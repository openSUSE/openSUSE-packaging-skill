#!/bin/bash
# test-pool-pr.sh — proves scripts/pool-pr.sh creates or moves a pool PR only
# behind a green target-gate.sh, and that leap-sync.sh syncs and builds but
# never pushes. Copies of both scripts run next to a fake target-gate.sh, with
# fake curl and tea and a git wrapper on PATH that record every network write
# and stub push and git-lfs; leap-sync.sh clones a local forge through
# url.insteadOf. All offline. Each negative case trips exactly one branch and
# asserts its message. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
SK="$REPO/skills/opensuse-packaging/scripts"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
REALGIT="$(command -v git)" || { echo "FAIL: git not found"; exit 1; }
# Not $TMPDIR: leap-sync.sh refuses a --dir under /tmp, and that is where it may point.
work="$(mktemp -d /var/tmp/test-pool-pr.XXXXXX)"; trap 'rm -rf "$work"' EXIT
S="$work/scripts"; EV="$work/events"
mkdir -p "$S" "$work/bin" "$work/py" "$work/home/.config/tea" "$work/forge/pool"
cp "$SK/pool-pr.sh" "$SK/leap-sync.sh" "$S/"

# --- fakes -------------------------------------------------------------------
cat > "$S/target-gate.sh" <<'EOF'
#!/bin/bash
printf 'gate %s\n' "$*" >> "$EV"
[ -z "${FAKE_GATE_COMMIT:-}" ] || git -C "$1" commit -q --allow-empty -m moved
exit "${FAKE_GATE_RC:-0}"
EOF
cat > "$work/bin/git" <<'EOF'
#!/bin/bash
printf 'git %s\n' "$*" >> "$ARGV"
a=("$@"); i=0
while [ $i -lt ${#a[@]} ]; do
  case "${a[$i]}" in -C|-c) i=$((i+2));; -*) i=$((i+1));; *) break;; esac
done
sub=${a[$i]:-}; nxt=${a[$((i+1))]:-}
# FAKE_GIT_FAIL="<sub>" or "<sub> <next>": that one git call fails.
if [ -n "${FAKE_GIT_FAIL:-}" ] && { [ "$FAKE_GIT_FAIL" = "$sub" ] || [ "$FAKE_GIT_FAIL" = "$sub $nxt" ]; }; then
  echo "fake git: $FAKE_GIT_FAIL failed" >&2; exit 1
fi
case "$sub" in
  push) printf 'push %s\n' "$*" >> "$EV"
        # What the credential helper answers, and the mode of its directory and
        # of every file in it that holds the token.
        if [ -n "${GIT_ASKPASS:-}" ]; then
          sd=$(dirname "$GIT_ASKPASS"); m="dir=$(stat -c %a "$sd")"
          for f in "$sd"/*; do grep -qF t0ken "$f" && m+=" ${f##*/}=$(stat -c %a "$f")"; done
          printf 'askpass user=%s pass=%s %s\n' "$("$GIT_ASKPASS" 'Username for x')" "$("$GIT_ASKPASS" 'Password for x')" "$m" >> "$EV"
        fi
        exit "${FAKE_PUSH_RC:-0}";;
  lfs) case "$nxt" in
         push) printf 'lfs-push %s\n' "$*" >> "$EV"; exit 0;;
         fsck) exit "${FAKE_FSCK_RC:-0}";;
         ls-files) [ -z "${FAKE_OID:-}" ] || echo "$FAKE_OID * foo-2.0.tar.gz"; exit 0;;
         fetch) printf 'lfs-fetch %s\n' "$*" >> "$EV"
                # As git-lfs does: `fetch [REMOTE [REF...]]`, each REF resolved
                # right here by rev-parse, HEAD when none is named.
                refs=(); n=0
                for x in "${a[@]:$((i+2))}"; do
                  case "$x" in -*) continue;; esac
                  n=$((n+1)); [ $n = 1 ] || refs+=("$x")
                done
                [ ${#refs[@]} -gt 0 ] || refs=(HEAD)
                for x in "${refs[@]}"; do
                  printf 'lfs-fetch-tree %s\n' "$("$REALGIT" rev-parse -q --verify "$x^{tree}")" >> "$EV"
                done
                exit 0;;
         checkout) printf 'lfs-checkout %s\n' "$*" >> "$EV"; exit 0;;
         *) exit 0;;
       esac;;
esac
exec "$REALGIT" "$@"
EOF
cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$ARGV"
m=GET; url=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m=$2; shift 2;;
    -d) data=$2; shift 2;;
    -H) h=$2; [ "${h#@}" = "$h" ] || h=$(cat "${h#@}"); printf 'hdr %s\n' "$h" >> "$EV"; shift 2;;
    --max-time) shift 2;;
    -*) shift;;
    *) url=$1; shift;;
  esac
done
printf 'curl %s %s %s\n' "$m" "$url" "$data" >> "$EV"
[ "${FAKE_CURL_FAIL:-}" = "$m" ] && { echo "curl: (6) Could not resolve host" >&2; exit 6; }
case "$m" in
  # FAKE_PRS_ENDLESS: 30 full pages, past pool-pr.sh's cap, so a lost cap shows
  # as a PR opened rather than a hang.
  GET) p=${url##*page=}
       [ -n "${FAKE_PRS_ENDLESS:-}" ] && [ "$p" -le 30 ] 2>/dev/null && { cat "$FAKE_PRS_ENDLESS"; exit 0; }
       case "$url" in
         *page=1|*limit=50) cat "${FAKE_PRS:-$EMPTY}";;
         *page=2) cat "${FAKE_PRS2:-$EMPTY}";;
         *) cat "$EMPTY";;
       esac;;
  POST) if [ -n "${FAKE_RESP:-}" ]; then echo "$FAKE_RESP"
        else echo '{"number": 12, "html_url": "https://src.opensuse.org/pool/foo/pulls/12"}'; fi;;
  PATCH) n=${url##*/}; echo "{\"number\": $n, \"html_url\": \"https://src.opensuse.org/pool/foo/pulls/$n\"}";;
esac
EOF
cat > "$work/bin/tea" <<'EOF'
#!/bin/bash
printf 'tea %s\n' "$*" >> "$ARGV"
printf 'tea %s\n' "$*" >> "$EV"
[ -z "${FAKE_TEA_OUT:-}" ] || echo "$FAKE_TEA_OUT" >&2
exit "${FAKE_TEA_RC:-0}"
EOF
# Only records argv: every command line the scripts run is checked for the token.
cat > "$work/bin/python3" <<'EOF'
#!/bin/bash
printf 'python3 %s\n' "$*" >> "$ARGV"
exec "$REALPY" "$@"
EOF
REALPY="$(command -v python3)" || { echo "FAIL: python3 not found"; exit 1; }
chmod +x "$S"/*.sh "$work/bin"/*
# JSON is YAML: the stub lets the scripts' tea-config loader run without PyYAML.
printf 'import json\n\n\ndef safe_load(s):\n    return json.loads(s if isinstance(s, str) else s.read())\n' > "$work/py/yaml.py"
TEACONF='{"logins": [{"name": "src.opensuse.org", "token": "t0ken", "user": "tester"}]}'
printf '%s\n' "$TEACONF" > "$work/home/.config/tea/config.yml"
mkdir -p "$work/home-nouser/.config/tea"
printf '%s\n' '{"logins": [{"name": "src.opensuse.org", "token": "t0ken", "user": ""}]}' > "$work/home-nouser/.config/tea/config.yml"
# The file tea writes, read with no PyYAML importable.
mkdir -p "$work/home-yaml/.config/tea" "$work/noyaml"
printf 'raise ImportError("no PyYAML here")\n' > "$work/noyaml/yaml.py"
cat > "$work/home-yaml/.config/tea/config.yml" <<'EOF'
logins:
    - name: git.example.org
      url: https://git.example.org
      token: not-this-one
      user: someone
    - name: src.opensuse.org
      url: https://src.opensuse.org
      token: t0ken
      default: true
      ssh_agent: false
      user: tester
preferences:
    editor: false
    flag_defaults:
        remote: ""
EOF
EMPTY="$work/empty.json"; echo '[]' > "$EMPTY"
ARGV="$work/argv"
# Token files must not rely on the caller's umask.
umask 022
export EV ARGV REALGIT REALPY EMPTY
export PATH="$work/bin:$PATH" PYTHONPATH="$work/py" HOME="$work/home" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
# leap-sync.sh's src.opensuse.org URLs resolve to the local forge.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$work/forge/.insteadOf" GIT_CONFIG_VALUE_0="https://src.opensuse.org/"

# prj <number> <base> <head ref> <head owner> [head full_name] [head sha] — one open PR
prj() {
  printf '{"number": %s, "base": {"ref": "%s"}, "head": {"ref": "%s", "sha": "%s", "repo": {"owner": {"login": "%s"}, "full_name": "%s"}}, "html_url": "https://src.opensuse.org/pool/foo/pulls/%s"}' \
    "$1" "$2" "$3" "${6:-}" "$4" "${5:-$4/foo}" "$1"
}
# prs <file> <prj>... — write a PR list
prs() { local f=$1 IFS=,; shift; printf '[%s]\n' "$*" > "$f"; }
n_of() { grep -cE -- "$1" "$EV"; }
at() { grep -nE -- "$1" "$EV" | head -1 | cut -d: -f1; }

# run_ <script> <name> <rc> <message> [VAR=value ...] -- [script args ...]
run_() {
  local script=$1 name=$2 rc=$3 msg=$4 envs=(); shift 4
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  : > "$EV"; : > "$ARGV"
  out="$(env ${envs[@]+"${envs[@]}"} "$S/$script" "$@" 2>&1)"; got=$?
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"
    printf '%s\n' "$out" | sed 's/^/    /'
    sed 's/^/    event: /' "$EV"
  }
}
pp() { run_ pool-pr.sh "$@"; }
ls_() { run_ leap-sync.sh "$@"; }
nowrites() {  # nothing but the gate reached the network
  [ "$(n_of '^(push|lfs-push|tea|curl) ')" = 0 ] && pass "$1: no network call after the gate" \
    || { fail "$1: network calls recorded"; sed 's/^/    event: /' "$EV"; }
}
nopush() {
  [ "$(n_of '^(push|lfs-push) |^curl (POST|PATCH) ')" = 0 ] && pass "$1: nothing pushed, no PR written" \
    || { fail "$1: push or PR write recorded"; sed 's/^/    event: /' "$EV"; }
}
notoken() {  # the token reached no command line, and did reach curl's header
  ! grep -qF t0ken "$ARGV" && grep -qx 'hdr Authorization: token t0ken' "$EV" \
    && pass "$1: token on no command line, sent as a header from a file" \
    || { fail "$1: token on a command line, or no auth header"; grep -F t0ken "$ARGV" | sed 's/^/    argv: /'; }
}

# mkclone <dir> [upstream branch] [origin url] — a pool clone one commit ahead of its upstream
mkclone() {
  local d=$1 b=${2:-leap-16.0} url=${3:-https://src.opensuse.org/pool/foo.git}
  "$REALGIT" init -q -b "$b" "$d" && "$REALGIT" -C "$d" commit -q --allow-empty -m base \
    && "$REALGIT" -C "$d" remote add origin "$url" \
    && "$REALGIT" -C "$d" update-ref "refs/remotes/origin/$b" HEAD \
    && "$REALGIT" -C "$d" branch -q -u "origin/$b" \
    && printf 'Name: foo\nVersion: 2.0\n' > "$d/foo.spec" && "$REALGIT" -C "$d" add foo.spec \
    && "$REALGIT" -C "$d" commit -q -m "Update to 2.0" -m "Synced body." \
    || { echo "FAIL: could not build the clone fixture $d"; exit 1; }
}

# ============================ pool-pr.sh ======================================
C="$work/c1"; mkclone "$C"
SHA=$("$REALGIT" -C "$C" rev-parse HEAD); NEWHEAD="leap-16.0-${SHA:0:12}"
PREV=$("$REALGIT" -C "$C" rev-parse HEAD~1); TREE=$("$REALGIT" -C "$C" rev-parse 'HEAD^{tree}')
OID=4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
P="$work/prs.json"; P2="$work/prs2.json"

pp help 0 "Exit:" -- --help
pp no-dir 2 "Usage: pool-pr.sh DIR" --

# The gate: any non-zero verdict stops before the first network call.
pp gate-no-stamp 7 "no green target build + PASS review for tree" FAKE_GATE_RC=3 -- "$C"
nowrites gate-no-stamp
[ "$(n_of '^gate ')" = 1 ] && pass "gate-no-stamp: target-gate.sh ran in check mode on DIR" \
  || fail "gate-no-stamp: target-gate.sh was not called exactly once"
grep -qx "gate $C" "$EV" && pass "gate-no-stamp: gate called as 'target-gate.sh DIR'" || fail "gate-no-stamp: gate argv was $(head -1 "$EV")"
pp gate-red 7 "nothing pushed" FAKE_GATE_RC=1 -- "$C"
nowrites gate-red
pp gate-refused 7 "(target-gate.sh exit 2)" FAKE_GATE_RC=2 -- "$C"
nowrites gate-refused
C2="$work/c2"; mkclone "$C2"
pp head-moved 7 "HEAD moved while target-gate.sh ran" FAKE_GATE_COMMIT=1 -- "$C2"
nowrites head-moved

# Local refusals, before the gate or the network.
C3="$work/c3"; mkclone "$C3" leap-16.0 https://example.invalid/foo.git
pp origin-not-pool 2 "not src.opensuse.org/pool/<pkg>" -- "$C3"
[ "$(n_of .)" = 0 ] && pass "origin-not-pool: gate not even consulted" || fail "origin-not-pool: events recorded"
C4="$work/c4"; mkclone "$C4" factory
pp upstream-not-leap 2 "tracks 'origin/factory', not origin/leap-16.x" -- "$C4"
pp lfs-objects-missing 2 "missing or corrupt here" FAKE_FSCK_RC=1 -- "$C"
nowrites lfs-objects-missing
pp no-tea-login 2 "no src.opensuse.org token" "HOME=$work/nohome" -- "$C"
nowrites no-tea-login
pp no-tea-user 2 "could not determine your src.opensuse.org username" "HOME=$work/home-nouser" -- "$C"
nowrites no-tea-user
pp lfs-ls-files-fails 2 "git lfs ls-files failed" "FAKE_GIT_FAIL=lfs ls-files" -- "$C"
nowrites lfs-ls-files-fails
pp title-needs-value 2 "--title needs a value" -- "$C" --title
pp unknown-option 2 "unknown option --bogus" -- --bogus "$C"
pp two-dirs 2 "one DIR only" -- "$C" "$C2"
pp body-file-unreadable 2 "cannot read --body-file" -- --body-file "$work/no-such-body" "$C"
nowrites body-file-unreadable
mkdir -p "$work/plain"
pp not-a-checkout 2 "not a git checkout with an origin remote" -- "$work/plain"
# An unborn branch that still tracks origin/leap-16.0.
C5="$work/c5"; mkclone "$C5"
"$REALGIT" -C "$C5" symbolic-ref HEAD refs/heads/unborn && "$REALGIT" -C "$C5" config branch.unborn.remote origin \
  && "$REALGIT" -C "$C5" config branch.unborn.merge refs/heads/leap-16.0 || { echo "FAIL: could not build the unborn fixture"; exit 1; }
pp no-head-commit 2 "no HEAD commit" -- "$C5"

# The open-PR lookup: a failure never reads as "no PR".
pp pr-list-network 6 "could not list open PRs" FAKE_CURL_FAIL=GET -- "$C"
nopush pr-list-network
echo '{"message": "token is required"}' > "$work/bad.json"
pp pr-list-unparseable 6 "cannot rule out a duplicate" "FAKE_PRS=$work/bad.json" -- "$C"
nopush pr-list-unparseable
prs "$P" "$(prj 3 leap-16.0 their-branch someone)"
pp others-pr-on-base 2 "an open PR by someone already targets leap-16.0" "FAKE_PRS=$P" -- "$C"
nopush others-pr-on-base
prs "$P" "$(prj 3 leap-16.1 x someone)"; prs "$P2" "$(prj 9 leap-16.0 their-branch someone)"
pp page-two-is-read 2 "an open PR by someone already targets leap-16.0" "FAKE_PRS=$P" "FAKE_PRS2=$P2" -- "$C"
prs "$P" "$(prj 3 leap-16.0 a tester)" "$(prj 4 leap-16.0 b tester)"
pp two-of-yours 2 "open PRs of yours on leap-16.0: #3, #4" "FAKE_PRS=$P" -- "$C"
nopush two-of-yours
# One head branch feeding PRs to two bases (the reused-head defect).
prs "$P" "$(prj 3 leap-16.0 shared tester)" "$(prj 4 leap-16.1 shared tester)"
pp head-reused-other-base 2 "head branch shared already heads PR #4 to leap-16.1" "FAKE_PRS=$P" -- "$C"
nopush head-reused-other-base
prs "$P" "$(prj 4 leap-16.1 "$NEWHEAD" tester)"
pp new-head-taken-other-base 2 "head branch $NEWHEAD already heads PR #4 to leap-16.1" "FAKE_PRS=$P" -- "$C"
nopush new-head-taken-other-base
# The same branch name in someone else's fork is no clash.
prs "$P" "$(prj 4 leap-16.1 "$NEWHEAD" someone)"
pp others-head-same-name 0 "PR opened" "FAKE_PRS=$P" -- "$C"
prs "$P" "$(prj 3 leap-16.1 x someone)"
pp pr-list-endless 6 "does not end" "FAKE_PRS_ENDLESS=$P" -- "$C"
nopush pr-list-endless
echo '[1]' > "$work/odd.json"
pp pr-list-odd-entry 6 "could not read the open-PR list" "FAKE_PRS=$work/odd.json" -- "$C"
nopush pr-list-odd-entry

# Write failures stop the flow and say so.
pp push-fails 6 "push to tester/foo:$NEWHEAD failed" FAKE_PUSH_RC=1 -- "$C"
[ "$(n_of '^curl (POST|PATCH) ')" = 0 ] && pass "push-fails: no PR opened over a failed push" || fail "push-fails: PR written"
pp post-rejected 6 "PR POST rejected" 'FAKE_RESP={"message": "pull request already exists"}' -- "$C"
pp post-network 6 "PR POST failed (network?)" FAKE_CURL_FAIL=POST -- "$C"
pp lfs-push-fails 6 "LFS object push to tester/foo failed" "FAKE_OID=$OID" "FAKE_GIT_FAIL=lfs push" -- "$C"
nopush lfs-push-fails
# A fork error is shown, then the push decides; an existing fork is not an error.
pp fork-error-surfaced 0 "tea repo fork failed: fork quota exceeded" FAKE_TEA_RC=1 "FAKE_TEA_OUT=fork quota exceeded" -- "$C"
for m in "already exists" "repository is already forked"; do
  pp "fork-exists ($m)" 0 "PR opened" FAKE_TEA_RC=1 "FAKE_TEA_OUT=$m" -- "$C"
  ! grep -qF "tea repo fork failed" <<<"$out" && pass "fork-exists ($m): reused silently" || fail "fork-exists ($m): reported as a failure"
done
mkdir -p "$work/sec"
pp token-dir-removed 0 "PR opened" "TMPDIR=$work/sec" -- "$C"
[ -z "$(ls -A "$work/sec")" ] && pass "token-dir-removed: no token file outlives the run" || fail "token-dir-removed: left $(ls -A "$work/sec")"
pp token-no-pyyaml 0 "PR opened" "HOME=$work/home-yaml" "PYTHONPATH=$work/noyaml" -- "$C"
grep -q '^askpass user=tester pass=t0ken ' "$EV" && notoken token-no-pyyaml \
  || { fail "token-no-pyyaml: tea's config not read without PyYAML"; grep '^askpass' "$EV" | sed 's/^/    event: /'; }

# Happy path: gate, then exactly one push, then exactly one POST.
pp open-new 0 "PR opened: https://src.opensuse.org/pool/foo/pulls/12" "FAKE_OID=$OID" -- "$C"
g=$(at '^gate '); lp=$(at '^lfs-push '); pu=$(at '^push '); po=$(at '^curl POST ')
[ "$(n_of '^push ')" = 1 ] && [ "$(n_of '^curl POST ')" = 1 ] && [ "$(n_of '^curl PATCH ')" = 0 ] \
  && pass "open-new: exactly one push and one POST" || fail "open-new: push/POST counts wrong"
[ -n "$g" ] && [ -n "$lp" ] && [ -n "$pu" ] && [ -n "$po" ] && [ "$g" -lt "$lp" ] && [ "$lp" -lt "$pu" ] && [ "$pu" -lt "$po" ] \
  && pass "open-new: order is gate, LFS objects, ref, POST" || { fail "open-new: wrong order"; sed 's/^/    event: /' "$EV"; }
grep -q "^push .* --no-verify fork $SHA:refs/heads/$NEWHEAD\$" "$EV" && ! grep -q '^push .*--force' "$EV" \
  && pass "open-new: HEAD's commit pushed to <base>-<sha12>, no force" || fail "open-new: push argv $(grep '^push' "$EV")"
grep -q "^lfs-push .*--object-id fork $OID\$" "$EV" && pass "open-new: the tree's LFS objects pushed by id" || fail "open-new: lfs push argv"
grep -qF "\"head\": \"tester:$NEWHEAD\", \"base\": \"leap-16.0\", \"title\": \"Update to 2.0\", \"body\": \"Synced body.\"" "$EV" \
  && pass "open-new: POST names head, base, and HEAD's subject/body" || fail "open-new: POST payload $(grep POST "$EV")"
grep -q "^tea repo fork --repo pool/foo" "$EV" && pass "open-new: fork ensured" || fail "open-new: no tea fork"
grep -qF "sr-status.py --pr pool/foo#12" <<<"$out" && pass "open-new: next step printed" || fail "open-new: no next step"
grep -qE '^askpass user=tester pass=t0ken dir=700( [^ =]+=600)+$' "$EV" \
  && pass "open-new: git gets the token from the helper; token files 0600 in a 0700 directory" \
  || fail "open-new: $(grep '^askpass' "$EV" | sed 's/pass=[^ ]*/pass=.../')"
notoken open-new

# Your open PR on the base, HEAD a fix on top of its head: force-push onto its
# head, PATCH the title only.
prs "$P" "$(prj 5 leap-16.0 leap-16.0-sync-1.0 tester "" "$PREV")" "$(prj 6 leap-16.1 other-head tester)"
pp update-existing 0 "PR updated: https://src.opensuse.org/pool/foo/pulls/5" "FAKE_PRS=$P" -- --title "Update to 2.0 (refresh)" "$C"
[ "$(n_of '^push ')" = 1 ] && [ "$(n_of '^curl PATCH .*/pulls/5 ')" = 1 ] && [ "$(n_of '^curl POST ')" = 0 ] && [ "$(n_of '^tea ')" = 0 ] \
  && pass "update-existing: one push, one PATCH, no POST, no fork" || { fail "update-existing: wrong calls"; sed 's/^/    event: /' "$EV"; }
grep -q "^push .* --force fork $SHA:refs/heads/leap-16.0-sync-1.0\$" "$EV" && [ "$(at '^push ')" -lt "$(at '^curl PATCH ')" ] \
  && pass "update-existing: force-pushed onto the PR's own head, before the PATCH" || fail "update-existing: push argv $(grep '^push' "$EV")"
grep -qF '{"title": "Update to 2.0 (refresh)"}' "$EV" && pass "update-existing: PATCH carries the title, keeps the body" || fail "update-existing: PATCH payload $(grep PATCH "$EV")"
notoken update-existing
prs "$P" "$(prj 5 leap-16.0 sync tester tester/foo-renamed "$PREV")"
printf 'New body.\n' > "$work/body.txt"
pp update-own-head-repo 0 "PR updated" "FAKE_PRS=$P" -- --body-file "$work/body.txt" "$C"
[ "$("$REALGIT" -C "$C" config --get remote.fork.url)" = "https://src.opensuse.org/tester/foo-renamed.git" ] \
  && pass "update-own-head-repo: pushes to the PR's head repo" || fail "update-own-head-repo: fork url $("$REALGIT" -C "$C" config --get remote.fork.url)"
grep -qF '"body": "New body."' "$EV" && pass "update-own-head-repo: --body-file replaces the body" || fail "update-own-head-repo: body not sent"
prs "$P" "$(prj 5 leap-16.0 sync tester "" "$PREV" | sed 's/, "full_name": "[^"]*"//')"
pp update-no-head-repo 0 "PR updated" "FAKE_PRS=$P" -- "$C"
[ "$("$REALGIT" -C "$C" config --get remote.fork.url)" = "https://src.opensuse.org/tester/foo.git" ] \
  && pass "update-no-head-repo: falls back to your fork" || fail "update-no-head-repo: fork url $("$REALGIT" -C "$C" config --get remote.fork.url)"

# Your open PR's head is not in HEAD (say a CVE backport, then a sync): pushing
# would drop its commits, so that takes --replace, which resets the body too.
SIDE=$("$REALGIT" -C "$C" commit-tree -p "$PREV" -m "CVE backport" "$PREV^{tree}") || { echo "FAIL: side commit"; exit 1; }
prs "$P" "$(prj 5 leap-16.0 leap-16.0-cve tester "" "$SIDE")"
pp update-drops-commits 2 "does not contain ${SIDE:0:12}, the head of your open PR #5" "FAKE_PRS=$P" -- "$C"
nopush update-drops-commits
prs "$P" "$(prj 5 leap-16.0 leap-16.0-cve tester "" 0123456789abcdef0123456789abcdef01234567)"
pp update-head-not-here 2 "does not contain 0123456789ab" "FAKE_PRS=$P" -- "$C"
nopush update-head-not-here
prs "$P" "$(prj 5 leap-16.0 leap-16.0-cve tester)"
pp update-head-unlisted 2 "pushing would drop its commits" "FAKE_PRS=$P" -- "$C"
nopush update-head-unlisted
prs "$P" "$(prj 5 leap-16.0 leap-16.0-cve tester "" "$SIDE")"
pp update-replace 0 "PR updated (head replaced): https://src.opensuse.org/pool/foo/pulls/5" "FAKE_PRS=$P" -- --replace "$C"
grep -q "^push .* --force fork $SHA:refs/heads/leap-16.0-cve\$" "$EV" && [ "$(n_of '^curl PATCH .*/pulls/5 ')" = 1 ] \
  && pass "update-replace: HEAD force-pushed onto the PR's head, one PATCH" || { fail "update-replace: wrong calls"; sed 's/^/    event: /' "$EV"; }
grep -qF "{\"title\": \"Update to 2.0\", \"body\": \"Synced body.\\n\\nHead replaced by ${SHA:0:12} (tree ${TREE:0:12}); the commits of the previous head ${SIDE:0:12} are no longer in this PR.\"}" "$EV" \
  && pass "update-replace: the stale body is replaced by one naming the new head" || fail "update-replace: PATCH payload $(grep PATCH "$EV")"
pp update-replace-body-file 0 "PR updated (head replaced)" "FAKE_PRS=$P" -- --replace --body-file "$work/body.txt" "$C"
grep -qF '{"title": "Update to 2.0", "body": "New body."}' "$EV" && pass "update-replace-body-file: --body-file is the new body" || fail "update-replace-body-file: PATCH payload $(grep PATCH "$EV")"
prs "$P" "$(prj 5 leap-16.0 leap-16.0-sync-1.0 tester "" "$PREV")"
pp replace-not-needed 0 "PR updated: " "FAKE_PRS=$P" -- --replace "$C"
grep -qF '{"title": "Update to 2.0"}' "$EV" && pass "replace-not-needed: a fix on top keeps the body" || fail "replace-not-needed: PATCH payload $(grep PATCH "$EV")"

# A symlinked copy runs the target-gate.sh beside the real script, never one
# placed beside the link.
L="$work/lnk"; mkdir -p "$L"
ln -s "$S/pool-pr.sh" "$L/pool-pr.sh" && ln -s "$S/leap-sync.sh" "$L/leap-sync.sh" || { echo "FAIL: symlinks"; exit 1; }
cat > "$L/target-gate.sh" <<'EOF'
#!/bin/bash
printf 'decoy-gate %s\n' "$*" >> "$EV"
exit 0
EOF
chmod +x "$L/target-gate.sh"
run_ ../lnk/pool-pr.sh symlinked-pool-pr 7 "(target-gate.sh exit 3)" FAKE_GATE_RC=3 -- "$C"
[ "$(n_of '^decoy-gate')" = 0 ] && [ "$(n_of '^gate ')" = 1 ] \
  && pass "symlinked-pool-pr: the real target-gate.sh decided" || fail "symlinked-pool-pr: gate events $(grep gate "$EV")"
nowrites symlinked-pool-pr

# Static: no network write can precede the gate call.
awk '!/^[[:space:]]*#/ {
       if (!g && /target-gate\.sh" /) g = NR
       if (!w && (/git .*[[:space:]]push([[:space:]]|$)/ || /lfs push/ || /(^|[^[:alnum:]_-])curl[[:space:]]/ || /tea[[:space:]]+(pr|pulls|repo|api)/)) w = NR
     } END { exit !(g && w && g < w) }' "$SK/pool-pr.sh" \
  && pass "static: pool-pr.sh calls target-gate.sh before any push, curl or tea" \
  || fail "static: pool-pr.sh has a push/curl/tea before (or without) the target-gate.sh call"

# ============================ leap-sync.sh ====================================
# mkforge <pkg> <branch=version>... — a bare pool/<pkg> with a factory branch at
# 2.0 and unrelated-history product branches, as the OBS import left them.
# FVER overrides the factory version; STALE names a file only the product
# branches carry.
mkforge() {
  local pkg=$1 src="$work/src-$1" bv; shift
  "$REALGIT" init -q -b factory "$src" \
    && printf 'Name: %s\nVersion: %s\n' "$pkg" "${FVER-2.0}" > "$src/$pkg.spec" && "$REALGIT" -C "$src" add -A \
    && "$REALGIT" -C "$src" commit -q -m factory || { echo "FAIL: forge $pkg"; exit 1; }
  for bv in "$@"; do
    "$REALGIT" -C "$src" checkout -q --orphan "${bv%=*}" \
      && printf 'Name: %s\nVersion: %s\n' "$pkg" "${bv#*=}" > "$src/$pkg.spec" \
      && { [ -z "${STALE:-}" ] || echo old > "$src/$STALE"; } && "$REALGIT" -C "$src" add -A \
      && "$REALGIT" -C "$src" commit -q -m "${bv%=*}" || { echo "FAIL: forge $pkg ${bv%=*}"; exit 1; }
  done
  "$REALGIT" clone -q --bare "$src" "$work/forge/pool/$pkg.git" || { echo "FAIL: forge $pkg bare"; exit 1; }
}
STALE=dropped.patch mkforge foo leap-16.0=1.0 leap-16.1=1.5
mkforge bar leap-16.0=2.0
STALE=leap-only.patch mkforge samever leap-16.0=2.0
FVER='' mkforge nover leap-16.0=1.0
mkforge nofac leap-16.0=1.0
"$REALGIT" -C "$work/forge/pool/nofac.git" update-ref -d refs/heads/factory || { echo "FAIL: forge nofac"; exit 1; }
FTREE=$("$REALGIT" -C "$work/forge/pool/foo.git" rev-parse 'factory^{tree}')
d() { mkdir -p "$work/$1" && printf '%s' "$work/$1"; }

D=$(d ls1); W="$D/leap-16.0/foo"
ls_ sync-build-green 0 "target build GREEN" -- --dir "$D" foo
grep -qx "gate $W --build" "$EV" && pass "sync-build-green: native build of the worktree" || fail "sync-build-green: gate argv $(grep '^gate' "$EV")"
nopush sync-build-green
[ "$(n_of '^tea ')" = 0 ] && pass "sync-build-green: no fork, no tea" || fail "sync-build-green: tea called"
[ "$("$REALGIT" -C "$W" rev-parse 'HEAD^{tree}')" = "$FTREE" ] && pass "sync-build-green: worktree tree == factory tree" || fail "sync-build-green: tree differs from factory"
[ "$("$REALGIT" -C "$W" rev-parse --abbrev-ref '@{upstream}')" = origin/leap-16.0 ] && pass "sync-build-green: tracks origin/leap-16.0" || fail "sync-build-green: wrong upstream"
[ -z "$("$REALGIT" -C "$W" status --porcelain --ignored --untracked-files=all)" ] && pass "sync-build-green: worktree clean" || fail "sync-build-green: worktree dirty"
lf=$(at '^lfs-fetch '); lc=$(at '^lfs-checkout '); g=$(at '^gate ')
grep -qx "lfs-fetch-tree $FTREE" "$EV" && [ -n "$lc" ] && [ -n "$g" ] && [ "$lf" -lt "$lc" ] && [ "$lc" -lt "$g" ] \
  && pass "sync-build-green: the factory tree's LFS objects fetched and checked out before the build" \
  || { fail "sync-build-green: LFS fetch/checkout missing or out of order"; sed 's/^/    event: /' "$EV"; }
grep -qF "pool-pr.sh $W" <<<"$out" && grep -qF "target-gate.sh $W --review FILE" <<<"$out" \
  && pass "sync-build-green: prints the review and pool-pr.sh steps" || fail "sync-build-green: next steps missing"
notoken sync-build-green
# The two halves meet: the worktree leap-sync.sh leaves is what pool-pr.sh takes.
pp sync-then-pool-pr 0 "PR opened" -- "$W"
grep -qF '"base": "leap-16.0", "title": "Update to 2.0 (sync leap-16.0 with Factory)"' "$EV" \
  && pass "sync-then-pool-pr: PR opened from the synced worktree" || fail "sync-then-pool-pr: POST payload $(grep POST "$EV")"
ls_ second-branch-reuses-clone 0 "target build GREEN" -- --dir "$D" foo leap-16.1
[ "$("$REALGIT" -C "$D/pool/foo" worktree list | grep -c "$D/leap-16")" = 2 ] \
  && pass "second-branch-reuses-clone: one clone, a worktree per branch" || fail "second-branch-reuses-clone: worktrees $("$REALGIT" -C "$D/pool/foo" worktree list)"
ls_ worktree-exists 2 "already exists" -- --dir "$D" foo
grep -qF "branch -D leap-16.0" <<<"$out" && pass "worktree-exists: removing it names the branch too" || fail "worktree-exists: no branch -D in the advice"

D=$(d ls2)
ls_ remote-pending 8 "remote build pending" FAKE_GATE_RC=3 -- --dir "$D" --remote foo
grep -qx "gate $D/leap-16.0/foo --remote" "$EV" && pass "remote-pending: OBS build of the worktree" || fail "remote-pending: gate argv $(grep '^gate' "$EV")"
D=$(d ls3)
ls_ build-red 7 "target build RED" FAKE_GATE_RC=1 -- --dir "$D" foo
[ -d "$D/leap-16.0/foo" ] && pass "build-red: the red tree stays for the fix" || fail "build-red: worktree removed"
grep -qF "(not leap-sync.sh)" <<<"$out" && pass "build-red: the fix is rebuilt by target-gate.sh, not a re-sync" || fail "build-red: no 'not leap-sync.sh' in the advice"
nopush build-red
D=$(d ls4)
ls_ gate-refused 2 "target-gate.sh stopped (exit 2" FAKE_GATE_RC=2 -- --dir "$D" foo
D=$(d ls5); prs "$P" "$(prj 3 leap-16.0 their-branch someone)"
ls_ others-pr-open 4 "an open PR already targets pool/foo:leap-16.0" "FAKE_PRS=$P" -- --dir "$D" foo
[ ! -e "$D/pool" ] && pass "others-pr-open: nothing cloned" || fail "others-pr-open: clone left behind"
D=$(d ls6); prs "$P" "$(prj 5 leap-16.0 leap-16.0-sync-1.0 tester)"
ls_ your-pr-open 0 "your open PR #5 is on another head" "FAKE_PRS=$P" -- --dir "$D" foo
grep -qF -- "--replace" <<<"$out" && pass "your-pr-open: names --replace, does not imply it" || fail "your-pr-open: no --replace hint"
D=$(d ls7)
ls_ already-in-sync 0 "already in sync (identical trees)" -- --dir "$D" bar
[ ! -e "$D/pool" ] && [ "$(n_of '^gate ')" = 0 ] && pass "already-in-sync: fresh clone removed, no build" || fail "already-in-sync: clone left or gate ran"
D=$(d ls8)
ls_ new-to-leap 3 "no 'leap-16.2' branch" -- --dir "$D" foo leap-16.2
ls_ slfo-refused 2 "'slfo-main' is not a leap-16.x branch" -- --dir "$D" foo slfo-main
ls_ refresh-moved 2 "--refresh is gone" -- --refresh foo
T=$(mktemp -d /tmp/test-pool-pr.XXXXXX)
ls_ dir-under-tmp 2 "is under /tmp" -- --dir "$T" foo
rmdir "$T"
ls_ help 0 "Exit codes:" -- --help
ls_ dir-needs-value 2 "--dir needs a value" -- foo --dir
ls_ unknown-option 2 "unknown option --bogus" -- --bogus foo
ls_ no-pkg 2 "Usage: leap-sync.sh" --
ls_ extra-arg 2 "Usage: leap-sync.sh" -- --dir "$(d ls9)" foo leap-16.0 extra
ls_ dir-missing 2 "--dir: no such directory" -- --dir "$work/no-such-dir" foo

# Refusals before the clone: nothing is left in --dir.
D=$(d ls10)
ls_ no-tea-login 2 "no src.opensuse.org token" "HOME=$work/nohome" -- --dir "$D" foo
ls_ no-tea-user 2 "could not determine your src.opensuse.org username" "HOME=$work/home-nouser" -- --dir "$D" foo
ls_ pr-list-network 6 "could not query open PRs" FAKE_CURL_FAIL=GET -- --dir "$D" foo
ls_ pr-list-unparseable 6 "cannot rule out a duplicate" "FAKE_PRS=$work/bad.json" -- --dir "$D" foo
ls_ pool-repo-unreachable 6 "could not reach pool/nosuch" -- --dir "$D" nosuch
ls_ no-factory-branch 5 "has no 'factory' branch" -- --dir "$D" nofac
[ -z "$(ls -A "$D")" ] && pass "refusals before the clone: nothing left in --dir" || fail "refusals before the clone: left $(ls -A "$D")"
D=$(d ls11); prs "$P" "$(prj 3 leap-16.1 their-branch someone)"
ls_ others-pr-other-branch 0 "target build GREEN" "FAKE_PRS=$P" -- --dir "$D" foo

# Whatever is already at D/pool/<pkg> is never replaced or removed.
D=$(d ls12); mkdir -p "$D/pool/foo" && echo mine > "$D/pool/foo/notes"
ls_ clone-path-not-git 2 "exists and is not a git clone" -- --dir "$D" foo
[ -f "$D/pool/foo/notes" ] && pass "clone-path-not-git: left untouched" || fail "clone-path-not-git: removed"
D=$(d ls13); "$REALGIT" init -q "$D/pool/foo" && "$REALGIT" -C "$D/pool/foo" remote add origin "file://$work/elsewhere/foo.git"
ls_ clone-foreign-origin 2 "is not a clone of pool/foo" -- --dir "$D" foo
[ -d "$D/pool/foo/.git" ] && pass "clone-foreign-origin: left untouched" || fail "clone-foreign-origin: removed"
D=$(d ls14); "$REALGIT" clone -q "https://src.opensuse.org/pool/foo.git" "$D/pool/foo" || { echo "FAIL: pre-clone"; exit 1; }
ls_ fetch-fails 6 "could not fetch pool/foo" FAKE_GIT_FAIL=fetch -- --dir "$D" foo
[ -d "$D/pool/foo/.git" ] && pass "fetch-fails: your existing clone is kept" || fail "fetch-fails: existing clone removed"

# Failures between the clone and the build: the half-made sync is undone.
D=$(d ls15)
ls_ clone-fails 6 "could not clone pool/foo" FAKE_GIT_FAIL=clone -- --dir "$D" foo
D=$(d ls16)
ls_ no-factory-version 2 "could not read factory version" -- --dir "$D" nover
D=$(d ls17)
ls_ worktree-add-fails 2 "could not add the leap-16.0 worktree" "FAKE_GIT_FAIL=worktree add" -- --dir "$D" foo
D=$(d ls18)
ls_ content-sync-fails 2 "content sync of leap-16.0 to factory failed" FAKE_GIT_FAIL=commit -- --dir "$D" foo
[ -z "$(ls -A "$D")" ] && pass "content-sync-fails: worktree and fresh clone removed" || fail "content-sync-fails: left $(ls -A "$D")"
D=$(d ls19)
ls_ lfs-fetch-fails 2 "git lfs fetch/checkout failed" "FAKE_GIT_FAIL=lfs fetch" -- --dir "$D" foo
[ "$(n_of '^gate ')" = 0 ] && pass "lfs-fetch-fails: no build without the LFS objects" || fail "lfs-fetch-fails: gate ran"
D=$(d ls20)
ls_ lfs-checkout-fails 2 "git lfs fetch/checkout failed" "FAKE_GIT_FAIL=lfs checkout" -- --dir "$D" foo

# Same version, different tree: still a sync.
D=$(d ls21)
ls_ same-version-content-change 0 "target build GREEN" -- --dir "$D" samever
D=$(d ls22)
ls_ gate-pending-native 2 "target-gate.sh stopped (exit 3" FAKE_GATE_RC=3 -- --dir "$D" foo

# A reused clone keeps its local factory branch where the first clone left it,
# behind origin/factory: the LFS objects fetched must be the synced tree's.
mkforge moving leap-16.0=1.0
D=$(d ls23)
"$REALGIT" clone -q --branch factory "https://src.opensuse.org/pool/moving.git" "$D/pool/moving" \
  && "$REALGIT" -C "$work/src-moving" checkout -q factory \
  && printf 'Name: moving\nVersion: 3.0\n' > "$work/src-moving/moving.spec" \
  && "$REALGIT" -C "$work/src-moving" commit -q -am "factory moves on" \
  && "$REALGIT" -C "$work/forge/pool/moving.git" fetch -q "$work/src-moving" factory:factory \
  || { echo "FAIL: could not build the moved-factory fixture"; exit 1; }
MTREE=$("$REALGIT" -C "$work/forge/pool/moving.git" rev-parse 'factory^{tree}')
[ "$("$REALGIT" -C "$D/pool/moving" rev-parse 'factory^{tree}')" != "$MTREE" ] || { echo "FAIL: fixture: local factory is not behind"; exit 1; }
ls_ reused-clone-lfs 0 "target build GREEN" -- --dir "$D" moving
[ "$(grep '^lfs-fetch-tree ' "$EV")" = "lfs-fetch-tree $MTREE" ] && [ "$("$REALGIT" -C "$D/leap-16.0/moving" rev-parse 'HEAD^{tree}')" = "$MTREE" ] \
  && pass "reused-clone-lfs: LFS objects of the synced tree, not of the stale local factory" \
  || { fail "reused-clone-lfs: fetched for another tree"; grep '^lfs' "$EV" | sed 's/^/    event: /'; }

# The token: stdlib only, and on no command line.
D=$(d ls24); mkdir -p "$work/lsec"
ls_ token-no-pyyaml 0 "target build GREEN" "HOME=$work/home-yaml" "PYTHONPATH=$work/noyaml" "TMPDIR=$work/lsec" -- --dir "$D" foo
notoken "leap-sync token-no-pyyaml"
[ -z "$(ls -A "$work/lsec")" ] && pass "leap-sync token-no-pyyaml: no token file outlives the lookup" || fail "leap-sync token-no-pyyaml: left $(ls -A "$work/lsec")"

D=$(d ls25)
run_ ../lnk/leap-sync.sh symlinked-leap-sync 7 "target build RED" FAKE_GATE_RC=1 -- --dir "$D" foo
[ "$(n_of '^decoy-gate')" = 0 ] && pass "symlinked-leap-sync: the real target-gate.sh decided" || fail "symlinked-leap-sync: the decoy gate ran"

# Red build, fix committed, worktree removed, leap-sync re-run: the fix on the
# local leap branch must survive.
D=$(d ls26); W="$D/leap-16.0/foo"
ls_ unpushed-fixture 7 "target build RED" FAKE_GATE_RC=1 -- --dir "$D" foo
echo fix > "$W/fix.patch" && "$REALGIT" -C "$W" add fix.patch && "$REALGIT" -C "$W" commit -q -m fix \
  && FIX=$("$REALGIT" -C "$W" rev-parse HEAD) && "$REALGIT" -C "$D/pool/foo" worktree remove --force "$W" \
  || { echo "FAIL: could not build the unpushed-fix fixture"; exit 1; }
ls_ reused-clone-unpushed 2 "local branch leap-16.0 in $D/pool/foo has 2 commit(s) not on origin/leap-16.0" -- --dir "$D" foo
[ "$("$REALGIT" -C "$D/pool/foo" rev-parse -q --verify refs/heads/leap-16.0)" = "$FIX" ] && [ ! -e "$W" ] && [ "$(n_of '^gate ')" = 0 ] \
  && pass "reused-clone-unpushed: the fix is still on leap-16.0, nothing built" \
  || fail "reused-clone-unpushed: leap-16.0 at $("$REALGIT" -C "$D/pool/foo" rev-parse -q --verify refs/heads/leap-16.0), fix was $FIX"
ls_ reused-clone-compare-fails 2 "could not compare local leap-16.0 with origin/leap-16.0" FAKE_GIT_FAIL=rev-list -- --dir "$D" foo
"$REALGIT" -C "$D/pool/foo" branch -q -D leap-16.0 || { echo "FAIL: could not drop the fixture branch"; exit 1; }
ls_ reused-clone-branch-dropped 0 "target build GREEN" -- --dir "$D" foo

# Static: leap-sync.sh has no way left to push or write a PR. The long options
# are grouped so the installed pr-guard.py does not read this line as a write.
if grep -vE '^[[:space:]]*#' "$SK/leap-sync.sh" \
     | grep -nE '(^|[^[:alnum:]_-])push([^[:alnum:]_-]|$)|-X[[:space:]]*(POST|PATCH|PUT)|--(request|data)|[[:space:]]-d[[:space:]]|tea[[:space:]]+(pr|pulls|repo|api)'; then
  fail "static: leap-sync.sh still pushes or writes to the API (lines above)"
else
  pass "static: leap-sync.sh contains no push, POST/PATCH/PUT or tea call"
fi

[ $fails -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
