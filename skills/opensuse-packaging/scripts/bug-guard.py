#!/usr/bin/env python3
"""bug-guard.py -- harness hook for the bugzilla MCP server's write tools.

Reads one tool-call event on stdin and prints a permission decision. One write
passes without a prompt: handing a security bug back to the security team once
your own Factory submit request fixes it. Every other write gets "ask" -- a
prompt in an interactive session, a refusal in a sub-agent that cannot show
one. A read tool gets no decision, so the harness's allow rules decide.

An assign_bug call is allowed only when all of these hold:
  - the assignee is security-team@suse.de;
  - the comment, 1-600 characters, cites exactly one request ("SR 123",
    "SR#123", "sr#123", "request 123");
  - that request (geectl request show N) was created by you, every action submits
    to openSUSE:Factory, its state is new, review or accepted, and factory-auto
    has accepted it (or the request is accepted);
  - a .changes file at the request's source revision has a line naming the
    bug (boo#, bsc# or bnc# and its id) that the target did not have before
    the request. It reads those files alone: a request's whole diff carries its
    tarballs and can take minutes.
The request ties the write to a submission only you can file, so text in a bug
cannot point the hand-back at another bug.

Usage: bug-guard.py < EVENT
  EVENT  the Claude Code PreToolUse JSON: {"tool_name": "mcp__bugzilla__<tool>",
         "tool_input": {...}}; the opencode plugin sends the same shape with
         "bugzilla_<tool>".

Environment:
  BUG_GUARD_OBS_USER  your OBS account (default: $GEECTL_OBS_USERNAME)

A failed or unreadable geectl lookup, lookups past 40 s in all, or a malformed
event answers "ask", never "allow". geectl authenticates itself; no credential
file is read.

Exit: 0 = answered (decision on stdout, none for a read tool) · 2 = usage
"""

import collections
import json
import os
import re
import signal
import subprocess
import sys

DEADLINE = 40
SECURITY = "security-team@suse.de"
TARGET = "openSUSE:Factory"
MAX_COMMENT = 600
READ = {
    "bugs_quicksearch",
    "quicksearch_syntax",
    "bug_info",
    "bug_comments",
    "bug_history",
    "summarize_bug",
    "bug_url",
    "list_attachments",
    "download_attachment",
    "bugzilla_server_info",
    "mcp_server_info",
}
PREFIXES = ("mcp__bugzilla__", "bugzilla_")
CITE = re.compile(r"(?i)\b(?:sr|request)\s*#?\s*(\d{4,})\b")


class Doubt(Exception):
    """Anything that keeps the hand-back from being proven: answer "ask"."""


def late(*_):
    raise Doubt(f"no verdict within {DEADLINE} s")


def geectl(*args, text=False, missing=None):
    """A geectl read: the parsed JSON payload, or the raw text when text;
    `missing` instead when OBS answers 404 and the caller allows it."""
    try:
        r = subprocess.run(
            ("geectl",) + args, capture_output=True, text=True, timeout=DEADLINE
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Doubt(f"geectl {args[0]} could not run ({type(e).__name__})")
    if r.returncode != 0:
        if missing is not None and r.returncode == 3:
            return missing
        raise Doubt(f"geectl {' '.join(args[:2])} failed (exit {r.returncode})")
    if text:
        return r.stdout
    try:
        return json.loads(r.stdout)
    except ValueError:
        raise Doubt(f"geectl {' '.join(args[:2])} did not parse")


def me():
    user = os.environ.get("BUG_GUARD_OBS_USER") or os.environ.get(
        "GEECTL_OBS_USERNAME", ""
    )
    user = user.strip()
    if not user:
        raise Doubt("cannot tell your OBS account")
    return user


def link_tag(data):
    """(project, package, rev) a _link file names, else None."""
    m = re.search(r"<link[^>]*project=\"([^\"]+)\"[^>]*package=\"([^\"]+)\"", data)
    if not m:
        return None
    rev = re.search(r"\brev=\"([^\"]+)\"", data)
    return m.group(1), m.group(2), rev.group(1) if rev else ""


def listing(prj, pkg, rev, depth=0):
    """(names, origin) of the package at rev: the .changes names of an
    expanded listing, and (project, package, rev) the files actually come
    from — the link target at its pin when the source is a _link, else the
    package itself. `remote list-files` never expands a link, so one is
    resolved by hand."""
    payload = geectl("remote", "list-files", prj, pkg, "--rev", str(rev))
    if not isinstance(payload, dict) or not isinstance(payload.get("files"), list):
        raise Doubt(f"the source listing of {prj}/{pkg} did not parse")
    names = [e.get("name") for e in payload["files"] if isinstance(e, dict)]
    if "_link" in names:
        if depth >= 5:
            raise Doubt(f"a _link chain past 5 in {prj}/{pkg}")
        tag = link_tag(
            geectl(
                "remote",
                "cat",
                "--rev",
                str(rev),
                "--format",
                "text",
                prj,
                pkg,
                "_link",
                text=True,
            )
        )
        if tag is None:
            raise Doubt(f"an unreadable _link in {prj}/{pkg}")
        tprj, tpkg, trev = tag
        return listing(tprj, tpkg, trev or rev, depth + 1)
    return names, (prj, pkg, rev)


def check_request(n, user):
    """The request, once it is yours, a submit to Factory and past factory-auto."""
    req = geectl("request", "show", n)
    if not isinstance(req, dict) or not isinstance(req.get("actions"), list):
        raise Doubt(f"request {n} did not parse")
    if str(req.get("id")) != n:
        raise Doubt(f"geectl answered for request {req.get('id')}, not {n}")
    if req.get("creator") != user:
        raise Doubt(f"request {n} is not yours")
    actions = req["actions"]
    if not actions or any(
        not isinstance(a, dict)
        or a.get("type") != "submit"
        or a.get("target_project") != TARGET
        for a in actions
    ):
        raise Doubt(f"request {n} is not a submit to {TARGET}")
    st = req.get("state") or {}
    state = st.get("name")
    if state not in ("new", "review", "accepted"):
        raise Doubt(f"request {n} is {state or 'in no state'}")
    passed = any(
        isinstance(r, dict)
        and r.get("by_user") == "factory-auto"
        and r.get("state") == "accepted"
        for r in req.get("reviews") or []
    )
    if state != "accepted" and not passed:
        raise Doubt(f"factory-auto has not passed request {n} yet")
    return req


def added_changes(req, n):
    """Every line the request's .changes files add over the target's before it."""
    added = []
    for a in req["actions"]:
        sprj, spkg, rev = (
            a.get("source_project"),
            a.get("source_package"),
            a.get("source_rev"),
        )
        if not (sprj and spkg and rev):
            raise Doubt(f"request {n} names no source revision")
        tpkg = a.get("target_package") or spkg
        info = a.get("acceptinfo") or {}
        orev = info.get("osrcmd5")
        names, (oprj, opkg, orev2) = listing(sprj, spkg, rev)
        for name in names:
            if not name.endswith(".changes"):
                continue
            new = geectl(
                "remote",
                "cat",
                "--rev",
                str(orev2),
                "--format",
                "text",
                oprj,
                opkg,
                name,
                text=True,
            )
            if info and not orev:  # accepted as a new package
                old = ""
            else:
                args = ["remote", "cat", "--format", "text", TARGET, tpkg, name]
                if orev:
                    args = [
                        "remote",
                        "cat",
                        "--rev",
                        orev,
                        "--format",
                        "text",
                        TARGET,
                        tpkg,
                        name,
                    ]
                old = geectl(*args, text=True, missing="")
            have = collections.Counter(old.splitlines())
            for line in new.splitlines():
                if have[line]:
                    have[line] -= 1
                else:
                    added.append(line)
    return added


def judge_assign(inp):
    if not isinstance(inp, dict):
        raise Doubt("assign_bug without input")
    bug, assignee, comment = inp.get("bug_id"), inp.get("assignee"), inp.get("comment")
    if isinstance(bug, str) and bug.isdigit():
        bug = int(bug)
    if not isinstance(bug, int) or isinstance(bug, bool) or bug <= 0:
        raise Doubt("no bug id")
    if assignee != SECURITY:
        raise Doubt(f"only a hand-back to {SECURITY} passes unasked")
    if not isinstance(comment, str) or not comment.strip():
        raise Doubt("a hand-back carries its comment")
    if len(comment) > MAX_COMMENT:
        raise Doubt(f"the comment is over {MAX_COMMENT} characters")
    cited = set(CITE.findall(comment))
    if len(cited) != 1:
        raise Doubt("the comment must cite exactly one submit request")
    n = cited.pop()
    req = check_request(n, me())
    pat = re.compile(rf"\b(?:boo|bsc|bnc)#{bug}\b")
    if not any(pat.search(line) for line in added_changes(req, n)):
        raise Doubt(f"request {n} adds no .changes line citing boo#{bug}")
    return f"hand-back of boo#{bug} for your Factory request {n} verified"


def decide(ev):
    """None for a call it has no say in, else (decision, reason)."""
    if not isinstance(ev, dict) or not isinstance(ev.get("tool_name"), str):
        return "ask", "the event did not parse"
    name = ev["tool_name"]
    tool = next((name[len(p) :] for p in PREFIXES if name.startswith(p)), None)
    if tool is None or tool in READ:
        return None
    if tool != "assign_bug":
        return "ask", f"{tool} is a bugzilla write"
    return "allow", judge_assign(ev.get("tool_input"))


def main(argv):
    if argv[1:2] in (["-h"], ["--help"]):
        print(__doc__.strip())
        return 0
    if len(argv) > 1:
        sys.stderr.write("usage: bug-guard.py < EVENT (see --help)\n")
        return 2
    signal.signal(signal.SIGALRM, late)
    signal.alarm(DEADLINE)
    try:
        try:
            ev = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
        except ValueError:
            ev = None
        verdict = decide(ev)
    except Doubt as e:
        verdict = ("ask", str(e))
    except Exception as e:  # never "allow" on a failure of its own
        verdict = ("ask", f"the guard failed ({type(e).__name__})")
    finally:
        signal.alarm(0)
    if verdict is None:
        return 0
    decision, why = verdict
    if decision == "ask":
        why += "; this write needs your go"
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": "bug-guard: " + why,
        }
    }
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
