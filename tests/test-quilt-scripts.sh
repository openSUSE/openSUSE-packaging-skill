#!/bin/bash
# test-quilt-scripts.sh — quilt-prep.sh and quilt-test-series.sh on a package built at run
# time: patch 1 applies at an offset (must be refreshed), patch 2 rejects (must be
# commented out, later patches must still be tested), patch 3 applies cleanly. The
# functional cases need quilt and rpmbuild and print SKIP without them; -h and usage
# errors always run. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../skills/opensuse-packaging/scripts"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

for s in quilt-prep.sh quilt-test-series.sh; do
  out="$(bash "$S/$s" -h 2>&1)"; rc=$?
  [ $rc = 0 ] && grep -q '^Exit:' <<<"$out" && pass "$s -h prints usage with an Exit line" || fail "$s -h (rc=$rc)"
  bash "$S/$s" >/dev/null 2>&1; [ $? = 2 ] && pass "$s without a spec is a usage error (2)" || fail "$s without a spec must exit 2"
  bash "$S/$s" "$work/missing.spec" >/dev/null 2>&1; [ $? = 2 ] && pass "$s with a missing spec exits 2" || fail "$s with a missing spec must exit 2"
done

if ! command -v quilt >/dev/null || ! command -v rpmbuild >/dev/null || ! command -v rpmspec >/dev/null; then
  printf 'SKIP: functional cases need quilt, rpmbuild and rpmspec\n'
  [ "$fails" = 0 ]; exit
fi

pkg="$work/pkg"; mkdir -p "$pkg" "$work/src/hello-1.0"
seq 1 20 | sed 's/^/line /' > "$work/src/hello-1.0/f.txt"
tar -C "$work/src" -czf "$pkg/hello-1.0.tar.gz" hello-1.0
mk() { # mk <name> <orig-line> <new-text> <hunk-start>: one-line replacement patch
  printf -- '--- a/f.txt\n+++ b/f.txt\n@@ -%s,3 +%s,3 @@\n %s\n-%s\n+%s\n %s\n' "$4" "$4" "line $(($2-1))" "line $2" "$3" "line $(($2+1))" > "$pkg/$1"
}
mk offset.patch 10 "ten" 12      # real position 9: hunk header is 3 lines off -> offset
mk reject.patch 10 "TEN" 9       # line 10 is already "ten" -> context mismatch -> reject
mk clean.patch 15 "fifteen" 14
cat > "$pkg/hello.spec" <<'SPEC'
Name:           hello
Version:        1.0
Release:        0
Summary:        t
License:        MIT
Source0:        hello-1.0.tar.gz
Patch1:         offset.patch
Patch2:         reject.patch
Patch3:         clean.patch
%description
t
%prep
%autosetup -p1
%build
%install
%files
SPEC
cd "$pkg" || exit 2
out="$(bash "$S/quilt-test-series.sh" hello.spec 2>&1)"; rc=$?
[ $rc = 1 ] && pass "series with a reject exits 1" || { fail "series exit $rc, want 1"; printf '%s\n' "$out" | sed 's/^/    /'; }
grep -q '^#Patch2:' hello.spec && grep -q '^Patch1:' hello.spec && grep -q '^Patch3:' hello.spec \
  && pass "only the rejecting patch is commented out" || fail "spec after run: $(grep '^#\?Patch' hello.spec | tr '\n' ' ')"
grep -qF 'reject.patch ::' <<<"$out" && pass "reject reported with its hunks" || fail "no reject line in report"
grep -A1 'REFRESHED' <<<"$out" | grep -q offset.patch && pass "offset-only patch refreshed" || fail "offset.patch not reported refreshed"
grep -q '^@@ -7,7 ' offset.patch && pass "refresh corrected the hunk offset" || fail "offset.patch not rewritten: $(grep '^@@' offset.patch)"
grep -q '^--- a/f.txt' offset.patch && ! grep -q '^Index:' offset.patch && pass "refreshed patch has a/ b/ prefixes and no Index line" || fail "refreshed header: $(head -3 offset.patch)"
[ ! -d hello-1.0-build ] && pass "build dir removed" || fail "build dir left behind"
mkdir hello-1.0-build
bash "$S/quilt-test-series.sh" hello.spec >/dev/null 2>&1; [ $? = 2 ] && [ -d hello-1.0-build ] \
  && pass "existing build dir is refused, not deleted" || fail "existing build dir must exit 2 and survive"
[ "$fails" = 0 ]
