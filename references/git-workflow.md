# Git packaging workflow (src.opensuse.org / Gitea)

openSUSE is migrating package sources from classic OBS `osc` checkouts to **Git on `src.opensuse.org`** (a Gitea instance). Reference: https://en.opensuse.org/openSUSE:Git_Packaging_Workflow (and its companion https://en.opensuse.org/openSUSE:OBS_to_Git). A package is in the Git workflow when you clone it from `src.opensuse.org` instead of `osc co`-ing it; the checkout is a plain git repo (no `.osc/` dir) with the `.spec`, `.changes`, source tarball(s), `.gitattributes`, and `.gitignore`.

**The spec/`.changes`/spec-cleaner/rpmlint rules in this skill are unchanged** — only the *plumbing* around them (fork / checkout / commit / submit) differs. Everything in SKILL.md "Core directive" still applies: spec-cleaner clean, `.changes` entry per session, local `osc build`, etc.

### Repo topology on src.opensuse.org

- `pool/<pkg>` — the canonical package repo (the source of truth, shared across products). Marked **`source`** in `tea repo search`. Default branch is usually **`factory`**. **Do NOT target PRs here.**
- `<devel-project>/<pkg>` (e.g. `devel-factory/hwdata`, `network:messaging:xmpp/libstrophe`) — the devel-project repo, a **`fork`** of pool in Gitea's fork network. Default branch is usually **`main`**. **This is the PR target for package changes.**
- `<youruser>/<pkg>` — your personal fork.

All three live in one Gitea fork network, so a PR can technically be opened between any of them. Find a package's devel project via `pkgs/_meta/devel_packages` in the `openSUSE/Factory` repo (the Factory web UI doesn't show it yet, as of 2026-07).

**PR target = the devel-project repo, not `pool`.** A package change (version bump, spec fix, etc.) goes as a PR to `<devel-project>/<pkg>` (base branch `main`) — that is where the `autogits` bots run (they open the follow-on `_ObsPrj` PR and post OBS build results as a comment). `pool/<pkg>` is the canonical/aggregation repo and is **not** the contribution entry point; a PR opened against `pool` is the wrong target and will just be closed. (Confirmed in practice: a `pool/hwdata` PR was closed by the maintainer in favour of the `devel-factory/hwdata` one.) After the devel PR merges, propagation to `pool` and to `openSUSE:Factory` is handled by the bots / the classic `osc sr <devel-project>/<pkg> openSUSE:Factory` step — not by you PRing pool directly.

### Maintainership lives in git, and the OBS metadata index cannot see it

A scmsync package's OBS `_meta` is a **stub** — `<scmsync>` + `<url>`, with **no `<person>` elements at all**:

```
$ osc api /source/devel:languages:perl/perl-Mojolicious/_meta
<package name="perl-Mojolicious" project="devel:languages:perl">
  <scmsync>https://src.opensuse.org/perl/perl-Mojolicious#c4d329c5…</scmsync>
  <url>https://src.opensuse.org/perl/_ObsPrj</url>
</package>
```

Its maintainers are in a **`_maintainership.json`** file in the git repo (`git-obs file maintainership migrate` converts the legacy format). Consequences, all of them silent:

- `osc api "/search/package?match=person[@userid='<u>' and @role='maintainer']"` — **returns nothing** for it.
- `osc api "/search/owner?project=<prj>&filter=maintainer&user=<u>"` — returns only the *project-level* entry, no `package=` rows.
- `osc api "/search/owner?binary=<pkg>"` — falls all the way back to the `openSUSE:Factory` project owners (`dimstar_suse`, `factory-maintainers`), which reads as "nobody maintains this" when in fact somebody does, in git.

**The command that does see it is `osc maintainer -U <user>`** (osc ≥ 1.15; "Fix 'osc maintainer' not to error out before it prints maintainers in git"). It prints tagged lines and returns **only** git-defined entries:

```
Defined in git package: devel:languages:perl/perl-Test-Harness
Defined in git project: editors:tree-sitter
```

So the OBS index and the git index are **disjoint sets you must union** — on a real account, 268 from OBS + 263 from git with **overlap zero**. `scripts/my-packages.sh` does the union by default. Scale of the blind spot: `osc api "/search/project/id?match=starts-with(scmsync,'https')"` reports **>1100 scmsync projects**, `devel:languages:perl` / `:nodejs` / `:erlang` / `:lua` / `Java:packages` / `GNOME:Factory` / `devel:openSUSE:Factory` / `server:dns` among them.

Related osc-side git support worth knowing: `osc maintained` also lists maintained branches in git, and `osc lbl` works on git-based packages.

### Tooling & one-time setup

- **osc ≥ 1.15.0** is required for `osc fork` (earlier versions have fork bugs). `osc build` and `osc sr` still work as documented elsewhere in this skill.
- **`git-lfs` is mandatory** — source tarballs are stored in LFS, configured by the repo's `.gitattributes` (`*.gz *.xz *.zst *.bz2 *.tar … filter=lfs`). After `git add`-ing a tarball, confirm it's a pointer with `git cat-file -p :<tarball>` (should print `version https://git-lfs.github.com/spec/v1` + oid + size), **not** the raw binary. The working-tree file stays the real tarball, so `osc build` still sees real sources.
- **CLI clients**: `osc` (forking + building + Factory SRs), `tea` (Gitea CLI — logins, fork, PR), and `git-obs` (bundled with osc; PR create/review). Check `tea logins list` for an existing `src.opensuse.org` login before assuming auth is needed.
- **SSH**: clone via `gitea@src.opensuse.org:<owner>/<pkg>.git`; your SSH key must be registered at https://src.opensuse.org/user/settings/keys. First clone may need the host key — `ssh-keyscan src.opensuse.org >> ~/.ssh/known_hosts`.

### Command mapping (old osc → git workflow)

| Old `osc` | Git workflow |
|---|---|
| `osc co <prj> <pkg>` | `git clone gitea@src.opensuse.org:<owner>/<pkg>.git` |
| `osc add file` | `git add file` |
| `osc ci` | `git commit` + `git push` |
| `osc vc` | `osc vc` (unchanged — still the canonical `.changes` editor) |
| `osc build` | `osc build` (unchanged) |
| `osc branch` | `osc fork <prj> <pkg>` |
| `osc rdelete prj/pkg` | `git rm <pkg>` (removes the submodule in a project repo) |

### Forking

Two ways, and the difference matters:

- **`osc fork <devel-project> <pkg>`** (recommended) — creates **both** the Gitea fork (`<youruser>/<pkg>`) **and** an OBS project branch (`home:<you>:branches:<devel-project>`) wired to build your fork via scmsync. Use this when you want OBS to build your changes before/without a PR.
- **`tea repo fork --repo <owner>/<pkg>`** (or `git-obs repo fork`) — Gitea-only fork, **no** OBS build branch. Sufficient when you'll rely on local `osc build` plus the post-PR autogits bot build (below). Lighter weight; no OBS home project left behind to clean up.

### Local build in a git checkout — the gotchas

- There is no `.osc/` metadata, so **`osc build` defaults to building against `openSUSE:Factory`, not the devel project.** Pass **`osc build --alternative-project=<devel-project>`** to use the devel project's build config. (Plain `osc build` from a bare spec also needs an explicit `REPOSITORY ARCH BUILD_DESCR` — see "Local builds" in `references/update-build.md`.)
- **HARD RULE — build against the *target product's* repo, not Factory/Tumbleweed, when the submission is for a maintained product.** A **Leap 16.x** PR must be verified against Leap, not Factory: Leap/SLE ship different (often older) deps, so a green Factory build doesn't prove the change builds on the target. Use `osc build --alternative-project=openSUSE:Leap:16.0 standard aarch64 <pkg>.spec` (or `openSUSE:Backports:SLE-16.0` for a community package; `SUSE:SLFO:1.2` / the SLE repo for an SLFO submission), confirming the repo/arch with `osc repos <project>` and preferring the **native** arch. Factory/Tumbleweed is only the correct base for a *Factory* submission. (Note: two `osc build`s with the same `<repo> <arch>` share one `/var/tmp/build-root/<repo>-<arch>` and will collide — finish/clean one before starting the other, and pass `--clean` when switching the base project.)
- **`osc service runall source_validator` fails in a git checkout** with `Git SCM package working copy doesn't have … project / The package has no parent project checkout`. This is expected — the validator wants OBS parent-project metadata a plain clone lacks. It's not a blocker for local iteration; the real gate is a clean `osc build` (which parses the spec) plus spec-cleaner. (The server-side workflow runs validation for you on the PR.)
- Pick a repo/arch that publishes your **native** arch to avoid qemu emulation. `openSUSE:Factory/standard` only has `x86_64`/`i586`; for aarch64 use `openSUSE:Factory:ARM/standard` (or a Leap repo that lists aarch64). Confirm with `osc repos <project>`.
- **Emulated foreign arches need an x86_64 host.** `osc build`/`osc chroot` for riscv64 via `openSUSE:Factory:RISCV` aborts on an aarch64 host with `Error: hostarch 'x86_64' is required` — the qemu buildconfig pins the *host* to x86_64. So from an aarch64 machine you cannot locally build riscv64 (and native riscv64 would need a riscv64 host); rely on OBS server-side (x86_64 workers) for that arch, or settle arch-specific questions by source inspection. (When a build *is* justified on a non-native arch, expect it to be much slower under qemu.)

### Submitting changes — PR, not `osc sr` (except to Factory)

Contributors send **pull requests on Gitea**, not OBS submit requests. **Target the devel-project repo** (`<devel-project>/<pkg>`, base branch `main`) — never `pool`:

```
# after git commit + git push to your fork:
git-obs pr create --title "..." --description "..." --target-branch main
# or use tea:  tea pr create --base main --head <youruser>:<branch> --repo <devel-project>/<pkg>
# or the Gitea web UI.
```

`tea`/`git-obs` can choke on a fresh checkout with `core.repositoryformatversion does not support extension: objectformat` (a go-git limitation reading newer git repo configs). When that happens, **create the PR via the Gitea REST API** instead:

```
TOKEN=$(python3 -c "import yaml;c=yaml.safe_load(open('$HOME/.config/tea/config.yml'));print([l['token'] for l in c['logins'] if l['name']=='src.opensuse.org'][0])")
curl -sS -X POST "https://src.opensuse.org/api/v1/repos/<devel-project>/<pkg>/pulls" \
  -H "Authorization: token $TOKEN" -H "Content-Type: application/json" \
  -d '{"head":"<youruser>:<branch>","base":"main","title":"...","body":"..."}'
```

**Build the JSON payload in Python, not by interpolating the body into a `-d "{…\"body\":\"$BODY\"…}"` string.** A PR body almost always contains characters that break inline JSON — a literal `"quoted phrase"`, a backtick, a newline — and the failure is silent-ish: the branch is already pushed, so you just get `jsontext: invalid character '…'` and *no PR*. Use `json.dumps({...})` with `urllib` (it escapes everything), the same shape as the [bug-close snippet](bugzilla-cve-triage.md). (Real case: a body containing `"WARNING: Cannot open …"` broke the curl `-d`; rebuilding the payload with `json.dumps` fixed it.)

### Verify a push/PR actually landed — don't trust a piped push

**Never confirm `git push` through a pipe** (`git push -q 2>&1 | tail -1 && echo pushed`): the pipeline's exit status is the *last* stage's (`tail`, always 0), so a failed push reports success and the remote silently stays stale. Push **unpiped** and read the result: a real push prints `   <old>..<new>  <branch> -> <branch>` (or `* [new branch] …`); check `echo "exit=$?"`. (Real case: an entire session's commits to a GitHub skill repo *looked* pushed every time but never left the laptop — the remote sat on the pre-session commit. See [[verify-git-push-exit-code]].) For an important push, compare the remote HEAD afterwards via the API (`/commits?per_page=1`) against `git rev-parse HEAD`.

**Verify the LFS *object* uploaded, not just the pointer.** `git lfs push origin <branch>` is also commonly piped, and a missing LFS object only surfaces later as a bot/OBS build failure (*"Unable to find source for object …"*). Gitea's `…/raw/branch/<branch>/<tarball>` returns the **pointer** (~130 B) — that only proves the git content, not the object. Fetch the **`…/media/branch/<branch>/<tarball>`** endpoint (LFS-resolving) and confirm its byte count equals the pointer's declared `size`:
```
ptr=$(curl -s .../raw/branch/<branch>/<tarball>)         # has "size <N>"
actual=$(curl -s .../media/branch/<branch>/<tarball> | wc -c)   # must equal <N>, and be >2 KB
```

What happens after the PR opens:
- The **`autogits-devel` bot** automatically opens a second PR against the project's `_ObsPrj` repo.
- The **`autogits_obs_staging_bot`** creates an OBS build project, builds the change, and **posts build results as a comment on your PR** — this is your server-side build feedback (you don't need an OBS home branch just to see if it builds).
- Prefix the PR title with **`WIP:`** to suppress the bot automation while iterating.
- Maintainer approves → bot auto-merges. A maintainer's own PR auto-merges on a successful build.

**Submitting to `openSUSE:Factory` is still pure osc** — it is *not* yet managed through Git/Gitea (as of 2026-07). After your change lands in the devel project (PR merged), run the classic `osc sr <obs-devel-project>/<pkg> openSUSE:Factory` (see "Submit requests" in `references/submit-watch.md`). The whole Factory review chain (`factory-auto`, `licensedigger`, staging, `opensuse-review-team`) is unchanged.

**The `osc sr` source is the OBS devel-project name, not the Gitea org name** — they differ. The Gitea org `devel-factory` corresponds to the OBS project `devel:openSUSE:Factory` (the catch-all Factory devel project for packages without a more specific devel project). So a package whose git repo is `devel-factory/hwdata` is submitted with:

```
osc sr devel:openSUSE:Factory/hwdata openSUSE:Factory
```

i.e. the SR runs against `api.opensuse.org` (OBS), referencing the OBS-side project, **after** the Gitea PR to `devel-factory/hwdata` has merged and OBS has synced that revision. Don't pass the Gitea path (`devel-factory/hwdata`) to `osc sr` — `osc` won't find it. If unsure of the OBS devel-project name, `osc develproject openSUSE:Factory <pkg>` returns it.

Before submitting, confirm the merge actually synced into OBS — `osc cat <obs-devel-project> <pkg> <pkg>.spec | grep ^Version:` (and the top of the `.changes`) should show your new version. The Gitea→OBS sync is near-instant but not literally instantaneous; if the spec still shows the old version, wait and re-check rather than submitting the stale revision.

**Skip `osc results` before the SR for git-tracked packages.** When the package lives in a git-based devel project (the Git packaging workflow), build verification is the PR/autogits bot's job — it already built the change and posted results on the Gitea PR before it merged. Polling `osc results <obs-devel-project> <pkg>` before `osc sr` is therefore the wrong check for git-tracked packages; skip it and go straight from "merge synced into OBS" to `osc sr`. (The pre-SR `osc results` poll still applies to **classic osc-checkout** devel projects, where OBS is the only thing that built your commit.)

### A PR is NOT built by OBS unless that repo opted in — check before you promise results

The bot-built-it assumption above holds for **autogits-managed** devel repos. It does **not** hold generally: a `src.opensuse.org` repo gets its PRs built only if someone wired up the SCM/CI integration, and plenty of scmsync-backed devel repos never did. Checked across `science/*`, `editors/*`, `pool/*` and several `devel:*`: none had an `.obs/` directory at all. So when a maintainer says *"I don't see any build results"*, the answer is usually **nothing builds PRs here** — say that instead of hunting for a broken bot.

Two-call tell:

```
curl -s .../api/v1/repos/<org>/<pkg>/contents/.obs          # 404 → no integration
curl -s .../api/v1/repos/<org>/<pkg>/commits/<sha>/statuses  # []  → nothing ever reported
```

Switching it on takes **three** pieces, and **only the first can live in the repo**:

1. `.obs/workflows.yml` on the **target** branch (the path is overridable in the token config).
2. An **OBS workflow token**, created by someone who may write to the target project: `osc token --create --operation workflow --scm-token <gitea-token>`.
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

### Leap 16.x / SLFO / SLE-15 Backports

Routing AND mechanics live in `references/leap-slfo.md` (single home). One orientation note: the Leap 16.x PR target is the `leap-16.x` branch of **`pool/<pkg>`** — the opposite of the Factory devel-repo rule above.

### Upstreaming patches (foreign forges)

When a downstream patch is upstream-eligible (see the Patches section in `references/specfile-guidelines.md` for the `PATCH-FIX-UPSTREAM` tag format and the one-issue-one-PR rule), actually open the upstream PR/MR:

- **Actually file the upstream PR/MR when the fix is a genuine upstream bug (e.g. a build-system defect every packager hits), then reference it.** Keep the patch **minimal and faithful** to the one real bug (don't bundle unrelated cleanups), and **verify the bug still exists on the upstream default/development branch** before opening it — sometimes part of your fix is already merged post-release (`gh api repos/<o>/<r>/contents/<path>?ref=<default-branch> --jq .content | base64 -d`), so narrow the patch to only what's still broken. Mechanics via the GitHub API (works without a local clone of a huge repo): `gh repo fork <o>/<r> --clone=false`; `gh repo sync <you>/<r> --branch <default>`; create a branch ref (`gh api -X POST repos/<you>/<r>/git/refs -f ref=refs/heads/<branch> -f sha=<HEAD>`); commit the edited file via `gh api -X PUT repos/<you>/<r>/contents/<path> -f message=… -f content=<base64> -f sha=<filesha> -f branch=<branch>`; `gh pr create --repo <o>/<r> --base <default> --head <you>:<branch>`. **DCO gotcha: the `Signed-off-by:` email must match the commit *author* email** (the API sets the author from your GitHub account's git email) — a mismatch fails the project's DCO check. If they differ, reset the branch ref to HEAD and re-commit with a matching sign-off. Then add the patch downstream as `# PATCH-FIX-UPSTREAM <file> gh#<o>/<r>#<PR> -- <reason>`. (Real case: Mbed-TLS/mbedtls#10777 — `install(FILES …)` → `install(PROGRAMS …)` so the libmbedcrypto compat shared object is installed executable; the DESTDIR half of the original bug was already fixed on `development`, so the MR was narrowed to just the executable-bit fix.)
- **Non-GitHub upstreams: use the matching forge CLI/API.** **Codeberg/any Gitea** → `tea` (the same client used for `src.opensuse.org`): check `tea logins list`; if the upstream forge isn't there, the login needs a token *the user* generates (`write:repository`+`write:issue` scopes) — have them run `! tea logins add --name codeberg --url https://codeberg.org --token <TOKEN>` so the secret stays on their side. Then fork via the API (`curl -X POST -H "Authorization: token $TOK" .../repos/<o>/<r>/forks`), push the branch with the token via `GIT_ASKPASS` (a one-line script that `printf`s the token — **never** embed it in the remote URL or echo it), and open the PR via `POST .../repos/<o>/<r>/pulls` with `{"head":"<youruser>:<branch>","base":"<default>",…}`. **GitLab** → `glab`. Confirm your fork username from the API (it may differ from your OBS/codeberg display name). (Real case: dnkl/yambar#497 opened on codeberg via `tea`/API.)

### AGit workflow (no fork)

Push straight to a magic ref to auto-create a PR — no fork needed:

```
git clone https://src.opensuse.org/<prj>/<pkg>
# edit, commit
git push origin main:refs/for/main/<feature> -o title="Update to X"
```

**Do not use AGit for repos with LFS-stored source archives** — AGit doesn't support LFS yet (per the wiki's own warning). Since almost every package repo stores its tarball in LFS, this means AGit is rarely the right choice for a normal version bump; fork + PR is the safe default.

### Build-result dashboards

`https://br.opensuse.org/status/<PRJ>/<PKG>[/<repo>[/<arch>]]` — human-readable build status, e.g. `https://br.opensuse.org/status/devel:languages:lua/lua54`. Handy to paste into a README badge or to check status without `osc results`.
