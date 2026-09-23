#!/bin/bash
# Print the devel project registered for a package in a target project.
# This is the lightweight pre-SR existence check (don't `osc list | grep`).
#
# Distinguishes "package absent" from "package present but no devel project set"
# (osc develproject exits 1 in BOTH cases, so a _meta probe decides which):
#   exit 0  present, prints "<devel-project>/<pkg>"
#   exit 3  NOT in <target> (404 on _meta) — new package
#   exit 4  IN <target> but no devel project set
#   exit 5  lookup failed (auth, network, or osc develproject failed although
#           _meta names a devel project) — never read as "new package"
#   exit 2  usage error
#
# Usage: devel-of.sh <package> [target-project]   (target default: openSUSE:Factory)
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 0;;
  '') awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 2;;
esac
pkg="$1" ; target="${2:-openSUSE:Factory}"
if out="$(osc develproject "$target" "$pkg" 2>/dev/null)" && [ -n "$out" ]; then
  echo "$out"
elif meta="$(osc api "/source/$target/$pkg/_meta" 2>&1)"; then
  if grep -q '<devel ' <<<"$meta"; then
    echo "ERROR: osc develproject failed, but $target/$pkg/_meta names a devel project" >&2
    exit 5
  fi
  echo "IN $target, no devel project set"
  exit 4
elif grep -q '404' <<<"$meta"; then
  echo "NOT IN $target (new package?) — submit via its devel project first (see references/submit-watch.md)"
  exit 3
else
  echo "ERROR: cannot read $target/$pkg/_meta: $meta" >&2
  exit 5
fi
