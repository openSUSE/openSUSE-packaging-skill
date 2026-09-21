#!/bin/bash
# The commit/SR gate chain as ONE tool call: source_validator, changes-lint.sh,
# changes-guard.sh and changes-patches.sh, each run unpiped with its exit code
# read directly, then one VERDICT line. Four separate calls cost four provider
# steps and four result blocks that ride along in context for the rest of the
# session; this costs one. The adversarial change review (agents/changes-review.md)
# still follows — it is a judgement, not a check, and stays outside this script.
#
# Usage: gate.sh [DIR] [--entries N] [--amend-top AUTHOR] [--target PRJ[/PKG]]
#                [--build-log FILE] [--full]
#   DIR          package checkout (default .)
#   --entries N  entries the submission adds vs the target (changes-lint, default 1)
#   --amend-top  the .changes top entry is yours and still unaccepted (changes-guard)
#   --target     SR target for changes-patches (default: link origin, else Factory)
#   --build-log  also run build-summary.sh on this osc build log (verdict only)
#   --full       print every gate's complete output (default: last 12 lines each;
#                full output is always saved under $TMPDIR/gate-<pkg>/)
# Exit: 0 = every gate green, 1 = at least one red (VERDICT names them), 2 = usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
dir=.; entries=1; amend=""; target=""; buildlog=""; full=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --entries) entries=$2; shift 2 ;;
    --amend-top) amend=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --build-log) buildlog=$2; shift 2 ;;
    --full) full=1; shift ;;
    -*) echo "gate.sh: unknown option $1" >&2; exit 2 ;;
    *) dir=$1; shift ;;
  esac
done
cd "$dir" || exit 2
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
  show source_validator $rc "$log/source_validator.txt"
else
  echo "## source_validator: SKIPPED (not installed)"; red+=(source_validator)
fi

changes=( *.changes )
if [ -e "${changes[0]}" ]; then
  "$HERE/changes-lint.sh" --entries "$entries" "${changes[@]}" > "$log/changes-lint.txt" 2>&1; rc=$?
  show changes-lint $rc "$log/changes-lint.txt"
  if [ -n "$amend" ]; then "$HERE/changes-guard.sh" --amend-top "$amend" "${changes[@]}" > "$log/changes-guard.txt" 2>&1; rc=$?
  else "$HERE/changes-guard.sh" "${changes[@]}" > "$log/changes-guard.txt" 2>&1; rc=$?; fi
  show changes-guard $rc "$log/changes-guard.txt"
else
  echo "## changes-lint / changes-guard: no *.changes in $(pwd)"; red+=(changes)
fi

if [ -n "$target" ]; then "$HERE/changes-patches.sh" . --target "$target" > "$log/changes-patches.txt" 2>&1; rc=$?
else "$HERE/changes-patches.sh" . > "$log/changes-patches.txt" 2>&1; rc=$?; fi
show changes-patches $rc "$log/changes-patches.txt"

if [ -n "$buildlog" ]; then
  "$HERE/build-summary.sh" "$buildlog" > "$log/build-summary.txt" 2>&1; rc=$?
  { grep -m1 'VERDICT' "$log/build-summary.txt"; grep -A1 '^### rpmlint' "$log/build-summary.txt" | tail -1; } > "$log/build-summary.short.txt"
  show build-summary $rc "$log/build-summary.short.txt"
fi

if [ ${#red[@]} -eq 0 ]; then
  echo "VERDICT: GREEN — all gates passed (full output: $log/)"; exit 0
fi
echo "VERDICT: RED — ${red[*]} (full output: $log/)"; exit 1
