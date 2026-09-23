#!/bin/bash
# test-check-osc.sh — proves tests/repo/check-osc.py goes red on each defect it
# exists to catch: every case copies the skill tree to a scratch dir, applies one
# mutation, and expects the exit code plus the finding that names it. Each
# negative case trips exactly one branch. Needs osc importable (CI pins it).
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
SK=skills/opensuse-packaging
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# case_ <name> <expected rc> <expected message> <mutation> [python flags]
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 py=${5:-} dir="$work/$1" out got
  mkdir -p "$dir/tests"
  cp -a "$REPO/skills" "$dir/" && cp -a "$REPO/tests/repo" "$dir/tests/"
  (cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  # shellcheck disable=SC2086  # $py is empty or one flag
  out="$(python3 $py "$dir/tests/repo/check-osc.py" 2>&1)"; got=$?
  # A negative case must trip exactly one branch, or it proves neither.
  if [ "$rc" = 1 ] && ! grep -qx "1 finding(s)" <<<"$out"; then
    fail "$name: expected exactly one finding"; printf '%s\n' "$out" | sed 's/^/    /'; return
  fi
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"
    printf '%s\n' "$out" | sed 's/^/    /'
  }
}

U=$SK/references/osc-usage.md; T=$SK/agents/triage.md
# shellcheck disable=SC2317  # called from the mutations, through eval
add() { printf '%s\n' "$1" >> "$T" && grep -qF -- "$1" "$T"; }

case_ clean 0 "osc citations match osc" ":"
case_ unknown-subcommand 1 "\`osc frobnicate\`: no such osc subcommand" \
  "add 'Run \`osc frobnicate PRJ\`.'"
case_ unknown-flag 1 "osc build has no option --nope" \
  "add 'Run \`osc build --nope standard x86_64 p.spec\`.'"
case_ fenced-citation 1 "osc results has no option --nope2" \
  "printf '\`\`\`\nosc results --nope2 PRJ\n\`\`\`\n' >> $T && grep -q -- --nope2 $T"
case_ alias-resolves 0 "osc citations match osc" \
  "add 'Run \`osc bco PRJ PKG\` or \`osc rbl PRJ PKG standard x86_64 --lastsucceeded\`.'"
case_ hidden-option-accepted 0 "osc citations match osc" \
  "add 'Run \`osc build --shell standard x86_64 p.spec\`.'"
case_ mkpac-two-args 1 "mkpac takes ONE package name" \
  "add 'Run \`osc mkpac devel:x pkg\`.'"
case_ mkpac-negated 0 "osc citations match osc" \
  "add 'Never \`osc mkpac devel:x pkg\`.'"
case_ checkout-into-tmp 1 "checks out into /tmp" \
  "add 'Run \`osc co PRJ PKG -o /tmp/y\`.'"
case_ api-put-meta 1 "PUTs _meta by hand" \
  "add 'Run \`osc api -X PUT -T m.xml /source/P/K/_meta\`.'"
case_ no-synopsis 1 "\`osc whois\` has no synopsis line" \
  "sed -i '/^- \`osc whois/d' $U && ! grep -q '^- \`osc whois' $U"
case_ usage-file-missing 1 "missing; the skill cites osc subcommands" \
  "rm $U && [ ! -e $U ]"
case_ osc-not-importable 2 "cannot import osc" ":" "-S"

[ $fails -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
