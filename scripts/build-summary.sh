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
# Usage: build-summary.sh [repo-arch | flavor | root-name | root-path | logfile | --list]
#   A full root NAME (exactly what --list prints, e.g. pkg-repo-arch) or a full
#   root PATH is honored verbatim — explicit naming overrides the wrong-package
#   guard that protects the loose repo-arch match.
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
TMPL=$(grep -hE '^\s*build-root\s*=' ~/.config/osc/oscrc ~/.oscrc 2>/dev/null \
       | tail -1 | sed -E 's/^[^=]*=\s*//; s/\s+$//')
: "${TMPL:=/var/tmp/build-root/%(repo)s-%(arch)s}"

root_base() {
  local tmpl="$TMPL"
  # strip trailing path components that are templated (%(package)s etc.)
  while [ -n "$tmpl" ] && case "$tmpl" in */*) [[ "${tmpl##*/}" == *'%('* ]];; *) false;; esac; do
    tmpl="${tmpl%/*}"
  done
  echo "${tmpl:-/var/tmp/build-root}"
}
BASE=$(root_base)

# The template usually embeds %(package)s, so the root is "<pkg>-<repo>-<arch>"
# and a bare "<repo>-<arch>" arg matches NOTHING under BASE. Expanding the
# template with the checkout's own package name is exact; globbing is the
# fallback. Getting this wrong silently reports ANOTHER package's stale log as
# this package's verdict (seen twice: fastmcp -> zoo's log, rtk -> repose's).
CKPKG=""; [ -r .osc/_package ] && CKPKG=$(tr -d '\n' < .osc/_package 2>/dev/null)
# git/scmsync checkout: no .osc, but a single spec names the package.
# NB: use an array — 'set -- *.spec' would clobber the script's own arguments
# and silently drop the repo-arch the caller asked about.
if [ -z "$CKPKG" ] && [ ! -d .osc ]; then
  specs=(*.spec)
  [ "${#specs[@]}" -eq 1 ] && [ -f "${specs[0]}" ] && CKPKG="$(basename "${specs[0]}" .spec)"
fi

expand_root() {                     # expand_root <pkg> <repo> <arch>
  local out="$TMPL"
  out="${out//%(package)s/$1}"; out="${out//%(repo)s/$2}"; out="${out//%(arch)s/$3}"
  out="${out//%(project)s/${OSC_PROJECT:-}}"; out="${out//%(user)s/${USER:-}}"
  echo "$out"
}

# osc records the repo/arch of the last build in the checkout — use it so a bare
# invocation right after `osc build` answers about THAT build.
last_repo=""; last_arch=""
if [ -r .osc/_last_buildroot ]; then
  last_repo=$(sed -n 1p .osc/_last_buildroot); last_arch=$(sed -n 2p .osc/_last_buildroot)
fi

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

if [ -n "${1:-}" ]; then
  arg="$1"
elif [ -n "$last_repo" ] && [ -n "$last_arch" ]; then
  arg="$last_repo-$last_arch"           # what `osc build` last used here
else
  arg="standard-aarch64"
fi
log=""
if [ -f "$arg" ]; then                      # a captured/teed log file
  log="$arg"; rpms=""
elif [ -r "$arg/.build.log" ]; then         # a build-root PATH, used verbatim
  log="$arg/.build.log"; rpms="$arg/home/abuild/rpmbuild/RPMS"
elif [ -r "$BASE/$arg/.build.log" ]; then   # a full root NAME (what --list prints)
  # Explicitly named roots are honored as-is: naming the root IS the
  # disambiguation, so the wrong-package guard below must not apply — it
  # compares against "$CKPKG-$arg" and can never match once $arg already
  # carries the package prefix (real case: the exact string --list printed
  # was rejected with exit 2).
  log="$BASE/$arg/.build.log"; rpms="$BASE/$arg/home/abuild/rpmbuild/RPMS"
else
  # Exact expansion of the oscrc template comes FIRST — it is the only candidate
  # that cannot resolve to a different package.
  cands=()
  if [ -n "$CKPKG" ]; then
    cands+=("$(expand_root "$CKPKG" "${arg%-*}" "${arg##*-}")")
    cands+=("$BASE/$CKPKG-$arg")
  fi
  cands+=("$BASE/_repository:$arg-"* "$BASE"/*":$arg-"* "$BASE/$arg-"*)
  # package-prefixed roots for this repo-arch, newest log first
  while IFS= read -r d; do [ -n "$d" ] && cands+=("$d"); done < <(
    for d in "$BASE"/*"-$arg"/; do
      [ -r "$d/.build.log" ] && printf '%s\t%s\n' "$(date -r "$d/.build.log" +%s)" "${d%/}"
    done 2>/dev/null | sort -rn | cut -f2-)
  cands+=("/var/tmp/build-root/$arg")        # last resort: the un-templated root
  for cand in "${cands[@]}"; do
    [ -r "$cand/.build.log" ] || continue
    # Never answer with another package's log when this checkout names a
    # package. The `compgen` form of this guard only held once SOME root for
    # CKPKG existed; with none at all it fell through and reported a foreign
    # package's stale log as this build's verdict — which is exactly the
    # failure this script exists to prevent. It bit a zstd checkout whose
    # `osc build` had refused the repo name (and still exited 0), answering
    # with gpscorrelate's GREEN. Now: if we know the package, the root must
    # carry its name, full stop.
    if [ -n "$CKPKG" ] && [ "${cand##*/}" != "$CKPKG-$arg" ] \
       && [ "${cand##*/}" != "$CKPKG" ]; then continue; fi
    log="$cand/.build.log"; rpms="$cand/home/abuild/rpmbuild/RPMS"; break
  done
fi
if [ -z "$log" ]; then
  echo "no readable build log for '$arg' under $BASE" >&2
  [ -n "$CKPKG" ] && echo "(checkout package '$CKPKG' — a root belonging to a DIFFERENT package is never used)" >&2
  echo "" >&2; echo "recent build roots:" >&2; list_roots >&2
  exit 2
fi

strip='s/^\[[^]]*\] //'   # drop the "[  98s] " elapsed-time prefix

# Build-log excerpts are third-party text (%check output and rpmlint messages
# quote whatever upstream's tests print) — sanitize them before DISPLAY only;
# the verdict/rc derivation above works on the raw log so sanitization can
# never flip a verdict. See scripts/_sanitize.py.
SDIR="$(cd "$(dirname "$0")" && pwd)"
# On helper failure fall back to the RAW text with a loud stderr warning —
# an empty result would be a silent false-clean (foreign text vanishing).
sanitize() {
  local out
  if out=$(printf '%s' "$1" | python3 "$SDIR/_sanitize.py" 2>/dev/null); then
    printf '%s' "$out"
  else
    echo "WARNING: $SDIR/_sanitize.py unavailable — printing UNSANITIZED third-party text" >&2
    printf '%s' "$1"
  fi
}

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
[ -n "$verdict_line" ] && sanitize "$verdict_line" && echo
[ -n "$rpm_errors" ] && sanitize "$rpm_errors" && echo
[ -n "$badness_abort" ] && sanitize "$badness_abort" && echo
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
t=$(grep -hE '[0-9]+ (passed|failed)|[0-9]+% tests passed|Total Test time|No tests were found|Ran [0-9]+ test|All tests (have )?(PASSED|FAILED)|^\[[ 0-9]+s\] *(Ok|Fail|Expected Fail|Unexpected Pass|Skipped|Timeout): +[0-9]+' "$log" | sed -E "$strip" | tail -6)
# Hand-rolled shell testsuites (autoconf-era, e.g. gpscorrelate) report one
# "Test <name> PASSED/FAILED" line per case and no totals — synthesize the
# count so the section is not silently empty on a package that DOES have a
# %check (which read as "no %check" and invited a pointless re-read of the log).
if [ -z "$t" ]; then
  npass=$(grep -hcE '(^|[] ])Test .* PASSED' "$log")
  nfail=$(grep -hcE '(^|[] ])Test .* FAILED' "$log")
  [ "$npass$nfail" != "00" ] && t="$npass test(s) PASSED, $nfail FAILED"
fi
# GNU automake's parallel test harness ("Testsuite summary for <pkg>") reports
# only a block of "# TOTAL:/# PASS:/# FAIL:/# SKIP:/# XFAIL:/# XPASS:/# ERROR:"
# counters, none of which match any pattern above. par2cmdline 1.3.0 therefore
# printed "(no test summary found — does the spec have a %check?)" on a build
# whose %check had just run 47/47 green — precisely the "silent green" confusion
# this section exists to prevent, only inverted. Collapse the block to one line.
if [ -z "$t" ]; then
  am=$(grep -hE '^\[[^]]*\] *# (TOTAL|PASS|FAIL|SKIP|XFAIL|XPASS|ERROR): +[0-9]+' "$log" \
       | sed -E "$strip" | sed -E 's/^ *# +//; s/: +/=/' \
       | awk '!seen[$0]++ {printf "%s%s", sep, $0; sep=", "} END {if (NR) print ""}')
  [ -n "$am" ] && t="automake testsuite: $am"
fi
[ -n "$t" ] && { sanitize "$t"; echo; } || echo "(no test summary found — does the spec have a %check?)"
echo
echo "### rpmlint"
sanitize "$(grep -hE 'packages and [0-9].* checked;|[0-9]+ errors?, [0-9]+ warnings?.*badness' "$log" | sed -E "$strip" | tail -1)"; echo
issues=$(grep -hE ': (E|W): ' "$log" | sed -E "$strip" | sort -u)
[ -n "$issues" ] && { echo; sanitize "$(printf '%s\n' "$issues" | head -40)"; echo; } || echo "(no E:/W: lines)"
echo
echo "### RPMs produced"
if [ -n "${rpms:-}" ] && [ -d "$rpms" ]; then
  find "$rpms" -name '*.rpm' ! -name '*debuginfo*' ! -name '*debugsource*' 2>/dev/null | sed 's#.*/##' | sort
else
  grep -hoE '[^ ]+\.rpm' "$log" | grep -vE 'debuginfo|debugsource|\.src\.rpm' | sed 's#.*/##' | sort -u
fi
exit "$rc"
