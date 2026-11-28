# Block 3 — Submit to Factory and watch

## Contents
- Committing changes to OBS
  - Auto-forwarding your own submissions
- Monitoring server-side builds (`geectl build results`, `geectl build build-log`)
  - `geectl build results` status vocabulary
  - `geectl build build-log` — remote build log
  - Release tag rewriting
- Submit requests (`geectl request file`, `geectl request search`)
  - Picking the right target project
  - Verifying the target has the package
  - Querying existing requests
  - Reviewing incoming requests (other people's submissions to your packages)
  - Triaging your declined submit requests
  - SR state vocabulary
  - Typical Factory review chain
  - Filing an SR
  - Consolidating several source packages into one — file the submit and the delete as a PAIR
  - Gotchas observed in practice

## Committing changes to OBS

OBS treats commit and push as a single operation: `geectl commit -m MSG --live` sends the change to api.opensuse.org and triggers a server-side rebuild. There is no separate push step. Once `geectl commit` returns "Committed revision N", the change is live and irreversible — revisions are immutable, you cannot amend or rewrite them.

> **HARD RULE — a `reviewer` role held by someone else means SUBMIT, never commit directly.** Before committing to *any* project you don't own, read the package `_meta` (`geectl remote package-meta <prj> <pkg>`) and the project `_meta`. If either sets `<person userid="…" role="reviewer"/>` (or a `<group … role="reviewer"/>`) naming **anyone other than you**, that person has explicitly asked to see changes to this package *before* they land — a direct `geectl commit` bypasses exactly the gate they set up, even when your maintainer rights let it succeed. Instead: `geectl branch branch-package --project <prj> --package <pkg> --live`, do the work in the branch, and file `geectl request file --source-project <your-branch-project> --source-package <pkg> --target-project <prj> --target-package <pkg> --description DESC --changes-entry ENTRY --live` so the reviewer is auto-added to the request. **Then leave it alone — do not accept your own SR**, even though you can; the whole point is that the named reviewer decides. Say in the SR message what you'd like their eyes on (a dropped patch, a new `%files` decision, a dep-floor change). This is *in addition to* the never-accept-someone-else's-request rule below — that one governs *their* requests, this one governs *yours*. The same applies transitively to the devel→Factory forward: land it in the devel project through the reviewer first, then forward what they accepted. (Real case: a `network:utilities` package carried a `role="reviewer"` person alongside our own maintainership — the version bump was filed as an SR to the devel project and left for that reviewer, precisely because the release forced a judgement call about not shipping a newly-added static library.)

### Auto-forwarding your own submissions

**The reviewer role is also the gate for forwarding your *own* accepted request onward — and the gate is the `reviewer` role, NOT co-maintainership.** For a request *you* created, you may accept it into the devel project and forward it onward unattended when **no explicit `reviewer` role is set** — by a person *or* a group, on the package *or* the project — and either:
1. you hold `maintainer` on the **package**, or
2. the package has **no maintainer at all** and you hold `maintainer` on the **project** (an unowned package in a project you run is yours to move).

A co-maintainer who never set a reviewer role has not asked to be consulted; an explicit `reviewer` has. Gating instead on "does anyone else co-maintain this" is the wrong test: it blocks the large majority of ordinary packages while catching nothing the reviewer role does not already catch. (Real case that produced this rule: two packages that had to be handled differently were distinguishable *only* by the reviewer role — both had co-maintainers.)

A project kept in git takes them from its project git (`references/git-workflow.md` "Forwarding to Factory"). `scripts/autoforward-gate.sh` mechanizes the call: exit 0 ELIGIBLE, 3 BLOCKED (reviewer set — report and wait), 4 NOT_YOURS, 5 meta unreadable, 6 WRONG-DEVEL (Factory develops it elsewhere). `--batch <file>` takes `<project>\t<package>` lines and exits with the worst row (5 > 6 > 3 > 4 > 0).

Two absolute limits:
- It applies **only to requests you created**. **Somebody else's** request is accepted or declined only on the user's explicit go, whatever the roles say — holding maintainer rights is not permission to use them unattended: on a package you maintain, after its incoming review recorded PASS or FIXABLE, then forwarded through this same gate; on another maintainer's, never (SKILL.md core directive item 10, `references/incoming-review.md` "The flow").
- Before forwarding, run `scripts/forward-check.py <devel-project> <pkg>` (`--mine`: all your accepted requests, ~6 s each, so in the background, or narrowed with `--since`) and file only on `DUE`, or on your fixed `MINE-DECLINED` with `-s <id>`; report every other verdict but `FORWARDED … current`, `MINE-OPEN … current` and `IN-FACTORY`. Devel maintainers forward what they accept (accepting forwards to the link parent by default); a duplicate 403s — see "When *someone else* accepts your home→devel SR" below.

> **HARD RULE — always show the full diff before committing.** Before running `geectl commit` **or any commit-equivalent** (`git commit`/`git push` in a git checkout; a `geectl remote delete-link PRJ PKG --live`, which is itself a commit; `geectl branch copy-package`; `geectl local-build service-run` runs that will be committed), **display the full diff to the user** (`geectl diff`, or `git diff`/`git diff --cached`) and let them see it — *every time*, even when they've already said "commit". Show the diff in the same turn, then commit. This is the last review gate before a public, immutable revision; never commit without surfacing the diff first.

Workflow (run after a successful local build and a `.changes` entry):

1. `geectl status` — list modified / added / deleted files. Anything not yet staged shows up with `M`/`A`/`D`/`?`.
2. `geectl diff` — preview the *full* diff that will be sent. Always read this before committing; it is the last chance to catch a mistake before the change becomes public.
3. `geectl add <newfile> --live` for any new files (sources, patches) that show as `?` in `geectl status`.
4. `geectl local-build service-run --service source_validator DIR --live` — run the source-validation service locally before commit (**run the one service only** — see `references/source-services.md` "Service modes decide what you run AND what you commit"). OBS runs this server-side on every commit anyway, but doing it locally catches the same class of issues (sources referenced in the spec but missing from the package dir, unused source files, unparseable spec, bad license tag, a stray trailing `----` separator or malformed date in `.changes` → `'' is not a date`) before they end up in OBS history. **Treat any reported error as a hard blocker** (warnings case-by-case). **Operational rule: gate in one call, commit in the next** — `scripts/gate.sh` runs the validator unpiped and reads its real exit code; only on GREEN, `geectl commit -m MSG --noservice --live` alone in the next call (pr-guard refuses a commit chained after anything that can change the tree). Never read a validator through a pipe: `| tail -2` exits with `tail`'s 0 (real miss: ossim rev 25 committed past a validator failure). Likewise only commit when the local `geectl local-build build` (incl. `%check`) passed — a failing build/validator must abort the commit, not proceed past it.
5. **Run `geectl remote update-package-meta-from-spec PRJ PKG` by default as part of cleanup** to sync `URL:`/`%description`/title into the OBS package `_meta`. The spec is not authoritative for the OBS package metadata — `_meta` carries its own copy of the URL and description that's shown on build.opensuse.org, used by web searches, and consumed by tooling. Without this step the spec and `_meta` drift and the project page keeps showing the old URL/description forever. The command is dry-run by default: run it once without `--live` — it prints the change it would make — and only after reading that diff apply it with `geectl remote update-package-meta-from-spec PRJ PKG --live`. Run this **before** `geectl commit` so any metadata update lands together with the source change. **Do it on every cleanup, not only when you changed `URL:`/`%description`** — the `_meta` frequently drifts or is missing these fields entirely (real case: `Archiving:Backup/vorta`'s `_meta` had no title/description/url at all until synced).
6. `geectl commit -m "<short message>" --noservice --live` — sends the tree `gate.sh` judged; without `--noservice`, `geectl commit` first runs services (a project's `format_spec_file`) that rewrite it or fail where missing. The `-m` message is the OBS revision message (`geectl remote package-log`), not the `.changes`: one line summarising the entry.
7. After commit, `geectl status` should return empty. Confirm the new revision with `geectl remote package-log PRJ PKG | head -10`.

Treat `geectl commit` like a `git push` to a shared remote: never run it speculatively. Server-side rebuilds are scheduled automatically across all enabled repos and architectures; watch with `geectl build results` (see next section). Do not assume the local build matches what the server will produce — repository state, build constraints, and macros can differ.

**Broken link because the link target was removed upstream.** A devel package can be a `<link project="openSUSE:Factory" .../>` (often a branch link with `<patches><branch/></patches>`). If Factory later *removes* that package, the link breaks: checkout warns the link is currently broken, and the file list carries `linkinfo … error="openSUSE:Factory/<pkg>: package 'X' does not exist"`. **`geectl pull` cannot fix this** — it merges a link against its base, and the base is gone (`geectl pull` just re-errors with the 404). When the package already carries its own real sources (spec/tarball/patches are real `<entry>`s, not inherited), the fix is to **drop the `_link`**, turning it into a standalone package:
```
geectl remote delete-link <prj> <pkg> --live
```
This delete *is itself a commit* (creates a new server revision immediately — never speculatively, same as `geectl commit`); afterwards `geectl update --live` to sync the local checkout, and `geectl status` will be clean. No `.changes` entry needed — it's pure OBS metadata, recorded in `geectl remote package-log`. The alternative (re-pointing the link elsewhere) only makes sense if a valid new target exists; when Factory simply dropped the package, standalone is correct.

## Monitoring server-side builds (`geectl build results`, `geectl build build-log`)

After committing, OBS reschedules every enabled `<repo, arch>` target. `geectl build results` watches the matrix and `geectl build build-log` inspects individual logs — **but reaching for them is opt-in, not a default.** Per the "investigate locally" HARD RULE above: don't poll the server on your own initiative after a commit/SR, and don't query a remote log for something already sitting in `/var/tmp/build-root/.../.build.log` on your disk. Use these tools only when the user asks, or for the narrow cases that genuinely require the server (arch-specific failures you can't build locally, an OBS-only failure, triaging a pasted URL). The commands below document *how* to use them when one of those reasons applies.

### `geectl build results` status vocabulary

`geectl build results` shows one line per `<repo, arch>` with a `code` word. There is no unpublished distinction: a build that succeeded reports `succeeded` whether or not the binary is published.

| `code` | Meaning |
|---|---|
| `succeeded` | Build OK, package published to the repo. |
| `published` | Build OK and published. |
| `finished` | Build run completed; the code alone does not say whether it succeeded — confirm the outcome from the log, not the code. |
| `building` / `dispatching` / `signing` | Still running. |
| `scheduled` | Waiting for a worker. |
| `blocked` | Waiting on another package in the dependency graph. |
| `disabled` | Project / package config disables this `<repo, arch>` deliberately. Don't try to "fix" by enabling without checking `_meta`. |
| `excluded` | Spec's `ExcludeArch:` / `ExclusiveArch:` excludes this arch. |
| `unresolvable` | BuildRequires couldn't be satisfied — usually a missing repo dep, not a build error. |
| `failed` | Build actually broke. Read the log with `geectl build build-log`. |
| `broken` | The package metadata is broken (bad spec, missing source). |

Rule of thumb: only `failed`, `unresolvable`, and `broken` are real problems. `finished` alone is not a verdict — confirm the outcome from the log before reporting a failure.

**Report status from a read made in that turn:** "blocked" names what it waits on, "nothing failing" follows reading every line (electron r6 was reported blocked by churn after failing in `gn gen`).

### `geectl build build-log` — remote build log

`geectl build build-log PRJ PKG REPO ARCH` streams the build log for that target. There is no pasted-URL form: a build log is read by project, package, repo and arch, never from a chat link.

Useful flags:

- `--start -50000` — only the tail: reads the last 50000 bytes. Use this first when triaging a failure; it's cheap and the failure reason is almost always near the end.
- `--last` — show the last *finished* log (succeeded or failed); useful when the current state is "building".
- `--lastsucceeded` — show the last *succeeded* log specifically; perfect for diffing against the current failure when a previously-working build breaks.
- `--start OFFSET` — start reading from a byte offset; a negative offset reads from the end. The log can be megabytes for big packages; use `--start -50000` to skip to the end.
- There is no `--strip-time`: the log comes with its elapsed-time prefixes; grep locally instead.
- There is no flavor selector: `build build-log` takes no multibuild flag, so a multibuild package's per-flavor log has no typed form — that is a gap.

Triage workflow for a remote-build failure:

1. `geectl build results PRJ --package PKG` — identify which `<repo, arch>` actually failed.
2. `geectl build build-log PRJ PKG REPO ARCH --start -50000` — read the tail. RPM errors, rpmlint errors, and `%check` failures land in the last few hundred lines.
3. If the failure is build-step specific (compile error, missing dep), `geectl build build-log PRJ PKG REPO ARCH --last | grep -iE "error:|undefined|cannot find"`.
4. If it's a regression, `geectl build build-log PRJ PKG REPO ARCH --lastsucceeded` and diff against the current to see what changed in the environment.
5. Real failures should usually be reproduced locally with `geectl local-build build --project PRJ --repo REPO --arch ARCH DIR --live` before pushing a fix — the build root from the local run gives you a debugger-friendly environment (binaries left in `/var/tmp/build-root/...`, see Local builds).

### Release tag rewriting

The `Release: 0` you set in the spec is **not** what shows up in the built RPM name. OBS appends a project-specific suffix during build: `<name>-<version>-<project>.<release-counter>.<rebuild-counter>.<arch>.rpm`. E.g. `stream-5.10-0.aarch64.rpm` locally becomes `stream-5.10-benchmark.8.1.aarch64.rpm` on the server. This is why the "always `Release: 0`" rule works — the server generates the real number and rebases it each commit. Don't try to set the release counter manually.

## Submit requests (`geectl request file`, `geectl request search`)

A commit to a devel project (e.g. `benchmark/stream`) is **not** the same as a submission to an upstream distribution (e.g. `openSUSE:Factory`). They are two separate steps:

1. `geectl commit -m MSG --live` — writes a new revision in the devel project. OBS rebuilds it across that project's repos. Nothing automatic happens beyond that.
2. `geectl request file --source-project SRC_PRJ --source-package SRC_PKG --target-project DST_PRJ --target-package DST_PKG --description DESC --changes-entry ENTRY --live` — files a submit request (SR) asking maintainers of `<target-project>` to copy your latest revision in. This is the step that propagates a change upstream.

**This is a real gotcha.** `geectl commit` returning "Committed revision N" does *not* mean the change is on its way to Factory; it only means the devel project has it. If a downstream/user reports that a fix you just committed isn't visible, the cause is almost always a missing `geectl request file`.

Conversely, an SR may show up in `geectl request search --project <project>` for a project that you didn't manually create — collaborators can file a request against the same package between your commit and your next check, or origin-manager / staging bots may file follow-on requests. Don't be surprised by an SR that "appeared" minutes after your commit; check `Created by:` to see who issued it.

### Picking the right target project

The submit target depends on the package's license and category:

- **OSI-approved SPDX license** → `openSUSE:Factory` (the default).
- **Non-SPDX, restricted-redistribution, or NonFree-marker license** (`License: NonFree`, custom benchmark licenses, fonts under non-redistributable terms, etc.) → **`openSUSE:Factory:NonFree`**. Submitting a NonFree-licensed package to plain `openSUSE:Factory` will be declined by `licensedigger`; pick the NonFree target up front.
- **SLE Updates / backports under `SUSE:SLE-*`** → **IBS only.** There are **two separate build services** and this skill's workflows assume one of them: **OBS** (`build.opensuse.org` / `api.opensuse.org`) hosts `openSUSE:Factory`, `openSUSE:Factory:NonFree`, `openSUSE:Backports:*`, `openSUSE:Leap:*`, `devel:*`, `Publishing`, `home:*`; **IBS** (`build.suse.de` / `api.suse.de`, SUSE-internal) hosts `SUSE:SLE-*`, `SUSE:Devel:*` and the internal products, and needs a separate geectl instance for `api.suse.de` (its own named credentials) plus SUSE-internal network access.
  - **Cross-instance gotcha:** `geectl remote search-packages` from OBS returns matches from *both* — `SUSE:SLE-15-SP*:Update` appears alongside `openSUSE:Backports:*`, because OBS can read the cross-instance metadata. **That visibility is not actionability.** From an OBS checkout you can only file SRs/MRs to OBS-hosted targets; a submission to `SUSE:SLE-*` means re-running the entire workflow against IBS. When listing candidate maintenance-update targets from an OBS context, include only `openSUSE:Backports:*:Update` / `openSUSE:Leap:*:Update` — never propose `SUSE:SLE-*:Update` as something you can act on. If the user explicitly wants an IBS submission, flag it up front: *"I'd need to switch to IBS — confirm you have access."*
- **Maintenance updates for an already-released package** → a maintenance-incident request (`geectl request file-maintenance-incident`) rather than a submit request; the route is `references/maintenance-updates.md` "Maintenance updates (Backports / Leap)".

### Verifying the target has the package

Before filing to `<target>`, confirm the target actually has the package — Factory routinely removes packages, and an SR to a removed target gets declined ("The package 'openSUSE:Factory/foo' has been removed"). Do **not** use `geectl remote list-packages <target> | grep <pkg>` for this — it downloads the whole project package list to answer a yes/no question. Two lighter options:

- **`geectl remote devel-project <pkg> --target-project <target>`** — returns the devel project registered for that package in `<target>`. 404 means the package isn't in the target. Best choice for the pre-SR check because it also confirms which project the target expects SRs *from* (e.g. `openSUSE:Factory/tesseract-ocr` → `Publishing/tesseract-ocr` — your local checkout is the canonical sender). One round trip, one fact you actually needed.
- **`geectl remote cat <target> <pkg> _link`** — for packages set up as a link from one project to another (devel-project branches, maintenance branches), shows the link XML. 404 means no `_link` (the project holds real sources). Use this when chasing project-to-project link relationships, not for the basic existence check.

### Querying existing requests

Use `scripts/sr-status.py` (table of state, review chain, comments; `--summary` for "status of my submissions" at volume; `--brief` a plain list; includes src.opensuse.org PRs) / `scripts/my-requests.sh` (the brief list, OBS only). For "what changed?" use `scripts/watch-submissions.sh --resolve` — it diffs the active SR + open PR set against a saved baseline and prints only the delta (`NOCHANGE` → stay silent; `RESOLVE` = left the set, with its final state). The commands below are what they wrap, for custom queries.

**HARD RULE — "open" must include `declined`, or your status view is blind to the one state that needs you.** The natural definition of an active request is `states=new,review`, and it is wrong for a *creator's* view: a decline is terminal in OBS, so a declined request **leaves the active set** and vanishes from exactly the query you would reach for. The result is a status table that looks entirely healthy while a Factory submission sits dead. Anything answering "what are my submissions doing?" must fetch `new,review,declined` — which is why `sr-status.py --state open` (and `my-requests.sh` through it) does. When hand-rolling a query, spell the state out:

```
geectl request search --creator <user> --state new --state review --state declined --type submit
```

**The delta-watcher case is different and must NOT be "fixed" the same way.** `watch-submissions.sh` deliberately snapshots only `new,review`, because it reports *change*: a decline shows up as the id **disappearing** from the active set between runs, which it emits as a `RESOLVE` line for the caller to resolve with `geectl request show`. Adding `declined` to a delta watcher's baseline would make every decline a permanent resident of the snapshot and silence exactly one notification. Snapshot the active set; query the creator's set with declines included. (Real case: a Regina-REXX Factory decline was invisible in the default status table for hours because `open` meant `new,review`; the scheduled watcher's disappearance check would have caught it.)

| Command | What it shows |
|---|---|
| `geectl request search --project <project>` | Open requests **involving** that project — both directions (source or target). |
| `geectl request search --project <project> --package <package>` | Open requests against that specific package. |
| `geectl request search --state new --state review --state declined --state accepted --state revoked` | Filter by state (`--state` repeats). With no `--state` only new, review and declined requests are listed — add `--state accepted --state revoked` to see historical SRs. |
| `geectl request show <NN>` | Full detail of one SR: source, target, message, every review's state, and the history log. |
| `geectl request search --who <user>` | Requests **involving** a user — **not** creator-only (see below). |
| `geectl request search --reviewer <user>` | Requests you have to act on (you are a reviewer or owner). |

`--project` returns **both** directions. Read each entry's source and target to interpret it: if the project of interest is the source, the SR is *outgoing*; if the target, *incoming*. Maintenance-incident requests follow the same convention.

**`geectl request search --who <user>` is not a creator filter.** It returns every request the user is *involved* in — including ones where they are only a reviewer or a maintainer of the target package (the `Created by:` line in the output will frequently be someone else). Geectl *does* have a creator filter — `--creator <user>`. To get the requests a user actually *authored*:

```
# declined submit requests created by <user> targeting Factory:
geectl request search --creator <user> --state declined --type submit --target-project openSUSE:Factory
```

The result lists each request with its id, state, decliner and source/target — read those fields for each. Adjust `--state` (repeatable), drop `--target-project` for all targets, or change the filter (`--creator`, `--reviewer`, `--who`, `--project`, `--package`) as needed. Your OBS username is the `--creator` value — confirm it with `geectl remote whois <login>`.

### Reviewing incoming requests (other people's submissions to your packages)

Requests *others* file against packages/projects the user maintains. `scripts/watch-submissions.sh` reports them as `NEW INCOMING SR <id> <pkg> from <creator> [state]`; `scripts/incoming-requests.py` lists those needing the user personally (explicit person-level `role="maintainer"` targets, and PRs naming them in `requested_reviewers`), without the group reviews (`opensuse-review-team`, `factory-staging`, …) that fill `geectl request search --reviewer <user>`. Report `maintenance_incident` / `maintenance_release` requests as a counted group: the maintenance and security teams drive them (real case: 25 of a 39-request queue).

Reviewing one, its comment, and accepting, approving or declining it: `references/incoming-review.md` — the `incoming-review` agent reviews a contributor's submission to a package the user maintains as text and records the comment, which is posted unattended; accept, approve and decline wait for the user's go; another maintainer's package is never acted on.

### Triaging your declined submit requests

A recurring task is "which of my submissions are declined and need attention?" Workflow:

1. **List them** with the `--creator` search above (`--state declined`), reading each decliner and the decline comment. Group by decline reason:
2. **Bookkeeping declines (quick fixes)** — `factory-auto`/reviewer rejected on a fixable spec/source issue:
   - *Orphaned source* (`… is not mentioned in spec files as source or patch`): declare the file as `Source`/`Patch`, or `geectl rm <file> --live` it if obsolete (verify which — see Patches section; e.g. an unreferenced `.desktop` used only via `%suse_update_desktop_file -i`). An `<pkg>-rpmlintrc` counts too: OBS reads it without a `Source:` line, factory-auto declines it all the same. `scripts/gate.sh` turns this red before you file.
   - *Patch added/deleted without changelog note* (`A patch (X) is being added/deleted without this … being mentioned in the changelog`): add a bullet naming the literal filename on one line — a rename needs both names, a glob or `%{version}` form does not count. `scripts/changes-patches.sh` reproduces the bot's check locally; run it before resubmitting.
   - *License typo* (`invalid-license` / a wrong SPDX token): fix the `License:` tag.
   - *"missing details on why we update"* (human reviewer): write a proper, curated `.changes` entry.
   - Fix → rebuild unless only `.changes` changed (`references/update-build.md` "Build modes") → `scripts/gate.sh` → `geectl diff` → `geectl commit -m MSG --noservice --live` in its own call → resubmit (`geectl request refile … --supersede <declined-id> --live`, full form in "Filing an SR").
3. **"The package '…' has been removed"** — the target is gone from Factory; a plain resubmit just re-declines. This is now a **new-package submission**: update + cleanup + make it build cleanly (these are often packages dropped *for* a CMake-4/GCC-15 FTBFS — fix that), then refile with `--supersede <declined-id>` (expect the stricter `opensuse-review-team` review for a new-package submission). Or `geectl request revoke --comment MSG <id> --live` if you don't want to re-add it. Route and rights: `references/new-package.md` "Submitting a brand-new package".
4. **Stale/obsolete declines** — if the devel-project sources now match Factory (`geectl remote diff-packages openSUSE:Factory <pkg> <devel-project> <pkg>` is empty), the decline is moot → `geectl request revoke --comment MSG <id> --live` to tidy (revoke works on `declined`; see state vocabulary).

**Amending an in-flight Factory/devel submission** (e.g. to add a `boo#` ref after you already submitted): an SR pins the source revision it was filed from, so a later commit never reaches it. Edit the `.changes` entry, commit, then **revoke the stale Factory SR** (`geectl request revoke --comment "superseding: …" <id> --live`) and re-submit fresh — don't leave two competing SRs for the same package. (Real: vapoursynth — revoked SR, amended changelog to reference `boo#1268226`, re-forwarded.) Note the home-branch project is auto-removed once its SR is accepted, so re-branch before amending. Use `geectl request refile … --supersede <declined-id> --live` when resubmitting over a declined/pending request in one step (see specfile-guidelines.md decline handling); use explicit `geectl request revoke` + a fresh `geectl request file` when you must amend sources first — both end with exactly one live SR. For a **pending** SR of your own (same package, same target), name it too — `geectl request refile … --supersede <old-id> --live` — and verify with `geectl request show <old-id>` afterwards. Filing never supersedes silently: `request file` has no supersede mechanism, and `refile --supersede` names exactly one request — see the next rule.

**HARD RULE — filing supersedes every open request of yours on the package. Never file blind; name the one request you replace.** `geectl request file` supersedes every open request for the package from the same user — there is no prompt, and no per-request choice at filing time. A fresh filing that was meant to replace one declined request also supersedes your other open one. The safe form touches exactly one request: file first, then `geectl request supersede OLD_ID NEW_ID --live` — or `geectl request refile … --supersede <id> --live`, which files and supersedes the named request with it.

Never file a request except with `geectl request file`/`refile`: a hand-rolled API call skips the devel-project check, and the pr-guard hook refuses it.

**Do not count on a permission error to stop you.** Filing supersedes **your own** open requests on the package — other people's are untouched — but your own older requests are swept up silently. (Real case: a Regina-REXX resubmit swept up two *other people's* long-`declined` requests on the same package under the old client, flipping both to `superseded` under the submitter's own account. Geectl's filing supersedes only your own requests — but the sweep is still silent, so list first and name the one you replace.)

**Before filing, always list what is open** (`geectl request search --target-project <target> --target-package <pkg> --state new --state review --state declined`) so you know which of your requests are in the blast radius, and afterwards `geectl request show` each id you did *not* intend to touch to prove it is untouched.

### SR state vocabulary

- `new` — created, waiting for first review or staging pickup.
- `review` — at least one review is `accepted` and the workflow is progressing; one or more reviews remain `new`.
- `accepted` — all reviews passed; the SR's payload has been applied to the target.
- **Rescuing a `[botdel]` package (repo-checker filed a *delete* request because it FTBFS'd ≥ 6 weeks).** A botdel is a `delete` action against `openSUSE:Factory/<pkg>` (`Created by: repo-checker`, message `[botdel] Package has had build problems for >= 6 weeks`). To save the package: (1) **fix the FTBFS** in its devel project (it's almost always a toolchain/dep break — GCC 15, a libsinsp/Boost/UHD API bump, a dependency that dropped a transitive include — and the package usually still builds on the *older* distro (Leap 15.x) but fails on TW + the newest Leap, which pinpoints "newer toolchain"); (2) **submit the fix to Factory**; (3) **comment on the botdel request** pointing at your fix SR and asking it be declined. **Gotcha — a pending delete request *blocks* your submit:** Factory will decline your update with *"sr#NNNNNN of a different type should be revoked first"* (the delete outranks the submit). So the **botdel must be declined/revoked first**, then resubmit. **How you decline depends on your rights, and `geectl request decline` often 403s:** declining the whole *request* needs maintainer rights on the **target** (`openSUSE:Factory/<pkg>`), which a *devel-only* maintainer (you maintain `<devel>/<pkg>` but not the Factory package directly) does **not** have → `HTTP 403 post_request_no_permission`. But factory-auto routes a **by-package review** of the botdel to the devel project (`Review: new Package: <devel>/<pkg>`), and as a devel maintainer you *can* decline **that review**, which declines the whole request. Decline that review with `geectl request change-review-state <id> declined --project <devel> --package <pkg> --live`. Use the request-level decline (`geectl request decline --comment MSG <id> --live`) when you hold the rights on the target, and otherwise report the botdel as blocked on it. Once the botdel is `declined`, the fix's forward goes through. (Real cases: reuse, yambar, soapy-uhd declined directly as maintainer; **simple-obfs** — the request-level decline 403'd for the devel-only maintainer, so the by-package review was declined instead, which unblocked the Factory submit.)
- `declined` — a reviewer rejected it. The decliner's name and reason are in the comment. It won't proceed on its own, but it is **not immutable**: the creator can still `geectl request revoke --comment MSG <id> --live` it (transitions `declined`→`revoked`, confirmed working) or `--supersede` it with a fresh SR. Revoking obsolete declined requests is good hygiene — e.g. clean up your old declines whose devel-project sources now match Factory: `geectl remote diff-packages openSUSE:Factory <pkg> <devel-project> <pkg>` with empty output means identical, so the decline is moot and can be revoked. (A package that errors on diff-packages has been removed from Factory; leave those.)
- `revoked` — the SR author (or someone with author permissions) cancelled it before resolution. Not the same as `declined`.
- `superseded` — replaced by a newer SR.

### Typical Factory review chain

A submit request to Factory or Factory:NonFree typically picks up these reviews in order. Each must finish `accepted` for the SR to merge:

1. **`factory-auto` (User review)** — automated check script (spec sanity, no obvious blockers). Usually completes within seconds.
2. **`licensedigger` (User review)** — license SPDX validation. Flags wrong/missing `License:` tags and missing license files.
3. **`factory-staging` (Group review)** — picks a staging project (`openSUSE:Factory:Staging:adi:NN` or `openSUSE:Factory:NonFree:Staging:adi:NN`) for the change.
4. **Staging project review** — the staging project rebuilds the change together with anything else queued and validates the combined state.
5. **`opensuse-review-team` (Group review)** — human review by the openSUSE review team. This is the variable-latency step.

A new review can spawn additional reviews (e.g. `licensedigger` may add a follow-up if it finds a question to resolve). Watch the full chain with `geectl request show <NN>` and re-run as needed; for the staging rebuild, one bounded `geectl build results <staging-project>` per check (`references/update-build.md` "Build modes").

**Querying a staging project's combined state** (step 3–4) — `geectl remote staging-project <workflow-project> <staging>` returns its staged, untracked and obsolete requests and its overall state (both included by default; `--no-requests` / `--no-status` leave them out). The human-readable web page is `https://build.opensuse.org/staging_workflows/openSUSE:Factory/staging_projects/<staging>`. The staging page shows which SRs are in it, what each still waits on (usually `opensuse-review-team`), the rebuild health, and the overall state (`review` = building/reviewing, `acceptable` = ready to merge). A green staging blocked only by `opensuse-review-team` is in the normal wait state, not stuck.

**Interdependent packages are staged together.** When you submit a set with build interdependencies (e.g. a library + consumers that each needed a change of their own, like `girara` → `zathura` → the `zathura-plugin-*` set — a soname bump alone makes no such set: `references/shlib-alternatives.md` "Who needs a change on a soname bump"), the `factory-staging` bot generally pulls them into the **same** `adi:NN` staging so the combined rebuild can validate them as a unit — they then get accepted together. Submit the whole set close in time; if one is still in `factory-auto`/`licensedigger` it won't have been assigned a staging yet, so don't be alarmed that early snapshots show only some members staged. (If the bot splits an interdependent set across stagings and the rebuild breaks on the missing dep, that's a sign to ask staging maintainers to co-locate them.)

**The staging assignment is not stable — re-query it, never cache an `adi:NN`.** The bot actively re-groups: a package already sitting in one staging can be **moved** to a different one as the rest of its interdependent set arrives, so the whole set ends up consolidated in a single fresh `adi:NN` (and the original staging is emptied). Observed live: `girara` was first placed alone in `adi:48`; once `zathura` and the five plugins cleared `factory-auto`/`licensedigger`, the bot moved **all seven** into `adi:44` and left `adi:48` empty. So when watching a multi-package submission, on every poll re-read the staging from each request (`geectl request show <id>` — read its reviews for the staging project) and follow the set to wherever it currently lives — don't keep polling the staging name from an earlier snapshot, or you'll be watching an empty project.

### Filing an SR

**HARD RULE — the Block-2 adversarial change review must have COMPLETED and returned `PASS` before you file.** Never file the request while a review is still running, and never file one that returned blockers intending to fix them afterwards. The reason is that **a submitted request is public**: reviewers, bots and staging start acting on it immediately, so a blocker found after filing costs a supersede or a revoke and burns the accumulated review chain — and every reviewer who already looked did so at a version you knew was wrong. Fix first, submit once.

**HARD RULE: the whole commit gate — `scripts/gate.sh`, one call — must be green before you file, not just at commit time** (`references/update-build.md` "Gate the SR on one green build" for why each check exists). `factory-auto` re-runs `source_validator` server-side and *declines* on any failure (orphaned/missing sources, unparseable spec, bad license tag, malformed `.changes` date, minisign-not-available, …), so a local red is a decline you can still avoid. Re-run it even for a package you committed moments ago (it is the exact gate the server applies, and it is cheap), then file in the next call: pr-guard refuses a `geectl request file` chained after a command that can change what OBS holds. Applies to **every** target (Factory, NonFree, and the devel-project PR equivalents).

```
# From the package checkout, after a clean local build and a fresh commit:
<skill>/scripts/gate.sh .                       # one call: GREEN, the review's PASS recorded
geectl request file --source-project <src-prj> --source-package <pkg> --target-project <target> --target-package <pkg> --description "<short message>" --changes-entry "<entry>" --live    # the next call
```

Filing into a devel project is the executable case. The accept forwards to Factory by default, so there is no separate forward step in the normal flow — never spell out a Factory target in a `request file`/`refile` citation for a normal submission. The only Factory-targeted submit is the manual forward: on `forward-check.py` DUE (no forward exists and the auto-forward did not file one), file it from the recorded devel project with `--without-cleanup` — the source is a package that must keep existing.

**HARD RULE — you file it yourself**, and on `autoforward-gate.sh`'s ELIGIBLE also accept it — the accept forwards it to Factory ("Auto-forwarding your own submissions" below); otherwise stop at the devel SR, waiting for its maintainer. Never hand the user a geectl, tea or git-obs command, nor predict a refusal from memory: run it; a pr-guard refusal names a step — take it, retry.

**HARD RULE — an SR or PR message is one headline of a few words saying what the request does (pr-guard refuses over 160 characters of prose), then `- ` lines only for what the reviewer needs — first what must be staged with it or land before it.** No work notes (build, sweep or session status) and no `.changes` paste. Format, examples, forwards: `references/request-text.md` "SR and PR messages".

`--description` is required: there is no editor fallback — a filing without it fails.

**HARD RULE — cleanup is the default; a forward from a devel project opts out.** A request from a `home:<you>:<sub>` project (scratch, topic, `branches:…`) cleans up on accept: OBS deletes the branch package, and the subproject with it when that was its last package (top-level `home:<you>` is never deleted). A forward from a devel project passes `--without-cleanup` — the source is a package that must keep existing. Never `--without-cleanup` from a `home:<you>:<sub>` branch; pr-guard refuses it. Sweep obsolete forks with `geectl gitea cleanup-forks --live` — it lists obsolete Gitea forks and their OBS home test projects, and deletes a project only when its description marker names a fork that no longer exists on Gitea (dry-run by default). A request declined or revoked for good still leaves its branch: `references/update-build.md` "Close-out".

geectl never prompts: a filing with uncommitted changes or other open requests on the package does not ask — it files, and filing supersedes your own open requests on the package. Name the request you replace with `--supersede <id>` on `request refile` (never file a fresh request expecting the old ones to go away — see "Triaging your declined submit requests" above). Run it with `</dev/null`, so an unexpected question aborts instead of hanging.

- When geectl refuses with the devel-project error, submit from that devel project instead — a git (scmsync) one once its scmsync has caught up with your merged change; a classic one by a request from your branch to it, forwarded once accepted (`references/new-package.md` "Accept-and-forward"). factory-auto declines any other source (`references/decline-catalog.md` "factory-auto declines that point the wrong way").
- **Retiring a package:** `geectl request file-delete --target-project openSUSE:Factory --package <pkg> --description MSG --live` first; delete the devel package only after Factory accepted that request — until then Factory's package still names it as its devel package. (A consolidation orders its devel side differently: "Consolidating several source packages into one" below.)
- **A security bug goes back to the security team only after factory-auto has passed the SR and no other affected stream you can submit to lags** — `references/bugzilla-cve-triage.md` "5. Resolving".

**Delaying/scheduling a geectl action (file, commit, maintenance-incident) — use a local scheduled wakeup, NOT the remote `/schedule` skill.** When a submit must wait (e.g. a Git-workflow PR needs to merge + sync into OBS before the forward to Factory; see the git-workflow section), schedule a **local session wakeup** to resume and run the geectl command. **Do not use the `/schedule` skill (remote cloud routines) for this** — those agents run in an isolated cloud sandbox without your local geectl credentials, so they cannot authenticate to `api.opensuse.org`/`api.suse.de` and the `geectl request file`/`geectl commit`/`geectl request file-maintenance-incident` will fail. Any credential-dependent geectl/git-push action belongs in the *local* session. Have the scheduled step **verify the precondition before acting** — e.g. `geectl remote cat <devel-project> <pkg> <pkg>.spec | grep ^Version:` shows the new version (PR merged + synced) — and skip/report rather than submit a stale revision if it hasn't. (Real case: hwdata — a 20-min local wakeup verified `devel:openSUSE:Factory/hwdata` had synced to 0.408, then filed the Factory SR.)

### Consolidating several source packages into one — file the submit and the delete as a PAIR

When one source package absorbs another (an upstream monorepo whose several
distributions we had been packaging separately; see the monorepo bullet in
`references/language-packaging.md`), the merge SR is only half the change. The
absorbed source package must be deleted in the same target, or that target ends
up with **two sources producing the same binary**.

- **File both, and cross-reference both.** File the submit (`geectl request file … --live`, full form in "Filing an SR")
  then `geectl request file-delete --target-project openSUSE:Factory --package <oldpkg> --description "... goes together with
  SR#<id>" --live`, and put "MUST BE ACCEPTED TOGETHER WITH the delete request for
  <oldpkg>" in the SR message too. Only one of the two can carry the other's
  number (whichever you file second), so add a comment on the first pointing at
  the second — a reviewer who picks either one out of the staging queue then
  sees the pairing instead of accepting the SR alone.
- **Say what does NOT change.** The distinction reviewers care about is that the
  *binary* package survives unchanged even though a *source* package is being
  deleted. Prove it rather than asserting it: download the currently published
  RPM and diff `rpm -qlp` and `rpm -qpR` against the new build, then quote the
  numbers ("891 site-packages files identical, 39 requires identical"). Also
  check `scripts/rdeps.sh <oldpkg>` for build-time consumers.
- **Devel-side ordering: `geectl remote delete-package <devel> <oldpkg> --message MSG --live` the old source FIRST, then commit the
  merge.** The devel project builds against Factory, which still publishes the
  old binary, so nothing goes unresolvable in the gap — whereas committing the
  merge first creates a real duplicate-binary window in the devel project. (In
  Factory the two requests are accepted together, so no ordering applies there.)
- Contrast with a **rename**, where the old binary genuinely disappears and you
  need `Provides`/`Obsoletes` on the new package — see the rename bullet in
  `references/language-packaging.md`. A consolidation needs neither, because the
  binary name is unchanged.

(Real case: python-fastmcp 3.4.5 absorbed python-fastmcp-slim — SR 1369572 +
delete request 1369573.)

### Commenting on a failed or declined request

Yours or someone else's, the comment gives the people who read it what is relevant and nothing more:

- **Asked to fix or follow up a failure: the fix, no comment.** On your own declined request the superseding request carries what changed. An ack ("I'm on it.") goes out only when the user asks for one; pr-guard asks before a comment posts, except on a request, issue or PR you opened or one to a package you maintain, where you hold it for the user's go.
- **First look for a fix already filed** (an open request of yours to that devel package, perhaps from another session). If there is one, do nothing.
- **A triage or any other comment only when the user asks for it.** Post exactly what was asked for, with every claim checked first (fetch the URL the bot quotes). A reviewer's question on your own request still gets the short threaded reply of `agents/submit-watch.md` step 5, drafted for the user.
- Unasked triage essays went out on libpinyin sr#1385979 and ibus-typing-booster sr#1385674. The second blamed a Source0 that downloads fine, and both had to be deleted.

### Gotchas observed in practice

- **Declined because target was removed upstream.** If you SR a package and the destination has since been removed from Factory, the SR will be declined with a message like *"The package 'openSUSE:Factory/foo' has been removed"*. Before resubmitting, check with `geectl remote devel-project <pkg> --target-project <target-project>` (404 = removed; see "Verifying the target has the package" above), or `scripts/devel-of.sh` which wraps exactly this.
- **A devel-project package is not necessarily in Factory — a request to a missing target is a *new-package* submission.** When the target has no such package (confirm with `geectl remote devel-project <pkg> --target-project openSUSE:Factory` → 404), the package does not exist in Factory yet. The SR is still created and valid, but it is treated as a **new package**: it picks up the regular bots *plus* a stricter new-package legal/review pass by `opensuse-review-team`, so expect slower acceptance than an in-place update. Flag this to the user up front — "this package isn't in Factory, so this is a new-package submission" — rather than presenting it as a routine update. (ior was a benchmark devel-project package not present in Factory; SR 1355890 was a new-package submission.)
- **`geectl commit` can race with collaborators.** If someone else's SR is mid-flight when you commit, your commit will produce a divergent revision and any auto-forwarded SR will reflect *yours*, not theirs. Coordinate before pushing if the package has multiple active maintainers.
- **NonFree subset of arches.** Even with a successful build, `openSUSE:Factory:NonFree` projects often hold a subset of architectures back unpublished. This is policy, not a failure — don't try to fix it by editing the spec.
- **`factory-auto` declines minisign-signed packages.** OBS's source_validator does not have the `minisign` binary available, so any package shipping a `*.minisig` `Source` will be declined by `factory-auto` with `Source validator failed. ERROR: minisign command not available`. The fix is to drop the `*.minisig` (and the accompanying `*.keyring` minisign pubkey, which is then orphaned) from the spec and the package directory before resubmitting. Minisign signatures are useful for *upstream* download verification but cannot be enforced by OBS itself, so they add no value in the package. Document the removal in `.changes` with the validation-failure reason. After fixing, commit and file a new request. A declined SR is terminal, but you can still pass **`geectl request refile … --supersede <declined-id> --live`** — `--supersede` works even on a `declined` request and sets it to `superseded by <new-id>` (rather than leaving an orphaned `declined` entry), giving a clean audit trail linking the resubmission to what it replaced. A plain fresh `geectl request file` also works; `--supersede` is the tidier choice when you know the old request id.
- **Most "Source URLs are not valid" declines show up locally first: `scripts/gate.sh` runs the same `download_files --enforceupstream yes --enforcelocal yes`.** On OBS the bot only leaves its review open, and the staging manager declines a day later. Diagnose the source the bot names (the quoted URL, or the `differ` line), not a neighbour: one session blamed ibus-typing-booster's working Source0 while the bot named Source1. Before you comment on someone else's request, fetch the URL you blame. The shapes:
  - `ERROR: Failed to download "<url>"` — a wrong URL (libpinyin: the tag is `v2.11.92`, the URL lacks the `v`) or a dead host (`releases.pagure.org`). Fix the URL; for a host that is gone, commit the file under a bare-filename `Source:` with the old URL in a comment.
  - `<file> … differ: byte N` plus `fail when the upstream file is different` — upstream re-rolled the file (dsda-doom: GitHub regenerates `/archive/` tarballs). Re-download it, check that the unpacked trees match, prefer a release asset, and say so in `.changes`.
  - The OBS-only failures below.
- **`factory-auto` decline for "Source URLs are not valid / Failed to download" — distinguish a transient upstream blip from a persistent OBS-side fetch block.** factory-auto (and the staging bot) re-fetch every `Source:` URL *from OBS infrastructure* to verify the committed tarball matches upstream; on failure the SR is declined with `Source URLs are not valid. Try 'osc service runall download_files'. ERROR: Failed to download "<url>"` (that `runall` is factory-auto's own boilerplate — do **not** follow it; `geectl local-build service-run --service download_files DIR --live` is the mode-respecting form). **The trap: it can fetch fine from your laptop and still fail on OBS.** Diagnose properly before acting:
  1. Is the URL reachable from your machine? `curl -sIL --max-time 30 "<url>" | head -1` → `HTTP/1.1 200 OK`, and `sha256sum <local-tarball>` vs a fresh download to confirm the committed tarball is current.
  2. **Has it failed more than once, and is asl-style history present?** Check the package's SR history: `geectl request search --target-project openSUSE:Factory --target-package <pkg> --state accepted --type submit` — if the **last accepted SR is years old** while recent ones all decline on download, the URL is **persistently unreachable from OBS**, not transient.
  - **Transient** (reachable from you, has succeeded recently, fails once): just resubmit — no content change; file a fresh `geectl request file` (optionally refile with `--supersede` the declined one).
  - **Persistent OBS-side block** (you can fetch it but OBS repeatedly can't): retrying is futile. This is common with **non-standard ports** — e.g. `asl` on `john.ccac.rwth-aachen.de:8000` has been un-fetchable by OBS for years (last accepted 2022; every update since declines on the same download, even though `curl` to `:8000` returns 200 locally and the host has no port-80/https mirror). The remedy is to give factory-auto a source it *can* verify: a fetchable mirror URL on a standard port, **or** drop the URL entirely so there's nothing to verify — `Source:  <name>-%{version}.tar.bz2` (bare filename, upstream URL kept in a `# ` comment above it), with the tarball committed in the package. **Confirmed:** with a bare-filename `Source` (no URL), factory-auto's source check passes (`Check script succeeded`) — it only validates download for sources that *are* URLs. Don't keep blindly resubmitting an OBS-unreachable URL. Confirm the package isn't simply stuck-by-design before spending effort; some packages with unreachable upstreams are knowingly parked in their devel project.
- **Rolling-release upstreams that keep only the latest build.** Some projects publish a single moving tarball plus build-numbered snapshots and prune old snapshots (e.g. `asl`: `asl-current.tar.bz2` alongside `asl-current-142-bld<NNN>.tar.bz2`, where stale `bld<NNN>` files eventually disappear). If a download-failure decline turns out to be a *removed* tarball rather than a transient outage, bump to the current build: fetch the rolling `*-current` tarball, read the embedded build number (e.g. `version.h`), update the `%define rev`/`Version`, and confirm `sha256sum` of the rolling tarball matches the new build-numbered one. If the rolling tarball's sha256 equals your already-committed tarball, you're already current — so the decline is *not* a removed-tarball problem; it's either transient or a persistent OBS-side fetch block (see the previous bullet to tell which), and bumping the version won't help.
- **When the upstream download host is *down* mid-update (HTTP 5xx, e.g. Cloudflare 522), DEFER the package — do not degrade to a worse source just to proceed.** A transient outage of the canonical host (e.g. `downloads.mariadb.com` returning 522) blocks fetching the official tarball, but the fix is to wait/retry, not to switch the `Source:` to something inferior. Specifically, **do not swap a signed `-src`/release tarball for a GitHub auto-archive** to dodge the outage: the auto-archive loses the upstream **GPG signature** (`.asc`) verification *and* any **bundled submodules/vendored deps** the release tarball ships, and changes the top-dir name — a real regression carried forever for a momentary outage. Instead: **bank the front-loaded analysis** (which patches drop/rebase, soversion, new deps — see the change-extraction rule) into a memory/note, defer the package, and retry the official host later (a scheduled wakeup is handy). Distinguish this *transient host outage* from a *persistent OBS-side fetch block* (previous bullets): the latter justifies a bare-filename `Source` or a fetchable mirror; the former just needs patience. (Real case: mariadb-connector-c 3.4.9 — `downloads.mariadb.com` 522 with no usable mirror; deferred with analysis banked rather than switching to the GitHub archive.)
