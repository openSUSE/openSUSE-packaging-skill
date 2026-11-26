#!/usr/bin/env python3
# Kimi Code PreToolUse hook: refuse tool calls that read credential files, print secrets, call
# the OBS or Gitea API past geectl/tea/git-obs, merge a PR on src.opensuse.org, file a
# request that targets openSUSE:Factory directly, or run sudo.
"""Exit 2 blocks the call and its stderr becomes the tool result; exit 0 lets it run.

Any error inside the hook blocks too (fail closed). It matches text, so a path built at run time,
a variable or a script written first and run later still gets past it.
"""

import bisect
import json
import os
import re
import sys

HOME = os.path.expanduser("~")
KIMI_HOME = os.environ.get("KIMI_CODE_HOME") or f"{HOME}/.kimi-code"
# Write and Edit may not touch this hook or the config that wires it in.
SELF = (os.path.join(KIMI_HOME, "config.toml"), os.path.join(KIMI_HOME, "hooks") + "/")
# Kimi runs a call the hook has not judged within its timeout, so a text too long to scan
# quickly is refused outright.
MAX_TEXT = 64 * 1024

PATHS = [
    r"\.config/gh(?![\w.-])",
    r"gh/hosts\.yml",
    r"\.config/geectl\b",
    r"\.config/tea\b",
    r"\.netrc\b",
    r"\.git-credentials\b",
    r"\.config\}?/git/credentials\b",
    r"CONFIG_HOME\}?/git/credentials\b",
    r"(?:^|[\s/\"'=:<>(|;&])\.env(?:\.(?!example\b)[\w.-]+)?(?=$|[\s\"'/;|&)<>,*?\[])",
    r"\.config/mcp-bugzilla\b",
]
# geectl's global options that take the next word; a group and leaf are found past them,
# in their own place, not wherever their names occur in a message. Only --format takes
# a value; geectl takes no option by any unambiguous prefix.
GEECLT_VALUED = set()
GEECLT_VALUED_LONG = ("--format",)
# Each rule holds when all its parts occur in one simple command. Parts are searched
# separately, and no part has two quantifiers that can take the same characters, which
# keeps every search linear in the command's length.
COMMANDS = [
    (r"\bgh\s+auth\s+(?:token|status|git-credential)\b",),
    (r"(?:(?<!\S)(?-i:-[a-zA-Z]*H)|--header)[\s=]*(?:['\"]\s*)?authorization\s*:",),
    (r"--api(?:key|secret)\b",),
    (r"://[^\s/:@]+:[^\s/@]+@",),
    (r"\b(?:GIT|SSH)_ASKPASS\s*=|core\.askpass",),
    (r"\bgit[\s-]obs\b", r"\blogin\s+list\b"),
    (r"gitcredentials-helper",),
    (r"\blogins?\s+(?:helper|git-credential)\b",),
    (r"\btea\b", r"\blogins?\s+(?:edit|e)\b"),
    (r"\bsecret-tool\s+(?:lookup|search)\b",),
    (r"\bcredential\s+fill\b",),
    (r"\bGEECTL_(?:OBS|GITEA)_",),
    (r"\bgit[\s-]credential-", r"(?:^|\s)get\b"),
    (
        r"\b(?:curl|wget)\b",
        r"\b(?:api|build)\.opensuse\.org\b|\bsrc\.opensuse\.org/api\b",
    ),
    (
        r"\bgeectl\b",
        r"\brequest\b",
        r"\b(?:file|refile)\b",
        r"--target-project\b",
        r"openSUSE:Factory\b",
    ),
    (r"\bsudo\b", r"(?<!local-build )\bchroot\b"),
    (
        r"\bsudo\b",
        r"(?:^|(?<=[;&|\n]))\s*(?:(?:do|then|else|exec|command|nohup|time|xargs|\w+=\S*)\s+)*sudo\b",
    ),
    (r"\btea\b", r"\b(?:pr|pulls?)\b", r"\bmerge\b"),
    (r"\btea\s+(?:pr|pulls?)\s+m\b",),
    (r"\bgit[\s-]obs\b", r"\bpr\b", r"\bmerge\b"),
    (
        r"\btea\b|\bgit[\s-]obs\b|src\.opensuse\.org|repos/pool/",
        r"/pulls/[^/\s]+/merge\b",
    ),
]
# A recursive search rooted at one of these, or at an ancestor of one, would read them.
SECRET_ROOTS = [
    f"{HOME}/.config/gh",
    f"{HOME}/.config/geectl",
    f"{HOME}/.config/tea",
    f"{HOME}/.netrc",
    f"{HOME}/.git-credentials",
    f"{HOME}/.config/git/credentials",
    f"{HOME}/.config/mcp-bugzilla",
]
PATH_RE = re.compile("|".join(PATHS), re.IGNORECASE)
RULES = [[re.compile(p, re.IGNORECASE) for p in parts] for parts in COMMANDS]
GEECLT_WORD_RE = re.compile(r"[\s`$(){}]+")
WORD_RE = re.compile(r"[\s\"'`=<>|;&()]+")
UP_RE = re.compile(r"(?:\.\.(?:/|$))*")
MCP_KEY_RE = re.compile(r"path|file|dir|root|scope|glob|url|command|cmd", re.IGNORECASE)
ROOT_KEY_RE = re.compile(r"path|dir|root|scope", re.IGNORECASE)


def block(why):
    sys.stderr.write(f"Denied by opensuse-packaging hook: {why}\n")
    sys.exit(2)


def segments(text):
    """The (start, end) of each simple command: split at ; & | and newlines outside
    quotes, in one pass."""
    out, start, quote, i = [], 0, "", 0
    while i < len(text):
        c = text[i]
        if c == "\\" and quote != "'":
            i += 2
            continue
        if quote:
            if c == quote:
                quote = ""
        elif c in "'\"":
            quote = c
        elif c in "\n;&|":
            out.append((start, i))
            start = i + 1
        i += 1
    out.append((start, len(text)))
    return out


def geectl_calls(segment):
    """Yield (group, leaf, the next three words) for each geectl in a simple command."""
    words = [w for w in GEECLT_WORD_RE.split(segment) if w]
    for i, word in enumerate(words):
        if word == "geectl" or word.endswith("/geectl"):
            j = i + 1
            for _ in range(16):  # more global options than that is not a real call
                if j >= len(words) or not words[j].startswith("-"):
                    break
                opt = words[j]
                valued = opt in GEECLT_VALUED or opt in GEECLT_VALUED_LONG
                j += 2 if valued else 1
            if j + 1 < len(words):
                yield words[j], words[j + 1], words[j + 2 : j + 5]


def refused(text):
    # Bash deletes a backslash-newline, so "gh auth \\<newline>token" is gh auth token.
    text = text.replace("\\\n", "")
    if len(text) > MAX_TEXT:
        return f"it is longer than {MAX_TEXT} characters, too long to check"
    if PATH_RE.search(text):
        return "it names a credential file"
    # Only a rule whose parts all occur somewhere can hold in one simple command, and
    # only in a simple command where its first part occurs: each is tried once.
    candidates = [parts for parts in RULES if all(rx.search(text) for rx in parts)]
    if not candidates and "geectl" not in text:
        return None
    spans = segments(text)
    starts = [a for a, _ in spans]
    for parts in candidates:
        tried = set()
        for m in parts[0].finditer(text):
            k = bisect.bisect_right(starts, m.start()) - 1
            if k not in tried:
                tried.add(k)
                segment = text[spans[k][0] : spans[k][1]]
                if all(rx.search(segment) for rx in parts):
                    return "it prints a secret or is refused here"
    for a, b in spans if "geectl" in text else ():
        segment = text[a:b]
        for group, leaf, rest in geectl_calls(segment) if "geectl" in segment else ():
            if group == "remote" and leaf == "create-token":
                return "geectl prints a token here"
    return None


def variants(path, cwds):
    out = {path}
    for cwd in cwds:
        joined = os.path.join(cwd, os.path.expanduser(path))
        out |= {joined, os.path.normpath(joined), os.path.realpath(joined)}
    return out


def check_path(path, cwds, recursive=False, write=False):
    if len(path) > MAX_TEXT:
        block("the path is too long to check")
    for variant in variants(path, cwds):
        if PATH_RE.search(variant):
            block(f"{path!r} is a credential file")
        if write and (variant == SELF[0] or variant.startswith(SELF[1])):
            block(f"{path!r} is this hook or its configuration")
        if recursive and any(
            root == variant or root.startswith(variant.rstrip("/") + "/")
            for root in SECRET_ROOTS
        ):
            block(f"a recursive search of {path!r} would read credential files")


def check_words(command, cwd):
    """Resolve each word of a Bash command against the cwd the call sets."""
    base = os.path.normpath(cwd).rstrip("/")
    for word in set(WORD_RE.split(command)):
        word = os.path.normpath(word)
        up = UP_RE.match(word).group()
        rest = word[len(up) :]
        path = os.path.join(base.rsplit("/", up.count(".."))[0] + "/", rest)
        # base itself passed check_path, so only a match near the join is new.
        if PATH_RE.search(path, max(0, len(path) - len(rest) - 64)):
            block(f"{word!r} is a credential file in the call's cwd")


def mcp_strings(obj, key=""):
    if isinstance(obj, dict):
        for name, value in obj.items():
            yield from mcp_strings(value, name)
    elif isinstance(obj, list):
        for value in obj:
            yield from mcp_strings(value, key)
    elif isinstance(obj, str) and MCP_KEY_RE.search(key):
        yield key, obj


def session_dirs(session):
    # A line cut short by a concurrent write is skipped, not fatal.
    dirs = set()
    try:
        with open(
            os.path.join(KIMI_HOME, "session_index.jsonl"), encoding="utf-8"
        ) as handle:
            for line in handle:
                if session in line:
                    try:
                        dirs.add(json.loads(line).get("workDir"))
                    except ValueError:
                        pass
    except OSError:
        pass
    dirs.discard(None)
    return dirs


def main():
    event = json.load(sys.stdin)
    tool = event.get("tool_name", "")
    args = event.get("tool_input") or {}
    # event["cwd"] is Kimi's process directory; an ACP or web session has its own workDir.
    cwds = {event.get("cwd") or os.getcwd()} | session_dirs(
        event.get("session_id") or "\0"
    )
    if tool == "Bash":
        command = args.get("command", "").replace("\\\n", "")
        why = refused(command)
        if why:
            block(f"the command is refused: {why}")
        if args.get("cwd"):
            check_path(args["cwd"], cwds)
        # Without a cwd of its own the command runs in the session's directory.
        for cwd in cwds:
            check_words(
                command, os.path.join(cwd, os.path.expanduser(args.get("cwd") or "."))
            )
    elif tool in ("Read", "ReadMediaFile"):
        check_path(args.get("path", ""), cwds)
    elif tool in ("Write", "Edit"):
        check_path(args.get("path", ""), cwds, write=True)
    elif tool == "Grep":
        for root in [args["path"]] if args.get("path") else sorted(cwds):
            check_path(root, cwds, recursive=True)
            if args.get("glob"):
                check_path(os.path.join(root, args["glob"]), cwds)
    elif tool == "Glob":
        check_path(os.path.join(args.get("path") or ".", args.get("pattern", "")), cwds)
    elif tool == "FetchURL":
        url = args.get("url", "")
        if len(url) > MAX_TEXT or PATH_RE.search(url):
            block("the URL names a credential file or is too long to check")
    elif tool.startswith("mcp__"):
        total = 0
        for key, text in mcp_strings(args):
            total += len(text)
            if total > MAX_TEXT:
                block(f"the MCP arguments are longer than {MAX_TEXT} characters in all")
            why = refused(text)
            if why:
                block(f"an MCP argument is refused: {why}")
            # A search scoped to a directory above the credentials would read them.
            if ROOT_KEY_RE.search(key):
                check_path(text, cwds, recursive=True)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - any failure must block, not let the call run
        block(f"the hook failed ({type(error).__name__}); failing closed")
    sys.exit(0)
