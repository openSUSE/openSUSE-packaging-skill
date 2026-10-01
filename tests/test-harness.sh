#!/bin/bash
# test-harness.sh — the contrib/harness snippets stay loadable and in step. Each
# parses; each denies the credential set the openQA skill ships as well, the
# tools' own secret printers and this skill's extras, with the traps measured on
# the harnesses designed out (a Claude Read rule does not stop cat, opencode read
# patterns are relative, a grok "~/" is literal); every snippet with a read tool
# names every read path the README claims; every git-obs rule has its "git obs"
# twin. The opencode 2.x snippet must carry the 1.x rules in the same order, with no
# "*" allow. The Claude Code, grok and opencode command globs go through an fnmatch
# stand-in for their matchers: they must catch the refuse probes and leave real
# packaging work alone. One shared list of commands goes through the globs, the
# Gemini CLI rules and the Kimi hook alike, and every glob, every Gemini CLI
# alternative and every Kimi rule, path and osc walk must be the only one to refuse
# some probe, so deleting any of them fails the suite. The Gemini CLI regexes,
# which nothing here can run, go through a port of its loader: the ReDoS rule, the
# '"command":"' prefix, the probes, and 64 kB of pathological input, which each rule
# must scan in under 1 s.
# The Kimi hook is fed events on stdin and must refuse, let through, fail closed on
# bad input and stay under 1 s on its worst cases. Where codex and kimi are
# installed, `codex execpolicy check` decides the Codex probes and `kimi doctor
# config` validates the hook entry, in a throw-away home under a bare environment.
# No probe is ever run as a command. The probes live in fixtures/harness/: pr-guard
# reads this suite and would refuse the merge ones. The TOML files need tomllib
# (Python 3.11+); older Pythons skip them. Exit 0 = all assertions hold.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d /var/tmp/test-harness.XXXXXX)"; trap 'rm -rf "$work"' EXIT
python3 - "$HERE/../contrib/harness" "$HERE/fixtures/harness" "$work" <<'PY'
import fnmatch, json, os, re, shutil, subprocess, sys, time

H, FXDIR, WORK = sys.argv[1:4]
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
            "HTTP_FULL_DEBUG", "osc -H", "osc token", "osc config * pass",
            "osc *api*/person/*/token", "credential fill", "secret-tool lookup", "secret-tool search",
            "git-credential-* get", "git credential-* get", ".config/gh/", "-*H *uthorization",
            "osc *--dump-", "osc -*H"]
EXTRAS = ["api.opensuse.org", "build.opensuse.org", "src.opensuse.org/api", "--nodevelproject",
          "sudo chroot", "pr merge", "osc/cookiejar", "mcp-bugzilla",
          "GIT_ASKPASS=", "SSH_ASKPASS=", "core.askPass"]
GLOBS = fixture("glob-probes.json")
SHARED = fixture("shared-probes.json")
REFUSE = SHARED["refuse"] + GLOBS["refuse"]
PASS = SHARED["pass"] + GLOBS["allow"]
CAUGHT = {}


def covers(rules, tokens, kind, name):
    miss = [t for t in tokens if not any(t in r for r in rules)]
    check(not miss, f"{name}: {kind} rules name all {len(tokens)} tokens" + (f" -- missing {miss}" if miss else ""))


def twins(rules, name):
    miss = [r for r in rules if "git-obs " in r and r.replace("git-obs ", "git obs ") not in rules]
    check(not miss, f"{name}: every git-obs rule has its git obs twin" + (f" -- missing {miss}" if miss else ""))


def glob_verdicts(name, decide):
    # fnmatch's "*" crosses spaces and "/", as these matchers' does; the CLIs decide for real.
    miss = [c for c in REFUSE if decide(c) != "deny"]
    check(not miss, f"{name}: command globs refuse all {len(REFUSE)} probes" + (f" -- not {miss}" if miss else ""))
    hit = [c for c in PASS if decide(c) == "deny"]
    check(not hit, f"{name}: command globs leave all {len(PASS)} ordinary commands alone" + (f" -- refuse {hit}" if hit else ""))


def glob_hit(cmd, p):
    # A trailing ":*" is the legacy prefix syntax: what precedes it is a literal prefix.
    return cmd.startswith(p[:-2]) if p.endswith(":*") else fnmatch.fnmatchcase(cmd, p)


def any_glob(patterns):
    return lambda cmd: "deny" if any(glob_hit(cmd, p) for p in patterns) else "allow"


def load_bearing(name, rules, refused_without):
    # Deleting any rule must turn a probe red: each one is the only rule refusing some probe.
    refused = [c for c in REFUSE if refused_without(None, c)]
    idle = [r for r in rules if all(refused_without(r, c) for c in refused)]
    check(not idle, f"{name}: every rule is the only one to refuse some probe" + (f" -- not {idle}" if idle else ""))


def sole(rules):
    def refused_without(skip, cmd):
        return any(glob_hit(cmd, p) for p in rules if p != skip)
    return refused_without


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
load_bearing("claude", bash_rules(deny), sole(bash_rules(deny)))
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


def opencode_without(skip, cmd):
    verdict = "allow"
    for pat, action in perm["bash"].items():
        if pat != skip and fnmatch.fnmatchcase(cmd, pat):
            verdict = action
    return verdict == "deny"


load_bearing("opencode", [p for p, a in perm["bash"].items() if a == "deny"], opencode_without)
no_legacy(list(perm["bash"]), "opencode")

# opencode 2.x: an ordered array of {action, resource, effect}, last match wins, over a
# base policy that already allows everything, so the snippet carries no "*" allow. It
# must say what the 1.x snippet says, in the same order, then deny what only 2.x offers.
v2 = load("opencode-v2/opencode.jsonc")["permissions"]
check(all(set(r) == {"action", "resource", "effect"} and all(isinstance(v, str) for v in r.values())
          and r["action"] in ("external_directory", "shell", "read", "edit", "execute")
          and r["effect"] in ("allow", "deny", "ask")
          for r in v2), "opencode-v2: every entry has exactly an action, a resource and an effect, with known values")
# 2.x reads "x *" as also matching the bare x, so a 1.x pattern whose "x *" twin has its effect adds nothing.
v1_as_v2 = [{"action": {"bash": "shell"}.get(sec, sec), "resource": p, "effect": e}
            for sec, rules in perm.items() for p, e in rules.items()
            if not (sec == "bash" and (p == "*" or rules.get(p + " *") == e))]
check(v2[:len(v1_as_v2)] == v1_as_v2, "opencode-v2: the same rules as opencode, in the same order, minus the bash"
      " '*' allow and the patterns that a ' *' twin covers")
# Past them only 2.x entries: edit (the write, edit and patch tools) off the guard, the harness
# configs and the stamps, but for the Plan agent's directory, and Code Mode's execute tool,
# whose fetch no hook sees, removed.
v2_tail = v2[len(v1_as_v2):]
PLAN = {"action": "edit", "resource": "*.opencode/plan/*", "effect": "allow"}
check(all(r["action"] in ("edit", "execute") and (r["effect"] == "deny" or r == PLAN) for r in v2_tail),
      "opencode-v2: past the 1.x rules only edit and execute denies, and the plan directory's allow")
check({"action": "execute", "resource": "*", "effect": "deny"} in v2_tail,
      "opencode-v2: denies execute with resource '*', which removes the tool")
v2_edit = [(r["resource"], r["effect"]) for r in v2_tail if r["action"] == "edit"]
STAMP = "target-" + "gate"
EDIT_PATHS = [".claude/hooks/pr-guard.py", "/home/user/.claude/hooks/_pr_guard.py", "/home/user/.claude/settings.json",
              "/home/user/.config/opencode/plugins/pool-pr-guard.ts", "opencode.json", "sub/opencode.jsonc",
              ".opencode/plugins/x.ts", f".git/{STAMP}/t-b.json", f"/w/pool/x/.git/{STAMP}/t-b.json"]
EDIT_OK = ["foo.spec", "foo.changes", "_service", "README.md", "opencode.spec", "opencode.changes",
           f"skills/opensuse-packaging/scripts/{STAMP}.sh", ".opencode/plan/x.md", "/home/user/.opencode/plan/x.md"]


def edit_denied(path, skip=None):
    verdict = "allow"
    for pat, effect in v2_edit:
        if pat != skip and fnmatch.fnmatchcase(path, pat):
            verdict = effect
    return verdict == "deny"


missed = [p for p in EDIT_PATHS if not edit_denied(p)]
check(not missed, "opencode-v2: edit denied on the guard, the harness configs and the stamps"
      + (f" -- not {missed}" if missed else ""))
hit = [p for p in EDIT_OK if edit_denied(p)]
check(not hit, "opencode-v2: the edit denies leave packaging files alone" + (f" -- {hit}" if hit else ""))
idle = [s for s, _ in v2_edit if not any(edit_denied(p) != edit_denied(p, s) for p in EDIT_PATHS + EDIT_OK)]
check(not idle, "opencode-v2: every edit entry decides some path" + (f" -- not {idle}" if idle else ""))
check(not [r for r in v2 if r["resource"] == "*" and r["effect"] == "allow"],
      "opencode-v2: no '*' allow, which appended after another entry would undo its denies")
v2_read = [r["resource"] for r in v2 if r["action"] == "read"]
bad = [p for p in v2_read if not p.startswith("*") or p.startswith("*/") or p == "*"]
check(not bad, "opencode-v2: every read pattern starts with '*' but not '*/', and none is a bare '*'"
      + (f" -- {bad}" if bad else ""))
covers([r["resource"] for r in v2 if r["action"] == "read" and r["effect"] == "deny"], READ_PATHS, "read", "opencode-v2")
v2_deny = [r["resource"] for r in v2 if r["action"] == "shell" and r["effect"] == "deny"]
covers(v2_deny, PATHS + COMMANDS + EXTRAS, "shell", "opencode-v2")
check(all(r["resource"].startswith(("~/", "/")) for r in v2 if r["action"] == "external_directory"),
      "opencode-v2: external_directory patterns are absolute or ~")


def v2_hit(cmd, pat):
    # A pattern ending in " *" also matches the bare command.
    return fnmatch.fnmatchcase(cmd, pat) or (pat.endswith(" *") and fnmatch.fnmatchcase(cmd, pat[:-2]))


def v2_verdict(cmd, skip=None):
    verdict = "allow"
    for r in v2:
        if r["action"] == "shell" and r["resource"] != skip and v2_hit(cmd, r["resource"]):
            verdict = r["effect"]
    return verdict


glob_verdicts("opencode-v2", v2_verdict)
load_bearing("opencode-v2", v2_deny, lambda skip, cmd: v2_verdict(cmd, skip) == "deny")
no_legacy(v2_deny, "opencode-v2")
check(v2_verdict("sudo chroot") == "deny" and v2_verdict("sudo chroot x") == "deny" and v2_verdict("sudo chrootx") == "allow",
      "opencode-v2: a trailing ' *' pattern also matches the bare command")

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
    load_bearing("grok", bash_rules(deny), sole(bash_rules(deny)))
    GROK = any_glob(bash_rules(deny))
    no_legacy(bash_rules(deny), "grok")

    # Gemini CLI, packages/core/src/policy: buildArgsPatterns() and isSafeRegExp().
    nested = re.compile(r"\([^)]*[*+?{].*\)[*+?{]")
    rules, shell = [], []
    for r in load("gemini/opensuse-packaging.toml")["rule"]:
        names = r["toolName"] if isinstance(r["toolName"], list) else [r["toolName"]]
        src = r["argsPattern"] if "argsPattern" in r else '"command":"' + r["commandRegex"]
        check(len(src) <= 2048 and not nested.search(src), f"gemini: loader accepts {src[:50]}...")
        check(r["decision"] == "deny" and r["priority"] == 999, f"gemini: deny at priority 999: {src[:40]}...")
        rules.append((names, re.compile(src)))
        if "commandRegex" in r:
            shell.append(r["commandRegex"])

    def refused(tool, args):
        text = json.dumps(args, separators=(",", ":"), ensure_ascii=False)
        return any(tool in names and rx.search(text) for names, rx in rules)

    def alternatives(group):
        """The top-level alternatives of "(?:A|B|...)"."""
        out, depth, start, i, cls = [], 0, 3, 0, False
        while i < len(group):
            c = group[i]
            if c == "\\":
                i += 2
                continue
            if cls:
                cls = c != "]"
            elif c == "[":
                cls = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    out.append(group[start:i])
            elif c == "|" and depth == 1:
                out.append(group[start:i])
                start = i + 1
            i += 1
        return out

    # Every shell rule is one "(?:...)" of alternatives; each alternative must be the
    # only one to refuse some probe, so deleting any of them turns this red.
    parts = [(k, a) for k, src in enumerate(shell) for a in alternatives(src)]
    check(all(src.startswith("(?:") and src.endswith(")") for src in shell) and parts,
          "gemini: every shell rule is a flat (?:...) of alternatives")
    compiled = [re.compile('"command":"(?:' + a + ")") for _, a in parts]
    gem_refuse = SHARED["refuse"] + fixture("gemini-probes.json")["shell_refused"]

    def gem_hits(cmd):
        text = json.dumps({"command": cmd}, separators=(",", ":"), ensure_ascii=False)
        return [i for i, rx in enumerate(compiled) if rx.search(text)]

    hits = {cmd: gem_hits(cmd) for cmd in gem_refuse}
    idle = [parts[i][1][:60] for i in range(len(parts)) if not any(h == [i] for h in hits.values())]
    check(not idle, f"gemini: each of {len(parts)} alternatives is the only one to refuse some probe"
          + (f" -- not {idle}" if idle else ""))

    home = "/home/user"
    probes = fixture("gemini-probes.json")
    for path in probes["files_refused"]:
        check(refused("read_file", {"file_path": f"{home}/{path}"}), f"gemini: read_file refuses ~/{path}")
    for path in probes["files_allowed"]:
        check(not refused("read_file", {"file_path": f"{home}/{path}"}), f"gemini: read_file allows ~/{path}")
    check(refused("glob", {"pattern": "*", "dir_path": f"{home}/.config/tea"}), "gemini: glob refuses ~/.config/tea")
    for cmd in SHARED["refuse"] + probes["shell_refused"]:
        check(refused("run_shell_command", {"command": cmd}), f"gemini: refuses {cmd}")
    for cmd in SHARED["pass"] + probes["shell_allowed"]:
        check(not refused("run_shell_command", {"command": cmd}), f"gemini: allows {cmd}")
    for cmd in probes["shell_missed"]:
        check(not refused("run_shell_command", {"command": cmd}), f"gemini: misses, as the README says, {cmd}")
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
attribution("opencode-v2", lambda c: v2_verdict(c) == "deny")
if tomllib is not None:
    attribution("grok", lambda c: GROK(c) == "deny")
    attribution("gemini", CAUGHT["gemini"])

# Antigravity: absolute read_file targets with a placeholder home.
deny = load("agy/settings.json")["permissions"]["deny"]
covers([r for r in deny if r.startswith("read_file(")], READ_PATHS, "read_file", "agy")
covers([r for r in deny if r.startswith("command(")], fixture("agy-commands.json")["commands"], "command", "agy")
check(all(r.startswith(("read_file(/home/USER/", "command(")) for r in deny),
      "agy: read_file targets use the /home/USER placeholder")

# Codex: prefix rules with a placeholder home, and a permission profile whose globs
# rg expands before every command (an error there fails the command: no /tmp glob).
rules = open(os.path.join(H, "codex/opensuse-packaging.rules"), encoding="utf-8").read()
covers([rules], PATHS + [".local/state/osc/cookiejar", ".config/mcp-bugzilla"], "prefix", "codex")
check('HOME = "/home/USER"' in rules and '"~/' not in rules, "codex: rules use the /home/USER placeholder")


def bare_env(home, **extra):
    return {"PATH": "/usr/bin:/bin", "HOME": home, "DBUS_SESSION_BUS_ADDRESS": "disabled:", **extra}


fake = os.path.join(WORK, "home")
os.makedirs(os.path.join(fake, ".codex"))
os.makedirs(os.path.join(fake, ".kimi-code"))
if tomllib is not None:
    conf = load("codex/config.toml")
    prof = conf["permissions"]
    def deny_keys(table):
        for k, v in table.items():
            yield from deny_keys(v) if isinstance(v, dict) else [k] if v == "deny" else []

    denied = [k for name in ("credentials", "credentials-strict") for k in deny_keys(prof[name]["filesystem"])]
    covers(denied, READ_PATHS, "profile", "codex")
    check(conf["default_permissions"] == "credentials" and "sandbox_mode" not in conf,
          "codex: the credentials profile is the default, with no legacy sandbox_mode")
    globs = [k for k in denied if any(c in k for c in "*?[")]
    check(not globs, "codex: no deny glob, whose rg scan fails every command on one unreadable directory"
          + (f" -- {globs}" if globs else ""))
    req = load("codex/requirements.toml")["permissions"]["filesystem"]["deny_read"]
    check(all(p.startswith("/home/USER/") for p in req), "codex: requirements deny_read is absolute")
if shutil.which("codex"):
    for want, *argv in fixture("codex-probes.json")["cases"]:
        r = subprocess.run(
            ["codex", "execpolicy", "check", "--resolve-host-executables",
             "--rules", os.path.join(H, "codex/opensuse-packaging.rules"), *argv],
            env=bare_env(fake, CODEX_HOME=os.path.join(fake, ".codex")),
            capture_output=True, text=True)
        try:
            got = json.loads(r.stdout).get("decision") or "none"
        except ValueError:
            got = "error: " + (r.stderr or r.stdout).strip()[:120]
        check(got == want, f"codex execpolicy: {' '.join(argv)} -> {want}" + ("" if got == want else f" (got {got})"))
else:
    print("SKIP: codex execpolicy (codex not installed)")

# Kimi: [permission] rules are inert in 0.42.0, so a PreToolUse hook does the work.
hook = os.path.join(H, "kimi/opensuse-packaging.py")
kimi_home = os.path.join(fake, ".kimi-code")
with open(os.path.join(kimi_home, "session_index.jsonl"), "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"sessionId": "acp-1", "workDir": fake + "/.config"}) + "\n")
    fh.write(json.dumps({"sessionId": "acp-2", "workDir": fake + "/.config/osc"}) + "\n")
    fh.write('{"sessionId": "acp-1", "workDir": "/va')  # cut short by a concurrent write


def run_hook(stdin):
    try:
        return subprocess.run([sys.executable, hook], input=stdin, capture_output=True, text=True,
                              env=bare_env(fake, KIMI_CODE_HOME=kimi_home), timeout=10)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(hook, "timeout", "", "")


def bash_event(cmd):
    return json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": fake + "/work"})


events = fixture("kimi-probes.json")
events["refuse"] = SHARED["refuse"] + events["refuse"]
events["allow"] = SHARED["pass"] + events["allow"]
for want, name in ((2, "refuse"), (0, "allow")):
    for ev in events[name]:
        if isinstance(ev, str):
            ev = {"tool_name": "Bash", "tool_input": {"command": ev}}
        ev = json.loads(json.dumps(ev).replace("@HOME@", fake))
        ev.setdefault("cwd", fake + "/work")
        r = run_hook(json.dumps(ev))
        what = ev["tool_input"].get("command") or json.dumps(ev["tool_input"])
        check(r.returncode == want, f"kimi hook: {name}s {ev['tool_name']} {what}"
              + ("" if r.returncode == want else f" (exit {r.returncode})"))
# Deleting any of the hook's rules, any credential path, or its osc walk must let some
# probe through. A child imports the hook and asks refused() with each one removed.
mutate = """
import importlib.util, json, re, sys
spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
probes = json.loads(sys.argv[2])
rules, paths, walk = list(hook.RULES), list(hook.PATHS), hook.osc_calls
def refused():
    return [c for c in probes if hook.refused(c)]
base = refused()
idle = []
for i in range(len(rules)):
    hook.RULES = rules[:i] + rules[i + 1:]
    if refused() == base:
        idle.append("rule " + " & ".join(p.pattern for p in rules[i])[:60])
hook.RULES = rules
for i in range(len(paths)):
    hook.PATH_RE = re.compile("|".join(paths[:i] + paths[i + 1:]), re.IGNORECASE)
    if refused() == base:
        idle.append("path " + paths[i][:60])
hook.PATH_RE = re.compile("|".join(paths), re.IGNORECASE)
hook.osc_calls = lambda segment: iter(())
if refused() == base:
    idle.append("the osc walk")
print(json.dumps({"base": len(base), "idle": idle}))
"""
strings = [e for e in events["refuse"] if isinstance(e, str)]
try:
    out = json.loads(subprocess.run([sys.executable, "-c", mutate, hook, json.dumps(strings)], capture_output=True,
                                    text=True, timeout=120, env=bare_env(fake)).stdout)
except (subprocess.TimeoutExpired, ValueError):
    out = {"base": 0, "idle": ["the check did not run"]}
check(not out["idle"], f"kimi hook: every rule, path and the osc walk is the only one to refuse some probe"
      + (f" -- not {out['idle']}" if out["idle"] else ""))
r = run_hook("not json")
check(r.returncode == 2, "kimi hook: input that is not JSON fails closed")
r = run_hook(bash_event("gh auth token"))
check("Denied by opensuse-packaging hook" in r.stderr, "kimi hook: a refusal says why on stderr")
# Kimi runs the call unchecked once its 10 s timeout passes, so the worst case must stay
# far below it: a text over the cap, a separator per character, every multi-part rule's
# parts in segments of their own, and the shapes that once backtracked.
worst = {"parts": ";".join(fixture("slow-units.json")["kimi_parts"]) + ";a" * 28000,
         "separators": ";" * 65000, "one-char segments": "a;" * 32500,
         "osc sr tea pr": "osc sr tea pr " * 4600, "-H and spaces": "-H" + " " * 64000 + "x",
         "git-credential-": "git-credential-" * 4300, "osc global options": "osc -A " * 9200,
         "first parts everywhere": "osc;tea;git obs;curl;sudo;" * 2500 + ";".join(fixture("slow-units.json")["kimi_parts"]),
         "over the cap": "osc sr tea pr " * 5000}
for name, text in worst.items():
    want = 2 if len(text) > 64 * 1024 else 0
    start = time.monotonic()
    r = run_hook(bash_event(text))
    took = time.monotonic() - start
    check(r.returncode == want and took < 1, f"kimi hook: {name} ({len(text) // 1000} kB) exits {want} in {took:.2f} s"
          + ("" if r.returncode == want else f" (exit {r.returncode})"))
# Every part on its own, on each pathological unit repeated to 64 kB, in a child a
# timeout can stop: the README says no part backtracks.
scan = """
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
worst, which = 0.0, ""
for rx in [hook.PATH_RE] + [part for parts in hook.RULES for part in parts]:
    for unit in json.loads(sys.argv[2]):
        text = unit * (65000 // len(unit))
        start = time.monotonic()
        rx.search(text)
        took = time.monotonic() - start
        if took > worst:
            worst, which = took, rx.pattern[:40]
print(f"{worst:.3f} {which}")
"""
try:
    out = subprocess.run([sys.executable, "-c", scan, hook, json.dumps(fixture("slow-units.json")["units"])],
                         capture_output=True, text=True, timeout=120, env=bare_env(fake)).stdout
    took, which = float(out.split(" ", 1)[0]), out.split(" ", 1)[1].strip()
except (subprocess.TimeoutExpired, ValueError, IndexError):
    took, which = float("inf"), "?"
check(took < 0.25, f"kimi hook: every part scans 64 kB of pathological input, the slowest in {took:.3f} s ({which})")
got = [run_hook(bash_event(c)).returncode == 2 for c in fixture("global-options.json")["commands"]]
want = fixture("global-options.json")["caught"]["kimi"]
check(got == want, "kimi hook: catches the global-option forms the README credits it with"
      + ("" if got == want else f" -- got {got}"))
if tomllib is not None:
    entry = load("kimi/config.toml")["hooks"][0]
    matcher = re.compile(entry["matcher"])  # kimi doctor does not compile it
    check(entry["event"] == "PreToolUse" and "opensuse-packaging.py" in entry["command"]
          and all(matcher.search(t) for t in ("Bash", "Read", "Grep", "Write", "mcp__x__y")),
          "kimi: the hook matcher compiles and selects Bash, Read, Grep, Write and MCP tools")
if shutil.which("kimi"):
    r = subprocess.run(["kimi", "doctor", "config", os.path.join(H, "kimi/config.toml")],
                       env=bare_env(fake), capture_output=True, text=True)
    check(r.returncode == 0, "kimi doctor config accepts the hook entry"
          + ("" if r.returncode == 0 else f": {r.stdout.strip()[-200:]}"))
else:
    print("SKIP: kimi doctor (kimi not installed)")

print("ALL PASS" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
PY
