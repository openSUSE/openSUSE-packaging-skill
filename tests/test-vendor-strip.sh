#!/bin/bash
# test-vendor-strip.sh — vendor-strip.py removes exactly the members its globs
# name from a cargo vendor tarball, drops exactly their keys from each crate's
# .cargo-checksum.json and leaves every other byte alone. Sessions hand-wrote
# this repack 28 times and broke it three ways: top-level entries dropped,
# checksum JSON re-dumped with other formatting, globs that missed listed
# files. Fixtures are made at run time; offline.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
VS="$HERE/../skills/opensuse-packaging/scripts/vendor-strip.py"
SB="$HERE/../skills/opensuse-packaging/scripts/source-binaries.py"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export XDG_CACHE_HOME="$work/cache"

# run <expected rc> <expected text> [args] — LAST holds the output
run() {
  local want=$1 text=$2; shift 2
  local rc
  LAST="$(python3 "$VS" "$@" 2>&1)"; rc=$?
  [ "$rc" = "$want" ] && grep -qF -- "$text" <<<"$LAST" && pass "vendor-strip $* (rc=$want)" || {
    fail "vendor-strip $*: expected rc=$want and '$text', got rc=$rc"; printf '%s\n' "$LAST" | sed 's/^/    /'; }
}

# A cargo_vendor-shaped tarball: .cargo/config.toml and Cargo.lock at the top,
# crates under vendor/, compact .cargo-checksum.json maps. Mixed header kinds on
# purpose (GNU long names, a PAX member, a global PAX header) so "byte-identical"
# means the raw blocks, not what tarfile would write again.
python3 - "$work/vendor.tar" <<'PY'
import hashlib, io, struct, sys, tarfile
def coff(machine=0x8664):
    hdr = struct.pack("<HHIIIHH", machine, 2, 0, 0, 0, 0, 0)
    return hdr + b"".join(n.ljust(8, b"\0") + b"\0" * 32 for n in (b".text", b".data")) + b"\0" * 64
long_dir = "src/" + "deeply/" * 12
files = {
    ".cargo/config.toml": b'[source.crates-io]\nreplace-with = "vendored-sources"\n',
    "Cargo.lock": b"# lock\n",
    "vendor/ring-0.17.14/A-prebuilt.o": coff(0xAA64),
    "vendor/ring-0.17.14/Cargo.toml": b"[package]\nname = \"ring\"\n",
    "vendor/ring-0.17.14/pregenerated/aes-x86_64-elf.S": b"; assembly\n",
    "vendor/ring-0.17.14/pregenerated/aes-x86_64-nasm.o": coff(),
    "vendor/ring-0.17.14/pregenerated/chacha-x86_64-win32n.o": coff(0x14C),
    "vendor/ring-0.17.14/src/lüb.rs": b"// lib\n",
    "vendor/ring-0.17.14/" + long_dir + "x.rs": b"// deep\n",
    "vendor/aws-lc-sys-0.45.0/Cargo.toml": b"[package]\nname = \"aws-lc-sys\"\n",
    "vendor/aws-lc-sys-0.45.0/builder/prebuilt-nasm/aesni-x86_64.obj": coff(),
    "vendor/aws-lc-sys-0.45.0/build.rs": b"fn main() {}\n",
    "vendor/libc-0.2.170/Cargo.toml": b"[package]\nname = \"libc\"\n",
    "vendor/libc-0.2.170/src/lib.rs": b"// libc\n",
    "vendor/libc-0.2.170/stray.o": coff(),
}
order = sorted(files)
crates = sorted({p.split("/")[1] for p in files if p.startswith("vendor/")})
sums = {}
for c in crates:
    rel = [p[len(f"vendor/{c}/"):] for p in order if p.startswith(f"vendor/{c}/")]
    # stray.o is in the tarball but not in its crate's checksum map
    inner = ",".join(f'"{r}":"{hashlib.sha256(files[f"vendor/{c}/{r}"]).hexdigest()}"'
                     for r in rel if r != "stray.o")
    sums[f"vendor/{c}/.cargo-checksum.json"] = ('{"files":{' + inner + '},"package":"'
                                                 + "ab" * 32 + '"}').encode()
files.update(sums)
out = bytearray()
def member(name, data, fmt=tarfile.GNU_FORMAT, mode=0o644, pax=None):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.mtime, ti.uname, ti.gname = len(data), mode, 1700000000, "", ""
    if pax:
        ti.pax_headers = pax
    out.extend(ti.tobuf(fmt, "utf-8", "surrogateescape"))
    out.extend(data + b"\0" * (-len(data) % 512))
first = True
for name in sorted(files):
    if name.startswith("vendor/aws-lc-sys") and first:
        g = tarfile.TarInfo._create_pax_generic_header({"comment": "global"}, tarfile.XGLTYPE, "utf-8")
        out.extend(g); first = False
    pax = {"mtime": "1700000000.5"} if name.endswith("build.rs") else None
    member(name, files[name], tarfile.PAX_FORMAT if pax else tarfile.GNU_FORMAT,
           0o755 if name.endswith("build.rs") else 0o644, pax)
out.extend(b"\0" * 1024)
out.extend(b"\0" * (-len(out) % 10240))
open(sys.argv[1], "wb").write(out)
PY

# check <original> <stripped> <removed member>... — names, raw bytes, checksum maps
check() {
  python3 - "$@" <<'PY'
import gzip, lzma, bz2, json, subprocess, sys, tarfile
orig, new, removed = sys.argv[1], sys.argv[2], set(sys.argv[3:])
def raw(path):
    head = open(path, "rb").read(6)
    if head.startswith(b"\x1f\x8b"): return "gz", gzip.open(path).read()
    if head.startswith(b"\xfd7zXZ\0"): return "xz", lzma.open(path).read()
    if head.startswith(b"BZh"): return "bz2", bz2.open(path).read()
    if head.startswith(b"(\xb5/\xfd"):
        return "zst", subprocess.run(["zstd", "-dc", path], capture_output=True, check=True).stdout
    return "tar", open(path, "rb").read()
def members(data):
    import io
    tf = tarfile.open(fileobj=io.BytesIO(data), mode="r:")
    out = []
    for m in tf.getmembers():
        end = m.offset_data + m.size + (-m.size % 512)
        out.append((m, data[m.offset:m.offset_data], data[m.offset_data:end]))
    return out
ko, o = raw(orig); kn, n = raw(new)
bad = []
if ko != kn: bad.append(f"compression {ko} became {kn}")
om, nm = members(o), members(n)
want = [x for x in om if x[0].name not in removed]
if [x[0].name for x in nm] != [x[0].name for x in want]:
    bad.append(f"member list: {[x[0].name for x in nm]}")
for (a, ha, da), (b, hb, db) in zip(want, nm):
    if a.name.endswith("/.cargo-checksum.json"):
        crate = a.name[: -len(".cargo-checksum.json")]
        text = da.rstrip(b"\0").decode()
        old = json.loads(text)
        gone = {r[len(crate):] for r in removed if r.startswith(crate)} & set(old["files"])
        if not gone:
            if (ha, da) != (hb, db): bad.append(f"{a.name}: untouched map changed")
            continue
        exp = {k: v for k, v in old["files"].items() if k not in gone}
        got_text = db[: b.size].decode()
        got = json.loads(got_text)
        if got["files"] != exp or got["package"] != old["package"]:
            bad.append(f"{a.name}: map {got}")
        # exactly the removed pairs gone, nothing re-dumped
        rebuilt = text
        for k in gone:
            for pat in (f'"{k}":"{old["files"][k]}",', f',"{k}":"{old["files"][k]}"', f'"{k}":"{old["files"][k]}"'):
                if pat in rebuilt:
                    rebuilt = rebuilt.replace(pat, "", 1); break
        if got_text != rebuilt: bad.append(f"{a.name}: bytes {got_text!r} != {rebuilt!r}")
        # header: only the size and its checksum may differ
        diff = [i for i in range(len(ha)) if ha[i] != hb[i]] if len(ha) == len(hb) else ["len"]
        if any(not (124 <= i < 136 or 148 <= i < 156) for i in diff):
            bad.append(f"{a.name}: header bytes {diff} changed")
        if (a.mtime, a.mode, a.uid, a.gid, a.uname, a.gname) != (b.mtime, b.mode, b.uid, b.gid, b.uname, b.gname):
            bad.append(f"{a.name}: metadata changed")
    elif (ha, da) != (hb, db):
        bad.append(f"{a.name}: raw bytes changed")
if len(n) % 10240: bad.append(f"length {len(n)} is not whole 10240-byte records")
print("\n".join(bad) if bad else "same")
sys.exit(1 if bad else 0)
PY
}

STRIP=(vendor/ring-0.17.14/A-prebuilt.o vendor/ring-0.17.14/pregenerated/aes-x86_64-nasm.o vendor/ring-0.17.14/pregenerated/chacha-x86_64-win32n.o
       vendor/aws-lc-sys-0.45.0/builder/prebuilt-nasm/aesni-x86_64.obj)
# the map's first, middle and last keys: A-prebuilt.o sorts before Cargo.toml
GLOBS=('ring-*/pregenerated/*.o' 'aws-lc-sys-*/builder/prebuilt-nasm/*.obj' 'ring-*/A-*.o')

# No usage error passes for a result, and --help names its exit codes.
run 0 "Exit:" --help
run 2 "-o" "$work/vendor.tar" 'ring-*/pregenerated/*.o'

# --dry-run lists what would go and writes nothing.
cp "$work/vendor.tar" "$work/dry.tar"
run 0 "would remove vendor/ring-0.17.14/pregenerated/aes-x86_64-nasm.o" --dry-run "$work/dry.tar" "${GLOBS[@]}"
grep -qF "ring-0.17.14: 3 file(s)" <<<"$LAST" && grep -qF "aws-lc-sys-0.45.0: 1 file(s)" <<<"$LAST" \
  && pass "dry-run: a summary per crate" || fail "dry-run summary: $LAST"
cmp -s "$work/vendor.tar" "$work/dry.tar" && [ "$(find "$work" -mindepth 1 -maxdepth 1 -newer "$work/dry.tar" | wc -l)" = 0 ] \
  && pass "dry-run: nothing written" || fail "dry-run wrote something"

# Every compression cargo_vendor writes (and none), each kept as it was.
for z in tar gz xz bz2 zst; do
  src="$work/v-$z"
  case $z in
    tar) cp "$work/vendor.tar" "$src" ;;
    gz) gzip -c "$work/vendor.tar" > "$src" ;;
    xz) xz -c "$work/vendor.tar" > "$src" ;;
    bz2) bzip2 -c "$work/vendor.tar" > "$src" ;;
    zst) if command -v zstd > /dev/null; then zstd -q -c "$work/vendor.tar" > "$src"
         else echo "note: no zstd here, its case is not run"; continue; fi ;;
  esac
  run 0 "STRIPPED: 4 member(s) from 2 crate(s)" "$src" -o "$src.out" "${GLOBS[@]}"
  r=$(check "$src" "$src.out" "${STRIP[@]}") && pass "$z: exactly the 4 members gone, the rest byte-identical" \
    || fail "$z: $r"
done

# Deterministic: the same input and globs give the same bytes.
python3 "$VS" "$work/v-xz" -o "$work/again.xz" "${GLOBS[@]}" > /dev/null 2>&1
cmp -s "$work/v-xz.out" "$work/again.xz" && pass "deterministic output" || fail "two runs differ"
python3 "$VS" "$work/v-xz" -o "$work/swapped.xz" "${GLOBS[2]}" "${GLOBS[1]}" "${GLOBS[0]}" > /dev/null 2>&1
cmp -s "$work/v-xz.out" "$work/swapped.xz" && pass "glob order does not matter" || fail "glob order changes the output"

# In place: -o may name the input.
cp "$work/v-gz" "$work/inplace.tar.gz"
run 0 "STRIPPED" "$work/inplace.tar.gz" -o "$work/inplace.tar.gz" "${GLOBS[@]}"
r=$(check "$work/v-gz" "$work/inplace.tar.gz" "${STRIP[@]}") && pass "in place: same result" || fail "in place: $r"

# ** spans directories; * and ? stay inside one path segment.
run 0 "STRIPPED: 1 member(s) from 1 crate(s)" "$work/vendor.tar" -o "$work/deep.tar" 'aws-lc-sys-*/**/*.obj'
run 1 "matches nothing" "$work/vendor.tar" -o "$work/x.tar" 'aws-lc-sys-*/*.obj'
[ ! -e "$work/x.tar" ] && pass "a refused run writes nothing" || fail "a refused run wrote $work/x.tar"
run 1 "relative to vendor/" "$work/vendor.tar" -o "$work/x.tar" 'vendor/ring-*/pregenerated/*.o'
run 1 "'nothing/*' matches nothing" "$work/vendor.tar" -o "$work/x.tar" "${GLOBS[@]}" 'nothing/*'

# A crate's manifest and checksum file are never removed.
rm -f "$work/x.tar"
run 1 "Cargo.toml" "$work/vendor.tar" -o "$work/x.tar" 'ring-*/*'
run 1 ".cargo-checksum.json" "$work/vendor.tar" -o "$work/x.tar" '*/.cargo-checksum.json'
[ ! -e "$work/x.tar" ] && pass "refusals write nothing" || fail "a refusal wrote $work/x.tar"

# A file the checksum map does not list goes with a note; the map stays as it was.
run 0 "not listed" "$work/vendor.tar" -o "$work/stray.tar" 'libc-*/stray.o'
r=$(check "$work/vendor.tar" "$work/stray.tar" vendor/libc-0.2.170/stray.o) && pass "unlisted file: map untouched" \
  || fail "unlisted file: $r"

# Not a cargo vendor tarball, or not an archive at all.
mkdir -p "$work/plain/a"; echo x > "$work/plain/a/f"; tar -C "$work/plain" -cf "$work/plain.tar" a
run 2 ".cargo-checksum.json" "$work/plain.tar" -o "$work/x.tar" 'a/*'
echo "not a tarball" > "$work/junk.tar.zst"
run 2 "cannot read" "$work/junk.tar.zst" -o "$work/x.tar" 'a/*'

# A tarball tarfile stops reading early (a corrupt header mid-way) or that ends
# early is unreadable, never "the rest": that would drop every member after it.
python3 - "$work/vendor.tar" "$work/badhdr.tar" "$work/short.tar" <<'PY'
import sys, tarfile
src, bad, short = sys.argv[1:]
data = bytearray(open(src, "rb").read())
m = next(m for m in tarfile.open(src).getmembers() if m.name == "vendor/libc-0.2.170/src/lib.rs")
data[m.offset + 148 : m.offset + 156] = b"0000000\0"   # a checksum that does not hold
open(bad, "wb").write(data)
lib = next(m for m in tarfile.open(src).getmembers() if m.name == "vendor/libc-0.2.170/Cargo.toml")
open(short, "wb").write(open(src, "rb").read()[: lib.offset_data + 5])
PY
run 2 "cannot read" "$work/badhdr.tar" -o "$work/x.tar" 'ring-*/A-*.o'
run 2 "cannot read" "$work/short.tar" -o "$work/x.tar" 'ring-*/A-*.o'
head -c $(( $(wc -c < "$work/v-xz") / 2 )) "$work/v-xz" > "$work/short.tar.xz"
run 2 "cannot read" "$work/short.tar.xz" -o "$work/x.tar" 'ring-*/A-*.o'
printf '\037\213\010\000\000\000\000\000\000\003this is no deflate stream at all' > "$work/bad.tar.gz"
run 2 "cannot read" "$work/bad.tar.gz" -o "$work/x.tar" 'ring-*/A-*.o'
[ ! -e "$work/x.tar" ] && pass "unreadable input: nothing written" || fail "unreadable input wrote $work/x.tar"

# An output that cannot be written is exit 2, and a compressor that fails half
# way leaves the input as it was and no temporary file behind.
run 2 "cannot write" "$work/vendor.tar" -o "$work/no-such-dir/out.tar" 'ring-*/A-*.o'
if command -v zstd > /dev/null; then
  mkdir -p "$work/fakebin" "$work/midfail"
  zs=$(command -v zstd)
  printf '#!/bin/bash\ncase " $* " in *" -dcq "*) exec %s "$@" ;; esac\ncat > /dev/null; exit 1\n' "$zs" > "$work/fakebin/zstd"
  chmod +x "$work/fakebin/zstd"; cp "$work/v-zst" "$work/midfail/v.tar.zst"
  out=$(PATH="$work/fakebin:$PATH" python3 "$VS" "$work/midfail/v.tar.zst" -o "$work/midfail/v.tar.zst" 'ring-*/A-*.o' 2>&1); rc=$?
  [ $rc = 2 ] && cmp -s "$work/v-zst" "$work/midfail/v.tar.zst" && [ "$(ls -A "$work/midfail")" = v.tar.zst ] \
    && pass "a compressor failing mid-write: exit 2, input intact, no temporary left" \
    || { fail "mid-write failure: rc=$rc, dir: $(ls -A "$work/midfail")"; printf '%s\n' "$out" | sed 's/^/    /'; }
fi

# A glob naming a directory says how to take what is under it.
run 1 "'ring-*/pregenerated/**'" "$work/vendor.tar" -o "$work/x.tar" 'ring-*/pregenerated'

# Links: a kept hard link or symlink to a removed member would dangle (GNU tar
# 1.35 spins on such a hard link at extract), so that is refused; removing the
# links too is fine. A pretty-printed map keeps its layout.
python3 - "$work/links.tar" <<'PY'
import io, sys, tarfile
pretty = (b'{\n  "files": {\n    "Cargo.toml": "aa",\n    "lib/a.o": "bb",\n'
          b'    "lib/b.o": "cc",\n    "lib/c.rs": "dd"\n  },\n  "package": "ee"\n}')
with tarfile.open(sys.argv[1], "w", format=tarfile.GNU_FORMAT) as t:
    def add(name, data=None, kind=tarfile.REGTYPE, link=""):
        ti = tarfile.TarInfo(name); ti.type, ti.linkname, ti.mtime = kind, link, 1700000000
        ti.size = len(data or b"")
        t.addfile(ti, io.BytesIO(data) if data else None)
    add("vendor/foo-1.0/.cargo-checksum.json", pretty)
    add("vendor/foo-1.0/Cargo.toml", b"[package]\n")
    add("vendor/foo-1.0/lib/a.o", b"\0" * 64)
    add("vendor/foo-1.0/lib/b.o", b"\1" * 64)
    add("vendor/foo-1.0/lib/c.rs", b"// c\n")
    add("vendor/foo-1.0/lib/hard.o", kind=tarfile.LNKTYPE, link="vendor/foo-1.0/lib/a.o")
    add("vendor/foo-1.0/lib/sym.o", kind=tarfile.SYMTYPE, link="b.o")
PY
run 1 "hard link" "$work/links.tar" -o "$work/x.tar" 'foo-*/lib/a.o'
run 1 "symlink" "$work/links.tar" -o "$work/x.tar" 'foo-*/lib/b.o'
[ ! -e "$work/x.tar" ] && pass "dangling links: nothing written" || fail "a dangling-link run wrote $work/x.tar"
run 0 "STRIPPED: 4 member(s)" "$work/links.tar" -o "$work/links-out.tar" 'foo-*/lib/*.o'
got=$(tar -xOf "$work/links-out.tar" vendor/foo-1.0/.cargo-checksum.json)
want=$(printf '{\n  "files": {\n    "Cargo.toml": "aa",\n    "lib/c.rs": "dd"\n  },\n  "package": "ee"\n}')
[ "$got" = "$want" ] && pass "a pretty-printed map keeps its layout" || fail "pretty map: $got"

# The point of it: source-binaries.py finds the Windows objects before, none after.
mkdir -p "$work/pkg-before" "$work/pkg-after"
printf 'Name: p\n' | tee "$work/pkg-before/p.spec" > "$work/pkg-after/p.spec"
cp "$work/v-xz" "$work/pkg-before/vendor.tar.xz"
python3 "$VS" "$work/v-xz" -o "$work/pkg-after/vendor.tar.xz" "${GLOBS[@]}" 'libc-*/stray.o' > /dev/null 2>&1
out=$(python3 "$SB" "$work/pkg-before" 2>&1); rc=$?
[ $rc = 3 ] && grep -qF "aes-x86_64-nasm.o: COFF object" <<<"$out" && pass "source-binaries: the original is red" \
  || { fail "source-binaries before: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
out=$(python3 "$SB" "$work/pkg-after" 2>&1); rc=$?
[ $rc = 0 ] && [ -s "$work/pkg-after/vendor.tar.xz" ] && pass "source-binaries: the stripped tarball is clean" \
  || { fail "source-binaries after: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

[ $fails -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
