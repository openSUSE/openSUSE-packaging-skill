# Contributing to this repository

For whoever *changes* this repository, human or agent. The division of labour:

- **`README.md`** — for someone deciding whether to install the skill.
- **`skills/opensuse-packaging/SKILL.md`** — for the agent at run time. Loaded on every
  trigger, so it is byte-capped and routes rather than explains.
- **`AGENTS.md`** (this file) — conventions that would otherwise be rediscovered.

## Ground rules

- **Everything here is public.** No personal identifiers — not yours, not anyone else's:
  no forge or build-service usernames, e-mail addresses, real maintainer names, local home
  paths, or build hostnames. Write generically (`<your-obs-account>`, "the maintainer").
  Public record ids — `boo#`, `sr#`, CVE numbers, package names — are fine. `check-skills.py`
  enforces this; if one reaches the tip commit, amend and force-push with
  `--force-with-lease` rather than adding a scrub commit on top.
- **No tool or assistant attribution** anywhere: no `Co-authored-by`/`Assisted-by` trailers,
  no generated-with footers, no AI authorship claims in commits, PRs, docs or code comments.
- **Verify against upstream, not memory.** A rule worth writing down is worth checking
  first. Field experience is a hypothesis: most of it turns out to be already documented,
  already wrong, or true only of the one case that produced it.
- **Conventional Commits**, with the *why* in the body. The diff shows what changed; the
  message must say what it was for, and what you verified.
- **Own words.** Do not paste upstream documentation; state the rule and cite the source.

## Token budget

`SKILL.md` is injected whole on every trigger, so its size is a correctness property rather
than a matter of taste. The references are read one section at a time and must stay
readable that way.

- Budgets live in `tests/test-skill-budget.sh` and are enforced in CI. Adding to `SKILL.md`
  means trading something out of it.
- **State a rule once, in the file that owns the topic.** Elsewhere write a pointer:
  `references/<file>.md "<Section>"`, which is literally the argument list for
  `scripts/refsection.py`. `tests/test-doc-lint.sh` resolves every pointer, so a renamed
  section breaks the build instead of rotting.
- **Never tell anyone to read a reference whole** — same lint fails on it. Detail belongs in
  a reference section; `SKILL.md` gets a headline and the pointer.
- **Playbooks in `agents/` are read by sub-agents that never see `SKILL.md`.** Their
  "read this first" list must hold exactly the sections every run of that block needs;
  everything conditional goes in a trigger table. Brief a sub-agent with the playbook and
  the sections — never with "read SKILL.md".

## Scripts

- Every runnable script prints usage with `-h`/`--help`. A leading underscore
  (`_forges.py`) means an imported module, not a command.
- The docs cite exact invocations so an agent never spends a turn probing `--help`.
  `tests/repo/check-flags.py` checks every cited flag against the real `--help`.
- **A failed lookup must never read as good news.** This is the recurring bug class here:
  a watcher that reported success when its query failed, a status script that printed
  IN-SYNC when it could not read any version, a missing script whose "No such file" was
  counted as "nothing to do". When touching one, ask what an empty or failed fetch
  returns, and make it loud — exit non-zero and say UNKNOWN rather than guess.
- Output is compact plain text meant to be read by an agent in one tool result: no raw
  JSON dumps, no whole logs. Prefer one line per finding and a verdict line.
- Standard library only, Python 3.9+. The suites are offline; network lookups are stubbed.

## Before you push

Run what CI runs (README "Development"), and for anything new:

**Break it first.** A check that has never failed is not yet a check. Introduce the defect
it exists to catch, watch it go red, then make it pass. The obvious runner loop here,
`for t in ...; do bash "$t" || break; done`, returns 0 on a failing suite — it would have
reported success forever.

`main` is protected: work on a branch, open a PR, and let the required checks run.

## Adding to the skill

1. **A new rule** — decide which file owns the topic; add it there and point at it from
   anywhere else that needs it. Check the budget still passes.
2. **A new reference section** — give it a `##` heading so `refsection.py` can address it,
   and keep it independently readable: someone will read that section and nothing else.
3. **A new script** — add `--help`, a `## <script>` entry in `scripts/README.md` with its
   exit codes and the trap it encodes, a one-line mention in `SKILL.md`'s bundled-scripts
   list, and a test. Say what a failed lookup returns.
4. **A new skill** — a directory under `skills/` whose name equals its `name:` frontmatter,
   lowercase and hyphenated, carrying `license:`. Nothing inside a skill may reference a
   path outside its own directory: installers copy that directory verbatim.
