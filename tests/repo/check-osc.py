#!/usr/bin/env python3
"""Every `osc` invocation the prose cites must be one osc accepts.

The skill tells agents exactly how to call osc so they neither guess nor probe
`osc <cmd> --help`. A guessed form costs more than a probe: `osc mkpac PRJ PKG`
fails, and the agent that hit it worked around it with a raw `osc api -X PUT`
and a checkout in /tmp. So each citation is checked against osc's own argparse
parser, read in-process (hidden options such as `build --shell` and the global
ones every subcommand accepts included; help text shows neither):

  * the subcommand exists (aliases resolve: sr, rq, co, ci, rbl, blt, ...);
  * every flag cited after it is an option that subcommand's parser accepts;
  * references/osc-usage.md has a synopsis line for that subcommand, so no doc
    uses an osc form the reference does not define;
  * the known wrong forms are not recommended outside osc-usage.md's
    "Wrong forms" section.

Fence-aware like check-flags.py (whose span reader it reuses). Positionals are
not parsed, except mkpac's single one, which is the trap that was actually hit.

  python3 tests/repo/check-osc.py [--skill NAME]

Needs osc importable by this interpreter (CI pins it); without it this exits 2
rather than passing.
Prints "osc: <file>:<line>: <message>" per finding; exit 1 on any finding.
"""

import argparse
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

_spec = importlib.util.spec_from_file_location(
    "check_flags", os.path.join(HERE, "check-flags.py")
)
_cf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cf)
spans, NEGATED = _cf.spans, _cf.NEGATED

# `osc [global opts] <subcommand> <rest>`; the rest stops where another command
# starts (a pipe, ;, &). Global options that take a value take the next word.
CALL = re.compile(
    r"(?<![\w./-])osc((?:\s+(?:(?:-A|--apiurl|--config|--setopt)(?:\s+(?!-)\S+|=\S+)"
    r"|(?!(?:-A|--apiurl|--config|--setopt)\b)--?[A-Za-z][\w-]*(?:=\S+)?))*)"
    r"\s+([a-z][a-z_]*)\b([^`\n|;&]*)"
)
# A command substitution is its own command: `-m "$(cat f)"` must not hide the
# options after it, nor lend it its own.
SUBST = re.compile(r"\$\([^()]*\)")
OPT = re.compile(r"(?<![\w/.<>=-])(--?[A-Za-z][\w-]*)")
# A synopsis bullet: "- `osc sub ...` · `osc other ...` — meaning"; every
# `osc <sub>` span before the dash defines that subcommand.
SYNOPSIS = re.compile(r"^- `osc ")
DEFINES = re.compile(r"`osc ([a-z][a-z_]*)\b")
WRONG_HEAD = "## Wrong forms"

# Invocations that are wrong however they are spelled. Each is (pattern over the
# canonical subcommand + rest, message).
WRONG = [
    (
        re.compile(r"^mkpac\s+\S+\s+\S+"),
        "mkpac takes ONE package name, inside a checked-out project; "
        "create a package with `osc meta pkg PRJ PKG -F FILE`",
    ),
    (
        re.compile(r"^checkout\b.*\s(?:-o|--output-dir)(?:\s+|=)?/(?:var/)?tmp\b"),
        "checks out into a temp dir; checkouts belong in the osc working area",
    ),
    (
        re.compile(r"^api\b.*(?:-X|--method)(?:\s+|=)?PUT\b.*_meta\b"),
        "PUTs _meta by hand; use `osc meta pkg|prj ... -F FILE`",
    ),
]


def load_osc():
    """{name or alias: (canonical name, set of accepted options)}, or None when
    osc cannot be imported."""
    try:
        from osc.commandline import argparse_manpage_get_parser
    except ImportError:
        return None
    parser = argparse_manpage_get_parser()
    subs = next(a for a in parser._actions if isinstance(a, argparse._SubParsersAction))
    # Aliases map to the same parser object; its prog names the canonical one.
    table = {}
    for name, sp in subs.choices.items():
        canonical = sp.prog.split()[-1]
        table[name] = (canonical, set(sp._option_string_actions))
    return table


def docs_of(base):
    docs = [os.path.join(base, "SKILL.md")]
    for sub in ("agents", "references"):
        d = os.path.join(base, sub)
        if os.path.isdir(d):
            docs += [
                os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".md")
            ]
    readme = os.path.join(base, "scripts", "README.md")
    if os.path.exists(readme):
        docs.append(readme)
    return docs


def wrong_section_lines(path):
    """Line numbers inside osc-usage.md's "Wrong forms" section."""
    out, inside = set(), False
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh.read().splitlines(), start=1):
            if line.startswith("## "):
                inside = line.startswith(WRONG_HEAD)
            if inside:
                out.add(n)
    return out


def check(base, table):
    findings, cited_subs, count = [], {}, 0
    usage = os.path.join(base, "references", "osc-usage.md")
    wrong_ok = wrong_section_lines(usage) if os.path.exists(usage) else set()
    for doc in docs_of(base):
        rel = os.path.relpath(doc, ROOT)
        with open(doc, encoding="utf-8") as fh:
            raw = fh.read().splitlines()
        cursor = {}
        for n, text in spans(doc):
            text = SUBST.sub("SUBST", text)
            for m in CALL.finditer(text):
                word, rest = m.group(2), m.group(3)
                if word not in table:
                    findings.append((rel, n, f"`osc {word}`: no such osc subcommand"))
                    continue
                sub, flags = table[word]
                count += 1
                cited_subs.setdefault(sub, (rel, n))
                for flag in OPT.findall(rest):
                    if flag not in flags:
                        findings.append(
                            (rel, n, f"`osc {word}`: osc {sub} has no option {flag}")
                        )
                if doc == usage and n in wrong_ok:
                    continue
                call = f"{sub} {rest.strip()}"
                # Negation is judged at THIS occurrence: a later, un-negated
                # repeat of the same call must not borrow an earlier "never".
                line = SUBST.sub("SUBST", raw[n - 1])
                at = line.find(m.group(0), cursor.get(n, 0))
                cursor[n] = at + 1
                before = line[: max(0, at)]
                before = before.replace("`", "").replace("*", "")
                for pat, msg in WRONG:
                    if pat.search(call) and not NEGATED.search(before[-40:]):
                        findings.append((rel, n, f"`osc {word}`: {msg}"))
    # The reference must define every subcommand the skill uses.
    rel_usage = os.path.relpath(usage, ROOT)
    if not os.path.exists(usage):
        findings.append((rel_usage, 0, "missing; the skill cites osc subcommands"))
        return findings, count
    defined = {}
    with open(usage, encoding="utf-8") as fh:
        for n, line in enumerate(fh.read().splitlines(), start=1):
            # A wrong form defines nothing; only the real synopsis lines count.
            if n in wrong_ok or not SYNOPSIS.match(line):
                continue
            # An unknown word here is already reported as a citation above.
            for word in DEFINES.findall(line.split(" — ", 1)[0]):
                if word in table:
                    defined.setdefault(table[word][0], n)
    for sub, (rel, n) in sorted(cited_subs.items()):
        if sub not in defined:
            findings.append(
                (rel, n, f"`osc {sub}` has no synopsis line in {rel_usage}")
            )
    return findings, count


def main(argv=None):
    ap = argparse.ArgumentParser(prog="check-osc.py", description=__doc__)
    ap.add_argument("--skill", default=None, help="only this skill directory")
    args = ap.parse_args(argv)
    table = load_osc()
    if not table:
        print(
            "check-osc.py: cannot import osc; install it (CI pins the version)",
            file=sys.stderr,
        )
        return 2
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
    findings, count = [], 0
    for skill in skills:
        f, c = check(os.path.join(skills_dir, skill), table)
        findings += f
        count += c
    for path, line, msg in findings:
        print(f"osc: {path}:{line}: {msg}")
    if findings:
        print(f"\n{len(findings)} finding(s)", file=sys.stderr)
        return 1
    print(f"ok - {count} osc citations match osc")
    return 0


if __name__ == "__main__":
    sys.exit(main())
