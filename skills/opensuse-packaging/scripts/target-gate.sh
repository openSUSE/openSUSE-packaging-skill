#!/bin/bash
# Build the exact tree a Leap pool PR will carry against that PR's own target,
# and stamp the verdict so pool-pr.sh can refuse to push anything else. A green
# build of another checkout, of an older commit or against another base is not
# evidence: the stamp is keyed on HEAD's tree plus the base.
#
# Usage: target-gate.sh [DIR] [--branch BASE] (--build [--jobs N] | --remote | --review FILE)
#   DIR            the pool/<pkg> clone (default .)
#   --branch BASE  leap-16.0 or leap-16.1 (default: the branch @{upstream}
#                  tracks on origin); slfo-* and factory are refused
#   --build        native local build against openSUSE:Backports:SLE-16.x
#                  standard, once per _multibuild flavor, in a per-base build
#                  root; every other PR arch must resolve
#   --jobs N       refused: geectl local-build build takes no --jobs flag
#   --remote       no native route: push HEAD to fork branch
#                  leapgate/<base>-<sha12> and build it in home:<you>:leapgate;
#                  re-run to poll (pending until every PR arch built the
#                  source revision whose obsinfo names HEAD); the fork branch
#                  and the package are deleted once the build is GREEN
#   --review FILE  record the change review: FILE's first non-empty line
#                  starts with PASS and names "tree <sha12>" of HEAD (trees
#                  quoted further down are ignored); needs a GREEN build first
#   (no mode)      check: GREEN build and PASS review for HEAD's tree and base
# Carried: when HEAD's tree differs from the base's last GREEN tree only in
# .changes files and `geectl changelog validate` passes the entries they touch, --build and
# --remote stamp that build for HEAD's tree (mode carried) without building;
# the review never carries. A tree stamped already is built for real.
# PR arches: the standard repository of openSUSE:Backports:SLE-16.x:PullRequest,
# where the PR bot builds. Your PRs: those whose head repo belongs to the user
# of your src.opensuse.org login, the identity pool-pr.sh updates by.
# Refused before anything is built: a dirty worktree (ignored and untracked
# files count), a detached HEAD, unsmudged LFS files, a clone under /tmp or a
# scratchpad, HEAD not on top of origin/<base>, HEAD stacked on more than one
# of your open PRs to the base, a failed PR lookup, a host arch the PR project
# does not build (never emulated), a flavor with no native route, a mounted
# root. Every failed lookup is a refusal or a red, never a green.
# Stamp: <git-common-dir>/target-gate/<tree>-<base>.json
# Needs: geectl, git-lfs, obs-build (queryrecipe) and a src.opensuse.org
# login (geectl's Gitea token); --remote pushes over SSH (gitea@src.opensuse.org)
# with your key. geectl and ssh read their own credentials: this script reads none.
#
# Exit: 0 = green (check: build GREEN and review PASS), 1 = red (the check is
# named), 2 = refused or usage, 3 = no stamp, stale stamp or remote build pending.
set -uo pipefail
HERE=$(dirname "$(readlink -f -- "$0")")
G=https://src.opensuse.org
GS=gitea@src.opensuse.org

usage() { awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }
say() { printf '%s\n' "$*"; }
refuse() { printf 'VERDICT: REFUSED — %s\n' "$*" >&2; exit 2; }
pending() { say "VERDICT: PENDING — $*"; exit 3; }

dir=""; base=""; mode=check; jobs=""; review=""
setmode() { [ "$mode" = check ] || refuse "one mode only (--$mode and $1)"; mode=${1#--}; }
while [ $# -gt 0 ]; do
  case "$1" in --branch|--jobs|--review) [ $# -ge 2 ] || refuse "$1 needs a value";; esac
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --branch) base=$2; shift 2 ;;
    --build|--remote) setmode "$1"; shift ;;
    --review) setmode "$1"; review=$2; shift 2 ;;
    --jobs) jobs=$2; shift 2 ;;
    -*) refuse "unknown option $1 — nothing reaches geectl local-build build: the project, repo, root and spec are fixed by the base" ;;
    *) [ -z "$dir" ] || refuse "one DIR only (got '$dir' and '$1')"; dir=$1; shift ;;
  esac
done
# geectl local-build build takes no --jobs flag (osc build --jobs has no
# geectl form), so a --jobs is refused outright, not silently dropped —
# after the same validations the option always had.
if [ -n "$jobs" ]; then
  [ "$mode" = build ] || refuse "--jobs goes with --build only"
  [[ $jobs =~ ^[1-9][0-9]*$ ]] || refuse "--jobs takes a positive integer, not '$jobs'"
  refuse "--jobs is refused: geectl local-build build takes no --jobs flag"
fi
# Resolved before the cd: FILE is relative to the caller, not to DIR.
[ -z "$review" ] || review=$(realpath -m -- "$review")

read -r -d '' PY <<'PYEOF'
import glob
import hashlib
import json
import os
import re
import sys
import time
import xml.etree.ElementTree as ET


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def login():
    # The user of the login: GET /user.
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return 1
    u = d.get("login") if isinstance(d, dict) else None
    if not isinstance(u, str) or not u:
        return 1
    print(u)
    return 0


def geectluser():
    # The geectl identity for the default instance: the account the
    # fallback reads when `geectl remote whois` cannot answer.
    u = os.environ.get("GEECTL_OBS_USERNAME", "")
    if not u:
        return 1
    print(u)
    return 0

def pulls(base, user):
    # The pull-request search payload (PullRequestSummary): one row per
    # own PR as "<number>\t<head sha>\t<head branch>". Yours = your fork
    # heads it, as pool-pr.sh decides — the head repo's owner, in any
    # letter case, not who opened it; a deleted fork has no repo.
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return 1
    if not isinstance(d, list):
        return 1
    for p in d:
        m = re.fullmatch(r"gitea:([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9_][A-Za-z0-9_.+-]*)#([0-9]+)", p.get("reference") or "")
        if not m:
            return 1
        if (p.get("target") or {}).get("branch") != base:
            continue
        src = p.get("source") or {}
        owner = (src.get("repository") or "").split("/")[0]
        if owner.lower() != user.lower():
            continue
        head = src.get("commit") or ""
        ref = src.get("branch") or ""
        if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", head):
            return 1
        print("%s\t%s\t%s" % (m.group(3), head, ref))
    return 0


def arches():
    # The project-meta JSON: repositories carry their arches as a list.
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return 1
    if not isinstance(d, dict):
        return 1
    for r in d.get("repositories") or []:
        if r.get("name") == "standard":
            a = [x for x in (r.get("arch") or []) if x and x != "local"]
            if a:
                print(" ".join(a))
                return 0
    return 1

def flavors(path):
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError):
        return 1
    for e in root:
        if e.tag in ("package", "flavor") and (e.text or "").strip():
            print(e.text.strip())
    return 0


def qr(arch):
    # queryrecipe --format json: OBS's own parser under the target's config.
    try:
        q = json.load(sys.stdin)
    except ValueError:
        return 1
    if not isinstance(q, dict) or not q.get("name"):
        return 1
    excl = q.get("exclarch")
    out = (excl is not None and arch not in excl) or arch in (q.get("badarch") or [])
    print("excluded" if out else "builds")
    return 0


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def save(path, d):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(d, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def stamp_write(path, *kv):
    d = dict(x.split("=", 1) for x in kv)
    d["arches"] = [a for a in d.get("arches", "").split(",") if a]
    if "flavors" in d:
        d["flavors"] = d["flavors"].split("|")
    d["time"] = now()
    old = load(path)
    # A rebuild of the same tree keeps the review of that tree.
    if old and old.get("tree") == d["tree"] and old.get("review"):
        d["review"] = old["review"]
    save(path, d)
    return 0


def last(sd, base, tree):
    # The newest GREEN build of another tree on this base.
    best = None
    for p in glob.glob(os.path.join(sd, "*-%s.json" % base)):
        d = load(p)
        t = os.path.basename(p)[: -len("-%s.json" % base)]
        if not d or d.get("tree") != t or d.get("base") != base or t == tree:
            continue
        if d.get("verdict") == "GREEN":
            key = (d.get("time") or "", os.path.getmtime(p))
            if best is None or key > best[0]:
                best = (key, t)
    if best is None:
        return 1
    print(best[1])
    return 0


def touched(new):
    # changelog validate --entries: down to the deepest entry of NEW that the
    # stamped tree's copy (stdin) lacks verbatim.
    def entries(text):
        return [e for e in re.split(r"(?m)^(?=---)", text) if e.strip()]

    old = set(entries(sys.stdin.read()))
    try:
        with open(new, encoding="utf-8", errors="replace") as fh:
            ents = entries(fh.read())
    except OSError:
        return 1
    print(max([i + 1 for i, e in enumerate(ents) if e not in old] or [1]))
    return 0


def carry(src, dst, *kv):
    # The build verdict of src for a tree that differs only in .changes;
    # never its review (stamp_write keeps one only for the same tree).
    s = load(src)
    if not s or s.get("verdict") != "GREEN":
        return 1
    extra = ["arches=" + ",".join(s.get("arches") or [])]
    if s.get("flavors") is not None:
        extra.append("flavors=" + "|".join(s["flavors"]))
    return stamp_write(dst, *(extra + list(kv)))


def built(d):
    if d.get("mode") == "carried":
        return "carried from %s, %s" % ((d.get("from") or "?")[:12], d.get("time"))
    return "%s, %s" % (d.get("mode"), d.get("time"))


def stamp_check(sd, tree, base):
    t12, path = tree[:12], os.path.join(sd, "%s-%s.json" % (tree, base))
    if os.path.exists(path):
        d = load(path)
        if not d or d.get("tree") != tree or d.get("base") != base:
            print("VERDICT: NO BUILD — unreadable stamp %s" % path)
            return 3
        if d.get("verdict") != "GREEN":
            print("VERDICT: NO BUILD — tree %s on %s is not GREEN" % (t12, base))
            return 3
        rv = d.get("review") or {}
        if rv.get("verdict") != "PASS":
            print(
                "VERDICT: NO REVIEW — tree %s on %s built GREEN (%s); "
                "run the change review, then --review FILE" % (t12, base, built(d))
            )
            return 3
        print(
            "VERDICT: GREEN — tree %s on %s: build GREEN (%s), review PASS (%s)"
            % (t12, base, built(d), rv.get("time"))
        )
        return 0
    same = sorted(glob.glob(os.path.join(sd, "*-%s.json" % base)), key=os.path.getmtime)
    if same:
        print(
            "VERDICT: STALE — stamped %s, HEAD %s on %s: build HEAD's tree"
            % (os.path.basename(same[-1])[:12], t12, base)
        )
        return 3
    other = sorted(
        os.path.basename(p)[len(tree) + 1 : -5]
        for p in glob.glob(os.path.join(sd, tree + "-*.json"))
    )
    if other:
        print(
            "VERDICT: NO BUILD — tree %s is stamped for %s, not %s"
            % (t12, ", ".join(other), base)
        )
        return 3
    print("VERDICT: NO BUILD — no build of tree %s on %s" % (t12, base))
    return 3


def review(path, tree, base, fpath):
    d = load(path)
    if not d or d.get("tree") != tree or d.get("verdict") != "GREEN":
        print(
            "VERDICT: NO BUILD — no GREEN build of tree %s on %s: build before review"
            % (tree[:12], base)
        )
        return 3
    try:
        with open(fpath, "rb") as fh:
            raw = fh.read()
    except OSError as e:
        print("VERDICT: REFUSED — cannot read %s: %s" % (fpath, e.strerror))
        return 2
    text = raw.decode("utf-8", "replace")
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    first = lines[0] if lines else ""
    # Only the verdict line binds: a body may quote Factory's or the old tree.
    trees = re.findall(r"\btree ([0-9a-f]{12,})\b", first)
    bad = None
    if not re.match(r"PASS\b", first):
        bad = "review verdict is '%s', not PASS" % first[:40]
    elif not trees:
        bad = "the PASS line names no 'tree <sha12>'"
    else:
        wrong = sorted({t for t in trees if not tree.startswith(t)})
        if wrong:
            bad = "review names tree %s, HEAD is tree %s" % (wrong[0][:12], tree[:12])
    if bad:
        if d.pop("review", None) is not None:
            save(path, d)
        print("VERDICT: RED — " + bad)
        return 1
    d["review"] = {
        "verdict": "PASS",
        "sha256": hashlib.sha256(raw).hexdigest(),
        "time": now(),
    }
    save(path, d)
    print("VERDICT: GREEN — review PASS recorded for tree %s on %s" % (tree[:12], base))
    return 0


def prjmeta(prj, user, *triples):
    # The current meta arrives as the project-meta JSON (geectl remote
    # project-meta); the new meta goes out as XML (geectl remote
    # set-project-meta --from-file reads the meta document). The JSON
    # carries no publish flag, so the emitted meta always disables
    # publishing: the leapgate project never publishes, matching the
    # meta target-gate creates. A meta with lock or build flags would
    # lose them here — target-gate never sets those on this project.
    text = sys.stdin.read().strip()
    want = [
        (triples[i], triples[i + 1], triples[i + 2].split(","))
        for i in range(0, len(triples), 3)
    ]
    if text:
        try:
            d = json.loads(text)
        except ValueError:
            return 1
        if not isinstance(d, dict):
            return 1
        name = d.get("name") or prj
        title = d.get("title")
        desc = d.get("description")
        persons = d.get("persons") or []
        repos = {}
        for r in d.get("repositories") or []:
            if r.get("name"):
                repos[r["name"]] = r
        changed = False
    else:
        name = prj
        title = "target-gate remote builds"
        desc = "Exact trees built before a Leap pool PR is opened; transient."
        persons = [{"name": user, "role": "maintainer"}]
        repos = {}
        changed = True
    for rname, pprj, arch in want:
        cur = repos.get(rname)
        if (
            cur is not None
            and [(p.get("project"), p.get("repository")) for p in (cur.get("paths") or [])]
            == [(pprj, "standard")]
            and sorted(cur.get("arch") or []) == sorted(arch)
        ):
            continue
        changed = True
        repos[rname] = {
            "name": rname,
            "paths": [{"project": pprj, "repository": "standard"}],
            "arch": list(arch),
        }
    if not changed:
        return 4
    root = ET.Element("project", name=name)
    if title:
        ET.SubElement(root, "title").text = title
    if desc is not None:
        ET.SubElement(root, "description").text = desc
    for p in persons:
        ET.SubElement(root, "person", userid=p.get("name", ""), role=p.get("role", ""))
    ET.SubElement(ET.SubElement(root, "publish"), "disable")
    for rname, r in repos.items():
        re_ = ET.SubElement(root, "repository", name=rname)
        for p in r.get("paths") or []:
            ET.SubElement(
                re_, "path", project=p.get("project", ""), repository=p.get("repository", "")
            )
        for a in r.get("arch") or []:
            ET.SubElement(re_, "arch").text = a
    print(ET.tostring(root, encoding="unicode"))
    return 0

def pkgmeta(prj, pkg, url, other):
    # The current meta arrives as the package-meta JSON (geectl remote
    # package-meta); the new meta goes out as XML (geectl remote
    # set-package-meta --from-file reads the meta document). The JSON
    # carries no build flags, so the no-change check reads the scmsync
    # URL only: the build/disable flag is set by target-gate itself when
    # the package is created, so a matching scmsync means the meta is as
    # target-gate left it.
    text = sys.stdin.read().strip()
    if text:
        try:
            d = json.loads(text)
        except ValueError:
            return 1
        if not isinstance(d, dict):
            return 1
        if (d.get("scmsync") or "").strip() == url:
            return 4
    root = ET.Element("package", name=pkg, project=prj)
    ET.SubElement(root, "title").text = "%s at the tree under review" % pkg
    ET.SubElement(root, "description")
    # The other base's repo would build a tree that is not its own.
    ET.SubElement(ET.SubElement(root, "build"), "disable", repository=other)
    ET.SubElement(root, "scmsync").text = url
    print(ET.tostring(root, encoding="unicode"))
    return 0

def results(repo, required):
    # The build-results JSON: one object per repository/architecture cell,
    # each with its per-package codes; a cell's dirty flag is a boolean.
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return 2
    if not isinstance(d, dict) or not isinstance(d.get("results"), list):
        return 2
    ok, bad = (
        {"succeeded", "excluded", "disabled"},
        {"failed", "unresolvable", "broken"},
    )
    req = set(required.split())
    codes, dirty, built, seen = [], [], set(), set()
    for cell in d["results"]:
        if cell.get("repository") != repo:
            continue
        arch = cell.get("arch")
        # An arch the PR bot never builds is not this base's verdict.
        if arch not in req:
            continue
        if cell.get("dirty") is True or cell.get("state") in ("scheduling", "outdated"):
            dirty.append(arch)
        row = []
        for s in cell.get("statuses") or []:
            code = s.get("code") or "unknown"
            codes.append(code)
            seen.add(arch)
            if code == "succeeded":
                built.add(arch)
                print("#built %s %s" % (arch, s.get("package")))
            det = (s.get("details") or "").strip()
            row.append(
                "%s %s%s"
                % (
                    s.get("package"),
                    code,
                    " (%s)" % det[:80] if det and code in bad else "",
                )
            )
        print("  %s: %s" % (arch, ", ".join(row) or "no status"))
    print("#arches " + " ".join(sorted(built)))
    if not codes:
        print("#why no results for repository %s yet" % repo)
        return 3
    if any(c in bad for c in codes):
        return 1
    if dirty or any(c not in ok for c in codes):
        print(
            "#why still scheduling or building%s"
            % (" (dirty: %s)" % " ".join(dirty) if dirty else "")
        )
        return 3
    if req - seen:
        print("#why no result on %s yet" % " ".join(sorted(req - seen)))
        return 3
    if not built:
        if all(c == "excluded" for c in codes):
            print("#why excluded on every arch: nothing was built")
            return 1
        print("#why repository %s not enabled yet" % repo)
        return 3
    return 0

def srcmd5():
    # A package-log's newest entry srcmd5; a job-history's newest job's.
    # Both payloads carry their entries newest first with a srcmd5 each.
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return 2
    if not isinstance(d, dict):
        return 2
    entries = d.get("entries") or []
    m = entries[0].get("srcmd5") if entries else None
    if not m:
        return 1
    print(m)
    return 0

def buildinfo():
    # The buildinfo JSON's blocking error, if any (null when the package
    # resolves): print it and return 1; return 0 when there is none.
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return 2
    if not isinstance(d, dict):
        return 2
    err = d.get("error")
    if err:
        print(err)
        return 1
    return 0


cmd, args = sys.argv[1], sys.argv[2:]
fn = {
    "login": login,
    "geectluser": geectluser,
    "pulls": pulls,
    "arches": arches,
    "flavors": flavors,
    "qr": qr,
    "stamp-write": stamp_write,
    "stamp-check": stamp_check,
    "last": last,
    "touched": touched,
    "carry": carry,
    "review": review,
    "prjmeta": prjmeta,
    "pkgmeta": pkgmeta,
    "results": results,
    "srcmd5": srcmd5,
    "buildinfo": buildinfo,
}[cmd]
sys.exit(fn(*args))
PYEOF
py() { python3 -I -c "$PY" "$@"; }

tmpd=$(mktemp -d "${TMPDIR:-/var/tmp}/target-gate.XXXXXX") || refuse "mktemp failed"
trap 'rm -rf "$tmpd"' EXIT

cd "${dir:-.}" 2>/dev/null || refuse "no such directory: ${dir:-.}"
rdir=$(pwd -P)
building=0; case "$mode" in build|remote) building=1;; esac
if [ $building = 1 ]; then
  # Build evidence must outlive the session, and /tmp is where the unbuilt
  # tesseract trees lived.
  case "$rdir/" in
    /tmp/*|*/scratchpad/*) refuse "$rdir is under /tmp or a scratchpad — clone the package somewhere persistent" ;;
  esac
fi
top=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "$rdir is not a git clone"
[ "$top" = "$rdir" ] || refuse "run on the clone's top level ($top), not $rdir"
if [ $building = 1 ]; then
  # A detached HEAD is no branch to push or build from.
  git symbolic-ref -q HEAD >/dev/null || refuse "detached HEAD — check out a named branch"
fi

if [ -z "$base" ]; then
  up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) \
    || refuse "no --branch and the current branch has no upstream — pass --branch leap-16.0 or leap-16.1"
  case "$up" in
    origin/*) base=${up#origin/} ;;
    *) refuse "upstream is $up, not origin/<base> — pass --branch" ;;
  esac
fi
# The project a base builds against. The PR bot builds in its :PullRequest
# subproject, whose own meta names the arches (pr_arches).
bprj() { case "$1" in leap-16.0) echo openSUSE:Backports:SLE-16.0;; leap-16.1) echo openSUSE:Backports:SLE-16.1;; esac; }
case "$base" in
  leap-16.0) marker=160000 ;;
  leap-16.1) marker=160100 ;;
  slfo-*) refuse "$base: an SLFO target needs a route the user names — no pool fork PRs to slfo branches" ;;
  factory) refuse "factory: not a Leap target — Factory takes submit requests, not pool PRs" ;;
  *) refuse "base '$base' is not a Leap target (leap-16.0, leap-16.1)" ;;
esac
prj=$(bprj "$base")
head=$(git rev-parse -q --verify HEAD) || refuse "no commit on HEAD"
tree=$(git rev-parse "HEAD^{tree}")
sd="$(git rev-parse --path-format=absolute --git-common-dir)/target-gate" || refuse "no git common dir"
stamp="$sd/$tree-$base.json"

if [ "$mode" = check ]; then py stamp-check "$sd" "$tree" "$base"; exit $?; fi
if [ "$mode" = review ]; then py review "$stamp" "$tree" "$base" "$review"; exit $?; fi

# --- preconditions shared by --build and --remote -----------------------------
ourl=$(git config --get remote.origin.url) || refuse "no origin remote"
[[ $ourl =~ src\.opensuse\.org[:/]+pool/([^/]+)/?$ ]] || refuse "origin is $ourl, not src.opensuse.org/pool/<pkg>"
pkg=${BASH_REMATCH[1]%.git}
[ -f "$pkg.spec" ] || refuse "no $pkg.spec in $rdir"
# The build copies ignored and untracked files into the build too.
st=$(git status --porcelain --ignored --untracked-files=all) || refuse "git status failed"
[ -z "$st" ] || refuse "worktree not clean: $(printf '%s\n' "$st" | head -5 | paste -sd';')"
lfs=$(git lfs ls-files 2>&1) || refuse "cannot list LFS files (is git-lfs installed?): $lfs"
bad=$(printf '%s\n' "$lfs" | awk '$2 == "-" {print $3}' | paste -sd' ')
[ -z "$bad" ] || refuse "LFS files not smudged (pointers only — run git lfs pull): $bad"

git rev-parse -q --verify "refs/remotes/origin/$base" >/dev/null || refuse "no origin/$base — git fetch origin $base"
git merge-base --is-ancestor "origin/$base" HEAD || refuse "HEAD does not contain origin/$base — rebase onto it"
# The forge user, through geectl: the token owner of the configured Gitea
# instance. The open-PRs read below is geectl too.
gerr() { local e; e=$(grep -v '^Response:$' "$tmpd/gerr" | tail -1); echo "${e:-no usable answer}"; }
guser=$(timeout 60 geectl --format json gitea whoami 2>"$tmpd/gerr" | py login) || refuse "cannot read your src.opensuse.org user through geectl: $(gerr)"
# One call: pull-request search pages the Gitea list internally (bounded
# at 500), so there is no page loop here.
js=$(timeout 60 geectl pull-request search --backend gitea --repo "pool/$pkg" --state open 2>"$tmpd/gerr") \
  || refuse "cannot read the open PRs of pool/$pkg (lookup failed, not 'none'): $(gerr)"
mine=$(printf '%s' "$js" | py pulls "$base" "$guser") || refuse "unparseable open-PR list for pool/$pkg"
# One such PR is the one this tree updates; two means HEAD carries both.
anc=()
while IFS=$'\t' read -r num sha ref; do
  [ -n "$sha" ] || continue
  git merge-base --is-ancestor "$sha" HEAD 2>/dev/null || continue
  git merge-base --is-ancestor "$sha" "origin/$base" 2>/dev/null && continue
  anc+=("#$num ($ref)")
done <<<"$mine"
[ ${#anc[@]} -le 1 ] || refuse "stacked: HEAD contains the heads of your open PRs ${anc[*]} to $base — each PR carries its own change on top of origin/$base"

say "target-gate: $pkg tree ${tree:0:12} (commit ${head:0:12}) on $base -> $prj standard"
mkdir -p "$sd" || refuse "cannot create $sd"
[ ${#anc[@]} -eq 0 ] || say "note: HEAD extends your open PR ${anc[0]} — pool-pr.sh updates that PR"

# A changelog changes nothing that builds but a heading `geectl changelog
# validate` checks, so a .changes-only step from the base's last GREEN tree
# carries that build, not its review. A tree stamped already is built for real.
if [ ! -e "$stamp" ] && from=$(py last "$sd" "$base" "$tree") \
   && ns=$(git diff --no-renames --name-status "$from" HEAD 2>/dev/null) && [ -n "$ns" ] \
   && files=$(awk -F'\t' '$1 !~ /^[AM]$/ || $2 !~ /\.changes$/ {exit 1} {print $2}' <<<"$ns"); then
  carry=1
  while IFS= read -r f; do
    n=$({ git show "$from:$f" 2>/dev/null || :; } | py touched "$f") || n=1
    if ! out=$(geectl changelog validate "$(dirname -- "$f")" --entries "$n" 2>&1); then
      say "note: $f fails changelog validate — building, not carrying tree ${from:0:12}:"
      printf '%s\n' "$out" | head -5
      carry=0
    fi
  done <<<"$files"
  if [ $carry = 1 ]; then
    py carry "$sd/$from-$base.json" "$stamp" tree="$tree" commit="$head" base="$base" project="$prj" \
      mode=carried from="$from" verdict=GREEN || refuse "cannot write $stamp"
    v=differs; [ "$(wc -l <<<"$files")" = 1 ] || v=differ
    say "VERDICT: GREEN — tree ${tree:0:12} on $base: only $(paste -sd' ' <<<"$files") $v from GREEN tree ${from:0:12}, whose build carries; stamped $stamp — the review does not carry"
    exit 0
  fi
fi

pr_arches() {   # arches the PR bot builds for base $1; Backports itself has more
  local p m a
  p="$(bprj "$1"):PullRequest"
  m=$(geectl remote project-meta "$p" 2>&1) || refuse "cannot read the $p meta: $(tail -1 <<<"$m")"
  a=$(py arches <<<"$m") || refuse "no standard repository arches in the $p meta"
  echo "$a"
}

# ============================== --remote =======================================
if [ "$mode" = remote ]; then
  obsuser=$(geectl remote whois 2>/dev/null | py login)
  [ -n "$obsuser" ] || obsuser=$(py geectluser) || obsuser=""
  [ -n "$obsuser" ] || refuse "cannot determine your OBS account (geectl remote whois failed, no GEECTL_OBS_USERNAME)"
  gprj="home:$obsuser:leapgate"
  triples=(); req=""
  for b in leap-16.0 leap-16.1; do
    a=$(pr_arches "$b") || exit 2
    triples+=("$b" "$(bprj "$b")" "${a// /,}")
    [ "$b" != "$base" ] || req=$a
  done
  other=leap-16.1; [ "$base" = leap-16.1 ] && other=leap-16.0
  br="leapgate/$base-${head:0:12}"
  url="$G/$guser/$pkg?trackingbranch=$br#$head"

  # An existing fork is no error: repo-fork returns the existing fork
  # instead of failing. A failure shows, the push decides.
  forkerr=$(timeout 60 geectl gitea repo-fork pool "$pkg" --live 2>&1 >/dev/null) \
    || say "geectl gitea repo-fork pool/$pkg failed: $(tail -1 <<<"$forkerr")"
  git remote add leapgate "$GS:$guser/$pkg.git" 2>/dev/null || git remote set-url leapgate "$GS:$guser/$pkg.git"
  # A fork does not share the parent's LFS store, and the pre-push hook would
  # upload every object in the history: exactly this tree's objects first,
  # then the ref without the hook, so the branch never points at a pointer.
  # Both over SSH: git-lfs asks the forge for its credentials there.
  oids=$(git lfs ls-files -l | awk '{print $1}')
  if [ -n "$oids" ]; then
    # shellcheck disable=SC2086  # one argument per object id
    git lfs push --object-id leapgate $oids \
      || refuse "LFS object push to $guser/$pkg failed — OBS would fetch dangling pointers"
  fi
  git push -q --no-verify leapgate "HEAD:refs/heads/$br" \
    || refuse "push to $guser/$pkg:$br failed"

  metaget() {   # metaget prj|pkg ARGS... — current meta, empty when it does not exist
    local out rc
    case "$1" in
      prj) out=$(geectl remote project-meta "$2" 2>&1); rc=$? ;;
      pkg) out=$(geectl remote package-meta "$2" "$3" 2>&1); rc=$? ;;
      *) refuse "metaget: unknown kind $1" ;;
    esac
    [ $rc = 0 ] && { printf '%s' "$out"; return 0; }
    # A missing project or package is not an error here: geectl reports
    # it as not_found (rc 3), and the callers treat an empty meta as
    # "does not exist yet".
    case "$out" in *not_found*|*404*|*"Not Found"*) return 0 ;; esac
    [ $rc = 3 ] && return 0
    refuse "cannot read the meta of $*: $(tail -1 <<<"$out")"
  }
  changed=0
  cur=$(metaget prj "$gprj") || exit 2
  new=$(py prjmeta "$gprj" "$obsuser" "${triples[@]}" <<<"$cur"); rc=$?
  case $rc in
    0) printf '%s\n' "$new" > "$tmpd/prj.xml"
       geectl remote set-project-meta --from-file "$tmpd/prj.xml" "$gprj" --live >/dev/null 2>"$tmpd/err" || refuse "writing the $gprj meta failed: $(tail -1 "$tmpd/err")"
       say "set up $gprj (leap-16.0, leap-16.1)" ;;
    4) ;;
    *) refuse "unparseable $gprj meta" ;;
  esac
  cur=$(metaget pkg "$gprj" "$pkg") || exit 2
  new=$(py pkgmeta "$gprj" "$pkg" "$url" "$other" <<<"$cur"); rc=$?
  case $rc in
    0) printf '%s\n' "$new" > "$tmpd/pkg.xml"
       geectl remote set-package-meta --from-file "$tmpd/pkg.xml" "$gprj" "$pkg" --live >/dev/null 2>"$tmpd/err" || refuse "writing the $gprj/$pkg meta failed: $(tail -1 "$tmpd/err")"
       changed=1 ;;
    4) ;;
    *) refuse "unparseable $gprj/$pkg meta" ;;
  esac
  [ $changed = 0 ] || pending "pointed $gprj/$pkg at $br#${head:0:12} — re-run to poll"

  # obsinfo and every build are held to one source revision: until the
  # scheduler catches up, a build of the previous one still reads "succeeded".
  # The newest package-log entry's srcmd5 is the directory's: the package
  # links nothing, so the expanded listing and the revision agree.
  src=$(geectl remote package-log --limit 1 "$gprj" "$pkg" 2>&1) || refuse "cannot read the $gprj/$pkg package log: $(tail -1 <<<"$src")"
  smd5=$(py srcmd5 <<<"$src") || refuse "no srcmd5 in the $gprj/$pkg package log"
  info=$(geectl remote cat --rev "$smd5" "$gprj" "$pkg" _scmsync.obsinfo 2>&1) || pending "$gprj/$pkg has no _scmsync.obsinfo yet — re-run to poll"
  got=$(sed -n 's/^commit: *//p' <<<"$info" | head -1)
  [ "$got" = "$head" ] || pending "OBS synced ${got:-nothing}, HEAD is $head — re-run to poll"
  res=$(geectl build results --repository "$base" --package "$pkg" "$gprj" 2>&1) || refuse "cannot read the $gprj/$pkg results: $(tail -1 <<<"$res")"
  sum=$(py results "$base" "$req" <<<"$res"); rc=$?
  grep -v '^#' <<<"$sum"
  why=$(sed -n 's/^#why //p' <<<"$sum")
  if [ $rc = 0 ]; then
    stale=()
    # The last job, not _history: an unchanged rebuild adds no entry there.
    while read -r a p; do
      h=$(geectl build job-history --package "$p" --limit 1 "$gprj" "$base" "$a" 2>&1) \
        || refuse "cannot read the $gprj/$base/$a/$p job history: $(tail -1 <<<"$h")"
      m=$(py srcmd5 <<<"$h"); [ $? != 2 ] || refuse "unparseable $gprj/$base/$a/$p job history"
      [ "$m" = "$smd5" ] || { m=${m:0:12}; stale+=("$a/$p (built ${m:-nothing})"); }
    done < <(sed -n 's/^#built //p' <<<"$sum")
    [ ${#stale[@]} -eq 0 ] || pending "source ${smd5:0:12} not built yet on ${stale[*]} — re-run to poll"
  fi
  case $rc in
    0) py stamp-write "$stamp" tree="$tree" commit="$head" base="$base" project="$prj" mode=remote \
         arches="$(sed -n 's/^#arches //p' <<<"$sum" | tr ' ' ',')" \
         obs_project="$gprj" verdict=GREEN || refuse "cannot write $stamp"
       # The branch and the package served their purpose: the stamp is the
       # evidence. Delete this run's fork branch and scratch package so they
       # don't pile up. Only on green -- a red build keeps both for debugging.
       git push -q leapgate --delete "$br" 2>/dev/null \
         || say "note: could not delete the fork branch $br"
       geectl remote delete-package --message "target-gate: tree ${tree:0:12} GREEN on $base, stamped" "$gprj" "$pkg" --live </dev/null >/dev/null 2>"$tmpd/err" \
         || say "note: could not delete $gprj/$pkg: $(tail -1 "$tmpd/err")"
       say "VERDICT: GREEN — tree ${tree:0:12} built on $gprj/$base at commit ${head:0:12}; stamped $stamp"
       exit 0 ;;
    1) rm -f "$stamp"
       say "VERDICT: RED — $gprj/$pkg on $base ${why:-failed} (geectl build build-log $gprj $pkg $base <arch>)"
       exit 1 ;;
    3) pending "${why:-building} — re-run to poll" ;;
    *) refuse "unparseable $gprj/$pkg results" ;;
  esac
fi

# ============================== --build ========================================
native=$(uname -m)
arches=$(pr_arches "$base") || exit 2
case " $arches " in
  *" $native "*) ;;
  *) refuse "host arch $native is not one $prj:PullRequest builds ($arches) — builds are never emulated; use --remote" ;;
esac

# The build-root base from geectl's cache, as build-summary.sh reads it.
CACHE=$(geectl config show 2>/dev/null | python3 -I -c \
  'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("build_cache_dir") or "")')
: "${CACHE:=${XDG_CACHE_HOME:-$HOME/.cache}/geectl}"
# Per base: 16.0 and 16.1 are different roots, and neither may reuse the
# <pkg>-standard-<arch> root of some other build.
root="$CACHE/build-roots/$pkg-$base-$native"

mounted() {   # mounts at or under $1; rc 2 when findmnt cannot tell
  local m
  m=$(findmnt -rn -o TARGET) || return 2
  printf '%s\n' "$m" | awk -v r="$1" '$0 == r || index($0, r "/") == 1'
}

flavors=("")
if [ -f _multibuild ]; then
  fl=$(py flavors _multibuild) || refuse "_multibuild is unreadable"
  while IFS= read -r f; do [ -z "$f" ] || flavors+=("$f"); done <<<"$fl"
fi

# Which flavor builds on which arch, decided as OBS decides it under the
# target's build config: the recipe's ExclusiveArch/ExcludeArch, then the
# prjconf's per-arch onlybuild/excludebuild lists (Backports whitelists i586).
# Decided before any build, so a missing native route is refused up front.
qrbin="${BUILD_DIR:-/usr/lib/build}/queryrecipe"; qcbin="${BUILD_DIR:-/usr/lib/build}/queryconfig"
{ [ -x "$qrbin" ] && [ -x "$qcbin" ]; } || refuse "$qrbin or $qcbin not found (obs-build, which geectl local-build build needs)"
geectl build buildconfig "$prj" standard > "$tmpd/buildconfig" 2>"$tmpd/err" \
  || refuse "cannot read the $prj standard build config: $(tail -1 "$tmpd/err")"
declare -A onlyb exclb
for a in $arches; do
  for k in onlybuild excludebuild; do
    v=$("$qcbin" --dist "$tmpd/buildconfig" --archpath "$a" buildflags+ "$k" 2>/dev/null) \
      || refuse "queryconfig cannot read the $prj build flags for $a"
    if [ "$k" = onlybuild ]; then onlyb[$a]=$v; else exclb[$a]=$v; fi
  done
done
flagged() {   # flagged ARCH PACKID — the build flags exclude pkg or pkg:flavor there
  local id=$2 p=${2%%:*}
  grep -qxF -e "$id" -e "$p" <<<"${exclb[$1]}" && return 0
  [ -n "${onlyb[$1]}" ] && ! grep -qxF -e "$id" -e "$p" <<<"${onlyb[$1]}"
}
todo=(); others=(); built=(); resolved=" "
for i in "${!flavors[@]}"; do
  f=${flavors[$i]}; ok=""
  for a in $arches; do
    q=$("$qrbin" --dist "$tmpd/buildconfig" --arch "$a" --buildflavor "$f" --format json "$rdir/$pkg.spec" 2>/dev/null | py qr "$a") \
      || refuse "queryrecipe cannot parse $pkg.spec for $a${f:+ flavor $f}"
    [ "$q" = builds ] && ! flagged "$a" "$pkg${f:+:$f}" && ok+=" $a"
  done
  if [ -z "$ok" ]; then say "flavor ${f:-(none)}: excluded on every $base arch, skipped"; continue; fi
  case "$ok " in
    *" $native "*) ;;
    *) refuse "flavor ${f:-(none)} builds on$ok but not on $native — no native route; use --remote" ;;
  esac
  todo+=("$i"); others+=("$(tr ' ' '\n' <<<"$ok" | grep -vx -e "$native" -e '' | paste -sd' ')")
done
[ ${#todo[@]} -gt 0 ] || refuse "nothing builds on $base: every flavor is excluded on every arch"

reds=()
red() { reds+=("$*"); say "RED: $*"; }
# geectl's own error lines (its stdout is block-buffered, so they can land after
# the build's), else the log's tail; sanitized, as build output is third-party.
excerpt() {
  local ex
  ex=$(grep -aE 'Build failed with exit code|Server returned an error|^Error' "$1" | tail -n 3)
  [ -n "$ex" ] || ex=$(tail -n 3 "$1")
  [ -n "$ex" ] || return 0
  printf '%s\n' "$ex" | python3 "$HERE/_sanitize.py" | sed 's/^/  /' \
    || say "  (log excerpt withheld: $HERE/_sanitize.py failed)"
}
# Log text quoted in a RED line, sanitized the same way.
clean() { printf '%s' "$1" | python3 "$HERE/_sanitize.py" || printf '(withheld: %s failed)' "$HERE/_sanitize.py"; }
for k in "${!todo[@]}"; do
  f=${flavors[${todo[$k]}]}; fs=${f:+ --flavor $f}
  say "flavor ${f:-(none)}: build $native, resolve ${others[$k]:-nothing else}"
  # A cheap resolution failure elsewhere spares the long native build.
  for a in ${others[$k]}; do
    # A multibuild flavor is addressed as pkg:flavor, the same form the
    # build-log leaf's --multibuild appends to the package.
    bpkg="$pkg${f:+:$f}"
    if ! out=$(geectl build buildinfo --project "$prj" --package "$bpkg" --alternative-project "$prj" standard "$a" 2>&1 </dev/null)
    then
      red "buildinfo $a$fs: lookup failed: $(tail -1 <<<"$out")"
    else
      err=$(py buildinfo <<<"$out"); brc=$?
      if [ $brc = 2 ]; then
        red "buildinfo $a$fs: lookup failed: unparseable buildinfo"
      elif [ -n "$err" ]; then
        red "buildinfo $a$fs: $err"
      else
        resolved+="$a "
      fi
    fi
  done
  [ ${#reds[@]} -eq 0 ] || break

  # geectl local-build build --clean on a root with a bind-mounted /dev wipes the host's /dev.
  m=$(mounted "$root"); [ $? -ne 2 ] || refuse "findmnt failed — cannot rule out mounts under $root"
  [ -z "$m" ] || refuse "mounted under $root: $(paste -sd' ' <<<"$m") — unmount before building there"
  cmd=(geectl local-build build --clean --trust-all-projects --root "$root" --alternative-project="$prj" --project "$prj" --repo standard --arch "$native" --live)
  [ -z "$f" ] || cmd+=(--flavor "$f")
  cmd+=("$rdir")
  # geectl's output is the build log: a VM build (build-type=kvm) puts no
  # installed-pkg in the root, and the root's .build.log can be empty (e.g.
  # with build-shell-after-fail). The guest's console adds CRs and NULs.
  blog="$tmpd/build.log"
  # A second early: the RPMs a VM hands back carry whole-second times.
  touch -d '1 second ago' "$tmpd/start" || refuse "cannot write $tmpd/start"
  "${cmd[@]}" </dev/null 2>&1 | tr -d '\000\r' > "$blog"; orc=${PIPESTATUS[0]}

  # The build runs in $root, or in $root/.mount under a VM, and leaves the
  # packages in that root's .build.packages.
  broot=$(sed -n '/Using BUILD_ROOT=/{s/.*Using BUILD_ROOT=//p;q;}' "$blog")
  if [ "$broot" != "$root" ] && [ "$broot" != "$root/.mount" ]; then
    red "build$fs: the log built in $(clean "${broot:-no build root}"), not $root, geectl local-build build rc=$orc"
    excerpt "$blog"
  else
    bs=$("$HERE/build-summary.sh" --rpms "$broot/.build.packages" "$blog" 2>&1); brc=$?
    if [ $brc -ne 0 ] || [ "$orc" -ne 0 ]; then
      red "build$fs: build-summary rc=$brc ($(grep -m1 -o 'VERDICT: .*\|no readable build log' <<<"$bs")), geectl local-build build rc=$orc"
    fi
    # obs-build empties .build.packages first; in a root it did not set up, files
    # older than this build are an earlier build's.
    old=$(find "$broot/.build.packages/RPMS" "$broot/.build.packages/SRPMS" -type f ! -newer "$tmpd/start" 2>/dev/null \
      | sed 's#.*/##' | sort | head -3 | paste -sd' ')
    [ -z "$old" ] || red "rpms$fs: $broot/.build.packages holds files from before this build ($old) — an earlier build's RPMs are no evidence"
  fi
  # The tesseract discriminator: the log names the recipe it built (a VM
  # guest also names its own copy, //.build-srcdir/<pkg>.spec).
  recipes=$(grep -ao 'processing recipe [^ ]*' "$blog" | sed 's/^processing recipe //' \
    | grep -vxF "//.build-srcdir/$pkg.spec" | sort -u | paste -sd' ')
  if [ "$recipes" != "$rdir/$pkg.spec" ]; then
    [ -z "$recipes" ] || recipes=$(clean "$recipes")
    red "recipe$fs: the log built ${recipes:-no recipe}, not $rdir/$pkg.spec${recipes:+ — a build of another checkout is no evidence}"
  fi
  st=$(git status --porcelain --ignored --untracked-files=all)
  if [ "$(git rev-parse 'HEAD^{tree}')" != "$tree" ]; then
    red "worktree$fs: HEAD's tree changed during the build — the built tree is not the one stamped"
  elif [ -n "$st" ]; then
    red "worktree$fs: the build left it dirty ($(printf '%s\n' "$st" | head -3 | paste -sd';')) — the built tree is not HEAD's"
  fi
  # Tripwire: the root really is the base's product (release 16.0.x/16.1.x),
  # as init_buildsystem logs installing it.
  rcs=$(grep -m1 -aoE '(^| )(cumulate|installing|keeping|preinstalled) rpm-config-SUSE-[0-9][^ ]*' "$blog" | sed 's/^ *[a-z]* //')
  case "$rcs" in
    *"-$marker."*) ;;
    *) [ -z "$rcs" ] || rcs=$(clean "$rcs")
       red "base$fs: root has ${rcs:-no rpm-config-SUSE}, want release -$marker.* for $base" ;;
  esac
  [ ${#reds[@]} -eq 0 ] || break
  built+=("$f")
done

if [ ${#reds[@]} -gt 0 ]; then
  rm -f "$stamp"
  say "VERDICT: RED — ${#reds[@]} check(s) failed for tree ${tree:0:12} on $base (root $root)"
  exit 1
fi
py stamp-write "$stamp" tree="$tree" commit="$head" base="$base" project="$prj" mode=local \
  arches="$(tr ' ' '\n' <<<"$native$resolved" | grep -v '^$' | sort -u | paste -sd,)" \
  flavors="$(IFS='|'; echo "${built[*]}")" root="$root" verdict=GREEN || refuse "cannot write $stamp"
r=${resolved# }; r=${r% }
say "VERDICT: GREEN — tree ${tree:0:12} on $base: built $native, resolves ${r:-no other arch}; stamped $stamp"
exit 0
