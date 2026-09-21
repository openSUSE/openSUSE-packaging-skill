#!/bin/bash
# Reverse build-dependencies of a package within a project, via _builddepinfo.
# Authoritative where `osc whatdependson` is unreliable (it frequently returns
# empty even for libraries that clearly have consumers). The Block-2/3 tool for
# sizing the rebuild scope of a soname bump in a maintenance codestream.
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
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,17p' "$0"; exit 0;;
  '') sed -n '2,17p' "$0"; exit 2;;
esac
# arch defaults to x86_64 because OBS builds it on every project — unlike
# aarch64; the host's aarch64 applies to LOCAL build roots only (see
# build-summary.sh's standard-aarch64 default). Don't "fix" the mismatch.
needle="$1"; project="${2:-openSUSE:Factory}"; repo="${3:-standard}"; arch="${4:-x86_64}"

osc api "/build/$project/$repo/$arch/_builddepinfo" 2>/dev/null | python3 -c '
import sys, xml.etree.ElementTree as ET
needle, scope = sys.argv[1], sys.argv[2]
try:
    root = ET.parse(sys.stdin).getroot()
except ET.ParseError:
    sys.stderr.write("no _builddepinfo for %s (wrong repo/arch, or project not built?)\n" % scope)
    sys.exit(1)
hits = 0
for p in root.findall("package"):
    deps = sorted({d.text for d in p.findall("pkgdep") if d.text and needle in d.text})
    if deps:
        hits += 1
        print("%-30s <- %s" % (p.get("name"), " ".join(deps)))
if hits == 0:
    sys.stderr.write("no consumers of *%s* in %s\n" % (needle, scope))
' "$needle" "$project/$repo/$arch"
