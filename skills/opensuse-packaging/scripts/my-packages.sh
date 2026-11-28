#!/bin/bash
# List packages where the user is an EXPLICIT package-level maintainer
# (role=maintainer on the package itself) — not project-inherited.
# Output: one "<project>\t<package>" line per package, home:/branches/Maintenance excluded.
#
# TWO SOURCES, and they are DISJOINT — you need both:
#   obs  search-packages-by-person — maintainers in the OBS package _meta
#   git  the package's git _maintainership.json (scmsync packages)
# A package hosted in git (src.opensuse.org) has a _meta that is a bare
# <scmsync> stub with NO <person> elements, so the classic search sees nothing;
# conversely a git-index read returns ONLY git-defined entries. Measured on a
# real account: 268 obs + 263 git, overlap ZERO. >1100 OBS projects are already
# scmsync (devel:languages:perl, :nodejs, :erlang, Java:packages, GNOME:Factory,
# devel:openSUSE:Factory, …), so an obs-only query silently under-reports and
# the gap grows with every project that migrates.
#
# The git leg has no typed leaf yet: no geectl read covers the git
# _maintainership.json index, so this script is obs-only until one lands and
# says so on stderr. --source git on its own exits 2.
#
# Usage: my-packages.sh [--project PRJ] [--user OBSUSER] [--source obs|git|both]
#                       [--all-projects] [--show-source]
#   --project PRJ   only packages in PRJ
#   --user OBSUSER  OBS account (default: $GEECTL_OBS_USERNAME). NB the OBS
#                   account often differs from $USER / the email local-part.
#   --source        which backend to ask (default: both)
#   --all-projects  keep derivative product projects (openSUSE:Backports:*,
#                   openSUSE:Leap:*, SUSE:SLFO:*, SUSE:ALP:*). They are dropped
#                   by default: their maintainership is materialised from the
#                   devel project, so for triage they duplicate entries you
#                   already have. The count dropped is always reported on stderr.
#   --show-source   prefix each line with "obs" or "git"
#
# An auth/network failure exits non-zero with geectl's stderr — it must never look
# like "maintains no packages"; a genuinely empty result says so on stderr.
# A failure of the obs backend is fatal for the same reason: a half-answer that
# looks complete is worse than an error.
# Exit: 0 = listed (an empty result is noted on stderr), 2 = usage or a
#       backend query failed.
set -euo pipefail

user="" ; project="" ; source_sel="both" ; all_projects=0 ; show_source=0
while [ $# -gt 0 ]; do
  case "$1" in --user|--project|--source) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; };; esac
  case "$1" in
    --user) user="$2"; shift 2;;
    --project) project="$2"; shift 2;;
    --source) source_sel="$2"; shift 2;;
    --all-projects) all_projects=1; shift;;
    --show-source) show_source=1; shift;;
    -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$source_sel" in obs|git|both) ;; *) echo "--source must be obs, git or both" >&2; exit 2;; esac
[ -n "$user" ] || user="${GEECTL_OBS_USERNAME:-}"
[ -n "$user" ] || { echo "ERROR: no OBS account: pass --user, or set GEECTL_OBS_USERNAME" >&2; exit 2; }

obs_out="" ; git_out="" ; git_projects=""

# ---- source 1: OBS package _meta ------------------------------------------
# role=maintainer (NOT bugowner). Capture first: a geectl failure (auth,
# network) must surface, not be eaten by a pipeline.
# search-packages-by-person matches any role the meta names, so entries that
# carry no role are verified one by one against their package meta (the
# package's own persons, not project-inherited ones).
if [ "$source_sel" != git ]; then
  if ! resp="$(geectl remote search-packages-by-person "$user" 2>&1)"; then
    echo "ERROR: geectl remote search-packages-by-person failed for user '$user':" >&2
    echo "$resp" >&2
    exit 2
  fi
  # Parse with json — the payload shape is the person-search one
  # ({login, packages: [{name, project, ...}]}); accept a bare list or
  # "project/package" strings too. Emits "PRJ<TAB>PKG<TAB>ROLE" where ROLE is
  # "maintainer" when the entry says so, empty when it carries no role.
  if ! candidates="$(printf '%s' "$resp" | python3 -I -c '
import sys, json
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError as e:
    sys.stderr.write(f"ERROR: unparseable person search response: {e}\n"); sys.exit(2)
if isinstance(payload, dict):
    entries = payload.get("packages", [])
elif isinstance(payload, list):
    entries = payload
else:
    sys.stderr.write("ERROR: unexpected person search response shape\n"); sys.exit(2)
for e in entries:
    if isinstance(e, str):
        if "/" in e:
            prj, name = e.split("/", 1)
            print(f"{prj}\t{name}\t")
        continue
    prj, name = e.get("project", ""), e.get("name", "")
    if not prj or not name:
        continue
    print(prj + "\t" + name + "\t" + e.get("role", ""))
')"; then
    echo "ERROR: the person search answer for '$user' did not parse" >&2
    exit 2
  fi
  obs_out="$(while IFS=$'\t' read -r prj pkg role; do
    [ -n "$prj" ] || continue
    if [ "$role" = maintainer ]; then
      printf 'obs\t%s\t%s\n' "$prj" "$pkg"
    elif [ -z "$role" ]; then
      # No role on the entry: the package meta decides (its own persons).
      if meta="$(geectl remote package-meta "$prj" "$pkg" 2>/dev/null)" && \
         python3 -I -c '
import sys, json
meta = json.load(sys.stdin)
user = sys.argv[1]
sys.exit(0 if any(p.get("name") == user and p.get("role") == "maintainer"
                  for p in meta.get("persons", [])) else 1)
' "$user" <<<"$meta"; then
        printf 'obs\t%s\t%s\n' "$prj" "$pkg"
      fi
    fi
  done <<<"$candidates")"
fi

# ---- source 2: git _maintainership.json ------------------------------------
# No typed leaf reads the git index yet, so the git leg is UNKNOWN, never
# silently empty: --source git alone fails, --source both lists obs only and
# says the git leg is missing.
if [ "$source_sel" = git ]; then
  echo "ERROR: no typed leaf reads the git _maintainership.json index yet — the git leg is unavailable" >&2
  exit 2
fi
if [ "$source_sel" = both ]; then
  echo "note: git-defined maintainerships are NOT listed (no typed leaf reads the git _maintainership.json index yet); this is obs-only and under-reports git-maintained packages" >&2
fi

merged="$(printf '%s\n%s\n' "$obs_out" "$git_out" | grep -v '^$' || true)"

# ---- filtering --------------------------------------------------------------
filtered="$(printf '%s\n' "$merged" \
  | grep -vE '^[a-z]+	(home:|.*:branches:|openSUSE:Maintenance)' || true)"

if [ "$all_projects" = 0 ]; then
  before=$(printf '%s\n' "$filtered" | grep -c . || true)
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE '^[a-z]+	(openSUSE:Backports:|openSUSE:Leap:|SUSE:SLFO:|SUSE:ALP:)' || true)"
  after=$(printf '%s\n' "$filtered" | grep -c . || true)
  dropped=$(( before - after ))
  [ "$dropped" -gt 0 ] && \
    echo "note: dropped $dropped entr$([ "$dropped" = 1 ] && echo y || echo ies) in derivative product projects (Backports/Leap/SLFO/ALP); --all-projects keeps them" >&2
fi

if [ -n "$project" ]; then
  filtered="$(printf '%s\n' "$filtered" | grep -E "^[a-z]+	$project	" || true)"
fi

filtered="$(printf '%s\n' "$filtered" | grep -v '^$' | sort -u -t'	' -k2,3 || true)"

if [ -n "$git_projects" ]; then
  echo "note: also maintainer of these git PROJECTS (project-level, out of scope here): $(printf '%s' "$git_projects" | tr '\n' ' ')" >&2
fi

if [ -z "$filtered" ]; then
  echo "no explicit package-level maintainerships for '$user'${project:+ in $project}" >&2
  exit 0
fi

if [ "$show_source" = 1 ]; then
  printf '%s\n' "$filtered"
else
  printf '%s\n' "$filtered" | cut -f2,3
fi
