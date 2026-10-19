#!/bin/bash
# The commit/SR gate chain as ONE tool call: source_validator, spec-cleaner, changes-lint.sh,
# changes-guard.sh, changes-patches.sh and a one-Legal-Review-Notice-per-License
# check, each run unpiped with its exit code read directly, then one VERDICT line. Five separate calls cost five provider
# steps and five result blocks that ride along in context for the rest of the
# session; this costs one. The adversarial change review (agents/changes-review.md)
# still follows — it is a judgement, not a check, and stays outside this script.
#
# Usage: gate.sh [DIR] [--entries N] [--amend-top AUTHOR] [--target PRJ[/PKG]]
#                [--git-base REF] [--build-log FILE] [--cleaner-deviation REASON] [--full]
#   DIR          package checkout (default .)
#   --entries N  entries the submission adds vs the target (changes-lint and
#                changes-patches, default 1)
#   changes-lint also checks those entries' author against what a bare
#   `osc vc` writes (vc-identity.sh); with no identity from osc vc it is red.
#   --amend-top  the .changes top entry is yours and still unaccepted (changes-guard)
#   --target     SR target for changes-patches (default: link origin, else Factory)
#   --git-base   git checkout: the target's ref for changes-patches (a fork PR's
#                upstream is the pushed fork branch, which compares clean)
#   --build-log  also run build-summary.sh on this osc build log (verdict only)
#   --cleaner-deviation  the spec-cleaner diff left is a documented deviation
#                (references/spec-cleaner.md "Checking a spec file"): name it.
#                The gate passes, prints the reason and keeps the diff for the
#                change review, which judges every hunk of it
#   --full       print every gate's complete output (default: last 12 lines each;
#                full output is always saved under $TMPDIR/gate-<pkg>/)
# Exit: 0 = every gate green, 1 = at least one red (VERDICT names them), 2 = usage,
#       or DIR is not a package checkout (no *.spec, no .osc/_package).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
dir=.; entries=1; amend=""; target=""; gitbase=""; buildlog=""; deviation=""; full=0
while [ $# -gt 0 ]; do
  case "$1" in --entries|--amend-top|--target|--git-base|--build-log|--cleaner-deviation) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; };; esac
  case "$1" in
    -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --entries) [[ $2 =~ ^[1-9][0-9]*$ ]] || { echo "gate.sh: --entries takes a positive integer, got '$2'" >&2; exit 2; }
               entries=$2; shift 2 ;;
    --amend-top) amend=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --git-base) gitbase=$2; shift 2 ;;
    --build-log) buildlog=$2; shift 2 ;;
    --cleaner-deviation) [ -n "$2" ] || { echo "gate.sh: --cleaner-deviation needs the reason" >&2; exit 2; }
                         deviation=$2; shift 2 ;;
    --full) full=1; shift ;;
    -*) echo "gate.sh: unknown option $1" >&2; exit 2 ;;
    *) dir=$1; shift ;;
  esac
done
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
log="${TMPDIR:-/tmp}/gate-$pkg"; rm -rf "$log"; mkdir -p "$log"
red=()
show() {   # $1 name, $2 rc, $3 output file
  printf '## %s: rc=%s\n' "$1" "$2"
  if [ $full -eq 1 ]; then cat "$3"; else tail -n 12 "$3"; fi
  [ "$2" -eq 0 ] || red+=("$1")
}

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

# spec-cleaner as the skill runs it (core directive 3), in every build mode: the
# four policy flags and a fresh -o per spec. A diff is red unless it is named as
# a documented deviation; a run that fails is red, never "no diff".
if command -v spec-cleaner >/dev/null 2>&1; then
  : > "$log/spec-cleaner.diff"; : > "$log/spec-cleaner.txt"; rc=0; changed=0
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
  if [ -n "$amend" ]; then "$HERE/changes-guard.sh" --amend-top "$amend" "${changes[@]}" > "$log/changes-guard.txt" 2>&1; rc=$?
  else "$HERE/changes-guard.sh" "${changes[@]}" > "$log/changes-guard.txt" 2>&1; rc=$?; fi
  show changes-guard $rc "$log/changes-guard.txt"
else
  echo "## changes-lint / changes-guard: no *.changes in $(pwd)"; red+=(changes)
fi

cp_args=(. --entries "$entries"); [ -n "$target" ] && cp_args+=(--target "$target")
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

if [ ${#red[@]} -eq 0 ]; then
  if [ -n "$deviation" ] && grep -q '^DEVIATION' "$log/spec-cleaner.txt" 2>/dev/null; then
    echo "VERDICT: GREEN — all gates passed, spec-cleaner deviation: $deviation (diff: $log/spec-cleaner.diff; full output: $log/)"; exit 0
  fi
  echo "VERDICT: GREEN — all gates passed (full output: $log/)"; exit 0
fi
echo "VERDICT: RED — ${red[*]} (full output: $log/)"; exit 1
