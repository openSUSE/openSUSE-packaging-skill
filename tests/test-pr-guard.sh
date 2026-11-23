#!/bin/bash
# test-pr-guard.sh — proves scripts/pr-guard.py refuses each way an agent has
# opened, moved or merged a pool PR, forged a gate stamp or built emulated, and
# lets the look-alikes through -- above all text a command only carries (a
# commit message, a grep pattern, an echo), which is not a command. The events live in tests/fixtures/pr-guard/
# events.json, with the commands verbatim from real agent runs where one exists
# (account names replaced), so this file carries none of the text the guard
# refuses and stays runnable under the installed guard -- a case below checks
# that. Offline: the open-PR lookup reads fixture files, git runs on scratch
# clones. Each refusal must name the rule that fired. Exit 0 = all assertions hold.
# shellcheck disable=SC2015  # `cond && pass ... || fail ...` is this suite's assertion
# idiom: pass and fail both return 0, so exactly one verdict is ever printed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
GUARD=$REPO/skills/opensuse-packaging/scripts/pr-guard.py
V1PLUGIN=$REPO/contrib/harness/opencode/pool-pr-guard.ts
V2PLUGIN=$REPO/contrib/harness/opencode-v2/pool-pr-guard.ts
PERMS=$REPO/contrib/harness/opencode/opencode.jsonc
FX=$HERE/fixtures/pr-guard
fails=0; used=" "
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
work="$(mktemp -d /var/tmp/test-pr-guard.XXXXXX)"; trap 'rm -rf "$work"' EXIT
# macOS resolves /var to /private/var: canonicalize once, so the paths
# the guard prints (resolved) match the ones this file expects.
work="$(cd "$work" && pwd -P)"

# Nothing from the machine running the suite: no git config, no skill checkout,
# no network, and an aarch64 host whatever the runner is.
export HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export PR_GUARD_ARCH=aarch64 PR_GUARD_PULLS_DIR="$work/prs" PR_GUARD_META_DIR="$work/meta"
export PR_GUARD_GITEA_DIR="$FX/gitea"
export PR_GUARD_OBS_USER=tester
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset PR_GUARD_SKILL_DIR
mkdir -p "$HOME/lua/lua-x" "$HOME/work" "$work/plain" "$work/scripts" "$work/links" && ln -s "$HOME" "$work/links/home"
cp -r "$FX/prs" "$work/prs"; cp -r "$FX/meta" "$work/meta"
cp -r "$FX/gitea" "$work/gitea"; export PR_GUARD_GITEA_DIR="$work/gitea"
python3 -c 'import json, sys
prs = [{"number": n, "head": {"ref": "b%d" % n, "repo": {"owner": {"login": "x"}}}} for n in range(50)]
json.dump(prs, open(sys.argv[1], "w"))' "$work/prs/many-prs.json"

# clone_ <dir> <branch> <remote>=<url>...
clone_() {
  local d=$1 b=$2 r; shift 2
  git init -q -b "$b" "$d" && git -C "$d" commit -q --allow-empty -m init || return 1
  for r in "$@"; do git -C "$d" remote add "${r%%=*}" "${r#*=}"; done
}
F=https://src.opensuse.org
# Pushes go over SSH: the clones whose pushes pass have SSH remotes, since a push over
# HTTPS is refused (push-https) whatever the pool rules say.
G=gitea@src.opensuse.org:
clone_ "$work/clone" leap-16.0 origin=$F/pool/tesseract-ocr.git fork=${G}someone/tesseract-ocr.git
git -C "$work/clone" branch tess-88053-16.0
clone_ "$work/track" tess-88053-16.0 origin=$F/pool/tesseract-ocr.git fork=$F/someone/tesseract-ocr.git
git -C "$work/track" config branch.tess-88053-16.0.pushRemote fork
clone_ "$work/other" factory origin=${G}AI/other-pkg.git fork=${G}someone/other-pkg.git
clone_ "$work/devel" factory origin=${G}javascript/js-pkg.git fork=${G}someone/js-pkg.git
clone_ "$work/https" electron-44 origin=$F/nodejs/nodejs-electron.git fork=$F/someone/nodejs-electron.git
clone_ "$work/tokfork" update-1 "fork=https://user:tok3n@${F#https://}/someone/x.git"
clone_ "$work/broken" leap-16.0 fork=$F/someone/broken-pkg.git
clone_ "$work/many" leap-16.0 fork=$F/someone/many-prs.git
clone_ "$work/odd" leap-16.0 fork=$F/someone/odd-pkg.git
clone_ "$work/github" main origin=https://github.com/example/tool.git
clone_ "$work/stranger" leap-16.0 fork=${G}stranger/tesseract-ocr.git
# A local branch that pushes to a differently named remote branch.
clone_ "$work/mapped" wip-tess fork=$F/someone/tesseract-ocr.git
git -C "$work/mapped" config branch.wip-tess.remote fork
git -C "$work/mapped" config branch.wip-tess.merge refs/heads/tess-88053-16.0
git -C "$work/mapped" config push.default upstream
clone_ "$work/refspec" leap-16.0 fork=$F/someone/tesseract-ocr.git
git -C "$work/refspec" config remote.fork.push 'refs/heads/*:refs/heads/*'
# On the PR branch with no push config (a bare push goes to origin), and with remote.pushDefault.
clone_ "$work/onpr" tess-88053-16.0 origin=$F/pool/tesseract-ocr.git fork=${G}someone/tesseract-ocr.git
clone_ "$work/pdef" tess-88053-16.0 origin=$F/pool/tesseract-ocr.git fork=$F/someone/tesseract-ocr.git
git -C "$work/pdef" config remote.pushDefault fork
# A remote URL that carries a token, which no refusal may print.
clone_ "$work/tokened" leap-16.0 "origin=https://user:tok3n@${F#https://}/pool/x.git"
# For GIT_DIR=~/...: bash expands ~ to $HOME, where prclone is the PR-head clone; a
# literal ~ directory inside other/ leads to the harmless clone instead.
ln -s "$work/clone" "$HOME/prclone"; ln -s "$work/other" "$HOME/otherclone"
mkdir -p "$work/other/~" && ln -s "$work/other" "$work/other/~/prclone"
# ~+ is the working directory, other/, whose clonelink is the PR-head clone; a
# literal ~+ directory leads back to other/.
ln -s "$work/clone" "$work/other/clonelink"
mkdir -p "$work/other/~+" && ln -s "$work/other" "$work/other/~+/clonelink"

# A skill checkout whose pool-pr.sh stand-in, a target-gate.sh it would run and
# another script are committed and merged (origin/main, the pinned ref); the
# cases below add an uncommitted new-tool.sh only while they need it.
S=$work/skill
mkdir -p "$S/scripts" && cp "$FX/pool-pr.sh" "$FX/open-pr.sh" "$S/scripts/"
# A changes-prepend.sh that is refused if read: allowed, it ran unread.
cp "$FX/pool-pr.sh" "$S/scripts/changes-prepend.sh"
printf '#!/bin/bash\necho "gate $*"\n' > "$S/scripts/target-gate.sh"
git init -q -b main "$S" && git -C "$S" add -A && git -C "$S" commit -q -m init
git -C "$S" update-ref refs/remotes/origin/main HEAD
cp "$S/scripts/target-gate.sh" "$work/pinned-gate.sh"; cp "$S/scripts/pool-pr.sh" "$work/pinned-pool-pr.sh"
W=$work/scripts
{ cat "$FX/pool-pr.sh"; echo 'echo pushed'; } > "$W/pool-pr-copy.sh"
# The canonical script, byte-identical and same-named but outside the checkout; and linked to.
mkdir -p "$W/elsewhere" && cp "$S/scripts/pool-pr.sh" "$W/elsewhere/"; ln -s "$S/scripts/pool-pr.sh" "$W/pool-pr-link.sh"
cp "$FX/open-pr.sh" "$FX/open_pr.py" "$FX/open-pr.js" "$FX/open-pr.pl" "$FX/agit.sh" "$FX/land.sh" "$FX/quoting.sh" "$FX/stamp.py" "$FX/kpi.py" "$FX/self-append.sh" "$FX/self-append-merge.sh" "$W/"
cp "$FX/scrape-token.sh" "$FX/obs-api.sh" "$FX/open_pr_split.py" "$FX/open_pr_comment.py" "$W/"
cp "$FX/state-xargs.sh" "$FX/state-bash-c.sh" "$W/"
# Stand-in credential files under the suite's HOME, and a link to one; their
# names live in a fixture, since the guard reads this suite.
python3 -c 'import json, os, sys
spec = json.load(open(sys.argv[1]))
for rel in spec["files"]:
    path = os.path.join(sys.argv[2], rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write("fake\n")
for name, rel in spec["links"].items():
    os.symlink(os.path.join(sys.argv[2], rel), os.path.join(sys.argv[3], name))' "$FX/creds.json" "$HOME" "$W"
# The real pool-pr.sh without its gate call and its pushes: the PR write alone,
# with method, body and URL all held in variables.
grep -v -e 'target-gate\.sh' -e ' push ' "$REPO/skills/opensuse-packaging/scripts/pool-pr.sh" > "$W/pp-nogate.sh"
# The same quoting script read as shell by its shebang alone, and by its .sh alone.
cp "$FX/quoting.sh" "$W/quoting"; tail -n +2 "$FX/quoting.sh" > "$W/quoting-plain.sh"
# A binary is not read as text, whatever strings it carries.
{ printf '\177ELF\n'; cat "$FX/open_pr.py"; } > "$W/tool"
chmod +x "$W/open-pr.sh"
printf '#!/bin/bash\nbash %s/open-pr.sh\n' "$W" > "$W/outer.sh"
# A gate.sh by its name, and a script that records a review with it.
printf 'echo gate "$@"\n' > "$W/gate.sh"; chmod +x "$W/gate.sh"
printf '%s/gate.sh . --review /var/tmp/x-review/verdict.txt\n' "$W" > "$W/record-review.sh"
# shellcheck disable=SC2016  # the script's own array, expanded when it runs
printf 'args=(. --review /var/tmp/x-review/verdict.txt)\n%s/gate.sh "${args[@]}"\n' "$W" > "$W/record-review-array.sh"
# gate.sh under another name: a link to it, and a copy of the skill's own.
ln -s "$W/gate.sh" "$W/g-link"; cp "$W/gate.sh" "$W/g-copy"
mkdir -p "$work/skill-gate/scripts" && cp "$W/gate.sh" "$work/skill-gate/scripts/gate.sh"
# Harmless now; the calls that run them rewrite them first.
printf 'echo hello\n' > "$W/iter.sh"; printf 'print("hello")\n' > "$W/iter.py"
# A script with its own backoff: its sleep is the script's, not the call's.
printf 'osc results\nsleep 120\n' > "$W/backoff.sh"
# A short long.txt where a message substitution that changes directory must not look.
printf 'Short.\n' > "$W/long.txt"
# A FIFO blocks whoever opens it until a writer comes: never opened by the guard.
mkfifo "$W/fifo"
# The harmless scripts of a sweep loop, 64 of them.
mkdir -p "$W/sweep" && for i in $(seq -w 1 64); do printf 'echo %s\n' "$i" > "$W/sweep/p$i.sh"; done
# A local script named like the gate, which copies its arguments.
cp "$FX/fake-gate.sh" "$W/target-gate.sh"; chmod +x "$W/target-gate.sh"
# A skill whose gate.sh, as merged, writes its stamp: unread only while pinned.
mkdir -p "$W/state-skill/scripts" && cp "$FX/state-gate.sh" "$W/state-skill/scripts/gate.sh"
git init -q -b main "$W/state-skill" && git -C "$W/state-skill" add -A && git -C "$W/state-skill" commit -q -m init
git -C "$W/state-skill" update-ref refs/remotes/origin/main HEAD
# A link to that gate.sh from a directory an agent writes, which would run the
# siblings planted beside the link; and a link to a skill's scripts/ itself.
mkdir -p "$W/evil" && ln -s "$W/state-skill/scripts/gate.sh" "$W/evil/gate.sh"
ln -s "$S/scripts" "$W/scripts-link"
# A worktree named like the stamp directory, which is no git directory (spelled
# in pieces: the guard reads this suite), and a git directory not named .git.
g=gate; mkdir -p "$W/wt/target-$g"
git init -q --bare "$work/barerepo"
# osc checkouts: .osc/_project names the project a commit lands in. The home
# projects are spelled in pieces: check-skills.py reads this suite.
osc_co_() { mkdir -p "$1/.osc" && printf '%s\n' "$2" > "$1/.osc/_project"; }
h=home
osc_co_ "$work/osc/upd/x" openSUSE:Backports:SLE-15-SP7:Update
osc_co_ "$work/osc/incident/x" openSUSE:Maintenance:12345
osc_co_ "$work/osc/$h:tester:branches:OBS_Maintained:x/x.openSUSE_Backports_SLE-15-SP7_Update" "$h:tester:branches:OBS_Maintained:x"
osc_co_ "$work/osc/branch/x" "$h:tester:branches:openSUSE:Backports:SLE-15-SP7:Update"
osc_co_ "$work/osc/devel/x" devel:tools
# A geectl working copy: a git checkout carrying the geectl project and package
# in its config, the way the working-copy leaves record them.
geectl_co_() { git init -q -b main "$1" && git -C "$1" config geectl.project "$2" && git -C "$1" config geectl.package "$3"; }
geectl_co_ "$work/osc/spark/libpqxx" "$h:tester:spark" libpqxx
geectl_co_ "$work/osc/spark/python-streamdeck" "$h:tester:spark" python-streamdeck
# A geectl working copy in a maintenance project: a commit there is a direct write.
geectl_co_ "$work/osc/maint/mypkg" "openSUSE:Maintenance:12345" mypkg
osc_co_ "$work/osc/fresh/y" devel:tools; osc_co_ "$work/osc/edited/z" devel:tools
# A scmsync checkout (osc co of a package OBS syncs from git) takes no osc commit.
osc_co_ "$work/osc/scm/s" devel:tools && printf 's\n' > "$work/osc/scm/s/.osc/_package" \
  && printf 'https://src.opensuse.org/tools/s#main\n' > "$work/osc/scm/s/.osc/_scm"
osc_co_ "$work/osc/obs/obsbare" devel:tools
osc_co_ "$work/osc/prjco" devel:tools
# osc co PRJ PKG: a project checkout around its one package, and one around three.
osc_co_ "$work/osc/single" devel:tools; osc_co_ "$work/osc/single/x" devel:tools && printf 'x\n' > "$work/osc/single/x/.osc/_package"
osc_co_ "$work/osc/multi" devel:tools
for p in termit kmscon rioterm; do geectl_co_ "$work/osc/multi/$p" devel:tools "$p"; done
ln -s "$work/osc/spark" "$work/links/spark"
# What a commit, a submit or a forward the guard lets through unasked needs, from
# fixtures/pr-guard/stamped.json: gate.sh's stamp of a reviewed tree (under this
# suite's HOME) with the source listing it matches, and the _meta of a package
# the account maintains; and the near misses the asks are tested on.
python3 - "$FX/stamped.json" "$work/meta/api" "$HOME" "$work" <<'PY'
import hashlib, json, os, sys
spec, api, home, work = sys.argv[1:]
os.makedirs(api, exist_ok=True)
s = json.load(open(spec))
def stub(path, text):
    open(os.path.join(api, path.translate(str.maketrans("/?&=", "____"))), "w").write(text)
def stamp(prj, pkg, files, review=True, build=True, no_entry="", obs=None, pre=None, added=None, factory=True):
    d = os.path.join(home, s["state_dir"], "gate", "obs", pkg)
    os.makedirs(d, exist_ok=True)
    st = {"project": prj, "package": pkg, "verdict": "GREEN", "files": files, "tree": "0" * 64}
    if review:
        st["review"] = {"verdict": "PASS"}
    if build:
        st["build"] = {"verdict": "GREEN", "kind": "log"}
    if obs is not None:
        st["target"] = "devel:tools"
        st["build"] = {"verdict": "GREEN", "kind": "obs", "repos": sorted(["openSUSE_Tumbleweed"] + obs),
                       "factory": factory, "others": obs}
        if added is not None:
            st["build"]["added"] = added
        if pre is not None:
            st["build"]["repos"] = sorted(set(st["build"]["repos"]) | {p.split("/")[0] for p in pre})
            st["build"]["preexisting"] = pre
    if no_entry:
        st["no_entry"] = no_entry
    json.dump(st, open(os.path.join(d, prj + ".json"), "w"))
def pairs(key):
    return [tuple(e) for e in s[key]]
def listing(prj, pkg):
    md5 = hashlib.md5(f"{prj} {pkg}".encode()).hexdigest()
    stub(f"/source/{prj}/{pkg}?expand=1",
         f'<directory name="{pkg}"><entry name="_link" md5="0"/><entry name="{pkg}.spec" md5="{md5}"/></directory>')
    return {f"{pkg}.spec": md5}
for prj, pkg in pairs("stamped"):
    stamp(prj, pkg, listing(prj, pkg))
for prj, pkg in pairs("listed"):
    listing(prj, pkg)
for prj, pkg in pairs("noreview"):
    stamp(prj, pkg, listing(prj, pkg), review=False)
for prj, pkg in pairs("nobuild"):
    stamp(prj, pkg, listing(prj, pkg), build=False)
for prj, pkg in pairs("noentry"):
    stamp(prj, pkg, listing(prj, pkg), no_entry="comment-only cleanup")
for prj, pkg in pairs("obs_factory"):
    stamp(prj, pkg, listing(prj, pkg), obs=[])
for prj, pkg in pairs("obs_repos"):
    stamp(prj, pkg, listing(prj, pkg), obs=["16.0"], added=[])
for prj, pkg in pairs("obs_sle"):
    stamp(prj, pkg, listing(prj, pkg), obs=["SLE_15_SP7"], added=["SLE_15_SP7"])
for prj, pkg in pairs("obs_nofac"):
    stamp(prj, pkg, listing(prj, pkg), obs=["16.0"], added=[], factory=False,
          pre=["openSUSE_Tumbleweed/x86_64 failed", "openSUSE_Tumbleweed/aarch64 failed"])
for prj, pkg in pairs("obs_pre"):
    stamp(prj, pkg, listing(prj, pkg), obs=[], pre=["16.1/x86_64 failed", "16.1/aarch64 unresolvable"])
for prj, pkg in pairs("stale"):
    listing(prj, pkg)
    stamp(prj, pkg, {f"{pkg}.spec": "0" * 32})
for prj, pkg in pairs("listing_err"):
    stub(f"/source/{prj}/{pkg}?expand=1", "@ERR")
for prj, pkg in pairs("own"):
    stub(f"/source/{prj}/{pkg}/_meta",
         f'<package name="{pkg}" project="{prj}"><person userid="tester" role="maintainer"/></package>')
    stub(f"/source/{prj}/_meta", f'<project name="{prj}"/>')
for key in ("checkouts", "unstamped", "edited", "obs_checkouts"):
    for rel, prj, pkg in s[key]:
        d = os.path.join(work, rel)
        open(os.path.join(d, ".osc/_package"), "w").write(pkg + "\n")
        open(os.path.join(d, ".osc/_files"), "w").write(
            f'<directory name="{pkg}"><entry name="{pkg}.spec" md5="0"/></directory>')
        open(os.path.join(d, pkg + ".spec"), "w").write(f"Name: {pkg}\n")
        md5 = hashlib.md5(f"Name: {pkg}\n".encode()).hexdigest()
        if key in ("checkouts", "obs_checkouts"):  # and committed: the source listing a submit reads
            stub(f"/source/{prj}/{pkg}?expand=1",
                 f'<directory name="{pkg}"><entry name="{pkg}.spec" md5="{md5}"/></directory>')
        if key != "unstamped":
            stamp(prj, pkg, {f"{pkg}.spec": md5}, obs=[] if key == "obs_checkouts" else None)
        if key == "edited":
            open(os.path.join(d, pkg + ".spec"), "a").write("Version: 2\n")
# A link into the state directory, which a write through it reaches.
os.symlink(os.path.join(home, s["state_dir"]), os.path.join(work, "links", "state"))
PY
# Contributors' requests and devel PRs, the incoming reviews recorded of them and
# what OBS and Gitea answer, from fixtures/pr-guard/incoming.json; the scripts the
# recording cases run; and a HOME whose one review record does not parse.
python3 - "$FX/incoming.json" "$FX/stamped.json" "$work" "$HOME" "$W" <<'PY'
import hashlib, json, os, sys
spec, stamped, work, home, scripts = sys.argv[1:]
s = json.load(open(spec))
sd = json.load(open(stamped))["state_dir"]
state = os.path.join(home, sd)
api, meta, gitea = (os.path.join(work, d) for d in ("meta/api", "meta", "gitea"))
def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)
def stub(path, text):
    put(os.path.join(api, path.translate(str.maketrans("/?&=", "____"))), text)
def gstub(path, obj):
    put(os.path.join(gitea, path.replace("/", "_")), json.dumps(obj))
def md5(t):
    return hashlib.md5(t.encode()).hexdigest()
def entries(files):
    return "".join(f'<entry name="{n}" md5="{m}"/>' for n, m in files.items())
def factory(pkg, devel):
    text = f'<package name="{pkg}" project="openSUSE:Factory"><devel project="{devel}" package="{pkg}"/></package>'
    put(os.path.join(meta, pkg + ".xml"), text)
    stub(f"/source/openSUSE:Factory/{pkg}/_meta", text)
def stamp(kind, name, sid, creator, verdict, part, comment="", build="", key="0123456789ab" + "0" * 52, root=state, green=True):
    green = bool(build) and green
    ok = {"openSUSE_Tumbleweed/x86_64": "succeeded", "16.0/aarch64": "succeeded"} if green else {}
    st = {"v": 1, "kind": kind, "id": sid, "creator": creator, "verdict": verdict,
          "key": key, "recorded": "2026-11-22T10:00:00Z", "scan": {"exit": 0, "lines": []},
          "build": {"project": build, "results": ok, "srcmd5": "", "green": green},
          "findings": [], "comment": comment,
          "comment_sha256": hashlib.sha256(comment.encode()).hexdigest() if comment else ""}
    put(os.path.join(root, "incoming", kind, name + ".json"), json.dumps(dict(st, **part)))
S, D = s["source_project"], "devel:inc"
stub(f"/source/{D}/_meta", f'<project name="{D}"><person userid="tester" role="maintainer"/></project>')
for c in s["obs"]:
    pkg, rid, rev, T = c["pkg"], c["id"], c.get("rev", "5"), c.get("target", D)
    sfiles, tfiles = {f"{pkg}.spec": md5("new " + pkg)}, {f"{pkg}.spec": md5("old " + pkg)}
    ssrc, tsrc = md5("src " + pkg), md5("tgt " + pkg)
    rev = ssrc if rev == "@srcmd5" else rev  # a _link pinned by its expanded srcmd5
    opts = "".join(f"<{o}>true</{o}>" for o in c.get("options", []))
    act = (f'<action type="submit"><source project="{S}" package="{pkg}"' + (f' rev="{rev}"' if rev else "")
           + f'/><target project="{T}" package="{pkg}"/>' + (f"<options>{opts}</options>" if opts else "") + "</action>")
    stub(f"/request/{rid}", f'<request id="{rid}" creator="contrib">{act * c.get("actions", 1)}<state name="new"/></request>')
    lprj, lpkg = c["link"].split("/") if isinstance(c.get("link"), str) else (T, pkg)
    base = md5("older " + pkg) if c.get("stale_base") else tsrc
    link = f'<linkinfo project="{lprj}" package="{lpkg}" baserev="{base}"/>' if c.get("link") else ""
    stub(f"/source/{S}/{pkg}?expand=1&rev={rev}", f'<directory name="{pkg}" srcmd5="{ssrc}">{link}{entries(sfiles)}</directory>')
    now = {"source": sfiles, "followup": {f"{pkg}.spec": md5("fix " + pkg)}}.get(c.get("devel"), tfiles)
    stub(f"/source/{T}/{pkg}?expand=1", f'<directory name="{pkg}" srcmd5="{tsrc}">{entries(now)}</directory>')
    if c.get("factory"):  # openSUSE:Factory's own listing of the package
        stub(f"/source/openSUSE:Factory/{pkg}?expand=1", "@ERR" if c["factory"] == "@ERR"
             else f'<directory name="{pkg}"><entry name="_link" md5="0"/>{entries(sfiles)}</directory>')
    stub(f"/source/{T}/{pkg}/_meta", f'<package name="{pkg}" project="{T}"><person userid="tester" role="maintainer"/></package>')
    factory(pkg, D)
    if T == "openSUSE:Factory":  # the account as a reviewer of Factory's own package
        stub(f"/source/{T}/{pkg}/_meta", f'<package name="{pkg}" project="{T}"><devel project="{D}" package="{pkg}"/>'
             f'<person userid="{c["maintainer"]}" role="maintainer"/></package>')
        stub(f"/source/{T}/_meta", f'<project name="{T}"/>')
    if c["verdict"]:
        part = {"obs": {"actions": c.get("actions", 1), "action": {
            "type": "submit", "options": c.get("options", []),
            "source": {"project": S, "package": pkg, "rev": rev,
                       "srcmd5": md5("other") if c.get("stamp_src") else ssrc, "files": sfiles},
            "target": {"project": T, "package": pkg,
                       "srcmd5": md5("other") if c.get("stamp_tgt") else tsrc, "files": tfiles}}}}
        # the 48-bit key of old, under a HOME of its own: as no valid record, it holds every forward
        key = {"key": "0123456789ab", "root": os.path.join(work, "oldkey", sd)} if c.get("key12") else {}
        stamp("obs", rid, rid, "contrib", c["verdict"], part, c.get("comment", ""), S, green=c.get("green", True), **key)
    if c.get("devel") == "followup" or c.get("factory"):  # devel's files, gated and reviewed, as a forward needs them
        put(os.path.join(state, "gate", "obs", pkg, D + ".json"), json.dumps({
            "project": D, "package": pkg, "verdict": "GREEN", "files": now, "tree": "0" * 64,
            "review": {"verdict": "PASS"}, "build": {"verdict": "GREEN", "kind": "log"}}))
g = s["gitea"]
GD, O = g["devel"], g["owner"]
stub(f"/source/{GD}/_meta", f'<project name="{GD}"><scmsync>https://src.opensuse.org/{O}/_ObsPrj</scmsync></project>')
gstub(f"repos/{O}/_ObsPrj/raw/_maintainership.json", g["maintainers"])
for pkg in g["maintainers"]:
    role = f'<person userid="{g["reviewer"][pkg]}" role="reviewer"/>' if pkg in g["reviewer"] else ""
    org = g["scmsync_owner"].get(pkg, O)
    stub(f"/source/{GD}/{pkg}/_meta",
         f'<package name="{pkg}" project="{GD}"><scmsync>https://src.opensuse.org/{org}/{pkg}#factory</scmsync>{role}</package>')
    factory(pkg, GD)
for p in g["prs"]:
    o, r, n = p.get("owner", O), p["repo"], p["number"]
    gstub(g["pr_path"].format(o=o, r=r, n=n), {"number": n, "state": "open", "user": {"login": p["author"]},
          "head": {"sha": p["head"]}, "base": {"sha": "b" * 40, "repo": {"full_name": f"{o}/{r}"}}})
    gstub(f"repos/{o}/{r}/issues/{n}", {"number": n, "user": {"login": p["author"]},
          "repository": {"full_name": f"{o}/{r}"}})
    files = {f"{r}.spec": p["head"][:39] + "f"}
    if p.get("hold"):  # the commit OBS synced holds what the PR's head held
        stub(f"/source/{GD}/{r}/_scmsync.obsinfo", f"mtime: 1\ncommit: {g['synced']}\n")
        gstub(f"repos/{o}/{r}/git/trees/{g['synced']}?recursive=true&per_page=1000",
              {"sha": g["synced"], "truncated": False,
               "tree": [{"path": f, "type": "blob", "mode": "100644", "sha": h} for f, h in files.items()]})
    if p.get("factory"):  # Factory holds devel's files; OBS lists what it adds to a synced package beside them
        held = {f"{r}.spec": md5("pr " + r)}
        synced = dict(held, **{"_scmsync.obsinfo": md5("info " + r), "build.specials.obscpio": md5("cpio " + r)})
        stub(f"/source/{GD}/{r}?expand=1", f'<directory name="{r}">{entries(synced)}</directory>')
        stub(f"/source/openSUSE:Factory/{r}?expand=1", f'<directory name="{r}">{entries(held)}</directory>')
        put(os.path.join(state, "gate", "obs", r, GD + ".json"), json.dumps({
            "project": GD, "package": r, "verdict": "GREEN", "files": synced, "tree": "0" * 64,
            "review": {"verdict": "PASS"}, "build": {"verdict": "GREEN", "kind": "log"}}))
    if p["verdict"]:
        part = {"gitea": {"owner": o, "repo": r, "number": n, "head": p["head"], "base": "b" * 40,
                          "merge_base": "b" * 40, "files": files}}
        name = "_".join(x.lower().replace("%", "%25").replace("_", "%5F") for x in (o, r))
        stamp("gitea", f"{name}_{n}", f"{o}/{r}#{n}", p["author"], p["verdict"], part, p.get("comment", ""))
for rel, text in s["files"].items():
    put(os.path.join(scripts, rel), text)
for name, target in s["links"].items():
    os.symlink(os.path.join(scripts, target), os.path.join(scripts, name))
put(os.path.join(work, "badhome", sd, "incoming", "obs", "1391099.json"), "{")
put(os.path.join(work, "listless", sd, "incoming", "obs"), "not a directory\n")
PY
# A harmless prog.sh beside lnk, and through lnk's .. (deep/) one that pushes a PR head.
printf 'echo hi\n' > "$W/prog.sh"
printf 'git -C %s/clone push fork tess-88053-16.0\n' "$work" > "$W/deep/prog.sh"

# ev <name>: the fixture event, placeholders filled in.
ev() {
  python3 -c 'import json, sys
text = json.dumps(json.load(open(sys.argv[2]))[sys.argv[1]])
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1)
    text = text.replace("@%s@" % k, v)
print(text)' "$1" "$FX/events.json" CLONE="$work/clone" TRACK="$work/track" \
    OTHER="$work/other" BROKEN="$work/broken" MANY="$work/many" ODD="$work/odd" \
    GITHUB="$work/github" STRANGER="$work/stranger" MAPPED="$work/mapped" \
    REFSPEC="$work/refspec" ONPR="$work/onpr" PDEF="$work/pdef" PLAIN="$work/plain" \
    WORK="$W" SKILL="$S" BARE="$work/barerepo" TOKENED="$work/tokened" OSC="$work/osc" \
    DEVEL="$work/devel" MSGS="$FX/messages" HOME="$HOME" LINKS="$work/links" \
    HTTPS="$work/https" TOKFORK="$work/tokfork"
}

# case_ <event> <rc> <rule|-> <detail> [VAR=value ...]
# rc 0: allowed, silently. rc 2: refused, and the message names the rule (and
# the detail) -- a refusal by some other rule proves nothing about this one.
case_() {
  local name=$1 rc=$2 rule=$3 detail=$4 event out got; shift 4
  used="$used$name "
  event="$(ev "$name")" || { fail "$name: no such event"; return; }
  out="$(printf '%s' "$event" | env "$@" python3 "$GUARD" 2>&1)"; got=$?
  if [ "$rc" = 0 ]; then
    [ "$got" = 0 ] && [ -z "$out" ] && pass "$name (allowed)" || {
      fail "$name: expected allowed, got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
    return
  fi
  [ "$got" = "$rc" ] && grep -qF -- "BLOCKED [$rule]" <<<"$out" && grep -qF -- "$detail" <<<"$out" \
    && pass "$name (rc=$rc, $rule)" || {
      fail "$name: expected rc=$rc [$rule] '$detail', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}

# ask_ <event> <rule> <detail> [VAR=value ...]: allowed only on the user's go --
# rc 0 and the hook's "ask" decision on stdout, naming the rule and the detail.
ask_() {
  local name=$1 rule=$2 detail=$3 event out got; shift 3
  used="$used$name "
  event="$(ev "$name")" || { fail "$name: no such event"; return; }
  out="$(printf '%s' "$event" | env "$@" python3 "$GUARD" 2>&1)"; got=$?
  [ "$got" = 0 ] && python3 -c 'import json, sys
d = json.loads(sys.stdin.read())["hookSpecificOutput"]
why = d["permissionDecisionReason"]
assert d["hookEventName"] == "PreToolUse" and d["permissionDecision"] == "ask"
assert why.startswith("pr-guard: ASK [") and "ASK [%s]" % sys.argv[1] in why and sys.argv[2] in why' \
    "$rule" "$detail" <<<"$out" 2>/dev/null && pass "$name (ask, $rule)" || {
      fail "$name: expected an ask [$rule] '$detail', got rc=$got"; printf '%s\n' "$out" | sed 's/^/    /'; }
}

echo "--- pushes, judged by where they land"
case_ push-tesseract-rtk        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-url-to-pr-head       2 push-pr-head "pool/tesseract-ocr#4"
case_ push-agit-refs-for        2 push-pool    "naming pool/ or AGit refs"
case_ push-pool-url             2 push-pool    "naming pool/ or AGit refs"
case_ push-pool-remote          2 push-pool    "a push to $F/pool/tesseract-ocr.git"
case_ push-bare-tracking        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-all-branches         2 push-pr-head "pool/tesseract-ocr#3"
case_ push-head-refspec         2 push-pr-head "pool/tesseract-ocr#3"
case_ push-upstream-mapping     2 push-pr-head "pool/tesseract-ocr#3"
case_ push-inline-remote        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-git-C                2 push-pr-head "pool/tesseract-ocr#3"
# GIT_DIR or GIT_WORK_TREE assigned on git itself, ~ and $PWD expanded as bash does:
# the push is judged there and where git runs (a repository there); refused if either
# heads a pool PR. Any other form in the call -- env, exec -c, sudo, a wrapper, a
# function, export, unset, a loop, a trap, a nameref, let, (( )), a subscript -- and
# GIT_COMMON_DIR or GIT_CONFIG_* in any form refuse the push: the guard cannot place it.
case_ push-git-dir-prefix       2 push-pr-head "pool/tesseract-ocr#3"
case_ push-git-dir-elsewhere    2 push-pr-head "pool/tesseract-ocr#3"
case_ push-git-dir-tilde        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-git-dir-no-repo      2 push-pr-head "pool/tesseract-ocr#3"
case_ push-git-dir-harmless     0 - ""
case_ push-git-dir-same         0 - ""
case_ push-git-dir-unknown      2 push-unknown "GIT_DIR is set to a value the guard cannot read"
for name in push-git-dir-env push-git-dir-export push-git-dir-bash-c push-git-dir-env-unset \
    push-git-dir-exec-c push-git-dir-exec push-git-dir-systemd-run push-git-dir-setpriv \
    push-git-dir-sudo push-git-dir-command push-git-dir-subshell-unset push-git-dir-cond-unset \
    push-git-dir-pipe-unset push-git-dir-func-export push-git-dir-func-prefix \
    push-git-dir-loop-after push-git-dir-trap push-git-dir-declare-x push-git-dir-subscript; do
  case_ "$name" 2 push-unknown "GIT_DIR is set in the call other than on the git command itself"
done
# A nameref or arithmetic refuses any push in its call (below), GIT_DIR named or not.
case_ push-git-dir-nameref      2 push-unknown "the call holds a nameref"
case_ push-git-dir-arith        2 push-unknown "the call holds an arithmetic context"
case_ push-git-dir-let          2 push-unknown "the call holds an arithmetic context"
case_ push-common-dir           2 push-unknown "GIT_COMMON_DIR is set in the call"
case_ push-common-dir-head      2 push-unknown "GIT_COMMON_DIR is set in the call"
case_ push-config-env           2 push-unknown "GIT_CONFIG_COUNT is set in the call"
# A variable set by a name not written out (GIT_$v, a brace, a substitution, xargs'
# env {}=) may be GIT_DIR: every push in that call is refused, one run before it too.
for name in push-dyn-var-export push-dyn-brace-export push-dyn-printf-env push-dyn-var-env \
    push-dyn-xargs-env push-dyn-append push-dyn-loop-after; do
  case_ "$name" 2 push-unknown "sets a variable whose name only the shell knows"
done
case_ push-git-dir-read         0 - ""
# ~+ is the call's directory; ~- and a ~ form expanduser() leaves are not read.
case_ push-git-dir-tilde-plus   2 push-pr-head "pool/tesseract-ocr#3"
case_ push-git-dir-tilde-minus  2 push-unknown "GIT_DIR is set to a value the guard cannot read"
# Ways to set a variable by a name the guard never sees refuse every push in the call:
# a nameref, allexport, an arithmetic context, xargs, env given a word only the shell
# knows. Without a push, as the main session's own arithmetic, they pass.
for name in push-nameref-target push-nameref-for push-nameref-gn push-nameref-local \
    push-nameref-typeset; do
  case_ "$name" 2 push-unknown "the call holds a nameref"
done
for name in push-allexport-arith push-allexport-let push-allexport-test \
    push-allexport-declare-i push-allexport-expansion push-allexport-subscript \
    push-allexport-o; do
  case_ "$name" 2 push-unknown "the call holds allexport"
done
for name in push-arith push-arith-test push-arith-declare-i push-arith-subscript; do
  case_ "$name" 2 push-unknown "the call holds an arithmetic context"
done
case_ push-xargs-env-word       2 push-unknown "the call holds xargs"
case_ push-env-dynamic-value    2 push-unknown "the call holds env with a word only the shell knows"
case_ main-arith-no-push        0 - ""
# A script read from a directory reached through a link: its .. is where bash finds it.
for name in script-dotdot-pipe script-dotdot-stdin script-dotdot-run script-dotdot-source; do
  case_ "$name" 2 push-pr-head "pool/tesseract-ocr#3"
done
case_ script-pipe-control       0 - ""
case_ push-bash-c               2 push-pr-head "pool/tesseract-ocr#3"
case_ push-shell-heredoc        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-substitution         2 push-pr-head "pool/tesseract-ocr#3"
case_ push-cwd-unknown          2 push-unknown "the working directory is unknown"
case_ push-no-such-remote       2 push-unknown "no remote 'fork'"
case_ push-lookup-fails         2 push-unknown "could not list the open PRs of pool/broken-pkg"
case_ push-lookup-too-many      2 push-unknown "50+ open PRs"
case_ push-lookup-not-a-list    2 push-unknown "unexpected open-PR list for pool/odd-pkg"
case_ push-all-outside-clone    2 push-unknown "cannot list the local branches"
case_ push-pool-in-python       2 push-pool    "naming pool/ or AGit refs"
case_ push-in-python            2 push-unknown "inside program text"
case_ push-configured-refspec   2 push-unknown "cannot tell which branch"
case_ push-git-c                2 push-pr-head "pool/tesseract-ocr#3"
case_ push-refs-heads           2 push-pr-head "pool/tesseract-ocr#3"
case_ push-force-refspec        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-push-default         2 push-pr-head "pool/tesseract-ocr#3"
case_ push-bare-origin          2 push-pool    "a push to $F/pool/tesseract-ocr.git"
case_ push-repo-option          2 push-pr-head "pool/tesseract-ocr#3"
case_ push-repo-option-eq       2 push-pr-head "pool/tesseract-ocr#3"
case_ push-pool-ssh             2 push-pool    "naming pool/ or AGit refs"
case_ push-ssh-fork             2 push-pr-head "pool/tesseract-ocr#4"
case_ push-eval                 2 push-pr-head "pool/tesseract-ocr#3"
case_ push-nohup                2 push-pr-head "pool/tesseract-ocr#3"
case_ push-timeout              2 push-pr-head "pool/tesseract-ocr#3"
case_ push-rtk-run              2 push-pr-head "pool/tesseract-ocr#3"
case_ push-rtk-err              2 push-pr-head "pool/tesseract-ocr#3"
case_ push-env-split            2 push-pr-head "pool/tesseract-ocr#3"
case_ push-env-unset            2 push-pr-head "pool/tesseract-ocr#3"
case_ push-wildcard-refspec     2 push-pr-head "pool/tesseract-ocr#3"
case_ push-wildcard-star        2 push-pr-head "pool/tesseract-ocr#3"
case_ push-wildcard-prefix      2 push-pr-head "pool/tesseract-ocr#3"
case_ push-matching-colon       2 push-pr-head "pool/tesseract-ocr#3"
case_ push-matching-default     2 push-pr-head "pool/tesseract-ocr#3"
case_ push-mirror               2 push-pr-head "pool/tesseract-ocr#3"
case_ push-send-pack            2 push-pr-head "pool/tesseract-ocr#3"
case_ push-send-pack-matching   2 push-pr-head "pool/tesseract-ocr#3"
case_ push-send-pack-remote     2 push-pr-head "pool/tesseract-ocr#3"
case_ push-host-case            2 push-pr-head "pool/tesseract-ocr#3"
case_ push-wildcard-outside-clone 2 push-unknown "cannot list the local branches"
case_ push-wildcard-no-pr       0 - ""
case_ push-in-python-github-cwd 2 push-unknown "inside program text"
case_ push-in-python-github-var 2 push-unknown "inside program text"
case_ push-in-python-github     0 - ""
case_ push-in-python-github-string 0 - ""
case_ push-wip                  0 - ""
case_ push-leapgate             0 - ""
case_ push-not-in-pool          0 - ""
case_ push-other-forge          0 - ""
case_ push-same-name-other-fork 0 - ""
case_ push-in-comment           0 - ""
case_ quoted-backticks          0 - ""
case_ stash-push-rtk            0 - ""
case_ stash-push-bash-c         0 - ""
case_ stash-push-naming-pool    0 - ""
# Repairing a PR whose LFS object never reached the forge: upload the objects
# (git lfs push is no git push), then amend and force-push a devel-org or fork
# branch to retrigger the sync. Only a pool PR's head stays refused.
case_ lfs-push-object-id        0 - ""
case_ lfs-push-all              0 - ""
# Read as a push this would be refused: --all takes in a branch that heads pool PR #3.
case_ lfs-push-all-fork-pr-clone 0 - ""
case_ push-force-lease-devel    0 - ""
case_ push-force-lease-fork     0 - ""
case_ push-force-lease-pool-head 2 push-pr-head "pool/js-pkg#7"
# An HTTPS push needs a token, which an agent never handles: over SSH it passes as before.
case_ push-https-url            2 push-https   "a push to $F/someone/other-pkg.git"
case_ push-http-url             2 push-https   "a push to http://src.opensuse.org/someone/other-pkg.git"
case_ push-https-remote         2 push-https   "a push to fork ($F/someone/nodejs-electron.git)"
case_ push-https-origin         2 push-https   "git remote set-url <remote> gitea@src.opensuse.org:<owner>/<repo>.git"
case_ push-ssh-url-other        0 - ""
case_ push-ssh-scheme-other     0 - ""
# The fix the refusal names, in the same call: the push then goes over SSH.
case_ push-https-set-url-first  0 - ""
echo "--- a refusal prints no credential"
case_ push-token-remote         2 push-pool    "a push to https://user:[REDACTED]@src.opensuse.org/pool/x.git"
case_ push-token-query          2 push-unknown "x.git?access_token=[REDACTED] is named by a variable"
case_ push-https-token-remote   2 push-https   "a push to fork (https://user:[REDACTED]@src.opensuse.org/someone/x.git)"
# A token in the push URL itself: refused as an HTTPS push, which says what to do instead.
case_ push-https-token-url      2 push-https   "a push to https://someone:[REDACTED]@src.opensuse.org/someone/other-pkg.git"
# Whatever a message echoes is redacted, a script path included.
case_ redact-authorization-token 2 exec-unreadable "Authorization: token [REDACTED]"
case_ redact-bearer             2 exec-unreadable "Bearer [REDACTED]"
for name in push-token-remote push-token-query push-https-token-remote push-https-token-url \
  redact-authorization-token redact-bearer; do
  out="$(ev "$name" | python3 "$GUARD" 2>&1)"
  grep -qF tok3n <<<"$out" && fail "$name: the refusal prints the token" || pass "$name: token redacted"
done
echo "--- the hook's cwd: two calls, one call, subshells"
case_ cd-call-1                 0 - ""
case_ cd-call-2                 2 push-pr-head "pool/tesseract-ocr#3"
case_ cd-call-2-elsewhere       0 - ""
case_ cd-same-call              2 push-pr-head "pool/tesseract-ocr#3"
case_ cd-subshell-restores      2 push-pr-head "pool/tesseract-ocr#3"
case_ cd-subshell-contained     0 - ""
case_ push-cd-dash              2 push-unknown "the working directory is unknown"
case_ push-popd                 2 push-unknown "the working directory is unknown"

echo "--- the live open-PR lookup, answered in-process (a dead proxy keeps it offline)"
N=(PYTHONPATH="$FX/net" PR_GUARD_PULLS_DIR= https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9)
case_ push-live-lookup 2 push-pr-head "pool/tesseract-ocr#3" "${N[@]}" NET_STUB="$work/prs"
case_ push-live-lookup 0 - ""                                "${N[@]}" NET_STUB=404
case_ push-live-lookup 2 push-unknown "could not list the open PRs of pool/tesseract-ocr" "${N[@]}" NET_STUB=500

echo "--- merges"
case_ merge-gitoxide            2 merge-tea     "not even their own"
case_ merge-gitoxide-pulls      2 merge-tea     "sr-status.py --pr"
case_ merge-smoke-pool          2 merge-tea     "tea PR merge"
case_ merge-no-repo-pool-clone  2 merge-tea     "tea PR merge"
case_ merge-no-repo-no-clone    2 merge-tea     "tea PR merge"
case_ merge-urllib-pool         2 merge-api     "API merge"
case_ merge-do-payload-only     2 merge-api     "API merge"
case_ merge-git-obs             2 merge-git-obs "git-obs PR merge"
case_ merge-tea-alias-m         2 merge-tea     "tea PR merge"
case_ merge-tea-pull            2 merge-tea     "tea PR merge"
case_ merge-tea-owner-case      2 merge-tea     "tea PR merge"
case_ merge-curl-url            2 merge-api     "API merge"
case_ merge-do-keyword          2 merge-api     "API merge"
case_ merge-api-split-url       2 merge-api     "API merge"
# Any repository's PR, not only pool's: merging one is never an agent's job.
case_ merge-smoke-ai            2 merge-tea     "tea PR merge"
case_ merge-ai-mistral-vibe     2 merge-tea     "tea PR merge"
case_ merge-no-repo-ai-clone    2 merge-tea     "tea PR merge"
case_ merge-git-obs-ai          2 merge-git-obs "git-obs PR merge"
case_ merge-tea-own-fork        2 merge-tea     "tea PR merge"
case_ merge-control-checkout    0 - ""
# tea's subcommand decides, not words further on: a description or comment may quote one.
case_ tea-create-describes-merge 0 - ""
# Program text is searched wider: an argument list may split the words any way.
case_ prog-node-execfilesync-merge 2 merge-tea  "tea PR merge"
case_ prog-node-spawn-create    2 create-tea    "tea PR create"
case_ prog-python-concat-merge  2 merge-tea     "tea PR merge"
case_ write-script-node-merge   2 merge-tea     "a script running a tea PR merge"
ask_ tea-comment-quotes-merge  comment "tea comment"
case_ tea-issue-quotes-create   0 - ""
case_ tea-global-option-merge   2 merge-tea     "tea PR merge"
case_ merge-urllib-ai           2 merge-api     "API merge"
case_ merge-web-ai              2 merge-api     "API merge"
case_ merge-curl-ai             2 merge-api     "API merge"
case_ merge-git-obs-api-ai      2 merge-api     "API merge"
case_ merge-git-obs-space-api-ai 2 merge-api    "API merge"
case_ merge-tea-api-ai          2 merge-api     "API merge"
case_ merge-tea-api-pool        2 merge-api     "API merge"
case_ merge-do-payload-ai-clone 2 merge-api     "API merge"
case_ merge-api-control-get-pr  2 api-direct "curl to src.opensuse.org/api"
case_ merge-api-control-tea-get 0 - ""
# A merge URL held in variables this call set is judged by its value.
case_ merge-curl-var-ai         2 merge-api     "API merge"
# A merge URL is a merge unless the call provably only reads: no method but GET or
# HEAD and no body option, in any spelling (attached, clustered, a prefix).
case_ merge-curl-attached-d     2 merge-api     "API merge"
# On pool or an unnamed repository a merge URL is refused however it is read, as on
# main; elsewhere a read is proven only without a config that may add a method or
# body (curl -q first, wget --no-config) or a stdin HTTPie would send.
case_ merge-pool-http-stdin     2 merge-api     "API merge"
case_ merge-pool-xh-stdin       2 merge-api     "API merge"
case_ merge-ai-http-implicit    2 merge-api     "API merge"
case_ merge-ai-curl-no-q        2 merge-api     "API merge"
case_ merge-ai-wget-config      2 merge-api     "API merge"
# A URL is read decoded, with // collapsed and dot segments removed; "do" is any case.
case_ merge-ai-pct-encoded      2 merge-api     "API merge"
case_ merge-ai-dot-segment      2 merge-api     "API merge"
case_ merge-ai-double-slash     2 merge-api     "API merge"
case_ merge-ai-do-lowercase     2 merge-api     "API merge"
case_ merged-check-other-curl-q 0 - ""
case_ merged-check-other-http-get 0 - ""
case_ merged-check-other-http-ignore-stdin 0 - ""
case_ merged-check-other-wget-no-config 0 - ""
case_ merged-check-ai-git-obs   0 - ""
case_ merged-check-other-script-curl-sf 0 - ""
# On src.opensuse.org itself such a read goes through git-obs, not curl or HTTPie.
case_ merged-check-ai-curl-q    2 api-direct "curl to src.opensuse.org/api"
case_ merged-check-ai-http-get  2 api-direct "http to src.opensuse.org/api"
case_ merged-check-ai-http-ignore-stdin 2 api-direct "http to src.opensuse.org/api"
case_ merged-check-ai-wget-no-config 2 api-direct "wget to src.opensuse.org/api"
case_ merged-check-ai-script-curl-sf 2 api-direct "curl to src.opensuse.org/api"
case_ merge-curl-attached-F     2 merge-api     "API merge"
case_ merge-curl-cluster-X      2 merge-api     "API merge"
case_ merge-curl-request-prefix 2 merge-api     "API merge"
case_ merge-wget-post-prefix    2 merge-api     "API merge"
case_ merge-wget-method-prefix  2 merge-api     "API merge"
case_ merge-git-obs-meth-prefix 2 merge-api     "API merge"
case_ merge-git-obs-dat-prefix  2 merge-api     "API merge"
case_ merge-git-obs-space-meth  2 merge-api     "API merge"
case_ merge-tea-api-attached-f  2 merge-api     "API merge"
case_ merge-tea-api-go-method   2 merge-api     "API merge"
case_ merge-python-opener       2 merge-api     "API merge"
case_ merged-check-curl-cluster 2 merge-api "API merge"
case_ merged-check-curl-head 2 merge-api "API merge"
case_ merged-check-git-obs-meth-get 2 merge-api "API merge"
case_ merged-check-tea-api-get 2 merge-api "API merge"
case_ merged-check-wget 2 merge-api "API merge"
case_ merge-tea-api-var-ai      2 merge-api     "API merge"
case_ merge-git-obs-api-var-ai  2 merge-api     "API merge"
case_ merge-git-obs-space-api-var-ai 2 merge-api "API merge"
# A literal GET of /pulls/N/merge only asks whether the PR is merged.
case_ merged-check-curl 2 merge-api "API merge"
case_ merged-check-curl-get 2 merge-api "API merge"
case_ merged-check-tea-api      0 - ""
case_ merged-check-git-obs-api 2 merge-api "API merge"
case_ merged-check-python 2 merge-api "API merge"
case_ merge-in-comment          0 - ""
# An argument list: the repository option and its value are separate strings.
case_ list-tea-merge            2 merge-tea      "tea PR merge"
case_ list-tea-merge-r          2 merge-tea      "tea PR merge"
case_ list-tea-create           2 create-tea     "tea PR create"
case_ list-git-obs-create       2 create-git-obs "PR create towards pool"
case_ list-tea-merge-ai         2 merge-tea      "tea PR merge"
case_ list-tea-create-ai        0 - ""
# A Python string prefix, and {placeholders}: the literal owner before the slash decides.
case_ list-tea-create-fstring   2 create-tea     "tea PR create"
case_ list-tea-merge-fstring    2 merge-tea      "tea PR merge"
case_ list-git-obs-merge-fstring 2 merge-git-obs "git-obs PR merge"
case_ list-git-obs-merge-owner-placeholder 2 merge-git-obs "git-obs PR merge"
case_ list-tea-merge-fstring-ai 2 merge-tea      "tea PR merge"
case_ list-tea-create-fstring-ai 0 - ""

echo "--- text a command only carries is not a command"
case_ carried-echo-merge          0 - ""
case_ carried-commit-osc-build    0 - ""
case_ carried-log-grep-backports  0 - ""
case_ carried-grep-merge          0 - ""
case_ carried-commit-heredoc      0 - ""
case_ carried-commit-subst-heredoc 0 - ""
case_ carried-perl-pe             0 - ""
case_ carried-perl-ne             0 - ""
case_ carried-perl-i-pe           0 - ""
case_ carried-perl-lane           0 - ""
case_ carried-python-Im           0 - ""
case_ carried-node-pe             0 - ""
case_ carried-then-merge          2 merge-tea "tea PR merge"
case_ carried-perl-e-merge        2 merge-tea "tea PR merge"
case_ carried-if-merge            2 merge-tea "tea PR merge"
case_ carried-xargs-merge         2 merge-tea "tea PR merge"
case_ parse-case-patterns         0 - ""
case_ parse-arithmetic            0 - ""
case_ parse-bash-n                0 - ""
case_ parse-case-clause           2 merge-tea "tea PR merge"
case_ parse-array-literal         0 - ""
case_ parse-array-then-subshell   2 push-pr-head "pool/tesseract-ocr#3"
case_ parse-quoted-heredoc        2 push-pr-head "pool/tesseract-ocr#3"
case_ parse-quoted-then-heredoc   2 push-pr-head "pool/tesseract-ocr#3"

echo "--- text fed to a shell or interpreter is a program"
# A trap's command runs in this shell, as an eval string does.
case_ trap-merge                2 merge-git-obs "a git-obs PR merge"
case_ trap-signal-merge         2 merge-tea "tea PR merge"
ask_ trap-comment               comment "tea comment"
case_ trap-cleanup              0 - ""
case_ trap-reset                0 - ""
case_ trap-list                 0 - ""
# An eval or trap string the guard cannot read is asked about; one it can is judged, and
# so is a command word (eval, trap, bash) held in a variable the call sets.
m=mer; printf 'git-obs pr %sge pool/x#5\n' "$m" > "$W/merge-cmd.txt"
case_ coproc-merge              2 merge-git-obs "a git-obs PR merge"
ask_ eval-dynamic-subst         eval-dynamic "eval"
ask_ trap-dynamic-merge         eval-dynamic "trap"
ask_ eval-dynamic-unset         eval-dynamic "eval"
ask_ eval-ssh-agent             eval-dynamic "eval"
ask_ eval-known-var             comment "tea comment"
ask_ eval-var-command           comment "tea comment"
ask_ trap-var-command           comment "tea comment"
ask_ bash-var-command           comment "tea comment"
case_ eval-literal              0 - ""
# Any & or coproc in the call: every write in it may run while the commit does.
case_ ci-if-background         2 retired-osc "an osc command"
case_ ci-for-background        2 retired-osc "an osc command"
case_ ci-and-background        2 retired-osc "an osc command"
case_ ci-subst-background      2 retired-osc "an osc command"
case_ ci-coproc-named          2 retired-osc "an osc command"
# A command word only the shell knows, given a judged tool or a runner to start.
ask_ dyn-subst-command          eval-dynamic "the command word is unknown"
ask_ dyn-var-command            eval-dynamic "the command word is unknown"
case_ dyn-path-script           0 - ""
# Unknown words in argument positions leave the commands readable.
case_ trap-mktemp               0 - ""
case_ eval-arg-var              0 - ""
case_ fed-cat-heredoc-bash        2 push-pr-head "pool/tesseract-ocr#3"
case_ fed-here-string             2 push-pr-head "pool/tesseract-ocr#3"
case_ fed-echo-sh                 2 push-pr-head "pool/tesseract-ocr#3"
case_ fed-printf-bash             2 push-pr-head "pool/tesseract-ocr#3"
case_ fed-heredoc-expands         2 push-pr-head "pool/tesseract-ocr#3"
case_ fed-python-file             2 create-api "a write to pool pulls"
case_ fed-bash-s-file             2 create-api "a write to pool pulls"
case_ fed-cat-file-bash           2 create-api "a write to pool pulls"
case_ fed-stderr-redirect         2 create-api "a write to pool pulls"
case_ fed-unknown-pipe            2 exec-unreadable "the program sh reads from curl"
case_ fed-process-substitution    2 exec-unreadable "/dev/fd/63"
case_ fed-python-stdin-read       0 - ""

echo "--- tea and git-obs act on the clone a cd, subshell or env -C leaves"
case_ cwd-tea-merge               2 merge-tea      "tea PR merge"
case_ cwd-git-obs-merge           2 merge-git-obs  "git-obs PR merge"
case_ cwd-subshell-tea-create     2 create-tea     "tea PR create"
case_ cwd-variable-tea-merge      2 merge-tea      "tea PR merge"
case_ cwd-env-C-tea-merge         2 merge-tea      "tea PR merge"
case_ cwd-remote-added            2 merge-tea      "tea PR merge"
case_ cwd-away-from-pool          2 merge-tea      "tea PR merge"
case_ cwd-away-from-pool-create   0 - ""

echo "--- what a variable holds is unknown"
case_ var-push-loop               2 push-unknown "the pushed branch is held in a variable"
case_ var-push-branch             2 push-unknown "the pushed branch is held in a variable"
case_ var-push-url-owner          2 push-unknown "is named by a variable"
case_ var-tea-repo                2 merge-tea     "tea PR merge"
case_ var-git-obs-id              2 merge-git-obs "git-obs PR merge"
case_ var-curl-url                2 create-api    "a write to pool pulls"
case_ var-command-name            2 merge-tea     "tea PR merge"
case_ var-pr-number-ai            2 merge-tea     "tea PR merge"

echo "--- git obs, as git runs it"
case_ gitobs-space-merge          2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-create         2 create-git-obs "PR create towards pool"
case_ gitobs-space-forward        2 create-git-obs "PR forward on pool"
case_ gitobs-space-no-slash       2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-C              2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-python         2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-ai             2 merge-git-obs  "git-obs PR merge"
case_ gitobs-space-create-ai      0 - ""

echo "--- creates"
case_ create-tesseract          2 create-tea       "pool-pr.sh DIR"
case_ create-python-heredoc     2 create-api       "pool-pr.sh DIR"
case_ create-curl-heredoc       2 create-api       "a write to pool pulls"
case_ create-curl-short-body    2 create-api       "a write to pool pulls"
case_ create-tea-api            2 create-tea-api   "tea api write"
case_ create-api-variable-owner 2 create-api       "a write to pool pulls"
case_ create-git-obs-untargeted 2 create-git-obs   "PR create towards pool"
case_ create-git-obs-forward    2 create-git-obs   "PR forward on pool"
case_ create-tea-alias-c        2 create-tea       "pool-pr.sh DIR"
case_ create-tea-api-field      2 create-tea-api   "tea api write"
case_ create-tea-api-method     2 create-tea-api   "tea api write"
case_ create-curl-update-branch 2 create-api       "a write to pool pulls"
case_ create-curl-data          2 create-api       "a write to pool pulls"
case_ create-python-argv        2 create-api       "a write to pool pulls"
case_ create-python-requests    2 create-api       "a write to pool pulls"
# Past the pool rules, the PR's text is held to a request message's (see below):
# this real body, build status included, is refused on any repository.
case_ create-ai-mistral-vibe    2 pr-message "create description with 357 characters of prose"
case_ create-git-obs-ai         0 - ""
case_ create-git-obs-target-owner-ai 0 - ""
case_ create-tea-api-ai         0 - ""
case_ get-tea-list              0 - ""
case_ get-tea-api               0 - ""
# Past the pool rules, curl on the Gitea API and a token header are refused.
case_ create-curl-short-ai      2 api-direct  "curl to src.opensuse.org/api"
case_ get-curl-pulls            2 api-direct  "curl to src.opensuse.org/api"
case_ post-fork                 2 auth-header "curl with a credential header (Authorization)"
case_ post-lfs-batch            2 auth-header "curl with a credential header (Authorization)"

echo "--- any request to pool pulls but a literal GET is a write"
case_ write-curl-method-var     2 create-api "a write to pool pulls"
case_ write-curl-form           2 create-api "a write to pool pulls"
case_ write-curl-upload         2 create-api "a write to pool pulls"
case_ write-curl-json           2 create-api "a write to pool pulls"
case_ write-urllib-positional   2 create-api "a write to pool pulls"
case_ write-requests-request    2 create-api "a write to pool pulls"
case_ write-requests-method-var 2 create-api "a write to pool pulls"
case_ write-httpx               2 create-api "a write to pool pulls"
case_ write-http-client         2 create-api "a write to pool pulls"
case_ write-httpie-post         2 create-api "a write to pool pulls"
case_ write-httpie-implicit     2 create-api "a write to pool pulls"
case_ write-httpie-auth-patch   2 create-api "a write to pool pulls"
case_ write-tea-api-method-var  2 create-tea-api "tea api write"
case_ write-js-method-var       2 create-api "a write to pool pulls"
case_ write-close-pool-pr       2 create-api "a write to pool pulls"
# A body option counts on a curl, wget or tea api command, or in its argument list.
case_ write-curl-json-body      2 create-api "a write to pool pulls"
case_ write-curl-json-list      2 create-api "a write to pool pulls"
case_ write-tea-api-data-list   2 create-api "a write to pool pulls"
case_ json-flag-run             0 - ""
case_ post-comment-links-pr     0 - ""
case_ post-bugzilla-links-pr    0 - ""
# Only a stand-in that still sends the request, with nothing else to refuse, proves the case.
# shellcheck disable=SC2016  # the $method is the script's, matched literally
if grep -qF -- '-X "$method"' "$W/pp-nogate.sh" && ! grep -qe ' push ' -e 'target-gate\.sh' "$W/pp-nogate.sh"; then
  case_ write-real-pool-pr-nogate 2 create-api "a write to pool pulls"
else
  fail "pool-pr.sh no longer sends its PR request with a variable method; rebuild the stand-in"
  used="${used}write-real-pool-pr-nogate "
fi
case_ get-urllib                0 - ""
case_ get-requests              0 - ""
case_ get-http-client           0 - ""
case_ get-httpie                2 api-direct "http to src.opensuse.org/api"
case_ get-httpie-query          2 api-direct "http to src.opensuse.org/api"
case_ get-curl-query            2 api-direct "curl to src.opensuse.org/api"

echo "--- scripts: written, then run, in every form"
case_ write-script              2 create-api      "a script writing to pool pulls"
case_ edit-script-merge         2 merge-tea       "a script running a tea PR merge"
case_ write-merge-script        2 merge-api       "a script merging a PR"
case_ write-merge-script-ai     2 merge-api       "a script merging a PR"
case_ write-script-tea-create   2 create-tea      "a script running a tea PR create"
case_ write-doc                 0 - ""
case_ write-script-ai-merge     2 merge-tea       "a script running a tea PR merge"
case_ write-script-ai-create    0 - ""
case_ write-script-tea-api-data 2 create-api      "a script writing to pool pulls"
case_ json-flag-write           0 - ""
case_ run-bash                  2 create-api      "a write to pool pulls"
case_ run-dot-slash             2 create-api      "a write to pool pulls"
case_ run-source                2 create-api      "a write to pool pulls"
case_ run-env                   2 create-api      "a write to pool pulls"
case_ run-python                2 create-api      "a write to pool pulls"
case_ run-python-bsnl-split     2 create-api      "a write to pool pulls"
case_ run-python-bsnl-comment   2 create-api      "a write to pool pulls"
case_ run-uv                    2 create-api      "a write to pool pulls"
case_ run-node                  2 create-api      "a write to pool pulls"
case_ run-nested                2 create-api      "a write to pool pulls"
case_ run-dot-slash-py          2 create-api      "a write to pool pulls"
case_ run-perl                  2 create-api      "a write to pool pulls"
case_ run-source-word           2 create-api      "a write to pool pulls"
case_ run-bash-option           2 create-api      "a write to pool pulls"
case_ run-python-option         2 create-api      "a write to pool pulls"
case_ run-agit-script           2 push-pool       "naming pool/ or AGit refs"
case_ run-script-merge          2 merge-tea       "tea PR merge"
# An array that appends to itself spells its own name: no endless re-entry,
# and what it ends up running is still judged.
case_ run-self-append           0 - ""
case_ run-self-append-merge     2 merge-tea       "tea PR merge"
# A script's quoted strings are data; only the command line itself is read as text.
case_ run-script-quoting-merge  0 - ""
case_ run-path-shebang          0 - ""
case_ run-path-plain-sh         0 - ""
case_ run-elf                   0 - ""
# Interpreter options that name no script file.
case_ run-python-module         0 - ""
case_ run-bash-stdin-args       0 - ""
case_ run-not-yet-written       2 exec-written    "pp2.sh"
case_ run-missing               2 exec-unreadable "no-such-script.sh"
case_ run-cwd-unknown           2 exec-unreadable "the working directory is unknown"
# A relative path is placed in the event's cwd (or where a cd moved), not the hook's own;
# one that is not there is refused, naming where it was looked for.
case_ run-relative-dot-slash    0 - ""
case_ run-relative-bash         0 - ""
case_ run-relative-after-cd     0 - ""
case_ run-relative-missing      2 exec-unreadable "./scripts/leap-sync.sh ($work/clone/scripts/leap-sync.sh: No such file"

echo "--- a file the call writes does not run in the same call"
case_ written-cat-run           2 exec-written "$W/iter.py"
case_ written-tee-run           2 exec-written "$W/iter.sh"
case_ written-sed-i-run         2 exec-written "$W/iter.sh"
case_ written-echo-run          2 exec-written "iter.sh is written"
case_ written-cp-run            2 exec-written "$W/iter.sh"
case_ written-cp-t-run          2 exec-written "$W/iter.sh"
case_ written-mv-run            2 exec-written "$W/iter.sh"
case_ written-install-run       2 exec-written "$W/iter.sh"
case_ written-perl-i-run        2 exec-written "$W/iter.sh"
case_ written-curl-o-run        2 exec-written "$W/iter.sh"
case_ written-curl-O-run        2 exec-written "iter.sh is written"
case_ written-push-run          2 exec-written "$W/iter.sh"
case_ written-var-run           2 exec-written "\$W/iter.py"
case_ written-dir-run           2 exec-written "$W/copied/pool-pr.sh"
case_ written-source-run        2 exec-written "$W/iter.sh"
case_ written-skill-sibling     2 create-api   "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
case_ written-not-run           0 - ""
case_ written-other-run         0 - ""
case_ written-other-judged      2 create-api   "a write to pool pulls"

echo "--- script paths the shell expands: this call's values, \$PWD, \$TMPDIR, globs"
case_ var-path-assigned         2 create-api "a write to pool pulls"
case_ var-path-for-glob         2 create-api "a write to pool pulls"
case_ var-path-glob             2 create-api "a write to pool pulls"
case_ var-path-python           2 create-api "a write to pool pulls"
case_ var-path-dir              2 create-api "a write to pool pulls"
case_ var-path-export           2 create-api "a write to pool pulls"
case_ var-path-tmpdir           2 create-api "a write to pool pulls" TMPDIR="$W"
case_ var-path-pwd              2 create-api "a write to pool pulls"
case_ var-path-exec             2 create-api "a write to pool pulls"
case_ var-path-unknown          2 exec-unresolved "\$UNSET_DIR/pr.sh"
case_ var-path-tmpdir           2 exec-unresolved "\$TMPDIR/open-pr.sh" TMPDIR=
case_ var-path-substitution     2 exec-unresolved "/b.sh"
case_ var-path-benign           0 - ""
case_ var-path-loop-benign      0 - ""
# Past 64 values a variable is unknown, never cut short.
case_ var-path-loop-64          2 create-api "a write to pool pulls"
case_ var-path-loop-65          2 exec-unresolved "\$f"

echo "--- the skill's scripts: trusted only as merged, run by path, in the checkout"
case_ canonical-pool-pr   0 - ""                          PR_GUARD_SKILL_DIR="$S"
case_ canonical-by-path   0 - ""                          PR_GUARD_SKILL_DIR="$S"
case_ canonical-other-script 0 - ""                       PR_GUARD_SKILL_DIR="$S"
# A link elsewhere to a pinned script runs the siblings beside the link, so it is
# read; a link to the scripts/ directory itself runs the skill's own.
case_ canonical-symlink   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
case_ canonical-dir-link  0 - ""                          PR_GUARD_SKILL_DIR="$S"
case_ canonical-copy      2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
case_ canonical-exact-copy 2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
cp "$FX/pool-pr.sh" "$S/scripts/new-tool.sh"
case_ canonical-untracked 2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
rm "$S/scripts/new-tool.sh"
case_ canonical-sourced   2 canonical-read "read as a program" PR_GUARD_SKILL_DIR="$S"
case_ canonical-fed       2 canonical-read "read as a program" PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-path  2 canonical-env "run with PATH"      PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-build-dir 2 canonical-env "run with BUILD_DIR" PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-command 2 canonical-env "run with PATH"   PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-export 2 canonical-env "run with PATH"    PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-then  2 canonical-env "run with PATH"    PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-clean 0 - ""                          PR_GUARD_SKILL_DIR="$S"
# changes-prepend.sh documents CHANGES_AUTHOR as the way to name the entry's author.
case_ canonical-env-changes-author 0 - ""                 PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-changes-author-export 0 - ""          PR_GUARD_SKILL_DIR="$S"
# The two settings distro-survey.sh documents; the script takes numbers alone.
case_ canonical-env-survey 0 - ""                         PR_GUARD_SKILL_DIR="$S"
case_ canonical-env-survey-export 0 - ""                  PR_GUARD_SKILL_DIR="$S"
case_ canonical-shell-variable 0 - ""                     PR_GUARD_SKILL_DIR="$S"
# A commit that is not merged is not trusted: the pin is origin/main, not HEAD.
echo 'echo edited' >> "$S/scripts/pool-pr.sh"; git -C "$S" commit -qam 'local edit'
case_ canonical-pool-pr   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
case_ canonical-pool-pr   0 - ""                          PR_GUARD_SKILL_DIR="$S" PR_GUARD_PIN_REF=refs/heads/main
git -C "$S" reset -q --hard refs/remotes/origin/main
mkdir -p "$work/h1/.claude/skills" "$work/h2/.agents/skills"
ln -s "$S" "$work/h1/.claude/skills/opensuse-packaging"
ln -s "$S" "$work/h2/.agents/skills/opensuse-packaging"
case_ canonical-pool-pr   0 - ""                          HOME="$work/h1"
case_ canonical-pool-pr   0 - ""                          HOME="$work/h2"
case_ canonical-pool-pr   2 create-api "a write to pool pulls"
echo 'echo edited' >> "$S/scripts/pool-pr.sh"
case_ canonical-pool-pr   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
# An index flag hides the edit from `git diff`, not from the blob hash.
git -C "$S" update-index --assume-unchanged scripts/pool-pr.sh
if git -C "$S" diff --quiet HEAD -- scripts/pool-pr.sh; then
  case_ canonical-pool-pr 2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
else
  fail "assume-unchanged did not hide the edit from git diff; the case proves nothing"
fi
git -C "$S" update-index --no-assume-unchanged scripts/pool-pr.sh
# A clean filter that hashes the edit to the pinned blob hides it from git, not
# from the bytes on disk.
echo 'scripts/pool-pr.sh filter=pin' > "$S/.git/info/attributes"
git -C "$S" config filter.pin.clean "cat $work/pinned-pool-pr.sh"
if [ "$(git -C "$S" hash-object scripts/pool-pr.sh)" = "$(git -C "$S" rev-parse HEAD:scripts/pool-pr.sh)" ]; then
  case_ canonical-clean-filter 2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
else
  fail "the clean filter did not hash the edit to the pinned blob; the case proves nothing"
fi
rm -f "$S/.git/info/attributes"; git -C "$S" config --unset filter.pin.clean
cp "$work/pinned-pool-pr.sh" "$S/scripts/pool-pr.sh"
case_ canonical-pool-pr   0 - ""                          PR_GUARD_SKILL_DIR="$S"
# The scripts run their siblings: one that differs from the pin, or that the
# index tracks and the pin lacks, untrusts them all.
printf 'exit 0\n' > "$S/scripts/target-gate.sh"
case_ canonical-sibling-gutted  2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
git -C "$S" rm -q --cached scripts/target-gate.sh
case_ canonical-sibling-dropped 2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
git -C "$S" reset -q; cp "$work/pinned-gate.sh" "$S/scripts/target-gate.sh"
cp "$FX/pool-pr.sh" "$S/scripts/new-tool.sh"; git -C "$S" add scripts/new-tool.sh
case_ canonical-sibling-added   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
git -C "$S" rm -q --cached scripts/new-tool.sh
case_ canonical-pool-pr   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
rm "$S/scripts/new-tool.sh"
case_ canonical-pool-pr   0 - ""                          PR_GUARD_SKILL_DIR="$S"
# Any file scripts/ does not track runs beside the pinned scripts -- a module named
# like the standard library they import, a sourceless .pyc, ignored or not -- and
# untrusts them all; a __pycache__, which their Python never reads, does not.
printf 'raise SystemExit\n' > "$S/scripts/argparse.py"
case_ canonical-pool-pr   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
mv "$S/scripts/argparse.py" "$S/scripts/argparse.pyc"
case_ canonical-pool-pr   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
echo 'argparse.pyc' > "$S/.git/info/exclude"
case_ canonical-pool-pr   2 create-api "a write to pool pulls" PR_GUARD_SKILL_DIR="$S"
rm "$S/scripts/argparse.pyc" "$S/.git/info/exclude"
mkdir -p "$S/scripts/__pycache__" && printf 'x' > "$S/scripts/__pycache__/_forges.cpython-313.pyc"
case_ canonical-pool-pr   0 - ""                          PR_GUARD_SKILL_DIR="$S"
rm -r "$S/scripts/__pycache__"

echo "--- stamps"
case_ stamp-redirect      2 stamp       "a redirection into the stamp directory"
case_ stamp-gate-output   2 stamp       "a redirection into the stamp directory"
case_ stamp-python        2 stamp       "a command touching the stamp directory"
# Writing a script is not running it; running it is refused.
case_ stamp-heredoc       0 - ""
case_ stamp-script-run    2 stamp       "program text touching the stamp directory"
case_ stamp-write-tool    2 stamp-write "only target-gate.sh writes its stamps"
case_ stamp-gate-call     0 - ""
# The directory named without a trailing slash, from inside it, or in pieces.
case_ stamp-cp-dir        2 stamp       "a command touching the stamp directory"
case_ stamp-cd-printf     2 stamp       "a redirection into the stamp directory"
case_ stamp-cd-cp         2 stamp       "a command touching the stamp directory"
case_ stamp-install-t     2 stamp       "a command touching the stamp directory"
case_ stamp-cp-r          2 stamp       "a command touching the stamp directory"
case_ stamp-var-sed       2 stamp       "a command touching the stamp directory"
case_ stamp-shutil-join   2 stamp       "program text touching the stamp directory"
case_ stamp-python-join   2 stamp       "program text touching the stamp directory"
case_ stamp-heredoc-glob  2 stamp       "program text touching the stamp directory"
case_ stamp-cwd-event     2 stamp       "a redirection into the stamp directory"
case_ stamp-mv-no-slash   2 stamp       "a command touching the stamp directory"
case_ stamp-find-delete   2 stamp       "a command touching the stamp directory"
case_ stamp-find-exec     2 stamp       "a command touching the stamp directory"
case_ stamp-cat-redirect  2 stamp       "a redirection into the stamp directory"
# Looking is not writing.
case_ stamp-read-ls       0 - ""
case_ stamp-read-cat      0 - ""
case_ stamp-read-jq       0 - ""
case_ stamp-read-grep     0 - ""
case_ stamp-read-head-tail 0 - ""
case_ stamp-read-find     0 - ""
case_ stamp-read-cd-ls    0 - ""
case_ stamp-read-cwd-event 0 - ""
case_ stamp-read-rg       0 - ""
case_ stamp-read-wc       0 - ""
case_ stamp-read-json-tool 0 - ""
case_ stamp-read-sed      0 - ""
case_ stamp-read-awk      0 - ""
case_ stamp-var-subst-read 0 - ""
# ... unless it writes a file: its output, sed w, awk print >, an output file.
case_ stamp-read-redirect-unknown 2 stamp "a command touching the stamp directory"
case_ stamp-sed-w         2 stamp       "a command touching the stamp directory"
case_ stamp-awk-redirect  2 stamp       "a command touching the stamp directory"
case_ stamp-json-tool-outfile 2 stamp   "a command touching the stamp directory"
# A path is a stamp path only directly under a git directory; the word alone is text.
case_ stamp-text-rg       0 - ""
case_ stamp-text-git-grep 0 - ""
case_ stamp-text-git-log-grep 0 - ""
case_ stamp-text-git-branch 0 - ""
case_ stamp-text-git-commit 0 - ""
case_ stamp-text-git-commit-path 0 - ""
case_ stamp-text-sed      0 - ""
case_ stamp-text-awk      0 - ""
case_ stamp-text-gh-title 0 - ""
case_ stamp-text-path-elsewhere 0 - ""
case_ stamp-cwd-not-git   0 - ""
case_ stamp-cwd-not-git-make 0 - ""
case_ stamp-git-redirect  2 stamp       "a redirection into the stamp directory"
case_ stamp-git-dir-unnamed 2 stamp     "a command touching the stamp directory"
case_ stamp-unknown-parent 2 stamp      "a command touching the stamp directory"
# A stamp directory held in a variable set from a substitution.
case_ stamp-var-subst-cp  2 stamp       "a command touching the stamp directory"
case_ stamp-cd-subst-printf 2 stamp     "a redirection into the stamp directory"
case_ stamp-cd-subst-sed    2 stamp     "a command touching the stamp directory"
case_ stamp-pushd-subst-cp  2 stamp     "a command touching the stamp directory"
case_ stamp-cd-var-cp       2 stamp     "a command touching the stamp directory"
case_ stamp-env-C-subst-cp  2 stamp     "a command touching the stamp directory"
case_ stamp-read-cd-subst-ls 0 - ""
case_ stamp-var-subst-mkdir 2 stamp     "a command touching the stamp directory"
case_ stamp-var-subst-printf 2 stamp    "a redirection into the stamp directory"
case_ stamp-var-subst-export 2 stamp    "a command touching the stamp directory"
case_ stamp-var-subst-chain 2 stamp     "a command touching the stamp directory"
# Only the skill's own target-gate.sh, as merged, names a stamp freely.
case_ stamp-fake-gate     2 stamp       "a command touching the stamp directory"
case_ stamp-canonical-gate 0 - ""                         PR_GUARD_SKILL_DIR="$S"

echo "--- the state directory: gate.sh's stamps and the incoming reviews', written by their scripts alone"
case_ stamp-write-gate-dir     2 stamp-write "only the skill's own gate.sh"
case_ stamp-edit-incoming-dir  2 stamp-write "only the skill's own gate.sh"
case_ stamp-write-incoming-dir 2 stamp "a redirection into the state directory"
case_ stamp-shell-cp           2 stamp "a command touching the state directory"
case_ stamp-xdg-default        2 stamp "a command touching the state directory"
# Through a link into it, from above it, from inside it, or by a cd it cannot place.
case_ stamp-symlink-write      2 stamp "a command touching the state directory"
case_ stamp-ln-into-state      2 stamp "a command touching the state directory"
case_ stamp-cd-relative        2 stamp "a redirection into the state directory"
case_ stamp-cd-inside-cp       2 stamp "a command touching the state directory"
case_ stamp-cd-unplaced-state  2 stamp "a redirection into the state directory"
case_ stamp-cwd-event-state    2 stamp "a redirection into the state directory"
case_ stamp-cwd-above-mv       2 stamp "a command touching the state directory"
case_ stamp-mv-into-parent     2 stamp "a command touching the state directory"
case_ stamp-cp-state-sibling   0 - ""
case_ stamp-python-state       2 stamp "touching the state directory"
# Looking is not writing, and a git argument is text.
case_ stamp-read-cat-state     0 - ""
case_ stamp-read-cwd-state     0 - ""
case_ stamp-text-state-commit  0 - ""
# The skill's gate.sh writes its stamps only as merged: an edited one is read, and refused.
case_ gate-sh-pinned-writes    0 - ""                     PR_GUARD_SKILL_DIR="$W/state-skill"
case_ gate-sh-pinned-in-state  0 - ""                     PR_GUARD_SKILL_DIR="$W/state-skill"
case_ gate-sh-unpinned-writes  2 stamp "a redirection into the state directory"
case_ gate-sh-unpinned-writes  2 stamp "its scripts/ differ from the pinned ref" \
  PR_GUARD_SKILL_DIR="$W/state-skill" PR_GUARD_PIN_REF=refs/remotes/origin/gone
# Linked from elsewhere, it would run the siblings planted beside the link: read, and refused.
case_ gate-sh-symlinked        2 stamp "run through a link from outside its scripts/" \
  PR_GUARD_SKILL_DIR="$W/state-skill"
case_ gate-sh-symlinked-path   2 stamp "run through a link from outside its scripts/" \
  PR_GUARD_SKILL_DIR="$W/state-skill"
# A write the guard cannot place, in a call that names the state directory in any
# piece, is refused, whatever carries it: xargs, a shell, an interpreter, an array,
# a substitution, a namespace, an fd, /proc, a link made in the call, CDPATH.
for name in state-xargs-echo state-xargs-I state-env-bash-c state-export-py state-array \
    state-param-subst state-brace-tee state-subst-echo state-pwd-subst state-proc-cwd \
    state-dev-fd state-ln-same-call state-bwrap state-unshare state-cd-dirname state-cdpath \
    state-redirect-unplaced; do
  case_ "$name" 2 stamp "state directory"
done
# A destination given with an option is a destination, git's too.
for name in state-cp-target-eq state-ln-target-eq state-dd-of state-sort-o-home \
    state-sort-output-eq state-osc-output state-git-log-output state-git-checkout-index \
    state-git-show-output; do
  case_ "$name" 2 stamp "state directory"
done
# git writes where GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE and core.worktree point,
# and wherever any argument of a bundle create resolves to.
for name in state-git-dir-init state-git-work-tree-export state-git-core-worktree \
    state-git-config-env-worktree state-git-bundle state-git-bundle-version \
    state-git-index-file; do
  case_ "$name" 2 stamp "a command touching the state directory"
done
# A GIT_ variable set other than on git, in a call naming the state directory: unplaced.
case_ state-git-env-unplaced   2 stamp "a GIT_ variable set in it"
# A script the call runs that names it fails closed the same way.
case_ state-script-xargs       2 stamp "state directory"
case_ state-script-bash-c      2 stamp "state directory"
# osc's own state beside it names no piece of it.
case_ osc-state-ls-then-build  2 retired-osc "an osc command"
case_ watch-state-then-make    0 - ""
# Reads stay allowed, and so does a copy out of it.
case_ stamp-read-diff-state    0 - ""
case_ stamp-read-cat-out       0 - ""
case_ stamp-read-cp-out        0 - ""
case_ stamp-read-test          0 - ""

echo "--- osc"
case_ osc-build-x86_64    2 retired-osc "an osc command"
case_ osc-build-setsid    2 retired-osc "an osc command"
case_ osc-build-i586      2 retired-osc "an osc command"
case_ osc-shell-x86_64    2 retired-osc "an osc command"
case_ osc-chroot-x86_64   2 retired-osc "an osc command"
case_ osc-build-x86_64    2 retired-osc "an osc command"   PR_GUARD_ARCH=x86_64
case_ osc-build-i586      2 retired-osc "an osc command"   PR_GUARD_ARCH=x86_64
case_ osc-buildinfo       2 retired-osc "an osc command"
case_ osc-sr-backports    2 retired-osc "an osc command"
case_ osc-mr-backports    2 retired-osc "an osc command"
case_ osc-sr-factory      2 retired-osc "an osc command"
case_ osc-sr-factory-plain 2 retired-osc "an osc command"
case_ sr-devel-target-live 2 retired-osc "an osc command"
# The request message only describes the request.
case_ osc-sr-message-backports 2 retired-osc "an osc command"
case_ osc-sr-message-eq   2 retired-osc "an osc command"
# factory-auto declines a Factory request whose source is not the devel project.
case_ osc-sr-nodevelproject   2 retired-osc "an osc command"
case_ osc-creq-nodevelproject 2 retired-osc "an osc command"
case_ osc-sr-nodevel-abbrev   2 retired-osc "an osc command"
case_ osc-sr-nodevel-python   2 retired-osc "an osc command"
# Read as bash reads it, home:<you>:... redirects into the file ":branches:devel:tools",
# outside every checkout and at the submit itself: nothing it sends changes first.
case_ osc-sr-devel-control  2 retired-osc "an osc command"
case_ osc-sr-nodevel-message  2 retired-osc "an osc command"
# Maintenance and update projects take no direct write, by commit or by API;
# a home: branch of one is the user's own, whatever its name ends in.
case_ osc-ci-update-checkout     2 retired-osc "an osc command"
case_ osc-ci-incident-checkout   2 retired-osc "an osc command"
case_ osc-ci-update-operand      2 retired-osc "an osc command"
case_ osc-ci-update-file-operand 2 retired-osc "an osc command"
case_ osc-ci-update-new-checkout 2 retired-osc "an osc command"
case_ osc-api-put-update         2 retired-osc "an osc command"
case_ osc-api-post-maintenance-m 2 retired-osc "an osc command"
case_ osc-api-file-implies-put   2 retired-osc "an osc command"
case_ osc-api-delete-full-url    2 retired-osc "an osc command"
case_ osc-mbranch                2 retired-osc "an osc command"
case_ osc-mr                     2 retired-osc "an osc command"
case_ osc-ci-mbranch-checkout    2 retired-osc "an osc command"
case_ osc-ci-home-update-branch  2 retired-osc "an osc command"
case_ osc-ci-devel               2 retired-osc "an osc command"
case_ osc-api-get-update         2 retired-osc "an osc command"
case_ osc-api-put-home-branch    2 retired-osc "an osc command"
# A POST that only reads (diff, showlinked) or branches out of the project writes
# nothing into it; any other cmd, none, a branch into it, PUT or DELETE does.
case_ osc-api-post-diff-update       2 retired-osc "an osc command"
case_ osc-api-post-branch-update     2 retired-osc "an osc command"
case_ osc-api-post-showlinked-update 2 retired-osc "an osc command"
case_ osc-api-post-branch-into-update    2 retired-osc "an osc command"
case_ osc-api-post-commitfilelist-update 2 retired-osc "an osc command"
case_ osc-api-post-copy-update       2 retired-osc "an osc command"
case_ osc-api-post-no-cmd-update     2 retired-osc "an osc command"
case_ osc-api-post-diff-then-commit  2 retired-osc "an osc command"
case_ osc-api-put-diff-query         2 retired-osc "an osc command"
case_ osc-api-delete-branch-query    2 retired-osc "an osc command"
# A commit or API write the guard cannot place is refused, as a push is; osc's
# global options and api --method count by any prefix argparse takes.
case_ osc-ci-cwd-unknown         2 retired-osc "an osc command"
# A cd follows what the call set: not a value read gives, all values a loop gives
# its variable (before as after the cd), and a loop's globs as the shell expands them.
case_ osc-ci-read-stale          2 retired-osc "an osc command"
case_ osc-ci-loop-reassign       2 retired-osc "an osc command"
case_ osc-ci-loop-outer-unknown  2 retired-osc "an osc command"
case_ osc-ci-loop-glob-devel     2 retired-osc "an osc command"
case_ osc-ci-loop-glob-all       2 retired-osc "an osc command"
case_ osc-api-var-url            2 retired-osc "an osc command"
case_ osc-api-subst-url          2 retired-osc "an osc command"
case_ osc-api-host-var-path      2 retired-osc "an osc command"
case_ osc-api-double-slash       2 retired-osc "an osc command"
case_ osc-api-dot-segment        2 retired-osc "an osc command"
case_ osc-api-dotdot-segment     2 retired-osc "an osc command"
# A commit whose checkout has no .osc/_project yet (made in the same call) is unplaced.
case_ osc-co-output-then-ci      2 retired-osc "an osc command"
case_ osc-co-current-then-ci     2 retired-osc "an osc command"
case_ osc-ci-not-a-checkout      2 retired-osc "an osc command"
# A cd into each word of a loop, or into a variable this call set, is followed.
case_ osc-ci-loop-devel          2 retired-osc "an osc command"
case_ osc-ci-loop-update         2 retired-osc "an osc command"
case_ osc-ci-var-cd-devel        2 retired-osc "an osc command"
case_ push-loop-dirs             2 push-unknown "one of several directories"
case_ osc-ci-no-cwd              2 retired-osc "an osc command"
case_ osc-ci-subst-operand       2 retired-osc "an osc command"
case_ osc-ci-loop-subst          2 retired-osc "an osc command"
case_ osc-api-var-project        2 retired-osc "an osc command"
case_ osc-api-var-branch-target  2 retired-osc "an osc command"
case_ osc-api-quoted-project     2 retired-osc "an osc command"
case_ osc-api-meth-prefix        2 retired-osc "an osc command"
case_ osc-ci-api-prefix          2 retired-osc "an osc command"
case_ osc-ci-conf-prefix         2 retired-osc "an osc command"
case_ osc-ci-setopt              2 retired-osc "an osc command"
case_ osc-api-var-get            2 retired-osc "an osc command"
# A request's id is no project: a revoke of one only the shell knows asks whose it is.
case_ osc-api-var-request 2 retired-osc "an osc command"
case_ osc-api-quoted-home        2 retired-osc "an osc command"
case_ osc-ci-var-devel           2 retired-osc "an osc command"
# Nor do they take a package copied, linked or aggregated in, deleted or
# undeleted, or meta written; reading from them stays allowed.
case_ osc-copypac-into-update       2 retired-osc "an osc command"
case_ osc-rmkpac-update            2 retired-osc "an osc command"
case_ osc-repo-add-update          2 retired-osc "an osc command"
case_ osc-repo-remove-checkout     2 retired-osc "an osc command"
case_ osc-metafromspec-checkout    2 retired-osc "an osc command"
case_ osc-unlock-update            2 retired-osc "an osc command"
case_ osc-mbranch-target           2 retired-osc "an osc command"
case_ osc-addchannels-update       2 retired-osc "an osc command"
case_ osc-addcontainers-update     2 retired-osc "an osc command"
case_ osc-maintained               2 retired-osc "an osc command"
case_ osc-repo-list-update         2 retired-osc "an osc command"
case_ osc-metafromspec-devel       2 retired-osc "an osc command"
case_ osc-rmkpac-home              2 retired-osc "an osc command"
case_ osc-branch-into-update        2 retired-osc "an osc command"
case_ osc-branch-dot-checkout       2 retired-osc "an osc command"
case_ osc-rremove-update            2 retired-osc "an osc command"
case_ osc-sdp-update                2 retired-osc "an osc command"
case_ osc-sdp-checkout              2 retired-osc "an osc command"
case_ osc-setlinkrev-maint          2 retired-osc "an osc command"
case_ osc-detachbranch-update       2 retired-osc "an osc command"
case_ osc-linktobranch-checkout     2 retired-osc "an osc command"
case_ osc-lock-update               2 retired-osc "an osc command"
case_ osc-release-maint             2 retired-osc "an osc command"
case_ osc-release-target            2 retired-osc "an osc command"
case_ osc-wipebinaries-update       2 retired-osc "an osc command"
case_ osc-unpublish-update          2 retired-osc "an osc command"
case_ osc-api-build-wipe            2 retired-osc "an osc command"
case_ osc-branch-from-update        2 retired-osc "an osc command"
case_ osc-bco-from-update           2 retired-osc "an osc command"
case_ osc-branch-into-home          2 retired-osc "an osc command"
case_ osc-sdp-devel-checkout        2 retired-osc "an osc command"
case_ osc-release-home              2 retired-osc "an osc command"
case_ osc-wipebinaries-home         2 retired-osc "an osc command"
case_ osc-api-build-result          2 retired-osc "an osc command"
case_ osc-api-build-rebuild-home    2 retired-osc "an osc command"
case_ osc-copypac-slash-into-maint  2 retired-osc "an osc command"
case_ osc-linkpac-into-update       2 retired-osc "an osc command"
case_ osc-linkpac-from-checkout     2 retired-osc "an osc command"
case_ osc-aggregatepac-into-update  2 retired-osc "an osc command"
case_ osc-rdelete-update            2 retired-osc "an osc command"
case_ osc-rdelete-slash             2 retired-osc "an osc command"
case_ osc-rdelete-dot               2 retired-osc "an osc command"
case_ osc-undelete-maintenance      2 retired-osc "an osc command"
case_ osc-meta-pkg-file             2 retired-osc "an osc command"
case_ osc-meta-prj-edit             2 retired-osc "an osc command"
case_ osc-meta-pkg-slash-file       2 retired-osc "an osc command"
case_ osc-meta-pkg-checkout-file    2 retired-osc "an osc command"
case_ osc-meta-pkg-edit-prefix     2 retired-osc "an osc command"
case_ osc-copypac-var-unknown       2 retired-osc "an osc command"
case_ osc-copypac-from-update       2 retired-osc "an osc command"
case_ osc-linkpac-into-home         2 retired-osc "an osc command"
case_ osc-aggregatepac-from-update  2 retired-osc "an osc command"
case_ osc-rdelete-home-branch       2 retired-osc "an osc command"
case_ osc-rdelete-dot-home          2 retired-osc "an osc command"
case_ osc-meta-pkg-read             2 retired-osc "an osc command"
case_ osc-meta-prj-blame            2 retired-osc "an osc command"
case_ osc-meta-pkg-home-file        2 retired-osc "an osc command"
# A new package's maintainer role, set in the devel project the user maintains: no ask.
case_ osc-meta-pkg-devel-file       2 retired-osc "an osc command"
case_ osc-maintainer-add-devel      2 retired-osc "an osc command"
# osc maintainer/bugowner -a, -d and -s write the meta: the maintenance rules hold, and
# an owner search (one name, -U/-G) lands where the guard cannot tell.
case_ osc-maintainer-add-update     2 retired-osc "an osc command"
case_ osc-maintainer-del-update     2 retired-osc "an osc command"
case_ osc-bugowner-add-update       2 retired-osc "an osc command"
case_ osc-maintainer-add-search     2 retired-osc "an osc command"
case_ osc-maintainer-read-update    2 retired-osc "an osc command"
case_ osc-maintainer-devel-update   2 retired-osc "an osc command"
# A request is filed with osc, which checks the devel project and the message;
# one created through the API skips both.
case_ request-api-osc-create        2 retired-osc "an osc command"
case_ request-api-pct-value         2 retired-osc "an osc command"
case_ request-api-pct-key           2 retired-osc "an osc command"
case_ request-api-dot               2 retired-osc "an osc command"
case_ request-api-curl-pct          2 request-api "a request created through the API"
case_ request-api-osc-create-addrev 2 retired-osc "an osc command"
case_ request-api-curl-create       2 request-api "a request created through the API"
case_ request-api-python-create     2 request-api "a request created through the API"
case_ request-api-var-create        2 retired-osc "an osc command"
case_ request-api-changestate       2 retired-osc "an osc command"
case_ request-api-list              2 retired-osc "an osc command"
case_ request-sr-supersede          2 retired-osc "an osc command"

echo "--- geectl"
# A filing into Backports is refused. A filing naming Factory as its target,
# and a foreign-arch local build, are not refused here: geectl itself refuses
# them (its Factory devel check and its UnsupportedArch).
case_ geectl-backports            2 backports "a geectl request to openSUSE:Backports:SLE-16.x"
case_ geectl-backports-refile     2 backports "a geectl request to openSUSE:Backports:SLE-16.x"
# Maintenance and update projects take no direct write, by commit or by a remote leaf;
# a target the guard cannot place is refused too.
case_ geectl-maintenance-write    2 maintenance-write "a geectl remote set-project-meta into openSUSE:Maintenance:12345"
case_ geectl-maintenance-unknown  2 maintenance-unknown "geectl remote set-project-meta to \$PRJ"
case_ geectl-maintenance-commit   2 maintenance-commit "a geectl commit into openSUSE:Maintenance:12345"
# A rebuild, restart or abort names a build, not a write, and is not judged here.
case_ geectl-rebuild-package      0 - ""
case_ geectl-restart-build        0 - ""
case_ geectl-abort-build          0 - ""

echo "--- find -exec, watch and parallel run the command they carry"
case_ find-exec-tea-merge        2 merge-tea     "tea PR merge"
case_ find-execdir-push          2 push-unknown  "the working directory is unknown"
case_ find-ok-sh-merge           2 merge-tea     "tea PR merge"
case_ find-exec-placeholder-push 2 push-unknown  "the pushed branch is held in a variable"
case_ watch-tea-merge            2 merge-tea     "tea PR merge"
case_ watch-exec-merge           2 merge-tea     "tea PR merge"
case_ parallel-merge             2 merge-tea     "tea PR merge"
case_ parallel-push-placeholder  2 push-unknown  "the pushed branch is held in a variable"
case_ find-exec-grep             0 - ""
case_ watch-osc-results          2 retired-osc "an osc command"
case_ parallel-echo              0 - ""

echo "--- osc named by a variable is judged as osc"
case_ var-osc-ci-update          2 retired-osc "an osc command"
# The prefilter also reads the text without its quotes and backslashes, $'...'
# decoded, and a variable after if, while, !, { or a wrapper.
case_ prefilter-split-quotes     2 retired-osc "an osc command"
case_ prefilter-ansi-c           2 retired-osc "an osc command"
case_ prefilter-quoted-var       2 retired-osc "an osc command"
case_ prefilter-if-var           2 retired-osc "an osc command"
case_ prefilter-wrapper-var      2 retired-osc "an osc command"
# A command held in several words (a variable, an array, a function running "$@")
# is those words; one only the shell knows is refused.
case_ var-multiword-command      2 merge-tea     "tea PR merge"
case_ var-array-command          2 merge-tea     "tea PR merge"
case_ func-wrapper-merge         2 merge-tea     "tea PR merge"
case_ var-array-unknown          2 command-unknown "\${ARGS[@]}"
case_ func-wrapper-status        0 - ""
case_ var-array-status           0 - ""
# An unknown command is judged as osc only when its variable is named for it.
case_ var-git-commit             0 - ""
case_ var-make-release           0 - ""

echo "--- osc request arguments held in variables are judged by their values"
case_ osc-sr-var-backports       2 retired-osc "an osc command"
case_ osc-sr-loop-backports      2 retired-osc "an osc command"
case_ osc-sr-var-nodevel         2 retired-osc "an osc command"
case_ osc-sr-unknown-target      2 retired-osc "an osc command"
case_ osc-sr-var-factory         2 retired-osc "an osc command"

echo "--- tea's options may take one dash (-repo, -method)"
case_ tea-create-single-dash-repo 2 create-tea   "tea PR create"
case_ tea-api-pulls-single-dash  2 create-tea-api "tea api write"
case_ tea-create-single-dash-ai  0 - ""
case_ tea-api-pulls-get-single-dash 0 - ""

echo "--- a number before a redirection is its fd only when attached"
case_ fd-number-argument         0 - ""
case_ fd-number-attached         2 push-pr-head "pool/tesseract-ocr#3"

echo "--- an expansion that doubles past 64 KiB is unknown, and fast"
case_ var-doubling-script        2 exec-unresolved "\$V40"
case_ var-doubling-message       2 retired-osc "an osc command"

echo "--- a FIFO or device is refused, never read"
case_ run-fifo                   2 exec-unreadable "not a regular file"
case_ msg-fifo                   2 retired-osc "an osc command"
case_ run-dev-stdin              2 exec-unreadable "not a regular file"
case_ var-osc-path-sr-long       2 retired-osc "an osc command"
case_ var-osc-unset-ci-update    2 retired-osc "an osc command"
case_ var-osc-unset-nodevel      2 retired-osc "an osc command"
case_ var-osc-ci-devel           2 retired-osc "an osc command"
# A request message is one headline: over 160 characters of prose it is refused.
case_ osc-sr-long-message        2 retired-osc "an osc command"
case_ osc-sr-message-161         2 retired-osc "an osc command"
case_ osc-mr-long-message-eq     2 retired-osc "an osc command"
case_ osc-creq-long-message-attached 2 retired-osc "an osc command"
case_ osc-sr-message-160         2 retired-osc "an osc command"
case_ msg-headline-real          2 retired-osc "an osc command"
case_ msg-headline-stage-with    2 retired-osc "an osc command"
# Build, sweep and session status is the user's, not the reviewer's: refused in
# the prose or a list line, by word, so a word that only contains one passes.
case_ msg-note-decoys            2 retired-osc "an osc command"
case_ msg-note-not-done          2 retired-osc 'an osc command'
case_ msg-note-bugwarden         2 retired-osc 'an osc command'
case_ msg-note-vul-sweep         2 retired-osc 'an osc command'
case_ msg-note-built-green       2 retired-osc 'an osc command'
case_ msg-note-still-building    2 retired-osc 'an osc command'
case_ msg-note-this-env          2 retired-osc 'an osc command'
case_ msg-note-subagent          2 retired-osc 'an osc command'
case_ msg-note-no-access         2 retired-osc 'an osc command'
case_ msg-note-in-list           2 retired-osc 'an osc command'
case_ msg-note-gate-sh           2 retired-osc 'an osc command'
# A forward says what it forwards.
case_ msg-forward-bare           2 retired-osc "an osc command"
case_ msg-forward-with-content   2 retired-osc "an osc command"
case_ msg-forward-described     2 retired-osc "an osc command"
# A message file the same call writes cannot be read yet: the refusal says so.
case_ msg-same-call-file         2 retired-osc "an osc command"

echo "--- a PR's title and description are held to a request message's rules, on any repository"
# A real body: build status, the gate's and the review's verdicts, the agent's home project.
case_ pr-create-work-notes        2 pr-message "create description with 339 characters of prose"
case_ pr-create-terse             0 - ""
case_ pr-create-green-decoy       0 - ""
case_ pr-create-note-gate         2 pr-message 'description with a work note ("gate.sh")'
case_ pr-create-note-adversarial  2 pr-message 'description with a work note ("Adversarial review")'
case_ pr-create-note-review-pass  2 pr-message 'description with a work note ("review PASS")'
case_ pr-create-note-green        2 pr-message 'description with a work note ("GREEN")'
case_ pr-create-title-note        2 pr-message 'title with a work note ("still building")'
case_ pr-create-title-long        2 pr-message "title with 174 characters of prose"
case_ pr-create-tea-short-opts    2 pr-message 'description with a work note ("gate.sh")'
case_ pr-create-tea-one-dash-eq   2 pr-message 'description with a work note ("review PASS")'
case_ pr-create-git-obs-notes     2 pr-message 'description with a work note ("GREEN")'
case_ pr-create-git-obs-abbrev    2 pr-message 'description with a work note ("adversarial review")'
case_ pr-create-git-space-obs     2 pr-message "description with 380 characters of prose"
case_ pr-create-git-obs-terse     0 - ""
# Text it cannot read now is refused; a file an earlier call wrote is read.
case_ pr-create-sub-same-call     2 pr-message-unknown "cannot read the tea pulls create description (a command substitution;"
case_ pr-create-var-unset         2 pr-message-unknown "(\$BODY)"
case_ pr-create-sub-readable      0 - ""
case_ pr-create-sub-readable-long 2 pr-message "description with 380 characters of prose"
# The same rules on a geectl filing: a commit or a filing with no message, one
# too long for its reviewers, or one that cannot be read now.
case_ geectl-commit-no-message       2 request-no-message "geectl commit without -m"
case_ geectl-request-no-message      2 request-no-message "geectl request file without --changes-entry and --description"
case_ geectl-request-message         2 request-message "a geectl request file message with 167 characters of prose"
case_ geectl-request-message-unknown 2 request-message-unknown "the geectl request file message (\$MSG)"

echo "--- a submit request goes to the devel project Factory's _meta names"
case_ sr-target-swept            2 retired-osc "an osc command"
case_ sr-target-aggregate        2 retired-osc "an osc command"
case_ sr-target-slash-form       2 retired-osc "an osc command"
case_ sr-target-var              2 retired-osc "an osc command"
case_ sr-target-garbled          2 retired-osc "an osc command"
case_ sr-target-devel            2 retired-osc "an osc command"
case_ sr-target-factory          2 retired-osc "an osc command"
case_ sr-target-home             2 retired-osc "an osc command"
case_ sr-target-not-in-factory   2 retired-osc "an osc command"
case_ sr-target-no-devel         2 retired-osc "an osc command"
# Not developed for Factory: the target package itself says when it only mirrors.
case_ sr-target-link-factory-devel 2 retired-osc "an osc command"
case_ sr-target-link-foreign     2 retired-osc "an osc command"
case_ sr-target-aggregate-nonfactory 2 retired-osc "an osc command"
case_ sr-target-link-same-project 2 retired-osc "an osc command"
case_ sr-target-link-to-factory  2 retired-osc "an osc command"

echo "--- a submit request from a home subproject deletes its branch on accept"
case_ sr-cleanup-missing         2 retired-osc "an osc command"
case_ sr-cleanup-no-cleanup      2 retired-osc "an osc command"
case_ sr-cleanup-slash           2 retired-osc "an osc command"
case_ sr-cleanup-branches        2 retired-osc "an osc command"
case_ sr-cleanup-checkout        2 retired-osc "an osc command"
case_ sr-cleanup-submitpac-no    2 retired-osc "an osc command"
case_ sr-cleanup-given           2 retired-osc "an osc command"
case_ sr-cleanup-abbrev          2 retired-osc "an osc command"
case_ sr-cleanup-checkout-given  2 retired-osc "an osc command"
case_ sr-cleanup-submitpac       2 retired-osc "an osc command"
case_ sr-cleanup-top-home        2 retired-osc "an osc command"
case_ sr-cleanup-devel           2 retired-osc "an osc command"

echo "--- a home branch is filed only to the project its link points at"
# python-streamdeck: branched from a stale copy in hardware, filed to Factory's
# devel project, so the request deleted five of the target's .changes entries.
case_ request-link-sweep-copy    2 retired-osc "an osc command"
case_ request-link-slash         2 retired-osc "an osc command"
case_ request-link-checkout      2 retired-osc "an osc command"
case_ request-link-var           2 retired-osc "an osc command"
# Filed to Factory, the advice is the devel project first, then the forward.
case_ request-link-branch-to-factory 2 retired-osc "an osc command"
case_ request-link-garbled       2 retired-osc "an osc command"
case_ request-link-to-target     2 retired-osc "an osc command"
case_ request-link-same-project  2 retired-osc "an osc command"
case_ request-link-no-link       2 retired-osc "an osc command"
case_ request-link-devel-source  2 retired-osc "an osc command"
# osc reads a project "." as the checkout's, and creq -a submit files the same request.
case_ request-link-dot           2 retired-osc "an osc command"
case_ request-link-creq          2 retired-osc "an osc command"
case_ request-link-creq-delete   2 retired-osc "an osc command"
case_ sr-target-creq             2 retired-osc "an osc command"

echo "--- osc's questions are answered with options, never through a pipe"
case_ osc-prompt-echo-sr         2 retired-osc "an osc command"
case_ osc-prompt-yes-sr          2 retired-osc "an osc command"
case_ osc-prompt-herestring-ci   2 retired-osc "an osc command"
case_ osc-prompt-echo-accept     2 retired-osc "an osc command"
case_ osc-prompt-devnull-sr      2 retired-osc "an osc command"
case_ osc-prompt-message-stdin-ci 2 retired-osc "an osc command"
case_ osc-ci-long-message        2 retired-osc "an osc command"
# --yes answers them unread, as a pipe does: by any prefix argparse takes.
case_ osc-yes-sr                 2 retired-osc "an osc command"
case_ osc-yes-prefix             2 retired-osc "an osc command"
case_ osc-yes-creq               2 retired-osc "an osc command"
case_ osc-yes-var                2 retired-osc "an osc command"
case_ osc-yes-python             2 retired-osc "an osc command"
case_ osc-yes-message            2 retired-osc "an osc command"
case_ osc-yes-echo               0 - ""
case_ osc-yes-heredoc-commit     0 - ""
# A line continuation joins the words, for the prefilter too.
case_ prefilter-continuation-osc 2 retired-osc "an osc command"
# Without a message osc opens an editor, and the call hangs until its timeout.
case_ nomsg-sr                   2 retired-osc "an osc command"
case_ nomsg-submitreq-supersede  2 retired-osc "an osc command"
case_ nomsg-creq                 2 retired-osc "an osc command"
case_ nomsg-rq-accept            2 retired-osc "an osc command"
case_ nomsg-request-decline      2 retired-osc "an osc command"
case_ nomsg-rq-revoke            2 retired-osc "an osc command"
case_ nomsg-rq-supersede         2 retired-osc "an osc command"
case_ nomsg-review-accept        2 retired-osc "an osc command"
case_ nomsg-review-add           2 retired-osc "an osc command"
case_ nomsg-rq-wipe              2 retired-osc "an osc command"
case_ nomsg-rq-revoke-message    2 retired-osc "an osc command"
case_ nomsg-sr-file              2 retired-osc "an osc command"
case_ nomsg-rq-show              2 retired-osc "an osc command"
# osc sr --diff only shows what a request would carry: no request, no editor.
case_ nomsg-sr-diff              2 retired-osc "an osc command"
case_ nomsg-sr-d                 2 retired-osc "an osc command"

echo "--- a recursive delete takes one checkout at a time, or asks"
ask_ rm-project-dir             rm-checkouts "deletes 2 geectl checkouts at once: libpqxx, python-streamdeck"
ask_ rm-fr-trailing-slash       rm-checkouts "deletes 2 geectl checkouts at once: libpqxx, python-streamdeck"
ask_ rm-r-f-separate            rm-checkouts "deletes 2 geectl checkouts at once: libpqxx, python-streamdeck"
ask_ rm-sudo-recursive-long     rm-checkouts "deletes 2 geectl checkouts at once: libpqxx, python-streamdeck"
ask_ rm-glob-siblings           rm-checkouts "deletes 2 geectl checkouts at once: libpqxx, python-streamdeck"
ask_ rm-parent-of-projects      rm-checkouts "geectl checkouts at once"
ask_ rm-var-dir                 rm-checkouts "deletes 2 geectl checkouts at once: libpqxx, python-streamdeck"
ask_ rm-relative-in-cwd         rm-checkouts "deletes 2 geectl checkouts at once: libpqxx, python-streamdeck"
ask_ find-delete-project        rm-checkouts "deletes 2 geectl checkouts at once: libpqxx, python-streamdeck"
# The incident's shape: one project checkout around three packages others work in.
ask_ rm-project-many-packages   rm-checkouts "deletes 3 geectl checkouts at once: kmscon, rioterm, termit"
# No path in the command: find reaches the guard by name.
ask_ find-delete-no-slash       rm-checkouts "deletes 2 geectl checkouts at once"
ask_ find-mindepth-no-slash     rm-checkouts "deletes 2 geectl checkouts at once"
# A trailing slash makes rm empty a symlink's target; without it only the link goes.
ask_ rm-link-trailing-slash     rm-checkouts "deletes 2 geectl checkouts at once"
case_ rm-link-itself             0 - ""
# Cleanup after osc co PRJ PKG, one checkout per rm, and separate rm commands pass.
case_ rm-project-one-package     0 - ""
case_ rm-checkouts-separately    0 - ""
case_ find-delete-name           0 - ""
case_ rm-own-checkout            0 - ""
case_ rm-not-recursive           0 - ""
case_ rm-no-checkouts            0 - ""

echo "--- a script runs under its own interpreter"
case_ interpreter-python-sh      2 interpreter "python3 $W/iter.sh"
case_ interpreter-bash-py        2 interpreter "bash $W/iter.py"
case_ interpreter-sh-var         2 interpreter "python3 \$S/iter.sh"
case_ interpreter-var-value      2 interpreter "python3 \$F ($W/iter.sh)"
case_ interpreter-python-py      0 - ""
case_ interpreter-bash-sh        0 - ""
case_ interpreter-echo           0 - ""

echo "--- a wait is on an event, not a fixed sleep of a minute or more"
case_ sleep-long                 2 sleep "sleep 290"
case_ sleep-long                 2 sleep "$S/scripts/build-wait.sh PGID LOG" PR_GUARD_SKILL_DIR="$S"
# A wait on a local service, vendor or cargo run has its tool too.
case_ sleep-long                 2 sleep "(--no-summary: any other local job"
case_ sleep-minutes              2 sleep "sleep 5m"
case_ sleep-hex-overflow         2 sleep "sleep 0x1p99999"
case_ sleep-sum                  2 sleep "sleep 30 30"
case_ sleep-loop                 2 retired-osc "an osc command"
case_ sleep-timeout              2 sleep "sleep 290"
case_ sleep-var                  2 sleep "sleep \$N"
case_ sleep-path                 2 sleep "sleep 600"
case_ prefilter-continuation-sleep 2 sleep "sleep 600"
# GNU sleep's own spellings: a +, hex, leading blanks; an unknown operand counts 0.
case_ sleep-plus                 2 sleep "sleep +600"
case_ sleep-hex                  2 sleep "sleep 0x258"
case_ sleep-blank                2 sleep "sleep  600"
case_ sleep-unset-operand        2 sleep "sleep 600 \$UNSET"
case_ sleep-substitution-operand 2 sleep "sleep 600"
case_ sleep-busybox              2 sleep "sleep 600"
case_ sleep-added                2 sleep "sleep 59 (118 s in this call)"
# Inline code is the call's own; a script it runs keeps its backoff.
case_ sleep-bash-c               2 sleep "sleep 120"
case_ sleep-eval                 2 sleep "sleep 120"
case_ sleep-short                0 - ""
case_ sleep-short-loop           2 retired-osc "an osc command"
case_ sleep-unknown              0 - ""
case_ sleep-monitor              0 - ""
case_ sleep-echo                 0 - ""
case_ sleep-commit-message       0 - ""
case_ sleep-background           0 - ""
case_ sleep-in-script            2 retired-osc "an osc command"

echo "--- comments speak for the user: posted only on their go"
case_ comment-osc-create 2 retired-osc "an osc command"
case_ comment-osc-list          2 retired-osc "an osc command"
case_ comment-osc-api-post 2 retired-osc "an osc command"
case_ comment-osc-api-get       2 retired-osc "an osc command"
# A comment on someone else's request to a package the account maintains asks unless its
# incoming review recorded that comment (the cases of contributors' submissions, below).
case_ comment-request-own-pkg 2 retired-osc "an osc command"
case_ comment-request-git-pkg 2 retired-osc "an osc command"
case_ comment-request-own-req     2 retired-osc "an osc command"
case_ comment-api-own-pkg 2 retired-osc "an osc command"
case_ comment-request-unreadable 2 retired-osc "an osc command"
case_ comment-request-two-mixed 2 retired-osc "an osc command"
case_ comment-request-id-unknown 2 retired-osc "an osc command"
case_ comment-api-package-own 2 retired-osc "an osc command"
case_ comment-package-create 2 retired-osc "an osc command"
case_ comment-request-group 2 retired-osc "an osc command"
case_ comment-request-no-action 2 retired-osc "an osc command"
case_ comment-api-full-host 2 retired-osc "an osc command"
case_ comment-api-query 2 retired-osc "an osc command"
# The requester replies to its reviewers on a request it filed, whoever maintains the target.
case_ comment-reply-own-request   2 retired-osc "an osc command"
case_ comment-api-own-request     2 retired-osc "an osc command"
case_ comment-own-and-others 2 retired-osc "an osc command"
case_ comment-tea-comments-list 0 - ""
case_ comment-tea-list-read       0 - ""
case_ comment-tea-review-comments 0 - ""
# Without a subcommand tea adds a comment, so a read spelled that way asks, and the
# ask says how to read; a comment that carries its body gets no such hint.
ask_ comment-tea-issue-flag       comment "tea comments: tea's option --issue is not judged"
ask_ comment-tea-issue-flag       comment "To read them: tea comments list --login src.opensuse.org --repo OWNER/NAME N."
for name in comment-tea-others-item comment-tea-pkg-other comment-tea-description; do
  out="$(ev "$name" | python3 "$GUARD" 2>&1)"
  grep -qF "To read them" <<<"$out" && fail "$name: a comment with a body gets the read hint" \
    || pass "$name: no read hint beside a body"
done
# A tea comment on an issue or PR the user opened, or in a repository the user
# maintains -- judged only in the plain form: --login src.opensuse.org and a literal
# --repo owner/name that is no local path.
case_ comment-tea-own-item        0 - ""
ask_ comment-tea-maintained-pkg   comment "tea comment: perl/perl-Foo#2 by other: no incoming review is recorded"
ask_ comment-tea-maintained-prj   comment "tea comment: lua/lua-x#4 by other: no incoming review is recorded"
ask_ comment-tea-pool-maintained  comment "tea comment: pool/foo4#9 was opened by other"
case_ comment-tea-api-own         0 - ""
ask_ comment-tea-others-item      comment "tea comment: AI has no _maintainership.json"
ask_ comment-tea-pkg-other        comment "tea comment: lua/lua-y is maintained by other"
ask_ comment-tea-prj-not-pkg      comment "tea comment: perl/perl-Bar is maintained by boss"
ask_ comment-tea-pool-other       comment "tea comment: pool/dlib: science:machinelearning/dlib is maintained by other"
# A devel project kept in git (devel:openSUSE:Factory) has stub package _meta: its
# project git's _maintainership.json decides, never the OBS persons.
ask_ comment-tea-pool-git         comment "tea comment: pool/hwgit#9 was opened by other"
ask_ comment-tea-pool-git-group   comment "tea comment: pool/hwgrp: devel:gitprj/hwgrp is maintained by @team (gitprj/_ObsPrj)"
ask_ comment-tea-pool-git-other   comment "tea comment: pool/hwother: devel:gitprj/hwother is maintained by other (gitprj/_ObsPrj)"
ask_ comment-tea-pool-git-unreadable comment "tea comment: pool/hwbad: cannot read repos/gitbad/_ObsPrj/raw/_maintainership.json"
ask_ comment-tea-no-login         comment "tea comment: it names no --login src.opensuse.org"
ask_ comment-tea-other-login      comment "tea comment: it names no --login src.opensuse.org"
ask_ comment-tea-no-repo          comment "tea comment: it names no --repo owner/name"
ask_ comment-tea-remote-opt       comment "tea comment: tea's option --remote is not judged"
ask_ comment-tea-double-dash-short comment "tea comment: lua/lua-y is maintained by other"
ask_ comment-tea-description      comment "tea comment: tea's option -d is not judged"
ask_ comment-tea-repo-twice       comment "tea comment: --repo is given twice"
ask_ comment-tea-repo-is-path     comment "tea comment: --repo lua/lua-x may be a local checkout"
ask_ comment-tea-env-chdir-eq     comment "tea comment: it is not one literal tea command alone"
ask_ comment-tea-env-chdir-cluster comment "tea comment: it is not one literal tea command alone"
# The pass needs the tea command alone: nothing else in the call can make the path a
# --repo names, or move the directory tea resolves it in.
ask_ comment-tea-mkdir-first      comment "tea comment: it is not one literal tea command alone"
ask_ comment-tea-clone-first      comment "tea comment: it is not one literal tea command alone"
ask_ comment-tea-newline          comment "tea comment: it is not one literal tea command alone"
ask_ comment-tea-env-prefix       comment "tea comment: it is not one literal tea command alone"
ask_ comment-tea-ansi-quote       comment "tea comment: it is not one literal tea command alone"
ask_ comment-tea-hash-in-word     comment "tea comment: it is not one literal tea command alone"
ask_ comment-tea-brace            comment "tea comment: it is not one literal tea command alone"
ask_ comment-tea-glob             comment "tea comment: it is not one literal tea command alone"
# env -a NAME runs the command under another argv[0]; the command is still judged.
case_ env-argv0-osc-yes 2 retired-osc "an osc command"
ask_ comment-tea-triple-dash      comment "tea comment: tea's option ---repo=AI/mistral-vibe is not judged"
ask_ comment-tea-case             comment "tea comment: lua/lua-y is maintained by other"
ask_ comment-tea-wrong-repo       comment "tea comment: cannot tell which repository lua/lua-z#5 is in"
ask_ comment-tea-var-index        comment "tea comment: it is not one literal tea command alone"
ask_ comment-tea-lookup-fails     comment "tea comment: cannot read repos/AI/err/issues/1"
ask_ comment-tea-maint-fails      comment "tea comment: cannot read repos/bad/_ObsPrj/raw/_maintainership.json"
ask_ comment-tea-api-patch        comment "tea api: tea api PATCH"
ask_ comment-tea-api-header       comment "tea api: tea's option -H is not judged"
ask_ comment-tea-pr-approve     comment "tea pulls approve"
ask_ comment-tea-api            comment "tea api: it names no --login src.opensuse.org"
ask_ comment-git-obs-pr         comment "git-obs pr comment"
case_ comment-git-obs-review    2 incoming-approve "approving AI/mistral-vibe#3: it names no --commit SHA"
case_ comment-git-obs-pr-list   0 - ""
case_ comment-gh-pr              0 - ""
case_ comment-gh-issue           0 - ""
case_ comment-gh-review          0 - ""
case_ comment-gh-api-post        0 - ""
case_ comment-gh-api-read       0 - ""
case_ comment-gh-help           0 - ""
case_ comment-in-commit-message 0 - ""
case_ comment-echo              0 - ""
ask_ comment-bash-c             comment "tea comment"
# A line a forge bot acts on: autogits merges on a maintainer's "merge ok", the
# group-review bot reviews on "@group : approve". Refused in any comment, review or
# request message, inline, from a file or as a JSON body; one the guard cannot read too.
case_ comment-merge-ok-tea      2 bot-directive 'the tea comment body with a bot directive ("merge ok")'
case_ comment-merge-ok-sentence 0 - ""
case_ comment-merge-ok-osc-file 2 retired-osc 'an osc command'
case_ comment-merge-ok-osc-cat  2 retired-osc 'an osc command'
case_ comment-group-approve     2 bot-directive '("@qa-team : approve")'
case_ comment-group-approve-api 2 bot-directive '("@factory-maintainers : approve")'
case_ comment-body-unreadable   2 retired-osc "an osc command"
case_ approve-message-merge-ok  2 bot-directive 'the git-obs pr review body with a bot directive ("Merge OK")'
case_ tea-approve-merge-ok      2 bot-directive 'the tea pulls approve body with a bot directive ("merge ok")'
case_ accept-message-merge-ok   2 retired-osc 'an osc command'
# tea joins a body's words; a clause that starts with it counts; git obs is git-obs; a
# sentence about someone's approval is no group directive.
case_ comment-merge-ok-split    2 bot-directive 'with a bot directive ("merge ok")'
case_ comment-group-split       2 bot-directive 'with a bot directive ("@qa-team : approve")'
case_ tea-approve-split         2 bot-directive 'with a bot directive ("merge ok")'
# Only a line, or a list item, that starts with it: not a clause after a comma or colon.
case_ comment-merge-ok-clause   0 - ""
case_ comment-merge-ok-colon    0 - ""
case_ comment-merge-ok-numbered 2 bot-directive 'with a bot directive ("merge ok")'
case_ comment-git-obs-space     2 bot-directive 'with a bot directive ("merge ok")'
case_ comment-group-human       0 - ""
# An ask never outweighs a refusal elsewhere in the call.
case_ comment-deny-wins         2 retired-osc "an osc command"
# osc's options, its slash-split operands, a held subcommand; git obs; a closing comment.
# gh is not judged: GitHub is outside the packaging forges (the gh cases above and below run).
case_ comment-osc-option-first 2 retired-osc "an osc command"
case_ comment-osc-slash 2 retired-osc "an osc command"
case_ comment-osc-sub-variable 2 retired-osc "an osc command"
case_ comment-gh-repo-first      0 - ""
ask_ comment-git-obs-subcommand comment "git-obs pr comment"
case_ comment-gh-pr-close        0 - ""
case_ comment-gh-issue-close     0 - ""
ask_ comment-git-obs-close      comment "git-obs pr close with a comment"
case_ comment-gh-pr-close-plain 0 - ""
# A close without a comment is no comment; of a PR someone else opened, it is a close.
ask_ comment-git-obs-close-plain others-request "git-obs pr close AI/mistral-vibe#3: opened by other"

echo "--- an accept or a forward is unattended only where autoforward-gate.sh says ELIGIBLE"
case_ accept-own-eligible       2 retired-osc "an osc command"
case_ accept-git-eligible       2 retired-osc "an osc command"
case_ accept-own-var            2 retired-osc "an osc command"
# Someone else's request is accepted only through its incoming review (the cases of
# contributors' submissions, below), and one the guard cannot read may be someone else's.
case_ accept-others-request     2 retired-osc "an osc command"
case_ accept-others-maintained 2 retired-osc "an osc command"
case_ accept-two-own           2 retired-osc "an osc command"
case_ accept-not-yours-package 2 retired-osc "an osc command"
case_ accept-reviewer 2 retired-osc "an osc command"
case_ accept-unreadable         2 retired-osc "an osc command"
case_ accept-no-action          2 retired-osc "an osc command"
case_ accept-api-no-action      2 retired-osc "an osc command"
case_ accept-group-maintained   2 retired-osc "an osc command"
case_ accept-delete-request 2 retired-osc "an osc command"
case_ accept-unknown-id         2 retired-osc "an osc command"
case_ forward-not-yours 2 retired-osc "an osc command"
case_ forward-wrong-devel 2 retired-osc "an osc command"
case_ forward-link-into-here    2 retired-osc "an osc command"
case_ forward-project-reviewer 2 retired-osc "an osc command"
case_ forward-unowned-project   2 retired-osc "an osc command"
case_ forward-meta-fails 2 retired-osc "an osc command"
case_ forward-from-checkout     2 retired-osc "an osc command"
# osc's own option table: -i and -G, --user are no request ids; the verb, as the call sets it.
case_ accept-interactive-flag   2 retired-osc "an osc command"
case_ accept-group-option       2 retired-osc "an osc command"
case_ accept-user-option        2 retired-osc "an osc command"
case_ accept-verb-variable      2 retired-osc "an osc command"
case_ accept-approve            2 retired-osc "an osc command"
case_ accept-approvenew 2 retired-osc "an osc command"
case_ accept-review-alias 2 retired-osc "an osc command"
case_ accept-review-own-eligible 2 retired-osc "an osc command"
case_ accept-review-decline 2 retired-osc "an osc command"
case_ accept-decline 2 retired-osc "an osc command"
case_ accept-api-accepted       2 retired-osc "an osc command"
case_ accept-api-own            2 retired-osc "an osc command"
case_ accept-api-declined 2 retired-osc "an osc command"
case_ accept-revoke             2 retired-osc "an osc command"
case_ osc-sub-unknown 2 retired-osc "an osc command"
# Closing someone else's request declines their work, and --force skips its reviews:
# the user's call. The user's own requests run as before.
case_ supersede-others 2 retired-osc "an osc command"
case_ supersede-own             2 retired-osc "an osc command"
case_ revoke-others 2 retired-osc "an osc command"
case_ revoke-own                2 retired-osc "an osc command"
case_ reopen-others 2 retired-osc "an osc command"
case_ sr-s-others 2 retired-osc "an osc command"
case_ sr-supersede-long-others 2 retired-osc "an osc command"
case_ revoke-api-others 2 retired-osc "an osc command"
case_ accept-force-others       2 retired-osc "an osc command"
case_ accept-force-own          2 retired-osc "an osc command"
case_ accept-or-revoke-others   2 retired-osc "an osc command"
case_ mr-s-others 2 retired-osc "an osc command"
# The API takes its parameters from the body too, and a ; separates them.
case_ revoke-api-body 2 retired-osc "an osc command"
case_ revoke-api-semicolon 2 retired-osc "an osc command"
case_ accept-api-body           2 retired-osc "an osc command"
case_ decline-api-body 2 retired-osc "an osc command"
# Closing, or any API write to, a PR someone else opened; your own PRs run.
ask_ pr-close-others-tea        others-request "tea pulls close perl/perl-Foo#2: opened by other"
ask_ pr-close-others-git-obs    others-request "git-obs pr close perl/perl-Foo#2: opened by other"
ask_ pr-close-others-api        others-request "git-obs api PATCH perl/perl-Foo#2: opened by other"
ask_ pr-close-others-tea-api    others-request "tea api PATCH perl/perl-Foo#2: opened by other"
case_ pr-close-own              0 - ""
case_ pr-close-own-git-obs      0 - ""
# tea's issues close, reopen and edit take a PR's number as well (the issues endpoint).
ask_ tea-issue-close-others     others-request "tea issues close perl/perl-Foo#2: opened by other"
ask_ tea-i-close-others         others-request "tea i close perl/perl-Foo#2: opened by other"
ask_ tea-issue-edit-others      others-request "tea issue edit perl/perl-Foo#2: opened by other"
ask_ tea-pr-reopen-others       others-request "tea pulls reopen perl/perl-Foo#2: opened by other"
ask_ gitobs-pr-reopen-others    others-request "git-obs pr reopen perl/perl-Foo#2: opened by other"
case_ tea-issue-close-own       0 - ""
# Every lookup goes to the instance osc -A names: here, one with none of the stubs.
case_ forward-apiurl 2 retired-osc "an osc command"
# No agreement check with autoforward-gate.sh anymore: that gate judged the
# retired tool's submit requests, and the guard refuses every call of it
# outright, so there is nothing to agree on. The plain form is covered by
# osc-sr-factory-plain below.

echo "--- a contributor's submission: accepted or approved through its incoming review, on the user's go"
# Without a review recorded, refused; with PASS or FIXABLE of what OBS holds now, asked,
# the review and the facts checked again in the ask.
case_ accept-others-unreviewed  2 retired-osc "an osc command"
case_ accept-pass 2 retired-osc "an osc command"
case_ accept-pass 2 retired-osc "an osc command"
case_ accept-fixable 2 retired-osc "an osc command"
case_ accept-api-pass 2 retired-osc "an osc command"
# A review accept is the user as a reviewer: asked as before unless ELIGIBLE, on
# Factory's packages too, whoever filed the request.
case_ accept-review-accept-pass 2 retired-osc "an osc command"
case_ accept-review-factory 2 retired-osc "an osc command"
case_ accept-api-review-factory 2 retired-osc "an osc command"
case_ accept-block              2 retired-osc "an osc command"
case_ accept-files-moved        2 retired-osc "an osc command"
case_ accept-target-moved       2 retired-osc "an osc command"
case_ accept-no-rev             2 retired-osc "an osc command"
case_ accept-link-rev           2 retired-osc "an osc command"
# A _link source is pinned only by its expanded srcmd5 at that rev: another srcmd5 may
# be the link's own, whose expansion moves with the package it links to.
case_ accept-link-rev-moved     2 retired-osc "an osc command"
case_ accept-red-build 2 retired-osc "an osc command"
case_ accept-link-target-rev 2 retired-osc "an osc command"
case_ accept-link-target-moved 2 retired-osc "an osc command"
case_ accept-link-target-stale 2 retired-osc "an osc command"
case_ accept-link-pinned 2 retired-osc "an osc command"
case_ accept-multi-action       2 retired-osc "an osc command"
case_ accept-options            2 retired-osc "an osc command"
case_ accept-home-target        2 retired-osc "an osc command"
# The stamp's key is the whole sha256: the 48-bit key of old is no key.
case_ accept-key12              2 retired-osc "an osc command" HOME="$work/oldkey"
case_ accept-from-reviewer-agent 2 retired-osc "an osc command"
# A devel PR: git-obs pr review approve --commit of the head reviewed, in the devel
# organisation the project git syncs from; tea's approve keeps asking as a comment.
ask_ approve-git-obs-pass       incoming-approve "approving incorg/incgit#5 by contrib at 555555555555: review PASS"
ask_ approve-git-obs-pass       incoming-approve "0 findings); build at review: no green build of this head"
case_ approve-no-commit         2 incoming-approve "approving incorg/incgit#5: it names no --commit SHA"
case_ approve-head-moved        2 incoming-approve "approving incorg/incgit#5: its head is not 444444444444"
case_ approve-reviewer-flag     2 incoming-approve "approving incorg/incgit#5: --reviewer approves for someone else"
case_ approve-two-ids           2 incoming-approve "it names no one literal OWNER/REPO#N"
case_ approve-pool              2 incoming-approve "approving pool/incgit#5: a pool PR is never an agent's to approve"
case_ approve-not-devel-org     2 incoming-approve "approving other/incgit#5: other is not the organisation devel:incgit syncs from"
case_ approve-own-pr            2 incoming-approve "approving incorg/incgit#6: it is your own PR"
case_ approve-reviewer-role     2 incoming-approve "approving incorg/increv#7: a reviewer role is set (qa)"
# A gitea stamp's file name: owner and repo lowercased, % as %25 and _ as %5F.
ask_ approve-underscore-name    incoming-approve "approving incorg/inc_under#11 by contrib at 111111111111: review PASS"
# A SHA-256 repository's head, as src.opensuse.org's newer ones name it.
ask_ approve-git-obs-sha256     incoming-approve "approving incorg/incgit#14 by contrib at 141414141414: review PASS"
case_ approve-from-reviewer-agent 2 incoming-self "git-obs pr review approve from agent incoming-review"
ask_ approve-tea-asks           comment "tea pulls approve"
# A comment on a contributor's item in a package the user maintains runs when its text is
# the one the review recorded (its sha256), and asks otherwise.
case_ comment-foreign-stamped   2 retired-osc "an osc command"
case_ comment-tea-foreign-stamped 0 - ""
case_ comment-foreign-unstamped 2 retired-osc "an osc command"
case_ comment-foreign-other-text 2 retired-osc "an osc command"
ask_ comment-tea-foreign-other-text comment "tea comment: incorg/incgit#5 by contrib: not the comment its review recorded"
case_ comment-from-reviewer-agent 2 retired-osc "an osc command"
# An accepted FIXABLE review holds the Factory forward until devel holds the follow-up.
case_ forward-fixable-pending   2 retired-osc "an osc command"
case_ forward-fixable-pending-git 2 retired-osc "an osc command"
case_ forward-after-followup    2 retired-osc "an osc command"
case_ forward-after-followup    2 retired-osc "an osc command" HOME="$work/badhome"
# word: read now, compared by its sha256, the tea command still alone in the call.
case_ comment-tea-file-stamped  0 - ""
ask_ comment-tea-file-other-text comment "tea comment: incorg/incgit#12 by contrib: not the comment its review recorded"
case_ comment-tea-file-written  2 bot-directive-unknown "cannot read the tea comment body"
ask_ comment-tea-file-two-subs  comment "tea comment: it is not one literal tea command alone"
# Unquoted, bash would split and glob what cat prints: tea would post other text.
ask_ comment-tea-file-unquoted  comment "tea comment: it is not one literal tea command alone"
# The guard runs elsewhere (-C), as the opencode plugins run it.
case_ comment-tea-file-proc-cwd 2 bot-directive-unknown "cannot read the tea comment body" -C "$W"
case_ comment-tea-file-proc-link 2 bot-directive-unknown "cannot read the tea comment body" -C "$W"
case_ comment-osc-file-proc-cwd 2 retired-osc "an osc command" -C "$W"
case_ comment-osc-file-stamped 2 retired-osc "an osc command"
# A .. after a link in the event's directory climbs from where the link leads, as cat's.
ask_ comment-tea-file-dotdot    comment "tea comment: incorg/incgit#12 by contrib: not the comment its review recorded"
case_ comment-osc-file-dotdot 2 retired-osc "an osc command"
case_ forward-fixable-in-factory 2 retired-osc "an osc command"
case_ forward-fixable-in-factory-git 2 retired-osc "an osc command"
case_ forward-fixable-factory-err 2 retired-osc "an osc command"
# Only the incoming-review agent records a review; a suite hands the recorder its option
# from a fixture file, which only the agent's own command line may not do.
case_ incoming-record-main      2 incoming-self "incoming-review.sh --record from the main session"
case_ incoming-record-agent     0 - ""
case_ incoming-record-copy      2 incoming-self "incoming-review.sh --record from the main session" PR_GUARD_SKILL_DIR="$W/skill-inc"
case_ incoming-record-real      2 incoming-self "incoming-review.sh --record from agent osc-update-build"
case_ incoming-record-test-copy 0 - ""
case_ incoming-record-unread    2 incoming-self "incoming-review.sh with an argument only the shell knows from the main session"
# The incoming-review agent reads a submission as text: nothing of it is parsed or run.
case_ reviewer-rpmspec          2 incoming-self "rpmspec from agent incoming-review"
# Its calls reach the rules whatever they say: a bare rpmspec names no path.
case_ reviewer-rpmspec-bare     2 incoming-self "rpmspec from agent incoming-review"
case_ reviewer-rpm-specfile     2 incoming-self "rpm from agent incoming-review"
case_ reviewer-rpmbuild         2 incoming-self "rpmbuild from agent incoming-review"
case_ reviewer-quilt            2 incoming-self "quilt setup from agent incoming-review"
case_ reviewer-osc-build        2 retired-osc "an osc command"
case_ reviewer-osc-service      2 retired-osc "an osc command"
case_ reviewer-gate             2 incoming-self "gate.sh from agent incoming-review"
case_ reviewer-target-gate      2 incoming-self "target-gate.sh from agent incoming-review"
case_ reviewer-reads            0 - ""
case_ reviewer-rpmspec-main     0 - ""
case_ reviewer-osc-build-main   2 retired-osc "an osc command"
# The whole rpm family by name or through a link (rpmlint runs rpm -q --specfile), a
# checkout or update that runs the source services, a shell's options before its script,
# and the skill's scripts that build or sync.
case_ reviewer-rpmquery         2 incoming-self "rpmquery from agent incoming-review"
case_ reviewer-rpm-query        2 incoming-self "rpm from agent incoming-review"
case_ reviewer-rpmlint          2 incoming-self "rpmlint from agent incoming-review"
case_ reviewer-rpm-link         2 incoming-self "rpx (rpmspec) from agent incoming-review"
case_ reviewer-osc-co-s         2 retired-osc "an osc command"
case_ reviewer-osc-co-cluster   2 retired-osc "an osc command"
case_ reviewer-osc-up-long      2 retired-osc "an osc command"
case_ reviewer-osc-co-plain     2 retired-osc "an osc command"
case_ reviewer-bash-opts        2 incoming-self "gate.sh from agent incoming-review"
case_ reviewer-pool-pr          2 incoming-self "pool-pr.sh from agent incoming-review"
case_ reviewer-leap-sync        2 incoming-self "leap-sync.sh from agent incoming-review"
case_ reviewer-quilt-script     2 incoming-self "quilt-setup.sh from agent incoming-review"
# The reviewing agents decline nothing: no revoke, supersede, decline or close either.
case_ reviewer-revoke           2 retired-osc "an osc command"
case_ reviewer-supersede        2 retired-osc "an osc command"
case_ reviewer-decline          2 retired-osc "an osc command"
case_ reviewer-tea-close        2 incoming-self "tea pulls close from agent changes-review"
case_ reviewer-git-obs-close    2 incoming-self "git-obs pr close from agent incoming-review"
case_ reviewer-api-revoke       2 retired-osc "an osc command"
# A review of a repository named like the package holds its forward unless it is shown
# not to: a package that syncs from no repository, or from another one, refuses it.
case_ forward-hold-no-scmsync   2 retired-osc "an osc command"
case_ forward-hold-other-org    2 retired-osc "an osc command"
case_ forward-after-followup    2 retired-osc "an osc command" HOME="$work/listless"
# The incoming-review agent commits nothing (osc commit runs the local source services),
# and its call names nothing that changes which program a name runs: PATH as a word or
# a variable, BASH_ENV, ENV=, the hash builtin, a nameref. The main session may.
case_ reviewer-osc-ci 2 retired-osc "an osc command"
case_ reviewer-osc-commit 2 retired-osc "an osc command"
case_ osc-ci-devel 2 retired-osc "an osc command"
for name in reviewer-path-prefix reviewer-path-export reviewer-path-for reviewer-path-subscript \
    reviewer-path-select reviewer-path-let reviewer-path-printf reviewer-path-read; do
  case_ "$name" 2 incoming-self "PATH from agent incoming-review"
done
case_ reviewer-path-nameref     2 incoming-self "typeset -n from agent incoming-review"
case_ reviewer-path-hash        2 incoming-self "hash from agent incoming-review"
case_ reviewer-path-bash-env    2 incoming-self "BASH_ENV from agent incoming-review"
case_ reviewer-path-env         2 incoming-self "ENV= from agent incoming-review"
case_ reviewer-path-main        0 - ""
case_ reviewer-path-subscript-main 0 - ""
case_ reviewer-hash-main        0 - ""
# Nor a name it builds or brace-expands, a command word only the shell knows, a file it
# sources, or PS4, whose substitutions bash -x runs.
for name in reviewer-path-built-printf reviewer-path-built-read reviewer-path-built-export; do
  case_ "$name" 2 incoming-self "x from agent incoming-review"
done
case_ reviewer-path-built-declare 2 incoming-self "x} from agent incoming-review"
case_ reviewer-path-brace-export 2 incoming-self "PATH from agent incoming-review"
case_ reviewer-path-brace-declare 2 incoming-self "PATH from agent incoming-review"
case_ reviewer-path-source      2 incoming-self "source from agent incoming-review"
case_ reviewer-path-dot         2 incoming-self ". from agent incoming-review"
case_ reviewer-path-built-hash  2 incoming-self "the command word"
case_ reviewer-path-ps4         2 incoming-self "PS4 from agent incoming-review"
case_ reviewer-path-built-main  0 - ""
case_ reviewer-path-brace-main  0 - ""
# Nor an arithmetic context or allexport, which set a variable by a name it builds,
# nor a shell's rc file (--rcfile, --init-file, -i), which runs unread.
for name in reviewer-arith-paren reviewer-arith-let reviewer-arith-test \
    reviewer-arith-declare-i reviewer-arith-subscript reviewer-arith-expansion; do
  case_ "$name" 2 incoming-self "an arithmetic context from agent incoming-review"
done
case_ reviewer-allexport        2 incoming-self "allexport from agent incoming-review"
case_ reviewer-rcfile           2 incoming-self "--rcfile"
case_ reviewer-init-file        2 incoming-self "--init-file"
case_ reviewer-bash-i           2 incoming-self "bash -i from agent incoming-review"

echo "--- the command a wrapper runs is judged: fakeroot, strace, ltrace, unshare, flock, taskset, chrt, prlimit, systemd-run, nsenter, setpriv, script -c"
# script's -c in a cluster, attached, by a prefix of --command or after its file; chrt's
# policy option without a priority.
for n in fakeroot strace ltrace unshare flock flock-c taskset chrt prlimit systemd-run nsenter setpriv script-c \
  script-qc script-attached script-long-prefix script-after-file chrt-policy; do
  case_ "wrap-$n" 2 retired-osc "an osc command"
done
case_ reviewer-script-qc        2 incoming-self "rpmspec from agent incoming-review"
# A script of the agent's named like a wrapper, run by its path, is read as a script:
# only a bare name or an ELF binary unwraps.
for n in flock script nohup; do
  case_ "wrapname-$n" 2 retired-osc "an osc command"
done
case_ wrapname-strace           2 incoming-self "rpmspec from agent incoming-review"
# A wrapper by a variable's path is the real one once the call's value places it: unwrapped
# when it is an ELF binary; one only the shell can place is refused, in a script too.
case_ wrapvar-nice-decline 2 retired-osc "an osc command"
for n in timeout nohup-quoted env-braced in-script script-qc; do
  case_ "wrapvar-$n" 2 retired-osc "an osc command"
done
case_ wrapvar-nice-approve       2 incoming-approve "approving incorg/incgit#5: it names no --commit SHA"
case_ wrapvar-push               2 push-pr-head "pool/tesseract-ocr#3"
case_ wrapvar-merge              2 merge-tea "tea PR merge"
case_ wrapvar-reviewer-flock     2 exec-unreadable "cannot read \$D/flock (/usr/bin/flock: No such file or directory)"
case_ wrapvar-unset-in-script    2 exec-unresolved "UNSET_DIR/flock"

echo "--- the harness's own files are the user's: no agent command writes, moves or deletes them"
case_ harness-cp-hooks          2 harness-write "cp ~/.claude/hooks/_pr_guard.py"
case_ harness-redirect-settings 2 harness-write "a redirection to ~/.claude/settings.json"
case_ harness-rm-claude         2 harness-write "rm ~/.claude"
case_ harness-mv-plugin         2 harness-write "mv ~/.config/opencode/plugins/pool-pr-guard.ts"
case_ harness-sed-hooks         2 harness-write "sed ~/.claude/hooks/_pr_guard.py"
case_ harness-cd-rm             2 harness-write "rm pr-guard.py"
case_ harness-write-tool        2 harness-write "a write to $HOME/.config/opencode/plugins/x.ts"
case_ harness-read              0 - ""
case_ harness-copy-out          0 - ""
# Claude Code's settings in any directory (a project's settings.local.json can switch the
# hooks off), and a tree written into ~/.claude or ~/.config/opencode or deleted below them.
case_ harness-project-settings  2 harness-write "a redirection to /var/tmp/proj/.claude/settings.local.json"
case_ harness-user-settings-local 2 harness-write "cp ~/.claude/settings.local.json"
case_ harness-parent-cp         2 harness-write "cp ~/.claude/"
case_ harness-parent-tar        2 harness-write "tar ~/.config/opencode"
case_ harness-find-delete       2 harness-write "find ~/.claude"
case_ harness-claude-md         0 - ""

echo "--- a change review is recorded by the changes-review agent that ran it"
ask_ review-main-session        review-self "gate.sh --review from the main session"
ask_ review-author-agent        review-self "gate.sh --review from agent osc-update-build"
ask_ review-bash-wrapped        review-self "gate.sh --review from agent general-purpose"
ask_ review-in-script           review-self "gate.sh --review from the main session"
case_ review-reviewer-agent     0 - ""
case_ review-reviewer-session   0 - ""
case_ review-gate-run           0 - ""
# Every spelling that reaches gate.sh: shell options before the script, --review held
# in a variable, an argument the guard cannot read (an array, a substitution, a
# function's "$@", what xargs adds).
for n in review-bash-options review-bash-o review-bash-O review-bash-rcfile review-variable; do
  ask_ "$n" review-self "gate.sh --review from the main session"
done
for n in review-array review-function review-script-array review-ifs; do
  ask_ "$n" gate-args "gate.sh from the main session with an argument only the shell knows"
done
ask_ review-xargs               gate-args "gate.sh from the main session with the arguments xargs adds"
# --no-entry takes the next word, as --cleaner-deviation does: its value is no --review.
case_ gate-no-entry-value        0 - ""
# Each names the skill's own gate.sh by its absolute path.
case_ sr-unbuilt 2 retired-osc "an osc command" PR_GUARD_SKILL_DIR="$S"
ask_ review-array               gate-args "Write $S/scripts/gate.sh's arguments out literally" PR_GUARD_SKILL_DIR="$S"
ask_ review-main-session        review-self "runs $S/scripts/gate.sh --review itself" PR_GUARD_SKILL_DIR="$S"
# A substitution whose text spells --review is a review, wherever it stands.
for n in review-brace review-brace-empty review-symlink review-substitution review-substitution-last review-unknown-word; do
  ask_ "$n" review-self "gate.sh --review from the main session"
done
ask_ review-copy                review-self "gate.sh --review from the main session" PR_GUARD_SKILL_DIR="$work/skill-gate"
ask_ review-stdin               review-self "bash reading stdin --review from the main session"
ask_ review-stdin-pipe          review-self "bash reading stdin --review from the main session"
# An argument the guard cannot read where it cannot be --review: a lone last one
# (--review takes a file after it), or a valued option's value.
case_ gate-run-pwd              0 - ""
case_ gate-run-build-log        0 - ""
case_ gate-run-loop             0 - ""
case_ review-gate-run-main      0 - ""
case_ review-reviewer-array     0 - ""
echo "--- a commit or a request carries only a tree gate.sh judged, the request a reviewed one"
case_ ci-unstamped 2 retired-osc "an osc command"
case_ ci-scmsync                 2 retired-osc "an osc command"
# The skill's scripts by their absolute path: told "Run scripts/gate.sh in the checkout",
# agents wrote a gate of their own into the package checkout.
case_ ci-unstamped 2 retired-osc "an osc command" PR_GUARD_SKILL_DIR="$S"
case_ ci-unstamped 2 retired-osc "an osc command"
case_ ci-edited-after-gate 2 retired-osc "an osc command"
case_ ci-project-checkout 2 retired-osc "an osc command"
case_ sr-unstamped 2 retired-osc "an osc command"
case_ sr-unreviewed 2 retired-osc "an osc command"
case_ sr-restaged 2 retired-osc "an osc command"
case_ sr-unbuilt 2 retired-osc "an osc command"
# A tree gated under --no-entry goes to a devel project, never to openSUSE:Factory: its
# factory-auto declines a request with no new .changes entry whatever the reason.
case_ sr-factory-no-entry 2 retired-osc "an osc command"
case_ sr-devel-no-entry         2 retired-osc "an osc command"
# gate.sh --obs-build judges the Factory/Tumbleweed repos: that build covers a request to
# Factory or the devel project, another target only through the repos --repos added.
case_ sr-obs-factory            2 retired-osc "an osc command"
case_ sr-obs-devel              2 retired-osc "an osc command"
case_ sr-obs-factory-leap 2 retired-osc "an osc command"
case_ sr-obs-factory-leap 2 retired-osc "an osc command"
case_ sr-obs-repos-leap         2 retired-osc "an osc command"
case_ sr-obs-repos-leap-other 2 retired-osc "an osc command"
case_ sr-obs-sle-sp             2 retired-osc "an osc command"
# A default stamp's green Leap 16 repo covers a Leap 16 target only: a product whose
# version the guard cannot read, or any other, needs a repo --repos added for it.
case_ sr-obs-default-sle15 2 retired-osc "an osc command"
case_ sr-obs-default-slfo 2 retired-osc "an osc command"
case_ sr-obs-default-step 2 retired-osc "an osc command"
# A version alone is not enough: 16.0 of a non-Leap product is no Leap 16 target.
case_ sr-obs-default-sles16 2 retired-osc "an osc command"
# No Tumbleweed build succeeded (both arches PRE-EXISTING), so Factory is not covered.
case_ sr-obs-nofac-factory 2 retired-osc "an osc command"
case_ sr-obs-sle-other 2 retired-osc "an osc command"
# No written target: osc picks the link or devel target, which a Factory-judged build covers.
case_ sr-obs-bare               2 retired-osc "an osc command"
# A GREEN build whose only reds are PRE-EXISTING (devel has them too) covers Factory and devel.
case_ sr-obs-pre-factory        2 retired-osc "an osc command"
case_ sr-obs-pre-devel          2 retired-osc "an osc command"
case_ sr-unlistable 2 retired-osc "an osc command"
case_ sr-no-source 2 retired-osc "an osc command"
# A "." the guard cannot place names no project it can judge.
case_ sr-dot-cwd-unknown        2 retired-osc "an osc command"
# Judged before the call runs: anything else in it that can write may change the tree first.
case_ ci-after-append          2 retired-osc "an osc command"
case_ ci-sr-after-append       2 retired-osc "an osc command"
case_ ci-after-sed             2 retired-osc "an osc command"
case_ ci-after-osc-add         2 retired-osc "an osc command"
case_ ci-after-script          2 retired-osc "an osc command"
case_ ci-loop-edit-after       2 retired-osc "an osc command"
case_ ci-then-sr               2 retired-osc "an osc command"
# Recording the review and committing in one call, eleven times in one session: a fault
# the agent fixes by splitting the call, so it is refused with the order to follow.
case_ ci-after-review            2 retired-osc "an osc command"
case_ ci-after-review            2 retired-osc "an osc command"
case_ ci-unstamped-after-gate    2 retired-osc "an osc command"
case_ ci-redirect-devnull       2 retired-osc "an osc command"
case_ accept-api-approve        2 retired-osc "an osc command"
case_ accept-api-slash          2 retired-osc "an osc command"
ask_ comment-git-obs-reopen     comment "git-obs pr reopen with a comment"
# A reopen without a comment is no comment; of a PR someone else opened, it asks as a reopen.
ask_ comment-git-obs-reopen-plain others-request "git-obs pr reopen AI/mistral-vibe#3: opened by other"
# A commit is refused only for a write that runs before it and lands in its checkout; a request
# for any write anywhere in the call.
case_ ci-after-sort-o          2 retired-osc "an osc command"
case_ ci-after-uniq-out        2 retired-osc "an osc command"
case_ ci-git-C-status           2 retired-osc "an osc command"
case_ ci-log-redirect           2 retired-osc "an osc command"
case_ ci-log-tee                2 retired-osc "an osc command"
case_ ci-note-outside           2 retired-osc "an osc command"
case_ ci-while-edit-after      2 retired-osc "an osc command"
# A path through a link and .. lands where the link points, not where normpath says.
mkdir -p "$work/osc/devel/x/sub" && ln -sfn "$work/osc/devel/x/sub" "$work/links/co"
case_ ci-symlink-dotdot        2 retired-osc "an osc command"
# What runs beside the commit, backgrounded or in its pipeline, writes during it.
case_ ci-background-then-edit  2 retired-osc "an osc command"
case_ ci-pipe-tee-into         2 retired-osc "an osc command"
# Registering a trap and waiting write nothing: a request beside them stays unasked.
case_ sr-trap-wait              2 retired-osc "an osc command"
# A trap's command runs when the call ends, after every write in it.
case_ trap-ci-then-append      2 retired-osc "an osc command"
case_ trap-ci-then-sed         2 retired-osc "an osc command"
case_ trap-cleanup-then-ci      2 retired-osc "an osc command"
# A backgrounded group, every command of it; coproc runs in the background too.
case_ ci-brace-background      2 retired-osc "an osc command"
case_ ci-subshell-background   2 retired-osc "an osc command"
case_ ci-coproc                2 retired-osc "an osc command"
# A submit sends what OBS holds: only a write before it that can change that counts --
# a commit, a script, a write into a checkout -- not its own log or one outside checkouts.
case_ sr-after-write-anywhere   2 retired-osc "an osc command"
case_ seq-sr-tee-log             2 retired-osc "an osc command"
case_ seq-sr-redirect-out        2 retired-osc "an osc command"
case_ seq-sr-after-checkout-write 2 retired-osc "an osc command"
# A directory made outside the checkout changes none of its files.
case_ seq-mkdir-then-ci          2 retired-osc "an osc command"
# cp, rm and tar with a known target outside the checkout change none of its files;
# into it (a copy over the spec, an archive unpacked there) they do.
case_ seq-cp-out-then-ci         2 retired-osc "an osc command"
case_ seq-rm-out-then-ci         2 retired-osc "an osc command"
case_ seq-tar-out-then-ci        2 retired-osc "an osc command"
case_ seq-cp-in-then-ci          2 retired-osc "an osc command"
case_ seq-tar-x-then-ci          2 retired-osc "an osc command"
# A destination that holds the checkout writes into it too: a copy or unpack into its project
# directory or "..". One in the home directory or in another checkout does not.
case_ seq-cp-project-then-ci     2 retired-osc "an osc command"
case_ seq-cp-dotdot-then-ci      2 retired-osc "an osc command"
case_ seq-tar-x-dotdot-then-ci   2 retired-osc "an osc command"
case_ seq-cp-project-then-sr     2 retired-osc "an osc command"
case_ seq-cp-home-then-ci        2 retired-osc "an osc command"
case_ seq-cp-other-co-then-ci    2 retired-osc "an osc command"
# The account: geectl config show, once per call and in memory only. A file a
# call can write is no source for it: an earlier call could name someone else there.
mkdir -p "$work/whois/bin" "$work/whois/home/.cache/opensuse-packaging"
# shellcheck disable=SC2016  # the fake geectl's own $1 and $*, expanded when it runs
printf '#!/bin/bash\n[ "$1" = --format ] && [ "$2" = json ] && [ "$3" = config ] && [ "$4" = show ] || exit 99\necho "geectl $*" >> "%s/calls"\necho \"{\\\"obs_auth\\\": {\\\"username\\\": \\\"tester\\\", \\\"status\\\": \\\"configured\\\"}}\"\n' \
  "$work/whois" > "$work/whois/bin/geectl"; chmod +x "$work/whois/bin/geectl"
for f in pr-guard-user-da39a3ee5e6b4b0d pr-guard-user; do
  printf 'other\n' > "$work/whois/home/.cache/opensuse-packaging/$f"
done
used="$used geectl-accept-others-maintained geectl-accept-own "
whois_() { ev "$1" | env -u PR_GUARD_OBS_USER HOME="$work/whois/home" PATH="$work/whois/bin:$PATH" \
  python3 "$GUARD" 2>&1; }
out="$(whois_ geectl-accept-others-maintained)"
grep -qF "BLOCKED [incoming-accept] accepting request 1390007 by other: science:machinelearning/dlib is maintained by other" <<<"$out" \
  && pass "an account written to a file is not taken: the accept of another maintainer's package is refused" \
  || fail "a planted account was taken: $out"
touch "$work/whois/mark"; sleep 1
out="$(whois_ geectl-accept-own)"
[ "$(grep -c "config show" "$work/whois/calls")" = 2 ] && grep -qF "ASK [accept-forward] accepting request 1390004" <<<"$out" \
  && [ -z "$(find "$work/whois/home" -newer "$work/whois/mark" 2>/dev/null)" ] \
  && pass "geectl config show runs once per call and nothing is written for the next one" \
  || fail "config show: $(grep -c "config show" "$work/whois/calls") calls, written: $(find "$work/whois/home" -newer "$work/whois/mark")"
echo "--- deletes never take requests with them: one package at a time, no force"
case_ rdelete-force-recursive     2 retired-osc "an osc command"
case_ rdelete-force-combined      2 retired-osc "an osc command"
case_ rdelete-force-abbrev        2 retired-osc "an osc command"
case_ rdelete-force-apiurl        2 retired-osc "an osc command"
case_ rdelete-recursive-project   2 retired-osc "an osc command"
case_ rdelete-recursive-long      2 retired-osc "an osc command"
case_ rdelete-var-force           2 retired-osc "an osc command"
case_ rdelete-var-unknown         2 retired-osc "an osc command"
case_ rdelete-guessed-osc         2 retired-osc "an osc command"
case_ rdelete-plain-package       2 retired-osc "an osc command"
case_ rdelete-var-message        2 retired-osc "an osc command"
case_ rdelete-empty-project       2 retired-osc "an osc command"
case_ rdelete-for-literal         2 retired-osc "an osc command"
# The geectl form: a forced or recursive delete, and one naming what it deletes
# only through a variable.
case_ geectl-rdelete-pending           2 rdelete-pending "geectl remote delete-package --force"
case_ geectl-rdelete-project-recursive 2 rdelete-pending "geectl remote delete-project --recursive"
case_ geectl-rdelete-unknown           2 rdelete-unknown "geectl remote delete-package with \$PKG"
case_ api-delete-source           2 retired-osc "an osc command"
case_ api-delete-joined           2 retired-osc "an osc command"
case_ api-delete-method           2 retired-osc "an osc command"
case_ api-delete-method-eq        2 retired-osc "an osc command"
case_ api-delete-var              2 retired-osc "an osc command"
case_ api-delete-var-unknown      2 retired-osc "an osc command"
case_ api-get-source              2 retired-osc "an osc command"
case_ api-delete-m                2 retired-osc "an osc command"
case_ api-delete-m-joined         2 retired-osc "an osc command"
case_ api-delete-m-force          2 retired-osc "an osc command"
# OBS reads the path decoded, slashes collapsed and dot segments resolved:
# "/source/$P/$K/" with an empty K is project P.
case_ api-delete-double-slash     2 retired-osc "an osc command"
case_ api-delete-empty-var        2 retired-osc "an osc command"
case_ api-delete-dotdot           2 retired-osc "an osc command"
case_ api-delete-encoded-dot      2 retired-osc "an osc command"
# A file, the _link or an attribute is no project or package: nothing is revoked.
case_ api-delete-link             2 retired-osc "an osc command"
case_ api-delete-file             2 retired-osc "an osc command"
case_ api-delete-attribute        2 retired-osc "an osc command"
# ... wherever the message comes from: a substitution, a file, stdin, a variable,
# a --message prefix. Only the prose counts, the text before a "- "/"* " list.
case_ msg-subst-cat-long         2 retired-osc "an osc command"
# read, printf -v, declare -n and mapfile leave a value only the shell knows; a
# substitution's files are placed where its own cd leaves it; printf widths,
# reused formats and brace expansion are unknown; a loop's many spellings are
# measured by their longest.
case_ msg-read-stale             2 retired-osc "an osc command"
case_ msg-printf-v-stale         2 retired-osc "an osc command"
case_ msg-declare-n              2 retired-osc "an osc command"
case_ msg-mapfile                2 retired-osc "an osc command"
case_ msg-subst-cd               2 retired-osc "an osc command"
case_ msg-subst-cd-unknown       2 retired-osc "an osc command"
# 70 packages are more spellings than the guard expands: which ones it forwards is unknown.
case_ msg-loop-70-short 2 retired-osc "an osc command"
case_ msg-loop-70-long           2 retired-osc "an osc command"
case_ msg-printf-width           2 retired-osc "an osc command"
case_ msg-printf-reuse           2 retired-osc "an osc command"
case_ msg-echo-brace             2 retired-osc "an osc command"
# Text is resolved like a -m word: stdin, here-strings, echo/printf of variables,
# expanding heredocs, += and every writer of a substitution; unknown is refused.
case_ msg-herestring-var-long    2 retired-osc "an osc command"
case_ msg-echo-var-pipe-long     2 retired-osc "an osc command"
case_ msg-printf-subst-long      2 retired-osc "an osc command"
case_ msg-heredoc-expanding-long 2 retired-osc "an osc command"
case_ msg-plus-equals-long       2 retired-osc "an osc command"
case_ msg-subst-two-writers-long 2 retired-osc "an osc command"
case_ msg-echo-unset-pipe        2 retired-osc "an osc command"
case_ msg-heredoc-expanding-unset 2 retired-osc "an osc command"
# Every line but a "- " item is prose, wherever it sits; an item is at most 100
# characters, the message 1000.
case_ msg-changes-bullets        2 retired-osc "an osc command"
case_ msg-changes-entries        2 retired-osc "an osc command"
case_ msg-prose-after-list       2 retired-osc "an osc command"
case_ msg-long-list-line         2 retired-osc "an osc command"
case_ msg-list-over-1000         2 retired-osc "an osc command"
case_ msg-star-list              2 retired-osc "an osc command"
# Single quotes, $'...' and \$ are literal; $(<FILE) reads FILE.
case_ msg-single-quoted-dollar   2 retired-osc "an osc command"
case_ msg-ansi-c-quoted          2 retired-osc "an osc command"
case_ msg-escaped-dollar         2 retired-osc "an osc command"
case_ msg-double-quoted-unset    2 retired-osc "an osc command"
case_ msg-heredoc-quoted-dollar  2 retired-osc "an osc command"
case_ msg-subst-redirect-long    2 retired-osc "an osc command"
case_ msg-subst-redirect-short   2 retired-osc "an osc command"
case_ msg-subst-cat-short        2 retired-osc "an osc command"
case_ msg-subst-heredoc-long     2 retired-osc "an osc command"
case_ msg-subst-heredoc-short    2 retired-osc "an osc command"
case_ msg-file-long              2 retired-osc "an osc command"
case_ msg-file-short             2 retired-osc "an osc command"
case_ msg-file-stdin-long        2 retired-osc "an osc command"
case_ msg-file-stdin-short       2 retired-osc "an osc command"
case_ msg-var-long               2 retired-osc "an osc command"
case_ msg-var-short              2 retired-osc "an osc command"
case_ msg-var-subst-long         2 retired-osc "an osc command"
case_ msg-prefix-eq-long         2 retired-osc "an osc command"
case_ msg-prefix-space-long      2 retired-osc "an osc command"
case_ msg-prefix-short           2 retired-osc "an osc command"
case_ msg-prose-then-list        2 retired-osc "an osc command"
case_ msg-inline-prose-then-list 2 retired-osc "an osc command"
case_ msg-long-prose-then-list   2 retired-osc "an osc command"
case_ msg-deletereq-long         2 retired-osc "an osc command"
case_ msg-changedevel-long       2 retired-osc "an osc command"
case_ msg-dr-short               2 retired-osc "an osc command"
# A message it cannot read now is refused.
case_ msg-var-unset              2 retired-osc "an osc command"
case_ msg-file-missing           2 retired-osc "an osc command"
case_ msg-file-written           2 retired-osc "an osc command"
case_ msg-stdin-unknown          2 retired-osc "an osc command"
case_ msg-subst-unknown          2 retired-osc "an osc command"

echo "--- a help invocation of a guarded tool does nothing"
case_ help-tea-create           0 - ""
case_ help-tea-merge-h          0 - ""
case_ help-git-obs-merge        0 - ""
case_ help-git-obs-space-create 0 - ""
case_ help-git-push             0 - ""
case_ help-osc-build            0 - ""
# ... unless it is an option's value or an operand, and a script is read whatever its arguments.
case_ help-as-option-value      2 create-tea   "tea PR create"
case_ help-after-dashdash       2 push-pr-head "pool/tesseract-ocr#3"
case_ help-script-still-read    2 create-api   "a write to pool pulls"

echo "--- credential files are read only by the tools that own them"
# On the agent's own command line: named as written, placed in the cwd a cd
# leaves or the event gives, through this call's values, dot segments, globs
# and symlinks; the first is the field's token scrape.
case_ cred-tea-scrape-field      2 credential-read "grep reads ~/.config/tea/config.yml"
case_ cred-home-var              2 credential-read "grep reads ~/.config/tea/config.yml"
case_ cred-dot-segment           2 credential-read "cat reads ~/.config/tea/config.yml"
case_ cred-relative-cwd          2 credential-read "cat reads ~/.config/tea/config.yml"
case_ cred-cd-relative           2 credential-read "head reads ~/.config/tea/config.yml"
case_ cred-glob                  2 credential-read "cat reads ~/.config/tea/config.yml"
case_ cred-var-assigned          2 credential-read "awk reads ~/.netrc"
case_ cred-symlink               2 credential-read "cat reads ~/.config/tea/config.yml"
case_ cred-oscrc-sed             2 credential-read "sed reads ~/.config/osc/oscrc"
case_ cred-source-oscrc          2 credential-read "source reads ~/.config/osc/oscrc"
case_ cred-cookiejar-cp          2 credential-read "cp reads ~/.local/state/osc/cookiejar"
case_ cred-gh-hosts              2 credential-read "yq reads ~/.config/gh/hosts.yml"
# An SSH private key is a login too; its public half and known_hosts are not.
mkdir -p "$HOME/.ssh"
case_ cred-ssh-key               2 credential-read "cat reads ~/.ssh/id_ed25519"
case_ cred-ssh-key-abs           2 credential-read "base64 reads /home/agent/.ssh/id_rsa"
case_ cred-ssh-key-recursive     2 credential-read "tar reaches the credential files under ~/.ssh"
case_ cred-ssh-pub               0 - ""
case_ cred-ssh-known-hosts       0 - ""
case_ cred-git-credentials       2 credential-read "cut reads ~/.git-credentials"
case_ cred-xdg-git-credentials   2 credential-read "cut reads ~/.config/git/credentials"
case_ cred-xdg-config-home       2 credential-read "head reads \$XDG_CONFIG_HOME/git/credentials"
case_ cred-xdg-git-unplaced      2 credential-read "cat reads \$D/.config/git/credentials"
case_ cred-xdg-git-recursive     2 credential-read "grep reaches the credential files under ~/.config/git"
case_ cred-xdg-git-dir-cwd       2 credential-read "head reads ~/.config/git/credentials"
case_ cred-xdg-default-form      2 credential-read "cat reads \${XDG_CONFIG_HOME:-\$HOME/.config}/git/credentials"
case_ cred-xdg-git-config-ok     0 - ""
case_ cred-mcp-api-key           2 credential-read "cat reads ~/.config/mcp-bugzilla/api-key"
# The opencode server's password: whoever reads it answers that server's prompts.
case_ cred-opencode-service      2 credential-read "cat reads ~/.local/state/opencode/service.json"
case_ cred-opencode-xdg          2 credential-read "opencode/service.json"
case_ cred-opencode-service-version 2 credential-read "cat reads ~/.local/state/opencode/service-2.2.7.json"
case_ cred-redirect              2 credential-read "a redirection reads ~/.netrc"
case_ cred-subst-redirect        2 credential-read "a redirection reads ~/.netrc"
case_ cred-bash-c                2 credential-read "head reads ~/.git-credentials"
case_ cred-xargs-file            2 credential-read "xargs reads ~/.netrc"
case_ cred-parallel-input        2 credential-read "parallel reads ~/.netrc"
case_ cred-parallel-arg-file     2 credential-read "parallel reads ~/.config/tea/config.yml"
case_ cred-parallel-quad         2 credential-read "parallel reads ~/.git-credentials"
case_ cred-wrapper-watch         2 credential-read "xargs reads ~/.netrc"
case_ cred-wrapper-parallel      2 credential-read "xargs reads ~/.git-credentials"
case_ cred-find-exec             2 credential-read "find reads ~/.config/gh"
case_ cred-cwd-unknown-oscrc     2 credential-read "cat reads oscrc"
# A recursive read of a directory above them reads them too.
case_ cred-recursive-grep        2 credential-read "grep reaches the credential files under ~/.config"
case_ cred-recursive-tar         2 credential-read "tar reaches the credential files under ~/.local"
case_ cred-recursive-rg-cwd      2 credential-read "rg reaches the credential files under ~"
# A brace expansion names each word bash expands it to: lists and sequences,
# nested, into the pattern's place or the command's; past 64 words it is unknown.
case_ cred-brace-list            2 credential-read "cat reads ~/.config/osc/oscrc"
case_ cred-brace-quoted-space    2 credential-read "cat reads ~/.config/osc/oscrc"
case_ cred-brace-escaped-space   2 credential-read "cat reads ~/.config/osc/oscrc"
case_ cred-brace-glob            2 credential-read "head reads ~/.config/tea/config.yml"
case_ cred-brace-grep            2 credential-read "grep reads ~/.config/tea/config.yml"
case_ cred-brace-dotfiles        2 credential-read "cat reads ~/.netrc"
case_ cred-brace-recursive       2 credential-read "grep reaches the credential files under ~/.config"
case_ cred-brace-tar             2 credential-read "tar reads ~/.config/tea"
case_ cred-brace-nested          2 credential-read "cat reads ~/.config/gh/hosts.yml"
case_ cred-brace-sequence        2 credential-read "cat reads ~/.config/mcp-bugzilla/api-key"
case_ cred-brace-pattern-shift   2 credential-read "grep reads ~/.netrc"
case_ cred-brace-command         2 credential-read "head reads ~/.git-credentials"
case_ cred-brace-redirect        2 credential-read "a redirection reads ~/.netrc"
case_ cred-brace-too-many        2 credential-read "a brace expansion past 64 words"
# Looking is not reading, a write is not a read, and a word is not a file:
# a search pattern, a commit message, a package named for a helper.
case_ cred-ls-config             0 - ""
case_ cred-stat-test             0 - ""
case_ cred-ls-in-cred-dir        0 - ""
case_ cred-find-listing          0 - ""
case_ cred-write-fake-config     0 - ""
case_ cred-spec-oauth            2 retired-osc "an osc command"
case_ cred-spec-askpass          0 - ""
case_ cred-grep-pattern          0 - ""
case_ cred-commit-message        0 - ""
case_ cred-grep-elsewhere        0 - ""
case_ cred-brace-sources         0 - ""
case_ cred-brace-quoted-echo     0 - ""
case_ cred-brace-ls              0 - ""
case_ cred-brace-ls-many         0 - ""
case_ cred-brace-backup          0 - ""
case_ cred-brace-find-exec       0 - ""
case_ cred-brace-sequence-small  0 - ""
case_ cred-parallel-plain        0 - ""
# The tools read their own: osc its --config, git-obs its --gitea-config.
case_ cred-osc-own-config        2 credential-read "osc reads ~/.config/osc/oscrc: a login is read only by the tool that"
case_ cred-git-obs-own-config    0 - ""
# A grep that prints only a build-* setting of oscrc (build-summary.sh and
# target-gate.sh read build-root so); any other key or a context option reads more.
case_ cred-build-root-grep       0 - ""
case_ cred-oscrc-grep-pass       2 credential-read "grep reads ~/.config/osc/oscrc"
case_ cred-oscrc-grep-context    2 credential-read "grep reads ~/.config/osc/oscrc"
# An askpass program hands git or ssh a password: setting one, or running or
# reading it, is refused; testing that one is set is not.
case_ askpass-run                2 askpass "\$GIT_ASKPASS"
case_ askpass-cat                2 askpass "\$SSH_ASKPASS"
case_ askpass-env-clone          2 askpass "GIT_ASKPASS"
case_ askpass-push-fork          2 askpass "GIT_ASKPASS"
case_ askpass-export             2 askpass "SSH_ASKPASS"
case_ askpass-alone              2 askpass "GIT_ASKPASS"
case_ askpass-env-wrapper        2 askpass "GIT_ASKPASS"
case_ askpass-git-c              2 askpass "core.askPass"
case_ askpass-git-config         2 askpass "core.askpass"
case_ askpass-test-set           0 - ""
case_ askpass-git-config-get     0 - ""

echo "--- the tools' own secret printers"
case_ secret-gh-token            2 secret-gh      "gh auth token"
case_ secret-gh-status           2 secret-gh      "gh auth status"
case_ secret-gh-git-credential   2 secret-gh      "gh auth git-credential"
case_ secret-git-obs-login-list  2 secret-git-obs "git-obs login list"
case_ secret-git-obs-space       2 secret-git-obs "git-obs login list"
case_ secret-git-obs-helper      2 secret-git-obs "git-obs gitcredentials-helper"
case_ secret-tea-helper          2 secret-tea     "tea login helper"
case_ secret-tea-edit            2 secret-tea     "tea logins e"
case_ secret-osc-dump-full       2 retired-osc     "an osc command"
case_ secret-osc-dump-prefix     2 retired-osc     "an osc command"
case_ secret-osc-dump-var        2 retired-osc     "an osc command"
case_ secret-osc-dump-var-unknown 2 retired-osc    "an osc command"
case_ secret-osc-http-debug      2 retired-osc     "an osc command"
case_ secret-osc-http-debug-cluster 2 retired-osc  "an osc command"
case_ secret-osc-http-full-prefix 2 retired-osc    "an osc command"
case_ secret-osc-setopt-debug    2 retired-osc     "an osc command"
case_ secret-osc-env-debug       2 retired-osc     "an osc command"
case_ secret-osc-token           2 retired-osc     "an osc command"
case_ secret-osc-token-apiurl    2 retired-osc     "an osc command"
case_ secret-osc-quoted          2 retired-osc     "an osc command"
case_ secret-osc-config-pass     2 retired-osc     "an osc command"
case_ secret-osc-api-person-token 2 retired-osc    "an osc command"
case_ geectl-secret-create-token 2 secret-geectl "geectl remote create-token"
case_ secret-git-credential-fill 2 secret-git     "git credential fill"
case_ secret-git-credential-helper 2 secret-git   "git credential-libsecret get"
case_ secret-git-credential-direct 2 secret-git   "git-credential-oauth get"
case_ secret-tool-lookup         2 secret-tool    "secret-tool lookup"
case_ secret-tool-search         2 secret-tool    "secret-tool search"
case_ secret-gh-pr-list          0 - ""
case_ secret-tea-login-list      0 - ""
case_ secret-osc-dump            2 retired-osc "an osc command"
case_ secret-osc-config-build-root 2 retired-osc "an osc command"
case_ secret-osc-api-person      2 retired-osc "an osc command"
case_ secret-osc-whois           2 retired-osc "an osc command"
case_ secret-osc-token-help      0 - ""
case_ secret-git-config-helper   0 - ""
case_ secret-names-only          2 retired-osc "an osc command"
case_ secret-git-obs-api-user    0 - ""

echo "--- a credential on a command line"
case_ auth-header-curl           2 auth-header "curl with a credential header (Authorization)"
case_ auth-header-wget           2 auth-header "wget with a credential header (Authorization)"
case_ auth-private-token         2 auth-header "curl with a credential header (PRIVATE-TOKEN)"
case_ auth-httpie-header         2 auth-header "http with a credential header (Authorization)"
case_ auth-tea-api-header        2 auth-header "tea api with a credential header (Authorization)"
case_ auth-git-obs-api-header    2 auth-header "git-obs api with a credential header (Authorization)"
case_ auth-git-extraheader       2 auth-header "git with a credential header (Authorization)"
case_ auth-user-pass-curl        2 auth-user   "curl -u with a password"
case_ auth-curl-no-slash         2 auth-user   "curl -u with a password"
case_ auth-xh-auth               2 auth-user   "xh -a with a password"
case_ auth-httpie-bearer         2 auth-user   "https -a with a secret"
case_ auth-curl-bearer-opt       2 auth-user   "curl --oauth2-bearer"
case_ auth-wget-password         2 auth-user   "wget --password"
case_ auth-url-userinfo          2 auth-url    "curl with a password in a URL"
case_ auth-git-clone-userinfo    2 auth-url    "git with a password in a URL"
case_ auth-accept-header         0 - ""
case_ auth-clone-public          0 - ""
case_ auth-clone-ssh             0 - ""
for name in auth-user-pass-curl auth-curl-no-slash auth-xh-auth auth-wget-password auth-url-userinfo auth-git-clone-userinfo; do
  out="$(ev "$name" | python3 "$GUARD" 2>&1)"
  grep -qe hunter2 -e tok3n <<<"$out" && fail "$name: the refusal prints the password" || pass "$name: password not printed"
done

echo "--- the OBS and Gitea APIs are reached through osc and git-obs"
case_ api-curl-obs-field         2 api-direct "curl to api.opensuse.org"
case_ api-curl-obs-schemeless    2 api-direct "curl to api.opensuse.org"
case_ api-curl-build-source      2 api-direct "curl to build.opensuse.org/source"
case_ api-wget-gitea             2 api-direct "wget to src.opensuse.org/api"
case_ api-var-url                2 api-direct "curl to src.opensuse.org/api"
case_ api-uppercase-host         2 api-direct "curl to api.opensuse.org"
case_ api-gitea-dot-segment      2 api-direct "curl to src.opensuse.org/api"
case_ api-httpie-gitea           2 api-direct "http to src.opensuse.org/api"
# Downloads, public git over https, other forges and registries, OBS web pages.
case_ api-download               0 - ""
case_ api-src-raw                0 - ""
case_ api-github                 0 - ""
case_ api-pypi                   0 - ""
case_ api-crates                 0 - ""
case_ api-build-web-page         0 - ""
case_ api-osc-api                2 retired-osc "an osc command"
case_ api-print-link             0 - ""
case_ api-git-obs                0 - ""
# Gitea file reads have no typed geectl leaf, so they stand: the six git-obs api
# calls the review machinery reads files through (see pr-guard.py).
case_ gitobs-api-raw-maintainership 0 - ""
case_ gitobs-api-raw-spec          0 - ""
case_ gitobs-api-trees             0 - ""
case_ gitobs-api-blob              0 - ""
case_ gitobs-api-comments          0 - ""
case_ gitobs-api-pulls             0 - ""

echo "--- the credential rules judge the agent's own commands, not the programs they run"
# A script's body, and program code inline or fed on stdin, are not scanned
# for them: the harness's Read denies and its snippets cover the rest.
case_ cred-script                0 - ""
case_ api-script                 0 - ""
case_ cred-yaml-heredoc          0 - ""
case_ api-python-urllib-obs      0 - ""

echo "--- the prefilter sends them without a path: a keyword, or a cwd among the credentials"
case_ prefilter-netrc-cwd        2 credential-read "cat reads ~/.netrc"
case_ prefilter-cred-dir-cwd     2 credential-read "cat reads ~/.config/gh/hosts.yml"
case_ prefilter-askpass-no-slash 2 askpass "SSH_ASKPASS"
# ... a variable, .., or a cwd above the credential files: no / needed to reach them.
case_ prefilter-home-var-sibling 2 credential-read "grep reaches the credential files under ~"
case_ prefilter-parent-dir       2 credential-read "tar reaches the credential files under ~"
case_ prefilter-recursive-no-path 2 credential-read "grep reaches the credential files under ~"
case_ prefilter-home-symlink    2 credential-read "grep reaches the credential files under ~"
case_ prefilter-home-slashes    2 credential-read "grep reaches the credential files under ~"
# In $'...' a \' closes nothing: read as a closing quote, the rest of the line
# became a comment, a quoted continuation or a heredoc.
case_ ansi-c-desync-comment     2 credential-read "cat reads ~/.config/tea/config.yml"
case_ ansi-c-desync-bsnl        2 credential-read "cat reads ~/.config/tea/config.yml"
case_ ansi-c-desync-heredoc     2 credential-read "cat reads ~/.config/tea/config.yml"
case_ ansi-c-desync-dollar-bsnl 2 credential-read "cat reads ~/.config/tea/config.yml"
case_ ansi-c-desync-pid        2 credential-read "cat reads ~/.config/tea/config.yml"
# An escaped space, or the ) of a $(...), is part of a word: a # after it starts
# no comment. After a group's ) it does, and a quote in that comment quotes nothing.
case_ comment-escaped-space     2 credential-read "cat reads ~/.config/tea/config.yml"
case_ comment-after-substitution 2 merge-tea    "not even their own"
case_ comment-after-substitution-bsnl 2 credential-read "cat reads ~/.config/tea/config.yml"
case_ comment-after-group-quote 2 merge-tea     "not even their own"
case_ comment-in-quoted-substitution 2 credential-read "cat reads ~/.config/tea/config.yml"
# Nesting as bash reads it: a backtick ends at the next one, ${...} at its },
# a # in either is no comment, nor a << after a # a heredoc.
case_ comment-case-in-backticks 2 credential-read "cat reads ~/.config/tea/config.yml"
case_ comment-backticks-in-quotes 2 credential-read "cat reads ~/.config/tea/config.yml"
case_ comment-param-quote       2 credential-read "cat reads ~/.config/tea/config.yml"
case_ comment-param-single-quote 2 credential-read "cat reads ~/.config/tea/config.yml"
case_ comment-param-double-quote 2 credential-read "cat reads ~/.config/tea/config.yml"
case_ comment-in-param          2 credential-read "cat reads ~/.config/tea/config.yml"
case_ heredoc-in-comment        2 credential-read "cat reads ~/.config/tea/config.yml"
# A case pattern's ) would end a (...) it sits in: refused there, read elsewhere.
case_ case-in-quoted-substitution 2 undecided   "a case inside (...) or \$(...) is not read"
case_ case-top-level            0 - ""
case_ case-word-in-substitution 0 - ""
case_ heredoc-escaped           2 merge-tea     "not even their own"
# A quoted case or esac is a command, not the keyword: the rules would read the
# lines after it as patterns. Refused where a command's name stands.
case_ case-quoted-dq            2 undecided     "a quoted case runs as a command"
case_ case-quoted-backslash     2 undecided     "a quoted case runs as a command"
case_ case-quoted-ansi          2 undecided     "a quoted case runs as a command"
case_ case-quoted-after-keyword 2 undecided     "a quoted case runs as a command"
case_ case-quoted-after-pattern 2 undecided     "a quoted case runs as a command"
case_ case-quoted-after-fd      2 undecided     "a quoted case runs as a command"
case_ case-quoted-after-dup     2 undecided     "a quoted case runs as a command"
case_ case-quoted-after-clobber 2 undecided     "a quoted case runs as a command"
case_ case-quoted-after-procsub 2 undecided     "a quoted case runs as a command"
case_ case-quoted-in-group      2 undecided     "a quoted case runs as a command"
case_ case-quoted-in-glued-group 2 undecided   "a quoted case runs as a command"
case_ case-quoted-argument      0 - ""
case_ prefilter-dot-in-home      2 credential-read "tar reaches the credential files under ~"
case_ prefilter-bare-cd          2 credential-read "tar reaches the credential files under ~"

echo "--- a backslash-newline joins the word around it, as bash reads it"
case_ bsnl-cred-read     2 credential-read "cat reads ~/.config/tea/config.yml"
case_ bsnl-push-pool     2 push-pool "pool/"
case_ bsnl-comment-ends  2 credential-read "cat reads ~/.config/tea/config.yml"
case_ bsnl-single-quoted 0 - ""

echo "--- the prefilter skips only calls the rules let through, over every event"
skipped="$(python3 - "$GUARD" "$FX/events.json" CLONE="$work/clone" TRACK="$work/track" \
    OTHER="$work/other" BROKEN="$work/broken" MANY="$work/many" ODD="$work/odd" \
    GITHUB="$work/github" STRANGER="$work/stranger" MAPPED="$work/mapped" \
    REFSPEC="$work/refspec" ONPR="$work/onpr" PDEF="$work/pdef" PLAIN="$work/plain" \
    WORK="$W" SKILL="$S" BARE="$work/barerepo" TOKENED="$work/tokened" OSC="$work/osc" \
    DEVEL="$work/devel" MSGS="$FX/messages" HOME="$HOME" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
judge = g.rules()["judge"]
subs = [kv.split("=", 1) for kv in sys.argv[3:]]
bad, n = [], 0
for name, ev in json.load(open(sys.argv[2])).items():
    text = json.dumps(ev)
    for k, v in subs:
        text = text.replace("@%s@" % k, v)
    ev = json.loads(text)
    if g.skip(ev, g.text_of(ev)):
        n += 1
        if judge(ev):
            bad.append(name)
print(n, " ".join(bad))
PY
)"
[ -n "$skipped" ] && [ "${skipped#* }" = "" ] && pass "no skipped event is one the rules refuse (${skipped%% *} skipped)" \
  || fail "the prefilter skips events the rules refuse: ${skipped#* }"

echo "--- plumbing: fail closed only after a match"
case_ nothing-guarded     0 - ""
case_ nul-in-remote       2 undecided "embedded null byte"
# $'...' decodes as bash does, and a character it cannot hold is refused.
case_ ansi-c-bare-escapes 0 - ""
case_ ansi-c-no-character 2 undecided "names no character"
out="$(printf '{"tool_name": "Bash", "tool_input": {"command": "tea pr merge' | python3 "$GUARD" 2>&1)"; got=$?
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided]" <<<"$out" && pass "malformed event after a match (rc=2)" \
  || fail "malformed event after a match: rc=$got $out"
out="$(printf '{"tool_name": "Bash", "tool_input": {"command": "ls' | python3 "$GUARD" 2>&1)"; got=$?
[ "$got" = 0 ] && [ -z "$out" ] && pass "malformed event, nothing guarded (allowed)" \
  || fail "malformed event, nothing guarded: rc=$got $out"
# Exit 1 is a non-blocking error to Claude Code: nothing the guard meets may end in one.
# 200000 deep, as Python 3.14+ checks the C stack and parses 20000.
out="$(python3 -c 'import sys; d = 200000; sys.stdout.write("{\"tool_name\": \"Bash\", \"tool_input\": {\"z\": " + "[" * d + "]" * d + "}}")' \
  | python3 "$GUARD" 2>&1)"; got=$?
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided]" <<<"$out" && grep -qF RecursionError <<<"$out" \
  && pass "an event nested past the parser's depth refuses (rc=2)" || fail "deep nesting: rc=$got $out"
out="$(ev merge-gitoxide | sed 's/"}/ \xff"}/' | python3 "$GUARD" 2>&1)"; got=$?
[ "$got" = 2 ] && grep -qF "BLOCKED [merge-" <<<"$out" && pass "bytes that are not UTF-8 are judged, not a crash (rc=2)" \
  || fail "non-UTF-8 input: rc=$got $out"
# A call the guard has not decided by its deadline is refused, before Claude Code's
# hook timeout would run it unjudged.
mkdir -p "$work/late/prs" && sed 's/^DEADLINE = .*/DEADLINE = 1/' "$GUARD" > "$work/late/pr-guard.py"
{ cat "${GUARD%/*}/_pr_guard.py"; printf '\nNET_BUDGET = 30\n'; } > "$work/late/_pr_guard.py"
mkfifo "$work/late/prs/tesseract-ocr.json"
t0=$(date +%s)
out="$(ev push-wip | PR_GUARD_PULLS_DIR="$work/late/prs" timeout 30 python3 "$work/late/pr-guard.py" 2>&1)"; got=$?
took=$(( $(date +%s) - t0 ))
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided] no verdict within 1 s" <<<"$out" && [ "$took" -lt 10 ] \
  && pass "a call past the guard's deadline refuses (rc=2, ${took}s)" || fail "past the deadline: rc=$got after ${took}s $out"
# Also where the rules take an OSError for a failed lookup: a git that hangs.
mkdir -p "$work/late/bin" && printf '#!/bin/sh\nexec sleep 30\n' > "$work/late/bin/git" && chmod +x "$work/late/bin/git"
t0=$(date +%s)
out="$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1], "tool_input": {"command": "git pu" + "sh origin HEAD:refs/heads/x"}}))' "$work/plain" \
  | PATH="$work/late/bin:$PATH" timeout 60 python3 "$work/late/pr-guard.py" 2>&1)"; got=$?
took=$(( $(date +%s) - t0 ))
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided] no verdict within 1 s" <<<"$out" && [ "$took" -lt 10 ] \
  && pass "a deadline inside an OSError handler still refuses (rc=2, ${took}s)" || fail "deadline in a hung git: rc=$got after ${took}s $out"
deadline=$(sed -n 's/^DEADLINE = \([0-9]*\).*/\1/p' "$GUARD")
[ -n "$deadline" ] && [ $((deadline + 5)) -le "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["timeout"])' "$REPO/contrib/harness/claude/pr-guard-hook.json")" ] \
  && pass "the deadline (${deadline} s) refuses before the hook's timeout" || fail "deadline ${deadline:-unset} s against the hook timeout"
# Long input stays linear: 100 kB of = (the API-host pattern once rescanned from each).
t0=$(date +%s)
out="$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1], "tool_input": {"command": "curl https://example.org -d " + "=a" * 50000 + "; cat " + "~/.ne" + "trc"}}))' "$work/plain" \
  | python3 "$GUARD" 2>&1)"; got=$?
took=$(( $(date +%s) - t0 ))
[ "$got" = 2 ] && grep -qF "BLOCKED [credential-read]" <<<"$out" && [ "$took" -lt 10 ] \
  && pass "100 kB of = is judged in ${took}s (rc=2)" || fail "100 kB of =: rc=$got after ${took}s"
# The rules load only once a call matched; without them it fails closed.
mkdir -p "$work/bare" && cp "$GUARD" "$work/bare/"
out="$(ev nothing-guarded | python3 "$work/bare/pr-guard.py" 2>&1)"; got=$?
[ "$got" = 0 ] && [ -z "$out" ] && pass "unmatched call needs no rules (allowed)" \
  || fail "unmatched call without _pr_guard.py: rc=$got $out"
out="$(ev merge-gitoxide | python3 "$work/bare/pr-guard.py" 2>&1)"; got=$?
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided]" <<<"$out" && grep -qF "_pr_guard.py" <<<"$out" \
  && pass "matched call without _pr_guard.py (rc=2)" || fail "matched call without _pr_guard.py: rc=$got $out"
# A failure's own text is redacted too.
mkdir -p "$work/raises" && cp "$GUARD" "$work/raises/"
{ cat "${GUARD%/*}/_pr_guard.py"; printf '\n\ndef judge(ev):\n    raise ValueError("https://user:tok3n@example.com")\n'; } > "$work/raises/_pr_guard.py"
out="$(ev merge-gitoxide | python3 "$work/raises/pr-guard.py" 2>&1)"; got=$?
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided]" <<<"$out" && grep -qF "user:[REDACTED]@" <<<"$out" && ! grep -qF tok3n <<<"$out" \
  && pass "a failure's text is redacted (rc=2)" || fail "a failure's text is not redacted: rc=$got $out"
# ... and a redaction that fails still refuses, without the text it could not redact.
printf '\n\ndef redact(text):\n    raise RuntimeError("no redaction")\n' >> "$work/raises/_pr_guard.py"
out="$(ev merge-gitoxide | python3 "$work/raises/pr-guard.py" 2>&1)"; got=$?
[ "$got" = 2 ] && grep -qF "BLOCKED [undecided]" <<<"$out" && ! grep -qF tok3n <<<"$out" \
  && pass "a failed redaction still refuses (rc=2)" || fail "a failed redaction: rc=$got $out"
# The open-PR lookups of one call share a budget below the hook's timeout, past which
# Claude Code would run the call unjudged: a lookup still sleeping when it runs out refuses.
mkdir -p "$work/slow/prs" && cp "$GUARD" "$work/slow/"
{ cat "${GUARD%/*}/_pr_guard.py"; printf '\nNET_BUDGET = 1\n'; } > "$work/slow/_pr_guard.py"
mkfifo "$work/slow/prs/tesseract-ocr.json"  # no writer: opening it sleeps for good
t0=$(date +%s)
out="$(ev push-wip | PR_GUARD_PULLS_DIR="$work/slow/prs" timeout 30 python3 "$work/slow/pr-guard.py" 2>&1)"; got=$?
took=$(( $(date +%s) - t0 ))
[ "$got" = 2 ] && grep -qF "BLOCKED [push-unknown]" <<<"$out" && grep -qF "ran past 1 s" <<<"$out" && [ "$took" -lt 10 ] \
  && pass "a lookup still sleeping when the call's budget runs out refuses (rc=2, ${took}s)" \
  || fail "a lookup past the budget: rc=$got after ${took}s $out"
budget=$(sed -n 's/^NET_BUDGET = \([0-9]*\).*/\1/p' "${GUARD%/*}/_pr_guard.py")
hook=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["timeout"])' \
  "$REPO/contrib/harness/claude/pr-guard-hook.json")
[ -n "$budget" ] && [ $((budget + 15)) -le "$hook" ] && pass "the lookup budget (${budget} s) leaves room below the hook's ${hook} s" \
  || fail "lookup budget ${budget:-unset} s against the hook's ${hook} s timeout"
out="$(python3 "$GUARD" --help)"; got=$?
[ "$got" = 0 ] && grep -q '^Exit: 0 = allowed' <<<"$out" && pass "--help (rc=0)" || fail "--help: rc=$got"
python3 "$GUARD" --bogus </dev/null >/dev/null 2>&1; got=$?
[ "$got" = 2 ] && pass "unknown argument (rc=2)" || fail "unknown argument: rc=$got"

echo "--- the skill's own tools, and every suite, run unrefused and unasked"
asks_ok() {   # asks_ok <file>: the rules its ask may name, where the ask is intended
  case $1 in
    # a mutation case runs its mutant through eval, which the guard cannot read
    test-autoforward-gate.sh|test-check-flags.sh|test-check-geectl.sh|test-check-osc.sh|test-forward-check.sh) echo eval-dynamic ;;
    test-incoming-requests.sh|test-preflight.sh|test-sr-status.sh) echo eval-dynamic ;;
    # each case is a command line run through eval
    test-cone-status.sh) echo eval-dynamic ;;
    # each case is a command line run through eval, target-gate.sh --review among them
    test-target-gate.sh) echo eval-dynamic review-self ;;
  esac
}
for f in "$REPO"/skills/opensuse-packaging/scripts/*.sh "$REPO"/skills/opensuse-packaging/scripts/*.py "$HERE"/test-*.sh; do
  # The scripts that write stamps run only as merged, unread: read, they are refused.
  case ${f##*/} in _*|pool-pr.sh|leap-sync.sh|target-gate.sh|gate.sh|incoming-review.sh) continue;; esac
  case $f in *.py) run=python3;; *) run=bash;; esac
  out="$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[2],
    "tool_input": {"command": sys.argv[1]}}))' "$run $f --help" "$work/plain" | python3 "$GUARD" 2>&1)"; got=$?
  asked=$(grep -oE 'ASK \[[a-z-]+\]' <<<"$out" | sed 's/^ASK \[//; s/\]$//' | sort -u | tr '\n' ' '); asked=${asked% }
  allowed=$(asks_ok "${f##*/}"); bad=""; gone=""
  for r in $asked; do case " $allowed " in *" $r "*) ;; *) bad+=" $r";; esac; done
  for r in $allowed; do case " $asked " in *" $r "*) ;; *) gone+=" $r";; esac; done
  if [ "$got" != 0 ]; then fail "${f##*/} is refused: $out"
  elif [ -n "$bad" ]; then fail "${f##*/} asks (${bad# }): $out"
  elif [ -z "$asked" ] && grep -qE '"permissionDecision": *"ask"' <<<"$out"; then fail "${f##*/} asks, no rule named: $out"
  elif [ -n "$gone" ]; then fail "${f##*/} no longer asks${gone}: drop it from asks_ok"
  else pass "runs unrefused${asked:+, asking only $asked}: ${f##*/}"; fi
done

echo "--- the opencode plugins carry the same prefilter"
py="$(python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(mod.PREFILTER.pattern); print(mod.STAMP_DIR); print(mod.CRED_DIR.pattern)
print(",".join(mod.CRED_HOMES)); print(mod.STATE_DIR.pattern)' "$GUARD")"
{ IFS= read -r py_pre; IFS= read -r py_stamp; IFS= read -r py_cred; IFS= read -r py_homes; IFS= read -r py_state; } <<<"$py"
for PLUGIN in "$V1PLUGIN" "$V2PLUGIN"; do
  v=${PLUGIN%/pool-pr-guard.ts}; v=${v##*/}
  # shellcheck disable=SC2016  # the backticks are the pattern's, not the shell's
  ts="$(sed -n 's/^const PREFILTER = new RegExp(String\.raw`\(.*\)`)$/\1/p' "$PLUGIN")"
  [ -n "$ts" ] && [ "$py_pre" = "$ts" ] && pass "$v: prefilter identical in the plugin" \
    || fail "$v: prefilter differs: guard '$py_pre' plugin '$ts'"
  grep -qF 'PREFILTER.test(unquoted(text))' "$PLUGIN" && pass "$v: plugin also reads the text unquoted" \
    || fail "$v: the plugin does not apply the prefilter to the unquoted text"
  ts="$(sed -n 's/^const STAMP_DIR = "\(.*\)"$/\1/p' "$PLUGIN")"
  [ -n "$ts" ] && [ "$py_stamp" = "$ts" ] && grep -qF 'includes(STAMP_DIR)' "$PLUGIN" \
    && pass "$v: plugin also judges a call run inside the stamp directory" \
    || fail "$v: the plugin does not send a call run inside '$py_stamp' to the guard"
  # shellcheck disable=SC2016  # the backticks are the pattern's, not the shell's
  ts="$(sed -n 's/^const CRED_DIR = new RegExp(String\.raw`\(.*\)`)$/\1/p' "$PLUGIN")"
  [ -n "$ts" ] && [ "$py_cred" = "$ts" ] && grep -qF 'CRED_DIR.test(' "$PLUGIN" \
    && pass "$v: plugin also judges a call run among the credential files" \
    || fail "$v: the plugin's CRED_DIR differs or is unused: guard '$py_cred' plugin '$ts'"
  ts="$(sed -n 's/^const CRED_HOMES = \[\(.*\)\]$/\1/p' "$PLUGIN" | tr -d ' "')"
  [ -n "$ts" ] && [ "$py_homes" = "$ts" ] && grep -qF 'above(' "$PLUGIN" \
    && pass "$v: plugin also judges a call run above the credential files" \
    || fail "$v: the plugin's CRED_HOMES differs or is unused: guard '$py_homes' plugin '$ts'"
  # shellcheck disable=SC2016  # the backticks are the pattern's, not the shell's
  ts="$(sed -n 's/^const STATE_DIR = new RegExp(String\.raw`\(.*\)`)$/\1/p' "$PLUGIN")"
  [ -n "$ts" ] && [ "$py_state" = "$ts" ] && grep -qF 'STATE_DIR.test(' "$PLUGIN" \
    && pass "$v: plugin also judges a call run inside the state directory" \
    || fail "$v: the plugin's STATE_DIR differs or is unused: guard '$py_state' plugin '$ts'"
done
# Each plugin is wired to its own plugin API: 1.x never runs a 2.x file nor the reverse.
grep -qF '"tool.execute.before"' "$V1PLUGIN" && ! grep -qF 'ctx.tool.hook' "$V1PLUGIN" \
  && pass "opencode: the 1.x plugin hooks tool.execute.before" \
  || fail "opencode: the 1.x plugin is not wired to tool.execute.before"
grep -qF 'ctx.tool.hook("execute.before", async (event) => {' "$V2PLUGIN" && ! grep -qF '"tool.execute.before"' "$V2PLUGIN" \
  && grep -qF 'export default' "$V2PLUGIN" && ! grep -qF 'Plugin.define' "$V2PLUGIN" \
  && pass "opencode-v2: the 2.x plugin registers execute.before from a default export" \
  || fail "opencode-v2: the 2.x plugin is not wired to ctx.tool.hook execute.before"
# Any of these changed lets a guarded call through: the tool ids, their 2.x fields, the
# refusal of an input the plugin cannot read, the absolute path, the throw.
# shellcheck disable=SC2016  # the backticks are TypeScript's, not the shell's
grep -qF 'if (tool !== "shell" && tool !== "write" && tool !== "edit") return' "$V2PLUGIN" \
  && grep -qF 'const command = args.command' "$V2PLUGIN" && grep -qF 'const path = args.path' "$V2PLUGIN" \
  && grep -qF 'const body = tool === "write" ? args.content : args.newString' "$V2PLUGIN" \
  && grep -qF 'throw new Error(`pool-pr-guard: ${tool} call without input`)' "$V2PLUGIN" \
  && grep -qF 'const file_path = resolve(dir, home(path))' "$V2PLUGIN" \
  && grep -qF 'if (why !== undefined) throw new Error(why)' "$V2PLUGIN" \
  && grep -qxF 'import type { Plugin } from "@opencode/plugin"' "$V2PLUGIN" \
  && pass "opencode-v2: the plugin judges shell, write and edit by their 2.x fields and throws to refuse" \
  || fail "opencode-v2: the plugin's tool ids, input fields or refusal changed"
# Neither plugin hands the guard's ask to opencode's prompt: an agent can answer that
# through the opencode server (service.json), so the ask reaches the model as a refusal
# and the go stays in a Claude Code session.
grep -qF 'done(code === 0 ? asked(out) :' "$V2PLUGIN" && grep -qF 'd?.permissionDecision !== "ask"' "$V2PLUGIN" \
  && grep -qF 'if (d?.permissionDecision === "ask")' "$V1PLUGIN" \
  && pass "opencode: both plugins refuse a call the guard asks about" \
  || fail "opencode: a plugin lets the guard's ask through"
! grep -qE 'permission\.(assert|hook)' "$V2PLUGIN" "$V1PLUGIN" \
  && grep -qF 'waits for the user in a Claude Code session' "$V2PLUGIN" \
  && grep -qF 'waits for the user in a Claude Code session' "$V1PLUGIN" \
  && pass "opencode: no plugin raises opencode's own prompt, and the refusal sends the go to a Claude Code session" \
  || fail "opencode: a plugin raises opencode's prompt, or its refusal does not name where the go is given"
# As pr-guard.py, the 2.x plugin judges every call of the incoming-review agent.
grep -qF 'const READER = "incoming-review"' "$V2PLUGIN" && grep -qF '&& event.agent !== READER) return' "$V2PLUGIN" \
  && pass "opencode-v2: the plugin judges every call of the incoming-review agent" \
  || fail "opencode-v2: the plugin skips incoming-review calls the prefilter misses"
grep -qF 'setTimeout(() => child.kill("SIGKILL"), 60_000)' "$V2PLUGIN" \
  && pass "opencode-v2: the guard is killed at 60 s, and a kill refuses" || fail "opencode-v2: the 60 s kill changed"
# The 2.x plugin run, where bun or a node that strips types is at hand, with a fake ctx as
# the 2.x promise adapter drives it: guarded calls refused, ls and an AI push run.
tsrun=""
if command -v bun >/dev/null; then tsrun=$(command -v bun)
elif node --experimental-strip-types -e '' 2>/dev/null; then tsrun="$(command -v node) --experimental-strip-types --no-warnings"; fi
if [ -z "$tsrun" ]; then echo "SKIP: opencode-v2 plugin run (no bun, no node that strips types)"; else
  mkdir -p "$HOME/.claude/hooks" && cp "$GUARD" "${GUARD%/*}/_pr_guard.py" "$HOME/.claude/hooks/"
  cp "$V2PLUGIN" "$work/v2.mts"
  for d in pool AI; do
    git init -q -b main "$work/v2-$d" && git -C "$work/v2-$d" remote add origin "gitea@src.opensuse.org:$d/x.git"
  done
  cat >"$work/drive.mjs" <<'JS'
const [plugin, loc, pool] = process.argv.slice(-3)
let fire
await (await import(plugin)).default.setup({ location: { directory: loc }, tool: { hook: async (_n, f) => { fire = f } } })
const run = async (e) => { try { await Promise.resolve(fire(e)); return "run" } catch { return "refused" } }
const merge = ["tea", "pulls", "mer" + "ge", "1"].join(" ")
const push = "git " + "pu" + "sh origin HEAD:refs/heads/x"
const review = process.env.V2_GATE + " . --review /var/tmp/x-review/verdict.txt"
console.log([
  await run({ tool: "shell", input: { command: merge } }),
  await run({ tool: "shell", input: { command: "ls" } }),
  await run({ tool: "write", input: { path: ".git/target-" + "gate/t-b.json", content: "{}" } }),
  await run({ tool: "write", input: { path: process.env.V2_STATE + "/incoming/x.json", content: "{}" } }),
  await run({ tool: "shell", input: { command: push, workdir: pool } }),
  await run({ tool: "shell", input: { command: push } }),
  await run({ tool: "shell", input: "x" }),
  await run({ tool: "shell", input: { command: ["osc", "comment", "create", "-c", "ok", "request", "1"].join(" ") } }),
  await run({ tool: "shell", agent: "changes-review", input: { command: review } }),
  await run({ tool: "shell", agent: "build", input: { command: review } }),
].join(" "))
JS
  # shellcheck disable=SC2086  # tsrun is a command line
  v2state="$HOME/$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["state_dir"])' "$FX/stamped.json")"
  out="$(V2_GATE="$W/gate.sh" V2_STATE="$v2state" $tsrun "$work/drive.mjs" "$work/v2.mts" "$work/v2-AI" "$work/v2-pool" 2>&1)"
  [ "$out" = "refused run refused refused refused run refused refused run refused" ] \
    && pass "opencode-v2: the plugin refuses a merge, stamp writes, a pool push, unreadable input and an ask, and hands the guard the agent" \
    || fail "opencode-v2: the plugin run gave '$out'"
  # shellcheck disable=SC2086  # tsrun is a command line
  out="$(PATH=/nonexistent $tsrun "$work/drive.mjs" "$work/v2.mts" "$work/v2-AI" "$work/v2-pool" 2>&1 | head -1)"
  [ "${out%% *}" = refused ] && pass "opencode-v2: the plugin refuses a guarded call when python3 is missing" \
    || fail "opencode-v2: with no python3 the plugin gave '$out'"
  # With opencode's permission service at hand (2.2.7), the guard's ask is still refused,
  # the service is never asked and no hook is set on it; the incoming-review agent's bare
  # rpmspec reaches the guard.
  cat >"$work/drive-ask.mjs" <<'JS'
const [plugin, loc, answer] = process.argv.slice(-3)
let fire, evaluate
const prompts = []
const permission = {
  hook: async (_n, f) => { evaluate = f },
  assert: async (req) => {
    const ev = { action: req.action, resources: req.resources, effect: "allow", metadata: req.metadata }
    await evaluate(ev)
    prompts.push(ev.effect === "ask" ? ev.message : "-")
    if (ev.effect === "ask" && answer !== "once") throw new Error("Permission.DeclinedError")
  },
}
await (await import(plugin)).default.setup({ location: { directory: loc }, permission,
  tool: { hook: async (_n, f) => { fire = f } } })
const call = { sessionID: "ses_1", messageID: "msg_1", id: "call_1" }
const run = async (e) => { try { await Promise.resolve(fire({ ...call, ...e })); return "run" } catch { return "refused" } }
const comment = ["osc", "comment", "create", "-c", "ok", "request", "1"].join(" ")
console.log([
  await run({ tool: "shell", input: { command: comment } }),
  await run({ tool: "shell", agent: "incoming-review", input: { command: "rpmspec -P x.spec" } }),
  await run({ tool: "shell", input: { command: "ls" } }),
  evaluate ? "hooked" : "unhooked",
  prompts.length,
].join(" "))
JS
  # shellcheck disable=SC2086  # tsrun is a command line
  out="$($tsrun "$work/drive-ask.mjs" "$work/v2.mts" "$work/v2-AI" once 2>&1)"
  [ "$out" = "refused refused run unhooked 0" ] \
    && pass "opencode-v2: with opencode's prompt at hand the guard's ask is still refused, the prompt never raised" \
    || fail "opencode-v2: with a permission service the plugin gave '$out'"
fi
# git runs "git obs" as git-obs: every git-obs pattern of the backstop has its twin.
miss="$(sed -n 's/^ *"\(git-obs [^"]*\)": "\([a-z]*\)",\{0,1\}$/\1\t\2/p' "$PERMS" | while IFS=$'\t' read -r pat act; do
  grep -qF "\"git obs ${pat#git-obs }\": \"$act\"" "$PERMS" || printf '%s ' "$pat"; done)"
grep -q '"git-obs ' "$PERMS" && [ -z "$miss" ] && pass "backstop spells git obs both ways" \
  || fail "backstop lacks the git obs form of: ${miss:-its git-obs patterns}"

# Every fixture is exercised, so none rots unread.
for name in $(python3 -c 'import json, sys; print(" ".join(json.load(open(sys.argv[1]))))' "$FX/events.json"); do
  case $used in *" $name "*) ;; *) fail "events.json: $name is never used";; esac
done

[ $fails -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
