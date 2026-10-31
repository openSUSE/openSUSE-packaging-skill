#!/bin/bash
# Audit the shared libraries in built RPMs for the cross-version file-conflict
# trap: a versioned symlink whose name is NOT the SONAME.
#
# THE BUG THIS CATCHES. The normal, correct layout is a real file carrying the
# full version and a symlink named exactly after the SONAME:
#     libfoo.so.1.2.3          (real)
#     libfoo.so.1 -> ...       (symlink, == SONAME)  OK
# Nothing else belongs in a runtime library package. When upstream ALSO installs
# a shorter or longer link that is not the SONAME, a `%files` glob like
# `%{_libdir}/libfoo.so.*` sweeps it in, and then:
#   * nothing ever links against it (rpm only Provides the real SONAME), so it
#     buys nothing, AND
#   * its path does not change between releases, so two consecutive
#     lib<name><version> packages both own it and CONFLICT on install.
# A local build never shows this — it needs two versions present at once, which
# first happens in the target project's staging. Cost: a reviewer decline late,
# after the submission looked green.
# Real case: mupdf shipped libmupdf.so.28 beside SONAME libmupdf.so.28.1;
# libmupdf28_0 and libmupdf28_1 then conflicted on /usr/lib64/libmupdf.so.28.
#
# Also reports, as advisories:
#   * a runtime package shipping a bare unversioned lib*.so (belongs in -devel)
#   * a package name that does not encode its SONAME version (shlib policy)
#
# Reads only rpm metadata (`--provides` gives the SONAME rpm actually recorded,
# `-qplv` gives the symlinks) — no extraction, no objdump, no root.
#
#   exit 0  clean
#   exit 3  findings (conflict-hazard symlink, or a devel-only file in runtime)
#   exit 2  usage error / no RPMs found
#
# Usage: soname-check.sh <file.rpm> [file.rpm ...]
#        soname-check.sh --build-root <dir>   # audit that root's built RPMs
#        soname-check.sh                      # the newest root under oscrc's build-root
# A root's built RPMs: .build.packages/RPMS of the build root its log names
# (<root>/.mount for build-type=kvm), else of <root>/.mount beside <root>/img,
# else of <root>; a --build-root dir that is no build root is searched whole.
set -uo pipefail

usage() { awk 'NR>1 { if (!/^#/) exit; print }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0;; esac

# A VM build's --clean wipes only .mount, so a chroot tree in the root is stale,
# and an oscrc build-device leaves no img in the root: the log knows.
rpmdir_of() {
  local b
  b=$(sed -n '/Using BUILD_ROOT=/{s/.*Using BUILD_ROOT=//p;q;}' "$1/.build.log" 2>/dev/null)
  if [ -n "$b" ]; then echo "$b/.build.packages/RPMS"
  elif [ -e "$1/img" ] && [ -d "$1/.mount" ]; then echo "$1/.mount/.build.packages/RPMS"
  else echo "$1/.build.packages/RPMS"; fi
}

rpms=()
if [ "${1:-}" = "--build-root" ]; then
  [ -n "${2:-}" ] || { usage; exit 2; }
  dir=${2%/}
  if [ -e "$dir/.build.log" ] || [ -e "$dir/.build.packages" ] || [ -e "$dir/img" ]; then
    dir=$(rpmdir_of "$dir")
  fi
  mapfile -t rpms < <(find "$dir" -name '*.rpm' ! -name '*debuginfo*' \
                      ! -name '*debugsource*' ! -name '*.src.rpm' 2>/dev/null)
elif [ $# -gt 0 ]; then
  rpms=("$@")
else
  # The build-root base from oscrc, as build-summary.sh reads it.
  base=$(grep -hE '^\s*build-root\s*=' ~/.config/osc/oscrc ~/.oscrc 2>/dev/null \
         | tail -1 | sed -E 's/^[^=]*=\s*//; s/\s+$//')
  : "${base:=/var/tmp/build-root/%(repo)s-%(arch)s}"
  # strip trailing path components that are templated (%(package)s etc.)
  while case "$base" in */*) [[ "${base##*/}" == *'%('* ]];; *) false;; esac; do base=${base%/*}; done
  : "${base:=/var/tmp/build-root}"
  newest() {
    local r d
    for r in "$@"; do
      d=$(rpmdir_of "${r%/}")
      [ -d "$d" ] && printf '%s\n' "$d"
    done | xargs -r -d '\n' ls -dt 2>/dev/null | head -1
  }
  root="$(newest "$base"/*/)"
  [ -n "$root" ] || root="$(newest "$base")"
  [ -n "$root" ] || { echo "no build root found; pass RPMs explicitly" >&2; exit 2; }
  mapfile -t rpms < <(find "$root" -name '*.rpm' ! -name '*debuginfo*' \
                      ! -name '*debugsource*' 2>/dev/null)
  echo "# auto-detected: $root"
fi

[ ${#rpms[@]} -gt 0 ] || { echo "no RPMs to check" >&2; exit 2; }

findings=0
checked=0
for r in "${rpms[@]}"; do
  [ -r "$r" ] || { echo "SKIP (unreadable): $r" >&2; continue; }
  name="$(rpm -qp --qf '%{NAME}' "$r" 2>/dev/null)" || continue

  # SONAMEs exactly as rpm recorded them, e.g. "libfoo.so.1()(64bit)" -> libfoo.so.1
  mapfile -t sonames < <(rpm -qp --provides "$r" 2>/dev/null \
      | sed -n 's/^\(lib[^ ]*\.so[^ (]*\)(.*)\?.*$/\1/p' | sort -u)
  # some 32-bit/noarch provides have no () suffix at all
  mapfile -t -O "${#sonames[@]}" sonames < <(rpm -qp --provides "$r" 2>/dev/null \
      | awk '/^lib.*\.so($|\.)/ && $0 !~ /\(/ {print $1}' | sort -u)
  mapfile -t sonames < <(printf '%s\n' "${sonames[@]}" | grep -v '^$' | sort -u)

  # shipped symlinks and their targets, from the metadata
  while read -r perms _ _ _ _ _ _ _ path arrow target; do
    case "$perms" in l*) ;; *) continue;; esac
    base="${path##*/}"
    case "$base" in lib*.so.*) ;; *) continue;; esac
    [ "$arrow" = "->" ] || continue
    hit=0
    for s in "${sonames[@]}"; do [ "$base" = "$s" ] && hit=1 && break; done
    if [ $hit -eq 0 ]; then
      echo "CONFLICT-HAZARD  $name: $path -> $target"
      echo "    not the SONAME (${sonames[*]:-none recorded}); nothing links against it, and"
      echo "    its path is version-independent -- the next release's package will"
      echo "    own the same path and conflict. Drop it in %install."
      findings=$((findings+1))
    fi
  done < <(rpm -qplv "$r" 2>/dev/null)

  # a runtime package should not carry the unversioned devel symlink
  case "$name" in
    *-devel|*-devel-*) ;;
    *)
      if rpm -qplv "$r" 2>/dev/null | awk '{print $9}' | grep -qx '.*/lib[^/]*\.so'; then
        echo "DEVEL-IN-RUNTIME  $name ships a bare lib*.so (unversioned) -- belongs in -devel"
        findings=$((findings+1))
      fi
      ;;
  esac

  # advisory only: does the package name encode the SONAME version?
  if [ ${#sonames[@]} -gt 0 ]; then
    case "$name" in
      lib*)
        ver="${sonames[0]##*.so.}"
        squashed="${ver//./_}"
        if [ -n "$ver" ] && [[ "$name" != *"$squashed"* ]] && [[ "$name" != *"$ver"* ]]; then
          echo "ADVISORY  $name does not encode SONAME version '$ver' (shlib policy)"
        fi
        ;;
    esac
  fi
  checked=$((checked+1))
done

echo "# checked $checked package(s); $findings finding(s)"
# "0 checked" must never read as a pass -- silence would look like success
if [ $checked -eq 0 ]; then
  echo "nothing could be checked (unreadable or non-RPM inputs)" >&2
  exit 2
fi
[ $findings -eq 0 ] || exit 3
exit 0
