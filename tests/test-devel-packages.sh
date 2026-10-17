#!/bin/bash
# test-devel-packages.sh — proves devel-packages.sh lists what Factory's _meta
# says a devel project develops, keeps the project beside each name, and never
# reads a failed or unparsable search as "no packages". Offline: a fake `osc` on
# PATH answers the package search from fixtures keyed by the devel project.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/skills/opensuse-packaging/scripts/devel-packages.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
FIX="$work/fix"; export FIX
mkdir -p "$work/bin" "$FIX"
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
[ "$1" = api ] || { echo "fake osc: unexpected $*" >&2; exit 99; }
prj=${2#*devel/@project=\'}; prj=${prj%\'}
f="$FIX/$prj"
[ -f "$f" ] || { echo "Server returned an error: HTTP Error 500: Internal Server Error" >&2; exit 1; }
cat "$f"
EOF
chmod +x "$work/bin/osc"
export PATH="$work/bin:$PATH"
printf '%s' '<collection matches="2"><package name="libpqxx" project="openSUSE:Factory"/><package name="pgadmin4" project="openSUSE:Factory"/></collection>' > "$FIX/server:database:postgresql"
printf '%s' '<collection matches="1"><package name="ctemplate" project="openSUSE:Factory"/></collection>' > "$FIX/server:database"
printf '%s' '<collection matches="0"/>' > "$FIX/devel:empty"
printf '%s' '<status code="400"><summary>bad xpath</summary></status>' > "$FIX/odd"
printf '%s' 'not xml' > "$FIX/broken"

out="$(bash "$SCRIPT" server:database:postgresql)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = $'libpqxx server:database:postgresql\npgadmin4 server:database:postgresql' ] \
  && pass "lists each package with its devel project" || fail "listed: rc=$rc out=$out"
out="$(bash "$SCRIPT" server:database server:database:postgresql)"; rc=$?
[ "$rc" = 0 ] && grep -qx 'ctemplate server:database' <<<"$out" && grep -qx 'libpqxx server:database:postgresql' <<<"$out" \
  && ! grep -q 'libpqxx server:database$' <<<"$out" \
  && pass "several projects: each name keeps its own project" || fail "several: rc=$rc out=$out"
out="$(bash "$SCRIPT" devel:empty 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -q '^NONE' <<<"$out" && pass "no package: exit 3" || fail "none: rc=$rc out=$out"
bash "$SCRIPT" no:fixture >/dev/null 2>&1; rc=$?
[ "$rc" = 5 ] && pass "a failed search: exit 5, not none" || fail "failed search: rc=$rc"
bash "$SCRIPT" odd >/dev/null 2>&1; rc=$?
[ "$rc" = 5 ] && pass "an error document: exit 5" || fail "error document: rc=$rc"
bash "$SCRIPT" broken >/dev/null 2>&1; rc=$?
[ "$rc" = 5 ] && pass "an answer that does not parse: exit 5" || fail "unparsable: rc=$rc"
bash "$SCRIPT" "x' or @name='y" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "a quote in the project: usage error" || fail "quote: rc=$rc"
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "no argument: usage error" || fail "no argument: rc=$rc"
bash "$SCRIPT" --help | grep -q 'exit 5' && pass "--help lists the exit codes" || fail "--help"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
