#!/usr/bin/env python3
"""Upstream releases a new .changes entry skips, or describes a second time.

  changes-range.py [DIR] [--target PRJ[/PKG] | --base DIR] [--git-base REF]
  DIR         package checkout (default .)
  --target    osc checkout: the SR target (default: a branched checkout's link
              origin, else the committed copy, a direct commit's target)
  --base DIR  offline: a directory holding the target's spec and .changes; a
              missing DIR is a new package
  --git-base  git checkout: the ref holding the target's tree (default: the
              upstream tracking branch)

The old version is the target's spec Version, the new one the checkout's. The
releases strictly between them come from the source the spec names: Source0's
registry (PyPI, npm, crates.io) or forge, else URL:'s forge, else the
_service obs_scm url. GitHub counts its releases and the version tags that
have no release object, GitLab its tags. Not counted: drafts, yanked versions,
pre-releases (rc, alpha, beta, dev; on npm and crates.io any semver "-" part,
15.0.0-canary.1; on GitHub and GitLab a version that is not a plain number,
v2.0.0rc1), tags outside the Source0 or obs_scm revision tag scheme, a release
published after the new one (another branch; a bare GitHub tag has no date),
and one GitHub flags as a pre-release unless the old or new version is flagged
too (the package is on that track). A packaged pre-release sorts before its
release: 1.3.0~rc1 -> 1.3.0 crosses nothing.

  MISSING: V   a release between them that no version heading of the new
               entries names (a line starting with V or "Update to", wrapped
               lines included: "- Update to 1.3 (with 1.2.4):", "  * 1.2.4: ...")
  REPEATED: V  a version the new entries describe (a line that starts with it,
               or with "Update to V") and the target's .changes already does
  OLDER: V     the checkout's version is older than the target's (a stale
               branch, or a downgrade)

The new entries are the checkout's entries above the first one whose header
line (date and author) the target's .changes has; when the version moved and
none is new, the top entry was amended in place and is the new one. A lookup
that fails is UNKNOWN, never clean; findings that need no lookup are printed
all the same.

Exit: 0 clean, or nothing to compare (no version change, a new package) ·
1 findings · 2 usage, or no verdict (a lookup failed, no upstream to ask, the
new version is no upstream release, a snapshot version)
"""

import argparse
import builtins
import http.client
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _forges  # noqa: E402
import _sanitize  # noqa: E402  # escape/Unicode-smuggling filter for third-party text


# tag names and versions come from the forge: sanitize every printed line
def print(*args, **kw):  # noqa: A001
    builtins.print(
        *(_sanitize.sanitize(a) if isinstance(a, str) else a for a in args), **kw
    )


SEPARATOR = re.compile(r"(?m)^-{20,}[ \t]*$")
# The words that may lead a version heading, in any order: "Update to version",
# "Changes from version", "New upstream release", "includes".
_WORDS = (
    r"(?:(?:update[ds]?|upgraded?|bump(?:ed)?|to|the|new|upstream|versions?|"
    r"releases?|changes?|in|for|from|of|with|includes?|including|also|and)"
    r"[ \t]+){0,6}"
)
_BODY = r"(?:#+[ \t]*)?\[?" + _WORDS + r"v?(\d+(?:\.\d+)+)"
# a line describing a version: "- Update to version 1.2:", "  * 1.2: ...",
# "- Version 1.2 (skipped):", "## [1.2] - date"; a bullet or a line at column 0,
# since an indented line without a bullet wraps the one above
HEADING = re.compile(
    r"^(?:[ \t]*[-*+][ \t]*|(?=\S))"
    + _BODY
    + r"\]?(?=[ \t]*(?::|\(|,|$|[ \t]-[ \t]|[ \t]\u2014[ \t]))",
    re.I | re.M,
)
# a version: 0.9.98 or v0.9.98, not inside 10.9.98, 0.9.981, x0.9.98, 0.9.98rc1
# or a date (2026-02-01 names neither 2 nor 1)
MENTION = re.compile(r"(?<![\w.-])v?(\d+(?:\.\d+)*)(?!\w|\.\d|-\d)")
# what follows the numbers of a pre-release: 1.3.0~rc1, 15.0.0-canary.1, 2.0rc1
PRE = re.compile(
    r"[-~]|[._]?(?:a|b|c|rc|alpha|beta|pre|preview|dev)\d*(?:$|[.+])", re.I
)
# a line that starts with a version, at any indentation (pasted NEWS headings
# such as "  4.0.7 (released ...)"): the versions it names, wrapped lines
# included, are the ones the entry covers ("stop a running 0.8.6 daemon"
# covers nothing)
LEAD = re.compile(r"^[ \t]*(?:[-*+][ \t]*)?" + _BODY, re.I)
BULLET = re.compile(r"^[ \t]*[-*+][ \t]")


class NoVerdict(Exception):
    pass


def vkey(v):
    """(release numbers, 0 for a pre-release of it or 1, the rest's numbers),
    trailing zeros dropped: 1.0 == 1.0.0 < 1.0.1-rc.1 < 1.0.1 < 1.1."""
    m = re.match(r"\D*(\d+(?:\.\d+)*)(.*)", v or "")
    if not m:
        return ((), 1, ())
    rel = [int(x) for x in m.group(1).split(".")]
    while rel and rel[-1] == 0:
        rel.pop()
    rest = m.group(2)
    return (
        tuple(rel),
        0 if PRE.match(rest) else 1,
        tuple(int(x) for x in re.findall(r"\d+", rest)),
    )


def entries(text):
    return [e.strip("\n") for e in SEPARATOR.split(text or "") if e.strip()]


def named(text):
    """Keys of the versions the version headings of text name."""
    items = []
    for line in text.splitlines():
        if BULLET.match(line) or LEAD.match(line) or not items:
            items.append(line)
        elif line.strip():
            items[-1] += "\n" + line
    return {vkey(m) for it in items if LEAD.match(it) for m in MENTION.findall(it)}


def headings(text):
    return {vkey(m): m for m in HEADING.findall(text)}


def run(cmd, cwd=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        return 1, "", str(e)
    return p.returncode, p.stdout, p.stderr


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def osc_target(d, target):
    """(prj, pkg) the osc checkout in d is compared with, or None: the committed copy."""
    if target:
        prj, _, pkg = target.partition("/")
        return prj, pkg or read(os.path.join(d, ".osc/_package")).strip()
    files = read(os.path.join(d, ".osc/_files"))
    if files is None:
        # osc store 2.0 keeps no _files: the API has the same listing
        prj = read(os.path.join(d, ".osc/_project")).strip()
        pkg = read(os.path.join(d, ".osc/_package")).strip()
        rc, files, err = run(["osc", "api", f"/source/{prj}/{pkg}?expand=1"])
        if rc:
            raise NoVerdict(f"osc api /source/{prj}/{pkg} failed: {err.strip()[:200]}")
    try:
        li = ET.fromstring(files).find("linkinfo")
    except ET.ParseError as e:
        raise NoVerdict(f"cannot read the checkout's file list: {e}") from e
    if li is not None and li.get("project"):
        return li.get("project"), li.get("package")
    return None


def target_files(d, names, a):
    """({name: text or None}, where) of the target; None for a new package."""
    if a.base is not None:
        if not os.path.isdir(a.base):
            return None, a.base
        return {n: read(os.path.join(a.base, n)) for n in names}, a.base
    if os.path.isfile(os.path.join(d, ".osc/_package")) and not os.path.exists(
        os.path.join(d, ".osc/_scm")
    ):
        t = osc_target(d, a.target)
        if t is None:
            out = {}
            for n in names:
                out[n] = read(os.path.join(d, ".osc/sources", n))
                if out[n] is None:
                    out[n] = read(os.path.join(d, ".osc", n))
            return out, "the committed copy"
        prj, pkg = t
        out = {}
        for n in names:
            rc, text, err = run(["osc", "cat", prj, pkg, n])
            if rc and ("404" in err or "does not exist" in err):
                text = None
            elif rc:
                raise NoVerdict(f"osc cat {prj} {pkg} {n} failed: {err.strip()[:200]}")
            out[n] = text
        return out, f"{prj}/{pkg}"
    if run(["git", "rev-parse", "--show-toplevel"], cwd=d)[0] == 0:
        ref = a.git_base
        if ref is None:
            rc, ref, _ = run(
                [
                    "git",
                    "rev-parse",
                    "--abbrev-ref",
                    "--symbolic-full-name",
                    "@{upstream}",
                ],
                cwd=d,
            )
            ref = ref.strip()
            if rc or not ref:
                raise NoVerdict("no upstream tracking branch: pass --git-base REF")
        out = {}
        for n in names:
            rc, text, _ = run(["git", "show", f"{ref}:./{n}"], cwd=d)
            out[n] = text if rc == 0 else None
        return out, ref
    raise NoVerdict(f"{d} is no osc or git checkout: pass --base DIR")


def upstream(d, spec_text, version):
    """((kind, host, name), tag prefix) of the source to ask, or None."""
    _name, _ver, url, src = _forges.spec_facts(spec_text)
    service = read(os.path.join(d, "_service"))
    scm_url, rev = _forges.service_scm_url(service)
    # a name still carrying a macro is no identity (_forges.source_registry)
    forges = [_forges.parse_forge(c) for c in (src, url, scm_url)]
    forge = next((f for f in forges if f and "%" not in f"{f[1]}{f[2]}"), None)
    if forge is None:
        return None
    prefix = _forges.tag_prefix(src)
    if prefix is None:
        prefix = _forges.tag_prefix(url)
    if prefix is None and rev:
        rev = rev.removeprefix("refs/tags/")
        if version and rev.endswith(version):
            prefix = rev[: -len(version)]
    return forge, prefix


def label(src):
    kind, host, name = src
    return f"{kind}:{host}/{name}" if kind == "github" else f"{kind}:{name}"


def in_scheme(rels, new):
    """With no tag scheme known, the one of the tag that carries new: brotli's
    go/cbrotli/v1.1.0.bcr.1 is another stream than its v1.2.0."""

    def lead(r):
        return r["tag"][: len(r["tag"]) - len(r["version"])]

    own = sorted(
        (not r["object"], len(lead(r)), lead(r))
        for r in rels
        if vkey(r["version"]) == vkey(new)
    )
    if not own:
        return rels
    return [r for r in rels if lead(r) == own[0][2]]


def between(rels, old, new):
    """The releases strictly between old and new that the update crosses."""
    by_key = {}
    for r in rels:
        k = vkey(r["version"])
        if k[0] and (k not in by_key or (r["object"] and not by_key[k]["object"])):
            by_key[k] = r
    lo, hi = vkey(old), vkey(new)
    top = by_key.get(hi)
    if top is None:
        raise NoVerdict(
            f"{new} is not an upstream release there (a pre-release, a draft, or a "
            "tag outside the Source0 tag scheme): no range to check"
        )
    flagged_track = top["flagged"] or by_key.get(lo, {}).get("flagged", False)
    out = []
    for k, r in sorted(by_key.items()):
        if not lo < k < hi:
            continue
        if r["flagged"] and not flagged_track:
            continue
        if r["date"] and top["date"] and r["date"] > top["date"]:
            continue
        out.append(r)
    return out


def main():
    ap = argparse.ArgumentParser(
        prog="changes-range.py",
        description=__doc__.split("\n\n", 1)[0],
        epilog=__doc__.split("\n\n", 1)[1],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
    )
    ap.add_argument("dir", nargs="?", default=".", metavar="DIR")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--target", metavar="PRJ[/PKG]")
    g.add_argument("--base", metavar="DIR")
    ap.add_argument("--git-base", metavar="REF")
    a = ap.parse_args()
    d = os.path.abspath(a.dir)
    try:
        sys.exit(check(d, a))
    except NoVerdict as e:
        print(f"UNKNOWN: {e}")
        sys.exit(2)


def check(d, a):
    pkg = read(os.path.join(d, ".osc/_package"))
    pkg = pkg.strip() if pkg else os.path.basename(d)
    specs = sorted(f for f in os.listdir(d) if f.endswith(".spec"))
    spec = (
        f"{pkg}.spec"
        if f"{pkg}.spec" in specs
        else (specs[0] if len(specs) == 1 else None)
    )
    if spec is None:
        raise NoVerdict(f"no {pkg}.spec in {d}, and not exactly one *.spec")
    changes = spec[: -len(".spec")] + ".changes"
    new_spec, new_changes = read(os.path.join(d, spec)), read(os.path.join(d, changes))
    if new_changes is None:
        raise NoVerdict(f"no {changes} in {d}")
    old_files, where = target_files(d, (spec, changes), a)
    if old_files is None or old_files[spec] is None:
        print(f"OK: {where} has no {spec}: a new package, no range to check")
        return 0
    old = _forges.spec_facts(old_files[spec])[1]
    new = _forges.spec_facts(new_spec)[1]
    for v, side in ((old, where), (new, d)):
        if not v or "%" in v:
            raise NoVerdict(f"cannot read the Version of {spec} in {side}: {v!r}")
    if vkey(old) == vkey(new):
        print(f"OK: no version change ({new} in {where} and here)")
        return 0
    # the entries above the first one whose header (date and author) the target
    # has: a fix to an older entry's text does not make it new
    old_entries, mine = entries(old_files[changes]), entries(new_changes)
    seen, top = {e.split("\n", 1)[0] for e in old_entries}, []
    for e in mine:
        if e.split("\n", 1)[0] in seen:
            break
        top.append(e)
    amended = None
    if not top and mine:
        # the version moved but no header is new: the top entry was amended in
        # place (gate.sh --amend-top), and the target's copy of it repeats nothing
        top, amended = mine[:1], mine[0].split("\n", 1)[0]
    fresh = "\n".join(top)
    known = headings(
        "\n".join(e for e in old_entries if e.split("\n", 1)[0] != amended)
    )
    repeated = [v for k, v in sorted(headings(fresh).items()) if k in known]
    found = [
        f"REPEATED: {v}: the new entries describe it, and {where}'s {changes} already does"
        for v in repeated
    ]
    print(f"changes-range: {old} -> {new} against {where}")
    if vkey(new) < vkey(old):
        print(
            f"OLDER: {new} here is older than {old} in {where}: a downgrade, or a "
            "checkout the target has moved past"
        )
        print("VERDICT: 1 finding(s) — no range: the new version is not newer")
        return 1
    for line in found:
        print(line)
    try:
        if _forges.SNAPSHOT.search(old) or _forges.SNAPSHOT.search(new):
            raise NoVerdict("a snapshot version: no upstream release range to check")
        src = upstream(d, new_spec, new)
        if src is None:
            raise NoVerdict(
                "no upstream to ask: neither Source0, URL nor a _service obs_scm url "
                "names GitHub, GitLab, PyPI, npm or crates.io"
            )
        (kind, host, name), prefix = src
        try:
            rels = _forges.list_releases(kind, host, name, prefix)
        except (OSError, RuntimeError, ValueError, http.client.HTTPException) as e:
            raise NoVerdict(f"{label(src[0])} did not answer: {e}") from e
        crossed = between(
            rels if prefix is not None else in_scheme(rels, new), old, new
        )
    except NoVerdict as e:
        print(f"UNKNOWN: {e}")
        return 2
    covered = named(fresh)
    for r in crossed:
        if vkey(r["version"]) in covered:
            continue
        when = r["date"].date() if r["date"] else None
        how = f"tag {r['tag']}, no release object" if not r["object"] else when
        found.append(
            f"MISSING: {r['version']} ({how}): crossed, and the new entries never name it"
        )
        print(found[-1])
    span = (
        f"{len(crossed)} release(s) between {old} and {new}"
        if crossed
        else f"no upstream release between {old} and {new}"
    )
    if found:
        print(
            f"VERDICT: {len(found)} finding(s) — {label(src[0])}, {span}: name each "
            "crossed release in the new entry, and drop what the target already documents"
        )
        return 1
    print(
        f"VERDICT: CLEAN — {label(src[0])}, {span}{', each named' if crossed else ''}"
    )
    return 0


if __name__ == "__main__":
    # an uncaught exception would exit 1, which reads as findings
    try:
        main()
    except Exception:
        import traceback

        traceback.print_exc()
        print("UNKNOWN: internal error, no verdict")
        sys.exit(2)
