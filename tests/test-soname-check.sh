#!/bin/bash
# test-soname-check.sh — soname-check.sh audits a build's own RPMs: a chroot
# root's .build.packages, a VM root's (build-type=kvm) .mount/.build.packages,
# or those of the build root the root's log names, never the stale chroot tree
# an earlier build left in that root. That holds for the newest root under the
# oscrc build-root (no arguments) and for --build-root. HOME holds an oscrc
# whose build-root is inside this suite's own directory, so no other root is
# read; a fake rpm on PATH answers the queries. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SC="$HERE/../skills/opensuse-packaging/scripts/soname-check.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT
B="$work/roots"
export HOME="$work/home"
mkdir -p "$work/bin" "$B" "$HOME/.config/osc"
printf '[general]\nbuild-root = %s/%%(package)s-%%(repo)s-%%(arch)s\n' "$B" > "$HOME/.config/osc/oscrc"
# The package name from the file name; no SONAME, no symlink: clean.
cat > "$work/bin/rpm" <<'EOF'
#!/bin/bash
[ "$1" = -qp ] || { echo "fake rpm: unexpected $*" >&2; exit 9; }
f=${!#}; f=${f##*/}
[ "$2" = --qf ] && printf '%s' "${f%%-[0-9]*}"
exit 0
EOF
chmod +x "$work/bin/rpm"
run() { out="$(PATH="$work/bin:$PATH" bash "$SC" "$@" 2>&1)"; rc=$?; }

# A chroot root: .build.packages links to the rpmbuild tree.
C="$B/foo-leap-16.0-aarch64"
mkdir -p "$C/home/abuild/rpmbuild/RPMS/aarch64"
: > "$C/home/abuild/rpmbuild/RPMS/aarch64/libfoo1-1.0-0.aarch64.rpm"
ln -s home/abuild/rpmbuild "$C/.build.packages"
touch -d '3 minutes ago' "$C/home/abuild/rpmbuild/RPMS"
run
[ "$rc" = 0 ] && grep -qF "# auto-detected: $C/" <<<"$out" && grep -qF '# checked 1 package(s)' <<<"$out" \
  && pass "chroot root: its RPMs are found" \
  || { fail "chroot root: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

# A VM root: the build is in .mount; the chroot tree beside it is older work.
K="$B/bar-leap-16.0-aarch64"
mkdir -p "$K/.mount/.build.packages/RPMS/aarch64" "$K/home/abuild/rpmbuild/RPMS/aarch64"
: > "$K/img"
: > "$K/.build.log"     # as issue #71 found it
: > "$K/.mount/.build.packages/RPMS/aarch64/libbar2-2.0-0.aarch64.rpm"
: > "$K/home/abuild/rpmbuild/RPMS/aarch64/libstale1-1.0-0.aarch64.rpm"
ln -s home/abuild/rpmbuild "$K/.build.packages"
touch -d '2 minutes ago' "$K/.mount/.build.packages/RPMS"
touch -d '1 minute ago' "$K/home/abuild/rpmbuild/RPMS"
run
[ "$rc" = 0 ] && grep -qF "# auto-detected: $K/.mount/.build.packages/RPMS" <<<"$out" \
  && grep -qF '# checked 1 package(s)' <<<"$out" \
  && pass "kvm root: the RPMs of .mount/.build.packages, not the stale chroot tree" \
  || { fail "kvm root: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
run --build-root "$K"
[ "$rc" = 0 ] && grep -qF '# checked 1 package(s)' <<<"$out" \
  && pass "--build-root on a kvm root: only the RPMs the VM handed back" \
  || { fail "--build-root kvm root: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

# An oscrc build-device keeps the image out of the root: the log names .mount.
D="$B/baz-leap-16.0-aarch64"
mkdir -p "$D/.mount/.build.packages/RPMS/aarch64" "$D/home/abuild/rpmbuild/RPMS/aarch64"
printf '[    0s] Using BUILD_ROOT=%s/.mount\n' "$D" > "$D/.build.log"
: > "$D/.mount/.build.packages/RPMS/aarch64/libbaz3-3.0-0.aarch64.rpm"
: > "$D/home/abuild/rpmbuild/RPMS/aarch64/libstale1-1.0-0.aarch64.rpm"
ln -s home/abuild/rpmbuild "$D/.build.packages"
run --build-root "$D"
[ "$rc" = 0 ] && grep -qF '# checked 1 package(s)' <<<"$out" \
  && pass "--build-root on a build-device root: the build root its log names" \
  || { fail "--build-root build-device root: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
# Any other directory is searched whole.
run --build-root "$C/home/abuild/rpmbuild/RPMS"
[ "$rc" = 0 ] && grep -qF '# checked 1 package(s)' <<<"$out" \
  && pass "--build-root on an RPM directory: its RPMs" \
  || { fail "--build-root RPM directory: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

echo "---"; [ "$fails" = 0 ] && echo "all soname-check checks passed" || echo "$fails FAILED"
exit $((fails > 0))
