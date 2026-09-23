# Block 3 — Submit to Factory and watch

## Contents
- Committing changes to OBS
  - Auto-forwarding your own submissions
- Monitoring server-side builds (`osc results`, `osc rbl`)
  - `osc results` status vocabulary
  - `osc rbl` — remote build log
  - Release tag rewriting
- Submit requests (`osc sr`, `osc rq`)
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

OBS treats commit and push as a single operation: `osc commit` (alias `osc ci`) sends the change to api.opensuse.org and triggers a server-side rebuild. There is no separate push step. Once `osc commit` returns "Committed revision N", the change is live and irreversible — revisions are immutable, you cannot amend or rewrite them.

> **HARD RULE — a `reviewer` role held by someone else means SUBMIT, never commit directly.** Before committing to *any* project you don't own, read the package `_meta` (`osc meta pkg <prj> <pkg>`) and the project `_meta`. If either sets `<person userid="…" role="reviewer"/>` (or a `<group … role="reviewer"/>`) naming **anyone other than you**, that person has explicitly asked to see changes to this package *before* they land — a direct `osc commit` bypasses exactly the gate they set up, even when your maintainer rights let it succeed. Instead: `osc branch <prj> <pkg>`, do the work in the branch, and file `osc sr <your-branch-project> <pkg> <prj>` so the reviewer is auto-added to the request. **Then leave it alone — do not accept your own SR**, even though you can; the whole point is that the named reviewer decides. Say in the SR message what you'd like their eyes on (a dropped patch, a new `%files` decision, a dep-floor change). This is *in addition to* the never-accept-someone-else's-request rule below — that one governs *their* requests, this one governs *yours*. The same applies transitively to the devel→Factory forward: land it in the devel project through the reviewer first, then forward what they accepted. (Real case: a `network:utilities` package carried a `role="reviewer"` person alongside our own maintainership — the version bump was filed as an SR to the devel project and left for that reviewer, precisely because the release forced a judgement call about not shipping a newly-added static library.)

### Auto-forwarding your own submissions

**The reviewer role is also the gate for forwarding your *own* accepted request onward — and the gate is the `reviewer` role, NOT co-maintainership.** For a request *you* created, you may accept it into the devel project and forward it onward unattended when **no explicit `reviewer` role is set** — by a person *or* a group, on the package *or* the project — and either:
1. you hold `maintainer` on the **package**, or
2. the package has **no maintainer at all** and you hold `maintainer` on the **project** (an unowned package in a project you run is yours to move).

A co-maintainer who never set a reviewer role has not asked to be consulted; an explicit `reviewer` has. Gating instead on "does anyone else co-maintain this" is the wrong test: it blocks the large majority of ordinary packages while catching nothing the reviewer role does not already catch. (Real case that produced this rule: two packages that had to be handled differently were distinguishable *only* by the reviewer role — both had co-maintainers.)

`scripts/autoforward-gate.sh` mechanizes the call: exit 0 ELIGIBLE, 3 BLOCKED (reviewer set — report and wait), 4 NOT_YOURS, 5 meta unreadable. `--batch <file>` takes `<project>\t<package>` lines for a whole set and exits with the worst row (5 > 3 > 4 > 0).

Two absolute limits:
- It applies **only to requests you created**. Accepting or declining **somebody else's** request is always an explicit human decision, whatever the roles say — holding maintainer rights is not permission to use them unattended. See SKILL.md core directive item 10 and "Reviewing incoming requests" below.
- Before forwarding, always check for an **already in-flight request** against the target (`osc api "/search/request?match=(state/@name='new'+or+state/@name='review')+and+action/target/@project='<target>'+and+action/target/@package='<pkg>'"`). Devel maintainers and OBS itself frequently auto-forward on accept (`osc request accept --forward` does both in one step); a duplicate 403s and is noise — see "When *someone else* accepts your home→devel SR" below.

> **HARD RULE — always show the full diff before committing.** Before running `osc commit`/`osc ci` **or any commit-equivalent** (`git commit`/`git push` in a git checkout; an `osc api -X DELETE …/_link`, which is itself a commit; `osc copypac`; `osc service` runs that will be committed), **display the full diff to the user** (`osc diff`, or `git diff`/`git diff --cached`) and let them see it — *every time*, even when they've already said "commit". Show the diff in the same turn, then commit. This is the last review gate before a public, immutable revision; never commit without surfacing the diff first.

Workflow (run after a successful local build and a `.changes` entry):

1. `osc status` — list modified / added / deleted files. Anything not yet staged shows up with `M`/`A`/`D`/`?`.
2. `osc diff` — preview the *full* diff that will be sent. Always read this before committing; it is the last chance to catch a mistake before the change becomes public.
3. `osc add <newfile>` for any new files (sources, patches) that show as `?` in `osc status`.
4. `osc service run source_validator` — run the source-validation service locally before commit (**`run`, never `runall`**: `runall` ignores the declared modes and on a `_service`-bearing package also fires the `mode="buildtime"` `tar`/`compress` services, leaving an artifact you must not commit — see `references/source-services.md` "Service modes decide what you run AND what you commit"). OBS runs this server-side on every commit anyway, but doing it locally catches the same class of issues (sources referenced in the spec but missing from the package dir, unused source files, unparseable spec, bad license tag, a stray trailing `----` separator or malformed date in `.changes` → `'' is not a date`) before they end up in OBS history. **Treat any reported error as a hard blocker** (warnings case-by-case). **Operational rule: only commit on green — chain the gates with `&&`, never `;`, and never pipe the validator before the `&&`.** Writing `osc service run source_validator ; osc commit` commits *even when the validator failed*. Subtler trap: `osc service run source_validator | tail -2 && osc commit` **also** commits on failure — a pipeline's exit status is the *last* command's (`tail`, always 0), so it masks the validator's failure. Run the validator **unpiped** and check its real `rc` (`osc service run source_validator >/tmp/sv.log 2>&1; rc=$?`), or `set -o pipefail`, then `&& osc commit -m "..."`. (Real miss: committed ossim rev 25 with a validator failure because `| tail -2` swallowed `rc=1`.) Likewise only commit when the local `osc build` (incl. `%check`) passed — a failing build/validator must abort the commit, not proceed past it.
5. **Run `osc updatepacmetafromspec` by default as part of cleanup** to sync `URL:`/`%description`/title into the OBS package `_meta`. The spec is not authoritative for the OBS package metadata — `_meta` carries its own copy of the URL and description that's shown on build.opensuse.org, used by web searches, and consumed by tooling. Without this step the spec and `_meta` drift and the project page keeps showing the old URL/description forever. The command is interactive (prints a diff and asks `y)yes / n)no / e)edit Write?`); pipe `echo y |` to confirm non-interactively after reviewing the diff. Run this **before** `osc commit` so any metadata update lands together with the source change. **Do it on every cleanup, not only when you changed `URL:`/`%description`** — the `_meta` frequently drifts or is missing these fields entirely (real case: `Archiving:Backup/vorta`'s `_meta` had no title/description/url at all until synced). If the `_meta` already matches, the command simply produces no diff and is harmless.
6. `osc commit -m "<short message>"` — sends the changes. The `-m` message becomes the OBS revision message (visible in `osc log`); it is **separate** from the `.changes` file bullets. Keep it to one line summarising the `.changes` entry — do not paste the whole `.changes` block in.
7. After commit, `osc status` should return empty. Confirm the new revision with `osc log | head -10`.

Treat `osc commit` the same way as a `git push` to a shared remote — confirm intent before running, and never run it speculatively. Server-side rebuilds are scheduled automatically across all enabled repos and architectures; watch with `osc results` (see next section). Do not assume the local build matches what the server will produce — repository state, build constraints, and macros can differ.

**Broken link because the link target was removed upstream.** A devel package can be a `<link project="openSUSE:Factory" .../>` (often a branch link with `<patches><branch/></patches>`). If Factory later *removes* that package, the link breaks: checkout warns `the link … is currently broken … use 'osc pull'`, and the file list carries `linkinfo … error="openSUSE:Factory/<pkg>: package 'X' does not exist"`. **`osc pull` cannot fix this** — it merges a link against its base, and the base is gone (`osc pull` just re-errors with the 404). When the package already carries its own real sources (spec/tarball/patches are real `<entry>`s, not inherited), the fix is to **drop the `_link`**, turning it into a standalone package:
```
osc api -X DELETE '/source/<prj>/<pkg>/_link?comment=drop+broken+link+(target+removed+from+Factory)'
```
This `DELETE` *is itself a commit* (creates a new server revision immediately — confirm intent first, same as `osc commit`); afterwards `osc up` to sync the local checkout, and `osc st` will be clean. No `.changes` entry needed — it's pure OBS metadata, recorded in `osc log`. The alternative (re-pointing the link elsewhere) only makes sense if a valid new target exists; when Factory simply dropped the package, standalone is correct.

## Monitoring server-side builds (`osc results`, `osc rbl`)

After committing, OBS reschedules every enabled `<repo, arch>` target. `osc results` watches the matrix and `osc rbl` (a.k.a. `osc buildlog`) inspects individual logs — **but reaching for them is opt-in, not a default.** Per the "investigate locally" HARD RULE above: don't poll the server on your own initiative after a commit/SR, and don't query a remote log for something already sitting in `/var/tmp/build-root/.../.build.log` on your disk. Use these tools only when the user asks, or for the narrow cases that genuinely require the server (arch-specific failures you can't build locally, an OBS-only failure, triaging a pasted URL). The commands below document *how* to use them when one of those reasons applies.

### `osc results` status vocabulary

`osc results` shows one line per `<repo, arch>` with a status word. The plain form abbreviates; pass `--verbose` for the full state.

| Plain | `--verbose` form | Meaning |
|---|---|---|
| `succeeded` | `succeeded` | Build OK, package published to the repo. |
| `succeeded*` | `succeeded(unpublished)` | Build OK, but the binary is *not* published — could be project policy (NonFree-style projects often hold a subset of arches back), publish queue lag, or download_on_demand. Not a failure; just means consumers won't see it via zypper. |
| `finished` | `finished: succeeded` / `finished: failed` | Build run completed; check the verbose form to know which. `finished:` alone is not a status — always confirm with `--verbose` before trusting it. |
| `building` | `building: building on <worker>:<slot>` | Still running. Verbose form names the worker — useful when a build is mysteriously slow or stuck. |
| `scheduled` | `scheduled` | Waiting for a worker. |
| `blocked` | `blocked: needed by <X>` | Waiting on another package in the dependency graph. |
| `disabled` | `disabled` | Project / package config disables this `<repo, arch>` deliberately. Don't try to "fix" by enabling without checking `_meta`. |
| `excluded` | `excluded` | Spec's `ExcludeArch:` / `ExclusiveArch:` excludes this arch. |
| `unresolvable` | `unresolvable: nothing provides <X>` | BuildRequires couldn't be satisfied — usually a missing repo dep, not a build error. |
| `failed` | `failed` | Build actually broke. Read the log with `osc rbl`. |
| `broken` | `broken: <reason>` | The package metadata is broken (bad spec, missing source). |

Rule of thumb: only `failed`, `unresolvable`, and `broken` are real problems. `succeeded*` and `finished` look alarming but usually aren't — always run `osc results --verbose` before reporting a failure, and prefer the verbose form when communicating status back to the user.

### `osc rbl` — remote build log

`osc rbl <repo> <arch>` (when invoked inside a package checkout) streams the build log for that target. Aliases / siblings:

- `osc buildlog` — full name (same thing).
- `osc blt` / `osc buildlogtail` — only the tail. Use this first when triaging a failure; it's cheap and the failure reason is almost always near the end.
- From outside a checkout: `osc rbl <project> <package> <repo> <arch>` — the full four-arg form.
- Or `osc rbl <buildlog-URL>` — pasted-URL form, useful for pointing at someone else's failed build from a chat link.

Useful flags:

- `-s` / `--strip-time` — drops the `[ Ns]` elapsed-time prefix from each line. Use it when reading the log as a human — the timestamps add noise. Keep them when comparing build performance across arches or chasing timing-sensitive failures.
- `-l` / `--last` — show the last *finished* log (succeeded or failed); useful when the current state is "building".
- `--lastsucceeded` — show the last *succeeded* log specifically; perfect for diffing against the current failure when a previously-working build breaks.
- `-o OFFSET` — start reading from a byte offset. The log can be megabytes for big packages; use this with `-o $((SIZE-50000))` (or just `osc blt`) to skip to the end.
- `-M FLAVOR` — for multibuild packages, picks the flavor (the `<package>:<flavor>` form).

Triage workflow for a remote-build failure:

1. `osc results --verbose` — identify which `<repo, arch>` actually failed (vs `succeeded*` noise).
2. `osc blt <repo> <arch>` — read the tail. RPM errors, rpmlint errors, and `%check` failures land in the last few hundred lines.
3. If the failure is build-step specific (compile error, missing dep), `osc rbl -s <repo> <arch> | grep -iE "error:|undefined|cannot find"`.
4. If it's a regression, `osc rbl --lastsucceeded <repo> <arch>` and diff against the current to see what changed in the environment.
5. Real failures should usually be reproduced locally with `osc build <repo> <arch>` before pushing a fix — the build root from the local run gives you a debugger-friendly environment (binaries left in `/var/tmp/build-root/...`, see Local builds).

### Release tag rewriting

The `Release: 0` you set in the spec is **not** what shows up in the built RPM name. OBS appends a project-specific suffix during build: `<name>-<version>-<project>.<release-counter>.<rebuild-counter>.<arch>.rpm`. E.g. `stream-5.10-0.aarch64.rpm` locally becomes `stream-5.10-benchmark.8.1.aarch64.rpm` on the server. This is why the "always `Release: 0`" rule works — the server generates the real number and rebases it each commit. Don't try to set the release counter manually.

## Submit requests (`osc sr`, `osc rq`)

A commit to a devel project (e.g. `benchmark/stream`) is **not** the same as a submission to an upstream distribution (e.g. `openSUSE:Factory`). They are two separate steps:

1. `osc commit` — writes a new revision in the devel project. OBS rebuilds it across that project's repos. Nothing automatic happens beyond that.
2. `osc sr <target-project>` (alias `osc submitrequest`) — files a submit request (SR) asking maintainers of `<target-project>` to copy your latest revision in. This is the step that propagates a change upstream.

**This is a real gotcha.** `osc commit` returning "Committed revision N" does *not* mean the change is on its way to Factory; it only means the devel project has it. If a downstream/user reports that a fix you just committed isn't visible, the cause is almost always a missing `osc sr`.

Conversely, an SR may show up in `osc rq list` for a project that you didn't manually create — collaborators can run `osc sr` against the same package between your commit and your next check, or origin-manager / staging bots may file follow-on requests. Don't be surprised by an SR that "appeared" minutes after your commit; check `Created by:` to see who issued it.

### Picking the right target project

The submit target depends on the package's license and category:

- **OSI-approved SPDX license** → `openSUSE:Factory` (the default).
- **Non-SPDX, restricted-redistribution, or NonFree-marker license** (`License: NonFree`, custom benchmark licenses, fonts under non-redistributable terms, etc.) → **`openSUSE:Factory:NonFree`**. Submitting a NonFree-licensed package to plain `openSUSE:Factory` will be declined by `licensedigger`; pick the NonFree target up front.
- **SLE Updates / backports under `SUSE:SLE-*`** → **IBS only.** There are **two separate build services** and this skill's workflows assume one of them: **OBS** (`build.opensuse.org` / `api.opensuse.org`) hosts `openSUSE:Factory`, `openSUSE:Factory:NonFree`, `openSUSE:Backports:*`, `openSUSE:Leap:*`, `devel:*`, `Publishing`, `home:*`; **IBS** (`build.suse.de` / `api.suse.de`, SUSE-internal) hosts `SUSE:SLE-*`, `SUSE:Devel:*` and the internal products, and needs a separate `osc` configuration (`osc -A https://api.suse.de`, or an `[ibs]` profile in `~/.config/osc/oscrc`) plus SUSE-internal network access.
  - **Cross-instance gotcha:** `osc search` from OBS returns matches from *both* — `SUSE:SLE-15-SP*:Update` appears alongside `openSUSE:Backports:*`, because OBS can read the cross-instance metadata. **That visibility is not actionability.** From an OBS checkout you can only file SRs/MRs to OBS-hosted targets; a submission to `SUSE:SLE-*` means re-running the entire workflow against IBS. When listing candidate maintenance-update targets from an OBS context, include only `openSUSE:Backports:*:Update` / `openSUSE:Leap:*:Update` — never propose `SUSE:SLE-*:Update` as something you can act on. If the user explicitly wants an IBS submission, flag it up front: *"I'd need to switch to IBS — confirm you have access."*
- **Maintenance updates for an already-released package** → `osc mr` (maintenance request) rather than `osc sr`; the route is `references/maintenance-updates.md` "Maintenance updates (Backports / Leap)".

### Verifying the target has the package

Before `osc sr <target>`, confirm the target actually has the package — Factory routinely removes packages, and an SR to a removed target gets declined ("The package 'openSUSE:Factory/foo' has been removed"). Do **not** use `osc list <target> | grep <pkg>` for this — it downloads the whole project package list to answer a yes/no question. Two lighter options:

- **`osc develproject <target> <pkg>`** — returns the devel project registered for that package in `<target>`. 404 means the package isn't in the target. Best choice for the pre-SR check because it also confirms which project the target expects SRs *from* (e.g. `openSUSE:Factory/tesseract-ocr` → `Publishing/tesseract-ocr` — your local checkout is the canonical sender). One round trip, one fact you actually needed.
- **`osc cat <target> <pkg> _link`** — for packages set up as a link from one project to another (devel-project branches, maintenance branches), shows the link XML. 404 means no `_link` (the project holds real sources). Use this when chasing project-to-project link relationships, not for the basic existence check.

### Querying existing requests

For the common cases use `scripts/sr-status.py` (state + review chain + comments table; `--brief` for a plain list with staging assignments; includes src.opensuse.org PRs) / `scripts/my-requests.sh` (thin wrapper for the brief view). For a **recurring/scheduled watch** use `scripts/watch-submissions.sh` — it diffs the active SR + open PR set against a saved baseline and prints only the delta (`NOCHANGE` on most firings → stay silent; `RESOLVE SR/PR` lines mean the item left the watched set and the caller fetches the final accepted/declined/merged state). The commands below are what they wrap, for custom queries.

**HARD RULE — "open" must include `declined`, or your status view is blind to the one state that needs you.** The natural definition of an active request is `states=new,review`, and it is wrong for a *creator's* view: a decline is terminal in OBS, so a declined request **leaves the active set** and vanishes from exactly the query you would reach for. The result is a status table that looks entirely healthy while a Factory submission sits dead. Anything answering "what are my submissions doing?" must fetch `new,review,declined` — which is why `sr-status.py --state open` (and `my-requests.sh` through it) does. When hand-rolling a query, spell the state out:

```
osc api '/request?view=collection&states=new,review,declined&roles=creator&user=<user>&types=submit'
```

**The delta-watcher case is different and must NOT be "fixed" the same way.** `watch-submissions.sh` deliberately snapshots only `new,review`, because it reports *change*: a decline shows up as the id **disappearing** from the active set between runs, which it emits as a `RESOLVE` line for the caller to resolve with `osc request show`. Adding `declined` to a delta watcher's baseline would make every decline a permanent resident of the snapshot and silence exactly one notification. Snapshot the active set; query the creator's set with declines included. (Real case: a Regina-REXX Factory decline was invisible in the default status table for hours because `open` meant `new,review`; the scheduled watcher's disappearance check would have caught it.)

| Command | What it shows |
|---|---|
| `osc rq list <project>` (alias `osc request list`) | Open requests **involving** that project — both directions (source or target). |
| `osc rq list -P <project>` | Same, but the `-P` flag is explicit. Useful when the project name could be confused with a state keyword. |
| `osc rq list <project> <package>` | Open requests against that specific package. |
| `osc rq list -s 'new,review,declined,accepted,revoked'` | Filter by state. Defaults to open states only — add `accepted,revoked` to see historical SRs. |
| `osc rq show <NN>` | Full detail of one SR: source, target, message, every review's state, and the history log. |
| `osc rq list -U <user>` | Requests **involving** a user — **not** creator-only (see below). |
| `osc rq list -M` | Requests you have to act on (you are a reviewer or owner). |

`-P` returns **both** directions. Read the `submit: A/x -> B` line to interpret each entry: if the project of interest is on the left, the SR is *outgoing*; on the right, *incoming*. Maintenance-incident lines (`maintenance_incident: …`) follow the same convention.

**`osc rq list -U <user>` is not a creator filter.** It returns every request the user is *involved* in — including ones where they are only a reviewer or a maintainer of the target package (the `Created by:` line in the output will frequently be someone else). There is **no creator-only flag** in `osc rq list`. To get the requests a user actually *authored*, query the request-search API with `roles=creator`:

```
# declined submit requests created by <user> targeting Factory:
osc api '/request?view=collection&states=declined&roles=creator&user=<user>&types=submit&project=openSUSE:Factory'
```

The result is a `<collection>` of `<request>` elements — parse `@id`, `state/@who`, `state/@when`, and `action/source` + `action/target` for each. Adjust `states=` (comma-separated), drop `project=` for all targets, or change `roles=` (`creator`, `reviewer`, `maintainer`, `source`, `target`) as needed. `osc whois` prints your own OBS username for the `user=` value.

### Reviewing incoming requests (other people's submissions to your packages)

The mirror image of the rest of this file: requests *others* file against packages/projects the user maintains. `scripts/watch-submissions.sh` reports them as `NEW INCOMING SR <id> <pkg> from <creator> [state]`; the full standing set is
`osc api '/request?view=collection&roles=maintainer,reviewer&user=<user>&states=new,review&limit=250'` (filter out `@creator == <user>`, which is the outgoing set).

That full standing set — and `osc request list --incoming -U <user>` likewise — includes requests gated on a *group* review the user merely belongs to (`opensuse-review-team`, `factory-staging`, …), often the bulk of the result on a Factory-active account. For "what needs *my* decision, not my group's": `scripts/incoming-requests.py` restricts to explicit person-level `role="maintainer"` targets, excluding `by_group`-only SRs, plus the Gitea equivalent — open PRs where the user is individually in `requested_reviewers`, excluding team-only (`requested_reviewers_teams`) ones.

**Separate the two populations before reporting anything** — they are not equally actionable:
- **`submit` into a devel project** (`editors`, `devel:tools:scm`, `multimedia:apps`, `science:machinelearning`, …) — a contributor's change awaiting a maintainer. This is the real review queue.
- **`maintenance_incident` / `maintenance_release` against `openSUSE:Maintenance*` or `*:Update`** — the QAM/security release pipeline. These land in the queue merely because the user maintains the package in its devel project; the maintenance and security teams drive them and they are **not** the user's to accept. Report them as a counted group, never as individual to-dos. (Real case: a 39-request queue was 25 maintenance-pipeline entries — mostly CVE incidents plus `sectools/auto_maintenance.pl` release requests — and only 14 genuine reviews.)

Reviewing one: `osc request show --diff <id>` gives message, actions and the full spec/changes diff in one call. Read it the way a Factory reviewer would — the decline catalogue in `references/decline-catalog.md` "What human Factory reviewers decline for" applies verbatim, since whatever is accepted here is what the user forwards to Factory under their own name. Checks that repeatedly matter:
- **Spec must stay parseable outside a populated buildroot.** `%(...)` shell expansion in a tag (notably `Requires:`) is a defect: the command runs at *every* parse, so `rpmspec`/`source_validator`/SRPM rebuilds outside OBS get an empty value and a hard "Empty tag" error, and any out-of-order rebuild FTBFS. Prefer static tags, plus a `%check` guard or a macro shipped in the `-devel` package when a value must track upstream.
- **One package per submission** when the devel project feeds Factory: a multi-package SR **cannot be forwarded** to Factory package-by-package, so it is a decline on mechanics alone regardless of content.
- **Competing submissions**: two open SRs for the same package (a version bump and an unrelated fix) will conflict — flag which should land first and that the other needs rebasing or revoking.
- **Age**: requests open for a year or more against maintenance targets are usually stale; propose revoke/decline rather than a blind accept.
- **RFC-shaped requests** ("RFC:" in the message, bundling/vendoring proposals) want a policy opinion, not an accept.

Then **stop**: state the recommendation and wait for the user's explicit go, per the never-accept-or-decline-on-your-own-initiative HARD RULE above. **HARD RULE — that stop includes commenting: do NOT post anything on someone else's request (review comment, finding, nitpick) until the user has seen the review and explicitly said to.** A comment is outward-facing communication under the user's name — the contributor sees it immediately, it cannot be unsent, and the user may want to rephrase, drop a point, or handle it in person. Proposing a comment is encouraged — when a finding deserves one, say so and include the ready-to-post draft in the report; just don't send it. When the user does approve one, the mechanics: `osc api -X POST '/comments/request/<id>' -f <file>` (there is **no** `osc request comment` subcommand; the API endpoint is the way).

### Triaging your declined submit requests

A recurring task is "which of my submissions are declined and need attention?" Workflow:

1. **List them** with the `roles=creator` API above (`states=declined`), reading each `state/@who` (decliner) and the decline comment. Group by decline reason:
2. **Bookkeeping declines (quick fixes)** — `factory-auto`/reviewer rejected on a fixable spec/source issue:
   - *Orphaned source* (`… is not mentioned in spec files as source or patch`): declare the file as `Source`/`Patch`, or `osc rm` it if obsolete (verify which — see Patches section; e.g. an unreferenced `.desktop` used only via `%suse_update_desktop_file -i`).
   - *Patch added/deleted without changelog note* (`A patch (X) is being added/deleted without this … being mentioned in the changelog`): add a bullet naming the literal filename on one line — a rename needs both names, a glob or `%{version}` form does not count. `scripts/changes-patches.sh` reproduces the bot's check locally; run it before resubmitting.
   - *License typo* (`invalid-license` / a wrong SPDX token): fix the `License:` tag.
   - *"missing details on why we update"* (human reviewer): write a proper, curated `.changes` entry.
   - Fix → local build → `osc diff` → `source_validator && osc commit` → resubmit (`osc sr <devel>/<pkg> openSUSE:Factory --supersede <declined-id>`).
3. **"The package '…' has been removed"** — the target is gone from Factory; a plain resubmit just re-declines. This is now a **new-package submission**: update + cleanup + make it build cleanly (these are often packages dropped *for* a CMake-4/GCC-15 FTBFS — fix that), then `osc sr … --supersede <declined-id>` (expect the `(new package?)` warning + stricter `opensuse-review-team` review). Or `osc rq revoke` if you don't want to re-add it. Route and rights: `references/new-package.md` "Submitting a brand-new package".
4. **Stale/obsolete declines** — if the devel-project sources now match Factory (`osc rdiff openSUSE:Factory <pkg> <devel-project> <pkg>` is empty), the decline is moot → `osc rq revoke <id>` to tidy (revoke works on `declined`; see state vocabulary).

**Amending an in-flight Factory/devel submission** (e.g. to add a `boo#` ref after you already submitted): edit the `.changes` entry, commit, then **revoke the stale Factory SR** (`osc request revoke <id> -m "superseding: …"`) and re-submit fresh — don't leave two competing SRs for the same package. (Real: vapoursynth — revoked SR, amended changelog to reference `boo#1268226`, re-forwarded.) Note the home-branch project is auto-removed once its SR is accepted, so re-branch before amending. Use `osc sr --supersede <declined-id>` when resubmitting over a declined/pending request in one step (see specfile-guidelines.md decline handling); use explicit `osc request revoke` + a fresh `sr` when you must amend sources first — both end with exactly one live SR. For a **pending** SR of your own (same package, same target), a plain `osc sr --yes` already auto-supersedes it — no `--supersede` flag needed (confirmed live: filing a langsmith 0.9.6 SR flipped the pending 0.9.5 SR to `superseded by <new-id>` automatically); still verify with `osc request show <old-id>` afterwards. **That auto-supersede is only safe when every open request on the package is yours — see the next rule.**

**HARD RULE — the `osc sr` supersede prompt is ALL-OR-NOTHING. Never answer it; always pass `-s <id> --yes`, or create the request through the API.** When other requests are already open on the package, `osc sr` prints **one** line listing *every* one of them and asks **one** question:

```
The following submit requests are already open: 909973 1287670 1371083
Supersede the old requests? (y/n/c)
```

There is **no per-request prompt**, and the same sweep happens silently under a bare `--yes`. Answering `y` (or letting `--yes` decide) supersedes **all of them, including other people's**: `declined` flips to `superseded by <your-id>` with `who=` set to *you*. That is an unauthorised write to someone else's request and it is not cleanly reversible (`superseded` and `declined` are both terminal; the audit trail then reads as though your request replaced theirs). An instruction like "supersede mine, answer `n` for the others" is **impossible to carry out** — the choice is not offered per id.

The two safe forms, both of which touch exactly one request and never render the prompt:

```
osc sr <devel-prj> <pkg> openSUSE:Factory -s <your-old-id> --yes -m "$(cat msg.txt)"
# or, when you want no prompt logic at all in the path:
osc api -X POST -f req.xml '/request?cmd=create'
osc api -X POST '/request/<your-old-id>?cmd=changestate&newstate=superseded&superseded_by=<new-id>'
```

**Do not count on a permission error to stop you.** The duplicate-forward case above shows osc's auto-supersede being refused with `HTTP Error 403: Forbidden` on someone else's request — but that protection is **not reliable**, and the conditions under which it applies have not been pinned down. In the case below the identical operation went through and silently rewrote two third-party requests. Treat the 403 as a lucky outcome, never as a safety net.

**Before filing, always list what is open** (`osc request list <target> <pkg> -s new,review,declined`) so you know whose requests are in the blast radius, and afterwards `osc request show` each id you did *not* intend to touch to prove it is untouched. (Real case: a Regina-REXX resubmit swept up two *other people's* long-`declined` requests on the same package, flipping both to `superseded` under the submitter's own account. The four later supersedes in the same session used `-s`/the API and each hit exactly one request — an unrelated third-party SR still open on the same package survived all of them.)

### SR state vocabulary

- `new` — created, waiting for first review or staging pickup.
- `review` — at least one review is `accepted` and the workflow is progressing; one or more reviews remain `new`.
- `accepted` — all reviews passed; the SR's payload has been applied to the target.
- **Rescuing a `[botdel]` package (repo-checker filed a *delete* request because it FTBFS'd ≥ 6 weeks).** A botdel is a `delete` action against `openSUSE:Factory/<pkg>` (`Created by: repo-checker`, message `[botdel] Package has had build problems for >= 6 weeks`). To save the package: (1) **fix the FTBFS** in its devel project (it's almost always a toolchain/dep break — GCC 15, a libsinsp/Boost/UHD API bump, a dependency that dropped a transitive include — and the package usually still builds on the *older* distro (Leap 15.x) but fails on TW + the newest Leap, which pinpoints "newer toolchain"); (2) **submit the fix to Factory**; (3) **comment on the botdel request** pointing at your fix SR and asking it be declined. **Gotcha — a pending delete request *blocks* your submit:** Factory will decline your update with *"sr#NNNNNN of a different type should be revoked first"* (the delete outranks the submit). So the **botdel must be declined/revoked first**, then resubmit. **How you decline depends on your rights, and `osc request decline` often 403s:** declining the whole *request* needs maintainer rights on the **target** (`openSUSE:Factory/<pkg>`), which a *devel-only* maintainer (you maintain `<devel>/<pkg>` but not the Factory package directly) does **not** have → `HTTP 403 post_request_no_permission`. But factory-auto routes a **by-package review** of the botdel to the devel project (`Review: new Package: <devel>/<pkg>`), and as a devel maintainer you *can* decline **that review**, which declines the whole request. The `--by-package` flag may not exist on your osc, so do it via the API: `osc api -X POST '/request/<botdel-id>?cmd=changereviewstate&newstate=declined&by_project=<devel>&by_package=<pkg>' -d "fixed in sr#…"`. Once the botdel is `declined`, `osc sr <devel> <pkg> openSUSE:Factory` goes through. (Real cases: reuse, yambar, soapy-uhd declined directly as maintainer; **simple-obfs** — `osc request decline` 403'd for the devel-only maintainer, so the by-package review was declined via the changereviewstate API, which unblocked the Factory submit.)
- `declined` — a reviewer rejected it. The decliner's name and reason are in the comment. It won't proceed on its own, but it is **not immutable**: the creator can still `osc rq revoke <id>` it (transitions `declined`→`revoked`, confirmed working) or `--supersede` it with a fresh SR. Revoking obsolete declined requests is good hygiene — e.g. clean up your old declines whose devel-project sources now match Factory: `osc rdiff openSUSE:Factory <pkg> <devel-project> <pkg>` with empty output means identical, so the decline is moot and can be revoked. (A package that errors on rdiff has been removed from Factory; leave those.)
- `revoked` — the SR author (or someone with author permissions) cancelled it before resolution. Not the same as `declined`.
- `superseded` — replaced by a newer SR.

### Typical Factory review chain

A submit request to Factory or Factory:NonFree typically picks up these reviews in order. Each must finish `accepted` for the SR to merge:

1. **`factory-auto` (User review)** — automated check script (spec sanity, no obvious blockers). Usually completes within seconds.
2. **`licensedigger` (User review)** — license SPDX validation. Flags wrong/missing `License:` tags and missing license files.
3. **`factory-staging` (Group review)** — picks a staging project (`openSUSE:Factory:Staging:adi:NN` or `openSUSE:Factory:NonFree:Staging:adi:NN`) for the change.
4. **Staging project review** — the staging project rebuilds the change together with anything else queued and validates the combined state.
5. **`opensuse-review-team` (Group review)** — human review by the openSUSE review team. This is the variable-latency step.

A new review can spawn additional reviews (e.g. `licensedigger` may add a follow-up if it finds a question to resolve). Watch the full chain with `osc rq show <NN>` and re-run as needed; use `osc results --watch` for live staging-rebuild status.

**Querying a staging project's combined state** (step 3–4) — the human-readable web page is `https://build.opensuse.org/staging_workflows/openSUSE:Factory/staging_projects/<staging>`, but for scripting use the API:

```
osc api "/staging/openSUSE:Factory/staging_projects/openSUSE:Factory:Staging:adi:NN?requests=1&status=1"
```

The XML tells you everything you need to triage a staging in one call: `<staged_requests>` (which SRs are in it), `<missing_reviews>` (what each still waits on — usually `opensuse-review-team`), `<building_repositories count>` and `<broken_packages count>` (the rebuild health — both `0` with `<checks>` `success` means the combined build is green), and the overall `state=` attribute (`review` = building/reviewing, `acceptable` = ready to merge). A green staging blocked only by `opensuse-review-team` is in the normal wait state, not stuck.

**Interdependent packages are staged together.** When you submit a set with build interdependencies (e.g. a library + its consumers, like `girara` → `zathura` → the `zathura-plugin-*` set), the `factory-staging` bot generally pulls them into the **same** `adi:NN` staging so the combined rebuild can validate them as a unit — they then get accepted together. Submit the whole set close in time; if one is still in `factory-auto`/`licensedigger` it won't have been assigned a staging yet, so don't be alarmed that early snapshots show only some members staged. (If the bot splits an interdependent set across stagings and the rebuild breaks on the missing dep, that's a sign to ask staging maintainers to co-locate them.)

**The staging assignment is not stable — re-query it, never cache an `adi:NN`.** The bot actively re-groups: a package already sitting in one staging can be **moved** to a different one as the rest of its interdependent set arrives, so the whole set ends up consolidated in a single fresh `adi:NN` (and the original staging is emptied). Observed live: `girara` was first placed alone in `adi:48`; once `zathura` and the five plugins cleared `factory-auto`/`licensedigger`, the bot moved **all seven** into `adi:44` and left `adi:48` empty. So when watching a multi-package submission, on every poll re-read the staging from each request (`osc rq show <id>` → the `Project: openSUSE:Factory:Staging:adi:NN` review line, or the `<staged_requests>` of the staging API) and follow the set to wherever it currently lives — don't keep polling the staging name from an earlier snapshot, or you'll be watching an empty project.

### Filing an SR

**HARD RULE — the Block-2 adversarial change review must have COMPLETED and returned `PASS` before you file.** Never file the request while a review is still running, and never file one that returned blockers intending to fix them afterwards. The reason is that **a submitted request is public**: reviewers, bots and staging start acting on it immediately, so a blocker found after filing costs a supersede or a revoke and burns the accumulated review chain — and every reviewer who already looked did so at a version you knew was wrong. Fix first, submit once.

**HARD RULE: the whole commit gate — `scripts/gate.sh`, one call — must be green before you file, not just at commit time** (`references/update-build.md` "Gate the SR on the whole branch being green" for why each check exists). `factory-auto` re-runs `source_validator` server-side and *declines* on any failure (orphaned/missing sources, unparseable spec, bad license tag, malformed `.changes` date, minisign-not-available, …), so a local red is a decline you can still avoid. Two SR-specific points: re-run it even for a package you committed moments ago (it is the exact gate the server applies, and it is cheap), and keep it **unpiped** in the submit line — `osc service run source_validator >/tmp/sv.log 2>&1; rc=$?` then `&& osc sr ...`, never `;` and never a pipe before the `&&`, whose exit status would be `tail`'s. Applies to **every** target (Factory, NonFree, and the devel-project PR equivalents).

```
# From the package checkout, after a clean local build and a fresh commit:
osc service run source_validator >/tmp/sv.log 2>&1 && osc sr <target-project> -m "<short message>"
```

The `-m` message goes into the SR's `Message:` field. Convention is to make it a *paste* of the new `.changes` entry's bullets (so reviewers can see what's changing without clicking through). This is the one place where pasting the full .changes bullets is appropriate — unlike `osc commit -m`, where one summary line is correct.

If you skip `-m`, `osc sr` opens an editor seeded with the new `.changes` bullets.

Even with `-m`, `osc sr` prints a confirmation diff and asks `Create this request? (y/N)` interactively. Pass `--yes` to skip the prompt when running non-interactively (e.g. from this skill). The `-m` value is also picked up *before* the prompt, so `osc sr <target> -m "..." --yes` is the canonical non-interactive form.

**Delaying/scheduling an `osc` action (sr, commit, mr) — use a local scheduled wakeup, NOT the remote `/schedule` skill.** When a submit must wait (e.g. a Git-workflow PR needs to merge + sync into OBS before `osc sr` to Factory; see the git-workflow section), schedule a **local session wakeup** to resume and run the osc command. **Do not use the `/schedule` skill (remote cloud routines) for this** — those agents run in an isolated cloud sandbox without your local `~/.config/osc/oscrc` credentials, so they cannot authenticate to `api.opensuse.org`/`api.suse.de` and the `osc sr`/`osc commit`/`osc mr` will fail. Any credential-dependent osc/git-push action belongs in the *local* session. Have the scheduled step **verify the precondition before acting** — e.g. `osc cat <devel-project> <pkg> <pkg>.spec | grep ^Version:` shows the new version (PR merged + synced) — and skip/report rather than submit a stale revision if it hasn't. (Real case: hwdata — a 20-min local wakeup verified `devel:openSUSE:Factory/hwdata` had synced to 0.408, then filed the Factory SR.)

### Consolidating several source packages into one — file the submit and the delete as a PAIR

When one source package absorbs another (an upstream monorepo whose several
distributions we had been packaging separately; see the monorepo bullet in
`references/language-packaging.md`), the merge SR is only half the change. The
absorbed source package must be deleted in the same target, or that target ends
up with **two sources producing the same binary**.

- **File both, and cross-reference both.** `osc sr <devel> <pkg> openSUSE:Factory`
  then `osc deletereq openSUSE:Factory <oldpkg> -m "... goes together with
  SR#<id>"`, and put "MUST BE ACCEPTED TOGETHER WITH the delete request for
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
- **Devel-side ordering: `osc rdelete` the old source FIRST, then commit the
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

### Gotchas observed in practice

- **Declined because target was removed upstream.** If you SR a package and the destination has since been removed from Factory, the SR will be declined with a message like *"The package 'openSUSE:Factory/foo' has been removed"*. Before resubmitting, check with `osc develproject <target-project> <pkg>` (404 = removed; see "Verifying the target has the package" above), or `scripts/devel-of.sh` which wraps exactly this.
- **A devel-project package is not necessarily in Factory — `osc sr` to a missing target is a *new-package* submission.** When `osc sr openSUSE:Factory` prints `Warning: failed to fetch meta data for 'openSUSE:Factory' package '<pkg>' (new package?)`, the package does not exist in Factory yet (confirm with `osc develproject openSUSE:Factory <pkg>` → 404). The SR is still created and valid, but it is treated as a **new package**: it picks up the regular bots *plus* a stricter new-package legal/review pass by `opensuse-review-team`, so expect slower acceptance than an in-place update. Flag this to the user up front — "this package isn't in Factory, so this is a new-package submission" — rather than presenting it as a routine update. (ior was a benchmark devel-project package not present in Factory; SR 1355890 was a new-package submission.)
- **`osc commit` can race with collaborators.** If someone else's SR is mid-flight when you commit, your commit will produce a divergent revision and any auto-forwarded SR will reflect *yours*, not theirs. Coordinate before pushing if the package has multiple active maintainers.
- **NonFree subset of arches.** Even with a successful build, `openSUSE:Factory:NonFree` projects often hold a subset of architectures back as `succeeded(unpublished)`. This is policy, not a failure — don't try to fix it by editing the spec.
- **`factory-auto` declines minisign-signed packages.** OBS's source_validator does not have the `minisign` binary available, so any package shipping a `*.minisig` `Source` will be declined by `factory-auto` with `Source validator failed. ERROR: minisign command not available`. The fix is to drop the `*.minisig` (and the accompanying `*.keyring` minisign pubkey, which is then orphaned) from the spec and the package directory before resubmitting. Minisign signatures are useful for *upstream* download verification but cannot be enforced by OBS itself, so they add no value in the package. Document the removal in `.changes` with the validation-failure reason. After fixing, commit and file a new `osc sr`. A declined SR is terminal, but you can still pass **`osc sr <target> --supersede <declined-id> -m "..." --yes`** — `--supersede` works even on a `declined` request and sets it to `superseded by <new-id>` (rather than leaving an orphaned `declined` entry), giving a clean audit trail linking the resubmission to what it replaced. A plain fresh `osc sr` also works; `--supersede` is the tidier choice when you know the old request id.
- **`factory-auto` decline for "Source URLs are not valid / Failed to download" — distinguish a transient upstream blip from a persistent OBS-side fetch block.** factory-auto (and the staging bot) re-fetch every `Source:` URL *from OBS infrastructure* to verify the committed tarball matches upstream; on failure the SR is declined with `Source URLs are not valid. Try 'osc service runall download_files'. ERROR: Failed to download "<url>"` (that `runall` is factory-auto's own boilerplate — do **not** follow it; `osc service run download_files` is the mode-respecting form). **The trap: it can fetch fine from your laptop and still fail on OBS.** Diagnose properly before acting:
  1. Is the URL reachable from your machine? `curl -sIL --max-time 30 "<url>" | head -1` → `HTTP/1.1 200 OK`, and `sha256sum <local-tarball>` vs a fresh download to confirm the committed tarball is current.
  2. **Has it failed more than once, and is asl-style history present?** Check the package's SR history: `osc api '/request?view=collection&roles=target&types=submit&project=openSUSE:Factory&package=<pkg>&states=accepted'` — if the **last accepted SR is years old** while recent ones all decline on download, the URL is **persistently unreachable from OBS**, not transient.
  - **Transient** (reachable from you, has succeeded recently, fails once): just resubmit — no content change; file a fresh `osc sr` (optionally `--supersede` the declined one).
  - **Persistent OBS-side block** (you can fetch it but OBS repeatedly can't): retrying is futile. This is common with **non-standard ports** — e.g. `asl` on `john.ccac.rwth-aachen.de:8000` has been un-fetchable by OBS for years (last accepted 2022; every update since declines on the same download, even though `curl` to `:8000` returns 200 locally and the host has no port-80/https mirror). The remedy is to give factory-auto a source it *can* verify: a fetchable mirror URL on a standard port, **or** drop the URL entirely so there's nothing to verify — `Source:  <name>-%{version}.tar.bz2` (bare filename, upstream URL kept in a `# ` comment above it), with the tarball committed in the package. **Confirmed:** with a bare-filename `Source` (no URL), factory-auto's source check passes (`Check script succeeded`) — it only validates download for sources that *are* URLs. Don't keep blindly resubmitting an OBS-unreachable URL. Confirm the package isn't simply stuck-by-design before spending effort; some packages with unreachable upstreams are knowingly parked in their devel project.
- **Rolling-release upstreams that keep only the latest build.** Some projects publish a single moving tarball plus build-numbered snapshots and prune old snapshots (e.g. `asl`: `asl-current.tar.bz2` alongside `asl-current-142-bld<NNN>.tar.bz2`, where stale `bld<NNN>` files eventually disappear). If a download-failure decline turns out to be a *removed* tarball rather than a transient outage, bump to the current build: fetch the rolling `*-current` tarball, read the embedded build number (e.g. `version.h`), update the `%define rev`/`Version`, and confirm `sha256sum` of the rolling tarball matches the new build-numbered one. If the rolling tarball's sha256 equals your already-committed tarball, you're already current — so the decline is *not* a removed-tarball problem; it's either transient or a persistent OBS-side fetch block (see the previous bullet to tell which), and bumping the version won't help.
- **When the upstream download host is *down* mid-update (HTTP 5xx, e.g. Cloudflare 522), DEFER the package — do not degrade to a worse source just to proceed.** A transient outage of the canonical host (e.g. `downloads.mariadb.com` returning 522) blocks fetching the official tarball, but the fix is to wait/retry, not to switch the `Source:` to something inferior. Specifically, **do not swap a signed `-src`/release tarball for a GitHub auto-archive** to dodge the outage: the auto-archive loses the upstream **GPG signature** (`.asc`) verification *and* any **bundled submodules/vendored deps** the release tarball ships, and changes the top-dir name — a real regression carried forever for a momentary outage. Instead: **bank the front-loaded analysis** (which patches drop/rebase, soversion, new deps — see the change-extraction rule) into a memory/note, defer the package, and retry the official host later (a scheduled wakeup is handy). Distinguish this *transient host outage* from a *persistent OBS-side fetch block* (previous bullets): the latter justifies a bare-filename `Source` or a fetchable mirror; the former just needs patience. (Real case: mariadb-connector-c 3.4.9 — `downloads.mariadb.com` 522 with no usable mirror; deferred with analysis banked rather than switching to the GitHub archive.)
