#!/bin/bash
# test-build-summary.sh — build-summary.sh turns a green build red when a built
# RPM requires a user() or group() its own scriptlets create but no built RPM
# provides: rpm derives the dependency from %attr ownership, so the package
# cannot be installed (owntone sr#1385677: "nothing provides group(owntone)").
# A fake rpm on PATH answers the queries. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BS="$HERE/../skills/opensuse-packaging/scripts/build-summary.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export TMPDIR="$work" HOME="$work"
mkdir -p "$work/bin" "$work/root/home/abuild/rpmbuild/RPMS/x86_64"
printf '[  10s] ... finished "build owntone.spec" at Mon Oct 19 2026.\n' > "$work/root/.build.log"
: > "$work/root/home/abuild/rpmbuild/RPMS/x86_64/owntone-29.3-0.x86_64.rpm"
cat > "$work/bin/rpm" <<'EOF'
#!/bin/bash
[ "$1" = -qp ] || { echo "fake rpm: unexpected $*" >&2; exit 9; }
case "$2" in
  --requires) printf 'libc.so.6()(64bit)\ngroup(owntone)\nuser(owntone)\ngroup(mail)\n' ;;
  --provides) printf 'owntone = 29.3-0\n'; [ -n "${PROVIDE_USERS:-}" ] && printf 'group(owntone)\nuser(owntone)\n' ;;
  --scripts) printf 'preinstall scriptlet (using /bin/sh):\ngetent group owntone >/dev/null || groupadd -r owntone\n'
             printf 'getent passwd owntone >/dev/null || useradd -r -g owntone -d /var/lib/owntone owntone\n' ;;
esac
EOF
chmod +x "$work/bin/rpm"

out="$(PATH="$work/bin:$PATH" bash "$BS" "$work/root" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qF 'nothing provides group(owntone)' <<<"$out" && grep -qF 'user(owntone)' <<<"$out" \
  && ! grep -qF 'group(mail)' <<<"$out" \
  && pass "a user/group its %pre creates, provided by nothing: red" \
  || { fail "unprovided group(owntone): rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(PROVIDE_USERS=1 PATH="$work/bin:$PATH" bash "$BS" "$work/root" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qF 'OK: every user()/group() a built RPM requires' <<<"$out" \
  && pass "the package provides its own user and group: green" \
  || { fail "provided group(owntone): rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(PATH="$work/bin:$PATH" bash "$BS" "$work/root/.build.log" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qF 'not checked: no built RPMs' <<<"$out" \
  && pass "a bare log (no RPMs): the check says it did not run" \
  || { fail "bare log: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

echo "---"; [ "$fails" = 0 ] && echo "all build-summary checks passed" || echo "$fails FAILED"
exit $((fails > 0))
