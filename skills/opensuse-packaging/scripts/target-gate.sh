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
#   --jobs N       the only option passed through to the build
#   --remote       no native route: push HEAD to fork branch
#                  leapgate/<base>-<sha12> and build it in home:<you>:leapgate;
#                  re-run to poll (pending until every PR arch built the
#                  source revision whose obsinfo names HEAD); the fork branch
#                  is deleted once the build is GREEN
#   --review FILE  record the change review: FILE's first non-empty line
#                  starts with PASS and names "tree <sha12>" of HEAD (trees
#                  quoted further down are ignored); needs a GREEN build first
#   (no mode)      check: GREEN build and PASS review for HEAD's tree and base
# PR arches: the standard repository of openSUSE:Backports:SLE-16.x:PullRequest,
# where the PR bot builds. Your PRs: those whose head repo belongs to the user
# of the src.opensuse.org tea login, the same identity pool-pr.sh updates by.
# Refused before anything is built: a dirty worktree (ignored and untracked
# files count), a detached HEAD, unsmudged LFS files, a clone under /tmp or a
# scratchpad, HEAD not on top of origin/<base>, HEAD stacked on more than one
# of your open PRs to the base, a failed PR lookup, a host arch the PR project
# does not build (never emulated), a flavor with no native route, a mounted
# root. Every failed lookup is a refusal or a red, never a green.
# Stamp: <git-common-dir>/target-gate/<tree>-<base>.json
# Needs: osc, git-lfs, obs-build (queryrecipe) and a src.opensuse.org tea login.
#
# Exit: 0 = green (check: build GREEN and review PASS), 1 = red (the check is
# named), 2 = refused or usage, 3 = no stamp, stale stamp or remote build pending.
set -uo pipefail
HERE=$(dirname "$(readlink -f -- "$0")")
G=https://src.opensuse.org

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
    -*) refuse "unknown option $1 — nothing but --jobs N reaches osc build: the project, repo, root and spec are fixed by the base" ;;
    *) [ -z "$dir" ] || refuse "one DIR only (got '$dir' and '$1')"; dir=$1; shift ;;
  esac
done
if [ -n "$jobs" ]; then
  [ "$mode" = build ] || refuse "--jobs goes with --build only"
  [[ $jobs =~ ^[1-9][0-9]*$ ]] || refuse "--jobs takes a positive integer, not '$jobs'"
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


def tea():
    try:
        with open(
            os.path.expanduser("~/.config/tea/config.yml"), encoding="utf-8"
        ) as fh:
            text = fh.read()
    except OSError:
        return 1
    try:
        import yaml

        logins = (yaml.safe_load(text) or {}).get("logins") or []
    except ImportError:
        # The one shape tea writes: a "logins:" list of flat mappings.
        logins, cur = [], None
        for line in text.splitlines():
            m = re.match(r"^(\s*)(-\s+)?([\w-]+):\s*(.*?)\s*$", line)
            if not m:
                continue
            if m.group(2):
                cur = {}
                logins.append(cur)
            elif not m.group(1):
                cur = None
            if cur is not None:
                cur[m.group(3)] = m.group(4).strip("'\"")
    except Exception:
        return 1
    for lg in logins:
        if isinstance(lg, dict) and lg.get("name") == "src.opensuse.org":
            print("%s\t%s" % (lg.get("user") or "", lg.get("token") or ""))
            return 0
    return 1


def oscuser():
    import configparser

    for p in ("~/.config/osc/oscrc", "~/.oscrc"):
        cp = configparser.RawConfigParser()
        try:
            cp.read(os.path.expanduser(p))
        except configparser.Error:
            continue
        for sec in cp.sections():
            if "api.opensuse.org" in sec and cp.get(sec, "user", fallback=""):
                print(cp.get(sec, "user"))
                return 0
    return 1


def pulls(base, user):
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return 1
    if not isinstance(d, list):
        return 1
    print(len(d))
    for p in d:
        if (p.get("base") or {}).get("ref") != base:
            continue
        h = p.get("head") or {}
        owner = ((h.get("repo") or {}).get("owner") or {}).get("login") or ""
        if owner.lower() != user.lower():
            continue
        print("%s\t%s\t%s" % (p.get("number"), h.get("sha") or "", h.get("ref") or ""))
    return 0


def arches():
    try:
        root = ET.fromstring(sys.stdin.read())
    except ET.ParseError:
        return 1
    for r in root.findall("repository"):
        if r.get("name") == "standard":
            a = [x.text for x in r.findall("arch") if x.text and x.text != "local"]
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
                "VERDICT: NO REVIEW — tree %s on %s built GREEN (%s, %s); "
                "run the change review, then --review FILE"
                % (t12, base, d.get("mode"), d.get("time"))
            )
            return 3
        print(
            "VERDICT: GREEN — tree %s on %s: build GREEN (%s, %s), review PASS (%s)"
            % (t12, base, d.get("mode"), d.get("time"), rv.get("time"))
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
    text = sys.stdin.read().strip()
    want = [
        (triples[i], triples[i + 1], triples[i + 2].split(","))
        for i in range(0, len(triples), 3)
    ]
    if text:
        try:
            root = ET.fromstring(text)
        except ET.ParseError:
            return 1
    else:
        root = ET.Element("project", name=prj)
        ET.SubElement(root, "title").text = "target-gate remote builds"
        ET.SubElement(
            root, "description"
        ).text = "Exact trees built before a Leap pool PR is opened; transient."
        ET.SubElement(root, "person", userid=user, role="maintainer")
        ET.SubElement(ET.SubElement(root, "publish"), "disable")
    changed = not text
    for name, pprj, arch in want:
        cur = [r for r in root.findall("repository") if r.get("name") == name]
        if (
            len(cur) == 1
            and [
                (p.get("project"), p.get("repository")) for p in cur[0].findall("path")
            ]
            == [(pprj, "standard")]
            and sorted(a.text for a in cur[0].findall("arch")) == sorted(arch)
        ):
            continue
        changed = True
        for r in cur:
            root.remove(r)
        r = ET.SubElement(root, "repository", name=name)
        ET.SubElement(r, "path", project=pprj, repository="standard")
        for a in arch:
            ET.SubElement(r, "arch").text = a
    if not changed:
        return 4
    print(ET.tostring(root, encoding="unicode"))
    return 0


def pkgmeta(prj, pkg, url, other):
    text = sys.stdin.read().strip()
    if text:
        try:
            cur = ET.fromstring(text)
        except ET.ParseError:
            return 1
        flags = {
            (e.tag, e.get("repository"), e.get("arch")) for e in cur.findall("build/*")
        }
        if (cur.findtext("scmsync") or "").strip() == url and flags == {
            ("disable", other, None)
        }:
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
    try:
        root = ET.fromstring(sys.stdin.read())
    except ET.ParseError:
        return 2
    ok, bad = (
        {"succeeded", "excluded", "disabled"},
        {"failed", "unresolvable", "broken"},
    )
    req = set(required.split())
    codes, dirty, built, seen = [], [], set(), set()
    for r in root.findall("result"):
        if r.get("repository") != repo:
            continue
        arch = r.get("arch")
        # An arch the PR bot never builds is not this base's verdict.
        if arch not in req:
            continue
        if r.get("dirty") == "true" or r.get("state") in ("scheduling", "outdated"):
            dirty.append(arch)
        row = []
        for s in r.findall("status"):
            code = s.get("code") or "unknown"
            codes.append(code)
            seen.add(arch)
            if code == "succeeded":
                built.add(arch)
                print("#built %s %s" % (arch, s.get("package")))
            det = (s.findtext("details") or "").strip()
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
    # A source listing's directory srcmd5; a build _history's last entry's.
    try:
        root = ET.fromstring(sys.stdin.read())
    except ET.ParseError:
        return 2
    e = root if root.tag == "directory" else (root.findall("entry") or [None])[-1]
    m = e.get("srcmd5") if e is not None else None
    if not m:
        return 1
    print(m)
    return 0


cmd, args = sys.argv[1], sys.argv[2:]
fn = {
    "tea": tea,
    "oscuser": oscuser,
    "pulls": pulls,
    "arches": arches,
    "flavors": flavors,
    "qr": qr,
    "stamp-write": stamp_write,
    "stamp-check": stamp_check,
    "review": review,
    "prjmeta": prjmeta,
    "pkgmeta": pkgmeta,
    "results": results,
    "srcmd5": srcmd5,
}[cmd]
sys.exit(fn(*args))
PYEOF
py() { python3 -c "$PY" "$@"; }

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
  # osc's git store has no working copy on a detached HEAD.
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
# osc copies ignored and untracked files into the build too.
st=$(git status --porcelain --ignored --untracked-files=all) || refuse "git status failed"
[ -z "$st" ] || refuse "worktree not clean: $(printf '%s\n' "$st" | head -5 | paste -sd';')"
lfs=$(git lfs ls-files 2>&1) || refuse "cannot list LFS files (is git-lfs installed?): $lfs"
bad=$(printf '%s\n' "$lfs" | awk '$2 == "-" {print $3}' | paste -sd' ')
[ -z "$bad" ] || refuse "LFS files not smudged (pointers only — run git lfs pull): $bad"

git rev-parse -q --verify "refs/remotes/origin/$base" >/dev/null || refuse "no origin/$base — git fetch origin $base"
git merge-base --is-ancestor "origin/$base" HEAD || refuse "HEAD does not contain origin/$base — rebase onto it"
tl=$(py tea) || refuse "no src.opensuse.org login in ~/.config/tea/config.yml"
guser=${tl%%$'\t'*}; gtok=${tl#*$'\t'}
[ -n "$guser" ] || refuse "the tea login for src.opensuse.org names no user"
: > "$tmpd/auth"; chmod 600 "$tmpd/auth"
[ -z "$gtok" ] || printf 'Authorization: token %s\n' "$gtok" > "$tmpd/auth"
mine=""; page=1
while :; do
  js=$(curl -fsS --max-time 20 -H "@$tmpd/auth" "$G/api/v1/repos/pool/$pkg/pulls?state=open&limit=50&page=$page" 2>&1) \
    || refuse "cannot read the open PRs of pool/$pkg (lookup failed, not 'none'): $js"
  rows=$(printf '%s' "$js" | py pulls "$base" "$guser") || refuse "unparseable open-PR list for pool/$pkg"
  mine+=$(tail -n +2 <<<"$rows")$'\n'
  [ "$(head -1 <<<"$rows")" -ge 50 ] || break
  page=$((page + 1))
done
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

pr_arches() {   # arches the PR bot builds for base $1; Backports itself has more
  local p m a
  p="$(bprj "$1"):PullRequest"
  m=$(osc meta prj "$p" 2>&1) || refuse "cannot read the $p meta: $(tail -1 <<<"$m")"
  a=$(py arches <<<"$m") || refuse "no standard repository arches in the $p meta"
  echo "$a"
}

# ============================== --remote =======================================
if [ "$mode" = remote ]; then
  obsuser=$(osc whois 2>/dev/null | sed -n '1s/:.*//p' | tr -d '[:space:]')
  [ -n "$obsuser" ] || obsuser=$(py oscuser) || obsuser=""
  [ -n "$obsuser" ] || refuse "cannot determine your OBS account (osc whois failed, no user in oscrc)"
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

  forkerr=$(tea repo fork --repo "pool/$pkg" --login src.opensuse.org 2>&1 >/dev/null) \
    || case "$forkerr" in
         *"already exists"*|*"already forked"*) : ;;
         *) say "tea repo fork: $forkerr" ;;
       esac
  git remote add leapgate "$G/$guser/$pkg.git" 2>/dev/null || git remote set-url leapgate "$G/$guser/$pkg.git"
  # The token reaches git and git-lfs through a 0600 file, never argv.
  printf '%s' "$gtok" > "$tmpd/tok"; chmod 600 "$tmpd/tok"
  # shellcheck disable=SC2016  # $1 belongs to the helper, not to this shell
  printf '#!/bin/sh\ncase "$1" in\n  Username*) echo "%s" ;;\n  Password*) cat "%s" ;;\nesac\n' \
    "$guser" "$tmpd/tok" > "$tmpd/askpass"
  chmod 700 "$tmpd/askpass"
  # A fork does not share the parent's LFS store, and the pre-push hook would
  # upload every object in the history: push refs without it, then exactly
  # this tree's objects.
  GIT_ASKPASS="$tmpd/askpass" git push -q --no-verify leapgate "HEAD:refs/heads/$br" \
    || refuse "push to $guser/$pkg:$br failed"
  oids=$(git lfs ls-files -l | awk '{print $1}')
  if [ -n "$oids" ]; then
    # shellcheck disable=SC2086  # one argument per object id
    GIT_ASKPASS="$tmpd/askpass" git lfs push --object-id leapgate $oids \
      || refuse "LFS object push to $guser/$pkg failed — OBS would fetch dangling pointers"
  fi

  metaget() {   # metaget prj|pkg ARGS... — current meta, empty when it does not exist
    local out
    out=$(osc meta "$@" 2>&1) && { printf '%s' "$out"; return 0; }
    case "$out" in *404*|*"Not Found"*) return 0 ;; esac
    refuse "cannot read the meta of $*: $(tail -1 <<<"$out")"
  }
  changed=0
  cur=$(metaget prj "$gprj") || exit 2
  new=$(py prjmeta "$gprj" "$obsuser" "${triples[@]}" <<<"$cur"); rc=$?
  case $rc in
    0) printf '%s\n' "$new" > "$tmpd/prj.xml"
       osc meta prj -F "$tmpd/prj.xml" "$gprj" >/dev/null 2>"$tmpd/err" || refuse "writing the $gprj meta failed: $(tail -1 "$tmpd/err")"
       say "set up $gprj (leap-16.0, leap-16.1)" ;;
    4) ;;
    *) refuse "unparseable $gprj meta" ;;
  esac
  cur=$(metaget pkg "$gprj" "$pkg") || exit 2
  new=$(py pkgmeta "$gprj" "$pkg" "$url" "$other" <<<"$cur"); rc=$?
  case $rc in
    0) printf '%s\n' "$new" > "$tmpd/pkg.xml"
       osc meta pkg -F "$tmpd/pkg.xml" "$gprj" "$pkg" >/dev/null 2>"$tmpd/err" || refuse "writing the $gprj/$pkg meta failed: $(tail -1 "$tmpd/err")"
       changed=1 ;;
    4) ;;
    *) refuse "unparseable $gprj/$pkg meta" ;;
  esac
  [ $changed = 0 ] || pending "pointed $gprj/$pkg at $br#${head:0:12} — re-run to poll"

  # obsinfo and every build are held to one source revision: until the
  # scheduler catches up, a build of the previous one still reads "succeeded".
  src=$(osc api "/source/$gprj/$pkg?expand=1" 2>&1) || refuse "cannot read the $gprj/$pkg sources: $(tail -1 <<<"$src")"
  smd5=$(py srcmd5 <<<"$src") || refuse "no srcmd5 in the $gprj/$pkg source listing"
  info=$(osc cat -r "$smd5" "$gprj" "$pkg" _scmsync.obsinfo 2>&1) || pending "$gprj/$pkg has no _scmsync.obsinfo yet — re-run to poll"
  got=$(sed -n 's/^commit: *//p' <<<"$info" | head -1)
  [ "$got" = "$head" ] || pending "OBS synced ${got:-nothing}, HEAD is $head — re-run to poll"
  res=$(osc results --xml -r "$base" "$gprj" "$pkg" 2>&1) || refuse "cannot read the $gprj/$pkg results: $(tail -1 <<<"$res")"
  sum=$(py results "$base" "$req" <<<"$res"); rc=$?
  grep -v '^#' <<<"$sum"
  why=$(sed -n 's/^#why //p' <<<"$sum")
  if [ $rc = 0 ]; then
    stale=()
    while read -r a p; do
      h=$(osc api "/build/$gprj/$base/$a/$p/_history" 2>&1) \
        || refuse "cannot read the $gprj/$base/$a/$p build history: $(tail -1 <<<"$h")"
      m=$(py srcmd5 <<<"$h"); [ $? != 2 ] || refuse "unparseable $gprj/$base/$a/$p build history"
      [ "$m" = "$smd5" ] || { m=${m:0:12}; stale+=("$a/$p (built ${m:-nothing})"); }
    done < <(sed -n 's/^#built //p' <<<"$sum")
    [ ${#stale[@]} -eq 0 ] || pending "source ${smd5:0:12} not built yet on ${stale[*]} — re-run to poll"
  fi
  case $rc in
    0) py stamp-write "$stamp" tree="$tree" commit="$head" base="$base" project="$prj" mode=remote \
         arches="$(sed -n 's/^#arches //p' <<<"$sum" | tr ' ' ',')" \
         obs_project="$gprj" verdict=GREEN || refuse "cannot write $stamp"
       # The branch served its purpose: the stamp is the evidence. Delete
       # this run's fork branch so stale leapgate/* branches don't pile up.
       # Only on green -- a red build keeps its branch for debugging.
       GIT_ASKPASS="$tmpd/askpass" git push -q leapgate --delete "$br" 2>/dev/null \
         || say "note: could not delete the fork branch $br"
       say "VERDICT: GREEN — tree ${tree:0:12} built on $gprj/$base at commit ${head:0:12}; stamped $stamp"
       exit 0 ;;
    1) rm -f "$stamp"
       say "VERDICT: RED — $gprj/$pkg on $base ${why:-failed} (osc rbl $gprj $pkg $base <arch>)"
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

# The build-root base from oscrc, as build-summary.sh reads it.
TMPL=$(grep -hE '^\s*build-root\s*=' ~/.config/osc/oscrc ~/.oscrc 2>/dev/null \
       | tail -1 | sed -E 's/^[^=]*=\s*//; s/\s+$//')
: "${TMPL:=/var/tmp/build-root/%(repo)s-%(arch)s}"
root_base() {
  local tmpl="$TMPL"
  while [ -n "$tmpl" ] && case "$tmpl" in */*) [[ "${tmpl##*/}" == *'%('* ]];; *) false;; esac; do
    tmpl="${tmpl%/*}"
  done
  echo "${tmpl:-/var/tmp/build-root}"
}
# Per base: 16.0 and 16.1 are different roots, and neither may reuse the
# <pkg>-standard-<arch> root of some other build.
root="$(root_base)/$pkg-$base-$native"

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
{ [ -x "$qrbin" ] && [ -x "$qcbin" ]; } || refuse "$qrbin or $qcbin not found (obs-build, which osc build needs)"
osc buildconfig "$prj" standard > "$tmpd/buildconfig" 2>"$tmpd/err" \
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
for k in "${!todo[@]}"; do
  f=${flavors[${todo[$k]}]}; fs=${f:+ -M $f}
  say "flavor ${f:-(none)}: build $native, resolve ${others[$k]:-nothing else}"
  # A cheap resolution failure elsewhere spares the long native build.
  for a in ${others[$k]}; do
    mflag=(); [ -z "$f" ] || mflag=(-M "$f")
    out=$(osc buildinfo --alternative-project "$prj" "${mflag[@]}" standard "$a" "$pkg.spec" 2>&1 </dev/null)
    if ! grep -q '<buildinfo' <<<"$out"; then
      red "buildinfo $a$fs: lookup failed: $(tail -1 <<<"$out")"
    elif err=$(grep -m1 -o '<error>[^<]*</error>' <<<"$out"); then
      err=${err#<error>}; red "buildinfo $a$fs: ${err%</error>}"
    else
      resolved+="$a "
    fi
  done
  [ ${#reds[@]} -eq 0 ] || break

  # osc build --clean on a root with a bind-mounted /dev wipes the host's /dev.
  m=$(mounted "$root"); [ $? -ne 2 ] || refuse "findmnt failed — cannot rule out mounts under $root"
  [ -z "$m" ] || refuse "mounted under $root: $(paste -sd' ' <<<"$m") — unmount before building there"
  cmd=(osc build --clean --trust-all-projects --root "$root" --alternative-project="$prj")
  [ -z "$jobs" ] || cmd+=(--jobs "$jobs")
  [ -z "$f" ] || cmd+=(-M "$f")
  cmd+=(standard "$native" "$pkg.spec")
  "${cmd[@]}" </dev/null 2>&1 | tail -n 30 > "$tmpd/osc.tail"; orc=${PIPESTATUS[0]}

  bs=$("$HERE/build-summary.sh" "$root" 2>&1); brc=$?
  if [ $brc -ne 0 ] || [ "$orc" -ne 0 ]; then
    red "build$fs: build-summary rc=$brc ($(grep -m1 -o 'VERDICT: .*\|no readable build log' <<<"$bs")), osc build rc=$orc"
    [ $brc -ne 2 ] || tail -n 5 "$tmpd/osc.tail"
  fi
  # The tesseract discriminator: the log names the recipe it built.
  recipes=$(grep -ho 'processing recipe [^ ]*' "$root/.build.log" 2>/dev/null | sed 's/^processing recipe //' | sort -u | paste -sd' ')
  [ "$recipes" = "$rdir/$pkg.spec" ] \
    || red "recipe$fs: the log built ${recipes:-no recipe}, not $rdir/$pkg.spec${recipes:+ — a build of another checkout is no evidence}"
  st=$(git status --porcelain --ignored --untracked-files=all)
  if [ "$(git rev-parse 'HEAD^{tree}')" != "$tree" ]; then
    red "worktree$fs: HEAD's tree changed during the build — the built tree is not the one stamped"
  elif [ -n "$st" ]; then
    red "worktree$fs: the build left it dirty ($(printf '%s\n' "$st" | head -3 | paste -sd';')) — the built tree is not HEAD's"
  fi
  # Tripwire: the root really is the base's product (release 16.0.x/16.1.x).
  rcs=$(cat "$root/installed-pkg/rpm-config-SUSE" 2>/dev/null)
  case "$rcs" in
    *"-$marker."*) ;;
    *) red "base$fs: root has ${rcs:-no rpm-config-SUSE}, want release -$marker.* for $base" ;;
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
