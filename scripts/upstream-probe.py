#!/usr/bin/env python3
"""Single-package "real latest upstream by DATE" probe with prerelease filtering.

Mechanizes the per-candidate verification from references/triage.md (the
Repology false-positive discipline): a higher version NUMBER can be an OLDER
release — projects renumber (flowgrind's packaged 0.8.2 is from 2021, its
"newer" 0.12 tag from 2009), so the decisive check is the tag/upload DATE,
never a string/semver sort. Complements outdated.py (the bulk sweep); this is
the per-candidate deep check.

Traps encoded here (from triage.md):
  * GitHub `tags?per_page=1` returns git/alphabetical order, NOT chronological
    — never trusted alone; every tag is dated via its commit.
  * Dual-track tag namespaces (`rust-v*` vs `rusty-v8-*`, npm vs rust): the
    prefix before `%{version}` in a tags/archive Source0 is required, and
    only tags where that prefix is followed by a digit count (so rust-v0.148.0
    matches, rusty-v8-v150.4.0 and rust-vrust-v0.147.0-alpha.9 do not). Prefer
    GitHub `/releases` (skip prerelease/draft) over git-order `tags?per_page=10`.
    Do not treat `/releases/latest` as stable if `prerelease: true`.
  * A tag without a *release object* (releases/tags/<tag> 404 / empty assets)
    has no maintainer-uploaded tarball — only the auto-archive, which for
    autotools projects lacks `configure` (adopting it costs an autoreconf +
    autoconf/automake/libtool BRs and loses the .asc). Flagged in the output.
  * Git-snapshot packaged versions (~git/+git/+hg + a YYYYMMDD) compare by the
    upstream HEAD commit date, not by tag.
  * Prereleases (rc/alpha/beta/dev/pre; PyPI prerelease/yanked flags) are
    filtered out of "latest stable".
  * ALL resolvable sources are probed AT THE SAME TIME by default: every
    forge found in URL:/Source0: (github, gitlab, pypi, npm, crates.io — a
    spec can point URL: at github and Source0: at npm) plus, when GitHub is
    selected, npm `@OWNER/REPO` and `REPO` companions (404 skipped), plus
    release-monitoring.org (Anitya) by package name (homepage-from-URL
    disambiguates same-named Anitya projects). One source failing degrades
    to a warning as long as another answers; merged latest stable/tag are
    decided by DATE. Anitya publishes versions WITHOUT dates, so when only
    it sees a newer stable the verdict is UPDATE-CANDIDATE with an explicit
    verify-by-hand caveat.

Usage:
  upstream-probe.py <pkg> [--project openSUSE:Factory]   # spec fetched via osc
  upstream-probe.py --spec <file>
  upstream-probe.py --url <github|gitlab|pypi|npm|crates url> [--version <packaged-ver>]

Exit codes:
  0  CURRENT           — packaged version is the latest stable (by date)
  1  UPDATE-CANDIDATE  — a genuinely newer (by date) stable release exists
  3  SUSPECT           — the "newer" version is OLDER by date (renumbering?);
                         do not downgrade
  2  a probe failed (network/auth/unresolvable upstream) — never a silent
     CURRENT
"""
import argparse, subprocess, sys, urllib.error
import builtins, os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _sanitize    # escape/Unicode-smuggling filter for third-party text
import _forges

# Every output line of this script embeds forge-controlled strings (tag names,
# release titles, version strings, asset notes), so sanitize at the single
# choke point: a module-local print shadow. Deliberate; args pass through
# unchanged unless they are str.
def print(*args, **kw):    # noqa: A001
    builtins.print(*(_sanitize.sanitize(a) if isinstance(a, str) else a
                     for a in args), **kw)

try:
    import _anitya          # sibling module; see scripts/_anitya.py
except ImportError:
    _anitya = None

norm = _forges.norm


def die(msg, code=2):
    sys.stderr.write(f"ERROR: {msg}\n")
    sys.exit(code)


# ---------- main ---------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pkg", nargs="?", help="package name (spec fetched via osc)")
    ap.add_argument("--spec", help="local spec file to read instead")
    ap.add_argument("--url", help="probe this forge/pypi/npm/crates URL directly")
    ap.add_argument("--version", help="packaged version (with --url)")
    ap.add_argument("--project", default="openSUSE:Factory")
    a = ap.parse_args()

    pkgname, packaged, url, src = a.pkg, a.version, a.url, None
    if a.spec:
        pkgname, packaged, url, src = _forges.spec_facts(open(a.spec).read())
    elif a.pkg:
        r = subprocess.run(["osc", "cat", a.project, a.pkg, f"{a.pkg}.spec"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            die(f"osc cat {a.project}/{a.pkg}/{a.pkg}.spec: {r.stderr.strip()}")
        _specname, packaged, url, src = _forges.spec_facts(r.stdout)
        pkgname = a.pkg or _specname
    elif not a.url:
        ap.error("need <pkg>, --spec or --url")

    url = a.url or url
    prefix = _forges.tag_prefix(src) or _forges.tag_prefix(url)
    sources = _forges.pick_forges(url, src)

    def probe_job(spec):
        return _forges.probe_one(spec, packaged, prefix=prefix)

    anitya_v = anitya_how = None
    answered, errors = [], []
    homepage = url if url and "%" not in url else None
    with ThreadPoolExecutor(max_workers=6) as ex:
        futs = {ex.submit(probe_job, s): s for s in sources}
        afut = (ex.submit(_anitya.latest_stable, pkgname, "openSUSE", homepage)
                if _anitya and pkgname and "%" not in pkgname else None)
        for fut, spec in futs.items():
            kind, host, name, optional = _forges.unpack_forge(spec)
            try:
                facts = fut.result()
            except (urllib.error.URLError, OSError, RuntimeError, ValueError) as e:
                if not optional:
                    errors.append(f"{kind}: {e}")
                continue
            if facts:
                answered.append((kind, host, name, optional, facts))
        if afut:
            try:
                anitya_v, anitya_how = afut.result()
            except _anitya.AnityaError as e:
                errors.append(f"anitya: {e}")

    answered = _forges.prefer_scoped_npm(answered)
    results = _forges.label_results(answered)

    for err in errors:
        # exception text can embed fetched bytes — sanitize the warning too
        sys.stderr.write(_sanitize.sanitize(f"WARNING: probe failed — {err}\n"))

    if not results:
        if anitya_v:
            # Anitya-only outcome: it has versions but NO dates, so this can
            # only say "a newer stable exists upstream" — never the by-date
            # renumbering analysis the forge backends do.
            print(f"packaged:       {packaged} (date unknown — no forge source answered)")
            print(f"anitya latest:  {anitya_v} ({anitya_how}, release-monitoring.org)")
            cmp = _anitya.vercmp(anitya_v, packaged)
            if cmp == 1:
                print("VERDICT: UPDATE-CANDIDATE — release-monitoring.org knows a "
                      "newer stable; anitya has NO dates, verify the tag/upload "
                      "date by hand before acting")
                sys.exit(1)
            if cmp == 0 or _anitya.norm(anitya_v) == _anitya.norm(packaged):
                print("VERDICT: CURRENT (per release-monitoring.org; dates unverified)")
                sys.exit(0)
            die(f"anitya version {anitya_v!r} is not comparable to packaged "
                f"{packaged!r} — verify by hand")
        die(f"no source answered from URL={url!r} Source={src!r} "
            f"(supported forges: github, gitlab, pypi, npm, crates; plus "
            f"release-monitoring.org by package name)")

    # Merge multi-source facts: latest stable/tag decided by DATE across
    # sources; packaged date from whichever source could date it.
    _floor = datetime.min.replace(tzinfo=timezone.utc)
    facts = {}
    for f in results.values():
        if f.get("packaged_date") and not facts.get("packaged_date"):
            facts["packaged_date"] = f["packaged_date"]
        if f.get("head_date"):
            facts["head_date"] = f["head_date"]
        for key in ("latest_stable", "latest_tag"):
            v = f.get(key)
            if v and v[1] and (key not in facts or (facts[key][1] or _floor) < v[1]):
                facts[key] = v
    if "latest_stable" not in facts:
        facts["latest_stable"] = next(r["latest_stable"] for r in results.values()
                                      if r.get("latest_stable"))
    if len(results) == 1:
        facts["asset_note"] = next(iter(results.values())).get("asset_note")
    else:
        facts["asset_note"] = "; ".join(f"[{fg}] {r['asset_note']}"
                                        for fg, r in sorted(results.items())
                                        if r.get("asset_note"))

    def fmt(pair):
        if not pair: return "?"
        v, d = pair
        return f"{v} ({d.date() if d else 'undated'})"

    pd = facts.get("packaged_date")
    lv, ld = facts.get("latest_stable", (None, None))
    print(f"packaged:       {packaged} ({pd.date() if pd else 'date unknown'})")
    print(f"latest stable:  {fmt(facts.get('latest_stable'))}")
    if len(results) > 1:
        for fg, r in sorted(results.items()):
            print(f"  [{fg}] latest stable: {fmt(r.get('latest_stable'))}")
    elif any(fg.startswith("npm") or fg.startswith("crates") for fg in results):
        # Single npm/crates source: still name the backend, per the output contract.
        fg = next(iter(results))
        print(f"  [{fg}] latest stable: {fmt(results[fg].get('latest_stable'))}")
    if facts.get("latest_tag") and facts["latest_tag"] != facts.get("latest_stable"):
        print(f"latest tag:     {fmt(facts.get('latest_tag'))}")
    if facts.get("head_date"):
        print(f"upstream HEAD:  {facts['head_date'].date()} (snapshot package — compare by commit date)")
    if facts.get("asset_note"):
        print(f"release assets: {facts['asset_note']}")
    if anitya_v:
        print(f"anitya:         {anitya_v} ({anitya_how}, release-monitoring.org)")
        if lv and _anitya.vercmp(anitya_v, lv) == 1:
            print(f"WARNING: release-monitoring.org knows a NEWER stable "
                  f"({anitya_v}) than this forge probe found ({lv}) — check the "
                  f"project on release-monitoring.org before trusting CURRENT")

    # ---- verdict ----
    # Anitya sees releases the forge scans can miss (and vice versa): a
    # forge-side CURRENT only stands if release-monitoring.org doesn't know a
    # strictly newer stable.
    def anitya_newer(v):
        return anitya_v and _anitya and _anitya.vercmp(anitya_v, v or "") == 1

    def anitya_elevate():
        print(f"VERDICT: UPDATE-CANDIDATE — forge source(s) look CURRENT but "
              f"release-monitoring.org knows a newer stable ({anitya_v}); anitya "
              f"has NO dates, verify the tag/upload date by hand before acting")
        sys.exit(1)

    if facts.get("head_date") and pd:          # snapshot package
        if facts["head_date"].date() > pd.date():
            print(f"VERDICT: UPDATE-CANDIDATE — upstream HEAD ({facts['head_date'].date()}) "
                  f"is newer than the packaged snapshot ({pd.date()})")
            sys.exit(1)
        print("VERDICT: CURRENT (snapshot at upstream HEAD)")
        sys.exit(0)
    if norm(lv or "") == norm(packaged or ""):
        if anitya_newer(packaged):
            anitya_elevate()
        print("VERDICT: CURRENT")
        sys.exit(0)
    if pd and ld:
        if pd == ld:
            if anitya_newer(packaged):
                anitya_elevate()
            print("VERDICT: CURRENT (packaged tag and latest stable share the same date)")
            sys.exit(0)
        if ld > pd:
            print(f"VERDICT: UPDATE-CANDIDATE — {lv} is newer by date ({ld.date()} > {pd.date()})")
            sys.exit(1)
        print(f"VERDICT: SUSPECT: \"newer\" version {lv} is OLDER by date "
              f"({ld.date()} <= {pd.date()}) — possible renumbering, do not downgrade")
        sys.exit(3)
    if ld and not pd:
        print(f"VERDICT: UPDATE-CANDIDATE — latest stable {lv} ({ld.date()}); packaged "
              f"version's date unknown (tag not found) — VERIFY the dates by hand before acting")
        sys.exit(1)
    die("could not date either side — verify by hand")

if __name__ == "__main__":
    main()
