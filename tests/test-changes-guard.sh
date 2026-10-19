#!/bin/bash
# test-changes-guard.sh — changes-guard.sh keeps every committed .changes entry
# intact. `--amend-top` may rework only an unreleased top entry: it once passed
# with another packager's name on that packager's entry (sr#1385744).
# Adding a bug/CVE reference to an older entry passes only with a new entry on
# top. Offline: --released DIR or a fake osc stands in for openSUSE:Factory.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/../skills/opensuse-packaging/scripts/changes-guard.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
SEP=-------------------------------------------------------------------

# entry <date> <author> <body line>...
entry() { local d=$1 a=$2; shift 2; printf '%s\n%s - %s\n\n' "$SEP" "$d" "$a"; printf '%s\n' "$@"; echo; }
JANE='Jane Packager <jane@example.com>'
OTHER='Other Person <other@example.com>'
old1() { entry "Thu Apr 23 06:43:40 UTC 2026" "$OTHER" "- Update to version 2.2" \
  "  * cramfsck: reject dirent names containing path separators or" "    traversal components." \
  "- Drop patch:" "  * foo-obey-cflags.patch (upstreamed)"; }
old2() { entry "Tue Sep  1 20:47:26 UTC 2020" "$OTHER" "- Initial package, version 2.1"; }
new1() { entry "Sun Oct 18 06:00:44 UTC 2026" "$JANE" "- Reference CVE-2026-8274 (boo#1264703) fixed in 2.2"; }

# case_ <name> <expected rc> <expected message> <args>...
case_() {
  local name=$1 want=$2 msg=$3 out got; shift 3
  out="$(bash "$GUARD" "$@" 2>&1)"; got=$?
  [ "$got" = "$want" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$want)" || {
    fail "$name: expected rc=$want and '$msg', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}

# mk <name>: a package dir with .osc/_package, the baseline at base/foo.changes
mk() { mkdir -p "$work/$1/.osc" "$work/$1/base" && printf 'foo\n' > "$work/$1/.osc/_package"; }

mk ins; { old1; old2; } > "$work/ins/base/foo.changes"; { new1; old1; old2; } > "$work/ins/foo.changes"
case_ insertion-only 0 "insertion-only" --base "$work/ins/base/foo.changes" "$work/ins/foo.changes"

mk mid; { old1; old2; } > "$work/mid/base/foo.changes"
{ new1; old1 | sed 's/(upstreamed)/(upstreamed; drop leftover file)/'; old2; } > "$work/mid/foo.changes"
case_ old-entry-reworded 1 "not an exact suffix" --base "$work/mid/base/foo.changes" "$work/mid/foo.changes"

# --amend-top: the top entry must be the OBS user's (osc whois) and not yet in
# Factory (the --released dir, else osc cat). A fake osc answers both.
mkdir -p "$work/bin"
cat > "$work/bin/osc" <<'OSC'
#!/bin/bash
case "$1" in
  whois) [ "${WHOIS_MODE:-ok}" = ok ] || { echo "Server returned an error: HTTP Error 401" >&2; exit 1; }
         echo 'jpackager: "Jane Packager" <jane@example.com>' ;;
  cat) [ "$2 $3 $4" = "openSUSE:Factory foo foo.changes" ] || { echo "fake osc: unexpected $*" >&2; exit 9; }
       case "${OSC_MODE:-}" in
         404) echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1 ;;
         err) echo "Server returned an error: HTTP Error 503: Service Unavailable" >&2; exit 1 ;;
         ok) cat "$OSC_FILE" ;;
         *) echo "fake osc: cat without OSC_MODE" >&2; exit 9 ;;
       esac ;;
  *) echo "fake osc: unexpected $*" >&2; exit 9 ;;
esac
OSC
chmod +x "$work/bin/osc"
export PATH="$work/bin:$PATH"

mk own; mkdir -p "$work/own/factory"; old2 > "$work/own/factory/foo.changes"
{ entry "Sat Oct 17 10:00:00 UTC 2026" "$JANE" "- Update to 2.3"; old2; } > "$work/own/base/foo.changes"
{ entry "Sun Oct 18 10:00:00 UTC 2026" "$JANE" "- Update to 2.3" "- Fix the build"; old2; } > "$work/own/foo.changes"
case_ amend-own-unreleased 0 "the top entry is yours" --amend-top 'Jane Packager' \
  --released "$work/own/factory" --base "$work/own/base/foo.changes" "$work/own/foo.changes"

# sr#1385744: another packager's entry, committed to devel but not in Factory,
# "amended" under that packager's name
mk foreign; mkdir -p "$work/foreign/factory"; old2 > "$work/foreign/factory/foo.changes"
{ old1; old2; } > "$work/foreign/base/foo.changes"
{ old1 | sed 's/^- Drop patch:$/- Spec cleanup: drop the Group tag\n- Drop patch:/'; old2; } > "$work/foreign/foo.changes"
case_ amend-foreign 1 "the top entry is not yours" --amend-top "$OTHER" \
  --released "$work/foreign/factory" --base "$work/foreign/base/foo.changes" "$work/foreign/foo.changes"
WHOIS_MODE=fail case_ amend-whois-fails 3 "cannot tell whether the top entry is yours" --amend-top "$OTHER" \
  --released "$work/foreign/factory" --base "$work/foreign/base/foo.changes" "$work/foreign/foo.changes"

mk ownrel; mkdir -p "$work/ownrel/factory"
{ entry "Sat Oct 17 10:00:00 UTC 2026" "$JANE" "- Update to 2.3"; old2; } | tee "$work/ownrel/factory/foo.changes" > "$work/ownrel/base/foo.changes"
{ entry "Sun Oct 18 10:00:00 UTC 2026" "$JANE" "- Update to 2.3" "- Fix the build"; old2; } > "$work/ownrel/foo.changes"
case_ amend-own-released 1 "already in openSUSE:Factory" --amend-top 'Jane Packager' \
  --released "$work/ownrel/factory" --base "$work/ownrel/base/foo.changes" "$work/ownrel/foo.changes"

# no --released: Factory is asked through osc for the package in .osc/_package
OSC_MODE=404 case_ amend-new-package 0 "the top entry is yours" --amend-top 'Jane Packager' \
  --base "$work/own/base/foo.changes" "$work/own/foo.changes"
OSC_MODE=ok OSC_FILE="$work/ownrel/factory/foo.changes" case_ amend-released-via-osc 1 "already in openSUSE:Factory" \
  --amend-top 'Jane Packager' --base "$work/ownrel/base/foo.changes" "$work/ownrel/foo.changes"
OSC_MODE=err case_ amend-factory-unreadable 3 "cannot tell whether openSUSE:Factory" --amend-top 'Jane Packager' \
  --base "$work/own/base/foo.changes" "$work/own/foo.changes"
mkdir -p "$work/nopkg"; cp "$work/own/foo.changes" "$work/nopkg/"
case_ amend-no-package-name 3 "cannot tell whether openSUSE:Factory" --amend-top 'Jane Packager' \
  --base "$work/own/base/foo.changes" "$work/nopkg/foo.changes"

# a bug/CVE reference added to an older entry: allowed with a new entry on top
withref() { old1 | sed 's/traversal components\.$/traversal components (CVE-2026-8274, boo#1264703)./'; }
mk ref; { old1; old2; } > "$work/ref/base/foo.changes"; { new1; withref; old2; } > "$work/ref/foo.changes"
case_ ref-with-new-entry 0 "only by added bug/CVE references" --base "$work/ref/base/foo.changes" "$work/ref/foo.changes"

mk refonly; { old1; old2; } > "$work/refonly/base/foo.changes"; { withref; old2; } > "$work/refonly/foo.changes"
case_ ref-without-new-entry 1 "also prepend a new entry" --base "$work/refonly/base/foo.changes" "$work/refonly/foo.changes"

mk refword; { old1; old2; } > "$work/refword/base/foo.changes"
{ new1; withref | sed 's/reject dirent/refuse dirent/'; old2; } > "$work/refword/foo.changes"
case_ ref-plus-reword 1 "not an exact suffix" --base "$work/refword/base/foo.changes" "$work/refword/foo.changes"

mk rewrap; { old1; old2; } > "$work/rewrap/base/foo.changes"
{ new1; old1 | awk '/separators or$/ { print "  * cramfsck: reject dirent names containing path separators or traversal"; next }
  /^    traversal components\.$/ { print "    components (bsc#1264703)."; next } { print }'; old2; } > "$work/rewrap/foo.changes"
case_ ref-rewrapped 0 "only by added bug/CVE references" --base "$work/rewrap/base/foo.changes" "$work/rewrap/foo.changes"

mk reflow; { old1; old2; } > "$work/reflow/base/foo.changes"
{ new1; old1 | sed 's/^  \* cramfsck/    * cramfsck/'; old2; } > "$work/reflow/foo.changes"
case_ old-entry-reindented 1 "not an exact suffix" --base "$work/reflow/base/foo.changes" "$work/reflow/foo.changes"

# --squash-mine: the run of your own unreleased entries on top folds into ONE
# new entry; every entry below it stays byte-identical (swift-lang: the first
# attempt rewrote the whole file, the second stacked a 20th entry).
mine() { entry "$1" "$JANE" "$2"; }
run3() { mine "Sun Oct 18 21:42:19 UTC 2026" "- Fix the aarch64 rpmlint gate"
  mine "Sun Oct 18 17:21:04 UTC 2026" "- Strip the installed tree"
  mine "Sat Oct 17 08:00:00 UTC 2026" "- Update to 2.3"; }
one() { mine "Mon Oct 19 10:12:43 UTC 2026" "- Update to 2.3: build fixes for aarch64 and rpmlint"; }
mk squash; mkdir -p "$work/squash/factory"; { old1; old2; } > "$work/squash/factory/foo.changes"
{ run3; old1; old2; } > "$work/squash/base/foo.changes"; { one; old1; old2; } > "$work/squash/foo.changes"
case_ squash-own-run 0 "3 of your unreleased entries folded into one" --squash-mine 'Jane Packager' \
  --released "$work/squash/factory" --base "$work/squash/base/foo.changes" "$work/squash/foo.changes"
mk squashpart; { run3; old1; old2; } > "$work/squashpart/base/foo.changes"
{ one; mine "Sat Oct 17 08:00:00 UTC 2026" "- Update to 2.3"; old1; old2; } > "$work/squashpart/foo.changes"
case_ squash-part-of-run 0 "2 of your unreleased entries folded into one" --squash-mine 'Jane Packager' \
  --released "$work/squash/factory" --base "$work/squashpart/base/foo.changes" "$work/squashpart/foo.changes"
mk squashforeign; { run3; old1; old2; } > "$work/squashforeign/base/foo.changes"; { one; old2; } > "$work/squashforeign/foo.changes"
case_ squash-eats-foreign 1 "is not yours" --squash-mine 'Jane Packager' \
  --released "$work/squash/factory" --base "$work/squashforeign/base/foo.changes" "$work/squashforeign/foo.changes"
mk squashrel; mkdir -p "$work/squashrel/factory"
{ mine "Sat Oct 17 08:00:00 UTC 2026" "- Update to 2.3"; old1; old2; } > "$work/squashrel/factory/foo.changes"
{ run3; old1; old2; } > "$work/squashrel/base/foo.changes"; { one; old1; old2; } > "$work/squashrel/foo.changes"
case_ squash-eats-released 1 "already in openSUSE:Factory" --squash-mine 'Jane Packager' \
  --released "$work/squashrel/factory" --base "$work/squashrel/base/foo.changes" "$work/squashrel/foo.changes"
mk squashedit; { run3; old1; old2; } > "$work/squashedit/base/foo.changes"
{ one; old1 | sed 's/(upstreamed)/(upstream)/'; old2; } > "$work/squashedit/foo.changes"
case_ squash-touches-older 1 "not an exact suffix" --squash-mine 'Jane Packager' \
  --released "$work/squash/factory" --base "$work/squashedit/base/foo.changes" "$work/squashedit/foo.changes"
mk squashother; { run3; old1; old2; } > "$work/squashother/base/foo.changes"
{ entry "Mon Oct 19 10:12:43 UTC 2026" "$OTHER" "- Update to 2.3"; old1; old2; } > "$work/squashother/foo.changes"
case_ squash-new-entry-not-yours 1 "not an exact suffix" --squash-mine 'Jane Packager' \
  --released "$work/squash/factory" --base "$work/squashother/base/foo.changes" "$work/squashother/foo.changes"

echo "---"; [ "$fails" = 0 ] && echo "all changes-guard checks passed" || echo "$fails FAILED"
exit $((fails > 0))
