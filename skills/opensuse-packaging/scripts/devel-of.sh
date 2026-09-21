#!/bin/bash
# Print the devel project registered for a package in a target project.
# This is the lightweight pre-SR existence check (don't `osc list | grep`).
#
# Distinguishes "package absent" from "package present but no devel project set"
# (osc develproject exits 1 in BOTH cases, so a _meta probe decides which):
#   exit 0  present, prints "<devel-project>/<pkg>"
#   exit 3  NOT in <target> (404 on _meta) — new package
#   exit 4  IN <target> but no devel project set
#   exit 2  usage error
#
# Usage: devel-of.sh <package> [target-project]   (target default: openSUSE:Factory)
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,13p' "$0"; exit 0;;
  '') sed -n '2,13p' "$0"; exit 2;;
esac
pkg="$1" ; target="${2:-openSUSE:Factory}"
if out="$(osc develproject "$target" "$pkg" 2>/dev/null)" && [ -n "$out" ]; then
  echo "$out"
elif osc api "/source/$target/$pkg/_meta" >/dev/null 2>&1; then
  echo "IN $target, no devel project set"
  exit 4
else
  echo "NOT IN $target (new package?) — submit via its devel project first (see references/submit-watch.md)"
  exit 3
fi
