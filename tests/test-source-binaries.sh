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
d=$(pkg except); cp "$work/tarball/vendor.tar.gz" "$d/"
printf '# Source-Binary-Exception: vendor.tar.gz:./bin/* -- bootstrap: go needs a go to build\n' >> "$d/p.spec"
case_ exception-partial 3 "EXCEPTION vendor.tar.gz:./bin/* (bootstrap: go needs a go to build): 1 hit(s)" "$d"
grep -qF "HIT vendor.tar.gz:./pkg.tgz!package/addon.node" <<<"$LAST" && ! grep -qF "HIT vendor.tar.gz:./bin/go" <<<"$LAST" \
  && pass "exception: covers its glob only" || fail "exception scope: $LAST"
printf '# Source-Binary-Exception: vendor.tar.gz:./pkg.tgz!* -- test-data: a fixture the tests read\n' >> "$d/p.spec"
case_ exception-all 0 "OK: no prebuilt binaries in the sources outside the 2 excepted" "$d"
printf '# Source-Binary-Exception: ./bin/* because I said so\n' >> "$d/p.spec"
case_ exception-malformed 3 "MALFORMED p.spec:4:" "$d"

# What cannot be read is UNKNOWN, never clean; an exception may name it.
d=$(pkg unknown); printf '7z\274\257\047\034rest' > "$d/legacy.7z"
case_ 7z-unknown 2 "UNKNOWN legacy.7z: a 7z archive" "$d"
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 1\n' > "$d/big.tar.zst"
case_ lfs-pointer 2 "UNKNOWN big.tar.zst: a git-lfs pointer" "$d"
rm -f "$d/big.tar.zst"; printf '# Source-Binary-Exception: legacy.7z -- test-data: an extractor test archive\n' >> "$d/p.spec"
case_ unknown-excepted 0 "EXCEPTION legacy.7z" "$d"
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

echo "---"; [ "$fails" = 0 ] && echo "all source-binaries checks passed" || echo "$fails FAILED"
exit $((fails > 0))
