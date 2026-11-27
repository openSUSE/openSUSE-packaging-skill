#!/bin/bash
# test-preflight.sh — preflight.sh offline: a fake `geectl` on PATH
# answer from a per-case fixture tree (a missing fixture is a 404, one holding
# @500 a 500), and a fake `curl` fails and records that it was called. The base
# package foo has devel devel:example at 1.1 against openSUSE:Factory at 1.0,
# nothing in flight, and one declined devel->Factory SR. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PF="$HERE/../skills/opensuse-packaging/scripts/preflight.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/geectl" <<'EOF'
#!/bin/bash
echo "geectl $*" >> "$FIX/calls"; readlink "/proc/$$/fd/2" >> "$FIX/stderr-paths"
case "$*" in
  "remote devel-project "*) [ -e "$FIX/no-develproject" ] && exit 1; f=devel-project ;;
  "remote package-meta "*) f="meta-$(printf %s "$3" | tr '/' '_')_$(printf %s "$4" | tr '/' '_')" ;;
  "remote project-meta "*) f="meta-$(printf %s "$3" | tr '/' '_')_project" ;;
  "remote link-target "*) f="link-$(printf %s "$3" | tr '/' '_')_$(printf %s "$4" | tr '/' '_')" ;;
  "remote cat --format text "*) f="cat-$(printf %s "$5" | tr '/' '_')_$(printf %s "$6" | tr '/' '_')_$(printf %s "$7" | tr '/' '_')" ;;
  "remote list-packages "*) f="ls-$(printf %s "$3" | tr '/' '_')" ;;
  "request search "*) f="search-$(printf %s "$*" | tr -c 'A-Za-z0-9._:-' '_')" ;;
  "pull-request search "*) f="prs-$(printf %s "$*" | tr -c 'A-Za-z0-9._:-' '_')" ;;
  "gitea raw-file "*) f="raw-$3%$4%$(printf %s "$5" | tr / %)" ; [ "$6" = --ref ] && f="$f%ref=$7" ;;
  *) echo "fake geectl: unexpected $*" >&2; exit 99 ;;
esac
[ -f "$FIX/$f" ] || {
  case "$*" in
    "remote cat --format text "*)
      printf 'error: https://api.opensuse.org/public/source/%s/%s/%s returned 404\nremediation: check the project, package, or request name and retry\n' "$5" "$6" "$7" >&2; exit 3 ;;
  esac
  printf '{"error":{"code":"not_found","context":"no such thing"}}\n' >&2; exit 3
}
[ "$(cat "$FIX/$f")" = @HANG ] && exec sleep 20
[ "$(cat "$FIX/$f")" = @500 ] && { echo "Server returned an error: HTTP Error 500: Internal" >&2; exit 1; }
cat "$FIX/$f"
EOF
cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$FIX/calls"
echo "curl: (7) Failed to connect" >&2; exit 7
EOF
chmod +x "$work/bin/"*

B="$work/base"
put() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1"; }
# srch <query> <json> — the request-search fixture for the query as preflight.sh passes it
srch() { printf '%s\n' "$2" > "$B/search-$(printf %s "request search $1" | tr -c 'A-Za-z0-9._:-' '_')"; }
# spath <query> — that fixture's path under $B (the case's copy in a mutation)
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
spath() { printf '%s/search-%s' "$B" "$(printf %s "request search $1" | tr -c 'A-Za-z0-9._:-' '_')"; }
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
Q_PRS="--backend gitea --repo example/foo --state open"
# prs <query> <json> — the pull-request-search fixture for the query as preflight.sh passes it
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
prs() { printf '%s\n' "$2" > "$B/prs-$(printf %s "pull-request search $1" | tr -c 'A-Za-z0-9._:-' '_')"; }
Q_IN="--target-project devel:example --target-package foo --type submit --state new --state review"
Q_OUT="--target-project openSUSE:Factory --target-package foo --type submit --state new --state review --source-project devel:example"
Q_DEC="--target-project openSUSE:Factory --target-package foo --type submit --state declined --source-project devel:example"
Q_SWEEP="--target-package foo --type submit --state new --state review"
put "$B/devel-project" '{"package": "foo", "devel_project": "devel:example", "devel_package": "foo"}'
put "$B/meta-devel:example_foo" '{"name": "foo", "project": "devel:example", "persons": [], "groups": []}'
put "$B/meta-devel:example_project" '{"name": "devel:example", "persons": [], "groups": [], "scmsync": null}'
put "$B/meta-openSUSE:Factory_foo" '{"name": "foo", "project": "openSUSE:Factory", "persons": [], "groups": [], "devel": null}'
put "$B/cat-devel:example_foo_foo.spec" 'Name: foo
Version: 1.1'
put "$B/cat-devel:example_foo_foo.changes" '-------------------------------------------------------------------
Mon Sep 14 10:00:00 UTC 2026 - Jane Packager <jane@example.com>

- Update to 1.1'
put "$B/cat-openSUSE:Factory_foo_foo.spec" 'Name: foo
Version: 1.0'
put "$B/ls-openSUSE:Factory" '{"project": "openSUSE:Factory", "packages": ["foo", "python-Authlib", "python-Authlib:test", "python-zope.interface", "python-pytest-lazy-fixtures"]}'
srch "$Q_IN" '{"requests": []}'
srch "$Q_OUT" '{"requests": []}'
srch "$Q_DEC" '{"requests": [{"id": 1375013, "creator": "tester", "state": {"name": "declined", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:example", "source_package": "foo", "target_project": "openSUSE:Factory", "target_package": "foo"}], "reviews": []}]}'
srch "$Q_SWEEP" '{"requests": []}'

# inq/outg/sweep take the requests array and write that search fixture
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
inq() { srch "$Q_IN" "{\"requests\": [$1]}"; }
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
outg() { srch "$Q_OUT" "{\"requests\": [$1]}"; }
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
sweep() { srch "$Q_SWEEP" "{\"requests\": [$1]}"; }
Q_OUT_NEW="--target-project openSUSE:Factory --target-package python-brand-new --type submit --state new --state review"
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
outg_new() { srch "$Q_OUT_NEW" "{\"requests\": [$1]}"; }
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_OTHER_TGT='{"id": 2000001, "creator": "someone-else", "state": {"name": "review", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "openSUSE:Leap:16.0", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_DIRECT='{"id": 2000002, "creator": "someone-else", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "openSUSE:Factory", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_DEDUP_IN='{"id": 2000003, "creator": "someone-else", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "devel:example", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_DEDUP_SWEEP='{"id": 2000004, "creator": "someone-else", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "openSUSE:Leap:16.0", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_NONSUBMIT_1='{"id": 2000005, "creator": "someone-else", "state": {"name": "review", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "set_bugowner", "target_project": "openSUSE:Factory", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_NONSUBMIT_2='{"id": 2000007, "creator": "someone-else", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "add_role", "target_project": "devel:example", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_MIXED='{"id": 2000006, "creator": "someone-else", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "openSUSE:Leap:16.0", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_NEWPKG='{"id": 2000020, "creator": "someone-else", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "python-brand-new", "target_project": "openSUSE:Factory", "target_package": "python-brand-new"}], "reviews": []}'

# case_ <name> <expected rc> <expected message> <mutation> [preflight args after foo]
# XPATH, when set, goes first on PATH. XENV holds extra environment for the run.
XPATH=""; XENV=()
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got; shift 4
  cp -a "$B" "$dir"
  # shellcheck disable=SC2030  # rebinding B to the copy is the point; the parent's B stays the pristine tree
  (B=$dir; cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  mkdir -p "$dir/tmp"
  out="$(cd "$dir" && FIX=$dir HOME=$dir/home GEECTL_OBS_USERNAME=tester TMPDIR=$dir/tmp PATH="${XPATH:+$XPATH:}$work/bin:$PATH" \
    env ${XENV[@]+"${XENV[@]}"} bash "$PF" "${PKG:-foo}" "$@" 2>&1)"; got=$?
  LAST=$out
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}

# A declined SR is not in flight, but a filing still lists every declined
# request from the same source and prompts to supersede them all at once.
# Only your own is yours to supersede, by its id with --supersede; someone
# else's is theirs to revoke. The FORWARD command never prompts.
FWD_CLOSED='VERDICT: FORWARD - stranded devel update (devel already has a newer version than openSUSE:Factory): the forward needs a devel→Factory request, which geectl cannot file yet — report the update as ready to forward and stop'
FWD_FILE_LEAP='run: geectl request file --source-project devel:example --source-package foo --target-project openSUSE:Leap:16.0 --target-package foo --description "<short message>" --changes-entry "<short message>" --live'
Q_OUT_LEAP="--target-project openSUSE:Leap:16.0 --target-package foo --type submit --state new --state review --source-project devel:example"
Q_DEC_LEAP="--target-project openSUSE:Leap:16.0 --target-package foo --type submit --state declined --source-project devel:example"
case_ declined-own 4 "-> 1375013 is yours: a refile would supersede it, but geectl cannot file a request targeting openSUSE:Factory yet, so it stays listed as open" ":"
grep -qF "$FWD_CLOSED" <<<"$LAST" && grep -qF 'filing still lists them as open' <<<"$LAST" \
  && ! grep -qF -- '--yes' <<<"$LAST" && ! grep -qF "geectl request refile" <<<"$LAST" \
  && pass "declined-own: FORWARD fails closed, never prompts" \
  || fail "declined-own: $LAST"
case_ declined-foreign 4 "-> 1375013 is by someone-else, not yours to supersede: ask them to revoke it, or leave it" \
  "sed -i 's/\"creator\": \"tester\"/\"creator\": \"someone-else\"/' \$(spath \"\$Q_DEC\")"
! grep -qF -- "--supersede 1375013" <<<"$LAST" && grep -qF "$FWD_CLOSED" <<<"$LAST" \
  && pass "declined-foreign: no --supersede for someone else's SR" || fail "declined-foreign: $LAST"
XENV=(GEECTL_OBS_USERNAME=)
case_ declined-owner-unknown 4 "could not tell which are yours" ":"
XENV=()
! grep -qF -- "--supersede 1375013" <<<"$LAST" && pass "declined-owner-unknown: no --supersede" || fail "declined-owner-unknown: $LAST"
XENV=(GEECTL_OBS_USERNAME=)
case_ declined-user-flag 4 "-> 1375013 is yours" ":" --user tester
XENV=()
case_ no-declined 4 "$FWD_CLOSED" "srch \"\$Q_DEC\" '{\"requests\": []}'"
! grep -qF "DECLINED" <<<"$LAST" && pass "no-declined: nothing to supersede" || fail "no-declined: $LAST"

# A non-Factory target still gets the exact filing command: the refusal is
# Factory's, not the command's.
case_ leap-forward 4 "$FWD_FILE_LEAP" "put \$B/cat-openSUSE:Leap:16.0_foo_foo.spec 'Version: 1.0' && srch \"$Q_OUT_LEAP\" '{\"requests\": []}' && srch \"$Q_DEC_LEAP\" '{\"requests\": []}'" 1.1 --target-project openSUSE:Leap:16.0

# The anchored queries are read against the devel and target projects, and
# the outgoing one is filtered to devel sources. The target-agnostic sweep
# sees the rest: an SR filed straight at the target from a non-devel source
# is in flight (STOP); one aimed at another target entirely is printed for
# the report and changes no verdict; a failed sweep is CHECK-FAILED.
case_ sweep-none 4 "sweep SRs:      none" ":"
case_ sweep-other-target 4 "SR 2000001 [review] devel:other/foo -> openSUSE:Leap:16.0 by someone-else" \
  "sweep \"\$SR_OTHER_TGT\""
grep -qF "VERDICT: FORWARD" <<<"$LAST" && pass "sweep-other-target: verdict unchanged" || fail "sweep-other-target: $LAST"
case_ sweep-direct-to-target 3 "VERDICT: STOP - already in flight: SR 2000002 [new] devel:other/foo -> openSUSE:Factory by someone-else" \
  "sweep \"\$SR_DIRECT\""
case_ sweep-lookup-failed 2 "CHECK FAILED: could not query other SRs targeting foo" \
  "echo @500 > \$(spath \"\$Q_SWEEP\")"
case_ sweep-dedup 3 "SR 2000004 [new] devel:other/foo -> openSUSE:Leap:16.0 by someone-else" \
  "inq \"\$SR_DEDUP_IN\" && sweep \"\$SR_DEDUP_IN, \$SR_DEDUP_SWEEP\""
# SR 2000003 is named exactly twice — the incoming listing and the STOP
# verdict line quoting it; a third naming would be the sweep repeating it.
[ "$(grep -c 'SR 2000003' <<<"$LAST")" = 2 ] && pass "sweep-dedup: an SR the anchored checks listed is not repeated" || fail "sweep-dedup: $LAST"

# Only a submit request moves code: a set_bugowner or add_role request
# against the package is not an update in flight, however it is aimed
# (sr#1383747 was a set_bugowner request and read as a STOP for runc).
case_ sweep-non-submit 4 "sweep SRs:      none" \
  "sweep \"\$SR_NONSUBMIT_1, \$SR_NONSUBMIT_2\""
! grep -qE "VERDICT: STOP|2000005|2000007" <<<"$LAST" && pass "sweep-non-submit: role requests are not in flight" || fail "sweep-non-submit: $LAST"
# A non-submit request beside a real one changes nothing either: the submit
# is reported, the role request is dropped.
case_ sweep-mixed-actions 4 "SR 2000006 [new] devel:other/foo -> openSUSE:Leap:16.0 by someone-else" \
  "sweep \"\$SR_NONSUBMIT_1, \$SR_MIXED\""
grep -qF "VERDICT: FORWARD" <<<"$LAST" && ! grep -q "2000005" <<<"$LAST" \
  && pass "sweep-mixed-actions: only the submit is reported" || fail "sweep-mixed-actions: $LAST"

# A + in a package name is a URL trap only when the name goes into a query
# string; geectl takes it as an argv, so it is passed as-is, never encoded
# and never decoded as a space (libsigc++3 read as "libsigc  3" printed
# "none" while sr#1386760 was open). No fixtures exist for foo++, so every
# read 404s and the run ends PROCEED; what is asserted is the calls log —
# the geectl argv carries a literal foo++, never %2B.
dir="$work/pkg-plus"
# shellcheck disable=SC2031  # B is rebound only inside the mutation subshell; here it is still the pristine tree
cp -a "$B" "$dir"; mkdir -p "$dir/tmp"
out="$(cd "$dir" && FIX=$dir GEECTL_OBS_USERNAME=tester TMPDIR=$dir/tmp PATH="$work/bin:$PATH" bash "$PF" 'foo++' 2>&1)"; got=$?
calls="$(cat "$dir/calls")"
[ "$got" = 0 ] && grep -qF 'foo++' <<<"$calls" && ! grep -qF 'foo%2B%2B' <<<"$calls" \
  && ! grep -qF 'foo  ' <<<"$calls" \
  && pass "pkg-plus: a + is passed as-is in geectl argv, never encoded" \
  || { fail "pkg-plus: expected rc=0 and a literal foo++ in the calls, got rc=$got"; printf '%s\n' "$calls" | sed 's/^/    /'; }

# A git devel project's in-flight update is a PR on src.opensuse.org, read
# through `geectl pull-request search`. A failed or unreadable read is
# CHECK-FAILED, never "open PRs: none".
SCM="put \$B/meta-devel:example_project '{\"name\": \"devel:example\", \"persons\": [], \"groups\": [], \"scmsync\": \"https://src.opensuse.org/example/_ObsPrj\"}'"
# A PR's head: the one it has now, and an older one a review may have been of.
HEAD1=1111111111111111111111111111111111111111; HEAD0=0000000000000000000000000000000000000000
SRC="\"source\": {\"repository\": \"tester/foo\", \"branch\": \"update-foo\", \"commit\": \"$HEAD1\"}"
TGT="\"target\": {\"repository\": \"example/foo\", \"branch\": \"factory\", \"commit\": \"$HEAD0\"}"
case_ scm-no-prs 4 "open PRs:       none" "$SCM && prs \"\$Q_PRS\" '[]'"
no_curl() { ! grep -q '^curl ' "$work/$1/calls" && pass "$1: geectl, not curl" || fail "$1: curl was called"; }
no_curl scm-no-prs
case_ scm-pr-open 3 "VERDICT: STOP - already in flight: PR #5 -> factory: Update foo to 1.2" \
  "$SCM && prs \"\$Q_PRS\" '[{\"reference\": \"gitea:example/foo#5\", \"title\": \"Update foo to 1.2\", \"author\": \"tester\", \"status\": \"open\", $SRC, $TGT}]'"
! grep -qF "$HEAD1" <<<"$LAST" && pass "scm-pr-open: the head is not shown" || fail "scm-pr-open: $LAST"
case_ scm-pr-lookup-failed 2 "CHECK FAILED: could not query open PRs on example/foo: {\"error\":{\"code\":\"not_found\",\"context\":\"no such thing\"}}" "$SCM"
grep -qF "VERDICT: CHECK-FAILED" <<<"$LAST" && ! grep -qF "open PRs:       none" <<<"$LAST" \
  && pass "scm-pr-lookup-failed: not read as none" || fail "scm-pr-lookup-failed: $LAST"
case_ scm-pr-unparsable 2 "unparseable PR list for example/foo" "$SCM && prs \"\$Q_PRS\" '<html>'"
case_ scm-pr-empty-answer 2 "unparseable PR list for example/foo" "$SCM && prs \"\$Q_PRS\" ''"
# Captured stderr goes to a mktemp file under $TMPDIR, never a predictable
# /tmp path another user could plant first.
paths="$(cat "$work/scm-no-prs/stderr-paths")"
grep -q "^$work/scm-no-prs/tmp/" <<<"$paths" && ! grep -q '^/tmp/preflight\.' <<<"$paths" \
  && pass "stderr captured under \$TMPDIR" || fail "stderr capture paths: $paths"
left="$(find "$work/scm-no-prs/tmp" "$work/scm-pr-lookup-failed/tmp" -type f)"
[ -z "$left" ] && pass "the capture file is removed, on CHECK-FAILED too" || fail "left behind: $left"
# A geectl read that never answers is cut off and CHECK-FAILED. A stand-in
# `timeout` gives the real one 2s whatever the script asks for.
mkdir -p "$work/tbin"
printf '#!/bin/bash\nshift\nexec %q 2 "$@"\n' "$(command -v timeout)" > "$work/tbin/timeout" && chmod +x "$work/tbin/timeout"
XPATH="$work/tbin"
case_ scm-pr-hang 2 "CHECK FAILED: could not query open PRs on example/foo: geectl timed out after 30s" \
  "$SCM && prs \"\$Q_PRS\" @HANG"
XPATH=""
! grep -qF "open PRs:       none" <<<"$LAST" && pass "scm-pr-hang: not read as none" || fail "scm-pr-hang: $LAST"
case_ scm-pr-no-author 2 "unparseable PR list for example/foo" \
  "$SCM && prs \"\$Q_PRS\" '[{\"reference\": \"gitea:example/foo#5\", \"title\": \"Update foo to 1.2\", \"status\": \"open\", $SRC, $TGT}]'"
# Without a head nobody can tell whether a review is still of the PR.
case_ scm-pr-no-head 2 "unparseable PR list for example/foo" \
  "$SCM && prs \"\$Q_PRS\" '[{\"reference\": \"gitea:example/foo#5\", \"title\": \"Update foo to 1.2\", \"author\": \"tester\", \"status\": \"open\", $TGT}]'"

# A contributor's open SR or devel PR on a package you maintain is reviewed
# before your update: INCOMING (5), each item annotated from its review stamp,
# a BLOCK one too, as it still waits. Your own request in flight still STOPs
# (3), a failed check still beats both (2), and an incoming item beats a
# stranded update (4). Someone else's forward to the target is in flight, not
# yours to review, and so is a contributor's SR on a package you do not
# maintain. The stamps sit under the suite's HOME, the state directory read
# from a fixture: pr-guard reads this suite.
STAMPS="home/$(cat "$HERE/fixtures/gate/state-dir")/incoming"
# shellcheck disable=SC2031,SC2317  # called by case_'s mutations, where B is the case's copy
stamp() { mkdir -p "$B/$STAMPS/$1" && printf '%s\n' "$3" > "$B/$STAMPS/$1/$2.json"; }
MAINT="put \$B/meta-devel:example_foo '{\"name\": \"foo\", \"project\": \"devel:example\", \"persons\": [{\"name\": \"tester\", \"role\": \"maintainer\"}], \"groups\": []}'"
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_C='{"id": 2000010, "creator": "someone-else", "state": {"name": "review", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "devel:example", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_OWN='{"id": 2000011, "creator": "tester", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "devel:example", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_FWD='{"id": 2000012, "creator": "someone-else", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:example", "source_package": "foo", "target_project": "openSUSE:Factory", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_NOCREATOR='{"id": 2000010, "state": {"name": "review", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "devel:example", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
SR_2ACT='{"id": 2000013, "creator": "someone-else", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "set_bugowner", "target_project": "devel:example", "target_package": "foo"}, {"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "devel:example", "target_package": "foo"}], "reviews": []}'
# shellcheck disable=SC2016  # a case mutation is single-quoted to be eval'd in its tree
CONTRIB='inq "$SR_C"' 
case_ incoming-only 5 "VERDICT: INCOMING" "$MAINT && $CONTRIB" 1.2
grep -qF "sr#2000010 by someone-else: not reviewed" <<<"$LAST" && pass "incoming-only: the item and its creator" || fail "incoming-only: $LAST"
case_ own-and-incoming 3 "VERDICT: STOP - already in flight: SR 2000011 [new] devel:other/foo -> devel:example by tester" \
  "$MAINT && inq \"\$SR_C, \$SR_OWN\""
grep -qF "sr#2000010 by someone-else: not reviewed" <<<"$LAST" && pass "own-and-incoming: the contributor's SR is listed" || fail "own-and-incoming: $LAST"
PR_C="$SCM && put \$B/raw-example%_ObsPrj%_maintainership.json '{\"foo\": [\"tester\"]}' \
   && prs \"\$Q_PRS\" '[{\"reference\": \"gitea:example/foo#5\", \"title\": \"Update foo to 1.2\", \"author\": \"someone-else\", \"status\": \"open\", $SRC, $TGT}]'"
case_ incoming-pr 5 "example/foo#5 by someone-else: not reviewed" "$PR_C"
grep -qF "VERDICT: INCOMING" <<<"$LAST" && pass "incoming-pr: INCOMING" || fail "incoming-pr: $LAST"
case_ others-forward 3 "VERDICT: STOP - already in flight: SR 2000012 [new] devel:example/foo -> openSUSE:Factory by someone-else" \
  "$MAINT && inq \"\$SR_FWD\" && outg \"\$SR_FWD\""
! grep -qF "sr#2000012" <<<"$LAST" && pass "others-forward: a forward is no contributor's submission" || fail "others-forward: $LAST"
case_ incoming-and-ahead 5 "VERDICT: INCOMING" "$MAINT && $CONTRIB"
# After the review: what devel already has is on the verdict line, so nobody
# repackages it.
grep -qF "after it: devel already has a newer version than openSUSE:Factory, forward it, do not repackage" <<<"$LAST" \
  && pass "incoming-and-ahead: says devel already has it" || fail "incoming-and-ahead: $LAST"
case_ incoming-landed 5 "after it: nothing to package, devel:example and openSUSE:Factory are both at 1.1" \
  "$MAINT && $CONTRIB && printf 'Name: foo\nVersion: 1.1\n' > \$B/cat-openSUSE:Factory_foo_foo.spec" 1.1
case_ incoming-not-mine 3 "VERDICT: STOP - already in flight: SR 2000010" "$CONTRIB"
# A contributor's request that submits to devel and to the target is in flight
# at the target, whichever action comes first: the sweep keeps its target
# action, though the devel one is listed as incoming.
A_DEV='{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "devel:example", "target_package": "foo"}'
A_TGT='{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "openSUSE:Factory", "target_package": "foo"}'
for order in "$A_DEV,$A_TGT" "$A_TGT,$A_DEV"; do
  # shellcheck disable=SC2034  # expanded by the case_ mutations, through eval
  sr="{\"requests\": [{\"id\": 2000014, \"creator\": \"someone-else\", \"state\": {\"name\": \"new\", \"when\": \"2026-09-22T10:00:00\"}, \"actions\": [$order], \"reviews\": []}]}"
  case_ "incoming-and-target-$([ "$order" = "$A_DEV,$A_TGT" ] && echo devel-first || echo target-first)" 3 \
    "VERDICT: STOP - already in flight: SR 2000014 [new] devel:other/foo -> openSUSE:Factory by someone-else" \
    "$MAINT && srch \"\$Q_IN\" \"\$sr\" && srch \"\$Q_SWEEP\" \"\$sr\""
done
# Your own PR in flight beats a contributor's.
case_ own-pr-and-incoming 3 "VERDICT: STOP - already in flight: PR #6 -> factory: My update (https://src.opensuse.org/example/foo/pulls/6) by tester" \
  "$SCM && put \$B/raw-example%_ObsPrj%_maintainership.json '{\"foo\": [\"tester\"]}' \
   && prs \"\$Q_PRS\" '[{\"reference\": \"gitea:example/foo#5\", \"title\": \"Update foo\", \"author\": \"someone-else\", \"status\": \"open\", $SRC, $TGT},
             {\"reference\": \"gitea:example/foo#6\", \"title\": \"My update\", \"author\": \"tester\", \"status\": \"open\", $SRC, $TGT}]'"
# Who maintains it is no answer when the lookup crashed, came back empty or
# does not parse: CHECK-FAILED, never "not yours".
case_ maintainer-deep-json 2 "CHECK FAILED: could not tell whether you maintain devel:example/foo" \
  "$SCM && printf '%*s' 100000 '' | tr ' ' '[' > \$B/raw-example%_ObsPrj%_maintainership.json \
   && prs \"\$Q_PRS\" '[{\"reference\": \"gitea:example/foo#5\", \"title\": \"Update foo\", \"author\": \"someone-else\", \"status\": \"open\", $SRC, $TGT}]'"
case_ maintainer-empty-answer 2 "CHECK FAILED: could not tell whether you maintain devel:example/foo" \
  "$CONTRIB && : > \$B/meta-devel:example_foo"
case_ incoming-no-creator 2 "unparseable SR collection (incoming)" "$MAINT && inq \"\$SR_NOCREATOR\""
case_ check-failed-wins 2 "CHECK FAILED: could not tell whether you maintain devel:example/foo" \
  "inq \"\$SR_C, \$SR_OWN\" && echo @500 > \$B/meta-devel:example_foo"
XENV=(GEECTL_OBS_USERNAME=)
case_ incoming-owner-unknown 2 "CHECK FAILED: could not tell whose requests are open" "$MAINT && $CONTRIB"
XENV=()
case_ incoming-empty-answer 2 "unparseable SR collection (incoming)" ": > \$(spath \"\$Q_IN\")"
case_ incoming-second-action 5 "sr#2000013 by someone-else: not reviewed" \
  "$MAINT && inq \"\$SR_2ACT\""
K64="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
st_() { printf '{"v": 1, "kind": "%s", "id": "%s", "verdict": "BLOCK", "key": "%s"}' "$@"; }
case_ incoming-blocked-stamp 5 "sr#2000010 by someone-else: reviewed: BLOCK (key $K64)" \
  "$MAINT && $CONTRIB && stamp obs 2000010 '$(st_ obs 2000010 "$K64")'"
case_ incoming-bad-stamp 5 "sr#2000010 by someone-else: not reviewed" "$MAINT && $CONTRIB && stamp obs 2000010 '{\"v\": 1, \"verdict\": '"
# Only a stamp of this submission with a full key counts: one naming another
# request, or with the old 12-hex key, is not a review of it.
case_ incoming-stamp-other-sr 5 "sr#2000010 by someone-else: not reviewed" \
  "$MAINT && $CONTRIB && stamp obs 2000010 '$(st_ obs 2000099 "$K64")'"
case_ incoming-stamp-short-key 5 "sr#2000010 by someone-else: not reviewed" \
  "$MAINT && $CONTRIB && stamp obs 2000010 '$(st_ obs 2000010 0123456789ab)'"
# A PR's review counts at the head it was recorded at: one of another head is
# reviewed again, and a stamp that names no head is no review.
stg_() { printf '{"v": 1, "kind": "gitea", "id": "%s", "verdict": "BLOCK", "key": "%s", "gitea": {"head": "%s"}}' "$@"; }
case_ incoming-pr-reviewed 5 "example/foo#5 by someone-else: reviewed: BLOCK (key $K64)" \
  "$PR_C && stamp gitea example_foo_5 '$(stg_ example/foo#5 "$K64" "$HEAD1")'"
case_ incoming-pr-older-head 5 "example/foo#5 by someone-else: reviewed at an older head: review again" \
  "$PR_C && stamp gitea example_foo_5 '$(stg_ example/foo#5 "$K64" "$HEAD0")'"
! grep -qF "reviewed: BLOCK" <<<"$LAST" && pass "incoming-pr-older-head: not counted as reviewed" || fail "incoming-pr-older-head: $LAST"
# A SHA-256 repository's head is 64 hex.
HEAD64=2222222222222222222222222222222222222222222222222222222222222222
case_ incoming-pr-sha256 5 "example/foo#5 by someone-else: reviewed: BLOCK (key $K64)" \
  "${PR_C//$HEAD1/$HEAD64} && stamp gitea example_foo_5 '$(stg_ example/foo#5 "$K64" "$HEAD64")'"
case_ incoming-pr-stamp-no-head 5 "example/foo#5 by someone-else: not reviewed" \
  "$PR_C && stamp gitea example_foo_5 '$(st_ gitea example/foo#5 "$K64")'"
# A PR's stamp is <owner>_<repo>_<N>.json, owner and repo lowercased and each
# % and _ escaped (%25, %5F), as incoming-review.sh writes it.
B="$work/stamp-gitea" stamp gitea 'ex%5Fample_my%5Fpkg_5' "$(stg_ 'Ex_ample/My_Pkg#5' "$K64" "$HEAD1")"
INC="$HERE/../skills/opensuse-packaging/scripts/_incoming.py"
out="$(HOME="$work/stamp-gitea/home" python3 -I -B "$INC" stamp 'Ex_ample/My_Pkg#5' "$HEAD1" 2>&1)"
[ "$out" = "reviewed: BLOCK (key $K64)" ] && pass "stamp-gitea-name: lowercased and escaped" || fail "stamp-gitea-name: $out"
# A PR item needs the head it has now, and a request takes none.
HOME="$work/stamp-gitea/home" python3 -I -B "$INC" stamp 'Ex_ample/My_Pkg#5' > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "stamp-pr-no-head: exit 2" || fail "stamp-pr-no-head: exit $rc"
HOME="$work/stamp-gitea/home" python3 -I -B "$INC" stamp sr#2000010 "$HEAD1" > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "stamp-sr-head: exit 2" || fail "stamp-sr-head: exit $rc"

# _incoming.maintains() mirrors _pr_guard.maintains(): both judge each case
# from the same answers (the guard's offline stand-ins, a fake geectl run for ours).
out="$(python3 -I -B - "$HERE/../skills/opensuse-packaging/scripts" "$work/parity" 2>&1 <<'PY'
import json
import os
import re
import subprocess
import sys

scripts, root = sys.argv[1:3]
sys.path.insert(0, scripts)
import _incoming  # noqa: E402

os.environ["PR_GUARD_OBS_USER"] = "tester"
guard = {"__name__": "_pr_guard", "__file__": scripts + "/_pr_guard.py"}
exec(compile(open(guard["__file__"]).read(), guard["__file__"], "exec"), guard)
me, other = '<person userid="tester" role="maintainer"/>', '<person userid="other" role="maintainer"/>'
grp, scm = '<group groupid="t" role="maintainer"/>', "<scmsync>https://src.opensuse.org/o/P#main</scmsync>"
cases = [  # package _meta (None: absent), project _meta, _maintainership.json (None: absent)
    (me, "", None), (other, me, None), (grp, me, None), (grp + me, "", None), ("", me, None),
    ("", other, None), (None, me, None), ("", scm, {"foo": ["tester"]}), ("", scm, {"": ["tester"]}),
    ("", scm, {"foo": ["other"], "": ["tester"]}), ("", scm, {"foo": [], "": ["tester"]}),
    (me, scm, {"": ["other"]}), ("", scm, None),
]
def persons_xml(frag):
    """[{name, role}] from <person userid=.. role=..> and <group groupid=.. role=..> fragments."""
    out = {"persons": [], "groups": []}
    for tag, attr, kind in (("person", "userid", "persons"), ("group", "groupid", "groups")):
        for m in re.finditer(r'<%s %s="([^"]+)" role="([^"]+)"/>' % (tag, attr), frag):
            out[kind].append({"name": m.group(1), "role": m.group(2)})
    return out

bad = []
for n, (pkg, prj, git) in enumerate(cases):
    ans = {"/source/d:p/_meta": f'<project name="d:p">{prj}</project>'}
    if pkg is not None:
        ans["/source/d:p/foo/_meta"] = f'<package name="foo">{pkg}</package>'
    if git is not None:
        ans["/repos/o/P/raw/_maintainership.json?ref=main"] = json.dumps(git)
    d = f"{root}/{n}"  # PR_GUARD_META_DIR/api/<path, /?&= as _>, PR_GUARD_GITEA_DIR/<path, / as _>
    os.makedirs(f"{d}/api")
    os.environ.update(PR_GUARD_META_DIR=d, PR_GUARD_GITEA_DIR=d)
    for p, text in ans.items():
        name = f"api/{p.translate(str.maketrans('/?&=', '____'))}" if p[:2] == "/s" else p[1:].replace("/", "_")
        with open(f"{d}/{name}", "w") as fh:
            fh.write(text)

    pkg_meta = None if pkg is None else {"name": "foo", "project": "d:p", **persons_xml(pkg)}
    prj_meta = {"name": "d:p", **persons_xml(prj),
                "scmsync": "https://src.opensuse.org/o/P#main" if scm in prj else None}
    geo = {("remote", "package-meta", "d:p", "foo"): pkg_meta,
           ("remote", "project-meta", "d:p"): prj_meta}
    if git is not None:
        geo[("gitea", "raw-file", "o", "P", "_maintainership.json", "--ref", "main")] = json.dumps(git)

    def fake(cmd):
        if cmd[0] == "geectl":
            payload = geo.get(tuple(cmd[1:]))
            if payload is None:
                return subprocess.CompletedProcess(cmd, 3, "", '{"error":{"code":"not_found"}}')
            if cmd[1:3] == ["gitea", "raw-file"]:
                return subprocess.CompletedProcess(cmd, 0, payload, "")
            return subprocess.CompletedProcess(cmd, 0, json.dumps(payload), "")
        raise AssertionError(f"unexpected non-geectl call: {cmd}")

    want = guard["maintains"]("d:p", "foo", guard["Ctx"]("/"))[0]
    if _incoming.maintains("tester", "d:p", "foo", fake)[0] != want:
        bad.append(f"case {n}: the guard says {want}")
print(f"{len(cases)} cases" if not bad else "; ".join(bad))
sys.exit(1 if bad else 0)
PY
)"; rc=$?
[ "$rc" = 0 ] && pass "maintainer-rule-matches-guard ($out)" || fail "maintainer-rule-matches-guard: $out"

# The version slot takes a version: a project name there compared as one and
# printed PROCEED (seen twice with `preflight.sh <pkg> <project>`).
case_ version-is-project 2 "'devel:languages:python' is not a version" ":" devel:languages:python
case_ version-no-digit 2 "'hardware' is not a version" ":" hardware
case_ version-ok 4 "VERDICT: FORWARD" ":" 1.1
grep -qF "the forward needs a devel→Factory request, which geectl cannot file yet — report the update as ready to forward and stop" <<<"$LAST" \
  && ! grep -qF "geectl request file" <<<"$LAST" && ! grep -qF "geectl request refile" <<<"$LAST" \
  && pass "version-ok: FORWARD fails closed, no filing command" || fail "version-ok: $LAST"
# --from: the project about to be branched must be where the package is
# developed, or what the devel package links to (sr#1392134 branched
# hardware's stale copy of a devel:languages:python package).
case_ from-wrong 3 "VERDICT: STOP - wrong branch source: foo is developed in devel:example, not hardware" ":" --from hardware
grep -qF "geectl branch branch-package --project devel:example --package foo --live" <<<"$LAST" && pass "from-wrong: names the branch to make" || fail "from-wrong: $LAST"
case_ from-devel 4 "branch source:  devel:example (the devel project)" ":" --from devel:example
case_ from-link-target 4 "branch source:  hardware (devel:example/foo links to it)" \
  "put \$B/link-devel:example_foo '{\"project\": \"devel:example\", \"package\": \"foo\", \"target\": {\"project\": \"hardware\", \"package\": \"foo\"}}'" --from hardware
case_ from-link-elsewhere 3 "wrong branch source" \
  "put \$B/link-devel:example_foo '{\"project\": \"devel:example\", \"package\": \"foo\", \"target\": {\"project\": \"science\", \"package\": \"foo\"}}'" --from hardware
case_ from-link-unreadable 2 "CHECK FAILED: could not read devel:example/foo link target" \
  "echo @500 > \$B/link-devel:example_foo" --from hardware

# geectl remote devel-project failing is no "no devel project": when the
# Factory package meta names one, the lookup failed, and --from must not
# PROCEED against nothing.
case_ develproject-failed 2 "geectl remote devel-project failed, but openSUSE:Factory/foo meta names a devel project" \
  ": > \$B/no-develproject && put \$B/meta-openSUSE:Factory_foo '{\"name\": \"foo\", \"project\": \"openSUSE:Factory\", \"persons\": [], \"groups\": [], \"devel\": {\"project\": \"devel:example\", \"package\": \"foo\"}}'" \
  --from hardware
! grep -q "^VERDICT: PROCEED" <<<"$LAST" && pass "develproject-failed: no PROCEED" || fail "develproject-failed: $LAST"
case_ no-devel-set 0 "in openSUSE:Factory but no devel project set" \
  ": > \$B/no-develproject && put \$B/meta-openSUSE:Factory_foo '{\"name\": \"foo\", \"project\": \"openSUSE:Factory\", \"persons\": [], \"groups\": [], \"devel\": null}'" --from hardware

# A name Factory lacks may be one it has under another spelling: case
# (python-authlib was filed while Factory ships python-Authlib), -, _ and .,
# or a python3-/python3XX- flavour prefix, as python3dist() names it. Each is
# a STOP; a failed listing is CHECK-FAILED, never a new package.
NEW=": > \$B/no-develproject"
PKG=python-authlib case_ near-case 3 "VERDICT: STOP - not in openSUSE:Factory as python-authlib, but it has python-Authlib" "$NEW"
! grep -qF "python-Authlib:test" <<<"$LAST" && pass "near-case: a multibuild flavour is no package" || fail "near-case: $LAST"
PKG=python-zope_interface case_ near-separators 3 "but it has python-zope.interface" "$NEW"
PKG=python3-pytest-lazy-fixtures case_ near-flavour 3 "but it has python-pytest-lazy-fixtures" "$NEW"
PKG=python-brand-new case_ near-none 0 "VERDICT: PROCEED (new package" "$NEW"
PKG=python-brand-new case_ near-list-failed 2 "CHECK FAILED" "$NEW && rm \$B/ls-openSUSE:Factory"
! grep -q "^VERDICT: PROCEED" <<<"$LAST" && pass "near-list-failed: no PROCEED" || fail "near-list-failed: $LAST"
# A new package someone already submitted to the target is in flight, not one
# to package from scratch.
PKG=python-brand-new case_ new-package-in-flight 3 "VERDICT: STOP - already in flight: SR 2000020 [new] devel:other/python-brand-new -> openSUSE:Factory by someone-else" \
  "$NEW && outg_new \"\$SR_NEWPKG\""
# devel-of.sh: the same lookup, its own exit 6.
DEVEL_OF="$HERE/../skills/opensuse-packaging/scripts/devel-of.sh"
devel_of_() { # <name> <rc> <expected> <pkg> [mutation]
  local dir="$work/do-$1"
  # shellcheck disable=SC2031  # B is rebound only inside the mutation subshells
  cp -a "$B" "$dir"; : > "$dir/no-develproject"
  # shellcheck disable=SC2030  # rebound in a subshell on purpose, as case_ does
  [ -z "${5:-}" ] || (B=$dir; cd "$dir" && eval "$5")
  out="$(FIX=$dir PATH="$work/bin:$PATH" bash "$DEVEL_OF" "$4" 2>&1)"; got=$?
  [ "$got" = "$2" ] && grep -qF -- "$3" <<<"$out" && pass "devel-of $1 (rc=$2)" \
    || { fail "devel-of $1: expected rc=$2 and '$3', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
devel_of_ near 6 "NOT IN openSUSE:Factory as python-authlib, but it has python-Authlib" python-authlib
devel_of_ new 3 "NOT IN openSUSE:Factory (new package?)" python-brand-new
devel_of_ list-failed 5 "cannot list openSUSE:Factory" python-brand-new "rm \$B/ls-openSUSE:Factory"

echo "---"; [ "$fails" = 0 ] && echo "all preflight checks passed" || echo "$fails FAILED"
exit $((fails > 0))
