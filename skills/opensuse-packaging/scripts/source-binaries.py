#!/usr/bin/env python3
"""Prebuilt binaries in a package's sources: executables, shared and static
libraries, native addons, wasm, Java bytecode and RPMs in every file of the
checkout. Archives (tar, gzip, xz, zstd, bzip2, zip, cpio/obscpio) are streamed
member by member, one level into nested archives (an npm .tgz inside a vendor
tarball), and nothing is extracted.

  source-binaries.py [DIR] [--rpms RPMDIR] [--all] [--no-cache]
  DIR         package checkout (default .)
  --rpms RPMDIR  also read the built RPMs in RPMDIR (osc getbinaries -d, or a
              build root's RPMS): a payload file that is, or carries verbatim, a
              prebuilt binary from the sources is SHIPPED, red whatever its
              exception says, firmware alone excepted
  --all       list every hit (default: the first 20, then a count per kind and
              per directory)
  --no-cache  rescan archives scanned before (results are cached by sha256
              under $XDG_CACHE_HOME/opensuse-packaging/source-binaries)

"All binaries or libraries included with openSUSE packages must have been built
from source code included in the source package" (openSUSE:Packaging_guidelines).
A binary the package ships, embeds, loads or links is never an exception: build
it from source or unbundle it. "Only used at build time" is no exception either:
the source package still redistributes it. A hit is allowed only when a spec
comment in DIR names it:

  # Source-Binary-Exception: <glob> -- bootstrap|firmware|test-data: <why>

<glob> (fnmatch: * spans /) matches the hit's path, FILE, FILE:MEMBER or
FILE:MEMBER!INNER. firmware: a blob no source exists for; test-data: a fixture
the tests only read, so the glob must lie under a test directory (tests/,
testdata/, fixtures/, corpus/, golden/, or an example's examples/ or
samples/); bootstrap: a compiler or toolchain that needs a previous build of
itself, used only during the build and never shipped, with a why of at least
8 words saying what it builds and why no
packaged predecessor can. Every bootstrap exception is named on the verdict
line (references/specfile-guidelines.md "Spec file — general rules"). The
shipped check finds a binary copied into an RPM and one a bundler embeds
verbatim in its single executable (a 4 KiB fingerprint of each hit of 1 KiB or
more); one stored compressed or encoded stays the review's to find.

A file that cannot be read completely (a 7z or rar archive, a missing
decompressor, a broken archive, a git-lfs pointer whose object was not fetched)
is UNKNOWN, never clean.

Exit: 0 no prebuilt binary outside the named exceptions · 2 usage, a file that
could not be read, or --rpms found no RPM to read · 3 prebuilt binaries the spec
does not except, an exception line that does not hold, or a shipped one
"""

import argparse
import collections
import fnmatch
import hashlib
import io
import json
import lzma
import os
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile
import zlib

VERSION = 3  # bump when detection changes, so cached results are rescanned
HEAD = 4096
PRINT = 1024  # shortest hit whose bytes are searched for inside the payload
CHUNK = 8 << 20
NESTED_ZIP_CAP = 256 << 20
SHOW = 20
EXCEPTION = re.compile(r"^#\s*Source-Binary-Exception:(.*)$")
EXCEPTION_BODY = re.compile(
    r"^\s*(\S+)\s+--\s+(bootstrap|firmware|test-data):\s*(\S.*)$"
)
# a test directory: tests/, testdata/, manual_tests/, fixtures/, fuzz/corpus/, golden-*/,
# examples/ and samples/ (an example's input data);
# a word, so latest/ or googletest/ are not one
TEST_PATH = re.compile(
    r"(?:^|[^a-z0-9])(?:unit)?(?:tests?|testing|testdata|test[-_]data|fixtures?|corpus|golden|examples?|samples?)"
    r"(?:[^a-z0-9]|$)",
    re.I,
)
BOOTSTRAP_WORDS = 8
FIX = (
    "a binary the package ships, embeds, loads or links is never an exception: build "
    "it from source or unbundle it (BuildRequires the system package; Rust: cargo_vendor "
    "filter=true, then strip what is left and drop it from .cargo-checksum.json)"
)
LFS = b"version https://git-lfs.github.com/spec/v1"
COMPRESSED = {  # magic: (external tool, python module)
    b"\x1f\x8b": ("gzip", "gzip"),
    b"\xfd7zXZ\x00": ("xz", "lzma"),
    b"(\xb5/\xfd": ("zstd", "zstd"),
    b"BZh": ("bzip2", "bz2"),
}
UNSUPPORTED = {b"7z\xbc\xaf\x27\x1c": "7z archive", b"Rar!\x1a\x07": "rar archive"}
# what a corrupt or exotic archive raises while it is read
DECODE = (
    tarfile.TarError,
    zipfile.BadZipFile,
    zlib.error,
    lzma.LZMAError,
    OSError,
    EOFError,
    ValueError,
)


def kind(head, name):
    """What prebuilt binary head (a file's first bytes) is, or None."""
    if head[:4] == b"\x7fELF":
        return "ELF"
    if head[:2] == b"MZ":
        off = int.from_bytes(head[60:64], "little") if len(head) >= 64 else -1
        if 0 <= off <= len(head) - 4 and head[off : off + 4] == b"PE\0\0":
            return "PE"
        if name.lower().endswith((".exe", ".dll", ".sys", ".efi")):
            return "PE"
        return None
    m = head[:4]
    if m in (
        b"\xfe\xed\xfa\xce",
        b"\xfe\xed\xfa\xcf",
        b"\xce\xfa\xed\xfe",
        b"\xcf\xfa\xed\xfe",
    ):
        return "Mach-O"
    if m in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf") and len(head) >= 8:
        # a fat Mach-O counts its slices here; a class file its version (major >= 45)
        return "Mach-O" if int.from_bytes(head[4:8], "big") < 45 else "Java class"
    if head[:8] in (b"!<arch>\n", b"!<thin>\n"):
        return "ar archive"
    if m == b"\0asm":
        return "wasm"
    if m == b"\xed\xab\xee\xdb":
        return "RPM"
    return None


def archive(head):
    """The container format head starts, or None."""
    for magic in COMPRESSED:
        if head.startswith(magic):
            return "compressed"
    if head[:4] == b"PK\x03\x04":
        return "zip"
    if head[:6] in (b"070701", b"070702"):
        return "cpio"
    if len(head) >= 262 and head[257:262] == b"ustar":
        return "tar"
    return None


class Prefixed(io.RawIOBase):
    """head, then the rest of stream: a peeked stream read from its start."""

    def __init__(self, head, stream):
        self.head, self.stream = head, stream

    def readable(self):
        return True

    def readinto(self, b):
        if self.head:
            n = min(len(b), len(self.head))
            b[:n], self.head = self.head[:n], self.head[n:]
            return n
        data = self.stream.read(len(b))
        b[: len(data)] = data
        return len(data)


class Limited(io.RawIOBase):
    """At most n bytes of stream."""

    def __init__(self, stream, n):
        self.stream, self.left = stream, n

    def readable(self):
        return True

    def readinto(self, b):
        if self.left <= 0:
            return 0
        data = self.stream.read(min(len(b), self.left))
        self.left -= len(data)
        b[: len(data)] = data
        return len(data)


def digest(head, stream):
    """(sha256, fingerprint) of head and the rest of stream, read to its end.
    The fingerprint is 4 KiB from past the headers every binary of a kind
    shares (the whole file when it is short): what a bundler that embeds the
    file in its single executable still carries verbatim."""
    h, buf = hashlib.sha256(head), bytearray(head)
    while True:
        data = stream.read(1 << 20)
        if not data:
            break
        h.update(data)
        if len(buf) < 2 * HEAD:
            buf += data[: 2 * HEAD - len(buf)]
    whole = len(buf) < 2 * HEAD
    fp = bytes(buf) if whole else bytes(buf[HEAD : 2 * HEAD])
    return h.hexdigest(), (fp.hex() if len(fp) >= PRINT else "")


def drain(stream):
    while stream.read(1 << 20):
        pass


def read_head(stream):
    buf = b""
    while len(buf) < HEAD:
        data = stream.read(HEAD - len(buf))
        if not data:
            break
        buf += data
    return buf


class Scan:
    def __init__(self):
        self.hits = []  # (path, kind)
        self.unknown = []  # (path, why)
        self.members = 0
        self.host = False  # an UNKNOWN this host caused (no decompressor): not cached

    def item(self, path, head, stream, depth, size=None):
        """Judge one file whose first bytes are head and rest is stream."""
        self.members += 1
        k = kind(head, path)
        if k:
            self.hits.append((path, k, *digest(head, stream)))
            return
        for magic, what in UNSUPPORTED.items():
            if head.startswith(magic):
                self.unknown.append((path, f"a {what}, which this scan cannot read"))
                return
        fmt = archive(head)
        if fmt is None or depth > 1:
            return
        self.container(path, fmt, Prefixed(head, stream), depth + 1, size)

    def container(self, path, fmt, stream, depth, size=None):
        sep = ":" if depth == 1 else "!"
        try:
            if fmt == "compressed":
                self.compressed(path, stream, depth, sep)
            elif fmt == "tar":
                self.tar(path, stream, depth, sep)
            elif fmt == "cpio":
                self.cpio(path, stream, depth, sep)
            elif fmt == "zip":
                if size is not None and size > NESTED_ZIP_CAP:
                    self.unknown.append((path, "nested zip over 256 MiB, not scanned"))
                    return
                data = io.BytesIO(stream.read())
                self.zip(path, zipfile.ZipFile(data), depth, sep)
        except DECODE as e:
            self.unknown.append((path, f"cannot read the {fmt} archive: {e}"))

    def compressed(self, path, stream, depth, sep):
        head = read_head(stream)
        tool, module = next(v for m, v in COMPRESSED.items() if head.startswith(m))
        raw = Prefixed(head, stream)
        proc = None
        if shutil.which(tool):
            proc = subprocess.Popen(
                [tool, "-dc"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
            feeder = _Feeder(raw, proc.stdin)
            feeder.start()
            inner = proc.stdout
        else:
            mod = _module(module)
            if mod is None:
                self.unknown.append((path, f"no {tool} to decompress it"))
                self.host = True
                return
            inner = (
                mod.open(io.BufferedReader(raw))
                if module != "zstd"
                else mod.ZstdFile(raw)
            )
        try:
            ihead = read_head(inner)
            fmt = archive(ihead)
            if fmt in ("tar", "cpio", "zip"):
                self.container(path, fmt, Prefixed(ihead, inner), depth)
            else:
                k = kind(ihead, path)
                if k:
                    self.hits.append((path, k + " (compressed)", *digest(ihead, inner)))
            # to its end: a tar stops at its end-of-archive blocks, and a
            # decompressor left writing would die of SIGPIPE and read as broken
            drain(inner)
        finally:
            if proc is not None:
                proc.stdout.close()
                feeder.join()
                if proc.wait() != 0 and not feeder.broken:
                    self.unknown.append((path, f"{tool} -dc failed"))

    def tar(self, path, stream, depth, sep):
        with tarfile.open(fileobj=io.BufferedReader(stream, 1 << 16), mode="r|") as tf:
            for m in tf:
                if not m.isfile():
                    continue
                f = tf.extractfile(m)
                self.item(f"{path}{sep}{m.name}", read_head(f), f, depth, m.size)

    def cpio(self, path, stream, depth, sep):
        for name, size, body in cpio_files(stream):
            self.item(f"{path}{sep}{name}", read_head(body), body, depth, size)

    def zip(self, path, zf, depth, sep):
        for info in zf.infolist():
            if info.is_dir():
                continue
            member = f"{path}{sep}{info.filename}"
            try:
                with zf.open(info) as f:
                    self.item(member, read_head(f), f, depth, info.file_size)
            except NotImplementedError:
                # unread is not clean: an exception may name a format-test corpus
                self.unknown.append(
                    (member, f"zip method {info.compress_type} is not readable here")
                )
            except RuntimeError:
                self.unknown.append((member, "an encrypted zip member"))
            except DECODE as e:
                self.unknown.append((member, f"cannot read this zip member: {e}"))


def cpio_files(stream):
    """(name, size, body) of each regular file in a newc cpio stream; a body
    not read to its end is skipped."""
    stream = io.BufferedReader(stream, 1 << 16)
    while True:
        hdr = stream.read(110)
        if len(hdr) < 110:
            raise EOFError("truncated cpio header")
        if hdr[:6] not in (b"070701", b"070702"):
            raise ValueError("not a newc cpio header")
        mode = int(hdr[14:22], 16)
        size = int(hdr[54:62], 16)
        nsize = int(hdr[94:102], 16)
        name = stream.read(nsize).rstrip(b"\0").decode("utf-8", "replace")
        stream.read((4 - (110 + nsize) % 4) % 4)
        if name == "TRAILER!!!":
            return
        body = Limited(stream, size)
        if mode & 0o170000 == 0o100000:
            yield name, size, body
        drain(body)
        stream.read((4 - size % 4) % 4)


class _Feeder:
    """Copies raw into a decompressor's stdin on a thread."""

    def __init__(self, raw, sink):
        import threading

        self.raw, self.sink, self.broken = raw, sink, False
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def run(self):
        try:
            while True:
                data = self.raw.read(1 << 20)
                if not data:
                    break
                self.sink.write(data)
        except (BrokenPipeError, OSError):
            self.broken = True
        finally:
            try:
                self.sink.close()
            except OSError:
                pass

    def join(self):
        self.thread.join()


def _module(name):
    try:
        if name == "zstd":
            from compression import zstd  # Python 3.14+

            return zstd
        return __import__(name)
    except ImportError:
        return None


def scan_file(path, name):
    """(hits, unknown, members) for one file of the checkout."""
    s = Scan()
    try:
        with open(path, "rb") as fh:
            head = read_head(fh)
            if head.startswith(LFS):
                s.unknown.append((name, "a git-lfs pointer: the object is not fetched"))
                return s
            for magic, what in UNSUPPORTED.items():
                if head.startswith(magic):
                    s.unknown.append((name, f"a {what}, which this scan cannot read"))
                    return s
            fmt = archive(head)
            k = kind(head, name)
            if k:
                s.hits.append((name, k, *digest(head, fh)))
            elif fmt == "zip":
                try:
                    with zipfile.ZipFile(
                        path
                    ) as zf:  # seekable on disk: never read whole
                        s.zip(name, zf, 1, ":")
                except DECODE as e:
                    s.unknown.append((name, f"cannot read the zip archive: {e}"))
            elif fmt:
                s.container(name, fmt, Prefixed(head, fh), 1)
    except OSError as e:
        s.unknown.append((name, f"cannot read it: {e.strerror}"))
    return s


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cached_scan(path, name, use_cache):
    cache = os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
        "opensuse-packaging",
        "source-binaries",
    )
    key = None
    if use_cache:
        try:
            key = os.path.join(cache, f"v{VERSION}-{sha256(path)}.json")
            with open(key, encoding="utf-8") as fh:
                d = json.load(fh)
            s = Scan()
            # cached paths start with the name the file had then
            old = d["name"]
            s.hits = [(name + p[len(old) :], k, h, f) for p, k, h, f in d["hits"]]
            s.unknown = [(name + p[len(old) :], w) for p, w in d["unknown"]]
            s.members = d["members"]
            return s
        except (OSError, ValueError, KeyError):
            pass
    s = scan_file(path, name)
    if key and not s.host:
        try:
            os.makedirs(cache, exist_ok=True)
            tmp = key + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "name": name,
                        "hits": s.hits,
                        "unknown": s.unknown,
                        "members": s.members,
                    },
                    fh,
                )
            os.replace(tmp, key)
        except OSError:
            pass
    return s


def exceptions(d):
    """[(glob, reason, why)] from every spec in d, and malformed lines."""
    out, bad = [], []
    for spec in sorted(f for f in os.listdir(d) if f.endswith(".spec")):
        try:
            with open(os.path.join(d, spec), encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            m = EXCEPTION.match(line)
            if not m:
                continue
            b = EXCEPTION_BODY.match(m.group(1))
            where = f"{spec}:{n}: {line.strip()}"
            if not b:
                bad.append(
                    f"{where}: want '<glob> -- bootstrap|firmware|test-data: <why>'"
                )
                continue
            glob, reason, why = b.groups()
            # the directories the glob names inside its file, not the file itself
            dirs = re.split(r"[/!]", glob.split(":", 1)[1] if ":" in glob else glob)[
                :-1
            ]
            if reason == "test-data" and not any(TEST_PATH.search(c) for c in dirs):
                bad.append(
                    f"{where}: test-data names a test fixture, and {glob} is not inside a test "
                    "directory (tests/, testdata/, fixtures/, corpus/, golden/, examples/)"
                )
            elif reason == "bootstrap" and len(why.split()) < BOOTSTRAP_WORDS:
                bad.append(
                    f"{where}: a bootstrap needs a why of {BOOTSTRAP_WORDS}+ words: what it "
                    "builds, and why no packaged predecessor can"
                )
            else:
                out.append((glob, reason, why))
    return out, bad


def rpm_payloads(rpmdir, prebuilt, prints):
    """Every payload file of the binary RPMs in rpmdir against the source hits:
    ([(payload path, how, source path)], unknown, rpms). prebuilt maps a hit's
    sha256 to its path, prints a fingerprint's bytes to the hit's path."""
    s, rpms, found = Scan(), 0, []
    overlap = max((len(f) for f in prints), default=1) - 1
    names = sorted(
        f
        for f in os.listdir(rpmdir)
        if f.endswith(".rpm")
        and not f.endswith((".src.rpm", ".nosrc.rpm"))
        and "-debuginfo-" not in f
        and "-debugsource-" not in f
    )
    if not shutil.which("rpm2cpio"):
        s.unknown.append((rpmdir, "no rpm2cpio to read the RPMs"))
        return s, 0
    for f in names:
        proc = subprocess.Popen(
            ["rpm2cpio", os.path.join(rpmdir, f)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        try:
            # a wrapper of its own: closing the cpio reader must not close the pipe
            for name, _, body in cpio_files(Prefixed(b"", proc.stdout)):
                where, h, tail, seen = f"{f}:{name}", hashlib.sha256(), b"", set()
                while True:
                    data = body.read(CHUNK)
                    if not data:
                        break
                    h.update(data)
                    window = tail + data
                    for fp, src in prints.items():
                        if src not in seen and fp in window:
                            seen.add(src)
                    tail = window[-overlap:] if overlap else b""
                if h.hexdigest() in prebuilt:
                    found.append((where, "is", prebuilt[h.hexdigest()]))
                else:
                    found += [(where, "embeds", src) for src in sorted(seen)]
        except DECODE as e:
            s.unknown.append((f, f"cannot read its payload: {e}"))
        finally:
            drain(proc.stdout)
            if proc.wait() != 0:
                s.unknown.append((f, "rpm2cpio failed"))
        rpms += 1
    return found, s.unknown, rpms


def files(d):
    return sorted(
        f
        for f in os.listdir(d)
        if not f.startswith(".")
        and os.path.isfile(os.path.join(d, f))
        and not os.path.islink(os.path.join(d, f))
    )


def main():
    ap = argparse.ArgumentParser(
        prog="source-binaries.py",
        description=__doc__.split("\n\n", 1)[0],
        epilog=__doc__.split("\n\n", 1)[1],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
    )
    ap.add_argument("dir", nargs="?", default=".", metavar="DIR")
    ap.add_argument("--rpms", metavar="RPMDIR")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--no-cache", action="store_true")
    a = ap.parse_args()
    d = a.dir
    for x in (d, a.rpms):
        if x is not None and not os.path.isdir(x):
            print(f"source-binaries.py: {x} is not a directory", file=sys.stderr)
            return 2
    excs, bad = exceptions(d)
    hits, unknown, members, scanned = [], [], 0, 0
    for name in files(d):
        s = cached_scan(os.path.join(d, name), name, not a.no_cache)
        hits += s.hits
        unknown += s.unknown
        members += s.members
        scanned += 1
    covered = collections.Counter()

    def exception(path):
        for e in excs:
            if fnmatch.fnmatchcase(path, e[0]):
                return e
        return None

    def excepted(path):
        e = exception(path)
        if e:
            covered[e[0]] += 1
        return e is not None

    # a payload file with a source binary's bytes ships it; only firmware may ship
    shipped = []
    if a.rpms is not None:
        prebuilt, prints = {}, {}
        for p, k, h, fp in hits:
            e = exception(p)
            if not (e and e[1] == "firmware"):
                prebuilt.setdefault(h, p)
                if fp:
                    prints.setdefault(bytes.fromhex(fp), p)
        shipped, bad_rpms, rpms = rpm_payloads(a.rpms, prebuilt, prints)
        unknown += bad_rpms
        if not rpms and not bad_rpms:
            unknown.append((a.rpms, "no binary RPM to read"))
    uncovered = [(p, k) for p, k, _, _ in hits if not excepted(p)]
    # an exception may name what cannot be read too (a format-test corpus)
    unknown = [(p, w) for p, w in unknown if not excepted(p)]
    print(f"source-binaries: {scanned} files, {members} archive members scanned")
    for line in bad:
        print(f"MALFORMED {line}")
    for where, how, src in shipped:
        print(f"SHIPPED {where} {how} the prebuilt {src}")
    shown = uncovered if a.all else uncovered[:SHOW]
    for path, k in shown:
        print(f"HIT {path}: {k}")
    if len(shown) < len(uncovered):
        kinds = collections.Counter(k for _, k in uncovered)
        dirs = collections.Counter("/".join(p.split("/")[:3]) for p, _ in uncovered)
        print(f"... first {len(shown)} of {len(uncovered)} (--all lists every one)")
        print("by kind: " + ", ".join(f"{k} {n}" for k, n in kinds.most_common()))
        print("by directory: " + ", ".join(f"{p} {n}" for p, n in dirs.most_common(8)))
    for path, why in unknown if a.all else unknown[:SHOW]:
        print(f"UNKNOWN {path}: {why}")
    if not a.all and len(unknown) > SHOW:
        print(f"... first {SHOW} of {len(unknown)} UNKNOWN (--all lists every one)")
    for glob, reason, why in excs:
        if covered[glob]:
            print(f"EXCEPTION {glob} ({reason}: {why}): {covered[glob]} hit(s)")
        else:
            print(f"note: exception {glob} matches nothing")
    boot = [f"{g}: {w}" for g, r, w in excs if r == "bootstrap" and covered[g]]
    tail = f" (bootstrap: {'; '.join(boot)})" if boot else ""
    if uncovered or bad or shipped:
        what = []
        if uncovered:
            what.append(
                f"{len(uncovered)} prebuilt binaries in the sources outside the exceptions"
            )
        if shipped:
            what.append(f"{len(shipped)} shipped in the RPMs")
        if bad:
            what.append(f"{len(bad)} exception line(s) that do not hold")
        print(f"FIX: {FIX}")
        print(
            f"VERDICT: RED — {', '.join(what)}{tail} "
            f'(references/specfile-guidelines.md "Spec file — general rules")'
        )
        return 3
    if unknown:
        print(
            f"VERDICT: UNKNOWN — {len(unknown)} file(s) could not be scanned completely{tail}"
        )
        return 2
    n = sum(covered.values())
    checked = f", {a.rpms} read for shipped ones" if a.rpms is not None else ""
    print(
        f"OK: no prebuilt binaries in the sources{f' outside the {n} excepted' if n else ''}"
        f"{checked}{tail}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
