#!/usr/bin/env python3
"""Incoming OBS submit requests + src.opensuse.org PRs needing YOUR PERSONAL
action — excludes anything gated only on a group/team you belong to (unlike
the incoming list or the Gitea inbox, both full of group/team
items you can't act on alone).

Your own requests and PRs (you are the creator or author) are not listed.

Buckets:
  A. SR state=new, no <review> yet — bare maintainer decision, nobody assigned
     a reviewer. Target: explicit person `role="maintainer"` (project or
     package; project role inherits to its packages). This is who should look
     at a request, not who may accept it: a new package, a project-level
     request and another maintainer's package in your project are listed,
     where pr-guard's accept check is stricter.
  B. SR state=review, pending review by_user==you OR by_project/by_package you
     maintain. by_group reviews SKIPPED even if you're a member.
  C. Gitea PR, state=open, with a pending review asked of you personally
     (`pull-request show` reviews, state `asked`, naming your login).
     Team-only asks (`@team`, not you individually) SKIPPED — re-verified
     per PR, since the search answer carries no requested-reviewer info.

Maintainership (A/B) = OBS person search, verified per target against the
package and project meta (the person search matches any role, so a bugowner
alone does not count). Git/scmsync packages the OBS index can't see are NOT
covered: no typed leaf reads the git `_maintainership.json` index
(`references/git-workflow.md` "Maintainership lives in git"), and the script
says so on stderr. One global `request search` call regardless of package
count. Bucket C: one pull-request search + one pull-request show per candidate.
Descriptions and titles are third-party text, printed through _sanitize.py.

Gitea (bucket C) is read through `geectl pull-request search --backend
gitea --reviewer <login>` and `geectl pull-request show`: the login comes
from `geectl gitea whoami` (the token owner), which may differ from the OBS
--user, and the reviewer flag accepts no other login. A failure skips bucket
C with a stderr warning; A/B still report, and the output says the
src.opensuse.org PRs are UNKNOWN. `--no-prs` skips bucket C outright.
Every geectl call times out after 60s and then counts as a failed
query, never as an empty answer.

Usage: incoming-requests.py [--user OBSUSER] [--format ascii|table|plain]
                             [--verbose] [--no-prs]
  --user     OBS account (default: $GEECTL_OBS_USERNAME)
  --format   ascii (bordered table, default) | table (markdown) | plain (tsv)
  --verbose  print scanned/skipped counts and why each skip happened
  --no-prs   skip bucket C

Exit: 0 on success (empty result isn't an error); 2 on a usage error or an
OBS query/parse failure (never read as "nothing pending"). Gitea leg fails soft.
"""

import os
import re
import sys
import argparse
import subprocess
import json

sys.pycache_prefix = "/dev/null/opensuse-packaging"  # no __pycache__ beside it is read
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _sanitize  # noqa: E402  # escape/Unicode-smuggling filter for third-party text

# seconds per geectl call: geectl has hung for good, and a harness
# gives the whole tool call 2 minutes, so the timeout must come first
TIMEOUT = 60


def run(cmd):
    """subprocess.run with TIMEOUT. A call that times out, or whose binary is
    missing, comes back as a failed one (rc 124 / 127, as in the shell) and is
    reported like any other."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            cmd, 124, "", f"{cmd[0]} timed out after {TIMEOUT}s"
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 127, "", f"{cmd[0]}: command not found")


def geectl_json(args, what):
    """The parsed JSON payload of a geectl read; exit 2 on any failure,
    never an empty answer."""
    r = run(["geectl"] + args)
    if r.returncode != 0:
        sys.stderr.write(
            f"ERROR: geectl {' '.join(args)} failed (rc={r.returncode}): {r.stderr.strip()}\n"
        )
        sys.exit(2)
    try:
        return json.loads(r.stdout)
    except ValueError as e:
        sys.stderr.write(f"ERROR: unparseable {what}: {e}\n")
        sys.exit(2)


def gitea_json(args):
    """The parsed JSON payload of a soft geectl read for bucket C; None on
    any failure (no Gitea token, network, bad JSON), with a WARNING, so the
    caller can skip bucket C cleanly."""
    r = run(["geectl"] + args)
    if r.returncode != 0:
        sys.stderr.write(
            f"WARNING: geectl {' '.join(args)} failed: {r.stderr.strip()}\n"
        )
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError as e:
        sys.stderr.write(
            f"WARNING: geectl {' '.join(args)} returned unparsable output ({e})\n"
        )
        return None


def gitea_login():
    """The src.opensuse.org login from `geectl gitea whoami` (the token
    owner): the --reviewer flag accepts no other login, and it may differ
    from the OBS --user. None on failure."""
    payload = gitea_json(["gitea", "whoami"])
    if not isinstance(payload, dict):
        return None
    return payload.get("login") or None


def whois_user():
    user = os.environ.get("GEECTL_OBS_USERNAME", "").strip()
    if not user:
        sys.stderr.write(
            "ERROR: no user (set GEECTL_OBS_USERNAME or pass --user explicitly)\n"
        )
        sys.exit(2)
    return user


def _maintainers(meta):
    """{login} holding an explicit person role="maintainer" in a meta payload."""
    return {
        p.get("name")
        for p in (meta or {}).get("persons") or []
        if isinstance(p, dict) and p.get("role") == "maintainer"
    } - {None}


def my_direct_targets(user):
    """Returns (projects: set[str], packages: set[(project, package)]) where
    `user` holds an explicit person role="maintainer". The person search
    matches any role, so every hit is verified against the package and
    project meta (a project role inherits to its packages). Git-defined
    maintainerships are not covered: no typed leaf reads the git
    `_maintainership.json` index."""
    sys.stderr.write(
        "WARNING: git-defined maintainerships are not covered (no typed leaf "
        "reads the git _maintainership.json index); git/scmsync packages are "
        "missing from this list\n"
    )
    projects, packages = set(), set()
    proj_cache = {}

    def project_maintains(prj):
        if prj not in proj_cache:
            meta = geectl_json(["remote", "project-meta", prj], "project meta")
            proj_cache[prj] = _maintainers(meta) if isinstance(meta, dict) else set()
        return user in proj_cache[prj]

    payload = geectl_json(
        ["remote", "search-projects-by-person", user], "project search response"
    )
    for p in (payload or {}).get("projects") or []:
        name = p.get("name") if isinstance(p, dict) else None
        if name and project_maintains(name):
            projects.add(name)

    payload = geectl_json(
        ["remote", "search-packages-by-person", user], "package search response"
    )
    hits = (payload or {}).get("packages") or []
    for p in hits:
        if isinstance(p, dict):
            prj, name = p.get("project"), p.get("name")
        elif isinstance(p, str) and "/" in p:
            prj, name = p.split("/", 1)
        else:
            continue
        if not prj or not name:
            continue
        meta = geectl_json(["remote", "package-meta", prj, name], "package meta")
        if isinstance(meta, dict) and (
            user in _maintainers(meta) or project_maintains(prj)
        ):
            packages.add((prj, name))

    return projects, packages


def targets_of(req):
    """All (project, package_or_None) pairs named by any action's target."""
    out = []
    for a in req.get("actions") or []:
        if isinstance(a, dict):
            out.append((a.get("target_project"), a.get("target_package")))
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
        sys.stderr.write(
            f"note: {len(my_projects)} directly-maintained project(s), "
            f"{len(my_packages)} directly-maintained package(s) for '{user}'\n"
        )

    payload = geectl_json(
        ["request", "search", "--state", "new", "--state", "review"],
        "request search response",
    )
    if not isinstance(payload, dict) or not isinstance(payload.get("requests"), list):
        sys.stderr.write("ERROR: unparseable request search response\n")
        sys.exit(2)

    scanned = 0
    group_gated_skipped = 0
    own_skipped = 0
    rows = []

    for req in payload["requests"]:
        if not isinstance(req, dict):
            continue
        scanned += 1
        rid = str(req.get("id"))
        state = (req.get("state") or {}).get("name") or "?"
        created = (req.get("state") or {}).get("when") or "?"
        desc = first_line(_sanitize.sanitize(req.get("description")))
        if req.get("creator") == user:
            own_skipped += 1
            continue

        matched_target = None
        for project, package in targets_of(req):
            if project and is_direct(project, package, my_projects, my_packages):
                matched_target = (project, package)
                break
        if not matched_target:
            continue

        acts = [a for a in req.get("actions") or [] if isinstance(a, dict)]
        action_type = acts[0].get("type") if acts else "?"
        project, package = matched_target

        if state == "new":
            why = "no reviewer assigned yet -- yours to accept/decline"
        else:  # state == "review"
            reviews = [
                r
                for r in req.get("reviews") or []
                if isinstance(r, dict) and r.get("state") == "new"
            ]
            personal = any(r.get("by_user") == user for r in reviews)
            project_pkg = any(
                (r.get("by_project") and r.get("by_project") in my_projects)
                or (
                    r.get("by_package")
                    and (r.get("by_project"), r.get("by_package")) in my_packages
                )
                for r in reviews
            )
            if not (personal or project_pkg):
                group_gated_skipped += 1
                continue
            why = (
                "review pending, assigned to you personally"
                if personal
                else "review pending, assigned to a project/package you maintain"
            )

        target = f"{project}/{package}" if package else project
        rows.append(
            {
                "kind": "SR",
                "id": rid,
                "type": action_type,
                "target": target,
                "state": state,
                "created": created,
                "why": why,
                "desc": desc,
                "url": f"https://build.opensuse.org/request/show/{rid}",
            }
        )

    if verbose:
        sys.stderr.write(
            f"note: scanned {scanned} open OBS request(s); "
            f"{group_gated_skipped} skipped as gated solely on a group review, "
            f"{own_skipped} as your own\n"
        )
    return rows


# ---------- Gitea (src.opensuse.org) PR leg -- bucket C ----------
# Read through geectl's typed leaves: the token stays in geectl's config,
# no token is read here.


def fetch_review_prs(user, verbose):
    """Bucket C: open src.opensuse.org PRs where the token owner is an
    individually requested reviewer. Returns a list of row dicts, or None
    if the leg is unavailable entirely (no login/network -- caller falls
    back to OBS-only). The reviewer flag takes the token owner's login
    from `gitea whoami` (the OBS user may differ); the search answer
    carries no requested-reviewer info, so each candidate is re-verified
    through `pull-request show`: a pending `asked` review naming the login
    personally counts, a team-only ask (`@team`) does not."""
    login = gitea_login()
    if login is None:
        sys.stderr.write(
            "WARNING: src.opensuse.org PR leg skipped (no usable "
            "login/network) -- OBS-only view. Pass --no-prs to silence.\n"
        )
        return None
    payload = gitea_json(
        [
            "pull-request",
            "search",
            "--backend",
            "gitea",
            "--reviewer",
            login,
            "--state",
            "open",
        ]
    )
    if not isinstance(payload, dict):
        sys.stderr.write(
            "WARNING: src.opensuse.org PR leg skipped (no usable "
            "login/network) -- OBS-only view. Pass --no-prs to silence.\n"
        )
        return None
    issues = payload.get("pull_requests", [])

    rows = []
    team_gated_skipped = 0
    own_skipped = 0
    for it in issues:
        ref = it.get("reference") or ""
        m = re.fullmatch(r"gitea:([\w.+-]+/[\w.+-]+)#(\d+)", ref)
        if not m:
            continue
        repo, num = m.group(1), int(m.group(2))
        title = first_line(_sanitize.sanitize(it.get("title", "")))
        # Neither the search nor the show carries a created date.
        created = "?"
        if (it.get("author") or "") == login:
            own_skipped += 1
            continue

        pr = gitea_json(["pull-request", "show", f"gitea:{repo}#{num}"])
        if pr is None:
            rows.append(
                {
                    "kind": "PR",
                    "id": f"{repo}#{num}",
                    "type": "PR",
                    "target": repo,
                    "state": "?",
                    "created": created,
                    "why": "detail fetch failed",
                    "desc": title,
                    "url": f"https://src.opensuse.org/{repo}/pulls/{num}",
                }
            )
            continue

        if (pr.get("author") or "") == login:
            own_skipped += 1
            continue
        asked = [r for r in (pr.get("reviews") or []) if r.get("state") == "asked"]
        personal = any(r.get("reviewer") == login for r in asked)
        teams = [
            r.get("reviewer", "")[1:]
            for r in asked
            if (r.get("reviewer") or "").startswith("@")
        ]
        if not personal:
            # only reachable via a team you belong to (or a stale search-index
            # hit) -- same exclusion as an OBS by_group review
            team_gated_skipped += 1
            continue

        why = "requested reviewer, assigned to you personally"
        if teams:
            why += " (also via a team you belong to)"

        rows.append(
            {
                "kind": "PR",
                "id": f"{repo}#{num}",
                "type": "PR",
                "target": repo,
                "state": "open",
                "created": created,
                "why": why,
                "desc": title,
                "url": f"https://src.opensuse.org/{repo}/pulls/{num}",
            }
        )

    if verbose:
        sys.stderr.write(
            f"note: scanned {len(issues)} review-requested PR(s); "
            f"{team_gated_skipped} skipped as gated solely on a team review, "
            f"{own_skipped} as your own\n"
        )
    return rows


def clip(s, n):
    s = str(s)
    return (s[: n - 1] + "…") if len(s) > n else s


def render_ascii(rows):
    """Fixed-width bordered table (+---+---+ style) -- easier to scan in a
    terminal than a markdown pipe table, which only renders as a real grid
    inside a markdown viewer. Each row's URL prints on its own line below it
    (never truncated) since it rarely fits alongside the other columns."""
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
            v = (
                r[key][:10] if key == "created" else r[key]
            )  # date only, drop time/offset
            line.append(clip(v, cap))
        data.append(line)
    widths = [
        min(cap, max(len(header), max((len(row[i]) for row in data), default=0)))
        for i, (header, key, cap) in enumerate(cols)
    ]

    def sep():
        return "+" + "+".join("-" * (w + 2) for w in widths) + "+"

    def fmt(cells):
        return "| " + " | ".join(c.ljust(w) for c, w in zip(cells, widths)) + " |"

    def fmt_url(url):
        # continuation line under a row: blank under Kind, URL spans the rest.
        # Never truncated -- a clipped URL is useless to click/copy -- so it's
        # allowed to overflow the right border on the rare over-long one.
        prefix = "| " + " " * widths[0] + " | "
        span = len(sep()) - len(prefix) - 2
        return prefix + (url.ljust(span) if len(url) <= span else url) + " |"

    out = [sep(), fmt([h for h, _, _ in cols]), sep()]
    for row, r in zip(data, rows):
        out.append(fmt(row))
        out.append(fmt_url(r["url"]))
        out.append(sep())
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(
        allow_abbrev=False,
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--user")
    ap.add_argument(
        "--format",
        choices=["ascii", "table", "plain"],
        default="ascii",
        help="ascii = fixed-width bordered table (default); "
        "table = markdown pipe table; plain = tab-separated",
    )
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument(
        "--no-prs",
        action="store_true",
        help="skip bucket C (the src.opensuse.org PR leg)",
    )
    args = ap.parse_args()

    user = args.user or whois_user()

    results = fetch_incoming_srs(user, args.verbose)
    prs_unknown = False
    if not args.no_prs:
        prs = fetch_review_prs(user, args.verbose)
        if prs is None:
            prs_unknown = True
        else:
            results.extend(prs)

    if not results:
        if prs_unknown:
            sys.stderr.write(
                f"no OBS requests need '{user}' personally; src.opensuse.org PRs "
                "UNKNOWN (the PR leg failed, see above)\n"
            )
        else:
            sys.stderr.write(f"no requests or PRs need '{user}' personally right now\n")
        return

    results.sort(key=lambda r: r["created"])  # oldest first -- these are going stale

    if args.format == "plain":
        for r in results:
            print(
                f"{r['id']}\t{r['type']}\t{r['target']}\t{r['state']}\t"
                f"{r['created']}\t{r['why']}\t{r['desc']}"
            )
    elif args.format == "table":
        print("| Kind | ID | Type | Target | State | Created | Why | Description |")
        print("|---|---|---|---|---|---|---|---|")
        for r in results:
            print(
                f"| {r['kind']} | [{r['id']}]({r['url']}) | {r['type']} | "
                f"{r['target']} | {r['state']} | {r['created']} | {r['why']} | "
                f"{r['desc']} |"
            )
    else:
        print(render_ascii(results))
    if prs_unknown:
        print("src.opensuse.org PRs: UNKNOWN (see stderr)")


if __name__ == "__main__":
    main()
