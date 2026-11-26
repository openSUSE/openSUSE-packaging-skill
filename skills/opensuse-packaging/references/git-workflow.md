# Git packaging workflow (src.opensuse.org / Gitea)

openSUSE is migrating package sources from classic OBS checkouts to **Git on `src.opensuse.org`** (a Gitea instance). Reference: https://en.opensuse.org/openSUSE:Git_Packaging_Workflow (and its companion https://en.opensuse.org/openSUSE:OBS_to_Git). A package is in the Git workflow when you clone it from `src.opensuse.org` instead of checking it out with `geectl checkout`; the checkout is a plain git repo (no `.osc/` dir) with the `.spec`, `.changes`, source tarball(s), `.gitattributes`, and `.gitignore`.

**The spec/`.changes`/spec-cleaner/rpmcrab rules in this skill are unchanged** — only the *plumbing* around them (fork / checkout / commit / submit) differs. Everything in SKILL.md "Core directive" still applies: spec-cleaner clean, one `.changes` entry per change, a clean `geectl local-build build`, etc.

## Repo topology on src.opensuse.org

- `pool/<pkg>` — the canonical package repo (the source of truth, shared across products). Marked **`source`** in `tea repos search --login <login>`. Default branch is usually **`factory`**. **Do NOT target PRs here.**
- `<devel-project>/<pkg>` (e.g. `devel-factory/hwdata`, `network:messaging:xmpp/libstrophe`) — the devel-project repo, a **`fork`** of pool in Gitea's fork network. Default branch is usually **`main`**. **This is the PR target for package changes.**
- `<youruser>/<pkg>` — your personal fork.

All three live in one Gitea fork network, so a PR can technically be opened between any of them. Find a package's devel project via `pkgs/_meta/devel_packages` in the `openSUSE/Factory` repo (the Factory web UI doesn't show it yet, as of 2026-07).

**PR target = the devel-project repo, not `pool`.** A package change (version bump, spec fix, etc.) goes as a PR to `<devel-project>/<pkg>` (base branch `main`) — that is where the `autogits` bots run (they open the follow-on `_ObsPrj` PR and post OBS build results as a comment). `pool/<pkg>` is the canonical/aggregation repo and is **not** the contribution entry point; a PR opened against `pool` is the wrong target and will just be closed. (Confirmed in practice: a `pool/hwdata` PR was closed by the maintainer in favour of the `devel-factory/hwdata` one.) After the devel PR merges, propagation to `pool` and to `openSUSE:Factory` is handled by the bots / the forward step (see "Forwarding to Factory" below) — not by you PRing pool directly.

## Maintainership lives in git, and the OBS metadata index cannot see it

A scmsync package's OBS `_meta` is a **stub** — `<scmsync>` + `<url>`, with **no `<person>` elements at all**:

```
$ geectl remote package-meta devel:languages:perl perl-Mojolicious
<package name="perl-Mojolicious" project="devel:languages:perl">
  <scmsync>https://src.opensuse.org/perl/perl-Mojolicious#c4d329c5…</scmsync>
  <url>https://src.opensuse.org/perl/_ObsPrj</url>
</package>
```

Its maintainers are in a **`_maintainership.json`** file in the git repo — read it with `geectl gitea maintainers OWNER REPO`. Consequences, all of them silent:

- `geectl remote search-packages-by-person <u>` — **returns nothing** for it: the OBS person index has no git-defined entries.
- `geectl remote search-projects-by-person <u>` — returns only the *project-level* entries, no package rows.
- `geectl remote owners-for-binary <pkg>` — the same OBS owners for the package shipping that binary, so it falls all the way back to the `openSUSE:Factory` project owners (a Factory release-manager account plus `group:factory-maintainers`), which reads as "nobody maintains this" when in fact somebody does, in git.

**The OBS side and the git side are two different reads, and neither alone is the answer.** `geectl remote maintainers <project> <pkg>` reads only the OBS `_meta` — for a scmsync package that stub names nobody, so the output is the project fallback owners, not the maintainer. **Reading only that output is actively misleading.** The git answer lives in the repo's `_maintainership.json` — read it with `geectl gitea maintainers OWNER REPO` (the git-side counterpart of `remote maintainers`, read from the repo's default branch) before drawing any conclusion. `geectl remote search-projects-by-person <user>` lists only the projects whose OBS meta names the user. Note the entries are **per-product and the name can differ per product** — coordinate with the maintainer of the branch you are actually touching.

Devel-project resolution is unaffected: `geectl remote devel-project <pkg>` and `scripts/devel-of.sh` still return `devel:openSUSE:Factory/hwdata` correctly.

So the OBS index and the git index are **disjoint sets you must union** — on a real account, 268 from OBS + 263 from git with **overlap zero**. `scripts/my-packages.sh` does the union by default. Scale of the blind spot: **>1100 scmsync projects** (no typed geectl form lists them — that enumeration is a gap), `devel:languages:perl` / `:nodejs` / `:erlang` / `:lua` / `Java:packages` / `GNOME:Factory` / `devel:openSUSE:Factory` / `server:dns` among them.

Related git support worth knowing: `geectl maintenance maintained-instances --package <pkg>` lists the maintained products carrying the package, including its git-based ones.

## Tooling & one-time setup

- **`geectl` is the OBS client**: forking, building and filing all go through it (see `references/geectl-usage.md`).
- **`git-lfs` is mandatory** — source tarballs are stored in LFS, configured by the repo's `.gitattributes` (`*.gz *.xz *.zst *.bz2 *.tar … filter=lfs`). After `git add`-ing a tarball, confirm it's a pointer with `git cat-file -p :<tarball>` (should print `version https://git-lfs.github.com/spec/v1` + oid + size), **not** the raw binary. The working-tree file stays the real tarball, so `geectl local-build build` still sees real sources.
- **CLI clients**: `geectl` (OBS work — forking, building, requests), `tea` (Gitea CLI — logins, fork, PR), and `geectl pull-request submit` / the `pull-request` review leaves (PR create/review). Check `tea logins list` for an existing `src.opensuse.org` login before assuming auth is needed. No curl against the API and no token handling: `references/geectl-usage.md` "Tool discipline".
- **SSH**: clone via `gitea@src.opensuse.org:<owner>/<pkg>.git`; your SSH key must be registered at https://src.opensuse.org/user/settings/keys. First clone may need the host key — `ssh-keyscan src.opensuse.org >> ~/.ssh/known_hosts`. The pool PR scripts (`scripts/pool-pr.sh`, `scripts/target-gate.sh --remote`) push over SSH, LFS objects included, and read the forge through `geectl`'s typed leaves (`pull-request search`, `gitea repo-fork`): they need this key and a geectl Gitea token, and read no token themselves. The user lookup goes through `geectl gitea whoami`; the PR filing still goes through `git-obs -G src.opensuse.org api` until geectl gains a create leaf, so a git-obs login is still needed for that read. Every push goes over SSH ("Push over SSH only" below).

## Push over SSH only

**Every push to src.opensuse.org goes over SSH**, to `gitea@src.opensuse.org:<owner>/<pkg>.git`: the SSH user is `gitea`, not `git`. `ssh -T gitea@src.opensuse.org` checks the key (Gitea greets the account and offers no shell). Over HTTPS a push authenticates only with a token, and an agent never handles one, so pr-guard refuses a push to an `https://` or `http://` src.opensuse.org URL, named or through a remote (`[push-https]`).

- **A clone with HTTPS remotes**, fine for anonymous reads and fetches: repoint the remote before pushing, `git remote set-url <remote> gitea@src.opensuse.org:<owner>/<pkg>.git`, and confirm with `git remote -v`.
- **LFS rides on the same key**: git-lfs gets its credentials over SSH (`git-lfs-authenticate`), so `git push` and `git lfs push` to the SSH remote need nothing else.
- **No key, or `Permission denied (publickey)`**: the user's one-time setup (the SSH bullet above). Report it; never fall back to HTTPS.
- **Never route a token** through a URL, an argument, an environment variable or the shell history, and never advise the user to: a token in a push URL is exactly that.

## Gitea CLI — tea 0.15.1 cheat sheet

Checked against `tea <cmd> --help` of tea 0.15.1. `<login>` is a name from `tea logins list` (it also shows your user name on each forge).

- **`--login` and `--repo` belong to each subcommand**, not to `tea` (`tea --login …` is a usage error). Without `--login`, tea takes the login matching the checkout's remote, else its default one; on the wrong instance a lookup fails with *"The target couldn't be found"*, which reads like a missing repo. Pass both, long forms: in `tea pulls edit`, `-r` also means `--add-reviewers`.
- Fork: `tea repos fork --login <login> --repo <owner>/<pkg>` (`--owner <org>` forks into an organisation).
- Open a PR: `tea pulls create --login <login> --repo <owner>/<pkg> --head <you>:<branch> --base main --title "<title>" --description "<text>"`.
- Read a PR with its comments: `tea pulls --comments --login <login> --repo <owner>/<pkg> <n>`.
- Edit its title or description: `tea pulls edit --login <login> --repo <owner>/<pkg> --title "<title>" --description "<text>" <n>`.
- Comment on it: `tea comments --login <login> --repo <owner>/<pkg> <n> "<text>"`, or a text of several lines written to FILE in an earlier call: `... <n> "$(cat FILE)"`, the command alone; `tea comments list` with the same options reads them (without `list` it adds one: `references/request-text.md` "Comments: reading them, posting an approved one").
- Reply inside a reviewer's thread: `tea pulls reply --login <login> --repo <owner>/<pkg> <n> <comment-id> "<text>"`, the id from `tea pulls review-comments`; resolving is in "Responding to a PR review" below.
- Anything else: the typed `gitea` and `pull-request` leaves of geectl — `geectl gitea raw-file OWNER REPO PATH [--ref REF]` for a file read (a missing file is `NotFound`, never empty content), `geectl gitea commit-statuses OWNER REPO SHA` for a commit's CI states, `geectl gitea repo-get OWNER REPO` (the token owner's permissions included), `geectl pull-request show gitea:OWNER/REPO#N` / `comments` / `search --backend gitea --repo OWNER/REPO --state open` for pull requests. There is no generic API command: a read the typed commands do not cover is a missing leaf, not a workaround. Not `tea api`: it exits 0 on a 404, so a failed lookup reads as success.

## Command mapping (classic checkout → git workflow)

| Classic checkout | Git workflow |
|---|---|
| check out | `git clone gitea@src.opensuse.org:<owner>/<pkg>.git` |
| add a file | `git add file` |
| commit | `git commit` + `git push` |
| edit the `.changes` | `geectl changelog generate` / `geectl changelog validate` |
| local build | `geectl local-build build` |
| branch | `geectl branch create --project PRJ --package PKG --live` (Gitea fork + OBS fork into a test project; the OBS-only form is `geectl branch branch-package --project PRJ --package PKG --live`) |
| delete a package | `git rm <pkg>` (removes the submodule in a project repo) |

## Forking

Two ways, and the difference matters:

- **`geectl branch create --project <devel-project> --package <pkg> --live`** (recommended) — branches a git-backed package in one step: the Gitea fork (`<youruser>/<pkg>`) plus the OBS fork into a test project (`home:<you>:branches:<devel-project>`) with the source project's repositories. Use this when you want OBS to build your changes before/without a PR. The two steps separately are `geectl gitea repo-fork <owner> <pkg> --live` + `geectl branch branch-package --project <devel-project> --package <pkg> --live` (the OBS-only branch, for when the Gitea fork already exists).
- **`tea repos fork --login <login> --repo <owner>/<pkg>`** (or `geectl gitea repo-fork <owner> <pkg> --live`) — Gitea-only fork, **no** OBS build branch. Sufficient when you'll rely on a local `geectl local-build build` plus the post-PR autogits bot build (below). Lighter weight; no OBS home project left behind to clean up.

## Local build in a git checkout — the gotchas

- There is no checkout project, so **pass the project explicitly**: `geectl local-build build --project <devel-project> --repo <repo> --arch <arch> DIR --live`. (A plain build from a bare spec also needs the project, repo and arch spelled out — see "Local builds" in `references/update-build.md`.)
- **HARD RULE — build against the *target product's* repo, not Factory/Tumbleweed, when the submission is for a maintained product — and build the exact tree you submit.** Leap/SLE ship different (often older) deps, so a green Factory build doesn't prove the change builds on the target. **A Leap 16.x `pool/` PR:** the target is `openSUSE:Backports:SLE-16.x standard` — what the PR bot builds, not `openSUSE:Leap:16.0` — and the proof is `scripts/target-gate.sh --build` (or `--remote`) run in the pool clone itself: it stamps that tree on that base, and `scripts/pool-pr.sh` refuses to push any other. A green build of the devel checkout is not evidence for the pool branch. → `references/leap-slfo.md` "The pool PR gate — build, review, open, watch".
  For another maintained product use `geectl local-build build --project <product project> --repo <repo> --arch <arch> DIR --live`, confirming the repo/arch with `geectl build list-repositories <project>` and preferring the **native** arch; an SLFO submission needs the user to name the route first. Factory/Tumbleweed is only the correct base for a *Factory* submission. (Note: two `geectl local-build build`s with the same `<repo> <arch>` share one build root and will collide — `--root <dir>` gives a build its own root, which is what `target-gate.sh` does per package and base; otherwise finish/clean one before starting the other, and pass `--clean` when switching the base project.)
- **`geectl local-build service-run --service source_validator DIR --live` has no OBS parent project to validate against in a git checkout** — the validator wants OBS parent-project metadata a plain clone lacks. It's not a blocker for local iteration; the real gate is a clean `geectl local-build build` (which parses the spec) plus spec-cleaner. (The server-side workflow runs validation for you on the PR.)
- Pick a repo/arch that publishes your **native** arch to avoid qemu emulation. `openSUSE:Factory/standard` only has `x86_64`/`i586`; for aarch64 use `openSUSE:Factory:ARM/standard` (or a Leap repo that lists aarch64). Confirm with `geectl build list-repositories <project>`.
- **Emulated foreign arches need an x86_64 host.** `geectl local-build build`/`geectl local-build chroot` for riscv64 via `openSUSE:Factory:RISCV` aborts on an aarch64 host — the qemu buildconfig pins the *host* to x86_64, and `local-build build --arch` must equal the host arch. So from an aarch64 machine you cannot locally build riscv64 (and native riscv64 would need a riscv64 host); rely on OBS server-side (x86_64 workers) for that arch instead: trigger the build with `geectl build rebuild-package PRJ PKG REPO ARCH --live`, then read it with `geectl build wait-for-results --deadline-secs N PRJ --package PKG`, `geectl build build-log PRJ PKG REPO ARCH`, `geectl build build-status PRJ PKG REPO ARCH`, `geectl build results PRJ --package PKG`, `geectl build download-binary --output PATH PRJ PKG REPO ARCH FILE`, `geectl build list-binaries PRJ REPO ARCH --package PKG`, or `geectl build build-history PRJ PKG REPO ARCH`. The submit is not blocked on the build result — it is checked at the accepting step, not before filing. Or settle arch-specific questions by source inspection. (When a build *is* justified on a non-native arch, expect it to be much slower under qemu.)

## Submitting changes — PR, not `geectl request file`

Contributors send **pull requests on Gitea**, not OBS submit requests. **Target the devel-project repo** (`<devel-project>/<pkg>`, base branch `main`) — never `pool`:

```
# after git commit + git push to your fork:
geectl pull-request submit --base main --title "..." --body "..."
# or use tea:  tea pulls create --login <login> --repo <devel-project>/<pkg> --head <youruser>:<branch> --base main
# or the Gitea web UI.
```

On PR opening, `geectl pull-request build-comment --project <test-project> --package <pkg> gitea:<owner>/<repo>#<N> --live` posts the build-link comment on the Gitea PR (the OBS build results for the test project and package, as a link plus a one-line per-instance summary) — posted once, on opening; there is no polling, no live update, and no edit. An OBS handle is refused (the build link belongs on the Gitea PR).

The description follows the SR message rule: `references/request-text.md` "SR and PR messages".

If `tea` fails to read a fresh checkout (`core.repositoryformatversion does not support extension: objectformat`, seen with older builds), run it from outside the checkout with `--login` and `--repo` spelled out, or use `geectl pull-request submit --base main --title "..." --body "..."`. Never fall back to curl with a token taken from the tea config; `geectl pull-request submit` covers what `tea` cannot file.

## Forwarding to Factory

Once the PR merged and OBS synced it into the devel project, the Factory step is a request from that project, gated like any other: in a `geectl checkout <devel-project> <pkg> --live` checkout (scmsync: `.osc/_scm` beside the git tree)
run `scripts/gate.sh`, let the changes review record its `--review`, add `--obs-build` once OBS built it, then file the forward (`references/submit-watch.md` "Filing an SR") — geectl has no form that files a request into openSUSE:Factory directly.

- **The stamp is keyed on what OBS holds.** For a scmsync checkout gate.sh's tree is the files OBS lists for the package (`/source/<prj>/<pkg>?expand=1`, `_scmsync.obsinfo` and `build.specials.obscpio` included), the set the forward carries and pr-guard compares. It stamps only while the checkout holds each of the others with OBS's md5 and no other file, its git `HEAD` is the `commit:` OBS's `_scmsync.obsinfo` names, no file carries git's assume-unchanged or skip-worktree flag (`git ls-files -v` tags only `H`), and `git status --untracked-files=all --ignored` (`.osc` aside, `git replace` refs ignored) is empty, since a build of the tree copies in whatever else lies there: a local edit, one such a flag hides, an untracked or ignored file or directory, a dotfile or symlink, another commit, or a subdirectory OBS packs as `<dir>.obscpio` leaves no stamp, and gate.sh says what differs.
  A checkout without `.git` stamps only with no directory, symlink or dotfile but `.osc` and `.git*`. After the sync, `geectl update --live` and rerun.
  The review's PASS names the `tree <key12>` gate.sh printed; `--review` also takes the checkout's `git rev-parse HEAD^{tree}` (its first 12 characters) while gate.sh holds the checkout to the synced commit, and records it under gate.sh's key.
- **No `geectl commit` there.** OBS takes the sources from git, so pr-guard refuses a `geectl commit` in a scmsync checkout; a change goes by PR.
- **Who may forward it unattended** (`scripts/autoforward-gate.sh`, and pr-guard's accept-forward ask). A project whose `_meta` has `<scmsync>https://src.opensuse.org/<owner>/<repo>…` keeps its roles in that repository, read through `geectl gitea raw-file <owner> <repo> <path> --ref <ref>` (pr-guard reads the same files anonymously, without a login) at the branch or commit its `#fragment` names (`--ref <ref>`; the default branch without one; a fragment that is no plain name, `[A-Za-z0-9][A-Za-z0-9_.-]*` without `..`, is not eligible):
  - maintainers: `_maintainership.json`, the package's list, else the project's `""` list; each entry a list of plain logins (`@` for a group), anything else does not parse. Only the legacy `{"<name>": ["<login>", …]}` form is read: the versioned form, a `_maintainership/` directory, a 404 or a failed read is not eligible, with the reason;
  - reviewers: every name in `workflow.config`'s `Reviewers`, autogits' key for the reviewers it adds to each PR (a list or an object; a `+`, `-`, `*` or `~` prefix only says where and how firmly), blocks like an OBS `reviewer` role; present, it must be a list or an object of plain names (`false`, `""` or `null` does not parse). autogits parses the file as JSON with comments and trailing commas (hujson), and so do these scripts. `ReviewGroups` only name groups `Reviewers` uses; `ReviewRequired` is not read (it asks a second maintainer to review the PR, which the merge already had). No `workflow.config` means no reviewer;
  - a reviewer role in the OBS package or project `_meta` still counts, and a `<scmsync>` on another host, or one these scripts cannot parse (a CDATA section or a comment in the `_meta`, or a second `<scmsync>`, too), is not eligible: never an OBS fallback.

## Verify a push/PR actually landed — don't trust a piped push

**Never confirm `git push` through a pipe** (`git push -q 2>&1 | tail -1 && echo pushed`): the pipeline's exit status is the *last* stage's (`tail`, always 0), so a failed push reports success and the remote silently stays stale. Push **unpiped** and read the result: a real push prints `   <old>..<new>  <branch> -> <branch>` (or `* [new branch] …`); check `echo "exit=$?"`. (Real case: an entire session's commits to a GitHub skill repo *looked* pushed every time but never left the laptop — the remote sat on the pre-session commit. See [[verify-git-push-exit-code]].) For an important push, compare `git ls-remote <remote> refs/heads/<branch>` against `git rev-parse HEAD` afterwards.

**Verify the LFS *object*, not just the pointer:**
- **`git push --no-verify` skips the hook that uploads LFS objects**, so only the pointer arrives: the reviewer sees a file "not uploaded to LFS" and OBS fails with *"Unable to find source for object …"*. After any such push of an LFS-tracked file, push exactly the objects of the pushed commit, unpiped, against the SSH remote: `git lfs push --object-id <remote> $(git lfs ls-files -l | awk '{print $1}')`. Not `--all`: it walks the whole history and dies on objects long pruned from old branches (`references/leap-slfo.md` "LFS gotchas"). A pointer-only push that is not your own PR head — someone else's branch, a shared one — is not yours to repair: tell its owner, or open a PR that carries the object.
- **Prove it from a fresh clone of the branch** (under `/var/tmp`, not in the checkout): `git lfs ls-files` must mark the file `*` (full object), not `-` (pointer only), and `git lfs fsck` must pass. A `raw/` URL returns the pointer and proves nothing.
- **Uploading LFS objects alone does not trigger the OBS sync, and force-pushing the same sha is a no-op.** To make OBS or the PR bot pick the objects up, amend the commit (a new sha) and `git push --force-with-lease` — only onto your own PR head branch (your fork's feature branch), never a shared one (`factory`, `leap-*`, `main`); never an empty commit, which stays in the package history. A Leap pool PR's head moves only through `scripts/pool-pr.sh`.
- **Answer the reviewer inside their thread** (`tea pulls reply`, "Gitea CLI — tea 0.15.1 cheat sheet"), and apply the same fix to every sibling PR or SR carrying that file — both Leap branches, the Factory SR.

What happens after the PR opens:
- The **`autogits-devel` bot** automatically opens a second PR against the project's `_ObsPrj` repo.
- The **`autogits_obs_staging_bot`** creates an OBS build project, builds the change, and **posts build results as a comment on your PR** — this is your server-side build feedback (you don't need an OBS home branch just to see if it builds).
- Prefix the PR title with **`WIP:`** to suppress the bot automation while iterating.
- Maintainer approves → bot auto-merges. A maintainer's own PR auto-merges on a successful build. The approve form, pinned to the head reviewed: `geectl pull-request show gitea:<owner>/<repo>#<N>` must report `source.commit` as the head reviewed, then `geectl pull-request approve gitea:<owner>/<repo>#<N> --live`, never `--reviewer`. Review actions are `geectl pull-request show` / `comments` / `approve` / `request-changes` / `comment` on the `gitea:<owner>/<repo>#<N>` handle. (`pull-request show` is metadata only — no diff; the diff gap is geectl #416.) A contributor's PR to the user's package is approved only after its incoming review recorded PASS or FIXABLE at that head, on the user's go (`references/incoming-review.md` "Devel PRs on src.opensuse.org"); agents never merge one.

**Submitting to `openSUSE:Factory` is still an OBS request, not a Git PR** — it is *not* managed through Git/Gitea. After your change lands in the devel project (PR merged), file the forward from the OBS devel project (see "Submit requests" in `references/submit-watch.md`). The whole Factory review chain (`factory-auto`, `licensedigger`, staging, `opensuse-review-team`) is unchanged.

**The forward's source is the OBS devel-project name, not the Gitea org name** — they differ. The Gitea org `devel-factory` corresponds to the OBS project `devel:openSUSE:Factory` (the catch-all Factory devel project for packages without a more specific devel project). So a package whose git repo is `devel-factory/hwdata` is forwarded from `devel:openSUSE:Factory` — i.e. the forward is an OBS request, referencing the OBS-side project, **after** the Gitea PR to `devel-factory/hwdata` has merged and OBS has synced that revision. Don't pass the Gitea path (`devel-factory/hwdata`) as the source project — geectl won't find it. If unsure of the OBS devel-project name, `geectl remote devel-project <pkg>` returns it.

Before submitting, confirm the merge actually synced into OBS — `geectl remote cat <obs-devel-project> <pkg> <pkg>.spec | grep ^Version:` (and the top of the `.changes`) should show your new version. The Gitea→OBS sync is near-instant but not literally instantaneous; if the spec still shows the old version, wait and re-check rather than submitting the stale revision.

**Skip `geectl build results` before the forward for git-tracked packages.** When the package lives in a git-based devel project (the Git packaging workflow), build verification is the PR/autogits bot's job — it already built the change and posted results on the Gitea PR before it merged. Polling `geectl build results <obs-devel-project> --package <pkg>` before filing the forward is therefore the wrong check for git-tracked packages; skip it and go straight from "merge synced into OBS" to filing the forward. (The pre-forward `geectl build results` poll still applies to **classic-checkout** devel projects, where OBS is the only thing that built your commit.)

## Responding to a PR review — `tea` does what the REST API cannot

A reviewer's **inline review comment** (as opposed to an issue comment) has to be
replied to and **marked resolved**, or a `REQUEST_CHANGES` review sits there
blocking the merge even after you've pushed the fix.

**The Gitea REST API has no resolve-conversation endpoint.** Don't hunt for one:
`swagger.v1.json` is `403` to anonymous *and* token requests on
`src.opensuse.org`, and the web route the browser uses
(`POST /{owner}/{repo}/pulls/{n}/files/reviews/resolve_conversation`) answers
**404 to a token** — it is a session+CSRF route, not an API. **`tea` is the
supported path**, and it wraps calls the plain REST surface doesn't expose:

```
tea pulls review-comments --repo <org>/<pkg> --login <login> <n>   # id, path, line, body, reviewer, RESOLVER
tea pulls reply   --repo <org>/<pkg> --login <login> <n> <comment-id> "<text>"
tea pulls resolve --repo <org>/<pkg> --login <login> <comment-id>   # also: unresolve
```

- **Always pass `--repo` and `--login` explicitly.** A package checkout that has both an
  `origin` (base repo) and a `fork` remote gives `tea` two candidates and it can
  pick the wrong one; naming the slug and the login removes the guess.
- **Verify** by re-running `review-comments` and confirming the `RESOLVER`
  column is populated — a resolve that silently no-ops looks identical to
  success on the command line.
- Reply *and* resolve. Resolving a change-request with no explanation reads as
  dismissal, and the reviewer still has to diff the branch to see what changed.

(Real case: a `typescript-go` PR whose reviewer objected to installing into the
shared `/usr/lib/node_modules`; the fix was pushed, then replied to and resolved
with `tea pulls reply` / `tea pulls resolve`.)

**A reviewer reporting `smudge filter lfs failed` is not automatically your
bug.** Gitea's LFS content store is shared across a repo and its forks, so a
fork-PR's objects usually *are* fetchable from the base repo. Check before
"fixing" anything — fetch the PR head's objects from the base repo, anonymously,
in a fresh clone:

```
git clone --no-checkout https://src.opensuse.org/<org>/<pkg>.git /var/tmp/<dir> && cd /var/tmp/<dir>
git fetch origin refs/pull/<n>/head && git lfs fetch origin FETCH_HEAD
```
A clean `git lfs fetch` means the objects are present and public — the failure
is then the reviewer's client, and the fix is theirs, not a repush.
Note `git lfs push --dry-run <remote>` over **HTTPS** can't authenticate
(`could not read Username`) and then lists *every* local object as "to push",
which looks exactly like "the server has none" — run it against the **SSH**
remote or the answer is meaningless.

## A PR is NOT built by OBS unless that repo opted in — check before you promise results

The bot-built-it assumption above holds for **autogits-managed** devel repos. It does **not** hold generally: a `src.opensuse.org` repo gets its PRs built only if someone wired up the SCM/CI integration, and plenty of scmsync-backed devel repos never did. Checked across `science/*`, `editors/*`, `pool/*` and several `devel:*`: none had an `.obs/` directory at all. So when a maintainer says *"I don't see any build results"*, the answer is usually **nothing builds PRs here** — say that instead of hunting for a broken bot.

Two-call tell:

```
geectl gitea raw-file <org> <pkg> .obs/workflows.yml   # NotFound → no integration
geectl gitea commit-statuses <org> <pkg> <sha>         # [] → nothing ever reported
```

Switching it on takes **three** pieces, and **only the first can live in the repo**:

1. `.obs/workflows.yml` on the **target** branch (the path is overridable in the token config).
2. An **OBS workflow token**, created by someone who may write to the target project — the maintainer runs this, since it prints the token's secret and an agent never handles one: `geectl remote create-token --operation workflow PRJ PKG --live`.
3. A **webhook** on the Gitea repo pointing at that token's payload URL, subscribed to the Pull Request event — needs repo-admin rights.

So a drive-by contributor can only ever *propose* the YAML; a maintainer must finish it. **Say that plainly when offering one** rather than implying the PR will start building on merge.

```yaml
build_pull_request:
  steps:
    - branch_package:
        source_project: <devel-project>
        source_package: <pkg>
        target_project: <devel-project>:CI
  filters:
    event: pull_request
```

`target_project` must already exist; each PR lands in `…:PR-<n>`. Other steps: `submit_request`, `link_package`, `configure_repositories`, `rebuild_package`, `set_flags`, `trigger_services`. **For an scmsync package `branch_package` does the right thing** — OBS writes the PR's commit SHA into the branched package's `scmsync` attribute, which triggers the source services and rebuilds every `_multibuild` flavor, then reports back as a commit status. Docs: openbuildservice.org → obs-user-guide → `cha.obs.scm_ci_workflow_integration` (the useful detail is in the code blocks, not the prose).

**Meanwhile, a local build is the only evidence you have** — which is exactly when the "never state a build result you have not read" rule in `references/update-build.md` bites, because the reviewer is taking your word for it.

## Leap 16.x / SLFO / SLE-15 Backports

Routing AND mechanics live in `references/leap-slfo.md` (single home). One orientation note: the Leap 16.x PR target is the `leap-16.x` branch of **`pool/<pkg>`** — the opposite of the Factory devel-repo rule above — and only `scripts/pool-pr.sh` opens or updates that PR.

## Upstreaming patches (foreign forges)

When a downstream patch is upstream-eligible (see the Patches section in `references/specfile-guidelines.md` for the `PATCH-FIX-UPSTREAM` tag format and the one-issue-one-PR rule), actually open the upstream PR/MR:

- **Actually file the upstream PR/MR when the fix is a genuine upstream bug (e.g. a build-system defect every packager hits), then reference it.** Keep the patch **minimal and faithful** to the one real bug (don't bundle unrelated cleanups), and **verify the bug still exists on the upstream default/development branch** before opening it — sometimes part of your fix is already merged post-release (`gh api repos/<o>/<r>/contents/<path>?ref=<default-branch> --jq .content | base64 -d`), so narrow the patch to only what's still broken. Mechanics via the GitHub API (works without a local clone of a huge repo): `gh repo fork <o>/<r> --clone=false`; `gh repo sync <you>/<r> --branch <default>`; create a branch ref (`gh api -X POST repos/<you>/<r>/git/refs -f ref=refs/heads/<branch> -f sha=<HEAD>`); commit the edited file via `gh api -X PUT repos/<you>/<r>/contents/<path> -f message=… -f content=<base64> -f sha=<filesha> -f branch=<branch>`; `gh pr create --repo <o>/<r> --base <default> --head <you>:<branch>`. **DCO gotcha: the `Signed-off-by:` email must match the commit *author* email** (the API sets the author from your GitHub account's git email) — a mismatch fails the project's DCO check. If they differ, reset the branch ref to HEAD and re-commit with a matching sign-off. Then add the patch downstream as `# PATCH-FIX-UPSTREAM <file> gh#<o>/<r>#<PR> -- <reason>`. (Real case: Mbed-TLS/mbedtls#10777 — `install(FILES …)` → `install(PROGRAMS …)` so the libmbedcrypto compat shared object is installed executable; the DESTDIR half of the original bug was already fixed on `development`, so the MR was narrowed to just the executable-bit fix.)
- **Non-GitHub upstreams: use the matching forge CLI.** **Codeberg/any Gitea** → `tea` (the same client used for `src.opensuse.org`): check `tea logins list`; if the upstream forge isn't there, *the user* adds it — `tea logins add` without arguments asks interactively (a token with `write:repository`+`write:issue` scopes), so the secret never passes through you. Then `tea repos fork --login <login> --repo <o>/<r>`, push the branch over SSH (the user's key registered on that forge), and `tea pulls create --login <login> --repo <o>/<r> --head <you>:<branch> --base <default>`. **GitLab** → `glab`. Take your fork's user name from `tea logins list` (it may differ from your OBS/codeberg display name). (Real case: dnkl/yambar#497 opened on codeberg via `tea`.)

## AGit workflow (no fork)

Push straight to a magic ref to auto-create a PR — no fork needed:

```
git clone https://src.opensuse.org/<prj>/<pkg>
# edit, commit
git push origin main:refs/for/main/<feature> -o title="Update to X"
```

**Do not use AGit for repos with LFS-stored source archives** — AGit doesn't support LFS yet (per the wiki's own warning). Since almost every package repo stores its tarball in LFS, this means AGit is rarely the right choice for a normal version bump; fork + PR is the safe default.

## Build-result dashboards

`https://br.opensuse.org/status/<PRJ>/<PKG>[/<repo>[/<arch>]]` — human-readable build status, e.g. `https://br.opensuse.org/status/devel:languages:lua/lua54`. Handy to paste into a README badge or to check status without `geectl build results`.
