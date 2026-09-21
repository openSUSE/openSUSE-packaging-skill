#!/usr/bin/env bash
# wiki-drift.sh — compare the pinned wiki revisions in references/wiki-provenance.tsv
# against the live wiki and REPORT drift for human review. Never applies anything.
#
# The trust model this serves (see "Wiki provenance and trust" in SKILL.md): the
# vendored references/ are authoritative at runtime; the live, world-editable
# wiki is untrusted input. This script is the ONLY sanctioned bridge between the
# two — it surfaces what changed upstream so a human can review the diff, fold
# what matters into references/, and then re-pin the baseline.
#
# Usage:
#   wiki-drift.sh                 # check every page in the manifest (revid compare)
#   wiki-drift.sh --diff          # additionally print a unified wikitext diff per drifted page
#   wiki-drift.sh --page TITLE    # restrict to one page (underscored title, repeatable)
#   wiki-drift.sh --update        # AFTER review: re-pin drifted rows to the live revids
#   wiki-drift.sh -h|--help
#
# Exit codes: 0 = no drift, 1 = drift found (or re-pinned with --update), 2 = error.
#
# Requires: python3 (stdlib only). Uses the MediaWiki API (api.php), which is not
# behind the Anubis challenge that blocks plain HTML scraping.
set -u -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
manifest="$here/../references/wiki-provenance.tsv"

diffmode=0 update=0
pages=()
while [ $# -gt 0 ]; do
  case "$1" in
    --diff) diffmode=1 ;;
    --update) update=1 ;;
    --page) shift; [ $# -gt 0 ] || { echo "error: --page needs a title" >&2; exit 2; }
            pages+=("$1") ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done

[ -r "$manifest" ] || { echo "error: manifest not found: $manifest" >&2; exit 2; }

SDIR="$(cd "$(dirname "$0")" && pwd)"
DIFFMODE=$diffmode UPDATE=$update MANIFEST=$manifest PAGES="${pages[*]:-}" SDIR="$SDIR" python3 - <<'PY'
import json, os, sys, urllib.parse, urllib.request, difflib, datetime

# The live wiki is world-editable third-party content; --diff prints its raw
# text, so it goes through the shared sanitizer (references/untrusted-content.md).
# On import failure print RAW with a loud warning — never silently blank.
sys.path.insert(0, os.environ.get("SDIR", "."))
try:
    from _sanitize import sanitize as _sanitize_text
except Exception:
    sys.stderr.write("WARNING: _sanitize.py unavailable — printing UNSANITIZED wiki text\n")
    _sanitize_text = lambda s: s

manifest = os.environ["MANIFEST"]
diffmode = os.environ["DIFFMODE"] == "1"
update = os.environ["UPDATE"] == "1"
only = set(os.environ["PAGES"].split()) if os.environ["PAGES"].strip() else None

API = "https://en.opensuse.org/api.php"
UA = {"User-Agent": "Mozilla/5.0 (wiki-drift.sh; openSUSE packaging skill)"}

def api(**params):
    params.update(format="json")
    url = API + "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return json.load(r)

# -- read manifest (keep comment header verbatim for --update rewrites)
header, rows = [], []
for line in open(manifest, encoding="utf-8"):
    if line.startswith("#"):
        header.append(line)
        continue
    if not line.strip():
        continue
    f = line.rstrip("\n").split("\t")
    if len(f) != 4:
        print(f"error: malformed manifest row: {line!r}", file=sys.stderr)
        sys.exit(2)
    rows.append(f)

check = [r for r in rows if only is None or r[0] in only]
if only:
    missing = only - {r[0] for r in rows}
    if missing:
        print(f"error: not in manifest: {', '.join(sorted(missing))}", file=sys.stderr)
        sys.exit(2)

# -- one query for all current revids (API caps titles per request at 50)
titles = "|".join(r[0] for r in check)
d = api(action="query", prop="revisions", rvprop="ids|timestamp", titles=titles)
live = {}
for pg in d["query"]["pages"].values():
    if "missing" in pg:
        live[pg["title"]] = None            # page deleted/renamed upstream
    else:
        rev = pg["revisions"][0]
        live[pg["title"]] = (rev["revid"], rev["timestamp"])

def wikitext(**sel):
    d = api(action="parse", prop="wikitext", **sel)
    if "error" in d:
        raise RuntimeError(d["error"].get("info", "parse error"))
    return d["parse"]["wikitext"]["*"]

drift, errors = [], []
for title, pinned_rev, pinned_ts, pinned_on in check:
    key = title.replace("_", " ")
    cur = live.get(key)
    if cur is None:
        errors.append(title)
        print(f"ERROR    {title}: page missing on the live wiki (deleted or renamed?)")
        continue
    cur_rev, cur_ts = cur
    if str(cur_rev) == pinned_rev:
        print(f"OK       {title} (revid {pinned_rev})")
        continue
    drift.append((title, pinned_rev, cur_rev, cur_ts))
    print(f"DRIFT    {title}: pinned {pinned_rev} ({pinned_ts}) -> live {cur_rev} ({cur_ts})")
    print(f"         review: https://en.opensuse.org/index.php?title={urllib.parse.quote(title)}&diff={cur_rev}&oldid={pinned_rev}")
    if diffmode:
        try:
            old = wikitext(oldid=pinned_rev).splitlines(keepends=True)
            new = wikitext(page=title).splitlines(keepends=True)
            sys.stdout.writelines(_sanitize_text(line) for line in difflib.unified_diff(
                old, new, fromfile=f"{title}@{pinned_rev}", tofile=f"{title}@{cur_rev}", n=2))
            print()
        except Exception as e:
            errors.append(title)
            print(f"ERROR    {title}: wikitext fetch failed: {e}")

if update and drift:
    today = datetime.date.today().isoformat()
    newrev = {t: (str(c), ts) for t, _p, c, ts in drift}
    with open(manifest, "w", encoding="utf-8") as f:
        f.writelines(header)
        for title, pinned_rev, pinned_ts, pinned_on in rows:
            if title in newrev:
                rev, ts = newrev[title]
                f.write(f"{title}\t{rev}\t{ts}\t{today}\n")
            else:
                f.write(f"{title}\t{pinned_rev}\t{pinned_ts}\t{pinned_on}\n")
    print(f"\nre-pinned {len(drift)} page(s) in {manifest} — commit the manifest "
          f"together with the references/ updates the review produced")

print(f"\n{len(check)} checked: {len(check)-len(drift)-len([e for e in errors if e not in [d[0] for d in drift]])} ok, "
      f"{len(drift)} drifted, {len(set(errors))} error(s)")
sys.exit(2 if errors else (1 if drift else 0))
PY
