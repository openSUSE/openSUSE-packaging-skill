#!/bin/bash
# test-sr-status.sh — proves sr-status.py reads a pool PR's build from OBS, not
# from the staging bot's last comment. Offline: fake `osc` and `git-obs` on PATH
# serve fixtures from a per-case tree, and an empty HOME has no tea token (one
# case adds one), so every src.opensuse.org read goes through git-obs. The fixtures replay
# pool/tesseract-ocr #3 (built d09d8d0, head 760972c, pinned by a hand-made
# products PR) and #4 (built at the head by the bot's branch). Every case
# mutates one thing and expects the exit code plus the line that names it.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
SR="$REPO/skills/opensuse-packaging/scripts/sr-status.py"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# A missing fixture is a 404; one holding @NET is a refused connection, and
# one holding "@ERR <text>" fails with that text.
mkdir -p "$work/bin"
cat > "$work/bin/serve" <<'EOF'
#!/bin/bash
[ -f "$1" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
[ "$(cat "$1")" = @NET ] && { echo "Failed to establish a new connection: [Errno 111] Connection refused" >&2; exit 1; }
[ "$(head -c5 "$1")" = "@ERR " ] && { cut -c6- "$1" >&2; exit 1; }
cat "$1"
EOF
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
echo "osc $*" >> "$FIX/calls"
case $1 in
  whois) echo 'tester: "Tester"' ;;
  api) exec serve "$FIX/obs/$(printf %s "$2" | tr '?&=' '___')" ;;
  results) [ "$2" = --xml ] && exec serve "$FIX/obs/results/$3/$4" ;;
  *) echo "fake osc: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat > "$work/bin/git-obs" <<'EOF'
#!/bin/bash
echo "git-obs $*" >> "$FIX/calls"
[ "$1 $2" = "-q api" ] || { echo "fake git-obs: unexpected $*" >&2; exit 99; }
exec serve "$FIX/gitea$(printf %s "$3" | tr '?&=' '___')"
EOF
chmod +x "$work/bin/"*

# ---------------------------------------------------------------- fixtures
B="$work/base"
H3=760972c02a1f103ff23d88a59e83f6b7eb63deb453c6ed1ac119a4e5f7202b10
B3=d09d8d0dc74bddd486a815af0e2d6362cade8312093acb9c6e6f094e39b92a82
H4=ee3e97a3248f29f1e15cfbc120742a4fc259637f0e4f1ad695b230b219d5c40c
P3=openSUSE:Backports:SLE-16.0:PullRequest:3356
P4=openSUSE:Backports:SLE-16.1:PullRequest:3353
G=$B/gitea/repos
put() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1"; }
pr() { # <num> <head sha> <base> [merged] [state]
  put "$G/pool/tesseract-ocr/pulls/$1" "{\"number\": $1, \"state\": \"${5:-open}\",
    \"merged\": ${4:-false}, \"created_at\": \"2026-09-23T15:50:00+02:00\",
    \"head\": {\"ref\": \"tess-$3\", \"sha\": \"$2\",
               \"repo\": {\"full_name\": \"a-packager/tesseract-ocr\"}},
    \"base\": {\"ref\": \"$3\"}}"
}
results() { # <project> <x86_64 code> [aarch64 code] [dirty attribute]
  put "$B/obs/results/$1/tesseract-ocr" "<resultlist state=\"0\">
  <result project=\"$1\" repository=\"standard\" arch=\"local\" code=\"blocked\" state=\"blocked\">
    <status package=\"tesseract-ocr\" code=\"excluded\"/></result>
  <result project=\"$1\" repository=\"standard\" arch=\"i586\" code=\"published\" state=\"published\">
    <status package=\"tesseract-ocr\" code=\"excluded\"><details>package whitelist</details></status></result>
  <result project=\"$1\" repository=\"standard\" arch=\"x86_64\" code=\"published\" state=\"published\"${4:-}>
    <status package=\"tesseract-ocr\" code=\"$2\"/></result>
  <result project=\"$1\" repository=\"standard\" arch=\"aarch64\" code=\"published\" state=\"published\">
    <status package=\"tesseract-ocr\" code=\"${3:-$2}\"/></result>
</resultlist>"
}
obsinfo() { # <project> <commit>
  put "$B/obs/source/$1/tesseract-ocr/_scmsync.obsinfo" "mtime: 1790171239
commit: $2
url: https://src.opensuse.org/pool/tesseract-ocr
revision: $2
trackingbranch: leap-16.x"
}
# shellcheck disable=SC2317  # called from case mutations, through eval
extra() { # <project> <package> <code>: one more status in the x86_64 result
  sed -i "s|\(arch=\"x86_64\"[^>]*>\)|\1<status package=\"$2\" code=\"$3\"/>|" "$B/obs/results/$1/tesseract-ocr"
}
srcmd5() { # <project> <srcmd5>: the expanded source listing
  put "$B/obs/source/$1/tesseract-ocr_expand_1" "<directory name=\"tesseract-ocr\" rev=\"7\" vrev=\"7\" srcmd5=\"$2\"/>"
}
buildhist() { # <project> <arch>/<package> <srcmd5>: the last successful build there
  put "$B/obs/build/$1/standard/$2/_history_limit_1" "<buildhistory>
  <entry rev=\"7\" srcmd5=\"$3\" versrel=\"5.5.3-160000.1\" bcnt=\"1\" time=\"1790171300\" duration=\"812\"/>
</buildhistory>"
}
built() { # <project> <srcmd5>: sources, and both building arches' last build, at srcmd5
  srcmd5 "$1" "$2" && buildhist "$1" x86_64/tesseract-ocr "$2" && buildhist "$1" aarch64/tesseract-ocr "$2"
}
pin() { # <project> <products PR> <head repo> <head ref>
  put "$B/obs/source/$1/_meta" "<project name=\"$1\">
  <url>https://src.opensuse.org/products/PackageHub/pulls/$2</url>
</project>"
  put "$G/products/PackageHub/pulls/$2" "{\"number\": $2, \"state\": \"open\",
    \"head\": {\"ref\": \"$4\", \"sha\": \"4b829d7e9b56\", \"repo\": {\"full_name\": \"$3\"}}}"
}
BR='![Build results](https://br.opensuse.org/status'
S3=5d1c3c52e3d0e8a09c1f0f6c0b8a7e21
S4=9b6e2f4a0d73c1e85f2a6b3d4c7e8f10
OLD=31f0e7a9c2b4d6e8f0a1b3c5d7e9f1a2

pr 3 $H3 leap-16.0
put "$G/pool/tesseract-ocr/issues/3/comments" "[
 {\"user\": {\"login\": \"autogits_obs_staging_bot\"}, \"body\": \"$BR/$P3/tesseract-ocr)\"},
 {\"user\": {\"login\": \"a-reviewer\"}, \"body\": \"package fails to build\"}]"
obsinfo $P3 $B3
results $P3 failed
built $P3 $S3
pin $P3 3356 someone/PackageHub maintenance-update-1790172046

pr 4 $H4 leap-16.1
put "$G/pool/tesseract-ocr/issues/4/comments" "[
 {\"user\": {\"login\": \"autogits_obs_staging_bot\"}, \"body\": \"$BR/$P4/tesseract-ocr)\"},
 {\"user\": {\"login\": \"autogits_obs_staging_bot\"}, \"body\": \"Build successful, for more information go in https://build.opensuse.org/project/show/$P4.\"}]"
obsinfo $P4 $H4
results $P4 succeeded
built $P4 $S4
pin $P4 3353 products/PackageHub 'PR_tesseract-ocr#4'

# The table leg: the two pool PRs plus a non-pool one whose badge still comes
# from the bot comment. No SRs.
S=$B/gitea/repos/issues
put "$S/search_type_pulls_created_true_state_open_limit_50" '[
 {"number": 4, "state": "open", "repository": {"full_name": "pool/tesseract-ocr"}, "pull_request": {}},
 {"number": 2, "state": "open", "repository": {"full_name": "somegroup/example"}, "pull_request": {}},
 {"number": 3, "state": "open", "repository": {"full_name": "pool/tesseract-ocr"}, "pull_request": {}}]'
put "$S/search_type_pulls_review_requested_true_state_open_limit_50" '[]'
put "$G/somegroup/example/pulls/2" '{"number": 2, "state": "open", "mergeable": true, "base": {"ref": "main"}}'
put "$G/somegroup/example/issues/2/comments" '[{"user": {"login": "autogits_obs_staging_bot"}, "body": "Build successful"}]'
put "$B/obs/request_view_collection_states_new,review,declined_roles_creator_user_tester_types_submit" '<collection matches="0"/>'

# case_ <name> <expected rc> <expected message> <mutation> [sr-status args...]
# Mutations run in the case's fixture tree ($B there), with $G/$P3/... to hand.
# XENV holds extra environment for the run.
XENV=()
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got; shift 4
  cp -a "$B" "$dir" && mkdir -p "$dir/home"
  (B=$dir G=$dir/gitea/repos; cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  out="$(cd "$dir" && FIX=$dir HOME=$dir/home PATH="$work/bin:$PATH" \
    env ${XENV[@]+"${XENV[@]}"} python3 "$SR" "$@" 2>&1)"; got=$?
  LAST=$out; CALLS=$(cat "$dir/calls" 2>/dev/null)
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"
    printf '%s\n' "$out" | sed 's/^/    /'
  }
}
no_osc_calls() { ! grep -q '^osc ' <<<"$CALLS" && pass "$1: no OBS call" || fail "$1: queried OBS: $CALLS"; }

# ---------------------------------------------------------------- --pr
case_ tesseract-4-green-at-head 0 "VERDICT: GREEN at the PR head" ":" --pr 'pool/tesseract-ocr#4'
case_ tesseract-3-stale 4 "pinned by products/PackageHub#3356, hand-made branch someone/PackageHub:maintenance-update-1790172046" \
  ":" --pr 'pool/tesseract-ocr#3'
grep -qF "VERDICT: STALE — the PR build is not of the PR head; a hand-made branch does not follow pushes" <<<"$LAST" \
  && grep -qF "built d09d8d0dc74b · PR head 760972c02a1f" <<<"$LAST" \
  && pass "tesseract-3-stale: names both commits" || fail "tesseract-3-stale: verdict lines: $LAST"
case_ stale-bot-branch 4 "pinned by products/PackageHub#3353, bot branch PR_tesseract-ocr#4" \
  "obsinfo $P4 $B3" --pr 'pool/tesseract-ocr#4'
case_ stale-bot-branch-needs-both 4 "hand-made branch someone/PackageHub:PR_tesseract-ocr#4" \
  "obsinfo $P4 $B3 && pin $P4 3353 someone/PackageHub 'PR_tesseract-ocr#4'" --pr 'pool/tesseract-ocr#4'
case_ stale-bot-branch-needs-this-pr 4 "hand-made branch products/PackageHub:PR_tesseract-ocr#3" \
  "obsinfo $P4 $B3 && pin $P4 3353 products/PackageHub 'PR_tesseract-ocr#3'" --pr 'pool/tesseract-ocr#4'
# A failed pin lookup must not turn a stale build into anything milder.
case_ stale-pin-unreadable 4 "products/PackageHub#3356, branch unknown (lookup failed)" \
  "rm \$G/products/PackageHub/pulls/3356" --pr 'pool/tesseract-ocr#3'
case_ stale-pin-meta-missing 4 "pinned by an unknown products PR (lookup failed)" \
  "rm \$B/obs/source/$P3/_meta" --pr 'pool/tesseract-ocr#3'
case_ stale-pin-meta-unparsable 4 "pinned by an unknown products PR (lookup failed)" \
  "put \$B/obs/source/$P3/_meta '<project'" --pr 'pool/tesseract-ocr#3'
case_ building 3 "VERDICT: PENDING — still building at the PR head" \
  "results $P4 building succeeded" --pr 'pool/tesseract-ocr#4'
case_ dirty-repository 3 "standard/x86_64 succeeded (dirty)" \
  "results $P4 succeeded succeeded ' dirty=\"true\"'" --pr 'pool/tesseract-ocr#4'
# An excluded arch in a dirty repository may be about to build the new sources.
case_ dirty-excluded-arch 3 "standard/i586 excluded (dirty)" \
  "sed -i 's|arch=\"i586\" code=\"published\" state=\"published\"|& dirty=\"true\"|' \$B/obs/results/$P4/tesseract-ocr" \
  --pr 'pool/tesseract-ocr#4'
# The scheduler race: obsinfo is at the head and the results say succeeded, not
# dirty, but x86_64's last build is of the previous sources.
case_ succeeded-from-older-sources 3 "VERDICT: PENDING — not yet rebuilt from the current sources" \
  "buildhist $P4 x86_64/tesseract-ocr $OLD" --pr 'pool/tesseract-ocr#4'
grep -qF "built from older sources: standard/x86_64 succeeded (built ${OLD:0:12}, sources ${S4:0:12})" <<<"$LAST" \
  && ! grep -qF "standard/aarch64 succeeded (built" <<<"$LAST" \
  && pass "succeeded-from-older-sources: names only the older arch" || fail "succeeded-from-older-sources: $LAST"
case_ no-build-recorded 3 "standard/aarch64 succeeded (built nothing recorded, sources ${S4:0:12})" \
  "put \$B/obs/build/$P4/standard/aarch64/tesseract-ocr/_history_limit_1 '<buildhistory/>'" --pr 'pool/tesseract-ocr#4'
# A flavor is judged by its own history, not the main package's.
case_ flavor-at-current-sources 0 "VERDICT: GREEN at the PR head" \
  "extra $P4 tesseract-ocr:docs succeeded && buildhist $P4 x86_64/tesseract-ocr:docs $S4" --pr 'pool/tesseract-ocr#4'
case_ flavor-from-older-sources 3 "standard/x86_64:docs succeeded (built ${OLD:0:12}, sources ${S4:0:12})" \
  "extra $P4 tesseract-ocr:docs succeeded && buildhist $P4 x86_64/tesseract-ocr:docs $OLD" --pr 'pool/tesseract-ocr#4'
case_ history-missing 2 "could not read the $P4/standard/x86_64/tesseract-ocr build history (lookup failed)" \
  "rm \$B/obs/build/$P4/standard/x86_64/tesseract-ocr/_history_limit_1" --pr 'pool/tesseract-ocr#4'
case_ history-unparsable 2 "could not read the $P4/standard/x86_64/tesseract-ocr build history (lookup failed)" \
  "put \$B/obs/build/$P4/standard/x86_64/tesseract-ocr/_history_limit_1 '<buildhistory'" --pr 'pool/tesseract-ocr#4'
case_ history-network 6 "could not read the $P4/standard/x86_64/tesseract-ocr build history (network failure)" \
  "put \$B/obs/build/$P4/standard/x86_64/tesseract-ocr/_history_limit_1 @NET" --pr 'pool/tesseract-ocr#4'
case_ srcmd5-missing 2 "could not read the $P4/tesseract-ocr srcmd5 (lookup failed)" \
  "rm \$B/obs/source/$P4/tesseract-ocr_expand_1" --pr 'pool/tesseract-ocr#4'
case_ srcmd5-unparsable 2 "could not read the $P4/tesseract-ocr srcmd5 (lookup failed)" \
  "put \$B/obs/source/$P4/tesseract-ocr_expand_1 '<directory'" --pr 'pool/tesseract-ocr#4'
case_ srcmd5-absent 2 "could not read the $P4/tesseract-ocr srcmd5 (lookup failed)" \
  "put \$B/obs/source/$P4/tesseract-ocr_expand_1 '<directory name=\"tesseract-ocr\"/>'" --pr 'pool/tesseract-ocr#4'
case_ no-results-yet 3 "VERDICT: PENDING — no build results yet" \
  "put \$B/obs/results/$P4/tesseract-ocr '<resultlist state=\"0\"/>'" --pr 'pool/tesseract-ocr#4'
case_ no-bot-comment 3 "VERDICT: PENDING — no staging-bot build comment (PR opened 2026-09-23)" \
  "put \$G/pool/tesseract-ocr/issues/4/comments '[]'" --pr 'pool/tesseract-ocr#4'
no_osc_calls no-bot-comment
# Only the bot's own comment counts: a pasted green project is not evidence.
case_ human-pasted-project 3 "no staging-bot build comment" \
  "put \$G/pool/tesseract-ocr/issues/4/comments '[{\"user\": {\"login\": \"a-packager\"}, \"body\": \"$BR/$P4/tesseract-ocr)\"}]'" \
  --pr 'pool/tesseract-ocr#4'
# A re-created products PR means a new project: the bot's latest link wins.
case_ latest-bot-project-wins 0 "VERDICT: GREEN at the PR head" \
  "put \$G/pool/tesseract-ocr/issues/4/comments '[
   {\"user\": {\"login\": \"autogits_obs_staging_bot\"}, \"body\": \"$BR/${P4}0/tesseract-ocr)\"},
   {\"user\": {\"login\": \"autogits_obs_staging_bot\"}, \"body\": \"$BR/$P4/tesseract-ocr)\"}]'" \
  --pr 'pool/tesseract-ocr#4'
case_ bot-link-to-project-page 0 "VERDICT: GREEN at the PR head" \
  "put \$G/pool/tesseract-ocr/issues/4/comments '[
   {\"user\": {\"login\": \"autogits_obs_staging_bot\"}, \"body\": \"Build successful, for more information go in https://build.opensuse.org/project/show/$P4.\"}]'" \
  --pr 'pool/tesseract-ocr#4'
case_ linkless-bot-comment-keeps-project 0 "VERDICT: GREEN at the PR head" \
  "put \$G/pool/tesseract-ocr/issues/4/comments '[
   {\"user\": {\"login\": \"autogits_obs_staging_bot\"}, \"body\": \"$BR/$P4/tesseract-ocr)\"},
   {\"user\": {\"login\": \"autogits_obs_staging_bot\"}, \"body\": \"Build is started\"}]'" \
  --pr 'pool/tesseract-ocr#4'
case_ failed-at-head 1 "VERDICT: RED at the PR head" \
  "results $P4 succeeded failed" --pr 'pool/tesseract-ocr#4'
# The bot's last word is "Build successful"; OBS says otherwise.
grep -qF "standard/aarch64 failed" <<<"$LAST" && pass "failed-at-head: names the arch" || fail "failed-at-head: $LAST"
case_ red-beats-building 1 "VERDICT: RED at the PR head" \
  "results $P4 building failed" --pr 'pool/tesseract-ocr#4'
case_ unresolvable-at-head 1 "VERDICT: RED at the PR head" \
  "results $P4 unresolvable" --pr 'pool/tesseract-ocr#4'
case_ broken-at-head 1 "VERDICT: RED at the PR head" \
  "results $P4 broken" --pr 'pool/tesseract-ocr#4'
# A _multibuild flavor is the package too; another package in the result is not.
case_ flavor-failed-at-head 1 "standard/x86_64:docs failed" \
  "extra $P4 tesseract-ocr:docs failed" --pr 'pool/tesseract-ocr#4'
case_ other-package-ignored 0 "VERDICT: GREEN at the PR head" \
  "extra $P4 tesseract-ocr-traineddata failed" --pr 'pool/tesseract-ocr#4'
case_ nothing-built 1 "RED — nothing built" \
  "results $P4 excluded disabled" --pr 'pool/tesseract-ocr#4'
case_ merged 0 "VERDICT: MERGED" "pr 4 $H4 leap-16.1 true closed" --pr 'pool/tesseract-ocr#4'
no_osc_calls merged
case_ closed-unmerged 1 "VERDICT: CLOSED without a merge" "pr 4 $H4 leap-16.1 false closed" --pr 'pool/tesseract-ocr#4'
case_ obsinfo-missing 2 "VERDICT: UNKNOWN — could not read $P4/tesseract-ocr/_scmsync.obsinfo (lookup failed)" \
  "rm \$B/obs/source/$P4/tesseract-ocr/_scmsync.obsinfo" --pr 'pool/tesseract-ocr#4'
case_ obsinfo-no-commit 2 "VERDICT: UNKNOWN — no commit: in _scmsync.obsinfo" \
  "put \$B/obs/source/$P4/tesseract-ocr/_scmsync.obsinfo 'mtime: 1'" --pr 'pool/tesseract-ocr#4'
case_ pr-head-missing 2 "VERDICT: UNKNOWN — no the PR head" \
  "put \$G/pool/tesseract-ocr/pulls/4 '{\"number\": 4, \"state\": \"open\", \"base\": {\"ref\": \"leap-16.1\"}}'" \
  --pr 'pool/tesseract-ocr#4'
case_ obsinfo-network 6 "(network failure)" \
  "put \$B/obs/source/$P4/tesseract-ocr/_scmsync.obsinfo @NET" --pr 'pool/tesseract-ocr#4'
# Each transient failure the classifier knows asks for a retry (6), never
# "lookup failed" (2); the 404 cases are the controls. One pattern per line.
while IFS='|' read -r kind msg <&3; do
  case_ "network-$kind" 6 "(network failure)" \
    "put \$B/obs/source/$P4/tesseract-ocr/_scmsync.obsinfo '@ERR $msg'" --pr 'pool/tesseract-ocr#4'
done 3<<'EOF'
timeout|Read timed out. (read timeout=60)
refused|[Errno 111] Connection refused
reset|[Errno 104] Connection reset by peer
aborted|Connection aborted. BrokenPipeError(32, Broken pipe)
establish|Failed to establish a new connection: [Errno 99] Cannot assign requested address
dns|[Errno -2] Name or service not known
dns-temporary|[Errno -3] Temporary failure in name resolution
unreachable|[Errno 101] Network is unreachable
no-route|[Errno 113] No route to host
remote-closed|Remote end closed connection without response
urlopen|<urlopen error EOF occurred in violation of protocol>
http-5xx|Server returned an error: HTTP Error 502: Bad Gateway
http-429|Server returned an error: HTTP Error 429: Too Many Requests
EOF
case_ network-git-obs-5xx 6 "could not read pool/tesseract-ocr#4 (network failure)" \
  "put \$G/pool/tesseract-ocr/pulls/4 '@ERR *** Error: 503 Service Unavailable'" --pr 'pool/tesseract-ocr#4'
# With a tea token the direct fetch runs first; its failure counts too, so an
# unreachable forge is not "lookup failed" when git-obs has no login. yaml.py
# stands in for pyyaml (JSON is YAML); the proxy refuses on the loopback.
mkdir -p "$work/pylib"
printf 'import json\n\n\ndef safe_load(f):\n    return json.load(f)\n' > "$work/pylib/yaml.py"
XENV=(PYTHONPATH="$work/pylib" https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 no_proxy= NO_PROXY=)
case_ direct-fetch-network 6 "could not read pool/tesseract-ocr#4 (network failure)" \
  "put home/.config/tea/config.yml '{\"logins\": [{\"name\": \"src.opensuse.org\", \"token\": \"t\"}]}' &&
   put \$G/pool/tesseract-ocr/pulls/4 '@ERR *** Error: no default login configured'" --pr 'pool/tesseract-ocr#4'
XENV=()
case_ results-missing 2 "could not read the $P4 results (lookup failed)" \
  "rm \$B/obs/results/$P4/tesseract-ocr" --pr 'pool/tesseract-ocr#4'
case_ results-unparsable 2 "could not read the $P4 results (lookup failed)" \
  "put \$B/obs/results/$P4/tesseract-ocr '<resultlist'" --pr 'pool/tesseract-ocr#4'
case_ pr-missing 2 "VERDICT: UNKNOWN — could not read pool/tesseract-ocr#9 (lookup failed)" \
  ":" --pr 'pool/tesseract-ocr#9'
case_ pr-network 6 "VERDICT: UNKNOWN — could not read pool/tesseract-ocr#4 (network failure)" \
  "put \$G/pool/tesseract-ocr/pulls/4 @NET" --pr 'pool/tesseract-ocr#4'
case_ comments-missing 2 "VERDICT: UNKNOWN — could not read the PR comments (lookup failed)" \
  "rm \$G/pool/tesseract-ocr/issues/4/comments" --pr 'pool/tesseract-ocr#4'
case_ bad-pr-spec 2 "--pr takes OWNER/REPO#N and no request ids" ":" --pr 'pool/tesseract-ocr'
case_ pr-with-ids 2 "--pr takes OWNER/REPO#N and no request ids" ":" --pr 'pool/tesseract-ocr#4' 1234

# ---------------------------------------------------------------- the table
case_ table-stale-sorts-first 0 "| PR | #3 | tesseract-ocr | pool/tesseract-ocr:leap-16.0 |" ":"
rows=$(grep '^| PR ' <<<"$LAST")
[ "$(head -1 <<<"$rows" | cut -d'|' -f3)" = " #3 " ] && grep -qF "PR build STALE (d09d8d0 ≠ head 760972c, products/PackageHub#3356 hand-made)" <<<"$rows" \
  && pass "table: the stale row sorts first and names its pin" || fail "table: stale row: $rows"
grep '| #4 |' <<<"$rows" | grep -qF "PR build ✅ at head" && pass "table: #4 green at head" || fail "table: #4 row: $rows"
# Outside pool/ the badge still comes from the bot comment.
grep '| #2 |' <<<"$rows" | grep -qF "mergeable · bot-build ✅" \
  && pass "table: non-pool PR unchanged" || fail "table: #2 row: $rows"
grep '| #3 |' <<<"$rows" | grep -qF '💬 a-reviewer: "package fails to build"' \
  && pass "table: latest human comment kept" || fail "table: #3 comment: $rows"
case_ table-green-sorts-by-number 0 "PR build ✅ at head" "obsinfo $P3 $H3 && results $P3 succeeded"
rows=$(grep '^| PR ' <<<"$LAST")
[ "$(head -1 <<<"$rows" | cut -d'|' -f3)" = " #2 " ] && pass "table: nothing bad, rows by number" || fail "table: order: $rows"
case_ table-red-sorts-first 0 "PR build ❌ at head" "results $P4 failed"
rows=$(grep '^| PR ' <<<"$LAST")
[ "$(head -2 <<<"$rows" | cut -d'|' -f3 | tr -d '\n')" = " #3  #4 " ] && pass "table: red and stale rows first" || fail "table: order: $rows"
case_ table-unreadable-sorts-first 0 "PR build UNKNOWN (lookup failed)" \
  "obsinfo $P3 $H3 && results $P3 succeeded && rm \$B/obs/source/$P4/tesseract-ocr/_scmsync.obsinfo"
rows=$(grep '^| PR ' <<<"$LAST")
[ "$(head -1 <<<"$rows" | cut -d'|' -f3)" = " #4 " ] && pass "table: an unreadable build sorts first" || fail "table: order: $rows"
case_ table-comments-unreadable 0 "PR build UNKNOWN (lookup failed)" "rm \$G/pool/tesseract-ocr/issues/3/comments"
case_ table-pending-sorts-by-number 0 "no PR build yet" "put \$G/pool/tesseract-ocr/issues/3/comments '[]'"
rows=$(grep '^| PR ' <<<"$LAST")
[ "$(head -1 <<<"$rows" | cut -d'|' -f3)" = " #2 " ] && pass "table: a pending build is not bad" || fail "table: order: $rows"
# Only open pool PRs are read from OBS: a merged one's PR project is gone.
case_ table-merged-not-read 0 "| PR | #4 | tesseract-ocr | pool/tesseract-ocr:leap-16.1 | ✅ merged |" \
  "pr 4 $H4 leap-16.1 true closed && rm \$B/obs/source/$P4/tesseract-ocr/_scmsync.obsinfo &&
   put \$B/obs/request_view_collection_states_accepted_roles_creator_user_tester_types_submit '<collection matches=\"0\"/>' &&
   put \$G/issues/search_type_pulls_created_true_state_all_limit_50 '[
    {\"number\": 4, \"state\": \"closed\", \"repository\": {\"full_name\": \"pool/tesseract-ocr\"}, \"pull_request\": {\"merged\": true}}]' &&
   put \$G/issues/search_type_pulls_review_requested_true_state_all_limit_50 '[]'" --state accepted
row=$(grep '| #4 |' <<<"$LAST")
[ -n "$row" ] && ! grep -qF "PR build" <<<"$row" && pass "table: a merged PR is not read from OBS" || fail "table: merged row: $row"

echo "---"; [ "$fails" = 0 ] && echo "all sr-status checks passed" || echo "$fails FAILED"
exit $((fails > 0))
