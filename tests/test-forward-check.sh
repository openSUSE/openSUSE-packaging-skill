#!/bin/bash
# test-forward-check.sh — forward-check.py offline: a fake `osc` on PATH answers
# request searches and source lookups from a per-case fixture tree (a missing
# source is a 404, a missing search is no match, "@ERR" fails the call). Each
# package lives in devel:a with current sources bbb against openSUSE:Factory's
# aaa; the user tester's request into devel:a was accepted. A Factory request
# is the forward only from devel:a, and current only when it carries bbb.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
# shellcheck disable=SC2016  # a case's mutation is single-quoted to be eval'd in its tree
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FC="$HERE/../skills/opensuse-packaging/scripts/forward-check.py"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
h=home  # spelled apart: no literal home project in a public file
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/osc" <<'EOF'
#!/usr/bin/env python3
import os, re, sys, time, urllib.parse
fix = os.environ["FIX"]
args = sys.argv[1:]
with open(os.path.join(fix, "calls"), "a") as fh:
    fh.write("osc " + " ".join(urllib.parse.unquote(a) for a in args) + "\n")
def answer(path, missing):
    if not os.path.exists(path):
        if missing is None:
            sys.exit("Server returned an error: HTTP Error 404: Not Found")
        print(missing)
        return
    text = open(path).read()
    if text.startswith("@SLOW\n"):  # answers after 3 s
        time.sleep(3)
        text = text[6:]
    if text.strip() == "@ERR":
        sys.exit("Server returned an error: HTTP Error 500: Internal Server Error")
    if text.strip() == "@ERR502":
        sys.exit("Server returned an error: HTTP Error 502: Bad Gateway (backend said 404)")
    sys.stdout.write(text)
if args == ["whois"]:
    print('tester: "Tester"')
elif args[:2] == ["develproject", "openSUSE:Factory"]:
    f = os.path.join(fix, "devel", args[2])
    if not os.path.exists(f):
        sys.exit(1)
    print(open(f).read().strip())
elif args[0] == "api" and args[1].startswith("/search/request?match="):
    m = urllib.parse.unquote(args[1].split("=", 1)[1])
    pkg = re.search(r"@package='([^']+)'", m)
    prj = re.search(r"target/@project='([^']+)'", m)
    if "target/@project='openSUSE:Factory'" in m:
        acc = "acc-" if "state/@name='accepted'" in m else ""
        key = f"factory-{acc}{pkg.group(1)}"
    elif pkg:
        key = f"own-{prj.group(1)}-{pkg.group(1)}"
    else:
        key = "mine"
    answer(os.path.join(fix, "search", key), '<collection matches="0"/>')
elif args[0] == "api":
    answer(os.path.join(fix, "obs", re.sub(r"[/?&=]", "_", args[1])), None)
else:
    sys.exit(f"fake osc: unexpected {args}")
EOF
chmod +x "$work/bin/osc"

B="$work/base"
mkdir -p "$B/search" "$B/obs" "$B/devel"
obs() { printf '%s\n' "$2" > "$B/obs/$(printf %s "$1" | tr '/?&=' '____')"; }
# req <id> <creator> <state> <created> [<src> [<rev> [<comment> [<who> [<tgt> [<pkg>]]]]]]
# A request to openSUSE:Factory for PKG from devel:a carrying bbb by default.
req() {
  printf '<request id="%s" creator="%s"><action type="submit"><source project="%s" package="%s" rev="%s"/>' \
    "$1" "$2" "${5:-devel:a}" "${10:-PKG}" "${6-bbb}"
  printf '<target project="%s" package="%s"/></action>' "${9:-openSUSE:Factory}" "${10:-PKG}"
  printf '<state name="%s" who="%s" when="%s" created="%s"><comment>%s</comment></state></request>\n' \
    "$3" "${8:-$2}" "$4" "$4" "${7:-}"
}
coll() { printf '<collection>%s</collection>\n' "$*"; }
# srcdir <srcmd5> <md5 of its one file>: an expanded source directory
srcdir() { printf '<directory srcmd5="%s"><entry name="x.spec" md5="%s"/></directory>\n' "$1" "$2"; }
# put <pkg> <maintainer> [<factory-srcmd5>|-]: the package is in devel:a at bbb
# (last changed 2026-10-12), maintained by <maintainer>, and in
# openSUSE:Factory at aaa (- = not there); tester's request into it was accepted.
put() {
  obs "/source/devel:a/$1/_meta" "<package name=\"$1\"><person userid=\"$2\" role=\"maintainer\"/></package>"
  obs "/source/devel:a/$1?expand=1" "$(srcdir bbb bbb)"
  obs "/source/devel:a/$1/_history?limit=1" \
    '<revisionlist><revision rev="9"><time>1791806400</time></revision></revisionlist>'
  [ "${3:-aaa}" = - ] || obs "/source/openSUSE:Factory/$1?expand=1" "$(srcdir "${3:-aaa}" "${3:-aaa}")"
  printf 'devel:a/%s\n' "$1" > "$B/devel/$1"
  coll "$(req 2000 tester accepted 2026-10-15T09:00:00 $h:tester:spark x '' maint devel:a "$1")" \
    > "$B/search/own-devel:a-$1"
}
# fact <pkg> <request...>: openSUSE:Factory's open and declined requests for pkg
fact() { local p=$1; shift; coll "$@" | sed "s/PKG/$p/g" > "$B/search/factory-$p"; }
obs /source/devel:a/_meta '<project name="devel:a"/>'

put fwd maint;        fact fwd "$(req 3000 maint review 2026-10-16T08:00:00)"
put stale maint;      fact stale "$(req 3001 maint review 2026-10-16T08:00:00 devel:a old)"
obs "/source/devel:a/stale?expand=1&rev=old" "$(srcdir old aaa)"
put revnum maint;     fact revnum "$(req 3009 maint review 2026-10-16T08:00:00 devel:a 7)"
obs "/source/devel:a/revnum?expand=1&rev=7" "$(srcdir ccc bbb)"
# A linked devel package's srcmd5 changes with its link base: equal files are
# equal sources.
put relink maint;     fact relink "$(req 3010 maint review 2026-10-16T08:00:00 devel:a xxx)"
obs "/source/devel:a/relink?expand=1&rev=xxx" "$(srcdir xxx bbb)"
put samefiles maint fff
obs "/source/openSUSE:Factory/samefiles?expand=1" "$(srcdir fff bbb)"
put mineopen tester;  fact mineopen "$(req 3002 tester new 2026-10-16T08:00:00)"
put minestale tester; fact minestale "$(req 3002 tester new 2026-10-14T08:00:00 devel:a old)"
put infac maint bbb
put acc maint
coll "$(req 3003 maint accepted 2026-10-16T08:00:00 | sed s/PKG/acc/g)" > "$B/search/factory-acc-acc"
put mydecl tester;    fact mydecl "$(req 3004 tester declined 2026-10-16T08:00:00 devel:a bbb 'bugzilla refs missing' dimstar)"
put theydecl maint;   fact theydecl "$(req 3005 maint declined 2026-10-16T08:00:00 devel:a bbb 'build fails' dimstar)"
put foreign tester;   fact foreign "$(req 3006 other declined 2026-09-01T08:00:00 devel:a old 'nothing provides group(x)' dimstar)"
put due tester
put newpkg tester -
put maintdue maint
put wrong tester;     printf 'devel:b/wrong\n' > "$B/devel/wrong"
put broken tester;    echo @ERR > "$B/search/factory-broken"
put pend tester
coll "$(req 2000 tester accepted 2026-10-15T09:00:00 $h:tester:spark x '' maint devel:a pend)" \
  "$(req 2001 tester review 2026-10-17T08:00:00 $h:tester:spark x '' tester devel:a pend)" \
  > "$B/search/own-devel:a-pend"
# --mine finds accepted requests into devel projects only: Factory, other
# openSUSE: projects and home: are not devel projects; two into one package
# make one row.
coll "$(req 2002 tester accepted 2026-10-15T09:00:00 $h:tester:spark x '' maint devel:a fwd)" \
  "$(req 2007 tester accepted 2026-10-16T09:00:00 $h:tester:spark x '' maint devel:a fwd)" \
  "$(req 2003 tester accepted 2026-10-15T09:00:00 devel:a x '' maint openSUSE:Factory fwd)" \
  "$(req 2004 tester accepted 2026-10-15T09:00:00 $h:tester:spark x '' maint $h:tester fwd)" \
  "$(req 2005 tester accepted 2026-10-15T09:00:00 $h:tester:spark x '' maint devel:a due)" \
  > "$B/search/mine"

# case_ <name> <expected rc> <expected line> <mutation> <args...>
case_() {
  local name=$1 rc=$2 msg=$3 mut=$4 dir="$work/$1" out got; shift 4
  cp -a "$B" "$dir"
  (B=$dir; cd "$dir" && eval "$mut") || { fail "$name: mutation did not apply"; return; }
  out="$(cd "$dir" && FIX=$dir PATH="$work/bin:$PATH" python3 "$FC" "$@" 2>&1)"; got=$?
  LAST=$out; LASTDIR=$dir
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}
absent() { grep -qF -- "$1" <<<"$LAST" && fail "$2: '$1' in output" || pass "$2"; }

echo "--- a forward is current when it carries the devel package's sources"
case_ forwarded      0 "devel:a/fwd  FORWARDED 3000 by maint review current" : devel:a fwd
grep -qF "_meta" "$LASTDIR/calls" && fail "a forwarded package read a _meta" \
  || pass "a decided package reads no _meta"
case_ stale          4 "FORWARDED 3001 by maint review stale" : devel:a stale
case_ rev-number     0 "FORWARDED 3009 by maint review current" : devel:a revnum
case_ mine-open      0 "MINE-OPEN 3002 new current" : devel:a mineopen
case_ mine-open-stale 4 "MINE-OPEN 3002 new stale" : devel:a minestale
case_ in-factory     0 "devel:a/infac  IN-FACTORY" : devel:a infac
case_ same-files     0 "devel:a/samefiles  IN-FACTORY" : devel:a samefiles
case_ relinked       0 "FORWARDED 3010 by maint review current" : devel:a relink
case_ accepted       0 "FORWARDED 3003 by maint accepted current" : devel:a acc
grep -qF "state/@name='accepted' and state/@when>='2026-10-12'" "$LASTDIR/calls" \
  && pass "accepted forwards searched from the devel package's last change" \
  || fail "accepted: no last-change floor in the Factory search"
# A direct commit leaves no request of yours: the sources still decide.
case_ direct-commit  4 "FORWARDED 3001 by maint review stale" "rm search/own-devel:a-stale" devel:a stale

echo "--- only a request from the devel project is the forward"
case_ other-source-open 4 "devel:a/due  DUE" \
  'fact due "$(req 3100 other review 2026-10-16T08:00:00 $h:other:branches:openSUSE:Factory)"' devel:a due
case_ other-source-accepted 4 "devel:a/due  DUE" \
  'coll "$(req 3101 other accepted 2026-10-16T08:00:00 $h:other:x | sed s/PKG/due/g)" > search/factory-acc-due' devel:a due
case_ accepted-older 4 "devel:a/due  DUE" \
  'coll "$(req 3104 maint accepted 2026-10-16T08:00:00 devel:a old | sed s/PKG/due/g)" > search/factory-acc-due' devel:a due
case_ other-package  4 "devel:a/due  DUE" \
  'fact due "$(req 3107 maint review 2026-10-16T08:00:00 devel:a bbb "" "" openSUSE:Factory other)"' devel:a due

echo "--- every decline of the current sources is reported"
case_ mine-declined  4 "MINE-DECLINED 3004 by dimstar: bugzilla refs missing" : devel:a mydecl
case_ declined       4 "devel:a/theydecl  DECLINED 3005 by dimstar: build fails" : devel:a theydecl
case_ foreign        4 "FOREIGN-DECLINED 3006 by dimstar: nothing provides group(x)" : devel:a foreign
case_ foreign-elsewhere 4 "devel:a/foreign  DUE" \
  "sed -i 's/project=\"devel:a\"/project=\"$h:other:x\"/' search/factory-foreign" devel:a foreign
case_ foreign-theirs 0 "devel:a/maintdue  MAINTAINERS" \
  'fact maintdue "$(req 3006 other declined 2026-09-01T08:00:00 devel:a old "no" dimstar)"' devel:a maintdue
case_ mine-declined-older 4 "DUE supersede 3008 with -s" \
  'fact due "$(req 3008 tester declined 2026-09-01T08:00:00 devel:a old "no" dimstar)"' devel:a due

echo "--- then the role decides"
case_ due            4 "devel:a/due  DUE" : devel:a due
case_ new-in-factory 4 "NEW-IN-FACTORY ask before submitting a new package" : devel:a newpkg
case_ maintainers    0 "devel:a/maintdue  MAINTAINERS" : devel:a maintdue
case_ wrong-devel    4 "devel:a/wrong  WRONG-DEVEL openSUSE:Factory develops it in devel:b" : devel:a wrong
grep -qF "target/@project='openSUSE:Factory'" "$LASTDIR/calls" && fail "wrong-devel searched Factory first" \
  || pass "wrong-devel is decided before any Factory search"
# A current forward does not make the wrong project right.
case_ wrong-forwarded 4 "devel:a/fwd  WRONG-DEVEL" "echo devel:b/fwd > devel/fwd" devel:a fwd
case_ link-into-here 4 "devel:a/due  DUE" \
  "echo devel:b/due > devel/due; obs /source/devel:b/due/_link '<link project=\"devel:a\"/>'" devel:a due
case_ gate-fails     3 "devel:a/due  UNKNOWN autoforward-gate.sh: UNREADABLE" \
  "echo @ERR > obs/_source_devel:a_due__meta" devel:a due

echo "--- your own devel request"
case_ not-landed     0 "NOT-LANDED 2001 review" : devel:a pend
case_ older-pending  0 "devel:a/fwd  FORWARDED" \
  'coll "$(req 1999 tester review 2026-10-01T08:00:00 $h:tester:spark x "" tester devel:a fwd)" "$(req 2000 tester accepted 2026-10-15T09:00:00 $h:tester:spark x "" maint devel:a fwd)" > search/own-devel:a-fwd' devel:a fwd
case_ devel-declined 4 "DEVEL-DECLINED 2001 by maint: no" \
  'coll "$(req 2001 tester declined 2026-10-17T08:00:00 $h:tester:spark x no maint devel:a pend)" > search/own-devel:a-pend' devel:a pend

echo "--- a lookup that cannot answer is UNKNOWN, a 404 is an answer"
case_ unknown        3 "devel:a/broken  UNKNOWN" : devel:a broken
case_ status-body    3 "UNKNOWN request search answered <status>" \
  'echo "<status code=\"error\"><summary>x</summary></status>" > search/factory-due' devel:a due
case_ source-fails   3 "devel:a/due  UNKNOWN" "echo @ERR > obs/_source_devel:a_due_expand_1" devel:a due
case_ gone           0 "devel:a/due  GONE no longer in devel:a" "rm obs/_source_devel:a_due_expand_1" devel:a due
case_ not-a-404      3 "devel:a/due  UNKNOWN" "echo @ERR502 > obs/_source_devel:a_due_expand_1" devel:a due

echo "--- --mine lists your accepted requests into devel projects"
case_ mine           4 "# 2 package(s): 1 DUE, 1 FORWARDED" : --mine --since 2026-10-14
grep -qF "state/@when>='2026-10-14'" "$LASTDIR/calls" && pass "--mine searches from --since" \
  || fail "--mine: no --since floor in the search"
absent "$h:tester/" "--mine skips home: targets"
absent "openSUSE:Factory/fwd" "--mine skips openSUSE: targets"
[ "$(grep -c '^devel:a/fwd ' <<<"$LAST")" = 1 ] && pass "--mine prints one row per package" \
  || fail "--mine: devel:a/fwd not exactly once"
[ "$(tail -1 <<<"$LAST" | cut -c1)" = "#" ] && pass "--mine prints the count last" \
  || fail "--mine: count line not last"
case_ mine-unknown   3 "UNKNOWN: cannot list the requests" "echo @ERR > search/mine" --mine
case_ mine-none      0 "# 0 package(s): none" "rm search/mine" --mine

echo "--- several packages: pairs, prj/pkg and --batch"
case_ pairs          4 "# 2 package(s): 1 DUE, 1 FORWARDED" : devel:a fwd devel:a due
grep -qF "devel:a/fwd  FORWARDED 3000" <<<"$LAST" && grep -qF "devel:a/due  DUE" <<<"$LAST" \
  && pass "pairs: one row per pair" || fail "pairs: $LAST"
case_ slash          0 "devel:a/fwd  FORWARDED 3000 by maint review current" : devel:a/fwd
case_ mixed          4 "# 2 package(s): 1 DUE, 1 FORWARDED" : devel:a/fwd devel:a due
case_ duplicate      0 "# 1 package(s): 1 FORWARDED" : devel:a fwd devel:a/fwd
case_ odd-words      2 "'devel:a' has no package" : devel:a fwd devel:a
case_ empty-half     2 "not <project>/<package>: 'devel:a/'" : devel:a/
case_ batch          4 "# 3 package(s): 1 DUE, 1 FORWARDED, 1 IN-FACTORY" \
  "printf '# a comment\n\ndevel:a\tfwd\ndevel:a due\ndevel:a/infac\n' > list" --batch list
case_ batch-empty    2 "--batch list: no packages" "printf '# only a comment\n' > list" --batch list
case_ batch-missing  2 "--batch nolist: No such file or directory" : --batch nolist
case_ batch-extra    2 "--batch list:1: more than one package" "printf 'devel:a fwd due\n' > list" --batch list
case_ batch-and-pair 2 "give <devel-project> <package>, --batch FILE, or --mine" "printf 'devel:a fwd\n' > list" --batch list devel:a due
# A package the own-request search cannot answer for is UNKNOWN on its own row:
# the others are still decided.
case_ own-search-fails 3 "devel:a/pend  UNKNOWN" "echo @ERR > search/own-devel:a-pend" devel:a pend devel:a fwd
grep -qF "devel:a/fwd  FORWARDED 3000" <<<"$LAST" && pass "own-search-fails: the other package is decided" \
  || fail "own-search-fails: $LAST"

echo "--- --deadline: what it stops is UNKNOWN, and the run says it is incomplete"
case_ deadline-zero  3 "# INCOMPLETE: 2 not looked up (--deadline reached; raise it, or ask for these): devel:a/due, devel:a/fwd" \
  : devel:a fwd devel:a due --deadline 0
grep -qF "devel:a/due  UNKNOWN not looked up (--deadline reached)" <<<"$LAST" \
  && [ "$(tail -2 <<<"$LAST" | head -1 | cut -c1-12)" = "# 2 package(" ] \
  && pass "deadline-zero: rows UNKNOWN, the count before the INCOMPLETE line" || fail "deadline-zero: $LAST"
! grep -q "^osc api" "$LASTDIR/calls" && pass "deadline-zero: no lookup started" || fail "deadline-zero: $(cat "$LASTDIR/calls")"
# A lookup still running at the deadline is cut too: due's Factory search
# answers after 3 s, the deadline is 1 s, so its next lookups never start.
case_ deadline-cut   3 "# INCOMPLETE: 1 not looked up" \
  "printf '@SLOW\\n<collection matches=\"0\"/>\\n' > search/factory-due" devel:a due --deadline 1
grep -qF "devel:a/due  UNKNOWN not looked up (--deadline reached)" <<<"$LAST" \
  && pass "deadline-cut: the package is UNKNOWN, not DUE" || fail "deadline-cut: $LAST"
case_ deadline-negative 2 "--deadline takes 0 or more seconds" : devel:a due --deadline -1
# Killed by a harness timeout (SIGTERM), it still says the output is cut off.
d="$work/sigterm"; cp -a "$work/base" "$d"; printf '@SLOW\n<collection matches="0"/>\n' > "$d/search/factory-due"
( cd "$d" && FIX=$d PATH="$work/bin:$PATH" exec python3 "$FC" devel:a due > "$d/out" 2>&1 ) &
pid=$!; sleep 1; kill -TERM "$pid"; wait "$pid"; got=$?
[ "$got" = 3 ] && grep -qF "# INCOMPLETE: interrupted before every package was decided" "$d/out" \
  && pass "sigterm: prints # INCOMPLETE and exits 3" || { fail "sigterm: rc=$got"; sed 's/^/    /' "$d/out"; }

echo "--- usage"
case_ no-args        2 "give <devel-project> <package>, --batch FILE, or --mine" :
case_ both           2 "give <devel-project> <package>, --batch FILE, or --mine" : devel:a due --mine
case_ since-alone    2 "--since YYYY-MM-DD goes with --mine" : devel:a due --since 2026-10-14
case_ since-bad      2 "--since YYYY-MM-DD goes with --mine" : --mine --since 14days
case_ help           0 "Exit:" : --help

if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
