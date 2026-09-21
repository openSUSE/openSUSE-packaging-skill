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

Prints "flags: <file>:<line>: <message>" per finding; exit 1 on any finding.
Runs each script's --help once, offline (argparse does no I/O of its own).
"""

import argparse
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


def help_flags(script_path):
    """The set of long flags a script's --help mentions, or None if it has no
    usable --help."""
    if script_path.endswith(".py"):
        cmd = [sys.executable, script_path, "--help"]
    else:
        cmd = ["bash", script_path, "--help"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, cwd=ROOT)
    except (OSError, subprocess.SubprocessError):
        return None
    out = (r.stdout or "") + (r.stderr or "")
    if not out.strip():
        return None
    return set(FLAG.findall(out))


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
            full = os.path.join(scripts, fn)
            cmd = (
                [sys.executable, full, "--help"]
                if fn.endswith(".py")
                else ["bash", full, "--help"]
            )
            try:
                r = subprocess.run(
                    cmd, capture_output=True, text=True, timeout=30, cwd=ROOT
                )
            except (OSError, subprocess.SubprocessError) as e:
                findings.append((f"scripts/{fn}", 0, f"--help could not run: {e}"))
                continue
            if r.returncode != 0:
                findings.append(
                    (f"scripts/{fn}", 0, f"--help exits {r.returncode}, want 0")
                )
            elif not (r.stdout or r.stderr).strip():
                findings.append((f"scripts/{fn}", 0, "--help prints nothing"))

    for path, line, msg in findings:
        print(f"flags: {path}:{line}: {msg}")
    if findings:
        print(f"\n{len(findings)} finding(s)", file=sys.stderr)
        return 1
    print(f"ok - {cited} flag citations match --help")
    return 0


if __name__ == "__main__":
    sys.exit(main())
