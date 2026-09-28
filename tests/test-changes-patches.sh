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
# An scmsync package carries BOTH .osc and .git, and the osc side cannot see the
# change: it keeps no _files, so the listing comes back as git HEAD (the
# unmodified side) and `osc status` says nothing in a git checkout. Taking the
# osc branch therefore reports "no patch added or removed" over a real added
# patch. This builds that exact shape offline and asserts the finding fires.
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

# An osc project checkout has .osc/_project but no _package (gate.sh run from
# the project directory): a usage failure that says where to go, no traceback.
mkdir -p "$prj/.osc" && printf 'devel:example\n' > "$prj/.osc/_project"
out="$("$SCRIPT" "$prj" 2>&1)"; rc=$?
if [ "$rc" = 2 ] && grep -q 'osc project checkout — cd into the package directory' <<<"$out" && ! grep -q Traceback <<<"$out"; then
  pass "osc project checkout: exit 2 with a pointer, no traceback"
else
  fail "osc project checkout: expected rc=2 and a pointer, got rc=$rc"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# A non-link osc checkout of a package not in Factory: factory-auto skips the patch
# rule, but the entries still count against the committed copy -- two stacked on it
# are a finding, one is not. A stub osc answers the Factory lookup with a 404.
dev="$(mktemp -d)"; trap 'rm -rf "$scm" "$prj" "$dev"' EXIT
mkdir -p "$dev/bin" "$dev/p/.osc/sources"
cat > "$dev/bin/osc" <<'EOF'
#!/bin/bash
case "$1" in
  api) echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1;;
  status) exit 0;;
esac
exit 99
EOF
chmod +x "$dev/bin/osc"
printf 'p\n' > "$dev/p/.osc/_package"; printf 'devel:example\n' > "$dev/p/.osc/_project"
printf '<directory name="p"><entry name="p.changes"/><entry name="p.spec"/></directory>\n' > "$dev/p/.osc/_files"
entry() { printf -- '-------------------------------------------------------------------\nMon Jan  %s 00:00:00 UTC 2024 - you@example.com\n\n- change %s\n\n' "$1" "$1"; }
entry 1 > "$dev/p/.osc/sources/p.changes"; printf 'Name: p\n' > "$dev/p/p.spec"
{ entry 3; entry 2; entry 1; } > "$dev/p/p.changes"
out="$(PATH="$dev/bin:$PATH" "$SCRIPT" "$dev/p" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qF 'p.changes: 2 new entries vs the committed copy' <<<"$out" \
  && pass "not in Factory: two entries stacked on the committed copy are a finding" \
  || { fail "not in Factory, two stacked entries: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
{ entry 2; entry 1; } > "$dev/p/p.changes"
out="$(PATH="$dev/bin:$PATH" "$SCRIPT" "$dev/p" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qF 'does not exist — new package' <<<"$out" \
  && pass "not in Factory: one new entry passes as a new package" \
  || { fail "not in Factory, one entry: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

# usage errors never look clean
"$SCRIPT" --target 2>/dev/null; [ $? -eq 2 ] && pass "missing option value exits 2" || fail "missing option value did not exit 2"
out="$("$SCRIPT" "$FIX/stacked-entries/new" --base "$FIX/stacked-entries/old" --entries 0 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qF -- "--entries takes a positive integer" <<<"$out" \
  && pass "--entries 0 is a usage error that says so" || fail "--entries 0: rc=$rc $out"
"$SCRIPT" /nonexistent-dir-for-test --base "$FIX/rename-glob/old" >/dev/null 2>&1; [ $? -ne 0 ] && pass "nonexistent DIR does not exit 0" || fail "nonexistent DIR exited 0"

[ $fails -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
