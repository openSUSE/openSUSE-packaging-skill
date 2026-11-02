#!/bin/bash
# test-changes-range.sh — changes-range.py lists the upstream releases strictly
# between the target's Version and the checkout's, and reports the ones the new
# .changes entry never names, and the versions it describes that the target's
# .changes already documents. Four reviews BLOCKed on the first (graphifyy
# 0.9.98, artcraft 0.10.0/0.11.0, zeroclaw 0.8.6, zpaqfranz 65.13-65.15), one
# re-review on the second. Offline: the forge answers come from
# tests/fixtures/changes-range/ (trimmed real responses, names replaced; npm,
# crates.io, GitLab and github-releases-e.json are made up in the same shape).
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CR="$HERE/../skills/opensuse-packaging/scripts/changes-range.py"
FIX="$HERE/fixtures/changes-range"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# Every URL the script opens is answered from CR_MAP: [substring, fixture file
# | "[]" | HTTP status | 0 for a refused connection]; anything else is a 404.
# gh is "not logged in", so GitHub goes through urlopen too; osc must not run.
mkdir -p "$work/stub"
cat > "$work/stub/sitecustomize.py" <<'PY'
import io, json, os, subprocess, urllib.error, urllib.request
MAP = json.load(open(os.environ["CR_MAP"])) if os.environ.get("CR_MAP") else []
class _R(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False
_real_run = subprocess.run
def _run(cmd, *a, **k):
    if cmd and cmd[0] == "gh":
        return subprocess.CompletedProcess(cmd, 1, "", "not logged in")
    if cmd and cmd[0] == "osc":
        return subprocess.CompletedProcess(cmd, 1, "", "osc must not run in this suite")
    return _real_run(cmd, *a, **k)
subprocess.run = _run
def _urlopen(req, *a, **k):
    url = getattr(req, "full_url", req)
    with open(os.environ["CR_LOG"], "a") as fh:
        fh.write(url + "\n")
    for sub, what in MAP:
        if sub in url:
            if what == 0:
                raise urllib.error.URLError(ConnectionRefusedError(111, "refused"))
            if isinstance(what, int):
                raise urllib.error.HTTPError(url, what, "stub", None, None)
            if what == "[]":
                return _R(b"[]")
            return _R(open(os.path.join(os.environ["CR_FIX"], what), "rb").read())
    raise urllib.error.HTTPError(url, 404, "not in the stub map", None, None)
urllib.request.urlopen = _urlopen
PY

GH='https://github.com/someone/thing'
spec() {  # spec <dir> <version> [Source0] [URL]
  mkdir -p "$1"
  printf 'Name:           thing\nVersion:        %s\nRelease:        0\nURL:            %s\nSource0:        %s\n' \
    "$2" "${4:-$GH}" "${3:-$GH/archive/refs/tags/v%{version\}.tar.gz}" > "$1/thing.spec"
}
# entry <text> — one .changes entry, led by the blank lines that part it from the
# one before (a command substitution keeps leading newlines, not trailing ones)
# one, with a time of day of its own: no two real entries share a header line
entry() {
  local n; n=$(printf '%s' "$1" | cksum); n=${n%% *}
  printf '\n\n%s\nMon Nov  2 %02d:%02d:%02d UTC 2026 - Packager <packager@example.org>\n\n%s' \
    '-------------------------------------------------------------------' $((n % 24)) $((n / 24 % 60)) $((n / 1440 % 60)) "$1"
}
# pkg <name> <old version> <new version> <old entries> <new entries> [Source0] [URL]
pkg() {
  local d="$work/$1"; rm -rf "$d"
  spec "$d/base" "$2" "${6:-}" "${7:-}"; spec "$d/co" "$3" "${6:-}" "${7:-}"
  printf '%s\n' "${4#$'\n\n'}" > "$d/base/thing.changes"
  printf '%s\n\n%s\n' "${5#$'\n\n'}" "${4#$'\n\n'}" > "$d/co/thing.changes"
  echo "$d"
}
# run <name> <expected rc> <expected text> <map json> <dir> [args] — LAST holds the output
run() {
  local name=$1 want=$2 text=$3 map=$4 d=$5; shift 5
  local rc
  printf '%s' "$map" > "$work/map.json"; : > "$work/urls.log"
  LAST="$(PYTHONPATH="$work/stub" CR_MAP="$work/map.json" CR_FIX="$FIX" CR_LOG="$work/urls.log" \
    python3 "$CR" "$d/co" --base "$d/base" "$@" 2>&1)"; rc=$?
  [ "$rc" = "$want" ] && grep -qF -- "$text" <<<"$LAST" && pass "$name (rc=$want)" || {
    fail "$name: expected rc=$want and '$text', got rc=$rc"; printf '%s\n' "$LAST" | sed 's/^/    /'; }
}
has() { grep -qF -- "$2" <<<"$LAST" && pass "$1" || { fail "$1: no '$2' in"; printf '%s\n' "$LAST" | sed 's/^/    /'; }; }
hasnt() { ! grep -qF -- "$2" <<<"$LAST" && pass "$1" || { fail "$1: '$2' in"; printf '%s\n' "$LAST" | sed 's/^/    /'; }; }

out="$(python3 "$CR" --help 2>&1)"; rc=$?
[ $rc = 0 ] && grep -q '^Exit:' <<<"$out" && pass "--help names its exit codes" || fail "--help: rc=$rc"
out="$(python3 "$CR" --bogus 2>&1)"; rc=$?
[ $rc = 2 ] && grep -qF "unrecognized arguments: --bogus" <<<"$out" && pass "unknown option (rc=2)" || fail "unknown option: rc=$rc $out"

A='[["/repos/someone/thing/releases", "github-releases-a.json"], ["/repos/someone/thing/tags", "[]"]]'
OLD97=$(entry '- Update to version 0.9.97:
  * Faster graph build')

# graphifyy: 0.9.97 -> 0.9.99 crosses 0.9.98, and the entry covers 0.9.99 only.
d=$(pkg graphify 0.9.97 0.9.99 "$OLD97" "$(entry '- Update to version 0.9.99:
  * serve: new --port flag')")
run "skipped release" 1 "MISSING: 0.9.98 (2026-10-30)" "$A" "$d"
hasnt "the old and new versions are not in the range" "MISSING: 0.9.97"
has "one verdict line" "VERDICT: 1 finding(s)"
d=$(pkg graphify 0.9.97 0.9.99 "$OLD97" "$(entry '- Update to version 0.9.99:
  * serve: new --port flag
- Update to version 0.9.98:
  * Path filters')")
run "every crossed release named" 0 "VERDICT: CLEAN" "$A" "$d"
# A mention is enough: v-prefixed, inside a sentence.
d=$(pkg graphify 0.9.97 0.9.100 "$OLD97" "$(entry '- Update to version 0.9.100 (includes v0.9.98 and v0.9.99):
  * Many fixes')")
run "named in a sentence, v-prefixed" 0 "VERDICT: CLEAN" "$A" "$d"
# 0.9.98 is not inside 10.9.98, 0.9.981, baz0.9.98 or 0.9.98rc1, nor is it 0.9.9.
d=$(pkg graphify 0.9.97 0.9.99 "$OLD97" "$(entry '- Update to version 0.9.99 (needs foo 10.9.98, bar 0.9.981,
  baz0.9.98, 0.9.98rc1 and 0.9.9):')")
run "a longer number is no mention" 1 "MISSING: 0.9.98" "$A" "$d"

# bugwarden: 0.6.0 -> 0.7.0 with nothing between is clean.
d=$(pkg bw 0.9.99 0.9.100 "$(entry '- Update to version 0.9.99:')" "$(entry '- Update to version 0.9.100:
  * Fix')")
run "no release between" 0 "VERDICT: CLEAN" "$A" "$d"
has "says there is none" "no upstream release between 0.9.99 and 0.9.100"

# zeroclaw: 0.8.5 -> 0.8.7 skips 0.8.6; the 0.8.0 betas are not in any range.
D='[["/repos/someone/thing/releases", "github-releases-d.json"], ["/repos/someone/thing/tags", "[]"]]'
d=$(pkg zc 0.8.5 0.8.7 "$(entry '- Update to version 0.8.5:')" "$(entry '- Update to version 0.8.7:
  * Fixes')")
run "zeroclaw: entry skips v0.8.6" 1 "MISSING: 0.8.6" "$D" "$d"
# The blocked zeroclaw entry did say 0.8.6, inside a bullet about something else:
# only a version heading (or the Update line) names a release.
d=$(pkg zc 0.8.5 0.8.7 "$(entry '- Update to version 0.8.5:')" "$(entry '- Update to version 0.8.7:
  * Daemon accepts a group-writable data directory again
    (stop a running 0.8.6 daemon before upgrading)')")
run "zeroclaw: a mention in a bullet body is no coverage" 1 "MISSING: 0.8.6" "$D" "$d"
d=$(pkg zc 0.8.5 0.8.7 "$(entry '- Update to version 0.8.5:')" "$(entry '- Update to version 0.8.7:
  * Fixes
  * Version 0.8.6 (skipped): WebAssembly plugin host')")
run "zeroclaw: a sub-heading names it" 0 "VERDICT: CLEAN" "$D" "$d"
# cronopete's style: the words before the version come in any order.
d=$(pkg zc 0.8.5 0.8.7 "$(entry '- Updated to version 0.8.5:')" "$(entry '- Updated to version 0.8.7:
  * Fixes
- Changes from version 0.8.6:
  * WebAssembly plugin host')")
run "cronopete: \"Changes from version V\" names it" 0 "VERDICT: CLEAN" "$D" "$d"
# patool's style: upstream's NEWS pasted in, versions indented without a bullet.
d=$(pkg zc 0.8.5 0.8.7 "$(entry '- Updated to version 0.8.5:')" "$(entry '- update to 0.8.7:
  0.8.7 (released 27.10.2026)
    * Fixes
  0.8.6 (released 18.10.2026)
    * WebAssembly plugin host')")
run "patool: an indented NEWS heading names it" 0 "VERDICT: CLEAN" "$D" "$d"
d=$(pkg zc 0.7.9 0.8.1 "$(entry '- Update to version 0.7.9:')" "$(entry '- Update to version 0.8.1:
  * 0.8.0: new plugin host')")
run "pre-releases are not releases" 0 "VERDICT: CLEAN" "$D" "$d"
hasnt "no beta reported" "beta"

# zpaqfranz: upstream flags 65.5-65.15 as pre-releases. A package on that track
# (its old version is one) crosses them; one on the releases does not.
B='[["/repos/someone/thing/releases", "github-releases-b.json"], ["/repos/someone/thing/tags", "github-tags-b.json"]]'
ZS="$GH/archive/refs/tags/%{version}.tar.gz#/thing-%{version}.tar.gz"
d=$(pkg zpaq 65.12 65.16 "$(entry '- Update to 65.12:')" "$(entry '- Update to 65.16:
  * New repack command')" "$ZS")
run "zpaqfranz: a pre-release track crosses the flagged releases" 1 "MISSING: 65.13" "$B" "$d"
has "65.14 too" "MISSING: 65.14"; has "65.15 too" "MISSING: 65.15"; has "three findings" "VERDICT: 3 finding(s)"
d=$(pkg zpaq 65.4 65.16 "$(entry '- Update to 65.4:')" "$(entry '- Update to 65.16:
  * New repack command')" "$ZS")
run "zpaqfranz: a release track does not" 0 "VERDICT: CLEAN" "$B" "$d"

# zpaqfranz re-review: the target already documents 65.13-65.15; the new entry
# repeats 65.14 and 65.13 as sub-headings.
d=$(pkg zpaq 65.15 65.16 "$(entry '- Update to 65.15 (upstream notes this release is still to be
  stabilized):
  * Lower memory use')$(entry '- Update to 65.14:
  * t -ssd')$(entry '- Update to 65.13:
  * Guards')" "$(entry '- Update to 65.16:
  * New repack command
  * 65.14: t with a path and -ssd: multithreaded verification
  * 65.13: self-overwrite guards')" "$ZS")
run "zpaqfranz: versions the target documents, described again" 1 "REPEATED: 65.14" "$B" "$d"
has "65.13 too" "REPEATED: 65.13"; hasnt "65.16 is new" "REPEATED: 65.16"
hasnt "nothing crossed" "MISSING"
# A version only mentioned (not described) is no repeat.
d=$(pkg zpaq 65.15 65.16 "$(entry '- Update to 65.15:')$(entry '- Update to 65.14:')" "$(entry '- Update to 65.16:
  * Fixes the regression 65.14 brought in')" "$ZS")
run "a mention of an old version is no repeat" 0 "VERDICT: CLEAN" "$B" "$d"

# dtrx, doctest: a whitespace fix in an old entry, even the one right below the
# new entry, does not make it new; coverage-tools: a wrapped line that starts
# with an old version heads nothing.
d=$(pkg dtrx 65.15 65.16 "$(entry '- Update to 65.15:
  * Lower memory use')$(entry '- Update to 65.14:
  * t -ssd')" "$(entry '- Update to 65.16:
  * New repack command
- Remove a stale file, which made set_version pick
  65.14, the duplicate service')" "$ZS")
sed -i 's/^  \* t -ssd$/  * t -ssd   /; s/^  \* Lower memory use$/  * Lower memory use  /' "$d/co/thing.changes"
grep -qF '  * t -ssd   ' "$d/co/thing.changes" && grep -qF '  * Lower memory use  ' "$d/co/thing.changes" \
  && pass "dtrx: the old entries really differ" || fail "dtrx fixture"
run "an edited old entry and a wrapped line repeat nothing" 0 "VERDICT: CLEAN" "$B" "$d"

# artcraft: v0.10.0 and v0.11.0 are tags without a release object, and count.
C='[["/repos/someone/thing/releases", "github-releases-c.json"], ["/repos/someone/thing/tags", "github-tags-c.json"]]'
d=$(pkg art 0.9.0 0.11.1 "$(entry '- Update to 0.9.0:')" "$(entry '- Update to 0.11.1:
  * Launcher fixes')" "thing-%{version}.tar.zst")
run "artcraft: crossed tags without a release" 1 "MISSING: 0.10.0 (tag v0.10.0, no release object)" "$C" "$d"
has "0.11.0 too" "MISSING: 0.11.0"
# No tag scheme in Source0 or URL: the new version's tag sets it, so another
# stream's tags (brotli's go/cbrotli/v1.1.0.bcr.1) stay out.
G='[["/repos/someone/thing/releases", "github-releases-c.json"], ["/repos/someone/thing/tags", "github-tags-g.json"]]'
run "no scheme given: the new version's tag sets it" 1 "MISSING: 0.11.0" "$G" "$d"
hasnt "a sub-module's tags stay out" "0.10.5"
hasnt "a tag whose version is not a number stays out" "0.10.2"
d=$(pkg art 0.9.0 0.11.1 "$(entry '- Update to 0.9.0:')" "$(entry '- Update to 0.11.1 (upstream tags v0.10.0, v0.11.0, v0.11.1):
  * Launcher fixes')" "thing-%{version}.tar.zst")
run "artcraft: named in the heading" 0 "VERDICT: CLEAN" "$C" "$d"
d=$(pkg art 0.9.0 0.11.1 "$(entry '- Update to 0.9.0:')" "$(entry '- Update to 0.11.1 (upstream tags v0.10.0, the
  hotfix v0.11.0 and v0.11.1):
  * Launcher fixes')" "thing-%{version}.tar.zst")
run "artcraft: a heading wrapped onto the next line" 0 "VERDICT: CLEAN" "$C" "$d"

# The _service obs_scm url when the spec names no forge, its tag prefix from revision.
d=$(pkg svc 0.9.0 0.11.1 "$(entry '- Update to 0.9.0:')" "$(entry '- Update to 0.11.1:')" \
  "thing-%{version}.tar.zst" "https://thing.example.org")
cat > "$d/co/_service" <<'EOF'
<services>
  <service name="obs_scm" mode="manual">
    <param name="url">https://github.com/someone/thing.git</param>
    <param name="revision">v0.11.1</param>
  </service>
</services>
EOF
F='[["/repos/someone/thing/releases", "github-releases-c.json"], ["/repos/someone/thing/tags", "github-tags-f.json"]]'
run "_service obs_scm url" 1 "MISSING: 0.10.0" "$F" "$d"
hasnt "the revision's tag scheme keeps another tag stream out" "0.10.5"

# Drafts, release candidates and a release published after the new one (a
# parallel branch) are not crossed.
E='[["/repos/someone/thing/releases", "github-releases-e.json"], ["/repos/someone/thing/tags", "[]"]]'
d=$(pkg branches 1.2.3 1.3.0 "$(entry '- Update to 1.2.3:')" "$(entry '- Update to 1.3.0:')")
run "drafts, rcs and later branch releases" 0 "VERDICT: CLEAN" "$E" "$d"

# Source0 on a registry: the registry decides, the GitHub URL is not asked.
P='[["pypi.org/pypi/thing/json", "pypi.json"]]'
PS='https://files.pythonhosted.org/packages/source/t/thing/thing-%{version}.tar.gz'
d=$(pkg py 0.8.45 0.8.51 "$(entry '- Update to 0.8.45:')" "$(entry '- Update to 0.8.51:
  * 0.8.50: x
  * 0.8.47: y
  * 0.8.46: z')" "$PS")
run "pypi: the registry decides" 1 "MISSING: 0.8.49" "$P" "$d"
hasnt "a yanked release is none" "0.8.48"; hasnt "an rc is none" "rc1"; has "one finding" "VERDICT: 1 finding(s)"
grep -q 'api.github.com' "$work/urls.log" && fail "pypi: GitHub was asked" || pass "pypi: GitHub not asked"
# A Source0 whose name is still a macro is no source: URL:'s forge answers.
d=$(pkg macro 0.9.97 0.9.99 "$OLD97" "$(entry '- Update to version 0.9.99:')" \
  'https://github.com/%{owner}/thing/archive/refs/tags/v%{version}.tar.gz')
run "an unexpanded Source0 falls back to URL:" 1 "MISSING: 0.9.98" "$A" "$d"
N='[["registry.npmjs.org/thing", "npm.json"]]'
d=$(pkg npm 1.0.0 1.2.0 "$(entry '- Update to 1.0.0:')" "$(entry '- Update to 1.2.0:')" \
  'https://registry.npmjs.org/thing/-/thing-%{version}.tgz')
run "npm" 1 "MISSING: 1.1.0" "$N" "$d"; hasnt "npm: no beta" "beta"
K='[["crates.io/api/v1/crates/thing", "crates.json"]]'
d=$(pkg crates 0.3.0 0.4.0 "$(entry '- Update to 0.3.0:')" "$(entry '- Update to 0.4.0:')" \
  'https://static.crates.io/crates/thing/thing-%{version}.crate')
run "crates.io" 1 "MISSING: 0.3.1" "$K" "$d"; hasnt "crates: a yanked version is none" "0.3.2"
L='[["gitlab.com/api/v4/projects/someone%2Fthing/repository/tags", "gitlab-tags.json"]]'
d=$(pkg gl 2.1.0 2.2.0 "$(entry '- Update to 2.1.0:')" "$(entry '- Update to 2.2.0:')" \
  'https://gitlab.com/someone/thing/-/archive/v%{version}/thing-v%{version}.tar.gz' 'https://gitlab.com/someone/thing')
run "gitlab" 1 "MISSING: 2.1.1" "$L" "$d"; hasnt "gitlab: another tag stream is none" "docs"

# A failed lookup is never clean, and a local finding is still shown.
d=$(pkg down 0.9.97 0.9.99 "$OLD97" "$(entry '- Update to version 0.9.99:')")
run "forge down" 2 "UNKNOWN" '[["/repos/someone/thing/releases", 503]]' "$d"
hasnt "no verdict of clean" "CLEAN"
run "connection refused" 2 "UNKNOWN" '[["/repos/someone/thing/releases", 0]]' "$d"
run "no such repository" 2 "UNKNOWN" '[["/repos/someone/thing/releases", 404]]' "$d"
d=$(pkg downrep 65.15 65.16 "$(entry '- Update to 65.14:')" "$(entry '- Update to 65.16:
  * 65.14: again')" "$ZS")
run "forge down, local finding kept" 2 "REPEATED: 65.14" '[["/repos/someone/thing/releases", 503]]' "$d"
d=$(pkg notrel 0.9.97 0.9.101 "$OLD97" "$(entry '- Update to version 0.9.101:')")
run "new version is no upstream release" 2 "0.9.101 is not an upstream release" "$A" "$d"
d=$(pkg snap 0.9.97 0.9.99~git20261101.abc1234 "$OLD97" "$(entry '- Update to a snapshot:')")
run "snapshot version" 2 "snapshot" "$A" "$d"
d=$(pkg noforge 1.0 1.1 "$(entry '- Update to 1.0:')" "$(entry '- Update to 1.1:')" \
  "thing-%{version}.tar.gz" "https://thing.example.org")
run "no forge to ask" 2 "no upstream" "[]" "$d"

# A checkout behind its target (a stale branch) is a downgrade, not a clean range.
d=$(pkg older 0.9.99 0.9.97 "$(entry '- Update to version 0.9.99:')" "$(entry '- Fix the build')")
run "older than the target" 1 "OLDER: 0.9.97 here is older than 0.9.99" "$A" "$d"
hasnt "older: no verdict of clean" "CLEAN"

# Nothing to compare: no version change, or a new package.
d=$(pkg same 0.9.97 0.9.97 "$OLD97" "$(entry '- Add a patch')")
run "no version change" 0 "no version change" "[]" "$d"
[ -s "$work/urls.log" ] && fail "no version change: a forge was asked" || pass "no version change: no lookup"
d=$(pkg new 0.9.97 0.9.99 "$OLD97" "$(entry '- Initial package')"); rm -rf "$d/base"
run "new package" 0 "new package" "[]" "$d"
d=$(pkg nochanges 0.9.97 0.9.99 "$OLD97" "x"); rm -f "$d/co/thing.changes"
run "no .changes in the checkout" 2 "thing.changes" "[]" "$d"

[ $fails -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
