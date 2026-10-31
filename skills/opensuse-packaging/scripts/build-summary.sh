#!/bin/bash
# Summarize the last `osc build` from its build log — in ONE invocation, so a
# session/agent gets the literal numbers without ad-hoc grep pipelines, and an
# UNAMBIGUOUS verdict it can gate on instead of eyeballing a tail.
# Surfaces: VERDICT + when, %check/ctest pass count, the rpmlint badness summary
# + every E:/W: line, and the produced RPMs.
#
# Exit code IS the verdict — chain on it, never claim "built green" without it:
#   0  GREEN     log has `finished "build <spec>"`
#   1  FAILED    log has `failed "build <spec>"` / RPM build errors / badness abort,
#                or a built RPM requires a user()/group() its own scriptlets
#                create and no built RPM provides (it would not install)
#   2  NO LOG    nothing readable at that path (recent build roots are listed)
#   3  NO VERDICT  log exists but the build never reached a conclusion
#                  (still running, or killed — e.g. by a `timeout` wrapper),
#                  or a green spec build whose RPM directory is not known to
#                  be this build's (no SRPMS/*src.rpm there) or whose RPMs
#                  cannot be queried (no rpm, or rpm cannot read them)
#
# No sudo: the preserved build log and RPMs under the build root are readable by
# the build user. If a profile blocks reading them, capture the build yourself —
# `osc build … 2>&1 | tee /tmp/osc-build.log` — and pass that file as the
# argument; osc streams the identical log to stdout.
#
# Usage: build-summary.sh [repo-arch | flavor | root-name | root-path | logfile | --rpms DIR logfile | --list]
#   --rpms DIR: the build's .build.packages, whose RPMS/ get the user()/group()
#   check a bare log file cannot have. A root form reads the .build.packages of
#   the build root its log names first (<root>, or <root>/.mount for a VM build,
#   build-type=kvm); with no such line, <root>/.mount/.build.packages beside an
#   image <root>/img, else <root>/.build.packages.
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
pkgdir=""
if [ "${1:-}" = --rpms ]; then
  if [ $# -ne 3 ] || [ ! -f "$3" ]; then
    echo "no readable build log '${3:-}' (usage: build-summary.sh --rpms DIR LOGFILE)" >&2; exit 2
  fi
  pkgdir=$2; shift 2
fi

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

# A VM build (build-type=kvm) runs in <root>/.mount, and --clean wipes only that:
# the chroot tree of an earlier build in <root> is stale, so never home/abuild.
# The log's own BUILD_ROOT comes first: an oscrc build-device moves the image
# out of the root, and a later chroot build leaves an old image in it.
pkgdir_of() {
  local b
  b=$(sed -n '/Using BUILD_ROOT=/{s/.*Using BUILD_ROOT=//p;q;}' "$1/.build.log" 2>/dev/null)
  if [ -n "$b" ]; then echo "$b/.build.packages"
  elif [ -e "$1/img" ] && [ -d "$1/.mount" ]; then echo "$1/.mount/.build.packages"
  else echo "$1/.build.packages"; fi
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
      "$(grep -ahoE '(finished|failed) "build [^"]+"' "$d/.build.log" 2>/dev/null | tail -1)"
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
  log="$arg"
elif [ -r "$arg/.build.log" ]; then         # a build-root PATH, used verbatim
  log="$arg/.build.log"; pkgdir=$(pkgdir_of "$arg")
elif [ -r "$BASE/$arg/.build.log" ]; then   # a full root NAME (what --list prints)
  # Explicitly named roots are honored as-is: naming the root IS the
  # disambiguation, so the wrong-package guard below must not apply — it
  # compares against "$CKPKG-$arg" and can never match once $arg already
  # carries the package prefix (real case: the exact string --list printed
  # was rejected with exit 2).
  log="$BASE/$arg/.build.log"; pkgdir=$(pkgdir_of "$BASE/$arg")
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
    log="$cand/.build.log"; pkgdir=$(pkgdir_of "$cand"); break
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
# grep -a: a VM build's console output can carry a NUL, and grep skips a "binary" log.
verdict_line=$(grep -ahE 'finished "build|failed "build' "$log" | sed -E "$strip" | tail -1)
badness_abort=$(grep -ahE 'exceeds threshold, aborting' "$log" | sed -E "$strip" | tail -1)
rpm_errors=$(grep -ahE '^RPM build errors' "$log" | sed -E "$strip" | tail -1)

case "$verdict_line" in
  *'finished "build'*) rc=0; verdict="GREEN";;
  *'failed "build'*)   rc=1; verdict="FAILED";;
  *)                   rc=3; verdict="NO VERDICT — build never concluded (still running, or killed)";;
esac
[ -n "$badness_abort" ] && { rc=1; verdict="FAILED (rpmlint badness over threshold)"; }

# rpm derives user(X)/group(X) requires from %attr ownership; a user the package's
# own scriptlets create must also be provided (sysusers.d does it, a useradd in
# %pre needs Provides:), or nothing can install it. System users (root, mail, ...)
# come from other packages and are left alone.
# A spec build writes its source RPM (.src.rpm, or .nosrc.rpm for NoSource; obs-build
# globs *src.rpm) unless osc's --stage skips -bs, so none means the lookup is not
# known to be this build's; a source RPM alone (a test flavor) leaves nothing to
# install. An RPM rpm cannot read would make the check below read as passed.
users_checked=0; unprovided=""; noquery=""; built=()
if [ -n "$pkgdir" ]; then
  mapfile -t built < <(find "$pkgdir/RPMS" -name '*.rpm' ! -name '*debuginfo*' ! -name '*debugsource*' 2>/dev/null)
  if [[ $verdict_line == *'.spec"'* ]] && [ -z "$(find "$pkgdir/SRPMS" -name '*src.rpm' 2>/dev/null | head -1)" ]; then
    noquery="no source RPM under $pkgdir/SRPMS: the RPMs there are not known to be this build's"
  elif [ "${#built[@]}" -gt 0 ] && ! command -v rpm >/dev/null 2>&1; then
    noquery="rpm is not on PATH to query the built RPMs"
  elif [ "${#built[@]}" -gt 0 ] && ! rpm -qp --qf '' "${built[@]}" >/dev/null 2>&1; then
    noquery="rpm cannot read the built RPMs under $pkgdir/RPMS"
  elif [ "${#built[@]}" -gt 0 ]; then
    users_checked=1
    req=$(rpm -qp --requires "${built[@]}" 2>/dev/null | grep -oE '^(user|group)\([^)]+\)' | sort -u)
    prov=$(rpm -qp --provides "${built[@]}" 2>/dev/null | grep -oE '^(user|group)\([^)]+\)' | sort -u)
    made=$(rpm -qp --scripts "${built[@]}" 2>/dev/null | grep -E '(user|group)add')
    for d in $(comm -23 <(printf '%s\n' "$req") <(printf '%s\n' "$prov")); do
      n=${d#*(}; n=${n%)}
      grep -qwF -- "$n" <<<"$made" && unprovided+="${unprovided:+ }$d"
    done
  fi
fi
if [ -n "$unprovided" ] && [ "$rc" = 0 ]; then
  rc=1; verdict="FAILED (not installable: nothing provides $unprovided)"
fi
if [ -n "$noquery" ] && [ "$rc" = 0 ]; then rc=3; verdict="NO VERDICT — $noquery"; fi

echo "## Build summary — $arg"
echo
echo "### VERDICT: $verdict"
[ -n "$verdict_line" ] && sanitize "$verdict_line" && echo
[ -n "$rpm_errors" ] && sanitize "$rpm_errors" && echo
[ -n "$badness_abort" ] && sanitize "$badness_abort" && echo
echo "log: $log  (last written $(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null))"
# Named traps that masquerade as something else:
if grep -aqE 'error: Architecture is not included' "$log"; then
  echo "!! 'Architecture is not included' — this is usually a MISSING FLAVOR FLAG,"
  echo "   not an arch problem: a _multibuild package guards the flavorless spec"
  echo "   with 'ExclusiveArch: do_not_build'. Rebuild with 'osc build -M <flavor>'."
fi
if [ "$rc" = 3 ] && [ -z "$verdict_line" ]; then
  echo "!! No 'finished'/'failed' line. If you wrapped the build in 'timeout', it was"
  echo "   killed (exit 124) and this log is truncated — that is YOUR cap, not an FTBFS."
fi
echo
echo "### %check / tests"
# googletest is matched explicitly: it prints the count AFTER an upper-case
# bracketed tag ("[  PASSED  ] 1547 tests.", "[  FAILED  ] 2 tests"), so the
# lower-case '[0-9]+ (passed|failed)' alternative above never fires on it and
# libddwaf reported "no test summary found" on a build that ran 1547 tests.
# FAILED is matched too, so a failing gtest run cannot read as a silent pass.
t=$(grep -ahE '[0-9]+ (passed|failed)|[0-9]+% tests passed|Total Test time|No tests were found|Ran [0-9]+ test|All tests (have )?(PASSED|FAILED)|\[ *(PASSED|FAILED) *\] [0-9]+ test|[0-9]+ tests? from [0-9]+ test suites? ran|^\[[ 0-9]+s\] *(Ok|Fail|Expected Fail|Unexpected Pass|Skipped|Timeout): +[0-9]+' "$log" | sed -E "$strip" | tail -6)
# Hand-rolled shell testsuites (autoconf-era, e.g. gpscorrelate) report one
# "Test <name> PASSED/FAILED" line per case and no totals — synthesize the
# count so the section is not silently empty on a package that DOES have a
# %check (which read as "no %check" and invited a pointless re-read of the log).
if [ -z "$t" ]; then
  npass=$(grep -ahcE '(^|[] ])Test .* PASSED' "$log")
  nfail=$(grep -ahcE '(^|[] ])Test .* FAILED' "$log")
  [ "$npass$nfail" != "00" ] && t="$npass test(s) PASSED, $nfail FAILED"
fi
# GNU automake's parallel test harness ("Testsuite summary for <pkg>") reports
# only a block of "# TOTAL:/# PASS:/# FAIL:/# SKIP:/# XFAIL:/# XPASS:/# ERROR:"
# counters, none of which match any pattern above. par2cmdline 1.3.0 therefore
# printed "(no test summary found — does the spec have a %check?)" on a build
# whose %check had just run 47/47 green — precisely the "silent green" confusion
# this section exists to prevent, only inverted. Collapse the block to one line.
if [ -z "$t" ]; then
  am=$(grep -ahE '^\[[^]]*\] *# (TOTAL|PASS|FAIL|SKIP|XFAIL|XPASS|ERROR): +[0-9]+' "$log" \
       | sed -E "$strip" | sed -E 's/^ *# +//; s/: +/=/' \
       | awk '!seen[$0]++ {printf "%s%s", sep, $0; sep=", "} END {if (NR) print ""}')
  [ -n "$am" ] && t="automake testsuite: $am"
fi
[ -n "$t" ] && { sanitize "$t"; echo; } || echo "(no test summary found — does the spec have a %check?)"
echo
echo "### rpmlint"
sanitize "$(grep -ahE 'packages and [0-9].* checked;|[0-9]+ errors?, [0-9]+ warnings?.*badness' "$log" | sed -E "$strip" | tail -1)"; echo
issues=$(grep -ahE ': (E|W): ' "$log" | sed -E "$strip" | sort -u)
[ -n "$issues" ] && { echo; sanitize "$(printf '%s\n' "$issues" | head -40)"; echo; } || echo "(no E:/W: lines)"
echo
echo "### RPMs produced"
if [ -n "$pkgdir" ]; then
  [ "${#built[@]}" -eq 0 ] || printf '%s\n' "${built[@]}" | sed 's#.*/##' | sort
else
  grep -ahoE '[^ ]+\.rpm' "$log" | grep -vE 'debuginfo|debugsource|\.src\.rpm' | sed 's#.*/##' | sort -u
fi
echo
echo "### user()/group() dependencies"
if [ -n "$unprovided" ]; then
  echo "nothing provides $unprovided, which the package's own scriptlets create: ship a sysusers.d file"
  echo "(sysuser-tools; it provides them) or add Provides: for each (references/specfile-guidelines.md \"Sysusers / system users\")"
elif [ "$users_checked" = 1 ]; then
  echo "OK: every user()/group() a built RPM requires and creates is provided"
elif [ -n "$noquery" ]; then
  echo "(not checked: $noquery)"
elif [ -n "$pkgdir" ]; then
  echo "(nothing to install: $pkgdir holds no binary RPM)"
else
  echo "(not checked: no built RPMs to query)"
fi
exit "$rc"
