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
Repology reported "newest" and the package never appeared here). To cover that
blind spot, this script probes BOTH sources at the same time: the Anitya
lookups for the whole name set run concurrently with the Repology sweep, and
every name Repology did NOT flag is checked against release-monitoring.org,
which tracks upstreams directly; extra hits print tagged [anitya:...]. Anitya
has no release DATES, so those are candidates to verify, never confirmed
updates. Skip the pass with --no-anitya (it needs the reference-project
cross-check, so --no-factory-check also disables it).

Surviving candidates are still CANDIDATES, not confirmed updates — verify before
acting (see references/triage.md): compare by tag/commit DATE not version string,
watch for multi-track upstreams (LTS lines, parallel sonames) and deliberately
pinned packages. Known false positives stay flagged here.

Usage: my-packages.sh --... | cut -f2 | outdated.py
       outdated.py --names /tmp/names.txt
       outdated.py --names /tmp/names.txt --no-anitya          # Repology only
       outdated.py --names /tmp/names.txt --no-factory-check   # raw Repology
"""
import sys, json, time, urllib.request, urllib.error, argparse, subprocess, re
import os
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _sanitize    # escape/Unicode-smuggling filter for third-party text

try:
    import _anitya          # sibling module; see scripts/_anitya.py
except ImportError:
    _anitya = None

ap = argparse.ArgumentParser()
ap.add_argument("--names", help="file of package names (default: stdin)")
ap.add_argument("--repo", default="opensuse_tumbleweed")
ap.add_argument("--ua", default="osc-update-check/1.0")
ap.add_argument("--project", default="openSUSE:Factory",
                help="reference project whose live Version: confirms a hit (default openSUSE:Factory)")
ap.add_argument("--no-factory-check", action="store_true",
                help="skip the live cross-check; print every raw Repology hit (incl. lag false positives)")
ap.add_argument("--no-anitya", action="store_true",
                help="skip the release-monitoring.org pass over the names Repology did not flag")
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
def ref_version(pkg):
    """Returns (status, version): ('ok', v) | ('absent', None) | ('failed', None).
    A network hiccup / osc failure must NOT be conflated with 'not in project'."""
    try:
        r = subprocess.run(["osc", "cat", args.project, pkg, f"{pkg}.spec"],
                           capture_output=True, text=True, timeout=30)
    except Exception:
        return ("failed", None)
    if r.returncode != 0:
        # 404 (package/file absent) vs any other failure (auth, network, 5xx)
        if "404" in (r.stderr or ""):
            return ("absent", None)
        return ("failed", None)
    for line in r.stdout.splitlines():
        m = re.match(r"^Version:\s*(\S+)", line)
        if m:
            return ("ok", m.group(1))
    return ("absent", None)  # in project but no parseable Version

do_check = (mine is not None) and not args.no_factory_check
refv = {}
if do_check and hits:
    with ThreadPoolExecutor(max_workers=8) as ex:
        refv = dict(zip((h[0] for h in hits),
                        ex.map(ref_version, (h[0] for h in hits))))

candidates, suppressed = [], []
for s, cur, new, new_disp in hits:
    status, fv = refv.get(s, (None, None))
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
if do_check and not args.no_anitya:
    if _anitya is None:
        sys.stderr.write("WARNING: _anitya.py not found next to this script — "
                         "release-monitoring.org pass SKIPPED\n")
    else:
        # exclude names Repology already flagged as candidates; keep the
        # suppressed ones (Repology's own "newest" may be stale)
        rest = sorted(set(anitya_futs) - {c[0] for c in candidates})
        lookups, failed = {}, []
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
                refv.update(zip(need_ref, ex.map(ref_version, need_ref)))

        a_hits, a_odd = [], []
        for pkg, (raw, how) in sorted(lookups.items()):
            status, fv = refv.get(pkg, (None, None))
            if status != "ok":
                continue        # absent from / unreadable in the reference project
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
