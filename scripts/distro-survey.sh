#!/bin/bash
# Survey how other distributions package <pkg> — the version on every distro
# (plus a patch-count hint for Fedora, whose dist-git tree is cheap to list)
# across Fedora, Debian, Gentoo, Arch, Alpine, openEuler, Void, NixOS, FreeBSD
# ports, OpenMandriva and Mageia, in ONE call.
# Implements the "survey other distros whenever you touch a package" hard rule
# (catch config options / patches / fixes / a newer-or-different upstream lineage
# we're missing). Best-effort: a distro that 404s or isn't packaged is shown as
# "-" rather than failing the whole run.
#
# Usage: distro-survey.sh <pkg> [factory-version]
#   factory-version (optional) is printed alongside for a quick lag comparison.
#
# Output: one line per distro: "<distro>  <version>  [notes]";
#         Fedora additionally shows "(N patches)" when its dist-git carries any.
set -u
case "${1:-}" in
  -h|--help) sed -n '2,15p' "$0"; exit 0;;
  '') sed -n '2,15p' "$0"; exit 2;;
esac
pkg="$1"
fac="${2:-}"
UA='openSUSE-distro-survey/1.0'
get() { curl -fsSL -A "$UA" --max-time 20 "$@" 2>/dev/null; }

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

printf '== distro survey: %s ==\n' "$pkg"
[ -n "$fac" ] && row 'Factory' "$fac"

# One Repology call up front — feeds Gentoo + the Repology-only distros below.
# Repology project name usually == srcname; best-effort, '-' on mismatch/absence.
REPOLOGY=$(get "https://repology.org/api/v1/project/$pkg")
rg() {
  printf '%s' "$REPOLOGY" | python3 -c '
import sys, json
pref = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("-"); sys.exit()
vs = sorted({p.get("version","") for p in d if p.get("repo","").startswith(pref) and p.get("version")})
print(vs[-1] if vs else "-")
' "$1"
}

# Fedora (rawhide spec + a patch-count hint from the dist-git tree listing)
fv=$(get "https://src.fedoraproject.org/rpms/$pkg/raw/rawhide/f/$pkg.spec" | grep -m1 -iE '^Version:' | awk '{print $2}')
fp=$(get "https://src.fedoraproject.org/api/0/rpms/$pkg/tree/rawhide" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
n = sum(1 for e in d.get("content", []) if e.get("name","").endswith(".patch"))
if n: print(f"({n} patches)")
' 2>/dev/null)
row 'Fedora' "${fv:-}" "${fp:-}"

# Debian (sources.debian.org API)
dv=$(get "https://sources.debian.org/api/src/$pkg/" | python3 -c "import sys,json;d=json.load(sys.stdin);vs=[v['version'] for v in d.get('versions',[])];print(vs[0] if vs else '-')" 2>/dev/null)
row 'Debian' "${dv:-}"

# Gentoo — from the already-fetched Repology payload (a gitweb category scrape
# would have to guess the category and misses dev-python/net-libs/…)
row 'Gentoo' "$(rg gentoo)"

# Arch (official repos)
av=$(get "https://archlinux.org/packages/search/json/?name=$pkg" | python3 -c "import sys,json;r=json.load(sys.stdin).get('results',[]);print(r[0]['pkgver'] if r else '-')" 2>/dev/null)
row 'Arch' "${av:-}"

# Alpine (aports APKBUILD on edge, common repos)
alv='-'
for repo in main community testing; do
  v=$(get "https://gitlab.alpinelinux.org/alpine/aports/-/raw/master/$repo/$pkg/APKBUILD" | grep -m1 -E '^pkgver=' | cut -d= -f2)
  [ -n "$v" ] && { alv="$v ($repo)"; break; }
done
row 'Alpine' "$alv"

# openEuler (src-openeuler spec on gitee)
ov=$(get "https://gitee.com/src-openeuler/$pkg/raw/master/$pkg.spec" | grep -m1 -iE '^Version:' | awk '{print $2}')
row 'openEuler' "${ov:-}"

# Void Linux (void-packages template — reliable, version=<v>)
vv=$(get "https://raw.githubusercontent.com/void-linux/void-packages/master/srcpkgs/$pkg/template" | grep -m1 -E '^version=' | cut -d= -f2)
row 'Void' "${vv:-}"

# NixOS / FreeBSD ports / OpenMandriva / Mageia — from the same Repology payload.
row 'NixOS'       "$(rg nix)"
row 'FreeBSD'     "$(rg freebsd)"
row 'OpenMandr.'  "$(rg openmandriva)"
row 'Mageia'      "$(rg mageia)"

echo "(divergence → a newer version, a different upstream lineage, or a patch worth pulling; inspect the laggard-vs-leader spec/patches directly.)"
