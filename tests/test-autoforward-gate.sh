#!/bin/bash
# test-autoforward-gate.sh — autoforward-gate.sh offline: a fake `osc` on PATH
# answers _meta, _link and develproject lookups from a per-case fixture tree (a
# missing file is a 404, "@ERR" fails the call). The package foo lives in
# devel:a, which openSUSE:Factory names as its devel project; tester maintains
# it and nobody reviews. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
AG="$HERE/../skills/opensuse-packaging/scripts/autoforward-gate.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
echo "osc $*" >> "$FIX/calls"
case $1 in
  whois) echo 'tester: "Tester"' ;;
  develproject) [ -f "$FIX/devel/$3" ] || exit 1; cat "$FIX/devel/$3" ;;
  ls) [ ! -f "$FIX/ls" ] || cat "$FIX/ls" ;;
  api) f="$FIX/obs/$(printf %s "$2" | tr '/?&=' '____')"
       [ -f "$f" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
       [ "$(cat "$f")" = @ERR ] && { echo "Server returned an error: HTTP Error 500" >&2; exit 1; }
       cat "$f" ;;
  *) echo "fake osc: unexpected $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/osc"
# git-obs answers the project git's files from $FIX/gitea/<path, / as %>.
cat > "$work/bin/git-obs" <<'EOF'
#!/bin/bash
echo "git-obs $*" >> "$FIX/calls"
[ "$1 $2 $3 $4" = "-G src.opensuse.org -q api" ] || { echo "fake git-obs: unexpected $*" >&2; exit 99; }
f="$FIX/gitea/$(printf %s "${5#/}" | tr / %)"
[ -f "$f" ] || { echo "ERROR: 404 Not Found" >&2; exit 1; }
[ "$(cat "$f")" = @ERR ] && { echo "ERROR: 500 Internal Server Error" >&2; exit 1; }
cat "$f"
EOF
chmod +x "$work/bin/git-obs"

B="$work/base"
mkdir -p "$B/obs" "$B/devel" "$B/gitea"
obs() { printf '%s\n' "$2" > "$B/obs/$(printf %s "$1" | tr '/?&=' '____')"; }
gitea() { printf '%s\n' "$2" > "$B/gitea/$(printf %s "$1" | tr / %)"; }
obs /source/devel:a/foo/_meta '<package name="foo"><person userid="tester" role="maintainer"/></package>'
obs /source/devel:a/_meta '<project name="devel:a"><person userid="boss" role="maintainer"/></project>'
echo devel:a/foo > "$B/devel/foo"
# devel:g is kept in git (hwdata in devel:openSUSE:Factory): its package _meta
# is a stub, its roles are in gorg/_ObsPrj; tester maintains hw there.
obs /source/devel:g/hw/_meta '<package name="hw" project="devel:g"><scmsync>https://src.opensuse.org/gorg/hw?trackingbranch=main#ab12</scmsync><url>https://src.opensuse.org/gorg/_ObsPrj.git</url></package>'
obs /source/devel:g/_meta '<project name="devel:g"><scmsync>https://src.opensuse.org/gorg/_ObsPrj.git</scmsync><person userid="tester" role="maintainer"/></project>'
echo devel:g/hw > "$B/devel/hw"
gitea repos/gorg/_ObsPrj/raw/_maintainership.json '{"": ["boss"], "hw": ["tester"], "other": ["boss"]}'
# JWCC, as autogits reads it: a comment and trailing commas
gitea repos/gorg/_ObsPrj/raw/workflow.config '{
  // no reviewers
  "Workflows": ["direct", "pr",],
  "Organization": "gorg",
}'

# case_ <name> <expected rc> <expected text> <mutation> [args]
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got; shift 4
  cp -a "$B" "$dir"
  (B=$dir; cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  out="$(cd "$dir" && FIX=$dir PATH="$work/bin:$PATH" bash "$AG" "$@" 2>&1)"; got=$?
  LAST=$out
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
NOMAINT='<package name="foo"/>'

echo "--- the reviewer role gates, maintainership decides"
case_ eligible          0 "ELIGIBLE — package maintainer" : devel:a foo
case_ project-maint     0 "ELIGIBLE — package unmaintained, project maintainer" \
  "obs /source/devel:a/foo/_meta '$NOMAINT'; obs /source/devel:a/_meta '<project><person userid=\"tester\" role=\"maintainer\"/></project>'" devel:a foo
case_ reviewer          3 "BLOCKED — explicit reviewer role: rev" \
  "obs /source/devel:a/foo/_meta '<package><person userid=\"tester\" role=\"maintainer\"/><person userid=\"rev\" role=\"reviewer\"/></package>'" devel:a foo
case_ project-reviewer  3 "BLOCKED — explicit reviewer role: qa" \
  "obs /source/devel:a/_meta '<project><group groupid=\"qa\" role=\"reviewer\"/></project>'" devel:a foo
case_ not-yours         4 "NOT_YOURS — maintained by someone else" \
  "obs /source/devel:a/foo/_meta '<package><person userid=\"other\" role=\"maintainer\"/></package>'" devel:a foo
case_ unmaintained      4 "NOT_YOURS — package unmaintained, not a project maintainer" \
  "obs /source/devel:a/foo/_meta '$NOMAINT'" devel:a foo
case_ unreadable        5 "cannot read /source/devel:a/foo/_meta" "rm obs/_source_devel:a_foo__meta" devel:a foo
# Unread, a project-level reviewer would go unseen.
case_ project-unreadable 5 "its project's" "obs /source/devel:a/_meta @ERR" devel:a foo

echo "--- the project must be the one Factory develops the package in"
case_ wrong-devel       6 "WRONG-DEVEL — openSUSE:Factory develops it in devel:b" \
  "echo devel:b/foo > devel/foo" devel:a foo
grep -q ELIGIBLE <<<"$LAST" && fail "wrong-devel also said ELIGIBLE" || pass "wrong-devel never reads ELIGIBLE"
case_ link-into-here    0 "ELIGIBLE" \
  "echo devel:b/foo > devel/foo; obs /source/devel:b/foo/_link '<link project=\"devel:a\"/>'" devel:a foo
case_ link-elsewhere    6 "WRONG-DEVEL" \
  "echo devel:b/foo > devel/foo; obs /source/devel:b/foo/_link '<link project=\"openSUSE:Factory\"/>'" devel:a foo
case_ link-other-package 6 "WRONG-DEVEL" \
  "echo devel:b/foo > devel/foo; obs /source/devel:b/foo/_link '<link project=\"devel:a\" package=\"bar\"/>'" devel:a foo
case_ link-unreadable   5 "or its Factory devel project" \
  "echo devel:b/foo > devel/foo; obs /source/devel:b/foo/_link @ERR" devel:a foo
# Project names are compared as strings: "devel.a" is no pattern for "develxa".
case_ link-literal      6 "WRONG-DEVEL" \
  "obs /source/devel.a/foo/_meta \"\$(cat obs/_source_devel:a_foo__meta)\"; obs /source/devel.a/_meta '<project/>'; echo devel:b/foo > devel/foo; obs /source/devel:b/foo/_link '<link project=\"develxa\"/>'" devel.a foo
# Factory itself is never another project's devel project.
case_ factory-itself    0 "ELIGIBLE" \
  "obs /source/openSUSE:Factory/foo/_meta \"\$(cat obs/_source_devel:a_foo__meta)\"; obs /source/openSUSE:Factory/_meta '<project/>'" openSUSE:Factory foo
grep -q develproject "$work/factory-itself/calls" && fail "factory-itself asked for a devel project" \
  || pass "factory-itself asks for no devel project"
case_ not-in-factory    0 "ELIGIBLE" "rm devel/foo" devel:a foo
# Not in Factory by this name, but under another spelling: forwarding it files a duplicate.
case_ not-in-factory-near 6 "WRONG-DEVEL — NOT IN openSUSE:Factory as foo, but it has Foo" \
  "rm devel/foo; echo Foo > ls" devel:a foo
case_ no-devel-set      0 "ELIGIBLE" \
  "rm devel/foo; obs /source/openSUSE:Factory/foo/_meta '<package name=\"foo\"/>'" devel:a foo
case_ devel-lookup-fails 5 "or its Factory devel project" \
  "rm devel/foo; obs /source/openSUSE:Factory/foo/_meta @ERR" devel:a foo

echo "--- a project kept in git: its project git names the maintainers and reviewers"
M=repos/gorg/_ObsPrj/raw/_maintainership.json W=repos/gorg/_ObsPrj/raw/workflow.config
case_ git-eligible        0 "ELIGIBLE — package maintainer in gorg/_ObsPrj/_maintainership.json" : devel:g hw
case_ git-not-listed      4 "NOT_YOURS — not a maintainer in gorg/_ObsPrj/_maintainership.json (maintainers: other)" \
  "gitea $M '{\"\": [\"tester\"], \"hw\": [\"other\"]}'" devel:g hw
case_ git-project-list    0 "ELIGIBLE — project maintainer in gorg/_ObsPrj/_maintainership.json" \
  "gitea $M '{\"\": [\"tester\"]}'" devel:g hw
case_ git-not-in-project  4 "NOT_YOURS — not a maintainer in gorg/_ObsPrj/_maintainership.json (maintainers: boss)" \
  "gitea $M '{\"\": [\"boss\"]}'" devel:g hw
case_ git-reviewer        3 "BLOCKED — explicit reviewer role: qa-bot" \
  "gitea $W '{\"Workflows\": [\"pr\"], \"Reviewers\": [\"+qa-bot\",],}'" devel:g hw
case_ git-reviewer-object 3 "BLOCKED — explicit reviewer role: legal" \
  "gitea $W '{\"Reviewers\": {\"~legal\": {\"IgnoreSubmoduleChanges\": true}}}'" devel:g hw
case_ git-no-workflow     0 "ELIGIBLE" "rm gitea/repos%gorg%_ObsPrj%raw%workflow.config" devel:g hw
case_ git-json-broken     5 "UNREADABLE — gorg/_ObsPrj's _maintainership.json did not parse" "gitea $M '{\"hw\": [\"tester\"'" devel:g hw
case_ git-json-absent     5 "UNREADABLE — gorg/_ObsPrj has no _maintainership.json" \
  "rm gitea/repos%gorg%_ObsPrj%raw%_maintainership.json" devel:g hw
case_ git-json-fails      5 "UNREADABLE — cannot read gorg/_ObsPrj/_maintainership.json" "gitea $M @ERR" devel:g hw
case_ git-workflow-broken 5 "UNREADABLE — gorg/_ObsPrj's workflow.config did not parse" \
  "gitea $W '{\"Reviewers\": \"qa-bot\"}'" devel:g hw
case_ git-other-host      5 "UNREADABLE — devel:g is kept in https://example.org/gorg/_ObsPrj.git, whose maintainers this cannot read" \
  "obs /source/devel:g/_meta '<project name=\"devel:g\"><scmsync>https://example.org/gorg/_ObsPrj.git</scmsync></project>'" devel:g hw
# The roles are read at the branch or commit the <scmsync> fragment names
# (salt/_ObsPrj#main, whose default branch is factory); a fragment that is no
# plain ref is not read at all.
REFMETA='<project name="devel:g"><scmsync>https://src.opensuse.org/gorg/_ObsPrj.git#devel</scmsync><person userid="tester" role="maintainer"/></project>'
case_ git-ref             0 "ELIGIBLE — package maintainer in gorg/_ObsPrj/_maintainership.json at devel" \
  "obs /source/devel:g/_meta '$REFMETA'; gitea $M '{\"hw\": [\"other\"]}'; gitea $M?ref=devel '{\"hw\": [\"tester\"]}'; gitea $W?ref=devel '{}'" devel:g hw
grep -qx 'git-obs -G src.opensuse.org -q api /repos/gorg/_ObsPrj/raw/_maintainership.json?ref=devel' "$work/git-ref/calls" \
  && grep -qx 'git-obs -G src.opensuse.org -q api /repos/gorg/_ObsPrj/raw/workflow.config?ref=devel' "$work/git-ref/calls" \
  && pass "git-ref: both files read at the ref" || fail "git-ref: $(grep git-obs "$work/git-ref/calls")"
case_ git-ref-reviewer    3 "BLOCKED — explicit reviewer role: qa" \
  "obs /source/devel:g/_meta '$REFMETA'; gitea $M?ref=devel '{\"hw\": [\"tester\"]}'; gitea $W?ref=devel '{\"Reviewers\": [\"qa\"]}'" devel:g hw
case_ git-ref-absent      5 "UNREADABLE — gorg/_ObsPrj has no _maintainership.json at devel" \
  "obs /source/devel:g/_meta '$REFMETA'" devel:g hw
n=0
for r in 'a..b' '-x' 'a/b' 'a%20b'; do
  n=$((n+1)); case_ "git-ref-odd-$n" 5 "UNREADABLE — devel:g is kept in https://src.opensuse.org/gorg/_ObsPrj.git#$r, whose ref this cannot read" \
    "obs /source/devel:g/_meta '<project name=\"devel:g\"><scmsync>https://src.opensuse.org/gorg/_ObsPrj.git#$r</scmsync><person userid=\"tester\" role=\"maintainer\"/></project>'" devel:g hw
done
# What the project git names must be plain names: a newline in one split the
# verdict line and lost the reviewers; a URL with a space fell back to the OBS
# persons. Each is UNREADABLE, never ELIGIBLE (tester maintains devel:g in OBS).
case_ git-login-newline   5 "UNREADABLE — gorg/_ObsPrj's _maintainership.json did not parse" \
  "gitea $M '{\"hw\": [\"tester\\n\"]}'; gitea $W '{\"Reviewers\": [\"qa-bot\"]}'" devel:g hw
case_ git-reviewer-newline 5 "UNREADABLE — gorg/_ObsPrj's workflow.config did not parse" \
  "gitea $W '{\"Reviewers\": [\"\\nqa\"]}'" devel:g hw
case_ git-reviewer-comma  5 "UNREADABLE — gorg/_ObsPrj's workflow.config did not parse" \
  "gitea $W '{\"Reviewers\": [\"qa,tester\"]}'" devel:g hw
case_ git-url-space       5 "UNREADABLE — devel:g is kept in https://src.opensuse.org/gorg/_ObsPrj#main x, whose maintainers this cannot read" \
  "obs /source/devel:g/_meta '<project name=\"devel:g\"><scmsync>https://src.opensuse.org/gorg/_ObsPrj#main x</scmsync><person userid=\"tester\" role=\"maintainer\"/></project>'" devel:g hw
# A CDATA section or a comment in <scmsync> leaves sed no URL: UNREADABLE, never the OBS persons.
n=0
for u in '<![CDATA[https://src.opensuse.org/gorg/_ObsPrj]]>' 'https://src.opensuse.org/gorg/_ObsPrj<!-- x -->'; do
  n=$((n+1)); case_ "git-url-markup-$n" 5 "UNREADABLE — devel:g is kept in a <scmsync> that is not plain text or not alone, whose maintainers this cannot read" \
    "obs /source/devel:g/_meta '<project name=\"devel:g\"><scmsync>$u</scmsync><person userid=\"tester\" role=\"maintainer\"/></project>'" devel:g hw
done
# sed takes the last plain <scmsync>, one inside a comment too: a commented one after
# the real one, alone in a project OBS keeps (or in its CDATA), a second one (the same URL
# too), or one repeating the real URL is never read.
EVIL="gitea repos/evil/_ObsPrj/raw/_maintainership.json '{\"hw\": [\"tester\"], \"foo\": [\"tester\"]}'"
CMT='<!-- <scmsync>https://src.opensuse.org/evil/_ObsPrj</scmsync> -->'
case_ git-url-commented   5 "UNREADABLE — devel:g is kept in a <scmsync> that is not plain text or not alone" \
  "$EVIL; gitea $M '{\"hw\": [\"other\"]}'; obs /source/devel:g/_meta '<project name=\"devel:g\"><scmsync>https://src.opensuse.org/gorg/_ObsPrj.git</scmsync>$CMT<person userid=\"tester\" role=\"maintainer\"/></project>'" devel:g hw
case_ obs-url-commented   5 "UNREADABLE — devel:a is kept in a <scmsync> that is not plain text or not alone" \
  "$EVIL; obs /source/devel:a/foo/_meta '<package name=\"foo\"><person userid=\"other\" role=\"maintainer\"/></package>'; obs /source/devel:a/_meta '<project name=\"devel:a\">$CMT<person userid=\"boss\" role=\"maintainer\"/></project>'" devel:a foo
case_ obs-url-cdata       5 "UNREADABLE — devel:a is kept in a <scmsync> that is not plain text or not alone" \
  "$EVIL; obs /source/devel:a/foo/_meta '<package name=\"foo\"><person userid=\"other\" role=\"maintainer\"/></package>'; obs /source/devel:a/_meta '<project name=\"devel:a\"><description><![CDATA[<scmsync>https://src.opensuse.org/evil/_ObsPrj</scmsync>]]></description><person userid=\"boss\" role=\"maintainer\"/></project>'" devel:a foo
case_ git-url-twice       5 "UNREADABLE — devel:g is kept in a <scmsync> that is not plain text or not alone" \
  "$EVIL; gitea $M '{\"hw\": [\"other\"]}'; obs /source/devel:g/_meta '<project name=\"devel:g\"><scmsync>https://src.opensuse.org/gorg/_ObsPrj.git</scmsync><scmsync>https://src.opensuse.org/evil/_ObsPrj</scmsync></project>'" devel:g hw
case_ git-url-doubled     5 "UNREADABLE — devel:g is kept in a <scmsync> that is not plain text or not alone" \
  "obs /source/devel:g/_meta '<project name=\"devel:g\"><scmsync>https://src.opensuse.org/gorg/_ObsPrj.git</scmsync><scmsync>https://src.opensuse.org/gorg/_ObsPrj.git</scmsync></project>'" devel:g hw
case_ git-url-repeated    5 "UNREADABLE — devel:g is kept in a <scmsync> that is not plain text or not alone" \
  "obs /source/devel:g/_meta '<project name=\"devel:g\"><scmsync>https://src.opensuse.org/gorg/_ObsPrj.git</scmsync><!-- <scmsync>https://src.opensuse.org/gorg/_ObsPrj.git</scmsync> --></project>'" devel:g hw
# Absent means none; present, Reviewers is a list or an object, and an entry a list.
for v in false 0 '""' null; do
  case_ "git-reviewers-$v" 5 "UNREADABLE — gorg/_ObsPrj's workflow.config did not parse" \
    "gitea $W '{\"Reviewers\": $v}'" devel:g hw
done
case_ git-entry-false     5 "UNREADABLE — gorg/_ObsPrj's _maintainership.json did not parse" \
  "gitea $M '{\"\": [\"tester\"], \"hw\": false}'" devel:g hw
case_ git-group-entry     4 "NOT_YOURS — not a maintainer in gorg/_ObsPrj/_maintainership.json (maintainers: @team)" \
  "gitea $M '{\"\": [\"tester\"], \"hw\": [\"@team\"]}'" devel:g hw
# An OBS reviewer role still counts.
case_ git-obs-reviewer    3 "BLOCKED — explicit reviewer role: qa" \
  "obs /source/devel:g/_meta '<project name=\"devel:g\"><scmsync>https://src.opensuse.org/gorg/_ObsPrj.git</scmsync><group groupid=\"qa\" role=\"reviewer\"/></project>'" devel:g hw
case_ git-batch           4 $'devel:g/other\tNOT_YOURS' \
  "obs /source/devel:g/other/_meta '<package name=\"other\" project=\"devel:g\"/>'; echo devel:g/other > devel/other; printf 'devel:g\thw\ndevel:g\tother\n' > rows" --batch rows
grep -qF $'devel:g/hw\tELIGIBLE' <<<"$LAST" && [ "$(grep -c 'raw/_maintainership.json$' "$work/git-batch/calls")" = 1 ] \
  && pass "--batch reads a project git's _maintainership.json once" || fail "git-batch: $(grep git-obs "$work/git-batch/calls")"
# One --batch run, project gits whose names a flat key would merge (a_b/c and
# a/b_c), and one project git at two refs: each read for itself.
BATCH2="obs /source/devel:p/x/_meta '<package name=\"x\"/>'; obs /source/devel:p/_meta '<project name=\"devel:p\"><scmsync>https://src.opensuse.org/a_b/c</scmsync></project>'
obs /source/devel:q/x2/_meta '<package name=\"x2\"/>'; obs /source/devel:q/_meta '<project name=\"devel:q\"><scmsync>https://src.opensuse.org/a/b_c</scmsync></project>'
obs /source/devel:r/x3/_meta '<package name=\"x3\"/>'; obs /source/devel:r/_meta '<project name=\"devel:r\"><scmsync>https://src.opensuse.org/a_b/c#v2</scmsync></project>'
gitea repos/a_b/c/raw/_maintainership.json '{\"x\": [\"tester\"], \"x2\": [\"tester\"], \"x3\": [\"tester\"]}'
gitea repos/a/b_c/raw/_maintainership.json '{\"x2\": [\"other\"]}'; gitea repos/a/b_c/raw/workflow.config '{\"Reviewers\": [\"qa\"]}'
gitea 'repos/a_b/c/raw/_maintainership.json?ref=v2' '{\"x3\": [\"other\"]}'
printf 'devel:p\tx\ndevel:q\tx2\ndevel:r\tx3\n' > rows"
case_ git-batch-keys      3 $'devel:q/x2\tBLOCKED\tqa' "$BATCH2" --batch rows
grep -qF $'devel:p/x\tELIGIBLE' <<<"$LAST" && grep -qF $'devel:r/x3\tNOT_YOURS' <<<"$LAST" \
  && pass "--batch keys each project git and ref apart" || fail "git-batch-keys: $LAST"

echo "--- --batch exits with the worst row"
# Packages Factory lacks by name: one package list for the whole --batch run.
case_ batch-one-listing 0 $'devel:a/bar\tELIGIBLE' \
  "obs /source/devel:a/bar/_meta '<package><person userid=\"tester\" role=\"maintainer\"/></package>'; rm devel/foo; printf 'devel:a\tfoo\ndevel:a\tbar\n' > rows" --batch rows
[ "$(grep -c '^osc ls ' "$work/batch-one-listing/calls")" = 1 ] && pass "--batch lists the target once" \
  || fail "--batch listed the target $(grep -c '^osc ls ' "$work/batch-one-listing/calls") times"

ROWS=$'devel:a\tfoo\ndevel:a\tbar'
BAR="obs /source/devel:a/bar/_meta '<package><person userid=\"tester\" role=\"maintainer\"/></package>'"
case_ batch-eligible    0 $'devel:a/bar\tELIGIBLE' \
  "$BAR; echo devel:a/bar > devel/bar; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-wrong       6 $'devel:a/bar\tWRONG-DEVEL' \
  "$BAR; echo devel:c/bar > devel/bar; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-wrong-over-blocked 6 "WRONG-DEVEL" \
  "$BAR; echo devel:c/bar > devel/bar; obs /source/devel:a/foo/_meta '<package><person userid=\"rev\" role=\"reviewer\"/></package>'; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-unreadable-wins 5 "UNREADABLE" \
  "echo devel:c/foo > devel/foo; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-empty       2 "no project/package rows" ": > rows" --batch rows
# A failed project _meta read is not cached as an empty one.
case_ batch-project-unreadable 5 $'devel:a/bar\tUNREADABLE' \
  "$BAR; echo devel:a/bar > devel/bar; obs /source/devel:a/_meta @ERR; printf '%s\n' \"$ROWS\" > rows" --batch rows
[ "$(grep -c '^osc api /source/devel:a/_meta$' "$work/batch-eligible/calls")" = 1 ] \
  && pass "--batch reads each project's _meta once" || fail "--batch: devel:a/_meta not read exactly once"

if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
