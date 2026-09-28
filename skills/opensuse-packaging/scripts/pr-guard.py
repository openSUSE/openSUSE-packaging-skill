#!/usr/bin/env python3
"""pr-guard.py -- harness guard for pool/ pull requests on src.opensuse.org.

Reads one tool-call event on stdin and refuses (exit 2) a call that would open,
update or merge a pool/ PR outside pool-pr.sh, merge any src.opensuse.org PR
(tea, git-obs, a merge URL on pool, or elsewhere an API call that does not
provably only read; gh is not judged), push to a branch that heads an open pool
PR, write a target-gate.sh stamp, run an emulated osc build, file a request
against the scmsync'd openSUSE:Backports:SLE-16.x projects, file a submit
request that overrides osc's devel-project check or create one through the API,
file a request whose message is too long (over 300 characters of prose, which
is every line but a "- " list item; a list line over 100; over 1000 in all) or
cannot be read, or write into a *:Update or *:Maintenance:* project outside
home: (commit, api, and osc's other writes) or one it cannot place. A -h/--help
call of tea, git-obs, git or osc is not judged, and a refusal redacts the
credentials it would echo. Its rules live in _pr_guard.py beside it, read only
once a call matches the prefilter.

The agent's own commands (not the scripts or program code they run) are also
refused when they read a credential file (tea's, osc's, gh's, netrc, git's
credential store, osc's cookie jar, an MCP server's api-key) other than by
listing it, set or run an askpass program, run one of the tools' own secret
printers (gh auth, tea login helper/edit, git-obs login list, git credential
helpers, secret-tool, osc's full config dump, HTTP debugging and tokens),
put a credential on an HTTP tool's, tea api's or git-obs api's command line,
or call the OBS or Gitea API with curl, wget or HTTPie instead of osc or
git-obs.

A command line is judged one parsed command at a time, so what a command only
carries -- a commit message, a grep pattern, an echo -- is not read as a
command. Program text is read whole: every script a command runs (its path
expanded from what the call assigns, $PWD, $TMPDIR, $HOME and globs), inline
code (-c, -e), and text fed to a shell or interpreter (heredoc, here-string,
< FILE, a pipe from echo, printf or cat). A script the same call writes is not
run: its content is not known yet. The scripts in the skill checkout's scripts/
run unread only when run by path, while every file scripts/ tracks is
byte-identical to its blob at the pinned ref (as merged, not as edited
locally), with no environment change but TMPDIR, LC_ALL, LANG, NO_COLOR and
CHANGES_AUTHOR.

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
held in a variable, a failed PR lookup or lookups past 40 s in all (under the
hook's 60 s timeout), an unreadable script or stdin program, a script path it
cannot expand, a malformed event, a missing _pr_guard.py -- refuses the call.

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
# Any path matches, because a file a command runs is where a POST hides, and
# so does a command named by a variable; so do the names the credential rules
# need where no path shows (gh, a netrc in the cwd, curl -u).
PREFILTER = re.compile(
    r"\/|tea\b|git-obs|\bgit\b[^\n;&|]*\bobs\b|src\.opensuse\.org|\bpush\b|\bosc\b"
    r"|\b(?:python[0-9.]*|bash|sh|zsh|dash|ksh|node|perl|source|env|uv|eval)\b"
    r"|(?:^|[\s;&|(])\.\s|\bsend-pack\b|\btarget-gate\b"
    r"|(?:^|[;&|(\n!{]|\b(?:do|then|else|elif|if|while|until|command|exec|nohup|time"
    r"|builtin|setsid|stdbuf|nice|ionice|sudo|doas|xargs|timeout|watch|parallel)\b)"
    r"\s*[\x22']?\$[{A-Za-z_@*]"
    r"|\bgh\b|credential|secret-tool|netrc|oscrc|[Aa][Ss][Kk][Pp][Aa][Ss][Ss]"
    r"|[Aa]uthorization|\b(?:curl|wget|xhs?|https?)\b"
)
# A call run inside a directory of credential files is judged whatever it says.
CRED_DIR = re.compile(r"/\.(?:config/(?:tea|osc|gh|mcp-[^/]*)|local/state/osc)(?:/|$)")
ANSI_C = re.compile(r"\$'((?:[^'\\]|\\.)*)'")
ESCAPE = re.compile(r"\\(x[0-9a-fA-F]{1,2}|[0-7]{1,3}|.)")


def unquoted(text):
    """text as the shell joins its words: $'...' decoded, then quotes and
    backslashes dropped (o''sc, "osc", \\osc and $'\\x6fsc' all read osc).
    The opencode plugin carries the same function."""

    def esc(m):
        e = m.group(1)
        if e[0] == "x" and len(e) > 1:
            return chr(int(e[1:], 16))
        return chr(int(e, 8)) if e[0] in "01234567" else e

    text = ANSI_C.sub(lambda m: ESCAPE.sub(esc, m.group(1)), text)
    return re.sub(r"[\"'\\]", "", text)


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
    watched = isinstance(cwd, str) and (STAMP_DIR in cwd or CRED_DIR.search(cwd))
    if text is None or not (
        PREFILTER.search(text) or PREFILTER.search(unquoted(text)) or watched
    ):
        return 0
    mod = {}
    try:
        if ev is None:
            raise ValueError("the event is not JSON")
        mod = rules()
        why = mod["judge"](ev)
    except Exception as e:  # fail closed: the call matched a guarded pattern
        why = "pr-guard: BLOCKED [undecided] a guarded pattern matched but the guard "
        try:
            why += mod.get("redact", str)(f"failed ({type(e).__name__}: {e}), ")
        except Exception:
            why += "failed, "
        why += "so the call is refused."
    if why:
        sys.stderr.write(why + "\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
