#!/usr/bin/env python3
# Contributor-activity report for an OBS project (default openSUSE:Factory).
#
# Answers "who is shipping this project, and how?" — ranked by accepted submit
# requests, but with TWO axes beside the count, because a ranking alone
# conflates jobs that are not alike:
#
#   SHAPE   = requests / distinct packages.  Near 1.0 the work is a sweep
#             across many packages; high means the same few packages were
#             resubmitted over and over (a release train, a fast upstream).
#             Needs a LONG window to discriminate — over ~30 days almost
#             nobody resubmits anything, so every shape collapses toward 1.0.
#             The report says so in its own footnote rather than hiding it.
#   RHYTHM  = how many separate days the work landed on.  `steady` arrived
#             across most of the window; `burst` arrived on a handful of days
#             (or over half on one).  Identical totals, very different review
#             load. This is the axis that discriminates on SHORT windows.
#
# Both are always reported, so one report can be read at any window length.
#
# Usage: factory-report.py [--days N | --since YYYY-MM-DD] [--project PRJ]
#                          [--top N] [--highlight USER] [--json] [-o FILE]
#   --days N        window length, default 30 (ignored if --since given)
#   --since DATE    explicit window start
#   --project PRJ   default openSUSE:Factory
#   --top N         rows in the table, default 30
#   --highlight U   mark this account's row; default `osc whois`
#   --role-account  accounts to label as automation (repeatable; default
#                   factory-maintainer)
#   --json          print aggregates as JSON instead of writing HTML
#   -o FILE         output path, default factory-report.html
#
# Buckets the cadence sparkline daily for windows <= 92 days, monthly beyond,
# and shades weekends on the daily form (a project that runs on a working week
# shows it clearly; automation that does not stands out).
#
# Counts REQUESTS, not commits or lines: a one-line version bump and a full
# rewrite weigh the same. Say so when presenting the numbers.
import argparse, collections, datetime, html, json, subprocess, sys
import xml.etree.ElementTree as ET

PAGE = 2000


def osc_api(path):
    r = subprocess.run(["osc", "api", path], capture_output=True)
    if r.returncode != 0:
        sys.exit(f"osc api failed: {r.stderr.decode(errors='replace')[-300:]}")
    return r.stdout


def collect(project, since):
    q = ("/search/request?match=state/@name='accepted'+and+action/@type='submit'"
         f"+and+action/target/@project='{project}'+and+state/@when>'{since}'"
         "&view=collection&limit={n}&offset={o}")
    cnt = collections.Counter()
    pkgs = collections.defaultdict(set)
    when = collections.defaultdict(collections.Counter)
    off = 0
    while True:
        rs = ET.fromstring(osc_api(q.format(n=PAGE, o=off))).findall("request")
        if not rs:
            break
        for r in rs:
            c = r.get("creator") or "?"
            cnt[c] += 1
            st = r.find("state")
            w = (st.get("when") if st is not None else "") or ""
            if len(w) >= 10:
                when[c][w[:10]] += 1
            for a in r.findall("action"):
                t = a.find("target")
                if t is not None and t.get("package"):
                    pkgs[c].add(t.get("package"))
        off += len(rs)
        if len(rs) < PAGE:
            break
    return cnt, pkgs, when


def buckets(since, today):
    d0 = datetime.date.fromisoformat(since)
    span = (today - d0).days
    if span <= 92:
        keys = [(d0 + datetime.timedelta(days=i)).isoformat() for i in range(span + 1)]
        return keys, "day"
    keys, cur = [], d0.replace(day=1)
    while cur <= today:
        keys.append(cur.isoformat()[:7])
        cur = (cur.replace(day=28) + datetime.timedelta(days=4)).replace(day=1)
    return keys, "month"


def bucketise(counter, keys, gran):
    if gran == "day":
        return [counter.get(k, 0) for k in keys]
    agg = collections.Counter()
    for day, n in counter.items():
        agg[day[:7]] += n
    return [agg.get(k, 0) for k in keys]


def shape_of(srs, npkgs):
    q = srs / max(npkgs, 1)
    return ("broad" if q < 2.0 else "mixed" if q < 5.0 else "focused"), q


def rhythm_of(series):
    active = sum(1 for v in series if v)
    peak = max(series) if series else 0
    total = sum(series) or 1
    if active <= max(2, len(series) // 4) or peak / total > 0.5:
        return "burst", active, peak
    if active >= len(series) * 0.55:
        return "steady", active, peak
    return "uneven", active, peak


CSS = """
:root{
  --mono:ui-monospace,"JetBrains Mono","SF Mono","Cascadia Code",Menlo,Consolas,monospace;
  --sans:ui-sans-serif,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
  --fg:#0E1310; --bg:#F6F7F3; --surface:#FFFFFF; --line:#DDE1D8;
  --muted:#6E756A; --dim:#8A9086; --accent:#5C9121; --copper:#9E5F22;
}
@media (prefers-color-scheme:dark){
  :root{ --fg:#E4E8E0; --bg:#0E1310; --surface:#161C15; --line:#28301F;
    --muted:#98A092; --dim:#6E756A; --accent:#8CC63F; --copper:#D08A45; }
}
:root[data-theme="dark"]{ --fg:#E4E8E0; --bg:#0E1310; --surface:#161C15; --line:#28301F;
  --muted:#98A092; --dim:#6E756A; --accent:#8CC63F; --copper:#D08A45; }
:root[data-theme="light"]{ --fg:#0E1310; --bg:#F6F7F3; --surface:#FFFFFF; --line:#DDE1D8;
  --muted:#6E756A; --dim:#8A9086; --accent:#5C9121; --copper:#9E5F22; }
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--sans);
  -webkit-font-smoothing:antialiased;line-height:1.5}
.wrap{max-width:1120px;margin:0 auto;padding:clamp(28px,5vw,64px) clamp(16px,4vw,40px) 72px}
header{display:flex;flex-direction:column;gap:14px;margin-bottom:38px}
.eyebrow{font-family:var(--mono);font-size:11px;letter-spacing:.14em;text-transform:uppercase;
  color:var(--accent);display:flex;align-items:center;gap:10px}
.eyebrow::after{content:"";height:1px;flex:1;background:var(--line)}
h1{font-family:var(--mono);font-size:clamp(26px,4.4vw,40px);line-height:1.08;margin:0;
  font-weight:600;letter-spacing:-.02em;text-wrap:balance}
h1 em{font-style:normal;color:var(--muted)}
.lede{max-width:63ch;color:var(--muted);font-size:15px;margin:0}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(148px,1fr));gap:1px;
  background:var(--line);border:1px solid var(--line);margin:30px 0 8px}
.stat{background:var(--surface);padding:16px 18px;display:flex;flex-direction:column;gap:5px}
.stat b{font-family:var(--mono);font-size:25px;font-weight:600;letter-spacing:-.02em;
  font-variant-numeric:tabular-nums}
.stat span{font-family:var(--mono);font-size:10.5px;letter-spacing:.1em;text-transform:uppercase;
  color:var(--dim)}
.scroll{overflow-x:auto;border:1px solid var(--line);background:var(--surface)}
table{border-collapse:collapse;width:100%;min-width:940px}
thead th{position:sticky;top:0;background:var(--surface);z-index:2;
  font-family:var(--mono);font-size:10.5px;letter-spacing:.11em;text-transform:uppercase;
  color:var(--dim);font-weight:500;text-align:left;padding:13px 12px;
  border-bottom:1px solid var(--line);white-space:nowrap}
thead th.num{text-align:right}
tbody td{padding:11px 12px;border-bottom:1px solid var(--line);vertical-align:middle}
tbody tr:last-child td{border-bottom:0}
tbody tr:hover td{background:color-mix(in srgb,var(--accent) 7%,transparent)}
.rank{font-family:var(--mono);font-size:12px;color:var(--dim);width:44px;
  font-variant-numeric:tabular-nums;text-align:right;padding-right:16px}
tbody tr:nth-child(-n+3) .rank{color:var(--accent);font-weight:600}
.who{display:flex;align-items:baseline;gap:9px;flex-wrap:wrap;min-width:190px}
.handle{font-family:var(--mono);font-size:14px;font-weight:500}
.tag{font-family:var(--mono);font-size:9.5px;letter-spacing:.08em;text-transform:uppercase;
  padding:2px 6px;border:1px solid var(--line);color:var(--dim);border-radius:2px}
.tag.you{color:var(--accent);border-color:var(--accent)}
.num{font-family:var(--mono);font-variant-numeric:tabular-nums;text-align:right;
  font-size:14px;white-space:nowrap}
.pk{color:var(--muted);font-size:13px}
.volume{width:132px;min-width:104px}
.bar{display:block;height:7px;width:var(--w);background:var(--accent);opacity:.82;border-radius:1px}
.axis2{display:flex;align-items:baseline;gap:9px;white-space:nowrap}
.chip{font-family:var(--mono);font-size:10px;letter-spacing:.07em;text-transform:uppercase;
  padding:3px 7px;border-radius:2px;border:1px solid currentColor}
.chip.broad,.chip.steady{color:var(--accent)}
.chip.mixed,.chip.uneven{color:var(--muted)}
.chip.focused,.chip.burst{color:var(--copper)}
.ratio{font-family:var(--mono);font-size:12px;color:var(--dim);font-variant-numeric:tabular-nums}
.per{opacity:.65}
.cad{width:122px}
.spark{width:107px;height:22px;display:block;overflow:visible}
.spark polyline{fill:none;stroke:var(--muted);stroke-width:1.25;
  stroke-linejoin:round;stroke-linecap:round;vector-effect:non-scaling-stroke}
.spark circle{fill:var(--muted)}
.spark .we{fill:currentColor;opacity:.07}
.spark.steady polyline{stroke:var(--accent)}
.spark.steady circle{fill:var(--accent)}
.spark.burst polyline{stroke:var(--copper)}
.spark.burst circle{fill:var(--copper)}
tr.me td{background:color-mix(in srgb,var(--accent) 9%,transparent)}
tr.me .rank{box-shadow:inset 2px 0 0 var(--accent)}
tr.role .handle{color:var(--muted)}
footer{margin-top:26px;display:flex;flex-direction:column;gap:9px;
  font-size:13px;color:var(--muted);max-width:70ch}
footer code{font-family:var(--mono);font-size:12px;color:var(--fg);
  background:color-mix(in srgb,var(--accent) 10%,transparent);padding:1px 5px;border-radius:2px}
.key{display:flex;flex-wrap:wrap;gap:16px;font-family:var(--mono);font-size:11px;
  color:var(--dim);padding-top:4px}
.key b{font-weight:500}
@media (prefers-reduced-motion:no-preference){tbody tr{transition:background .12s ease}}
"""


def sparkline(vals, kind, weekend_idx):
    hi = max(vals) or 1
    W, H = 104, 22
    step = W / max(len(vals) - 1, 1)
    bands = "".join(
        f'<rect x="{i*step-step/2:.1f}" y="0" width="{step:.1f}" height="{H}" class="we"/>'
        for i in weekend_idx)
    pts = " ".join(f"{i*step:.1f},{H-1.5-(v/hi)*(H-4):.1f}" for i, v in enumerate(vals))
    ly = H - 1.5 - (vals[-1] / hi) * (H - 4)
    return (f'<svg class="spark {kind}" viewBox="-2 0 {W+5} {H}" aria-hidden="true">{bands}'
            f'<polyline points="{pts}"/><circle cx="{W:.1f}" cy="{ly:.1f}" r="1.8"/></svg>')


def render(meta, rows, gran, weekend_idx, weekend_share):
    mx = max(r["srs"] for r in rows)
    nb = meta["buckets"]
    trs = []
    for i, r in enumerate(rows, 1):
        cls = " ".join(filter(None, ["row",
                                     "me" if r["highlight"] else "",
                                     "role" if r["role"] else ""]))
        tag = ('<span class="tag you">you</span>' if r["highlight"]
               else '<span class="tag bot">role account</span>' if r["role"] else "")
        unit = "d" if gran == "day" else "mo"
        trs.append(f'''<tr class="{cls}">
<td class="rank">{i}</td>
<td class="who"><span class="handle">{html.escape(r["user"])}</span>{tag}</td>
<td class="num">{r["srs"]:,}</td>
<td class="volume"><span class="bar" style="--w:{r["srs"]/mx*100:.1f}%"></span></td>
<td class="num pk">{r["pkgs"]:,}</td>
<td class="axis2"><span class="chip {r["shape"]}">{r["shape"]}</span>\
<span class="ratio">{r["ratio"]:.1f}<span class="per">/pkg</span></span></td>
<td class="axis2"><span class="chip {r["rhythm"]}">{r["rhythm"]}</span>\
<span class="ratio">{r["active"]}<span class="per">/{nb}{unit}</span></span></td>
<td class="num pk">{r["peak"]}</td>
<td class="cad">{sparkline(r["spark"], r["rhythm"], weekend_idx)}</td>
</tr>''')

    short = gran == "day" and nb <= 45
    shape_note = (" Over a window this short almost nobody resubmits the same package, so shape "
                  "compresses toward 1.0 for everyone and separates little — read rhythm here, "
                  "and shape on a year-long report." if short else
                  " A <b>broad</b> figure near 1 means each package was touched about once; "
                  "<b>focused</b> means the same packages went through many times, the signature "
                  "of a release train or a fast-moving upstream.")
    wk = (f'<p>Shaded columns in the cadence line are Saturdays and Sundays. Only '
          f'<b>{weekend_share:.0f}%</b> of these requests landed on one, against weekends being '
          f'26% of the calendar.</p>' if gran == "day" else "")
    wkstat = (f'<div class="stat"><b>{weekend_share:.0f}%</b><span>landed at a weekend</span></div>'
              if gran == "day" else
              f'<div class="stat"><b>{nb}</b><span>months covered</span></div>')

    return f'''<title>{html.escape(meta["project"])} — contributor report</title>
<style>{CSS}</style>
<div class="wrap">
<header>
  <p class="eyebrow">{html.escape(meta["project"])} · accepted submit requests · {meta["spanlabel"]}</p>
  <h1>Who is shipping {html.escape(meta["short"])} <em>— {meta["heading"]}</em></h1>
  <p class="lede">Every submit request accepted into <code>{html.escape(meta["project"])}</code>
  from {meta["span"]}, grouped by the account that filed it. Ranked by volume, with two axes
  beside it: <b>shape</b>, how concentrated the work was across packages, and <b>rhythm</b>,
  how many separate {"days" if gran == "day" else "months"} it landed on.</p>
</header>
<div class="stats">
  <div class="stat"><b>{meta["total"]:,}</b><span>requests accepted</span></div>
  <div class="stat"><b>{meta["contributors"]:,}</b><span>contributors</span></div>
  <div class="stat"><b>{meta["packages"]:,}</b><span>packages touched</span></div>
  {wkstat}
</div>
<div class="scroll"><table>
<thead><tr><th class="rank">#</th><th>Contributor</th><th class="num">Requests</th><th>Volume</th>
<th class="num">Packages</th><th>Shape</th><th>Rhythm</th><th class="num">Peak</th>
<th>Cadence</th></tr></thead>
<tbody>
{"".join(trs)}
</tbody></table></div>
<footer>
  <p><b>Shape</b> is requests divided by distinct packages.{shape_note}</p>
  <p><b>Rhythm</b> counts the {"days" if gran == "day" else "months"} on which at least one
  request was accepted. <b>Steady</b> arrived across most of the window; <b>burst</b> arrived on a
  handful, or over half of it at once. The two produce identical totals and very different
  review loads.</p>
  {wk}
  <div class="key">
    <span><b>Source:</b> OBS request search, <code>state=accepted</code>, <code>type=submit</code></span>
    <span><b>Counts requests, not commits or lines</b></span>
  </div>
</footer>
</div>'''


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--since")
    ap.add_argument("--project", default="openSUSE:Factory")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--highlight")
    ap.add_argument("--role-account", action="append", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-o", "--output", default="factory-report.html")
    a = ap.parse_args()

    today = datetime.date.today()
    since = a.since or (today - datetime.timedelta(days=a.days)).isoformat()
    roles = set(a.role_account or ["factory-maintainer"])
    me = a.highlight
    if me is None:
        r = subprocess.run(["osc", "whois"], capture_output=True)
        me = r.stdout.decode().split(":")[0].strip() if r.returncode == 0 else ""

    cnt, pkgs, when = collect(a.project, since)
    if not cnt:
        sys.exit(f"no accepted submit requests in {a.project} since {since}")
    keys, gran = buckets(since, today)
    weekend_idx = ([i for i, k in enumerate(keys)
                    if datetime.date.fromisoformat(k).weekday() >= 5]
                   if gran == "day" else [])

    rows = []
    for u, n in cnt.most_common(a.top):
        series = bucketise(when[u], keys, gran)
        shp, ratio = shape_of(n, len(pkgs[u]))
        rhy, active, peak = rhythm_of(series)
        rows.append({"user": u, "srs": n, "pkgs": len(pkgs[u]), "shape": shp,
                     "ratio": ratio, "rhythm": rhy, "active": active, "peak": peak,
                     "spark": series, "highlight": u == me and bool(me), "role": u in roles})

    tot_all = sum(sum(r["spark"]) for r in rows) or 1
    weekend_share = 100 * sum(sum(r["spark"][i] for i in weekend_idx) for r in rows) / tot_all

    d0 = datetime.date.fromisoformat(since)
    meta = {"project": a.project, "short": a.project.split(":")[-1],
            "total": sum(cnt.values()), "contributors": len(cnt),
            "packages": len(set().union(*pkgs.values())), "buckets": len(keys),
            "span": f"{d0.strftime('%-d %B %Y')} to {today.strftime('%-d %B %Y')}",
            "spanlabel": f"{(today - d0).days} days" if gran == "day" else "by month",
            "heading": "right now" if gran == "day" and (today - d0).days <= 45 else "over the window"}

    if a.json:
        print(json.dumps({"meta": meta, "buckets": keys, "granularity": gran,
                          "weekend_share": round(weekend_share, 1), "rows": rows}, indent=1))
        return
    with open(a.output, "w") as f:
        f.write(render(meta, rows, gran, weekend_idx, weekend_share))
    print(f"{a.output}: {len(rows)} rows, {meta['total']:,} requests, "
          f"{meta['contributors']:,} contributors, {gran} buckets")


if __name__ == "__main__":
    main()
