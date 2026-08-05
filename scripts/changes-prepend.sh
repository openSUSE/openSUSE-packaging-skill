#!/bin/bash
# Prepend a .changes entry as a VERIFIED insertion — mechanizes the
# prepend-is-insertion HARD RULE (SKILL.md "Adding a .changes entry"). The
# truncate-then-read one-liner trap (open(f,"w").write(hdr+open(f).read()))
# silently dropped ALL entries in three fastmcp-cone .changes files and earned
# three real reviewer declines; this makes that failure class impossible in
# scripted/unattended runs.
#
# Usage: changes-prepend.sh <name>.changes [--author 'Full Name <email>']
#   The bullet body comes on STDIN (already wrapped at 67 cols, '-'/'*' bullets).
#   --author falls back to $CHANGES_AUTHOR, then to git config
#   user.name/user.email — always the full 'Name <email>' form, never a bare
#   email. Prefer CHANGES_AUTHOR: your packaging address is often NOT your git
#   commit address. With none of the three available the script exits 2 rather
#   than guessing.
#
# Behavior: backs the file up, builds the canonical header (67-dash separator +
# `LC_ALL=C date -u` + ' - ' + author), inserts separator+header+blank+body+blank
# ABOVE the current first separator, then HARD-verifies before declaring success:
#   * separator count == old count + 1 exactly
#   * every pre-existing line still present, in order (insertion-only diff —
#     checked as byte-identical old content at the tail)
#   * the previous top entry's header line is byte-identical
# On any verification failure the backup is restored, the discrepancy printed,
# and the exit is 1. Exit 0 only on verified success.
set -euo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,25p' "$0"; exit 0;;
  '') sed -n '2,25p' "$0"; exit 2;;
esac

file="" ; author=""
while [ $# -gt 0 ]; do
  case "$1" in
    --author) author="$2"; shift 2;;
    -*) echo "unknown arg: $1" >&2; exit 2;;
    *) if [ -z "$file" ]; then file="$1"; else echo "unexpected arg: $1" >&2; exit 2; fi; shift;;
  esac
done

# Resolve the author without baking a person into the script.
#   1. --author
#   2. $CHANGES_AUTHOR
#   3. git config user.name/user.email
# Prefer $CHANGES_AUTHOR over git: the packaging identity in a .changes entry is
# frequently NOT the git commit identity (a distribution address vs a personal
# one), and silently inheriting the git email puts the wrong address in the
# changelog — which reviewers do bounce. Set it once in your shell profile:
#   export CHANGES_AUTHOR='Full Name <you@distro.example>'
if [ -z "$author" ]; then
  if [ -n "${CHANGES_AUTHOR:-}" ]; then
    author="$CHANGES_AUTHOR"
  else
    _n=$(git config user.name  2>/dev/null || true)
    _e=$(git config user.email 2>/dev/null || true)
    if [ -n "$_n" ] && [ -n "$_e" ]; then
      author="$_n <$_e>"
      echo "note: using git identity '$author'; set CHANGES_AUTHOR if your" >&2
      echo "      packaging address differs from your git commit address" >&2
    else
      echo "no --author given, CHANGES_AUTHOR unset, and git config" >&2
      echo "user.name/user.email is not set; pass --author 'Full Name <email>'" >&2
      exit 2
    fi
  fi
fi
[ -n "$file" ] || { sed -n '2,25p' "$0"; exit 2; }
case "$author" in
  *"<"*"@"*">"*) : ;;
  *) echo "--author must be the full 'Full Name <email>' form, got: $author" >&2; exit 2;;
esac

body="$(cat)"   # the bullets, from stdin
[ -n "$body" ] || { echo "empty body on stdin — nothing to add" >&2; exit 2; }

sep="$(printf -- '-%.0s' $(seq 67))"
stamp="$(LC_ALL=C date -u '+%a %b %e %H:%M:%S UTC %Y')"

# back up first (same-dir mktemp copy so a restore is a rename, not a copy
# across filesystems)
if [ -f "$file" ]; then
  bak="$(mktemp "$(dirname "$file")/.$(basename "$file").bak.XXXXXX")"
  cp -p "$file" "$bak"
else
  bak=""   # new file (a brand-new package's first entry)
  : > "$file"
fi

restore() { [ -n "$bak" ] && mv -f "$bak" "$file"; }

rc=0
FILE="$file" SEP="$sep" STAMP="$stamp" AUTHOR="$author" BODY="$body" python3 - <<'PYEOF' || rc=$?
import os, sys
f      = os.environ["FILE"]
sep    = os.environ["SEP"]
stamp  = os.environ["STAMP"]
author = os.environ["AUTHOR"]
body   = os.environ["BODY"].rstrip("\n")

old = open(f, encoding="utf-8", errors="surrogateescape").read()
old_seps = sum(1 for l in old.split("\n") if l == sep)
old_top_header = None
lines = old.split("\n")
for i, l in enumerate(lines):
    if l == sep and i + 1 < len(lines):
        old_top_header = lines[i + 1]
        break

block = f"{sep}\n{stamp} - {author}\n\n{body}\n\n"
new = block + old

# write as TWO separate steps on a distinct object — never a truncate-then-read
with open(f, "w", encoding="utf-8", errors="surrogateescape") as out:
    out.write(new)

# ---- HARD verification -------------------------------------------------------
back = open(f, encoding="utf-8", errors="surrogateescape").read()
errs = []
new_seps = sum(1 for l in back.split("\n") if l == sep)
if new_seps != old_seps + 1:
    errs.append(f"separator count {old_seps} -> {new_seps}, expected {old_seps + 1}")
if not back.endswith(old):
    errs.append("pre-existing content is NOT byte-identical at the tail (not an insertion-only change)")
if old_top_header is not None:
    tail_lines = back[len(block):].split("\n")
    prev_hdr = None
    for i, l in enumerate(tail_lines):
        if l == sep and i + 1 < len(tail_lines):
            prev_hdr = tail_lines[i + 1]
            break
    if prev_hdr != old_top_header:
        errs.append(f"previous top entry header changed: {old_top_header!r} -> {prev_hdr!r}")
if errs:
    for e in errs:
        sys.stderr.write(f"VERIFY FAILED: {e}\n")
    sys.exit(1)
print(f"separators {old_seps} -> {new_seps}, previous top entry intact, insertion-only diff OK")
PYEOF
if [ $rc -ne 0 ]; then
  restore
  echo "verification failed — original $file restored from backup" >&2
  exit 1
fi
[ -n "$bak" ] && rm -f "$bak"
exit 0
