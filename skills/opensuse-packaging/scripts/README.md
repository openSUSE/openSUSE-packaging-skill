# Bundled scripts (`scripts/`)

Reference detail for the scripts listed one-line-each in `SKILL.md` "Bundled scripts".
Call these instead of hand-writing the osc-API / Repology / bugzilla / Gitea incantations
every time — they encode the exact queries that are easy to get subtly wrong. Every flag and
exit code is in `references/script-usage.md` (guarded against the scripts, so an agent needs
no `--help` call); this file carries the *why* and the traps.

Every runnable script prints usage with `-h`/`--help` (`_anitya.py` and `_forges.py` are
modules, not commands); the user-scoped ones (`my-packages`, `my-requests`, `sr-status`,
`preflight`) default the OBS account to `osc whois` unless `--user` is given
(`factory-report.py` uses `--highlight` for the same purpose).

## `my-packages.sh`

Packages where you are an **explicit package-level** maintainer (not project-inherited). Queries **both** maintainer indexes, which are disjoint: the OBS `_meta` person index *and* the git `_maintainership.json` side (`osc maintainer -U`) that scmsync packages use — an OBS-only query silently misses every git-hosted package (`--source obs|git|both`, `--show-source`).

## `my-requests.sh`

Your submit requests as a plain list (now a thin wrapper over `sr-status.py --brief --no-prs`, OBS side only).

## `incoming-requests.py`

Incoming OBS requests **and** src.opensuse.org PRs needing **you personally**, unlike `osc request list --incoming -U` (surfaces group-review noise too). Restricted to explicit person `role="maintainer"` targets / PRs where you're individually in `requested_reviewers` (both maintainer indexes, item 11); `by_group`/team-only items are skipped even if you're a member. `--verbose` counts what was skipped; `--no-prs` drops the Gitea leg.

## `sr-status.py`

**the Block-3 watch view**: OBS SRs *and* src.opensuse.org PRs (filed by you + awaiting your review) in one table, declines/closed-unmerged/needs-your-review first. Gitea leg needs a default `git-obs login`.

## `watch-submissions.sh`

The **cron/scheduled-prompt delta watcher**: diffs your active SRs, **incoming requests others filed against packages you maintain**, and open PRs against a saved baseline, printing only what changed since the last run (`NOCHANGE` → stay silent; `NEW`/`NEW INCOMING`/staging-move/`RESOLVE` lines → the caller fetches final states; `--no-incoming` opts out of that leg). `sr-status.py` answers "what's the status?", this answers "what changed?" without spamming on every firing. A `NEW INCOMING` line means *review and recommend*, never accept/decline — see core directive item 10.

## `outdated.py`

Repology "outdated in openSUSE Tumbleweed" ∩ your package set, cross-checked against live Factory, **plus a release-monitoring.org (Anitya) pass** over the names Repology did not flag — Repology's "newest" is only "newest packaged in some repo", so a release nobody has packaged yet is invisible to it; Anitya tracks upstreams directly and catches those (real case: libdispatch 6.3.3) — **and a forge pass** (GitHub/GitLab/PyPI/npm/crates.io from the spec `URL:`/`Source0:`, plus GitHub→npm `@owner/repo`; `--no-forge` skips it) for names neither index mapped. The forge pass applies the same registry-authority rule as `upstream-probe.py`. **No source may abort the sweep, and a lost source is not a clean bill of health**: any of the three can be down at any time (Repology often is), so an outage degrades to the remaining sources with one live WARNING per source — keeping whatever was already downloaded — and the report's last line is a short `# COVERAGE:` verdict naming what was lost (the detail is on the lines above it). **Exit 3 when a source was LOST** (could not answer: refused/timeout/403/429/5xx, or a non-JSON body — how a public API usually goes down; 403 is GitHub's rate limit and crates.io/npm's refusal, and a false outage costs a re-run where a false answer costs a silent clean sweep) or a pass never ran at all; 0 when every source answered or was skipped on purpose (`--no-repology`, `--no-anitya`, `--no-forge`, `--no-factory-check`). A 404 or "no releases and no datable tags" is the source *answering* about one package, and a name whose spec resolves to no forge at all was never checked by anything; both get their own line and neither degrades the run — otherwise exit 3 would be the steady state of every large sweep. That is what lets an unattended caller tell "nothing needs updating" from "nothing was checked". A names file or stdin with no names is exit 2, named as such — an empty set used to skip every pass and, beside a Repology outage, looked like the sweep had bailed.

## `upstream-probe.py`

Per-candidate date-based latest-upstream verdict (CURRENT / UPDATE-CANDIDATE / SUSPECT-renumbering); the Repology-false-positive deep check. Probes ALL resolvable sources at the same time — every forge found in `URL:`/`Source0:` (GitHub, GitLab, PyPI, npm, crates.io) plus release-monitoring.org by package name — merging by date; an Anitya-only newer stable elevates a would-be CURRENT to UPDATE-CANDIDATE (verify by hand, Anitya has no dates). **When `Source0:` is served by a package registry (pythonhosted/npm/crates), that registry decides the verdict** — a git tag ahead of it is not a release the package can consume, so a structural PyPI lag, a monorepo tag that is not the sub-package's version, or a repo carrying parallel artefact tag streams no longer reads as an update. Other sources are still probed and printed, with the authoritative one marked — except when the authoritative one is the source that went down, where there is no verdict and no context block to read a number off. When the spec resolves to no forge at all (homepage `URL:`, bare local `Source0:`), it falls back to the `_service` `obs_scm` url instead of giving up. One source going down degrades to a warning as long as another answers — **except the registry that serves `Source0:`, whose outage has no fallback** (another forge's tag is not a release this package can consume): that exits 2 with no verdict, naming the registry's own error, rather than answering from the wrong source. Only a transport failure counts; a 404 from the registry is an answer, and a `Source0:` whose name is still an unexpanded RPM macro is not a registry identity at all.

## `preflight.sh`

Block-2 step 0: is the update already done or in flight? exit 0/3/4 = proceed/stop/forward.

## `devel-of.sh`

The devel project registered for a package (exit 3 = not in target/new package, exit 4 = present but no devel project, exit 5 = lookup failed — never read as "new package").

## `autoforward-gate.sh`

May **your own** accepted request be forwarded onward unattended? **The gate is the `reviewer` role, NOT co-maintainership**: eligible when no explicit `reviewer` (person *or* group, package *or* project) is set *and* either you hold `maintainer` on the package, or the package has **no maintainer at all** and you hold `maintainer` on the project. A co-maintainer who never set a reviewer role has not asked to be consulted; an explicit `reviewer` has — and gating on "does anyone else co-maintain this" blocks most ordinary packages while catching nothing the reviewer role misses. exit 0 ELIGIBLE / 3 BLOCKED / 4 NOT_YOURS / 5 unreadable; `--batch <file>` takes `<project>\t<package>` lines and exits with the worst row (5 > 3 > 4 > 0), so one unreadable or foreign package never lets the set read as ELIGIBLE. **Applies only to requests you created** — accepting or declining someone else's is always an explicit human decision (core directive item 10) — and always check for an already in-flight target request first, since devel maintainers and OBS itself often auto-forward on accept.

## `gpg-verify.sh`

Verify a signed source tarball against a package keyring (handles the ASCII-armored-keyring trap).

## `build-summary.sh`

The last `osc build`'s verdict, `%check`/ctest pass count, rpmlint badness + E:/W: lines, produced RPMs (no sudo needed — the preserved log is readable). **Its exit code IS the verdict** (0 green / 1 failed / 2 no log / 3 never concluded), so gate on it rather than eyeballing a tail — the mechanical enforcement of "never state a build result you have not read". Resolves the build root from the oscrc template (`--list` shows them newest-first; a bare flavor name works).

## `soname-check.sh`

After building anything that ships a shared library, audit the produced RPMs for the **cross-version file-conflict trap**: a versioned symlink whose name is *not* the SONAME. A local build can never show this — it needs two versions installed at once, which first happens in the target project's staging, so it surfaces as a late reviewer decline on a submission that looked green. Also flags a bare unversioned `lib*.so` in a runtime package, and advises when a package name doesn't encode its SONAME version. Reads only rpm metadata (no extraction, no root). exit 0 clean / 3 findings / 2 nothing checked. Run it with no arguments to audit the last `osc build`, or pass RPMs / `--build-root <dir>`.

## `cone-status.sh`

Per-package build-status table for a whole project with a loopable exit code (0 green / 1 in-flight / 2 settled failure / 3 no answer: usage or a failed lookup, kept apart from a real build failure); encodes the stale-failure-while-rebuilding guard.

## `leap-sync.sh`

Content-sync a package's Leap pool branch up to factory and open the Package Hub PR; refuses new-to-Leap packages and already-open PRs.

## `leap-status.sh`

Is the package in Leap, at what version per branch, and is a PR ALREADY open? exit 0/1/2/3 = in-sync / behind-no-PR / behind-PR-open / not-in-Leap; 4 = no verdict (a branch's Version unreadable, or usage), 5 = network — neither ever reads as in-sync or PR-open.

## `scm-snapshot.sh`

Scaffold + verify a pinned-commit `obs_scm` `_service` for tagless upstreams (reproducible `X.Y.Z~gitYYYYMMDD.hash`); `--update` re-pins with moved-checks. **`--update` edits ONLY the obs_scm `<param name="revision">`, in place** — sibling services (`tar`/`recompress`/`set_version`/`cargo_vendor`/…) and the declared `versionformat` survive byte-for-byte, and `--base` is ignored. That matters because a pinned-snapshot package is rarely a lone `obs_scm`: rewriting the whole file would delete the vendoring/compression services *and* silently rewrite a `<base>+git…` versionformat to `<base>~git…`, which changes the package's version string. If the obs_scm block has no `revision` param it refuses and restores rather than guessing.

## `changes-prepend.sh`

Verified `.changes` prepend (separator-count + insertion-only checks; restores on failure).

## `changes-lint.sh`

Format-lint the newest N `.changes` entries (separators, headers, blank lines, bullets); the pre-SR gate against "fix the format of the changes entries" declines.

## `changes-patches.sh`

Factory-auto's patch-mention rule run locally against the SR **target** (not your branch's last commit, which already holds the change): each `*.patch`/`*.diff`/`*.dif` added or removed must have its literal filename on a single `+`/`-` line of the `.changes` diff — a glob, a `%{version}` form, a name split by the 67-col wrap, or a mention only in an untouched old entry all decline, and a rename counts twice. `--target PRJ` (default: the checkout's link origin, else Factory), `--base DIR` for offline use. Real case: a three-patch rename cost three SRs in a row.

## `changes-guard.sh`

Integrity gate: assert a `.changes` edit is *insertion-only* — the committed baseline must
remain an exact byte-suffix of the new file, so no already-committed entry can be overwritten,
folded in, reordered or deleted (auto-detects the baseline from `.osc/sources/` or
`git show HEAD`; `--base FILE` overrides the baseline outright). Runs at every commit gate next
to `changes-lint.sh`; the mechanical enforcement of "never modify previous entries" after a
fan-out agent breached it (folded a standalone prior entry into its new one).

**`--amend-top "<Your Name> <you@example.com>"` — amend your OWN top entry.** Use it while the
update is committed to devel (or pushed to an open PR/SR branch) but **not yet accepted into
Factory**: on a git branch the auto-detected baseline is the *branch HEAD*, which already
contains your own unmerged entry, so reworking it after review feedback trips the guard even
though nothing published was touched. That entry is a draft describing an unreleased revision,
and one coherent entry per submission beats stacking fixup bullets, so `--amend-top` permits
exactly that edit — grow, reword, rewrite, refresh the date. It still refuses any change from
the second entry down, a foreign top entry (in the baseline *or* the replacement), and emptying
the entry. Stop using it once the submission is accepted: the entry is history then — write a
new one.

**The one sanctioned override** is a header `check_dates_in_changes` rejects: the guard goes red
and you proceed anyway, but only with the evidence the rule demands — `references/changelog-rules.md`
"Sanctioned exception 2". Every *other* red guard is a real defect.

## Bugzilla — no bundled script

Bugzilla has **no bundled script** — **HARD RULE: all bugzilla access (reads AND writes) goes through the connected bugwarden MCP server** (`bugs_quicksearch`, `bug_info`, `bug_comments`, write tools); setup + migration in `references/bugzilla-cve-triage.md` §6, the maintained-packages bug sweep (with its false-positive pruning heuristics) in §1b.

## `distro-survey.sh`

Version (+ Fedora patch-count hint) across Fedora, Debian, Gentoo, Arch, Alpine, openEuler, Void, NixOS, FreeBSD ports, OpenMandriva and Mageia in one call (the cross-distro hard-rule set for items 8–9).

## `rdeps.sh`

Reverse build-deps via `_builddepinfo` (authoritative where `osc whatdependson` returns empty); the soname-bump rebuild-scope check.

## `wiki-drift.sh`

Compare the pinned wiki revisions in `references/wiki-provenance.tsv` against the live wiki and report drift for human review (`--diff` wikitext diff, `--update` re-pin after review); the only sanctioned bridge between the world-editable wiki and the vendored references — see `references/untrusted-content.md` "Wiki provenance and trust".

## `factory-report.py`

**contributor-activity report** for a project ("who is shipping Factory?", "most active contributors", "how do I compare"). Ranks accounts by accepted submit requests and writes a self-contained HTML page. Reports **two axes beside the count, always**, because the ranking alone conflates unlike jobs: **shape** (requests ÷ distinct packages — a distro-wide sweep sits near 1.0, a release train runs high) and **rhythm** (how many separate days/months the work landed on — `steady` vs `burst`, identical totals but very different review load). Buckets the cadence sparkline daily under ~92 days and monthly beyond, shading weekends on the daily form. **Which axis is informative depends on the window**: shape needs a year to discriminate (over 30 days nobody resubmits anything, so every shape collapses toward 1.0 — the page says so itself in a footnote), rhythm is the one that separates people over a month. `--json` gives the aggregates instead of the page; `--highlight` defaults to `osc whois`. Counts *requests*, not commits or lines — say so when presenting the numbers.

## `_anitya.py`

Shared release-monitoring.org (Anitya) lookup + version-normalize/compare module imported at runtime by `outdated.py` and `upstream-probe.py`; not directly runnable — do not prune it.

## `_forges.py`

Shared GitHub/GitLab/PyPI/npm/crates.io probe helpers imported by `upstream-probe.py` and `outdated.py`; not directly runnable — do not prune it.

## refsection.py

refsection.py — print ONE section of a skill doc instead of Reading the file.

The references are big (specfile-guidelines.md, update-build.md and
submit-watch.md are the largest at ~48-55 KB each); a whole-file Read burns the budget
on the ~95% you did not need (references/token-budget.md). Every pointer in
this skill is written as `references/<file>.md "<Section>"` — this turns that
pointer into a one-liner, replacing the two-step "grep -n '^#' then Read with
offset=/limit= and hope the window is right".

  refsection.py patches.md "Patches"                    # the section, whole
  refsection.py update-build.md "local builds"          # substring, case-insensitive
  refsection.py --list submit-watch.md                  # the heading outline
  refsection.py --lines update-build.md "Common build pitfalls"   # numbered, Read for more
  refsection.py --rule 3 7                              # numbered Core-directive rules of SKILL.md

A `##` section prints through the line before the next heading of the SAME or a
HIGHER level, so its `###` subsections come with it. Several matches are
ambiguous — except when one is an exact heading, or the parent of all the
others (you get them anyway). A match on a bold lead-in (`**Section** — ...`,
the paragraph form several references use instead of a heading) prints that
paragraph.

<file> may be a basename (`update-build.md`), a repo-relative path
(`references/leap-slfo.md`, `scripts/README.md`) or an absolute path; it is
resolved against the skill root (this script's parent's parent), so cwd does
not matter.

Exit: 0 printed · 1 no such section (all headings listed on stderr) · 2
ambiguous (candidates listed on stderr) · 3 usage / no such file.

Output is NOT sanitised, deliberately: these are first-party skill docs shipped
in this repo, not fetched content. references/untrusted-content.md scopes
`_sanitize.py` to third-party bytes — build logs, osc output, Bugzilla and
Gitea text, API dumps. Piping our own documentation through it would only
mangle the escapes the docs quote on purpose.

Ported from the SUSE-qe-update-validation skill (scripts/refsection.py); keep
the mechanics byte-compatible so fixes port both ways.

## gate.sh

The commit/SR gate chain as ONE tool call: source_validator, changes-lint.sh,
changes-guard.sh and changes-patches.sh, each run unpiped with its exit code
read directly, then one VERDICT line. Four separate calls cost four provider
steps and four result blocks that ride along in context for the rest of the
session; this costs one. The adversarial change review (agents/changes-review.md)
still follows — it is a judgement, not a check, and stays outside this script.

Usage: gate.sh [DIR] [--entries N] [--amend-top AUTHOR] [--target PRJ[/PKG]]
               [--build-log FILE] [--full]
  DIR          package checkout (default .)
  --entries N  entries the submission adds vs the target (changes-lint, default 1)
  --amend-top  the .changes top entry is yours and still unaccepted (changes-guard)
  --target     SR target for changes-patches (default: link origin, else Factory)
  --build-log  also run build-summary.sh on this osc build log (verdict only)
  --full       print every gate's complete output (default: last 12 lines each;
               full output is always saved under $TMPDIR/gate-<pkg>/)
Exit: 0 = every gate green, 1 = at least one red (VERDICT names them), 2 = usage.
