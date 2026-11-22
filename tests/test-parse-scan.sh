#!/bin/bash
# test-parse-scan.sh — proves scripts/_parse_scan.py finds the parse-time
# constructs of a spec as text (what rpm runs, loads or expands twice while it
# parses), leaves the look-alikes alone, and counts a construct Factory's spec
# has verbatim as added once a file it reads or a macro it uses changed.
# Offline; drives the CLI. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
# shellcheck disable=SC2016  # the single-quoted $ and $(...) are spec text, never shell
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/../skills/opensuse-packaging/scripts/_parse_scan.py"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# hit <name> <kinds> < line: the line is one construct, of those kinds
hit() {
  local out rc; cat > "$work/c.spec"
  out="$(python3 -I "$SCAN" constructs "$work/c.spec" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && grep -qF -- "— $2: construct" <<<"$out" && [ "$(grep -c '^[^ ]' <<<"$out")" = 1 ] \
    && pass "construct $1 ($2)" || { fail "construct $1: expected '$2', got rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
# miss <name> < lines: no construct
miss() {
  local out rc; cat > "$work/c.spec"
  out="$(python3 -I "$SCAN" constructs "$work/c.spec" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && pass "no construct: $1" \
    || { fail "no construct: $1: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
hit shell 'shell' <<<'%global short %(c=%{commit}; echo ${c:0:7})'
hit lua-block 'lua' <<'EOF'
%{lua:
  local t = { 1, 2 }
  print(t[1])
}
EOF
hit lua-bare 'lua' <<<'%lua print(1)'
hit lua-conditional 'lua' <<<'Requires: %{?lua:x}'
hit expand-indirection 'expand, %%' <<<'%define x %{expand:%%%{o}id)}'
hit include 'include' <<<'%include %{SOURCE1}'
hit load 'load' <<<'%{load:%{_sourcedir}/foo.macros}'
hit load-bare 'load' <<<'%load foo.macros'
hit escape '%%' <<<"%python_expand echo %%{\$python_sitelib}"
hit escape-stored '%%' <<<'%global fmt %%s'
hit lone-tag 'lone %' <<<'Summary: 100%'
hit lone 'lone %' <<<'%global p %'
hit lower 'lower' <<<'%global y %{lower:%{LUA:print(1)}}'
hit dirname 'dirname' <<<'%global x %{dirname:%{lu/x}}a:print(1)}'
hit macrobody 'macrobody' <<<'%global x %{macrobody:_build_name_fmt}'
hit glue-eol 'glue' <<<'%define a %lu'
hit glue-quote 'glue' <<<'%global x %{expr:"%l" + "ua print(1)"}'
hit glue-args 'glue' <<<'%define f() %1%2'
# Forms an independent review ran under rpm 4.20: a Lua call in an expression, a
# directive behind %%, shrink trimming a space to join %lu to its "a", the u2p
# alias, a CR inside a line and a NUL ending one, as rpm reads them.
hit if-lua 'lua' <<<'%if lua:os.execute("id")'
hit elif-lua 'lua' <<<'%elif lua:os.execute("id")'
hit bracket-lua 'lua' <<<'echo %[lua:os.execute("id")]'
hit expr-lua 'lua' <<<'Release: %{expr:lua:os.execute("id")}'
hit escaped-include 'include' <<<'  %%include %{SOURCE9}'
hit shrink-glue 'shrink' <<<'%global x %{shrink:%lu }a print(1)'
hit u2p 'u2p' <<<'%global x %{u2p:%{lu/x}}'
hit cr-in-line '%%' < <(printf '%%global x 1\r%%%%(id)\nSummary: %%{x}\n')
hit nul-ends-line '%%' < <(printf '%%global x %%{?nil:\0}\n%%%%(id)}\nSummary: %%{x}\n')
# A Lua call that reaches an expression through a macro.
printf '%%define x lua:os.execute("id")\n%%if %%{x}\n%%endif\nRelease: %%{expr:%%{x}}\n' > "$work/luax.spec"
out="$(python3 -I "$SCAN" constructs "$work/luax.spec")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'luax.spec:2: %if %{x} — lua: construct' <<<"$out" && grep -qF 'luax.spec:4: Release: %{expr:%{x}} — lua: construct' <<<"$out" \
  && pass "construct lua-through-a-macro" || { fail "construct lua-through-a-macro: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# A construct line that is no UTF-8: listed with its bytes escaped, never a traceback.
printf '%%global x %%(echo \377\376)\n' > "$work/bad.spec"
out="$(python3 -I "$SCAN" constructs "$work/bad.spec" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qF 'bad.spec:1: %global x %(echo \xff\xfe) — shell: construct' <<<"$out" && ! grep -q Traceback <<<"$out" \
  && pass "a construct line that is no UTF-8 is listed, its bytes escaped" || { fail "non-UTF-8 line: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
hit shell-continued 'shell' <<'EOF'
%global x %(echo \
  more)
EOF
miss look-alikes <<'EOF'
# %%check runs unprivileged; 100% offline
date +%%Y%%m%%d
printf '%%s\n' %{name} > %{_builddir}/list
Name:           foo
BuildRequires:  %{lua_version} lua-devel
Provides:       %{name}(x86-64)
Source0:        %url/archive/foo-%{version}.tar.gz
%dir %{_datadir}/foo
%{?load_thing}
%global debug_package %{nil}
%{quote:a b}
%install
%make_install
%files
%license LICENSE
EOF

# added <name> <rc> <expected or -> <new file> <base file> [changed...]
added() {
  local out rc; out="$(python3 -I "$SCAN" added "$4" "$5" 2>&1)"; rc=$?
  { [ "$rc" = "$2" ] && { [ "$3" = - ] && [ -z "$out" ] || grep -qF -- "$3" <<<"$out"; }; } \
    && pass "added $1 (rc=$2)" || { fail "added $1: expected rc=$2 '$3', got rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
printf 'Name: foo\nVersion: 1.2\n%%global commit 0123abcd\n%%global short %%(c=%%{commit}; echo ${c:0:7})\n%%{lua:\n  print("a")\n}\n' > "$work/base.spec"
cp "$work/base.spec" "$work/same.spec"; sed -i 's/$/  /' "$work/same.spec"
added trailing-blanks 0 - "$work/same.spec" "$work/base.spec"
sed 's/^Version: 1.2$/Version: 1.3/; s/0123abcd/fedcba98/' "$work/base.spec" > "$work/bump.spec"
added version-and-commit 0 - "$work/bump.spec" "$work/base.spec"
sed 's/0123abcd/$(id)/' "$work/base.spec" > "$work/inject.spec"
added commit-injected 1 "inject.spec:4: %global short %(c=%{commit}; echo \${c:0:7}) — shell: uses %commit, defined anew" \
  "$work/inject.spec" "$work/base.spec"
sed 's/print("a")/os.execute("id")/' "$work/base.spec" > "$work/lua.spec"
added lua-body-changed 1 'lua.spec:5: %{lua: (+2 lines) — lua: new' "$work/lua.spec" "$work/base.spec"
added no-base 1 'shell: new' "$work/base.spec" "$work/no-such-file"
# Seen on real specs: an escaped URL in a Source tag and a date taken from the
# .changes keep a version bump green; a glob a shell line reads covers each file.
printf 'Name: j\nVersion: 1.4\nSource: https://x.example/J%%%%20%%%%28All%%%%29/%%{version}/j-%%{version}.tar.bz2\nD=$(date -r %%{_sourcedir}/%%{name}.changes +%%%%Y)\n' > "$work/url-base.spec"
sed 's/^Version: 1.4$/Version: 1.5/' "$work/url-base.spec" > "$work/url.spec"
added escaped-url-bump 0 - "$work/url.spec" "$work/url-base.spec"
printf 'Name: j\nVersion: 1.4\n%%global v %%%%%%{version}\n' > "$work/join-base.spec"
sed 's/^Version: 1.4$/Version: lua/' "$work/join-base.spec" > "$work/join.spec"
added plain-value-after-escape 1 'uses %version, defined anew' "$work/join.spec" "$work/join-base.spec"
printf 'Name: foo\n%%define f() %%(echo %%1)\n' > "$work/param-base.spec"
{ cat "$work/param-base.spec"; printf '%%f $(id)\n'; } > "$work/param.spec"
added parametric-new-call 1 'a new line calls %f' "$work/param.spec" "$work/param-base.spec"
printf 'Name: foo\n%%global inc %%{mydir}/x.inc\n%%include %%{inc}\n' > "$work/inc.spec"
added include-unnamed 1 'reads a file the text does not name' "$work/inc.spec" "$work/inc.spec"
# Tags rpm defines macros from, in either case: a new value under Factory's shell line counts.
for tag in 'URL:%{URL}' 'URL:%{url}' 'BugUrl:%{bugurl}' 'Source0:%{SOURCEURL0}' 'Version:%{VERSION}' \
           'DistTag:%{disttag}' 'Prefix:%{prefix}' 'SourceLicense:%{sourcelicense}'; do
  printf '%s https://a.example/x.tgz\n%%global u %%(echo %s)\n' "${tag%%:*}:" "${tag#*:}" > "$work/tag-base.spec"
  sed 's|x.tgz$|$(id)|' "$work/tag-base.spec" > "$work/tag.spec"
  added "tag-${tag#*:}" 1 'defined anew' "$work/tag.spec" "$work/tag-base.spec"
done
# %%{version} inside a %(...) is rpm query format text, no use of %version: a bump lists nothing.
printf 'Version: 1\n%%define requires_file() %%( rpm -q --qf "Requires: %%%%{name} >= %%%%{version}\\n" -f %%* )\n' > "$work/qf-base.spec"
sed 's/^Version: 1$/Version: 2/' "$work/qf-base.spec" > "$work/qf.spec"
added escaped-query-format 0 - "$work/qf.spec" "$work/qf-base.spec"
printf 'Name: foo\n%%global stamp %%(date)\n\033[31m%%global y %%(id)\n' > "$work/esc.spec"
out="$(python3 -I "$SCAN" constructs "$work/esc.spec")"
! grep -q $'\033' <<<"$out" && grep -qF 'esc.spec:3: %global y %(id) — shell' <<<"$out" \
  && pass "output is sanitized" || fail "output carries an escape: $out"

# needs and scan over a tree: an included file is followed and compared.
mkdir -p "$work/t" "$work/b" "$work/empty"
printf 'Name: foo\nSource1: foo.inc\n%%include %%{SOURCE1}\n' | tee "$work/t/foo.spec" > "$work/b/foo.spec"
printf '%%define x 1\n' | tee "$work/t/foo.inc" > "$work/b/foo.inc"
printf 'Name: foo-doc\n' > "$work/t/foo-doc.spec"
out="$(python3 -I "$SCAN" needs "$work/t")"
[ "$out" = $'foo.inc\nfoo.spec' ] && pass "needs: the spec with a construct and its include" || fail "needs: '$out'"
out="$(python3 -I "$SCAN" scan "$work/t" "$work/b")"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "scan: identical to the base" || fail "scan identical: rc=$rc $out"
printf '%%define x %%(id)\n' > "$work/t/foo.inc"
out="$(python3 -I "$SCAN" scan "$work/t" "$work/b")"; rc=$?
[ "$rc" = 1 ] && [ "$out" = 'foo.inc:1: %define x %(id) — shell: new' ] \
  && pass "scan: an included file is read in its place, its new construct listed" || { fail "scan include: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf 'Source1000: https://registry.example/a-1.tgz\n' > "$work/t/foo.inc"
out="$(python3 -I "$SCAN" scan "$work/t" "$work/b")"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "scan: an included file that changed without a construct is green" \
  || { fail "scan include, tags only: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
sed -i 's/^Source1: foo.inc$/Source1: evil.inc/' "$work/t/foo.spec"; cp "$work/b/foo.inc" "$work/t/foo.inc"
printf '%%global y %%(id)\n' > "$work/t/evil.inc"
out="$(python3 -I "$SCAN" scan "$work/t" "$work/b")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'evil.inc:1: %global y %(id) — shell: new' <<<"$out" \
  && pass "scan: a Source tag pointed at another file reads that one" || { fail "scan retarget: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# A loaded macro file that differs counts as a whole; another file a construct names
# is compared by the md5 in Factory's listing, not fetched.
mkdir -p "$work/t2" "$work/b2"
printf 'Name: foo\nSource1: foo.macros\nSource2: data.txt\n%%{load:%%{SOURCE1}}\n%%global n %%(wc -l < %%{SOURCE2})\n' \
  | tee "$work/t2/foo.spec" > "$work/b2/foo.spec"
printf '%%foo_x 1\n' | tee "$work/t2/foo.macros" > "$work/b2/foo.macros"; printf 'a\n' > "$work/t2/data.txt"
out="$(python3 -I "$SCAN" needs "$work/t2")"
[ "$out" = $'foo.macros\nfoo.spec' ] && pass "needs: the loaded file, not the data a shell line reads" || fail "needs load: '$out'"
printf '<directory name="foo"><entry name="data.txt" md5="%s"/></directory>\n' "$(md5sum < "$work/t2/data.txt" | cut -d' ' -f1)" > "$work/list.xml"
out="$(python3 -I "$SCAN" scan "$work/t2" "$work/b2" "$work/list.xml")"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "scan: the data file's md5 matches the listing" || { fail "scan md5: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf 'b\n' > "$work/t2/data.txt"
out="$(python3 -I "$SCAN" scan "$work/t2" "$work/b2" "$work/list.xml")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'foo.spec:5: %global n %(wc -l < %{SOURCE2}) — shell: reads data.txt, which differs' <<<"$out" \
  && pass "scan: a data file a shell line reads that differs" || { fail "scan data: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf '%%foo_x 2\n' > "$work/t2/foo.macros"; printf 'a\n' > "$work/t2/data.txt"
out="$(python3 -I "$SCAN" scan "$work/t2" "$work/b2" "$work/list.xml")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'foo.spec:4: %{load:%{SOURCE1}} — load: reads foo.macros, which differs' <<<"$out" \
  && pass "scan: a loaded file that differs counts" || { fail "scan load: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(python3 -I "$SCAN" scan "$work/t" "$work/empty")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'evil.inc:1: %global y %(id) — shell: new' <<<"$out" && pass "scan: no base, every construct is new" || fail "scan no base: rc=$rc $out"
mkdir -p "$work/t3" "$work/b3"
printf 'Name: g\n%%global n %%(cat %%{_sourcedir}/*.patch | wc -l)\n' | tee "$work/t3/g.spec" > "$work/b3/g.spec"
printf 'a\n' | tee "$work/t3/g-1.patch" > "$work/b3/g-1.patch"; printf 'b\n' > "$work/t3/g-2.patch"
out="$(python3 -I "$SCAN" scan "$work/t3" "$work/b3")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'reads g-2.patch, which differs' <<<"$out" \
  && pass "scan: a glob a shell line reads covers each file it matches" || { fail "scan glob: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# Only a running line reads: a Source tag's escaped URL names its file, and a sed
# expression's [a-z]* is no glob; both stay green while those files change.
mkdir -p "$work/t4" "$work/b4"
printf 'Name: h\nSource1: https://x.example/a%%%%20b/h.txt\n%%global o %%(echo x | sed "s/-flto=[a-z]*//")\n' \
  | tee "$work/t4/h.spec" > "$work/b4/h.spec"
printf 'a\n' > "$work/b4/h.txt"; printf 'b\n' > "$work/t4/h.txt"
out="$(python3 -I "$SCAN" scan "$work/t4" "$work/b4")"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "scan: no file read by a tag line or a regex" || { fail "scan reads: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# An escaped %%include is read in its place like %include.
mkdir -p "$work/t5" "$work/b5"
printf 'Name: e\n%%%%include evil.inc\n' | tee "$work/t5/e.spec" > "$work/b5/e.spec"
printf '%%global y %%(id)\n' > "$work/t5/evil.inc"
out="$(python3 -I "$SCAN" scan "$work/t5" "$work/b5")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'evil.inc:1: %global y %(id) — shell: new' <<<"$out" \
  && pass "scan: an escaped %%include is followed" || { fail "scan escaped include: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# A file named through a macro another file defines: the spec's Source5, read by a
# shell line of the file it includes; and a file an included file includes through
# the spec's Source2. Only the data, or the nested file, changes.
mkdir -p "$work/t6" "$work/b6"
printf 'Name: m\nSource1: m.inc\nSource5: data.txt\n%%include %%{SOURCE1}\n' | tee "$work/t6/m.spec" > "$work/b6/m.spec"
printf '%%global n %%(cat %%{SOURCE5})\n' | tee "$work/t6/m.inc" > "$work/b6/m.inc"
printf 'a\n' > "$work/b6/data.txt"; printf 'b\n' > "$work/t6/data.txt"
out="$(python3 -I "$SCAN" scan "$work/t6" "$work/b6")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'm.inc:1: %global n %(cat %{SOURCE5}) — shell: reads data.txt, which differs' <<<"$out" \
  && pass "scan: a file named by the spec's macro in an included file's shell line" \
  || { fail "scan cross-file name: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
mkdir -p "$work/t7" "$work/b7"
printf 'Name: n\nSource1: outer.inc\nSource2: inner.inc\n%%include %%{SOURCE1}\n' | tee "$work/t7/n.spec" > "$work/b7/n.spec"
printf '%%include %%{SOURCE2}\n' | tee "$work/t7/outer.inc" > "$work/b7/outer.inc"
printf '%%define n_x 1\n' > "$work/b7/inner.inc"; printf '%%define n_x %%(id)\n' > "$work/t7/inner.inc"
out="$(python3 -I "$SCAN" needs "$work/t7")"
[ "$out" = $'inner.inc\nn.spec\nouter.inc' ] && pass "needs: a nested include named by the spec's macro" || fail "needs nested: '$out'"
out="$(python3 -I "$SCAN" scan "$work/t7" "$work/b7")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'inner.inc:1: %define n_x %(id) — shell: new' <<<"$out" \
  && pass "scan: a nested include named by the spec's macro is read in its place" \
  || { fail "scan nested include: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# The scanner reads nothing outside the checkout: an include through a directory
# link, or a top-level link to a file outside, is not read and is reported.
mkdir -p "$work/outside" "$work/t8" "$work/b8" "$work/t9" "$work/b9"
printf '%%global s %%(echo secret-outside)\n' > "$work/outside/x.inc"
printf 'Name: o\n%%include sub/x.inc\n' | tee "$work/t8/o.spec" > "$work/b8/o.spec"; ln -s "$work/outside" "$work/t8/sub"
out="$(timeout 30 python3 -I "$SCAN" scan "$work/t8" "$work/b8")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'o.spec:2: %include sub/x.inc — include: leaves the checkout' <<<"$out" && ! grep -q secret-outside <<<"$out" \
  && pass "scan: an include through a directory link out of the checkout is not read, and reported" \
  || { fail "scan directory link: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
printf 'Name: p\nSource1: link.inc\n%%include %%{SOURCE1}\n' | tee "$work/t9/p.spec" > "$work/b9/p.spec"
ln -s "$work/outside/x.inc" "$work/t9/link.inc"
out="$(timeout 30 python3 -I "$SCAN" needs "$work/t9")"
[ "$out" = p.spec ] && pass "needs: a link out of the checkout is never fetched" || fail "needs link: '$out'"
out="$(timeout 30 python3 -I "$SCAN" scan "$work/t9" "$work/b9")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'p.spec:3: %include %{SOURCE1} — include: leaves the checkout' <<<"$out" && ! grep -q secret-outside <<<"$out" \
  && pass "scan: a top-level link to a file outside the checkout is not read, and reported" \
  || { fail "scan file link: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# An %include is named with the definitions before it, as rpm names it; once a
# macro has two values it names no file, so that %include is never "verbatim".
mkdir -p "$work/t10" "$work/b10"
printf 'Name: lw\n%%define inc a.inc\n%%include %%{inc}\n%%define inc b.inc\n%%include %%{inc}\n' | tee "$work/t10/lw.spec" > "$work/b10/lw.spec"
printf '%%define lw_a 1\n' > "$work/b10/a.inc"; printf '%%define lw_a %%(id)\n' > "$work/t10/a.inc"
printf '%%define lw_b 1\n' | tee "$work/t10/b.inc" > "$work/b10/b.inc"
out="$(timeout 30 python3 -I "$SCAN" scan "$work/t10" "$work/b10")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'a.inc:1: %define lw_a %(id) — shell: new' <<<"$out" \
  && grep -qF 'lw.spec:5: %include %{inc} — include: reads a file the text does not name' <<<"$out" \
  && pass "scan: an %include through a macro defined twice is not verbatim" || { fail "scan redefined macro: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# Where a cap stops the scan, it says so and never claims the rest verbatim: a
# chain of includes past depth 8, a macro that expands past 64 KiB, and more than
# 8 MiB of included text; each returns within seconds.
mkdir -p "$work/t11" "$work/b11"
printf 'Name: deep\n%%include i1.inc\n' | tee "$work/t11/deep.spec" > "$work/b11/deep.spec"
for i in $(seq 1 10); do printf '%%include i%d.inc\n' $((i + 1)) | tee "$work/t11/i$i.inc" > "$work/b11/i$i.inc"; done
printf '%%define d 1\n' > "$work/b11/i11.inc"; printf '%%define d %%(id)\n' > "$work/t11/i11.inc"
out="$(timeout 30 python3 -I "$SCAN" scan "$work/t11" "$work/b11")"; rc=$?
[ "$rc" = 4 ] && grep -qF 'incomplete: an %include past depth 8 was not read' <<<"$out" \
  && pass "scan: an include chain past depth 8 is incomplete, not verbatim" || { fail "scan depth cap: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
mkdir -p "$work/t12" "$work/b12"
{ echo 'Name: blow'
  for x in aaa:bbb bbb:ccc ccc:ddd ddd:eee eee:fff fff:ggg ggg:hhh; do
    printf '%%define %s ' "${x%:*}"; for _ in $(seq 30); do printf '%%{%s}' "${x#*:}"; done; echo; done
  echo '%define hhh x'; echo '%global y %(echo %{aaa})'; } > "$work/t12/blow.spec"
out="$(timeout 30 python3 -I "$SCAN" scan "$work/t12" "$work/b12")"; rc=$?
[ "$rc" != 124 ] && grep -qF 'incomplete: a macro expands past 64 KiB' <<<"$out" \
  && pass "scan: a macro that expands past 64 KiB stops short within seconds, and says so" || { fail "scan expansion cap: rc=$rc"; printf '%s\n' "$out" | head -5 | sed 's/^/    /'; }
mkdir -p "$work/t13" "$work/b13"
{ echo 'Name: fan'; echo 'Source1: big.inc'; for _ in $(seq 12); do echo '%include %{SOURCE1}'; done; } | tee "$work/t13/fan.spec" > "$work/b13/fan.spec"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("# padding line of a large included file\n" * 25000)' "$work/t13/big.inc"
cp "$work/t13/big.inc" "$work/b13/big.inc"
out="$(timeout 30 python3 -I "$SCAN" scan "$work/t13" "$work/b13")"; rc=$?
[ "$rc" = 4 ] && grep -qF 'incomplete: more than 8 MiB of included text' <<<"$out" \
  && pass "scan: more than 8 MiB of included text stops short within seconds, and says so" || { fail "scan size cap: rc=$rc"; printf '%s\n' "$out" | head -5 | sed 's/^/    /'; }
# No OK on any doubt: each tree is its base but for the file rpm reads, which the
# scan cannot name for sure, so an incomplete: line names the macro (exit 4).
# twin <dir> <spec>: the same spec in the tree and its base; differ <dir> <file>
twin() { mkdir -p "$work/$1" "$work/$1b"; printf '%b' "$2" | tee "$work/$1/$1.spec" > "$work/$1b/$1.spec"; }
differ() { printf 'a\n' > "$work/$1b/$2"; printf 'b\n' > "$work/$1/$2"; }
doubt() {  # doubt <dir> <macro> <what>
  local out rc
  out="$(timeout 30 python3 -I "$SCAN" scan "$work/$1" "$work/$1b")"; rc=$?
  [ "$rc" = 4 ] && grep -qF "incomplete: %$2 has no single value the text gives" <<<"$out" \
    && pass "scan: $3, no OK" || { fail "scan $1: rc=$rc"; printf '%s\n' "$out" | head -5 | sed 's/^/    /'; }
}
twin amb 'Name: amb\n%define d a.txt\n%define d b.txt\n%global x %{expand:%(cat %{d})}\n'
printf 'a\n' | tee "$work/amb/a.txt" > "$work/ambb/a.txt"; differ amb b.txt
doubt amb d "a shell line reads through a macro given two values"
twin ifdef 'Name: ifdef\n%if 0%{?never}\n%define d -evil\n%endif\n%global x %(cat foo%{?d}.txt)\n'
differ ifdef foo.txt; doubt ifdef d "a macro defined inside %if"
twin late 'Name: late\n%global x %(cat foo%{?d}.txt)\n%define d -evil\n'
differ late foo.txt; doubt late d "a macro defined after the line that reads through it"
twin lazy 'Name: lazy\n%define x %(cat foo%{?d}.txt)\n%global y %{x}\n%define d -evil\n'
differ lazy foo.txt; doubt lazy d "a macro defined after a %define body first runs"
# A %define body runs where the macro is used: one above Version: that is used
# below it reads through %version for sure.
twin above 'Name: above\n%define sv %(cat data-%{version}.txt)\nVersion: 1\nRelease: %{sv}\n'
differ above data-1.txt
out="$(timeout 30 python3 -I "$SCAN" scan "$work/above" "$work/aboveb")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'above.spec:2: %define sv %(cat data-%{version}.txt) — shell: reads data-1.txt, which differs' <<<"$out" \
  && ! grep -q '^incomplete:' <<<"$out" \
  && pass "scan: a %define body above Version: runs where it is used" || { fail "scan above: rc=$rc"; printf '%s\n' "$out" | head -5 | sed 's/^/    /'; }
twin host 'Name: host\n%global s %(cat sums.%{_arch})\n'
differ host sums.x86_64; doubt host _arch "a macro the text never defines"
twin vers 'Name: vers\nVersion: 1\n%package sub\nVersion: 2\n%global x %(cat data-%{version}.txt)\n'
printf 'a\n' | tee "$work/vers/data-1.txt" > "$work/versb/data-1.txt"; differ vers data-2.txt
doubt vers version "a subpackage's Version: sets %version anew"
twin luadef 'Name: luadef\n%define d a.txt\n%{lua: rpm.define("d b" .. ".txt")}\n%global x %(cat %{d})\n'
printf 'a\n' | tee "$work/luadef/a.txt" > "$work/luadefb/a.txt"; differ luadef b.txt
doubt luadef d "Lua may define the macro"
# Only a Lua line defines macros: a Source named macros.lua is no Lua.
twin srclua 'Name: srclua\nSource1: macros.lua\nVersion: 1\n%global x %(cat data-%{version}.txt)\n'
differ srclua data-1.txt
out="$(timeout 30 python3 -I "$SCAN" scan "$work/srclua" "$work/srcluab")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'reads data-1.txt, which differs' <<<"$out" && ! grep -q '^incomplete:' <<<"$out" \
  && pass "scan: a Source named macros.lua leaves the macros certain" || { fail "scan srclua: rc=$rc"; printf '%s\n' "$out" | head -5 | sed 's/^/    /'; }
twin loaddef 'Name: loaddef\nSource1: m.macros\n%define d a.txt\n%{load:%{SOURCE1}}\n%global x %(cat %{d})\n'
printf '%%d b.txt\n' | tee "$work/loaddef/m.macros" > "$work/loaddefb/m.macros"
printf 'a\n' | tee "$work/loaddef/a.txt" > "$work/loaddefb/a.txt"; differ loaddef b.txt
doubt loaddef d "a loaded file may define the macro"
# A conditional definition: rpm reads evil.inc, which no plain line names.
twin cond 'Name: cond\n%{!?inc:%global inc evil.inc}\n%include %{inc}\n%define inc good.inc\n'
printf '%%define good 1\n' | tee "$work/cond/good.inc" > "$work/condb/good.inc"
printf '%%define e 1\n' > "$work/condb/evil.inc"; printf '%%define e %%(id)\n' > "$work/cond/evil.inc"
out="$(timeout 30 python3 -I "$SCAN" scan "$work/cond" "$work/condb")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'cond.spec:3: %include %{inc} — include: reads a file the text does not name' <<<"$out" \
  && grep -qF 'incomplete: %inc has no single value the text gives' <<<"$out" \
  && pass "scan: an %include through a conditionally defined macro is never verbatim" || { fail "scan cond: rc=$rc"; printf '%s\n' "$out" | head -5 | sed 's/^/    /'; }
# An escaped construct reads what it reads once a later expansion makes it live;
# a lone % joins code nobody can name, so a verbatim one is never OK.
twin pct 'Name: pct\n%global p %%(cat data.txt)\n'; differ pct data.txt
out="$(timeout 30 python3 -I "$SCAN" scan "$work/pct" "$work/pctb")"; rc=$?
[ "$rc" = 1 ] && grep -qF 'pct.spec:2: %global p %%(cat data.txt) — %%: reads data.txt, which differs' <<<"$out" \
  && pass "scan: an escaped shell line reads its file" || { fail "scan escaped reads: rc=$rc"; printf '%s\n' "$out" | head -5 | sed 's/^/    /'; }
twin lone 'Name: lone\n%global p %\n%global x %{p}(cat data.txt)\n'; differ lone data.txt
out="$(timeout 30 python3 -I "$SCAN" scan "$work/lone" "$work/loneb")"; rc=$?
[ "$rc" = 4 ] && grep -qF 'incomplete: a lone % or glue joins code at parse time' <<<"$out" \
  && pass "scan: a verbatim lone % is never OK" || { fail "scan lone: rc=$rc"; printf '%s\n' "$out" | head -5 | sed 's/^/    /'; }
twin wide "Name: wide\n$(for i in $(seq 0 599); do printf '%%define m%d 1\\n' "$i"; done)%global x %(echo $(for i in $(seq 0 599); do printf '%%{m%d}' "$i"; done))\n"
sed -i 's/^%define m0 1$/%define m0 1 2/' "$work/wide/wide.spec"
out="$(timeout 30 python3 -I "$SCAN" scan "$work/wide" "$work/wideb")"; rc=$?
[ "$rc" != 0 ] && grep -qF 'incomplete: a line uses more than 500 macros' <<<"$out" \
  && pass "scan: a line using more than 500 macros is never OK" || { fail "scan wide: rc=$rc"; printf '%s\n' "$out" | head -5 | sed 's/^/    /'; }
# The caps bound memory and time: a 1 MiB value put in 2000 times on one line, 10000
# lines that each put in 60 KiB, and a spec past 8 MiB, each under 1 GiB of address
# space, finish within seconds and say they stopped short.
mkdir -p "$work/onepass" "$work/onepassb" "$work/many" "$work/manyb" "$work/huge" "$work/hugeb"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("Name: one\n%define a " + "x" * (1 << 20) + "\n%global y %(echo " + "%{a}" * 2000 + ")\n")' "$work/onepass/one.spec"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("Name: many\n%define a " + "x" * 61440 + "\n" + "".join("%%global y%d %%(echo %%{a} %d)\n" % (i, i) for i in range(10000)))' "$work/many/many.spec"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("Name: huge\n%global y %(id)\n" + "# padding line of a spec past the cap\n" * 250000)' "$work/huge/huge.spec"
for t in onepass many huge; do cp "$work/$t/"*.spec "$work/${t}b/"; done
capped() {  # capped <dir> <note> <what>
  local out rc
  out="$(ulimit -v 1048576; timeout 30 python3 -I "$SCAN" scan "$work/$1" "$work/$1b" 2>&1)"; rc=$?
  [ "$rc" = 4 ] && grep -qF "incomplete: $2" <<<"$out" && ! grep -q 'MemoryError' <<<"$out" \
    && pass "scan: $3, under 1 GiB" || { fail "scan $1: rc=$rc"; printf '%s\n' "$out" | head -5 | cut -c1-200 | sed 's/^/    /'; }
}
capped onepass 'a macro expands past 64 KiB' "a 1 MiB value put in 2000 times stops short"
capped many 'more than 32 MiB of macro text resolved' "10000 lines of 60 KiB each stop short"
capped huge 'a file past 8 MiB was not read: huge.spec' "a spec past 8 MiB is not read"
out="$(python3 -I "$SCAN" scan "$work/t" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qF "Usage:" <<<"$out" && pass "usage: exit 2" || fail "usage: rc=$rc"
out="$(python3 -I "$SCAN" constructs "$work/no-such.spec" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qF "cannot read" <<<"$out" && pass "a file it cannot read: exit 3, not 'found'" || fail "unreadable: rc=$rc"

echo "---"; [ "$fails" = 0 ] && echo "all parse-scan checks passed" || echo "$fails FAILED"
exit $((fails > 0))
