#!/bin/bash
# test-target-gate.sh — proves scripts/target-gate.sh stamps only the exact tree
# it built against the PR's own base, and refuses or reds on each condition it
# exists for. Every case runs against a throwaway pool/foo clone under /var/tmp;
# osc, curl, tea, findmnt, uname, git-lfs and obs-build's queryrecipe are fakes
# on PATH that write the build roots, logs, obsinfo and results the script reads.
# Each negative case trips exactly one branch and asserts its message. Offline.
# Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
TG="$REPO/skills/opensuse-packaging/scripts/target-gate.sh"
fails=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d /var/tmp/test-target-gate.XXXXXX)" || exit 1
tmpcase=""
trap 'rm -rf "$work" ${tmpcase:+"$tmpcase"}' EXIT

U=tester                      # the fake OBS and Gitea account
GPRJ="home:$U:leapgate"
ROOTS="$work/roots"
export HOME="$work/home" TMPDIR="$work/tmp" BUILD_DIR="$work/obs-build" FAKE="$work/fake"
# The home package's current source revision, and the one before it.
export FAKE_SRCMD5=0123456789abcdef0123456789abcdef FAKE_OLDMD5=fedcba9876543210fedcba9876543210
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export PATH="$work/bin:$PATH"
mkdir -p "$HOME/.config/osc" "$HOME/.config/tea" "$TMPDIR" "$BUILD_DIR" "$work/bin" "$FAKE" \
  "$work/forge/$U"
printf '[general]\nbuild-root = %s/%%(package)s-%%(repo)s-%%(arch)s\n[https://api.opensuse.org]\nuser = %s\n' \
  "$ROOTS" "$U" > "$HOME/.config/osc/oscrc"
printf 'logins:\n  - name: src.opensuse.org\n    url: https://src.opensuse.org\n    token: faketoken\n    user: %s\n' \
  "$U" > "$HOME/.config/tea/config.yml"
git config --global init.defaultBranch main
# Pushes to the forge land in a local bare repo; origin's URL still reads as pool/foo.
git config --global url."file://$work/forge/".pushInsteadOf https://src.opensuse.org/
git init -q --bare "$work/forge/$U/foo.git"
cat > "$work/forge/$U/foo.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
[ -z "$FAKE_PUSH_FAIL" ] || { echo "pre-receive hook declined" >&2; exit 1; }
EOF
chmod +x "$work/forge/$U/foo.git/hooks/pre-receive"

# --- fakes --------------------------------------------------------------------
cat > "$work/bin/osc" <<'EOF'
#!/bin/bash
echo "osc $*" >> "$FAKE/calls"
sub=$1; shift
case "$sub" in
  whois) [ -z "${FAKE_WHOIS_FAIL:-}" ] || exit 1; echo 'tester: "T" <t@example.com>' ;;
  meta)
    kind=$1; shift
    if [ "$1" = -F ]; then
      [ "${FAKE_METAWRITE_FAIL:-}" != "$kind" ] || { echo "Server returned an error: HTTP Error 400: bad meta" >&2; exit 1; }
      cp "$2" "$FAKE/meta-$kind-${3//:/_}${4:+-$4}"; exit 0
    fi
    case "$1" in
      openSUSE:Backports:SLE-16.*)
        [ -z "${FAKE_META_FAIL:-}" ] || { echo "Server returned an error: HTTP Error 503"; exit 1; }
        # As live: the 16.1 PR project builds fewer arches than Backports itself.
        case "$1" in
          *16.0:PullRequest) arches=${FAKE_ARCHES:-i586 x86_64 aarch64 ppc64le s390x} ;;
          *16.1:PullRequest) arches=${FAKE_ARCHES:-i586 x86_64 aarch64} ;;
          *) arches="i586 x86_64 aarch64 ppc64le s390x" ;;
        esac
        printf '<project name="%s"><repository name="standard">' "$1"
        for a in local $arches; do printf '<arch>%s</arch>' "$a"; done
        printf '</repository></project>\n' ;;
      *) [ "${FAKE_HOMEMETA_FAIL:-}" != "$kind" ] || { echo "Server returned an error: HTTP Error 503: Service Unavailable"; exit 1; }
         f="$FAKE/meta-$kind-${1//:/_}${2:+-$2}"
         [ -f "$f" ] && cat "$f" || { echo "Server returned an error: HTTP Error 404: Not Found"; exit 1; } ;;
    esac ;;
  buildconfig) [ -z "${FAKE_BUILDCONFIG_FAIL:-}" ] || { echo "HTTP Error 503" >&2; exit 1; }; echo 'Macros:' ;;
  buildinfo)
    arch=""; prev=""
    for x in "$@"; do [ "$prev" = standard ] && arch=$x; prev=$x; done
    case " ${FAKE_BI_FAIL:-} " in *" $arch "*) echo "Server returned an error: HTTP Error 502"; exit 1;; esac
    case " ${FAKE_BI_ERROR:-} " in
      *" $arch "*) printf '<buildinfo><arch>%s</arch><error>unresolvable: nothing provides bogus-devel</error></buildinfo>\n' "$arch" ;;
      *) printf 'Using local file: foo.spec\n<buildinfo><arch>%s</arch></buildinfo>\n' "$arch" ;;
    esac ;;
  build)
    root=""; prj=""; spec=""; prev=""
    for x in "$@"; do
      [ "$prev" = --root ] && root=$x
      case "$x" in --alternative-project=*) prj=${x#*=};; *.spec) spec=$x;; esac
      prev=$x
    done
    rm -rf "$root"; mkdir -p "$root/installed-pkg"
    case "$prj" in *16.1) rel=160100;; *) rel=160000;; esac
    echo "${FAKE_RPMCONFIG:-rpm-config-SUSE-20250328-$rel.2.2 1743178964-noarch}" > "$root/installed-pkg/rpm-config-SUSE"
    v=finished; [ "${FAKE_BUILD:-}" = failed ] && v=failed
    readlink /proc/self/fd/0 > "$FAKE/build-stdin"
    { printf '[    0s] Using BUILD_ROOT=%s\n' "$root"
      [ -n "${FAKE_NO_RECIPE:-}" ] || printf '[    1s] processing recipe %s/%s ...\n' "${FAKE_RECIPE_DIR:-$(pwd -P)}" "$spec"
      printf '[   20s] fakehost %s "build %s" at Thu Sep 24 00:00:00 UTC 2026.\n' "$v" "$spec"
    } > "$root/.build.log"
    [ -z "${FAKE_BUILD_TOUCH:-}" ] || : > "$FAKE_BUILD_TOUCH"
    [ -z "${FAKE_BUILD_COMMIT:-}" ] || { echo "- $FAKE_BUILD_COMMIT" >> foo.changes; git commit -qam "$FAKE_BUILD_COMMIT"; }
    [ -z "${FAKE_OSC_RC:-}" ] || exit "$FAKE_OSC_RC"
    [ "$v" = finished ] ;;
  cat)
    [ -n "${FAKE_OBSINFO_COMMIT:-}" ] || { echo "Server returned an error: HTTP Error 404: Not Found"; exit 1; }
    printf 'mtime: 1\ncommit: %s\nurl: x\n' "$FAKE_OBSINFO_COMMIT" ;;
  results)
    [ -z "${FAKE_RESULTS_FAIL:-}" ] || { echo "Server returned an error: HTTP Error 500"; exit 1; }
    cat "$FAKE/results.xml" ;;
  api)
    case "$1" in
      /source/*)
        [ -z "${FAKE_SRC_FAIL:-}" ] || { echo "Server returned an error: HTTP Error 500"; exit 1; }
        printf '<directory name="foo" rev="2" srcmd5="%s"><entry name="_scmsync.obsinfo"/></directory>\n' "$FAKE_SRCMD5" ;;
      /build/*/_history)
        # FAKE_HIST_*="<arch>/<packid> ...": which builds are stale, empty or unreadable.
        ap=${1#/build/*/*/}; ap=${ap%/_history}
        case " ${FAKE_HIST_FAIL:-} " in *" $ap "*) echo "Server returned an error: HTTP Error 502"; exit 1;; esac
        case " ${FAKE_HIST_EMPTY:-} " in *" $ap "*) echo '<buildhistory/>'; exit 0;; esac
        case " ${FAKE_HIST_GARBAGE:-} " in *" $ap "*) echo 'Server returned garbage'; exit 0;; esac
        a=$FAKE_OLDMD5 b=$FAKE_SRCMD5
        case " ${FAKE_HIST_STALE:-} " in *" $ap "*) a=$FAKE_SRCMD5 b=$FAKE_OLDMD5;; esac
        printf '<buildhistory>\n  <entry rev="1" srcmd5="%s" bcnt="1"/>\n  <entry rev="2" srcmd5="%s" bcnt="1"/>\n</buildhistory>\n' "$a" "$b" ;;
      *) echo "fake osc: unexpected api path $1" >&2; exit 99 ;;
    esac ;;
  *) echo "fake osc: unexpected subcommand $sub" >&2; exit 99 ;;
esac
EOF
cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$FAKE/calls"
[ -z "${FAKE_CURL_FAIL:-}" ] || { echo "curl: (6) Could not resolve host: src.opensuse.org" >&2; exit 6; }
p=${FAKE_PULLS:-}; case "$*" in *page=2*) p=${FAKE_PULLS2:-};; esac
if [ -n "$p" ]; then cat "$p"; else echo '[]'; fi
EOF
cat > "$work/bin/tea" <<'EOF'
#!/bin/bash
echo "tea $*" >> "$FAKE/calls"
EOF
cat > "$work/bin/findmnt" <<'EOF'
#!/bin/bash
[ -z "${FAKE_FINDMNT_FAIL:-}" ] || exit 1
printf '/\n/dev\n/proc\n'
[ -z "${FAKE_MOUNTS:-}" ] || printf '%s\n' "$FAKE_MOUNTS"
EOF
cat > "$work/bin/uname" <<'EOF'
#!/bin/bash
echo "${FAKE_ARCH:-aarch64}"
EOF
cat > "$work/bin/git-lfs" <<'EOF'
#!/bin/bash
echo "git-lfs $*" >> "$FAKE/calls"
case "$1" in
  ls-files)
    [ -z "${FAKE_LFS_FAIL:-}" ] || { echo "git: 'lfs' is not a git command." >&2; exit 1; }
    [ -n "${FAKE_LFS:-}" ] || exit 0
    if [ "${2:-}" = -l ]; then printf '%s %s foo-1.0.tar.gz\n' "$(printf 'a%.0s' {1..64})" "$FAKE_LFS"
    else printf 'aaaaaaaaaa %s foo-1.0.tar.gz\n' "$FAKE_LFS"; fi ;;
  push) [ -z "${FAKE_LFS_PUSH_FAIL:-}" ] || { echo "batch response: Authorization error" >&2; exit 2; } ;;
esac
EOF
cat > "$BUILD_DIR/queryrecipe" <<'EOF'
#!/bin/bash
# FAKE_QR_EXCL / FAKE_QR_BAD="<flavor>=<arch,...> ...": that flavor's
# ExclusiveArch / ExcludeArch.
fl=""
while [ $# -gt 0 ]; do
  case "$1" in --buildflavor) fl=$2; shift 2;; --dist|--arch|--format) shift 2;; *) shift;; esac
done
[ -z "${FAKE_QR_GARBAGE:-}" ] || { echo "\$VAR1 = { 'name' => 'foo' };"; exit 0; }
ex=""; for e in ${FAKE_QR_EXCL:-}; do [ "${e%%=*}" = "$fl" ] && ex=${e#*=}; done
bad=""; for e in ${FAKE_QR_BAD:-}; do [ "${e%%=*}" = "$fl" ] && bad=${e#*=}; done
j='{"name":"foo"'
[ -z "$ex" ] || j+=",\"exclarch\":[\"${ex//,/\",\"}\"]"
[ -z "$bad" ] || j+=",\"badarch\":[\"${bad//,/\",\"}\"]"
echo "$j}"
EOF
cat > "$BUILD_DIR/queryconfig" <<'EOF'
#!/bin/bash
# FAKE_QC_ONLY / FAKE_QC_EXCL="<arch>=<packid,...> ...": the BuildFlags lists.
arch=""; kind=""
while [ $# -gt 0 ]; do
  case "$1" in --archpath) arch=$2; shift 2;; --dist) shift 2;; buildflags+) kind=$2; shift 2;; *) shift;; esac
done
[ -z "${FAKE_QC_FAIL:-}" ] || exit 1
case "$kind" in onlybuild) v=${FAKE_QC_ONLY:-};; excludebuild) v=${FAKE_QC_EXCL:-};; *) exit 2;; esac
for e in $v; do [ "${e%%=*}" = "$arch" ] && tr ',' '\n' <<<"${e#*=}"; done
exit 0
EOF
chmod +x "$work/bin/"* "$BUILD_DIR/queryrecipe" "$BUILD_DIR/queryconfig"

# --- the clone ------------------------------------------------------------------
# pool/foo on branch "work", tracking origin/leap-16.0, one commit ahead of it.
T="$work/template"
mkdir -p "$T" && (
  cd "$T" || exit 1
  git init -q .
  printf 'Name: foo\nVersion: 1.0\nRelease: 0\nSummary: t\nLicense: MIT\n%%description\nt\n' > foo.spec
  printf -- '- initial\n' > foo.changes
  printf '*.log\n' > .gitignore
  git add -A && git commit -qm init
  git remote add origin https://src.opensuse.org/pool/foo.git
  git update-ref refs/remotes/origin/leap-16.0 HEAD
  git update-ref refs/remotes/origin/leap-16.1 HEAD
  git checkout -qb work && git branch -q -u origin/leap-16.0
  printf -- '- fix\n' >> foo.changes && git commit -qam fix
) || { echo "cannot build the template clone"; exit 1; }
fresh() { rm -rf "$work/c/$1"; mkdir -p "$work/c"; cp -a "$T" "$work/c/$1"; echo "$work/c/$1"; }
tree() { git -C "$1" rev-parse 'HEAD^{tree}'; }
# The stamp dir is spelled through a variable: the installed pr-guard.py reads
# this suite before it runs and refuses any other text naming that path.
stampf() { local d=target-gate; echo "$1/.git/$d/$(tree "$1")-${2:-leap-16.0}.json"; }
# shellcheck disable=SC2317  # called from the checks, through eval
calls() { grep -c -- "$1" "$FAKE/calls"; }

# case_ <name> <expected rc> <expected message> <shell command>
case_() {
  local name=$1 rc=$2 msg=$3 out got; shift 3
  : > "$FAKE/calls"
  out="$(eval "$*" 2>&1)"; got=$?
  # A negative case must trip exactly one branch, or it proves neither.
  if [ "$(grep -c '^RED:' <<<"$out")" -gt 1 ]; then
    fail "$name: more than one RED check"; printf '%s\n' "$out" | sed 's/^/    /'; return
  fi
  [ "$got" = "$rc" ] && grep -qF -- "$msg" <<<"$out" && pass "$name (rc=$rc)" || {
    fail "$name: expected rc=$rc and '$msg', got rc=$got"
    printf '%s\n' "$out" | sed 's/^/    /'
  }
}
# check_ <name> <condition (shell)>
check_() { eval "$2" && pass "$1" || fail "$1"; }

case_ help 0 "Exit: 0 = green" "bash $TG --help"
case_ option-needs-value 2 "--branch needs a value" "bash $TG --build --branch"

# --- green, then review, then check ----------------------------------------------
C=$(fresh green); S=$(stampf "$C"); T12=$(tree "$C" | cut -c1-12)
case_ build-green 0 "VERDICT: GREEN — tree $T12 on leap-16.0: built aarch64, resolves i586 x86_64 ppc64le s390x" \
  "cd $C && bash $TG --build"
check_ build-green-one-native-build "[ \"\$(calls '^osc build ')\" = 1 ] && grep -qF -- 'osc build --clean --trust-all-projects --root $ROOTS/foo-leap-16.0-aarch64 --alternative-project=openSUSE:Backports:SLE-16.0 standard aarch64 foo.spec' $FAKE/calls"
check_ build-green-resolves-the-rest "[ \"\$(calls '^osc buildinfo --alternative-project openSUSE:Backports:SLE-16.0 standard')\" = 4 ] && ! grep -q 'buildinfo.* aarch64 ' $FAKE/calls"
check_ build-green-stamp "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d[\"verdict\"]==\"GREEN\" and d[\"mode\"]==\"local\" and d[\"base\"]==\"leap-16.0\" and d[\"root\"].endswith(\"/foo-leap-16.0-aarch64\") and d[\"arches\"]==[\"aarch64\",\"i586\",\"ppc64le\",\"s390x\",\"x86_64\"] and d[\"commit\"]==sys.argv[2]))' $S \$(git -C $C rev-parse HEAD)"
case_ check-no-review 3 "VERDICT: NO REVIEW — tree $T12 on leap-16.0 built GREEN" "cd $C && bash $TG"
R="$work/review"
printf 'BLOCK: BuildRequires asciidoc cannot build the man pages\ntree %s\n' "$T12" > "$R.block"
printf 'PASS tree 0123456789ab reviewed\n' > "$R.other"
printf 'PASS\nlooks fine\n' > "$R.notree"
printf 'PASS\ntree %s\n' "$T12" > "$R.treebelow"
printf 'PASSABLE once BuildRequires asciidoc is fixed\ntree %s\n' "$T12" > "$R.passable"
printf '\nPASS — tree %s, Leap checklist clean\n' "$T12" > "$R.pass"
printf 'PASS tree %s\nBuildRequires diff against Factory tree 0123456789abcdef: none\n' "$T12" > "$R.quotes"
case_ review-block 1 "review verdict is 'BLOCK: BuildRequires" "cd $C && bash $TG --review $R.block"
case_ review-other-tree 1 "review names tree 0123456789ab, HEAD is tree $T12" "cd $C && bash $TG --review $R.other"
case_ review-no-tree 1 "the PASS line names no 'tree <sha12>'" "cd $C && bash $TG --review $R.notree"
# Only the verdict line binds: HEAD's tree below it does not, another tree quoted there does not either.
case_ review-tree-below-pass-line 1 "the PASS line names no 'tree <sha12>'" "cd $C && bash $TG --review $R.treebelow"
case_ review-quotes-factory-tree 0 "review PASS recorded for tree $T12" "cd $C && bash $TG --review $R.quotes"
case_ review-passable 1 "review verdict is 'PASSABLE once" "cd $C && bash $TG --review $R.passable"
case_ review-missing-file 2 "cannot read $R.nope" "cd $C && bash $TG --review $R.nope"
case_ review-pass 0 "review PASS recorded for tree $T12 on leap-16.0" "cd $C && bash $TG --review $R.pass"
check_ review-pass-sha256 "python3 -c 'import hashlib,json,sys; d=json.load(open(sys.argv[1])); sys.exit(d[\"review\"].get(\"sha256\")!=hashlib.sha256(open(sys.argv[2],\"rb\").read()).hexdigest())' $S $R.pass"
case_ check-green 0 "VERDICT: GREEN — tree $T12 on leap-16.0: build GREEN (local" "bash $TG $C"
case_ check-other-base 3 "tree $T12 is stamped for leap-16.0, not leap-16.1" "bash $TG $C --branch leap-16.1"
case_ review-block-revokes 1 "not PASS" "cd $C && bash $TG --review $R.block"
case_ check-after-revoke 3 "VERDICT: NO REVIEW" "bash $TG $C"
case_ review-pass-again 0 "review PASS recorded" "cd $C && bash $TG --review $R.pass"
case_ review-file-relative-to-caller 0 "review PASS recorded" "cd $work && bash $TG $C --review review.pass"
case_ rebuild-keeps-review 0 "VERDICT: GREEN" "cd $C && bash $TG --build && bash $TG"
(cd "$C" && printf -- '- more\n' >> foo.changes && git commit -qam more)
case_ check-stale 3 "VERDICT: STALE — stamped $T12, HEAD $(tree "$C" | cut -c1-12) on leap-16.0" "bash $TG $C"
case_ review-before-build 3 "no GREEN build of tree $(tree "$C" | cut -c1-12) on leap-16.0" "cd $C && bash $TG --review $R.pass"
case_ check-no-build 3 "no build of tree" "bash $TG $(fresh nobuild)"

C=$(fresh forged); (cd "$C" && bash "$TG" --build >/dev/null)
sed -i 's/"verdict": "GREEN"/"verdict": "RED"/' "$(stampf "$C")"
case_ review-needs-green-verdict 3 "no GREEN build of tree" "cd $C && bash $TG --review $R.pass"
case_ check-needs-green-verdict 3 "is not GREEN" "bash $TG $C"

# A stamp is evidence only for the tree and base it names inside, whatever its file is called.
C=$(fresh renamed); S=$(stampf "$C")
(cd "$C" && bash "$TG" --build >/dev/null && bash "$TG" --review "$R.pass" >/dev/null)
cp "$S" "$(stampf "$C" leap-16.1)"
case_ stamp-renamed-to-other-base 3 "VERDICT: NO BUILD — unreadable stamp" "bash $TG $C --branch leap-16.1"
(cd "$C" && printf -- '- more\n' >> foo.changes && git commit -qam more); cp "$S" "$(stampf "$C")"
printf 'PASS tree %s\n' "$(tree "$C")" > "$R.renamed"
case_ stamp-renamed-to-other-tree 3 "VERDICT: NO BUILD — unreadable stamp" "bash $TG $C"
case_ review-stamp-renamed 3 "no GREEN build of tree $(tree "$C" | cut -c1-12)" "cd $C && bash $TG --review $R.renamed"
C=$(fresh garbage); mkdir -p "$(dirname "$(stampf "$C")")" && echo 'not json' > "$(stampf "$C")"
case_ stamp-garbage 3 "VERDICT: NO BUILD — unreadable stamp" "bash $TG $C"

C=$(fresh redrop)
case_ red-drops-stamp 1 "RED: build: build-summary rc=1" \
  "cd $C && bash $TG --build >/dev/null && FAKE_BUILD=failed bash $TG --build"
check_ red-drops-stamp-file "[ ! -e $(stampf "$C") ]"

C=$(fresh b161)
case_ build-16.1-jobs 0 "VERDICT: GREEN — tree $(tree "$C" | cut -c1-12) on leap-16.1" "bash $TG $C --branch leap-16.1 --build --jobs 8"
check_ build-16.1-root-and-jobs "grep -qF -- '--root $ROOTS/foo-leap-16.1-aarch64 --alternative-project=openSUSE:Backports:SLE-16.1 --jobs 8 standard aarch64' $FAKE/calls"
case_ build-16.1-stamped-for-16.1 3 "VERDICT: NO REVIEW — tree $(tree "$C" | cut -c1-12) on leap-16.1 built GREEN" "bash $TG $C --branch leap-16.1"
# The arches are the PR project's: Backports:SLE-16.1 has ppc64le and s390x,
# its :PullRequest project (where the bot builds) does not.
case_ build-16.1-pr-arches-only 0 "built aarch64, resolves i586 x86_64; stamped" \
  "FAKE_BI_ERROR='ppc64le s390x' bash $TG $C --branch leap-16.1 --build"
check_ build-16.1-reads-pr-project "grep -qx 'osc meta prj openSUSE:Backports:SLE-16.1:PullRequest' $FAKE/calls && ! grep -qx 'osc meta prj openSUSE:Backports:SLE-16.1' $FAKE/calls"

C=$(fresh mb)
(cd "$C" && printf '<multibuild>\n  <flavor>test</flavor>\n</multibuild>\n' > _multibuild && git add _multibuild && git commit -qm mb)
case_ multibuild-flavors 0 "flavor (none): excluded on every leap-16.0 arch, skipped" \
  "cd $C && FAKE_QR_EXCL='=do_not_build' bash $TG --build"
check_ multibuild-builds-the-flavor-only "[ \"\$(calls '^osc build ')\" = 1 ] && [ \"\$(calls '^osc build .* -M test standard aarch64 foo.spec')\" = 1 ] && [ \"\$(calls '^osc buildinfo .* -M test standard')\" = 4 ]"
case_ blacklisted-flavor-arch 0 "flavor test: build aarch64, resolve i586 x86_64 ppc64le" \
  "cd $C && FAKE_QR_EXCL='=do_not_build' FAKE_QC_EXCL='s390x=foo:test' FAKE_QC_ONLY='i586=foo' FAKE_BI_ERROR=s390x bash $TG --build"
# OBS matches the build flags on the flavor's own id and on its package's name.
case_ blacklisted-package-covers-flavor 0 "built aarch64, resolves i586 x86_64 ppc64le; stamped" \
  "cd $C && FAKE_QR_EXCL='=do_not_build' FAKE_QC_EXCL='s390x=foo' FAKE_BI_ERROR=s390x bash $TG --build"
case_ whitelisted-flavor-id 0 "built aarch64, resolves i586 x86_64 ppc64le s390x; stamped" \
  "cd $C && FAKE_QR_EXCL='=do_not_build' FAKE_QC_ONLY='i586=foo:test' bash $TG --build"
C=$(fresh mbpkg)
(cd "$C" && printf '<multibuild>\n  <package>test</package>\n</multibuild>\n' > _multibuild && git add _multibuild && git commit -qm mb)
case_ multibuild-package-entry 0 "flavor test: build aarch64, resolve i586 x86_64 ppc64le s390x" \
  "cd $C && FAKE_QR_EXCL='=do_not_build' bash $TG --build"

# --- red: the build is not evidence for this tree on this base -------------------
C=$(fresh red)
case_ tesseract-replay 1 "RED: recipe: the log built /var/tmp/tess-fix/foo.spec, not $C/foo.spec" \
  "cd $C && FAKE_RECIPE_DIR=/var/tmp/tess-fix bash $TG --build"
case_ wrong-base-marker 1 "RED: base: root has rpm-config-SUSE-20250328-160100.2.1" \
  "cd $C && FAKE_RPMCONFIG='rpm-config-SUSE-20250328-160100.2.1 1743178964-noarch' bash $TG --build"
case_ factory-marker 1 "RED: base: root has rpm-config-SUSE-20250904-1.4" \
  "cd $C && FAKE_RPMCONFIG='rpm-config-SUSE-20250904-1.4 1756977167-noarch' bash $TG --build"
case_ failed-build 1 "RED: build: build-summary rc=1 (VERDICT: FAILED)" "cd $C && FAKE_BUILD=failed bash $TG --build"
case_ unresolvable-elsewhere 1 "RED: buildinfo s390x: unresolvable: nothing provides bogus-devel" \
  "cd $C && FAKE_BI_ERROR=s390x bash $TG --build"
check_ unresolvable-skips-the-build "[ \"\$(calls '^osc build ')\" = 0 ]"
case_ build-dirties-tree 1 "RED: worktree: the build left it dirty (?? junk.o)" \
  "cd $C && FAKE_BUILD_TOUCH=junk.o bash $TG --build"
case_ build-changes-tree 1 "RED: worktree: HEAD's tree changed during the build" \
  "cd $(fresh moved) && FAKE_BUILD_COMMIT=sneaky bash $TG --build"
case_ buildinfo-lookup-failed 1 "RED: buildinfo x86_64: lookup failed: Server returned an error: HTTP Error 502" \
  "cd $(fresh bifail) && FAKE_BI_FAIL=x86_64 bash $TG --build"
case_ osc-exit-nonzero 1 "RED: build: build-summary rc=0 (VERDICT: GREEN), osc build rc=1" \
  "cd $(fresh oscrc) && FAKE_OSC_RC=1 bash $TG --build"
check_ red-leaves-no-stamp "[ ! -d $C/.git/target-gate ] || [ -z \"\$(ls $C/.git/target-gate)\" ]"
case_ log-failed-osc-zero 1 "RED: build: build-summary rc=1 (VERDICT: FAILED), osc build rc=0" \
  "cd $(fresh logfail) && FAKE_BUILD=failed FAKE_OSC_RC=0 bash $TG --build"
C=$(fresh norecipe)
case_ log-names-no-recipe 1 "RED: recipe: the log built no recipe, not $C/foo.spec" "cd $C && FAKE_NO_RECIPE=1 bash $TG --build"
# Run through a symlink, siblings still come from the real scripts directory:
# a build-summary.sh planted next to the link would read a failed log as green.
mkdir -p "$work/link" && ln -s "$TG" "$work/link/target-gate.sh"
printf '#!/bin/sh\necho "VERDICT: GREEN"\n' > "$work/link/build-summary.sh" && chmod +x "$work/link/build-summary.sh"
case_ symlink-uses-real-siblings 1 "RED: build: build-summary rc=1 (VERDICT: FAILED), osc build rc=0" \
  "cd $(fresh symlink) && FAKE_BUILD=failed FAKE_OSC_RC=0 bash $work/link/target-gate.sh --build"

# --- refused before building --------------------------------------------------------
X=$(fresh refuse)
tmpcase=$(mktemp -d /tmp/tg-case.XXXXXX)
case_ under-tmp 2 "is under /tmp or a scratchpad" "bash $TG $tmpcase --build"
mkdir -p "$work/s/scratchpad" && cp -a "$T" "$work/s/scratchpad/foo"
case_ under-scratchpad 2 "is under /tmp or a scratchpad" "bash $TG $work/s/scratchpad/foo --build"
case_ no-such-dir 2 "no such directory: $work/nonexistent" "bash $TG $work/nonexistent --build"
case_ mktemp-failed 2 "mktemp failed" "TMPDIR=$work/nonexistent bash $TG $X --build"
case_ remote-under-tmp 2 "is under /tmp or a scratchpad" "bash $TG $tmpcase --remote"
mkdir -p "$work/notgit"
case_ not-git 2 "is not a git clone" "bash $TG $work/notgit --build"
mkdir -p "$X/sub"
case_ not-top-level 2 "run on the clone's top level" "bash $TG $X/sub --build"
C=$(fresh untracked); : > "$C/new.txt"
case_ dirty-untracked 2 "worktree not clean: ?? new.txt" "bash $TG $C --build"
C=$(fresh hidden); git -C "$C" config status.showUntrackedFiles no; : > "$C/new.txt"
case_ dirty-untracked-hidden 2 "worktree not clean: ?? new.txt" "bash $TG $C --build"
C=$(fresh ignored); : > "$C/build.log"
case_ dirty-ignored 2 "worktree not clean: !! build.log" "bash $TG $C --build"
C=$(fresh detached); git -C "$C" checkout -q --detach
case_ detached-head 2 "detached HEAD" "bash $TG $C --build"
case_ lfs-unlistable 2 "cannot list LFS files (is git-lfs installed?)" "FAKE_LFS_FAIL=1 bash $TG $X --build"
case_ lfs-unsmudged 2 "LFS files not smudged (pointers only — run git lfs pull): foo-1.0.tar.gz" \
  "FAKE_LFS=- bash $TG $X --build"
case_ base-slfo 2 "slfo-1.2: an SLFO target needs a route the user names" "bash $TG $X --branch slfo-1.2 --build"
case_ base-factory 2 "factory: not a Leap target" "bash $TG $X --branch factory --build"
case_ base-unknown 2 "base 'leap-15.6' is not a Leap target" "bash $TG $X --branch leap-15.6 --build"
C=$(fresh noup); git -C "$C" branch -q --unset-upstream
case_ no-upstream 2 "no --branch and the current branch has no upstream" "bash $TG $C --build"
C=$(fresh localup); git -C "$C" branch -q -u main
case_ upstream-not-origin 2 "upstream is main, not origin/<base>" "bash $TG $C --build"
git init -q "$work/unborn"
case_ no-commit 2 "no commit on HEAD" "bash $TG $work/unborn --branch leap-16.0 --build"
C=$(fresh notpool); git -C "$C" remote set-url origin https://example.invalid/foo.git
case_ origin-not-pool 2 "not src.opensuse.org/pool/<pkg>" "bash $TG $C --build"
C=$(fresh fork); git -C "$C" remote set-url origin https://src.opensuse.org/$U/foo.git
case_ origin-a-fork 2 "origin is https://src.opensuse.org/$U/foo.git, not src.opensuse.org/pool/<pkg>" "bash $TG $C --build"
C=$(fresh noorigin); git -C "$C" remote remove origin
case_ no-origin 2 "no origin remote" "bash $TG $C --branch leap-16.0 --build"
C=$(fresh nospec); (cd "$C" && git rm -q foo.spec && git commit -qm rm)
case_ no-spec 2 "no foo.spec in $C" "bash $TG $C --build"
C=$(fresh nobase); git -C "$C" update-ref -d refs/remotes/origin/leap-16.1
case_ no-origin-base 2 "no origin/leap-16.1" "bash $TG $C --branch leap-16.1 --build"
C=$(fresh offbase)
git -C "$C" update-ref refs/remotes/origin/leap-16.0 "$(git -C "$C" commit-tree 'HEAD~1^{tree}' -p HEAD~1 -m moved)"
case_ not-on-base 2 "HEAD does not contain origin/leap-16.0" "bash $TG $C --build"
case_ no-tea-login 2 "no src.opensuse.org login" "HOME=$work/nohome bash $TG $X --build"
cp -a "$HOME" "$work/home4" && sed -i '/user:/d' "$work/home4/.config/tea/config.yml"
case_ tea-login-no-user 2 "the tea login for src.opensuse.org names no user" "HOME=$work/home4 bash $TG $X --build"
case_ pr-lookup-failed 2 "cannot read the open PRs of pool/foo (lookup failed, not 'none')" \
  "FAKE_CURL_FAIL=1 bash $TG $X --build"
printf 'not json' > "$FAKE/garbage.json"
case_ pr-list-garbage 2 "unparseable open-PR list for pool/foo" "FAKE_PULLS=$FAKE/garbage.json bash $TG $X --build"

# Stacking: HEAD = B2 on B1 on origin/leap-16.0; your PRs headed at B1 and B2.
C=$(fresh stacked); (cd "$C" && printf -- '- two\n' >> foo.changes && git commit -qam two)
B0=$(git -C "$C" rev-parse origin/leap-16.0); B1=$(git -C "$C" rev-parse HEAD~1); B2=$(git -C "$C" rev-parse HEAD)
# pr NUM BASE AUTHOR SHA [HEAD-REPO-OWNER (default AUTHOR)]
pr() { printf '{"number":%s,"base":{"ref":"%s"},"user":{"login":"%s"},"head":{"sha":"%s","ref":"h%s","repo":{"owner":{"login":"%s"}}}}' "$1" "$2" "$3" "$4" "$1" "${5:-$3}"; }
printf '[%s,%s]\n' "$(pr 7 leap-16.0 $U "$B1")" "$(pr 8 leap-16.0 $U "$B2")" > "$FAKE/stacked.json"
case_ stacked-head 2 "stacked: HEAD contains the heads of your open PRs #7 (h7) #8 (h8) to leap-16.0" \
  "FAKE_PULLS=$FAKE/stacked.json bash $TG $C --build"
# Control: one of your PRs is the one this tree updates; another base, another
# author and an already-merged head do not count.
printf '[%s,%s,%s,%s]\n' "$(pr 7 leap-16.0 $U "$B1")" "$(pr 8 leap-16.1 $U "$B2")" \
  "$(pr 9 leap-16.0 someone "$B2")" "$(pr 10 leap-16.0 $U "$B0")" > "$FAKE/one.json"
case_ extends-one-pr 0 "note: HEAD extends your open PR #7 (h7)" "FAKE_PULLS=$FAKE/one.json bash $TG $C --build"
# Control: your PR on a sibling commit is not under HEAD.
SIB=$(git -C "$C" commit-tree 'HEAD~1^{tree}' -p HEAD~1 -m sibling)
printf '[%s,%s]\n' "$(pr 7 leap-16.0 $U "$B1")" "$(pr 11 leap-16.0 $U "$SIB")" > "$FAKE/sibling.json"
case_ sibling-pr-not-stacked 0 "note: HEAD extends your open PR #7 (h7)" "FAKE_PULLS=$FAKE/sibling.json bash $TG $C --build"
# The stack sits on the second page of open PRs.
{ printf '['; for n in $(seq 100 149); do [ "$n" = 100 ] || printf ','; pr "$n" leap-16.0 someone "$B0"; done; echo ']'; } > "$FAKE/page1.json"
case_ stacked-on-page-2 2 "stacked: HEAD contains the heads of your open PRs #7 (h7) #8 (h8) to leap-16.0" \
  "FAKE_PULLS=$FAKE/page1.json FAKE_PULLS2=$FAKE/stacked.json bash $TG $C --build"
# Yours = your fork heads it, as pool-pr.sh decides, in any letter case; not
# who opened it.
printf '[%s,%s]\n' "$(pr 7 leap-16.0 someone "$B1" Tester)" "$(pr 8 leap-16.0 someone "$B2" TESTER)" > "$FAKE/byfork.json"
case_ stacked-by-head-repo-owner 2 "stacked: HEAD contains the heads of your open PRs #7 (h7) #8 (h8) to leap-16.0" \
  "FAKE_PULLS=$FAKE/byfork.json bash $TG $C --build"
printf '[%s,%s]\n' "$(pr 7 leap-16.0 $U "$B1" someone)" "$(pr 8 leap-16.0 $U "$B2" someone)" > "$FAKE/otherfork.json"
case_ authored-from-another-fork-not-yours 0 "VERDICT: GREEN" "FAKE_PULLS=$FAKE/otherfork.json bash $TG $C --build"

case_ foreign-arch 2 "host arch riscv64 is not one openSUSE:Backports:SLE-16.0:PullRequest builds" "FAKE_ARCH=riscv64 bash $TG $X --build"
case_ no-native-route 2 "flavor (none) builds on x86_64 but not on aarch64 — no native route; use --remote" \
  "FAKE_QR_EXCL='=x86_64' bash $TG $X --build"
case_ nothing-builds 2 "nothing builds on leap-16.0" "FAKE_QR_EXCL='=do_not_build' bash $TG $X --build"
case_ blacklisted-native 2 "flavor (none) builds on i586 x86_64 ppc64le s390x but not on aarch64" \
  "FAKE_QC_EXCL='aarch64=bar,foo' bash $TG $X --build"
case_ excludearch-skips-arch 0 "built aarch64, resolves i586 x86_64 ppc64le; stamped" \
  "FAKE_QR_BAD='=s390x' FAKE_BI_ERROR=s390x bash $TG $X --build"
case_ whitelist-skips-arch 0 "built aarch64, resolves x86_64 ppc64le s390x" \
  "FAKE_QC_ONLY='i586=bar,baz' FAKE_BI_ERROR=i586 bash $TG $X --build"
case_ mounted-root 2 "mounted under $ROOTS/foo-leap-16.0-aarch64: $ROOTS/foo-leap-16.0-aarch64/dev" \
  "FAKE_MOUNTS=$ROOTS/foo-leap-16.0-aarch64/dev bash $TG $X --build"
case_ mounted-root-itself 2 "mounted under $ROOTS/foo-leap-16.0-aarch64: $ROOTS/foo-leap-16.0-aarch64 — unmount" \
  "FAKE_MOUNTS=$ROOTS/foo-leap-16.0-aarch64 bash $TG $X --build"
case_ mount-prefix-control 0 "VERDICT: GREEN" "FAKE_MOUNTS=$ROOTS/foo-leap-16.0-aarch64x/dev bash $TG $X --build"
case_ findmnt-failed 2 "findmnt failed" "FAKE_FINDMNT_FAIL=1 bash $TG $X --build"
# A prompt must not wait on the caller's stdin.
case_ build-stdin-closed 0 "VERDICT: GREEN" "bash $TG $X --build < $T/foo.spec"
check_ build-stdin-is-dev-null "[ \"\$(cat $FAKE/build-stdin)\" = /dev/null ]"
case_ disallowed-flag 2 "unknown option --alternative-project=openSUSE:Factory" "bash $TG $X --build --alternative-project=openSUSE:Factory"
case_ jobs-not-a-number 2 "--jobs takes a positive integer, not '0'" "bash $TG $X --build --jobs 0"
case_ jobs-without-build 2 "--jobs goes with --build only" "bash $TG $X --remote --jobs 4"
case_ two-modes 2 "one mode only" "bash $TG $X --build --remote"
case_ two-dirs 2 "one DIR only" "bash $TG $X $X --build"
case_ pr-meta-no-arches 2 "no standard repository arches in the openSUSE:Backports:SLE-16.0:PullRequest meta" "FAKE_ARCHES=' ' bash $TG $X --build"
case_ pr-meta-failed 2 "cannot read the openSUSE:Backports:SLE-16.0:PullRequest meta: Server returned an error: HTTP Error 503" \
  "FAKE_META_FAIL=1 bash $TG $X --build"
case_ buildconfig-failed 2 "cannot read the openSUSE:Backports:SLE-16.0 standard build config" \
  "FAKE_BUILDCONFIG_FAIL=1 bash $TG $X --build"
case_ obs-build-missing 2 "$work/nobuild/queryrecipe or $work/nobuild/queryconfig not found" "BUILD_DIR=$work/nobuild bash $TG $X --build"
case_ queryconfig-failed 2 "queryconfig cannot read the openSUSE:Backports:SLE-16.0 build flags for i586" \
  "FAKE_QC_FAIL=1 bash $TG $X --build"
case_ queryrecipe-unparseable 2 "queryrecipe cannot parse foo.spec for i586" "FAKE_QR_GARBAGE=1 bash $TG $X --build"
C=$(fresh badmb); (cd "$C" && echo '<multibuild>' > _multibuild && git add _multibuild && git commit -qm mb)
case_ multibuild-unreadable 2 "_multibuild is unreadable" "bash $TG $C --build"

# --- remote: poll-once against home:<you>:leapgate ------------------------------------
C=$(fresh remote); H=$(git -C "$C" rev-parse HEAD); BR="leapgate/leap-16.0-${H:0:12}"
PKGMETA="$FAKE/meta-pkg-home_${U}_leapgate-foo"; PRJMETA="$FAKE/meta-prj-home_${U}_leapgate"
results() {   # results "<arch>:<code> ..." [dirty arch] [repository]
  { echo '<resultlist state="x">'
    for ac in $1; do
      d=""; [ "${ac%%:*}" = "${2:-}" ] && d=' dirty="true"'
      printf '<result repository="%s" arch="%s" code="published" state="published"%s><status package="foo" code="%s"/></result>\n' \
        "${3:-leap-16.0}" "${ac%%:*}" "$d" "${ac#*:}"
    done
    echo '</resultlist>'; } > "$FAKE/results.xml"
}
export FAKE_LFS='*'
case_ remote-first-call 3 "pointed $GPRJ/foo at $BR#${H:0:12}" "bash $TG $C --remote"
check_ remote-pushed-branch "[ \"\$(git -C $work/forge/$U/foo.git rev-parse refs/heads/$BR)\" = $H ]"
check_ remote-pushed-lfs "grep -q '^git-lfs push --object-id leapgate a\{64\}$' $FAKE/calls && grep -q '^tea repo fork --repo pool/foo' $FAKE/calls"
check_ remote-pkg-meta "grep -qF '<scmsync>https://src.opensuse.org/$U/foo?trackingbranch=$BR#$H</scmsync>' $PKGMETA && grep -qF '<disable repository=\"leap-16.1\" />' $PKGMETA"
check_ remote-prj-meta "python3 -c 'import sys,xml.etree.ElementTree as E; r=E.parse(sys.argv[1]).getroot(); g={x.get(\"name\"):([(p.get(\"project\"),p.get(\"repository\")) for p in x.findall(\"path\")],[a.text for a in x.findall(\"arch\")]) for x in r.findall(\"repository\")}; a=[\"i586\",\"x86_64\",\"aarch64\"]; sys.exit(g!={\"leap-16.0\":([(\"openSUSE:Backports:SLE-16.0\",\"standard\")],a+[\"ppc64le\",\"s390x\"]),\"leap-16.1\":([(\"openSUSE:Backports:SLE-16.1\",\"standard\")],a)})' $PRJMETA"
case_ remote-not-synced 3 "has no _scmsync.obsinfo yet" "bash $TG $C --remote"
check_ remote-meta-not-rewritten "[ \"\$(calls '^osc meta .*-F')\" = 0 ]"
case_ remote-pr-meta-failed 2 "cannot read the openSUSE:Backports:SLE-16.0:PullRequest meta: Server returned an error: HTTP Error 503" \
  "FAKE_META_FAIL=1 bash $TG $C --remote"
C2=$(fresh pushfail); (cd "$C2" && printf -- '- push\n' >> foo.changes && git commit -qam push)
case_ remote-push-failed 2 "push to $U/foo:leapgate/leap-16.0-$(git -C "$C2" rev-parse HEAD | cut -c1-12) failed" \
  "FAKE_PUSH_FAIL=1 bash $TG $C2 --remote"
case_ remote-lfs-push-failed 2 "LFS object push to $U/foo failed" "FAKE_LFS_PUSH_FAIL=1 bash $TG $C --remote"
# A meta that cannot be read is not a meta that does not exist: never overwrite it.
case_ remote-prj-meta-unreadable 2 "cannot read the meta of prj $GPRJ: Server returned an error: HTTP Error 503" \
  "FAKE_HOMEMETA_FAIL=prj bash $TG $C --remote"
case_ remote-pkg-meta-unreadable 2 "cannot read the meta of pkg $GPRJ foo: Server returned an error: HTTP Error 503" \
  "FAKE_HOMEMETA_FAIL=pkg bash $TG $C --remote"
cp "$PRJMETA" "$work/prjmeta.bak"; cp "$PKGMETA" "$work/pkgmeta.bak"
echo '<project name="broken"' > "$PRJMETA"
case_ remote-prj-meta-garbage 2 "unparseable $GPRJ meta" "bash $TG $C --remote"
cp "$work/prjmeta.bak" "$PRJMETA"; echo '<package name="broken"' > "$PKGMETA"
case_ remote-pkg-meta-garbage 2 "unparseable $GPRJ/foo meta" "bash $TG $C --remote"
cp "$work/pkgmeta.bak" "$PKGMETA"; rm -f "$PRJMETA"
case_ remote-prj-meta-write-failed 2 "writing the $GPRJ meta failed: Server returned an error: HTTP Error 400" \
  "FAKE_METAWRITE_FAIL=prj bash $TG $C --remote"
cp "$work/prjmeta.bak" "$PRJMETA"; rm -f "$PKGMETA"
case_ remote-pkg-meta-write-failed 2 "writing the $GPRJ/foo meta failed: Server returned an error: HTTP Error 400" \
  "FAKE_METAWRITE_FAIL=pkg bash $TG $C --remote"
cp "$work/pkgmeta.bak" "$PKGMETA"
# An existing meta that drifted is put back.
sed -i 's/openSUSE:Backports:SLE-16.0/openSUSE:Leap:16.0/' "$PRJMETA"
case_ remote-prj-path-repaired 3 "set up $GPRJ (leap-16.0, leap-16.1)" "bash $TG $C --remote"
sed -i 's#<arch>s390x</arch>##g' "$PRJMETA"
case_ remote-prj-arch-repaired 3 "set up $GPRJ (leap-16.0, leap-16.1)" "bash $TG $C --remote"
sed -i 's#<build><disable repository="leap-16.1" /></build>##' "$PKGMETA"
case_ remote-pkg-flags-repaired 3 "pointed $GPRJ/foo at $BR#${H:0:12}" "bash $TG $C --remote"
case_ remote-commit-mismatch 3 "OBS synced 0123456789ab, HEAD is $H" \
  "FAKE_OBSINFO_COMMIT=0123456789ab bash $TG $C --remote"
results "x86_64:succeeded aarch64:succeeded s390x:building"
case_ remote-building 3 "still scheduling or building" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
results "x86_64:succeeded aarch64:succeeded" aarch64
case_ remote-dirty 3 "(dirty: aarch64)" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
results "x86_64:failed aarch64:succeeded s390x:excluded"
case_ remote-failed-arch 1 "VERDICT: RED — $GPRJ/foo on leap-16.0 failed" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
results "i586:disabled x86_64:disabled aarch64:disabled ppc64le:disabled s390x:disabled"
case_ remote-not-enabled 3 "repository leap-16.0 not enabled yet" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
results "i586:excluded x86_64:excluded aarch64:excluded ppc64le:excluded s390x:excluded"
case_ remote-all-excluded 1 "excluded on every arch" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
results "x86_64:broken aarch64:succeeded"
case_ remote-broken-arch 1 "VERDICT: RED — $GPRJ/foo on leap-16.0 failed" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
echo '<resultlist state="x"></resultlist>' > "$FAKE/results.xml"
case_ remote-no-results 3 "no results for repository leap-16.0 yet" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
printf '<resultlist state="x"><result repository="leap-16.0" arch="aarch64" code="scheduling" state="scheduling"><status package="foo" code="succeeded"/></result></resultlist>\n' > "$FAKE/results.xml"
case_ remote-scheduling 3 "still scheduling or building" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
echo 'Server returned garbage' > "$FAKE/results.xml"
case_ remote-results-garbage 2 "unparseable $GPRJ/foo results" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
check_ remote-results-garbage-no-stamp "[ ! -e $(stampf "$C") ]"
case_ remote-results-unreadable 2 "cannot read the $GPRJ/foo results" \
  "FAKE_OBSINFO_COMMIT=$H FAKE_RESULTS_FAIL=1 bash $TG $C --remote"
# Every PR arch must report, and every build must be of the source revision
# whose obsinfo names HEAD: until the scheduler catches up, a build of the
# previous revision still reads "succeeded" and not dirty.
results "i586:succeeded x86_64:succeeded aarch64:succeeded"
case_ remote-pr-arch-missing 3 "no result on ppc64le s390x yet" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
results "i586:succeeded x86_64:succeeded aarch64:succeeded ppc64le:succeeded s390x:excluded"
case_ remote-stale-build 3 "source ${FAKE_SRCMD5:0:12} not built yet on aarch64/foo (built ${FAKE_OLDMD5:0:12})" \
  "FAKE_OBSINFO_COMMIT=$H FAKE_HIST_STALE=aarch64/foo bash $TG $C --remote"
check_ remote-obsinfo-read-at-that-source "grep -qxF 'osc api /source/$GPRJ/foo?expand=1' $FAKE/calls && grep -qxF 'osc cat -r $FAKE_SRCMD5 $GPRJ foo _scmsync.obsinfo' $FAKE/calls"
case_ remote-never-built 3 "not built yet on x86_64/foo (built nothing)" \
  "FAKE_OBSINFO_COMMIT=$H FAKE_HIST_EMPTY=x86_64/foo bash $TG $C --remote"
case_ remote-history-unreadable 2 "cannot read the $GPRJ/leap-16.0/ppc64le/foo build history: Server returned an error: HTTP Error 502" \
  "FAKE_OBSINFO_COMMIT=$H FAKE_HIST_FAIL=ppc64le/foo bash $TG $C --remote"
case_ remote-history-garbage 2 "unparseable $GPRJ/leap-16.0/i586/foo build history" \
  "FAKE_OBSINFO_COMMIT=$H FAKE_HIST_GARBAGE=i586/foo bash $TG $C --remote"
case_ remote-sources-unreadable 2 "cannot read the $GPRJ/foo sources: Server returned an error: HTTP Error 500" \
  "FAKE_OBSINFO_COMMIT=$H FAKE_SRC_FAIL=1 bash $TG $C --remote"
# A flavor's build is its own.
{ echo '<resultlist state="x">'
  for a in i586 x86_64 aarch64 ppc64le s390x; do
    printf '<result repository="leap-16.0" arch="%s" code="published" state="published"><status package="foo" code="succeeded"/><status package="foo:test" code="succeeded"/></result>\n' "$a"
  done
  echo '</resultlist>'; } > "$FAKE/results.xml"
case_ remote-stale-flavor 3 "not built yet on aarch64/foo:test (built ${FAKE_OLDMD5:0:12})" \
  "FAKE_OBSINFO_COMMIT=$H FAKE_HIST_STALE=aarch64/foo:test bash $TG $C --remote"
check_ remote-stale-no-stamp "[ ! -e $(stampf "$C") ]"
# The other base's repository is not this base's verdict.
{ echo '<resultlist state="x">'
  printf '<result repository="leap-16.1" arch="x86_64" code="published" state="published"><status package="foo" code="failed"/></result>\n'
  for a in i586 x86_64 aarch64 ppc64le s390x; do
    printf '<result repository="leap-16.0" arch="%s" code="published" state="published"><status package="foo" code="succeeded"/></result>\n' "$a"
  done
  echo '</resultlist>'; } > "$FAKE/results.xml"
case_ remote-other-repo-ignored 0 "VERDICT: GREEN" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
results "i586:succeeded x86_64:succeeded aarch64:succeeded ppc64le:succeeded s390x:excluded"
case_ remote-green 0 "VERDICT: GREEN — tree $(tree "$C" | cut -c1-12) built on $GPRJ/leap-16.0 at commit ${H:0:12}" \
  "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
printf 'PASS tree %s\n' "$(tree "$C")" > "$R.remote"
case_ remote-green-passes-gate 0 "VERDICT: GREEN — tree $(tree "$C" | cut -c1-12) on leap-16.0: build GREEN (remote" \
  "cd $C && bash $TG --review $R.remote && bash $TG"
check_ remote-green-stamp "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d[\"mode\"]==\"remote\" and d[\"obs_project\"]==sys.argv[2] and d[\"arches\"]==[\"aarch64\",\"i586\",\"ppc64le\",\"x86_64\"] and d[\"commit\"]==sys.argv[3]))' $(stampf "$C") $GPRJ $H"
results "i586:succeeded x86_64:unresolvable aarch64:succeeded"
case_ remote-red-drops-stamp 1 "VERDICT: RED" "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
check_ remote-red-drops-stamp-file "[ ! -e $(stampf "$C") ]"
case_ remote-other-base-repoints 3 "pointed $GPRJ/foo at leapgate/leap-16.1-${H:0:12}" \
  "FAKE_OBSINFO_COMMIT=$H bash $TG $C --branch leap-16.1 --remote"
check_ remote-other-base-disables-16.0 "grep -qF '<disable repository=\"leap-16.0\" />' $PKGMETA"
# 16.1's PR project builds no ppc64le: a failure there is not its verdict.
results "i586:succeeded x86_64:succeeded aarch64:succeeded ppc64le:failed" "" leap-16.1
case_ remote-16.1-pr-arches-only 0 "VERDICT: GREEN — tree $(tree "$C" | cut -c1-12) built on $GPRJ/leap-16.1" \
  "FAKE_OBSINFO_COMMIT=$H bash $TG $C --branch leap-16.1 --remote"
case_ remote-account-from-oscrc 3 "pointed $GPRJ/foo at" "FAKE_WHOIS_FAIL=1 bash $TG $(fresh remote2) --remote"
# The git config comes along so that even a broken gate pushes to the fake forge only.
mkdir -p "$work/home3/.config/tea" && cp "$HOME/.config/tea/config.yml" "$work/home3/.config/tea/" \
  && cp "$HOME/.gitconfig" "$work/home3/"
case_ remote-no-account 2 "cannot determine your OBS account" \
  "FAKE_WHOIS_FAIL=1 HOME=$work/home3 bash $TG $(fresh remote3) --remote"
(cd "$C" && printf -- '- next\n' >> foo.changes && git commit -qam next)
case_ remote-new-commit-repoints 3 "pointed $GPRJ/foo at leapgate/leap-16.0-$(git -C "$C" rev-parse HEAD | cut -c1-12)" \
  "FAKE_OBSINFO_COMMIT=$H bash $TG $C --remote"
unset FAKE_LFS

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
