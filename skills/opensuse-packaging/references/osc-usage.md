# osc usage — the exact invocations this workflow uses

Call osc exactly as below: don't guess a form and don't run `osc <cmd> --help`. CI checks every `osc` citation in this skill against osc's own parser (verified with osc 1.27.3): the subcommand exists, every cited option is accepted, and each subcommand the skill uses has a line here. Positionals are not machine-checked, so copy them as written. `PRJ`/`PKG` are OBS project/package names; one line per subcommand, aliases in the line.

**Where checkouts live:** one osc working area, with projects as subdirectories (`<area>/<prj>/<pkg>`). Run `osc co` from the area itself, never from inside a `<prj>/` checkout (that nests one), and never check out into `/tmp` or a scratchpad — the build, the gates and the commit all run from the checkout, and a throwaway location loses them. → `references/update-build.md` "Avoid full-project checkouts"

## Tool discipline

**HARD RULE — every service through its own client.** A hand-rolled HTTP call skips the client's auth and error handling and every check this skill documents.

- **OBS: `osc`** — a subcommand from this page, else `osc api PATH` (it returns XML, not JSON). Never curl, wget or urllib `api.opensuse.org` or `build.opensuse.org`.
- **src.opensuse.org: the bundled scripts, `tea` or `git-obs`**, and `git-obs -G src.opensuse.org api` when none of them fits — never curl or urllib its API, and never `tea api` for a lookup: it exits 0 on an HTTP 404. Name the forge on every call — `git-obs -G src.opensuse.org`, `tea … --login <login>` — or the tool takes its default login, possibly another forge's, and that forge's 404 reads as "not there". Push over SSH. Forms: `references/git-workflow.md` "Gitea CLI — tea 0.15.1 cheat sheet".
- **Credentials stay inside the tools.** Never read an `oscrc`, `~/.config/osc/`, osc's cookie jar (`~/.local/state/osc/cookiejar`), `~/.config/tea/config.yml` or an API-key file, and never put a token in a URL, a header or argv — no `Authorization:` header, no `GIT_ASKPASS` script; the CLIs read their own config (`references/token-auth.md` "Agent rules"). A step that seems to need the raw token needs another tool.
- **Maintained products only through `osc mbranch` + `osc mr`** (or a `home:` branch + `osc sr`) — never a commit, an `osc api` write or another direct write (copypac, linkpac, aggregatepac, rdelete, undelete, a meta `-F`/`-e`) into a `*:Update` or maintenance project: `references/maintenance-updates.md` "Maintenance updates (Backports / Leap)".
- **Non-interactive forms only** — without a TTY a prompt hangs or takes its default:
  - `osc ci -m MSG`, never a bare `osc ci` (it opens an editor);
  - `osc sr … -s ID` names the one request to supersede; never `--yes`, which supersedes every open request from the same source, other people's included (`references/submit-watch.md` "Triaging your declined submit requests");
  - a long job runs in the background as `CMD </dev/null >LOG 2>&1 &`, so a prompt fails instead of waiting;
  - find a running build with `pgrep -f '[o]sc build'`: the brackets keep the pattern from matching the shell that runs it.

## Package and checkout

- `osc meta pkg PRJ PKG -F meta.xml` — **creates a new package** (or replaces its meta); write `meta.xml` first (`<package name="PKG" project="PRJ"><title/><description/></package>`, plus `<person>`/`<url>` as needed). `osc meta pkg PRJ PKG` alone prints it. `-e` opens an editor: interactive only.
- `osc meta prj PRJ` — print project meta (maintainers, reviewers, repositories); `-F FILE` writes it.
- `osc co PRJ PKG` (checkout) — run from the working area; creates `PRJ/PKG/`.
- `osc up` (update) — refresh a checkout before reusing it.
- `osc repairwc DIR` — only when osc asks for it; a fresh `osc co` is often faster.
- `osc add FILE...` / `osc rm FILE...` (delete) / `osc addremove` (ar) — track new, dropped, or both.
- `osc status` (st) · `osc diff` (di; `osc diff --link` = linkdiff) — what the commit will contain.
- `osc commit -m MSG` (ci) — commit the checkout; `-F FILE` takes the message from a file.
- `osc vc -m MSG` — `.changes` entry in the osc format; prefer `scripts/changes-prepend.sh`.
- `osc mkpac PKG` — **only inside a checked-out project** (`cd PRJ` first); takes ONE argument. For a new package in a project you don't have checked out, use `osc meta pkg` above.
- `osc branch PRJ PKG [TGT_PRJ [TGT_PKG]]` — branch into `home:<you>:branches:PRJ` (or TGT_PRJ).
- `osc copypac SRC_PRJ SRC_PKG DST_PRJ [DST_PKG]` — server-side copy; `-e` copies a linked source expanded, `-K` keeps a link a link.
- `osc linkpac PRJ PKG TGT_PRJ [TGT_PKG]` — rewrites the target's package meta: re-check its build flags after.
- `osc repairlink PRJ PKG` — rebase a broken `_link`.
- `osc pull` — merge upstream changes into a branched checkout.
- `osc rdelete -m MSG PRJ PKG` — delete a package server-side; for a whole project `-r` deletes its packages too and `-f` deletes even when others depend on it.
- `osc fork` — Gitea fork of an scmsync package; see `references/git-workflow.md`.
- `osc cat PRJ PKG FILE` — print one remote file without checking anything out.
- `osc ls PRJ [PKG]` (list) · `osc log PRJ [PKG]` — remote file list · commit history.
- `osc rdiff OLD_PRJ OLD_PKG NEW_PRJ [NEW_PKG]` — diff two remote packages.
- `osc updatepacmetafromspec` — copy the spec's URL/summary/description into the package meta.

## Build

- `osc build [--alternative-project PRJ] REPO ARCH PKG.spec` — local build; `REPO` is a repository of the checkout's project (`osc repos PRJ`), `ARCH` the host's. Flags used here: `--clean`, `-k DIR` (keep RPMs), `-p DIR` (prefer packages), `--trust-all-projects`, `-M FLAVOR` (multibuild), `--noinit`, `--release N`, `--root ROOT` (a build root of its own instead of the oscrc one; `scripts/target-gate.sh` uses one per package and base). Never bind-mount host paths into the root. For a Leap pool PR, `scripts/target-gate.sh --build` runs this build — never hand-run it as the proof.
- `osc chroot [--alternative-project PRJ] REPO ARCH PKG.spec` (build alias) — enter the preserved build root of the last build; `--shell-cmd CMD` runs one command.
- `osc wipe --force [--alternative-project PRJ] REPO ARCH PKG.spec` (build alias) — delete that build root after unmounting every mount whose path starts with the root's (a sibling root `<root>-…` included); `--force` skips the confirmation, and the root must be named by the build's own options (`--root`, `-M`).
- `osc buildinfo [--alternative-project PRJ] REPO ARCH PKG.spec` — the resolved build deps, without building.
- `osc lbl` (localbuildlog) — log of the last local build.
- `osc repos [PRJ [PKG]]` (repositories) — repository/arch pairs a project builds.
- `osc results PRJ [PKG]` (r) — remote status; `-r REPO`, `-a ARCH`, `-w` waits, `--verbose` adds details, `--xml` for a script to parse.
- `osc rbl PRJ PKG REPO ARCH` (buildlog) — remote build log (`blt`/`buildlogtail` print only its tail); `--lastsucceeded` shows the last green one.
- `osc getbinaries PRJ PKG REPO ARCH` — download remote build results.
- `osc whatdependson PRJ PKG REPO ARCH` — reverse build deps (`scripts/rdeps.sh` wraps it).
- `osc service run source_validator` — the validator gate. `osc service manualrun` (mr) runs the `mode="manual"` services; `osc service run NAME` one service. Never `runall` (it also fires `buildtime` services).
- `osc token --create --operation OP PRJ PKG` — a trigger token (e.g. for Gitea PR builds). The maintainer runs it: it prints the token's secret, so an agent never does, and the harness snippets refuse every `osc token` call.

## Requests

- `osc sr SRC_PRJ SRC_PKG DST_PRJ [DST_PKG] -m MSG` (submitrequest) — file a submit request; `-m "$(cat FILE)"` for shell safety (quotes, `$` and backticks in the text), with FILE written in an earlier call: the pr-guard hook reads it and holds its prose to the 300-character cap (`references/submit-watch.md` "Filing an SR"); `-s ID` / `--supersede ID` replaces exactly that one; never `--yes` ("Tool discipline" above). From a checkout, `osc sr DST_PRJ -m MSG`.
- `osc creq -a change_devel PRJ PKG DEVEL_PRJ [DEVEL_PKG] -m MSG` (createrequest) · `osc changedevelrequest PRJ PKG DEVEL_PRJ -m MSG` — change a package's devel project.
- `osc deletereq PRJ PKG -m MSG` (deleterequest) — request deletion.
- `osc mr [SRC_PRJ [PKGS RELEASE_PRJ]] -m MSG` (maintenancerequest) — maintenance incident request; `-s ID` supersedes exactly that one.
- `osc maintained PKG` (sm) — dry run: lists the maintained products carrying the package, branches nothing.
- `osc mbranch PKG` — branch every maintained product's copy of the package.
- `osc rq list -U USER -s new,review -t submit [PRJ [PKG]]` (request) — list requests.
- `osc rq show ID` (`-d` adds the diff) · `osc rq log ID` — one request · its history.
- `osc rq accept -m MSG ID` · `osc rq decline -m MSG ID` · `osc rq revoke -m MSG ID` — act on a request (accept/decline only on your own, or with the user's explicit go). Accepting does not forward: after a devel accept, file the onward `osc sr` yourself.

## Lookup

- `osc develproject PRJ PKG` (dp) — the registered devel project.
- `osc maintainer PRJ PKG` — maintainers of a package (`osc maintainer PRJ` for a project); `-U USER` lists what a user maintains. Not `osc bugowner`: that alias lists bugowners only.
- `osc whois USER` (user) — account name and email.
- `osc search TERM` (se) — find packages/projects; `osc search --package TERM` matches package names only.
- `osc api PATH` — a read-only GET for what no subcommand covers (search, `/request?view=collection`). Not a workaround for a failing subcommand: find its right form here.

## Wrong forms

Each was actually run by an agent, and each failed or did damage. The correct form is in the section above.

- `osc mkpac devel:tools graphifyy` — mkpac takes one argument and only inside a project checkout → `osc meta pkg PRJ PKG -F meta.xml`, then `osc co PRJ PKG`.
- `osc api -X PUT -T meta.xml /source/PRJ/PKG/_meta` — hand-written meta PUT → `osc meta pkg PRJ PKG -F meta.xml`.
- `osc co -c PRJ PKG -o /tmp/x` — checkout outside the working area → `osc co PRJ PKG` from the area.
- `osc service runall` — mode-blind, also runs `buildtime` services on the host → name the service.
- `osc rq accept` expecting a forward — there is no forward option; accept, then `osc sr` the next hop.
- `osc build 16.0 aarch64 <pkg>.spec` in a devel checkout (its project's `16.0` repository), offered as proof for a Leap pool PR — another tree, built against another project than the PR bot's → `scripts/target-gate.sh <pool clone> --build`.
