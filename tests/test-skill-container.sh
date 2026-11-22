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
# $work and $open lie in /tmp whatever TMPDIR says: install mounts a work directory at
# its own path and refuses one under /var.
work="$(mktemp -d -p /tmp)"; tools="$(mktemp -d)"; open="$(mktemp -d -p /tmp)"; trap 'rm -rf "$work" "$tools" "$open"' EXIT
FIX="$work/fix"; export FIX
N=opensuse-packaging

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
[ ! -e "$FIX/want-locale" ] || printf '%s %s\n' "${0##*/}" "${LC_ALL-unset}" >> "$FIX/locale-seen"
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
# Each running container and its network namespace, as podman prints them for
# this format alone: a client shares the server's.
"ps --namespace")
  [ ! -e "$FIX/netns-fails" ] || exit 1
  [ "$3 $4" = '--format {{.Names}} {{.Namespaces.NET}}' ] && [ $# = 4 ] || exit 97
  cat "$FIX/netns" ;;
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
  # The memory seed: cp -n keeps what a volume already holds.
  case "$*" in
  *"test -e /seed/"*) [ -e "$FIX/seed-exists" ]; exit ;;
  *"cp -n /src/"* | *"cp /src/"*)
    printf '%s\n' "$*" >> "$FIX/seed-calls"
    : > "$FIX/seeded"
    [ ! -e "$FIX/seed-fails" ]; exit ;;
  *)
    printf '%s\n' "$*" >> "$FIX/client-calls"
    ;;
  esac
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
  *"{{.Name}}|"*)
    [ "$3" = '{{.Name}}|{{range .Mounts}}{{if .RW}}|{{.Source}}{{end}}{{end}}' ] \
      && [ "$4" = beef01 ] && [ "$5" = beef02 ] && [ $# = 5 ] || exit 97
    srcs=$(tr '\n' '|' < "$FIX/others")
    if [ -e "$FIX/own-name" ]; then printf '/%s|%s\n' "$(cat "$FIX/own-name")" "$srcs"
    else printf '/beef01|%s\n/beef02|%s\n' "$srcs" "$srcs"; fi ;;
  esac ;;
# The image a name stands for now: the running one unless a newer was pulled.
"image inspect") if [ -e "$FIX/image-new" ]; then cat "$FIX/image-new"; else cat "$FIX/image"; fi ;;
"pull"*)
  printf '%s\n' "$*" >> "$FIX/pull-calls"
  # With $FIX/pull-busies a session begins while the image comes.
  [ ! -e "$FIX/pull-busies" ] \
    || echo '[{"id":"ses_p","permissions":null,"time":{"busy":5,"idle":2}}]' > "$FIX/sessions"
  [ ! -e "$FIX/pull-fails" ] ;;
"exec "*)
  # Every call into the container is one the launcher bounds in time.
  [ -n "${FAKE_TIMEOUT-}" ] || printf '%s\n' "$*" >> "$FIX/untimed"
  # Counts the calls of $1. Line N of $FIX/$1-script says how call N goes, as
  # with a podman another container keeps busy: silent answers nothing, fail is
  # podman's own error, slow the same 15 seconds later, exit2 answers and ends
  # with status 2; else it answers.
  busy() {
    echo >> "$FIX/$1-asked"
    case $(sed -n "$(wc -l < "$FIX/$1-asked")p" "$FIX/$1-script" 2>/dev/null) in
    silent) exit 0 ;;
    slow) sleep 15; echo "Error: BUSY-MARK the storage is locked" >&2; exit 125 ;;
    fail) echo "Error: BUSY-MARK the storage is locked" >&2; exit 125 ;;
    exit2) trap 'exit 2' EXIT ;;
    esac
  }
  # With $FIX/exec-escape whatever runs in the container tries the terminal on its error stream.
  [ ! -e "$FIX/exec-escape" ] || printf 'inside says\033]52;c;QUFB\007\033[2J\n' >&2
  case "$*" in
  # With $FIX/plugins-late holding N, the first N lists show no plugin yet.
  *"plugin list"*)
    n=$(cat "$FIX/plugins-late" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$FIX/plugins-late"; echo "ID  VERSION"; else cat "$FIX/plugins"; fi ;;
  *"auth import"*) busy import; cat > "$FIX/imported"; [ ! -e "$FIX/import-fails" ] ;;
  # A session the container imports from a pipe: stdin is the export.
  *"session import"*)
    cat > "$FIX/imported-session"
    [ ! -e "$FIX/import-fails" ] ;;
  # The model logins the state volume keeps; the answer holds their keys.
  # A client that repeats the answer on its error stream is the worst case.
  # With $FIX/logins-next the next answer differs.
  *"api GET /api/credential "*) busy logins; cat "$FIX/logins"; cat "$FIX/logins" >&2
    [ ! -e "$FIX/logins-next" ] || mv "$FIX/logins-next" "$FIX/logins" ;;
  *"api DELETE /api/credential/"*)
    busy logindel
    all="$*"; id=${all#*/api/credential/}; id=${id%% *}
    # With $FIX/login-stays the server refuses.
    [ ! -e "$FIX/login-stays" ] || exit 1
    # With $FIX/login-ghost it answers as the real one does for a login it does not hold.
    [ ! -e "$FIX/login-ghost" ] || exit 0
    jq -c --arg id "$id" '.data |= map(select(.id != $id))' "$FIX/logins" > "$FIX/logins.new" \
      && mv "$FIX/logins.new" "$FIX/logins" ;;
  *"api GET /api/project "*) busy projects; cat "$FIX/projects" ;;
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
    busy deletes
    all="$*"; id=${all#*/api/permission/saved/}; id=${id%% *}
    # With $FIX/keeps the server answers and removes nothing.
    [ -e "$FIX/keeps" ] || { jq -c --arg id "$id" '.data |= map(select(.id != $id))' "$FIX/saved" \
      > "$FIX/saved.new" && mv "$FIX/saved.new" "$FIX/saved"; } ;;
  # The session list, two to a page whatever the limit; the cursor is the offset
  # and never null. What is no list is answered as it is.
  *"api GET /api/session?limit=1000"*)
    busy sessions
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
    busy patches
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
# The caller's opencode, which `secrets` and `import` alone start: builtins
# only, it runs with the caller's PATH.
cat > "$tools/userbin/opencode" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
printf '%s\n' "$*" >> "$FIX/opencode-calls"
printf '%s' "$0" > "$FIX/client-path"
printf '%s' "$PATH" > "$FIX/client-PATH"
# The sessions of the project the caller names: the host's own.
if [ "$1 $2" = "session list" ]; then cat "$FIX/host-sessions"; exit 0; fi
if [ "$1 $2" = "session export" ]; then
  if [ -e "$FIX/export-busy" ]; then cat "$FIX/host-export-busy"; else cat "$FIX/host-export"; fi
  exit 0
fi
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
# systemctl: the units install writes and up starts. Records every call and
# stands in for the unit: start activates it, stop and restart clear it.
cat > "$tools/bin/systemctl" <<'EOF'
#!/bin/bash
. "$FIX/envcheck"
PATH=/usr/bin:/bin
[ "$1" = --user ] && shift
printf '%s\n' "$*" >> "$FIX/systemctl-calls"
case "$1" in
daemon-reload) [ ! -e "$FIX/reload-fails" ] || exit 1 ;;
disable | reset-failed) ;;
start) [ ! -e "$FIX/start-fails" ] || exit 1; [ ! -e "$FIX/run-fails" ] || exit 125
  # With $FIX/start-slow holding N, the start takes N seconds.
  [ ! -e "$FIX/start-slow" ] || sleep "$(cat "$FIX/start-slow")"
  [ -e "$FIX/stops" ] || echo true > "$FIX/running" ;;
stop) echo false > "$FIX/running" ;;
restart) [ ! -e "$FIX/start-fails" ] || exit 1; [ ! -e "$FIX/run-fails" ] || exit 125
  echo true > "$FIX/running" ;;
is-active) grep -qx true "$FIX/running" ;;
*) echo "fake systemctl: unexpected $*" >&2; exit 99 ;;
esac
EOF
# The real commands of the launcher, each behind the same check.
for f in python3 jq realpath head base64 tr id mkdir seq sleep cat ls cp cmp mktemp rm ln ssh-keygen git rmdir; do
  printf '%s\n' '#!/bin/bash' '. "$FIX/envcheck"' "exec $(command -v "$f") \"\$@\"" > "$tools/bin/$f"
done
# The launcher's pauses are recorded; with $FIX/sleep-fast they take no time.
printf '%s\n' '#!/bin/bash' '. "$FIX/envcheck"' 'printf "%s\n" "$*" >> "$FIX/sleep-calls"' \
  '[ ! -e "$FIX/sleep-fast" ] || exit 0' "exec $(command -v sleep) \"\$@\"" > "$tools/bin/sleep"
# A read that fails is asked again for five minutes: no check waits that long.
touch "$FIX/sleep-fast"
# A client among the launcher's own commands is not the caller's.
printf '%s\n' '#!/bin/bash' ': > "$FIX/launcher-path-client"; exit 1' > "$tools/bin/opencode"
# First on the caller's PATH: what the launcher must take from its own.
for f in podman python3 jq realpath sed timeout head base64 tr id mkdir seq sleep cat ls gh cp cmp mktemp rm systemctl ln ssh-keygen git rmdir; do
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
printf %s "$work/ws" > "$FIX/workdir"
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
# The servers of the instances that idle and update ask about, each in a
# network namespace of its own, and a container that shares none; with
# arguments, further containers.
netns() { printf '%s\n' "$N-nol-agent 4026530001" "$N-pub-agent 4026530002" "spike-x 4026530099" "$@" > "$FIX/netns"; }
netns
# The sessions of the host project, as `session list` answers them.
printf '%s\n' '[{"id":"ses_h1","title":"host one"},{"id":"ses_h2","title":"host two"}]' > "$FIX/host-sessions"
# And their export: idle, with the transcript the container keeps.
printf '%s\n' '{"info":{"id":"ses_h1","title":"host one","location":{"directory":"/home/user/obs"},"time":{"busy":1,"idle":2}},"messages":[{"id":"msg_1","type":"user","text":"hello"}]}' > "$FIX/host-export"
printf '%s\n' '{"info":{"id":"ses_h1","title":"host one","location":{"directory":"/home/user/obs"},"time":{"busy":3,"idle":2}},"messages":[{"id":"msg_1","type":"user","text":"hello"}]}' > "$FIX/host-export-busy"
# The fixed copy install asks for: the launcher itself.
mkdir -p "$work/home/.local/bin"
cp "$SC" "$work/home/.local/bin/skill-container"
cp -r "$HERE/../contrib/container/systemd" "$work/home/.local/bin/systemd"
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
  } | xargs -r -d '\n' grep -lE -- 'SECRET[-_][0-9]|TEA-OTHER' 2> /dev/null | grep -vxF -f <(printf '%s\n' "${fixtures[@]}") | mine
}
# Another launcher suite running at the same time keeps its fixtures in a
# directory like ours, with fix/envcheck in it, and its commands in one like
# $tools: those are its logins, not a leak.
mine() {
  local f d rest top
  while IFS= read -r f; do
    top=''
    for d in /tmp /var/tmp /dev/shm "/run/user/$(id -u)"; do
      [[ $f == "$d"/*/* ]] || continue
      rest=${f#"$d"/}
      top=$d/${rest%%/*}
    done
    [ -n "$top" ] && [ "$top" != "$work" ] && [ -e "$top/fix/envcheck" ] && continue
    [ -n "$top" ] && [ "$top" != "$tools" ] && [ -f "$top/bin/podman" ] && [ -d "$top/userbin" ] \
      && [ -d "$top/evilbin" ] && continue
    printf '%s\n' "$f"
  done
}
secret() { cat "$FIX/secrets/$N-$1" 2>/dev/null; }
stored() { cat "$FIX/secrets/"* | sha256sum; }
# The container was removed after it last started.
stopped() { grep -qx "stop $N-agent@obs.service" "$FIX/systemctl-calls"; }
# No made-up secret may reach the terminal or a command line.
leaks() { grep -E 'SECRET[-_][0-9]|TEA-OTHER' "$@" 2>/dev/null; }
# What the launcher says when it tries again.
again="skill-container: could not read or change what $N-obs-agent keeps; trying again for up to 5 minutes"
# $1: what the fake podman counts, $2...: how its calls go in turn (see busy
# there). No other call is scripted, and the pauses start anew.
scripted() { rm -f "${FIX:?}"/*-script; printf '%s\n' "${@:2}" > "$FIX/$1-script"; : > "$FIX/$1-asked"; : > "$FIX/sleep-calls"; }
# Every call of $1 after the first ${3:-0} goes as $2.
never() { scripted "$1"; { yes ok | head -n "${3:-0}"; yes "$2" | head -n 100; } > "$FIX/$1-script"; }
reads() { wc -l < "$FIX/$1-asked"; }
pauses() { wc -l < "$FIX/sleep-calls"; }

out="$(sc install obs --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "secrets" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install without secrets starts nothing" || fail "install without secrets: rc=$rc $out"

out="$(sc secrets 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ -z "$(ls "$FIX/secrets")" ] && pass "secrets needs --model-auth" \
  || fail "secrets without --model-auth: rc=$rc $out"
out="$(sc ssh-key 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no secret $N-ssh" <<<"$out" && pass "ssh-key before secrets says so" \
  || fail "ssh-key without the secret: rc=$rc $out"

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
out="$(PYTHONPATH="$work/planted" sc install obs --workdir "$work/ws" --memory "$work/none" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "not a file: $work/none" <<<"$out" && [ ! -e "$FIX/planted-ran" ] \
  && pass "install imports no module from PYTHONPATH" || fail "install with PYTHONPATH on planted modules: rc=$rc $out"
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
[ "$rc" = 0 ] && [ "$out" = "$(printf '%s\n' $N-osc $N-tea $N-github $N-model $N-bugzilla $N-ssh)" ] \
  && pass "secrets prints the six names only" || fail "secrets: rc=$rc $out"
# The SSH key: made by the first run, with no file of it left behind.
key1="$(secret ssh)"
grep -q 'BEGIN OPENSSH PRIVATE KEY' <<<"$key1" && [ -z "$(find "$work/run" -name 'tmp.*')" ] \
  && pass "secrets makes an SSH key and leaves no copy" || fail "the SSH key: $(find "$work/run" -name 'tmp.*')"
out="$(sc ssh-key 2>&1)"; rc=$?
[ "$rc" = 0 ] && [[ $out == "ssh-ed25519 "*" $N" ]] && [ "$(wc -l <<<"$out")" = 1 ] \
  && pass "ssh-key prints the public half alone" || fail "ssh-key: rc=$rc $(wc -l <<<"$out") lines"
out="$(sc secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(secret ssh)" = "$key1" ] && pass "a later secrets run keeps the SSH key" \
  || fail "the SSH key after a second run: rc=$rc"
out="$(sc secrets --model-auth prov --new-ssh-key 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(secret ssh)" != "$key1" ] && secret ssh | grep -q 'BEGIN OPENSSH PRIVATE KEY' \
  && pass "--new-ssh-key replaces the SSH key" || fail "--new-ssh-key: rc=$rc"
# A key of the caller's own instead: copied as it is, and judged before any
# secret is replaced.
ssh-keygen -q -t ed25519 -N '' -C own -f "$work/ownkey"
ssh-keygen -q -t ed25519 -N locked -C own -f "$work/lockedkey"
printf 'no key\n' > "$work/nokey"
out="$(cd "$work" && sc secrets --model-auth prov --ssh-key ownkey 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(secret ssh)" = "$(cat "$work/ownkey")" ] && [ -z "$(find "$work/run" -name 'tmp.*')" ] \
  && pass "--ssh-key stores the named key and leaves no copy" || fail "--ssh-key: rc=$rc $out"
out="$(sc ssh-key 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(cat "$work/ownkey.pub")" ] && pass "ssh-key prints the public half of the named key" \
  || fail "ssh-key after --ssh-key: rc=$rc"
out="$(sc secrets --model-auth prov 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(secret ssh)" = "$(cat "$work/ownkey")" ] && pass "a later secrets run keeps the named key" \
  || fail "the named key after a second run: rc=$rc"
before="$(stored)"
for k in lockedkey nokey none run; do
  out="$(GH_CONFIG_DIR="$FIX/ghalt" sc secrets --model-auth prov --ssh-key "$work/$k" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "$work/$k" <<<"$out" && [ "$(stored)" = "$before" ] \
    && [ -z "$(find "$work/run" -name 'tmp.*')" ] && ! grep -q 'PRIVATE KEY' <<<"$out" \
    && pass "--ssh-key refuses what is no key without a passphrase: nothing replaced ($k)" \
    || fail "--ssh-key $k: rc=$rc $out"
done
out="$(GH_CONFIG_DIR="$FIX/ghalt" sc secrets --model-auth prov --ssh-key "$work/ownkey" --new-ssh-key 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF -- "--new-ssh-key" <<<"$out" && [ "$(stored)" = "$before" ] \
  && pass "--ssh-key and --new-ssh-key together are refused" \
  || fail "--ssh-key with --new-ssh-key: rc=$rc $out"
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
: > "$work/empty-key"; mkdir "$work/key-dir"
for key in "$work/no-key" "$work/empty-key" "$work/key-dir"; do
  out="$(sc secrets --model-auth prov --bugzilla-key "$key" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "no Bugzilla API key" <<<"$out" && [ "$(stored)" = "$before" ] \
    && pass "no Bugzilla key in ${key##*/}: nothing replaced" \
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
  out="$(sc install obs --workdir "$d" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && ! grep -q '^run ' "$FIX/podman-calls" && pass "install refuses $d" \
    || fail "install --workdir $d: rc=$rc $out"
done
# Podman's volumes can lie outside its storage.
mkdir -p "$work/vols/v/_data" "$work/vols/g/_data" "$FIX/store/volumes/g/_data" "$FIX/store/overlay"
echo "$work/vols" > "$FIX/volpath"
for d in "$work/vols/v/_data" "$FIX/store/overlay"; do
  out="$(sc install obs --workdir "$d" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "the work directory is one you own" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a work directory in podman's storage or volumes (${d#"$work"})" \
    || fail "install --workdir $d: rc=$rc $out"
done
# Nor is the graph a file there or in the storage: a container that mounts the
# volume writes it.
for d in "$work/vols/g/_data" "$FIX/store/volumes/g/_data"; do
  printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' > "$d/memory.json"
  out="$(sc install obs --workdir "$work/ws" --memory "$d/memory.json" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "memory.json: it lies in podman's storage" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a graph in podman's storage (${d#"$work"})" || fail "install --memory $d/memory.json: rc=$rc $out"
done
echo "$FIX/store/volumes" > "$FIX/volpath"
# Another owner's directory below a closed one of the caller: without root
# only a subordinate uid makes one.
mkdir "$work/foreign"
if unshare --user --map-root-user --map-users=auto chown 1 "$work/foreign" 2> /dev/null; then
  out="$(sc install obs --workdir "$work/foreign" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "the work directory is one you own" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a work directory of another owner" || fail "install --workdir of another owner: rc=$rc $out"
else
  echo "SKIP: a work directory of another owner (no subordinate uids here)"
fi
rmdir "$work/foreign"
out="$(cd "$work/ws" && sc install obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "is required" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install without --workdir starts nothing, wherever it is called" || fail "install without --workdir: rc=$rc $out"
out="$(SC_HOME="$work/homelink" sc install obs --workdir "$work/home" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ! grep -q '^run ' "$FIX/podman-calls" && pass "install refuses the home directory behind a link" \
  || fail "install --workdir on a linked home: rc=$rc $out"

# Every login is there before a container starts.
mv "$FIX/secrets/$N-ssh" "$FIX/ssh.kept"
out="$(sc install obs --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no secret $N-ssh" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install without the SSH key starts nothing" || fail "install without the SSH key: rc=$rc $out"
mv "$FIX/ssh.kept" "$FIX/secrets/$N-ssh"
mv "$FIX/secrets/$N-github" "$FIX/github.kept"
out="$(sc install obs --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no secret $N-github" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install without the GitHub secret starts nothing" || fail "install without the GitHub secret: rc=$rc $out"

# The agent runs as the caller and can make a file setuid to them: a directory
# above what it writes is the caller's and closed to everyone else. ($open
# lies in a temporary directory that is open, as /tmp is.)
mkdir -p "$open/ws" "$open/mid/ws" "$open/vol"
chmod 700 "$open/ws"
for mode in 755 750 710 701; do
  chmod "$mode" "$open"
  out="$(sc install obs --workdir "$open/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "closed to other users" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a work directory below a directory others can enter ($mode)" \
    || fail "install below a directory of mode $mode: rc=$rc $out"
done
echo "$open/vol" > "$FIX/volpath"
out="$(sc install obs --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "podman's volumes in $open/vol need" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install refuses volumes below a directory others can enter" || fail "install with open volumes: rc=$rc $out"
echo "$FIX/store/volumes" > "$FIX/volpath"
# Closed two levels up: the check goes on to the logins.
chmod 700 "$open"; chmod 755 "$open/mid"
out="$(sc install obs --workdir "$open/mid/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no secret $N-github" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install takes a work directory with a closed directory further up" || fail "install below a closed directory: rc=$rc $out"
# Root owns what lies above: where the directories above belong to neither
# root nor the caller, as an unmapped owner shows in a user namespace, the
# closed one counts for nothing.
if unshare --user --map-user="$(id -u)" true 2> /dev/null; then
  out="$(unshare --user --map-user="$(id -u)" "${scenv[@]}" HOME="$work/home" bash "$SC" install obs --workdir "$open/mid/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "closed to other users" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a work directory below one that neither root nor the caller owns" \
    || fail "install below a directory of another owner: rc=$rc $out"
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
  out="$(sc install obs --workdir "$open/c/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "closed to other users" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a work directory below a directory others can write ($mode)" \
    || fail "install below a directory of mode $mode: rc=$rc $out"
  out="$(sc install obs --workdir "$work/ws" --memory "$open/gm/memory.json" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "another user can write a directory above it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a graph below a directory others can write ($mode)" \
    || fail "install --memory below a directory of mode $mode: rc=$rc $out"
done
echo "$open/c/vol" > "$FIX/volpath"
out="$(sc install obs --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "podman's volumes in $open/c/vol need" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install refuses volumes below a directory others can write" || fail "install with volumes others can replace: rc=$rc $out"
# A directory that is not there yet is not a closed one.
chmod 1777 "$open"
echo "$open/missing/volumes" > "$FIX/volpath"
out="$(sc install obs --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "podman's volumes in $open/missing/volumes need" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install refuses volumes below a missing directory with no closed one above" \
  || fail "install with volumes below a missing directory: rc=$rc $out"
echo "$FIX/store/volumes" > "$FIX/volpath"
for mode in 1777 755; do
  chmod "$mode" "$open"
  out="$(sc install obs --workdir "$open/c/ws" --memory "$open/gm/memory.json" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "no secret $N-github" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install takes a work directory and a graph below a directory others cannot replace them in ($mode)" \
    || fail "install below a directory of mode $mode: rc=$rc $out"
done
chmod 777 "$open/gm"
out="$(sc install obs --workdir "$open/c/ws" --memory "$open/gm/memory.json" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "another user can write a directory above it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install refuses a graph in a directory others can write" || fail "install --memory in an open directory: rc=$rc $out"
chmod 700 "$open"
# What a link names is taken where the link leads: the directory of the
# logins, the runtime directory, podman's storage and its volumes.
# $1 = what lies behind the link, $2 = the refusal, then assignments for the
# environment and the arguments of up.
linked() {
  local label=$1 want=$2 envs=(); shift 2
  while [[ $1 == *=* ]]; do envs+=("$1"); shift; done
  out="$("${scenv[@]}" HOME="$work/home" "${envs[@]}" bash "$SC" install obs "$@" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF -- "$want" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses $label behind a link" || fail "install with $label behind a link: rc=$rc $out"
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
  out="$(sc install obs --workdir "$work/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "a running container writes" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a work directory a running container writes around (${other#"$work"}/)" \
    || fail "install while a container writes $other: rc=$rc $out"
done
mkdir -p "$work/memc/g"
printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' > "$work/memc/g/memory.json"
for other in "$work/memc" "$work/memc/g" "$work/memc/g/sub" "$work/memc/g/_data"; do
  printf '%s\n' "$other" /srv/elsewhere > "$FIX/others"
  out="$(sc install obs --workdir "$work/ws" --memory "$work/memc/g/memory.json" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "memory.json: a running container writes" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a graph a running container writes around (${other#"$work"}/)" \
    || fail "install --memory while a container writes $other: rc=$rc $out"
done
printf '%s\n' /srv/elsewhere "$work/ws2" "$work/mem2" > "$FIX/others"
touch "$FIX/ps-fails"
out="$(sc install obs --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "cannot list what the running containers mount" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install starts nothing when the running containers cannot be listed" || fail "install without a container list: rc=$rc $out"
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
  out="$(sc install obs --workdir "$work/ws" --memory "$work/$file" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "$why" <<<"$out" && [ -z "$(leaks <<<"$out")" ] && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses the memory graph $file" || fail "install --memory $file: rc=$rc $out"
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
  out="$(sc install obs --workdir "$d" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "a symlink leads to it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a work directory behind a link (${d#"$work/"})" || fail "install --workdir $d: rc=$rc $out"
done

# Commands are looked up nowhere in the work directory: not on the caller's
# PATH, not behind a link, not on the launcher's own.
n=0
for p in "PATH=$callerpath:$work/ws/bin" "PATH=$callerpath:$tools/wslink" "SKILL_CONTAINER_PATH=$ownpath:$work/ws/bin" \
  "PATH=$callerpath:$work/ws/pathlink" "SKILL_CONTAINER_PATH=$ownpath:$work/ws/pathlink" \
  "PATH=$callerpath:$work/ws" "SKILL_CONTAINER_PATH=$ownpath:$work/ws"; do
  n=$((n+1))
  out="$("${scenv[@]}" "$p" HOME="$work/home" bash "$SC" install obs --workdir "$work/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "lies in the work directory" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a work directory that commands are looked install in ($n)" \
    || fail "install with a PATH entry in the work directory ($n): rc=$rc $out"
done
out="$("${scenv[@]}" "SKILL_CONTAINER_PATH=bin:$ownpath" HOME="$work/home" bash "$SC" install obs --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "not an absolute path" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
  && pass "install refuses a relative entry among the launcher's own directories" \
  || fail "install with a relative SKILL_CONTAINER_PATH entry: rc=$rc $out"
# An entry with . or .. is not the directory it reads as; a name that starts
# with a dot is.
mkdir -p "$tools/.dot/..dot"
n=0
for p in "PATH=$callerpath:$tools/userbin/../userbin" "PATH=$callerpath:$tools/./userbin" "PATH=$callerpath:$tools/userbin/." \
  "PATH=$callerpath:$tools/userbin/.." "SKILL_CONTAINER_PATH=$ownpath/../bin" "LD_LIBRARY_PATH=$tools/../lib" \
  "LD_PRELOAD=$tools/./x.so"; do
  n=$((n+1))
  out="$("${scenv[@]}" "$p" HOME="$work/home" bash "$SC" install obs --workdir "$work/ws" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "with a . or .. in it" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses an entry with . or .. in it ($n)" || fail "install with $p: rc=$rc $out"
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
  out="$(ld "$p" install obs --workdir "$work/ws")"; rc=$?
  [ "$rc" != 0 ] && grep -qF "lies in the work directory" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses a work directory that libraries are looked install in ($n)" \
    || fail "install with a loader entry in the work directory ($n): rc=$rc $out"
done
# An empty or relative entry is looked up where a command starts.
n=0
for p in "LD_LIBRARY_PATH=$tools/lib:" "LD_LIBRARY_PATH=:$tools/lib" "LD_LIBRARY_PATH=lib" \
  "LD_LIBRARY_PATH=$tools/lib;lib" "LD_PRELOAD=lib/x.so" "LD_PRELOAD=$tools/lib/a.so lib/x.so" \
  "LD_AUDIT=lib/x.so" "LD_AUDIT=$tools/lib/a.so:lib/x.so"; do
  n=$((n+1))
  out="$(ld "$p" install obs --workdir "$work/ws")"; rc=$?
  [ "$rc" != 0 ] && grep -qF "not an absolute path" <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses an empty or relative entry in a list of the loader ($n)" \
    || fail "install with an empty or relative loader entry ($n): rc=$rc $out"
done
for p in "LD_LIBRARY_PATH=$tools/"'$LIB' "LD_PRELOAD=$tools/"'$LIB/x.so'; do
  out="$(ld "$p" install obs --workdir "$work/ws")"; rc=$?
  [ "$rc" != 0 ] && grep -qF 'with a $' <<<"$out" && ! grep -q '^run ' "$FIX/podman-calls" \
    && pass "install refuses an entry the loader would rewrite (${p%%=*})" || fail "install with $p: rc=$rc $out"
done

# From here on no opencode starts on the host: the client's is in a container.
oc0="$(wc -l < "$FIX/opencode-calls")"
printf '%s\n' '{"data":[{"id":"per_a1","projectID":"prj_main","action":"shell","resource":"*"},{"id":"per_b2","projectID":"prj_main","action":"edit","resource":"*"}]}' \
  > "$FIX/saved"
sessions "[{\"id\":\"ses_u1\",\"permissions\":$allow}]"
kept_login cred_old1
# A work directory named from the current one. install validates it and writes
# the unit; up starts it.
out="$(cd "$work" && sc install obs --workdir ws --image img:1 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$work/home/.config/containers/systemd/$N-agent@obs.container.d/10-workdir.conf" ] \
  && [ -L "$work/home/.config/containers/systemd/$N-agent@obs.container" ] \
  && pass "install writes the unit drop-in" || fail "install: rc=$rc $out"
drop="$(cat "$work/home/.config/containers/systemd/$N-agent@obs.container.d/10-workdir.conf")"
[ "$drop" = "$(printf '%s\n' "# Written by skill-container install obs. Do not edit: install writes it again." \
  "[Container]" "Volume=$work/ws:$work/ws:Z" "WorkingDir=$work/ws" "Image=img:1")" ] \
  && pass "install writes the work directory and the image into the drop-in" || fail "the drop-in: $drop"
[ "$(cat "$work/config/skill-container/$N/obs.dir")" = "$(printf '%s\n' "$work/ws" "$work/ws" img:1)" ] \
  && pass "install writes the state file" || fail "the state file"
[ "$(grep -c daemon-reload "$FIX/systemctl-calls")" = 1 ] \
  && [ -f "$work/home/.config/containers/systemd/$N-agent@.container" ] \
  && [ -f "$work/home/.config/systemd/user/$N-agent@.service.d/20-depend.conf" ] \
  && [ -f "$work/home/.config/systemd/user/$N-relay@.service" ] \
  && [ -f "$work/home/.config/systemd/user/$N-update@.timer" ] \
  && pass "install installs the units" || fail "install and the units"
: > "$FIX/systemctl-calls"
out="$(sc up obs --model prov/model 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qx "start $N-agent@obs.service" "$FIX/systemctl-calls" \
  && pass "up starts the unit" || fail "up and the unit: rc=$rc $out"
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
[ "$rc" = 0 ] && grep -qxF "obs is up, work directory $work/ws" <<<"$out" && ! stopped && pass "up says where the instance works" \
  || fail "up: rc=$rc $out"
pw="$(secret obs-server-password)"
[ "${#pw}" = 32 ] && [ "$(secret obs-server-password | wc -l)" = 0 ] \
  && grep -qx "secret create --replace $N-obs-server-password -" "$FIX/podman-calls" \
  && pass "up makes a 24-byte server password without a newline" \
  || fail "the server password: ${#pw} characters"
# The lockdown lives in the unit file the service starts: every flag the
# pilot checked on the podman command line is there, and the service refuses
# the locked-down shape no update may change.
missed=0
for line in "UserNS=keep-id" "ReadOnly=true" "DropCapability=all" "NoNewPrivileges=true" "Pull=never" \
  "Secret=opensuse-packaging-%i-server-password,type=env,target=OPENCODE_PASSWORD" \
  "Secret=opensuse-packaging-osc,target=/home/agent/.config/osc/oscrc,uid=%U,gid=%G,mode=0600" \
  "Secret=opensuse-packaging-tea,target=/home/agent/.config/tea/config.yml,uid=%U,gid=%G,mode=0400" \
  "Secret=opensuse-packaging-github,target=/home/agent/.config/gh/hosts.yml,uid=%U,gid=%G,mode=0400" \
  "Secret=opensuse-packaging-bugzilla,target=/home/agent/.config/mcp-bugzilla/api-key,uid=%U,gid=%G,mode=0400" \
  "Secret=opensuse-packaging-ssh,target=/home/agent/.ssh/id_ed25519,uid=%U,gid=%G,mode=0400" \
  "StartLimitIntervalSec=600" "StartLimitBurst=5" "SuccessExitStatus=143" \
  "Volume=opensuse-packaging-%i-state:/home/agent/.local/share/opencode:U" \
  "Volume=opensuse-packaging-%i-memory:/home/agent/.local/share/mcp-memory:U" \
  "Volume=opensuse-packaging-%i-toolstate:/home/agent/.local/state:U" \
  "Volume=opensuse-packaging-%i-scratch:/var/tmp" \
  "Exec=opencode serve --hostname 127.0.0.1 --port 4096"; do
  grep -qxF "$line" "$HERE/../contrib/container/systemd/opensuse-packaging-agent@.container" \
    || missed=$((missed + 1))
done
[ "$missed" = 0 ] && pass "the unit runs the container locked down, with its secrets and volumes" \
  || fail "the unit lost its lockdown"
! grep -qF "$N-model" <<<"$out" && grep -qF MODEL-SECRET-6 "$FIX/imported" \
  && grep -q "^exec -i $N-obs-agent opencode auth import --server http://127.0.0.1:4096$" "$FIX/podman-calls" \
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
cl=(run --rm --pull=never --network "container:$N-obs-agent" --userns "container:$N-obs-agent"
  --user "$(id -u):$(id -g)" --read-only --cap-drop=all --security-opt no-new-privileges --init
  --http-proxy=false --log-driver=none
  --secret "$N-obs-server-password,type=env,target=OPENCODE_PASSWORD"
  --env FORCE_HYPERLINK=0 --env TERM --env COLORTERM
  --tmpfs "/home/agent/.local/share/opencode:rw,mode=0700,U"
  --tmpfs "/home/agent/.local/state:rw,mode=0700,U" --tmpfs "/home/agent/.cache:rw,mode=0700,U"
  --tmpfs "$work/ws:ro,mode=0555,notmpcopyup" --workdir "$work/ws")
# The last client's container against the one expected, and where they differ.
client() { [ "$(tail -1 "$FIX/client-calls")" = "${cl[*]} $*" ]; }
differs() { diff <(printf '%s\n' "${cl[@]}" "$@") <(tail -1 "$FIX/client-calls" | tr ' ' '\n'); }
rm -f "$FIX/sed-password"
out="$(cd / && VISUAL=vi EDITOR=vi FORCE_HYPERLINK=1 http_proxy=http://proxy.example:3128 sc run obs --continue hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && client "$img" opencode run --server "$inner" --continue hello \
  && pass "run starts the client in a container of its own: the server's image, network and users, nothing of the host" \
  || fail "run: rc=$rc $out / $(differs "$img" opencode run --server "$inner" --continue hello)"
grep -qx "inspect --format {{.Image}} $N-obs-agent" "$FIX/podman-calls" \
  && pass "run takes the image from the server's container, by its id" || fail "run did not ask for the server's image"
[ -s "$FIX/sed-password" ] && ! grep -qv '^unset$' "$FIX/sed-password" \
  && pass "the filter of run starts without the server password" || fail "the filter of run got the password"
# Called from the work directory, the launcher's commands still start in /.
out="$(cd "$work/ws" && sc run obs hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$FIX/cwd-leak" ] && client "$img" opencode run --server "$inner" hello \
  && pass "run from the work directory starts no command there" \
  || fail "run from the work directory: rc=$rc $out / $(sort -u "$FIX/cwd-leak" 2> /dev/null | tr '\n' ' ')"
# attach gives the client's container the caller's terminal, and starts
# nothing without one at both ends.
rm -f "$FIX/client-tty"
out="$(tty attach obs --session s1 2>&1)"; rc=$?
[ "$rc" = 0 ] && client --interactive --tty --detach-keys= "$img" opencode --server "$inner" --session s1 \
  && [ "$(cat "$FIX/client-tty")" = yes ] \
  && pass "attach starts the client in a container of its own, on the caller's terminal" \
  || fail "attach: rc=$rc $out / $(differs --interactive --tty --detach-keys= "$img" opencode --server "$inner" --session s1)"
n0="$(wc -l < "$FIX/podman-calls")"
out="$(sc attach obs --session s1 2>&1 < /dev/null)"; rc=$?
[ "$rc" = 1 ] && grep -qF "attach needs a terminal" <<<"$out" && [ "$(wc -l < "$FIX/podman-calls")" = "$n0" ] \
  && pass "attach without a terminal starts nothing" || fail "attach without a terminal: rc=$rc $out"
n=0
# The third: the output is no terminal, the error stream is one.
for half in '2>&1 < /dev/null' '2>&1 | while IFS= read -r l; do printf "%s\n" "$l"; done' '> /dev/null'; do
  n=$((n+1))
  out="$(pty "${scenv[@]}" HOME="$work/home" SC="$SC" bash -o pipefail -c "bash \"\$SC\" attach obs $half" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && grep -qF "attach needs a terminal" <<<"$out" && [ "$(wc -l < "$FIX/podman-calls")" = "$n0" ] \
    && pass "attach with a terminal at one end only starts nothing ($n)" || fail "attach with half a terminal ($n): rc=$rc $out"
done
touch "$FIX/escapes"
tty attach obs > /dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && pass "attach ends with the client's exit status" || fail "attach and the client's exit status: rc=$rc"
rm "$FIX/escapes"
# attach and run pass on the flags the launcher names and no other: not the
# three that answer every permission with yes, in any form opencode reads, and
# not the one that names a file: the client's container holds none of the caller's.
out="$(sc run obs -c --session=s1 --fork -m prov/model --agent build --format json --title=-t --thinking hello there 2>&1)"; rc=$?
[ "$rc" = 0 ] && client "$img" opencode run --server "$inner" -c --session=s1 --fork -m prov/model --agent build --format json --title=-t --thinking hello there \
  && pass "run passes on the flags it names" || fail "run with its flags: rc=$rc $out / $(tail -1 "$FIX/client-calls")"
out="$(tty attach obs --continue -s s1 --prompt=hi 2>&1)"; rc=$?
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
run obs --auto hello|run passes on these opencode flags only
run obs --auto=true hello|run passes on these opencode flags only
run obs --yolo hello|run passes on these opencode flags only
run obs --dangerously-skip-permissions hello|run passes on these opencode flags only
run obs --no-auto hello|run passes on these opencode flags only
run obs hello --auto|run passes on these opencode flags only
run obs -c --auto hello|run passes on these opencode flags only
run obs -- --auto|run passes on these opencode flags only
run obs -- hello|run passes on these opencode flags only
run obs hello -- --yolo|run passes on these opencode flags only
run obs --help|run passes on these opencode flags only
run obs --standalone hello|run passes on these opencode flags only
run obs --server http://127.0.0.1:1 hello|run passes on these opencode flags only
run obs -x hello|run passes on these opencode flags only
run obs -cs s1 hello|run passes on these opencode flags only
run obs -f note hello|run passes on these opencode flags only
run obs --file=note hello|run passes on these opencode flags only
run obs --prompt hi hello|run passes on these opencode flags only
run obs -s --auto hello|-s needs a value
run obs -s -c hello|-s needs a value
run obs --model --agent build hello|--model needs a value
run obs hello --title|--title needs a value
run obs --continue=--auto hello|--continue takes no value
run obs -c=--auto hello|-c takes no value
run obs --thinking=--auto hello|--thinking takes no value
run obs --fork=x hello|--fork takes no value
attach obs --auto|attach passes on these opencode flags only
attach obs --auto=true|attach passes on these opencode flags only
attach obs --yolo|attach passes on these opencode flags only
attach obs --dangerously-skip-permissions|attach passes on these opencode flags only
attach obs -c --auto|attach passes on these opencode flags only
attach obs -- --auto|attach passes on these opencode flags only
attach obs --|attach passes on these opencode flags only
attach obs --print-logs|attach passes on these opencode flags only
attach obs --model prov/model|attach passes on these opencode flags only
attach obs --fork|attach passes on these opencode flags only
attach obs -f note|attach passes on these opencode flags only
attach obs -s --auto|-s needs a value
attach obs --prompt|--prompt needs a value
attach obs --continue=--auto|--continue takes no value
attach obs serve|attach takes flags only
attach obs /tmp|attach takes flags only
attach obs --session=s1 serve|attach takes flags only
attach obs -c serve|attach takes flags only
attach obs --prompt auth list|attach takes flags only
attach obs -s s1 web|attach takes flags only
EOF
# One word made of two flags of the list is no flag of it.
for refused in "attach|-c --continue" "attach|-s --session=--auto" "run|--title --thinking" "run|--agent --format=--auto"; do
  out="$(sc "${refused%%|*}" obs "${refused#*|}" hello 2>&1 < /dev/null)"; rc=$?
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
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -s "$FIX/client-calls" ] \
  && pass "run removes a saved approval, then starts the client" || fail "run with a saved approval: rc=$rc $out"
approval ../session/ses_1; : > "$FIX/sleep-calls"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && ! grep -qF "DELETE /api/permission/saved/.." "$FIX/podman-calls" \
  && [ ! -s "$FIX/sleep-calls" ] \
  && pass "run refuses a saved approval whose id is not one, at once" || fail "run with a made-up id: rc=$rc $out"
approval per_d4; touch "$FIX/keeps"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses while a saved approval stays" \
  || fail "run with an approval that stays: rc=$rc $out"
rm "$FIX/keeps"; echo '{"error":"no"}' > "$FIX/saved"; : > "$FIX/client-calls"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses when the saved approvals cannot be listed" \
  || fail "run without a list of approvals: rc=$rc $out"
echo '{"data":[]}' > "$FIX/saved"

# An approval belongs to a project: one of a project the server lists is found
# by that project's id, one of a project it does not list by the empty id.
echo '[{"id":"prj_main"},{"id":"prj_sub"}]' > "$FIX/projects"
approval per_s1 prj_sub; touch "$FIX/empty-lists-none"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -s "$FIX/client-calls" ] \
  && pass "run removes the approval of another project the server lists" \
  || fail "run with an approval of a listed project: rc=$rc $out"
rm "$FIX/empty-lists-none"; echo '[]' > "$FIX/projects"; approval per_e1 prj_evil
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -s "$FIX/client-calls" ] \
  && pass "run removes the approval of a project the server does not list" \
  || fail "run with an approval of an unlisted project: rc=$rc $out"
n=0
for projects in '{"error":"no"}' '' '[{"id":"../x"}]'; do
  n=$((n+1)); printf '%s' "$projects" > "$FIX/projects"; : > "$FIX/client-calls"; : > "$FIX/sleep-calls"
  out="$(sc run obs hello 2>&1)"; rc=$?
  # A list that is no list is asked for again; a project id that is none is not.
  [ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && ! grep -qF "projectID=.." "$FIX/podman-calls" \
    && { [ "$n" != 3 ] || [ ! -s "$FIX/sleep-calls" ]; } \
    && pass "run refuses when the projects cannot be listed ($n)" \
    || fail "run without a list of projects ($n): rc=$rc $out"
done
echo '[{"id":"prj_main"},{"id":"prj_sub"}]' > "$FIX/projects"; touch "$FIX/id-answers-nothing"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses when a project's approvals do not come" \
  || fail "run without an answer for a project: rc=$rc $out"
rm "$FIX/id-answers-nothing"; echo '[{"id":"prj_main"}]' > "$FIX/projects"

# So are a session's own rules: the one on the second page of the list as well.
sessions "[{\"id\":\"ses_a\",\"permissions\":null},{\"id\":\"ses_b\",\"permissions\":[]},{\"id\":\"ses_c\",\"permissions\":$allow}]"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c 'map(.permissions)' "$FIX/sessions")" = "[null,[],[]]" ] && [ -s "$FIX/client-calls" ] \
  && pass "run clears the rules of a session on a later page, then starts the client" \
  || fail "run with session rules: rc=$rc $out"
sessions "[{\"id\":\"ses_d\",\"permissions\":$allow}]"; touch "$FIX/keeps-rules"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses while a session keeps its rules" \
  || fail "run with rules that stay: rc=$rc $out"
rm "$FIX/keeps-rules"; sessions "[{\"id\":\"../permission/saved/x\",\"permissions\":$allow}]"; : > "$FIX/sleep-calls"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && ! grep -qF "PATCH /api/session/.." "$FIX/podman-calls" \
  && [ ! -s "$FIX/sleep-calls" ] \
  && pass "run refuses a session whose id is not one, at once" || fail "run with a made-up session id: rc=$rc $out"
sessions '{"error":"no"}'
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses when the sessions cannot be listed" \
  || fail "run without a list of sessions: rc=$rc $out"
sessions '[{"id":"ses_e","permissions":null}]'; touch "$FIX/bad-cursor"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses a list whose next page is not named by a cursor" \
  || fail "run with a made-up cursor: rc=$rc $out"
rm "$FIX/bad-cursor"; touch "$FIX/endless"; : > "$FIX/sleep-calls"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses a session list that does not end" \
  || fail "run with an endless session list: rc=$rc $out"
# It is an answer: asking again would page through it as long.
[ ! -s "$FIX/sleep-calls" ] && ! grep -qxF "$again" <<<"$out" \
  && pass "a session list that does not end is not asked for again" \
  || fail "an endless session list asked for again: $(wc -l < "$FIX/sleep-calls") pauses"
rm "$FIX/endless"; sessions '[]'
# What podman says of the container reaches the command line of the client's:
# an image that is no id, or a work directory podman cannot mount, starts none.
n=0
for bad in "" "${img:1}" "sha256:$img" "--volume=/:/host"; do
  n=$((n+1)); printf '%s\n' "$bad" > "$FIX/image"
  out="$(sc run obs hello 2>&1)"; rc=$?
  [ "$rc" = 1 ] && [ ! -s "$FIX/client-calls" ] && [[ $out == *"cannot read the image of $N-obs-agent"* ]] \
    && pass "run refuses a container whose image is not named by its id ($n)" \
    || fail "run with the image '$bad': rc=$rc $out"
done
printf '%s\n' "$img" > "$FIX/image"
n=0
for wd in "" ws / "$work/a,b" "$work/a:b"; do
  n=$((n+1)); printf %s "$wd" > "$FIX/workdir"
  out="$(sc run obs hello 2>&1)"; rc=$?
  [ "$rc" = 1 ] && [ ! -s "$FIX/client-calls" ] && [[ $out == *"cannot read the work directory of $N-obs-agent"* ]] \
    && pass "run refuses a container whose work directory is no path to mount ($n)" \
    || fail "run with the work directory '$wd': rc=$rc $out"
done
printf %s "$work/ws" > "$FIX/workdir"

# A reply reaches the terminal as text and colour, each stream on its own, and
# the client's exit status is the launcher's.
touch "$FIX/escapes"
sc run obs hello > "$work/rout" 2> "$work/rerr"; rc=$?
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
  out="$(cd "$work" && "${scenv[@]}" PATH="$p" HOME="$work/home" bash "$SC" run obs hello 2>&1)"; rc=$?
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
  out="$(ld "$p" run obs hello)"; rc=$?
  [ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] \
    && pass "run refuses a list of the loader that reaches the work directory ($n)" \
    || fail "run with $p: rc=$rc $out"
done
for p in "LD_LIBRARY_PATH=$tools/lib" "LD_LIBRARY_PATH=" "LD_PRELOAD=libc.so.6"; do
  : > "$FIX/client-calls"
  out="$(ld "$p" run obs hello)"; rc=$?
  [ "$rc" = 0 ] && [ -s "$FIX/client-calls" ] && pass "run takes ${p:-an empty list}" || fail "run with $p: rc=$rc $out"
done
: > "$FIX/client-calls"
out="$("${scenv[@]}" PATH="$callerpath:$work/ws/bin" HOME="$work/home" bash "$SC" run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "lies in the work directory" <<<"$out" && [ ! -s "$FIX/client-calls" ] \
  && pass "run refuses a PATH entry in the work directory" || fail "run with a PATH entry in the work directory: rc=$rc $out"

out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "is already running" <<<"$out" && [ "$(grep -c '^start ' "$FIX/systemctl-calls")" = 1 ] \
  && [ "$(secret obs-server-password)" = "$pw" ] \
  && pass "up leaves a running instance and its password alone" || fail "up on a running instance: rc=$rc $out"
# The instance's own mounts do not stop it; another container's do.
printf '%s\n' "$work/ws" > "$FIX/others"
printf '%s\n' "$N-obs-agent" > "$FIX/own-name"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "is already running" <<<"$out" \
  && pass "up ignores what its own container writes" || fail "up and its own mounts: rc=$rc $out"
rm "$FIX/own-name"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "a running container writes $work/ws" <<<"$out" \
  && pass "up refuses what another container writes" || fail "up and another container's mounts: rc=$rc $out"
printf '%s\n' /srv/elsewhere "$work/ws2" "$work/mem2" > "$FIX/others"
cp "$FIX/plugins.bad" "$FIX/plugins"; : > "$FIX/client-calls"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses a container without both guards" \
  || fail "run without a guard plugin: rc=$rc $out"
printf '%s\n' "ID  VERSION" "opensuse-packaging.bug-guard-x opensuse-packaging.pool-pr-guard" > "$FIX/plugins"
: > "$FIX/client-calls"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -s "$FIX/client-calls" ] && pass "run refuses a plugin id naming both guards" \
  || fail "run with a crafted plugin id: rc=$rc $out"
cp "$FIX/plugins.bad" "$FIX/plugins"

# Starts that must leave no container behind.
restart() { sc down obs > /dev/null; : > "$FIX/podman-calls"; : > "$FIX/systemctl-calls"; rm -f "$FIX/imported"; }
restart
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] \
  && pass "a guard plugin that failed to load: the unit is stopped" || fail "failed plugin: rc=$rc $out"
# What the server printed on the way is shown as text.
printf 'ID  VERSION\n-  local  /x\033]52;c;QUJD\007.ts\n' > "$FIX/plugins"; restart; touch "$FIX/log-escapes"
sc up obs > "$work/rout" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -qaF "log]0;tline" "$work/rout" && grep -qaxF "ctl<>" "$work/rout" \
  && grep -qaF "/x]52;c;QUJD.ts" "$work/rout" && ! grep -qa $'[\033\007]' "$work/rout" \
  && pass "a failed start shows the server's output without control characters" \
  || fail "failed start and control characters: rc=$rc $(od -c "$work/rout" | head -12)"
rm "$FIX/log-escapes"
cp "$FIX/plugins.good" "$FIX/plugins"; restart; approval per_e5; touch "$FIX/keeps"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] \
  && pass "a saved approval that stays: the unit is stopped, no credential is sent" \
  || fail "up with an approval that stays: rc=$rc $out"
rm "$FIX/keeps"; echo '{"data":[]}' > "$FIX/saved"; restart; touch "$FIX/stops"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -e "$FIX/imported" ] \
  && pass "a container that stopped: no credential is sent" || fail "stopped container: rc=$rc $out"
rm "$FIX/stops"; restart; touch "$FIX/run-fails"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] \
  && pass "a container podman made and could not start is removed" || fail "a start podman failed: rc=$rc $out"
rm "$FIX/run-fails"; restart; touch "$FIX/import-fails"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && pass "a failed import: the unit is stopped" \
  || fail "failed import: rc=$rc $out"
rm "$FIX/import-fails"
restart; echo '{"error":"no"}' > "$FIX/logins"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "podman volume rm" <<<"$out" \
  && pass "model logins that cannot be listed: the unit is stopped, no credential is sent" \
  || fail "up without a list of model logins: rc=$rc $out"
restart; kept_login 'cred_a/../../session'; : > "$FIX/sleep-calls"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] \
  && ! grep -q 'api DELETE /api/credential' "$FIX/podman-calls" && [ ! -s "$FIX/sleep-calls" ] \
  && pass "a kept model login with an unexpected id: no call is made with it, no credential is sent, no pause" \
  || fail "up with a model login id: rc=$rc $out"
restart; kept_login cred_old1; touch "$FIX/login-stays"; scripted logins
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] \
  && grep -qF "podman volume rm" <<<"$out" && grep -qF "the model logins $N-obs-agent keeps cannot be removed" <<<"$out" \
  && [ "$(reads logins)" = 61 ] && [ "$(pauses)" = 59 ] \
  && [ "$(grep -c 'api DELETE /api/credential/cred_old1' "$FIX/podman-calls")" = 60 ] \
  && pass "a kept model login that stays: the unit is stopped after 60 rounds of removal, no credential is sent" \
  || fail "up with a model login that stays: rc=$rc $(reads logins) reads, $(pauses) pauses $out"
rm "$FIX/login-stays"
# An id is one value in the answer; split into lines, a line break in it makes two.
for id in 'cred_x\ncred_y' 'cred_a\n' ''; do
  restart; kept_login "$id"; : > "$FIX/sleep-calls"
  out="$(sc up obs 2>&1)"; rc=$?
  [ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] \
    && ! grep -q 'api DELETE /api/credential' "$FIX/podman-calls" && grep -qF "podman volume rm" <<<"$out" \
    && [ ! -s "$FIX/sleep-calls" ] \
    && pass "a kept model login with the id '$id': no call is made with it, no credential is sent" \
    || fail "up with the model login id '$id': rc=$rc $out"
done
# Nor is an id that is no text, whatever it holds.
restart; echo '{"data":[{"id":{"k":"SECRET-7"}}]}' > "$FIX/logins"; : > "$FIX/sleep-calls"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] \
  && ! grep -q 'api DELETE /api/credential' "$FIX/podman-calls" && [ ! -s "$FIX/sleep-calls" ] \
  && pass "a kept model login whose id is no text: no call is made, nothing of it is shown" \
  || fail "up with a model login id that is no text: rc=$rc $out"
restart; kept_login cred_old1; touch "$FIX/login-ghost"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ -z "$(leaks <<<"$out")" ] \
  && grep -q 'api DELETE /api/credential/cred_old1' "$FIX/podman-calls" && grep -qF "podman volume rm" <<<"$out" \
  && pass "a kept model login the server only claims to remove: the unit is stopped, no credential is sent" \
  || fail "up with a model login removed in name only: rc=$rc $out"
rm "$FIX/login-ghost"
restart; echo '{"data":[]}' > "$FIX/logins"; echo '{"error":"no"}' > "$FIX/logins-next"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "podman volume rm" <<<"$out" \
  && pass "model logins that cannot be listed again: the unit is stopped, no credential is sent" \
  || fail "up without a second list of model logins: rc=$rc $out"
# A list that could not be read is not an empty one: the one read again counts.
restart; kept_login cred_old1; mv "$FIX/logins" "$FIX/logins-next"; echo '{"error":"no"}' > "$FIX/logins"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -e "$FIX/imported" ] && grep -q 'api DELETE /api/credential/cred_old1' "$FIX/podman-calls" \
  && [ "$(jq -c .data "$FIX/logins")" = "[]" ] \
  && pass "model logins that can be listed only the second time: the login listed then is removed first" \
  || fail "up without a first list of model logins: rc=$rc $out"
rm -f "$FIX/logins-next"; echo '{"data":[]}' > "$FIX/logins"
# A hangup cannot be sent where the caller of this test ignores it.
sigs=(TERM); [ -n "$(trap -p HUP)" ] || sigs+=(HUP)
for sig in "${sigs[@]}"; do
  restart; echo "ID  VERSION" > "$FIX/plugins"
  "${scenv[@]}" HOME="$work/home" bash "$SC" up obs > /dev/null 2>&1 &
  pid=$!
  for _ in $(seq 100); do grep -q "plugin list" "$FIX/podman-calls" && break; sleep 0.1; done
  kill "-$sig" "$pid"; wait "$pid"; rc=$?
  [ "$rc" = 130 ] && stopped && [ ! -e "$FIX/imported" ] && pass "an up interrupted by $sig stops the unit" \
    || fail "up interrupted by $sig: rc=$rc"
done
cp "$FIX/plugins.good" "$FIX/plugins"
# Every probe of a start writes to the journal: half a minute of one a second,
# then one every five seconds.
restart; echo 35 > "$FIX/plugins-late"; : > "$FIX/sleep-calls"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -cx 1 "$FIX/sleep-calls")" = 30 ] && [ "$(grep -cx 5 "$FIX/sleep-calls")" = 5 ] \
  && [ "$(wc -l < "$FIX/sleep-calls")" = 35 ] && [ "$(head -n 30 "$FIX/sleep-calls" | sort -u)" = 1 ] \
  && pass "a slow start probes each second for 30 probes, then every five seconds" \
  || fail "the pace of a slow start: rc=$rc $(sort "$FIX/sleep-calls" | uniq -c | tr '\n' ' ') $out"
rm -f "$FIX/plugins-late"
# podman answers nothing, or an error of its own, while another container holds
# its storage lock: what follows a start is tried again, with one line to say so
# and the errors of the first failure alone.
restart; scripted projects fail fail fail
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && ! stopped && [ -e "$FIX/imported" ] && [ "$(grep -cxF "$again" <<<"$out")" = 1 ] \
  && [ "$(reads projects)" = 4 ] && [ "$(grep -cx 5 "$FIX/sleep-calls")" = 3 ] && [ "$(pauses)" = 3 ] \
  && [ "$(grep -c BUSY-MARK <<<"$out")" = 1 ] \
  && pass "up asks again for the projects while podman fails, and shows the first failure alone" \
  || fail "up with a busy podman: rc=$rc $(reads projects) reads $out"
# One that never comes stops the unit after 60 reads.
restart; never projects silent
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "cannot read the permissions $N-obs-agent keeps" <<<"$out" \
  && [ "$(grep -cxF "$again" <<<"$out")" = 1 ] && [ "$(reads projects)" = 60 ] && [ "$(pauses)" = 59 ] \
  && pass "permissions podman never answers for: the unit is stopped after 60 reads, no credential is sent" \
  || fail "up with a podman that never answers: rc=$rc $(reads projects) reads $out"
# The pages of the session list, too.
restart; scripted sessions fail fail fail
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -e "$FIX/imported" ] && [ "$(grep -cxF "$again" <<<"$out")" = 1 ] \
  && [ "$(reads sessions)" = 4 ] && [ "$(pauses)" = 3 ] \
  && pass "up asks again for the session list while podman fails" \
  || fail "up with a busy podman and the session list: rc=$rc $(reads sessions) reads $out"
# Status 2 from the command in the container is not a list without an end.
restart; scripted logins exit2
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -e "$FIX/imported" ] && [ "$(reads logins)" = 3 ] && [ "$(pauses)" = 1 ] \
  && pass "an answer that ends with status 2 is asked for again" \
  || fail "up with an answer that ends with status 2: rc=$rc $(reads logins) reads $out"
# bash takes SECONDS from the environment. 314 short of the largest number,
# the start's deadline still fits for 14 seconds; after a start of 15 the
# read's has wrapped round and is past: nothing is tried again after five
# minutes. A host slower than that stops at the start and fails the check.
restart; scripted projects fail; echo 15 > "$FIX/start-slow"
out="$("${scenv[@]}" SECONDS=$((9223372036854775807 - 314)) HOME="$work/home" bash "$SC" up obs 2>&1)"; rc=$?
rm "$FIX/start-slow"
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && [ "$(reads projects)" = 1 ] && [ "$(pauses)" = 0 ] \
  && grep -qF "cannot read the permissions $N-obs-agent keeps" <<<"$out" \
  && pass "a read is not tried again once five minutes have passed" \
  || fail "up past the deadline: rc=$rc $(reads projects) reads, $(pauses) pauses $out"
# The five minutes are the command's, not each list's: 314 short of the largest
# number, the deadline the first read sets fits for 14 seconds, and one the
# logins read set for itself after a failure of 15 would have wrapped round.
restart; scripted projects slow; echo fail > "$FIX/logins-script"; : > "$FIX/logins-asked"
out="$("${scenv[@]}" SECONDS=$((9223372036854775807 - 314)) HOME="$work/home" bash "$SC" up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -e "$FIX/imported" ] && [ "$(reads projects)" = 2 ] && [ "$(reads logins)" = 3 ] && [ "$(pauses)" = 2 ] \
  && pass "every try after the start shares one deadline" \
  || fail "up with one deadline: rc=$rc $(reads projects) and $(reads logins) reads, $(pauses) pauses $out"
# An id that is none stops the start at once: an empty one would vanish from
# the lines read, and one with a line break would split into two that look
# like ids while the real one stays.
restart; approval ""; : > "$FIX/sleep-calls"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "cannot read the permissions $N-obs-agent keeps" <<<"$out" \
  && ! grep -q 'api DELETE /api/permission' "$FIX/podman-calls" && [ ! -s "$FIX/sleep-calls" ] \
  && pass "an approval with an empty id stops the unit at once, no credential is sent" \
  || fail "up with an approval with an empty id: rc=$rc $out"
restart; approval 'per_a\nper_b'; : > "$FIX/sleep-calls"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "cannot read the permissions $N-obs-agent keeps" <<<"$out" \
  && ! grep -q 'api DELETE /api/permission' "$FIX/podman-calls" && [ ! -s "$FIX/sleep-calls" ] \
  && pass "an approval whose id holds a line break stops the unit at once, no credential is sent" \
  || fail "up with an approval id with a line break: rc=$rc $out"
echo '{"data":[]}' > "$FIX/saved"
restart; sessions "[{\"id\":\"\",\"permissions\":$allow}]"; : > "$FIX/sleep-calls"
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "cannot read the permissions $N-obs-agent keeps" <<<"$out" \
  && ! grep -q 'api PATCH /api/session' "$FIX/podman-calls" && [ ! -s "$FIX/sleep-calls" ] \
  && pass "a session with rules and an empty id stops the unit at once, no credential is sent" \
  || fail "up with a session with an empty id: rc=$rc $out"
sessions '[]'
# One answer is one list: a second one after it is not left unread.
restart; printf '{"data":[]}{"data":[{"id":"cred_old1"}]}\n' > "$FIX/logins"; scripted logins
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "cannot read the model logins $N-obs-agent keeps" <<<"$out" \
  && pass "two lists of model logins in one answer: the unit is stopped, no credential is sent" \
  || fail "up with two lists of model logins: rc=$rc $out"
echo '{"data":[]}' > "$FIX/logins"
restart; printf '%s\n' '[{"id":"prj_main"}][{"id":"prj_evil"}]' > "$FIX/projects"; scripted projects
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "cannot read the permissions $N-obs-agent keeps" <<<"$out" \
  && pass "two lists of projects in one answer: the unit is stopped, no credential is sent" \
  || fail "up with two lists of projects: rc=$rc $out"
echo '[{"id":"prj_main"}]' > "$FIX/projects"
# The read of a removal round is asked again as well.
restart; approval per_v1; scripted projects ok silent silent silent
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -e "$FIX/imported" ] \
  && [ "$(grep -cxF "$again" <<<"$out")" = 1 ] && [ "$(reads projects)" = 5 ] && [ "$(pauses)" = 3 ] \
  && pass "up asks again for the permissions after their removal while podman does not answer" \
  || fail "up with a busy podman after the removal: rc=$rc $(reads projects) reads $out"
# One that never answers again stops the unit after 60 rounds.
restart; approval per_v2; never projects silent 1
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "the permissions $N-obs-agent keeps cannot be removed" <<<"$out" \
  && grep -q 'api DELETE /api/permission/saved/per_v2' "$FIX/podman-calls" && [ "$(reads projects)" = 61 ] \
  && [ "$(pauses)" = 59 ] \
  && pass "approvals podman stops answering for once removed: the unit is stopped after 60 rounds" \
  || fail "up with a podman silent after the removal: rc=$rc $(reads projects) reads $out"
echo '{"data":[]}' > "$FIX/saved"
restart; kept_login cred_old1; never logins silent 1
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "the model logins $N-obs-agent keeps cannot be removed" <<<"$out" \
  && grep -q 'api DELETE /api/credential/cred_old1' "$FIX/podman-calls" && [ "$(reads logins)" = 61 ] \
  && [ "$(pauses)" = 59 ] \
  && pass "model logins podman stops answering for once removed: the unit is stopped after 60 rounds" \
  || fail "up with a podman silent after the login removal: rc=$rc $(reads logins) reads $out"
echo '{"data":[]}' > "$FIX/logins"
# A removal the busy podman lost leaves its item listed: the next round removes
# it. One that stays stops the unit after 60 rounds.
restart; approval per_r1; scripted deletes fail
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/saved")" = "[]" ] && [ -e "$FIX/imported" ] && [ "$(reads deletes)" = 2 ] \
  && [ "$(pauses)" = 1 ] && [ "$(grep -cxF "$again" <<<"$out")" = 1 ] \
  && pass "an approval whose removal failed once is removed in the next round" \
  || fail "up with a lost approval removal: rc=$rc $(reads deletes) removals $out"
restart; approval per_r2; touch "$FIX/keeps"; scripted deletes
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "the permissions $N-obs-agent keeps cannot be removed" <<<"$out" \
  && [ "$(reads deletes)" = 60 ] && [ "$(pauses)" = 59 ] \
  && pass "an approval that stays: the unit is stopped after 60 rounds of removal, no credential is sent" \
  || fail "up with an approval that stays: rc=$rc $(reads deletes) removals, $(pauses) pauses $out"
rm "$FIX/keeps"; echo '{"data":[]}' > "$FIX/saved"
restart; sessions "[{\"id\":\"ses_r1\",\"permissions\":$allow}]"; scripted patches fail
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c 'map(.permissions)' "$FIX/sessions")" = "[[]]" ] && [ -e "$FIX/imported" ] \
  && [ "$(reads patches)" = 2 ] && [ "$(pauses)" = 1 ] \
  && pass "session rules whose removal failed once are removed in the next round" \
  || fail "up with a lost rule removal: rc=$rc $(reads patches) removals $out"
restart; sessions "[{\"id\":\"ses_r2\",\"permissions\":$allow}]"; touch "$FIX/keeps-rules"; scripted patches
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "the permissions $N-obs-agent keeps cannot be removed" <<<"$out" \
  && [ "$(reads patches)" = 60 ] && [ "$(pauses)" = 59 ] \
  && pass "session rules that stay: the unit is stopped after 60 rounds of removal, no credential is sent" \
  || fail "up with rules that stay: rc=$rc $(reads patches) removals, $(pauses) pauses $out"
rm "$FIX/keeps-rules"; sessions '[]'
restart; kept_login cred_old1; scripted logindel fail
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -c .data "$FIX/logins")" = "[]" ] && [ -e "$FIX/imported" ] \
  && [ "$(reads logindel)" = 2 ] && [ "$(pauses)" = 1 ] \
  && pass "a model login whose removal failed once is removed in the next round" \
  || fail "up with a lost login removal: rc=$rc $(reads logindel) removals $out"
restart; scripted import fail
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -e "$FIX/imported" ] && [ "$(reads import)" = 2 ] && [ "$(pauses)" = 1 ] \
  && pass "a model credential whose import failed once is imported on the next try" \
  || fail "up with a lost import: rc=$rc $(reads import) imports $out"
restart; scripted import exit2
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -e "$FIX/imported" ] && [ "$(reads import)" = 2 ] && [ "$(pauses)" = 1 ] \
  && pass "an import that ends with status 2 is tried again" \
  || fail "up with an import that ends with status 2: rc=$rc $(reads import) imports $out"
# And the model logins: the first three reads, or the three after the removal.
for first in 1 2; do
  restart; kept_login cred_old1
  if [ "$first" = 1 ]; then scripted logins silent silent silent; else scripted logins ok silent silent silent; fi
  out="$(sc up obs 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ -e "$FIX/imported" ] && grep -q 'api DELETE /api/credential/cred_old1' "$FIX/podman-calls" \
    && [ "$(jq -c .data "$FIX/logins")" = "[]" ] && [ "$(grep -cxF "$again" <<<"$out")" = 1 ] \
    && [ "$(reads logins)" = 5 ] && [ "$(pauses)" = 3 ] \
    && pass "up asks again for the model logins while podman does not answer (from read $first)" \
    || fail "up with a busy podman and model logins (from read $first): rc=$rc $(reads logins) reads $out"
done
# No answer is no list of them: one that never comes stops the unit.
restart; kept_login cred_old1; never logins silent
out="$(sc up obs 2>&1)"; rc=$?
[ "$rc" != 0 ] && stopped && [ ! -e "$FIX/imported" ] && grep -qF "cannot read the model logins $N-obs-agent keeps" <<<"$out" \
  && ! grep -q 'api DELETE /api/credential' "$FIX/podman-calls" && [ "$(grep -cxF "$again" <<<"$out")" = 1 ] \
  && [ "$(reads logins)" = 60 ] && [ "$(pauses)" = 59 ] \
  && pass "model logins podman never answers for: the unit is stopped after 60 reads, no credential is sent" \
  || fail "up with model logins that never come: rc=$rc $(reads logins) reads $out"
rm -f "${FIX:?}"/*-script; echo '{"data":[]}' > "$FIX/logins"

# Each instance keeps its server password across restarts: it is created
# once, on the first start, and never rotated by up or update.
restart
out="$(sc up obs 2>&1)"; rc=$?
pw2="$(secret obs-server-password)"
[ "$rc" = 0 ] && [ "${#pw2}" = 32 ] && [ "$pw2" = "$pw" ] && ! grep -q '^secret create' "$FIX/podman-calls" \
  && pass "a restarted container keeps its server password" || fail "the second up: rc=$rc $out"
sc down obs > /dev/null
# Manual rotation: removing the secret makes the next start create a new one.
rm "$FIX/secrets/$N-obs-server-password"
: > "$FIX/podman-calls"
out="$(sc up obs 2>&1)"; rc=$?
pw3="$(secret obs-server-password)"
[ "$rc" = 0 ] && [ "${#pw3}" = 32 ] && [ "$pw3" != "$pw2" ] \
  && pass "a removed server password is created anew on the next start" || fail "rotation: rc=$rc $out"
sc down obs > /dev/null

# The memory graph is seeded into the volume once: a copy that keeps what a
# volume already holds, and nothing when the copy fails.
mkdir -p "$work/ws3"
: > "$FIX/seed-calls"; rm -f "$FIX/seeded"
out="$(cd "$work" && sc install seed --workdir ws3 --memory mem/memory.json --image img:1 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -e "$FIX/seeded" ] && grep -q "cp -n /src/memory.json /seed/memory.jsonl" "$FIX/seed-calls" \
  && grep -qF "$N-seed-memory:/seed:U" "$FIX/seed-calls" && grep -qF "$work/mem:/src:ro,Z" "$FIX/seed-calls" \
  && pass "install seeds the memory graph into the volume" || fail "install --memory: rc=$rc $out"
touch "$FIX/seed-fails"
out="$(cd "$work" && sc install seed2 --workdir ws3 --memory mem/memory.json 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -e "$work/home/.config/containers/systemd/$N-agent@seed2.container.d/10-workdir.conf" ] \
  && [ ! -L "$work/home/.config/containers/systemd/$N-agent@seed2.container" ] \
  && [ ! -e "$work/config/skill-container/$N/seed2.dir" ] \
  && pass "a failed seed writes no unit" || fail "install with a failed seed: rc=$rc $out"
# On a second install the first one stays as it was.
seeddir="$work/home/.config/containers/systemd"
out="$(cd "$work" && sc install seed --workdir ws3 --memory mem/memory.json --image img:2 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qxF "Image=img:1" "$seeddir/$N-agent@seed.container.d/10-workdir.conf" \
  && [ -L "$seeddir/$N-agent@seed.container" ] \
  && [ "$(sed -n 3p "$work/config/skill-container/$N/seed.dir")" = img:1 ] \
  && pass "a failed seed keeps an earlier install" || fail "install again with a failed seed: rc=$rc $out"
rm "$FIX/seed-fails"
# systemd not reloading: what install wrote stays, and it says so.
touch "$FIX/reload-fails"
out="$(cd "$work" && sc install seed --workdir ws3 --image img:3 2>&1)"; rc=$?
rm "$FIX/reload-fails"
[ "$rc" != 0 ] && grep -qF "would not reload" <<<"$out" \
  && grep -qxF "Image=img:3" "$seeddir/$N-agent@seed.container.d/10-workdir.conf" \
  && [ -L "$seeddir/$N-agent@seed.container" ] \
  && [ "$(sed -n 3p "$work/config/skill-container/$N/seed.dir")" = img:3 ] \
  && pass "install keeps its files when systemd does not reload" || fail "install without a reload: rc=$rc $out"

: > "$FIX/client-calls"
out="$(sc run obs hello 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "not running" <<<"$out" && [ ! -s "$FIX/client-calls" ] \
  && pass "run without a container says so" || fail "run without a container: rc=$rc $out"
out="$(sc down obs 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(tail -1 "$FIX/systemctl-calls")" = "stop $N-agent@obs.service" ] \
  && [ -n "$(secret osc)" ] && pass "down stops the unit and keeps the secrets" \
  || fail "down: rc=$rc $out"
# install mounts the work directory where the sessions expect it, which need
# not be its path on the host.
out="$(sc install as --workdir "$work/ws" --as /inside/dir 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "Volume=$work/ws:/inside/dir:Z" \
  "$work/home/.config/containers/systemd/$N-agent@as.container.d/10-workdir.conf" \
  && grep -qxF "WorkingDir=/inside/dir" \
  "$work/home/.config/containers/systemd/$N-agent@as.container.d/10-workdir.conf" \
  && [ "$(cat "$work/config/skill-container/$N/as.dir")" = "$(printf '%s\n' "$work/ws" /inside/dir localhost/$N-agent:latest)" ] \
  && pass "install mounts the work directory at --as" || fail "install --as: rc=$rc $out"
# install runs the fixed copy: a missing or changed one stops it first.
mv "$work/home/.local/bin/skill-container" "$FIX/launcher.kept"
out="$(sc install nol --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "copy the launcher" <<<"$out" \
  && [ ! -e "$work/config/skill-container/$N/nol.dir" ] \
  && pass "install without the fixed copy writes nothing" || fail "install without the fixed copy: rc=$rc $out"
printf 'changed\n' > "$work/home/.local/bin/skill-container"
out="$(sc install nol --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "copy the launcher" <<<"$out" \
  && [ ! -e "$work/config/skill-container/$N/nol.dir" ] \
  && pass "install with a changed fixed copy writes nothing" || fail "install with a changed fixed copy: rc=$rc $out"
mv "$FIX/launcher.kept" "$work/home/.local/bin/skill-container"
out="$(sc install nol --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -e "$work/config/skill-container/$N/nol.dir" ] \
  && pass "install writes the state file again on a repeated run" || fail "install again: rc=$rc $out"
# password prints the secret of a running instance, and nothing when stopped.
out="$(sc up as 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "up for the password test: rc=$rc $out"
printf %s /inside/dir > "$FIX/workdir"
out="$(sc password as 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(secret as-server-password)" ] \
  && pass "password prints the server password of the instance" || fail "password: rc=$rc $out"
sc down as > /dev/null
out="$(sc password as 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "is not running" <<<"$out" \
  && pass "password without the instance says so" || fail "password without the instance: rc=$rc $out"
# idle and update: a quiet instance, a busy session, an attached client.
out="$(sc up nol 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "up for the idle test: rc=$rc $out"
printf %s "$work/ws" > "$FIX/workdir"
out="$(sc idle nol 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "nol is idle" <<<"$out" \
  && pass "idle answers for a quiet instance" || fail "idle: rc=$rc $out"
# What a call into the container writes to its error stream is the agent's text.
touch "$FIX/exec-escape"
out="$(sc idle nol 2>&1)"; rc=$?
rm "$FIX/exec-escape"
[ "$rc" = 0 ] && grep -qF "inside says" <<<"$out" && ! grep -q $'\033' <<<"$out" \
  && pass "idle filters the error stream of a call into the container" || fail "idle printed a control sequence: rc=$rc"
sessions '[{"id":"ses_b","permissions":null,"time":{"busy":5,"idle":2}}]'
out="$(sc idle nol 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF ses_b <<<"$out" \
  && pass "idle names a busy session" || fail "idle with a busy session: rc=$rc $out"
# The state volume is the agent's: an id that is more than an id is not printed.
sessions '[{"id":"ses_\u001b]52;c;eA==\u0007\u001b[2J","permissions":null,"time":{"busy":5,"idle":2}}]'
out="$(sc idle nol 2>&1)"; rc=$?
[ "$rc" != 0 ] && ! grep -q $'\033' <<<"$out" && grep -qF "cannot list the sessions" <<<"$out" \
  && pass "idle prints no control sequence from a session id" || fail "idle with a crafted id: rc=$rc"
sessions '[]'
printf '%s\n' /srv/elsewhere > "$FIX/others"
# podman names a shared network by the server's id, not its name: the client
# is the container in the server's network namespace.
netns "spike-y 4026530001"
out="$(sc idle nol 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "a client is on" <<<"$out" \
  && pass "idle sees an attached client" || fail "idle with a client: rc=$rc $out"
echo 0123abcd > "$FIX/image-new"; : > "$FIX/systemctl-calls"
out="$(sc update nol 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "is not idle" <<<"$out" && ! grep -q '^restart' "$FIX/systemctl-calls" \
  && pass "update waits while a client is on" || fail "update with a client: rc=$rc $out"
# What podman does not answer is not idle.
for how in fails empty; do
  if [ "$how" = fails ]; then netns; touch "$FIX/netns-fails"; else : > "$FIX/netns"; fi
  out="$(sc idle nol 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "cannot tell whether a client is on" <<<"$out" \
    && pass "idle stops when podman names no namespaces ($how)" || fail "idle, namespaces $how: rc=$rc $out"
  out="$(sc update nol 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "cannot tell whether a client is on" <<<"$out" && ! grep -q '^restart' "$FIX/systemctl-calls" \
    && pass "update restarts nothing when podman names no namespaces ($how)" \
    || fail "update, namespaces $how: rc=$rc $out"
  rm -f "$FIX/netns-fails"
done
rm "$FIX/image-new"
netns
printf '%s\n' /srv/elsewhere "$work/ws2" "$work/mem2" > "$FIX/others"
pw3="$(secret nol-server-password)"
# The image it runs is still the newest: nothing ends the sessions.
: > "$FIX/systemctl-calls"
out="$(sc update nol 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qF "runs the newest" <<<"$out" && ! grep -q '^restart' "$FIX/systemctl-calls" \
  && pass "update leaves an instance on the newest image running" || fail "update without a new image: rc=$rc $out"
# It asks whether the instance is idle last, and only before a restart.
sessions '[{"id":"ses_b","permissions":null,"time":{"busy":5,"idle":2}}]'
out="$(sc update nol 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qF "runs the newest" <<<"$out" \
  && pass "update on the newest image does not ask whether the instance is idle" \
  || fail "update, busy on the newest image: rc=$rc $out"
sessions '[]'
echo 0123abcd > "$FIX/image-new"
# The clock of a launcher that pulled for ten minutes: the wait starts at the restart.
touch "$FIX/exec-escape"
out="$("${scenv[@]}" SECONDS=600 HOME="$work/home" bash "$SC" update nol 2>&1)"; rc=$?
rm "$FIX/exec-escape"
! grep -q $'\033' <<<"$out" && pass "update shows no control sequence from inside the container" \
  || fail "update printed a control sequence"
[ "$rc" = 0 ] && grep -qxF "nol is updated" <<<"$out" && [ "$(secret nol-server-password)" = "$pw3" ] \
  && grep -qx "restart $N-agent@nol.service" "$FIX/systemctl-calls" && [ ! -e "$FIX/pull-calls" ] \
  && pass "update restarts a quiet instance on a new image, keeps its password, no pull for a local image" \
  || fail "update: rc=$rc $out"
# After its restart it asks again while podman does not answer, as up does.
scripted projects fail fail fail; : > "$FIX/systemctl-calls"
out="$(sc update nol 2>&1)"; rc=$?
rm "$FIX/projects-script"
[ "$rc" = 0 ] && grep -qxF "nol is updated" <<<"$out" && grep -qx "restart $N-agent@nol.service" "$FIX/systemctl-calls" \
  && ! grep -q '^stop ' "$FIX/systemctl-calls" && [ "$(wc -l < "$FIX/sleep-calls")" = 3 ] \
  && [ "$(grep -cxF "${again/$N-obs-agent/$N-nol-agent}" <<<"$out")" = 1 ] && [ "$(reads projects)" = 4 ] \
  && pass "update asks again for the permissions while podman does not answer after the restart" \
  || fail "update with a busy podman: rc=$rc $out"
rm "$FIX/image-new"
# A published image is pulled first.
sc down nol > /dev/null
out="$(sc install pub --workdir "$work/ws" --image registry.example/agent:latest 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "install with a custom image: rc=$rc $out"
out="$(sc up pub 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "up with a custom image: rc=$rc $out"
out="$(sc update pub 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qx "pull registry.example/agent:latest" "$FIX/pull-calls" \
  && pass "update pulls a published image" || fail "update with a custom image: rc=$rc $out"
# A session that begins while the image is pulled is not interrupted.
echo 0123abcd > "$FIX/image-new"; touch "$FIX/pull-busies"; : > "$FIX/systemctl-calls"
out="$(sc update pub 2>&1)"; rc=$?
rm "$FIX/pull-busies" "$FIX/image-new"; sessions '[]'
[ "$rc" != 0 ] && grep -qF "is not idle" <<<"$out" && ! grep -q '^restart' "$FIX/systemctl-calls" \
  && pass "update asks whether the instance is idle after the pull" || fail "update, busy after the pull: rc=$rc $out"
sc down pub > /dev/null
touch "$FIX/pull-fails"
out="$(sc up pub 2>&1)" && out="$(sc update pub 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "was not pulled" <<<"$out" \
  && pass "update without the new image changes nothing" || fail "update with a failed pull: rc=$rc $out"
rm "$FIX/pull-fails"
sc down pub > /dev/null
sc down nol > /dev/null
# uninstall takes the units and settings of one instance; what holds its work stays.
pubdir="$work/home/.config/containers/systemd"
: > "$FIX/systemctl-calls"
out="$(sc uninstall pub 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$pubdir/$N-agent@pub.container.d" ] && [ ! -L "$pubdir/$N-agent@pub.container" ] \
  && [ ! -e "$work/config/skill-container/$N/pub.dir" ] && [ -f "$pubdir/$N-agent@.container" ] \
  && grep -qx "stop $N-agent@pub.service" "$FIX/systemctl-calls" \
  && grep -qx "stop $N-relay@pub.service" "$FIX/systemctl-calls" \
  && grep -qx "disable --now $N-update@pub.timer" "$FIX/systemctl-calls" \
  && grep -qx daemon-reload "$FIX/systemctl-calls" && [ -f "$FIX/secrets/$N-pub-server-password" ] \
  && [ -f "$work/config/skill-container/$N/nol.dir" ] \
  && pass "uninstall removes one instance's units and keeps its secret" || fail "uninstall: rc=$rc $out"
out="$(sc up pub 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "is not installed" <<<"$out" && pass "an uninstalled instance does not start" \
  || fail "up after uninstall: rc=$rc $out"
# A unit started by its name alone has no settings: it is stopped all the same.
: > "$FIX/systemctl-calls"
out="$(sc uninstall ghost 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qx "stop $N-agent@ghost.service" "$FIX/systemctl-calls" \
  && pass "uninstall stops an instance that was never installed" || fail "uninstall of a stray unit: rc=$rc $out"
# What goes into the drop-in is one value a line: systemd would read more.
# systemd also ends a line at a carriage return, expands a $ and ends a quoted
# value at a double quote.
for bad in "--image=img:1"$'\n'"PodmanArgs=--privileged" "--as=$work/ws%t" "--as=$work/ws\\" \
  "--image=img:1"$'\r'"PodmanArgs=--privileged" "--as=$work/ws\$HOME" "--as=$work/ws\"x" \
  "--as=$work/ws"$'\001' "--image=img:1"$'\t'"x"; do
  out="$(sc install inj --workdir "$work/ws" "${bad%%=*}" "${bad#*=}" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "a control character, a %, a \$, a backslash or a double quote" <<<"$out" \
    && [ ! -e "$pubdir/$N-agent@inj.container.d" ] \
    && pass "install refuses ${bad%%=*} with a character systemd would read: $(printf %q "${bad#*=}")" \
    || fail "install ${bad%%=*} injection $(printf %q "${bad#*=}"): rc=$rc $out"
done
# The work directory is mounted where --as says: not over the image's own files.
for at in /etc/opencode/x /etc /usr/local /home/agent / /srv/../usr/bin //home/agent/.claude /bin /sbin/x /lib /lib64 /usr/../bin \
  /var/lib/rpm /var/lib/ca-certificates /var/run /var/lock/x /var /var/tmp /var/tmp/ws /var/tmp/../lib/x /tmp /tmp/../run/x \
  /run/x /root /boot /dev/shm /proc/1 /sys /home; do
  out="$(sc install inj --workdir "$work/ws" --as "$at" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "it would cover what the image holds" <<<"$out" && [ ! -e "$pubdir/$N-agent@inj.container.d" ] \
    && pass "install refuses --as $at" || fail "install --as $at: rc=$rc $out"
done
out="$(sc install inj --workdir "$work/ws" --as /srv/etcetera 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "Volume=$work/ws:/srv/etcetera:Z" "$pubdir/$N-agent@inj.container.d/10-workdir.conf" \
  && pass "install takes --as beside, not in, the image's directories" || fail "install --as /srv/etcetera: rc=$rc $out"
sc uninstall inj > /dev/null
for at in /tmp/ws /variable/x /rootless /tmpx; do
  out="$(sc install inj --workdir "$work/ws" --as "$at" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && grep -qxF "Volume=$work/ws:$at:Z" "$pubdir/$N-agent@inj.container.d/10-workdir.conf" \
    && pass "install takes --as $at" || fail "install --as $at: rc=$rc $out"
  sc uninstall inj > /dev/null
done
# The units come from beside the fixed copy: those beside the launcher that
# runs may lie where an agent writes, its own or another instance's.
mkdir -p "$work/elsewhere/tool"
cp "$SC" "$work/elsewhere/tool/skill-container"
cp -r "$HERE/../contrib/container/systemd" "$work/elsewhere/tool/systemd"
echo "# AGENT-WRITTEN" >> "$work/elsewhere/tool/systemd/$N-relay@.service"
out="$("${scenv[@]}" HOME="$work/home" bash "$work/elsewhere/tool/skill-container" install inw --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ! grep -q AGENT-WRITTEN "$work/home/.config/systemd/user/$N-relay@.service" \
  && pass "install takes no units from beside the launcher that runs" || fail "units beside the launcher: rc=$rc $out"
sc uninstall inw > /dev/null
rm -r "$work/elsewhere/tool"
mv "$work/home/.local/bin/systemd" "$FIX/units.kept"
out="$(sc install inw --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "no units in" <<<"$out" && [ ! -L "$pubdir/$N-agent@inw.container" ] \
  && pass "install without units beside the fixed copy writes nothing" || fail "install without units: rc=$rc $out"
mv "$FIX/units.kept" "$work/home/.local/bin/systemd"
# install names the image in the instance's own lines, and the host's git identity.
grep -qxF "Image=localhost/$N-agent:latest" "$pubdir/$N-agent@nol.container.d/10-workdir.conf" \
  && pass "install pins the default image for the instance" || fail "no Image= line for nol"
git config --file "$work/home/.gitconfig" user.name "Pat Packager"
git config --file "$work/home/.gitconfig" user.email pat@example.org
gidconf="$work/config/skill-container/$N/gid.gitconfig"
out="$(sc install gid --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(git config --file "$gidconf" user.email)" = pat@example.org ] \
  && [ "$(git config --file "$gidconf" user.name)" = "Pat Packager" ] \
  && grep -qxF "Volume=$gidconf:/home/agent/.config/git/config:ro,Z" "$pubdir/$N-agent@gid.container.d/10-workdir.conf" \
  && pass "install passes the host's git identity on" || fail "the git identity: rc=$rc $out"
# The file is the instance's: an install of another one leaves it.
rm "$work/home/.gitconfig"
out="$(sc install gi2 --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -s "$gidconf" ] && [ ! -e "$work/config/skill-container/$N/gi2.gitconfig" ] \
  && ! grep -q gitconfig "$pubdir/$N-agent@gi2.container.d/10-workdir.conf" \
  && pass "install without a git identity mounts none and leaves another instance's" \
  || fail "install without a git identity: rc=$rc $out"
out="$(sc install gid --workdir "$work/ws" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$gidconf" ] && ! grep -q gitconfig "$pubdir/$N-agent@gid.container.d/10-workdir.conf" \
  && pass "a later install without a git identity removes the instance's own" \
  || fail "a stale git identity: rc=$rc $out"
git config --file "$work/home/.gitconfig" user.name "Pat Packager"
git config --file "$work/home/.gitconfig" user.email pat@example.org
sc install gid --workdir "$work/ws" > /dev/null 2>&1
sc uninstall gid > /dev/null
[ ! -e "$gidconf" ] && pass "uninstall removes the instance's git identity" || fail "uninstall leaves the git identity"
rm "$work/home/.gitconfig"
sc uninstall gi2 > /dev/null
# import copies the project, its graph and its sessions into the instance.
# From here on the host's opencode runs again: the count starts over after.
mkdir -p "$work/from/proj" "$work/impws" "$work/impws2" "$work/home/.local/share/mcp-memory"
printf 'work\n' > "$work/from/proj/file.txt"
printf '%s\n' '{"type":"entity","name":"a","entityType":"t","observations":["o"]}' \
  > "$work/home/.local/share/mcp-memory/memory.json"
out="$(sc install imp --workdir "$work/impws" 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "install for the import test: rc=$rc $out"
out="$(sc up imp 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "up for the import test: rc=$rc $out"
# --from names a project: the copy would hand the agent what holds the logins.
mkdir -p "$work/home/.dotdir/p"
for from in / "$work/home" "$work" "$work/home/.dotdir/p" "$work/config" "$work/config/tea" "$work/run"; do
  out="$(sc import imp --from "$from" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "import copies a project" <<<"$out" && [ -z "$(ls -A "$work/impws")" ] \
    && pass "import refuses --from ${from/#"$work"/WORK}" || fail "import --from $from: rc=$rc $out"
done
: > "$FIX/opencode-calls"; rm -f "$FIX/imported-session"
touch "$FIX/exec-escape"
out="$(sc import imp --from "$work/from" 2>&1)"; rc=$?
rm "$FIX/exec-escape"
! grep -q $'\033' <<<"$out" && pass "import shows no control sequence from inside the container" \
  || fail "import printed a control sequence"
[ "$rc" = 0 ] && [ "$(cat "$work/impws/proj/file.txt")" = work ] \
  && grep -q "cp /src/memory.json /seed/memory.jsonl" "$FIX/seed-calls" \
  && [ "$(cat "$FIX/imported-session")" = "$(cat "$FIX/host-export")" ] \
  && grep -qxF "imp imported $work/from: its files, the memory graph and 2 sessions" <<<"$out" \
  && [ "$(wc -l < "$FIX/opencode-calls")" = 3 ] \
  && pass "import copies the files, the graph and the sessions" || fail "import: rc=$rc $out"
out="$(sc import imp --from "$work/from" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "it is not empty" <<<"$out" \
  && pass "import into a used work directory says so" || fail "import again: rc=$rc $out"
sc down imp > /dev/null
out="$(sc install imp2 --workdir "$work/impws2" 2>&1)" && out="$(sc up imp2 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "up for the busy import test: rc=$rc $out"
touch "$FIX/export-busy"; rm -f "$FIX/imported-session"
out="$(sc import imp2 --from "$work/from" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "is busy" <<<"$out" && [ ! -e "$FIX/imported-session" ] \
  && [ -z "$(ls -A "$work/impws2")" ] \
  && pass "import with a busy session imports none" || fail "import with a busy session: rc=$rc $out"
rm "$FIX/export-busy"
sc down imp2 > /dev/null
out="$(sc import imp2 --from "$work/from" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "is not running" <<<"$out" \
  && pass "import without the instance says so" || fail "import without the instance: rc=$rc $out"
mkdir -p "$work/valws"
out="$(sc install valg --workdir "$work/valws" 2>&1)" && out="$(sc up valg 2>&1)"; rc=$?
[ "$rc" = 0 ] || fail "up for the validation import test: rc=$rc $out"
out="$(sc import valg --from "$work/from" --memory "$work/mem-mixed/memory.json" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "with entities and relations only" <<<"$out" && [ -z "$(ls -A "$work/valws")" ] \
  && pass "import refuses a bad graph before copying" || fail "import with a bad graph: rc=$rc $out"
sc down valg > /dev/null
: > "$FIX/opencode-calls"; oc0=0
# A locale widens a-z to accented letters: the launcher checks, and runs its
# commands, in C whatever the caller's is.
acc=$'\xc3\xa9'; loc=
for l in $(locale -a 2>/dev/null | grep -iE '\.utf-?8$'); do
  LC_ALL=$l bash -c '[[ $1 =~ ^[a-z]+$ ]]' _ "$acc" 2>/dev/null && { loc=$l; break; }
done
if [ -n "$loc" ]; then
  out="$(LC_ALL=$loc sc up "inst$acc" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "letters, digits, _ and - only" <<<"$out" \
    && pass "an instance name with an accented letter is refused in $loc" || fail "instance name in $loc: rc=$rc $out"
else
  echo "SKIP: an accented instance name (no locale here widens a-z)"
fi
# An instance name is short and no option.
long=$(printf 'a%.0s' {1..33})
for bad in --help -x "$long"; do
  out="$(sc down "$bad" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && grep -qF "an instance names the container" <<<"$out" \
    && pass "an instance named ${bad:0:8} is refused" || fail "instance $bad: rc=$rc $out"
done
out="$(sc uninstall "${long:0:32}" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "an instance name of 32 characters is taken" || fail "a 32-character instance: rc=$rc $out"
touch "$FIX/want-locale"
out="$(LC_ALL=${loc:-en_US.UTF-8} sc down valg 2>&1)"; rc=$?
rm "$FIX/want-locale"
[ "$rc" = 0 ] && [ -s "$FIX/locale-seen" ] && ! grep -qv ' C$' "$FIX/locale-seen" \
  && pass "the launcher's commands run in the C locale" \
  || fail "commands outside the C locale: rc=$rc $(sort -u "$FIX/locale-seen" 2>/dev/null | tr '\n' ' ')"
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
sib="$(mktemp -d -p /tmp)"; mkdir "$sib/fix"; : > "$sib/fix/envcheck"; echo OBS-SECRET-1 > "$sib/fix/imported"
# Its commands, the caller's opencode with a login in it among them, lie apart.
sibtools="$(mktemp -d -p /tmp)"; mkdir "$sibtools/bin" "$sibtools/userbin" "$sibtools/evilbin"
cp "$tools/bin/podman" "$sibtools/bin/"; cp "$tools/userbin/opencode" "$sibtools/userbin/"
stray="$(mktemp -p /tmp)"; echo OBS-SECRET-1 > "$stray"
left="$(leakfiles)"
[ "$left" = "$stray" ] && pass "the leak scan passes over another suite's run and still finds a stray login" \
  || fail "the leak scan with another suite's run: $left"
rm -rf "$sib" "$sibtools" "$stray"
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
