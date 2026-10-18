#!/bin/bash
# Lint a .changes file for the format problems reviewers decline over —
# the whole-file companion to changes-prepend.sh (which only verifies its
# own insertion). Run as part of the Block-3 pre-SR gate: a human reviewer
# decline for "format of the changes entries" (real case: python-langsmith
# a real decline over "missing newlines") costs a full review round-trip
# that this catches locally in milliseconds.
#
# Usage: changes-lint.sh [--entries N | --all] [--author 'Name <email>'] <file>.changes [...]
#   --entries N  lint only the N >= 1 newest (topmost) entries (default: 1 —
#                the entry your SR adds; use the number of entries new
#                to the SR when superseding). Historical entries routinely
#                violate today's rules and must never be retro-edited, so
#                they are out of scope by default — except for the blank
#                line closing the newest entry, which sits on the boundary
#                and IS checked (see the comment at `limit`).
#   --all        lint every entry + file-global checks (EOF newline,
#                trailing blank lines). For audits, not the gate.
#   --author 'Name <email>'
#                the identity a bare `osc vc` writes (vc-identity.sh; gate.sh
#                passes it): an entry whose author shares its name OR its
#                address must carry both exactly (address case-insensitive).
#                Other packagers' entries pass (a forwarded update keeps its
#                author). Real case: sr#1385844 shipped an entry signed with
#                the git address under the right name.
#   Checks per entry:
#     - separators are exactly 67 dashes; entry starts at one
#     - separator followed by 'Day Mon DD HH:MM:SS UTC YYYY - Name <email>'
#     - author is 'Name <email>' form (never a bare email); with --author,
#       the same name and address osc vc writes
#     - blank line after the header, blank line before the next separator
#     - body lines are bullets ('- ', nested '* ') or indented continuations
#     - no trailing whitespace
#     - entry has a real body: not empty, and not a bare 'Update to X.Y.Z'
#       with no summary of the actual changes (add substantive bullets, or
#       state '* No user-visible changes' when a release truly has none) —
#       the content decline reviewers reject over (real case: langsmith
#       a real decline: "modify the changelog entry to contain more
#       details"); the format checks above pass on such an entry, so this
#       is the gate that catches it
#     - no bullet ('-', '*' or '+', continuation lines included) names a
#       CVE id as not fixed — 'not (yet) fixed/addressed', 'unfixed',
#       'unpatched', 'still vulnerable/affected', 'does/did not fix/address',
#       'tracked separately', 'remains open/unfixed/vulnerable' — unless it
#       states that this update fixes that id: reviewers read any CVE id in
#       .changes as fixed here (references/changelog-rules.md "CVEs and
#       security bullets")
#     - no bullet names an OBS request ('sr#N', 'SR N', 'rq N', 'request #N')
#       or a staging order ('lands after', 'stage together'): the SR
#       message carries those, the .changes ships in the RPM
#       (references/changelog-rules.md "Curate the entry")
#   Exit: 0 = clean, 1 = findings (file:line: message), 2 = usage,
#         3 = a file is unreadable (wins over 1: the other files are still
#         linted and printed, but the run is incomplete).
set -euo pipefail

entries=1; author=""
while :; do
  case "${1:-}" in
    -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    --entries) [ $# -ge 2 ] || { echo "--entries needs a value" >&2; exit 2; }
      # 0 is --all's internal value: from --entries it would lint released entries
      [[ $2 =~ ^[1-9][0-9]*$ ]] || { echo "--entries takes a positive integer, got '$2' (--all lints every entry)" >&2; exit 2; }
      entries=$2; shift 2 ;;
    --all) entries=0; shift ;;
    --author) [ $# -ge 2 ] || { echo "--author needs a value" >&2; exit 2; }
      [[ $2 =~ ^[^\<\>]*[^\<\>\ ]\ \<[^\<\>@\ ]+@[^\<\>@\ ]+\>$ ]] \
        || { echo "--author takes 'Name <email>', got '$2'" >&2; exit 2; }
      author=$2; shift 2 ;;
    *) break ;;
  esac
done

[ $# -gt 0 ] || { awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
rc=0; unreadable=0
for f in "$@"; do
  [ -r "$f" ] || { echo "$f: unreadable" >&2; unreadable=1; continue; }
  python3 - "$f" "$entries" "$author" <<'PY' || rc=1
import re, sys
f, nent, me = sys.argv[1], int(sys.argv[2]), sys.argv[3]
WHO = re.compile(r"^(.*\S) <([^<>]+)>$")
me_name, me_mail = WHO.match(me).groups() if me else ("", "")
raw = open(f, encoding="utf-8").read()
lines = raw.split("\n")
if raw.endswith("\n"):
    lines = lines[:-1]          # drop the artifact of the final newline
SEP = "-" * 67
HDR = re.compile(
    r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) "
    r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) "
    r"[ 123][0-9] \d\d:\d\d:\d\d UTC \d{4} - .+<\S+@\S+>$")
bad = []
if not lines or not lines[0].startswith("---"):
    bad.append((1, "first line is not a separator"))
# determine the line range to lint: first `nent` entries (0 = all)
seps = [i for i, l in enumerate(lines, 1) if l.startswith("---")]
if nent and len(seps) > nent:
    limit = seps[nent] - 1      # stop before the (nent+1)-th separator
    # ...but that separator is the ANCHOR for the "blank line before the
    # separator" check below, so stopping short of it blinds --entries to a
    # missing blank line at the END of the newest entry — precisely what a
    # reviewer sees. (Real case: python-cyclopts 4.22.4, SR 1369130: the gate
    # said clean, the reviewer added the newline by hand and superseded it.)
    # So check that one boundary explicitly here. Only the blank line is in
    # scope — the separator's own dash count / whitespace belong to the older
    # entry and must not be retro-flagged.
    if seps[nent] >= 2 and lines[seps[nent] - 2].strip() != "":
        bad.append((seps[nent] - 1, "missing blank line before the separator"))
else:
    limit = len(lines)
    if nent == 0:               # --all: file-global checks
        if not raw.endswith("\n"):
            bad.append((len(lines), "missing newline at end of file"))
        if raw.endswith("\n\n"):
            bad.append((len(lines), "trailing blank line(s) at end of file"))
for i, l in enumerate(lines[:limit], 1):
    if l.startswith("---") and l != SEP:
        bad.append((i, f"separator is {len(l)} dashes, must be exactly 67"))
    if l != l.rstrip():
        bad.append((i, "trailing whitespace"))
    if l == SEP:
        if i >= len(lines) or not HDR.match(lines[i]):
            bad.append((i + 1, "separator not followed by a valid "
                        "'Day Mon DD HH:MM:SS UTC YYYY - Name <email>' header"))
        elif " - <" in lines[i]:
            bad.append((i + 1, "bare email in author field — use 'Name <email>'"))
        elif me:
            who = lines[i].split(" - ", 1)[1]
            m = WHO.match(who)
            name, mail = m.groups() if m else ("", "")
            same_name, same_mail = name == me_name, mail.lower() == me_mail.lower()
            if (same_name or same_mail) and not (same_name and same_mail):
                bad.append((i + 1, f"author '{who}' is not what osc vc writes ('{me}'): "
                            "use the same name and address"))
        if i + 1 < len(lines) and lines[i + 1].strip() != "":
            bad.append((i + 2, "missing blank line after the entry header"))
        if i > 1 and lines[i - 2].strip() != "":
            bad.append((i - 1, "missing blank line before the separator"))
    elif l.strip() and not HDR.match(l) and not l.startswith(("-", " ", "\t")) and i > 1:
        bad.append((i, f"top-level line is neither bullet nor continuation: {l[:50]!r}"))
# entry-level content check: reject a bare 'Update to <version>' with no summary
UPD = re.compile(r"^-\s*update to\b", re.I)
NOCHG = re.compile(r"no (?:user[- ]?visible|consumer[- ]?relevant|visible) change", re.I)
CVE = re.compile(r"\bCVE-\d{4}-\d{4,}\b", re.I)
UNFIXED = re.compile(
    r"\bnot\s+(?:yet\s+)?(?:fixed|addressed|patched)\b|\bunfixed\b|\bunpatched\b"
    r"|\bstill\s+(?:vulnerable|affected)\b|\btracked\s+separately\b"
    r"|\b(?:does|did|do)(?:\s+not|n['’]t)\s+(?:yet\s+)?(?:fix|address)\b"
    r"|\b(?:is|are|was|were)n['’]t\s+(?:yet\s+)?(?:fixed|addressed|patched)\b"
    r"|\bremains?\s+(?:open|unfixed|unpatched|vulnerable)\b", re.I)
# "Fix CVE-1 and CVE-2" / "CVE-1: fixed" state a fix; "did not fix CVE-1" does not
FIXES = re.compile(r"\b(?:fix(?:es|ed|ing)?|address(?:es|ed|ing)?)(?:\s+[^\s.;]+){0,3}?\s+\(?"
                   r"(?P<ids>CVE-\d{4}-\d{4,}(?:\)?(?:\s*,\s*|\s+and\s+)\(?CVE-\d{4}-\d{4,})*)", re.I)
FIXED = re.compile(r"(?P<id>CVE-\d{4}-\d{4,})\)?:?\s+(?:is\s+|was\s+|now\s+)?(?:fixed|addressed)\b", re.I)
NEGATED = re.compile(r"(?:\bnot|n['’]t|\bnever)\s+(?:yet\s+)?$", re.I)
PATCHED = re.compile(r"(CVE-\d{4}-\d{4,})[^\s,;()]*\.(?:patch|diff|dif)\b", re.I)  # named for the fix
REQUEST_ID = re.compile(r"\b(?:sr|rq|request)\s*#?\s*\d{6,}\b", re.I)
UPSTREAM_PR = re.compile(r"\b(?:pull|merge)[\s-]*$", re.I)    # "pull request #N" is upstream's
STAGING = re.compile(r"\b(?:lands?|landing|goes\s+in)\s+(?:after|before|together)\b"
                     r"|\bstage[ds]?\s+(?:together|after|before)\b", re.I)
def names_request(t):
    return bool(STAGING.search(t)) or any(not UPSTREAM_PR.search(t[:m.start()])
                                          for m in REQUEST_ID.finditer(t))
def stated_fixed(t):
    ids = {m.group("id").upper() for m in FIXED.finditer(t)}
    ids.update(i.upper() for i in PATCHED.findall(t))
    for m in FIXES.finditer(t):
        if not NEGATED.search(t[:m.start()]):
            ids.update(i.upper() for i in CVE.findall(m.group("ids")))
    return ids
ncheck = len(seps) if nent == 0 else min(nent, len(seps))
for k in range(ncheck):
    hdr0 = seps[k]                      # 0-indexed entry header line
    body_end = (seps[k + 1] - 1) if (k + 1) < len(seps) else len(lines)
    body = [(hdr0 + 1 + off + 1, t)     # (1-indexed line no, text)
            for off, t in enumerate(lines[hdr0 + 1:body_end]) if t.strip()]
    if not body:
        bad.append((hdr0 + 1, "entry has no body — describe the change"))
        continue
    has_update = any(UPD.match(t.strip()) for _, t in body)
    other = [t for _, t in body if not UPD.match(t.strip())]
    has_nochange = any(NOCHG.search(t) for _, t in body)
    if has_update and not other and not has_nochange:
        bad.append((body[0][0],
                    "bare 'Update to <version>' with no summary of upstream "
                    "changes — add substantive bullets, or state "
                    "'* No user-visible changes'"))
    bullets = []                        # (first line no, text joined over continuations)
    for n, t in body:
        if t.strip().startswith(("-", "*", "+")) or not bullets:
            bullets.append((n, t.strip()))
        else:
            bullets[-1] = (bullets[-1][0], bullets[-1][1] + " " + t.strip())
    for n, t in bullets:
        ids = {i.upper() for i in CVE.findall(t)}
        if ids and UNFIXED.search(t) and ids - stated_fixed(t):
            bad.append((n, "bullet names a CVE id as not fixed — if this update fixes it, "
                           "say so without the not-fixed phrase; if it does not, leave the "
                           "id out (any CVE id in .changes reads as fixed here)"))
        if names_request(t):
            bad.append((n, "bullet names a submit request or a staging order — put it in "
                           "the SR message (- Stage with sr#N), not in .changes"))
for i, msg in sorted(set(bad)):
    print(f"{f}:{i}: {msg}")
sys.exit(1 if bad else 0)
PY
done
[ $unreadable = 0 ] || exit 3
[ $rc -eq 0 ] && echo "OK: clean"
exit $rc
