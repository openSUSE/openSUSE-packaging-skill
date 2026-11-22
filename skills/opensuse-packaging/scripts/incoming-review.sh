#!/bin/bash
# incoming-review.sh — the review recorder for a contributor's submit request
# or pull request on a package you maintain. A reviewing agent reads the change
# as text (--show), then records its verdict (--record); the guard lets your
# accept or approve go ahead only with a stamp whose key matches what OBS or
# src.opensuse.org serves at that moment. The recorder trusts nothing from the
# agent but the verdict word and the comment: --record fetches everything
# again and re-derives every fact. It writes nothing but its own stamp, never
# builds, never runs a service, never parses a spec with rpm (the advisory
# scanner _parse_scan.py reads it as text), and reads no credential: osc and
# git-obs log in themselves.
#
# Usage: incoming-review.sh --show <sr#ID | owner/repo#N>
#        incoming-review.sh --record <ID> FILE   (or --record=<ID> FILE)
#   --show    the request's facts, its description and diff (sanitized, between
#             data markers), the mechanical findings, then `build <project>`,
#             the OBS project whose build is the evidence (an SR's source
#             project; a PR's staging project, or - when none built the head),
#             and last `key <sha12>`: a hash over the request's actions, its
#             source rev, srcmd5 and file md5s and the target's file md5s (a
#             PR: its head, base and merge base and both trees)
#   --record  FILE's first line is `PASS|FIXABLE|BLOCK <ID> key <sha12>`, the
#             rest is the comment as it will be posted (the blank space around
#             it dropped; the stamp's comment_sha256 is its UTF-8 sha256). A
#             key that moved since --show is refused. PASS and FIXABLE are
#             refused while any finding stands, while the comment breaks a
#             rule, and until the installed guard ~/.claude/hooks/_pr_guard.py
#             has foreign_accept; BLOCK always records, and allows no comment
#             when its comment breaks a rule. The stamp, mode 0600:
#             ~/.local/state/opensuse-packaging/incoming/obs/<ID>.json, or
#             .../incoming/gitea/<owner>_<repo>_<N>.json
# Findings, each refusing PASS and FIXABLE: no source rev, or a _link source
# whose rev is no 32-hex srcmd5; more than one action, a type but submit, an
# option but sourceupdate; a target package that does not exist; parse-time
# code the scanner finds added over the target's files, or a scan that stopped
# short; a changed _service, _link, _aggregate, *.macros, .gitmodules, symlink
# or submodule; bidi or zero-width characters; a source host the target's
# spec does not use (nothing is fetched from it), a changed file whose bytes
# differ from its Source URL's, a changed binary with no Source URL; a
# service-made vendor or obscpio archive; a diff over 128 KiB; for an SR, a
# source package whose sources moved since the request, or whose build is not
# green from them: each Tumbleweed and Leap 16 repo on x86_64 and aarch64 that
# gate.sh judges and the source project builds succeeded, one at least. A PR's
# build is reported, never required: PRs build only where the devel project
# builds them. The comment: no URL but a build, src or bugzilla.opensuse.org one,
# no @-mention but of the creator, no internal tag (VERDICT, tree keys, gate
# names), no bot directive, 1500 characters at most.
# Env INCOMING_REVIEW_GUARD: the guard file to check instead; the test suite's
# alone.
# Exit: 0 = recorded (--show: shown); 1 = refused; 2 = usage; 3 = key moved;
#       5 = lookup failed
set -u

usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; }
bad() { echo "incoming-review.sh: $1 (usage: references/script-usage.md)" >&2; exit 2; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --show) [ $# -eq 2 ] || bad "--show takes one id" ;;
  --record) [ $# -eq 3 ] || bad "--record takes an id and a FILE" ;;
  # the two spellings the guard knows; no abbreviation, no short form
  --record=*) [ $# -eq 2 ] || bad "--record=<ID> takes a FILE"; set -- --record "${1#--record=}" "$2" ;;
  *) bad "--show or --record expected" ;;
esac
[ -n "${HOME:-}" ] || bad "HOME is not set"
HERE="$(cd "$(dirname "$0")" && pwd)" || exit 5
STATE="$HOME/.local/state/opensuse-packaging/incoming"
GUARD="${INCOMING_REVIEW_GUARD:-$HOME/.claude/hooks/_pr_guard.py}"

python3 -I -X pycache_prefix=/dev/null/opensuse-packaging - "$HERE" "$STATE" "$GUARD" "$@" <<'PY'
import base64
import binascii
import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

HERE, STATE, GUARD, MODE = sys.argv[1:5]
ARGS = sys.argv[5:]
sys.path.insert(0, HERE)
import _obs_scope as scope  # noqa: E402
import _sanitize  # noqa: E402

API = "https://api.opensuse.org"
TIMEOUT = 60
FETCH_CAP = 8 << 20  # the scanner's own cap on included text
DIFF_CAP = 128 << 10
COMMENT_CAP = 1500
DOWNLOAD_TIME = 300
UA = "openSUSE-packaging-incoming-review/1"
SCAN = os.path.join(HERE, "_parse_scan.py")
HEX32 = re.compile(r"[0-9a-f]{32}")
HEX40 = re.compile(r"[0-9a-f]{40}")
PRJ = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.+:-]*")
PKG = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.+-]*")
LOGIN = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.+-]*")
GIT_NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")
CTRL = re.compile(r"[\x00-\x1f\x7f]")
INVISIBLE = re.compile(
    "[\u202a-\u202e\u2066-\u2069\u200e\u200f\u061c\u200b-\u200d\u2060\ufeff"
    "\U000e0000-\U000e007f]"
)
GUARDED = {"_service", "_link", "_aggregate", ".gitmodules"}
VENDOR = re.compile(
    r"(?i)\.obscpio$|(?:^|[-_.])(?:vendor(?:ed)?|node[-_]modules|crates)(?:[-_.][\w.+-]*)?"
    r"\.(?:tar(?:\.(?:gz|xz|zst|bz2|lz|lzma))?|tgz|txz|tzst|tbz2?|zip)$"
)
LFS = re.compile(rb"\Aversion https://git-lfs\.github\.com/spec/v1\n(?:[^\n]*\n)*?oid sha256:([0-9a-f]{64})\n")
REGULAR = ("", "100644", "100755")
MODES = {"100644", "100755", "120000", "160000"}

# The comment's rules. LINE_START, MERGE_OK and GROUP_REVIEW as pr-guard reads a
# bot directive; WORK_NOTE as it reads a work note in a request message.
ALLOWED_HOSTS = {"build.opensuse.org", "src.opensuse.org", "bugzilla.opensuse.org"}
URLISH = re.compile(
    r"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"'`]*|\bwww\.[^\s<>\"'`]*"
    r"|\b(?:[a-z0-9-]+\.)+[a-z]{2,}/[^\s<>\"'`]*"
)
MENTION = re.compile(r"(?<![\w.@/+-])@([A-Za-z0-9_][\w.-]*)")
LINE_START = r"(?i)(?:[^\w@]|_)*(?:\d+[.)]\s+)?"
MERGE_OK = re.compile(rf"{LINE_START}(merge[\W_]*ok(?:ay)?)(?!\w)")
GROUP_REVIEW = re.compile(rf"{LINE_START}(@[\w.+-]+\s*:\s*(?:approve|decline))(?!\w)")
WORK_NOTE = re.compile(
    r"\b(?:not done|bugwarden|vul[- ](?:sweep|bug cross-check)|(?:builds?|built) green"
    r"|still building|this env(?:ironment)?|sub-?agents?|no (?:bugzilla )?access"
    r"|gate\.sh|adversarial review|review (?-i:PASS)|(?-i:GREEN))\b",
    re.I,
)
INTERNAL = re.compile(
    r"\b(?:VERDICT|FIXABLE|PASS|BLOCK)\b"
    r"|(?i:\b(?:tree|key)\s+[0-9a-f]{12,64}\b|\bcomment_sha256\b"
    r"|\b(?:pr-guard|changes-review|incoming-review|parse-surface)\b)"
)
SCRIPTS = sorted(n for n in os.listdir(HERE) if n.endswith((".sh", ".py")))
SCRIPT_NAMES = re.compile(r"(?<![\w.-])(?:%s)(?![\w-])" % "|".join(map(re.escape, SCRIPTS)))


class Lookup(Exception):
    """A lookup that failed or answered nothing usable: exit 5, never "none"."""


class Usage(Exception):
    """A malformed id or FILE: exit 2."""


def clean(text):
    """Third-party text as one sanitized line."""
    return " ".join(_sanitize.sanitize(str(text)).split())


def shown(name):
    return name if not CTRL.search(name) else json.dumps(name)


def say(text=""):
    out = _sanitize.sanitize(str(text)).encode("utf-8", "surrogateescape")
    sys.stdout.write(out.decode("utf-8", "backslashreplace") + "\n")


def last(err):
    lines = err.decode("utf-8", "replace").strip().splitlines()
    return clean(lines[-1])[:200] if lines else ""


def run(cmd, timeout=TIMEOUT):
    """(exit status, stdout, stderr) as bytes; a timeout or a missing program
    is a failed call (124, 127), never an empty answer."""
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, b"", b"%s timed out after %ds" % (cmd[0].encode(), timeout)
    except OSError as e:
        return 127, b"", ("%s: %s" % (cmd[0], e.strerror)).encode()
    return p.returncode, p.stdout, p.stderr


def q(s):
    return urllib.parse.quote(s, safe=":+")


def obs(path, missing_ok=False, empty_ok=False):
    """osc api PATH as bytes. missing_ok: a 404 is None; every other failure,
    and an empty answer unless empty_ok, is a Lookup."""
    rc, out, err = run(["osc", "-A", API, "api", path])
    if rc == 0:
        if not out.strip() and not empty_ok:
            raise Lookup("osc api %s: an empty answer" % path)
        return out
    if missing_ok and b"HTTP Error 404" in err:
        return None
    raise Lookup("osc api %s failed (%d): %s" % (path, rc, last(err) or "no message"))


def xml(data, what, tag):
    try:
        root = ET.fromstring(data)
    except ET.ParseError as e:
        raise Lookup("%s: an unparseable answer (%s)" % (what, e))
    if root.tag != tag:
        raise Lookup("%s: a <%s> answer, not <%s>" % (what, clean(root.tag), tag))
    return root


def gitea(path):
    rc, out, err = run(["git-obs", "-G", "src.opensuse.org", "-q", "api", path])
    if rc != 0:
        raise Lookup("git-obs api %s failed (%d): %s" % (path, rc, last(err) or "no message"))
    text = out.decode("utf-8", "replace")
    if text.startswith("Response:"):
        text = text.split("\n", 1)[1] if "\n" in text else ""
    if not text.strip():
        raise Lookup("git-obs api %s: an empty answer" % path)
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        raise Lookup("git-obs api %s: an unparseable answer (%s)" % (path, e))


def listing(root, what):
    """{name: (md5, size, "")} and the srcmd5 of an OBS directory listing."""
    files = {}
    for e in root.findall("entry"):
        n, m, s = e.get("name") or "", e.get("md5") or "", e.get("size") or ""
        if (
            not n
            or n in files
            or n in (".", "..")
            or "/" in n
            or CTRL.search(n)
            or not HEX32.fullmatch(m)
            or not re.fullmatch(r"[0-9]+", s)
        ):
            raise Lookup("%s: a malformed entry (%s)" % (what, shown(n) or "no name"))
        files[n] = (m, int(s), "")
    srcmd5 = root.get("srcmd5") or ""
    if not HEX32.fullmatch(srcmd5):
        raise Lookup("%s: no srcmd5" % what)
    return files, srcmd5


def valid_path(p):
    parts = p.split("/")
    return all(x and x not in (".", "..") and not CTRL.search(x) for x in parts)


def gitea_tree(owner, repo, sha):
    what = "the tree of %s/%s at %s" % (owner, repo, sha[:12])
    j = gitea("/repos/%s/%s/git/trees/%s?recursive=true&per_page=1000" % (owner, repo, sha))
    if not isinstance(j, dict) or not isinstance(j.get("tree"), list) or j.get("truncated") is not False:
        raise Lookup("%s: a malformed or truncated answer" % what)
    files = {}
    for e in j["tree"]:
        if not isinstance(e, dict):
            raise Lookup("%s: a malformed entry" % what)
        p, mode, typ, s = e.get("path"), e.get("mode"), e.get("type"), e.get("sha")
        if typ == "tree" and isinstance(p, str) and valid_path(p):
            continue
        size = e.get("size", 0) if typ == "blob" else 0
        if (
            not isinstance(p, str)
            or not valid_path(p)
            or p in files
            or typ not in ("blob", "commit")
            or mode not in MODES
            or not isinstance(s, str)
            or not HEX40.fullmatch(s)
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size < 0
        ):
            raise Lookup("%s: a malformed entry (%s)" % (what, shown(str(p))))
        files[p] = (s, size, mode)
    if not files:
        raise Lookup("%s: no file" % what)
    return files


def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_blob(b):
    return hashlib.sha1(b"blob %d\0" % len(b) + b).hexdigest()


def placeholder(ident):
    return b"incoming-review: not fetched, %s\n" % ident.encode()


class Tree:
    """One side of the change: {name: (id, size, mode)}, each file fetched once,
    only when needed, and checked against its id. A twin holding the same id
    shares the bytes."""

    def __init__(self, files, fetch, check):
        self.files, self._fetch, self._check = files, fetch, check
        self.data, self.twin = {}, None

    def same(self, name):
        t = self.twin
        return t is not None and name in t.files and t.files[name][::2] == self.files[name][::2]

    def real(self, name):
        """name's bytes, or None when it is over the fetch cap, a symlink or
        a submodule (never fetched)."""
        if name in self.data:
            return self.data[name]
        ident, size, mode = self.files[name]
        if size > FETCH_CAP or mode not in REGULAR:
            return None
        if self.same(name) and name in self.twin.data:
            self.data[name] = self.twin.data[name]
            return self.data[name]
        b = self._fetch(name, ident)
        if not self._check(b, ident):
            raise Lookup("%s: the bytes fetched do not match %s" % (shown(name), ident))
        self.data[name] = b
        if self.same(name):
            self.twin.data[name] = b
        return b

    def write(self, d):
        """The tree in d: a fetched file as it is, any other as a placeholder
        naming its id, so two placeholders are equal exactly when the files are."""
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        for name, (ident, _, mode) in self.files.items():
            if mode == "160000":
                continue
            p = os.path.join(d, *name.split("/"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            b = self.data.get(name)
            with open(p, "wb") as fh:
                fh.write(b if b is not None else placeholder(ident))


def pair(src, base):
    src.twin, base.twin = base, src
    return src, base


class Facts:
    def __init__(self, kind, label, sid):
        self.kind, self.label, self.sid = kind, label, sid
        self.findings, self.info, self.diff, self.desc = [], [], "", ""
        self.scan = {"exit": None, "lines": []}
        self.build = {}
        self.part = {}
        self.creator = self.project = ""
        self.key = ""

    def find(self, why):
        self.findings.append(clean(why))


# ---------------------------------------------------------------- the spec as text
SPEC_DEF = re.compile(r"^\s*%(?:global|define)\s+(\w+)\s+(\S.*?)\s*$")
SPEC_TAG = re.compile(r"^\s*(Name|Version|URL|Source\d*)\s*:\s*(\S+)", re.I)
SPEC_USE = re.compile(r"%%|%\{(\??)(\w+)\}|%(\w+)")


def sources(text):
    """(tag, value) of each Source line, the spec's own %define/%global and
    Name, Version and URL put in as text; anything else stays as written."""
    defs, tags, srcs = {}, {}, []
    for line in text.splitlines():
        m = SPEC_DEF.match(line)
        if m:
            k, v = m.groups()
            defs[k] = v if defs.get(k, v) == v else None  # two values: unknown
            continue
        m = SPEC_TAG.match(line)
        if m:
            tag, v = m.groups()
            if tag.lower().startswith("source"):
                srcs.append((tag, v))
            else:
                tags.setdefault(tag.lower(), v)
    for k, v in tags.items():
        defs[k] = v if defs.get(k, v) == v else None

    def sub(m):
        k = m.group(2) or m.group(3)
        if not k:
            return m.group(0)
        v = defs.get(k)
        if v is not None and "%(" not in v and "%{lua" not in v:
            return v
        return "" if m.group(1) and k not in defs else m.group(0)

    out = []
    for tag, v in srcs:
        for _ in range(8):
            n = SPEC_USE.sub(sub, v)
            if n == v:
                break
            v = n
        out.append((tag, v))
    return out


def is_url(v):
    scheme = urllib.parse.urlsplit(v).scheme.lower() if "://" in v else ""
    return scheme in ("http", "https", "ftp") or ("%" in v and "/" in v)


def local_name(url):
    if "#/" in url:
        return url.split("#/", 1)[1]
    return urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1]


def host_of(url):
    try:
        net = urllib.parse.urlsplit(url).netloc
    except ValueError:
        return None
    if not net or "%" in net:
        return None
    return (urllib.parse.urlsplit(url).hostname or "").lower() or None


# ---------------------------------------------------------------- what the change holds
def analyze(f, src, base, target_exists, tmp, lfs):
    """The content findings, the diff and the scan, from the two trees."""
    names = sorted(set(src.files) | set(base.files))
    changed = [n for n in names if src.files.get(n, ())[::2] != base.files.get(n, ())[::2]]
    added = [n for n in changed if n not in base.files]
    removed = [n for n in changed if n not in src.files]
    f.info.append(
        "files: %d changed, %d added, %d removed (source %d, target %d)"
        % (len(changed) - len(added) - len(removed), len(added), len(removed), len(src.files), len(base.files))
    )
    for n in changed:
        b = n.rsplit("/", 1)[-1]
        how = "added" if n in added else "removed" if n in removed else "changed"
        if b in GUARDED or b.endswith(".macros") or b.startswith("_service:"):
            f.find("content: %s %s: a _service, _link, _aggregate, *.macros or .gitmodules change is the maintainer's own to review" % (shown(n), how))
        modes = {t.files[n][2] for t in (src, base) if n in t.files}
        if "120000" in modes:
            f.find("content: symlink %s %s" % (shown(n), how))
        if "160000" in modes:
            f.find("content: submodule %s %s" % (shown(n), how))
        if n not in removed and VENDOR.search(b):
            f.find("content: %s %s: a service-made vendor or obscpio archive, whose bytes no review can check" % (shown(n), how))
        if INVISIBLE.search(n):
            f.find("content: the name of %s holds a bidi or zero-width character" % shown(n))

    specs = lambda t: sorted(n for n in t.files if "/" not in n and n.endswith(".spec"))  # noqa: E731
    for t in (src, base):
        for n in specs(t):
            t.real(n)

    # the diff, and the bidi check on every changed text the change brings
    out, total, over, binary = [], 0, False, set()
    for n in changed:
        new = src.real(n) if n in src.files else b""
        old = base.real(n) if n in base.files else b""
        if new is not None and n not in removed:
            m = INVISIBLE.search(new.decode("utf-8", "surrogateescape"))
            if m:
                line = new.decode("utf-8", "surrogateescape")[: m.start()].count("\n") + 1
                f.find("content: %s line %d holds a bidi or zero-width character (U+%04X)" % (shown(n), line, ord(m.group(0))))
        if n not in removed and (new is None or b"\0" in new or (lfs and LFS.match(new))):
            binary.add(n)
        if new is None or old is None or b"\0" in new or b"\0" in old:
            ids = (base.files.get(n, ("-",))[0][:12], src.files.get(n, ("-",))[0][:12])
            text = "Binary or unfetched file %s: %s -> %s\n" % (n, *ids)
        elif max(len(new), len(old)) > DIFF_CAP:
            text = "Text file %s too large to show (%d bytes)\n" % (n, max(len(new), len(old)))
            over = True
        else:
            lines = difflib.unified_diff(
                old.decode("utf-8", "surrogateescape").splitlines(True),
                new.decode("utf-8", "surrogateescape").splitlines(True),
                "a/" + n if n not in added else "/dev/null",
                "b/" + n if n not in removed else "/dev/null",
            )
            text = "".join(ln if ln.endswith("\n") else ln + "\n\\ No newline at end of file\n" for ln in lines)
        text = _sanitize.sanitize(text)
        if total + len(text) > DIFF_CAP:
            over = True
            out.append("... diff cut at %d KiB: %s and later files not shown\n" % (DIFF_CAP >> 10, n))
            break
        total += len(text)
        out.append(text)
    f.diff = "".join(out)
    if over:
        f.find("content: the diff is over the %d KiB cap: no review can read it whole" % (DIFF_CAP >> 10))

    # Source URLs: the bytes of each changed file they name, and their hosts
    urls, hosts = {}, set()
    for n in specs(src):
        for tag, v in sources((src.real(n) or b"").decode("utf-8", "surrogateescape")):
            if is_url(v):
                urls.setdefault(local_name(v), (n, tag, v))
    for n in specs(base):
        for tag, v in sources((base.real(n) or b"").decode("utf-8", "surrogateescape")):
            if is_url(v) and host_of(v):
                hosts.add(host_of(v))
    if target_exists:
        for spec, tag, v in sorted(urls.values()):
            h = host_of(v)
            if not h:
                f.find("content: %s %s: cannot read the host of %s" % (spec, tag, v))
            elif h not in hosts:
                f.find("content: %s %s downloads from %s, a host the target's Sources do not use (%s)" % (spec, tag, h, ", ".join(sorted(hosts)) or "none"))
    for n in changed:
        if n in removed or n not in urls:
            if n in binary and not VENDOR.search(n.rsplit("/", 1)[-1]) and src.files[n][2] in REGULAR:
                f.find("content: %s is binary, %s, and no Source URL names it to check its bytes against" % (shown(n), "added" if n in added else "changed"))
            continue
        spec, tag, v = urls[n]
        if not target_exists or host_of(v) not in hosts:
            # never fetched: a host the target's spec does not name
            f.find("content: the bytes of %s are not checked: %s is no host the target's Sources use" % (shown(n), host_of(v) or v))
            continue
        verify(f, src, n, spec, tag, v, tmp, lfs)
    scan(f, src, base, tmp, specs)


def verify(f, src, name, spec, tag, url, tmp, lfs):
    """The bytes of name against what its Source URL serves."""
    if "%" in url:
        f.find("content: %s %s %s: a macro the text cannot expand, so the bytes of %s are not checked" % (spec, tag, url, shown(name)))
        return
    fetch = url.split("#", 1)[0]
    path = os.path.join(tmp, "download")
    if os.path.exists(path):
        os.unlink(path)
    rc, _, err = run(
        [
            "curl", "-q", "-fsSL", "--proto", "=http,https,ftp", "--proto-redir", "=http,https,ftp",
            "--max-time", str(DOWNLOAD_TIME), "-A", UA, "-o", path, "--url", fetch,
        ],
        timeout=DOWNLOAD_TIME + 30,
    )
    if rc != 0 or not os.path.isfile(path):
        f.find("content: %s %s: cannot download %s (curl %d: %s), so the bytes of %s are not checked" % (spec, tag, fetch, rc, last(err), shown(name)))
        return
    ident = src.files[name][0]
    if not lfs:
        ok = md5_of(path) == ident
    else:
        data = src.data.get(name)
        m = LFS.match(data) if data is not None else None
        h = hashlib.sha256() if m else hashlib.sha1(b"blob %d\0" % os.path.getsize(path))
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        ok = h.hexdigest() == (m.group(1).decode() if m else ident)
    os.unlink(path)
    if not ok:
        f.find("content: %s differs from the bytes at %s (%s %s)" % (shown(name), fetch, spec, tag))


def scan(f, src, base, tmp, specs):
    """_parse_scan.py scan of the change against the target's files: each file
    it reads fetched, until what it reads settles."""
    new, old = os.path.join(tmp, "new"), os.path.join(tmp, "old")
    short = ["%s is over the %d MiB fetch cap" % (shown(n), FETCH_CAP >> 20) for n in specs(src) if src.real(n) is None]
    # one round per include level: the scanner reads 8 deep
    for _ in range(12):
        src.write(new)
        rc, out, err = run([sys.executable, "-I", SCAN, "needs", new])
        if rc != 0:
            f.scan = {"exit": 3, "lines": ["needs failed (%d): %s" % (rc, last(err) or last(out))]}
            f.find("content: the parse scan failed: %s" % f.scan["lines"][0])
            return
        more = False
        for n in out.decode("utf-8", "replace").splitlines():
            for t in (src, base):
                if n in t.files and n not in t.data:
                    if t.real(n) is not None:
                        more = True
                    elif ("%s is over" % shown(n)) not in " ".join(short):
                        short.append("%s is over the %d MiB fetch cap" % (shown(n), FETCH_CAP >> 20))
        if not more:
            break
    else:
        short.append("the files it reads did not settle in 12 rounds")
    src.write(new)
    base.write(old)
    rc, out, err = run([sys.executable, "-I", SCAN, "scan", new, old], timeout=120)
    lines = [clean(x) for x in (out + err).decode("utf-8", "replace").splitlines() if x.strip()]
    if rc in (0, 1, 4) and short:
        lines += ["incomplete: %s" % s for s in short]
        rc = rc or 4
    f.scan = {"exit": rc, "lines": lines[:40]}
    if rc == 1:
        f.find("content: the change adds parse-time code over the target (scan lines above)")
    elif rc == 4:
        f.find("content: the parse scan stopped short (incomplete): nothing past that point is known")
    elif rc != 0:
        f.find("content: the parse scan failed (%d): %s" % (rc, lines[0] if lines else "no message"))


# ---------------------------------------------------------------- build evidence
def build_obs(f, prj, pkg, srcmd5, leap):
    """The source package's own build: its current sources must be the
    request's, and every repo/arch gate.sh --obs-build judges (_obs_scope) that
    the source project builds must have succeeded from them, one at least."""
    out = {"project": prj, "package": pkg, "required": True, "results": {}, "srcmd5": "", "green": False}
    f.build = out
    before = len(f.findings)
    what = "%s/%s" % (prj, pkg)
    _, cur = listing(xml(obs("/source/%s/%s?expand=1" % (q(prj), q(pkg))), what, "directory"), what)
    out["srcmd5"] = cur
    if cur != srcmd5:
        f.find("build: %s moved since the request (sources %s, the request's %s): its results are of other sources" % (what, cur[:12], srcmd5[:12]))
        return
    res = xml(obs("/build/%s/_result?package=%s&multibuild=1" % (q(prj), q(pkg))), "the results of %s" % what, "resultlist")
    probs, judged = [], []
    for r in res.findall("result"):
        repo, arch = r.get("repository") or "", r.get("arch") or ""
        if not scope.judged(prj, repo, arch, leap):
            continue
        mine = [s for s in r.findall("status") if (s.get("package") or "") == pkg or (s.get("package") or "").startswith(pkg + ":")]
        if not any(s.get("package") == pkg for s in mine):
            probs.append("%s/%s has no build of %s" % (clean(repo), clean(arch), pkg))
        for s in mine:
            name = s.get("package")
            code = "dirty" if r.get("dirty") == "true" else (s.get("code") or "unknown")
            label = clean("%s/%s%s" % (repo, arch, name[len(pkg):]))
            out["results"][label] = clean(code)
            if code == "succeeded":
                judged.append((repo, arch, name, label))
            elif code not in ("excluded", "disabled"):
                probs.append("%s %s" % (label, clean(code)))
    if not judged:
        probs.append("no Tumbleweed or Leap 16 build on x86_64 or aarch64 succeeded")
    for repo, arch, name, label in judged:
        path = "/build/%s/%s/%s/_jobhistory?package=%s&limit=1" % (q(prj), q(repo), q(arch), q(name))
        jobs = xml(obs(path), "the job history of %s/%s" % (prj, label), "jobhistlist").findall("jobhist")
        got = jobs[-1].get("srcmd5", "") if jobs else ""
        if got != cur:
            probs.append("%s built %s, not the sources %s" % (label, clean(got[:12]) or "nothing recorded", cur[:12]))
    for p in probs:
        f.find("build: %s: %s" % (what, p))
    out["green"] = len(f.findings) == before


PR_BUILD = {0: "green", 1: "red", 3: "pending", 4: "stale"}


def build_pr(f, label):
    """A PR is built only where its devel project builds PRs: sr-status.py --pr
    reads the staging bot's build of the head. Reported, never required."""
    rc, out, err = run([sys.executable, "-I", os.path.join(HERE, "sr-status.py"), "--pr", label], timeout=300)
    if rc not in PR_BUILD:
        raise Lookup("sr-status.py --pr %s (%d): %s" % (label, rc, last(out + err) or "no message"))
    text = out.decode("utf-8", "replace")
    m = re.search(r"^PR build: (\S+)", text, re.M)
    prj = m.group(1) if m and PRJ.fullmatch(m.group(1)) else ""
    verdict = PR_BUILD[rc] if prj else "none"
    said = re.findall(r"^VERDICT: (.*)$", text, re.M)
    note = "no build of this head" if verdict == "none" else clean(said[-1]) if said else verdict
    f.build = {"project": prj, "required": False, "results": {}, "srcmd5": "", "green": verdict == "green",
               "verdict": verdict, "note": note}
    f.project = prj


# ---------------------------------------------------------------- the two kinds
def derive_obs(rid, tmp):
    f = Facts("obs", "sr#" + rid, rid)
    root = xml(obs("/request/%s" % rid), "request %s" % rid, "request")
    if root.get("id") != rid:
        raise Lookup("request %s: the answer is request %s" % (rid, clean(root.get("id") or "?")))
    f.creator = root.get("creator") or ""
    if not LOGIN.fullmatch(f.creator):
        raise Lookup("request %s: no creator" % rid)
    acts = []
    for a in root.findall("action"):
        s, t, o = a.find("source"), a.find("target"), a.find("options")
        acts.append({
            "type": a.get("type") or "",
            "source": dict(sorted(s.attrib.items())) if s is not None else {},
            "target": dict(sorted(t.attrib.items())) if t is not None else {},
            "options": [[c.tag, (c.text or "").strip()] for c in o] if o is not None else [],
        })
    if not acts:
        raise Lookup("request %s: no action" % rid)
    if len(acts) > 1:
        f.find("shape: %d actions: only a request with one submit action may pass" % len(acts))
    for a in acts:
        if a["type"] != "submit":
            f.find("shape: a %s action, not submit" % clean(a["type"] or "typeless"))
        for tag, val in a["options"]:
            if tag != "sourceupdate":
                f.find("shape: option %s%s: only sourceupdate may pass" % (clean(tag), "=" + clean(val) if val else ""))
    f.desc = "description: " + _sanitize.sanitize(root.findtext("description") or "(none)")
    key = {"kind": "obs", "id": rid, "creator": f.creator, "actions": acts}
    a = next((x for x in acts if x["type"] == "submit"), None)
    if a is None:
        f.scan = {"exit": 3, "lines": ["no submit action: nothing scanned"]}
        f.key = digest(key)
        f.part = {"obs": {"action": {"type": acts[0]["type"], "options": [], "source": {}, "target": {}}, "actions": len(acts)}}
        f.build = {"project": "", "required": True, "results": {}, "srcmd5": "", "green": False}
        return f
    sprj, spkg, rev = a["source"].get("project", ""), a["source"].get("package", ""), a["source"].get("rev", "")
    tprj, tpkg = a["target"].get("project", ""), a["target"].get("package") or spkg
    for v, rx in ((sprj, PRJ), (spkg, PKG), (tprj, PRJ), (tpkg, PKG)):
        if not rx.fullmatch(v):
            raise Lookup("request %s: a malformed project or package name (%s)" % (rid, shown(v)))
    f.project = sprj
    if not rev:
        f.find("revision: the request pins no source rev: what it submits moves with %s/%s" % (sprj, spkg))
    elif not re.fullmatch(r"[0-9]+|[0-9a-f]{32}", rev):
        f.find("revision: rev %s is neither a revision number nor a srcmd5" % shown(rev))
    what = "%s/%s%s" % (sprj, spkg, " rev " + rev if rev else "")
    path = "/source/%s/%s?expand=1%s" % (q(sprj), q(spkg), "&rev=" + q(rev) if rev else "")
    sroot = xml(obs(path), what, "directory")
    sfiles, ssrc = listing(sroot, what)
    if not sfiles:
        raise Lookup("%s: no file" % what)
    if sroot.find("linkinfo") is not None and not HEX32.fullmatch(rev):
        f.find("revision: the source is a _link, and its rev %s is no 32-hex srcmd5: what it expands to moves" % (shown(rev) or "(none)"))
    traw = obs("/source/%s/%s?expand=1" % (q(tprj), q(tpkg)), missing_ok=True)
    tfiles, tsrc = ({}, "") if traw is None else listing(xml(traw, "%s/%s" % (tprj, tpkg), "directory"), "%s/%s" % (tprj, tpkg))
    if traw is None:
        f.find("target: %s/%s does not exist: a new package is the maintainer's own to review" % (tprj, tpkg))
    opts = " (%s)" % ", ".join("=".join(x for x in o if x) for o in a["options"]) if a["options"] else ""
    f.info.insert(0, "%s by %s: submit %s -> %s/%s%s" % (f.label, f.creator, what, tprj, tpkg, opts))

    def fetcher(prj, pkg, srcmd5):
        return lambda n, _: obs("/source/%s/%s/%s?rev=%s" % (q(prj), q(pkg), q(n), srcmd5), empty_ok=True)

    md5ok = lambda b, ident: hashlib.md5(b).hexdigest() == ident  # noqa: E731
    src, base = pair(Tree(sfiles, fetcher(sprj, spkg, ssrc), md5ok), Tree(tfiles, fetcher(tprj, tpkg, tsrc), md5ok))
    smap = {n: m for n, (m, _, _) in sfiles.items()}
    tmap = {n: m for n, (m, _, _) in tfiles.items()}
    key.update(source={"srcmd5": ssrc, "files": smap}, target={"exists": traw is not None, "files": tmap})
    f.key = digest(key)
    analyze(f, src, base, traw is not None, tmp, lfs=False)
    # a request to Factory itself is judged without Leap 16, as gate.sh judges it
    build_obs(f, sprj, spkg, ssrc, leap=not (tprj == "openSUSE:Factory" or tprj.startswith("openSUSE:Factory:")))
    f.part = {"obs": {
        "action": {
            "type": "submit",
            "options": [o[0] for o in a["options"]],
            "source": {"project": sprj, "package": spkg, "rev": rev, "srcmd5": ssrc, "files": smap},
            "target": {"project": tprj, "package": tpkg, "srcmd5": tsrc, "files": tmap},
        },
        "actions": len(acts),
    }}
    return f


def derive_gitea(owner, repo, num, tmp):
    label = "%s/%s#%s" % (owner, repo, num)
    f = Facts("gitea", label, label)
    pr = gitea("/repos/%s/%s/pulls/%s" % (owner, repo, num))
    try:
        head, base_ = pr["head"]["sha"], pr["base"]["sha"]
        mb, f.creator = pr["merge_base"], pr["user"]["login"]
        full = pr["base"]["repo"]["full_name"]
        ok = pr["number"] == int(num) and all(isinstance(x, str) and HEX40.fullmatch(x) for x in (head, base_, mb))
        ok = ok and isinstance(f.creator, str) and LOGIN.fullmatch(f.creator) and isinstance(full, str)
    except (KeyError, TypeError):
        ok = False
    if not ok or full.lower() != ("%s/%s" % (owner, repo)).lower():
        raise Lookup("%s: a malformed answer for the PR" % label)
    title = pr.get("title") if isinstance(pr.get("title"), str) else ""
    body = pr.get("body") if isinstance(pr.get("body"), str) else ""
    f.desc = "title: %s\ndescription: %s" % (_sanitize.sanitize(title), _sanitize.sanitize(body or "(none)"))
    f.info.insert(0, "%s by %s: head %s, base %s, merge base %s" % (label, f.creator, head[:12], base_[:12], mb[:12]))
    hfiles, bfiles = gitea_tree(owner, repo, head), gitea_tree(owner, repo, mb)

    def fetch(n, ident):
        j = gitea("/repos/%s/%s/git/blobs/%s" % (owner, repo, ident))
        if not isinstance(j, dict) or j.get("encoding") != "base64" or not isinstance(j.get("content"), str):
            raise Lookup("the blob %s of %s: a malformed answer" % (ident[:12], label))
        try:
            return base64.b64decode(j["content"])
        except (binascii.Error, ValueError):
            raise Lookup("the blob %s of %s: no base64" % (ident[:12], label))

    blobok = lambda b, ident: git_blob(b) == ident  # noqa: E731
    src, base = pair(Tree(hfiles, fetch, blobok), Tree(bfiles, fetch, blobok))
    hmap = {n: s for n, (s, _, _) in hfiles.items()}
    f.key = digest({
        "kind": "gitea", "id": label, "creator": f.creator, "head": head, "base": base_, "merge_base": mb,
        "files": {n: [s, m] for n, (s, _, m) in hfiles.items()},
        "base_files": {n: [s, m] for n, (s, _, m) in bfiles.items()},
    })
    analyze(f, src, base, True, tmp, lfs=True)
    build_pr(f, label)
    f.part = {"gitea": {"owner": owner, "repo": repo, "number": int(num), "head": head, "base": base_, "merge_base": mb, "files": hmap}}
    return f


def digest(facts):
    return hashlib.sha256(json.dumps(facts, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:12]


def parse_id(s):
    m = re.fullmatch(r"(?:sr)?#?([0-9]{1,10})", s)
    if m:
        return ("obs", m.group(1))
    m = re.fullmatch(r"([^/#]+)/([^/#]+)#([0-9]{1,10})", s)
    if m and GIT_NAME.fullmatch(m.group(1)) and GIT_NAME.fullmatch(m.group(2)):
        return ("gitea", m.group(1), m.group(2), m.group(3))
    raise Usage("not an id: %s (sr#ID or owner/repo#N)" % shown(s)[:80])


def derive(ident, tmp):
    if ident[0] == "obs":
        return derive_obs(ident[1], tmp)
    return derive_gitea(*ident[1:], tmp)


def guard_ready():
    try:
        with open(GUARD, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return False
    return re.search(r"^\s*def foreign_accept\b", text, re.M) is not None


def report(f, diff):
    for ln in f.info:
        say(ln)
    if diff:
        say(_sanitize.DELIM_OPEN)
        say(f.desc)
        say(f.diff.rstrip("\n") or "(no file differs)")
        say(_sanitize.DELIM_CLOSE)
    meaning = {0: "nothing added over the target", 1: "parse-time code added", 4: "incomplete"}
    say("scan: %s (%s)" % (f.scan["exit"], meaning.get(f.scan["exit"], "failed")))
    for ln in f.scan["lines"][:20]:
        say("  " + ln)
    b = f.build
    if b.get("required", True):
        shown_results = ", ".join("%s %s" % kv for kv in sorted(b.get("results", {}).items())) or "none"
        say("build: %s %s: %s" % (b.get("project") or "-", "green" if b.get("green") else "not green", shown_results))
    else:
        say("build: %s, not required for a PR: %s" % (b.get("verdict"), b.get("note")))
    if not guard_ready():
        say("guard: the installed pr-guard has no foreign_accept: only BLOCK records until it is installed")
    if not diff:
        return
    if f.findings:
        say("findings (%d), each refusing PASS and FIXABLE:" % len(f.findings))
        for x in f.findings:
            say("- " + x)
    else:
        say("findings: none")


def comment_faults(c, creator):
    out = []
    if not c:
        return ["it is empty"]
    if len(c) > COMMENT_CAP:
        out.append("%d characters, over %d" % (len(c), COMMENT_CAP))
    if _sanitize.sanitize(c) != c:
        out.append("it holds control, bidi or zero-width characters")
    for m in URLISH.finditer(c):
        u = m.group(0).rstrip(".,;:!?)")
        try:
            p = urllib.parse.urlsplit(u if "://" in u else "https://" + u)
            good = p.scheme.lower() == "https" and (p.hostname or "") in ALLOWED_HOSTS
            good = good and not p.username and not p.password and p.port is None
        except ValueError:
            good = False
        if not good:
            out.append("a URL other than a build, src or bugzilla.opensuse.org one: %s" % u[:80])
    for m in MENTION.finditer(c):
        who = m.group(1).rstrip(".-")
        if who.lower() != creator.lower():
            out.append("an @-mention of %s, not of the creator %s" % (who, creator))
    for rx in (INTERNAL, WORK_NOTE, SCRIPT_NAMES):
        m = rx.search(c)
        if m:
            out.append('an internal tag ("%s")' % m.group(0)[:40])
    for ln in c.splitlines():
        m = GROUP_REVIEW.match(ln) or MERGE_OK.match(ln)
        if m:
            out.append('a bot directive ("%s")' % m.group(1)[:40])
    return [clean(x) for x in out]


def read_file(path, ident):
    try:
        with open(path, "rb") as fh:
            raw = fh.read(65537)
    except OSError as e:
        raise Usage("cannot read %s: %s" % (shown(path), e.strerror))
    if len(raw) > 65536:
        raise Usage("%s is over 64 KiB" % shown(path))
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Usage("%s is no UTF-8" % shown(path))
    first, _, rest = text.partition("\n")
    m = re.fullmatch(r"(PASS|FIXABLE|BLOCK) (\S+) key ([0-9a-f]{12})", first.rstrip())
    if not m:
        raise Usage("the first line of %s is no 'PASS|FIXABLE|BLOCK <ID> key <sha12>'" % shown(path))
    try:
        theirs = parse_id(m.group(2))
    except Usage:
        theirs = None
    if theirs != ident:
        raise Usage("the first line of %s names %s, not %s" % (shown(path), shown(m.group(2))[:80], ARGS[0]))
    return m.group(1), rest.strip(), m.group(3)


def write_stamp(kind, name, stamp):
    d = os.path.join(STATE, kind)
    os.makedirs(d, mode=0o700, exist_ok=True)
    final = os.path.join(d, name + ".json")
    fd, tmp = tempfile.mkstemp(prefix="." + name + ".", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(stamp, fh, indent=1, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, final)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    dfd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
    return final


def show(ident, tmp):
    f = derive(ident, tmp)
    report(f, diff=True)
    say("build %s" % (f.project or "-"))
    say("key %s" % f.key)
    return 0


def record(ident, verdict, comment, want, tmp):
    f = derive(ident, tmp)
    report(f, diff=False)
    say("build %s" % (f.project or "-"))
    if f.key != want:
        say("KEY MOVED: %s is key %s now, the review named key %s: run --show again and review what changed" % (f.label, f.key, want))
        return 3
    faults = comment_faults(comment, f.creator)
    if verdict != "BLOCK":
        refusals = f.findings + ["comment: " + x for x in faults]
        if not guard_ready():
            refusals.append("rollout: the installed pr-guard (%s) has no foreign_accept yet: only BLOCK records until it is installed" % GUARD)
        if refusals:
            say("REFUSED: %s for %s, nothing recorded:" % (verdict, f.label))
            for r in refusals:
                say("- " + r)
            return 1
    ok = not faults
    stamp = {
        "v": 1,
        "kind": f.kind,
        "id": f.sid,
        "creator": f.creator,
        "verdict": verdict,
        "key": f.key,
        "recorded": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scan": f.scan,
        "build": f.build,
        "findings": f.findings + ["comment: " + x for x in faults],
        "comment_sha256": hashlib.sha256(comment.encode("utf-8")).hexdigest() if ok else "",
        "comment": comment if ok else "",
    }
    stamp.update(f.part)
    name = f.sid if f.kind == "obs" else "%s_%s_%s" % ident[1:]
    try:
        path = write_stamp(f.kind, name, stamp)
    except OSError as e:
        say("NOT RECORDED: cannot write the stamp: %s" % e)
        return 5
    say("RECORDED: %s for %s, key %s: %s" % (verdict, f.label, f.key, path))
    for x in stamp["findings"]:
        say("- " + x)
    if ok:
        say("comment_sha256 %s: post exactly the recorded comment (the stamp's comment field)" % stamp["comment_sha256"])
    else:
        say("the comment breaks a rule (%s): the stamp allows no comment; fix it and record again" % "; ".join(faults))
    return 0


def main():
    tmp = None
    try:
        ident = parse_id(ARGS[0])
        if MODE == "--record":
            verdict, comment, want = read_file(ARGS[1], ident)
        tmp = tempfile.mkdtemp(prefix="incoming-review.", dir=os.environ.get("TMPDIR") or "/var/tmp")
        if MODE == "--show":
            return show(ident, tmp)
        return record(ident, verdict, comment, want, tmp)
    except Usage as e:
        print("incoming-review.sh: %s (usage: references/script-usage.md)" % e, file=sys.stderr)
        return 2
    except Lookup as e:
        say("LOOKUP FAILED: %s; nothing recorded" % e)
        return 5
    except Exception as e:  # a bug must not read as a verdict
        say("LOOKUP FAILED: internal error %s: %s; nothing recorded" % (type(e).__name__, e))
        return 5
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


sys.exit(main())
PY
rc=$?
case $rc in 0|1|2|3|5) exit "$rc" ;; esac
echo "incoming-review.sh: internal failure ($rc): nothing recorded" >&2
exit 5
