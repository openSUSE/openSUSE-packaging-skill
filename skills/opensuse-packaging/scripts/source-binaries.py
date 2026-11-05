#!/usr/bin/env python3
"""Prebuilt binaries in a package's sources: executables, shared and static
libraries, native addons, Windows COFF objects, wasm, Java bytecode and RPMs in
every file of the checkout. Archives (tar, gzip, xz, zstd, bzip2, zip, cpio/obscpio) are streamed
member by member, one level into nested archives (an npm .tgz inside a vendor
tarball), and nothing is extracted.

  source-binaries.py [DIR] [--rpms RPMDIR] [--all] [--no-cache]
  DIR         package checkout (default .)
  --rpms RPMDIR  also read the built RPMs in RPMDIR and its subdirectories
              (osc getbinaries -d, or a build root's RPMS): a payload file
              that is, or carries verbatim, a prebuilt binary from the sources
              is SHIPPED, red whatever its exception says, firmware alone
              excepted; one that carries the code of a bootstrap's static
              library or object (not a copy of it) is an EMBEDS? line for the
              review: the package may have rebuilt the same sources with the
              same compiler
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

  # Source-Binary-Exception: <glob> -- <kind>: <why>

<kind> is bootstrap, firmware, test-data or other-platform. <glob> (fnmatch: *
spans /) matches the hit's path, FILE, FILE:MEMBER or FILE:MEMBER!INNER.
firmware: a blob no source exists for; test-data: a fixture the tests only
read, so the glob must lie under a test directory (tests/, testdata/,
fixtures/, corpus/, golden/, or an example's examples/ or samples/);
bootstrap: a compiler or toolchain that needs a previous build of itself, used
only during the build and never shipped, with a why of at least 8 words saying
what it builds and why no packaged predecessor can; a bootstrap why saying the
build does not use the file (never invoked, unused) is refused: that file is
removed from the sources, or declared other-platform. Every bootstrap
exception is named on the verdict line (references/specfile-guidelines.md
"Spec file — general rules"). other-platform: a file for another OS or CPU
that the build does not use, with a why of 3+ words naming the platform. It
holds only for a file whose bytes show the platform: a Windows PE image or
COFF object, an ar archive of COFF and import objects alone (a MinGW or MSVC
import library; symbol and name tables only first, holding no binary), a
Mach-O (a fat one's every slice), a wasm relocatable object (a module, which
node or wasmtime run, is refused), or an ELF whose e_machine is a CPU
openSUSE does not build (EI_OSABI proves nothing). Anything but zeros past
the format's own extent, or a zip end record, refuses it too. A Linux-target
ELF (x86, Arm, POWER, s390, RISC-V, LoongArch, BPF, GPU code), an EFI image,
a .NET assembly or a file that cannot be read is refused. Every line that
matches a hit is tried in turn, so a later test-data line still covers a
fixture an other-platform line does not. The shipped check finds a
binary copied into an RPM and one a bundler embeds
verbatim in its single executable (a fingerprint of 1-4 KiB from each hit's own
code: its ELF executable sections or archive members, bytes with real entropy
found once in the hit, never zero padding or a symbol table that unrelated
binaries share); one stored compressed or encoded stays the review's to find.

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
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import zipfile
import zlib

VERSION = 9  # bump when detection changes, so cached results are rescanned
HEAD = 4096
PRINT = 1024  # shortest hit whose bytes are searched for inside the payload
FP_CAP = 8 << 20  # how much of a hit its fingerprint is chosen from
MIN_CODE = (
    256  # a code range this short is a fingerprint whole (a small helper's .text)
)
CHUNK = 8 << 20
NESTED_ZIP_CAP = 256 << 20
SHOW = 20
LINKABLE = ("ar archive", "ELF object", "COFF object")  # what a build links, not runs
EXCEPTION = re.compile(r"^#\s*Source-Binary-Exception:(.*)$")
EXCEPTION_BODY = re.compile(
    r"^\s*(\S+)\s+--\s+(bootstrap|firmware|test-data|other-platform):\s*(\S.*)$"
)
# a test directory: tests/, testdata/, manual_tests/, AUTOTEST/, autotests/, fixtures/, fuzz/corpus/, golden-*/,
# examples/ and samples/ (an example's input data);
# a word, so latest/ or googletest/ are not one
TEST_PATH = re.compile(
    r"(?:^|[^a-z0-9])(?:unit)?(?:tests?|testing|testdata|test[-_]data|autotests?|fixtures?|corpus|golden|examples?|samples?)"
    r"(?:[^a-z0-9]|$)",
    re.I,
)
BOOTSTRAP_WORDS = 8
OTHER_WORDS = 3
PLATFORM = re.compile(
    r"\b(?:windows|win(?:32|64)|mingw\w*|msvc|macos|darwin|apple|ios|mach-o|wasm\w*|webassembly"
    r"|\w*bsd|solaris|illumos|aix|hp-ux|irix|sparc\w*|mips\w*|m68k|alpha|pa-risc|hppa|superh"
    r"|ia-?64|itanium)\b",
    re.I,
)
# e_machine of CPUs openSUSE does not build; any other may be one it builds, or
# code Linux loads (BPF, GPU)
ELF_CPU = {
    2: "SPARC",
    4: "m68k",
    8: "MIPS",
    10: "MIPS",
    15: "PA-RISC",
    18: "SPARC",
    42: "SuperH",
    43: "SPARC",
    50: "IA-64",
    0x9026: "Alpha",
}
# PE subsystems of Windows programs; EFI images (10-13) are what openSUSE builds and boots
PE_WINDOWS = (1, 2, 3, 9)
MACHO_THIN = (
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
)
FAT = (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")
TAIL = 22 + 0xFFFF  # a zip end record and the longest comment after it
# what a GNU or MSVC long-name table holds: names, "/\n" or NUL ends
NAME_TABLE = re.compile(rb"[ -~\n\0]*")
# a why that says the build does not use the file: the build is what never
# invokes it ("this Linux build never invokes it", "not required by the build",
# "only the Android build invokes it", "unused"). What a real bootstrap says of a
# packaged predecessor or the installed package ("Factory's go does not run it",
# "not needed afterwards", "not used by anything the RPM installs") is no denial.
_BUILD = r"(?:(?:this|the|our|its)\s+)?(?:[\w'-]+\s+){0,4}?build(?:s|ing)?"
_VERB = r"(?:invok|use|using|run|ran|execut|call|load|need|requir|depend)\w*"
# not "cannot": "the build cannot use Factory's ghc" is a bootstrap's reason
_NEG = r"(?:never|not|doesn't|didn't|won't|has\s+no)"
UNUSED = re.compile(
    "|".join(
        (
            rf"\b{_BUILD}\s+(?:\w+\s+)?{_NEG}\s+(?:\w+\s+)?{_VERB}",
            rf"\b(?:not|never)\s+(?:\w+\s+){{0,2}}?{_VERB}\s+(?:by|in|during|at|for|when|while)\s+"
            rf"{_BUILD}\b",
            rf"\bonly\s+(?:(?:the|its)\s+)?(?:[\w'-]+\s+){{1,4}}?build(?:s|ing)?\s+{_VERB}",
            r"\bunused\b",
        )
    ),
    re.I,
)
# a denial about what follows the build or what ships is a bootstrap's own claim
NOT_DENIAL = re.compile(
    r"[^.;]{0,40}?\b(?:afterwards|after\s+the\s+build|outside\s+the\s+build|at\s+run[\s-]?time"
    r"|once\s+installed|by\s+the\s+(?:installed|shipped)\b)",
    re.I,
)


def denial(why):
    """The first phrase of why that says the build does not use the file, or None."""
    for m in UNUSED.finditer(why):
        if not NOT_DENIAL.match(why, m.end()):
            return m.group(0)
    return None


FIX = (
    "a binary the package ships, embeds, loads or links is never an exception: build "
    "it from source or unbundle it (BuildRequires the system package); a file for another "
    "OS or CPU that the build does not use is declared other-platform, not stripped"
)
LFS = b"version https://git-lfs.github.com/spec/v1"
COMPRESSED = {  # magic: (external tool, python module)
    b"\x1f\x8b": ("gzip", "gzip"),
    b"\xfd7zXZ\x00": ("xz", "lzma"),
    b"(\xb5/\xfd": ("zstd", "zstd"),
    b"BZh": ("bzip2", "bz2"),
}
UNSUPPORTED = {b"7z\xbc\xaf\x27\x1c": "7z archive", b"Rar!\x1a\x07": "rar archive"}
# i386, x86-64, arm64, ARMv7 Thumb-2, arm64ec: the machines a Windows object targets
COFF_MACHINES = {0x014C, 0x8664, 0xAA64, 0x01C4, 0xA641}
# ANON_OBJECT_HEADER_BIGOBJ's ClassID {D1BAA1C7-BAEE-4BA9-AF20-FAF66AA4DCB8}
BIGOBJ_CLASS = bytes.fromhex("c7a1bad1eebaa94baf20faf66aa4dcb8")
# what a corrupt or exotic archive raises while it is read (zipfile: NotImplementedError)
DECODE = (
    tarfile.TarError,
    zipfile.BadZipFile,
    NotImplementedError,
    zlib.error,
    lzma.LZMAError,
    OSError,
    EOFError,
    ValueError,
)


def kind(head, name):
    """What prebuilt binary head (a file's first bytes) is, or None."""
    if head[:4] == b"\x7fELF":
        end = "big" if head[5:6] == b"\x02" else "little"
        # a relocatable object (ET_REL) is what a static library holds
        return "ELF object" if int.from_bytes(head[16:18], end) == 1 else "ELF"
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
    if coff(head):
        return "COFF object"
    return None


def coff(head):
    """Whether head starts a Windows COFF object file. COFF has no magic, so it
    takes a known machine, a sane section count, no optional header (an image
    has one, and is a PE behind MZ anyway) and section names that are names:
    ring's pregenerated *.o and aws-lc-sys's prebuilt *.obj are this."""
    if len(head) < 60:
        return False
    machine, nsec = struct.unpack_from("<HH", head, 0)
    if machine == 0 and nsec == 0xFFFF:
        # an anonymous object header: the bigobj form says what it is by its ClassID
        version, machine = struct.unpack_from("<HH", head, 4)
        return version >= 2 and machine in COFF_MACHINES and head[12:28] == BIGOBJ_CLASS
    if machine not in COFF_MACHINES or not 1 <= nsec <= 96:
        return False
    symptr, nsym, opt = struct.unpack_from("<IIH", head, 8)
    if opt != 0 or (nsym and symptr < 20 + 40 * nsec):
        return False
    names = [
        head[20 + 40 * i : 28 + 40 * i]
        for i in range(min(nsec, (len(head) - 20) // 40))
    ]
    return all(section_name(n) for n in names)


SECTION_NAME = re.compile(rb"[./][!-~]*\0*")


def section_name(raw):
    """A COFF section name: .text, .debug$S, or /4 for a long one, NUL-padded."""
    return SECTION_NAME.fullmatch(raw) is not None


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


class Tee(io.RawIOBase):
    """head, then the rest of stream, hashed: its first FP_CAP bytes kept in buf
    and its last TAIL in tail, its length in n, and in end the length up to its
    last nonzero byte."""

    def __init__(self, head, stream):
        self.src, self.h = Prefixed(head, stream), hashlib.sha256()
        self.buf, self.tail, self.n, self.end = bytearray(), b"", 0, 0

    def readable(self):
        return True

    def readinto(self, b):
        n = self.src.readinto(b)
        data = memoryview(b)[:n]
        self.h.update(data)
        if len(self.buf) < FP_CAP:
            self.buf += data[: FP_CAP - len(self.buf)]
        chunk = data.tobytes()
        kept = len(chunk.rstrip(b"\0"))
        if kept:
            self.end = self.n + kept
        self.n += n
        self.tail = (self.tail + chunk)[-TAIL:]
        return n


def digest(head, stream, k):
    """(sha256, fingerprint, platform) of head and the rest of stream, read to
    its end. The fingerprint is up to 4 KiB of the hit's own code: what a
    bundler that embeds the file in its single executable still carries
    verbatim, and what no unrelated binary shares (fingerprint()). The platform
    is the other one the file is for (platform()), or ""."""
    t = Tee(head, stream)
    r = io.BufferedReader(t, 1 << 20)
    # an ar archive and a fat Mach-O are judged member by member as they stream
    whole = k.startswith("ar archive") or (k.startswith("Mach-O") and head[:4] in FAT)
    plat = (
        (ar_platform if k.startswith("ar archive") else fat_platform)(r)
        if whole
        else None
    )
    drain(r)
    buf = bytes(t.buf)
    if not whole:
        plat = platform(buf, k)
        # nothing but zeros past what the format itself accounts for: a zip or
        # a Linux binary appended to a Windows or Apple header is no artifact of one
        ext = extent(buf, k) if plat else None
        plat = plat if ext is not None and t.end <= ext else None
    if plat and zip_end(t.tail):
        plat = None
    return t.h.hexdigest(), fingerprint(buf, k).hex(), plat or ""


def skip(r, n, zero=False):
    """Read n bytes of r (to its end when n is None); whether they were all
    there and, with zero, all zero."""
    while n is None or n > 0:
        data = r.read(1 << 20 if n is None else min(n, 1 << 20))
        if not data:
            return n is None
        if zero and data.strip(b"\0"):
            return False
        if n is not None:
            n -= len(data)
    return True


def zip_end(tail):
    """Whether tail, a file's last bytes, holds a zip end record that unzip or
    zipfile would read a zip by, whatever precedes it: its central directory
    (or zip64 locator) right before it, or, when that lies past tail, the
    record ending the file."""
    i = tail.rfind(b"PK\5\6")
    while i >= 0:
        if i + 22 <= len(tail):
            size, note = struct.unpack_from("<I4xH", tail, i + 12)
            if (
                (i >= 20 and tail[i - 20 : i - 16] == b"PK\6\7")
                or (0 < size <= i and tail[i - size : i - size + 4] == b"PK\1\2")
                or (size > i and i + 22 + note == len(tail))
            ):
                return True
        i = tail.rfind(b"PK\5\6", 0, i)
    return False


def ar_platform(r):
    """The other platform every member of the ar archive stream r is for, or
    None: a member that may be for one openSUSE builds, a thin archive (its
    members lie elsewhere), no member, or a header that does not parse. Only
    the archive's leading members may be its symbol and name tables, and only
    when they hold no binary."""
    if r.read(8) != b"!<arch>\n":
        return None
    found, tables = set(), 0
    while True:
        hdr = r.read(60)
        if not hdr:
            return "/".join(sorted(found)) or None
        try:
            size = int(hdr[48:58])
        except ValueError:
            return None
        if len(hdr) < 60 or hdr[58:60] != b"`\n" or size < 0:
            return None
        name = hdr[:16].decode("latin-1").rstrip()
        # BSD ar (macOS): "#1/N" puts the N-byte name first in the member's data
        lead = int(name[3:]) if name.startswith("#1/") and name[3:].isdigit() else 0
        if lead > min(size, HEAD):
            return None
        body = r.read(min(size, lead + HEAD))
        if len(body) < min(size, lead + HEAD):
            return None
        if lead:
            name, body = body[:lead].rstrip(b"\0").decode("latin-1"), body[lead:]
        if (
            name in AR_TABLES
            and not found
            and tables < 4
            and kind(body, "") is None
            and (name not in ("//", "ARFILENAMES/") or NAME_TABLE.fullmatch(body))
        ):
            tables += 1
        else:
            p = member_platform(body)
            if p is None:
                return None
            found.add(p)
        if not skip(r, size - lead - len(body)):
            return None
        r.read(size & 1)  # the pad byte, which the last member may lack


def fat_platform(r):
    """Apple when every slice of the fat Mach-O stream r lies inside it and
    starts as a thin Mach-O, and the bytes around them are zeros; else None."""
    hdr = r.read(8)
    entry = 32 if hdr[:4] == b"\xca\xfe\xba\xbf" else 20
    n = int.from_bytes(hdr[4:8], "big")
    table = r.read(n * entry) if 1 <= n < 45 else b""
    if len(table) < max(n, 1) * entry:
        return None
    wide = entry == 32
    slices = sorted(
        struct.unpack_from(">QQ" if wide else ">II", table, i * entry + 8)
        for i in range(n)
    )
    pos = 8 + n * entry
    for off, size in slices:
        if off < pos or size < 4 or not skip(r, off - pos, zero=True):
            return None
        if r.read(4) not in MACHO_THIN or not skip(r, size - 4):
            return None
        pos = off + size
    return "Apple" if skip(r, None, zero=True) else None


def platform(b, k):
    """The other OS or CPU the prebuilt b of kind k is for, read from its bytes;
    None when it may be for one openSUSE builds, or cannot be told (an ar
    archive or a fat Mach-O: ar_platform(), fat_platform())."""
    if k.startswith("COFF object"):
        return "Windows"
    if k.startswith("Mach-O"):
        return "Apple" if b[:4] in MACHO_THIN else None
    if k.startswith("wasm"):
        return wasm_platform(b)
    if k.startswith("PE"):
        return pe_platform(b)
    if k.startswith("ELF"):
        return elf_platform(b)
    return None


def extent(b, k):
    """How many bytes of the file b starts the format accounts for (headers,
    sections, symbol and string tables, signatures), or None when the fields
    that say so lie past b or do not parse."""
    try:
        if k.startswith("COFF object"):
            return coff_extent(b)
        if k.startswith("PE"):
            return pe_extent(b)
        if k.startswith("Mach-O"):
            return macho_extent(b)
        if k.startswith("ELF"):
            return elf_extent(b)
        if k.startswith("wasm"):
            return len(b)  # wasm_platform() parsed its sections to the end of b
    except struct.error:
        return None
    return None


def sections_extent(b, at, nsec, symptr, nsym, symsize, ext):
    """extent() of a COFF object or PE image whose nsec section headers start at
    at, past ext: their raw data, relocations and line numbers, then the
    symbol table and the string table after it."""
    if at + 40 * nsec > len(b):
        return None
    for i in range(nsec):
        raw, ptr, rel, line, nrel, nline, flags = struct.unpack_from(
            "<IIIIHHI", b, at + 40 * i + 16
        )
        if flags & 0x01000000 and nrel == 0xFFFF:  # IMAGE_SCN_LNK_NRELOC_OVFL
            nrel = (
                int.from_bytes(b[rel : rel + 4], "little") if rel + 4 <= len(b) else 0
            )
            if not nrel:
                return None
        ext = max(ext, ptr + raw if ptr else 0, rel + 10 * nrel, line + 6 * nline)
    if symptr:
        strings = symptr + symsize * nsym
        size = b[strings : strings + 4]
        ext = max(
            ext,
            strings + max(4, int.from_bytes(size, "little"))
            if len(size) == 4
            else strings,
        )
    return ext


def coff_extent(b):
    machine, nsec = struct.unpack_from("<HH", b, 0)
    if machine == 0 and nsec == 0xFFFF:  # bigobj
        nsec, symptr, nsym = struct.unpack_from("<III", b, 44)
        return sections_extent(b, 56, nsec, symptr, nsym, 20, 56 + 40 * nsec)
    symptr, nsym, opt = struct.unpack_from("<IIH", b, 8)
    return sections_extent(b, 20 + opt, nsec, symptr, nsym, 18, 20 + opt + 40 * nsec)


def pe_extent(b):
    off = int.from_bytes(b[60:64], "little")
    nsec, _, symptr, nsym, opt_size = struct.unpack_from("<HIIIH", b, off + 6)
    opt = off + 24
    dirs = opt + (96 if int.from_bytes(b[opt : opt + 2], "little") == 0x10B else 112)
    ext = max(
        int.from_bytes(b[opt + 60 : opt + 64], "little"), opt + opt_size + 40 * nsec
    )
    if int.from_bytes(b[dirs - 4 : dirs], "little") > 4:
        # the certificate table's address is a file offset: a signature
        cert, size = struct.unpack_from("<II", b, dirs + 32)
        ext = max(ext, cert + size if cert else 0)
    return sections_extent(b, opt + opt_size, nsec, symptr, nsym, 18, ext)


# load commands with (offset, size) pairs of file data, and where the pairs sit
MACHO_DATA = {
    0x2: None,  # LC_SYMTAB: its own layout
    0xB: None,  # LC_DYSYMTAB: its own layout
    0x22: (8, 5),  # LC_DYLD_INFO: rebase, bind, weak, lazy, export
    0x80000022: (8, 5),
    0x1D: (8, 1),  # LC_CODE_SIGNATURE and the other linkedit_data_command ones
    0x1E: (8, 1),
    0x26: (8, 1),
    0x29: (8, 1),
    0x2B: (8, 1),
    0x2E: (8, 1),
    0x36: (8, 1),
    0x80000033: (8, 1),
    0x80000034: (8, 1),
}


def macho_extent(b):
    e = "<" if b[:4] in (b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe") else ">"
    wide = b[:4] in (b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe")
    ncmds, cmds = struct.unpack_from(e + "II", b, 16)
    at = 32 if wide else 28
    if at + cmds > len(b) or ncmds > cmds // 8:
        return None
    ext, o = at + cmds, at
    for _ in range(ncmds):
        cmd, size = struct.unpack_from(e + "II", b, o)
        if size < 8 or o + size > at + cmds:
            return None
        if cmd in (0x1, 0x19):  # LC_SEGMENT, LC_SEGMENT_64 and their sections
            fileoff, filesize = struct.unpack_from(
                e + ("QQ" if wide else "II"), b, o + (40 if wide else 32)
            )
            nsects = int.from_bytes(
                b[o + (64 if wide else 48) : o + (68 if wide else 52)],
                "little" if e == "<" else "big",
            )
            ext = max(ext, fileoff + filesize)
            for i in range(nsects):
                sec = o + (72 if wide else 56) + i * (80 if wide else 68)
                if wide:
                    sz, off, _, rel, nrel, flags = struct.unpack_from(
                        e + "QIIIII", b, sec + 40
                    )
                else:
                    sz, off, _, rel, nrel, flags = struct.unpack_from(
                        e + "IIIIII", b, sec + 36
                    )
                if flags & 0xFF not in (0x1, 0xC, 0x12):  # zerofill holds no file data
                    ext = max(ext, off + sz if off else 0)
                ext = max(ext, rel + 8 * nrel)
        elif cmd == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack_from(e + "IIII", b, o + 8)
            ext = max(ext, symoff + nsyms * (16 if wide else 12), stroff + strsize)
        elif cmd == 0xB:
            f = struct.unpack_from(e + "18I", b, o + 8)
            entries = (
                (6, 8),
                (8, 56 if wide else 52),
                (10, 4),
                (12, 4),
                (14, 8),
                (16, 8),
            )
            ext = max([ext] + [f[i] + f[i + 1] * n for i, n in entries])
        elif cmd == 0x31:  # LC_NOTE
            off, sz = struct.unpack_from(e + "QQ", b, o + 24)
            ext = max(ext, off + sz)
        elif cmd in MACHO_DATA:
            first, pairs = MACHO_DATA[cmd]
            f = struct.unpack_from(e + "%dI" % (2 * pairs), b, o + first)
            ext = max([ext] + [f[i] + f[i + 1] for i in range(0, 2 * pairs, 2)])
        o += size
    return ext


def elf_extent(b):
    e = "<" if b[5] == 1 else ">"
    if b[4] == 2:
        phoff, shoff = struct.unpack_from(e + "QQ", b, 0x20)
        ehsize, phsz, phn, shsz, shn = struct.unpack_from(e + "HHHHH", b, 0x34)
    else:
        phoff, shoff = struct.unpack_from(e + "II", b, 0x1C)
        ehsize, phsz, phn, shsz, shn = struct.unpack_from(e + "HHHHH", b, 0x28)
    ext = max(ehsize, 64 if b[4] == 2 else 52, phoff + phsz * phn, shoff + shsz * shn)
    if phoff + phsz * phn > len(b) or shoff + shsz * shn > len(b):
        return None
    for i in range(phn):
        o = phoff + i * phsz
        off, filesz = (
            struct.unpack_from(e + "8xQ16xQ", b, o)
            if b[4] == 2
            else struct.unpack_from(e + "4xI8xI", b, o)
        )
        ext = max(ext, off + filesz)
    for i in range(shn):
        o = shoff + i * shsz
        if b[4] == 2:
            typ, off, size = struct.unpack_from(e + "4xI16xQQ", b, o)
        else:
            typ, off, size = struct.unpack_from(e + "4xI8xII", b, o)
        ext = max(ext, off + size if typ != 8 else 0)  # SHT_NOBITS holds no file data
    return ext


def leb(b, i):
    """The unsigned LEB128 number at b[i] and the offset past it; None, i if none."""
    n = 0
    for j in range(i, min(i + 10, len(b))):
        n |= (b[j] & 0x7F) << 7 * (j - i)
        if b[j] < 0x80:
            return n, j + 1
    return None, i


def wasm_platform(b):
    """wasm for a relocatable wasm object: its sections parse to the end, one
    is the "linking" custom section wasm-ld reads, and it imports
    env.__linear_memory as every object does; None for a module, which node or
    wasmtime run, or anything else."""
    if b[4:8] != b"\1\0\0\0":
        return None
    pos, linking, memory = 8, False, False
    while pos < len(b):
        size, start = leb(b, pos + 1)
        if b[pos] > 13 or size is None or start + size > len(b):
            return None
        if b[pos] == 0:
            n, name = leb(b, start)
            linking |= n is not None and b[name : name + n] == b"linking"
        elif b[pos] == 2:
            memory = linear_memory(b[start : start + size])
        pos = start + size
    return "wasm" if linking and memory else None


def linear_memory(s):
    """Whether the wasm import section s imports env.__linear_memory as a memory."""
    count, i = leb(s, 0)
    for _ in range(count or 0):
        names = []
        for _ in (0, 1):
            n, i = leb(s, i)
            if n is None:
                return False
            names.append(s[i : i + n])
            i += n
        if i >= len(s):
            return False
        what, i = s[i], i + 1
        if what == 2 and names == [b"env", b"__linear_memory"]:
            return True
        # step over the import's type: a function, table, memory, global or tag
        if what in (0, 4):
            i = leb(s, i + (what == 4))[1]
        elif what in (1, 2):
            i += what == 1
            flags = s[i] if i < len(s) else 0
            i = leb(s, i + 1)[1]
            if flags & 1:
                i = leb(s, i)[1]
        elif what == 3:
            i += 2
        else:
            return False
    return False


def pe_platform(b):
    """Windows for a Windows program or library; None for an EFI image (openSUSE
    builds and boots those), a .NET assembly (mono and dotnet run it on Linux)
    or a header that does not parse."""
    off = int.from_bytes(b[60:64], "little") if len(b) >= 64 else -1
    if off < 0 or b[off : off + 4] != b"PE\0\0":
        return None
    opt = off + 24
    dirs = {0x10B: 96, 0x20B: 112}.get(int.from_bytes(b[opt : opt + 2], "little"))
    if dirs is None or len(b) < opt + dirs:
        return None
    if int.from_bytes(b[opt + 68 : opt + 70], "little") not in PE_WINDOWS:
        return None
    count = int.from_bytes(b[opt + dirs - 4 : opt + dirs], "little")
    clr = b[opt + dirs + 112 : opt + dirs + 120] if count > 14 else bytes(8)
    return "Windows" if len(clr) == 8 and not any(clr) else None


def elf_platform(b):
    """The CPU its e_machine names when openSUSE does not build that CPU; None
    for every other ELF. EI_OSABI proves nothing: one byte, and Linux runs and
    links an x86-64 ELF that says FreeBSD."""
    if len(b) < 20 or b[5] not in (1, 2):
        return None
    return ELF_CPU.get(int.from_bytes(b[18:20], "little" if b[5] == 1 else "big"))


def member_platform(m):
    """platform() of an ar member's first bytes: a COFF short import object (an
    MSVC import library holds one per function) is Windows."""
    if m[:4] == b"\0\0\xff\xff" and len(m) >= 8 and m[4:6] == b"\0\0":
        return "Windows" if int.from_bytes(m[6:8], "little") in COFF_MACHINES else None
    k = kind(m, "")
    return platform(m, k) if k and not k.startswith("ar archive") else None


def lively(w):
    """Whether window w carries information: 5+ bits per byte and no byte over a
    quarter of it. Zero padding (lld's mips-gp-disp.so test input) and the
    symbol names of string tables fall short; machine code does not."""
    counts = [c for c in (w.count(i) for i in range(256)) if c]
    n = len(w)
    if max(counts) * 4 > n:
        return False
    return -sum(c / n * math.log2(c / n) for c in counts) >= 5.0


def elf_code(b, base=0):
    """[(start, end)] of the executable sections of the ELF image b (its PF_X
    segments when the section table lies past b), offset by base."""
    if len(b) < 64 or b[:4] != b"\x7fELF" or b[4] not in (1, 2) or b[5] not in (1, 2):
        return []
    e = "<" if b[5] == 1 else ">"
    wide = b[4] == 2
    try:
        if wide:
            phoff, shoff = struct.unpack_from(e + "QQ", b, 0x20)
            phsz, phn, shsz, shn = struct.unpack_from(e + "HHHH", b, 0x36)
        else:
            phoff, shoff = struct.unpack_from(e + "II", b, 0x1C)
            phsz, phn, shsz, shn = struct.unpack_from(e + "HHHH", b, 0x2A)
        out = []
        if shn and shsz in (40, 64) and shn <= 4096 and shoff + shn * shsz <= len(b):
            for i in range(shn):
                o = shoff + i * shsz
                if wide:
                    typ, flags, off, size = struct.unpack_from(e + "IQ8xQQ", b, o + 4)
                else:
                    typ, flags, off, size = struct.unpack_from(e + "II4xII", b, o + 4)
                if flags & 0x4 and typ != 8 and size:  # SHF_EXECINSTR, not SHT_NOBITS
                    out.append((base + off, base + off + size))
            return out
        if phn and phsz in (32, 56) and phn <= 4096 and phoff + phn * phsz <= len(b):
            for i in range(phn):
                o = phoff + i * phsz
                if wide:
                    typ, flags, off, _, _, size = struct.unpack_from(e + "IIQQQQ", b, o)
                else:
                    typ, off, _, _, size, _, flags = struct.unpack_from(
                        e + "IIIIIII", b, o
                    )
                if typ == 1 and flags & 1 and size:  # PT_LOAD, PF_X
                    out.append((base + off, base + off + size))
        return out
    except struct.error:
        return []


AR_TABLES = (
    "/",
    "//",
    "/SYM64/",
    "/<ECSYMBOLS>/",
    "__.SYMDEF",
    "__.SYMDEF SORTED",
    "ARFILENAMES/",
)


def ar_members(b):
    """(start, size) of each member of the ar archive b but its symbol and name
    tables, which archives of the same objects for another arch share."""
    off = 8
    while off + 60 <= len(b):
        name = b[off : off + 16].decode("latin-1").rstrip()
        try:
            size = int(b[off + 48 : off + 58])
        except ValueError:
            return
        if name not in AR_TABLES:
            yield off + 60, size
        off += 60 + size + (size & 1)


def merged(ranges):
    """ranges sorted, the ones a section alignment apart joined (.plt and .text)."""
    out = []
    for lo, hi in sorted(ranges):
        if out and lo - out[-1][1] <= 64:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out


def window(buf, ranges, least):
    """The first lively() window of up to 4 KiB in ranges, at least least bytes
    long, that is found once in buf; b"" if none."""
    for lo, hi in ranges:
        hi = min(hi, len(buf))
        n = min(HEAD, hi - lo)
        if n < least:
            continue
        offs = list(range(lo, hi - n + 1, n))[:64]
        for off in offs + [hi - n]:
            w = buf[off : off + n]
            if lively(w) and buf.find(w) == off and buf.find(w, off + 1) == -1:
                return w
    return b""


def fingerprint(buf, k):
    """Up to 4 KiB of buf that is lively() and found once in it, from the hit's
    own code: an ELF's executable sections (a small helper's whole .text, 256 B
    or more), an ar archive's members (their code when they are ELF objects),
    and else, or when none of those qualifies, past the first 4 KiB of headers.
    b"" when no window qualifies: the sha256 still finds a verbatim copy."""
    code, data = [], []
    if k.startswith("ELF"):
        code = elf_code(buf)
    elif k.startswith("ar archive"):
        for start, size in ar_members(buf):
            r = elf_code(buf[start : start + size], start)
            (code if r else data).extend(r or [(start, start + size)])
    rest = [(HEAD if len(buf) >= 2 * HEAD else 0, len(buf))]
    return (
        window(buf, merged(code), MIN_CODE)
        or window(buf, data, PRINT)
        or window(buf, rest, PRINT)
    )


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
            self.hits.append((path, k, *digest(head, stream, k)))
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
                    self.hits.append(
                        (path, k + " (compressed)", *digest(ihead, inner, k))
                    )
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
        if nsize > HEAD:  # a header's length is never read unbounded
            raise ValueError(f"a cpio name of {nsize} bytes")
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
                s.hits.append((name, k, *digest(head, fh, k)))
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
            s.hits = [(name + p[len(old) :], *rest) for p, *rest in d["hits"]]
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
    """[(glob, reason, why, where)] from every spec in d, and malformed lines."""
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
                    f"{where}: want '<glob> -- bootstrap|firmware|test-data|other-platform: <why>'"
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
            elif reason == "bootstrap" and denial(why):
                bad.append(
                    f"{where}: a bootstrap is a toolchain the build runs, and this why says it "
                    f"does not ('{denial(why)}'): a file the build does not use "
                    "is removed from the sources (the tarball repack or the _service exclude), "
                    "or declared other-platform when it is for another OS or CPU"
                )
            elif reason == "other-platform" and (
                len(why.split()) < OTHER_WORDS or not PLATFORM.search(why)
            ):
                bad.append(
                    f"{where}: other-platform needs a why of {OTHER_WORDS}+ words naming the "
                    "platform the file is for (Windows, macOS, wasm, FreeBSD, ...)"
                )
            else:
                out.append((glob, reason, why, where))
    return out, bad


def rpm_payloads(rpmdir, prebuilt, prints):
    """Every payload file of the binary RPMs in rpmdir against the source hits:
    ([(payload path, how, source path)], unknown, rpms). prebuilt maps a hit's
    sha256 to its path, prints a fingerprint's bytes to the hit's path."""
    s, rpms, found = Scan(), 0, []
    overlap = max((len(f) for f in prints), default=1) - 1
    names = sorted(
        os.path.relpath(os.path.join(root, f), rpmdir)
        for root, _, fs in os.walk(rpmdir)
        for f in fs
        if f.endswith(".rpm")
        and not f.endswith((".src.rpm", ".nosrc.rpm"))
        and "-debuginfo-" not in f
        and "-debugsource-" not in f
    )
    if not shutil.which("rpm2cpio"):
        s.unknown.append((rpmdir, "no rpm2cpio to read the RPMs"))
        return [], s.unknown, 0
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
    covered, matched = collections.Counter(), set()
    # an other-platform glob: the platforms it covered; its line: what it does not hold for
    plats, refused = collections.defaultdict(set), collections.defaultdict(list)

    def exception(path, plat):
        """The first line matching path whose kind holds for it, and the
        other-platform lines before it that matched but do not."""
        passed = []
        for e in excs:
            if fnmatch.fnmatchcase(path, e[0]):
                matched.add(e[0])
                if e[1] != "other-platform" or plat:
                    return e, passed
                passed.append(e)
        return None, passed

    def excepted(path, what, plat):
        e, passed = exception(path, plat)
        if e:
            covered[e[0]] += 1
            if plat and e[1] == "other-platform":
                plats[e[0]].add(plat)
        else:
            for x in passed:
                refused[x].append(f"{path} ({what})")
        return e is not None

    # a payload file with a source binary's bytes ships it; only firmware may ship
    shipped, review = [], []
    if a.rpms is not None:
        prebuilt, prints = {}, {}
        for p, k, h, fp, pl in hits:
            e = exception(p, pl)[0]
            if not (e and e[1] == "firmware"):
                prebuilt.setdefault(h, p)
                if fp:
                    prints.setdefault(bytes.fromhex(fp), p)
        shipped, bad_rpms, rpms = rpm_payloads(a.rpms, prebuilt, prints)
        # A bootstrap's static library or object whose code a shipped file
        # carries may be the package's own build of the same sources by the same
        # compiler (swift-lang's compiler-rt and its seed's): the review decides.
        # A copy stays SHIPPED, and so does any other library's code.
        static = {
            p
            for p, k, _, _, pl in hits
            if k.startswith(LINKABLE)
            and (exception(p, pl)[0] or ("", ""))[1] == "bootstrap"
        }
        review = [x for x in shipped if x[1] == "embeds" and x[2] in static]
        shipped = [x for x in shipped if x not in review]
        unknown += bad_rpms
        if not rpms and not bad_rpms:
            unknown.append((a.rpms, "no binary RPM to read"))
    uncovered = [(p, k) for p, k, _, _, pl in hits if not excepted(p, k, pl)]
    # an exception may name what cannot be read too (a format-test corpus)
    unknown = [(p, w) for p, w in unknown if not excepted(p, "not readable", "")]
    for e, what in refused.items():
        more = f" and {len(what) - 1} more" if len(what) > 1 else ""
        bad.append(
            f"{e[3]}: other-platform holds only for a file whose bytes show another OS or "
            f"CPU, not {what[0]}{more}: build it from source or unbundle it, or except "
            "it as bootstrap or test-data when it is one"
        )
    print(f"source-binaries: {scanned} files, {members} archive members scanned")
    for line in bad:
        print(f"MALFORMED {line}")
    for where, how, src in shipped:
        print(f"SHIPPED {where} {how} the prebuilt {src}")
    for where, _, src in review:
        print(
            f"EMBEDS? {where} shares code with the prebuilt {src}: the review decides "
            "whether it was linked or rebuilt"
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
    for glob, reason, why, _ in excs:
        if covered[glob]:
            on = f", for {', '.join(sorted(plats[glob]))}" if plats[glob] else ""
            print(f"EXCEPTION {glob} ({reason}: {why}): {covered[glob]} hit(s){on}")
        elif glob not in matched:
            print(f"note: exception {glob} matches nothing")
        elif not any(e[0] == glob for e in refused):
            print(
                f"note: exception {glob} holds for none it matches; other lines cover them"
            )
    boot = [f"{g}: {w}" for g, r, w, _ in excs if r == "bootstrap" and covered[g]]
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
    if review:
        checked += f", {len(review)} EMBEDS? line(s) for the review"
    print(
        f"OK: no prebuilt binaries in the sources{f' outside the {n} excepted' if n else ''}"
        f"{checked}{tail}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
