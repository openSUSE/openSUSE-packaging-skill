#!/usr/bin/env python3
"""Combined submission-status view: OBS submit requests AND src.opensuse.org
(Gitea) pull requests in ONE table — overall state, the review chain (SRs) /
merge+bot-build status (PRs), and human comments. Reused by Block 3
(submit / watch); satisfies the "status of my submissions = OBS SRs AND Gitea
PRs, declines flagged first" rule in one call.

Renders a Markdown table (so it looks nice in a chat/terminal that renders MD).

Usage:
  sr-status.py [--user U] [--state open|all|declined|accepted] [--target PRJ]
               [--limit N] [--format table|blocks] [--brief] [--no-prs] [ID ...]
    ID ...      specific OBS request ids (overrides discovery; skips the PR leg)
    --state     which of your creator SRs/PRs to show (default: open = new,review,declined)
    --target    restrict SR discovery to a target project (e.g. openSUSE:Factory)
    --limit     cap discovered SRs (most recent first); each costs 2 API calls
    --format    table = one row per item; blocks = per-item bullets
    --brief     discovery list only (id, package, target, state) — NO per-item
                review/comment API calls (this is what my-requests.sh wraps)
    --no-prs    skip the src.opensuse.org PR leg (OBS-only view)
    --user      OBS account (default: `osc whois`)

The PR leg needs a src.opensuse.org login in ~/.config/tea/config.yml; if the
token/network is unavailable it prints a loud stderr warning and falls back to
the OBS-only table (it never kills the SR view).
"""
import sys, argparse, subprocess, json, urllib.request, urllib.error
import os, xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _sanitize   # escape/Unicode-smuggling filter for third-party text

GITEA = "https://src.opensuse.org/api/v1"

def api(path, hard=True):
    """osc api wrapper. hard=True: exit 2 on failure (discovery must not
    silently become '0 shown'). hard=False: return None so the caller can emit
    a visible FETCH FAILED row instead of a garbage one."""
    r = subprocess.run(["osc", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"ERROR: osc api {path} failed (rc={r.returncode}): "
                         f"{r.stderr.strip()}\n")
        if hard:
            sys.exit(2)
        return None
    return r.stdout or ""

EMOJI = {"accepted": "✅", "new": "⏳", "review": "🔎", "declined": "❌",
         "revoked": "🚫", "superseded": "♻️", "obsoleted": "♻️",
         "open": "🔎", "merged": "✅", "closed": "❌", "": "❔"}
def badge(state): return EMOJI.get(state, "❔")

SHORT = {"factory-auto": "auto", "licensedigger": "lic", "factory-staging": "stg",
         "opensuse-review-team": "team", "repo-checker": "repo"}
# logins whose comments are bot noise, not human feedback
BOTS = ("factory-auto", "licensedigger", "repo-checker", "staging-bot", "_obs_",
        "autogits")
def is_bot(who):
    w = (who or "").lower()
    return any(b in w for b in BOTS) or "bot" in w or w.startswith("_")

def review_label(rv):  # short, for the compact table column
    for k in ("by_user", "by_group", "by_project"):
        v = rv.get(k)
        if v:
            return SHORT.get(v, v.split(":")[-1] if k == "by_project" else v)
    return "?"

def review_full(rv):   # full name, for the bulleted blocks format
    for k in ("by_user", "by_group"):
        v = rv.get(k)
        if v:
            return v
    v = rv.get("by_project")
    if v:
        return "staging " + (v.split("Staging:")[1] if "Staging:" in v else v.split(":")[-1])
    return "?"

def clip(s, n=64):
    # Every foreign-authored comment/description body flows through here —
    # sanitize at the choke point so no ANSI/bidi/zero-width smuggling from a
    # request comment or PR body reaches the rendered table.
    s = " ".join(_sanitize.sanitize(s or "").split())
    return (s[: n - 1] + "…") if len(s) > n else s

def human_comment(req_id, state_el):
    # declined: the decline reason on the state element is the salient human note
    if state_el is not None and state_el.get("name") == "declined":
        c = state_el.findtext("comment")
        who = state_el.get("who", "?")
        if c and c.strip():
            return f"💬 {who}: \"{clip(c)}\""
    # otherwise the latest non-bot comment in the thread
    raw = api(f"/comments/request/{req_id}", hard=False)
    if raw is None:
        return "(comment fetch failed)"
    try:
        root = ET.fromstring(raw or "<comments/>")
    except ET.ParseError:
        return "—"
    cmts = [c for c in root.findall("comment") if not is_bot(c.get("who"))]
    if not cmts:
        return "—"
    last = cmts[-1]
    return f"💬 {last.get('who','?')}: \"{clip(last.text)}\""

# ---------- Gitea (src.opensuse.org) PR leg ----------

def tea_login():
    """Token + username from ~/.config/tea/config.yml (same loader pattern as
    leap-sync.sh). Returns (token, user) or (None, None)."""
    try:
        import yaml
        c = yaml.safe_load(open(os.path.expanduser("~/.config/tea/config.yml")))
        for l in c.get("logins", []):
            if l.get("name") == "src.opensuse.org":
                return l.get("token"), l.get("user")
    except Exception as e:
        sys.stderr.write(f"WARNING: no usable tea login ({e.__class__.__name__}: {e})\n")
    return None, None

def gitea_get(path, tok):
    req = urllib.request.Request(GITEA + path,
                                 headers={"Authorization": f"token {tok}"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())

def fetch_prs(state, brief):
    """One issues/search call for the user's created PRs; per-PR detail
    (base branch, mergeable, bot-build + human comments) only in full mode.
    Returns a list of row dicts, or None on failure (caller falls back)."""
    tok, _user = tea_login()
    if not tok:
        sys.stderr.write("WARNING: src.opensuse.org PR leg skipped (no tea token) "
                         "— OBS-only view. Pass --no-prs to silence.\n")
        return None
    q_state = "open" if state == "open" else "all"
    try:
        issues = gitea_get(f"/repos/issues/search?type=pulls&created=true"
                           f"&state={q_state}&limit=50", tok)
    except (urllib.error.URLError, OSError, ValueError) as e:
        sys.stderr.write(f"WARNING: src.opensuse.org PR fetch failed ({e}) "
                         f"— OBS-only view.\n")
        return None
    rows = []
    for it in issues:
        repo = (it.get("repository") or {}).get("full_name", "?")
        num = it.get("number")
        prinfo = it.get("pull_request") or {}
        merged = bool(prinfo.get("merged") or prinfo.get("merged_at"))
        st = "merged" if merged else it.get("state", "?")   # open|closed|merged
        if state == "declined" and st != "closed":
            continue
        if state == "accepted" and st != "merged":
            continue
        target, status, comment = repo, "—", "—"
        if not brief:
            try:
                pr = gitea_get(f"/repos/{repo}/pulls/{num}", tok)
                base = (pr.get("base") or {}).get("ref", "?")
                target = f"{repo}:{base}"
                bits = []
                if merged:
                    bits.append("merged")
                elif pr.get("mergeable") is not None:
                    bits.append("mergeable" if pr["mergeable"] else "NOT mergeable")
                cmts = gitea_get(f"/repos/{repo}/issues/{num}/comments", tok)
                bot_line = next((c for c in reversed(cmts)
                                 if is_bot((c.get("user") or {}).get("login"))), None)
                if bot_line:
                    body = (bot_line.get("body") or "").lower()
                    if "succe" in body or "✅" in body:
                        bits.append("bot-build ✅")
                    elif "fail" in body or "❌" in body:
                        bits.append("bot-build ❌")
                    else:
                        bits.append("bot 💬")
                status = " · ".join(bits) or "—"
                hum = next((c for c in reversed(cmts)
                            if not is_bot((c.get("user") or {}).get("login"))), None)
                if hum:
                    comment = (f"💬 {(hum.get('user') or {}).get('login','?')}: "
                               f"\"{clip(hum.get('body'))}\"")
            except (urllib.error.URLError, OSError, ValueError) as e:
                status = f"(detail fetch failed: {e.__class__.__name__})"
        rows.append({"kind": "PR", "id": f"#{num}",
                     "num": int(num or 0), "pkg": repo.split("/")[-1],
                     "target": target, "state": st, "chain": status,
                     "comment": comment,
                     "bad": st == "closed"})   # closed-unmerged sorts first
    return rows

# ---------- main ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--user")
    ap.add_argument("--state", default="open")
    ap.add_argument("--target")
    ap.add_argument("--limit", type=int, default=40,
                    help="cap discovered SRs (most recent first); each costs 2 API calls")
    ap.add_argument("--format", choices=["table", "blocks"], default="table",
                    help="table = one cramped row per item; blocks = per-item bullets")
    ap.add_argument("--brief", action="store_true",
                    help="discovery list only — no per-item review/comment calls")
    ap.add_argument("--no-prs", action="store_true",
                    help="skip the src.opensuse.org PR leg")
    a = ap.parse_args()
    w = subprocess.run(["osc", "whois"], capture_output=True, text=True)
    user = a.user or w.stdout.split(":")[0].strip()
    if not user:
        sys.stderr.write(f"ERROR: could not determine OBS user (osc whois rc="
                         f"{w.returncode}: {w.stderr.strip()}) — pass --user\n")
        sys.exit(2)

    rows = []
    ids = a.ids
    if not ids:
        # "open" means "still needs something from you", so it MUST include
        # declined: a decline is the single most actionable state a request of
        # yours can be in (it needs a fix + supersede, or a revoke), and it is
        # what the declines-first sort below exists to surface. Leaving it out
        # made the default view silently hide exactly the rows worth reading.
        states = {"open": "new,review,declined",
                  "all": "new,review,declined,accepted,revoked,superseded"}.get(a.state, a.state)
        q = f"/request?view=collection&states={states}&roles=creator&user={user}&types=submit"
        if a.target:
            q += f"&project={a.target}"
        col = ET.fromstring(api(q) or "<collection/>")   # api() exits 2 on failure
        reqs = col.findall("request")
        if a.limit and len(reqs) > a.limit:
            reqs = sorted(reqs, key=lambda r: int(r.get("id", 0)), reverse=True)[: a.limit]
        if a.brief:
            for r in reqs:
                st = r.find("state"); act = r.find("action")
                tgt = act.find("target") if act is not None else None
                src = act.find("source") if act is not None else None
                sname = st.get("name") if st is not None else "?"
                # staging assignment is free here — the collection XML already
                # carries the reviews, so no per-item API call is needed
                stg = ""
                for rv in r.findall("review"):
                    if rv.get("state") == "new":
                        by = rv.get("by_project") or ""
                        if "Staging" in by:
                            parts = by.split(":")
                            # ...Staging:adi:40 -> adi:40, ...Staging:G -> G
                            stg = (parts[-1] if parts[-2] == "Staging"
                                   else ":".join(parts[-2:]))
                rows.append({"kind": "SR", "id": r.get("id"),
                             "num": int(r.get("id", 0)),
                             "pkg": tgt.get("package") if tgt is not None else "?",
                             "target": (tgt.get("project") if tgt is not None else "?"),
                             "src": (f"{src.get('project')}/{src.get('package')}"
                                     if src is not None else "?"),
                             "state": sname, "staging": stg,
                             "chain": "—", "comment": "—",
                             "bad": sname == "declined"})
        else:
            ids = [r.get("id") for r in reqs]
    if ids:
        for rid in ids:
            raw = api(f"/request/{rid}", hard=False)
            if raw is None:
                rows.append({"kind": "SR", "id": rid, "num": int(rid) if rid.isdigit() else 0,
                             "pkg": "?", "target": "?", "state": "",
                             "chain": "FETCH FAILED", "comment": "(see stderr)",
                             "bad": True})
                continue
            req = ET.fromstring(raw or "<request/>")
            st = req.find("state")
            sname = st.get("name") if st is not None else ""
            act = req.find("action")
            tgt = act.find("target") if act is not None else None
            reviews = req.findall("review")
            chain = " ".join(f"{review_label(rv)}{badge(rv.get('state',''))}"
                             for rv in reviews) or "—"
            rows.append({"kind": "SR", "id": rid,
                         "num": int(rid) if str(rid).isdigit() else 0,
                         "pkg": tgt.get("package") if tgt is not None else "?",
                         "target": tgt.get("project") if tgt is not None else "?",
                         "state": sname, "chain": chain, "reviews": reviews,
                         "comment": human_comment(rid, st),
                         "bad": sname == "declined"})

    if not a.ids and not a.no_prs:
        prs = fetch_prs(a.state, a.brief)
        if prs:
            rows.extend(prs)

    # declined SRs / closed-unmerged PRs first, then ids numeric descending-safe
    rows.sort(key=lambda r: (not r["bad"], r["num"]))

    print(f"### Submissions for `{user}` — {len(rows)} shown"
          + ("" if a.no_prs or a.ids else " (OBS SRs + src.opensuse.org PRs)") + "\n")
    if a.brief:
        for r in rows:
            src = f"  {r.get('src','')} ->" if r.get("src") else " "
            print(f"  {r['kind']} {r['id']}  [{r['state']:9}] {src} {r['target']}"
                  + (f"/{r['pkg']}" if r["kind"] == "SR" else "")
                  + (f"  @{r['staging']}" if r.get("staging") else ""))
        return
    if a.format == "blocks":
        for r in rows:
            print(f"**{r['kind']} {r['id']} — {r['pkg']}**  {badge(r['state'])} "
                  f"{r['state']}  ·  → `{r['target']}`")
            for rv in r.get("reviews", []):
                print(f"- {review_full(rv)} {badge(rv.get('state',''))}")
            if r["kind"] == "PR" and r["chain"] not in ("—", ""):
                print(f"- {r['chain']}")
            if r["comment"] and r["comment"] != "—":
                print(f"- {r['comment']}")
            print()
    else:
        print("| Kind | ID | Package | Target | State | Review chain / PR status | Latest comment |")
        print("|------|----|---------|--------|-------|--------------------------|----------------|")
        for r in rows:
            print(f"| {r['kind']} | {r['id']} | {r['pkg']} | {r['target']} | "
                  f"{badge(r['state'])} {r['state']} | {r['chain']} | {r['comment']} |")
    print("\n_Legend: ✅ accepted/merged · 🔎 review/open · ⏳ new/pending · "
          "❌ declined/closed-unmerged · 🚫 revoked · ♻️ superseded_")

if __name__ == "__main__":
    main()
