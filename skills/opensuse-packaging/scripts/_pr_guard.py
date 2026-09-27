"""_pr_guard.py -- the rules of pr-guard.py, which compiles this file only once
a call has matched its prefilter. Not a command: see pr-guard.py --help."""

import json
import os
import re

GITEA = "https://src.opensuse.org/api/v1"
PIN_REF = "refs/remotes/origin/main"
CLEAN_ENV = {"TMPDIR", "LC_ALL", "LANG", "NO_COLOR", "CHANGES_AUTHOR"}
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


# Program text splits an argument list any way (['tea'] + ['pr', 'merge']).
WSEP = r"[\s\"',\[\]()+]+"
WOPTS = rf"(?:{WSEP}-[^\s\"',\[\]()+]+(?:{WSEP}[^-\s\"',\[\]()+][^\s\"',\[\]()+]*)?)*"


def tea(sub):
    """Patterns of tea's pr/pulls subcommand sub: for program text, anywhere
    after tea; for a command line, matched from its start over options only,
    so a description or comment that quotes one is text."""
    return (
        Rx(rf"\btea\b.*?(?<![-\w])(?:pr|pulls?)[\"']?{WOPTS}{WSEP}(?:{sub})(?![-\w])"),
        Rx(
            rf"\btea\b[\"']?{OPTS}{SEP}(?:pr|pulls?)[\"']?{OPTS}{SEP}(?:{sub})(?![-\w])"
        ),
    )


TEA_MERGE, TEA_MERGE_ARGV = tea("merge|m")
TEA_CREATE, TEA_CREATE_ARGV = tea("create|c")
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
DO_MERGE = Rx(
    r"(?i)[\"']Do[\"']\s*:|\bDo\s*=\s*[\"']"
)  # Go reads JSON keys in any case
# OBS's request creation, which osc sr and friends wrap with the devel-project
# check and a message.
REQUEST_CREATE = Rx(r"/request/?\?(?:[^\s\"'#]*&)?cmd=create(?![\w-])")
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
GUARDED = HTTP_TOOLS | {"tea", "git-obs", "git", "osc"}
HTTPIE_VALUED = {
    "-a", "--auth", "-A", "--auth-type", "-o", "--output", "--session",
    "--session-read-only", "--cert", "--cert-key", "--cert-key-pass", "--proxy",
    "--timeout", "--max-redirects", "-p", "--print", "-P", "--history-print",
    "--pretty", "-s", "--style", "--verify", "--ssl", "--ciphers", "--boundary",
    "--default-scheme", "--format-options", "--response-charset", "--response-mime",
}  # fmt: skip
# A request item that sends data: field=value, field:=json, field@file.
HTTPIE_DATA = Rx(r"[^=:@\s]+(?::=|=(?!=)|@)")
# What a call to curl, tea api or git-obs api may carry and still provably
# only read: its short flags, the short options that take a value, its long
# flags and the long options that take a value. Anything else may send a body
# or another method; the method option itself must say GET or HEAD, a header
# must not override it.
READ_OPTS = {
    "curl": (
        "sSfLiIvkqG0O46ngNR#",
        "owmHuAexrYyE",
        "silent show-error fail fail-with-body location include head verbose "
        "insecure compressed get no-progress-meter progress-bar http1.1 http2 "
        "create-dirs remote-name ipv4 ipv6 netrc globoff no-buffer remote-time",
        "output write-out max-time header user user-agent referer proxy "
        "connect-timeout retry retry-delay retry-max-time cacert capath cert key "
        "output-dir url dump-header netrc-file noproxy",
    ),
    "tea": ("ih", "HloRr", "include debug vvv help", "header output login repo remote"),
    "git-obs": ("qh", "G", "quiet help", "gitea-config gitea-login"),
}
METHOD_OPT = {"curl": "--request", "tea": "--method", "git-obs": "--method"}
# git-obs is argparse: a long option may be any unique prefix of its name.
GIT_OBS_LONG = ("--quiet", "--help", "--gitea-config", "--gitea-login", "--method")
GIT_OBS_LONG += ("--data",)
# wget's options that send a body, set the method, or run wgetrc commands that
# may; getopt takes any unique prefix of them.
WGET_WRITES = ("post-data", "post-file", "body-data", "body-file", "method")
WGET_WRITES += ("execute", "config")
WGET_VALUED = "oaOtTwUPQBDiARlIX"  # its short options that take a value
GET = ("GET", "HEAD")
# In program text, anything that may make a request send a body or another
# method: a merge URL near none of them is a GET.
MAY_WRITE = Rx(
    r"(?i:\b(?:data|json|body|form|files|fields?|method|post|put|patch|delete"
    r"|upload)\b)|(?<![\w-])-[a-zA-Z]*[XdFTf]|--(?:request|method|data|json|form"
    r"|upload|post|body|field)|\b(?:urlopen|open|Request|request|fetch|send)\s*\([^()]*,"
)
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
# --nodevelproject, or a prefix argparse expands to it, on a submit request.
NODEVEL = "|".join("--nodevelproject"[:n] for n in range(5, 17))
OSC_NODEVEL = Rx(
    r"\bosc\b.*?(?<![-\w])(?:sr|submitreq|submitrequest|submitpac|creq|createrequest)"
    rf"(?![-\w]).*?(?<![-\w])(?:{NODEVEL})(?![-\w])"
)
# A maintenance or update project, which takes no direct write; one under
# home: is the user's own branch, whatever its name ends in.
MAINT_PRJ = Rx(r"(?!home:)\S+:(?:Update|Maintenance(?::\S*)?)")
# The project an API path writes into: its sources, or its builds.
SOURCE_PRJ = Rx(r"(?:^|/)(?:source|build)/([^/?#\s]+)")
# POST cmds that write nothing into the project named: osc diffs, lists links
# and branches (into home:, unless target_project says otherwise) by them.
READ_CMDS = {"diff", "showlinked", "branch"}
# osc 1.27.3's long options: global ones, and those of the subcommands whose
# operands the guard reads (with the short ones that take a value) -- the ones
# that take a value, then ";" and the rest; argparse takes any unique prefix.
OSC_GLOBAL = "apiurl config setopt; debug debugger help http-debug http-full-debug "
OSC_GLOBAL += "no-keyring no-pager post-mortem quiet traceback verbose"
OSC_OPTS = {
    "commit": (
        "mF",
        "message file; no-message force skip-local-service-run noservice no-service",
    ),
    "api": ("XmdTfa", "method data file add-header; edit"),
    "copypac": (
        "rtm",
        "revision to-apiurl message; client-side-copy keep-maintainers keep-link "
        "keep-develproject expand",
    ),
    "linkpac": (
        "Cr",
        "cicount revision; current force disable-build disable-publish new-package",
    ),
    "aggregatepac": ("m", "map-repo; nosources disable-publish"),
    "rdelete": ("m", "message; recursive force"),
    "undelete": ("m", "message;"),
    "meta": (
        "aFrms",
        "attribute file revision message set add; attribute-defaults "
        "attribute-project blame force edit create remove-linking-repositories delete",
    ),
}
OSC_OPTS.update(
    {
        "branch": (
            "mr",
            "message revision linkrev add-repositories-block add-repositories-rebuild; "
            "nodevelproject checkout force add-repositories extend-package-names "
            "noaccess maintenance new-package disable-build",
        ),
        "rremove": ("", "; force"),
        "setdevelproject": ("", "; unset"),
        "setlinkrev": ("r", "revision vrev; use-plain-revision unset"),
        "detachbranch": ("m", "message;"),
        "linktobranch": ("", ";"),
        "lock": ("m", "message;"),
        "release": (
            "ar",
            "arch repo target-project target-repository set-release; no-delay",
        ),
        "wipebinaries": (
            "aMr",
            "arch multibuild-package repo; build-disabled build-failed broken "
            "unresolvable all",
        ),
        "rmkpac": ("", "scmsync; force"),
        "repo": ("", "repo arch path; disable-publish yes"),
        "updatepacmetafromspec": ("", "specfile;"),
        "unlock": ("m", "message;"),
        "mbranch": (
            "au",
            "attribute update-project-attribute; checkout dryrun noaccess "
            "nodevelproject version",
        ),
        "addchannels": ("", "; skip-disabled enable-all"),
        "addcontainers": ("", "; extend-package-names"),
    }
)
OSC_ALIAS = {"ci": "commit", "checkin": "commit", "bco": "branch", "branchco": "branch"}
OSC_ALIAS.update(
    {"getpac": "branch", "sdp": "setdevelproject", "unpublish": "wipebinaries"}
)
OSC_ALIAS.update(
    {
        "metafromspec": "updatepacmetafromspec",
        "updatepkgmetafromspec": "updatepacmetafromspec",
    }
)
REQUESTS = {"sr", "submitreq", "submitrequest", "submitpac", "creq", "createrequest"}
REQUESTS |= {"mr", "maintenancerequest", "deletereq", "deleterequest", "dr"}
REQUESTS |= {"droprequest", "dropreq", "changedevelrequest", "changedevelreq", "cr"}
# Their long options that take a value (osc 1.27.3), and the -F files that
# are stdin.
REQUEST_VALUED = tuple(
    "--" + o
    for o in "message file revision supersede action attribute release-project "
    "incident incident-project repository accept-in-hours apiurl config setopt".split()
)
STDIN = ("-", "/dev/stdin")
# printf's conversions (with any flags, width or precision), and a brace
# expansion echo or printf would print expanded.
PRINTF_CONV = Rx(r"%(?!%)([-+ #0]*)([0-9*]*(?:\.[0-9*]*)?)[a-zA-Z]")
# A command position that runs its arguments, or expands to several words:
# "$@", "$*", ${A[@]}.
ARGS_RUN = Rx(r"\$[@*1]|\$\{[@*1]\}")
ARRAY_ALL = Rx(r"\$[@*]|\$\{[@*]\}|\$\{(\w+)\[[@*]\]\}")
BRACES = Rx(r"\{[^{}\s]*(?:,|\.\.)[^{}\s]*\}")
# A $ or backtick the shell takes literally (single quotes, $'...', a
# backslash), as the literal-aware text of substitutions(lit=True) spells it.
LIT_CHARS = {"$": "\x02", "`": "\x03"}
UNLITERAL = str.maketrans({v: k for k, v in LIT_CHARS.items()})
ANSI_C = Rx(r"\\(x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|[0-7]{1,3}|.)")
ANSI_ESC = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f"}
ANSI_ESC.update({"v": "\v", "e": "\x1b", "E": "\x1b"})
# The word a command substitution leaves, naming its output in ctx.subs.
SUB_WORD = Rx(r"\$__sub(\d+)")

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
# find's actions that run a command, which ends at ";" or "+" (the -dir ones in
# each match's directory); GNU parallel's options that take a value, and the
# placeholders find and parallel fill in.
FIND_EXEC = {"-exec", "-execdir", "-ok", "-okdir"}
PARALLEL_VALUED = (
    "-j", "-N", "-n", "-I", "-S", "-a", "-L", "-l", "-P", "-E", "-d", "-C", "-s",
    "--jobs", "--colsep", "--arg-file", "--delay", "--timeout", "--joblog",
    "--results", "--tmpdir", "--workdir", "--sshlogin", "--basefile", "--env",
    "--tagstring", "--retries", "--memfree", "--load", "--max-args",
    "--max-replace-args", "--max-lines", "--max-chars",
)  # fmt: skip
PLACEHOLDER = Rx(r"\{[\d./#%]*\}")
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
    "merge": "{0}: agents never merge a PR, not even their own. Watch it "
    "instead: sr-status.py --pr <owner>/<pkg>#<n>.",
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
    "nodevelproject": "{0}: the option overrides osc's devel-project check, and "
    "factory-auto declines a Factory request whose source is not the devel "
    "project. Submit from the devel project.",
    "request-api": "{0}: file requests with osc (osc sr ... -s ID supersedes "
    "exactly one), which checks the devel project and the message.",
    "maintenance": "{0}: no direct writes into maintenance/update projects — use "
    "osc mbranch + osc mr.",
    "maintenance-unknown": "cannot tell where {0} lands, so it is refused. Run it in "
    "the checkout, or name the checkout or the project literally.",
    "request-message": "{0}: keep it to 1–3 sentences (≤300 characters of prose); "
    'a list may follow as "- " lines of ≤100 characters, 1000 in all.',
    "request-unknown": "cannot tell where {0} goes, so it is refused. Name its "
    "projects literally, or set them in this call.",
    "command-unknown": "cannot tell which command {0} runs, so it is refused. Name "
    "the command literally.",
    "request-message-unknown": "cannot read {0} now, so it is refused. Pass the "
    "message inline or from a readable file.",
    "exec-unreadable": "cannot read {0} before it runs, so it is refused. Create "
    "the file in one call and run it in the next.",
    "exec-written": "{0} is written by this same call, so the guard would judge "
    "what it held before. Run it in a separate call so it can be read.",
    "exec-unresolved": "cannot tell which file {0} names, so it is refused. Run "
    "the script by a literal path.",
    "canonical-env": "{0}: the skill's scripts run unread only in the environment "
    "they were given. Drop the change (allowed: TMPDIR, LC_ALL, LANG, NO_COLOR, "
    "CHANGES_AUTHOR) and pass values as arguments.",
    "canonical-read": "{0}: the skill's scripts find their siblings from their own "
    "path, so they are run by path (bash <skill>/scripts/NAME ...), never sourced "
    "or fed on stdin.",
}


# Credentials a message may echo from a remote URL or a command: a URL's
# password (or a token as its user), an Authorization value, a token= value.
SECRETS = (
    (Rx(r"(://[^/\s:@]*:)[^/\s@]+@"), r"\1[REDACTED]@"),
    (Rx(r"(://)[\w-]{20,}@"), r"\1[REDACTED]@"),
    (
        Rx(
            r"(?i)(\b(?:authorization:\s*(?:(?:token|bearer|basic)\s+)?|token\s+"
            r"|bearer\s+))[^\s\"'`]+"
        ),
        r"\1[REDACTED]",
    ),
    (Rx(r"(?i)(token=)[^\s&\"'`]+"), r"\1[REDACTED]"),
)


def redact(text):
    for rx, repl in SECRETS:
        text = rx.sub(repl, text)
    return text


class Blocked(Exception):
    def __init__(self, rule, kind, detail):
        super().__init__(detail)
        self.rule, self.kind, self.detail = rule, kind, detail

    def __str__(self):
        return redact(
            f"pr-guard: BLOCKED [{self.rule}] "
            + MESSAGES[self.kind].format(self.detail)
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
        self.lit_values = {}  # the values, as literal-aware text
        self.wrappers = set()  # functions that run their arguments ("$@")
        self.in_function = 0  # inside a function body, where "$@" is its arguments
        self.subs = []  # what each command substitution writes, as literal-aware text


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


def tool_rules(ln, ctx, cwd, argv=False):
    """tea and git-obs, on one command line or one line of a program. argv:
    a command line, whose tea subcommand is its first word after options."""
    merge, create = (
        (TEA_MERGE_ARGV, TEA_CREATE_ARGV) if argv else (TEA_MERGE, TEA_CREATE)
    )
    tea = "match" if argv else "search"
    if getattr(merge, tea)(ln):
        block("merge-tea", "a tea PR merge")
    m = GIT_OBS.search(ln)
    # A PR id or repository held in a variable names no owner.
    held = bool(m) and bool(VAR_WORD.search(ln[m.end() :]))
    if m and m.group(1) == "merge":
        block("merge-git-obs", "a git-obs PR merge")
    if m and m.group(1) == "create":
        if not GIT_OBS_TARGET.search(ln) or pool_or_unknown(ln, ctx, cwd, True):
            block("create-git-obs", "a git-obs PR create towards pool")
    if m and m.group(1) == "forward":
        if held or pool_or_unknown(ln, ctx, cwd, True, BARE_REPO):
            block("create-git-obs", "a git-obs PR forward on pool")
    if getattr(create, tea)(ln) and pool_or_unknown(ln, ctx, cwd, cmd=True):
        block("create-tea", "a tea PR create on a pool (or unnamed) repository")
    if not argv:  # a command line's own call is judged by its options
        tea_api_merge(ln, ctx, cwd)
    if TEA_API.search(ln) and "pulls" in ln and TEA_WRITE.search(ln):
        if pool_or_unknown(ln, ctx, cwd, cmd=True):
            block("create-tea-api", "a tea api write to pool pulls")


def tea_api_merge(ln, ctx, cwd, reads=None):
    """A tea api call on a merge URL: on a pool (or unknown) repository, or
    one that does not provably only read."""
    ln = norm_urls(ln)
    if TEA_API.search(ln) and MERGE_URL.search(ln):
        if pool_or_unknown(ln, ctx, cwd, cmd=True) or not (
            code_reads(ln) if reads is None else reads
        ):
            block("merge-api", "an API merge of a PR")


def expansions(words, ctx, cwd):
    """The spellings of the words that hold variables this call set."""
    return [
        e for w in words if VARIABLE.search(w) for e in substitute(w, ctx, cwd) or ()
    ]


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
    if OSC_NODEVEL.search(seg if request is None else request):
        block("nodevelproject", "an osc request with --nodevelproject")


def long_prefix(a, names):
    """a with a long option given by an unambiguous prefix, as argparse takes
    it, written out in full."""
    k, eq, v = a.partition("=")
    hits = [n for n in names if n.startswith(k)] if a[:2] == "--" and k[2:] else []
    return hits[0] + eq + v if len(hits) == 1 else a


def without_message(run):
    """An osc argv without the value of -m/--message."""
    out, i = [], 0
    while i < len(run):
        a = long_prefix(run[i], ("--message",))
        if a in ("-m", "--message"):
            i += 2
            continue
        if not (a.startswith("--message=") or a.startswith("-m") and len(a) > 2):
            out.append(a)
        i += 1
    return out


def request_args(run, ctx, cwd):
    """osc_rules on an osc command line and on the values its variables hold
    (a loop's words included); a request whose non-message argument holds a
    value only the shell knows is refused: where it goes is unknown."""
    rest = without_message(run)
    extra, unknown = [], None
    for k, a in enumerate(rest[1:], 1):
        if not VARIABLE.search(a) or rest[k - 1] in ("-F", "--file"):
            continue  # a literal, or the message file request_message() reads
        spellings = substitute(a, ctx, cwd)
        if spellings is None:  # unknown, or past 64 spellings: each value then
            names = [x or y for x, y in VAR_REF.findall(a)]
            if VARIABLE.search(VAR_REF.sub("", a)) or not all(
                ctx.values.get(n) for n in names
            ):
                unknown = unknown or a
            spellings = [v for n in names for v in ctx.values.get(n, ())]
        extra += spellings
    osc_rules(" ".join([*run, *extra]), " ".join([*rest, *extra]))
    sub = osc_sub(rest)[0]
    if sub in REQUESTS and unknown:
        block("request-unknown", f"osc {sub} {shown(unknown)}")


def request_message(run, lit, ctx, cwd):
    """A request message too long for its reviewers, or one that cannot be
    read now. lit: the argv as literal-aware text and the stdin of the call.
    -m of other subcommands is a commit message, or osc api's method."""
    sub, args = osc_sub(run)
    if sub not in REQUESTS:
        return
    largv, lstdin = lit or (None, None)
    if largv is not None and len(largv) >= len(args):
        args = largv[len(largv) - len(args) :]
    else:  # no literal-aware text: any $ or backtick is unknown
        args = [literal(a) if not VARIABLE.search(a) else a for a in args]
    args = [long_prefix(a, ("--message", "--file")) for a in args]
    for flag, word in parse_opts(args, "mFrsaA", REQUEST_VALUED)[0]:
        if flag not in ("-m", "--message", "-F", "--file"):
            continue
        is_file = flag in ("-F", "--file")
        texts = [word]
        if is_file:
            names = lit_texts(word, ctx, cwd) or [None]
            outs = [lstdin if f in STDIN else f and ("files", [f]) for f in names]
            texts = [t for o in outs for t in piped(o, ctx, cwd) or [None]]
        texts = [lit_texts(t, ctx, cwd) if t is not None else None for t in texts]
        texts = None if None in texts else [t for ts in texts for t in ts]
        if texts is None and not is_file:  # too many spellings: fine if all short
            top = lit_texts(word, ctx, cwd, longest=True)
            texts = top if top and len(top[0].strip()) <= 100 else None
        if texts is None:
            what = "a command substitution" if SUB_WORD.search(word) else word
            what = ("stdin" if word in STDIN else f"-F {word}") if is_file else what
            what = what.translate(UNLITERAL)
            block("request-message-unknown", f"the osc {sub} message ({what})")
        for fault in filter(None, map(message_fault, texts)):
            block("request-message", f"an osc {sub} message {fault}")


def message_fault(text):
    """Why a request message is too long for its reviewers, or None: over 300
    characters of prose (every line that is not a "- " list item, wherever it
    sits), a list item over 100, or over 1000 characters in all."""
    lines = text.strip().split("\n")
    prose = "\n".join(ln for ln in lines if not ln.startswith("- ")).strip()
    if len(prose) > 300:
        return f"with {len(prose)} characters of prose"
    item = max((len(ln) for ln in lines if ln.startswith("- ")), default=0)
    if item > 100:
        return f"with a {item}-character list line"
    if len(text.strip()) > 1000:
        return f"of {len(text.strip())} characters"
    return None


def literal(text):
    """text with every $ and backtick literal."""
    return text.translate(str.maketrans(LIT_CHARS))


def lit_texts(text, ctx, cwd, seen=frozenset(), longest=False):
    """Every text a literal-aware word or text stands for, its $NAME, ${NAME}
    and command substitutions expanded from what this call set; None when
    anything it expands is not known, or past 64 spellings. longest: only
    the longest spelling."""
    m = VAR_REF.search(text)
    if not m or VARIABLE.search(text[: m.start()]):
        return None if VARIABLE.search(text) else [text.translate(UNLITERAL)]
    name = m.group(1) or m.group(2)
    sub = re.fullmatch(r"__sub(\d+)", name)
    if name in seen:
        return None
    if sub and int(sub.group(1)) < len(ctx.subs):
        vals = sub_texts(ctx.subs[int(sub.group(1))], ctx, cwd)
    elif name in ctx.lit_values:
        vals = ctx.lit_values[name]
    elif name in ("PWD", "TMPDIR", "HOME"):
        vals = substitute("$" + name, ctx, cwd)
        vals = vals and [literal(v) for v in vals]
    else:
        vals = None
    tails = lit_texts(text[m.end() :], ctx, cwd, seen, longest)
    if not vals or None in vals or tails is None:
        return None
    out = []
    for v in vals:
        heads = lit_texts(v, ctx, cwd, seen | {name}, longest)
        if heads is None:
            return None
        out += [
            text[: m.start()].translate(UNLITERAL) + h + t for h in heads for t in tails
        ]
    if longest:
        return [max(out, key=len)]
    return out if len(out) <= 64 else None


def sub_texts(writers, ctx, cwd):
    """The literal-aware texts a command substitution's writers put out,
    joined in order; None when one of them cannot be read now."""
    texts = [""]
    for out in writers or ():
        got = piped(out, ctx, cwd)
        if got is None or len(texts) * len(got) > 64:
            return None
        texts = [t + g for t in texts for g in got]
    return [t.rstrip("\n") for t in texts] if writers else None


def piped(out, ctx, cwd):
    """The literal-aware texts a command writes to a pipe (what output() says
    it writes), read now; None when they cannot be."""
    how, what = out or (None, None)
    if how == "text":
        return [what]
    if how != "files":
        return None
    text = ""
    for raw in what:
        for path in locate(raw, ctx, cwd)[0] or [None]:
            real = path and os.path.realpath(path)
            if not real or written(real, ctx) or real.startswith(("/dev/", "/proc/")):
                return None
            try:
                with open(real, "rb") as fh:
                    text += literal(fh.read(MAX_BYTES).decode("utf-8", "replace"))
            except OSError:
                return None
    return [text]


def osc_projects(raw, what, ctx, cwd):
    """The projects an osc checkout path (a checkout, or a file in one) names
    in its .osc/_project -- in each directory a loop's cd may leave. Refused
    when a path cannot be placed, or holds no .osc/_project (one the call
    checks out itself, or no checkout): unless its own components name a
    maintenance project, it is unknown."""
    dirs = cwd.dirs if isinstance(cwd, Dirs) else [cwd]
    got = [locate(raw, ctx, d) for d in dirs]
    why = next((w for p, w in got if p is None), False)
    if why is not False:
        block(
            "maintenance-unknown", f"{what} {shown(raw)}" + (f" ({why})" if why else "")
        )
    prjs = []
    for path in (p for paths, _ in got for p in paths):
        d = path if os.path.isdir(path) else os.path.dirname(path)
        try:
            with open(os.path.join(d, ".osc", "_project"), encoding="utf-8") as fh:
                prjs.append(fh.read().strip())
        except OSError:
            prjs += list(filter(MAINT_PRJ.fullmatch, path.split(os.sep)))[:1] or [None]
    if None in prjs and not any(p and MAINT_PRJ.fullmatch(p) for p in prjs):
        block(
            "maintenance-unknown",
            f"{what} {shown(raw)} (no .osc/_project there: check out in one call, "
            "commit in the next)",
        )
    return prjs


def long_names(spec):
    """(long options that take a value, all long options) of an OSC_* spec."""
    valued, _, flags = spec.partition(";")
    valued = ["--" + o for o in valued.split()]
    return valued, valued + ["--" + o for o in flags.split()]


def osc_sub(run):
    """(subcommand, its arguments) of an osc argv."""
    valued, names = long_names(OSC_GLOBAL)
    i = 1
    while i < len(run) and run[i].startswith("-"):
        i += 2 if long_prefix(run[i], names) in ("-A", *valued) else 1
    return (run[i], run[i + 1 :]) if i < len(run) else (None, [])


def osc_args(sub, args):
    """(options as (flag, value), operands) of the arguments of an OSC_OPTS
    subcommand, which may carry osc's global options too."""
    short, spec = OSC_OPTS[sub]
    valued, names = long_names(spec)
    gvalued, gnames = long_names(OSC_GLOBAL)
    args = [long_prefix(a, names + gnames) for a in args]
    return parse_opts(args, short + "A", valued + gvalued)


def shown(word):
    return SUB_WORD.sub("$(...)", word)


def osc_writes(run, ctx, cwd):
    """osc writes into a maintenance or update project, or into one the guard
    cannot place: commit, api, and the project arguments of osc_target()."""
    sub, args = osc_sub(run)
    sub = OSC_ALIAS.get(sub, sub)
    if sub not in OSC_OPTS:
        return
    opts, pos = osc_args(sub, args)
    if sub in ("commit", "updatepacmetafromspec"):  # checkouts, by their paths
        rule = "maintenance-commit" if sub == "commit" else "maintenance-write"
        for raw in pos or ["."]:
            for prj in osc_projects(raw, f"osc {sub}", ctx, cwd):
                if prj and MAINT_PRJ.fullmatch(prj):
                    block(rule, f"an osc {sub} into {prj}")
        return
    if sub != "api":
        for target in filter(None, osc_targets(sub, pos, opts)):
            if target == ".":
                prjs = [p for p in osc_projects(".", f"osc {sub} to", ctx, cwd) if p]
            else:
                prjs = substitute(target, ctx, cwd)
                if prjs is None:
                    block("maintenance-unknown", f"osc {sub} to {shown(target)}")
            for prj in filter(MAINT_PRJ.fullmatch, prjs):
                block("maintenance-write", f"an osc {sub} into {prj}")
        return
    keys = {k for k, _ in opts}
    method = ([v for k, v in opts if k in ("-X", "-m", "--method")] or ["GET"])[-1]
    # As osc: a file uploads by PUT, and --edit PUTs what it fetched.
    if method == "GET" and keys & {"-T", "-f", "--file"} or keys & {"-e", "--edit"}:
        method = "PUT"
    if method.upper() in ("GET", "HEAD"):
        return
    for a in pos:
        urls = substitute(a, ctx, cwd)
        if urls is None and api_segment(a) is None:
            block("maintenance-unknown", f"osc api {method} {shown(a)}")
        for url in urls or [a]:
            for prj in api_targets(method, url):
                if VARIABLE.search(prj):
                    block("maintenance-unknown", f"osc api {method} {shown(a)}")
                if MAINT_PRJ.fullmatch(prj):
                    block("maintenance-api", f"an osc api {method} into {prj}")


def osc_targets(sub, pos, opts):
    """The projects an osc write names, "." for the checkout's: the
    destination of copypac, linkpac, aggregatepac and branch (from a
    checkout, linkpac's operands are the destination), release's project and
    --target-project, the project of meta prj|pkg with -F or -e, and the one
    of the rest (rdelete, rremove, setdevelproject, lock ...). Empty when the
    call writes into nothing it names."""
    keys = {k for k, _ in opts}

    def project(args):  # osc's PROJECT PACKAGE, or PROJECT/PACKAGE
        a = args.pop(0) if args else None
        if a and a.count("/") != 1 and args:
            args.pop(0)
        return a and a.split("/")[0]

    words = [w for p in pos for w in p.strip("/").split("/")]  # osc's slash_split
    if sub == "meta":
        if words[:1] not in (["prj"], ["pkg"]):
            return []
        if not keys & {"-F", "--file", "-e", "--edit"}:
            return []
        rest = words[1:]
        return [rest[0] if len(rest) > (words[0] == "pkg") else "."]
    if sub == "branch":
        return words[2:3]
    if sub in ("copypac", "linkpac", "aggregatepac"):
        rest = list(pos)
        project(rest)
        return [project(rest) or project(list(pos))]
    if sub == "setdevelproject" and (
        len(pos) < 2 or len(pos) == 2 and "/" not in pos[0]
    ):
        return ["."]  # the devel project is what it names
    if sub == "release":
        return [project(list(pos)) or "."] + [
            v for k, v in opts if k == "--target-project"
        ]
    if sub in ("rdelete", "undelete", "rremove", "lock", "rmkpac"):
        return [project(list(pos))]
    if sub == "repo":  # add or remove change the project's meta; list reads it
        return (
            [project(pos[1:]) or "."]
            if pos[:1] in (["add"], ["remove"], ["rm"])
            else []
        )
    if sub == "mbranch":  # a second operand is the project it branches into
        return pos[1:2]
    return [project(list(pos)) or "."]


def api_segment(url):
    """The first path segment of an API URL (or path), when the text before
    the first $ or backtick spells it out whole; else None."""
    head = re.split(r"[$`]", url)[0]
    if "://" in head:
        head = head.split("://", 1)[1].partition("/")[2] if "/" in head[8:] else ""
    parts = re.sub(r"/+", "/", head).lstrip("/").split("/")
    return parts[0] if len(parts) > 1 else None


def api_targets(method, url):
    """The projects an osc api write to url writes into."""
    import posixpath
    import urllib.parse

    if "://" in url:
        parts = urllib.parse.urlsplit(url)
        path, query = parts.path, parts.query
    else:  # a path, which may start with // (osc prefixes the API URL)
        path, _, query = url.partition("#")[0].partition("?")
    path = posixpath.normpath(re.sub(r"/+", "/", urllib.parse.unquote(path)) or "/")
    query = urllib.parse.parse_qs(query)
    cmds = query.get("cmd", [])
    if method.upper() == "POST" and cmds and set(cmds) <= READ_CMDS:
        return query.get("target_project", []) if "branch" in cmds else []
    return [m.group(1) for m in SOURCE_PRJ.finditer(path)]


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


def httpie_reads(run, stdin):
    """Whether an HTTPie or xh call provably only reads: no request item that
    sends data, and an explicit GET or HEAD -- or no stdin it would send as a
    body (--ignore-stdin, nothing piped in)."""
    if httpie_writes(run):
        return False
    words = [a for a in run[1:] if a[:1] != "-"]
    ignore = "--ignore-stdin" in run or "-I" in run
    return words[:1] in (["GET"], ["HEAD"]) or ignore and stdin is None


def curl_reads(args):
    """Whether a curl call provably only reads: -q (--disable) first, so no
    curlrc adds a method or body, and only_reads()."""
    first = args[0] if args else ""
    no_rc = first == "--disable" or re.fullmatch(r"-q[a-zA-Z]*", first)
    return bool(no_rc) and only_reads("curl", args)


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


def only_reads(tool, args, names=()):
    """Whether a curl, tea api or git-obs api call provably only reads: each
    option one of READ_OPTS, its method GET or HEAD. names: the long options a
    prefix may stand for."""
    flags, valued, lflags, lvalued = READ_OPTS[tool]
    method = METHOD_OPT[tool]
    i = 0
    while i < len(args):
        a = args[i]
        i += 1
        if a == "--":
            break
        if a[:1] != "-" or a == "-":
            continue
        if a[:2] == "--":
            k, eq, v = long_prefix(a, names).partition("=")
            if k[2:] in lflags.split() and not eq:
                continue
            if k != method and k[2:] not in lvalued.split():
                return False
            if not eq:
                v, i = (args[i] if i < len(args) else ""), i + 1
        else:
            j = 1
            while j < len(a) and a[j] in flags:
                j += 1
            if j == len(a):
                continue
            if a[j] != "X" and a[j] not in valued:
                return False
            k, v = ("--method" if a[j] == "X" else a[j]), a[j + 1 :].lstrip("=")
            if not v:
                v, i = (args[i] if i < len(args) else ""), i + 1
        if k in (method, "--method") and v.upper() not in ("GET", "HEAD"):
            return False
        if k in ("H", "--header") and "method" in v.lower():
            return False
    return True


def wget_reads(args):
    """Whether a wget call provably only reads: its wgetrc off (--no-config),
    and no option that sends a body, sets a method other than GET or HEAD, or
    runs wgetrc commands (-e)."""
    if "--no-config" not in args:
        return False
    for a in args:
        k, _, v = a.partition("=")
        if a[:2] == "--" and len(k) > 2:
            for w in WGET_WRITES:
                if w.startswith(k[2:]) and not (w == "method" and v.upper() in GET):
                    return False
        elif a[:1] == "-":
            for c in a[1:]:
                if c == "e":
                    return False
                if c in WGET_VALUED:
                    break
    return True


def code_reads(text):
    """Whether program text provably only reads: a curl or wget on a merge
    URL's line only reads by its options, and the text shows no other sign of
    a write at all."""
    if writes(text):
        return False
    other = False
    for ln in text.split("\n"):
        m = CURL.search(ln) if MERGE_URL.search(ln) else None
        if m:
            args = re.findall(r"[^\s\"',\[\]()]+", re.split(r"[;&|]", ln[m.end() :])[0])
            if not (curl_reads(args) if m.group() == "curl" else wget_reads(args)):
                return False
        else:
            other = True
    return not (other and MAY_WRITE.search(text))


def norm_urls(text):
    """text for the URL rules: percent-encoding decoded, runs of / collapsed
    (a scheme's // kept), dot segments removed."""
    import urllib.parse

    text = re.sub(r"(?<!:)//+", "/", urllib.parse.unquote(text))
    end = r"(?=/|[?#\s\"'`]|$)"
    prev = None
    while prev != text:
        prev = text
        text = re.sub(rf"/\.{end}", "", text)
        text = re.sub(rf"/[^/\s\"'`?#]+/\.\.{end}", "", text)
    return text


def api_rules(text, ctx, cwd, write=False, reads=None):
    """The pulls API: a merge -- a merge payload; a merge URL on a pool (or
    unknown) repository, however it is sent; elsewhere one in a call that
    does not provably only read (reads: that proof for a command line;
    program text must show no sign of a write) -- or any write to pool (or
    unknown) pulls. URLs are judged normalised (norm_urls)."""
    text = norm_urls(text)
    if REQUEST_CREATE.search(text):
        block("request-api", "a request created through the API")
    if (
        DO_MERGE.search(text)
        or MERGE_URL.search(text)
        and (
            pool_or_unknown(text, ctx, cwd)
            or not (code_reads(text) if reads is None else reads)
        )
    ):
        block("merge-api", "an API merge of a PR")
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


def substitutions(text, quotes=True, base=0, lit=False):
    """(text with each $(...), `...`, <(...) and >(...) replaced by a word only
    the shell can expand, their bodies). They run even inside double quotes,
    where the tokenizer sees one word; quotes=False reads an expanding heredoc
    body, where quote characters are literal. The word of a $(...) or `...`
    is $__subN, N its body's index counted from base. lit: the literal-aware
    text, where a $ or backtick the shell takes literally -- single-quoted,
    backslashed, or in a decoded $'...' -- is spelled as in LIT_CHARS."""
    out, bodies, q, i, n = [], [], None, 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\" and q != "'":
            esc = text[i + 1 : i + 2]
            out.append(LIT_CHARS[esc] if lit and esc in LIT_CHARS else text[i : i + 2])
            i += 2
            continue
        if lit and not q and text.startswith("$'", i):
            j = i + 2
            while j < n and text[j] != "'":
                j += 2 if text[j] == "\\" else 1
            word = literal(ansi_c(text[i + 2 : j]))
            out.append("'" + word.replace("'", "'\\''") + "'")
            i = j + 1
            continue
        if q == "'":
            q = None if c == "'" else q
            c = LIT_CHARS.get(c, c) if lit else c
        elif quotes and c == "'" and q is None:
            q = c
        elif quotes and c == '"':
            q = None if q else c
        elif c == "`":
            j = i + 1
            while j < n and text[j] != "`":
                j += 2 if text[j] == "\\" else 1
            out.append(f"$__sub{base + len(bodies)}")
            bodies.append(text[i + 1 : j])
            i = j + 1
            continue
        elif text.startswith("$(", i) or (not q and text.startswith(("<(", ">("), i)):
            depth, j = 0, i + 1
            while j < n:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                if depth == 0:
                    break
                j += 1
            if text.startswith("$((", i):  # $((...)) is arithmetic
                out.append("$__sub")
            else:
                out.append(
                    f"$__sub{base + len(bodies)}" if c == "$" else " /dev/fd/63 "
                )
                bodies.append(text[i + 2 : j])
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), bodies


def ansi_c(text):
    """The text of a $'...' word, its backslash escapes decoded."""

    def one(m):
        e = m.group(1)
        if e[0] in "xuU":
            return chr(int(e[1:], 16))
        if e[0] in "01234567":
            return chr(int(e, 8))
        return ANSI_ESC.get(e, e)

    return ANSI_C.sub(one, text)


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
            where = "" if path == raw else f"{path}: "
            block("exec-unreadable", f"{raw} ({where}{e.strerror or e})")
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


def shell_assigned(name, args):
    """The variables a command gives values only the shell knows: read,
    mapfile/readarray, printf -v, getopts, unset, and declare -n (a name that
    refers to another)."""
    if name == "read":
        opts, pos = parse_opts(args, "adinNptu")
        return [v for k, v in opts if k == "-a"] + (pos or ["REPLY"])
    if name in ("mapfile", "readarray"):
        return (parse_opts(args, "dnOsuCc")[1] or ["MAPFILE"])[:1]
    if name == "printf" and args[:1] == ["-v"]:
        return args[1:2]
    if name == "getopts":
        return args[1:2]
    if name == "unset":
        return [a for a in args if a[:1] != "-"]
    if name in DECLARE:
        opts, pos = parse_opts(args, "")
        if any(k == "-n" for k, _ in opts):
            return [a.split("=", 1)[0] for a in pos]
    return []


def assign(word, lword, ctx):
    """Remember what NAME=VALUE (or NAME+=VALUE, which appends to every value
    the name holds) gives NAME, as written and as literal-aware text; its name."""
    k, v = word.split("=", 1)
    lv = lword.split("=", 1)[1] if lword and "=" in lword else None
    k, append = k.rstrip("+"), k.endswith("+")
    for store, val in ((ctx.values, v), (ctx.lit_values, lv)):
        if append:
            old = store.get(k) or ["${%s}" % k]  # the value from outside the call
            store[k] = [None if o is None or val is None else o + val for o in old]
        else:
            store.setdefault(k, []).append(val)
    return k


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
        elif base == "watch":  # its command runs through sh -c, or as is with -x
            j = skip(i + 1, ("-n", "--interval", "-q", "--equexit"))
            if {"-x", "--exec"} & set(argv[i + 1 : j]):
                i = j
                continue
            return [], " ".join(argv[j:]), changes, chdir
        elif base == "parallel":  # the command before ::: runs through a shell
            j = skip(i + 1, PARALLEL_VALUED)
            rest = argv[j:]
            end = next(
                (k for k, a in enumerate(rest) if a.startswith(":::")), len(rest)
            )
            text = PLACEHOLDER.sub("$__arg", " ".join(rest[:end]))
            return [], text, changes, chdir
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
        wide = " ".join([ln, *expansions(sub[1:], ctx, cwd)])
        api_rules(wide, ctx, cwd, reads=git_obs_reads(sub[1:]))
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


def git_obs_reads(args):
    """Whether git-obs arguments provably only read: an api call that does, or
    another subcommand, which sends no request of its own making."""
    i = 0
    while i < len(args) and args[i][:1] == "-":
        a = long_prefix(args[i], GIT_OBS_LONG)
        i += 2 if a in ("-G", "--gitea-login", "--gitea-config") else 1
    return args[i : i + 1] != ["api"] or only_reads("git-obs", args, GIT_OBS_LONG)


def guess(run, ctx, cwd):
    """A command whose name only the shell knows, judged as each guarded tool
    -- as osc only when it could be osc: a value naming osc, or none known and
    a variable named for it. A refusal names the variable."""
    rest = run[1:]
    try:
        tool_rules(" ".join(["tea", *rest]), ctx, cwd, argv=True)
        tool_rules(" ".join(["git-obs", *rest]), ctx, cwd)
        api_rules(" ".join(["curl", *rest]), ctx, cwd, reads=False)
        if rest[:1] in (["push"], ["obs"]):
            git_command(["git", *rest], ctx, cwd)
        held = substitute(run[0], ctx, cwd)
        if (
            held is None
            and re.search(r"(?i)osc", run[0])
            or any(os.path.basename(h) == "osc" for h in held or ())
        ):
            osc = ["osc", *rest]
            request_args(osc, ctx, cwd)
            request_message(osc, None, ctx, cwd)
            osc_writes(osc, ctx, cwd)
    except Blocked as b:
        raise Blocked(b.rule, b.kind, f"{run[0]}: {b.detail}") from None


def command_words(word, ctx, cwd, depth):
    """The argv spellings of a command held in several words -- a variable
    whose value has spaces, an array ${A[@]} or ${A[*]} -- or None when the
    word is not one. On the call's own command line "$@", "$*" and an unknown
    array are refused, outside a function that passes them on; a script's
    are its arguments, which the guard does not follow."""
    arr = ARRAY_ALL.fullmatch(word)
    if arr and arr.group(1):
        vals = ctx.values.get(arr.group(1))
        if vals:
            return [v.strip("()").split() for v in vals]
    if arr and not ctx.in_function and depth == 0:
        block("command-unknown", word)
    if arr:
        return [[]]
    vals = substitute(word, ctx, cwd)
    if vals and any(len(v.split()) > 1 for v in vals):
        return [v.split() for v in vals]
    return None


def asks_help(args):
    """Whether a tool's arguments ask for its help, which acts on nothing: -h
    or --help before any "--", and not the value of the option before it."""
    for i, a in enumerate(args):
        if a == "--":
            return False
        prev = args[i - 1] if i else ""
        if a in ("-h", "--help") and (not prev.startswith("-") or "=" in prev):
            return True
    return False


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


class Dirs(str):
    """The working directory after a cd to each word of a loop: dirs holds
    them, and the string itself names no directory, so a rule that reads it as
    a path finds nothing there and refuses."""

    def __new__(cls, dirs):
        self = super().__new__(cls, "/(one of several directories)")
        self.dirs = dirs
        return self


def enter(target, ctx, cwd):
    """The directory cd/pushd/env -C moves to -- expanded from what the call
    set, Dirs for several -- or STAMP_CWD when only the shell can place it and
    it names the stamp directory."""
    new = resolve(target, cwd)[0]
    if new is None and not isinstance(cwd, Dirs):
        places = []
        for w in substitute(target, ctx, cwd) or ():
            places += locate(w, ctx, cwd)[0] or [None]  # a glob as the shell expands it
        if places and None not in places:
            if any(stamp_word(p, ctx, cwd, path=True) for p in places):
                return STAMP_CWD
            new = places[0] if len(set(places)) == 1 else Dirs(sorted(set(places)))
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


def one_command(argv, redirs, stdin, ctx, cwd, depth, lit=(None, None)):
    """Check one simple command: (the working directory after it, what it
    writes to a pipe). lit: its argv and stdin as literal-aware text."""
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
        for a, la in zip(argv, lit[0] or [None] * len(argv)):
            k = assign(a, la, ctx) if ASSIGN.match(a) else None
            if k and k not in CLEAN_ENV and (k in os.environ or SENSITIVE.fullmatch(k)):
                ctx.exported.append(k)
        return cwd, None
    here = cwd if chdir is None else enter(chdir, ctx, cwd)
    if shell is not None:
        shell_pass(shell, ctx, here, depth)
        return cwd, ("unknown", "a wrapper")
    lrun = (
        lit[0][len(argv) - len(run) :] if lit[0] and len(lit[0]) == len(argv) else None
    )
    if lrun and VARIABLE.search(run[0]) and not VARIABLE.search(lrun[0]):
        run = [lrun[0].translate(UNLITERAL), *run[1:]]  # a quoted or $'...' name
    name = os.path.basename(run[0])
    if VARIABLE.search(name):
        words = command_words(run[0], ctx, here, depth)
        if words is not None:  # a command held in words: judge each spelling
            for w in words:
                if w:
                    one_command([*w, *run[1:]], redirs, stdin, ctx, here, depth)
            return cwd, ("unknown", name)
        tools = {os.path.basename(h) for h in substitute(run[0], ctx, here) or ()}
        if len(tools) == 1 and tools <= GUARDED:  # a guarded tool in a variable
            name = tools.pop()
            run = [name, *run[1:]]
    if name in ctx.wrappers and len(run) > 1:  # a function that runs "$@"
        one_command(run[1:], redirs, stdin, ctx, here, depth)
    for k in shell_assigned(name, run[1:]):
        ctx.values[k] = ctx.lit_values[k] = []  # a value only the shell knows
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
            words = lrun[3:] if lrun else [None] * len(run[3:])
            ctx.lit_values.setdefault(run[1], []).extend(words)
        return cwd, None
    if touches_stamp(name, run, outs, ctx, here):
        block("stamp", "a command touching the stamp directory")
    note_writes(name, run[1:], ctx, here)
    if name in DECLARE or name == "set":
        note_env(run, ctx)
        for k, a in enumerate(run[1:] if name in DECLARE else (), 1):
            if ASSIGN.match(a) and "-n" not in {
                o for o, _ in parse_opts(run[1:], "")[0]
            }:
                assign(a, lrun[k] if lrun else None, ctx)
    elif VARIABLE.search(name):
        # A path held in a variable is read; a command name, judged as a tool.
        held = substitute(run[0], ctx, here)
        if held and all("/" in h for h in held):
            scan_file(run[0], "auto", ctx, here, depth, env, run=True)
        else:
            guess(run, ctx, here)
    elif name in ("tea", "git-obs", "git", "osc") and asks_help(run[1:]):
        pass
    elif name == "tea":
        wide = " ".join([joined, *expansions(run[1:], ctx, here)])
        tea_api_merge(wide, ctx, here, only_reads("tea", run[1:]))
        tool_rules(" ".join(["tea", *run[1:]]), ctx, here, argv=True)
    elif name == "git-obs":
        tool_rules(joined, ctx, here)
        wide = " ".join([joined, *expansions(run[1:], ctx, here)])
        api_rules(wide, ctx, here, reads=git_obs_reads(run[1:]))
    elif name == "git":
        git_command(run, ctx, here)
    elif name == "osc":
        wide = " ".join([joined, *expansions(run[1:], ctx, here)])
        if osc_sub(run)[0] == "api" and REQUEST_CREATE.search(norm_urls(wide)):
            block("request-api", "a request created through the API")
        request_args(run, ctx, here)
        request_message(run, (lrun, lit[1]), ctx, here)
        osc_writes(run, ctx, here)
    elif name in HTTP_TOOLS:
        # A URL held in a variable this call assigned is judged by its value.
        held = [
            v for k in re.findall(r"\$\{?(\w+)", joined) for v in ctx.values.get(k, ())
        ]
        text = " ".join([joined, *held, *expansions(run[1:], ctx, here)])
        write = name in HTTPIE and httpie_writes(run)
        reads = {"curl": curl_reads(run[1:]), "wget": wget_reads(run[1:])}
        api_rules(text, ctx, here, write, reads.get(name, httpie_reads(run, stdin)))
    elif name == "eval":
        run_text(" ".join(run[1:]), "shell", ctx, here, depth)
    elif name == "find":
        find_exec(run, ctx, here, depth)
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


def find_exec(run, ctx, cwd, depth):
    """Judge each command find runs, a match's name ({}) held in a variable,
    and the -dir ones run in a directory only find knows."""
    i = 1
    while i < len(run):
        if run[i] not in FIND_EXEC:
            i += 1
            continue
        end = next(
            (j for j in range(i + 1, len(run)) if run[j] in (";", "+")), len(run)
        )
        argv = [PLACEHOLDER.sub("$__arg", a) for a in run[i + 1 : end]]
        where = None if run[i].endswith("dir") else cwd
        if argv:
            one_command(argv, [], None, ctx, where, depth)
        i = end + 1


def function_bodies(items, ctx):
    """{item index: +1 where a function body starts, -1 after it ends}; a
    function whose body runs "$@", "$*" or "$1" as a command joins ctx.wrappers."""
    marks = {}
    for k, item in enumerate(items):
        argv = item[0] if len(item) == 2 else []
        name = argv[1] if argv[:1] == ["function"] and len(argv) > 1 else None
        if name is None and len(argv) == 1 and items[k + 1 : k + 3] == ["(", ")"]:
            name = argv[0]
        if name is None:
            continue
        depth, j = 0, k + 1
        while j < len(items):
            words = items[j][0] if len(items[j]) == 2 else []
            depth += words.count("{") - words.count("}")
            head = [w for w in words if w not in KEYWORDS][:1]
            if head and ARGS_RUN.fullmatch(head[0]):
                ctx.wrappers.add(name)
            if depth <= 0 and "}" in words:
                break
            j += 1
        marks[k + 1] = marks.get(k + 1, 0) + 1
        marks[j + 1] = marks.get(j + 1, 0) - 1
    return marks


def loop_assignments(items, lits):
    """{index of a loop's first command: the assignments its body makes, as
    (word, literal-aware word)}: a variable a loop assigns holds each of its
    values at every point of the loop, the next iteration's included."""
    starts, out = [], {}
    for k, item in enumerate(items):
        if len(item) != 2 or not item[0]:
            continue
        if item[0][0] in ("for", "while", "until", "select"):
            starts.append(k)
        elif item[0][0] == "done" and starts:
            start = starts.pop()
            found = out.setdefault(start, [])
            for j in range(start, k):
                if len(items[j]) != 2 or not items[j][0]:
                    continue
                argv, largv = items[j][0], (lits[j] or (None, None))[0]
                run = unwrap(argv)[0]
                name = os.path.basename(run[0]) if run else ""
                words = argv[: len(argv) - len(run)] if run else argv
                if name in DECLARE:
                    words = [*words, *run[1:]]
                lwords = largv and largv[: len(words)] if name not in DECLARE else None
                for n, w in enumerate(words):
                    if ASSIGN.match(w):
                        found.append((w, lwords[n] if lwords else None))
                for v in shell_assigned(name, run[1:]):
                    found.append((v + "+=", None))  # unknown
    return out


def widen(word, lword, ctx):
    """Give a variable a loop assigns every value it takes there too; one this
    call did not set before, or appended to, becomes unknown."""
    k, v = word.split("=", 1)
    known = ctx.values.get(k.rstrip("+"))
    if k.endswith("+") or not known:
        ctx.values[k.rstrip("+")] = ctx.lit_values[k.rstrip("+")] = []
        return
    ctx.values[k] = known + [v]
    ctx.lit_values[k] = (ctx.lit_values.get(k) or []) + [lword]


def shell_pass(text, ctx, cwd, depth):
    """Walk the simple commands of shell text, following cd, subshells, and
    pipes into a shell or interpreter. Returns what it writes to stdout, as
    literal-aware text: one output() per writer, in order."""
    first = len(ctx.docs)
    body = split_heredocs(text, ctx)
    for doc, expands in ctx.docs[first:]:
        if expands:
            for inner in substitutions(doc, quotes=False)[1]:
                shell_pass(inner, ctx, cwd, depth)
    base = len(ctx.subs)
    body = strip_comments(body.replace("\\\n", " "))
    lit = substitutions(body, base=base, lit=True)[0]
    body, inners = substitutions(body, base=base)
    ctx.subs += [None] * len(inners)
    for k, inner in enumerate(inners):
        ctx.subs[base + k] = shell_pass(inner, ctx, cwd, depth)
    items = list(commands(arrays(tokenize(body))))
    lits = list(commands(arrays(tokenize(lit))))
    shape = [len(i) == 2 and (len(i[0]), len(i[1])) or i for i in items]
    if shape != [len(i) == 2 and (len(i[0]), len(i[1])) or i for i in lits]:
        lits = [None] * len(items)  # a literal $'...' split otherwise: all unknown
    stack, out, piped, case, pattern = [], None, None, 0, False
    writers, lpiped = [], None
    loops = loop_assignments(items, lits)
    bodies = function_bodies(items, ctx)
    for k, (item, litem) in enumerate(zip(items, lits)):
        for word, lword in loops.get(k, ()):
            widen(word, lword, ctx)
        ctx.in_function += bodies.get(k, 0)
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
            lpiped = writers.pop() if writers else None
        elif item == "(":
            stack.append(cwd)
        elif item == ")":
            cwd = stack.pop() if stack else cwd
            out = ("unknown", "a subshell")
            writers.append(out)
        else:
            argv, redirs = item
            largv, lredirs = litem or (None, None)
            stdin, piped = piped, None
            lstdin, lpiped = lpiped, None
            for k, (op, word) in enumerate(redirs):
                lword = lredirs[k][1] if lredirs else None
                if op == "<<" and word[:1] == "\x01" and word[1:].isdigit():
                    doc, expands = ctx.docs[int(word[1:])]
                    stdin, lstdin = (
                        ("text", doc),
                        ("text", doc if expands else literal(doc)),
                    )
                elif op == "<<<":
                    stdin, lstdin = ("text", word), lword and ("text", lword)
                elif op == "<":
                    stdin = lstdin = ("files", [word])
            lit = (largv, lstdin)
            before = cwd
            cwd, out = one_command(argv, redirs, stdin, ctx, cwd, depth, lit)
            writers.append(placed(lit_output(argv, redirs, out, lit), ctx, before))
    return [w for w in writers if w is not None]


def placed(out, ctx, cwd):
    """out with the files it names placed where the writer ran: cwd."""
    if not out or out[0] != "files":
        return out
    paths = [locate(raw, ctx, cwd)[0] for raw in out[1]]
    if None in paths:
        return ("unknown", "a file where only the shell can place it")
    return ("files", [p for ps in paths for p in ps])


def lit_output(argv, redirs, out, lit):
    """What a command writes to stdout (out, as output() says), as
    literal-aware text: echo, printf and cat from their literal-aware words,
    a bare < FILE, as in $(<FILE), its file; None for nothing."""
    largv, lstdin = lit
    run = unwrap(argv)[0]
    if not argv and any(op == "<" for op, _ in redirs):
        return lstdin
    if (
        out is None
        or not run
        or os.path.basename(run[0]) not in ("echo", "printf", "cat")
    ):
        return out
    if largv is None or len(largv) != len(argv):
        return ("unknown", "text the guard could not read literally")
    lrun = largv[len(argv) - len(run) :]
    name, args = os.path.basename(run[0]), lrun[1:]
    if any(BRACES.search(a) for a in args):
        return ("unknown", "a brace expansion")
    if name == "printf" and args and args[0] != "-v":
        convs = PRINTF_CONV.findall(args[0])
        if any(c[1] for c in convs) or len(args) - 1 > len(convs):
            return ("unknown", "a printf width, precision or reused format")
    return output(name, args, lstdin) or ("unknown", "text")


def check_write(path, content, ctx):
    if STAMP.search(path.replace(os.sep, "/")):
        block("stamp-write", f"a write to {path}", "stamp")
    # Docs quote the wrong forms on purpose; scripts are where a POST hides.
    if not path.lower().endswith(DOCS):
        lines = "\n".join(code_lines(content))
        for ln in lines.split("\n"):
            if TEA_MERGE.search(ln):
                block("merge-tea", "a script running a tea PR merge")
            if TEA_CREATE.search(ln) and pool_or_unknown(ln, ctx, ctx.cwd, cmd=True):
                block("create-tea", "a script running a tea PR create on pool")
        lines = norm_urls(lines)
        if (
            DO_MERGE.search(lines)
            or MERGE_URL.search(lines)
            and (pool_or_unknown(lines, ctx, ctx.cwd) or not code_reads(lines))
        ):
            block("merge-api", "a script merging a PR")
        if REQUEST_CREATE.search(lines):
            block("request-api", "a script creating a request through the API")
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
