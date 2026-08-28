# Quilt: local patch mechanics

Creating/editing/rebasing patch files on disk with `quilt`, plus a CVE-backport
recipe. Covers *producing the diff* only — spec-side conventions (tags,
categories, upstream-reference, `.changes`) are `references/specfile-guidelines.md`
"Patches"; apply both.

Quilt works on the spec+patch files in the checkout, not the VCS — same
mechanics for a classic `osc co` or a git clone (`references/git-workflow.md`).

**HARD RULE — check `command -v quilt` before using anything here; never
assume it's installed** (not in a base openSUSE install). If missing:
- Offer to install (`sudo zypper install quilt`) — get explicit confirmation
  first, like any other system-affecting command.
- Otherwise fall back to the manual diff-tool method in
  `references/specfile-guidelines.md` "Patches" (pre-edit tree in `a/`, edited
  copy in `b/`, `diff -u a/<path> b/<path>`) — slower, but produces an
  equivalent `a/`/`b/`-prefixed patch, so every rule below still applies to
  its output.

## Extracting & preparing sources

`quilt setup -v <package>.spec` extracts sources into
`<package>-<version>-build/` and rebuilds the `series` index from existing
`PatchN:` tags. Safe to rerun (extraction only) — if the build dir gets
confusing, `rm -rf` and rerun rather than hand-repairing it.

## Applying & editing patches

Work inside `<package>-<version>-build/<package>-<version>`, `quilt push -a`
first. Mandatory sequence per edit:

1. **Check state** — `quilt top`/`quilt applied` — before touching anything.
2. **New patch** — `quilt new <name>.patch` — *before* editing any file;
   earlier edits aren't tracked into it.
3. **Add files** — `quilt add <file>` before editing each one. Skipped
   silently: no error, just an empty/incomplete patch on refresh.
4. **Commit** — `quilt refresh` right after each edit; don't batch sessions —
   small diffs catch mistakes.

**Header standard.** `a/`/`b/` prefixes (quilt's default) for `%autosetup -p1`
compatibility — never hand-edit to `-p0` form; failure modes:
`references/specfile-guidelines.md` "Patches".

**Inspect without breaking the series.** `quilt pop`/`quilt push` to view the
base or an intermediate state — never hand-edit to simulate a pop, it desyncs
quilt's bookkeeping and causes confusing conflicts later.

## CVE patch backporting (quilt + spec)

Backporting published CVE fixes into an old lineage missing them — the
classic-osc/maintenance flow, once `references/leap-slfo.md` §6 has decided
**backport** over bump.

1. **Fetch each fix as a raw diff from its own upstream URL** —
   `curl -sL -o <file> <url>.patch`. Real upstream reference only (provenance
   rule: `SKILL.md` / `references/untrusted-content.md`) — never an unverified
   CVE-tracker/bug-comment link. No browser-rendering tool — it can corrupt
   whitespace/line-endings.
2. **Rename** to `fix-CVE-XXXX-YYYYY.patch`, one file per CVE — keeps the
   `.changes` exact-filename rule (`references/specfile-guidelines.md`
   "Patches") unambiguous.
3. **WIP-commit new patch files only** — stage individually, never
   `git add -A`/`-u` (or equivalent): don't sweep in unrelated pre-existing
   changes (e.g. an LFS tarball mid-update).
4. **Add `PatchN:` lines** after existing patches, ascending by CVE number —
   don't interleave.
5. **Test one at a time**, ascending:
   - `quilt setup -v <pkg>.spec` — regenerate build dir + series. Safe to
     rerun.
   - `quilt push` the next patch.
   - Clean apply, or offset-only success → `quilt refresh`, continue.
   - Reject / `does not apply` / `can't find file to patch` → **don't
     hand-fix it.** Comment out that `PatchN:` line, `rm -rf` the build dir,
     `quilt setup`, restart from the top of the series (real fix: step 8).
6. **Clean up**: delete the build dir and the `*.patch~` backups `quilt
   refresh` leaves — don't commit them.
7. **No `.changes` entry unless asked** — that's a separate, explicit step
   (`references/specfile-guidelines.md` "Changelog").
8. **Report CVEs left commented out** as needing a manual rebase — but first
   confirm the vulnerable code is even present at the packaged version
   (`references/leap-slfo.md` §6): a reject often means "already
   fixed/absent", not "needs rebase" (hunk-by-hunk procedure:
   `references/specfile-guidelines.md` "Patches", "When a distro patch stops
   applying after a version bump").
