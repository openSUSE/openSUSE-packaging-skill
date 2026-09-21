#!/usr/bin/env python3
"""Repository gates: skill frontmatter, public-content hygiene, attribution.

Three checks the other suites cannot make, because they are about what the
repository publishes rather than what the scripts do:

  frontmatter  the Agent Skills contract -- a skill that violates it installs
               wrong or refuses to publish, and nothing else here would notice
  public       this is a public repository: no personal identifiers, anyone's,
               and that rule is only as good as something that enforces it
  attribution  no tool/assistant attribution in the published files

Budgets and cross-reference pointers are deliberately NOT here: tests/
test-skill-budget.sh and tests/test-doc-lint.sh already own those, and a second
implementation would drift from the first.

  python3 tests/repo/check-skills.py [--only frontmatter,public,attribution]

Prints "<check>: <file>[:<line>]: <message>" per finding; exit 1 on any
finding, 0 when clean.
"""

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SKILLS = os.path.join(ROOT, "skills")

# ---------------------------------------------------------------- frontmatter

# The Agent Skills spec's keys. An unknown key is an error rather than a
# warning: publishers reject what they do not recognise.
ALLOWED_KEYS = {
    "name",
    "description",
    "license",
    "compatibility",
    "metadata",
    "allowed-tools",
}
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def _frontmatter(path):
    """The YAML block as {key: (value, lineno)}. Hand-parsed: PyYAML is not a
    dependency of this repository and the block is a flat mapping."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    out, key = {}, None
    for i, line in enumerate(lines[1:], start=2):
        if line.strip() == "---":
            return out
        if line[:1] in (" ", "\t") and key:  # continuation of a folded scalar
            out[key] = (out[key][0] + " " + line.strip(), out[key][1])
            continue
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if value in (">-", ">", "|", "|-"):
            value = ""
        out[key] = (value, i)
    return None  # unterminated


def check_frontmatter(findings):
    if os.path.exists(os.path.join(ROOT, "SKILL.md")):
        findings.append(
            (
                "frontmatter",
                "SKILL.md",
                None,
                "a SKILL.md at the repository root hides skills/ from installers",
            )
        )
    if not os.path.isdir(SKILLS):
        findings.append(("frontmatter", "skills/", None, "no skills/ directory"))
        return
    names = sorted(
        d for d in os.listdir(SKILLS) if os.path.isdir(os.path.join(SKILLS, d))
    )
    if not names:
        findings.append(("frontmatter", "skills/", None, "no skill directories"))
    for name in names:
        rel = f"skills/{name}/SKILL.md"
        path = os.path.join(SKILLS, name, "SKILL.md")
        if not os.path.exists(path):
            findings.append(("frontmatter", rel, None, "missing SKILL.md"))
            continue
        fm = _frontmatter(path)
        if fm is None:
            findings.append(
                ("frontmatter", rel, 1, "no terminated YAML frontmatter block")
            )
            continue
        for key, (_, line) in sorted(fm.items()):
            if key not in ALLOWED_KEYS:
                findings.append(
                    ("frontmatter", rel, line, f"unknown frontmatter key `{key}`")
                )
        if "name" not in fm:
            findings.append(("frontmatter", rel, 1, "missing `name`"))
        else:
            value, line = fm["name"]
            if not NAME_RE.match(value):
                findings.append(
                    (
                        "frontmatter",
                        rel,
                        line,
                        f"`name: {value}` must be lowercase alphanumeric with single hyphens",
                    )
                )
            if len(value) > 64:
                findings.append(
                    ("frontmatter", rel, line, "`name` exceeds 64 characters")
                )
            if value != name:
                findings.append(
                    (
                        "frontmatter",
                        rel,
                        line,
                        f"`name: {value}` must equal its directory `{name}`",
                    )
                )
        if "description" not in fm:
            findings.append(("frontmatter", rel, 1, "missing `description`"))
        else:
            value, line = fm["description"]
            if not 1 <= len(value) <= 1024:
                findings.append(
                    (
                        "frontmatter",
                        rel,
                        line,
                        f"`description` is {len(value)} characters, want 1-1024",
                    )
                )
        if "license" not in fm:
            findings.append(("frontmatter", rel, 1, "missing `license`"))
        if fm.get("allowed-tools", ("", 0))[0].lstrip().startswith("-"):
            findings.append(
                (
                    "frontmatter",
                    rel,
                    fm["allowed-tools"][1],
                    "`allowed-tools` must be a space-delimited string, not a list",
                )
            )


# --------------------------------------------------------------------- public

# This repository is public. Personal identifiers -- ours or anyone else's --
# belong in a maintainer's local notes, never here. Patterns are generic on
# purpose: a denylist of real usernames would publish the very names it guards.
PUBLIC_PATTERNS = [
    # A real e-mail address. Placeholders and role addresses are allowed below.
    (r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "e-mail address"),
    # A personal home directory. /home/abuild is the RPM build root, and
    # test/user/... are documentation placeholders -- none of them is a person.
    (
        r"/home/(?!(?:abuild|test|user|username|youruser|builder|packager)\b)[a-z][a-z0-9_-]*",
        "home directory path",
    ),
    (r"/Users/[A-Za-z][A-Za-z0-9_-]*", "home directory path"),
    # A build or lab host, as opposed to a documented service endpoint.
    (r"\b[a-z][a-z0-9-]*\.(?:qam|qa|lab)\.suse\.(?:de|cz|com)\b", "build host"),
    (r"#(?:team|discuss|proj|eng)-[\w-]+", "chat channel"),
    # An OBS home project names its owner. `home:<user>` and `home:<user>:sub`
    # are account names as surely as an e-mail address is, and this pattern was
    # missing when a real one reached a published release.
    (r"\bhome:(?!<)[A-Za-z][\w.-]*", "OBS home project (names its owner)"),
]
# Addresses that are roles or documentation placeholders, not people.
PUBLIC_ALLOW = re.compile(
    r"""
    (?:^|[^\w.-])(?:
        [\w.+-]+@(?:example\.(?:com|org|net)|[\w.-]*\.example)   # placeholders
      | (?:security-team|screening-team-bugs|maintenance)@suse\.de  # role addresses
      | gitea@src\.opensuse\.org                                 # service account
      | you@|jane@|[\w.+-]+@distro\.example
    )
    """,
    re.VERBOSE | re.IGNORECASE,
)

# ---------------------------------------------------------------- attribution

# Scoped to attribution proper -- trailers, footers, authorship claims. A bare
# vendor or product name is NOT included: this skill legitimately documents
# agent CLIs and their config paths, and flagging those would train everyone to
# ignore the check.
ATTRIBUTION_PATTERNS = [
    (r"co-authored-by\s*:", "co-author trailer"),
    (r"assisted-by\s*:\s*(?!<)\S", "Assisted-by trailer naming a concrete model"),
    (
        r"generated (?:with|by) (?:\[?)(?:claude|chatgpt|gpt|copilot|gemini|an? (?:ai|llm))",
        "generated-with footer",
    ),
    (
        r"\b(?:written|authored|produced|created) (?:by|with) (?:an? )?(?:ai|llm|assistant|language model)\b",
        "AI authorship claim",
    ),
    ("\U0001f916", "robot emoji"),
]

SKIP_DIRS = {".git", "__pycache__", ".ruff_cache", ".github"}
# Trees that exist to imitate hostile or third-party text: scanning them would
# report the fixtures' own contents as leaks. Note this is the files/ tree only
# -- evals.json itself is authored here and stays in scope.
SKIP_TREES = ("tests/fixtures", "evals/opensuse-packaging/files")
SKIP_FILES = {"LICENSE", "tests/repo/check-skills.py"}
TEXT_EXT = {".md", ".py", ".sh", ".txt", ".tsv", ".yml", ".yaml", ".json", ".cc", ""}


def _text_files():
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in files:
            full = os.path.join(base, fn)
            rel = os.path.relpath(full, ROOT)
            if rel in SKIP_FILES or rel.startswith(SKIP_TREES):
                continue
            if os.path.splitext(fn)[1].lower() not in TEXT_EXT:
                continue
            yield rel, full


def _scan(findings, check, patterns, allow=None):
    compiled = [(re.compile(p, re.IGNORECASE), label) for p, label in patterns]
    for rel, full in _text_files():
        try:
            with open(full, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for n, line in enumerate(lines, start=1):
            for rx, label in compiled:
                for m in rx.finditer(line):
                    if allow and allow.search(line[max(0, m.start() - 1) : m.end()]):
                        continue
                    findings.append((check, rel, n, f"{label}: {m.group(0)}"))


def check_public(findings):
    _scan(findings, "public", PUBLIC_PATTERNS, allow=PUBLIC_ALLOW)


def check_attribution(findings):
    _scan(findings, "attribution", ATTRIBUTION_PATTERNS)


CHECKS = {
    "frontmatter": check_frontmatter,
    "public": check_public,
    "attribution": check_attribution,
}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="check-skills.py", description=__doc__)
    ap.add_argument(
        "--only",
        default=",".join(CHECKS),
        help="comma-separated subset of: " + ", ".join(CHECKS),
    )
    args = ap.parse_args(argv)
    wanted = [c.strip() for c in args.only.split(",") if c.strip()]
    unknown = [c for c in wanted if c not in CHECKS]
    if unknown:
        ap.error("unknown check(s): " + ", ".join(unknown))

    findings = []
    for name in wanted:
        CHECKS[name](findings)
    for check, path, line, msg in findings:
        where = f"{path}:{line}" if line else path
        print(f"{check}: {where}: {msg}")
    if findings:
        print(f"\n{len(findings)} finding(s)", file=sys.stderr)
        return 1
    print("ok - all repository checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
