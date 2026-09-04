#!/bin/bash
# Block-2 pre-flight (HARD RULE): is this update already done or in flight?
# Run BEFORE any osc branch / spec edit / build. Mechanizes the check from
# references/update-build.md "Pre-flight" — born from the python-ruff/uv case
# (SRs 1362328/1362488 discovered only AFTER two heavy Rust builds were wasted).
#
# Checks, against the package's devel project:
#   1. devel spec Version: + top .changes header (is the target version there?)
#   2. incoming SRs (someone's home:...:branches -> devel staging the bump)
#   3. outgoing devel -> Factory SRs (the one that lands the update)
#   4. for a git/scmsync devel project: open PRs on the devel Gitea repo
#      (MANDATORY — an in-flight update there is a PR, not an SR; an osc-only
#      check gives a false PROCEED)
#   5. a `reviewer` role (package or project _meta) held by someone OTHER than
#      you -> prints a REVIEWER ROLE notice. That person asked to see changes
#      before they land, so the update must go as a BRANCH + SR to the devel
#      project, never a direct commit, and you must not accept your own SR --
#      maintainer rights are not permission to bypass their gate.
#
# Usage: preflight.sh <pkg> [target-version] [--target-project PRJ] [--user U]
#   target-version    the version you intend to package (optional; without it
#                     the devel-vs-Factory version delta drives the verdict)
#   --target-project  default openSUSE:Factory
#   --user            OBS account (default: `osc whois`)
#
# Verdict line + exit code:
#   0  VERDICT: PROCEED            (also for a brand-new package, with a note)
#   3  VERDICT: STOP     — update already in flight (prints the SR id / PR #), or
#      nothing to do because devel and the target project already carry the same
#      version (the update landed; forwarding it would file an empty SR)
#   4  VERDICT: FORWARD  — stranded devel update: devel is ahead but no Factory
#      SR was ever filed (openmopac/pspg case); prints the exact osc sr command
#   2  a check FAILED (network/auth) — a failed check must NEVER print PROCEED
set -uo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,33p' "$0"; exit 0;;
  '') sed -n '2,33p' "$0"; exit 2;;
esac

pkg="" ; targetver="" ; target="openSUSE:Factory" ; user=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target-project) target="$2"; shift 2;;
    --user) user="$2"; shift 2;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) if [ -z "$pkg" ]; then pkg="$1"; elif [ -z "$targetver" ]; then targetver="$1";
       else echo "unexpected arg: $1" >&2; exit 2; fi; shift;;
  esac
done
[ -n "$pkg" ] || { sed -n '2,29p' "$0"; exit 2; }
[ -n "$user" ] || user="$(timeout 30 osc whois 2>/dev/null | sed 's/:.*//')" || true

fail() { echo "CHECK FAILED: $*" >&2; echo "VERDICT: CHECK-FAILED (fix and re-run — this is NOT a PROCEED)"; exit 2; }

# Third-party text (foreign .changes entries, PR titles, spec fields) is
# sanitized before display — see scripts/_sanitize.py. Always capture the
# producer's output/rc FIRST and sanitize the captured text: this filter must
# never sit in a pipeline whose exit status is a verdict.
SDIR="$(cd "$(dirname "$0")" && pwd)"
# On helper failure fall back to the RAW text with a loud stderr warning —
# an empty result would be a silent false-clean (foreign text vanishing).
sanitize() {
  local out
  if out=$(printf '%s' "$1" | python3 "$SDIR/_sanitize.py" 2>/dev/null); then
    printf '%s' "$out"
  else
    echo "WARNING: $SDIR/_sanitize.py unavailable — printing UNSANITIZED third-party text" >&2
    printf '%s' "$1"
  fi
}

# osc wrapper distinguishing 404 (fact) from other failures (fatal).
# Sets: O_OUT (stdout), O_404 (0/1). Returns 0 on success or 404, 1 otherwise.
oapi() {
  local err rc
  O_OUT="$(timeout 30 osc api "$1" 2>/tmp/preflight.$$.err)"; rc=$?
  err="$(cat /tmp/preflight.$$.err 2>/dev/null || true)"; rm -f /tmp/preflight.$$.err
  O_404=0
  if [ $rc -ne 0 ]; then
    if printf '%s' "$err" | grep -q "404"; then O_404=1; O_OUT=""; return 0; fi
    echo "$err" >&2; return 1
  fi
  return 0
}

# ---- 1. resolve the devel project (devel-of.sh logic inline) ----------------
devel="$(timeout 30 osc develproject "$target" "$pkg" 2>/dev/null | head -1 | cut -d/ -f1)" || devel=""
newpkg=0
if [ -z "$devel" ]; then
  oapi "/source/$target/$pkg/_meta" || fail "could not probe $target/$pkg/_meta"
  if [ "$O_404" = 1 ]; then
    echo "package:        $pkg — NOT in $target (new package)"
    newpkg=1
  else
    echo "package:        $pkg — in $target but no devel project set"
  fi
else
  echo "devel project:  $devel"
fi

# ---- 2. versions: devel spec + top .changes header, target-project spec -----
develver=""
if [ -n "$devel" ]; then
  oapi "/source/$devel/$pkg/$pkg.spec" || fail "could not read $devel/$pkg/$pkg.spec"
  if [ "$O_404" = 1 ]; then
    echo "devel spec:     (no $pkg.spec — link/multi-spec package? verify by hand)"
  else
    develver="$(sanitize "$(printf '%s\n' "$O_OUT" | grep -m1 -iE '^Version:' | awk '{print $2}')")"
    echo "devel Version:  ${develver:-?}"
  fi
  oapi "/source/$devel/$pkg/$pkg.changes" || fail "could not read $devel/$pkg/$pkg.changes"
  # foreign-authored prose block -> sanitized AND delimited
  [ "$O_404" = 0 ] && { echo "devel .changes top entry:"; printf '%s\n' "$O_OUT" | sed -n '1,4p' | python3 "$SDIR/_sanitize.py" --delimit | sed 's/^/    /'; }
  # A reviewer role held by someone else means SUBMIT, never commit directly:
  # that person asked to see changes before they land, and a direct commit
  # bypasses the gate even where maintainer rights would allow it.
  reviewers=""
  for meta in "/source/$devel/$pkg/_meta" "/source/$devel/_meta"; do
    oapi "$meta" || continue
    [ "$O_404" = 0 ] || continue
    reviewers="$reviewers$(printf '%s\n' "$O_OUT" \
      | grep -oE '<(person|group) [^>]*role="reviewer"[^>]*/?>' \
      | grep -oE '(userid|groupid)="[^"]*"' | cut -d'"' -f2)
"
  done
  reviewers="$(printf '%s\n' "$reviewers" | grep -vx "${user:-__none__}" | grep -v '^$' | sort -u | tr '\n' ' ')"
  if [ -n "$reviewers" ]; then
    echo "REVIEWER ROLE:  $reviewers— do NOT commit to $devel directly."
    echo "                Branch, then: osc sr <branch-prj> $pkg $devel"
    echo "                and leave the accept to them (see references/submit-watch.md)."
  fi
fi
targetprjver=""
if [ "$newpkg" = 0 ]; then
  oapi "/source/$target/$pkg/$pkg.spec" || fail "could not read $target/$pkg/$pkg.spec"
  [ "$O_404" = 0 ] && targetprjver="$(sanitize "$(printf '%s\n' "$O_OUT" | grep -m1 -iE '^Version:' | awk '{print $2}')")"
  echo "$target Version: ${targetprjver:-?}"
fi

# ---- 3+4. SRs in flight, both directions ------------------------------------
parse_srs() { # stdin: request collection XML; args: filter-source-project (optional)
  python3 -c '
import sys, xml.etree.ElementTree as ET
flt = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    root = ET.fromstring(sys.stdin.read() or "<collection/>")
except ET.ParseError:
    sys.exit(2)
for r in root.findall("request"):
    a = r.find("action"); s = a.find("source") if a is not None else None
    t = a.find("target") if a is not None else None
    st = r.find("state")
    sp = s.get("project") if s is not None else "?"
    if flt and sp != flt: continue
    sname = st.get("name") if st is not None else "?"
    spkg = s.get("package") if s is not None else "?"
    tprj = t.get("project") if t is not None else "?"
    rid = r.get("id")
    print(f"SR {rid} [{sname}] {sp}/{spkg} -> {tprj}")
' "$@"
}

incoming=""
if [ -n "$devel" ]; then
  oapi "/request?view=collection&types=submit&states=new,review&project=$devel&package=$pkg" \
    || fail "could not query incoming SRs for $devel/$pkg"
  incoming="$(printf '%s' "$O_OUT" | parse_srs)" || fail "unparseable SR collection (incoming)"
fi
oapi "/request?view=collection&types=submit&states=new,review&project=$target&package=$pkg" \
  || fail "could not query $target SRs for $pkg"
outgoing="$(printf '%s' "$O_OUT" | parse_srs "${devel:-}")" || fail "unparseable SR collection (outgoing)"

# A DECLINED request is terminal but NOT gone: `osc sr` still refuses with
# "already open: <id>" until it is revoked or superseded. Querying only
# new,review reports "outgoing SRs: none" and the submit then fails at the end
# of the work (picsart-gen-ai 2026-09-04, stale declined 1375013).
oapi "/request?view=collection&types=submit&states=declined&project=$target&package=$pkg" \
  || fail "could not query declined $target SRs for $pkg"
declined="$(printf '%s' "$O_OUT" | parse_srs "${devel:-}")" || fail "unparseable SR collection (declined)"

[ -n "$incoming" ] && { echo "incoming SR(s) at $devel (a maintainer staging the bump — already handled):"; printf '%s\n' "$incoming" | sed 's/^/    /'; } \
                   || echo "incoming SRs:   none"
[ -n "$outgoing" ] && { echo "outgoing devel->$target SR(s):"; printf '%s\n' "$outgoing" | sed 's/^/    /'; } \
                   || echo "outgoing SRs:   none"
[ -n "$declined" ] && { echo "DECLINED $target SR(s) - not in flight, but \`osc sr\` will refuse until superseded:"; printf '%s\n' "$declined" | sed 's/^/    /'; echo "    -> submit with: osc sr ... --supersede <id> --yes"; }

# ---- 5. Gitea leg (MANDATORY for scmsync devel projects) ---------------------
prs=""
if [ -n "$devel" ]; then
  oapi "/source/$devel/_meta" || fail "could not read $devel/_meta"
  scm="$(printf '%s' "$O_OUT" | grep -oE '<scmsync>[^<]+' | sed 's/<scmsync>//' | head -1)" || scm=""
  if [ -n "$scm" ]; then
    org="$(printf '%s' "$scm" | sed -E 's#https?://src\.opensuse\.org/##; s#[/?].*##')"
    echo "scmsync:        $scm (git devel project — checking Gitea PRs on $org/$pkg)"
    resp="$(curl -fsS --max-time 20 "https://src.opensuse.org/api/v1/repos/$org/$pkg/pulls?state=open" 2>&1)" \
      || fail "could not query open PRs on $org/$pkg: $resp"
    prs="$(printf '%s' "$resp" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(2)
for p in d:
    num = p.get("number"); base = (p.get("base") or {}).get("ref")
    title = p.get("title"); url = p.get("html_url")
    print(f"PR #{num} -> {base}: {title} ({url})")
')" || fail "unparseable PR list for $org/$pkg"
    # PR titles are foreign-authored; sanitize AFTER the rc-gated capture above
    prs="$(sanitize "$prs")"
    [ -n "$prs" ] && { echo "open PR(s) on the devel repo:"; printf '%s\n' "$prs" | sed 's/^/    /'; } \
                  || echo "open PRs:       none"
  fi
fi

# ---- verdict -----------------------------------------------------------------
if [ "$newpkg" = 1 ] && [ -z "$devel" ]; then
  echo "VERDICT: PROCEED (new package — absent from $target and no devel project; package it from scratch, see references/update-build.md \"New package from scratch\")"
  exit 0
fi
if [ -n "$incoming" ] || [ -n "$outgoing" ] || [ -n "$prs" ]; then
  first="$(printf '%s\n%s\n%s\n' "$outgoing" "$incoming" "$prs" | grep -m1 .)"
  echo "VERDICT: STOP - already in flight: $first"
  exit 3
fi
# devel ahead of the target version / of the target project, with no SR/PR = stranded
# ahead=1 -> stranded, forward it;  ahead=2 -> devel and the target project are
# already at the same version, i.e. the update LANDED and there is nothing to do.
# The distinction matters: without it a package whose update is already in the
# target project reports FORWARD, and the "fix" is an empty SR (real case
# 2026-08-09, python-apache-tvm-ffi 0.1.13.post2 in both devel and Factory).
ahead=0
if [ -n "$develver" ]; then
  if [ -n "$targetver" ]; then
    # devel >= target-version ? (sort -V; equality counts as "already has it")
    if [ "$(printf '%s\n%s\n' "$targetver" "$develver" | sort -V | head -1)" = "$targetver" ]; then
      if [ -n "$targetprjver" ] && [ "$develver" = "$targetprjver" ]; then ahead=2; else ahead=1; fi
    fi
  elif [ -n "$targetprjver" ] && [ "$develver" != "$targetprjver" ]; then
    [ "$(printf '%s\n%s\n' "$targetprjver" "$develver" | sort -V | tail -1)" = "$develver" ] && ahead=1
  fi
fi
if [ "$ahead" = 2 ]; then
  echo "VERDICT: STOP - nothing to do: $devel and $target are both at $develver (this update already landed)"
  exit 3
fi
if [ "$ahead" = 1 ]; then
  echo "VERDICT: FORWARD - stranded devel update (devel already has ${targetver:-a newer version than $target}), run: osc sr $devel $pkg $target"
  exit 4
fi
if [ "$newpkg" = 1 ]; then
  echo "VERDICT: PROCEED (not in $target — this will be a new-package submission via ${devel:-a devel project})"
else
  echo "VERDICT: PROCEED"
fi
exit 0
