#!/bin/bash
# test-incoming-requests.sh — incoming-requests.py offline: fake `geectl` and
# `git-obs` on PATH answer from a per-case fixture tree (a missing fixture is a
# 404; one holding @HANG answers nothing for 20s), and HOME is empty unless a
# case plants something there. Each case mutates the base fixtures and expects
# an exit code plus a line. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
IR="$REPO/skills/opensuse-packaging/scripts/incoming-requests.py"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/geectl" <<'EOF'
#!/bin/bash
echo "geectl $*" >> "$FIX/calls"
case "$*" in
  "remote search-projects-by-person tester") f=projects-by-person ;;
  "remote search-packages-by-person tester") f=packages-by-person ;;
  "remote project-meta "*) f="meta-$(printf %s "$3" | tr '/' '_')_project" ;;
  "remote package-meta "*) f="meta-$(printf %s "$3" | tr '/' '_')_$(printf %s "$4" | tr '/' '_')" ;;
  "request search --state new --state review") f=requests ;;
  *) echo "fake geectl: unexpected $*" >&2; exit 99 ;;
esac
[ -f "$FIX/geectl/$f" ] || { printf '{"error":{"code":"not_found","context":"no such thing"}}\n' >&2; exit 3; }
[ "$(cat "$FIX/geectl/$f")" = @HANG ] && exec sleep 20
cat "$FIX/geectl/$f"
EOF
cat > "$work/bin/git-obs" <<'EOF'
#!/bin/bash
echo "git-obs $*" >> "$FIX/calls"
# Only the src.opensuse.org login may answer: the default one can be another forge.
[ "$1 $2 $3 $4" = "-G src.opensuse.org -q api" ] || { echo "fake git-obs: unexpected $*" >&2; exit 99; }
f="$FIX/gitea$(printf %s "$5" | tr '?&=' '___')"
[ -f "$f" ] || { echo "*** Error: 404 Not Found" >&2; exit 1; }
[ "$(cat "$f")" = @HANG ] && exec sleep 20
cat "$f"
EOF
chmod +x "$work/bin/"*

# ---------------------------------------------------------------- fixtures
B="$work/base"
put() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1"; }
REQ100='{"id": 100, "creator": "someone-else", "state": {"name": "new", "when": "2026-09-20T10:00:00"}, "description": "update foo", "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "devel:example", "target_package": "foo"}], "reviews": []}'
SR101='{"id": 101, "creator": "tester", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "description": "my update", "actions": [{"type": "submit", "source_project": "devel:other", "source_package": "foo", "target_project": "devel:example", "target_package": "foo"}], "reviews": []}'
REQ104='{"id": 104, "creator": "x", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "a", "source_package": "newpkg", "target_project": "devel:example", "target_package": "newpkg"}], "reviews": []}'
REQ105='{"id": 105, "creator": "x", "state": {"name": "review", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "submit", "source_project": "a", "source_package": "bar", "target_project": "devel:example", "target_package": "bar"}], "reviews": [{"state": "new", "by_user": "tester"}]}'
REQ106='{"id": 106, "creator": "x", "state": {"name": "new", "when": "2026-09-22T10:00:00"}, "actions": [{"type": "add_role", "target_project": "devel:example", "person": {"name": "x", "role": "maintainer"}}], "reviews": []}'
# putreqs <req-json>... — write the request-search fixture from request dicts.
putreqs() { local out='{"requests": [' sep=""; for r in "$@"; do out+="$sep$r"; sep=", "; done; put "$B/geectl/requests" "$out]}"; }
put "$B/geectl/projects-by-person" '{"login": "tester", "projects": [{"name": "devel:example"}]}'
put "$B/geectl/packages-by-person" '{"packages": []}'
# package-meta answers for a maintainer lookup, which the list must not make
put "$B/geectl/meta-devel:example_project" '{"name": "devel:example", "persons": [{"name": "tester", "role": "maintainer"}], "groups": [], "scmsync": null}'
put "$B/geectl/meta-devel:example_foo" '{"name": "foo", "project": "devel:example", "persons": []}'
putreqs "$REQ100"
PRS="gitea/repos/issues/search_type_pulls_review_requested_true_state_open_limit_50"
put "$B/$PRS" \
  '[{"number": 7, "title": "Update bar", "created_at": "2026-09-21T10:00:00Z", "repository": {"full_name": "pool/bar"}, "user": {"login": "someone-else"}}]'
put "$B/gitea/repos/pool/bar/pulls/7" '{"number": 7, "requested_reviewers": [{"login": "tester"}], "requested_reviewers_teams": [], "user": {"login": "someone-else"}}'

# case_ <name> <expected rc> <expected message> <mutation> [incoming-requests args...]
# XENV holds extra environment for the run; SHORT=("$work/short.py") runs the
# script with a 3s call timeout.
XENV=(); SHORT=()
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got; shift 4
  cp -a "$B" "$dir" && mkdir -p "$dir/home"
  (B=$dir; cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  out="$(cd "$dir" && FIX=$dir HOME=$dir/home GEECTL_OBS_USERNAME=tester PATH="$work/bin:$PATH" \
    env ${XENV[@]+"${XENV[@]}"} python3 ${SHORT[@]+"${SHORT[@]}"} "$IR" "$@" 2>&1)"; got=$?
  LAST=$out
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"
    printf '%s\n' "$out" | sed 's/^/    /'
  }
}

case_ both-buckets 0 "pool/bar#7	PR	pool/bar	open" ":" --format plain
grep -qF "100	submit	devel:example/foo	new" <<<"$LAST" && pass "both-buckets: the SR row" || fail "both-buckets: SR row: $LAST"

# src.opensuse.org is read through git-obs only, which keeps its own login: a
# tea token on disk is never loaded. yaml.py stands in for pyyaml (JSON is
# YAML) and leaves a mark when anything parses the tea config; the proxy
# refuses on the loopback, so a direct fetch would show as a warning too.
mkdir -p "$work/pylib"
printf 'import json\nimport os\n\n\ndef safe_load(f):\n    open(os.environ["FIX"] + "/tea-read", "w").close()\n    return json.load(f)\n' > "$work/pylib/yaml.py"
XENV=(PYTHONPATH="$work/pylib" https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 no_proxy= NO_PROXY=)
case_ tea-token-ignored 0 "pool/bar#7	PR	pool/bar	open" \
  "put home/.config/tea/config.yml '{\"logins\": [{\"name\": \"src.opensuse.org\", \"token\": \"t\", \"user\": \"tester\"}]}'" \
  --format plain
XENV=()
[ ! -e "$work/tea-token-ignored/tea-read" ] && ! grep -qF "direct src.opensuse.org fetch" <<<"$LAST" \
  && pass "tea-token-ignored: the tea config is never read" || fail "tea-token-ignored: the tea config was read: $LAST"

# geectl and git-obs have hung for good in the field. A call that does not answer
# times out and is reported like any other failure, never as an empty result.
cat > "$work/short.py" <<'EOF'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.TIMEOUT = 3
sys.argv = sys.argv[1:]
sys.exit(mod.main())
EOF
SHORT=("$work/short.py")
case_ hang-request-search 2 "geectl timed out after 3s" "put \$B/geectl/requests @HANG"
case_ hang-project-search 2 "geectl timed out after 3s" "put \$B/geectl/projects-by-person @HANG"
case_ hang-package-search 2 "geectl timed out after 3s" "put \$B/geectl/packages-by-person @HANG"
case_ hang-pr-search 0 "100	submit	devel:example/foo	new" \
  "put \$B/gitea/repos/issues/search_type_pulls_review_requested_true_state_open_limit_50 @HANG" --format plain
grep -qF "git-obs timed out after 3s" <<<"$LAST" && grep -qF "PR leg skipped" <<<"$LAST" \
  && pass "hang-pr-search: the skipped PR leg is reported" || fail "hang-pr-search: $LAST"
grep -qxF "src.opensuse.org PRs: UNKNOWN (see stderr)" <<<"$LAST" \
  && pass "hang-pr-search: stdout says the PRs are unknown" || fail "hang-pr-search: no UNKNOWN line: $LAST"
# With no OBS request either, "nothing needs you" would be a guess.
case_ hang-pr-search-no-srs 0 "src.opensuse.org PRs UNKNOWN" \
  "put \$B/geectl/requests '{\"requests\": []}' &&
   put \$B/gitea/repos/issues/search_type_pulls_review_requested_true_state_open_limit_50 @HANG"
! grep -qF "no requests or PRs need" <<<"$LAST" && pass "hang-pr-search-no-srs: no all-clear" \
  || fail "hang-pr-search-no-srs: claims nothing is pending: $LAST"
python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m); sys.exit(0 if m.TIMEOUT < 120 else 1)' "$IR" \
  && pass "TIMEOUT is under the 2-minute tool limit" || fail "TIMEOUT is not under 120s"
SHORT=()
# No user set is a failed query (exit 2), not a traceback.
XENV=(GEECTL_OBS_USERNAME=)
case_ no-user 2 "no user" ":"
XENV=()
# A missing geectl is a failed query (exit 2), not a traceback.
mkdir -p "$work/py-only" && ln -sf "$(command -v python3)" "$work/py-only/python3"
out="$(GEECTL_OBS_USERNAME=tester PATH="$work/py-only" HOME="$work" python3 "$IR" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qF "geectl: command not found" <<<"$out" && ! grep -q Traceback <<<"$out" \
  && pass "missing geectl: a failed query (rc=2)" || { fail "missing geectl: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
case_ nothing-pending 0 "no requests or PRs need 'tester' personally right now" \
  "put \$B/geectl/requests '{\"requests\": []}' &&
   put \$B/gitea/repos/issues/search_type_pulls_review_requested_true_state_open_limit_50 '[]'"

# Your own SR or PR is not incoming, whoever is asked to review it.
case_ drops-own-sr 0 "100	submit	devel:example/foo	new" \
  "putreqs \"\$REQ100\" \"\$SR101\"" --format plain
! grep -q "^101	" <<<"$LAST" && pass "drops-own-sr: your own SR is not listed" || fail "drops-own-sr: $LAST"
case_ drops-own-pr 0 "pool/bar#7	PR" \
  "put \$B/$PRS '[{\"number\": 7, \"title\": \"Update bar\", \"created_at\": \"2026-09-21T10:00:00Z\", \"repository\": {\"full_name\": \"pool/bar\"}, \"user\": {\"login\": \"someone-else\"}},
    {\"number\": 8, \"title\": \"Update baz\", \"created_at\": \"2026-09-21T11:00:00Z\", \"repository\": {\"full_name\": \"pool/baz\"}, \"user\": {\"login\": \"tester\"}}]' &&
   put \$B/gitea/repos/pool/baz/pulls/8 '{\"number\": 8, \"requested_reviewers\": [{\"login\": \"tester\"}], \"user\": {\"login\": \"tester\"}}'" --format plain
! grep -qF "pool/baz#8" <<<"$LAST" && pass "drops-own-pr: your own PR is not listed" || fail "drops-own-pr: $LAST"
# A description or title is third-party text: an escape sequence (ESC or C1)
# and a bidi override are stripped, the words kept.
case_ sanitizes-desc 0 "update foo evil" \
  "printf '{\"requests\": [{\"id\": 100, \"creator\": \"someone-else\", \"state\": {\"name\": \"new\", \"when\": \"2026-09-20T10:00:00\"}, \"description\": \"update \\xc2\\x9b31mfoo \\xe2\\x80\\xaeevil\", \"actions\": [{\"type\": \"submit\", \"source_project\": \"devel:other\", \"source_package\": \"foo\", \"target_project\": \"devel:example\", \"target_package\": \"foo\"}], \"reviews\": []}]}' > \$B/geectl/requests &&
   put \$B/$PRS '[{\"number\": 7, \"title\": \"Update \\u001b[31mbar\\u202e\", \"created_at\": \"2026-09-21T10:00:00Z\", \"repository\": {\"full_name\": \"pool/bar\"}, \"user\": {\"login\": \"someone-else\"}}]'" \
  --format plain
python3 -I -c 'import sys; t = sys.stdin.read(); sys.exit(any(c in t for c in "\x1b\x9b" + chr(0x202E)) or "Update bar" not in t)' <<<"$LAST" \
  && pass "sanitizes-desc: no escape or bidi character survives" || fail "sanitizes-desc: $(printf '%s' "$LAST" | od -c | head -20)"

# The list is who should look at a request, not who may accept it (pr-guard's
# stricter check): a new package in your project, a review assigned to you on
# another maintainer's package there, and a project-level request are listed,
# and no package meta is read for it.
case_ lists-new-package 0 "104	submit	devel:example/newpkg	new" \
  "putreqs \"\$REQ100\" \"\$REQ104\"" \
  --format plain
case_ lists-assigned-review 0 "105	submit	devel:example/bar	review" \
  "put \$B/geectl/meta-devel:example_bar '{\"name\": \"bar\", \"project\": \"devel:example\", \"persons\": [{\"name\": \"someone\", \"role\": \"maintainer\"}]}' &&
   putreqs \"\$REQ100\" \"\$REQ105\"" \
  --format plain
! grep -q "remote package-meta" "$work/lists-assigned-review/calls" && pass "lists-assigned-review: no package meta read" \
  || fail "lists-assigned-review: a package meta was read"
case_ lists-project-request 0 "106	add_role	devel:example	new" \
  "putreqs \"\$REQ100\" \"\$REQ106\"" \
  --format plain

echo "---"; [ "$fails" = 0 ] && echo "all incoming-requests checks passed" || echo "$fails FAILED"
exit $((fails > 0))
