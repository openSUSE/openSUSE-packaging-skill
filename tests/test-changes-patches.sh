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
stacked-entries  1 0 0 0
TABLE

# the exact factory-auto wording must survive, so a decline and the local
# finding read the same
out="$("$SCRIPT" "$FIX/rename-glob/new" --base "$FIX/rename-glob/old" 2>/dev/null)"
grep -qxF 'A patch (zoo-2.10.1-tempfile.patch) is being added without this addition being mentioned in the changelog.' <<<"$out" \
  && pass "finding uses factory-auto's exact sentence" || fail "finding wording drifted from factory-auto"
# One submission, one entry: two new entries vs the target are a finding even
# with no patch delta (a second prepend stacked them); --entries N allows a
# forward that carries N.
out="$("$SCRIPT" "$FIX/stacked-entries/new" --base "$FIX/stacked-entries/old" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qF 'zoo.changes: 2 new entries vs' <<<"$out" \
  && pass "stacked entries: named with their count" || { fail "stacked entries: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# A red run never ends on an "OK:" line.
[ "$(tail -1 <<<"$out" | cut -c1-3)" != "OK:" ] && ! grep -q '^OK:' <<<"$out" \
  && pass "stacked entries: no OK: line on a red run" || { fail "stacked entries: OK: printed on a red run"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$("$SCRIPT" "$FIX/stacked-entries/new" --base "$FIX/stacked-entries/old" --entries 2 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "stacked entries: --entries 2 allows two" || { fail "stacked entries --entries 2: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# An scmsync package carries BOTH .osc and .git; the target is the git ref, and
# the added patch is found over it — the git branch, not an OBS listing.
scm="$(mktemp -d)"; prj="$(mktemp -d)"
trap 'rm -rf "$scm" "$prj"' EXIT
(
  cd "$scm" || exit 1
  git init -q . && git config user.email t@example.com && git config user.name t
  printf -- '-------------------------------------------------------------------\nMon Jan  1 00:00:00 UTC 2024 - you@example.com\n\n- initial\n' > p.changes
  printf 'Name: p\n' > p.spec
  git add p.changes p.spec && git commit -qm base
  mkdir -p .osc && printf 'url=https://example.invalid/p.git\n' > .osc/_scm
  printf 'x\n' > added.patch && git add added.patch          # added, unmentioned
) || fail "could not build the scmsync fixture"
out="$("$SCRIPT" "$scm" --git-base HEAD 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q 'added.patch) is being added' <<<"$out"; then
  pass "scmsync checkout: unmentioned added patch is found (not a false clean)"
else
  fail "scmsync checkout: expected rc=1 with an 'is being added' finding, got rc=$rc"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# A directory that is neither a git checkout nor given --base: a usage failure
# that says where to go, no traceback. (A bare .osc project dir is not a
# package checkout: it has a _project but no _package.)
mkdir -p "$prj/.osc" && printf 'devel:example\n' > "$prj/.osc/_project"
out="$("$SCRIPT" "$prj" 2>&1)"; rc=$?
if [ "$rc" = 2 ] && grep -q 'osc project checkout — cd into the package directory' <<<"$out" && ! grep -q Traceback <<<"$out"; then
  pass "bare .osc project dir: exit 2 with a pointer, no traceback"
else
  fail "neither git nor --base: expected rc=2 and a pointer, got rc=$rc"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# A geectl working copy compares against the git ref: two entries stacked on
# the ref are a finding, one is not. A missing --base dir is a new package.
dev="$(mktemp -d)"; trap 'rm -rf "$scm" "$prj" "$dev"' EXIT
(
  cd "$dev" || exit 1
  git init -q . && git config user.email t@example.com && git config user.name t
  printf -- '-------------------------------------------------------------------\nMon Jan  1 00:00:00 UTC 2024 - you@example.com\n\n- change 1\n\n' > p.changes
  printf 'Name: p\n' > p.spec
  git add p.changes p.spec && git commit -qm base
) || fail "could not build the git fixture"
entry() { printf -- '-------------------------------------------------------------------\nMon Jan  %s 00:00:00 UTC 2024 - you@example.com\n\n- change %s\n\n' "$1" "$1"; }
{ entry 3; entry 2; entry 1; } > "$dev/p.changes"
git -C "$dev" add p.changes
out="$("$SCRIPT" "$dev" --git-base HEAD 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qF 'p.changes: 2 new entries vs HEAD' <<<"$out" \
  && pass "git ref: two entries stacked on the ref are a finding" \
  || { fail "git ref, two stacked entries: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
{ entry 2; entry 1; } > "$dev/p.changes"
out="$("$SCRIPT" "$dev" --git-base HEAD 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "git ref: one new entry passes" \
  || { fail "git ref, one entry: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$("$SCRIPT" "$dev" --base "$dev/no-such-target" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qF 'no target snapshot at' <<<"$out" \
  && pass "missing --base dir passes as a new package" \
  || { fail "missing --base dir: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

# An osc checkout compares against its committed copy (no --target) or the
# SR target (--target): the committed copy lives in .osc/sources, the target's
# files come from geectl list-files + remote cat.
oscfix="$(mktemp -d)"; trap 'rm -rf "$scm" "$prj" "$dev" "$oscfix"' EXIT
mkdir -p "$oscfix/bin" "$oscfix/factory" "$oscfix/d1/.osc/sources" "$oscfix/d2/.osc/sources"
cat > "$oscfix/bin/geectl" <<'GEOF'
#!/bin/bash
case "$*" in
  "remote link-target devel:example foo") echo '{"project": "devel:example", "package": "foo", "target": null}' ;;
  "remote list-files openSUSE:Factory foo") echo '{"project": "openSUSE:Factory", "package": "foo", "files": [{"name": "foo.changes", "size": 1, "mtime": 1, "md5": "c1"}, {"name": "foo.spec", "size": 1, "mtime": 1, "md5": "s1"}]}' ;;
  "remote cat openSUSE:Factory foo foo.changes --format text") cat "$GEO_FACTORY/foo.changes" ;;
  *) echo "fake geectl: unexpected $*" >&2; exit 99 ;;
esac
GEOF
chmod +x "$oscfix/bin/geectl"
{
  printf -- '-------------------------------------------------------------------\nMon Jan  5 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Initial package\n\n'
} > "$oscfix/factory/foo.changes"
for dd in d1 d2; do
  printf 'foo\n' > "$oscfix/$dd/.osc/_package"
  printf 'devel:example\n' > "$oscfix/$dd/.osc/_project"
  printf '<directory name="foo" rev="3"><entry name="foo.changes"/><entry name="foo.spec"/></directory>\n' > "$oscfix/$dd/.osc/_files"
  printf 'Name: foo\nVersion: 1.3\n' > "$oscfix/$dd/foo.spec"
  cp "$oscfix/$dd/foo.spec" "$oscfix/$dd/.osc/sources/foo.spec"
  {
    printf -- '-------------------------------------------------------------------\nWed Sep 16 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Fix the man page\n\n'
    printf -- '-------------------------------------------------------------------\nTue Sep 15 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Drop the obsolete Obsoletes\n\n'
    cat "$oscfix/factory/foo.changes"
  } > "$oscfix/$dd/.osc/sources/foo.changes"
  {
    printf -- '-------------------------------------------------------------------\nThu Sep 17 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Build with the system zlib\n\n'
    cat "$oscfix/$dd/.osc/sources/foo.changes"
  } > "$oscfix/$dd/foo.changes"
done
{
  printf -- '-------------------------------------------------------------------\nFri Sep 18 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Fix the build\n\n'
  cat "$oscfix/d2/foo.changes"
} > "$oscfix/d2/foo.changes.new" && mv "$oscfix/d2/foo.changes.new" "$oscfix/d2/foo.changes"
GEO_FACTORY="$oscfix/factory" PATH="$oscfix/bin:$PATH" "$SCRIPT" "$oscfix/d1" --entries 1 >$oscfix/d1.out 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qF 'OK: no patch added or removed vs openSUSE:Factory/foo' $oscfix/d1.out \
  && pass "osc checkout: one new entry vs the committed copy passes" \
  || { fail "osc checkout d1: rc=$rc"; sed 's/^/    /' $oscfix/d1.out; }
GEO_FACTORY="$oscfix/factory" PATH="$oscfix/bin:$PATH" "$SCRIPT" "$oscfix/d2" --entries 1 >$oscfix/d2.out 2>&1; rc=$?
[ "$rc" = 1 ] && grep -qF 'foo.changes: 2 new entries vs the committed copy' $oscfix/d2.out \
  && pass "osc checkout: two new entries vs the committed copy are a finding" \
  || { fail "osc checkout d2: rc=$rc"; sed 's/^/    /' $oscfix/d2.out; }
GEO_FACTORY="$oscfix/factory" PATH="$oscfix/bin:$PATH" "$SCRIPT" "$oscfix/d1" --entries 1 --target openSUSE:Factory >$oscfix/d1t.out 2>&1; rc=$?
[ "$rc" = 1 ] && grep -qF 'foo.changes: 3 new entries vs openSUSE:Factory/foo' $oscfix/d1t.out \
  && pass "osc checkout: --target Factory counts three new entries" \
  || { fail "osc checkout d1 --target: rc=$rc"; sed 's/^/    /' $oscfix/d1t.out; }

# usage errors never look clean
"$SCRIPT" --entries 2>/dev/null; [ $? -eq 2 ] && pass "missing option value exits 2" || fail "missing option value did not exit 2"
"$SCRIPT" --target 2>/dev/null; [ $? -eq 2 ] && pass "missing --target value exits 2" || fail "missing --target value did not exit 2"
out="$("$SCRIPT" "$FIX/stacked-entries/new" --base "$FIX/stacked-entries/old" --entries 0 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qF -- "--entries takes a positive integer" <<<"$out" \
  && pass "--entries 0 is a usage error that says so" || fail "--entries 0: rc=$rc $out"
"$SCRIPT" /nonexistent-dir-for-test --base "$FIX/rename-glob/old" >/dev/null 2>&1; [ $? -ne 0 ] && pass "nonexistent DIR does not exit 0" || fail "nonexistent DIR exited 0"

[ $fails -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
