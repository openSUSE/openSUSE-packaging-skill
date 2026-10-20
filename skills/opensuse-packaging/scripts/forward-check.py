#!/usr/bin/env python3
"""Before any Factory forward: has the devel project's state already reached
Factory, or a request on its way there, and who forwards it?

Devel maintainers forward what they accept themselves (129 of the 132 SRs other
maintainers accepted in one measured week got their own Factory forward), so an
accepted devel request is not a forward still to file. This asks Factory:

  forward-check.py <devel-project> <package>    one package
  forward-check.py --mine [--since YYYY-MM-DD]  every submit request of yours
                                                accepted into a project that is
                                                neither openSUSE:* nor home:
                                                since DATE (default: 14 days ago)
  --user U   OBS account (default: `osc whois`)

A request to Factory is the forward only when it comes from the devel
project; it is current when its source revision holds the devel package's
current files (name and md5, expanded), stale otherwise. One line per package, as
each is decided (about 2 s each: run --mine in the background), the count last:
  FORWARDED <id> by <who> <state> current|stale
  MINE-OPEN <id> <state> current|stale   your own forward is open
  IN-FACTORY                   openSUSE:Factory holds the devel package's files
  MINE-DECLINED <id> by <who>: <reason>
      your forward of the current sources was declined: fix it, then file
      again superseding it, osc sr ... -s <id>
  DECLINED <id> by <who>: <reason>
      someone else's forward of the current sources was declined: report it
  FOREIGN-DECLINED <id> by <who>: <reason>
      an older declined request from the devel project, someone else's, which
      your osc sr would offer to supersede: ask, never supersede it
  NOT-LANDED <id> <state>      your devel request is not accepted yet
  DEVEL-DECLINED <id> by <who>: <reason>   your devel request was declined
  GONE                         the package is no longer in the devel project
  WRONG-DEVEL                  openSUSE:Factory develops it in another project
  NEW-IN-FACTORY               yours, but not in openSUSE:Factory yet: ask
                               before submitting a new package
  DUE                          yours to forward (autoforward-gate.sh ELIGIBLE)
  MAINTAINERS                  not yours to forward: the devel maintainers do
  UNKNOWN                      a lookup failed; never read as done
File a forward only on DUE, or on MINE-DECLINED once the decline is fixed.

Exit: 0 nothing to do; 4 something needs you (a stale forward, MINE-DECLINED,
DECLINED, FOREIGN-DECLINED, DEVEL-DECLINED, WRONG-DEVEL, NEW-IN-FACTORY or
DUE); 3 a lookup failed (wins over 4); 2 usage

Requests to an scmsync devel project's Gitea repository are not OBS requests
and are not covered.
"""

import argparse
import datetime
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _sanitize  # escape/Unicode-smuggling filter for third-party text

HERE = os.path.dirname(os.path.abspath(__file__))
FACTORY = "openSUSE:Factory"
TIMEOUT = 60
CLEAN = {"FORWARDED", "MINE-OPEN", "IN-FACTORY", "NOT-LANDED", "GONE", "MAINTAINERS"}


class Lookup(Exception):
    """An osc call failed: the verdict is UNKNOWN, never a guess. args[1]
    tells a 404 apart."""


def osc(*args):
    try:
        r = subprocess.run(
            ["osc", *args], capture_output=True, text=True, timeout=TIMEOUT
        )
    except subprocess.TimeoutExpired:
        raise Lookup(f"osc {args[0]} timed out after {TIMEOUT}s", False)
    except FileNotFoundError:
        raise Lookup("osc: command not found", False)
    if r.returncode != 0:
        err = (r.stderr or "").strip()
        raise Lookup(f"osc {' '.join(args)}: {err[:200]}", "HTTP Error 404" in err)
    return r.stdout


def clean(text, width=None):
    s = " ".join(_sanitize.sanitize(text or "").split())
    return s if width is None or len(s) <= width else s[: width - 1] + "…"


def search(match):
    """The submit requests an xpath match finds, as dicts."""
    out = osc("api", "/search/request?match=" + urllib.parse.quote(match, safe="@/'"))
    try:
        root = ET.fromstring(out)
    except ET.ParseError as e:
        raise Lookup(f"unreadable request search: {e}", False)
    if root.tag != "collection":
        raise Lookup(f"request search answered <{root.tag}>, not a collection", False)
    reqs = []
    for r in root.findall("request"):
        st = r.find("state")
        if st is None:
            continue
        acts = []
        for a in r.findall("action"):
            src, tgt = a.find("source"), a.find("target")
            if a.get("type") == "submit" and src is not None and tgt is not None:
                acts.append(
                    (
                        src.get("project") or "",
                        src.get("rev") or "",
                        tgt.get("project") or "",
                        tgt.get("package") or "",
                    )
                )
        reqs.append(
            {
                "id": int(r.get("id")),
                "creator": r.get("creator") or "",
                "state": st.get("name") or "",
                "who": st.get("who") or "",
                "when": st.get("when") or "",
                "created": st.get("created") or "",
                "comment": st.findtext("comment") or "",
                "actions": acts,
            }
        )
    return reqs


def tree(prj, pkg, rev=None):
    """(srcmd5, files) of prj/pkg expanded (at revision rev), files being its
    (name, md5) pairs; None when absent. Sources are equal when their files
    are: a linked devel package's srcmd5 also covers the link, so it differs
    from Factory's for the same files."""
    path = f"/source/{prj}/{pkg}?expand=1" + (f"&rev={rev}" if rev else "")
    try:
        out = osc("api", path)
    except Lookup as e:
        if e.args[1]:
            return None
        raise
    try:
        root = ET.fromstring(out)
    except ET.ParseError as e:
        raise Lookup(f"unreadable {path}: {e}", False)
    files = frozenset((e.get("name"), e.get("md5")) for e in root.findall("entry"))
    return root.get("srcmd5"), files


def last_change(prj, pkg):
    """The day prj/pkg's latest revision was committed (YYYY-MM-DD)."""
    out = osc("api", f"/source/{prj}/{pkg}/_history?limit=1")
    try:
        when = ET.fromstring(out).findtext("revision/time")
        return datetime.datetime.fromtimestamp(
            int(when), datetime.timezone.utc
        ).strftime("%Y-%m-%d")
    except (ET.ParseError, TypeError, ValueError) as e:
        raise Lookup(f"unreadable /source/{prj}/{pkg}/_history: {e}", False)


class Package:
    """One devel package and what Factory holds for it."""

    def __init__(self, prj, pkg, user, own):
        self.prj, self.pkg, self.user, self.own = prj, pkg, user, own
        self.devel = None
        self.factory = None
        self.older = []  # declined forwards of older sources, for the role step
        self.revs = {}

    def carries(self, rev):
        """Does a forward of source revision rev (a srcmd5, or the revision
        number older requests carry) hold the devel package's current files?"""
        if not rev:
            return False
        if rev == self.devel[0]:
            return True
        if rev not in self.revs:
            self.revs[rev] = tree(self.prj, self.pkg, rev)
        return bool(self.revs[rev]) and self.revs[rev][1] == self.devel[1]

    def factory_devel(self):
        """openSUSE:Factory's devel project for the package when it is another
        one than prj (and its package is no _link to prj/pkg), else None."""
        try:
            r = subprocess.run(
                ["bash", os.path.join(HERE, "devel-of.sh"), self.pkg],
                capture_output=True,
                text=True,
                timeout=2 * TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise Lookup("devel-of.sh timed out", False)
        if r.returncode in (3, 4):  # not in Factory, or no devel project named
            return None
        if r.returncode != 0:
            raise Lookup(f"devel-of.sh {self.pkg}: exit {r.returncode}", False)
        dprj, _, dpkg = r.stdout.strip().partition("/")
        if dprj == self.prj:
            return None
        try:
            link = ET.fromstring(osc("api", f"/source/{dprj}/{dpkg}/_link"))
        except Lookup as e:
            if e.args[1]:
                return dprj
            raise
        except ET.ParseError as e:
            raise Lookup(f"unreadable /source/{dprj}/{dpkg}/_link: {e}", False)
        if (
            link.get("project") == self.prj
            and (link.get("package") or dpkg) == self.pkg
        ):
            return None
        return dprj

    def forwards(self, states):
        """Factory submit requests for the package from the devel project."""
        reqs = search(
            f"action/target/@project='{FACTORY}' and action/target/@package='{self.pkg}' "
            f"and action/@type='submit' and ({states})"
        )
        out = []
        for r in reqs:
            for src, rev, tgt, pkg in r["actions"]:
                if src == self.prj and tgt == FACTORY and pkg == self.pkg:
                    out.append(dict(r, rev=rev))
                    break
        return sorted(out, key=lambda r: r["id"], reverse=True)

    def decide(self):
        """(verdict, detail), or None when only the role step can decide."""
        own = self.own
        if own and own["state"] in ("new", "review"):
            return "NOT-LANDED", f"{own['id']} {own['state']}"
        if own and own["state"] == "declined":
            return (
                "DEVEL-DECLINED",
                f"{own['id']} by {clean(own['who'])}: {clean(own['comment'], 120)}",
            )
        wrong = self.factory_devel()
        if wrong:
            return "WRONG-DEVEL", f"openSUSE:Factory develops it in {wrong}"
        self.devel = tree(self.prj, self.pkg)
        if self.devel is None:
            return "GONE", f"no longer in {self.prj}"
        reqs = self.forwards(
            "state/@name='new' or state/@name='review' or state/@name='declined'"
        )
        for r in reqs:
            if r["state"] in ("new", "review"):
                age = "current" if self.carries(r["rev"]) else "stale"
                if r["creator"] == self.user:
                    return "MINE-OPEN", f"{r['id']} {r['state']} {age}"
                who = clean(r["creator"])
                return "FORWARDED", f"{r['id']} by {who} {r['state']} {age}"
        self.factory = tree(FACTORY, self.pkg)
        if self.factory and self.factory[1] == self.devel[1]:
            return "IN-FACTORY", ""
        if self.factory is not None:
            since = last_change(self.prj, self.pkg)
            for r in self.forwards(
                f"state/@name='accepted' and state/@when>='{since}'"
            ):
                if self.carries(r["rev"]):
                    who = clean(r["creator"])
                    return "FORWARDED", f"{r['id']} by {who} accepted current"
        for r in reqs:
            if r["state"] != "declined":
                continue
            why = f"{r['id']} by {clean(r['who'])}: {clean(r['comment'], 120)}"
            if self.carries(r["rev"]):
                mine = r["creator"] == self.user
                return ("MINE-DECLINED" if mine else "DECLINED"), why
            self.older.append((r, why))
        return None

    def role(self, verdict):
        """The verdict once autoforward-gate.sh has decided the role."""
        if verdict == "WRONG-DEVEL":
            return verdict, ""
        if verdict in ("BLOCKED", "NOT_YOURS"):
            return "MAINTAINERS", "reviewer role set" if verdict == "BLOCKED" else ""
        if verdict != "ELIGIBLE":
            return "UNKNOWN", f"autoforward-gate.sh: {verdict or 'no answer'}"
        if self.factory is None:
            return "NEW-IN-FACTORY", "ask before submitting a new package"
        theirs = [w for r, w in self.older if r["creator"] != self.user]
        if theirs:
            return "FOREIGN-DECLINED", theirs[0]
        mine = [r for r, _ in self.older if r["creator"] == self.user]
        return "DUE", f"supersede {mine[0]['id']} with -s" if mine else ""


def gate(packages, user):
    """{(prj, pkg): verdict} from autoforward-gate.sh --batch, in up to six
    parallel batches; a batch that fails leaves its rows out (UNKNOWN)."""
    chunks = [packages[i::6] for i in range(min(6, len(packages)))]

    def run(chunk):
        with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as fh:
            fh.write("".join(f"{p.prj}\t{p.pkg}\n" for p in chunk))
        try:
            r = subprocess.run(
                [
                    "bash",
                    os.path.join(HERE, "autoforward-gate.sh"),
                    "--batch",
                    fh.name,
                    "--user",
                    user,
                ],
                capture_output=True,
                text=True,
                timeout=len(chunk) * 4 * TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            return {}
        finally:
            os.unlink(fh.name)
        rows = {}
        for line in r.stdout.splitlines():
            name, _, rest = line.partition("\t")
            prj, _, pkg = name.partition("/")
            rows[(prj, pkg)] = rest.split("\t", 1)[0]
        return rows

    verdicts = {}
    with ThreadPoolExecutor(max_workers=6) as ex:
        for rows in ex.map(run, chunks):
            verdicts.update(rows)
    return verdicts


def mine_since(user, since):
    """{(project, package): None} for your requests accepted into a devel
    project since DATE."""
    found = {}
    for r in search(
        f"state/@name='accepted' and @creator='{user}' and action/@type='submit' "
        f"and state/@when>='{since}'"
    ):
        for _, _, prj, pkg in r["actions"]:
            if prj and not prj.startswith(("openSUSE:", "home:")):
                found[(prj, pkg)] = None
    return found


def one(prj, pkg, user):
    """Your latest request to prj/pkg not accepted after it was filed, if any."""
    reqs = search(
        f"@creator='{user}' and action/@type='submit' and "
        f"action/target/@project='{prj}' and action/target/@package='{pkg}'"
    )
    landed = max((r["when"] for r in reqs if r["state"] == "accepted"), default="")
    pending = [
        r
        for r in reqs
        if r["state"] in ("new", "review", "declined") and r["created"] > landed
    ]
    return max(pending, key=lambda r: r["id"]) if pending else None


def main():
    ap = argparse.ArgumentParser(
        allow_abbrev=False,
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("project", nargs="?")
    ap.add_argument("package", nargs="?")
    ap.add_argument("--mine", action="store_true")
    ap.add_argument("--since")
    ap.add_argument("--user")
    a = ap.parse_args()
    if a.mine == bool(a.project) or bool(a.project) != bool(a.package):
        ap.error("give <devel-project> <package>, or --mine")
    if a.since and (not a.mine or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", a.since)):
        ap.error("--since YYYY-MM-DD goes with --mine")
    user = a.user
    if not user:
        try:
            user = osc("whois").split(":", 1)[0].strip()
        except Lookup as e:
            print(
                f"cannot determine account ({e.args[0]}); pass --user", file=sys.stderr
            )
            return 2
    try:
        if a.mine:
            since = a.since or (
                datetime.datetime.now(datetime.timezone.utc)
                - datetime.timedelta(days=14)
            ).strftime("%Y-%m-%d")
            todo = mine_since(user, since)
        else:
            todo = {(a.project, a.package): one(a.project, a.package, user)}
    except Lookup as e:
        print(f"UNKNOWN: cannot list the requests ({e.args[0]})", file=sys.stderr)
        return 3

    counts, stale = {}, False

    def emit(p, verdict, detail):
        nonlocal stale
        counts[verdict] = counts.get(verdict, 0) + 1
        stale |= verdict in ("FORWARDED", "MINE-OPEN") and detail.endswith(" stale")
        print(f"{p.prj}/{p.pkg}  {verdict} {detail}".rstrip(), flush=True)

    def decide(p):
        try:
            return p, p.decide()
        except Lookup as e:
            return p, ("UNKNOWN", clean(str(e.args[0]), 160))

    packages = [
        Package(prj, pkg, user, own) for (prj, pkg), own in sorted(todo.items())
    ]
    undecided = []
    with ThreadPoolExecutor(max_workers=10) as ex:
        for fut in as_completed([ex.submit(decide, p) for p in packages]):
            p, result = fut.result()
            if result is None:
                undecided.append(p)
            else:
                emit(p, *result)
    if undecided:
        roles = gate(undecided, user)
        for p in undecided:
            emit(p, *p.role(roles.get((p.prj, p.pkg), "")))
    print(
        f"# {len(packages)} package(s): "
        + (", ".join(f"{n} {v}" for v, n in sorted(counts.items())) or "none")
    )
    if "UNKNOWN" in counts:
        return 3
    return 4 if stale or set(counts) - CLEAN else 0


if __name__ == "__main__":
    sys.exit(main())
