# Token budget — read narrow, surface the answer

Context is a budget: every byte a tool returns is re-sent on every later step of the session, and
a fan-out agent re-sends its whole context ~50 times. Measured on one 180-agent sweep, agents were
93 % of the spend; the largest single item was reference files read whole at step 0. These habits
are always-on, not a phase.

## Contents
- Reading this skill
- Briefing a sub-agent
- Tool output economy
- What a script must do

## Reading this skill
- **A section, not the file.** Every pointer in this skill is `references/<file>.md "<Section>"`;
  the pointer *is* the command: `python3 <skill>/scripts/refsection.py <file>.md "<Section>"`.
  `--list <file>.md` prints the outline; `--lines` numbers the output so a follow-up
  `Read offset=/limit=` can widen it. A bare file pointer means `--list` it first.
- **Never Read a reference whole.** The biggest (`submit-watch.md`, `specfile-guidelines.md`,
  `update-build.md`) are 48–55 KB each (~12–14k tokens) and none may exceed 60 KB; a whole-file Read
  still spends ~90 % of that on sections the task never touches. `--list` the outline, then read the
  one section. A section over ~12 KB has `###` sub-sections — name one of those instead.
- **Long sessions:** reload the skill only in a fresh session — a reload stacks a second copy in the
  context — and compact (or start fresh) after each landed artifact or wave.
- **SKILL.md is injected by the harness on trigger** — never Read it for content. In a sub-agent it is
  not injected at all; that is what the agent playbooks and rule pointers are for.
- **Read a further section only when its trigger fires**: a failed build → `update-build.md "Common
  build pitfalls"`; a Rust/Go/npm vendor tree → `language-packaging.md` (that language's section);
  a Leap/SLFO target → `leap-slfo.md`; a decline → `submit-watch.md "Triaging your declined submit
  requests"`. Not before.

## Briefing a sub-agent
- A spawned agent starts with an EMPTY context. Never brief it with "invoke the skill", "read
  SKILL.md" or "read references/x.md": quote the rule numbers it is bound by (number + one line)
  and name the ONE section it needs — or paste that section's `refsection.py` output into the brief
  when it is short. Give the absolute skill-root path; the agent's cwd is not the skill root.
- **Point the brief at a playbook, never at the references behind it.** `agents/update-build.md`,
  `agents/submit-watch.md`, `agents/triage.md` and `agents/changes-review.md` each open with the 1–5
  sections that block must read, written as `refsection.py` commands, plus a trigger table for
  everything else. That mandatory set is the agent's step-0 cost, measured:

  | playbook | mandatory sections | bytes | ≈ tokens |
  |---|---|---|---|
  | `agents/update-build.md` | 10 (+ the 0.8 KB entry template) | 43,700 | ~10.9k |
  | `agents/changes-review.md` | 4 | 33,400 | ~8.3k |
  | `agents/submit-watch.md` | 7 | 26,500 | ~6.6k |
  | `agents/triage.md` | 8 | 23,700 | ~5.9k |

  Budget: **≤ 48 KB per playbook**. A brief that adds "and read `references/<file>.md`" on top of a
  playbook is the regression this table exists to catch — it used to be 215 KB (two files) for the
  update-build agent, carried for ~55 steps.
- Ask for a report, not a transcript: the parent reads the result block on every later step.
  Verdicts, ids, sizes, the one surprising thing — not the log; **at most ~1.5 KB**, the full report
  in a file under `/var/tmp/<task>/`.
- **One package per child**, dispatched only after `scripts/preflight.sh` said proceed; never two
  children on one checkout. Resume an aborted child instead of starting over, and keep parallel
  children below the provider's concurrency limit.
- **The review runs in a context of its own** — a changes-review sub-agent, never the author's own
  context. A PASS the author wrote for its own change is no review.

## Tool output economy
- **Build logs never enter context.** `osc build … > log 2>&1 </dev/null`, then
  `scripts/build-summary.sh log` (its exit code is the verdict). On failure, grep the log for the
  error class and read that window with `sed -n`, never `cat`/`tail -500`.
- **Gates in one call**: `scripts/gate.sh` runs source_validator + changes-lint + changes-guard +
  changes-patches and prints one verdict block — four tool results become one.
- `osc diff` → `| head -N` or per-file; `osc log` → `-l N`; `osc results` → the package, not the
  project; `osc api` → pipe through a python one-liner that prints the fields you need.
- `sr-status.py --brief`, `preflight.sh`, `leap-status.sh`, `cone-status.sh`: read the VERDICT line
  first; open the detail only for the non-clean case.
- Third-party text (build logs, osc/Gitea/Bugzilla output) goes through `scripts/_sanitize.py`
  (`references/untrusted-content.md`); size discipline and injection defence are the same habit.
- **Waiting is one bounded call, never a loop.** A local build: `scripts/build-wait.sh`; an OBS build or request:
  `scripts/obs-wait.py`. Each `sleep N; osc results` or `tail` round rereads the whole context — one
  10-day session spent ~430 M tokens on ~900 such rounds.
- **Batch independent probes** into one tool call (or parallel calls) instead of one per step.
- **Long lines slip past `head -n`** (a linker command line, `ps aux`): add `cut -c1-300`. Never run a
  bare `osc ls` — it lists every project on the server.
- Don't re-fetch what a result already holds; don't re-read a file you edited to "verify" — Edit/Write
  fail loudly, and the harness tracks file state.

## What a script must do
- Print a **verdict line** the caller can act on, then only the rows that matter; row counts and
  the path to the full output go to stderr or a file.
- Offer `--brief`/`--limit`/`--json`, cap cells, and never echo an input file back.
- `--help` re-prints its own header comment, for humans; agents read the script's line in
  `script-usage.md` (CI keeps the two in step). Duplicate neither in SKILL.md.
