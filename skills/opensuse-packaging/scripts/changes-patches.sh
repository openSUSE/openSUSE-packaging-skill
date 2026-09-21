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
#
# Usage: changes-patches.sh [DIR] [--target PRJ[/PKG]] [--base DIR] [--git-base REF]
#   DIR         package checkout (default .)
#   --target    SR target. Default: a branched osc checkout's link origin
#               (<linkinfo project=> in .osc/_files, or the API listing for an
#               osc-2.0 store that has none), else openSUSE:Factory.
#   --base DIR  offline: a directory holding the target's files (tests/CI);
#               a missing DIR means "new package" and passes with a note.
#   --git-base  git checkout: ref holding the target's tree (default: the
#               upstream tracking branch). For a fork PR pass the TARGET
#               remote's branch, e.g. origin/factory — your own branch already
#               contains the change and would compare clean.
# Output: factory-auto's own sentence per patch, plus a hint when the name is
# present but wrapped across lines.
# Exit: 0 = clean (or new package), 1 = findings, 2 = usage / lookup failure
#       (a failed lookup never reports clean).
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0;; esac
exec python3 - "$@" <<'PY'
import os, re, sys, difflib, subprocess, xml.etree.ElementTree as ET

def usage():
    print("usage: changes-patches.sh [DIR] [--target PRJ[/PKG]] [--base DIR] [--git-base REF]",
          file=sys.stderr); sys.exit(2)
def fail(msg):
    print(f"changes-patches: {msg}", file=sys.stderr); sys.exit(2)
def run(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr

args, d, target, base, gitbase, i = sys.argv[1:], ".", None, None, None, 0
while i < len(args):
    a = args[i]
    if a in ("--target", "--base", "--git-base"):
        if i + 1 >= len(args): usage()
        if a == "--target": target = args[i + 1]
        elif a == "--base": base = args[i + 1]
        else: gitbase = args[i + 1]
        i += 2
    elif a.startswith("-"): usage()
    else: d = a; i += 1
d = os.path.abspath(d)
PATCH = re.compile(r".*\.(patch|diff|dif)$")

def read(path):
    return open(path, encoding="utf-8", errors="replace").read() if os.path.isfile(path) else None

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
elif os.path.isdir(os.path.join(d, ".osc")):
    pkg = read(os.path.join(d, ".osc/_package")).strip()
    if os.path.exists(os.path.join(d, ".osc/_files")):
        files_xml = ET.parse(os.path.join(d, ".osc/_files")).getroot()
    else:
        # osc store 2.0 keeps no _files: ask the API for the same directory
        # listing (expanded, so a link shows its real files and linkinfo).
        prj = read(os.path.join(d, ".osc/_project")).strip()
        rc, out, err = run(["osc", "api", f"/source/{prj}/{pkg}?expand=1"])
        if rc != 0: fail(f"osc api /source/{prj}/{pkg} failed: {err.strip()[:200]}")
        files_xml = ET.fromstring(out)
    if target is None:
        li = files_xml.find("linkinfo")
        target = li.get("project") if li is not None and li.get("project") else "openSUSE:Factory"
    tprj, tpkg = target.split("/", 1) if "/" in target else (target, pkg)
    rc, out, err = run(["osc", "api", f"/source/{tprj}/{tpkg}?expand=1"])
    if rc != 0:
        if "404" in err or "does not exist" in err:
            print(f"OK: {tprj}/{tpkg} does not exist — new package, factory-auto skips this check")
            sys.exit(0)
        fail(f"osc api /source/{tprj}/{tpkg} failed: {err.strip()[:200]}")
    old_files = {e.get("name") for e in ET.fromstring(out).findall("entry")}
    def old_read(name):
        if name not in old_files: return None
        rc, out, err = run(["osc", "cat", tprj, tpkg, name])
        if rc != 0: fail(f"osc cat {tprj}/{tpkg}/{name} failed: {err.strip()[:200]}")
        return out
    new_files = {e.get("name") for e in files_xml.findall("entry")}
    rc, out, err = run(["osc", "status"], cwd=d)
    if rc != 0: fail(f"osc status failed: {err.strip()[:200]}")
    for line in out.splitlines():
        if len(line) > 4 and line[0] in "AD!":
            (new_files.add if line[0] == "A" else new_files.discard)(line[4:].strip())
    where = f"{tprj}/{tpkg}"
elif run(["git", "rev-parse", "--show-toplevel"], cwd=d)[0] == 0:
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
    fail(f"{d} is neither an osc checkout nor a git checkout, and no --base given")

def new_read(name): return read(os.path.join(d, name))

# --- factory-auto's algorithm, step for step ---------------------------------
opatches = {f for f in old_files if PATCH.match(f)}
npatches = {f for f in new_files if PATCH.match(f)}
common = opatches & npatches
to_mention = {p: "old" for p in opatches - common}
to_mention.update({p: "new" for p in npatches - common})
if not to_mention:
    print(f"OK: no patch added or removed vs {where}"); sys.exit(0)

plus_minus = []                      # only the +/- lines of the .changes diff count
for ch in sorted(f for f in new_files if f.endswith(".changes")):
    new, old = new_read(ch), old_read(ch)
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
    print(f"OK: every added/removed patch vs {where} is named in the .changes diff"); sys.exit(0)

glued, spaced = "".join(plus_minus), " ".join(plus_minus)
for p, state in sorted(to_mention.items()):
    verb, noun = ("added", "addition") if state == "new" else ("deleted", "removal")
    msg = f"A patch ({p}) is being {verb} without this {noun} being mentioned in the changelog."
    if p in glued or p in spaced:
        msg += " (it is there, but wrapped across lines — keep the filename on one line)"
    print(msg)
print(f"-> name each file literally, on one line, in the new .changes entry (compared against {where})",
      file=sys.stderr)
sys.exit(1)
PY
