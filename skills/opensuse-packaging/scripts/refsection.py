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

Ported from the SUSE-qe-update-validation skill
(skills/suse-qe-update-validation/scripts/refsection.py); keep
the mechanics byte-compatible so fixes port both ways.
"""

import argparse
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


# ---- SKILL.md hard rules, by number ----------------------------------------


def hard_rules():
    """The numbered rules of SKILL.md's core-directive section as {n: [lines]}.

    A rule runs from its `NN. **` line to the next one, so that its indented
    sub-bullets and `NNb.` continuations travel with it. Ending at the first
    blank line instead would be wrong in both directions: consecutive rules
    with no blank between them get swallowed into the first of the run (which
    made rules 2-5 unretrievable, and `--rule 1` print five rules), while a
    rule whose bullets are separated by a blank line loses them."""
    _, lines = load_doc("SKILL.md")
    headings, bolds = parse(lines)
    for section in ("Hard rules at a glance", "Core directive"):
        status, start, end = locate(lines, headings, bolds, section)
        if status == "ok":
            break
    else:
        return {}
    rule = re.compile(r"^(\d+)\. \*\*")
    starts = [
        (i, int(m.group(1))) for i in range(start, end) if (m := rule.match(lines[i]))
    ]
    out = {}
    for k, (i, n) in enumerate(starts):
        stop = starts[k + 1][0] if k + 1 < len(starts) else end
        # The last rule would otherwise run to the end of the section, which
        # carries its `###` subsections: stop at the next heading of any level.
        for j in range(i + 1, stop):
            if HEADING.match(lines[j]):
                stop = j
                break
        block = lines[i:stop]
        while block and not block[-1].strip():
            block.pop()
        out[n] = block
    return out


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
        "--anchor <file> A6 | --rule 26 32\n\n"
        "Exit: 0 printed · 1 no such section · 2 ambiguous · 3 usage / no such file",
        formatter_class=argparse.RawDescriptionHelpFormatter,
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
    mode, marg, hoisted, i, twice = None, None, [], 0, False
    while i < len(head):
        x = head[i]
        if x == "--rule":
            twice |= mode is not None
            mode, marg = "rule", []
            while i + 1 < len(head) and head[i + 1].isdigit():
                marg.append(int(head[i + 1]))
                i += 1
        else:
            hoisted.append(x)
        i += 1
    known = {"--list", "--anchor", "--lines", "-h", "--help"}
    flags = [x for x in hoisted if x in known]
    rest = [x for x in hoisted if x not in known] + tail
    a = ap.parse_args(flags + ["--"] + rest)

    if mode:
        bad = twice or a.args or a.lines or a.anchor or a.list
        if bad:
            print(
                "refsection.py: --rule N… takes rule numbers only — no FILE/SECTION, "
                "no --list/--lines/--anchor",
                file=sys.stderr,
            )
            ap.print_usage(sys.stderr)
            return 3
        return run_rules(marg)

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
