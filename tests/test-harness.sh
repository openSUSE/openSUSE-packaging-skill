#!/bin/bash
# test-harness.sh — the contrib/harness snippets stay loadable and in step. Each
# parses; each denies the credential set the openQA skill ships as well, the
# tools' own secret printers and this skill's extras, with the traps measured on
# the harnesses designed out (a Claude Read rule does not stop cat, opencode read
# patterns are relative, a grok "~/" is literal); every snippet with a read tool
# names every read path the README claims; every git-obs rule has its "git obs"
# twin. The Claude Code, grok and opencode command globs go through an fnmatch
# stand-in for their matchers: they must catch the refuse probes and leave real
# packaging work alone. The Gemini CLI regexes, which nothing here can run, go
# through a port of its loader: the ReDoS rule, the '"command":"' prefix, the
# probes, and 64 kB of pathological input, which each rule must scan in under 1 s.
# No probe is ever run as a command. The probes live in fixtures/harness/: pr-guard
# reads this suite and would refuse the merge ones. The TOML files need tomllib
# (Python 3.11+); older Pythons skip them. Exit 0 = all assertions hold.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "$HERE/../contrib/harness" "$HERE/fixtures/harness" <<'PY'
import fnmatch, json, os, re, subprocess, sys

H, FXDIR = sys.argv[1:3]
fails = 0


def check(cond, what):
    global fails
    print(("PASS: " if cond else "FAIL: ") + what)
    fails += not cond


try:
    import tomllib
except ImportError:
    tomllib = None


def load(rel):
    text = open(os.path.join(H, rel), encoding="utf-8").read()
    if rel.endswith(".toml"):
        return tomllib.loads(text)
    if rel.endswith(".jsonc"):
        text = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("//"))
    return json.loads(text)


def fixture(name):
    return json.load(open(os.path.join(FXDIR, name), encoding="utf-8"))


# The shared set, the tools' secret printers, and the paths every read tool denies.
PATHS = [".config/osc", "oscrc", ".config/tea", "gh/hosts.yml", ".netrc", ".git-credentials"]
READ_PATHS = PATHS + [".local/state/osc", ".config/mcp-bugzilla"]
COMMANDS = ["gh auth token", "gh auth status", "gh auth git-credential",
            "-H*uthorization", "--header*uthorization", "--apikey", "--apisecret", "://*:*@",
            "login list", "gitcredentials-helper", "login helper", "logins helper",
            "login git-credential", "logins git-credential", "tea login e", "tea logins e",
            "--dump-", "--http-d", "--http-f", "http_debug", "http_full_debug", "HTTP_DEBUG",
            "HTTP_FULL_DEBUG", "osc -H", "osc -qH", "osc -vH", "osc token", "osc config * pass",
            "osc *api*/person/*/token", "credential fill",
            "git-credential-* get", "git credential-* get"]
EXTRAS = ["api.opensuse.org", "build.opensuse.org", "src.opensuse.org/api", "--nodevelproject",
          "sudo chroot", "pr merge", "osc/cookiejar", "mcp-bugzilla",
          "GIT_ASKPASS=", "SSH_ASKPASS=", "core.askPass"]
GLOBS = fixture("glob-probes.json")
CAUGHT = {}


def covers(rules, tokens, kind, name):
    miss = [t for t in tokens if not any(t in r for r in rules)]
    check(not miss, f"{name}: {kind} rules name all {len(tokens)} tokens" + (f" -- missing {miss}" if miss else ""))


def twins(rules, name):
    miss = [r for r in rules if "git-obs " in r and r.replace("git-obs ", "git obs ") not in rules]
    check(not miss, f"{name}: every git-obs rule has its git obs twin" + (f" -- missing {miss}" if miss else ""))


def glob_verdicts(name, decide):
    # fnmatch's "*" crosses spaces and "/", as these matchers' does; the CLIs decide for real.
    miss = [c for c in GLOBS["refuse"] if decide(c) != "deny"]
    check(not miss, f"{name}: command globs refuse all {len(GLOBS['refuse'])} probes" + (f" -- not {miss}" if miss else ""))
    hit = [c for c in GLOBS["allow"] if decide(c) == "deny"]
    check(not hit, f"{name}: command globs leave all {len(GLOBS['allow'])} ordinary commands alone" + (f" -- refuse {hit}" if hit else ""))


def any_glob(patterns):
    # A trailing ":*" is the legacy prefix syntax: what precedes it is a literal prefix.
    def hit(cmd, p):
        return cmd.startswith(p[:-2]) if p.endswith(":*") else fnmatch.fnmatchcase(cmd, p)
    return lambda cmd: "deny" if any(hit(cmd, p) for p in patterns) else "allow"


def no_legacy(rules, name):
    bad = [r for r in rules if r.endswith(":*") and r != "sudo chroot:*"]  # a genuine prefix
    check(not bad, f"{name}: no glob ends in ':*', which reads as a literal prefix" + (f" -- {bad}" if bad else ""))


def bash_rules(deny):
    return [r[5:-1] for r in deny if r.startswith("Bash(")]


# Claude Code: a Read rule alone did not stop `cat` of the file, so each path
# needs a Bash text rule too.
deny = load("claude/settings.json")["permissions"]["deny"]
covers([r for r in deny if r.startswith("Read(")], READ_PATHS, "Read", "claude")
covers(bash_rules(deny), PATHS + COMMANDS + EXTRAS, "Bash", "claude")
twins(deny, "claude")
glob_verdicts("claude", any_glob(bash_rules(deny)))
CLAUDE = any_glob(bash_rules(deny))
no_legacy(bash_rules(deny), "claude")
check("hooks" not in load("claude/settings.json"), "claude: the deny snippet carries no hook")

# opencode: read patterns match the path relative to the worktree, so one that
# does not start with "*" never fires, and "*/" misses when HOME is the worktree.
perm = load("opencode/opencode.jsonc")["permission"]
read = [p for p, a in perm["read"].items() if a == "deny"]
covers(read, READ_PATHS, "read", "opencode")
bad = [p for p in perm["read"] if not p.startswith("*") or p.startswith("*/") or p == "*"]
check(not bad, "opencode: every read pattern starts with '*' but not '*/', and none is a bare '*'"
      " that would re-allow another snippet's denies" + (f" -- {bad}" if bad else ""))
check(next(iter(perm["bash"])) == "*", "opencode: the bash '*' is the first key")
covers([p for p, a in perm["bash"].items() if a == "deny"], PATHS + COMMANDS + EXTRAS, "bash", "opencode")
check(all(p.startswith(("~/", "/")) for p in perm["external_directory"]),
      "opencode: external_directory patterns are absolute or ~")


def last_match(cmd):
    verdict = "allow"
    for pat, action in perm["bash"].items():
        if fnmatch.fnmatchcase(cmd, pat):
            verdict = action
    return verdict


glob_verdicts("opencode", last_match)
no_legacy(list(perm["bash"]), "opencode")

if tomllib is None:
    print("SKIP: grok and gemini (no tomllib before Python 3.11)")
else:
    # grok: a leading "~/" is literal, and "X/**" does not match X itself.
    deny = load("grok/config.toml")["permission"]["deny"]
    reads = [r for r in deny if r.startswith("Read(")]
    covers(reads, READ_PATHS, "Read", "grok")
    covers(bash_rules(deny), PATHS + COMMANDS + EXTRAS, "Bash", "grok")
    check(not [r for r in deny if "(~/" in r], "grok: no rule starts with a literal ~/")
    lone = [r for r in reads if r.endswith("/**)") and r[:-4] + ")" not in reads]
    check(not lone, "grok: each X/** rule also denies X" + (f" -- {lone}" if lone else ""))
    twins(deny, "grok")
    glob_verdicts("grok", any_glob(bash_rules(deny)))
    GROK = any_glob(bash_rules(deny))
    no_legacy(bash_rules(deny), "grok")

    # Gemini CLI, packages/core/src/policy: buildArgsPatterns() and isSafeRegExp().
    nested = re.compile(r"\([^)]*[*+?{].*\)[*+?{]")
    rules = []
    for r in load("gemini/opensuse-packaging.toml")["rule"]:
        names = r["toolName"] if isinstance(r["toolName"], list) else [r["toolName"]]
        src = r["argsPattern"] if "argsPattern" in r else '"command":"' + r["commandRegex"]
        check(len(src) <= 2048 and not nested.search(src), f"gemini: loader accepts {src[:50]}...")
        check(r["decision"] == "deny" and r["priority"] == 999, f"gemini: deny at priority 999: {src[:40]}...")
        rules.append((names, re.compile(src)))

    def refused(tool, args):
        text = json.dumps(args, separators=(",", ":"), ensure_ascii=False)
        return any(tool in names and rx.search(text) for names, rx in rules)

    home = "/home/user"
    probes = fixture("gemini-probes.json")
    for path in probes["files_refused"]:
        check(refused("read_file", {"file_path": f"{home}/{path}"}), f"gemini: read_file refuses ~/{path}")
    for path in probes["files_allowed"]:
        check(not refused("read_file", {"file_path": f"{home}/{path}"}), f"gemini: read_file allows ~/{path}")
    check(refused("glob", {"pattern": "*", "dir_path": f"{home}/.config/tea"}), "gemini: glob refuses ~/.config/tea")
    for cmd in probes["shell_refused"]:
        check(refused("run_shell_command", {"command": cmd}), f"gemini: refuses {cmd}")
    for cmd in probes["shell_allowed"]:
        check(not refused("run_shell_command", {"command": cmd}), f"gemini: allows {cmd}")
    # The CLI evaluates the rules in-process: a regex that backtracks through nested gaps
    # hangs it on a long command. Each rule runs in a child, which a timeout can stop.
    scan = """
import json, re, sys, time
rx, worst = re.compile(sys.argv[1]), 0.0
for unit in json.loads(sys.argv[2]):
    text = json.dumps({"command": unit * (65000 // len(unit))}, separators=(",", ":"))
    start = time.monotonic(); rx.search(text); worst = max(worst, time.monotonic() - start)
print(f"{worst:.3f}")
"""
    units = json.dumps(fixture("slow-units.json")["units"])
    CAUGHT["gemini"] = lambda cmd: refused("run_shell_command", {"command": cmd})
    for names, rx in rules:
        try:
            out = subprocess.run([sys.executable, "-c", scan, rx.pattern, units],
                                 capture_output=True, text=True, timeout=30).stdout
            took = float(out)
        except (subprocess.TimeoutExpired, ValueError):
            took = float("inf")
        check(took < 1, f"gemini: {rx.pattern[:40]}... scans 64 kB of pathological input in {took:.2f} s")

# Global options before the subcommand: the README's Limits say which matcher catches
# which of these forms; each stand-in must agree.
GLOBAL = fixture("global-options.json")


def attribution(name, caught):
    got = [bool(caught(c)) for c in GLOBAL["commands"]]
    want = GLOBAL["caught"][name]
    check(got == want, f"{name}: catches the global-option forms the README credits it with"
          + ("" if got == want else f" -- got {got}"))


attribution("claude", lambda c: CLAUDE(c) == "deny")
attribution("opencode", lambda c: last_match(c) == "deny")
if tomllib is not None:
    attribution("grok", lambda c: GROK(c) == "deny")
    attribution("gemini", CAUGHT["gemini"])

# Antigravity: absolute read_file targets with a placeholder home.
deny = load("agy/settings.json")["permissions"]["deny"]
covers([r for r in deny if r.startswith("read_file(")], READ_PATHS, "read_file", "agy")
covers([r for r in deny if r.startswith("command(")], fixture("agy-commands.json")["commands"], "command", "agy")
check(all(r.startswith(("read_file(/home/USER/", "command(")) for r in deny),
      "agy: read_file targets use the /home/USER placeholder")

print("ALL PASS" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
PY
