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
# state as fixed still is. A not-affected id is no way out: see below.
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
# A not-affected line must not carry an id either: the trackers read it as a
# fix. The assessment goes in the bug comment. Real decline: pool/gh PR #11.
NA_MSG="bullet cites an id for an issue it says is not affected"
entry cve-not-affected.changes "- Refresh the vendored dependencies:" \
  "  * CVE-2025-1111 (boo#2): is not affected by this, ships foo 1.2"
case_ cve-not-affected 1 "cve-not-affected.changes:5: $NA_MSG" --entries 1 "$work/cve-not-affected.changes"
grep -qF -- "put the assessment in the bug comment" <<<"$LAST" && pass "not-affected message says where it goes" || fail "not-affected message: $LAST"
entry cve-not-affected-above.changes "- Refresh the vendored dependencies:" \
  "  * CVE-2025-55159 (boo#1248048): slab is 0.4.12, above the 0.4.11" \
  "    fix"
case_ cve-above-the-fix 1 "cve-not-affected-above.changes:5: $NA_MSG" --entries 1 "$work/cve-not-affected-above.changes"
# the gh.changes shape: the header says it, the sub-bullets carry the ids
entry cve-na-header.changes "- Update to 2.103.3" \
  "- Not affected, vendored dependencies are above the fixed version:" \
  "  * CVE-2026-1111 (bsc#1): package is 1.2.3, fixed in 1.2.0" \
  "  * CVE-2026-2222 (bsc#2): package is 2.0.1, fixed in 2.0.0"
case_ cve-na-header 1 "cve-na-header.changes:5: $NA_MSG" --entries 1 "$work/cve-na-header.changes"
entry cve-na-bug-only.changes "- Update to 1.2:" "  * Not affected by boo#1234567 (the code postdates 1.1)"
case_ cve-na-bug-id 1 "cve-na-bug-only.changes:5: $NA_MSG" --entries 1 "$work/cve-na-bug-only.changes"
entry cve-na-other-bullet.changes "- Fix CVE-2026-1111 (boo#1)" "- The 32-bit build is not affected"
case_ cve-na-other-bullet-clean 0 "OK: clean" --entries 1 "$work/cve-na-other-bullet.changes"
entry cve-na-mixed.changes "- Fix CVE-2026-1111, which the old build is not affected by" \
  "  on arm, and CVE-2026-2222 (boo#2): not affected"
case_ cve-na-mixed 1 "cve-na-mixed.changes:4: $NA_MSG" --entries 1 "$work/cve-na-mixed.changes"
entry cve-na-no-id.changes "- Refresh the vendored dependencies" "- Fix CVE-2026-1111 (boo#1): crash on empty input" \
  "- The bundled foo is above the fixed version for the other issue"
case_ cve-na-no-id-clean 0 "OK: clean" --entries 1 "$work/cve-na-no-id.changes"
# "the fixed version" is not-affected wording, not a statement that an id is fixed
entry cve-na-header-one.changes "- Not affected, vendored dependencies are above the fixed version:" \
  "  * CVE-2026-1111 (bsc#1)"
case_ cve-na-header-one 1 "cve-na-header-one.changes:4: $NA_MSG (CVE-2026-1111, bsc#1)" --entries 1 "$work/cve-na-header-one.changes"
entry cve-na-oneliner.changes "- Not affected (above the fixed versions): CVE-2026-1111," "  CVE-2026-2222 (bsc#1, bsc#2)"
case_ cve-na-oneliner 1 "cve-na-oneliner.changes:4: $NA_MSG (CVE-2026-1111, CVE-2026-2222, bsc#1, bsc#2)" \
  --entries 1 "$work/cve-na-oneliner.changes"
# a header without its ':', or a list at the header's own indent
entry cve-na-no-colon.changes "- Not affected, vendored dependencies are above the fixed version" \
  "  * CVE-2026-1111 (bsc#1): package is 1.2.3, fixed in 1.2.0"
case_ cve-na-no-colon 1 "cve-na-no-colon.changes:4: $NA_MSG (CVE-2026-1111, bsc#1)" --entries 1 "$work/cve-na-no-colon.changes"
entry cve-na-same-indent.changes "- Not affected, vendored dependencies are above the fixed version:" \
  "- CVE-2026-1111 (bsc#1): package is 1.2.3, fixed in 1.2.0" "- Fix a crash on empty input (boo#3)"
case_ cve-na-same-indent 1 "cve-na-same-indent.changes:4: $NA_MSG (CVE-2026-1111, bsc#1)" --entries 1 "$work/cve-na-same-indent.changes"
# A fix that also says what is not affected: only the ids next to that phrase count.
entry cve-na-fix-and-na.changes "- Fix CVE-2026-1111 (boo#1); boo#2 is not affected"
case_ cve-na-fix-and-na 1 "cve-na-fix-and-na.changes:4: $NA_MSG (boo#2)" --entries 1 "$work/cve-na-fix-and-na.changes"
entry cve-na-fix-list.changes "- Update to 0.23.0:" "  * The other CVEs fixed by this release are in bindings this" \
  "    package does not build, so it is not affected here:" "    CVE-2026-1111 (boo#1, Lua), CVE-2026-2222 (boo#2, Java)"
case_ cve-na-fix-list 1 "cve-na-fix-list.changes:5: $NA_MSG (CVE-2026-1111, boo#1, CVE-2026-2222, boo#2)" \
  --entries 1 "$work/cve-na-fix-list.changes"
while IFS='|' read -r name text <&3; do
  entry "cve-na-$name.changes" "$text"
  case_ "cve-na-$name" 1 "cve-na-$name.changes:4: $NA_MSG" --entries 1 "$work/cve-na-$name.changes"
done 3<<'EOF'
fix-layout|- CVE-2026-1111: not affected, ships 1.2 (bsc#1)
does-not-affect|- CVE-2026-1111 (bsc#1) does not affect this package
isnt-affected|- The vendored foo isn't affected by CVE-2026-1111 (bsc#1)
not-vulnerable|- This package is not vulnerable to CVE-2026-1111 (bsc#1)
already-fixed|- The parser overflow (bsc#1) was already fixed in 1.1
already-upstream|- The parser overflow (bsc#1) was already fixed upstream
hyphen|- CVE-2026-1111 (bsc#1): not-affected, ships 1.2
not-impacted|- This package is not impacted by CVE-2026-1111 (bsc#1)
id-led-fix-verb|- CVE-2026-1111 (bsc#1): this package is not affected; a guard prevents it
upstream-fixed-it|- Not affected by CVE-2026-1111 (bsc#1): upstream 1.2 fixed it
upstream-fixed-them|- CVE-2026-1111 (bsc#1) is not affected, as upstream 1.2 fixed them
EOF
while IFS='|' read -r name text <&3; do
  entry "cve-na-ok-$name.changes" "- Update to 1.2:" "$text"
  case_ "cve-na-ok-$name" 0 "OK: clean" --entries 1 "$work/cve-na-ok-$name.changes"
done 3<<'EOF'
bump-layout|  * CVE-2026-1111: heap overflow; 1.x is not affected (bsc#1)
fix-bug|- Fix a crash (boo#1234567); Wayland sessions are not affected
patch-named|- Add fix-resume.patch: Wayland sessions are unaffected (boo#1)
keep|- Keep configs unaffected by the upgrade (boo#1234567)
over-patched|- Prefer system zlib over the patched bundled copy (boo#1234567)
bump-above|- Bump vendored slab to 0.4.12, above the 0.4.11 fix (boo#1)
arrow-above|- slab 0.4.11 -> 0.4.12, above the 0.4.11 fix (CVE-2025-55159)
id-led-bump|- CVE-2025-55159 (boo#1): slab bumped to 0.4.12, above the fix
update-scope|- Update foo to 2.0 (boo#1); 1.x is not affected
fixed-by-update|- CVE-2026-1111 (bsc#1): fixed by this update; 1.x is not affected
fixes-it|- CVE-2026-1111 (bsc#1): crash, 1.x unaffected; this bump fixes it
id-led-fix|- CVE-2026-1111 (bsc#1): crash, closed by the bump; 2.x unaffected
harden|- Harden the parser (CVE-2026-1111, bsc#1); 2.x is not affected
reject|- Reject long headers (CVE-2026-1111, bsc#1); 2.x is not affected
mitigate|- Mitigate the desync (CVE-2026-1111, bsc#1); 2.x is not affected
prevent|- Prevent the overflow (CVE-2026-1111, bsc#1); 2.x is not affected
sanitize|- Sanitize the header (CVE-2026-1111, bsc#1); 2.x is not affected
close|- Close the desync (CVE-2026-1111, bsc#1); 2.x is not affected
EOF
# A fixing bump reads "above the fix" too (pi-coding-agent).
entry cve-na-ok-fix-floor.changes "- Update to 1.5.0:" "  * CVE-2026-87018 (boo#1285858): undici is 8.12.3, above the" \
  "    8.12.2 fix floor, so this update fixes it"
case_ cve-na-ok-fix-floor 0 "OK: clean" --entries 1 "$work/cve-na-ok-fix-floor.changes"
# The bump closes one id; the other is a real not-affected one (zed).
entry cve-na-closes.changes "- Update to 0.200.0:" "  * async-tar 0.5.0 -> 0.6.1 takes an entry's size from its PAX" \
  "    header, closing the desync upstream cites as CVE-2025-62518;" \
  "    it is not affected by CVE-2026-53600, a desync that fix introduced"
case_ cve-na-closes 1 "cve-na-closes.changes:5: $NA_MSG (CVE-2026-53600)" --entries 1 "$work/cve-na-closes.changes"
# A scope note in a header does not reach the fixes listed under it ...
entry cve-na-ok-scope-header.changes "- Update to 3.1.2 (3.0.x is not affected):" "  * CVE-2026-1111: heap overflow (bsc#1)"
case_ cve-na-ok-scope-header 0 "OK: clean" --entries 1 "$work/cve-na-ok-scope-header.changes"
entry cve-na-ok-scope-list.changes "- Update to 3.1.2:" "  * Security fixes, 3.0.x is not affected:" \
  "    + CVE-2026-1111: heap overflow (bsc#1)"
case_ cve-na-ok-scope-list 0 "OK: clean" --entries 1 "$work/cve-na-ok-scope-list.changes"
# ... but a header that opens with the phrase, or whose list is what is not affected,
# lists not-affected ids, whatever their layout.
entry cve-na-by-list.changes "- The bundled copy is newer, so the package is not affected by:" \
  "  * CVE-2026-1111: overflow (bsc#1)"
case_ cve-na-by-list 1 "cve-na-by-list.changes:4: $NA_MSG (CVE-2026-1111, bsc#1)" --entries 1 "$work/cve-na-by-list.changes"
entry cve-na-following.changes "- Update to 1.2; the following are not affected:" "  * CVE-2026-1111: overflow (bsc#1)"
case_ cve-na-following 1 "cve-na-following.changes:4: $NA_MSG (CVE-2026-1111, bsc#1)" --entries 1 "$work/cve-na-following.changes"
entry cve-na-header-layout.changes "- Not affected, vendored dependencies are above the fixed version:" \
  "  * CVE-2026-1111: package is 1.2.3, fixed in 1.2.0 (bsc#1)"
case_ cve-na-header-layout 1 "cve-na-header-layout.changes:4: $NA_MSG (CVE-2026-1111, bsc#1)" \
  --entries 1 "$work/cve-na-header-layout.changes"
# A long id list is linear: 6000 ids took 40 s when each list was re-read from every id.
{ printf '%s\nMon Sep 14 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Not affected by:\n' "$SEP"
  for i in $(seq 10000 12999); do printf '  CVE-2026-%s (boo#%s), CVE-2026-%s (boo#%s),\n' "$i" "2$i" "$((i + 5000))" "3$i"; done
} > "$work/cve-na-long.changes"
out=$(timeout 20 bash "$LINT" --entries 1 "$work/cve-na-long.changes" 2>&1); rc=$?
[ $rc = 1 ] && grep -qF "cve-na-long.changes:4: $NA_MSG" <<<"$out" && pass "cve-na-long-list (rc=1, in time)" \
  || fail "cve-na-long-list: rc=$rc (124 = timed out)"
entry cve-na-ok-patch-layout.changes "- CVE-2026-1111: heap overflow; arm is not affected (bsc#1)" \
  "  * fix-CVE-2026-1111.patch"
case_ cve-na-ok-patch-layout 0 "OK: clean" --entries 1 "$work/cve-na-ok-patch-layout.changes"
entry cve-na-ok-security-header.changes "- Update to 3.1.2:" "  * Security fixes (3.0.x is not affected):" \
  "    + CVE-2026-1111: heap overflow (bsc#1)"
case_ cve-na-ok-security-header 0 "OK: clean" --entries 1 "$work/cve-na-ok-security-header.changes"

# Request ids and staging order belong in the SR message, not in .changes.
# Real case: sr#1385697, wrapped over a continuation line.
entry req-lands-after.changes "- Update to 5.1.15 (requires fcitx5 >= 5.1.22 and libime >= 1.1.14;" \
  "  lands after SR 1385569):" "  * Pinyin: keep typed context for prediction"
case_ req-lands-after 1 "req-lands-after.changes:4: bullet names a submit request or a staging order" --entries 1 "$work/req-lands-after.changes"
grep -qF -- "put it in the SR message (- Stage with sr#N), not in .changes" <<<"$LAST" \
  && pass "request message says where it goes" || fail "request message: $LAST"
while IFS='|' read -r name text <&3; do
  entry "req-$name.changes" "- Update to 1.2:" "  * Fix a crash on empty input" "$text"
  case_ "req-$name" 1 "req-$name.changes:6: bullet names a submit request or a staging order" \
    --entries 1 "$work/req-$name.changes"
done 3<<'EOF'
stage-with|- Stage with sr#1385054 (core)
rq-glued|- Needs rq1385569 first
request-hash|- Goes with request #1385569
lands-together|- Lands together with the fcitx5 update
staged-together|- Must be staged together with libime
lands-after-pkg|- Lands after the fcitx5 5.1.23 update
EOF
while IFS='|' read -r name text <&3; do
  entry "req-ok-$name.changes" "- Update to 1.2:" "$text"
  case_ "req-ok-$name" 0 "OK: clean" --entries 1 "$work/req-ok-$name.changes"
done 3<<'EOF'
boo|  * Fix a crash on a crafted header (boo#1234567)
gh|  * Fix a crash on empty input (gh#fcitx/fcitx5#1234)
pull-request|  * Fix the parser regression from pull request #123456
merge-request|  * Revert merge request 123456, it broke the ARM build
pull-hyphen|  * Fix the regression from pull-request 123456
http|  * Faster HTTP request handling for 1000000 requests
floor|  * Build: requires fcitx5 >= 5.1.22
git-staged|  * Show the files staged with --cached
lands-with|  * The Qt6 port lands with this release
EOF
# Continuation lines join their bullet, so a wrapped "pull request" stays upstream's.
entry req-ok-pull-wrapped.changes "- Update to 1.2:" "  * Fix the regression from pull" "    request #123456"
case_ req-ok-pull-wrapped 0 "OK: clean" --entries 1 "$work/req-ok-pull-wrapped.changes"
{ printf '%s\nTue Sep 15 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Update to 1.3\n  * Fix the crash\n\n' "$SEP"
  cat "$work/req-stage-with.changes"; } > "$work/req-old.changes"
case_ req-old-entry-not-linted 0 "OK: clean" --entries 1 "$work/req-old.changes"

# Review and bot status is the SR's business too (ibus-typing-booster: "failing
# source-URL validation of the Factory forward"; swift-lang: "factory-auto
# declines otherwise").
while IFS='|' read -r name text <&3; do
  entry "rev-$name.changes" "- Update to 1.2:" "  * Fix a crash on empty input" "$text"
  case_ "rev-$name" 1 "rev-$name.changes:6: bullet reports submission or review status" \
    --entries 1 "$work/rev-$name.changes"
done 3<<'EOF'
factory-auto|- Name the patch by file: factory-auto declines otherwise
url-validation|- Drop Source1: its URL 404s, failing source-URL validation of the Factory forward
source-validator|- Reference the rpmlintrc, so source_validator passes
factory-forward|- Fix the spec for the Factory forward
EOF
while IFS='|' read -r name text <&3; do
  entry "rev-ok-$name.changes" "- Update to 1.2:" "$text"
  case_ "rev-ok-$name" 0 "OK: clean" --entries 1 "$work/rev-ok-$name.changes"
done 3<<'EOF'
input-validation|  * Add input validation to the source map parser
factory-reset|  * Fix the factory reset of the settings dialog
EOF

# A line that could have been wrapped is red; one unbreakable word is not.
entry long-line.changes "- Drop dead Source1 inscript2-20210820.tar.gz: its releases.pagure.org URL 404s, and it was only unpacked for old releases."
case_ long-line 1 "long-line.changes:4: line is 123 characters: wrap it" --entries 1 "$work/long-line.changes"
entry long-word.changes "- Add patch, which fixes the test run:" "  0001-meson-build-allow-overriding-the-default-plugin-search-path-for-tests.patch"
case_ long-word-clean 0 "OK: clean" --entries 1 "$work/long-word.changes"
# The words before an unbreakable one could have wrapped: break before it.
entry long-word-tail.changes "- Refresh the following patch for the new tree, which moved the plugin loader: 0001-meson-build-allow-overriding-the-default-plugin-search-path.patch"
case_ long-word-tail 1 "long-word-tail.changes:4: line is 149 characters: wrap it at 67" --entries 1 "$work/long-word-tail.changes"
# The width is the .changes convention's 67, not 80: a 68-column sub-bullet
# that wraps is red (sr#1392409's review caught a 69-column one by hand).
entry wrap-68.changes "- Drop obsolete patches:" "  * DevIL-1.7.8-libpng14.patch (upstream uses the current libpng 16)"
case_ wrap-68 1 "wrap-68.changes:5: line is 68 characters: wrap it at 67" --entries 1 "$work/wrap-68.changes"
entry wrap-67.changes "- Drop obsolete patches:" "  * DevIL-1.7.8-libpng14.patch (upstream uses the current libpng16)"
case_ wrap-67-clean 0 "OK: clean" --entries 1 "$work/wrap-67.changes"
# A word that cannot fit at its indentation may run over; so may an old entry.
entry wrap-word.changes "- Refresh patches:" "  * 0001-build-let-the-test-suite-find-plugins-in-the-builddir-1.patch"
case_ wrap-word-clean 0 "OK: clean" --entries 1 "$work/wrap-word.changes"
# ... but only as the line's last word: what follows it could have wrapped.
entry wrap-word-more.changes "- Add 0001-build-let-the-test-suite-find-plugins-in-the-builddir-1.patch: fix the test run"
case_ wrap-word-more 1 "wrap-word-more.changes:4: line is 90 characters: wrap it at 67" --entries 1 "$work/wrap-word-more.changes"
{ printf '%s\nTue Sep 15 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Fix the build\n\n' "$SEP"
  cat "$work/wrap-68.changes"; } > "$work/wrap-old.changes"
case_ wrap-old-entry-not-judged 0 "OK: clean" --entries 1 "$work/wrap-old.changes"

# --author: the identity osc vc writes. An entry that shares its name or its
# address must carry both (sr#1385844 shipped the git address under the name).
ME='Jane Packager <jane@suse.example>'
by() { printf '%s\nSun Oct 18 10:00:00 UTC 2026 - %s\n\n- Update to 2.0:\n  * Fix the crash\n\n' "$SEP" "$1"; cat "$F"; }
by "Jane Packager <jane@personal.example>" > "$work/au-git.changes"
case_ author-git-email 1 "is not what osc vc writes ('$ME')" --author "$ME" --entries 1 "$work/au-git.changes"
by "J. Packager <jane@suse.example>" > "$work/au-name.changes"
case_ author-other-name 1 "is not what osc vc writes" --author "$ME" --entries 1 "$work/au-name.changes"
by "Jane Packager <JANE@suse.example>" > "$work/au-case.changes"
case_ author-email-case 0 "OK: clean" --author "$ME" --entries 1 "$work/au-case.changes"
by "$ME" > "$work/au-ok.changes"
case_ author-exact 0 "OK: clean" --author "$ME" --entries 1 "$work/au-ok.changes"
by "Other Person <other@example.com>" > "$work/au-other.changes"
case_ author-other-packager 0 "OK: clean" --author "$ME" --entries 1 "$work/au-other.changes"
{ printf '%s\nMon Oct 19 10:00:00 UTC 2026 - %s\n\n- Fix the build\n\n' "$SEP" "$ME"; cat "$work/au-git.changes"; } > "$work/au-old.changes"
case_ author-old-entry-not-linted 0 "OK: clean" --author "$ME" --entries 1 "$work/au-old.changes"
case_ author-old-entry-in-scope 1 "au-old.changes:7: author" --author "$ME" --entries 2 "$work/au-old.changes"
case_ author-bad-value 2 "--author takes 'Name <email>'" --author "jane@suse.example" --entries 1 "$work/au-ok.changes"
case_ author-option-order 1 "is not what osc vc writes" --entries 1 --author "$ME" "$work/au-git.changes"

# A security claim without its CVE ids took nine fix rounds in one week: the
# tracker keys off the literal ids. An incomplete id is always a finding; a
# security claim passes with a full id, a boo#/bsc# or a GHSA id somewhere in
# its top-level bullet (sub-bullets included); "CVEs" passes only with an id.
while IFS='|' read -r name rc text <&3; do
  IFS='^' read -r -a lines <<<"$text"
  entry "sec-$name.changes" "${lines[@]}"
  if [ "$rc" = 0 ]; then
    case_ "sec-$name" 0 "OK: clean" --entries 1 "$work/sec-$name.changes"
  elif [ "$rc" = partial ]; then
    case_ "sec-$name" 1 "sec-$name.changes:4: bullet has an incomplete CVE id" --entries 1 "$work/sec-$name.changes"
  else
    case_ "sec-$name" 1 "sec-$name.changes:4: bullet claims security fixes without a full CVE id" \
      --entries 1 "$work/sec-$name.changes"
  fi
done 3<<'EOF'
cves|1|- Update to 2.0, fixes multiple CVEs
cve-word|1|- Security hardening (CVE)
security-fixes|1|- Update to 2.0:^  * Several security fixes
security-update|1|- Update to 2.0 (security update)
vulnerability|1|- Fix a vulnerability in the HTTP parser
vulnerabilities-wrapped|1|- Update to 2.0, which closes two^  vulnerabilities in the parser
placeholder|partial|- CVE-2026-XXXX: heap overflow in the parser
year-only|partial|- Fix CVE-2026 in the parser
short|partial|- CVE-2026-12: heap overflow in the parser
placeholder-beside-full|partial|- CVE-2026-1234 and CVE-2026-XXXX: overflows
full-id|0|- Update to 2.0 (security release):^  * CVE-2026-1234: heap overflow in the parser (boo#1)
cves-with-ids|0|- Security fixes for two CVEs: CVE-2026-1234,^  CVE-2026-5678
bug-ref|0|- Fix a vulnerability in the HTTP parser (boo#1284176)
ghsa|0|- Fix a vulnerability in the parser (GHSA-abcd-efgh-ijkl)
not-affected|0|- Refresh the vendored crates:^  * slab is 0.4.12, above the 0.4.11 fix
no-cve|0|- Fix a heap overflow in the parser (no CVE assigned)
hardening|0|- Build with -D_FORTIFY_SOURCE=3 for stronger hardening
security-policy|0|- Ship the upstream security policy file
patch-name|0|- Add fix-CVE-2026-54886.patch:^  * CVE-2026-54886: SFTP server loop (bsc#1270246)
no-security|0|- Rebuild for the new parser: no security fixes
non-security|0|- Backport a non-security fix for the parser
not-a-vulnerability|0|- Document why the parser crash is not a vulnerability
without|0|- Refresh the bundled data without security fixes
colon-lead|0|- Version 10.08.0 also fixes the following two security issues:^- CVE-2026-103226: stack buffer overflow (bsc#1283917)^- CVE-2026-101258: heap buffer overflow (bsc#1284397)
colon-lead-no-ids|1|- Version 2.0 also fixes the following security issues:^- Faster start-up
colon-not-last|1|- Fixes security issues: see upstream^- CVE-2026-103226: stack buffer overflow (bsc#1283917)
patch-name-vuln|0|- Add patch 0012-Fix-two-NegoEx-parsing-vulnerabilities.patch
url-security|0|- Point URL to https://example.org/security-fixes/archive
cve-pending-ghsa|0|- Update to 5.8.4:^  * Fix an invalid memory access after a failed allocation^    (GHSA-5qpq-xqfv-j9pg, CVE pending, affects all versions)
cve-pending-bug|0|- Fix an invalid memory access (boo#1284176, CVE pending)
cve-pending-alone|1|- Fix an invalid memory access (CVE pending)
EOF
# Only the entries in scope are judged: an old vague entry is history.
{ printf '%s\nMon Oct 19 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Fix the build\n\n' "$SEP"
  cat "$work/sec-cves.changes"; } > "$work/sec-old.changes"
case_ sec-old-entry-not-linted 0 "OK: clean" --entries 1 "$work/sec-old.changes"

echo "---"; [ "$fails" = 0 ] && echo "all changes-lint checks passed" || echo "$fails FAILED"
exit $((fails > 0))
