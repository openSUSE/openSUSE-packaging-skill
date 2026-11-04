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
  ls) exit 0 ;;
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

# A copy of a skill script in the checkout is red: one written there printed
# GREEN for a tree the real gate called red.
mkdir -p "$work/forged/scripts" && printf 'Name: p\n' > "$work/forged/p.spec"
printf '#!/bin/bash\necho "VERDICT: GREEN"\n' > "$work/forged/scripts/gate.sh"
out="$(bash "$GATE" "$work/forged" 2>&1)"
grep -qF "## skill-scripts: rc=1" <<<"$out" && grep -qF "scripts/gate.sh: named like the skill's own gate.sh" <<<"$out" \
  && grep -q "^VERDICT: RED — .*skill-scripts" <<<"$out" && pass "a gate.sh copy in the checkout: skill-scripts red" \
  || { fail "a gate.sh copy in the checkout"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(bash "$GATE" "$work/pkg" 2>&1)"
grep -qF "## skill-scripts: rc=0" <<<"$out" && pass "no copy of a skill script: skill-scripts green" \
  || { fail "skill-scripts control"; printf '%s\n' "$out" | sed 's/^/    /'; }

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
  ls) [ "$2" = openSUSE:Factory ] && { ls "$OBS/openSUSE:Factory"; exit 0; } ;;
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
# A package Factory has under another spelling is no new package
# (python-authlib was filed while Factory had python-Authlib).
co "$work/t-near" 'home:<you>:spark' - "$O/hardware/foo"; printf 'FOO\n' > "$work/t-near/.osc/_package"
og "$work/t-near"
grep -qF "## target: rc=1" <<<"$out" && grep -qF "RED: NOT IN openSUSE:Factory as FOO, but it has foo" <<<"$out" \
  && pass "a package Factory has under another spelling: target red" \
  || { fail "another spelling in Factory"; printf '%s\n' "$out" | sed 's/^/    /'; }
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
# OBS's build is the evidence after the commit: nothing is parsed or unpacked here
! grep -qE '^## (rpmspec|prep)|%prep' <<<"$out" && pass "--obs-build: no spec parse and no %prep run" \
  || { fail "--obs-build ran the parse or %prep"; grep -E '^## (rpmspec|prep)|%prep' <<<"$out" | sed 's/^/    /'; }
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
# Only the Factory/Tumbleweed repos are judged: another repo is a note, never red or pending.
lp() { printf '<result repository="%s" arch="x86_64"><status package="foo" code="%s"/></result>' "$@"; }
blog16() { printf "[    0s] Building foo for project '%s' repository '16.1' arch 'x86_64' srcmd5 '%s'\n[  100s] ... failed \"build foo.spec\" at Mon Nov  2 2026.\n" "$P" "$SRC" > "$work/ob/log-16.1-x86_64-foo"; }
blog16
rx "$(st_ x86_64 '' foo succeeded)$(st_ aarch64 '' foo succeeded)$(lp 16.1 failed)$(lp 15.7 unresolvable)"; ob
[ "$rc" = 0 ] && grep -qF "note: not judged" <<<"$out" && grep -qF "16.1/x86_64 failed" <<<"$out" \
  && [ "$(sv "$SO" build.repos)" = "['openSUSE_Tumbleweed']" ] && [ "$(sv "$SO" build.factory)" = True ] && [ "$(sv "$SO" build.others)" = "[]" ] \
  && pass "--obs-build: Factory green with Leap red is GREEN, the Leap repos a note, the judged repos recorded" \
  || { fail "--obs-build Factory green, Leap red: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
rx "$(st_ x86_64 '' foo succeeded)$(st_ aarch64 '' foo failed)$(lp 16.1 succeeded)"; blog aarch64 "$SRC" failed; ob
[ "$rc" = 1 ] && grep -qF "VERDICT: RED" <<<"$out" && grep -qF "openSUSE_Tumbleweed/aarch64" <<<"$out" \
  && pass "--obs-build: Factory red is red, whatever Leap does" || { fail "--obs-build Factory red: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
blog aarch64 "$SRC" finished
rx "$(st_ x86_64 '' foo succeeded)$(st_ aarch64 '' foo building)$(lp 16.1 failed)"; ob
[ "$rc" = 4 ] && grep -qF "openSUSE_Tumbleweed/aarch64 building" <<<"$out" \
  && pass "--obs-build: Factory still building is pending (rc=4) with Leap done" || { fail "--obs-build Factory building: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
rx "$(st_ x86_64 '' foo succeeded)$(st_ aarch64 '' foo succeeded)$(lp 16.1 building)"; ob
[ "$rc" = 0 ] && grep -qF "16.1/x86_64 building" <<<"$out" \
  && pass "--obs-build: a Leap repo still building is a note, not pending" || { fail "--obs-build Leap building: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
rx "$(st_ x86_64 '' foo succeeded)$(st_ aarch64 '' foo succeeded)$(lp 16.1 failed)"; ob --repos '16\.1'
[ "$rc" = 1 ] && grep -qF "VERDICT: RED" <<<"$out" && grep -qF "16.1/x86_64" <<<"$out" \
  && pass "--obs-build --repos '16\.1': a red 16.1 is red" || { fail "--obs-build --repos 16.1: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
sed -i 's/\] \.\.\. failed /] ... finished /' "$work/ob/log-16.1-x86_64-foo"
rx "$(st_ x86_64 '' foo succeeded)$(st_ aarch64 '' foo succeeded)$(lp 16.1 succeeded)"; ob --repos '16\.1'
[ "$rc" = 0 ] && [ "$(sv "$SO" build.others)" = "['16.1']" ] \
  && pass "--obs-build --repos: a green 16.1 is recorded among the judged repos" || { fail "--obs-build --repos green: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
rx "$(lp 16.1 succeeded)$(lp 15.7 failed)"; ob
[ "$rc" = 1 ] && grep -qF "VERDICT: UNKNOWN" <<<"$out" && grep -qF "no Factory/Tumbleweed repo builds it" <<<"$out" \
  && pass "--obs-build: no Factory/Tumbleweed repo is UNKNOWN, naming --repos" || { fail "--obs-build no Factory repo: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
ob --repos '('
[ "$rc" = 2 ] && pass "--obs-build --repos: a bad regex is usage" || { fail "--obs-build bad --repos: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
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

if [ -x /usr/lib/obs/service/source_validator ] && [ -x /usr/lib/obs/service/download_files ]; then
  # qux: in devel:example only, its top entry a real one; the change edits the spec alone
  printf 'Name: qux\nVersion: 1.0\n' | put devel:example/qux qux.spec
  e "Mon Jan  5" "Build with the system zlib" | put devel:example/qux qux.changes; echo devel:example/qux > "$O/devel/qux"
  rm -rf "$work/t-ne"; mkdir -p "$work/t-ne/.osc/sources"; printf 'qux\n' > "$work/t-ne/.osc/_package"
  printf 'home:<you>:branches:devel:example\n' > "$work/t-ne/.osc/_project"; printf '2.0\n' > "$work/t-ne/.osc/_osclib_version"
  printf '<directory name="qux" rev="1"><linkinfo project="devel:example" package="qux" srcmd5="x"/><entry name="qux.changes"/><entry name="qux.spec"/></directory>\n' \
    > "$work/t-ne/.osc/_files"
  cp "$O/devel:example/qux/"* "$work/t-ne/.osc/sources/"; cp "$O/devel:example/qux/qux.changes" "$work/t-ne/"
  printf 'Name:           qux\nVersion:        1.0\nRelease:        0\nSummary:        t\nLicense:        MIT\n%%description\nt\n%%files\n%%changelog\n' \
    > "$work/t-ne/qux.spec"
  SQ="$work/home/.local/state/opensuse-packaging/gate/obs/qux/home:<you>:branches:devel:example.json"
  out="$(OBS=$O HOME="$work/home" PATH="$work/scbin:$work/obin:$PATH" SC_MODE=same bash "$GATE" "$work/t-ne" --no-entry "a comment-only cleanup" 2>&1)"
  grep -q "^VERDICT: GREEN — .*no new .changes entry: a comment-only cleanup" <<<"$out" \
    && python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])).get("no_entry") != "a comment-only cleanup")' "$SQ" \
    && pass "--no-entry: GREEN names the reason, and the stamp records it" \
    || { fail "--no-entry on a GREEN run"; printf '%s\n' "$out" | sed 's/^/    /'; }
else
  echo "SKIP: --no-entry on a GREEN run (no OBS source_validator/download_files)"
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

# rpmspec -P parses every spec: a parse error is red, and so is %prep in a
# comment or a comment rpm expands into commands. opencode sr#1394137 was
# declined for "%prep" in a comment ("Unknown tag: %prep"); codenomad's
# "# %{cargo_test}" comment ran cargo test. Without --build-log, %prep runs too
# (rpmbuild -bp in a sandbox): photocraft's patch no longer applied while the
# gate was GREEN. Several specs share one checkout, so one gate run checks many,
# and the runs go in parallel: the fixtures first, then every run, then the checks.
if command -v rpmspec > /dev/null && command -v rpmbuild > /dev/null; then
  # %prep runs only in a bwrap sandbox that starts; without one its cases are skipped
  sbx=0; env -i PATH="$PATH" bwrap --ro-bind / / true > /dev/null 2>&1 && sbx=1
  HDR=$'Name:           p\nVersion:        1\nRelease:        0\nSummary:        t\nLicense:        MIT'
  PATH="$work/scbin:$PATH"   # the stand-in spec-cleaner (SC_MODE=same unless set) saves a second a spec
  ms() { mkdir -p "$work/$1"; { echo "$HDR"; cat; } > "$work/$1/$2.spec"; }   # ms <dir> <name> < spec body
  # bg <dir> [VAR=value ...] [-- gate args]: the gate on <dir> in the background, into <dir>.out
  bg() { local d=$1 v=(); shift; while [ $# -gt 0 ] && [ "$1" != -- ]; do v+=("$1"); shift; done; [ $# -eq 0 ] || shift
    env "${v[@]}" bash "$GATE" "$work/$d" "$@" > "$work/$d.out" 2>&1 & }
  got() { out=$(cat "$work/$1.out"); }
  # has/hasnt <dir> <section> <text> <what>: the section's output (does not) hold text
  has() { grep -qF -- "$3" "$work/gate-$1/$2.txt" && pass "$2: $4" \
    || { fail "$2: $4: no '$3'"; sed 's/^/    /' "$work/gate-$1/$2.txt" 2>/dev/null; }; }
  hasnt() { ! grep -qF -- "$3" "$work/gate-$1/$2.txt" && pass "$2: $4" \
    || { fail "$2: $4: '$3' found"; grep -F -- "$3" "$work/gate-$1/$2.txt" | sed 's/^/    /'; }; }
  sec() { grep -qF "## $2: rc=$3" <<<"$out" && pass "$2 rc=$3 in $1" || { fail "$2 in $1: want rc=$3"; grep "^## $2" <<<"$out"; }; }

  # What parses, or what only the build root could judge: the section stays green.
  ms rs-ok clean <<'EOF'
# Unpacked in %%prep; %{name} expands to one line here.
%description
t
%prep
%build
# %{name} stays one line in a script too.
%files
%changelog
EOF
  ms rs-ok sectnote <<'EOF'
# Built from source in %build, and %check runs the tests.
%description
t
%prep
%files
EOF
  # its default build is off (do_not_build under the empty-flavor test): its flavors count
  printf '<multibuild>\n  <package>qt6</package>\n</multibuild>\n' > "$work/rs-ok/_multibuild"
  ms rs-ok noflavor <<'EOF'
%define flavor @BUILD_FLAVOR@%{nil}
%if "%{flavor}" == ""
ExclusiveArch:  do_not_build
%endif
%if "%{flavor}" != ""
%define libname libp-%{flavor}
%endif
%description
t
%package devel
Summary:        t
Requires:       %{libname}
%description devel
t
%files
EOF
  # a macro only a missing BuildRequires defines (Requires: %{apache_mmn} without apache2-devel)
  ms rs-ok hostmacro <<'EOF'
BuildRequires:  gate-test-no-such-devel
Requires:       %{gate_test_no_such_macro}
%description
t
%prep
%files
EOF
  # spec-cleaner's copy of a flavor-only spec is parsed as its flavor, not the default
  mkdir -p "$work/rs-sc"; cp "$work/rs-ok/_multibuild" "$work/rs-ok/noflavor.spec" "$work/rs-sc/"

  # What is wrong in the spec: red, each spec on its own line.
  mkdir -p "$work/rs-red"; printf '<multibuild>\n  <package>doc</package>\n</multibuild>\n' > "$work/rs-red/_multibuild"
  ms rs-red badtag <<<$'Bogus: tag\n%description\nt\n%files'
  ms rs-red sectcomment <<<$'# Unpacks into the crate dir in %prep.\n%description\nt\n%prep\n%files'
  ms rs-red multiline <<'EOF'
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
  ms rs-red flavor <<'EOF'
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
  # do_not_build for another flavor does not excuse the default build
  ms rs-red offguard <<'EOF'
%define flavor @BUILD_FLAVOR@%{nil}
%if "%{flavor}" == ""
Bogus: tag
%endif
%if "%{flavor}" == "doc"
ExclusiveArch:  do_not_build
%endif
%description
t
%files
EOF
  # structural mistakes and macro typos are no host gap: every BuildRequires is here
  ms rs-red dupprep <<<$'%description\nt\n%prep\ntrue\n%prep\ntrue\n%files'
  ms rs-red filesn <<<$'%description\nt\n%prep\n%files\n%files -n nosuchpkg\n/x'
  ms rs-red descn <<<$'%description\nt\n%description -n nosuch\nx\n%prep\n%files'
  ms rs-red duppkg <<<$'%description\nt\n%package devel\nSummary: x\n%description devel\nx\n%package devel\nSummary: y\n%description devel\ny\n%files'
  ms rs-red nmae <<<$'Requires:       %{nmae}-libs\n%description\nt\n%files'
  ms rs-red pythn <<<$'BuildRequires:  %{pythn_module foo}\n%description\nt\n%files'
  # the hint names the comment rpm's error is on, not the one a warning names
  ms rs-red warnline <<<$'# uses %{name} here\nBogus: tag\n%description\nt\n%files'
  # %patchN is an error from rpm 4.20 on; 4.18 only warns
  rpmv=$(rpm --version | awk '{print $NF}')
  if [ "$(printf '%s\n' 4.20 "$rpmv" | sort -V | head -n 1)" = 4.20 ]; then
    ms rs-red obsolete <<<$'%description\nt\n%prep\n%patch0 -p1\n%files'
  else
    echo "SKIP: rpmspec obsolete %patch0 (rpm $rpmv < 4.20 only warns)"
  fi

  # %prep in the sandbox: a tarball, a patch that applies and one that does not.
  mkdir -p "$work/ppsrc/p-1"; echo hello > "$work/ppsrc/p-1/hello.txt"
  tar -C "$work/ppsrc" -czf "$work/p-1.tar.gz" p-1
  # pspec <dir> <name> <patch context> [%prep lines] [-- preamble lines]: a spec applying <name>.patch
  pspec() {
    local d=$1 n=$2 c=$3; shift 3; local body=() pre=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do body+=("$1"); shift; done; [ $# -eq 0 ] || { shift; pre=("$@"); }
    mkdir -p "$work/$d"; cp "$work/p-1.tar.gz" "$work/$d/"
    printf -- '--- a/hello.txt\n+++ b/hello.txt\n@@ -1 +1 @@\n-%s\n+hello world\n' "$c" > "$work/$d/$n.patch"
    printf '%s\n' "${pre[@]}" 'Source0:        p-1.tar.gz' "# PATCH-FIX-OPENSUSE $n.patch -- t" "Patch0:         $n.patch" \
      '%description' t '%prep' '%autosetup -p1' "${body[@]}" '%build' '%files' '%changelog' | ms "$d" "$n"
  }
  mkdir -p "$work/home"; : > "$work/home/.gate-test-secret"
  pspec pp-ok ok hello
  pspec pp-ok host hello 'cp /usr/share/gate-test-no-such-pkg/* .' -- 'BuildRequires:  gate-test-no-such-devel'
  pspec pp-ok arch hello -- 'ExcludeArch:    %{_target_cpu}'
  # shellcheck disable=SC2016  # these %prep lines are expanded by %prep's shell, not here
  pspec pp-ok net hello 'test "$(grep -c : /proc/net/dev)" -eq 1'
  # shellcheck disable=SC2016
  pspec pp-ok home hello 'test ! -e "$HOME/.gate-test-secret"'
  # nothing of the gate's environment, no core dumps or journals: not even bwrap's PID 1 holds it
  pspec pp-ok secret hello 'grep -q GATE_TEST_SECRET /proc/1/environ /proc/self/environ 2>/dev/null && exit 1 || :' \
    'test ! -e /var/lib/systemd/coredump' 'test ! -e /var/log/journal'
  # an escape sequence in upstream output (a build script's message) must not reach the verdict line
  pspec pp-ok esc hello "sh -c 'printf \"gatetest\\033[2Jcmd: command not found\\n\" >&2; exit 127'" \
    -- 'BuildRequires:  gate-test-no-such-devel'
  printf '%s\n' 'Source1:        gate-test-made-by-tar.tar.gz' '%description' t '%prep' '%setup -q -c -T -a 1' '%files' | ms pp-ok svc
  printf '<services>\n  <service name="tar" mode="buildtime"/>\n</services>\n' > "$work/pp-ok/_service"
  pspec pp-cache ok hello
  # a pass recorded before %prep ran in the sandbox (an unsalted key) does not count
  pspec pp-salt salt hello
  mkdir -p "$XDG_CACHE_HOME/opensuse-packaging/prep"
  (cd "$work/pp-salt" && python3 -I - "$XDG_CACHE_HOME/opensuse-packaging/prep" <<'PY'
import hashlib, os, subprocess, sys
h = hashlib.sha256(subprocess.run(["rpm", "--version"], capture_output=True, text=True).stdout.encode() + b"\0salt.spec")
for n in sorted(x for x in os.listdir(".") if os.path.isfile(x)):
    h.update(("%s  %s\n" % (hashlib.md5(open(n, "rb").read()).hexdigest(), n)).encode())
open(os.path.join(sys.argv[1], h.hexdigest()), "w").close()
PY
  )
  pspec pp-red bad goodbye
  pspec pp-red mixed hello 'gate-test-no-such-cmd || :' 'false'   # only the command that failed counts
  pspec pp-red typo hello 'gate-test-no-such-cmd'                 # every BuildRequires is here: a typo
  pspec pp-red rofs hello 'touch %{_sourcedir}/gate-written'      # the checkout is read-only
  printf '%s\n' 'Source1:        gate-test-missing.tar.gz' '%description' t '%prep' '%setup -q -c -T -a 1' '%files' | ms pp-red svc
  printf '<services>\n  <service name="format_spec_file"/>\n</services>\n' > "$work/pp-red/_service"
  pspec pp-red noparse hello -- 'Bogus: tag'
  pspec pp-log bad goodbye; echo build > "$work/build.log"
  # never unsandboxed: no bwrap that starts is UNKNOWN, and nothing runs
  mkdir -p "$work/nobw"; printf '#!/bin/sh\necho "bwrap: no permission" >&2; exit 1\n' > "$work/nobw/bwrap"; chmod +x "$work/nobw/bwrap"
  # shellcheck disable=SC2016
  pspec pp-nobw ran hello 'touch "$HOME/.gate-test-ran"'
  # not enough room under /var/tmp to unpack: UNKNOWN, nothing unpacked
  mkdir -p "$work/nodf"; printf '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/x 100 99 1 99%% /var/tmp\\n"\n' > "$work/nodf/df"
  chmod +x "$work/nodf/df"; pspec pp-df room hello   # a tree no other run caches
  # a signal or the time limit kills %prep and removes its scratch, read-only parts too
  slow() { pspec "$1" slow hello 'mkdir ro && touch ro/f && chmod -R a-w ro' "sleep $2"; }
  s1="41.$$"; slow pp-sig "$s1"; s2="42.$$"; slow pp-tmo "$s2"
  # spec-cleaner 1.3.2 unbraces %{cargo_build} -p foo, which rpm then parses as
  # the macro's options (goose failed in staging): a spec-cleaner defect, not a
  # missed rule; the -- form is what spec-cleaner leaves alone.
  sdef() { mkdir -p "$work/$1"
    printf '%s\n' "$HDR" '%define opt_macro() echo %*' '%description' t '%prep' '%build' "$2" '%files' '%changelog' > "$work/$1/p.spec"; }
  sdef sp-defect '%{opt_macro} -p foo'; sdef sp-dash '%opt_macro -- -p foo'; sdef sp-group '%{opt_macro} -p foo'
  # a bootstrap's static library whose code a shipped file carries: named on the verdict line
  mkdir -p "$work/emb/lib" "$work/pp-emb" "$work/emb-rpm/SOURCES" "$work/emb-rpms"; head -c 6144 /dev/urandom > "$work/emb-code"
  python3 - "$work/emb/lib/libseed.a" "$work/emb-code" <<'PY'
import sys
code = open(sys.argv[2], "rb").read()
hdr = b"%-16s%-12s%-6s%-6s%-8s%-10d`\n" % (b"x.o/", b"0", b"0", b"0", b"644", len(code))
open(sys.argv[1], "wb").write(b"!<arch>\n" + hdr + code)
PY
  tar -C "$work/emb" -czf "$work/pp-emb/seed.tar.gz" .
  printf '%s\n' 'Source0:        seed.tar.gz' \
    '# Source-Binary-Exception: seed.tar.gz:./lib/* -- bootstrap: the seed compiler builds the first stage of this compiler, which Factory lacks' \
    '%description' t '%prep' '%files' | ms pp-emb emb
  { head -c 2000 /dev/urandom; cat "$work/emb-code"; head -c 2000 /dev/urandom; } > "$work/emb-rpm/SOURCES/lib"
  printf 'Name: e\nVersion: 1\nRelease: 0\nSummary: e\nLicense: MIT\nBuildArch: noarch\nSource0: lib\n%%description\ne\n%%install\ninstall -D -m 0644 %%{SOURCE0} %%{buildroot}/usr/lib/e/lib\n%%files\n/usr/lib/e\n' > "$work/emb-rpm/e.spec"
  rpmbuild -bb --quiet --define "_topdir $work/emb-rpm" --define 'debug_package %{nil}' --define '__os_install_post %{nil}' \
    "$work/emb-rpm/e.spec" > /dev/null 2>&1 && find "$work/emb-rpm/RPMS" -name '*.rpm' -exec cp {} "$work/emb-rpms/" \;

  bg rs-ok; bg rs-sc SC_MODE=group; bg rs-red; bg pp-log -- --build-log "$work/build.log"
  bg pp-nobw HOME="$work/home" PATH="$work/nobw:$PATH"
  bg sp-defect SC_MODE=unbrace; bg sp-dash SC_MODE=unbrace; bg sp-group SC_MODE=group
  bg pp-emb -- --rpms "$work/emb-rpms"
  if [ "$sbx" = 1 ]; then
    bg pp-ok HOME="$work/home" GATE_TEST_SECRET=leaked; bg pp-cache; bg pp-red; bg pp-salt
    bg pp-df PATH="$work/nodf:$PATH"; bg pp-tmo GATE_PREP_TIMEOUT=2
  fi
  wait
  [ "$sbx" = 0 ] || bash "$GATE" "$work/pp-cache" > "$work/pp-cache.out" 2>&1   # the second run of the same tree

  got rs-ok
  sec rs-ok rpmspec 0
  hasnt rs-ok rpmspec "clean.spec" "a clean spec has no finding"
  has rs-ok rpmspec "note: sectnote.spec:6: %build in a comment" "a section name other than %prep in a comment is a note"
  has rs-ok rpmspec "note: noflavor.spec: the default build does not parse, and the spec builds only its flavors" "a flavor-only spec is judged by its flavors"
  has rs-ok rpmspec "UNKNOWN: hostmacro.spec: rpmspec -P stopped on what this host lacks: macro %gate_test_no_such_macro" "a macro of a missing BuildRequires is UNKNOWN"
  [ "$sbx" = 0 ] || has rs-ok prep "UNKNOWN: %prep of hostmacro.spec not run: rpmspec -P stopped on this host" "not run after an UNKNOWN parse"
  grep -qE '^VERDICT: .*not proven on this host.*gate_test_no_such_macro' <<<"$out" \
    && pass "rpmspec: an UNKNOWN parse is named on the verdict line" || { fail "rpmspec: UNKNOWN not on the verdict line"; grep VERDICT <<<"$out"; }
  got rs-sc; hasnt rs-sc spec-cleaner "KNOWN DEFECT" "a flavor-only spec's cleaned copy parses as its flavor"

  got rs-red
  sec rs-red rpmspec 1
  has rs-red rpmspec "badtag.spec: rpmspec -P fails: error: line 6: Unknown tag: Bogus: tag" "a parse error is red"
  has rs-red rpmspec "sectcomment.spec:6: %prep in a comment" "%prep in a comment is red"
  has rs-red rpmspec "multiline.spec:13: the comment's macro expands to 3 lines" "a multi-line macro in a comment is red"
  hasnt rs-red rpmspec "multiline.spec:16:" "a one-line expansion in a comment is not"
  has rs-red rpmspec "flavor.spec (flavor doc): rpmspec -P fails: error: line 11: Unknown tag: Bogus: tag" "each flavor is parsed"
  hasnt rs-red rpmspec "flavor.spec: rpmspec -P fails" "the default build of that spec parses"
  has rs-red rpmspec "offguard.spec: rpmspec -P fails" "do_not_build for another flavor excuses nothing"
  has rs-red rpmspec "dupprep.spec: rpmspec -P fails: error: line 10: second" "a second %prep is red"
  has rs-red rpmspec "filesn.spec: rpmspec -P fails: error: line 10: %files -n nosuchpkg" "%files of no package is red"
  has rs-red rpmspec "descn.spec: rpmspec -P fails: error: line 8: %description -n nosuch" "%description of no package is red"
  has rs-red rpmspec "duppkg.spec: rpmspec -P fails: error: line 12: %package devel" "a duplicate %package is red"
  has rs-red rpmspec "nmae.spec: rpmspec -P fails" "a macro typo in Requires is red"
  has rs-red rpmspec "pythn.spec: rpmspec -P fails" "a macro typo in BuildRequires is red"
  has rs-red rpmspec "warnline.spec: rpmspec -P fails" "an error after a warned comment is red"
  hasnt rs-red rpmspec "warnline.spec:6 is a comment" "a warning's line is no error line"
  [ ! -e "$work/rs-red/obsolete.spec" ] \
    || has rs-red rpmspec "obsolete.spec: rpmspec -P fails: error: %patchN is obsolete" "%patchN is red on rpm 4.20"
  hasnt rs-red rpmspec "UNKNOWN" "no wrong spec passes as a host gap"

  got pp-log; sec pp-log prep 0; has pp-log prep "note: not run: the --build-log build ran %prep" "skipped with --build-log"

  got pp-nobw
  sec pp-nobw prep 0
  has pp-nobw prep "UNKNOWN: %prep not run: no sandbox (bwrap: no permission)" "no sandbox is UNKNOWN"
  [ ! -e "$work/home/.gate-test-ran" ] && pass "prep: nothing ran without the sandbox" || fail "prep: %prep ran unsandboxed"
  grep -qE '^VERDICT: .*not proven on this host.*no sandbox' <<<"$out" && pass "prep: no sandbox is on the verdict line" \
    || { fail "prep: no sandbox not on the verdict line"; grep VERDICT <<<"$out"; }
  if [ "$sbx" = 1 ]; then
    got pp-ok
    sec pp-ok prep 0
    has pp-ok prep "OK: %prep of ok.spec ran in" "a patch that applies"
    has pp-ok prep "UNKNOWN: %prep of host.spec stopped on what this host lacks: /usr/share/gate-test-no-such-pkg/*" "a /usr file of a missing BuildRequires is UNKNOWN"
    has pp-ok prep "UNKNOWN: %prep of arch.spec stopped on what this host lacks: a build arch (rpm: Architecture is excluded:" "an excluded host arch is UNKNOWN"
    has pp-ok prep "OK: %prep of net.spec ran in" "no network but loopback in the sandbox"
    has pp-ok prep "OK: %prep of home.spec ran in" "\$HOME is empty in the sandbox"
    has pp-ok prep "OK: %prep of secret.spec ran in" "no environment, core dump or journal of the host in the sandbox"
    has pp-ok prep "UNKNOWN: %prep of svc.spec stopped on what this host lacks: gate-test-made-by-tar.tar.gz, which a source service makes" "a source a buildtime service makes is UNKNOWN"
    has pp-ok prep "UNKNOWN: %prep of esc.spec stopped on what this host lacks: gatetest" "a command of a missing BuildRequires is UNKNOWN"
    grep '^VERDICT' <<<"$out" | grep -q $'\x1b' && fail "prep: an escape from upstream text reached the verdict line" \
      || pass "prep: upstream text is sanitized on the verdict line"
    has pp-cache prep "OK: %prep of ok.spec passed on these sources before (cached)" "a pass is cached"
    has pp-salt prep "OK: %prep of salt.spec ran in" "a pass from before the sandbox is no pass"

    got pp-red
    sec pp-red prep 1
    has pp-red prep "bad.spec: %prep fails" "a patch that does not apply is red"
    has pp-red prep "mixed.spec: %prep fails" "an earlier miss the spec tolerates is no excuse"
    has pp-red prep "typo.spec: %prep fails" "a missing command with every BuildRequires here is red"
    has pp-red prep "rofs.spec: %prep fails" "writing into the checkout fails"
    [ ! -e "$work/pp-red/gate-written" ] && pass "prep: the checkout stays untouched" || fail "prep: %prep wrote into the checkout"
    has pp-red prep "svc.spec: %prep fails" "a missing source no source service makes is red"
    has pp-red prep "noparse.spec: not run: the spec does not parse" "an unparsable spec is red"
    grep -qE '^VERDICT: RED — [^(]*\bprep\b' <<<"$out" && pass "prep: red on the verdict line" || fail "prep: not on the verdict line"
    got pp-df; sec pp-df prep 0; has pp-df prep "UNKNOWN: %prep of room.spec not run: not enough free space under /var/tmp" "too little space is UNKNOWN"

    gone() { # gone <pkg> <sleep arg> <what>: no %prep process and no scratch directory left
      local _; for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "sleep $2" > /dev/null || break; sleep 0.3; done
      if ! pgrep -f "sleep $2" > /dev/null && ! compgen -G "/var/tmp/gate-prep-$1.*" > /dev/null; then pass "prep: $3"
      else fail "prep: $3: left $(pgrep -f "sleep $2" | wc -l) process(es), $(compgen -G "/var/tmp/gate-prep-$1.*" | wc -l) dir(s)"
           pkill -f "sleep $2"; for d in /var/tmp/gate-prep-"$1".*; do [ ! -d "$d" ] || { chmod -R u+w "$d"; rm -rf "$d"; }; done; fi
    }
    got pp-tmo; sec pp-tmo prep 1; has pp-tmo prep "UNKNOWN: %prep of slow.spec did not finish in 2 s" "the time limit is red"
    gone pp-tmo "$s2" "the time limit leaves nothing behind"
    bash "$GATE" "$work/pp-sig" > "$work/sig.out" 2>&1 & gp=$!
    for _ in $(seq 1 100); do pgrep -f "sleep $s1" > /dev/null && break; sleep 0.2; done
    kill -TERM "$gp"; wait "$gp"; rc=$?
    [ "$rc" = 130 ] && pass "prep: a TERM exits 130" || fail "prep: TERM: rc=$rc"
    gone pp-sig "$s1" "a TERM leaves nothing behind"
  else
    echo "SKIP: the %prep cases in the sandbox (no bwrap sandbox starts here)"
  fi
  got pp-emb
  grep -qE '^VERDICT: .*1 EMBEDS\? line\(s\) for the review' <<<"$out" && pass "source-binaries: an EMBEDS? line is counted on the verdict line" \
    || { fail "source-binaries: EMBEDS? not on the verdict line"; grep -E 'EMBEDS|VERDICT' <<<"$out" | sed 's/^/    /'; }
  got sp-defect
  grep -qF "## spec-cleaner: rc=1" <<<"$out" \
    && grep -qF "KNOWN DEFECT: p.spec:11: spec-cleaner's \`%opt_macro -p foo\` does not parse" "$work/gate-sp-defect/spec-cleaner.txt" \
    && grep -qF -- "%cargo_build -- <args>" "$work/gate-sp-defect/spec-cleaner.txt" \
    && pass "spec-cleaner: an unbraced macro that no longer parses is a known defect, with the -- form" \
    || { fail "spec-cleaner known defect"; sed 's/^/    /' "$work/gate-sp-defect/spec-cleaner.txt"; }
  got sp-dash
  grep -qF "## spec-cleaner: rc=0" <<<"$out" && pass "spec-cleaner: the -- form is left alone" \
    || { fail "spec-cleaner -- form"; sed 's/^/    /' "$work/gate-sp-dash/spec-cleaner.txt"; }
  got sp-group
  grep -qF "## spec-cleaner: rc=1" <<<"$out" && ! grep -qF "KNOWN DEFECT" "$work/gate-sp-group/spec-cleaner.txt" \
    && pass "spec-cleaner: a hunk that parses is no known defect" || { fail "spec-cleaner group hunk"; sed 's/^/    /' "$work/gate-sp-group/spec-cleaner.txt"; }
else
  echo "SKIP: rpmspec, %prep and spec-cleaner parse checks (no rpmspec, rpmbuild or bwrap)"
fi
# factory-auto declines a request whose .changes files all match the target's
# ("No changelog": sr#1394259 and 16 more, vendor strips filed with the
# .changes as it was). A tree that differs needs a top entry the target lacks,
# and, when the target is Factory's devel project, one Factory lacks.
md5_files() { # <dir>: .osc/_files listing the committed copies with their md5
  python3 -I - "$1" <<'PY'
import hashlib, os, sys
d = sys.argv[1]
src = os.path.join(d, ".osc", "sources")
pkg = open(os.path.join(d, ".osc", "_package")).read().strip()
ents = "".join('<entry name="%s" md5="%s"/>' % (n, hashlib.md5(open(os.path.join(src, n), "rb").read()).hexdigest())
               for n in sorted(os.listdir(src)))
open(os.path.join(d, ".osc", "_files"), "w").write('<directory name="%s" rev="1">%s</directory>\n' % (pkg, ents))
PY
}
ce() { # <name> <rc> <expected line> <gate args...>
  local n=$1 r=$2 m=$3; shift 3; og "$@"
  grep -qF "## changes-entry: rc=$r" <<<"$out" && grep -qF -- "$m" <<<"$out" && pass "changes-entry $n (rc=$r)" \
    || { fail "changes-entry $n: expected rc=$r and '$m'"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
co "$work/t-ce-branch" 'home:<you>:branches:devel:example' devel:example "$O/devel:example/foo"
cp "$work/t-ce-branch/.osc/sources/foo.changes" "$work/t-ce-branch/foo.changes"
ce branch-no-entry 1 "RED: foo.spec changed vs devel:example/foo, and no .changes has a top entry it lacks" "$work/t-ce-branch"
grep -q "^VERDICT: RED — .*changes-entry" <<<"$out" && pass "changes-entry branch-no-entry: the verdict names it" \
  || fail "changes-entry branch-no-entry: not in the verdict"
grep -qF -- "--amend-top" <<<"$out" && grep -qF -- "--no-entry REASON" <<<"$out" \
  && pass "changes-entry branch-no-entry: names --amend-top and --no-entry" \
  || fail "changes-entry branch-no-entry: no --amend-top or --no-entry in the red line"
# The user's exemption, or a cosmetic change: --no-entry REASON passes it,
# prints the reason and records it in the stamp for the change review.
ce no-entry 0 "NO ENTRY: comment-only cleanup" "$work/t-ce-branch" --no-entry "comment-only cleanup"
# A lookup it cannot make stays red under --no-entry: the reason waives an entry, not a check.
: > "$O/fail-list"
ce no-entry-unreadable 2 "UNKNOWN: cannot list devel:example/foo" "$work/t-ce-branch" --no-entry "comment-only cleanup"
rm "$O/fail-list"
out="$(HOME="$work/home" bash "$GATE" "$work/t-ce-branch" --no-entry "" 2>&1)"; rc=$?
[ "$rc" = 2 ] && pass "--no-entry needs a reason" || fail "--no-entry empty: rc=$rc"
out="$(HOME="$work/home" bash "$GATE" "$work/t-ce-branch" --review "$work/rv.txt" --no-entry x 2>&1)"; rc=$?
[ "$rc" = 2 ] && pass "--review with --no-entry: usage" || fail "--review with --no-entry: rc=$rc"
ce branch-entry 0 "OK: foo.changes: its top entry is new vs devel:example/foo" "$work/t-good"
grep -qF "OK: foo.changes: its top entry is new vs openSUSE:Factory/foo" <<<"$out" \
  && pass "changes-entry branch-entry: Factory's devel project as the target, so Factory too" \
  || { fail "changes-entry branch-entry: Factory not compared"; printf '%s\n' "$out" | sed 's/^/    /'; }
co "$work/t-ce-direct" devel:example - "$O/devel:example/foo"; md5_files "$work/t-ce-direct"
cp "$work/t-ce-direct/.osc/sources/foo.changes" "$work/t-ce-direct/foo.changes"
ce direct-no-entry 1 "RED: foo.spec changed vs the committed copy, and no .changes has a top entry it lacks" "$work/t-ce-direct"
# Committed already, the tree is the committed copy: Factory, where it goes
# next, still sees a change with no entry.
printf 'Name: baz\nVersion: 1.0\n' | put openSUSE:Factory/baz baz.spec
e "Mon Jan  5" "Update to 1.0" | put openSUSE:Factory/baz baz.changes
echo full | put openSUSE:Factory/baz vendor.tar
mkdir -p "$O/devel:example/baz"; cp "$O/openSUSE:Factory/baz/baz.spec" "$O/openSUSE:Factory/baz/baz.changes" "$O/devel:example/baz/"
echo stripped > "$O/devel:example/baz/vendor.tar"; echo devel:example/baz > "$O/devel/baz"
rm -rf "$work/t-ce-baz"; mkdir -p "$work/t-ce-baz/.osc/sources"; printf 'baz\n' > "$work/t-ce-baz/.osc/_package"
printf 'devel:example\n' > "$work/t-ce-baz/.osc/_project"; printf '2.0\n' > "$work/t-ce-baz/.osc/_osclib_version"
cp "$O/devel:example/baz/"* "$work/t-ce-baz/.osc/sources/"; cp "$O/devel:example/baz/"* "$work/t-ce-baz/"; md5_files "$work/t-ce-baz"
ce committed-vs-factory 1 "RED: vendor.tar changed vs openSUSE:Factory/baz, and no .changes has a top entry it lacks" "$work/t-ce-baz"
grep -qF "OK: no file differs from the committed copy" <<<"$out" && pass "changes-entry committed-vs-factory: nothing to commit" \
  || fail "changes-entry committed-vs-factory: the committed copy differs"
# --no-entry waives a missing entry for a devel target, Factory compared beside it or not:
# committed (here), a commit there (A) or a branch of it (C), devel equal to Factory. Never
# for openSUSE:Factory as the target (D): factory-auto declines that whatever the reason.
ce no-entry-vs-factory 0 "NO ENTRY: comment-only cleanup" "$work/t-ce-baz" --no-entry "comment-only cleanup"
printf 'Name: same\nVersion: 1.0\n' | put openSUSE:Factory/same same.spec
e "Mon Jan  5" "Update to 1.0" | put openSUSE:Factory/same same.changes
mkdir -p "$O/devel:example/same"; cp "$O/openSUSE:Factory/same/"* "$O/devel:example/same/"; echo devel:example/same > "$O/devel/same"
same_co() { # <dir> <project> <link project or ->: a checkout of same, a comment added to its spec
  rm -rf "$1"; mkdir -p "$1/.osc/sources"; printf 'same\n' > "$1/.osc/_package"; printf '%s\n' "$2" > "$1/.osc/_project"
  printf '2.0\n' > "$1/.osc/_osclib_version"; cp "$O/devel:example/same/"* "$1/.osc/sources/"; cp "$O/devel:example/same/"* "$1/"
  md5_files "$1"; [ "$3" = - ] || sed -i "s|rev=\"1\">|&<linkinfo project=\"$3\" package=\"same\" srcmd5=\"x\"/>|" "$1/.osc/_files"
  echo '# built from source' >> "$1/same.spec"
}
same_co "$work/t-ce-sa" devel:example -
ce no-entry-devel-commit 0 "NO ENTRY: comment-only cleanup" "$work/t-ce-sa" --no-entry "comment-only cleanup"
same_co "$work/t-ce-sc" 'home:<you>:branches:devel:example' devel:example
ce no-entry-devel-branch 0 "NO ENTRY: comment-only cleanup" "$work/t-ce-sc" --no-entry "comment-only cleanup"
same_co "$work/t-ce-sd" 'home:<you>:branches:openSUSE:Factory' openSUSE:Factory
ce factory-target 1 "RED: same.spec changed vs openSUSE:Factory/same" "$work/t-ce-sd" --target openSUSE:Factory
grep -qF -- "--no-entry REASON" <<<"$out" && fail "changes-entry factory-target: the red line offers --no-entry" \
  || pass "changes-entry factory-target: the red line offers no --no-entry"
ce no-entry-factory-target 1 "NO ENTRY refused" "$work/t-ce-sd" --target openSUSE:Factory --no-entry "comment-only cleanup"
# --amend-top: devel's unaccepted top entry, which Factory lacks, still describes the fix.
co "$work/t-ce-amend" devel:example - "$O/devel:example/foo"; md5_files "$work/t-ce-amend"
cp "$work/t-ce-amend/.osc/sources/foo.changes" "$work/t-ce-amend/foo.changes"
ce amend-top-draft 0 "OK: foo.changes: its top entry is new vs openSUSE:Factory/foo" "$work/t-ce-amend" --amend-top 'Jane Packager'
# A new package has no entry to compare.
ce new-package 0 "note: devel:other/foo does not exist: a new package there, no entry to compare" "$work/t-new" --target devel:other
# A git checkout: against the base ref.
{ g clone -q "$work/seed" "$work/ce-git" && printf 'Name: p\nVersion: 2\n' > "$work/ce-git/p.spec"; } || fail "could not build the git fixture"
out="$(bash "$GATE" "$work/ce-git" 2>&1)"
grep -qF "## changes-entry: rc=1" <<<"$out" && grep -qF "RED: p.spec changed vs origin/" <<<"$out" \
  && pass "changes-entry git-no-entry (rc=1)" || { fail "changes-entry git-no-entry"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(bash "$GATE" "$work/clone" --entries 2 2>&1)"
grep -qF "## changes-entry: rc=0" <<<"$out" && pass "changes-entry git-entry (rc=0)" \
  || { fail "changes-entry git-entry"; printf '%s\n' "$out" | sed 's/^/    /'; }

# A spec comment is one line, two at most: a comment block the change adds
# that runs past three lines is red (a 9-line %check comment, 10-line
# Legal-Review-Notices), the header excepted, as are commented-out spec lines
# and Source-Binary-Exception lines. A Legal-Review-Notice is its notice line
# and short bullets. Without the target's spec every comment counts as added.
sc_hdr='#
# spec file for package p
#
# Copyright (c) 2026 SUSE LLC and contributors
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for modifications is in the file named COPYING.
#
# Please submit bugfixes or comments via https://bugs.opensuse.org/
#
'
cm() { # <name> <rc> <expected line> < spec body after the header
  mkdir -p "$work/cm-$1"; { printf '%s\n' "$sc_hdr"; cat; } > "$work/cm-$1/p.spec"
  out="$(bash "$GATE" "$work/cm-$1" 2>&1)"
  grep -qF "## spec-comments: rc=$2" <<<"$out" && grep -qF -- "$3" <<<"$out" && pass "spec-comments $1 (rc=$2)" \
    || { fail "spec-comments $1: expected rc=$2 and '$3'"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
cm short 0 "OK: no comment block the change adds runs past 3 lines" <<'EOF'
Name:           p
# Two lines say why:
# the test needs a network.
%check
EOF
cm long 1 "p.spec:15: a 5-line comment" <<'EOF'
Name:           p
%check
# The default addopts in pyproject.toml deselect the integration tests,
# which need a running server; the remaining tests are all unit tests
# and run offline. Two of them time out on the slow workers, so they are
# skipped below; upstream knows (issue 12) and plans a fix in the next
# release, after which this can go.
pytest -k 'not slow'
EOF
cm code-lines 0 "OK: no comment block" <<'EOF'
Name:           p
#BuildRequires:  foo
#BuildRequires:  bar
#BuildRequires:  baz
#Requires:       qux
# Source-Binary-Exception: a.bin -- firmware: no source exists for it
# Source-Binary-Exception: b.bin -- firmware: no source exists for it
# Source-Binary-Exception: c.bin -- firmware: no source exists for it
# Source-Binary-Exception: d.bin -- firmware: no source exists for it
EOF
cm notice-bullets 0 "OK: no comment block" <<'EOF'
Name:           p
# Legal-Review-Notice: statically linked besides MIT:
# - MPL-2.0: option-ext; vendor.tar.zst carries its source.
# - ISC: ring, untrusted.
# - Unicode-3.0: the icu_* crates, with their
#   tables in regex-syntax.
License:        MIT AND MPL-2.0 AND ISC AND Unicode-3.0
EOF
cm notice-prose 1 "a Legal-Review-Notice line that is no short bullet" <<'EOF'
Name:           p
# Legal-Review-Notice: 155 crates are statically linked into libfoo (cargo
# tree -e normal). Beyond MIT and the dual MIT/Apache-2.0 majority: BSL-1.0
# from xxhash-rust.
License:        MIT AND BSL-1.0
EOF
# Real notices list 15-23 findings: no cap on bullets. The notice line may
# wrap once, and it may carry a bug id: "Legal-Review-Notice (boo#N):".
{ echo 'Name:           p'; echo '# Legal-Review-Notice: linked besides MIT:'
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do echo "# - L$i: crate$i"; done
  echo 'License:        MIT'; } | cm notice-many 0 "OK: no comment block"
cm notice-boo 0 "OK: no comment block" <<'EOF'
Name:           p
# Legal-Review-Notice (boo#1273104): linked besides MIT:
# - MPL-2.0: cssparser and seven sibling crates.
# - GPL-3.0-only named in a jbig2.rs doc comment only.
# - ISC: ring.
License:        MIT AND MPL-2.0 AND ISC
EOF
cm notice-header-wrap 0 "OK: no comment block" <<'EOF'
Name:           p
# Legal-Review-Notice: crates statically linked into the shipped binary,
#   besides MIT:
# - MPL-2.0: option-ext.
# - ISC: ring.
License:        MIT AND MPL-2.0 AND ISC
EOF
cm notice-header-wrap-twice 1 "a Legal-Review-Notice line that is no short bullet" <<'EOF'
Name:           p
# Legal-Review-Notice: crates statically linked into the shipped binary,
#   taken from the unit graph, identical on both arches,
#   besides MIT:
# - ISC: ring.
License:        MIT AND ISC
EOF
# Against the target: its own long comments are not the change's, kept or
# moved; a long one the change adds is red.
printf 'Name: foo\nVersion: 0.9.8\n%%check\n# one\n# two\n# three\n# four\n# five\nmake check\n' | put devel:example/foo foo.spec
co "$work/t-cm" 'home:<you>:branches:devel:example' devel:example "$O/devel:example/foo"
og "$work/t-cm"
grep -qF "## spec-comments: rc=0" <<<"$out" && pass "spec-comments: the target's own 5-line comment is not the change's" \
  || { fail "spec-comments: target's comment"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf 'Name: foo\nVersion: 1.0\n# one\n# two\n# three\n# four\n# five\n%%check\nmake check\n' > "$work/t-cm/foo.spec"
og "$work/t-cm"
grep -qF "## spec-comments: rc=0" <<<"$out" && pass "spec-comments: the target's comment moved is not the change's" \
  || { fail "spec-comments: moved comment"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf 'Name: foo\nVersion: 1.0\n%%check\n# one\n# two\n# three\n# four\n# five\n# The suite needs a network\n# since 1.0, which the\n# build has not, so only\n# the unit tests run.\nmake check\n' > "$work/t-cm/foo.spec"
og "$work/t-cm"
grep -qF "## spec-comments: rc=1" <<<"$out" && grep -qF "foo.spec:4: a 4-line comment" <<<"$out" \
  && pass "spec-comments: a 4-line comment added to the target's is red" \
  || { fail "spec-comments: added comment"; printf '%s\n' "$out" | sed 's/^/    /'; }
# Bare "#" lines neither hide in the target's header nor split a comment.
hdr 2026 '' | put devel:example/foo foo.spec
co "$work/t-cm-hash" 'home:<you>:branches:devel:example' devel:example "$O/devel:example/foo"
{ cat "$O/devel:example/foo/foo.spec"; printf '# one\n# two\n#\n# three\n# four\n#\n# five\n'; } > "$work/t-cm-hash/foo.spec"
og "$work/t-cm-hash"
grep -qF "## spec-comments: rc=1" <<<"$out" && grep -qF "a 5-line comment" <<<"$out" \
  && pass "spec-comments: a comment split by bare # lines is one comment" \
  || { fail "spec-comments: bare # lines"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf 'Name: foo\nVersion: 0.9.8\n' | put devel:example/foo foo.spec

echo "---"; [ "$fails" = 0 ] && echo "all gate checks passed" || echo "$fails FAILED"
exit $((fails > 0))
