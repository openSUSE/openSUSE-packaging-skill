#!/bin/bash
# test-autoforward-gate.sh — autoforward-gate.sh offline: a fake `osc` on PATH
# answers _meta, _link and develproject lookups from a per-case fixture tree (a
# missing file is a 404, "@ERR" fails the call). The package foo lives in
# devel:a, which openSUSE:Factory names as its devel project; tester maintains
# it and nobody reviews. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
AG="$HERE/../skills/opensuse-packaging/scripts/autoforward-gate.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
echo "osc $*" >> "$FIX/calls"
case $1 in
  whois) echo 'tester: "Tester"' ;;
  develproject) [ -f "$FIX/devel/$3" ] || exit 1; cat "$FIX/devel/$3" ;;
  api) f="$FIX/obs/$(printf %s "$2" | tr '/?&=' '____')"
       [ -f "$f" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
       [ "$(cat "$f")" = @ERR ] && { echo "Server returned an error: HTTP Error 500" >&2; exit 1; }
       cat "$f" ;;
  *) echo "fake osc: unexpected $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/osc"

B="$work/base"
mkdir -p "$B/obs" "$B/devel"
obs() { printf '%s\n' "$2" > "$B/obs/$(printf %s "$1" | tr '/?&=' '____')"; }
obs /source/devel:a/foo/_meta '<package name="foo"><person userid="tester" role="maintainer"/></package>'
obs /source/devel:a/_meta '<project name="devel:a"><person userid="boss" role="maintainer"/></project>'
echo devel:a/foo > "$B/devel/foo"

# case_ <name> <expected rc> <expected text> <mutation> [args]
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got; shift 4
  cp -a "$B" "$dir"
  (B=$dir; cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  out="$(cd "$dir" && FIX=$dir PATH="$work/bin:$PATH" bash "$AG" "$@" 2>&1)"; got=$?
  LAST=$out
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
NOMAINT='<package name="foo"/>'

echo "--- the reviewer role gates, maintainership decides"
case_ eligible          0 "ELIGIBLE — package maintainer" : devel:a foo
case_ project-maint     0 "ELIGIBLE — package unmaintained, project maintainer" \
  "obs /source/devel:a/foo/_meta '$NOMAINT'; obs /source/devel:a/_meta '<project><person userid=\"tester\" role=\"maintainer\"/></project>'" devel:a foo
case_ reviewer          3 "BLOCKED — explicit reviewer role: rev" \
  "obs /source/devel:a/foo/_meta '<package><person userid=\"tester\" role=\"maintainer\"/><person userid=\"rev\" role=\"reviewer\"/></package>'" devel:a foo
case_ project-reviewer  3 "BLOCKED — explicit reviewer role: qa" \
  "obs /source/devel:a/_meta '<project><group groupid=\"qa\" role=\"reviewer\"/></project>'" devel:a foo
case_ not-yours         4 "NOT_YOURS — maintained by someone else" \
  "obs /source/devel:a/foo/_meta '<package><person userid=\"other\" role=\"maintainer\"/></package>'" devel:a foo
case_ unmaintained      4 "NOT_YOURS — package unmaintained, not a project maintainer" \
  "obs /source/devel:a/foo/_meta '$NOMAINT'" devel:a foo
case_ unreadable        5 "cannot read /source/devel:a/foo/_meta" "rm obs/_source_devel:a_foo__meta" devel:a foo
# Unread, a project-level reviewer would go unseen.
case_ project-unreadable 5 "its project's" "obs /source/devel:a/_meta @ERR" devel:a foo

echo "--- the project must be the one Factory develops the package in"
case_ wrong-devel       6 "WRONG-DEVEL — openSUSE:Factory develops it in devel:b" \
  "echo devel:b/foo > devel/foo" devel:a foo
grep -q ELIGIBLE <<<"$LAST" && fail "wrong-devel also said ELIGIBLE" || pass "wrong-devel never reads ELIGIBLE"
case_ link-into-here    0 "ELIGIBLE" \
  "echo devel:b/foo > devel/foo; obs /source/devel:b/foo/_link '<link project=\"devel:a\"/>'" devel:a foo
case_ link-elsewhere    6 "WRONG-DEVEL" \
  "echo devel:b/foo > devel/foo; obs /source/devel:b/foo/_link '<link project=\"openSUSE:Factory\"/>'" devel:a foo
case_ link-other-package 6 "WRONG-DEVEL" \
  "echo devel:b/foo > devel/foo; obs /source/devel:b/foo/_link '<link project=\"devel:a\" package=\"bar\"/>'" devel:a foo
case_ link-unreadable   5 "or its Factory devel project" \
  "echo devel:b/foo > devel/foo; obs /source/devel:b/foo/_link @ERR" devel:a foo
# Project names are compared as strings: "devel.a" is no pattern for "develxa".
case_ link-literal      6 "WRONG-DEVEL" \
  "obs /source/devel.a/foo/_meta \"\$(cat obs/_source_devel:a_foo__meta)\"; obs /source/devel.a/_meta '<project/>'; echo devel:b/foo > devel/foo; obs /source/devel:b/foo/_link '<link project=\"develxa\"/>'" devel.a foo
# Factory itself is never another project's devel project.
case_ factory-itself    0 "ELIGIBLE" \
  "obs /source/openSUSE:Factory/foo/_meta \"\$(cat obs/_source_devel:a_foo__meta)\"; obs /source/openSUSE:Factory/_meta '<project/>'" openSUSE:Factory foo
grep -q develproject "$work/factory-itself/calls" && fail "factory-itself asked for a devel project" \
  || pass "factory-itself asks for no devel project"
case_ not-in-factory    0 "ELIGIBLE" "rm devel/foo" devel:a foo
case_ no-devel-set      0 "ELIGIBLE" \
  "rm devel/foo; obs /source/openSUSE:Factory/foo/_meta '<package name=\"foo\"/>'" devel:a foo
case_ devel-lookup-fails 5 "or its Factory devel project" \
  "rm devel/foo; obs /source/openSUSE:Factory/foo/_meta @ERR" devel:a foo

echo "--- --batch exits with the worst row"
ROWS=$'devel:a\tfoo\ndevel:a\tbar'
BAR="obs /source/devel:a/bar/_meta '<package><person userid=\"tester\" role=\"maintainer\"/></package>'"
case_ batch-eligible    0 $'devel:a/bar\tELIGIBLE' \
  "$BAR; echo devel:a/bar > devel/bar; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-wrong       6 $'devel:a/bar\tWRONG-DEVEL' \
  "$BAR; echo devel:c/bar > devel/bar; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-wrong-over-blocked 6 "WRONG-DEVEL" \
  "$BAR; echo devel:c/bar > devel/bar; obs /source/devel:a/foo/_meta '<package><person userid=\"rev\" role=\"reviewer\"/></package>'; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-unreadable-wins 5 "UNREADABLE" \
  "echo devel:c/foo > devel/foo; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-empty       2 "no project/package rows" ": > rows" --batch rows
# A failed project _meta read is not cached as an empty one.
case_ batch-project-unreadable 5 $'devel:a/bar\tUNREADABLE' \
  "$BAR; echo devel:a/bar > devel/bar; obs /source/devel:a/_meta @ERR; printf '%s\n' \"$ROWS\" > rows" --batch rows
[ "$(grep -c '^osc api /source/devel:a/_meta$' "$work/batch-eligible/calls")" = 1 ] \
  && pass "--batch reads each project's _meta once" || fail "--batch: devel:a/_meta not read exactly once"

if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
