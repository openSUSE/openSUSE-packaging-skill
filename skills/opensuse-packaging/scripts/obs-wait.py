#!/usr/bin/env python3
"""Wait for ONE OBS build or request to settle, in one bounded call, instead of
a sleep loop.

build    PKG and its multibuild flavors on every repo/arch (or --repo/--arch),
         judged only on a build of the CURRENT expanded sources: a result of an
         older srcmd5 reads pending, never green or failed
request  request ID, by its request number

It opens OBS's public event stream first (server-sent events from
rabbit.opensuse.org, anonymous and read-only) and asks osc second, so nothing
lands in between. An event only wakes it to ask osc again: osc gives every
verdict. It also asks osc every --recheck seconds (default 300; 30 when
polling), after every reconnect and once more at --timeout (default 80), since
unresolvable, broken, excluded and disabled send no event and a dropped stream
replays nothing. With the stream unreachable or dropping repeatedly it polls
osc and says so on stderr; a stalled stream never holds it past --timeout.
A call takes about --timeout plus that last osc check; --timeout 0 asks osc
once. Prints one VERDICT line. Read-only; osc authenticates itself, no
credential file is read.

Exit:
  0 = green on every applicable repo/arch from the current sources; request accepted
  1 = still pending at --timeout: repeat the same call
  2 = settled failure: failed/unresolvable/broken/unknown code or nothing to build; request declined/revoked/superseded/deleted
  3 = no answer: usage, or an osc lookup failed or did not parse
"""

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _sanitize  # escape/Unicode-smuggling filter for third-party text

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
OSC_TIMEOUT = 30
POLL = 30  # --recheck default without the feed
GAP = 2  # coalesces an event burst (every arch finishing at once) into one check

GREEN = {"succeeded"}
RED = {"unresolvable", "broken"}
SKIP = {"disabled", "excluded"}
PENDING = {"scheduled", "building", "blocked", "finished", "signing", "dispatching"}


class Lookup(Exception):
    """An osc answer we could not get or read: exit 3, never a verdict."""


class FeedLost(Exception):
    pass


def note(msg):
    sys.stderr.write(f"obs-wait: {msg}\n")


def clip(text, n=120):
    text = " ".join(_sanitize.sanitize(text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def osc(args):
    what = " ".join(args[:2])
    try:
        r = subprocess.run(
            ["osc"] + args, capture_output=True, text=True, timeout=OSC_TIMEOUT
        )
    except subprocess.TimeoutExpired:
        raise Lookup(f"osc {what} timed out after {OSC_TIMEOUT}s")
    except FileNotFoundError:
        raise Lookup("osc: command not found")
    if r.returncode != 0:
        last = (r.stderr.strip().splitlines() or ["no error text"])[-1]
        raise Lookup(f"osc {what} failed: {clip(last)}")
    return r.stdout


def parse(xml, what):
    try:
        return ET.fromstring(xml)
    except ET.ParseError as e:
        raise Lookup(f"unparseable {what}: {e}")


# ---------------------------------------------------------------- build


def last_job(t, repo, arch, name):
    """srcmd5 of the last build job of name on repo/arch, "" if none. Not
    _history: an unchanged rebuild adds no entry there."""
    path = f"/build/{t.prj}/{repo}/{arch}/_jobhistory?package={name}&limit=1"
    jobs = parse(osc(["api", path]), f"{repo}/{arch} job history").findall("jobhist")
    return jobs[-1].get("srcmd5", "") if jobs else ""


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
    cmd = ["results", "--xml"]
    cmd += ["-r", t.repo] if t.repo else []
    cmd += ["-a", t.arch] if t.arch else []
    root = parse(osc(cmd + [t.prj, t.pkg]), "osc results")
    rows, dirty_repo = [], False
    for res in root.findall("result"):
        where = f"{res.get('repository')}/{res.get('arch')}"
        dirty = res.get("dirty") == "true"
        dirty_repo |= dirty
        for s in res.findall("status"):
            name = s.get("package", "")
            if name == t.pkg or name.startswith(t.pkg + ":"):
                label = where + name[len(t.pkg) :]
                rows.append((res, name, label, s.get("code", ""), dirty, s))
    who = f"{t.prj}/{t.pkg}"
    if not rows and dirty_repo:
        return 1, f"PENDING — {who}: no status yet (repository dirty)"
    if not rows:
        raise Lookup(f"no build results for {who}{t.where}")

    red, failed, pending, ok = [], [], [], []
    for res, name, label, code, dirty, s in rows:
        if dirty:
            pending.append(("dirty", label, ""))
        elif code in SKIP:
            continue
        elif code in RED:
            red.append((code, label, clip(s.findtext("details"), 80)))
        elif code == "failed":
            failed.append((res, name, label))
        elif code in GREEN:
            ok.append((res, name, label))
        elif code in PENDING:
            pending.append((code, label, ""))
        else:
            # Never pending: a code nobody knows must not hold the wait open.
            red.append((f"unknown code {code!r}", label, ""))
    if red:
        return 2, f"FAILED — {who}: {summary(red)}"
    if not (failed or pending or ok):
        return 2, f"FAILED — {who}: nothing to build, all excluded or disabled"

    src = parse(osc(["api", f"/source/{t.prj}/{t.pkg}?expand=1"]), "source listing")
    t.srcmd5 = src.get("srcmd5")
    if not t.srcmd5:
        raise Lookup(f"no srcmd5 in the {who} source listing")
    who += f" sources {t.srcmd5[:12]}"
    older = "built from older sources"
    for res, name, label in failed:
        got = last_job(t, res.get("repository"), res.get("arch"), name)
        if got and got != t.srcmd5:
            pending.append((older, label, f"failed on {got[:12]}"))
        else:
            red.append(("failed", label, ""))
    if red:
        return 2, f"FAILED — {who}: {summary(red)}"
    if pending:
        return 1, f"PENDING — {who}: {summary(pending)}"
    for res, name, label in ok:
        got = last_job(t, res.get("repository"), res.get("arch"), name)
        if not got:
            raise Lookup(f"no build job recorded for {label}: its sources are unknown")
        if got != t.srcmd5:
            pending.append((older, label, f"succeeded on {got[:12]}"))
    if pending:
        return 1, f"PENDING — {who}: {summary(pending)}"
    return 0, f"GREEN — {who}: " + summary([("succeeded", x[2], "") for x in ok], 8)


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
    root = parse(osc(["api", f"/request/{t.id}"]), f"request {t.id}")
    st = root.find("state")
    name = st.get("name", "") if st is not None else ""
    who = clip(st.get("who", "?") if st is not None else "?", 60)
    said = clip(st.findtext("comment") if st is not None else "")
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
            for r in root.findall("review")
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
        # Ask osc only once the stream delivers: the server is subscribed then.
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
        note(f"no event stream ({e}); polling osc instead")
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
                        note(f"event stream lost {drops} times ({e}); polling osc")
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


def main(argv=None):
    ap = Parser(
        prog="obs-wait.py",
        usage="obs-wait.py build PRJ PKG [--repo R] [--arch A] [--timeout S] [--recheck S]\n"
        "       obs-wait.py request ID [--timeout S] [--recheck S]",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = ap.add_subparsers(dest="mode", required=True, metavar="{build,request}")
    b = sub.add_parser("build", prog="obs-wait.py build")
    b.add_argument("prj")
    b.add_argument("pkg")
    b.add_argument("--repo", metavar="R")
    b.add_argument("--arch", metavar="A")
    r = sub.add_parser("request", prog="obs-wait.py request")
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
    if t.mode == "build":
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
