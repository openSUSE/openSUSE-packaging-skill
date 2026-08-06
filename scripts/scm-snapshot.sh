#!/bin/bash
# Scaffold + verify a pinned-commit obs_scm _service for a TAGLESS upstream
# (no tags, no releases, not on PyPI — the NVIDIA/skillspector case), producing
# the X.Y.Z~gitYYYYMMDD.shorthash snapshot version REPRODUCIBLY: the revision
# is pinned to a full commit sha and the snapshot date derives from the COMMIT
# date (%cd), not the run date.
#
# Usage: scm-snapshot.sh <git-url> [--rev <sha|branch>] [--base X.Y.Z]
#                        [--pkg NAME] [--update]
#   --rev     commit-ish to pin (default: the remote HEAD)
#   --base    version base for '<base>~git%cd.%h' (default: 0)
#   --pkg     package name (default: url basename without .git)
#   --update  re-pin an EXISTING _service in the cwd to the newer commit and
#             enforce the "verify it actually moved" checks from
#             references/update-build.md: .obsinfo version advanced,
#             _servicedata changesrevision advanced, new top-dir name
#
# Behavior: resolves the rev to a FULL sha (git ls-remote), writes/updates the
# _service XML (obs_scm, revision=<full sha>, versionformat <base>~git%cd.%h,
# exclude .git*), runs `osc service mr` (the scaffolded service is mode="manual";
# never `runall`, which is mode-blind) inside an .osc checkout or falls
# back to the direct `/usr/lib/obs/service/obs_scm --outdir` invocation in a
# plain git-pool checkout (see references/leap-slfo.md), then parses the
# produced .obsinfo and prints:
#   version=<X.Y.Z~gitYYYYMMDD.hash> commit=<full sha> obsinfo=OK|MISMATCH
# plus the ready-to-paste '- Update to X.Y.Z~git...' changelog line.
# Exits non-zero on any mismatch/verification failure.
set -euo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,27p' "$0"; exit 0;;
  '') sed -n '2,27p' "$0"; exit 2;;
esac

url="" ; rev="" ; base="0" ; pkg="" ; update=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rev) rev="$2"; shift 2;;
    --base) base="$2"; shift 2;;
    --pkg) pkg="$2"; shift 2;;
    --update) update=1; shift;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) if [ -z "$url" ]; then url="$1"; else echo "unexpected arg: $1" >&2; exit 2; fi; shift;;
  esac
done

if [ "$update" = 1 ] && [ -f _service ]; then
  # inherit url/base/pkg from the existing service unless overridden
  read -r s_url s_vf s_oldrev <<<"$(python3 -c '
import xml.etree.ElementTree as ET
r = ET.parse("_service").getroot()
for s in r.findall("service"):
    if s.get("name") == "obs_scm":
        p = {e.get("name"): (e.text or "") for e in s.findall("param")}
        print(p.get("url",""), p.get("versionformat",""), p.get("revision",""))
        break
')"
  [ -n "$s_url" ] || { echo "no obs_scm service in ./_service" >&2; exit 2; }
  [ -n "$url" ] || url="$s_url"
  [ "$base" != "0" ] || base="${s_vf%%~git*}"
elif [ "$update" = 1 ]; then
  echo "--update needs an existing ./_service" >&2; exit 2
fi
[ -n "$url" ] || { echo "need a git url" >&2; exit 2; }
[ -n "$pkg" ] || { pkg="$(basename "$url")"; pkg="${pkg%.git}"; }

# ---- 1. resolve the rev to a FULL sha ----------------------------------------
ref="${rev:-HEAD}"
line="$(timeout 30 git ls-remote "$url" "$ref" | head -1)" \
  || { echo "git ls-remote $url failed (network?)" >&2; exit 2; }
sha="$(printf '%s' "$line" | awk '{print $1}')"
if [ -z "$sha" ] && printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
  sha="$ref"   # a full sha isn't listable via ls-remote; trust it as given
fi
[ -n "$sha" ] || { echo "could not resolve '$ref' on $url" >&2; exit 2; }
echo "pin: $url @ $sha"

# snapshot the pre-run state for the --update "did it move?" checks
old_obsinfo_ver=""; old_changesrev=""; old_obscpio=""
if [ "$update" = 1 ]; then
  old_obsinfo_ver="$(grep -h '^version:' ./*.obsinfo 2>/dev/null | head -1 | awk '{print $2}')" || true
  old_changesrev="$(grep -oE '<param name="changesrevision">[^<]+' _servicedata 2>/dev/null | sed 's/.*>//')" || true
  old_obscpio="$(ls -1 ./*.obscpio 2>/dev/null | head -1)" || true
  [ -n "$s_oldrev" ] && [ "$s_oldrev" = "$sha" ] && { echo "already pinned to $sha — nothing to do"; exit 0; }
fi

# ---- 2. write/update the _service --------------------------------------------
vf="${base}~git%cd.%h"
[ -f _service ] && [ "$update" = 0 ] && { cp _service _service.bak; echo "(existing _service backed up to _service.bak)"; }
cat > _service <<EOF
<services>
  <service name="obs_scm" mode="manual">
    <param name="url">$url</param>
    <param name="scm">git</param>
    <param name="revision">$sha</param>
    <param name="versionformat">$vf</param>
    <param name="exclude">.git*</param>
    <param name="filename">$pkg</param>
  </service>
</services>
EOF
echo "_service written (obs_scm, pinned revision, versionformat $vf)"

# ---- 3. run the service -------------------------------------------------------
if [ -d .osc ]; then
  # the _service written above is mode="manual" -> manualrun, NOT runall
  osc service manualrun || { echo "osc service manualrun failed" >&2; exit 2; }
else
  # plain (git-pool / scratch) checkout: run the service binary directly
  svc=/usr/lib/obs/service/obs_scm
  [ -x "$svc" ] || { echo "$svc not available (install obs-service-obs_scm) and no .osc checkout" >&2; exit 2; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  "$svc" --url "$url" --scm git --revision "$sha" --versionformat "$vf" \
         --exclude '.git*' --filename "$pkg" --outdir "$tmp" \
    || { echo "obs_scm run failed" >&2; exit 2; }
  cp "$tmp"/*.obscpio "$tmp"/*.obsinfo . 2>/dev/null \
    || { echo "obs_scm produced no obscpio/obsinfo in $tmp" >&2; exit 2; }
fi

# ---- 4. parse + verify the .obsinfo -------------------------------------------
obsinfo="$(ls -1t ./*.obsinfo 2>/dev/null | head -1)"
[ -n "$obsinfo" ] || { echo "no .obsinfo produced" >&2; exit 2; }
ver="$(grep -m1 '^version:' "$obsinfo" | awk '{print $2}')"
commit="$(grep -m1 '^commit:' "$obsinfo" | awk '{print $2}')"
ok=OK
[ "$commit" = "$sha" ] || ok=MISMATCH
echo "version=$ver commit=$commit obsinfo=$ok"
[ "$ok" = OK ] || { echo "obsinfo commit does not match the pinned sha!" >&2; exit 1; }

# ---- 5. --update: verify it actually moved -------------------------------------
if [ "$update" = 1 ]; then
  fail=0
  if [ -n "$old_obsinfo_ver" ] && [ "$ver" = "$old_obsinfo_ver" ]; then
    echo "VERIFY FAILED: .obsinfo version did not advance ($ver)" >&2; fail=1
  fi
  new_changesrev="$(grep -oE '<param name="changesrevision">[^<]+' _servicedata 2>/dev/null | sed 's/.*>//')" || true
  if [ -n "$old_changesrev" ]; then
    if [ "$new_changesrev" = "$old_changesrev" ]; then
      echo "VERIFY FAILED: _servicedata changesrevision did not advance ($old_changesrev)" >&2; fail=1
    fi
  elif [ ! -f _servicedata ]; then
    echo "(no _servicedata — changesrevision check skipped; changesgenerate not enabled)"
  fi
  new_obscpio="$(ls -1t ./*.obscpio 2>/dev/null | head -1)"
  if [ -n "$old_obscpio" ] && [ "$new_obscpio" = "$old_obscpio" ]; then
    echo "VERIFY FAILED: obscpio name (top-dir) did not change ($old_obscpio)" >&2; fail=1
  fi
  [ "$fail" = 0 ] || exit 1
  echo "verified: version advanced, sources moved"
  [ -n "$old_obscpio" ] && [ -f "$old_obscpio" ] && echo "(remember: osc rm $old_obscpio ; osc add $new_obscpio)"
fi

echo
echo "ready-to-paste changelog line:"
echo "- Update to $ver:"
