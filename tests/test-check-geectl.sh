#!/bin/bash
# test-check-geectl.sh — proves tests/repo/check-geectl.py goes red on each defect it
# exists to catch: every case copies the skill tree to a scratch dir, applies one
# mutation, and expects the exit code plus the finding that names it. Each
# negative case trips exactly one branch. Needs a geectl binary: GEectl_BIN, or
# geectl on PATH (CI builds it from a pinned source commit).
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
SK=skills/opensuse-packaging
GE="${GEectl_BIN:-geectl}"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# case_ <name> <expected rc> <expected message> <mutation> [python flags]
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 py=${5:-"--geectl $GE"} dir="$work/$1" out got
  mkdir -p "$dir/tests"
  cp -a "$REPO/skills" "$dir/" && cp -a "$REPO/tests/repo" "$dir/tests/"
  (cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  # shellcheck disable=SC2086  # $py is one --geectl flag or one override
  out="$(python3 "$dir/tests/repo/check-geectl.py" $py 2>&1)"; got=$?
  # A negative case must trip exactly one branch, or it proves neither.
  if [ "$rc" = 1 ] && ! grep -qx "1 finding(s)" <<<"$out"; then
    fail "$name: expected exactly one finding"; printf '%s\n' "$out" | sed 's/^/    /'; return
  fi
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"
    printf '%s\n' "$out" | sed 's/^/    /'
  }
}

U=$SK/references/geectl-usage.md; T=$SK/agents/triage.md; M=tests/repo/geectl-target-state.json
# shellcheck disable=SC2317,SC2329  # called from the mutations, through eval
add() { printf '%s\n' "$1" >> "$T" && grep -qF -- "$1" "$T"; }
# shellcheck disable=SC2317,SC2329  # called from the mutations, through eval
del_line() { python3 - "$1" "$2" <<'PY'
import sys
path, prefix = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines()
kept = [ln for ln in lines if not ln.startswith(prefix)]
assert len(kept) < len(lines), f"no line starting {prefix!r}"
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(kept) + "\n")
PY
}
# shellcheck disable=SC2317,SC2329  # called from the mutations, through eval
insert_wrong_form() { python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
old = "## Lookup\n"
new = old + "\n- `geectl local-build service-run --mode runall .` — wrong here\n"
assert old in text
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text.replace(old, new, 1))
PY
}
# shellcheck disable=SC2317,SC2329  # called from the mutations, through eval
insert_prose_typo() { python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines()
for i, ln in enumerate(lines):
    if ln.startswith("- `geectl build results"):
        lines.insert(i + 1, "- `geectl build results PRJ --package PKG` — remote status; `--bogus` scopes it.")
        break
else:
    raise SystemExit("no build results line")
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
PY
}
# shellcheck disable=SC2317,SC2329  # called from the mutations, through eval
manifest_add() { python3 - "$M" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["leaves"]["remote cat"] = {"issue": 999, "flags": ["--rev"]}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
}
# shellcheck disable=SC2317,SC2329  # called from the mutations, through eval
manifest_add_flag() { python3 - "$M" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["flags"]["build job-history"] = {"--limit": {"issue": 999, "kind": "issue"}}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
}

case_ clean 0 "geectl citations match geectl" ":"
case_ unknown-subcommand 1 "\`geectl frobnicate\`: no such geectl command" \
  "add 'Run \`geectl frobnicate PRJ\`.'"
case_ unknown-flag 1 "geectl build results has no option --nope" \
  "add 'Run \`geectl build results --nope PRJ\`.'"
case_ fenced-citation 1 "geectl build results has no option --nope2" \
  "printf '\`\`\`\ngeectl build results --nope2 PRJ\n\`\`\`\n' >> $T && grep -q -- --nope2 $T"
case_ target-state-leaf 0 "geectl citations match geectl" \
  "add 'Run \`geectl checkout PRJ PKG\`.'"
case_ target-state-flag 0 "geectl citations match geectl" \
  "add 'Run \`geectl request search --since 2026-01-01 --state new\`.'"
case_ target-state-flag-unknown 1 "target-state leaf (issue #17) has no flag --bogus" \
  "add 'Run \`geectl checkout --bogus PRJ PKG\`.'"
case_ stale-manifest-leaf 1 "target-state leaf \`remote cat\` (issue #999) now exists in geectl" \
  "manifest_add $M"
case_ stale-manifest-flag 1 "target-state flag \`--limit\` on \`build job-history\` (issue #999) now exists in geectl" \
  "manifest_add_flag $M"
case_ service-run-runall 1 "no such mode; name the service and its mode, never runall" \
  "add 'Run \`geectl local-build service-run --mode runall .\`.'"
case_ runall-negated 0 "geectl citations match geectl" \
  "add 'Never \`geectl local-build service-run --mode runall .\`.'"
case_ no-synopsis 1 "\`geectl remote whois\` has no synopsis line" \
  "del_line $U '- \`geectl remote whois' && add 'Run \`geectl remote whois LOGIN\`.'"
case_ usage-file-missing 1 "missing; the skill cites geectl commands" \
  "rm $U && [ ! -e $U ]"
case_ global-opts-prefix 1 "geectl build results has no option --nope" \
  "add 'Run \`geectl --format text build results --nope PRJ\`.'"
case_ substitution-hides-nothing 1 "geectl request file has no option --bogus" \
  "add 'Run \`geectl request file A B --description \"\$(cat f)\" --bogus\`.'"
case_ substitution-lends-nothing 0 "geectl citations match geectl" \
  "add 'Run \`geectl request file A B --description \"\$(sed -n 1p -Z f)\"\`.'"
case_ negation-is-per-occurrence 1 "no such mode" \
  "add 'Never \`geectl local-build service-run --mode runall .\` there, but do run \`geectl local-build service-run --mode runall .\` here.'"
case_ wrong-form-outside-section 1 "no such mode" \
  "insert_wrong_form $U"
case_ wrong-bullet-is-no-synopsis 1 "\`geectl checkout\` has no synopsis line" \
  "del_line $U '- \`geectl checkout PRJ PKG --live\`'"
case_ prose-flag-typo 1 "prose cites --bogus, which no cited \`geectl\` command accepts" \
  "insert_prose_typo $U"
case_ prose-flag-no-command 0 "geectl citations match geectl" \
  "add 'Note: \`--live\` performs a mutation.'"
case_ geectl-missing 2 "cannot run geectl" ":" "--geectl /nonexistent"

[ $fails -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
