#!/bin/bash
# The commit/SR gate chain as ONE tool call: the SR target, the tracked files
# (osc checkouts), no copy of a skill script, source_validator, factory-auto's
# URL check (download_files), the spec as rpm parses it (rpmspec -P), %prep
# (rpmbuild -bp, without --build-log), spec-cleaner, changes-lint.sh,
# changes-guard.sh, changes-patches.sh, a one-Legal-Review-Notice-per-License
# check, the spec header, terse spec comments, the patch tags, a new .changes
# entry for a changed tree and the sources' prebuilt binaries
# (source-binaries.py), each run unpiped with its exit code read directly, then
# one VERDICT line. Five separate calls cost five provider steps and five result
# blocks that ride along in context for the rest of the session; this costs one.
# The adversarial change review (agents/changes-review.md) still follows — it is
# a judgement, not a check, and stays outside this script.
# changes-range.py runs as a note that is never red: the upstream releases the
# bump crosses that the new .changes entries never name, or describe again.
#
# Usage: gate.sh [DIR] [--entries N] [--amend-top AUTHOR] [--squash-mine AUTHOR] [--target PRJ[/PKG]]
#                [--git-base REF] [--build-log FILE] [--rpms DIR] [--cleaner-deviation REASON]
#                [--no-entry REASON] [--full]
#        gate.sh [DIR] --review FILE
#        gate.sh [DIR] --obs-build [--rpms DIR] [--repos REGEX] [--arches REGEX]
#   DIR          package checkout (default .)
#   --entries N  entries the submission adds vs the target (changes-lint and
#                changes-patches, default 1)
#   changes-lint also checks those entries' author against what a bare
#   `osc vc` writes (vc-identity.sh); with no identity from osc vc it is red.
#   --amend-top  the .changes top entry is yours and still unaccepted (changes-guard)
#   --squash-mine  the new top entry folds the run of your own unaccepted entries
#                under it into one, when the user asks for it (changes-guard)
#   --target     the SR target (default: Factory's devel project, devel-of.sh; for a
#                link into another openSUSE:/SUSE: project, that maintenance
#                project; for a package Factory lacks, the link origin, else the
#                checkout's own project). An osc checkout whose link origin (its
#                own project when it is no link) is not the target is red: its
#                .changes history is not the target's (sr#1392134). A forward to
#                openSUSE:Factory from Factory's devel project is fine.
#                changes-guard then compares against the target's .changes and
#                changes-patches against the target
#   --git-base   git checkout: the target's ref for changes-patches and patch-tags
#                (a fork PR's upstream is the pushed fork branch, which compares clean)
#   --build-log  also run build-summary.sh on this osc build log, in any form
#                build-summary.sh takes (verdict only). Red unless it is a build
#                of this tree: a spec of the checkout, its source RPM of the
#                spec's name and version, started after the last change to any
#                file but a .changes (with no spec: its recipe is the
#                checkout's); a _multibuild package passes it once per build,
#                the base package and each flavor. GREEN records them as the
#                tree's build. Without it (and without --obs-build) %prep runs
#                here: rpmbuild -bp --nodeps in a bwrap sandbox (no network,
#                only /usr and /etc of the host, $HOME empty, the checkout
#                read-only, only a scratch dir under /var/tmp writable), a pass
#                cached per spec and sources; red when it fails or passes 900 s,
#                UNKNOWN but not red when no sandbox starts, /var/tmp lacks the
#                room, or %prep stops on what a BuildRequires missing here
#                would bring
#   --rpms DIR   the built RPMs (osc getbinaries -d DIR): source-binaries.py then
#                also refuses a prebuilt binary the package ships, whatever its
#                exception line says (firmware alone may ship); without it the
#                gate notes that the RPMs went unchecked. A static library's code
#                a shipped file carries is an EMBEDS? line for the review
#   --cleaner-deviation  the spec-cleaner diff left is a documented deviation
#                (references/spec-cleaner.md "Checking a spec file"): name it.
#                The gate passes, prints the reason and keeps the diff for the
#                change review, which judges every hunk of it
#   --no-entry   the change adds no .changes entry on purpose (the user said so,
#                or it is cosmetic, a comment-only cleanup): name why. The
#                changes-entry gate passes, and the verdict and the stamp carry
#                the reason for the change review; never with openSUSE:Factory as
#                the target (factory-auto declines "No changelog"), nor a failed
#                lookup
#   --full       print every gate's complete output (default: last 12 lines each;
#                full output is always saved under $TMPDIR/gate-<pkg>/)
#   --review FILE  record the change review instead of running the gates: FILE's
#                first non-empty line starts with PASS and names "tree <key12>",
#                the tree the last GREEN run printed; needs that GREEN run
#   --obs-build  record OBS's build of the committed tree instead (gate 1 in
#                OBS-ONLY mode): OBS's expanded files are the stamped tree, every
#                repo/arch/flavor succeeded from them (each log's srcmd5), and
#                build-summary.sh reads each log GREEN; --rpms DIR also records
#                the shipped-binary check of OBS's RPMs. A red build drops the
#                tree's recorded build. Judged: the Tumbleweed and Leap 16 repos
#                (openSUSE_Factory*, openSUSE_Tumbleweed, an openSUSE:Factory
#                project's standard; 16.N and openSUSE_Leap_16.N unless the
#                stamp's target is openSUSE:Factory) on x86_64 and aarch64; any
#                other repo/arch is a note with its state, never red or pending.
#                A red (failed, unresolvable, broken) the link origin has at the
#                same repo/arch is PRE-EXISTING: listed, not red, and GREEN needs
#                one judged build that succeeded; a repo/arch the origin disables
#                is not judged (one it excludes is). The stamp records the repos
#                judged, the green ones --repos added, whether a Tumbleweed build
#                succeeded, and the PRE-EXISTING ones
#   --repos REGEX  with --obs-build: also judge the repos whose name matches
#                (re.search), when the user says another target matters
#   --arches REGEX  with --obs-build: also judge the arches that match
# Parsing a spec runs its %(...) on this host as you, and %prep runs the
# package's code (sandboxed, which keeps it off the network and out of $HOME but
# is no reason to trust it): run the gate only on a checkout you are changing
# yourself, never on someone else's submission (references/untrusted-content.md
# "The two sharp local-execution vectors").
# Entry: a tree that differs from the target needs a .changes top entry the
# target lacks (factory-auto: "No changelog"), and one Factory lacks too when
# the target is Factory's devel project; --amend-top and --squash-mine take an
# entry Factory lacks, --no-entry REASON none.
# Stamp (osc checkouts): a GREEN run records the tree it judged, a sha256 over
# the md5 and name of every file osc would commit (no _link, no _service:*), in
# ~/.local/state/opensuse-packaging/gate/obs/<pkg>/<prj>.json; a red run deletes
# it. A rerun of the same tree keeps its review, build and --rpms check; a tree
# that differs only in *.changes keeps the build and the --rpms check, never
# the review. Nothing tracked (osc mkpac before osc add) is red and stamps
# nothing, and --review refuses it.
# Exit: 0 = every gate green (--review, --obs-build: recorded), 1 = at least one
#       red (VERDICT names them; --review: the verdict file is not a PASS of this
#       tree; --obs-build: a red build, OBS holds other files, or a lookup failed),
#       2 = usage, or DIR is not a package checkout (no *.spec, no .osc/_package),
#       3 = --review, --obs-build: no GREEN gate run of the current tree,
#       4 = --obs-build: still building, or built from older sources: wait
#       (obs-wait.py), then rerun.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
read -r -d '' PY <<'PYEOF'
import calendar
import difflib
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def listing(d, prj, pkg):
    # .osc/_files, else the API's expanded listing (an osc store without one)
    path = os.path.join(d, ".osc/_files")
    if os.path.exists(path):
        try:
            return ET.parse(path).getroot()
        except (OSError, ET.ParseError):
            return None
    p = subprocess.run(["osc", "api", "/source/%s/%s?expand=1" % (prj, pkg)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    try:
        return ET.fromstring(p.stdout)
    except ET.ParseError:
        return None


def link(d, prj, pkg):
    root = listing(d, prj, pkg)
    if root is None:
        return 2
    li = root.find("linkinfo")
    if li is not None and li.get("project"):
        print("%s/%s" % (li.get("project"), li.get("package") or pkg))
    return 0


def files(d):
    # the files `osc ci` would commit, with the working copy's md5
    path = os.path.join(d, ".osc/_files")
    try:
        names = {e.get("name") for e in ET.parse(path).getroot().findall("entry")}
    except (OSError, ET.ParseError):
        return None
    for extra, add in (("_to_be_added", True), ("_to_be_deleted", False)):
        try:
            with open(os.path.join(d, ".osc", extra), encoding="utf-8") as fh:
                for n in fh.read().split():
                    (names.add if add else names.discard)(n)
        except OSError:
            pass
    out = {}
    for n in sorted(x for x in names if x and x != "_link" and not x.startswith("_service:")):
        h = hashlib.md5()
        try:
            with open(os.path.join(d, n), "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
            out[n] = h.hexdigest()
        except OSError:
            out[n] = "-"
    return out


def key(fm):
    return hashlib.sha256("".join("%s  %s\n" % (m, n) for n, m in sorted(fm.items())).encode()).hexdigest()


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def save(path, d):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(d, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def present(fm):
    # a missing file ("-") has no content for the key to bind
    return {n: m for n, m in fm.items() if m != "-"}


def tracked(d):
    fm = files(d)
    if fm is None:
        print("note: no .osc/_files, no tree to stamp")
        return 0
    if not present(fm):
        print("nothing to stamp: no tracked files (osc add the package files first)")
        return 1
    print("OK: %d file(s) osc would commit" % len(present(fm)))
    return 0


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def changelog_only(old, new):
    # only *.changes differ: nothing that builds changed
    return (isinstance(old, dict) and set(old) == set(new)
            and all(old[n] == new[n] for n in old if not n.endswith(".changes")))


def build_note(st):
    b = st.get("build") if isinstance(st.get("build"), dict) else {}
    if b.get("carried"):
        return "build: carried from tree %s, only .changes changed since" % b["carried"]
    if b.get("kind") == "obs":
        return "build: OBS, sources %s" % (b.get("srcmd5") or "?")[:12]
    if b.get("kind") == "log":
        more = len(b.get("logs") or [1]) - 1
        return "build: %s%s" % (b.get("log"), " and %d more" % more if more > 0 else "")
    return ("build: none recorded for this tree; osc sr asks for one (--build-log LOG,"
            " or --obs-build once OBS built the commit)")


STARTED = re.compile(r'started "build ([^"]+)" at (.+?)\.?\s*$')
RECIPE = re.compile(r'(?:finished|failed) "build ([^"]+)"')
WROTE_SRPM = re.compile(r"Wrote: \S*/SRPMS/(\S+?)\.(?:no)?src\.rpm\b")


def log_facts(log):
    # (the spec it built, when it started, its source RPM's n-v-r)
    recipe, started, srpm = None, None, None
    with open(log, encoding="utf-8", errors="replace") as fh:
        for ln in fh:
            m = STARTED.search(ln)
            if m:
                recipe, started = m.group(1), m.group(2)
            m = RECIPE.search(ln)
            if m:
                recipe = m.group(1)
            m = srpm is None and WROTE_SRPM.search(ln)
            if m:
                srpm = m.group(1)
    when = None
    if started:
        try:
            when = calendar.timegm(time.strptime(" ".join(started.split()), "%a %b %d %H:%M:%S UTC %Y"))
        except ValueError:
            pass
    return recipe, when if when is not None else os.path.getmtime(log), srpm


def flavors(d):
    try:
        root = ET.parse(os.path.join(d, "_multibuild")).getroot()
    except FileNotFoundError:
        return []
    except (OSError, ET.ParseError):
        return None
    return [e.text.strip() for e in root.iter() if e.tag in ("package", "flavor") and (e.text or "").strip()]


def name_fits(n, names):
    # n starts with a spelling of Name up to what only a build knows (a macro
    # left unexpanded, the flavor); one that starts with that, any n fits
    return any(not p or n.startswith(p) for p in (re.split(r"%|@BUILD_FLAVOR@", x)[0] for x in names))


def buildlogs(d, *logs):
    # Whether GREEN logs are builds of this tree: a spec of it, the source RPM
    # of its name (any flavor's) and version, started after the newest file
    # but a .changes; one per build of a _multibuild, the base package unless
    # the spec excludes it. With no spec (kiwi, Dockerfile) there is no source
    # RPM: the recipe must be a file of the checkout.
    want, excluded = {}, False
    for spec in sorted(os.listdir(d)):
        if spec.endswith(".spec"):
            lines = read_lines(os.path.join(d, spec))
            vals = spec_values(lines)
            names = set().union(*(expansions(x, vals) for x in vals.get("name") or [""]))
            versions = set().union(*(expansions(x, vals) for x in vals.get("version") or [""]))
            want[spec] = (names, versions)
            excluded = excluded or base_excluded(lines, vals)
    fm = files(d)
    names = [n for n in fm if fm[n] != "-"] if fm is not None else list(want)
    stamps = [(os.path.getmtime(os.path.join(d, n)), n) for n in names
              if not n.endswith(".changes") and os.path.isfile(os.path.join(d, n))]
    newest = max(stamps, default=(0, ""))
    bad, seen, srpms = [], set(), set()
    for log in logs:
        recipe, start, srpm = log_facts(log)
        seen.add(sha256(log))
        if not want:
            if recipe and not os.path.isfile(os.path.join(d, recipe)):
                bad.append("%s built %s, which this checkout does not have" % (log, recipe))
                continue
        elif recipe and recipe not in want:
            bad.append("%s built %s, not this checkout's %s" % (log, recipe, ", ".join(want)))
            continue
        elif not srpm:
            bad.append("%s names no source RPM it wrote (Wrote: …/SRPMS/…src.rpm): not known to be a build of this tree" % log)
            continue
        else:
            parts = srpm.rsplit("-", 2)
            n, v = (parts[0], parts[1]) if len(parts) == 3 else (srpm, "")
            srpms.add(n)
            mine = [nv for spec, nv in want.items() if not recipe or spec == recipe]
            if not any(name_fits(n, ns) and any("%" in x or x == v for x in vs) for ns, vs in mine):
                said = "; ".join("%s %s" % ("|".join(sorted(ns)), "|".join(sorted(vs))) for ns, vs in mine)
                bad.append("%s built %s, the spec says %s" % (log, srpm, said))
        if newest[0] > start + 1:
            bad.append("%s changed after %s started: rebuild" % (newest[1], log))
    fl = flavors(d)
    if fl is None:
        bad.append("_multibuild: cannot read it")
    elif fl:
        need = ([] if excluded else ["the base package"]) + fl
        varies = any(len(ns) > 1 for ns, _ in want.values())
        got, what = (len(srpms), "distinct source RPM(s)") if varies else (len(seen), "distinct build log(s)")
        if got < len(need):
            bad.append("a _multibuild package: %d build(s) (%s), %d %s: pass --build-log once per build"
                       % (len(need), ", ".join(need), got, what))
    for b in bad:
        print("RED: " + b)
    if not bad:
        print("OK: %d log(s), each a build of this tree" % len(logs))
    return 1 if bad else 0


def stamp(path, d, prj, pkg, target, rpms="", *logs):
    fm = files(d)
    if fm is None or not present(fm):
        return 1
    st = {"project": prj, "package": pkg, "target": target, "tree": key(fm),
          "files": fm, "verdict": "GREEN", "time": now()}
    if os.environ.get("GATE_NO_ENTRY"):  # the change review sees why the change adds no entry
        st["no_entry"] = os.environ["GATE_NO_ENTRY"]
    old = load(path)
    if old and old.get("tree") == st["tree"]:
        # A rerun of the same tree keeps its review, build and RPM check.
        for k in ("review", "build", "rpms"):
            if old.get(k):
                st[k] = old[k]
    elif old and changelog_only(old.get("files"), fm):
        # A changelog builds nothing: its build and RPM check stand, never its review.
        for k in ("build", "rpms"):
            if isinstance(old.get(k), dict):
                st[k] = dict(old[k], carried=old.get("tree", "")[:12])
    if logs:
        st["build"] = {"verdict": "GREEN", "kind": "log", "log": logs[0], "logs": list(logs),
                       "sha256": [sha256(x) for x in logs], "time": now()}
    if rpms:
        st["rpms"] = {"dir": rpms, "time": now()}
    save(path, st)
    print(st["tree"])
    print(build_note(st))
    return 0


def review(path, d, fpath):
    fm = files(d)
    if fm is not None and not present(fm):
        st = load(path)
        # only a stamp of no content: another tree's may still match OBS's copy
        if st and isinstance(st.get("files"), dict) and not present(st["files"]):
            os.remove(path)
        print("VERDICT: NO GATE — nothing to review: no tracked files (osc add the package files first)")
        return 3
    t = key(fm) if fm is not None else ""
    st = load(path)
    if not st or st.get("verdict") != "GREEN" or not t or st.get("tree") != t:
        print("VERDICT: NO GATE — no GREEN gate run of tree %s: run gate.sh, then --review" % (t[:12] or "?"))
        return 3
    try:
        with open(fpath, "rb") as fh:
            raw = fh.read()
    except OSError as e:
        print("VERDICT: REFUSED — cannot read %s: %s" % (fpath, e.strerror))
        return 2
    lines = [ln.strip() for ln in raw.decode("utf-8", "replace").splitlines() if ln.strip()]
    first = lines[0] if lines else ""
    # Only the verdict line binds: a body may quote the target's or an older tree.
    trees = re.findall(r"\btree ([0-9a-f]{12,})\b", first)
    bad = None
    if not re.match(r"PASS\b", first):
        bad = "review verdict is '%s', not PASS" % first[:40]
    elif not trees:
        bad = "the PASS line names no 'tree <key12>'"
    else:
        wrong = sorted({x for x in trees if not t.startswith(x)})
        if wrong:
            bad = "review names tree %s, the checkout is tree %s" % (wrong[0][:12], t[:12])
    if bad:
        if st.pop("review", None) is not None:
            save(path, st)
        print("VERDICT: RED — " + bad)
        return 1
    st["review"] = {"verdict": "PASS", "sha256": hashlib.sha256(raw).hexdigest(), "time": now()}
    save(path, st)
    print("VERDICT: GREEN — review PASS recorded for tree %s of %s/%s" % (t[:12], st.get("project"), st.get("package")))
    return 0


# osc results codes: what is not built here, and what is still on its way
SKIPPED = {"disabled", "excluded"}
WAITING = {"scheduled", "building", "blocked", "finished", "signing", "dispatching"}
SRCMD5 = re.compile(r"Building \S+ for project '[^']*' repository '[^']*' arch '[^']*' srcmd5 '([0-9a-f]+)'")


def osc_run(args, out=None):
    # (stdout, None), or (None, what failed): a failed lookup is never a verdict
    try:
        p = subprocess.run(["osc", *args], stdout=out or subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, timeout=900)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, type(e).__name__
    if p.returncode:
        return None, (p.stderr.strip().splitlines() or ["osc exited %d" % p.returncode])[-1][:160]
    return ("" if out else p.stdout), None


def xml(text):
    try:
        return ET.fromstring(text) if text is not None else None
    except ET.ParseError:
        return None


FACTORY_REPO = re.compile(r"openSUSE_(Factory(_\w+)?|Tumbleweed)")
LEAP16_REPO = re.compile(r"(openSUSE_Leap_)?16\.\d+")
ARCHES = {"x86_64", "aarch64"}
REDS = {"failed", "unresolvable", "broken"}


def obsbuild(path, d, prj, pkg, tmp, outdir, summary, scan, rpms="", repos="", arches=""):
    rx = {}
    for opt, v in (("--repos", repos), ("--arches", arches)):
        try:
            rx[opt] = re.compile(v) if v else None
        except re.error as e:
            print("gate.sh: %s %r: %s" % (opt, v, e), file=sys.stderr)
            return 2
    extra, wide = rx["--repos"], rx["--arches"]
    fm = files(d)
    t = key(fm) if fm is not None and present(fm) else ""
    st = load(path)
    if not t or not st or st.get("verdict") != "GREEN" or st.get("tree") != t:
        print("VERDICT: NO GATE — no GREEN gate run of tree %s: run gate.sh before the commit, then --obs-build" % (t[:12] or "?"))
        return 3
    who = "%s/%s" % (prj, pkg)
    text, err = osc_run(["api", "/source/%s/%s?expand=1" % (prj, pkg)])
    src = xml(text)
    srcmd5 = src.get("srcmd5") if src is not None else None
    if not srcmd5:
        print("VERDICT: UNKNOWN — cannot read the sources of %s: %s" % (who, err or "no srcmd5 in the listing"))
        return 1
    li = src.find("linkinfo")
    origin = (li.get("project"), li.get("package") or pkg) if li is not None and li.get("project") else None
    tprj = (st.get("target") or "").split("/")[0]
    leap = not (tprj == "openSUSE:Factory" or tprj.startswith("openSUSE:Factory:"))
    remote = {e.get("name"): e.get("md5") for e in src.findall("entry")
              if e.get("name") != "_link" and not (e.get("name") or "").startswith("_service:")}
    mine = st.get("files") if isinstance(st.get("files"), dict) else {}
    if remote != mine:
        odd = sorted(n for n in set(remote) | set(mine) if remote.get(n) != mine.get(n))
        print("VERDICT: RED — OBS holds other files than tree %s (%s): commit this tree, or gate the one OBS holds"
              % (t[:12], ", ".join(odd[:4])))
        return 1

    def red(why):
        cur = load(path)  # as it is now: a review may have been recorded meanwhile
        if cur and cur.get("tree") == t and cur.pop("build", None) is not None:
            save(path, cur)
        print("VERDICT: RED — %s: %s" % (who, why))
        return 1

    def unknown(why):
        print("VERDICT: UNKNOWN — %s: %s; the recorded build stays" % (who, why))
        return 1

    def pending(why):
        print("VERDICT: PENDING — %s sources %s: %s; wait with obs-wait.py build %s %s, then rerun"
              % (who, srcmd5[:12], why, prj, pkg))
        return 4

    text, err = osc_run(["results", "--xml", prj, pkg])
    res = xml(text)
    if res is None:
        print("VERDICT: UNKNOWN — cannot read the build results of %s: %s" % (who, err or "unparseable"))
        return 1
    entries, notes = [], []
    for r in res.findall("result"):
        repo, arch = r.get("repository") or "", r.get("arch") or ""
        fac = bool(FACTORY_REPO.fullmatch(repo)) or (
            repo == "standard" and (prj == "openSUSE:Factory" or prj.startswith("openSUSE:Factory:")))
        inside = (fac or (leap and LEAP16_REPO.fullmatch(repo)) or (extra and extra.search(repo))) \
            and (arch in ARCHES or (wide and wide.search(arch)))
        for s in r.findall("status"):
            name = s.get("package") or ""
            if name != pkg and not name.startswith(pkg + ":"):
                continue
            label = "%s/%s%s" % (repo, arch, name[len(pkg):])
            code = s.get("code") or ""
            state = "dirty" if r.get("dirty") == "true" else code or "no code"
            if code in SKIPPED:
                continue
            if not inside:
                notes.append("%s %s" % (label, state))
                continue
            entries.append((repo, arch, name, label, code, state, fac))
    # the link origin's state of each judged repo/arch, read only when one is not green
    theirs = {}
    if origin and any(e[5] != "succeeded" for e in entries):
        text, err = osc_run(["results", "--xml", origin[0], origin[1]])
        ores = xml(text)
        if ores is None:
            return unknown("cannot read the build results of %s/%s, the link origin: %s"
                           % (origin[0], origin[1], err or "unparseable"))
        for r in ores.findall("result"):
            for s in r.findall("status"):
                name = s.get("package") or ""
                if name == origin[1] or name.startswith(origin[1] + ":"):
                    theirs[(r.get("repository"), r.get("arch"), name[len(origin[1]):])] = s.get("code") or ""
    rows, bad, odd, waiting, pre, judged = [], [], [], [], [], set()
    for repo, arch, name, label, code, state, fac in entries:
        there = theirs.get((repo, arch, name[len(pkg):]))
        # disabled only: excluded follows the spec, whose ExclusiveArch the change may edit
        if there == "disabled":
            notes.append("%s %s (%s in %s)" % (label, state, there, origin[0]))
            continue
        judged.add(repo)
        if state == "dirty" or code in WAITING:
            waiting.append("%s %s" % (label, state))
        elif code in REDS and there in REDS:
            if code == "failed":
                rows.append((repo, arch, name, label, fac, True))
            else:
                pre.append("%s %s" % (label, code))
        elif code in ("succeeded", "failed"):
            rows.append((repo, arch, name, label, fac, False))
        elif code in REDS:
            bad.append("%s %s" % (label, code))
        else:
            odd.append("%s %s" % (label, state))
    if notes:
        print("note: not judged (--repos/--arches REGEX judges one): %s"
              % (", ".join(notes[:8]) + (" +%d more" % (len(notes) - 8) if len(notes) > 8 else "")))
    if not judged:
        return unknown("no Tumbleweed or Leap 16 repo builds it on x86_64 or aarch64; pass --repos/--arches REGEX for the ones that matter")
    if bad:
        return red(", ".join(bad))
    if odd:
        return unknown("states the gate cannot judge: " + ", ".join(odd[:6]))
    if waiting:
        return pending(", ".join(waiting[:6]) + (" +%d more" % (len(waiting) - 6) if len(waiting) > 6 else ""))
    os.makedirs(outdir, exist_ok=True)
    # factory: a Tumbleweed build succeeded; added: a green repo only --repos brought in
    reds, older, done, others, added, factory = [], [], [], set(), set(), False
    for repo, arch, name, label, fac, red_there in rows:
        logf = os.path.join(tmp, "%s-%s-%s.log" % (repo, arch, name.replace(":", "_")))
        with open(logf, "w", encoding="utf-8") as fh:
            _, err = osc_run(["rbl", prj, name, repo, arch], out=fh)
        if err:
            return unknown("cannot read the build log of %s: %s" % (label, err))
        with open(logf, encoding="utf-8", errors="replace") as fh:
            m = next((m for m in (SRCMD5.search(ln) for _, ln in zip(range(400), fh)) if m), None)
        if not m or m.group(1) != srcmd5:
            older.append("%s on %s" % (label, m.group(1)[:12] if m else "unknown sources"))
            continue
        if red_there:
            pre.append("%s failed" % label)
            continue
        p = subprocess.run([summary, logf], capture_output=True, text=True, cwd=d)
        with open(os.path.join(outdir, label.replace("/", "-").replace(":", "_") + ".txt"), "w", encoding="utf-8") as fh:
            fh.write(p.stdout + p.stderr)
        if p.returncode:
            v = next((ln[len("### VERDICT: "):] for ln in p.stdout.splitlines() if ln.startswith("### VERDICT: ")), "no verdict")
            reds.append("%s %s" % (label, v))
        else:
            done.append(label)
            if fac:
                factory = True
            else:
                others.add(repo)
                if not (leap and LEAP16_REPO.fullmatch(repo)):
                    added.add(repo)
    if pre:
        print("note: PRE-EXISTING, red in %s too (reported, not red): %s" % (origin[0], ", ".join(pre)))
    if reds:
        return red("build-summary.sh: %s (summaries: %s)" % ("; ".join(reds), outdir))
    if older:
        return pending("built from older sources: " + ", ".join(older[:6]))
    if not done:
        return unknown("no judged build succeeded, only reds %s has too" % origin[0])
    if rpms:
        p = subprocess.run([scan, d, "--rpms", rpms], capture_output=True, text=True, cwd=d)
        with open(os.path.join(outdir, "source-binaries.txt"), "w", encoding="utf-8") as fh:
            fh.write(p.stdout + p.stderr)
        if p.returncode:
            last = (p.stdout.strip().splitlines() or ["exit %d" % p.returncode])[-1]
            print("VERDICT: RED — source-binaries --rpms %s: %s (full output: %s)" % (rpms, last, outdir))
            return 1
    cur = load(path)  # as it is now: a review recorded meanwhile stays
    if not cur or cur.get("verdict") != "GREEN" or cur.get("tree") != t:
        print("VERDICT: UNKNOWN — the stamp of %s changed during the run: rerun --obs-build" % who)
        return 1
    if rpms:
        cur["rpms"] = {"dir": rpms, "time": now()}
    cur["build"] = {"verdict": "GREEN", "kind": "obs", "srcmd5": srcmd5, "builds": done,
                    "repos": sorted(judged), "factory": factory, "others": sorted(others),
                    "added": sorted(added), "preexisting": pre, "time": now()}
    save(path, cur)
    shown = ", ".join(done[:6]) + (" +%d more" % (len(done) - 6) if len(done) > 6 else "")
    rp = ", and the RPMs of %s checked" % rpms if rpms else ""
    pe = "; PRE-EXISTING: %s" % ", ".join(pre) if pre else ""
    print("VERDICT: GREEN — OBS build of tree %s recorded: sources %s, %s%s%s (summaries: %s)"
          % (t[:12], srcmd5[:12], shown, rp, pe, outdir))
    return 0


COPY = re.compile(r"^#\s*Copyright\b(.*)$", re.I)


def holders(path):
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return out
    for line in text.splitlines():
        m = COPY.match(line)
        if not m:
            continue
        h = re.sub(r"\((c|C)\)|©", " ", m.group(1))
        h = re.sub(r"^[\s,0-9-]+", "", h)
        h = re.sub(r"(,?\s+and\s+contributors)?[\s.]*$", "", h, flags=re.I)
        h = re.sub(r"\s+", " ", h).strip().lower()
        # spec-cleaner and format_spec_file rewrite the SUSE header themselves
        if h and not re.match(r"(suse|novell)\b", h):
            out.setdefault(h, line.strip())
    return out


def copyright(base, work):
    gone = [line for h, line in holders(base).items() if h not in holders(work)]
    for line in gone:
        print("gone: %s" % line)
    return 1 if gone else 0


TAG = re.compile(r"PATCH-(?:(?:FIX|FEATURE)-(?:UPSTREAM|OPENSUSE|SLE)|NEEDS-REBASE)\b")
PATCH = re.compile(r"Patch\d*\s*:\s*(\S+)", re.I)
MACRO = re.compile(r"%\{\??(\w+)\}|%(\w+)")
# a URL; gh#o/r#N, gh#o/r!N, glgo#GNOME/x!N; a bug id (bsc#N, fdo#N, GCC#N, RT#N)
REF = re.compile(r"https?://\S+|\b[a-z][\w-]*#(?:[\w.-]+/)+[\w.-]+[#!]\d+|\b[a-z][a-z0-9]*[#!]\d+", re.I)
HEX = re.compile(r"\b[0-9a-f]{7,40}\b")


def named(name, text):  # the file as a whole token: not notfix.patch, not fix.patch.orig
    return re.search(r"(?<![\w.+-])%s(?![\w+-]|\.\w)" % re.escape(name), text) is not None


def cited(lines, names):
    text = "\n".join(lines)
    for n in names:  # a hash-like file name is no reference
        text = text.replace(n, " ")
    return bool(REF.search(text)) or any(re.search(r"\d", h) and re.search(r"[a-f]", h) for h in HEX.findall(text))


def untouched(against):
    # "strict": every patch counts as touched; "git:REF": the file as REF has
    # it; else a directory listing (the target's, or .osc/_files)
    if against == "strict":
        return lambda f: False
    if against.startswith("git:"):
        ref = against[4:]

        def same_git(f):
            return (subprocess.run(["git", "cat-file", "-e", "%s:./%s" % (ref, f)], capture_output=True).returncode == 0
                    and subprocess.run(["git", "diff", "--quiet", ref, "--", f], capture_output=True).returncode == 0)
        return same_git
    try:
        md5 = {e.get("name"): e.get("md5") for e in ET.parse(against).getroot().findall("entry")}
    except (OSError, ET.ParseError):
        return lambda f: False

    def same(f):
        if f not in md5:
            return False
        h = hashlib.md5()
        try:
            with open(f, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
        except OSError:
            return False
        return h.hexdigest() == md5[f]
    return same


def spec_macros(lines):
    # Name, Version and plain %define/%global values, the first of each
    macros = {}
    for line in lines:
        m = re.match(r"(name|version)\s*:\s*(\S+)", line, re.I)
        if m:
            macros.setdefault(m.group(1).lower(), m.group(2))
        m = re.match(r"%(?:define|global)\s+(\w+)\s+(\S+)\s*$", line)
        if m:
            macros.setdefault(m.group(1), m.group(2))
    return macros


def spec_values(lines):
    # every Name, Version and plain %define/%global value: a _multibuild spec
    # defines a macro once per flavor, the flavor's often first
    vals = {"nil": [""]}
    for line in lines:
        m = re.match(r"(name|version)\s*:\s*(\S+)", line, re.I)
        if m:
            vals.setdefault(m.group(1).lower(), []).append(m.group(2))
        m = re.match(r"%(?:define|global)\s+(\w+)\s+(\S+)\s*$", line)
        if m:
            vals.setdefault(m.group(1), []).append(m.group(2))
    return vals


def expansions(s, vals, depth=8):
    # every spelling of s those values give it, at most 32; %{?x} is also
    # empty, as rpm makes it where x is not defined (the base build of a
    # flavor that alone defines x)
    m = next((m for m in MACRO.finditer(s)
              if (m.group(1) or m.group(2)) in vals or m.group(0).startswith("%{?")), None)
    if m is None or depth == 0:
        return {s}
    out = set()
    cands = vals.get(m.group(1) or m.group(2), [])[:8]
    for v in cands + [""] * (m.group(0).startswith("%{?") and "" not in cands):
        out |= expansions(s[: m.start()] + v + s[m.end():], vals, depth - 1)
        if len(out) >= 32:
            break
    return out


EMPTY_IF = re.compile(r'%if\s+"%\{?\??(\w+)\}?"\s*==\s*""\s*$')


def base_excluded(lines, vals):
    # ExclusiveArch: do_not_build (or do-not-build) under %if "%{flavor}" == "" (or another macro
    # holding @BUILD_FLAVOR@, as pg_name does): no base package build
    def flavorish(m):
        return m == "flavor" or any("@BUILD_FLAVOR@" in x for x in expansions("%{" + m + "}", vals))

    stack = []
    for line in lines:
        t = line.strip()
        if re.match(r"%if(?:arch|narch|os|nos)?\b", t):
            m = EMPTY_IF.match(t)
            stack.append(bool(m) and flavorish(m.group(1)))
        elif re.match(r"%el(?:se|if)", t) and stack:
            stack[-1] = False
        elif re.match(r"%endif\b", t) and stack:
            stack.pop()
        elif stack and stack[-1] and re.match(r"ExclusiveArch:\s*do[_-]not[_-]build\b", t):
            return True
    return False


def expand_macros(s, macros):
    for _ in range(5):
        t = MACRO.sub(lambda m: macros.get(m.group(1) or m.group(2), m.group(0)), s)
        if t == s:
            break
        s = t
    return s


def verdicts(lines):
    # (line number, patch file, what is wrong with its tag or None) per Patch line
    macros = spec_macros(lines)

    def expand(s):
        return expand_macros(s, macros)

    def base(s):  # a URL Patch names its file after #/, else by its last path part
        return s.split("#/")[-1] if "#/" in s else s.rsplit("/", 1)[-1]

    out = []
    for i, line in enumerate(lines):
        m = PATCH.match(line)
        if not m:
            continue
        f = base(expand(m.group(1)))
        names = {base(m.group(1)), f}
        j = i - 1  # an %if/%ifarch around the Patch line sits between it and its comment
        while j >= 0 and re.match(r"%(if|else|elif|endif)", lines[j].strip()):
            j -= 1
        block = []
        while j >= 0 and lines[j].lstrip().startswith("#"):
            block.insert(0, lines[j])
            j -= 1
        tagged = [k for k, t in enumerate(block) if TAG.search(t)]
        naming = [k for k in tagged if any(named(n, block[k]) for n in names)]
        why = None
        if not tagged:
            why = "%s has no PATCH-* tag in the comment above it" % f
        elif not naming:
            why = "the PATCH-* tag above %s does not name it" % f
        # the reference is this tag's: from its line down, plus the Patch value
        elif "UPSTREAM" in TAG.search(block[naming[-1]]).group(0) and not cited(block[naming[-1]:] + [m.group(1)], names):
            why = "the PATCH-*-UPSTREAM tag of %s cites no reference (URL, gh#owner/repo#N, commit, bug id like bsc#N)" % f
        out.append((i + 1, f, why))
    return out


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def tags(spec, against="strict", basespec=""):
    try:
        lines = read_lines(spec)
    except OSError as e:
        print("%s: cannot read it: %s" % (spec, e.strerror))
        return 1
    same = untouched(against)
    kept = set()  # patches the target's spec tags correctly: losing that tag is a change
    if basespec:
        try:
            kept = {f for _, f, why in verdicts(read_lines(basespec)) if why is None}
        except OSError:
            same = untouched("strict")
    bad = 0
    for n, f, why in verdicts(lines):
        if why and same(f) and f not in kept:  # shipped as is: whoever changes it next tags it
            print("note: %s:%d: %s (unchanged from the target)" % (spec, n, why))
        elif why:
            print("%s:%d: %s" % (spec, n, why))
            bad = 1
    return bad




# a section name rpm would read as one: %prep, %build, %files, %post, %pretrans ...
SECTION = re.compile(
    r"(?<!%)%(prep|build|install|check|files|changelog|package|description|conf|generate_buildrequires|"
    r"(?:pre|post)(?:un|trans|untrans)?|verifyscript|(?:trans)?filetrigger(?:in|un|postun)|"
    r"trigger(?:in|un|postun|prein)|sourcelist|patchlist)(?![\w-])"
)
MACROREF = re.compile(r"(?<!%)%[{(A-Za-z_]")


def rpmspec(path):
    try:
        return subprocess.run(["rpmspec", "-P", "--define", "_sourcedir " + os.getcwd(), path],
                              capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired):
        return None


def first_error(p):
    errs = [ln.strip() for ln in p.stderr.splitlines() if re.match(r"\s*error:|\S+: invalid option", ln)]
    return "; ".join(errs[:2]) or (p.stderr.strip().splitlines() or ["exit %d" % p.returncode])[-1]


def write(path, lines):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def as_built(lines, flavor=""):
    # OBS sets @BUILD_FLAVOR@ to the _multibuild flavor, empty for the default build
    return [ln.replace("@BUILD_FLAVOR@", flavor) for ln in lines]


def defined(name):
    try:
        out = subprocess.run(["rpm", "--eval", "%%{?%s:1}" % name], capture_output=True, text=True).stdout
    except OSError:
        return True
    return out.strip() == "1"


# rpm's own macros and spec directives: never a package's macro the host lacks
BUILTINS = set("""define global undefine expand lua if ifarch ifnarch ifos ifnos else elif elifarch elifos endif
include patch setup autosetup autopatch dnl echo warn error verbose trace dump getenv basename dirname exists
suffix url2path uncompress quote shescape shrink len upper lower sub gsub rep reverse expr S P nil load
getncpus rpmversion""".split())


def errors(err):
    return [ln for ln in err.splitlines() if "error:" in ln]


def provided(names):
    # every name is something an installed package provides (rpm -q --whatprovides)
    if not names:
        return True
    try:
        return subprocess.run(["rpm", "-q", "--whatprovides"] + names, capture_output=True).returncode == 0
    except OSError:
        return False


def buildrequires(path, lines):
    # the names a spec BuildRequires: rpmspec's own answer when it parses, else the
    # lines outside any %if (a dependency that names a macro is skipped)
    p = subprocess.run(["rpmspec", "-q", "--buildrequires", "--define", "_sourcedir " + os.getcwd(), path],
                       capture_output=True, text=True) if path else None
    if p is not None and p.returncode == 0:
        return [ln.split()[0] for ln in p.stdout.splitlines() if ln.strip() and not ln.startswith("(")]
    names, depth = [], 0
    for ln in lines:
        t = ln.strip()
        if re.match(r"%if", t):
            depth += 1
        elif re.match(r"%endif\b", t):
            depth = max(depth - 1, 0)
        elif not depth and re.match(r"BuildRequires:", t, re.I):
            value = t.split(":", 1)[1].strip()
            if "%" in value:  # what this host's macros make of it; a spec's own macro stays unknown
                try:
                    value = subprocess.run(["rpm", "--eval", value], capture_output=True, text=True).stdout.strip()
                except OSError:
                    continue
                if "%" in value:
                    continue
            words = re.split(r"[\s,]+", value)
            skip = False
            for w in words:
                if skip or not w:
                    skip = False
                elif w in ("<", ">", "=", "<=", ">=", "=="):
                    skip = True  # the version after it
                elif not w.startswith("("):
                    names.append(w)
    return names


def host_parse(lines, err, path):
    # a parse that stops on what only the build root has: a macro a missing
    # BuildRequires defines (Requires: %{apache_mmn} without apache2-devel), or
    # %requires_eq/%pkg_vcmp asking about a package this host lacks
    if re.search(r"is obsolete|not specified|invalid option|Unknown option", err):
        return None
    msg = "\n".join(errors(err))
    if "does not resolve" in msg or "(~~~" in msg:
        why = "a package %requires_eq or %pkg_vcmp asks about"
    else:
        own = set(re.findall(r"^\s*%(?:define|global)\s+(\w+)", "\n".join(lines), re.M))
        names = [n for n in dict.fromkeys(re.findall(r"%\{?[?!]*([A-Za-z_]\w*)", msg))
                 if n not in BUILTINS and n not in own and not SECTION.fullmatch("%" + n) and not defined(n)]
        if not names:
            return None
        why = "macro %%%s, which no package here defines" % names[0]
    # every BuildRequires installed here: the build root has no more than this host
    return None if provided(buildrequires(None, lines)) else why


def flavors_only(raw):
    # ExclusiveArch: do_not_build directly under %if "%{<flavor macro>}" == ""
    names = set(re.findall(r"^\s*%(?:define|global)\s+(\w+)\s+@BUILD_FLAVOR@", "\n".join(raw), re.M))
    for i, ln in enumerate(raw):
        if not re.match(r"\s*ExclusiveArch:\s*do_not_build\b", ln):
            continue
        depth = 0
        for t in (x.strip() for x in reversed(raw[:i])):
            if re.match(r"%endif\b", t):
                depth += 1
            elif re.match(r"%(?:else|elif)", t) and not depth:
                break
            elif re.match(r"%if", t):
                if depth:
                    depth -= 1
                    continue
                m = re.match(r'%if\s+"%\{?(\w+)\}?"\s*==\s*""$', t)
                if m and m.group(1) in names:
                    return True
                break
    return False


def parse(spec, logdir):
    # rpm expands macros in comments: %prep there broke opencode's
    # build, and a multi-line macro there runs its lines as commands
    try:
        raw = read_lines(spec)
    except OSError as e:
        print("%s: cannot read it: %s" % (spec, e.strerror))
        return 1
    variants = [""] + ((flavors(".") or []) if any("@BUILD_FLAVOR@" in ln for ln in raw) else [])
    # a _multibuild spec may build only its flavors (qmqtt: ExclusiveArch: do_not_build)
    off = len(variants) > 1 and flavors_only(raw)
    bad, primary, host = 0, None, False
    for flavor in variants:
        path = os.path.join(logdir, "flavor-%s.%s" % (flavor or "default", spec))
        write(path, as_built(raw, flavor))
        q = rpmspec(path)
        what = spec + (" (flavor %s)" % flavor if flavor else "")
        if q is not None and q.returncode == 0:
            # %prep and the comment check read the first build OBS runs
            if primary is None and not (off and not flavor and re.search(r"^ExclusiveArch:\s*do_not_build", q.stdout, re.M)):
                primary = (flavor, q)
        elif off and not flavor:
            print("note: %s: the default build does not parse, and the spec builds only its flavors (do_not_build)" % spec)
        elif q is None:
            print("UNKNOWN: rpmspec -P %s did not finish" % what)
            bad = 1
        elif host_parse(raw, q.stderr, path):
            print("UNKNOWN: %s: rpmspec -P stopped on what this host lacks: %s — the build log decides"
                  % (what, host_parse(raw, q.stderr, path)))
            host = True
        else:
            print("%s: rpmspec -P fails: %s" % (what, first_error(q).replace(path, spec)))
            for n in (int(x) for x in re.findall(r"line (\d+):", "\n".join(errors(q.stderr)))):
                if 0 < n <= len(raw) and raw[n - 1].lstrip().startswith("#"):
                    print("%s:%d is a comment, and rpm expands macros in comments: write %%%% for each %% there" % (spec, n))
                    break
            bad = 1
    p = primary[1] if primary else None
    lines = as_built(raw, primary[0] if primary else "")
    if primary:
        write(os.path.join(logdir, "rpm." + spec), lines)
        write(os.path.join(logdir, "flavor." + spec), [primary[0]])
        with open(os.path.join(logdir, "parsed." + spec), "w", encoding="utf-8") as fh:
            fh.write(p.stdout)
    elif host and not bad:
        write(os.path.join(logdir, "hostonly." + spec), [])
    end = next((i for i, ln in enumerate(lines) if re.match(r"%changelog\b", ln)), len(lines))
    cand = []
    for i, line in enumerate(lines[:end]):
        if not line.lstrip().startswith("#"):
            continue
        found = [m.group(1) for m in SECTION.finditer(line)]
        if "prep" in found:
            print("%s:%d: %%prep in a comment: rpm expands macros in comments, and OBS declined opencode "
                  "for one (sr#1394137, Unknown tag: %%prep): write %%%%prep" % (spec, i + 1))
            bad = 1
        elif found:
            # only %prep is proven to break an OBS build
            print("note: %s:%d: %%%s in a comment: rpm may expand it, write %%%%%s" % (spec, i + 1, found[0], found[0]))
        joined = line.rstrip().endswith("\\") or (i and lines[i - 1].rstrip().endswith("\\"))
        if MACROREF.search(line) and not joined:
            cand.append(i)
    if cand and p is not None:
        # each candidate between marker comments: in a script rpm keeps both, so
        # what lies between them is that one line's expansion
        marked, at = [], set(cand)
        for i, line in enumerate(lines):
            marked += ["#GATE-OPEN-%d" % i, line, "#GATE-SHUT-%d" % i] if i in at else [line]
        path = os.path.join(logdir, "marked." + spec)
        write(path, marked)
        q = rpmspec(path)
        if q is None or q.returncode != 0:
            print("note: %s: comment expansions not checked (the marked copy does not parse)" % spec)
            return bad
        pos = {ln: k for k, ln in enumerate(q.stdout.splitlines()) if ln.startswith("#GATE-")}
        for i in cand:
            a, b = pos.get("#GATE-OPEN-%d" % i), pos.get("#GATE-SHUT-%d" % i)
            if a is not None and b is not None and b - a > 2:
                print("%s:%d: the comment's macro expands to %d lines, which rpm runs as commands "
                      "(codenomad's comment ran cargo test): write %%%% for its %%" % (spec, i + 1, b - a - 1))
                bad = 1
    return bad


def flat(text):
    return [" ".join(ln.split()) for ln in text.splitlines()]


def unbraced(line):
    return " ".join(re.sub(r"%\{([!?]*\w+)\}", r"%\1", line).split())


def cleaned(spec, out, logdir):
    # spec-cleaner hunks that only add or drop macro braces must expand as before
    try:
        with open(os.path.join(logdir, "parsed." + spec), encoding="utf-8") as fh:
            want = flat(fh.read())
        with open(os.path.join(logdir, "flavor." + spec), encoding="utf-8") as fh:
            flavor = fh.read().strip()
        a, b = read_lines(spec), read_lines(out)
    except OSError:
        return 0  # the spec does not parse: the rpmspec gate says so
    pairs = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == "replace" and i2 - i1 == j2 - j1:
            pairs += [(i1 + k, j1 + k) for k in range(i2 - i1)
                      if a[i1 + k] != b[j1 + k] and unbraced(a[i1 + k]) == unbraced(b[j1 + k])]

    def broken(sel):
        lines = list(a)
        for i, j in sel:
            lines[i] = b[j]
        path = os.path.join(logdir, "trial." + spec)
        write(path, as_built(lines, flavor))
        p = rpmspec(path)
        if p is None:
            return ""
        if p.returncode != 0:
            return "does not parse (%s)" % first_error(p).replace(path, spec)
        return "expands differently" if flat(p.stdout) != want else ""

    found = 0
    if pairs and broken(pairs):
        for i, j in pairs:
            why = broken([(i, j)])
            if why:
                fix = ("write the options after `--` (`%cargo_build -- <args>`), which spec-cleaner leaves alone"
                       if "option" in why else "keep the line and name it with --cleaner-deviation")
                print("KNOWN DEFECT: %s:%d: spec-cleaner's `%s` %s, the spec's `%s` does not: a spec-cleaner "
                      "bug, not a missed rule. Do not apply it; %s" % (spec, i + 1, b[j].strip(), why, a[i].strip(), fix))
                found += 1
    if not found:
        path = os.path.join(logdir, "trial." + spec)
        write(path, as_built(b, flavor))
        p = rpmspec(path)
        if p is not None and p.returncode != 0:
            print("KNOWN DEFECT: %s: spec-cleaner's output does not parse (%s) where the spec does: "
                  "do not apply it whole" % (spec, first_error(p).replace(path, spec)))
            found += 1
    return 1 if found else 0


def prepkey(spec):
    # what %prep reads: the spec, every other file but the .changes, and rpm itself
    try:
        v = subprocess.run(["rpm", "--version"], capture_output=True, text=True).stdout
    except OSError:
        return 1
    # the salt: a pass from before %prep ran in the sandbox is no pass
    h = hashlib.sha256(b"sandbox-1\0" + v.encode() + b"\0" + spec.encode())
    for n in sorted(os.listdir(".")):
        if n.startswith(".") or n.endswith(".changes") or not os.path.isfile(n):
            continue
        m = hashlib.md5()
        with open(n, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                m.update(chunk)
        h.update(("%s  %s\n" % (m.hexdigest(), n)).encode())
    print(h.hexdigest())
    return 0


def hostonly(logpath, specpath):
    # a %prep that stopped on what the build root would have: a tool, a file a
    # BuildRequires installs, a source a server-side or buildtime service makes
    try:
        text = read_lines(logpath)
    except OSError:
        return 1
    here = os.getcwd()
    # bash -e stops at the command that failed: only its output counts
    last = max((k for k, ln in enumerate(text) if ln.startswith("+ ")), default=-1)
    lack = None  # what a missing BuildRequires would bring
    for line in reversed(text[last + 1:]):
        m = re.search(r"Architecture is (?:not included|excluded): \S+", line)
        if m:
            print("a build arch (rpm: %s)" % m.group(0))
            return 0
        m = re.search(r"(\S+): command not found$", line)
        if m:
            lack = "%s is not on this host" % m.group(1)
            break
        m = re.search(r"No module named '([^']+)'", line)
        if m:
            lack = "python module %s is not on this host" % m.group(1)
            break
        m = re.search(r"['‘]?(/(?:usr|etc|opt|lib|lib64|bin|sbin)/[^'’:]*)['’]?: No such file or directory", line)
        if m:
            lack = m.group(1)
            break
        m = re.match(r"error: File (\S+): No such file or directory", line)
        if m and os.path.dirname(m.group(1)) == here and services():
            print("%s, which a source service makes" % os.path.basename(m.group(1)))
            return 0
    if lack is None:
        return 1
    try:
        lines = read_lines(specpath)
    except OSError:
        lines = []
    # every BuildRequires is here: the build root would fail the same way
    if provided(buildrequires(specpath, lines)):
        return 1
    print(lack)
    return 0


SOURCE_SERVICES = {"obs_scm", "tar_scm", "tar", "recompress", "download_files", "go_modules", "cargo_vendor",
                   "node_modules"}


def services():
    # a service that makes sources and runs on OBS (no mode, buildtime, serveronly)
    try:
        root = ET.parse("_service").getroot()
    except (OSError, ET.ParseError):
        return False
    return any(s.get("name") in SOURCE_SERVICES and s.get("mode") in (None, "", "buildtime", "serveronly")
               for s in root.findall("service"))


def need(dirname):
    # KiB %prep may unpack: 8 times the sources (nodejs-electron: 2.1 GB of them, 13 GB unpacked)
    total = 0
    for n in os.listdir(dirname):
        p = os.path.join(dirname, n)
        if not n.startswith(".") and os.path.isfile(p):
            total += os.path.getsize(p)
    print(8 * total // 1024 + 1)
    return 0


def excerpt(logpath):
    # the lines before rpm's own summary: the command that failed and its error
    try:
        text = [ln for ln in read_lines(logpath) if ln.strip()]
    except OSError:
        return 1
    for k, ln in enumerate(text):
        if ln.startswith(("RPM build errors:", "RPM build warnings:")):
            text = text[:k]
            break
    for ln in text[-6:]:
        print("  " + ln[:300])
    return 0
SEP = "-" * 67


def entries(path):
    """The entries of a .changes, each its lines with trailing blanks dropped;
    None when there is no such file."""
    try:
        lines = read_lines(path)
    except OSError:
        return None
    out = []
    for line in lines:
        if line == SEP:
            out.append([])
        elif out:
            out[-1].append(line.rstrip())
    for e in out:
        while e and not e[-1]:
            e.pop()
    return [tuple(e) for e in out]


def changed(against):
    """The files that differ from against (a listing, or git:REF), or None
    when they cannot be compared."""
    if against.startswith("git:"):
        p = subprocess.run(["git", "diff", "--relative", "--name-only", against[4:], "--", "."],
                           capture_output=True, text=True)
        return sorted(p.stdout.splitlines()) if p.returncode == 0 else None
    work = files(".")
    try:
        root = ET.parse(against).getroot()
    except (OSError, ET.ParseError):
        return None
    if work is None:
        return None
    base = {e.get("name"): e.get("md5") for e in root.findall("entry")
            if e.get("name") != "_link" and not (e.get("name") or "").startswith("_service:")}
    return sorted(n for n in set(work) | set(base) if work.get(n) != base.get(n))


def entry(label, against, elabel, basedir, *changes):
    # 0: no file differs from label's copy (against), or a top entry is new
    # against elabel's .changes (in basedir; one missing there is new);
    # 1: the files differ and none is; 2: the files cannot be compared
    diff = changed(against)
    if diff is None:
        print("UNKNOWN: cannot compare the files with %s" % label)
        return 2
    if not diff:
        print("OK: no file differs from %s" % label)
        return 0
    new = []
    for ch in changes:
        work, base = entries(ch), entries(os.path.join(basedir, ch))
        if work and (base is None or work[0] not in base):
            new.append(ch)
    if new:
        print("OK: %s: its top entry is new vs %s" % (", ".join(new), elabel))
        return 0
    few = ", ".join(diff[:4]) + (", …" if len(diff) > 4 else "")
    lacks = "it lacks" if elabel == label else "%s lacks" % elabel
    waive = "" if os.environ.get("ENTRY_FACTORY") else (
        "; only when the user said so or the change is cosmetic, --no-entry REASON")
    print("RED: %s changed vs %s, and no .changes has a top entry %s: add one, or amend"
          " your own top entry Factory lacks with --amend-top (amend, don't stack)%s" % (few, label, lacks, waive))
    return 1


CMT = re.compile(r"\s*#")
# Commented-out spec code and the scan's exception lines, which are no prose.
CMT_CODE = re.compile(r"\s*#\s*(?:%[\w{(!?]|Source-Binary-Exception:|(?:Build)?Requires(?:\(\w+\))?:"
                      r"|Recommends:|Suggests:|Provides:|Obsoletes:|Conflicts:|(?:Source|Patch)\d*:)")
BULLET = re.compile(r"\s*#\s*[-*]\s")
CONT = re.compile(r"\s*#\s{2,}\S")
BARE = re.compile(r"\s*#\s*$")
NOTICE = re.compile(r"Legal-Review-Notice\b[^:]*:")  # "Legal-Review-Notice (boo#N):" too
LONG = 3


def comments(spec, basespec=""):
    """The comment blocks spec adds over basespec (every one without it), the
    header excepted, that run past LONG lines, bare "#" lines not counted; a
    Legal-Review-Notice block may be its notice line, wrapped once, and bullets
    of at most two lines each."""
    try:
        lines = read_lines(spec)
    except OSError as e:
        print("%s: cannot read it: %s" % (spec, e.strerror))
        return 1
    try:
        base = read_lines(basespec) if basespec else None
    except OSError:
        base = None
    if base is None:
        added = set(range(len(lines)))
    else:
        added = set()
        for tag, _, _, j1, j2 in difflib.SequenceMatcher(None, base, lines, autojunk=False).get_opcodes():
            if tag in ("replace", "insert"):
                added.update(range(j1, j2))
        # a comment moved or kept is not added; a bare "#" says nothing either way
        moved = {ln.strip() for ln in base if CMT.match(ln) and not BARE.match(ln)}
        added = {i for i in added if lines[i].strip() not in moved}
    head = 0
    while head < len(lines) and CMT.match(lines[head]):
        head += 1
    if not any(re.search(r"spec file for package|Copyright", ln) for ln in lines[:head]):
        head = 0  # no header: the first comment is the change's too
    bad, i = 0, head
    while i < len(lines):
        if not CMT.match(lines[i]):
            i += 1
            continue
        j = i
        while j < len(lines) and CMT.match(lines[j]):
            j += 1
        block = range(i, j)
        new = {k for k in block if k in added and not CMT_CODE.match(lines[k])}
        why, fix = None, "one line, two at most, saying why"
        if new and any(NOTICE.search(lines[k]) for k in block):
            fix = "the findings as short bullets"
            bullets, cont, wrap = 0, 0, 0
            for k in block:
                if NOTICE.search(lines[k]):
                    wrap = 1
                elif BARE.match(lines[k]):
                    continue
                elif BULLET.match(lines[k]):
                    bullets, cont, wrap = bullets + 1, 0, 0
                elif wrap:
                    wrap = 0  # the notice line, wrapped once
                elif CONT.match(lines[k]) and bullets and not cont:
                    cont = 1
                elif k in added:
                    why = "a Legal-Review-Notice line that is no short bullet: %s" % lines[k].strip()[:60]
                    break
                else:
                    wrap = 0
        elif new:
            run = longest = 0
            for k in block:
                if BARE.match(lines[k]):
                    continue  # neither counts nor splits the comment
                run = run + 1 if k in new else 0
                longest = max(longest, run)
            if longest > LONG:
                why = "a %d-line comment" % longest
        if why:
            print("%s:%d: %s — %s (references/specfile-guidelines.md \"Spec file — general"
                  " rules\")" % (spec, i + 1, why, fix))
            bad = 1
        i = j
    return bad

cmd, args = sys.argv[1], sys.argv[2:]
fn = {"link": link, "tracked": tracked, "stamp": stamp, "review": review, "obsbuild": obsbuild,
      "buildlogs": buildlogs, "copyright": copyright, "tags": tags,
      "parse": parse, "cleaned": cleaned, "prepkey": prepkey, "hostonly": hostonly, "excerpt": excerpt,
      "need": need, "entry": entry, "comments": comments}[cmd]
sys.exit(fn(*args))
PYEOF
py() { python3 -c "$PY" "$@"; }
dir=.; entries=1; amend=""; squash=""; target=""; gitbase=""; buildlogs=(); rpms=""; deviation=""; noentry=""; full=0; review=""; nopts=0
obsbuild=0; repos=""; arches=""
while [ $# -gt 0 ]; do
  case "$1" in --entries|--amend-top|--squash-mine|--target|--git-base|--build-log|--rpms|--cleaner-deviation|--no-entry|--review|--repos|--arches) [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; };; esac
  case "$1" in --entries|--amend-top|--squash-mine|--target|--git-base|--build-log|--rpms|--cleaner-deviation|--no-entry|--full) nopts=$((nopts+1)) ;; esac
  case "$1" in
    -h|--help) awk 'NR>1 { if (!/^#/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --entries) [[ $2 =~ ^[1-9][0-9]*$ ]] || { echo "gate.sh: --entries takes a positive integer, got '$2'" >&2; exit 2; }
               entries=$2; shift 2 ;;
    --amend-top) amend=$2; shift 2 ;;
    --squash-mine) squash=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --git-base) gitbase=$2; shift 2 ;;
    --build-log) if [ -e "$2" ]; then buildlogs+=("$(realpath -- "$2")"); else buildlogs+=("$2"); fi; shift 2 ;;
    --rpms) rpms=$(realpath -m -- "$2"); shift 2 ;;
    --cleaner-deviation) [ -n "$2" ] || { echo "gate.sh: --cleaner-deviation needs the reason" >&2; exit 2; }
                         deviation=$2; shift 2 ;;
    --no-entry) [ -n "$2" ] || { echo "gate.sh: --no-entry needs the reason" >&2; exit 2; }
                noentry=$2; shift 2 ;;
    --full) full=1; shift ;;
    --review) review=$(realpath -m -- "$2"); shift 2 ;;
    --obs-build) obsbuild=1; shift ;;
    --repos) repos=$2; shift 2 ;;
    --arches) arches=$2; shift 2 ;;
    -*) echo "gate.sh: unknown option $1" >&2; exit 2 ;;
    *) dir=$1; shift ;;
  esac
done
[ -z "$review" ] || [ "$nopts" = 0 ] || { echo "gate.sh: --review records a verdict and runs no gate: it takes DIR only" >&2; exit 2; }
[ "$obsbuild" = 0 ] || { [ -z "$review" ] && [ "$nopts" = "$([ -n "$rpms" ] && echo 1 || echo 0)" ]; } \
  || { echo "gate.sh: --obs-build records OBS's build and runs no gate: it takes DIR, --rpms, --repos and --arches only" >&2; exit 2; }
[ -z "$repos$arches" ] || [ "$obsbuild" = 1 ] || { echo "gate.sh: --repos and --arches go with --obs-build" >&2; exit 2; }
cd "$dir" || exit 2
# Anywhere else source_validator reports rc=0 over nothing: a green piece of a
# verdict about no package.
specs=( *.spec )
if [ ! -e "${specs[0]}" ] && [ ! -r .osc/_package ]; then
  if [ -r .osc/_project ]; then echo "gate.sh: $(pwd): osc project checkout — cd into the package directory" >&2
  else echo "gate.sh: $(pwd): no *.spec and no .osc/_package — not a package checkout" >&2; fi
  exit 2
fi
pkg=$(basename "$(pwd -P)"); [ -r .osc/_package ] && pkg=$(tr -d '\n' < .osc/_package)
# A classic osc checkout (not a git/scmsync one): its own project, and the stamp.
own=""; [ -r .osc/_project ] && [ -r .osc/_package ] && [ ! -e .osc/_scm ] && own=$(tr -d '\n' < .osc/_project)
stampf=""; [ -n "$own" ] && [[ $own != */* && $pkg != */* && $pkg != .* ]] \
  && stampf="$HOME/.local/state/opensuse-packaging/gate/obs/$pkg/$own.json"
if [ -n "$review" ]; then
  [ -n "$stampf" ] || { echo "gate.sh: --review needs an osc package checkout (.osc/_project and .osc/_package)" >&2; exit 2; }
  py review "$stampf" . "$review"; exit $?
fi
if [ "$obsbuild" = 1 ]; then
  [ -n "$stampf" ] || { echo "gate.sh: --obs-build needs an osc package checkout (.osc/_project and .osc/_package)" >&2; exit 2; }
  # the logs go under /var/tmp, not the /tmp tmpfs; the summaries stay with the gate's output
  dl=$(mktemp -d -p /var/tmp "gate-obs-$pkg.XXXXXX") || { echo "VERDICT: UNKNOWN — no scratch directory under /var/tmp"; exit 1; }
  sums="${TMPDIR:-/tmp}/gate-$pkg/obs-build"; rm -rf "$sums"
  py obsbuild "$stampf" . "$own" "$pkg" "$dl" "$sums" "$HERE/build-summary.sh" "$HERE/source-binaries.py" "$rpms" "$repos" "$arches"; rc=$?
  rm -rf "$dl"; exit $rc
fi
log="${TMPDIR:-/tmp}/gate-$pkg"; rm -rf "$log"; mkdir -p "$log"
red=()
# %prep's process group and scratch go on every way out; a signal exits 130
prep_pid=""; bp=""
# shellcheck disable=SC2317  # run by the EXIT trap
cleanup() {
  [ -z "$prep_pid" ] || { kill -TERM -- "-$prep_pid" 2>/dev/null; wait "$prep_pid" 2>/dev/null; }
  [ -z "$bp" ] || { chmod -R u+w "$bp" 2>/dev/null; rm -rf "$bp"; }
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
show() {   # $1 name, $2 rc, $3 output file
  printf '## %s: rc=%s\n' "$1" "$2"
  if [ $full -eq 1 ]; then cat "$3"; else tail -n 12 "$3"; fi
  [ "$2" -eq 0 ] || red+=("$1")
}

# The SR target, and whether this checkout's history is the target's. A branch
# of a stale copy in another project, submitted to Factory's devel project,
# deletes the devel entries the copy never had (sr#1392134: hardware's 0.9.5
# copy filed to devel:languages:python at 0.9.8). Only for osc checkouts; a git
# checkout names its target with --git-base.
tgt=""; tprj=""; tpkg=""
if [ -n "$own" ]; then
  : > "$log/target.txt"; rc=0
  origin=$(py link . "$own" "$pkg" 2> "$log/link.err"); lrc=$?
  if [ $lrc -ne 0 ]; then
    echo "UNKNOWN: cannot read the checkout's link: osc api /source/$own/$pkg failed" >> "$log/target.txt"; rc=1
  fi
  oprj=${origin%%/*}; base=${oprj:-$own}; bpkg=$pkg; [ -z "$origin" ] || bpkg=${origin#*/}
  devel=""; drc=-1
  devel_of() { devel=$(timeout 60 "$HERE/devel-of.sh" "$pkg" 2>> "$log/target.txt"); drc=$?; }
  tgt=$target
  if [ -z "$tgt" ]; then
    if [ -n "$oprj" ] && [[ $oprj =~ ^(openSUSE|SUSE): ]] && [ "$oprj" != openSUSE:Factory ]; then
      tgt=$origin                    # maintenance work: the branched update project
    else
      devel_of
      case $drc in
        0) tgt=$devel ;;
        3|4) tgt=${origin:-$own/$pkg}; echo "note: $pkg has no devel project in openSUSE:Factory: target $tgt" >> "$log/target.txt" ;;
        6) echo "RED: $devel (a rename passes --target)" >> "$log/target.txt"; rc=1 ;;
        *) echo "UNKNOWN: Factory's devel project for $pkg could not be read (devel-of.sh exit $drc): pass --target" >> "$log/target.txt"; rc=1 ;;
      esac
    fi
  fi
  if [ -n "$tgt" ]; then
    tprj=${tgt%%/*}; tpkg=$pkg; [[ $tgt == */* ]] && tpkg=${tgt#*/}
    if [ "$tprj" = "$own" ]; then
      echo "OK: a direct commit to $own, the target" >> "$log/target.txt"
    elif [ "$tprj" = "$base" ]; then
      echo "OK: the checkout is based on $base, the target is $tprj/$tpkg" >> "$log/target.txt"
    elif [ "$tprj" = openSUSE:Factory ]; then
      [ $drc -ge 0 ] || devel_of
      case $drc in
        0) if [ "${devel%%/*}" = "$base" ]; then
             echo "OK: a forward from Factory's devel project $base to $tprj/$tpkg" >> "$log/target.txt"
           else
             echo "RED: openSUSE:Factory takes $pkg from its devel project ${devel%%/*}; this checkout is based on $base" >> "$log/target.txt"; rc=1
           fi ;;
        3|4) echo "note: $pkg has no devel project in openSUSE:Factory; the checkout is based on $base" >> "$log/target.txt" ;;
        *) echo "UNKNOWN: Factory's devel project for $pkg could not be read (devel-of.sh exit $drc)" >> "$log/target.txt"; rc=1 ;;
      esac
    elif timeout 60 osc api "/source/$tprj/$tpkg/_meta" > /dev/null 2> "$log/target-meta.err"; then
      echo "RED: the checkout is based on $base/$bpkg, the SR goes to $tprj/$tpkg: its .changes history is not the target's — branch the target (osc branch $tprj $tpkg), or pass --target $base if $base really is where this goes" >> "$log/target.txt"; rc=1
    elif grep -q 'HTTP Error 404' "$log/target-meta.err"; then
      # a misspelt project would pass as a new package against the committed copy
      if timeout 60 osc api "/source/$tprj/_meta" > /dev/null 2> "$log/target-meta.err"; then
        echo "note: $tprj/$tpkg does not exist: a new package there" >> "$log/target.txt"
      elif grep -q 'HTTP Error 404' "$log/target-meta.err"; then
        echo "RED: the target project $tprj does not exist — check --target" >> "$log/target.txt"; rc=1
      else
        echo "UNKNOWN: cannot read $tprj/_meta: $(head -n 1 "$log/target-meta.err")" >> "$log/target.txt"; rc=1
      fi
    else
      echo "UNKNOWN: cannot read $tprj/$tpkg/_meta: $(head -n 1 "$log/target-meta.err")" >> "$log/target.txt"; rc=1
    fi
  fi
  show target $rc "$log/target.txt"
fi

# A fresh `osc mkpac` tracks nothing until `osc add`, and that tree's key is
# the same whatever the files hold: a review bound to it would bind nothing.
if [ -n "$stampf" ]; then
  py tracked . > "$log/tracked.txt"; show tracked $? "$log/tracked.txt"
fi

# A package never ships a file named like one of this skill's scripts: told to
# "run scripts/gate.sh in the checkout", agents wrote their own there, and one
# printed GREEN for a tree the real gate called red.
: > "$log/skill-scripts.txt"; rc=0
for f in "$HERE"/*.sh "$HERE"/*.py; do
  for c in "scripts/${f##*/}" "${f##*/}"; do
    [ ! -e "$c" ] || { echo "$c: named like the skill's own ${f##*/}: delete it, and run $f itself" >> "$log/skill-scripts.txt"; rc=1; }
  done
done
[ $rc -eq 0 ] && echo "OK: no file named like a skill script" >> "$log/skill-scripts.txt"
show skill-scripts $rc "$log/skill-scripts.txt"

if command -v /usr/lib/obs/service/source_validator >/dev/null 2>&1 || [ -x /usr/lib/obs/service/source_validator ]; then
  /usr/lib/obs/service/source_validator --outdir "$log/sv" > "$log/source_validator.txt" 2>&1; rc=$?
  # factory-auto (check_source.py) declines on these although the validator exits 0
  na=$(grep -E 'Attention.*not mentioned' "$log/source_validator.txt")
  [ -z "$na" ] || printf '%s\n' "${na//(W) /ERROR: factory-auto declines this: }" >> "$log/source_validator.txt"
  show source_validator $rc "$log/source_validator.txt"
  [ -z "$na" ] || [ $rc -ne 0 ] || red+=(source_validator)
else
  echo "## source_validator: SKIPPED (not installed)"; red+=(source_validator)
fi

# factory-auto's check_urls: every remote Source downloads and equals the
# committed file. The downloads go under /var/tmp, not the /tmp tmpfs.
if [ -x /usr/lib/obs/service/download_files ]; then
  if dl=$(mktemp -d -p /var/tmp "gate-dl-$pkg.XXXXXX"); then
    /usr/lib/obs/service/download_files --enforceupstream yes --enforcelocal yes --outdir "$dl" \
      > "$log/download_files.txt" 2>&1; rc=$?
    rm -rf "$dl"
  else
    echo "UNKNOWN: no scratch directory under /var/tmp" > "$log/download_files.txt"; rc=1
  fi
  [ $rc -eq 0 ] && echo "OK: every remote source downloads and matches the committed file" >> "$log/download_files.txt"
  show download_files $rc "$log/download_files.txt"
else
  echo "## download_files: SKIPPED (not installed)"; red+=(download_files)
fi

# The spec as rpm reads it. rpmspec -P expands every macro, comments included:
# opencode sr#1394137 was declined for "%prep" in a comment ("Unknown tag:
# %prep"), and codenomad's "# %{cargo_test} ..." comment ran cargo test. Parsing
# runs the spec's %(...) on this host: a checkout you are changing yourself only.
# A parse that stops for want of the build root (a macro a BuildRequires
# defines) is UNKNOWN, not red, and named on the verdict line.
hostnote=""
if command -v rpmspec >/dev/null 2>&1; then
  : > "$log/rpmspec.txt"; rc=0
  for s in "${specs[@]}"; do
    [ -e "$s" ] || continue
    py parse "$s" "$log" >> "$log/rpmspec.txt" || rc=1
  done
  [ $rc -eq 0 ] && ! grep -q '^UNKNOWN' "$log/rpmspec.txt" \
    && echo "OK: every spec parses in each build OBS runs, and no comment expands into a section name or commands" >> "$log/rpmspec.txt"
  # what this host could not judge goes on the verdict line
  while IFS= read -r l; do hostnote+="${hostnote:+; }$l"; done \
    < <(sed -n 's/^UNKNOWN: \(.*\): rpmspec -P stopped on what this host lacks: \(.*\) — the build log decides$/\1: \2/p' "$log/rpmspec.txt")
  show rpmspec $rc "$log/rpmspec.txt"
else
  echo "## rpmspec: SKIPPED (not installed)"; red+=(rpmspec)
fi

# %prep, unless a local build already ran it (--build-log): photocraft's patch
# no longer applied while the gate was GREEN, electron's %prep died on
# "unexpected EOF". %prep is the package's code (nodejs-electron runs a python
# script from its tarball, others ./autogen.sh or ./configure), so rpmbuild -bp
# runs in a bwrap sandbox: no network, only /usr and /etc of the host, $HOME
# empty, the checkout read-only, only the scratch directory under /var/tmp
# writable, no environment but PATH and HOME. Without a sandbox that starts it
# does not run at all. A pass is cached by the hash of the spec, the sources and
# rpm's version. What only the
# build root has (a missing BuildRequires' file, tool or module, a source a
# service makes, an arch the spec builds) leaves %prep UNKNOWN, not red.
sandbox() {   # sandbox <writable dir>: the bwrap arguments, in sbx
  # only /usr and /etc of the host, never / (core dumps, journals, other users'
  # files); run under env -i, so not even bwrap's own PID 1 holds the gate's env
  sbx=(--unshare-net --unshare-pid --unshare-ipc --die-with-parent --new-session
       --ro-bind /usr /usr --ro-bind /etc /etc --dev /dev --proc /proc
       --tmpfs /tmp --tmpfs /var/tmp --tmpfs /run --tmpfs "$HOME")
  local x
  for x in /bin /sbin /lib /lib64 /lib32 /libx32 /var/lib/rpm; do   # usrmerge links, the rpm db
    if [ -L "$x" ]; then sbx+=(--symlink "$(readlink "$x")" "$x")
    elif [ -d "$x" ]; then sbx+=(--ro-bind "$x" "$x"); fi
  done
  sbx+=(--ro-bind "$PWD" "$PWD" --bind "$1" "$1")
}
tmo=${GATE_PREP_TIMEOUT:-900}
if [ ${#buildlogs[@]} -gt 0 ]; then
  echo "note: not run: the --build-log build ran %prep" > "$log/prep.txt"; show prep 0 "$log/prep.txt"
elif ! command -v rpmbuild >/dev/null 2>&1; then
  echo "## prep: SKIPPED (no rpmbuild)"; red+=(prep)
elif ! command -v bwrap >/dev/null 2>&1 || ! { sandbox "$log"; perr=$(env -i PATH="$PATH" HOME="$HOME" bwrap "${sbx[@]}" true 2>&1); }; then
  perr=${perr:-bwrap is not installed}; why="no sandbox (${perr%%$'\n'*})"
  echo "UNKNOWN: %prep not run: $why" > "$log/prep.txt"; hostnote+="${hostnote:+; }%prep: $why"
  show prep 0 "$log/prep.txt"
else
  : > "$log/prep.txt"; rc=0
  # what %prep may unpack, against what /var/tmp has (shared with build roots)
  need=$(py need .); avail=$(df -Pk /var/tmp 2>/dev/null | awk 'NR == 2 { print $4 }')
  for s in "${specs[@]}"; do
    [ -e "$s" ] || continue
    if [ -e "$log/hostonly.$s" ]; then
      echo "UNKNOWN: %prep of $s not run: rpmspec -P stopped on this host" >> "$log/prep.txt"; continue
    elif command -v rpmspec >/dev/null 2>&1 && [ ! -e "$log/parsed.$s" ]; then
      echo "$s: not run: the spec does not parse" >> "$log/prep.txt"; rc=1; continue
    fi
    key=$(py prepkey "$s") || key=""
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/opensuse-packaging/prep/$key"
    if [ -n "$key" ] && [ -e "$cache" ]; then
      echo "OK: %prep of $s passed on these sources before (cached)" >> "$log/prep.txt"; continue
    fi
    if ! [[ $avail =~ ^[0-9]+$ ]] || [ "$avail" -lt "$need" ]; then
      why="not enough free space under /var/tmp (${avail:-?} KiB free, %prep may unpack $need KiB)"
      echo "UNKNOWN: %prep of $s not run: $why" >> "$log/prep.txt"; hostnote+="${hostnote:+; }$s: $why"; continue
    fi
    if ! bp=$(mktemp -d -p /var/tmp "gate-prep-$pkg.XXXXXX"); then
      bp=""; echo "UNKNOWN: no scratch directory under /var/tmp for %prep" >> "$log/prep.txt"; rc=1; continue
    fi
    rs="$PWD/$s"; [ ! -e "$log/rpm.$s" ] || rs="$log/rpm.$s"   # @BUILD_FLAVOR@ set as OBS sets it
    cp "$rs" "$bp/rpm.spec"; t0=$SECONDS
    # in the background, so a signal can kill its process group (the EXIT trap)
    sandbox "$bp"
    timeout -k 30 "$tmo" env -i PATH="$PATH" HOME="$HOME" bwrap "${sbx[@]}" rpmbuild -bp --nodeps --define "_topdir $bp" --define "_sourcedir $PWD" --define "_builddir $bp/BUILD" \
      "$bp/rpm.spec" > "$log/prep.$s.log" 2>&1 &
    prep_pid=$!; wait "$prep_pid"; prc=$?; prep_pid=""
    chmod -R u+w "$bp"; rm -rf "$bp"; bp=""
    if [ $prc -eq 0 ]; then
      echo "OK: %prep of $s ran in $((SECONDS - t0)) s" >> "$log/prep.txt"
      [ -z "$key" ] || { mkdir -p "${cache%/*}" && : > "$cache"; }
    elif [ $prc -eq 124 ] || [ $prc -eq 137 ]; then
      echo "UNKNOWN: %prep of $s did not finish in $tmo s: build it and pass --build-log" >> "$log/prep.txt"; rc=1
    elif why=$(py hostonly "$log/prep.$s.log" "$rs" | python3 -I "$HERE/_sanitize.py"); then
      echo "UNKNOWN: %prep of $s stopped on what this host lacks: $why — the build log decides (--build-log)" >> "$log/prep.txt"
      hostnote+="${hostnote:+; }$s: $why"
    else
      { echo "$s: %prep fails ($log/prep.$s.log):"; py excerpt "$log/prep.$s.log" | python3 -I "$HERE/_sanitize.py"; } >> "$log/prep.txt"; rc=1
    fi
  done
  show prep $rc "$log/prep.txt"
fi

# spec-cleaner as the skill runs it (core directive 3), in every build mode: the
# four policy flags and a fresh -o per spec. A diff is red unless it is named as
# a documented deviation; a run that fails is red, never "no diff". The version is
# printed because the references describe 1.3.0 and older ones rewrite differently.
if command -v spec-cleaner >/dev/null 2>&1; then
  : > "$log/spec-cleaner.diff"; : > "$log/spec-cleaner.defects"; rc=0; changed=0
  scv=$(spec-cleaner --version 2>/dev/null | head -n 1); scv=${scv:-unknown}
  echo "spec-cleaner $scv" > "$log/spec-cleaner.txt"
  [ "$scv" = 1.3.0 ] || echo "NOTE: spec-cleaner $scv is not the documented 1.3.0: a hunk only it makes may be a version difference (references/spec-cleaner.md \"Checking a spec file\")" >> "$log/spec-cleaner.txt"
  for s in "${specs[@]}"; do
    [ -e "$s" ] || continue
    if ! spec-cleaner --remove-groups --pkgconfig --perl --tex -o "$log/cleaned.$s" "$s" > "$log/spec-cleaner.err" 2>&1; then
      echo "UNKNOWN: spec-cleaner failed on $s: $(tail -n 1 "$log/spec-cleaner.err")" >> "$log/spec-cleaner.txt"; rc=1; continue
    fi
    diff -u "$s" "$log/cleaned.$s" >> "$log/spec-cleaner.diff"; d=$?
    # a hunk that breaks a spec rpm parses is spec-cleaner's bug (1.3.2 unbraces
    # %{cargo_build} -p foo into an option error: goose failed in staging)
    if [ $d -eq 1 ]; then changed=$((changed+1))
      [ ! -e "$log/parsed.$s" ] || py cleaned "$s" "$log/cleaned.$s" "$log" >> "$log/spec-cleaner.defects"
    elif [ $d -gt 1 ]; then
      echo "UNKNOWN: could not diff $s against its cleaned copy" >> "$log/spec-cleaner.txt"; rc=1; fi
  done
  lines=$(grep -c '^[-+][^-+]' "$log/spec-cleaner.diff")
  if [ $rc -eq 0 ] && [ $changed -eq 0 ]; then
    echo "OK: spec-cleaner leaves every spec as it is" >> "$log/spec-cleaner.txt"
  elif [ $rc -eq 0 ] && [ -n "$deviation" ]; then
    echo "DEVIATION: $lines changed line(s) kept on purpose — $deviation — the change review judges $log/spec-cleaner.diff" >> "$log/spec-cleaner.txt"
  elif [ $rc -eq 0 ]; then
    apply="apply it (spec-cleaner --remove-groups --pkgconfig --perl --tex -i <spec>)"
    [ ! -s "$log/spec-cleaner.defects" ] || apply="apply the hunks it gets right by hand, not with -i: a KNOWN DEFECT below breaks the spec"
    { echo "spec-cleaner would change $lines line(s) in $changed spec(s): $apply, or name the documented deviation with --cleaner-deviation REASON"
      grep '^[-+][^-+]' "$log/spec-cleaner.diff" | head -n 8; } >> "$log/spec-cleaner.txt"; rc=1
  fi
  cat "$log/spec-cleaner.defects" >> "$log/spec-cleaner.txt"
  show spec-cleaner $rc "$log/spec-cleaner.txt"
else
  echo "## spec-cleaner: SKIPPED (not installed)"; red+=(spec-cleaner)
fi

changes=( *.changes )
if [ -e "${changes[0]}" ]; then
  lint=(--entries "$entries")
  if me=$("$HERE/vc-identity.sh" 2> "$log/vc-identity.txt"); then lint+=(--author "$me"); else me=""; fi
  "$HERE/changes-lint.sh" "${lint[@]}" "${changes[@]}" > "$log/changes-lint.txt" 2>&1; rc=$?
  if [ -z "$me" ]; then
    { cat "$log/vc-identity.txt"; echo "author not checked: no identity from osc vc to compare against"; } \
      >> "$log/changes-lint.txt"
    [ $rc != 0 ] || rc=1
  fi
  show changes-lint $rc "$log/changes-lint.txt"
  guard=(); [ -n "$amend" ] && guard+=(--amend-top "$amend"); [ -n "$squash" ] && guard+=(--squash-mine "$squash")
  if [ -n "$tprj" ] && [ "$tprj" != "$own" ]; then
    # Against the target's copy, not the checkout's own committed one: a branch
    # commits its base, so its own copy is no evidence of what the target has.
    mkdir -p "$log/target-base"; : > "$log/changes-guard.txt"; rc=0
    for ch in "${changes[@]}"; do
      if timeout 60 osc cat "$tprj" "$tpkg" "$ch" > "$log/target-base/$ch" 2> "$log/target-base/$ch.err"; then
        echo "### $ch vs $tprj/$tpkg" >> "$log/changes-guard.txt"
        "$HERE/changes-guard.sh" "${guard[@]}" --base "$log/target-base/$ch" "$ch" >> "$log/changes-guard.txt" 2>&1 || rc=1
      elif grep -q 'HTTP Error 404' "$log/target-base/$ch.err"; then
        echo "### $ch: not in $tprj/$tpkg, vs the committed copy" >> "$log/changes-guard.txt"
        "$HERE/changes-guard.sh" "${guard[@]}" "$ch" >> "$log/changes-guard.txt" 2>&1 || rc=1
      else
        echo "UNKNOWN: osc cat $tprj $tpkg $ch failed: $(head -n 1 "$log/target-base/$ch.err")" >> "$log/changes-guard.txt"; rc=1
      fi
    done
  else
    "$HERE/changes-guard.sh" "${guard[@]}" "${changes[@]}" > "$log/changes-guard.txt" 2>&1; rc=$?
  fi
  show changes-guard $rc "$log/changes-guard.txt"
else
  echo "## changes-lint / changes-guard: no *.changes in $(pwd)"; red+=(changes)
fi

cp_args=(. --entries "$entries")
# The resolved target, except a direct commit to the checkout's own project:
# its entries count against the committed copy.
if [ -n "$tprj" ]; then [ "$tprj" = "$own" ] || cp_args+=(--target "$tprj/$tpkg")
elif [ -n "$target" ]; then cp_args+=(--target "$target"); fi
[ -n "$gitbase" ] && cp_args+=(--git-base "$gitbase")
"$HERE/changes-patches.sh" "${cp_args[@]}" > "$log/changes-patches.txt" 2>&1; rc=$?
show changes-patches $rc "$log/changes-patches.txt"

# Releases the bump crosses that the new entries never name, or describe again:
# a note, never red, as it reads free-text headings. cp_args minus --entries N.
timeout 120 "$HERE/changes-range.py" "${cp_args[0]}" "${cp_args[@]:3}" > "$log/changes-range.txt" 2>&1; rc=$?
printf '## changes-range: rc=%s (a note, never red)\n' "$rc"
if [ $full -eq 1 ]; then cat "$log/changes-range.txt"; else tail -n 12 "$log/changes-range.txt"; fi

# Each --build-log in any form build-summary.sh takes (a log, a build root, its
# name, repo-arch); the log file it read is the one checked and recorded.
blogs=()
if [ ${#buildlogs[@]} -gt 0 ]; then
  : > "$log/build-summary.short.txt"; rc=0
  for i in "${!buildlogs[@]}"; do
    out="$log/build-summary.txt"; [ "$i" = 0 ] || out="$log/build-summary.$i.txt"
    "$HERE/build-summary.sh" "${buildlogs[$i]}" > "$out" 2>&1 || rc=1
    { grep -m1 'VERDICT' "$out"; grep -A1 '^### rpmlint' "$out" | tail -1; } >> "$log/build-summary.short.txt"
    f=$(sed -n 's/^log: \(.*\)  (last written .*)$/\1/p' "$out" | head -n 1)
    if [ -n "$f" ] && [ -f "$f" ]; then blogs+=("$(realpath -- "$f")")
    else echo "RED: no build log behind --build-log ${buildlogs[$i]}: $(tail -n 1 "$out")" >> "$log/build-summary.short.txt"; rc=1; fi
  done
  if [ $rc -eq 0 ]; then py buildlogs . "${blogs[@]}" >> "$log/build-summary.short.txt" || rc=1; fi
  show build-summary $rc "$log/build-summary.short.txt"
fi

# One itemised # Legal-Review-Notice: per License: tag; several read as
# separate claims to the legal reviewer.
: > "$log/spec-notices.txt"; rc=0
for s in "${specs[@]}"; do
  [ -e "$s" ] || continue
  n=$(grep -c '^#[[:space:]]*Legal-Review-Notice:' "$s"); l=$(grep -ci '^License:' "$s")
  if [ "$n" -gt 1 ] && [ "$n" -gt "$l" ]; then
    echo "$s: $n Legal-Review-Notice blocks for $l License: tag(s) — merge them into one itemised block above the tag" >> "$log/spec-notices.txt"; rc=1
  fi
done
[ $rc -eq 0 ] && echo "OK: at most one Legal-Review-Notice per License: tag" >> "$log/spec-notices.txt"
show spec-notices $rc "$log/spec-notices.txt"

# One "# spec file for package" header per spec (rpmcrab shipped two), and
# every copyright holder the target's spec names besides SUSE survives: a
# format_spec_file or spec-cleaner run replaced a maintainer's own line (bluetui).
: > "$log/spec-header.txt"; rc=0
for s in "${specs[@]}"; do
  [ -e "$s" ] || continue
  n=$(grep -c '^# spec file for package' "$s")
  [ "$n" -le 1 ] || { echo "$s: $n '# spec file for package' headers — keep one" >> "$log/spec-header.txt"; rc=1; }
  b="$log/base.$s"; rm -f "$b"; from=""
  if [ -n "$tprj" ] && [ "$tprj" != "$own" ]; then
    if timeout 60 osc cat "$tprj" "$tpkg" "$s" > "$b" 2> "$b.err"; then from="$tprj/$tpkg"
    elif grep -q 'HTTP Error 404' "$b.err"; then rm -f "$b"
    else echo "UNKNOWN: osc cat $tprj $tpkg $s failed: $(head -n 1 "$b.err")" >> "$log/spec-header.txt"; rc=1; rm -f "$b"; fi
  elif [ -r ".osc/sources/$s" ]; then cp ".osc/sources/$s" "$b"; from="the committed copy"
  elif [ -r ".osc/$s" ]; then cp ".osc/$s" "$b"; from="the committed copy"
  elif ref=${gitbase:-$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)} && [ -n "$ref" ] \
       && git show "$ref:./$s" > "$b" 2>/dev/null; then from=$ref
  else rm -f "$b"; fi
  if [ -n "$from" ]; then
    if ! py copyright "$b" "$s" > "$log/copyright.txt"; then
      sed "s|^gone: |$s: a copyright line of $from is gone: |" "$log/copyright.txt" >> "$log/spec-header.txt"; rc=1
    fi
  else
    echo "note: $s: no target or committed copy to compare the copyright lines with" >> "$log/spec-header.txt"
  fi
done
[ $rc -eq 0 ] && echo "OK: one spec header, and every copyright holder of the target kept" >> "$log/spec-header.txt"
show spec-header $rc "$log/spec-header.txt"

# A spec comment says why in a line or two (references/specfile-guidelines.md
# "Spec file — general rules"): 9-line %check comments and 10-line prose
# Legal-Review-Notices were hard to review. Only the comment lines the change
# adds count, against the target's spec spec-header saved (all without one).
: > "$log/spec-comments.txt"; rc=0
for s in "${specs[@]}"; do
  [ -e "$s" ] || continue
  b=""; [ ! -e "$log/base.$s" ] || b="$log/base.$s"
  py comments "$s" "$b" >> "$log/spec-comments.txt" || rc=1
done
[ $rc -eq 0 ] && echo "OK: no comment block the change adds runs past 3 lines" >> "$log/spec-comments.txt"
show spec-comments $rc "$log/spec-comments.txt"

# A patch the change adds or edits carries a PATCH-* tag naming its file, and
# an UPSTREAM tag says where upstream has it (references/patches.md): a devel
# reviewer asked for them on sr#1385879, which no gate had checked. One the
# target ships unchanged only gets a note. Without the target's files (a new
# package, a failed lookup) every patch counts as changed.
: > "$log/patch-tags.txt"; rc=0; against=strict
if [ -n "$tprj" ] && [ "$tprj" != "$own" ]; then
  if timeout 60 osc api "/source/$tprj/$tpkg?expand=1" > "$log/target-files.xml" 2> "$log/target-files.err"; then
    against="$log/target-files.xml"
  elif ! grep -q 'HTTP Error 404' "$log/target-files.err"; then
    echo "note: cannot list $tprj/$tpkg ($(head -n 1 "$log/target-files.err")): every patch counts as changed" >> "$log/patch-tags.txt"
  fi
elif [ -n "$own" ] && [ "$tprj" = "$own" ] && [ -r .osc/_files ]; then
  against=.osc/_files                      # a direct commit: against the committed copy
elif [ -z "$own" ] && [ -n "$gitbase" ]; then
  against="git:$gitbase"                   # named by the caller: always the base
elif [ -z "$own" ] && ref=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) && [ -n "$ref" ]; then
  # a pushed fork or topic branch holds the change itself: it says nothing
  # about the target. The remote's default branch does (uncommitted edits).
  remote=$(git for-each-ref --format='%(upstream:remotename)' "$(git symbolic-ref -q HEAD)" 2>/dev/null)
  default=""; [ -z "$remote" ] || default=$(git symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null)
  if [ "$ref" != "$default" ] && git merge-base --is-ancestor HEAD "$ref" 2>/dev/null; then
    echo "note: $ref already holds HEAD: every patch counts as changed (a fork PR passes --git-base <target ref>)" >> "$log/patch-tags.txt"
  else
    against="git:$ref"
  fi
fi
for s in "${specs[@]}"; do
  [ -e "$s" ] || continue
  # the target's spec (spec-header saved it): a patch it tags correctly must stay tagged
  b=""; [ "$against" = strict ] || [ ! -e "$log/base.$s" ] || b="$log/base.$s"
  py tags "$s" "$against" "$b" >> "$log/patch-tags.raw" || rc=1
done
# notes first, so the red lines stay in the 12 lines show prints
{ grep '^note:' "$log/patch-tags.raw"; grep -v '^note:' "$log/patch-tags.raw"; } >> "$log/patch-tags.txt" 2>/dev/null
[ $rc -eq 0 ] && echo "OK: every changed patch tagged by name, every UPSTREAM tag with its reference" >> "$log/patch-tags.txt"
show patch-tags $rc "$log/patch-tags.txt"

# factory-auto declines a request whose .changes files all equal the target's
# ("No changelog"; sr#1394259 and 16 more: vendor strips filed with the
# .changes left as it was passed every gate). A tree that differs from the
# target needs a top entry the target lacks; when the target is Factory's
# devel project, a tree that differs from Factory needs one Factory lacks,
# since the change goes there next. With --amend-top or --squash-mine, an
# entry Factory lacks is the draft that describes the change.
if [ -e "${changes[0]}" ]; then
  : > "$log/changes-entry.txt"; rc=0; tlist=""; tlabel=""; tbase="$log/entry-target"; fbase="$log/entry-factory"
  rm -rf "$tbase" "$fbase"; mkdir -p "$tbase" "$fbase"
  if [ -n "$tprj" ] && [ "$tprj" != "$own" ]; then
    tlabel="$tprj/$tpkg"
    if [ "$against" = "$log/target-files.xml" ]; then
      tlist=$against
      for ch in "${changes[@]}"; do   # changes-guard fetched them
        if [ -s "$log/target-base/$ch" ]; then cp "$log/target-base/$ch" "$tbase/"
        elif ! grep -q 'HTTP Error 404' "$log/target-base/$ch.err" 2>/dev/null; then
          echo "UNKNOWN: no copy of $ch from $tlabel" >> "$log/changes-entry.txt"; rc=2; fi
      done
    elif grep -q 'HTTP Error 404' "$log/target-files.err" 2>/dev/null; then
      echo "note: $tlabel does not exist: a new package there, no entry to compare" >> "$log/changes-entry.txt"
    else
      echo "UNKNOWN: cannot list $tlabel" >> "$log/changes-entry.txt"; rc=2
    fi
  elif [ -n "$own" ] && [ "$tprj" = "$own" ] && [ -r .osc/_files ]; then
    tlabel="the committed copy"; tlist=.osc/_files
    for ch in "${changes[@]}"; do
      if [ -r ".osc/sources/$ch" ]; then cp ".osc/sources/$ch" "$tbase/"; elif [ -r ".osc/$ch" ]; then cp ".osc/$ch" "$tbase/"; fi
    done
  elif [ -z "$own" ] && [ "${against#git:}" != "$against" ]; then
    tlabel=${against#git:}; tlist=$against
    for ch in "${changes[@]}"; do git show "$tlabel:./$ch" > "$tbase/$ch" 2>/dev/null || rm -f "$tbase/$ch"; done
  else
    echo "note: no target or base ref to compare the files with" >> "$log/changes-entry.txt"
  fi
  fbound=0; fseen=0; fac=openSUSE:Factory/$pkg
  if [ $rc -eq 0 ] && [ -n "$own" ] && [ -n "$tprj" ] && [ "$tprj" != openSUSE:Factory ]; then
    [ $drc -ge 0 ] || devel_of
    [ $drc -eq 0 ] && [ "${devel%%/*}" = "$tprj" ] && fbound=1
    if [ $fbound = 1 ] || [ -n "$amend$squash" ]; then
      if timeout 60 osc api "/source/$fac?expand=1" > "$log/factory-files.xml" 2> "$log/factory-files.err"; then
        fseen=1
        for ch in "${changes[@]}"; do
          if timeout 60 osc cat openSUSE:Factory "$pkg" "$ch" > "$fbase/$ch" 2> "$log/factory-cat.err"; then :
          elif grep -q 'HTTP Error 404' "$log/factory-cat.err"; then rm -f "$fbase/$ch"
          else echo "UNKNOWN: osc cat openSUSE:Factory $pkg $ch failed: $(head -n 1 "$log/factory-cat.err")" >> "$log/changes-entry.txt"; rc=2; fi
        done
      elif grep -q 'HTTP Error 404' "$log/factory-files.err"; then
        fseen=2; fbound=0   # not in Factory: every entry is new there
      else
        echo "UNKNOWN: cannot list $fac: $(head -n 1 "$log/factory-files.err")" >> "$log/changes-entry.txt"; rc=2
      fi
    fi
  fi
  tofac=""; [ "$tprj" != openSUSE:Factory ] || tofac=1   # factory-auto declines it whatever the reason
  if [ $rc -eq 0 ] && [ -n "$tlist" ]; then
    ebase=$tbase; elabel=$tlabel
    [ -z "$amend$squash" ] || [ $fseen = 0 ] || { ebase=$fbase; elabel=$fac; }
    ENTRY_FACTORY=$tofac py entry "$tlabel" "$tlist" "$elabel" "$ebase" "${changes[@]}" >> "$log/changes-entry.txt"; erc=$?
    [ $erc -eq 0 ] || rc=$erc
  fi
  if [ $rc -eq 0 ] && [ $fbound = 1 ] && [ $fseen = 1 ]; then
    py entry "$fac" "$log/factory-files.xml" "$fac" "$fbase" "${changes[@]}" >> "$log/changes-entry.txt"; erc=$?
    [ $erc -eq 0 ] || rc=$erc
  fi
  # rc 1: an entry is missing, which --no-entry may waive but for Factory; 2: a lookup failed, which it never does
  if [ $rc -eq 1 ] && [ -n "$noentry" ] && [ -n "$tofac" ]; then
    echo "NO ENTRY refused: openSUSE:Factory is the target, and factory-auto declines a request with no new entry (\"No changelog\") whatever the reason" >> "$log/changes-entry.txt"
  elif [ $rc -eq 1 ] && [ -n "$noentry" ]; then
    echo "NO ENTRY: $noentry — the change review judges it" >> "$log/changes-entry.txt"; rc=0
  fi
  show changes-entry $rc "$log/changes-entry.txt"
fi

# Prebuilt binaries in any file the checkout carries, inside archives too:
# "build-time only" still ships them in the SRPM (references/specfile-guidelines.md
# "Spec file — general rules"). nodejs-electron 44.10.0 kept CIPD Go, esbuild and
# rolldown binaries that way, and the change review passed them. With --rpms, one
# the built RPMs carry is red whatever its exception says (opencode 2.2.5 called
# its shipped pty helper a bootstrap).
sb_args=(.); [ -z "$rpms" ] || sb_args+=(--rpms "$rpms")
"$HERE/source-binaries.py" "${sb_args[@]}" > "$log/source-binaries.txt" 2>&1; rc=$?
[ -n "$rpms" ] || echo "note: no --rpms DIR: the built RPMs were not checked for a prebuilt binary they ship (the build root's RPMS, or osc getbinaries -d DIR, then --obs-build --rpms DIR)" >> "$log/source-binaries.txt"
show source-binaries $rc "$log/source-binaries.txt"
# a bootstrap's static library whose code ships: the review's to settle, so on the verdict line
emb=$(grep -c '^EMBEDS?' "$log/source-binaries.txt"); review=""
[ "$emb" = 0 ] || review=", $emb EMBEDS? line(s) for the review ($log/source-binaries.txt)"

[ -z "$hostnote" ] || hostnote=$(printf '%s' "$hostnote" | python3 -I "$HERE/_sanitize.py")
if [ ${#red[@]} -eq 0 ]; then
  t=""; ne=""; grep -q '^NO ENTRY' "$log/changes-entry.txt" 2>/dev/null && ne=$noentry
  if [ -n "$stampf" ]; then
    if t=$(GATE_NO_ENTRY=$ne py stamp "$stampf" . "$own" "$pkg" "${tprj:+$tprj/$tpkg}" "$rpms" "${blogs[@]}"); then
      echo "${t#*$'\n'}"; t=" for tree ${t:0:12}"
    else t=" (no tree stamped: no .osc/_files)"; fi
  fi
  [ -z "$ne" ] || t+=", no new .changes entry: $ne"
  [ -z "$hostnote" ] || t+=", not proven on this host: $hostnote"
  t+=$review
  if [ -n "$deviation" ] && grep -q '^DEVIATION' "$log/spec-cleaner.txt" 2>/dev/null; then
    echo "VERDICT: GREEN — all gates passed$t, spec-cleaner deviation: $deviation (diff: $log/spec-cleaner.diff; full output: $log/)"; exit 0
  fi
  echo "VERDICT: GREEN — all gates passed$t (full output: $log/)"; exit 0
fi
[ -z "$stampf" ] || rm -f "$stampf"
echo "VERDICT: RED — ${red[*]}${hostnote:+, not proven on this host: $hostnote}$review (full output: $log/)"; exit 1
