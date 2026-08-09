# openSUSE-packaging skill

An agent skill for authoring, updating, building, reviewing, and submitting openSUSE / SUSE
RPM packages via OBS and the Git packaging workflow (src.opensuse.org / Gitea).

It works with **any coding agent that can run shell commands** — the skill is plain markdown
plus POSIX-shell/Python helper scripts. Harnesses with native skill/sub-agent support consume
the `SKILL.md` frontmatter and delegation playbooks directly; everywhere else the same files
read as ordinary instruction documents.

## Layout

```
SKILL.md                     entry point — the three-block pipeline + cross-cutting rules
references/                  per-block + domain depth documents, loaded on demand —
                             see SKILL.md's block pointers for what to load when;
                             references/untrusted-content.md is the cross-cutting
                             prompt-injection policy every block inherits
scripts/                     reusable osc / Repology / bugzilla / Gitea / distro helpers —
                             see SKILL.md "Bundled scripts" for the catalog
agents/                      delegation playbooks (role prompts) for the three blocks
```

The YAML frontmatter at the top of `SKILL.md` and `agents/*.md` is metadata for harnesses
with native skill/sub-agent support; everywhere else it is harmless
plain text — no other file depends on it.

## Install

Clone the repo anywhere and point your agent at `SKILL.md` as context — reference it from
your harness's rules/context file (`AGENTS.md`, `.rules`, a system prompt, an
`@`-include, …) or just tell the agent to read it at session start. `SKILL.md` tells the
agent which `references/*.md` to load per work block (don't preload them all) and catalogs
the `scripts/` helpers, which need only `bash`, `python3`, `osc`, and `curl`.

The `agents/*.md` playbooks are role prompts: if your harness supports delegating to
sub-agents/sub-tasks, use one as the sub-agent's instructions; otherwise run the playbook
inline in the main session or paste it as a standalone session prompt.

Harnesses with native skill/sub-agent support: place (or symlink) the repo where the harness
discovers skills, and register the `agents/*.md` playbooks wherever it discovers agents so the
three blocks become first-class delegatable agents.

## License

Apache-2.0. See [LICENSE](LICENSE).
