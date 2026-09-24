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
PLUGIN=$REPO/contrib/harness/opencode-pool-pr-guard.ts
PERMS=$REPO/contrib/harness/opencode-permission-snippet.jsonc
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

# A skill checkout whose pool-pr.sh stand-in, a target-gate.sh it would run and
# another script are committed and merged (origin/main, the pinned ref);
# new-tool.sh is not committed.
S=$work/skill
mkdir -p "$S/scripts" && cp "$FX/pool-pr.sh" "$FX/open-pr.sh" "$S/scripts/"
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
# The harmless scripts of a sweep loop, 64 of them.
mkdir -p "$W/sweep" && for i in $(seq -w 1 64); do printf 'echo %s\n' "$i" > "$W/sweep/p$i.sh"; done
# A local script named like the gate, which copies its arguments.
cp "$FX/fake-gate.sh" "$W/target-gate.sh"; chmod +x "$W/target-gate.sh"
# A worktree named like the stamp directory, which is no git directory (spelled
# in pieces: the guard reads this suite), and a git directory not named .git.
g=gate; mkdir -p "$W/wt/target-$g"
git init -q --bare "$work/barerepo"

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
    WORK="$W" SKILL="$S" BARE="$work/barerepo"
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
case_ merge-smoke-ai            0 - ""
case_ merge-ai-mistral-vibe     0 - ""
case_ merge-no-repo-ai-clone    0 - ""
case_ merge-urllib-ai           0 - ""
case_ merge-in-comment          0 - ""
case_ merge-web-ai              0 - ""
case_ merge-git-obs-ai          0 - ""
# An argument list: the repository option and its value are separate strings.
case_ list-tea-merge            2 merge-tea      "tea PR merge"
case_ list-tea-merge-r          2 merge-tea      "tea PR merge"
case_ list-tea-create           2 create-tea     "tea PR create"
case_ list-git-obs-create       2 create-git-obs "PR create towards pool"
case_ list-tea-merge-ai         0 - ""
# A Python string prefix, and {placeholders}: the literal owner before the slash decides.
case_ list-tea-create-fstring   2 create-tea     "tea PR create"
case_ list-tea-merge-fstring    2 merge-tea      "tea PR merge"
case_ list-git-obs-merge-fstring 2 merge-git-obs "git-obs PR merge"
case_ list-git-obs-merge-owner-placeholder 2 merge-git-obs "git-obs PR merge"
case_ list-tea-merge-fstring-ai 0 - ""

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
case_ cwd-away-from-pool          0 - ""

echo "--- what a variable holds is unknown"
case_ var-push-loop               2 push-unknown "the pushed branch is held in a variable"
case_ var-push-branch             2 push-unknown "the pushed branch is held in a variable"
case_ var-push-url-owner          2 push-unknown "is named by a variable"
case_ var-tea-repo                2 merge-tea     "tea PR merge"
case_ var-git-obs-id              2 merge-git-obs "git-obs PR merge"
case_ var-curl-url                2 create-api    "a write to pool pulls"
case_ var-command-name            2 merge-tea     "tea PR merge"
case_ var-pr-number-ai            0 - ""

echo "--- git obs, as git runs it"
case_ gitobs-space-merge          2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-create         2 create-git-obs "PR create towards pool"
case_ gitobs-space-forward        2 create-git-obs "PR forward on pool"
case_ gitobs-space-no-slash       2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-C              2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-python         2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-ai             0 - ""

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
case_ create-curl-short-ai      0 - ""
case_ get-curl-pulls            0 - ""
case_ get-tea-list              0 - ""
case_ get-tea-api               0 - ""
case_ post-fork                 0 - ""
case_ post-lfs-batch            0 - ""

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
case_ get-httpie                0 - ""
case_ get-httpie-query          0 - ""
case_ get-curl-query            0 - ""

echo "--- scripts: written, then run, in every form"
case_ write-script              2 create-api      "a script writing to pool pulls"
case_ edit-script-merge         2 merge-tea       "a script running a tea PR merge"
case_ write-merge-script        2 merge-api       "a script merging a pool"
case_ write-script-tea-create   2 create-tea      "a script running a tea PR create"
case_ write-doc                 0 - ""
case_ write-script-ai-merge     0 - ""
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

echo "--- plumbing: fail closed only after a match"
case_ nothing-guarded     0 - ""
case_ nul-in-remote       2 undecided "embedded null byte"
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

echo "--- the opencode plugin carries the same prefilter"
py="$(python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(mod.PREFILTER.pattern); print(mod.STAMP_DIR)' "$GUARD")"
# shellcheck disable=SC2016  # the backticks are the pattern's, not the shell's
ts="$(sed -n 's/^const PREFILTER = new RegExp(String\.raw`\(.*\)`)$/\1/p' "$PLUGIN")"
[ -n "$ts" ] && [ "${py%$'\n'*}" = "$ts" ] && pass "prefilter identical in the plugin" \
  || fail "prefilter differs: guard '${py%$'\n'*}' plugin '$ts'"
ts="$(sed -n 's/^const STAMP_DIR = "\(.*\)"$/\1/p' "$PLUGIN")"
[ -n "$ts" ] && [ "${py##*$'\n'}" = "$ts" ] && grep -qF 'includes(STAMP_DIR)' "$PLUGIN" \
  && pass "plugin also judges a call run inside the stamp directory" \
  || fail "the plugin does not send a call run inside '${py##*$'\n'}' to the guard"
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
