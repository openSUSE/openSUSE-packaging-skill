#!/bin/bash
# test-source-binaries.sh — source-binaries.py finds prebuilt binaries in every
# file of a checkout, inside archives and one level into nested ones, lets
# through only what a # Source-Binary-Exception: spec line names, and never
# reads an archive it could not read completely as clean. nodejs-electron
# 44.10.0 kept CIPD Go, esbuild and rolldown binaries in its source tarballs as
# "build-time only" and passed review. Fixtures are made at run time; offline.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SB="$HERE/../skills/opensuse-packaging/scripts/source-binaries.py"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export XDG_CACHE_HOME="$work/cache"

# case_ <name> <expected rc> <expected text> <dir> [args]
case_() {
  local name=$1 want=$2 text=$3 dir=$4; shift 4
  local out rc
  out="$(python3 "$SB" "$dir" "$@" 2>&1)"; rc=$?
  [ "$rc" = "$want" ] && grep -qF -- "$text" <<<"$out" && pass "$name (rc=$want)" || {
    fail "$name: expected rc=$want and '$text', got rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
  LAST=$out
}
pkg() { rm -rf "${work:?}/$1"; mkdir -p "$work/$1"; printf 'Name: p\n' > "$work/$1/p.spec"; echo "$work/$1"; }
elf() { printf '\177ELF\002\001\001\000rest of a binary' > "$1"; }

# Clean: text sources and a tarball of text.
d=$(pkg clean); mkdir -p "$work/t/clean/src"; echo 'int main(void){return 0;}' > "$work/t/clean/src/a.c"
tar -C "$work/t/clean" -czf "$d/p-1.0.tar.gz" . && echo "# MZ is not a PE without its header" > "$d/notes.txt"
case_ clean 0 "OK: no prebuilt binaries in the sources" "$d"

# A loose binary next to the spec.
d=$(pkg loose); elf "$d/esbuild"
case_ loose-elf 3 "HIT esbuild: ELF" "$d"

# A binary inside a gzip tarball, and inside an npm .tgz inside it.
d=$(pkg tarball); mkdir -p "$work/t/tb/bin" "$work/t/npm/package"
elf "$work/t/tb/bin/go"; elf "$work/t/npm/package/addon.node"; echo '{}' > "$work/t/npm/package/package.json"
tar -C "$work/t/npm" -czf "$work/t/tb/pkg.tgz" package && tar -C "$work/t/tb" -czf "$d/vendor.tar.gz" .
case_ tar-member 3 "HIT vendor.tar.gz:./bin/go: ELF" "$d"
grep -qF "HIT vendor.tar.gz:./pkg.tgz!package/addon.node: ELF" <<<"$LAST" && pass "nested npm .tgz: its .node is found" \
  || fail "nested npm .tgz: $LAST"

# zstd and xz tarballs, when the tools are here.
for z in zstd xz; do
  if command -v "$z" > /dev/null; then
    d=$(pkg "c-$z"); tar -C "$work/t/tb" -cf - ./bin | "$z" -q -c > "$d/v.tar.$z"
    case_ "tar.$z" 3 "HIT v.tar.$z:./bin/go: ELF" "$d"
  else
    echo "note: no $z here, its case is not run"
  fi
done

# zip: a PE member; "MZ" text without the PE header is no hit.
d=$(pkg zip)
python3 - "$d/tools.zip" <<'PY'
import sys, zipfile
pe = bytearray(b"MZ" + b"\0" * 62)
pe[60:64] = (64).to_bytes(4, "little")
pe += b"PE\0\0" + b"\0" * 20
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("win/tool.exe", bytes(pe))
    z.writestr("doc/mz.txt", "MZ is only text here")
PY
case_ zip-pe 3 "HIT tools.zip:win/tool.exe: PE" "$d"
! grep -qF "mz.txt" <<<"$LAST" && pass "zip: an MZ text file is not a PE" || fail "zip: MZ text flagged: $LAST"

# obscpio (newc), with wasm, a Java class and a fat Mach-O told apart.
d=$(pkg cpio)
python3 - "$d/p.obscpio" <<'PY'
import sys
files = {"p/x.wasm": b"\0asm\1\0\0\0", "p/A.class": b"\xca\xfe\xba\xbe\0\0\0\x34", "p/fat": b"\xca\xfe\xba\xbe\0\0\0\x02", "p/a.txt": b"text"}
out = bytearray()
def entry(name, data, mode):
    global out
    n = name.encode() + b"\0"
    fields = [1, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(n), 0]
    hdr = b"070701" + b"".join(b"%08x" % f for f in fields)
    out += hdr + n
    out += b"\0" * ((4 - len(out) % 4) % 4)
    out += data
    out += b"\0" * ((4 - len(out) % 4) % 4)
for name, data in files.items():
    entry(name, data, 0o100644)
entry("TRAILER!!!", b"", 0)
open(sys.argv[1], "wb").write(out)
PY
case_ cpio-wasm 3 "HIT p.obscpio:p/x.wasm: wasm" "$d"
grep -qF "HIT p.obscpio:p/A.class: Java class" <<<"$LAST" && grep -qF "HIT p.obscpio:p/fat: Mach-O" <<<"$LAST" \
  && ! grep -qF "a.txt" <<<"$LAST" && pass "cpio: Java class and fat Mach-O told apart, text clean" \
  || fail "cpio kinds: $LAST"

# An exception line names the allowed ones; a malformed one is red.
BOOT='the go compiler is written in go and needs a previous go build to compile itself'
d=$(pkg except); cp "$work/tarball/vendor.tar.gz" "$d/"
printf '# Source-Binary-Exception: vendor.tar.gz:./bin/* -- bootstrap: %s\n' "$BOOT" >> "$d/p.spec"
case_ exception-partial 3 "EXCEPTION vendor.tar.gz:./bin/* (bootstrap: $BOOT): 1 hit(s)" "$d"
grep -qF "HIT vendor.tar.gz:./pkg.tgz!package/addon.node" <<<"$LAST" && ! grep -qF "HIT vendor.tar.gz:./bin/go" <<<"$LAST" \
  && pass "exception: covers its glob only" || fail "exception scope: $LAST"
grep -qF "FIX: a binary the package ships, embeds, loads or links is never an exception: build it from source or unbundle it" <<<"$LAST" \
  && pass "red names build from source or unbundle" || fail "red without the fix: $LAST"
printf '# Source-Binary-Exception: vendor.tar.gz:./pkg.tgz!* -- firmware: a blob no source exists for\n' >> "$d/p.spec"
case_ exception-all 0 "OK: no prebuilt binaries in the sources outside the 2 excepted (bootstrap: vendor.tar.gz:./bin/*: $BOOT)" "$d"
printf '# Source-Binary-Exception: ./bin/* because I said so\n' >> "$d/p.spec"
case_ exception-malformed 3 "MALFORMED p.spec:4:" "$d"

# test-data names a fixture inside a test directory: a library's lib/ is a build
# input (goose called winapi's MinGW import libraries test-data), and a short
# bootstrap why says nothing (opencode called its shipped pty helper a bootstrap).
d=$(pkg testdata); mkdir -p "$work/t/td/tests/data" "$work/t/td/lib"
elf "$work/t/td/tests/data/sample.so"; printf '!<arch>\nlibwinapi.a' > "$work/t/td/lib/libwinapi_x.a"
tar -C "$work/t/td" -czf "$d/vendor.tar.gz" .
printf '# Source-Binary-Exception: vendor.tar.gz:./lib/* -- test-data: import libs linked only on windows\n' >> "$d/p.spec"
case_ testdata-lib 3 "test-data names a test fixture, and vendor.tar.gz:./lib/* is not inside a test directory" "$d"
printf '# Source-Binary-Exception: latest.tar.gz:latest/* -- test-data: not a test dir\n' >> "$d/p.spec"
grep -qF "latest.tar.gz:latest/* is not inside a test directory" <<<"$(python3 "$SB" "$d" 2>&1)" \
  && pass "test-data: latest/ is no test directory" || fail "test-data: latest/ accepted"
d=$(pkg testdata-ok); cp "$work/testdata/vendor.tar.gz" "$d/"
printf '# Source-Binary-Exception: vendor.tar.gz:./tests/* -- test-data: an ELF parser sample\n' >> "$d/p.spec"
case_ testdata-tests 3 "EXCEPTION vendor.tar.gz:./tests/* (test-data: an ELF parser sample): 1 hit(s)" "$d"
grep -qF "HIT vendor.tar.gz:./lib/libwinapi_x.a: ar archive" <<<"$LAST" && pass "test-data: lib/ stays a hit" \
  || fail "test-data scope: $LAST"
d=$(pkg shortboot); cp "$work/tarball/vendor.tar.gz" "$d/"
printf '# Source-Binary-Exception: vendor.tar.gz:./bin/* -- bootstrap: upstream-built helper embedded by the build\n' >> "$d/p.spec"
case_ bootstrap-short 3 "a bootstrap needs a why of 8+ words" "$d"

# What cannot be read is UNKNOWN, never clean; an exception may name it.
d=$(pkg unknown); printf '7z\274\257\047\034rest' > "$d/legacy.7z"
case_ 7z-unknown 2 "UNKNOWN legacy.7z: a 7z archive" "$d"
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 1\n' > "$d/big.tar.zst"
case_ lfs-pointer 2 "UNKNOWN big.tar.zst: a git-lfs pointer" "$d"
rm -f "$d/big.tar.zst" "$d/legacy.7z"; mkdir -p "$work/t/u7/tests"; printf '7z\274\257\047\034rest' > "$work/t/u7/tests/legacy.7z"
tar -C "$work/t/u7" -czf "$d/t.tar.gz" .
case_ 7z-member-unknown 2 "UNKNOWN t.tar.gz:./tests/legacy.7z: a 7z archive" "$d"
printf '# Source-Binary-Exception: t.tar.gz:./tests/* -- test-data: an extractor test archive\n' >> "$d/p.spec"
case_ unknown-excepted 0 "EXCEPTION t.tar.gz:./tests/*" "$d"
d=$(pkg truncated); head -c 40 "$work/tarball/vendor.tar.gz" > "$d/cut.tar.gz"
case_ truncated-gzip 2 "UNKNOWN cut.tar.gz" "$d"

# The cache: a second scan answers from it, under the file's current name.
d=$(pkg cache); cp "$work/tarball/vendor.tar.gz" "$d/a.tar.gz"
python3 "$SB" "$d" > /dev/null 2>&1
n=$(find "$XDG_CACHE_HOME" -name 'v*-*.json' | wc -l)
[ "$n" -ge 1 ] && pass "cache: the scan is stored" || fail "cache: nothing stored"
mv "$d/a.tar.gz" "$d/b.tar.gz"
case_ cache-renamed 3 "HIT b.tar.gz:./bin/go: ELF" "$d"
case_ usage 2 "is not a directory" "$work/nonexistent"

# --rpms: a payload file with a source binary's bytes ships it, red whatever
# its exception says; so does one that carries them inside (opencode 2.2.5's
# bun executable held its pty helper verbatim); firmware alone may ship.
d=$(pkg ship); mkdir -p "$work/t/sh/bin"
{ printf '\177ELF\002\001\001\000'; head -c 10000 /dev/urandom; } > "$work/t/sh/bin/helper"
elf "$work/t/sh/bin/go"; tar -C "$work/t/sh" -czf "$d/vendor.tar.gz" .
printf '# Source-Binary-Exception: vendor.tar.gz:./* -- bootstrap: %s\n' "$BOOT" >> "$d/p.spec"
if command -v rpmbuild > /dev/null && command -v rpm2cpio > /dev/null; then
  mkdir -p "$work/rpm/SOURCES" "$work/rpms"; cp "$work/t/sh/bin/go" "$work/rpm/SOURCES/go"
  { head -c 5000 /dev/urandom; cat "$work/t/sh/bin/helper"; head -c 3000 /dev/urandom; } > "$work/rpm/SOURCES/app"
  printf 'Name: s\nVersion: 1\nRelease: 0\nSummary: s\nLicense: MIT\nBuildArch: noarch\nSource0: go\nSource1: app\n%%description\ns\n%%install\ninstall -D -m 0755 %%{SOURCE0} %%{buildroot}/usr/bin/go\ninstall -D -m 0755 %%{SOURCE1} %%{buildroot}/usr/bin/app\n%%files\n/usr/bin/go\n/usr/bin/app\n' > "$work/rpm/s.spec"
  rpmbuild -bb --quiet --define "_topdir $work/rpm" --define 'debug_package %{nil}' --define '__os_install_post %{nil}' \
    --define '_binaries_in_noarch_packages_terminate_build 0' "$work/rpm/s.spec" > /dev/null 2>&1
  find "$work/rpm/RPMS" -name '*.rpm' -exec cp {} "$work/rpms/" \;
  case_ shipped 3 "SHIPPED s-1-0.noarch.rpm:./usr/bin/go is the prebuilt vendor.tar.gz:./bin/go" "$d" --rpms "$work/rpms"
  grep -qF "SHIPPED s-1-0.noarch.rpm:./usr/bin/app embeds the prebuilt vendor.tar.gz:./bin/helper" <<<"$LAST" \
    && pass "shipped: a binary carried inside another file is found" || fail "embedded: $LAST"
  sed -i 's/-- bootstrap: .*/-- firmware: a blob no source exists for/' "$d/p.spec"
  case_ shipped-firmware 0 "read for shipped ones" "$d" --rpms "$work/rpms"
else
  echo "note: no rpmbuild/rpm2cpio here, the --rpms cases are not run"
fi
mkdir -p "$work/norpms"
case_ no-rpms 2 "UNKNOWN $work/norpms: no binary RPM to read" "$d" --rpms "$work/norpms"

echo "---"; [ "$fails" = 0 ] && echo "all source-binaries checks passed" || echo "$fails FAILED"
exit $((fails > 0))
