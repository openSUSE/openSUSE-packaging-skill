#!/bin/bash
# Answer "is <pkg> in Leap, at what version, and is an update ALREADY in
# flight?" in one call — implements the check-in-flight-Leap-PRs HARD RULE
# (open pool PRs count, not just shipped versions). Feeds the CVE-triage
# "Leap affected?" question (references/bugzilla-cve-triage.md §3) and the
# pre-sync check before scripts/leap-sync.sh.
#
# Data shown:
#   * pool/<pkg> branches (factory / leap-16.x / slfo-*) with each branch's
#     spec Version:
#   * open PRs on pool/<pkg>: number, target branch, author, title, head spec
#     Version:
#   * presence in SUSE:SLFO:1.2 and openSUSE:Backports:SLE-16.0 (osc), and in
#     products/PackageHub .gitmodules (what actually puts it in Leap)
#
# Usage: leap-status.sh <pkg>
# Exit codes:
#   0  in sync (every product branch at the factory version)
#   1  behind, NO open PR        -> actionable: scripts/leap-sync.sh <pkg> <branch>
#   2  behind, PR already open   -> do nothing (no double-filing); PR printed
#   3  not in Leap (factory-only branches) -> pool-maintainer onboarding, see
#      references/leap-slfo.md §4 (leap-sync.sh refuses this case)
#   5  network/API failure (NEVER reported as a fake in-sync)
#
# Public reads work unauthenticated; a token from ~/.config/tea/config.yml is
# used when present (rate limits).
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,28p' "$0"; exit 0;;
  '') sed -n '2,28p' "$0"; exit 2;;
esac
pkg="$1"
G="https://src.opensuse.org"
tok=$(python3 -c "import yaml,os;c=yaml.safe_load(open(os.path.expanduser('~/.config/tea/config.yml')));print([l['token'] for l in c['logins'] if l['name']=='src.opensuse.org'][0])" 2>/dev/null) || tok=""
auth=(); [ -n "$tok" ] && auth=(-H "Authorization: token $tok")

gget() { curl -fsS --max-time 20 "${auth[@]}" "$1"; }

# ---- 1. branches + per-branch spec version ----------------------------------
branches_json="$(gget "$G/api/v1/repos/pool/$pkg/branches")" \
  || { echo "ERROR: could not list pool/$pkg branches (network, or no pool repo)" >&2; exit 5; }
branches="$(printf '%s' "$branches_json" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(2)
for b in d: print(b.get("name",""))
')" || { echo "ERROR: unparseable branch list for pool/$pkg" >&2; exit 5; }

bver() {  # spec Version: on a branch
  # NB: the raw-file endpoint ($G/pool/$pkg/raw/branch/...) 403s for
  # unauthenticated callers, which used to make every branch read as empty and
  # the verdict below collapse to a bogus "IN-SYNC" (all versions equal ==
  # all empty). Use the REST contents endpoint instead: it answers without a
  # token, and an empty result now really does mean "could not determine".
  gget "$G/api/v1/repos/pool/$pkg/contents/$pkg.spec?ref=$1" 2>/dev/null \
    | python3 -c '
import sys, json, base64, re
try:
    raw = base64.b64decode(json.load(sys.stdin).get("content") or "").decode("utf-8", "replace")
except Exception:
    sys.exit(0)
m = re.search(r"^Version:\s*(\S+)", raw, re.M | re.I)
print(m.group(1) if m else "")
' 2>/dev/null
}

echo "== leap-status: $pkg =="
fver=""
declare -A ver
have_leapish=0
for b in factory leap-16.0 leap-16.1 slfo-1.2 slfo-main; do
  if printf '%s\n' "$branches" | grep -qx "$b"; then
    v="$(bver "$b")" || v=""
    ver[$b]="$v"
    [ "$b" = factory ] && fver="$v"
    case "$b" in leap-*|slfo-*) have_leapish=1;; esac
    printf '  branch %-10s Version: %s\n' "$b" "${v:-?}"
  fi
done
other="$(printf '%s\n' "$branches" | grep -vE '^(factory|leap-16\.[01]|slfo-(1\.2|main))$' || true)"
[ -n "$other" ] && echo "  (other branches: $(printf '%s' "$other" | tr '\n' ' '))"

# ---- 2. open PRs -------------------------------------------------------------
prs_json="$(gget "$G/api/v1/repos/pool/$pkg/pulls?state=open")" \
  || { echo "ERROR: could not list open PRs on pool/$pkg" >&2; exit 5; }
prs="$(printf '%s' "$prs_json" | PKG="$pkg" G="$G" python3 -c '
import sys, os, json, urllib.request, re
pkg, g = os.environ["PKG"], os.environ["G"]
try: d = json.load(sys.stdin)
except Exception: sys.exit(2)
for p in d:
    base = (p.get("base") or {}).get("ref", "?")
    head = p.get("head") or {}
    repo = (head.get("repo") or {}).get("full_name", "")
    ref = head.get("ref", "")
    hv = "?"
    if repo and ref:
        try:
            raw = urllib.request.urlopen(f"{g}/{repo}/raw/branch/{ref}/{pkg}.spec",
                                         timeout=20).read().decode(errors="replace")
            m = re.search(r"^Version:\s*(\S+)", raw, re.M | re.I)
            if m: hv = m.group(1)
        except Exception:
            pass
    user = (p.get("user") or {}).get("login", "?")
    num, title = p.get("number"), p.get("title")
    print(f"PR #{num} -> {base}  [{user}]  head-Version: {hv}  {title}")
')" || { echo "ERROR: unparseable PR list for pool/$pkg" >&2; exit 5; }
if [ -n "$prs" ]; then echo "open PR(s):"; printf '%s\n' "$prs" | sed 's/^/  /'; else echo "open PRs: none"; fi

# ---- 3. presence in the OBS-side feeds + PackageHub .gitmodules --------------
p_slfo="no"; timeout 30 osc api "/source/SUSE:SLFO:1.2/$pkg/_meta" >/dev/null 2>&1 && p_slfo="yes"
p_bp="no";   timeout 30 osc api "/source/openSUSE:Backports:SLE-16.0/$pkg/_meta" >/dev/null 2>&1 && p_bp="yes"
p_hub="no"
gm="$(curl -fsS --max-time 20 "$G/products/PackageHub/raw/branch/leap-16.0/.gitmodules" 2>/dev/null)" || gm=""
if [ -n "$gm" ] && printf '%s' "$gm" | grep -qE "^\[submodule \"$pkg\"\]|path = $pkg\$|url = \.\./\.\./pool/$pkg\$"; then p_hub="yes"; fi
echo "presence: SUSE:SLFO:1.2=$p_slfo  openSUSE:Backports:SLE-16.0=$p_bp  PackageHub .gitmodules(leap-16.0)=$p_hub"

# ---- verdict -------------------------------------------------------------------
if [ "$have_leapish" = 0 ]; then
  echo "VERDICT: NOT-IN-LEAP (factory-only branches) — needs pool-maintainer onboarding, see references/leap-slfo.md §4 (leap-sync.sh refuses this case)"
  exit 3
fi
# A version we could not read must NEVER be treated as "matches factory": the
# comparison below skips empty values, so an all-empty read used to collapse
# into a bogus IN-SYNC verdict and would silently talk you out of a sync that
# is actually needed (real case: cvise, factory 2.12.0 vs leap-16.1 2.10.0
# reported as IN-SYNC — the very drift that caused boo#1273590).
unknown=""
[ -n "$fver" ] || unknown="factory"
for b in leap-16.0 leap-16.1 slfo-1.2 slfo-main; do
  printf '%s\n' "$branches" | grep -qx "$b" || continue
  [ -n "${ver[$b]:-}" ] || unknown="$unknown $b"
done
if [ -n "$unknown" ]; then
  echo "VERDICT: UNKNOWN — could not read the spec Version on:$unknown (network, auth, or a renamed spec). Refusing to guess; check manually before syncing." >&2
  exit 2
fi
behind=""
for b in leap-16.0 leap-16.1 slfo-1.2 slfo-main; do
  v="${ver[$b]:-}"
  [ -n "$v" ] || continue
  [ -n "$fver" ] && [ "$v" != "$fver" ] && behind="$behind $b($v)"
done
if [ -z "$behind" ]; then
  echo "VERDICT: IN-SYNC (every product branch at factory's ${fver:-?}); note: same-version content drift is possible — leap-sync.sh compares trees"
  exit 0
fi
if [ -n "$prs" ]; then
  echo "VERDICT: BEHIND (${behind# }) but a PR is already open — do NOT double-file; watch the PR above"
  exit 2
fi
echo "VERDICT: BEHIND (${behind# }) with NO open PR — actionable: scripts/leap-sync.sh $pkg <branch>"
exit 1
