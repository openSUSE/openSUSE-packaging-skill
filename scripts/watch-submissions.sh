#!/bin/bash
# watch-submissions.sh — cron-friendly DELTA watcher for your submissions:
# snapshots your ACTIVE OBS submit requests (states new,review; roles=creator),
# INCOMING requests others directed at packages/projects you maintain
# (roles=maintainer,reviewer, creator != you), plus your OPEN src.opensuse.org
# (Gitea) PRs; diffs each set against the saved baseline, prints only the
# delta, then refreshes the baseline. Complements sr-status.py: that renders
# the full current status; this answers "what CHANGED since the last firing?"
# cheaply enough to run from a cron/scheduled prompt without spamming
# (NOCHANGE is the common case — stay silent on it).
#
# Output protocol (stable — scheduled-prompt playbooks key on the first line):
#   BASELINE-INIT      first run; snapshot saved, nothing to diff
#   NOCHANGE           no delta
#   CHANGED            followed by one "  * ..." line per delta:
#                        NEW SR <id> <pkg> [state]       entered the active set
#                        SR <id> <pkg>: staging A -> B   staging (re)assignment
#                        RESOLVE SR <id> <pkg> (...)     left new/review
#                        NEW INCOMING SR <id> <pkg> from <creator> [state]
#                        RESOLVE INCOMING SR <id> <pkg> (...)
#                        INCOMING MAINTENANCE: <n> new (<ids>) — ...
#                        INCOMING MAINTENANCE: <n> closed (<ids>) — no action
#                        NEW PR <repo>#<n>
#                        RESOLVE PR <repo>#<n> '<title>' (no longer open)
#   WATCH-ERROR ...    query failure; baseline untouched (exit 2)
#
# "RESOLVE" means the item left the watched set; the CALLER fetches the final
# state (osc request show <id> / tea api .../pulls/<n> — accepted/declined/
# revoked vs merged/closed). For NEW INCOMING the caller reviews the request
# (osc request show --diff <id>) and applies the accept/decline policy. The
# watcher itself stays one-API-call-per-leg cheap and does not chase
# resolutions. maintenance_incident / maintenance_release entries are the
# exception: they are the QAM/security teams' pipeline, never the package
# maintainer's to accept or decline, so they are aggregated into one counted
# INCOMING MAINTENANCE line rather than per-request lines that would read like
# review to-dos.
#
# Usage: watch-submissions.sh [--user U] [--login GITEA_LOGIN]
#                             [--state-dir DIR] [--allow-empty] [--no-prs]
#                             [--no-incoming]
#   --user        OBS account (default: osc whois)
#   --login       tea login name for the Gitea leg (default: src.opensuse.org)
#   --state-dir   where the baseline JSON lives
#                 (default: ${XDG_STATE_HOME:-~/.local/state}/osc-submission-watch)
#   --allow-empty accept an empty OBS active set as truth. Default is to treat
#                 it as a failed query and keep the baseline — right for anyone
#                 who usually has SRs in flight, wrong the day you have none.
#                 (Applies to the OUTGOING set only: an empty incoming set is
#                 perfectly normal and always trusted.)
#   --no-prs      skip the Gitea leg entirely
#   --no-incoming skip the incoming-requests leg entirely
#
# Failure semantics: an OBS outgoing-query failure (or empty set without
# --allow-empty) aborts with WATCH-ERROR, baseline untouched. The incoming and
# Gitea legs fail SOFT: their diff is skipped for this run, the baseline keeps
# that leg's previous set, and a "! <leg> unavailable" note is appended —
# a leg failure never fabricates RESOLVE lines. A pre-existing baseline
# without the incoming set (written by an older version) is upgraded silently:
# the current incoming set is recorded without reporting it all as NEW.
set -o pipefail

OBSUSER="" LOGIN="src.opensuse.org"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/osc-submission-watch"
ALLOW_EMPTY=0 NO_PRS=0 NO_INCOMING=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0;;
    --user) OBSUSER="$2"; shift 2;;
    --login) LOGIN="$2"; shift 2;;
    --state-dir) STATE_DIR="$2"; shift 2;;
    --allow-empty) ALLOW_EMPTY=1; shift;;
    --no-prs) NO_PRS=1; shift;;
    --no-incoming) NO_INCOMING=1; shift;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2;;
  esac
done

if [ -z "$OBSUSER" ]; then
  OBSUSER=$(osc whois 2>/dev/null | cut -d: -f1 | tr -d '[:space:]')
fi
if [ -z "$OBSUSER" ]; then
  echo "WATCH-ERROR: cannot determine OBS user (osc whois failed; pass --user)"
  exit 2
fi
mkdir -p "$STATE_DIR" || { echo "WATCH-ERROR: cannot create state dir $STATE_DIR"; exit 2; }
BASE="$STATE_DIR/baseline-$OBSUSER.json"

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

osc api "/request?view=collection&roles=creator&user=$OBSUSER&states=new,review&limit=250" \
    >"$TMP/obs.xml" 2>"$TMP/obs.err"
OBS_RC=$?

INCOMING_RC=1
if [ "$NO_INCOMING" = 0 ]; then
  osc api "/request?view=collection&roles=maintainer,reviewer&user=$OBSUSER&states=new,review&limit=250" \
      >"$TMP/incoming.xml" 2>"$TMP/incoming.err"
  INCOMING_RC=$?
fi

GITEA_RC=1
if [ "$NO_PRS" = 0 ]; then
  tea api --login "$LOGIN" "/repos/issues/search?type=pulls&state=open&created=true&limit=50" \
      >"$TMP/gitea.json" 2>"$TMP/gitea.err"
  GITEA_RC=$?
fi

OBS_RC=$OBS_RC INCOMING_RC=$INCOMING_RC GITEA_RC=$GITEA_RC \
ALLOW_EMPTY=$ALLOW_EMPTY NO_PRS=$NO_PRS NO_INCOMING=$NO_INCOMING \
OBSUSER="$OBSUSER" BASE="$BASE" TMP="$TMP" python3 - <<'PYEOF'
import json, os, sys, xml.etree.ElementTree as ET

tmp, base_path = os.environ["TMP"], os.environ["BASE"]
allow_empty = os.environ["ALLOW_EMPTY"] == "1"
no_prs = os.environ["NO_PRS"] == "1"
no_incoming = os.environ["NO_INCOMING"] == "1"
obsuser = os.environ["OBSUSER"]

def parse_requests(path):
    """id -> {pkg,state,staging,creator,kind} for a request collection document.

    kind is "maintenance" when ANY action is a maintenance_incident /
    maintenance_release (the QAM+security release pipeline) and "submit"
    otherwise. Callers must report maintenance entries as a counted group,
    never as review to-dos: they are not the package maintainer's to drive,
    and surfacing them as ordinary incoming SRs invites an accept/decline
    review that would be wrong to act on.
    """
    out = {}
    root = ET.parse(path).getroot()
    for r in root.findall("request"):
        rid = r.get("id")
        st = r.find("state")
        acts = r.findall("action")
        pkgs = []
        for act in acts:
            tgt, src = act.find("target"), act.find("source")
            p = ((tgt.get("package") if tgt is not None else None)
                 or (src.get("package") if src is not None else None))
            if p and p not in pkgs:
                pkgs.append(p)
        pkg = (pkgs[0] + (f" +{len(pkgs)-1} more" if len(pkgs) > 1 else "")) if pkgs else "?"
        stg = ""
        for rv in r.findall("review"):
            if rv.get("state") == "new":
                by = rv.get("by_project") or ""
                if "Staging" in by:
                    parts = by.split(":")
                    stg = parts[-1] if parts[-2] == "Staging" else ":".join(parts[-2:])
        kind = ("maintenance"
                if any((act.get("type") or "").startswith("maintenance_")
                       for act in acts)
                else "submit")
        out[rid] = {"pkg": pkg, "state": st.get("name") if st is not None else "?",
                    "staging": stg, "creator": r.get("creator") or "?", "kind": kind}
    return out

# ---- OBS leg (hard requirement: no diff without a trusted active set) ----
if os.environ["OBS_RC"] != "0":
    err = open(f"{tmp}/obs.err").read().strip().splitlines()
    print("WATCH-ERROR: OBS request query failed "
          f"({err[-1] if err else 'osc api rc!=0'}); baseline untouched")
    sys.exit(2)
try:
    obs = parse_requests(f"{tmp}/obs.xml")
except ET.ParseError as e:
    print(f"WATCH-ERROR: OBS response not parseable ({e}); baseline untouched")
    sys.exit(2)
if not obs and not allow_empty:
    print("WATCH-ERROR: OBS active set came back empty (likely a query failure; "
          "pass --allow-empty if you really have no open SRs); baseline untouched")
    sys.exit(2)

# ---- incoming leg (soft: a failure skips the diff, never fakes RESOLVEs) ----
# roles=maintainer,reviewer returns requests whose TARGET the user maintains /
# is asked to review; the user's own creations are removed so nothing shows up
# in both sets. Empty is normal here — no --allow-empty guard.
incoming, incoming_ok = {}, False
if not no_incoming and os.environ["INCOMING_RC"] == "0":
    try:
        incoming = {rid: v for rid, v in parse_requests(f"{tmp}/incoming.xml").items()
                    if v["creator"] != obsuser}
        incoming_ok = True
    except ET.ParseError:
        incoming_ok = False

# ---- Gitea leg (soft: a failure skips the PR diff, never fakes RESOLVEs) ----
gitea, gitea_ok = {}, False
if not no_prs and os.environ["GITEA_RC"] == "0":
    try:
        for it in json.load(open(f"{tmp}/gitea.json")):
            repo = (it.get("repository") or {}).get("full_name", "?")
            gitea[f"{repo}#{it.get('number')}"] = {"title": (it.get("title") or "")[:60]}
        gitea_ok = True
    except Exception:
        gitea_ok = False

base = None
if os.path.exists(base_path):
    try:
        base = json.load(open(base_path))
    except Exception:
        base = None  # corrupt baseline: reinitialize below

if base is None:
    json.dump({"obs": obs, "incoming": incoming if incoming_ok else {},
               "gitea": gitea if gitea_ok else {}},
              open(base_path, "w"), indent=1)
    print("BASELINE-INIT: first snapshot saved"
          + ("" if gitea_ok or no_prs else " (gitea leg unavailable)")
          + ("" if incoming_ok or no_incoming else " (incoming leg unavailable)"))
    sys.exit(0)

changes = []
bo = base.get("obs", {})
for rid, v in obs.items():
    if rid not in bo:
        changes.append(f"NEW SR {rid} {v['pkg']} [{v['state']}]")
    elif bo[rid].get("staging") != v.get("staging"):
        changes.append(f"SR {rid} {v['pkg']}: staging "
                       f"{bo[rid].get('staging') or '-'} -> {v.get('staging') or '-'}")
for rid, v in bo.items():
    if rid not in obs:
        changes.append(f"RESOLVE SR {rid} {v['pkg']} "
                       "(left review; fetch final state: accepted/declined/revoked)")

# Incoming diff. A baseline written by an older script version has no
# "incoming" key — upgrade silently (record, don't report a NEW flood).
bi = base.get("incoming")
incoming_upgraded = incoming_ok and bi is None
if bi is None:
    bi = {}
if incoming_ok and not incoming_upgraded:
    # Maintenance-pipeline entries are aggregated into one counted line instead
    # of per-request NEW/RESOLVE lines: they belong to QAM/security, so a line
    # that reads like a review to-do is actively misleading. A baseline written
    # before `kind` existed has no key — default to "submit" so those entries
    # resolve once as ordinary SRs and are classified correctly from then on.
    maint_new, maint_gone = [], []
    for rid, v in incoming.items():
        if rid not in bi:
            (maint_new if v.get("kind") == "maintenance" else changes).append(
                rid if v.get("kind") == "maintenance"
                else f"NEW INCOMING SR {rid} {v['pkg']} "
                     f"from {v['creator']} [{v['state']}]")
    for rid, v in bi.items():
        if rid not in incoming:
            (maint_gone if v.get("kind") == "maintenance" else changes).append(
                rid if v.get("kind") == "maintenance"
                else f"RESOLVE INCOMING SR {rid} {v['pkg']} "
                     "(left review; fetch final state: accepted/declined/revoked)")
    if maint_new:
        changes.append(f"INCOMING MAINTENANCE: {len(maint_new)} new "
                       f"({', '.join(sorted(maint_new))}) — QAM/security pipeline, "
                       "report as a counted group, not review to-dos")
    if maint_gone:
        changes.append(f"INCOMING MAINTENANCE: {len(maint_gone)} closed "
                       f"({', '.join(sorted(maint_gone))}) — no action")

bg = base.get("gitea", {})
if gitea_ok:
    for k in gitea:
        if k not in bg:
            changes.append(f"NEW PR {k}")
    for k, v in bg.items():
        if k not in gitea:
            changes.append(f"RESOLVE PR {k} '{v.get('title', '')}' "
                           "(no longer open; fetch final state: merged/closed)")

print("CHANGED" if changes else "NOCHANGE")
for c in changes:
    print("  * " + c)
if not gitea_ok and not no_prs:
    print("  ! gitea leg unavailable this run (PR diff skipped; PR baseline kept)")
if not incoming_ok and not no_incoming:
    print("  ! incoming leg unavailable this run (diff skipped; baseline kept)")
if incoming_upgraded:
    print("  ! incoming leg initialized (baseline upgraded; deltas start next run)")

json.dump({"obs": obs,
           "incoming": incoming if incoming_ok else bi,
           "gitea": gitea if gitea_ok else bg},
          open(base_path, "w"), indent=1)
PYEOF
