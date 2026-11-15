#!/bin/bash
# test-quilt-scripts.sh — quilt-prep.sh and quilt-test-series.sh on a package built at run
# time: patch 1 applies at an offset (must be refreshed), patch 2 rejects (must be
# commented out, later patches must still be tested), patch 3 applies cleanly. The
# functional cases need quilt and rpmbuild (rpm 4.20's build directory layout, as on
# Tumbleweed) and print SKIP without them, or fail with QUILT_TESTS=require; -h and usage
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
  # Where the cases are meant to run, a missing tool is a failure, not a skip.
  [ "${QUILT_TESTS:-}" = require ] && fail "QUILT_TESTS=require, but quilt, rpmbuild or rpmspec is missing"
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

# One rejecting patch, in each way a spec can name and apply it. A run that cannot comment
# the patch out must stop: before, it pushed the same patch for ever, hence the time limit.
one() { # one <dir> <patch file> <Patch line> [<%prep line>...]: run the series there
  local d="$work/$1" file=$2 tag=$3; shift 3
  mkdir -p "$d"; cp "$pkg/hello-1.0.tar.gz" "$d/"
  printf -- '--- a/f.txt\n+++ b/f.txt\n@@ -9,3 +9,3 @@\n line 9\n-line X\n+TEN\n line 11\n' > "$d/$file"
  { printf '%s\n' "Name:           hello" "Version:        1.0" "Release:        0" "Summary:        t" \
      "License:        MIT" "Source0:        hello-1.0.tar.gz" "%global stem reject" "$tag" "%description" "t" "%prep"
    printf '%s\n' "${@:-%autosetup -p1}" "%build" "%install" "%files"; } > "$d/hello.spec"
  cd "$d" || exit 2
  out="$(timeout 120 bash "$S/quilt-test-series.sh" hello.spec 2>&1)"; rc=$?
}
one macro hello-reject.patch 'Patch1:         %{name}-reject.patch'
[ $rc = 1 ] && grep -q '^#Patch1:' hello.spec && pass "a patch named with %{name} is commented out" || fail "macro name: rc=$rc"
one plus c++-reject.patch 'Patch1:         c++-reject.patch'
[ $rc = 1 ] && grep -q '^#Patch1:' hello.spec && pass "a patch with + in its name is commented out" || fail "plus name: rc=$rc"
one bare reject.patch 'Patch:          reject.patch'
[ $rc = 1 ] && grep -q '^#Patch:' hello.spec && pass "an unnumbered Patch: line is commented out" || fail "unnumbered tag: rc=$rc"
one explicit reject.patch 'Patch1:         reject.patch' '%setup -q' '%patch -P 1 -p1'
[ $rc = 1 ] && grep -q '^#Patch1:' hello.spec && grep -q '^#%patch -P 1 -p1' hello.spec \
  && pass "the %patch line that applies the patch goes with it" || fail "explicit %patch: rc=$rc $(grep 'atch' hello.spec | tr '\n' ' ')"
one stuck reject.patch 'Patch1:         %{stem}.patch'
[ $rc = 2 ] && grep -q 'STUCK: reject.patch' <<<"$out" && grep -q '^Patch1:' hello.spec && [ ! -d hello-1.0-build ] \
  && pass "a patch line it cannot find stops the run and leaves the spec" || fail "unfindable line: rc=$rc"
# The build dir is removed by its name: one that leaves the checkout is refused.
mkdir -p "$work/evil"; cd "$work/evil" || exit 2
sed 's|^Name:.*|Name:           ../evil|' "$pkg/hello.spec" > hello.spec
out="$(bash "$S/quilt-prep.sh" --force hello.spec 2>&1)"; rc=$?
[ $rc = 2 ] && grep -q "refusing the name-version" <<<"$out" && pass "a name-version with a slash is refused" || fail "slash in name: rc=$rc $out"
[ "$fails" = 0 ]
