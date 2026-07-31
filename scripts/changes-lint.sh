#!/bin/bash
# Lint a .changes file for the format problems reviewers decline over —
# the whole-file companion to changes-prepend.sh (which only verifies its
# own insertion). Run as part of the Block-3 pre-SR gate: a human reviewer
# decline for "format of the changes entries" (real case: python-langsmith
# a real decline over "missing newlines") costs a full review round-trip
# that this catches locally in milliseconds.
#
# Usage: changes-lint.sh [--entries N | --all] <file>.changes [more.changes ...]
#   --entries N  lint only the N newest (topmost) entries (default: 1 —
#                the entry your SR adds; use the number of entries new
#                to the SR when superseding). Historical entries routinely
#                violate today's rules and must never be retro-edited, so
#                they are out of scope by default.
#   --all        lint every entry + file-global checks (EOF newline,
#                trailing blank lines). For audits, not the gate.
#   Checks per entry:
#     - separators are exactly 67 dashes; entry starts at one
#     - separator followed by 'Day Mon DD HH:MM:SS UTC YYYY - Name <email>'
#     - author is 'Name <email>' form (never a bare email)
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
#   Exit: 0 = clean, 1 = findings (file:line: message), 2 = usage.
set -euo pipefail

entries=1
case "${1:-}" in
  -h|--help|"") sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  --entries) entries=$2; shift 2 ;;
  --all) entries=0; shift ;;
esac

rc=0
for f in "$@"; do
  [ -r "$f" ] || { echo "$f: unreadable" >&2; rc=1; continue; }
  python3 - "$f" "$entries" <<'PY' || rc=1
import re, sys
f, nent = sys.argv[1], int(sys.argv[2])
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
        if i + 1 < len(lines) and lines[i + 1].strip() != "":
            bad.append((i + 2, "missing blank line after the entry header"))
        if i > 1 and lines[i - 2].strip() != "":
            bad.append((i - 1, "missing blank line before the separator"))
    elif l.strip() and not HDR.match(l) and not l.startswith(("-", " ", "\t")) and i > 1:
        bad.append((i, f"top-level line is neither bullet nor continuation: {l[:50]!r}"))
# entry-level content check: reject a bare 'Update to <version>' with no summary
UPD = re.compile(r"^-\s*update to\b", re.I)
NOCHG = re.compile(r"no (?:user[- ]?visible|consumer[- ]?relevant|visible) change", re.I)
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
for i, msg in sorted(set(bad)):
    print(f"{f}:{i}: {msg}")
sys.exit(1 if bad else 0)
PY
done
[ $rc -eq 0 ] && echo "OK: clean"
exit $rc
