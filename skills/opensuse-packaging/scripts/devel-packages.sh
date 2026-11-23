#!/bin/bash
# List the Factory packages a devel project develops, as Factory's own _meta
# records them: one "<package> <devel-project>" line each, sorted.
#
# The list for a devel-project update sweep, and the SR target beside each name.
# Never sweep `geectl remote list-packages PRJ` intersected with Factory
# instead: that also lists PRJ's _aggregate and _link packages and every
# package PRJ carries whose Factory devel project is another one
# (Application:Geo: 170 such names against 51 it develops), and an SR filed
# to PRJ for one of those goes to the wrong project.
#
#   exit 0  listed
#   exit 3  Factory names no package with that devel project
#   exit 5  the search failed or did not parse — never read as "none"
#   exit 2  usage error
#
# Usage: devel-packages.sh <devel-project> [<devel-project> ...]
#   Names only (the list outdated.py reads):  devel-packages.sh PRJ | cut -d" " -f1
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 0;;
  ''|-*) awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 2;;
esac
found=0
for prj in "$@"; do
  case "$prj" in
    *"'"*|*" "*|'') echo "ERROR: not a project name: $prj" >&2; exit 2;;
  esac
  if ! resp="$(geectl remote search-packages --devel-project "$prj" 2>&1)"; then
    echo "ERROR: search for $prj failed: ${resp##*$'\n'}" >&2
    exit 5
  fi
  if ! names="$(python3 -I -c '
import sys, json
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError as e:
    sys.stderr.write(f"ERROR: unparseable search response: {e}\n"); sys.exit(2)
# The search attributes packages to their devel project across projects;
# keep only the Factory ones, as the old project-scoped search did.
for p in payload.get("packages", []):
    if p.get("project") == "openSUSE:Factory" and p.get("name"):
        print(p["name"])
' <<<"$resp")"; then
    echo "ERROR: the search answer for $prj did not parse" >&2
    exit 5
  fi
  while read -r n; do
    [ -n "$n" ] || continue
    printf '%s %s\n' "$n" "$prj"
    found=1
  done < <(sort -u <<<"$names")
done
[ "$found" = 1 ] || { echo "NONE: Factory names no package developed in $*" >&2; exit 3; }
exit 0
