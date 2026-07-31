#!/bin/bash
# Decide whether YOUR OWN submit request against a package may be accepted and
# forwarded onward unattended, or must stop for a human.
#
# THE GATE IS THE `reviewer` ROLE, NOT CO-MAINTAINERSHIP. A co-maintainer who
# never set a reviewer role has not asked to be consulted; an explicit
# <person role="reviewer"/> (or a group reviewer) HAS. Gating on "is anyone else
# a maintainer" is the wrong test — it blocks the overwhelming majority of
# normal packages while catching nothing the reviewer role does not already
# catch. Real case that produced this rule: two packages that had to be handled
# differently were distinguishable ONLY by the reviewer role; both had
# co-maintainers.
#
# Two ways to be eligible:
#   1. you hold `maintainer` on the PACKAGE, or
#   2. the package has NO maintainer at all and you hold `maintainer` on the
#      PROJECT — an unowned package in a project you run is yours to move.
# Either way an explicit reviewer (package or project, person or group) blocks.
#
# This ONLY ever applies to requests YOU created. Never use it to accept or
# decline somebody else's request — that always needs an explicit human
# decision, regardless of what roles are set.
#
#   exit 0  ELIGIBLE   — no reviewer set, and you maintain the package (or the
#                        package is unmaintained and you maintain the project)
#   exit 3  BLOCKED    — an explicit reviewer role exists; stop, report, wait
#   exit 4  NOT_YOURS  — package has a maintainer and it is not you
#   exit 5  package/meta unreadable (404, auth, network)
#   exit 2  usage error
#
# Usage: autoforward-gate.sh <project> <package> [--user <account>]
#        autoforward-gate.sh --batch <file>   # lines of "<project>\t<package>"
#   --user defaults to `osc whois`.
set -uo pipefail

usage() { sed -n '2,36p' "$0"; }
case "${1:-}" in
  -h|--help) usage; exit 0;;
  '') usage; exit 2;;
esac

user=""; batch=""; prj=""; pkg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user)  user="${2:-}"; shift 2;;
    --batch) batch="${2:-}"; shift 2;;
    -*)      usage; exit 2;;
    *)       if [ -z "$prj" ]; then prj="$1"; else pkg="$1"; fi; shift;;
  esac
done

if [ -z "$user" ]; then
  user="$(osc whois 2>/dev/null | sed 's/:.*//')"
  [ -n "$user" ] || { echo "cannot determine account (osc whois failed); pass --user" >&2; exit 2; }
fi

# role extraction. Anchor the sed: a greedy .*=" would capture role="..." instead
# of the userid/groupid.
_maints() { printf '%s' "$1" | grep -o '<person userid="[^"]*" role="maintainer"' \
            | sed -E 's/^<person userid="([^"]*)".*/\1/' | sort -u; }
_revs()   { printf '%s' "$1" \
            | grep -o '<\(person\|group\) \(userid\|groupid\)="[^"]*" role="reviewer"' \
            | sed -E 's/^<(person|group) (userid|groupid)="([^"]*)".*/\3/' | sort -u; }

# Prints "<verdict>\t<reviewers>\t<other-maintainers>\t<why>"; returns exit code.
check_one() {
  local p="$1" k="$2" pmeta prjmeta maints revs prjrevs others prjmaints
  pmeta="$(osc api "/source/$p/$k/_meta" 2>/dev/null)" || return 5
  [ -n "$pmeta" ] || return 5
  prjmeta="$(osc api "/source/$p/_meta" 2>/dev/null)" || prjmeta=""

  maints="$(_maints "$pmeta")"
  revs="$(_revs "$pmeta")"
  prjrevs="$(_revs "$prjmeta")"
  # a project-level reviewer gates everything inside it, same as a package one
  revs="$(printf '%s\n%s\n' "$revs" "$prjrevs" | grep -v '^$' | sort -u)"
  others="$(printf '%s\n' "$maints" | grep -v '^$' | grep -vx "$user" | paste -sd, -)"

  if [ -n "$revs" ]; then
    printf 'BLOCKED\t%s\t%s\treviewer set\n' "$(printf '%s' "$revs" | paste -sd, -)" "${others:--}"
    return 3
  fi
  if printf '%s\n' "$maints" | grep -qx "$user"; then
    printf 'ELIGIBLE\t-\t%s\tpackage maintainer\n' "${others:--}"
    return 0
  fi
  # no maintainer at all on the package -> fall back to project maintainership
  if [ -z "$(printf '%s\n' "$maints" | grep -v '^$')" ]; then
    prjmaints="$(_maints "$prjmeta")"
    if printf '%s\n' "$prjmaints" | grep -qx "$user"; then
      printf 'ELIGIBLE\t-\t-\tpackage unmaintained, project maintainer\n'
      return 0
    fi
    printf 'NOT_YOURS\t-\t-\tpackage unmaintained, not a project maintainer either\n'
    return 4
  fi
  printf 'NOT_YOURS\t-\t%s\tmaintained by someone else\n' "${others:--}"
  return 4
}

if [ -n "$batch" ]; then
  [ -r "$batch" ] || { echo "cannot read $batch" >&2; exit 2; }
  rc_any=0
  while IFS=$'\t' read -r bp bk; do
    [ -n "${bp:-}" ] && [ -n "${bk:-}" ] || continue
    out="$(check_one "$bp" "$bk")"; rc=$?
    [ $rc -eq 5 ] && out=$'UNREADABLE\t-\t-\tmeta unreadable'
    printf '%s/%s\t%s\n' "$bp" "$bk" "$out"
    [ $rc -eq 3 ] && rc_any=3
  done < "$batch"
  exit $rc_any
fi

[ -n "$prj" ] && [ -n "$pkg" ] || { usage; exit 2; }
out="$(check_one "$prj" "$pkg")"; rc=$?
if [ $rc -eq 5 ]; then
  echo "cannot read /source/$prj/$pkg/_meta (absent, auth, or network)" >&2
  exit 5
fi
IFS=$'\t' read -r verdict revs others why <<<"$out"
case "$verdict" in
  ELIGIBLE)  echo "ELIGIBLE — $why, no reviewer role set (other maintainers: $others)";;
  BLOCKED)   echo "BLOCKED — explicit reviewer role: $revs — do NOT accept/forward unattended";;
  NOT_YOURS) echo "NOT_YOURS — $why (maintainers: $others)";;
esac
exit $rc
