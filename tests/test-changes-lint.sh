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

# A line osc vc would have wrapped is red; one unbreakable word is not.
entry long-line.changes "- Drop dead Source1 inscript2-20210820.tar.gz: its releases.pagure.org URL 404s, and it was only unpacked for old releases."
case_ long-line 1 "long-line.changes:4: line is 123 characters: wrap it" --entries 1 "$work/long-line.changes"
entry long-word.changes "- Add 0001-meson-build-allow-overriding-the-default-plugin-search-path-for-tests.patch:" "  fix the test run"
case_ long-word-clean 0 "OK: clean" --entries 1 "$work/long-word.changes"

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
not-affected|0|- Refresh the vendored crates:^  * CVE-2025-55159 (boo#1248048): slab is 0.4.12, above the 0.4.11 fix
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
EOF
# Only the entries in scope are judged: an old vague entry is history.
{ printf '%s\nMon Oct 19 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Fix the build\n\n' "$SEP"
  cat "$work/sec-cves.changes"; } > "$work/sec-old.changes"
case_ sec-old-entry-not-linted 0 "OK: clean" --entries 1 "$work/sec-old.changes"

echo "---"; [ "$fails" = 0 ] && echo "all changes-lint checks passed" || echo "$fails FAILED"
exit $((fails > 0))
