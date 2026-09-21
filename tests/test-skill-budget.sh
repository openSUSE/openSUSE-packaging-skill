#!/bin/bash
# test-skill-budget.sh — the token budget as a build constraint. SKILL.md is
# injected whole on every trigger (and the loader truncates a body past
# ~51,200 B), so its size is a correctness property, not taste. Fails when:
#   - the body (after the frontmatter) exceeds 40,000 B
#   - the frontmatter exceeds 500 B (its description is in EVERY system prompt)
#   - any body line exceeds 1,600 B — knowledge appended inside a bullet is how
#     the file grew from 20 KB to 54 KB; put detail in a reference and point
#   - any reference exceeds 60,000 B, or is > 300 lines without a `## Contents`
# Exit 0 = within budget; 1 = over, with the offending numbers.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../skills/opensuse-packaging" && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }

python3 - "$ROOT/SKILL.md" <<'PY' || fails=$((fails+1))
import sys
raw = open(sys.argv[1], 'rb').read()
parts = raw.split(b'---', 2)
fm, body = (parts[1], parts[2]) if len(parts) == 3 else (b'', raw)
bad = []
if len(body) > 40000: bad.append(f"body {len(body):,} B > 40,000")
if len(fm) > 500: bad.append(f"frontmatter {len(fm):,} B > 500")
longest = max((len(l), i) for i, l in enumerate(body.splitlines(), 1))
if longest[0] > 1600: bad.append(f"line {longest[1]} is {longest[0]:,} B > 1,600")
print(("FAIL: " + "; ".join(bad)) if bad else
      f"PASS: SKILL.md body {len(body):,} B, frontmatter {len(fm)} B, longest line {longest[0]:,} B")
sys.exit(1 if bad else 0)
PY

for f in "$ROOT"/references/*.md; do
  b=$(wc -c < "$f"); l=$(wc -l < "$f"); n=$(basename "$f")
  [ "$b" -le 60000 ] || fail "$n is $b B > 60,000"
  if [ "$l" -gt 300 ] && ! grep -q '^## Contents' "$f"; then fail "$n has $l lines and no '## Contents'"; fi
done
[ $fails -eq 0 ] && pass "references: all ≤ 60,000 B, Contents present where > 300 lines"
[ $fails -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
