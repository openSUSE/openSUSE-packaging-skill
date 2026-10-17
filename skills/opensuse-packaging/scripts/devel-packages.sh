#!/bin/bash
# List the Factory packages a devel project develops, as Factory's own _meta
# records them: one "<package> <devel-project>" line each, sorted.
#
# The list for a devel-project update sweep, and the SR target beside each name.
# Never sweep `osc ls PRJ` intersected with Factory instead: that also lists
# PRJ's _aggregate and _link packages and every package PRJ carries whose Factory
# devel project is another one (Application:Geo: 170 such names against 51 it
# develops), and an SR filed to PRJ for one of those goes to the wrong project.
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
  if ! xml="$(osc api "/search/package/id?match=@project='openSUSE:Factory'+and+devel/@project='$prj'" 2>&1)"; then
    echo "ERROR: search for $prj failed: ${xml##*$'\n'}" >&2
    exit 5
  fi
  if ! names="$(python3 -c '
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
if root.tag != "collection":
    sys.exit(1)
for p in root.findall("package"):
    print(p.get("name"))
' <<<"$xml")"; then
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
