#!/bin/bash
# quilt-prep.sh — regenerate the quilt build dir for a spec, optionally pushing to a patch.
usage() {
cat <<'U'
Usage: quilt-prep.sh [--force] [--to PATCH] <package>.spec

Runs `quilt setup -v` for the spec in the current directory. Replaces an existing
<name>-<version>-build/ only with --force (it may hold unrefreshed edits).
  --to PATCH   afterwards `quilt push` up to PATCH (basename, with or without .patch)
               and leave the tree there for hand edits.
Prints: BUILDDIR=<path> on stdout as the last line.
Exit: 0 ready; 1 build dir exists without --force; 2 setup/push failed or bad usage.
U
}
force=0; to=""
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0;;
    --force) force=1;;
    --to) to=$2; shift;;
    -*) usage >&2; exit 2;;
    *) spec=$1;;
  esac; shift
done
[ -n "${spec:-}" ] && [ -f "$spec" ] || { usage >&2; exit 2; }
command -v quilt >/dev/null || { echo "quilt not installed" >&2; exit 2; }

pkg=$(rpmspec -q --srpm --qf '%{name}-%{version}' "$spec" 2>/dev/null) || pkg=""
[ -n "$pkg" ] || pkg=$(sed -n 's/^Name:[[:space:]]*//p;s/^Version:[[:space:]]*//p' "$spec" | paste -sd- )
[ -n "$pkg" ] || { echo "cannot read name-version from $spec" >&2; exit 2; }
build="$pkg-build"
if [ -d "$build" ]; then
  if [ $force -eq 0 ]; then
    echo "$build exists (may hold unrefreshed edits). Re-run with --force to delete it." >&2
    exit 1
  fi
  rm -rf "$build"
fi

log=$(mktemp); trap 'rm -f "$log"' EXIT
quilt setup -v "$spec" >"$log" 2>&1
if ! ls -d "$build"/*/.pc >/dev/null 2>&1; then
  tail -5 "$log" >&2; echo "quilt setup failed" >&2; exit 2
fi
src=$(dirname "$(ls -d "$build"/*/.pc | head -1)")
if [ -n "$to" ]; then
  to=${to%.patch}.patch; to=${to#patches/}
  (cd "$src" && quilt push "patches/$to" 2>&1 | grep -E "FAILED|rej|Now at|fuzz|offset|can't find") || true
  (cd "$src" && [ "$(quilt top 2>/dev/null)" = "patches/$to" ]) || { echo "push to $to did not complete" >&2; exit 2; }
fi
echo "BUILDDIR=$PWD/$src"
