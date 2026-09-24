#!/bin/bash
# Sync a package's Leap product branch up to its Factory branch on
# src.opensuse.org and build that exact tree against the Leap target — the
# repetitive half of "push the latest <pkg> from Factory to Leap". It stops
# there: no PR head is pushed and no PR opened (--remote pushes only the build
# branch target-gate.sh builds from); after the review, pool-pr.sh does that.
#
# What it does: check for an open PR on the leap branch (refuses someone
# else's; yours is pool-pr.sh's to update or replace), verify the leap branch EXISTS
# (new packages can't be onboarded this way — see below), clone pool/<pkg>
# (LFS pointers only) into D/pool/<pkg> or reuse that clone, compare the TREES
# (not just versions — a same-version patch/spec/.changes-only change still
# syncs), then in a worktree D/<leap-branch>/<pkg> make the leap tree identical
# to the factory branch as one commit, fetch and check out its LFS objects,
# and run target-gate.sh on it: a native build, or an OBS build of the same
# tree with --remote. Then it prints the review and pool-pr.sh steps.
#
# IMPORTANT — only works for packages ALREADY in Leap (an existing leap-NN
# branch in pool/<pkg>). Adding a NEW package to Leap needs a pool maintainer to
# create the branch first (a contributor PR cannot create a branch); this script
# errors out in that case. See references/leap-slfo.md.
#
# Requires: a src.opensuse.org login in ~/.config/tea/config.yml, git-lfs.
#
# Usage: leap-sync.sh [--dir D] [--remote] <pkg> [leap-branch]   (branch default: leap-16.0)
#   --dir     where the clone and the per-branch worktrees go (default: .)
#   --remote  build on OBS against the same target instead of natively
#             (x86_64-only packages, builds too big for this host)
# Exit codes: 0 synced and target build green, or already in sync; 2 error;
#             3 new-to-Leap (no leap branch); 4 someone else's open PR targets
#             the leap branch; 5 no factory branch; 6 network failure
#             (transient — retry); 7 target build red; 8 remote build pending
set -euo pipefail
# Resolved, so a symlinked copy never runs a target-gate.sh placed beside the link.
HERE="$(dirname "$(readlink -f "$0")")"
G=https://src.opensuse.org
usage() { awk 'NR>1 { if (!/^#/) exit; print }' "$0"; }
dir=.; remote=0; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --dir) [ $# -ge 2 ] || { echo "--dir needs a value" >&2; exit 2; }; dir=$2; shift 2;;
    --remote) remote=1; shift;;
    --refresh) echo "--refresh is gone: sync and build here, then pool-pr.sh updates your open PR" >&2; exit 2;;
    -*) echo "leap-sync.sh: unknown option $1" >&2; exit 2;;
    *) args+=("$1"); shift;;
  esac
done
if [ ${#args[@]} -lt 1 ] || [ ${#args[@]} -gt 2 ]; then usage; exit 2; fi
pkg=${args[0]}; leap=${args[1]:-leap-16.0}
[[ $leap =~ ^leap-16\.[0-9]+$ ]] \
  || { echo "REFUSING: '$leap' is not a leap-16.x branch (SLFO branches: ask for the route)" >&2; exit 2; }
dir=$(cd "$dir" 2>/dev/null && pwd -P) || { echo "--dir: no such directory" >&2; exit 2; }
# target-gate.sh refuses to build a clone there; fail before cloning, not after.
case "$dir/" in /tmp/*) echo "REFUSING: $dir is under /tmp — pass --dir elsewhere (e.g. under /var/tmp)" >&2; exit 2;; esac
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

# --- duplicate-PR guard: refuse to double-file over someone else's open PR ---
# The token stays off argv: curl reads the header from a 0600 file, gone after.
sec=$(mktemp --directory -p "${TMPDIR:-/var/tmp}" leap-sync.XXXXXX) || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$sec"' EXIT
(umask 077; printf 'Authorization: token %s\n' "$tok" > "$sec/auth")
prs=$(curl -sS --max-time 20 -H "@$sec/auth" \
      "$G/api/v1/repos/pool/$pkg/pulls?state=open&limit=50" 2>&1) \
  || { echo "could not query open PRs for pool/$pkg (network?): $prs" >&2; exit 6; }
rm -rf "$sec"; trap - EXIT
existing=$(printf '%s' "$prs" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
if not isinstance(d, list): sys.exit(1)
on = [p for p in d if (p.get('base') or {}).get('ref') == sys.argv[1]]
own = lambda p: ((((p.get('head') or {}).get('repo') or {}).get('owner') or {}).get('login') or '').lower() == sys.argv[2].lower()
p = next((p for p in on if own(p)), None) or next(iter(on), None)
if p: print('%s\t%s\t%s' % ('mine' if own(p) else 'other', p.get('number'), p.get('html_url') or ''))
" "$leap" "$user" 2>/dev/null) || { echo "unparseable open-PR list for pool/$pkg — cannot rule out a duplicate" >&2; exit 6; }
prnote=""
case "$existing" in
  other*) echo "REFUSING: an open PR already targets pool/$pkg:$leap — $(printf '%s' "$existing" | cut -f3)" >&2; exit 4;;
  mine*) prnote="   (your open PR #$(printf '%s' "$existing" | cut -f2) is on another head: pool-pr.sh refuses to drop its commits unless --replace — check what it carries first)";;
esac

# --- probe the branches separately so the diagnosis is precise ---------------
if ! heads=$(git ls-remote --heads "$G/pool/$pkg.git" 2>&1); then
  echo "could not reach pool/$pkg (network failure or no such repo — transient? retry): $heads" >&2
  exit 6
fi
if ! printf '%s\n' "$heads" | grep -q "refs/heads/factory$"; then
  echo "ERROR: pool/$pkg has no 'factory' branch — unexpected repo layout, inspect it by hand." >&2
  exit 5
fi
if ! printf '%s\n' "$heads" | grep -q "refs/heads/$leap$"; then
  echo "ERROR: pool/$pkg has no '$leap' branch — this is a NEW-to-Leap package; a pool maintainer must create the branch first (contributor PRs can't). See references/leap-slfo.md." >&2
  exit 3
fi

# One clone per package, one worktree per leap branch: a 16.0 and a 16.1 sync
# never share a checkout, and target-gate.sh stamps land in the shared git dir.
clone="$dir/pool/$pkg"; wt="$dir/$leap/$pkg"
if [ -e "$wt" ]; then
  echo "REFUSING: $wt already exists — continue there with target-gate.sh, then pool-pr.sh (not leap-sync.sh), or drop it and its commits deliberately: git -C '$clone' worktree remove --force '$wt' && git -C '$clone' branch -D $leap" >&2
  exit 2
fi
fresh=0; made=0; keep=0
# One EXIT trap for everything: undo a half-made sync, but never the synced tree
# once the build has seen it.
# shellcheck disable=SC2317  # runs from the trap
cleanup() {
  [ "$keep" = 1 ] && return 0
  if [ "$made" = 1 ]; then
    rm -rf "$wt"
    git -C "$clone" worktree prune >/dev/null 2>&1 || true
    git -C "$clone" branch -q -D "$leap" >/dev/null 2>&1 || true
  fi
  [ "$fresh" = 1 ] && rm -rf "$clone"
  rmdir "$dir/$leap" "$dir/pool" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

if [ -e "$clone/.git" ]; then
  o=$(git -C "$clone" config --get remote.origin.url 2>/dev/null) || o=""
  [ "${o%.git}" = "$G/pool/$pkg" ] \
    || { echo "REFUSING: $clone exists and is not a clone of pool/$pkg (origin: ${o:-none})" >&2; exit 2; }
  git -C "$clone" fetch -q origin factory "$leap" || { echo "could not fetch pool/$pkg (network?)" >&2; exit 6; }
elif [ -e "$clone" ]; then
  echo "REFUSING: $clone exists and is not a git clone" >&2; exit 2
else
  mkdir -p "$dir/pool"; fresh=1
  GIT_LFS_SKIP_SMUDGE=1 git clone -q --branch factory "$G/pool/$pkg.git" "$clone" \
    || { echo "could not clone pool/$pkg (network?)" >&2; exit 6; }
fi
cd "$clone"

fver=$(git show "origin/factory:$pkg.spec" 2>/dev/null | grep -iE '^Version:' | head -1 | awk '{print $2}') || fver=""
lver=$(git show "origin/$leap:$pkg.spec"   2>/dev/null | grep -iE '^Version:' | head -1 | awk '{print $2}') || lver=""
echo "$pkg: factory=$fver  $leap=$lver"
[ -n "$fver" ] || { echo "could not read factory version" >&2; exit 2; }

# --- in-sync gate: compare TREES, not versions (same-version content changes
# — patch-only CVE fixes, spec fixes, new .changes entries — must still sync) --
if [ "$(git rev-parse "origin/factory^{tree}")" = "$(git rev-parse "origin/$leap^{tree}")" ]; then
  echo "already in sync (identical trees) — nothing to do"
  exit 0
fi

# -B below resets the local leap branch: never over commits it has that origin lacks.
if git rev-parse -q --verify "refs/heads/$leap" >/dev/null; then
  ahead=$(git rev-list --count "refs/remotes/origin/$leap..refs/heads/$leap") \
    || { echo "could not compare local $leap with origin/$leap in $clone" >&2; exit 2; }
  if [ "$ahead" != 0 ]; then
    echo "REFUSING: local branch $leap in $clone has $ahead commit(s) not on origin/$leap, which a sync would reset — continue on it (git -C '$clone' worktree add '$wt' $leap, then target-gate.sh and pool-pr.sh), or drop them deliberately: git -C '$clone' branch -D $leap" >&2
    exit 2
  fi
fi
git worktree prune
mkdir -p "$dir/$leap"
GIT_LFS_SKIP_SMUDGE=1 git worktree add -q --track -B "$leap" "$wt" "origin/$leap" \
  || { echo "could not add the $leap worktree at $wt" >&2; exit 2; }
made=1
cd "$wt"
git rm -rqf . >/dev/null 2>&1 || true
if ! { GIT_LFS_SKIP_SMUDGE=1 git checkout "origin/factory" -- . && git add -A \
       && git commit -q -m "Update to $fver (sync $leap with Factory)" \
            -m "Sync the $leap branch up to the Factory version $fver (was $lver). Sources are identical to openSUSE:Factory."; }; then
  echo "content sync of $leap to factory failed in $wt" >&2; exit 2
fi
# Fetch only what this tree needs: it is origin/factory verbatim, so its objects
# are the complete set. NOT "--all" -- that walks every ref in the repo, and
# pool packages routinely have pruned objects on old product branches ("No
# such OID"). (Real case: pool/ollama, 4 of 148 objects gone from the 2024
# leap branches.) HEAD, not "factory": git-lfs resolves that name to the local
# branch, which a reused clone leaves behind origin/factory. The build needs
# the real files, hence the checkout.
lfsout=$(git lfs fetch origin HEAD 2>&1 && git lfs checkout 2>&1) \
  || { echo "git lfs fetch/checkout failed — the tree cannot be built without its LFS objects:" >&2
       printf '%s\n' "$lfsout" | tail -5 >&2; exit 2; }

# From here the synced tree is the build's subject: keep it whatever happens.
keep=1
tree=$(git rev-parse --short=12 'HEAD^{tree}')
mode=--build; [ "$remote" = 1 ] && mode=--remote
rc=0; "$HERE/target-gate.sh" "$wt" "$mode" || rc=$?
case "$rc" in
  0)
    echo "target build GREEN: tree $tree on $leap, in $wt. Next, in order:"
    echo "  1. review that tree: $(cd "$HERE/.." && pwd)/agents/changes-review.md — the verdict file starts with PASS and names tree $tree"
    echo "  2. $HERE/target-gate.sh $wt --review FILE"
    echo "  3. $HERE/pool-pr.sh $wt$prnote"
    exit 0;;
  1)
    echo "target build RED: tree $tree on $leap — fix it in $wt, commit, and re-run $HERE/target-gate.sh $wt $mode (not leap-sync.sh)" >&2
    exit 7;;
  3)
    if [ "$remote" = 1 ]; then
      echo "remote build pending: tree $tree on $leap — re-run $HERE/target-gate.sh $wt --remote until it exits 0" >&2
      exit 8
    fi;;
esac
echo "target-gate.sh stopped (exit $rc, see above) — the synced tree stays in $wt" >&2
exit 2
