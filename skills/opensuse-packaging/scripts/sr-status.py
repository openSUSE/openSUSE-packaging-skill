#!/usr/bin/env python3
"""Combined submission-status view: OBS submit requests AND src.opensuse.org
(Gitea) pull requests in ONE table — overall state, the review chain (SRs) /
merge+bot-build status (PRs), and human comments. Reused by Block 3
(submit / watch); satisfies the "status of my submissions = OBS SRs AND Gitea
PRs, declines flagged first" rule in one call.

Renders a Markdown table (so it looks nice in a chat/terminal that renders MD).

Usage:
  sr-status.py [--user U] [--state open|all|declined|accepted] [--target PRJ]
               [--limit N] [--format table|blocks] [--brief] [--summary]
               [--no-prs] [ID ...]
  sr-status.py --pr pool/<pkg>#<n>
    ID ...      specific OBS request ids (overrides discovery; skips the PR leg)
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
                any later request for that package, the oldest new request, and
                comments by others since your last action (one call per open SR)
    --no-prs    skip the src.opensuse.org PR leg (OBS-only view)
    --user      OBS account (default: `osc whois`)

The PR leg reads src.opensuse.org through `git-obs -G src.opensuse.org api`.
git-obs reads its login itself (shared with tea by default); this script never
reads it. -G picks the login named src.opensuse.org, or the only one for that
host (`git-obs login add`), so a default login for another forge is never
used. If that fails it warns and falls back to the OBS-only table, and the
header says the PRs are UNKNOWN. Two sub-legs, both always run: PRs you
created, and PRs awaiting your review. `--no-prs` skips both. Every osc /
git-obs call times out after 60s and then counts as a failed lookup (a network
failure for --pr), never as an empty answer.

A declined SR that a later accepted one for the same package and target
replaced is annotated with the revoke that clears it and stays at the top:
osc still counts a declined request, so the next `osc sr` from that source
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
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _sanitize  # escape/Unicode-smuggling filter for third-party text

# seconds per osc / git-obs call: both have hung for good, and a harness
# gives the whole tool call 2 minutes, so the timeout must come first
TIMEOUT = 60


def run(cmd):
    """subprocess.run with TIMEOUT. A call that times out, or whose binary is
    missing, comes back as a failed one (rc 124 / 127, as in the shell) and is
    reported like any other."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            cmd, 124, "", f"{cmd[0]} timed out after {TIMEOUT}s"
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 127, "", f"{cmd[0]}: command not found")


def api(path, hard=True, errors=None):
    """osc api wrapper. hard=True: exit 2 on failure (discovery must not
    silently become '0 shown'). hard=False: return None so the caller can emit
    a visible FETCH FAILED row instead of a garbage one."""
    return osc(["api", path], hard, errors)


def osc(args, hard=True, errors=None):
    """Run osc; a failure's text is appended to `errors` so --pr can tell a
    network failure from a refusal or a missing object."""
    r = run(["osc", *args])
    if r.returncode != 0:
        msg = f"osc {' '.join(args)} failed (rc={r.returncode}): {r.stderr.strip()}"
        sys.stderr.write(f"ERROR: {msg}\n")
        if errors is not None:
            errors.append(msg)
        if hard:
            sys.exit(2)
        return None
    return r.stdout or ""


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
# logins whose comments are bot noise, not human feedback
BOTS = (
    "factory-auto",
    "licensedigger",
    "repo-checker",
    "staging-bot",
    "_obs_",
    "autogits",
)


def is_bot(who):
    w = (who or "").lower()
    return any(b in w for b in BOTS) or "bot" in w or w.startswith("_")


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


def human_comment(req_id, state_el):
    # declined: the decline reason on the state element is the salient human note
    if state_el is not None and state_el.get("name") == "declined":
        c = state_el.findtext("comment")
        who = state_el.get("who", "?")
        if c and c.strip():
            return f'💬 {who}: "{clip(c)}"'
    # otherwise the latest non-bot comment in the thread
    raw = api(f"/comments/request/{req_id}", hard=False)
    if raw is None:
        return "(comment fetch failed)"
    try:
        root = ET.fromstring(raw or "<comments/>")
    except ET.ParseError:
        return "—"
    cmts = [c for c in root.findall("comment") if not is_bot(c.get("who"))]
    if not cmts:
        return "—"
    last = cmts[-1]
    return f'💬 {last.get("who", "?")}: "{clip(last.text)}"'


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


def build_results(xml, pkg):
    """(red, pending, succeeded, skipped) from `osc results --xml`, excluded
    and disabled arches counted in skipped; None when unparsable. succeeded
    maps each label to its <repo>/<arch>/<package> build path. A dirty
    repository's codes are outdated, so they count as pending whatever they
    say."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return None
    red, pending, ok, skipped = [], [], {}, 0
    for res in root.findall("result"):
        where = f"{res.get('repository')}/{res.get('arch')}"
        for s in res.findall("status"):
            p = s.get("package", "")
            if p != pkg and not p.startswith(pkg + ":"):
                continue
            code = s.get("code", "unknown")
            label = f"{where}{p[len(pkg) :]} {code}"
            if res.get("dirty") is not None:
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
    could not be read."""
    src = api(f"/source/{prj}/{pkg}?expand=1", hard=False, errors=errors)
    try:
        cur = ET.fromstring(src).get("srcmd5") if src is not None else None
    except ET.ParseError:
        cur = None
    if not cur:
        return None, f"the {prj}/{pkg} srcmd5"
    older = []
    for label, path in ok.items():
        what = f"the {prj}/{path} job history"
        # The last job, not _history: an unchanged rebuild adds no entry there.
        where, name = path.rsplit("/", 1)
        url = f"/build/{prj}/{where}/_jobhistory?package={name}&limit=1"
        hist = api(url, hard=False, errors=errors)
        if hist is None:
            return None, what
        try:
            jobs = ET.fromstring(hist).findall("jobhist")
        except ET.ParseError:
            return None, what
        got = jobs[-1].get("srcmd5", "") if jobs else ""
        if got != cur:
            built = got[:12] or "nothing recorded"
            older.append(f"{label} (built {built}, sources {cur[:12]})")
    return older, None


def pin_of(prj, pkg, num, errors):
    """The products PR whose branch the PR project builds, and whose branch
    it is: the bot's PR_<pkg>#<n> follows pushes, a hand-made one does not.
    Returns (detail, short, advice)."""
    meta = api(f"/source/{prj}/_meta", hard=False, errors=errors)
    url = ""
    if meta:
        try:
            url = ET.fromstring(meta).findtext("url") or ""
        except ET.ParseError:
            pass
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
    info = api(f"/source/{prj}/{pkg}/_scmsync.obsinfo", hard=False, errors=errors)
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
    xml = osc(["results", "--xml", prj, pkg], hard=False, errors=errors)
    got = build_results(xml, pkg) if xml is not None else None
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


PR_PAGE = 50  # src.opensuse.org's page size for issues/search


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
            }
        )
    return rows, len(issues) >= PR_PAGE


# ---------- OBS request rows ----------

SEARCH_CHUNK = 50  # ids per /search/request call, to keep the URL short


def sr_row(req, brief):
    """One table/brief row from a request element of a collection or search
    result: both already carry the state, actions and reviews, so no per-item
    call is needed for anything but the comments."""
    st = req.find("state")
    sname = st.get("name") if st is not None else ""
    act = req.find("action")
    tgt = act.find("target") if act is not None else None
    src = act.find("source") if act is not None else None
    reviews = req.findall("review")
    # staging assignment is free here — the reviews are in the XML already
    stg = ""
    for rv in reviews:
        if rv.get("state") == "new":
            by = rv.get("by_project") or ""
            if "Staging" in by:
                parts = by.split(":")
                # ...Staging:adi:40 -> adi:40, ...Staging:G -> G
                stg = parts[-1] if parts[-2] == "Staging" else ":".join(parts[-2:])
    rid = req.get("id", "?")
    row = {
        "kind": "SR",
        "id": rid,
        "num": int(rid) if rid.isdigit() else 0,
        "pkg": tgt.get("package") if tgt is not None else "?",
        "target": tgt.get("project") if tgt is not None else "?",
        "state": sname,
        "chain": "—",
        "comment": "—",
        "bad": sname == "declined",
        "el": req,
    }
    if brief:
        row["src"] = (
            f"{src.get('project')}/{src.get('package')}" if src is not None else "?"
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


def failed_row(rid, why):
    return {
        "kind": "SR",
        "id": rid,
        "num": int(rid) if rid.isdigit() else 0,
        "pkg": "?",
        "target": "?",
        "state": "",
        "chain": why,
        "comment": "(see stderr)",
        "bad": True,
    }


def fetch_ids(ids):
    """The requests behind explicit ids, SEARCH_CHUNK per search call: one
    call per id timed out on 40 ids. Returns {id: element}; an id missing
    from the answer is absent, a failed chunk maps its ids to None."""
    got = {}
    for i in range(0, len(ids), SEARCH_CHUNK):
        chunk = ids[i : i + SEARCH_CHUNK]
        match = "+or+".join(f"@id={rid}" for rid in chunk)
        raw = api(f"/search/request?match={match}", hard=False)
        try:
            root = ET.fromstring(raw) if raw is not None else None
        except ET.ParseError:
            root = None
        if root is None:
            got.update({rid: None for rid in chunk})
            continue
        for r in root.findall("request"):
            got[r.get("id")] = r
    return got


def comments_for(rows, fn):
    """fn(row) for every row, 8 at a time: comments are one call per request."""
    with ThreadPoolExecutor(max_workers=8) as ex:
        return list(ex.map(fn, rows))


# ---------- --summary ----------


def norm_time(s):
    """OBS writes 2026-10-19T05:09:04 in request XML and
    2026-10-19 05:09:04 UTC in comments; both become comparable text."""
    return (s or "").replace("T", " ").replace(" UTC", "")[:19]


def created(row):
    st = row["el"].find("state")
    return norm_time(st.get("created")) if st is not None else ""


def later_requests(row):
    """Requests filed after a decline for the same target package, by anyone:
    whether someone already handled it. One call per decline."""
    q = (
        "/request?view=collection&types=submit&states=new,review,accepted"
        f"&project={row['target']}&package={row['pkg']}"
    )
    raw = api(q, hard=False)
    try:
        root = ET.fromstring(raw) if raw is not None else None
    except ET.ParseError:
        root = None
    if root is None:
        return None
    later = []
    for r in root.findall("request"):
        rid = r.get("id", "")
        if rid.isdigit() and int(rid) > row["num"]:
            st = r.find("state")
            later.append(
                (int(rid), st.get("name") if st is not None else "?", r.get("creator"))
            )
    return sorted(later)


def others_comments(row, user):
    """Non-bot comments by someone other than `user` newer than the user's last
    action on the request (its creation, a history entry, or an own comment).
    Returns a list of (when, who, text), or None when the fetch failed."""
    req = row["el"]
    mine = [created(row)]
    mine += [
        norm_time(h.get("when")) for h in req.iter("history") if h.get("who") == user
    ]
    raw = api(f"/comments/request/{row['id']}", hard=False)
    try:
        root = ET.fromstring(raw) if raw is not None else None
    except ET.ParseError:
        root = None
    if root is None:
        return None
    cmts = root.findall("comment")
    mine += [norm_time(c.get("when")) for c in cmts if c.get("who") == user]
    last = max(mine) if mine else ""
    return [
        (norm_time(c.get("when")), c.get("who", "?"), c.text)
        for c in cmts
        if c.get("who") != user
        and not is_bot(c.get("who"))
        and norm_time(c.get("when")) > last
    ]


def summary(user, rows, prs, failed_legs, no_prs):
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
    new = [r for r in srs if r["state"] == "new"]
    if new:
        old = min(new, key=created)
        when = created(old)
        try:
            then = datetime.datetime.strptime(when, "%Y-%m-%d %H:%M:%S")
            now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
            age = f", {(now - then).days} days ago"
        except ValueError:
            age = ""
        print(
            f"oldest new: SR {old['id']} {old['pkg']} -> {old['target']} (created {when[:10]}{age})"
        )
    declined = [r for r in srs if r["state"] == "declined"]
    if declined:
        print(f"\ndeclined ({len(declined)}):")
        for r, later in zip(declined, comments_for(declined, later_requests)):
            st = r["el"].find("state")
            who = clip(st.get("who", "?") if st is not None else "?", 40)
            why = clip((st.findtext("comment") if st is not None else "") or "", 120)
            if later is None:
                after = "later requests UNKNOWN (lookup failed)"
            elif later:
                after = "; ".join(
                    f"later #{n} {s} by {clip(c or '?', 40)}" for n, s, c in later
                )
            else:
                after = "nothing filed there since"
            print(
                f'  SR {r["id"]} {r["pkg"]} -> {r["target"]} by {who}: "{why}" — {after}'
            )
    open_srs = [r for r in srs if r["state"] in ("new", "review", "declined")]
    found = comments_for(open_srs, lambda r: others_comments(r, user))
    unknown = [r for r, c in zip(open_srs, found) if c is None]
    news = [(r, c) for r, c in zip(open_srs, found) if c]
    print(
        f"\ncomments by others since your last action: {len(news)} request(s)"
        + (f", {len(unknown)} UNKNOWN (comment fetch failed)" if unknown else "")
    )
    for r, cs in news:
        when, who, text = cs[-1]
        more = f" (+{len(cs) - 1} more)" if len(cs) > 1 else ""
        print(
            f'  SR {r["id"]} {r["pkg"]} -> {r["target"]} {clip(who, 40)} {when[:10]}: "{clip(text, 100)}"{more}'
        )
    for r in unknown:
        print(
            f"  SR {r['id']} {r['pkg']} -> {r['target']} UNKNOWN (comment fetch failed)"
        )
    if not no_prs:
        if failed_legs:
            print(
                f"\nsrc.opensuse.org PRs UNKNOWN: the {' and '.join(failed_legs)} leg failed, see stderr"
            )
        else:
            mine = [p for p in prs if not p.get("review")]
            asked = [p for p in prs if p.get("review")]
            print(
                f"\nsrc.opensuse.org PRs: {len(mine)} yours, {len(asked)} awaiting your review"
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
        "--no-prs", action="store_true", help="skip the src.opensuse.org PR leg"
    )
    ap.add_argument(
        "--pr",
        metavar="OWNER/REPO#N",
        help="one PR's staging-bot OBS build verdict, e.g. pool/pkg#3",
    )
    a = ap.parse_args()
    if a.pr:
        m = re.fullmatch(r"([\w.+-]+/[\w.+-]+)#(\d+)", a.pr)
        if not m or a.ids:
            ap.error("--pr takes OWNER/REPO#N and no request ids")
        sys.exit(pr_mode(m[1], m[2]))
    if a.summary and a.ids:
        ap.error("--summary takes no request ids")
    if a.limit is not None and a.limit < 0:
        ap.error("--limit takes 0 (no cap) or a positive number")
    limit = a.limit if a.limit is not None else (0 if a.brief or a.summary else 40)
    w = run(["osc", "whois"])
    user = a.user or w.stdout.split(":")[0].strip()
    if not user:
        sys.stderr.write(
            f"ERROR: could not determine OBS user (osc whois rc="
            f"{w.returncode}: {w.stderr.strip()}) — pass --user\n"
        )
        sys.exit(2)

    brief = a.brief or a.summary
    rows, cut = [], 0
    if a.ids:
        got = fetch_ids(a.ids)
        for rid in a.ids:
            if rid not in got:
                rows.append(failed_row(rid, "NOT FOUND"))
            elif got[rid] is None:
                rows.append(failed_row(rid, "FETCH FAILED"))
            else:
                rows.append(sr_row(got[rid], brief))
    else:
        # "open" means "still needs something from you", so it MUST include
        # declined: a decline is the single most actionable state a request of
        # yours can be in (it needs a fix + supersede, or a revoke), and it is
        # what the declines-first sort below exists to surface. Leaving it out
        # made the default view silently hide exactly the rows worth reading.
        states = {
            "open": "new,review,declined",
            "all": "new,review,declined,accepted,revoked,superseded",
        }.get(a.state, a.state)
        q = f"/request?view=collection&states={states}&roles=creator&user={user}&types=submit"
        if a.target:
            q += f"&project={a.target}"
        col = ET.fromstring(api(q) or "<collection/>")  # api() exits 2 on failure
        reqs = col.findall("request")
        if limit and len(reqs) > limit:
            # the cap only saves the comment calls: keep every decline, then the
            # newest of the rest — a silent cut of the oldest once hid a decline
            def declined(r):
                st = r.find("state")
                return st is not None and st.get("name") == "declined"

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
        detail = [r for r in rows if "el" in r]
        for r, c in zip(
            detail,
            comments_for(
                detail, lambda r: human_comment(r["id"], r["el"].find("state"))
            ),
        ):
            r["comment"] = c

    # A decline that a later accepted request for the same package and target
    # replaced is cleanup, not done: osc still counts it, and the next `osc sr`
    # from that source prompts over it until it is revoked. Only rows already
    # fetched are compared (the default view holds no accepted ones), so this
    # costs no call.
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
                f'osc rq revoke -m "replaced by #{n}" {r["id"]}'
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
        summary(user, rows, prs, failed_legs, a.no_prs)
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
                f"  {r['kind']} {r['id']}  [{r['state'] + r.get('note', ''):9}] {src} "
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
