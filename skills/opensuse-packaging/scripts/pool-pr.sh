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
# Requires: a src.opensuse.org login in ~/.config/tea/config.yml, git-lfs, tea.
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
G=https://src.opensuse.org
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

tealogin() {   # "user<TAB>token" of the src.opensuse.org tea login; PyYAML optional
  python3 - 2>/dev/null <<'PYEOF'
import os
import re

with open(os.path.expanduser("~/.config/tea/config.yml"), encoding="utf-8") as fh:
    text = fh.read()
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
for lg in logins:
    if isinstance(lg, dict) and lg.get("name") == "src.opensuse.org":
        print("%s\t%s" % (lg.get("user") or "", lg.get("token") or ""))
        break
PYEOF
}
tl=$(tealogin) || tl=""
user=${tl%%$'\t'*}; tok=${tl#*$'\t'}
[ -n "$tok" ] || { echo "no src.opensuse.org token in ~/.config/tea/config.yml" >&2; exit 2; }
[ -n "$user" ] || { echo "could not determine your src.opensuse.org username from the tea login" >&2; exit 2; }

# Token off argv: curl reads the header from a file, git/git-lfs get it through
# GIT_ASKPASS (git-lfs ignores http.extraHeader, so a header-only push 401s on
# any repo with LFS objects). 0600 files in a 0700 directory.
sec=$(mktemp -d -p "${TMPDIR:-/var/tmp}" pool-pr.XXXXXX) || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$sec"' EXIT
(umask 077
 printf 'Authorization: token %s\n' "$tok" > "$sec/auth"
 printf '%s' "$tok" > "$sec/tok"
 # shellcheck disable=SC2016  # $1 belongs to the helper, not to this script
 printf '#!/bin/sh\ncase "$1" in\n  Username*) echo "%s" ;;\n  Password*) cat "%s" ;;\nesac\n' \
   "$user" "$sec/tok" > "$sec/askpass")
chmod 700 "$sec/askpass"

# Every page: a head-branch clash or a PR on page 2 must not read as "none".
api="$G/api/v1/repos/pool/$pkg"
page=1
while :; do
  [ "$page" -le 20 ] || { echo "open-PR list for pool/$pkg does not end — nothing pushed" >&2; exit 6; }
  curl -fsS --max-time 20 -H "@$sec/auth" "$api/pulls?state=open&limit=50&page=$page" > "$sec/pulls.$page" \
    || { echo "could not list open PRs on pool/$pkg (network?) — nothing pushed" >&2; exit 6; }
  n=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d, list); print(len(d))' "$sec/pulls.$page" 2>/dev/null) \
    || { echo "unparseable open-PR list for pool/$pkg — cannot rule out a duplicate; nothing pushed" >&2; exit 6; }
  [ "$n" = 0 ] && break
  page=$((page + 1))
done

# Prints mode, PR number, head branch, head repo, PR url, head commit, one per
# line; exit 3 = refused.
plan=$(python3 - "$user" "$base" "$base-${sha:0:12}" "$sec"/pulls.* <<'EOF'
import json
import sys

user, base, fresh = sys.argv[1].lower(), sys.argv[2], sys.argv[3]
prs = [p for f in sys.argv[4:] for p in json.load(open(f))]


def g(p, *keys):
    for k in keys:
        p = (p or {}).get(k)
    return p or ""


def refuse(msg):
    print("REFUSING: " + msg, file=sys.stderr)
    sys.exit(3)


def mine(p):
    return g(p, "head", "repo", "owner", "login").lower() == user


on_base = [p for p in prs if g(p, "base", "ref") == base]
own = [p for p in on_base if mine(p)]
if len(own) > 1:
    nums = ", ".join("#%s" % p.get("number") for p in own)
    refuse("open PRs of yours on %s: %s — close the extras by hand" % (base, nums))
if own:
    pr, mode = own[0], "update"
    head = g(pr, "head", "ref")
elif on_base:
    pr = on_base[0]
    who = g(pr, "head", "repo", "owner", "login") or g(pr, "user", "login") or "?"
    refuse(
        "an open PR by %s already targets %s: %s — not double-filing"
        % (who, base, g(pr, "html_url"))
    )
else:
    pr, mode, head = {}, "new", fresh
for q in prs:
    if mine(q) and g(q, "head", "ref") == head and g(q, "base", "ref") != base:
        refuse(
            "head branch %s already heads PR #%s to %s — one head branch per base"
            % (head, q.get("number"), g(q, "base", "ref"))
        )
for field in (mode, pr.get("number") or "", head):
    print(field)
print(g(pr, "head", "repo", "full_name"))
print(g(pr, "html_url"))
print(g(pr, "head", "sha"))
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
  forkerr=$(tea repo fork --repo "pool/$pkg" --login src.opensuse.org 2>&1 >/dev/null) \
    || case "$forkerr" in
         *"already exists"*|*"repository is already forked"*) : ;;   # fine, reuse it
         *) echo "tea repo fork failed: $forkerr" >&2 ;;             # surface, but the fork may still exist — try the push
       esac
  hrepo="$user/$pkg"
else
  # The PR's own head repo: pushing anywhere else leaves the PR on its old tree.
  [ -n "$hrepo" ] || hrepo="$user/$pkg"
  echo "updating PR #$num ($purl), head $hrepo:$head"
fi
furl="$G/$hrepo.git"
git -C "$dir" remote add fork "$furl" 2>/dev/null || git -C "$dir" remote set-url fork "$furl"

# LFS objects first, then the ref, so the head never points at a tree whose
# objects the fork lacks. Gitea forks do not share the parent's LFS storage,
# and the pre-push hook would upload every object reachable from the branch
# history — including ones pruned on old product branches ("Unable to find
# source for object ..."). So --no-verify on the ref push, and --object-id for
# exactly the objects of this tree. (Real case: pool/ollama.)
if [ -n "$oids" ]; then
  # shellcheck disable=SC2086  # one argument per oid
  GIT_ASKPASS="$sec/askpass" git -C "$dir" lfs push --object-id fork $oids \
    || { echo "LFS object push to $hrepo failed — ref not pushed" >&2; exit 6; }
fi
# A --replace shares no history with the old head; a bare --force-with-lease
# would need a fork tracking ref never fetched.
pushopt=""; [ "$mode" = update ] && pushopt="--force"
# shellcheck disable=SC2086  # empty $pushopt must expand to no argument
GIT_ASKPASS="$sec/askpass" git -C "$dir" push -q --no-verify $pushopt fork "$sha:refs/heads/$head" \
  || { echo "push to $hrepo:$head failed (does the fork exist? see the tea output above)" >&2; exit 6; }

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
  payload=$(python3 -c 'import json,sys; d={"title": sys.argv[1]}; sys.argv[2] and d.update(body=sys.argv[3]); print(json.dumps(d))' \
    "$title" "$setbody" "$body")
  method=PATCH; url="$api/pulls/$num"
else
  payload=$(python3 -c 'import json,sys; print(json.dumps(dict(zip(("head", "base", "title", "body"), sys.argv[1:]))))' \
    "$user:$head" "$base" "$title" "$body")
  method=POST; url="$api/pulls"
fi
resp=$(curl -sS --max-time 20 -X "$method" -H "@$sec/auth" -H "Content-Type: application/json" -d "$payload" "$url") \
  || { echo "PR $method failed (network?) — $hrepo:$head is pushed; re-run to finish" >&2; exit 6; }
pr=$(printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d["number"])); print(d["html_url"])' 2>/dev/null) \
  || { echo "PR $method rejected: $(printf '%s' "$resp" | head -c 300)" >&2; exit 6; }
{ read -r num; read -r purl; } <<<"$pr"
verb=opened; [ "$mode" = update ] && verb=updated; [ "$replace" = 1 ] && verb="updated (head replaced)"
echo "PR $verb: $purl (head $hrepo:$head at ${sha:0:12}, tree ${tree:0:12}, base $base)"
echo "next: $HERE/sr-status.py --pr pool/$pkg#$num — done only when that exits 0; never merge a pool PR"
