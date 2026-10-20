#!/bin/bash
# test-watch-submissions.sh — the delta watcher, offline: a fake `osc` serves
# fixtures named from the API path, and answers a request search by id from
# one file per id; a fake `tea` serves the PR leg. Proves that a request that
# left the set is named with its final state under --resolve (one search call
# per 50 ids, never one per id), that a failed lookup says so instead of
# guessing, that the outgoing set is never capped (a cap turns every request
# past it into a RESOLVE line), and that a full incoming or PR page skips that
# diff rather than faking resolutions.
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
mkdir -p "$work/bin" "$FIX/req"
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
echo "osc $*" >> "$FIX/calls"
case $1 in
  whois) echo 'tester: "Tester"' ;;
  api) case $2 in
    /search/request\?match=@id=*)
      ids=$(printf %s "${2#*match=}" | sed 's/+or+/ /g; s/@id=//g')
      for id in $ids; do
        [ "$(cat "$FIX/req/$id" 2>/dev/null)" = @NET ] && { echo "Connection refused" >&2; exit 1; }
      done
      echo '<collection>'; for id in $ids; do cat "$FIX/req/$id" 2>/dev/null; done; echo '</collection>' ;;
    *) f="$FIX/$(printf %s "$2" | tr '?&=' '___')"
       [ -f "$f" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
       cat "$f" ;;
  esac ;;
  *) echo "fake osc: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat > "$work/bin/tea" <<'EOF'
#!/bin/bash
echo "tea $*" >> "$FIX/calls"
cat "$FIX/gitea.json"
EOF
chmod +x "$work/bin/osc" "$work/bin/tea"

OUT="$FIX/request_view_collection_roles_creator_user_tester_states_new,review"
IN="$FIX/request_view_collection_roles_maintainer,reviewer_user_tester_states_new,review_limit_250"
req() { # <id> <package> [creator]
  printf '<request id="%s" creator="%s"><action type="submit"><target project="openSUSE:Factory" package="%s"/></action><state name="review"/></request>\n' \
    "$1" "${3:-tester}" "$2"
}
outgoing() { { echo '<collection>'; for i in "$@"; do req "$i" "pkg$i"; done; echo '</collection>'; } > "$OUT"; }
final() { # <id> <state> <who> [superseded_by | decline comment]
  case $2 in
    superseded) printf '<request id="%s"><state name="superseded" who="%s" superseded_by="%s"/></request>\n' "$1" "$3" "$4" ;;
    declined) printf '<request id="%s"><state name="declined" who="%s"><comment>%s</comment></state></request>\n' "$1" "$3" "$4" ;;
    *) printf '<request id="%s"><state name="%s" who="%s"/></request>\n' "$1" "$2" "$3" ;;
  esac > "$FIX/req/$1"
}
echo '<collection/>' > "$IN"
echo '[]' > "$FIX/gitea.json"

PRS=(--no-prs)
run() { # <expected rc> <expected text> [args...]
  local rc=$1 msg=$2 got; shift 2
  : > "$FIX/calls"
  LAST="$(PATH="$work/bin:$PATH" bash "$W" "${PRS[@]}" --state-dir "$work/state" "$@" 2>&1)"; got=$?
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

# With --resolve each one names its final state. Third-party text is
# sanitized (C1, bidi and zero-width characters are legal in XML), and a long
# reason is cut with an ellipsis.
CSI=$'\xc2\x9b'; RLO=$'\xe2\x80\xae'; ZWSP=$'\xe2\x80\x8b'  # UTF-8 bytes: \u needs a UTF-8 locale
outgoing 104
final 103 declined dimstar "nothing provides ${CSI}31mgroup(owntone)${RLO} needed by owntone${ZWSP}, and then a very long explanation that runs well past the hundred characters kept"
run 0 'RESOLVE SR 103 pkg103: declined by dimstar: "nothing provides group(owntone) needed by owntone, and then a very long explanation that runs well…"' --resolve
[ "$(grep -c '/search/request' <<<"$CALLS")" = 1 ] && pass "--resolve: one search call" || fail "--resolve calls: $CALLS"
! grep -qF -e "$CSI" -e "$RLO" -e "$ZWSP" <<<"$LAST" && pass "--resolve: control characters stripped" || fail "--resolve: raw controls: $LAST"

outgoing 105 106 107
run 0 "NEW SR 105 pkg105 [review]"
outgoing
final 105 accepted maint; final 106 superseded tester 190; final 107 revoked tester
run 0 "RESOLVE SR 105 pkg105: accepted by maint" --resolve --allow-empty
for want in "RESOLVE SR 106 pkg106: superseded by #190" "RESOLVE SR 107 pkg107: revoked by tester"; do
  grep -qF "$want" <<<"$LAST" && pass "$want" || fail "missing '$want': $LAST"
done

# Past 50 gone ids the second call is made too, and a failure in it is said.
# shellcheck disable=SC2046  # the id list is meant to split
outgoing $(seq 300 360)
run 0 "NEW SR 300 pkg300" --allow-empty
outgoing
for i in $(seq 300 360); do final "$i" accepted maint; done
run 0 "RESOLVE SR 360 pkg360: accepted by maint" --resolve --allow-empty
[ "$(grep -c '/search/request' <<<"$CALLS")" = 2 ] && ! grep -q 'fetch final state' <<<"$LAST" \
  && pass "--resolve: 61 ids in two calls, every final state named" || fail "--resolve chunks: $CALLS"
# shellcheck disable=SC2046
outgoing $(seq 400 460)
run 0 "NEW SR 400 pkg400" --allow-empty
outgoing
for i in $(seq 400 460); do final "$i" accepted maint; done
echo @NET > "$FIX/req/460"   # the second chunk's call fails
run 0 "! --resolve lookup failed this run" --resolve --allow-empty
grep -qF "RESOLVE SR 400 pkg400 (left review; fetch final state" <<<"$LAST" \
  && pass "failed second chunk: no final state is guessed" || fail "failed second chunk: $LAST"

# A failed lookup keeps the plain line and says it failed.
outgoing 108
run 0 NEW --resolve --allow-empty
outgoing
echo @NET > "$FIX/req/108"
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

# The same for the PR leg at its 50.
PRS=()
echo '[{"number": 1, "title": "one", "repository": {"full_name": "g/r"}}]' > "$FIX/gitea.json"
run 0 "NEW PR g/r#1"
{ echo '['; for i in $(seq 2 50); do printf '{"number": %s, "title": "t", "repository": {"full_name": "g/r"}},\n' "$i"; done
  echo '{"number": 51, "title": "t", "repository": {"full_name": "g/r"}}]'; } > "$FIX/gitea.json"
run 0 "! gitea leg hit its 50 limit"
! grep -q "RESOLVE PR g/r#1" <<<"$LAST" && pass "full PR page: no RESOLVE PR" || fail "full PR page: $LAST"

echo "---"; [ "$fails" = 0 ] && echo "all watch-submissions checks passed" || echo "$fails FAILED"
exit $((fails > 0))
