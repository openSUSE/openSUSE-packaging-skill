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
Exit: 0 everything applied; 1 at least one patch commented out or fuzzy; 2 setup error.
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
refreshed=(); fuzzy=(); failed=()

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
    # comment out the PatchN: line for this file
    sed -i -E "s|^(Patch[0-9]+:[[:space:]]+${name//./\\.})[[:space:]]*\$|#\1|" "$spec"
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
[ ${#failed[@]} -eq 0 ] && [ ${#fuzzy[@]} -eq 0 ]
