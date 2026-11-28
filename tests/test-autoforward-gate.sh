#!/bin/bash
# test-autoforward-gate.sh — autoforward-gate.sh offline: a fake `geectl` on PATH
# answers package-meta, project-meta, link-target, list-packages and gitea
# raw-file lookups from a per-case fixture tree (a missing file is a 404,
# "@ERR" fails the call). The package foo lives in devel:a, which
# openSUSE:Factory names as its devel project; tester maintains it and nobody
# reviews. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
AG="$HERE/../skills/opensuse-packaging/scripts/autoforward-gate.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export GEECTL_OBS_USERNAME=tester

mkdir -p "$work/bin"
cat > "$work/bin/geectl" <<'EOF'
#!/bin/bash
echo "geectl $*" >> "$FIX/calls"
if [ "$1 $2" = "gitea raw-file" ]; then
  # raw-file <owner> <repo> <path> [--ref <ref>]: the fixture keeps the
  # owner/repo/path structure, so a_b/c and a/b_c stay apart.
  f="$FIX/raw/$3%$4%$(printf %s "$5" | tr / %)"
  [ "$6" = --ref ] && f="$f%ref=$7"
  [ -f "$f" ] || { printf '%s' '{"error":{"code":"not_found","context":"fake 404"}}' >&2; exit 3; }
  [ "$(cat "$f")" = @ERR ] && { echo "Server returned an error: HTTP Error 500" >&2; exit 1; }
  cat "$f"
  exit 0
fi
f="$FIX/meta/$(printf %s "$*" | tr -c 'A-Za-z0-9' '_')"
[ -f "$f" ] || { printf '%s' '{"error":{"code":"not_found","context":"fake 404"}}' >&2; exit 3; }
[ "$(cat "$f")" = @ERR ] && { echo "Server returned an error: HTTP Error 500" >&2; exit 1; }
cat "$f"
EOF
chmod +x "$work/bin/geectl"
B="$work/base"
mkdir -p "$B/meta" "$B/raw"
meta() { printf '%s\n' "$2" > "$B/meta/$(printf %s "$1" | tr -c 'A-Za-z0-9' '_')"; }
nometa() { rm -f "$B/meta/$(printf %s "$1" | tr -c 'A-Za-z0-9' '_')"; }
# A project git's file, repos/<owner>/<repo>/raw/<path>[?ref=<ref>], as the
# fake-geectl raw-file fixture: $B/raw/<owner>%<repo>%<path, / as %>
# [%ref=<ref>].
gitea() {
  local p="$1" ref="" owner rest repo fpath f
  case "$p" in *\?ref=*) ref="${p#*\?ref=}"; p="${p%%\?ref=*}";; esac
  p="${p#repos/}"; owner="${p%%/*}"; rest="${p#*/}"; repo="${rest%%/*}"; fpath="${rest#*/raw/}"
  f="$B/raw/$owner%$repo%$(printf %s "$fpath" | tr / %)"
  [ -n "$ref" ] && f="$f%ref=$ref"
  printf '%s\n' "$2" > "$f"
}
FOO_META='{"name": "foo", "project": "devel:a", "persons": [{"name": "tester", "role": "maintainer"}], "groups": []}'
FOO_FACTORY='{"name": "foo", "project": "openSUSE:Factory", "devel": {"project": "devel:a", "package": "foo"}, "persons": [], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
FACTORY_FOO='{"name": "foo", "project": "openSUSE:Factory", "persons": [{"name": "tester", "role": "maintainer"}], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
FACTORY_DEVEL_B='{"name": "foo", "project": "openSUSE:Factory", "devel": {"project": "devel:b", "package": "foo"}, "persons": [], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
FACTORY_NODEVEL='{"name": "foo", "project": "openSUSE:Factory", "persons": [], "groups": []}'
PROJ_META='{"name": "devel:a", "persons": [{"name": "boss", "role": "maintainer"}], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
PROJ_TESTER='{"name": "devel:a", "persons": [{"name": "tester", "role": "maintainer"}], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
PROJ_REVIEWER='{"name": "devel:a", "persons": [{"name": "boss", "role": "maintainer"}], "groups": [{"name": "qa", "role": "reviewer"}]}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
NOMAINT='{"name": "foo", "project": "devel:a", "persons": [], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
REVIEWER_META='{"name": "foo", "project": "devel:a", "persons": [{"name": "tester", "role": "maintainer"}, {"name": "rev", "role": "reviewer"}], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
OTHER_META='{"name": "foo", "project": "devel:a", "persons": [{"name": "other", "role": "maintainer"}], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
LINK_HERE='{"project": "devel:b", "package": "foo", "target": {"project": "devel:a"}}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
LINK_ELSEWHERE='{"project": "devel:b", "package": "foo", "target": {"project": "openSUSE:Factory"}}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
LINK_OTHER='{"project": "devel:b", "package": "foo", "target": {"project": "devel:a", "package": "bar"}}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
LINK_DEVELXA='{"project": "devel:b", "package": "foo", "target": {"project": "develxa"}}'
GIT_PROJ='{"name": "devel:g", "scmsync": "https://src.opensuse.org/gorg/_ObsPrj.git", "persons": [{"name": "tester", "role": "maintainer"}], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
GIT_PROJ_QA='{"name": "devel:g", "scmsync": "https://src.opensuse.org/gorg/_ObsPrj.git", "persons": [], "groups": [{"name": "qa", "role": "reviewer"}]}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
GIT_PROJ_OTHER='{"name": "devel:g", "scmsync": "https://example.org/gorg/_ObsPrj.git", "persons": [{"name": "tester", "role": "maintainer"}], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
GIT_PROJ_REF='{"name": "devel:g", "scmsync": "https://src.opensuse.org/gorg/_ObsPrj.git#devel", "persons": [{"name": "tester", "role": "maintainer"}], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
BAR_META='{"name": "bar", "project": "devel:a", "persons": [{"name": "tester", "role": "maintainer"}], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
BAR_FACTORY_A='{"name": "bar", "project": "openSUSE:Factory", "devel": {"project": "devel:a", "package": "bar"}, "persons": [], "groups": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
BAR_FACTORY_C='{"name": "bar", "project": "openSUSE:Factory", "devel": {"project": "devel:c", "package": "bar"}, "persons": [], "groups": []}'
meta 'remote package-meta devel:a foo' "$FOO_META"
meta 'remote project-meta devel:a' "$PROJ_META"
meta 'remote package-meta openSUSE:Factory foo' "$FOO_FACTORY"
meta 'remote project-meta openSUSE:Factory' '{"name": "openSUSE:Factory", "persons": [], "groups": []}'
meta 'remote list-packages openSUSE:Factory' '{"project": "openSUSE:Factory", "packages": []}'
# devel:g is kept in git (hwdata in devel:openSUSE:Factory): its package meta
# is a stub, its roles are in gorg/_ObsPrj; tester maintains hw there.
meta 'remote package-meta devel:g hw' '{"name": "hw", "project": "devel:g", "persons": [], "groups": []}'
meta 'remote project-meta devel:g' "$GIT_PROJ"
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

echo "--- the reviewer role gates, maintainership decides"
case_ eligible          0 "ELIGIBLE — package maintainer" : devel:a foo
case_ project-maint     0 "ELIGIBLE — package unmaintained, project maintainer" \
  "meta 'remote package-meta devel:a foo' \"\$NOMAINT\"; meta 'remote project-meta devel:a' \"\$PROJ_TESTER\"" devel:a foo
case_ reviewer          3 "BLOCKED — explicit reviewer role: rev" \
  "meta 'remote package-meta devel:a foo' \"\$REVIEWER_META\"" devel:a foo
case_ project-reviewer  3 "BLOCKED — explicit reviewer role: qa" \
  "meta 'remote project-meta devel:a' \"\$PROJ_REVIEWER\"" devel:a foo
case_ not-yours         4 "NOT_YOURS — maintained by someone else" \
  "meta 'remote package-meta devel:a foo' \"\$OTHER_META\"" devel:a foo
case_ unmaintained      4 "NOT_YOURS — package unmaintained, not a project maintainer" \
  "meta 'remote package-meta devel:a foo' \"\$NOMAINT\"" devel:a foo
case_ unreadable        5 "cannot read the devel:a/foo package meta" "nometa 'remote package-meta devel:a foo'" devel:a foo
# Unread, a project-level reviewer would go unseen.
case_ project-unreadable 5 "cannot read the devel:a/foo package meta" "meta 'remote project-meta devel:a' @ERR" devel:a foo

echo "--- the project must be the one Factory develops the package in"
case_ wrong-devel       6 "WRONG-DEVEL — openSUSE:Factory develops it in devel:b" \
  "meta 'remote package-meta openSUSE:Factory foo' \"\$FACTORY_DEVEL_B\"" devel:a foo
grep -q ELIGIBLE <<<"$LAST" && fail "wrong-devel also said ELIGIBLE" || pass "wrong-devel never reads ELIGIBLE"
case_ link-into-here    0 "ELIGIBLE" \
  "meta 'remote package-meta openSUSE:Factory foo' \"\$FACTORY_DEVEL_B\"; meta 'remote link-target devel:b foo' \"\$LINK_HERE\"" devel:a foo
case_ link-elsewhere    6 "WRONG-DEVEL" \
  "meta 'remote package-meta openSUSE:Factory foo' \"\$FACTORY_DEVEL_B\"; meta 'remote link-target devel:b foo' \"\$LINK_ELSEWHERE\"" devel:a foo
case_ link-other-package 6 "WRONG-DEVEL" \
  "meta 'remote package-meta openSUSE:Factory foo' \"\$FACTORY_DEVEL_B\"; meta 'remote link-target devel:b foo' \"\$LINK_OTHER\"" devel:a foo
case_ link-unreadable   5 "or its Factory devel project" \
  "meta 'remote package-meta openSUSE:Factory foo' \"\$FACTORY_DEVEL_B\"; meta 'remote link-target devel:b foo' @ERR" devel:a foo
# Project names are compared as strings: "devel.a" is no pattern for "develxa".
case_ link-literal      6 "WRONG-DEVEL" \
  "meta 'remote package-meta devel.a foo' \"\$FOO_META\"; meta 'remote project-meta devel.a' '{\"name\": \"devel.a\", \"persons\": [], \"groups\": []}'; meta 'remote package-meta openSUSE:Factory foo' \"\$FACTORY_DEVEL_B\"; meta 'remote link-target devel:b foo' \"\$LINK_DEVELXA\"" devel.a foo
# Factory itself is never another project's devel project.
case_ factory-itself    0 "ELIGIBLE" \
  "meta 'remote package-meta openSUSE:Factory foo' \"\$FACTORY_FOO\"" openSUSE:Factory foo
[ "$(grep -c '^geectl remote package-meta openSUSE:Factory foo$' "$work/factory-itself/calls")" = 1 ] \
  && pass "factory-itself asks for no devel project" || fail "factory-itself: $(grep 'package-meta openSUSE' "$work/factory-itself/calls")"
case_ not-in-factory    0 "ELIGIBLE" "nometa 'remote package-meta openSUSE:Factory foo'" devel:a foo
# Not in Factory by this name, but under another spelling: forwarding it files a duplicate.
case_ not-in-factory-near 6 "WRONG-DEVEL — NOT IN openSUSE:Factory as foo, but it has Foo" \
  "nometa 'remote package-meta openSUSE:Factory foo'; meta 'remote list-packages openSUSE:Factory' '{\"project\": \"openSUSE:Factory\", \"packages\": [\"Foo\"]}'" devel:a foo
case_ no-devel-set      0 "ELIGIBLE" \
  "meta 'remote package-meta openSUSE:Factory foo' \"\$FACTORY_NODEVEL\"" devel:a foo
case_ devel-lookup-fails 5 "or its Factory devel project" \
  "meta 'remote package-meta openSUSE:Factory foo' @ERR" devel:a foo

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
case_ git-no-workflow     0 "ELIGIBLE" "rm raw/gorg%_ObsPrj%workflow.config" devel:g hw
case_ git-json-broken     5 "UNREADABLE — gorg/_ObsPrj's _maintainership.json did not parse" "gitea $M '{\"hw\": [\"tester\"'" devel:g hw
case_ git-json-absent     5 "UNREADABLE — gorg/_ObsPrj has no _maintainership.json" \
  "rm raw/gorg%_ObsPrj%_maintainership.json" devel:g hw
case_ git-json-fails      5 "UNREADABLE — cannot read gorg/_ObsPrj/_maintainership.json" "gitea $M @ERR" devel:g hw
case_ git-workflow-broken 5 "UNREADABLE — gorg/_ObsPrj's workflow.config did not parse" \
  "gitea $W '{\"Reviewers\": \"qa-bot\"}'" devel:g hw
case_ git-other-host      5 "UNREADABLE — devel:g is kept in https://example.org/gorg/_ObsPrj.git, whose maintainers this cannot read" \
  "meta 'remote project-meta devel:g' \"\$GIT_PROJ_OTHER\"" devel:g hw
# The roles are read at the branch or commit the <scmsync> fragment names
# (salt/_ObsPrj#main, whose default branch is factory); a fragment that is no
# plain ref is not read at all.
case_ git-ref             0 "ELIGIBLE — package maintainer in gorg/_ObsPrj/_maintainership.json at devel" \
  "meta 'remote project-meta devel:g' \"\$GIT_PROJ_REF\"; gitea $M '{\"hw\": [\"other\"]}'; gitea $M?ref=devel '{\"hw\": [\"tester\"]}'; gitea $W?ref=devel '{}'" devel:g hw
grep -qx 'geectl gitea raw-file gorg _ObsPrj _maintainership.json --ref devel' "$work/git-ref/calls" \
  && grep -qx 'geectl gitea raw-file gorg _ObsPrj workflow.config --ref devel' "$work/git-ref/calls" \
  && pass "git-ref: both files read at the ref" || fail "git-ref: $(grep 'gitea raw-file' "$work/git-ref/calls")"
case_ git-ref-reviewer    3 "BLOCKED — explicit reviewer role: qa" \
  "meta 'remote project-meta devel:g' \"\$GIT_PROJ_REF\"; gitea $M?ref=devel '{\"hw\": [\"tester\"]}'; gitea $W?ref=devel '{\"Reviewers\": [\"qa\"]}'" devel:g hw
case_ git-ref-absent      5 "UNREADABLE — gorg/_ObsPrj has no _maintainership.json at devel" \
  "meta 'remote project-meta devel:g' \"\$GIT_PROJ_REF\"" devel:g hw
n=0
for r in 'a..b' '-x' 'a/b' 'a%20b'; do
  n=$((n+1)); case_ "git-ref-odd-$n" 5 "UNREADABLE — devel:g is kept in https://src.opensuse.org/gorg/_ObsPrj.git#$r, whose ref this cannot read" \
    "meta 'remote project-meta devel:g' '{\"name\": \"devel:g\", \"scmsync\": \"https://src.opensuse.org/gorg/_ObsPrj.git#$r\", \"persons\": [{\"name\": \"tester\", \"role\": \"maintainer\"}], \"groups\": []}'" devel:g hw
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
  "meta 'remote project-meta devel:g' '{\"name\": \"devel:g\", \"scmsync\": \"https://src.opensuse.org/gorg/_ObsPrj#main x\", \"persons\": [{\"name\": \"tester\", \"role\": \"maintainer\"}], \"groups\": []}'" devel:g hw
# The scmsync field is one plain string by construction: a value that is no
# src.opensuse.org URL at all is UNREADABLE, never the OBS persons.
case_ git-url-not-a-url   5 "UNREADABLE — devel:g is kept in not a url, whose maintainers this cannot read" \
  "meta 'remote project-meta devel:g' '{\"name\": \"devel:g\", \"scmsync\": \"not a url\", \"persons\": [{\"name\": \"tester\", \"role\": \"maintainer\"}], \"groups\": []}'" devel:g hw
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
case_ obs-reviewer        3 "BLOCKED — explicit reviewer role: qa" \
  "meta 'remote project-meta devel:g' \"\$GIT_PROJ_QA\"" devel:g hw
case_ git-batch           4 $'devel:g/other\tNOT_YOURS' \
  "meta 'remote package-meta devel:g other' '{\"name\": \"other\", \"project\": \"devel:g\", \"persons\": [], \"groups\": []}'; printf 'devel:g\thw\ndevel:g\tother\n' > rows" --batch rows
grep -qF $'devel:g/hw\tELIGIBLE' <<<"$LAST" && [ "$(grep -c 'gitea raw-file gorg _ObsPrj _maintainership.json$' "$work/git-batch/calls")" = 1 ] \
  && pass "--batch reads a project git's _maintainership.json once" || fail "git-batch: $(grep 'gitea raw-file' "$work/git-batch/calls")"
# One --batch run, project gits whose names a flat key would merge (a_b/c and
# a/b_c), and one project git at two refs: each read for itself.
BATCH2="meta 'remote package-meta devel:p x' '{\"name\": \"x\", \"project\": \"devel:p\", \"persons\": [], \"groups\": []}'; meta 'remote project-meta devel:p' '{\"name\": \"devel:p\", \"scmsync\": \"https://src.opensuse.org/a_b/c\", \"persons\": [], \"groups\": []}'
meta 'remote package-meta devel:q x2' '{\"name\": \"x2\", \"project\": \"devel:q\", \"persons\": [], \"groups\": []}'; meta 'remote project-meta devel:q' '{\"name\": \"devel:q\", \"scmsync\": \"https://src.opensuse.org/a/b_c\", \"persons\": [], \"groups\": []}'
meta 'remote package-meta devel:r x3' '{\"name\": \"x3\", \"project\": \"devel:r\", \"persons\": [], \"groups\": []}'; meta 'remote project-meta devel:r' '{\"name\": \"devel:r\", \"scmsync\": \"https://src.opensuse.org/a_b/c#v2\", \"persons\": [], \"groups\": []}'
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
  "meta 'remote package-meta devel:a bar' \"\$BAR_META\"; nometa 'remote package-meta openSUSE:Factory foo'; printf 'devel:a\tfoo\ndevel:a\tbar\n' > rows" --batch rows
[ "$(grep -c '^geectl remote list-packages openSUSE:Factory$' "$work/batch-one-listing/calls")" = 1 ] && pass "--batch lists the target once" \
  || fail "--batch listed the target $(grep -c '^geectl remote list-packages openSUSE:Factory$' "$work/batch-one-listing/calls") times"

ROWS=$'devel:a\tfoo\ndevel:a\tbar'
BAR="meta 'remote package-meta devel:a bar' \"\$BAR_META\""
case_ batch-eligible    0 $'devel:a/bar\tELIGIBLE' \
  "$BAR; meta 'remote package-meta openSUSE:Factory bar' \"\$BAR_FACTORY_A\"; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-wrong       6 $'devel:a/bar\tWRONG-DEVEL' \
  "$BAR; meta 'remote package-meta openSUSE:Factory bar' \"\$BAR_FACTORY_C\"; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-wrong-over-blocked 6 "WRONG-DEVEL" \
  "$BAR; meta 'remote package-meta openSUSE:Factory bar' \"\$BAR_FACTORY_C\"; meta 'remote package-meta devel:a foo' \"\$REVIEWER_META\"; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-unreadable-wins 5 "UNREADABLE" \
  "$BAR; meta 'remote package-meta openSUSE:Factory bar' \"\$BAR_FACTORY_C\"; meta 'remote project-meta devel:a' @ERR; printf '%s\n' \"$ROWS\" > rows" --batch rows
case_ batch-empty       2 "no project/package rows" ": > rows" --batch rows
# A failed project _meta read is not cached as an empty one.
case_ batch-project-unreadable 5 $'devel:a/bar\tUNREADABLE' \
  "$BAR; meta 'remote package-meta openSUSE:Factory bar' \"\$BAR_FACTORY_A\"; meta 'remote project-meta devel:a' @ERR; printf '%s\n' \"$ROWS\" > rows" --batch rows
[ "$(grep -c '^geectl remote project-meta devel:a$' "$work/batch-eligible/calls")" = 1 ] \
  && pass "--batch reads each project's _meta once" || fail "--batch: devel:a/_meta not read exactly once"

if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
