#!/bin/bash
# Reverse build-dependencies of a package within a project, via _builddepinfo.
# Authoritative where `geectl build whatdependson` on one package name is too
# narrow (it takes an exact binary package, not a substring). The Block-2/3
# tool for sizing the rebuild scope of a soname bump in a maintenance
# codestream.
#
# Output: one consumer source-package per line with the matching dep tokens, so
# you can split consumers by which soname / -devel they actually link (e.g.
# libfoo7 vs the separate foo-2/old-ABI compat package).
#
# Usage: rdeps.sh <pkg-or-substring> [project] [repo] [arch]
#   project default openSUSE:Factory, repo default standard, arch default x86_64
#   <pkg-or-substring> matches against dependency names as a substring, so
#   "mbed" catches libmbedtls14/libmbedcrypto7/mbedtls-devel/... in one pass —
#   but also unrelated names that merely contain it ("mbed" hits *embed* too,
#   e.g. ghc-file-embed/texlive-embedall). Eyeball-filter the obvious noise, or
#   pass a more distinctive needle when the family name allows it.
# Exit: 0 = listed (no consumers is noted on stderr), 1 = no _builddepinfo
#       (wrong repo/arch, project not built, or the API failed), 2 = usage.
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 0;;
  '') awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 2;;
esac
# arch defaults to x86_64 because OBS builds it on every project — unlike
# aarch64; the host's aarch64 applies to LOCAL build roots only (see
# build-summary.sh's standard-aarch64 default). Don't "fix" the mismatch.
needle="$1"; project="${2:-openSUSE:Factory}"; repo="${3:-standard}"; arch="${4:-x86_64}"

# dependson with no --package reads the whole _builddepinfo (view=pkgnames),
# so the substring match runs client-side over every package's dependencies.
# whatdependson takes one exact package and cannot do the substring pass.
geectl build dependson "$project" "$repo" "$arch" 2>/dev/null | python3 -I -c '
import sys, json
needle, scope = sys.argv[1], sys.argv[2]
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.stderr.write("no _builddepinfo for %s (wrong repo/arch, or project not built?)\n" % scope)
    sys.exit(1)
hits = 0
for p in payload.get("packages", []):
    deps = sorted({d for d in p.get("dependencies", []) if d and needle in d})
    if deps:
        hits += 1
        print("%-30s <- %s" % (p.get("name", "?"), " ".join(deps)))
if hits == 0:
    sys.stderr.write("no consumers of *%s* in %s\n" % (needle, scope))
' "$needle" "$project/$repo/$arch"
