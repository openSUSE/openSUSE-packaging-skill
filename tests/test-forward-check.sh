#!/bin/bash
# test-forward-check.sh — forward-check.py offline: a fake `geectl` on PATH answers
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
export GEECTL_OBS_USERNAME=tester

mkdir -p "$work/bin"
cat > "$work/bin/geectl" <<'EOF'
#!/usr/bin/env python3
import os, sys, time
fix = os.environ["FIX"]
args = sys.argv[1:]
with open(os.path.join(fix, "calls"), "a") as fh:
    fh.write("geectl " + " ".join(args) + "\n")
def answer(path, missing):
    if not os.path.exists(path):
        if missing is None:
            if "--format" in args and args[:2] == ["remote", "cat"]:
                sys.stderr.write(
                    "error: https://api.opensuse.org/public/source/%s/%s/%s returned 404\n"
                    "remediation: check the project, package, or request name and retry\n"
                    % (args[2], args[3], args[4]))
            else:
                sys.stderr.write('{"error":{"code":"not_found","context":"fake 404"}}')
            sys.exit(3)
        print(missing)
        return
    text = open(path).read()
    if text.startswith("@SLOW\n"):  # answers after 3 s
        time.sleep(3)
        text = text[6:]
    if text.strip() == "@ERR":
        sys.stderr.write("Server returned an error: HTTP Error 500: Internal Server Error")
        sys.exit(1)
    if text.strip() == "@ERR502":
        sys.stderr.write("Server returned an error: HTTP Error 502: Bad Gateway")
        sys.exit(1)
    sys.stdout.write(text)
def opt(name):
    return args[args.index(name) + 1] if name in args else None
if args[:2] == ["request", "search"]:
    src, tgt, tpkg, creator = opt("--source-project"), opt("--target-project"), opt("--target-package"), opt("--creator")
    states = [args[i + 1] for i, a in enumerate(args) if a == "--state"]
    if src and tgt == "openSUSE:Factory" and tpkg:
        key = "factory-" + ("acc-" if states == ["accepted"] else "") + tpkg
    elif creator and tgt and tpkg:
        key = f"own-{tgt}-{tpkg}"
    elif creator and states == ["accepted"]:
        key = "mine"
    else:
        key = None
    if key is None:
        print('{"requests": []}')
    else:
        answer(os.path.join(fix, "search", key), '{"requests": []}')
elif args[:2] == ["remote", "list-files"]:
    key = f"{args[2]}_{args[3]}" + (f"_rev{opt('--rev')}" if opt("--rev") else "")
    answer(os.path.join(fix, "src", key), None)
elif args[:2] == ["remote", "package-log"]:
    key = f"{args[2]}_{args[3]}" + ("_limit1" if "--limit" in args else "")
    answer(os.path.join(fix, "log", key), None)
elif args[:2] == ["remote", "cat"]:
    answer(os.path.join(fix, "cat", f"{args[2]}_{args[3]}_{args[4]}"), None)
elif args[:2] == ["remote", "link-target"]:
    answer(os.path.join(fix, "link", f"{args[2]}_{args[3]}"), None)
elif args[:2] == ["remote", "package-meta"]:
    answer(os.path.join(fix, "meta", f"{args[2]}_{args[3]}"), None)
elif args[:2] == ["remote", "project-meta"]:
    answer(os.path.join(fix, "meta", f"{args[2]}_project"), None)
elif args[:2] == ["remote", "list-packages"]:
    answer(os.path.join(fix, "ls"), '{"project": "openSUSE:Factory", "packages": []}')
elif args[:2] == ["gitea", "raw-file"]:
    # geectl gitea raw-file OWNER REPO PATH [--ref REF]: the project git's
    # files, from $FIX/gitea/repos_<OWNER>_<REPO>_raw_<PATH, / as _>.
    # autoforward-gate.sh reads _maintainership.json through this leaf now,
    # not through git-obs.
    path = args[4].replace("/", "_")
    answer(os.path.join(fix, "gitea", "repos_%s_%s_raw_%s" % (args[2], args[3], path)), None)
else:
    sys.exit(f"fake geectl: unexpected {args}")
EOF
chmod +x "$work/bin/geectl"
# git-obs answers a project git's files from $FIX/gitea/<path, / as _>.
cat > "$work/bin/git-obs" <<'EOF'
#!/bin/bash
f="$FIX/gitea/$(printf %s "${5#/}" | tr / _)"
[ -f "$f" ] || { echo "ERROR: 404 Not Found" >&2; exit 1; }
cat "$f"
EOF
chmod +x "$work/bin/git-obs"

B="$work/base"
mkdir -p "$B/search" "$B/src" "$B/log" "$B/meta" "$B/link" "$B/gitea"
putf() { mkdir -p "$B/$(dirname "$1")"; printf '%s\n' "$2" > "$B/$1"; }
listing() { # <prj> <pkg> <filemd5>
  putf "src/$1_$2" "{\"project\": \"$1\", \"package\": \"$2\", \"files\": [{\"name\": \"x.spec\", \"size\": 1, \"mtime\": 1, \"md5\": \"$3\"}]}"
}
log1() { # <prj> <pkg> <srcmd5>
  putf "log/$1_$2_limit1" "{\"project\": \"$1\", \"package\": \"$2\", \"entries\": [{\"rev\": 9, \"srcmd5\": \"$3\", \"time\": 1791806400}]}"
}
# req <id> <creator> <state> <created> [<src> [<rev> [<comment> [<who> [<tgt> [<pkg>]]]]]]
# A request to openSUSE:Factory for PKG from devel:a carrying bbb by default.
req() {
  printf '{"id": %s, "creator": "%s", "state": {"name": "%s", "who": "%s", "when": "%s", "created": "%s", "comment": "%s"}, "actions": [{"type": "submit", "source_project": "%s", "source_package": "%s", "source_rev": "%s", "target_project": "%s", "target_package": "%s"}]}' \
    "$1" "$2" "$3" "${8:-$2}" "$4" "$4" "${7:-}" "${5:-devel:a}" "${10:-PKG}" "${6-bbb}" "${9:-openSUSE:Factory}" "${10:-PKG}"
}
coll() { local IFS=,; printf '{"requests": [%s]}\n' "$*"; }
# put <pkg> <maintainer> [<factory-srcmd5>|-]: the package is in devel:a at bbb
# (last changed 2026-10-12), maintained by <maintainer>, and in
# openSUSE:Factory at aaa (- = not there); tester's request into it was accepted.
put() {
  putf "meta/devel:a_$1" "{\"name\": \"$1\", \"project\": \"devel:a\", \"persons\": [{\"name\": \"$2\", \"role\": \"maintainer\"}], \"groups\": []}"
  listing devel:a "$1" bbb
  log1 devel:a "$1" bbb
  if [ "${3:-aaa}" != - ]; then
    listing openSUSE:Factory "$1" "${3:-aaa}"
    log1 openSUSE:Factory "$1" "${3:-aaa}"
    putf "meta/openSUSE:Factory_$1" "{\"name\": \"$1\", \"project\": \"openSUSE:Factory\", \"devel\": {\"project\": \"devel:a\", \"package\": \"$1\"}, \"persons\": [], \"groups\": []}"
  fi
  coll "$(req 2000 tester accepted 2026-10-15T09:00:00 $h:tester:spark x '' maint devel:a "$1")" \
    > "$B/search/own-devel:a-$1"
}
# fact <pkg> <request...>: openSUSE:Factory's open and declined requests for pkg
fact() { local p=$1; shift; coll "$@" | sed "s/PKG/$p/g" > "$B/search/factory-$p"; }
putf "meta/devel:a_project" '{"name": "devel:a", "persons": [], "groups": []}'

put fwd maint;        fact fwd "$(req 3000 maint review 2026-10-16T08:00:00)"
put stale maint;      fact stale "$(req 3001 maint review 2026-10-16T08:00:00 devel:a old)"
putf "src/devel:a_stale_revold" '{"project": "devel:a", "package": "stale", "files": [{"name": "x.spec", "size": 1, "mtime": 1, "md5": "aaa"}]}'
put revnum maint;     fact revnum "$(req 3009 maint review 2026-10-16T08:00:00 devel:a 7)"
putf "src/devel:a_revnum_rev7" '{"project": "devel:a", "package": "revnum", "files": [{"name": "x.spec", "size": 1, "mtime": 1, "md5": "bbb"}]}'
# A linked devel package's srcmd5 changes with its link base: equal files are
# equal sources.
put relink maint;     fact relink "$(req 3010 maint review 2026-10-16T08:00:00 devel:a xxx)"
putf "src/devel:a_relink_revxxx" '{"project": "devel:a", "package": "relink", "files": [{"name": "x.spec", "size": 1, "mtime": 1, "md5": "bbb"}]}'
put samefiles maint fff
listing openSUSE:Factory samefiles bbb
put mineopen tester;  fact mineopen "$(req 3002 tester new 2026-10-16T08:00:00)"
put minestale tester; fact minestale "$(req 3002 tester new 2026-10-14T08:00:00 devel:a old)"
putf "src/devel:a_minestale_revold" '{"project": "devel:a", "package": "minestale", "files": [{"name": "x.spec", "size": 1, "mtime": 1, "md5": "aaa"}]}'
put infac maint bbb
put acc maint
coll "$(req 3003 maint accepted 2026-10-16T08:00:00 | sed s/PKG/acc/g)" > "$B/search/factory-acc-acc"
put mydecl tester;    fact mydecl "$(req 3004 tester declined 2026-10-16T08:00:00 devel:a bbb 'bugzilla refs missing' dimstar)"
put theydecl maint;   fact theydecl "$(req 3005 maint declined 2026-10-16T08:00:00 devel:a bbb 'build fails' dimstar)"
put foreign tester;   fact foreign "$(req 3006 other declined 2026-09-01T08:00:00 devel:a old 'nothing provides group(x)' dimstar)"
put due tester
put newpkg tester -
put newmaint maint -
# newpkg was created by tester's accepted request 2000, updated by 2100 since.
putf "log/devel:a_newpkg" '{"project": "devel:a", "package": "newpkg", "entries": [{"rev": 2, "srcmd5": "ccc", "time": 1791900000, "request_id": 2100}, {"rev": 1, "srcmd5": "bbb", "time": 1791806400, "request_id": 2000}]}'
put maintdue maint
# devel:g is kept in git: hw's _meta is a stub, gorg/_ObsPrj names tester its
# maintainer (hwdata in devel:openSUSE:Factory, merged by PR, never an OBS request).
putf "meta/devel:g_project" '{"name": "devel:g", "scmsync": "https://src.opensuse.org/gorg/_ObsPrj.git", "persons": [], "groups": []}'
putf "meta/devel:g_hw" '{"name": "hw", "project": "devel:g", "persons": [], "groups": []}'
listing devel:g hw bbb
log1 devel:g hw bbb
listing openSUSE:Factory hw aaa
log1 openSUSE:Factory hw aaa
printf '{"": ["boss"], "hw": ["tester"]}\n' > "$B/gitea/repos_gorg__ObsPrj_raw__maintainership.json"
put wrong tester
putf "meta/openSUSE:Factory_wrong" '{"name": "wrong", "project": "openSUSE:Factory", "devel": {"project": "devel:b", "package": "wrong"}, "persons": [], "groups": []}'
# Not in Factory by this name, but under another spelling (devel-of.sh exit 6).
put near tester -
put near2 tester -
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
case_ stale          4 "FORWARDED 3001 by maint review stale" : devel:a stale
case_ rev-number     0 "FORWARDED 3009 by maint review current" : devel:a revnum
case_ mine-open      0 "MINE-OPEN 3002 new current" : devel:a mineopen
case_ mine-open-stale 4 "MINE-OPEN 3002 new stale" : devel:a minestale
case_ in-factory     0 "devel:a/infac  IN-FACTORY" : devel:a infac
case_ same-files     0 "devel:a/samefiles  IN-FACTORY" : devel:a samefiles
case_ relinked       0 "FORWARDED 3010 by maint review current" : devel:a relink
case_ accepted       0 "FORWARDED 3003 by maint accepted current" : devel:a acc
grep -qF -- "--target-package acc --state accepted --since 2026-10-12" "$LASTDIR/calls" \
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
  "sed -i 's/\"source_project\": \"devel:a\"/\"source_project\": \"$h:other:x\"/' search/factory-foreign" devel:a foreign
case_ foreign-theirs 0 "devel:a/maintdue  MAINTAINERS" \
  'fact maintdue "$(req 3006 other declined 2026-09-01T08:00:00 devel:a old "no" dimstar)"' devel:a maintdue
case_ mine-declined-older 4 "DUE supersede 3008 with --supersede" \
  'fact due "$(req 3008 tester declined 2026-09-01T08:00:00 devel:a old "no" dimstar)"' devel:a due

echo "--- then the role decides"
case_ due            4 "devel:a/due  DUE" : devel:a due
# A new package your accepted request created: no typed leaf says whether
# Factory ever held it, so the answer is UNKNOWN, never DUE.
case_ new-own-devel-sr 3 "devel:a/newpkg  UNKNOWN cannot tell whether openSUSE:Factory ever held this package" : devel:a newpkg
case_ new-in-factory 4 "NEW-IN-FACTORY ask before submitting a new package" 'rm search/own-devel:a-newpkg' devel:a newpkg
absent "DUE" "new-in-factory: no accepted request of yours, so not DUE"
case_ new-updated-only 4 "devel:a/newpkg  NEW-IN-FACTORY ask before submitting a new package" \
  "sed -i 's/\"request_id\": 2000/\"request_id\": 1999/' log/devel:a_newpkg" devel:a newpkg
absent "DUE" "new-updated-only: your request updated it, someone else's created it, so not DUE"
case_ new-no-request 4 "devel:a/newpkg  NEW-IN-FACTORY ask before submitting a new package" \
  "sed -i 's/\"request_id\": 2000/\"request_id\": null/' log/devel:a_newpkg" devel:a newpkg
case_ new-history-err 3 "devel:a/newpkg  UNKNOWN" 'echo @ERR > log/devel:a_newpkg' devel:a newpkg
case_ new-not-yours  0 "devel:a/newmaint  MAINTAINERS" : devel:a newmaint
case_ maintainers    0 "devel:a/maintdue  MAINTAINERS" : devel:a maintdue
case_ wrong-devel    4 "devel:a/wrong  WRONG-DEVEL openSUSE:Factory develops it in devel:b" : devel:a wrong
case_ near-spelling  4 "devel:a/near  WRONG-DEVEL NOT IN openSUSE:Factory as near, but it has Near" "printf '%s' '{\"project\": \"openSUSE:Factory\", \"packages\": [\"Near\"]}' > ls" devel:a near
case_ near-two       4 "devel:a/near2  WRONG-DEVEL" "printf '%s' '{\"project\": \"openSUSE:Factory\", \"packages\": [\"Near\", \"Near2\"]}' > ls" devel:a/near devel:a/near2
[ "$(grep -c '^geectl remote list-packages openSUSE:Factory$' "$LASTDIR/calls")" = 1 ] && pass "near-two: Factory's package list read once a run" \
  || fail "near-two: Factory listed $(grep -c '^geectl remote list-packages openSUSE:Factory$' "$LASTDIR/calls") times"
grep -qF -- "--target-project openSUSE:Factory" "$LASTDIR/calls" && fail "wrong-devel searched Factory first" \
  || pass "wrong-devel is decided before any Factory search"
# A current forward does not make the wrong project right.
case_ wrong-forwarded 4 "devel:a/fwd  WRONG-DEVEL" "putf 'meta/openSUSE:Factory_fwd' '{\"name\": \"fwd\", \"project\": \"openSUSE:Factory\", \"devel\": {\"project\": \"devel:b\", \"package\": \"fwd\"}, \"persons\": [], \"groups\": []}'" devel:a fwd
case_ link-into-here 4 "devel:a/due  DUE" \
  "putf 'meta/openSUSE:Factory_due' '{\"name\": \"due\", \"project\": \"openSUSE:Factory\", \"devel\": {\"project\": \"devel:b\", \"package\": \"due\"}, \"persons\": [], \"groups\": []}'; putf 'link/devel:b_due' '{\"project\": \"devel:b\", \"package\": \"due\", \"target\": {\"project\": \"devel:a\"}}'" devel:a due
case_ git-due        4 "devel:g/hw  DUE" : devel:g hw
case_ git-maintainers 0 "devel:g/hw  MAINTAINERS" \
  "printf '{\"hw\": [\"other\"]}\n' > gitea/repos_gorg__ObsPrj_raw__maintainership.json" devel:g hw
case_ git-unreadable 3 "devel:g/hw  UNKNOWN autoforward-gate.sh: UNREADABLE" \
  "rm gitea/repos_gorg__ObsPrj_raw__maintainership.json" devel:g hw
case_ gate-fails     3 "devel:a/due  UNKNOWN autoforward-gate.sh: UNREADABLE" \
  "echo @ERR > meta/devel:a_due" devel:a due

echo "--- your own devel request"
case_ not-landed     0 "NOT-LANDED 2001 review" : devel:a pend
case_ older-pending  0 "devel:a/fwd  FORWARDED" \
  'coll "$(req 1999 tester review 2026-10-01T08:00:00 $h:tester:spark x "" tester devel:a fwd)" "$(req 2000 tester accepted 2026-10-15T09:00:00 $h:tester:spark x "" maint devel:a fwd)" > search/own-devel:a-fwd' devel:a fwd
case_ devel-declined 4 "DEVEL-DECLINED 2001 by maint: no" \
  'coll "$(req 2001 tester declined 2026-10-17T08:00:00 $h:tester:spark x no maint devel:a pend)" > search/own-devel:a-pend' devel:a pend

echo "--- a lookup that cannot answer is UNKNOWN, a 404 is an answer"
case_ unknown        3 "devel:a/broken  UNKNOWN" : devel:a broken
case_ status-body    3 "UNKNOWN geectl request search" \
  'echo "<status code=\"error\"><summary>x</summary></status>" > search/factory-due' devel:a due
case_ source-fails   3 "devel:a/due  UNKNOWN" "echo @ERR > src/devel:a_due" devel:a due
case_ gone           0 "devel:a/due  GONE no longer in devel:a" "rm src/devel:a_due" devel:a due
case_ not-a-404      3 "devel:a/due  UNKNOWN" "echo @ERR502 > src/devel:a_due" devel:a due

echo "--- --mine lists your accepted requests into devel projects"
case_ mine           4 "# 2 package(s): 1 DUE, 1 FORWARDED" : --mine --since 2026-10-14
grep -qF -- "--since 2026-10-14" "$LASTDIR/calls" && pass "--mine searches from --since" \
  || fail "--mine: no --since floor in the search"
absent "$h:tester/" "--mine skips home: targets"
absent "openSUSE:Factory/fwd" "--mine skips openSUSE: targets"
[ "$(grep -c '^devel:a/fwd ' <<<"$LAST")" = 1 ] && pass "--mine prints one row per package" \
  || fail "--mine: devel:a/fwd not exactly once"
[ "$(tail -1 <<<"$LAST" | cut -c1)" = "#" ] && pass "--mine prints the count last" \
  || fail "--mine: count line not last"
case_ mine-unknown   3 "UNKNOWN: cannot list the requests" "echo @ERR > search/mine" --mine
case_ mine-none      0 "# 0 package(s): none" "rm search/mine" --mine

echo "--- several packages: prj/pkg words and --batch; one bare pair only alone"
case_ slash          0 "devel:a/fwd  FORWARDED 3000 by maint review current" : devel:a/fwd
case_ slashes        4 "# 2 package(s): 1 DUE, 1 FORWARDED" : devel:a/fwd devel:a/due
grep -qF "devel:a/fwd  FORWARDED 3000" <<<"$LAST" && grep -qF "devel:a/due  DUE" <<<"$LAST" \
  && pass "slashes: one row per package" || fail "slashes: $LAST"
# "prj p1 p2 p3" read as pairs checked p2/p3 and said WRONG-DEVEL.
case_ bare-list      2 "not <project>/<package>: 'devel:a'" : devel:a fwd due infac
case_ bare-pairs     2 "not <project>/<package>: 'devel:a'" : devel:a fwd devel:a due
case_ mixed          2 "not <project>/<package>: 'devel:a'" : devel:a/fwd devel:a due
case_ duplicate      0 "# 1 package(s): 1 FORWARDED" : devel:a/fwd devel:a/fwd
case_ odd-words      2 "not <project>/<package>: 'devel:a'" : devel:a fwd devel:a
case_ empty-half     2 "not <project>/<package>: 'devel:a/'" : devel:a/
case_ batch          4 "# 3 package(s): 1 DUE, 1 FORWARDED, 1 IN-FACTORY" \
  "printf '# a comment\n\ndevel:a\tfwd\ndevel:a due\ndevel:a/infac\n' > list" --batch list
case_ batch-empty    2 "--batch list: no packages" "printf '# only a comment\n' > list" --batch list
case_ batch-missing  2 "--batch nolist: No such file or directory" : --batch nolist
case_ batch-extra    2 "--batch list:1: more than one package" "printf 'devel:a fwd due\n' > list" --batch list
case_ batch-and-pair 2 "give <devel-project> <package>, --batch FILE, or --mine" "printf 'devel:a fwd\n' > list" --batch list devel:a due
# A package the own-request search cannot answer for is UNKNOWN on its own row:
# the others are still decided.
case_ own-search-fails 3 "devel:a/pend  UNKNOWN" "echo @ERR > search/own-devel:a-pend" devel:a/pend devel:a/fwd
grep -qF "devel:a/fwd  FORWARDED 3000" <<<"$LAST" && pass "own-search-fails: the other package is decided" \
  || fail "own-search-fails: $LAST"

echo "--- --deadline: what it stops is UNKNOWN, and the run says it is incomplete"
case_ deadline-zero  3 "# INCOMPLETE: 2 not looked up (--deadline reached; raise it, or ask for these): devel:a/due, devel:a/fwd" \
  : devel:a/fwd devel:a/due --deadline 0
grep -qF "devel:a/due  UNKNOWN not looked up (--deadline reached)" <<<"$LAST" \
  && [ "$(tail -2 <<<"$LAST" | head -1 | cut -c1-12)" = "# 2 package(" ] \
  && pass "deadline-zero: rows UNKNOWN, the count before the INCOMPLETE line" || fail "deadline-zero: $LAST"
! grep -q "^geectl " "$LASTDIR/calls" 2>/dev/null && pass "deadline-zero: no lookup started" || fail "deadline-zero: $(cat "$LASTDIR/calls" 2>/dev/null)"
# A lookup still running at the deadline is cut too: due's Factory search
# answers after 3 s, the deadline is 1 s, so its next lookups never start.
case_ deadline-cut   3 "# INCOMPLETE: 1 not looked up" \
  "printf '@SLOW\\n{\"requests\": []}\\n' > search/factory-due" devel:a due --deadline 1
grep -qF "devel:a/due  UNKNOWN not looked up (--deadline reached)" <<<"$LAST" \
  && pass "deadline-cut: the package is UNKNOWN, not DUE" || fail "deadline-cut: $LAST"
case_ deadline-negative 2 "--deadline takes 0 or more seconds" : devel:a due --deadline -1
# --mine runs in the background without a default cut (222 of 349 read as
# UNKNOWN at 80 s); an explicit --deadline still applies.
case_ mine-explicit-deadline 3 "UNKNOWN: cannot list the requests (--deadline reached)" : --mine --deadline 0
# Killed by a harness timeout (SIGTERM), it still says the output is cut off.
d="$work/sigterm"; cp -a "$work/base" "$d"; printf '@SLOW\n{"requests": []}\n' > "$d/search/factory-due"
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
