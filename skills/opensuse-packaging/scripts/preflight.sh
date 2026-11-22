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
#      check gives a false PROCEED), read with `git-obs -G src.opensuse.org`;
#      a failed or unreadable answer is CHECK-FAILED, never "none"
#   5. a `reviewer` role (package or project _meta) held by someone OTHER than
#      you -> prints a REVIEWER ROLE notice. That person asked to see changes
#      before they land, so the update must go as a BRANCH + SR to the devel
#      project, never a direct commit, and you must not accept your own SR --
#      maintainer rights are not permission to bypass their gate.
#   6. a target-agnostic sweep (/search/request on the package as the action
#      target, any source, any target project): catches what the anchored
#      queries filter out — an SR filed straight at the target from a
#      non-devel source, or one aimed at another target entirely (a Leap /
#      Backports submission, a staging project). Submit requests only: a
#      set_bugowner, add_role or delete request moves no code and is not an
#      update in flight. A hit on the target project counts as in flight
#      (check 3's STOP); one on the devel project is check 2's incoming SR,
#      already listed and deduped out below. Any other hit is printed for
#      the report — for a fix leg it names a tree the fixes may have to
#      ride on — and does not change the verdict.
#   7. whose each open request and PR is (every action of a request is read):
#      when you maintain the devel package (pr-guard's maintainer rule) and a
#      contributor — a creator other than you — has an SR to it or a PR on its
#      devel repo, that is INCOMING: review it before your update. Each one is
#      listed with its creator and what its incoming-review.sh stamp recorded
#      ("reviewed: BLOCK" is not reviewed again, yet still waits), and the
#      verdict line adds when devel already has the version or it already
#      landed, so nobody repackages it after the review. On a package you do
#      not maintain it is in flight, as before. A lookup that fails, or
#      an answer that is empty or malformed, is CHECK-FAILED, never "nothing
#      incoming".
#
# Usage: preflight.sh <pkg> [target-version] [--target-project PRJ] [--user U] [--from PRJ]
#   target-version    the version you intend to package (optional; without it
#                     the devel-vs-Factory version delta drives the verdict);
#                     anything not version-shaped (a project name) is a usage error
#   --target-project  default openSUSE:Factory
#   --user            OBS account (default: `osc whois`)
#   --from            the project you are about to branch (or already branched):
#                     STOP unless it is the devel project, or the devel package
#                     is a _link to it. A copy elsewhere carries its own .changes
#                     history, and an SR from it rewrites the devel project's
#                     (sr#1392134: hardware's stale copy filed to devel:languages:python)
#
# Verdict line + exit code:
#   0  VERDICT: PROCEED            (also for a brand-new package, with a note)
#   3  VERDICT: STOP     — update already in flight (prints the SR id / PR #), or
#      nothing to do because devel and the target project already carry the same
#      version (the update landed; forwarding it would file an empty SR), or
#      --from names a project that is not where the package is developed
#   5  VERDICT: INCOMING — a contributor's SR or devel PR on your package waits
#      for review (check 7); your own request in flight still wins (3)
#   4  VERDICT: FORWARD  — stranded devel update: devel is ahead but no Factory
#      SR was ever filed (openmopac/pspg case); prints the exact osc sr command
#   2  a check FAILED (network/auth) — a failed check must NEVER print PROCEED
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 0;;
  '') awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 2;;
esac

pkg="" ; targetver="" ; target="openSUSE:Factory" ; user="" ; from=""
while [ $# -gt 0 ]; do
  case "$1" in --target-project|--user|--from) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; };; esac
  case "$1" in
    --target-project) target="$2"; shift 2;;
    --user) user="$2"; shift 2;;
    --from) from="$2"; shift 2;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) if [ -z "$pkg" ]; then pkg="$1"; elif [ -z "$targetver" ]; then targetver="$1";
       else echo "unexpected arg: $1" >&2; exit 2; fi; shift;;
  esac
done
[ -n "$pkg" ] || { awk 'NR>1 { if (!/^#/) exit; print }' "$0"; exit 2; }
# A project name in the version slot compared as a version and printed PROCEED.
if [ -n "$targetver" ] && { [[ ! $targetver =~ ^[A-Za-z0-9._+~^]+$ ]] || [[ ! $targetver =~ [0-9] ]]; }; then
  echo "preflight.sh: '$targetver' is not a version (the target project goes in --target-project)" >&2; exit 2
fi
# Query strings decode + as a space, so the package name enters every
# request query percent-encoded (libsigc++3 read as "libsigc  3" printed
# "none" with sr#1386760 open); URL paths keep the literal name.
epkg="${pkg//+/%2B}"
[ -n "$user" ] || user="$(timeout 30 osc whois 2>/dev/null | sed 's/:.*//')" || true

fail() { echo "CHECK FAILED: $*" >&2; echo "VERDICT: CHECK-FAILED (fix and re-run — this is NOT a PROCEED)"; exit 2; }
# captured stderr of osc / git-obs: mktemp under $TMPDIR, not a guessable /tmp name
errf="$(mktemp)" || fail "mktemp failed"; trap 'rm -f "$errf"' EXIT

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
  O_OUT="$(timeout 30 osc api "$1" 2>"$errf")"; rc=$?
  err="$(cat "$errf" 2>/dev/null || true)"
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
    # Absent by this spelling only? devel-of.sh checks the others (case, -/_/.,
    # python3dist()'s): python-authlib was filed while Factory had python-Authlib.
    near="$(timeout 120 "$SDIR/devel-of.sh" "$pkg" "$target" 2>"$errf")"; nrc=$?
    case $nrc in
      3) ;;
      6) echo "VERDICT: STOP - not in $target as $pkg, but it has ${near#*, but it has }"; exit 3 ;;
      *) fail "could not check $target for other spellings of $pkg: $(head -n 1 "$errf" 2>/dev/null)${near:+ $near}" ;;
    esac
    echo "package:        $pkg — NOT in $target (new package)"
    newpkg=1
  elif printf '%s' "$O_OUT" | grep -q '<devel '; then
    fail "osc develproject failed, but $target/$pkg/_meta names a devel project"
  else
    echo "package:        $pkg — in $target but no devel project set"
  fi
else
  echo "devel project:  $devel"
fi
if [ -n "$from" ]; then
  if [ -z "$devel" ]; then
    echo "branch source:  $from (no devel project to check it against)"
  elif [ "$from" = "$devel" ]; then
    echo "branch source:  $from (the devel project)"
  else
    oapi "/source/$devel/$pkg/_link" || fail "could not read $devel/$pkg/_link"
    lp="$(printf '%s' "$O_OUT" | grep -oE '<link [^>]*project="[^"]*"' | sed 's/.*project="//; s/"$//' | head -1)"
    if [ "$O_404" = 0 ] && [ "$lp" = "$from" ]; then
      echo "branch source:  $from ($devel/$pkg links to it)"
    else
      echo "VERDICT: STOP - wrong branch source: $pkg is developed in $devel, not $from; its history is not $devel's — branch $devel/$pkg (osc branch $devel $pkg)"
      exit 3
    fi
  fi
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
parse_srs() { # stdin: request collection XML; args: source project, target project, target package ("": any)
  python3 -I -c '
import sys, xml.etree.ElementTree as ET
sp_f, tp_f, tk_f = (sys.argv[1:] + ["", "", ""])[:3]
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(2)  # OBS answers an empty <collection/>, never nothing
try:
    root = ET.fromstring(raw)
except ET.ParseError:
    sys.exit(2)
seen = set()
for r in root.findall("request"):
    st = r.find("state")
    sname = st.get("name") if st is not None else "?"
    rid, who = r.get("id"), r.get("creator") or ""
    # Every action: the submit of a multi-action request may be its second.
    for a in r.findall("action"):
        # Only a submit moves code: a set_bugowner/add_role/delete request is
        # not an update in flight, whatever the query returned.
        if a.get("type") != "submit": continue
        s, t = a.find("source"), a.find("target")
        sp = s.get("project") if s is not None else "?"
        spkg = s.get("package") if s is not None else "?"
        tprj = t.get("project") if t is not None else "?"
        tpkg = (t.get("package") if t is not None else None) or spkg
        if sp_f and sp != sp_f or tp_f and tprj != tp_f or tk_f and tpkg != tk_f: continue
        if len(who.split()) != 1: sys.exit(2)  # whose it is decides STOP or INCOMING
        line = f"SR {rid} [{sname}] {sp}/{spkg} -> {tprj} by {who}"
        if line not in seen:
            seen.add(line)
            print(line)
' "$@"
}
# The last oapi answer as a request collection: a 404 is an answer, none.
coll() { if [ "$O_404" = 1 ]; then printf '<collection/>'; else printf '%s' "$O_OUT"; fi; }

incoming=""
if [ -n "$devel" ]; then
  oapi "/request?view=collection&types=submit&states=new,review&project=$devel&package=$epkg" \
    || fail "could not query incoming SRs for $devel/$pkg"
  incoming="$(coll | parse_srs "" "$devel" "$pkg")" || fail "unparseable SR collection (incoming)"
fi
oapi "/request?view=collection&types=submit&states=new,review&project=$target&package=$epkg" \
  || fail "could not query $target SRs for $pkg"
outgoing="$(coll | parse_srs "${devel:-}" "$target" "$pkg")" || fail "unparseable SR collection (outgoing)"

# A DECLINED request is terminal but NOT gone: `osc sr` still lists it as
# "already open" and prompts to supersede it (y/n/c), which an unattended run
# cannot answer. Querying only new,review reports "outgoing SRs: none" and the
# submit then fails at the end of the work (picsart-gen-ai 2026-09-04, stale
# declined 1375013). The prompt covers every open request from the same source,
# anyone's, and --yes answers it for all of them: supersede only your own, by
# id with -s; someone else's is theirs to revoke.
oapi "/request?view=collection&types=submit&states=declined&project=$target&package=$epkg" \
  || fail "could not query declined $target SRs for $pkg"
declined="$(coll | parse_srs "${devel:-}" "$target" "$pkg")" || fail "unparseable SR collection (declined)"

[ -n "$incoming" ] && { echo "incoming SR(s) at $devel:"; printf '%s\n' "$incoming" | sed 's/^/    /'; } \
                   || echo "incoming SRs:   none"
[ -n "$outgoing" ] && { echo "outgoing devel->$target SR(s):"; printf '%s\n' "$outgoing" | sed 's/^/    /'; } \
                   || echo "outgoing SRs:   none"
own=""
if [ -n "$declined" ]; then
  echo "DECLINED $target SR(s) - not in flight, but \`osc sr\` lists them as open and prompts to supersede them:"
  printf '%s\n' "$declined" | sed 's/^/    /'
  if [ -z "$user" ]; then
    echo "    -> could not tell which are yours (\`osc whois\` failed): pass --user"
  else
    own="$(printf '%s\n' "$declined" | awk -v u="$user" '$NF == u {print $2}' | sort -n | tail -1)"
    [ -n "$own" ] && echo "    -> $own is yours: file with osc sr ... -s $own  (never --yes: it supersedes every open request from this source)"
    printf '%s\n' "$declined" | awk -v u="$user" '$NF != u {print "    -> " $2 " is by " $NF ", not yours to supersede: ask them to revoke it, or leave it"}'
  fi
fi

# ---- 5. Gitea leg (MANDATORY for scmsync devel projects) ---------------------
prs="" ; prs_by=""
if [ -n "$devel" ]; then
  oapi "/source/$devel/_meta" || fail "could not read $devel/_meta"
  scm="$(printf '%s' "$O_OUT" | grep -oE '<scmsync>[^<]+' | sed 's/<scmsync>//' | head -1)" || scm=""
  if [ -n "$scm" ]; then
    org="$(printf '%s' "$scm" | sed -E 's#https?://src\.opensuse\.org/##; s#[/?].*##')"
    echo "scmsync:        $scm (git devel project — checking Gitea PRs on $org/$pkg)"
    # -G: without it git-obs takes its default login, which may be another forge
    resp="$(timeout 30 git-obs -G src.opensuse.org -q api "/repos/$org/$pkg/pulls?state=open" 2>"$errf")"; grc=$?
    err="$(grep -vx 'Response:' "$errf" 2>/dev/null || true)"
    [ "$grc" = 124 ] && err="git-obs timed out after 30s"
    [ "$grc" = 0 ] || fail "could not query open PRs on $org/$pkg: ${err:-git-obs exit $grc}"
    # "<author>\t<line>" per PR; a PR without a number or an author is no list
    prs_by="$(printf '%s' "$resp" | python3 -I -c '
import re, sys, json
raw = sys.stdin.read()
if raw.startswith("Response:"): raw = raw.split("\n", 1)[1] if "\n" in raw else ""
try: d = json.loads(raw)
except Exception: sys.exit(2)
if not isinstance(d, list): sys.exit(2)
for p in d:
    num = p.get("number"); base = (p.get("base") or {}).get("ref")
    who = (p.get("user") or {}).get("login")
    if type(num) is not int or not isinstance(who, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", who):
        sys.exit(2)
    # one line each: a newline in a title could forge another PR
    title, url = (" ".join(str(x).split()) for x in (p.get("title"), p.get("html_url")))
    print(f"{who}\tPR #{num} -> {base}: {title} ({url}) by {who}")
')" || fail "unparseable PR list for $org/$pkg"
    # PR titles are foreign-authored; sanitize AFTER the rc-gated capture above
    prs_by="$(sanitize "$prs_by")"
    prs="$(printf '%s\n' "$prs_by" | cut -f2- | grep -v '^$')"
    [ -n "$prs" ] && { echo "open PR(s) on the devel repo:"; printf '%s\n' "$prs" | sed 's/^/    /'; } \
                  || echo "open PRs:       none"
  fi
fi

# ---- 6. target-agnostic sweep ------------------------------------------------
# The anchored queries above are read against the devel and target projects
# only, and the outgoing one is filtered to devel sources — an SR filed
# straight at the target from a non-devel source, or aimed at another target
# entirely, escapes both. One /search/request sweep on the package as the
# action target sees every open submit request for it, from anyone. The
# match is submit-only, and parse_srs drops a non-submit action a second
# time: a set_bugowner request (sr#1383747, for runc) is not in flight.
oapi "/search/request?match=action%5B@type=%27submit%27%20and%20target/@package=%27$epkg%27%5D%20and%20(state/@name=%27new%27%20or%20state/@name=%27review%27)" \
  || fail "could not query other SRs targeting $pkg"
sweep="$(coll | parse_srs "" "" "$pkg")" || fail "unparseable SR collection (sweep)"
sweep_blocking="" ; sweep_other=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # By the action's line, not the request id: a request that submits to
  # devel and to the target is listed above for its devel action only.
  printf '%s\n%s\n' "$incoming" "$outgoing" | grep -qxF -- "$line" && continue
  tgt="$(printf '%s' "$line" | sed 's/.* -> \([^ ]*\) by .*/\1/')"
  # No $devel arm: a submit to devel/$pkg is check 2's incoming SR, already
  # listed and deduped above, so only the target project can block here.
  if [ "$tgt" = "$target" ]; then
    sweep_blocking="${sweep_blocking:+$sweep_blocking
}$line"
  else
    sweep_other="${sweep_other:+$sweep_other
}$line"
  fi
done <<< "$sweep"
[ -n "$sweep_blocking" ] && { echo "sweep: SR(s) in flight at $target from a non-devel source:"; printf '%s\n' "$sweep_blocking" | sed 's/^/    /'; }
[ -n "$sweep_other" ] && { echo "sweep: SR(s) targeting $pkg in other projects (report them — a fix leg may have to ride on one):"; printf '%s\n' "$sweep_other" | sed 's/^/    /'; }
[ -z "$sweep_blocking" ] && [ -z "$sweep_other" ] && echo "sweep SRs:      none"

# ---- 7. contributors' submissions --------------------------------------------
# A contributor's SR to the devel package or PR on its repo, on a package you
# maintain, is reviewed before your update. Maintainership and the review
# stamps are _incoming.py's: pr-guard's rule, and the state directory this
# script must not name (pr-guard refuses its writes when it does).
own_in="" ; foreign_in="" ; own_prs="" ; foreign_prs="" ; contrib=""
if [ -n "$incoming$prs_by" ]; then
  [ -n "$user" ] || fail "could not tell whose requests are open (osc whois failed): pass --user"
  own_in="$(printf '%s\n' "$incoming" | awk -v u="$user" 'NF && $NF == u')"
  foreign_in="$(printf '%s\n' "$incoming" | awk -v u="$user" 'NF && $NF != u')"
  own_prs="$(printf '%s\n' "$prs_by" | awk -F'\t' -v u="$user" 'NF && $1 == u { sub(/^[^\t]*\t/, ""); print }')"
  foreign_prs="$(printf '%s\n' "$prs_by" | awk -F'\t' -v u="$user" 'NF && $1 != u')"
fi
if [ -n "$foreign_in$foreign_prs" ]; then
  why="$(python3 -I "$SDIR/_incoming.py" maintains "$user" "$devel" "$pkg" 2>"$errf")"; mrc=$?
  case $mrc in
    0) items=""
       while IFS= read -r line; do
         [ -n "$line" ] || continue
         sid="${line#SR }" ; sid="${sid%% *}"
         items="${items}sr#$sid ${line##* }"$'\n'
       done <<< "$foreign_in"
       while IFS=$'\t' read -r who line; do
         [ -n "$who" ] || continue
         num="${line#PR #}" ; num="${num%% *}"
         items="${items}$org/$pkg#$num $who"$'\n'
       done <<< "$foreign_prs"
       while read -r item who; do
         [ -n "$item" ] || continue
         note="$(python3 -I "$SDIR/_incoming.py" stamp "$item" 2>"$errf")" \
           || fail "could not read the review stamp of $item: $(head -n 1 "$errf" 2>/dev/null)"
         contrib="${contrib:+$contrib
}$item by $who: $note"
       done <<< "$items"
       echo "contributors' submissions to review before your update (you maintain $devel/$pkg):"
       printf '%s\n' "$contrib" | sed 's/^/    /' ;;
    3) echo "contributors' submissions: in flight, not yours to review ($why)" ;;
    # 2, or anything else (a crash): no answer, never "not yours"
    *) fail "could not tell whether you maintain $devel/$pkg: ${why:-$(head -n 1 "$errf" 2>/dev/null)}" ;;
  esac
fi

# ---- verdict -----------------------------------------------------------------
# Your own request, a forward and a sweep hit are in flight; so is a
# contributor's item on a package you do not maintain. Before the new-package
# PROCEED: an open SR to the target for a new package is in flight too.
if [ -n "$contrib" ]; then stop_in="$own_in"; stop_prs="$own_prs"; else stop_in="$incoming"; stop_prs="$prs"; fi
if [ -n "$outgoing$stop_in$stop_prs$sweep_blocking" ]; then
  first="$(printf '%s\n%s\n%s\n%s\n' "$outgoing" "$stop_in" "$stop_prs" "$sweep_blocking" | grep -m1 .)"
  echo "VERDICT: STOP - already in flight: $first"
  exit 3
fi
if [ "$newpkg" = 1 ] && [ -z "$devel" ]; then
  echo "VERDICT: PROCEED (new package — absent from $target and no devel project; package it from scratch, see references/update-build.md \"New package from scratch\")"
  exit 0
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
if [ -n "$contrib" ]; then
  # what comes after the review: an agent going on must not repackage
  case $ahead in
    1) after=" — after it: devel already has ${targetver:-a newer version than $target}, forward it, do not repackage" ;;
    2) after=" — after it: nothing to package, $devel and $target are both at $develver" ;;
    *) after="" ;;
  esac
  echo "VERDICT: INCOMING - review the contributors' submissions before your update: ${contrib//$'\n'/; }$after"
  exit 5
fi
if [ "$ahead" = 2 ]; then
  echo "VERDICT: STOP - nothing to do: $devel and $target are both at $develver (this update already landed)"
  exit 3
fi
if [ "$ahead" = 1 ]; then
  # -s and -m keep it from prompting; only someone else's declined SR still can
  stuck=""; [ -z "$own" ] && [ -n "$declined" ] \
    && stuck=" — declined $(printf '%s\n' "$declined" | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//') still makes osc sr prompt (see above)"
  echo "VERDICT: FORWARD - stranded devel update (devel already has ${targetver:-a newer version than $target}), run: osc sr $devel $pkg $target${own:+ -s $own} -m \"<short message>\"$stuck"
  exit 4
fi
if [ "$newpkg" = 1 ]; then
  echo "VERDICT: PROCEED (not in $target — this will be a new-package submission via ${devel:-a devel project})"
else
  echo "VERDICT: PROCEED"
fi
exit 0
