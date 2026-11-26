#!/usr/bin/env python3
"""Every `geectl` invocation the prose cites must be one geectl accepts.

The skill tells agents exactly how to call geectl so they neither guess nor
probe `geectl <cmd> --help`. A guessed form costs more than a probe: the
wrong leaf fails, and the agent that hit it worked around it with a raw
API call. So each citation is checked against geectl's own `--help`,
read from the built binary (command names up front, flag sets per cited
leaf):

  * the command exists (a group plus its leaf, or a top-level leaf);
  * every flag cited after it is an option that leaf's parser accepts
    (the global options every command accepts included);
  * a synopsis line states the leaf's positional arity: the count of its
    bare words must fit the leaf's Usage line (a manifest row's
    "positionals" when the binary lacks the leaf, or a
    "positional-overrides" row when the binary's shape predates the
    target state). A synopsis line that abbreviates with `…` states
    nothing; a prose mention names the command, not its arguments, so it
    is not checked for positionals.
  * a `--flag` cited in prose on the same line as a command is an option
    geectl accepts, so a typo in a prose flag fails too — unless it is a
    bundled script's option whose script is named on the same line
    (script-usage.md synopses give the flag's owners; a bare geectl typo
    that merely collides with a script flag still fails) or a short flag
    of another tool (`-p`, `-j1`);
  * references/geectl-usage.md has a synopsis line for that command, so no
    doc uses a geectl form the reference does not define;
  * the known wrong forms are not recommended outside geectl-usage.md's
    "Wrong forms" section.

Target state: leaves and flags geectl does not have yet are listed in
tests/repo/geectl-target-state.json with the blocking geectl issue or PR
and the exact shape the skill needs. A citation of one of those is checked
against the manifest instead of the binary — and the manifest row goes
stale (a finding) the moment the binary gains the leaf or flag, so the
row is removed and the citations re-verified live. A row may also carry
"positionals": the leaf's positional names in order. A
"positional-overrides" row records a leaf whose positionals changed since
the binary: the row's required/optional lists are the target state, and
the row goes stale the moment the binary's Usage line matches them.

  python3 tests/repo/check-geectl.py [--geectl PATH] [--skill NAME]

Needs a geectl binary: --geectl, the GEectl_BIN environment variable, or
`geectl` on PATH. Without a runnable binary this exits 2 rather than
passing.
Prints "geectl: <file>:<line>: <message>" per finding; exit 1 on any finding.
"""

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

_spec = importlib.util.spec_from_file_location(
    "check_flags", os.path.join(HERE, "check-flags.py")
)
_cf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cf)
spans, NEGATED = _cf.spans, _cf.NEGATED

MANIFEST = os.path.join(HERE, "geectl-target-state.json")

# `geectl [global opts] <word1> [<word2>] <rest>`; the rest stops where
# another command starts (a pipe, ;, &). Global options that take a value
# take the next word. word1 is a group (remote, request, ...) with word2
# as its leaf, or a top-level leaf on its own (checkout, status, ...).
CALL = re.compile(
    r"(?<![\w./-])geectl((?:\s+(?:(?:--format)(?:\s+(?!-)\S+|=\S+)"
    r"|(?!--format\b)--?[A-Za-z][\w-]*(?:=\S+)?))*)"
    r"\s+([a-z][a-z0-9_-]*)(?:\s+([a-z][a-z0-9_-]*))?\b([^`\n|;&]*)"
)
# A command substitution is its own command: `-m "$(cat f)"` must not hide the
# options after it, nor lend it its own.
SUBST = re.compile(r"\$\([^()]*\)")
OPT = re.compile(r"(?<![\w/.<>=-])(--?[A-Za-z][\w-]*)")


def prose_flags(span):
    """Flag tokens in a bare prose span: a one-letter dash-token directly
    after a flag is that flag's value (`--start -N`), not another flag."""
    out = []
    prev_flag = False
    for tok in span.strip().split():
        if tok.startswith("-") and not (
            prev_flag and len(tok) == 2 and tok[1].isalpha()
        ):
            out.append(tok)
            prev_flag = True
        else:
            prev_flag = False
    return out


SHORT = re.compile(r"^-[A-Za-z][A-Za-z0-9]?$")


def _stem_mentioned(stem, line):
    """The script stem as a word on the line, bounded by characters outside
    [A-Za-z0-9_-]: ``gate`` matches ``the gate's`` and ``gate.sh``, not
    ``target-gate.sh``."""
    return (
        re.search(
            r"(?<![A-Za-z0-9_-])" + re.escape(stem) + r"(?![A-Za-z0-9_-])",
            line,
            re.IGNORECASE,
        )
        is not None
    )


def script_flags(base):
    """Long flags of the bundled scripts, from their script-usage.md
    synopses (check-flags.py verifies those against each script's --help),
    as flag -> {script stems}: a prose flag naming one of those passes only
    when its owning script is named on the same line, so a geectl typo that
    merely collides with a script flag (``--repos`` for ``--repo``) still
    fails."""
    path = os.path.join(base, "references", "script-usage.md")
    out = {}
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in fh.read().splitlines():
            if _cf.SYNOPSIS.match(line):
                m = re.search(r"`([^`]+)`", line)
                if not m:
                    continue
                stem = os.path.basename(m.group(1).split()[0])
                if not stem.endswith((".sh", ".py")):
                    continue
                stem = re.sub(r"\.(sh|py)$", "", stem)
                for flag in _cf.FLAG.findall(line):
                    out.setdefault(flag, set()).add(stem)
    return out


# A synopsis bullet: "- `geectl group leaf ...` · `geectl other ...` — meaning";
# every `geectl ...` span before the dash defines that command.
SYNOPSIS = re.compile(r"^- `geectl ")
DEFINES = re.compile(r"`geectl ((?:[a-z][a-z0-9_-]*)(?: [a-z][a-z0-9_-]*)?)\b")
WRONG_HEAD = "## Wrong forms"

# Invocations that are wrong however they are spelled. Each is (pattern over the
# canonical leaf path + rest, message). A checkout into a temp dir is a
# working-directory mistake, not a flag, so it stays prose in the reference.
WRONG = [
    (
        re.compile(r"^local-build service-run\b.*--mode(?:\s+|=)runall\b"),
        "no such mode; name the service and its mode, never runall",
    ),
]

# Options every geectl command accepts (also listed in each leaf's help).
GLOBAL_OPTS = {
    "--format",
    "--debug",
    "--debug-body",
    "--live",
    "--help",
    "--version",
    "-h",
    "-V",
}

# Long flags of external tools the skill's prose names: a prose flag is
# that tool's, not geectl's, when the tool is named on the same line — the
# same attribution the bundled scripts get. Only the flags the prose
# actually cites are listed; a new tool's flags belong here, not in `known`.
TOOL_FLAGS = {
    "bash": {"--rcfile", "--init-file"},
    "curl": {"--globoff", "--max-filesize", "--resolve", "--config", "--next"},
    # Long flags of the other tools the guard doc cites in prose, named
    # on the same line (same attribution as the bundled scripts): a
    # geectl typo that merely collides with one of these still fails.
    "git": {"--work-tree", "--output=", "--output-dir=", "--config"},
    "tea": {"--login", "-title"},
    "git-obs": {"--commit"},
    "wget": {"--next", "--no-config"},
    "httpie": {"--ignore-stdin"},
    "opencode": {"--agent"},
    "cp": {"--target-directory="},
    # Removed flag, named in prose as gone (leap-sync.sh no longer takes
    # it, so it cannot live in script-usage.md's synopsis).
    "leap-sync": {"--refresh"},
}


def run_help(binary, args):
    """(exit code, stdout) of `geectl <args> --help`, or (None, error)."""
    try:
        r = subprocess.run(
            [binary, *args, "--help"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, str(exc)
    return r.returncode, r.stdout


def run(binary, args):
    """(exit code, stdout) of `geectl <args>`, or (None, error)."""
    try:
        r = subprocess.run(
            [binary, *args],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, str(exc)
    return r.returncode, r.stdout


def command_names(help_text):
    """Leaf names from a clap `--help` Commands section."""
    return re.findall(r"^  ([a-z][a-z0-9-]*)\s{2,}\S", help_text, flags=re.M)


class GeectlCli:
    """The binary's command tree: names loaded up front, flag sets loaded
    lazily per leaf, so a run only pays for the leaves the docs cite (plus
    the manifest rows the staleness check covers)."""

    def __init__(self, binary):
        self.binary = binary
        self.paths = set()
        self.flags = {}
        self.positionals = {}
        self.valued = {}
        rc, out = run_help(binary, [])
        if rc is None or rc != 0:
            raise RuntimeError("cannot run geectl --help")
        for name in command_names(out):
            if name == "help":
                self.paths.add("help")
                self.flags["help"] = set(GLOBAL_OPTS)
                self.valued["help"] = {"--format"}
                continue
            rc, group_out = run_help(binary, [name])
            if rc is None or rc != 0:
                raise RuntimeError(f"cannot run geectl {name} --help")
            leaves = command_names(group_out)
            if not leaves:
                # A top-level leaf with no subcommands (e.g. version):
                # its flags load lazily from `geectl help <leaf>`,
                # like a group leaf's — GLOBAL_OPTS alone would fail
                # every cited leaf flag (e.g. `commit -m`).
                self.paths.add(name)
                continue
            for leaf in leaves:
                self.paths.add(f"{name} {leaf}")

    def groups(self):
        return {path.split()[0] for path in self.paths if " " in path}

    def load_flags(self, path):
        """Flag set for a leaf path, or None when the leaf does not exist."""
        if path in self.flags:
            return self.flags[path]
        if path not in self.paths:
            return None
        parts = path.split()
        if len(parts) == 1:
            # A top-level leaf (`commit`, `checkout`, ...): its help is
            # `geectl help <leaf>`, with the same Options section.
            rc, leaf_out = run(self.binary, ["help", parts[0]])
            if rc is None or rc != 0:
                raise RuntimeError(f"cannot run geectl help {path}")
        else:
            group, leaf = parts
            if leaf == "help":
                self.flags[path] = set(GLOBAL_OPTS)
                self.valued[path] = {"--format"}
                return self.flags[path]
            # `geectl help <group> <leaf>` prints the leaf help; appending
            # --help to the help subcommand does not.
            rc, leaf_out = run(self.binary, ["help", group, leaf])
            if rc is None or rc != 0:
                raise RuntimeError(f"cannot run geectl help {path}")
        flags = set(GLOBAL_OPTS)
        options = leaf_out.split("Options:", 1)[-1] if "Options:" in leaf_out else ""
        flags.update(re.findall(r"^ {6}(--[\w-]+)", options, flags=re.M))
        flags.update(
            f"-{c}" for c in re.findall(r"^  -([a-zA-Z]),", options, flags=re.M)
        )
        # A flag takes a value when a <VALUE> follows its name on its
        # Options line; the rest are booleans. --format is the only valued
        # global option.
        valued = {"--format"}
        valued.update(
            re.findall(r"^ {6}(--[\w-]+)\s+<[^>]+>", options, flags=re.M)
        )
        for short, long in re.findall(
            r"^  -([a-zA-Z]), (--[\w-]+)\s+<[^>]+>", options, flags=re.M
        ):
            valued.add(f"-{short}")
            valued.add(long)
        self.flags[path] = flags
        self.valued[path] = valued
        return flags

    def load_valued(self, path):
        """Flags of a leaf path that take a value, or None when the leaf
        does not exist."""
        if path in self.valued:
            return self.valued[path]
        if path not in self.paths:
            return None
        self.load_flags(path)
        return self.valued[path]


    def load_positionals(self, path):
        """(required, optional) positional names for a leaf path, in order,
        parsed from the leaf's Usage line: a bare <NAME> is a required
        positional, a [NAME] (or [<NAME>]) an optional one; a <NAME> after
        a flag is that flag's value. None when the leaf is unknown."""
        if path in self.positionals:
            return self.positionals[path]
        if path not in self.paths:
            return None
        parts = path.split()
        if parts[-1] == "help":
            self.positionals[path] = ([], [])
            return self.positionals[path]
        rc, leaf_out = run(self.binary, ["help", *parts])
        if rc is None or rc != 0:
            raise RuntimeError(f"cannot run geectl help {path}")
        required, optional = [], []
        m = re.search(
            r"^Usage: geectl " + re.escape(path) + r"\b(.*)$",
            leaf_out,
            flags=re.M,
        )
        if m:
            toks = m.group(1).split()
            i = 0
            while i < len(toks):
                tok = toks[i]
                if tok == "[OPTIONS]":
                    i += 1
                    continue
                if tok.startswith("--") or re.match(r"^-[A-Za-z]$", tok.strip("[]")):
                    # A flag; its <VALUE>, when the next token carries one,
                    # is not a positional.
                    if "=" in tok:
                        i += 1
                        continue
                    if i + 1 < len(toks) and toks[i + 1].strip("[]").startswith("<"):
                        i += 2
                    else:
                        i += 1
                    continue
                base = tok[:-3] if tok.endswith("...") else tok
                pm = re.match(r"^<([A-Za-z][A-Za-z0-9_-]*)>$", base)
                if pm:
                    required.append(pm.group(1))
                else:
                    pm = re.match(r"^\[<?([A-Za-z][A-Za-z0-9_-]*)>?]$", base)
                    if pm:
                        optional.append(pm.group(1))
                i += 1
        self.positionals[path] = (required, optional)
        return self.positionals[path]


def load_geectl(binary):
    """A GeectlCli, or None when the binary cannot run."""
    try:
        return GeectlCli(binary)
    except RuntimeError:
        return None


def load_manifest():
    """(leaves, flags, overrides) from geectl-target-state.json, or
    ({}, {}, {}) when the file is absent (no target-state debt). A
    malformed file fails closed. An override is (issue, required,
    optional): the target-state positionals of a leaf the binary already
    has, whose shape predates the target state."""
    if not os.path.exists(MANIFEST):
        return {}, {}, {}
    with open(MANIFEST, encoding="utf-8") as fh:
        data = json.load(fh)
    leaves = {}
    for path, row in data.get("leaves", {}).items():
        leaves[path] = (
            row["issue"],
            set(row.get("flags", [])),
            row.get("positionals"),
        )
    flags = {}
    for path, row in data.get("flags", {}).items():
        flags[path] = {flag: entry["issue"] for flag, entry in row.items()}
    overrides = {}
    for path, row in data.get("positional-overrides", {}).items():
        overrides[path] = (
            row["issue"],
            row.get("required", []),
            row.get("optional", []),
        )
    return leaves, flags, overrides


def cited_positionals(rest, valued):
    """Bare words in a cited call that fill positionals, in order. A word
    after a valued option flag is that flag's value; a word after a boolean
    flag is a positional, not a value (`--recursive PRJ` names the project
    to delete)."""
    out = []
    prev_valued = False
    for raw in rest.split():
        tok = raw.strip("[]`\"'")
        if tok.endswith("..."):
            tok = tok[:-3]
        elif tok not in (".", ".."):
            # Trailing sentence punctuation — but a bare `.`/`..` is a
            # path literal filling a positional, not punctuation.
            tok = tok.rstrip(",.;")
        if not tok:
            prev_valued = False
            continue
        if tok.startswith("--") or re.match(r"^-[A-Za-z]$", tok):
            prev_valued = "=" not in tok and tok in valued
            continue
        if prev_valued:
            prev_valued = False
            continue
        out.append(tok)
        prev_valued = False
    return out


def positional_mismatch(provided, required, all_names):
    """None when the cited positionals fit the leaf's arity, else a
    message. Only the count is judged: the skill's placeholders (PRJ,
    PKG, REPO, DIR, FILE) name the CLI's positionals (PROJECT, PACKAGE,
    REPOSITORY, DIRECTORY, FILENAME) by convention, so a name check would
    flag every correct citation. A lowercase word is a literal value
    filling one slot."""
    if not provided:
        if required:
            return f"takes positionals {' '.join(required)} (none cited)"
        return None
    if not all_names:
        return f"takes no positionals (cited {' '.join(provided)})"
    if len(provided) > len(all_names):
        return f"takes positionals {' '.join(all_names)} (cited {' '.join(provided)})"
    if len(provided) < len(required):
        return f"takes positionals {' '.join(required)} (cited {' '.join(provided)})"
    return None


def docs_of(base):
    docs = [os.path.join(base, "SKILL.md")]
    for sub in ("agents", "references"):
        d = os.path.join(base, sub)
        if os.path.isdir(d):
            docs += [
                os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".md")
            ]
    readme = os.path.join(base, "scripts", "README.md")
    if os.path.exists(readme):
        docs.append(readme)
    return docs


def wrong_section_lines(path):
    """Line numbers inside geectl-usage.md's "Wrong forms" section."""
    out, inside = set(), False
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh.read().splitlines(), start=1):
            if line.startswith("## "):
                inside = line.startswith(WRONG_HEAD)
            if inside:
                out.add(n)
    return out


def check(base, cli, manifest_leaves, manifest_flags, manifest_overrides):
    findings, cited_subs, count = [], {}, 0
    usage = os.path.join(base, "references", "geectl-usage.md")
    wrong_ok = wrong_section_lines(usage) if os.path.exists(usage) else set()
    groups = cli.groups()
    # A manifest-only group (changelog) is a group too.
    groups |= {path.split()[0] for path in manifest_leaves if " " in path}
    for doc in docs_of(base):
        rel = os.path.relpath(doc, ROOT)
        with open(doc, encoding="utf-8") as fh:
            raw = fh.read().splitlines()
        cursor = {}
        for n, text in spans(doc):
            text = SUBST.sub("SUBST", text)
            for m in CALL.finditer(text):
                word1, word2, rest = m.group(2), m.group(3), m.group(4)
                if word1 in groups:
                    if not word2:
                        findings.append(
                            (rel, n, f"`geectl {word1}`: a group, not a command")
                        )
                        continue
                    path, rest = f"{word1} {word2}", rest
                else:
                    path = word1
                manifest_pos = None
                valued = None
                if path in manifest_leaves:
                    issue, flags, manifest_pos = manifest_leaves[path]
                    valued = set(flags) | {"--format"}
                    count += 1
                    cited_subs.setdefault(path, (rel, n))
                    for flag in OPT.findall(rest):
                        if flag not in flags and flag not in GLOBAL_OPTS:
                            findings.append(
                                (
                                    rel,
                                    n,
                                    f"`geectl {path}`: target-state leaf (issue "
                                    f"#{issue}) has no flag {flag}",
                                )
                            )
                elif path in cli.paths:
                    flags = set(cli.load_flags(path))
                    # The manifest flags for this leaf are main-only
                    # options the binary lacks; they are valued options
                    # the skill cites, so their values are not
                    # positionals either.
                    valued = cli.load_valued(path) | set(
                        manifest_flags.get(path, {})
                    )
                    flags.update(manifest_flags.get(path, {}))
                    count += 1
                    cited_subs.setdefault(path, (rel, n))
                    for flag in OPT.findall(rest):
                        if flag not in flags:
                            findings.append(
                                (
                                    rel,
                                    n,
                                    f"`geectl {path}`: geectl {path} has no "
                                    f"option {flag}",
                                )
                            )
                else:
                    findings.append(
                        (rel, n, f"`geectl {path}`: no such geectl command")
                    )
                    continue
                if doc == usage and n in wrong_ok:
                    continue
                call = f"{path} {rest.strip()}"
                # Negation is judged at THIS occurrence: a later, un-negated
                # repeat of the same call must not borrow an earlier "never".
                line = SUBST.sub("SUBST", raw[n - 1])
                at = line.find(m.group(0), cursor.get(n, 0))
                cursor[n] = at + 1
                before = line[: max(0, at)]
                before = before.replace("`", "").replace("*", "")
                for pat, msg in WRONG:
                    if pat.search(call) and not NEGATED.search(before[-40:]):
                        findings.append((rel, n, f"`geectl {path}`: {msg}"))
                # Positionals, on synopsis calls only: the call states the
                # full form, so the count of its bare words must fit the
                # leaf's positional arity. A call after the line's ` — `
                # is prose, not a synopsis; an abbreviated call (`…`)
                # states nothing about them.
                dash = line.find(" — ")
                if (
                    SYNOPSIS.match(raw[n - 1])
                    and dash != -1
                    and at != -1
                    and at < dash
                    and "…" not in rest
                    and "..." not in rest
                ):
                    if manifest_pos is not None:
                        required, all_names = manifest_pos, manifest_pos
                    elif path in manifest_overrides:
                        _issue_o, required, optional = manifest_overrides[path]
                        all_names = required + optional
                    elif path in cli.paths:
                        required, optional = cli.load_positionals(path)
                        all_names = required + optional
                    else:
                        required = all_names = None
                    if all_names is not None:
                        mismatch = positional_mismatch(
                            cited_positionals(rest, valued or set()),
                            required,
                            all_names,
                        )
                        if mismatch:
                            findings.append(
                                (rel, n, f"`geectl {path}`: {mismatch}")
                            )
    # Prose flags: a `--flag` span on the same line as a `geectl` call cites
    # a flag geectl accepts, even though it sits outside the call span — a
    # typo there would sail through the call check above. Verify each
    # against every flag of every leaf the docs cite (the call check above
    # loaded those), the manifest rows, and the global options: a prose
    # flag may name another command's flag (`--description`, for the shell
    # safety the add-comment line points at), so the check is existence,
    # not which command takes it. A flag of a bundled script (its
    # script-usage.md synopsis lists it) is that script's, not geectl's,
    # when the script is named on the same line; a short flag (`-p`, `-j1`)
    # belongs to another tool — geectl's short
    # options are verified inside call spans, where the call check covers
    # them. A span naming another tool (`tea … --login`) starts with that
    # tool, not a flag, so it is not a prose flag; a line with no `geectl`
    # call has no command to attribute the flag to, so it is skipped.
    # Wrong forms define nothing.
    known = set(GLOBAL_OPTS)
    for _path, flags in cli.flags.items():
        known |= set(flags)
    for _issue, flags, _pos in manifest_leaves.values():
        known |= set(flags)
    for row in manifest_flags.values():
        known |= set(row)
    script_owners = script_flags(base)
    for doc in docs_of(base):
        rel = os.path.relpath(doc, ROOT)
        skip = wrong_ok if doc == usage else set()
        by_line = {}
        for n, text in spans(doc):
            by_line.setdefault(n, []).append(text)
        with open(doc, encoding="utf-8") as fh:
            raw_lines = fh.read().splitlines()
        for n in sorted(by_line):
            if n in skip:
                continue
            has_call = False
            bare = []
            for text in by_line[n]:
                text = SUBST.sub("SUBST", text)
                if CALL.search(text):
                    has_call = True
                else:
                    bare.append(text)
            if not has_call:
                continue
            for text in bare:
                if not OPT.match(text.strip()):
                    continue
                for flag in prose_flags(text):
                    if flag in known or SHORT.match(flag):
                        continue
                    owners = script_owners.get(flag)
                    if owners and any(
                        _stem_mentioned(stem, raw_lines[n - 1]) for stem in owners
                    ):
                        continue
                    if any(
                        _stem_mentioned(tool, raw_lines[n - 1])
                        for tool, flags in TOOL_FLAGS.items()
                        if flag in flags
                    ):
                        continue
                    findings.append(
                        (
                            rel,
                            n,
                            f"prose cites {flag}, which no cited "
                            "`geectl` command accepts",
                        )
                    )
    # A manifest row goes stale the moment the binary gains it.
    for path, (issue, _flags, _pos) in sorted(manifest_leaves.items()):
        if path in cli.paths:
            findings.append(
                (
                    os.path.relpath(MANIFEST, ROOT),
                    0,
                    f"target-state leaf `{path}` (issue #{issue}) now exists in "
                    "geectl; remove the row and re-verify its citations live",
                )
            )
    for path, row in sorted(manifest_flags.items()):
        if path not in cli.paths:
            continue
        live = cli.load_flags(path)
        for flag, issue in sorted(row.items()):
            if flag in live:
                findings.append(
                    (
                        os.path.relpath(MANIFEST, ROOT),
                        0,
                        f"target-state flag `{flag}` on `{path}` (issue #{issue}) "
                        "now exists in geectl; remove the row and re-verify "
                        "its citations live",
                    )
                )
    # A positional override goes stale the moment the binary's Usage
    # line matches the target state.
    for path, (issue, required, optional) in sorted(manifest_overrides.items()):
        if path not in cli.paths:
            continue
        live_required, live_optional = cli.load_positionals(path)
        if (live_required, live_optional) == (required, optional):
            findings.append(
                (
                    os.path.relpath(MANIFEST, ROOT),
                    0,
                    f"positional override for `{path}` (issue #{issue}) "
                    "now matches geectl; remove the row and re-verify "
                    "its citations live",
                )
            )
    # The reference must define every command the skill uses.
    rel_usage = os.path.relpath(usage, ROOT)
    if not os.path.exists(usage):
        findings.append((rel_usage, 0, "missing; the skill cites geectl commands"))
        return findings, count
    defined = {}
    with open(usage, encoding="utf-8") as fh:
        for n, line in enumerate(fh.read().splitlines(), start=1):
            # A wrong form defines nothing; only the real synopsis lines count.
            if n in wrong_ok or not SYNOPSIS.match(line):
                continue
            for word in DEFINES.findall(line.split(" — ", 1)[0]):
                defined.setdefault(word, n)
    for sub, (rel, n) in sorted(cited_subs.items()):
        if sub not in defined:
            findings.append(
                (rel, n, f"`geectl {sub}` has no synopsis line in {rel_usage}")
            )
    return findings, count


def main(argv=None):
    ap = argparse.ArgumentParser(prog="check-geectl.py", description=__doc__)
    ap.add_argument("--skill", default=None, help="only this skill directory")
    ap.add_argument(
        "--geectl",
        default=os.environ.get("GEectl_BIN", "geectl"),
        help="geectl binary to check against (default: $GEectl_BIN or geectl)",
    )
    args = ap.parse_args(argv)
    table = load_geectl(args.geectl)
    if not table:
        print(
            "check-geectl.py: cannot run geectl; pass --geectl PATH to a "
            "built binary (CI builds one from a pinned source commit)",
            file=sys.stderr,
        )
        return 2
    try:
        manifest_leaves, manifest_flags, manifest_overrides = load_manifest()
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        print(f"check-geectl.py: {MANIFEST} is malformed: {exc}", file=sys.stderr)
        return 2
    skills_dir = os.path.join(ROOT, "skills")
    skills = (
        [args.skill]
        if args.skill
        else sorted(
            d
            for d in os.listdir(skills_dir)
            if os.path.isdir(os.path.join(skills_dir, d))
        )
    )
    findings, count = [], 0
    try:
        for skill in skills:
            f, c = check(
                os.path.join(skills_dir, skill),
                table,
                manifest_leaves,
                manifest_flags,
                manifest_overrides,
            )
            findings += f
            count += c
    except RuntimeError as exc:
        print(f"check-geectl.py: {exc}", file=sys.stderr)
        return 2
    for path, line, msg in findings:
        print(f"geectl: {path}:{line}: {msg}")
    if findings:
        print(f"\n{len(findings)} finding(s)", file=sys.stderr)
        return 1
    print(f"ok - {count} geectl citations match geectl")
    return 0


if __name__ == "__main__":
    sys.exit(main())
