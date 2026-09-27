#!/bin/bash
# test-preflight.sh — preflight.sh offline: a fake `osc` on PATH answers from a
# per-case fixture tree (a missing fixture is a 404). The base package foo has
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
echo "osc $*" >> "$FIX/calls"
case $1 in
  whois) [ -e "$FIX/no-whois" ] && exit 1; echo 'tester: "Tester"' ;;
  develproject) echo "devel:example/$3" ;;
  api) f="$FIX/obs/$(printf %s "$2" | tr '/?&=,' '_____')"
       [ -f "$f" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
       cat "$f" ;;
  *) echo "fake osc: unexpected $*" >&2; exit 99 ;;
esac
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

# case_ <name> <expected rc> <expected message> <mutation> [preflight args after foo]
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got; shift 4
  cp -a "$B" "$dir"
  (B=$dir; cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  out="$(cd "$dir" && FIX=$dir PATH="$work/bin:$PATH" bash "$PF" foo "$@" 2>&1)"; got=$?
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

echo "---"; [ "$fails" = 0 ] && echo "all preflight checks passed" || echo "$fails FAILED"
exit $((fails > 0))
