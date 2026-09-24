#!/usr/bin/env python3
"""pr-guard.py -- harness guard for pool/ pull requests on src.opensuse.org.

Reads one tool-call event on stdin and refuses (exit 2) a call that would open,
update or merge a pool/ PR outside pool-pr.sh, push to a branch that heads an
open pool PR, write a target-gate.sh stamp, run an emulated osc build, or file a
request against the scmsync'd openSUSE:Backports:SLE-16.x projects. Its rules
live in _pr_guard.py beside it, read only once a call matches the prefilter.

A command line is judged one parsed command at a time, so what a command only
carries -- a commit message, a grep pattern, an echo -- is not read as a
command. Program text is read whole: every script a command runs (its path
expanded from what the call assigns, $PWD, $TMPDIR, $HOME and globs), inline
code (-c, -e), and text fed to a shell or interpreter (heredoc, here-string,
< FILE, a pipe from echo, printf or cat). A script the same call writes is not
run: its content is not known yet. The scripts in the skill checkout's scripts/
run unread only when run by path, while every file scripts/ tracks is
byte-identical to its blob at the pinned ref (as merged, not as edited
locally), with no environment change but TMPDIR, LC_ALL, LANG and NO_COLOR.

Usage: pr-guard.py < EVENT
  EVENT  the Claude Code PreToolUse JSON: {"tool_name", "cwd", "tool_input":
         {"command"} or {"file_path", "content" | "new_string"}}; the opencode
         plugin maps its tool arguments into the same shape.

Environment:
  PR_GUARD_SKILL_DIR  the skill checkout (default ~/.claude/skills/opensuse-packaging,
                      then ~/.agents/skills/opensuse-packaging)
  PR_GUARD_PIN_REF    the ref the skill's scripts must match to run unread
                      (default refs/remotes/origin/main)
  PR_GUARD_ARCH       the native architecture (default: this machine's)
  PR_GUARD_PULLS_DIR  offline stand-in for the open-PR lookup, for tests: <repo>.json
                      holds the Gitea response, a missing file reads as a 404

A call that matches nothing guarded is allowed without a lookup. Once one
matches, anything the guard cannot establish -- a remote, branch or repository
held in a variable, a failed PR lookup, an unreadable script or stdin program, a
script path it cannot expand, a malformed event, a missing _pr_guard.py --
refuses the call.

Exit: 0 = allowed · 2 = refused, reason on stderr
"""

# Only what the prefilter needs is loaded up front: most calls stop at it, and
# must cost little more than the interpreter's start.
import json
import os
import re
import sys

# No match, no analysis. The opencode plugin carries a verbatim copy so it
# spawns this guard only on a match; tests/test-pr-guard.sh compares the two.
# Any path matches, because a file a command runs is where a POST hides.
PREFILTER = re.compile(
    r"\/|tea\b|git-obs|\bgit\b[^\n;&|]*\bobs\b|src\.opensuse\.org|\bpush\b|\bosc\b"
    r"|\b(?:python[0-9.]*|bash|sh|zsh|dash|ksh|node|perl|source|env|uv|eval)\b"
    r"|(?:^|[\s;&|(])\.\s|\bsend-pack\b|\btarget-gate\b"
)
# A call run inside the stamp directory is judged whatever it says. Two pieces:
# the guard reads this file too when a call runs it.
STAMP_DIR = "target-" + "gate"


def text_of(ev):
    """What the prefilter reads: the command, or the file and what goes in it."""
    inp = ev.get("tool_input") if isinstance(ev, dict) else None
    if not isinstance(inp, dict):
        return None
    if isinstance(inp.get("command"), str):
        return inp["command"]
    if isinstance(inp.get("file_path"), str):
        body = inp.get("content", inp.get("new_string"))
        return inp["file_path"] + "\n" + (body if isinstance(body, str) else "")
    return None


def rules():
    """_pr_guard.py, compiled from its source: no bytecode cache to trust."""
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "_pr_guard.py")
    with open(path, encoding="utf-8") as fh:
        code = compile(fh.read(), path, "exec")
    mod = {"__name__": "_pr_guard", "__file__": path}
    exec(code, mod)
    return mod


def main(argv):
    if argv[1:2] in (["-h"], ["--help"]):
        print(__doc__.strip())
        return 0
    if len(argv) > 1:
        sys.stderr.write("usage: pr-guard.py < EVENT (see --help)\n")
        return 2
    raw = sys.stdin.read()
    try:
        ev = json.loads(raw)
        text = text_of(ev)
    except ValueError:
        ev, text = None, raw
    cwd = ev.get("cwd") if isinstance(ev, dict) else None
    in_stamps = isinstance(cwd, str) and STAMP_DIR in cwd
    if text is None or not (PREFILTER.search(text) or in_stamps):
        return 0
    try:
        if ev is None:
            raise ValueError("the event is not JSON")
        why = rules()["judge"](ev)
    except Exception as e:  # fail closed: the call matched a guarded pattern
        why = (
            f"pr-guard: BLOCKED [undecided] a guarded pattern matched but the guard "
            f"failed ({type(e).__name__}: {e}), so the call is refused."
        )
    if why:
        sys.stderr.write(why + "\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
