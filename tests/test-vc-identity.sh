#!/bin/bash
# test-vc-identity.sh — vc-identity.sh prints the author a bare `geectl
# changelog generate` writes, from the OBS account's own record
# (`geectl remote whois $GEECTL_OBS_USERNAME`); anything else is exit 3,
# never a guess (the git identity once filled that gap: sr#1385844).
# A fake geectl stands in for remote whois. Exit 0 = all assertions hold.
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
cat > "$work/bin/geectl" <<'EOF'
#!/bin/bash
[ "$1" = remote ] && [ "$2" = whois ] && [ -n "$3" ] || { echo "fake geectl: unexpected $*" >&2; exit 9; }
case "$WHOIS_MODE" in
  ok) printf '%s' '{"login": "jane", "realname": "Jane Packager", "email": "jane@suse.example", "state": "confirmed"}' ;;
  fail) echo '{"error":{"code":"auth_failed","context":"401 Unauthorized"}}' >&2; exit 1 ;;
  garbled) printf 'probe\n' ;;
  noemail) printf '%s' '{"login": "jane", "realname": "Jane Packager", "email": "", "state": "confirmed"}' ;;
  norealname) printf '%s' '{"login": "jane", "realname": "", "email": "jane@suse.example", "state": "confirmed"}' ;;
esac
EOF
chmod +x "$work/bin/geectl"

# case_ <name> <WHOIS_MODE> <expected rc> <expected output>
case_() {
  local out got
  out="$(GEECTL_OBS_USERNAME=jane WHOIS_MODE=$2 PATH="$work/bin:$PATH" bash "$VCID" 2>&1)"; got=$?
  [ "$got" = "$3" ] && grep -qF -- "$4" <<<"$out" && pass "$1 (rc=$3)" || {
    fail "$1: expected rc=$3 and '$4', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
case_ whois ok 0 "Jane Packager <jane@suse.example>"
out="$(GEECTL_OBS_USERNAME=jane WHOIS_MODE=ok PATH="$work/bin:$PATH" bash "$VCID" 2>/dev/null)"
[ "$out" = "Jane Packager <jane@suse.example>" ] && pass "whois: prints only the identity" \
  || fail "whois: printed '$out'"
case_ login-fallback norealname 0 "jane <jane@suse.example>"
case_ whois-fails fail 3 "geectl remote whois jane failed"
case_ no-email noemail 3 "carries no usable name/email"
case_ garbled garbled 3 "carries no usable name/email"
out="$(env -u GEECTL_OBS_USERNAME PATH="$work/bin:$PATH" bash "$VCID" 2>&1)"; got=$?
[ "$got" = 3 ] && grep -qF "set GEECTL_OBS_USERNAME" <<<"$out" && pass "no user set (rc=3)" \
  || { fail "no user set: expected rc=3 and 'set GEECTL_OBS_USERNAME', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }

echo "---"; [ "$fails" = 0 ] && echo "all vc-identity checks passed" || echo "$fails FAILED"
exit $((fails > 0))
