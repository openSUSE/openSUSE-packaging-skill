#!/bin/bash
# test-bug-guard.sh — proves bug-guard.py lets through only the proven security
# hand-back and asks for everything else. Offline: a fake `osc` on PATH serves
# `whois` and `api PATH` from fixtures, a path with no fixture answering 404 as
# osc does. Every refusal check is then broken in a copy of the guard, and the
# case it exists for must flip to allow: a check never seen to fail is not one.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/skills/opensuse-packaging/scripts/bug-guard.py"
PY="${PYTHON:-python3}"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
FIX="$work/fix"; export FIX
mkdir -p "$work/bin" "$FIX"

cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
[ -f "$FIX/slow" ] && exec sleep 30
case "$1" in
  whois) cat "$FIX/whois" ;;
  api) f="$FIX/$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')"
       [ -f "$f" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
       cat "$f" ;;
  *) echo "fake osc: unexpected $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/osc"
export PATH="$work/bin:$PATH"
put() { printf '%s' "$2" > "$FIX/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

echo 'maintainer1: "A Maintainer" <maintainer@example.org>' > "$FIX/whois"
OLD=$'-------------------------------------------------------------------\nMon Jan  5 10:00:00 UTC 2026 - A Maintainer <maintainer@example.org>\n\n- Update to 1:\n  * Fix an old bug (boo#1200002)\n  * Drop a stale workaround (boo#1200003)\n'
NEW=$'-------------------------------------------------------------------\nMon Feb  2 10:00:00 UTC 2026 - A Maintainer <maintainer@example.org>\n\n- Update to 2:\n  * Fix CVE-2026-0001 (boo#1200001, bsc#1200005)\n\n-------------------------------------------------------------------\nMon Jan  5 10:00:00 UTC 2026 - A Maintainer <maintainer@example.org>\n\n- Update to 1:\n  * Fix an old bug (boo#1200002)\n'
SPEC=$'Name: pkga\n# boo#1200004 is only in the spec\n'
LIST='<directory name="pkga"><entry name="pkga.spec"/><entry name="pkga.changes"/></directory>'

# request N: creator, action type, target project, state, factory-auto review, acceptinfo
req() {
  local n=$1 creator=$2 type=$3 tprj=$4 state=$5 fa=$6 accept=${7:-} id=${8:-$1}
  put "/request/$n" "<request id=\"$id\" creator=\"$creator\"><action type=\"$type\"><source project=\"devel:tools\" package=\"pkga\" rev=\"rev$n\"/><target project=\"$tprj\" package=\"pkga\"/>$accept</action><state name=\"$state\"/><review state=\"$fa\" by_user=\"factory-auto\"/><review state=\"new\" by_group=\"factory-staging\"/></request>"
  put "/source/devel:tools/pkga?rev=rev$n&expand=1" "$LIST"
  put "/source/devel:tools/pkga/pkga.changes?rev=rev$n&expand=1" "$NEW"
  put "/source/devel:tools/pkga/pkga.spec?rev=rev$n&expand=1" "$SPEC"
}
req 1000001 maintainer1 submit openSUSE:Factory review accepted
req 1000003 someoneelse submit openSUSE:Factory review accepted
req 1000004 maintainer1 submit devel:languages:python review accepted
req 1000005 maintainer1 delete openSUSE:Factory review accepted
req 1000006 maintainer1 submit openSUSE:Factory declined accepted
req 1000007 maintainer1 submit openSUSE:Factory review new
req 1000009 maintainer1 submit openSUSE:Factory accepted accepted '<acceptinfo rev="3" srcmd5="x" osrcmd5="old9"/>'
req 1000010 maintainer1 submit openSUSE:Factory accepted accepted '<acceptinfo rev="1" srcmd5="y"/>'
req 1000011 maintainer1 submit openSUSE:Factory review accepted '' 1000001
put "/source/openSUSE:Factory/pkga/pkga.changes" "$OLD"
put "/source/openSUSE:Factory/pkga/pkga.changes?rev=old9" "$OLD"

COMMENT='Fixed in pkga 2: carried the upstream fix. Submitted as SR 1000001 (devel:tools → openSUSE:Factory). Reassigning to the security team for verification/tracking; status left open.'
ev() { # tool bug assignee comment
  "$PY" -c 'import json,sys; t,b,a,c=sys.argv[1:5]; b=int(b) if b.isdigit() else json.loads(b); print(json.dumps({"tool_name":t,"tool_input":{"bug_id":b,"assignee":a,"comment":c}}))' "$@"
}
decision() { # GUARD < EVENT -> allow | ask | none | error:<rc>
  local out rc
  out="$("$PY" "$1")"; rc=$?
  [ "$rc" -eq 0 ] || { echo "error:$rc"; return; }
  [ -n "$out" ] || { echo none; return; }
  printf '%s' "$out" | "$PY" -c 'import json,sys; o=json.load(sys.stdin)["hookSpecificOutput"]; assert o["hookEventName"]=="PreToolUse"; print(o["permissionDecision"])' 2>/dev/null || echo "bad-json"
}
expect() { # label want GUARD EVENT...
  local label=$1 want=$2 guard=$3 got; shift 3
  got="$(ev "$@" | decision "$guard")"
  [ "$got" = "$want" ] && pass "$label: $want" || fail "$label: want $want, got $got"
}
A=mcp__bugzilla__assign_bug S=security-team@suse.de

# The proven hand-back, in each form it legitimately takes.
expect "own SR past factory-auto, bug added to .changes" allow "$SCRIPT" $A 1200001 $S "$COMMENT"
expect "opencode's tool name" allow "$SCRIPT" bugzilla_assign_bug 1200001 $S "$COMMENT"
expect "bsc# citation" allow "$SCRIPT" $A 1200005 $S "$COMMENT"
expect "bug id as a string" allow "$SCRIPT" $A '"1200001"' $S "$COMMENT"
expect "accepted, read against the old target revision" allow "$SCRIPT" $A 1200001 $S "Fixed. Submitted as sr#1000009."
expect "accepted as a new package" allow "$SCRIPT" $A 1200001 $S "Fixed. Submitted as request 1000010."
expect "cited as SR#N" allow "$SCRIPT" $A 1200001 $S "Fixed. Submitted as SR#1000001."
BUG_GUARD_OBS_USER=maintainer1 expect "account from BUG_GUARD_OBS_USER" allow "$SCRIPT" $A 1200001 $S "$COMMENT"
BUG_GUARD_OBS_USER=other expect "BUG_GUARD_OBS_USER names someone else" ask "$SCRIPT" $A 1200001 $S "$COMMENT"

# Each condition broken alone.
expect "assignee other than security" ask "$SCRIPT" $A 1200001 someone@example.org "$COMMENT"
expect "no comment" ask "$SCRIPT" $A 1200001 $S ""
LONG="$COMMENT $(printf 'x%.0s' $(seq 1 450))"
expect "comment over 600 characters" ask "$SCRIPT" $A 1200001 $S "$LONG"
expect "comment cites no request" ask "$SCRIPT" $A 1200001 $S "Fixed in pkga 2. Reassigning to the security team."
expect "comment cites two requests" ask "$SCRIPT" $A 1200001 $S "Submitted as SR 1000001 and SR 1000009."
expect "someone else's request" ask "$SCRIPT" $A 1200001 $S "Submitted as SR 1000003."
expect "not a Factory submit" ask "$SCRIPT" $A 1200001 $S "Submitted as SR 1000004."
expect "not a submit" ask "$SCRIPT" $A 1200001 $S "Submitted as SR 1000005."
expect "declined request" ask "$SCRIPT" $A 1200001 $S "Submitted as SR 1000006."
expect "factory-auto not passed yet" ask "$SCRIPT" $A 1200001 $S "Submitted as SR 1000007."
expect "osc answers for another request" ask "$SCRIPT" $A 1200001 $S "Submitted as SR 1000011."
expect "request lookup fails (404)" ask "$SCRIPT" $A 1200001 $S "Submitted as SR 1000099."
expect "bug nowhere in the request" ask "$SCRIPT" $A 1200009 $S "$COMMENT"
expect "bug cited only in an entry the target already had" ask "$SCRIPT" $A 1200002 $S "$COMMENT"
expect "bug only in a line the request removes" ask "$SCRIPT" $A 1200003 $S "$COMMENT"
expect "bug only in the spec, not a .changes" ask "$SCRIPT" $A 1200004 $S "$COMMENT"
expect "boolean bug id" ask "$SCRIPT" $A true $S "$COMMENT"
mv "$FIX/whois" "$FIX/whois.off"
expect "osc whois fails" ask "$SCRIPT" $A 1200001 $S "$COMMENT"
mv "$FIX/whois.off" "$FIX/whois"

# Other tools and malformed input.
for t in add_comment update_bug_status update_bug_fields create_bug mark_as_duplicate add_cc_to_bug some_future_tool; do
  expect "write tool $t" ask "$SCRIPT" "mcp__bugzilla__$t" 1200001 $S "$COMMENT"
done
for t in bugs_quicksearch bug_info bug_comments bug_history; do
  expect "read tool $t gets no decision" none "$SCRIPT" "mcp__bugzilla__$t" 1200001 $S ""
done
expect "a tool of another server gets no decision" none "$SCRIPT" mcp__other__assign_bug 1200001 $S "$COMMENT"
got="$(printf 'not json' | decision "$SCRIPT")"
[ "$got" = ask ] && pass "malformed event: ask" || fail "malformed event: want ask, got $got"
got="$(printf '{"tool_name":"mcp__bugzilla__assign_bug","tool_input":"x"}' | decision "$SCRIPT")"
[ "$got" = ask ] && pass "input not an object: ask" || fail "input not an object: want ask, got $got"

# The deadline: a copy that waits 2 s, against an osc that hangs.
sed 's/^DEADLINE = 40$/DEADLINE = 2/' "$SCRIPT" > "$work/fast.py"
grep -q '^DEADLINE = 2$' "$work/fast.py" || fail "deadline: DEADLINE line not found"
touch "$FIX/slow"; start=$SECONDS
expect "osc hangs past the deadline" ask "$work/fast.py" $A 1200001 $S "$COMMENT"
[ $((SECONDS - start)) -lt 15 ] && pass "deadline holds" || fail "deadline: took $((SECONDS - start)) s"
rm -f "$FIX/slow"

# Usage.
"$PY" "$SCRIPT" --help | grep -q '^Exit:' && pass "--help has an Exit: line" || fail "--help has no Exit: line"
"$PY" "$SCRIPT" extra </dev/null 2>/dev/null; rc=$?
[ "$rc" -eq 2 ] && pass "an argument is a usage error" || fail "argument: want exit 2, got $rc"

# Break each check in a copy: the case it guards must flip to allow.
mutant() { # label old new -> path of a copy with old replaced once
  "$PY" - "$SCRIPT" "$work/m.py" "$2" "$3" <<'PY' || { fail "mutant $1: pattern not found exactly once"; return 1; }
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit(1)
open(dst, "w", encoding="utf-8").write(s.replace(old, new))
PY
}
broken() { # label old new EVENT...
  local label=$1 old=$2 new=$3 got; shift 3
  mutant "$label" "$old" "$new" || return
  got="$(ev "$@" | decision "$work/m.py")"
  [ "$got" = allow ] && pass "without the $label check the case passes (so the check is live)" \
    || fail "without the $label check: want allow, got $got — the case does not exercise it"
}
broken assignee 'if assignee != SECURITY:' 'if False:' $A 1200001 someone@example.org "$COMMENT"
broken length 'if len(comment) > MAX_COMMENT:' 'if False:' $A 1200001 $S "$LONG"
broken "one-request" 'if len(cited) != 1:' 'if not cited:' $A 1200001 $S "Submitted as SR 1000001 and SR 1000009."
broken creator 'if req.get("creator") != user:' 'if False:' $A 1200001 $S "Submitted as SR 1000003."
broken target 'or a.find("target").get("project") != TARGET' 'or False' $A 1200001 $S "Submitted as SR 1000004."
broken "submit-type" 'a.get("type") != "submit"' 'False' $A 1200001 $S "Submitted as SR 1000005."
broken state 'if state not in ("new", "review", "accepted"):' 'if False:' $A 1200001 $S "Submitted as SR 1000006."
broken factory-auto 'if state != "accepted" and not passed:' 'if False:' $A 1200001 $S "Submitted as SR 1000007."
broken "request-id" 'if req.get("id") != n:' 'if False:' $A 1200001 $S "Submitted as SR 1000011."
broken "added-line" 'if have[line]:' 'if False:' $A 1200002 $S "$COMMENT"
broken ".changes-only" 'if not name.endswith(".changes"):' 'if False:' $A 1200004 $S "$COMMENT"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
