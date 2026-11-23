#!/bin/bash
# Local port of factory-auto's "patch not mentioned in the changelog" rule
# (openSUSE-release-tools check_source.py, detect_mentioned_patches). That bot
# auto-declines a Factory SR when a *.patch / *.diff / *.dif file is added to
# or removed from the package without its LITERAL filename appearing on a
# single added/removed line of the .changes diff between the SR target and the
# source. So a glob ("foo-*.patch"), a %{version} form, a rename described by
# one name only, or a filename split by the 67-column wrap all fail it — and a
# mention in an untouched older entry does not count. Files named on a
# Source: line are exempt; a brand-new package is skipped.
#
# Nothing else local checks this: changes-lint.sh is format-only,
# changes-guard.sh is insertion-only, source_validator only cross-checks
# spec<->files. Real case: a three-patch rename cost three SRs in a row —
# first described with a glob, then with the added side still a glob.
#
# It compares against the SR TARGET, not the checkout's last commit: in a
# branched checkout the renames are already committed, so a baseline diff sees
# no file delta at all — exactly the blind spot factory-auto does not have.
# A geectl working copy is a git checkout, so the target is the git ref
# (--git-base).
#
# Usage: changes-patches.sh [DIR] [--target PRJ[/PKG]] [--base DIR] [--git-base REF] [--entries N]
#   DIR         package checkout (default .)
#   --target    SR target. Default: a branched checkout's link origin, else
#               openSUSE:Factory; a checkout without --target is a direct commit
#               to its project: its entries count against the committed copy.
#               The target's files come from geectl list-files + remote cat.
#   --base DIR  offline: a directory holding the target's files (tests/CI);
#               a missing DIR means "new package" and passes with a note.
#   --git-base  git checkout: ref holding the target's tree (default: the
#               upstream tracking branch). For a fork PR pass the TARGET
#               remote's branch, e.g. origin/factory — your own branch already
#               contains the change and would compare clean.
#   --entries N entries the .changes may add vs the target (default 1): more
#               is a finding — typically a fix-up stacked as a second entry
#               instead of folded into the top one. Pass the real count when
#               the submission carries several on purpose (per-version entries
#               of a superseding SR, a forward from devel).
# Output: factory-auto's own sentence per patch, plus a hint when the name is
# present but wrapped across lines; a line per .changes adding too many entries.
# Exit: 0 = clean (or new package), 1 = findings, 2 = usage / lookup failure
#       (a failed lookup never reports clean).
set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 0;; esac
exec python3 -I - "$@" <<'PY'
import os, re, sys, difflib, subprocess, json

def usage():
    print("usage: changes-patches.sh [DIR] [--target PRJ[/PKG]] [--base DIR]"
          " [--git-base REF] [--entries N]", file=sys.stderr); sys.exit(2)
def fail(msg):
    print(f"changes-patches: {msg}", file=sys.stderr); sys.exit(2)
def run(cmd, cwd=None, timeout=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr

args, d, target, base, gitbase, maxnew, i = sys.argv[1:], ".", None, None, None, 1, 0
while i < len(args):
    a = args[i]
    if a in ("--target", "--base", "--git-base", "--entries"):
        if i + 1 >= len(args): usage()
        if a == "--target": target = args[i + 1]
        elif a == "--base": base = args[i + 1]
        elif a == "--entries":
            if not re.fullmatch(r"[1-9][0-9]*", args[i + 1]):
                fail(f"--entries takes a positive integer, got '{args[i + 1]}'")
            maxnew = int(args[i + 1])
        else: gitbase = args[i + 1]
        i += 2
    elif a.startswith("-"): usage()
    else: d = a; i += 1
d = os.path.abspath(d)
PATCH = re.compile(r".*\.(patch|diff|dif)$")

def read(path):
    return open(path, encoding="utf-8", errors="replace").read() if os.path.isfile(path) else None

count_old = count_where = None       # entries count against the target unless set
new_pkg = None                       # the target does not exist: only entries count
# --- the target ("old") side and the working ("new") file set -----------------
if base is not None:
    if not os.path.isdir(base):
        print(f"OK: no target snapshot at {base} — new package, factory-auto skips this check")
        sys.exit(0)
    old_files = {f for f in os.listdir(base) if os.path.isfile(os.path.join(base, f))}
    def old_read(name): return read(os.path.join(base, name))
    new_files = {f for f in os.listdir(d)
                 if os.path.isfile(os.path.join(d, f)) and not f.startswith(".")}
    where = base
elif os.path.isdir(os.path.join(d, ".osc")) and not os.path.exists(os.path.join(d, ".osc/_scm")):
    if not os.path.isfile(os.path.join(d, ".osc/_package")):
        fail(f"{d}: osc project checkout — cd into the package directory")
    pkg = read(os.path.join(d, ".osc/_package")).strip()
    prj = read(os.path.join(d, ".osc/_project")).strip()
    new_files = {f for f in os.listdir(d)
                 if os.path.isfile(os.path.join(d, f)) and not f.startswith(".")}
    # A link's listing holds only _link: resolve it by hand, like the other
    # scripts, so the comparison sees the target's real files.
    def list_files(p, k, rev=None):
        cmd = ["geectl", "remote", "list-files", p, k]
        if rev is not None:
            cmd += ["--rev", str(rev)]
        rc, out, err = run(cmd, timeout=60)
        if rc != 0:
            return None if "not_found" in err else "FAILED"
        try:
            payload = json.loads(out)
        except ValueError:
            return "FAILED"
        files = [(f.get("name"), f.get("md5")) for f in payload.get("files", [])]
        tag = None
        if any(n == "_link" for n, _ in files):
            rc, out, err = run(["geectl", "remote", "cat", p, k, "_link", "--format", "text"], timeout=60)
            if rc != 0:
                return "FAILED"
            m = re.search(r"<link\b[^>]*>", out or "")
            tag = m.group(0) if m else ""
        return (files, tag)
    def expanded(p, k):
        got = list_files(p, k)
        if got is None or got == "FAILED":
            return got
        files, tag = got
        depth = 0
        while tag is not None and depth < 5:
            depth += 1
            def attr(name, _tag=tag):
                mm = re.search(rf'\b{name}="([^"]*)"', _tag)
                return mm.group(1) if mm else ""
            tprj, tpkg, trev = attr("project"), attr("package"), attr("rev")
            if not tprj or not tpkg:
                return "FAILED"
            got = list_files(tprj, tpkg, trev or None)
            if got is None or got == "FAILED":
                return got
            tfiles, tag = got
            merged = {n: m for n, m in tfiles if n != "_link"}
            merged.update({n: m for n, m in files if n != "_link"})
            files = sorted(merged.items())
            p, k = tprj, tpkg
        if tag is not None:
            return "FAILED"
        return (p, k, files)
    if target is None:
        # the checkout's link origin, else Factory; a direct commit's entries
        # count against the committed copy, not the target
        rc, out, err = run(["geectl", "remote", "link-target", prj, pkg], timeout=60)
        if rc != 0:
            fail(f"geectl remote link-target {prj} {pkg} failed: {err.strip()[:200]}")
        try:
            origin = (json.loads(out).get("target") or {})
        except ValueError:
            fail(f"geectl remote link-target {prj} {pkg} did not parse")
        if origin.get("project"):
            target = f"{origin['project']}/{origin.get('package') or pkg}"
        else:
            target = "openSUSE:Factory"
            def count_old(name):
                for pp in (".osc/sources", ".osc"):
                    txt = read(os.path.join(d, pp, name))
                    if txt is not None: return txt
                return None
            count_where = "the committed copy"
    tprj, _, tpkg = target.partition("/")
    tpkg = tpkg or pkg
    got = expanded(tprj, tpkg)
    if got is None:
        if count_old is None:
            print(f"OK: {tprj}/{tpkg} does not exist — new package, factory-auto skips this check")
            sys.exit(0)
        new_pkg = f"OK: {tprj}/{tpkg} does not exist — new package, factory-auto skips this check"
        old_files, eprj, epkg = set(), tprj, tpkg
    elif got == "FAILED":
        fail(f"geectl remote list-files {tprj}/{tpkg} failed")
    else:
        eprj, epkg, files = got
        old_files = {n for n, _ in files}
    def old_read(name):
        if name not in old_files: return None
        rc, out, err = run(["geectl", "remote", "cat", eprj, epkg, name, "--format", "text"], timeout=60)
        if rc != 0: fail(f"geectl remote cat {eprj}/{epkg}/{name} failed: {err.strip()[:200]}")
        return out
    where = f"{tprj}/{tpkg}"
elif run(["git", "rev-parse", "--show-toplevel"], cwd=d)[0] == 0:
    # A geectl working copy is a git checkout: the target is the git ref, and
    # the working tree is the new side — no OBS listing is read at all.
    if os.path.exists(os.path.join(d, ".osc/_scm")):
        print("note: scmsync package — comparing the git tree")
    ref = gitbase
    if ref is None:
        rc, out, _ = run(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd=d)
        ref = out.strip() if rc == 0 and out.strip() else None
        if ref is None:
            fail("git checkout without an upstream branch — pass --git-base <target-remote>/<branch>")
        print(f"note: comparing against {ref}; for a fork PR pass --git-base <target-remote>/<branch>")
    rc, out, err = run(["git", "ls-tree", "-r", "--name-only", ref], cwd=d)
    if rc != 0: fail(f"git ls-tree {ref} failed: {err.strip()[:200]}")
    old_files = {l.strip() for l in out.splitlines() if l.strip() and "/" not in l}
    def old_read(name):
        rc, out, _ = run(["git", "show", f"{ref}:./{name}"], cwd=d)
        return out if rc == 0 else None
    rc, out, err = run(["git", "ls-files", "--cached"], cwd=d)
    if rc != 0: fail(f"git ls-files failed: {err.strip()[:200]}")
    new_files = {l.strip() for l in out.splitlines() if l.strip() and "/" not in l}
    where = ref
else:
    fail(f"{d} is neither a git checkout, and no --base given")

def new_read(name): return read(os.path.join(d, name))

# --- one submission, one entry (runs whenever a target was resolved) ----------
changes = {ch: (new_read(ch), old_read(ch))
           for ch in sorted(f for f in new_files if f.endswith(".changes"))}
def nentries(txt): return sum(1 for l in txt.splitlines() if re.fullmatch(r"-{3,}\s*", l))
stacked = []
for ch, (new, old) in changes.items():
    old = count_old(ch) if count_old else old
    if new is None or old is None: continue
    n = nentries(new) - nentries(old)
    if n > maxnew:
        stacked.append(f"{ch}: {n} new entries vs {count_where or where}, expected at most"
                       f" {maxnew} — fold a fix-up into the top entry; for {n} deliberate"
                       f" per-version entries pass --entries {n}")
def done(msg):                       # the entry finding last; no "OK:" on a red run
    print(msg[4:] if stacked and msg.startswith("OK: ") else msg)
    for m in stacked: print(m)
    sys.exit(1 if stacked else 0)
if new_pkg:
    done(new_pkg)

# --- factory-auto's algorithm, step for step ---------------------------------
opatches = {f for f in old_files if PATCH.match(f)}
npatches = {f for f in new_files if PATCH.match(f)}
common = opatches & npatches
to_mention = {p: "old" for p in opatches - common}
to_mention.update({p: "new" for p in npatches - common})
if not to_mention:
    done(f"OK: no patch added or removed vs {where}")

plus_minus = []                      # only the +/- lines of the .changes diff count
for ch, (new, old) in changes.items():
    if new is None: continue
    lines = (["+" + l for l in new.splitlines(True)] if old is None
             else list(difflib.unified_diff(old.splitlines(True), new.splitlines(True))))
    plus_minus += [l[1:].strip() for l in lines if l[:1] in "+-"]
for p in list(to_mention):
    if any(p in l for l in plus_minus): del to_mention[p]

srcs = set()                         # a file named on a Source: line is exempt
for spec in sorted(f for f in (new_files | old_files) if f.endswith(".spec")):
    for txt in (new_read(spec), old_read(spec)):
        for line in (txt or "").splitlines():
            m = re.match(r"Source[0-9]*\s*:\s*(.*)$", line)
            if m: srcs.add(m.group(1).strip())
for s in srcs: to_mention.pop(s, None)

if not to_mention:
    done(f"OK: every added/removed patch vs {where} is named in the .changes diff")

glued, spaced = "".join(plus_minus), " ".join(plus_minus)
for p, state in sorted(to_mention.items()):
    verb, noun = ("added", "addition") if state == "new" else ("deleted", "removal")
    msg = f"A patch ({p}) is being {verb} without this {noun} being mentioned in the changelog."
    if p in glued or p in spaced:
        msg += " (it is there, but wrapped across lines — keep the filename on one line)"
    print(msg)
for m in stacked: print(m)
print(f"-> name each file literally, on one line, in the new .changes entry (compared against {where})",
      file=sys.stderr)
sys.exit(1)
PY
