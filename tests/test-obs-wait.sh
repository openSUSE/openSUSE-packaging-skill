#!/bin/bash
# test-obs-wait.sh — proves obs-wait.py takes every verdict from osc and uses
# OBS's event stream only to wake up. Offline: a fake `osc` on PATH serves
# fixtures, the n-th call of a kind getting <kind>@n (or the highest one below
# n); a sitecustomize.py on PYTHONPATH replaces urllib's urlopen with a scripted
# server-sent-event stream, one plan per connection ("fail" refuses it, "hang"
# never answers, DROP resets it, END closes it; after its last event a stream
# goes silent for good), and a dead proxy catches anything that slips past.
# Both fakes log to $FIX/calls, so a case can assert the order of subscribe and
# check and how often osc was asked. Timed cases use a --timeout far above the
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
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
echo "osc $*" >> "$FIX/calls"
serve() { # the n-th call of a kind gets <kind>@n, else the highest below n, else <kind>
  local n f=
  n=$(( $(cat "$FIX/.n.$1" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIX/.n.$1"
  while [ "$n" -gt 0 ]; do [ -f "$FIX/$1@$n" ] && { f="$FIX/$1@$n"; break; }; n=$((n-1)); done
  [ -n "$f" ] || f="$FIX/$1"
  [ -f "$f" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
  [ "$(head -c5 "$f")" = "@ERR " ] && { cut -c6- "$f" >&2; exit 1; }
  cat "$f"
}
case "$1 $2" in
  "results --xml") serve results ;;
  "api /source/"*) serve source ;;
  "api /request/"*) serve request ;;
  "api /build/"*"/_jobhistory?package="*)
    IFS=/ read -r _ _ _ repo arch rest <<<"$2"
    name=${rest#_jobhistory?package=}; name=${name%%&*}
    if compgen -G "$FIX/jobhist.$repo.$arch.$name*" >/dev/null; then serve "jobhist.$repo.$arch.$name"; else serve jobhist; fi ;;
  *) echo "fake osc: unexpected $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/osc"

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
new() { FIX="$work/$1"; mkdir -p "$FIX"; plan; }
res() { # res NAME ARCH[:FLAVOR][!]=CODE[/DETAILS] ...  — "!" marks the repository dirty
  local f="$FIX/$1" spec a code why flav dirty; shift
  { echo '<resultlist state="0">'
    for spec in "$@"; do
      a=${spec%%=*}; code=${spec#*=}; why=; dirty=; flav=
      case $code in */*) why=${code#*/}; code=${code%%/*} ;; esac
      case $a in *!) dirty=' dirty="true"'; a=${a%!} ;; esac
      case $a in *:*) flav=":${a#*:}"; a=${a%%:*} ;; esac
      echo "  <result project=\"$P\" repository=\"standard\" arch=\"$a\" code=\"x\" state=\"x\"$dirty>"
      if [ -n "$why" ]; then
        echo "    <status package=\"$K$flav\" code=\"$code\"><details>$why</details></status>"
      else
        echo "    <status package=\"$K$flav\" code=\"$code\"/>"
      fi
      echo '  </result>'
    done
    echo '</resultlist>'; } > "$f"
}
src() { echo "<directory name=\"$K\" rev=\"3\" srcmd5=\"$2\"/>" > "$FIX/$1"; }
job() { echo "<jobhistlist><jobhist package=\"$K\" srcmd5=\"$2\" code=\"succeeded\"/></jobhistlist>" > "$FIX/$1"; }
req() { # req NAME STATE [ATTRS] [COMMENT] [REVIEWS]
  printf '<request id="4242" creator="a-packager"><state name="%s" who="a-reviewer" %s><comment>%s</comment></state>%s</request>\n' \
    "$2" "${3:-}" "${4:-}" "${5:-}" > "$FIX/$1"
}

run() { # run CASE ARGS... — sets rc, out, err, ms
  FIX="$work/$1"; shift; export FIX
  : > "$FIX/calls"
  local t0; t0=$(date +%s%N)
  out=$(PATH="$work/bin:$PATH" PYTHONPATH="$work/py" https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
        timeout 60 "$PY" "$SCRIPT" "$@" 2>"$FIX/err"); rc=$?
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  err=$(cat "$FIX/err")
}
calls() { grep -c "^osc $1" "$FIX/calls"; }
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
o=$(at '^feed open'); s=$(at '^feed sent'); c=$(at '^osc ')
[ -n "$o" ] && [ -n "$s" ] && [ -n "$c" ] && [ "$o" -lt "$s" ] && [ "$s" -lt "$c" ] \
  && pass "  ...osc is asked only once the stream has delivered" || fail "  order: $(cat "$FIX/calls")"
grep -q '^feed open 1 https://rabbit.opensuse.org/cgi-bin/webevents.py accept=text/event-stream timeout=60$' "$FIX/calls" \
  && pass "  ...the public event stream, with a socket timeout" || fail "  feed open: $(grep '^feed open' "$FIX/calls")"

new ev-green; res results@1 x86_64=building; res results@2 x86_64=succeeded; src source $CUR; job jobhist $CUR
plan "$(bev 0.3 build_success $CUR)"
run ev-green build $P $K --timeout 20
expect "an event wakes it and osc confirms green" 0 "VERDICT: GREEN"
[ "$ms" -lt 10000 ] && [ "$(calls results)" = 2 ] && pass "  ...on the event, not the timeout (${ms}ms, 2 checks)" \
  || fail "  ${ms}ms, $(calls results) checks"

new failed; res results x86_64=failed i586=succeeded; src source $CUR; job jobhist $CUR
run failed build $P $K --timeout 0
expect "a build failed from the current sources: exit 2" 2 "VERDICT: FAILED — $P/$K sources aaaaaaaaaaaa: failed: standard/x86_64"
[ "$(at '^feed')" = "" ] && pass "  ...--timeout 0 asks osc once, without the stream" || fail "  --timeout 0 opened the stream"

new red-first; res results x86_64=failed i586=building; src source $CUR; job jobhist $CUR
run red-first build $P $K --timeout 0
expect "a settled failure beats an arch still building" 2 "failed: standard/x86_64"

new stale-ev; res results x86_64=building; src source $CUR
plan "$(bev 0.3 build_success $OLD), $(ev 0.4 package.commit "{\"project\": \"$P\", \"package\": \"$K\"}")"
run stale-ev build $P $K --timeout 5
[ "$rc" = 1 ] && [ "$(calls results)" = 2 ] && has "$err" "older sources bbbbbbbbbbbb" \
  && pass "an event for older sources, or a commit, is ignored (2 checks: start and timeout)" \
  || fail "stale event: rc=$rc, $(calls results) checks, $err"

new other-ev; res results x86_64=building; src source $CUR
plan "$(bev 0.2 build_success $CUR foo-extra), $(bev 0.3 build_fail $CUR foo aarch64), \
$(bev 0.4 build_success $CUR foo x86_64 devel:other), \
$(ev 0.5 repo.build_finished '{"project": "devel:other", "repo": "standard", "arch": "x86_64"}')"
run other-ev build $P $K --arch x86_64 --timeout 5
[ "$rc" = 1 ] && [ "$(calls results)" = 2 ] && [ "$(grep -c '^feed sent' "$FIX/calls")" = 5 ] \
  && pass "events for another package, arch or project do not wake it" \
  || fail "unrelated events: rc=$rc, $(calls results) checks, $(grep -c '^feed sent' "$FIX/calls") sent"
grep -q "^osc results --xml -a x86_64 $P $K$" "$FIX/calls" && pass "  ...--arch reaches osc results" \
  || fail "  --arch not passed: $(grep '^osc results' "$FIX/calls" | head -1)"

new repo-ev; res results@1 x86_64=building; res results@2 "x86_64=unresolvable/nothing provides bar"; src source $CUR
plan "$(ev 0.3 repo.build_finished "{\"project\": \"$P\", \"repo\": \"standard\", \"arch\": \"x86_64\"}")"
run repo-ev build $P $K --repo standard --timeout 20
expect "the repository finishing wakes it: unresolvable is a settled failure" 2 "unresolvable: standard/x86_64 (nothing provides bar)"
[ "$ms" -lt 10000 ] && pass "  ...on the event (${ms}ms)" || fail "  took ${ms}ms"
grep -q "^osc results --xml -r standard $P $K$" "$FIX/calls" && pass "  ...--repo reaches osc results" \
  || fail "  --repo not passed: $(grep '^osc results' "$FIX/calls" | head -1)"

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

new timeout; res results x86_64=scheduled; src source $CUR
run timeout build $P $K --timeout 3
expect "still building at the timeout: exit 1" 1 "PENDING — $P/$K sources aaaaaaaaaaaa: scheduled: standard/x86_64 — not settled after 3s"
[ "$(calls results)" = 2 ] && pass "  ...asked osc again at the timeout" || fail "  $(calls results) checks"

new flavor; src source $CUR; job jobhist $CUR; job jobhist.standard.x86_64.foo:test $CUR
cat > "$FIX/results" <<EOF
<resultlist state="0">
  <result project="$P" repository="standard" arch="x86_64" code="x" state="x">
    <status package="foo" code="succeeded"/>
    <status package="foo:test" code="failed"/>
    <status package="foo-extra" code="broken"/>
  </result>
</resultlist>
EOF
run flavor build $P $K --timeout 0
expect "a multibuild flavor's failure counts; foo-extra is not foo" 2 "failed: standard/x86_64:test"
grep -q '_jobhistory?package=foo:test&limit=1' "$FIX/calls" && pass "  ...the flavor's own job history is read" \
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
<resultlist state="0"><result project="$P" repository="standard" arch="x86_64" code="x" state="x">
  <status package="foo-extra" code="succeeded"/></result></resultlist>
EOF
run no-rows build $P $K --timeout 0
expect "no status for the package is no answer" 3 "no build results for $P/$K"

new garbage; echo 'not xml <' > "$FIX/results"
run garbage build $P $K --timeout 0
expect "unparseable results are no answer" 3 "unparseable osc results"

new no-job; res results x86_64=succeeded; src source $CUR; echo '<jobhistlist/>' > "$FIX/jobhist"
run no-job build $P $K --timeout 0
expect "succeeded with no job on record is no answer, not green" 3 "no build job recorded for standard/x86_64"

new mid-err; res results@1 x86_64=building; echo '@ERR HTTP Error 502: gateway' > "$FIX/results@2"; res results@3 x86_64=building
src source $CUR
plan "$(bev 0.3 build_success $CUR)"
run mid-err build $P $K --timeout 20
expect "a lookup failing mid-wait is no answer, not pending" 3 "gateway"

# ---------------------------------------------------------------- the stream

new no-stream; res results@1 x86_64=building; res results@2 x86_64=succeeded; src source $CUR; job jobhist $CUR
echo '[{"fail": "stub: network is unreachable"}]' > "$FIX/feed"
run no-stream build $P $K --recheck 1 --timeout 20
expect "without the stream it polls osc and still finds green" 0 "VERDICT: GREEN"
has "$err" "network is unreachable" && has "$err" "polling osc" && [ "$ms" -lt 10000 ] \
  && pass "  ...saying so on stderr (${ms}ms)" || fail "  ${ms}ms, stderr: $err"

new no-stream-wait; res results x86_64=building; src source $CUR
echo '[{"fail": "stub: network is unreachable"}]' > "$FIX/feed"
run no-stream-wait build $P $K --recheck 1 --timeout 3
expect "without the stream a build still running is pending, never done" 1 "PENDING"

new html; res results x86_64=building; src source $CUR
echo '[{"type": "text/html", "events": []}]' > "$FIX/feed"
run html build $P $K --timeout 3
expect "an HTML page in place of the stream is pending, never done" 1 "PENDING"
has "$err" "not an event stream: text/html" && has "$err" "polling osc" && pass "  ...and says it is polling" \
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
  expect "after a lost stream ($how) it reconnects and asks osc again" 0 "VERDICT: GREEN"
  grep -q '^feed open 2 ' "$FIX/calls" && has "$err" "event stream lost" && [ "$ms" -lt 10000 ] \
    && pass "  ...reconnected and re-checked (${ms}ms)" || fail "  ${ms}ms, stderr: $err"
done

new drops; res results x86_64=building; src source $CUR
printf '[{"events": [%s, [0.3, "DROP"]]}]\n' "$NOISE" > "$FIX/feed"
run drops build $P $K --timeout 6
expect "a stream that keeps dropping is pending, never done" 1 "PENDING"
[ "$(grep -c '^feed open' "$FIX/calls")" = 3 ] && has "$err" "lost 3 times" && has "$err" "polling osc" \
  && pass "  ...three connections, then it polls" || fail "  $(grep -c '^feed open' "$FIX/calls") opens, stderr: $err"

new reconnect-fail; res results x86_64=building; src source $CUR
printf '[{"events": [%s, [0.3, "DROP"]]}, {"fail": "connection refused"}]\n' "$NOISE" > "$FIX/feed"
run reconnect-fail build $P $K --timeout 4
expect "a stream that cannot come back falls back to polling" 1 "PENDING"
has "$err" "connection refused" && has "$err" "polling osc" && pass "  ...and says so" || fail "  stderr: $err"

# ---------------------------------------------------------------- request

REV='<review state="new" by_group="factory-staging"/><review state="accepted" by_user="factory-auto"/>'
new rq-ev; req request@1 review '' '' "$REV"; req request@2 accepted
plan "$(ev 0.3 request.state_change '{"number": 4242, "id": 17, "state": "accepted", "oldstate": "review"}')"
run rq-ev request 4242 --timeout 20
expect "a request event wakes it and osc confirms accepted" 0 "VERDICT: ACCEPTED — request 4242 by a-reviewer"
[ "$ms" -lt 10000 ] && pass "  ...on the event (${ms}ms)" || fail "  ${ms}ms"

new rq-id; req request review '' '' "$REV"
plan "$(ev 0.3 request.review_changed '{"number": 1111, "id": 4242, "state": "accepted"}')"
run rq-id request 4242 --timeout 5
expect "an event whose database id collides is not this request" 1 "PENDING — request 4242 review; open reviews: factory-staging"
[ "$(calls "api /request")" = 2 ] && pass "  ...no wake-up (2 checks)" || fail "  $(calls "api /request") checks"

new rq-declined; req request declined '' "needs a changelog $(printf '‮')entry"
run rq-declined request 4242 --timeout 0
expect "declined: exit 2 with the comment, sanitized" 2 "VERDICT: DECLINED — request 4242 by a-reviewer: needs a changelog entry"
new rq-superseded; req request superseded 'superseded_by="4243"'
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
expect "a missing request is no answer" 3 "VERDICT: UNKNOWN — osc api /request/4242 failed"

# ---------------------------------------------------------------- usage

new usage
run usage; [ "$rc" = 3 ] && pass "no arguments: exit 3" || fail "no arguments: rc=$rc"
run usage request abc; [ "$rc" = 3 ] && pass "a non-numeric request id: exit 3" || fail "request abc: rc=$rc"
run usage build $P; [ "$rc" = 3 ] && pass "a missing package: exit 3" || fail "build without a package: rc=$rc"
run usage --help; [ "$rc" = 0 ] && has "$out" "Exit:" && pass "--help: exit 0 with the exit codes" || fail "--help: rc=$rc"
[ ! -s "$FIX/calls" ] && pass "  ...none of them touched osc or the stream" || fail "  usage errors called out: $(cat "$FIX/calls")"

[ $fails -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
