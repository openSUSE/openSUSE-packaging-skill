#!/bin/bash
# test-cone-status.sh — cone-status.sh offline: a fake `osc` on PATH serves the
# project's _meta, its _result and each package's last commit from a per-case
# fixture tree (a missing file is a 404). Each case expects the exit code and
# the line that names the verdict. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
# shellcheck disable=SC2016  # a case's setup is single-quoted to be eval'd in its tree
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CS="$HERE/../skills/opensuse-packaging/scripts/cone-status.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
[ "$1" = api ] || { echo "fake osc: unexpected $*" >&2; exit 99; }
f="$FIX/$(printf %s "$2" | tr '/?&=' '____')"
[ -f "$f" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
cat "$f"
EOF
chmod +x "$work/bin/osc"

P=devel:cone
# result <case dir> <pkg>=<code> ...: the x86_64 result of standard
# shellcheck disable=SC2317,SC2329  # called from case setups, through eval
result() {
  local d=$1 spec; shift
  { echo "<resultlist><result project=\"$P\" repository=\"standard\" arch=\"x86_64\" code=\"x\" state=\"x\">"
    for spec in "$@"; do echo "  <status package=\"${spec%%=*}\" code=\"${spec#*=}\"/>"; done
    echo '</result></resultlist>'; } > "$d/_build_${P}__result_repository_standard_arch_x86_64"
}
# commit <case dir> <pkg> <seconds ago>: the package's last commit
# shellcheck disable=SC2317,SC2329  # called from case setups, through eval
commit() {
  printf '<revisionlist><revision rev="3"><time>%s</time></revision></revisionlist>\n' \
    "$(( $(date +%s) - $3 ))" > "$1/_source_${P}_$2__history_limit_1"
}
# ended <case dir> <seconds ago>: the repo/arch's newest build job ended then
# shellcheck disable=SC2317,SC2329  # called from case setups, through eval
ended() {
  printf '<jobhistlist><jobhist package="dep" endtime="%s"/></jobhistlist>\n' \
    "$(( $(date +%s) - $2 ))" > "$1/_build_${P}_standard_x86_64__jobhistory_limit_1"
}
# case_ <name> <rc> <expected line> <setup: result/commit calls on $d>
case_() {
  local name=$1 rc=$2 msg=$3 out got; d="$work/$1"; mkdir -p "$d"
  echo "<project name=\"$P\"><repository name=\"standard\"/></project>" > "$d/_source_${P}__meta"
  eval "$4"
  out="$(FIX=$d PATH="$work/bin:$PATH" bash "$CS" "$P" 2>&1)"; got=$?
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}

case_ green 0 "summary: 2 ok / 0 failed / 0 in-flight" 'result "$d" a=succeeded b=succeeded'
case_ building 1 "summary: 1 ok / 0 failed / 1 in-flight" 'result "$d" a=succeeded b=building'
case_ settled-failure 2 "summary: 1 ok / 1 failed / 0 in-flight" 'result "$d" a=succeeded b=failed'
# Packages that only wait for a worker: polling does not shorten that. Stuck
# once neither a commit nor a finished job in the repo/arch came for 30 min.
case_ queued-stuck 4 "QUEUED-STUCK: 2 scheduled 30+ min with no commit or finished job there, the rest green" \
  'result "$d" a=succeeded b=scheduled c=scheduled x=excluded; commit "$d" b 3600; commit "$d" c 7200; ended "$d" 3600'
# Blocked on a dependency for an hour, scheduled since it built two minutes ago.
case_ queued-after-dep 1 "summary: 1 ok / 0 failed / 1 in-flight" \
  'result "$d" a=succeeded b=scheduled; commit "$d" b 3600; ended "$d" 120'
# A flavor (b:test) has no _history of its own: its package's commit counts.
case_ queued-flavor 4 "QUEUED-STUCK: 1 scheduled" \
  'result "$d" a=succeeded b:test=scheduled; commit "$d" b 3600; ended "$d" 3600'
case_ queued-no-jobs 4 "QUEUED-STUCK: 1 scheduled" \
  'result "$d" a=succeeded b=scheduled; commit "$d" b 3600; echo "<jobhistlist/>" > "$d/_build_${P}_standard_x86_64__jobhistory_limit_1"'
case_ queued-jobs-unreadable 1 "NOTE: a last-commit or job time could not be read — treated as in flight" \
  'result "$d" a=succeeded b=scheduled; commit "$d" b 3600'
case_ queued-fresh 1 "summary: 1 ok / 0 failed / 2 in-flight" \
  'result "$d" a=succeeded b=scheduled c=scheduled; commit "$d" b 3600; commit "$d" c 600; ended "$d" 3600'
case_ queued-unreadable 1 "NOTE: a last-commit or job time could not be read — treated as in flight" \
  'result "$d" a=succeeded b=scheduled; ended "$d" 3600; echo "<revisionlist/>" > "$d/_source_${P}_b__history_limit_1"'
case_ queued-none-green 1 "summary: 0 ok / 0 failed / 2 in-flight" \
  'result "$d" b=scheduled c=scheduled; commit "$d" b 3600; commit "$d" c 3600; ended "$d" 3600'
case_ queued-with-failure 1 "summary: 1 ok / 1 failed / 1 in-flight" \
  'result "$d" a=succeeded b=scheduled f=failed; commit "$d" b 3600; ended "$d" 3600'
case_ queued-with-building 1 "summary: 1 ok / 0 failed / 2 in-flight" \
  'result "$d" a=succeeded b=scheduled g=building; commit "$d" b 3600; ended "$d" 3600'
case_ no-result 3 "no build result for $P standard/x86_64" ':'

if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
