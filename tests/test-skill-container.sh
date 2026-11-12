#!/bin/bash
# test-skill-container.sh — contrib/container/skill-container offline: a fake
# `podman` keeps secrets as files, records every call and stands in for the
# client's container; a fake `opencode` answers `secrets` alone; osc and tea
# read made-up configs with two logins each. The launcher's own commands come
# from $tools/bin, where each real one is wrapped to check what it is given,
# the caller's opencode from $tools/userbin on the caller's PATH, whose first
# directory holds commands that must never run. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
# shellcheck disable=SC2016  # the fake commands written here expand their own variables
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SC="$HERE/../contrib/container/skill-container"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
[ -x "$SC" ] && pass "the launcher is executable" || fail "the launcher is not executable"
# The commands live outside $work: a work directory that holds one is refused.
work="$(mktemp -d)"; tools="$(mktemp -d)"; open="$(mktemp -d)"; trap 'rm -rf "$work" "$tools" "$open"' EXIT
FIX="$work/fix"; export FIX
N=sc-test

mkdir -p "$tools/bin" "$tools/userbin" "$tools/evilbin" "$FIX/secrets" "$FIX/store/volumes" "$work/home/.config" \
  "$work/ws/bin" "$work/a,b" "$work/a:b" \
  "$work/planted/ruamel" "$work/planted/osc" "$work/config/tea" "$work/config/mcp-bugzilla" "$work/run/sub"
ln -s home "$work/homelink"
ln -s "$work/ws/bin" "$tools/wslink"
# A link the agent could repoint: it lies in the work directory and leads out of it.
ln -s "$tools/userbin" "$work/ws/pathlink"
touch "$work/stamp"
# Sourced by every fake and wrapper: no command starts in the work directory,
# and none has a login or the server password in its environment or arguments.
cat > "$FIX/envcheck" <<'EOF'
case "$PWD/" in
"${FIX%/fix}/ws"/*) printf '%s\n' "${0##*/}" >> "$FIX/cwd-leak" ;;
esac
case "$(/usr/bin/env) $*" in
*SECRET[-_][0-9]*) printf '%s\n' "${0##*/}" >> "$FIX/secret-leak" ;;
esac
for _f in "$FIX"/secrets/*-server-password; do
  [ -s "$_f" ] || continue
  _pw=$(< "$_f")
  # Empty while `up` replaces it.
  [ -n "$_pw" ] || continue
  case "$(/usr/bin/env) $*" in
  *"$_pw"*) printf '%s\n' "${0##*/}" >> "$FIX/env-leak" ;;
  esac
done
EOF
# Every control character the filter drops, between two marks: the C0 set
# without tab and newline, DEL, and the C1 set as UTF-8. Builtins only.
cat > "$FIX/ctl" <<'EOF'
ctl() {
  local i o
  printf 'ctl<'
  for i in {0..8} {11..31} 127; do printf -v o '\\%03o' "$i"; printf "$o"; done
  for i in {128..159}; do printf -v o '\\302\\%03o' "$i"; printf "$o"; done
  printf '>\n'
}
EOF
cat > "$tools/bin/podman" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
PATH=/usr/bin:/bin
printf '%s\n' "$*" >> "$FIX/podman-calls"
case "$1 $2" in
"secret create")
  [ "$3" = --replace ] || exit 98
  if [ "$5" = - ]; then cat > "$FIX/secrets/$4"; else cp "$5" "$FIX/secrets/$4"; fi ;;
"secret exists") [ -f "$FIX/secrets/$3" ] ;;
"secret inspect") cat "$FIX/secrets/${!#}"; echo ;;
"info --format") case $3 in *VolumePath*) cat "$FIX/volpath" ;; *) cat "$FIX/storepath" ;; esac ;;
# Two other containers run when $FIX/others names what they write on the host.
"ps --quiet") [ ! -e "$FIX/ps-fails" ] || exit 1; [ ! -s "$FIX/others" ] || printf '%s\n' beef01 beef02 ;;
"run --detach")
  while [ $# -gt 1 ]; do
    [ "$1" = --workdir ] && printf %s "$2" > "$FIX/workdir"
    shift
  done
  # With $FIX/run-fails podman makes the container and cannot start it.
  [ ! -e "$FIX/run-fails" ] || exit 125
  # With $FIX/stops the container exits at once.
  [ -e "$FIX/stops" ] || echo true > "$FIX/running"
  echo c0ffee ;;
# The client's container: whether it got a terminal, and what a client prints.
"run --rm")
  printf '%s\n' "$*" >> "$FIX/client-calls"
  t=no; [ -t 0 ] && [ -t 1 ] && t=yes
  echo "$t" > "$FIX/client-tty"
  # A reply that tries the terminal: clipboard, title, clear, a C1 control, a
  # colour made of the filter's own marker.
  if [ -e "$FIX/escapes" ]; then
    printf 'out\033]52;c;QUJD\007\033[31mred\033[0m\033[2J\302\233x\001[35m'
    # C1 controls that are whole only once the one inside them is taken out.
    printf '\302\302\233\2332Jy\302\302\235\2350;t\302\302\234\234\r\n'
    printf 'err\033]0;title\007\033[1mbold\033[0m\n' >&2
    . "$FIX/ctl"
    ctl
    ctl >&2
    exit 7
  fi ;;
"inspect --format")
  case $3 in
  *Running*) cat "$FIX/running" ;;
  *WorkingDir*) cat "$FIX/workdir" ;;
  *Image*) cat "$FIX/image" ;;
  # What a container writes on the host, as podman prints it for this format alone.
  *Mounts*)
    [ "$3" = '{{range .Mounts}}{{if .RW}}{{println .Source}}{{end}}{{end}}' ] \
      && [ "$4" = beef01 ] && [ "$5" = beef02 ] && [ $# = 5 ] || exit 97
    cat "$FIX/others" ;;
  esac ;;
"exec "*)
  # Every call into the container is one the launcher bounds in time.
  [ -n "${FAKE_TIMEOUT-}" ] || printf '%s\n' "$*" >> "$FIX/untimed"
  case "$*" in
  *"plugin list"*) cat "$FIX/plugins" ;;
  *"auth import"*) cat > "$FIX/imported"; [ ! -e "$FIX/import-fails" ] ;;
  # The model logins the state volume keeps; the answer holds their keys.
  # A client that repeats the answer on its error stream is the worst case.
  # With $FIX/logins-next the next answer differs.
  *"api GET /api/credential "*) cat "$FIX/logins"; cat "$FIX/logins" >&2
    [ ! -e "$FIX/logins-next" ] || mv "$FIX/logins-next" "$FIX/logins" ;;
  *"api DELETE /api/credential/"*)
    all="$*"; id=${all#*/api/credential/}; id=${id%% *}
    # With $FIX/login-stays the server refuses.
    [ ! -e "$FIX/login-stays" ] || exit 1
    # With $FIX/login-ghost it answers as the real one does for a login it does not hold.
    [ ! -e "$FIX/login-ghost" ] || exit 0
    jq -c --arg id "$id" '.data |= map(select(.id != $id))' "$FIX/logins" > "$FIX/logins.new" \
      && mv "$FIX/logins.new" "$FIX/logins" ;;
  *"api GET /api/project "*) cat "$FIX/projects" ;;
  # The approvals of the server's project, of every project (an empty id), or
  # of the one named. What is no list is answered as it is.
  *"api GET /api/permission/saved"[?\ ]*)
    all="$*"
    if ! jq -e '.data | type == "array"' "$FIX/saved" > /dev/null 2>&1; then cat "$FIX/saved"
    elif [[ $all != *"saved?projectID="* ]]; then jq -c '.data |= map(select(.projectID == "prj_main"))' "$FIX/saved"
    else
      id=${all#*projectID=}; id=${id%% *}
      if [ -z "$id" ]; then
        # With $FIX/empty-lists-none the server knows no such question.
        if [ -e "$FIX/empty-lists-none" ]; then echo '{"data":[]}'; else cat "$FIX/saved"; fi
      # With $FIX/id-answers-nothing a project's own list does not come.
      elif [ ! -e "$FIX/id-answers-nothing" ]; then
        jq -c --arg p "$id" '.data |= map(select(.projectID == $p))' "$FIX/saved"
      fi
    fi ;;
  *"api DELETE /api/permission/saved/"*)
    all="$*"; id=${all#*/api/permission/saved/}; id=${id%% *}
    # With $FIX/keeps the server answers and removes nothing.
    [ -e "$FIX/keeps" ] || { jq -c --arg id "$id" '.data |= map(select(.id != $id))' "$FIX/saved" \
      > "$FIX/saved.new" && mv "$FIX/saved.new" "$FIX/saved"; } ;;
  # The session list, two to a page whatever the limit; the cursor is the offset
  # and never null. What is no list is answered as it is.
  *"api GET /api/session?limit=1000"*)
    all="$*"; off=0
    [[ $all != *"cursor="* ]] || { off=${all#*cursor=}; off=${off%%[& ]*}; }
    next=$((off + 2)); [ ! -e "$FIX/bad-cursor" ] || next="$next&directory=/x"
    # With $FIX/endless the list never ends.
    if [ -e "$FIX/endless" ]; then
      printf '{"data":[{"id":"ses_x","permissions":null}],"cursor":{"next":"%s"}}\n' "$next"
    elif jq -e 'type == "array"' "$FIX/sessions" > /dev/null; then
      jq -c --argjson o "$off" --arg n "$next" '{data: .[$o:$o + 2], cursor: {next: $n}}' "$FIX/sessions"
    else cat "$FIX/sessions"; fi ;;
  *"api PATCH /api/session/"*)
    all="$*"; id=${all#*/api/session/}; id=${id%% *}
    [[ $all == *' -d {"permissions":[]} '* ]] || exit 96
    # With $FIX/keeps-rules the server answers and clears nothing.
    [ -e "$FIX/keeps-rules" ] || { jq -c --arg id "$id" 'map(if .id == $id then .permissions = [] else . end)' \
      "$FIX/sessions" > "$FIX/sessions.new" && mv "$FIX/sessions.new" "$FIX/sessions"; } ;;
  esac ;;
"logs "*) [ ! -e "$FIX/log-escapes" ] || { printf 'log\033]0;t\007line\n'; . "$FIX/ctl"; ctl; } ;;
"rm "*) echo false > "$FIX/running" ;;
*) echo "fake podman: unexpected $*" >&2; exit 99 ;;
esac
EOF
# The caller's opencode, which `secrets` alone starts: builtins only, it runs
# with the caller's PATH.
cat > "$tools/userbin/opencode" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
printf '%s\n' "$*" >> "$FIX/opencode-calls"
printf '%s' "$0" > "$FIX/client-path"
printf '%s' "$PATH" > "$FIX/client-PATH"
[ "$1 $2" = "auth export" ] || exit 95
printf '%s %s\n' "$PWD" "${OPENCODE_DISABLE_PROJECT_CONFIG-unset}" > "$FIX/export-env"
# An array, as opencode prints it; empty for the integration `none`.
if [ "$3" = none ]; then echo '[]'
# What is no JSON and holds a credential all the same.
elif [ "$3" = broken ]; then echo 'warning: MODEL-SECRET-6 is no JSON'
else printf '[{"id":"cred_1","integrationID":"%s","label":"key","active":true,"value":{"type":"key","key":"MODEL-SECRET-6"}}]\n' "$3"; fi
EOF
# The launcher's filter, recording what it gets of the server password.
cat > "$tools/bin/sed" <<EOF
#!/bin/bash
. "\$FIX/envcheck"
printf '%s\\n' "\${OPENCODE_PASSWORD-unset}" >> "\$FIX/sed-password"
exec $(command -v sed) "\$@"
EOF
cat > "$tools/bin/timeout" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
shift; FAKE_TIMEOUT=1 exec "$@"
EOF
# gh: the login's name and its token, each on request only, from the config
# directory the caller names.
cat > "$tools/bin/gh" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
PATH=/usr/bin:/bin
printf '%s\n' "$*" >> "$FIX/gh-calls"
case "$*" in
"config get -h github.com user") cat "${GH_CONFIG_DIR:-$FIX}/gh-user"; [ ! -e "$FIX/gh-no-login" ] ;;
"auth token --hostname github.com") cat "${GH_CONFIG_DIR:-$FIX}/gh-token"; [ ! -e "$FIX/gh-no-token" ] ;;
*) exit 97 ;;
esac
EOF
# The real commands of the launcher, each behind the same check.
for f in python3 jq realpath head base64 tr id mkdir seq sleep cat ls; do
  printf '%s\n' '#!/bin/bash' '. "$FIX/envcheck"' "exec $(command -v "$f") \"\$@\"" > "$tools/bin/$f"
done
# A client among the launcher's own commands is not the caller's.
printf '%s\n' '#!/bin/bash' ': > "$FIX/launcher-path-client"; exit 1' > "$tools/bin/opencode"
# First on the caller's PATH: what the launcher must take from its own.
for f in podman python3 jq realpath sed timeout head base64 tr id mkdir seq sleep cat ls gh; do
  printf '%s\n' '#!/bin/bash' ': > "$FIX/planted-host"; exit 1' > "$tools/evilbin/$f"
done
chmod +x "$tools/bin/"* "$tools/userbin/"* "$tools/evilbin/"*
# What an agent could leave in the work directory for the launcher to start.
for f in podman opencode sed bin/sed bin/podman bin/opencode; do
  printf '%s\n' '#!/bin/bash' ': > "$FIX/planted-client"' > "$work/ws/$f"
  chmod +x "$work/ws/$f"
done
# A client named relative to / that the work directory holds as well.
mkdir -p "$work/ws/usr/bin"
cp "$work/ws/podman" "$work/ws/usr/bin/env"
# What an agent could leave in a work directory for the launcher to import.
for m in ruamel/__init__ osc/__init__ sitecustomize; do
  printf 'import os\nopen(os.environ["FIX"] + "/planted-ran", "w").close()\n' > "$work/planted/$m.py"
done

cat > "$work/osc.conf" <<'EOF'
[general]
apiurl = https://api.opensuse.org

[https://api.opensuse.org]
user = packager
pass = OBS-SECRET-1
realname = Pat Packager
email = pat@example.org

[https://api.example.com]
user = other
pass = OTHER-SECRET-2
EOF
tea_config() {
  cat > "$work/config/tea/config.yml" <<EOF
logins:
- name: elsewhere
  url: https://src.opensuse.org.example.com
  token: TEA-OTHER-3
  default: true
  user: other
- name: src
  url: https://$1
  token: TEA-SECRET-4
  default: false
  user: packager
preferences:
  editor: false
EOF
}
tea_config src.opensuse.org
printf 'BZ-SECRET-5\n' > "$work/config/mcp-bugzilla/api-key"
gh_config() { printf '%s\n' "$1" > "$FIX/gh-user"; printf '%s\n' "$2" > "$FIX/gh-token"; }
gh_config packager gho_SECRET_9
printf '%s\n' "ID  VERSION" "opensuse-packaging.bug-guard  local" \
  "-  local  /etc/opencode/plugins/pool-pr-guard.ts" > "$FIX/plugins.bad"
printf '%s\n' "ID  VERSION" "opensuse-packaging.bug-guard  local" \
  "opensuse-packaging.pool-pr-guard  local" > "$FIX/plugins.good"
cp "$FIX/plugins.good" "$FIX/plugins"
echo false > "$FIX/running"
# The image of the server's container, as podman names it: by its id.
img="$(printf %s "$N" | sha256sum | cut -d' ' -f1)"
echo "$img" > "$FIX/image"
echo "$FIX/store" > "$FIX/storepath"
echo "$FIX/store/volumes" > "$FIX/volpath"
# Another container, which writes beside the directories of this test.
printf '%s\n' /srv/elsewhere "$work/ws2" "$work/mem2" > "$FIX/others"
echo '{"data":[]}' > "$FIX/saved"
echo '{"data":[]}' > "$FIX/logins"
kept_login() { printf '{"data":[{"id":"%s","integrationID":"prov","active":true,"value":{"type":"key","key":"KEPT-SECRET-8"}}]}\n' "$1" > "$FIX/logins"; }
echo '[{"id":"prj_main"}]' > "$FIX/projects"
echo '[]' > "$FIX/sessions"
allow='[{"action":"*","resource":"*","effect":"allow"}]'
# The sessions of the state volume, as the agent could have written them.
sessions() { printf '%s\n' "$1" > "$FIX/sessions"; : > "$FIX/client-calls"; }
# One approval the server saved for a project, as the agent could have written it.
approval() {
  printf '{"data":[{"id":"%s","projectID":"%s","action":"shell","resource":"*"}]}\n' "$1" "${2:-prj_main}" \
    > "$FIX/saved"
  : > "$FIX/client-calls"
}

# OPENCODE unset: the caller's own must not replace the fake. The launcher finds
# its commands among the checked ones alone: one it takes from elsewhere fails.
ownpath="$tools/bin"
callerpath="$tools/evilbin:$tools/userbin:$PATH"
scenv=(env -u OPENCODE -u OPENCODE_PASSWORD XDG_CONFIG_HOME="$work/config" XDG_RUNTIME_DIR="$work/run" OSC_CONFIG="$work/osc.conf"
  "SKILL_CONTAINER_NAME=$N" "SKILL_CONTAINER_PATH=$ownpath" PATH="$callerpath")
sc() { "${scenv[@]}" HOME="${SC_HOME:-$work/home}" bash "$SC" "$@"; }
# A command on a terminal of its own, whose output a pipe reads: attach wants one.
pty() (
  set -o pipefail
  python3 -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    os.write(1, data)
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))' "$@" | tr -d '\r'
)
tty() { pty "${scenv[@]}" HOME="$work/home" bash "$SC" "$@"; }
# The files the launcher left that hold the server password $pw.
pwfiles() {
  {
    find /tmp /var/tmp /dev/shm "/run/user/$(id -u)" -maxdepth 3 \( -path "$work" -o -path "$tools" \) -prune \
      -o -type f -user "$(id -u)" -newer "$work/stamp" -print 2> /dev/null
    find "$work" "$tools" -path "$FIX" -prune -o -type f -newer "$work/stamp" -print
  } | xargs -r -d '\n' grep -lF -- "$pw" 2> /dev/null
}
# The files that hold a made-up login and are not the fixtures: those the
# launcher left, in the temporary directories or beside what it reads.
fixtures=("$work/osc.conf" "$work/osc-broken.conf" "$work/config/tea/config.yml" "$work/config/mcp-bugzilla/api-key"
  "$work/planted/key" "$work/mem-key/memory.json" "$work/mem-mixed/memory.json" "$tools/userbin/opencode")
leakfiles() {
  {
    find /tmp /var/tmp /dev/shm "/run/user/$(id -u)" -maxdepth 3 \( -path "$work" -o -path "$tools" \) -prune \
      -o -type f -user "$(id -u)" -newer "$work/stamp" -print 2> /dev/null
    find "$work" "$tools" -path "$FIX" -prune -o -type f -print
  } | xargs -r -d '\n' grep -lE -- 'SECRET[-_][0-9]|TEA-OTHER' 2> /dev/null | grep -vxF -f <(printf '%s\n' "${fixtures[@]}")
}
secret() { cat "$FIX/secrets/$N-$1" 2>/dev/null; }
stored() { cat "$FIX/secrets/"* | sha256sum; }
# The container was removed after it last started.
removed() {
  awk -v rm="rm --force --ignore --depend $N-agent" \
    '$0 == rm { r = 1 } /^run --detach / { r = 0 } END { exit !r }' "$FIX/podman-calls"
}
# No made-up secret may reach the terminal or a command line.
leaks() { grep -E 'SECRET[-_][0-9]|TEA-OTHER' "$@" 2>/dev/null; }

out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "secrets" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "up without secrets starts nothing" || fail "up without secrets: rc=$rc $out"

out="$(sc secrets 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ -z "$(ls "$FIX/secrets")" ] && pass "secrets needs --model-auth" \
  || fail "secrets without --model-auth: rc=$rc $out"

# From a directory the agent wrote: none of its modules is imported, opencode
# exports elsewhere and without project config, a key file named from it is found.
printf 'BZ-SECRET-8\n' > "$work/planted/key"
out="$(cd "$work/planted" && sc secrets --model-auth prov --bugzilla-key key 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$FIX/planted-ran" ] && pass "secrets imports no module from the current directory" \
  || fail "secrets in a directory with planted modules: rc=$rc $out"
[ "$(cat "$FIX/export-env")" = "/ 1" ] && pass "the export runs outside the current directory, project config off" \
  || fail "the export ran in: $(cat "$FIX/export-env")"
[ "$(secret bugzilla)" = BZ-SECRET-8 ] && pass "a key file named from the current directory is stored" \
  || fail "a relative --bugzilla-key: rc=$rc $out"
[ "$(cat "$FIX/client-path")" = "$tools/userbin/opencode" ] && [ "$(cat "$FIX/client-PATH")" = "$callerpath" ] \
  && pass "the export is the caller's opencode, with the caller's PATH" \
  || fail "the export ran $(cat "$FIX/client-path") with $(cat "$FIX/client-PATH")"
# Nor from a directory that PYTHONPATH names: in secrets, which reads the
# logins, and in up, which checks the directories above the mounts.
out="$(PYTHONPATH="$work/planted" sc secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$FIX/planted-ran" ] && pass "secrets imports no module from PYTHONPATH" \
  || fail "secrets with PYTHONPATH on planted modules: rc=$rc $out"
rm -f "$FIX/planted-ran"
out="$(PYTHONPATH="$work/planted" sc up --workdir "$work/ws" --memory "$work/none" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "not a file: $work/none" <<<"$out" && [ ! -e "$FIX/planted-ran" ] \
  && pass "up imports no module from PYTHONPATH" || fail "up with PYTHONPATH on planted modules: rc=$rc $out"
rm -f "$FIX/planted-ran"
# The GitHub login is the one gh finds where the caller runs secrets.
mkdir "$FIX/ghalt"
printf 'narrow\n' > "$FIX/ghalt/gh-user"; printf 'gho_SECRET_8\n' > "$FIX/ghalt/gh-token"
out="$(GH_CONFIG_DIR="$FIX/ghalt" sc secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(secret github | grep -c 'user: narrow$\|oauth_token: gho_SECRET_8$')" = 3 ] \
  && ! secret github | grep -q 'packager\|gho_SECRET_9' \
  && pass "secrets copies the login of the gh config directory the caller names" \
  || fail "secrets with GH_CONFIG_DIR: rc=$rc $(leaks <<<"$out" | wc -l) $(secret github | sed 's/token:.*/token: …/')"

out="$(sc secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(printf '%s\n' $N-osc $N-tea $N-github $N-model $N-bugzilla)" ] \
  && pass "secrets prints the five names only" || fail "secrets: rc=$rc $out"
[ -z "$(leaks "$FIX/podman-calls" "$FIX/opencode-calls" "$FIX/gh-calls")" ] && pass "no secret on a command line" \
  || fail "a secret on a command line: $(leaks "$FIX/podman-calls" "$FIX/opencode-calls" "$FIX/gh-calls")"

got="$(OSC_CONFIG="$FIX/secrets/$N-osc" python3 -c '
from osc import conf
conf.get_config()
hosts = conf.config["api_host_options"]
h = hosts["https://api.opensuse.org"]
print(len(hosts), h.username, h.password, h.realname, h.email)' 2>&1)"
[ "$got" = "1 packager OBS-SECRET-1 Pat Packager pat@example.org" ] \
  && ! secret osc | grep -q 'OTHER\|example\.com' \
  && pass "osc reads its secret: the one login" || fail "the osc secret: $got"
secret tea | grep -qF TEA-SECRET-4 && ! secret tea | grep -q 'TEA-OTHER\|example\.com\|preferences' \
  && secret tea | grep -q 'default: true' && pass "the tea secret holds the one login, as default" \
  || fail "the tea secret: $(secret tea | sed 's/token:.*/token: …/')"
# gh's hosts file, as gh 2.x writes it for one login.
[ "$(secret github)" = "$(printf '%s\n' "github.com:" "    users:" "        packager:" \
  "            oauth_token: gho_SECRET_9" "    git_protocol: https" "    user: packager" \
  "    oauth_token: gho_SECRET_9")" ] \
  && [ "$(sort -u "$FIX/gh-calls" | tr '\n' '|')" = "auth token --hostname github.com|config get -h github.com user|" ] \
  && pass "the gh secret is a hosts file with the one github.com login" \
  || fail "the gh secret: $(secret github | sed 's/token:.*/token: …/') / $(sort -u "$FIX/gh-calls")"
secret model | grep -qF MODEL-SECRET-6 && [ "$(secret bugzilla)" = BZ-SECRET-5 ] \
  && pass "the model and Bugzilla secrets are stored" || fail "the model or Bugzilla secret"
[ ! -e "$FIX/secrets/$N-server-password" ] && pass "no server password before a container starts" \
  || fail "a server password without a container"

# A later run that fails must not have stored its first secret already.
sed -i 's/OBS-SECRET-1/OBS-SECRET-7/' "$work/osc.conf"
before="$(stored)"
tea_config src.example.org
out="$(sc secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no src.opensuse.org login" <<<"$out" && [ "$(stored)" = "$before" ] \
  && pass "no login for the forge: nothing replaced" || fail "no forge login: rc=$rc $out"
printf '%s\n' "logins:" "- name: src" "  url: https://src.opensuse.org" "  user: packager" \
  > "$work/config/tea/config.yml"
out="$(sc secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(stored)" = "$before" ] && pass "a forge login without a token: nothing replaced" \
  || fail "forge login without a token: rc=$rc $out"
# The parser's own message for a key given twice quotes its value.
printf '%s\n' "logins:" "- url: https://src.opensuse.org" "  token: TEA-SECRET-4" \
  "  token: TEA-SECRET-4" > "$work/config/tea/config.yml"
out="$(sc secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ -z "$(leaks <<<"$out")" ] && [ "$(stored)" = "$before" ] \
  && pass "a broken tea config: no line of it is quoted" || fail "broken tea config: rc=$rc $out"
tea_config src.opensuse.org
out="$("${scenv[@]}" OPENCODE=usr/bin/env HOME="$work/home" bash "$SC" secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no opencode client at an absolute path" <<<"$out" && [ "$(stored)" = "$before" ] \
  && pass "secrets refuses a client named by a relative path" || fail "secrets with a relative OPENCODE: rc=$rc $out"
# gh without a github.com login or its token. What gh prints goes into a YAML
# file as it is: a name or a token that is more than one word is not stored.
touch "$FIX/gh-no-login"
out="$(sc secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no github.com login" <<<"$out" && [ "$(stored)" = "$before" ] \
  && pass "no GitHub login: nothing replaced" || fail "no GitHub login: rc=$rc $out"
rm "$FIX/gh-no-login"; touch "$FIX/gh-no-token"
out="$(sc secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no token for github.com" <<<"$out" && [ "$(stored)" = "$before" ] \
  && pass "a GitHub login without a token: nothing replaced" || fail "GitHub login without a token: rc=$rc $out"
rm "$FIX/gh-no-token"
n=0
for pair in 'packager: x|gho_SECRET_9' '|gho_SECRET_9' $'packager|gho_SECRET_9\n    user: other' \
  'packager|gho_SECRET_9: x' 'packager|'; do
  n=$((n+1)); gh_config "${pair%%|*}" "${pair#*|}"
  out="$(sc secrets --model-auth prov 2>&1)"; rc=$?
  [ "$rc" != 0 ] && [ -z "$(leaks <<<"$out")" ] && [ "$(stored)" = "$before" ] \
    && pass "a GitHub name or token that is not one word: nothing replaced, nothing quoted ($n)" \
    || fail "GitHub name or token ($n): rc=$rc $out"
done
gh_config packager gho_SECRET_9
out="$(sc secrets --model-auth none 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(stored)" = "$before" ] \
  && pass "an empty export: nothing replaced" || fail "empty export: rc=$rc $out"
out="$(sc secrets --model-auth broken 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "exported no credential" <<<"$out" && [ -z "$(leaks <<<"$out")" ] && [ "$(stored)" = "$before" ] \
  && pass "an export that is no JSON: nothing replaced, nothing quoted" || fail "export that is no JSON: rc=$rc $out"
# osc's own message for a line it cannot read quotes the line.
printf '%s\n' "[general]" "apiurl = https://api.opensuse.org" "[https://api.opensuse.org]" "user = packager" \
  "pass OBS-SECRET-1" > "$work/osc-broken.conf"
out="$("${scenv[@]}" OSC_CONFIG="$work/osc-broken.conf" HOME="$work/home" bash "$SC" secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no usable" <<<"$out" && [ -z "$(leaks <<<"$out")" ] && [ "$(stored)" = "$before" ] \
  && pass "a broken osc config: no line of it is quoted" || fail "broken osc config: rc=$rc $out"
: > "$work/empty-key"
for key in "$work/no-key" "$work/empty-key"; do
  out="$(sc secrets --model-auth prov --bugzilla-key "$key" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && [ "$(stored)" = "$before" ] && pass "no Bugzilla key in ${key##*/}: nothing replaced" \
    || fail "Bugzilla key $key: rc=$rc $out"
done

left="$(leakfiles)"
[ -z "$left" ] && pass "secrets leaves no login in a file" || fail "secrets left a login in: $left"

# The agent gets the whole work directory: not the home directory, what holds
# it, the logins, podman's storage, the runtime directory, someone else's
# directory, or a path podman would split.
refused=(/ "$work" "$work/home" "$work/home/.config" "$work/config" "$work/config/tea" "$FIX"
  "$FIX/store/volumes" "$work/run" "$work/run/sub" "$work/a,b" "$work/a:b")
[ "$(id -u)" = 0 ] || refused+=(/etc)
for d in "${refused[@]}"; do
  out="$(sc up --workdir "$d" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && ! grep -q '^run ' "$FIX/podman-calls" && pass "up refuses $d" \
    || fail "up --workdir $d: rc=$rc $out"
done
# Podman's volumes can lie outside its storage.
mkdir -p "$work/vols/v/_data" "$work/vols/g/_data" "$FIX/store/volumes/g/_data" "$FIX/store/overlay"
echo "$work/vols" > "$FIX/volpath"
for d in "$work/vols/v/_data" "$FIX/store/overlay"; do
  out="$(sc up --workdir "$d" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "the work directory is one you own" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a work directory in podman's storage or volumes (${d#"$work"})" \
    || fail "up --workdir $d: rc=$rc $out"
done
# Nor is the graph a file there or in the storage: a container that mounts the
# volume writes it.
for d in "$work/vols/g/_data" "$FIX/store/volumes/g/_data"; do
  printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' > "$d/memory.json"
  out="$(sc up --workdir "$work/ws" --memory "$d/memory.json" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "memory.json: it lies in podman's storage" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a graph in podman's storage (${d#"$work"})" || fail "up --memory $d/memory.json: rc=$rc $out"
done
echo "$FIX/store/volumes" > "$FIX/volpath"
# Another owner's directory below a closed one of the caller: without root
# only a subordinate uid makes one.
mkdir "$work/foreign"
if unshare --user --map-root-user --map-users=auto chown 1 "$work/foreign" 2> /dev/null; then
  out="$(sc up --workdir "$work/foreign" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "the work directory is one you own" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a work directory of another owner" || fail "up --workdir of another owner: rc=$rc $out"
else
  echo "SKIP: a work directory of another owner (no subordinate uids here)"
fi
rmdir "$work/foreign"
out="$(cd "$work/ws" && sc up 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "is required" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "up without --workdir starts nothing, wherever it is called" || fail "up without --workdir: rc=$rc $out"
out="$(SC_HOME="$work/homelink" sc up --workdir "$work/home" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ! grep -q '^run ' "$FIX/podman-calls" && pass "up refuses the home directory behind a link" \
  || fail "up --workdir on a linked home: rc=$rc $out"

# Every login is there before a container starts.
mv "$FIX/secrets/$N-github" "$FIX/github.kept"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no secret $N-github" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "up without the GitHub secret starts nothing" || fail "up without the GitHub secret: rc=$rc $out"

# The agent runs as the caller and can make a file setuid to them: a directory
# above what it writes is the caller's and closed to everyone else. ($open
# lies in a temporary directory that is open, as /tmp is.)
mkdir -p "$open/ws" "$open/mid/ws" "$open/vol"
chmod 700 "$open/ws"
for mode in 755 750 710 701; do
  chmod "$mode" "$open"
  out="$(sc up --workdir "$open/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "closed to other users" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a work directory below a directory others can enter ($mode)" \
    || fail "up below a directory of mode $mode: rc=$rc $out"
done
echo "$open/vol" > "$FIX/volpath"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "podman's volumes in $open/vol need" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "up refuses volumes below a directory others can enter" || fail "up with open volumes: rc=$rc $out"
echo "$FIX/store/volumes" > "$FIX/volpath"
# Closed two levels up: the check goes on to the logins.
chmod 700 "$open"; chmod 755 "$open/mid"
out="$(sc up --workdir "$open/mid/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no secret $N-github" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "up takes a work directory with a closed directory further up" || fail "up below a closed directory: rc=$rc $out"
# Root owns what lies above: where the directories above belong to neither
# root nor the caller, as an unmapped owner shows in a user namespace, the
# closed one counts for nothing.
if unshare --user --map-user="$(id -u)" true 2> /dev/null; then
  out="$(unshare --user --map-user="$(id -u)" "${scenv[@]}" HOME="$work/home" bash "$SC" up --workdir "$open/mid/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "closed to other users" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a work directory below one that neither root nor the caller owns" \
    || fail "up below a directory of another owner: rc=$rc $out"
else
  echo "SKIP: a directory of another owner (no user namespaces here)"
fi
# A closed directory does not help below one that others write: they can put
# another in its place. A sticky one keeps it. The same holds for a graph,
# which needs no closed one.
mkdir -p "$open/c/ws" "$open/c/vol" "$open/gm"
chmod 700 "$open/c"
printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' > "$open/gm/memory.json"
for mode in 777 775 757; do
  chmod "$mode" "$open"
  out="$(sc up --workdir "$open/c/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "closed to other users" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a work directory below a directory others can write ($mode)" \
    || fail "up below a directory of mode $mode: rc=$rc $out"
  out="$(sc up --workdir "$work/ws" --memory "$open/gm/memory.json" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "another user can write a directory above it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a graph below a directory others can write ($mode)" \
    || fail "up --memory below a directory of mode $mode: rc=$rc $out"
done
echo "$open/c/vol" > "$FIX/volpath"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "podman's volumes in $open/c/vol need" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "up refuses volumes below a directory others can write" || fail "up with volumes others can replace: rc=$rc $out"
# A directory that is not there yet is not a closed one.
chmod 1777 "$open"
echo "$open/missing/volumes" > "$FIX/volpath"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "podman's volumes in $open/missing/volumes need" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "up refuses volumes below a missing directory with no closed one above" \
  || fail "up with volumes below a missing directory: rc=$rc $out"
echo "$FIX/store/volumes" > "$FIX/volpath"
for mode in 1777 755; do
  chmod "$mode" "$open"
  out="$(sc up --workdir "$open/c/ws" --memory "$open/gm/memory.json" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "no secret $N-github" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up takes a work directory and a graph below a directory others cannot replace them in ($mode)" \
    || fail "up below a directory of mode $mode: rc=$rc $out"
done
chmod 777 "$open/gm"
out="$(sc up --workdir "$open/c/ws" --memory "$open/gm/memory.json" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "another user can write a directory above it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "up refuses a graph in a directory others can write" || fail "up --memory in an open directory: rc=$rc $out"
chmod 700 "$open"
# What a link names is taken where the link leads: the directory of the
# logins, the runtime directory, podman's storage and its volumes.
# $1 = what lies behind the link, $2 = the refusal, then assignments for the
# environment and the arguments of up.
linked() {
  local label=$1 want=$2 envs=(); shift 2
  while [[ $1 == *=* ]]; do envs+=("$1"); shift; done
  out="$("${scenv[@]}" HOME="$work/home" "${envs[@]}" bash "$SC" up "$@" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF -- "$want" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses $label behind a link" || fail "up with $label behind a link: rc=$rc $out"
}
mkdir -p "$work/lk/ws/config" "$work/lk/ws/storage/g" "$work/lk/ws/vols/g" "$open/lkvol"
ln -s ws/config "$work/lk/config"; ln -s ws "$work/lk/run"; ln -s ws/storage "$work/lk/storage"
ln -s ws/vols "$work/lk/vols"; ln -s "$open/lkvol" "$work/lk/openvols"
printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' \
  | tee "$work/lk/ws/storage/g/memory.json" > "$work/lk/ws/vols/g/memory.json"
own="the work directory is one you own"
instore="memory.json: it lies in podman's storage"
linked "a work directory that holds the logins" "$own" XDG_CONFIG_HOME="$work/lk/config" --workdir "$work/lk/ws"
linked "a work directory that is the runtime directory" "$own" XDG_RUNTIME_DIR="$work/lk/run" --workdir "$work/lk/ws"
echo "$work/lk/storage" > "$FIX/storepath"
linked "a work directory that holds podman's storage" "$own" --workdir "$work/lk/ws"
linked "a graph in podman's storage" "$instore" --workdir "$work/ws" --memory "$work/lk/ws/storage/g/memory.json"
echo "$FIX/store" > "$FIX/storepath"
echo "$work/lk/vols" > "$FIX/volpath"
linked "a work directory that holds podman's volumes" "$own" --workdir "$work/lk/ws"
linked "a graph in podman's volumes" "$instore" --workdir "$work/ws" --memory "$work/lk/ws/vols/g/memory.json"
chmod 755 "$open"
echo "$work/lk/openvols" > "$FIX/volpath"
linked "podman's volumes below a directory others can enter" "podman's volumes in $work/lk/openvols need" \
  --workdir "$work/ws"
chmod 700 "$open"
echo "$FIX/store/volumes" > "$FIX/volpath"
# No directory here is root's and written by others, which takes root to make,
# and where user namespaces are off none is another user's: the program of
# kept() is given a tree of them. $1 = owner and $2 = mode of /a, which lies
# above /a/b, a closed directory of the caller (uid 1000).
keptprog="$(sed -n '/^kept() {$/,/^}$/p' "$SC" | sed -e '1,2d' -e '/^EOF$/,$d')"
keptfed() {
  python3 -I -c 'import os, sys
tree = {"/": (0, 0o40755), "/a": (int(sys.argv.pop(1)), int(sys.argv.pop(1), 8)), "/a/b": (1000, 0o40700)}
os.getuid = lambda: 1000
os.stat = lambda d: os.stat_result((tree[d][1], 0, 0, 0, tree[d][0], 0, 0, 0, 0, 0))
'"$keptprog" "$1" "$2" /a/b/ws closed
}
[ -n "$keptprog" ] || fail "no program found in kept()"
for fed in "0 777" "0 775" "0 757" "2000 755" "2000 1777" "1000 777"; do
  # shellcheck disable=SC2086  # owner and mode are two arguments
  keptfed $fed; rc=$?
  [ "$rc" = 1 ] && pass "kept() refuses below a directory of owner and mode $fed" \
    || fail "kept() below a directory of owner and mode $fed: rc=$rc"
done
for fed in "0 755" "0 1777" "1000 755" "1000 1777"; do
  # shellcheck disable=SC2086
  keptfed $fed; rc=$?
  [ "$rc" = 0 ] && pass "kept() takes a closed directory below one of owner and mode $fed" \
    || fail "kept() below a directory of owner and mode $fed: rc=$rc"
done

# A running container that writes a directory above or below the one mounted
# next could turn it into a link between the checks and the mount.
ln -s ws "$work/wsalias"
for other in "$work" "$work/ws" "$work/ws/sub" "$work/wsalias" "$work/ws/vol/_data"; do
  printf '%s\n' /srv/elsewhere "$other" > "$FIX/others"
  out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "a running container writes" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a work directory a running container writes around (${other#"$work"}/)" \
    || fail "up while a container writes $other: rc=$rc $out"
done
mkdir -p "$work/memc/g"
printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' > "$work/memc/g/memory.json"
for other in "$work/memc" "$work/memc/g" "$work/memc/g/sub" "$work/memc/g/_data"; do
  printf '%s\n' "$other" /srv/elsewhere > "$FIX/others"
  out="$(sc up --workdir "$work/ws" --memory "$work/memc/g/memory.json" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "memory.json: a running container writes" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a graph a running container writes around (${other#"$work"}/)" \
    || fail "up --memory while a container writes $other: rc=$rc $out"
done
printf '%s\n' /srv/elsewhere "$work/ws2" "$work/mem2" > "$FIX/others"
touch "$FIX/ps-fails"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "cannot list what the running containers mount" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "up starts nothing when the running containers cannot be listed" || fail "up without a container list: rc=$rc $out"
rm "$FIX/ps-fails"
mv "$FIX/github.kept" "$FIX/secrets/$N-github"

# A shared memory graph: its directory is mounted whole and relabelled, so the
# file is alone in it, holds a graph and nothing else, and is not the agent's.
graph='{"type":"entity","name":"a","entityType":"t","observations":["o"]}
{"type":"relation","from":"a","to":"a","relationType":"r"}'
mkdir -p "$work/mem" "$work/mem-two" "$work/mem-hidden" "$work/mem-key" "$work/mem-mixed" "$work/ws/mem" "$work/m,x"
for d in mem mem-two mem-hidden mem-mixed ws/mem "m,x"; do printf '%s\n' "$graph" > "$work/$d/memory.json"; done
touch "$work/mem-two/other" "$work/mem-hidden/.other"
printf 'BZ-SECRET-5\n' > "$work/mem-key/memory.json"
printf '%s\n' '{"type":"login","token":"TEA-SECRET-4"}' >> "$work/mem-mixed/memory.json"
ln -s "$work/ws/mem/memory.json" "$work/graphlink"
ln -s mem "$work/memlink"
while IFS='|' read -r file why; do
  out="$(sc up --workdir "$work/ws" --memory "$work/$file" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "$why" <<<"$out" && [ -z "$(leaks <<<"$out")" ] && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses the memory graph $file" || fail "up --memory $file: rc=$rc $out"
done <<'EOF'
mem/none.json|not a file
mem|not a file
mem-two/memory.json|alone in its directory
mem-hidden/memory.json|alone in its directory
mem-key/memory.json|alone in its directory
mem-mixed/memory.json|alone in its directory
ws/mem/memory.json|lies in the work directory
mem/../ws/mem/memory.json|lies in the work directory
graphlink|a symlink leads to it
memlink/memory.json|a symlink leads to it
m,x/memory.json|podman cannot mount
EOF
# Nor is a work directory behind a link: podman would mount where it leads.
mkdir "$work/elsewhere"
ln -s "$work/elsewhere" "$work/ws/sublink"
ln -s ws "$work/wslink"
for d in "$work/wslink" "$work/ws/sublink" "$work/wslink/bin"; do
  out="$(sc up --workdir "$d" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "a symlink leads to it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a work directory behind a link (${d#"$work/"})" || fail "up --workdir $d: rc=$rc $out"
done

# Commands are looked up nowhere in the work directory: not on the caller's
# PATH, not behind a link, not on the launcher's own.
n=0
for p in "PATH=$callerpath:$work/ws/bin" "PATH=$callerpath:$tools/wslink" "SKILL_CONTAINER_PATH=$ownpath:$work/ws/bin" \
  "PATH=$callerpath:$work/ws/pathlink" "SKILL_CONTAINER_PATH=$ownpath:$work/ws/pathlink" \
  "PATH=$callerpath:$work/ws" "SKILL_CONTAINER_PATH=$ownpath:$work/ws"; do
  n=$((n+1))
  out="$("${scenv[@]}" "$p" HOME="$work/home" bash "$SC" up --workdir "$work/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "lies in the work directory" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a work directory that commands are looked up in ($n)" \
    || fail "up with a PATH entry in the work directory ($n): rc=$rc $out"
done
out="$("${scenv[@]}" "SKILL_CONTAINER_PATH=bin:$ownpath" HOME="$work/home" bash "$SC" up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "not an absolute path" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "up refuses a relative entry among the launcher's own directories" \
  || fail "up with a relative SKILL_CONTAINER_PATH entry: rc=$rc $out"
# An entry with . or .. is not the directory it reads as; a name that starts
# with a dot is.
mkdir -p "$tools/.dot/..dot"
n=0
for p in "PATH=$callerpath:$tools/userbin/../userbin" "PATH=$callerpath:$tools/./userbin" "PATH=$callerpath:$tools/userbin/." \
  "PATH=$callerpath:$tools/userbin/.." "SKILL_CONTAINER_PATH=$ownpath/../bin" "LD_LIBRARY_PATH=$tools/../lib" \
  "LD_PRELOAD=$tools/./x.so"; do
  n=$((n+1))
  out="$("${scenv[@]}" "$p" HOME="$work/home" bash "$SC" up --workdir "$work/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "with a . or .. in it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses an entry with . or .. in it ($n)" || fail "up with $p: rc=$rc $out"
done
out="$("${scenv[@]}" PATH="$callerpath:$tools/.dot:$tools/.dot/..dot" HOME="$work/home" bash "$SC" help 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q '^usage:' <<<"$out" && pass "a PATH entry whose name starts with a dot is taken" \
  || fail "a dot-directory on PATH: rc=$rc $out"

# Nor are libraries: no entry of the loader's lists lies in the work directory,
# behind a link, after a `;` or after a space.
mkdir "$tools/lib"
ld() { (cd "$work" && "${scenv[@]}" "$1" HOME="$work/home" bash "$SC" "${@:2}" 2>&1); }
n=0
for p in "LD_LIBRARY_PATH=$work/ws/bin" "LD_LIBRARY_PATH=$work/ws" "LD_LIBRARY_PATH=$tools/wslink" "LD_LIBRARY_PATH=$tools/lib;$work/ws/bin" \
  "LD_PRELOAD=$work/ws/bin/x.so" "LD_PRELOAD=$tools/lib/a.so $work/ws/bin/x.so" \
  "LD_AUDIT=$tools/lib/a.so:$work/ws/bin/x.so"; do
  n=$((n+1))
  out="$(ld "$p" up --workdir "$work/ws")"; rc=$?
  [ "$rc" != 0 ] && grep -qF "lies in the work directory" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses a work directory that libraries are looked up in ($n)" \
    || fail "up with a loader entry in the work directory ($n): rc=$rc $out"
done
# An empty or relative entry is looked up where a command starts.
n=0
for p in "LD_LIBRARY_PATH=$tools/lib:" "LD_LIBRARY_PATH=:$tools/lib" "LD_LIBRARY_PATH=lib" \
  "LD_LIBRARY_PATH=$tools/lib;lib" "LD_PRELOAD=lib/x.so" "LD_PRELOAD=$tools/lib/a.so lib/x.so" \
  "LD_AUDIT=lib/x.so" "LD_AUDIT=$tools/lib/a.so:lib/x.so"; do
  n=$((n+1))
  out="$(ld "$p" up --workdir "$work/ws")"; rc=$?
  [ "$rc" != 0 ] && grep -qF "not an absolute path" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses an empty or relative entry in a list of the loader ($n)" \
    || fail "up with an empty or relative loader entry ($n): rc=$rc $out"
done
for p in "LD_LIBRARY_PATH=$tools/"'$LIB' "LD_PRELOAD=$tools/"'$LIB/x.so'; do
  out="$(ld "$p" up --workdir "$work/ws")"; rc=$?
  [ "$rc" != 0 ] && grep -qF 'with a $' <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "up refuses an entry the loader would rewrite (${p%%=*})" || fail "up with $p: rc=$rc $out"
done

# From here on no opencode starts on the host: the client's is in a container.
oc0="$(wc -l < "$FIX/opencode-calls")"
printf '%s\n' '{"data":[{"id":"per_a1","projectID":"prj_main","action":"shell","resource":"*"},{"id":"per_b2","projectID":"prj_main","action":"edit","resource":"*"}]}' \
  > "$FIX/saved"
sessions "[{\"id\":\"ses_u1\",\"permissions\":$allow}]"
kept_login cred_old1
# A work directory named from the current one.
out="$(cd "$work" && sc up --workdir ws --image img:1 --model prov/model 2>&1)"; rc=$?
run="$(grep '^run --detach ' "$FIX/podman-calls")"
order="$(grep -o 'api DELETE [^ ]*\|api PATCH [^ ]*\|auth import' "$FIX/podman-calls" | tr '\n' ' ')"
[ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ "$(jq -c 'map(.permissions)' "$FIX/sessions")" = "[[]]" ] \
  && grep -qF "removed the saved approvals and session rules" <<<"$out" \
  && [ "$order" = "api DELETE /api/permission/saved/per_a1 api DELETE /api/permission/saved/per_b2 api PATCH /api/session/ses_u1 api DELETE /api/credential/cred_old1 auth import " ] \
  && pass "up removes the saved approvals and session rules before the model credential goes in" \
  || fail "up and saved approvals: $order / $out"
[ "$(jq -c .data "$FIX/logins")" = "[]" ] && [[ $order == *"api DELETE /api/credential/cred_old1 auth import " ]] \
  && [ -z "$(leaks <<<"$out")" ] \
  && pass "up removes the model login the state volume kept, then imports the secret's" \
  || fail "up and a kept model login: $order / $(jq -c '.data | map(.id)' "$FIX/logins")"
[ "$rc" = 0 ] && grep -qxF "$N-agent is up, work directory $work/ws" <<<"$out" && ! removed && pass "up says where the container works" \
  || fail "up: rc=$rc $out"
pw="$(secret server-password)"
[ "${#pw}" = 32 ] && [ "$(secret server-password | wc -l)" = 0 ] \
  && [ "$(grep -x "secret create --replace $N-server-password -\|rm --force --ignore --depend $N-agent\|run --detach .*" "$FIX/podman-calls" | tail -3 | cut -d' ' -f1 | tr '\n' ' ')" = "secret rm run " ] \
  && pass "up makes a 24-byte server password without a newline, removes what an earlier start left, then starts the container" \
  || fail "the server password: ${#pw} characters"
own="uid=$(id -u),gid=$(id -g)"
# The whole command: an option nobody asked for, a second mount or the host
# network, fails here as well.
want=(run --detach --name "$N-agent" --userns=keep-id --user "$(id -u):$(id -g)"
  --read-only --cap-drop=all --security-opt no-new-privileges --init
  --secret "$N-server-password,type=env,target=OPENCODE_PASSWORD"
  --secret "$N-osc,target=/home/agent/.config/osc/oscrc,$own,mode=0600"
  --secret "$N-tea,target=/home/agent/.config/tea/config.yml,$own,mode=0400"
  --secret "$N-github,target=/home/agent/.config/gh/hosts.yml,$own,mode=0400"
  --secret "$N-bugzilla,target=/home/agent/.config/mcp-bugzilla/api-key,$own,mode=0400"
  --volume "$N-state:/home/agent/.local/share/opencode:U"
  --volume "$N-memory:/home/agent/.local/share/mcp-memory:U"
  --volume "$N-toolstate:/home/agent/.local/state:U" --volume "$N-scratch:/var/tmp"
  --tmpfs "/home/agent/.cache:rw,mode=0700,U"
  --volume "$work/config/skill-container/$N:/home/agent/.config/opencode:ro,Z"
  --volume "$work/ws:$work/ws:Z" --workdir "$work/ws"
  img:1 opencode serve --hostname 127.0.0.1 --port 4096)
[ "$run" = "${want[*]}" ] && pass "up runs the container locked down, with its secrets and volumes and nothing else" \
  || fail "up: the run differs: $(diff <(printf '%s\n' "${want[@]}") <(tr ' ' '\n' <<<"$run"))"
! grep -qF "$N-model" <<<"$run" && grep -qF MODEL-SECRET-6 "$FIX/imported" \
  && grep -q "^exec -i $N-agent opencode auth import --server http://127.0.0.1:4096$" "$FIX/podman-calls" \
  && pass "the model credential is imported through a pipe, not mounted" \
  || fail "the model import: $(grep 'auth import' "$FIX/podman-calls")"
[ "$(jq -r .model "$work/config/skill-container/$N/opencode.json")" = prov/model ] \
  && pass "the model choice is in the user config" || fail "the user config"
[ -z "$(leaks "$FIX/podman-calls")" ] && [ -z "$(leaks <<<"$out")" ] && ! grep -qF "$pw" <<<"$out" \
  && pass "up puts no secret on a command line or the terminal" || fail "up leaks a secret"

# attach and run start the client in a second container, made from the image
# the server's container runs. The whole command, as for up: a mount of the
# host, a published port or a variable of the caller fails here.
inner=http://127.0.0.1:4096
cl=(run --rm --pull=never --network "container:$N-agent" --userns "container:$N-agent"
  --user "$(id -u):$(id -g)" --read-only --cap-drop=all --security-opt no-new-privileges --init
  --http-proxy=false --log-driver=none
  --secret "$N-server-password,type=env,target=OPENCODE_PASSWORD"
  --env FORCE_HYPERLINK=0 --env TERM --env COLORTERM
  --tmpfs "/home/agent/.local/share/opencode:rw,mode=0700,U"
  --tmpfs "/home/agent/.local/state:rw,mode=0700,U" --tmpfs "/home/agent/.cache:rw,mode=0700,U"
  --tmpfs "$work/ws:ro,mode=0555,notmpcopyup" --workdir "$work/ws")
# The last client's container against the one expected, and where they differ.
client() { [ "$(tail -1 "$FIX/client-calls")" = "${cl[*]} $*" ]; }
differs() { diff <(printf '%s\n' "${cl[@]}" "$@") <(tail -1 "$FIX/client-calls" | tr ' ' '\n'); }
rm -f "$FIX/sed-password"
out="$(cd / && VISUAL=vi EDITOR=vi FORCE_HYPERLINK=1 http_proxy=http://proxy.example:3128 sc run --continue hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && client "$img" opencode run --server "$inner" --continue hello \
  && pass "run starts the client in a container of its own: the server's image, network and users, nothing of the host" \
  || fail "run: rc=$rc $out / $(differs "$img" opencode run --server "$inner" --continue hello)"
grep -qx "inspect --format {{.Image}} $N-agent" "$FIX/podman-calls" \
  && pass "run takes the image from the server's container, by its id" || fail "run did not ask for the server's image"
[ -s "$FIX/sed-password" ] && ! grep -qv '^unset$' "$FIX/sed-password" \
  && pass "the filter of run starts without the server password" || fail "the filter of run got the password"
# Called from the work directory, the launcher's commands still start in /.
out="$(cd "$work/ws" && sc run hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$FIX/cwd-leak" ] && client "$img" opencode run --server "$inner" hello \
  && pass "run from the work directory starts no command there" \
  || fail "run from the work directory: rc=$rc $out / $(sort -u "$FIX/cwd-leak" 2> /dev/null | tr '\n' ' ')"
# attach gives the client's container the caller's terminal, and starts
# nothing without one at both ends.
rm -f "$FIX/client-tty"
out="$(tty attach --session s1 2>&1)"; rc=$?
[ "$rc" = 0 ] && client --interactive --tty --detach-keys= "$img" opencode --server "$inner" --session s1 \
  && [ "$(cat "$FIX/client-tty")" = yes ] \
  && pass "attach starts the client in a container of its own, on the caller's terminal" \
  || fail "attach: rc=$rc $out / $(differs --interactive --tty --detach-keys= "$img" opencode --server "$inner" --session s1)"
n0="$(wc -l < "$FIX/podman-calls")"
out="$(sc attach --session s1 2>&1 < /dev/null)"; rc=$?
[ "$rc" = 1 ] && grep -qF "attach needs a terminal" <<<"$out" && [ "$(wc -l < "$FIX/podman-calls")" = "$n0" ] \
  && pass "attach without a terminal starts nothing" || fail "attach without a terminal: rc=$rc $out"
n=0
# The third: the output is no terminal, the error stream is one.
for half in '2>&1 < /dev/null' '2>&1 | while IFS= read -r l; do printf "%s\n" "$l"; done' '> /dev/null'; do
  n=$((n+1))
  out="$(pty "${scenv[@]}" HOME="$work/home" SC="$SC" bash -o pipefail -c "bash \"\$SC\" attach $half" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && grep -qF "attach needs a terminal" <<<"$out" && [ "$(wc -l < "$FIX/podman-calls")" = "$n0" ] \
    && pass "attach with a terminal at one end only starts nothing ($n)" || fail "attach with half a terminal ($n): rc=$rc $out"
done
touch "$FIX/escapes"
tty attach > /dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && pass "attach ends with the client's exit status" || fail "attach and the client's exit status: rc=$rc"
rm "$FIX/escapes"
# attach and run pass on the flags the launcher names and no other: not the
# three that answer every permission with yes, in any form opencode reads, and
# not the one that names a file: the client's container holds none of the caller's.
out="$(sc run -c --session=s1 --fork -m prov/model --agent build --format json --title=-t --thinking hello there 2>&1)"; rc=$?
[ "$rc" = 0 ] && client "$img" opencode run --server "$inner" -c --session=s1 --fork -m prov/model --agent build --format json --title=-t --thinking hello there \
  && pass "run passes on the flags it names" || fail "run with its flags: rc=$rc $out / $(tail -1 "$FIX/client-calls")"
out="$(tty attach --continue -s s1 --prompt=hi 2>&1)"; rc=$?
[ "$rc" = 0 ] && client --interactive --tty --detach-keys= "$img" opencode --server "$inner" --continue -s s1 --prompt=hi \
  && pass "attach passes on the flags it names" || fail "attach with its flags: rc=$rc $out / $(tail -1 "$FIX/client-calls")"
calls="$(wc -l < "$FIX/client-calls") $(wc -l < "$FIX/podman-calls")"
while IFS='|' read -r refused why; do
  # shellcheck disable=SC2086
  out="$(sc $refused 2>&1 < /dev/null)"; rc=$?
  [ "$rc" != 0 ] && grep -qF -- "$why" <<<"$out" \
    && [ "$(wc -l < "$FIX/client-calls") $(wc -l < "$FIX/podman-calls")" = "$calls" ] \
    && pass "refused before anything runs: $refused" || fail "$refused: rc=$rc $out"
done <<'EOF'
run --auto hello|run passes on these opencode flags only
run --auto=true hello|run passes on these opencode flags only
run --yolo hello|run passes on these opencode flags only
run --dangerously-skip-permissions hello|run passes on these opencode flags only
run --no-auto hello|run passes on these opencode flags only
run hello --auto|run passes on these opencode flags only
run -c --auto hello|run passes on these opencode flags only
run -- --auto|run passes on these opencode flags only
run -- hello|run passes on these opencode flags only
run hello -- --yolo|run passes on these opencode flags only
run --help|run passes on these opencode flags only
run --standalone hello|run passes on these opencode flags only
run --server http://127.0.0.1:1 hello|run passes on these opencode flags only
run -x hello|run passes on these opencode flags only
run -cs s1 hello|run passes on these opencode flags only
run -f note hello|run passes on these opencode flags only
run --file=note hello|run passes on these opencode flags only
run --prompt hi hello|run passes on these opencode flags only
run -s --auto hello|-s needs a value
run -s -c hello|-s needs a value
run --model --agent build hello|--model needs a value
run hello --title|--title needs a value
run --continue=--auto hello|--continue takes no value
run -c=--auto hello|-c takes no value
run --thinking=--auto hello|--thinking takes no value
run --fork=x hello|--fork takes no value
attach --auto|attach passes on these opencode flags only
attach --auto=true|attach passes on these opencode flags only
attach --yolo|attach passes on these opencode flags only
attach --dangerously-skip-permissions|attach passes on these opencode flags only
attach -c --auto|attach passes on these opencode flags only
attach -- --auto|attach passes on these opencode flags only
attach --|attach passes on these opencode flags only
attach --print-logs|attach passes on these opencode flags only
attach --model prov/model|attach passes on these opencode flags only
attach --fork|attach passes on these opencode flags only
attach -f note|attach passes on these opencode flags only
attach -s --auto|-s needs a value
attach --prompt|--prompt needs a value
attach --continue=--auto|--continue takes no value
attach serve|attach takes flags only
attach /tmp|attach takes flags only
attach --session=s1 serve|attach takes flags only
attach -c serve|attach takes flags only
attach --prompt auth list|attach takes flags only
attach -s s1 web|attach takes flags only
EOF
# One word made of two flags of the list is no flag of it.
for refused in "attach|-c --continue" "attach|-s --session=--auto" "run|--title --thinking" "run|--agent --format=--auto"; do
  out="$(sc "${refused%%|*}" "${refused#*|}" hello 2>&1 < /dev/null)"; rc=$?
  [ "$rc" != 0 ] && grep -qF -- "${refused%%|*} passes on these opencode flags only" <<<"$out" \
    && [ "$(wc -l < "$FIX/client-calls") $(wc -l < "$FIX/podman-calls")" = "$calls" ] \
    && pass "refused before anything runs: one word '${refused#*|}'" || fail "one word '${refused#*|}': rc=$rc $out"
done
! grep -qF "$pw" "$FIX/client-calls" "$FIX/podman-calls" && pass "the password is on no command line" \
  || fail "the password is on a command line"
[ -z "$(pwfiles)" ] && pass "up, run and attach leave the password in no file" \
  || fail "the password is in: $(pwfiles)"
! grep -q "^secret inspect.* $N-server-password$" "$FIX/podman-calls" \
  && pass "the launcher does not read the server password back: podman hands it to the containers" \
  || fail "the launcher read the server password back"

# The state volume is the agent's to write: an approval in it ends with the session.
approval per_c3
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -s "$FIX/client-calls" ] \
  && pass "run removes a saved approval, then starts the client" || fail "run with a saved approval: rc=$rc $out"
approval ../session/ses_1
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && ! grep -qF "DELETE /api/permission/saved/.." "$FIX/podman-calls" \
  && pass "run refuses a saved approval whose id is not one" || fail "run with a made-up id: rc=$rc $out"
approval per_d4; touch "$FIX/keeps"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses while a saved approval stays" \
  || fail "run with an approval that stays: rc=$rc $out"
rm "$FIX/keeps"; echo '{"error":"no"}' > "$FIX/saved"; : > "$FIX/client-calls"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses when the saved approvals cannot be listed" \
  || fail "run without a list of approvals: rc=$rc $out"
echo '{"data":[]}' > "$FIX/saved"

# An approval belongs to a project: one of a project the server lists is found
# by that project's id, one of a project it does not list by the empty id.
echo '[{"id":"prj_main"},{"id":"prj_sub"}]' > "$FIX/projects"
approval per_s1 prj_sub; touch "$FIX/empty-lists-none"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -s "$FIX/client-calls" ] \
  && pass "run removes the approval of another project the server lists" \
  || fail "run with an approval of a listed project: rc=$rc $out"
rm "$FIX/empty-lists-none"; echo '[]' > "$FIX/projects"; approval per_e1 prj_evil
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -s "$FIX/client-calls" ] \
  && pass "run removes the approval of a project the server does not list" \
  || fail "run with an approval of an unlisted project: rc=$rc $out"
n=0
for projects in '{"error":"no"}' '' '[{"id":"../x"}]'; do
  n=$((n+1)); printf '%s' "$projects" > "$FIX/projects"; : > "$FIX/client-calls"
  out="$(sc run hello 2>&1)"; rc=$?
  [ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && ! grep -qF "projectID=.." "$FIX/podman-calls" \
    && pass "run refuses when the projects cannot be listed ($n)" \
    || fail "run without a list of projects ($n): rc=$rc $out"
done
echo '[{"id":"prj_main"},{"id":"prj_sub"}]' > "$FIX/projects"; touch "$FIX/id-answers-nothing"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses when a project's approvals do not come" \
  || fail "run without an answer for a project: rc=$rc $out"
rm "$FIX/id-answers-nothing"; echo '[{"id":"prj_main"}]' > "$FIX/projects"

# So are a session's own rules: the one on the second page of the list as well.
sessions "[{\"id\":\"ses_a\",\"permissions\":null},{\"id\":\"ses_b\",\"permissions\":[]},{\"id\":\"ses_c\",\"permissions\":$allow}]"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c 'map(.permissions)' "$FIX/sessions")" = "[null,[],[]]" ] && [ -s "$FIX/client-calls" ] \
  && pass "run clears the rules of a session on a later page, then starts the client" \
  || fail "run with session rules: rc=$rc $out"
sessions "[{\"id\":\"ses_d\",\"permissions\":$allow}]"; touch "$FIX/keeps-rules"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses while a session keeps its rules" \
  || fail "run with rules that stay: rc=$rc $out"
rm "$FIX/keeps-rules"; sessions "[{\"id\":\"../permission/saved/x\",\"permissions\":$allow}]"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && ! grep -qF "PATCH /api/session/.." "$FIX/podman-calls" \
  && pass "run refuses a session whose id is not one" || fail "run with a made-up session id: rc=$rc $out"
sessions '{"error":"no"}'
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses when the sessions cannot be listed" \
  || fail "run without a list of sessions: rc=$rc $out"
sessions '[{"id":"ses_e","permissions":null}]'; touch "$FIX/bad-cursor"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses a list whose next page is not named by a cursor" \
  || fail "run with a made-up cursor: rc=$rc $out"
rm "$FIX/bad-cursor"; touch "$FIX/endless"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses a session list that does not end" \
  || fail "run with an endless session list: rc=$rc $out"
rm "$FIX/endless"; sessions '[]'
# What podman says of the container reaches the command line of the client's:
# an image that is no id, or a work directory podman cannot mount, starts none.
n=0
for bad in "" "${img:1}" "sha256:$img" "--volume=/:/host"; do
  n=$((n+1)); printf '%s\n' "$bad" > "$FIX/image"
  out="$(sc run hello 2>&1)"; rc=$?
  [ "$rc" = 1 ] && [ ! -s "$FIX/client-calls" ] && [[ $out == *"cannot read the image of $N-agent"* ]] \
    && pass "run refuses a container whose image is not named by its id ($n)" \
    || fail "run with the image '$bad': rc=$rc $out"
done
printf '%s\n' "$img" > "$FIX/image"
n=0
for wd in "" ws / "$work/a,b" "$work/a:b"; do
  n=$((n+1)); printf %s "$wd" > "$FIX/workdir"
  out="$(sc run hello 2>&1)"; rc=$?
  [ "$rc" = 1 ] && [ ! -s "$FIX/client-calls" ] && [[ $out == *"cannot read the work directory of $N-agent"* ]] \
    && pass "run refuses a container whose work directory is no path to mount ($n)" \
    || fail "run with the work directory '$wd': rc=$rc $out"
done
printf %s "$work/ws" > "$FIX/workdir"

# A reply reaches the terminal as text and colour, each stream on its own, and
# the client's exit status is the launcher's.
touch "$FIX/escapes"
sc run hello > "$work/rout" 2> "$work/rerr"; rc=$?
[ "$rc" = 7 ] && cmp -s "$work/rout" <(printf 'out]52;c;QUJD\033[31mred\033[0m[2Jx[35m2Jy0;t\nctl<>\n') \
  && cmp -s "$work/rerr" <(printf 'err]0;title\033[1mbold\033[0m\nctl<>\n') \
  && pass "run prints a reply without its control characters, colours apart" \
  || fail "run and control characters: rc=$rc $(od -c "$work/rout" | head -8) / $(od -c "$work/rerr" | head -8)"
rm "$FIX/escapes"

# Nothing the agent left in the work directory runs on the host: no command is
# looked up there.
: > "$FIX/client-calls"
n=0
base="$tools/userbin:$PATH"
for p in ":$base" ".:$base" "bin:$base" "$base:" "$tools/userbin:.:$PATH" "$tools/userbin::$PATH"; do
  n=$((n+1))
  out="$(cd "$work" && "${scenv[@]}" PATH="$p" HOME="$work/home" bash "$SC" run hello 2>&1)"; rc=$?
  [ "$rc" != 0 ] && [ ! -e "$FIX/planted-client" ] && [ ! -s "$FIX/client-calls" ] \
    && pass "run refuses a PATH that looks commands up in the work directory ($n)" \
    || fail "run with an empty or relative PATH entry ($n): rc=$rc $out"
done
# Nor is a library loaded from there into the launcher's commands.
n=0
for p in "LD_LIBRARY_PATH=$tools/lib:" "LD_LIBRARY_PATH=lib" "LD_LIBRARY_PATH=$work/ws/bin" \
  "LD_PRELOAD=$tools/lib/a.so lib/x.so" "LD_PRELOAD=$work/ws/bin/x.so" "LD_AUDIT=lib/x.so" \
  "LD_AUDIT=$work/ws/bin/x.so" "LD_LIBRARY_PATH=$tools/"'$LIB'; do
  n=$((n+1))
  out="$(ld "$p" run hello)"; rc=$?
  [ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] \
    && pass "run refuses a list of the loader that reaches the work directory ($n)" \
    || fail "run with $p: rc=$rc $out"
done
for p in "LD_LIBRARY_PATH=$tools/lib" "LD_LIBRARY_PATH=" "LD_PRELOAD=libc.so.6"; do
  : > "$FIX/client-calls"
  out="$(ld "$p" run hello)"; rc=$?
  [ "$rc" = 0 ] && [ -s "$FIX/client-calls" ] && pass "run takes ${p:-an empty list}" || fail "run with $p: rc=$rc $out"
done
: > "$FIX/client-calls"
out="$("${scenv[@]}" PATH="$callerpath:$work/ws/bin" HOME="$work/home" bash "$SC" run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "lies in the work directory" <<<"$out" && [ ! -s "$FIX/client-calls" ] \
  && pass "run refuses a PATH entry in the work directory" || fail "run with a PATH entry in the work directory: rc=$rc $out"

out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(grep -c '^run --detach ' "$FIX/podman-calls")" = 1 ] && ! removed && [ "$(secret server-password)" = "$pw" ] \
  && pass "up leaves a running container and its password alone" || fail "up on a running container: rc=$rc $out"
cp "$FIX/plugins.bad" "$FIX/plugins"; : > "$FIX/client-calls"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses a container without both guards" \
  || fail "run without a guard plugin: rc=$rc $out"

# Starts that must leave no container behind.
restart() { sc down > /dev/null; : > "$FIX/podman-calls"; rm -f "$FIX/imported"; }
restart
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] \
  && pass "a guard plugin that failed to load: the container is removed" || fail "failed plugin: rc=$rc $out"
# What the server printed on the way is shown as text.
printf 'ID  VERSION\n-  local  /x\033]52;c;QUJD\007.ts\n' > "$FIX/plugins"; restart; touch "$FIX/log-escapes"
sc up --workdir "$work/ws" > "$work/rout" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -qaF "log]0;tline" "$work/rout" && grep -qaxF "ctl<>" "$work/rout" \
  && grep -qaF "/x]52;c;QUJD.ts" "$work/rout" && ! grep -qa $'[\033\007]' "$work/rout" \
  && pass "a failed start shows the server's output without control characters" \
  || fail "failed start and control characters: rc=$rc $(od -c "$work/rout" | head -12)"
rm "$FIX/log-escapes"
cp "$FIX/plugins.good" "$FIX/plugins"; restart; approval per_e5; touch "$FIX/keeps"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] \
  && pass "a saved approval that stays: the container is removed, no credential is sent" \
  || fail "up with an approval that stays: rc=$rc $out"
rm "$FIX/keeps"; echo '{"data":[]}' > "$FIX/saved"; restart; touch "$FIX/stops"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -e "$FIX/imported" ] \
  && pass "a container that stopped: no credential is sent" || fail "stopped container: rc=$rc $out"
rm "$FIX/stops"; restart; touch "$FIX/run-fails"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] \
  && pass "a container podman made and could not start is removed" || fail "a start podman failed: rc=$rc $out"
rm "$FIX/run-fails"; restart; touch "$FIX/import-fails"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && pass "a failed import: the container is removed" \
  || fail "failed import: rc=$rc $out"
rm "$FIX/import-fails"
restart; echo '{"error":"no"}' > "$FIX/logins"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] && grep -qF "podman volume rm" <<<"$out" \
  && pass "model logins that cannot be listed: the container is removed, no credential is sent" \
  || fail "up without a list of model logins: rc=$rc $out"
restart; kept_login 'cred_a/../../session'
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] \
  && ! grep -q 'api DELETE /api/credential' "$FIX/podman-calls" \
  && pass "a kept model login with an unexpected id: no call is made with it, no credential is sent" \
  || fail "up with a model login id: rc=$rc $out"
restart; kept_login cred_old1; touch "$FIX/login-stays"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] \
  && grep -qF "podman volume rm" <<<"$out" \
  && pass "a kept model login that stays: the container is removed, no credential is sent" \
  || fail "up with a model login that stays: rc=$rc $out"
rm "$FIX/login-stays"
# An id is one value in the answer; split into lines, a line break in it makes two.
for id in 'cred_x\ncred_y' 'cred_a\n' ''; do
  restart; kept_login "$id"
  out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] \
    && ! grep -q 'api DELETE /api/credential' "$FIX/podman-calls" && grep -qF "podman volume rm" <<<"$out" \
    && pass "a kept model login with the id '$id': no call is made with it, no credential is sent" \
    || fail "up with the model login id '$id': rc=$rc $out"
done
# Nor is an id that is no text, whatever it holds.
restart; echo '{"data":[{"id":{"k":"SECRET-7"}}]}' > "$FIX/logins"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] \
  && ! grep -q 'api DELETE /api/credential' "$FIX/podman-calls" \
  && pass "a kept model login whose id is no text: no call is made, nothing of it is shown" \
  || fail "up with a model login id that is no text: rc=$rc $out"
restart; kept_login cred_old1; touch "$FIX/login-ghost"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] \
  && grep -q 'api DELETE /api/credential/cred_old1' "$FIX/podman-calls" && grep -qF "podman volume rm" <<<"$out" \
  && pass "a kept model login the server only claims to remove: the container is removed, no credential is sent" \
  || fail "up with a model login removed in name only: rc=$rc $out"
rm "$FIX/login-ghost"
restart; echo '{"data":[]}' > "$FIX/logins"; echo '{"error":"no"}' > "$FIX/logins-next"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] && grep -qF "podman volume rm" <<<"$out" \
  && pass "model logins that cannot be listed again: the container is removed, no credential is sent" \
  || fail "up without a second list of model logins: rc=$rc $out"
# A list that could not be read is not an empty one, whatever the next one says.
restart; echo '{"error":"no"}' > "$FIX/logins"; echo '{"data":[]}' > "$FIX/logins-next"
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && removed && [ ! -e "$FIX/imported" ] \
  && pass "model logins that can be listed only the second time: the container is removed, no credential is sent" \
  || fail "up without a first list of model logins: rc=$rc $out"
rm -f "$FIX/logins-next"; echo '{"data":[]}' > "$FIX/logins"
# A hangup cannot be sent where the caller of this test ignores it.
sigs=(TERM); [ -n "$(trap -p HUP)" ] || sigs+=(HUP)
for sig in "${sigs[@]}"; do
  restart; echo "ID  VERSION" > "$FIX/plugins"
  "${scenv[@]}" HOME="$work/home" bash "$SC" up --workdir "$work/ws" > /dev/null 2>&1 &
  pid=$!
  for _ in $(seq 100); do grep -q "plugin list" "$FIX/podman-calls" && break; sleep 0.1; done
  kill "-$sig" "$pid"; wait "$pid"; rc=$?
  [ "$rc" = 130 ] && removed && [ ! -e "$FIX/imported" ] && pass "an up interrupted by $sig removes the container" \
    || fail "up interrupted by $sig: rc=$rc"
done
cp "$FIX/plugins.good" "$FIX/plugins"

# Each container has a password of its own.
restart
out="$(sc up --workdir "$work/ws" 2>&1)"; rc=$?
pw2="$(secret server-password)"
[ "$rc" = 0 ] && [ "${#pw2}" = 32 ] && [ "$pw2" != "$pw" ] && pass "a new container gets a new server password" \
  || fail "the second up: rc=$rc $out"
sc down > /dev/null

# The host's graph in place of the volume, named from the current directory:
# mounted to read, and the server is told the file.
restart
out="$(cd "$work" && sc up --workdir ws --memory mem/memory.json --image img:1 2>&1)"; rc=$?
run="$(grep '^run --detach ' "$FIX/podman-calls")"
g=/home/agent/.local/share/mcp-memory
shared=()
for a in "${want[@]}"; do
  if [ "$a" = "$N-memory:$g:U" ]; then shared+=("$work/mem:$g:ro,z" --env "MEMORY_FILE_PATH=$g/memory.json")
  else shared+=("$a"); fi
done
[ "$rc" = 0 ] && [ "$run" = "${shared[*]}" ] && [ "${#shared[@]}" = "$((${#want[@]} + 2))" ] \
  && pass "up --memory mounts the graph's directory read-only in place of the volume and names the file" \
  || fail "up --memory: rc=$rc $out / $(diff <(printf '%s\n' "${shared[@]}") <(tr ' ' '\n' <<<"$run"))"
sc down > /dev/null

: > "$FIX/client-calls"
out="$(sc run hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "not running" <<<"$out" && [ ! -s "$FIX/client-calls" ] \
  && pass "run without a container says so" || fail "run without a container: rc=$rc $out"
out="$(sc down 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(tail -1 "$FIX/podman-calls")" = "rm --force --ignore --depend $N-agent" ] \
  && [ -n "$(secret osc)" ] && pass "down removes the container and keeps the secrets" \
  || fail "down: rc=$rc $out"
[ ! -s "$FIX/untimed" ] && pass "every command in the container is bounded in time" \
  || fail "commands in the container without a timeout: $(sort -u "$FIX/untimed")"
[ ! -e "$FIX/planted-host" ] && [ ! -e "$FIX/planted-client" ] && [ ! -e "$FIX/launcher-path-client" ] \
  && pass "no command of the caller's PATH or the work directory ran in place of the launcher's" \
  || fail "a planted command ran: $(cd "$FIX" && echo planted-* launcher-path-clien[t])"
[ "$(wc -l < "$FIX/opencode-calls")" = "$oc0" ] && pass "up, attach, run and down start no opencode on the host" \
  || fail "an opencode ran on the host: $(tail -n "+$((oc0 + 1))" "$FIX/opencode-calls")"
[ ! -e "$FIX/env-leak" ] && pass "the server password is in the environment and the arguments of no command" \
  || fail "the server password reached: $(sort -u "$FIX/env-leak" | tr '\n' ' ')"
[ ! -e "$FIX/secret-leak" ] && pass "no login is in the arguments or the environment of a command" \
  || fail "a login reached: $(sort -u "$FIX/secret-leak" | tr '\n' ' ')"
left="$(leakfiles)"
[ -z "$left" ] && pass "no login is left in a file" || fail "a login is in: $left"
[ ! -e "$FIX/cwd-leak" ] && pass "no command starts in the work directory" \
  || fail "started in the work directory: $(sort -u "$FIX/cwd-leak" | tr '\n' ' ')"
# The launcher names no command by its path and sets PATH in two ways only:
# each command it runs is one of the checked ones.
[ "$(grep -owE 'PATH=[^ ]+' "$SC" | LC_ALL=C sort -u)" = "$(printf '%s\n' \
  'PATH=$userpath' 'PATH=${SKILL_CONTAINER_PATH:-/usr/local/bin:/usr/bin:/bin}')" ] \
  && ! tail -n +2 "$SC" | grep -qE '/(s?bin|libexec)/|command +-p' \
  && pass "the launcher takes every command from its own PATH" \
  || fail "the launcher names a command by its path or sets another PATH"
out="$(sc frobnicate 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q '^usage:' <<<"$out" && pass "an unknown command prints the usage" \
  || fail "unknown command: rc=$rc"

echo "---"; [ "$fails" = 0 ] && echo "all skill-container checks passed" || echo "$fails FAILED"
exit $((fails > 0))
