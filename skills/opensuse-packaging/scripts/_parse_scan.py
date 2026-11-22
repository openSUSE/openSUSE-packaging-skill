#!/usr/bin/env python3
"""_parse_scan.py -- the parse-time constructs of a spec, read as text.

Parsing a spec (rpmspec -P, rpmbuild) runs what rpm expands while it reads:
shell, Lua, files it includes or loads, text it expands twice. gate.sh's
parse-surface step lists the constructs a tree adds over Factory's spec of the
package, as information for the review and never as a gate: a text scan cannot
be complete, so gate.sh parses inside a bwrap sandbox where the host has one.

A construct is a logical line (rpm reads on while a line ends in a backslash or
leaves a %{, %( or %[ open; it splits on LF alone, and a NUL ends a physical
line) that holds one of:
  shell    %(...)
  lua, expand, load, include in any call form (%lua, %{lua:, %{?load ...);
           %include, %if and %elif also behind a %% that the line's expansion
           turns into a directive
  lua      a Lua call in an expression: lua: in %if, %elif, %[...], %{expr:...}
  sub gsub rep reverse upper lower basename dirname suffix url2path u2p
  macrobody shrink: they cut or rewrite text, and rpm keeps an undefined
           %name as it is, so %{lower:%{LUA:...}} turns into a live %{lua:...},
           and %{shrink:%lu }a into %lua
  %%       an escaped %, which a %global body or a tag turns into a live one
  lone %   a % that starts no macro: rpm keeps it, and a later expansion joins
           it to what follows (%global p %, then %{p}(id) runs id)
  glue     a bare %name that a later expansion can complete into one of those
           names: a proper prefix of one at a line end or before } % \\ or "
           (%define a %lu, then %{a}a ... is %lua ...); %1 or %* before a name
           character or a %
%% and a lone % count only on a line that defines a macro, sets a tag or calls
a macro with arguments: nothing else expands them again (a comment's %%check).
quote, shescape and expr keep their argument's characters in order and are none.
A construct Factory's spec has verbatim still counts as added when a file a
shell, Lua, %include or %load line names (a path glob: each file it matches)
differs from Factory's, when a macro it uses is defined anew (a shell, Lua, %%
or lone % line may take a value of plain characters, a version or a commit, for
a macro it does not put right after a %%), or, for a parametric macro it
defines, when a new line calls it. An %include of a file of the tree is read in
its place, as rpm reads it, so what counts is the constructs that file brings (a
node_modules.spec.inc of Source lines brings none); a loaded macro file that
differs counts as a whole.
Out of scope: what a host macro does with its arguments (%requires_eq x';id;'
reaches a shell inside the host's own macro) and _multibuild flavour names.

Usage: python3 -I _parse_scan.py constructs FILE
       python3 -I _parse_scan.py added NEW BASE
       python3 -I _parse_scan.py needs DIR
       python3 -I _parse_scan.py scan DIR BASEDIR [LISTING]
  needs: the files scan reads from Factory as text (none: no spec holds a
         construct): each spec with one, and each file a spec includes or loads
  scan:  each *.spec of DIR, with the files it %includes read in their place,
         and each file it loads, against their copies in BASEDIR; any other file
         a construct names against its md5 in LISTING, OBS's expanded listing
         (no copy, no entry: Factory lacks it)
Exit: 0 = no construct found (constructs) or added (added, scan); needs: listed
      1 = found or added, 2 = usage, 3 = a file it cannot read, or an internal
      error
"""

import fnmatch
import hashlib
import os
import re
import sys
import xml.etree.ElementTree as ET

RUNS = ("lua", "expand", "load", "include")
RESHAPES = ("sub", "gsub", "rep", "reverse", "upper", "lower", "basename")
RESHAPES += ("dirname", "suffix", "url2path", "u2p", "macrobody", "shrink")
NAME = r"[A-Za-z_][A-Za-z0-9_]*"
TAGS = {"name", "version", "release", "epoch", "summary", "license", "url"}
TAGS |= {"bugurl", "vcs", "disturl", "docdir", "group", "vendor", "packager"}
TAGS |= {"distribution", "sourcelicense", "disttag", "translationurl"}
TAGS |= {"upstreamreleases", "modularitylabel", "buildsystem", "prefix", "prefixes"}
READS = {"shell", "lua", "include", "load"}
PLAIN = re.compile(r"[A-Za-z0-9._+~^-]*")
LONE = re.compile(r"%(?![A-Za-z0-9_%{(\[*#?!-])")
REF = re.compile(
    r"%[A-Za-z_][A-Za-z0-9_]*[ \t]+\S|%\{[?!]*[A-Za-z_][A-Za-z0-9_]*[ \t:]"
)
STORE = re.compile(
    r"%(?:define|global)\s|^\s*[A-Za-z][A-Za-z0-9]*(?:\([^)]*\))?\s*:", re.M
)
ARGS = re.compile(
    r"%(?:[0-9]+|\*\*?|#)(?=[A-Za-z_%])|%\{(?:[0-9]+|\*\*?|#)\}(?=[A-Za-z0-9_%])"
)
CALL = re.compile(r"%%\{?[?!]*(%s)(?![A-Za-z0-9_])" % "|".join(RUNS + RESHAPES))
PRE = {n[:k] for n in RUNS + RESHAPES for k in range(1, len(n))}
PRE -= set(RUNS + RESHAPES)
GLUE = re.compile(
    r"%%(?:%s)(?=$|[}%%\\\"])" % "|".join(sorted(PRE, key=len, reverse=True)),
    re.M,
)
# a directive the line's own expansion makes: %include, %if, %elif, or the same behind %%
DIRECTIVE = re.compile(r"\s*%%?(include|if|elif)(?![A-Za-z0-9_])")
EXPR = re.compile(r"%\[|%\{[?!]*expr[:\s]")
DEFINE = re.compile(r"%%(?:define|global|undefine)\s+(%s)" % NAME)
TAG = re.compile(r"\s*([A-Za-z]+)([0-9]*)(?:\([^)]*\))?\s*:")
INCLUDE_ARG = re.compile(r"%(\{?)[?!]*(?:include|load)(?![A-Za-z0-9_])")


def key(name):
    """The name rpm keeps a macro under: a tag's in either case (%{URL} is
    %{url}, %{SOURCEURL0} reads Source0), any other as written."""
    low = name.lower()
    m = re.fullmatch(r"(source|patch)(?:url)?([0-9]+)", low)
    if m:
        return "%s%d" % (m.group(1), int(m.group(2)))
    return low if low in TAGS else name


def logical(text):
    """(first line number, text) of each line as rpm reads it."""
    out, cur, first, depth = [], [], 0, {"{": 0, "(": 0, "[": 0}
    close = {"}": "{", ")": "(", "]": "["}
    for n, raw in enumerate(text.split("\n"), 1):
        line = raw.split("\0", 1)[0].rstrip()
        if not cur:
            first = n
        cur.append(line)
        i, cont = 0, False
        while i < len(line):
            c = line[i]
            if c == "\\":
                cont = i == len(line) - 1
                i += 2
                continue
            if c == "%" and line[i + 1 : i + 2] in ("{", "(", "[", "%"):
                if line[i + 1] != "%":
                    depth[line[i + 1]] += 1
                i += 2
                continue
            if c in depth and depth[c]:
                depth[c] += 1
            elif c in close and depth[close[c]]:
                depth[close[c]] -= 1
            i += 1
        if not cont and not any(depth.values()):
            out.append((first, "\n".join(cur)))
            cur = []
    if cur:
        out.append((first, "\n".join(cur)))
    return out


def kinds(s, index=None):
    """What makes logical line s a parse-time construct; [] for nothing. With the
    index of its text, a lua: call that reaches an expression through a macro
    counts too (%define x lua:..., then %if %{x})."""
    bare = s.replace("%%", "\0")
    found = ["shell"] if "%(" in bare else []
    for m in CALL.finditer(bare):
        if m.group(1) not in found:
            found.append(m.group(1))
    d = DIRECTIVE.match(s)
    if d and d.group(1) == "include" and "include" not in found:
        found.append("include")
    expr = d and d.group(1) != "include" or EXPR.search(bare)
    if expr and "lua" not in found:
        if (
            "lua:" in s
            or index
            and any(
                "lua:" in v for name in index.uses(s) for v in index.defs.get(name, ())
            )
        ):
            found.append("lua")
    if not (STORE.search(s) or REF.search(bare)):
        return found
    if "%%" in s:
        found.append("%%")
    if LONE.search(bare):
        found.append("lone %")
    if GLUE.search(bare) or ARGS.search(bare):
        found.append("glue")
    return found


def constructs(text):
    """(first line number, logical line) of each parse-time construct of text."""
    index = Index(logical(text))
    return [(n, s) for n, s in index.lines if kinds(s, index)]


def refs(s):
    """The macros line s uses (%{S:1} as SOURCE1, %%{x} none), but those it defines."""
    bare = s.replace("%%", "\0")
    out = set()
    for m in re.finditer(r"%%\{?[?!]*(%s)(?::\s*([0-9]+))?" % NAME, bare):
        name, num = m.group(1), m.group(2)
        if name in ("S", "P") and num:
            name = ("SOURCE" if name == "S" else "PATCH") + num
        out.add(key(name))
    return out - {key(n) for n in DEFINE.findall(bare)}


class Index:
    """What a text's logical lines define, looked up once: each macro's
    defining lines (%define, %global, %undefine, or the tag rpm sets it from),
    and the plain values a file name can be resolved with."""

    def __init__(self, lines):
        self.lines = lines
        self.have = {s for _, s in lines}
        self.defs, self.refs = {}, {}
        self.vals = {"_sourcedir": "."}
        for _, d in lines:
            for name in {key(n) for n in DEFINE.findall(d.replace("%%", "\0"))}:
                self.defs.setdefault(name, []).append(d)
            m = TAG.match(d)
            if m:
                tag, num = m.group(1).lower(), m.group(2)
                if tag in ("source", "patch"):
                    self.defs.setdefault("%s%d" % (tag, int(num or 0)), []).append(d)
                elif tag in TAGS and not num:
                    self.defs.setdefault(tag, []).append(d)
            m = re.match(r"\s*%%(?:define|global)\s+(%s)\s+(\S+)$" % NAME, d)
            if m:
                self.vals[key(m.group(1))] = m.group(2)
                continue
            m = re.match(r"(?i)\s*(source|patch)([0-9]*)\s*:\s*(\S+)$", d)
            if m:
                f = m.group(3).split("#/")[-1].rsplit("/", 1)[-1]
                self.vals["%s%d" % (m.group(1).lower(), int(m.group(2) or 0))] = f
                continue
            m = re.match(r"(?i)\s*(name|version|release)\s*:\s*(\S+)$", d)
            if m:
                self.vals.setdefault(m.group(1).lower(), m.group(2))

    def uses(self, s):
        """Each macro line s uses, through the definitions this text gives."""
        seen, todo = set(), sorted(refs(s))
        while todo and len(seen) < 500:
            name = todo.pop()
            if name not in seen:
                seen.add(name)
                for d in self.defs.get(name, ()):
                    if d not in self.refs:
                        self.refs[d] = refs(d)
                    todo += sorted(self.refs[d] - seen)
        return seen

    def resolve(self, s):
        """s with the macros this text gives a plain value, the Source and Patch
        file names and %_sourcedir (the tree) put in, as far as text can tell."""

        def put(m):
            name = m.group(1) or m.group(2)
            if m.group(3):
                name = ("SOURCE" if m.group(3) == "S" else "PATCH") + m.group(4)
            return self.vals.get(key(name), m.group(0))

        rx = r"%%\{[?]?(%s)\}|%%(%s)|%%\{([SP]):\s*([0-9]+)\}" % (NAME, NAME)
        for _ in range(8):
            t = re.sub(rx, put, s)
            if t == s:
                break
            s = t
        return s


def plain(d):
    """Whether definition line d gives a value of plain characters, its macro
    references aside: a version or a commit, never syntax or a path."""
    m = re.match(r"\s*%%(?:define|global)\s+%s\s+(.*)" % NAME, d, re.S)
    m = m or re.match(r"\s*[A-Za-z]+[0-9]*\s*:\s*(.*)", d, re.S)
    if not m or re.search(r"%(?:define|global|undefine)", m.group(1)):
        return False
    v = re.sub(r"%%\{[?!]*%s\}|%%%s" % (NAME, NAME), "", m.group(1))
    return PLAIN.fullmatch(v) is not None


def arg(line, end, braced):
    """The argument of the call that ends at end: to its closing brace, or to
    the next blank."""
    if not braced:
        rest = line[end:].lstrip(" \t:")
        return rest.split()[0] if rest.split() else ""
    depth, i = 1, end
    while i < len(line) and depth:
        depth += {"{": 1, "}": -1}.get(line[i], 0)
        i += 1
    return line[end : i - 1].lstrip(" \t:") if not depth else ""


def targets(line, index, names):
    """The files of names a running construct reads or names; None among them
    for an %include or %load whose file the text cannot tell."""
    if not READS & set(kinds(line, index)):
        return set()
    out = set()
    for m in re.finditer(r"(/?)([A-Za-z0-9_.+~@*?\[\]-]+)", index.resolve(line)):
        glob = m.group(1) and re.search(
            r"[*?\[]", m.group(2)
        )  # a path's, not a regex's
        out |= set(fnmatch.filter(names, m.group(2))) if glob else {m.group(2)} & names
    for m in INCLUDE_ARG.finditer(line):
        a = index.resolve(arg(line, m.end(), m.group(1) == "{"))
        a = a[2:] if a.startswith("./") else a
        if not a or "%" in a or ".." in a.split("/"):
            out.add(None)
        elif not a.startswith("/"):  # a host path is no file of the tree
            out.add(a)
    return out


def include_targets(line, text, names=()):
    """The files construct line reads or names, of names (the tree's files):
    what an %include or %load opens, and any word of it once the macros text
    defines are put in. None among them: an %include or %load whose file text
    cannot tell (a macro left, a path out of the tree)."""
    return targets(line, Index(logical(text)), set(names))


def moved(s, found, new, base, changed):
    """Why construct s, which base has verbatim, still counts as added."""
    reads = targets(s, new, changed)
    if None in reads:
        return "reads a file the text does not name"
    if reads & changed:
        return "reads %s, which differs" % ", ".join(sorted(reads & changed))
    simple = set(found) <= {"shell", "lua", "%%", "lone %"}
    for name in sorted(new.uses(s)):
        old = set(base.defs.get(name, ()))
        fresh = [d for d in new.defs.get(name, ()) if d not in old]
        joined = re.search(r"%%%%\{?[?!]*%s(?![A-Za-z0-9_])" % name, s, re.I)
        if fresh and not (simple and not joined and all(map(plain, fresh))):
            return "uses %%%s, defined anew" % name
    m = re.match(r"\s*%%(?:define|global)\s+(%s)\(" % NAME, s)
    if m:
        call = r"%%\{?[?!]*%s(?![A-Za-z0-9_])" % m.group(1)
        if any(
            u != s and u not in base.have and re.search(call, u) for _, u in new.lines
        ):
            return "a new line calls %%%s" % m.group(1)
    return ""


def added_constructs(new_text, base_text, changed=frozenset()):
    """(first line number, construct, why) of each construct new_text adds over
    base_text: one base_text lacks verbatim, or one it has that reads a file
    of changed (the files that differ from base's), uses a macro defined anew,
    or defines a parametric macro a new line calls."""
    new, base = Index(logical(new_text)), Index(logical(base_text))
    out = []
    for n, s in new.lines:
        found = kinds(s, new)
        if found:
            why = (
                "new"
                if s not in base.have
                else moved(s, found, new, base, set(changed))
            )
            if why:
                out.append((n, s, why))
    return out


def read(path):
    # no newline translation: rpm splits on LF alone, a CR stays in the line
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as fh:
        return fh.read()


def md5(path):
    h = hashlib.md5()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    except FileNotFoundError:
        return None
    return h.hexdigest()


def listed(path):
    """name -> md5 of each entry of an OBS directory listing; {} without one."""
    try:
        root = ET.parse(path).getroot()
    except FileNotFoundError:
        return {}
    return {e.get("name"): e.get("md5") for e in root.findall("entry")}


INCLUDE = re.compile(r"\s*%%?include(?![A-Za-z0-9_])")


def units(d, f, names, limit=64):
    """f's logical lines as rpm reads them, each %include of a file of d put in
    its place, as (file, line number, text, depth). An %include's file is named
    with the macros of all the text read so far, the spec's and every included
    file's alike; at most limit files go in, none deeper than 8."""
    lines = [(f, n, s, 0) for n, s in logical(read(os.path.join(d, f)))]
    done, count = set(), 0
    while count < limit:
        index = Index([(n, s) for _, n, s, _ in lines])
        for k, (src, n, s, depth) in enumerate(lines):
            if (src, n) in done or depth >= 8 or not INCLUDE.match(s):
                continue
            t = targets(s, index, names)
            inc = t.pop() if len(t) == 1 and None not in t else None
            if inc and os.path.isfile(os.path.join(d, inc)):
                text = read(os.path.join(d, inc))
                sub = [(inc, m, x, depth + 1) for m, x in logical(text)]
                lines, count = lines[:k] + sub + lines[k + 1 :], count + 1
                break
            done.add((src, n))
        else:
            break
    return lines


def inline(d, f, names):
    """f's physical lines as rpm reads them, each %include of a file of d put
    in its place (units()), and the file and line each came from."""
    out, where = [], []
    for src, n, s, _ in units(d, f, names):
        out += s.split("\n")
        where += [(src, n + k) for k in range(s.count("\n") + 1)]
    return out, where


def tree(d):
    """What d's specs and the files they include or load hold: the files to
    scan (the specs, an included file read in its place, and the loaded
    ones), the ones to read from Factory as text, and every file a construct
    other than an %include names, each named with the macros of all the text
    it is read with."""
    names = {n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n))}
    specs = sorted(n for n in names if n.endswith(".spec"))
    todo, seen, fetch, loaded, wanted = list(specs), set(), set(), set(), set()
    while todo and len(seen) < 64:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        lines = units(d, f, names)
        index = Index([(n, s) for _, n, s, _ in lines])
        read_in = {src for src, _, _, _ in lines}
        if len(read_in) > 1:
            fetch |= read_in
        for src, _, s, _ in lines:
            if not kinds(s, index):
                continue
            fetch |= {f, src}
            reads = (targets(s, index, names) - {None}) & names
            if INCLUDE_ARG.search(s):
                fetch |= reads
            if re.search(r"%\{?[?!]*load(?![A-Za-z0-9_])", s):
                loaded |= reads
                todo += sorted(reads)
            if not INCLUDE.match(s) or not reads <= read_in:
                wanted |= reads
    return specs + sorted(loaded - set(specs)), sorted(fetch & names), wanted


def show(f, n, s, why, found):
    """One line per construct, the lines it runs on below it, indented (10 at most)."""
    cut = [ln if len(ln) <= 160 else ln[:157] + "..." for ln in s.split("\n")]
    more = " (+%d lines)" % (len(cut) - 1) if len(cut) > 1 else ""
    out = ["%s:%d: %s%s — %s: %s" % (f, n, cut[0], more, ", ".join(found), why)]
    out += ["    " + ln for ln in cut[1:11]]
    if len(cut) > 11:
        out.append("    ... %d more lines" % (len(cut) - 11))
    return "\n".join(out)


def run(cmd, args):
    """The lines to print, each (file, line number, construct, kinds, why)."""
    if cmd == "constructs":
        text = read(args[0])
        index = Index(logical(text))
        return [
            (args[0], n, s, kinds(s, index), "construct") for n, s in constructs(text)
        ]
    if cmd == "added":
        new = read(args[0])
        index = Index(logical(new))
        base = read(args[1]) if os.path.exists(args[1]) else ""
        return [
            (args[0], n, s, kinds(s, index), why)
            for n, s, why in added_constructs(new, base)
        ]
    d, b = args[:2]
    files, _, wanted = tree(d)
    sums = listed(args[2]) if len(args) > 2 else {}
    changed = set()
    for f in wanted:
        old = os.path.join(b, f)
        if not os.path.exists(old) and sums.get(f) == md5(os.path.join(d, f)):
            continue
        if md5(old) != md5(os.path.join(d, f)):
            changed.add(f)
    names = {n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n))}
    found = []
    for f in files:
        new, where = inline(d, f, names)
        old = inline(b, f, names)[0] if os.path.exists(os.path.join(b, f)) else []
        index = Index(logical("\n".join(new)))
        for n, s, why in added_constructs("\n".join(new), "\n".join(old), changed):
            found.append(where[n - 1] + (s, kinds(s, index), why))
    return found


def main(argv):
    # no __pycache__ beside it is read or written
    sys.pycache_prefix = "/dev/null/opensuse-packaging"
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import _sanitize

    def say(text):
        # sanitized, and bytes that are no UTF-8 shown as \xNN, never a traceback
        clean = _sanitize.sanitize(text).encode("utf-8", "surrogateescape")
        print(clean.decode("utf-8", "backslashreplace"))

    cmd, args = (argv[0], argv[1:]) if argv else ("", [])
    want = {"constructs": [1], "added": [2], "needs": [1], "scan": [2, 3]}
    if len(args) not in want.get(cmd, []):
        usage = __doc__.split("Usage: ", 1)[1].split("\nExit")[0]
        print("Usage: " + usage, file=sys.stderr)
        return 2
    try:
        if cmd == "needs":
            say("\n".join(tree(args[0])[1]))
            return 0
        found = run(cmd, args)
        for f, n, s, kind, why in found:
            say(show(f, n, s, why, kind))
    except (OSError, UnicodeError, ET.ParseError) as e:
        say("cannot read %s: %s" % (getattr(e, "filename", None) or "a file", e))
        return 3
    except Exception as e:  # a bug here must not read as "nothing found"
        say("internal error: %s: %s" % (type(e).__name__, e))
        return 3
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
