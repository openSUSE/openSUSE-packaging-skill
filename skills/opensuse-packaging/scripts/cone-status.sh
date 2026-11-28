#!/bin/bash
# Per-package build-status table for a whole project (a dependency cone in a
# home: project), in ONE call — so an unattended/remote-build run can gate on
# "is the whole branch green yet?" without hand-rolling a
# `geectl build results | parse the bare code row` pipeline each time.
#
# Reads the build results (all packages at once), prints a code->package table,
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
#   3  no answer: usage error, or the project-meta/results lookup failed or did not parse
#   4  QUEUED-STUCK: the only packages left are "scheduled", the rest succeeded,
#      and 30+ min have passed since each one's last commit and since the
#      last build job in the repo/arch ended (a package scheduled because its
#      dependency just built is not stuck) — they wait for a worker, which no
#      polling shortens: report it and check back later. NOT green: every
#      package must be green before anything is filed
#
# Usage: cone-status.sh <project> [repo] [arch]
#   repo default: first <repository> in the project meta;  arch default: x86_64
#   (arch defaults to x86_64 because OBS builds it on every project — unlike
#   aarch64; contrast build-summary.sh's local standard-aarch64 default, which is
#   THIS host's build root. Don't "fix" the mismatch.)
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 0;;
  '') awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 3;;
esac
prj="$1"; repo="${2:-}"; arch="${3:-x86_64}"

if [ -z "$repo" ]; then
  repo="$(geectl remote project-meta "$prj" 2>/dev/null | python3 -I -c '
import sys, json
try:
    meta = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit()
repos = meta.get("repositories", [])
if repos: print(repos[0].get("name", ""))
')"
  [ -n "$repo" ] || { echo "no repository in $prj meta — pass one explicitly" >&2; exit 3; }
fi

res="$(geectl build results "$prj" --repository "$repo" --arch "$arch" 2>/dev/null)"
[ -n "$res" ] || { echo "no build result for $prj $repo/$arch" >&2; exit 3; }

# Parse the JSON results (attribute-order-independent), classify, print, and
# encode the verdict in the exit code.
printf '%s' "$res" | PRJ="$prj" REPO="$repo" ARCH="$arch" python3 -I -c '
import sys, os, subprocess, time, json
from concurrent.futures import ThreadPoolExecutor
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError as e:
    sys.stderr.write(f"unparseable build results: {e}\n"); sys.exit(3)
results = payload.get("results", [])
result = next((r for r in results
               if r.get("repository") == os.environ["REPO"]
               and r.get("arch") == os.environ["ARCH"]), None)
if result is None:
    sys.stderr.write("no result for the requested repository/arch\n"); sys.exit(3)
dirty = result.get("dirty") is True
overall = result.get("state") or result.get("code") or "?"
rows = [(s.get("code", ""), s.get("package", ""))
        for s in result.get("statuses", [])]
if not rows:
    sys.stderr.write("no package statuses parsed\n"); sys.exit(3)

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

def geectl_json(cmd):
    """A geectl JSON read, or None when it fails or does not parse."""
    try:
        out = subprocess.run(["geectl"] + cmd, capture_output=True, text=True,
                             timeout=30).stdout
        return json.loads(out)
    except (subprocess.TimeoutExpired, OSError, json.JSONDecodeError):
        return None

def last_job_endtime():
    payload = geectl_json(["build", "job-history", prj, repo, arch, "--limit", "1"])
    if not payload:
        return None
    entries = payload.get("entries", [])
    if not entries:
        return 0
    return int(entries[0].get("endtime") or 0)

def last_commit(pkg):
    payload = geectl_json(["remote", "package-log", prj, pkg, "--limit", "1"])
    if not payload:
        return None
    entries = payload.get("entries", [])
    if not entries:
        return 0
    return int(entries[0].get("time") or 0)

queued = [pkg for code, pkg in rows if code == "scheduled"]
if pending and not dirty and not failed and green and len(queued) == pending:
    # a dependency that just built is why a package turns from blocked to
    # scheduled: the newest finished job in the repo/arch counts like a commit
    times = [last_job_endtime()]
    if times[0] is not None and time.time() - times[0] >= 30 * 60:
        names = sorted({pkg.split(":")[0] for pkg in queued})   # a flavor has no package log
        with ThreadPoolExecutor(max_workers=8) as ex:            # one call per package
            times += ex.map(last_commit, names)
    if None in times:
        print("NOTE: a last-commit or job time could not be read — treated as in flight")
    elif time.time() - max(times) >= 30 * 60:
        print(f"QUEUED-STUCK: {len(queued)} scheduled 30+ min with no commit or finished "
              "job there, the rest green — not green: report it and check back later")
        sys.exit(4)
if pending > 0 or dirty:
    sys.exit(1)      # something still in flight — do not trust failures yet
sys.exit(2 if failed > 0 else 0)
'
