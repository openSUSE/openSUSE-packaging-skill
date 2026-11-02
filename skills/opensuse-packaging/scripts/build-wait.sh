#!/bin/bash
# Wait for ONE local `osc build` (--no-summary: any long local job) running in
# the background, in one bounded call, then hand over to build-summary.sh for
# the verdict -- in place of a `sleep N; tail LOG` loop, each round of which
# re-reads the whole session.
# Start the build as a process group of its own, the skill's recipe:
#   set +m; setsid -w osc build ... </dev/null >LOG 2>&1 &   # $! is the group id
# set +m: under job control (Claude Code's shell has it on) the job already
# leads a group, setsid forks and $! names only the waiting setsid, so
# `kill -- -$!` would leave the build running; -w still backs up the wait.
# osc waits for its build, so the group lives until the build ends.
# Repeat `build-wait.sh $! LOG` until it stops exiting 4;
# give the tool call a 10-minute timeout, or a --max below the one it has.
# Any other local job (osc service mr, a vendor or cargo run) is waited on the
# same way with --no-summary, started by the same recipe or as a plain `&`.
#
# Usage: build-wait.sh [--max SEC] [--no-summary] PGID LOG
#   --max SEC     wait at most SEC seconds (default 540); 0 checks once
#   --no-summary  not an osc build: PGID may be the job's pid, and once it is
#                 gone LOG's last line is printed (exit 0) instead of a build
#                 verdict -- the job's outcome is in LOG
#   LOG           the file the build writes; build-summary.sh reads its verdict
#                 (never a build root's .build.log, which still holds the last
#                 build until this one starts)
#
# Exit codes: 0 green (--no-summary: ended) · 1 failed · 2 no log · 3 no verdict · 4 still running, call again · 5 usage, or PGID is not a group id
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (/^#/) print; else exit }' "$0"; exit 0;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: build-wait.sh [--max SEC] [--no-summary] PGID LOG" >&2; exit 5; }
seconds() { [[ "$1" =~ ^(0|[1-9][0-9]{0,5})$ ]]; }

max=540 nosum=0
while [ $# -gt 0 ]; do
  case "$1" in
    --max) if [ $# -lt 2 ] || ! seconds "$2"; then usage; fi; max=$2; shift 2;;
    --max=*) max=${1#--max=}; seconds "$max" || usage; shift;;
    --no-summary) nosum=1; shift;;
    --) shift; break;;
    -*) usage;;
    *) break;;
  esac
done
if [ $# -ne 2 ] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]] || [[ "$2" == -* ]]; then usage; fi
pgid=$1 log=$2

# A live pid that leads no group means $! was not taken the recipe's way; any
# other job is waited on by that pid.
lead=$(ps -o pgid= -p "$pgid" 2>/dev/null | tr -d ' ')
what="process group $pgid"
if [ -n "$lead" ] && [ "$lead" != "$pgid" ]; then
  if [ "$nosum" = 0 ]; then
    echo "build-wait.sh: $pgid is a pid in group $lead, not a group id: start the build with set +m; setsid -w" >&2
    exit 5
  fi
  what="pid $pgid"
fi
alive() { if [ "$what" = "pid $pgid" ]; then ps -p "$pgid" >/dev/null 2>&1; else pgrep -g "$pgid" >/dev/null 2>&1; fi; }

end=$((SECONDS + max))
while alive; do
  left=$((end - SECONDS))
  if [ "$left" -le 0 ]; then
    echo "STILL RUNNING after ${max}s: $what; call build-wait.sh again"
    [ -f "$log" ] && echo "last: $(tail -n 1 "$log" | cut -c1-200 | python3 "$HERE/_sanitize.py" 2>/dev/null)"
    exit 4
  fi
  sleep $((left < 5 ? left : 5))
done
if [ "$nosum" = 1 ]; then
  [ -f "$log" ] || { echo "build-wait.sh: $what is gone and wrote no $log" >&2; exit 2; }
  echo "ENDED: $what is gone; its outcome is in $log"
  echo "last: $(tail -n 1 "$log" | cut -c1-200 | python3 "$HERE/_sanitize.py" 2>/dev/null)"
  exit 0
fi
exec bash "$HERE/build-summary.sh" "$log"
