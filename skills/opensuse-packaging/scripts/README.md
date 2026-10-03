# Bundled scripts (`scripts/`)

Reference detail for the scripts listed one-line-each in `SKILL.md` "Bundled scripts".
Call these instead of hand-writing the osc-API / Repology / bugzilla / Gitea incantations
every time — they encode the exact queries that are easy to get subtly wrong. Every flag and
exit code is in `references/script-usage.md` (guarded against the scripts, so an agent needs
no `--help` call); this file carries the *why* and the traps.

Every runnable script prints usage with `-h`/`--help` (`_anitya.py`, `_forges.py` and
`_pr_guard.py` are modules, not commands); the user-scoped ones (`my-packages`, `my-requests`, `sr-status`,
`preflight`) default the OBS account to `osc whois` unless `--user` is given
(`factory-report.py` uses `--highlight` for the same purpose).

## `my-packages.sh`

Packages where you are an **explicit package-level** maintainer (not project-inherited). Queries **both** maintainer indexes, which are disjoint: the OBS `_meta` person index *and* the git `_maintainership.json` side (`osc maintainer -U`) that scmsync packages use — an OBS-only query silently misses every git-hosted package (`--source obs|git|both`, `--show-source`).

## `my-requests.sh`

Your submit requests as a plain list (now a thin wrapper over `sr-status.py --brief --no-prs`, OBS side only).

## `incoming-requests.py`

Incoming OBS requests **and** src.opensuse.org PRs needing **you personally**, unlike `osc request list --incoming -U` (surfaces group-review noise too). Restricted to explicit person `role="maintainer"` targets / PRs where you're individually in `requested_reviewers` (both maintainer indexes, item 11); `by_group`/team-only items are skipped even if you're a member. `--verbose` counts what was skipped; `--no-prs` drops the Gitea leg. The Gitea leg reads through `git-obs -G src.opensuse.org api` (git-obs reads its login itself, shared with tea by default; the script never reads it); when it fails, the output says the PRs are UNKNOWN (a line under the table, or instead of "nothing pending"). Every osc / git-obs call times out after 60s and counts as a failed query.

## `sr-status.py`

**the Block-3 watch view**: OBS SRs *and* src.opensuse.org PRs (filed by you + awaiting your review) in one table, declines/closed-unmerged/needs-your-review first. Gitea leg reads through `git-obs -G src.opensuse.org api`: git-obs reads its login itself (shared with tea by default) and the script never reads it; `-G` picks the login of that name, or the only one for that host, since a default login may be another forge; a failed leg is a warning and the header marks the PRs UNKNOWN. Every osc / git-obs call times out after 60s and counts as a failed lookup, never an empty answer. A declined SR that a later accepted one for the same package and target replaced reads `declined; later #N accepted — revoke: osc rq revoke -m "replaced by #N" <id>` and stays at the top as cleanup: osc still counts a declined request, and the next `osc sr` from that source prompts over it. Only when both are in the fetched set (`--state all`, or both ids given); the default view fetches no accepted requests, and no call is added for it.

**An open `pool/` PR's row reads its build from OBS, not from the staging bot's last comment** — the bot's comment, and a green build of an older commit, are exactly the evidence that let a red PR look done. It finds the `…:PullRequest:<n>` project in the latest `autogits_obs_staging_bot` comment (a link a human pastes is ignored), compares that project's `_scmsync.obsinfo` `commit:` with the PR head, and reads `osc results --xml`. Before it calls a PR green it reads the last `_jobhistory` job of every succeeded arch and flavor (not `_history`: an unchanged rebuild of a new commit adds no entry there): a srcmd5 other than the package's current expanded source is the previous commit's build still standing (the scheduler has not caught up), so pending — one source lookup plus one per succeeded arch and flavor, only for a PR that would otherwise read green. Red, stale and unreadable rows sort first, like declines. **Stale** (built commit ≠ head) usually means a hand-made `products/PackageHub` PR pins the old commit and does not follow pushes; the row names that products PR and whether its head is the bot's `PR_<pkg>#<n>` branch or hand-made. `--pr OWNER/REPO#N` gives one PR's verdict as an exit code: 0 green at the head or merged · 1 red at the head (a failure beats arches still building; every arch excluded or disabled is red, "nothing built") or closed unmerged · 3 pending (no bot comment yet, building, dirty — an excluded or disabled arch in a dirty repository too —, no results, a succeeded arch not yet rebuilt from the current sources) · 4 stale · 2 a lookup failed · 6 network. A failed lookup — the srcmd5 and `_jobhistory` reads included — never softens a verdict: it is UNKNOWN with 2 or 6, never green or pending. A pool PR is done only at 0.

## `watch-submissions.sh`

The **cron/scheduled-prompt delta watcher**: diffs your active SRs, **incoming requests others filed against packages you maintain**, and open PRs against a saved baseline, printing only what changed since the last run (`NOCHANGE` → stay silent; `NEW`/`NEW INCOMING`/staging-move/`RESOLVE` lines → the caller fetches final states; `--no-incoming` opts out of that leg). `sr-status.py` answers "what's the status?", this answers "what changed?" without spamming on every firing. A `NEW INCOMING` line means *review and recommend*, never accept/decline — see core directive item 10.

## `outdated.py`

Repology "outdated in openSUSE Tumbleweed" ∩ your package set, cross-checked against live Factory, **plus a release-monitoring.org (Anitya) pass** over the names Repology did not flag — Repology's "newest" is only "newest packaged in some repo", so a release nobody has packaged yet is invisible to it; Anitya tracks upstreams directly and catches those (real case: libdispatch 6.3.3) — **and a forge pass** (GitHub/GitLab/PyPI/npm/crates.io from the spec `URL:`/`Source0:`, plus GitHub→npm `@owner/repo`; `--no-forge` skips it) for names neither index mapped. The forge pass applies the same registry-authority rule as `upstream-probe.py`. **No source may abort the sweep, and a lost source is not a clean bill of health**: any of the three can be down at any time (Repology often is), so an outage degrades to the remaining sources with one live WARNING per source — keeping whatever was already downloaded — and the report's last line is a short `# COVERAGE:` verdict naming what was lost (the detail is on the lines above it). **Exit 3 when a source was LOST** (could not answer: refused/timeout/403/429/5xx, or a non-JSON body — how a public API usually goes down; 403 is GitHub's rate limit and crates.io/npm's refusal, and a false outage costs a re-run where a false answer costs a silent clean sweep) or a pass never ran at all; 0 when every source answered or was skipped on purpose (`--no-repology`, `--no-anitya`, `--no-forge`, `--no-factory-check`). A 404 or "no releases and no datable tags" is the source *answering* about one package, and a name whose spec resolves to no forge at all was never checked by anything; both get their own line and neither degrades the run — otherwise exit 3 would be the steady state of every large sweep. That is what lets an unattended caller tell "nothing needs updating" from "nothing was checked". A names file or stdin with no names is exit 2, named as such — an empty set used to skip every pass and, beside a Repology outage, looked like the sweep had bailed.

## `upstream-probe.py`

Per-candidate date-based latest-upstream verdict (CURRENT / UPDATE-CANDIDATE / SUSPECT-renumbering); the Repology-false-positive deep check. Probes ALL resolvable sources at the same time — every forge found in `URL:`/`Source0:` (GitHub, GitLab, PyPI, npm, crates.io) plus release-monitoring.org by package name — merging by date; an Anitya-only newer stable elevates a would-be CURRENT to UPDATE-CANDIDATE (verify by hand, Anitya has no dates). **When `Source0:` is served by a package registry (pythonhosted/npm/crates), that registry decides the verdict** — a git tag ahead of it is not a release the package can consume, so a structural PyPI lag, a monorepo tag that is not the sub-package's version, or a repo carrying parallel artefact tag streams no longer reads as an update. Other sources are still probed and printed, with the authoritative one marked — except when the authoritative one is the source that went down, where there is no verdict and no context block to read a number off. When the spec resolves to no forge at all (homepage `URL:`, bare local `Source0:`), it falls back to the `_service` `obs_scm` url instead of giving up. One source going down degrades to a warning as long as another answers — **except the registry that serves `Source0:`, whose outage has no fallback** (another forge's tag is not a release this package can consume): that exits 2 with no verdict, naming the registry's own error, rather than answering from the wrong source. Only a transport failure counts; a 404 from the registry is an answer, and a `Source0:` whose name is still an unexpanded RPM macro is not a registry identity at all.

## `preflight.sh`

Block-2 step 0: is the update already done or in flight? exit 0/3/4 = proceed/stop/forward. For a git devel project it reads the open PRs through `git-obs -G src.opensuse.org api`; a failed or unreadable answer exits 2, never "none".

## `devel-of.sh`

The devel project registered for a package (exit 3 = not in target/new package, exit 4 = present but no devel project, exit 5 = lookup failed — never read as "new package").

## `autoforward-gate.sh`

May **your own** accepted request be forwarded onward unattended? **The gate is the `reviewer` role, NOT co-maintainership**: eligible when no explicit `reviewer` (person *or* group, package *or* project) is set *and* either you hold `maintainer` on the package, or the package has **no maintainer at all** and you hold `maintainer` on the project. A co-maintainer who never set a reviewer role has not asked to be consulted; an explicit `reviewer` has — and gating on "does anyone else co-maintain this" blocks most ordinary packages while catching nothing the reviewer role misses. exit 0 ELIGIBLE / 3 BLOCKED / 4 NOT_YOURS / 5 unreadable; `--batch <file>` takes `<project>\t<package>` lines and exits with the worst row (5 > 3 > 4 > 0), so one unreadable or foreign package never lets the set read as ELIGIBLE. **Applies only to requests you created** — accepting or declining someone else's is always an explicit human decision (core directive item 10) — and always check for an already in-flight target request first, since devel maintainers and OBS itself often auto-forward on accept.

## `gpg-verify.sh`

Verify a signed source tarball against a package keyring (handles the ASCII-armored-keyring trap).

## `build-summary.sh`

The last `osc build`'s verdict, `%check`/ctest pass count, rpmlint badness + E:/W: lines, produced RPMs (no sudo needed — the preserved log is readable). **Its exit code IS the verdict** (0 green / 1 failed / 2 no log / 3 never concluded), so gate on it rather than eyeballing a tail — the mechanical enforcement of "never state a build result you have not read". Resolves the build root from the oscrc template (`--list` shows them newest-first; a bare flavor name works).

## `build-wait.sh`

One bounded wait for a local `osc build` started in the background as its own process group (`set +m; setsid -w osc build … </dev/null >LOG 2>&1 &`; under job control `setsid` forks, so `$!` would name only the waiting `setsid` and `kill -- -$!` would leave the build running), in place of a `sleep N; tail LOG` loop whose every round rereads the whole agent context: it watches the group with `pgrep -g` (osc waits for its build, so the group lives until the build ends) for up to `--max` seconds (default 540, for a 10-minute tool call), then hands over to `build-summary.sh LOG`, so its exit code is the verdict (0 green / 1 failed / 2 no log / 3 never concluded); exit 4 while the build still runs, with the log's last line sanitized — call it again. A pid that leads no group is refused (exit 5), and the verdict comes only from LOG, never from a build root's `.build.log`, which still holds the previous build until this one starts.

## `soname-check.sh`

After building anything that ships a shared library, audit the produced RPMs for the **cross-version file-conflict trap**: a versioned symlink whose name is *not* the SONAME. A local build can never show this — it needs two versions installed at once, which first happens in the target project's staging, so it surfaces as a late reviewer decline on a submission that looked green. Also flags a bare unversioned `lib*.so` in a runtime package, and advises when a package name doesn't encode its SONAME version. Reads only rpm metadata (no extraction, no root). exit 0 clean / 3 findings / 2 nothing checked. Run it with no arguments to audit the last `osc build`, or pass RPMs / `--build-root <dir>`.

## `cone-status.sh`

Per-package build-status table for a whole project with a loopable exit code (0 green / 1 in-flight / 2 settled failure / 3 no answer: usage or a failed lookup, kept apart from a real build failure); encodes the stale-failure-while-rebuilding guard.

## `obs-wait.py`

One bounded wait for ONE build (`build PRJ PKG`, every repo/arch and multibuild flavor, or `--repo`/`--arch`) or ONE request (`request ID`), in place of a `sleep` loop: exit 0 green or accepted / 1 still pending at `--timeout` (default 80 s; the call runs that plus one osc check, under a tool call's limit), so repeat the same call on a later turn / 2 settled failure (failed, unresolvable, broken, an unknown code, nothing to build; declined, revoked, superseded, deleted) / 3 no answer. It opens OBS's event stream (`references/remote-builds.md` "OBS event feed") and waits for its first event **before** the first osc check, since checking first loses an event that lands in between, and **an event is only a wake-up: every verdict comes from osc**. A build is judged on the current expanded sources only: each succeeded or failed repo/arch counts once its last `_jobhistory` job is of that srcmd5 — not `_history`, which an unchanged rebuild never updates — otherwise it is pending, and a settled failure beats arches still building. It ignores events whose srcmd5 is older, and matches a request by the payload's `number` alone (`id` is a database id). It asks osc again every `--recheck` s (default 300) and once at the timeout, since unresolvable, broken, excluded and disabled send no event, and after every reconnect (events during a disconnect are lost). The stream is read on a daemon thread with a 60 s socket timeout, so a stalled stream can neither hold the call past `--timeout` nor go unnoticed; unreachable, not an event stream, or lost three times in one call, it polls osc every `--recheck` s (default 30) inside the same bound and says so on stderr. Standard library only. **A failed or unreadable osc lookup is exit 3 wherever it happens, never pending or green** — so is a succeeded result with no job on record. It covers OBS only: src.opensuse.org PRs stay with `sr-status.py --pr`. In a dep cone a package's `unresolvable` can be transient; the cone's verdict is `cone-status.sh`.

## `leap-sync.sh`

Content-sync a package's Leap pool branch up to factory and build that exact tree against the Leap target; it **stops there: no PR head is pushed and no PR written** (no `tea`) — only `--remote` pushes, through `target-gate.sh --remote`, the fork build branch `leapgate/<base>-<sha12>` over SSH — then prints the review, `target-gate.sh --review` and `pool-pr.sh` steps. One clone per package at `D/pool/<pkg>` on factory, one worktree per base at `D/<leap-branch>/<pkg>` tracking `origin/<leap-branch>` — the folder is named after the package because osc falls back to it — so a 16.0 and a 16.1 sync never share a checkout. It compares *trees*, not versions (a same-version spec/patch change still syncs), fetches LFS objects for the synced tree only — `git lfs fetch origin HEAD` in the worktree, because a bare `factory` names the reused clone's local branch, which lags `origin/factory`; never `--all`: pool repos carry pruned objects on old branches —, then runs `target-gate.sh --build` (`--remote` with `--remote`). Refuses before cloning: a branch that is not `leap-16.N` (SLFO needs the user's route), a `--dir` under `/tmp`, an existing worktree (a hand-edited tree is never reset), someone else's open PR on the base (exit 4; your own is `pool-pr.sh`'s to update, and since a re-sync is rebuilt on `origin/<leap-branch>` it never contains that PR's head: moving the PR to it takes `--replace`, after checking what the PR carries), a new-to-Leap package (exit 3). On a reused clone it also refuses (exit 2) a local `<leap-branch>` carrying commits `origin` lacks — the sync's `worktree add -B` would reset them; a failed comparison refuses too: continue on that branch, or `branch -D` it deliberately. A failure before the build removes the half-made worktree and a freshly made clone; once the build has run the tree is kept. Exit 7 = target build red, 8 = remote build pending. `--refresh` is gone (exit 2): `pool-pr.sh` updates an open PR. It runs the `target-gate.sh` beside its resolved path, so a symlinked copy cannot pick up a stand-in, and reads the open PRs through `git-obs -G src.opensuse.org api`, which holds the login: the script reads no credential file.

## `target-gate.sh`

Builds **the exact tree a Leap pool PR will carry, against that PR's own target** — `openSUSE:Backports:SLE-16.0` or `-16.1` `standard`, on the arches of `openSUSE:Backports:SLE-16.x:PullRequest` `standard`, what the PR bot builds (16.1's PR project builds fewer arches than Backports itself) — and stamps the verdict at `<git-common-dir>/target-gate/<tree>-<base>.json`, keyed on `HEAD^{tree}` plus the base. `pool-pr.sh` refuses to push without a GREEN build and a PASS review in that stamp, so any commit after it means build and review again — except the build of a commit that changes only `.changes` files against the base's last GREEN tree: `--build` and `--remote` carry that build to it (`mode: carried`, `from: <tree>`) once `changes-lint.sh` passes the entries the change touches, and build when it does not (or when a file is dropped). The review never carries, and `--build` on a tree stamped already builds it for real.

Traps it encodes: a green build of **another checkout** (the tesseract-ocr PRs: the devel checkout was built and the hand-edited pool tree pushed unbuilt — the build log must name `processing recipe <this clone>/<pkg>.spec`); **the wrong base's root** (a per-package, per-base `--root <build-root base>/<pkg>-<base>-<arch>`, and a tripwire on the root's `rpm-config-SUSE` release, `-160000.` or `-160100.`); **the i586 whitelist** (flavor/arch pairs are decided as OBS decides them, from obs-build's `queryrecipe` for ExclusiveArch/ExcludeArch and `queryconfig` for the Backports onlybuild/excludebuild lists, so an arch OBS marks excluded is not a red); a **bind-mounted `/dev`** under the root (`osc build --clean` would wipe the host's — any mount at or under the root refuses the build).

`--build` is native only, never emulated: a flavor with no native route is refused with a pointer to `--remote`, and the other arches the PR project builds must resolve (`osc buildinfo`) before the long native build starts. `--remote` pushes HEAD and its LFS objects to the fork branch `leapgate/<base>-<sha12>` (never a PR head; it adds a git remote named `leapgate`), sets up `home:<you>:leapgate` with that package scmsync'd to exactly HEAD, and exits 3 until `_scmsync.obsinfo`, read at the package's current source revision, shows HEAD's commit and every PR arch is excluded, disabled or succeeded *from that revision* — the srcmd5 of the last `_jobhistory` job of each arch and flavor, since an unchanged rebuild adds no `_history` entry; a `succeeded` left over from the previous commit's build is pending, not green; its package meta disables the other base's repository, so remote gates for 16.0 and 16.1 of one package run one after the other. On GREEN it deletes the fork branch and the package (`osc rdelete`; a failed delete is a note, not a verdict change), so the next run starts a new one; red or pending keeps both for `osc rbl`. `--review FILE` needs a GREEN stamp; the file's first non-empty line — the verdict line — must start with `PASS` and name `tree <sha12>` of HEAD and no other tree. Trees quoted further down (Factory's, the previous one) are ignored, and HEAD's tree named only below the verdict line is red. A red build of the same tree deletes the stamp, a failing `--review` removes an earlier PASS, a rebuild of the same tree keeps its review.

Refused (exit 2): a dirty worktree (ignored and untracked files count — osc copies them), a detached HEAD, unsmudged LFS files, a clone under `/tmp` or a scratchpad, HEAD not on top of `origin/<base>`, HEAD carrying the heads of two or more of your open PRs to the base (one is the PR `pool-pr.sh` updates; yours = the head repo belongs to the user of your git-obs login, as in `pool-pr.sh`), an `slfo-*` or `factory` base, any option but `--jobs N` for the build. **Every failed lookup — the PR list, the PR project's arches, the build config, the results, the source listing, the build history — exits 1 or 2, never green.** It finds `build-summary.sh` beside its resolved path, so a symlink cannot swap in a stand-in. Needs osc, git-lfs, obs-build (`BUILD_DIR` points at its tools), a git-obs login for src.opensuse.org and, for `--remote`, an SSH key there: it reads the forge through `git-obs -G src.opensuse.org api`, forks with `git-obs repo fork`, and pushes the tree's LFS objects, then the branch, to `gitea@src.opensuse.org:<you>/<pkg>.git`. It reads no forge credential.

## `pool-pr.sh`

**The only route by which a `pool/` PR is opened or its head moved; it never merges.** It runs `target-gate.sh DIR` in check mode before any network call, and without a GREEN build + PASS review for HEAD's tree on the base it exits 7 with nothing pushed. The package comes from origin (`src.opensuse.org/pool/<pkg>`), the base from `@{upstream}`, which must be `origin/leap-16.N`. An open PR of yours on the base (its head repo belongs to the user of your git-obs login) is updated in place only when HEAD contains that PR's head — a fix on top: HEAD is force-pushed onto the PR's own head repo and branch and its title reset (the body too with `--body-file`). A HEAD that would drop the PR's commits — a `leap-sync.sh` re-sync always does — exits 2 unless `--replace`, which also resets the body (`--body-file`, else HEAD's body plus a line naming the old and new heads) and prints `PR updated (head replaced)`; check what the PR carries before replacing it. A PR head the listing omits, or this clone lacks, counts as not contained. Otherwise HEAD goes to a new head branch `<base>-<sha12>` on your fork and the PR is opened; title and body default to HEAD's commit.

It pushes the gated commit by sha — exit 7 if HEAD moved while the gate ran — and the LFS objects before the ref, so a PR head never points at objects the fork lacks (a fresh fork has empty LFS storage). Refused (exit 2): someone else's open PR on the base, two of yours, a head branch that already heads a PR to another base (one head branch, one base). It reads every page of open PRs; a lookup that fails, does not parse or does not end is exit 6, never "no PR". It reads and writes the forge through `git-obs -G src.opensuse.org api` (an HTTP error is a non-zero exit, never "no PR"), forks with `git-obs repo fork`, and pushes over SSH to `gitea@src.opensuse.org:<owner>/<pkg>.git`, where git-lfs gets its credentials from the forge (`git-lfs-authenticate`). It reads no credential file and puts no token on a command line. Prints the PR URL and the next step, `sr-status.py --pr pool/<pkg>#<n>`.

## `pr-guard.py`

**The harness hook that makes the pool PR route mechanical**: Claude Code (PreToolUse on `Bash|Monitor|Write|Edit`) or an opencode plugin hands it each tool call as JSON, and it refuses (exit 2, the reason and the right command on stderr) a call that would open, update or merge a `pool/` PR outside `pool-pr.sh` (`tea`, `git-obs` or `git obs`, or the API), merge any other src.opensuse.org PR the same ways (`gh` is not judged; a merge URL on a pool or unnamed repository is refused however it is sent, as it always was, and elsewhere counts unless the call provably only reads: GET or HEAD, no body option, no config that could add one — `curl -q`, `wget --no-config`, HTTPie with an explicit `GET` or `--ignore-stdin`), push to a branch that heads an open pool PR or to `pool/`/`refs/for/` directly, write a `target-gate.sh` stamp, run an emulated `osc build`, file `osc sr`/`osc mr` against the scmsync'd `openSUSE:Backports:SLE-16.x`, file a submit request with `--nodevelproject` (factory-auto declines it) or create one through the API (`/request?cmd=create`, skipping osc's checks) or a request whose message has over 300 characters of prose (every line but a `- ` list item), a list line over 100 characters or over 1000 in all (read from `-m`, `-F`, stdin, a variable or an `echo`/`printf`/`cat` substitution, and refused when it cannot be read), or write into a `*:Update` or `*:Maintenance:*` project outside `home:` by commit, `osc api` (sources or builds) or another direct write — among them `branch`, `mbranch` into it, `copypac`, `linkpac`, `aggregatepac`, `rdelete`, `undelete`, `rremove`, `rmkpac`, `repo add`/`remove`, `meta prj|pkg` writes, `lock`/`unlock`, `release`, `wipebinaries`, `setdevelproject`, `setlinkrev`, `detachbranch`, `linktobranch`, `updatepacmetafromspec`, `addchannels`, `addcontainers`, or where it cannot place the project (use `osc mbranch`, then `osc mr`). A `-h`/`--help` call of `tea`, `git-obs`, `git` or `osc` is not judged, and a refusal redacts credentials (URL userinfo, `Authorization`/`Bearer` values, `token=`). A command line is judged one parsed command at a time, so a commit message, grep pattern or `echo` that only quotes a pool merge is text, not a merge. Program text is read whole: every script a command runs, inline `-c`/`-e` code, and text fed to a shell or interpreter by heredoc, here-string, `< FILE` or a pipe from `echo`, `printf` or `cat`. The only scripts it runs unread are those in the skill checkout's `scripts/`, run by their path, while every file `scripts/` tracks (in the index or at the pinned ref) hashes, unfiltered, to its blob at the pinned ref — `PR_GUARD_PIN_REF`, default `refs/remotes/origin/main`, so as merged, not as edited or committed locally; the scripts run their siblings, so one edited, added or dropped file, or a call that writes into `scripts/`, untrusts them all — and with no environment change but `TMPDIR`, `LC_ALL`, `LANG`, `NO_COLOR` and `CHANGES_AUTHOR` (a `PATH=` or `BUILD_DIR=` could hand them a fake `osc`). One sourced or fed on stdin is refused: the scripts find their siblings from their own path.

The agent's own commands — its command line, with `bash -c`, `eval`, substitutions and heredocs fed to a shell, as parsed through the same wrappers, variables and options — are also held to credential rules; the scripts and program code they run, and Write/Edit content, are not. No reading a credential file (tea's config, osc's config and cookie jar, gh's, netrc, git's credential store, an MCP server's `api-key`), placed as written, in the tracked directory, through the call's values, brace expansions (past 64 words, unknown and refused), globs, dot segments and symlinks, through `xargs -a` or GNU `parallel`'s inputs, or through a recursive reader (`grep -r`, `rg`, `cp -r`, `tar`, `rsync`, `find -exec`) of a directory above one; `ls`, `stat`, `test`, `mkdir`, `chmod`, a `find` without an action, an output redirection, a search pattern, a commit message, and a grep that prints only a `build-*` setting (as `build-summary.sh` reads `build-root`) pass, and so does osc's `--config` or git-obs's `--gitea-config` naming the tool's own file. No setting or running an askpass program (`GIT_ASKPASS`, `SSH_ASKPASS`, `core.askPass`). None of the tools' own secret printers: `gh auth` token, status or git-credential; `tea login` helper, git-credential or edit; `git-obs login list` and its gitcredentials-helper; `git credential fill` and a credential helper's `get`; `secret-tool` lookup or search; osc's `config --dump-full`, `-H`, `--http-debug`, `--http-full-debug` or `http_debug` (by `--setopt` or `OSC_HTTP_DEBUG`), `token`, `config … pass|passx` and `api …/person/<login>/token`. No credential on the command line of `curl`, `wget`, HTTPie or `xh`, `tea api`, `git-obs api` or git: a header that carries one (`Authorization`, `Cookie`, `PRIVATE-TOKEN` and kin), a `user:password`, a bearer option, a URL's userinfo. And no `curl`, `wget` or HTTPie request to the OBS API (`api.opensuse.org`, `build.opensuse.org`'s API paths) or Gitea's (`src.opensuse.org/api`): `osc api` and `git-obs -G src.opensuse.org api` hold the logins. Downloads, web pages, public clones and other forges pass.

A call that matches nothing guarded is allowed without a lookup; once one matches, anything it cannot establish — a remote it cannot resolve, a branch, remote URL or repository held in a variable, a failed open-PR lookup or lookups past 40 s in all (below the hook's 60 s timeout, past which Claude Code runs the call unjudged), an unreadable script, a script path it cannot expand after substituting the call's own assignments (`for` words included), `$PWD`, `$TMPDIR`, `$HOME` and globs (`exec-unresolved`), a file the call writes and then runs (`exec-written`: it would be judged by its old content) — refuses the call. It runs as a **pinned copy** of two files, `pr-guard.py` (the prefilter) and `_pr_guard.py` (the rules, compiled only on a match; without it every matched call is refused), not updated with the skill: a change to it is a decision. It is wired in with the drafts under the skill repository's `contrib/harness/`. Agents never run it.

Limits: moving the pinned ref by hand (`update-ref`, a fetch from another remote) re-approves whatever it names, and merging a script to `main` is itself a guard decision; a script run by bare name from `PATH`, or a program held in a variable the call does not set or made by a substitution, is not read; a file written other than by the shell (`git checkout`, `patch`, `tar`, program code) can run in the same call; after a `cd` to a variable the call did not set, or to a substitution, the working directory is unknown (values the call sets, a loop's words and globs are followed, and a variable a loop reassigns holds all its values; `read`, `mapfile`, `printf -v` and `declare -n` leave a value unknown), so a push, an unnamed `tea`/`git-obs` call, an `osc commit` or a script run by relative path there is refused; git's arguments are text to the stamp rule (a commit message or branch naming `.git/target-gate/` passes), so git writing into a stamp directory itself (`--work-tree`, `--output`) is not seen; the harness's Edit/Write deny rules do not stop a shell command editing the same files; a merge through the pulls API is judged whatever its host, while `gh` (GitHub's own PRs) is not judged, and a curl or wget request whose URL or method comes from a config file (`-K`, `--next`, a wgetrc) is not seen; request messages are measured on osc command lines only, not in program code or PR descriptions, and one made by another program, a printf width or reused format, or a brace expansion is refused as unknown; the maintenance rule reads osc command lines only (not program code running osc) and covers the writes named above, not every osc subcommand that writes (`rebuild`, `restartbuild`/`abortbuild`, `service remoterun` and `meta prjconf`/`attribute`/`pattern`, for instance); a script that runs its own arguments (`"$@"`) is not followed, and `"$@"` or an array in a script's command position is its arguments, not judged; commands run through `flock` or `script` are not unwrapped; the prefilter reads the text as written and with its quotes and backslashes dropped, so a command name only an expansion spells (`${X:-osc}`, `$(echo osc)`) is not seen; the credential rules read the agent's own commands only: a script's body, program code (`python3 -c`, a heredoc fed to Python) and Write/Edit content are not scanned for them (the Read tool is left to the harness snippets' deny rules), nor are a credential file named by a variable the call does not set, one read in a directory the guard cannot place (but for `oscrc` and `cookiejar`), words `xargs` reads from stdin, or a recursive search with no path in a call the prefilter lets through.

## `leap-status.sh`

Is the package in Leap, at what version per branch, and is a PR ALREADY open? exit 0/1/2/3 = in-sync / behind-no-PR / behind-PR-open / not-in-Leap; 4 = no verdict (a branch's Version unreadable, or usage), 5 = network — neither ever reads as in-sync or PR-open.

## `scm-snapshot.sh`

Scaffold + verify a pinned-commit `obs_scm` `_service` for tagless upstreams (reproducible `X.Y.Z~gitYYYYMMDD.hash`); `--update` re-pins with moved-checks. **`--update` edits ONLY the obs_scm `<param name="revision">`, in place** — sibling services (`tar`/`recompress`/`set_version`/`cargo_vendor`/…) and the declared `versionformat` survive byte-for-byte, and `--base` is ignored. That matters because a pinned-snapshot package is rarely a lone `obs_scm`: rewriting the whole file would delete the vendoring/compression services *and* silently rewrite a `<base>+git…` versionformat to `<base>~git…`, which changes the package's version string. If the obs_scm block has no `revision` param it refuses and restores rather than guessing.

## `changes-prepend.sh`

Verified `.changes` prepend (separator-count + insertion-only checks; restores on failure). Refuses (exit 3, nothing written) when the file already differs from its committed version (looked up as `changes-guard.sh` does): an entry is already pending, and a second prepend would stack two into one submission — edit that top entry, then `changes-guard.sh --amend-top`.

## `changes-lint.sh`

Format-lint the newest N `.changes` entries (separators, headers, blank lines, bullets); the pre-SR gate against "fix the format of the changes entries" declines. Also flags a bullet that names a CVE id as not fixed (`not (yet) fixed`, `unpatched`, `does not address`, `tracked separately`, `remains open` and kin) unless the bullet states that fix (`Fix CVE-…`, `CVE-…: fixed`, a patch named for the id): any CVE id in `.changes` reads as fixed by that update.

## `changes-patches.sh`

Factory-auto's patch-mention rule run locally against the SR **target** (not your branch's last commit, which already holds the change): each `*.patch`/`*.diff`/`*.dif` added or removed must have its literal filename on a single `+`/`-` line of the `.changes` diff — a glob, a `%{version}` form, a name split by the 67-col wrap, or a mention only in an untouched old entry all decline, and a rename counts twice. `--target PRJ` (default: the checkout's link origin, else Factory), `--base DIR` for offline use. Real case: a three-patch rename cost three SRs in a row. It also counts the entries the `.changes` adds vs the target: more than `--entries N` (default 1) is a finding — typically a fix-up stacked as a second entry instead of folded into the top one; pass the real count for deliberate per-version entries or a devel forward (`gate.sh --entries N` passes it on). In a non-link osc checkout without `--target` (a direct commit to a devel project, which may be entries ahead of Factory) they count against the committed copy instead, also for a package Factory does not have yet.

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

## `_pr_guard.py`

The rules of `pr-guard.py`, compiled from source only once a call matches the prefilter, which keeps an unmatched call near Python's own start-up time. Installed beside the pinned `pr-guard.py`: without it every matched call is refused. Not directly runnable; a change to it is a change to the guard.

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
changes-guard.sh, changes-patches.sh and a one-Legal-Review-Notice-per-License
check, each run unpiped with its exit code read directly, then one VERDICT line. Five separate calls cost five provider
steps and five result blocks that ride along in context for the rest of the
session; this costs one. The adversarial change review (agents/changes-review.md)
still follows — it is a judgement, not a check, and stays outside this script.

Usage: gate.sh [DIR] [--entries N] [--amend-top AUTHOR] [--target PRJ[/PKG]]
               [--git-base REF] [--build-log FILE] [--full]
  DIR          package checkout (default .)
  --entries N  entries the submission adds vs the target (changes-lint and
               changes-patches, default 1)
  --amend-top  the .changes top entry is yours and still unaccepted (changes-guard)
  --target     SR target for changes-patches (default: link origin, else Factory)
  --git-base   git checkout: the target's ref for changes-patches (a fork PR's
               upstream is the pushed fork branch, which compares clean)
  --build-log  also run build-summary.sh on this osc build log (verdict only)
  --full       print every gate's complete output (default: last 12 lines each;
               full output is always saved under $TMPDIR/gate-<pkg>/)
Exit: 0 = every gate green, 1 = at least one red (VERDICT names them), 2 = usage,
      or DIR is not a package checkout (no *.spec, no .osc/_package).
