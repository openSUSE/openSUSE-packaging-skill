#!/bin/bash
# Summarize the last `osc build` from its build log — in ONE invocation, so a
# session/agent gets the literal numbers without ad-hoc grep pipelines, and an
# UNAMBIGUOUS verdict it can gate on instead of eyeballing a tail.
# Surfaces: VERDICT + when, %check/ctest pass count, the rpmlint badness summary
# + every E:/W: line, and the produced RPMs.
#
# Exit code IS the verdict — chain on it, never claim "built green" without it:
#   0  GREEN     log has `finished "build <spec>"`
#   1  FAILED    log has `failed "build <spec>"` / RPM build errors / badness abort
#   2  NO LOG    nothing readable at that path (recent build roots are listed)
#   3  NO VERDICT  log exists but the build never reached a conclusion
#                  (still running, or killed — e.g. by a `timeout` wrapper)
#
# No sudo: the preserved build log and RPMs under the build root are readable by
# the build user. If a profile blocks reading them, capture the build yourself —
# `osc build … 2>&1 | tee /tmp/osc-build.log` — and pass that file as the
# argument; osc streams the identical log to stdout.
#
# Usage: build-summary.sh [repo-arch | flavor | logfile | --list]
#   The build root's name comes from `build-root` in oscrc, which is a template
#   (default `%(repo)s-%(arch)s`, often customized to include `%(package)s`), so
#   there is NO single right answer — the arg is matched loosely against the
#   roots that exist. A bare flavor name also resolves (`build-summary.sh serial`
#   finds `_repository:serial-<repo>-<arch>`, which is what `osc build -M serial`
#   writes from a git checkout). `--list` just shows the roots, newest first.
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (/^#/) print; else exit }' "$0"; exit 0;;
esac

# --- where do build roots live? Read the oscrc template, don't assume. --------
root_base() {
  local tmpl
  tmpl=$(grep -hE '^\s*build-root\s*=' ~/.config/osc/oscrc ~/.oscrc 2>/dev/null \
         | tail -1 | sed -E 's/^[^=]*=\s*//; s/\s+$//')
  [ -n "$tmpl" ] || { echo /var/tmp/build-root; return; }
  # strip trailing path components that are templated (%(package)s etc.)
  while [ -n "$tmpl" ] && case "$tmpl" in */*) [[ "${tmpl##*/}" == *'%('* ]];; *) false;; esac; do
    tmpl="${tmpl%/*}"
  done
  echo "${tmpl:-/var/tmp/build-root}"
}
BASE=$(root_base)

list_roots() {
  local d
  for d in "$BASE"/*/ /var/tmp/build-root/*/; do
    [ -r "$d/.build.log" ] || continue
    printf '%s\t%s\t%s\n' \
      "$(date -r "$d/.build.log" '+%m-%d %H:%M' 2>/dev/null)" \
      "$(basename "$d")" \
      "$(grep -hoE '(finished|failed) "build [^"]+"' "$d/.build.log" 2>/dev/null | tail -1)"
  done 2>/dev/null | sort -r | head -12
}

if [ "${1:-}" = "--list" ]; then
  echo "## Build roots under $BASE (newest first)"; list_roots; exit 0
fi

arg="${1:-standard-aarch64}"
log=""
if [ -f "$arg" ]; then                      # a captured/teed log file
  log="$arg"; rpms=""
else
  for cand in "$BASE/$arg" "/var/tmp/build-root/$arg" \
              "$BASE/_repository:$arg-"* "$BASE"/*":$arg-"* "$BASE/$arg-"*; do
    [ -r "$cand/.build.log" ] && { log="$cand/.build.log"; rpms="$cand/home/abuild/rpmbuild/RPMS"; break; }
  done
fi
if [ -z "$log" ]; then
  echo "no readable build log for '$arg' under $BASE" >&2
  echo "" >&2; echo "recent build roots:" >&2; list_roots >&2
  exit 2
fi

strip='s/^\[[^]]*\] //'   # drop the "[  98s] " elapsed-time prefix

# --- verdict ------------------------------------------------------------------
verdict_line=$(grep -hE 'finished "build|failed "build' "$log" | sed -E "$strip" | tail -1)
badness_abort=$(grep -hE 'exceeds threshold, aborting' "$log" | sed -E "$strip" | tail -1)
rpm_errors=$(grep -hE '^RPM build errors' "$log" | sed -E "$strip" | tail -1)

case "$verdict_line" in
  *'finished "build'*) rc=0; verdict="GREEN";;
  *'failed "build'*)   rc=1; verdict="FAILED";;
  *)                   rc=3; verdict="NO VERDICT — build never concluded (still running, or killed)";;
esac
[ -n "$badness_abort" ] && { rc=1; verdict="FAILED (rpmlint badness over threshold)"; }

echo "## Build summary — $arg"
echo
echo "### VERDICT: $verdict"
[ -n "$verdict_line" ] && echo "$verdict_line"
[ -n "$rpm_errors" ] && echo "$rpm_errors"
[ -n "$badness_abort" ] && echo "$badness_abort"
echo "log: $log  (last written $(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null))"
# Named traps that masquerade as something else:
if grep -qE 'error: Architecture is not included' "$log"; then
  echo "!! 'Architecture is not included' — this is usually a MISSING FLAVOR FLAG,"
  echo "   not an arch problem: a _multibuild package guards the flavorless spec"
  echo "   with 'ExclusiveArch: do_not_build'. Rebuild with 'osc build -M <flavor>'."
fi
[ "$rc" = 3 ] && echo "!! No 'finished'/'failed' line. If you wrapped the build in 'timeout', it was"
[ "$rc" = 3 ] && echo "   killed (exit 124) and this log is truncated — that is YOUR cap, not an FTBFS."
echo
echo "### %check / tests"
t=$(grep -hE '[0-9]+ (passed|failed)|[0-9]+% tests passed|Total Test time|No tests were found|Ran [0-9]+ test|^\[[ 0-9]+s\] *(Ok|Fail|Expected Fail|Unexpected Pass|Skipped|Timeout): +[0-9]+' "$log" | sed -E "$strip" | tail -6)
[ -n "$t" ] && echo "$t" || echo "(no test summary found — does the spec have a %check?)"
echo
echo "### rpmlint"
grep -hE 'packages and [0-9].* checked;|[0-9]+ errors?, [0-9]+ warnings?.*badness' "$log" | sed -E "$strip" | tail -1
issues=$(grep -hE ': (E|W): ' "$log" | sed -E "$strip" | sort -u)
[ -n "$issues" ] && { echo; echo "$issues" | head -40; } || echo "(no E:/W: lines)"
echo
echo "### RPMs produced"
if [ -n "${rpms:-}" ] && [ -d "$rpms" ]; then
  find "$rpms" -name '*.rpm' ! -name '*debuginfo*' ! -name '*debugsource*' 2>/dev/null | sed 's#.*/##' | sort
else
  grep -hoE '[^ ]+\.rpm' "$log" | grep -vE 'debuginfo|debugsource|\.src\.rpm' | sed 's#.*/##' | sort -u
fi
exit "$rc"
