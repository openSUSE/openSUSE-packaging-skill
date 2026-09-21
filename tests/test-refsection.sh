#!/bin/bash
# test-refsection.sh — proves scripts/refsection.py prints exactly ONE section:
# a `##` heading carries its `###` children and stops at the next same-level
# heading, `--list` never mistakes a fenced `# comment` for a heading, an
# ambiguous query exits 2 with the candidates and an unknown one exits 1 with
# the outline, a parent heading beats its own subsections, a section whose name
# starts with "-" is not eaten as an option, and the real docs resolve by
# basename from any cwd (--anchor §-style ids included). Exit 0 = all
# assertions hold. Run from anywhere; paths are self-relative.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom, not a broken if/then/else: pass and fail both return 0 (verified), so exactly
# one verdict is ever printed, including at the inverted `&& fail || pass` sites.
# shellcheck disable=SC2181  # rc is captured once with rc=$? and then asserted on
# several times; `if cmd; then` cannot express that.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RS="$HERE/../skills/opensuse-packaging/scripts/refsection.py"
FIX="$HERE/fixtures/refsection-sample.md"
fails=0
say()  { printf '%s\n' "$*"; }
pass() { say "PASS: $*"; }
fail() { say "FAIL: $*"; fails=$((fails+1)); }

[ -f "$RS" ]  || { say "FAIL: $RS missing"; exit 1; }
[ -x "$RS" ]  || fail "refsection.py is not executable"
[ -f "$FIX" ] || { say "FAIL: fixture refsection-sample.md missing"; exit 1; }

# run from a directory that is NOT the skill root: every path must resolve
# against the script's own location.
cd / || exit 1
out="$(mktemp)"; err="$(mktemp)"
# refsection.py refuses to print a file outside its own checkout, so that
# un-sanitised third-party text cannot be echoed through it. The fixtures live
# in tests/, outside the skill directory, so stage a throwaway skill root that
# contains them and run that copy against them; the real $RS still serves the
# by-basename lookups of the real docs below.
STAGE="$(mktemp -d)"
trap 'rm -f "$out" "$err"; rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/scripts" "$STAGE/references"
cp "$RS" "$STAGE/scripts/refsection.py"
cp "$HERE/fixtures/refsection-sample.md" "$HERE/fixtures/refsection-extra.md" "$STAGE/references/"
SRS="$STAGE/scripts/refsection.py"
FIX="$STAGE/references/refsection-sample.md"

# 1. a ## section prints whole — heading, body, and both ### children — and
#    stops before the next ## heading.
python3 "$SRS" "$FIX" "Alpha section" > "$out" 2> "$err"; rc=$?
if [ $rc -eq 0 ]; then pass "section: exit 0"; else fail "section: rc=$rc ($(head -1 "$err"))"; fi
head -1 "$out" | grep -qxF '## Alpha section' \
    && pass "section: starts at the heading" || fail "section: first line $(head -1 "$out")"
grep -qxF '### Alpha one' "$out" && grep -qxF '### Alpha two' "$out" \
    && pass "section: both ### children included" || fail "section: a ### child is missing"
grep -qF 'Beta body' "$out" \
    && fail "section: leaked into the next ## section" || pass "section: stops before the next ##"
grep -qF '# not a heading' "$out" \
    && pass "section: fenced body printed verbatim" || fail "section: fenced body lost"
tail -1 "$out" | grep -q '.' \
    && pass "section: no trailing blank line" || fail "section: trailing blank line"

# 2. ambiguity -> exit 2, candidates on stderr, nothing on stdout
python3 "$SRS" "$FIX" "Duplicate candidate" > "$out" 2> "$err"; rc=$?
[ $rc -eq 2 ] && pass "ambiguous: exit 2" || fail "ambiguous: rc=$rc"
[ ! -s "$out" ] && pass "ambiguous: stdout empty" || fail "ambiguous: printed a section anyway"
grep -qF 'Duplicate candidate one' "$err" && grep -qF 'Duplicate candidate two' "$err" \
    && pass "ambiguous: both candidates listed on stderr" || fail "ambiguous: candidates not listed"

# 3. no match -> exit 1 and the full heading outline on stderr
python3 "$SRS" "$FIX" "no such section here" > "$out" 2> "$err"; rc=$?
[ $rc -eq 1 ] && pass "no match: exit 1" || fail "no match: rc=$rc"
grep -qF 'Alpha section' "$err" && grep -qF 'Beta section' "$err" \
    && pass "no match: headings listed on stderr" || fail "no match: headings not listed"

# 4. --list is heading-only: the fenced `# comment` lines must not appear
python3 "$SRS" --list "$FIX" > "$out" 2> "$err"; rc=$?
[ $rc -eq 0 ] && pass "--list: exit 0" || fail "--list: rc=$rc"
grep -qF 'not a heading' "$out" \
    && fail "--list: a fenced # line was listed as a heading" \
    || pass "--list: fenced # lines skipped"
[ "$(grep -c . "$out")" -eq 8 ] \
    && pass "--list: exactly the 8 real headings" || fail "--list: $(grep -c . "$out") rows, want 8"
grep -qE '^ +8  ## Alpha section$' "$out" \
    && pass "--list: line number + level + text" || fail "--list: row format wrong"

# 4b. a parent heading beats its own subsections (they print with it anyway),
#     and a section name starting with "-" is not eaten as an option.
python3 "$SRS" "$FIX" "Alpha" > "$out" 2> "$err"; rc=$?
if [ $rc -eq 0 ] && [ "$(head -1 "$out")" = "## Alpha section" ]; then
    pass "parent heading wins over its ### children"
else
    fail "parent heading: rc=$rc, first line $(head -1 "$out")"
fi
for sep in "" "--"; do
    # shellcheck disable=SC2086  # $sep is intentionally unquoted (empty = absent)
    python3 "$SRS" "$FIX" $sep "--dash-flag" > "$out" 2> "$err"; rc=$?
    if [ $rc -eq 0 ] && head -1 "$out" | grep -q '^### --dash-flag'; then
        pass "leading-dash section queryable (sep='$sep')"
    else
        fail "leading-dash (sep='$sep'): rc=$rc, $(head -1 "$err")"
    fi
done

# 5. bold lead-in: its own paragraph only, not the rest of the section
python3 "$SRS" "$FIX" "Bold lead-in" > "$out" 2> "$err"; rc=$?
[ $rc -eq 0 ] && pass "bold lead-in: exit 0" || fail "bold lead-in: rc=$rc ($(head -1 "$err"))"
if [ "$(grep -c . "$out")" -eq 2 ] && ! grep -qF 'Trailing Beta paragraph' "$out"; then
    pass "bold lead-in: stops at the blank line"
else
    fail "bold lead-in: $(grep -c . "$out") lines, ran past the paragraph"
fi

# 6. the real docs, by basename, with the §-anchor form
# real docs, by basename, from a cwd that is not the skill root: the first `##`
# section of a big reference comes back whole and stops before the second `##`
# (headings read from --list, so a reshuffle of the reference cannot break this)
first=$(python3 "$RS" --list update-build.md 2>/dev/null | grep -m1 '## ' | sed 's/^.*## //')
second=$(python3 "$RS" --list update-build.md 2>/dev/null | grep '## ' | sed -n '2p' | sed 's/^.*## //')
python3 "$RS" update-build.md "$first" > "$out" 2> "$err"; rc=$?
[ $rc -eq 0 ] && pass "real doc by basename from /: exit 0" || fail "real doc: rc=$rc ($(head -1 "$err"))"
head -1 "$out" | grep -qF "## $first" \
    && pass "real doc: first ## section returned" || fail "real doc: got $(head -1 "$out")"
[ -n "$second" ] && grep -qF "## $second" "$out" \
    && fail "real doc: ran into the next ## section ($second)" || pass "real doc: stops at the next ##"
rm -f "$out.2"

python3 "$RS" SKILL.md "Core directive" > "$out" 2> "$err"; rc=$?
[ $rc -eq 0 ] && pass "SKILL.md \"Core directive\": exit 0" || fail "SKILL.md: rc=$rc ($(head -1 "$err"))"
head -1 "$out" | grep -qxF '## Core directive' \
    && pass "SKILL.md: heading matched by substring" || fail "SKILL.md: got $(head -1 "$out")"
grep -qF '## Batch processing' "$out" \
    && fail "SKILL.md: ran into the next ## section" || pass "SKILL.md: stops at the next ##"

# 7. --lines prefixes the source line numbers (so the caller can Read for more)
python3 "$SRS" --lines "$FIX" "Alpha section" > "$out" 2>/dev/null
[ "$(head -1 "$out")" = "$(printf '8\t## Alpha section')" ] \
    && pass "--lines: line-number prefix" || fail "--lines: got $(head -1 "$out")"

# 8. unknown doc -> usage/lookup failure, not a traceback
python3 "$RS" no-such-doc.md "x" > "$out" 2> "$err"; rc=$?
[ $rc -eq 3 ] && pass "missing doc: exit 3" || fail "missing doc: rc=$rc"
grep -qF 'Traceback' "$err" && fail "missing doc: traceback leaked" || pass "missing doc: clean error"


# 7-12. second fixture: tiebreaks, case, tilde fences, anchors, H1, unreadable input
X="$STAGE/references/refsection-extra.md"
python3 "$SRS" "$X" "Exact" > "$out" 2> "$err"; rc=$?
[ $rc -eq 0 ] && [ "$(head -1 "$out")" = "## Exact" ] && ! grep -q "Extended body" "$out" \
    && pass "exact heading beats substrings" || fail "exact beats substring: rc=$rc $(head -1 "$out")"
python3 "$SRS" "$X" "exact match EXTENDED" > "$out" 2> "$err"; rc=$?
[ $rc -eq 0 ] && grep -q "Extended body" "$out" && pass "case-insensitive match" || fail "case-insensitive: rc=$rc"
python3 "$SRS" --list "$X" > "$out" 2> "$err"
! grep -q "tilde fence" "$out" && ! grep -q "nospace" "$out" \
    && pass "--list: ~~~ fence and #nospace are not headings" || fail "--list: tilde/nospace leaked"
python3 "$SRS" --anchor "$X" A1 > "$out" 2> "$err"; rc=$?
[ $rc -eq 0 ] && grep -q "A1 body" "$out" && ! grep -q "A10 body" "$out" \
    && pass "--anchor A1 does not match A10" || fail "--anchor A1: rc=$rc"
python3 "$SRS" "$X" "Anchor" > "$out" 2> "$err"; rc=$?
[ $rc -eq 2 ] && pass "document H1 never wins as parent (exit 2)" || fail "H1 parent: rc=$rc ($(wc -l < "$out") lines)"
printf '\xff\xfe\x00binary' > "$out.bin"; python3 "$RS" "$out.bin" x > "$out" 2> "$err"; rc=$?
[ $rc -eq 3 ] && ! grep -q Traceback "$err" && pass "unreadable file: exit 3, no traceback" || fail "unreadable: rc=$rc"
rm -f "$out.bin"

# 13. containment: a perfectly READABLE markdown file outside the checkout is
#     still refused. Tested separately from the binary case above, which exits 3
#     because it cannot be decoded -- that passes even with containment removed,
#     so it never proved this property.
OUTSIDE="$(mktemp -d)"
cp "$HERE/fixtures/refsection-sample.md" "$OUTSIDE/refsection-sample.md"
python3 "$RS" "$OUTSIDE/refsection-sample.md" "Alpha section" > "$out" 2> "$err"; rc=$?
[ $rc -eq 3 ] && [ ! -s "$out" ] && grep -qF 'outside the skill checkout' "$err" \
    && pass "readable file outside the checkout: refused, nothing printed" \
    || fail "containment: rc=$rc, $(wc -c < "$out") bytes printed, $(head -1 "$err")"
rm -rf "$OUTSIDE"
if [ "$fails" -eq 0 ]; then say "ALL PASS"; exit 0; fi
say "$fails FAILURE(S)"; exit 1
