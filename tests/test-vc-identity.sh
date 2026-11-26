#!/bin/bash
# test-vc-identity.sh — vc-identity.sh prints the author a bare `geectl
# changelog generate` writes, resolving in the same order generate does:
# the config file's `[identity]` section, then VC_REALNAME / VC_MAILADDR,
# then the OBS account (`geectl remote whois $GEECTL_OBS_USERNAME`),
# then git identity (`user.name` / `user.email`).
# A fake geectl stands in for remote whois, and a fixture gitconfig for
# git. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
VCID="$HERE/../skills/opensuse-packaging/scripts/vc-identity.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export TMPDIR="$work"
mkdir -p "$work/bin"
cat > "$work/bin/geectl" <<'EOF'
#!/bin/bash
[ "$1" = remote ] && [ "$2" = whois ] && [ -n "$3" ] || { echo "fake geectl: unexpected $*" >&2; exit 9; }
case "$WHOIS_MODE" in
  ok) printf '%s' '{"login": "jane", "realname": "Jane Packager", "email": "jane@suse.example", "state": "confirmed"}' ;;
  fail) echo '{"error":{"code":"auth_failed","context":"401 Unauthorized"}}' >&2; exit 1 ;;
  garbled) printf 'probe\n' ;;
  noemail) printf '%s' '{"login": "jane", "realname": "Jane Packager", "email": "", "state": "confirmed"}' ;;
  norealname) printf '%s' '{"login": "jane", "realname": "", "email": "jane@suse.example", "state": "confirmed"}' ;;
esac
EOF
chmod +x "$work/bin/geectl"
# The git fixture: a global config carrying a real identity, an empty
# one, and a misshapen one. The script runs in $work (no repository),
# so the local scope never applies unless a case builds one.
cat > "$work/gitconfig" <<'EOF'
[user]
	name = Git Person
	email = git@example
EOF
: > "$work/gitconfig-empty"
cat > "$work/gitconfig-bad" <<'EOF'
[user]
	name = Git Person
	email = not-an-email
EOF
# The config leg needs a python3 with tomllib (3.11+). The minimal
# PATH below would find only the system python3, so the invoking
# python3's directory joins it.
PY3DIR="$(dirname "$(command -v python3 2>/dev/null || echo /usr/bin/python3)")"
# run <VAR=val ...>: the script in $work with a controlled environment.
run() { (cd "$work" && env -i PATH="$work/bin:$PY3DIR:/usr/bin:/bin" HOME="$work" GIT_CONFIG_SYSTEM=/dev/null "$@" /bin/bash "$VCID" 2>&1); }
# case_ <name> <expected rc> <expected output> <VAR=val ...>
case_() {
  local name="$1" want_rc="$2" want="$3" out got
  shift 3
  out="$(run "$@")"; got=$?
  [ "$got" = "$want_rc" ] && grep -qF -- "$want" <<<"$out" && pass "$name (rc=$want_rc)" || {
    fail "$name: expected rc=$want_rc and '$want', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
GITCFG="$work/gitconfig"
case_ env-wins 0 "Env Person <env@example>" GIT_CONFIG_GLOBAL="$GITCFG" VC_REALNAME="Env Person" VC_MAILADDR="env@example" GEECTL_OBS_USERNAME=jane WHOIS_MODE=ok
case_ env-half-realname 3 "VC_REALNAME is set but VC_MAILADDR is not" GIT_CONFIG_GLOBAL="$GITCFG" VC_REALNAME="Env Person" GEECTL_OBS_USERNAME=jane WHOIS_MODE=ok
case_ env-half-mailaddr 3 "VC_MAILADDR is set but VC_REALNAME is not" GIT_CONFIG_GLOBAL="$GITCFG" VC_MAILADDR="env@example" GEECTL_OBS_USERNAME=jane WHOIS_MODE=ok
case_ env-misshapen 3 "VC_REALNAME/VC_MAILADDR: identity needs a non-empty name and an email address" GIT_CONFIG_GLOBAL="$GITCFG" VC_REALNAME="Env Person" VC_MAILADDR="not-an-email"
case_ whois 0 "Jane Packager <jane@suse.example>" GIT_CONFIG_GLOBAL="$GITCFG" GEECTL_OBS_USERNAME=jane WHOIS_MODE=ok
out="$(run GIT_CONFIG_GLOBAL="$GITCFG" GEECTL_OBS_USERNAME=jane WHOIS_MODE=ok)"
[ "$out" = "Jane Packager <jane@suse.example>" ] && pass "whois: prints only the identity" \
  || fail "whois: printed '$out'"
case_ whois-norealname-falls-to-git 0 "Git Person <git@example>" GIT_CONFIG_GLOBAL="$GITCFG" GEECTL_OBS_USERNAME=jane WHOIS_MODE=norealname
case_ whois-noemail-falls-to-git 0 "Git Person <git@example>" GIT_CONFIG_GLOBAL="$GITCFG" GEECTL_OBS_USERNAME=jane WHOIS_MODE=noemail
case_ whois-fails 3 "geectl remote whois jane failed" GIT_CONFIG_GLOBAL="$GITCFG" GEECTL_OBS_USERNAME=jane WHOIS_MODE=fail
case_ whois-garbled 3 "not a whois record" GIT_CONFIG_GLOBAL="$GITCFG" GEECTL_OBS_USERNAME=jane WHOIS_MODE=garbled
case_ no-user-git 0 "Git Person <git@example>" GIT_CONFIG_GLOBAL="$GITCFG" WHOIS_MODE=ok
case_ nothing-anywhere 3 "no changelog identity found" GIT_CONFIG_GLOBAL="$work/gitconfig-empty" WHOIS_MODE=ok
case_ git-misshapen 3 "no changelog identity found" GIT_CONFIG_GLOBAL="$work/gitconfig-bad" WHOIS_MODE=ok
# The config level: `[identity]` in the geectl config file, first.
mkdir -p "$work/xdg-ok/geectl" "$work/xdg-half-name/geectl" "$work/xdg-half-email/geectl" "$work/xdg-unknown/geectl" "$work/xdg-nontable/geectl" "$work/xdg-bad/geectl" "$work/xdg-shape/geectl" "$work/xdg-empty"
cat > "$work/xdg-ok/geectl/config.toml" <<'EOF'
[identity]
name = "Config Person"
email = "config@example"
EOF
cat > "$work/xdg-half-name/geectl/config.toml" <<'EOF'
[identity]
email = "config@example"
EOF
cat > "$work/xdg-half-email/geectl/config.toml" <<'EOF'
[identity]
name = "Config Person"
EOF
cat > "$work/xdg-unknown/geectl/config.toml" <<'EOF'
[identity]
name = "Config Person"
email = "config@example"
nickname = "conf"
EOF
cat > "$work/xdg-nontable/geectl/config.toml" <<'EOF'
identity = "Config Person"
EOF
cat > "$work/xdg-bad/geectl/config.toml" <<'EOF'
[identity
name = "Config Person"
EOF
cat > "$work/xdg-shape/geectl/config.toml" <<'EOF'
[identity]
name = "Config Person"
email = "not-an-email"
EOF
case_ config-wins 0 "Config Person <config@example>" GIT_CONFIG_GLOBAL="$GITCFG" XDG_CONFIG_HOME="$work/xdg-ok" VC_REALNAME="Env Person" VC_MAILADDR="env@example" GEECTL_OBS_USERNAME=jane WHOIS_MODE=ok
case_ config-half-name 3 "needs both 'name' and 'email' (missing 'name')" GIT_CONFIG_GLOBAL="$GITCFG" XDG_CONFIG_HOME="$work/xdg-half-name" VC_REALNAME="Env Person" VC_MAILADDR="env@example"
case_ config-half-email 3 "needs both 'name' and 'email' (missing 'email')" GIT_CONFIG_GLOBAL="$GITCFG" XDG_CONFIG_HOME="$work/xdg-half-email"
case_ config-unknown-key 3 "unknown config key 'identity.nickname'" GIT_CONFIG_GLOBAL="$GITCFG" XDG_CONFIG_HOME="$work/xdg-unknown"
case_ config-not-table 3 "'identity' must be a table" GIT_CONFIG_GLOBAL="$GITCFG" XDG_CONFIG_HOME="$work/xdg-nontable"
case_ config-malformed 3 "is not valid TOML" GIT_CONFIG_GLOBAL="$GITCFG" XDG_CONFIG_HOME="$work/xdg-bad"
case_ config-misshapen 3 "identity needs a non-empty name and an email address" GIT_CONFIG_GLOBAL="$GITCFG" XDG_CONFIG_HOME="$work/xdg-shape"
case_ config-absent-falls-to-env 0 "Env Person <env@example>" GIT_CONFIG_GLOBAL="$GITCFG" XDG_CONFIG_HOME="$work/xdg-empty" VC_REALNAME="Env Person" VC_MAILADDR="env@example"
# The HOME default: a config under $HOME/.config, no XDG_CONFIG_HOME.
mkdir -p "$work/.config/geectl"
cat > "$work/.config/geectl/config.toml" <<'EOF'
[identity]
name = "Config Person"
email = "config@example"
EOF
case_ config-home-default 0 "Config Person <config@example>" GIT_CONFIG_GLOBAL="$GITCFG" VC_REALNAME="Env Person" VC_MAILADDR="env@example"
# Two config files at different paths is a misconfiguration.
case_ config-two-files 3 "two geectl config files found" GIT_CONFIG_GLOBAL="$GITCFG" XDG_CONFIG_HOME="$work/xdg-ok"
rm -rf "$work/.config"

# The placeholder skip: a repository whose local identity is the
# synthesized one falls through to the global identity.
mkdir -p "$work/repo" && git -C "$work/repo" init -q
git -C "$work/repo" config user.name geectl
git -C "$work/repo" config user.email geectl@localhost
out="$(cd "$work/repo" && env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work" GIT_CONFIG_GLOBAL="$GITCFG" GIT_CONFIG_SYSTEM=/dev/null WHOIS_MODE=ok /bin/bash "$VCID" 2>&1)"; got=$?
[ "$got" = 0 ] && [ "$out" = "Git Person <git@example>" ] && pass "placeholder local identity falls through to global (rc=0)" \
  || { fail "placeholder: expected rc=0 and 'Git Person <git@example>', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }

echo "---"; [ "$fails" = 0 ] && echo "all vc-identity checks passed" || echo "$fails FAILED"
exit $((fails > 0))
