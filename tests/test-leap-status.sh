#!/bin/bash
# test-leap-status.sh — leap-status.sh offline: a fake `curl` on PATH records
# its arguments and serves fixtures (a missing one is a 404), a fake `osc`
# answers 404. Public src.opensuse.org reads need no token, so none is sent
# even with a tea login on disk. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LS="$HERE/../skills/opensuse-packaging/scripts/leap-status.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
FIX="$work/fix"; export FIX

mkdir -p "$work/bin" "$FIX/web" "$work/home/.config/tea" "$work/pylib"
cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FIX/curl-calls"
url=${!#}
f="$FIX/web/$(printf %s "${url#https://}" | tr '/?&=' '____')"
[ -f "$f" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cat "$f"
EOF
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1
EOF
chmod +x "$work/bin/"*
web() { printf '%s\n' "$2" > "$FIX/web/$(printf %s "$1" | tr '/?&=' '____')"; }
spec() { printf '{"content": "%s"}' "$(printf 'Name: p\nVersion: %s\n' "$1" | base64 | tr -d '\n')"; }
A=src.opensuse.org/api/v1/repos/pool/p
web "$A/branches" '[{"name": "factory"}, {"name": "leap-16.0"}]'
web "$A/contents/p.spec?ref=factory" "$(spec 1.2)"
web "$A/contents/p.spec?ref=leap-16.0" "$(spec 1.2)"
web "$A/pulls?state=open" '[]'

# A tea login on disk, and a yaml stand-in that marks any parse of it.
printf '{"logins": [{"name": "src.opensuse.org", "token": "t0ken"}]}\n' > "$work/home/.config/tea/config.yml"
printf 'import json\nimport os\n\n\ndef safe_load(f):\n    open(os.environ["FIX"] + "/tea-read", "w").close()\n    return json.load(f)\n' > "$work/pylib/yaml.py"

out="$(HOME="$work/home" PYTHONPATH="$work/pylib" PATH="$work/bin:$PATH" bash "$LS" p 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qF "VERDICT: IN-SYNC" <<<"$out" && pass "in sync (rc=0)" \
  || { fail "in sync: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
[ -s "$FIX/curl-calls" ] && ! grep -qi "authorization" "$FIX/curl-calls" && pass "no token sent" \
  || fail "a token was sent: $(cat "$FIX/curl-calls" 2>/dev/null)"
[ ! -e "$FIX/tea-read" ] && pass "the tea config is never read" || fail "the tea config was read"

echo "---"; [ "$fails" = 0 ] && echo "all leap-status checks passed" || echo "$fails FAILED"
exit $((fails > 0))
