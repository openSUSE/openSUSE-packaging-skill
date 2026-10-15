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
  - that request (osc api /request/N) was created by you, every action submits
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
  BUG_GUARD_OBS_USER  your OBS account (default: osc whois)

A failed or unreadable osc lookup, lookups past 40 s in all, or a malformed
event answers "ask", never "allow". osc authenticates itself; no credential
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
import urllib.parse
import xml.etree.ElementTree as ET

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


def osc(*args, missing=None):
    """osc's stdout; `missing` instead when OBS answers 404 and the caller allows it."""
    try:
        r = subprocess.run(
            ("osc",) + args, capture_output=True, text=True, timeout=DEADLINE
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Doubt(f"osc {args[0]} could not run ({type(e).__name__})")
    if r.returncode != 0:
        if missing is not None and "HTTP Error 404" in r.stderr:
            return missing
        raise Doubt(f"osc {' '.join(args[:2])} failed (exit {r.returncode})")
    return r.stdout


def me():
    user = os.environ.get("BUG_GUARD_OBS_USER") or osc("whois").split(":", 1)[0]
    user = user.strip()
    if not user:
        raise Doubt("cannot tell your OBS account")
    return user


def check_request(n, user):
    """The request's XML, once it is yours, a submit to Factory and past factory-auto."""
    try:
        req = ET.fromstring(osc("api", f"/request/{n}"))
    except ET.ParseError:
        raise Doubt(f"request {n} did not parse")
    if req.get("id") != n:
        raise Doubt(f"osc answered for request {req.get('id')}, not {n}")
    if req.get("creator") != user:
        raise Doubt(f"request {n} is not yours")
    actions = req.findall("action")
    if not actions or any(
        a.get("type") != "submit"
        or (a.find("target") is None)
        or a.find("target").get("project") != TARGET
        for a in actions
    ):
        raise Doubt(f"request {n} is not a submit to {TARGET}")
    st = req.find("state")
    state = st.get("name") if st is not None else None
    if state not in ("new", "review", "accepted"):
        raise Doubt(f"request {n} is {state or 'in no state'}")
    passed = any(
        r.get("by_user") == "factory-auto" and r.get("state") == "accepted"
        for r in req.findall("review")
    )
    if state != "accepted" and not passed:
        raise Doubt(f"factory-auto has not passed request {n} yet")
    return req


def path(*parts):
    return "/source/" + "/".join(urllib.parse.quote(p, safe=":+") for p in parts)


def added_changes(req, n):
    """Every line the request's .changes files add over the target's before it."""
    added = []
    for a in req.findall("action"):
        src, tgt = a.find("source"), a.find("target")
        sprj, spkg, rev = (
            src.get(k) if src is not None else None
            for k in ("project", "package", "rev")
        )
        if not (sprj and spkg and rev):
            raise Doubt(f"request {n} names no source revision")
        tpkg = tgt.get("package") or spkg
        info = a.find("acceptinfo")
        orev = info.get("osrcmd5") if info is not None else None
        rq = "?rev=" + urllib.parse.quote(rev) + "&expand=1"
        try:
            listing = ET.fromstring(osc("api", path(sprj, spkg) + rq))
        except ET.ParseError:
            raise Doubt(f"the source listing of request {n} did not parse")
        for e in listing.findall("entry"):
            name = e.get("name") or ""
            if not name.endswith(".changes"):
                continue
            new = osc("api", path(sprj, spkg, name) + rq)
            if info is not None and not orev:  # accepted as a new package
                old = ""
            else:
                old = osc(
                    "api",
                    path(TARGET, tpkg, name)
                    + ("?rev=" + urllib.parse.quote(orev) if orev else ""),
                    missing="",
                )
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
