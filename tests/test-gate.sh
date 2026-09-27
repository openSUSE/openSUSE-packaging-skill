#!/bin/bash
# test-gate.sh — gate.sh refuses a directory that is not a package checkout
# before any gate runs: source_validator there reported rc=0, a green piece of a
# verdict about nothing. Offline; TMPDIR keeps gate.sh's logs in the work dir.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../skills/opensuse-packaging/scripts/gate.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export TMPDIR="$work"

# case_ <name> <expected rc> <expected message> <dir>
case_() {
  local out got
  out="$(bash "$GATE" "$4" 2>&1)"; got=$?
  [ "$got" = "$2" ] && grep -qF -- "$3" <<<"$out" && pass "$1 (rc=$2)" || {
    fail "$1: expected rc=$2 and '$3', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
  LAST=$out
}

# A bad --entries is a usage error before any gate runs, not a red gate.
mkdir -p "$work/pkg0" && printf 'Name: p\n' > "$work/pkg0/p.spec"
for n in 0 x -1; do
  out="$(bash "$GATE" "$work/pkg0" --entries "$n" 2>&1)"; rc=$?
  [ "$rc" = 2 ] && grep -qF -- "--entries takes a positive integer" <<<"$out" && ! grep -q '^## ' <<<"$out" \
    && pass "--entries $n: usage error, no gate ran" || { fail "--entries $n: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
done
mkdir -p "$work/project/.osc" && printf 'devel:example\n' > "$work/project/.osc/_project"
case_ project-checkout 2 "osc project checkout — cd into the package directory" "$work/project"
! grep -q '^## ' <<<"$LAST" && pass "project-checkout: no gate ran" || fail "project-checkout: gates ran: $LAST"
mkdir -p "$work/empty"
case_ empty-dir 2 "no *.spec and no .osc/_package" "$work/empty"
! grep -q '^## ' <<<"$LAST" && pass "empty-dir: no gate ran" || fail "empty-dir: gates ran: $LAST"
# Control: a spec is enough to get past the refusal; the gates then run (and
# are red here: no .changes, and not a checkout changes-patches can read).
mkdir -p "$work/pkg" && printf 'Name: p\n' > "$work/pkg/p.spec"
case_ spec-only 1 "VERDICT: RED" "$work/pkg"

echo "---"; [ "$fails" = 0 ] && echo "all gate checks passed" || echo "$fails FAILED"
exit $((fails > 0))
