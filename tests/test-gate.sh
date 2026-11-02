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
export TMPDIR="$work" XDG_CACHE_HOME="$work/cache"

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

# changes-range.py is a note: what it finds is printed and never red. This
# checkout is behind its committed copy (1.2 < 1.3), which it finds without a lookup.
devel "$work/devel-older" 1; sed -i 's/^Version: 1.3$/Version: 1.2/' "$work/devel-older/foo.spec"
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-older" 2>&1)"
grep -qF "## changes-range: rc=1 (a note, never red)" <<<"$out" && grep -qF "OLDER: 1.2 here is older than 1.3" <<<"$out" \
  && grep -q '^VERDICT: ' <<<"$out" && ! grep -q '^VERDICT: RED — .*changes-range' <<<"$out" \
  && pass "changes-range: a finding is printed, never red" \
  || { fail "changes-range: the note"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-one" 2>&1)"
grep -qF "## changes-range: rc=0 (a note, never red)" <<<"$out" && grep -qF "no version change (1.3" <<<"$out" \
  && pass "changes-range: no version change against the committed copy" \
  || { fail "changes-range: no version change"; printf '%s\n' "$out" | sed 's/^/    /'; }

# --full prints changes-range's whole output, as it does every gate's: here 13
# repeated headings, more than the 12 lines a plain run shows.
devel "$work/devel-long" 1; sed -i 's/^Version: 1.3$/Version: 1.4/' "$work/devel-long/foo.spec"
for i in $(seq 13 -1 1); do printf '%s\nMon Aug %2d 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Update to 1.0.%s:\n\n' "$SEP" "$i" "$i"; done \
  > "$work/devel-long/.osc/sources/foo.changes"
{ printf '%s\nSat Sep 19 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Update to 1.4:\n' "$SEP"
  for i in $(seq 1 13); do printf '  * 1.0.%s: again\n' "$i"; done; echo; cat "$work/devel-long/.osc/sources/foo.changes"; } > "$work/devel-long/foo.changes"
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-long" --full 2>&1)"
grep -qF "changes-range: 1.3 -> 1.4 against the committed copy" <<<"$out" && grep -qF "REPEATED: 1.0.1:" <<<"$out" \
  && pass "changes-range: --full prints all of it" || { fail "changes-range --full"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-long" 2>&1)"
! grep -qF "changes-range: 1.3 -> 1.4" <<<"$out" && grep -qF "REPEATED: 1.0.13:" <<<"$out" \
  && pass "changes-range: without --full, its last 12 lines" || { fail "changes-range without --full"; printf '%s\n' "$out" | sed 's/^/    /'; }

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

# A prebuilt binary among the sources is its own red gate; an exception line
# naming it turns that gate green.
mkdir -p "$work/binary"
printf 'Name: p\nLicense: MIT\n' > "$work/binary/p.spec"
printf '\177ELF\002\001\001\000rest' > "$work/binary/esbuild"
out="$(XDG_CACHE_HOME="$work/cache" bash "$GATE" "$work/binary" 2>&1)"
grep -qF "## source-binaries: rc=3" <<<"$out" && grep -qF "HIT esbuild: ELF" <<<"$out" \
  && grep -q "^VERDICT: RED — .*source-binaries" <<<"$out" \
  && pass "a prebuilt binary in the sources: source-binaries is red" \
  || { fail "prebuilt binary in the sources"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf '# Source-Binary-Exception: esbuild -- firmware: a blob no source exists for\n' >> "$work/binary/p.spec"
out="$(XDG_CACHE_HOME="$work/cache" bash "$GATE" "$work/binary" 2>&1)"
grep -qF "## source-binaries: rc=0" <<<"$out" && pass "the binary named by an exception: source-binaries is green" \
  || { fail "excepted binary"; printf '%s\n' "$out" | sed 's/^/    /'; }
# --rpms reaches the scan: a directory without a binary RPM is no clean bill.
mkdir -p "$work/norpms"
out="$(XDG_CACHE_HOME="$work/cache" bash "$GATE" "$work/binary" --rpms "$work/norpms" 2>&1)"
grep -qF "## source-binaries: rc=2" <<<"$out" && grep -qF "no binary RPM to read" <<<"$out" \
  && pass "--rpms reaches source-binaries.py" || { fail "--rpms passthrough"; printf '%s\n' "$out" | sed 's/^/    /'; }

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
# unbrace (%{opt_macro} -> %opt_macro, as 1.3.2 does to %{cargo_build}), fail
# (exits 1). An absent tool is red, never a pass.
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
  unbrace) sed 's/%{opt_macro}/%opt_macro/' "$spec" > "$out";;
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
# A tag the target's spec had right cannot be lost, even on an unchanged patch.
cob "$work/t-pt-lost" 'home:<you>:branches:devel:example' old
printf 'Name: bar\nVersion: 1\n# PATCH-FIX-OPENSUSE bar-old.patch -- the old layout\nPatch0: bar-old.patch\n' | put devel:example/bar bar.spec
pt tag-lost 1 "bar.spec:3: bar-old.patch has no PATCH-* tag in the comment above it" "$work/t-pt-lost"
grep -q '^note:.*bar-old' "$work/gate-bar/patch-tags.txt" && fail "patch-tags tag-lost: printed as a note" \
  || pass "patch-tags tag-lost: red, not a note"
printf 'Name: bar\nVersion: 1\nPatch0: bar-old.patch\n' | put devel:example/bar bar.spec
# Git: a pushed fork branch already holds the change, so it is no base: every
# patch counts as changed until --git-base names the target's ref.
g="$work/gz"; rm -rf "$g"; mkdir -p "$g"
( cd "$g" && git init -q -b factory && git config user.email t@example.com && git config user.name T \
  && printf 'Name: gz\nPatch0: gz-a.patch\nPatch1: gz-b.patch\n' > gz.spec && echo a > gz-a.patch && echo b > gz-b.patch \
  && git add -A && git commit -qm base && git checkout -qb fork && echo a2 > gz-a.patch && git commit -qam edit \
  && git branch -q pushed && git branch -q -u pushed ) || fail "git fixture"
gt() { # <name> <rc> <expected line> [gate args]: patch-tags of the git checkout
  local n=$1 r=$2 m=$3; shift 3; out="$(OBS=$O HOME="$work/home" PATH="$work/obin:$PATH" bash "$GATE" "$g" "$@" 2>&1)"
  grep -qF "## patch-tags: rc=$r" <<<"$out" && grep -qF -- "$m" "$work/gate-gz/patch-tags.txt" && pass "patch-tags $n (rc=$r)" \
    || { fail "patch-tags $n: expected rc=$r and '$m'"; sed 's/^/    /' "$work/gate-gz/patch-tags.txt" 2>/dev/null; }
}
gt git-fork-strict 1 "gz.spec:3: gz-b.patch has no PATCH-* tag in the comment above it"
grep -qF "note: pushed already holds HEAD" "$work/gate-gz/patch-tags.txt" && pass "patch-tags git-fork-strict: says why" \
  || fail "patch-tags git-fork-strict: no note on the pushed branch"
gt git-base-target 1 "gz.spec:2: gz-a.patch has no PATCH-* tag in the comment above it" --git-base factory
grep -qF "note: gz.spec:3: gz-b.patch has no PATCH-* tag in the comment above it (unchanged from the target)" "$work/gate-gz/patch-tags.txt" \
  && pass "patch-tags git-base-target: the unchanged patch is a note" || fail "patch-tags git-base-target: the unchanged patch is not a note"
# Uncommitted edits on a clone of the remote's default branch: HEAD is the
# base there, which is evidence (the normal pre-commit run), with or without
# an explicit --git-base, which is never overridden.
r="$work/gzr.git"; c="$work/gzc"; rm -rf "$r" "$c"
( git clone -q --bare --branch factory "$g" "$r" && git clone -q "$r" "$c" \
  && cd "$c" && echo a3 > gz-a.patch ) || fail "git clone fixture"
for args in "" "--git-base origin/factory"; do
  # shellcheck disable=SC2086  # $args is zero or two words
  out="$(OBS=$O HOME="$work/home" PATH="$work/obin:$PATH" bash "$GATE" "$c" $args 2>&1)"
  grep -qF "## patch-tags: rc=1" <<<"$out" && grep -qF "gz.spec:2: gz-a.patch has no PATCH-* tag" "$work/gate-gzc/patch-tags.txt" \
    && grep -qF "note: gz.spec:3: gz-b.patch has no PATCH-* tag in the comment above it (unchanged from the target)" "$work/gate-gzc/patch-tags.txt" \
    && pass "patch-tags uncommitted edit on the default branch${args:+, $args}: only the edited patch is red" \
    || { fail "patch-tags uncommitted edit on the default branch${args:+, $args}"; sed 's/^/    /' "$work/gate-gzc/patch-tags.txt" 2>/dev/null; }
done
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
# The option assembled at run time: pr-guard reads this suite, and asks before a review recorded by literal.
REV=$(printf -- '--%s' review)
rv() { out="$(HOME="$work/home" bash "$GATE" "$work/t-st" "$REV" "$1" 2>&1)"; rc=$?; }
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
out="$(HOME="$work/home" bash "$GATE" "$work/t-st" "$REV" "$work/rv.txt" --entries 2 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qF -- "--review records a verdict and runs no gate" <<<"$out" && pass "--review with gate options: usage" \
  || { fail "--review with gate options: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

# --obs-build records OBS's build of the stamped tree, gate 1 in OBS-ONLY mode:
# every repo/arch succeeded from the sources OBS holds, those are the stamped
# files, and each log reads GREEN in build-summary.sh. A fake osc serves the
# listing, the results and the logs from $OB.
P='home:<you>:branches:devel:example'
mkdir -p "$work/obbin" "$work/ob"
cat > "$work/obbin/osc" <<'EOF'
#!/bin/bash
P='home:<you>:branches:devel:example'
case "$1" in
  api) [ "$2" = "/source/$P/foo?expand=1" ] && [ -f "$OB/listing.xml" ] && { cat "$OB/listing.xml"; exit 0; } ;;
  results) [ "$*" = "results --xml $P foo" ] && [ -f "$OB/results.xml" ] && { cat "$OB/results.xml"; exit 0; } ;;
  rbl) [ -z "${MUTATE:-}" ] || python3 -I -c 'import json, sys
st = json.load(open(sys.argv[1])); st["review"] = {"verdict": "PASS"}; json.dump(st, open(sys.argv[1], "w"))' "$MUTATE"
       [ "$2" = "$P" ] && [ -f "$OB/log-$4-$5-$3" ] && { cat "$OB/log-$4-$5-$3"; exit 0; } ;;
esac
echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1
EOF
chmod +x "$work/obbin/osc"
co "$work/t-ob" "$P" devel:example "$O/devel:example/foo"
md5_() { md5sum < "$1" | cut -d' ' -f1; }
SRC=0123456789abcdef0123456789abcdef
listing() {   # <md5 of foo.spec>
  printf '<directory name="foo" srcmd5="%s"><entry name="_link" md5="1"/><entry name="foo.changes" md5="%s"/><entry name="foo.spec" md5="%s"/></directory>\n' \
    "$SRC" "$(md5_ "$work/t-ob/foo.changes")" "$1" > "$work/ob/listing.xml"
}
results() {   # <code for openSUSE_Tumbleweed/aarch64>
  { printf '<resultlist><result repository="openSUSE_Tumbleweed" arch="x86_64"><status package="foo" code="succeeded"/></result>'
    printf '<result repository="openSUSE_Tumbleweed" arch="aarch64"><status package="foo" code="%s"/></result>' "$1"
    printf '<result repository="16.0" arch="x86_64"><status package="foo" code="disabled"/></result></resultlist>\n'
  } > "$work/ob/results.xml"
}
blog() {   # <arch> <srcmd5> <finished|failed> [extra line]
  { printf "[    0s] Building foo for project '%s' repository 'openSUSE_Tumbleweed' arch '%s' srcmd5 '%s'\n" "$P" "$1" "$2"
    [ -z "${4:-}" ] || printf '%s\n' "$4"
    printf '[  100s] ... %s "build foo.spec" at Mon Nov  2 2026.\n' "$3"; } > "$work/ob/log-openSUSE_Tumbleweed-$1-foo"
}
SO="$work/home/.local/state/opensuse-packaging/gate/obs/foo/$P.json"
obstamp() {   # gate.sh's GREEN stamp of t-ob as it stands
  python3 -I - "$work/t-ob" "$SO" "$P" <<'PY'
import hashlib, json, os, sys
d, path, prj = sys.argv[1:]
fm = {n: hashlib.md5(open(os.path.join(d, n), "rb").read()).hexdigest() for n in ("foo.changes", "foo.spec")}
tree = hashlib.sha256("".join("%s  %s\n" % (m, n) for n, m in sorted(fm.items())).encode()).hexdigest()
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"project": prj, "package": "foo", "tree": tree, "files": fm, "verdict": "GREEN"}, open(path, "w"))
print(tree)
PY
}
sv() { python3 -I -c 'import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else v)' "$1" "$2" 2>/dev/null; }
ob() { out="$(OB="$work/ob" HOME="$work/home" PATH="$work/obbin:$PATH" bash "$GATE" "$work/t-ob" --obs-build "$@" 2>&1)"; rc=$?; }
listing "$(md5_ "$work/t-ob/foo.spec")"; results succeeded
blog x86_64 "$SRC" finished; blog aarch64 "$SRC" finished
rm -f "$SO"; ob
[ "$rc" = 3 ] && grep -qF "VERDICT: NO GATE" <<<"$out" && pass "--obs-build without a GREEN gate run: rc=3" \
  || { fail "--obs-build without a stamp: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
TO=$(obstamp); ob
[ "$rc" = 0 ] && grep -qF "OBS build of tree ${TO:0:12} recorded" <<<"$out" && [ "$(sv "$SO" build.kind)" = obs ] \
  && [ "$(sv "$SO" build.srcmd5)" = "$SRC" ] && [ "$(sv "$SO" build.verdict)" = GREEN ] \
  && pass "--obs-build: every repo green from the stamped files, each log GREEN: recorded" \
  || { fail "--obs-build green: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
results building; ob
[ "$rc" = 4 ] && grep -qF "PENDING" <<<"$out" && grep -qF "openSUSE_Tumbleweed/aarch64" <<<"$out" \
  && pass "--obs-build: an arch still building is pending (rc=4)" || { fail "--obs-build building: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
results succeeded; blog aarch64 fedcba9876543210fedcba9876543210 finished; ob
[ "$rc" = 4 ] && grep -qF "built from older sources" <<<"$out" \
  && pass "--obs-build: a log of older sources is pending (rc=4)" || { fail "--obs-build older log: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
listing 00000000000000000000000000000000; blog aarch64 "$SRC" finished; ob
[ "$rc" = 1 ] && grep -qF "OBS holds other files than tree ${TO:0:12}" <<<"$out" && grep -qF "foo.spec" <<<"$out" \
  && pass "--obs-build: OBS holding other files than the stamped tree is red" \
  || { fail "--obs-build other files: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
rm -f "$work/ob/listing.xml"; ob
[ "$rc" = 1 ] && grep -qF "UNKNOWN" <<<"$out" && [ "$(sv "$SO" build.kind)" = obs ] \
  && pass "--obs-build: a failed listing lookup is UNKNOWN, rc=1, the recorded build kept" \
  || { fail "--obs-build listing lookup failed: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
listing "$(md5_ "$work/t-ob/foo.spec")"
blog aarch64 "$SRC" finished '[   90s] foo-1.0-1.1.aarch64.rpm: directories not owned by a package:
[   90s]  - /usr/share/zsh'; ob
[ "$rc" = 1 ] && grep -qF "openSUSE_Tumbleweed/aarch64" <<<"$out" && grep -qF "post-build check" <<<"$out" \
  && [ -z "$(sv "$SO" build)" ] \
  && pass "--obs-build: a succeeded build whose log build-summary.sh calls red is red, the recorded build dropped" \
  || { fail "--obs-build red log: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
blog aarch64 "$SRC" finished; results failed; blog aarch64 "$SRC" failed; ob
[ "$rc" = 1 ] && grep -qF "FAILED" <<<"$out" && grep -qF "openSUSE_Tumbleweed/aarch64" <<<"$out" \
  && pass "--obs-build: a failed build of the current sources is red" || { fail "--obs-build failed: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
results succeeded; blog aarch64 "$SRC" finished
rx() { printf '<resultlist>%s</resultlist>\n' "$1" > "$work/ob/results.xml"; }
st_() { printf '<result repository="openSUSE_Tumbleweed" arch="%s"%s><status package="%s" code="%s"/></result>' "$@"; }
ob
[ "$rc" = 0 ] && [ "$(sv "$SO" build.kind)" = obs ] || { fail "--obs-build: no build recorded to keep"; printf '%s\n' "$out" | sed 's/^/    /'; }
# What the gate cannot judge keeps the recorded build: UNKNOWN, rc=1.
for c in "empty:" "disabled:$(st_ x86_64 '' foo disabled)$(st_ aarch64 '' foo excluded)" \
         "locked:$(st_ x86_64 '' foo succeeded)$(st_ aarch64 '' foo locked)"; do
  rx "${c#*:}"; ob
  [ "$rc" = 1 ] && grep -qF "VERDICT: UNKNOWN" <<<"$out" && grep -qF "the recorded build stays" <<<"$out" \
    && [ "$(sv "$SO" build.kind)" = obs ] \
    && pass "--obs-build: ${c%%:*} results are UNKNOWN and keep the recorded build" \
    || { fail "--obs-build ${c%%:*} results: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
done
rm -f "$work/ob/results.xml"; ob
[ "$rc" = 1 ] && grep -qF "UNKNOWN" <<<"$out" && [ "$(sv "$SO" build.kind)" = obs ] \
  && pass "--obs-build: a failed results lookup is UNKNOWN, the recorded build kept" \
  || { fail "--obs-build results lookup failed: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
results succeeded; mv "$work/ob/log-openSUSE_Tumbleweed-aarch64-foo" "$work/ob/away.log"; ob
[ "$rc" = 1 ] && grep -qF "cannot read the build log of openSUSE_Tumbleweed/aarch64" <<<"$out" && [ "$(sv "$SO" build.kind)" = obs ] \
  && pass "--obs-build: a failed log lookup is UNKNOWN, the recorded build kept" \
  || { fail "--obs-build log lookup failed: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
mv "$work/ob/away.log" "$work/ob/log-openSUSE_Tumbleweed-aarch64-foo"
rx "$(st_ x86_64 ' dirty="true"' foo succeeded)$(st_ aarch64 '' foo succeeded)"; ob
[ "$rc" = 4 ] && grep -qF "openSUSE_Tumbleweed/x86_64 dirty" <<<"$out" \
  && pass "--obs-build: a dirty repository is pending (rc=4)" || { fail "--obs-build dirty: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
rx "$(st_ x86_64 '' foo succeeded)$(st_ aarch64 '' foo succeeded)$(st_ aarch64 '' bar failed)$(st_ aarch64 '' foobar broken)"; ob
[ "$rc" = 0 ] && pass "--obs-build: other packages' rows are not this package's" \
  || { fail "--obs-build other packages' rows: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
rx "$(st_ x86_64 '' foo succeeded)$(st_ aarch64 '' foo succeeded)$(st_ x86_64 '' foo:test succeeded)"; ob
[ "$rc" = 1 ] && grep -qF "cannot read the build log of openSUSE_Tumbleweed/x86_64:test" <<<"$out" \
  && pass "--obs-build: a flavor's log is read too (here missing: UNKNOWN)" || { fail "--obs-build flavor without a log: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
cp "$work/ob/log-openSUSE_Tumbleweed-x86_64-foo" "$work/ob/log-openSUSE_Tumbleweed-x86_64-foo:test"; ob
[ "$rc" = 0 ] && grep -qF "openSUSE_Tumbleweed/x86_64:test" <<<"$out" \
  && pass "--obs-build: every flavor's log GREEN: recorded" || { fail "--obs-build flavors: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
results succeeded; MUTATE="$SO" ob
[ "$rc" = 0 ] && [ "$(sv "$SO" review.verdict)" = PASS ] && [ "$(sv "$SO" build.kind)" = obs ] \
  && pass "--obs-build: a review recorded during the run stays in the stamp" \
  || { fail "--obs-build loses a review recorded meanwhile: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
rx "$(st_ x86_64 '' foo succeeded)$(st_ aarch64 '' foo unresolvable)"; ob
[ "$rc" = 1 ] && grep -qF "VERDICT: RED" <<<"$out" && [ -z "$(sv "$SO" build)" ] && [ "$(sv "$SO" review.verdict)" = PASS ] \
  && pass "--obs-build: unresolvable is red and drops the recorded build, not the review" \
  || { fail "--obs-build unresolvable: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
results succeeded
ob --entries 2
[ "$rc" = 2 ] && grep -qF -- "--obs-build records OBS's build and runs no gate" <<<"$out" \
  && pass "--obs-build with gate options: usage" || { fail "--obs-build with gate options: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
mkdir -p "$work/obrpms"; ob --rpms "$work/obrpms"
[ "$rc" = 1 ] && grep -qF "source-binaries" <<<"$out" && [ -z "$(sv "$SO" rpms)" ] \
  && pass "--obs-build --rpms: the shipped-binary check runs, and its red records nothing" \
  || { fail "--obs-build --rpms red: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
if command -v rpmbuild > /dev/null && command -v rpm2cpio > /dev/null; then
  mkdir -p "$work/obrpm/SPECS"
  printf 'Name: t\nVersion: 1\nRelease: 0\nSummary: t\nLicense: MIT\nBuildArch: noarch\n%%description\nt\n%%install\nmkdir -p %%{buildroot}/usr/share/t\necho t > %%{buildroot}/usr/share/t/t.txt\n%%files\n/usr/share/t\n' \
    > "$work/obrpm/SPECS/t.spec"
  rpmbuild -bb --quiet --define "_topdir $work/obrpm" "$work/obrpm/SPECS/t.spec" > /dev/null 2>&1
  ob --rpms "$work/obrpm/RPMS"
  [ "$rc" = 0 ] && [ "$(sv "$SO" rpms.dir)" = "$work/obrpm/RPMS" ] && [ "$(sv "$SO" build.kind)" = obs ] \
    && pass "--obs-build --rpms: the shipped-binary check of the built RPMs is recorded" \
    || { fail "--obs-build --rpms green: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
else
  echo "SKIP: --obs-build --rpms green (no rpmbuild/rpm2cpio)"
fi

# --build-log is checked against the tree: gate.sh's Python, read out of it, runs
# here without the OBS services the full gate needs.
sed -n "/^read -r -d '' PY <<'PYEOF'\$/,/^PYEOF\$/p" "$GATE" | sed '1d;$d' > "$work/gate-py.py"
pyg() { out="$(python3 -I "$work/gate-py.py" "$@" 2>&1)"; rc=$?; }
co "$work/t-bl" "$P" devel:example "$O/devel:example/foo"
now=$(LC_ALL=C date -u '+%a %b %e %H:%M:%S UTC %Y')
blog_() {   # <file> <started date> <srpm n-v-r or -> <spec>
  { printf '[    1s] host started "build %s" at %s.\n' "$4" "$2"
    [ "$3" = - ] || printf '[   90s] Wrote: /home/abuild/rpmbuild/SRPMS/%s.src.rpm\n' "$3"
    printf '[  100s] host finished "build %s" at %s.\n' "$4" "$2"; } > "$1"
}
blog_ "$work/bl-ok.log" "$now" foo-1.0-0 foo.spec
blog_ "$work/bl-ok2.log" "$now" foo-1.0-0 foo.spec; echo '[  101s] second flavor' >> "$work/bl-ok2.log"
blog_ "$work/bl-old.log" "$now" foo-0.9.8-0 foo.spec
blog_ "$work/bl-other.log" "$now" bar-1.0-0 bar.spec
blog_ "$work/bl-nosrpm.log" "$now" - foo.spec
blog_ "$work/bl-stale.log" "Mon Jan  6 10:00:00 UTC 2020" foo-1.0-0 foo.spec
bl() {   # <name> <rc> <message> <logs...>
  local name=$1 want=$2 msg=$3; shift 3
  pyg buildlogs "$work/t-bl" "$@"
  [ "$rc" = "$want" ] && grep -qF -- "$msg" <<<"$out" && pass "--build-log $name (rc=$want)" \
    || { fail "--build-log $name: want rc=$want and '$msg', got rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
bl "a build of this tree" 0 "OK: 1 log(s), each a build of this tree" "$work/bl-ok.log"
bl "of the previous version" 1 "built foo-0.9.8-0, the spec says foo 1.0" "$work/bl-old.log"
bl "of another package" 1 "built bar.spec, not this checkout's foo.spec" "$work/bl-other.log"
bl "with no source RPM" 1 "names no source RPM it wrote" "$work/bl-nosrpm.log"
bl "started before the last edit" 1 "foo.spec changed after $work/bl-stale.log started: rebuild" "$work/bl-stale.log"
touch "$work/t-bl/foo.changes"
bl "older than a .changes edit" 0 "OK: 1 log(s)" "$work/bl-ok.log"
# A _multibuild package builds the base package and each flavor: one log each,
# the base only when the spec does not exclude it.
blog_ "$work/bl-ok3.log" "$now" foo-1.0-0 foo.spec; echo '[  102s] third build' >> "$work/bl-ok3.log"
printf '<multibuild>\n  <flavor>test</flavor>\n  <flavor>gui</flavor>\n</multibuild>\n' > "$work/t-bl/_multibuild"
bl "of one build of three" 1 "3 build(s) (the base package, test, gui), 1 distinct build log(s): pass --build-log once per build" "$work/bl-ok.log"
bl "the same log twice" 1 "1 distinct build log(s)" "$work/bl-ok.log" "$work/bl-ok.log"
bl "one per flavor, not the base" 1 "2 distinct build log(s)" "$work/bl-ok.log" "$work/bl-ok2.log"
bl "one per build" 0 "OK: 3 log(s)" "$work/bl-ok.log" "$work/bl-ok2.log" "$work/bl-ok3.log"
co "$work/t-nobase" "$P" devel:example "$O/devel:example/foo"
printf '%%if "%%{flavor}" == ""\nExclusiveArch:  do_not_build\n%%endif\n' >> "$work/t-nobase/foo.spec"
cp "$work/t-bl/_multibuild" "$work/t-nobase/"
now=$(LC_ALL=C date -u '+%a %b %e %H:%M:%S UTC %Y')   # after the edit
blog_ "$work/nb1.log" "$now" foo-1.0-0 foo.spec; blog_ "$work/nb2.log" "$now" foo-1.0-0 foo.spec; echo '[  101s] gui' >> "$work/nb2.log"
pyg buildlogs "$work/t-nobase" "$work/nb1.log" "$work/nb2.log"
[ "$rc" = 0 ] && pass "--build-log: a spec that excludes the base package needs one log per flavor" \
  || { fail "--build-log base excluded: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# do-not-build is spelled with dashes too.
sed -i 's/^ExclusiveArch:  do_not_build$/ExclusiveArch:  do-not-build/' "$work/t-nobase/foo.spec"
now=$(LC_ALL=C date -u '+%a %b %e %H:%M:%S UTC %Y')
blog_ "$work/nb1.log" "$now" foo-1.0-0 foo.spec; blog_ "$work/nb2.log" "$now" foo-1.0-0 foo.spec; echo '[  101s] gui' >> "$work/nb2.log"
pyg buildlogs "$work/t-nobase" "$work/nb1.log" "$work/nb2.log"
[ "$rc" = 0 ] && pass "--build-log: ExclusiveArch: do-not-build excludes the base package too" \
  || { fail "--build-log do-not-build: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# The same through a macro that holds the flavor, as postgresql extensions write it.
sed -i 's/^%if "%{flavor}" == ""$/%if "%{pg_name}" == ""/' "$work/t-nobase/foo.spec"
printf '%%define pg_name @BUILD_FLAVOR@%%{nil}\n' >> "$work/t-nobase/foo.spec"
now=$(LC_ALL=C date -u '+%a %b %e %H:%M:%S UTC %Y')
blog_ "$work/nb1.log" "$now" foo-1.0-0 foo.spec; blog_ "$work/nb2.log" "$now" foo-1.0-0 foo.spec; echo '[  101s] gui' >> "$work/nb2.log"
pyg buildlogs "$work/t-nobase" "$work/nb1.log" "$work/nb2.log"
[ "$rc" = 0 ] && pass "--build-log: the base package excluded through a macro holding the flavor" \
  || { fail "--build-log base excluded through pg_name: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
rm "$work/t-bl/_multibuild"
# A python _multibuild spec (python-ruff's header): its Name carries the flavor, and
# the flavor's psuffix is defined before the base's. Each build is a source RPM of its own.
pyco() {   # <dir>: a checkout of python-ruff with the fixture's spec and a test flavor
  mkdir -p "$1/.osc" && printf 'python-ruff\n' > "$1/.osc/_package" && printf 'devel:languages:python\n' > "$1/.osc/_project"
  printf '<directory name="python-ruff"><entry name="python-ruff.changes"/><entry name="python-ruff.spec"/></directory>\n' > "$1/.osc/_files"
  cp "$HERE/fixtures/gate/python-ruff.spec" "$1/"; e "Mon Nov  2" "Update to 0.17.3" > "$1/python-ruff.changes"
  printf '<multibuild>\n  <flavor>test</flavor>\n</multibuild>\n' > "$1/_multibuild"
}
pyco "$work/t-py"
now=$(LC_ALL=C date -u '+%a %b %e %H:%M:%S UTC %Y')
blog_ "$work/py-main.log" "$now" python-ruff-0.17.3-0 python-ruff.spec
blog_ "$work/py-main2.log" "$now" python-ruff-0.17.3-0 python-ruff.spec; echo '[  101s] again' >> "$work/py-main2.log"
blog_ "$work/py-test.log" "$now" python-ruff-test-0.17.3-0 python-ruff.spec
pybl() {   # <name> <rc> <message> <logs...>
  local name=$1 want=$2 msg=$3; shift 3
  pyg buildlogs "$work/t-py" "$@"
  [ "$rc" = "$want" ] && grep -qF -- "$msg" <<<"$out" && pass "--build-log python multibuild: $name (rc=$want)" \
    || { fail "--build-log python multibuild $name: want rc=$want and '$msg', got rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
pybl "the main and the test flavor" 0 "OK: 2 log(s)" "$work/py-main.log" "$work/py-test.log"
pybl "the main flavor alone" 1 "2 build(s) (the base package, test)" "$work/py-main.log"
pybl "the main flavor twice" 1 "1 distinct source RPM(s)" "$work/py-main.log" "$work/py-main2.log"
# %{?psuffix} with psuffix defined for one flavor only is empty in the base build.
mkdir -p "$work/t-hw/.osc" && printf 'halloween-openSUSE\n' > "$work/t-hw/.osc/_package" && printf 'X11:Utilities\n' > "$work/t-hw/.osc/_project"
printf '<directory name="halloween-openSUSE"><entry name="halloween-openSUSE.spec"/></directory>\n' > "$work/t-hw/.osc/_files"
cp "$HERE/fixtures/gate/halloween-openSUSE.spec" "$work/t-hw/"
printf '<multibuild>\n  <flavor>firefox</flavor>\n</multibuild>\n' > "$work/t-hw/_multibuild"
now=$(LC_ALL=C date -u '+%a %b %e %H:%M:%S UTC %Y')
blog_ "$work/hw-base.log" "$now" halloween-openSUSE-2026.10.6-1.1 halloween-openSUSE.spec
blog_ "$work/hw-ff.log" "$now" halloween-openSUSE-firefox-theme-2026.10.6-1.1 halloween-openSUSE.spec
pyg buildlogs "$work/t-hw" "$work/hw-base.log" "$work/hw-ff.log"
[ "$rc" = 0 ] && pass "--build-log: %{?macro} in Name is empty in the base build" \
  || { fail "--build-log %{?psuffix} base: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# A checkout with no spec (kiwi, Dockerfile) writes no source RPM: its recipe is checked.
mkdir -p "$work/t-kiwi/.osc" && printf 'img\n' > "$work/t-kiwi/.osc/_package" && printf 'devel:example\n' > "$work/t-kiwi/.osc/_project"
printf '<directory name="img"><entry name="img.kiwi"/></directory>\n' > "$work/t-kiwi/.osc/_files"; printf '<image/>\n' > "$work/t-kiwi/img.kiwi"
now=$(LC_ALL=C date -u '+%a %b %e %H:%M:%S UTC %Y')
blog_ "$work/kiwi.log" "$now" - img.kiwi; blog_ "$work/kiwi-other.log" "$now" - other.kiwi
pyg buildlogs "$work/t-kiwi" "$work/kiwi.log"
[ "$rc" = 0 ] && pass "--build-log: a build of a checkout with no spec needs no source RPM" \
  || { fail "--build-log kiwi: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
pyg buildlogs "$work/t-kiwi" "$work/kiwi-other.log"
[ "$rc" = 1 ] && grep -qF "built other.kiwi, which this checkout does not have" <<<"$out" \
  && pass "--build-log: a log of another recipe is red there too" || { fail "--build-log kiwi other recipe: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# The stamp: a build of the logs; a rerun of the tree keeps it, a .changes-only edit
# carries it, any other edit drops it.
SL="$work/home/.local/state/opensuse-packaging/gate/obs/foo/t-bl.json"
pyg stamp "$SL" "$work/t-bl" t-bl foo "" "" "$work/bl-ok.log"
[ "$rc" = 0 ] && [ "$(sv "$SL" build.kind)" = log ] && [ "$(sv "$SL" build.log)" = "$work/bl-ok.log" ] \
  && grep -qF "build: $work/bl-ok.log" <<<"$out" && pass "stamp: the logs are the tree's build" \
  || { fail "stamp records the logs: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
t1=$(sv "$SL" tree)
pyg stamp "$SL" "$work/t-bl" t-bl foo "" ""
[ "$(sv "$SL" build.kind)" = log ] && [ -z "$(sv "$SL" build.carried)" ] && pass "stamp: a rerun of the same tree keeps its build" \
  || { fail "stamp rerun keeps the build"; printf '%s\n' "$out" | sed 's/^/    /'; }
echo "  * one more bullet" >> "$work/t-bl/foo.changes"
pyg stamp "$SL" "$work/t-bl" t-bl foo "" ""
[ "$(sv "$SL" build.kind)" = log ] && [ "$(sv "$SL" build.carried)" = "${t1:0:12}" ] \
  && pass "stamp: a .changes-only edit carries the build to the new tree" || { fail "stamp .changes-only carry"; printf '%s\n' "$out" | sed 's/^/    /'; }
echo "Summary: t" >> "$work/t-bl/foo.spec"
pyg stamp "$SL" "$work/t-bl" t-bl foo "" ""
[ -z "$(sv "$SL" build)" ] && grep -qF "build: none recorded" <<<"$out" \
  && pass "stamp: a spec edit leaves the new tree without a build" || { fail "stamp spec edit drops the build"; printf '%s\n' "$out" | sed 's/^/    /'; }

mkstamp > /dev/null; og "$work/t-st"
grep -q "^VERDICT: RED" <<<"$out" && [ ! -e "$SF" ] && pass "a red gate run deletes the stamp" \
  || { fail "red run and the stamp"; printf '%s\n' "$out" | tail -3 | sed 's/^/    /'; }
grep -qF "## tracked: rc=0" <<<"$out" && pass "a checkout whose files osc tracks: tracked green" \
  || { fail "tracked checkout: tracked not green"; printf '%s\n' "$out" | sed 's/^/    /'; }
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
  grep -qF "note: no --rpms DIR" <<<"$out" && [ -z "$(sv "$SF" build)" ] \
    && pass "a GREEN run without --build-log or --rpms records no build and says the RPMs went unchecked" \
    || { fail "GREEN run without build evidence"; printf '%s\n' "$out" | sed 's/^/    /'; }
  # --build-log through the whole gate: another package's log is red; a log, or a
  # build root as build-summary.sh takes it, is recorded; a missing one is red.
  gg() { out="$(OBS=$O HOME="$work/home" PATH="$work/scbin:$work/obin:$PATH" SC_MODE=same bash "$GATE" "$work/t-green" "$@" 2>&1)"; rc=$?; }
  now=$(LC_ALL=C date -u '+%a %b %e %H:%M:%S UTC %Y')
  blog_ "$work/bar-build.log" "$now" bar-1.0-0 bar.spec
  blog_ "$work/foo-build.log" "$now" foo-1.0-0 foo.spec
  gg --build-log "$work/bar-build.log"
  grep -q "^VERDICT: RED — .*build-summary" <<<"$out" && grep -qF "built bar.spec, not this checkout's foo.spec" <<<"$out" \
    && pass "--build-log of another package's spec: red" || { fail "--build-log of another spec"; printf '%s\n' "$out" | sed 's/^/    /'; }
  gg --build-log "$work/foo-build.log"
  [ "$(sv "$SF" build.kind)" = log ] && [ "$(sv "$SF" build.log)" = "$work/foo-build.log" ] \
    && pass "a GREEN --build-log run records the tree's build" || { fail "--build-log recorded"; printf '%s\n' "$out" | sed 's/^/    /'; }
  mkdir -p "$work/root-foo/.build.packages/SRPMS" && cp "$work/foo-build.log" "$work/root-foo/.build.log"
  : > "$work/root-foo/.build.packages/SRPMS/foo-1.0-0.src.rpm"
  gg --build-log "$work/root-foo"
  grep -q "^VERDICT: GREEN" <<<"$out" && [ "$(sv "$SF" build.log)" = "$work/root-foo/.build.log" ] \
    && pass "--build-log of a build root: its .build.log is checked and recorded" \
    || { fail "--build-log of a build root"; printf '%s\n' "$out" | sed 's/^/    /'; }
  gg --build-log "$work/no-such.log"
  [ "$rc" = 1 ] && grep -qF "no build log behind --build-log $work/no-such.log" <<<"$out" && ! grep -q Traceback <<<"$out" \
    && pass "--build-log of nothing: red, no traceback" || { fail "--build-log of nothing: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
else
  echo "SKIP: GREEN stamp (no OBS source_validator/download_files)"
fi

# A fresh `osc mkpac` whose files were never `osc add`ed tracks nothing: its
# tree is the sha256 of nothing, e3b0c44298fc for any content, so a review
# bound to it binds nothing. Red, nothing stamped, and --review refuses it.
mkpac() {   # <dir>: `osc mkpac bar` in devel:example, its files written, none added
  rm -rf "$1"; mkdir -p "$1/.osc"; printf 'bar\n' > "$1/.osc/_package"; printf 'devel:example\n' > "$1/.osc/_project"
  printf '2.0\n' > "$1/.osc/_osclib_version"; printf '<directory />' > "$1/.osc/_files"
  printf 'Name:           bar\nVersion:        1.0\nRelease:        0\nSummary:        t\nLicense:        MIT\n%%description\nt\n%%files\n%%changelog\n' \
    > "$1/bar.spec"
  e "Thu Oct 22" "Initial package" > "$1/bar.changes"
}
SB="$work/home/.local/state/opensuse-packaging/gate/obs/bar/devel:example.json"
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
mkpac "$work/t-mkpac"
out="$(OBS=$O HOME="$work/home" PATH="$work/scbin:$work/obin:$PATH" SC_MODE=same bash "$GATE" "$work/t-mkpac" 2>&1)"
grep -qF "## tracked: rc=1" <<<"$out" && grep -qF "nothing to stamp: no tracked files (osc add the package files first)" <<<"$out" \
  && grep -q "^VERDICT: RED — .*tracked" <<<"$out" && [ ! -e "$SB" ] \
  && pass "fresh mkpac checkout, nothing osc added: red, nothing stamped" \
  || { fail "fresh mkpac checkout"; printf '%s\n' "$out" | sed 's/^/    /'; }
# Its one tracked file `osc add`ed, then deleted: a name with no content to key.
mkpac "$work/t-gone"; printf 'bar-1.0.tar.xz\n' > "$work/t-gone/.osc/_to_be_added"
out="$(OBS=$O HOME="$work/home" PATH="$work/scbin:$work/obin:$PATH" SC_MODE=same bash "$GATE" "$work/t-gone" 2>&1)"
grep -qF "## tracked: rc=1" <<<"$out" && grep -qF "nothing to stamp: no tracked files (osc add the package files first)" <<<"$out" \
  && [ ! -e "$SB" ] && pass "only tracked file deleted after osc add: red, nothing stamped" \
  || { fail "tracked file deleted after osc add"; printf '%s\n' "$out" | sed 's/^/    /'; }
# A GREEN stamp of the empty tree with its review, as gate.sh wrote them before
# it went red: --review refuses the tree and deletes the stale stamp.
mkdir -p "$(dirname "$SB")"
printf '{"project": "devel:example", "package": "bar", "tree": "%s", "files": {}, "verdict": "GREEN", "review": {"verdict": "PASS"}}\n' "$EMPTY" > "$SB"
echo "PASS — tree ${EMPTY:0:12} — clean" > "$work/rv.txt"
out="$(HOME="$work/home" bash "$GATE" "$work/t-mkpac" "$REV" "$work/rv.txt" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qF "nothing to review: no tracked files (osc add the package files first)" <<<"$out" && [ ! -e "$SB" ] \
  && pass "--review: a PASS naming the empty tree ${EMPTY:0:12} is refused, the stale stamp deleted" \
  || { fail "--review of the empty tree: rc=$rc, stamp $([ -e "$SB" ] && echo kept || echo gone)"; printf '%s\n' "$out" | sed 's/^/    /'; }
rm -f "$SB"
printf 'bar.changes\nbar.spec\n' > "$work/t-mkpac/.osc/_to_be_added"
out="$(OBS=$O HOME="$work/home" PATH="$work/scbin:$work/obin:$PATH" SC_MODE=same bash "$GATE" "$work/t-mkpac" 2>&1)"
grep -qF "## tracked: rc=0" <<<"$out" && pass "the mkpac checkout once osc added: tracked green" \
  || { fail "mkpac checkout after osc add"; printf '%s\n' "$out" | sed 's/^/    /'; }
if [ -x /usr/lib/obs/service/source_validator ] && [ -x /usr/lib/obs/service/download_files ]; then
  t12=$(sed -n 's/^VERDICT: GREEN — all gates passed for tree \([0-9a-f]\{12\}\) .*/\1/p' <<<"$out")
  [ -n "$t12" ] && [ "$t12" != "${EMPTY:0:12}" ] \
    && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d["tree"].startswith(sys.argv[2]) and set(d["files"])=={"bar.changes","bar.spec"}))' "$SB" "$t12" \
    && pass "the mkpac checkout once osc added: GREEN, its two files stamped" \
    || { fail "mkpac checkout after osc add: not GREEN"; printf '%s\n' "$out" | sed 's/^/    /'; }
else
  echo "SKIP: GREEN stamp after osc add (no OBS source_validator/download_files)"
fi

# rpmspec -P parses every spec: a parse error is red, and so is a comment rpm
# expands into a section name or into commands. opencode sr#1394137 was declined
# for "%prep" in a comment ("Unknown tag: %prep"); codenomad's "# %{cargo_test}"
# comment ran cargo test. Without --build-log, %prep runs too (rpmbuild -bp):
# photocraft's patch no longer applied while the gate was GREEN.
if command -v rpmspec > /dev/null && command -v rpmbuild > /dev/null; then
  HDR=$'Name:           p\nVersion:        1\nRelease:        0\nSummary:        t\nLicense:        MIT'
  # sp <name> <gate section> <rc> <expected line> [gate args] < spec body
  sp() {
    local n=$1 sec=$2 r=$3 m=$4; shift 4
    mkdir -p "$work/sp-$n"; { echo "$HDR"; cat; } > "$work/sp-$n/p.spec"
    out="$(bash "$GATE" "$work/sp-$n" "$@" 2>&1)"
    grep -qF "## $sec: rc=$r" <<<"$out" && grep -qF -- "$m" "$work/gate-sp-$n/$sec.txt" && pass "$sec $n (rc=$r)" \
      || { fail "$sec $n: expected rc=$r and '$m'"; sed 's/^/    /' "$work/gate-sp-$n/$sec.txt" 2>/dev/null; }
  }
  sp clean rpmspec 0 "OK: every spec parses" <<'EOF'
# Unpacked in %%prep; %{name} expands to one line here.
%description
t
%prep
%build
# %{name} stays one line in a script too.
%files
%changelog
EOF
  sp bad-tag rpmspec 1 "p.spec: rpmspec -P fails: error: line 6: Unknown tag: Bogus: tag" <<'EOF'
Bogus: tag
%description
t
%files
EOF
  sp section-comment rpmspec 1 "p.spec:6: %prep in a comment" <<'EOF'
# Unpacks into the crate dir in %prep.
%description
t
%prep
%files
EOF
  sp multiline-comment rpmspec 1 "p.spec:13: the comment's macro expands to 3 lines" <<'EOF'
%define two_lines \
echo one\
echo two
%description
t
%prep
%build
# Note %{two_lines} in a comment.
true
%check
# Note %{name}: one line.
%files
%changelog
EOF
  grep -qF "p.spec:16:" "$work/gate-sp-multiline-comment/rpmspec.txt" \
    && fail "rpmspec multiline-comment: a one-line expansion was flagged" || pass "rpmspec multiline-comment: a one-line expansion is not"
  # A _multibuild spec is parsed per flavor, @BUILD_FLAVOR@ set as OBS sets it.
  mkdir -p "$work/sp-flavor"; printf '<multibuild>\n  <package>doc</package>\n</multibuild>\n' > "$work/sp-flavor/_multibuild"
  sp flavor rpmspec 1 "p.spec (flavor doc): rpmspec -P fails: error: line 11: Unknown tag: Bogus: tag" <<'EOF'
%define flavor @BUILD_FLAVOR@%{nil}
%if "%{flavor}" != ""
%define name_suffix -%{flavor}
%endif
%if "%{flavor}" == "doc"
Bogus: tag
%endif
%description
t
%files
EOF
  grep -qF "p.spec: rpmspec -P fails" "$work/gate-sp-flavor/rpmspec.txt" \
    && fail "rpmspec flavor: the default build was red" || pass "rpmspec flavor: the default build parses"
  # %prep: a tarball and a patch that applies, then one that does not.
  mkdir -p "$work/ppsrc/p-1"; echo hello > "$work/ppsrc/p-1/hello.txt"
  tar -C "$work/ppsrc" -czf "$work/p-1.tar.gz" p-1
  pspec() { printf '%s\n' 'Source0:        p-1.tar.gz' '# PATCH-FIX-OPENSUSE p-fix.patch -- t' 'Patch0:         p-fix.patch' \
    '%description' t '%prep' '%autosetup -p1' "$@" '%build' '%files' '%changelog'; }
  pfix() { mkdir -p "$work/sp-$1"; cp "$work/p-1.tar.gz" "$work/sp-$1/"
    printf -- '--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-%s\n+hello world\n' "$2" > "$work/sp-$1/p-fix.patch"; }
  pfix prep-ok hello; sp prep-ok prep 0 "OK: %prep of p.spec ran in" < <(pspec)
  sp prep-ok prep 0 "OK: %prep of p.spec passed on these sources before (cached)" < <(pspec)
  pfix prep-bad goodbye; sp prep-bad prep 1 "p.spec: %prep fails" < <(pspec)
  grep -qE '^VERDICT: RED — [^(]*\bprep\b' <<<"$out" && pass "prep-bad: on the verdict line" || fail "prep-bad: not on the verdict line"
  echo build > "$work/build.log"
  pfix prep-log goodbye; sp prep-log prep 0 "not run: the --build-log build ran %prep" --build-log "$work/build.log" < <(pspec)
  pfix prep-host hello
  sp prep-host prep 0 "UNKNOWN: %prep of p.spec stopped on what this host lacks: /usr/share/gate-test-no-such-pkg/*" \
    < <(pspec 'cp /usr/share/gate-test-no-such-pkg/* .')
  # only the command that failed counts: an earlier miss the spec tolerates is no excuse
  pfix prep-mixed hello; sp prep-mixed prep 1 "p.spec: %prep fails" < <(pspec 'gate-test-no-such-cmd || :' 'false')
  pfix prep-noparse hello; sp prep-noparse prep 1 "p.spec: not run: the spec does not parse" < <(echo "Bogus: tag"; pspec)
  # spec-cleaner 1.3.2 unbraces %{cargo_build} -p foo, which rpm then parses as
  # the macro's options (goose failed in staging): a spec-cleaner defect, not a
  # missed rule; the -- form is what spec-cleaner leaves alone.
  scd() { out="$(PATH="$work/scbin:$PATH" SC_MODE=$1 bash "$GATE" "$work/sp-defect" 2>&1)"; }
  mkdir -p "$work/sp-defect"
  printf '%s\n' "$HDR" '%define opt_macro() echo %*' '%description' t '%prep' '%build' '%{opt_macro} -p foo' '%files' '%changelog' > "$work/sp-defect/p.spec"
  scd unbrace
  grep -qF "## spec-cleaner: rc=1" <<<"$out" \
    && grep -qF "KNOWN DEFECT: p.spec:11: spec-cleaner's \`%opt_macro -p foo\` does not parse" "$work/gate-sp-defect/spec-cleaner.txt" \
    && grep -qF -- "%cargo_build -- <args>" "$work/gate-sp-defect/spec-cleaner.txt" \
    && pass "spec-cleaner: an unbraced macro that no longer parses is a known defect, with the -- form" \
    || { fail "spec-cleaner known defect"; sed 's/^/    /' "$work/gate-sp-defect/spec-cleaner.txt"; }
  sed -i 's/^%{opt_macro} -p foo$/%opt_macro -- -p foo/' "$work/sp-defect/p.spec"; scd unbrace
  grep -qF "## spec-cleaner: rc=0" <<<"$out" && pass "spec-cleaner: the -- form is left alone" \
    || { fail "spec-cleaner -- form"; sed 's/^/    /' "$work/gate-sp-defect/spec-cleaner.txt"; }
  scd group
  grep -qF "## spec-cleaner: rc=1" <<<"$out" && ! grep -qF "KNOWN DEFECT" "$work/gate-sp-defect/spec-cleaner.txt" \
    && pass "spec-cleaner: a hunk that parses is no known defect" || { fail "spec-cleaner group hunk"; sed 's/^/    /' "$work/gate-sp-defect/spec-cleaner.txt"; }
else
  echo "SKIP: rpmspec, %prep and spec-cleaner parse checks (no rpmspec or rpmbuild)"
fi

echo "---"; [ "$fails" = 0 ] && echo "all gate checks passed" || echo "$fails FAILED"
exit $((fails > 0))
