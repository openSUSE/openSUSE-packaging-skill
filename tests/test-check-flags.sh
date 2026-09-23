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

U=$SK/references/script-usage.md; T=$SK/agents/triage.md
N=$(( $(wc -l < "$REPO/$T") + 1 ))   # the line a case appends to the playbook
case_ clean 0 "flag citations match --help" ":"
case_ undocumented-argparse-flag 1 "upstream-probe.py: synopsis lacks --foo" \
  "sed -i 's/^    ap.add_argument(\"--project\", default=\"openSUSE:Factory\")$/&\n    ap.add_argument(\"--foo\")/' $SK/scripts/upstream-probe.py && grep -q -- '\"--foo\"' $SK/scripts/upstream-probe.py"
case_ synopsis-flag-removed 1 "gate.sh: synopsis lacks --full" \
  "sed -i '/^- \`gate.sh/s/ \[--full\]//' $U && ! grep -q '^- \`gate.sh.*--full' $U"
case_ synopsis-flag-extra 1 "gate.sh: synopsis has --bogus, --help does not" \
  "sed -i '/^- \`gate.sh/s/ \[--full\]/ [--full] [--bogus]/' $U && grep -q '^- \`gate.sh.*--bogus' $U"
case_ synopsis-value-dropped 1 "gate.sh: --entries takes a value only in --help" \
  "sed -i '/^- \`gate.sh/s/\[--entries N\]/[--entries]/' $U && grep -q '^- \`gate.sh.*\[--entries\]' $U"
case_ synopsis-short-dropped 1 "factory-report.py: -o|--output only in --help" \
  "sed -i '/^- \`factory-report.py/s/\[-o|--output FILE\]/[--output FILE]/' $U && grep -q '^- \`factory-report.py.*\[--output FILE\]' $U"
case_ synopsis-duplicate 1 "second synopsis for gate.sh" \
  "sed -i '/^- \`gate.sh/p' $U && [ \"\$(grep -c '^- \`gate.sh' $U)\" = 2 ]"
case_ exit-code-changed 1 "leap-status.sh: exit codes [0, 1, 2, 3, 4, 6], --help says [0, 1, 2, 3, 4, 5]" \
  "sed -i '/^- \`leap-status.sh/s/· 5 network/· 6 network/' $U && grep -q '· 6 network' $U"
case_ help-declares-no-exit 1 "gpg-verify.sh --help declares no exit codes" \
  "sed -i '/^# Exit: 0 = good signature/,+1d' $SK/scripts/gpg-verify.sh && ! grep -q '^# Exit' $SK/scripts/gpg-verify.sh"
case_ help-exits-nonzero 1 "scripts/gpg-verify.sh:0: --help exits 1, want 0" \
  "sed -i 's/^\(  -h|--help) .*\)exit 0;;\$/\1exit 1;;/' $SK/scripts/gpg-verify.sh && grep -q -- '-h|--help).*exit 1;;' $SK/scripts/gpg-verify.sh"
case_ foreign-exemption-stale 1 "soname-check.sh: FOREIGN exempts --provides, --help no longer shows it" \
  "sed -i 's/(\`--provides\` gives/(the provides query gives/' $SK/scripts/soname-check.sh && ! bash $SK/scripts/soname-check.sh --help | grep -q -- --provides"
case_ undocumented-script 1 "no synopsis line for x.sh" \
  "printf '#!/bin/bash\n# Usage: x.sh\n# Exit: 0 = ok.\ncase \"\${1:-}\" in -h|--help) sed -n 2,3p \"\$0\"; exit 0;; esac\n' > $SK/scripts/x.sh && [ -s $SK/scripts/x.sh ]"
case_ synopsis-for-missing-script 1 "names ghost.sh, which is not a runnable script" \
  "echo '- \`ghost.sh\` — exit 0 ok' >> $U && grep -q ghost.sh $U"
case_ prose-cites-missing-flag 1 "gate.sh --help does not mention --nope" \
  "echo 'Then \`gate.sh --nope\`.' >> $T && grep -q -- --nope $T"
case_ doc-script-help 1 "$T:$N: tells the agent to run --help" \
  "echo 'Run \`gate.sh --help\` first.' >> $T && tail -1 $T | grep -q 'gate.sh --help'"
case_ doc-run-its-help 1 "$T:$N: tells the agent to run --help" \
  "echo 'Before calling a script, run its \`--help\`.' >> $T && tail -1 $T | grep -q 'run its'"
case_ doc-with-help 1 "$T:$N: tells the agent to run --help" \
  "echo 'Call a script with \`--help\` first.' >> $T && tail -1 $T | grep -q 'with \`--help'"
case_ doc-help-output 1 "$T:$N: tells the agent to run --help" \
  "echo \"Read the script's \\\`--help\\\` output.\" >> $T && tail -1 $T | grep -q 'help\` output'"
case_ doc-negated-help 0 "flag citations match --help" \
  "echo 'Do not ever run \`--help\`.' >> $T && tail -1 $T | grep -q 'not ever run'"
case_ doc-no-need-to 0 "flag citations match --help" \
  "echo 'No need to run \`--help\`.' >> $T && tail -1 $T | grep -q 'No need'"
case_ doc-described-check 0 "flag citations match --help" \
  "echo \"The file is checked against each script's \\\`--help\\\` output in CI.\" >> $T && tail -1 $T | grep -q 'checked against'"
case_ doc-foreign-command-help 0 "flag citations match --help" \
  "echo 'Run \`configure --help\` for its options.' >> $T && tail -1 $T | grep -q 'configure --help'"
case_ doc-script-short-help 1 "$T:$N: tells the agent to run --help" \
  "echo '\`gate.sh -h\` shows the flags.' >> $T && tail -1 $T | grep -q 'gate.sh -h'"
case_ doc-look-at-help 1 "$T:$N: tells the agent to run --help" \
  "echo \"Look at the helper's \\\`--help\\\`.\" >> $T && tail -1 $T | grep -q 'Look at'"
case_ prose-cites-missing-script 1 "cites scripts/nope.sh, which does not exist" \
  "echo 'See \`scripts/nope.sh\`.' >> $T && tail -1 $T | grep -q nope.sh"
case_ synopsis-value-extra 1 "gate.sh: --full takes a value only in the synopsis" \
  "sed -i '/^- \`gate.sh/s/\[--full\]/[--full MODE]/' $U && grep -q '^- \`gate.sh.*--full MODE' $U"
case_ synopsis-short-extra 1 "gate.sh: -f|--full only in the synopsis" \
  "sed -i '/^- \`gate.sh/s/\[--full\]/[-f|--full]/' $U && grep -q '^- \`gate.sh.*-f|--full' $U"
case_ usage-file-missing 1 "script-usage.md:0: missing; every runnable script needs a synopsis line" \
  "rm $U && [ ! -e $U ]"
case_ help-prints-nothing 1 "scripts/gpg-verify.sh:0: --help prints nothing" \
  "sed -i 's/^  -h|--help) .*exit 0;;\$/  -h|--help) exit 0;;/' $SK/scripts/gpg-verify.sh && grep -qx '  -h|--help) exit 0;;' $SK/scripts/gpg-verify.sh"
case_ help-unusable 1 "gpg-verify.sh has no usable --help" \
  "sed -i 's/^  -h|--help) .*exit 0;;\$/  -h|--help) exit 0;;/' $SK/scripts/gpg-verify.sh && grep -qx '  -h|--help) exit 0;;' $SK/scripts/gpg-verify.sh"

[ "$fails" -eq 0 ] && { echo "OK: check-flags.py catches every mutation"; exit 0; }
echo "$fails failure(s)"; exit 1
