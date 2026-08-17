#!/bin/bash
# Survey how other distributions package <pkg> — the version on every distro
# (plus a patch-count hint for Fedora, whose dist-git tree is cheap to list)
# across Fedora, Debian, Gentoo, Arch, Alpine, openEuler, Void, NixOS, FreeBSD
# ports, OpenMandriva and Mageia, in ONE call.
# Implements the "survey other distros whenever you touch a package" hard rule
# (catch config options / patches / fixes / a newer-or-different upstream lineage
# we're missing). Best-effort: a distro that 404s or isn't packaged is shown as
# "-" rather than failing the whole run; a backend we could not REACH is shown
# as "?" — "not packaged" and "not answered" are different facts, and printing
# the second as the first is how this script used to invent false negatives.
#
# Usage: distro-survey.sh <pkg> [factory-version]
#   factory-version (optional) is printed alongside for a quick lag comparison.
#   DISTRO_SURVEY_BUDGET=90   whole-run seconds; past it, rows show '?'
#   DISTRO_SURVEY_TIMEOUT=10  per-request seconds
#
# Output: one line per distro: "<distro>  <version>  [notes]";
#         Fedora additionally shows "(N patches)" when its dist-git carries any.
#         Rows are indented by two spaces; un-indented "(...)" lines are notes,
#         including the Repology name-resolution note (the openSUSE name is not
#         always Repology's project slug — 'thrift' is 'apache-thrift' there).
#         Debian reports its sid version (versions[0] is experimental); a suite
#         in parentheses means the package is NOT in sid under that name.
set -u
case "${1:-}" in
  -h|--help) sed -n '2,24p' "$0"; exit 0;;
  '') sed -n '2,24p' "$0"; exit 2;;
esac
pkg="$1"
fac="${2:-}"
UA='openSUSE-distro-survey/1.0'

# Whole-run time budget. Twelve backends x a 20s per-call timeout used to add up
# to ~283s in the worst case (a healthy run is ~10s), so cap the run and cap each
# call at whatever is left, never more than PERCALL. When the budget is gone we
# stop fetching and every remaining backend renders '?' — an unanswered backend
# is not a "not packaged".
BUDGET=${DISTRO_SURVEY_BUDGET:-90}
PERCALL=${DISTRO_SURVEY_TIMEOUT:-10}
DEADLINE=$((SECONDS + BUDGET))
BUDGETNOTE=''

# get() must NOT be used inside $(...): the HTTP status has to survive the call,
# and a command substitution runs it in a subshell that throws the assignment
# away. That is exactly how the old `curl -fsSL ... 2>/dev/null | parser` shape
# lost the status: -f blanks the body on an HTTP error, stderr is discarded, and
# the pipeline's exit code is the parser's (always 0). Body lands in GBODY, code
# in GCODE — same discipline as rget() below.
GBODY=''; GCODE=''
get() {
  local out left
  left=$((DEADLINE - SECONDS))
  if [ "$left" -le 0 ]; then
    GBODY=''; GCODE=000
    [ -n "$BUDGETNOTE" ] || { BUDGETNOTE=1
      note "time budget (${BUDGET}s) exhausted — the remaining backends show '?', not '-'"; }
    return 0
  fi
  [ "$left" -gt "$PERCALL" ] && left=$PERCALL
  out=$(curl -sSL -A "$UA" --connect-timeout 5 --max-time "$left" -w '\n%{http_code}' "$@" 2>/dev/null)
  GCODE=${out##*$'\n'}
  GBODY=''
  [ "$GCODE" = 200 ] && GBODY=${out%$'\n'*}
  return 0
}
# Did the backend actually ANSWER? 200 = yes; 404/400 = yes, "no such package".
# Anything else (000 DNS failure/timeout, 429, 5xx) means we never learned
# anything and must not be rendered as a negative.
answered() { case "${1:-$GCODE}" in 200|400|404) return 0;; *) return 1;; esac; }
# The placeholder to use when a parse came back empty: '-' not packaged / '?'
# unknown. Same convention as the Repology path's rg().
gmark() { if answered; then printf -- '-'; else printf '?'; fi; }

# Every version/note field below is text fetched from another distro's
# infrastructure — sanitize before display (see scripts/_sanitize.py).
SDIR="$(cd "$(dirname "$0")" && pwd)"
# Falls back to the RAW text on helper failure — an empty cell would be a
# silent false-clean (see the sanitize() helpers in preflight/build-summary).
row() {
  local clean
  if ! clean=$(printf '%s' "${2:--}${3:+ $3}" | python3 "$SDIR/_sanitize.py" 2>/dev/null); then
    echo "WARNING: $SDIR/_sanitize.py unavailable — printing UNSANITIZED third-party text" >&2
    clean="${2:--}${3:+ $3}"
  fi
  printf '  %-10s %s\n' "$1" "$clean"
}
# Same sanitizing path, for the un-indented "(...)" notes (Repology candidate
# names are third-party text too). Un-indented is what tells a parser a note
# from a row.
note() {
  local clean
  if ! clean=$(printf '%s' "$1" | python3 "$SDIR/_sanitize.py" 2>/dev/null); then
    echo "WARNING: $SDIR/_sanitize.py unavailable — printing UNSANITIZED third-party text" >&2
    clean="$1"
  fi
  printf '(%s)\n' "$clean"
}

printf '== distro survey: %s ==\n' "$pkg"

# One Repology payload up front — feeds Gentoo + the Repology-only distros below.
# Repology's project slug is NOT always the openSUSE package name ('thrift' is
# 'apache-thrift' there, 'python-requests' is 'python:requests'), so a direct
# miss must not be reported as "nobody packages this". On a miss we ask
# tools/project-by, Repology's own name-resolution endpoint: it 302s from a
# distro's src/bin package name to that project, and get()'s -L follows the
# redirect straight to the resolved project's API payload.
# Four outcomes, deliberately kept apart:
#   ok      REPOLOGY holds the payload            -> real versions (or '-')
#   absent  Repology knows no such project at all -> '-'  (not packaged)
#   unres   similar projects exist, name unmapped -> '?'  (do NOT trust as '-')
#   down    unreachable / rate-limited (429)      -> '?'
# curl -f would hide the status code, and 404 (no such project) must never look
# like 429 or a timeout, so ask for the code explicitly and fail soft. Body
# lands in RBODY, not stdout: a $(...) capture would run the assignment to
# rcode in a subshell and throw the status away.
RBODY=''; rcode=''; rurl=''
rget() {
  local out tail left
  left=$((DEADLINE - SECONDS))
  if [ "$left" -le 0 ]; then RBODY=''; rcode=000; rurl=''; return 0; fi
  [ "$left" -gt "$PERCALL" ] && left=$PERCALL
  out=$(curl -sSL -A "$UA" --connect-timeout 5 --max-time "$left" -G -w '\n%{http_code} %{url_effective}' "$@" 2>/dev/null)
  tail=${out##*$'\n'}
  rcode=${tail%% *}; rurl=${tail#* }
  RBODY=''
  [ "$rcode" = 200 ] && RBODY=${out%$'\n'*}
  return 0
}
RSTATE=ok
rget "https://repology.org/api/v1/project/$pkg"
REPOLOGY="$RBODY"
if [ "$rcode" != 200 ]; then
  RSTATE=down
  note "repology: unreachable (HTTP $rcode) — its rows show '?', not '-'"
elif [ -z "$REPOLOGY" ] || [ "$REPOLOGY" = '[]' ]; then
  RSTATE=absent
  for nt in srcname binname; do
    sleep 1   # Repology answers bursts with 429; ~1 call/s stays under it
    rget "https://repology.org/tools/project-by" \
         -d repo=opensuse_tumbleweed -d "name_type=$nt" \
         -d target_page=api_v1_project --data-urlencode "name=$pkg"
    case "$rcode" in
      200) if [ -n "$RBODY" ] && [ "$RBODY" != '[]' ]; then
             REPOLOGY="$RBODY"; RSTATE=ok
             # %{url_effective} is the redirect target, so its last path
             # segment is the resolved slug (percent-encoded: python%3Arequests).
             rname=$(printf '%s' "${rurl##*/}" | python3 -c \
               'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null)
             note "repology: '$pkg' resolved via tools/project-by ($nt) to project '${rname:-${rurl##*/}}'"
             break
           fi;;
      404) ;;                     # this name type has no match — try the next
      *)   RSTATE=down
           note "repology: name resolution unreachable (HTTP $rcode) — its rows show '?', not '-'"
           break;;
    esac
  done
  if [ "$RSTATE" = absent ]; then
    # Neither the slug nor either openSUSE name matched. Before calling it
    # "not packaged", check whether Repology knows anything by that substring:
    # if it does, the project exists under a name we failed to map, which is a
    # different (and much less trustworthy) answer than "nobody ships it".
    sleep 1
    rget "https://repology.org/api/v1/projects/" --data-urlencode "search=$pkg"
    cand=$(printf '%s' "$RBODY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
print(", ".join(sorted(d)[:5]))
' 2>/dev/null)
    if [ "$rcode" != 200 ]; then
      RSTATE=down
      note "repology: unreachable (HTTP $rcode) — its rows show '?', not '-'"
    elif [ -n "$cand" ]; then
      RSTATE=unres
      note "repology: could not resolve '$pkg' to a project; similar names: $cand — its rows show '?' (UNKNOWN), not '-'"
    else
      note "repology: no project matches '$pkg' — not packaged in any Repology-tracked distro"
    fi
  fi
fi
rg() {
  case "$RSTATE" in
    ok)     ;;
    absent) printf -- '-\n'; return;;
    *)      printf '?\n'; return;;   # unresolved / unreachable — not a '-'
  esac
  # A repo prefix can cover several branches (nix_stable_24_05 … nix_unstable),
  # so pick the NEWEST, and a plain string sort does not do that: it made curl
  # "8.7.1" beat "8.21.0" on NixOS and let Gentoo's live-git ebuild "9999" win
  # outright. Compare component-wise with numbers as numbers, and drop the 9999
  # live-ebuild sentinels — a placeholder, not a release. Those are not only
  # bare "9999": Gentoo also carries per-slot live ebuilds like gcc-15.3.9999
  # and gcc-17.0.9999, so drop any version with a 9999 component as well as
  # everything Repology itself flags status=rolling (that status exists exactly
  # for 9999/git/HEAD packages and is excluded from its own newest calculation).
  printf '%s' "$REPOLOGY" | python3 -c '
import sys, json, re
pref = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("-"); sys.exit()
def split(v):
    return re.split(r"[._\-+~]", v)
def vkey(v):
    return [(0, int(x)) if x.isdigit() else (1, x) for x in split(v)]
def live(v):
    return v.startswith("9999") or any(x == "9999" for x in split(v))
vs = {p["version"] for p in d
      if p.get("repo", "").startswith(pref) and p.get("version")
      and p.get("status") != "rolling" and not live(p["version"])}
print(max(vs, key=vkey) if vs else "-")
' "$1"
}

[ -n "$fac" ] && row 'Factory' "$fac"

# Fedora — mdapi first (rawhide's *resolved* repodata), then the rawhide spec as
# a fallback, plus a patch-count hint from the dist-git tree listing.
# The spec grep alone returned literal macros for a large share of packages
# (gcc -> %{gcc_version}, llvm -> %{maj_ver}.%{min_ver}.%{patch_ver}, vim ->
# %{baseversion}.%{patchlevel}); mdapi hands back the expanded Version. A spec
# value is only accepted when it still contains no '%'. mdapi answers 400 for an
# unknown source package, which is an answer, not an outage.
fnote=''
get "https://mdapi.fedoraproject.org/rawhide/srcpkg/$pkg"
fcode=$GCODE
fv=$(printf '%s' "$GBODY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
print(d.get("version") or "")
' 2>/dev/null)
if [ -z "$fv" ]; then
  get "https://src.fedoraproject.org/rpms/$pkg/raw/rawhide/f/$pkg.spec"
  fv=$(printf '%s' "$GBODY" | grep -m1 -iE '^Version:' | awk '{print $2}')
  case "$fv" in
    *%*) fnote="(rawhide spec says '$fv' — unexpanded macro; mdapi gave no version, HTTP $fcode)"; fv='?';;
    '')  if answered "$fcode" || answered; then fv='-'; else fv='?'; fi;;
  esac
fi
get "https://src.fedoraproject.org/api/0/rpms/$pkg/tree/rawhide"
fp=$(printf '%s' "$GBODY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
n = sum(1 for e in d.get("content", []) if e.get("name","").endswith(".patch"))
if n: print(f"({n} patches)")
' 2>/dev/null)
# Printing nothing here used to be read as "Fedora carries zero patches" even
# when the listing never loaded. Say so instead.
if [ -z "$fp" ] && ! answered; then fp="(patch count unknown — dist-git listing unreachable, HTTP $GCODE)"; fi
row 'Fedora' "$fv" "${fp}${fp:+${fnote:+ }}${fnote}"

# Debian (sources.debian.org API). versions[0] is whatever suite sorts first,
# which is always experimental when one exists — that reported thrift 0.24.0-1
# while sid actually carries 0.23.0-3. Prefer sid; if the package is only in
# other suites, fall back to the first entry and NAME the suite.
get "https://sources.debian.org/api/src/$pkg/"
dv=$(printf '%s' "$GBODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
vs = d.get('versions', [])
s = [v for v in vs if 'sid' in v.get('suites', [])] or vs
if s:
    v = s[0]
    su = v.get('suites', [])
    print(v.get('version', '') + ('' if 'sid' in su else ' (%s)' % (', '.join(su) or 'suite?')))
" 2>/dev/null)
[ -z "$dv" ] && dv=$(gmark)
row 'Debian' "$dv"

# Gentoo — from the already-fetched Repology payload (a gitweb category scrape
# would have to guess the category and misses dev-python/net-libs/…)
row 'Gentoo' "$(rg gentoo)"

# Arch (official repos). Unlike the others Arch says "no such package" with a
# 200 and an empty results list, so an empty list is a real '-' — only a failed
# fetch (which leaves the parse with nothing to chew on) becomes '?'.
get "https://archlinux.org/packages/search/json/?name=$pkg"
av=$(printf '%s' "$GBODY" | python3 -c "import sys,json;r=json.load(sys.stdin).get('results',[]);print(r[0]['pkgver'] if r else '-')" 2>/dev/null)
[ -z "$av" ] && av=$(gmark)
row 'Arch' "$av"

# Alpine (aports APKBUILD on edge, common repos).
# NOT gitlab.alpinelinux.org: it now answers unauthenticated fetches with a
# "go-away" anti-bot interstitial instead of the raw file, so every lookup came
# back empty and every package looked unpackaged. The GitHub mirror of aports
# serves the same master branch as plain text.
# A miss is only a '-' if all three repos actually answered 404; one unanswered
# repo means we cannot claim the package is absent from Alpine.
alv=''; albad=''
for repo in main community testing; do
  get "https://raw.githubusercontent.com/alpinelinux/aports/master/$repo/$pkg/APKBUILD"
  answered || albad=$GCODE
  v=$(printf '%s' "$GBODY" | grep -m1 -E '^pkgver=' | cut -d= -f2)
  [ -n "$v" ] && { alv="$v ($repo)"; break; }
done
[ -n "$alv" ] || { [ -n "$albad" ] && alv='?' || alv='-'; }
row 'Alpine' "$alv"

# openEuler (src-openeuler spec on gitee). Same unexpanded-macro problem as
# Fedora's raw spec, and openEuler publishes no resolved-metadata API to fall
# back to — so say we do not know rather than print '%{anolis_release}' as if
# it were a version.
get "https://gitee.com/src-openeuler/$pkg/raw/master/$pkg.spec"
ov=$(printf '%s' "$GBODY" | grep -m1 -iE '^Version:' | awk '{print $2}')
onote=''
case "$ov" in
  *%*) onote="(spec says '$ov' — unexpanded macro, no resolved-metadata API for openEuler)"; ov='?';;
  '')  ov=$(gmark);;
esac
row 'openEuler' "$ov" "$onote"

# Void Linux (void-packages template — reliable, version=<v>)
get "https://raw.githubusercontent.com/void-linux/void-packages/master/srcpkgs/$pkg/template"
vv=$(printf '%s' "$GBODY" | grep -m1 -E '^version=' | cut -d= -f2)
[ -z "$vv" ] && vv=$(gmark)
row 'Void' "$vv"

# NixOS / FreeBSD ports / OpenMandriva / Mageia — from the same Repology payload.
row 'NixOS'       "$(rg nix)"
row 'FreeBSD'     "$(rg freebsd)"
row 'OpenMandr.'  "$(rg openmandriva)"
row 'Mageia'      "$(rg mageia)"

echo "(divergence → a newer version, a different upstream lineage, or a patch worth pulling; inspect the laggard-vs-leader spec/patches directly.)"
