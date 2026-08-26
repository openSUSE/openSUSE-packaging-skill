"""Shared forge/registry probe helpers — a module, not a command.

Imported by upstream-probe.py (per-candidate by-DATE check) and outdated.py
(the bulk-sweep forge pass for names Repology/Anitya did not map). One home
for URL parsing, tag-prefix extraction, and GitHub/GitLab/PyPI/npm/crates.io
probes so the two commands cannot drift.

GitHub companion npm: when a spec already selected github.com/OWNER/REPO,
also probe npm `@OWNER/REPO` and `REPO` (404 is skip, not a failure). That is
the whole companion guess list — nothing else is invented.
"""
import json
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

TIMEOUT = 20
UA = "openSUSE-upstream-probe/1.0 (https://en.opensuse.org)"
# crates.io 403s a request that has no identifying User-Agent.
CRATES_UA = "openSUSE-upstream-probe/1.0 (https://en.opensuse.org; packaging-check)"

PRERELEASE = re.compile(r"(?:^|[.\-_~])(rc|alpha|beta|dev|pre|a\d+$|b\d+$)", re.I)
SNAPSHOT = re.compile(r"[+~](?:git|hg)\.?(\d{8})", re.I)

# Literal text before %{version} in a tags/archive URL. Order matters:
# /archive/refs/tags/PREFIX%{version} must hit the tags/ alternative, not
# swallow the path as an /archive/ prefix.
_TAG_PREFIX_RES = (
    re.compile(r"/(?:refs/)?tags/([^/]*?)%\{version\}", re.I),
    re.compile(r"/releases/download/([^/]*?)%\{version\}", re.I),
    re.compile(r"/-/archive/([^/]*?)%\{version\}", re.I),
    re.compile(r"/archive/([^/]*?)%\{version\}", re.I),
)


def http_json(url, headers=None, missing_ok=False, ua=None):
    req = urllib.request.Request(
        url,
        headers={"User-Agent": ua or UA, "Accept": "application/json",
                 **(headers or {})},
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        if missing_ok and e.code in (404, 422):
            return None
        raise


# ---------- GitHub: prefer gh api when authenticated (5000 req/h vs 60 anon)
_GH = None


def gh_ok():
    global _GH
    if _GH is None:
        try:
            _GH = subprocess.run(["gh", "auth", "status"], capture_output=True,
                                 timeout=15).returncode == 0
        except Exception:
            _GH = False
    return _GH


def gh_json(path):
    """GET a GitHub API path; returns parsed JSON or None on 404."""
    if gh_ok():
        r = subprocess.run(["gh", "api", path], capture_output=True, text=True,
                           timeout=30)
        if r.returncode != 0:
            # 404 = absent; 422 = "No commit found for SHA: <tag>" (a ref that
            # does not exist) — both are facts ("not there"), not failures
            if "404" in r.stderr or "Not Found" in r.stderr or "HTTP 422" in r.stderr:
                return None
            raise RuntimeError(f"gh api {path}: {r.stderr.strip()}")
        return json.loads(r.stdout)
    try:
        return http_json(f"https://api.github.com/{path}")
    except urllib.error.HTTPError as e:
        if e.code in (404, 422):
            return None
        raise


def parse_date(s):
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


def is_prerelease(v):
    return bool(PRERELEASE.search(v or ""))


def norm(v):
    # strip any non-digit prefix: "v1.2" -> "1.2", "flowgrind-0.8.2" -> "0.8.2"
    return re.sub(r"^[^0-9]*", "", v or "")


def _uniq(seq):
    seen, out = set(), []
    for x in seq:
        if x and x not in seen:
            seen.add(x)
            out.append(x)
    return out


# ---------- spec / URL parsing ------------------------------------------------
def spec_facts(text):
    name = ver = url = src = None
    for line in text.splitlines():
        m = re.match(r"^Name:\s*(\S+)", line, re.I)
        if m and not name:
            name = m.group(1)
        m = re.match(r"^Version:\s*(\S+)", line, re.I)
        if m and not ver:
            ver = m.group(1)
        m = re.match(r"^URL:\s*(\S+)", line, re.I)
        if m and not url:
            url = m.group(1)
        m = re.match(r"^Source0?:\s*(\S+)", line, re.I)
        if m and not src:
            src = m.group(1)
    return name, ver, url, src


def tag_prefix(url):
    """Literal prefix before %{version} in a tags/archive URL, or None.

    rust-v%{version} → 'rust-v'; v%{version} → 'v'. OBS `#/rename` fragments
    are ignored so the path, not the local filename, wins.
    """
    if not url or "%{version}" not in url.lower():
        return None
    main = url.split("#", 1)[0]
    for rx in _TAG_PREFIX_RES:
        m = rx.search(main)
        if m:
            return m.group(1)
    return None


def tag_matches_prefix(tag, prefix):
    """True if tag is `{prefix}` followed by a digit.

    startswith alone is wrong: prefix `rust-v` would accept `rust-vrust-v…`
    and a looser `rust` prefix would accept `rusty-v8-…`. No prefix → no
    filter (the spec did not declare a tag scheme).
    """
    if not prefix:
        return True
    if not tag or not tag.startswith(prefix):
        return False
    rest = tag[len(prefix):]
    return bool(rest) and rest[0].isdigit()


def parse_forge(cand):
    """Return (kind, host, name) for a single URL, or None."""
    if not cand:
        return None
    m = re.search(r"github\.com/([^/]+)/([^/#?]+)", cand)
    if m:
        return ("github", m.group(1), m.group(2).removesuffix(".git"))
    if "gitlab" in cand:
        host_m = re.search(r"(gitlab\.[^/]+)", cand)
        proj_m = re.search(
            r"gitlab\.[^/]+/([^#?]+?)(?:/-/|\.git|/archive|$)", cand)
        if host_m and proj_m:
            return ("gitlab", host_m.group(1), proj_m.group(1).strip("/"))
    npm = _parse_npm(cand)
    if npm:
        return ("npm", None, npm)
    m = re.search(r"(?:static\.)?crates\.io/crates/([^/#?]+)", cand)
    if m:
        return ("crates", None, m.group(1))
    if "pythonhosted.org" in cand or "pypi.org" in cand or "pypi.python.org" in cand:
        m = re.search(
            r"(?:packages/source/./|pypi\.org/(?:project|pypi)/)([A-Za-z0-9._-]+)",
            cand)
        if m:
            return ("pypi", None, m.group(1))
    return None


def _parse_npm(cand):
    """npm package name from registry.npmjs.org or npmjs.com/package/… URLs."""
    m = re.search(
        r"(?:www\.)?npmjs\.com/package/(@[^/]+/[^/#?]+|[^/#?]+)", cand)
    if m:
        return urllib.parse.unquote(m.group(1))
    m = re.search(r"registry\.npmjs\.org/(@[^/]+/[^/#?]+|[^/#?]+)", cand)
    if not m:
        return None
    name = urllib.parse.unquote(m.group(1))
    if not name or name in ("-", "-v1"):
        return None
    return name


# A registry that *serves the packaged tarball* outranks a code forge that
# merely hosts the sources. Source0 naming pythonhosted/npm/crates means the
# release artefact IS the registry upload, so the registry's newest version is
# the only one we can package -- a git tag ahead of it is not a release we can
# consume. Three real 2026-08-26 false positives came from date-merging the two:
# comfyui-frontend-package (PyPI 1.50.6 vs GitHub v1.53.2, a structural lag),
# cubesandbox (GitHub carries six parallel artefact tag streams, incl.
# guest-image-YYMMDD-N VM images), and any monorepo whose repo tag is not the
# sub-package's version.
REGISTRY_KINDS = ("pypi", "npm", "crates")


def source_registry(src):
    """(kind, host, name) if Source0 is served by a package registry, else None."""
    f = parse_forge(src)
    return f if f and f[0] in REGISTRY_KINDS else None


def pick_authoritative(rows, src):
    """The answering row that actually serves Source0, or None.

    rows: (kind, host, name, optional, facts) as collected by the callers.
    """
    target = source_registry(src)
    if not target:
        return None
    for row in rows:
        if (row[0], row[1], row[2]) == target and row[4]:
            return row
    return None


_SCM_URL_RE = re.compile(
    r'<param\s+name="url"\s*>\s*([^<\s]+)\s*</param>', re.I)
_SCM_REV_RE = re.compile(
    r'<param\s+name="revision"\s*>\s*([^<\s]+)\s*</param>', re.I)


def service_scm_url(text):
    """(url, revision) from a _service obs_scm/tar_scm block, else (None, None).

    A pinned-snapshot package often has no forge-resolvable spec at all --
    `URL:` is a project homepage and `Source0:` a bare local tarball name --
    while the real upstream sits in _service. Without this the probe reports
    "no source answered" forever (real case: monero, whose URL is get<name>.org
    and whose Source0 is <name>-<version>.tar.gz).
    """
    if not text:
        return (None, None)
    m = _SCM_URL_RE.search(text)
    if not m:
        return (None, None)
    rev = _SCM_REV_RE.search(text)
    return (m.group(1), rev.group(1) if rev else None)


def pick_forges(url, src, companions=True):
    """ALL distinct forges resolvable from Source0 and URL.

    A spec often points URL: at github and Source0: at pypi/npm — probe every
    one. Returns 4-tuples (kind, host, name, optional). GitHub companion npm
    names are optional (404 = skip).
    """
    explicit = []
    for cand in (src, url):
        f = parse_forge(cand)
        if f and f not in explicit:
            explicit.append(f)
    out = [(k, h, n, False) for k, h, n in explicit]
    if companions:
        seen = {(k, h, n) for k, h, n, _ in out}
        for kind, host, name in explicit:
            if kind != "github":
                continue
            for npm_name in (f"@{host}/{name}", name):
                t = ("npm", None, npm_name)
                if t not in seen:
                    seen.add(t)
                    out.append((*t, True))
    return out


def forge_how(kind, host, name):
    """Tag used in outdated.py output, analogous to anitya:mapped."""
    if kind == "github":
        return f"github:{host}/{name}"
    if kind == "gitlab":
        return f"gitlab:{name}"
    if kind == "npm":
        return f"npm:{name}"
    if kind == "crates":
        return f"crates:{name}"
    if kind == "pypi":
        return f"pypi:{name}"
    return kind


# ---------- backends -----------------------------------------------------------
def probe_pypi(name, packaged):
    d = http_json(f"https://pypi.org/pypi/{name}/json")
    releases = d.get("releases", {})

    def rel_date(v):
        files = releases.get(v) or []
        ds = [parse_date(f.get("upload_time_iso_8601")) for f in files
              if not f.get("yanked")]
        ds = [x for x in ds if x]
        return max(ds) if ds else None

    stable = [(v, rel_date(v)) for v in releases
              if not is_prerelease(v) and rel_date(v)]
    if not stable:
        raise RuntimeError(f"pypi {name}: no dated stable releases")
    latest_v, latest_d = max(stable, key=lambda x: x[1])
    return {"packaged_date": rel_date(packaged) or rel_date(norm(packaged)),
            "latest_stable": (latest_v, latest_d),
            "latest_tag": (latest_v, latest_d),
            "asset_note": "PyPI sdist/wheel (real release files)"}


def probe_npm(name, packaged, missing_ok=False):
    enc = urllib.parse.quote(name, safe="@")
    url = f"https://registry.npmjs.org/{enc}"
    try:
        d = http_json(url, missing_ok=missing_ok)
    except urllib.error.HTTPError as e:
        if missing_ok and e.code == 404:
            return None
        raise
    if not d:
        return None
    tags = d.get("dist-tags") or {}
    times = d.get("time") or {}
    versions = d.get("versions") or {}

    def vdate(v):
        return parse_date(times.get(v)) if v else None

    latest = tags.get("latest")
    if latest and is_prerelease(latest):
        latest = None
    if not latest:
        stable = [(v, vdate(v)) for v in versions
                  if not is_prerelease(v) and vdate(v)]
        if not stable:
            if missing_ok:
                return None
            raise RuntimeError(f"npm {name}: no dated stable releases")
        latest = max(stable, key=lambda x: x[1])[0]
    ld = vdate(latest)
    return {"packaged_date": vdate(packaged) or vdate(norm(packaged)),
            "latest_stable": (latest, ld),
            "latest_tag": (latest, ld),
            "asset_note": "npm packument (dist-tags.latest)"}


def probe_crates(name, packaged, missing_ok=False):
    url = f"https://crates.io/api/v1/crates/{urllib.parse.quote(name)}"
    try:
        d = http_json(url, missing_ok=missing_ok, ua=CRATES_UA)
    except urllib.error.HTTPError as e:
        if missing_ok and e.code == 404:
            return None
        raise
    if not d:
        return None
    crate = d.get("crate") or {}
    versions = d.get("versions") or []
    by_num = {v.get("num"): v for v in versions
              if v.get("num") and not v.get("yanked")}
    latest = crate.get("max_stable_version") or crate.get("newest_version")
    if latest and (is_prerelease(latest) or latest not in by_num):
        dated = [(v.get("num"), parse_date(v.get("created_at")))
                 for v in versions
                 if v.get("num") and not v.get("yanked")
                 and not is_prerelease(v.get("num"))
                 and parse_date(v.get("created_at"))]
        latest = max(dated, key=lambda x: x[1])[0] if dated else None
    if not latest:
        if missing_ok:
            return None
        raise RuntimeError(f"crates.io {name}: no stable version")
    ver = by_num.get(latest) or {}
    ld = parse_date(ver.get("created_at") or crate.get("updated_at"))
    pver = by_num.get(packaged) or by_num.get(norm(packaged)) or {}
    pd = parse_date(pver.get("created_at"))
    return {"packaged_date": pd,
            "latest_stable": (latest, ld),
            "latest_tag": (latest, ld),
            "asset_note": "crates.io crate (max_stable_version)"}


def probe_github(owner, repo, packaged, prefix=None):
    base = f"repos/{owner}/{repo}"

    def tag_date(tag):
        c = gh_json(f"{base}/commits/{urllib.parse.quote(tag, safe='')}")
        return parse_date(((c or {}).get("commit") or {}).get("committer", {})
                          .get("date")) if c else None

    out = {}
    snap = SNAPSHOT.search(packaged or "")
    if snap:
        out["packaged_date"] = datetime.strptime(snap.group(1), "%Y%m%d").replace(
            tzinfo=timezone.utc)
        head = gh_json(f"{base}/commits?per_page=1")
        out["head_date"] = parse_date(((head or [{}])[0].get("commit") or {})
                                      .get("committer", {}).get("date")) if head else None
    else:
        out["packaged_date"] = None
        cands = []
        if prefix:
            cands.append(f"{prefix}{packaged}")
        cands.extend([packaged, f"v{packaged}", norm(packaged),
                      f"{repo}-{packaged}"])
        for cand in _uniq(cands):
            d = tag_date(cand)
            if d:
                out["packaged_date"] = d
                break
    # Prefer /releases (skip prerelease/draft) over git-order tags?per_page=10.
    # /releases/latest is NOT used: GitHub can mark a prerelease as latest.
    rels = gh_json(f"{base}/releases?per_page=100") or []
    if isinstance(rels, dict):
        rels = []
    dated_rel = []
    for rel in rels:
        if rel.get("prerelease") or rel.get("draft"):
            continue
        tag = rel.get("tag_name") or ""
        if is_prerelease(tag) or not tag_matches_prefix(tag, prefix):
            continue
        d = parse_date(rel.get("published_at"))
        if d:
            dated_rel.append((tag, d, rel))
    if dated_rel:
        tag, d, rel = max(dated_rel, key=lambda x: x[1])
        out["latest_stable"] = (tag, d)
        out["asset_note"] = (f"{len(rel.get('assets') or [])} release asset(s)"
                             if rel.get("assets") else
                             "NO release assets — auto-archive only (autotools: "
                             "no configure -> autoreconf + autoconf/automake/libtool cost)")
    tags = gh_json(f"{base}/tags?per_page=20") or []
    if isinstance(tags, dict):
        tags = []
    dated = []
    n_dated = 0
    for t in tags:
        tname = t.get("name") or ""
        if not tag_matches_prefix(tname, prefix) or is_prerelease(tname):
            continue
        d = None
        c = t.get("commit") or {}
        if c.get("sha"):
            cc = gh_json(f"{base}/commits/{c['sha']}")
            d = parse_date(((cc or {}).get("commit") or {}).get("committer", {})
                           .get("date"))
        if d:
            dated.append((tname, d))
            n_dated += 1
            if n_dated >= 10:
                break
    if dated:
        out["latest_tag"] = max(dated, key=lambda x: x[1])
        if "latest_stable" not in out:
            out["latest_stable"] = out["latest_tag"]
            rt = gh_json(f"{base}/releases/tags/{out['latest_tag'][0]}")
            out["asset_note"] = ("release object present" if rt else
                                 "tag has NO release object — auto-archive only")
    if "latest_stable" not in out:
        raise RuntimeError(f"github {owner}/{repo}: no releases and no datable tags")
    return out


def probe_gitlab(host, proj, packaged, prefix=None):
    enc = urllib.parse.quote(proj, safe="")
    tags = http_json(f"https://{host}/api/v4/projects/{enc}/repository/tags")
    if not tags:
        raise RuntimeError(f"gitlab {proj}: no tags")

    def d(t):
        return parse_date((t.get("commit") or {}).get("committed_date"))

    dated = [(t.get("name"), d(t)) for t in tags if d(t)]
    matching = [(n, dd) for n, dd in dated if tag_matches_prefix(n, prefix)]
    pool = matching or dated
    stable = [x for x in pool if not is_prerelease(x[0])] or pool
    latest = max(stable, key=lambda x: x[1])
    cands = set()
    if prefix and packaged:
        cands.add(f"{prefix}{packaged}")
    if packaged:
        cands.update((packaged, f"v{packaged}", norm(packaged)))
    packaged_date = next((dd for n, dd in dated if n in cands), None)
    if packaged_date is None:
        packaged_date = next((dd for n, dd in dated
                              if norm(n) == norm(packaged)), None)
    return {"packaged_date": packaged_date, "latest_stable": latest,
            "latest_tag": max(dated, key=lambda x: x[1]),
            "asset_note": "gitlab: check the release for uploaded assets vs auto-archive"}


def unpack_forge(spec):
    if len(spec) == 4:
        return spec
    kind, host, name = spec
    return kind, host, name, False


def probe_one(spec, packaged, prefix=None):
    """Dispatch one pick_forges tuple. Optional companions return None on 404."""
    kind, host, name, optional = unpack_forge(spec)
    try:
        if kind == "pypi":
            return probe_pypi(name, packaged)
        if kind == "github":
            return probe_github(host, name, packaged, prefix=prefix)
        if kind == "gitlab":
            return probe_gitlab(host, name, packaged, prefix=prefix)
        if kind == "npm":
            return probe_npm(name, packaged, missing_ok=optional)
        if kind == "crates":
            return probe_crates(name, packaged, missing_ok=optional)
        raise RuntimeError(f"unknown forge {kind}")
    except urllib.error.HTTPError as e:
        if optional and e.code == 404:
            return None
        raise


def prefer_scoped_npm(rows):
    """Drop an unscoped npm *companion* when `@owner/repo` also answered.

    Unscoped `codex` on npm is a different 2012 package from `@openai/codex`;
    merging it by date would be a name-collision of the same class as Anitya's.
    Explicit npm Source0/URL (optional=False) is kept.
    """
    scoped_pkgs = set()
    for kind, host, name, optional, facts in rows:
        if kind == "npm" and facts and name.startswith("@") and "/" in name:
            scoped_pkgs.add(name.split("/", 1)[1])
    keep = []
    for row in rows:
        kind, host, name, optional, facts = row
        if (kind == "npm" and optional and "/" not in (name or "")
                and name in scoped_pkgs):
            continue
        keep.append(row)
    return keep


def label_results(rows, with_index=False):
    """rows: (kind, host, name, optional, facts) → {label: facts}.

    with_index also returns {(kind, host, name): label} so a caller can find
    the label of a specific source (e.g. the authoritative one) without
    re-deriving the naming rules.
    """
    kinds = [r[0] for r in rows]
    results, index = {}, {}
    for kind, host, name, optional, facts in rows:
        if kind == "npm" and kinds.count("npm") > 1:
            label = f"npm:{name}"
        else:
            label = kind
        if label in results:
            label = f"{kind}:{name}"
        results[label] = facts
        index[(kind, host, name)] = label
    return (results, index) if with_index else results
