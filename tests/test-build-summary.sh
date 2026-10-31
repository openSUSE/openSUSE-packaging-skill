#!/bin/bash
# test-build-summary.sh — build-summary.sh turns a green build red when a built
# RPM requires a user() or group() its own scriptlets create but no built RPM
# provides: rpm derives the dependency from %attr ownership, so the package
# cannot be installed (owntone sr#1385677: "nothing provides group(owntone)").
# The RPMs it queries are the build's own: a chroot root's .build.packages, a
# VM root's (build-type=kvm) .mount/.build.packages, or --rpms DIR for a
# captured log, and a lookup with no source RPM there is no verdict.
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
green='[  10s] ... finished "build owntone.spec" at Mon Oct 19 2026.'
# A chroot root, as obs-build leaves it: .build.packages links to the rpmbuild tree.
mkdir -p "$work/bin" "$work/root/home/abuild/rpmbuild/RPMS/x86_64" "$work/root/home/abuild/rpmbuild/SRPMS"
printf '%s\n' "$green" > "$work/root/.build.log"
: > "$work/root/home/abuild/rpmbuild/RPMS/x86_64/owntone-29.3-0.x86_64.rpm"
: > "$work/root/home/abuild/rpmbuild/SRPMS/owntone-29.3-0.src.rpm"
ln -s home/abuild/rpmbuild "$work/root/.build.packages"
# owntone-* creates its user and group in %pre; any other RPM needs no user.
# A file that says "truncated" is what rpm cannot read: an error, and exit 1.
cat > "$work/bin/rpm" <<'EOF'
#!/bin/bash
[ "$1" = -qp ] || { echo "fake rpm: unexpected $*" >&2; exit 9; }
q=$2; shift 2; [ "$q" != --qf ] || shift
bad=0
for f in "$@"; do
  if grep -qs truncated "$f"; then
    echo "error: $f: signature hdr blob(4388): BAD, read returned 0" >&2; bad=1; continue
  fi
  case "${f##*/}" in
    owntone-*)
      case "$q" in
        --requires) printf 'libc.so.6()(64bit)\ngroup(owntone)\nuser(owntone)\ngroup(mail)\n' ;;
        --provides) printf 'owntone = 29.3-0\n'; [ -n "${PROVIDE_USERS:-}" ] && printf 'group(owntone)\nuser(owntone)\n' ;;
        --scripts) printf 'preinstall scriptlet (using /bin/sh):\ngetent group owntone >/dev/null || groupadd -r owntone\n'
                   printf 'getent passwd owntone >/dev/null || useradd -r -g owntone -d /var/lib/owntone owntone\n' ;;
      esac ;;
    *) [ "$q" != --provides ] || printf '%s = 1\n' "${f##*/}" ;;
  esac
done
exit "$bad"
EOF
chmod +x "$work/bin/rpm"
# expect <name> <rc> <message> <args...> — the output must name <message>.
expect() {
  local name=$1 want=$2 msg=$3 rc; shift 3
  last="$(PATH="$work/bin:$PATH" bash "$BS" "$@" 2>&1)"; rc=$?
  [ "$rc" = "$want" ] && grep -qF -- "$msg" <<<"$last" && pass "$name" \
    || { fail "$name: want rc=$want and '$msg', got rc=$rc"; printf '%s\n' "$last" | sed 's/^/    /'; }
}

expect "a user/group its %pre creates, provided by nothing: red" 1 'nothing provides group(owntone)' "$work/root"
grep -qF 'user(owntone)' <<<"$last" && ! grep -qF 'group(mail)' <<<"$last" \
  && pass "the red names user(owntone), not the system group(mail)" || fail "unprovided list: $last"
PROVIDE_USERS=1 expect "the package provides its own user and group: green" 0 'OK: every user()/group() a built RPM requires' "$work/root"
expect "a bare log (no RPMs): the check says it did not run" 0 'not checked: no built RPMs' "$work/root/.build.log"

# --- --rpms DIR LOGFILE: a captured log with the build's .build.packages --------
mkdir -p "$work/empty" "$work/srconly/SRPMS" "$work/norpm"
printf '[  10s] ... failed "build owntone.spec" at Mon Oct 19 2026.\n' > "$work/failed.log"
printf '%s\n' "$green" > "$work/green.log"
: > "$work/srconly/SRPMS/owntone-29.3-0.src.rpm"
expect "--rpms: a captured log gets the user/group check" 1 'nothing provides group(owntone)' \
  --rpms "$work/root/.build.packages" "$work/green.log"
expect "--rpms with no source RPM: no verdict" 3 "no source RPM under $work/empty/SRPMS" --rpms "$work/empty" "$work/green.log"
grep -qF 'no source RPM' <<<"$last" && ! grep -qF timeout <<<"$last" \
  && pass "--rpms no verdict: no timeout hint on a log that concluded" \
  || fail "--rpms no verdict: the timeout hint is for logs with no verdict line"
expect "--rpms: a failed build stays failed" 1 'VERDICT: FAILED' --rpms "$work/empty" "$work/failed.log"
expect "--rpms: no log is no log" 2 'no readable build log' --rpms "$work/empty" "$work/nope.log"
expect "--rpms: a source RPM and no binary (a test flavor): nothing to install, green" 0 'nothing to install' \
  --rpms "$work/srconly" "$work/green.log"
# Binary RPMs to query and no rpm to query them with: everything but rpm on PATH.
for t in awk basename cat comm cut date dirname find grep head python3 sed sort tail tr; do
  ln -s "$(command -v "$t")" "$work/norpm/$t"
done
out="$(PATH="$work/norpm" "$BASH" "$BS" --rpms "$work/root/.build.packages" "$work/green.log" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qF 'rpm is not on PATH' <<<"$out" && pass "--rpms: binary RPMs and no rpm on PATH: no verdict" \
  || { fail "--rpms without rpm: want rc=3, got rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# NoSource/NoPatch: rpmbuild writes <n-v-r>.nosrc.rpm, a source RPM all the same.
mkdir -p "$work/nosrc/RPMS/x86_64" "$work/nosrc/SRPMS"
: > "$work/nosrc/RPMS/x86_64/owntone-29.3-0.x86_64.rpm"
: > "$work/nosrc/SRPMS/owntone-29.3-0.nosrc.rpm"
PROVIDE_USERS=1 expect "--rpms: a nosrc.rpm is the source RPM" 0 'OK: every user()/group() a built RPM requires' \
  --rpms "$work/nosrc" "$work/green.log"
# An RPM rpm cannot read: the user/group check did not run, whatever the log says.
mkdir -p "$work/trunc/RPMS/x86_64" "$work/trunc/SRPMS"
echo truncated > "$work/trunc/RPMS/x86_64/owntone-29.3-0.x86_64.rpm"
: > "$work/trunc/SRPMS/owntone-29.3-0.src.rpm"
PROVIDE_USERS=1 expect "--rpms: an RPM rpm cannot read: no verdict" 3 'rpm cannot read the built RPMs' \
  --rpms "$work/trunc" "$work/green.log"
! grep -qF 'OK: every' <<<"$last" && pass "--rpms unreadable RPM: no OK for a check that did not run" \
  || fail "--rpms unreadable RPM: printed the OK of a check that did not run"

# --- root forms: the RPM directory is the build's, never home/abuild ---------------
# A VM root (build-type=kvm) builds in <root>/.mount; --clean wipes only that, so
# the chroot tree an earlier build left in the root stays, with its own RPMs.
K="$work/kvm"
mkdir -p "$K/.mount/.build.packages/RPMS/x86_64" "$K/.mount/.build.packages/SRPMS" \
  "$K/home/abuild/rpmbuild/RPMS/x86_64" "$K/home/abuild/rpmbuild/SRPMS"
: > "$K/img"
printf '%s\n' "$green" > "$K/.build.log"
: > "$K/.mount/.build.packages/RPMS/x86_64/owntone-29.3-0.x86_64.rpm"
: > "$K/.mount/.build.packages/SRPMS/owntone-29.3-0.src.rpm"
: > "$K/home/abuild/rpmbuild/RPMS/x86_64/stale-1.0-0.x86_64.rpm"
: > "$K/home/abuild/rpmbuild/SRPMS/stale-1.0-0.src.rpm"
ln -s home/abuild/rpmbuild "$K/.build.packages"
expect "kvm root: the RPMs of .mount/.build.packages are checked" 1 'nothing provides group(owntone)' "$K"
grep -qF 'owntone-29.3-0.x86_64.rpm' <<<"$last" && ! grep -qF 'stale-1.0-0' <<<"$last" \
  && pass "kvm root: the RPMs produced are the VM's, not the stale chroot tree's" || fail "kvm root RPM list: $last"
# No extracted packages (the VM never handed any back): the stale tree is no stand-in.
rm -rf "$K/.mount/.build.packages"
expect "kvm root without .mount/.build.packages: no verdict, not the stale RPMs' OK" 3 \
  "no source RPM under $K/.mount/.build.packages/SRPMS" "$K"
# The log names its build root: a VM build with an oscrc build-device has no
# <root>/img, and still builds in <root>/.mount.
D="$work/bdev"
mkdir -p "$D/.mount/.build.packages/RPMS/x86_64" "$D/.mount/.build.packages/SRPMS"
printf '[    0s] Using BUILD_ROOT=%s/.mount\n%s\n' "$D" "$green" > "$D/.build.log"
: > "$D/.mount/.build.packages/RPMS/x86_64/owntone-29.3-0.x86_64.rpm"
: > "$D/.mount/.build.packages/SRPMS/owntone-29.3-0.src.rpm"
expect "build-device root: the log's BUILD_ROOT, not the layout, names the RPMs" 1 'nothing provides group(owntone)' "$D"
# A VM build's log carries a NUL from the guest's boot (and, captured from osc, CRs):
# grep must still read it as text.
printf '[    0s] Using BUILD_ROOT=%s/.mount\n[    5s] \000\n%s\n' "$D" "$green" > "$D/.build.log"
PROVIDE_USERS=1 expect "kvm root whose log holds a NUL: green" 0 'VERDICT: GREEN' "$D"
printf '[    5s] boot\r\n[    5s] \000\r\n%s\r\n' "$green" > "$work/nul.log"
expect "a captured kvm log with CRs and a NUL: green" 0 'VERDICT: GREEN' "$work/nul.log"
# A kiwi or Dockerfile build writes no source RPM.
mkdir -p "$work/kiwi/.build.packages"
printf '%s\n' '[  10s] ... finished "build foo.kiwi" at Mon Oct 19 2026.' > "$work/kiwi/.build.log"
expect "a green non-spec build: green with no source RPM" 0 'VERDICT: GREEN' "$work/kiwi"
# A chroot build in a root that still holds an earlier VM build's .mount and img.
V="$work/vm2chroot"
mkdir -p "$V/.mount/.build.packages/RPMS/x86_64" "$V/.mount/.build.packages/SRPMS" \
  "$V/home/abuild/rpmbuild/RPMS/x86_64" "$V/home/abuild/rpmbuild/SRPMS"
: > "$V/img"
printf '[    0s] Using BUILD_ROOT=%s\n%s\n' "$V" "$green" > "$V/.build.log"
: > "$V/.mount/.build.packages/RPMS/x86_64/stale-1.0-0.x86_64.rpm"
: > "$V/.mount/.build.packages/SRPMS/stale-1.0-0.src.rpm"
: > "$V/home/abuild/rpmbuild/RPMS/x86_64/owntone-29.3-0.x86_64.rpm"
: > "$V/home/abuild/rpmbuild/SRPMS/owntone-29.3-0.src.rpm"
ln -s home/abuild/rpmbuild "$V/.build.packages"
expect "chroot build beside an old VM image: the log's BUILD_ROOT names the RPMs" 1 'nothing provides group(owntone)' "$V"
! grep -qF 'stale-1.0-0' <<<"$last" && pass "chroot build beside an old VM image: the old VM's RPMs are not listed" \
  || fail "chroot build beside an old VM image RPM list: $last"
# A chroot root whose RPM tree holds no source RPM is not this build's.
rm "$work/root/home/abuild/rpmbuild/SRPMS/owntone-29.3-0.src.rpm"
PROVIDE_USERS=1 expect "chroot root without a source RPM: no verdict" 3 'no source RPM under' "$work/root"

echo "---"; [ "$fails" = 0 ] && echo "all build-summary checks passed" || echo "$fails FAILED"
exit $((fails > 0))
