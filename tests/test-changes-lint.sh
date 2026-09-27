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
  out="$(bash "$LINT" "$@" 2>&1)"; got=$?; LAST=$out
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

# A CVE id in .changes reads as "fixed here" to every reviewer and tool, so a
# bullet that names one as NOT fixed is a finding. Continuation lines are part
# of their bullet; another bullet is not.
entry() { # <file> <body...>: one clean entry, then the fixture's older one
  { printf '%s\nMon Sep 14 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n' "$SEP"
    printf '%s\n' "${@:2}"; printf '\n'; tail -n +7 "$F"; } > "$work/$1"
}
entry cve-unfixed.changes "- Update to 1.2:" "  * Fix a crash on empty input" "- CVE-2026-1234 is not fixed by this release (boo#1)"
case_ cve-not-fixed 1 "cve-unfixed.changes:6: bullet names a CVE id as not fixed" --entries 1 "$work/cve-unfixed.changes"
entry cve-wrapped.changes "- Update to 1.2, which leaves CVE-2026-1234 open: upstream has" "  NOT" "  fixed it yet"
case_ cve-not-fixed-wrapped 1 "cve-wrapped.changes:4: bullet names a CVE id as not fixed" --entries 1 "$work/cve-wrapped.changes"
entry cve-nested.changes "- Update to 1.2:" "  * CVE-2026-1234: the 32-bit build is still" "    affected"
case_ cve-still-affected-nested 1 "cve-nested.changes:5: bullet names a CVE id as not fixed" --entries 1 "$work/cve-nested.changes"
entry cve-vulnerable.changes "- CVE-2026-1234: still vulnerable, waiting for upstream"
case_ cve-still-vulnerable 1 "bullet names a CVE id as not fixed" --entries 1 "$work/cve-vulnerable.changes"
entry cve-unfixed-word.changes "- CVE-2026-1234 remains unfixed"
case_ cve-unfixed-word 1 "bullet names a CVE id as not fixed" --entries 1 "$work/cve-unfixed-word.changes"
entry cve-fixed.changes "- Fix CVE-2026-1234: crash on a crafted header (boo#1)"
case_ cve-fixed-clean 0 "OK: clean" --entries 1 "$work/cve-fixed.changes"
entry cve-other-bullet.changes "- CVE-2026-1234: crash on a crafted header (boo#1)" "- The slow start-up is not fixed yet"
case_ cve-other-bullet-clean 0 "OK: clean" --entries 1 "$work/cve-other-bullet.changes"
# Only the linted entries: the same bullet one entry down is history.
{ printf '%s\nTue Sep 15 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Update to 1.3\n  * Fix the crash\n\n' "$SEP"
  cat "$work/cve-unfixed.changes"; } > "$work/cve-old.changes"
case_ cve-old-entry-not-linted 0 "OK: clean" --entries 1 "$work/cve-old.changes"
case_ cve-old-entry-linted 1 "cve-old.changes:12: bullet names a CVE id as not fixed" --entries 2 "$work/cve-old.changes"
# One case per phrasing: those references/changelog-rules.md "CVEs and
# security bullets" names, and their kin.
while IFS='|' read -r name text <&3; do
  entry "cve-phrase-$name.changes" "$text"
  case_ "cve-phrase-$name" 1 "cve-phrase-$name.changes:4: bullet names a CVE id as not fixed" \
    --entries 1 "$work/cve-phrase-$name.changes"
done 3<<'EOF'
not-fixed|- CVE-2026-1234 is not fixed by this release
not-fixed-yet|- CVE-2026-1234 not fixed yet
not-yet-fixed|- CVE-2026-1234 is not yet fixed upstream
not-addressed|- CVE-2026-1234 is not addressed by 1.2
isnt-fixed|- CVE-2026-1234 isn't fixed yet
unfixed|- CVE-2026-1234 is unfixed in this release
unpatched|- CVE-2026-1234 is unpatched in this release
still-vulnerable|- CVE-2026-1234: still vulnerable, waiting for upstream
still-affected|- CVE-2026-1234: the 32-bit build is still affected
does-not-fix|- This update does not fix CVE-2026-1234
did-not-fix|- Upstream 1.2 did not fix CVE-2026-1234
doesnt-fix|- 1.2 doesn't fix CVE-2026-1234
does-not-address|- Does not address CVE-2026-1234
did-not-address|- The 1.2 release did not address CVE-2026-1234
tracked-separately|- CVE-2026-1234 tracked separately
remains-open|- CVE-2026-1234 remains open
remains-unfixed|- CVE-2026-1234 remains unfixed
remains-vulnerable|- The parser remains vulnerable to CVE-2026-1234
EOF
grep -qF "if this update fixes it, say so without the not-fixed phrase; if it does not, leave the id out" <<<"$LAST" \
  && pass "cve message says what to do either way" || fail "cve message: $LAST"
# "+" and indented markers open a bullet of their own.
entry cve-plus.changes "- Fix CVE-2026-1111: crash on a crafted header" "  + CVE-2026-2222 remains unfixed"
case_ cve-plus-bullet 1 "cve-plus.changes:5: bullet names a CVE id as not fixed" --entries 1 "$work/cve-plus.changes"
! grep -q "cve-plus.changes:4:" <<<"$LAST" && pass "cve-plus-bullet: the fix bullet is not flagged" || fail "cve-plus-bullet: $LAST"
entry cve-dash-nested.changes "- Update to 1.2:" "    - CVE-2026-2222 remains unfixed"
case_ cve-dash-nested 1 "cve-dash-nested.changes:5: bullet names a CVE id as not fixed" --entries 1 "$work/cve-dash-nested.changes"
# A bullet that states the fix of the id it cites is not a finding, even
# when it also says what an earlier attempt left undone; an id it does not
# state as fixed still is. The not-affected form is the sanctioned one.
entry cve-fix-stated.changes "- Fix CVE-2026-1234, which 1.1 did not fix completely"
case_ cve-fix-stated-clean 0 "OK: clean" --entries 1 "$work/cve-fix-stated.changes"
entry cve-fixed-id-first.changes "- CVE-2026-1234: fixed; the 1.1 patch did not address the" "  32-bit path"
case_ cve-fixed-id-first-clean 0 "OK: clean" --entries 1 "$work/cve-fixed-id-first.changes"
entry cve-addresses.changes "- Addresses CVE-2026-1234 and CVE-2026-5678, which 1.1 left" "  unpatched"
case_ cve-addresses-clean 0 "OK: clean" --entries 1 "$work/cve-addresses.changes"
# A patch named for the id is the fix, whatever else the bullet says.
entry cve-patch-named.changes "- Add foo-CVE-2026-1234-idna.patch: reject bad labels (boo#1," \
  "  CVE-2026-1234). Bumping the vendored library alone does not fix" "  this."
case_ cve-patch-named-clean 0 "OK: clean" --entries 1 "$work/cve-patch-named.changes"
entry cve-fix-other-id.changes "- Fix CVE-2026-1111; CVE-2026-2222 remains unfixed"
case_ cve-fix-other-id 1 "cve-fix-other-id.changes:4: bullet names a CVE id as not fixed" --entries 1 "$work/cve-fix-other-id.changes"
entry cve-not-affected.changes "- Refresh the vendored dependencies:" \
  "  * CVE-2025-55159 (boo#1248048): slab is 0.4.12, above the 0.4.11 fix" \
  "  * CVE-2025-1111 (boo#2): is not affected by this, ships foo 1.2"
case_ cve-not-affected-clean 0 "OK: clean" --entries 1 "$work/cve-not-affected.changes"

echo "---"; [ "$fails" = 0 ] && echo "all changes-lint checks passed" || echo "$fails FAILED"
exit $((fails > 0))
