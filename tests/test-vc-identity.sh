#!/bin/bash
# test-vc-identity.sh — vc-identity.sh prints the author a bare `osc vc` writes,
# taken from the header osc vc itself puts into a scratch .changes; anything
# else is exit 3, never a guess (the git identity once filled that gap:
# sr#1385844). A fake osc stands in for osc vc. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
VCID="$HERE/../skills/opensuse-packaging/scripts/vc-identity.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export TMPDIR="$work"
mkdir -p "$work/bin"
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
[ "$1 $2 $3" = "vc -m probe" ] && [ -n "$4" ] || { echo "fake osc: unexpected $*" >&2; exit 9; }
case "$VC_MODE" in
  ok) printf -- '-------------------------------------------------------------------\nSun Oct 18 12:16:26 UTC 2026 - Jane Packager <jane@suse.example>\n\n- probe\n\n' > "$4" ;;
  fail) echo "Server returned an error: HTTP Error 401: Unauthorized" >&2; exit 1 ;;
  garbled) printf 'probe\n' > "$4" ;;
  bare) printf -- '-------------------------------------------------------------------\nSun Oct 18 12:16:26 UTC 2026 - jane@suse.example\n\n- probe\n\n' > "$4" ;;
esac
EOF
chmod +x "$work/bin/osc"

# case_ <name> <VC_MODE> <expected rc> <expected output>
case_() {
  local out got
  out="$(VC_MODE=$2 PATH="$work/bin:$PATH" bash "$VCID" 2>&1)"; got=$?
  [ "$got" = "$3" ] && grep -qF -- "$4" <<<"$out" && pass "$1 (rc=$3)" || {
    fail "$1: expected rc=$3 and '$4', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
case_ vc-header ok 0 "Jane Packager <jane@suse.example>"
out="$(VC_MODE=ok PATH="$work/bin:$PATH" bash "$VCID" 2>/dev/null)"
[ "$out" = "Jane Packager <jane@suse.example>" ] && pass "vc-header: prints only the identity" \
  || fail "vc-header: printed '$out'"
case_ osc-fails fail 3 "osc vc failed: Server returned an error: HTTP Error 401"
case_ no-header garbled 3 "osc vc wrote no"
case_ bare-email bare 3 "osc vc wrote no"
[ -z "$(find "$work" -mindepth 1 -maxdepth 1 -name 'vc-identity.*')" ] && pass "scratch dir removed" \
  || fail "scratch dir left behind"

echo "---"; [ "$fails" = 0 ] && echo "all vc-identity checks passed" || echo "$fails FAILED"
exit $((fails > 0))
