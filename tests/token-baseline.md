# Token baseline — 2026-09-13, before the diet

Numbers to beat. Re-measure with `tests/measure-reads.sh` (main-thread transcripts) and, after a
fan-out, on the agents' `.output` transcripts; tokens ≈ bytes/4.

| Item | Baseline |
|---|---|
| SKILL.md | 54,576 B ≈ 13,644 tok per trigger; body 53,788 B (loader cap ≈ 51,200 B) |
| references/ (11 files) | 461,657 B ≈ 115k tok; largest 108,413 / 106,847 / 76,988 B |
| agents/ (4) | 27,211 B; `update-build.md` mandates `update-build.md` + `specfile-guidelines.md` = 215 KB ≈ 54k tok per agent |
| Redundancy | gate chain ×7 (11.4 KB), insertion-only ×12 (16.7 KB), bugzilla ×18 (13.4 KB), patch naming ×14 (14.3 KB), spec-cleaner flags ×12 |
| Main thread, 15 sessions | 15 Skill invocations (205k tok), 105 Reads (188k tok); median consumer session = SKILL.md only |
| Fan-out (tokenscope, 180 agents) | 963M of 1,037M tok (93 %); median 55 steps × ~66k context/step |

Budgets: SKILL.md body ≤ 40,000 B; mandatory per-agent reading ≤ 48 KB (~12k tok); every reference
`##`-sectioned with `## Contents` when > 300 lines; every `file.md "Section"` pointer resolves.

## measure-reads.sh, 15 most recent main transcripts (2026-09-13)

```
transcripts: 15   SKILL.md: 54,576 B ≈ 13,644 tok
file                                         full part sess     ~tok
references/specfile-guidelines.md               0    7    3   14,152
references/language-packaging.md                1    0    1   10,042
references/git-workflow.md                      1    3    1    7,240
references/leap-slfo.md                         1    2    2    6,377
SKILL.md                                        0    9    4    6,155
references/update-build.md                      0   10    3    3,957
scripts/distro-survey.sh                        1    0    1    3,882
references/submit-watch.md                      0    4    2    3,338
agents/update-build.md                          0    1    1    1,515
README.md                                       2    1    2    1,455
references/bugzilla-cve-triage.md               0    5    4    1,325
references/triage.md                            0    1    1      886
scripts/leap-sync.sh                            0    1    1      431
scripts/build-summary.sh                        0    2    1      288
agents/submit-watch.md                          0    1    1      131
references/2-update-build.md                    0    1    1        0

Skill invocations: 15 in 13 sessions → 204,660 tok
Agent fan-outs: {'general-purpose': 472, 'osc-update-build': 54, 'osc-triage': 13, 'fork': 6, 'osc-submit-watch': 5, 'claude': 4, 'Explore': 3, 'Plan': 1}
```
