#!/bin/bash
# Print the devel project registered for a package in a target project.
# This is the lightweight pre-SR existence check (don't `geectl remote
# list-packages | grep`).
#
# Distinguishes "package absent" from "package present but no devel project set"
# (a missing package and a package with no devel project both read as no
# devel project, so a package-meta probe decides which):
#   exit 0  present, prints "<devel-project>/<pkg>"
#   exit 3  NOT in <target> (404 on the meta), under any spelling — new package
#   exit 6  NOT in <target> by this name, but it has the package under another
#           spelling (case, -/_/., a python3-/python3XX- flavour prefix as
#           python3dist() names it: python-authlib vs python-Authlib) — STOP
#   exit 4  IN <target> but no devel project set
#   exit 5  lookup failed (auth, network, or the package list for the
#           spelling check) — never read as "new package"
#   exit 2  usage error
#
# Usage: devel-of.sh <package> [target-project]   (target default: openSUSE:Factory)
# A batch caller sets DEVEL_OF_CACHE to a directory: the target's package list
# is then read once per run.
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 0;;
  '') awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 2;;
esac
pkg="$1" ; target="${2:-openSUSE:Factory}"
if ! meta="$(geectl remote package-meta "$target" "$pkg" 2>&1)"; then
  if grep -q 'not_found' <<<"$meta"; then
    # A miss by this spelling only: Factory shipped python-Authlib while an SR
    # filed python-authlib anew.
    cached="${DEVEL_OF_CACHE:+$DEVEL_OF_CACHE/ls.$target}"
    # parallel callers wait for the one listing (the lock goes with this process)
    [ -z "$cached" ] || { exec 9> "$cached.lock" && flock 9; } || cached=""
    if [ -n "$cached" ] && [ -f "$cached" ]; then
      list="$(cat "$cached")"
    elif ! list="$(geectl remote list-packages "$target" 2>&1 | python3 -I -c '
import sys, json
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError as e:
    sys.stderr.write(f"ERROR: unparseable package list: {e}\n"); sys.exit(2)
print("\n".join(payload.get("packages", [])))
')"; then
      echo "ERROR: cannot list $target to check other spellings of $pkg: $(head -n 1 <<<"$list")" >&2
      exit 5
    elif [ -n "$cached" ]; then
      printf '%s\n' "$list" > "$cached"
    fi
    near="$(python3 -I -c '
import re, sys
def key(n):
    n = re.sub(r"^python3(?:\.?\d+)?(?=[-_.])", "python", n.lower())
    return re.sub(r"[-_.]+", "-", n)
want = key(sys.argv[1])
print(" ".join(n for n in sys.stdin.read().split() if ":" not in n and key(n) == want))
' "$pkg" <<<"$list")" || { echo "ERROR: cannot compare $pkg with $target's package names" >&2; exit 5; }
    if [ -n "$near" ]; then
      echo "NOT IN $target as $pkg, but it has $near — the same package under another spelling: work on that one, never package it anew"
      exit 6
    fi
    echo "NOT IN $target (new package?) — submit via its devel project first (see references/submit-watch.md)"
    exit 3
  fi
  echo "ERROR: cannot read $target/$pkg meta: $meta" >&2
  exit 5
fi
# The meta names the devel project directly (devel-project reads the same
# field); a package with no devel project set has a null devel field.
if ! devel="$(python3 -I -c '
import sys, json
try:
    meta = json.load(sys.stdin)
except json.JSONDecodeError as e:
    sys.stderr.write(f"ERROR: unparseable package meta: {e}\n"); sys.exit(2)
devel = meta.get("devel")
if devel:
    print(devel.get("project", "") + "/" + devel.get("package", ""))
' <<<"$meta")"; then
  echo "ERROR: cannot read $target/$pkg meta: $devel" >&2
  exit 5
fi
if [ -n "$devel" ]; then
  echo "$devel"
  exit 0
fi
echo "IN $target, no devel project set"
exit 4
