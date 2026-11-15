#!/bin/bash
# test-distro-survey.sh — distro-survey.sh offline: its two settings reach shell
# arithmetic, so a value that is not a whole number is a usage error before any
# request is made and before the shell can evaluate it. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DS="$HERE/../skills/opensuse-packaging/scripts/distro-survey.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1

bash "$DS" >/dev/null 2>&1; [ $? = 2 ] && pass "no package is a usage error (2)" || fail "no package must exit 2"
for v in DISTRO_SURVEY_BUDGET DISTRO_SURVEY_TIMEOUT; do
  # As bash reads an array subscript in arithmetic: it would run the command.
  out="$(env "$v=x[\$(touch $work/ran-$v)]" timeout 20 bash "$DS" hwdata 2>&1)"; rc=$?
  [ $rc = 2 ] && [ ! -e "$work/ran-$v" ] && grep -q 'whole seconds' <<<"$out" \
    && pass "$v that is not a number is refused and not evaluated" || fail "$v as code: rc=$rc ran=$(ls "$work")"
done
# A leading 0 would be octal, or stop the script at 08; a long number wraps.
for bad in 1.5 010 08 0 -5 +5 ' 5' 1234567; do
  out="$(DISTRO_SURVEY_BUDGET="$bad" timeout 20 bash "$DS" hwdata 2>&1)"; rc=$?
  [ $rc = 2 ] && grep -q 'whole seconds' <<<"$out" && pass "DISTRO_SURVEY_BUDGET='$bad' is refused" || fail "DISTRO_SURVEY_BUDGET='$bad': rc=$rc"
done
[ "$fails" = 0 ]
