# openSUSE-packaging skill

An agent skill for authoring, updating, building, reviewing, and submitting openSUSE / SUSE
RPM packages via OBS and the Git packaging workflow (src.opensuse.org / Gitea).

It works with **any coding agent that can run shell commands** — the skill is plain markdown
plus POSIX-shell/Python helper scripts. Harnesses with native skill/sub-agent support consume
the `SKILL.md` frontmatter and delegation playbooks directly; everywhere else the same files
read as ordinary instruction documents.

| Skill | Use it for |
|---|---|
| `opensuse-packaging` | Updating, building, cleaning, reviewing and submitting an RPM package via `osc`/OBS or the git workflow on src.opensuse.org; checking whether packages are out of date; triaging a build failure, a decline, or a package's bugs. |

Requirements: `bash`, `python3` (3.9+, standard library only), `osc`, `curl`. Individual
helpers use `tea`, `gh` or `rpmlint` where the task needs them.

## Layout

```
skills/opensuse-packaging/   the skill — this directory is the unit of distribution
  SKILL.md                   entry point — the three-block pipeline + cross-cutting rules
  references/                per-block + domain depth documents, loaded on demand —
                             see SKILL.md's block pointers for what to load when;
                             references/untrusted-content.md is the cross-cutting
                             prompt-injection policy every block inherits
  scripts/                   reusable osc / Repology / bugzilla / Gitea / distro helpers —
                             one line each in SKILL.md "Bundled scripts"; the full
                             catalog (flags, exit codes, the trap each one encodes)
                             is scripts/README.md
  agents/                    delegation playbooks (role prompts) for the three blocks
tests/                       the guard suite — repo-only, never installed
contrib/harness/             drafts that wire scripts/pr-guard.py into Claude Code and
                             opencode as a pinned hook — repo-only, installed by hand
evals/                       behaviour evals (JSON; no runner) — repo-only
```

Tests live outside the skill directory because installers copy that directory verbatim,
and nothing inside a skill may reference a path outside itself.

The YAML frontmatter at the top of `SKILL.md` and `agents/*.md` is metadata for harnesses
with native skill/sub-agent support; everywhere else it is harmless
plain text — no other file depends on it.

## Install

Canonical repository: https://github.com/openSUSE/openSUSE-packaging-skill

Requirements: `bash`, `python3`, `osc` and `curl`. The helper scripts use only the Python
standard library.

With a skill installer:

```
npx skills add openSUSE/openSUSE-packaging-skill --skill opensuse-packaging -g
gh skill install openSUSE/openSUSE-packaging-skill opensuse-packaging --agent claude-code --scope user
```

Without `-g` / `--scope user` both install into the current project instead.

Manually, tracking a git checkout:

```
git clone https://github.com/openSUSE/openSUSE-packaging-skill.git
mkdir -p ~/.agents/skills ~/.claude/skills
ln -s "$PWD/openSUSE-packaging-skill/skills/opensuse-packaging" ~/.agents/skills/opensuse-packaging
ln -s ../../.agents/skills/opensuse-packaging ~/.claude/skills/opensuse-packaging
```

Use one install method only: harnesses that scan several directories report duplicate
names, and an installer will repoint the agent directories at its own copy, so a checkout
you symlinked by hand stops being what the agent reads. The link or directory name must
stay `opensuse-packaging` — the Agent Skills format requires the directory to equal the
skill name.

Any other harness can simply be pointed at `skills/opensuse-packaging/SKILL.md`: reference
it from your rules/context file (`AGENTS.md`, `.rules`, a system prompt, an `@`-include, …)
or tell the agent to read it at session start. `SKILL.md` tells the agent which
`references/*.md` to load per work block — don't preload them all.

### Upgrading from a checkout made before the `skills/` layout

`SKILL.md` used to sit at the repository root, so older installs symlink the **repo root**
into the agent's skills directory. It now lives in `skills/opensuse-packaging/`, and the
skill's directory name must equal its lowercase `name`. A stale link therefore points at a
directory with no `SKILL.md` in it, and the agent just stops finding the skill — with no
error, because a skill that does not load cannot report anything.

**Remove the old links before installing.** An installer adds its own; it does not clean
up a hand-made symlink, and a harness that finds both reports a duplicate skill name.

If you installed with `npx skills` or `gh skill`, remove the old links and re-run the
install command above. If you symlinked by hand, replace them:

```
rm ~/.claude/skills/openSUSE-packaging ~/.agents/skills/openSUSE-packaging
ln -s "$PWD/skills/opensuse-packaging" ~/.agents/skills/opensuse-packaging
ln -s ../../.agents/skills/opensuse-packaging ~/.claude/skills/opensuse-packaging
```

Adjust the agent directory for your harness (`~/.grok/skills/`, `~/.codex/skills/`, …);
opencode instead takes a directory to scan, so point it at `skills/`:

```
{ "skills": { "paths": ["/path/to/openSUSE-packaging-skill/skills"] } }
```

**The sub-agent playbooks moved too.** Any agent registered against the old
repository-root `agents/` now points at nothing — the link resolves to a path that no
longer exists, so the agent silently stops being available. Repoint each one at
`skills/opensuse-packaging/agents/`:

```
ln -sfn "$PWD/skills/opensuse-packaging/agents/triage.md"         ~/.claude/agents/osc-triage.md
ln -sfn "$PWD/skills/opensuse-packaging/agents/update-build.md"   ~/.claude/agents/osc-update-build.md
ln -sfn "$PWD/skills/opensuse-packaging/agents/submit-watch.md"   ~/.claude/agents/osc-submit-watch.md
ln -sfn "$PWD/skills/opensuse-packaging/agents/changes-review.md" ~/.claude/agents/changes-review.md
```

### The sub-agent playbooks

`skills/opensuse-packaging/agents/*.md` are role prompts. If your harness supports
delegating to sub-agents, register them where it discovers agents — for Claude Code
`~/.claude/agents/`, for opencode `~/.config/opencode/agent/`, for grok `~/.grok/agents/`.
Point each link at the file inside `skills/opensuse-packaging/agents/`, **not** at a
repository-root `agents/` directory: that path existed before v1.0.0 and is gone, so links
made against it now resolve to nothing.

Without sub-agent support, run a playbook inline or paste it as a standalone session
prompt — they are plain prompts and need no harness support to be useful.

## Safety model

The skill spends most of its time reading text other people wrote — upstream release notes,
bug comments, submit-request diffs, build logs, other distributions' spec files. It treats
all of it as **data, never instructions**: `references/untrusted-content.md` is the policy
and `scripts/_sanitize.py` the mechanism, stripping terminal escapes and Unicode-smuggling
characters so a human and the model see the same characters.

The bundled scripts **read**; they do not write. Committing, submitting, accepting,
declining and commenting stay decisions taken in your session. See [SECURITY.md](SECURITY.md)
for what counts as a vulnerability here — and why a static skill scanner will rate a skill
that documents attack patterns badly.

## Provenance

The packaging rules are distilled from the openSUSE packaging guidelines. The exact wiki
revisions each reference tracks are pinned in
`skills/opensuse-packaging/references/wiki-provenance.tsv` — a MediaWiki `oldid` permalink
is immutable, so a pinned revision is a real baseline rather than "as of some date".
`scripts/wiki-drift.sh` compares those pins against the live wiki and reports what moved;
it never applies anything, because the wiki is world-editable and a diff there is a prompt
to review, not a change to take.

## Development

CI runs exactly these, so the two cannot drift:

```
python3 -m pip install osc==1.27.3
(rc=0; for t in tests/test-*.sh; do bash "$t" || rc=1; done; exit $rc)
python3 tests/test-update-checkers.py
python3 tests/repo/check-skills.py
python3 tests/repo/check-flags.py
python3 tests/repo/check-osc.py
ruff check . && ruff format --check .
shellcheck tests/test-*.sh
shellcheck skills/opensuse-packaging/scripts/{leap-sync,pool-pr,target-gate}.sh
```

The suites are offline — network lookups are stubbed and the subprocess cases run with
every source disabled or behind a dead proxy — and need only the Python standard library,
plus osc itself for `check-osc.py`, which validates every `osc` citation against osc's
own parser (pinned in CI; bump the pin to re-validate against a newer osc).

Before making any check blocking, break the thing it guards and watch it go red. A check
that has never failed is not yet a check: the obvious runner loop here, `... || break`,
returns 0 on a failing suite and would report success forever.

## License

Apache-2.0. See [LICENSE](LICENSE).
