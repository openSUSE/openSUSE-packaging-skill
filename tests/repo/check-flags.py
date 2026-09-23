#!/usr/bin/env python3
"""Every script flag the prose cites must exist in that script's --help.

The docs tell an agent to run `outdated.py --no-repology` instead of making it
probe `--help` first; that saves a tool call and a few hundred tokens, and is
worth exactly as much as the citation is accurate. A flag renamed in the script
and left behind in the prose sends the agent to a usage error.

Fence-aware on purpose. Matching only inline `code spans` misses every citation
inside a fenced block -- and those are concentrated in agents/, the playbooks a
sub-agent reads WITHOUT SKILL.md, so they are the citations that get checked
least and matter most.

  python3 tests/repo/check-flags.py [--skill NAME]

references/script-usage.md, the agents' substitute for --help, is checked the
other way round too: one synopsis line per runnable script, whose long flags,
short-to-long pairs (`-o|--output`), value-taking flags (`--days N`) and exit
codes equal what that script's --help shows. Positionals and the meaning
attached to each flag or exit code are NOT checked. No doc may tell the agent
to run --help.

Prints "flags: <file>:<line>: <message>" per finding; exit 1 on any finding.
Runs each script's --help once, offline (argparse does no I/O of its own).
"""

import argparse
import functools
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# `<script>.<ext> ... --flag`, where the flag belongs to that script rather than
# to something piped after it.
CITATION = re.compile(r"\b([\w.-]+\.(?:py|sh))\b((?:[^`\n|;&]|\|\|)*)")
FLAG = re.compile(r"(?<![\w-])(--[a-z][a-z0-9-]*)")
INLINE = re.compile(r"`([^`\n]+)`")
FENCE = re.compile(r"^\s*(```|~~~)")

# references/script-usage.md: "- `<script> <synopsis>` — [meaning; ]exit 0 x · 1 y"
SYNOPSIS = re.compile(r"^- `([\w.-]+\.(?:py|sh))\b[^`]*`")
SYN_EXIT = re.compile(r"(?:\bexit|·)\s*(\d+)\b")
# --help exit codes come in two shapes: an "Exit:"/"Exit codes:"/"... exit code:"
# block whose items start a line or follow ; , ·  -- or one "exit N" per line.
EXIT_HEAD = re.compile(r"\bexit(?: codes?)?\b[^:\n]*:(.*)", re.I)
EXIT_ITEM = re.compile(r"(?:^|[;,·])\s*(\d+)(?=\s|=|$)")
EXIT_LINE = re.compile(r"^exit (\d+)\b")
# Flags of OTHER commands a script's --help quotes, not its own.
FOREIGN = {
    "gpg-verify.sh": {"--keyring", "--verify"},
    "incoming-requests.py": {"--incoming", "--set-as-default"},
    "my-requests.sh": {"--brief", "--no-prs"},
    "scm-snapshot.sh": {"--outdir"},
    "soname-check.sh": {"--provides"},
    "watch-submissions.sh": {"--diff"},
}
# `-o, --output` (argparse) or `-o|--output` (bash, synopsis).
SHORT_PAIR = re.compile(r"(?<![\w-])(-[a-zA-Z])(?:, |\|)(--[a-z][a-z0-9-]*)")
# A flag followed by ONE space (or =) and a metavar: `--days N`, `--user <u>`,
# `--source obs|git`, `--rule [N ...]`. Two spaces start a description instead.
VALUED = re.compile(
    r"(?<![\w-])(--[a-z][a-z0-9-]*)[ =](?:<|'|\[|\{|[A-Z][A-Z0-9_]*\b|[a-z]+(?:\|[a-z]+)+)"
)
# Telling the agent to run --help, which script-usage.md replaces: a verb a few
# words before it, "with --help", or "--help output".
HELP = r"`?(?:--help|-h)(?![\w-])"
HELP_ADVICE = re.compile(
    r"\b(?:run|call|check|consult|see|read|use|pass|invoke|try)\b"
    r"((?:\s+[\w'`<>.-]+?){0,3}?)\s+"
    + HELP
    + r"|\bwith\s+()"
    + HELP
    + r"|((?:[\w'`<>.-]+\s+)?)"
    + HELP
    + r"`?\s+output\b",
    re.I,
)
NEGATED = re.compile(r"\b(?:don't|do not|never|not|no)\b(?:\s+\w+)?\s*$", re.I)
# Words that may sit between the verb and --help without naming a command.
FILLER = {"its", "the", "a", "their", "script's", "scripts'", "ever", "with", "it"}
# The one sentence that states the convention rather than advising a call.
HELP_CONVENTION = "prints usage with `-h`/`--help`"


def spans(path):
    """Yield (lineno, text) for every region that can carry a citation: each
    inline code span, and -- inside a fenced block -- each whole line."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    fence = None
    for n, line in enumerate(lines, start=1):
        m = FENCE.match(line)
        if m:
            if fence is None:
                fence = m.group(1)
            elif line.strip().startswith(fence):
                fence = None
            continue
        if fence is not None:
            yield n, line
        else:
            for sp in INLINE.finditer(line):
                yield n, sp.group(1)


@functools.lru_cache(maxsize=None)
def run_help(script_path):
    """(exit code, output) of `<script> --help`; the exit code is None and the
    output the error when it could not run."""
    if script_path.endswith(".py"):
        cmd = [sys.executable, script_path, "--help"]
    else:
        cmd = ["bash", script_path, "--help"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, cwd=ROOT)
    except (OSError, subprocess.SubprocessError) as e:
        return None, str(e)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def help_text(script_path):
    """A script's --help output, or None if it has no usable --help."""
    rc, out = run_help(script_path)
    return out if rc is not None and out.strip() else None


def valued(text):
    """Long flags the text shows taking a value."""
    return set(VALUED.findall(text))


def short_pairs(text):
    """(short, long) option pairs the text shows, minus -h/--help."""
    return set(SHORT_PAIR.findall(text)) - {("-h", "--help")}


def help_flags(script_path):
    """The set of long flags a script's --help mentions, or None if it has no
    usable --help."""
    out = help_text(script_path)
    return None if out is None else set(FLAG.findall(out))


def help_exits(text):
    """The exit codes a --help text declares (empty set: none)."""
    codes, block = set(), False
    for raw in text.splitlines():
        line = raw.lstrip("#").strip()
        if block:
            if not line:
                block = False
            else:
                codes.update(int(c) for c in EXIT_ITEM.findall(line))
            continue
        m = EXIT_LINE.match(line)
        if m:
            codes.add(int(m.group(1)))
            continue
        m = EXIT_HEAD.search(line)
        if m:
            block = True
            codes.update(int(c) for c in EXIT_ITEM.findall(m.group(1).strip()))
    return codes


def check_usage(scripts, usage_path, runnable):
    """script-usage.md holds exactly one synopsis line per runnable script, with
    the same long flags and exit codes as that script's --help."""
    rel = os.path.relpath(usage_path, ROOT)
    if not os.path.exists(usage_path):
        return [(rel, 0, "missing; every runnable script needs a synopsis line")]
    findings, seen = [], {}
    with open(usage_path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    for n, line in enumerate(lines, start=1):
        m = SYNOPSIS.match(line)
        if not m:
            continue
        name = m.group(1)
        if name not in runnable:
            findings.append((rel, n, f"names {name}, which is not a runnable script"))
            continue
        if name in seen:
            findings.append(
                (rel, n, f"second synopsis for {name} (first: line {seen[name]})")
            )
            continue
        seen[name] = n
        out = help_text(os.path.join(scripts, name))
        if out is None:
            findings.append((rel, n, f"{name} has no usable --help"))
            continue
        want = set(FLAG.findall(out)) - {"--help"} - FOREIGN.get(name, set())
        have = set(FLAG.findall(line)) - {"--help"}
        for flag in sorted(want - have):
            findings.append((rel, n, f"{name}: synopsis lacks {flag} (in --help)"))
        for flag in sorted(have - want):
            findings.append((rel, n, f"{name}: synopsis has {flag}, --help does not"))
        for flag in sorted(FOREIGN.get(name, set()) - set(FLAG.findall(out))):
            findings.append(
                (rel, n, f"{name}: FOREIGN exempts {flag}, --help no longer shows it")
            )
        both = want & have
        for flag in sorted((valued(out) ^ valued(line)) & both):
            where = "--help" if flag in valued(out) else "the synopsis"
            findings.append((rel, n, f"{name}: {flag} takes a value only in {where}"))
        for s, lng in sorted(short_pairs(out) ^ short_pairs(line)):
            where = "--help" if (s, lng) in short_pairs(out) else "the synopsis"
            findings.append((rel, n, f"{name}: {s}|{lng} only in {where}"))
        want_x = help_exits(out)
        have_x = {int(c) for c in SYN_EXIT.findall(line.split("`", 2)[2])}
        if not want_x:
            findings.append((rel, n, f"{name} --help declares no exit codes"))
        elif have_x != want_x:
            findings.append(
                (
                    rel,
                    n,
                    f"{name}: exit codes {sorted(have_x)}, --help says {sorted(want_x)}",
                )
            )
    for name in sorted(set(runnable) - set(seen)):
        findings.append((rel, 0, f"no synopsis line for {name}"))
    return findings


def check_no_help_advice(docs, runnable):
    """No doc tells the agent to run a bundled script's --help."""
    names = "|".join(re.escape(x) for x in sorted(runnable))
    by_name = re.compile(rf"(?<![\w.-])(?:{names}|<script>)`?\s+" + HELP)

    def advice(line):
        for m in HELP_ADVICE.finditer(line):
            if NEGATED.search(line[max(0, m.start() - 40) : m.start()]):
                continue
            between = next((g for g in m.groups() if g is not None), "")
            words = between.replace("`", " ").split()
            # `run configure --help` is another command's help, not ours.
            if words and words[-1] not in FILLER | set(runnable) | {"<script>"}:
                continue
            return True
        return False

    findings = []
    for doc in docs:
        with open(doc, encoding="utf-8") as fh:
            for n, line in enumerate(fh.read().splitlines(), start=1):
                line = line.replace(HELP_CONVENTION, "")
                if by_name.search(line) or advice(line):
                    findings.append(
                        (
                            os.path.relpath(doc, ROOT),
                            n,
                            "tells the agent to run --help; point at "
                            "references/script-usage.md",
                        )
                    )
    return findings


def main(argv=None):
    ap = argparse.ArgumentParser(prog="check-flags.py", description=__doc__)
    ap.add_argument("--skill", default=None, help="only this skill directory")
    args = ap.parse_args(argv)

    findings = []
    skills_dir = os.path.join(ROOT, "skills")
    skills = (
        [args.skill]
        if args.skill
        else sorted(
            d
            for d in os.listdir(skills_dir)
            if os.path.isdir(os.path.join(skills_dir, d))
        )
    )
    cache = {}
    cited = 0
    for skill in skills:
        base = os.path.join(skills_dir, skill)
        scripts = os.path.join(base, "scripts")
        docs = [os.path.join(base, "SKILL.md")]
        for sub in ("agents", "references"):
            d = os.path.join(base, sub)
            if os.path.isdir(d):
                docs += [
                    os.path.join(d, f)
                    for f in sorted(os.listdir(d))
                    if f.endswith(".md")
                ]
        readme = os.path.join(scripts, "README.md")
        if os.path.exists(readme):
            docs.append(readme)

        for doc in docs:
            rel = os.path.relpath(doc, ROOT)
            for line, text in spans(doc):
                for m in CITATION.finditer(text):
                    name, tail = m.group(1), m.group(2)
                    full = os.path.join(scripts, name)
                    if not os.path.exists(full):
                        # Only complain about names that look like this skill's
                        # own helpers; prose cites plenty of foreign scripts.
                        if f"scripts/{name}" in text:
                            findings.append(
                                (
                                    rel,
                                    line,
                                    f"cites scripts/{name}, which does not exist",
                                )
                            )
                        continue
                    wanted = FLAG.findall(tail)
                    if not wanted:
                        continue  # a bare mention promises nothing to check
                    if name.startswith("_"):
                        # Repo convention: a leading underscore is an imported
                        # module, not a command, so it has no --help to match.
                        continue
                    flags = cache.get(full, ...)
                    if flags is ...:
                        flags = cache[full] = help_flags(full)
                    if flags is None:
                        findings.append((rel, line, f"{name} has no usable --help"))
                        continue
                    for flag in wanted:
                        cited += 1
                        if flag not in flags:
                            findings.append(
                                (rel, line, f"{name} --help does not mention {flag}")
                            )

        # AGENTS.md: every runnable script prints usage with -h/--help. An
        # explicit help request is a request that SUCCEEDED, so it exits 0; 2 is
        # for a usage error, and conflating them misleads any caller that
        # checks the status.
        for fn in sorted(os.listdir(scripts)) if os.path.isdir(scripts) else []:
            if fn.startswith("_") or not fn.endswith((".py", ".sh")):
                continue
            rc, out = run_help(os.path.join(scripts, fn))
            if rc is None:
                findings.append((f"scripts/{fn}", 0, f"--help could not run: {out}"))
                continue
            if rc != 0:
                findings.append((f"scripts/{fn}", 0, f"--help exits {rc}, want 0"))
            elif not out.strip():
                findings.append((f"scripts/{fn}", 0, "--help prints nothing"))

        runnable = [
            fn
            for fn in (sorted(os.listdir(scripts)) if os.path.isdir(scripts) else [])
            if not fn.startswith("_") and fn.endswith((".py", ".sh"))
        ]
        if runnable:
            findings += check_usage(
                scripts, os.path.join(base, "references", "script-usage.md"), runnable
            )
            agents_md = os.path.join(ROOT, "AGENTS.md")
            findings += check_no_help_advice(
                docs + ([agents_md] if os.path.exists(agents_md) else []), runnable
            )

    for path, line, msg in findings:
        print(f"flags: {path}:{line}: {msg}")
    if findings:
        print(f"\n{len(findings)} finding(s)", file=sys.stderr)
        return 1
    print(f"ok - {cited} flag citations match --help")
    return 0


if __name__ == "__main__":
    sys.exit(main())
