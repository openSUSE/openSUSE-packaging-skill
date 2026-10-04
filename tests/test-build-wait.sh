#!/bin/bash
# test-build-wait.sh — proves build-wait.sh waits on the whole process group,
# stays inside --max, says "still running" with exit 4, refuses a pid that is
# not a group id, and once the group is gone hands the LOG's verdict to
# build-summary.sh unchanged. The "builds" are sleep processes in a group of
# their own; the logs are minimal fixtures. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
BW="$REPO/skills/opensuse-packaging/scripts/build-wait.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
g1=; g2=; g3=; s1=
work="$(mktemp -d /var/tmp/test-build-wait.XXXXXX)"
# shellcheck disable=SC2317  # runs from the EXIT trap
cleanup() { for g in $g1 $g2 $g3; do kill -- -"$g"; done 2>/dev/null; [ -z "$s1" ] || kill "$s1" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
cd "$work" || exit 1
printf '[  9s] host finished "build foo.spec" at Thu Oct  1 10:00:00 UTC 2026.\n' > green.log
printf '[  9s] host failed "build foo.spec" at Thu Oct  1 10:00:00 UTC 2026.\n' > red.log
printf '[  1s] compiling foo.c\n' > running.log
printf '[  1s] \033[31mred\033[0m text\n' > escape.log

run() { out="$(bash "$BW" "$@" 2>&1)"; rc=$?; }
# $! is known before the child's setsid() runs: wait until its group exists.
group() {
  setsid bash -c "$1" </dev/null >/dev/null 2>&1 &
  local p=$! i=0
  until pgrep -g "$p" >/dev/null || [ $((i += 1)) -gt 50 ]; do sleep 0.1; done
  echo "$p"
}

echo "--- usage"
for args in "" "1" "abc running.log" "0 running.log" "--max x 1 running.log" "--max 08 1 running.log" \
            "--max" "--bogus 1 running.log" "1 a b" "1 --list"; do
  # shellcheck disable=SC2086  # the cases are word lists
  run $args
  [ "$rc" = 5 ] && pass "usage error: '$args' exits 5" || fail "'$args' exited $rc: $out"
done
run --help
[ "$rc" = 0 ] && grep -q 'Exit codes:' <<<"$out" && pass "--help prints the exit codes" || fail "--help: rc=$rc"

echo "--- still running"
g1=$(group 'sleep 30')
t0=$SECONDS; run --max 2 "$g1" running.log; dt=$((SECONDS - t0))
[ "$rc" = 4 ] && grep -q '^STILL RUNNING after 2s' <<<"$out" && pass "a live group exits 4 at --max" \
  || fail "live group: rc=$rc $out"
[ "$dt" -ge 2 ] && [ "$dt" -le 4 ] && pass "returned after ${dt}s for --max 2" || fail "took ${dt}s for --max 2"
grep -q '^last: \[  1s\] compiling foo.c$' <<<"$out" && pass "shows the log's last line" || fail "no last line: $out"
t0=$SECONDS; run --max 0 "$g1" escape.log; dt=$((SECONDS - t0))
[ "$rc" = 4 ] && [ "$dt" -le 1 ] && pass "--max 0 checks once" || fail "--max 0: rc=$rc after ${dt}s"
grep -q $'\033' <<<"$out" && fail "an escape sequence from the log reached the output" \
  || pass "the log's last line is sanitized"
kill -- -"$g1" 2>/dev/null

echo "--- the group outlives its leader"
g2=$(group 'sleep 30 & exit 0')
sleep 1
run --max 1 "$g2" green.log
[ "$rc" = 4 ] && pass "a member left after the leader exited still counts" || fail "leader gone: rc=$rc $out"
kill -- -"$g2" 2>/dev/null

echo "--- the recipe under job control"
g3=$(bash -c 'set -m; set +m; setsid -w sleep 31.5 </dev/null >/dev/null 2>&1 & echo $!')
run --max 1 "$g3" running.log
[ "$rc" = 4 ] && pass "the recipe keeps \$! the group id under job control" || fail "job control: rc=$rc $out"
kill -- -"$g3" 2>/dev/null; sleep 0.5
pgrep -xf 'sleep 31.5' >/dev/null && fail "kill -- -\$! left the build running" || pass "kill -- -\$! stops the build"
sleep 30 & s1=$!
run --max 1 "$s1" running.log
[ "$rc" = 5 ] && grep -q 'not a group id' <<<"$out" && pass "a pid that leads no group is refused" \
  || fail "non-leader pid: rc=$rc $out"
kill "$s1" 2>/dev/null

echo "--- verdict once the group is gone"
g=$(group 'sleep 1'); run --max 20 "$g" green.log
[ "$rc" = 0 ] && grep -q 'VERDICT: GREEN' <<<"$out" && pass "green log: exit 0" || fail "green: rc=$rc $out"
g=$(group 'sleep 1'); run --max 20 "$g" red.log
[ "$rc" = 1 ] && grep -q 'VERDICT: FAILED' <<<"$out" && pass "failed log: exit 1" || fail "failed: rc=$rc $out"
run --max 0 999999 running.log
[ "$rc" = 3 ] && pass "no group, no verdict in the log: exit 3" || fail "never concluded: rc=$rc $out"
run --max 0 999999 missing.log
[ "$rc" = 2 ] && pass "no group, no log: exit 2" || fail "no log: rc=$rc $out"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
