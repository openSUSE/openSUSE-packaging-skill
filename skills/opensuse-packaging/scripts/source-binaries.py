#!/usr/bin/env python3
"""Prebuilt binaries in a package's sources: executables, shared and static
libraries, native addons, wasm, Java bytecode and RPMs in every file of the
checkout. Archives (tar, gzip, xz, zstd, bzip2, zip, cpio/obscpio) are streamed
member by member, one level into nested archives (an npm .tgz inside a vendor
tarball), and nothing is extracted.

  source-binaries.py [DIR] [--all] [--no-cache]
  DIR         package checkout (default .)
  --all       list every hit (default: the first 20, then a count per kind and
              per directory)
  --no-cache  rescan archives scanned before (results are cached by sha256
              under $XDG_CACHE_HOME/opensuse-packaging/source-binaries)

"Only built at build time, never in an RPM" is no exception: the source package
still redistributes the binary, and the build runs code nobody built from
source. A hit is allowed only when a spec comment in DIR names it:

  # Source-Binary-Exception: <glob> -- bootstrap|firmware|test-data: <why>

<glob> (fnmatch: * spans /) matches the hit's path, FILE, FILE:MEMBER or
FILE:MEMBER!INNER. bootstrap: a toolchain that needs a previous build of itself
and has no packaged predecessor; firmware: no source exists; test-data: a
fixture the tests parse and never run or link
(references/specfile-guidelines.md "Spec file — general rules").

A file that cannot be read completely (a 7z or rar archive, a missing
decompressor, a broken archive, a git-lfs pointer whose object was not fetched)
is UNKNOWN, never clean.

Exit: 0 no prebuilt binary outside the named exceptions · 2 usage, or a file
that could not be read · 3 prebuilt binaries the spec does not except
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

VERSION = 1  # bump when detection changes, so cached results are rescanned
HEAD = 4096
NESTED_ZIP_CAP = 256 << 20
SHOW = 20
EXCEPTION = re.compile(r"^#\s*Source-Binary-Exception:(.*)$")
EXCEPTION_BODY = re.compile(
    r"^\s*(\S+)\s+--\s+(bootstrap|firmware|test-data):\s*(\S.*)$"
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
            self.hits.append((path, k))
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
                    self.hits.append((path, k + " (compressed)"))
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
                self.item(f"{path}{sep}{name}", read_head(body), body, depth, size)
            drain(body)
            stream.read((4 - size % 4) % 4)

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
                s.hits.append((name, k))
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
            s.hits = [(name + p[len(old) :], k) for p, k in d["hits"]]
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
            if b:
                out.append(b.groups())
            else:
                bad.append(f"{spec}:{n}: {line.strip()}")
    return out, bad


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
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--no-cache", action="store_true")
    a = ap.parse_args()
    d = a.dir
    if not os.path.isdir(d):
        print(f"source-binaries.py: {d} is not a directory", file=sys.stderr)
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

    def excepted(path):
        for glob, _, _ in excs:
            if fnmatch.fnmatchcase(path, glob):
                covered[glob] += 1
                return True
        return False

    uncovered = [(p, k) for p, k in hits if not excepted(p)]
    # an exception may name what cannot be read too (a format-test corpus)
    unknown = [(p, w) for p, w in unknown if not excepted(p)]
    print(f"source-binaries: {scanned} files, {members} archive members scanned")
    for line in bad:
        print(
            f"MALFORMED {line}: want '# Source-Binary-Exception: <glob> -- bootstrap|firmware|test-data: <why>'"
        )
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
    if uncovered or bad:
        print(
            f"VERDICT: RED — {len(uncovered)} prebuilt binaries in the sources outside the spec's "
            f"Source-Binary-Exception lines{', and malformed exception lines' if bad else ''} "
            f'(references/specfile-guidelines.md "Spec file — general rules")'
        )
        return 3
    if unknown:
        print(
            f"VERDICT: UNKNOWN — {len(unknown)} file(s) could not be scanned completely"
        )
        return 2
    n = sum(covered.values())
    print(
        f"OK: no prebuilt binaries in the sources{f' outside the {n} excepted' if n else ''}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
