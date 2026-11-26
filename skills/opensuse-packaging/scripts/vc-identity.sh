#!/bin/bash
# Print the author identity `geectl changelog generate` writes into a
# .changes header — 'Full Name <email>' — in the order it resolves:
# the config file's `[identity]` section, then the VC_REALNAME /
# VC_MAILADDR environment, then the OBS account's own record
# (`geectl remote whois`), then git identity (`user.name` /
# `user.email`, local then global then system).
# A level that yields nothing falls through to the next; a level
# that is half-set or fails stops with an error naming it. With no
# identity from any level it refuses.
#
# Usage: vc-identity.sh
# Exit: 0 = identity printed, 2 = usage, 3 = no identity, or a level
#       failed (the message names the level).
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

# trim <text>: leading and trailing whitespace removed.
trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# identity_ok <name> <email>: a non-empty name, and an email address
# (an `@`, no whitespace) — the form a header author takes.
identity_ok() {
  local name email
  name=$(trim "$1"); email=$(trim "$2")
  [ -n "$name" ] || return 1
  [ -n "$email" ] || return 1
  case "$email" in *@*) ;; *) return 1 ;; esac
  case "$email" in *[[:space:]]*) return 1 ;; esac
  return 0
}

# The config level: the `[identity]` section of the geectl config file
# (`$XDG_CONFIG_HOME/geectl/config.toml`, default
# `~/.config/geectl/config.toml`). A missing file, or a file with no
# `[identity]`, falls through. Two config files at different paths, a
# half-set, misshapen or unknown-keyed `[identity]`, or a malformed file
# stops with an error naming it.
config_out=$(python3 -I -c 'import os, sys, tomllib
xdg = os.environ.get("XDG_CONFIG_HOME")
home = os.environ.get("HOME")
xdg_path = xdg + "/geectl/config.toml" if xdg and os.path.isabs(xdg) else None
def_path = home + "/.config/geectl/config.toml" if home and os.path.isabs(home) else None
if xdg_path and def_path and xdg_path != def_path and os.path.exists(xdg_path) and os.path.exists(def_path):
    print("vc-identity.sh: two geectl config files found (" + xdg_path + " and " + def_path + "); remove one", file=sys.stderr)
    sys.exit(2)
path = xdg_path or def_path
if path is None:
    print("vc-identity.sh: cannot locate a config directory: set XDG_CONFIG_HOME or HOME", file=sys.stderr)
    sys.exit(2)
if not os.path.exists(path):
    sys.exit(1)
try:
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
except tomllib.TOMLDecodeError as exc:
    print("vc-identity.sh: " + path + " is not valid TOML: " + str(exc), file=sys.stderr)
    sys.exit(2)
except OSError as exc:
    print("vc-identity.sh: cannot read " + path + ": " + str(exc), file=sys.stderr)
    sys.exit(2)
ident = data.get("identity")
if ident is None:
    sys.exit(1)
if not isinstance(ident, dict):
    print("vc-identity.sh: " + path + ": '\''identity'\'' must be a table", file=sys.stderr)
    sys.exit(2)
for key in ident:
    if key not in ("name", "email"):
        print("vc-identity.sh: " + path + ": unknown config key '\''identity." + key + "'\''", file=sys.stderr)
        sys.exit(2)
name = ident.get("name")
email = ident.get("email")
if name is None:
    print("vc-identity.sh: " + path + ": '\''[identity]'\'' needs both '\''name'\'' and '\''email'\'' (missing '\''name'\'')", file=sys.stderr)
    sys.exit(2)
if email is None:
    print("vc-identity.sh: " + path + ": '\''[identity]'\'' needs both '\''name'\'' and '\''email'\'' (missing '\''email'\'')", file=sys.stderr)
    sys.exit(2)
def as_str(value, key):
    if not isinstance(value, str):
        print("vc-identity.sh: " + path + ": '\''" + key + "'\'' must be a string", file=sys.stderr)
        sys.exit(2)
    text = value.strip()
    if not text:
        print("vc-identity.sh: " + path + ": '\''" + key + "'\'' must not be empty", file=sys.stderr)
        sys.exit(2)
    return text
name = as_str(name, "identity.name")
email = as_str(email, "identity.email")
if "@" not in email or any(c.isspace() for c in email):
    print("vc-identity.sh: " + path + ": '\''[identity]'\'': identity needs a non-empty name and an email address", file=sys.stderr)
    sys.exit(2)
print(name + " <" + email + ">")' 2>&1); config_rc=$?
case "$config_rc" in
  0) printf '%s\n' "$config_out"; exit 0 ;;
  1) ;; # no identity in the config: fall through
  *) printf '%s\n' "$config_out" >&2; exit 3 ;;
esac

# The environment level: both variables or neither. One without the
# other is a misconfiguration, and a misshapen pair is one too.
env_name=$(trim "${VC_REALNAME:-}")
env_email=$(trim "${VC_MAILADDR:-}")
if [ -n "$env_name" ] || [ -n "$env_email" ]; then
  if [ -z "$env_name" ]; then
    echo "vc-identity.sh: VC_MAILADDR is set but VC_REALNAME is not" >&2; exit 3
  fi
  if [ -z "$env_email" ]; then
    echo "vc-identity.sh: VC_REALNAME is set but VC_MAILADDR is not" >&2; exit 3
  fi
  identity_ok "$env_name" "$env_email" || { echo "vc-identity.sh: VC_REALNAME/VC_MAILADDR: identity needs a non-empty name and an email address" >&2; exit 3; }
  printf '%s <%s>\n' "$env_name" "$env_email"
  exit 0
fi

# The OBS-account level: the authenticated user's real name and email
# from `geectl remote whois`. No username yields nothing, and a person
# carrying only one of the two does not identify an author — both fall
# through to git. A failed whois read is an error.
if [ -n "${GEECTL_OBS_USERNAME:-}" ]; then
  who=$(geectl remote whois "$GEECTL_OBS_USERNAME" 2>&1) \
    || { echo "vc-identity.sh: geectl remote whois $GEECTL_OBS_USERNAME failed: $(head -n1 <<<"$who")" >&2; exit 3; }
  who=$(printf '%s' "$who" | python3 -I -c '
import sys, json
try:
    person = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(2)
if not isinstance(person, dict):
    sys.exit(2)
name = (person.get("realname") or "").strip()
email = (person.get("email") or "").strip()
if not name or not email or "@" not in email or any(c.isspace() for c in email):
    sys.exit(1)
print(f"{name} <{email}>")
')
  case $? in
    0) printf '%s\n' "$who"; exit 0 ;;
    1) ;; # no usable name/email: fall through to git
    *) echo "vc-identity.sh: geectl remote whois $GEECTL_OBS_USERNAME returned output that is not a whois record" >&2; exit 3 ;;
  esac
fi

# git_value <key> <placeholder>: the value git resolves for the key,
# local then global then system, skipping a value equal to the
# placeholder (the identity a working copy synthesizes is never a
# person's). Prints nothing when no scope carries the key.
# Exit 2 when the git config is broken.
git_value() {
  local scope out rc err
  err=$(mktemp)
  for scope in local global system; do
    out=$(git config --"$scope" --get "$1" 2>"$err"); rc=$?
    if [ "$rc" -eq 0 ]; then
      out=$(trim "$out")
      if [ -n "$out" ] && [ "$out" != "$2" ]; then printf '%s' "$out"; rm -f "$err"; return 0; fi
    elif [ -s "$err" ]; then
      case "$(cat "$err")" in
        *"not a git repository"*|*"--local can only be used inside a git repository"*) ;;
        *) rm -f "$err"; return 2 ;;
      esac
    fi
  done
  rm -f "$err"
  return 1
}

# The git level: `user.name` / `user.email` as git resolves them.
# A broken git config is an error; git absent yields nothing.
if command -v git >/dev/null 2>&1; then
  git_name=$(git_value user.name geectl); name_rc=$?
  git_email=$(git_value user.email geectl@localhost); email_rc=$?
  if [ "$name_rc" -eq 2 ] || [ "$email_rc" -eq 2 ]; then
    echo "vc-identity.sh: git config is broken" >&2; exit 3
  fi
  if [ "$name_rc" -eq 0 ] && [ "$email_rc" -eq 0 ] && identity_ok "$git_name" "$git_email"; then
    printf '%s <%s>\n' "$git_name" "$git_email"
    exit 0
  fi
fi

echo "vc-identity.sh: no changelog identity found: set an [identity] section in the geectl config, VC_REALNAME and VC_MAILADDR, an OBS login with a real name and email, or git user.name and user.email" >&2
exit 3
