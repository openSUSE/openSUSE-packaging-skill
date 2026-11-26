# geectl usage — the exact invocations this workflow uses

Call geectl exactly as below: don't guess a form and don't run `geectl <cmd> --help`. CI checks every `geectl` citation in this skill against geectl's own `--help` (the built binary; the target-state leaves in `tests/repo/geectl-target-state.json` are checked against that file until they land): the command exists, every cited option is accepted, and each command the skill uses has a line here. Positionals are not machine-checked, so copy them as written. `PRJ`/`PKG` are OBS project/package names; one line per command.

**Install:** `cargo install geectl` (version 0.2.3 or later). GitHub release tarballs are the other form: `geectl-<version>-x86_64-unknown-linux-gnu.tar.gz` or `geectl-<version>-aarch64-unknown-linux-gnu.tar.gz`, each with a `.sha256` checksum and a detached `.asc` signature plus a combined `SHA256SUMS`. Fetch the tarball for the release, verify its `.sha256` checksum and `.asc` signature, and put the `geectl` binary on `PATH`. Tarballs are Linux-only; on macOS use `cargo install`. **Auth:** geectl reads its own config (`$XDG_CONFIG_HOME/geectl/config.toml`, default `~/.config/geectl/config.toml`); credentials come from the environment only, per named instance: a token via `GEECTL_OBS_APIKEY_<ALIAS>`, or username/password via `GEECTL_OBS_USERNAME[_<ALIAS>]` / `GEECTL_OBS_PASSWORD[_<ALIAS>]` (or the `*_FILE` variants). The alias names the instance in the config file; the plain (un-suffixed) variables apply only to the default URL. The config file holds endpoints only and refuses credential-shaped keys. Per-call instance selection is the global `--instance` flag (`geectl --instance=ALIAS remote whois`): the flag beats the environment and the working-copy state, and credentials resolve from the flagged instance`s own env keys only. Migrating from osc: `geectl config import-oscrc --live` imports one instance mapping from an oscrc file (one-time; never passwords). `geectl config show` reports endpoint URLs and credential status, never a secret value.

**Where checkouts live:** one geectl working area, with projects as subdirectories (`<area>/<prj>/<pkg>`). Run `geectl checkout` from the area itself, never from inside a `<prj>/` checkout (that nests one), and never check out into `/tmp` or a scratchpad — the build, the gates and the commit all run from the checkout, and a throwaway location loses them. → `references/update-build.md` "Avoid full-project checkouts"

## Tool discipline

**HARD RULE — every service through its own client.** A hand-rolled HTTP call skips the client's auth and error handling and every check this skill documents.

- **OBS: `geectl`** — a command from this page. There is no generic API command: a read the typed commands do not cover is a missing leaf, not a workaround — never curl, wget or urllib `api.opensuse.org` or `build.opensuse.org`, and never hand-roll an HTTP call to either.
- **src.opensuse.org: the bundled scripts, `tea` or `git-obs`**, and `git-obs -G src.opensuse.org api` when none of them fits — never curl or urllib its API, and never `tea api` for a lookup: it exits 0 on an HTTP 404. Name the forge on every call — `git-obs -G src.opensuse.org`, `tea … --login <login>` — or the tool takes its default login, possibly another forge's, and that forge's 404 reads as "not there". Push over SSH. Forms: `references/git-workflow.md` "Gitea CLI — tea 0.15.1 cheat sheet".
- **GitHub: `gh api`**, which authenticates itself — never an unauthenticated `curl` of `api.github.com`, which runs into the rate limit within a sweep.
- **Unpack into `/var/tmp`**, never `/tmp`: a vendor tree or an RPM extraction there runs `/tmp` out of space or inodes for every session on the host.
- **Credentials stay inside the tools.** Never read a geectl config file, a password file, or an API-key file, and never put a token in a URL, a header or argv — no `Authorization:` header, no `GIT_ASKPASS` script; the CLIs read their own config (`references/token-auth.md` "Agent rules"). A step that seems to need the raw token needs another tool.
- **Maintained products only through `geectl maintenance maintenance-branch` + `geectl request file-maintenance-incident`** (or a `home:` branch + `geectl request file`) — never a commit, a direct write (copy-package, link-package, delete-package, a meta write) into a `*:Update` or maintenance project: `references/maintenance-updates.md` "Maintenance updates (Backports / Leap)".
- **Non-interactive forms only** — without a TTY a prompt hangs or takes its default:
  - every mutation is dry-run by default: `--live` performs it, so a mutation without `--live` changes nothing;
  - `geectl commit -m MSG`, never a bare `geectl commit` (it opens an editor);
  - filing supersedes every open request for the package from the same user, so check what is open first (`geectl request search --source-package PKG --state new --state review`); to supersede exactly one, file first, then `geectl request supersede OLD_ID NEW_ID --live`;
  - a long job runs in the background as `CMD </dev/null >LOG 2>&1 &`, so a prompt fails instead of waiting;
  - find a running build with `pgrep -f '[g]eectl local-build build'`: the brackets keep the pattern from matching the shell that runs it.

## Package and checkout

- `geectl remote create-package --title TITLE --description DESC PRJ PKG --live` — **creates a new package**; `--scmsync URL` creates it git-backed.
- `geectl remote create-project --title TITLE --description DESC PROJECT --live` — **creates a new project**; set its repositories and meta with `geectl remote set-project-meta --from-file`.
- `geectl remote set-package-meta --from-file meta.xml PRJ PKG --live` — replace a package's meta wholesale (write `meta.xml` first: `<package name="PKG" project="PRJ"><title/><description/></package>`, plus `<person>`/`<url>` as needed).
- `geectl remote package-meta PRJ PKG` — print a package's meta.
- `geectl remote project-meta PRJ` — print project meta (maintainers, reviewers, repositories).
- `geectl remote set-project-meta --from-file FILE PRJ --live` — write a project's meta.
- `geectl checkout PRJ PKG --live` — run from the working area; creates `PRJ/PKG/`. `--rev REV` (a revision number or a srcmd5) checks out that revision.
- `geectl update --live` — refresh a checkout before reusing it; `--rev REV` pins a revision.
- `geectl status` · `geectl diff` — what the commit will contain.
- `geectl add FILE... --live` / `geectl rm FILE... --live` / `geectl addremove --live` — track new, dropped, or both.
- `geectl commit -m MSG --live` — commit the checkout; `--noservice` skips the services it would run first, so a gated tree is committed as judged.
- `geectl changelog validate DIR` — validate the `.changes` entries (`--target-project PRJ --target-package PKG` adds the target-relative rules).
- `geectl changelog generate DIR` — emit the skeleton entry (`--write` prepends it; `--author AUTHOR` sets the author line, in `Name <email>` form); prefer `scripts/changes-prepend.sh`.
- `geectl branch branch-package --project PRJ --package PKG [--target-project TGT_PRJ [--target-package TGT_PKG]] --live` — branch into `home:<you>:branches:PRJ` (or TGT_PRJ).
- `geectl branch create --project PRJ --package PKG --live` — branch a git-backed package in one step: the Gitea fork plus the OBS fork into a test project with the source project's repositories. The first-build wait is opt-in (`--first-build-deadline-secs N`; 0 skips it).
- `geectl branch copy-package --source-project SRC_PRJ --source-package SRC_PKG --target-project DST_PRJ --target-package DST_PKG --live` — server-side copy; `--expand` copies a linked source expanded, `--keep-link` keeps a link a link.
- `geectl branch link-package --source-project SRC_PRJ --source-package SRC_PKG --target-project DST_PRJ --target-package DST_PKG --live` — rewrites the target's package meta: re-check its build flags after.
- `geectl branch repair-link --project PRJ --package PKG --live` — rebase a broken `_link`.
- `geectl pull --live` — merge upstream changes into a branched checkout (linked packages only, clean working copy).
- `geectl remote delete-package --message MSG PRJ PKG --live` — delete a package server-side; without `--force` geectl refuses first while an open request names it. OBS revokes every request (new, review, declined) whose source is deleted.
- `geectl remote delete-project --comment MSG --recursive PRJ --live` — delete a whole project and its packages.
- `geectl remote delete-link PRJ PKG --live` — delete only the `_link` file: the package keeps its files and stops tracking the source.
- `geectl gitea repo-fork OWNER REPO --live` — Gitea fork of an scmsync package; see `references/git-workflow.md`.
- `geectl remote cat PRJ PKG FILE [--rev REV]` — print one remote file without checking anything out; `--rev` takes a revision number or a srcmd5.
- `geectl remote download PRJ PKG FILE --output PATH` — download one remote file (the binary counterpart of `cat`).
- `geectl remote link-target PRJ PKG` — the link target of a package, when it is a link.
- `geectl remote list-packages PRJ` · `geectl remote list-files PRJ PKG [--rev REV]` · `geectl remote package-log PRJ PKG [--limit N]` — remote file list · files of a package · commit history.
- `geectl remote diff-packages OLD_PRJ OLD_PKG NEW_PRJ NEW_PKG` · `geectl remote project-diff OLD_PRJ NEW_PRJ` — diff two remote packages · two projects.
- `geectl remote update-package-meta-from-spec PRJ PKG --live` — copy the spec's URL/summary/description into the package meta.

## Build

- `geectl local-build build --project PRJ --repo REPO --arch ARCH DIR --live` — local build; `DIR` is the source directory (spec + sources), `REPO` a repository of the checkout's project (`geectl build list-repositories PRJ`), `ARCH` the host's. Flags used here: `--clean`, `--flavor FLAVOR` (multibuild), `--release N`, `--trust-all-projects`, `--alternative-project PRJ`, `--root ROOT` (a build root of its own instead of the shared one; `scripts/target-gate.sh` uses one per package and base), `--noinit`, `--keep-rpms DIR` (keep RPMs), `--prefer-packages DIR` (prefer packages). Never bind-mount host paths into the root. For a Leap pool PR, `scripts/target-gate.sh --build` runs this build — never hand-run it as the proof.
- `geectl local-build chroot --project PRJ --repo REPO --arch ARCH DIR` — enter the preserved build root of the last build; pipe repro commands in on stdin.
- `geectl local-build wipe REPO ARCH SPEC --live` — delete that build root after unmounting mounts under it; the root must be named by the build's own options (`--root`, `--flavor`).
- `geectl local-build log --project PRJ REPO ARCH SPEC` — log of the last local build; `--project` names the OBS project, `REPO`/`ARCH`/`SPEC` the build's coordinates.
- `geectl build buildinfo PRJ PKG REPO ARCH` — the resolved build deps, without building (`--alternative-project PRJ` builds the dep set against another project).
- `geectl build buildconfig PRJ REPO` — the build configuration.
- `geectl build list-repositories PRJ` — repository/arch pairs a project builds.
- `geectl build results PRJ --package PKG` — remote status; `--repository REPO`, `--arch ARCH`, `--code CODE`, `--lastbuild`, `--oldstate` scope it.
- `geectl build wait-for-results --deadline-secs N PRJ --package PKG` — wait for the build to settle.
- `geectl build build-log PRJ PKG REPO ARCH` — remote build log; `--lastsucceeded` shows the last green one, `--start -N` the tail.
- `geectl build list-binaries PRJ REPO ARCH --package PKG` — list remote build results.
- `geectl build download-binary --output PATH PRJ PKG REPO ARCH FILE` — download one built file.
- `geectl build download-binary --all --output DIR PRJ PKG REPO ARCH` — download every listed binary into the directory.
- `geectl build whatdependson PRJ PKG REPO ARCH` — reverse build deps (`scripts/rdeps.sh` wraps it).
- `geectl local-build service-run --service source_validator DIR --live` — the validator gate. `--mode manualrun` runs the `mode="manual"` services; `--mode precommit` the precommit gate. `--mode runall` is refused (no such mode).
- `geectl local-build precommit DIR --live` — run the precommit gate directly.
- `geectl remote create-token --operation OP --project PRJ --package PKG --live` — a trigger token (e.g. for Gitea PR builds). The maintainer runs it: it prints the token's secret, so an agent never does, and the harness snippets refuse a `geectl remote create-token` call — except that a global option before the subcommand (`geectl --live remote create-token`) gets past the Codex and Antigravity prefixes (see `contrib/harness/README.md` "Limits").

## Requests

- `geectl request file --source-project SRC_PRJ --source-package SRC_PKG --target-project DST_PRJ --target-package DST_PKG --description DESC --changes-entry ENTRY --live` — file a submit request; `--description "$(cat FILE)"` / `--changes-entry "$(cat FILE)"` for shell safety (quotes, `$` and backticks in the text), with FILE written in an earlier call: the pr-guard hook will read it and hold it to one headline of ≤160 characters of prose with no work notes (`references/request-text.md` "SR and PR messages"); `--cve CVE` for each CVE the entry names; from a `home:<you>:<sub>` branch never pass `--without-cleanup` (cleanup is the default: OBS deletes the branch on accept; pr-guard will refuse the SR with it). A forward from a devel project passes `--without-cleanup` — the source is a package that must keep existing. Never file from a devel project except the manual forward on `forward-check.py` DUE (`references/submit-watch.md` "Filing an SR"). Filing supersedes every open request for the package from the same user — see "Tool discipline" above.
- `geectl request refile --source-project SRC_PRJ --source-package SRC_PKG --target-project DST_PRJ --target-package DST_PKG --description DESC --changes-entry ENTRY --supersede ID --live` — file and supersede the named request with it.
- `geectl request refile-maintenance-incident --source-project SRC_PRJ --source-package SRC_PKG --target-project TGT_PRJ --description DESC --supersede ID --live` — file a maintenance incident request and supersede the named request with it.
- `geectl request supersede OLD_ID NEW_ID --live` — supersede exactly one request with another existing one.
- `geectl request file-change-devel --source-project PRJ --source-package PKG --target-project DEVEL_PRJ --target-package DEVEL_PKG --description MSG --live` — change a package's devel project.
- `geectl request file-delete --target-project PRJ [--package PKG] --description MSG --live` — request deletion.
- `geectl request file-maintenance-incident --source-project SRC_PRJ --source-package PKG --target-project TGT_PRJ --release-project REL_PRJ --description MSG --live` — maintenance incident request.
- `geectl maintenance maintained-instances --package PKG` — lists the maintained products carrying the package, branches nothing.
- `geectl maintenance maintenance-branch --package PKG [--target-project TGT_PRJ] --live` — branch every maintained product's copy of the package.
- `geectl request search --creator USER --state new --state review --type submit [--project PRJ] [--package PKG]` — list requests; `--request-id ID`, `--source-project PRJ`, `--target-project PRJ`, `--since DATE`, `--limit N`, `--reviewer USER` narrow it. With no `--state` only new, review and declined requests are listed.
- `geectl request show ID` · `geectl request log ID` · `geectl request diff ID [--xml]` — one request · its history · its diff.
- `geectl request list-comments ID` — a request's comments.
- `geectl request add-comment --body TEXT [--parent COMMENT_ID] ID --live` — post one, `--parent` as a reply in that thread; `--body "$(cat FILE)"` for the same shell safety as `--description` (`references/request-text.md` "Answering a reviewer").
- `geectl request accept --comment MSG ID --live` · `geectl request decline --comment MSG ID --live` · `geectl request revoke --comment MSG ID --live` — act on a request (accept/decline only on your own, or with the user's explicit go). Accepting forwards to the request's link parent by default (`--no-forward` skips it; `-m`/`--forward-message ENTRY` overrides the forwarded `.changes` entry, else it stays the original description); a refused forward is reported and the accept stands, with the work staying queued in the devel project. Accept cleans up: the branch package is deleted, and its test project with it when empty.
- `geectl pull-request merge REFERENCE --live` · `geectl pull-request decline REFERENCE --live` · `geectl pull-request withdraw REFERENCE --live` — act on a submission through the unified surface: an OBS submit request or a Gitea pull request, named by `obs:<id>` or `gitea:<owner>/<repo>#<number>`. Merge accepts (OBS) or merges (Gitea) and forwards to the link parent by default (`--no-forward` skips it; `-m`/`--forward-message ENTRY` overrides the forwarded `.changes` entry); on OBS a refused forward is reported and the accept stands, on Gitea the forward is resolved and validated before the merge lands. After the merge the branch home is cleaned up like the OBS arm's; merges done outside geectl are left for `gitea cleanup-forks`. Decline declines (OBS) or closes (Gitea); withdraw revokes (OBS) or closes (Gitea).
- `geectl pull-request approve REFERENCE --live` — approve a submission as the review asked of the target (OBS: the acting user's review; Gitea: the token owner's review).
- `geectl pull-request submit --base main --title TITLE --body BODY` — file a submission from the working copy in the current directory: a Gitea pull request from a git-backed checkout, an OBS submit request from an OBS-native one; `--repo`/`--head` name the Gitea repo and branch, `--draft` opens it as a draft.
- `geectl pull-request build-comment --project PRJ --package PKG gitea:OWNER/REPO#N --live` — post the build-link comment on a Gitea PR: the OBS build results for the test project and package, as a link plus a one-line per-instance summary. Posted once, on PR opening; no polling, no live update, no edit. An OBS handle is refused.
- `geectl pull-request show REFERENCE` — show one pull request: metadata only (title, state, reviews, the head in `source.commit`), no diff — the diff gap is geectl #416.
- `geectl pull-request comments REFERENCE` — list a pull request's comments, oldest first.
- `geectl pull-request comment --body BODY REFERENCE --live` — comment on a pull request.
- `geectl pull-request request-changes REFERENCE --live` — ask for changes on a pull request, as `approve` but with the review declined instead of accepted.
- `geectl pull-request search --backend BACKEND --repo REPO --state STATE` — search pull requests: OBS submit requests and Gitea pull requests as one list; `--creator` narrows it to one author.
- `geectl request change-review-state ID STATE --live` — change one review's state (`new`/`accepted`/`declined`); `--user`/`--group`/`--project`/`--package` address the review, `--comment` the message.
- `geectl request change-state ID STATE --live` — change a request's state (`new`/`review`/`accepted`/`declined`/`revoked`).
- `geectl request add-review --user USER --comment MSG ID --live` — ask a user to review a request (`--group`, `--project`, `--package` address the other review forms).

## Lookup

- `geectl remote devel-project PKG [--target-project PRJ]` — the registered devel project.
- `geectl remote maintainers PRJ PKG` — maintainers of a package.
- `geectl gitea maintainers OWNER REPO` — maintainers from the git side: the project maintainers and the per-package maintainers in the repo's `_maintainership.json`, read from the repo's default branch.
- `geectl gitea cleanup-forks --live` — list obsolete Gitea forks and their OBS home test projects, and delete them. A project is deleted only when its description marker names a fork that no longer exists on Gitea; dry-run is the default.
- `geectl remote owners PRJ PKG` — owners of a package (project/package scope); bugowners included, not the maintainer set.
- `geectl remote owners-for-binary BINARY` — owners of the source package shipping that binary.
- `geectl remote project-meta PRJ` — a project's persons (maintainers, reviewers).
- `geectl remote search-packages-by-person USER` — the packages a user maintains.
- `geectl remote search-projects-by-person USERID` — the projects whose meta names the login in a role.
- `geectl remote set-package-meta --add-person USER:maintainer PRJ PKG --live` — adds USER's `maintainer` role to PKG's `_meta` (write access to it needed). `--remove-person USER` removes a person. `geectl remote search-packages-by-person USER` lists what a user maintains.
- `geectl remote staging-project PRJ NAME` — one staging project of a workflow project: its staged, untracked and obsolete requests and its overall state (both included by default; `--no-requests` / `--no-status` leave them out).
- `geectl remote whois LOGIN` — account name and email.
- `geectl remote search-packages TERM` · `geectl remote search-projects TERM` — find packages/projects; `--exact` matches names only.
- `geectl remote search-packages --devel-project PRJ` — the packages a devel project develops.

## Config

- `geectl config show` — endpoint URLs with their source, and credential status (never a secret value).
- `geectl config init` — write the config template (endpoints only); refuses if the file already exists.
- `geectl config import-oscrc --live` — one-time migration from an oscrc file: reads it once, on explicit request, and writes only the alias→apiurl mapping into the config `[instances]` table. The password is never stored or printed (set it with the printed `GEECTL_OBS_PASSWORD_<ALIAS>` variable yourself); dry-run is the default.

## Wrong forms

Each was actually run by an agent, and each failed or did damage. The correct form is in the section above.

- Running `geectl checkout PRJ PKG` from `/tmp` instead of the working area — the build, the gates and the commit all run from the checkout, and a throwaway location loses them → run it from the area.
- `geectl local-build service-run --mode runall` — no such mode → name the service and its mode.
- `geectl local-build build …` in a devel checkout, offered as proof for a Leap pool PR — another tree, built against another project than the PR bot's → `scripts/target-gate.sh <pool clone> --build`.
- `geectl request show ID` expecting the diff — there is no diff flag on `show` → `geectl request diff ID`.
