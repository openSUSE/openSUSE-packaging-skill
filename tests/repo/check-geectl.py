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
  * a `--flag` cited in prose on the same line as a command is an option
    geectl accepts, so a typo in a prose flag fails too;
  * references/geectl-usage.md has a synopsis line for that command, so no
    doc uses a geectl form the reference does not define;
  * the known wrong forms are not recommended outside geectl-usage.md's
    "Wrong forms" section.

Target state: leaves and flags geectl does not have yet are listed in
tests/repo/geectl-target-state.json with the blocking geectl issue or PR
and the exact shape the skill needs. A citation of one of those is checked
against the manifest instead of the binary — and the manifest row goes
stale (a finding) the moment the binary gains the leaf or flag, so the
row is removed and the citations re-verified live. Positionals are not
parsed.

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
        rc, out = run_help(binary, [])
        if rc is None or rc != 0:
            raise RuntimeError("cannot run geectl --help")
        for name in command_names(out):
            if name == "help":
                self.paths.add("help")
                self.flags["help"] = set(GLOBAL_OPTS)
                continue
            rc, group_out = run_help(binary, [name])
            if rc is None or rc != 0:
                raise RuntimeError(f"cannot run geectl {name} --help")
            leaves = command_names(group_out)
            if not leaves:
                # A top-level leaf with no subcommands (e.g. version).
                self.paths.add(name)
                self.flags[name] = set(GLOBAL_OPTS)
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
        group, leaf = path.split()
        if leaf == "help":
            self.flags[path] = set(GLOBAL_OPTS)
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
        self.flags[path] = flags
        return flags


def load_geectl(binary):
    """A GeectlCli, or None when the binary cannot run."""
    try:
        return GeectlCli(binary)
    except RuntimeError:
        return None


def load_manifest():
    """(leaves, flags) from geectl-target-state.json, or ({}, {}) when the
    file is absent (no target-state debt). A malformed file fails closed."""
    if not os.path.exists(MANIFEST):
        return {}, {}
    with open(MANIFEST, encoding="utf-8") as fh:
        data = json.load(fh)
    leaves = {}
    for path, row in data.get("leaves", {}).items():
        leaves[path] = (row["issue"], set(row.get("flags", [])))
    flags = {}
    for path, row in data.get("flags", {}).items():
        flags[path] = {flag: entry["issue"] for flag, entry in row.items()}
    return leaves, flags


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


def check(base, cli, manifest_leaves, manifest_flags):
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
                if path in manifest_leaves:
                    issue, flags = manifest_leaves[path]
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
    # Prose flags: a `--flag` span on the same line as a `geectl` call cites
    # a flag geectl accepts, even though it sits outside the call span — a
    # typo there would sail through the call check above. Verify each
    # against every flag of every leaf the docs cite (the call check above
    # loaded those), the manifest rows, and the global options: a prose
    # flag may name another command's flag (`--description`, for the shell
    # safety the add-comment line points at), so the check is existence,
    # not which command takes it. A span naming another tool
    # (`tea … --login`) starts with that tool, not a flag, so it is not a
    # prose flag; a line with no `geectl` call has no command to attribute
    # the flag to, so it is skipped. Wrong forms define nothing.
    known = set(GLOBAL_OPTS)
    for _path, flags in cli.flags.items():
        known |= set(flags)
    for _issue, flags in manifest_leaves.values():
        known |= set(flags)
    for row in manifest_flags.values():
        known |= set(row)
    for doc in docs_of(base):
        rel = os.path.relpath(doc, ROOT)
        skip = wrong_ok if doc == usage else set()
        by_line = {}
        for n, text in spans(doc):
            by_line.setdefault(n, []).append(text)
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
                    if flag not in known:
                        findings.append(
                            (
                                rel,
                                n,
                                f"prose cites {flag}, which no cited "
                                "`geectl` command accepts",
                            )
                        )
    # A manifest row goes stale the moment the binary gains it.
    for path, (issue, _flags) in sorted(manifest_leaves.items()):
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
        manifest_leaves, manifest_flags = load_manifest()
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
