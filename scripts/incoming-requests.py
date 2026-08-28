#!/usr/bin/env python3
"""Incoming OBS submit requests + src.opensuse.org PRs needing YOUR PERSONAL
action — excludes anything gated only on a group/team you belong to (unlike
`osc request list --incoming -U` or the Gitea inbox, both full of group/team
items you can't act on alone).

Buckets:
  A. SR state=new, no <review> yet — bare maintainer decision, nobody assigned
     a reviewer. Target: explicit person `role="maintainer"` (project or
     package; project role inherits to its packages).
  B. SR state=review, pending review by_user==you OR by_project/by_package you
     maintain. by_group reviews SKIPPED even if you're a member.
  C. Gitea PR, state=open, you're in `requested_reviewers` by exact login.
     Team-only reviewers (`requested_reviewers_teams`, not you individually)
     SKIPPED — re-verified per PR since the API's `review_requested` filter
     doesn't reliably distinguish personal from team-membership matches.

Maintainership (A/B) = OBS `_meta` person search UNION `osc maintainer -U
<user>` (the latter catches git/scmsync packages the OBS index can't see —
`references/git-workflow.md` "Maintainership lives in git"). One global
`/search/request` call regardless of package count (expect a multi-hundred-KB
response). Bucket C: one issues/search + one PR-detail call per candidate.

Gitea auth (bucket C): tea token+urllib first (~/.config/tea/config.yml, no
subprocess); falls back to `git-obs api` if no token/pyyaml (needs a default
login — `git-obs login add`, then `git-obs login update <name>
--set-as-default`). Both failing skips bucket C with a stderr warning; A/B
still report. `--no-prs` skips bucket C outright.

Usage: incoming-requests.py [--user OBSUSER] [--format ascii|table|plain]
                             [--verbose] [--no-prs]
  --user     OBS account (default: `osc whois`)
  --format   ascii (bordered table, default) | table (markdown) | plain (tsv)
  --verbose  print scanned/skipped counts and why each skip happened
  --no-prs   skip bucket C

Exit: 0 on success (empty result isn't an error); 2 on an OBS query/parse
failure (never read as "nothing pending"). Gitea leg fails soft.
"""
import sys, argparse, subprocess, json, urllib.request, urllib.error, os
import xml.etree.ElementTree as ET

GITEA = "https://src.opensuse.org/api/v1"


def osc_api(path):
    r = subprocess.run(["osc", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"ERROR: osc api {path} failed (rc={r.returncode}): "
                          f"{r.stderr.strip()}\n")
        sys.exit(2)
    return r.stdout or ""


def parse_xml(text, what):
    try:
        return ET.fromstring(text or "<collection/>")
    except ET.ParseError as e:
        sys.stderr.write(f"ERROR: unparseable {what}: {e}\n")
        sys.exit(2)


def whois_user():
    r = subprocess.run(["osc", "whois"], capture_output=True, text=True)
    if r.returncode != 0 or ":" not in r.stdout:
        sys.stderr.write("ERROR: `osc whois` failed; pass --user explicitly\n")
        sys.exit(2)
    return r.stdout.split(":", 1)[0].strip()


def my_direct_targets(user):
    """Returns (projects: set[str], packages: set[(project, package)]) where
    `user` holds an explicit person role="maintainer", from both the OBS
    _meta index and git _maintainership.json."""
    projects, packages = set(), set()

    root = parse_xml(
        osc_api(f"/search/project?match=person[@userid='{user}' and @role='maintainer']"),
        "project search response")
    for p in root.findall("project"):
        name = p.get("name")
        if name:
            projects.add(name)

    root = parse_xml(
        osc_api(f"/search/package?match=person[@userid='{user}' and @role='maintainer']"),
        "package search response")
    for p in root.findall("package"):
        prj, name = p.get("project"), p.get("name")
        if prj and name:
            packages.add((prj, name))

    r = subprocess.run(["osc", "maintainer", "-U", user], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"ERROR: 'osc maintainer -U {user}' failed (needs osc >= 1.15): "
                          f"{r.stderr.strip()}\n")
        sys.exit(2)
    for line in r.stdout.splitlines():
        if line.startswith("Defined in git project: "):
            projects.add(line[len("Defined in git project: "):].strip())
        elif line.startswith("Defined in git package: "):
            rest = line[len("Defined in git package: "):].strip()
            if "/" in rest:
                prj, pkg = rest.split("/", 1)
                packages.add((prj.strip(), pkg.strip()))

    return projects, packages


def targets_of(req_el):
    """All (project, package_or_None) pairs named by any action's <target>."""
    out = []
    for action in req_el.findall("action"):
        t = action.find("target")
        if t is None:
            continue
        out.append((t.get("project"), t.get("package")))
    return out


def is_direct(project, package, my_projects, my_packages):
    if package and (project, package) in my_packages:
        return True
    return project in my_projects


def first_line(text):
    if not text:
        return ""
    return " ".join(text.split())[:80]


def fetch_incoming_srs(user, verbose):
    """Buckets A+B. Returns row dicts (shape: see main()). Hard-fails (exit 2)
    on an OBS query/parse error -- never reads as 'nothing pending'."""
    my_projects, my_packages = my_direct_targets(user)
    if verbose:
        sys.stderr.write(f"note: {len(my_projects)} directly-maintained project(s), "
                          f"{len(my_packages)} directly-maintained package(s) for '{user}'\n")

    root = parse_xml(
        osc_api("/search/request?match=(state/@name='new'+or+state/@name='review')"),
        "request search response")

    scanned = 0
    group_gated_skipped = 0
    rows = []

    for req in root.findall("request"):
        scanned += 1
        rid = req.get("id")
        state_el = req.find("state")
        state = state_el.get("name") if state_el is not None else "?"
        created = state_el.get("when") if state_el is not None else "?"
        desc = first_line(req.findtext("description"))

        matched_target = None
        for project, package in targets_of(req):
            if project and is_direct(project, package, my_projects, my_packages):
                matched_target = (project, package)
                break
        if not matched_target:
            continue

        action_el = req.find("action")
        action_type = action_el.get("type") if action_el is not None else "?"
        project, package = matched_target

        if state == "new":
            why = "no reviewer assigned yet -- yours to accept/decline"
        else:  # state == "review"
            reviews = [r for r in req.findall("review") if r.get("state") == "new"]
            personal = any(r.get("by_user") == user for r in reviews)
            project_pkg = any(
                (r.get("by_project") and r.get("by_project") in my_projects)
                or (r.get("by_package") and (r.get("by_project"), r.get("by_package")) in my_packages)
                for r in reviews
            )
            if not (personal or project_pkg):
                group_gated_skipped += 1
                continue
            why = "review pending, assigned to you personally" if personal \
                else "review pending, assigned to a project/package you maintain"

        target = f"{project}/{package}" if package else project
        rows.append({
            "kind": "SR", "id": rid, "type": action_type, "target": target,
            "state": state, "created": created, "why": why, "desc": desc,
            "url": f"https://build.opensuse.org/request/show/{rid}",
        })

    if verbose:
        sys.stderr.write(f"note: scanned {scanned} open OBS request(s); "
                          f"{group_gated_skipped} skipped as gated solely on a group review\n")
    return rows


# ---------- Gitea (src.opensuse.org) PR leg -- bucket C ----------
# Primary: direct token+urllib. Fallback: `git-obs api` (own auth, no pyyaml).

def tea_login():
    """Token + username from ~/.config/tea/config.yml (same loader pattern as
    leap-sync.sh / sr-status.py). Returns (token, user) or (None, None)."""
    try:
        import yaml
        c = yaml.safe_load(open(os.path.expanduser("~/.config/tea/config.yml")))
        for l in c.get("logins", []):
            if l.get("name") == "src.opensuse.org":
                return l.get("token"), l.get("user")
    except Exception as e:
        sys.stderr.write(f"WARNING: no usable tea login ({e.__class__.__name__}: {e})\n")
    return None, None


_TEA_TOKEN, _TEA_USER = tea_login()


def _gitea_get_urllib(path, tok):
    req = urllib.request.Request(GITEA + path,
                                 headers={"Authorization": f"token {tok}"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())


def _gitea_get_git_obs(path):
    """Fallback: `git-obs api <path>` -- strips the leading 'Response:' banner
    line and parses JSON. Returns None on any failure (missing/non-default
    login, network, bad JSON) so the caller can skip bucket C cleanly."""
    r = subprocess.run(["git-obs", "-q", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"WARNING: git-obs api {path} failed: {r.stderr.strip()}\n")
        return None
    out = r.stdout
    if out.startswith("Response:"):
        out = out.split("\n", 1)[1] if "\n" in out else ""
    try:
        return json.loads(out)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"WARNING: git-obs api {path} returned unparsable output ({e})\n")
        return None


def gitea_get(path):
    """Direct token+urllib first; falls back to `git-obs api` if there's no
    usable tea token or the direct call fails. Returns None if both fail."""
    if _TEA_TOKEN:
        try:
            return _gitea_get_urllib(path, _TEA_TOKEN)
        except (urllib.error.URLError, OSError, ValueError) as e:
            sys.stderr.write(f"WARNING: direct src.opensuse.org fetch failed ({e}) "
                             f"-- falling back to git-obs\n")
    return _gitea_get_git_obs(path)


def fetch_review_prs(user, verbose):
    """Bucket C: open src.opensuse.org PRs where `user` is an individually
    requested reviewer. Returns a list of row dicts, or None if the leg is
    unavailable entirely (no login/network -- caller falls back to OBS-only)."""
    issues = gitea_get("/repos/issues/search?type=pulls&review_requested=true"
                       "&state=open&limit=50")
    if issues is None:
        sys.stderr.write("WARNING: src.opensuse.org PR leg skipped (no usable "
                         "login/network) -- OBS-only view. Pass --no-prs to silence.\n")
        return None

    rows = []
    team_gated_skipped = 0
    for it in issues:
        repo = (it.get("repository") or {}).get("full_name", "?")
        num = it.get("number")
        title = it.get("title", "")
        created = it.get("created_at", "?")

        pr = gitea_get(f"/repos/{repo}/pulls/{num}")
        if pr is None:
            rows.append({
                "kind": "PR", "id": f"{repo}#{num}", "type": "PR", "target": repo,
                "state": "?", "created": created, "why": "detail fetch failed",
                "desc": title, "url": f"https://src.opensuse.org/{repo}/pulls/{num}",
            })
            continue

        reviewers = {(r.get("login") or "") for r in (pr.get("requested_reviewers") or [])}
        teams = pr.get("requested_reviewers_teams") or []
        if user not in reviewers:
            # only reachable via a team you belong to (or a stale search-index
            # hit) -- same exclusion as an OBS by_group review
            team_gated_skipped += 1
            continue

        why = "requested reviewer, assigned to you personally"
        if teams:
            why += " (also via a team you belong to)"

        rows.append({
            "kind": "PR", "id": f"{repo}#{num}", "type": "PR", "target": repo,
            "state": "open", "created": created, "why": why, "desc": first_line(title),
            "url": f"https://src.opensuse.org/{repo}/pulls/{num}",
        })

    if verbose:
        sys.stderr.write(f"note: scanned {len(issues)} review-requested PR(s); "
                         f"{team_gated_skipped} skipped as gated solely on a team review\n")
    return rows


def clip(s, n):
    s = str(s)
    return (s[: n - 1] + "…") if len(s) > n else s


def render_ascii(rows):
    """Fixed-width bordered table (+---+---+ style) -- easier to scan in a
    terminal than a markdown pipe table, which only renders as a real grid
    inside a markdown viewer."""
    cols = [
        ("Kind", "kind", 4),
        ("ID", "id", 22),
        ("Type", "type", 9),
        ("Target", "target", 42),
        ("State", "state", 8),
        ("Created", "created", 10),
        ("Why", "why", 45),
        ("Description", "desc", 45),
    ]
    data = []
    for r in rows:
        line = []
        for header, key, cap in cols:
            v = r[key][:10] if key == "created" else r[key]  # date only, drop time/offset
            line.append(clip(v, cap))
        data.append(line)
    widths = [min(cap, max(len(header), max((len(row[i]) for row in data), default=0)))
             for i, (header, key, cap) in enumerate(cols)]

    def sep():
        return "+" + "+".join("-" * (w + 2) for w in widths) + "+"

    def fmt(cells):
        return "| " + " | ".join(c.ljust(w) for c, w in zip(cells, widths)) + " |"

    out = [sep(), fmt([h for h, _, _ in cols]), sep()]
    out.extend(fmt(row) for row in data)
    out.append(sep())
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--user")
    ap.add_argument("--format", choices=["ascii", "table", "plain"], default="ascii",
                    help="ascii = fixed-width bordered table (default); "
                         "table = markdown pipe table; plain = tab-separated")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--no-prs", action="store_true",
                    help="skip bucket C (the src.opensuse.org PR leg)")
    args = ap.parse_args()

    user = args.user or whois_user()

    results = fetch_incoming_srs(user, args.verbose)
    if not args.no_prs:
        prs = fetch_review_prs(user, args.verbose)
        if prs:
            results.extend(prs)

    if not results:
        sys.stderr.write(f"no requests or PRs need '{user}' personally right now\n")
        return

    results.sort(key=lambda r: r["created"])  # oldest first -- these are going stale

    if args.format == "plain":
        for r in results:
            print(f"{r['id']}\t{r['type']}\t{r['target']}\t{r['state']}\t"
                  f"{r['created']}\t{r['why']}\t{r['desc']}")
    elif args.format == "table":
        print("| Kind | ID | Type | Target | State | Created | Why | Description |")
        print("|---|---|---|---|---|---|---|---|")
        for r in results:
            print(f"| {r['kind']} | [{r['id']}]({r['url']}) | {r['type']} | "
                  f"{r['target']} | {r['state']} | {r['created']} | {r['why']} | "
                  f"{r['desc']} |")
    else:
        print(render_ascii(results))


if __name__ == "__main__":
    main()
