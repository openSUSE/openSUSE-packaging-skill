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

# A zip whose version field zipfile refuses (a format-test corpus) is unread, not a crash.
d=$(pkg zipver); mkdir -p "$work/t/zv"
python3 - "$work/t/zv/bogus.zip" <<'PY2'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("a.txt", "hello")
b = bytearray(open(sys.argv[1], "rb").read())
for sig, off in ((b"PK\x01\x02", 6), (b"PK\x03\x04", 4)):
    i = b.find(sig)
    b[i + off:i + off + 2] = (99).to_bytes(2, "little")
open(sys.argv[1], "wb").write(b)
PY2
tar -C "$work/t/zv" -czf "$d/v.tar.gz" bogus.zip
case_ zip-bogus-version 2 "UNKNOWN v.tar.gz:bogus.zip: cannot read the zip archive: zip file version 9.9" "$d"
d=$(pkg zipver-top); cp "$work/t/zv/bogus.zip" "$d/"
case_ zip-bogus-version-top 2 "UNKNOWN bogus.zip: cannot read the zip archive: zip file version 9.9" "$d"

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

# Windows COFF objects have no magic (ring's pregenerated *.o, aws-lc-sys's
# prebuilt *.obj): a known machine, no optional header, real section names.
d=$(pkg coff); mkdir -p "$work/t/coff/pregenerated"
python3 - "$work/t/coff/pregenerated" <<'PY'
import os, struct, sys
out = sys.argv[1]
def obj(machine, names, opt=0):
    hdr = struct.pack("<HHIIIHH", machine, len(names), 0, 0, 0, opt, 0)
    secs = b"".join(n.ljust(8, b"\0") + b"\0" * 32 for n in names)
    return hdr + secs + b"\0" * 64
open(os.path.join(out, "x86_64-mont-nasm.o"), "wb").write(obj(0x8664, [b".text", b".data", b".debug$S"]))
big = struct.pack("<HHHHI", 0, 0xFFFF, 2, 0x8664, 0) + bytes.fromhex("c7a1bad1eebaa94baf20faf66aa4dcb8") + b"\0" * 64
open(os.path.join(out, "big.obj"), "wb").write(big)
# near misses: an image's optional header, a name that is no name, a text file
open(os.path.join(out, "opt.o"), "wb").write(obj(0x8664, [b".text"], opt=0xF0))
open(os.path.join(out, "garbage.o"), "wb").write(obj(0x8664, [b"\x01\x02xyz"]))
open(os.path.join(out, "notes.txt"), "wb").write(b"d\x86" + b"plain text that happens to start like an x86-64 COFF header " * 4)
PY
tar -C "$work/t/coff" -czf "$d/vendor.tar.gz" .
case_ coff-object 3 "HIT vendor.tar.gz:./pregenerated/x86_64-mont-nasm.o: COFF object" "$d"
grep -qF "HIT vendor.tar.gz:./pregenerated/big.obj: COFF object" <<<"$LAST" \
  && ! grep -qE "opt\.o|garbage\.o|notes\.txt" <<<"$LAST" \
  && pass "coff: a bigobj is one, an image header, a non-name and text are not" || fail "coff kinds: $LAST"

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
# zpaqfranz keeps the archives its autotest command checks in AUTOTEST/.
d=$(pkg autotest); mkdir -p "$work/t/zf/zpaqfranz-65.17/AUTOTEST"
printf '7z\274\257\047\034rest' > "$work/t/zf/zpaqfranz-65.17/AUTOTEST/sha256.7z"
tar -C "$work/t/zf" -czf "$d/zpaqfranz-65.17.tar.gz" .
printf '# Source-Binary-Exception: zpaqfranz-65.17.tar.gz:*/AUTOTEST/* -- test-data: archives the autotest command reads\n' >> "$d/p.spec"
case_ testdata-autotest 0 "EXCEPTION zpaqfranz-65.17.tar.gz:*/AUTOTEST/* (test-data" "$d"
# KDE keeps its test data in autotests/.
d=$(pkg autotests); mkdir -p "$work/t/kde/kio-6.0/autotests/data"; elf "$work/t/kde/kio-6.0/autotests/data/elf-sample"
tar -C "$work/t/kde" -czf "$d/kio-6.0.tar.gz" .
printf '# Source-Binary-Exception: kio-6.0.tar.gz:*/autotests/data/* -- test-data: an ELF the mimetype tests read\n' >> "$d/p.spec"
case_ testdata-autotests 0 "EXCEPTION kio-6.0.tar.gz:*/autotests/data/* (test-data" "$d"
d=$(pkg shortboot); cp "$work/tarball/vendor.tar.gz" "$d/"
printf '# Source-Binary-Exception: vendor.tar.gz:./bin/* -- bootstrap: upstream-built helper embedded by the build\n' >> "$d/p.spec"
case_ bootstrap-short 3 "a bootstrap needs a why of 8+ words" "$d"
# A bootstrap is a toolchain the build runs: a why saying the build never uses
# the file is no bootstrap (ringrtc's gradle wrapper, opencode's tree-sitter.wasm);
# saying it never runs once installed is fine.
boot() { d=$(pkg "boot-$1"); tar -C "$work/t/tb" -czf "$d/vendor.tar.gz" ./bin
  printf '# Source-Binary-Exception: vendor.tar.gz:./bin/* -- bootstrap: %s\n' "$2" >> "$d/p.spec"; echo "$d"; }
UNUSED="a file the build does not use is removed from the sources"
d=$(boot ringrtc 'upstream Android gradle bootstrap fetching their pinned gradle for mobile builds; this Linux build never invokes it and ships no part of it')
case_ bootstrap-never-invoked 3 "$UNUSED" "$d"
d=$(boot opencode 'runtime grammar asset the highlighter loads, embedded at build time, never executed at build time')
case_ bootstrap-never-executed 3 "$UNUSED" "$d"
d=$(boot unused 'a prebuilt go toolchain for the windows cross build, unused on Linux')
case_ bootstrap-unused 3 "$UNUSED" "$d"
d=$(boot doesnt 'the upstream build script fetches it for macOS, and the Linux build does not need it')
case_ bootstrap-not-needed 3 "$UNUSED" "$d"
d=$(boot runtime 'the go compiler is written in go and needs a previous go build to compile itself; not needed at run time and never shipped')
case_ bootstrap-runtime-denial 0 "EXCEPTION vendor.tar.gz:./bin/* (bootstrap:" "$d"
# A why is a denial only when the build is what does not use the file; a real
# bootstrap says what no packaged predecessor can do, and that nothing installed uses it.
for why in \
  "the go 1.23 compiler is written in go and Factory's go 1.22 does not run the new bootstrap code path" \
  "ghc is written in haskell; the packaged ghc can not be used because it is two major versions behind" \
  "the stage0 rustc builds stage1 of the compiler from source and is not needed afterwards" \
  "the bootstrap jdk compiles the new jdk, which needs a previous build of itself, and is never used outside the build" \
  "the bootstrap sbcl compiles sbcl itself since lisp needs a lisp to build; nothing loads it at run time" \
  "the seed swift toolchain compiles swift itself, since swift needs swift, and is not used by anything the RPM installs" \
  "ghc compiles itself, and the build cannot use Factory's ghc 9.4, which is two versions behind"; do
  d=$(boot real "$why")
  out="$(python3 "$SB" "$d" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && pass "bootstrap accepted: ${why:0:50}..." || { fail "bootstrap refused: $why"; printf '%s\n' "$out" | grep MALFORMED | sed 's/^/    /'; }
done
for why in \
  "upstream's gradle wrapper for Android; this Linux build never actually invokes it" \
  "upstream's gradle wrapper for Android releases; the openSUSE build has no use for it" \
  "upstream's Android gradle wrapper, which is not required by this Linux build at all" \
  "upstream's Android gradle wrapper; the Linux build does not depend on it in any way" \
  "upstream's Android gradle wrapper, never being invoked by the build on Linux" \
  "upstream's Android gradle wrapper; only the Android build invokes it, not this one" \
  "upstream's gradle wrapper for Android releases; Linux builds never invoke it" \
  "upstream's gradle wrapper for Android releases; only Android builds invoke it" \
  "upstream's gradle wrapper for Android; the openSUSE Linux x86_64 build never invokes it" \
  "upstream's gradle wrapper for Android releases; it is not invoked when building for Linux"; do
  d=$(boot denial "$why")
  out="$(python3 "$SB" "$d" 2>&1)"; rc=$?
  [ "$rc" = 3 ] && grep -qF "$UNUSED" <<<"$out" && pass "bootstrap refused: ${why:0:50}..." \
    || { fail "bootstrap accepted: $why (rc=$rc)"; }
done

# other-platform: a file for another OS or CPU that the build leaves alone
# (python-uv's Windows import libraries, ring's and aws-lc-sys's Windows objects,
# psm's wasm32.o). It holds by the file's bytes, never its name: a Linux-target
# object, an archive holding one, an EFI image, a .NET assembly or a wasm module
# (node or wasmtime run one: opencode embedded tree-sitter.wasm) is refused, and
# so is what a review hid behind a foreign header: a Linux object named like an
# archive's symbol table, a fat Mach-O around one, a zip appended to a Windows or
# Apple file, an EI_OSABI byte patched to FreeBSD, a BSD name 10^13 bytes long.
mkdir -p "$work/t/op/ok" "$work/t/op/no"
python3 - "$work/t/op/ok" "$work/t/op/no" <<'PY'
import io, os, struct, sys, zipfile
ok, no = sys.argv[1:3]
def put(d, name, data):
    open(os.path.join(d, name), "wb").write(data)
def coff(machine=0x8664):
    names = [b".text", b".data", b".debug$S"]
    hdr = struct.pack("<HHIIIHH", machine, len(names), 0, 0, 0, 0, 0)
    return hdr + b"".join(n.ljust(8, b"\0") + b"\0" * 32 for n in names) + b"\0" * 64
def ar(*members, bsd=False):
    out = b"!<arch>\n"
    for name, data in members:
        if bsd:  # macOS: "#1/N", and the name leads the data
            n = name.encode() + bytes(4 - len(name) % 4)
            name, data = f"#1/{len(n)}", n + data
        out += b"%-16s%-12s%-6s%-6s%-8s%-10d`\n" % (name.encode(), b"0", b"0", b"0", b"644", len(data))
        out += data + (b"\n" if len(data) % 2 else b"")
    return out
# an MSVC import library holds a short import object per function
short = struct.pack("<HHHHIIHH", 0, 0xFFFF, 0, 0x8664, 0, 26, 0, 0) + b"GetTickCount\0KERNEL32.dll\0"
def elf(machine, osabi=0, etype=1, big=False):
    ident = b"\x7fELF\x02" + (b"\x02" if big else b"\x01") + b"\x01" + bytes([osabi]) + bytes(8)
    return ident + struct.pack(">HHI" if big else "<HHI", etype, machine, 1) + bytes(64)
def pe(subsystem=3, clr=False):
    b = bytearray(512)
    b[:2], b[60:64], b[128:132] = b"MZ", (128).to_bytes(4, "little"), b"PE\0\0"
    struct.pack_into("<HHIIIH", b, 132, 0x8664, 1, 0, 0, 0, 240)
    struct.pack_into("<H", b, 152, 0x20B)  # PE32+
    struct.pack_into("<H", b, 152 + 68, subsystem)
    struct.pack_into("<I", b, 152 + 108, 16)  # data directories
    if clr:  # the CLI header's directory: a .NET assembly
        struct.pack_into("<II", b, 152 + 112 + 14 * 8, 0x2008, 0x48)
    return bytes(b)
macho = b"\xcf\xfa\xed\xfe" + struct.pack("<iiIIII", 0x0100000C, 0, 6, 0, 0, 0) + bytes(64)
def fat(*slices):
    out = struct.pack(">II", 0xCAFEBABE, len(slices))
    out += b"".join(struct.pack(">iiIII", 0x0100000C, 0, 4096 * (i + 1), len(s), 12) for i, s in enumerate(slices))
    return out.ljust(4096, b"\0") + b"".join(s.ljust(4096, b"\0") for s in slices)
def zipped(data):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as z:
        z.writestr("lib/libx.so", data)
    return b.getvalue()
# every relocatable object imports env.__linear_memory; a module need not
memory = b"\x02\x18\x01\x03env\x0f__linear_memory\x02\x00\x00"
put(ok, "x86_64-mont-nasm.obj", coff())
put(ok, "windows.0.52.0.lib", ar(("/", bytes(8)), ("/", bytes(8)), ("//", b"x\0"), ("KERNEL32.dll/", coff()), ("KERNEL32.dll/", short)))
put(ok, "libwindows.0.52.0.a", ar(("/", bytes(8)), ("dmmjs00001.o/", coff(0xAA64))))
put(ok, "wasm32.o", b"\0asm\1\0\0\0" + memory + b"\0\x09\x07linking\x02")
put(ok, "libfoo.dylib", macho)
put(ok, "libfoo-macos.a", ar(("__.SYMDEF SORTED", bytes(8)), ("foo.o", macho), bsd=True))
put(ok, "tool.exe", pe())
put(ok, "sparc.o", elf(43, big=True))
put(ok, "fat.dylib", fat(macho, macho))
put(no, "x86_64.o", elf(62))
put(no, "aarch64.so", elf(183, etype=3))
put(no, "linux.a", ar(("/", bytes(8)), ("a.o/", coff()), ("b.o/", elf(62))))
put(no, "BOOTX64.EFI", pe(subsystem=10))
put(no, "managed.dll", pe(clr=True))
# a module (a type section, no "linking"), one cut short, one with a section id wasm has not
put(no, "module.wasm", b"\0asm\1\0\0\0\x01\x04\x01\x60\0\0")
put(no, "truncated.wasm", b"\0asm\1\0\0\0" + memory + b"\0\x20\x07linking\x02")
put(no, "garbled.wasm", b"\0asm\1\0\0\0" + memory + b"\x7f\x02\0\0\0\x09\x07linking\x02")
# a module node runs (type, function, export, code) that carries a "linking" section
put(no, "linking-module.wasm", b"\0asm\1\0\0\0\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00"
    b"\x07\x07\x01\x03run\x00\x00\x0a\x06\x01\x04\x00\x41\x2a\x0b\x00\x09\x07linking\x02")
linux = elf(62, etype=3) + bytes(4096)
put(no, "freebsd.so", elf(62, osabi=9, etype=3))
put(no, "symdef.a", ar(("/", bytes(8)), ("a.obj/", coff()), ("__.SYMDEF", linux)))
put(no, "names.a", ar(("/", bytes(8)), ("//", linux), ("a.obj/", coff())))
put(no, "huge-name.a", b"!<arch>\n" + b"%-16s%-12s%-6s%-6s%-8s%-10s`\n" % (b"#1/9999999999999", b"0", b"0", b"0", b"644", b"9999999999") + b"x" * 100)
put(no, "fat-linux.dylib", fat(linux))
put(no, "zip.dylib", macho + zipped(linux))
put(no, "sfx.exe", pe() + zipped(linux))
put(no, "zip.obj", coff() + zipped(linux))
put(no, "elf-appended.obj", coff() + linux)  # past the object's own extent, no zip
# a zip that is the object's last section: inside its extent, still what unzip reads
z = zipped(linux)
sec = b".rdata\0\0" + struct.pack("<IIIIIIHHI", 0, 0, len(z), 60, 0, 0, 0, 0, 0x40000040)
put(no, "zip-in-section.obj", struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, 0, 0) + sec + z)
PY
# the why may say the build never uses the file: that is this kind's claim
OPW='Windows, macOS, wasm and SPARC objects the Linux build never uses'
d=$(pkg otherplat); tar -C "$work/t/op" -czf "$d/v.tar.gz" ./ok
printf '# Source-Binary-Exception: v.tar.gz:./ok/* -- other-platform: %s\n' "$OPW" >> "$d/p.spec"
case_ other-platform 0 "EXCEPTION v.tar.gz:./ok/* (other-platform: $OPW): 9 hit(s), for Apple, SPARC, Windows, wasm" "$d"
for f in x86_64.o aarch64.so linux.a BOOTX64.EFI managed.dll truncated.wasm garbled.wasm linking-module.wasm \
  freebsd.so symdef.a names.a fat-linux.dylib zip.dylib sfx.exe zip.obj elf-appended.obj \
  zip-in-section.obj module.wasm; do
  d=$(pkg "op-$f"); rm -rf "$work/t/op1"; mkdir -p "$work/t/op1/no"; cp "$work/t/op/no/$f" "$work/t/op1/no/"
  tar -C "$work/t/op1" -czf "$d/v.tar.gz" ./no
  printf '# Source-Binary-Exception: v.tar.gz:./no/* -- other-platform: Windows objects for another target\n' >> "$d/p.spec"
  case_ "other-platform-refused-$f" 3 "other-platform holds only for a file whose bytes show another OS or CPU, not v.tar.gz:./no/$f" "$d"
done
grep -qF "not v.tar.gz:./no/module.wasm (wasm): build it from source or unbundle it, or except it as bootstrap" <<<"$LAST" \
  && pass "other-platform: a wasm module is refused, pointing at unbundling or bootstrap" || fail "other-platform refusal hint: $LAST"
# a "#1/N" name longer than its member is refused before anything is read: a
# 10^13-byte one died of MemoryError with no verdict (in 1 GiB, as on a small worker)
d=$(pkg op-huge); rm -rf "$work/t/op1"; mkdir -p "$work/t/op1/no"; cp "$work/t/op/no/huge-name.a" "$work/t/op1/no/"
tar -C "$work/t/op1" -czf "$d/v.tar.gz" ./no
printf '# Source-Binary-Exception: v.tar.gz:./no/* -- other-platform: Windows objects for another target\n' >> "$d/p.spec"
out="$(ulimit -v 1048576; python3 "$SB" "$d" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qF "not v.tar.gz:./no/huge-name.a (ar archive)" <<<"$out" \
  && pass "other-platform: a BSD name past its member is refused (rc=3)" || { fail "huge BSD name: rc=$rc"; printf '%s\n' "$out" | tail -3 | sed 's/^/    /'; }
for why in 'unused here' 'objects nobody here uses'; do
  d=$(pkg op-why); cp "$work/otherplat/v.tar.gz" "$d/"
  printf '# Source-Binary-Exception: v.tar.gz:./ok/* -- other-platform: %s\n' "$why" >> "$d/p.spec"
  case_ "other-platform-why: $why" 3 "other-platform needs a why of 3+ words naming the platform" "$d"
done
d=$(pkg op-7z); mkdir -p "$work/t/op7/w"; printf '7z\274\257\047\034rest' > "$work/t/op7/w/sdk.7z"
tar -C "$work/t/op7" -czf "$d/v.tar.gz" ./w
printf '# Source-Binary-Exception: v.tar.gz:./w/* -- other-platform: a Windows SDK archive\n' >> "$d/p.spec"
case_ other-platform-unreadable 3 "not v.tar.gz:./w/sdk.7z (not readable)" "$d"
# every line that matches is tried in turn: an other-platform line that does not
# hold leaves a fixture to the test-data line after it
d=$(pkg op-order); mkdir -p "$work/t/opo/w/tests"; cp "$work/t/op/no/x86_64.o" "$work/t/opo/w/tests/fixture.o"
tar -C "$work/t/opo" -czf "$d/v.tar.gz" ./w
printf '# Source-Binary-Exception: v.tar.gz:./w/* -- other-platform: the Windows SDK files
# Source-Binary-Exception: v.tar.gz:./w/tests/* -- test-data: a fixture the tests only read
' >> "$d/p.spec"
case_ other-platform-then-test-data 0 "EXCEPTION v.tar.gz:./w/tests/* (test-data: a fixture the tests only read): 1 hit(s)" "$d"
grep -qF "note: exception v.tar.gz:./w/* holds for none it matches; other lines cover them" <<<"$LAST" \
  && pass "other-platform: a line another one covers for is named so" || fail "shadowed line note: $LAST"

# Java bytecode runs anywhere, so other-platform holds for it by path: under a
# directory named for the platform the why names, or in a Gradle wrapper
# (mupdf's tarball carries zxing-cpp's Android and Kotlin/Native wrappers). The
# bytes still decide what they can place: a Linux ELF under android/ is refused.
mkdir -p "$work/t/jv/w/android/lib" "$work/t/jv/w/java" "$work/t/jv/w/ios" "$work/t/jv/w/kn/gradle/wrapper" "$work/t/jv/w/lib/gradle/wrapper"
printf '\312\376\272\276\0\0\0\064class body' > "$work/t/jv/w/android/lib/A.class"
cp "$work/t/jv/w/android/lib/A.class" "$work/t/jv/w/java/A.class"; cp "$work/t/jv/w/android/lib/A.class" "$work/t/jv/w/ios/A.class"
python3 - "$work/t/jv/w/kn/gradle/wrapper/gradle-wrapper.jar" "$work/t/jv/w/lib/gradle/wrapper/tool.jar" <<'PY'
import sys, zipfile
for f in sys.argv[1:]:
    with zipfile.ZipFile(f, "w") as z:
        z.writestr("org/gradle/wrapper/GradleWrapperMain.class", b"\xca\xfe\xba\xbe\0\0\0\x34main")
PY
jv() { # jv <name> <rc> <expected text> <member> <exception line body>
  local d; d=$(pkg "jv-$1"); rm -rf "$work/t/jv1"; mkdir -p "$work/t/jv1/$(dirname "$4")"
  cp "$work/t/jv/$4" "$work/t/jv1/$4"; tar -C "$work/t/jv1" -czf "$d/v.tar.gz" ./w
  printf '# Source-Binary-Exception: %s\n' "$5" >> "$d/p.spec"
  case_ "path-$1" "$2" "$3" "$d"
}
ANDROID='v.tar.gz:./w/* -- other-platform: the Android bindings, which this build never enters'
jv android 0 "EXCEPTION v.tar.gz:./w/* (other-platform: the Android bindings, which this build never enters): 1 hit(s), for Android (by path)" \
  w/android/lib/A.class "$ANDROID"
jv outside 3 "other-platform holds only for a file whose bytes show another OS or CPU, not v.tar.gz:./w/java/A.class (Java class)" \
  w/java/A.class "$ANDROID"
grep -qF "Java bytecode holds by path: in a Gradle wrapper, or under a directory named for the platform the why names" <<<"$LAST" \
  && pass "path-outside: the refusal says how Java bytecode holds" || fail "path-outside hint: $LAST"
jv other-platform-dir 3 "not v.tar.gz:./w/ios/A.class (Java class)" w/ios/A.class "$ANDROID"
jv gradle-wrapper 0 "1 hit(s), for a Gradle wrapper (by path)" w/kn/gradle/wrapper/gradle-wrapper.jar \
  'v.tar.gz:./w/*/gradle/wrapper/gradle-wrapper.jar!* -- other-platform: the Gradle wrapper of the Android bindings'
jv not-the-wrapper 3 "not v.tar.gz:./w/lib/gradle/wrapper/tool.jar!org/gradle/wrapper/GradleWrapperMain.class (Java class)" \
  w/lib/gradle/wrapper/tool.jar 'v.tar.gz:./w/* -- other-platform: the Gradle wrapper of the Android bindings'
mkdir -p "$work/t/jv/w/android/jni"; cp "$work/t/op/no/aarch64.so" "$work/t/jv/w/android/jni/libx.so"
jv linux-elf 3 "not v.tar.gz:./w/android/jni/libx.so (ELF)" w/android/jni/libx.so "$ANDROID"

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
# an executable (e_type 2), so a fingerprint match of it is red
{ printf '\177ELF\002\001\001\000\0\0\0\0\0\0\0\0\002\000'; head -c 10000 /dev/urandom; } > "$work/t/sh/bin/helper"
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
  # a build root's RPMS keeps them in one directory per arch
  case_ shipped-subdir 3 "SHIPPED noarch/s-1-0.noarch.rpm:./usr/bin/go is the prebuilt vendor.tar.gz:./bin/go" "$d" --rpms "$work/rpm/RPMS"
  sed -i 's/-- bootstrap: .*/-- firmware: a blob no source exists for/' "$d/p.spec"
  case_ shipped-firmware 0 "read for shipped ones" "$d" --rpms "$work/rpms"
  # A fingerprint is the hit's own code, never what unrelated binaries share:
  # swift-lang's RPM "embedded" lld's all-zero mips-gp-disp.so test input and,
  # through an archive symbol table both arches have, the aarch64 seed's .a.
  d=$(pkg fp); mkdir -p "$work/t/fp/tests" "$work/t/fp/lib"
  { printf '\177ELF\002\001\001\000'; head -c 12288 /dev/zero; head -c 6144 /dev/urandom; } > "$work/t/fp/tests/padded.so"
  head -c 8192 /dev/urandom > "$work/fp-symtab"
  head -c 6144 /dev/urandom > "$work/fp-member"
  python3 - "$work/t/fp/lib/libx.a" "$work/fp-symtab" "$work/fp-member" <<'PY'
import sys
def member(name, data):
    hdr = b"%-16s%-12s%-6s%-6s%-8s%-10d`\n" % (name.encode(), b"0", b"0", b"0", b"644", len(data))
    return hdr + data + (b"\n" if len(data) % 2 else b"")
symtab, code = (open(f, "rb").read() for f in sys.argv[2:4])
open(sys.argv[1], "wb").write(b"!<arch>\n" + member("/", symtab) + member("x.o/", code))
PY
  tar -C "$work/t/fp" -czf "$d/fp.tar.gz" .
  printf '# Source-Binary-Exception: fp.tar.gz:./* -- bootstrap: %s\n' "$BOOT" >> "$d/p.spec"
  mkdir -p "$work/rpm-fp/SOURCES" "$work/rpms-fp"
  # unrelated shipped files: zero padding of their own, the same symbol table
  { printf 'other'; head -c 16384 /dev/zero; head -c 4096 /dev/urandom; } > "$work/rpm-fp/SOURCES/zeros"
  { head -c 3000 /dev/urandom; cat "$work/fp-symtab"; head -c 3000 /dev/urandom; } > "$work/rpm-fp/SOURCES/symtab"
  printf 'Name: f\nVersion: 1\nRelease: 0\nSummary: f\nLicense: MIT\nBuildArch: noarch\nSource0: zeros\nSource1: symtab\n%%description\nf\n%%install\ninstall -D -m 0644 %%{SOURCE0} %%{buildroot}/usr/share/f/zeros\ninstall -D -m 0644 %%{SOURCE1} %%{buildroot}/usr/share/f/symtab\n%%files\n/usr/share/f\n' > "$work/rpm-fp/f.spec"
  rpmbuild -bb --quiet --define "_topdir $work/rpm-fp" --define 'debug_package %{nil}' --define '__os_install_post %{nil}' \
    "$work/rpm-fp/f.spec" > /dev/null 2>&1
  find "$work/rpm-fp/RPMS" -name '*.rpm' -exec cp {} "$work/rpms-fp/" \;
  case_ shipped-padding 0 "read for shipped ones" "$d" --rpms "$work/rpms-fp"
  ! grep -q '^SHIPPED' <<<"$LAST" && pass "shipped: zero padding and a shared symbol table are no embed" \
    || fail "shipped: false SHIPPED: $(grep '^SHIPPED' <<<"$LAST" | head -3)"
  # A static library's code in a shipped file may be the package's own build of
  # the same sources with the same compiler (swift-lang's compiler-rt and the
  # seed's): the review decides. An exact copy of the archive stays red.
  shiprpm() { # shiprpm <dir> <file>: a noarch RPM of dir shipping file as /usr/lib/f/lib
    mkdir -p "$work/$1/SOURCES" "$work/$1-out"; cp "$2" "$work/$1/SOURCES/lib"
    printf 'Name: g\nVersion: 1\nRelease: 0\nSummary: g\nLicense: MIT\nBuildArch: noarch\nSource0: lib\n%%description\ng\n%%install\ninstall -D -m 0644 %%{SOURCE0} %%{buildroot}/usr/lib/f/lib\n%%files\n/usr/lib/f\n' > "$work/$1/g.spec"
    rpmbuild -bb --quiet --define "_topdir $work/$1" --define 'debug_package %{nil}' --define '__os_install_post %{nil}' \
      "$work/$1/g.spec" > /dev/null 2>&1
    find "$work/$1/RPMS" -name '*.rpm' -exec cp {} "$work/$1-out/" \;
  }
  { head -c 2000 /dev/urandom; cat "$work/fp-member"; head -c 2000 /dev/urandom; } > "$work/fp-linked"
  shiprpm rpm-emb "$work/fp-linked"
  case_ embeds-archive 0 "EMBEDS? g-1-0.noarch.rpm:./usr/lib/f/lib shares code with the prebuilt fp.tar.gz:./lib/libx.a" "$d" --rpms "$work/rpm-emb-out"
  ! grep -q '^SHIPPED' <<<"$LAST" && pass "embeds: an archive's code in a shipped file is for the review, not red" \
    || fail "embeds: archive code is SHIPPED: $(grep '^SHIPPED' <<<"$LAST" | head -2)"
  shiprpm rpm-copy "$work/t/fp/lib/libx.a"
  case_ shipped-archive-copy 3 "SHIPPED g-1-0.noarch.rpm:./usr/lib/f/lib is the prebuilt fp.tar.gz:./lib/libx.a" "$d" --rpms "$work/rpm-copy-out"
  # only a bootstrap's static library may be a review line: a test-data one is red
  d=$(pkg tdlib); mkdir -p "$work/t/tdl/tests"; cp "$work/t/fp/lib/libx.a" "$work/t/tdl/tests/"
  tar -C "$work/t/tdl" -czf "$d/tdl.tar.gz" .
  printf '# Source-Binary-Exception: tdl.tar.gz:./tests/* -- test-data: an archive the ar tests read\n' >> "$d/p.spec"
  case_ embeds-testdata 3 "SHIPPED g-1-0.noarch.rpm:./usr/lib/f/lib embeds the prebuilt tdl.tar.gz:./tests/libx.a" "$d" --rpms "$work/rpm-emb-out"
  # other-platform is no licence to ship: a file the RPMs carry is red
  d=$(pkg op-ship); cp "$work/otherplat/v.tar.gz" "$d/"
  printf '# Source-Binary-Exception: v.tar.gz:./ok/* -- other-platform: %s\n' "$OPW" >> "$d/p.spec"
  shiprpm rpm-op "$work/t/op/ok/tool.exe"
  case_ other-platform-shipped 3 "SHIPPED g-1-0.noarch.rpm:./usr/lib/f/lib is the prebuilt v.tar.gz:./ok/tool.exe" "$d" --rpms "$work/rpm-op-out"
  # nor is a path: the Android class the RPMs carry is red
  d=$(pkg jv-ship); cp "$work/jv-android/v.tar.gz" "$d/"; printf '# Source-Binary-Exception: %s\n' "$ANDROID" >> "$d/p.spec"
  shiprpm rpm-jv "$work/t/jv/w/android/lib/A.class"
  case_ other-platform-path-shipped 3 "SHIPPED g-1-0.noarch.rpm:./usr/lib/f/lib is the prebuilt v.tar.gz:./w/android/lib/A.class" "$d" --rpms "$work/rpm-jv-out"
  # a small helper (gcc -O2: under 1 KiB of .text in a 64 KiB file) embedded in a bundle
  if command -v gcc > /dev/null; then
    d=$(pkg tiny); mkdir -p "$work/t/tiny/bin"
    printf '#include <stdio.h>\n#include <unistd.h>\nint main(int c, char **v) { if (c < 2) { fprintf(stderr, "usage: %%s cmd\\n", v[0]); return 2; }\n  setsid(); execvp(v[1], v + 1); perror("execvp"); return 127; }\n' > "$work/tiny.c"
    gcc -O2 -o "$work/t/tiny/bin/pty-helper" "$work/tiny.c" && tar -C "$work/t/tiny" -czf "$d/tiny.tar.gz" .
    printf '# Source-Binary-Exception: tiny.tar.gz:./* -- bootstrap: %s\n' "$BOOT" >> "$d/p.spec"
    { head -c 3000 /dev/urandom; cat "$work/t/tiny/bin/pty-helper"; head -c 3000 /dev/urandom; } > "$work/tiny-bundle"
    shiprpm rpm-tiny "$work/tiny-bundle"
    case_ shipped-small-helper 3 "SHIPPED g-1-0.noarch.rpm:./usr/lib/f/lib embeds the prebuilt tiny.tar.gz:./bin/pty-helper" "$d" --rpms "$work/rpm-tiny-out"
  else
    echo "note: no gcc here, the small-helper case is not run"
  fi
else
  echo "note: no rpmbuild/rpm2cpio here, the --rpms cases are not run"
fi
mkdir -p "$work/norpms"
case_ no-rpms 2 "UNKNOWN $work/norpms: no binary RPM to read" "$d" --rpms "$work/norpms"
mkdir -p "$work/py"; ln -s "$(command -v python3)" "$work/py/python3"
out="$(PATH="$work/py" "$work/py/python3" "$SB" "$d" --rpms "$work/norpms" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qF "UNKNOWN $work/norpms: no rpm2cpio to read the RPMs" <<<"$out" \
  && pass "no-rpm2cpio (rc=2)" || { fail "no-rpm2cpio: expected rc=2, got rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

echo "---"; [ "$fails" = 0 ] && echo "all source-binaries checks passed" || echo "$fails FAILED"
exit $((fails > 0))
