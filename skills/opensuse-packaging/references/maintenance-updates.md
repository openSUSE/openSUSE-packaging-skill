# Maintenance updates for released products

Owner of the maintenance-update route. The Leap 16.x / SLFO / SLE-15 routing decision itself is
`references/leap-slfo.md`.

## Maintenance updates (Backports / Leap)

**HARD RULE — never write into a maintained product.** No checkout-and-commit, `osc copypac` or `osc api -X POST`/`PUT` in a `*:Update` project outside your `home:`, `openSUSE:Maintenance*` or an incident — not even a "probe" to see whether you may: a write that succeeds lands in a released product. The only route is `osc mbranch` + `osc mr` below (without incident rights, `osc branch` + `osc sr`: `references/leap-slfo.md` "6. `openSUSE:Backports:SLE-15-SPx` maintenance updates").

A change that already landed in the devel project (and is in flight to Factory) does **not** automatically reach released distributions — Leap, Package Hub, etc. Those are maintained separately and require a *maintenance request* (MR), which is a different workflow from `osc sr`. The typical sequence:

1. **`osc maintained <pkg>`** — discovers which maintained products carry the package today. Output is one `<project>/<package>` line per instance, e.g. `openSUSE:Backports:SLE-15-SP7:Update/fwts`. If the output is empty, there's nothing to update — the package isn't in a released distribution. Always run this first; assumptions about "is this in Leap?" are unreliable.

2. **`osc mbranch <pkg>`** — branches every maintained instance into `home:<you>:branches:OBS_Maintained:<pkg>/<pkg>.<product>`. Errors with `branch target package already exists` if you (or a previous session) already branched it; that's fine, reuse the existing branch — don't `osc rdelete` it just to recreate, you'll lose any in-flight edits there.

3. **Bring the fix into the maintenance branch.** Two equally valid paths:
   - Check it out (`osc co home:<you>:branches:OBS_Maintained:<pkg> <pkg>.<product>`) and redo the spec/changes edits in place. Fine when the maintenance distro needs a *different* fix from the devel one (older toolchain, missing dep, etc.).
   - **`osc copypac -e -K <devel_project> <devel_package> <branch_project> <branch_package>`** — bulk-copies the sources straight from the devel project, no checkout needed. `-K` keeps the link relationship so the branch stays a maintenance branch (not a fork); `-e` expands link sources before copying so what lands is the fully-resolved files, not a link reference. Best when the released distro should get the *same* fix that just went to devel. The OBS commit message records `revision:NN, using keep-link, using expand` so the audit trail is clear.

4. **`osc maintenancerequest <branch_project> <branch_package> <release_project> -m "..."`** (alias `osc mr`) — files the actual MR. The release project is the maintained product, **not** `openSUSE:Maintenance` — `osc mr` rewrites internally to target `openSUSE:Maintenance` and prints `Using target project 'openSUSE:Maintenance'. (release in 'openSUSE:Backports:SLE-15-SP7:Update')` to confirm. Result is a numeric request ID printed on the last line.

Gotchas observed in practice:

- **`osc maintenancerequest` has no `--yes` flag — and never pipe `echo y |` into it.** With `-m` given it asks two things: from a checkout with uncommitted changes (`osc mr .`), whether to go on without them; and, when incident requests from the same branch are open, the all-or-nothing supersede question, where `y` supersedes every one of them. Commit first, name the one request you replace with `-s <id>`, and run it `</dev/null`, so an unexpected question aborts. The `-m` message follows the `osc sr` rule: 1–3 sentences (`references/submit-watch.md` "Filing an SR").
- **Wiki says bug references are mandatory for Backports — they aren't.** `openSUSE:Backports_Package_Submission_Process` lists "A bug entry in bugzilla, referenced in the submission" as a requirement for Package Hub 15 submissions. That item is **outdated**; current Backports policy does not enforce a bugzilla reference. The rest of that wiki page (factory-source must accept, must already be in Factory or a maintained Leap, must respect Leap maintenance policy) is still valid.
- **Branch vrev tells you whether someone's already worked on it.** `osc cat <branch_project> <branch_package> fwts.spec` reveals the in-branch version. If it's older than the devel-project version, the branch is stale and you need step 3 above. If it already matches, you can skip straight to step 4.
