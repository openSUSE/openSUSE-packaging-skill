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
#     - no bullet that says an issue is not affected ('not affected', 'is not
#       affected by', 'unaffected', 'no longer affected', 'does not affect',
#       'not vulnerable', 'not impacted', 'above the fixed version', 'above the
#       X.Y fix', 'already fixed in X.Y/upstream') carries a CVE or
#       boo#/bsc#/bnc# id it does not state this update fixes ('… fixes it'
#       and 'above the X fix' beside a version move do); a ':' bullet saying
#       so takes the ids of the bullets it lists (indented under it, or id-led
#       at its own indent), one that opens with the phrase those of its
#       sub-bullets, but a mere scope note in a header leaves its 'CVE-…:'
#       sub-bullets alone. A fix that also says what is not affected — it
#       opens 'CVE-…:', has a fix or bump verb or names a patch — answers only
#       for the ids next to that phrase (an id-led one, for its leading ids
#       when the phrase is in its first clause). The finding names the ids.
#       The Leap, PackageHub and SLFO trackers read any
#       id in .changes as fixed here, so a not-affected assessment goes in the
#       bug comment (references/changelog-rules.md "CVEs and security
#       bullets"; real decline: pool/gh PR #11)
#     - no bullet carries an incomplete CVE id ('CVE-2026-XXXX', 'CVE-2026',
#       'CVE-2026-12'), and no top-level bullet (its sub-bullets included)
#       says 'CVEs'/'CVE' or claims a security fix ('security fix/issue/update
#       ...', 'vulnerability') without a full CVE id — a bug ref (boo#/bsc#)
#       or a GHSA id stands in for the id of a security claim, never of
#       'CVEs' (but it does of 'CVE pending'); a bullet ending in ':' takes
#       its ids from the bullets after it, 'no'/'non-'/'not a'/'without'
#       claims nothing, and patch names, paths and URLs are not read: the
#       security tracker keys off the literal ids
#       (references/changelog-rules.md "CVEs and security bullets")
#     - no bullet names an OBS request ('sr#N', 'SR N', 'rq N', 'request #N')
#       or a staging order ('lands after', 'stage together'): the SR
#       message carries those, the .changes ships in the RPM
#       (references/changelog-rules.md "Curate the entry")
#     - no bullet reports submission or review status ('factory-auto', the
#       source validator or a source-URL validation, the Factory forward),
#       for the same reason
#     - no line is over 67 characters when it could be wrapped there, the
#       .changes convention (references/changelog-rules.md); a word too long
#       for that may run over only on a line of its own
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
import itertools, re, sys
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
# "Fix CVE-1 and CVE-2" / "CVE-1: fixed" state a fix; "did not fix CVE-1" does not.
# A bug ref is stated fixed the same ways: "Fix a crash (boo#1)", "CVE-1 (bsc#1): fixed".
ID = r"(?:CVE-\d{4}-\d{4,}|(?:boo|bsc|bnc)#\d+)"
IDS = ID + r"(?:[\])]?(?:\s*,\s*|\s+and\s+|\s+(?=[\[(]))[\[(]?" + ID + r")*"
RUN = re.compile(IDS, re.I)
# each id list is read once, by what precedes and follows it: linear in a long list
FIX_HEAD = re.compile(r"\b(?:fix(?:es|ed|ing)?|address(?:es|ed|ing)?)(?:\s+[^\s.;]+){0,3}?\s+[\[(]?$", re.I)
FIX_TAIL = re.compile(r"[\])]?:?\s+(?:is\s+|are\s+|was\s+|were\s+|now\s+)?(?:fixed|addressed)\b", re.I)
NEGATED = re.compile(r"(?:\bnot|n['’]t|\bnever)\s+(?:yet\s+)?$", re.I)
PATCHED = re.compile(r"(CVE-\d{4}-\d{4,}|(?:boo|bsc|bnc)#?\d+)[^\s,;()]*\.(?:patch|diff|dif)\b", re.I)  # named for the fix
# a CVE id cut short or left as a placeholder: CVE-2026-XXXX, CVE-2026, CVE-2026-12
PARTIAL = re.compile(r"\bCVE-(?:\d{4}-(?!\d{4})\S*|\d{4}\b(?!-)|(?!\d{4}-)[^\s,;)]+)", re.I)
BARE_CVE = re.compile(r"\bCVEs?\b(?!-)", re.I)
SECURITY = re.compile(r"\bsecurity[\s-]+(?:fix(?:es|ed)?|issues?|bugs?|problems?|flaws?|"
                      r"vulnerabilit(?:y|ies)|updates?|releases?)\b|\bvulnerabilit(?:y|ies)\b", re.I)
REFS = re.compile(r"\b(?:boo|bsc|bnc)#\d+|\bGHSA(?:-[0-9a-z]{4}){3}\b", re.I)
NO_CLAIM = re.compile(r"(?:\bno|\bnon|\bnot(?:\s+an?)?|\bwithout(?:\s+any)?)[\s-]*$", re.I)
PENDING_CVE = re.compile(r"\s+(?:pending|requested|not\s+(?:yet\s+)?assigned|to\s+be\s+assigned)\b", re.I)
NAMES = re.compile(r"\S+\.(?:patch|diff|dif)\b|\S+/\S+")  # patch names, paths and URLs
def claims(rx, t, refs=False):
    """A security claim in t: not negated ("no security fixes", "non-security
    fix", "no CVE assigned"), and with refs not a "CVE pending" beside its
    GHSA or bug ref."""
    return any(not NO_CLAIM.search(t[:m.start()])
               and not (refs and PENDING_CVE.match(t, m.end()))
               for m in rx.finditer(t))
REQUEST_ID = re.compile(r"\b(?:sr|rq|request)\s*#?\s*\d{6,}\b", re.I)
UPSTREAM_PR = re.compile(r"\b(?:pull|merge)[\s-]*$", re.I)    # "pull request #N" is upstream's
# Review and bot status (factory-auto, the source validator, a Factory forward)
REVIEW = re.compile(r"\bfactory-auto\b|\bsource[-_ ]?(?:url[-_ ]?)?validat"
                    r"|\bfactory\s+forward|\bforward(?:ed|ing)?\s+to\s+(?:openSUSE:)?factory\b", re.I)
STAGING = re.compile(r"\b(?:lands?|landing|goes\s+in)\s+(?:after|before|together)\b"
                     r"|\bstage[ds]?\s+(?:together|after|before)\b", re.I)
def names_request(t):
    return bool(STAGING.search(t)) or any(not UPSTREAM_PR.search(t[:m.start()])
                                          for m in REQUEST_ID.finditer(t))
NOTAFF_RX = (r"\b(?:not|never|no\s+longer)[\s-]+(?:be\s+)?affected\b|n['’]t\s+(?:be\s+)?affected\b|\bunaffected\b"
             r"|\b(?:does|do|did)(?:\s+not|n['’]t)\s+affect\b|\bnot\s+vulnerable\b|n['’]t\s+vulnerable\b"
             r"|\bnot\s+impacted\b|n['’]t\s+impacted\b"
             r"|\babove\s+the\s+(?:\S+\s+)?(?:fix(?:ed)?\b|patched\b)"
             r"|\balready\s+fixed\s+(?:upstream\b|(?:in|by)\s+(?:\S+\s+){0,2}?v?\d)")
NOTAFF = re.compile(NOTAFF_RX, re.I)
KEEP = re.compile(r"\b(?:keep|keeps|kept|keeping|leave|leaves|leaving)\s+(?:\S+\s+){0,3}?unaffected\b", re.I)
FLOOR = re.compile(r"\bfixed\s+(?:upstream\b|(?:in|since|as\s+of)\s+(?:\S+\s+)?v?\d)", re.I)  # the upstream fix, not this one
ANYID = re.compile(r"\bCVE-\d{4}-\d{4,}\b|\b(?:boo|bsc|bnc)#\d+", re.I)
LEAD_ID = re.compile(r"^[-*+]\s+[\[(]?" + ID, re.I)
NA_OPEN = re.compile(r"^[-*+]\s+(?:(?:is|are|was|were|still)\s+)*(?:" + NOTAFF_RX + ")", re.I)
ID_LEAD = re.compile(r"^[-*+]\s+" + ID + r"\b(?!\s*:)", re.I)   # id-led, but not the 'CVE-…:' fix layout
FIX_LAYOUT = re.compile(r"^[-*+]\s+CVE-\d{4}-\d{4,}:", re.I)
FIX_VERB = re.compile(r"(?<!\bthe )(?<!\ba )(?<!\bthat )(?<!\bthis )(?<!\bits )\b(?:fix(?:es|ed|ing)?|"
                      r"address(?:es|ed|ing)?|resolv(?:e|es|ed|ing)|patch(?:es|ed|ing)?|backport(?:s|ed|ing)?|"
                      r"clos(?:e|es|ed|ing)|mitigat(?:e|es|ed|ing)|prevent(?:s|ed|ing)?|reject(?:s|ed|ing)?|"
                      r"harden(?:s|ed|ing)?|saniti[sz](?:e|es|ed|ing))\b", re.I)
# a version move: "above the X fix" beside one is how a fixing bump reads
BUMP = re.compile(r"\b(?:updat(?:e|es|ed|ing)|bump(?:s|ed|ing)?|upgrad(?:e|es|ed|ing))\b|->|→|\bto\s+v?\d+(?:\.\d+)+", re.I)
# "…, so this update fixes it": the ids before it are fixed. Never "upstream 1.2 fixed it".
THIS_FIX = re.compile(r"\bthis\s+(?:update|release|version|bump|upgrade)\s+(?:also\s+)?"
                      r"(?:fix(?:es|ed)?|address(?:es|ed)?|resolv(?:es|ed)|clos(?:es|ed))\s+(?:it|them|both)\b"
                      r"|\bfixed\s+by\s+this\s+(?:update|release|version|bump|upgrade)\b", re.I)
CLAUSE = re.compile(r";|\.\s")
PATCH_NAME = re.compile(r"\S\.(?:patch|diff|dif)\b", re.I)
NEAR = re.compile(r"\s+(?:by|to)\s+[\[(]?(?P<ids>" + IDS + ")", re.I)
FLOOR_IDS = re.compile(r"(?:\s+versions?)?\s*[\[(](?P<ids>" + IDS + ")", re.I)
LISTS = re.compile(r"(?:\s*[^\s:;]+){0,2}?\s*:")   # "not affected here: CVE-1 (boo#1), CVE-2 …"
# a header whose list is what is not affected: "… not affected by:", "the following are not affected:"
BY_LIST = re.compile(r"\s+(?:by|to)(?:\s+the\s+following)?\s*:$", re.I)
WHO_LIST = re.compile(r"\b(?:the\s+following|these|those)\b[^;,]*$", re.I)
def lists_lead(t, hits):
    return t.endswith(":") and any(BY_LIST.match(t, m.end()) or (re.match(r"\s*:$", t[m.end():])
                                   and WHO_LIST.search(t, 0, m.start())) for m in hits)
def norm(i):
    i = i.upper()
    return i if i.startswith("CVE") or "#" in i else i[:3] + "#" + i[3:]
def stated_fixed(t):
    ids = {norm(i) for i in PATCHED.findall(t)}
    for r in RUN.finditer(t):
        head = t[max(0, r.start() - 200):r.start()]
        h = FIX_HEAD.search(head)
        if FIX_TAIL.match(t, r.end()) or (h and not NEGATED.search(head[:h.start()])):
            ids.update(norm(i) for i in ANYID.findall(r.group()))
    return ids
def plain(t):
    """t without its not-affected wording and upstream fix floors, neither a fix statement"""
    return FLOOR.sub(" ", NOTAFF.sub(" ", KEEP.sub(" ", t)))
def clause(t, m):
    a = max((c.end() for c in CLAUSE.finditer(t, 0, m.start())), default=0)
    z = CLAUSE.search(t, m.end())
    return t[a:z.start() if z else len(t)]
def floor_claim(m):
    """'above the fixed version': a not-affected claim even beside a bump, unlike 'above the X fix'"""
    return re.search(r"(?:fixed|patched)$", m.group(), re.I)
def moved(t):
    """the clauses where 'above the X fix' sits beside a version move: a fix, not a claim"""
    return [c for m in NOTAFF.finditer(t) if m.group().lower().startswith("above") and not floor_claim(m)
            for c in [clause(t, m)] if BUMP.search(c)]
def fixed_here(t, own=True):
    """the ids t states this update fixes; under a not-affected opening (own=False)
    only a fix that names its id counts"""
    q = plain(t)
    ids = stated_fixed(q)
    if own:
        for m in THIS_FIX.finditer(q):
            if not NEGATED.search(q[max(0, m.start() - 40):m.start()]):
                ids.update(norm(i) for i in ANYID.findall(q[:m.start()]))
        ids.update(norm(i) for c in moved(t) for i in ANYID.findall(c))
    return ids
def about(t, m, lead=False):
    """The ids the not-affected phrase m names: just before it in its clause, or after it;
    in an id-led bullet's first clause, the ids that lead it."""
    if lead and not CLAUSE.search(t, 0, m.start()):
        ids = ANYID.findall(t[:m.start()])
    else:
        ids = ANYID.findall(" ".join(re.split(r"[;,]|\.\s", t[:m.start()])[-1].split()[-3:]))
    near, lists = NEAR.match(t, m.end()), LISTS.match(t, m.end())
    if floor_claim(m):                  # "above the fixed version (CVE-1, bsc#1)"
        near = near or FLOOR_IDS.match(t, m.end())
    if near:
        ids += ANYID.findall(near.group("ids"))
    if lists:
        ids += ANYID.findall(re.split(r";|\.\s", t[lists.end():])[0])
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
    for n, t in body:                   # .changes wraps at 67; one unbreakable word may overrun
        words = t.split()
        lead = len(t) - len(t.lstrip()) + (2 if words[0] in ("-", "*", "+") else 0)
        text = words[1:] if words[0] in ("-", "*", "+") else words
        # a word too long for 67 excuses the line only when it is all of it:
        # anything before it could have broken onto a line of its own
        if len(t) > 67 and not (len(text) == 1 and len(text[0]) + lead > 67):
            bad.append((n, f"line is {len(t)} characters: wrap it at 67, the .changes convention"))
    bullets = []                        # (first line no, text joined over continuations, indent)
    for n, t in body:
        if t.strip().startswith(("-", "*", "+")) or not bullets:
            bullets.append((n, t.strip(), len(t) - len(t.lstrip())))
        else:
            bullets[-1] = (bullets[-1][0], bullets[-1][1] + " " + t.strip(), bullets[-1][2])
    for b, (n, t, ind) in enumerate(bullets):
        ids = {i.upper() for i in CVE.findall(t)}
        if ids and UNFIXED.search(t) and ids - stated_fixed(t):
            bad.append((n, "bullet names a CVE id as not fixed — if this update fixes it, "
                           "say so without the not-fixed phrase; if it does not, leave the "
                           "id out (any CVE id in .changes reads as fixed here)"))
        tk = KEEP.sub(" ", t)
        na_open = NA_OPEN.match(tk)
        hits = list(NOTAFF.finditer(tk))
        if hits:
            sub = [x for _, x, i in itertools.takewhile(lambda y: y[2] > ind, bullets[b + 1:])]
            if not sub and t.endswith(":"):   # a ':' list at the header's own indent
                sub = [x for _, x, i in itertools.takewhile(
                    lambda y: y[2] == ind and LEAD_ID.match(y[1]), bullets[b + 1:])]
            if not (na_open or lists_lead(tk, hits)):   # a scope note leaves its fix sub-bullets alone
                sub = [x for x in sub if not FIX_LAYOUT.match(x) or NOTAFF.search(KEEP.sub(" ", x))]
            lead = ID_LEAD.match(tk)
            # a fix that also says what is not affected names only the ids next to that phrase
            if not na_open and (FIX_LAYOUT.match(t) or PATCH_NAME.search(t)
                                or FIX_VERB.search(plain(t)) or BUMP.search(plain(t))):
                pieces = [t] + (sub if t.endswith(":") and NOTAFF.search(tk.rsplit(")", 1)[-1]) else [])
                cited = [i for m in hits for i in about(tk, m, lead)] + ANYID.findall(" ".join(pieces[1:]))
            else:
                pieces = [t] + (sub if t.endswith(":") or na_open or lead else [])
                cited = ANYID.findall(" ".join(pieces))
            fixed = fixed_here(t, not na_open).union(*(fixed_here(p, not na_open) for p in pieces[1:]))
            left = {}
            for i in cited:
                if norm(i) not in fixed:
                    left.setdefault(norm(i), i)
            if left:
                bad.append((n, f"bullet cites an id for an issue it says is not affected ({', '.join(left.values())}) — "
                               "the trackers read any CVE/boo#/bsc#/bnc# in .changes as fixed here; put "
                               "the assessment in the bug comment (references/changelog-rules.md "
                               '"CVEs and security bullets")'))
        if REVIEW.search(t):
            bad.append((n, "bullet reports submission or review status — that goes in the "
                           "SR message, not in .changes, which ships in the RPM"))
        if names_request(t):
            bad.append((n, "bullet names a submit request or a staging order — put it in "
                           "the SR message (- Stage with sr#N), not in .changes"))
        cut = PARTIAL.search(t)
        if cut:
            bad.append((n, f"bullet has an incomplete CVE id ({cut.group(0)!r}) — cite the "
                           "full CVE-YYYY-NNNN, or leave it out"))
    groups = []                         # top-level '-' bullet with its sub-bullets
    for n, t in body:
        if t.startswith("-") or not groups:
            groups.append((n, t.strip()))
        else:
            groups[-1] = (groups[-1][0], groups[-1][1] + " " + t.strip())
    for g, (n, t) in enumerate(groups):
        if CVE.search(t) or PARTIAL.search(t):
            continue
        # "fixes the following two security issues:" lists its CVEs below
        if t.endswith(":") and any(CVE.search(x) for _, x in groups[g + 1:]):
            continue
        words, refs = NAMES.sub(" ", t), bool(REFS.search(t))
        if claims(BARE_CVE, words, refs) or (claims(SECURITY, words) and not refs):
            bad.append((n, "bullet claims security fixes without a full CVE id — cite "
                           "each CVE-YYYY-NNNN (with its boo#/bsc#), or describe the fix "
                           "itself without the security claim"))
for i, msg in sorted(set(bad)):
    print(f"{f}:{i}: {msg}")
sys.exit(1 if bad else 0)
PY
done
[ $unreadable = 0 ] || exit 3
[ $rc -eq 0 ] && echo "OK: clean"
exit $rc
