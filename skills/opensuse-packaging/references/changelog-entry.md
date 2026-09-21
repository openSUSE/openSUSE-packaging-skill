# Adding a `.changes` entry — the mechanics

Owner of: the entry template, the prepend-is-an-insertion HARD RULE, and the
`changes-prepend.sh` / `changes-lint.sh` / `changes-guard.sh --amend-top` mechanics.

The *format and content* rules — bullet levels (`-`/`*`, no third level), thematic grouping, the
condense-auto-generated-changelog drop/keep list, the no-URL rule, patch naming, CVE ids (with the
preferred security-bullet layout — `- CVE-XXXX-NNNN: <component + impact> (bsc#NNNNNN)` with the
fixing patch as a `*` sub-bullet), the umbrella-bullet norm, the SR-must-carry-an-entry rule, and
the never-edit-old-entries rule with its narrow exceptions — live in
`references/changelog-rules.md` "Changelog (`*.changes`)".

The canonical command is `osc vc`, which opens an editor with a fresh template. Since that is
interactive, when working from this skill **write the entry directly** to `<name>.changes` using
the mechanics below.

## The entry template

```
-------------------------------------------------------------------
<Wed May 27 16:31:48 UTC 2026> - Full Name <you@example.com>

- Short one-line summary of what changed (≤67 cols):
  * second-level detail
  * second-level detail
- Another top-level change, if independent

```
(Note the blank line at the end, before the previous entry's separator.)

**The inserted block MUST end with a blank line** — `separator` + `header` + blank + bullets +
**blank** — so that the next (older) separator is preceded by one. A hand-written entry drops that
final blank line almost every time, and reviewers act on it (real case: python-cyclopts 4.22.4,
SR 1369130 — superseded by the reviewer purely to add the newline; the same defect was then found
in three more in-flight SRs from the same day).

## Timestamp — always `LC_ALL=C`

```
LC_ALL=C date -u "+%a %b %_d %T UTC %Y"
```

Force `LC_ALL=C` — the locale-default weekday/month names will mismatch the canonical format and
reviewers will reject the entry. (`%_d` is the space-padded day: `Thu Jul  9`, never `Jul 09`.)

## Author line — HARD RULE: always the full `Full Name <email>` form

The header line is `<date> - Full Name <email>` (e.g. `Jane Packager <jane@example.com>`), never a
bare email. Use the packager's own name/email — the one already used in the file's existing
entries, or known from session context. If a source service (`changesgenerate`) stamps the entry
with just a bare email, rewrite it to the full form before committing.

## Prepend is an *insertion*, never a rewrite — HARD RULE

**You MUST verify the old entries survived.** Insert your block immediately *above* the first
`-------` separator (with an exact-anchor edit tool, if your harness has one), or read the whole
file into a variable and write `new_entry + old_content` as **two separate statements**.

**NEVER** prepend with a single truncate-then-read expression —
`open(f,"w").write(header + open(f).read())` (Python), `echo "$new" > f` after capturing,
`sed`-in-place gone wrong: the write handle truncates the file to empty *before* the read runs, so
**every previous entry is silently deleted**.

After writing, **always verify**: the previous top entry is still present, the `-------` separator
count went up by exactly one (`grep -c '^----' <name>.changes`), and `osc diff`/the PR diff shows a
**pure insertion**. Losing prior entries is a guaranteed Factory decline (*"please preserve
changelog entries"*). (Real case: the fastmcp/bugzilla-mcp cone — a
`open(f,"w").write(hdr+open(f).read())` one-liner truncated all three `.changes`, dropping the
`Initial package` entries; the reviewer declined all three SRs.)

## The scripts — `changes-prepend.sh`, `changes-lint.sh`, `changes-guard.sh`

- **`scripts/changes-prepend.sh` mechanizes the prepend + verification — prefer it over
  hand-editing**, because the block it emits is canonical by construction (separator count and
  insertion-only are checked; it restores the file on failure).
- Whichever way you write it, re-run **`scripts/changes-lint.sh --entries <n>`** afterwards: it
  format-lints the newest N entries (separators, headers, blank lines, bullets) and is the pre-SR
  gate against "fix the format of the changes entries" declines. `source_validator` does **not**
  check `.changes` format.
- **`scripts/changes-guard.sh`** is the integrity gate: the committed baseline must remain an exact
  byte-suffix of the new file, so nothing already committed can be overwritten, folded in,
  reordered or deleted. Run it at every commit gate, not just before the SR.
- **`changes-guard.sh --amend-top "<Your Name> <you@example.com>"`** is how you legitimately edit
  your OWN top entry while it is committed to devel (or pushed to an open PR/SR branch) but **not
  yet accepted into Factory** — on a git branch the auto-detected baseline is the *branch HEAD*,
  which already contains your unmerged entry. It still refuses any change from the second entry
  down, a foreign top entry, and emptying the entry. Stop using it once the submission is accepted;
  the entry is history then.
- Full flag/exit-code detail and the one sanctioned override (a `check_dates_in_changes` header
  repair): `scripts/README.md` "`changes-guard.sh`" and `references/changelog-rules.md`
  "Sanctioned exception 2".

## One `.changes` entry per session — amend, don't stack

Pair edits with entries in the same turn: a `.spec` edit and its `.changes` edit land together
before the task is reported done.

Do **not** prepend a fresh entry for each subsequent spec edit (ugly stacks of tiny
consecutive-timestamp entries) — on the first edit prepend the entry; on every later edit in the
session **amend it**: refresh the timestamp to the new current time, and add the new bullet (nested
`*` under an existing dash when it fits thematically, else a new `-`). If a previous turn already
stacked a second entry that should have been an amendment, merge them under the later timestamp,
preserving all bullets. Version bumps stay a separate top-level bullet within that one entry.

## `.changes` records net change, not the journey

The bullet describes what a *consumer* of the package observes (different files installed,
different runtime behaviour, different ABI, different deps), not what the packager did during the
session. The test: *if I diffed the previous build's RPM contents against this build's RPM
contents, would anything differ?* If no — no bullet. Concretely, omit:

- reverted-to-status-quo experiments (tried dropping `-j1`, hit upstream's race, restored it — the
  in-spec comment recording *why* is the entire artefact);
- pure spec-comment additions/rewordings;
- whitespace/spec-cleaner-style rewrites;
- `%files` hygiene that ships the identical file set (expanding `%{_bindir}/*` to explicit names,
  adding `%dir`, hardening a glob);
- rpmlint-warning silencing with an unchanged RPM.

But don't suppress the changelog for a visible cleanup — that still gets its brief umbrella bullet,
and almost every SR must carry an entry (see `references/specfile-guidelines.md`
"Changelog (`*.changes`)" for both rules).
