#!/bin/bash
# quilt-test-series.sh — push a spec's patches one by one, refresh offset-only applies,
# comment out patches that reject, restart, report.
usage() {
cat <<'U'
Usage: quilt-test-series.sh [--after PATCH] [--keep] <package>.spec

Run from the package checkout. For each patch in the series (only those after PATCH if
--after is given; earlier ones are pushed untouched):
  clean apply                 -> next patch
  "offset N lines" only       -> quilt refresh with a/ b/ prefixes, no timestamps, no Index line -> next
  fuzz                        -> NOT refreshed, listed as FUZZ for a human look
  any FAILED / does not apply -> comment out its PatchN: line, delete the build dir,
                                 re-run setup, push the already-good patches again, continue
Never edits patch content by hand. Deletes the build dir and any *.patch~ it created at the
end unless --keep. Final report: REFRESHED / FUZZ / COMMENTED OUT (with failing hunks).
Uses quilt-prep.sh from its own directory. Refuses to start if a build dir already exists (it may hold unrefreshed edits).
A patch is found in the spec by its file name, with %{name} and %{version} expanded; with
it goes the %patch line that applies its number. A rejecting patch whose line it cannot
find, or one a %patch line applies without a number, stops the run: STUCK names it.
Exit: 0 everything applied; 1 at least one patch commented out or fuzzy; 2 setup error or stuck.
U
}
after=""; keep=0
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0;;
    --keep) keep=1;;
    --after) after=$2; shift;;
    -*) usage >&2; exit 2;;
    *) spec=$1;;
  esac; shift
done
[ -n "${spec:-}" ] && [ -f "$spec" ] || { usage >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
root=$PWD
before=$(ls -- *.patch~ 2>/dev/null | sort)
refreshed=(); fuzzy=(); failed=(); stuck=""
pname=$(rpmspec -q --srpm --qf '%{name}' "$spec" 2>/dev/null) || pname=""
pver=$(rpmspec -q --srpm --qf '%{version}' "$spec" 2>/dev/null) || pver=""

# comment_out <patch file>: comments out the spec's Patch line naming it and, where the spec
# applies patches one by one, the %patch line with that number. 1 when it cannot, and then
# the spec is as it was.
comment_out() {
  local n=0 line val num at=""
  while IFS= read -r line; do
    n=$((n+1))
    [[ $line =~ ^Patch([0-9]*):[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]] || continue
    num=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    case $val in *%*) val=$(rpm --define "name $pname" --define "version $pver" --eval "$val" 2>/dev/null) ;; esac
    [ "${val##*/}" = "$1" ] && { at=$n; break; }
  done < "$spec"
  [ -n "$at" ] || return 1
  if ! grep -qE '^%auto(setup|patch)' "$spec"; then
    [ -n "$num" ] || return 1
    grep -qE "^%patch($num|[[:space:]]+(.*[[:space:]])?-P[[:space:]]*$num|[[:space:]]+$num)([[:space:]]|\$)" "$spec" || return 1
    sed -i -E "s/^%patch($num|[[:space:]]+(.*[[:space:]])?-P[[:space:]]*$num|[[:space:]]+$num)([[:space:]]|\$)/#&/" "$spec"
  fi
  sed -i "${at}s/^/#/" "$spec"
}

setup() { bash "$HERE/quilt-prep.sh" "$@" "$spec" | sed -n 's/^BUILDDIR=//p'; }
# first run without --force: an existing build dir may hold unrefreshed edits
bd=$(setup)
[ -n "$bd" ] || { echo "setup failed" >&2; exit 2; }
cd "$bd" || exit 2
[ -n "$after" ] && { after=${after%.patch}.patch; quilt push "patches/$after" >/dev/null 2>&1 || { echo "cannot push to $after" >&2; exit 2; }; }
good=$(quilt applied 2>/dev/null | sed 's#^patches/##')

while true; do
  next=$(quilt next 2>/dev/null) || break
  [ -n "$next" ] || break
  name=${next#patches/}
  out=$(quilt push 2>&1); rc=$?
  if [ $rc -ne 0 ] || grep -q "FAILED" <<<"$out"; then
    hunks=$(grep -E "FAILED|rejects in|can't find|does not apply" <<<"$out" | paste -sd';')
    failed+=("$name :: $hunks")
    cd "$root" || exit 2
    # Without its line gone the same patch would reject again, for ever.
    comment_out "$name" || { stuck=$name; unset 'failed[-1]'; break; }
    # It was the last one: quilt sets up no series for a spec without patches.
    grep -qE '^Patch[0-9]*:' "$spec" || break
    bd=$(setup --force); [ -n "$bd" ] || exit 2; cd "$bd" || exit 2
    for g in $good; do quilt push "patches/$g" >/dev/null 2>&1 || { echo "re-push of $g failed" >&2; exit 2; }; done
    continue
  fi
  if grep -qE "fuzz" <<<"$out"; then
    fuzzy+=("$name"); good="$good $name"; continue
  fi
  if grep -qE "offset [-0-9]+ line" <<<"$out"; then
    quilt refresh -p ab --no-timestamps --no-index >/dev/null 2>&1 && refreshed+=("$name")
  fi
  good="$good $name"
done

cd "$root" || exit 2
if [ $keep -eq 0 ]; then
  rm -rf "$(dirname "$bd")"
  for f in $(ls -- *.patch~ 2>/dev/null | sort | comm -13 <(echo "$before") -); do rm -f -- "$f"; done
fi
echo "== REFRESHED (offset only): ${#refreshed[@]}"; printf '   %s\n' "${refreshed[@]}"
echo "== FUZZ (not refreshed): ${#fuzzy[@]}"; printf '   %s\n' "${fuzzy[@]}"
echo "== COMMENTED OUT: ${#failed[@]}"; printf '   %s\n' "${failed[@]}"
if [ -n "$stuck" ]; then
  echo "== STUCK: $stuck rejects and its Patch line (or the %patch line applying it) was not found in $spec: comment it out by hand and run again" >&2
  exit 2
fi
[ ${#failed[@]} -eq 0 ] && [ ${#fuzzy[@]} -eq 0 ]
