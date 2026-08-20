#!/usr/bin/env python3
"""Repology "outdated in openSUSE Tumbleweed" sweep, intersected with your packages.

Pulls every project Repology marks outdated in opensuse_tumbleweed (paginated),
then keeps only those whose TW source-package name is in your set, printing
  <srcname>  <packaged-version> -> <newest-version>

Your package set: pass package names on stdin or via --names FILE (one per line,
e.g. the second column of my-packages.sh). With no names, prints the full TW
outdated list (large).

REPOLOGY LAGS PUBLISHED TUMBLEWEED, WHICH LAGS THE DEVEL PROJECT, so a large
fraction of raw hits are false positives — the update already landed in Factory
and Repology just hasn't caught up. By default (when filtering by --names/stdin)
this script therefore cross-checks every hit against the live Factory `Version:`
and SUPPRESSES the ones Factory already ships at the "newest" version, so the
output is actually actionable instead of a wall of known-lag noise. Use
--no-factory-check to skip that (raw Repology view). The cross-check needs a
working `osc` against api.opensuse.org.

REPOLOGY'S "newest" IS ITSELF ONLY "newest packaged in some tracked repo" — an
upstream release that no distro has packaged yet is invisible to the sweep
(real case: libdispatch 6.3.3 was released upstream, every repo had 6.3.2, so
Repology reported "newest" and the package never appeared here). Brand-new TW
packages may not be in Repology's index at all. To cover both blind spots,
this script probes further sources at the same time as the Repology sweep:

  * Anitya (release-monitoring.org) over names Repology did not flag; extra
    hits print tagged [anitya:mapped] / [anitya:name-match]. A name-collision
    across same-named Anitya projects is unknown, not max(version).
  * Then a forge pass over names that still have no mapping: one `osc cat` of
    the Factory spec (Version, URL, Source0 together), Anitya retried with
    homepage=URL ([anitya:homepage]), and if still unmapped, GitHub/GitLab/
    PyPI/npm/crates.io from URL/Source0 plus GitHub→npm @owner/repo
    companions ([github:…]/[npm:…]/[crates:…]). Skip names with no URL/Source.

Anitya has no release DATES; forge hits are still candidates to verify, never
confirmed updates. --no-anitya skips Anitya and the homepage retry (it needs
the reference-project cross-check, so --no-factory-check also disables it).
--no-forge skips the GitHub/npm/crates probe (default ON).

Surviving candidates are still CANDIDATES, not confirmed updates — verify before
acting (see references/triage.md): compare by tag/commit DATE not version string,
watch for multi-track upstreams (LTS lines, parallel sonames) and deliberately
pinned packages. Known false positives stay flagged here.

Usage: my-packages.sh --... | cut -f2 | outdated.py
       outdated.py --names /tmp/names.txt
       outdated.py --names /tmp/names.txt --no-anitya          # Repology + forge
       outdated.py --names /tmp/names.txt --no-forge           # Repology + Anitya
       outdated.py --names /tmp/names.txt --no-factory-check   # raw Repology
"""
import sys, json, time, urllib.request, urllib.error, argparse, subprocess, re
import os
from collections import namedtuple
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _sanitize    # escape/Unicode-smuggling filter for third-party text

try:
    import _anitya          # sibling module; see scripts/_anitya.py
except ImportError:
    _anitya = None
try:
    import _forges          # sibling module; see scripts/_forges.py
except ImportError:
    _forges = None

ap = argparse.ArgumentParser()
ap.add_argument("--names", help="file of package names (default: stdin)")
ap.add_argument("--repo", default="opensuse_tumbleweed")
ap.add_argument("--ua", default="osc-update-check/1.0")
ap.add_argument("--project", default="openSUSE:Factory",
                help="reference project whose live Version: confirms a hit (default openSUSE:Factory)")
ap.add_argument("--no-factory-check", action="store_true",
                help="skip the live cross-check; print every raw Repology hit (incl. lag false positives)")
ap.add_argument("--no-anitya", action="store_true",
                help="skip the release-monitoring.org pass and the homepage-from-spec retry")
ap.add_argument("--no-forge", action="store_true",
                help="skip the GitHub/GitLab/PyPI/npm/crates.io pass over unmapped names")
args = ap.parse_args()

src = open(args.names) if args.names else (sys.stdin if not sys.stdin.isatty() else None)
mine = set(l.strip() for l in src if l.strip()) if src else None

# Kick off the release-monitoring.org lookups for the WHOLE name set right
# away, so they run while the (slow, paginated) Repology sweep downloads —
# all sources are probed at the same time; results are filtered when printed.
anitya_futs = {}
if (_anitya is not None and mine
        and not args.no_anitya and not args.no_factory_check):
    def _anitya_lookup(pkg):
        try:
            return _anitya.latest_stable(pkg)
        except _anitya.AnityaError as e:
            return ("__failed__", str(e))
    _anitya_pool = ThreadPoolExecutor(max_workers=6)
    anitya_futs = {p: _anitya_pool.submit(_anitya_lookup, p) for p in sorted(mine)}

def fetch(bound):
    url = f"https://repology.org/api/v1/projects/{bound}?inrepo={args.repo}&outdated=1"
    # Repology rate-limits aggressively (HTTP 429) on the paginated sweep;
    # honor Retry-After / back off instead of dying mid-pagination.
    for attempt in range(4):
        req = urllib.request.Request(url, headers={"User-Agent": args.ua})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            if e.code in (429, 502, 503, 504) and attempt < 3:
                try:
                    delay = int(e.headers.get("Retry-After") or 0)
                except ValueError:
                    delay = 0
                delay = delay or 5 * 3 ** attempt
                sys.stderr.write(f"WARNING: HTTP {e.code} from Repology at "
                                 f"'{bound or '(start)'}', retrying in {delay}s\n")
                time.sleep(delay)
                continue
            raise

results, bound = {}, ""
while True:
    data = fetch(bound)
    if not data:
        break
    results.update(data)
    last = sorted(data)[-1]
    if len(data) < 200:
        break
    bound = last + "/"
    time.sleep(0.4)

hits, seen = [], set()
for proj, pkgs in results.items():
    tw = [p for p in pkgs if p.get("repo") == args.repo]
    if not tw:
        continue
    # Prefer a real 'newest' release; fall back to 'devel' (pre-release) ONLY
    # when no newest exists, and tag the fallback so triage sees it — the
    # first-in-list-order pick used to let a preceding rc/beta become the
    # proposed target version.
    newest = next((p["version"] for p in pkgs
                   if p.get("status") == "newest" and p.get("version")), None)
    if newest is not None:
        newest_disp = newest
    else:
        dev = next((p["version"] for p in pkgs
                    if p.get("status") == "devel" and p.get("version")), None)
        newest, newest_disp = (dev, f"{dev} (devel)") if dev else ("?", "?")
    for p in tw:
        s = p.get("srcname") or p.get("binname") or proj
        if (mine is None or s in mine) and s not in seen:
            seen.add(s)
            hits.append((s, p.get("version"), newest, newest_disp))

# Cross-check against the live reference project to drop Repology-lag false positives.
Ref = namedtuple("Ref", "status version url src")

def ref_spec(pkg):
    """One osc cat: Version, URL, Source0. status: ok | absent | failed.
    A network hiccup / osc failure must NOT be conflated with 'not in project'."""
    try:
        r = subprocess.run(["osc", "cat", args.project, pkg, f"{pkg}.spec"],
                           capture_output=True, text=True, timeout=30)
    except Exception:
        return Ref("failed", None, None, None)
    if r.returncode != 0:
        if "404" in (r.stderr or ""):
            return Ref("absent", None, None, None)
        return Ref("failed", None, None, None)
    if _forges:
        _n, ver, url, src = _forges.spec_facts(r.stdout)
    else:
        ver = url = src = None
        for line in r.stdout.splitlines():
            m = re.match(r"^Version:\s*(\S+)", line)
            if m and not ver:
                ver = m.group(1)
            m = re.match(r"^URL:\s*(\S+)", line, re.I)
            if m and not url:
                url = m.group(1)
            m = re.match(r"^Source0?:\s*(\S+)", line, re.I)
            if m and not src:
                src = m.group(1)
    if not ver:
        return Ref("absent", None, url, src)
    return Ref("ok", ver, url, src)

do_check = (mine is not None) and not args.no_factory_check
refv = {}
if do_check and hits:
    with ThreadPoolExecutor(max_workers=8) as ex:
        refv = dict(zip((h[0] for h in hits),
                        ex.map(ref_spec, (h[0] for h in hits))))

candidates, suppressed = [], []
for s, cur, new, new_disp in hits:
    ref = refv.get(s)
    status, fv = (ref.status, ref.version) if ref else (None, None)
    if do_check and status == "ok" and new != "?" and fv == new:
        suppressed.append((s, fv))          # reference already at newest -> Repology lag
    else:
        candidates.append((s, cur, new_disp, status, fv))

shortprj = args.project.split(":")[-1] or args.project
if do_check:
    print(f"# {len(candidates)} candidate(s) after {args.project} cross-check, "
          f"{len(suppressed)} suppressed as already-current — still VERIFY each (date, not string)")
else:
    print(f"# {len(candidates)} outdated candidate(s) — VERIFY each (date, not version string)")

for s, cur, new_disp, status, fv in sorted(candidates, key=lambda x: x[0].lower()):
    extra = ""
    if do_check:
        if status == "failed":
            extra = "   (check failed)"
        elif status == "absent":
            extra = f"   (not in {args.project})"
        elif fv != cur:
            extra = f"   ({shortprj}={fv})"
    # version strings come from Repology (any tracked repo's packager can
    # influence them) — sanitize before display
    print(_sanitize.sanitize(f"{s:32} {str(cur):24} -> {new_disp}{extra}"))

if do_check and suppressed:
    print(f"# suppressed (already at newest in {args.project}): "
          + " ".join(f"{s}={fv}" for s, fv in sorted(suppressed)))

# ---- release-monitoring.org (Anitya) pass over the REST of the set ----------
# Repology's "newest" is only "newest packaged in some tracked repo"; a release
# nobody has packaged yet never shows up above (real case: libdispatch 6.3.3).
# Anitya tracks upstreams directly, so check every name Repology did NOT flag —
# including the suppressed ones (Repology's "newest" itself may be stale).
lookups, a_hits, a_odd, failed = {}, [], [], []
if do_check and not args.no_anitya:
    if _anitya is None:
        sys.stderr.write("WARNING: _anitya.py not found next to this script — "
                         "release-monitoring.org pass SKIPPED\n")
    else:
        # exclude names Repology already flagged as candidates; keep the
        # suppressed ones (Repology's own "newest" may be stale)
        rest = sorted(set(anitya_futs) - {c[0] for c in candidates})
        for pkg in rest:
            res = anitya_futs[pkg].result()
            if res[0] == "__failed__":
                failed.append(pkg)
            elif res[0]:
                lookups[pkg] = res
        if anitya_futs:
            _anitya_pool.shutdown()

        need_ref = [p for p in lookups if p not in refv]
        if need_ref:
            with ThreadPoolExecutor(max_workers=8) as ex:
                refv.update(zip(need_ref, ex.map(ref_spec, need_ref)))

        for pkg, (raw, how) in sorted(lookups.items()):
            ref = refv.get(pkg)
            if not ref or ref.status != "ok":
                continue        # absent from / unreadable in the reference project
            fv = ref.version
            cmp = _anitya.vercmp(raw, fv)
            if cmp == 1:
                a_hits.append((pkg, fv, raw, how))
            elif cmp is None and _anitya.norm(raw) != _anitya.norm(fv):
                a_odd.append((pkg, fv, raw))

        print(f"# anitya (release-monitoring.org) pass over {len(rest)} name(s) "
              f"Repology did not flag: {len(a_hits)} additional candidate(s) — "
              f"anitya has NO dates, so VERIFY each before acting")
        for pkg, fv, raw, how in a_hits:
            disp = _anitya.norm(raw)
            rawnote = f" = {raw}" if disp != raw else ""
            # anitya version strings are upstream/mapping-controlled — sanitize
            print(_sanitize.sanitize(
                f"{pkg:32} {str(fv):24} -> {disp} [anitya:{how}{rawnote}]"))
        if a_odd:
            print(_sanitize.sanitize(
                "# anitya: incomparable version schemes (check by hand): "
                + " ".join(f"{p}({fv} vs {raw})" for p, fv, raw in a_odd)))
        if failed:
            print(f"# anitya: {len(failed)} lookup(s) FAILED (network/anti-bot) "
                  f"— NOT checked: " + " ".join(failed))
elif anitya_futs:
    _anitya_pool.shutdown()

# ---- homepage retry + forge pass over names still without a mapping ----------
# Only names Repology did not flag AND Anitya mapped-or-name-match did not
# already hit. One spec cat per remaining name (Version/URL/Source0 together).
hp_hits, forge_hits, forge_failed = [], [], []
do_homepage = do_check and not args.no_anitya and _anitya is not None
do_forge = do_check and not args.no_forge and _forges is not None
if do_check and not args.no_forge and _forges is None:
    sys.stderr.write("WARNING: _forges.py not found next to this script — "
                     "forge pass SKIPPED\n")
if (do_homepage or do_forge) and mine:
    anitya_resolved = set(lookups)
    remaining = sorted(set(mine) - {c[0] for c in candidates} - anitya_resolved)
    need_ref = [p for p in remaining if p not in refv]
    if need_ref:
        with ThreadPoolExecutor(max_workers=8) as ex:
            refv.update(zip(need_ref, ex.map(ref_spec, need_ref)))

    still = []
    for pkg in remaining:
        ref = refv.get(pkg)
        if not ref or ref.status != "ok" or not (ref.url or ref.src):
            continue
        still.append(pkg)

    if do_homepage:
        def _hp_lookup(pkg):
            ref = refv[pkg]
            hp = ref.url if ref.url and "%" not in ref.url else None
            if not hp:
                return (None, None)
            try:
                return _anitya.latest_stable(pkg, homepage=hp)
            except _anitya.AnityaError as e:
                return ("__failed__", str(e))
        with ThreadPoolExecutor(max_workers=6) as ex:
            hp_res = dict(zip(still, ex.map(_hp_lookup, still)))
        mapped_current = set()
        for pkg in still:
            raw, how = hp_res.get(pkg, (None, None))
            if raw == "__failed__":
                continue
            if not raw:
                continue
            ref = refv[pkg]
            cmp = _anitya.vercmp(raw, ref.version)
            if cmp == 1:
                hp_hits.append((pkg, ref.version, raw, how or "homepage"))
                mapped_current.add(pkg)
            else:
                # mapping exists (current or incomparable) — not a forge target
                mapped_current.add(pkg)
        still = [p for p in still if p not in mapped_current]

    if do_forge:
        def _forge_lookup(pkg):
            ref = refv[pkg]
            prefix = _forges.tag_prefix(ref.src) or _forges.tag_prefix(ref.url)
            rows, err = [], None
            for spec in _forges.pick_forges(ref.url, ref.src):
                kind, host, name, optional = _forges.unpack_forge(spec)
                try:
                    facts = _forges.probe_one(spec, ref.version, prefix=prefix)
                except (urllib.error.URLError, OSError, RuntimeError, ValueError) as e:
                    if not optional and err is None:
                        err = f"{kind}: {e}"
                    continue
                if facts and facts.get("latest_stable"):
                    rows.append((kind, host, name, optional, facts))
            rows = _forges.prefer_scoped_npm(rows)
            if not rows:
                return ("__failed__" if err else None, err)
            # merge by DATE across answering forges
            best = None
            for kind, host, name, optional, facts in rows:
                v, d = facts.get("latest_stable") or (None, None)
                if not v:
                    continue
                if best is None or (d and (best[1] is None or d > best[1])):
                    best = (v, d, kind, host, name)
            if not best:
                return (None, None)
            v, d, kind, host, name = best
            return (v, _forges.forge_how(kind, host, name))

        with ThreadPoolExecutor(max_workers=6) as ex:
            f_res = dict(zip(still, ex.map(_forge_lookup, still)))
        for pkg in still:
            raw, how = f_res.get(pkg, (None, None))
            if raw == "__failed__":
                forge_failed.append(pkg)
                continue
            if not raw or not _anitya:
                continue
            ref = refv[pkg]
            cmp = _anitya.vercmp(raw, ref.version)
            if cmp == 1:
                forge_hits.append((pkg, ref.version, raw, how))

    print(f"# forge/homepage pass over {len(remaining)} unmapped name(s): "
          f"{len(hp_hits) + len(forge_hits)} additional candidate(s) — "
          f"VERIFY each before acting")
    for pkg, fv, raw, how in hp_hits:
        disp = _anitya.norm(raw) if _anitya else raw
        rawnote = f" = {raw}" if disp != raw else ""
        tag = how if str(how).startswith("anitya:") else f"anitya:{how}"
        print(_sanitize.sanitize(
            f"{pkg:32} {str(fv):24} -> {disp} [{tag}{rawnote}]"))
    for pkg, fv, raw, how in forge_hits:
        disp = _anitya.norm(raw) if _anitya else raw
        rawnote = f" = {raw}" if disp != raw else ""
        print(_sanitize.sanitize(
            f"{pkg:32} {str(fv):24} -> {disp} [{how}{rawnote}]"))
    if forge_failed:
        print(f"# forge: {len(forge_failed)} lookup(s) FAILED "
              f"— NOT checked: " + " ".join(forge_failed))
