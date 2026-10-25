#!/bin/bash
# test-gate.sh — gate.sh refuses a directory that is not a package checkout
# before any gate runs: source_validator there reported rc=0, a green piece of a
# verdict about nothing. Offline; TMPDIR keeps gate.sh's logs in the work dir.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../skills/opensuse-packaging/scripts/gate.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export TMPDIR="$work"

# case_ <name> <expected rc> <expected message> <dir>
case_() {
  local out got
  out="$(bash "$GATE" "$4" 2>&1)"; got=$?
  [ "$got" = "$2" ] && grep -qF -- "$3" <<<"$out" && pass "$1 (rc=$2)" || {
    fail "$1: expected rc=$2 and '$3', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
  LAST=$out
}

# A bad --entries is a usage error before any gate runs, not a red gate.
mkdir -p "$work/pkg0" && printf 'Name: p\n' > "$work/pkg0/p.spec"
for n in 0 x -1; do
  out="$(bash "$GATE" "$work/pkg0" --entries "$n" 2>&1)"; rc=$?
  [ "$rc" = 2 ] && grep -qF -- "--entries takes a positive integer" <<<"$out" && ! grep -q '^## ' <<<"$out" \
    && pass "--entries $n: usage error, no gate ran" || { fail "--entries $n: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
done
mkdir -p "$work/project/.osc" && printf 'devel:example\n' > "$work/project/.osc/_project"
case_ project-checkout 2 "osc project checkout — cd into the package directory" "$work/project"
! grep -q '^## ' <<<"$LAST" && pass "project-checkout: no gate ran" || fail "project-checkout: gates ran: $LAST"
mkdir -p "$work/empty"
case_ empty-dir 2 "no *.spec and no .osc/_package" "$work/empty"
! grep -q '^## ' <<<"$LAST" && pass "empty-dir: no gate ran" || fail "empty-dir: gates ran: $LAST"
# Control: a spec is enough to get past the refusal; the gates then run (and
# are red here: no .changes, and not a checkout changes-patches can read).
mkdir -p "$work/pkg" && printf 'Name: p\n' > "$work/pkg/p.spec"
case_ spec-only 1 "VERDICT: RED" "$work/pkg"

# --entries N is "entries the submission adds vs the target": changes-patches
# counts them too. A git clone whose upstream holds one entry, two added.
SEP=-------------------------------------------------------------------
g() { git -c user.name=t -c user.email=t@example.com "$@"; }
mkdir -p "$work/seed" && printf 'Name: p\n' > "$work/seed/p.spec"
printf '%s\nMon Jan  5 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- initial package\n' "$SEP" > "$work/seed/p.changes"
{ g -C "$work/seed" init -q && g -C "$work/seed" add . && g -C "$work/seed" commit -qm base \
  && g clone -q "$work/seed" "$work/clone" \
  && { printf '%s\nTue Sep 15 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Fix the build\n\n' "$SEP"
       printf '%s\nMon Sep 14 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Update to 1.1\n\n' "$SEP"
       cat "$work/seed/p.changes"; } > "$work/clone/p.changes.new" \
  && mv "$work/clone/p.changes.new" "$work/clone/p.changes" && g -C "$work/clone" commit -qam two; } \
  || fail "could not build the git fixture"
case_ two-entries-default 1 "p.changes: 2 new entries vs" "$work/clone"
grep -qF "## changes-patches: rc=1" <<<"$LAST" && pass "two-entries-default: changes-patches is red" \
  || fail "two-entries-default: changes-patches not red: $LAST"
out="$(bash "$GATE" "$work/clone" --entries 2 2>&1)"
grep -qF "## changes-patches: rc=0" <<<"$out" && pass "two-entries --entries 2: changes-patches green" \
  || { fail "two-entries --entries 2: changes-patches not green"; printf '%s\n' "$out" | sed 's/^/    /'; }

# A non-link osc checkout of a devel project is a direct commit there: its new
# entries count against the committed copy, not against Factory, which the
# devel project may legitimately be several entries ahead of. An explicit
# --target still counts against that target. A fake osc serves Factory.
mkdir -p "$work/bin" "$work/factory"
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
case "$1" in
  api) [ "$2" = "/source/openSUSE:Factory/foo?expand=1" ] \
         && { echo '<directory name="foo"><entry name="foo.changes"/><entry name="foo.spec"/></directory>'; exit 0; } ;;
  cat) [ "$2 $3" = "openSUSE:Factory foo" ] && [ -f "$FACTORY/$4" ] && { cat "$FACTORY/$4"; exit 0; } ;;
  status) exit 0 ;;
  whois) echo 'jpackager: "Jane Packager" <jane@example.com>'; exit 0 ;;
  vc) [ -z "${VC_FAIL:-}" ] && printf -- '-------------------------------------------------------------------\nSun Oct 18 12:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- probe\n\n' > "$4" && exit 0 ;;
esac
echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1
EOF
chmod +x "$work/bin/osc"
entry() { printf '%s\n%s - Jane Packager <jane@example.com>\n\n- %s\n\n' "$SEP" "$1" "$2"; }
entry "Mon Jan  5 10:00:00 UTC 2026" "Initial package" > "$work/factory/foo.changes"
devel() { # <dir> <number of uncommitted entries>: devel two committed entries ahead of Factory
  mkdir -p "$1/.osc/sources" && printf 'foo\n' > "$1/.osc/_package" && printf 'devel:example\n' > "$1/.osc/_project"
  printf '<directory name="foo" rev="3"><entry name="foo.changes"/><entry name="foo.spec"/></directory>\n' > "$1/.osc/_files"
  printf 'Name: foo\nVersion: 1.3\n' | tee "$1/foo.spec" > "$1/.osc/sources/foo.spec"
  { entry "Wed Sep 16 10:00:00 UTC 2026" "Fix the man page"; entry "Tue Sep 15 10:00:00 UTC 2026" "Drop the obsolete Obsoletes"
    cat "$work/factory/foo.changes"; } > "$1/.osc/sources/foo.changes"
  { [ "$2" -ge 2 ] && entry "Fri Sep 18 10:00:00 UTC 2026" "Fix the build"
    entry "Thu Sep 17 10:00:00 UTC 2026" "Build with the system zlib"; cat "$1/.osc/sources/foo.changes"; } > "$1/foo.changes"
}
devel "$work/devel-one" 1; devel "$work/devel-two" 2
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-one" 2>&1)"
grep -qF "## changes-patches: rc=0" <<<"$out" && pass "non-link checkout, one new entry: changes-patches green" \
  || { fail "non-link checkout, one new entry: changes-patches not green"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-two" 2>&1)"
grep -qF "## changes-patches: rc=1" <<<"$out" && grep -qF "foo.changes: 2 new entries vs the committed copy" <<<"$out" \
  && pass "non-link checkout, two new entries: red, counted against the committed copy" \
  || { fail "non-link checkout, two new entries"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-one" --target openSUSE:Factory 2>&1)"
grep -qF "foo.changes: 3 new entries vs openSUSE:Factory/foo" <<<"$out" \
  && pass "non-link checkout, explicit --target: counted against the target" \
  || { fail "non-link checkout, explicit --target"; printf '%s\n' "$out" | sed 's/^/    /'; }

# --amend-top reaches changes-guard, which asks Factory whether the committed
# top entry is still a draft: devel's own unaccepted entry is, Factory's is not.
devel "$work/amend-draft" 1; cp "$work/amend-draft/.osc/sources/foo.changes" "$work/amend-draft/foo.changes"
sed -i 's/^- Fix the man page$/- Fix the man page and its examples/' "$work/amend-draft/foo.changes"
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/amend-draft" --amend-top 'Jane Packager' 2>&1)"
grep -qF "## changes-guard: rc=0" <<<"$out" && pass "--amend-top on devel's unaccepted top entry: guard green" \
  || { fail "--amend-top on devel's unaccepted top entry"; printf '%s\n' "$out" | sed 's/^/    /'; }
mkdir -p "$work/amend-released/.osc/sources" && printf 'foo\n' > "$work/amend-released/.osc/_package"
printf 'Name: foo\nVersion: 1.0\n' > "$work/amend-released/foo.spec"
cp "$work/factory/foo.changes" "$work/amend-released/.osc/sources/foo.changes"
sed 's/^- Initial package$/- Initial package, reworded/' "$work/factory/foo.changes" > "$work/amend-released/foo.changes"
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/amend-released" --amend-top 'Jane Packager' 2>&1)"
grep -qF "## changes-guard: rc=1" <<<"$out" && grep -qF "already in openSUSE:Factory" <<<"$out" \
  && pass "--amend-top on an entry Factory already has: guard red" \
  || { fail "--amend-top on an entry Factory already has"; printf '%s\n' "$out" | sed 's/^/    /'; }
# --squash-mine reaches changes-guard: devel's two unaccepted entries fold into one.
devel "$work/squash" 1
{ entry "Fri Sep 18 10:00:00 UTC 2026" "Fix the man page; drop the obsolete Obsoletes"; cat "$work/factory/foo.changes"; } > "$work/squash/foo.changes"
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/squash" --squash-mine 'Jane Packager' 2>&1)"
grep -qF "## changes-guard: rc=0" <<<"$out" && grep -qF "2 of your unreleased entries folded into one" <<<"$out" \
  && pass "--squash-mine: devel's own unaccepted entries fold into one" \
  || { fail "--squash-mine through the gate"; printf '%s\n' "$out" | sed 's/^/    /'; }

# changes-lint checks the new entry's author against what osc vc writes: the
# git address under the same name is red (sr#1385844), and an identity osc vc
# cannot give leaves the author unchecked, which is red too.
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-one" 2>&1)"
grep -qF "## changes-lint: rc=0" <<<"$out" && pass "author as osc vc writes it: changes-lint green" \
  || { fail "author as osc vc writes it"; printf '%s\n' "$out" | sed 's/^/    /'; }
devel "$work/git-email" 1; sed -i '2s/<jane@example.com>$/<jane@personal.example>/' "$work/git-email/foo.changes"
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/git-email" 2>&1)"
grep -qF "## changes-lint: rc=1" <<<"$out" && grep -qF "is not what osc vc writes" <<<"$out" \
  && pass "git address under the same name: changes-lint red" \
  || { fail "git address under the same name"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(VC_FAIL=1 FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-one" 2>&1)"
grep -qF "## changes-lint: rc=1" <<<"$out" && grep -qF "author not checked" <<<"$out" \
  && pass "osc vc gives no identity: changes-lint red" \
  || { fail "osc vc gives no identity"; printf '%s\n' "$out" | sed 's/^/    /'; }

# A fork-PR clone tracks the pushed fork branch, which already holds the
# change, so changes-patches compares clean against it; --git-base names the
# target's branch instead and gate.sh must pass it on. The fork's tracking
# ref is set directly: nothing is pushed, and pr-guard reads this suite.
{ g clone -q "$work/seed" "$work/forkpr" && br=$(git -C "$work/forkpr" rev-parse --abbrev-ref HEAD) \
  && cp "$work/clone/p.changes" "$work/forkpr/p.changes" && g -C "$work/forkpr" commit -qam two \
  && git -C "$work/forkpr" remote add fork "$work/fork.git" \
  && git -C "$work/forkpr" update-ref "refs/remotes/fork/$br" HEAD \
  && git -C "$work/forkpr" branch -q -u "fork/$br"; } || fail "could not build the fork-PR fixture"
out="$(bash "$GATE" "$work/forkpr" 2>&1)"
grep -qF "## changes-patches: rc=0" <<<"$out" && pass "fork-PR clone: its own upstream compares clean" \
  || { fail "fork-PR clone without --git-base"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(bash "$GATE" "$work/forkpr" --git-base "origin/$br" 2>&1)"
grep -qF "## changes-patches: rc=1" <<<"$out" && grep -qF "p.changes: 2 new entries vs origin/$br" <<<"$out" \
  && pass "fork-PR clone, --git-base origin/$br: compared against the target" \
  || { fail "fork-PR clone with --git-base"; printf '%s\n' "$out" | sed 's/^/    /'; }

# One # Legal-Review-Notice: block per License: tag. Three notices over one
# tag read to the legal reviewer as three separate claims.
mkdir -p "$work/notices"
printf 'Name: p\n# Legal-Review-Notice: relicensed to GPL-3.0.\n# Legal-Review-Notice: bundled MIT headers.\n# Legal-Review-Notice: submodules not shipped.\nLicense: GPL-3.0-only\n' > "$work/notices/p.spec"
out="$(bash "$GATE" "$work/notices" 2>&1)"
grep -qF "## spec-notices: rc=1" <<<"$out" && grep -qF "p.spec: 3 Legal-Review-Notice blocks for 1 License: tag" <<<"$out" \
  && pass "three notices over one License tag: red" \
  || { fail "three notices over one License tag"; printf '%s\n' "$out" | sed 's/^/    /'; }
mkdir -p "$work/notice-one"
printf 'Name: p\n# Legal-Review-Notice: relicensed to GPL-3.0; bundled MIT\n# headers; submodules not shipped.\nLicense: GPL-3.0-only\n' > "$work/notice-one/p.spec"
out="$(bash "$GATE" "$work/notice-one" 2>&1)"
grep -qF "## spec-notices: rc=0" <<<"$out" && pass "one itemised notice: green" \
  || { fail "one itemised notice"; printf '%s\n' "$out" | sed 's/^/    /'; }
mkdir -p "$work/notice-sub"
printf 'Name: p\n# Legal-Review-Notice: a\nLicense: MIT\n%%package data\n# Legal-Review-Notice: b\nLicense: CC-BY-4.0\n' > "$work/notice-sub/p.spec"
out="$(bash "$GATE" "$work/notice-sub" 2>&1)"
grep -qF "## spec-notices: rc=0" <<<"$out" && pass "one notice per subpackage License tag: green" \
  || { fail "one notice per subpackage License tag"; printf '%s\n' "$out" | sed 's/^/    /'; }

# Every Patch line needs a PATCH-* tag that names its file; an UPSTREAM tag
# also says where upstream has it (a devel reviewer asked on sr#1385879).
# ptag <name> <rc> <expected line> [<copy of pt-ok as a second spec>] < spec body
ptag() {
  mkdir -p "$work/pt-$1"; cat > "$work/pt-$1/p.spec"
  [ -z "${4:-}" ] || cp "$work/pt-ok/p.spec" "$work/pt-$1/$4"
  out="$(bash "$GATE" "$work/pt-$1" 2>&1)"
  grep -qF "## patch-tags: rc=$2" <<<"$out" && grep -qF -- "$3" <<<"$out" && pass "patch-tags $1 (rc=$2)" \
    || { fail "patch-tags $1: expected rc=$2 and '$3'"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
ptag ok 0 "OK: every changed patch tagged by name" <<'EOF'
Name:           p
Version:        1.2
# PATCH-FIX-OPENSUSE p-paths.patch -- use the FHS paths
Patch0:         p-paths.patch
# PATCH-FIX-UPSTREAM p-1.2-crash.patch gh#example/p#12 -- fix
#   a crash on empty input
Patch1:         %{name}-%{version}-crash.patch
# PATCH-FIX-UPSTREAM p-race.patch -- from upstream commit 1763633e5f7a
%if 0%{?suse_version} > 1600
Patch2:         p-race.patch
%endif
# PATCH-NEEDS-REBASE p-old.patch -- does not apply to 1.2 yet
Patch3:         p-old.patch
#Patch4:        p-dead.patch
# PATCH-FIX-UPSTREAM p-endian.patch fdo#63461 -- fix a crash across endianness
Patch5:         p-endian.patch
# PATCH-FIX-UPSTREAM p-url.patch -- the Patch value is the upstream commit
Patch6:         https://github.com/example/p/commit/abc1234.patch#/p-url.patch
# PATCH-FIX-UPSTREAM p-mr.patch gh#example/p!12 -- a merge request
Patch7:         p-mr.patch
# PATCH-FIX-UPSTREAM p-gcc.patch GCC#123 -- from the GCC tracker
Patch8:         p-gcc.patch
# PATCH-FIX-OPENSUSE p-arm.patch -- arm only
%ifarch aarch64
Patch9:         p-arm.patch
%endif
EOF
ptag untagged 1 "p.spec:4: p-a.patch has no PATCH-* tag in the comment above it" <<'EOF'
Name:           p
# the paths of the old layout
Patch0:         p-ok.patch
Patch1:         p-a.patch
EOF
ptag wrong-name 1 "p.spec:3: the PATCH-* tag above p-b.patch does not name it" <<'EOF'
Name:           p
# PATCH-FIX-OPENSUSE p-a.patch -- use the FHS paths
Patch1:         p-b.patch
EOF
ptag upstream-no-ref 1 "p.spec:3: the PATCH-*-UPSTREAM tag of p-a.patch cites no reference" <<'EOF'
Name:           p
# PATCH-FIX-UPSTREAM p-a.patch -- fixed upstream
Patch0:         p-a.patch
EOF
ptag hash-name-no-ref 1 "the PATCH-*-UPSTREAM tag of p-1763633e5f7a.patch cites no reference" <<'EOF'
Name:           p
# PATCH-FEATURE-UPSTREAM p-1763633e5f7a.patch -- backport
Patch0:         p-1763633e5f7a.patch
EOF
ptag name-substring 1 "p.spec:3: the PATCH-* tag above fix.patch does not name it" <<'EOF'
Name:           p
# PATCH-FIX-OPENSUSE notfix.patch fix.patch.orig -- neither is the file
Patch0:         fix.patch
EOF
ptag ref-lent 1 "p.spec:4: the PATCH-*-UPSTREAM tag of p-a.patch cites no reference" <<'EOF'
Name:           p
#Patch9:        https://example.org/p-old.patch
# PATCH-FIX-UPSTREAM p-a.patch -- fixed upstream
Patch0:         p-a.patch
EOF
ptag ref-digits 1 "p.spec:3: the PATCH-*-UPSTREAM tag of p-a.patch cites no reference" <<'EOF'
Name:           p
# PATCH-FIX-UPSTREAM p-a.patch -- sent 20240101
Patch0:         p-a.patch
EOF
ptag no-patches 0 "OK: every changed patch tagged by name" <<'EOF'
Name:           p
Source0:        p-1.2.tar.gz
EOF
ptag multibuild 1 "p.spec:2: p-a.patch has no PATCH-* tag" ok-copy.spec <<'EOF'
Name:           p
Patch0:         p-a.patch
EOF
if grep -qE '^ok-copy\.spec:[0-9]+:' <<<"$out"; then fail "patch-tags multibuild: the tagged spec was flagged"
else pass "patch-tags multibuild: only the bad spec is named"; fi

# spec-cleaner runs in the gate, every time: a fake on PATH stands in for it.
# SC_MODE: same (writes the spec back unchanged), group (adds a Group: line),
# fail (exits 1). An absent tool is red, never a pass.
mkdir -p "$work/scbin" "$work/sc"
cat > "$work/scbin/spec-cleaner" <<'EOF'
#!/bin/bash
out=; spec=
[ "$1" = --version ] && { echo "${SC_VERSION:-1.3.0}"; exit 0; }
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2;; -*) shift;; *) spec=$1; shift;; esac; done
[ -e "$out" ] && { echo "ERROR: $out already exists." >&2; exit 1; }
case "${SC_MODE:-same}" in
  fail) echo "Traceback: boom" >&2; exit 1;;
  group) { cat "$spec"; echo 'Group:          Development/Tools'; } > "$out";;
  *) cat "$spec" > "$out";;
esac
EOF
chmod +x "$work/scbin/spec-cleaner"
printf 'Name: p\nLicense: MIT\n' > "$work/sc/p.spec"
sc() { out="$(PATH="$work/scbin:$PATH" SC_MODE="$1" bash "$GATE" "$work/sc" "${@:2}" 2>&1)"; }
sc same
grep -qF "## spec-cleaner: rc=0" <<<"$out" && grep -qF "OK: spec-cleaner leaves every spec as it is" <<<"$out" \
  && pass "spec-cleaner: a clean spec is green" || { fail "spec-cleaner clean"; printf '%s\n' "$out" | sed 's/^/    /'; }
grep -qF "spec-cleaner 1.3.0" <<<"$out" && ! grep -qF "NOTE: spec-cleaner" <<<"$out" \
  && pass "spec-cleaner: the documented version is named, with no note" || { fail "spec-cleaner version 1.3.0"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(PATH="$work/scbin:$PATH" SC_VERSION=1.2.4+2 bash "$GATE" "$work/sc" 2>&1)"
grep -qF "## spec-cleaner: rc=0" <<<"$out" && grep -qF "spec-cleaner 1.2.4+2" <<<"$out" \
  && grep -qF "NOTE: spec-cleaner 1.2.4+2 is not the documented 1.3.0" <<<"$out" \
  && pass "spec-cleaner: another version is noted, not failed" || { fail "spec-cleaner version 1.2.4"; printf '%s\n' "$out" | sed 's/^/    /'; }
sc group
grep -qF "## spec-cleaner: rc=1" <<<"$out" && grep -qF "spec-cleaner would change 1 line(s) in 1 spec(s)" <<<"$out" \
  && grep -qF "+Group:" <<<"$out" && grep -q "^VERDICT: RED — .*spec-cleaner" <<<"$out" \
  && pass "spec-cleaner: a pending cleanup is red, with the lines" || { fail "spec-cleaner pending"; printf '%s\n' "$out" | sed 's/^/    /'; }
sc group --cleaner-deviation "keeps uthash-devel, no .pc"
grep -qF "## spec-cleaner: rc=0" <<<"$out" && grep -qF "DEVIATION: 1 changed line(s) kept on purpose — keeps uthash-devel, no .pc" <<<"$out" \
  && grep -qF "spec-cleaner.diff" <<<"$out" \
  && pass "spec-cleaner: a named deviation passes and keeps the diff" || { fail "spec-cleaner deviation"; printf '%s\n' "$out" | sed 's/^/    /'; }
sc fail
grep -qF "## spec-cleaner: rc=1" <<<"$out" && grep -qF "UNKNOWN: spec-cleaner failed on p.spec" <<<"$out" \
  && pass "spec-cleaner: a failed run is red, not 'no diff'" || { fail "spec-cleaner failed run"; printf '%s\n' "$out" | sed 's/^/    /'; }
sc fail --cleaner-deviation "anything"
grep -qF "## spec-cleaner: rc=1" <<<"$out" \
  && pass "spec-cleaner: a deviation never excuses a failed run" || { fail "spec-cleaner failed run with deviation"; printf '%s\n' "$out" | sed 's/^/    /'; }
mkdir -p "$work/nosc"
for t in bash cat tail head grep basename dirname tr rm mkdir awk sed env diff python3 osc git; do
  p=$(command -v "$t") && ln -sf "$p" "$work/nosc/$t"
done
out="$(PATH="$work/nosc" bash "$GATE" "$work/sc" 2>&1)"
grep -qF "## spec-cleaner: SKIPPED (not installed)" <<<"$out" && grep -q "^VERDICT: RED — .*spec-cleaner" <<<"$out" \
  && pass "spec-cleaner: not installed is red" || { fail "spec-cleaner missing"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(bash "$GATE" "$work/sc" --cleaner-deviation "" 2>&1)"; rc=$?
[ "$rc" = 2 ] && pass "--cleaner-deviation needs a reason" || fail "--cleaner-deviation empty: rc=$rc"

# factory-auto declines on source_validator's "(W) Attention, ... not mentioned"
# line although the validator exits 0 (sr#1386155: an unlisted rpmlintrc).
if [ -x /usr/lib/obs/service/source_validator ]; then
  mkdir -p "$work/lintrc"
  printf -- '-------------------------------------------------------------------\nThu Sep 17 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Initial package\n\n' \
    > "$work/lintrc/lintrc.changes"
  printf 'Name:           lintrc\nVersion:        1\nRelease:        0\nSummary:        t\nLicense:        MIT\n%%description\nt\n%%files\n%%changelog\n' \
    > "$work/lintrc/lintrc.spec"
  printf 'addFilter("no-documentation")\n' > "$work/lintrc/lintrc-rpmlintrc"
  out="$(bash "$GATE" "$work/lintrc" 2>&1)"
  grep -qF '## source_validator: rc=0' <<<"$out" && grep -qF 'factory-auto declines' <<<"$out" \
    && grep -q '^VERDICT: RED — .*source_validator' <<<"$out" \
    && pass "source_validator: an unlisted rpmlintrc is red although the validator exits 0" \
    || { fail "source_validator: unlisted rpmlintrc"; printf '%s\n' "$out" | sed 's/^/    /'; }
  sed -i 's/^License:.*/&\nSource99:       lintrc-rpmlintrc/' "$work/lintrc/lintrc.spec"
  out="$(bash "$GATE" "$work/lintrc" 2>&1)"
  grep -qF '## source_validator: rc=0' <<<"$out" && ! grep -qF 'factory-auto declines' <<<"$out" \
    && ! grep -q '^VERDICT: RED — .*source_validator' <<<"$out" \
    && pass "source_validator: a listed rpmlintrc is green" \
    || { fail "source_validator: listed rpmlintrc"; printf '%s\n' "$out" | sed 's/^/    /'; }
else
  echo "SKIP: source_validator 'not mentioned' rule (no /usr/lib/obs/service/source_validator)"
fi

# factory-auto's check_urls: every remote Source must download and equal the
# committed file (sr#1385858 re-rolled tarball, sr#1385979 a 404). A local HTTP
# server stands in for upstream.
if [ -x /usr/lib/obs/service/download_files ]; then
  mkdir -p "$work/up" "$work/urls"
  printf 'upstream\n' > "$work/up/urls-1.tar"
  python3 -I -c 'import http.server, functools, sys
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
s = http.server.HTTPServer(("127.0.0.1", 0), h)
open(sys.argv[2], "w").write(str(s.server_port))
s.serve_forever()' "$work/up" "$work/port" > /dev/null 2>&1 &
  srv=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$work/port" ] && break; sleep 0.3; done
  url="http://127.0.0.1:$(cat "$work/port")"
  printf -- '-------------------------------------------------------------------\nThu Sep 17 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Initial package\n\n' \
    > "$work/urls/urls.changes"
  urls_spec() { printf 'Name:           urls\nVersion:        1\nRelease:        0\nSummary:        t\nLicense:        MIT\nSource0:        %s\n%%description\nt\n%%files\n%%changelog\n' "$1" > "$work/urls/urls.spec"; }
  urls_spec "$url/urls-1.tar"; cp "$work/up/urls-1.tar" "$work/urls/"
  out="$(bash "$GATE" "$work/urls" 2>&1)"
  grep -qF '## download_files: rc=0' <<<"$out" && pass "download_files: an upstream-identical source is green" \
    || { fail "download_files: identical source"; printf '%s\n' "$out" | sed 's/^/    /'; }
  printf 're-rolled\n' > "$work/up/urls-1.tar"
  out="$(bash "$GATE" "$work/urls" 2>&1)"
  grep -qF '## download_files: rc=1' <<<"$out" && grep -qF 'differ' <<<"$out" \
    && grep -q '^VERDICT: RED — .*download_files' <<<"$out" \
    && pass "download_files: a re-rolled upstream file is red" \
    || { fail "download_files: re-rolled source"; printf '%s\n' "$out" | sed 's/^/    /'; }
  urls_spec "$url/v1/urls-1.tar"
  out="$(bash "$GATE" "$work/urls" 2>&1)"
  grep -qF '## download_files: rc=1' <<<"$out" && grep -qF 'Failed to download' <<<"$out" \
    && pass "download_files: a URL that does not download is red" \
    || { fail "download_files: dead URL"; printf '%s\n' "$out" | sed 's/^/    /'; }
  kill "$srv" 2>/dev/null
else
  echo "SKIP: download_files check (no /usr/lib/obs/service/download_files)"
fi

# The target: Factory's devel project unless named, and the checkout's history
# must be the target's (sr#1392134: a branch of hardware's stale copy filed to
# devel:languages:python deleted that project's newer entries). A fake OBS
# serves $OBS/<prj>/<pkg>/<file>, Factory's devel project from $OBS/devel/<pkg>,
# and a 500 for every _meta when $OBS/fail-meta exists.
mkdir -p "$work/obin"
cat > "$work/obin/osc" <<'EOF'
#!/bin/bash
case "$1" in
  develproject) [ -f "$OBS/devel/$3" ] && { cat "$OBS/devel/$3"; exit 0; } ;;
  api) case "$2" in
         */_meta) [ -e "$OBS/fail-meta" ] && { echo "Server returned an error: HTTP Error 500: Internal" >&2; exit 1; }
                  p=${2#/source/}; p=${p%/_meta}; [ -d "$OBS/$p" ] && { echo "<package name=\"${p#*/}\"/>"; exit 0; } ;;
         *'?expand=1') [ -e "$OBS/fail-list" ] && { echo "Server returned an error: HTTP Error 500: Internal" >&2; exit 1; }
                  p=${2#/source/}; p=${p%\?expand=1}
                  [ -d "$OBS/$p" ] && { echo "<directory name=\"${p#*/}\">"
                    for f in "$OBS/$p"/*; do echo "<entry name=\"$(basename "$f")\" md5=\"$(md5sum < "$f" | cut -d' ' -f1)\"/>"; done; echo "</directory>"; exit 0; } ;;
       esac ;;
  cat) [ -e "$OBS/fail-cat" ] && { echo "Server returned an error: HTTP Error 400: package 'foo-ui' does not exist" >&2; exit 1; }
       [ -f "$OBS/$2/$3/$4" ] && { cat "$OBS/$2/$3/$4"; exit 0; } ;;
  status) exit 0 ;;
  vc) printf -- '-------------------------------------------------------------------\nSun Oct 18 12:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- probe\n\n' > "$4"; exit 0 ;;
esac
echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1
EOF
chmod +x "$work/obin/osc"
O="$work/obs"
put() { mkdir -p "$O/$1" && cat > "$O/$1/$2"; }   # put <prj>/<pkg> <file> < content
e() { entry "$1 10:00:00 UTC 2026" "$2"; }
{ e "Wed Sep 16" "Update to 0.9.8"; e "Tue Sep 15" "Update to 0.9.7"; e "Mon Jan  5" "Update to 0.9.5"; } | put devel:example/foo foo.changes
printf 'Name: foo\nVersion: 0.9.8\n' | put devel:example/foo foo.spec
e "Mon Jan  5" "Update to 0.9.5" | put hardware/foo foo.changes
printf 'Name: foo\nVersion: 0.9.5\n' | put hardware/foo foo.spec
e "Mon Jan  5" "Update to 0.9.5" | put openSUSE:Factory/foo foo.changes
printf 'Name: foo\nVersion: 0.9.5\n' | put openSUSE:Factory/foo foo.spec
mkdir -p "$O/devel"; echo devel:example/foo > "$O/devel/foo"
# co <dir> <own project> <link project or -> <base file dir>: a checkout of foo
# whose committed files are the base's, plus one new entry and a 1.0 spec.
co() {
  rm -rf "$1"; mkdir -p "$1/.osc/sources"; printf 'foo\n' > "$1/.osc/_package"; printf '%s\n' "$2" > "$1/.osc/_project"
  printf '2.0\n' > "$1/.osc/_osclib_version"
  local li=""; [ "$3" = - ] || li="<linkinfo project=\"$3\" package=\"foo\" srcmd5=\"x\"/>"
  printf '<directory name="foo" rev="1">%s<entry name="foo.changes"/><entry name="foo.spec"/></directory>\n' "$li" > "$1/.osc/_files"
  cp "$4/foo.changes" "$4/foo.spec" "$1/.osc/sources/"
  { e "Thu Oct 22" "Update to 1.0"; cat "$4/foo.changes"; } > "$1/foo.changes"
  sed 's/^Version: .*/Version: 1.0/' "$4/foo.spec" > "$1/foo.spec"
}
og() { out="$(OBS=$O HOME="$work/home" PATH="$work/obin:$PATH" bash "$GATE" "$@" 2>&1)"; }
co "$work/t-wrong" 'home:<you>:spark' hardware "$O/hardware/foo"
og "$work/t-wrong"
grep -qF "## target: rc=1" <<<"$out" && grep -qF "based on hardware/foo, the SR goes to devel:example/foo" <<<"$out" \
  && pass "branch of hardware's copy, Factory develops it in devel:example: target red, names both" \
  || { fail "branch of another project's copy"; printf '%s\n' "$out" | sed 's/^/    /'; }
grep -qF "## changes-guard: rc=1" <<<"$out" && grep -qF "foo.changes vs devel:example/foo" "$work/gate-foo/changes-guard.txt" \
  && pass "branch of hardware's copy: changes-guard red against the target's .changes" \
  || { fail "branch of another project's copy: changes-guard"; printf '%s\n' "$out" | sed 's/^/    /'; }
co "$work/t-plain" hardware - "$O/hardware/foo"
og "$work/t-plain"
grep -qF "## target: rc=1" <<<"$out" && grep -qF "based on hardware/foo, the SR goes to devel:example/foo" <<<"$out" \
  && pass "plain checkout of hardware's copy: target red" || { fail "plain checkout of a stale copy"; printf '%s\n' "$out" | sed 's/^/    /'; }
og "$work/t-plain" --target hardware
grep -qF "## target: rc=0" <<<"$out" && pass "plain checkout of hardware's copy, --target hardware: target green" \
  || { fail "explicit --target of the checkout's own project"; printf '%s\n' "$out" | sed 's/^/    /'; }
# A branch of devel whose devel moved on since: the branch's own copy lacks the
# newest devel entry, so only a comparison with the target sees the deletion.
mkdir -p "$work/devel-old"; e "Mon Jan  5" "Update to 0.9.5" > "$work/devel-old/foo.changes"
cp "$O/devel:example/foo/foo.spec" "$work/devel-old/"
co "$work/t-stale" 'home:<you>:branches:devel:example' devel:example "$work/devel-old"
og "$work/t-stale"
grep -qF "## target: rc=0" <<<"$out" && grep -qF "## changes-guard: rc=1" <<<"$out" \
  && pass "stale branch of the devel project: target green, changes-guard red against devel's newer .changes" \
  || { fail "stale branch of the devel project"; printf '%s\n' "$out" | sed 's/^/    /'; }
co "$work/t-good" 'home:<you>:branches:devel:example' devel:example "$O/devel:example/foo"
og "$work/t-good"
grep -qF "## target: rc=0" <<<"$out" && grep -qF "the checkout is based on devel:example, the target is devel:example/foo" <<<"$out" \
  && grep -qF "## changes-guard: rc=0" <<<"$out" && grep -qF "## changes-patches: rc=0" <<<"$out" \
  && pass "current branch of the devel project: target, changes-guard and changes-patches green" \
  || { fail "current branch of the devel project"; printf '%s\n' "$out" | sed 's/^/    /'; }
# Patch tags against the target: a patch the target ships unchanged only gets
# a note, the same patch edited is red, and without the target's files (a new
# package there, or a failed listing) every patch counts as changed.
printf 'Name: bar\nVersion: 1\nPatch0: bar-old.patch\n' | put devel:example/bar bar.spec
echo old | put devel:example/bar bar-old.patch
e "Mon Jan  5" "Update to 1" | put devel:example/bar bar.changes
echo devel:example/bar > "$O/devel/bar"
cob() { # <dir> <project> <patch text>: a checkout of bar with the target's spec
  rm -rf "$1"; mkdir -p "$1/.osc/sources"; printf 'bar\n' > "$1/.osc/_package"; printf '%s\n' "$2" > "$1/.osc/_project"
  printf '2.0\n' > "$1/.osc/_osclib_version"
  # the committed copy is the target's, md5 and all: only the target's
  # listing, never this fallback, may call a patch unchanged
  printf '<directory name="bar" rev="1"><entry name="bar.changes"/><entry name="bar.spec"/><entry name="bar-old.patch" md5="%s"/></directory>\n' \
    "$(md5sum < "$O/devel:example/bar/bar-old.patch" | cut -d' ' -f1)" > "$1/.osc/_files"
  cp "$O/devel:example/bar/"* "$1/.osc/sources/"; cp "$O/devel:example/bar/"* "$1/"
  { e "Thu Oct 22" "Rebuild"; cat "$O/devel:example/bar/bar.changes"; } > "$1/bar.changes"
  printf '%s\n' "$3" > "$1/bar-old.patch"
}
pt() { # <name> <rc> <expected line> <gate args...>
  local n=$1 r=$2 m=$3; shift 3; og "$@"
  grep -qF "## patch-tags: rc=$r" <<<"$out" && grep -qF -- "$m" "$work/gate-bar/patch-tags.txt" && pass "patch-tags $n (rc=$r)" \
    || { fail "patch-tags $n: expected rc=$r and '$m'"; sed 's/^/    /' "$work/gate-bar/patch-tags.txt" 2>/dev/null; }
}
cob "$work/t-pt-same" 'home:<you>:branches:devel:example' old
pt untouched-note 0 "note: bar.spec:3: bar-old.patch has no PATCH-* tag in the comment above it (unchanged from the target)" "$work/t-pt-same"
cob "$work/t-pt-mod" 'home:<you>:branches:devel:example' new
pt modified-red 1 "bar.spec:3: bar-old.patch has no PATCH-* tag in the comment above it" "$work/t-pt-mod"
grep -q '^note:.*bar-old' "$work/gate-bar/patch-tags.txt" && fail "patch-tags modified-red: also printed as a note" \
  || pass "patch-tags modified-red: no note for a changed patch"
cob "$work/t-pt-new" 'home:<you>:spark' old
pt new-package-strict 1 "bar.spec:3: bar-old.patch has no PATCH-* tag" "$work/t-pt-new" --target devel:example/baz
: > "$O/fail-list"
pt listing-failure-strict 1 "note: cannot list devel:example/bar (Server returned an error: HTTP Error 500: Internal): every patch counts as changed" "$work/t-pt-same"
grep -qF "bar.spec:3: bar-old.patch has no PATCH-* tag in the comment above it" "$work/gate-bar/patch-tags.txt" \
  && ! grep -q '^note: bar.spec' "$work/gate-bar/patch-tags.txt" && pass "patch-tags listing-failure-strict: the patch is red" \
  || fail "patch-tags listing-failure-strict: the patch is not red"
rm "$O/fail-list"
: > "$O/fail-meta"; rm "$O/devel/foo"
og "$work/t-good"
grep -qF "## target: rc=1" <<<"$out" && grep -qF "could not be read (devel-of.sh exit 5)" <<<"$out" \
  && pass "Factory's devel project unreadable: target red" || { fail "devel lookup failed"; printf '%s\n' "$out" | sed 's/^/    /'; }
rm "$O/fail-meta"; echo devel:example/foo > "$O/devel/foo"
: > "$O/fail-cat"
og "$work/t-good"
grep -qF "## changes-guard: rc=1" <<<"$out" && grep -qF "UNKNOWN: osc cat devel:example foo foo.changes failed" "$work/gate-foo/changes-guard.txt" \
  && grep -qF "## spec-header: rc=1" <<<"$out" && grep -qF "UNKNOWN: osc cat devel:example foo foo.spec failed" <<<"$out" \
  && pass "the target's files unreadable: changes-guard and spec-header red, never the committed copy" \
  || { fail "target files unreadable"; printf '%s\n' "$out" | sed 's/^/    /'; }
rm "$O/fail-cat"
co "$work/t-fwd" devel:example - "$O/devel:example/foo"
og "$work/t-fwd" --target openSUSE:Factory
grep -qF "## target: rc=0" <<<"$out" && grep -qF "a forward from Factory's devel project devel:example" <<<"$out" \
  && grep -qF "## changes-guard: rc=0" <<<"$out" \
  && pass "forward from the devel project to Factory: target green, guarded against Factory's copy" \
  || { fail "forward from the devel project"; printf '%s\n' "$out" | sed 's/^/    /'; }
og "$work/t-plain" --target openSUSE:Factory
grep -qF "## target: rc=1" <<<"$out" && grep -qF "takes foo from its devel project devel:example; this checkout is based on hardware" <<<"$out" \
  && pass "Factory submission from a project that is not its devel project: target red" \
  || { fail "Factory submission from the wrong project"; printf '%s\n' "$out" | sed 's/^/    /'; }
# Most devel packages are a _link to Factory: a direct commit there is the
# devel project's own, and its committed copy is the baseline.
co "$work/t-dlink" devel:example openSUSE:Factory "$O/devel:example/foo"
og "$work/t-dlink"
grep -qF "## target: rc=0" <<<"$out" && grep -qF "## changes-guard: rc=0" <<<"$out" \
  && pass "direct commit in the devel project, its package a link to Factory: target and changes-guard green" \
  || { fail "direct devel commit of a link to Factory"; printf '%s\n' "$out" | sed 's/^/    /'; }
# A new package for a project that has no copy of it yet: nothing to rewrite.
co "$work/t-new" 'home:<you>:spark' - "$O/hardware/foo"
mkdir -p "$O/devel:other"
og "$work/t-new" --target devel:other
grep -qF "## target: rc=0" <<<"$out" && grep -qF "devel:other/foo does not exist: a new package there" <<<"$out" \
  && ! grep -qF "osc branch devel:other" <<<"$out" \
  && pass "new package named with its target: a note, not red" \
  || { fail "new package with --target"; printf '%s\n' "$out" | sed 's/^/    /'; }
# A misspelt target project is no new package: it would fall back to the
# committed copy and pass a stale branch.
og "$work/t-new" --target devel:exmaple
grep -qF "## target: rc=1" <<<"$out" && grep -qF "project devel:exmaple does not exist" <<<"$out" \
  && pass "target project that does not exist: red" \
  || { fail "missing target project"; printf '%s\n' "$out" | sed 's/^/    /'; }
e "Mon Jan  5" "Update to 0.9.5" | put openSUSE:Leap:16.0:Update/foo foo.changes
printf 'Name: foo\nVersion: 0.9.5\n' | put openSUSE:Leap:16.0:Update/foo foo.spec
co "$work/t-maint" 'home:<you>:branches:openSUSE:Leap:16.0:Update' openSUSE:Leap:16.0:Update "$O/openSUSE:Leap:16.0:Update/foo"
og "$work/t-maint"
grep -qF "## target: rc=0" <<<"$out" && grep -qF "the target is openSUSE:Leap:16.0:Update/foo" <<<"$out" \
  && pass "branch of a maintenance project: that project is the target" || { fail "maintenance branch"; printf '%s\n' "$out" | sed 's/^/    /'; }

# One spec header, and every non-SUSE copyright holder of the target kept.
hdr() { printf '#\n# spec file for package foo\n#\n# Copyright (c) %s SUSE LLC and contributors\n%s#\n\nName: foo\nVersion: 0.9.8\n' "$1" "$2"; }
hdr 2025 '# Copyright (c) 2024 Jane Maintainer <jane@example.org>
' | put devel:example/foo foo.spec
co "$work/t-hdr" 'home:<you>:branches:devel:example' devel:example "$O/devel:example/foo"
og "$work/t-hdr"
grep -qF "## spec-header: rc=0" <<<"$out" && pass "spec header: as the target has it, green" \
  || { fail "spec header unchanged"; printf '%s\n' "$out" | sed 's/^/    /'; }
hdr 2026 '# Copyright (c) 2026 Jane Maintainer <jane@example.org>
' > "$work/t-hdr/foo.spec"
og "$work/t-hdr"
grep -qF "## spec-header: rc=0" <<<"$out" && pass "spec header: SUSE and maintainer years bumped, green" \
  || { fail "spec header years bumped"; printf '%s\n' "$out" | sed 's/^/    /'; }
hdr 2026 '' > "$work/t-hdr/foo.spec"
og "$work/t-hdr"
grep -qF "## spec-header: rc=1" <<<"$out" && grep -qF "foo.spec: a copyright line of devel:example/foo is gone: # Copyright (c) 2024 Jane Maintainer" <<<"$out" \
  && pass "spec header: a maintainer's copyright line dropped, red" \
  || { fail "spec header: dropped copyright"; printf '%s\n' "$out" | sed 's/^/    /'; }
sed 's/^# Copyright (c) 2025 SUSE LLC and contributors$/# Copyright (c) 2019 SUSE LINUX GmbH, Nuernberg, Germany./' \
  "$O/devel:example/foo/foo.spec" > "$work/t-hdr/.osc/sources/foo.spec"
cp "$work/t-hdr/.osc/sources/foo.spec" "$O/devel:example/foo/foo.spec"
hdr 2026 '# Copyright (c) 2024 Jane Maintainer <jane@example.org>
' > "$work/t-hdr/foo.spec"
og "$work/t-hdr"
grep -qF "## spec-header: rc=0" <<<"$out" && pass "spec header: the old SUSE header rewritten as spec-cleaner writes it, green" \
  || { fail "spec header: SUSE header rewrite"; printf '%s\n' "$out" | sed 's/^/    /'; }
hdr 2025 '# Copyright (c) 2024 Jane Maintainer <jane@example.org>
# Copyright (c) 2015 Tony Packager <tony@suse.example>
' > "$work/t-hdr/.osc/sources/foo.spec"
cp "$work/t-hdr/.osc/sources/foo.spec" "$O/devel:example/foo/foo.spec"
hdr 2026 '# Copyright (c) 2024 Jane Maintainer <jane@example.org>
' > "$work/t-hdr/foo.spec"
og "$work/t-hdr"
grep -qF "## spec-header: rc=1" <<<"$out" && grep -qF "is gone: # Copyright (c) 2015 Tony Packager <tony@suse.example>" <<<"$out" \
  && pass "spec header: a packager's line with a SUSE address dropped, red" \
  || { fail "spec header: SUSE address exempted"; printf '%s\n' "$out" | sed 's/^/    /'; }
{ hdr 2026 '# Copyright (c) 2026 Jane Maintainer <jane@example.org>
'; printf '#\n# spec file for package foo\n#\n'; } > "$work/t-hdr/foo.spec"
og "$work/t-hdr"
grep -qF "## spec-header: rc=1" <<<"$out" && grep -qF "foo.spec: 2 '# spec file for package' headers" <<<"$out" \
  && pass "spec header: a duplicated header, red" || { fail "spec header: duplicated"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf 'Name: foo\nVersion: 0.9.8\n' | put devel:example/foo foo.spec

# The stamp and --review. A red run deletes the stamp; --review needs a GREEN
# stamp of the checkout's current tree and a PASS line naming that tree. The
# stamp is written here the way gate.sh writes it on GREEN (sha256 over
# "<md5>  <name>" lines of the files osc would commit).
co "$work/t-st" 'home:<you>:branches:devel:example' devel:example "$O/devel:example/foo"
SF="$work/home/.local/state/opensuse-packaging/gate/obs/foo/home:<you>:branches:devel:example.json"
mkstamp() {
  python3 -I - "$work/t-st" "$SF" <<'PY'
import hashlib, json, os, sys
d, path = sys.argv[1:]
fm = {n: hashlib.md5(open(os.path.join(d, n), "rb").read()).hexdigest() for n in ("foo.changes", "foo.spec")}
tree = hashlib.sha256("".join("%s  %s\n" % (m, n) for n, m in sorted(fm.items())).encode()).hexdigest()
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"project": "home:<you>:branches:devel:example", "package": "foo", "tree": tree, "files": fm,
           "verdict": "GREEN", "target": "devel:example/foo"}, open(path, "w"))
print(tree)
PY
}
rv() { out="$(HOME="$work/home" bash "$GATE" "$work/t-st" --review "$1" 2>&1)"; rc=$?; }
echo "PASS — tree 000000000000 — fine" > "$work/rv.txt"
rm -f "$SF"; rv "$work/rv.txt"
[ "$rc" = 3 ] && grep -qF "VERDICT: NO GATE" <<<"$out" && pass "--review without a GREEN gate run: no stamp, rc=3" \
  || { fail "--review without a stamp: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
T=$(mkstamp)
echo "PASS — tree ${T:0:12} — clean" > "$work/rv.txt"; rv "$work/rv.txt"
[ "$rc" = 0 ] && grep -qF "review PASS recorded for tree ${T:0:12}" <<<"$out" \
  && python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["review"]["verdict"] != "PASS")' "$SF" \
  && pass "--review: a PASS naming the stamped tree is recorded" || { fail "--review PASS: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf 'PASS — tree 0123456789ab — clean\n' > "$work/rv.txt"; rv "$work/rv.txt"
[ "$rc" = 1 ] && grep -qF "review names tree 0123456789ab, the checkout is tree ${T:0:12}" <<<"$out" \
  && ! python3 -I -c 'import json,sys; sys.exit("review" not in json.load(open(sys.argv[1])))' "$SF" \
  && pass "--review: a PASS of another tree is red and drops the recorded review" || { fail "--review other tree: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf 'BLOCK — tree %s\n' "${T:0:12}" > "$work/rv.txt"; rv "$work/rv.txt"
[ "$rc" = 1 ] && grep -qF "not PASS" <<<"$out" && pass "--review: a BLOCK is red" || { fail "--review BLOCK: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
echo "- one more bullet" >> "$work/t-st/foo.changes"
echo "PASS — tree ${T:0:12} — clean" > "$work/rv.txt"; rv "$work/rv.txt"
[ "$rc" = 3 ] && grep -qF "VERDICT: NO GATE" <<<"$out" && pass "--review: an edit after the GREEN run leaves no stamp for the new tree" \
  || { fail "--review after an edit: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(HOME="$work/home" bash "$GATE" "$work/t-st" --review "$work/rv.txt" --entries 2 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qF -- "--review records a verdict and runs no gate" <<<"$out" && pass "--review with gate options: usage" \
  || { fail "--review with gate options: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
mkstamp > /dev/null; og "$work/t-st"
grep -q "^VERDICT: RED" <<<"$out" && [ ! -e "$SF" ] && pass "a red gate run deletes the stamp" \
  || { fail "red run and the stamp"; printf '%s\n' "$out" | tail -3 | sed 's/^/    /'; }
# A GREEN run writes the stamp its GREEN line names: that needs the real OBS
# services, so only where they are installed.
if [ -x /usr/lib/obs/service/source_validator ] && [ -x /usr/lib/obs/service/download_files ]; then
  co "$work/t-green" 'home:<you>:branches:devel:example' devel:example "$O/devel:example/foo"
  printf 'Name:           foo\nVersion:        1.0\nRelease:        0\nSummary:        t\nLicense:        MIT\n%%description\nt\n%%files\n%%changelog\n' \
    > "$work/t-green/foo.spec"
  sed -i '4s/^- Update to 1.0$/- Build with the system zlib/' "$work/t-green/foo.changes"
  out="$(OBS=$O HOME="$work/home" PATH="$work/scbin:$work/obin:$PATH" SC_MODE=same bash "$GATE" "$work/t-green" 2>&1)"
  t12=$(sed -n 's/^VERDICT: GREEN — all gates passed for tree \([0-9a-f]\{12\}\) .*/\1/p' <<<"$out")
  [ -n "$t12" ] && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d["verdict"]=="GREEN" and d["tree"].startswith(sys.argv[2]) and set(d["files"])=={"foo.changes","foo.spec"}))' "$SF" "$t12" \
    && pass "a GREEN run stamps the tree its verdict names" || { fail "GREEN stamp"; printf '%s\n' "$out" | sed 's/^/    /'; }
else
  echo "SKIP: GREEN stamp (no OBS source_validator/download_files)"
fi

echo "---"; [ "$fails" = 0 ] && echo "all gate checks passed" || echo "$fails FAILED"
exit $((fails > 0))
