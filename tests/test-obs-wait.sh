#!/bin/bash
# test-obs-wait.sh — proves obs-wait.py takes every verdict from geectl and uses
# OBS's event stream only to wake up. Offline: a fake `geectl` on PATH serves
# fixtures, the n-th call of a kind getting <kind>@n (or the highest one below
# n); a sitecustomize.py on PYTHONPATH replaces urllib's urlopen with a scripted
# server-sent-event stream, one plan per connection ("fail" refuses it, "hang"
# never answers, DROP resets it, END closes it; after its last event a stream
# goes silent for good), and a dead proxy catches anything that slips past.
# Both fakes log to $FIX/calls, so a case can assert the order of subscribe and
# check and how often geectl was asked. Timed cases use a --timeout far above the
# expected wake-up. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/skills/opensuse-packaging/scripts/obs-wait.py"
PY="${PYTHON:-python3}"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/py"
cat > "$work/bin/geectl" <<'EOF'
#!/bin/bash
echo "geectl $*" >> "$FIX/calls"
serve() { # the n-th call of a kind gets <kind>@n, else the highest below n, else <kind>
  local n f=
  n=$(( $(cat "$FIX/.n.$1" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIX/.n.$1"
  while [ "$n" -gt 0 ]; do [ -f "$FIX/$1@$n" ] && { f="$FIX/$1@$n"; break; }; n=$((n-1)); done
  [ -n "$f" ] || f="$FIX/$1"
  [ -f "$f" ] || { printf '{"error":{"code":"not_found","context":"no such thing"}}\n' >&2; exit 3; }
  [ "$(head -c5 "$f")" = "@ERR " ] && { cut -c6- "$f" >&2; exit 1; }
  cat "$f"
}
case "$*" in
  "build results devel:origin"*) serve origin ;;
  "build results "*) serve results ;;
  "remote package-log devel:origin"*) serve origin-log ;;
  "remote package-log "*) serve source ;;
  "remote link-target "*) serve link-target ;;
  "remote cat "*) serve link ;;
  "build job-history "*)
    if [ "${6:-}" = --package ]; then
      if compgen -G "$FIX/jobhist.$4.$5.$7*" >/dev/null; then serve "jobhist.$4.$5.$7"; else serve jobhist; fi
    else serve repojobs; fi ;;
  "request show "*) serve request ;;
  *) echo "fake geectl: unexpected $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/geectl"

cat > "$work/py/sitecustomize.py" <<'EOF'
import json
import os
import time
import urllib.error
import urllib.request

_conns = [0]


def _log(msg):
    with open(os.environ["FIX"] + "/calls", "a") as fh:
        fh.write("feed " + msg + "\n")


class _Stream:
    def __init__(self, plan):
        self.plan = plan
        self.headers = {"Content-Type": plan.get("type", "text/event-stream")}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def __iter__(self):
        start = time.monotonic()
        for at, topic, *body in self.plan.get("events", []):
            time.sleep(max(0, at - (time.monotonic() - start)))
            if topic == "DROP":
                raise ConnectionResetError("stub: connection reset by peer")
            if topic == "END":
                return
            _log("sent " + topic)
            yield ("data: " + json.dumps({"topic": topic, "body": body[0]}) + "\n").encode()
            yield b"\n"
            yield b"\n"
        time.sleep(3600)  # silent for good, as a stalled stream is


def urlopen(req, timeout=None, **kw):
    with open(os.environ["FIX"] + "/feed") as fh:
        plans = json.load(fh)
    _conns[0] += 1
    plan = plans[min(_conns[0], len(plans)) - 1]
    _log(f"open {_conns[0]} {req.full_url} accept={req.get_header('Accept')} timeout={timeout}")
    if "fail" in plan:
        raise urllib.error.URLError(plan["fail"])
    if "hang" in plan:
        time.sleep(3600)
    return _Stream(plan)


if "FIX" in os.environ:
    urllib.request.urlopen = urlopen
EOF

# ---------------------------------------------------------------- fixtures
P=devel:tools:obswait
K=foo
CUR=aaaaaaaaaaaa1111111111111111111a
OLD=bbbbbbbbbbbb2222222222222222222b
ev() { # ev SECONDS TOPIC JSON — one stream event as a plan item
  printf '[%s, "opensuse.obs.%s", %s]' "$1" "$2" "$3"
}
bev() { # bev SECONDS KIND SRCMD5 [PACKAGE] [ARCH] [PROJECT]
  ev "$1" "package.$2" "{\"project\": \"${6:-$P}\", \"package\": \"${4:-$K}\", \"repository\": \"standard\", \"arch\": \"${5:-x86_64}\", \"srcmd5\": \"$3\"}"
}
# Some other project's build: the stream is busy, so a first event comes at once.
NOISE=$(bev 0.05 build_unchanged c noise x86_64 devel:other)
plan() { printf '[{"events": [%s%s]}]\n' "$NOISE" "${1:+, $1}" > "$FIX/feed"; }
new() { FIX="$work/$1"; mkdir -p "$FIX"; plan; printf '{"project": "%s", "package": "%s", "target": null}\n' "$P" "$K" > "$FIX/link-target"; }
res() { # res NAME ARCH[:FLAVOR][!]=CODE[/DETAILS] ...  — "!" marks the repository dirty
  local f="$FIX/$1" spec a code why flav dirty sep=""; shift
  { printf '{"results": ['
    for spec in "$@"; do
      a=${spec%%=*}; code=${spec#*=}; why=; dirty=false; flav=
      case $code in */*) why=${code#*/}; code=${code%%/*} ;; esac
      case $a in *!) dirty=true; a=${a%!} ;; esac
      case $a in *:*) flav=":${a#*:}"; a=${a%%:*} ;; esac
      printf '%s{"project": "%s", "repository": "standard", "arch": "%s", "code": "x", "state": "x", "dirty": %s, "statuses": [{"package": "%s", "code": "%s"%s}]}' \
        "$sep" "$P" "$a" "$dirty" "$K$flav" "$code" "${why:+, \"details\": \"$why\"}"
      sep=", "
    done
    printf ']}\n'; } > "$f"
}
src() { # src NAME SRCMD5 [AGE] — the package log: the latest revision's srcmd5, committed AGE seconds ago
  printf '{"entries": [{"rev": 3, "srcmd5": "%s", "version": "1.1-0", "time": %s, "user": "a-packager", "comment": "update"}]}\n' \
    "$2" "$(( $(date +%s) - ${3:-3600} ))" > "$FIX/$1"
}
ended() { # ended NAME SECONDS — the repo/arch's newest build job ended SECONDS ago
  printf '{"entries": [{"package": "dep", "code": "succeeded", "endtime": %s}]}\n' "$(( $(date +%s) - $2 ))" > "$FIX/$1"
}
job() { # job NAME SRCMD5 [START] — the package's last build job, started at START (epoch, default now)
  printf '{"entries": [{"package": "%s", "srcmd5": "%s", "code": "succeeded", "starttime": %s}]}\n' \
    "$K" "$2" "${3:-$(date +%s)}" > "$FIX/$1"
}
req() { # req NAME STATE [SUPERSEDED_BY] [COMMENT] [REVIEWS_JSON]
  printf '{"id": 4242, "creator": "a-packager", "state": {"name": "%s", "who": "a-reviewer"%s%s}, "reviews": %s}\n' \
    "$2" "${3:+, \"superseded_by\": \"$3\"}" "${4:+, \"comment\": \"$4\"}" "${5:-[]}" > "$FIX/$1"
}

# run CASE ARGS... — sets rc, out, err, ms. A build waits on every repo/arch
# (--all), as before the default became the gate's scope, unless SCOPED=1.
run() {
  FIX="$work/$1"; shift; export FIX
  : > "$FIX/calls"
  local t0 all=(); t0=$(date +%s%N)
  [ "${1:-}" = build ] && [ -z "${SCOPED:-}" ] && all=(--all)
  out=$(PATH="$work/bin:$PATH" PYTHONPATH="$work/py" https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
        timeout 60 "$PY" "$SCRIPT" "$@" "${all[@]}" 2>"$FIX/err"); rc=$?
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  err=$(cat "$FIX/err")
}
calls() { grep -c "^geectl $1" "$FIX/calls"; }
at() { grep -n "$1" "$FIX/calls" | head -1 | cut -d: -f1; }
has() { grep -qF -- "$2" <<<"$1"; }
expect() { # expect NAME RC TEXT — exit code and a line fragment
  [ "$rc" = "$2" ] && has "$out" "$3" && pass "$1" || fail "$1 (rc=$rc, want $2 + '$3'): $out | $err"
}

# ---------------------------------------------------------------- build

new green-first; res results x86_64=succeeded i586=excluded; src source $CUR; job jobhist $CUR
printf '[{"events": [%s]}]\n' "$(bev 0.5 build_unchanged c noise x86_64 devel:other)" > "$FIX/feed"
run green-first build $P $K --timeout 20
expect "already green before the wait: exit 0 at once" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: standard/x86_64"
[ "$ms" -lt 5000 ] && pass "  ...without waiting out the timeout (${ms}ms)" || fail "  waited ${ms}ms for a green build"
o=$(at '^feed open'); s=$(at '^feed sent'); c=$(at '^geectl ')
[ -n "$o" ] && [ -n "$s" ] && [ -n "$c" ] && [ "$o" -lt "$s" ] && [ "$s" -lt "$c" ] \
  && pass "  ...geectl is asked only once the stream has delivered" || fail "  order: $(cat "$FIX/calls")"
grep -q '^feed open 1 https://rabbit.opensuse.org/cgi-bin/webevents.py accept=text/event-stream timeout=60$' "$FIX/calls" \
  && pass "  ...the public event stream, with a socket timeout" || fail "  feed open: $(grep '^feed open' "$FIX/calls")"

new ev-green; res results@1 x86_64=building; res results@2 x86_64=succeeded; src source $CUR; job jobhist $CUR
plan "$(bev 0.3 build_success $CUR)"
run ev-green build $P $K --timeout 20
expect "an event wakes it and geectl confirms green" 0 "VERDICT: GREEN"
[ "$ms" -lt 10000 ] && [ "$(calls "build results")" = 2 ] && pass "  ...on the event, not the timeout (${ms}ms, 2 checks)" \
  || fail "  ${ms}ms, $(calls "build results") checks"

new failed; res results x86_64=failed i586=succeeded; src source $CUR; job jobhist $CUR
run failed build $P $K --timeout 0
expect "a build failed from the current sources: exit 2" 2 "VERDICT: FAILED — $P/$K sources aaaaaaaaaaaa: failed: standard/x86_64"
[ "$(at '^feed')" = "" ] && pass "  ...--timeout 0 asks geectl once, without the stream" || fail "  --timeout 0 opened the stream"

new red-first; res results x86_64=failed i586=building; src source $CUR; job jobhist $CUR
run red-first build $P $K --timeout 0
expect "a settled failure beats an arch still building" 2 "failed: standard/x86_64"

new stale-ev; res results x86_64=building; src source $CUR
plan "$(bev 0.3 build_success $OLD), $(ev 0.4 package.commit "{\"project\": \"$P\", \"package\": \"$K\"}")"
run stale-ev build $P $K --timeout 5
[ "$rc" = 1 ] && [ "$(calls "build results")" = 2 ] && has "$err" "older sources bbbbbbbbbbbb" \
  && pass "an event for older sources, or a commit, is ignored (2 checks: start and timeout)" \
  || fail "stale event: rc=$rc, $(calls "build results") checks, $err"

new other-ev; res results x86_64=building; src source $CUR
plan "$(bev 0.2 build_success $CUR foo-extra), $(bev 0.3 build_fail $CUR foo aarch64), \
$(bev 0.4 build_success $CUR foo x86_64 devel:other), \
$(ev 0.5 repo.build_finished '{"project": "devel:other", "repo": "standard", "arch": "x86_64"}')"
run other-ev build $P $K --arch x86_64 --timeout 5
[ "$rc" = 1 ] && [ "$(calls "build results")" = 2 ] && [ "$(grep -c '^feed sent' "$FIX/calls")" = 5 ] \
  && pass "events for another package, arch or project do not wake it" \
  || fail "unrelated events: rc=$rc, $(calls "build results") checks, $(grep -c '^feed sent' "$FIX/calls") sent"
grep -q "^geectl build results $P --package $K --multibuild --arch x86_64$" "$FIX/calls" && pass "  ...--arch reaches geectl results" \
  || fail "  --arch not passed: $(grep '^geectl build results' "$FIX/calls" | head -1)"

new repo-ev; res results@1 x86_64=building; res results@2 "x86_64=unresolvable/nothing provides bar"; src source $CUR
plan "$(ev 0.3 repo.build_finished "{\"project\": \"$P\", \"repo\": \"standard\", \"arch\": \"x86_64\"}")"
run repo-ev build $P $K --repo standard --timeout 20
expect "the repository finishing wakes it: unresolvable is a settled failure" 2 "unresolvable: standard/x86_64 (nothing provides bar)"
[ "$ms" -lt 10000 ] && pass "  ...on the event (${ms}ms)" || fail "  took ${ms}ms"
grep -q "^geectl build results $P --package $K --multibuild --repository standard$" "$FIX/calls" && pass "  ...--repo reaches geectl results" \
  || fail "  --repo not passed: $(grep '^geectl build results' "$FIX/calls" | head -1)"

new recheck; res results@1 x86_64=building; res results@2 "i586=unresolvable/nothing provides bar"; src source $CUR
run recheck build $P $K --recheck 1 --timeout 20
expect "unresolvable sends no event: the periodic re-check finds it" 2 "unresolvable: standard/i586 (nothing provides bar)"
[ "$ms" -lt 10000 ] && pass "  ...before the timeout (${ms}ms)" || fail "  only at the timeout (${ms}ms)"

new stale-green; res results x86_64=succeeded; src source $CUR; job jobhist $OLD
run stale-green build $P $K --timeout 0
expect "succeeded from older sources is pending, not green" 1 "built from older sources: standard/x86_64 (succeeded on bbbbbbbbbbbb)"

new stale-red; res results x86_64=failed; src source $CUR; job jobhist $OLD
run stale-red build $P $K --timeout 0
expect "failed from older sources is pending, not a failure" 1 "built from older sources: standard/x86_64 (failed on bbbbbbbbbbbb)"

new green-older-ok; res results x86_64=succeeded aarch64=succeeded; src source $CUR; job jobhist $CUR; job jobhist.standard.aarch64.foo $OLD
run green-older-ok build $P $K --timeout 0
expect "one green arch files it; an older green arch is named as older sources, not still building" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: standard/x86_64; built from older sources: standard/aarch64 (succeeded on bbbbbbbbbbbb)"
new green-older-failed; res results x86_64=succeeded aarch64=failed; src source $CUR; job jobhist $CUR; job jobhist.standard.aarch64.foo $OLD
run green-older-failed build $P $K --timeout 0
expect "one green arch files it; an older failed arch is named as older sources, not still building" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: standard/x86_64; built from older sources: standard/aarch64 (failed on bbbbbbbbbbbb)"

new timeout; res results x86_64=scheduled; src source $CUR; ended repojobs 120
run timeout build $P $K --timeout 3
expect "still building at the timeout: exit 1" 1 "PENDING — $P/$K sources aaaaaaaaaaaa: scheduled: standard/x86_64 — not settled after 3s"
[ "$(calls "build results")" = 2 ] && pass "  ...asked geectl again at the timeout" || fail "  $(calls "build results") checks"

new flavor; src source $CUR; job jobhist $CUR; job jobhist.standard.x86_64.foo:test $CUR
cat > "$FIX/results" <<EOF
{"results": [{"project": "$P", "repository": "standard", "arch": "x86_64", "code": "x", "state": "x", "dirty": false, "statuses": [{"package": "foo", "code": "succeeded"}, {"package": "foo:test", "code": "failed"}, {"package": "foo-extra", "code": "broken"}]}]}
EOF
run flavor build $P $K --timeout 0
expect "a multibuild flavor's failure counts; foo-extra is not foo" 2 "failed: standard/x86_64:test"
grep -q "^geectl build job-history $P standard x86_64 --package foo:test --limit 1$" "$FIX/calls" && pass "  ...the flavor's own job history is read" \
  || fail "  flavor job history not read"

new skipped; res results x86_64=excluded i586=disabled
run skipped build $P $K --timeout 0
expect "nothing to build is not green" 2 "nothing to build"

new dirty; res results x86_64!=succeeded; src source $CUR; job jobhist $CUR
run dirty build $P $K --timeout 0
expect "a dirty repository is pending whatever its code says" 1 "dirty: standard/x86_64"

new unknown; res results x86_64=locked
run unknown build $P $K --timeout 0
expect "an unknown code is a settled failure, not pending" 2 "unknown code 'locked': standard/x86_64"

for c in results source jobhist; do
  new "err-$c"; res results x86_64=succeeded; src source $CUR; job jobhist $CUR
  echo "@ERR Server returned an error: HTTP Error 500: boom-$c" > "$FIX/$c"
  run "err-$c" build $P $K --timeout 0
  expect "a failed $c lookup is no answer: exit 3" 3 "VERDICT: UNKNOWN — "
  has "$out" "boom-$c" && pass "  ...naming the error" || fail "  error text missing: $out"
done

new no-rows; src source $CUR
cat > "$FIX/results" <<EOF
{"results": [{"project": "$P", "repository": "standard", "arch": "x86_64", "code": "x", "state": "x", "dirty": false, "statuses": [{"package": "foo-extra", "code": "succeeded"}]}]}
EOF
run no-rows build $P $K --timeout 0
expect "no status for the package is no answer" 3 "no build results for $P/$K"

new garbage; echo 'not json <' > "$FIX/results"
run garbage build $P $K --timeout 0
expect "unparseable results are no answer" 3 "unparseable geectl build results"

new no-job; res results x86_64=succeeded; src source $CUR; echo '{"entries": []}' > "$FIX/jobhist"
run no-job build $P $K --timeout 0
expect "succeeded with no job on record is no answer, not green" 3 "no build job recorded for standard/x86_64"

new mid-err; res results@1 x86_64=building; echo '@ERR HTTP Error 502: gateway' > "$FIX/results@2"; res results@3 x86_64=building
src source $CUR
plan "$(bev 0.3 build_success $CUR)"
run mid-err build $P $K --timeout 20
expect "a lookup failing mid-wait is no answer, not pending" 3 "gateway"

# OBS refuses the source listing while the package's source service runs: that
# one failure is pending, so the wait goes on; any other lookup saying it is not.
SVC='@ERR Server returned an error: HTTP Error 400: service in progress'
new svc-then-green; res results x86_64=succeeded; echo "$SVC" > "$FIX/source@1"; src source@2 $CUR; job jobhist $CUR
run svc-then-green build $P $K --recheck 1 --timeout 20
expect "a source service still running is pending, and the wait goes on to green" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa"
[ "$(calls "remote package-log")" = 2 ] && pass "  ...asking for the listing again" || fail "  $(calls "remote package-log") listings"
new svc-stuck; res results x86_64=succeeded; echo "$SVC" > "$FIX/source"
run svc-stuck build $P $K --timeout 3
expect "a source service still running at the timeout: exit 1, repeat the call" 1 \
  "VERDICT: PENDING — $P/$K: the source service is still running — not settled after 3s, repeat the call"
new svc-results; echo "$SVC" > "$FIX/results"
run svc-results build $P $K --timeout 0
expect "the same words from another lookup stay no answer" 3 "VERDICT: UNKNOWN — geectl build results failed"
new svc-jobhist; res results x86_64=succeeded; src source $CUR; echo "$SVC" > "$FIX/jobhist"
run svc-jobhist build $P $K --timeout 0
expect "  ...from the job history too" 3 "VERDICT: UNKNOWN — geectl build job-history failed"

# An arch that only waits for a worker: no wait shortens it. Reported as
# QUEUED-STUCK (exit 4, not green) only with nothing green yet, once neither
# a commit nor a finished job in that repo/arch came in the last 30 minutes,
# instead of 127 sleeps.
new queued; res results x86_64=succeeded aarch64=scheduled i586=scheduled; src source $CUR 3600; job jobhist $CUR; ended repojobs 3600
run queued build $P $K --timeout 20
expect "one green arch files it; the scheduled rest is a note" 0 \
  "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: standard/x86_64; still building: scheduled: standard/aarch64, standard/i586"
[ "$ms" -lt 5000 ] && pass "  ...at once, without waiting out the timeout (${ms}ms)" || fail "  waited ${ms}ms"
# Blocked on a dependency for an hour, scheduled since it built two minutes ago.
new queued-after-dep; res results x86_64=succeeded aarch64=scheduled; src source $CUR 3600; job jobhist $CUR; ended repojobs 120
run queued-after-dep build $P $K --timeout 0
expect "one green arch files it; scheduled right after a dependency built is a note" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: standard/x86_64; still building: scheduled: standard/aarch64"
new queued-no-jobs; res results x86_64=succeeded aarch64=scheduled; src source $CUR 3600; job jobhist $CUR
echo '{"entries": []}' > "$FIX/repojobs"
run queued-no-jobs build $P $K --timeout 0
expect "one green arch files it; no job ever ended on the scheduled arch" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: standard/x86_64; still building: scheduled: standard/aarch64"
new queued-jobs-err; res results x86_64=succeeded aarch64=scheduled; src source $CUR 3600; job jobhist $CUR
echo '@ERR HTTP Error 502: gateway' > "$FIX/repojobs"
run queued-jobs-err build $P $K --timeout 0
expect "an unreadable job history on a still-building arch does not block green" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: standard/x86_64; still building: scheduled: standard/aarch64"
new queued-fresh; res results x86_64=succeeded aarch64=scheduled; src source $CUR 600; job jobhist $CUR
run queued-fresh build $P $K --timeout 0
expect "one green arch files it; scheduled ten minutes after the commit is a note" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: standard/x86_64; still building: scheduled: standard/aarch64"
new queued-building; res results x86_64=succeeded aarch64=scheduled i586=building; src source $CUR 3600; job jobhist $CUR
run queued-building build $P $K --timeout 0
expect "one green arch files it; an arch still building is a note" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: standard/x86_64; still building: scheduled: standard/aarch64; building: standard/i586"
new queued-none-green; res results x86_64=scheduled aarch64=scheduled; src source $CUR 3600; echo '{"entries": []}' > "$FIX/repojobs"
run queued-none-green build $P $K --timeout 0
expect "nothing green yet, all scheduled an hour: QUEUED-STUCK" 4 "VERDICT: QUEUED-STUCK — $P/$K sources aaaaaaaaaaaa: scheduled: standard/x86_64, standard/aarch64 for 60 min with no commit or finished job there; not green"
new queued-fresh-none-green; res results x86_64=scheduled aarch64=scheduled; src source $CUR 600
run queued-fresh-none-green build $P $K --timeout 0
expect "nothing green yet, all scheduled, commit ten minutes ago: pending, not stuck" 1 "PENDING — $P/$K sources aaaaaaaaaaaa: scheduled: standard/x86_64, standard/aarch64"
new queued-recent-job; res results x86_64=scheduled aarch64=scheduled; src source $CUR 3600; ended repojobs 120
run queued-recent-job build $P $K --timeout 0
expect "nothing green yet, all scheduled, but a job ended two minutes ago: pending, not stuck" 1 "PENDING — $P/$K sources aaaaaaaaaaaa: scheduled: standard/x86_64, standard/aarch64"
new queued-jobs-err-none-green; res results x86_64=scheduled aarch64=scheduled; src source $CUR 3600
echo '@ERR HTTP Error 502: gateway' > "$FIX/repojobs"
run queued-jobs-err-none-green build $P $K --timeout 0
expect "nothing green yet, an unreadable repo job history is no answer" 3 "VERDICT: UNKNOWN"
new queued-old-green; res results x86_64=succeeded aarch64=scheduled; src source $CUR 3600; job jobhist $OLD
run queued-old-green build $P $K --timeout 0
expect "a green arch of older sources keeps it pending" 1 "built from older sources: standard/x86_64 (succeeded on bbbbbbbbbbbb)"
new queued-no-history; res results x86_64=scheduled aarch64=scheduled; src source $CUR
printf '{"entries": [{"srcmd5": "%s"}]}\n' "$CUR" > "$FIX/source"
run queued-no-history build $P $K --timeout 0
expect "no commit time is no answer, never stuck or pending" 3 "VERDICT: UNKNOWN — no commit time in the $P/$K package log"

# ---------------------------------------------------------------- scope
# By default a build is waited on where gate.sh --obs-build judges it:
# Tumbleweed and Leap 16 on x86_64/aarch64, through the same _obs_scope.py.
rres() { # rres NAME REPO/ARCH[:FLAVOR]=CODE ... — results across named repositories
  local f="$FIX/$1" spec ra r a code flav sep=""; shift
  { printf '{"results": ['
    for spec in "$@"; do
      ra=${spec%%=*}; code=${spec#*=}; r=${ra%%/*}; a=${ra#*/}; flav=
      case $a in *:*) flav=":${a#*:}"; a=${a%%:*} ;; esac
      printf '%s{"project": "%s", "repository": "%s", "arch": "%s", "code": "x", "state": "x", "dirty": false, "statuses": [{"package": "%s", "code": "%s"}]}' \
        "$sep" "$P" "$r" "$a" "$K$flav" "$code"
      sep=", "
    done
    printf ']}\n'; } > "$f"
}
lsrc() { # lsrc SRCMD5 — a linked package: its log, its link target, its _link, the origin's log
  src source "$1"
  printf '{"project": "%s", "package": "%s", "target": {"project": "devel:origin", "package": "%s"}}\n' "$P" "$K" "$K" > "$FIX/link-target"
  printf '<link project="devel:origin" package="%s"/>\n' "$K" > "$FIX/link"
  printf '{"entries": [{"rev": 3, "srcmd5": "cccccccccccccccccccccccccccccccc", "version": "1.1-0", "time": %s, "user": "a-packager", "comment": "update"}]}\n' \
    "$(( $(date +%s) - 3600 ))" > "$FIX/origin-log"
}
TW=openSUSE_Tumbleweed
SCOPED=1

new scope-default; src source $CUR; job jobhist $CUR
rres results $TW/x86_64=succeeded $TW/aarch64=succeeded $TW/i586=building 15.7/x86_64=failed 16.1/aarch64=succeeded
run scope-default build $P $K --timeout 0
expect "by default only Tumbleweed and Leap 16 on x86_64/aarch64 are waited on" 0 \
  "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: $TW/x86_64, $TW/aarch64, 16.1/aarch64"
has "$out" "(not judged: building: $TW/i586; failed: 15.7/x86_64)" && pass "  ...the rest is named, not judged" \
  || fail "  not-judged note missing: $out"
[ "$(calls "build results")" = 1 ] && pass "  ...all green: the link origin is not asked" || fail "  $(calls "build results") results calls"
run scope-default build $P $K --timeout 0 --all
expect "--all waits on every repo/arch" 2 "failed: 15.7/x86_64"
run scope-default build $P $K --timeout 0 --arches i586
expect "--arches i586 adds i586, still building beside green ones" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: $TW/x86_64, $TW/aarch64, 16.1/aarch64; still building: building: $TW/i586"
run scope-default build $P $K --timeout 0 --repos '^15\.7$'
expect "--repos adds 15.7" 2 "failed: 15.7/x86_64"
run scope-default build $P $K --timeout 0 --all --repos x
expect "--all with --repos is usage" 3 ""
run scope-default build $P $K --timeout 0 --repos '('
expect "a bad --repos regex is usage" 3 ""

new scope-none; src source $CUR; job jobhist $CUR
rres results 15.7/x86_64=succeeded $TW/i586=succeeded
run scope-none build $P $K --timeout 0
expect "no repo/arch in scope is no answer, naming --all" 3 "VERDICT: UNKNOWN — no repo/arch of $P/$K in scope"

for c in empty list; do
  new "scope-$c"; src source $CUR; job jobhist $CUR
  if [ "$c" = empty ]; then : > "$FIX/results"; else echo '{"results": []}' > "$FIX/results"; fi
  run "scope-$c" build $P $K --timeout 0
  expect "an $c geectl results answer is no answer (exit 3), never settled" 3 "VERDICT: UNKNOWN"
done

# The link origin disables openSUSE_Factory_zSystems: the branch building it is not waited on.
new origin-off; lsrc $CUR; job jobhist $CUR
rres results $TW/x86_64=succeeded $TW/aarch64=succeeded openSUSE_Factory_zSystems/s390x=building
rres origin $TW/x86_64=succeeded openSUSE_Factory_zSystems/s390x=disabled
run origin-off build $P $K --timeout 0 --arches s390x
expect "a repo/arch the link origin disables is not waited on" 0 "VERDICT: GREEN"
has "$out" "disabled in devel:origin: openSUSE_Factory_zSystems/s390x" && pass "  ...and named" || fail "  note missing: $out"
grep -q "^geectl build results devel:origin --package $K --multibuild$" "$FIX/calls" && pass "  ...read from the origin's results" \
  || fail "  origin not asked: $(grep '^geectl build results' "$FIX/calls")"
rres origin $TW/x86_64=succeeded openSUSE_Factory_zSystems/s390x=succeeded
run origin-off build $P $K --timeout 0 --arches s390x
expect "one the origin builds is a note beside green ones" 0 "VERDICT: GREEN — $P/$K sources (linked): succeeded: $TW/x86_64, $TW/aarch64; still building: building: openSUSE_Factory_zSystems/s390x"
echo "@ERR Server returned an error: HTTP Error 500: boom-origin" > "$FIX/origin"
run origin-off build $P $K --timeout 0 --arches s390x
expect "a failed origin lookup is no answer" 3 "boom-origin"
: > "$FIX/origin"
run origin-off build $P $K --timeout 0 --arches s390x
expect "an empty origin answer is no answer" 3 "VERDICT: UNKNOWN"

# Blocked behind a rebuild the origin waits on too: not this change, and no wait shortens it.
new blocked-up; lsrc $CUR; job jobhist $CUR
rres results $TW/x86_64=succeeded $TW/aarch64=blocked
rres origin $TW/x86_64=succeeded $TW/aarch64=blocked
run blocked-up build $P $K --timeout 20
expect "one green arch files it; blocked in the origin too is a note" 0 \
  "VERDICT: GREEN — $P/$K sources (linked): succeeded: $TW/x86_64; still building: blocked: $TW/aarch64"
[ "$ms" -lt 5000 ] && pass "  ...at once (${ms}ms)" || fail "  waited ${ms}ms"
rres origin $TW/x86_64=succeeded $TW/aarch64=succeeded
run blocked-up build $P $K --timeout 0
expect "one green arch files it; blocked but built in the origin is a note" 0 "VERDICT: GREEN — $P/$K sources (linked): succeeded: $TW/x86_64; still building: blocked: $TW/aarch64"
new blocked-nolink; src source $CUR; job jobhist $CUR
rres results $TW/x86_64=succeeded $TW/aarch64=blocked
run blocked-nolink build $P $K --timeout 0
expect "one green arch files it; blocked with no link origin is a note" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: $TW/x86_64; still building: blocked: $TW/aarch64"
new blocked-none-green; lsrc $CUR; job jobhist $CUR
rres results $TW/x86_64=blocked $TW/aarch64=blocked
rres origin $TW/x86_64=blocked $TW/aarch64=blocked
run blocked-none-green build $P $K --timeout 0
expect "all blocked, the origin blocked too, nothing green: BLOCKED-UPSTREAM" 5 "VERDICT: BLOCKED-UPSTREAM — $P/$K sources (linked): blocked: $TW/x86_64, $TW/aarch64, blocked in devel:origin too; not green"
new blocked-origin-green; lsrc $CUR; job jobhist $CUR
rres results $TW/x86_64=blocked $TW/aarch64=blocked
rres origin $TW/x86_64=succeeded $TW/aarch64=blocked
run blocked-origin-green build $P $K --timeout 0
expect "all blocked, the origin green at one arch, nothing green: pending, not upstream-blocked" 1 "PENDING — $P/$K sources (linked): blocked: $TW/x86_64, $TW/aarch64"
# An exclusion follows the spec, which the change may edit: a red there still counts.
new origin-excluded; lsrc $CUR; job jobhist $CUR
rres results $TW/x86_64=succeeded $TW/aarch64=failed
rres origin $TW/x86_64=succeeded $TW/aarch64=excluded
run origin-excluded build $P $K --timeout 0
expect "a red where the origin excludes the arch is a settled failure, not skipped" 2 "failed: $TW/aarch64"
new pre-existing-failed; lsrc $CUR; job jobhist $CUR
rres results $TW/x86_64=succeeded $TW/aarch64=failed
rres origin $TW/x86_64=succeeded $TW/aarch64=failed
run pre-existing-failed build $P $K --timeout 0
expect "a red the link origin has too is PRE-EXISTING, not a failure" 0 "VERDICT: GREEN — $P/$K sources (linked): succeeded: $TW/x86_64; PRE-EXISTING: failed: $TW/aarch64"
new pre-existing-unresolvable; lsrc $CUR; job jobhist $CUR
rres results $TW/x86_64=succeeded $TW/aarch64=unresolvable
rres origin $TW/x86_64=succeeded $TW/aarch64=unresolvable
run pre-existing-unresolvable build $P $K --timeout 0
expect "an unresolvable the link origin has too is PRE-EXISTING, not a failure" 0 "VERDICT: GREEN — $P/$K sources (linked): succeeded: $TW/x86_64; PRE-EXISTING: unresolvable: $TW/aarch64"
new pre-existing-none-green; lsrc $CUR; job jobhist $CUR
rres results $TW/x86_64=failed $TW/aarch64=failed
rres origin $TW/x86_64=failed $TW/aarch64=failed
run pre-existing-none-green build $P $K --timeout 0
expect "only reds the origin has too, nothing green: pending, never a failure" 1 "PENDING — $P/$K sources (linked): PRE-EXISTING: failed: $TW/x86_64, $TW/aarch64"
new pre-existing-new-red; lsrc $CUR; job jobhist $CUR
rres results $TW/x86_64=succeeded $TW/aarch64=failed
rres origin $TW/x86_64=succeeded $TW/aarch64=succeeded
run pre-existing-new-red build $P $K --timeout 0
expect "a red the origin does not have is still a settled failure" 2 "VERDICT: FAILED — $P/$K sources (linked): failed: $TW/aarch64"
# A broken link does not expand: its reds are still a settled failure, not no answer.
new broken-link; lsrc $CUR; echo "@ERR Server returned an error: HTTP Error 400: conflict in file foo.spec" > "$FIX/link"
rres results $TW/x86_64=broken $TW/aarch64=broken
rres origin $TW/x86_64=succeeded $TW/aarch64=succeeded
run broken-link build $P $K --timeout 0
expect "a broken link's reds are a settled failure (exit 2), not exit 3" 2 "broken: $TW/x86_64, $TW/aarch64"
new svc-raw; lsrc $CUR; job jobhist $CUR; echo "$SVC" > "$FIX/origin-log"
rres results $TW/x86_64=succeeded $TW/aarch64=blocked
rres origin $TW/x86_64=succeeded $TW/aarch64=blocked
run svc-raw build $P $K --timeout 0
expect "the unexpanded listing refused while the service runs is pending too" 1 "VERDICT: PENDING — $P/$K: the source service is still running"
# For a Factory target the gate leaves Leap 16 out, and so does the wait.
new target-factory; src source $CUR; job jobhist $CUR
rres results $TW/x86_64=succeeded $TW/aarch64=succeeded 16.1/x86_64=building
run target-factory build $P $K --timeout 0 --target openSUSE:Factory
expect "--target openSUSE:Factory leaves Leap 16 out" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: $TW/x86_64, $TW/aarch64 (not judged: building: 16.1/x86_64)"
run target-factory build $P $K --timeout 0 --target devel:tools
expect "--target a devel project still files it on one green build" 0 "VERDICT: GREEN — $P/$K sources aaaaaaaaaaaa: succeeded: $TW/x86_64, $TW/aarch64; still building: building: 16.1/x86_64"
# Nothing left in scope (an s390x-only package, or all off in the origin) is no answer, as the gate's UNKNOWN.
new s390x-only; src source $CUR; job jobhist $CUR
rres results $TW/x86_64=excluded $TW/aarch64=excluded openSUSE_Factory_zSystems/s390x=succeeded
run s390x-only build $P $K --timeout 0
expect "every judged repo/arch excluded is no answer, naming --arches" 3 "VERDICT: UNKNOWN — no repo/arch of $P/$K in scope builds it"
has "$out" "--repos/--arches REGEX widen it" && pass "  ...with the hint" || fail "  hint missing: $out"
new all-off; lsrc $CUR; job jobhist $CUR
rres results 16.1/x86_64=building
rres origin 16.1/x86_64=disabled
run all-off build $P $K --timeout 0
expect "every judged repo/arch disabled in the origin is no answer" 3 "no repo/arch of $P/$K in scope builds it"
new blocked-old; lsrc $CUR; job jobhist $OLD $(( $(date +%s) - 7200 ))
rres results $TW/x86_64=succeeded $TW/aarch64=blocked
rres origin $TW/aarch64=blocked
run blocked-old build $P $K --timeout 0
expect "a green arch of older sources keeps it pending" 1 "built from older sources"
SCOPED=

# The gate and the wait take their scope from one place.
for f in gate.sh obs-wait.py; do
  g="$REPO/skills/opensuse-packaging/scripts/$f"
  grep -q "import _obs_scope as scope" "$g" && ! grep -qE "^(FACTORY_REPO|LEAP16_REPO|ARCHES) *=" "$g" \
    && pass "$f takes its repo/arch scope from _obs_scope.py" || fail "$f has a scope of its own"
done
"$PY" - "$REPO/skills/opensuse-packaging/scripts" <<'PYEOF' && pass "_obs_scope.judged: the documented scope" || fail "_obs_scope.judged"
import re, sys
sys.path.insert(0, sys.argv[1])
import _obs_scope as s
yes = [("devel:a", "openSUSE_Tumbleweed", "x86_64"), ("devel:a", "openSUSE_Factory", "aarch64"),
       ("devel:a", "openSUSE_Factory_ARM", "aarch64"), ("devel:a", "16.0", "x86_64"),
       ("devel:a", "openSUSE_Leap_16.1", "aarch64"), ("openSUSE:Factory", "standard", "x86_64")]
no = [("devel:a", "openSUSE_Tumbleweed", "i586"), ("devel:a", "openSUSE_Factory_zSystems", "s390x"),
      ("devel:a", "15.7", "x86_64"), ("devel:a", "SLE_15_SP7", "x86_64"), ("devel:a", "standard", "x86_64"),
      ("devel:a", "openSUSE_Slowroll", "x86_64"), ("devel:a", "116.0", "x86_64")]
assert all(s.judged(*c) for c in yes), [c for c in yes if not s.judged(*c)]
assert not any(s.judged(*c) for c in no), [c for c in no if s.judged(*c)]
assert not s.judged("devel:a", "16.0", "x86_64", leap=False)
assert s.judged("devel:a", "15.7", "x86_64", repos=re.compile(r"15\.7"))
assert s.judged("devel:a", "openSUSE_Tumbleweed", "i586", arches=re.compile("i586"))
PYEOF

# ---------------------------------------------------------------- the stream

new no-stream; res results@1 x86_64=building; res results@2 x86_64=succeeded; src source $CUR; job jobhist $CUR
echo '[{"fail": "stub: network is unreachable"}]' > "$FIX/feed"
run no-stream build $P $K --recheck 1 --timeout 20
expect "without the stream it polls geectl and still finds green" 0 "VERDICT: GREEN"
has "$err" "network is unreachable" && has "$err" "polling geectl" && [ "$ms" -lt 10000 ] \
  && pass "  ...saying so on stderr (${ms}ms)" || fail "  ${ms}ms, stderr: $err"

new no-stream-wait; res results x86_64=building; src source $CUR
echo '[{"fail": "stub: network is unreachable"}]' > "$FIX/feed"
run no-stream-wait build $P $K --recheck 1 --timeout 3
expect "without the stream a build still running is pending, never done" 1 "PENDING"

new html; res results x86_64=building; src source $CUR
echo '[{"type": "text/html", "events": []}]' > "$FIX/feed"
run html build $P $K --timeout 3
expect "an HTML page in place of the stream is pending, never done" 1 "PENDING"
has "$err" "not an event stream: text/html" && has "$err" "polling geectl" && pass "  ...and says it is polling" \
  || fail "  stderr: $err"

new hang; res results x86_64=building; src source $CUR; echo '[{"hang": true}]' > "$FIX/feed"
run hang build $P $K --timeout 3
expect "a stream that never answers cannot hold the call" 1 "PENDING"
[ "$ms" -lt 8000 ] && has "$err" "no answer" && pass "  ...it returns at the timeout (${ms}ms)" || fail "  ${ms}ms, rc=$rc, stderr: $err"

new stall; res results x86_64=building; src source $CUR; echo '[{"events": []}]' > "$FIX/feed"
run stall build $P $K --timeout 3
expect "a stream that answers and then stalls cannot hold the call" 1 "PENDING"
[ "$ms" -lt 8000 ] && pass "  ...it returns at the timeout (${ms}ms)" || fail "  ${ms}ms, rc=$rc"

for how in DROP END; do
  new "lost-$how"; res results@1 x86_64=building; res results@2 x86_64=succeeded; src source $CUR; job jobhist $CUR
  printf '[{"events": [%s, [0.3, "%s"]]}, {"events": [%s]}]\n' "$NOISE" "$how" "$NOISE" > "$FIX/feed"
  run "lost-$how" build $P $K --timeout 20
  expect "after a lost stream ($how) it reconnects and asks geectl again" 0 "VERDICT: GREEN"
  grep -q '^feed open 2 ' "$FIX/calls" && has "$err" "event stream lost" && [ "$ms" -lt 10000 ] \
    && pass "  ...reconnected and re-checked (${ms}ms)" || fail "  ${ms}ms, stderr: $err"
done

new drops; res results x86_64=building; src source $CUR
printf '[{"events": [%s, [0.3, "DROP"]]}]\n' "$NOISE" > "$FIX/feed"
run drops build $P $K --timeout 6
expect "a stream that keeps dropping is pending, never done" 1 "PENDING"
[ "$(grep -c '^feed open' "$FIX/calls")" = 3 ] && has "$err" "lost 3 times" && has "$err" "polling geectl" \
  && pass "  ...three connections, then it polls" || fail "  $(grep -c '^feed open' "$FIX/calls") opens, stderr: $err"

new reconnect-fail; res results x86_64=building; src source $CUR
printf '[{"events": [%s, [0.3, "DROP"]]}, {"fail": "connection refused"}]\n' "$NOISE" > "$FIX/feed"
run reconnect-fail build $P $K --timeout 4
expect "a stream that cannot come back falls back to polling" 1 "PENDING"
has "$err" "connection refused" && has "$err" "polling geectl" && pass "  ...and says so" || fail "  stderr: $err"

# ---------------------------------------------------------------- request

REV='[{"state": "new", "by_group": "factory-staging"}, {"state": "accepted", "by_user": "factory-auto"}]'
new rq-ev; req request@1 review '' '' "$REV"; req request@2 accepted
plan "$(ev 0.3 request.state_change '{"number": 4242, "id": 17, "state": "accepted", "oldstate": "review"}')"
run rq-ev request 4242 --timeout 20
expect "a request event wakes it and geectl confirms accepted" 0 "VERDICT: ACCEPTED — request 4242 by a-reviewer"
[ "$ms" -lt 10000 ] && pass "  ...on the event (${ms}ms)" || fail "  ${ms}ms"

new rq-id; req request review '' '' "$REV"
plan "$(ev 0.3 request.review_changed '{"number": 1111, "id": 4242, "state": "accepted"}')"
run rq-id request 4242 --timeout 5
expect "an event whose database id collides is not this request" 1 "PENDING — request 4242 review; open reviews: factory-staging"
[ "$(calls "request show")" = 2 ] && pass "  ...no wake-up (2 checks)" || fail "  $(calls "request show") checks"

new rq-declined; req request declined '' "needs a changelog $(printf '‮')entry"
run rq-declined request 4242 --timeout 0
expect "declined: exit 2 with the comment, sanitized" 2 "VERDICT: DECLINED — request 4242 by a-reviewer: needs a changelog entry"
new rq-superseded; req request superseded 4243
run rq-superseded request 4242 --timeout 0
expect "superseded: exit 2 naming the successor" 2 "SUPERSEDED — request 4242 by #4243"
new rq-revoked; req request revoked
run rq-revoked request 4242 --timeout 0
expect "revoked: exit 2" 2 "REVOKED — request 4242"
new rq-new; req request new
run rq-new request 4242 --timeout 0
expect "new: pending" 1 "PENDING — request 4242 new"
new rq-odd; req request frobnicated
run rq-odd request 4242 --timeout 0
expect "an unrecognized state is no answer" 3 "unrecognized state 'frobnicated'"
new rq-404
run rq-404 request 4242 --timeout 0
expect "a missing request is no answer" 3 "VERDICT: UNKNOWN — geectl request show failed"

# ---------------------------------------------------------------- usage

new usage
touched=  # run empties $FIX/calls, so each run's calls are kept here
run usage; [ "$rc" = 3 ] && pass "no arguments: exit 3" || fail "no arguments: rc=$rc"
touched+=$(cat "$FIX/calls")
run usage request abc; [ "$rc" = 3 ] && pass "a non-numeric request id: exit 3" || fail "request abc: rc=$rc"
touched+=$(cat "$FIX/calls")
run usage build $P; [ "$rc" = 3 ] && pass "a missing package: exit 3" || fail "build without a package: rc=$rc"
touched+=$(cat "$FIX/calls")
run usage --help; [ "$rc" = 0 ] && has "$out" "Exit:" && pass "--help: exit 0 with the exit codes" || fail "--help: rc=$rc"
touched+=$(cat "$FIX/calls")
[ -z "$touched" ] && pass "  ...none of them touched geectl or the stream" || fail "  usage errors called out: $touched"

[ $fails -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
