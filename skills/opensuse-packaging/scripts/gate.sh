#!/bin/bash
# The commit/SR gate chain as ONE tool call: the SR target, source_validator,
# factory-auto's URL check (download_files), spec-cleaner, changes-lint.sh,
# changes-guard.sh, changes-patches.sh, a one-Legal-Review-Notice-per-License
# check, the spec header and the patch tags, each run unpiped with its exit
# code read directly, then one VERDICT line. Five separate calls cost five provider
# steps and five result blocks that ride along in context for the rest of the
# session; this costs one. The adversarial change review (agents/changes-review.md)
# still follows — it is a judgement, not a check, and stays outside this script.
#
# Usage: gate.sh [DIR] [--entries N] [--amend-top AUTHOR] [--squash-mine AUTHOR] [--target PRJ[/PKG]]
#                [--git-base REF] [--build-log FILE] [--cleaner-deviation REASON] [--full]
#        gate.sh [DIR] --review FILE
#   DIR          package checkout (default .)
#   --entries N  entries the submission adds vs the target (changes-lint and
#                changes-patches, default 1)
#   changes-lint also checks those entries' author against what a bare
#   `osc vc` writes (vc-identity.sh); with no identity from osc vc it is red.
#   --amend-top  the .changes top entry is yours and still unaccepted (changes-guard)
#   --squash-mine  the new top entry folds the run of your own unaccepted entries
#                under it into one, when the user asks for it (changes-guard)
#   --target     the SR target (default: Factory's devel project, devel-of.sh; for a
#                link into another openSUSE:/SUSE: project, that maintenance
#                project; for a package Factory lacks, the link origin, else the
#                checkout's own project). An osc checkout whose link origin (its
#                own project when it is no link) is not the target is red: its
#                .changes history is not the target's (sr#1392134). A forward to
#                openSUSE:Factory from Factory's devel project is fine.
#                changes-guard then compares against the target's .changes and
#                changes-patches against the target
#   --git-base   git checkout: the target's ref for changes-patches (a fork PR's
#                upstream is the pushed fork branch, which compares clean)
#   --build-log  also run build-summary.sh on this osc build log (verdict only)
#   --cleaner-deviation  the spec-cleaner diff left is a documented deviation
#                (references/spec-cleaner.md "Checking a spec file"): name it.
#                The gate passes, prints the reason and keeps the diff for the
#                change review, which judges every hunk of it
#   --full       print every gate's complete output (default: last 12 lines each;
#                full output is always saved under $TMPDIR/gate-<pkg>/)
#   --review FILE  record the change review instead of running the gates: FILE's
#                first non-empty line starts with PASS and names "tree <key12>",
#                the tree the last GREEN run printed; needs that GREEN run
# Stamp (osc checkouts): a GREEN run records the tree it judged, a sha256 over
# the md5 and name of every file osc would commit (no _link, no _service:*), in
# ~/.local/state/opensuse-packaging/gate/obs/<pkg>/<prj>.json; a red run deletes
# it. A rerun of the same tree keeps its review.
# Exit: 0 = every gate green (--review: recorded), 1 = at least one red (VERDICT
#       names them; --review: the verdict file is not a PASS of this tree),
#       2 = usage, or DIR is not a package checkout (no *.spec, no .osc/_package),
#       3 = --review: no GREEN gate run of the current tree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
read -r -d '' PY <<'PYEOF'
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def listing(d, prj, pkg):
    # .osc/_files, else the API's expanded listing (an osc store without one)
    path = os.path.join(d, ".osc/_files")
    if os.path.exists(path):
        try:
            return ET.parse(path).getroot()
        except (OSError, ET.ParseError):
            return None
    p = subprocess.run(["osc", "api", "/source/%s/%s?expand=1" % (prj, pkg)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    try:
        return ET.fromstring(p.stdout)
    except ET.ParseError:
        return None


def link(d, prj, pkg):
    root = listing(d, prj, pkg)
    if root is None:
        return 2
    li = root.find("linkinfo")
    if li is not None and li.get("project"):
        print("%s/%s" % (li.get("project"), li.get("package") or pkg))
    return 0


def files(d):
    # the files `osc ci` would commit, with the working copy's md5
    path = os.path.join(d, ".osc/_files")
    try:
        names = {e.get("name") for e in ET.parse(path).getroot().findall("entry")}
    except (OSError, ET.ParseError):
        return None
    for extra, add in (("_to_be_added", True), ("_to_be_deleted", False)):
        try:
            with open(os.path.join(d, ".osc", extra), encoding="utf-8") as fh:
                for n in fh.read().split():
                    (names.add if add else names.discard)(n)
        except OSError:
            pass
    out = {}
    for n in sorted(x for x in names if x and x != "_link" and not x.startswith("_service:")):
        h = hashlib.md5()
        try:
            with open(os.path.join(d, n), "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
            out[n] = h.hexdigest()
        except OSError:
            out[n] = "-"
    return out


def key(fm):
    return hashlib.sha256("".join("%s  %s\n" % (m, n) for n, m in sorted(fm.items())).encode()).hexdigest()


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def save(path, d):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(d, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def stamp(path, d, prj, pkg, target):
    fm = files(d)
    if fm is None:
        return 1
    st = {"project": prj, "package": pkg, "target": target, "tree": key(fm),
          "files": fm, "verdict": "GREEN", "time": now()}
    old = load(path)
    # A rerun of the same tree keeps the review of that tree.
    if old and old.get("tree") == st["tree"] and old.get("review"):
        st["review"] = old["review"]
    save(path, st)
    print(st["tree"])
    return 0


def review(path, d, fpath):
    fm = files(d)
    t = key(fm) if fm is not None else ""
    st = load(path)
    if not st or st.get("verdict") != "GREEN" or not t or st.get("tree") != t:
        print("VERDICT: NO GATE — no GREEN gate run of tree %s: run gate.sh, then --review" % (t[:12] or "?"))
        return 3
    try:
        with open(fpath, "rb") as fh:
            raw = fh.read()
    except OSError as e:
        print("VERDICT: REFUSED — cannot read %s: %s" % (fpath, e.strerror))
        return 2
    lines = [ln.strip() for ln in raw.decode("utf-8", "replace").splitlines() if ln.strip()]
    first = lines[0] if lines else ""
    # Only the verdict line binds: a body may quote the target's or an older tree.
    trees = re.findall(r"\btree ([0-9a-f]{12,})\b", first)
    bad = None
    if not re.match(r"PASS\b", first):
        bad = "review verdict is '%s', not PASS" % first[:40]
    elif not trees:
        bad = "the PASS line names no 'tree <key12>'"
    else:
        wrong = sorted({x for x in trees if not t.startswith(x)})
        if wrong:
            bad = "review names tree %s, the checkout is tree %s" % (wrong[0][:12], t[:12])
    if bad:
        if st.pop("review", None) is not None:
            save(path, st)
        print("VERDICT: RED — " + bad)
        return 1
    st["review"] = {"verdict": "PASS", "sha256": hashlib.sha256(raw).hexdigest(), "time": now()}
    save(path, st)
    print("VERDICT: GREEN — review PASS recorded for tree %s of %s/%s" % (t[:12], st.get("project"), st.get("package")))
    return 0


COPY = re.compile(r"^#\s*Copyright\b(.*)$", re.I)


def holders(path):
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return out
    for line in text.splitlines():
        m = COPY.match(line)
        if not m:
            continue
        h = re.sub(r"\((c|C)\)|©", " ", m.group(1))
        h = re.sub(r"^[\s,0-9-]+", "", h)
        h = re.sub(r"(,?\s+and\s+contributors)?[\s.]*$", "", h, flags=re.I)
        h = re.sub(r"\s+", " ", h).strip().lower()
        # spec-cleaner and format_spec_file rewrite the SUSE header themselves
        if h and not re.match(r"(suse|novell)\b", h):
            out.setdefault(h, line.strip())
    return out


def copyright(base, work):
    gone = [line for h, line in holders(base).items() if h not in holders(work)]
    for line in gone:
        print("gone: %s" % line)
    return 1 if gone else 0


TAG = re.compile(r"PATCH-(?:(?:FIX|FEATURE)-(?:UPSTREAM|OPENSUSE|SLE)|NEEDS-REBASE)\b")
PATCH = re.compile(r"Patch\d*\s*:\s*(\S+)", re.I)
MACRO = re.compile(r"%\{\??(\w+)\}|%(\w+)")
REF = re.compile(r"https?://\S+|\bgh#[\w.-]+/[\w.-]+#\d+|\b[a-z][a-z0-9]*#\d+")  # URL, gh#o/r#N, a bug id (bsc#, fdo#, …)
HEX = re.compile(r"\b[0-9a-f]{7,40}\b")


def cited(block, names):
    text = "\n".join(block)
    for n in names:  # a hash-like file name is no reference
        text = text.replace(n, " ")
    return bool(REF.search(text)) or any(re.search(r"\d", h) for h in HEX.findall(text))


def tags(spec):
    try:
        with open(spec, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        print("%s: cannot read it: %s" % (spec, e.strerror))
        return 1
    macros = {}
    for line in lines:
        m = re.match(r"(name|version)\s*:\s*(\S+)", line, re.I)
        if m:
            macros.setdefault(m.group(1).lower(), m.group(2))
        m = re.match(r"%(?:define|global)\s+(\w+)\s+(\S+)\s*$", line)
        if m:
            macros.setdefault(m.group(1), m.group(2))

    def expand(s):
        for _ in range(5):
            t = MACRO.sub(lambda m: macros.get(m.group(1) or m.group(2), m.group(0)), s)
            if t == s:
                break
            s = t
        return s

    def base(s):  # a URL Patch names its file after #/, else by its last path part
        return s.split("#/")[-1] if "#/" in s else s.rsplit("/", 1)[-1]

    bad = 0
    for i, line in enumerate(lines):
        m = PATCH.match(line)
        if not m:
            continue
        f = base(expand(m.group(1)))
        names = {base(m.group(1)), f}
        j = i - 1  # an %if around the Patch line sits between it and its comment
        while j >= 0 and re.match(r"%(if|else|elif|endif)\b", lines[j].strip()):
            j -= 1
        block = []
        while j >= 0 and lines[j].lstrip().startswith("#"):
            block.insert(0, lines[j])
            j -= 1
        tagged = [t for t in block if TAG.search(t)]
        named = [t for t in tagged if any(n in t for n in names)]
        why = None
        if not tagged:
            why = "%s has no PATCH-* tag in the comment above it" % f
        elif not named:
            why = "the PATCH-* tag above %s does not name it" % f
        elif "UPSTREAM" in TAG.search(named[0]).group(0) and not cited(block, names):
            why = "the PATCH-*-UPSTREAM tag of %s cites no reference (URL, gh#owner/repo#N, commit, bug id like bsc#N)" % f
        if why:
            print("%s:%d: %s" % (spec, i + 1, why))
            bad = 1
    return bad


cmd, args = sys.argv[1], sys.argv[2:]
fn = {"link": link, "stamp": stamp, "review": review, "copyright": copyright, "tags": tags}[cmd]
sys.exit(fn(*args))
PYEOF
py() { python3 -c "$PY" "$@"; }
dir=.; entries=1; amend=""; squash=""; target=""; gitbase=""; buildlog=""; deviation=""; full=0; review=""; nopts=0
while [ $# -gt 0 ]; do
  case "$1" in --entries|--amend-top|--squash-mine|--target|--git-base|--build-log|--cleaner-deviation|--review) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; };; esac
  case "$1" in --entries|--amend-top|--squash-mine|--target|--git-base|--build-log|--cleaner-deviation|--full) nopts=$((nopts+1)) ;; esac
  case "$1" in
    -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --entries) [[ $2 =~ ^[1-9][0-9]*$ ]] || { echo "gate.sh: --entries takes a positive integer, got '$2'" >&2; exit 2; }
               entries=$2; shift 2 ;;
    --amend-top) amend=$2; shift 2 ;;
    --squash-mine) squash=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --git-base) gitbase=$2; shift 2 ;;
    --build-log) buildlog=$2; shift 2 ;;
    --cleaner-deviation) [ -n "$2" ] || { echo "gate.sh: --cleaner-deviation needs the reason" >&2; exit 2; }
                         deviation=$2; shift 2 ;;
    --full) full=1; shift ;;
    --review) review=$(realpath -m -- "$2"); shift 2 ;;
    -*) echo "gate.sh: unknown option $1" >&2; exit 2 ;;
    *) dir=$1; shift ;;
  esac
done
[ -z "$review" ] || [ "$nopts" = 0 ] || { echo "gate.sh: --review records a verdict and runs no gate: it takes DIR only" >&2; exit 2; }
cd "$dir" || exit 2
# Anywhere else source_validator reports rc=0 over nothing: a green piece of a
# verdict about no package.
specs=( *.spec )
if [ ! -e "${specs[0]}" ] && [ ! -r .osc/_package ]; then
  if [ -r .osc/_project ]; then echo "gate.sh: $(pwd): osc project checkout — cd into the package directory" >&2
  else echo "gate.sh: $(pwd): no *.spec and no .osc/_package — not a package checkout" >&2; fi
  exit 2
fi
pkg=$(basename "$(pwd -P)"); [ -r .osc/_package ] && pkg=$(tr -d '\n' < .osc/_package)
# A classic osc checkout (not a git/scmsync one): its own project, and the stamp.
own=""; [ -r .osc/_project ] && [ -r .osc/_package ] && [ ! -e .osc/_scm ] && own=$(tr -d '\n' < .osc/_project)
stampf=""; [ -n "$own" ] && [[ $own != */* && $pkg != */* && $pkg != .* ]] \
  && stampf="$HOME/.local/state/opensuse-packaging/gate/obs/$pkg/$own.json"
if [ -n "$review" ]; then
  [ -n "$stampf" ] || { echo "gate.sh: --review needs an osc package checkout (.osc/_project and .osc/_package)" >&2; exit 2; }
  py review "$stampf" . "$review"; exit $?
fi
log="${TMPDIR:-/tmp}/gate-$pkg"; rm -rf "$log"; mkdir -p "$log"
red=()
show() {   # $1 name, $2 rc, $3 output file
  printf '## %s: rc=%s\n' "$1" "$2"
  if [ $full -eq 1 ]; then cat "$3"; else tail -n 12 "$3"; fi
  [ "$2" -eq 0 ] || red+=("$1")
}

# The SR target, and whether this checkout's history is the target's. A branch
# of a stale copy in another project, submitted to Factory's devel project,
# deletes the devel entries the copy never had (sr#1392134: hardware's 0.9.5
# copy filed to devel:languages:python at 0.9.8). Only for osc checkouts; a git
# checkout names its target with --git-base.
tgt=""; tprj=""; tpkg=""
if [ -n "$own" ]; then
  : > "$log/target.txt"; rc=0
  origin=$(py link . "$own" "$pkg" 2> "$log/link.err"); lrc=$?
  if [ $lrc -ne 0 ]; then
    echo "UNKNOWN: cannot read the checkout's link: osc api /source/$own/$pkg failed" >> "$log/target.txt"; rc=1
  fi
  oprj=${origin%%/*}; base=${oprj:-$own}; bpkg=$pkg; [ -z "$origin" ] || bpkg=${origin#*/}
  devel=""; drc=-1
  devel_of() { devel=$(timeout 60 "$HERE/devel-of.sh" "$pkg" 2>> "$log/target.txt"); drc=$?; }
  tgt=$target
  if [ -z "$tgt" ]; then
    if [ -n "$oprj" ] && [[ $oprj =~ ^(openSUSE|SUSE): ]] && [ "$oprj" != openSUSE:Factory ]; then
      tgt=$origin                    # maintenance work: the branched update project
    else
      devel_of
      case $drc in
        0) tgt=$devel ;;
        3|4) tgt=${origin:-$own/$pkg}; echo "note: $pkg has no devel project in openSUSE:Factory: target $tgt" >> "$log/target.txt" ;;
        *) echo "UNKNOWN: Factory's devel project for $pkg could not be read (devel-of.sh exit $drc): pass --target" >> "$log/target.txt"; rc=1 ;;
      esac
    fi
  fi
  if [ -n "$tgt" ]; then
    tprj=${tgt%%/*}; tpkg=$pkg; [[ $tgt == */* ]] && tpkg=${tgt#*/}
    if [ "$tprj" = "$own" ]; then
      echo "OK: a direct commit to $own, the target" >> "$log/target.txt"
    elif [ "$tprj" = "$base" ]; then
      echo "OK: the checkout is based on $base, the target is $tprj/$tpkg" >> "$log/target.txt"
    elif [ "$tprj" = openSUSE:Factory ]; then
      [ $drc -ge 0 ] || devel_of
      case $drc in
        0) if [ "${devel%%/*}" = "$base" ]; then
             echo "OK: a forward from Factory's devel project $base to $tprj/$tpkg" >> "$log/target.txt"
           else
             echo "RED: openSUSE:Factory takes $pkg from its devel project ${devel%%/*}; this checkout is based on $base" >> "$log/target.txt"; rc=1
           fi ;;
        3|4) echo "note: $pkg has no devel project in openSUSE:Factory; the checkout is based on $base" >> "$log/target.txt" ;;
        *) echo "UNKNOWN: Factory's devel project for $pkg could not be read (devel-of.sh exit $drc)" >> "$log/target.txt"; rc=1 ;;
      esac
    elif timeout 60 osc api "/source/$tprj/$tpkg/_meta" > /dev/null 2> "$log/target-meta.err"; then
      echo "RED: the checkout is based on $base/$bpkg, the SR goes to $tprj/$tpkg: its .changes history is not the target's — branch the target (osc branch $tprj $tpkg), or pass --target $base if $base really is where this goes" >> "$log/target.txt"; rc=1
    elif grep -q 'HTTP Error 404' "$log/target-meta.err"; then
      # a misspelt project would pass as a new package against the committed copy
      if timeout 60 osc api "/source/$tprj/_meta" > /dev/null 2> "$log/target-meta.err"; then
        echo "note: $tprj/$tpkg does not exist: a new package there" >> "$log/target.txt"
      elif grep -q 'HTTP Error 404' "$log/target-meta.err"; then
        echo "RED: the target project $tprj does not exist — check --target" >> "$log/target.txt"; rc=1
      else
        echo "UNKNOWN: cannot read $tprj/_meta: $(head -n 1 "$log/target-meta.err")" >> "$log/target.txt"; rc=1
      fi
    else
      echo "UNKNOWN: cannot read $tprj/$tpkg/_meta: $(head -n 1 "$log/target-meta.err")" >> "$log/target.txt"; rc=1
    fi
  fi
  show target $rc "$log/target.txt"
fi

if command -v /usr/lib/obs/service/source_validator >/dev/null 2>&1 || [ -x /usr/lib/obs/service/source_validator ]; then
  /usr/lib/obs/service/source_validator --outdir "$log/sv" > "$log/source_validator.txt" 2>&1; rc=$?
  # factory-auto (check_source.py) declines on these although the validator exits 0
  na=$(grep -E 'Attention.*not mentioned' "$log/source_validator.txt")
  [ -z "$na" ] || printf '%s\n' "${na//(W) /ERROR: factory-auto declines this: }" >> "$log/source_validator.txt"
  show source_validator $rc "$log/source_validator.txt"
  [ -z "$na" ] || [ $rc -ne 0 ] || red+=(source_validator)
else
  echo "## source_validator: SKIPPED (not installed)"; red+=(source_validator)
fi

# factory-auto's check_urls: every remote Source downloads and equals the
# committed file. The downloads go under /var/tmp, not the /tmp tmpfs.
if [ -x /usr/lib/obs/service/download_files ]; then
  if dl=$(mktemp -d -p /var/tmp "gate-dl-$pkg.XXXXXX"); then
    /usr/lib/obs/service/download_files --enforceupstream yes --enforcelocal yes --outdir "$dl" \
      > "$log/download_files.txt" 2>&1; rc=$?
    rm -rf "$dl"
  else
    echo "UNKNOWN: no scratch directory under /var/tmp" > "$log/download_files.txt"; rc=1
  fi
  [ $rc -eq 0 ] && echo "OK: every remote source downloads and matches the committed file" >> "$log/download_files.txt"
  show download_files $rc "$log/download_files.txt"
else
  echo "## download_files: SKIPPED (not installed)"; red+=(download_files)
fi

# spec-cleaner as the skill runs it (core directive 3), in every build mode: the
# four policy flags and a fresh -o per spec. A diff is red unless it is named as
# a documented deviation; a run that fails is red, never "no diff". The version is
# printed because the references describe 1.3.0 and older ones rewrite differently.
if command -v spec-cleaner >/dev/null 2>&1; then
  : > "$log/spec-cleaner.diff"; rc=0; changed=0
  scv=$(spec-cleaner --version 2>/dev/null | head -n 1); scv=${scv:-unknown}
  echo "spec-cleaner $scv" > "$log/spec-cleaner.txt"
  [ "$scv" = 1.3.0 ] || echo "NOTE: spec-cleaner $scv is not the documented 1.3.0: a hunk only it makes may be a version difference (references/spec-cleaner.md \"Checking a spec file\")" >> "$log/spec-cleaner.txt"
  for s in "${specs[@]}"; do
    [ -e "$s" ] || continue
    if ! spec-cleaner --remove-groups --pkgconfig --perl --tex -o "$log/cleaned.$s" "$s" > "$log/spec-cleaner.err" 2>&1; then
      echo "UNKNOWN: spec-cleaner failed on $s: $(tail -n 1 "$log/spec-cleaner.err")" >> "$log/spec-cleaner.txt"; rc=1; continue
    fi
    diff -u "$s" "$log/cleaned.$s" >> "$log/spec-cleaner.diff"; d=$?
    if [ $d -eq 1 ]; then changed=$((changed+1)); elif [ $d -gt 1 ]; then
      echo "UNKNOWN: could not diff $s against its cleaned copy" >> "$log/spec-cleaner.txt"; rc=1; fi
  done
  lines=$(grep -c '^[-+][^-+]' "$log/spec-cleaner.diff")
  if [ $rc -eq 0 ] && [ $changed -eq 0 ]; then
    echo "OK: spec-cleaner leaves every spec as it is" >> "$log/spec-cleaner.txt"
  elif [ $rc -eq 0 ] && [ -n "$deviation" ]; then
    echo "DEVIATION: $lines changed line(s) kept on purpose — $deviation — the change review judges $log/spec-cleaner.diff" >> "$log/spec-cleaner.txt"
  elif [ $rc -eq 0 ]; then
    { echo "spec-cleaner would change $lines line(s) in $changed spec(s): apply it (spec-cleaner --remove-groups --pkgconfig --perl --tex -i <spec>), or name the documented deviation with --cleaner-deviation REASON"
      grep '^[-+][^-+]' "$log/spec-cleaner.diff" | head -n 8; } >> "$log/spec-cleaner.txt"; rc=1
  fi
  show spec-cleaner $rc "$log/spec-cleaner.txt"
else
  echo "## spec-cleaner: SKIPPED (not installed)"; red+=(spec-cleaner)
fi

changes=( *.changes )
if [ -e "${changes[0]}" ]; then
  lint=(--entries "$entries")
  if me=$("$HERE/vc-identity.sh" 2> "$log/vc-identity.txt"); then lint+=(--author "$me"); else me=""; fi
  "$HERE/changes-lint.sh" "${lint[@]}" "${changes[@]}" > "$log/changes-lint.txt" 2>&1; rc=$?
  if [ -z "$me" ]; then
    { cat "$log/vc-identity.txt"; echo "author not checked: no identity from osc vc to compare against"; } \
      >> "$log/changes-lint.txt"
    [ $rc != 0 ] || rc=1
  fi
  show changes-lint $rc "$log/changes-lint.txt"
  guard=(); [ -n "$amend" ] && guard+=(--amend-top "$amend"); [ -n "$squash" ] && guard+=(--squash-mine "$squash")
  if [ -n "$tprj" ] && [ "$tprj" != "$own" ]; then
    # Against the target's copy, not the checkout's own committed one: a branch
    # commits its base, so its own copy is no evidence of what the target has.
    mkdir -p "$log/target-base"; : > "$log/changes-guard.txt"; rc=0
    for ch in "${changes[@]}"; do
      if timeout 60 osc cat "$tprj" "$tpkg" "$ch" > "$log/target-base/$ch" 2> "$log/target-base/$ch.err"; then
        echo "### $ch vs $tprj/$tpkg" >> "$log/changes-guard.txt"
        "$HERE/changes-guard.sh" "${guard[@]}" --base "$log/target-base/$ch" "$ch" >> "$log/changes-guard.txt" 2>&1 || rc=1
      elif grep -q 'HTTP Error 404' "$log/target-base/$ch.err"; then
        echo "### $ch: not in $tprj/$tpkg, vs the committed copy" >> "$log/changes-guard.txt"
        "$HERE/changes-guard.sh" "${guard[@]}" "$ch" >> "$log/changes-guard.txt" 2>&1 || rc=1
      else
        echo "UNKNOWN: osc cat $tprj $tpkg $ch failed: $(head -n 1 "$log/target-base/$ch.err")" >> "$log/changes-guard.txt"; rc=1
      fi
    done
  else
    "$HERE/changes-guard.sh" "${guard[@]}" "${changes[@]}" > "$log/changes-guard.txt" 2>&1; rc=$?
  fi
  show changes-guard $rc "$log/changes-guard.txt"
else
  echo "## changes-lint / changes-guard: no *.changes in $(pwd)"; red+=(changes)
fi

cp_args=(. --entries "$entries")
# The resolved target, except a direct commit to the checkout's own project:
# its entries count against the committed copy.
if [ -n "$tprj" ]; then [ "$tprj" = "$own" ] || cp_args+=(--target "$tprj/$tpkg")
elif [ -n "$target" ]; then cp_args+=(--target "$target"); fi
[ -n "$gitbase" ] && cp_args+=(--git-base "$gitbase")
"$HERE/changes-patches.sh" "${cp_args[@]}" > "$log/changes-patches.txt" 2>&1; rc=$?
show changes-patches $rc "$log/changes-patches.txt"

if [ -n "$buildlog" ]; then
  "$HERE/build-summary.sh" "$buildlog" > "$log/build-summary.txt" 2>&1; rc=$?
  { grep -m1 'VERDICT' "$log/build-summary.txt"; grep -A1 '^### rpmlint' "$log/build-summary.txt" | tail -1; } > "$log/build-summary.short.txt"
  show build-summary $rc "$log/build-summary.short.txt"
fi

# One itemised # Legal-Review-Notice: per License: tag; several read as
# separate claims to the legal reviewer.
: > "$log/spec-notices.txt"; rc=0
for s in "${specs[@]}"; do
  [ -e "$s" ] || continue
  n=$(grep -c '^#[[:space:]]*Legal-Review-Notice:' "$s"); l=$(grep -ci '^License:' "$s")
  if [ "$n" -gt 1 ] && [ "$n" -gt "$l" ]; then
    echo "$s: $n Legal-Review-Notice blocks for $l License: tag(s) — merge them into one itemised block above the tag" >> "$log/spec-notices.txt"; rc=1
  fi
done
[ $rc -eq 0 ] && echo "OK: at most one Legal-Review-Notice per License: tag" >> "$log/spec-notices.txt"
show spec-notices $rc "$log/spec-notices.txt"

# One "# spec file for package" header per spec (rpmcrab shipped two), and
# every copyright holder the target's spec names besides SUSE survives: a
# format_spec_file or spec-cleaner run replaced a maintainer's own line (bluetui).
: > "$log/spec-header.txt"; rc=0
for s in "${specs[@]}"; do
  [ -e "$s" ] || continue
  n=$(grep -c '^# spec file for package' "$s")
  [ "$n" -le 1 ] || { echo "$s: $n '# spec file for package' headers — keep one" >> "$log/spec-header.txt"; rc=1; }
  b="$log/base.$s"; rm -f "$b"; from=""
  if [ -n "$tprj" ] && [ "$tprj" != "$own" ]; then
    if timeout 60 osc cat "$tprj" "$tpkg" "$s" > "$b" 2> "$b.err"; then from="$tprj/$tpkg"
    elif grep -q 'HTTP Error 404' "$b.err"; then rm -f "$b"
    else echo "UNKNOWN: osc cat $tprj $tpkg $s failed: $(head -n 1 "$b.err")" >> "$log/spec-header.txt"; rc=1; rm -f "$b"; fi
  elif [ -r ".osc/sources/$s" ]; then cp ".osc/sources/$s" "$b"; from="the committed copy"
  elif [ -r ".osc/$s" ]; then cp ".osc/$s" "$b"; from="the committed copy"
  elif ref=${gitbase:-$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)} && [ -n "$ref" ] \
       && git show "$ref:./$s" > "$b" 2>/dev/null; then from=$ref
  else rm -f "$b"; fi
  if [ -n "$from" ]; then
    if ! py copyright "$b" "$s" > "$log/copyright.txt"; then
      sed "s|^gone: |$s: a copyright line of $from is gone: |" "$log/copyright.txt" >> "$log/spec-header.txt"; rc=1
    fi
  else
    echo "note: $s: no target or committed copy to compare the copyright lines with" >> "$log/spec-header.txt"
  fi
done
[ $rc -eq 0 ] && echo "OK: one spec header, and every copyright holder of the target kept" >> "$log/spec-header.txt"
show spec-header $rc "$log/spec-header.txt"

# Every Patch line carries a PATCH-* tag naming its file, and an UPSTREAM tag
# says where upstream has it (references/patches.md): a devel reviewer asked
# for them on sr#1385879, which no gate had checked.
: > "$log/patch-tags.txt"; rc=0
for s in "${specs[@]}"; do
  [ -e "$s" ] || continue
  py tags "$s" >> "$log/patch-tags.txt" || rc=1
done
[ $rc -eq 0 ] && echo "OK: every patch tagged by name, every UPSTREAM tag with its reference" >> "$log/patch-tags.txt"
show patch-tags $rc "$log/patch-tags.txt"

if [ ${#red[@]} -eq 0 ]; then
  t=""
  if [ -n "$stampf" ]; then
    if t=$(py stamp "$stampf" . "$own" "$pkg" "${tprj:+$tprj/$tpkg}"); then t=" for tree ${t:0:12}"
    else t=" (no tree stamped: no .osc/_files)"; fi
  fi
  if [ -n "$deviation" ] && grep -q '^DEVIATION' "$log/spec-cleaner.txt" 2>/dev/null; then
    echo "VERDICT: GREEN — all gates passed$t, spec-cleaner deviation: $deviation (diff: $log/spec-cleaner.diff; full output: $log/)"; exit 0
  fi
  echo "VERDICT: GREEN — all gates passed$t (full output: $log/)"; exit 0
fi
[ -z "$stampf" ] || rm -f "$stampf"
echo "VERDICT: RED — ${red[*]} (full output: $log/)"; exit 1
