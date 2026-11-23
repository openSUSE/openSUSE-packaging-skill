#!/bin/bash
# test-sr-status.sh — proves sr-status.py reads a pool PR's build from OBS, not
# from the staging bot's last comment. Offline: fake `geectl` and `git-obs` on PATH
# serve fixtures from a per-case tree; every src.opensuse.org read goes through
# git-obs (one case plants a tea token to prove it is never read). The fixtures replay
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

# A missing fixture is a 404; one holding @NET is a refused connection, one
# holding "@ERR <text>" fails with that text, and one holding @HANG answers
# nothing for 20s (then an empty success).
mkdir -p "$work/bin"
cat > "$work/bin/serve" <<'EOF'
#!/bin/bash
[ -f "$1" ] || { echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1; }
[ "$(cat "$1")" = @HANG ] && exec sleep 20
[ "$(cat "$1")" = @NET ] && { echo "Failed to establish a new connection: [Errno 111] Connection refused" >&2; exit 1; }
[ "$(head -c5 "$1")" = "@ERR " ] && { cut -c6- "$1" >&2; exit 1; }
cat "$1"
EOF
cat > "$work/bin/geectl" <<'EOF'
#!/bin/bash
echo "geectl $*" >> "$FIX/calls"
case "$*" in
  # A request search by id answers from req/<id>, one entry per id it has;
  # an @NET there fails the whole call, like a dropped connection.
  "request search --with-history --request-id "*)
    shift 3
    out='{"requests": ['; first=1
    for a in "$@"; do
      [ "$a" = --request-id ] && continue
      [ "$(cat "$FIX/req/$a" 2>/dev/null)" = @NET ] && {
        echo "Failed to establish a new connection: [Errno 111] Connection refused" >&2; exit 1; }
      [ -f "$FIX/req/$a" ] || continue
      [ $first = 1 ] || out="$out,"
      first=0; out="$out$(cat "$FIX/req/$a")"
    done
    printf '%s]}\n' "$out"; exit 0 ;;
  "request search "*) f="search-$(printf %s "$*" | tr -c 'A-Za-z0-9._:-' '_')" ;;
  "request list-comments "*) f="comments-$3" ;;
  "remote cat "*) f="cat-$(printf %s "$3" | tr '/' '_')_$(printf %s "$4" | tr '/' '_')_$(printf %s "$5" | tr '/' '_')" ;;
  "remote package-log "*) f="log-$(printf %s "$3" | tr '/' '_')_$(printf %s "$4" | tr '/' '_')" ;;
  "remote link-target "*) f="link-$(printf %s "$3" | tr '/' '_')_$(printf %s "$4" | tr '/' '_')" ;;
  "remote list-files "*) if [ "$5" = --rev ]; then
      f="list-$(printf %s "$3" | tr '/' '_')_$(printf %s "$4" | tr '/' '_')_rev_$6"
    else
      f="list-$(printf %s "$3" | tr '/' '_')_$(printf %s "$4" | tr '/' '_')"
    fi ;;
  "remote project-meta "*) f="meta-$(printf %s "$3" | tr '/' '_')" ;;
  "build results "*) f="results-$(printf %s "$3" | tr '/' '_')" ;;
  "build job-history "*) f="jobhist-$(printf %s "$3" | tr '/' '_')_$(printf %s "$4" | tr '/' '_')_$(printf %s "$5" | tr '/' '_')_$(printf %s "$7" | tr ':' '_')" ;;
  *) echo "fake geectl: unexpected $*" >&2; exit 99 ;;
esac
[ -f "$FIX/$f" ] || { printf '{"error":{"code":"not_found","context":"no such thing"}}\n' >&2; exit 3; }
exec serve "$FIX/$f"
EOF
cat > "$work/bin/git-obs" <<'EOF'
#!/bin/bash
echo "git-obs $*" >> "$FIX/calls"
# Only the src.opensuse.org login may answer: the default one can be another forge.
[ "$1 $2 $3 $4" = "-G src.opensuse.org -q api" ] || { echo "fake git-obs: unexpected $*" >&2; exit 99; }
exec serve "$FIX/gitea$(printf %s "$5" | tr '?&=' '___')"
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
# srch <query> <json> — the request-search fixture for the query as sr-status.py passes it
srch() { printf '%s\n' "$2" > "$B/search-$(printf %s "request search $1" | tr -c 'A-Za-z0-9._:-' '_')"; }
# spath <query> — that fixture's path under $B (the case's copy in a mutation)
spath() { printf '%s/search-%s' "$B" "$(printf %s "request search $1" | tr -c 'A-Za-z0-9._:-' '_')"; }
Q_OPEN="--creator tester --type submit --with-history --state new --state review --state declined"
Q_ALL="--creator tester --type submit --with-history --state new --state review --state declined --state accepted --state revoked --state superseded"
closed_q() { printf '%s' "--creator tester --type submit --state accepted --state revoked --state superseded --since $1"; }
later_q() { printf '%s' "--target-project $1 --target-package $2 --type submit --state new --state review --state accepted"; }
SINCE=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=14)).strftime("%Y-%m-%d"))')
SINCE3=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=3)).strftime("%Y-%m-%d"))')
pr() { # <num> <head sha> <base> [merged] [state]
  put "$G/pool/tesseract-ocr/pulls/$1" "{\"number\": $1, \"state\": \"${5:-open}\",
    \"merged\": ${4:-false}, \"created_at\": \"2026-09-23T15:50:00+02:00\",
    \"head\": {\"ref\": \"tess-$3\", \"sha\": \"$2\",
               \"repo\": {\"full_name\": \"a-packager/tesseract-ocr\"}},
    \"base\": {\"ref\": \"$3\"}}"
}
results() { # <project> <x86_64 code> [aarch64 code] [x86_64 dirty] [i586 dirty]
  local dx=${4:-false} di=${5:-false}
  put "$B/results-$1" "{\"state\": 0, \"results\": [
  {\"project\": \"$1\", \"repository\": \"standard\", \"arch\": \"local\", \"code\": \"blocked\", \"state\": \"blocked\", \"dirty\": false, \"statuses\": [{\"package\": \"tesseract-ocr\", \"code\": \"excluded\"}]},
  {\"project\": \"$1\", \"repository\": \"standard\", \"arch\": \"i586\", \"code\": \"published\", \"state\": \"published\", \"dirty\": $di, \"statuses\": [{\"package\": \"tesseract-ocr\", \"code\": \"excluded\", \"details\": \"package whitelist\"}]},
  {\"project\": \"$1\", \"repository\": \"standard\", \"arch\": \"x86_64\", \"code\": \"published\", \"state\": \"published\", \"dirty\": $dx, \"statuses\": [{\"package\": \"tesseract-ocr\", \"code\": \"$2\"}]},
  {\"project\": \"$1\", \"repository\": \"standard\", \"arch\": \"aarch64\", \"code\": \"published\", \"state\": \"published\", \"dirty\": false, \"statuses\": [{\"package\": \"tesseract-ocr\", \"code\": \"${3:-$2}\"}]}]}"
}
obsinfo() { # <project> <commit>
  put "$B/cat-$(printf %s "$1" | tr '/' '_')_tesseract-ocr__scmsync.obsinfo" "mtime: 1790171239
commit: $2
url: https://src.opensuse.org/pool/tesseract-ocr
revision: $2
trackingbranch: leap-16.x"
}
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
extra() { # <project> <package> <code>: one more status in the x86_64 result
  python3 - "$B/results-$1" "$2" "$3" <<'EOF'
import json, sys
p, pkg, code = sys.argv[1:4]
d = json.load(open(p))
for r in d["results"]:
    if r["arch"] == "x86_64":
        r["statuses"].append({"package": pkg, "code": code})
json.dump(d, open(p, "w"))
EOF
}
srclog() { # <project> <srcmd5>: the package log's latest entry
  put "$B/log-$(printf %s "$1" | tr '/' '_')_tesseract-ocr"     "{\"project\": \"$1\", \"package\": \"tesseract-ocr\", \"entries\": [{\"rev\": 7, \"srcmd5\": \"$2\", \"time\": \"2026-10-20T10:00:00\", \"user\": \"tester\", \"comment\": \"\"}]}"
}
jobhist() { # <project> <arch>/<package> <srcmd5>: the last build job there
  local prj=$1 ap=$2 src=$3
  local arch=${ap%%/*} name=${ap#*/}
  put "$B/jobhist-$(printf %s "$prj" | tr '/' '_')_standard_${arch}_$(printf %s "$name" | tr ':' '_')"     "{\"project\": \"$prj\", \"repository\": \"standard\", \"arch\": \"$arch\", \"entries\": [{\"package\": \"$name\", \"rev\": 7, \"srcmd5\": \"$src\", \"versrel\": \"5.5.3-160000.1\", \"bcnt\": 1, \"code\": \"succeeded\"}]}"
}
built() { # <project> <srcmd5>: sources, and both building arches' last build, at srcmd5
  put "$B/link-$(printf %s "$1" | tr '/' '_')_tesseract-ocr" \
    "{\"project\": \"$1\", \"package\": \"tesseract-ocr\", \"target\": null}"
  srclog "$1" "$2" && for a in x86_64 aarch64; do
    jobhist "$1" "$a/tesseract-ocr" "$2" || return 1
  done
}
pin() { # <project> <products PR> <head repo> <head ref>
  put "$B/meta-$(printf %s "$1" | tr '/' '_')" "{\"name\": \"$1\", \"url\": \"https://src.opensuse.org/products/PackageHub/pulls/$2\"}"
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
srch "$Q_OPEN" '{"requests": []}'
srch "$(closed_q "$SINCE")" '{"requests": []}'

# case_ <name> <expected rc> <expected message> <mutation> [sr-status args...]
# Mutations run in the case's fixture tree ($B there), with $G/$P3/... to hand.
# XENV holds extra environment for the run; SHORT=("$work/short.py") runs the
# script with a 3s call timeout.
XENV=(); SHORT=()
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got; shift 4
  cp -a "$B" "$dir" && mkdir -p "$dir/home"
  (B=$dir G=$dir/gitea/repos; cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  out="$(cd "$dir" && FIX=$dir HOME=$dir/home GEECTL_OBS_USERNAME=tester PATH="$work/bin:$PATH" \
    env ${XENV[@]+"${XENV[@]}"} python3 ${SHORT[@]+"${SHORT[@]}"} "$SR" "$@" 2>&1)"; got=$?
  LAST=$out; CALLS=$(cat "$dir/calls" 2>/dev/null)
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"
    printf '%s\n' "$out" | sed 's/^/    /'
  }
}
no_geectl_calls() { ! grep -q '^geectl ' <<<"$CALLS" && pass "$1: no OBS call" || fail "$1: queried OBS: $CALLS"; }

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
  "rm \$B/meta-$P3" --pr 'pool/tesseract-ocr#3'
case_ stale-pin-meta-unparsable 4 "pinned by an unknown products PR (lookup failed)" \
  "put \$B/meta-$P3 '<project'" --pr 'pool/tesseract-ocr#3'
case_ building 3 "VERDICT: PENDING — still building at the PR head" \
  "results $P4 building succeeded" --pr 'pool/tesseract-ocr#4'
case_ dirty-repository 3 "standard/x86_64 succeeded (dirty)" \
  "results $P4 succeeded succeeded true" --pr 'pool/tesseract-ocr#4'
# An excluded arch in a dirty repository may be about to build the new sources.
case_ dirty-excluded-arch 3 "standard/i586 excluded (dirty)" \
  "results $P4 succeeded succeeded false true" \
  --pr 'pool/tesseract-ocr#4'
# The scheduler race: obsinfo is at the head and the results say succeeded, not
# dirty, but x86_64's last build is of the previous sources.
case_ succeeded-from-older-sources 3 "VERDICT: PENDING — not yet rebuilt from the current sources" \
  "jobhist $P4 x86_64/tesseract-ocr $OLD" --pr 'pool/tesseract-ocr#4'
grep -qF "built from older sources: standard/x86_64 succeeded (built ${OLD:0:12}, sources ${S4:0:12})" <<<"$LAST" \
  && ! grep -qF "standard/aarch64 succeeded (built" <<<"$LAST" \
  && pass "succeeded-from-older-sources: names only the older arch" || fail "succeeded-from-older-sources: $LAST"
case_ no-build-recorded 3 "standard/aarch64 succeeded (built nothing recorded, sources ${S4:0:12})" \
  "put \$B/jobhist-${P4}_standard_aarch64_tesseract-ocr '{\"entries\": []}'" --pr 'pool/tesseract-ocr#4'
# The last job, not _history, says which sources were built: the job history
# is the only read, so an older _history entry changes nothing.
case_ unchanged-rebuild 0 "VERDICT: GREEN at the PR head" \
  ":" --pr 'pool/tesseract-ocr#4'
# A flavor is judged by its own history, not the main package's.
case_ flavor-at-current-sources 0 "VERDICT: GREEN at the PR head" \
  "extra $P4 tesseract-ocr:docs succeeded && jobhist $P4 x86_64/tesseract-ocr:docs $S4" --pr 'pool/tesseract-ocr#4'
case_ flavor-from-older-sources 3 "standard/x86_64:docs succeeded (built ${OLD:0:12}, sources ${S4:0:12})" \
  "extra $P4 tesseract-ocr:docs succeeded && jobhist $P4 x86_64/tesseract-ocr:docs $OLD" --pr 'pool/tesseract-ocr#4'
case_ history-missing 2 "could not read the $P4/standard/x86_64/tesseract-ocr job history (lookup failed)" \
  "rm \$B/jobhist-${P4}_standard_x86_64_tesseract-ocr" --pr 'pool/tesseract-ocr#4'
case_ history-unparsable 2 "could not read the $P4/standard/x86_64/tesseract-ocr job history (lookup failed)" \
  "put \$B/jobhist-${P4}_standard_x86_64_tesseract-ocr '<jobhistlist'" --pr 'pool/tesseract-ocr#4'
case_ history-network 6 "could not read the $P4/standard/x86_64/tesseract-ocr job history (network failure)" \
  "put \$B/jobhist-${P4}_standard_x86_64_tesseract-ocr @NET" --pr 'pool/tesseract-ocr#4'
case_ srcmd5-missing 2 "could not read the $P4/tesseract-ocr srcmd5 (lookup failed)" \
  "rm \$B/log-${P4}_tesseract-ocr" --pr 'pool/tesseract-ocr#4'
case_ srcmd5-unparsable 2 "could not read the $P4/tesseract-ocr srcmd5 (lookup failed)" \
  "put \$B/log-${P4}_tesseract-ocr '<directory'" --pr 'pool/tesseract-ocr#4'
case_ srcmd5-absent 2 "could not read the $P4/tesseract-ocr srcmd5 (lookup failed)" \
  "put \$B/log-${P4}_tesseract-ocr '{\"entries\": [{\"rev\": 7}]}'" --pr 'pool/tesseract-ocr#4'
case_ no-results-yet 3 "VERDICT: PENDING — no build results yet" \
  "put \$B/results-$P4 '{\"state\": 0, \"results\": []}'" --pr 'pool/tesseract-ocr#4'
case_ no-bot-comment 3 "VERDICT: PENDING — no staging-bot build comment (PR opened 2026-09-23)" \
  "put \$G/pool/tesseract-ocr/issues/4/comments '[]'" --pr 'pool/tesseract-ocr#4'
no_geectl_calls no-bot-comment
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
no_geectl_calls merged
case_ closed-unmerged 1 "VERDICT: CLOSED without a merge" "pr 4 $H4 leap-16.1 false closed" --pr 'pool/tesseract-ocr#4'
case_ obsinfo-missing 2 "VERDICT: UNKNOWN — could not read $P4/tesseract-ocr/_scmsync.obsinfo (lookup failed)" \
  "rm \$B/cat-${P4}_tesseract-ocr__scmsync.obsinfo" --pr 'pool/tesseract-ocr#4'
case_ obsinfo-no-commit 2 "VERDICT: UNKNOWN — no commit: in _scmsync.obsinfo" \
  "put \$B/cat-${P4}_tesseract-ocr__scmsync.obsinfo 'mtime: 1'" --pr 'pool/tesseract-ocr#4'
case_ pr-head-missing 2 "VERDICT: UNKNOWN — no the PR head" \
  "put \$G/pool/tesseract-ocr/pulls/4 '{\"number\": 4, \"state\": \"open\", \"base\": {\"ref\": \"leap-16.1\"}}'" \
  --pr 'pool/tesseract-ocr#4'
case_ obsinfo-network 6 "(network failure)" \
  "put \$B/cat-${P4}_tesseract-ocr__scmsync.obsinfo @NET" --pr 'pool/tesseract-ocr#4'
# Each transient failure the classifier knows asks for a retry (6), never
# "lookup failed" (2); the 404 cases are the controls. One pattern per line.
while IFS='|' read -r kind msg <&3; do
  case_ "network-$kind" 6 "(network failure)" \
    "put \$B/cat-${P4}_tesseract-ocr__scmsync.obsinfo '@ERR $msg'" --pr 'pool/tesseract-ocr#4'
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
# src.opensuse.org is read through git-obs only, which keeps its own login: a
# tea token on disk is never loaded. yaml.py stands in for pyyaml (JSON is
# YAML) and leaves a mark when anything parses the tea config; the proxy
# refuses on the loopback, so a direct fetch would show as a warning too.
mkdir -p "$work/pylib"
printf 'import json\nimport os\n\n\ndef safe_load(f):\n    open(os.environ["FIX"] + "/tea-read", "w").close()\n    return json.load(f)\n' > "$work/pylib/yaml.py"
XENV=(PYTHONPATH="$work/pylib" https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 no_proxy= NO_PROXY=)
case_ tea-token-ignored 0 "VERDICT: GREEN at the PR head" \
  "put home/.config/tea/config.yml '{\"logins\": [{\"name\": \"src.opensuse.org\", \"token\": \"t\"}]}'" \
  --pr 'pool/tesseract-ocr#4'
XENV=()
[ ! -e "$work/tea-token-ignored/tea-read" ] && ! grep -qF "direct src.opensuse.org fetch" <<<"$LAST" \
  && pass "tea-token-ignored: the tea config is never read" || fail "tea-token-ignored: the tea config was read: $LAST"
case_ results-missing 2 "could not read the $P4 results (lookup failed)" \
  "rm \$B/results-$P4" --pr 'pool/tesseract-ocr#4'
case_ results-unparsable 2 "could not read the $P4 results (lookup failed)" \
  "put \$B/results-$P4 '<resultlist'" --pr 'pool/tesseract-ocr#4'
case_ pr-missing 2 "VERDICT: UNKNOWN — could not read pool/tesseract-ocr#9 (lookup failed)" \
  ":" --pr 'pool/tesseract-ocr#9'
case_ pr-network 6 "VERDICT: UNKNOWN — could not read pool/tesseract-ocr#4 (network failure)" \
  "put \$G/pool/tesseract-ocr/pulls/4 @NET" --pr 'pool/tesseract-ocr#4'
case_ comments-missing 2 "VERDICT: UNKNOWN — could not read the PR comments (lookup failed)" \
  "rm \$G/pool/tesseract-ocr/issues/4/comments" --pr 'pool/tesseract-ocr#4'
case_ bad-pr-spec 2 "--pr takes OWNER/REPO#N and no request ids" ":" --pr 'pool/tesseract-ocr'
case_ pr-with-ids 2 "--pr takes OWNER/REPO#N and no request ids" ":" --pr 'pool/tesseract-ocr#4' 1234

# ---------------------------------------------------------------- hung calls
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
case_ hang-git-obs-pr 6 "VERDICT: UNKNOWN — could not read pool/tesseract-ocr#4 (network failure)" \
  "put \$G/pool/tesseract-ocr/pulls/4 @HANG" --pr 'pool/tesseract-ocr#4'
grep -qF "git-obs timed out after 3s" <<<"$LAST" && pass "hang-git-obs-pr: says it timed out" || fail "hang-git-obs-pr: $LAST"
case_ hang-geectl-obsinfo 6 "could not read $P4/tesseract-ocr/_scmsync.obsinfo (network failure)" \
  "put \$B/cat-${P4}_tesseract-ocr__scmsync.obsinfo @HANG" --pr 'pool/tesseract-ocr#4'
case_ hang-geectl-collection 2 "geectl timed out after 3s" \
  "put \$(spath \"\$Q_OPEN\") @HANG"
XENV=(GEECTL_OBS_USERNAME=)
case_ no-user 2 "could not determine OBS user" ":"
XENV=()
# The table leg warns and goes on without the PRs, so its header must not
# claim them.
case_ hang-git-obs-pr-leg 0 "src.opensuse.org PRs UNKNOWN" \
  "put \$G/issues/search_type_pulls_created_true_state_open_limit_50 @HANG"
SHORT=()
# A hung call must fail before the harness gives up on the whole tool call
# (2 minutes by default), or the timeout is never seen.
python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m); sys.exit(0 if m.TIMEOUT < 120 else 1)' "$SR" \
  && pass "TIMEOUT is under the 2-minute tool limit" || fail "TIMEOUT is not under 120s"
# A missing geectl or git-obs is a failed lookup, not a traceback: exit 1 would
# read as "red at the PR head".
mkdir -p "$work/py-only" && ln -sf "$(command -v python3)" "$work/py-only/python3"
out="$(PATH="$work/py-only" HOME="$work" python3 "$SR" --pr 'pool/tesseract-ocr#4' 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qF "VERDICT: UNKNOWN — could not read pool/tesseract-ocr#4 (lookup failed)" <<<"$out" \
  && grep -qF "git-obs: command not found" <<<"$out" && ! grep -q Traceback <<<"$out" \
  && pass "missing git-obs: lookup failed (rc=2)" || { fail "missing git-obs: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

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
  "obsinfo $P3 $H3 && results $P3 succeeded && rm \$B/cat-${P4}_tesseract-ocr__scmsync.obsinfo"
rows=$(grep '^| PR ' <<<"$LAST")
[ "$(head -1 <<<"$rows" | cut -d'|' -f3)" = " #4 " ] && pass "table: an unreadable build sorts first" || fail "table: order: $rows"
case_ table-comments-unreadable 0 "PR build UNKNOWN (lookup failed)" "rm \$G/pool/tesseract-ocr/issues/3/comments"
case_ table-pending-sorts-by-number 0 "no PR build yet" "put \$G/pool/tesseract-ocr/issues/3/comments '[]'"
rows=$(grep '^| PR ' <<<"$LAST")
[ "$(head -1 <<<"$rows" | cut -d'|' -f3)" = " #2 " ] && pass "table: a pending build is not bad" || fail "table: order: $rows"
# Only open pool PRs are read from OBS: a merged one's PR project is gone.
case_ table-merged-not-read 0 "| PR | #4 | tesseract-ocr | pool/tesseract-ocr:leap-16.1 | ✅ merged |" \
  "pr 4 $H4 leap-16.1 true closed && rm \$B/cat-${P4}_tesseract-ocr__scmsync.obsinfo &&
   srch \"--creator tester --type submit --with-history --state accepted\" '{\"requests\": []}' &&
   put \$G/issues/search_type_pulls_created_true_state_all_limit_50 '[
    {\"number\": 4, \"state\": \"closed\", \"repository\": {\"full_name\": \"pool/tesseract-ocr\"}, \"pull_request\": {\"merged\": true}}]' &&
   put \$G/issues/search_type_pulls_review_requested_true_state_all_limit_50 '[]'" --state accepted
row=$(grep '| #4 |' <<<"$LAST")
[ -n "$row" ] && ! grep -qF "PR build" <<<"$row" && pass "table: a merged PR is not read from OBS" || fail "table: merged row: $row"

# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
sreq() { # <id> <package> <target> <state> [decline comment]
  local cmt=""; [ -n "${5:-}" ] && cmt=", \"comment\": \"$5\""
  printf '{\"id\": %s, \"creator\": \"tester\", \"title\": \"\", \"description\": \"\", \"actions\": [{\"type\": \"submit\", \"source_project\": \"devel:example\", \"source_package\": \"%s\", \"target_project\": \"%s\", \"target_package\": \"%s\"}], \"state\": {\"name\": \"%s\", \"who\": \"a-reviewer\", \"when\": \"2026-10-20T10:00:00\", \"created\": \"2026-10-20T10:00:00\"%s}, \"reviews\": [], \"history\": []}' \
    "$1" "$2" "$3" "$2" "$4" "$cmt"
}
# ---------------------------------------------------------------- replaced declines
# A declined SR that a later accepted one for the same package and target
# replaced still counts for geectl -- the next `geectl request file` from that source prompts
# over it -- so it stays at the top as cleanup, with the revoke that clears it.
# Only rows already fetched count (--state all, or ids given), never an extra
# call. The note avoids "superseded", which is an OBS state of its own.
{ printf '{\"requests\": ['
  sreq 100 foo openSUSE:Factory declined 'fix the changelog'; printf ', '
  sreq 120 foo openSUSE:Factory accepted; printf ', '
  sreq 90 bar openSUSE:Factory accepted; printf ', '
  sreq 110 bar openSUSE:Factory declined; printf ', '
  sreq 130 baz openSUSE:Factory declined; printf ', '
  sreq 140 baz devel:example accepted
  printf ']}'; } > "$work/collection.json"
REVOKE='declined; later #120 accepted — revoke: geectl request revoke --comment "replaced by #120" 100 --live'
case_ replaced-brief 0 "SR 100  [$REVOKE]" \
  "cp '$work/collection.json' \$(spath \"\$Q_ALL\")" --state all --brief --no-prs
rows=$(grep '^  SR ' <<<"$LAST")
[ "$(head -3 <<<"$rows" | awk '{print $2}' | tr '\n' ' ')" = "100 110 130 " ] \
  && pass "replaced-brief: every decline stays at the top" || fail "replaced-brief: order: $rows"
# bar's accepted #90 came before its decline; baz's accepted went elsewhere.
grep -qF "SR 110  [declined ]" <<<"$rows" && grep -qF "SR 130  [declined ]" <<<"$rows" \
  && ! grep -qi "superseded" <<<"$rows" && pass "replaced-brief: only the replaced one is annotated" \
  || fail "replaced-brief: annotations: $rows"
# Explicit ids come back from one search call per 50 ids, never one call per id
# (40 ids took over the 2-minute tool limit that way).
case_ replaced-ids 0 "| SR | 100 | foo | openSUSE:Factory | ❌ $REVOKE |" \
  "mkdir -p \$B/req &&
   sreq 100 foo openSUSE:Factory declined 'fix the changelog' > \$B/req/100 &&
   sreq 120 foo openSUSE:Factory accepted > \$B/req/120 &&
   echo '{\"id\": 120, \"comments\": []}' > \$B/comments-120" 100 120
[ "$(grep '^| SR ' <<<"$LAST" | head -1 | cut -d'|' -f3)" = " 100 " ] \
  && pass "replaced-ids: the declined row stays first" || fail "replaced-ids: order: $LAST"
[ "$(grep -c '^geectl request search --with-history --request-id' <<<"$CALLS")" = 1 ] && ! grep -q '^geectl request show' <<<"$CALLS" \
  && pass "replaced-ids: one search call for both ids" || fail "replaced-ids: calls: $CALLS"
case_ declined-alone-ids 0 "| SR | 100 | foo | openSUSE:Factory | ❌ declined |" \
  "mkdir -p \$B/req && sreq 100 foo openSUSE:Factory declined 'fix the changelog' > \$B/req/100" 100
# An id the search does not return is named, never dropped; nothing went to
# stderr, so the row does not point there.
case_ id-not-found 0 "| SR | 999 | ? | ? | ❔  | NOT FOUND | — |" \
  "mkdir -p \$B/req && sreq 100 foo openSUSE:Factory declined x > \$B/req/100" 100 999
case_ id-not-found-brief 0 "SR 999  [NOT FOUND]" ":" --brief 999
case_ ids-search-failed 0 "| SR | 100 | ? | ? | ❔  | FETCH FAILED | (see stderr) |" \
  "mkdir -p \$B/req && echo @NET > \$B/req/100" 100
# Past 50 ids the second call is made too.
case_ ids-two-chunks 0 "SR 51  [new" \
  "mkdir -p \$B/req && for i in \$(seq 1 51); do sreq \$i pkg\$i openSUSE:Factory new > \$B/req/\$i; done" \
  --brief $(seq 1 51)
[ "$(grep -c '^geectl request search --with-history --request-id' <<<"$CALLS")" = 2 ] && ! grep -q 'NOT FOUND' <<<"$LAST" \
  && pass "ids-two-chunks: two search calls, every id found" || fail "ids-two-chunks: $CALLS"
# One malformed id would fail a whole search call: refuse it up front; sr#N and #N are N.
for bad in abc '1385677)' 01385677 ''; do
  case_ "bad-id-${bad:-empty}" 2 "not a request id" ":" "$bad"
done
case_ id-with-sr-prefix 0 "| SR | 100 | foo | openSUSE:Factory | ❌ declined |" \
  "mkdir -p \$B/req && sreq 100 foo openSUSE:Factory declined x > \$B/req/100" 'sr#100'

# ---------------------------------------------------------------- requests at volume
# The listing used to cut at 40, oldest first and before the declines-first
# sort, and to say only "N shown": "40 open" was reported while 166 were, and a
# declined one fell off. --brief has no cap; the table keeps every decline and
# says what it cut.
spath_for() { # <tree> <query>: that search fixture's path under <tree>
  printf '%s/search-%s' "$1" "$(printf %s "request search $2" | tr -c 'A-Za-z0-9._:-' '_')"; }
closed_fix() { spath "$(closed_q "$SINCE")"; }
later() { # <prj> <pkg> <json>: the later-requests search fixture for that target
  printf '%s\n' "$3" > "$(spath "$(later_q "$1" "$2")")"; }
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
many() { # <count>: requests 1..count to openSUSE:Factory, #1 declined, the rest new
  printf '{\"requests\": ['; sreq 1 pkg1 openSUSE:Factory declined 'old decline'
  for i in $(seq 2 "$1"); do printf ', '; sreq "$i" "pkg$i" openSUSE:Factory new; done; printf ']}'
}
case_ brief-uncapped 0 "### Submissions for \`tester\` — 45 shown" \
  "many 45 > \$(spath \"\$Q_OPEN\")" --brief --no-prs
[ "$(grep -c '^  SR ' <<<"$LAST")" = 45 ] && pass "brief-uncapped: every request listed" || fail "brief-uncapped: $(grep -c '^  SR ' <<<"$LAST") rows"
case_ table-cap-keeps-declines 0 "— 40 of 45 shown — --limit 0 for all" \
  "many 45 > \$(spath \"\$Q_OPEN\")" --no-prs
rows=$(grep '^| SR ' <<<"$LAST")
grep -q '^| SR | 1 | pkg1 ' <<<"$rows" && ! grep -qE '^\| SR \| [2-6] \|' <<<"$rows" && grep -q '^| SR | 7 |' <<<"$rows" \
  && pass "table-cap-keeps-declines: the decline stays, the oldest others go" || fail "table-cap-keeps-declines: $rows"
case_ limit-zero-no-cap 0 "— 45 shown" "many 45 > \$(spath \"\$Q_OPEN\")" --no-prs --limit 0
case_ limit-negative 2 "--limit takes 0 (no cap) or a positive number" ":" --limit -1
# A PR leg that comes back at its page size may hold more: say so.
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
full_pr_page() { # <fixture tree>
  { echo '['; for i in $(seq 1 49); do
      printf '{"number": %s, "state": "open", "repository": {"full_name": "g/r"}},\n' "$i"; done
    echo '{"number": 50, "state": "open", "repository": {"full_name": "g/r"}}]'
  } > "$1/gitea/repos/issues/search_type_pulls_created_true_state_open_limit_50"
}
case_ pr-page-full 0 "the created PR leg returned 50, its page size: more may exist" "full_pr_page \$B" --brief
case_ summary-pr-page-full 0 "the created PR leg returned 50, its page size: more may exist" "full_pr_page \$B" --summary

# --summary: counts by state x target, every decline with its reason and what
# was filed for that package since (at the target and in the devel project the
# fix goes to), the oldest new and review requests, and comments by others
# newer than your own last action. A failed lookup is UNKNOWN, never "nothing".
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
vreq() { # <id> <package> <target> <state> <created> [decline comment] [a later own history entry]
  local cmt=""; [ -n "${6:-}" ] && cmt=", \"comment\": \"$6\""
  local hist=""; [ -n "${7:-}" ] && hist=", {\"who\": \"tester\", \"when\": \"$7\", \"description\": \"Request got a new review\", \"comment\": \"\"}"
  printf '{\"id\": %s, \"creator\": \"tester\", \"title\": \"\", \"description\": \"\", \"actions\": [{\"type\": \"submit\", \"source_project\": \"devel:example\", \"source_package\": \"%s\", \"target_project\": \"%s\", \"target_package\": \"%s\"}], \"state\": {\"name\": \"%s\", \"who\": \"a-reviewer\", \"when\": \"2026-10-18T10:00:00\", \"created\": \"%s\"%s}, \"reviews\": [], \"history\": [{\"who\": \"tester\", \"when\": \"%s\", \"description\": \"Request created\", \"comment\": \"\"}%s]}' \
    "$1" "$2" "$3" "$2" "$4" "$5" "$cmt" "$5" "$hist"
}
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
cmt() { # <who> <when> <text>
  printf '{\"who\": \"%s\", \"when\": \"%s\", \"id\": 1, \"body\": \"%s\"}' "$1" "${2/ /T}" "$3"
}
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
comments() { # <fixture tree> <id> <who> <when> <text> [<who> <when> <text> ...]
  local B=$1 id=$2; shift 2
  { printf '{\"id\": %s, \"comments\": [' "$id"; local first=1
    while [ $# -ge 3 ]; do [ $first = 1 ] || printf ', '; first=0; cmt "$1" "$2" "$3"; shift 3; done
    printf ']}'; } > "$B/comments-$id"
}
# XML carries no raw ESC, so OBS never sends one; C1 CSI, bidi and zero-width it can.
CSI=$'\xc2\x9b'; RLO=$'\xe2\x80\xae'; ZWSP=$'\xe2\x80\x8b'  # UTF-8 bytes: \u needs a UTF-8 locale
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
summary_fixtures() { # <fixture tree>
  local B=$1
  { printf '{\"requests\": ['
    vreq 201 alpha M17N new 2026-10-01T08:00:00; printf ', '
    vreq 202 beta M17N new 2026-10-15T08:00:00; printf ', '
    vreq 203 gamma games review 2026-10-16T08:00:00; printf ', '
    vreq 204 delta openSUSE:Factory review 2026-10-16T09:00:00; printf ', '
    vreq 205 owntone openSUSE:Factory declined 2026-10-17T18:30:23 "nothing provides group(owntone) ${CSI}31mDO NOT REVIEW${CSI}0m"; printf ', '
    vreq 206 epsilon games new 2026-10-19T06:00:00; printf ', '
    vreq 207 zeta games new 2026-10-10T08:00:00 '' 2026-10-18T08:00:00
    printf ']}'; } > "$(spath_for "$B" "$Q_OPEN")"
  # alpha: a reviewer asked something after the request was filed; hostile bytes are stripped
  comments "$B" 201 gsu '2026-10-19 05:09:04' "Please keep ${RLO}the empty${ZWSP} lines"
  # beta: the reviewer's comment came before your own reply, so it is handled
  comments "$B" 202 maint '2026-10-16 05:00:00' 'why this patch?' tester '2026-10-16 06:00:00' 'see upstream'
  # gamma: bots spoke, the newest last; abbott is a person whose name holds "bot"
  comments "$B" 203 factory-auto '2026-10-17 05:00:00' 'check_source ok' abbott '2026-10-17 07:00:00' 'looks fine' \
    staging-bot '2026-10-17 08:00:00' 'staged'
  # delta: the comment fetch fails
  echo @NET > "$B/comments-204"
  echo '{"id": 205, "comments": []}' > "$B/comments-205"
  # epsilon: same day as the filing, one hour later (2026-10-19T06 vs 07:00 UTC)
  comments "$B" 206 maint2 '2026-10-19 07:00:00' 'same-day question'
  # zeta: a comment between the filing and your later action on the request
  comments "$B" 207 maint3 '2026-10-12 08:00:00' 'answered since'
  later openSUSE:Factory owntone '{"requests": [
    {"id": 250, "creator": "maint", "title": "", "description": "", "actions": [{"type": "submit", "source_project": "devel:example", "source_package": "owntone", "target_project": "openSUSE:Factory", "target_package": "owntone"}], "state": {"name": "accepted", "who": "maint", "when": "2026-10-18T10:00:00", "created": "2026-10-18T10:00:00"}, "reviews": [], "history": []},
    {"id": 190, "creator": "old", "title": "", "description": "", "actions": [{"type": "submit", "source_project": "devel:example", "source_package": "owntone", "target_project": "openSUSE:Factory", "target_package": "owntone"}], "state": {"name": "accepted", "who": "old", "when": "2026-10-18T10:00:00", "created": "2026-10-18T10:00:00"}, "reviews": [], "history": []}]}'
  later devel:example owntone '{"requests": [
    {"id": 260, "creator": "tester", "title": "", "description": "", "actions": [{"type": "submit", "source_project": "devel:example", "source_package": "owntone", "target_project": "devel:example", "target_package": "owntone"}], "state": {"name": "new", "who": "tester", "when": "2026-10-18T10:00:00", "created": "2026-10-18T10:00:00"}, "reviews": [], "history": []}]}'
}
case_ summary 0 "OBS submit requests: 7 (new 4 · review 2 · declined 1)" "summary_fixtures \$B" --summary --no-prs
for want in "  games                                   3  (2/1/0)" \
            "oldest new: SR 201 alpha -> M17N (created 2026-10-01" \
            "oldest review: SR 203 gamma -> games (created 2026-10-16" \
            'SR 205 owntone -> openSUSE:Factory by a-reviewer: "nothing provides group(owntone) DO NOT REVIEW"' \
            "    openSUSE:Factory/owntone: #250 accepted by maint" \
            "    devel:example/owntone: #260 new by tester" \
            "comments by others since your last action: 3 request(s), 1 UNKNOWN (comment fetch failed)" \
            'SR 201 alpha -> M17N gsu 2026-10-19: "Please keep the empty lines"' \
            'SR 203 gamma -> games abbott 2026-10-17: "looks fine"' \
            'SR 206 epsilon -> games maint2 2026-10-19: "same-day question"' \
            "SR 204 delta -> openSUSE:Factory UNKNOWN (comment fetch failed)"; do
  grep -qF -- "$want" <<<"$LAST" && pass "summary: $want" || fail "summary: missing '$want'"
done
! grep -qE 'SR 202 beta|SR 207 zeta|#190|staging-bot|factory-auto' <<<"$LAST" \
  && pass "summary: handled, bot and earlier items stay out" || fail "summary: extra lines: $LAST"
! grep -qF -e "$CSI" -e "$RLO" -e "$ZWSP" <<<"$LAST" && pass "summary: C1, bidi and zero-width controls stripped" || fail "summary: raw control characters"
# Your own fix of a Factory decline goes to the devel project: name it there.
case_ summary-later-unknown 0 "openSUSE:Factory/owntone: UNKNOWN (lookup failed)" \
  "summary_fixtures \$B && rm \$(spath \"\$(later_q openSUSE:Factory owntone)\")" --summary --no-prs
case_ summary-nothing-since 0 "openSUSE:Factory/owntone: nothing filed since" \
  "summary_fixtures \$B && later openSUSE:Factory owntone '{\"requests\": []}'" --summary --no-prs
# A home: source is a branch, not a devel project: no lookup there.
case_ summary-home-source 0 "openSUSE:Factory/owntone: #250 accepted by maint" \
  "summary_fixtures \$B && sed -i 's|\"source_project\": \"devel:example\", \"source_package\": \"owntone\"|\"source_project\": \"home:<user>:branches\", \"source_package\": \"owntone\"| ' \$(spath \"\$Q_OPEN\")" \
  --summary --no-prs
! grep -q 'home:<user>' <<<"$LAST" && pass "summary-home-source: no lookup in a home project" || fail "summary-home-source: $LAST"
case_ summary-prs 0 "src.opensuse.org PRs: 3 yours, 1 awaiting your review" \
  "summary_fixtures \$B && put \$G/issues/search_type_pulls_review_requested_true_state_open_limit_50 \
   '[{\"number\": 7, \"state\": \"open\", \"repository\": {\"full_name\": \"somegroup/example\"}}]'" --summary
grep -qF "awaiting your review: somegroup/example#7" <<<"$LAST" && pass "summary-prs: names the PR awaiting you" || fail "summary-prs: $LAST"
case_ summary-with-ids 2 "--summary takes no request ids" ":" --summary 100
# The follow-up search is URL-quoted: a raw '+' arrives as a space, and
# libsigc++2 then matched nothing. It asks only for newer requests (@id>).
case_ summary-plus-in-name 0 "openSUSE:Factory/libsigc++2: #300 accepted by maint" \
  "summary_fixtures \$B && sed -i 's/owntone/libsigc++2/g' \$(spath \"\$Q_OPEN\") &&
   later openSUSE:Factory libsigc++2 '{\"requests\": [{\"id\": 300, \"creator\": \"maint\", \"title\": \"\", \"description\": \"\", \"actions\": [{\"type\": \"submit\", \"source_project\": \"devel:example\", \"source_package\": \"libsigc++2\", \"target_project\": \"openSUSE:Factory\", \"target_package\": \"libsigc++2\"}], \"state\": {\"name\": \"accepted\", \"who\": \"maint\", \"when\": \"2026-10-18T10:00:00\", \"created\": \"2026-10-18T10:00:00\"}, \"reviews\": [], \"history\": []}]}'" \
  --summary --no-prs
grep -qF -- "--target-package libsigc++2" <<<"$CALLS" && ! grep -qF "libsigc%2B%2B2" <<<"$CALLS" && ! grep -qF "@id>" <<<"$CALLS" \
  && pass "summary-plus-in-name: the typed search carries the name verbatim" || fail "summary-plus-in-name: $CALLS"
# Your PRs' comments are read too, only for PRs that have any: the newest by
# someone else after your own last comment, bots (legaldb among them) aside.
# The pool PRs' builds are not read here, and the summary says so.
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
pr_comments_fixtures() { # <fixture tree>
  local G=$1/gitea/repos
  printf '%s' '[
   {"number": 4, "state": "open", "comments": 0, "user": {"login": "me"}, "created_at": "2026-10-10T08:00:00+02:00", "repository": {"full_name": "pool/tesseract-ocr"}},
   {"number": 2, "state": "open", "comments": 3, "user": {"login": "me"}, "created_at": "2026-10-10T08:00:00+02:00", "repository": {"full_name": "somegroup/example"}},
   {"number": 6, "state": "open", "comments": 2, "user": {"login": "me"}, "created_at": "2026-10-10T08:00:00+02:00", "repository": {"full_name": "other/handled"}},
   {"number": 8, "state": "open", "comments": 1, "user": {"login": "me"}, "created_at": "2026-10-10T08:00:00+02:00", "repository": {"full_name": "other/broken"}}]' \
    > "$G/issues/search_type_pulls_created_true_state_open_limit_50"
  printf '%s' '[{"user": {"login": "a-maint"}, "body": "Please run geectl local-build service-run", "created_at": "2026-10-18T09:00:00Z"},
   {"user": {"login": "legaldb"}, "body": "legal ok", "created_at": "2026-10-19T09:00:00Z"},
   {"user": {"login": "autogits_obs_staging_bot"}, "body": "Build successful", "created_at": "2026-10-19T10:00:00Z"},
   {"user": {"login": "packagehub-review"}, "body": "Review by packagehub-review represents a group of reviewers", "created_at": "2026-10-19T11:00:00Z"}]' \
    > "$G/somegroup/example/issues/2/comments"
  mkdir -p "$G/other/handled/issues/6" "$G/other/broken/issues/8"
  printf '%s' '[{"user": {"login": "a-maint"}, "body": "why?", "created_at": "2026-10-11T09:00:00+00:00"},
   {"user": {"login": "me"}, "body": "because", "created_at": "2026-10-12T09:00:00+00:00"}]' > "$G/other/handled/issues/6/comments"
  echo @NET > "$G/other/broken/issues/8/comments"
}
case_ summary-pr-comments 0 'PR somegroup/example#2 a-maint 2026-10-18: "Please run geectl local-build service-run"' \
  "summary_fixtures \$B && pr_comments_fixtures \$B" --summary
for want in "comments by others since your last action: 4 request(s) or PR(s), 2 UNKNOWN (comment fetch failed)" \
            "PR other/broken#8 UNKNOWN (comment fetch failed)" \
            "PR builds not read: sr-status.py --pr pool/<pkg>#<n> for pool/tesseract-ocr#4"; do
  grep -qF -- "$want" <<<"$LAST" && pass "summary-pr-comments: $want" || fail "summary-pr-comments: missing '$want'"
done
! grep -qE 'other/handled|legal ok|Build successful|represents a group' <<<"$LAST" && ! grep -q 'pool/tesseract-ocr/issues/4/comments' <<<"$CALLS" \
  && pass "summary-pr-comments: handled, bot and comment-less PRs stay out" || fail "summary-pr-comments: $LAST"
# The count includes reviews, which the issue comments call does not return:
# when it is short, the reviews are read too. A change request is to answer;
# an approval ("merge ok", APPROVED) is listed apart. A failed reviews call
# is UNKNOWN.
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
pr_review_fixtures() { # <fixture tree>
  local G=$1/gitea/repos
  pr_comments_fixtures "$1"
  python3 - "$G/issues/search_type_pulls_created_true_state_open_limit_50" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for n, repo, count in ((9, "other/reviewed", 3), (10, "other/approved", 1), (11, "other/merge-ok", 1), (12, "other/rv-broken", 2)):
    d.append({"number": n, "state": "open", "comments": count, "user": {"login": "me"},
              "created_at": "2026-10-10T08:00:00+02:00", "repository": {"full_name": repo}})
json.dump(d, open(p, "w"))
EOF
  mkdir -p "$G/other/reviewed/issues/9" "$G/other/reviewed/pulls/9" "$G/other/approved/issues/10" "$G/other/approved/pulls/10" \
    "$G/other/merge-ok/issues/11" "$G/other/rv-broken/issues/12" "$G/other/rv-broken/pulls/12"
  echo '[{"user": {"login": "autogits_obs_staging_bot"}, "body": "Build failed", "created_at": "2026-10-19T08:00:00Z"}]' > "$G/other/reviewed/issues/9/comments"
  echo '[{"user": {"login": "mcepl"}, "state": "REQUEST_CHANGES", "body": "FTBFS", "comments_count": 2, "submitted_at": "2026-10-19T09:00:00Z"},
   {"user": {"login": "me"}, "state": "COMMENT", "body": "", "comments_count": 0, "submitted_at": "2026-10-12T09:00:00Z"}]' > "$G/other/reviewed/pulls/9/reviews"
  echo '[]' > "$G/other/approved/issues/10/comments"
  echo '[{"user": {"login": "oertel"}, "state": "APPROVED", "body": "", "comments_count": 0, "submitted_at": "2026-10-19T09:00:00Z"}]' > "$G/other/approved/pulls/10/reviews"
  echo '[{"user": {"login": "maint"}, "body": "merge ok", "created_at": "2026-10-19T09:00:00Z"}]' > "$G/other/merge-ok/issues/11/comments"
  echo '[]' > "$G/other/rv-broken/issues/12/comments"
  echo @NET > "$G/other/rv-broken/pulls/12/reviews"
}
case_ summary-pr-reviews 0 'PR other/reviewed#9 mcepl 2026-10-19 [change request, +2 inline]: "FTBFS"' \
  "summary_fixtures \$B && pr_review_fixtures \$B" --summary
for want in "comments by others since your last action: 5 request(s) or PR(s), 3 UNKNOWN (comment fetch failed)" \
            "approved since your last action: PR other/approved#10 by oertel, PR other/merge-ok#11 by maint" \
            "PR other/rv-broken#12 UNKNOWN (comment fetch failed)"; do
  grep -qF -- "$want" <<<"$LAST" && pass "summary-pr-reviews: $want" || fail "summary-pr-reviews: missing '$want'"
done
! grep -qE 'PR other/(approved|merge-ok)#1[01] (oertel|maint)' <<<"$LAST" && ! grep -q 'somegroup/example/pulls/2/reviews' <<<"$CALLS" \
  && pass "summary-pr-reviews: approvals are not questions; no reviews call when the count is met" || fail "summary-pr-reviews: $LAST"
# Under --deadline the PRs come first (few, and the end of the queue is what
# gets cut): the skipped list keeps that order.
case_ summary-deadline-prs-first 0 "not fetched (--deadline reached; raise it, or ask by id): PR somegroup/example#2, PR other/handled#6" \
  "summary_fixtures \$B && pr_comments_fixtures \$B" --summary --deadline 0
# The table past the deadline: a decline still shows its reason (no call
# needed), the rest say they were not fetched — never the bare sentinel.
case_ table-deadline 0 '| SR | 1 | pkg1 | openSUSE:Factory | ❌ declined | — | 💬 a-reviewer: "old decline" |' \
  "many 3 > \$(spath \"\$Q_OPEN\")" --no-prs --deadline 0
grep -qF '| (not fetched: --deadline reached) |' <<<"$LAST" && ! grep -qE '\| deadline \|' <<<"$LAST" \
  && pass "table-deadline: the others say they were not fetched" || fail "table-deadline: $LAST"
case_ deadline-negative 2 "--deadline takes 0 or more seconds" ":" --deadline -1
# A call's timeout is cut to the time left before the deadline (at least 5 s):
# a call started at 79 s must not run to 140 s.
case_ deadline-caps-call-timeout 2 "geectl timed out after 5s" "put \$(spath \"\$Q_OPEN\") @HANG" --summary --no-prs --deadline 0
# A long queue must still print: past --deadline no lookup starts, and the
# rest is UNKNOWN, never "nothing".
case_ summary-deadline 0 "not fetched (--deadline reached; raise it, or ask by id): SR 201 alpha, SR 202 beta" \
  "summary_fixtures \$B" --summary --no-prs --deadline 0
grep -qF "later requests UNKNOWN (not looked up: --deadline reached)" <<<"$LAST" \
  && grep -qF ", 7 UNKNOWN (not fetched: --deadline reached)" <<<"$LAST" && ! grep -q '/comments/request' <<<"$CALLS" \
  && pass "summary-deadline: nothing fetched, every item UNKNOWN" || fail "summary-deadline: $LAST"
# --summary is never capped: a cap would read 10 of 45 as the whole queue.
case_ summary-refuses-limit 2 "--summary is never capped: drop --limit" ":" --summary --limit 10
case_ summary-uncapped 0 "OBS submit requests: 45 (new 44 · declined 1)" "many 45 > \$(spath \"\$Q_OPEN\")" --summary --no-prs

# ---------------------------------------------------------------- stale requests
# geectl request file pins the source revision it was filed from: a fix committed to the
# branch afterwards reaches nobody until it is filed again, yet three
# such requests were reported as "intact". An open request whose source holds
# other files than its pinned revision is STALE; equal files at another
# revision (a link whose base moved, an scmsync package's obsinfo) are not. The
# pinned rev is compared with the current one first: one call when it is
# unchanged.
H=home  # spelled apart: no literal home project in a public file
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
rreq() { # <id> <package> <source project> <rev> [state] [target]
  printf '{\"id\": %s, \"creator\": \"tester\", \"title\": \"\", \"description\": \"\", \"actions\": [{\"type\": \"submit\", \"source_project\": \"%s\", \"source_package\": \"%s\", \"source_rev\": \"%s\", \"target_project\": \"%s\", \"target_package\": \"%s\"}], \"state\": {\"name\": \"%s\", \"who\": \"tester\", \"when\": \"2026-10-20T10:00:00\", \"created\": \"2026-10-20T10:00:00\"}, \"reviews\": [], \"history\": []}' \
    "$1" "$3" "$2" "$4" "${6:-openSUSE:Factory}" "$2" "${5:-new}"
}
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
_lst() { # <fixture tree> <prj> <pkg> <rev> <srcmd5> <suffix> <name md5 ...>
  local B=$1 prj=$2 pkg=$3 rev=$4 src=$5 suf=$6; shift 6
  local files=""; while [ $# -ge 2 ]; do [ -n "$files" ] && files="$files, "; files="$files{\"name\": \"$1\", \"size\": 1, \"mtime\": 1, \"md5\": \"$2\"}"; shift 2; done
  local k=$(printf %s "$prj" | tr '/' '_')_$(printf %s "$pkg" | tr '/' '_')$suf
  local revj="$rev"; case $rev in *[!0-9]*) revj="\"$rev\"";; esac
  put "$B/list-$k" "{\"project\": \"$prj\", \"package\": \"$pkg\", \"files\": [$files]}"
  put "$B/log-$k" "{\"project\": \"$prj\", \"package\": \"$pkg\", \"entries\": [{\"rev\": $revj, \"srcmd5\": \"$src\", \"time\": \"2026-10-20T10:00:00\", \"user\": \"tester\", \"comment\": \"\"}]}"
}
lst() { # <fixture tree> <prj> <pkg> <rev> <srcmd5> <name md5 ...>
  _lst "$1" "$2" "$3" "$4" "$5" "" "${@:6}"
}
lstrev() { # <fixture tree> <prj> <pkg> <rev> <srcmd5> <name md5 ...>
  _lst "$1" "$2" "$3" "$4" "$5" "_rev_$4" "${@:6}"
}
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
stale_fixtures() { # <fixture tree>
  local d=devel:example
  { printf '{\"requests\": ['
    rreq 301 foo "$d" 3; printf ', '                 # a later revision changed the files: stale
    rreq 302 bar "$d" 7 review; printf ', '          # still at revision 7
    rreq 303 baz "$d" 8; printf ', '                 # a link: its base moved, the files did not
    rreq 304 qux "$d" 3; printf ', '                 # scmsync: only the obsinfo's branch changed
    printf '{\"id\": 305, \"creator\": \"tester\", \"title\": \"\", \"description\": \"\", \"actions\": [{\"type\": \"submit\", \"source_project\": \"%s\", \"source_package\": \"m1\", \"source_rev\": \"1\", \"target_project\": \"openSUSE:Factory\", \"target_package\": \"m1\"}, {\"type\": \"submit\", \"source_project\": \"%s\", \"source_package\": \"m2\", \"source_rev\": \"1\", \"target_project\": \"openSUSE:Factory\", \"target_package\": \"m2\"}], \"state\": {\"name\": \"new\", \"who\": \"tester\", \"when\": \"2026-10-20T10:00:00\", \"created\": \"2026-10-20T10:00:00\"}, \"reviews\": [], \"history\": []}' "$d" "$d"; printf ', '
    rreq 306 quux "$d" u5; printf ', '               # pinned by srcmd5, still current
    rreq 307 svc "$d" sx; printf ', '                # a server-side _service: pinned by its result's srcmd5
    rreq 308 svc2 "$d" 2                # a _service, one revision back, same expanded files
    printf ']}'; } > "$(spath_for "$1" "$Q_OPEN")"
  lst "$1" "$d" foo 5 f5 x.spec m5; lstrev "$1" "$d" foo 3 f3 x.spec m3
  lst "$1" "$d" bar 7 b7 x.spec n7
  # a link's own listing holds only _link; the target's listing holds the files
  lst "$1" "$d" baz 9 z9 _link l1
  put "$1/cat-$(printf %s "$d" | tr '/' '_')_baz__link" '<link project="devel:base" package="baz"/>'
  lst "$1" devel:base baz 9 x9 x.spec k1; lstrev "$1" devel:base baz 8 x8 x.spec k1
  lstrev "$1" "$d" baz 8 z8 _link l1
  lst "$1" "$d" qux 4 q4 x.spec s1 _scmsync.obsinfo branch-factory
  lstrev "$1" "$d" qux 3 q3 x.spec s1 _scmsync.obsinfo branch-main
  lst "$1" "$d" quux 5 u5 x.spec w5
  # list-files never expands services: the pinned and current listings are
  # both the unexpanded file sets
  lst "$1" "$d" svc 4 v4 x.spec c1; lstrev "$1" "$d" svc sx v4 x.spec c1
  lst "$1" "$d" svc2 3 w3 x.spec c2; lstrev "$1" "$d" svc2 2 w2 x.spec c2
}
STALE1='STALE — source changed after the pinned revision: run forward-check.py devel:example/foo before any refile'
case_ table-stale 0 "| SR | 301 | foo | openSUSE:Factory | ⏳ new; $STALE1 |" "stale_fixtures \$B" --no-prs
rows=$(grep '^| SR ' <<<"$LAST")
[ "$(head -1 <<<"$rows" | cut -d'|' -f3)" = " 301 " ] && pass "table-stale: a stale request sorts first" || fail "table-stale: order: $rows"
! grep -qE '\| (302|303|304|306|307|308) \|.*STALE' <<<"$rows" && pass "table-stale: current, relinked, scmsync, srcmd5-, service-pinned requests are not stale" \
  || fail "table-stale: $rows"
grep -qF '| SR | 305 | m1 | openSUSE:Factory | ⏳ new; STALE not checked (2 actions) |' <<<"$rows" \
  && pass "table-stale: a multi-action request is not checked" || fail "table-stale: 305: $rows"
! grep -qE '^geectl remote list-files devel:example (bar|quux) --rev' <<<"$CALLS" \
  && pass "table-stale: an unchanged rev takes one call" || fail "table-stale: $CALLS"
case_ table-stale-home 0 "STALE — source changed after the pinned revision: the refile has no geectl path yet: geectl cannot file a request targeting openSUSE:Factory — report the request as ready to forward and stop |" \
  "stale_fixtures \$B && sed -i 's|\"source_project\": \"devel:example\", \"source_package\": \"foo\"|\"source_project\": \"$H:tester:spark\", \"source_package\": \"foo\"| ' \$(spath \"\$Q_OPEN\") &&
   lst \$B $H:tester:spark foo 5 f5 x.spec m5 && lstrev \$B $H:tester:spark foo 3 f3 x.spec m3" --no-prs
# A non-Factory target still gets the refile command. The second sed retargets
# only the first request (301): no /g, so the other rows keep Factory.
case_ table-stale-home-leap 0 "STALE — source changed after the pinned revision: geectl request refile --source-project $H:tester:spark --source-package foo --target-project openSUSE:Leap:16.0 --target-package foo --description MSG --changes-entry MSG --supersede 301 --live |" \
  "stale_fixtures \$B && sed -i 's|\"source_project\": \"devel:example\", \"source_package\": \"foo\"|\"source_project\": \"$H:tester:spark\", \"source_package\": \"foo\"| ' \$(spath \"$Q_OPEN\") && sed -i 's|\"target_project\": \"openSUSE:Factory\"|\"target_project\": \"openSUSE:Leap:16.0\"|' \$(spath \"$Q_OPEN\") &&
   lst \$B $H:tester:spark foo 5 f5 x.spec m5 && lstrev \$B $H:tester:spark foo 3 f3 x.spec m3" --no-prs
case_ table-stale-unknown 0 "| SR | 301 | foo | openSUSE:Factory | ⏳ new; STALE UNKNOWN (source lookup failed) |" \
  "stale_fixtures \$B && echo @NET > \$B/list-devel:example_foo" --no-prs
case_ table-stale-pinned-unknown 0 "STALE UNKNOWN (pinned revision lookup failed)" \
  "stale_fixtures \$B && rm \$B/list-devel:example_foo_rev_3" --no-prs
case_ table-source-gone 0 "| SR | 301 | foo | openSUSE:Factory | ⏳ new; source gone: devel:example/foo |" \
  "stale_fixtures \$B && rm \$B/list-devel:example_foo" --no-prs
case_ table-stale-deadline 0 "⏳ new; STALE not checked (--deadline reached)" "stale_fixtures \$B" --no-prs --deadline 0
case_ brief-not-checked 0 "SR 301  [new" "stale_fixtures \$B" --brief --no-prs
! grep -qE 'remote (list-files|package-log)' <<<"$CALLS" && ! grep -q STALE <<<"$LAST" && pass "brief-not-checked: --brief makes no source call" \
  || fail "brief-not-checked: $CALLS"
case_ summary-stale 0 "stale (1): source changed after the revision the request pins — refile:" \
  "stale_fixtures \$B" --summary --no-prs
grep -qF "  SR 301 foo -> openSUSE:Factory: run forward-check.py devel:example/foo before any refile" <<<"$LAST" \
  && grep -qF "  SR 305 m1 -> openSUSE:Factory: STALE not checked (2 actions)" <<<"$LAST" \
  && ! grep -qE '  SR 30[234678] [a-z0-9]+ -> openSUSE:Factory: ' <<<"$LAST" && pass "summary-stale: the stale one and the unchecked one, nothing else" || fail "summary-stale: $LAST"
case_ summary-stale-none 0 "stale (0): source changed after the revision the request pins" \
  "stale_fixtures \$B && lstrev \$B devel:example foo 3 f3 x.spec m5" --summary --no-prs
case_ summary-stale-deadline 0 "  not checked (--deadline reached): SR 301 foo, SR 302 bar, SR 303 baz, SR 304 qux, SR 305 m1, SR 306 quux, SR 307 svc, SR 308 svc2" \
  "stale_fixtures \$B" --summary --no-prs --deadline 0

# --summary --days: "no SR of mine was ever filed" was said of a request that
# had been accepted: the open list cannot answer it. Closed ones are listed
# per target (accepted, superseded) or with their reason (revoked).
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
creq() { # <id> <package> <target> <state> [who] [comment] [superseded_by]
  local sup=""; [ -n "${7:-}" ] && sup=", \"superseded_by\": $7"
  local cmt=""; [ -n "${6:-}" ] && cmt=", \"comment\": \"$6\""
  printf '{\"id\": %s, \"creator\": \"tester\", \"title\": \"\", \"description\": \"\", \"actions\": [{\"type\": \"submit\", \"source_project\": \"devel:example\", \"source_package\": \"%s\", \"target_project\": \"%s\", \"target_package\": \"%s\"}], \"state\": {\"name\": \"%s\", \"who\": \"%s\", \"when\": \"%s\"%s%s}, \"reviews\": [], \"history\": []}' \
    "$1" "$2" "$3" "$2" "$4" "${5:-tester}" "$(date -u +%FT%T)" "$sup" "$cmt"
}
# shellcheck disable=SC2317,SC2329  # called from case mutations, through eval
closed_fixtures() { # <fixture tree>
  local body; body=$( { printf '{\"requests\": ['
    creq 1392106 hidapi hardware accepted maint; printf ', '
    creq 1392121 libwacom hardware accepted maint; printf ', '
    creq 1392209 dlib openSUSE:Factory revoked tester 'forwarder is not package maintainer'; printf ', '
    creq 1386578 mariadb server:database superseded tester 'Update mariadb to 13.0.2' 1386595; printf ', '
    creq 1386600 zstd openSUSE:Factory superseded maint 'refreshed by the maintainer' 1386650
    printf ']}'; } )
  printf '%s\n' "$body" > "$(spath_for "$1" "$(closed_q "$SINCE")")"
  printf '%s\n' "$body" > "$(spath_for "$1" "$(closed_q "$SINCE3")")"
}
case_ summary-closed 0 "closed in the last 14 days (since $SINCE): 5 — accepted 2 · revoked 1 · superseded 2" \
  "closed_fixtures \$B" --summary --no-prs
# Your own refile carries your new description as its reason: counted, not
# listed. Someone else superseding yours is news.
for want in "  hardware: accepted 2" "  openSUSE:Factory: revoked 1 · superseded 1" "  server:database: superseded 1" \
            '  revoked: SR 1392209 dlib -> openSUSE:Factory (tester): "forwarder is not package maintainer"' \
            "  superseded by your own refile: 1" \
            '  superseded: SR 1386600 zstd -> openSUSE:Factory by #1386650 (maint): "refreshed by the maintainer"'; do
  grep -qF -- "$want" <<<"$LAST" && pass "summary-closed: $want" || fail "summary-closed: missing '$want'"
done
! grep -qE 'hidapi|libwacom|SR 1386578' <<<"$LAST" && pass "summary-closed: accepted requests and your own refiles are counted, not listed" \
  || fail "summary-closed: accepted rows listed: $LAST"
grep -qF -- "--since $SINCE" <<<"$CALLS" && grep -qF -- "--creator tester" <<<"$CALLS" \
  && pass "summary-closed: one search for your requests closed since then" || fail "summary-closed: $CALLS"
case_ summary-closed-none 0 "closed in the last 14 days (since $SINCE): 0" ":" --summary --no-prs
case_ summary-closed-failed 0 "closed in the last 14 days (since $SINCE): UNKNOWN (lookup failed)" \
  "echo @NET > \$(closed_fix)" --summary --no-prs
case_ summary-closed-deadline 0 "closed in the last 14 days (since $SINCE): UNKNOWN (not looked up: --deadline reached)" \
  "closed_fixtures \$B" --summary --no-prs --deadline 0
case_ summary-days 0 "closed in the last 3 days (since $SINCE3): 5" \
  "closed_fixtures \$B" --summary --no-prs --days 3
case_ days-without-summary 2 "--days N (1 or more) goes with --summary" ":" --days 3
case_ days-zero 2 "--days N (1 or more) goes with --summary" ":" --summary --days 0

echo "---"; [ "$fails" = 0 ] && echo "all sr-status checks passed" || echo "$fails FAILED"
exit $((fails > 0))
