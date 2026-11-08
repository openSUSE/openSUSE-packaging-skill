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
# A project kept in git (its _meta has <scmsync>, devel:openSUSE:Factory from
# devel-factory/_ObsPrj) has stub package _meta with no <person>: its
# maintainers are in the project git's _maintainership.json (the package's
# list, else the project's ""), and the Reviewers of its workflow.config are
# reviewer roles too. Both are read through git-obs.
# And the project must be the one Factory develops the package in: a request
# accepted anywhere else lands in the wrong devel project (real case: apache-arrow
# accepted into Application:Geo, whose package only linked to science).
#
# This ONLY ever applies to requests YOU created. Never use it to accept or
# decline somebody else's request — that always needs an explicit human
# decision, regardless of what roles are set.
#
#   exit 0  ELIGIBLE   — no reviewer set, and you maintain the package (or the
#                        package is unmaintained and you maintain the project)
#   exit 3  BLOCKED    — an explicit reviewer role exists; stop, report, wait
#   exit 4  NOT_YOURS  — package has a maintainer and it is not you
#   exit 5  package or project _meta unreadable (404, auth, network), or
#           Factory's devel project lookup failed, or the project git's
#           _maintainership.json or workflow.config unreadable
#   exit 6  WRONG-DEVEL — openSUSE:Factory develops the package in another
#           project, or has it under another spelling; accept nothing here,
#           submit there
#   exit 2  usage error (also an empty --batch file)
#
# --batch exits with the worst row: 5 UNREADABLE > 6 WRONG-DEVEL > 3 BLOCKED >
# 4 NOT_YOURS > 0.
#
# Usage: autoforward-gate.sh <project> <package> [--user <account>]
#        autoforward-gate.sh --batch <file>   # lines of "<project>\t<package>"
#   --user defaults to `osc whois`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

usage() { awk 'NR>1 { if (!/^#/) exit; print }' "$0"; }
case "${1:-}" in
  -h|--help) usage; exit 0;;
  '') usage; exit 2;;
esac

user=""; batch=""; prj=""; pkg=""
while [ $# -gt 0 ]; do
  case "$1" in --user|--batch) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; };; esac
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

# The value of attribute $1 on the <link> element in $2, compared as a string.
_attr() { printf '%s' "$2" | tr '\n' ' ' | sed -n "s/.*<link[^>]* $1=\"\([^\"]*\)\".*/\1/p" | head -1; }

# The URL a project _meta's <scmsync> names, "" for a project OBS keeps.
_scm() { printf '%s' "$1" | tr '\n' ' ' | sed -n 's|.*<scmsync>[[:space:]]*\([^<[:space:]]*\)[[:space:]]*</scmsync>.*|\1|p' | head -1; }

# File $2 of the project git $1 (owner/repo) into $3: 0 read, 4 absent, 5 failed.
_gitfile() {
  local err
  err="$(timeout 60 git-obs -G src.opensuse.org -q api "/repos/$1/raw/$2" 2>&1 >"$3")" && return 0
  grep -q 'ERROR: 404' <<<"$err" && return 4
  return 5
}

# "<maintainers>\t<reviewers>\t<package|project>" (- for none) of package $2 from the
# project git $1's _maintainership.json ($3) and workflow.config ($4, "" for
# none), or why not and exit 1. workflow.config is JSON with comments and
# trailing commas, as autogits reads it (hujson).
read -r -d '' GIT_ROLES <<'PY'
import json, re, sys
name, pkg, mfile, wfile = sys.argv[1:]
def strip(code):
    return re.sub(r",(\s*[\]}])", r"\1", "".join(code))
def jwcc(text):
    out, code, i = [], [], 0
    while i < len(text):
        if text[i] == '"':
            j = i + 1
            while j < len(text) and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out += [strip(code), text[i : j + 1]]
            code, i = [], j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = len(text) if j < 0 else j
        elif text.startswith("/*", i):
            i = text.index("*/", i + 2) + 2
        else:
            code.append(text[i])
            i += 1
    return json.loads("".join(out) + strip(code))
try:
    m = json.load(open(mfile, encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(f"{name}'s _maintainership.json did not parse")
if not isinstance(m, dict):
    sys.exit(f"{name} has no _maintainership.json")
pk, pr = m.get(pkg) or [], m.get("") or []
if not isinstance(pk, list) or not isinstance(pr, list):
    sys.exit(f"{name}'s _maintainership.json did not parse")
revs = set()
if wfile:
    try:
        conf = jwcc(open(wfile, encoding="utf-8").read())
    except (OSError, ValueError):
        sys.exit(f"{name}'s workflow.config did not parse")
    r = (conf.get("Reviewers") or []) if isinstance(conf, dict) else None
    if not isinstance(r, (list, dict)) or not all(isinstance(x, str) for x in r):
        sys.exit(f"{name}'s workflow.config did not parse")
    revs = {x.lstrip("+-*~") for x in r} - {""}
print(",".join(sorted(str(x) for x in set(pk or pr))) or "-", ",".join(sorted(revs)) or "-",
      "package" if pk else "project", sep="\t")
PY

# GIT_ROLES for package $2 of the project git $1 (owner/repo), its files read
# once a --batch run; the reason it cannot tell, and rc 5.
_gitroles() {
  local d rc w=""
  [ -n "$cache" ] || [ -n "${gtmp:-}" ] || { gtmp="$(mktemp -d)"; trap 'rm -rf "$gtmp"' EXIT; }
  d="${cache:-$gtmp}/git-${1/\//_}"
  if [ ! -e "$d/read" ]; then
    rm -rf "$d"; mkdir -p "$d"
    _gitfile "$1" _maintainership.json "$d/m"; rc=$?
    [ $rc -ne 4 ] || { echo "$1 has no _maintainership.json"; return 5; }
    [ $rc -eq 0 ] || { echo "cannot read $1/_maintainership.json"; return 5; }
    _gitfile "$1" workflow.config "$d/w"; rc=$?
    [ $rc -ne 4 ] || rm -f "$d/w"
    [ $rc -eq 0 ] || [ $rc -eq 4 ] || { echo "cannot read $1/workflow.config"; return 5; }
    : > "$d/read"
  fi
  [ ! -e "$d/w" ] || w="$d/w"
  python3 -I -c "$GIT_ROLES" "$1" "$2" "$d/m" "$w" 2>&1 || return 5
}

# Prints "<verdict>\t<reviewers>\t<other-maintainers>\t<why>"; returns exit code.
check_one() {
  local p="$1" k="$2" pmeta prjmeta maints revs prjrevs others prjmaints url u git roles grevs from
  pmeta="$(osc api "/source/$p/$k/_meta" 2>/dev/null)" || return 5
  [ -n "$pmeta" ] || return 5
  if [ "$p" != openSUSE:Factory ]; then
    local devel drc
    devel="$(bash "$here/devel-of.sh" "$k" 2>/dev/null)"; drc=$?
    case $drc in
      0) if [ "${devel%/*}" != "$p" ]; then
           # the devel package may be a _link to this one, which is fine
           local link lrc lprj lpkg
           link="$(osc api "/source/$devel/_link" 2>&1)"; lrc=$?
           if [ $lrc -ne 0 ]; then
             grep -q 'HTTP Error 404' <<<"$link" || return 5
             link=""
           fi
           lprj="$(_attr project "$link")"; lpkg="$(_attr package "$link")"
           if [ "$lprj" != "$p" ] || [ "${lpkg:-${devel#*/}}" != "$k" ]; then
             printf 'WRONG-DEVEL\t-\t-\topenSUSE:Factory develops it in %s\n' "${devel%/*}"
             return 6
           fi
         fi;;
      3|4) ;;  # not in Factory, or no devel project named: nothing to contradict
      6) printf 'WRONG-DEVEL\t-\t-\t%s\n' "$devel"; return 6;;  # Factory has it under another spelling
      *) return 5;;
    esac
  fi
  # --batch reads each project's _meta once
  if [ -n "$cache" ] && [ -f "$cache/$p" ]; then
    prjmeta="$(cat "$cache/$p")"
  else
    # unread, a project-level reviewer would go unseen
    prjmeta="$(osc api "/source/$p/_meta" 2>/dev/null)" || return 5
    [ -z "$cache" ] || printf '%s' "$prjmeta" > "$cache/$p"
  fi

  maints="$(_maints "$pmeta")"
  revs="$(_revs "$pmeta")"
  prjrevs="$(_revs "$prjmeta")"
  # a project-level reviewer gates everything inside it, same as a package one
  revs="$(printf '%s\n%s\n' "$revs" "$prjrevs" | grep -v '^$' | sort -u)"
  # a project kept in git: the OBS _meta are stubs, its roles are in the project git
  url="$(_scm "$prjmeta")"; git=""
  if [ -n "$url" ]; then
    u="${url%%[?#]*}"; u="${u%.git}"
    if [[ $u =~ ^https://src\.opensuse\.org/([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9_][A-Za-z0-9_.+-]*)$ ]]; then
      git="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
      printf 'UNREADABLE\t-\t-\t%s is kept in %s, whose maintainers this cannot read\n' "$p" "$url"
      return 5
    fi
    roles="$(_gitroles "$git" "$k")" || { printf 'UNREADABLE\t-\t-\t%s\n' "$roles"; return 5; }
    IFS=$'\t' read -r maints grevs from <<<"$roles"
    maints="$(tr , '\n' <<<"${maints#-}")"
    revs="$(printf '%s\n%s\n' "$revs" "$(tr , '\n' <<<"${grevs#-}")" | grep -v '^$' | sort -u)"
  fi
  others="$(printf '%s\n' "$maints" | grep -v '^$' | grep -vx "$user" | paste -sd, -)"

  if [ -n "$revs" ]; then
    printf 'BLOCKED\t%s\t%s\treviewer set\n' "$(printf '%s' "$revs" | paste -sd, -)" "${others:--}"
    return 3
  fi
  if printf '%s\n' "$maints" | grep -qx "$user"; then
    if [ -n "$git" ]; then
      printf 'ELIGIBLE\t-\t%s\t%s maintainer in %s/_maintainership.json\n' "${others:--}" "$from" "$git"
    else
      printf 'ELIGIBLE\t-\t%s\tpackage maintainer\n' "${others:--}"
    fi
    return 0
  fi
  if [ -n "$git" ]; then
    printf 'NOT_YOURS\t-\t%s\tnot a maintainer in %s/_maintainership.json\n' "${others:--}" "$git"
    return 4
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

cache=""
if [ -n "$batch" ]; then
  [ -r "$batch" ] || { echo "cannot read $batch" >&2; exit 2; }
  cache="$(mktemp -d)"; trap 'rm -rf "$cache"' EXIT
  mkdir "$cache/devel-of" && export DEVEL_OF_CACHE="$cache/devel-of"  # one package list a run
  rc_any=0; rows=0
  rank() { case $1 in 5) echo 4;; 6) echo 3;; 3) echo 2;; 4) echo 1;; *) echo 0;; esac; }
  while IFS=$'\t' read -r bp bk; do
    [ -n "${bp:-}" ] && [ -n "${bk:-}" ] || continue
    rows=$((rows+1))
    out="$(check_one "$bp" "$bk")"; rc=$?
    [ $rc -eq 5 ] && [ -z "$out" ] && out=$'UNREADABLE\t-\t-\tmeta unreadable'
    printf '%s/%s\t%s\n' "$bp" "$bk" "$out"
    [ "$(rank $rc)" -gt "$(rank $rc_any)" ] && rc_any=$rc
  done < "$batch"
  [ $rows -gt 0 ] || { echo "no project/package rows in $batch" >&2; exit 2; }
  exit $rc_any
fi

[ -n "$prj" ] && [ -n "$pkg" ] || { usage; exit 2; }
out="$(check_one "$prj" "$pkg")"; rc=$?
if [ $rc -eq 5 ]; then
  if [ -n "$out" ]; then echo "UNREADABLE — ${out##*$'\t'}" >&2
  else echo "cannot read /source/$prj/$pkg/_meta, its project's or its Factory devel project (absent, auth, or network)" >&2; fi
  exit 5
fi
IFS=$'\t' read -r verdict revs others why <<<"$out"
case "$verdict" in
  ELIGIBLE)  echo "ELIGIBLE — $why, no reviewer role set (other maintainers: $others)";;
  BLOCKED)   echo "BLOCKED — explicit reviewer role: $revs — do NOT accept/forward unattended";;
  NOT_YOURS) echo "NOT_YOURS — $why (maintainers: $others)";;
  WRONG-DEVEL) echo "WRONG-DEVEL — $why: accept nothing in $prj, submit there";;
esac
exit $rc
