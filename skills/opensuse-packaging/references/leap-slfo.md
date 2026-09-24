# Leap 16.x / SLFO / Backports — which branch, which flow

Getting a change into Leap 16.x is **not** one path — it depends on where the package comes from. Work this out *first* (`scripts/distro-survey.sh` aside, this is an openSUSE-internal lookup), because the submission target and review bar differ. This page owns Leap 16.x / SLFO / Backports **routing AND mechanics**; generic src.opensuse.org Git workflow (fork, PR, LFS basics) lives in `references/git-workflow.md`.

## 1. Where does the package come from? (decides the target branch)

Check the three feeds for Leap 16.0, in this order:

```
osc api /source/SUSE:SLFO:1.2/<pkg>/_meta        # SLE base (scmsync'd from pool ?trackingbranch=slfo-1.2)
osc api /source/openSUSE:Backports:SLE-16.0/<pkg>/_meta
# and the per-product branches in the git pool:
curl -s https://src.opensuse.org/api/v1/repos/pool/<pkg>/branches   # look for leap-16.0 / leap-16.1 / slfo-1.2 / slfo-main
```

| Branches present in `pool/<pkg>` | Origin | PR target for Leap | Reviewed by | Notes |
|---|---|---|---|---|
| `leap-16.0`, `leap-16.1` | **community / Package Hub** | the `leap-16.x` branch of `pool/<pkg>` | Backports/Package Hub team | The common case for community packages. |
| `slfo-1.2`, `slfo-main` (no `leap-16.x`) | **SLE base (`SUSE:SLFO:1.2`)** | **ask the user for the route** — no pool fork PR to `slfo-*` | **SLFO/SUSE maintainers — higher bar** | `slfo-1.2` feeds SLES 16.0 + Leap 16.0, `slfo-main` rolling SLFO → Leap 16.1: a commercial product. (Real: **xmlstarlet** has only `factory`/`slfo-1.2`/`slfo-main`.) |
| both `slfo-*` and `leap-x.y` | both | prefer the **`leap-x.y`** branch | Backports | When both exist, the community branch is the lighter path. |

**Key trap:** `openSUSE:Backports:SLE-16.0` (OBS) is **scmsync read-only** (`<scmsync>…/products/PackageHub#leap-16.0`), fed from the `leap-16.x` branches — so `osc sr … openSUSE:Backports:SLE-16.0` is the *old* path and is wrong. Submit via the git PR to the branch, which only `scripts/pool-pr.sh` opens (§3 "The pool PR gate").

**Factory and Leap can use *different* mechanisms for the same package — check each independently.** `pool/<pkg>` having a `factory` branch does **not** mean Factory consumes it: a package can be **OSC-managed for Factory** (`osc api /source/openSUSE:Factory/<pkg>/_meta` shows a `<devel project=…>`, not `<scmsync>`) while its Leap variant is **git/scmsync-managed** (`leap-16.x` pool branches). When so, the *same* fix goes out two ways in one session: `osc sr` to Factory via the devel project, **and** a git PR to each `leap-16.x` branch. (Real case: archmage — Factory devel project `Archiving` via `osc sr`, but Leap 16.0/16.1 are `pool/archmage` `leap-16.x` branches via PR; the `pool/archmage:factory` branch is just the git mirror, not Factory's source.)

**Review policy (community/Package Hub PRs):** the Backports/Package Hub team approves; if the sources **match** openSUSE:Factory (or a maintained Leap) no extra sign-off is needed, but a deviation from Factory, or a submitter who isn't a regular Factory maintainer of the package, needs separate Factory-maintainer approval. So sync to *exactly* the Factory version when you can. (Real case: `pool/xmrig` leap-16.0 6.22.0→6.26.0 — PR `pool/xmrig#1` to the `leap-16.0` branch; the submitter maintains xmrig in Factory so it qualified.)

**SLE-base packages: SLFO means ask the user for the route — do NOT treat them as new-to-Leap, and do not open a pool fork PR to `slfo-*`.** A package that is **absent from `openSUSE:Backports:SLE-16.0` and has no `leap-16.x` branch**, yet ships in Leap 16.0, comes from the **SLE base `SUSE:SLFO:1.2`** (the shared base for SLES 16.0 *and* Leap 16.0) — `osc api /source/SUSE:SLFO:1.2/<pkg>/_meta` shows it `scmsync`'d from `pool/<pkg>?trackingbranch=slfo-1.2`. `slfo-1.2` feeds **SLES 16.0** (commercial) and is reviewed by **SLFO/SUSE maintainers**, who own how changes reach it: report what you found (the SLFO version against Factory's, and the fix it lacks) and let the user name the route. `leap-sync.sh`, `target-gate.sh` and `pool-pr.sh` refuse `slfo-*` bases for the same reason.

## 2. Is the Leap branch actually behind? (don't sync a no-op)

`leap-16.0`/`leap-16.1` usually point at the same commit, but **not always** — verify per branch, don't assume:
- `tcpreplay`: `leap-16.0` = 4.5.2 but `leap-16.1` lagged at 4.4.4 (older than 16.0!).
- `lldpd`: both Leaps lagged Factory (1.0.18 vs 1.0.22).

Compare the `Version:` on each target branch against Factory before doing anything.

**A sync can need a COMPANION package — check virtual `Provides` dependencies.** If the Factory version of your package gained a `Requires:` on a virtual symbol (e.g. `<pkg>-traineddata-provider`), the Leap target must have a package providing it — the *old* companion snapshot in Backports may predate that `Provides:`, and the failure only surfaces in **openQA at release validation** ("nothing provides '<symbol>' needed by <pkg>"), after your PR already built green. When a reviewer reports that, don't touch your PR — sync the companion package's pool branch too (`scripts/leap-sync.sh <companion> <leap-branch>`, then its review and `pool-pr.sh`) and link the companion PR in a reply. (Real case: tesseract-ocr 5.5.2 → leap-16.0 needed `tesseract-ocr-traineddata` synced from Factory's git.20240801 snapshot, which introduced the `tesseract-ocr-traineddata-provider` Provides; 16.1 had already gotten the same companion sync from the Leap release manager.)

## 3. Two ways to produce the Leap change

- **Content-sync from Factory** (when `pool/<pkg>:factory` already has the new version): make the leap branch *identical* to factory in one commit — `git rm -rqf . && git checkout origin/factory -- . && git add -A && git commit`. Branches have **unrelated histories** (OBS→Git import), so `git merge origin/factory` fails with "refusing to merge unrelated histories" — content-sync, never merge. (**`scripts/leap-sync.sh [--dir D] <pkg> [leap-branch]` automates this case up to the build**: clone → verify the leap branch exists & is behind factory → content-sync in a per-base worktree `D/<leap-branch>/<pkg>` → LFS fetch/checkout → `target-gate.sh --build` (`--remote` with `--remote`). It pushes nothing: the review and `pool-pr.sh` follow, per "The pool PR gate" below. It refuses — and tells you why — for new-to-Leap packages.)
- **Apply the change directly to the leap branch** (when Factory's pool branch doesn't carry the fix yet — e.g. you just submitted it to Factory and it hasn't merged): branch off `leap-16.x`, apply the same patch/version bump you put in Factory, commit, then the pool PR gate below. This is the path for a fresh CVE fix that goes to Factory + Leaps in the same session (lrzip, lldpd).
- **Content-syncing to a version *newer* than `pool/<pkg>:factory` (an obscpio/LFS package, Factory itself mid-update).** Don't `git checkout origin/factory -- .` — that branch still lags, you'd get the *old* version. Sync from your **local osc checkout of the new version** instead: `git rm` the old package files **and the old `*.obscpio`**, copy the new `*.spec`/`*.changes`/`_service`/`_servicedata`/`*.obsinfo`/`*.obscpio` from the devel checkout, keep the branch's `.gitattributes`/`.gitignore`, `git add -A`. Confirm the obscpio committed as an **LFS pointer** (`git cat-file -p :<file>.obscpio` → `version https://git-lfs.github.com/spec/v1` + oid + size). If `leap-16.0` and `leap-16.1` sit on the **same commit** (`git log -1 origin/leap-16.0` == `origin/leap-16.1`), one sync commit serves both — but each base still gets its own build and its own head branch (below). (Real case: publicsuffix 20250424→20260622 while Factory's SR for 20260622 was still pending.)

**Mirror 16.0 ⇄ 16.1 with a cherry-pick — one commit, one build per base:** after committing on one base, give the other its own worktree and pick the commit there — `git -C D/pool/<pkg> worktree add --track -B leap-16.1 D/leap-16.1/<pkg> origin/leap-16.1`, then `git cherry-pick <commit>` and `git lfs checkout` in it — and run the gate in each. 16.0 and 16.1 are different build roots (release 160000 vs 160100), so a green 16.0 build is no evidence for the 16.1 tree. (Real cases: mbedtls, mbedtls-2, ofono, keepassxc, htop — two PRs each.)

**Practical mechanics for obscpio / LFS packages:**
- **`osc service` fails in a plain git-pool checkout** ("The package has no parent project checkout"). To regenerate the `*.obscpio` (and `.obsinfo`) for a new tag, run the service binary directly:
  `/usr/lib/obs/service/obs_scm --url <giturl> --scm git --revision refs/tags/v<X> --versionformat <X> --exclude '.*' --outdir <tmpdir>`, then copy the obscpio + obsinfo in, `git rm` the old obscpio, `git add` the new, and bump the spec `Version` + `_servicedata` `changesrevision` (from the new `.obsinfo` `commit:`).
- **LTS point-release bump — reuse the factory branch's history.** When Factory has moved to a new major but Leap must stay on the LTS line, the LTS state often still exists as a commit on `origin/factory` *before* the major bump (`git log --oneline origin/factory | grep <ltsver>`). Grab the obscpio/spec/changes from there instead of regenerating. (Real case: mbedtls Leap 16.0 3.6.1→3.6.6 reused the `dd721c5 mbedtls 3.6.6` commit that predated Factory's jump to 4.x.)
- **Build to verify even a content-sync** — `leap-sync.sh` runs `target-gate.sh` on it — **and don't claim "built & verified" in a PR unless you did.** By hand, materialize the LFS source first (`git lfs fetch origin HEAD && git lfs checkout <tarball-or-obscpio>` in the committed tree).

**LFS gotchas (two distinct traps):**
- **Fetch per-branch, never `--all`.** Clone with `GIT_LFS_SKIP_SMUDGE=1`, then `git lfs fetch origin origin/factory` (or whichever branch your tree comes from; `HEAD` once it is committed) + `git lfs checkout <tarball>`. Name the remote-tracking ref: a bare `factory` resolves to the *local* branch, which in a reused clone lags `origin/factory`, so the new tarball's object is never fetched. `git lfs fetch --all` walks *every* ref, and pool repos routinely have objects pruned from old product branches — the fetch dies with `No such OID` over objects your push never touches (real case: pool/ollama, 4 of 148 objects gone from the 2024 leap branches). After fetching, `git lfs fsck --dry-run` proves every object of *your* tree is present (`--pointers` checks only the pointer format, and passes with objects missing). Confirm the tarball staged as an LFS *pointer* with `git cat-file -p :<tarball>` (should print `version https://git-lfs.github.com/spec/v1`).
- **A fresh Gitea fork has EMPTY LFS storage — forks do not share the parent's objects.** So `git push fork <branch>`'s pre-push hook tries to upload every object reachable from the branch history, and dies on the same pruned OIDs (`Unable to find source for object …`). Push objects and refs separately: `git lfs push --object-id fork $(git lfs ls-files -l | awk '{print $1}')` — exactly the objects of the tree being submitted — then `git push --no-verify fork <branch>`. Verify they resolve on the fork (batch API `operation:download`, or the `…/media/…` endpoint) **before** opening the PR; a PR whose pointers dangle fails the staging bot build with the same "Unable to find source" much later. For a pool PR, `scripts/pool-pr.sh` does the split push, objects before the ref, so a PR head never points at objects the fork lacks. The same trap applies to any fork-based PR that adds a new LFS file to a repo you cannot push to directly (real case: a typescript-go PR — the new tarball existed on the fork but the *base* repo's staging bot could not smudge it, `smudge filter lfs failed`; when the base repo is unreachable for LFS writes, the options are asking a maintainer to push the object, or restructuring to avoid the new binary entirely).

### The pool PR gate — build, review, open, watch

A pool PR carries one tree to one base, and the only evidence for it is a build of **that tree against that base**: `openSUSE:Backports:SLE-16.x standard`, which is what the PR bot builds — not `openSUSE:Leap:16.x`, not Factory. A green build of the devel checkout, of an older commit or for the other base proves nothing about it. (Real case: tesseract-ocr's two Leap PRs failed at `%install` with `cp: cannot stat 'doc/*.1'` — the devel checkout had been built, then the pool spec was hand-edited to 5.5.3 keeping `BuildRequires: asciidoc`, which 5.5.3's man pages no longer build with, and that tree was pushed unbuilt.) The order, with `D` the `--dir` of `leap-sync.sh`:

```
scripts/leap-sync.sh --dir D <pkg> leap-16.0        # content-sync, then the target build; pushes nothing
#   a hand-edited tree instead: commit it in D/leap-16.0/<pkg>, then
scripts/target-gate.sh D/leap-16.0/<pkg> --build    # --remote when this host cannot build it natively
#   review THAT tree (agents/changes-review.md): the verdict file's first line is PASS naming "tree <sha12>"
scripts/target-gate.sh D/leap-16.0/<pkg> --review FILE
scripts/pool-pr.sh D/leap-16.0/<pkg>                 # opens the PR, or moves your open one to this tree
scripts/sr-status.py --pr pool/<pkg>#<n>             # done = exit 0; 1 red, 3 pending, 4 stale
```

- **The stamp is keyed on HEAD's tree plus the base.** Any commit after it — a fix, a rebase — is a new tree: build, review and stamp it again. `target-gate.sh <dir>` with no mode says what is missing (no build, no review, stale).
- **One commit, one build per base.** Each base gets its own worktree, build, review stamp and PR. `pool-pr.sh` names new head branches `<base>-<sha12>` and refuses a head that already heads a PR to the other base.
- **Your open PR moves only forward.** `pool-pr.sh` updates it when HEAD contains its head (a fix on top); a tree that would drop its commits — every `leap-sync.sh` re-sync, rebuilt on `origin/leap-16.x` — exits 2 until you pass `--replace`, which also resets the body. Read what the PR carries first; replace it only when this tree supersedes all of it. A re-sync first needs the previous sync's worktree and local branch gone (`git -C D/pool/<pkg> worktree remove --force D/leap-16.x/<pkg> && git -C D/pool/<pkg> branch -D leap-16.x`): `leap-sync.sh` refuses to reset a local branch with commits `origin` lacks, which that branch has while its PR is open or after a squash merge.
- **`--build` is native only, never emulated:** `osc build --clean --trust-all-projects --root <build-root base>/<pkg>-<base>-<arch> --alternative-project=openSUSE:Backports:SLE-16.x standard <arch> <pkg>.spec` for each `_multibuild` flavor the target builds, then it checks that the log built *this* clone's spec, that the root really is that base, and that every other arch the PR project (`openSUSE:Backports:SLE-16.x:PullRequest`) builds resolves (`osc buildinfo`). With no native route — x86_64-only, or too big for this host — use `--remote`: it pushes the fork branch `leapgate/<base>-<sha12>` (never a PR head) and builds it in `home:<you>:leapgate` against the same base; re-run it to poll (exit 3 while pending, until every arch has built the source revision that names HEAD — an arch still showing the previous commit's `succeeded` is pending). Run the remote gates of one package for 16.0 and 16.1 one after the other: each repoints that package.
- **Refused before anything is built:** a dirty worktree (ignored and untracked files count — osc copies them), a detached HEAD, unsmudged LFS files, a clone under `/tmp`, HEAD not on top of `origin/<base>`, HEAD carrying two of your open PRs, an `slfo-*` or `factory` base.
- **Never merge a pool PR, not even your own, and never push to a PR's head by hand**: the reviewers' approval merges it, and `pool-pr.sh` is the only thing that moves a head. A red or stale PR build is yours to act on — fix the tree, then this order again. Stale at the head usually means a hand-made `products/PackageHub` PR pins the old commit and does not follow pushes: report it to the user, don't push around it.
- With `scripts/pr-guard.py` wired into the harness, the other routes — a direct `tea pr create` on pool, any pool PR merge, a push onto a pool PR's head, a hand-written stamp, an emulated `osc build` — are refused before they run.

#### Wrong forms

Each was run by an agent on a live pool PR.

- `git push --no-verify fork <branch>` then `tea pr create --repo pool/<pkg>`, for a tree never built against the base → `pool-pr.sh`, which refuses without a GREEN + PASS stamp for that tree.
- `tea pr merge --repo pool/<pkg> <n>` on your own Leap PR → never: wait for the reviewers.

## 4. New-to-Leap packages are NOT self-service

A Gitea PR merges into an *existing* base branch, and a normal contributor has `push: false` on `pool/<pkg>` — so you **cannot** create a `leap-16.x` branch by PR. Onboarding a new package to Leap needs two `pool`/Package-Hub-maintainer actions: (1) create the `leap-16.x` branch (content = factory), (2) register it as a submodule in `products/PackageHub`'s `leap-16.x` branch `.gitmodules` (the exact keys: `path = <pkg>`, `url = ../../pool/<pkg>`, `branch = leap-16.x`). That's a coordinated request to the Backports/Package Hub team, not a stack of PRs. (Real wall: monero/monero-gui — no `leap-16.0` branch + `push:false`.)

**To work out what a new dependency *cone* still needs in Leap**, check each dep across the three feeds from §1 (SLFO 1.2, Backports:SLE-16.0, `leap-16.x` pool branches) — a dep present in *any* of the three is already available; the gaps are what must be onboarded. (Real case: the FastMCP cone — ~24 deps already in SLFO/Backports, only `python-mcp/jsonref/griffelib/beartype/docstring-parser` missing, plus the 11 new stack packages.)

**Confirm "is it in Leap?" and "can I even do it?" with two API checks before promising anything:**
- *In Leap?* `curl …/api/v1/repos/pool/<pkg>/branches` — **only a `factory` branch ⇒ not in Leap.** Cross-check `products/PackageHub`'s per-Leap `.gitmodules` (`…/products/PackageHub/raw/branch/leap-16.0/.gitmodules`) — a `[submodule "<pkg>"]` entry pointing at `pool/<pkg>` is what actually puts it in Leap. (`osc ls openSUSE:Backports:SLE-16.0` also lists what's there.)
- *Can I onboard it?* `curl -H "Authorization: token …" …/api/v1/repos/pool/<pkg>` → `.permissions.push`. **`false` ⇒ stop** — you can't create the `leap-16.x` branch, and a `products/PackageHub` submodule PR would point at a branch that can't exist yet. Report it as a release-team request, don't burn cycles forking.
- **A whole *stack* can be Factory-only even when its leaf libs are in Leap.** (Real case: zathura + its 5 plugins had only a `factory` branch each, while their deps `girara`/`mupdf` *were* in Leap. The girara/mupdf updates are normal PRs to their existing `leap-16.x` branches; the zathura stack needs the non-self-service onboarding above. Note the bug being "fixed in Leap" can be moot — if the consumer isn't shipped in Leap, the bug never affected Leap.)

## 5. Closing the loop with bugzilla / in-flight fixups

- Per the bug hard rule (`references/bugzilla-cve-triage.md`), cite `boo#` for what the Leap update fixes; for Leap/SLFO submissions where acceptance is uncertain, confirm with the user whether to close on submission or leave open.
- Amending an in-flight SR's changelog (revoke + fresh `sr` vs `--supersede`, incl. the vapoursynth case): see `references/submit-watch.md` ("Triaging your declined submit requests").

## 6. `openSUSE:Backports:SLE-15-SPx` maintenance updates (classic osc, NOT git)

The SLE-15 Backports (`openSUSE:Backports:SLE-15-SP5/6/7`) are **osc-managed maintenance codestreams**, a *different* flow from the Leap-16/git PRs above. The trigger is usually a **reopened security bug**: you closed a CVE citing Factory + Leap 16.x, and the security team reopens it because a SLE-15-SPx Backports codestream still ships the vulnerable version (real case: mbedtls — closed for Factory 4.1.0 / Leap 16.0-16.1 3.6.6, reopened because `Backports:SLE-15-SP7:Update/mbedtls` was still 3.5.1). Note many such packages are **Backports-community-only** (`osc se <pkg>` shows only `openSUSE:Backports:SLE-15-*`, no `SUSE:SLE-*`/`SLFO`) — there is then **no SLE base update to crib from**; the Backports instance is canonical and the fix is yours to make.

**The flow — two paths, both ending in a maintenance incident:**
- **(a) The incident-rights path** (see `references/maintenance-updates.md` "Maintenance updates (Backports / Leap)" for the full steps): `osc maintained <pkg>` (discover which maintained products carry it) → `osc mbranch <pkg>` (branch every maintained instance) → bring the fix in (edit in place, or `osc copypac -e -K <devel> <pkg> <branch-prj> <branch-pkg>` to bulk-copy the devel sources keeping the link) → `osc maintenancerequest <branch-prj> <branch-pkg> <release-prj> -m "…"` (alias `osc mr`).
- **(b) The fallback when `osc mbranch` fails with *"no permission to modify project"*** (that needs maintenance-incident rights): use **`osc branch openSUSE:Backports:SLE-15-SPx <pkg>`** — it branches from the configured **`:Update`** project (checkout `home:<you>:branches:openSUSE:Backports:SLE-15-SPx:Update`); then `osc sr` to `openSUSE:Backports:SLE-15-SPx:Update`, which prints `WARNING: … a maintenance incident request is being created` — that's **expected and correct** for a `:Update` target (the SR auto-creates the incident), not an error.
- Either path: local `osc build` aborts at an interactive trust prompt (the build root pulls from `SUSE:SLE-15-SPx:Update`) → build with **`--trust-all-projects`** (the general rule: `references/update-build.md` "Local builds", trust prompt policy — `SUSE:*` is non-`home:`).
- Gotchas (no `--yes` flag on `osc mr`, the outdated wiki claim that Backports needs a bug reference, the branch-vrev staleness check): see `references/maintenance-updates.md` "Maintenance updates (Backports / Leap)".
- **When a sibling product already ships the target version, its spec is the template.** (mbedtls: Leap 16.0 was already 3.6.6 — `osc cat openSUSE:Leap:16.0 mbedtls mbedtls.spec` diffed against the SP7 3.5.1 spec showed the *exact* minimal delta: soname `%define`s, `Version:`, one new `%files` line for `pkgconfig/*.pc`.)

**Soname bump in a released maintenance codestream — decide patch-backport vs version-bump:**
- A minor bump (e.g. mbedtls 3.5→3.6) usually **bumps SONAMEs** (libmbedtls20/crypto15/x509-6 → 21/16/7), which forces every consumer in that Backports repo to rebuild. Update **`baselibs.conf`** to the new soname names too (see the baselibs soname-bump rule).
- **Survey first (the distro hard rule decides the approach).** If Fedora/Debian/Arch/Alpine *all version-bumped* and nobody ships isolated CVE patches, then hand-backporting onto the old base is the **higher-risk** path — especially constant-time-crypto fixes, which arrive as sweeping refactors (mbedtls CVE-2025-59438 = ~30-commit CT rework of bignum/RSA/cipher; a subtly-wrong backport silently reintroduces the oracle). Quantify backportability by cherry-picking each fix commit onto the packaged tag in a scratch clone (`git cherry-pick --no-commit -x <c>` → clean vs conflict); when the worst CVE is an un-backportable refactor, the **version bump is the lower-risk, upstream-intended fix**.
- **Size the rebuild scope authoritatively with `_builddepinfo` — `osc whatdependson` is unreliable here (returns empty even for libs that clearly have consumers).** Parse the project's build-dep graph and split consumers by *which* soname/`-devel` they link:
  ```
  osc api '/build/openSUSE:Backports:SLE-15-SP7/standard/x86_64/_builddepinfo' \
    | python3 -c 'import sys,xml.etree.ElementTree as ET;
  [print(p.get("name"),[d.text for d in p.findall("pkgdep") if d.text and "mbed" in d.text])
   for p in ET.parse(sys.stdin).getroot().findall("package")
   if any(d.text and "mbed" in d.text for d in p.findall("pkgdep"))]'
  ```
  (Real case: 24 raw hits, but only **3** linked the 3.x `mbedtls` being bumped — OpenRGB, nemo-extensions, simple-obfs — the other 21 linked the separate `mbedtls-2`/2.28 compat package and were unaffected; the soname bump was cheap.) **Name the rebuild-needed consumers in the `osc sr` message** so the maintenance reviewers can co-schedule them. `scripts/rdeps.sh <pkg-substring> <project>` wraps this query.

**Before backporting a CVE fix onto an old base, confirm the vulnerable code is even present — the fix may target code that postdates the packaged version.** A multi-CVE upstream fix commit often touches several files; on a years-old maintenance base some of those code paths don't exist yet, and *fabricating a patch for absent code is wrong*. For each CVE/hunk:
- `git log -S '<a unique line of the vulnerable code>' -- <file>` to find the commit that introduced it, then `git merge-base --is-ancestor <that-commit> <packaged-tag>` → exit-nonzero ("not an ancestor") means the vulnerable code was added *after* your version ⇒ **not affected**, no patch.
- Sanity-check the affected function/loop actually exists at the packaged tag: `git show <tag>:<file> | grep '<vuln pattern>'`.
- (Real case: openbabel SP7 was 2.4.1; upstream commit `e23a224b8fd9` fixed 3 CVEs across `transform3d`/`mol2format`/`cdxmlformat`, but only the `transform3d` loop existed in 2.4.1 — the `mol2format` `GetAtom(aid)->SetFormalCharge` block and the `cdxml` implicit-H loop were both added post-2.4.1. So only **one** of the three CVEs applied; the other two bugs got a *"not affected — vulnerable code postdates 2.4.1"* comment instead of a fabricated patch.)

**The bump-vs-backport call, summarised across real cases:**

| Case | Gap | Soname change? | Consumers | Backportable? | Chose |
|---|---|---|---|---|---|
| mbedtls 3.5.1→3.6.6 | minor | yes (20/15/6→21/16/7) | 3 | no (CT-crypto refactor) | **bump** |
| mbedtls-2 2.28.6→2.28.10 | patch (within LTS) | **no** | n/a | — | **bump** (cheap, ABI-stable) |
| ofono 1.34→2.19 | major | **no** (daemon, no lib) | 0 | — | **bump** (no new deps either) |
| openbabel 2.4.1→3.2.0 | major (2→3) | yes (5→8) | 2 (won't build vs 3.x API) | yes (tiny hunk) + only 1/3 CVEs apply | **backport** |

Decision drivers, in order: (1) does the vulnerable code even exist at the packaged version? (2) is the fix a small isolated patch or a sweeping refactor? (3) does the bump change the soname *and* are there consumers that won't survive the new major API? A clean small patch against a costly/unbuildable bump ⇒ **backport**; an un-backportable fix or a cheap ABI-safe bump ⇒ **bump**. A *cluster* can also span both flows at once — ofono needed a git PR for `Backports:SLE-16.1` (Leap) **and** an osc maintenance incident for `Backports:SLE-15-SP7` in the same session.

**Once the call is "backport": patch-file mechanics (fetch, naming, `PatchN:` wiring, per-CVE quilt testing, rebase reporting) are `references/quilt-patches.md` "CVE patch backporting".**
