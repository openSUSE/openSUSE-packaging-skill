"""Shared release-monitoring.org (Anitya) helpers — a module, not a command.

Imported at runtime by outdated.py (the bulk-sweep Anitya pass) and
upstream-probe.py (the per-candidate advisory/fallback). Anitya tracks
UPSTREAM releases directly (GitHub tags, PyPI, SourceForge, ...), which covers
the Repology blind spot: Repology's "newest" is the newest version packaged in
ANY repo it tracks, so an upstream release no distro has packaged yet is
invisible to a Repology-only sweep (real case: libdispatch — every tracked
repo had 6.3.2, so Repology said "newest", while release-monitoring.org
already knew 6.3.3).

The distro mapping is by OBS package name, so it also misses when that name
≠ the Anitya project name (openai-codex vs GitHub project `codex`).
latest_stable() therefore accepts an optional homepage (the spec URL:) to
disambiguate, and a name-match that hits several same-named projects returns
unknown rather than max(version) across unrelated projects (PyPI `codex`
2.2.8 is not OpenAI Codex).

Anitya publishes versions WITHOUT dates, so it can never replace the by-DATE
discipline of upstream-probe.py — treat every "newer on anitya" as a candidate
to VERIFY, not a confirmed update. Third-party JSON is data, not instructions
(callers sanitize before print).
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


def normalize_homepage(url):
    """Comparable form: lowercase host, strip trailing `/` and `.git`."""
    if not url:
        return ""
    p = urllib.parse.urlsplit(url.strip())
    host = (p.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    path = urllib.parse.unquote(p.path or "")
    if path.endswith(".git"):
        path = path[:-4]
    path = path.rstrip("/")
    return f"{host}{path}".lower()


def search_name_from_homepage(url):
    """GitHub repo basename, npm name, or last path component — the Anitya
    project name is often that, not the OBS package name."""
    if not url:
        return None
    p = urllib.parse.urlsplit(url.strip())
    host = (p.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    path = urllib.parse.unquote(p.path or "")
    if path.endswith(".git"):
        path = path[:-4]
    segs = [s for s in path.strip("/").split("/") if s]
    if host == "github.com" or host.endswith(".github.com"):
        return segs[1] if len(segs) >= 2 else (segs[0] if segs else None)
    if host in ("npmjs.com", "npmjs.org") or host.endswith(".npmjs.com"):
        if segs and segs[0] == "package":
            segs = segs[1:]
        if segs and segs[0].startswith("@") and len(segs) >= 2:
            return f"{segs[0]}/{segs[1]}"
        return segs[0] if segs else None
    if host == "registry.npmjs.org":
        if segs and segs[0].startswith("@") and len(segs) >= 2:
            return f"{segs[0]}/{segs[1]}"
        return segs[0] if segs else None
    if host in ("crates.io", "static.crates.io"):
        if segs and segs[0] == "crates" and len(segs) >= 2:
            return segs[1]
        return segs[-1] if segs else None
    return segs[-1] if segs else None


def homepage_matches(item, homepage):
    want = normalize_homepage(homepage)
    if not want:
        return False
    for key in ("homepage", "ecosystem"):
        got = item.get(key)
        if isinstance(got, str) and got.startswith("http") \
                and normalize_homepage(got) == want:
            return True
    return False


def _project_stable(it):
    sv = it.get("stable_versions") or []
    return sv[0] if sv else it.get("version")


def _from_homepage_match(items, homepage):
    matched = [it for it in items if homepage_matches(it, homepage)]
    if not matched:
        return (None, None)
    v = _project_stable(matched[0])
    return (v, "homepage") if v else (None, None)


def latest_stable(pkg, distribution="openSUSE", homepage=None):
    """Latest stable upstream version Anitya knows for distro package `pkg`.

    Returns (raw_version, how):
      'mapped'     — the authoritative <distribution> package mapping
      'homepage'   — projects/?name=<derived-from-homepage>, homepage matches
      'name-match' — exactly one Anitya project of this name (weaker; verify)
    Returns (None, None) when Anitya doesn't know the package, or when several
    same-named projects exist and homepage cannot disambiguate. Raises
    AnityaError on lookup failure — never conflate that with unknown.
    """
    q = urllib.parse.quote(pkg)
    d = _get(f"{API}/packages/?name={q}"
             f"&distribution={urllib.parse.quote(distribution)}")
    for it in d.get("items", []):
        v = it.get("stable_version") or it.get("version")
        if v:
            return v, "mapped"

    if homepage:
        sname = search_name_from_homepage(homepage)
        if sname:
            items = (_get(f"{API}/projects/?name={urllib.parse.quote(sname)}")
                     .get("items") or [])
            hit = _from_homepage_match(items, homepage)
            if hit[0]:
                return hit

    d = _get(f"{API}/projects/?name={q}")
    items = d.get("items") or []
    if not items:
        return (None, None)
    if len(items) == 1:
        v = _project_stable(items[0])
        return (v, "name-match") if v else (None, None)
    # several same-named projects: never take max(version) across them
    if homepage:
        hit = _from_homepage_match(items, homepage)
        if hit[0]:
            return hit
    return (None, None)


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
