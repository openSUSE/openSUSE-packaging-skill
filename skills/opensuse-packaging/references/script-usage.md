# Script usage — every flag and exit code

The exact usage of every bundled script: don't run `--help`. CI checks each line against the script's `--help`: long flags, `-x|--long` pairs, which flags take a value, and the exit codes (not positionals or the wording of meanings). Why each exists and the traps it encodes: `scripts/README.md`.

## Triage

- `my-packages.sh [--project PRJ] [--user OBSUSER] [--source obs|git|both] [--all-projects] [--show-source]` — `--all-projects` keeps Backports/Leap/SLFO/ALP; exit 0 listed · 2 usage or query failed
- `outdated.py [--names FILE] [--project PRJ] [--repo REPO] [--ua UA] [--no-factory-check] [--no-anitya] [--no-forge] [--no-repology]` — names on stdin by default; exit 0 full coverage · 3 a source lost · 2 usage
- `upstream-probe.py [pkg] [--spec FILE] [--url URL --version V] [--project PRJ]` — exit 0 CURRENT · 1 UPDATE-CANDIDATE · 3 SUSPECT · 2 usage or no verdict
- `distro-survey.sh <pkg> [factory-version]` — env `DISTRO_SURVEY_BUDGET`, `DISTRO_SURVEY_TIMEOUT`; exit 0 printed · 2 usage
- `factory-report.py [--days N | --since YYYY-MM-DD] [--project PRJ] [--top N] [--highlight USER] [--role-account ACCT]... [--json] [-o|--output FILE]` — HTML by default; exit 0 written · 1 osc api failed or no SRs · 2 usage

## Update and build

- `preflight.sh <pkg> [target-version] [--target-project PRJ] [--user U]` — exit 0 PROCEED · 3 STOP · 4 FORWARD · 2 a check failed
- `build-summary.sh [repo-arch | flavor | root-name | root-path | logfile | --list]` — exit 0 green · 1 failed · 2 no log · 3 no verdict
- `soname-check.sh [file.rpm ... | --build-root DIR]` — no args: the last osc build; exit 0 clean · 3 findings · 2 usage or no RPMs
- `scm-snapshot.sh [git-url] [--rev SHA|BRANCH] [--base X.Y.Z] [--pkg NAME] [--update]` — url required unless `--update`, which re-pins `./_service` in place; exit 0 verified · 1 mismatch · 2 usage or a step failed
- `rdeps.sh <pkg-or-substring> [project] [repo] [arch]` — exit 0 listed · 1 no _builddepinfo · 2 usage
- `cone-status.sh <project> [repo] [arch]` — remote-build loop; exit 0 all green · 1 in flight · 2 settled failure · 3 no answer (usage or lookup failed)
- `gpg-verify.sh <tarball> <keyring> [signature]` — exit 0 good · 1 bad or unverifiable · 2 usage or unusable input

## Changelog and gates

- `gate.sh [DIR] [--entries N] [--amend-top AUTHOR] [--target PRJ[/PKG]] [--build-log FILE] [--full]` — exit 0 green · 1 red · 2 usage
- `changes-prepend.sh <name>.changes [--author 'Name <email>']` — bullets on stdin; author falls back to `$CHANGES_AUTHOR`, then git `user.name`/`user.email`; exit 0 verified · 1 verification failed (restored) · 2 usage or no author
- `changes-lint.sh [--entries N | --all] <file>.changes [...]` — exit 0 clean · 1 findings · 2 usage · 3 unreadable file (wins over 1)
- `changes-guard.sh [--base FILE] [--amend-top AUTHOR] <pkg>.changes [...]` — exit 0 insertion-only · 1 prior entry changed · 2 usage · 3 unreadable input (wins over 1)
- `changes-patches.sh [DIR] [--target PRJ[/PKG]] [--base DIR] [--git-base REF]` — exit 0 clean · 1 findings · 2 usage or lookup failed

## Submit and watch

- `sr-status.py [ID ...] [--user U] [--state open|all|declined|accepted] [--target PRJ] [--limit N] [--format table|blocks] [--brief] [--no-prs]` — exit 0 printed · 2 usage or OBS query failed
- `my-requests.sh [--state open|declined|accepted|all] [--user U] [--target PRJ]` — exit 0 listed · 2 usage or query failed
- `incoming-requests.py [--user U] [--format ascii|table|plain] [--verbose] [--no-prs]` — exit 0 listed · 2 usage or OBS query failed
- `watch-submissions.sh [--user U] [--login NAME] [--state-dir DIR] [--allow-empty] [--no-prs] [--no-incoming]` — baseline in `$XDG_STATE_HOME/osc-submission-watch` unless `--state-dir`; first line BASELINE-INIT, NOCHANGE, CHANGED or WATCH-ERROR; exit 0 · 2 WATCH-ERROR or usage
- `autoforward-gate.sh <project> <package> [--user U] | --batch FILE` — `--batch` exits with the worst row (5 > 3 > 4 > 0); exit 0 ELIGIBLE · 3 BLOCKED · 4 NOT_YOURS · 5 unreadable · 2 usage
- `devel-of.sh <package> [target-project]` — exit 0 prints devel/pkg · 3 not in target · 4 no devel project · 5 lookup failed · 2 usage

## Leap

- `leap-status.sh <pkg>` — exit 0 in sync · 1 behind, no PR · 2 behind, PR open · 3 not in Leap · 4 no verdict (a Version unreadable, or usage) · 5 network
- `leap-sync.sh [--refresh] <pkg> [leap-branch]` — exit 0 synced · 2 error · 3 new to Leap · 4 PR already open · 5 no factory branch · 6 network

## Skill upkeep

- `refsection.py [--lines] FILE SECTION | --list FILE | --anchor FILE ID | --rule N...` — exit 0 printed · 1 no such section · 2 ambiguous · 3 usage or no file
- `wiki-drift.sh [--diff] [--page TITLE]... [--update]` — exit 0 no drift · 1 drift · 2 error
