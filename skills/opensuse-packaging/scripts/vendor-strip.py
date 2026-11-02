#!/usr/bin/env python3
"""Strip prebuilt files from a cargo vendor tarball and keep cargo accepting it.

  vendor-strip.py TARBALL GLOB... (-o OUTPUT | --dry-run)
  TARBALL     a cargo_vendor tarball: tar, or tar.zst/.xz/.gz/.bz2 (told by its
              magic, not its name); the output keeps that compression
  GLOB        a member path relative to the vendor root (the directory holding
              the crates, vendor/ for cargo_vendor), e.g. ring-*/pregenerated/*.o;
              * ? [..] stay inside one path segment, ** spans any number of them
  -o OUTPUT   write the result there; it may be TARBALL, which is then replaced
  --dry-run   list what would be removed and write nothing

Removes exactly the members the globs match, and each one's key from its
crate's .cargo-checksum.json "files" map (cargo refuses a vendored crate whose
listed files are missing). Every other member keeps its raw tar blocks, header
and metadata included, and an edited map keeps every byte but the dropped
pairs: cargo writes it compact, and so it stays. Members outside the vendor root
(.cargo/config.toml, Cargo.lock) are never matched. The same tarball and globs
give the same bytes.

Refused, with nothing written: a glob that matches no file, a crate's
Cargo.toml or .cargo-checksum.json (a crate goes whole, through cargo_vendor's
filter=true, or not at all), and a kept hard link or symlink to a removed
member. A tarball with anything but zeros after the last member tarfile can
read is unreadable, not cut short.

cargo_vendor writes the files back on every run: redo the strip after each
re-vendor, and keep the command in a spec comment above the vendor Source line.

Exit: 0 written (--dry-run: listed) · 1 refused, nothing written · 2 usage, or
the tarball cannot be read or the result cannot be written
"""

import argparse
import bz2
import collections
import contextlib
import fnmatch
import gzip
import json
import lzma
import os
import posixpath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zlib

BLOCK = 512
RECORD = 20 * BLOCK
CHECKSUM = ".cargo-checksum.json"
KEEP = ("Cargo.toml", CHECKSUM)
MAGIC = (
    (b"(\xb5/\xfd", "zstd"),
    (b"\xfd7zXZ\x00", "xz"),
    (b"\x1f\x8b", "gzip"),
    (b"BZh", "bzip2"),
)
OPEN = {"xz": lzma.open, "gzip": gzip.open, "bzip2": bz2.open, "tar": open}
READ_ERRORS = (OSError, EOFError, lzma.LZMAError, zlib.error, tarfile.TarError)


class Refused(Exception):
    pass


class Failed(Exception):
    pass


def compression(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(BLOCK)
    except OSError as e:
        raise Failed(f"cannot read {path}: {e}") from e
    for magic, name in MAGIC:
        if head.startswith(magic):
            if name == "zstd" and not shutil.which("zstd"):
                raise Failed(f"cannot read {path}: zstd is not installed")
            return name
    if head[257:262] == b"ustar":
        return "tar"
    raise Failed(
        f"cannot read {path}: not a tar archive, nor a zstd, xz, gzip or bzip2 one"
    )


@contextlib.contextmanager
def tar_stream(path, fmt):
    """The decompressed tar stream of path."""
    if fmt != "zstd":
        with OPEN[fmt](path, "rb") as fh:
            yield fh
        return
    proc = subprocess.Popen(
        ["zstd", "-dcq", "--", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    try:
        yield proc.stdout
        # a tar ends at its zero blocks: drain the rest, or zstd dies of SIGPIPE
        while proc.stdout.read(1 << 20):
            pass
    finally:
        proc.stdout.close()
        err = proc.stderr.read().decode(errors="replace").strip()
        proc.stderr.close()
        rc = proc.wait()
    if rc:
        raise Failed(f"cannot read {path}: zstd -dc: {err}")


@contextlib.contextmanager
def compressor(out, fmt):
    """A writer that compresses into the binary file out as fmt."""
    if fmt == "tar":
        yield out
    elif fmt == "gzip":
        with gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=0) as w:
            yield w
    elif fmt == "xz":
        with lzma.LZMAFile(out, "wb", preset=6) as w:
            yield w
    elif fmt == "bzip2":
        with bz2.BZ2File(out, "wb", compresslevel=9) as w:
            yield w
    else:
        # level 19 is what cargo_vendor writes; zstd's output does not depend
        # on its thread count, so it stays reproducible
        proc = subprocess.Popen(
            ["zstd", "-q", "-19", "-c"], stdin=subprocess.PIPE, stdout=out
        )
        try:
            yield proc.stdin
        finally:
            proc.stdin.close()
            rc = proc.wait()
        if rc:
            raise Failed(f"zstd exited {rc} while compressing")


class Counted:
    def __init__(self, w):
        self.w, self.n = w, 0

    def write(self, b):
        self.w.write(b)
        self.n += len(b)


def plain(name):
    while name.startswith("./"):
        name = name[2:]
    return name.rstrip("/")


def glob_match(pat, parts):
    if not pat:
        return not parts
    if pat[0] == "**":
        return any(glob_match(pat[1:], parts[i:]) for i in range(len(parts) + 1))
    return (
        bool(parts)
        and fnmatch.fnmatchcase(parts[0], pat[0])
        and glob_match(pat[1:], parts[1:])
    )


def plan(members, globs):
    """(vendor root, {member name: (crate, path in the crate)} to remove, crates).

    members: the TarInfo of every member, in archive order."""
    sums = [
        plain(m.name)
        for m in members
        if not m.isdir() and plain(m.name).rsplit("/", 1)[-1] == CHECKSUM
    ]
    if not sums:
        raise Failed(f"no {CHECKSUM} in it: not a cargo vendor tarball")
    roots = collections.Counter(
        s.rsplit("/", 2)[0] if s.count("/") >= 2 else "" for s in sums
    )
    root = roots.most_common(1)[0][0]
    prefix = f"{root}/" if root else ""
    files = []
    for m in members:
        p = plain(m.name)
        if m.isdir() or not p.startswith(prefix) or "/" not in p[len(prefix) :]:
            continue
        crate, rel = p[len(prefix) :].split("/", 1)
        files.append((m.name, crate, rel))
    refused, gone = [], {}
    for g in globs:
        pat = [s for s in g.split("/") if s]
        hit = [f for f in files if glob_match(pat, [f[1], *f[2].split("/")])]
        if not hit:
            hint = ""
            if prefix and g.startswith(prefix):
                hint = f" (globs are relative to {prefix})"
            elif any(
                glob_match(pat, parts[:k])
                for f in files
                for parts in [[f[1], *f[2].split("/")]]
                for k in range(1, len(parts))
            ):
                hint = f" (a directory: '{g.rstrip('/')}/**' takes what is under it)"
            refused.append(
                f"'{g}' matches nothing under {prefix or 'the archive root'}{hint}"
            )
        for n, crate, rel in hit:
            if rel in KEEP:
                refused.append(
                    f"'{g}' matches {crate}/{rel}: a crate's Cargo.toml and "
                    f"{CHECKSUM} go only with the whole crate (cargo_vendor filter=true)"
                )
            gone[n] = (crate, rel)
    # a kept link to a removed member would dangle: GNU tar 1.35 spins on such
    # a hard link at extract
    left = {plain(n) for n in gone}
    for m in members:
        if m.name in gone or not (m.islnk() or m.issym()):
            continue
        to = plain(m.linkname)
        if m.issym():
            to = posixpath.normpath(
                posixpath.join(posixpath.dirname(plain(m.name)), to)
            )
        if to in left:
            kind = "hard link" if m.islnk() else "symlink"
            refused.append(f"{m.name} is a {kind} to {to}, which goes: strip it too")
    if refused:
        raise Refused("\n".join(dict.fromkeys(refused)))
    return root, gone, len({f[1] for f in files})


def _ws(s, i):
    while i < len(s) and s[i] in " \t\r\n":
        i += 1
    return i


def _pairs(s, i, dec=json.JSONDecoder()):
    """[(key, start, end, value start)] of the JSON object opening at s[i]."""
    out = []
    i = _ws(s, i + 1)
    if s[i] == "}":
        return out
    while True:
        start = i
        key, i = dec.raw_decode(s, i)
        i = _ws(s, i)
        if s[i] != ":":
            raise ValueError(f"no ':' at offset {i}")
        vstart = i = _ws(s, i + 1)
        _, i = dec.raw_decode(s, i)
        out.append((key, start, i, vstart))
        i = _ws(s, i)
        if s[i] == "}":
            return out
        if s[i] != ",":
            raise ValueError(f"no ',' at offset {i}")
        i = _ws(s, i + 1)


def drop_keys(text, keys):
    """(text without those keys' pairs in its "files" map, the keys it had).

    Every other byte stays: the separator kept before a pair is the one that
    preceded it, so a compact map stays compact and a pretty one pretty."""
    json.loads(text)  # the whole document is JSON before it is read by hand
    top = _pairs(text, _ws(text, 0))
    files = next((p for p in top if p[0] == "files"), None)
    if files is None or text[files[3]] != "{":
        raise ValueError('no "files" map')
    pairs = _pairs(text, files[3])
    found = {p[0] for p in pairs if p[0] in keys}
    if not found:
        return text, found
    kept = [i for i, p in enumerate(pairs) if p[0] not in keys]
    body = []
    for n, i in enumerate(kept):
        if n:
            body.append(text[pairs[i - 1][2] : pairs[i][1]])
        body.append(text[pairs[i][1] : pairs[i][2]])
    return text[: pairs[0][1]] + "".join(body) + text[pairs[-1][2] :], found


def header_with_size(block, size):
    """The tar header block with a new size field and checksum, else as it was."""
    hb = bytearray(block)
    hb[124:136] = b"%011o\0" % size
    hb[148:156] = b" " * 8
    hb[148:155] = b"%06o\0" % sum(hb)
    hb[155] = block[155]
    return bytes(hb)


def copy(src, dst, start, length):
    src.seek(start)
    while length > 0:
        buf = src.read(min(length, 1 << 20))
        if not buf:
            raise Failed("the decompressed tar ended early")
        dst.write(buf)
        length -= len(buf)


def data_end(m):
    """Where member m's data blocks end, as tarfile reads them."""
    n = m.size if m.isreg() or m.type not in tarfile.SUPPORTED_TYPES else 0
    return m.offset_data + n + (-n % BLOCK)


def load(src, fmt, tmp):
    """The members of src, decompressed into tmp, and the tar's length.

    tarfile ends a listing quietly at a header it cannot parse: what follows
    the last member must be the end-of-archive zeros, or the rest is lost."""
    try:
        with tar_stream(src, fmt) as stream:
            shutil.copyfileobj(stream, tmp, 1 << 20)
        total = tmp.tell()
        tmp.seek(0)
        members = tarfile.open(fileobj=tmp, mode="r:").getmembers()
    except READ_ERRORS as e:
        raise Failed(f"cannot read {src}: {e}") from e
    end = data_end(members[-1]) if members else 0
    tmp.seek(end)
    while buf := tmp.read(1 << 20):
        rest = buf.lstrip(b"\0")
        if rest:
            at = end + len(buf) - len(rest)
            raise Failed(f"cannot read {src}: no tar header it can read at {at}")
        end += len(buf)
    sparse = [m.name for m in members if m.issparse()]
    if sparse:
        raise Failed(f"cannot rewrite {src}: {sparse[0]} is a sparse member")
    return members, total


def strip(src, fmt, out, globs):
    """Write out; returns (root, gone, crates, {crate: entries dropped}, notes)."""
    outdir = os.path.dirname(os.path.abspath(out))
    try:
        tmp = tempfile.TemporaryFile(dir=outdir)
    except OSError as e:
        raise Failed(f"cannot write {out}: {e}") from e
    with tmp:
        members, total = load(src, fmt, tmp)
        root, gone, ncrates = plan(members, globs)
        by_crate = collections.defaultdict(set)
        for crate, rel in gone.values():
            by_crate[crate].add(rel)
        prefix = f"{root}/" if root else ""
        dropped, notes = {}, []
        fd, tmp_out = tempfile.mkstemp(prefix=".vendor-strip.", dir=outdir)
        try:
            with os.fdopen(fd, "wb") as raw, compressor(raw, fmt) as cw:
                w, pos = Counted(cw), 0
                for m in members:
                    copy(tmp, w, pos, m.offset - pos)  # a global header, if any
                    pos = data_end(m)
                    if m.name in gone:
                        continue
                    p = plain(m.name)
                    crate = p[len(prefix) :].split("/", 1)[0]
                    if not (p == f"{prefix}{crate}/{CHECKSUM}" and crate in by_crate):
                        copy(tmp, w, m.offset, pos - m.offset)
                        continue
                    tmp.seek(m.offset_data)
                    try:
                        text, found = drop_keys(
                            tmp.read(m.size).decode("utf-8"), by_crate[crate]
                        )
                    except ValueError as e:  # bad UTF-8 or JSON included
                        raise Failed(f"cannot edit {m.name}: {e}") from e
                    dropped[crate] = len(found)
                    notes += [
                        f"note: {crate}/{r} is not listed in its {CHECKSUM}"
                        for r in sorted(by_crate[crate] - found)
                    ]
                    data = text.encode("utf-8")
                    copy(tmp, w, m.offset, m.offset_data - BLOCK - m.offset)
                    tmp.seek(m.offset_data - BLOCK)
                    w.write(header_with_size(tmp.read(BLOCK), len(data)))
                    w.write(data + b"\0" * (-len(data) % BLOCK))
                # the end-of-archive blocks, in whole records when the input was
                if total % RECORD == 0:
                    tail = 2 * BLOCK + (-(w.n + 2 * BLOCK) % RECORD)
                else:
                    tail = max(2 * BLOCK, total - pos)
                w.write(b"\0" * tail)
            os.chmod(tmp_out, os.stat(src).st_mode & 0o777)
            os.replace(tmp_out, out)
        except OSError as e:
            raise Failed(f"cannot write {out}: {e}") from e
        finally:
            with contextlib.suppress(OSError):
                os.unlink(tmp_out)
    notes += [
        f"note: {c} has no {CHECKSUM}: its files went, no map to edit"
        for c in sorted(set(by_crate) - set(dropped))
    ]
    return root, gone, ncrates, dropped, notes


def main():
    ap = argparse.ArgumentParser(
        prog="vendor-strip.py",
        description=__doc__.split("\n\n", 1)[0],
        epilog=__doc__.split("\n\n", 1)[1],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
    )
    ap.add_argument("tarball", metavar="TARBALL")
    ap.add_argument("globs", nargs="+", metavar="GLOB")
    ap.add_argument("-o", "--output", help="the stripped tarball (may be TARBALL)")
    ap.add_argument("--dry-run", action="store_true", help="list, write nothing")
    a = ap.parse_args()
    if bool(a.output) == a.dry_run:
        ap.error("give -o OUTPUT, or --dry-run")
    try:
        fmt = compression(a.tarball)
        if a.dry_run:
            try:  # beside the tarball, unlinked: not in a tmpfs /tmp
                tmp = tempfile.TemporaryFile(
                    dir=os.path.dirname(os.path.abspath(a.tarball))
                )
            except OSError:
                tmp = tempfile.TemporaryFile()
            with tmp:
                root, gone, ncrates = plan(load(a.tarball, fmt, tmp)[0], a.globs)
            dropped, notes = None, []
        else:
            root, gone, ncrates, dropped, notes = strip(
                a.tarball, fmt, a.output, a.globs
            )
    except Refused as e:
        for line in str(e).splitlines():
            print(f"REFUSED: {line}")
        print("nothing written")
        sys.exit(1)
    except Failed as e:
        print(f"vendor-strip: {e}", file=sys.stderr)
        sys.exit(2)
    print(
        f"vendor root: {root + '/' if root else 'the archive root'} ({ncrates} crates)"
    )
    per = collections.Counter(crate for crate, _ in gone.values())
    if dropped is None:
        for n in gone:
            print(f"would remove {n}")
        for crate in sorted(per):
            print(f"{crate}: {per[crate]} file(s)")
        print(
            f"DRY-RUN: {len(gone)} member(s) from {len(per)} crate(s) would be "
            "removed; nothing written"
        )
        return
    for crate in sorted(per):
        print(
            f"{crate}: {per[crate]} file(s) removed, "
            f"{dropped.get(crate, 0)} {CHECKSUM} entries dropped"
        )
    for note in notes:
        print(note)
    print(
        f"STRIPPED: {len(gone)} member(s) from {len(per)} crate(s) -> {a.output} "
        f"({fmt}; every other member byte-identical)"
    )


if __name__ == "__main__":
    # an uncaught exception would exit 1, which reads as a refusal
    try:
        main()
    except Exception:
        import traceback

        traceback.print_exc()
        print("vendor-strip: internal error, nothing written", file=sys.stderr)
        sys.exit(2)
