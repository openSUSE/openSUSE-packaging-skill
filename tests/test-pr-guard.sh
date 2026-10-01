#!/bin/bash
# test-pr-guard.sh — proves scripts/pr-guard.py refuses each way an agent has
# opened, moved or merged a pool PR, forged a gate stamp or built emulated, and
# lets the look-alikes through -- above all text a command only carries (a
# commit message, a grep pattern, an echo), which is not a command. The events live in tests/fixtures/pr-guard/
# events.json, with the commands verbatim from real agent runs where one exists
# (account names replaced), so this file carries none of the text the guard
# refuses and stays runnable under the installed guard -- a case below checks
# that. Offline: the open-PR lookup reads fixture files, git runs on scratch
# clones. Each refusal must name the rule that fired. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
GUARD=$REPO/skills/opensuse-packaging/scripts/pr-guard.py
PLUGINS="$REPO/contrib/harness/opencode/pool-pr-guard.ts $REPO/contrib/harness/opencode-v2/pool-pr-guard.ts"
PERMS=$REPO/contrib/harness/opencode/opencode.jsonc
FX=$HERE/fixtures/pr-guard
fails=0; used=" "
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d /var/tmp/test-pr-guard.XXXXXX)"; trap 'rm -rf "$work"' EXIT

# Nothing from the machine running the suite: no git config, no skill checkout,
# no network, and an aarch64 host whatever the runner is.
export HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export PR_GUARD_ARCH=aarch64 PR_GUARD_PULLS_DIR="$work/prs"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset PR_GUARD_SKILL_DIR
mkdir -p "$HOME" "$work/plain" "$work/scripts"
cp -r "$FX/prs" "$work/prs"
python3 -c 'import json, sys
prs = [{"number": n, "head": {"ref": "b%d" % n, "repo": {"owner": {"login": "x"}}}} for n in range(50)]
json.dump(prs, open(sys.argv[1], "w"))' "$work/prs/many-prs.json"

# clone_ <dir> <branch> <remote>=<url>...
clone_() {
  local d=$1 b=$2 r; shift 2
  git init -q -b "$b" "$d" && git -C "$d" commit -q --allow-empty -m init || return 1
  for r in "$@"; do git -C "$d" remote add "${r%%=*}" "${r#*=}"; done
}
F=https://src.opensuse.org
clone_ "$work/clone" leap-16.0 origin=$F/pool/tesseract-ocr.git fork=$F/someone/tesseract-ocr.git
git -C "$work/clone" branch tess-88053-16.0
clone_ "$work/track" tess-88053-16.0 origin=$F/pool/tesseract-ocr.git fork=$F/someone/tesseract-ocr.git
git -C "$work/track" config branch.tess-88053-16.0.pushRemote fork
clone_ "$work/other" factory origin=$F/AI/other-pkg.git fork=$F/someone/other-pkg.git
clone_ "$work/devel" factory origin=$F/javascript/js-pkg.git fork=$F/someone/js-pkg.git
clone_ "$work/broken" leap-16.0 fork=$F/someone/broken-pkg.git
clone_ "$work/many" leap-16.0 fork=$F/someone/many-prs.git
clone_ "$work/odd" leap-16.0 fork=$F/someone/odd-pkg.git
clone_ "$work/github" main origin=https://github.com/example/tool.git
clone_ "$work/stranger" leap-16.0 fork=$F/stranger/tesseract-ocr.git
# A local branch that pushes to a differently named remote branch.
clone_ "$work/mapped" wip-tess fork=$F/someone/tesseract-ocr.git
git -C "$work/mapped" config branch.wip-tess.remote fork
git -C "$work/mapped" config branch.wip-tess.merge refs/heads/tess-88053-16.0
git -C "$work/mapped" config push.default upstream
clone_ "$work/refspec" leap-16.0 fork=$F/someone/tesseract-ocr.git
git -C "$work/refspec" config remote.fork.push 'refs/heads/*:refs/heads/*'
# On the PR branch with no push config (a bare push goes to origin), and with remote.pushDefault.
clone_ "$work/onpr" tess-88053-16.0 origin=$F/pool/tesseract-ocr.git fork=$F/someone/tesseract-ocr.git
clone_ "$work/pdef" tess-88053-16.0 origin=$F/pool/tesseract-ocr.git fork=$F/someone/tesseract-ocr.git
git -C "$work/pdef" config remote.pushDefault fork
# A remote URL that carries a token, which no refusal may print.
clone_ "$work/tokened" leap-16.0 "origin=https://user:tok3n@${F#https://}/pool/x.git"

# A skill checkout whose pool-pr.sh stand-in, a target-gate.sh it would run and
# another script are committed and merged (origin/main, the pinned ref);
# new-tool.sh is not committed.
S=$work/skill
mkdir -p "$S/scripts" && cp "$FX/pool-pr.sh" "$FX/open-pr.sh" "$S/scripts/"
# A changes-prepend.sh that is refused if read: allowed, it ran unread.
cp "$FX/pool-pr.sh" "$S/scripts/changes-prepend.sh"
printf '#!/bin/bash\necho "gate $*"\n' > "$S/scripts/target-gate.sh"
git init -q -b main "$S" && git -C "$S" add -A && git -C "$S" commit -q -m init
git -C "$S" update-ref refs/remotes/origin/main HEAD
cp "$FX/pool-pr.sh" "$S/scripts/new-tool.sh"
cp "$S/scripts/target-gate.sh" "$work/pinned-gate.sh"; cp "$S/scripts/pool-pr.sh" "$work/pinned-pool-pr.sh"
W=$work/scripts
{ cat "$FX/pool-pr.sh"; echo 'echo pushed'; } > "$W/pool-pr-copy.sh"
# The canonical script, byte-identical and same-named but outside the checkout; and linked to.
mkdir -p "$W/elsewhere" && cp "$S/scripts/pool-pr.sh" "$W/elsewhere/"; ln -s "$S/scripts/pool-pr.sh" "$W/pool-pr-link.sh"
cp "$FX/open-pr.sh" "$FX/open_pr.py" "$FX/open-pr.js" "$FX/open-pr.pl" "$FX/agit.sh" "$FX/land.sh" "$FX/quoting.sh" "$FX/stamp.py" "$FX/kpi.py" "$W/"
cp "$FX/scrape-token.sh" "$FX/obs-api.sh" "$W/"
# Stand-in credential files under the suite's HOME, and a link to one; their
# names live in a fixture, since the guard reads this suite.
python3 -c 'import json, os, sys
spec = json.load(open(sys.argv[1]))
for rel in spec["files"]:
    path = os.path.join(sys.argv[2], rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write("fake\n")
for name, rel in spec["links"].items():
    os.symlink(os.path.join(sys.argv[2], rel), os.path.join(sys.argv[3], name))' "$FX/creds.json" "$HOME" "$W"
# The real pool-pr.sh without its gate call and its pushes: the PR write alone,
# with method, body and URL all held in variables.
grep -v -e 'target-gate\.sh' -e ' push ' "$REPO/skills/opensuse-packaging/scripts/pool-pr.sh" > "$W/pp-nogate.sh"
# The same quoting script read as shell by its shebang alone, and by its .sh alone.
cp "$FX/quoting.sh" "$W/quoting"; tail -n +2 "$FX/quoting.sh" > "$W/quoting-plain.sh"
# A binary is not read as text, whatever strings it carries.
{ printf '\177ELF\n'; cat "$FX/open_pr.py"; } > "$W/tool"
chmod +x "$W/open-pr.sh"
printf '#!/bin/bash\nbash %s/open-pr.sh\n' "$W" > "$W/outer.sh"
# Harmless now; the calls that run them rewrite them first.
printf 'echo hello\n' > "$W/iter.sh"; printf 'print("hello")\n' > "$W/iter.py"
# A short long.txt where a message substitution that changes directory must not look.
printf 'Short.\n' > "$W/long.txt"
# A FIFO blocks whoever opens it until a writer comes: never opened by the guard.
mkfifo "$W/fifo"
# The harmless scripts of a sweep loop, 64 of them.
mkdir -p "$W/sweep" && for i in $(seq -w 1 64); do printf 'echo %s\n' "$i" > "$W/sweep/p$i.sh"; done
# A local script named like the gate, which copies its arguments.
cp "$FX/fake-gate.sh" "$W/target-gate.sh"; chmod +x "$W/target-gate.sh"
# A worktree named like the stamp directory, which is no git directory (spelled
# in pieces: the guard reads this suite), and a git directory not named .git.
g=gate; mkdir -p "$W/wt/target-$g"
git init -q --bare "$work/barerepo"
# osc checkouts: .osc/_project names the project a commit lands in. The home
# projects are spelled in pieces: check-skills.py reads this suite.
osc_co_() { mkdir -p "$1/.osc" && printf '%s\n' "$2" > "$1/.osc/_project"; }
h=home
osc_co_ "$work/osc/upd/x" openSUSE:Backports:SLE-15-SP7:Update
osc_co_ "$work/osc/incident/x" openSUSE:Maintenance:12345
osc_co_ "$work/osc/$h:tester:branches:OBS_Maintained:x/x.openSUSE_Backports_SLE-15-SP7_Update" "$h:tester:branches:OBS_Maintained:x"
osc_co_ "$work/osc/branch/x" "$h:tester:branches:openSUSE:Backports:SLE-15-SP7:Update"
osc_co_ "$work/osc/devel/x" devel:tools

# ev <name>: the fixture event, placeholders filled in.
ev() {
  python3 -c 'import json, sys
text = json.dumps(json.load(open(sys.argv[2]))[sys.argv[1]])
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1)
    text = text.replace("@%s@" % k, v)
print(text)' "$1" "$FX/events.json" CLONE="$work/clone" TRACK="$work/track" \
    OTHER="$work/other" BROKEN="$work/broken" MANY="$work/many" ODD="$work/odd" \
    GITHUB="$work/github" STRANGER="$work/stranger" MAPPED="$work/mapped" \
    REFSPEC="$work/refspec" ONPR="$work/onpr" PDEF="$work/pdef" PLAIN="$work/plain" \
    WORK="$W" SKILL="$S" BARE="$work/barerepo" TOKENED="$work/tokened" OSC="$work/osc" \
    DEVEL="$work/devel" MSGS="$FX/messages" HOME="$HOME"
}

# case_ <event> <rc> <rule|-> <detail> [VAR=value ...]
# rc 0: allowed, silently. rc 2: refused, and the message names the rule (and
# the detail) -- a refusal by some other rule proves nothing about this one.
case_() {
  local name=$1 rc=$2 rule=$3 detail=$4 event out got; shift 4
  used="$used$name "
  event="$(ev "$name")" || { fail "$name: no such event"; return; }
  out="$(printf '%s' "$event" | env "$@" python3 "$GUARD" 2>&1)"; got=$?
  if [ "$rc" = 0 ]; then
    [ "$got" = 0 ] && [ -z "$out" ] && pass "$name (allowed)" || {
      fail "$name: expected allowed, got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
    return
  fi
  [ "$got" = "$rc" ] && grep -qF -- "BLOCKED [$rule]" <<<"$out" && grep -qF -- "$detail" <<<"$out" \
    && pass "$name (rc=$rc, $rule)" || {
      fail "$name: expected rc=$rc [$rule] '$detail', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}

echo "--- pushes, judged by where they land"
case_ push-tesseract-rtk        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-url-to-pr-head       2 push-pr-head "pool/tesseract-ocr#4"
case_ push-agit-refs-for        2 push-pool    "naming pool/ or AGit refs"
case_ push-pool-url             2 push-pool    "naming pool/ or AGit refs"
case_ push-pool-remote          2 push-pool    "a push to $F/pool/tesseract-ocr.git"
case_ push-bare-tracking        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-all-branches         2 push-pr-head "pool/tesseract-ocr#3"
case_ push-head-refspec         2 push-pr-head "pool/tesseract-ocr#3"
case_ push-upstream-mapping     2 push-pr-head "pool/tesseract-ocr#3"
case_ push-inline-remote        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-git-C                2 push-pr-head "pool/tesseract-ocr#3"
case_ push-bash-c               2 push-pr-head "pool/tesseract-ocr#3"
case_ push-shell-heredoc        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-substitution         2 push-pr-head "pool/tesseract-ocr#3"
case_ push-cwd-unknown          2 push-unknown "the working directory is unknown"
case_ push-no-such-remote       2 push-unknown "no remote 'fork'"
case_ push-lookup-fails         2 push-unknown "could not list the open PRs of pool/broken-pkg"
case_ push-lookup-too-many      2 push-unknown "50+ open PRs"
case_ push-lookup-not-a-list    2 push-unknown "unexpected open-PR list for pool/odd-pkg"
case_ push-all-outside-clone    2 push-unknown "cannot list the local branches"
case_ push-pool-in-python       2 push-pool    "naming pool/ or AGit refs"
case_ push-in-python            2 push-unknown "inside program text"
case_ push-configured-refspec   2 push-unknown "cannot tell which branch"
case_ push-git-c                2 push-pr-head "pool/tesseract-ocr#3"
case_ push-refs-heads           2 push-pr-head "pool/tesseract-ocr#3"
case_ push-force-refspec        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-push-default         2 push-pr-head "pool/tesseract-ocr#3"
case_ push-bare-origin          2 push-pool    "a push to $F/pool/tesseract-ocr.git"
case_ push-repo-option          2 push-pr-head "pool/tesseract-ocr#3"
case_ push-repo-option-eq       2 push-pr-head "pool/tesseract-ocr#3"
case_ push-pool-ssh             2 push-pool    "naming pool/ or AGit refs"
case_ push-ssh-fork             2 push-pr-head "pool/tesseract-ocr#4"
case_ push-eval                 2 push-pr-head "pool/tesseract-ocr#3"
case_ push-nohup                2 push-pr-head "pool/tesseract-ocr#3"
case_ push-timeout              2 push-pr-head "pool/tesseract-ocr#3"
case_ push-rtk-run              2 push-pr-head "pool/tesseract-ocr#3"
case_ push-rtk-err              2 push-pr-head "pool/tesseract-ocr#3"
case_ push-env-split            2 push-pr-head "pool/tesseract-ocr#3"
case_ push-env-unset            2 push-pr-head "pool/tesseract-ocr#3"
case_ push-wildcard-refspec     2 push-pr-head "pool/tesseract-ocr#3"
case_ push-wildcard-star        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-wildcard-prefix      2 push-pr-head "pool/tesseract-ocr#3"
case_ push-matching-colon       2 push-pr-head "pool/tesseract-ocr#3"
case_ push-matching-default     2 push-pr-head "pool/tesseract-ocr#3"
case_ push-mirror               2 push-pr-head "pool/tesseract-ocr#3"
case_ push-send-pack            2 push-pr-head "pool/tesseract-ocr#3"
case_ push-send-pack-matching   2 push-pr-head "pool/tesseract-ocr#3"
case_ push-send-pack-remote     2 push-pr-head "pool/tesseract-ocr#3"
case_ push-host-case            2 push-pr-head "pool/tesseract-ocr#3"
case_ push-wildcard-outside-clone 2 push-unknown "cannot list the local branches"
case_ push-wildcard-no-pr       0 - ""
case_ push-in-python-github-cwd 2 push-unknown "inside program text"
case_ push-in-python-github-var 2 push-unknown "inside program text"
case_ push-in-python-github     0 - ""
case_ push-in-python-github-string 0 - ""
case_ push-wip                  0 - ""
case_ push-leapgate             0 - ""
case_ push-not-in-pool          0 - ""
case_ push-other-forge          0 - ""
case_ push-same-name-other-fork 0 - ""
case_ push-in-comment           0 - ""
case_ quoted-backticks          0 - ""
case_ stash-push-rtk            0 - ""
case_ stash-push-bash-c         0 - ""
case_ stash-push-naming-pool    0 - ""
# Repairing a PR whose LFS object never reached the forge: upload the objects
# (git lfs push is no git push), then amend and force-push a devel-org or fork
# branch to retrigger the sync. Only a pool PR's head stays refused.
case_ lfs-push-object-id        0 - ""
case_ lfs-push-all              0 - ""
# Read as a push this would be refused: --all takes in a branch that heads pool PR #3.
case_ lfs-push-all-fork-pr-clone 0 - ""
case_ push-force-lease-devel    0 - ""
case_ push-force-lease-fork     0 - ""
case_ push-force-lease-pool-head 2 push-pr-head "pool/js-pkg#7"
echo "--- a refusal prints no credential"
case_ push-token-remote         2 push-pool    "a push to https://user:[REDACTED]@src.opensuse.org/pool/x.git"
case_ push-token-query          2 push-unknown "x.git?access_token=[REDACTED] is named by a variable"
# Whatever a message echoes is redacted, a script path included.
case_ redact-authorization-token 2 exec-unreadable "Authorization: token [REDACTED]"
case_ redact-bearer             2 exec-unreadable "Bearer [REDACTED]"
for name in push-token-remote push-token-query redact-authorization-token redact-bearer; do
  out="$(ev "$name" | python3 "$GUARD" 2>&1)"
  grep -qF tok3n <<<"$out" && fail "$name: the refusal prints the token" || pass "$name: token redacted"
done
echo "--- the hook's cwd: two calls, one call, subshells"
case_ cd-call-1                 0 - ""
case_ cd-call-2                 2 push-pr-head "pool/tesseract-ocr#3"
case_ cd-call-2-elsewhere       0 - ""
case_ cd-same-call              2 push-pr-head "pool/tesseract-ocr#3"
case_ cd-subshell-restores      2 push-pr-head "pool/tesseract-ocr#3"
case_ cd-subshell-contained     0 - ""
case_ push-cd-dash              2 push-unknown "the working directory is unknown"
case_ push-popd                 2 push-unknown "the working directory is unknown"

echo "--- the live open-PR lookup, answered in-process (a dead proxy keeps it offline)"
N=(PYTHONPATH="$FX/net" PR_GUARD_PULLS_DIR= https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9)
case_ push-live-lookup 2 push-pr-head "pool/tesseract-ocr#3" "${N[@]}" NET_STUB="$work/prs"
case_ push-live-lookup 0 - ""                                "${N[@]}" NET_STUB=404
case_ push-live-lookup 2 push-unknown "could not list the open PRs of pool/tesseract-ocr" "${N[@]}" NET_STUB=500

echo "--- merges"
case_ merge-gitoxide            2 merge-tea     "not even their own"
case_ merge-gitoxide-pulls      2 merge-tea     "sr-status.py --pr"
case_ merge-smoke-pool          2 merge-tea     "tea PR merge"
case_ merge-no-repo-pool-clone  2 merge-tea     "tea PR merge"
case_ merge-no-repo-no-clone    2 merge-tea     "tea PR merge"
case_ merge-urllib-pool         2 merge-api     "API merge"
case_ merge-do-payload-only     2 merge-api     "API merge"
case_ merge-git-obs             2 merge-git-obs "git-obs PR merge"
case_ merge-tea-alias-m         2 merge-tea     "tea PR merge"
case_ merge-tea-pull            2 merge-tea     "tea PR merge"
case_ merge-tea-owner-case      2 merge-tea     "tea PR merge"
case_ merge-curl-url            2 merge-api     "API merge"
case_ merge-do-keyword          2 merge-api     "API merge"
case_ merge-api-split-url       2 merge-api     "API merge"
# Any repository's PR, not only pool's: merging one is never an agent's job.
case_ merge-smoke-ai            2 merge-tea     "tea PR merge"
case_ merge-ai-mistral-vibe     2 merge-tea     "tea PR merge"
case_ merge-no-repo-ai-clone    2 merge-tea     "tea PR merge"
case_ merge-git-obs-ai          2 merge-git-obs "git-obs PR merge"
case_ merge-tea-own-fork        2 merge-tea     "tea PR merge"
case_ merge-control-checkout    0 - ""
# tea's subcommand decides, not words further on: a description or comment may quote one.
case_ tea-create-describes-merge 0 - ""
# Program text is searched wider: an argument list may split the words any way.
case_ prog-node-execfilesync-merge 2 merge-tea  "tea PR merge"
case_ prog-node-spawn-create    2 create-tea    "tea PR create"
case_ prog-python-concat-merge  2 merge-tea     "tea PR merge"
case_ write-script-node-merge   2 merge-tea     "a script running a tea PR merge"
case_ tea-comment-quotes-merge  0 - ""
case_ tea-issue-quotes-create   0 - ""
case_ tea-global-option-merge   2 merge-tea     "tea PR merge"
case_ merge-urllib-ai           2 merge-api     "API merge"
case_ merge-web-ai              2 merge-api     "API merge"
case_ merge-curl-ai             2 merge-api     "API merge"
case_ merge-git-obs-api-ai      2 merge-api     "API merge"
case_ merge-git-obs-space-api-ai 2 merge-api    "API merge"
case_ merge-tea-api-ai          2 merge-api     "API merge"
case_ merge-tea-api-pool        2 merge-api     "API merge"
case_ merge-do-payload-ai-clone 2 merge-api     "API merge"
case_ merge-api-control-get-pr  2 api-direct "curl to src.opensuse.org/api"
case_ merge-api-control-tea-get 0 - ""
# A merge URL held in variables this call set is judged by its value.
case_ merge-curl-var-ai         2 merge-api     "API merge"
# A merge URL is a merge unless the call provably only reads: no method but GET or
# HEAD and no body option, in any spelling (attached, clustered, a prefix).
case_ merge-curl-attached-d     2 merge-api     "API merge"
# On pool or an unnamed repository a merge URL is refused however it is read, as on
# main; elsewhere a read is proven only without a config that may add a method or
# body (curl -q first, wget --no-config) or a stdin HTTPie would send.
case_ merge-pool-http-stdin     2 merge-api     "API merge"
case_ merge-pool-xh-stdin       2 merge-api     "API merge"
case_ merge-ai-http-implicit    2 merge-api     "API merge"
case_ merge-ai-curl-no-q        2 merge-api     "API merge"
case_ merge-ai-wget-config      2 merge-api     "API merge"
# A URL is read decoded, with // collapsed and dot segments removed; "do" is any case.
case_ merge-ai-pct-encoded      2 merge-api     "API merge"
case_ merge-ai-dot-segment      2 merge-api     "API merge"
case_ merge-ai-double-slash     2 merge-api     "API merge"
case_ merge-ai-do-lowercase     2 merge-api     "API merge"
case_ merged-check-other-curl-q 0 - ""
case_ merged-check-other-http-get 0 - ""
case_ merged-check-other-http-ignore-stdin 0 - ""
case_ merged-check-other-wget-no-config 0 - ""
case_ merged-check-ai-git-obs   0 - ""
case_ merged-check-other-script-curl-sf 0 - ""
# On src.opensuse.org itself such a read goes through git-obs, not curl or HTTPie.
case_ merged-check-ai-curl-q    2 api-direct "curl to src.opensuse.org/api"
case_ merged-check-ai-http-get  2 api-direct "http to src.opensuse.org/api"
case_ merged-check-ai-http-ignore-stdin 2 api-direct "http to src.opensuse.org/api"
case_ merged-check-ai-wget-no-config 2 api-direct "wget to src.opensuse.org/api"
case_ merged-check-ai-script-curl-sf 2 api-direct "curl to src.opensuse.org/api"
case_ merge-curl-attached-F     2 merge-api     "API merge"
case_ merge-curl-cluster-X      2 merge-api     "API merge"
case_ merge-curl-request-prefix 2 merge-api     "API merge"
case_ merge-wget-post-prefix    2 merge-api     "API merge"
case_ merge-wget-method-prefix  2 merge-api     "API merge"
case_ merge-git-obs-meth-prefix 2 merge-api     "API merge"
case_ merge-git-obs-dat-prefix  2 merge-api     "API merge"
case_ merge-git-obs-space-meth  2 merge-api     "API merge"
case_ merge-tea-api-attached-f  2 merge-api     "API merge"
case_ merge-tea-api-go-method   2 merge-api     "API merge"
case_ merge-python-opener       2 merge-api     "API merge"
case_ merged-check-curl-cluster 2 merge-api "API merge"
case_ merged-check-curl-head 2 merge-api "API merge"
case_ merged-check-git-obs-meth-get 2 merge-api "API merge"
case_ merged-check-tea-api-get 2 merge-api "API merge"
case_ merged-check-wget 2 merge-api "API merge"
case_ merge-tea-api-var-ai      2 merge-api     "API merge"
case_ merge-git-obs-api-var-ai  2 merge-api     "API merge"
case_ merge-git-obs-space-api-var-ai 2 merge-api "API merge"
# A literal GET of /pulls/N/merge only asks whether the PR is merged.
case_ merged-check-curl 2 merge-api "API merge"
case_ merged-check-curl-get 2 merge-api "API merge"
case_ merged-check-tea-api      0 - ""
case_ merged-check-git-obs-api 2 merge-api "API merge"
case_ merged-check-python 2 merge-api "API merge"
case_ merge-in-comment          0 - ""
# An argument list: the repository option and its value are separate strings.
case_ list-tea-merge            2 merge-tea      "tea PR merge"
case_ list-tea-merge-r          2 merge-tea      "tea PR merge"
case_ list-tea-create           2 create-tea     "tea PR create"
case_ list-git-obs-create       2 create-git-obs "PR create towards pool"
case_ list-tea-merge-ai         2 merge-tea      "tea PR merge"
case_ list-tea-create-ai        0 - ""
# A Python string prefix, and {placeholders}: the literal owner before the slash decides.
case_ list-tea-create-fstring   2 create-tea     "tea PR create"
case_ list-tea-merge-fstring    2 merge-tea      "tea PR merge"
case_ list-git-obs-merge-fstring 2 merge-git-obs "git-obs PR merge"
case_ list-git-obs-merge-owner-placeholder 2 merge-git-obs "git-obs PR merge"
case_ list-tea-merge-fstring-ai 2 merge-tea      "tea PR merge"
case_ list-tea-create-fstring-ai 0 - ""

echo "--- text a command only carries is not a command"
case_ carried-echo-merge          0 - ""
case_ carried-commit-osc-build    0 - ""
case_ carried-log-grep-backports  0 - ""
case_ carried-grep-merge          0 - ""
case_ carried-commit-heredoc      0 - ""
case_ carried-commit-subst-heredoc 0 - ""
case_ carried-perl-pe             0 - ""
case_ carried-perl-ne             0 - ""
case_ carried-perl-i-pe           0 - ""
case_ carried-perl-lane           0 - ""
case_ carried-python-Im           0 - ""
case_ carried-node-pe             0 - ""
case_ carried-then-merge          2 merge-tea "tea PR merge"
case_ carried-perl-e-merge        2 merge-tea "tea PR merge"
case_ carried-if-merge            2 merge-tea "tea PR merge"
case_ carried-xargs-merge         2 merge-tea "tea PR merge"
case_ parse-case-patterns         0 - ""
case_ parse-arithmetic            0 - ""
case_ parse-bash-n                0 - ""
case_ parse-case-clause           2 merge-tea "tea PR merge"
case_ parse-array-literal         0 - ""
case_ parse-array-then-subshell   2 push-pr-head "pool/tesseract-ocr#3"
case_ parse-quoted-heredoc        2 push-pr-head "pool/tesseract-ocr#3"
case_ parse-quoted-then-heredoc   2 push-pr-head "pool/tesseract-ocr#3"

echo "--- text fed to a shell or interpreter is a program"
case_ fed-cat-heredoc-bash        2 push-pr-head "pool/tesseract-ocr#3"
case_ fed-here-string             2 push-pr-head "pool/tesseract-ocr#3"
case_ fed-echo-sh                 2 push-pr-head "pool/tesseract-ocr#3"
case_ fed-printf-bash             2 push-pr-head "pool/tesseract-ocr#3"
case_ fed-heredoc-expands         2 push-pr-head "pool/tesseract-ocr#3"
case_ fed-python-file             2 create-api "a write to pool pulls"
case_ fed-bash-s-file             2 create-api "a write to pool pulls"
case_ fed-cat-file-bash           2 create-api "a write to pool pulls"
case_ fed-stderr-redirect         2 create-api "a write to pool pulls"
case_ fed-unknown-pipe            2 exec-unreadable "the program sh reads from curl"
case_ fed-process-substitution    2 exec-unreadable "/dev/fd/63"
case_ fed-python-stdin-read       0 - ""

echo "--- tea and git-obs act on the clone a cd, subshell or env -C leaves"
case_ cwd-tea-merge               2 merge-tea      "tea PR merge"
case_ cwd-git-obs-merge           2 merge-git-obs  "git-obs PR merge"
case_ cwd-subshell-tea-create     2 create-tea     "tea PR create"
case_ cwd-variable-tea-merge      2 merge-tea      "tea PR merge"
case_ cwd-env-C-tea-merge         2 merge-tea      "tea PR merge"
case_ cwd-remote-added            2 merge-tea      "tea PR merge"
case_ cwd-away-from-pool          2 merge-tea      "tea PR merge"
case_ cwd-away-from-pool-create   0 - ""

echo "--- what a variable holds is unknown"
case_ var-push-loop               2 push-unknown "the pushed branch is held in a variable"
case_ var-push-branch             2 push-unknown "the pushed branch is held in a variable"
case_ var-push-url-owner          2 push-unknown "is named by a variable"
case_ var-tea-repo                2 merge-tea     "tea PR merge"
case_ var-git-obs-id              2 merge-git-obs "git-obs PR merge"
case_ var-curl-url                2 create-api    "a write to pool pulls"
case_ var-command-name            2 merge-tea     "tea PR merge"
case_ var-pr-number-ai            2 merge-tea     "tea PR merge"

echo "--- git obs, as git runs it"
case_ gitobs-space-merge          2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-create         2 create-git-obs "PR create towards pool"
case_ gitobs-space-forward        2 create-git-obs "PR forward on pool"
case_ gitobs-space-no-slash       2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-C              2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-python         2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-ai             2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-create-ai      0 - ""

echo "--- creates"
case_ create-tesseract          2 create-tea       "pool-pr.sh DIR"
case_ create-python-heredoc     2 create-api       "pool-pr.sh DIR"
case_ create-curl-heredoc       2 create-api       "a write to pool pulls"
case_ create-curl-short-body    2 create-api       "a write to pool pulls"
case_ create-tea-api            2 create-tea-api   "tea api write"
case_ create-api-variable-owner 2 create-api       "a write to pool pulls"
case_ create-git-obs-untargeted 2 create-git-obs   "PR create towards pool"
case_ create-git-obs-forward    2 create-git-obs   "PR forward on pool"
case_ create-tea-alias-c        2 create-tea       "pool-pr.sh DIR"
case_ create-tea-api-field      2 create-tea-api   "tea api write"
case_ create-tea-api-method     2 create-tea-api   "tea api write"
case_ create-curl-update-branch 2 create-api       "a write to pool pulls"
case_ create-curl-data          2 create-api       "a write to pool pulls"
case_ create-python-argv        2 create-api       "a write to pool pulls"
case_ create-python-requests    2 create-api       "a write to pool pulls"
case_ create-ai-mistral-vibe    0 - ""
case_ create-git-obs-ai         0 - ""
case_ create-git-obs-target-owner-ai 0 - ""
case_ create-tea-api-ai         0 - ""
case_ get-tea-list              0 - ""
case_ get-tea-api               0 - ""
# Past the pool rules, curl on the Gitea API and a token header are refused.
case_ create-curl-short-ai      2 api-direct  "curl to src.opensuse.org/api"
case_ get-curl-pulls            2 api-direct  "curl to src.opensuse.org/api"
case_ post-fork                 2 auth-header "curl with a credential header (Authorization)"
case_ post-lfs-batch            2 auth-header "curl with a credential header (Authorization)"

echo "--- any request to pool pulls but a literal GET is a write"
case_ write-curl-method-var     2 create-api "a write to pool pulls"
case_ write-curl-form           2 create-api "a write to pool pulls"
case_ write-curl-upload         2 create-api "a write to pool pulls"
case_ write-curl-json           2 create-api "a write to pool pulls"
case_ write-urllib-positional   2 create-api "a write to pool pulls"
case_ write-requests-request    2 create-api "a write to pool pulls"
case_ write-requests-method-var 2 create-api "a write to pool pulls"
case_ write-httpx               2 create-api "a write to pool pulls"
case_ write-http-client         2 create-api "a write to pool pulls"
case_ write-httpie-post         2 create-api "a write to pool pulls"
case_ write-httpie-implicit     2 create-api "a write to pool pulls"
case_ write-httpie-auth-patch   2 create-api "a write to pool pulls"
case_ write-tea-api-method-var  2 create-tea-api "tea api write"
case_ write-js-method-var       2 create-api "a write to pool pulls"
case_ write-close-pool-pr       2 create-api "a write to pool pulls"
# A body option counts on a curl, wget or tea api command, or in its argument list.
case_ write-curl-json-body      2 create-api "a write to pool pulls"
case_ write-curl-json-list      2 create-api "a write to pool pulls"
case_ write-tea-api-data-list   2 create-api "a write to pool pulls"
case_ json-flag-run             0 - ""
case_ post-comment-links-pr     0 - ""
case_ post-bugzilla-links-pr    0 - ""
# Only a stand-in that still sends the request, with nothing else to refuse, proves the case.
# shellcheck disable=SC2016  # the $method is the script's, matched literally
if grep -qF -- '-X "$method"' "$W/pp-nogate.sh" && ! grep -qe ' push ' -e 'target-gate\.sh' "$W/pp-nogate.sh"; then
  case_ write-real-pool-pr-nogate 2 create-api "a write to pool pulls"
else
  fail "pool-pr.sh no longer sends its PR request with a variable method; rebuild the stand-in"
  used="${used}write-real-pool-pr-nogate "
fi
case_ get-urllib                0 - ""
case_ get-requests              0 - ""
case_ get-http-client           0 - ""
case_ get-httpie                2 api-direct "http to src.opensuse.org/api"
case_ get-httpie-query          2 api-direct "http to src.opensuse.org/api"
case_ get-curl-query            2 api-direct "curl to src.opensuse.org/api"

echo "--- scripts: written, then run, in every form"
case_ write-script              2 create-api      "a script writing to pool pulls"
case_ edit-script-merge         2 merge-tea       "a script running a tea PR merge"
case_ write-merge-script        2 merge-api       "a script merging a PR"
case_ write-merge-script-ai     2 merge-api       "a script merging a PR"
case_ write-script-tea-create   2 create-tea      "a script running a tea PR create"
case_ write-doc                 0 - ""
case_ write-script-ai-merge     2 merge-tea       "a script running a tea PR merge"
case_ write-script-ai-create    0 - ""
case_ write-script-tea-api-data 2 create-api      "a script writing to pool pulls"
case_ json-flag-write           0 - ""
case_ run-bash                  2 create-api      "a write to pool pulls"
case_ run-dot-slash             2 create-api      "a write to pool pulls"
case_ run-source                2 create-api      "a write to pool pulls"
case_ run-env                   2 create-api      "a write to pool pulls"
case_ run-python                2 create-api      "a write to pool pulls"
case_ run-uv                    2 create-api      "a write to pool pulls"
case_ run-node                  2 create-api      "a write to pool pulls"
case_ run-nested                2 create-api      "a write to pool pulls"
case_ run-dot-slash-py          2 create-api      "a write to pool pulls"
case_ run-perl                  2 create-api      "a write to pool pulls"
case_ run-source-word           2 create-api      "a write to pool pulls"
case_ run-bash-option           2 create-api      "a write to pool pulls"
case_ run-python-option         2 create-api      "a write to pool pulls"
case_ run-agit-script           2 push-pool       "naming pool/ or AGit refs"
case_ run-script-merge          2 merge-tea       "tea PR merge"
# A script's quoted strings are data; only the command line itself is read as text.
case_ run-script-quoting-merge  0 - ""
case_ run-path-shebang          0 - ""
case_ run-path-plain-sh         0 - ""
case_ run-elf                   0 - ""
# Interpreter options that name no script file.
case_ run-python-module         0 - ""
case_ run-bash-stdin-args       0 - ""
case_ run-not-yet-written       2 exec-written    "pp2.sh"
case_ run-missing               2 exec-unreadable "no-such-script.sh"
case_ run-cwd-unknown           2 exec-unreadable "the working directory is unknown"
# A relative path is placed in the event's cwd (or where a cd moved), not the hook's own;
# one that is not there is refused, naming where it was looked for.
case_ run-relative-dot-slash    0 - ""
case_ run-relative-bash         0 - ""
case_ run-relative-after-cd     0 - ""
case_ run-relative-missing      2 exec-unreadable "./scripts/leap-sync.sh ($work/clone/scripts/leap-sync.sh: No such file"

echo "--- a file the call writes does not run in the same call"
case_ written-cat-run           2 exec-written "$W/iter.py"
case_ written-tee-run           2 exec-written "$W/iter.sh"
case_ written-sed-i-run         2 exec-written "$W/iter.sh"
case_ written-echo-run          2 exec-written "iter.sh is written"
case_ written-cp-run            2 exec-written "$W/iter.sh"
case_ written-cp-t-run          2 exec-written "$W/iter.sh"
case_ written-mv-run            2 exec-written "$W/iter.sh"
case_ written-install-run       2 exec-written "$W/iter.sh"
case_ written-perl-i-run        2 exec-written "$W/iter.sh"
case_ written-curl-o-run        2 exec-written "$W/iter.sh"
case_ written-curl-O-run        2 exec-written "iter.sh is written"
case_ written-push-run          2 exec-written "$W/iter.sh"
case_ written-var-run           2 exec-written "\$W/iter.py"
case_ written-dir-run           2 exec-written "$W/copied/pool-pr.sh"
case_ written-source-run        2 exec-written "$W/iter.sh"
case_ written-skill-sibling     2 create-api   "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
case_ written-not-run           0 - ""
case_ written-other-run         0 - ""
case_ written-other-judged      2 create-api   "a write to pool pulls"

echo "--- script paths the shell expands: this call's values, \$PWD, \$TMPDIR, globs"
case_ var-path-assigned         2 create-api "a write to pool pulls"
case_ var-path-for-glob         2 create-api "a write to pool pulls"
case_ var-path-glob             2 create-api "a write to pool pulls"
case_ var-path-python           2 create-api "a write to pool pulls"
case_ var-path-dir              2 create-api "a write to pool pulls"
case_ var-path-export           2 create-api "a write to pool pulls"
case_ var-path-tmpdir           2 create-api "a write to pool pulls" TMPDIR="$W"
case_ var-path-pwd              2 create-api "a write to pool pulls"
case_ var-path-exec             2 create-api "a write to pool pulls"
case_ var-path-unknown          2 exec-unresolved "\$UNSET_DIR/pr.sh"
case_ var-path-tmpdir           2 exec-unresolved "\$TMPDIR/open-pr.sh" TMPDIR=
case_ var-path-substitution     2 exec-unresolved "/b.sh"
case_ var-path-benign           0 - ""
case_ var-path-loop-benign      0 - ""
# Past 64 values a variable is unknown, never cut short.
case_ var-path-loop-64          2 create-api "a write to pool pulls"
case_ var-path-loop-65          2 exec-unresolved "\$f"

echo "--- the skill's scripts: trusted only as merged, run by path, in the checkout"
case_ canonical-pool-pr   0 - ""                          PR_GUARD_SKILL_DIR="$S"
case_ canonical-by-path   0 - ""                          PR_GUARD_SKILL_DIR="$S"
case_ canonical-other-script 0 - ""                       PR_GUARD_SKILL_DIR="$S"
case_ canonical-symlink   0 - ""                          PR_GUARD_SKILL_DIR="$S"
case_ canonical-copy      2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
case_ canonical-exact-copy 2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
case_ canonical-untracked 2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
case_ canonical-sourced   2 canonical-read "read as a program" PR_GUARD_SKILL_DIR="$S"
case_ canonical-fed       2 canonical-read "read as a program" PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-path  2 canonical-env "run with PATH"      PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-build-dir 2 canonical-env "run with BUILD_DIR" PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-command 2 canonical-env "run with PATH"   PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-export 2 canonical-env "run with PATH"    PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-then  2 canonical-env "run with PATH"    PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-clean 0 - ""                          PR_GUARD_SKILL_DIR="$S"
# changes-prepend.sh documents CHANGES_AUTHOR as the way to name the entry's author.
case_ canonical-env-changes-author 0 - ""                 PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-changes-author-export 0 - ""          PR_GUARD_SKILL_DIR="$S"
case_ canonical-shell-variable 0 - ""                     PR_GUARD_SKILL_DIR="$S"
# A commit that is not merged is not trusted: the pin is origin/main, not HEAD.
echo 'echo edited' >> "$S/scripts/pool-pr.sh"; git -C "$S" commit -qam 'local edit'
case_ canonical-pool-pr   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
case_ canonical-pool-pr   0 - ""                          PR_GUARD_SKILL_DIR="$S" PR_GUARD_PIN_REF=refs/heads/main
git -C "$S" reset -q --hard refs/remotes/origin/main
mkdir -p "$work/h1/.claude/skills" "$work/h2/.agents/skills"
ln -s "$S" "$work/h1/.claude/skills/opensuse-packaging"
ln -s "$S" "$work/h2/.agents/skills/opensuse-packaging"
case_ canonical-pool-pr   0 - ""                          HOME="$work/h1"
case_ canonical-pool-pr   0 - ""                          HOME="$work/h2"
case_ canonical-pool-pr   2 create-api "a write to pool pulls"
echo 'echo edited' >> "$S/scripts/pool-pr.sh"
case_ canonical-pool-pr   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
# An index flag hides the edit from `git diff`, not from the blob hash.
git -C "$S" update-index --assume-unchanged scripts/pool-pr.sh
if git -C "$S" diff --quiet HEAD -- scripts/pool-pr.sh; then
  case_ canonical-pool-pr 2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
else
  fail "assume-unchanged did not hide the edit from git diff; the case proves nothing"
fi
git -C "$S" update-index --no-assume-unchanged scripts/pool-pr.sh
# A clean filter that hashes the edit to the pinned blob hides it from git, not
# from the bytes on disk.
echo 'scripts/pool-pr.sh filter=pin' > "$S/.git/info/attributes"
git -C "$S" config filter.pin.clean "cat $work/pinned-pool-pr.sh"
if [ "$(git -C "$S" hash-object scripts/pool-pr.sh)" = "$(git -C "$S" rev-parse HEAD:scripts/pool-pr.sh)" ]; then
  case_ canonical-clean-filter 2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
else
  fail "the clean filter did not hash the edit to the pinned blob; the case proves nothing"
fi
rm -f "$S/.git/info/attributes"; git -C "$S" config --unset filter.pin.clean
cp "$work/pinned-pool-pr.sh" "$S/scripts/pool-pr.sh"
case_ canonical-pool-pr   0 - ""                          PR_GUARD_SKILL_DIR="$S"
# The scripts run their siblings: one that differs from the pin, or that the
# index tracks and the pin lacks, untrusts them all.
printf 'exit 0\n' > "$S/scripts/target-gate.sh"
case_ canonical-sibling-gutted  2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
git -C "$S" rm -q --cached scripts/target-gate.sh
case_ canonical-sibling-dropped 2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
git -C "$S" reset -q; cp "$work/pinned-gate.sh" "$S/scripts/target-gate.sh"
git -C "$S" add scripts/new-tool.sh
case_ canonical-sibling-added   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
git -C "$S" rm -q --cached scripts/new-tool.sh
case_ canonical-pool-pr   0 - ""                          PR_GUARD_SKILL_DIR="$S"

echo "--- stamps"
case_ stamp-redirect      2 stamp       "a redirection into the stamp directory"
case_ stamp-gate-output   2 stamp       "a redirection into the stamp directory"
case_ stamp-python        2 stamp       "a command touching the stamp directory"
# Writing a script is not running it; running it is refused.
case_ stamp-heredoc       0 - ""
case_ stamp-script-run    2 stamp       "program text touching the stamp directory"
case_ stamp-write-tool    2 stamp-write "only target-gate.sh writes its stamps"
case_ stamp-gate-call     0 - ""
# The directory named without a trailing slash, from inside it, or in pieces.
case_ stamp-cp-dir        2 stamp       "a command touching the stamp directory"
case_ stamp-cd-printf     2 stamp       "a redirection into the stamp directory"
case_ stamp-cd-cp         2 stamp       "a command touching the stamp directory"
case_ stamp-install-t     2 stamp       "a command touching the stamp directory"
case_ stamp-cp-r          2 stamp       "a command touching the stamp directory"
case_ stamp-var-sed       2 stamp       "a command touching the stamp directory"
case_ stamp-shutil-join   2 stamp       "program text touching the stamp directory"
case_ stamp-python-join   2 stamp       "program text touching the stamp directory"
case_ stamp-heredoc-glob  2 stamp       "program text touching the stamp directory"
case_ stamp-cwd-event     2 stamp       "a redirection into the stamp directory"
case_ stamp-mv-no-slash   2 stamp       "a command touching the stamp directory"
case_ stamp-find-delete   2 stamp       "a command touching the stamp directory"
case_ stamp-find-exec     2 stamp       "a command touching the stamp directory"
case_ stamp-cat-redirect  2 stamp       "a redirection into the stamp directory"
# Looking is not writing.
case_ stamp-read-ls       0 - ""
case_ stamp-read-cat      0 - ""
case_ stamp-read-jq       0 - ""
case_ stamp-read-grep     0 - ""
case_ stamp-read-head-tail 0 - ""
case_ stamp-read-find     0 - ""
case_ stamp-read-cd-ls    0 - ""
case_ stamp-read-cwd-event 0 - ""
case_ stamp-read-rg       0 - ""
case_ stamp-read-wc       0 - ""
case_ stamp-read-json-tool 0 - ""
case_ stamp-read-sed      0 - ""
case_ stamp-read-awk      0 - ""
case_ stamp-var-subst-read 0 - ""
# ... unless it writes a file: its output, sed w, awk print >, an output file.
case_ stamp-read-redirect-unknown 2 stamp "a command touching the stamp directory"
case_ stamp-sed-w         2 stamp       "a command touching the stamp directory"
case_ stamp-awk-redirect  2 stamp       "a command touching the stamp directory"
case_ stamp-json-tool-outfile 2 stamp   "a command touching the stamp directory"
# A path is a stamp path only directly under a git directory; the word alone is text.
case_ stamp-text-rg       0 - ""
case_ stamp-text-git-grep 0 - ""
case_ stamp-text-git-log-grep 0 - ""
case_ stamp-text-git-branch 0 - ""
case_ stamp-text-git-commit 0 - ""
case_ stamp-text-git-commit-path 0 - ""
case_ stamp-text-sed      0 - ""
case_ stamp-text-awk      0 - ""
case_ stamp-text-gh-title 0 - ""
case_ stamp-text-path-elsewhere 0 - ""
case_ stamp-cwd-not-git   0 - ""
case_ stamp-cwd-not-git-make 0 - ""
case_ stamp-git-redirect  2 stamp       "a redirection into the stamp directory"
case_ stamp-git-dir-unnamed 2 stamp     "a command touching the stamp directory"
case_ stamp-unknown-parent 2 stamp      "a command touching the stamp directory"
# A stamp directory held in a variable set from a substitution.
case_ stamp-var-subst-cp  2 stamp       "a command touching the stamp directory"
case_ stamp-cd-subst-printf 2 stamp     "a redirection into the stamp directory"
case_ stamp-cd-subst-sed    2 stamp     "a command touching the stamp directory"
case_ stamp-pushd-subst-cp  2 stamp     "a command touching the stamp directory"
case_ stamp-cd-var-cp       2 stamp     "a command touching the stamp directory"
case_ stamp-env-C-subst-cp  2 stamp     "a command touching the stamp directory"
case_ stamp-read-cd-subst-ls 0 - ""
case_ stamp-var-subst-mkdir 2 stamp     "a command touching the stamp directory"
case_ stamp-var-subst-printf 2 stamp    "a redirection into the stamp directory"
case_ stamp-var-subst-export 2 stamp    "a command touching the stamp directory"
case_ stamp-var-subst-chain 2 stamp     "a command touching the stamp directory"
# Only the skill's own target-gate.sh, as merged, names a stamp freely.
case_ stamp-fake-gate     2 stamp       "a command touching the stamp directory"
case_ stamp-canonical-gate 0 - ""                         PR_GUARD_SKILL_DIR="$S"

echo "--- osc"
case_ osc-build-x86_64    2 emulated-build "x86_64 on aarch64"
case_ osc-build-setsid    2 emulated-build "x86_64 on aarch64"
case_ osc-build-i586      2 emulated-build "i586 on aarch64"
case_ osc-shell-x86_64    2 emulated-build "x86_64 on aarch64"
case_ osc-chroot-x86_64   2 emulated-build "x86_64 on aarch64"
case_ osc-build-x86_64    0 - ""   PR_GUARD_ARCH=x86_64
case_ osc-build-i586      0 - ""   PR_GUARD_ARCH=x86_64
case_ osc-buildinfo       0 - ""
case_ osc-sr-backports    2 backports "scmsync'd from pool"
case_ osc-mr-backports    2 backports "scmsync'd from pool"
case_ osc-sr-factory      0 - ""
# The request message only describes the request.
case_ osc-sr-message-backports 0 - ""
case_ osc-sr-message-eq   0 - ""
# factory-auto declines a Factory request whose source is not the devel project.
case_ osc-sr-nodevelproject   2 nodevelproject "an osc request with --nodevelproject"
case_ osc-creq-nodevelproject 2 nodevelproject "an osc request with --nodevelproject"
case_ osc-sr-nodevel-abbrev   2 nodevelproject "an osc request with --nodevelproject"
case_ osc-sr-nodevel-python   2 nodevelproject "an osc request with --nodevelproject"
case_ osc-sr-devel-control    0 - ""
case_ osc-sr-nodevel-message  0 - ""
# Maintenance and update projects take no direct write, by commit or by API;
# a home: branch of one is the user's own, whatever its name ends in.
case_ osc-ci-update-checkout     2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-ci-incident-checkout   2 maintenance-commit "an osc commit into openSUSE:Maintenance:12345"
case_ osc-ci-update-operand      2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-ci-update-file-operand 2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-ci-update-new-checkout 2 maintenance-commit "an osc commit into openSUSE:Leap:15.6:Update"
case_ osc-api-put-update         2 maintenance-api "an osc api PUT into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-api-post-maintenance-m 2 maintenance-api "an osc api POST into openSUSE:Maintenance:12345"
case_ osc-api-file-implies-put   2 maintenance-api "an osc api PUT into openSUSE:Leap:15.6:Update"
case_ osc-api-delete-full-url    2 maintenance-api "an osc api DELETE into openSUSE:Leap:15.6:Update"
case_ osc-mbranch                0 - ""
case_ osc-mr                     0 - ""
case_ osc-ci-mbranch-checkout    0 - ""
case_ osc-ci-home-update-branch  0 - ""
case_ osc-ci-devel               0 - ""
case_ osc-api-get-update         0 - ""
case_ osc-api-put-home-branch    0 - ""
# A POST that only reads (diff, showlinked) or branches out of the project writes
# nothing into it; any other cmd, none, a branch into it, PUT or DELETE does.
case_ osc-api-post-diff-update       0 - ""
case_ osc-api-post-branch-update     0 - ""
case_ osc-api-post-showlinked-update 0 - ""
case_ osc-api-post-branch-into-update    2 maintenance-api "an osc api POST into openSUSE:Leap:15.6:Update"
case_ osc-api-post-commitfilelist-update 2 maintenance-api "an osc api POST into openSUSE:Leap:15.6:Update"
case_ osc-api-post-copy-update       2 maintenance-api "an osc api POST into openSUSE:Leap:15.6:Update"
case_ osc-api-post-no-cmd-update     2 maintenance-api "an osc api POST into openSUSE:Leap:15.6:Update"
case_ osc-api-post-diff-then-commit  2 maintenance-api "an osc api POST into openSUSE:Leap:15.6:Update"
case_ osc-api-put-diff-query         2 maintenance-api "an osc api PUT into openSUSE:Leap:15.6:Update"
case_ osc-api-delete-branch-query    2 maintenance-api "an osc api DELETE into openSUSE:Leap:15.6:Update"
# A commit or API write the guard cannot place is refused, as a push is; osc's
# global options and api --method count by any prefix argparse takes.
case_ osc-ci-cwd-unknown         2 maintenance-unknown "(the working directory is unknown)"
# A cd follows what the call set: not a value read gives, all values a loop gives
# its variable (before as after the cd), and a loop's globs as the shell expands them.
case_ osc-ci-read-stale          2 maintenance-unknown "(the working directory is unknown)"
case_ osc-ci-loop-reassign       2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-ci-loop-outer-unknown  2 maintenance-unknown "(the working directory is unknown)"
case_ osc-ci-loop-glob-devel     0 - ""
case_ osc-ci-loop-glob-all       2 maintenance-commit "an osc commit into"
case_ osc-api-var-url            2 maintenance-unknown "osc api PUT \$URL"
case_ osc-api-subst-url          2 maintenance-unknown "osc api POST \$(...)"
case_ osc-api-host-var-path      2 maintenance-unknown "osc api DELETE https://api.opensuse.org/\$P"
case_ osc-api-double-slash       2 maintenance-api "an osc api PUT into openSUSE:Leap:15.6:Update"
case_ osc-api-dot-segment        2 maintenance-api "an osc api PUT into openSUSE:Leap:15.6:Update"
case_ osc-api-dotdot-segment     2 maintenance-api "an osc api PUT into openSUSE:Leap:15.6:Update"
# A commit whose checkout has no .osc/_project yet (made in the same call) is unplaced.
case_ osc-co-output-then-ci      2 maintenance-unknown "check out in one call"
case_ osc-co-current-then-ci     2 maintenance-unknown "check out in one call"
case_ osc-ci-not-a-checkout      2 maintenance-unknown "check out in one call"
# A cd into each word of a loop, or into a variable this call set, is followed.
case_ osc-ci-loop-devel          0 - ""
case_ osc-ci-loop-update         2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-ci-var-cd-devel        0 - ""
case_ push-loop-dirs             2 push-unknown "one of several directories"
case_ osc-ci-no-cwd              2 maintenance-unknown "(the working directory is unknown)"
case_ osc-ci-subst-operand       2 maintenance-unknown "osc commit \$(...)"
case_ osc-ci-loop-subst          2 maintenance-unknown "osc commit \$d"
case_ osc-api-var-project        2 maintenance-unknown "osc api PUT /source/\$PRJ/x/_meta"
case_ osc-api-var-branch-target  2 maintenance-unknown "osc api POST /source/openSUSE:Factory/x?cmd=branch&target_project=\$T"
case_ osc-api-quoted-project     2 maintenance-api "an osc api PUT into openSUSE:Leap:15.6:Update"
case_ osc-api-meth-prefix        2 maintenance-api "an osc api DELETE into openSUSE:Leap:15.6:Update"
case_ osc-ci-api-prefix          2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-ci-conf-prefix         2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-ci-setopt              2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-api-var-get            0 - ""
case_ osc-api-var-request        0 - ""
case_ osc-api-quoted-home        0 - ""
case_ osc-ci-var-devel           0 - ""
# Nor do they take a package copied, linked or aggregated in, deleted or
# undeleted, or meta written; reading from them stays allowed.
case_ osc-copypac-into-update       2 maintenance-write "an osc copypac into openSUSE:Leap:15.6:Update"
case_ osc-rmkpac-update            2 maintenance-write "an osc rmkpac into openSUSE:Leap:15.6:Update"
case_ osc-repo-add-update          2 maintenance-write "an osc repo into openSUSE:Leap:15.6:Update"
case_ osc-repo-remove-checkout     2 maintenance-write "an osc repo into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-metafromspec-checkout    2 maintenance-write "an osc updatepacmetafromspec into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-unlock-update            2 maintenance-write "an osc unlock into openSUSE:Leap:15.6:Update"
case_ osc-mbranch-target           2 maintenance-write "an osc mbranch into openSUSE:Maintenance:12345"
case_ osc-addchannels-update       2 maintenance-write "an osc addchannels into openSUSE:Leap:15.6:Update"
case_ osc-addcontainers-update     2 maintenance-write "an osc addcontainers into openSUSE:Leap:15.6:Update"
case_ osc-maintained               0 - ""
case_ osc-repo-list-update         0 - ""
case_ osc-metafromspec-devel       0 - ""
case_ osc-rmkpac-home              0 - ""
case_ osc-branch-into-update        2 maintenance-write "an osc branch into openSUSE:Leap:15.6:Update"
case_ osc-branch-dot-checkout       2 maintenance-write "an osc branch into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-rremove-update            2 maintenance-write "an osc rremove into openSUSE:Leap:15.6:Update"
case_ osc-sdp-update                2 maintenance-write "an osc setdevelproject into openSUSE:Leap:15.6:Update"
case_ osc-sdp-checkout              2 maintenance-write "an osc setdevelproject into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-setlinkrev-maint          2 maintenance-write "an osc setlinkrev into openSUSE:Maintenance:12345"
case_ osc-detachbranch-update       2 maintenance-write "an osc detachbranch into openSUSE:Leap:15.6:Update"
case_ osc-linktobranch-checkout     2 maintenance-write "an osc linktobranch into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-lock-update               2 maintenance-write "an osc lock into openSUSE:Leap:15.6:Update"
case_ osc-release-maint             2 maintenance-write "an osc release into openSUSE:Maintenance:12345"
case_ osc-release-target            2 maintenance-write "an osc release into openSUSE:Leap:15.6:Update"
case_ osc-wipebinaries-update       2 maintenance-write "an osc wipebinaries into openSUSE:Leap:15.6:Update"
case_ osc-unpublish-update          2 maintenance-write "an osc wipebinaries into openSUSE:Leap:15.6:Update"
case_ osc-api-build-wipe            2 maintenance-api "an osc api POST into openSUSE:Leap:15.6:Update"
case_ osc-branch-from-update        0 - ""
case_ osc-bco-from-update           0 - ""
case_ osc-branch-into-home          0 - ""
case_ osc-sdp-devel-checkout        0 - ""
case_ osc-release-home              0 - ""
case_ osc-wipebinaries-home         0 - ""
case_ osc-api-build-result          0 - ""
case_ osc-api-build-rebuild-home    0 - ""
case_ osc-copypac-slash-into-maint  2 maintenance-write "an osc copypac into openSUSE:Maintenance:12345"
case_ osc-linkpac-into-update       2 maintenance-write "an osc linkpac into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-linkpac-from-checkout     2 maintenance-write "an osc linkpac into openSUSE:Leap:15.6:Update"
case_ osc-aggregatepac-into-update  2 maintenance-write "an osc aggregatepac into openSUSE:Leap:15.6:Update"
case_ osc-rdelete-update            2 maintenance-write "an osc rdelete into openSUSE:Leap:15.6:Update"
case_ osc-rdelete-slash             2 maintenance-write "an osc rdelete into openSUSE:Leap:15.6:Update"
case_ osc-rdelete-dot               2 maintenance-write "an osc rdelete into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-undelete-maintenance      2 maintenance-write "an osc undelete into openSUSE:Maintenance:12345"
case_ osc-meta-pkg-file             2 maintenance-write "an osc meta into openSUSE:Leap:15.6:Update"
case_ osc-meta-prj-edit             2 maintenance-write "an osc meta into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-meta-pkg-slash-file       2 maintenance-write "an osc meta into openSUSE:Leap:15.6:Update"
case_ osc-meta-pkg-checkout-file    2 maintenance-write "an osc meta into openSUSE:Backports:SLE-15-SP7:Update"
case_ osc-meta-pkg-edit-prefix     2 maintenance-write "an osc meta into openSUSE:Leap:15.6:Update"
case_ osc-copypac-var-unknown       2 maintenance-unknown "osc copypac to \$DEST"
case_ osc-copypac-from-update       0 - ""
case_ osc-linkpac-into-home         0 - ""
case_ osc-aggregatepac-from-update  0 - ""
case_ osc-rdelete-home-branch       0 - ""
case_ osc-rdelete-dot-home          0 - ""
case_ osc-meta-pkg-read             0 - ""
case_ osc-meta-prj-blame            0 - ""
case_ osc-meta-pkg-home-file        0 - ""
# A request is filed with osc, which checks the devel project and the message;
# one created through the API skips both.
case_ request-api-osc-create        2 request-api "a request created through the API"
case_ request-api-pct-value         2 request-api "a request created through the API"
case_ request-api-pct-key           2 request-api "a request created through the API"
case_ request-api-dot               2 request-api "a request created through the API"
case_ request-api-curl-pct          2 request-api "a request created through the API"
case_ request-api-osc-create-addrev 2 request-api "a request created through the API"
case_ request-api-curl-create       2 request-api "a request created through the API"
case_ request-api-python-create     2 request-api "a request created through the API"
case_ request-api-var-create        2 request-api "a request created through the API"
case_ request-api-changestate       0 - ""
case_ request-api-list              0 - ""
case_ request-sr-supersede          0 - ""

echo "--- find -exec, watch and parallel run the command they carry"
case_ find-exec-tea-merge        2 merge-tea     "tea PR merge"
case_ find-execdir-push          2 push-unknown  "the working directory is unknown"
case_ find-ok-sh-merge           2 merge-tea     "tea PR merge"
case_ find-exec-placeholder-push 2 push-unknown  "the pushed branch is held in a variable"
case_ watch-tea-merge            2 merge-tea     "tea PR merge"
case_ watch-exec-merge           2 merge-tea     "tea PR merge"
case_ parallel-merge             2 merge-tea     "tea PR merge"
case_ parallel-push-placeholder  2 push-unknown  "the pushed branch is held in a variable"
case_ find-exec-grep             0 - ""
case_ watch-osc-results          0 - ""
case_ parallel-echo              0 - ""

echo "--- osc named by a variable is judged as osc"
case_ var-osc-ci-update          2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
# The prefilter also reads the text without its quotes and backslashes, $'...'
# decoded, and a variable after if, while, !, { or a wrapper.
case_ prefilter-split-quotes     2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ prefilter-ansi-c           2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ prefilter-quoted-var       2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ prefilter-if-var           2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ prefilter-wrapper-var      2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
# A command held in several words (a variable, an array, a function running "$@")
# is those words; one only the shell knows is refused.
case_ var-multiword-command      2 merge-tea     "tea PR merge"
case_ var-array-command          2 merge-tea     "tea PR merge"
case_ func-wrapper-merge         2 merge-tea     "tea PR merge"
case_ var-array-unknown          2 command-unknown "\${ARGS[@]}"
case_ func-wrapper-status        0 - ""
case_ var-array-status           0 - ""
# An unknown command is judged as osc only when its variable is named for it.
case_ var-git-commit             0 - ""
case_ var-make-release           0 - ""

echo "--- osc request arguments held in variables are judged by their values"
case_ osc-sr-var-backports       2 backports "scmsync'd from pool"
case_ osc-sr-loop-backports      2 backports "scmsync'd from pool"
case_ osc-sr-var-nodevel         2 nodevelproject "an osc request with --nodevelproject"
case_ osc-sr-unknown-target      2 request-unknown "osc sr \$TARGET"
case_ osc-sr-var-factory         0 - ""

echo "--- tea's options may take one dash (-repo, -method)"
case_ tea-create-single-dash-repo 2 create-tea   "tea PR create"
case_ tea-api-pulls-single-dash  2 create-tea-api "tea api write"
case_ tea-create-single-dash-ai  0 - ""
case_ tea-api-pulls-get-single-dash 0 - ""

echo "--- a number before a redirection is its fd only when attached"
case_ fd-number-argument         0 - ""
case_ fd-number-attached         2 push-pr-head "pool/tesseract-ocr#3"

echo "--- an expansion that doubles past 64 KiB is unknown, and fast"
case_ var-doubling-script        2 exec-unresolved "\$V40"
case_ var-doubling-message       2 request-message-unknown "\$V40"

echo "--- a FIFO or device is refused, never read"
case_ run-fifo                   2 exec-unreadable "not a regular file"
case_ msg-fifo                   2 request-message-unknown "-F"
case_ run-dev-stdin              2 exec-unreadable "not a regular file"
case_ var-osc-path-sr-long       2 request-message "an osc sr message with 380 characters of prose"
case_ var-osc-unset-ci-update    2 maintenance-commit "an osc commit into openSUSE:Backports:SLE-15-SP7:Update"
case_ var-osc-unset-nodevel      2 nodevelproject "an osc request with --nodevelproject"
case_ var-osc-ci-devel           0 - ""
# A request message is 1-3 sentences: over 300 characters it is refused.
case_ osc-sr-long-message        2 request-message "an osc sr message with 380 characters of prose"
case_ osc-sr-message-301         2 request-message "an osc submitreq message with 301 characters of prose"
case_ osc-mr-long-message-eq     2 request-message "an osc mr message with 380 characters of prose"
case_ osc-creq-long-message-attached 2 request-message "an osc creq message with 380 characters of prose"
case_ osc-sr-message-200         0 - ""
case_ osc-sr-message-300         0 - ""
case_ osc-ci-long-message        0 - ""
# ... wherever the message comes from: a substitution, a file, stdin, a variable,
# a --message prefix. Only the prose counts, the text before a "- "/"* " list.
case_ msg-subst-cat-long         2 request-message "an osc sr message with 380 characters of prose"
# read, printf -v, declare -n and mapfile leave a value only the shell knows; a
# substitution's files are placed where its own cd leaves it; printf widths,
# reused formats and brace expansion are unknown; a loop's many spellings are
# measured by their longest.
case_ msg-read-stale             2 request-message-unknown "\$MSG"
case_ msg-printf-v-stale         2 request-message-unknown "\$MSG"
case_ msg-declare-n              2 request-message-unknown "\$MSG"
case_ msg-mapfile                2 request-message-unknown "\$MSG"
case_ msg-subst-cd               2 request-message "an osc sr message with 380 characters of prose"
case_ msg-subst-cd-unknown       2 request-message-unknown "a command substitution"
case_ msg-loop-70-short          0 - ""
case_ msg-loop-70-long           2 request-message-unknown "\$p: \$L"
case_ msg-printf-width           2 request-message-unknown "a command substitution"
case_ msg-printf-reuse           2 request-message-unknown "a command substitution"
case_ msg-echo-brace             2 request-message-unknown "a command substitution"
# Text is resolved like a -m word: stdin, here-strings, echo/printf of variables,
# expanding heredocs, += and every writer of a substitution; unknown is refused.
case_ msg-herestring-var-long    2 request-message "an osc sr message with 380 characters of prose"
case_ msg-echo-var-pipe-long     2 request-message "an osc sr message with 380 characters of prose"
case_ msg-printf-subst-long      2 request-message "an osc sr message with 380 characters of prose"
case_ msg-heredoc-expanding-long 2 request-message "an osc sr message with 380 characters of prose"
case_ msg-plus-equals-long       2 request-message "an osc sr message with 380 characters of prose"
case_ msg-subst-two-writers-long 2 request-message "an osc sr message with 380 characters of prose"
case_ msg-echo-unset-pipe        2 request-message-unknown "stdin"
case_ msg-heredoc-expanding-unset 2 request-message-unknown "stdin"
# Every line but a "- " item is prose, wherever it sits; an item is at most 100
# characters, the message 1000.
case_ msg-changes-bullets        2 request-message "characters of prose"
case_ msg-changes-entries        2 request-message "characters of prose"
case_ msg-prose-after-list       2 request-message "an osc sr message with 306 characters of prose"
case_ msg-long-list-line         2 request-message "an osc sr message with a 132-character list line"
case_ msg-list-over-1000         2 request-message "an osc sr message of 1144 characters"
case_ msg-star-list              2 request-message "an osc sr message with 520 characters of prose"
# Single quotes, $'...' and \$ are literal; $(<FILE) reads FILE.
case_ msg-single-quoted-dollar   0 - ""
case_ msg-ansi-c-quoted          0 - ""
case_ msg-escaped-dollar         0 - ""
case_ msg-double-quoted-unset    2 request-message-unknown "Fix \$UNSET handling"
case_ msg-heredoc-quoted-dollar  0 - ""
case_ msg-subst-redirect-long    2 request-message "an osc sr message with 380 characters of prose"
case_ msg-subst-redirect-short   0 - ""
case_ msg-subst-cat-short        0 - ""
case_ msg-subst-heredoc-long     2 request-message "an osc sr message with 380 characters of prose"
case_ msg-subst-heredoc-short    0 - ""
case_ msg-file-long              2 request-message "an osc sr message with 380 characters of prose"
case_ msg-file-short             0 - ""
case_ msg-file-stdin-long        2 request-message "an osc sr message with 380 characters of prose"
case_ msg-file-stdin-short       0 - ""
case_ msg-var-long               2 request-message "an osc sr message with 380 characters of prose"
case_ msg-var-short              0 - ""
case_ msg-var-subst-long         2 request-message "an osc sr message with 380 characters of prose"
case_ msg-prefix-eq-long         2 request-message "an osc sr message with 380 characters of prose"
case_ msg-prefix-space-long      2 request-message "an osc sr message with 380 characters of prose"
case_ msg-prefix-short           0 - ""
case_ msg-prose-then-list        0 - ""
case_ msg-inline-prose-then-list 0 - ""
case_ msg-long-prose-then-list   2 request-message "an osc sr message with 380 characters of prose"
case_ msg-deletereq-long         2 request-message "an osc deletereq message with 380 characters of prose"
case_ msg-changedevel-long       2 request-message "an osc changedevelrequest message with 380 characters of prose"
case_ msg-dr-short               0 - ""
# A message it cannot read now is refused.
case_ msg-var-unset              2 request-message-unknown "Pass the message inline or from a readable file"
case_ msg-file-missing           2 request-message-unknown "/nonexistent/message.txt"
case_ msg-file-written           2 request-message-unknown "msg-new.txt"
case_ msg-stdin-unknown          2 request-message-unknown "stdin"
case_ msg-subst-unknown          2 request-message-unknown "a command substitution"

echo "--- a help invocation of a guarded tool does nothing"
case_ help-tea-create           0 - ""
case_ help-tea-merge-h          0 - ""
case_ help-git-obs-merge        0 - ""
case_ help-git-obs-space-create 0 - ""
case_ help-git-push             0 - ""
case_ help-osc-build            0 - ""
# ... unless it is an option's value or an operand, and a script is read whatever its arguments.
case_ help-as-option-value      2 create-tea   "tea PR create"
case_ help-after-dashdash       2 push-pr-head "pool/tesseract-ocr#3"
case_ help-script-still-read    2 create-api   "a write to pool pulls"

echo "--- credential files are read only by the tools that own them"
# On the agent's own command line: named as written, placed in the cwd a cd
# leaves or the event gives, through this call's values, dot segments, globs
# and symlinks; the first is the field's token scrape.
case_ cred-tea-scrape-field      2 credential-read "grep reads ~/.config/tea/config.yml"
case_ cred-home-var              2 credential-read "grep reads ~/.config/tea/config.yml"
case_ cred-dot-segment           2 credential-read "cat reads ~/.config/tea/config.yml"
case_ cred-relative-cwd          2 credential-read "cat reads ~/.config/tea/config.yml"
case_ cred-cd-relative           2 credential-read "head reads ~/.config/tea/config.yml"
case_ cred-glob                  2 credential-read "cat reads ~/.config/tea/config.yml"
case_ cred-var-assigned          2 credential-read "awk reads ~/.netrc"
case_ cred-symlink               2 credential-read "cat reads ~/.config/tea/config.yml"
case_ cred-oscrc-sed             2 credential-read "sed reads ~/.config/osc/oscrc"
case_ cred-source-oscrc          2 credential-read "source reads ~/.config/osc/oscrc"
case_ cred-cookiejar-cp          2 credential-read "cp reads ~/.local/state/osc/cookiejar"
case_ cred-gh-hosts              2 credential-read "yq reads ~/.config/gh/hosts.yml"
case_ cred-git-credentials       2 credential-read "cut reads ~/.git-credentials"
case_ cred-mcp-api-key           2 credential-read "cat reads ~/.config/mcp-bugzilla/api-key"
case_ cred-redirect              2 credential-read "a redirection reads ~/.netrc"
case_ cred-subst-redirect        2 credential-read "a redirection reads ~/.netrc"
case_ cred-bash-c                2 credential-read "head reads ~/.git-credentials"
case_ cred-xargs-file            2 credential-read "xargs reads ~/.netrc"
case_ cred-parallel-input        2 credential-read "parallel reads ~/.netrc"
case_ cred-parallel-arg-file     2 credential-read "parallel reads ~/.config/tea/config.yml"
case_ cred-parallel-quad         2 credential-read "parallel reads ~/.git-credentials"
case_ cred-wrapper-watch         2 credential-read "xargs reads ~/.netrc"
case_ cred-wrapper-parallel      2 credential-read "xargs reads ~/.git-credentials"
case_ cred-find-exec             2 credential-read "find reads ~/.config/gh"
case_ cred-cwd-unknown-oscrc     2 credential-read "cat reads oscrc"
# A recursive read of a directory above them reads them too.
case_ cred-recursive-grep        2 credential-read "grep reaches the credential files under ~/.config"
case_ cred-recursive-tar         2 credential-read "tar reaches the credential files under ~/.local"
case_ cred-recursive-rg-cwd      2 credential-read "rg reaches the credential files under ~"
# A brace expansion names each word bash expands it to: lists and sequences,
# nested, into the pattern's place or the command's; past 64 words it is unknown.
case_ cred-brace-list            2 credential-read "cat reads ~/.config/osc/oscrc"
case_ cred-brace-quoted-space    2 credential-read "cat reads ~/.config/osc/oscrc"
case_ cred-brace-escaped-space   2 credential-read "cat reads ~/.config/osc/oscrc"
case_ cred-brace-glob            2 credential-read "head reads ~/.config/tea/config.yml"
case_ cred-brace-grep            2 credential-read "grep reads ~/.config/tea/config.yml"
case_ cred-brace-dotfiles        2 credential-read "cat reads ~/.netrc"
case_ cred-brace-recursive       2 credential-read "grep reaches the credential files under ~/.config"
case_ cred-brace-tar             2 credential-read "tar reads ~/.config/tea"
case_ cred-brace-nested          2 credential-read "cat reads ~/.config/gh/hosts.yml"
case_ cred-brace-sequence        2 credential-read "cat reads ~/.config/mcp-bugzilla/api-key"
case_ cred-brace-pattern-shift   2 credential-read "grep reads ~/.netrc"
case_ cred-brace-command         2 credential-read "head reads ~/.git-credentials"
case_ cred-brace-redirect        2 credential-read "a redirection reads ~/.netrc"
case_ cred-brace-too-many        2 credential-read "a brace expansion past 64 words"
# Looking is not reading, a write is not a read, and a word is not a file:
# a search pattern, a commit message, a package named for a helper.
case_ cred-ls-config             0 - ""
case_ cred-stat-test             0 - ""
case_ cred-ls-in-cred-dir        0 - ""
case_ cred-find-listing          0 - ""
case_ cred-write-fake-config     0 - ""
case_ cred-spec-oauth            0 - ""
case_ cred-spec-askpass          0 - ""
case_ cred-grep-pattern          0 - ""
case_ cred-commit-message        0 - ""
case_ cred-grep-elsewhere        0 - ""
case_ cred-brace-sources         0 - ""
case_ cred-brace-quoted-echo     0 - ""
case_ cred-brace-ls              0 - ""
case_ cred-brace-ls-many         0 - ""
case_ cred-brace-backup          0 - ""
case_ cred-brace-find-exec       0 - ""
case_ cred-brace-sequence-small  0 - ""
case_ cred-parallel-plain        0 - ""
# The tools read their own: osc its --config, git-obs its --gitea-config.
case_ cred-osc-own-config        0 - ""
case_ cred-git-obs-own-config    0 - ""
# A grep that prints only a build-* setting of oscrc (build-summary.sh and
# target-gate.sh read build-root so); any other key or a context option reads more.
case_ cred-build-root-grep       0 - ""
case_ cred-oscrc-grep-pass       2 credential-read "grep reads ~/.config/osc/oscrc"
case_ cred-oscrc-grep-context    2 credential-read "grep reads ~/.config/osc/oscrc"
# An askpass program hands git or ssh a password: setting one, or running or
# reading it, is refused; testing that one is set is not.
case_ askpass-run                2 askpass "\$GIT_ASKPASS"
case_ askpass-cat                2 askpass "\$SSH_ASKPASS"
case_ askpass-env-clone          2 askpass "GIT_ASKPASS"
case_ askpass-push-fork          2 askpass "GIT_ASKPASS"
case_ askpass-export             2 askpass "SSH_ASKPASS"
case_ askpass-alone              2 askpass "GIT_ASKPASS"
case_ askpass-env-wrapper        2 askpass "GIT_ASKPASS"
case_ askpass-git-c              2 askpass "core.askPass"
case_ askpass-git-config         2 askpass "core.askpass"
case_ askpass-test-set           0 - ""
case_ askpass-git-config-get     0 - ""

echo "--- the tools' own secret printers"
case_ secret-gh-token            2 secret-gh      "gh auth token"
case_ secret-gh-status           2 secret-gh      "gh auth status"
case_ secret-gh-git-credential   2 secret-gh      "gh auth git-credential"
case_ secret-git-obs-login-list  2 secret-git-obs "git-obs login list"
case_ secret-git-obs-space       2 secret-git-obs "git-obs login list"
case_ secret-git-obs-helper      2 secret-git-obs "git-obs gitcredentials-helper"
case_ secret-tea-helper          2 secret-tea     "tea login helper"
case_ secret-tea-edit            2 secret-tea     "tea logins e"
case_ secret-osc-dump-full       2 secret-osc     "osc config --dump-full"
case_ secret-osc-dump-prefix     2 secret-osc     "osc config --dump-full"
case_ secret-osc-dump-var        2 secret-osc     "osc config --dump-full"
case_ secret-osc-dump-var-unknown 2 secret-osc    "\$OSC: osc config --dump-full"
case_ secret-osc-http-debug      2 secret-osc     "osc HTTP debugging"
case_ secret-osc-http-debug-cluster 2 secret-osc  "osc HTTP debugging"
case_ secret-osc-http-full-prefix 2 secret-osc    "osc HTTP debugging"
case_ secret-osc-setopt-debug    2 secret-osc     "osc HTTP debugging"
case_ secret-osc-env-debug       2 secret-osc     "osc HTTP debugging"
case_ secret-osc-token           2 secret-osc     "osc token"
case_ secret-osc-token-apiurl    2 secret-osc     "osc token"
case_ secret-osc-quoted          2 secret-osc     "osc token"
case_ secret-osc-config-pass     2 secret-osc     "osc config passx"
case_ secret-osc-api-person-token 2 secret-osc    "osc api /person/<login>/token"
case_ secret-git-credential-fill 2 secret-git     "git credential fill"
case_ secret-git-credential-helper 2 secret-git   "git credential-libsecret get"
case_ secret-git-credential-direct 2 secret-git   "git-credential-oauth get"
case_ secret-tool-lookup         2 secret-tool    "secret-tool lookup"
case_ secret-tool-search         2 secret-tool    "secret-tool search"
case_ secret-gh-pr-list          0 - ""
case_ secret-tea-login-list      0 - ""
case_ secret-osc-dump            0 - ""
case_ secret-osc-config-build-root 0 - ""
case_ secret-osc-api-person      0 - ""
case_ secret-osc-whois           0 - ""
case_ secret-osc-token-help      0 - ""
case_ secret-git-config-helper   0 - ""
case_ secret-names-only          0 - ""
case_ secret-git-obs-api-user    0 - ""

echo "--- a credential on a command line"
case_ auth-header-curl           2 auth-header "curl with a credential header (Authorization)"
case_ auth-header-wget           2 auth-header "wget with a credential header (Authorization)"
case_ auth-private-token         2 auth-header "curl with a credential header (PRIVATE-TOKEN)"
case_ auth-httpie-header         2 auth-header "http with a credential header (Authorization)"
case_ auth-tea-api-header        2 auth-header "tea api with a credential header (Authorization)"
case_ auth-git-obs-api-header    2 auth-header "git-obs api with a credential header (Authorization)"
case_ auth-git-extraheader       2 auth-header "git with a credential header (Authorization)"
case_ auth-user-pass-curl        2 auth-user   "curl -u with a password"
case_ auth-curl-no-slash         2 auth-user   "curl -u with a password"
case_ auth-xh-auth               2 auth-user   "xh -a with a password"
case_ auth-httpie-bearer         2 auth-user   "https -a with a secret"
case_ auth-curl-bearer-opt       2 auth-user   "curl --oauth2-bearer"
case_ auth-wget-password         2 auth-user   "wget --password"
case_ auth-url-userinfo          2 auth-url    "curl with a password in a URL"
case_ auth-git-clone-userinfo    2 auth-url    "git with a password in a URL"
case_ auth-accept-header         0 - ""
case_ auth-clone-public          0 - ""
case_ auth-clone-ssh             0 - ""
for name in auth-user-pass-curl auth-curl-no-slash auth-xh-auth auth-wget-password auth-url-userinfo auth-git-clone-userinfo; do
  out="$(ev "$name" | python3 "$GUARD" 2>&1)"
  grep -qe hunter2 -e tok3n <<<"$out" && fail "$name: the refusal prints the password" || pass "$name: password not printed"
done

echo "--- the OBS and Gitea APIs are reached through osc and git-obs"
case_ api-curl-obs-field         2 api-direct "curl to api.opensuse.org"
case_ api-curl-obs-schemeless    2 api-direct "curl to api.opensuse.org"
case_ api-curl-build-source      2 api-direct "curl to build.opensuse.org/source"
case_ api-wget-gitea             2 api-direct "wget to src.opensuse.org/api"
case_ api-var-url                2 api-direct "curl to src.opensuse.org/api"
case_ api-uppercase-host         2 api-direct "curl to api.opensuse.org"
case_ api-gitea-dot-segment      2 api-direct "curl to src.opensuse.org/api"
case_ api-httpie-gitea           2 api-direct "http to src.opensuse.org/api"
# Downloads, public git over https, other forges and registries, OBS web pages.
case_ api-download               0 - ""
case_ api-src-raw                0 - ""
case_ api-github                 0 - ""
case_ api-pypi                   0 - ""
case_ api-crates                 0 - ""
case_ api-build-web-page         0 - ""
case_ api-osc-api                0 - ""
case_ api-print-link             0 - ""
case_ api-git-obs                0 - ""

echo "--- the credential rules judge the agent's own commands, not the programs they run"
# A script's body, and program code inline or fed on stdin, are not scanned
# for them: the harness's Read denies and its snippets cover the rest.
case_ cred-script                0 - ""
case_ api-script                 0 - ""
case_ cred-yaml-heredoc          0 - ""
case_ api-python-urllib-obs      0 - ""

echo "--- the prefilter sends them without a path: a keyword, or a cwd among the credentials"
case_ prefilter-netrc-cwd        2 credential-read "cat reads ~/.netrc"
case_ prefilter-cred-dir-cwd     2 credential-read "cat reads ~/.config/gh/hosts.yml"
case_ prefilter-askpass-no-slash 2 askpass "SSH_ASKPASS"

echo "--- plumbing: fail closed only after a match"
case_ nothing-guarded     0 - ""
case_ nul-in-remote       2 undecided "embedded null byte"
# $'...' decodes as bash does, and a character it cannot hold is refused.
case_ ansi-c-bare-escapes 0 - ""
case_ ansi-c-no-character 2 undecided "names no character"
out="$(printf '{"tool_name": "Bash", "tool_input": {"command": "tea pr merge' | python3 "$GUARD" 2>&1)"; got=$?
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided]" <<<"$out" && pass "malformed event after a match (rc=2)" \
  || fail "malformed event after a match: rc=$got $out"
out="$(printf '{"tool_name": "Bash", "tool_input": {"command": "ls' | python3 "$GUARD" 2>&1)"; got=$?
[ "$got" = 0 ] && [ -z "$out" ] && pass "malformed event, nothing guarded (allowed)" \
  || fail "malformed event, nothing guarded: rc=$got $out"
# The rules load only once a call matched; without them it fails closed.
mkdir -p "$work/bare" && cp "$GUARD" "$work/bare/"
out="$(ev nothing-guarded | python3 "$work/bare/pr-guard.py" 2>&1)"; got=$?
[ "$got" = 0 ] && [ -z "$out" ] && pass "unmatched call needs no rules (allowed)" \
  || fail "unmatched call without _pr_guard.py: rc=$got $out"
out="$(ev merge-gitoxide | python3 "$work/bare/pr-guard.py" 2>&1)"; got=$?
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided]" <<<"$out" && grep -qF "_pr_guard.py" <<<"$out" \
  && pass "matched call without _pr_guard.py (rc=2)" || fail "matched call without _pr_guard.py: rc=$got $out"
# A failure's own text is redacted too.
mkdir -p "$work/raises" && cp "$GUARD" "$work/raises/"
{ cat "${GUARD%/*}/_pr_guard.py"; printf '\n\ndef judge(ev):\n    raise ValueError("https://user:tok3n@example.com")\n'; } > "$work/raises/_pr_guard.py"
out="$(ev merge-gitoxide | python3 "$work/raises/pr-guard.py" 2>&1)"; got=$?
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided]" <<<"$out" && grep -qF "user:[REDACTED]@" <<<"$out" && ! grep -qF tok3n <<<"$out" \
  && pass "a failure's text is redacted (rc=2)" || fail "a failure's text is not redacted: rc=$got $out"
# ... and a redaction that fails still refuses, without the text it could not redact.
printf '\n\ndef redact(text):\n    raise RuntimeError("no redaction")\n' >> "$work/raises/_pr_guard.py"
out="$(ev merge-gitoxide | python3 "$work/raises/pr-guard.py" 2>&1)"; got=$?
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided]" <<<"$out" && ! grep -qF tok3n <<<"$out" \
  && pass "a failed redaction still refuses (rc=2)" || fail "a failed redaction: rc=$got $out"
# The open-PR lookups of one call share a budget below the hook's timeout, past which
# Claude Code would run the call unjudged: a lookup still sleeping when it runs out refuses.
mkdir -p "$work/slow/prs" && cp "$GUARD" "$work/slow/"
{ cat "${GUARD%/*}/_pr_guard.py"; printf '\nNET_BUDGET = 1\n'; } > "$work/slow/_pr_guard.py"
mkfifo "$work/slow/prs/tesseract-ocr.json"  # no writer: opening it sleeps for good
t0=$(date +%s)
out="$(ev push-wip | PR_GUARD_PULLS_DIR="$work/slow/prs" timeout 30 python3 "$work/slow/pr-guard.py" 2>&1)"; got=$?
took=$(( $(date +%s) - t0 ))
[ "$got" = 2 ] && grep -qF "BLOCKED [push-unknown]" <<<"$out" && grep -qF "ran past 1 s" <<<"$out" && [ "$took" -lt 10 ] \
  && pass "a lookup still sleeping when the call's budget runs out refuses (rc=2, ${took}s)" \
  || fail "a lookup past the budget: rc=$got after ${took}s $out"
budget=$(sed -n 's/^NET_BUDGET = \([0-9]*\).*/\1/p' "${GUARD%/*}/_pr_guard.py")
hook=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["timeout"])' \
  "$REPO/contrib/harness/claude/pr-guard-hook.json")
[ -n "$budget" ] && [ $((budget + 15)) -le "$hook" ] && pass "the lookup budget (${budget} s) leaves room below the hook's ${hook} s" \
  || fail "lookup budget ${budget:-unset} s against the hook's ${hook} s timeout"
out="$(python3 "$GUARD" --help)"; got=$?
[ "$got" = 0 ] && grep -q '^Exit: 0 = allowed' <<<"$out" && pass "--help (rc=0)" || fail "--help: rc=$got"
python3 "$GUARD" --bogus </dev/null >/dev/null 2>&1; got=$?
[ "$got" = 2 ] && pass "unknown argument (rc=2)" || fail "unknown argument: rc=$got"

echo "--- the skill's own tools, and every suite, run unrefused"
for f in "$REPO"/skills/opensuse-packaging/scripts/*.sh "$REPO"/skills/opensuse-packaging/scripts/*.py "$HERE"/test-*.sh; do
  case ${f##*/} in _*|pool-pr.sh|leap-sync.sh|target-gate.sh) continue;; esac
  case $f in *.py) run=python3;; *) run=bash;; esac
  out="$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[2],
    "tool_input": {"command": sys.argv[1]}}))' "$run $f --help" "$work/plain" | python3 "$GUARD" 2>&1)"; got=$?
  [ "$got" = 0 ] && pass "runs unrefused: ${f##*/}" || { fail "${f##*/} is refused: $out"; }
done

echo "--- the opencode plugins carry the same prefilter"
py="$(python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(mod.PREFILTER.pattern); print(mod.STAMP_DIR); print(mod.CRED_DIR.pattern)' "$GUARD")"
{ IFS= read -r py_pre; IFS= read -r py_stamp; IFS= read -r py_cred; } <<<"$py"
for PLUGIN in $PLUGINS; do
  v=${PLUGIN%/pool-pr-guard.ts}; v=${v##*/}
  # shellcheck disable=SC2016  # the backticks are the pattern's, not the shell's
  ts="$(sed -n 's/^const PREFILTER = new RegExp(String\.raw`\(.*\)`)$/\1/p' "$PLUGIN")"
  [ -n "$ts" ] && [ "$py_pre" = "$ts" ] && pass "$v: prefilter identical in the plugin" \
    || fail "$v: prefilter differs: guard '$py_pre' plugin '$ts'"
  grep -qF 'PREFILTER.test(unquoted(text))' "$PLUGIN" && pass "$v: plugin also reads the text unquoted" \
    || fail "$v: the plugin does not apply the prefilter to the unquoted text"
  ts="$(sed -n 's/^const STAMP_DIR = "\(.*\)"$/\1/p' "$PLUGIN")"
  [ -n "$ts" ] && [ "$py_stamp" = "$ts" ] && grep -qF 'includes(STAMP_DIR)' "$PLUGIN" \
    && pass "$v: plugin also judges a call run inside the stamp directory" \
    || fail "$v: the plugin does not send a call run inside '$py_stamp' to the guard"
  # shellcheck disable=SC2016  # the backticks are the pattern's, not the shell's
  ts="$(sed -n 's/^const CRED_DIR = new RegExp(String\.raw`\(.*\)`)$/\1/p' "$PLUGIN")"
  [ -n "$ts" ] && [ "$py_cred" = "$ts" ] && grep -qF 'CRED_DIR.test(' "$PLUGIN" \
    && pass "$v: plugin also judges a call run among the credential files" \
    || fail "$v: the plugin's CRED_DIR differs or is unused: guard '$py_cred' plugin '$ts'"
done
# Each plugin is wired to its own plugin API: 1.x never runs a 2.x file nor the reverse.
grep -qF '"tool.execute.before"' "${PLUGINS%% *}" && ! grep -qF 'ctx.tool.hook' "${PLUGINS%% *}" \
  && pass "opencode: the 1.x plugin hooks tool.execute.before" \
  || fail "opencode: the 1.x plugin is not wired to tool.execute.before"
v2plugin=${PLUGINS##* }
grep -qF 'ctx.tool.hook("execute.before"' "$v2plugin" && ! grep -qF '"tool.execute.before"' "$v2plugin" \
  && grep -qF 'export default' "$v2plugin" && ! grep -qF 'Plugin.define' "$v2plugin" \
  && pass "opencode-v2: the 2.x plugin registers execute.before from a default export" \
  || fail "opencode-v2: the 2.x plugin is not wired to ctx.tool.hook execute.before"
# git runs "git obs" as git-obs: every git-obs pattern of the backstop has its twin.
miss="$(sed -n 's/^ *"\(git-obs [^"]*\)": "\([a-z]*\)",\{0,1\}$/\1\t\2/p' "$PERMS" | while IFS=$'\t' read -r pat act; do
  grep -qF "\"git obs ${pat#git-obs }\": \"$act\"" "$PERMS" || printf '%s ' "$pat"; done)"
grep -q '"git-obs ' "$PERMS" && [ -z "$miss" ] && pass "backstop spells git obs both ways" \
  || fail "backstop lacks the git obs form of: ${miss:-its git-obs patterns}"

# Every fixture is exercised, so none rots unread.
for name in $(python3 -c 'import json, sys; print(" ".join(json.load(open(sys.argv[1]))))' "$FX/events.json"); do
  case $used in *" $name "*) ;; *) fail "events.json: $name is never used";; esac
done

[ $fails -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
