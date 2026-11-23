#!/bin/bash
# Print the author identity `geectl changelog generate` writes into a
# .changes header — 'Full Name <email>' — from the OBS account's own record
# (`geectl remote whois`): the real name, falling back to the login when the
# account carries none, with the account's email. The git identity is not it
# (real case: sr#1385844 shipped an entry signed with the git address).
#
# Usage: vc-identity.sh
# Exit: 0 = identity printed, 2 = usage, 3 = the whois read failed or the
#       account carries no usable name/email.
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
[ -n "${GEECTL_OBS_USERNAME:-}" ] || { echo "vc-identity.sh: set GEECTL_OBS_USERNAME" >&2; exit 3; }
who="$(geectl remote whois "$GEECTL_OBS_USERNAME" 2>&1)" \
  || { echo "vc-identity.sh: geectl remote whois $GEECTL_OBS_USERNAME failed: $(head -n1 <<<"$who")" >&2; exit 3; }
who="$(printf '%s' "$who" | python3 -I -c '
import sys, json
try:
    person = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(2)
name = person.get("realname") or person.get("login") or ""
email = person.get("email") or ""
if not name or not email or "@" not in email:
    sys.exit(1)
print(f"{name} <{email}>")
')" || { echo "vc-identity.sh: geectl remote whois $GEECTL_OBS_USERNAME carries no usable name/email" >&2; exit 3; }
printf '%s\n' "$who"
