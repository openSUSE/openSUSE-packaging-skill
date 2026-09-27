#!/bin/bash
# test-gate.sh — gate.sh refuses a directory that is not a package checkout
# before any gate runs: source_validator there reported rc=0, a green piece of a
# verdict about nothing. Offline; TMPDIR keeps gate.sh's logs in the work dir.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../skills/opensuse-packaging/scripts/gate.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export TMPDIR="$work"

# case_ <name> <expected rc> <expected message> <dir>
case_() {
  local out got
  out="$(bash "$GATE" "$4" 2>&1)"; got=$?
  [ "$got" = "$2" ] && grep -qF -- "$3" <<<"$out" && pass "$1 (rc=$2)" || {
    fail "$1: expected rc=$2 and '$3', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
  LAST=$out
}

# A bad --entries is a usage error before any gate runs, not a red gate.
mkdir -p "$work/pkg0" && printf 'Name: p\n' > "$work/pkg0/p.spec"
for n in 0 x -1; do
  out="$(bash "$GATE" "$work/pkg0" --entries "$n" 2>&1)"; rc=$?
  [ "$rc" = 2 ] && grep -qF -- "--entries takes a positive integer" <<<"$out" && ! grep -q '^## ' <<<"$out" \
    && pass "--entries $n: usage error, no gate ran" || { fail "--entries $n: rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; }
done
mkdir -p "$work/project/.osc" && printf 'devel:example\n' > "$work/project/.osc/_project"
case_ project-checkout 2 "osc project checkout — cd into the package directory" "$work/project"
! grep -q '^## ' <<<"$LAST" && pass "project-checkout: no gate ran" || fail "project-checkout: gates ran: $LAST"
mkdir -p "$work/empty"
case_ empty-dir 2 "no *.spec and no .osc/_package" "$work/empty"
! grep -q '^## ' <<<"$LAST" && pass "empty-dir: no gate ran" || fail "empty-dir: gates ran: $LAST"
# Control: a spec is enough to get past the refusal; the gates then run (and
# are red here: no .changes, and not a checkout changes-patches can read).
mkdir -p "$work/pkg" && printf 'Name: p\n' > "$work/pkg/p.spec"
case_ spec-only 1 "VERDICT: RED" "$work/pkg"

# --entries N is "entries the submission adds vs the target": changes-patches
# counts them too. A git clone whose upstream holds one entry, two added.
SEP=-------------------------------------------------------------------
g() { git -c user.name=t -c user.email=t@example.com "$@"; }
mkdir -p "$work/seed" && printf 'Name: p\n' > "$work/seed/p.spec"
printf '%s\nMon Jan  5 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- initial package\n' "$SEP" > "$work/seed/p.changes"
{ g -C "$work/seed" init -q && g -C "$work/seed" add . && g -C "$work/seed" commit -qm base \
  && g clone -q "$work/seed" "$work/clone" \
  && { printf '%s\nTue Sep 15 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Fix the build\n\n' "$SEP"
       printf '%s\nMon Sep 14 10:00:00 UTC 2026 - Jane Packager <jane@example.com>\n\n- Update to 1.1\n\n' "$SEP"
       cat "$work/seed/p.changes"; } > "$work/clone/p.changes.new" \
  && mv "$work/clone/p.changes.new" "$work/clone/p.changes" && g -C "$work/clone" commit -qam two; } \
  || fail "could not build the git fixture"
case_ two-entries-default 1 "p.changes: 2 new entries vs" "$work/clone"
grep -qF "## changes-patches: rc=1" <<<"$LAST" && pass "two-entries-default: changes-patches is red" \
  || fail "two-entries-default: changes-patches not red: $LAST"
out="$(bash "$GATE" "$work/clone" --entries 2 2>&1)"
grep -qF "## changes-patches: rc=0" <<<"$out" && pass "two-entries --entries 2: changes-patches green" \
  || { fail "two-entries --entries 2: changes-patches not green"; printf '%s\n' "$out" | sed 's/^/    /'; }

# A non-link osc checkout of a devel project is a direct commit there: its new
# entries count against the committed copy, not against Factory, which the
# devel project may legitimately be several entries ahead of. An explicit
# --target still counts against that target. A fake osc serves Factory.
mkdir -p "$work/bin" "$work/factory"
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
case "$1" in
  api) [ "$2" = "/source/openSUSE:Factory/foo?expand=1" ] \
         && { echo '<directory name="foo"><entry name="foo.changes"/><entry name="foo.spec"/></directory>'; exit 0; } ;;
  cat) [ "$2 $3" = "openSUSE:Factory foo" ] && [ -f "$FACTORY/$4" ] && { cat "$FACTORY/$4"; exit 0; } ;;
  status) exit 0 ;;
esac
echo "Server returned an error: HTTP Error 404: Not Found" >&2; exit 1
EOF
chmod +x "$work/bin/osc"
entry() { printf '%s\n%s - Jane Packager <jane@example.com>\n\n- %s\n\n' "$SEP" "$1" "$2"; }
entry "Mon Jan  5 10:00:00 UTC 2026" "Initial package" > "$work/factory/foo.changes"
devel() { # <dir> <number of uncommitted entries>: devel two committed entries ahead of Factory
  mkdir -p "$1/.osc/sources" && printf 'foo\n' > "$1/.osc/_package" && printf 'devel:example\n' > "$1/.osc/_project"
  printf '<directory name="foo" rev="3"><entry name="foo.changes"/><entry name="foo.spec"/></directory>\n' > "$1/.osc/_files"
  printf 'Name: foo\nVersion: 1.3\n' | tee "$1/foo.spec" > "$1/.osc/sources/foo.spec"
  { entry "Wed Sep 16 10:00:00 UTC 2026" "Fix the man page"; entry "Tue Sep 15 10:00:00 UTC 2026" "Drop the obsolete Obsoletes"
    cat "$work/factory/foo.changes"; } > "$1/.osc/sources/foo.changes"
  { [ "$2" -ge 2 ] && entry "Fri Sep 18 10:00:00 UTC 2026" "Fix the build"
    entry "Thu Sep 17 10:00:00 UTC 2026" "Build with the system zlib"; cat "$1/.osc/sources/foo.changes"; } > "$1/foo.changes"
}
devel "$work/devel-one" 1; devel "$work/devel-two" 2
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-one" 2>&1)"
grep -qF "## changes-patches: rc=0" <<<"$out" && pass "non-link checkout, one new entry: changes-patches green" \
  || { fail "non-link checkout, one new entry: changes-patches not green"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-two" 2>&1)"
grep -qF "## changes-patches: rc=1" <<<"$out" && grep -qF "foo.changes: 2 new entries vs the committed copy" <<<"$out" \
  && pass "non-link checkout, two new entries: red, counted against the committed copy" \
  || { fail "non-link checkout, two new entries"; printf '%s\n' "$out" | sed 's/^/    /'; }
out="$(FACTORY="$work/factory" PATH="$work/bin:$PATH" bash "$GATE" "$work/devel-one" --target openSUSE:Factory 2>&1)"
grep -qF "foo.changes: 3 new entries vs openSUSE:Factory/foo" <<<"$out" \
  && pass "non-link checkout, explicit --target: counted against the target" \
  || { fail "non-link checkout, explicit --target"; printf '%s\n' "$out" | sed 's/^/    /'; }

echo "---"; [ "$fails" = 0 ] && echo "all gate checks passed" || echo "$fails FAILED"
exit $((fails > 0))
