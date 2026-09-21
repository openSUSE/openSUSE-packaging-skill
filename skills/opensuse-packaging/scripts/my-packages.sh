#!/bin/bash
# List packages where the user is an EXPLICIT package-level maintainer
# (role=maintainer on the package itself) — not project-inherited.
# Output: one "<project>\t<package>" line per package, home:/branches/Maintenance excluded.
#
# TWO SOURCES, and they are DISJOINT — you need both:
#   obs  /search/package?match=person[...]  — maintainers in the OBS package _meta
#   git  osc maintainer -U <user>           — maintainers in the package's git
#                                             _maintainership.json (scmsync packages)
# A package hosted in git (src.opensuse.org) has a _meta that is a bare
# <scmsync> stub with NO <person> elements, so the classic search sees nothing;
# conversely `osc maintainer -U` returns ONLY git-defined entries. Measured on a
# real account: 268 obs + 263 git, overlap ZERO. >1100 OBS projects are already
# scmsync (devel:languages:perl, :nodejs, :erlang, Java:packages, GNOME:Factory,
# devel:openSUSE:Factory, …), so an obs-only query silently under-reports and
# the gap grows with every project that migrates.
#
# Usage: my-packages.sh [--project PRJ] [--user OBSUSER] [--source obs|git|both]
#                       [--all-projects] [--show-source]
#   --project PRJ   only packages in PRJ
#   --user OBSUSER  OBS account (default: `osc whois`). NB the OBS account often
#                   differs from $USER / the email local-part.
#   --source        which backend to ask (default: both)
#   --all-projects  keep derivative product projects (openSUSE:Backports:*,
#                   openSUSE:Leap:*, SUSE:SLFO:*, SUSE:ALP:*). They are dropped
#                   by default: their maintainership is materialised from the
#                   devel project, so for triage they duplicate entries you
#                   already have. The count dropped is always reported on stderr.
#   --show-source   prefix each line with "obs" or "git"
#
# An auth/network failure exits non-zero with osc's stderr — it must never look
# like "maintains no packages"; a genuinely empty result says so on stderr.
# A failure of EITHER backend is fatal for the same reason: a half-answer that
# looks complete is worse than an error.
set -euo pipefail

user="" ; project="" ; source_sel="both" ; all_projects=0 ; show_source=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) user="$2"; shift 2;;
    --project) project="$2"; shift 2;;
    --source) source_sel="$2"; shift 2;;
    --all-projects) all_projects=1; shift;;
    --show-source) show_source=1; shift;;
    -h|--help) sed -n '2,35p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$source_sel" in obs|git|both) ;; *) echo "--source must be obs, git or both" >&2; exit 2;; esac
[ -n "$user" ] || user="$(osc whois | sed 's/:.*//')"

obs_out="" ; git_out="" ; git_projects=""

# ---- source 1: OBS package _meta ------------------------------------------
# role=maintainer (NOT bugowner). Capture first: an osc failure (auth, network)
# must surface, not be eaten by a pipeline.
if [ "$source_sel" != git ]; then
  if ! resp="$(osc api "/search/package?match=person[@userid='$user' and @role='maintainer']" 2>&1)"; then
    echo "ERROR: osc api search failed for user '$user':" >&2
    echo "$resp" >&2
    exit 2
  fi
  # Parse with xml.etree — a grep of 'name=... project=...' depends on OBS's
  # attribute order and would silently break on a reorder.
  obs_out="$(printf '%s' "$resp" | python3 -c '
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read() or "<collection/>")
except ET.ParseError as e:
    sys.stderr.write(f"ERROR: unparseable search response: {e}\n"); sys.exit(2)
for p in root.findall("package"):
    prj, name = p.get("project", ""), p.get("name", "")
    if not prj or not name:
        continue
    print(f"obs\t{prj}\t{name}")
')"
fi

# ---- source 2: git _maintainership.json ------------------------------------
# `osc maintainer -U` prints one line per entry, tagged by where it is defined:
#   "Defined in git package: <project>/<package>"
#   "Defined in git project: <project>"          (project-level -> not our scope,
#                                                 reported on stderr as a note)
if [ "$source_sel" != obs ]; then
  if ! gresp="$(osc maintainer -U "$user" 2>&1)"; then
    echo "ERROR: 'osc maintainer -U $user' failed (needs osc >= 1.15):" >&2
    echo "$gresp" >&2
    exit 2
  fi
  git_out="$(printf '%s\n' "$gresp" \
    | sed -n 's|^Defined in git package: \([^/]*\)/\(.*\)$|git\t\1\t\2|p')" || true
  git_projects="$(printf '%s\n' "$gresp" | sed -n 's|^Defined in git project: ||p')" || true
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
