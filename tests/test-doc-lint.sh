#!/bin/bash
# test-doc-lint.sh — the prose must not undo the token diet. Fails when:
#   - any doc tells an agent to read a reference "whole / in full / entirely"
#     (a read verb within 60 chars of such a qualifier), or to "read SKILL.md"
#   - a `references/<file>.md "<Section>"` pointer in SKILL.md, agents/ or
#     references/ does not resolve through scripts/refsection.py (exit != 0)
# Exit 0 = clean; 1 = findings (file:line: message).
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom, not a broken if/then/else: pass and fail both return 0 (verified), so exactly
# one verdict is ever printed, including at the inverted `&& fail || pass` sites.
# shellcheck disable=SC2181  # rc is captured once with rc=$? and then asserted on
# several times; `if cmd; then` cannot express that.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../skills/opensuse-packaging" && pwd)"
RS="$ROOT/scripts/refsection.py"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }

# a read verb whose OBJECT is a doc (reference / SKILL.md / playbook / file) with a
# whole-file qualifier, in either order; negations and descriptions of the
# anti-pattern ("never read … whole", "a whole-file Read burns …") are excluded.
DOC='(references?/[a-z-]+\.md|SKILL\.md|references?( files?)?|playbooks?|the (whole|entire) (file|reference|doc))'
Q='(in full|whole|entire(ly)?|fully)'
PAT="\b[Rr]ead(s|ing)?\b[^.;:]{0,40}${DOC}[^.;:]{0,40}\b${Q}\b|\b[Rr]ead(s|ing)?\b[^.;:]{0,60}\b${Q}\b[^.;:]{0,40}${DOC}|\b${Q}\b[^.;:]{0,30}${DOC}[^.;:]{0,30}\b[Rr]ead\b"
# self-test: the pattern must catch a real offender and pass a benign line,
# else the lint is a no-op and reports clean for the wrong reason
probe=$(mktemp)
# shellcheck disable=SC2016  # the backticks are literal markdown in the probe text,
# not command substitution; the string must reach grep exactly as a doc would write it.
printf 'Before starting, read references/update-build.md in full.\nread `references/specfile-guidelines.md` whole first\nre-read the whole manifest before trusting it\n' > "$probe"
n=$(grep -c -E "$PAT" "$probe"); rm -f "$probe"
[ "$n" -eq 2 ] && pass "lint pattern self-test (2 offenders caught, 1 benign passed)" || fail "lint pattern self-test caught $n of 2 — the regex is broken, nothing below is trustworthy"
hits=$(grep -rn -E "$PAT" "$ROOT/SKILL.md" "$ROOT/agents" "$ROOT/references" 2>/dev/null \
       | grep -v -i -E 'never|not |no |instead|defect|burns|spends|rather than|do not|don.t|regression')
if [ -n "$hits" ]; then fail "whole-file read instruction:"; printf '%s\n' "$hits" | sed "s|$ROOT/||; s/^/    /" | head -10; else pass "no whole-file read instruction"; fi

ok=0; bad=0
while IFS=$'\t' read -r file sec src; do
  if python3 "$RS" "$file" "$sec" >/dev/null 2>&1; then ok=$((ok+1)); else bad=$((bad+1)); printf '    %s: unresolved %s "%s"\n' "$src" "$file" "$sec"; fi
done < <(python3 - "$ROOT" <<'PY'
import re, sys, os
root = sys.argv[1]
docs = [os.path.join(root, 'SKILL.md')] + sorted(
    os.path.join(root, d, f) for d in ('agents', 'references') for f in os.listdir(os.path.join(root, d)) if f.endswith('.md'))
for doc in docs:
    for ln, line in enumerate(open(doc, encoding='utf-8'), 1):
        for m in re.finditer(r'`((?:references|scripts|agents)/[A-Za-z0-9_.-]+\.md)`((?:\s*,?\s*"[^"]+")+)', line):
            for sec in re.findall(r'"([^"]+)"', m.group(2)):
                print(f"{m.group(1)}\t{sec}\t{os.path.relpath(doc, root)}:{ln}")
PY
)
[ $bad -eq 0 ] && pass "pointers: $ok resolve" || fail "pointers: $bad of $((ok+bad)) unresolved"
[ $fails -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
