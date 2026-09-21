#!/usr/bin/env python3
"""refsection.py — print ONE section of a skill doc instead of Reading the file.

The references are big (specfile-guidelines.md, update-build.md and
submit-watch.md are 75-110 KB each); a whole-file Read burns the context budget
on the ~95% you did not need (references/token-budget.md). Every pointer in
this skill is written as `references/<file>.md "<Section>"` — this turns that
pointer into a one-liner, replacing the two-step "grep -n '^#' then Read with
offset=/limit= and hope the window is right".

  refsection.py patches.md "Patches"        # the section, whole
  refsection.py update-build.md "local builds"          # substring, case-insensitive
  refsection.py --list submit-watch.md                  # the heading outline
  refsection.py --lines update-build.md "Common build pitfalls"   # numbered, Read for more
  refsection.py --rule 3 7                              # numbered Core-directive rules of SKILL.md
  refsection.py --gate build                            # optional: scripts/gates.json, if present

A `##` section prints through the line before the next heading of the SAME or a
HIGHER level, so its `###` subsections come with it. Several matches are
ambiguous — except when one is an exact heading, or the parent of all the
others (you get them anyway). A match on a bold lead-in (`**Section** — ...`,
the paragraph form several references use instead of a heading) prints that
paragraph.

<file> may be a basename (`update-build.md`), a repo-relative path
(`references/leap-slfo.md`, `scripts/README.md`) or an absolute path; it is
resolved against the skill root (this script's parent's parent), so cwd does
not matter.

Exit: 0 printed · 1 no such section (all headings listed on stderr) · 2
ambiguous (candidates listed on stderr) · 3 usage / no such file.

Output is NOT sanitised, deliberately: these are first-party skill docs shipped
in this repo, not fetched content. references/untrusted-content.md scopes
`_sanitize.py` to third-party bytes — build logs, osc output, Bugzilla and
Gitea text, API dumps. Piping our own documentation through it would only
mangle the escapes the docs quote on purpose.

Ported from the SUSE-qe-update-validation skill (scripts/refsection.py); keep
the mechanics byte-compatible so fixes port both ways.
"""

import argparse
import json
import os
import re
import signal
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEADING = re.compile(r"^(#{1,6})\s+(.*?)(?:\s+#+)?\s*$")
BOLD = re.compile(r"^(\s*(?:[-*+]|\d+[.)])\s+)?\*\*(.+?)(?:\*\*|$)")
# group 1 = a list marker (with its indent) when the lead-in opens a list item
# — the `- **Rule** — detail` form this skill's references use for most rules —
# else None for the bare-paragraph form.
FENCE = re.compile(r"^\s*(```|~~~)")


def norm(s):
    """Comparison form: case-folded, whitespace-collapsed."""
    return " ".join(s.split()).lower()


def plain(s):
    """norm() plus the markdown noise a caller pasting a pointer may drop."""
    return norm(s.replace("`", "").replace("*", "").replace("§", ""))


def resolve(name):
    """Skill-root-relative lookup so the script works from any cwd."""
    base = os.path.basename(name)
    for c in (
        [name]
        if os.path.isabs(name)
        else [
            os.path.join(ROOT, name),
            os.path.join(ROOT, "references", name),
            os.path.abspath(name),
            os.path.join(ROOT, "references", base),
            os.path.join(ROOT, base),
            os.path.join(ROOT, "scripts", base),
        ]
    ):
        if os.path.isfile(c):
            return c
    return None


def parse(lines):
    """-> (headings, bolds). Both skip fenced code blocks: several references
    quote shell with `# comment` lines that are not headings."""
    headings, bolds, fence = [], [], None
    for i, line in enumerate(lines):
        m = FENCE.match(line)
        if m:
            if fence is None:
                fence = m.group(1)
            elif line.strip().startswith(fence):
                fence = None
            continue
        if fence is not None:
            continue
        h = HEADING.match(line)
        if h:
            headings.append((i, len(h.group(1)), h.group(2)))
            continue
        b = BOLD.match(line)
        if b:
            bolds.append((i, b.group(2)))
    return headings, bolds


def outline(headings):
    return ["%5d  %s %s" % (i + 1, "#" * lvl, text) for i, lvl, text in headings]


def extent_heading(lines, headings, idx):
    """Heading through the line before the next same-or-higher-level heading."""
    start, lvl = headings[idx][0], headings[idx][1]
    end = len(lines)
    for i, l2, _ in headings[idx + 1 :]:
        if l2 <= lvl:
            end = i
            break
    return start, end


def extent_bold(lines, start):
    """Bold lead-in through the end of its paragraph — or, for a list item,
    through its continuation lines and nested sub-items: it ends at a blank
    line, a heading, or the next item at the same or a shallower indent."""
    m = BOLD.match(lines[start])
    marker = m.group(1) if m else None
    end = start + 1
    if marker is None:
        while end < len(lines) and lines[end].strip() and not HEADING.match(lines[end]):
            end += 1
        return start, end
    depth = len(marker) - len(marker.lstrip())
    while end < len(lines):
        ln = lines[end]
        if not ln.strip() or HEADING.match(ln):
            break
        indent = len(ln) - len(ln.lstrip())
        if indent <= depth and re.match(r"\s*(?:[-*+]|\d+[.)])\s+", ln):
            break
        end += 1
    return start, end


def emit(lines, start, end, numbered):
    while end > start and not lines[end - 1].strip():
        end -= 1
    for n in range(start, end):
        sys.stdout.write(
            "%d\t%s\n" % (n + 1, lines[n]) if numbered else lines[n] + "\n"
        )


def load_doc(name):
    """Resolve + read a skill doc. Returns (path, lines) or (None, error-text)."""
    path = resolve(name)
    if not path:
        return None, (
            "no such doc: %s (searched %s and %s/references)" % (name, ROOT, ROOT)
        )
    real = os.path.realpath(path)
    if not real.startswith(os.path.realpath(ROOT) + os.sep):
        return None, (
            "%s is outside the skill checkout — output is un-sanitised, so "
            "fetched/third-party files go through scripts/_sanitize.py instead" % path
        )
    try:
        return path, open(path, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        return None, "cannot read %s: %s" % (path, e)


def locate(lines, headings, bolds, q, anchor=False):
    """Find ONE section for query q.

    Returns ("ok", start, end) | ("ambiguous", [stderr lines]) | ("none", None, None).
    """
    if anchor:
        aid = re.escape(q.lstrip("§").strip())
        pat = re.compile(r"^§?%s(?![\w-])" % aid, re.I)
        hits = [i for i, h in enumerate(headings) if pat.match(plain(h[2]))]
    else:
        nq, pq = norm(q), plain(q)
        hits = [
            i for i, h in enumerate(headings) if nq in norm(h[2]) or pq in plain(h[2])
        ]
        if len(hits) > 1:  # an exact heading beats the substrings it contains
            exact = [i for i in hits if plain(headings[i][2]) == pq]
            if len(exact) == 1:
                hits = exact
            else:  # …and a parent beats its own subsections: they print with it
                end0 = extent_heading(lines, headings, hits[0])[1]
                # …but never the document H1: "the whole file" is the thing being avoided.
                if headings[hits[0]][1] > 1 and all(
                    headings[i][0] < end0 for i in hits[1:]
                ):
                    hits = hits[:1]
    if len(hits) == 1:
        start, end = extent_heading(lines, headings, hits[0])
        return "ok", start, end
    if len(hits) > 1:
        return (
            "ambiguous",
            (q, len(hits), "headings", outline([headings[i] for i in hits])),
            None,
        )
    if not anchor:
        pq = plain(q)
        bhits = [b for b in bolds if plain(b[1]).startswith(pq)]
        if len(bhits) == 1:
            start, end = extent_bold(lines, bhits[0][0])
            return "ok", start, end
        if len(bhits) > 1:
            return (
                "ambiguous",
                (
                    q,
                    len(bhits),
                    "bold lead-ins",
                    ["%5d  ** %s" % (i + 1, text) for i, text in bhits],
                ),
                None,
            )
    return "none", None, None


# ---- rule-54 gates ---------------------------------------------------------

GATES = os.path.join(ROOT, "scripts", "gates.json")
RS = os.path.join(ROOT, "scripts", "refsection.py")
CEILING = 28800  # bytes before the trailer: one gate must arrive as ONE tool result
RULE_REF = re.compile(r"\brules?[ -](\d+(?:\s*[/,]\s*(?:and\s+)?\d+)*)", re.I)


def load_gates():
    """gates.json minus the `_` keys, validated: a malformed manifest is reported
    like a broken gate (problems -> exit 2), never a traceback."""
    try:
        with open(GATES, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        print(
            "refsection.py: no usable gates manifest (%s: %s) — this skill defines no --gate "
            "classes; read sections by name instead" % (GATES, e),
            file=sys.stderr,
        )
        sys.exit(2)
    gates = {k: v for k, v in data.items() if not k.startswith("_")}
    for name, spec in gates.items():
        bad = []
        if not isinstance(spec, dict):
            bad.append("not an object")
        else:
            if not all(isinstance(n, int) for n in spec.get("rules") or []):
                bad.append("rules must be integers")
            for key in ("sections", "read_by_name"):
                if not all(
                    isinstance(p, list)
                    and len(p) == 2
                    and all(isinstance(x, str) for x in p)
                    for p in spec.get(key) or []
                ):
                    bad.append("%s entries must be [file, section] pairs" % key)
            if spec.get("max_chars") is not None and not isinstance(
                spec["max_chars"], int
            ):
                bad.append("max_chars must be an integer")
            for key in ("rules", "sections", "read_by_name", "tools"):
                if spec.get(key) is None:
                    spec[key] = []
        if bad:
            print(
                "refsection.py: gate %s is broken in %s: %s"
                % (name, GATES, "; ".join(bad)),
                file=sys.stderr,
            )
            sys.exit(2)
    return gates


def hard_rules():
    """The numbered rules of SKILL.md 'Hard rules at a glance' as {n: [lines]}:
    from the `NN. **` line through the line before the next blank one. Only that
    section — the lifecycle list uses the same `N. **` form."""
    _, lines = load_doc("SKILL.md")
    headings, bolds = parse(lines)
    for section in ("Hard rules at a glance", "Core directive"):
        status, start, end = locate(lines, headings, bolds, section)
        if status == "ok":
            break
    else:
        return {}
    out, i = {}, start
    while i < end:
        m = re.match(r"^(\d+)\. \*\*", lines[i])
        if m:
            j = i
            while j < end and lines[j].strip():
                j += 1
            out[int(m.group(1))] = lines[i:j]
            i = j
        else:
            i += 1
    return out


def cited_rules(text):
    found = set()
    for m in RULE_REF.finditer(text):
        for n in re.findall(r"\d+", m.group(1)):
            found.add(int(n))
    return found


def trim_footer(body):
    """A section that runs to EOF drags the file's attribution footer along."""
    body = list(body)
    while body and (
        not body[-1].strip() or re.match(r"^(-{3,}|\*.*\*)\s*$", body[-1].strip())
    ):
        body.pop()
    return body


def _resolve_pairs(pairs, problems, docs):
    """[(file, section)] -> [(file, section, body, kind)] via locate()."""
    out = []
    for fname, section in pairs:
        if fname not in docs:
            path, lines = load_doc(fname)
            if path:
                headings, bolds = parse(lines)
                docs[fname] = (lines, headings, bolds)
            else:
                problems.append(lines)
                docs[fname] = None
        if docs[fname] is None:
            continue
        lines, headings, bolds = docs[fname]
        status, start, end = locate(lines, headings, bolds, section)
        if status != "ok":
            problems.append(
                "%s %r: %s"
                % (
                    fname,
                    section,
                    "ambiguous" if status == "ambiguous" else "no such section",
                )
            )
            continue
        kind = (
            "H%d" % headings[[h[0] for h in headings].index(start)][1]
            if start in [h[0] for h in headings]
            else "bold lead-in"
        )
        body = lines[start:end]
        if end >= len(lines):
            body = trim_footer(body)
        out.append((fname, section, body, kind))
    return out


def gate_text(cls, spec, seen=(), no_rules=False):
    """Assemble one gate. Returns (text, problems, bytes_before_trailer)."""
    out, problems, docs = [], [], {}
    gates = load_gates()
    already = set()
    for s in seen:
        if s not in gates:
            problems.append("--seen: no gate class %r" % s)
        else:
            already |= set(gates[s].get("rules", []))
    out.append(
        "# GATE %s — rule 54: read this before %s"
        % (cls, spec.get("before", "the first call"))
    )
    out.append("Tools in this class: %s." % ", ".join(spec.get("tools", [])))
    if spec.get("scoped"):
        out.append(
            "Scope: with more than one template loaded, scope every call in this class "
            'with template="<RRID>" [rule 28].'
        )
    if no_rules:
        out.append(
            "Read this once per session, right before that first call; the hard rules are "
            "in SKILL.md, which you hold."
        )
    else:
        out.append(
            "Read this once per session, right before that first call. Do not read the whole "
            "reference; a sub-agent does not load SKILL.md — the hard rules that bind this "
            "class are printed below, and a rule a section cites by number but that is not "
            "printed here is still binding: `python3 %s --rule N` prints it." % RS
        )
    rbn = _resolve_pairs(spec.get("read_by_name", []), problems, docs)
    if rbn:
        out.append(
            "Later-stage sections, read by name when you reach them "
            '(`python3 %s <file> "<Section>"`): '
            % RS
            + "; ".join('%s "%s"' % (f, s) for f, s, _, _ in rbn)
            + "."
        )
    out.append("")
    rules = hard_rules()
    want = [] if no_rules else [n for n in spec.get("rules", []) if n not in already]
    if not no_rules:
        out.append("## Hard rules for this class (SKILL.md, verbatim)")
        skipped = sorted(n for n in spec.get("rules", []) if n in already)
        if skipped:
            out.append(
                "(already printed by gate%s %s: rule%s %s)"
                % (
                    "s" if len(seen) > 1 else "",
                    ", ".join(seen),
                    "s" if len(skipped) > 1 else "",
                    ", ".join(map(str, skipped)),
                )
            )
        out.append("")
        for n in want:
            if n not in rules:
                problems.append(
                    "rule %d not found in SKILL.md 'Hard rules at a glance'" % n
                )
                continue
            out.extend(rules[n])
            out.append("")
    sections = _resolve_pairs(spec.get("sections", []), problems, docs)
    cited = cited_rules("\n".join(out[1:]))  # skip the title line: it names rule 54
    for _, _, body, _ in sections:
        cited |= cited_rules("\n".join(body))
    printed = set(spec.get("rules", [])) if no_rules else (set(want) | already)
    printed.add(54)  # reading this gate IS rule 54
    missing = sorted(n for n in cited if n not in printed and n in rules)
    if missing and not no_rules:
        out.append(
            "Also cited by the sections below but not printed above (still binding): rule%s %s "
            "— `python3 %s --rule N`."
            % ("s" if len(missing) > 1 else "", ", ".join(map(str, missing)), RS)
        )
        out.append("")
    for fname, section, body, kind in sections:
        out.append(
            '---- references/%s "%s" (%s, %d lines) ----'
            % (os.path.basename(fname), section, kind, len(body))
        )
        out.extend(body)
        out.append("")
    text = "\n".join(out).rstrip("\n") + "\n"
    n = len(text.encode("utf-8"))
    text += "---- end of gate %s: %d bytes above, %d rules, %d sections ----\n" % (
        cls,
        n,
        len(want),
        len(sections),
    )
    return text, problems, n


def run_gate(cls, want_list, seen=(), no_rules=False):
    gates = load_gates()
    if want_list or not cls:
        bad = 0
        print("%-13s %7s %5s %4s  %s" % ("class", "bytes", "rules", "sect", "tools"))
        for name, spec in gates.items():
            text, problems, n = gate_text(name, spec)
            over = n > min(spec.get("max_chars", CEILING), CEILING)
            flag = "!" if (problems or over) else " "
            bad += 1 if (problems or over) else 0
            print(
                "%s%-12s %7d %5d %4d  %s"
                % (
                    flag,
                    name,
                    n,
                    len(spec.get("rules", [])),
                    len(spec.get("sections", [])),
                    ", ".join(spec.get("tools", [])),
                )
            )
        if bad:
            print(
                "refsection.py: %d gate(s) marked '!' are broken or over budget" % bad,
                file=sys.stderr,
            )
        return 2 if bad else 0
    if cls not in gates:
        print(
            "refsection.py: no gate class %r; classes are: %s"
            % (cls, ", ".join(gates)),
            file=sys.stderr,
        )
        return 3
    text, problems, n = gate_text(cls, gates[cls], seen, no_rules)
    if problems:
        print(
            "refsection.py: gate %s is broken (scripts/gates.json vs the docs):" % cls,
            file=sys.stderr,
        )
        for p in problems:
            print("  " + p, file=sys.stderr)
        return 2
    try:
        sys.stdout.write(text)
    except UnicodeEncodeError:
        sys.stdout.buffer.write(text.encode("utf-8", "replace"))
    cap = min(gates[cls].get("max_chars", CEILING), CEILING)
    if n > cap:
        print(
            "refsection.py: gate %s is %d bytes, over its %d budget — trim it (the text "
            "above is still the gate; read it)" % (cls, n, cap),
            file=sys.stderr,
        )
        return 2
    return 0


def run_rules(nums):
    rules = hard_rules()
    if not nums:
        print("refsection.py: --rule needs one or more rule numbers", file=sys.stderr)
        return 3
    rc = 0
    for n in nums:
        if n in rules:
            print("\n".join(rules[n]))
            print()
        else:
            print("refsection.py: no hard rule %d in SKILL.md" % n, file=sys.stderr)
            rc = 1
    return rc


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="refsection.py",
        description="Print one section of a skill doc.",
        epilog='refsection.py specfile-guidelines.md "Patches" | --list <file> | '
        "--anchor <file> A6 | --gate <class> [--seen a,b] "
        "[--no-rules] | --gate --list | --rule 26 32",
    )
    ap.add_argument(
        "--list", action="store_true", help="print the heading outline only"
    )
    ap.add_argument(
        "--anchor",
        action="store_true",
        help="second arg is an anchor id (A6, §A6, C2, …), not free text",
    )
    ap.add_argument(
        "--lines", action="store_true", help="prefix output with line numbers"
    )
    ap.add_argument(
        "--gate",
        metavar="CLASS",
        nargs="?",
        const="",
        help="rule-54 gate: the class's hard rules + operative sections "
        "(scripts/gates.json); `--gate --list` lists the classes",
    )
    ap.add_argument(
        "--seen",
        metavar="CLASSES",
        help="with --gate: omit rules these comma-separated gates already printed",
    )
    ap.add_argument(
        "--no-rules",
        action="store_true",
        help="with --gate: sections only (the orchestrator holds SKILL.md)",
    )
    ap.add_argument(
        "--rule",
        metavar="N",
        nargs="*",
        type=int,
        help="print hard rule N of SKILL.md (several numbers allowed)",
    )
    ap.add_argument("args", nargs="*", metavar="FILE [SECTION]")
    # a section can start with "-" (`refhost-install.md "--newpackage"`), so hoist
    # the flags out and hand argparse the rest behind a "--". Everything after a
    # literal "--" is positional, never a flag.
    argv = sys.argv[1:] if argv is None else list(argv)
    if "--" in argv:
        head, tail = argv[: argv.index("--")], argv[argv.index("--") + 1 :]
    else:
        head, tail = argv, []
    mode, marg, seen, no_rules, hoisted, i, twice = None, None, [], False, [], 0, False
    while i < len(head):
        x = head[i]
        if x == "--gate" or x.startswith("--gate="):
            twice |= mode is not None
            mode = "gate"
            if "=" in x:
                marg = x.split("=", 1)[1]
            elif i + 1 < len(head) and not head[i + 1].startswith("-"):
                marg = head[i + 1]
                i += 1
            else:
                marg = ""
        elif x == "--rule":
            twice |= mode is not None
            mode, marg = "rule", []
            while i + 1 < len(head) and head[i + 1].isdigit():
                marg.append(int(head[i + 1]))
                i += 1
        elif x == "--seen" or x.startswith("--seen="):
            if "=" in x:
                v = x.split("=", 1)[1]
            elif i + 1 < len(head) and not head[i + 1].startswith("-"):
                v = head[i + 1]
                i += 1
            else:
                v = ""
            seen = [s for s in v.split(",") if s] or ["?"]  # "?" = a value was missing
        elif x == "--no-rules":
            no_rules = True
        else:
            hoisted.append(x)
        i += 1
    known = {"--list", "--anchor", "--lines", "-h", "--help"}
    flags = [x for x in hoisted if x in known]
    rest = [x for x in hoisted if x not in known] + tail
    a = ap.parse_args(flags + ["--"] + rest)

    if mode:
        bad = (
            twice
            or a.args
            or a.lines
            or a.anchor
            or (a.list and mode == "rule")
            or (a.list and mode == "gate" and (marg or seen or no_rules))
            or (mode == "gate" and not marg and not a.list)
            or ((seen or no_rules) and mode != "gate")
            or "?" in seen
        )
        if bad:
            print(
                "refsection.py: one of --gate CLASS | --gate --list | --rule N…; no FILE/SECTION, "
                "no --lines/--anchor; --seen/--no-rules only with --gate CLASS",
                file=sys.stderr,
            )
            ap.print_usage(sys.stderr)
            return 3
        return (
            run_gate(marg, a.list, seen, no_rules)
            if mode == "gate"
            else run_rules(marg)
        )
    if seen or no_rules:
        print("refsection.py: --seen/--no-rules need --gate CLASS", file=sys.stderr)
        return 3

    if not a.args or len(a.args) > 2 or (not a.list and len(a.args) != 2):
        ap.print_usage(sys.stderr)
        return 3
    path, lines = load_doc(a.args[0])
    if not path:
        print("refsection.py: " + lines, file=sys.stderr)
        return 3
    headings, bolds = parse(lines)

    if a.list:
        print("\n".join(outline(headings)))
        return 0

    q = a.args[1]
    status, start, end = locate(lines, headings, bolds, q, a.anchor)
    if status == "ok":
        emit(lines, start, end, a.lines)
        return 0
    if status == "ambiguous":
        q_, n_, what, detail = start
        print(
            "refsection.py: %r matches %d %s in %s — be more specific:"
            % (q_, n_, what, os.path.relpath(path, ROOT)),
            file=sys.stderr,
        )
        print("\n".join(detail), file=sys.stderr)
        return 2
    print(
        "refsection.py: no section matching %r in %s; headings are:"
        % (q, os.path.relpath(path, ROOT)),
        file=sys.stderr,
    )
    print("\n".join(outline(headings)), file=sys.stderr)
    return 1


if __name__ == "__main__":
    # `refsection.py x.md "S" | head` must exit quietly, not traceback.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main())
