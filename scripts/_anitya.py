"""Shared release-monitoring.org (Anitya) helpers — a module, not a command.

Imported at runtime by outdated.py (the bulk-sweep Anitya pass) and
upstream-probe.py (the per-candidate advisory/fallback). Anitya tracks
UPSTREAM releases directly (GitHub tags, PyPI, SourceForge, ...), which covers
the Repology blind spot: Repology's "newest" is the newest version packaged in
ANY repo it tracks, so an upstream release no distro has packaged yet is
invisible to a Repology-only sweep (real case: libdispatch — every tracked
repo had 6.3.2, so Repology said "newest", while release-monitoring.org
already knew 6.3.3).

Anitya publishes versions WITHOUT dates, so it can never replace the by-DATE
discipline of upstream-probe.py — treat every "newer on anitya" as a candidate
to VERIFY, not a confirmed update.
"""
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://release-monitoring.org/api/v2"
UA = "openSUSE-update-check/1.0"


class AnityaError(RuntimeError):
    """Lookup FAILED (network/gateway/anti-bot) — never conflate with 'unknown
    to Anitya' (that is a (None, None) return), and never with 'current'."""


def _get(url):
    last = None
    for attempt in range(3):
        req = urllib.request.Request(url, headers={"User-Agent": UA,
                                                   "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read().decode()
        except urllib.error.HTTPError as e:
            if e.code in (429, 502, 503, 504) and attempt < 2:
                try:
                    delay = int(e.headers.get("Retry-After") or 0)
                except ValueError:
                    delay = 0
                time.sleep(delay or 3 * 3 ** attempt)
                last = e
                continue
            raise AnityaError(f"HTTP {e.code} from {url}") from e
        except OSError as e:
            raise AnityaError(f"{e} for {url}") from e
        if body.lstrip().startswith("<"):
            # Anubis anti-bot HTML challenge instead of JSON — the API is
            # (temporarily) gated. Fail loudly; a silent 'current' here would
            # hide real updates.
            raise AnityaError("release-monitoring.org returned an HTML "
                              "challenge page instead of JSON (anti-bot gate)")
        return json.loads(body)
    raise AnityaError(f"gave up after retries: {last}")


def latest_stable(pkg, distribution="openSUSE"):
    """Latest stable upstream version Anitya knows for distro package `pkg`.

    Returns (raw_version, how): how is 'mapped' (the authoritative
    <distribution> package mapping) or 'name-match' (exact Anitya
    project-name fallback — weaker, the project may be a different thing with
    the same name; verify). Returns (None, None) when Anitya doesn't know the
    package at all. Raises AnityaError on lookup failure.
    """
    q = urllib.parse.quote(pkg)
    d = _get(f"{API}/packages/?name={q}"
             f"&distribution={urllib.parse.quote(distribution)}")
    for it in d.get("items", []):
        v = it.get("stable_version") or it.get("version")
        if v:
            return v, "mapped"
    d = _get(f"{API}/projects/?name={q}")
    best = None
    for it in d.get("items", []):
        sv = it.get("stable_versions") or []
        v = sv[0] if sv else it.get("version")
        if v and (best is None or (vercmp(v, best) or 0) > 0):
            best = v
    return (best, "name-match") if best else (None, None)


_RELEASE_SUFFIX = re.compile(r"[-_.](release|final)$", re.I)


def norm(v):
    """Comparable core of a version string: strip non-digit prefixes
    ("v1.2", "swift-6.3.3"), release-tag suffixes ("6.3.3-RELEASE"), and
    snapshot/rebuild tails ("1.2.3~git20240505", "1.2.3+ds")."""
    if not v:
        return v
    v = re.sub(r"^[^0-9]*", "", v.strip())
    v = _RELEASE_SUFFIX.sub("", v)
    return re.split(r"[~+]", v)[0]


def vercmp(a, b):
    """-1/0/1 comparing the numeric fields of norm()ed versions (shorter side
    zero-padded, so 6.3 == 6.3.0). Returns None when either side has no
    digits — never guess on incomparable schemes. Letter suffixes ("1.2.3a")
    are ignored, deliberately erring toward NOT flagging."""
    ta = tuple(int(x) for x in re.findall(r"\d+", norm(a) or ""))
    tb = tuple(int(x) for x in re.findall(r"\d+", norm(b) or ""))
    if not ta or not tb:
        return None
    n = max(len(ta), len(tb))
    ta += (0,) * (n - len(ta))
    tb += (0,) * (n - len(tb))
    return (ta > tb) - (ta < tb)
