#!/bin/bash
# Per-package build-status table for a whole project (a dependency cone in a
# home: project), in ONE call — so an unattended/remote-build run can gate on
# "is the whole branch green yet?" without hand-rolling an
# `osc results | parse the bare code row` pipeline each time.
#
# Reads the _result API (all packages at once), prints a code->package table,
# and — crucially — distinguishes a SETTLED failure from a stale `failed` while
# a rebuild is still pending (the result carries dirty="true", or some package is
# still scheduled/building). It only trusts failures once nothing is in flight.
#
# Exit code (loop on it):
#   0  every applicable package succeeded            -> ready to submit
#   1  still building/scheduled/blocked, or dirty    -> call again later
#   2  a settled failure (failed/broken/unresolvable/UNKNOWN code) with nothing
#      in flight — an unrecognized status code counts as settled-failure, NOT
#      pending, so a stuck package can't keep the loop spinning forever
#
# Usage: cone-status.sh <project> [repo] [arch]
#   repo default: first <repository> in the project _meta;  arch default: x86_64
#   (arch defaults to x86_64 because OBS builds it on every project — unlike
#   aarch64; contrast build-summary.sh's local standard-aarch64 default, which is
#   THIS host's build root. Don't "fix" the mismatch.)
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,24p' "$0"; exit 0;;
  '') sed -n '2,24p' "$0"; exit 2;;
esac
prj="$1"; repo="${2:-}"; arch="${3:-x86_64}"

if [ -z "$repo" ]; then
  repo="$(osc api "/source/$prj/_meta" 2>/dev/null | python3 -c '
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read() or "<project/>")
except ET.ParseError:
    sys.exit()
r = root.find("repository")
if r is not None: print(r.get("name",""))
')"
  [ -n "$repo" ] || { echo "no repository in $prj/_meta — pass one explicitly" >&2; exit 2; }
fi

res="$(osc api "/build/$prj/_result?repository=$repo&arch=$arch" 2>/dev/null)"
[ -n "$res" ] || { echo "no build result for $prj $repo/$arch" >&2; exit 2; }

# Parse with xml.etree (attribute-order-independent), classify, print, and
# encode the verdict in the exit code.
printf '%s' "$res" | PRJ="$prj" REPO="$repo" ARCH="$arch" python3 -c '
import sys, os, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
except ET.ParseError as e:
    sys.stderr.write(f"unparseable _result: {e}\n"); sys.exit(2)
result = root.find("result")
if result is None:
    sys.stderr.write("no <result> element\n"); sys.exit(2)
dirty = result.get("dirty") == "true"
overall = result.get("state") or result.get("code") or "?"
rows = [(s.get("code",""), s.get("package","")) for s in result.findall("status")]
if not rows:
    sys.stderr.write("no package statuses parsed\n"); sys.exit(2)

prj, repo, arch = os.environ["PRJ"], os.environ["REPO"], os.environ["ARCH"]
dirty_s = ", dirty" if dirty else ""
print(f"## {prj} — {repo}/{arch} (overall: {overall}{dirty_s})")
for code, pkg in sorted(rows):
    print(f"  {code:<13} {pkg}")

GREEN   = {"succeeded"}
FAILED  = {"failed", "broken", "unresolvable"}
SKIP    = {"disabled", "excluded"}
PENDING = {"scheduled", "building", "blocked", "finished", "signing", "dispatching"}

green = failed = pending = total = 0
unknown = []
for code, pkg in rows:
    if not code: continue
    if code in SKIP: continue          # not applicable
    total += 1
    if code in GREEN:     green += 1
    elif code in FAILED:  failed += 1
    elif code in PENDING: pending += 1
    else:
        # A truly unknown code must NOT count as pending — the documented
        # "loop on exit 1" usage would then never terminate for a stuck pkg.
        failed += 1
        unknown.append((code, pkg))

print()
print(f"summary: {green} ok / {failed} failed / {pending} in-flight  (of {total} applicable)")
for code, pkg in unknown:
    print(f"NOTE: unknown code {code!r} for {pkg}/{repo}/{arch} — counted as settled failure")

if pending > 0 or dirty:
    sys.exit(1)      # something still in flight — do not trust failures yet
sys.exit(2 if failed > 0 else 0)
'
