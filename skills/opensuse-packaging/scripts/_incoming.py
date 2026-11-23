#!/usr/bin/env python3
"""Contributors' submissions on your packages: whether you maintain the
package, as the guard decides it, and what an earlier review recorded.

maintains() is _pr_guard.py's maintains() on the same lookups: the account
maintains PRJ/PKG when the package _meta names it maintainer, or names no
maintainer (person or group) and the project _meta does; a project whose
_meta has <scmsync> is judged by its project git's _maintainership.json (the
package's list, else the project's ""). The guard is the harness hook's rule
set, installed pinned on its own, so it is mirrored here rather than
imported; tests/test-preflight.sh runs both on the same cases. Where the
guard answers "no" to a lookup that failed or did not parse, this raises
Unknown: preflight.sh must not read it as "not yours".

stamp() reads the verdict incoming-review.sh recorded for a submission:
<id>.json for an OBS request, <owner>_<repo>_<N>.json for a PR (owner and
repo lowercased, each % written %25 and each _ %5F). Only its verdict and
key (64 hex), and a PR's head, are read, and a stamp that is missing,
unreadable or malformed, or names another submission, is "not reviewed".
A PR's stamp of another head than the PR has now reads "reviewed at an
older head: review again", and is not reviewed either.

preflight.sh runs it, and reads anything but 0 or 3 from maintains as a
failed check (an uncaught exception is 2 too, never "no"):
  _incoming.py maintains USER PRJ PKG   exit 0 yes, 3 no (why on stdout),
                                        2 unknown (why on stdout)
  _incoming.py stamp sr#N | OWNER/REPO#N HEAD
                                        prints the annotation; 2 bad item
"""

import html
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

TIMEOUT = 30  # seconds per osc / git-obs call when run as a command

# _pr_guard.py's GIT_LOGIN, GIT_REF and PROJECT_GIT.
GIT_LOGIN = re.compile(r"@?[A-Za-z0-9][A-Za-z0-9_.-]*")
GIT_REF = re.compile(r"(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9_.-]*")
PROJECT_GIT = re.compile(
    r"https://src\.opensuse\.org/([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9_][A-Za-z0-9_.+-]*?)"
    r"(?:\.git)?(?:\?[^#\s]*)?(?:#([^#\s]*))?"
)
SR_ITEM = re.compile(r"sr#([0-9]+)")
PR_ITEM = re.compile(
    r"([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9_][A-Za-z0-9_.+-]*)#([0-9]+)"
)
VERDICTS = ("PASS", "FIXABLE", "BLOCK")
# A PR's head: a SHA-1 or a SHA-256 commit id.
GIT_ID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


class Unknown(Exception):
    """A lookup that failed or an answer that did not parse."""


def run(cmd):
    """subprocess.run with TIMEOUT; a timeout or a missing binary comes back
    as a failed call (rc 124 / 127, as in the shell)."""
    try:
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            cmd, 124, "", f"{cmd[0]} timed out after {TIMEOUT}s"
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 127, "", f"{cmd[0]}: command not found")


def obs_get(path, run=run, cache=None):
    """The text of an OBS API GET, None for a 404; Unknown otherwise."""
    if cache is not None and path in cache:
        return cache[path]
    r = run(["osc", "api", path])
    if r.returncode == 0 and r.stdout:
        text = r.stdout
    elif r.returncode != 0 and "HTTP Error 404" in r.stderr:
        text = None
    else:
        why = r.stderr.strip().splitlines()[-1:] or [f"osc exited {r.returncode}"]
        raise Unknown(f"cannot read {path}: {why[0]}")
    if cache is not None:
        cache[path] = text
    return text


def git_get(owner, repo, name, ref, run=run, cache=None):
    """The text of file name in src.opensuse.org's owner/repo at ref (its
    default branch when ""), through git-obs; None for a 404, else Unknown."""
    path = f"/repos/{owner}/{repo}/raw/{name}" + (f"?ref={ref}" if ref else "")
    if cache is not None and path in cache:
        return cache[path]
    r = run(["git-obs", "-G", "src.opensuse.org", "-q", "api", path])
    if r.returncode == 0:
        text = r.stdout
        if text.startswith("Response:"):
            text = text.split("\n", 1)[1] if "\n" in text else ""
    elif "ERROR: 404" in r.stderr:
        text = None
    else:
        why = r.stderr.strip().splitlines()[-1:] or [f"git-obs exited {r.returncode}"]
        raise Unknown(f"cannot read {owner}/{repo}/{name}: {why[0]}")
    if cache is not None:
        cache[path] = text
    return text


def project_git(pmeta, text):
    """(owner, repo, ref) of the project git a project _meta's <scmsync>
    names, None for a project OBS keeps; Unknown for one the guard cannot
    read (kept elsewhere, an odd ref, a <scmsync> not plain or not alone)."""
    el = pmeta.find("scmsync")
    url = (el.text or "").strip() if el is not None else ""
    plain = re.findall(r"<scmsync>([^<]*)</scmsync>", text)
    if "<scmsync" in text and (
        not url
        or text.count("<scmsync") != 1
        or "<!--" in text
        or "<![CDATA[" in text
        or not plain
        or html.unescape(plain[-1]).strip() != url
    ):
        raise Unknown("a <scmsync> that is not plain text or not alone")
    if not url:
        return None
    m = PROJECT_GIT.fullmatch(url)
    if not m or m.group(3) and not GIT_REF.fullmatch(m.group(3)):
        raise Unknown(f"kept in {url}, whose maintainers this cannot read")
    return m.group(1), m.group(2), m.group(3) or ""


def maintains(user, prj, pkg, run=run, cache=None):
    """(True, "") when user maintains prj/pkg by the guard's rule, else
    (False, why); Unknown when a lookup fails or does not parse."""
    if not user:
        raise Unknown("the account is unknown (osc whois failed)")
    roots, text = [], ""
    for path in (f"/source/{prj}/{pkg}/_meta", f"/source/{prj}/_meta"):
        text = obs_get(path, run, cache)
        if text is None:
            return False, f"{path} does not exist"
        try:
            roots.append(ET.fromstring(text))
        except ET.ParseError:
            raise Unknown(f"{path} did not parse") from None
    meta, pmeta = roots
    git = project_git(pmeta, text)  # text: the project _meta's
    if git:
        owner, repo, ref = git
        at = f"#{ref}" if ref else ""
        raw = git_get(owner, repo, "_maintainership.json", ref, run, cache)
        if raw is None:
            return False, f"{owner}/{repo}{at} has no _maintainership.json"
        try:
            m = json.loads(raw)
        except (ValueError, RecursionError):
            m = None
        lists = [m.get(k, []) for k in (pkg, "")] if isinstance(m, dict) else None
        if lists is None or not all(
            isinstance(v, list)
            and all(isinstance(x, str) and GIT_LOGIN.fullmatch(x) for x in v)
            for v in lists
        ):
            raise Unknown(f"{owner}/{repo}{at}'s _maintainership.json did not parse")
        maints = set(lists[0] or lists[1])
        if user in maints:
            return True, ""
        who = ", ".join(sorted(maints)) or "nobody"
        return False, f"{prj}/{pkg} is maintained by {who} ({owner}/{repo}{at})"

    def holders(root, tag, attr):
        return {
            e.get(attr) for e in root if e.tag == tag and e.get("role") == "maintainer"
        } - {None}

    maints = holders(meta, "person", "userid")
    groups = holders(meta, "group", "groupid")
    if user in maints:
        return True, ""
    if groups:
        return (
            False,
            f"{prj}/{pkg} is maintained by {', '.join(sorted(maints | groups))}",
        )
    if not maints and user in holders(pmeta, "person", "userid"):
        return True, ""
    if not maints:
        return (
            False,
            f"{prj}/{pkg} has no maintainer and {user} does not maintain {prj}",
        )
    return False, f"{prj}/{pkg} is maintained by {', '.join(sorted(maints))}"


def stamp(item, head=None):
    """'reviewed: VERDICT (key KEY)' for item (sr#N, or OWNER/REPO#N and the
    head it has now) from its incoming-review.sh stamp, 'reviewed at an older
    head: review again' for a PR's stamp of another head, or 'not reviewed';
    ValueError for another item, or a head missing or given out of place."""
    m = SR_ITEM.fullmatch(item)
    if m:
        if head is not None:
            raise ValueError(f"a request has no head: {head!r}")
        kind, name, ident = "obs", m.group(1), m.group(1)
    else:
        m = PR_ITEM.fullmatch(item)
        if not m:
            raise ValueError(f"not an sr#N or OWNER/REPO#N item: {item!r}")
        if not isinstance(head, str) or not GIT_ID.fullmatch(head):
            raise ValueError(f"no 40- or 64-hex head for {item}: {head!r}")
        owner, repo = (
            x.lower().replace("%", "%25").replace("_", "%5F") for x in m.groups()[:2]
        )
        kind, name, ident = "gitea", f"{owner}_{repo}_{m.group(3)}", item.lower()
    path = os.path.join(
        os.path.expanduser("~"),
        ".local",
        "state",
        "opensuse-packaging",
        "incoming",
        kind,
    )
    try:
        with open(os.path.join(path, name + ".json"), encoding="utf-8") as fh:
            st = json.loads(fh.read(1 << 20))
    except (OSError, ValueError, RecursionError):
        return "not reviewed"
    if not (
        isinstance(st, dict)
        and st.get("v") == 1
        and st.get("kind") == kind
        and isinstance(st.get("id"), str)
        and (st["id"] if kind == "obs" else st["id"].lower()) == ident
        and st.get("verdict") in VERDICTS
        and isinstance(st.get("key"), str)
        and re.fullmatch(r"[0-9a-f]{64}", st["key"])
    ):
        return "not reviewed"
    if kind == "gitea":
        was = (
            st.get("gitea", {}).get("head")
            if isinstance(st.get("gitea"), dict)
            else None
        )
        if not isinstance(was, str) or not GIT_ID.fullmatch(was):
            return "not reviewed"
        if was != head:
            return "reviewed at an older head: review again"
    return f"reviewed: {st['verdict']} (key {st['key']})"


def main(argv):
    """Any failure is 2: Python's own exit 1 must not pass for an answer."""
    try:
        if argv[1:2] == ["maintains"] and len(argv) == 5:
            ok, why = maintains(*argv[2:5])
            if why:
                print(why)
            return 0 if ok else 3
        if argv[1:2] == ["stamp"] and len(argv) in (3, 4):
            print(stamp(*argv[2:]))
            return 0
        sys.stderr.write(__doc__.split("\n\n")[-1])
    except Unknown as e:
        print(e)
    except Exception as e:
        sys.stderr.write(f"{type(e).__name__}: {e}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
