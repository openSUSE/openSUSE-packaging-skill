#!/bin/bash
# test-changes-prepend.sh — changes-prepend.sh refuses a second prepend while
# the working .changes already differs from its committed baseline: the second
# run stacked two entries into one submission. Baselines are looked up as
# changes-guard.sh does (.osc/sources/, .osc/, git HEAD). Offline.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PREPEND="$HERE/../skills/opensuse-packaging/scripts/changes-prepend.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export CHANGES_AUTHOR='Jane Packager <jane@example.com>'
SEP=-------------------------------------------------------------------
seps() { grep -cx -- "$SEP" "$1"; }

# case_ <name> <expected rc> <expected message> <file> <bullet>
case_() {
  local out got
  out="$(printf '%s\n' "$5" | bash "$PREPEND" "$4" 2>&1)"; got=$?
  [ "$got" = "$2" ] && grep -qF -- "$3" <<<"$out" && pass "$1 (rc=$2)" || {
    fail "$1: expected rc=$2 and '$3', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}

initial() { printf '%s\nMon Jan  5 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- initial package\n\n' "$SEP"; }

# osc checkout: the committed copy lives in .osc/sources/
mkdir -p "$work/osc/.osc/sources"
initial > "$work/osc/p.changes"; cp "$work/osc/p.changes" "$work/osc/.osc/sources/p.changes"
case_ osc-first-prepend 0 "insertion-only diff OK" "$work/osc/p.changes" "- Update to 1.1"
[ "$(seps "$work/osc/p.changes")" = 2 ] && pass "osc-first-prepend: one entry added" || fail "osc-first-prepend: $(seps "$work/osc/p.changes") separators"
cp "$work/osc/p.changes" "$work/osc-after-first"
case_ osc-second-prepend 3 "edit the top entry instead" "$work/osc/p.changes" "- Fix the build"
cmp -s "$work/osc/p.changes" "$work/osc-after-first" && pass "osc-second-prepend: file untouched" \
  || fail "osc-second-prepend: file changed: $(seps "$work/osc/p.changes") separators"

# older osc store: .osc/<name>
mkdir -p "$work/oldosc/.osc"
initial > "$work/oldosc/.osc/p.changes"
{ printf '%s\nTue Sep 15 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Update to 1.1\n\n' "$SEP"; initial; } > "$work/oldosc/p.changes"
case_ old-osc-store 3 "changes-guard.sh --amend-top" "$work/oldosc/p.changes" "- Fix the build"

# git checkout: HEAD holds the baseline; an uncommitted entry on top refuses
mkdir -p "$work/git"
initial > "$work/git/p.changes"
git -C "$work/git" init -q && git -C "$work/git" -c user.name=t -c user.email=t@example.com add p.changes \
  && git -C "$work/git" -c user.name=t -c user.email=t@example.com commit -qm base || fail "could not build the git fixture"
case_ git-first-prepend 0 "insertion-only diff OK" "$work/git/p.changes" "- Update to 1.1"
case_ git-second-prepend 3 "edit the top entry instead" "$work/git/p.changes" "- Fix the build"
git -C "$work/git" -c user.name=t -c user.email=t@example.com commit -qam "1.1" || fail "could not commit the git fixture"
case_ git-after-commit 0 "insertion-only diff OK" "$work/git/p.changes" "- Update to 1.2"

# a brand-new package has no baseline at all
mkdir -p "$work/new"
case_ new-file 0 "insertion-only diff OK" "$work/new/p.changes" "- initial package"

echo "---"; [ "$fails" = 0 ] && echo "all changes-prepend checks passed" || echo "$fails FAILED"
exit $((fails > 0))
