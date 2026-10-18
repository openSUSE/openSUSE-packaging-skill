#!/bin/bash
# Print the author identity a bare `osc vc` writes into a .changes header —
# 'Full Name <email>' — by letting osc vc write one into a scratch file. osc
# takes it from oscrc's realname/email, then VC_REALNAME/VC_MAILADDR, then the
# OBS account; running osc vc itself gets exactly that without reading the
# oscrc, which holds credentials. The git identity is not it (real case:
# sr#1385844 shipped an entry signed with the git address).
#
# Usage: vc-identity.sh
# Exit: 0 = identity printed, 2 = usage, 3 = osc vc failed or wrote no
#       'Day Mon DD HH:MM:SS UTC YYYY - Name <email>' header.
set -uo pipefail
case "${1:-}" in
  -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
d=$(mktemp -d "${TMPDIR:-/tmp}/vc-identity.XXXXXX") || exit 3
trap 'rm -rf "$d"' EXIT
# stdin from /dev/null: an unconfigured osc prompts for credentials instead of failing
if ! (cd "$d" && osc vc -m probe "$d/probe.changes") < /dev/null > "$d/out" 2>&1; then
  echo "vc-identity.sh: osc vc failed: $(head -n1 "$d/out")" >&2; exit 3
fi
who=$(sed -n '2s/^[A-Z][a-z][a-z] [A-Z][a-z][a-z] [ 0-9][0-9] [0-9:]\{8\} UTC [0-9]\{4\} - \([^<>]*[^<> ] <[^<>@ ]\{1,\}@[^<>@ ]\{1,\}>\)$/\1/p' \
  "$d/probe.changes" 2>/dev/null)
[ -n "$who" ] || { echo "vc-identity.sh: osc vc wrote no 'Day Mon DD HH:MM:SS UTC YYYY - Name <email>' header" >&2; exit 3; }
printf '%s\n' "$who"
