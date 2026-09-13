#!/bin/bash
# measure-reads.sh — how much of this skill a set of sessions actually loaded.
# Manual tool, not CI: run it before and after a token-diet change, or after a
# fan-out, and compare with tests/token-baseline.md. Reads Claude Code session
# transcripts (JSONL) and counts, per skill file, Read tool calls (full vs
# windowed), Skill-tool invocations, and Agent fan-outs by subagent type.
#
# Usage: measure-reads.sh [-n N] [transcript.jsonl ...]
#   -n N   use the N most recent transcripts of the current project (default 15)
#   files  explicit transcripts (e.g. subagent .output files) instead of -n
# The skill directory is derived from this script's location; transcripts
# default to ~/.claude/projects/<current-project>/ (Claude Code's layout).
# Token estimates are bytes/4; a windowed Read is priced as limit × bytes-per-line/4.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd -P)"
n=15
[ "${1:-}" = "-n" ] && { n=$2; shift 2; }
if [ $# -gt 0 ]; then
  files=("$@")
else
  proj="$HOME/.claude/projects/$(pwd | sed 's|/|-|g')"
  [ -d "$proj" ] || { echo "no transcript dir $proj (run from the project dir, or pass files)" >&2; exit 2; }
  mapfile -t files < <(ls -t "$proj"/*.jsonl 2>/dev/null | head -n "$n")
fi
[ ${#files[@]} -gt 0 ] || { echo "no transcripts" >&2; exit 2; }

python3 - "$SKILL" "${files[@]}" <<'PY'
import json, os, re, sys, collections
skill = sys.argv[1]; files = sys.argv[2:]
size = {}
for root, _, names in os.walk(skill):
    if '/.git' in root or '__pycache__' in root: continue
    for nm in names:
        p = os.path.join(root, nm)
        try: b = open(p, 'rb').read()
        except OSError: continue
        size[os.path.relpath(p, skill)] = (len(b), max(1, b.count(b'\n')))
reads = collections.defaultdict(lambda: [0, 0, 0.0, set()])   # full, partial, tokens, sessions
skill_calls = collections.Counter(); agents = collections.Counter()
for f in files:
    sess = os.path.basename(f).split('.')[0]
    for line in open(f, encoding='utf-8', errors='replace'):
        if '"name":"Read"' in line and skill in line:
            for m in re.finditer(r'"name":"Read","input":(\{[^}]*\})', line):
                try: inp = json.loads(m.group(1))
                except ValueError: continue
                fp = inp.get('file_path', '')
                if not fp.startswith(skill): continue
                rel = os.path.relpath(fp, skill); by, ln = size.get(rel, (0, 1))
                r = reads[rel]; r[3].add(sess)
                if 'limit' in inp:
                    r[1] += 1; r[2] += int(inp['limit']) * (by / ln) / 4
                else:
                    r[0] += 1; r[2] += by / 4
        if '"name":"Skill"' in line:
            skill_calls[sess] += len(re.findall(r'"skill":"openSUSE-packaging"', line))
        if '"name":"Agent"' in line:
            for m in re.finditer(r'"subagent_type":"([^"]*)"', line): agents[m.group(1)] += 1
print(f"transcripts: {len(files)}   SKILL.md: {size.get('SKILL.md',(0,0))[0]:,} B ≈ {size.get('SKILL.md',(0,0))[0]//4:,} tok")
print(f"{'file':44} {'full':>4} {'part':>4} {'sess':>4} {'~tok':>8}")
for rel, (fu, pa, tok, ss) in sorted(reads.items(), key=lambda kv: -kv[1][2]):
    print(f"{rel:44} {fu:4} {pa:4} {len(ss):4} {tok:8,.0f}")
print(f"\nSkill invocations: {sum(skill_calls.values())} in {len(skill_calls)} sessions "
      f"→ {sum(skill_calls.values()) * size.get('SKILL.md',(0,0))[0] // 4:,} tok")
print("Agent fan-outs:", dict(agents.most_common()))
PY
