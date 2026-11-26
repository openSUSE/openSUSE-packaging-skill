#!/bin/bash
# Open or update the pool/<pkg> PR for a Leap product branch: the one route by
# which a pool PR is created or its head moved. It never merges.
#
# DIR is a pool/<pkg> clone or worktree (leap-sync.sh leaves one) on a branch
# tracking origin/leap-16.x: the package comes from origin, the base from
# @{upstream}. target-gate.sh runs FIRST, in check mode: unless HEAD's exact
# tree has a green target build AND a PASS review on that base, this stops
# with nothing pushed. A green build of any other checkout is not evidence.
#
# An open PR of yours on the base is updated in place: HEAD is force-pushed
# onto its head branch and its title reset. HEAD must contain that PR's head (a
# fix on top): one that would drop the PR's commits is refused unless
# --replace, which resets the body too. Otherwise HEAD goes to a new head
# branch <base>-<sha12> on your fork and the PR is opened. Refused: someone
# else's open PR on the base (no double-filing), two of yours, and a head
# branch that already heads a PR to another base (one head branch, one base).
#
# Requires: geectl for the open-PR listing and the fork, a git-obs login
# for src.opensuse.org (the user lookup and the PR create/update: the
# pull-request surface has no create leaf) and an SSH key there (geectl,
# git-obs and ssh read their own credentials: this script reads none), git-lfs.
#
# Usage: pool-pr.sh DIR [--title T] [--body-file F] [--replace]
#   --title      PR title (default: HEAD's commit subject)
#   --body-file  PR body (default: HEAD's commit body; an open PR keeps its own)
#   --replace    HEAD does not contain your open PR's head: replace the PR's
#                tree and body (--body-file, else HEAD's body naming the new head)
# Exit: 0 opened/updated · 2 refused or usage · 6 network/API failure (retry)
#       · 7 gate not green, nothing pushed
set -uo pipefail
# Resolved, so a symlinked copy never runs a target-gate.sh placed beside the link.
HERE="$(dirname "$(readlink -f "$0")")"
GS=gitea@src.opensuse.org
usage() { awk 'NR>1 { if (!/^#/) exit; print }' "$0"; }

dir=""; title=""; bodyfile=""; replace=0
while [ $# -gt 0 ]; do
  case "$1" in --title|--body-file) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; };; esac
  case "$1" in
    -h|--help) usage; exit 0;;
    --title) title=$2; shift 2;;
    --body-file) bodyfile=$2; shift 2;;
    --replace) replace=1; shift;;
    -*) echo "pool-pr.sh: unknown option $1" >&2; exit 2;;
    *) [ -z "$dir" ] || { echo "pool-pr.sh: one DIR only" >&2; exit 2; }; dir=$1; shift;;
  esac
done
[ -n "$dir" ] || { usage >&2; exit 2; }
[ -z "$bodyfile" ] || [ -r "$bodyfile" ] || { echo "cannot read --body-file $bodyfile" >&2; exit 2; }

# The configured URL, not `remote get-url`: that one applies insteadOf rewrites.
origin=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) \
  || { echo "$dir: not a git checkout with an origin remote" >&2; exit 2; }
u=${origin%/}; u=${u%.git}
[[ $u =~ ^(https://|ssh://)?([^@/]+@)?src\.opensuse\.org(:[0-9]+)?[:/]pool/([^/]+)$ ]] \
  || { echo "REFUSING: origin is $origin, not src.opensuse.org/pool/<pkg>" >&2; exit 2; }
pkg=${BASH_REMATCH[4]}
up=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || up=""
[[ $up =~ ^origin/(leap-16\.[0-9]+)$ ]] \
  || { echo "REFUSING: $dir tracks '${up:-nothing}', not origin/leap-16.x — pool PRs from here go to Leap branches only" >&2; exit 2; }
base=${BASH_REMATCH[1]}
sha=$(git -C "$dir" rev-parse -q --verify 'HEAD^{commit}') || { echo "$dir: no HEAD commit" >&2; exit 2; }
tree=$(git -C "$dir" rev-parse "$sha^{tree}")

# Before anything reaches the network: nothing below runs unless this exact
# tree built green on $base and passed review.
"$HERE/target-gate.sh" "$dir"; rc=$?
if [ "$rc" != 0 ]; then
  echo "no green target build + PASS review for tree ${tree:0:12} on base $base (target-gate.sh exit $rc) — nothing pushed" >&2
  exit 7
fi
# The gate read HEAD itself; push only the commit it saw.
[ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] \
  || { echo "HEAD moved while target-gate.sh ran — nothing pushed; re-run" >&2; exit 7; }

# Objects AND pointers of the commit being pushed; --pointers alone passes a
# tree whose objects were never fetched.
if ! lfsck=$(git -C "$dir" lfs fsck --dry-run "$sha" 2>&1); then
  echo "LFS objects of ${sha:0:12} missing or corrupt here — nothing pushed (git lfs fetch, then re-run):" >&2
  printf '%s\n' "$lfsck" >&2
  exit 2
fi
lfs=$(git -C "$dir" lfs ls-files -l "$sha") || { echo "git lfs ls-files failed — nothing pushed" >&2; exit 2; }
oids=$(printf '%s\n' "$lfs" | awk 'NF {print $1}')

tmpd=$(mktemp -d -p "${TMPDIR:-/var/tmp}" pool-pr.XXXXXX) || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$tmpd"' EXIT
# The forge user and the PR filing, still through git-obs: geectl has no
# whoami leaf, and pull-request submit needs a fork checkout, not a pool
# clone. gapi reads its own login (-G: the default one may be another
# forge's) and exits non-zero on an HTTP error.
gapi() { timeout 60 git-obs -G src.opensuse.org -q api "$@" 2>"$tmpd/gerr" | sed -e '1{' -e '/^Response:$/d' -e '}'; }
gerr() { local e; e=$(grep -v '^Response:$' "$tmpd/gerr" | tail -1); echo "${e:-no usable answer}"; }
user=$(gapi /user | python3 -I -c 'import json,sys; u=json.load(sys.stdin).get("login"); assert isinstance(u, str) and u; print(u)' 2>/dev/null) \
  || { echo "could not read your src.opensuse.org user through git-obs: $(gerr) — nothing pushed" >&2; exit 6; }

# The open PRs, as one list from the unified pull-request surface: geectl
# pages the forge's list itself (bounded at 500), so one call reads them all.
# A head-branch clash or a PR late in the list must not read as "none".
api="/repos/pool/$pkg"
prs=$(geectl --format json pull-request search --backend gitea --repo "pool/$pkg" --state open 2>"$tmpd/perr") \
  || { err=$(tail -1 "$tmpd/perr" 2>/dev/null); echo "could not list open PRs on pool/$pkg: ${err:-no usable answer} — nothing pushed" >&2; exit 6; }
# The list lives in a file: a heredoc script cannot also read piped stdin.
printf '%s' "$prs" > "$tmpd/prs.json"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d, dict) and isinstance(d.get("pull_requests"), list)' "$tmpd/prs.json" 2>/dev/null \
  || { echo "unparseable open-PR list for pool/$pkg — cannot rule out a duplicate; nothing pushed" >&2; exit 6; }

# Prints mode, PR number, head branch, head repo, PR url, head commit, one per
# line; exit 3 = refused.
plan=$(python3 -I - "$tmpd/prs.json" "$user" "$base" "$base-${sha:0:12}" <<'EOF'
import json
import re
import sys

prs = json.load(open(sys.argv[1]))["pull_requests"]
user, base, fresh = sys.argv[2].lower(), sys.argv[3], sys.argv[4]


def g(p, *keys):
    for k in keys:
        p = (p or {}).get(k)
    return p or ""


def num(p):
    # The handle: gitea:pool/<pkg>#<n>; anything else is not a list entry.
    ref = p.get("reference") if isinstance(p, dict) else None
    m = re.fullmatch(r"gitea:[^/]+/[^#]+#(\d+)", ref or "")
    if not m:
        raise ValueError("bad reference %r" % (ref,))
    return int(m.group(1))


def refuse(msg):
    print("REFUSING: " + msg, file=sys.stderr)
    sys.exit(3)


def owner(p):
    return (g(p, "source", "repository") or "/").split("/")[0]


def mine(p):
    return owner(p).lower() == user


def url(p):
    ref = p.get("reference") if isinstance(p, dict) else ""
    repo = (ref.split(":", 1)[1].rsplit("#", 1)[0] if ":" in ref else "")
    return "https://src.opensuse.org/%s/pulls/%s" % (repo, num(p))


for p in prs:
    # Every entry must carry the fields the plan reads, or the list is not
    # one this script can rule a duplicate out from.
    if (
        not isinstance(p, dict)
        or not isinstance(p.get("source"), dict)
        or not isinstance(p.get("target"), dict)
        or not isinstance(g(p, "source", "repository"), str)
        or not isinstance(g(p, "source", "branch"), str)
        or not isinstance(g(p, "target", "branch"), str)
    ):
        raise ValueError("bad entry %r" % (p,))
    num(p)
on_base = [p for p in prs if g(p, "target", "branch") == base]
own = [p for p in on_base if mine(p)]
if len(own) > 1:
    nums = ", ".join("#%s" % num(p) for p in own)
    refuse("open PRs of yours on %s: %s — close the extras by hand" % (base, nums))
if own:
    pr, mode = own[0], "update"
    head = g(pr, "source", "branch")
elif on_base:
    pr = on_base[0]
    who = owner(pr) or g(pr, "author") or "?"
    refuse(
        "an open PR by %s already targets %s: %s — not double-filing"
        % (who, base, url(pr))
    )
else:
    pr, mode, head = {}, "new", fresh
for q in prs:
    if mine(q) and g(q, "source", "branch") == head and g(q, "target", "branch") != base:
        refuse(
            "head branch %s already heads PR #%s to %s — one head branch per base"
            % (head, num(q), g(q, "target", "branch"))
        )
for field in (mode, num(pr) if pr else "", head):
    print(field)
print(g(pr, "source", "repository"))
print(url(pr) if pr else "")
print(g(pr, "source", "commit"))
EOF
); rc=$?
[ "$rc" = 3 ] && exit 2
[ "$rc" = 0 ] || { echo "could not read the open-PR list for pool/$pkg — nothing pushed" >&2; exit 6; }
{ read -r mode; read -r num; read -r head; read -r hrepo; read -r purl; read -r oldsha; } <<<"$plan"
old12=${oldsha:0:12}; old12=${old12:-(not listed)}
# Dropping the PR's own commits is a replacement, never implied. A head the
# listing omits, or that this clone lacks, counts as not contained.
if [ "$mode" = update ] && ! git -C "$dir" merge-base --is-ancestor "$oldsha" "$sha" 2>/dev/null; then
  [ "$replace" = 1 ] || {
    echo "REFUSING: HEAD ${sha:0:12} does not contain $old12, the head of your open PR #$num ($purl) — pushing would drop its commits. Check what #$num carries; --replace replaces its tree and body with this one" >&2
    exit 2; }
else
  replace=0
fi

if [ "$mode" = new ]; then
  # An existing fork is no error: repo-fork returns the existing fork
  # instead of failing. A failure shows, the push decides.
  forkerr=$(timeout 60 geectl gitea repo-fork pool "$pkg" --live 2>&1 >/dev/null) \
    || echo "geectl gitea repo-fork failed: $(tail -1 <<<"$forkerr")" >&2
  hrepo="$user/$pkg"
else
  # The PR's own head repo: pushing anywhere else leaves the PR on its old tree.
  [ -n "$hrepo" ] || hrepo="$user/$pkg"
  echo "updating PR #$num ($purl), head $hrepo:$head"
fi
furl="$GS:$hrepo.git"
git -C "$dir" remote add fork "$furl" 2>/dev/null || git -C "$dir" remote set-url fork "$furl"

# LFS objects first, then the ref, so the head never points at a tree whose
# objects the fork lacks. Gitea forks do not share the parent's LFS storage,
# and the pre-push hook would upload every object reachable from the branch
# history — including ones pruned on old product branches ("Unable to find
# source for object ..."). So --no-verify on the ref push, and --object-id for
# exactly the objects of this tree. (Real case: pool/ollama.) Both over SSH:
# git-lfs asks the forge for its credentials there.
if [ -n "$oids" ]; then
  # shellcheck disable=SC2086  # one argument per oid
  git -C "$dir" lfs push --object-id fork $oids \
    || { echo "LFS object push to $hrepo failed — ref not pushed" >&2; exit 6; }
fi
# A --replace shares no history with the old head; a bare --force-with-lease
# would need a fork tracking ref never fetched.
pushopt=""; [ "$mode" = update ] && pushopt="--force"
# shellcheck disable=SC2086  # empty $pushopt must expand to no argument
git -C "$dir" push -q --no-verify $pushopt fork "$sha:refs/heads/$head" \
  || { echo "push to $hrepo:$head failed (does the fork exist? see the repo-fork output above)" >&2; exit 6; }

[ -n "$title" ] || title=$(git -C "$dir" log -1 --format=%s "$sha")
if [ -n "$bodyfile" ]; then body=$(cat "$bodyfile"); else body=$(git -C "$dir" log -1 --format=%b "$sha"); fi
setbody=$bodyfile
if [ "$replace" = 1 ]; then
  # The old body describes commits that are gone.
  setbody=1
  [ -n "$bodyfile" ] || body="${body:+$body$'\n\n'}Head replaced by ${sha:0:12} (tree ${tree:0:12}); the commits of the previous head $old12 are no longer in this PR."
fi
if [ "$mode" = update ]; then
  # EditPullRequestOption has no head field; the push above already moved it.
  payload=$(python3 -I -c 'import json,sys; d={"title": sys.argv[1]}; sys.argv[2] and d.update(body=sys.argv[3]); print(json.dumps(d))' \
    "$title" "$setbody" "$body")
  method=PATCH; url="$api/pulls/$num"
else
  payload=$(python3 -I -c 'import json,sys; print(json.dumps(dict(zip(("head", "base", "title", "body"), sys.argv[1:]))))' \
    "$user:$head" "$base" "$title" "$body")
  method=POST; url="$api/pulls"
fi
resp=$(gapi -X "$method" --data "$payload" "$url") \
  || { echo "PR $method failed: $(gerr) — $hrepo:$head is pushed; re-run to finish" >&2; exit 6; }
pr=$(printf '%s' "$resp" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(int(d["number"])); print(d["html_url"])' 2>/dev/null) \
  || { echo "PR $method rejected: $(printf '%s' "$resp" | head -c 300)" >&2; exit 6; }
{ read -r num; read -r purl; } <<<"$pr"
verb=opened; [ "$mode" = update ] && verb=updated; [ "$replace" = 1 ] && verb="updated (head replaced)"
echo "PR $verb: $purl (head $hrepo:$head at ${sha:0:12}, tree ${tree:0:12}, base $base)"
echo "next: $HERE/sr-status.py --pr pool/$pkg#$num — done only when that exits 0; never merge a pool PR"
