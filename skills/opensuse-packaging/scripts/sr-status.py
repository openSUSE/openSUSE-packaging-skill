#!/usr/bin/env python3
"""Combined submission-status view: OBS submit requests AND src.opensuse.org
(Gitea) pull requests in ONE table — overall state, the review chain (SRs) /
merge+bot-build status (PRs), and human comments. Reused by Block 3
(submit / watch); satisfies the "status of my submissions = OBS SRs AND Gitea
PRs, declines flagged first" rule in one call.

Renders a Markdown table (so it looks nice in a chat/terminal that renders MD).

Usage:
  sr-status.py [--user U] [--state open|all|declined|accepted] [--target PRJ]
               [--limit N] [--format table|blocks] [--brief] [--summary] [--days N]
               [--deadline SECONDS] [--no-prs] [ID ...]
  sr-status.py --pr pool/<pkg>#<n>
    ID ...      specific OBS request ids, N, #N or sr#N (overrides discovery;
                skips the PR leg); one search call per 50 ids
    --pr        one PR's staging-bot build verdict, as an exit code
    --state     which of your creator SRs/PRs to show (default: open = new,review,declined)
    --target    restrict SR discovery to a target project (e.g. openSUSE:Factory)
    --limit     cap the SRs whose comments are fetched (default 40; no cap with
                --brief or --summary; 0 = no cap). Declines are never cut, and
                the header says "N of M shown" whenever anything was.
    --format    table = one row per item; blocks = per-item bullets
    --brief     discovery list only (id, package, target, state) — NO per-item
                review/comment API calls (this is what my-requests.sh wraps)
    --summary   counts by state and target, every decline with its reason and
                what was filed since at its target and in its devel project, the
                oldest new and review requests, and comments by others since your
                last action on your SRs and PRs (one call each); never capped, so
                no --limit. Pool PR builds are not read there: --pr reads them.
    --days      with --summary: also the requests accepted, revoked or
                superseded in the last N days (default 14), so "was it ever
                filed?" is never answered from the open list alone
    --deadline  start no per-item lookup after this many seconds (default 80):
                the rest print as UNKNOWN, so a long queue still prints
    --no-prs    skip the src.opensuse.org PR leg (OBS-only view)
    --user      OBS account (default: $GEECTL_OBS_USERNAME)

The PR leg reads src.opensuse.org through `git-obs -G src.opensuse.org api`.
git-obs reads its login itself (shared with tea by default); this script never
reads it. -G picks the login named src.opensuse.org, or the only one for that
host (`git-obs login add`), so a default login for another forge is never
used. If that fails it warns and falls back to the OBS-only table, and the
header says the PRs are UNKNOWN. Two sub-legs, both always run: PRs you
created, and PRs awaiting your review. `--no-prs` skips both. Every geectl /
git-obs call times out after 60s and then counts as a failed lookup (a network
failure for --pr), never as an empty answer.

A new or review SR whose source changed after the revision it pins is STALE
(outside --brief: one call per request when the source is still at that
revision): geectl request refile does not follow the branch, so a fix committed after filing
reaches nobody until it is filed again with --supersede. Equal files at another
srcmd5 (a link, or an scmsync package's _scmsync.obsinfo) are not stale. A
devel-project source gets forward-check.py instead of the refile, a request
targeting openSUSE:Factory gets no refile command yet (geectl cannot file
a request targeting it), and a request with several actions is not checked.

A declined SR that a later accepted one for the same package and target
replaced is annotated with the revoke that clears it and stays at the top:
geectl still counts a declined request, so the next `geectl request file` from that source
prompts over it. Only when both are among the rows fetched (--state all, or
both ids given).

An open pool/ PR's build is read from OBS, not from the staging bot's last
comment: the `...:PullRequest:<n>` project the bot names is built from whatever
commit its products PR pins, which can be older than the PR head (STALE). A
"succeeded" counts only when that arch's last build is of the current sources.
Red, stale and unreadable PR builds sort first, like declines.
"""

import sys
import argparse
import subprocess
import json
import re
import os
import datetime
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

sys.pycache_prefix = "/dev/null/opensuse-packaging"  # no __pycache__ beside it is read
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _sanitize  # noqa: E402  # escape/Unicode-smuggling filter for third-party text

# seconds per geectl / git-obs call: both have hung for good, and a harness
# gives the whole tool call 2 minutes, so the timeout must come first
TIMEOUT = 60


def run(cmd):
    """subprocess.run with TIMEOUT, cut to the time left before DEADLINE (at
    least 5 s), so a call started just before it cannot run a minute past. A
    call that times out, or whose binary is missing, comes back as a failed
    one (rc 124 / 127, as in the shell) and is reported like any other."""
    t = TIMEOUT
    if DEADLINE is not None:
        t = min(TIMEOUT, max(5, DEADLINE - time.monotonic()))
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=t)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            cmd, 124, "", f"{cmd[0]} timed out after {t:.0f}s"
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 127, "", f"{cmd[0]}: command not found")


def geectl(args, hard=True, errors=None, text=False):
    """Run geectl; a failure's text is appended to `errors` so --pr can tell a
    network failure from a refusal or a missing object. hard=True: exit 2 on
    failure (discovery must not silently become '0 shown'). hard=False:
    return None so the caller can emit a visible FETCH FAILED row instead of
    a garbage one. Returns the parsed JSON payload, or the raw text when
    text=True."""
    r = run(["geectl", *args])
    if r.returncode != 0:
        msg = f"geectl {' '.join(args)} failed (rc={r.returncode}): {r.stderr.strip()}"
        sys.stderr.write(f"ERROR: {msg}\n")
        if errors is not None:
            errors.append(msg)
        if hard:
            sys.exit(2)
        return None
    if text:
        return r.stdout or ""
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError as e:
        msg = f"geectl {' '.join(args)} returned unparseable output: {e}"
        sys.stderr.write(f"ERROR: {msg}\n")
        if errors is not None:
            errors.append(msg)
        if hard:
            sys.exit(2)
        return None


EMOJI = {
    "accepted": "✅",
    "new": "⏳",
    "review": "🔎",
    "declined": "❌",
    "revoked": "🚫",
    "superseded": "♻️",
    "obsoleted": "♻️",
    "open": "🔎",
    "merged": "✅",
    "closed": "❌",
    "": "❔",
}


def badge(state):
    return EMOJI.get(state, "❔")


SHORT = {
    "factory-auto": "auto",
    "licensedigger": "lic",
    "factory-staging": "stg",
    "opensuse-review-team": "team",
    "repo-checker": "repo",
}
# logins whose comments are bot noise, not human feedback: exact names, the
# autogits/_obs_ service accounts, and src.opensuse.org's group-review accounts
# (packagehub-review, opensuse-review) — a bare "bot" substring also hid people
BOTS = {
    "factory-auto",
    "licensedigger",
    "repo-checker",
    "staging-bot",
    "origin-manager",
    "abichecker",
    "leaper",
    "legaldb",
}


def is_bot(who):
    w = (who or "").lower()
    return (
        w in BOTS
        or w.startswith(("autogits", "_"))
        or "_obs_" in w
        or w.endswith("-review")
    )


def review_label(rv):  # short, for the compact table column
    for k in ("by_user", "by_group", "by_project"):
        v = rv.get(k)
        if v:
            return SHORT.get(v, v.split(":")[-1] if k == "by_project" else v)
    return "?"


def review_full(rv):  # full name, for the bulleted blocks format
    for k in ("by_user", "by_group"):
        v = rv.get(k)
        if v:
            return v
    v = rv.get("by_project")
    if v:
        return "staging " + (
            v.split("Staging:")[1] if "Staging:" in v else v.split(":")[-1]
        )
    return "?"


def clip(s, n=64):
    # Every foreign-authored comment/description body flows through here —
    # sanitize at the choke point so no ANSI/bidi/zero-width smuggling from a
    # request comment or PR body reaches the rendered table.
    s = " ".join(_sanitize.sanitize(s or "").split())
    return (s[: n - 1] + "…") if len(s) > n else s


def human_comment(req_id, state):
    # declined: the decline reason on the state is the salient human note
    if state is not None and state.get("name") == "declined":
        c = state.get("comment") or ""
        who = state.get("who", "?")
        if c.strip():
            return f'💬 {who}: "{clip(c)}"'
    # otherwise the latest non-bot comment in the thread
    payload = geectl(["request", "list-comments", str(req_id)], hard=False)
    if payload is None:
        return "(comment fetch failed)"
    cmts = [c for c in payload.get("comments", []) if not is_bot(c.get("who"))]
    if not cmts:
        return "—"
    last = cmts[-1]
    return f'💬 {last.get("who", "?")}: "{clip(last.get("body"))}"'


# ---------- Gitea (src.opensuse.org) PR leg ----------
# Read through `git-obs api`: git-obs keeps its own login, so no token is read here.


def gitea_get(path, errors=None):
    """`git-obs api <path>` — strips the leading 'Response:' banner line and
    parses JSON. Returns None on any failure (no src.opensuse.org login,
    network, HTTP error, bad JSON), with its text appended to `errors`, so
    the caller can emit a FETCH FAILED row."""
    # -G: the default login may belong to another forge
    r = run(["git-obs", "-G", "src.opensuse.org", "-q", "api", path])
    if r.returncode != 0:
        sys.stderr.write(f"WARNING: git-obs api {path} failed: {r.stderr.strip()}\n")
        if errors is not None:
            errors.append(r.stderr.strip())
        return None
    out = r.stdout
    if out.startswith("Response:"):
        out = out.split("\n", 1)[1] if "\n" in out else ""
    try:
        return json.loads(out)
    except json.JSONDecodeError as e:
        sys.stderr.write(
            f"WARNING: git-obs api {path} returned unparsable output ({e})\n"
        )
        if errors is not None:
            errors.append(f"unparsable output ({e})")
        return None


def human_line(cmts):
    """The latest non-bot comment, rendered, or '—'."""
    hum = next(
        (c for c in reversed(cmts) if not is_bot((c.get("user") or {}).get("login"))),
        None,
    )
    if not hum:
        return "—"
    return f'💬 {(hum.get("user") or {}).get("login", "?")}: "{clip(hum.get("body"))}"'


# ---------- PR build (the staging bot's ...:PullRequest:<n> project) ----------

# Only this login's links count: anyone can paste a green project into a comment.
STAGING_BOT = "autogits_obs_staging_bot"
PR_PROJECT = re.compile(
    r"(?:br\.opensuse\.org/status|build\.opensuse\.org/project/show)/"
    r"([\w.+-]+(?::[\w.+-]+)*:PullRequest:\d+)"
)
PIN_URL = re.compile(r"/([\w.+-]+/[\w.+-]+)/pulls/(\d+)")
RED = {"failed", "unresolvable", "broken"}
SKIP = {"excluded", "disabled"}
NETWORK = re.compile(
    r"timed? ?out|connection (?:refused|reset|aborted)|failed to establish"
    r"|name or service not known|temporary failure in name resolution"
    r"|network is unreachable|no route to host|remote end closed|urlopen error"
    r"|(?:HTTP Error |ERROR: )(?:5\d\d|429)\b",
    re.I,
)
PR_EXIT = {
    "green": 0,
    "merged": 0,
    "red": 1,
    "closed": 1,
    "lookup": 2,
    "pending": 3,
    "stale": 4,
    "network": 6,
}


def failure(errors, what):
    kind = "network" if any(NETWORK.search(e) for e in errors) else "lookup"
    word = "network failure" if kind == "network" else "lookup failed"
    return kind, f"PR build UNKNOWN ({word})", [f"could not read {what} ({word})"]


def build_results(payload, pkg):
    """(red, pending, succeeded, skipped) from a `geectl build results` JSON
    payload, excluded and disabled arches counted in skipped; None when
    unparsable. succeeded maps each label to its <repo>/<arch>/<package>
    build path. A dirty repository's codes are outdated, so they count as
    pending whatever they say."""
    if not isinstance(payload, dict):
        return None
    red, pending, ok, skipped = [], [], {}, 0
    for res in payload.get("results", []):
        where = f"{res.get('repository')}/{res.get('arch')}"
        for s in res.get("statuses", []):
            p = s.get("package", "")
            if p != pkg and not p.startswith(pkg + ":"):
                continue
            code = s.get("code", "unknown")
            label = f"{where}{p[len(pkg) :]} {code}"
            if res.get("dirty") is True:
                pending.append(label + " (dirty)")
            elif code in SKIP:
                skipped += 1
            elif code in RED:
                red.append(label)
            elif code == "succeeded":
                ok[label] = f"{where}/{p}"
            else:
                pending.append(label)
    return red, pending, ok, skipped


def older_builds(prj, pkg, ok, errors):
    """The succeeded labels whose last build is not of the current expanded
    sources: until the scheduler catches up, a new commit's results still say
    "succeeded", not dirty. Returns (older, None), or (None, what) when `what`
    could not be read. A linked package has no typed leaf for its expanded
    srcmd5 (its log's is the link's own), so its builds are unreadable here,
    not current."""
    log = geectl(
        ["remote", "package-log", prj, pkg, "--limit", "1"], hard=False, errors=errors
    )
    entries = log.get("entries", []) if log else []
    cur = entries[0].get("srcmd5") if entries else None
    if not cur:
        return None, f"the {prj}/{pkg} srcmd5"
    origin = geectl(["remote", "link-target", prj, pkg], hard=False, errors=errors)
    if origin and (origin.get("target") or {}).get("project"):
        return None, f"the {prj}/{pkg} expanded srcmd5 (linked package: no typed leaf reports it)"
    older = []
    for label, path in ok.items():
        what = f"the {prj}/{path} job history"
        # The last job, not _history: an unchanged rebuild adds no entry there.
        where, name = path.rsplit("/", 1)
        repo, arch = where.split("/")
        hist = geectl(
            ["build", "job-history", prj, repo, arch, "--package", name, "--limit", "1"],
            hard=False, errors=errors,
        )
        if hist is None:
            return None, what
        entries = hist.get("entries", [])
        got = entries[0].get("srcmd5", "") if entries else ""
        if got != cur:
            built = got[:12] or "nothing recorded"
            older.append(f"{label} (built {built}, sources {cur[:12]})")
    return older, None


def pin_of(prj, pkg, num, errors):
    """The products PR whose branch the PR project builds, and whose branch
    it is: the bot's PR_<pkg>#<n> follows pushes, a hand-made one does not.
    Returns (detail, short, advice)."""
    meta = geectl(["remote", "project-meta", prj], hard=False, errors=errors)
    url = (meta or {}).get("url") or ""
    m = PIN_URL.search(url)
    if not m:
        return "an unknown products PR (lookup failed)", "pin unknown", "check by hand"
    name = f"{m[1]}#{m[2]}"
    p = gitea_get(f"/repos/{m[1]}/pulls/{m[2]}", errors)
    if p is None:
        return f"{name}, branch unknown (lookup failed)", name, "check it by hand"
    head = p.get("head") or {}
    ref = _sanitize.sanitize(head.get("ref") or "?")
    owner = _sanitize.sanitize((head.get("repo") or {}).get("full_name") or "?")
    if ref == f"PR_{pkg}#{num}" and owner == m[1]:
        return (
            f"{name}, bot branch {ref}",
            f"{name} bot",
            "the bot has not picked up the head yet; if that persists it is stuck",
        )
    return (
        f"{name}, hand-made branch {owner}:{ref}",
        f"{name} hand-made",
        "a hand-made branch does not follow pushes; ask its author to move it",
    )


def pr_build(repo, num, pr, cmts, errors):
    """Verdict on the staging bot's OBS build of an open PR, read from OBS.
    cmts=None means the comments could not be read. Returns (verdict, short,
    lines): a PR_EXIT key, the table text, and the --pr lines, verdict last."""
    if cmts is None:
        return failure(errors, "the PR comments")
    prj = None
    for c in cmts:
        if (c.get("user") or {}).get("login") == STAGING_BOT:
            found = PR_PROJECT.findall(c.get("body") or "")
            prj = found[-1] if found else prj
    if not prj:
        since = (pr.get("created_at") or "?")[:10]
        return (
            "pending",
            "no PR build yet",
            [f"PENDING — no staging-bot build comment (PR opened {since})"],
        )
    head = ((pr.get("head") or {}).get("sha") or "").lower()
    pkg = repo.split("/")[-1]
    info = geectl(
        ["remote", "cat", prj, pkg, SCMSYNC_INFO, "--format", "text"],
        hard=False, errors=errors, text=True,
    )
    if info is None:
        v, short, why = failure(errors, f"{prj}/{pkg}/_scmsync.obsinfo")
        return v, short, [f"PR build: {prj}"] + why
    built = next(
        (
            ln.split(":", 1)[1].strip().lower()
            for ln in info.splitlines()
            if ln.startswith("commit:")
        ),
        "",
    )
    if not built or not head:
        what = "the PR head" if not head else "commit: in _scmsync.obsinfo"
        return (
            "lookup",
            "PR build UNKNOWN (lookup failed)",
            [f"PR build: {prj}", f"no {what}"],
        )
    lines = [f"PR build: {prj} · built {built[:12]} · PR head {head[:12]}"]
    payload = geectl(
        ["build", "results", prj, "--package", pkg, "--multibuild"],
        hard=False, errors=errors,
    )
    got = build_results(payload, pkg) if payload is not None else None
    if got is None:
        v, short, why = failure(errors, f"the {prj} results")
        return v, short, lines + why
    red, pending, ok, skipped = got
    lines.append("results: " + (" · ".join(red + pending + list(ok)) or "none"))
    if built != head:
        detail, pin, advice = pin_of(prj, pkg, num, errors)
        lines.append(f"pinned by {detail}")
        lines.append(f"STALE — the PR build is not of the PR head; {advice}")
        return "stale", f"PR build STALE ({built[:7]} ≠ head {head[:7]}, {pin})", lines
    if red:
        lines.append("RED at the PR head")
        return "red", "PR build ❌ at head", lines
    if pending:
        lines.append("PENDING — still building at the PR head")
        return "pending", "PR build ⏳", lines
    if not ok and not skipped:
        lines.append("PENDING — no build results yet")
        return "pending", "PR build ⏳", lines
    if not ok:
        lines.append("RED — nothing built: every arch excluded or disabled")
        return "red", "PR build ❌ (nothing built)", lines
    older, what = older_builds(prj, pkg, ok, errors)
    if older is None:
        v, short, why = failure(errors, what)
        return v, short, lines + why
    if older:
        lines.append("built from older sources: " + " · ".join(older))
        lines.append("PENDING — not yet rebuilt from the current sources")
        return "pending", "PR build ⏳", lines
    lines.append("GREEN at the PR head")
    return "green", "PR build ✅ at head", lines


def pr_mode(repo, num):
    """--pr: print one PR's build verdict and return its PR_EXIT code."""
    errors = []
    pr = gitea_get(f"/repos/{repo}/pulls/{num}", errors)
    if pr is None:
        v, _, why = failure(errors, f"{repo}#{num}")
        print(f"{repo}#{num}\nVERDICT: UNKNOWN — {why[0]}")
        return PR_EXIT[v]
    print(f"{repo}#{num} → {(pr.get('base') or {}).get('ref', '?')}")
    if pr.get("merged") or pr.get("merged_at"):
        print("VERDICT: MERGED")
        return PR_EXIT["merged"]
    if pr.get("state") == "closed":
        print("VERDICT: CLOSED without a merge")
        return PR_EXIT["closed"]
    cmts = gitea_get(f"/repos/{repo}/issues/{num}/comments", errors)
    v, _, lines = pr_build(repo, num, pr, cmts, errors)
    for ln in lines[:-1]:
        print(ln)
    if cmts and human_line(cmts) != "—":
        print(f"latest comment: {human_line(cmts)}")
    unknown = "UNKNOWN — " if v in ("lookup", "network") else ""
    print(f"VERDICT: {unknown}{lines[-1]}")
    return PR_EXIT[v]


PR_PAGE = 50  # the limit= the PR leg asks for: a full page may have more


def fetch_prs(state, brief, leg):
    """One issues/search call for the user's PRs (leg='created') or PRs
    awaiting the user's review (leg='review-requested'); per-PR detail
    (base branch, mergeable, bot-build + human comments) only in full mode.
    Returns (rows, full) — full when the page came back at PR_PAGE, so more
    may exist — or None on failure (caller falls back)."""
    q_state = "open" if state == "open" else "all"
    issues = gitea_get(
        f"/repos/issues/search?type=pulls&{leg.replace('-', '_')}=true"
        f"&state={q_state}&limit={PR_PAGE}"
    )
    if issues is None:
        sys.stderr.write(
            f"WARNING: src.opensuse.org PR leg ({leg}) skipped "
            f"— OBS-only view. Pass --no-prs to silence.\n"
        )
        return None
    rows = []
    for it in issues:
        repo = (it.get("repository") or {}).get("full_name", "?")
        num = it.get("number")
        prinfo = it.get("pull_request") or {}
        merged = bool(prinfo.get("merged") or prinfo.get("merged_at"))
        st = "merged" if merged else it.get("state", "?")  # open|closed|merged
        if state == "declined" and st != "closed":
            continue
        if state == "accepted" and st != "merged":
            continue
        target, status, comment = repo, "—", "—"
        build_bad = False
        if not brief:
            pr = gitea_get(f"/repos/{repo}/pulls/{num}")
            if pr is None:
                status = "(detail fetch failed)"
            else:
                base = (pr.get("base") or {}).get("ref", "?")
                target = f"{repo}:{base}"
                bits = []
                if merged:
                    bits.append("merged")
                elif pr.get("mergeable") is not None:
                    bits.append("mergeable" if pr["mergeable"] else "NOT mergeable")
                errors = []
                got = gitea_get(f"/repos/{repo}/issues/{num}/comments", errors)
                cmts = got or []
                bot_line = next(
                    (
                        c
                        for c in reversed(cmts)
                        if is_bot((c.get("user") or {}).get("login"))
                    ),
                    None,
                )
                if repo.startswith("pool/") and st == "open":
                    verdict, short, _ = pr_build(repo, num, pr, got, errors)
                    bits.append(short)
                    build_bad = verdict not in ("green", "pending")
                elif bot_line:
                    body = (bot_line.get("body") or "").lower()
                    if "succe" in body or "✅" in body:
                        bits.append("bot-build ✅")
                    elif "fail" in body or "❌" in body:
                        bits.append("bot-build ❌")
                    else:
                        bits.append("bot 💬")
                if leg == "review-requested":
                    bits.append("needs YOUR review")
                status = " · ".join(bits) or "—"
                comment = human_line(cmts)
        rows.append(
            {
                "kind": "PR",
                "id": f"#{num}",
                "num": int(num or 0),
                "pkg": repo.split("/")[-1],
                "target": target,
                "state": st,
                "chain": status,
                "comment": comment,
                # closed-unmerged, needs-your-review and a red, stale or
                # unreadable PR build all sort first
                "bad": st == "closed" or leg == "review-requested" or build_bad,
                "repo": repo,
                "ncomments": it.get("comments") or 0,
                "author": (it.get("user") or {}).get("login"),
                "created": it.get("created_at"),
            }
        )
    return rows, len(issues) >= PR_PAGE


# ---------- OBS request rows ----------

SEARCH_CHUNK = 50  # ids per /search/request call, to keep the URL short


def sr_row(req, brief):
    """One table/brief row from a request dict of a search result: it already
    carries the state, actions and reviews, so no per-item call is needed
    for anything but the comments."""
    st = req.get("state") or {}
    sname = st.get("name") or ""
    acts = [a for a in req.get("actions", []) if a.get("type") == "submit"]
    act = acts[0] if acts else {}
    reviews = req.get("reviews", [])
    # staging assignment is free here — the reviews are in the JSON already
    stg = ""
    for rv in reviews:
        if rv.get("state") == "new":
            by = rv.get("by_project") or ""
            if "Staging" in by:
                parts = by.split(":")
                # ...Staging:adi:40 -> adi:40, ...Staging:G -> G
                stg = parts[-1] if parts[-2] == "Staging" else ":".join(parts[-2:])
    rid = str(req.get("id", "?"))
    row = {
        "kind": "SR",
        "id": rid,
        "num": int(rid) if rid.isdigit() else 0,
        "pkg": act.get("target_package") or "?",
        "target": act.get("target_project") or "?",
        "state": sname,
        "chain": "—",
        "comment": "—",
        "bad": sname == "declined",
        "el": req,
    }
    if brief:
        row["src"] = (
            f"{act.get('source_project')}/{act.get('source_package')}"
            if act.get("source_project") else "?"
        )
        row["staging"] = stg
    else:
        row["reviews"] = reviews
        row["chain"] = (
            " ".join(
                f"{review_label(rv)}{badge(rv.get('state', ''))}" for rv in reviews
            )
            or "—"
        )
    return row


def failed_row(rid, why, comment="—"):
    return {
        "kind": "SR",
        "id": rid,
        "num": int(rid) if rid.isdigit() else 0,
        "pkg": "?",
        "target": "?",
        "state": "",
        "chain": why,
        "comment": comment,
        "bad": True,
    }


def fetch_ids(ids):
    """The requests behind explicit ids, SEARCH_CHUNK per search call: one
    call per id timed out on 40 ids. Returns {id: request dict}; an id
    missing from the answer is absent, a failed chunk maps its ids to None."""
    got = {}
    for i in range(0, len(ids), SEARCH_CHUNK):
        chunk = ids[i : i + SEARCH_CHUNK]
        cmd = ["request", "search", "--with-history"]
        for rid in chunk:
            cmd += ["--request-id", rid]
        payload = geectl(cmd, hard=False)
        if payload is None:
            got.update({rid: None for rid in chunk})
            continue
        for r in payload.get("requests", []):
            got[str(r.get("id"))] = r
    return got


# Per-item lookups stop starting at this monotonic time (set from --deadline),
# so a long queue still prints before a harness kills the call.
DEADLINE = None
SKIPPED = "deadline"  # what a lookup returns when it never started


def comments_for(rows, fn):
    """fn(row) for every row, 8 at a time: comments are one call per request.
    A row whose turn comes after DEADLINE gets SKIPPED instead of a call."""

    def one(row):
        if DEADLINE is not None and time.monotonic() >= DEADLINE:
            return SKIPPED
        return fn(row)

    with ThreadPoolExecutor(max_workers=8) as ex:
        return list(ex.map(one, rows))


# ---------- stale requests ----------

LOOKUP_FAILED = object()
# An scmsync package's obsinfo names its tracking branch: it changes (main ->
# factory) while the sources stay the same commit.
SCMSYNC_INFO = "_scmsync.obsinfo"


def _raw_files(prj, pkg, rev=None):
    """(files, link_tag) of prj/pkg at rev: files as (name, md5) pairs, and
    the _link element's text when the listing carries one, else None. None
    on a 404, LOOKUP_FAILED on any other failure."""
    cmd = ["remote", "list-files", prj, pkg]
    if rev is not None:
        cmd += ["--rev", str(rev)]
    errors = []
    payload = geectl(cmd, hard=False, errors=errors)
    if payload is None:
        return None if any("not_found" in e for e in errors) else LOOKUP_FAILED
    entries = payload.get("files", [])
    tag = None
    if any(f.get("name") == "_link" for f in entries):
        text = geectl(
            ["remote", "cat", prj, pkg, "_link", "--format", "text"],
            hard=False, text=True,
        )
        if text is None:
            return LOOKUP_FAILED
        m = re.search(r"<link\b[^>]*>", text or "")
        tag = m.group(0) if m else ""
    return (
        frozenset((f.get("name"), f.get("md5")) for f in entries),
        tag,
    )


def listing(prj, pkg, rev=None):
    """The expanded files of prj/pkg (at revision rev) with its srcmd5:
    {rev, srcmd5, files}. None on a 404, LOOKUP_FAILED on any other failure.
    list-files never expands a link, so a link is resolved by hand: its _link
    names the target (and pin), the target's listing at that revision is the
    expanded one, and local files overlay it. A link with its own _service is
    the exception: its service results are in neither listing. The
    _scmsync.obsinfo file is left out: it changes (main -> factory) while the
    sources stay the same commit."""
    raw = _raw_files(prj, pkg, rev)
    if raw is None or raw is LOOKUP_FAILED:
        return raw
    files, tag = raw
    srcmd5 = None
    if rev is None:
        log = geectl(["remote", "package-log", prj, pkg, "--limit", "1"], hard=False)
        if log:
            entries = log.get("entries", [])
            if entries:
                srcmd5 = entries[0].get("srcmd5")
                rev = entries[0].get("rev")
                if rev is not None:
                    rev = str(rev)
    depth = 0
    while tag is not None and depth < 5:
        depth += 1

        def attr(name, _tag=tag):
            mm = re.search(rf'\b{name}="([^"]*)"', _tag)
            return mm.group(1) if mm else ""

        tprj, tpkg, trev = attr("project"), attr("package"), attr("rev")
        if not tprj or not tpkg:
            return LOOKUP_FAILED
        traw = _raw_files(tprj, tpkg, trev or None)
        if traw is None or traw is LOOKUP_FAILED:
            return traw
        tfiles, tag = traw
        merged = {n: m for n, m in tfiles if n != "_link"}
        merged.update({n: m for n, m in files if n != "_link"})
        files = frozenset(merged.items())
    if tag is not None:
        return LOOKUP_FAILED
    files = frozenset((n, m) for n, m in files if n != SCMSYNC_INFO)
    return {"rev": rev, "srcmd5": srcmd5, "files": files}


def refile(row, prj, pkg):
    """What files the source's current state over the request: the geectl
    request refile for a home: branch; for a devel project forward-check.py
    first, since a refile would also forward other people's commits there.
    A request targeting openSUSE:Factory has no refile path yet: geectl
    cannot file a request targeting it. Cleanup is the refile's default,
    so no flag names it."""
    if not prj.startswith("home:"):
        return f"run forward-check.py {prj}/{pkg} before any refile"
    if row["target"] == "openSUSE:Factory":
        return (
            "the refile has no geectl path yet: geectl cannot file a request "
            "targeting openSUSE:Factory — report the request as ready to "
            "forward and stop"
        )
    return (
        f"geectl request refile --source-project {prj} --source-package {pkg} "
        f"--target-project {row['target']} --target-package {row['pkg']} "
        f"--description MSG --changes-entry MSG --supersede {row['id']} --live"
    )


def staleness(row):
    """What to say about an open request whose source moved on; empty when
    it still carries its source's current files or pins no revision. The
    pinned rev (most are revision numbers, some a link's or a service's
    expanded srcmd5) is compared with the source's current revision first:
    one call when nothing changed."""
    acts = [a for a in row["el"].get("actions", []) if a.get("type") == "submit"]
    if len(acts) > 1:
        return f"STALE not checked ({len(acts)} actions)"
    act = acts[0] if acts else {}
    rev = act.get("source_rev")
    prj, pkg = act.get("source_project"), act.get("source_package")
    if not (rev and prj and pkg):
        return ""
    head = listing(prj, pkg)
    if head is LOOKUP_FAILED:
        return "STALE UNKNOWN (source lookup failed)"
    if head is None:
        return f"source gone: {prj}/{pkg}"
    current = {head.get("rev"), head.get("srcmd5")}
    # a link pins its expanded srcmd5, a server-side _service its result's:
    # neither is in the current set (no typed leaf reports it), so such a
    # pin falls through to the files comparison
    if rev in current - {None}:
        return ""
    pinned = listing(prj, pkg, rev)
    if pinned in (None, LOOKUP_FAILED):
        return "STALE UNKNOWN (pinned revision lookup failed)"
    if pinned["files"] == head["files"]:
        return ""
    return f"STALE — source changed after the pinned revision: {refile(row, prj, pkg)}"


def closed_since(user, days):
    """(since, [request]) for your submit requests accepted, revoked or
    superseded since `days` ago, each request a dict; requests None when the
    search failed, SKIPPED past the deadline."""
    since = (
        datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    ).strftime("%Y-%m-%d")
    if DEADLINE is not None and time.monotonic() >= DEADLINE:
        return since, SKIPPED
    payload = geectl(
        ["request", "search", "--creator", user, "--type", "submit",
         "--state", "accepted", "--state", "revoked", "--state", "superseded",
         "--since", since],
        hard=False,
    )
    if payload is None:
        return since, None
    out = []
    for r in payload.get("requests", []):
        st = r.get("state") or {}
        # --since matches a history entry at or after the date, so the state
        # change itself is filtered on state.when
        if (st.get("when") or "") < since:
            continue
        act = (r.get("actions") or [{}])[0]
        out.append(
            {
                "id": str(r.get("id", "?")),
                "state": st.get("name", ""),
                "who": st.get("who", "?"),
                "by": st.get("superseded_by", "?"),
                "why": st.get("comment") or "",
                "target": act.get("target_project", "?"),
                "pkg": act.get("target_package", "?"),
            }
        )
    return since, sorted(out, key=lambda r: int(r["id"]) if r["id"].isdigit() else 0)


# ---------- --summary ----------


def norm_time(s):
    """OBS writes 2026-10-19T05:09:04 in request JSON and
    2026-10-19 05:09:04 UTC in comments; both become comparable text."""
    return (s or "").replace("T", " ").replace(" UTC", "")[:19]


def created(row):
    st = row["el"].get("state") or {}
    return norm_time(st.get("created"))


def later_requests(prj, pkg, after):
    """Requests to prj/pkg newer than id `after`, by anyone, still open or
    accepted: whether someone already handled a decline. One search call,
    scoped to the target (a collection by project/package also matches where
    it is only the source or a reviewer, and drags the whole history along).
    Returns [(id, state, creator)], or None when the lookup failed."""

    payload = geectl(
        ["request", "search", "--target-project", prj, "--target-package", pkg,
         "--type", "submit", "--state", "new", "--state", "review",
         "--state", "accepted"],
        hard=False,
    )
    if payload is None:
        return None
    later = []
    for r in payload.get("requests", []):
        rid = r.get("id", 0)
        if isinstance(rid, int) and rid > after:
            st = r.get("state") or {}
            later.append((rid, st.get("name", "?"), r.get("creator")))
    return sorted(later)


def decline_followups(row):
    """[(where, later)] for a decline: its target, and its source project when
    that is not a home: one — a Factory decline is fixed in the devel project."""
    acts = row["el"].get("actions", [])
    act = acts[0] if acts else {}
    places = [(row["target"], row["pkg"])]
    if act.get("source_project") and not act.get("source_project").startswith("home:"):
        places.append((act.get("source_project"), act.get("source_package") or row["pkg"]))
    return [(f"{p}/{k}", later_requests(p, k, row["num"])) for p, k in places]


def others_comments(row, user):
    """Non-bot comments by someone other than `user` newer than the user's last
    action on the request (its creation, a history entry, or an own comment).
    Returns a list of (when, who, text), or None when the fetch failed."""
    req = row["el"]
    mine = [created(row)]
    mine += [
        norm_time(h.get("when")) for h in req.get("history", []) if h.get("who") == user
    ]
    payload = geectl(["request", "list-comments", str(row["id"])], hard=False)
    if payload is None:
        return None
    cmts = payload.get("comments", [])
    mine += [norm_time(c.get("when")) for c in cmts if c.get("who") == user]
    last = max(mine) if mine else ""
    return [
        (norm_time(c.get("when")), c.get("who", "?"), c.get("body"))
        for c in cmts
        if c.get("who") != user
        and not is_bot(c.get("who"))
        and norm_time(c.get("when")) > last
    ]


def iso(s):
    """A Gitea timestamp as an aware datetime, or None."""
    try:
        return datetime.datetime.fromisoformat((s or "").replace("Z", "+00:00"))
    except ValueError:
        return None


def login(x):
    return (x.get("user") or {}).get("login")


def pr_others_comments(pr):
    """What others said on one of your PRs since your last word there (its
    opening, or your latest comment or review), bots aside. issues/search's
    count includes reviews, which /issues/<n>/comments does not return, so
    when it is short the reviews are read too. Returns (when, who, text,
    kind) oldest first — kind "comment", "change request" or "approval", with
    ", +N inline" for review comments — or None when a fetch failed."""
    num = pr["id"].lstrip("#")
    cmts = gitea_get(f"/repos/{pr['repo']}/issues/{num}/comments")
    if cmts is None:
        return None
    reviews = []
    if len(cmts) < (pr.get("ncomments") or 0):
        reviews = gitea_get(f"/repos/{pr['repo']}/pulls/{num}/reviews")
        if reviews is None:
            return None
    author = pr.get("author")
    marks = [iso(pr.get("created"))]
    marks += [iso(c.get("created_at")) for c in cmts if login(c) == author]
    marks += [iso(r.get("submitted_at")) for r in reviews if login(r) == author]
    marks = [m for m in marks if m is not None]
    last = max(marks) if marks else None

    def newer(stamp):
        when = iso(stamp)
        return last is None or when is None or when > last

    out = []
    for c in cmts:
        who = login(c)
        if who == author or is_bot(who) or not newer(c.get("created_at")):
            continue
        body = c.get("body") or ""
        merge_ok = body.strip().lower().rstrip(".!") == "merge ok"
        out.append(
            (c.get("created_at"), who, body, "approval" if merge_ok else "comment")
        )
    for r in reviews:
        who, state = login(r), (r.get("state") or "").upper()
        if who == author or is_bot(who) or not newer(r.get("submitted_at")):
            continue
        inline = r.get("comments_count") or 0
        if state == "APPROVED":
            kind = "approval"
        elif state == "REQUEST_CHANGES":
            kind = "change request"
        elif r.get("body") or inline:
            kind = "comment"
        else:
            continue
        kind += f", +{inline} inline" if inline else ""
        out.append((r.get("submitted_at"), who, r.get("body") or "", kind))
    floor = datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)
    return sorted(out, key=lambda x: iso(x[0]) or floor)


def summary(user, rows, prs, failed_legs, no_prs, days):
    """--summary: what needs reading at volume, in one screen."""
    srs = [r for r in rows if r["kind"] == "SR"]
    by_state = Counter(r["state"] for r in srs)
    by_target = defaultdict(Counter)
    for r in srs:
        by_target[r["target"]][r["state"]] += 1
    states = [s for s in ("new", "review", "declined") if by_state[s]] + sorted(
        s for s in by_state if s not in ("new", "review", "declined")
    )
    print(f"### Submissions for `{user}` — summary\n")
    print(
        f"OBS submit requests: {len(srs)}"
        + (f" ({' · '.join(f'{s} {by_state[s]}' for s in states)})" if srs else "")
    )
    if by_target:
        print("by target (" + "/".join(states) + "):")
        for tgt, c in sorted(
            by_target.items(), key=lambda kv: (-sum(kv[1].values()), kv[0])
        ):
            print(
                f"  {tgt:36} {sum(c.values()):4}  ("
                + "/".join(str(c[s]) for s in states)
                + ")"
            )
    for state in ("new", "review"):
        waiting = [r for r in srs if r["state"] == state]
        if not waiting:
            continue
        old = min(waiting, key=created)
        when = created(old)
        try:
            then = datetime.datetime.strptime(when, "%Y-%m-%d %H:%M:%S")
            now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
            age = f", {(now - then).days} days ago"
        except ValueError:
            age = ""
        print(
            f"oldest {state}: SR {old['id']} {old['pkg']} -> {old['target']} "
            f"(created {when[:10]}{age})"
        )
    declined = [r for r in srs if r["state"] == "declined"]
    if declined:
        print(f"\ndeclined ({len(declined)}):")
        for r, follow in zip(declined, comments_for(declined, decline_followups)):
            st = r["el"].get("state") or {}
            who = clip(st.get("who", "?"), 40)
            why = clip(st.get("comment") or "", 120)
            print(f'  SR {r["id"]} {r["pkg"]} -> {r["target"]} by {who}: "{why}"')
            if follow is SKIPPED:
                print("    later requests UNKNOWN (not looked up: --deadline reached)")
                continue
            for where, later in follow:
                if later is None:
                    after = "UNKNOWN (lookup failed)"
                elif later:
                    after = "; ".join(
                        f"#{n} {s} by {clip(c or '?', 40)}" for n, s, c in later
                    )
                else:
                    after = "nothing filed since"
                print(f"    {where}: {after}")
    waiting = [r for r in srs if r["state"] in ("new", "review")]
    if waiting:
        found = comments_for(waiting, staleness)
        stale = [(r, s) for r, s in zip(waiting, found) if s and s is not SKIPPED]
        unchecked = [r for r, s in zip(waiting, found) if s is SKIPPED]
        hits = [x for x in stale if x[1].startswith("STALE —")]
        print(
            f"\nstale ({len(hits)}): source changed after the revision the request pins"
            + (" — refile:" if hits else "")
        )
        for r, s in stale:
            what = s.split(": ", 1)[1] if s.startswith("STALE —") else s
            print(f"  SR {r['id']} {r['pkg']} -> {r['target']}: {what}")
        if unchecked:
            print(
                "  not checked (--deadline reached): "
                + ", ".join(f"SR {r['id']} {r['pkg']}" for r in unchecked)
            )
    since, closed = closed_since(user, days)
    head = f"\nclosed in the last {days} days (since {since})"
    if closed is SKIPPED:
        print(f"{head}: UNKNOWN (not looked up: --deadline reached)")
    elif closed is None:
        print(f"{head}: UNKNOWN (lookup failed)")
    else:
        by = Counter(r["state"] for r in closed)
        print(
            f"{head}: {len(closed)}"
            + (" — " + " · ".join(f"{s} {by[s]}" for s in sorted(by)) if closed else "")
        )
        per = defaultdict(Counter)
        for r in closed:
            per[r["target"]][r["state"]] += 1
        for tgt in sorted(per):
            c = per[tgt]
            print(f"  {tgt}: " + " · ".join(f"{s} {c[s]}" for s in sorted(c)))
        # your own refile is routine (its "why" is your new description):
        # counted, not listed; someone else superseding yours is news
        own = [r for r in closed if r["state"] == "superseded" and r["who"] == user]
        if own:
            print(f"  superseded by your own refile: {len(own)}")
        for r in closed:
            if r["state"] not in ("revoked", "superseded") or r in own:
                continue
            by_new = f" by #{r['by']}" if r["state"] == "superseded" else ""
            why = f': "{clip(r["why"], 100)}"' if r["why"].strip() else ""
            print(
                f"  {r['state']}: SR {r['id']} {r['pkg']} -> {r['target']}{by_new} "
                f"({clip(r['who'], 40)}){why}"
            )
    open_srs = [r for r in srs if r["state"] in ("new", "review", "declined")]
    prs_ok = not no_prs and not failed_legs
    mine = [p for p in prs if not p.get("review")]
    asked = [p for p in prs if p.get("review")]
    items = []
    if prs_ok:
        # issues/search says how many comments a PR has: read only those, and
        # first, as they are few and --deadline cuts the end of the queue
        items += [("PR", p) for p in mine if p.get("ncomments")]
    items += [("SR", r) for r in open_srs]
    found = comments_for(
        items,
        lambda it: (
            others_comments(it[1], user) if it[0] == "SR" else pr_others_comments(it[1])
        ),
    )
    failed = [it for it, c in zip(items, found) if c is None]
    skipped = [it for it, c in zip(items, found) if c is SKIPPED]
    # an approval ("merge ok", an APPROVED review) is news, not a question
    news, approvals = [], []
    for it, cs in zip(items, found):
        if not cs or cs is SKIPPED:
            continue
        cs = [c if len(c) == 4 else (*c, "comment") for c in cs]
        todo = [c for c in cs if c[3] != "approval"]
        if todo:
            news.append((it, todo))
        if len(todo) < len(cs):
            approvals.append((it, [c for c in cs if c[3] == "approval"]))

    def label(it):
        kind, r = it
        if kind == "SR":
            return f"SR {r['id']} {r['pkg']} -> {r['target']}"
        return f"PR {r['repo']}{r['id']}"

    print(
        f"\ncomments by others since your last action: {len(news)} request(s)"
        + (" or PR(s)" if prs_ok else "")
        + (f", {len(failed)} UNKNOWN (comment fetch failed)" if failed else "")
        + (
            f", {len(skipped)} UNKNOWN (not fetched: --deadline reached)"
            if skipped
            else ""
        )
    )
    for it, cs in news:
        when, who, text, kind = cs[-1]
        more = f" (+{len(cs) - 1} more)" if len(cs) > 1 else ""
        tag = "" if kind == "comment" else f" [{kind}]"
        print(
            f'  {label(it)} {clip(who, 40)} {(when or "?")[:10]}{tag}: "{clip(text, 100)}"{more}'
        )
    if approvals:
        print(
            "  approved since your last action: "
            + ", ".join(f"{label(it)} by {clip(cs[-1][1], 40)}" for it, cs in approvals)
        )
    for it in failed:
        print(f"  {label(it)} UNKNOWN (comment fetch failed)")
    if skipped:
        print(
            "  not fetched (--deadline reached; raise it, or ask by id): "
            + ", ".join(label(it).split(" -> ")[0] for it in skipped)
        )
    if not no_prs:
        if failed_legs:
            print(
                f"\nsrc.opensuse.org PRs UNKNOWN: the {' and '.join(failed_legs)} leg failed, see stderr"
            )
        else:
            print(
                f"\nsrc.opensuse.org PRs: {len(mine)} yours, {len(asked)} awaiting your review"
            )
            for p in asked:
                print(f"  awaiting your review: {p['repo']}{p['id']}")
            pool = [
                p
                for p in mine
                if p["repo"].startswith("pool/") and p["state"] == "open"
            ]
            if pool:
                print(
                    "  PR builds not read: sr-status.py --pr pool/<pkg>#<n> for "
                    + ", ".join(f"{p['repo']}{p['id']}" for p in pool)
                )


# ---------- main ----------


def main():
    ap = argparse.ArgumentParser(
        allow_abbrev=False,
        epilog="Exit:\n"
        "  0 = printed (a PR-leg or comment-fetch failure only warns, as UNKNOWN);\n"
        "      --pr: green at the PR head, or merged\n"
        "  1 = --pr: red at the PR head, or closed without a merge\n"
        "  2 = usage, or a lookup failed (the OBS query; with --pr any lookup)\n"
        "  3 = --pr: pending (no staging-bot comment yet, still building, or not\n"
        "      yet rebuilt from the current sources)\n"
        "  4 = --pr: stale (the PR build is of an older commit than the head)\n"
        "  6 = --pr: network failure (retry)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--user")
    ap.add_argument("--state", default="open")
    ap.add_argument("--target")
    ap.add_argument(
        "--limit",
        type=int,
        default=None,
        help="cap the SRs whose comments are fetched (default 40; no cap with "
        "--brief or --summary; 0 = no cap); declines are never cut",
    )
    ap.add_argument(
        "--format",
        choices=["table", "blocks"],
        default="table",
        help="table = one cramped row per item; blocks = per-item bullets",
    )
    ap.add_argument(
        "--brief",
        action="store_true",
        help="discovery list only — no per-item review/comment calls",
    )
    ap.add_argument(
        "--summary",
        action="store_true",
        help="counts by state and target, declines with reasons, the oldest new "
        "request, comments by others since your last action",
    )
    ap.add_argument(
        "--days",
        type=int,
        default=None,
        metavar="N",
        help="with --summary: also the requests accepted, revoked or superseded "
        "in the last N days (default 14)",
    )
    ap.add_argument(
        "--deadline",
        type=float,
        default=80,
        metavar="SECONDS",
        help="start no per-item lookup after this many seconds (default 80); "
        "the rest print as UNKNOWN, so a long queue still prints",
    )
    ap.add_argument(
        "--no-prs", action="store_true", help="skip the src.opensuse.org PR leg"
    )
    ap.add_argument(
        "--pr",
        metavar="OWNER/REPO#N",
        help="one PR's staging-bot OBS build verdict, e.g. pool/pkg#3",
    )
    a = ap.parse_args()
    if a.deadline < 0:
        ap.error("--deadline takes 0 or more seconds")
    global DEADLINE
    DEADLINE = time.monotonic() + a.deadline
    if a.pr:
        m = re.fullmatch(r"([\w.+-]+/[\w.+-]+)#(\d+)", a.pr)
        if not m or a.ids:
            ap.error("--pr takes OWNER/REPO#N and no request ids")
        sys.exit(pr_mode(m[1], m[2]))
    if a.summary and a.ids:
        ap.error("--summary takes no request ids")
    if a.summary and a.limit is not None:
        ap.error("--summary is never capped: drop --limit")
    if a.days is not None and (not a.summary or a.days < 1):
        ap.error("--days N (1 or more) goes with --summary")
    ids = []
    for raw in a.ids:
        rid = re.sub(r"^(?:sr)?#", "", raw.strip(), flags=re.I)
        if not re.fullmatch(r"[1-9][0-9]*", rid):
            ap.error(f"not a request id: {raw!r} (digits, optionally after sr# or #)")
        ids.append(rid)
    if a.limit is not None and a.limit < 0:
        ap.error("--limit takes 0 (no cap) or a positive number")
    limit = a.limit if a.limit is not None else (0 if a.brief or a.summary else 40)
    user = a.user or os.environ.get("GEECTL_OBS_USERNAME", "")
    if not user:
        sys.stderr.write(
            "ERROR: could not determine OBS user — pass --user or set "
            "GEECTL_OBS_USERNAME (there is no typed leaf for the "
            "authenticated user)\n"
        )
        sys.exit(2)

    brief = a.brief or a.summary
    rows, cut = [], 0
    if ids:
        got = fetch_ids(ids)
        for rid in ids:
            if rid not in got:
                rows.append(failed_row(rid, "NOT FOUND"))
            elif got[rid] is None:
                rows.append(failed_row(rid, "FETCH FAILED", "(see stderr)"))
            else:
                rows.append(sr_row(got[rid], brief))
    else:
        # "open" means "still needs something from you", so it MUST include
        # declined: a decline is the single most actionable state a request of
        # yours can be in (it needs a fix + supersede, or a revoke), and it is
        # what the declines-first sort below exists to surface. Leaving it out
        # made the default view silently hide exactly the rows worth reading.
        states = {
            "open": ["new", "review", "declined"],
            "all": ["new", "review", "declined", "accepted", "revoked", "superseded"],
        }.get(a.state, [a.state])
        cmd = ["request", "search", "--creator", user, "--type", "submit",
               "--with-history"]
        for st in states:
            cmd += ["--state", st]
        if a.target:
            cmd += ["--target-project", a.target]
        payload = geectl(cmd)  # geectl() exits 2 on failure
        reqs = payload.get("requests", [])
        if limit and len(reqs) > limit:
            # the cap only saves the comment calls: keep every decline, then the
            # newest of the rest — a silent cut of the oldest once hid a decline
            def declined(r):
                return (r.get("state") or {}).get("name") == "declined"

            keep = [r for r in reqs if declined(r)]
            rest = sorted(
                (r for r in reqs if not declined(r)),
                key=lambda r: int(r.get("id", 0)),
                reverse=True,
            )
            keep += rest[: max(0, limit - len(keep))]
            cut = len(reqs) - len(keep)
            reqs = keep
        rows = [sr_row(r, brief) for r in reqs]
    if not brief:
        # a decline's reason is in the request dict already: it needs no call,
        # and so no deadline either
        def decline_note(r):
            st = r["el"].get("state") or {}
            return st.get("name") == "declined" and (st.get("comment") or "").strip()

        for r in rows:
            if "el" in r and decline_note(r):
                r["comment"] = human_comment(r["id"], r["el"].get("state"))
        detail = [r for r in rows if "el" in r and not decline_note(r)]
        for r, c in zip(
            detail,
            comments_for(
                detail, lambda r: human_comment(r["id"], r["el"].get("state"))
            ),
        ):
            r["comment"] = "(not fetched: --deadline reached)" if c is SKIPPED else c
        # a fix committed to the branch after filing reaches nobody: say so,
        # and sort it with the declines
        waiting = [r for r in rows if "el" in r and r["state"] in ("new", "review")]
        for r, s in zip(waiting, comments_for(waiting, staleness)):
            if s is SKIPPED:
                r["note"] = "; STALE not checked (--deadline reached)"
            elif s:
                r["note"] = f"; {s}"
                r["bad"] = r["bad"] or s.startswith(("STALE —", "STALE UNKNOWN"))

    # A decline that a later accepted request for the same package and target
    # replaced is cleanup, not done: geectl still counts it, and the next
    # `geectl request file` from that source prompts over it until it is
    # revoked. Only rows already fetched are compared (the default view holds
    # no accepted ones), so this costs no call.
    accepted = [r for r in rows if r["state"] == "accepted" and r["pkg"] != "?"]
    for r in rows:
        if r["state"] != "declined":
            continue
        later = [
            x["num"]
            for x in accepted
            if (x["pkg"], x["target"]) == (r["pkg"], r["target"])
            and x["num"] > r["num"]
        ]
        if later:
            n = min(later)
            r["note"] = (
                f"; later #{n} accepted — revoke: "
                f'geectl request revoke --comment "replaced by #{n}" {r["id"]} --live'
            )

    failed_legs, full_legs, prs = [], [], []
    if not a.ids and not a.no_prs:
        for leg in ("created", "review-requested"):
            got = fetch_prs(a.state, brief, leg)
            if got is None:
                failed_legs.append(leg)
                continue
            leg_rows, full = got
            for p in leg_rows:
                p["review"] = leg == "review-requested"
            prs.extend(leg_rows)
            if full:
                full_legs.append(leg)
    rows.extend(prs)

    if a.summary:
        summary(user, rows, prs, failed_legs, a.no_prs, a.days or 14)
        if full_legs:
            print(
                f"  (the {' and '.join(full_legs)} PR leg returned {PR_PAGE}, its page size: more may exist)"
            )
        return

    # declined SRs / closed-unmerged PRs first, then ids numeric descending-safe
    rows.sort(key=lambda r: (not r["bad"], r["num"]))

    scope = " (OBS SRs + src.opensuse.org PRs)"
    if failed_legs:
        scope = (
            " (OBS SRs; src.opensuse.org PRs UNKNOWN: the "
            f"{' and '.join(failed_legs)} leg failed, see stderr)"
        )
    shown = (
        f"{len(rows)} of {len(rows) + cut} shown — --limit 0 for all"
        if cut
        else f"{len(rows)} shown"
    )
    if full_legs:
        shown += f"; the {' and '.join(full_legs)} PR leg returned {PR_PAGE}, its page size: more may exist"
    print(
        f"### Submissions for `{user}` — {shown}"
        + ("" if a.no_prs or a.ids else scope)
        + "\n"
    )
    if a.brief:
        for r in rows:
            src = f"  {r.get('src', '')} ->" if r.get("src") else " "
            print(
                f"  {r['kind']} {r['id']}  [{(r['state'] or r['chain']) + r.get('note', ''):9}] {src} "
                f"{r['target']}"
                + (f"/{r['pkg']}" if r["kind"] == "SR" else "")
                + (f"  @{r['staging']}" if r.get("staging") else "")
            )
        return
    if a.format == "blocks":
        for r in rows:
            print(
                f"**{r['kind']} {r['id']} — {r['pkg']}**  {badge(r['state'])} "
                f"{r['state']}{r.get('note', '')}  ·  → `{r['target']}`"
            )
            for rv in r.get("reviews", []):
                print(f"- {review_full(rv)} {badge(rv.get('state', ''))}")
            if r["kind"] == "PR" and r["chain"] not in ("—", ""):
                print(f"- {r['chain']}")
            if r["comment"] and r["comment"] != "—":
                print(f"- {r['comment']}")
            print()
    else:
        print(
            "| Kind | ID | Package | Target | State | Review chain / PR status | Latest comment |"
        )
        print(
            "|------|----|---------|--------|-------|--------------------------|----------------|"
        )
        for r in rows:
            print(
                f"| {r['kind']} | {r['id']} | {r['pkg']} | {r['target']} | "
                f"{badge(r['state'])} {r['state']}{r.get('note', '')} | {r['chain']} | "
                f"{r['comment']} |"
            )
    print(
        "\n_Legend: ✅ accepted/merged · 🔎 review/open · ⏳ new/pending · "
        "❌ declined/closed-unmerged · 🚫 revoked · ♻️ superseded_"
    )


if __name__ == "__main__":
    main()
