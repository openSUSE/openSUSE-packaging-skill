#!/bin/bash
# Sync a package's Leap product branch up to its Factory branch on
# src.opensuse.org and open the Package Hub PR — the repetitive git flow for
# "push the latest <pkg> from Factory to Leap", done in one call.
#
# What it does: check for an already-open PR on the leap branch (refuses to
# double-file), clone pool/<pkg> (LFS pointers only), verify the leap branch
# EXISTS (new packages can't be onboarded this way — see below), compare the
# TREES (not just versions — a same-version patch/spec/.changes-only change
# still syncs), make the leap tree identical to the factory branch as one
# commit, fetch the LFS objects, fork, push to your fork, and open a PR
# targeting the leap branch.
#
# IMPORTANT — only works for packages ALREADY in Leap (an existing leap-NN
# branch in pool/<pkg>). Adding a NEW package to Leap needs a pool maintainer to
# create the branch first (a contributor PR cannot create a branch); this script
# errors out in that case. See references/leap-slfo.md.
#
# Requires: a src.opensuse.org login in ~/.config/tea/config.yml, git-lfs, tea.
#
# Usage: leap-sync.sh <pkg> [leap-branch]      (leap-branch default: leap-16.0)
# Exit codes: 0 synced/PR opened or already in sync; 2 error; 3 new-to-Leap
#             (no leap branch); 4 an open PR already targets the leap branch;
#             5 no factory branch; 6 network failure (transient — retry)
set -euo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,26p' "$0"; exit 0;;
  '') sed -n '2,26p' "$0"; exit 2;;
esac
pkg="$1"; leap="${2:-leap-16.0}"
tok=$(python3 -c "import yaml,os;c=yaml.safe_load(open(os.path.expanduser('~/.config/tea/config.yml')));print([l['token'] for l in c['logins'] if l['name']=='src.opensuse.org'][0])" 2>/dev/null) || tok=""
[ -n "$tok" ] || { echo "no src.opensuse.org token in ~/.config/tea/config.yml" >&2; exit 2; }
user=$(python3 -c "import yaml,os;c=yaml.safe_load(open(os.path.expanduser('~/.config/tea/config.yml')));print(next((l.get('user') for l in c['logins'] if l['name']=='src.opensuse.org'),''))" 2>/dev/null) || user=""
[ -n "$user" ] || { echo "could not determine your src.opensuse.org username from the tea login" >&2; exit 2; }

# --- duplicate-PR guard: refuse to double-file over an already-open PR -------
prs=$(curl -sS --max-time 20 -H "Authorization: token $tok" \
      "https://src.opensuse.org/api/v1/repos/pool/$pkg/pulls?state=open" 2>&1) \
  || { echo "could not query open PRs for pool/$pkg (network?): $prs" >&2; exit 6; }
existing=$(printf '%s' "$prs" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for p in d:
    if (p.get('base') or {}).get('ref') == '$leap':
        print(p.get('html_url') or ('#%s' % p.get('number'))); break
" 2>/dev/null) || existing=""
if [ -n "$existing" ]; then
  echo "REFUSING: an open PR already targets pool/$pkg:$leap — $existing" >&2
  exit 4
fi

wd=$(mktemp -d); trap 'rm -rf "$wd"' EXIT

# --- probe the branches separately so the diagnosis is precise ---------------
if ! heads=$(git ls-remote --heads "https://src.opensuse.org/pool/$pkg.git" 2>&1); then
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

GIT_LFS_SKIP_SMUDGE=1 git clone -q "https://src.opensuse.org/pool/$pkg.git" "$wd/$pkg"
cd "$wd/$pkg"
git fetch -q origin factory "$leap"

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

# branch/PR name: version when it moved, short factory commit when it didn't
fsha=$(git rev-parse --short origin/factory)
if [ "$fver" = "$lver" ]; then tag="$fver-$fsha"; else tag="$fver"; fi
br="$leap-sync-$tag"
git checkout -q -b "$br" "origin/$leap"
git rm -rqf . >/dev/null 2>&1 || true
git checkout "origin/factory" -- .
git add -A
git commit -q -m "Update to $fver (sync $leap with Factory)"
# Fetch only what this push needs: the tree above is origin/factory verbatim, so
# its objects are the complete set. NOT "--all" -- that walks every ref in the
# repo, and pool packages routinely have pruned objects on old product branches
# ("No such OID"), which failed the sync over objects the push never touches.
# (Real case: pool/ollama, 4 of 148 objects gone from the 2024 leap branches.)
git lfs fetch origin factory >/dev/null 2>&1 || { echo "git lfs fetch failed — push would lose LFS objects" >&2; exit 2; }
# Prove every pointer in the new tree resolves before pushing.
if missing=$(git lfs fsck --pointers 2>&1 | grep -i 'missing\|corrupt'); then
  echo "LFS objects missing from the synced tree — refusing to push:" >&2
  echo "$missing" >&2
  exit 2
fi

# --- fork + push (token off argv AND off the remote URL) ---------------------
# git-lfs does NOT honor http.extraHeader for its batch/upload API, so a
# header-only push 401s on any repo with LFS objects (most pool packages).
# Instead feed the token through git's credential machinery via GIT_ASKPASS:
# the helper is a 0700 temp file, the token reaches git/git-lfs via a file
# read + env var — never on a command line.
forkerr=$(tea repo fork --repo "pool/$pkg" --login src.opensuse.org 2>&1 >/dev/null) \
  || case "$forkerr" in
       *"already exists"*|*"repository is already forked"*) : ;;   # fine, reuse it
       *) echo "tea repo fork failed: $forkerr" >&2 ;;             # surface, but the fork may still exist — try the push
     esac
git remote add fork "https://src.opensuse.org/$user/$pkg.git" 2>/dev/null \
  || git remote set-url fork "https://src.opensuse.org/$user/$pkg.git"
askpass=$(mktemp) tokfile=$(mktemp)
trap 'rm -f "$askpass" "$tokfile"' EXIT
chmod 600 "$tokfile"; printf '%s' "$tok" > "$tokfile"
printf '#!/bin/sh\ncase "$1" in\n  Username*) echo "%s" ;;\n  Password*) cat "%s" ;;\nesac\n' \
  "$user" "$tokfile" > "$askpass"
chmod 700 "$askpass"
# Push refs and LFS objects SEPARATELY. Gitea forks do not share the parent's
# LFS storage, so the pre-push hook wants to upload every object reachable from
# the branch history — including any pruned on old product branches ("Unable to
# find source for object ..."), which fails the whole push over objects this
# sync never touches. --no-verify skips the hook; the explicit --object-id push
# then uploads exactly the objects of the tree being submitted (fetched and
# fsck-verified above). The PR is still complete: Gitea resolves LFS reads
# through the fork network once these objects exist on the fork.
# (Real case: pool/ollama — refs+5-object push worked where a plain push died
# on 4 long-pruned OIDs from the 2024 leap branches.)
GIT_ASKPASS=$askpass git push -q --no-verify fork "$br" \
  || { echo "push to $user/$pkg failed (does the fork exist? see the tea output above)" >&2; exit 2; }
oids=$(git lfs ls-files -l | awk '{print $1}')
if [ -n "$oids" ]; then
  # shellcheck disable=SC2086 — word-splitting the oid list is intended
  GIT_ASKPASS=$askpass git lfs push --object-id fork $oids \
    || { echo "LFS object push to $user/$pkg failed — PR would have dangling pointers" >&2; exit 2; }
fi

body="Sync the $leap branch up to the Factory version $fver (was $lver). Sources are identical to openSUSE:Factory."
payload=$(python3 -c "import json,sys;print(json.dumps({'head':'$user:$br','base':'$leap','title':'Update to $fver (sync $leap with Factory)','body':sys.argv[1]}))" "$body")
resp=$(curl -sS --max-time 20 -X POST "https://src.opensuse.org/api/v1/repos/pool/$pkg/pulls" \
  -H "Authorization: token $tok" -H "Content-Type: application/json" -d "$payload")
echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);print('PR:', d.get('html_url') or d.get('message'))" 2>/dev/null \
  || { echo "PR API response:"; echo "$resp" | head -c 300; }
