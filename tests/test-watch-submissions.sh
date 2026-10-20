#!/bin/bash
# test-watch-submissions.sh — the delta watcher, offline: a fake `osc` serves
# fixtures named from the API path. Proves that a request that left the set is
# named with its final state under --resolve (one search call, never one per
# id), that a failed lookup says so instead of guessing, that the outgoing set
# is never capped (a cap turns every request past it into a RESOLVE line), and
# that a full incoming page skips the diff rather than faking resolutions.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass || fail`: pass and fail both return 0
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
W="$REPO/skills/opensuse-packaging/scripts/watch-submissions.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
FIX="$work/fix"; export FIX
mkdir -p "$work/bin" "$FIX/search"
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
echo "osc $*" >> "$FIX/calls"
case $1 in
  whois) echo 'tester: "Tester"' ;;
  api) f="$FIX/$(printf %s "$2" | tr '?&=' '___')"
       [ -f "$f" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
       cat "$f" ;;
  *) echo "fake osc: unexpected $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/osc"

OUT="$FIX/request_view_collection_roles_creator_user_tester_states_new,review"
IN="$FIX/request_view_collection_roles_maintainer,reviewer_user_tester_states_new,review_limit_250"
req() { # <id> <package> [creator]
  printf '<request id="%s" creator="%s"><action type="submit"><target project="openSUSE:Factory" package="%s"/></action><state name="review"/></request>\n' \
    "$1" "${3:-tester}" "$2"
}
outgoing() { { echo '<collection>'; for i in "$@"; do req "$i" "pkg$i"; done; echo '</collection>'; } > "$OUT"; }
echo '<collection/>' > "$IN"

run() { # <expected rc> <expected text> [args...]
  local rc=$1 msg=$2 got; shift 2
  : > "$FIX/calls"
  LAST="$(PATH="$work/bin:$PATH" bash "$W" --no-prs --state-dir "$work/state" "$@" 2>&1)"; got=$?
  CALLS=$(cat "$FIX/calls")
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$LAST" && pass "$msg (rc=$rc)" || {
    fail "expected rc=$rc and '$msg', got rc=$got"; printf '%s\n' "$LAST" | sed 's/^/    /'; }
}

outgoing 101 102 103 104
run 0 BASELINE-INIT
grep -F 'states=new,review' <<<"$CALLS" | grep -q 'roles=creator' && ! grep 'roles=creator' <<<"$CALLS" | grep -q limit= \
  && pass "the outgoing query carries no limit" || fail "outgoing query: $CALLS"
run 0 NOCHANGE

# 101 and 102 left; without --resolve the line asks the caller to look.
outgoing 103 104
run 0 "RESOLVE SR 101 pkg101 (left review; fetch final state"

# With --resolve each one names its final state, from one search call.
outgoing 104
{ echo '<collection>'
  echo '<request id="103"><state name="declined" who="dimstar"><comment>nothing provides group(owntone)</comment></state></request>'
  echo '</collection>'; } > "$FIX/search/request_match_@id_103"
run 0 'RESOLVE SR 103 pkg103: declined by dimstar: "nothing provides group(owntone)"' --resolve
[ "$(grep -c '/search/request' <<<"$CALLS")" = 1 ] && pass "--resolve: one search call" || fail "--resolve calls: $CALLS"

outgoing 105 106 107
run 0 "NEW SR 105 pkg105 [review]"
outgoing
cat > "$FIX/search/request_match_@id_105+or+@id_106+or+@id_107" <<'EOF'
<collection>
<request id="105"><state name="accepted" who="maint"/></request>
<request id="106"><state name="superseded" who="tester" superseded_by="190"/></request>
<request id="107"><state name="revoked" who="tester"/></request>
</collection>
EOF
run 0 "RESOLVE SR 105 pkg105: accepted by maint" --resolve --allow-empty
for want in "RESOLVE SR 106 pkg106: superseded by #190" "RESOLVE SR 107 pkg107: revoked by tester"; do
  grep -qF "$want" <<<"$LAST" && pass "$want" || fail "missing '$want': $LAST"
done

# A failed lookup keeps the plain line and says it failed.
outgoing 108
run 0 NEW --resolve --allow-empty
outgoing
run 0 "! --resolve lookup failed this run" --resolve --allow-empty
grep -qF "RESOLVE SR 108 pkg108 (left review; fetch final state" <<<"$LAST" \
  && pass "failed lookup: the plain RESOLVE line stays" || fail "failed lookup: $LAST"

# A full incoming page may be cut: no diff, no RESOLVE INCOMING, baseline kept.
outgoing 109
{ echo '<collection>'; req 900 inpkg someone; echo '</collection>'; } > "$IN"
run 0 NEW
{ echo '<collection>'; for i in $(seq 1000 1249); do req "$i" "in$i" someone; done; echo '</collection>'; } > "$IN"
run 0 "! incoming leg hit its 250 limit"
! grep -q "RESOLVE INCOMING" <<<"$LAST" && pass "full incoming page: no RESOLVE INCOMING" || fail "full page: $LAST"
{ echo '<collection>'; req 900 inpkg someone; echo '</collection>'; } > "$IN"
run 0 NOCHANGE
! grep -q "NEW INCOMING" <<<"$LAST" && pass "full incoming page: the baseline was kept" || fail "baseline after full page: $LAST"

echo "---"; [ "$fails" = 0 ] && echo "all watch-submissions checks passed" || echo "$fails FAILED"
exit $((fails > 0))
