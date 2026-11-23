#!/bin/bash
# test-preflight.sh — preflight.sh offline: fake `osc` and `git-obs` on PATH
# answer from a per-case fixture tree (a missing fixture is a 404), and a fake
# `curl` fails and records that it was called. The base package foo has
# devel devel:example at 1.1 against openSUSE:Factory at 1.0, nothing in
# flight, and one declined devel->Factory SR. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PF="$HERE/../skills/opensuse-packaging/scripts/preflight.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
echo "osc $*" >> "$FIX/calls"; readlink "/proc/$$/fd/2" >> "$FIX/stderr-paths"
case $1 in
  whois) [ -e "$FIX/no-whois" ] && exit 1; echo 'tester: "Tester"' ;;
  develproject) [ -e "$FIX/no-develproject" ] && exit 1; echo "devel:example/$3" ;;
  ls) [ -f "$FIX/ls/$2" ] || { echo "Server returned an error: HTTP Error 500: Internal" >&2; exit 1; }
      cat "$FIX/ls/$2" ;;
  api) f="$FIX/obs/$(printf %s "$2" | tr '/?&=,' '_____')"
       [ -f "$f" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
       [ "$(cat "$f")" = @500 ] && { echo "Server returned an error: HTTP Error 500: Internal" >&2; exit 1; }
       cat "$f" ;;
  *) echo "fake osc: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat > "$work/bin/git-obs" <<'EOF'
#!/bin/bash
echo "git-obs $*" >> "$FIX/calls"; readlink "/proc/$$/fd/2" >> "$FIX/stderr-paths"
# Only the src.opensuse.org login may answer: the default one can be another forge.
[ "$1 $2 $3 $4" = "-G src.opensuse.org -q api" ] || { echo "fake git-obs: unexpected $*" >&2; exit 99; }
echo "Response:" >&2
f="$FIX/gitea$(printf %s "$5" | tr '?&=' '___')"
[ -f "$f" ] || { echo "ERROR: 404 Not Found" >&2; exit 1; }
[ "$(cat "$f")" = @HANG ] && exec sleep 20
cat "$f"
EOF
cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$FIX/calls"
echo "curl: (7) Failed to connect" >&2; exit 7
EOF
chmod +x "$work/bin/"*

B="$work/base"
obs() { mkdir -p "$B/obs" && printf '%s\n' "$2" > "$B/obs/$(printf %s "$1" | tr '/?&=,' '_____')"; }
obs /source/devel:example/foo/foo.spec $'Name: foo\nVersion: 1.1'
obs /source/devel:example/foo/foo.changes $'-------------------------------------------------------------------\nMon Sep 14 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Update to 1.1'
obs /source/devel:example/foo/_meta '<package name="foo" project="devel:example"/>'
obs /source/devel:example/_meta '<project name="devel:example"/>'
obs /source/openSUSE:Factory/foo/foo.spec $'Name: foo\nVersion: 1.0'
obs '/request?view=collection&types=submit&states=new,review&project=devel:example&package=foo' '<collection/>'
obs '/request?view=collection&types=submit&states=new,review&project=openSUSE:Factory&package=foo' '<collection/>'
obs '/request?view=collection&types=submit&states=declined&project=openSUSE:Factory&package=foo' '<collection>
  <request id="1375013" creator="tester"><action type="submit"><source project="devel:example" package="foo"/>
  <target project="openSUSE:Factory" package="foo"/></action><state name="declined"/></request></collection>'
mkdir -p "$B/ls" && printf 'foo\npython-Authlib\npython-Authlib:test\npython-zope.interface\npython-pytest-lazy-fixtures\n' > "$B/ls/openSUSE:Factory"
SWEEP='/search/request?match=action%5B@type=%27submit%27%20and%20target/@package=%27foo%27%5D%20and%20(state/@name=%27new%27%20or%20state/@name=%27review%27)'
obs "$SWEEP" '<collection/>'

# case_ <name> <expected rc> <expected message> <mutation> [preflight args after foo]
# XPATH, when set, goes first on PATH.
XPATH=""
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got; shift 4
  cp -a "$B" "$dir"
  # shellcheck disable=SC2030  # rebinding B to the copy is the point; the parent's B stays the pristine tree
  (B=$dir; cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  mkdir -p "$dir/tmp"
  out="$(cd "$dir" && FIX=$dir HOME=$dir/home TMPDIR=$dir/tmp PATH="${XPATH:+$XPATH:}$work/bin:$PATH" bash "$PF" "${PKG:-foo}" "$@" 2>&1)"; got=$?
  LAST=$out
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}

# A declined SR is not in flight, but `osc sr` lists every open or declined
# request from the same source and prompts to supersede them all at once.
# Only your own is yours to supersede, by its id with -s (never --yes, which
# takes them all); someone else's is theirs to revoke. The FORWARD command
# never prompts: -s for your declined SR, and always -m.
FWD='run: osc sr devel:example foo openSUSE:Factory'
case_ declined-own 4 "-> 1375013 is yours: file with osc sr ... -s 1375013" ":"
# shellcheck disable=SC2016  # the backticks are the script's output, not the shell's
grep -qF "$FWD -s 1375013 -m \"<short message>\"" <<<"$LAST" && grep -qF '`osc sr` lists them as open' <<<"$LAST" \
  && ! grep -qE -- 'osc sr [^(]*--yes|will refuse' <<<"$LAST" && pass "declined-own: FORWARD names it, never prompts" \
  || fail "declined-own: $LAST"
case_ declined-foreign 4 "-> 1375013 is by someone-else, not yours to supersede: ask them to revoke it, or leave it" \
  "sed -i 's/creator=\"tester\"/creator=\"someone-else\"/' \$B/obs/*states_declined*"
! grep -qF -- "-s 1375013" <<<"$LAST" && grep -qF "$FWD -m \"<short message>\" — declined 1375013 still makes osc sr prompt" <<<"$LAST" \
  && pass "declined-foreign: no -s for someone else's SR" || fail "declined-foreign: $LAST"
case_ declined-owner-unknown 4 "could not tell which are yours" ": > \$B/no-whois"
! grep -qF -- "-s 1375013" <<<"$LAST" && pass "declined-owner-unknown: no -s" || fail "declined-owner-unknown: $LAST"
case_ declined-user-flag 4 "-> 1375013 is yours" ": > \$B/no-whois" --user tester
case_ no-declined 4 "$FWD -m \"<short message>\"" "echo '<collection/>' > \$B/obs/*states_declined*"
! grep -qF "DECLINED" <<<"$LAST" && pass "no-declined: nothing to supersede" || fail "no-declined: $LAST"

# The anchored queries are read against the devel and target projects, and
# the outgoing one is filtered to devel sources. The target-agnostic sweep
# sees the rest: an SR filed straight at the target from a non-devel source
# is in flight (STOP); one aimed at another target entirely is printed for
# the report and changes no verdict; a failed sweep is CHECK-FAILED.
case_ sweep-none 4 "sweep SRs:      none" ":"
case_ sweep-other-target 4 "SR 2000001 [review] devel:other/foo -> openSUSE:Leap:16.0 by someone-else" \
  "echo '<collection><request id=\"2000001\" creator=\"someone-else\"><action type=\"submit\"><source project=\"devel:other\" package=\"foo\"/><target project=\"openSUSE:Leap:16.0\" package=\"foo\"/></action><state name=\"review\"/></request></collection>' > \$B/obs/*search_request*"
grep -qF "VERDICT: FORWARD" <<<"$LAST" && pass "sweep-other-target: verdict unchanged" || fail "sweep-other-target: $LAST"
case_ sweep-direct-to-target 3 "VERDICT: STOP - already in flight: SR 2000002 [new] devel:other/foo -> openSUSE:Factory by someone-else" \
  "echo '<collection><request id=\"2000002\" creator=\"someone-else\"><action type=\"submit\"><source project=\"devel:other\" package=\"foo\"/><target project=\"openSUSE:Factory\" package=\"foo\"/></action><state name=\"new\"/></request></collection>' > \$B/obs/*search_request*"
case_ sweep-lookup-failed 2 "CHECK FAILED: could not query other SRs targeting foo" \
  "echo @500 > \$B/obs/*search_request*"
case_ sweep-dedup 3 "SR 2000004 [new] devel:other/foo -> openSUSE:Leap:16.0 by someone-else" \
  "echo '<collection><request id=\"2000003\" creator=\"someone-else\"><action type=\"submit\"><source project=\"devel:other\" package=\"foo\"/><target project=\"devel:example\" package=\"foo\"/></action><state name=\"new\"/></request></collection>' > \$B/obs/*states_new_review_project_devel* && echo '<collection><request id=\"2000003\" creator=\"someone-else\"><action type=\"submit\"><source project=\"devel:other\" package=\"foo\"/><target project=\"devel:example\" package=\"foo\"/></action><state name=\"new\"/></request><request id=\"2000004\" creator=\"someone-else\"><action type=\"submit\"><source project=\"devel:other\" package=\"foo\"/><target project=\"openSUSE:Leap:16.0\" package=\"foo\"/></action><state name=\"new\"/></request></collection>' > \$B/obs/*search_request*"
# SR 2000003 is named exactly twice — the incoming listing and the STOP
# verdict line quoting it; a third naming would be the sweep repeating it.
[ "$(grep -c 'SR 2000003' <<<"$LAST")" = 2 ] && pass "sweep-dedup: an SR the anchored checks listed is not repeated" || fail "sweep-dedup: $LAST"

# Only a submit request moves code: a set_bugowner or add_role request
# against the package is not an update in flight, however it is aimed
# (sr#1383747 was a set_bugowner request and read as a STOP for runc).
case_ sweep-non-submit 4 "sweep SRs:      none" \
  "echo '<collection><request id=\"2000005\" creator=\"someone-else\"><action type=\"set_bugowner\"><target project=\"openSUSE:Factory\" package=\"foo\"/><person name=\"someone-else\" role=\"bugowner\"/></action><state name=\"review\"/></request><request id=\"2000007\" creator=\"someone-else\"><action type=\"add_role\"><target project=\"devel:example\" package=\"foo\"/><person name=\"someone-else\" role=\"maintainer\"/></action><state name=\"new\"/></request></collection>' > \$B/obs/*search_request*"
! grep -qE "VERDICT: STOP|2000005|2000007" <<<"$LAST" && pass "sweep-non-submit: role requests are not in flight" || fail "sweep-non-submit: $LAST"
# A non-submit request beside a real one changes nothing either: the submit
# is reported, the role request is dropped.
case_ sweep-mixed-actions 4 "SR 2000006 [new] devel:other/foo -> openSUSE:Leap:16.0 by someone-else" \
  "echo '<collection><request id=\"2000005\" creator=\"someone-else\"><action type=\"set_bugowner\"><target project=\"openSUSE:Factory\" package=\"foo\"/><person name=\"someone-else\" role=\"bugowner\"/></action><state name=\"review\"/></request><request id=\"2000006\" creator=\"someone-else\"><action type=\"submit\"><source project=\"devel:other\" package=\"foo\"/><target project=\"openSUSE:Leap:16.0\" package=\"foo\"/></action><state name=\"new\"/></request></collection>' > \$B/obs/*search_request*"
grep -qF "VERDICT: FORWARD" <<<"$LAST" && ! grep -q "2000005" <<<"$LAST" \
  && pass "sweep-mixed-actions: only the submit is reported" || fail "sweep-mixed-actions: $LAST"

# A + in a package name decodes as a space in a query string, so every
# request query must percent-encode it (libsigc++3 read as "libsigc  3"
# printed "none" while sr#1386760 was open). No fixtures exist for foo++, so
# every read 404s and the run ends PROCEED; what is asserted is the calls
# log — the URLs osc was asked for carry %2B, never a raw +.
dir="$work/pkg-plus"
# shellcheck disable=SC2031  # B is rebound only inside the mutation subshell; here it is still the pristine tree
cp -a "$B" "$dir"; mkdir -p "$dir/tmp"
out="$(cd "$dir" && FIX=$dir TMPDIR=$dir/tmp PATH="$work/bin:$PATH" bash "$PF" 'foo++' 2>&1)"; got=$?
calls="$(cat "$dir/calls")"
[ "$got" = 0 ] && grep -qF 'package=foo%2B%2B' <<<"$calls" && grep -qF 'target/@package=%27foo%2B%2B%27' <<<"$calls" \
  && ! grep -qE 'package=foo\+\+|%27foo\+\+' <<<"$calls" \
  && pass "pkg-plus: + percent-encoded in every request query" \
  || { fail "pkg-plus: expected rc=0 and %2B-encoded queries, got rc=$got"; printf '%s\n' "$calls" | sed 's/^/    /'; }

# A git devel project's in-flight update is a PR on src.opensuse.org, read
# through git-obs pinned to that login. A failed or unreadable read is
# CHECK-FAILED, never "open PRs: none".
SCM="echo '<project name=\"devel:example\"><scmsync>https://src.opensuse.org/example/_ObsPrj</scmsync></project>' \
  > \$B/obs/_source_devel:example__meta && mkdir -p \$B/gitea/repos/example/foo"
PULLS='gitea/repos/example/foo/pulls_state_open'
# A PR's head: the one it has now, and an older one a review may have been of.
HEAD1=1111111111111111111111111111111111111111; HEAD0=0000000000000000000000000000000000000000
HD="\"head\": {\"sha\": \"$HEAD1\"}"
case_ scm-no-prs 4 "open PRs:       none" "$SCM && echo '[]' > \$B/$PULLS"
no_curl() { ! grep -q '^curl ' "$work/$1/calls" && pass "$1: git-obs, not curl" || fail "$1: curl was called"; }
no_curl scm-no-prs
case_ scm-pr-open 3 "VERDICT: STOP - already in flight: PR #5 -> factory: Update foo to 1.2" \
  "$SCM && echo '[{\"number\": 5, \"base\": {\"ref\": \"factory\"}, $HD, \"title\": \"Update foo to 1.2\", \"user\": {\"login\": \"tester\"}}]' > \$B/$PULLS"
! grep -qF "$HEAD1" <<<"$LAST" && pass "scm-pr-open: the head is not shown" || fail "scm-pr-open: $LAST"
case_ scm-pr-lookup-failed 2 "CHECK FAILED: could not query open PRs on example/foo: ERROR: 404 Not Found" "$SCM"
grep -qF "VERDICT: CHECK-FAILED" <<<"$LAST" && ! grep -qF "open PRs:       none" <<<"$LAST" \
  && pass "scm-pr-lookup-failed: not read as none" || fail "scm-pr-lookup-failed: $LAST"
case_ scm-pr-unparsable 2 "unparseable PR list for example/foo" "$SCM && echo '<html>' > \$B/$PULLS"
case_ scm-pr-empty-answer 2 "unparseable PR list for example/foo" "$SCM && : > \$B/$PULLS"
# Captured stderr goes to a mktemp file under $TMPDIR, never a predictable
# /tmp path another user could plant first.
paths="$(cat "$work/scm-no-prs/stderr-paths")"
grep -q "^$work/scm-no-prs/tmp/" <<<"$paths" && ! grep -q '^/tmp/preflight\.' <<<"$paths" \
  && pass "stderr captured under \$TMPDIR" || fail "stderr capture paths: $paths"
left="$(find "$work/scm-no-prs/tmp" "$work/scm-pr-lookup-failed/tmp" -type f)"
[ -z "$left" ] && pass "the capture file is removed, on CHECK-FAILED too" || fail "left behind: $left"
# A git-obs read that never answers is cut off and CHECK-FAILED. A stand-in
# `timeout` gives the real one 2s whatever the script asks for.
mkdir -p "$work/tbin"
printf '#!/bin/bash\nshift\nexec %q 2 "$@"\n' "$(command -v timeout)" > "$work/tbin/timeout" && chmod +x "$work/tbin/timeout"
XPATH="$work/tbin"
case_ scm-pr-hang 2 "CHECK FAILED: could not query open PRs on example/foo: git-obs timed out after 30s" \
  "$SCM && echo @HANG > \$B/$PULLS"
XPATH=""
! grep -qF "open PRs:       none" <<<"$LAST" && pass "scm-pr-hang: not read as none" || fail "scm-pr-hang: $LAST"
case_ scm-pr-no-author 2 "unparseable PR list for example/foo" \
  "$SCM && echo '[{\"number\": 5, \"base\": {\"ref\": \"factory\"}, $HD, \"title\": \"Update foo to 1.2\"}]' > \$B/$PULLS"
# Without a head nobody can tell whether a review is still of the PR.
case_ scm-pr-no-head 2 "unparseable PR list for example/foo" \
  "$SCM && echo '[{\"number\": 5, \"base\": {\"ref\": \"factory\"}, \"title\": \"Update foo to 1.2\", \"user\": {\"login\": \"tester\"}}]' > \$B/$PULLS"

# A contributor's open SR or devel PR on a package you maintain is reviewed
# before your update: INCOMING (5), each item annotated from its review stamp,
# a BLOCK one too, as it still waits. Your own request in flight still STOPs
# (3), a failed check still beats both (2), and an incoming item beats a
# stranded update (4). Someone else's forward to the target is in flight, not
# yours to review, and so is a contributor's SR on a package you do not
# maintain. The stamps sit under the suite's HOME, the state directory read
# from a fixture: pr-guard reads this suite.
STAMPS="home/$(cat "$HERE/fixtures/gate/state-dir")/incoming"
# shellcheck disable=SC2031,SC2317  # called by case_'s mutations, where B is the case's copy
stamp() { mkdir -p "$B/$STAMPS/$1" && printf '%s\n' "$3" > "$B/$STAMPS/$1/$2.json"; }
INQ="\$B/obs/*states_new_review_project_devel*"
MAINT="echo '<package name=\"foo\" project=\"devel:example\"><person userid=\"tester\" role=\"maintainer\"/></package>' > \$B/obs/_source_devel:example_foo__meta"
SR_C='<request id="2000010" creator="someone-else"><action type="submit"><source project="devel:other" package="foo"/><target project="devel:example" package="foo"/></action><state name="review"/></request>'
SR_OWN='<request id="2000011" creator="tester"><action type="submit"><source project="devel:other" package="foo"/><target project="devel:example" package="foo"/></action><state name="new"/></request>'
SR_FWD='<request id="2000012" creator="someone-else"><action type="submit"><source project="devel:example" package="foo"/><target project="openSUSE:Factory" package="foo"/></action><state name="new"/></request>'
CONTRIB="echo '<collection>$SR_C</collection>' > $INQ"
case_ incoming-only 5 "VERDICT: INCOMING" "$MAINT && $CONTRIB" 1.2
grep -qF "sr#2000010 by someone-else: not reviewed" <<<"$LAST" && pass "incoming-only: the item and its creator" || fail "incoming-only: $LAST"
case_ own-and-incoming 3 "VERDICT: STOP - already in flight: SR 2000011 [new] devel:other/foo -> devel:example by tester" \
  "$MAINT && echo '<collection>$SR_C$SR_OWN</collection>' > $INQ"
grep -qF "sr#2000010 by someone-else: not reviewed" <<<"$LAST" && pass "own-and-incoming: the contributor's SR is listed" || fail "own-and-incoming: $LAST"
PR_C="$SCM && mkdir -p \$B/gitea/repos/example/_ObsPrj/raw && echo '{\"foo\": [\"tester\"]}' > \$B/gitea/repos/example/_ObsPrj/raw/_maintainership.json \
   && echo '[{\"number\": 5, \"base\": {\"ref\": \"factory\"}, $HD, \"title\": \"Update foo to 1.2\", \"user\": {\"login\": \"someone-else\"}}]' > \$B/$PULLS"
case_ incoming-pr 5 "example/foo#5 by someone-else: not reviewed" "$PR_C"
grep -qF "VERDICT: INCOMING" <<<"$LAST" && pass "incoming-pr: INCOMING" || fail "incoming-pr: $LAST"
case_ others-forward 3 "VERDICT: STOP - already in flight: SR 2000012 [new] devel:example/foo -> openSUSE:Factory by someone-else" \
  "$MAINT && echo '<collection>$SR_FWD</collection>' > $INQ && echo '<collection>$SR_FWD</collection>' > \$B/obs/*states_new_review_project_openSUSE*"
! grep -qF "sr#2000012" <<<"$LAST" && pass "others-forward: a forward is no contributor's submission" || fail "others-forward: $LAST"
case_ incoming-and-ahead 5 "VERDICT: INCOMING" "$MAINT && $CONTRIB"
# After the review: what devel already has is on the verdict line, so nobody
# repackages it.
grep -qF "after it: devel already has a newer version than openSUSE:Factory, forward it, do not repackage" <<<"$LAST" \
  && pass "incoming-and-ahead: says devel already has it" || fail "incoming-and-ahead: $LAST"
case_ incoming-landed 5 "after it: nothing to package, devel:example and openSUSE:Factory are both at 1.1" \
  "$MAINT && $CONTRIB && printf 'Name: foo\nVersion: 1.1\n' > \$B/obs/_source_openSUSE:Factory_foo_foo.spec" 1.1
case_ incoming-not-mine 3 "VERDICT: STOP - already in flight: SR 2000010" "$CONTRIB"
# A contributor's request that submits to devel and to the target is in flight
# at the target, whichever action comes first: the sweep keeps its target
# action, though the devel one is listed as incoming.
A_DEV='<action type="submit"><source project="devel:other" package="foo"/><target project="devel:example" package="foo"/></action>'
A_TGT='<action type="submit"><source project="devel:other" package="foo"/><target project="openSUSE:Factory" package="foo"/></action>'
for order in "$A_DEV$A_TGT" "$A_TGT$A_DEV"; do
  sr="<collection><request id=\"2000014\" creator=\"someone-else\">$order<state name=\"new\"/></request></collection>"
  case_ "incoming-and-target-$([ "$order" = "$A_DEV$A_TGT" ] && echo devel-first || echo target-first)" 3 \
    "VERDICT: STOP - already in flight: SR 2000014 [new] devel:other/foo -> openSUSE:Factory by someone-else" \
    "$MAINT && echo '$sr' > $INQ && echo '$sr' > \$B/obs/*search_request*"
done
# Your own PR in flight beats a contributor's.
case_ own-pr-and-incoming 3 "VERDICT: STOP - already in flight: PR #6 -> factory: My update (None) by tester" \
  "$SCM && mkdir -p \$B/gitea/repos/example/_ObsPrj/raw && echo '{\"foo\": [\"tester\"]}' > \$B/gitea/repos/example/_ObsPrj/raw/_maintainership.json \
   && echo '[{\"number\": 5, \"base\": {\"ref\": \"factory\"}, $HD, \"title\": \"Update foo\", \"user\": {\"login\": \"someone-else\"}},
             {\"number\": 6, \"base\": {\"ref\": \"factory\"}, $HD, \"title\": \"My update\", \"user\": {\"login\": \"tester\"}}]' > \$B/$PULLS"
# Who maintains it is no answer when the lookup crashed, came back empty or
# does not parse: CHECK-FAILED, never "not yours".
case_ maintainer-deep-json 2 "CHECK FAILED: could not tell whether you maintain devel:example/foo" \
  "$SCM && mkdir -p \$B/gitea/repos/example/_ObsPrj/raw && printf '%*s' 100000 '' | tr ' ' '[' > \$B/gitea/repos/example/_ObsPrj/raw/_maintainership.json \
   && echo '[{\"number\": 5, \"base\": {\"ref\": \"factory\"}, $HD, \"title\": \"Update foo\", \"user\": {\"login\": \"someone-else\"}}]' > \$B/$PULLS"
case_ maintainer-empty-answer 2 "CHECK FAILED: could not tell whether you maintain devel:example/foo" \
  "$CONTRIB && : > \$B/obs/_source_devel:example_foo__meta"
case_ incoming-no-creator 2 "unparseable SR collection (incoming)" "$MAINT && echo '<collection>${SR_C/ creator=\"someone-else\"/}</collection>' > $INQ"
case_ check-failed-wins 2 "CHECK FAILED: could not tell whether you maintain devel:example/foo" \
  "echo '<collection>$SR_C$SR_OWN</collection>' > $INQ && echo @500 > \$B/obs/_source_devel:example_foo__meta"
case_ incoming-owner-unknown 2 "CHECK FAILED: could not tell whose requests are open" "$MAINT && $CONTRIB && : > \$B/no-whois"
case_ incoming-empty-answer 2 "unparseable SR collection (incoming)" ": > $INQ"
case_ incoming-second-action 5 "sr#2000013 by someone-else: not reviewed" \
  "$MAINT && echo '<collection><request id=\"2000013\" creator=\"someone-else\"><action type=\"set_bugowner\"><target project=\"devel:example\" package=\"foo\"/><person name=\"someone-else\" role=\"bugowner\"/></action><action type=\"submit\"><source project=\"devel:other\" package=\"foo\"/><target project=\"devel:example\" package=\"foo\"/></action><state name=\"new\"/></request></collection>' > $INQ"
K64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
st_() { printf '{"v": 1, "kind": "%s", "id": "%s", "verdict": "BLOCK", "key": "%s"}' "$@"; }
case_ incoming-blocked-stamp 5 "sr#2000010 by someone-else: reviewed: BLOCK (key $K64)" \
  "$MAINT && $CONTRIB && stamp obs 2000010 '$(st_ obs 2000010 "$K64")'"
case_ incoming-bad-stamp 5 "sr#2000010 by someone-else: not reviewed" "$MAINT && $CONTRIB && stamp obs 2000010 '{\"v\": 1, \"verdict\": '"
# Only a stamp of this submission with a full key counts: one naming another
# request, or with the old 12-hex key, is not a review of it.
case_ incoming-stamp-other-sr 5 "sr#2000010 by someone-else: not reviewed" \
  "$MAINT && $CONTRIB && stamp obs 2000010 '$(st_ obs 2000099 "$K64")'"
case_ incoming-stamp-short-key 5 "sr#2000010 by someone-else: not reviewed" \
  "$MAINT && $CONTRIB && stamp obs 2000010 '$(st_ obs 2000010 0123456789ab)'"
# A PR's review counts at the head it was recorded at: one of another head is
# reviewed again, and a stamp that names no head is no review.
stg_() { printf '{"v": 1, "kind": "gitea", "id": "%s", "verdict": "BLOCK", "key": "%s", "gitea": {"head": "%s"}}' "$@"; }
case_ incoming-pr-reviewed 5 "example/foo#5 by someone-else: reviewed: BLOCK (key $K64)" \
  "$PR_C && stamp gitea example_foo_5 '$(stg_ example/foo#5 "$K64" "$HEAD1")'"
case_ incoming-pr-older-head 5 "example/foo#5 by someone-else: reviewed at an older head: review again" \
  "$PR_C && stamp gitea example_foo_5 '$(stg_ example/foo#5 "$K64" "$HEAD0")'"
! grep -qF "reviewed: BLOCK" <<<"$LAST" && pass "incoming-pr-older-head: not counted as reviewed" || fail "incoming-pr-older-head: $LAST"
# A SHA-256 repository's head is 64 hex.
HEAD64=2222222222222222222222222222222222222222222222222222222222222222
case_ incoming-pr-sha256 5 "example/foo#5 by someone-else: reviewed: BLOCK (key $K64)" \
  "${PR_C//$HEAD1/$HEAD64} && stamp gitea example_foo_5 '$(stg_ example/foo#5 "$K64" "$HEAD64")'"
case_ incoming-pr-stamp-no-head 5 "example/foo#5 by someone-else: not reviewed" \
  "$PR_C && stamp gitea example_foo_5 '$(st_ gitea example/foo#5 "$K64")'"
# A PR's stamp is <owner>_<repo>_<N>.json, owner and repo lowercased and each
# % and _ escaped (%25, %5F), as incoming-review.sh writes it.
B="$work/stamp-gitea" stamp gitea 'ex%5Fample_my%5Fpkg_5' "$(stg_ 'Ex_ample/My_Pkg#5' "$K64" "$HEAD1")"
INC="$HERE/../skills/opensuse-packaging/scripts/_incoming.py"
out="$(HOME="$work/stamp-gitea/home" python3 -I -B "$INC" stamp 'Ex_ample/My_Pkg#5' "$HEAD1" 2>&1)"
[ "$out" = "reviewed: BLOCK (key $K64)" ] && pass "stamp-gitea-name: lowercased and escaped" || fail "stamp-gitea-name: $out"
# A PR item needs the head it has now, and a request takes none.
HOME="$work/stamp-gitea/home" python3 -I -B "$INC" stamp 'Ex_ample/My_Pkg#5' > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "stamp-pr-no-head: exit 2" || fail "stamp-pr-no-head: exit $rc"
HOME="$work/stamp-gitea/home" python3 -I -B "$INC" stamp sr#2000010 "$HEAD1" > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "stamp-sr-head: exit 2" || fail "stamp-sr-head: exit $rc"

# _incoming.maintains() mirrors _pr_guard.maintains(): both judge each case
# from the same answers (the guard's offline stand-ins, a fake run for ours).
out="$(python3 -I -B - "$HERE/../skills/opensuse-packaging/scripts" "$work/parity" 2>&1 <<'PY'
import json
import os
import subprocess
import sys

scripts, root = sys.argv[1:3]
sys.path.insert(0, scripts)
import _incoming  # noqa: E402

os.environ["PR_GUARD_OBS_USER"] = "tester"
guard = {"__name__": "_pr_guard", "__file__": scripts + "/_pr_guard.py"}
exec(compile(open(guard["__file__"]).read(), guard["__file__"], "exec"), guard)
me, other = '<person userid="tester" role="maintainer"/>', '<person userid="other" role="maintainer"/>'
grp, scm = '<group groupid="t" role="maintainer"/>', "<scmsync>https://src.opensuse.org/o/P#main</scmsync>"
cases = [  # package _meta (None: absent), project _meta, _maintainership.json (None: absent)
    (me, "", None), (other, me, None), (grp, me, None), (grp + me, "", None), ("", me, None),
    ("", other, None), (None, me, None), ("", scm, {"foo": ["tester"]}), ("", scm, {"": ["tester"]}),
    ("", scm, {"foo": ["other"], "": ["tester"]}), ("", scm, {"foo": [], "": ["tester"]}),
    (me, scm, {"": ["other"]}), ("", scm, None),
]
bad = []
for n, (pkg, prj, git) in enumerate(cases):
    ans = {"/source/d:p/_meta": f'<project name="d:p">{prj}</project>'}
    if pkg is not None:
        ans["/source/d:p/foo/_meta"] = f'<package name="foo">{pkg}</package>'
    if git is not None:
        ans["/repos/o/P/raw/_maintainership.json?ref=main"] = json.dumps(git)
    d = f"{root}/{n}"  # PR_GUARD_META_DIR/api/<path, /?&= as _>, PR_GUARD_GITEA_DIR/<path, / as _>
    os.makedirs(f"{d}/api")
    os.environ.update(PR_GUARD_META_DIR=d, PR_GUARD_GITEA_DIR=d)
    for p, text in ans.items():
        name = f"api/{p.translate(str.maketrans('/?&=', '____'))}" if p[:2] == "/s" else p[1:].replace("/", "_")
        with open(f"{d}/{name}", "w") as fh:
            fh.write(text)

    def fake(cmd):
        p = cmd[-1]
        if p in ans:
            return subprocess.CompletedProcess(cmd, 0, ans[p], "")
        return subprocess.CompletedProcess(cmd, 1, "", "HTTP Error 404 | ERROR: 404 Not Found")

    want = guard["maintains"]("d:p", "foo", guard["Ctx"]("/"))[0]
    if _incoming.maintains("tester", "d:p", "foo", fake)[0] != want:
        bad.append(f"case {n}: the guard says {want}")
print(f"{len(cases)} cases" if not bad else "; ".join(bad))
sys.exit(1 if bad else 0)
PY
)"; rc=$?
[ "$rc" = 0 ] && pass "maintainer-rule-matches-guard ($out)" || fail "maintainer-rule-matches-guard: $out"

# The version slot takes a version: a project name there compared as one and
# printed PROCEED (seen twice with `preflight.sh <pkg> <project>`).
case_ version-is-project 2 "'devel:languages:python' is not a version" ":" devel:languages:python
case_ version-no-digit 2 "'hardware' is not a version" ":" hardware
case_ version-ok 4 "VERDICT: FORWARD" ":" 1.1
# --from: the project about to be branched must be where the package is
# developed, or what the devel package links to (sr#1392134 branched
# hardware's stale copy of a devel:languages:python package).
case_ from-wrong 3 "VERDICT: STOP - wrong branch source: foo is developed in devel:example, not hardware" ":" --from hardware
grep -qF "osc branch devel:example foo" <<<"$LAST" && pass "from-wrong: names the branch to make" || fail "from-wrong: $LAST"
case_ from-devel 4 "branch source:  devel:example (the devel project)" ":" --from devel:example
case_ from-link-target 4 "branch source:  hardware (devel:example/foo links to it)" \
  "echo '<link project=\"hardware\" package=\"foo\"/>' > \$B/obs/_source_devel:example_foo__link" --from hardware
case_ from-link-elsewhere 3 "wrong branch source" \
  "echo '<link project=\"science\" package=\"foo\"/>' > \$B/obs/_source_devel:example_foo__link" --from hardware
case_ from-link-unreadable 2 "CHECK FAILED: could not read devel:example/foo/_link" \
  "echo @500 > \$B/obs/_source_devel:example_foo__link" --from hardware

# osc develproject failing is no "no devel project": when _meta names one, the
# lookup failed, and --from must not PROCEED against nothing.
case_ develproject-failed 2 "osc develproject failed, but openSUSE:Factory/foo/_meta names a devel project" \
  ": > \$B/no-develproject && echo '<package name=\"foo\"><devel project=\"devel:example\"/></package>' > \$B/obs/_source_openSUSE:Factory_foo__meta" \
  --from hardware
! grep -q "^VERDICT: PROCEED" <<<"$LAST" && pass "develproject-failed: no PROCEED" || fail "develproject-failed: $LAST"
case_ no-devel-set 0 "in openSUSE:Factory but no devel project set" \
  ": > \$B/no-develproject && echo '<package name=\"foo\"/>' > \$B/obs/_source_openSUSE:Factory_foo__meta" --from hardware

# A name Factory lacks may be one it has under another spelling: case
# (python-authlib was filed while Factory ships python-Authlib), -, _ and .,
# or a python3-/python3XX- flavour prefix, as python3dist() names it. Each is
# a STOP; a failed listing is CHECK-FAILED, never a new package.
NEW=": > \$B/no-develproject"
PKG=python-authlib case_ near-case 3 "VERDICT: STOP - not in openSUSE:Factory as python-authlib, but it has python-Authlib" "$NEW"
! grep -qF "python-Authlib:test" <<<"$LAST" && pass "near-case: a multibuild flavour is no package" || fail "near-case: $LAST"
PKG=python-zope_interface case_ near-separators 3 "but it has python-zope.interface" "$NEW"
PKG=python3-pytest-lazy-fixtures case_ near-flavour 3 "but it has python-pytest-lazy-fixtures" "$NEW"
PKG=python-brand-new case_ near-none 0 "VERDICT: PROCEED (new package" "$NEW"
PKG=python-brand-new case_ near-list-failed 2 "CHECK FAILED" "$NEW && rm \$B/ls/openSUSE:Factory"
! grep -q "^VERDICT: PROCEED" <<<"$LAST" && pass "near-list-failed: no PROCEED" || fail "near-list-failed: $LAST"
# A new package someone already submitted to the target is in flight, not one
# to package from scratch.
PKG=python-brand-new case_ new-package-in-flight 3 "VERDICT: STOP - already in flight: SR 2000020 [new] devel:other/python-brand-new -> openSUSE:Factory by someone-else" \
  "$NEW && echo '<collection><request id=\"2000020\" creator=\"someone-else\"><action type=\"submit\"><source project=\"devel:other\" package=\"python-brand-new\"/><target project=\"openSUSE:Factory\" package=\"python-brand-new\"/></action><state name=\"new\"/></request></collection>' > \$B/obs/_request_view_collection_types_submit_states_new_review_project_openSUSE:Factory_package_python-brand-new"
# devel-of.sh: the same lookup, its own exit 6.
DEVEL_OF="$HERE/../skills/opensuse-packaging/scripts/devel-of.sh"
devel_of_() { # <name> <rc> <expected> <pkg> [mutation]
  local dir="$work/do-$1"
  # shellcheck disable=SC2031  # B is rebound only inside the mutation subshells
  cp -a "$B" "$dir"; : > "$dir/no-develproject"
  # shellcheck disable=SC2030  # rebound in a subshell on purpose, as case_ does
  [ -z "${5:-}" ] || (B=$dir; cd "$dir" && eval "$5")
  out="$(FIX=$dir PATH="$work/bin:$PATH" bash "$DEVEL_OF" "$4" 2>&1)"; got=$?
  [ "$got" = "$2" ] && grep -qF -- "$3" <<<"$out" && pass "devel-of $1 (rc=$2)" \
    || { fail "devel-of $1: expected rc=$2 and '$3', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
devel_of_ near 6 "NOT IN openSUSE:Factory as python-authlib, but it has python-Authlib" python-authlib
devel_of_ new 3 "NOT IN openSUSE:Factory (new package?)" python-brand-new
devel_of_ list-failed 5 "cannot list openSUSE:Factory" python-brand-new "rm \$B/ls/openSUSE:Factory"

echo "---"; [ "$fails" = 0 ] && echo "all preflight checks passed" || echo "$fails FAILED"
exit $((fails > 0))
