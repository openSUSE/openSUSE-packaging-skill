# Maintenance updates for released products

Owner of the maintenance-update route. The Leap 16.x / SLFO / SLE-15 routing decision itself is
`references/leap-slfo.md`.

## Maintenance updates (Backports / Leap)

**HARD RULE — never write into a maintained product.** No checkout-and-commit, `geectl branch copy-package` or a direct write in a `*:Update` project outside your `home:`, `openSUSE:Maintenance*` or an incident — not even a "probe" to see whether you may: a write that succeeds lands in a released product. The only route is `geectl maintenance maintenance-branch` + `geectl request file-maintenance-incident` below (without incident rights, `geectl branch branch-package` + a maintenance-incident request: `references/leap-slfo.md` "6. `openSUSE:Backports:SLE-15-SPx` maintenance updates").

A change that already landed in the devel project (and is in flight to Factory) does **not** automatically reach released distributions — Leap, Package Hub, etc. Those are maintained separately and require a *maintenance request* (MR), which is a different workflow from a submit request. The typical sequence:

1. **`geectl maintenance maintained-instances --package <pkg>`** — discovers which maintained products carry the package today. Output is one `<project>/<package>` line per instance, e.g. `openSUSE:Backports:SLE-15-SP7:Update/fwts`. If the output is empty, there's nothing to update — the package isn't in a released distribution. Always run this first; assumptions about "is this in Leap?" are unreliable.

2. **`geectl maintenance maintenance-branch --package <pkg>`** — branches every maintained instance into `home:<you>:branches:OBS_Maintained:<pkg>/<pkg>.<product>`. Errors with `branch target package already exists` if you (or a previous session) already branched it; that's fine, reuse the existing branch — don't delete it just to recreate, you'll lose any in-flight edits there.

3. **Bring the fix into the maintenance branch.** Two equally valid paths:
   - Check it out (`geectl checkout home:<you>:branches:OBS_Maintained:<pkg> <pkg>.<product> --live`) and redo the spec/changes edits in place. Fine when the maintenance distro needs a *different* fix from the devel one (older toolchain, missing dep, etc.).
   - **`geectl branch copy-package --source-project <devel_project> --source-package <devel_package> --target-project <branch_project> --target-package <branch_package> --expand --keep-link --live`** — bulk-copies the sources straight from the devel project, no checkout needed. `--keep-link` keeps the link relationship so the branch stays a maintenance branch (not a fork); `--expand` expands link sources before copying so what lands is the fully-resolved files, not a link reference. Best when the released distro should get the *same* fix that just went to devel.

4. **`geectl request file-maintenance-incident --source-project <branch_project> --source-package <branch_package> --target-project openSUSE:Maintenance --release-project <release_project> --description "..." --live`** — files the actual MR. The release project is the maintained product, **not** `openSUSE:Maintenance`: `--target-project` is `openSUSE:Maintenance`, `--release-project` is the maintained product. Result is a numeric request ID printed on the last line.

Gotchas observed in practice:

- **`geectl request file-maintenance-incident` never prompts — and never pipe `echo y |` into it.** Commit first, name the one request you replace by superseding it after filing (`geectl request supersede OLD_ID NEW_ID --live`, or `geectl request refile-maintenance-incident … --supersede <id> --live`), and run it `</dev/null`, so an unexpected question aborts. The `--description` follows the request-text rule: 1–3 sentences (`references/submit-watch.md` "Filing an SR").
- **Wiki says bug references are mandatory for Backports — they aren't.** `openSUSE:Backports_Package_Submission_Process` lists "A bug entry in bugzilla, referenced in the submission" as a requirement for Package Hub 15 submissions. That item is **outdated**; current Backports policy does not enforce a bugzilla reference. The rest of that wiki page (factory-source must accept, must already be in Factory or a maintained Leap, must respect Leap maintenance policy) is still valid.
- **Branch vrev tells you whether someone's already worked on it.** `geectl remote cat <branch_project> <branch_package> fwts.spec` reveals the in-branch version. If it's older than the devel-project version, the branch is stale and you need step 3 above. If it already matches, you can skip straight to step 4.
