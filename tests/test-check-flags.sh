#!/bin/bash
# test-check-flags.sh — proves tests/repo/check-flags.py goes red on each defect
# it exists to catch: every case copies the repo's skill tree to a scratch dir
# under $TMPDIR, applies one mutation, and expects exit 1 plus the finding that
# names it. The unmutated copy must exit 0. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
SK=skills/opensuse-packaging
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# case <name> <expected rc> <expected message> <mutation (shell, run in the copy)>
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got
  mkdir -p "$dir/tests"
  cp -a "$REPO/skills" "$REPO/AGENTS.md" "$dir/" && cp -a "$REPO/tests/repo" "$dir/tests/"
  (cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  out="$(python3 "$dir/tests/repo/check-flags.py" 2>&1)"; got=$?
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"
    printf '%s\n' "$out" | sed 's/^/    /'
  }
}

case_ clean 0 "flag citations match --help" ":"
case_ undocumented-argparse-flag 1 "upstream-probe.py: synopsis lacks --foo" \
  "sed -i 's/^    ap.add_argument(\"--project\", default=\"openSUSE:Factory\")$/&\n    ap.add_argument(\"--foo\")/' $SK/scripts/upstream-probe.py && grep -q -- '\"--foo\"' $SK/scripts/upstream-probe.py"
case_ synopsis-flag-removed 1 "gate.sh: synopsis lacks --full" \
  "sed -i '/^- \`gate.sh/s/ \[--full\]//' $SK/references/script-usage.md && ! grep -q '^- \`gate.sh.*--full' $SK/references/script-usage.md"
case_ exit-code-changed 1 "leap-status.sh: exit codes [0, 1, 2, 3, 4], --help says [0, 1, 2, 3, 5]" \
  "sed -i '/^- \`leap-status.sh/s/· 5 network/· 4 network/' $SK/references/script-usage.md && grep -q '· 4 network' $SK/references/script-usage.md"
case_ undocumented-script 1 "no synopsis line for x.sh" \
  "printf '#!/bin/bash\n# Usage: x.sh\n# Exit: 0 = ok.\ncase \"\${1:-}\" in -h|--help) sed -n 2,3p \"\$0\"; exit 0;; esac\n' > $SK/scripts/x.sh"
case_ synopsis-for-missing-script 1 "names ghost.sh, which is not a runnable script" \
  "echo '- \`ghost.sh\` — exit 0 ok' >> $SK/references/script-usage.md"
case_ doc-says-run-help 1 "tells the agent to run --help" \
  "echo 'Run \`gate.sh --help\` first.' >> $SK/agents/triage.md"

[ "$fails" -eq 0 ] && { echo "OK: check-flags.py catches every mutation"; exit 0; }
echo "$fails failure(s)"; exit 1
