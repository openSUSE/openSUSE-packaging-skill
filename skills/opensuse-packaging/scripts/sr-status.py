#!/usr/bin/env python3
"""Combined submission-status view: OBS submit requests AND src.opensuse.org
(Gitea) pull requests in ONE table — overall state, the review chain (SRs) /
merge+bot-build status (PRs), and human comments. Reused by Block 3
(submit / watch); satisfies the "status of my submissions = OBS SRs AND Gitea
PRs, declines flagged first" rule in one call.

Renders a Markdown table (so it looks nice in a chat/terminal that renders MD).

Usage:
  sr-status.py [--user U] [--state open|all|declined|accepted] [--target PRJ]
               [--limit N] [--format table|blocks] [--brief] [--no-prs] [ID ...]
  sr-status.py --pr pool/<pkg>#<n>
    ID ...      specific OBS request ids (overrides discovery; skips the PR leg)
    --pr        one PR's staging-bot build verdict, as an exit code
    --state     which of your creator SRs/PRs to show (default: open = new,review,declined)
    --target    restrict SR discovery to a target project (e.g. openSUSE:Factory)
    --limit     cap discovered SRs (most recent first); each costs 2 API calls
    --format    table = one row per item; blocks = per-item bullets
    --brief     discovery list only (id, package, target, state) — NO per-item
                review/comment API calls (this is what my-requests.sh wraps)
    --no-prs    skip the src.opensuse.org PR leg (OBS-only view)
    --user      OBS account (default: `osc whois`)

The PR leg needs a src.opensuse.org login; if unavailable it warns and falls
back to the OBS-only table. Direct token+urllib (~/.config/tea/config.yml) is
tried first; falls back to `git-obs api` if no pyyaml/token (needs a default
login: `git-obs login add`, then `git-obs login update <name>
--set-as-default`). Two sub-legs, both always run: PRs you created, and PRs
awaiting your review. `--no-prs` skips both.

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
import urllib.request
import urllib.error
import os
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _sanitize  # escape/Unicode-smuggling filter for third-party text

GITEA = "https://src.opensuse.org/api/v1"


def api(path, hard=True, errors=None):
    """osc api wrapper. hard=True: exit 2 on failure (discovery must not
    silently become '0 shown'). hard=False: return None so the caller can emit
    a visible FETCH FAILED row instead of a garbage one."""
    return osc(["api", path], hard, errors)


def osc(args, hard=True, errors=None):
    """Run osc; a failure's text is appended to `errors` so --pr can tell a
    network failure from a refusal or a missing object."""
    r = subprocess.run(["osc", *args], capture_output=True, text=True)
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
# Primary: direct token+urllib. Fallback: `git-obs api` (own auth, no pyyaml).


def tea_login():
    """Token + username from ~/.config/tea/config.yml (same loader pattern as
    leap-sync.sh). Returns (token, user) or (None, None)."""
    try:
        import yaml

        c = yaml.safe_load(open(os.path.expanduser("~/.config/tea/config.yml")))
        for login in c.get("logins", []):
            if login.get("name") == "src.opensuse.org":
                return login.get("token"), login.get("user")
    except Exception as e:
        sys.stderr.write(
            f"WARNING: no usable tea login ({e.__class__.__name__}: {e})\n"
        )
    return None, None


_TEA_TOKEN, _TEA_USER = tea_login()


def _gitea_get_urllib(path, tok):
    req = urllib.request.Request(
        GITEA + path, headers={"Authorization": f"token {tok}"}
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())


def _gitea_get_git_obs(path, errors=None):
    """Fallback: `git-obs api <path>` — strips the leading 'Response:' banner
    line and parses JSON. Returns None on any failure (missing/non-default
    login, network, bad JSON) so the caller can emit a FETCH FAILED row."""
    r = subprocess.run(["git-obs", "-q", "api", path], capture_output=True, text=True)
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


def gitea_get(path, errors=None):
    """Direct token+urllib first; falls back to `git-obs api` if there's no
    usable tea token or the direct call fails. Returns None if both fail,
    with each failure's text appended to `errors`."""
    if _TEA_TOKEN:
        try:
            return _gitea_get_urllib(path, _TEA_TOKEN)
        except (urllib.error.URLError, OSError, ValueError) as e:
            sys.stderr.write(
                f"WARNING: direct src.opensuse.org fetch failed ({e}) "
                f"— falling back to git-obs\n"
            )
            if errors is not None:
                errors.append(str(e))
    return _gitea_get_git_obs(path, errors)


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
        what = f"the {prj}/{path} build history"
        hist = api(f"/build/{prj}/{path}/_history?limit=1", hard=False, errors=errors)
        if hist is None:
            return None, what
        try:
            entries = ET.fromstring(hist).findall("entry")
        except ET.ParseError:
            return None, what
        got = entries[-1].get("srcmd5", "") if entries else ""
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


def fetch_prs(state, brief, leg):
    """One issues/search call for the user's PRs (leg='created') or PRs
    awaiting the user's review (leg='review-requested'); per-PR detail
    (base branch, mergeable, bot-build + human comments) only in full mode.
    Returns a list of row dicts, or None on failure (caller falls back)."""
    q_state = "open" if state == "open" else "all"
    issues = gitea_get(
        f"/repos/issues/search?type=pulls&{leg.replace('-', '_')}=true"
        f"&state={q_state}&limit=50"
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
    return rows


# ---------- main ----------


def main():
    ap = argparse.ArgumentParser(
        epilog="Exit:\n"
        "  0 = printed (a PR-leg failure only warns); --pr: green at the PR head, "
        "or merged\n"
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
        default=40,
        help="cap discovered SRs (most recent first); each costs 2 API calls",
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
    w = subprocess.run(["osc", "whois"], capture_output=True, text=True)
    user = a.user or w.stdout.split(":")[0].strip()
    if not user:
        sys.stderr.write(
            f"ERROR: could not determine OBS user (osc whois rc="
            f"{w.returncode}: {w.stderr.strip()}) — pass --user\n"
        )
        sys.exit(2)

    rows = []
    ids = a.ids
    if not ids:
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
        if a.limit and len(reqs) > a.limit:
            reqs = sorted(reqs, key=lambda r: int(r.get("id", 0)), reverse=True)[
                : a.limit
            ]
        if a.brief:
            for r in reqs:
                st = r.find("state")
                act = r.find("action")
                tgt = act.find("target") if act is not None else None
                src = act.find("source") if act is not None else None
                sname = st.get("name") if st is not None else "?"
                # staging assignment is free here — the collection XML already
                # carries the reviews, so no per-item API call is needed
                stg = ""
                for rv in r.findall("review"):
                    if rv.get("state") == "new":
                        by = rv.get("by_project") or ""
                        if "Staging" in by:
                            parts = by.split(":")
                            # ...Staging:adi:40 -> adi:40, ...Staging:G -> G
                            stg = (
                                parts[-1]
                                if parts[-2] == "Staging"
                                else ":".join(parts[-2:])
                            )
                rows.append(
                    {
                        "kind": "SR",
                        "id": r.get("id"),
                        "num": int(r.get("id", 0)),
                        "pkg": tgt.get("package") if tgt is not None else "?",
                        "target": (tgt.get("project") if tgt is not None else "?"),
                        "src": (
                            f"{src.get('project')}/{src.get('package')}"
                            if src is not None
                            else "?"
                        ),
                        "state": sname,
                        "staging": stg,
                        "chain": "—",
                        "comment": "—",
                        "bad": sname == "declined",
                    }
                )
        else:
            ids = [r.get("id") for r in reqs]
    if ids:
        for rid in ids:
            raw = api(f"/request/{rid}", hard=False)
            if raw is None:
                rows.append(
                    {
                        "kind": "SR",
                        "id": rid,
                        "num": int(rid) if rid.isdigit() else 0,
                        "pkg": "?",
                        "target": "?",
                        "state": "",
                        "chain": "FETCH FAILED",
                        "comment": "(see stderr)",
                        "bad": True,
                    }
                )
                continue
            req = ET.fromstring(raw or "<request/>")
            st = req.find("state")
            sname = st.get("name") if st is not None else ""
            act = req.find("action")
            tgt = act.find("target") if act is not None else None
            reviews = req.findall("review")
            chain = (
                " ".join(
                    f"{review_label(rv)}{badge(rv.get('state', ''))}" for rv in reviews
                )
                or "—"
            )
            rows.append(
                {
                    "kind": "SR",
                    "id": rid,
                    "num": int(rid) if str(rid).isdigit() else 0,
                    "pkg": tgt.get("package") if tgt is not None else "?",
                    "target": tgt.get("project") if tgt is not None else "?",
                    "state": sname,
                    "chain": chain,
                    "reviews": reviews,
                    "comment": human_comment(rid, st),
                    "bad": sname == "declined",
                }
            )

    if not a.ids and not a.no_prs:
        for leg in ("created", "review-requested"):
            prs = fetch_prs(a.state, a.brief, leg)
            if prs:
                rows.extend(prs)

    # declined SRs / closed-unmerged PRs first, then ids numeric descending-safe
    rows.sort(key=lambda r: (not r["bad"], r["num"]))

    print(
        f"### Submissions for `{user}` — {len(rows)} shown"
        + ("" if a.no_prs or a.ids else " (OBS SRs + src.opensuse.org PRs)")
        + "\n"
    )
    if a.brief:
        for r in rows:
            src = f"  {r.get('src', '')} ->" if r.get("src") else " "
            print(
                f"  {r['kind']} {r['id']}  [{r['state']:9}] {src} {r['target']}"
                + (f"/{r['pkg']}" if r["kind"] == "SR" else "")
                + (f"  @{r['staging']}" if r.get("staging") else "")
            )
        return
    if a.format == "blocks":
        for r in rows:
            print(
                f"**{r['kind']} {r['id']} — {r['pkg']}**  {badge(r['state'])} "
                f"{r['state']}  ·  → `{r['target']}`"
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
                f"{badge(r['state'])} {r['state']} | {r['chain']} | {r['comment']} |"
            )
    print(
        "\n_Legend: ✅ accepted/merged · 🔎 review/open · ⏳ new/pending · "
        "❌ declined/closed-unmerged · 🚫 revoked · ♻️ superseded_"
    )


if __name__ == "__main__":
    main()
