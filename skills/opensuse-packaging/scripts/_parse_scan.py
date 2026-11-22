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
differs counts as a whole. A file such a line names must come out of macros
with one value each that the text gives before the line: a plain %define or
%global of one word, or a tag, outside %if and never given another, none a
loaded file defines, and no Lua line that defines macros; an escaped line is
read with its escapes live. Any other name (one the text never defines, a
conditional, %{expand:} or %undefine definition) and a lone % or glue, which
joins code nobody can name, give an "incomplete:" line.
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
  A file that leaves DIR once its links are followed is never read and is
  reported; where a cap stops the scan (an %include deeper than 8, more than
  64 files, a file or included text past 8 MiB, a macro expanding past 64 KiB,
  32 MiB of macro text resolved, a line using 500 macros) an "incomplete:"
  line says so, as for a name without one value, and nothing counts as verbatim.
Exit: 0 = no construct found (constructs) or added (added, scan); needs: listed
      1 = found or added, 2 = usage, 3 = a file it cannot read, or an internal
      error, 4 = nothing found, but the scan stopped short or could not name a
      file for sure (incomplete:)
"""

import fnmatch
import functools
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
SOURCE_KEY = re.compile(r"(source|patch)(?:url)?([0-9]+)")
# what rpm's line reader counts: an escape, a macro that opens, a bracket
TOKEN = re.compile(r"\\.?|%[{(\[%]|[{}()\[\]]")
PLAIN_DEF = re.compile(r"\s*%%(define|global)\s+(%s)\s+(\S+)$" % NAME)
LAZY = re.compile(r"\s*%%define\s+(%s)" % NAME)  # a body that runs where it is used
ONE_WORD = re.compile(r"\s*[A-Za-z]+[0-9]*(?:\([^)]*\))?\s*:\s*(\S+)$")
PUT = re.compile(r"%%\{[?]?(%s)\}|%%(%s)|%%\{([SP]):\s*([0-9]+)\}" % (NAME, NAME))
USE = re.compile(r"%%\{?[?!]*(%s)(?::\s*([0-9]+))?" % NAME)
IF = re.compile(r"\s*%(?:if|ifarch|ifnarch|ifos|ifnos)(?![A-Za-z0-9_])")
ENDIF = re.compile(r"\s*%endif(?![A-Za-z0-9_])")
LOAD = re.compile(r"%\{?[?!]*load(?![A-Za-z0-9_])")
MACRO = re.compile(r"^[ \t]*%%(%s)" % NAME, re.M)  # a macro file's definition
LUA_DEFINES = re.compile(r"rpm\s*\.\s*(?:un)?define|macros\s*[.\[]")
# rpm's own macros and directives: what they give comes from their arguments
BUILTINS = set(RUNS + RESHAPES) | {"expand", "quote", "shescape", "expr", "exists"}
BUILTINS |= {"defined", "undefined", "echo", "warn", "error", "verbose", "trace"}
BUILTINS |= {"dump", "dnl", "define", "global", "undefine", "if", "elif", "else"}
BUILTINS |= {"endif", "ifarch", "ifnarch", "ifos", "ifnos"}
# how far a scan goes before it stops short and says so
MAX_DEPTH, MAX_FILES, MAX_BYTES, MAX_EXPANSION = 8, 64, 8 << 20, 64 << 10
MAX_USES, MAX_CACHE, MAX_RESOLVED, MAX_NAMED = 500, 8 << 20, 32 << 20, 20


def note(notes, why):
    if why not in notes:
        notes.append(why)


def key(name):
    """The name rpm keeps a macro under: a tag's in either case (%{URL} is
    %{url}, %{SOURCEURL0} reads Source0), any other as written."""
    low = name.lower()
    m = SOURCE_KEY.fullmatch(low)
    if m:
        return "%s%d" % (m.group(1), int(m.group(2)))
    return low if low in TAGS else name


def logical(text):
    """(first line number, text) of each line as rpm reads it."""
    out, cur, first, depth = [], [], 0, {"{": 0, "(": 0, "[": 0}
    close = {"}": "{", ")": "(", "]": "["}
    for n, raw in enumerate(text.split("\n"), 1):
        line = raw.split("\0", 1)[0].rstrip()
        if not cur and "%" not in line and not line.endswith("\\"):
            out.append((n, line))  # no macro opens or continues on it
            continue
        if not cur:
            first = n
        cur.append(line)
        cont = False
        for m in TOKEN.finditer(line):
            t = m.group()
            if t[0] == "\\":
                cont = t == "\\" and m.end() == len(line)
            elif t[0] == "%":
                if t != "%%":
                    depth[t[1]] += 1
            elif t in depth:
                if depth[t]:
                    depth[t] += 1
            elif depth[close[t]]:
                depth[close[t]] -= 1
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
    if "%" not in s:
        return []
    if index is not None and s in index.kinds:
        return index.kinds[s]
    found = _kinds(s, index)
    if index is not None:
        index.kinds[s] = found
    return found


def _kinds(s, index):
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


def named(s):
    """The macros line s names (%{S:1} as SOURCE1), but those behind a %%."""
    out = set()
    for m in USE.finditer(s.replace("%%", "\0")):
        name, num = m.group(1), m.group(2)
        if name in ("S", "P") and num:
            name = ("SOURCE" if name == "S" else "PATCH") + num
        out.add(key(name))
    return out


def refs(s):
    """The macros line s uses, but those it defines."""
    return named(s) - {key(n) for n in DEFINE.findall(s.replace("%%", "\0"))}


class Index:
    """What a text's logical lines define, looked up once: each macro's
    defining lines (%define, %global, %undefine, or the tag rpm sets it from),
    and the values a file name can be resolved with. A macro has one only when
    each definition of it is a plain one outside %if (a %define or %global of
    one word, a tag), all alike: rpm takes the one in force at each line, which
    text read whole cannot tell."""

    spent = 0  # the macro text resolved in this run, every text's together

    def __init__(self, lines):
        self.lines, self.have, self.defs, self.refs = [], set(), {}, {}
        self.vals, self.ambiguous, self.short = {"_sourcedir": "."}, set(), []
        self.vals["nil"] = ""
        # where each line and each macro's first definition is; the macros noted
        self.at, self.first, self.unsure = {}, {}, set()
        # %if nesting; a Lua or %load line that may define any macro; and the
        # macros a %load line's files define (None: not known), where known
        self.depth, self.hidden, self.loads = 0, False, None
        self.kinds, self.resolved, self.reads, self.cached = {}, {}, {}, 0
        self.users, self.ran = None, {}  # the lines that use each macro; runs_at()
        self.extend(lines)

    def value(self, name, v):
        """A definition of name: v, or None for one that gives no single value."""
        if v is None or "%" in PUT.sub("", v) or self.vals.setdefault(name, v) != v:
            self.ambiguous.add(name)

    def extend(self, lines):
        for n, d in lines:
            self.at.setdefault(d, len(self.lines))
            self.lines.append((n, d))
            self.have.add(d)
            if self.ran or self.users is not None:
                self.users, self.ran = None, {}
            if "%" not in d and ":" not in d:
                continue
            if IF.match(d):
                self.depth += 1
            elif ENDIF.match(d):
                self.depth = max(self.depth - 1, 0)
            if self.define(d) and (self.kinds or self.resolved or self.reads):
                # worked out with the definitions before this line
                self.kinds, self.resolved, self.reads, self.cached = {}, {}, {}, 0

    def define(self, d):
        """Take in what line d defines; whether it defines anything."""
        pos, top, hidden = len(self.lines) - 1, not self.depth, self.hidden
        for name in {key(n) for n in DEFINE.findall(d.replace("%%", "\0"))}:
            self.defs.setdefault(name, []).append(d)
        m = PLAIN_DEF.match(d)
        found = {key(n) for n in DEFINE.findall(d)}  # behind a %% too
        for name in found:
            if m and top and name == key(m.group(2)):
                # a %global's value is expanded once as it is defined
                v = m.group(3)
                self.value(name, v.replace("%%", "%") if m.group(1) == "global" else v)
            else:
                self.value(name, None)
        t = TAG.match(d)
        tag = t.group(1).lower() if t else ""
        file = tag in ("source", "patch")
        if file or tag in TAGS and not t.group(2):
            tag = "%s%d" % (tag, int(t.group(2) or 0)) if file else tag
            self.defs.setdefault(tag, []).append(d)
            v = ONE_WORD.match(d)
            v = v.group(1).replace("%%", "%") if v and top else None
            if v and file:  # the file a URL names
                v = v.split("#/")[-1].rsplit("/", 1)[-1]
            self.value(tag, v)
            found.add(tag)
        if LOAD.search(d):
            got = self.loads(d) if self.loads else None
            self.hidden = self.hidden or got is None
            for name in got or ():
                self.value(name, None)
                found.add(name)
        if "lua" in d and LUA_DEFINES.search(d) and "lua" in kinds(d):
            self.hidden = True
        for name in found:
            self.first.setdefault(name, pos)
        return bool(found) or self.hidden != hidden

    def uses(self, s):
        """Each macro line s uses, through the definitions this text gives."""
        seen, todo = set(), sorted(refs(s))
        while todo:
            if len(seen) >= MAX_USES:
                note(self.short, "a line uses more than 500 macros")
                break
            name = todo.pop()
            if name not in seen:
                seen.add(name)
                for d in self.defs.get(name, ()):
                    if d not in self.refs:
                        self.refs[d] = refs(d)
                    todo += sorted(self.refs[d] - seen)
        return seen

    def resolve(self, s):
        """s with the values this text gives its macros put in (the Source and
        Patch file names, %_sourcedir as the tree), and the names put in; s as
        written and none where that passes a cap."""
        if s in self.resolved:
            return self.resolved[s]
        found = self._resolve(s)
        if self.cached + len(found[0]) <= MAX_CACHE:
            self.cached += len(found[0])
            self.resolved[s] = found
        return found

    def _resolve(self, s):
        first, used = s, set()
        for _ in range(8):
            out, size, end = [], 0, 0
            for m in PUT.finditer(s):
                name = m.group(1) or m.group(2)
                if m.group(3):
                    name = ("SOURCE" if m.group(3) == "S" else "PATCH") + m.group(4)
                name = key(name)
                if name in self.ambiguous or name not in self.vals:
                    continue
                size += m.start() - end + len(self.vals[name])
                if size > MAX_EXPANSION:  # measured before the text is built
                    note(self.short, "a macro expands past 64 KiB")
                    return first, set()
                out += [s[end : m.start()], self.vals[name]]
                end = m.end()
                used.add(name)
            if not out:
                break
            size += len(s) - end
            if size > MAX_EXPANSION:
                note(self.short, "a macro expands past 64 KiB")
                return first, set()
            if Index.spent + size > MAX_RESOLVED:
                note(self.short, "more than 32 MiB of macro text resolved")
                return first, set()
            Index.spent += size
            s = "".join(out) + s[end:]
        return s, used

    def runs_at(self, s, seen=frozenset()):
        """Where line s runs: where it is; for a %define, the first use of the
        macro after it, a %define's in turn (its own place if none, or past 50)."""
        pos = self.at.get(s, len(self.lines))
        m = LAZY.match(s)
        if not m or key(m.group(1)) in seen or len(seen) > 50:
            return pos
        if s not in self.ran:
            if self.users is None:
                self.users = {}
                for _, u in self.lines:
                    for name in refs(u) if "%" in u else ():
                        self.users.setdefault(name, []).append(u)
            name = key(m.group(1))
            later = [
                self.runs_at(u, seen | {name})
                for u in self.users.get(name, ())
                if self.at.get(u, -1) > pos
            ]
            self.ran[s] = min(later, default=pos)
        return self.ran[s]

    def doubts(self, s, pos):
        """The macros line s, read at pos, names without one value the text gives
        before it: each one left once resolved, each one put in from a definition
        after it; and each one, where a Lua or %load line may define any."""
        t, used = self.resolve(s)
        out = named(t) - BUILTINS
        out |= {n for n in used if self.first.get(n, -1) > pos}
        return out | used if self.hidden else out

    def doubt(self, name):
        if name in self.unsure:
            return
        self.unsure.add(name)
        why = "%%%s has no single value the text gives, so a file read through it"
        if len(self.unsure) > MAX_NAMED:
            note(self.short, "more than 20 macros have no single value the text gives")
        else:
            note(self.short, why % name + " is not known")


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


def targets(line, index, names, found=None):
    """The files of names a running construct reads or names; None among them
    for an %include or %load whose file the text cannot tell. found: the
    line's kinds, when known."""
    if (line, names) not in index.reads:
        index.reads[line, names] = _targets(line, index, names, found)
    return set(index.reads[line, names])


def _targets(line, index, names, found):
    found = kinds(line, index) if found is None else found
    pos = index.runs_at(line)
    if {"lone %", "glue"} & set(found):
        why = "a lone % or glue joins code at parse time: what it reads is not known"
        note(index.short, why)
    if "%%" in found and not READS & set(found):
        # read as a later expansion leaves it, every escape live
        line = re.sub("%%+", "%", line)
        found = kinds(line, index)
    if not READS & set(found):
        return set()
    for name in sorted(index.doubts(line, pos)):
        index.doubt(name)
    out = set()
    for m in re.finditer(r"(/?)([A-Za-z0-9_.+~@*?\[\]-]+)", index.resolve(line)[0]):
        glob = m.group(1) and re.search(
            r"[*?\[]", m.group(2)
        )  # a path's, not a regex's
        out |= set(fnmatch.filter(names, m.group(2))) if glob else {m.group(2)} & names
    for m in INCLUDE_ARG.finditer(line):
        a = index.resolve(arg(line, m.end(), m.group(1) == "{"))[0]
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
    return targets(line, Index(logical(text)), frozenset(names))


def moved(s, found, new, base, changed):
    """Why construct s, which base has verbatim, still counts as added."""
    reads = targets(s, new, changed, found)
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


def added_constructs(new_text, base_text, changed=frozenset(), notes=None):
    """(first line number, construct, why) of each construct new_text adds over
    base_text: one base_text lacks verbatim, or one it has that reads a file
    of changed (the files that differ from base's), uses a macro defined anew,
    or defines a parametric macro a new line calls. notes, a list, gets why the
    comparison stopped short of the whole text."""
    found = added(Index(logical(new_text)), Index(logical(base_text)), changed, notes)
    return [(n, s, why) for n, s, _, why in found]


def added(new, base, changed=frozenset(), notes=None):
    """added_constructs() over two Index objects, each finding with its kinds."""
    out, changed = [], frozenset(changed)
    for n, s in new.lines:
        found = kinds(s, new)
        if found:
            why = "new" if s not in base.have else moved(s, found, new, base, changed)
            if why:
                out.append((n, s, found, why))
    for why in new.short + base.short if notes is not None else ():
        note(notes, why)
    return out


@functools.lru_cache(maxsize=256)
def file_lines(path):
    """path's logical lines, read once per run however often it is included."""
    return tuple(logical(read(path)))


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


def inside(d, path):
    """Whether path, below d, stays in d once every link in it is followed."""
    root = os.path.realpath(d)
    return os.path.realpath(os.path.join(d, path)).startswith(root + os.sep)


def files_of(d):
    """d's top-level files: those that stay in d, and links that leave it."""
    names, out = set(), set()
    for n in os.listdir(d):
        if os.path.isfile(os.path.join(d, n)):
            (names if inside(d, n) else out).add(n)
    return frozenset(names), frozenset(out)


def units(d, f, names):
    """f's logical lines as rpm reads them, each %include of a file of d put in
    its place, as (file, line number, text, depth); the %include lines whose
    file leaves d, which are not read, as (file, line number, text, why); why
    the text could not be read whole; and its index, built in reading order. An
    %include's file is named with the macros of the text read before it, the
    spec's and every included file's, as rpm names it."""
    if os.path.getsize(os.path.join(d, f)) > MAX_BYTES:
        return [], [], ["a file past 8 MiB was not read: %s" % f], Index([])
    todo = [(f, n, s, 0) for n, s in reversed(file_lines(os.path.join(d, f)))]
    lines, index, left, notes, count, size = [], Index([]), [], [], 0, 0
    index.loads = lambda s: loaded(d, s, index, names)
    while todo:
        src, n, s, depth = todo.pop()
        t = targets(s, index, names) if INCLUDE.match(s) else {None}
        inc = t.pop() if len(t) == 1 and None not in t else None
        if inc and not inside(d, inc):
            left.append((src, n, s, "leaves the checkout"))
        elif inc and os.path.isfile(os.path.join(d, inc)):
            size += os.path.getsize(os.path.join(d, inc))
            if depth >= MAX_DEPTH:
                note(notes, "an %include past depth 8 was not read")
            elif count >= MAX_FILES:
                note(notes, "more than 64 included files")
            elif size > MAX_BYTES:
                note(notes, "more than 8 MiB of included text")
            else:
                sub = file_lines(os.path.join(d, inc))
                todo += [(inc, m, x, depth + 1) for m, x in reversed(sub)]
                count += 1
                continue
        lines.append((src, n, s, depth))
        index.extend([((src, n), s)])
    for why in index.short:
        note(notes, why)
    return lines, left, notes, index


def loaded(d, s, index, names):
    """The macros the files %load line s loads define; None where a file is
    not one of d's to read."""
    out = set()
    for f in targets(s, index, names):
        path = f and os.path.join(d, f)
        if not f or not inside(d, f) or not os.path.isfile(path):
            return None
        if os.path.getsize(path) > MAX_BYTES:
            return None
        out |= {key(n) for n in MACRO.findall(read(path))}
    return out


@functools.lru_cache(maxsize=64)
def units_of(d, f, names):
    """units(), worked out once per run for each file of each tree."""
    return units(d, f, names)


def tree(d):
    """What d's specs and the files they include or load hold: the files to
    scan (the specs, an included file read in its place, and the loaded
    ones), the ones to read from Factory as text, and every file a construct
    other than an %include names, each named with the macros of all the text
    it is read with; then what leaves d (never read), and why the text could
    not be read whole."""
    names, out = files_of(d)
    specs = sorted(n for n in names if n.endswith(".spec"))
    left = [
        (n, 0, "", "a link that leaves the checkout, not read")
        for n in sorted(out)
        if n.endswith(".spec")
    ]
    todo, seen, fetch, loaded, wanted, notes = (
        list(specs),
        set(),
        set(),
        set(),
        set(),
        [],
    )
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        if len(seen) >= MAX_FILES:
            note(notes, "more than 64 loaded files")
            break
        seen.add(f)
        lines, gone, why, index = units_of(d, f, names)
        left += gone
        for w in why:
            note(notes, w)
        read_in = {src for src, _, _, _ in lines}
        if len(read_in) > 1:
            fetch |= read_in
        gone = {(src, n) for src, n, _, _ in gone}
        for src, n, s, _ in lines:
            found = kinds(s, index)
            if not found:
                continue
            fetch |= {f, src}
            reads = targets(s, index, names | out, found) - {None}
            if reads & out and (src, n) not in gone:
                left.append((src, n, s, "names a link that leaves the checkout"))
            reads &= names
            if INCLUDE_ARG.search(s):
                fetch |= reads
            if re.search(r"%\{?[?!]*load(?![A-Za-z0-9_])", s):
                loaded |= reads
                todo += sorted(reads)
            if not INCLUDE.match(s) or not reads <= read_in:
                wanted |= reads
        for w in index.short:
            note(notes, w)
    files = specs + sorted(loaded - set(specs))
    return files, sorted(fetch & names), wanted, left, notes


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
    """What to print: each finding as (file, line number, construct, kinds, why),
    and why the scan stopped short of the whole text."""
    notes = []

    def text(path):
        if os.path.getsize(path) <= MAX_BYTES:
            return read(path)
        note(notes, "a file past 8 MiB was not read: %s" % os.path.basename(path))
        return ""

    if cmd == "constructs":
        new = text(args[0])
        index = Index(logical(new))
        found = [
            (args[0], n, s, kinds(s, index), "construct") for n, s in constructs(new)
        ]
        return found, notes
    if cmd == "added":
        new = text(args[0])
        index = Index(logical(new))
        base = text(args[1]) if os.path.exists(args[1]) else ""
        found = added_constructs(new, base, notes=notes)
        return [(args[0], n, s, kinds(s, index), why) for n, s, why in found], notes
    d, b = args[:2]
    files, _, wanted, left, notes = tree(d)
    sums = listed(args[2]) if len(args) > 2 else {}
    changed = set()
    for f in wanted:
        old = os.path.join(b, f)
        if not os.path.exists(old) and sums.get(f) == md5(os.path.join(d, f)):
            continue
        if md5(old) != md5(os.path.join(d, f)):
            changed.add(f)
    names = files_of(d)[0]
    found = [(f, n, s, ["include"] if s else ["file"], why) for f, n, s, why in left]
    for f in files:
        _, _, why, new = units_of(d, f, names)
        base = Index([])
        if os.path.exists(os.path.join(b, f)):
            _, _, bwhy, base = units_of(b, f, names)
            why = why + bwhy
        for w in why:
            note(notes, w)
        for (src, n), s, kind, w in added(new, base, changed, notes):
            found.append((src, n, s, kind, w))
    return found, notes


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
        found, notes = run(cmd, args)
        for f, n, s, kind, why in found:
            say(show(f, n, s, why, kind) if n else "%s: %s" % (f, why))
        for why in notes:
            say("incomplete: %s" % why)
    except (OSError, UnicodeError, ET.ParseError) as e:
        say("cannot read %s: %s" % (getattr(e, "filename", None) or "a file", e))
        return 3
    except Exception as e:  # a bug here must not read as "nothing found"
        say("internal error: %s: %s" % (type(e).__name__, e))
        return 3
    return 1 if found else 4 if notes else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
