#!/usr/bin/env python3
"""Wait for ONE OBS build or request to settle, in one bounded call, instead of
a sleep loop.

build    PKG and its multibuild flavors on the repos/arches gate.sh
         --obs-build judges (Tumbleweed/Factory and Leap 16 on x86_64 and
         aarch64; --repos/--arches REGEX widen it, --all takes every one,
         --repo/--arch name exactly what to wait on), judged only on a build of
         the CURRENT expanded sources: a result of an older srcmd5 reads
         pending, never green or failed. A linked package has no typed leaf
         for its expanded srcmd5, so a job of one counts as current when it
         started after the last commit of the link (and of its target, when
         the link follows it); when that cannot be told, the verdict is no
         answer, never green. In that default scope a repo/arch the
         link origin disables is not waited on (one it excludes is: the change
         may edit ExclusiveArch), and --target openSUSE:Factory leaves Leap 16
         out, as gate.sh does for a Factory target
request  request ID, by its request number

It opens OBS's public event stream first (server-sent events from
rabbit.opensuse.org, anonymous and read-only) and asks geectl second, so nothing
lands in between. An event only wakes it to ask geectl again: geectl gives every
verdict. It also asks geectl every --recheck seconds (default 300; 30 when
polling), after every reconnect and once more at --timeout (default 80), since
unresolvable, broken, excluded and disabled send no event and a dropped stream
replays nothing. With the stream unreachable or dropping repeatedly it polls
geectl and says so on stderr; a stalled stream never holds it past --timeout.
A call takes about --timeout plus that last geectl check; --timeout 0 asks geectl
once. Prints one VERDICT line. Read-only; geectl authenticates from its
configured credentials, no credential file is read.

A build with nothing green yet whose only unfinished repos/arches are
"scheduled" is QUEUED-STUCK once 30 minutes have passed since both the last
commit and the last build job that ended in each such repo/arch (a package
scheduled because its dependency just built is not stuck): those arches wait
for a worker, which no wait shortens. Report it and come back later; it is
not green.

In the default scope, a build with nothing green yet whose only unfinished
repos/arches are "blocked", with the link origin blocked at the same repo/arch
too, is BLOCKED-UPSTREAM: a dependency rebuild outside this change holds both.
Report it and come back later; it is not green either.

Exit:
  0 = one judged build green from the current sources, the still-building remainder and any red the link origin has too named; request accepted
  1 = still pending at --timeout, nothing green yet, a source service still running included: repeat the same call
  2 = settled failure: a NEW failed/unresolvable/broken/unknown code in the default scope, any red with --all, --repo or --arch, or nothing to build (with --all, --repo or --arch); request declined/revoked/superseded/deleted
  3 = no answer: usage, a geectl lookup failed, was empty or did not parse, or no repo/arch in scope
  4 = QUEUED-STUCK: nothing green yet, only scheduled arches left, 30+ min after the last commit and their repo's last finished job; not green, check back later
  5 = BLOCKED-UPSTREAM: nothing green yet, only blocked arches left, blocked in the link origin too; not green, check back later
"""

import argparse
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.request

sys.pycache_prefix = "/dev/null/opensuse-packaging"  # no __pycache__ beside it is read
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _obs_scope as scope  # noqa: E402  # the repos/arches gate.sh --obs-build judges
import _sanitize  # noqa: E402  # escape/Unicode-smuggling filter for third-party text

FEED_URL = "https://rabbit.opensuse.org/cgi-bin/webevents.py"
FEED_OPEN = 15  # seconds for the stream to answer
FEED_IDLE = 60  # this long silent, the stream is dead; 15 s gaps are normal
FEED_PRIME = 5  # a first event shows the server is subscribed
FEED_DROPS = 3  # losses per call before polling instead
BUILD_TOPICS = {
    "opensuse.obs.package.build_success",
    "opensuse.obs.package.build_fail",
    "opensuse.obs.package.build_unchanged",
    "opensuse.obs.repo.build_finished",
}
GEectl_TIMEOUT = 30
POLL = 30  # --recheck default without the feed
GAP = 2  # coalesces an event burst (every arch finishing at once) into one check
STUCK = 30 * 60  # seconds without a commit or a finished job before scheduled is stuck
SERVICE = "the source service is still running"

GREEN = {"succeeded"}
RED = {"unresolvable", "broken"}
PRE = {
    "failed",
    "unresolvable",
    "broken",
}  # gate.sh REDS: a red the link origin has too is PRE-EXISTING, not this change's failure
SKIP = {"disabled", "excluded"}
PENDING = {"scheduled", "building", "blocked", "finished", "signing", "dispatching"}


class Lookup(Exception):
    """A geectl answer we could not get or read: exit 3, never a verdict."""


class ServiceRunning(Lookup):
    """OBS refused a source listing while its source service runs: pending
    where a source listing is read, exit 3 like any Lookup elsewhere."""


class FeedLost(Exception):
    pass


def note(msg):
    sys.stderr.write(f"obs-wait: {msg}\n")


def clip(text, n=120):
    text = " ".join(_sanitize.sanitize(text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def geectl(args):
    """A geectl JSON read, parsed. A failure, a timeout or an unparseable
    answer is a Lookup (exit 3), never an empty answer."""
    what = " ".join(args[:2])
    try:
        r = subprocess.run(
            ["geectl"] + args, capture_output=True, text=True, timeout=GEectl_TIMEOUT
        )
    except subprocess.TimeoutExpired:
        raise Lookup(f"geectl {what} timed out after {GEectl_TIMEOUT}s")
    except FileNotFoundError:
        raise Lookup("geectl: command not found")
    if r.returncode != 0:
        last = (r.stderr.strip().splitlines() or ["no error text"])[-1]
        # the backend's own words while it runs the package's _service
        err = ServiceRunning if "service in progress" in r.stderr else Lookup
        raise err(f"geectl {what} failed: {clip(last)}")
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError as e:
        raise Lookup(f"unparseable geectl {what} answer: {e}")


# ---------------------------------------------------------------- build


def last_job(t, repo, arch, name):
    """The last build job of name on repo/arch (its job-history entry),
    None when there is none. Not the package log: an unchanged rebuild
    adds no entry there."""
    payload = geectl(
        ["build", "job-history", t.prj, repo, arch, "--package", name, "--limit", "1"]
    )
    entries = payload.get("entries", [])
    return entries[0] if entries else None


def job_built_current(t, job):
    """Whether the job built the current sources: True, False, or None when
    that cannot be told. A plain package compares the job's srcmd5 with the
    package log's; a job with no srcmd5 recorded counts as current, as a
    failure with no job history does. A linked package has no typed leaf
    for its expanded srcmd5, so the job counts as current when it started
    after the newest commit its expanded sources can depend on (see
    listing): a job that started earlier may have built older sources."""
    if job is None:
        return None
    got = job.get("srcmd5", "")
    if t.srcmd5 and got:
        return got == t.srcmd5
    if not t.linked:
        return True
    try:
        started = int(job.get("starttime") or 0)
    except (TypeError, ValueError):
        return None
    if not started or t.link_bound is None:
        return None
    return started > t.link_bound


def last_commit(t):
    """When prj/pkg's latest revision was committed (epoch seconds)."""
    payload = geectl(["remote", "package-log", t.prj, t.pkg, "--limit", "1"])
    entries = payload.get("entries", [])
    try:
        return int(entries[0].get("time"))
    except (IndexError, TypeError, ValueError):
        raise Lookup(f"no commit time in the {t.prj}/{t.pkg} package log")


def last_job_end(t, repo, arch):
    """When the newest build job of any package in repo/arch ended (epoch
    seconds), 0 when there is none: a dependency that just built is why a
    package turns from blocked to scheduled."""
    payload = geectl(["build", "job-history", t.prj, repo, arch, "--limit", "1"])
    entries = payload.get("entries", [])
    try:
        return int(entries[0].get("endtime") or 0) if entries else 0
    except ValueError:
        raise Lookup(f"unreadable end time in the {repo}/{arch} job history")


def summary(items, show=4):
    """(state, label, detail) items as "state: labels (detail); ..." with at
    most `show` labels per state: a project can have hundreds of repos."""
    groups = {}
    for state, label, why in items:
        groups.setdefault(state, []).append((label, why))
    parts = []
    for state, xs in groups.items():
        labels = ", ".join(x[0] for x in xs[:show])
        labels += f" +{len(xs) - show} more" if len(xs) > show else ""
        whys = list(dict.fromkeys(x[1] for x in xs if x[1]))
        why = f" ({'e.g. ' if len(whys) > 1 else ''}{whys[0]})" if whys else ""
        parts.append(f"{state}: {labels}{why}")
    return "; ".join(parts)


def build_check(t):
    notes = []
    code, line = build_verdict(t, notes)
    if notes:
        line += f" (not judged: {summary(notes, 3)})"
    return code, line


def out_of_scope(who):
    return (
        f"no repo/arch of {who} in scope builds it (Tumbleweed, or Leap 16 unless "
        "--target is openSUSE:Factory, on x86_64 or aarch64): --repos/--arches "
        "REGEX widen it, --all takes every one"
    )


def listing(t):
    """The current sources, from the latest package-log entry: {srcmd5,
    linked, bound}. srcmd5 is the log's, which is the expanded revision's
    for a plain package. For a linked package the log's srcmd5 is the
    link's own, not the expanded one no typed leaf reports, so srcmd5 is
    None and bound is the newest commit time the expanded sources can
    depend on: the link's own last commit, or the target's too when the
    link follows it (no rev pin in its _link). bound is None when that
    cannot be told."""
    payload = geectl(["remote", "package-log", t.prj, t.pkg, "--limit", "1"])
    entries = payload.get("entries", [])
    if not entries or not entries[0].get("srcmd5"):
        raise Lookup(f"no srcmd5 in the {t.prj}/{t.pkg} package log")
    out = {"srcmd5": entries[0]["srcmd5"], "linked": False, "bound": None}
    try:
        link_time = int(entries[0].get("time") or 0)
    except (TypeError, ValueError):
        link_time = 0
    origin = scope.origin(geectl(["remote", "link-target", t.prj, t.pkg]), t.pkg)
    if not origin:
        return out
    out["linked"] = True
    out["srcmd5"] = None
    pin = None
    # remote cat is a text read, not a JSON one: run it directly
    try:
        r = subprocess.run(
            ["geectl", "remote", "cat", t.prj, t.pkg, "_link", "--format", "text"],
            capture_output=True,
            text=True,
            timeout=GEectl_TIMEOUT,
        )
        text = r.stdout if r.returncode == 0 else None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        text = None
    if text is not None:
        m = re.search(r"<link\b[^>]*>", text)
        if m:
            mm = re.search(r'\brev="([^"]*)"', m.group(0))
            pin = mm.group(1) if mm else None
    if pin:
        out["bound"] = link_time or None
        return out
    tgt = geectl(["remote", "package-log", origin[0], origin[1], "--limit", "1"])
    tentries = tgt.get("entries", [])
    try:
        target_time = int(tentries[0].get("time") or 0) if tentries else 0
    except (TypeError, ValueError):
        target_time = 0
    bound = max(link_time, target_time)
    out["bound"] = bound or None
    return out


def build_verdict(t, notes):
    cmd = ["build", "results", t.prj, "--package", t.pkg, "--multibuild"]
    cmd += ["--repository", t.repo] if t.repo else []
    cmd += ["--arch", t.arch] if t.arch else []
    payload = geectl(cmd)
    rows, dirty_repo = [], False
    for res in payload.get("results", []):
        repo, arch = res.get("repository") or "", res.get("arch") or ""
        inside = not t.scoped or scope.judged(
            t.prj, repo, arch, t.leap, t.repos, t.arches
        )
        dirty = res.get("dirty") is True
        dirty_repo |= dirty and inside
        for s in res.get("statuses", []):
            name = s.get("package", "")
            if name == t.pkg or name.startswith(t.pkg + ":"):
                label = f"{repo}/{arch}" + name[len(t.pkg) :]
                code = s.get("code", "")
                if not inside:
                    if code not in SKIP:
                        notes.append((code or "no code", label, ""))
                    continue
                rows.append((res, name, label, code, dirty, s))
    who = f"{t.prj}/{t.pkg}"
    if not rows and dirty_repo:
        return 1, f"PENDING — {who}: no status yet (repository dirty)"
    if not rows and notes:
        raise Lookup(out_of_scope(who))
    if not rows:
        raise Lookup(f"no build results for {who}{t.where}")
    # the link origin, read once and only when a judged build is not green
    there, upstream = {}, None
    if t.scoped and any(d or c not in GREEN | SKIP for _, _, _, c, d, _ in rows):
        # unexpanded: a broken link fails to expand, and its reds must still read red
        upstream = scope.origin(geectl(["remote", "link-target", t.prj, t.pkg]), t.pkg)
    if upstream:
        theirs = scope.codes(
            geectl(
                [
                    "build",
                    "results",
                    upstream[0],
                    "--package",
                    upstream[1],
                    "--multibuild",
                ]
            ),
            upstream[1],
        )
        kept = []
        for row in rows:
            res, name, label = row[0], row[1], row[2]
            c = theirs.get((res.get("repository"), res.get("arch"), name[len(t.pkg) :]))
            if c in scope.OFF and row[3] not in SKIP:
                notes.append((f"{c} in {upstream[0]}", label, ""))
                continue
            there[label] = c
            kept.append(row)
        rows = kept

    red, failed, pending, ok, waits, pre = [], [], [], [], [], []
    for res, name, label, code, dirty, s in rows:
        if dirty:
            pending.append(("dirty", label, ""))
        elif code in SKIP:
            continue
        elif code in RED:
            if there.get(label) in PRE:
                pre.append((code, label, clip(s.get("details"), 80)))
            else:
                red.append((code, label, clip(s.get("details"), 80)))
        elif code == "failed":
            failed.append((res, name, label))
        elif code in GREEN:
            ok.append((res, name, label))
        elif code in PENDING:
            pending.append((code, label, ""))
            if code == "scheduled":
                waits.append((res.get("repository"), res.get("arch")))
        else:
            # Never pending: a code nobody knows must not hold the wait open.
            red.append((f"unknown code {code!r}", label, ""))
    # The PRE-EXISTING note here names RED-code pres only: failed-code pres
    # are classified by the loop below, so they wait for the second return.
    if red:
        return 2, f"FAILED — {who}: {summary(red)}" + (
            f"; PRE-EXISTING: {summary(pre)}" if pre else ""
        )
    if not (failed or pending or ok or pre):
        if t.scoped:
            raise Lookup(out_of_scope(who))
        return 2, f"FAILED — {who}: nothing to build, all excluded or disabled"

    # OBS refuses the source listing while the package's source service
    # runs: that one failure is pending, so the wait goes on. Any other
    # lookup saying the same words (build results, job history) stays no
    # answer -- those are raised as Lookup, not ServiceRunning, and the
    # top-level handler turns them into UNKNOWN.
    try:
        src = listing(t)
    except ServiceRunning:
        return 1, f"PENDING — {who}: the source service is still running"
    t.srcmd5 = src.get("srcmd5")
    t.linked = src.get("linked", False)
    t.link_bound = src.get("bound")
    who += f" sources {t.srcmd5[:12]}" if t.srcmd5 else " sources (linked)"
    older = "built from older sources"
    for res, name, label in failed:
        job = last_job(t, res.get("repository"), res.get("arch"), name)
        if job is None:
            if there.get(label) in PRE:
                pre.append(("failed", label, ""))
            else:
                red.append(("failed", label, ""))
            continue
        cur = job_built_current(t, job)
        if cur is False:
            src5 = job.get("srcmd5") or ""
            pending.append(
                (
                    older,
                    label,
                    f"failed on {src5[:12]}"
                    if src5
                    else "failed before the latest commit",
                )
            )
        elif cur is None:
            raise Lookup(
                f"cannot tell whether the {label} job built the current sources"
            )
        else:
            if there.get(label) in PRE:
                pre.append(("failed", label, ""))
            else:
                red.append(("failed", label, ""))
    pre_note = f"; PRE-EXISTING: {summary(pre)}" if pre else ""
    if red:
        return 2, f"FAILED — {who}: {summary(red)}{pre_note}"
    # One judged build green from the current sources is the evidence: the
    # still-building remainder is named, not waited on.
    current = []
    for res, name, label in ok:
        job = last_job(t, res.get("repository"), res.get("arch"), name)
        if job is None:
            raise Lookup(f"no build job recorded for {label}: its sources are unknown")
        cur = job_built_current(t, job)
        if cur is False:
            src5 = job.get("srcmd5") or ""
            pending.append(
                (
                    older,
                    label,
                    f"succeeded on {src5[:12]}"
                    if src5
                    else "succeeded before the latest commit",
                )
            )
        elif cur is None:
            raise Lookup(
                f"cannot tell whether the {label} job built the current sources"
            )
        else:
            current.append((res, name, label))
    if current:
        green = summary([("succeeded", x[2], "") for x in current], 8)
        still = [p for p in pending if p[0] != older]
        old = [p for p in pending if p[0] == older]
        rest = f"; still building: {summary(still)}" if still else ""
        rest += f"; {summary(old)}" if old else ""
        rest += pre_note
        return 0, f"GREEN — {who}: {green}{rest}"
    # Nothing green from the current sources: queued-stuck and
    # blocked-upstream return at once, as before; otherwise still pending.
    if pending and all(state == "scheduled" for state, _, _ in pending):
        try:
            now, since = time.time(), last_commit(t)
        except ServiceRunning:
            return 1, f"PENDING — {who}: the source service is still running"
        if now - since >= STUCK:
            for where in dict.fromkeys(waits):
                since = max(since, last_job_end(t, *where))
                if now - since < STUCK:
                    break
        if now - since >= STUCK:
            return 4, (
                f"QUEUED-STUCK — {who}: {summary(pending)} for {int((now - since) // 60)} "
                f"min with no commit or finished job there{pre_note}; not green: report "
                "it and check back later"
            )
    if pending and all(
        state == "blocked" and there.get(label) == "blocked"
        for state, label, _ in pending
    ):
        return 5, (
            f"BLOCKED-UPSTREAM — {who}: {summary(pending)}{pre_note}, blocked in {upstream[0]} "
            "too; not green: a dependency rebuild outside this change, "
            "report it and check back later"
        )
    if pending:
        return 1, f"PENDING — {who}: {summary(pending)}{pre_note}"
    # Nothing green, nothing building, only reds the link origin has too:
    # no green evidence yet, and none of it is this change's failure.
    return 1, f"PENDING — {who}: PRE-EXISTING: {summary(pre)}"


def build_event(t, key, p):
    if key not in BUILD_TOPICS or p.get("project") != t.prj:
        return None
    if key.endswith(".repo.build_finished"):
        repo = p.get("repo")
    else:
        name = p.get("package") or ""
        if name != t.pkg and not name.startswith(t.pkg + ":"):
            return None
        repo = p.get("repository")
    if (t.repo and repo != t.repo) or (t.arch and p.get("arch") != t.arch):
        return None
    md5 = p.get("srcmd5")
    if t.srcmd5 and md5 and md5 != t.srcmd5:
        note(
            f"ignored {key.rsplit('.', 1)[-1]} on {repo}/{p.get('arch')}: older sources {md5[:12]}"
        )
        return None
    return True


# ---------------------------------------------------------------- request


def request_check(t):
    req = geectl(["request", "show", t.id])
    st = req.get("state") or {}
    name = st.get("name", "")
    who = clip(st.get("who", "?"), 60)
    said = clip(st.get("comment") or "")
    said = f": {said}" if said else ""
    if name == "accepted":
        return 0, f"ACCEPTED — request {t.id} by {who}"
    if name == "superseded":
        return 2, f"SUPERSEDED — request {t.id} by #{st.get('superseded_by', '?')}"
    if name in ("declined", "revoked", "deleted"):
        return 2, f"{name.upper()} — request {t.id} by {who}{said}"
    if name in ("new", "review"):
        open_ = [
            clip(
                r.get("by_user") or r.get("by_group") or r.get("by_project") or "?", 60
            )
            for r in req.get("reviews", [])
            if r.get("state") == "new"
        ]
        by = f"; open reviews: {', '.join(open_)}" if open_ else ""
        return 1, f"PENDING — request {t.id} {name}{by}"
    raise Lookup(f"request {t.id}: unrecognized state {name!r}")


def request_event(t, key, p):
    # Only the number: a request's database id is a different integer.
    return key.startswith("opensuse.obs.request.") and str(p.get("number")) == t.id


# ---------------------------------------------------------------- feed


OPEN = object()


class Feed:
    """OBS's event bus as server-sent events, read on a daemon thread so that a
    stalled stream never holds the wait past its deadline. Wake-ups only."""

    def __init__(self, deadline):
        self.q, self.gone, self.early = queue.Queue(), False, None
        threading.Thread(target=self._read, daemon=True).start()
        item = self._get(min(FEED_OPEN, deadline - time.monotonic()))
        if item is not OPEN:
            self.gone = True
            raise item if isinstance(item, FeedLost) else FeedLost("no answer")
        # Ask geectl only once the stream delivers: the server is subscribed then.
        self.early = self._get(min(FEED_PRIME, deadline - time.monotonic()))
        if isinstance(self.early, FeedLost):
            self.gone = True
            raise self.early

    def _get(self, wait):
        try:
            return self.q.get(timeout=max(0, wait))
        except queue.Empty:
            return None

    def _read(self):
        try:
            req = urllib.request.Request(
                FEED_URL, headers={"Accept": "text/event-stream"}
            )
            with urllib.request.urlopen(req, timeout=FEED_IDLE) as resp:
                kind = resp.headers.get("Content-Type") or "no content type"
                if not kind.startswith("text/event-stream"):
                    raise FeedLost(f"not an event stream: {kind}")
                self.q.put(OPEN)
                data = []
                for raw in resp:
                    if self.gone:
                        return
                    line = raw.decode("utf-8", "replace").rstrip("\r\n")
                    if line.startswith("data:"):
                        data.append(line[5:])
                    elif not line and data:
                        self.q.put("\n".join(data))
                        data = []
            raise FeedLost("the stream ended")
        except Exception as e:  # whatever urllib, ssl or the socket raise
            if not isinstance(e, FeedLost):
                e = FeedLost(f"{type(e).__name__}: {e or 'no detail'}")
            self.q.put(e)

    def next(self, wait):
        """(topic, body) of the next event, None if none comes within wait."""
        item, self.early = self.early or self._get(wait), None
        if isinstance(item, FeedLost):
            self.gone = True
            raise item
        try:
            ev = json.loads(item) if isinstance(item, str) else None
        except ValueError:
            return None
        if not isinstance(ev, dict):
            return None
        topic, body = ev.get("topic"), ev.get("body")
        return (
            (topic, body) if isinstance(topic, str) and isinstance(body, dict) else None
        )

    def close(self):
        # Never join or close a stalled read: the thread leaves at its next line.
        self.gone = True


def open_feed(deadline):
    try:
        return Feed(deadline)
    except FeedLost as e:
        note(f"no event stream ({e}); polling geectl instead")
        return None


# ---------------------------------------------------------------- main


def wait(t, check, match):
    deadline = time.monotonic() + t.timeout
    # Subscribe before the first check: an event between the two would be lost.
    feed = open_feed(deadline) if t.timeout > 0 else None
    recheck = t.recheck or (300 if feed else POLL)
    drops = 0
    try:
        code, line = check(t)
        last, wake = time.monotonic(), False
        while code == 1 and time.monotonic() < deadline:
            if feed:
                try:
                    ev = feed.next(1)
                except FeedLost as e:
                    drops += 1
                    if drops < FEED_DROPS:
                        note(f"event stream lost ({e}); reconnecting")
                        feed = open_feed(deadline)
                    else:
                        note(f"event stream lost {drops} times ({e}); polling geectl")
                        feed = None
                    recheck = t.recheck or (recheck if feed else POLL)
                    # whatever happened while disconnected sent no event
                    wake, ev = True, None
                wake = wake or bool(ev and match(t, *ev))
            else:
                time.sleep(max(0, min(last + recheck, deadline) - time.monotonic()))
            now = time.monotonic()
            if (wake and now - last >= GAP) or now - last >= recheck:
                code, line = check(t)
                last, wake = now, False
        if code == 1 and time.monotonic() - last >= GAP:
            code, line = check(t)
    finally:
        if feed:
            feed.close()
    if code == 1 and t.timeout > 0:
        line += f" — not settled after {t.timeout}s, repeat the call"
    return code, line


class Parser(argparse.ArgumentParser):
    def error(self, message):  # usage is "no answer", not argparse's 2
        self.print_usage(sys.stderr)
        sys.stderr.write(f"{self.prog}: error: {message}\n")
        sys.exit(3)


def seconds(minimum):
    def integer(s):
        v = int(s)
        if v < minimum:
            raise argparse.ArgumentTypeError(f"must be >= {minimum}")
        return v

    return integer


def regex(s):
    try:
        return re.compile(s)
    except re.error as e:
        raise argparse.ArgumentTypeError(f"not a regular expression: {e}")


def main(argv=None):
    ap = Parser(
        prog="obs-wait.py",
        allow_abbrev=False,
        usage="obs-wait.py build PRJ PKG [--repos REGEX] [--arches REGEX] [--target PRJ] [--all]\n"
        "                          [--repo R] [--arch A] [--timeout S] [--recheck S]\n"
        "       obs-wait.py request ID [--timeout S] [--recheck S]",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = ap.add_subparsers(dest="mode", required=True, metavar="{build,request}")
    b = sub.add_parser("build", prog="obs-wait.py build", allow_abbrev=False)
    b.add_argument("prj")
    b.add_argument("pkg")
    b.add_argument("--repo", metavar="R")
    b.add_argument("--arch", metavar="A")
    b.add_argument("--repos", metavar="REGEX", type=regex)
    b.add_argument("--arches", metavar="REGEX", type=regex)
    b.add_argument("--target", metavar="PRJ")
    b.add_argument("--all", action="store_true")
    r = sub.add_parser("request", prog="obs-wait.py request", allow_abbrev=False)
    r.add_argument("id")
    for p in (b, r):
        p.add_argument("--timeout", metavar="S", type=seconds(0), default=80)
        p.add_argument("--recheck", metavar="S", type=seconds(1))
    t = ap.parse_args(argv)
    if t.mode == "request":
        if not t.id.isdigit():
            ap.error(f"not a request number: {t.id!r}")
        t.id = str(int(t.id))
    t.srcmd5 = None
    t.linked = False
    t.link_bound = None
    if t.mode == "build":
        if t.all and (t.repos or t.arches):
            ap.error("--all already takes every repo/arch: drop --repos/--arches")
        t.scoped = not (t.all or t.repo or t.arch)
        tprj = (t.target or "").split("/")[0]
        t.leap = not (
            tprj == "openSUSE:Factory" or tprj.startswith("openSUSE:Factory:")
        )
        t.where = f" on {t.repo or '*'}/{t.arch or '*'}" if t.repo or t.arch else ""
        mode = (build_check, build_event)
    else:
        mode = (request_check, request_event)
    try:
        code, line = wait(t, *mode)
    except Lookup as e:
        code, line = 3, f"UNKNOWN — {e}"
    print(f"VERDICT: {line}")
    return code


if __name__ == "__main__":
    sys.exit(main())
