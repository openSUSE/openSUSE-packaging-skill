#!/bin/bash
# test-changes-patches.sh — proves scripts/changes-patches.sh reproduces
# factory-auto's patch-mention rule offline, over tests/fixtures/changes-patches:
# each case is <case>/old (the SR target's files) and <case>/new (the working
# copy); the table below is the expected exit code, the number of
# "is being added" / "is being deleted" findings, and whether the wrapped-name
# hint fires. Exit 0 = all assertions hold; any failure exits 1.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom, not a broken if/then/else: pass and fail both return 0 (verified), so exactly
# one verdict is ever printed, including at the inverted `&& fail || pass` sites.
# shellcheck disable=SC2181  # rc is captured once with rc=$? and then asserted on
# several times; `if cmd; then` cannot express that.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../skills/opensuse-packaging/scripts/changes-patches.sh"
FIX="$HERE/fixtures/changes-patches"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }

#      case            rc added deleted wraphint
while read -r case rc added deleted hint; do
  out="$("$SCRIPT" "$FIX/$case/new" --base "$FIX/$case/old" 2>&1)"; got=$?
  a=$(grep -c 'is being added' <<<"$out"); r=$(grep -c 'is being deleted' <<<"$out")
  h=$(grep -c 'wrapped across lines' <<<"$out")
  if [ "$got" = "$rc" ] && [ "$a" = "$added" ] && [ "$r" = "$deleted" ] && [ "$h" = "$hint" ]; then
    pass "$case (rc=$rc added=$added deleted=$deleted wraphint=$hint)"
  else
    fail "$case: expected rc=$rc added=$added deleted=$deleted wraphint=$hint, got rc=$got added=$a deleted=$r wraphint=$h"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
done <<'TABLE'
rename-glob      1 3 0 0
rename-literal   0 0 0 0
wrapped          1 1 0 1
source-exempt    0 0 0 0
new-package      0 0 0 0
diff-dif         1 1 1 0
old-entry-only   1 1 0 0
TABLE

# the exact factory-auto wording must survive, so a decline and the local
# finding read the same
out="$("$SCRIPT" "$FIX/rename-glob/new" --base "$FIX/rename-glob/old" 2>/dev/null)"
grep -qxF 'A patch (zoo-2.10.1-tempfile.patch) is being added without this addition being mentioned in the changelog.' <<<"$out" \
  && pass "finding uses factory-auto's exact sentence" || fail "finding wording drifted from factory-auto"
# usage errors never look clean
"$SCRIPT" --target 2>/dev/null; [ $? -eq 2 ] && pass "missing option value exits 2" || fail "missing option value did not exit 2"
"$SCRIPT" /nonexistent-dir-for-test --base "$FIX/rename-glob/old" >/dev/null 2>&1; [ $? -ne 0 ] && pass "nonexistent DIR does not exit 0" || fail "nonexistent DIR exited 0"

[ $fails -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
