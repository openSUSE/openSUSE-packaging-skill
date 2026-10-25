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
SWEEP='/search/request?match=action/target/@package=%27foo%27%20and%20(state/@name=%27new%27%20or%20state/@name=%27review%27)'
obs "$SWEEP" '<collection/>'

# case_ <name> <expected rc> <expected message> <mutation> [preflight args after foo]
# XPATH, when set, goes first on PATH.
XPATH=""
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got; shift 4
  cp -a "$B" "$dir"
  (B=$dir; cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  mkdir -p "$dir/tmp"
  out="$(cd "$dir" && FIX=$dir TMPDIR=$dir/tmp PATH="${XPATH:+$XPATH:}$work/bin:$PATH" bash "$PF" foo "$@" 2>&1)"; got=$?
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

# A + in a package name decodes as a space in a query string, so every
# request query must percent-encode it (libsigc++3 read as "libsigc  3"
# printed "none" while sr#1386760 was open). No fixtures exist for foo++, so
# every read 404s and the run ends PROCEED; what is asserted is the calls
# log — the URLs osc was asked for carry %2B, never a raw +.
dir="$work/pkg-plus"; cp -a "$B" "$dir"; mkdir -p "$dir/tmp"
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
case_ scm-no-prs 4 "open PRs:       none" "$SCM && echo '[]' > \$B/$PULLS"
no_curl() { ! grep -q '^curl ' "$work/$1/calls" && pass "$1: git-obs, not curl" || fail "$1: curl was called"; }
no_curl scm-no-prs
case_ scm-pr-open 3 "VERDICT: STOP - already in flight: PR #5 -> factory: Update foo to 1.2" \
  "$SCM && echo '[{\"number\": 5, \"base\": {\"ref\": \"factory\"}, \"title\": \"Update foo to 1.2\"}]' > \$B/$PULLS"
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

echo "---"; [ "$fails" = 0 ] && echo "all preflight checks passed" || echo "$fails FAILED"
exit $((fails > 0))
