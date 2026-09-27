#!/bin/bash
# test-changes-lint.sh — changes-lint.sh over .changes files built at run time.
# The fixture's older entry breaks today's rules on purpose: released entries
# must never be retro-edited, so only --all may flag it. Exit 0 = all
# assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../skills/opensuse-packaging/scripts/changes-lint.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
SEP=-------------------------------------------------------------------

# case_ <name> <expected rc> <expected message> <changes-lint args...>
case_() {
  local name=$1 rc=$2 msg=$3 out got; shift 3
  out="$(bash "$LINT" "$@" 2>&1)"; got=$?
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && ! grep -q Traceback <<<"$out" \
    && pass "$name (rc=$rc)" || { fail "$name: expected rc=$rc and '$msg', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}

F="$work/p.changes"
cat > "$F" <<EOF
$SEP
Mon Sep 14 10:00:00 UTC 2026 - Jane Packager <jane@example.com>

- Update to 1.1:
  * Fix a crash on empty input

$SEP
Mon Jan  5 10:00:00 UTC 2026 - jane@example.com
- initial package
EOF

case_ newest-entry-clean 0 "OK: clean" --entries 1 "$F"
case_ all-flags-old-entry 1 "p.changes:8: separator not followed by a valid" --all "$F"
# 0 used to mean "every entry": the gate went red on released entries whose
# fix is forbidden. A non-number was a traceback.
case_ entries-zero 2 "--entries takes a positive integer" --entries 0 "$F"
case_ entries-word 2 "--entries takes a positive integer" --entries all "$F"
case_ entries-negative 2 "--entries takes a positive integer" --entries -1 "$F"

echo "---"; [ "$fails" = 0 ] && echo "all changes-lint checks passed" || echo "$fails FAILED"
exit $((fails > 0))
