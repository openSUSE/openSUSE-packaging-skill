"""_pr_guard.py -- the rules of pr-guard.py, which compiles this file only once
a call has matched its prefilter. Not a command: see pr-guard.py --help."""

import json
import os
import re

GITEA = "https://src.opensuse.org/api/v1"
PIN_REF = "refs/remotes/origin/main"
CLEAN_ENV = {"TMPDIR", "LC_ALL", "LANG", "NO_COLOR"}
MAX_DEPTH = 4
MAX_BYTES = 8 << 20


class Rx:
    """A pattern compiled on first use, so a call the prefilter lets through
    never pays for the rules."""

    def __init__(self, pattern):
        self.pattern, self.rx = pattern, None

    def __getattr__(self, name):
        if self.rx is None:
            self.rx = re.compile(self.pattern)
        return getattr(self.rx, name)


# The stamp directory as a path component, in program text or a path.
STAMP = Rx(r"(?<![\w.-])target-gate(?![\w.-])")
# In one shell word a path component ends at a slash, a glob or the word's end:
# a quoted "[ -d …/target-gate ]" that a command only carries names no path.
STAMP_WORD = Rx(r"(?<![\w.-])target-gate(?=[/*?\[]|$)")
# The path a component hangs from: the text back to a quote, space or operator.
PARENT = Rx(r"(?:\$\{\w+\}|[^\s\"'=<>|;&(),`{}])*$")
# Commands that write no file: they may look at the stamps.
READ_ONLY = {"ls", "cat", "jq", "grep", "head", "tail", "less", "stat", "find"}
READ_ONLY |= {"echo", "printf", "rg", "wc"}
FIND_ACTS = {"-exec", "-execdir", "-ok", "-okdir", "-delete", "-fls", "-fprint"}
FIND_ACTS |= {"-fprint0", "-fprintf"}
# sed and awk read too, unless sed -i, or their program or options name a stamp
# (sed w, awk print >): their valued options, and the ones that give the program.
SED_OPTS = ("efl", ("--expression", "--file", "--line-length"))
SED_PROGRAM = {"-e", "-f", "--expression", "--file"}
AWK_OPTS = (
    "fFvEile",
    ("--file", "--field-separator", "--assign", "--source", "--exec", "--include"),
)
AWK_PROGRAM = {"-f", "-e", "-E", "--file", "--source", "--exec"}
# Separators and interleaved options, so a subprocess argument list reads like
# the command line it becomes.
SEP = r"[\s\"',]+"
OPTS = rf"(?:{SEP}-[^\s\"',]+(?:{SEP}[^-\s\"',][^\s\"',]*)?)*"
# Owners a URL names: API paths and clone URLs. On a tea or git-obs command line
# its repository options and git-obs "owner/repo#N" ids name owners too. A
# value may be a Python f/b/r string, and hold {placeholders}: an owner that
# holds one is no literal owner.
URL_OWNER = (
    r"repos/([^/\s\"'`]+)/|src\.opensuse\.org(?::\d+)?[:/]+(?!api/)([^/\s\"'`]+)/"
)
API_OWNER = Rx(URL_OWNER)
PREFIX = r"(?:[bBrRuUfF]{1,2}(?=[\"']))?"
CMD_OWNER = Rx(
    URL_OWNER
    + rf"|(?<![\w-])(?:--repo|-r|--target)(?:={PREFIX}[\"']?|{SEP}{PREFIX}[\"']?)"
    r"([^/\s\"'`]+)/"
    rf"|(?<![\w-])--target-owner(?:={PREFIX}[\"']?|{SEP}{PREFIX}[\"']?)([^\s\"'`]+)"
    r"|(?<![\w/.~$-])([A-Za-z0-9{][\w.{}-]*)/(?:[\w.+-]|\{[^}\s]*\})+#(?:\d|\{)"
)
# A repository only the shell or the program knows is an unknown one.
VAR_REPOS = Rx(r"repos/(?:[\"'`$({]|\s*\+)")
VAR_OPT = Rx(
    r"(?<![\w-])(?:--repo|-r|--target|--target-owner|--target-repo)(?:=|\s+)"
    r"[\"']?[^\s\"']*[$`]"
)
VAR_WORD = Rx(r"(?:^|\s)(?!-)\S*[$`]")
VARIABLE = Rx(r"[$`]")
BARE_REPO = Rx(r"(?<![\w/.~$:-])([A-Za-z0-9][\w.-]*)/[\w.+-]+(?![\w/])")
LITERAL = Rx(r"[A-Za-z0-9][\w.-]*")
FORGE = Rx(r"(?i:src\.opensuse\.org)(?::\d+)?[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?/?$")


def tea(sub):
    return Rx(rf"\btea\b.*?(?<![-\w])(?:pr|pulls?)[\"']?{OPTS}{SEP}(?:{sub})(?![-\w])")


TEA_MERGE = tea("merge|m")
TEA_CREATE = tea("create|c")
TEA_API = Rx(r"\btea\b.*?(?<![-\w])api(?![-\w])")
# A method that is not a literal GET or HEAD: a write, or one the text hides.
METHOD = (
    r"(?:[=\s\"',]+)[\"']?(?!(?i:get|head)\b)[^\s\"',-]"
    r"|-X(?!(?i:get|head)\b)[A-Za-z$]"
)
TEA_WRITE = Rx(
    rf"(?<![\w-])(?:-[fFd](?![\w-])|--(?:field|Field|data)\b|(?:-X|--method){METHOD})"
)
# git-obs, also spelled "git obs" (git runs it as a subcommand).
GIT_OBS = Rx(
    rf"\bgit(?:-obs|[\"']?{OPTS}{SEP}obs)(?![-\w]).*?(?<![-\w])pr[\"']?{SEP}"
    r"(merge|create|forward)(?![-\w])"
)
GIT_OBS_TARGET = Rx(r"(?<![\w-])--(?:target|target-owner|self)\b")
MERGE_URL = Rx(r"/pulls/[^/\s\"']+/merge(?![-\w])")
DO_MERGE = Rx(r"[\"']Do[\"']\s*:|\bDo\s*=\s*[\"']")
# The API's pulls path, or one built from a variable. A web link to a PR
# (src.opensuse.org/pool/x/pulls/3) quoted in a comment is not an endpoint.
PULLS_REF = Rx(r"(?:repos/[^/\s\"'`]+/[^/\s\"'`]+|[})\"'`]|\$\w+)/pulls(?![-\w])")
# A write anywhere in the text: a write method, list-form short options, and
# the request calls of Python and JavaScript.
WRITE = Rx(
    r"(?:-X|--request|--method)[\s=\"',]*(?i:post|patch|put)\b"
    r"|[\"']-[dFT][\"']"
    r"|[(,]\s*data\s*=(?!=)|\.(?:post|patch|put)\s*\("
    r"|\bmethod\s*[=:]\s*[\"'](?i:post|patch|put)"
    r"|\bmethod\s*[=:]\s*(?!None\b)[A-Za-z_$({\[]"
)
# curl or wget on one line: a method that is not a literal GET, a form or file
# upload, or a body without -G (which turns the body into the query).
CURL = Rx(r"\b(?:curl|wget)\b")
CURL_METHOD = Rx(rf"(?<![\w-])(?:(?:-X|--request|--method){METHOD})")
CURL_FILE = Rx(r"(?<![\w-])-[a-zA-Z]*[FT](?=[\s\"'@{$]|$)")
CURL_BODY = Rx(r"(?<![\w-])-[a-zA-Z]*d(?=[\s\"'@{$]|$)")
CURL_GET = Rx(r"(?<![\w-])(?:-[a-zA-Z]*G[a-zA-Z]*|--get)(?![\w-])")
# Body options count on a curl, wget or tea api command only: elsewhere
# ("--json" of an argparse parser) they are a program's own flags.
BODY_LONG = Rx(
    r"(?<![\w-])--(?:data(?:-[a-z]+)?|json|form|upload-file|post-data|post-file)\b"
)
# The tool as one quoted element of an argument list, which may span lines.
ARGV_TOOL = Rx(r"[\"'](curl|wget|tea)[\"']")
# urllib's Request and urlopen take the body as the second argument; the
# request() of requests, httpx, urllib3 and http.client the method as the first.
CALL = Rx(r"(?:(?<!\w)(Request|urlopen)|\.(request))\(")
KWARG = Rx(r"\w+\s*=(?!=)")
QUOTED = Rx(r"[bruf]*([\"'])(.*)\1")
HTTPIE = {"http", "https", "xh", "xhs"}
HTTP_TOOLS = HTTPIE | {"curl", "wget"}
HTTPIE_VALUED = {
    "-a", "--auth", "-A", "--auth-type", "-o", "--output", "--session",
    "--session-read-only", "--cert", "--cert-key", "--cert-key-pass", "--proxy",
    "--timeout", "--max-redirects", "-p", "--print", "-P", "--history-print",
    "--pretty", "-s", "--style", "--verify", "--ssl", "--ciphers", "--boundary",
    "--default-scheme", "--format-options", "--response-charset", "--response-mime",
}  # fmt: skip
# A request item that sends data: field=value, field:=json, field@file.
HTTPIE_DATA = Rx(r"[^=:@\s]+(?::=|=(?!=)|@)")
PUSH = Rx(r"(?<![-\w])push(?![-\w])")
STASH_PUSH = Rx(r"\bstash\s+push\b")
PUSH_POOL = Rx(r"src\.opensuse\.org(?::\d+)?[:/]+pool/|refs\/for\/")
# git push spelled inside program text: judged only by a literal remote.
CODE_PUSH = Rx(
    r"[\"']git[\"']?[\s,]+(?:[\"']?-[Cc][\"']?[\s,]+[\"']?[^\"',\s]+[\"']?[\s,]+)*[\"']?push\b"
)
CODE_DIR = Rx(r"(?<![\w-])-C(?![\w-])|\bcwd\s*=|\bchdir\b")
CODE_ARG = Rx(r"[\s,]*([\"'])([^\"'\n]*)\1")
# The simple references a path word may carry: $NAME and ${NAME}.
VAR_REF = Rx(r"\$(?:\{(\w+)\}|(\w+))")
GLOB = Rx(r"[*?\[]")
# Short options of curl that take a value.
CURL_VALUED = set("EKCbcdDFPHhmoxUQreXYytzTuAw")
COPY_VALUED = {"cp": "tS", "mv": "tS", "install": "mogSt"}
COPY_LONG = {"--suffix", "--no-preserve", "--sparse", "--mode", "--owner", "--group"}
COPY_LONG |= {"--strip-program", "--target-directory"}
OSC_BUILD = Rx(r"\bosc\b.*?(?<![-\w.:/])(?:build|shell|chroot)(?![-\w.])(.*)")
ARCH = Rx(
    r"(?<![-\w./:])(x86_64|i[3-6]86|aarch64|armv[67][a-z]*l|ppc64(?:le)?|ppc|s390x"
    r"|riscv64|loong(?:arch)?64)(?![-\w./:])"
)
NATIVE = {"x86_64": {"x86_64", "i386", "i486", "i586", "i686"}}
OSC_REQUEST = Rx(
    r"\bosc\b.*?(?<![-\w])(?:sr|submitreq|submitrequest|submitpac|mr|maintenancerequest"
    r"|creq|createrequest)(?![-\w]).*?openSUSE:Backports:SLE-16"
)

HEREDOC = Rx(r"(?<!<)<<(-?)[ \t]*(?:\\([A-Za-z_][\w.-]*)|([\"']?)([A-Za-z_][\w.-]*)\3)")
SH_SHEBANG = Rx(r"#!\s*\S*/(?:env\s+)?(?:ba|z|da|k)?sh\b")
OPS = set(";&|()<>\n")
STDOUT = {">", ">>", ">|", "1>", "1>>", "1>|", "&>", "&>>"}
SEPS = Rx(r"\|\||\|&?|&&|;;&?|;&|[;&()\n]")
ASSIGN = Rx(r"[A-Za-z_]\w*\+?=")
URLISH = Rx(r"://|^[\w.-]+@[\w.-]+:|^[/.~]")
# Environment a canonical script would inherit from a plain assignment.
SENSITIVE = Rx(
    r"PATH|HOME|ENV|BASH_ENV|CDPATH|SHELLOPTS|BASHOPTS|IFS|LD_\w+|PYTHON\w*|PERL\w*"
    r"|NODE_\w+|GIT_\w+|XDG_\w+|OSC\w*|TEA_\w+|CURL_\w+|SSL_\w+|\w*_(?i:proxy)"
)
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
PYTHON = Rx(r"python[0-9.]*|pypy3?")
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"}
DECLARE = {"export", "declare", "typeset", "local", "readonly"}
WRAPPERS = {  # each with the options that take a value
    "command": "",
    "exec": "-a",
    "nohup": "",
    "time": "-f -o",
    "builtin": "",
    "setsid": "",
    "stdbuf": "-i -o -e",
    "nice": "-n",
    "ionice": "-c -n -p",
    "sudo": "-u -g -C -D -h -p -r -t -U",
    "doas": "-u -C",
    "xargs": "-I -n -P -d -a -E -L -s",
}
# Per interpreter, the letters of a short-option cluster: code = inline program
# (attached to the cluster, or the next word), module = runs no file, noexec =
# runs nothing, stdin = program on stdin, valued = takes the rest of the cluster
# or the next word, rest = takes the rest of the cluster, digits = takes the
# digits after it.
LANGS = {
    "shell": {"code": "c", "stdin": "s", "valued": "oO", "noexec": "n"},
    "python": {"code": "c", "attached": True, "module": "m", "valued": "WX"},
    "perl": {"code": "eE", "attached": True, "rest": "iMmIxFdD", "digits": "l0C"},
    "node": {"code": "ep", "valued": "r"},
}
LONG = {
    "shell": {"--rcfile": "value", "--init-file": "value"},
    "node": {
        "--eval": "code",
        "--print": "code",
        "--require": "value",
        "--import": "value",
        "--loader": "value",
        "--experimental-loader": "value",
    },
}
UV_RUN_VALUED = (
    "--with", "--with-requirements", "--with-editable", "--python", "-p", "--project",
    "--directory", "--package", "--extra", "--group", "--env-file", "--index",
    "--default-index", "-w",
)  # fmt: skip
DOCS = (".md", ".rst", ".txt", ".json", ".jsonc", ".changes")

ROUTE = (
    "pool PRs are opened and updated only by pool-pr.sh DIR, once target-gate.sh "
    "DIR is green and reviewed for that tree"
)
MESSAGES = {
    "merge": "{0}: agents never merge a pool PR, not even their own. Watch it "
    "instead: sr-status.py --pr pool/<pkg>#<n>.",
    "create": "{0}: " + ROUTE + ".",
    "push-pr-head": "{0}; a push moves that PR to a tree nobody built. " + ROUTE + ".",
    "push-pool": "{0} opens or moves a pool PR; " + ROUTE + ".",
    "push-unknown": "cannot tell where this push lands ({0}), so it is refused. "
    "Push from the clone to an explicit fork remote and a literal branch, or: "
    + ROUTE
    + ".",
    "stamp": "{0}: only target-gate.sh writes its stamps. Run target-gate.sh DIR "
    "--build (or --remote), then target-gate.sh DIR --review FILE.",
    "emulated-build": "{0}: that build is emulated, and builds are native only. "
    "For a foreign-arch proof run target-gate.sh DIR --remote.",
    "backports": "{0}: openSUSE:Backports:SLE-16.x is scmsync'd from pool and "
    "takes no requests; " + ROUTE + ".",
    "exec-unreadable": "cannot read {0} before it runs, so it is refused. Create "
    "the file in one call and run it in the next.",
    "exec-written": "{0} is written by this same call, so the guard would judge "
    "what it held before. Run it in a separate call so it can be read.",
    "exec-unresolved": "cannot tell which file {0} names, so it is refused. Run "
    "the script by a literal path.",
    "canonical-env": "{0}: the skill's scripts run unread only in the environment "
    "they were given. Drop the change (allowed: TMPDIR, LC_ALL, LANG, NO_COLOR) and "
    "pass values as arguments.",
    "canonical-read": "{0}: the skill's scripts find their siblings from their own "
    "path, so they are run by path (bash <skill>/scripts/NAME ...), never sourced "
    "or fed on stdin.",
}


class Blocked(Exception):
    def __init__(self, rule, kind, detail):
        super().__init__(detail)
        self.rule, self.kind, self.detail = rule, kind, detail

    def __str__(self):
        return f"pr-guard: BLOCKED [{self.rule}] " + MESSAGES[self.kind].format(
            self.detail
        )


def block(rule, detail, kind=None):
    kind = kind or (rule if rule in MESSAGES else rule.split("-", 1)[0])
    raise Blocked(rule, kind, detail)


def unsure(why):
    block("push-unknown", why, "push-unknown")


class Ctx:
    """Per-event state: the hook's cwd, remotes a command defines before it
    pushes, heredoc bodies, environment changes, variable values, the files the
    call writes, and memoised lookups."""

    def __init__(self, cwd):
        self.cwd = cwd
        self.remotes = {}
        self.prs = {}
        self.owners = {}
        self.scanned = set()
        self.canon = {}
        self.docs = []
        self.exported = []
        self.values = {}
        self.written = set()


def git(cwd, gargs, *args):
    """stdout of a local git query, or None when it fails."""
    import subprocess

    if not cwd:
        return None
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    try:
        r = subprocess.run(
            ["git", "-C", cwd, *gargs, *args],
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def remote_owners(ctx, cwd):
    """Owners of the src.opensuse.org remotes of cwd, counting remotes this
    call adds; tea and git-obs act on those when no repository is named."""
    if cwd not in ctx.owners:
        out = git(cwd, (), "remote", "-v")
        owners = set()
        for line in (out or "").splitlines():
            parts = line.split()
            m = FORGE.search(parts[1]) if len(parts) > 1 else None
            if m:
                owners.add(m.group(1).lower())
        ctx.owners[cwd] = owners
    added = [FORGE.search(u) for (d, _), u in ctx.remotes.items() if d == cwd]
    return ctx.owners[cwd] | {m.group(1).lower() for m in added if m}


def pool_or_unknown(text, ctx, cwd, cmd=False, extra=None):
    """False only when every owner the text names -- or, naming none, every
    remote of cwd -- is a literal owner other than pool. cmd: a tea or git-obs
    command line, whose repository options name owners too."""
    if VAR_REPOS.search(text) or (cmd and VAR_OPT.search(text)):
        return True
    found = [
        next(g for g in m.groups() if g)
        for m in (CMD_OWNER if cmd else API_OWNER).finditer(text)
    ]
    if extra is not None:
        found += extra.findall(text)
    if not found:
        owners = remote_owners(ctx, cwd)
        return not owners or "pool" in owners
    return any(o.lower() == "pool" or not LITERAL.fullmatch(o) for o in found)


def code_lines(text):
    return [
        ln
        for ln in text.replace("\\\n", " ").split("\n")
        if not ln.lstrip().startswith("#")
    ]


def tool_rules(ln, ctx, cwd):
    """tea and git-obs, on one command line or one line of a program."""
    if TEA_MERGE.search(ln) and pool_or_unknown(ln, ctx, cwd, cmd=True):
        block("merge-tea", "a tea PR merge on a pool (or unnamed) repository")
    m = GIT_OBS.search(ln)
    # A PR id or repository held in a variable names no owner.
    held = bool(m) and bool(VAR_WORD.search(ln[m.end() :]))
    if m and m.group(1) == "merge" and (held or pool_or_unknown(ln, ctx, cwd, True)):
        block("merge-git-obs", "a git-obs PR merge on a pool (or unnamed) repository")
    if m and m.group(1) == "create":
        if not GIT_OBS_TARGET.search(ln) or pool_or_unknown(ln, ctx, cwd, True):
            block("create-git-obs", "a git-obs PR create towards pool")
    if m and m.group(1) == "forward":
        if held or pool_or_unknown(ln, ctx, cwd, True, BARE_REPO):
            block("create-git-obs", "a git-obs PR forward on pool")
    if TEA_CREATE.search(ln) and pool_or_unknown(ln, ctx, cwd, cmd=True):
        block("create-tea", "a tea PR create on a pool (or unnamed) repository")
    if TEA_API.search(ln) and "pulls" in ln and TEA_WRITE.search(ln):
        if pool_or_unknown(ln, ctx, cwd, cmd=True):
            block("create-tea-api", "a tea api write to pool pulls")


def osc_rules(seg, request=None):
    """request: the command line without its request message, which only
    describes the request."""
    b = OSC_BUILD.search(seg)
    if b:
        import platform

        native = os.environ.get("PR_GUARD_ARCH") or platform.machine()
        for arch in ARCH.findall(b.group(1)):
            if arch not in NATIVE.get(native, {native}):
                block("emulated-build", f"an osc build for {arch} on {native}")
    if OSC_REQUEST.search(seg if request is None else request):
        block("backports", "an osc request to openSUSE:Backports:SLE-16.x")


def without_message(run):
    """An osc argv without the value of -m/--message."""
    out, i = [], 0
    while i < len(run):
        a = run[i]
        if a in ("-m", "--message"):
            i += 2
            continue
        if not (a.startswith("--message=") or a.startswith("-m") and len(a) > 2):
            out.append(a)
        i += 1
    return out


def call_args(text, i):
    """The top-level arguments of the call whose "(" ends at i."""
    args, cur, depth, q, end = [], [], 0, None, min(len(text), i + 2000)
    while i < end:
        c = text[i]
        if q:
            if c == "\\":
                cur.append(text[i : i + 2])
                i += 2
                continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif c == "," and depth == 0:
            args.append("".join(cur).strip())
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    last = "".join(cur).strip()
    return args + [last] if last else args


def writes(text):
    """Evidence of a request that is not a literal GET or HEAD."""
    if WRITE.search(text):
        return True
    for ln in text.split("\n"):
        m = CURL.search(ln)
        seg = re.split(r"[;&|]", ln[m.end() :])[0] if m else ""
        if m and (
            BODY_LONG.search(seg)
            or CURL_METHOD.search(seg)
            or CURL_FILE.search(seg)
            or (CURL_BODY.search(seg) and not CURL_GET.search(seg))
        ):
            return True
        m = TEA_API.search(ln)
        if m and BODY_LONG.search(re.split(r"[;&|]", ln[m.end() :])[0]):
            return True
    for m in ARGV_TOOL.finditer(text):
        seg = " ".join(call_args(text, m.end()))
        if m.group(1) != "tea" or re.match(r"[\s\"',]*api[\"']", seg):
            if BODY_LONG.search(seg):
                return True
    for m in CALL.finditer(text):
        pos = [a for a in call_args(text, m.end()) if not KWARG.match(a)]
        if m.group(1):
            if len(pos) >= 2:
                return True
            continue
        lit = QUOTED.fullmatch(pos[0]) if pos else None
        if pos and not lit:
            return True  # the method is a variable
        if (
            lit
            and lit.group(2).isalpha()
            and lit.group(2).upper() not in ("GET", "HEAD")
        ):
            return True
    return False


def httpie_writes(run):
    """HTTPie and xh: an explicit method, or request items that make a POST."""
    words, i = [], 1
    while i < len(run):
        a = run[i]
        if a == "--raw" or a.startswith("--raw="):
            return True
        if a in HTTPIE_VALUED:
            i += 2
            continue
        if not a.startswith("-"):
            words.append(a)
        i += 1
    if len(words) > 1 and re.fullmatch(r"[A-Z]+", words[0]):
        return words[0] not in ("GET", "HEAD", "OPTIONS")
    return any(HTTPIE_DATA.match(w) for w in words[1:])


def api_rules(text, ctx, cwd, write=False):
    """The pulls API: a merge, or any write, on a pool (or unknown) repository."""
    if MERGE_URL.search(text) or DO_MERGE.search(text):
        if pool_or_unknown(text, ctx, cwd):
            block("merge-api", "an API merge of a pool (or unnamed) PR")
    if PULLS_REF.search(text) and (write or writes(text)):
        if pool_or_unknown(text, ctx, cwd):
            block("create-api", "a write to pool pulls")


def line_rules(ln, ctx, cwd):
    """Rules one line of a program holds all the evidence for."""
    tool_rules(ln, ctx, cwd)
    for seg in re.split(r"[;&|]", ln):
        if PUSH.search(seg) and not STASH_PUSH.search(seg) and PUSH_POOL.search(seg):
            block("push-pool", "a push naming pool/ or AGit refs")
        osc_rules(seg)


def run_text(text, kind, ctx, cwd, depth):
    """A program read whole: inline code, or text fed to a shell or interpreter."""
    if kind == "shell":
        api_rules("\n".join(code_lines(text)), ctx, cwd)
        shell_pass(text, ctx, cwd, depth)
        return
    lines = code_lines(text)
    for ln in lines:
        line_rules(ln, ctx, cwd)
    whole = "\n".join(lines)
    api_rules(whole, ctx, cwd)
    if STAMP.search(whole):
        block("stamp", "program text touching the stamp directory")
    for m in CODE_PUSH.finditer(whole):
        if not other_forge(whole, m, ctx, cwd):
            unsure("a git push inside program text")


def other_forge(text, m, ctx, cwd):
    """Whether the git push matched at m names, as a literal, a remote that
    another forge hosts -- judged in cwd, so any directory change refuses."""
    if CODE_DIR.search(text):
        return False
    after, q = text[m.end() :], text[m.start()]
    if after[:1] in "\"'":  # an argument list: each argument its own literal
        args, at = [], 1
        a = CODE_ARG.match(after, at)
        while a:
            args.append(a.group(2))
            at = a.end()
            a = CODE_ARG.match(after, at)
    else:  # one command string: its words up to the closing quote
        end = after.find(q)
        args = after[:end].split() if end >= 0 else []
        if any(re.search(r"[${}%]", w) for w in args):
            return False
    remote = next((a for a in args if not a.startswith("-")), None)
    if not remote or not LITERAL.fullmatch(remote) and not URLISH.search(remote):
        return False
    url = (
        remote
        if URLISH.search(remote)
        else git(cwd, (), "remote", "get-url", "--push", remote)
    )
    return bool(url) and not FORGE.search(url)


def quoted(line, end):
    """Whether line[end] sits inside quotes opened earlier on the line."""
    q, i = None, 0
    while i < end:
        c = line[i]
        if c == "\\" and q != "'":
            i += 2
            continue
        if q:
            q = None if c == q else q
        elif c in "'\"":
            q = c
        i += 1
    return q is not None


def split_heredocs(text, ctx):
    """Text with each heredoc's delimiter replaced by a word "\\x01<n>" that
    names its body, kept as (body, expands) in ctx.docs."""
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        line = lines[i]
        i += 1
        # A << inside quotes is text: taking it for a heredoc would hide the
        # lines after it.
        ops = [m for m in HEREDOC.finditer(line) if not quoted(line, m.start())]
        parts, at = [], 0
        for m in ops:
            end, body = m.group(2) or m.group(4), []
            while i < len(lines):
                cur = lines[i].rstrip("\r")
                i += 1
                if (cur.lstrip("\t") if m.group(1) else cur) == end:
                    break
                body.append(cur)
            parts += [line[at : m.start()], f"<<\x01{len(ctx.docs)}"]
            at = m.end()
            ctx.docs.append(("\n".join(body), not (m.group(2) or m.group(3))))
        out.append("".join(parts) + line[at:])
    return "\n".join(out)


def strip_comments(text):
    """Drop shell comments: a # that starts a word, outside quotes."""
    out, q, i, n = [], None, 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\" and q != "'" and i + 1 < n:
            out.append(text[i : i + 2])
            i += 2
            continue
        if q:
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|()"):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def substitutions(text, quotes=True):
    """(text with each $(...), `...`, <(...) and >(...) replaced by a word only
    the shell can expand, their bodies). They run even inside double quotes,
    where the tokenizer sees one word; quotes=False reads an expanding heredoc
    body, where quote characters are literal."""
    out, bodies, q, i, n = [], [], None, 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\" and q != "'":
            out.append(text[i : i + 2])
            i += 2
            continue
        if q == "'":
            q = None if c == "'" else q
        elif quotes and c == "'" and q is None:
            q = c
        elif quotes and c == '"':
            q = None if q else c
        elif c == "`":
            j = i + 1
            while j < n and text[j] != "`":
                j += 2 if text[j] == "\\" else 1
            bodies.append(text[i + 1 : j])
            out.append("$__sub")
            i = j + 1
            continue
        elif text.startswith("$(", i) or (not q and text.startswith(("<(", ">("), i)):
            depth, j = 0, i + 1
            while j < n:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                if depth == 0:
                    break
                j += 1
            if not text.startswith("$((", i):  # $((...)) is arithmetic
                bodies.append(text[i + 2 : j])
            out.append("$__sub" if c == "$" else " /dev/fd/63 ")
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), bodies


def tokenize(text):
    import shlex

    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace, lex.whitespace_split, lex.commenters = " \t\r", True, ""
    try:
        return list(lex)
    except ValueError:  # unbalanced quotes: a rougher split still finds the words
        return re.findall(r"[;&|()<>\n]+|[^\s;&|()<>]+", text)


def arrays(tokens):
    """Tokens with each array literal, name=( ... ), joined into its assignment
    word: its parentheses open no subshell and its words run nothing."""
    out, i, n = [], 0, len(tokens)
    while i < n:
        tok = tokens[i]
        i += 1
        if not (
            tok[:1] == "(" and set(tok) <= OPS and out and ASSIGN.fullmatch(out[-1])
        ):
            out.append(tok)
            continue
        words, rest = [], tok[1:]
        while ")" not in rest and i < n:
            t = tokens[i]
            i += 1
            if t and set(t) <= OPS:
                rest = t
            else:
                words.append(t)
        out[-1] += "(" + " ".join(words) + ")"
        rest = rest[rest.find(")") + 1 :] if ")" in rest else ""
        if rest:
            out.append(rest)
    return out


def commands(tokens):
    """Yield "(", ")", "|", ";;" and (argv, redirections) per simple command;
    a redirection is (operator, word)."""
    argv, redirs, op = [], [], None
    for tok in tokens:
        if tok and set(tok) <= OPS:
            if "<" in tok or ">" in tok:
                # the fd of 2>&1 goes with its operator
                op = (argv.pop() if argv and argv[-1].isdigit() else "") + tok
                continue
            if argv or redirs:
                yield argv, redirs
            argv, redirs, op = [], [], None
            for sep in SEPS.findall(tok):
                if sep in ("(", ")", "|", "|&"):
                    yield sep[0]
                elif sep.startswith(";;") or sep == ";&":
                    yield ";;"
            continue
        if op is not None:
            redirs.append((op, tok))
            op = None
        else:
            argv.append(tok)
    if argv or redirs:
        yield argv, redirs


def resolve(raw, cwd):
    """(path, None); (None, None) for a path only the shell can expand; or
    (None, why) for a literal path that cannot be placed."""
    p = os.path.expanduser(re.sub(r"^\$\{?HOME\}?(?=/|$)", "~", raw))
    if re.search(r"[$`*?\[]", p):
        return None, None
    if not os.path.isabs(p):
        if not cwd:
            return None, "the working directory is unknown"
        p = os.path.join(cwd, p)
    return os.path.normpath(p), None


def substitute(word, ctx, cwd, seen=frozenset()):
    """Every spelling of word once its $NAME and ${NAME} are replaced by what
    this call assigned them (a for loop assigns each of its words), $PWD by
    the tracked directory, $TMPDIR and $HOME by the environment; None when
    anything else only the shell knows is left, or past 64 spellings."""
    m = VAR_REF.search(word)
    if not m:
        return None if VARIABLE.search(word) else [word]
    name = m.group(1) or m.group(2)
    if name in ctx.values:
        vals = ctx.values[name]
    elif name == "PWD":
        vals = [cwd] if cwd else None
    elif name in ("TMPDIR", "HOME"):
        vals = [os.environ[name]] if os.environ.get(name) else None
    else:
        vals = None
    if not vals or name in seen:
        return None
    tails = substitute(word[m.end() :], ctx, cwd, seen)
    out = []
    for v in vals:
        heads = substitute(v, ctx, cwd, seen | {name})
        if heads is None or tails is None:
            return None
        out += [word[: m.start()] + h + t for h in heads for t in tails]
    return out if len(out) <= 64 else None


def locate(raw, ctx, cwd):
    """(paths, None) for the files a word names, globs expanded in cwd as the
    shell would; (None, why) when a literal path cannot be placed; (None, None)
    when the word keeps something only the shell knows."""
    words = substitute(raw, ctx, cwd)
    if words is None:
        return None, None
    import glob

    paths = []
    for w in words:
        p = os.path.expanduser(w)
        if not os.path.isabs(p):
            if not cwd:
                return None, "the working directory is unknown"
            p = os.path.join(cwd, p)
        found = sorted(glob.glob(p)) if GLOB.search(p) else []
        paths += [os.path.normpath(f) for f in found or [p]]
    return paths, None


def written(real, ctx):
    return any(real == w or real.startswith(w + os.sep) for w in ctx.written)


def note_written(raw, ctx, cwd):
    """Remember a file (or a tree) the call writes; one only the shell can
    place is not remembered."""
    paths, _ = locate(raw, ctx, cwd)
    ctx.written.update(os.path.realpath(p) for p in paths or ())


def skill_dir():
    env = os.environ.get("PR_GUARD_SKILL_DIR")
    if env:
        return os.path.realpath(env)
    for cand in (
        "~/.claude/skills/opensuse-packaging",
        "~/.agents/skills/opensuse-packaging",
    ):
        if os.path.isdir(os.path.expanduser(cand)):
            return os.path.realpath(os.path.expanduser(cand))
    return None


def in_skill(real):
    """The skill checkout, when real is one of its scripts/; else None."""
    skill = skill_dir()
    scripts = os.path.realpath(os.path.join(skill, "scripts")) if skill else None
    return skill if scripts and real.startswith(scripts + os.sep) else None


def pinned(skill):
    """The files of the skill's scripts/ at the pinned ref, when every file
    that the index or the ref lists there matches its pinned blob on disk; else
    an empty set. The scripts run their siblings, so one edited file untrusts
    them all. Compared by blob hash of the bytes on disk (--no-filters: a clean
    filter would hash an edit to the pinned blob); `git diff` would trust an
    assume-unchanged index entry, and HEAD any local commit."""
    ref = os.environ.get("PR_GUARD_PIN_REF") or PIN_REF
    tree = git(skill, (), "ls-tree", "-r", "-z", ref, "--", "scripts")
    index = git(skill, (), "ls-files", "-s", "-z", "--", "scripts")
    if not tree or index is None:
        return set()
    blobs = {}
    for ent in filter(None, tree.split("\0")):
        meta, _, path = ent.partition("\t")
        blobs[path] = meta.split()[-1]
    tracked = {ent.partition("\t")[2] for ent in filter(None, index.split("\0"))}
    if tracked - set(blobs):
        return set()
    order = sorted(blobs)
    got = git(skill, (), "hash-object", "--no-filters", "--", *order)
    if got is None or got.split() != [blobs[p] for p in order]:
        return set()
    return set(order)


def canonical(real, skill, ctx):
    """A skill script, while its scripts/ matches the pinned ref and this call
    writes nothing there."""
    if skill not in ctx.canon:
        ctx.canon[skill] = pinned(skill)
    scripts = os.path.realpath(os.path.join(skill, "scripts"))
    if written(scripts, ctx) or any(
        w.startswith(scripts + os.sep) for w in ctx.written
    ):
        return False
    return os.path.relpath(real, skill) in ctx.canon[skill]


def scan_file(raw, kind, ctx, cwd, depth, env=(), run=False):
    """Read the scripts a word names when the command runs them; the command's
    own (depth 0) scripts must be readable now, or the call is refused. run:
    executed by its path, which it then sees as $0."""
    paths, why = locate(raw, ctx, cwd)
    if paths is None:
        if depth == 0:
            if why:
                block("exec-unreadable", f"{raw} ({why})")
            block("exec-unresolved", raw)
        return
    for path in paths:
        scan_path(path, raw, kind, ctx, cwd, depth, env, run)


def scan_path(path, raw, kind, ctx, cwd, depth, env, run):
    real = os.path.realpath(path)
    if written(real, ctx):
        block("exec-written", raw)
    if os.path.isdir(real):
        return
    skill = in_skill(real)
    if skill:
        if not run:
            block("canonical-read", f"{raw} read as a program")
        if canonical(real, skill, ctx):
            changed = [e for e in env if e not in CLEAN_ENV] + ctx.exported
            if changed:
                block("canonical-env", f"{raw} run with {', '.join(changed)}")
            return
    if real in ctx.scanned:
        return
    ctx.scanned.add(real)
    try:
        with open(real, "rb") as fh:
            data = fh.read(MAX_BYTES)
    except OSError as e:
        if depth == 0:
            block("exec-unreadable", f"{raw} ({e.strerror or e})")
        return
    if data.startswith(b"\x7fELF"):
        return
    text = data.decode("utf-8", "replace")
    if kind == "auto":
        kind = "shell" if real.endswith(".sh") or SH_SHEBANG.match(text) else "code"
    if kind == "code":
        run_text(text, kind, ctx, cwd, depth)
        return
    # A script's quoted strings are data (test fixtures quote the very commands
    # guarded here): its tool rules apply per parsed command, not per line.
    api_rules("\n".join(code_lines(text)), ctx, cwd)
    if depth < MAX_DEPTH:
        shell_pass(text, ctx, cwd, depth + 1)


def unwrap(argv):
    """Strip keywords, assignments and command wrappers: (argv, shell string or
    None, environment changes, the directory env -C moves to)."""
    changes, chdir, i, n = [], None, 0, len(argv)

    def skip(j, valued):
        while j < n and argv[j].startswith("-") and argv[j] != "-":
            if argv[j] == "--":
                return j + 1
            j += 2 if argv[j] in valued else 1
        return j

    while i < n:
        w, base = argv[i], os.path.basename(argv[i])
        if w in KEYWORDS:
            i += 1
        elif w == "function":
            i += 2
        elif ASSIGN.match(w):
            changes.append(w.split("=", 1)[0].rstrip("+"))
            i += 1
        elif base == "rtk":
            i = skip(i + 1, ())
            if i < n and argv[i] == "run":
                return [], " ".join(argv[i + 1 :]), changes, chdir
            if i < n and argv[i] in ("err", "test", "summary", "proxy"):
                i += 1
        elif base == "env":
            j = i + 1
            # env takes every NAME=VALUE before the command, identifier or not.
            while j < n and (argv[j].startswith("-") or "=" in argv[j]):
                a = argv[j]
                if a == "--":
                    j += 1
                    break
                if a in ("-S", "--split-string") and j + 1 < n:
                    return [], " ".join(argv[j + 1 :]), changes, chdir
                if a.startswith("-"):
                    changes.append("env " + a)
                    if a in ("-C", "--chdir") and j + 1 < n:
                        chdir = argv[j + 1]
                    j += 2 if a in ("-u", "-C", "--unset", "--chdir") else 1
                else:
                    changes.append(a.split("=", 1)[0])
                    j += 1
            i = j
        elif base == "uv" and argv[i + 1 : i + 2] == ["run"]:
            i = skip(i + 2, UV_RUN_VALUED)
            if i < n and argv[i].endswith(".py"):
                return ["python3"] + argv[i:], None, changes, chdir
        elif base == "timeout":
            i = skip(i + 1, ("-s", "-k", "--signal", "--kill-after")) + 1
        elif base in WRAPPERS:
            if base in ("sudo", "doas"):
                changes.append(base)
            i = skip(i + 1, WRAPPERS[base].split())
        else:
            break
    return argv[i:], None, changes, chdir


def note_env(run, ctx):
    """Remember an environment change a later canonical call would inherit."""
    name, args = os.path.basename(run[0]), run[1:]
    if name == "set":
        if "allexport" in args or any(re.fullmatch(r"-\w*a\w*", a) for a in args):
            ctx.exported.append("set -a")
        return
    opts = "".join(a[1:] for a in args if a.startswith("-"))
    if name != "export" and "x" not in opts or name == "export" and "n" in opts:
        return
    if "f" in opts:
        ctx.exported.append(f"{name} -f")
    names = [a.split("=", 1)[0].rstrip("+") for a in args if not a.startswith("-")]
    ctx.exported += [x for x in names if x not in CLEAN_ENV]


def interpreter(run, lang, stdin, env, ctx, cwd, depth):
    """Read what a shell or interpreter runs: inline code, its script file, or
    the program it takes on stdin."""
    spec, kind = LANGS[lang], "shell" if lang == "shell" else "code"
    codes, flag_c, from_stdin, inplace, i = [], False, False, False, 1
    while i < len(run):
        a = run[i]
        if a == "--":
            i += 1
            break
        if a == "-":
            from_stdin = True
            break
        if a.startswith("--"):
            opt, eq, val = a.partition("=")
            role = LONG.get(lang, {}).get(opt)
            if role == "code":
                codes.append(val if eq else " ".join(run[i + 1 : i + 2]))
            i += 1 if eq or not role else 2
            continue
        if len(a) < 2 or not (a[0] == "-" or a[0] == "+" and lang == "shell"):
            break
        i, j, code_next = i + 1, 1, False
        while j < len(a):
            ch, rest = a[j], a[j + 1 :]
            if ch in spec.get("code", ""):
                if lang == "shell":
                    flag_c = True
                elif spec.get("attached") and rest:
                    codes.append(rest)
                    break
                elif spec.get("attached"):
                    code_next = True
                    break
                else:
                    code_next = True
            elif ch in spec.get("module", "") or ch in spec.get("noexec", ""):
                return
            elif ch in spec.get("stdin", ""):
                from_stdin = True
            elif ch in spec.get("valued", ""):
                i += 0 if rest else 1
                break
            elif ch in spec.get("rest", ""):
                inplace = inplace or lang == "perl" and ch == "i"
                break
            elif ch in spec.get("digits", ""):
                j += 1 + len(re.match(r"x[0-9a-fA-F]+|[0-7]*", rest).group())
                continue
            j += 1
        if code_next:
            codes.append(" ".join(run[i : i + 1]))
            i += 1
        if codes and lang == "python":  # -c ends python's own options
            break
    operands = run[i:]
    if inplace:  # perl -i rewrites the files after its program
        for f in operands[0 if codes else 1 :]:
            note_written(f, ctx, cwd)
    if flag_c:
        codes.append(" ".join(operands[:1]))
    for code in codes:
        run_text(code, kind, ctx, cwd, depth)
    if codes:
        return
    if operands and not from_stdin:
        scan_file(operands[0], kind, ctx, cwd, depth, env, run=True)
    else:
        feed(stdin, kind, os.path.basename(run[0]), ctx, cwd, depth)


def feed(stdin, kind, name, ctx, cwd, depth):
    """The program a shell or interpreter reads from stdin."""
    if stdin is None:
        return
    how, what = stdin
    if how == "text":
        run_text(what, kind, ctx, cwd, depth)
    elif how == "files":
        for raw in what:
            scan_file(raw, kind, ctx, cwd, depth)
    elif depth == 0:
        block("exec-unreadable", f"the program {name} reads from {what}")


def output(name, args, stdin):
    """What echo, printf or cat write to a pipe: (kind, what) or None."""
    if name == "echo":
        while args and re.fullmatch(r"-[neE]+", args[0]):
            args = args[1:]
        return "text", " ".join(args).replace("\\n", "\n")
    if name == "printf":
        if not args or args[0] == "-v":
            return None
        rest = list(args[1:])
        text = re.sub(
            r"%%|%[-+ #0-9.]*[a-zA-Z]",
            lambda m: "%" if m.group() == "%%" else (rest.pop(0) if rest else ""),
            args[0],
        )
        text += "".join(" " + r for r in rest)
        return "text", text.replace("\\n", "\n").replace("\\t", "\t")
    files = [a for a in args if a == "-" or not a.startswith("-")]
    if not files or files == ["-"]:
        return stdin
    return "files", [f for f in files if f != "-"]


def check_push(args, ctx, cwd, gargs, send=False):
    """git push, or git send-pack (send), judged by the branches it updates on
    the remote it names."""
    pos, every, remote, i = [], False, None, 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos += args[i + 1 :]
            break
        if a in ("-o", "--push-option", "--receive-pack", "--exec", "--repo"):
            if a == "--repo" and i + 1 < len(args):
                remote = args[i + 1]
            i += 2
            continue
        if a.startswith("--repo="):
            remote = a[len("--repo=") :]
        elif a in ("--all", "--mirror", "--branches") or send and a == "--stdin":
            every = True
        elif not a.startswith("-"):
            pos.append(a)
        i += 1
    if pos:
        remote, specs = pos[0], pos[1:]
    else:
        specs = []
    if any(PUSH_POOL.search(a) for a in args):
        block("push-pool", "a push naming pool/ or AGit refs")
    if remote and URLISH.search(remote):
        url = remote
    else:
        if not cwd:
            unsure("the working directory is unknown")
        remote = remote or push_remote(cwd, gargs)
        url = ctx.remotes.get((cwd, remote)) or git(
            cwd, gargs, "remote", "get-url", "--push", remote
        )
        if not url:
            unsure(f"no remote {remote!r} in {cwd}")
    m = FORGE.search(url)
    if not m:
        return  # another forge
    owner, repo = m.group(1).lower(), m.group(2)
    if owner == "pool":
        block("push-pool", f"a push to {url}")
    if not (LITERAL.fullmatch(owner) and LITERAL.fullmatch(repo)):
        unsure(f"{url} is named by a variable")
    if any(VARIABLE.search(s) for s in specs):
        unsure("the pushed branch is held in a variable")
    # A pattern or a matching push (":", send-pack without refs, push.default
    # matching) is judged like --all, by every local branch.
    every = every or any("*" in s or s.lstrip("+") == ":" for s in specs)
    dst = None
    if not every and not specs:
        dst = None if send else push_branch(cwd, gargs, remote)
        every = send or dst == "*"
    if every:
        out = git(cwd, gargs, "for-each-ref", "--format=%(refname:short)", "refs/heads")
        if out is None:
            unsure("cannot list the local branches")
        dsts = set(out.split())
    elif specs:
        dsts = {destination(s, cwd, gargs) for s in specs}
    else:
        dsts = {dst}
    if None in dsts:
        unsure("cannot tell which branch it updates")
    for pr in open_pool_prs(ctx, repo):
        head = pr.get("head") or {}
        login = ((head.get("repo") or {}).get("owner") or {}).get("login") or ""
        if login.lower() == owner and head.get("ref") in dsts:
            block(
                "push-pr-head",
                f"{owner}:{head.get('ref')} heads open PR pool/{repo}#{pr.get('number')}",
            )


def current_branch(cwd, gargs):
    return git(cwd, gargs, "symbolic-ref", "--short", "-q", "HEAD") if cwd else None


def destination(spec, cwd, gargs):
    s = spec.lstrip("+")
    dst = s.split(":", 1)[1] if ":" in s else s
    if dst in ("", "HEAD", "@"):
        return current_branch(cwd, gargs)
    return dst[len("refs/heads/") :] if dst.startswith("refs/heads/") else dst


def push_remote(cwd, gargs):
    cur = current_branch(cwd, gargs)
    keys = [f"branch.{cur}.pushRemote"] if cur else []
    keys += ["remote.pushDefault"] + ([f"branch.{cur}.remote"] if cur else [])
    for key in keys:
        val = git(cwd, gargs, "config", "--get", key)
        if val:
            return val
    return "origin"


def push_branch(cwd, gargs, remote):
    """The remote branch a push without a refspec updates, "*" for every
    matching one, or None."""
    if git(cwd, gargs, "config", "--get-all", f"remote.{remote}.push"):
        return None  # configured refspecs: not worth second-guessing
    mode = git(cwd, gargs, "config", "--get", "push.default") or "simple"
    if mode == "matching":
        return "*"
    out = git(
        cwd, gargs, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{push}"
    )
    if out and out.startswith(remote + "/"):
        return out[len(remote) + 1 :]
    # @{push} needs the remote-tracking ref; a fresh clone has none.
    cur = current_branch(cwd, gargs)
    if cur and mode in ("upstream", "tracking"):
        merge = git(cwd, gargs, "config", "--get", f"branch.{cur}.merge")
        if merge:
            return (
                merge[len("refs/heads/") :]
                if merge.startswith("refs/heads/")
                else merge
            )
    return cur


def open_pool_prs(ctx, repo):
    """Open PRs of pool/<repo>; a 404 means there is no such pool repository.
    Any other failure refuses: an empty answer must not read as "no PR"."""
    import urllib.error
    import urllib.parse
    import urllib.request

    if repo in ctx.prs:
        return ctx.prs[repo]
    stub = os.environ.get("PR_GUARD_PULLS_DIR")
    try:
        if stub:
            path = os.path.join(stub, repo + ".json")
            data = []
            if os.path.exists(path):
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
        else:
            url = f"{GITEA}/repos/pool/{urllib.parse.quote(repo)}/pulls?state=open&limit=50"
            try:
                with urllib.request.urlopen(url, timeout=15) as r:
                    data = json.load(r)
            except urllib.error.HTTPError as e:
                if e.code != 404:
                    raise
                data = []
    except (OSError, ValueError) as e:
        unsure(f"could not list the open PRs of pool/{repo}: {e}")
    if not isinstance(data, list) or not all(isinstance(p, dict) for p in data):
        unsure(f"unexpected open-PR list for pool/{repo}")
    if len(data) >= 50:
        unsure(f"pool/{repo} has 50+ open PRs, the lookup cannot rule this branch out")
    ctx.prs[repo] = data
    return data


def git_command(argv, ctx, cwd):
    i, gargs = 1, []
    while i < len(argv) and argv[i].startswith("-"):
        a = argv[i]
        if a == "-C" and i + 1 < len(argv):
            cwd = resolve(argv[i + 1], cwd)[0]
            i += 2
        elif a in ("-c", "--git-dir", "--work-tree", "--namespace", "--config-env"):
            gargs += argv[i : i + 2]
            i += 2
        else:
            if a.startswith(
                ("--git-dir=", "--work-tree=", "--namespace=", "--config-env=")
            ):
                gargs.append(a)
            i += 1
    sub = argv[i:]
    if sub[:1] in (["push"], ["send-pack"]):
        check_push(sub[1:], ctx, cwd, gargs, send=sub[0] == "send-pack")
    elif sub[:1] == ["obs"]:
        ln = " ".join(["git-obs", *sub[1:]])
        tool_rules(ln, ctx, cwd)
        api_rules(ln, ctx, cwd)
    elif sub[:1] == ["remote"] and sub[1:2] in (["add"], ["set-url"]):
        pos, j = [], 2
        while j < len(sub):
            if sub[j] in ("-t", "-m"):
                j += 2
                continue
            if not sub[j].startswith("-"):
                pos.append(sub[j])
            j += 1
        if len(pos) >= 2:
            ctx.remotes[(cwd, pos[0])] = pos[1]


def guess(run, ctx, cwd):
    """A command whose name only the shell knows, judged as each guarded tool."""
    rest = run[1:]
    tool_rules(" ".join(["tea", *rest]), ctx, cwd)
    tool_rules(" ".join(["git-obs", *rest]), ctx, cwd)
    api_rules(" ".join(["curl", *rest]), ctx, cwd)
    if rest[:1] in (["push"], ["obs"]):
        git_command(["git", *rest], ctx, cwd)


def parse_opts(args, valued, long_valued=()):
    """(options as (flag, value), operands) of a getopt-style argument list;
    valued: the short options that take a value, long_valued the long ones."""
    opts, pos, i = [], [], 0
    while i < len(args):
        a = args[i]
        i += 1
        if a == "--":
            pos += args[i:]
            break
        if a.startswith("--"):
            k, eq, v = a.partition("=")
            if not eq and k in long_valued and i < len(args):
                v, i = args[i], i + 1
            opts.append((k, v))
        elif a.startswith("-") and len(a) > 1:
            for j in range(1, len(a)):
                if a[j] in valued:
                    v = a[j + 1 :]
                    if not v and i < len(args):
                        v, i = args[i], i + 1
                    opts.append(("-" + a[j], v))
                    break
                opts.append(("-" + a[j], ""))
        else:
            pos.append(a)
    return opts, pos


def note_writes(name, args, ctx, cwd):
    """Remember the files tee, cp, mv, install, sed -i and curl -o/-O write."""
    dests = []
    if name == "tee":
        dests = parse_opts(args, "")[1]
    elif name in COPY_VALUED:
        opts, pos = parse_opts(args, COPY_VALUED[name], COPY_LONG)
        flags = dict(opts)
        into = flags.get("-t", flags.get("--target-directory"))
        if name == "install" and ("-d" in flags or "--directory" in flags):
            dests = pos
        elif into is None and len(pos) >= 2:
            pos, into = pos[:-1], pos[-1]
            whole = "-T" in flags or "--no-target-directory" in flags
            isdir = any(map(os.path.isdir, locate(into, ctx, cwd)[0] or ()))
            if whole or not (len(pos) > 1 or into.endswith("/") or isdir):
                pos, dests = [], [into]
        if into is not None:
            dests += [os.path.join(into, os.path.basename(s.rstrip("/"))) for s in pos]
    elif name == "sed":
        opts, pos = parse_opts(args, "efl", ("--expression", "--file", "--line-length"))
        flags = {k for k, _ in opts}
        if flags & {"-i", "--in-place"}:
            given = flags & {"-e", "-f", "--expression", "--file"}
            dests = pos if given else pos[1:]
    elif name == "curl":
        import urllib.parse

        opts, pos = parse_opts(args, CURL_VALUED, ("--output", "--output-dir"))
        dests = [v for k, v in opts if k in ("-o", "--output") and v != "-"]
        if {k for k, _ in opts} & {"-O", "--remote-name", "--remote-name-all"}:
            dests += [
                os.path.basename(urllib.parse.urlsplit(u).path)
                for u in pos
                if "://" in u
            ]
        into = [v for k, v in opts if k == "--output-dir"]
        dests = [os.path.join(into[-1], d) if into else d for d in dests if d]
    for d in dests:
        note_written(d, ctx, cwd)


def git_dir(raw, ctx, cwd):
    """Whether raw names a git directory: one named *.git, one holding HEAD and
    objects/, or one only the shell can place."""
    for p in substitute(raw, ctx, cwd) or [None]:
        path = None if p is None else resolve(p.rstrip("/") or "/", cwd)[0]
        if path is None or path.endswith(".git"):
            return True
        if os.path.isfile(os.path.join(path, "HEAD")) and os.path.isdir(
            os.path.join(path, "objects")
        ):
            return True
    return False


def in_stamps(text, ctx, cwd):
    """Whether text names a target-gate component directly under a git
    directory; with no path before it, that directory is cwd."""
    for m in STAMP_WORD.finditer(text):
        s = m.start()
        if s and text[s - 1] == "/":
            if git_dir(PARENT.search(text[: s - 1]).group(), ctx, cwd):
                return True
        elif not cwd or git_dir(cwd, ctx, cwd):
            return True
    return False


def held(word, ctx, seen=frozenset()):
    """The values this call gave the variables a word names, and theirs, as
    written: a value built on a substitution never expands, yet names a path."""
    out = []
    for a, b in VAR_REF.findall(word):
        name = a or b
        if name not in seen:
            for v in ctx.values.get(name, ()):
                out += [v, *held(v, ctx, seen | {name})]
    return out


def stamp_word(word, ctx, cwd, path=False):
    """Whether a word names the stamp directory -- as written, by what its
    variables were given, once expanded, and (path) once placed in cwd, which
    may itself lie inside it."""
    words = [word, *held(word, ctx), *(substitute(word, ctx, cwd) or ())]
    if path:
        words += locate(word, ctx, cwd)[0] or ()
    return any(in_stamps(w, ctx, cwd) for w in words)


def pinned_gate(name, run, ctx, cwd):
    """Whether this runs the skill's target-gate.sh by path while it matches
    the pinned ref."""
    word = run[0] if name == "target-gate.sh" else ""
    if name in SHELLS and len(run) > 1:
        word = run[1]
    if "/" not in word or os.path.basename(word) != "target-gate.sh":
        return False
    paths = locate(word, ctx, cwd)[0] or []
    real = os.path.realpath(paths[0]) if len(paths) == 1 else ""
    skill = in_skill(real)
    return bool(skill) and canonical(real, skill, ctx)


def reads_only(name, run, ctx, cwd):
    """A look that writes no file: a read-only tool; sed without -i, and awk,
    whose program and options name no stamp; python -m json.tool without an
    output file."""
    args = run[1:]
    if name in READ_ONLY:
        return not (name == "find" and FIND_ACTS.intersection(run))
    if name in ("sed", "awk", "gawk", "mawk"):
        valued, long_valued = SED_OPTS if name == "sed" else AWK_OPTS
        opts, pos = parse_opts(args, valued, long_valued)
        flags = {k for k, _ in opts}
        if name == "sed" and flags & {"-i", "--in-place"}:
            return False
        given = flags & (SED_PROGRAM if name == "sed" else AWK_PROGRAM)
        files = set(pos[0 if given else 1 :])
        return not any(stamp_word(a, ctx, cwd) for a in args if a not in files)
    if PYTHON.fullmatch(name) and args[:1] in (["-m"], ["-mjson.tool"]):
        rest = args[1:] if args[0] == "-mjson.tool" else args[2:]
        if args[0] == "-m" and args[1:2] != ["json.tool"]:
            return False
        return len(parse_opts(rest, "", ("--indent",))[1]) <= 1
    return False


# The working directory after a cd whose target the guard cannot place but
# which names the stamp directory: in_stamps() reads it as inside one.
STAMP_CWD = "/unresolved.git/target-gate"


def enter(target, ctx, cwd):
    """The directory cd/pushd/env -C moves to, or STAMP_CWD when only the
    shell can place it and it names the stamp directory."""
    new = resolve(target, cwd)[0]
    if new is None and stamp_word(target, ctx, cwd):
        return STAMP_CWD
    return new


def touches_stamp(name, run, outs, ctx, cwd):
    """A command that names the stamp directory, or runs inside it -- but the
    pinned target-gate.sh, a look that writes no file, and git's arguments,
    which are text (branch names, messages, grep patterns)."""
    if pinned_gate(name, run, ctx, cwd):
        return False
    if all(t == "/dev/null" for t in outs) and reads_only(name, run, ctx, cwd):
        return False
    if cwd and in_stamps(cwd, ctx, cwd):
        return True
    if name == "git":
        return False
    declared = name in DECLARE
    return any(
        stamp_word(a, ctx, cwd) for a in run if not (declared and ASSIGN.match(a))
    )


def one_command(argv, redirs, stdin, ctx, cwd, depth):
    """Check one simple command: (the working directory after it, what it
    writes to a pipe)."""
    outs = [
        t
        for op, t in redirs
        if ">" in op and not (op.endswith("&") and (t.isdigit() or t == "-"))
    ]
    for t in outs:
        if stamp_word(t, ctx, cwd, path=True):
            block("stamp", "a redirection into the stamp directory")
        note_written(t, ctx, cwd)
    run, shell, env, chdir = unwrap(argv)
    if not run and shell is None:
        # Assignments alone: the shell keeps them, and its children see those
        # of names already in the environment.
        for a in filter(ASSIGN.match, argv):
            k, v = a.split("=", 1)
            k = k.rstrip("+")
            ctx.values.setdefault(k, []).append(v)
            if k not in CLEAN_ENV and (k in os.environ or SENSITIVE.fullmatch(k)):
                ctx.exported.append(k)
        return cwd, None
    here = cwd if chdir is None else enter(chdir, ctx, cwd)
    if shell is not None:
        shell_pass(shell, ctx, here, depth)
        return cwd, ("unknown", "a wrapper")
    name = os.path.basename(run[0])
    out = ("unknown", name)
    joined = " ".join(run)
    if name in ("cd", "pushd"):
        rest = [a for a in run[1:] if a not in ("-L", "-P", "-e", "-@")]
        new = None if rest[:1] == ["-"] else enter(rest[0] if rest else "~", ctx, cwd)
        return new, None
    if name == "popd":
        return None, None
    if name == "for":
        if run[2:3] == ["in"]:
            ctx.values.setdefault(run[1], []).extend(run[3:])
        return cwd, None
    if touches_stamp(name, run, outs, ctx, here):
        block("stamp", "a command touching the stamp directory")
    note_writes(name, run[1:], ctx, here)
    if name in DECLARE or name == "set":
        note_env(run, ctx)
        for a in filter(ASSIGN.match, run[1:] if name in DECLARE else ()):
            k, v = a.split("=", 1)
            ctx.values.setdefault(k.rstrip("+"), []).append(v)
    elif VARIABLE.search(name):
        # A path held in a variable is read; a command name, judged as a tool.
        held = substitute(run[0], ctx, here)
        if held and all("/" in h for h in held):
            scan_file(run[0], "auto", ctx, here, depth, env, run=True)
        else:
            guess(run, ctx, here)
    elif name == "tea":
        tool_rules(joined, ctx, here)
    elif name == "git-obs":
        tool_rules(joined, ctx, here)
        api_rules(joined, ctx, here)
    elif name == "git":
        git_command(run, ctx, here)
    elif name == "osc":
        osc_rules(joined, " ".join(without_message(run)))
    elif name in HTTP_TOOLS:
        # A URL held in a variable this call assigned is judged by its value.
        held = [
            v for k in re.findall(r"\$\{?(\w+)", joined) for v in ctx.values.get(k, ())
        ]
        text = " ".join([joined, *held])
        api_rules(text, ctx, here, write=name in HTTPIE and httpie_writes(run))
    elif name == "eval":
        run_text(" ".join(run[1:]), "shell", ctx, here, depth)
    elif name in SHELLS:
        interpreter(run, "shell", stdin, env, ctx, here, depth)
    elif PYTHON.fullmatch(name):
        interpreter(run, "python", stdin, env, ctx, here, depth)
    elif name in ("node", "nodejs", "perl"):
        interpreter(run, name.replace("nodejs", "node"), stdin, env, ctx, here, depth)
    elif name in ("source", ".") and len(run) > 1:
        scan_file(run[1], "shell", ctx, here, depth)
    elif "/" in run[0]:
        scan_file(run[0], "auto", ctx, here, depth, env, run=True)
    elif name in ("echo", "printf", "cat"):
        out = output(name, run[1:], stdin)
    if any(op in STDOUT or op in (">&", "1>&") and t != "1" for op, t in redirs):
        out = None
    return cwd, out


def shell_pass(text, ctx, cwd, depth):
    """Walk the simple commands of shell text, following cd, subshells, and
    pipes into a shell or interpreter."""
    first = len(ctx.docs)
    body = split_heredocs(text, ctx)
    for doc, expands in ctx.docs[first:]:
        if expands:
            for inner in substitutions(doc, quotes=False)[1]:
                shell_pass(inner, ctx, cwd, depth)
    body, inners = substitutions(strip_comments(body.replace("\\\n", " ")))
    for inner in inners:
        shell_pass(inner, ctx, cwd, depth)
    stack, out, piped, case, pattern = [], None, None, 0, False
    for item in commands(arrays(tokenize(body))):
        head = [w for w in item[0] if w not in KEYWORDS][:1] if len(item) == 2 else []
        # A case clause's patterns, up to its ")", are words, not commands.
        if pattern:
            if item == ")" or head == ["esac"]:
                pattern, case = False, case - (head == ["esac"])
            continue
        if head in (["case"], ["esac"]):
            case += 1 if head == ["case"] else -1
            pattern = head == ["case"]
        elif item == ";;":
            pattern = case > 0
        elif item == "|":
            piped = out
        elif item == "(":
            stack.append(cwd)
        elif item == ")":
            cwd = stack.pop() if stack else cwd
            out = ("unknown", "a subshell")
        else:
            argv, redirs = item
            stdin, piped = piped, None
            for op, word in redirs:
                if op == "<<" and word[:1] == "\x01" and word[1:].isdigit():
                    stdin = ("text", ctx.docs[int(word[1:])][0])
                elif op == "<<<":
                    stdin = ("text", word)
                elif op == "<":
                    stdin = ("files", [word])
            cwd, out = one_command(argv, redirs, stdin, ctx, cwd, depth)


def check_write(path, content, ctx):
    if STAMP.search(path.replace(os.sep, "/")):
        block("stamp-write", f"a write to {path}", "stamp")
    # Docs quote the wrong forms on purpose; scripts are where a POST hides.
    if not path.lower().endswith(DOCS):
        lines = "\n".join(code_lines(content))
        for rx, rule, what in (
            (TEA_MERGE, "merge-tea", "a tea PR merge"),
            (TEA_CREATE, "create-tea", "a tea PR create"),
        ):
            for ln in lines.split("\n"):
                if rx.search(ln) and pool_or_unknown(ln, ctx, ctx.cwd, cmd=True):
                    block(rule, f"a script running {what} on pool")
        if MERGE_URL.search(lines) or DO_MERGE.search(lines):
            if pool_or_unknown(lines, ctx, ctx.cwd):
                block("merge-api", "a script merging a pool (or unnamed) PR")
        if PULLS_REF.search(lines) and writes(lines):
            if pool_or_unknown(lines, ctx, ctx.cwd):
                block("create-api", "a script writing to pool pulls")


def judge(ev):
    """Why one tool-call event is refused, or None when it is allowed. Anything
    it raises refuses the call too: the caller fails closed."""
    inp = ev.get("tool_input") if isinstance(ev, dict) else None
    if not isinstance(inp, dict):
        return None
    cwd = ev.get("cwd") if isinstance(ev.get("cwd"), str) and ev.get("cwd") else None
    ctx = Ctx(cwd)
    try:
        if isinstance(inp.get("command"), str):
            shell_pass(inp["command"], ctx, cwd, 0)
        elif isinstance(inp.get("file_path"), str):
            body = inp.get("content", inp.get("new_string"))
            check_write(inp["file_path"], body if isinstance(body, str) else "", ctx)
    except Blocked as b:
        return str(b)
    return None
