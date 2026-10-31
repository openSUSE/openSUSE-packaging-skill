# Request text — SR and PR messages, replies to reviewers, comments

What a reviewer reads of your work besides the diff. Every piece is written for a person
scanning a queue: short, specific, and free of your own work notes.

## SR and PR messages

**One headline that says what the request does in a few words**, about 120 characters; the
pr-guard hook refuses more than 160 characters of prose:

```
Update opencode to 2.0.30: elicitation patch now in-tree (dropped), re-vendored, licences re-derived, no copyleft.
```

`Update <pkg> to <ver>: <what changes for a user or a packager>`, or `New package <pkg> <ver>: <what it is>`,
`Drop <patch>: <why>`, `Fix <symptom> (boo#N)`. Name a CVE or bug the update fixes; the
`.changes` carries the rest, and the reviewer reads it in the diff.

**Then, only when the reviewer needs it, `- ` lines** (each at most 100 characters, outside
the 160 cap), first of all **what must be staged together or land first**:

```
Update python-comfyui-workflow-templates to 0.11.85: pins core 0.3.376, json 0.1.111.
- Stage with sr#1385054 (core) and sr#1385055 (json).
```

- `- Stage with sr#N (<pkg>)` — requests that only work together (a lockstep pair, a pin roll).
- `- Needs sr#N (<pkg> <ver>) first` — a build or runtime dependency still in review; the
  request may be red in staging until it lands.
- `- Rebuilds: <pkg>, <pkg>` — consumers a soname or ABI move breaks.
- a dropped architecture, or a question for a named reviewer.

These lines go in the message only, never in the `.changes` entry, which ships in the RPM
(`changes-lint.sh` refuses a request number or a staging order there).

The request you file second can name the first; a one-line comment on the first naming the
second ("Stage with sr#N.") goes out only on the user's go; pr-guard lets it post on your own request, so
hold it yourself.

**A forward carries the same headline as its devel request**, never "Forward X update to
Factory" (refused) — the Factory reviewer sees only this one; "Forward X BR cleanup to
Factory." passes, but the devel headline says it better.

**Never in a message:** build or rpmlint status, test counts, whether a VUL sweep or bug
check ran, what the gate or the change review said, what tools the session had, how you
verified something, links to your home project, a paste of the `.changes`, or an apology
for any of these. That is your report to the user. The hook refuses the usual phrases
(`not done`, `bugwarden`, `VUL sweep`, `built green`, `still building`, `this env`,
`sub-agent`, `no access`, `gate.sh`, `adversarial review`, `review PASS`, a capitalised
`GREEN`) and a bare forward.

A request description renders as **plain text**: line breaks stay, Markdown and `sr#`
links do not render. A Gitea PR body renders Markdown, but takes the same brevity, and
pr-guard lints PR text like SR text, towards any repository (`tea pulls create`,
`git-obs pr create`): the title is the headline (160 characters at most), the description
is held to a message's caps (160 characters of prose, `- ` lines of 100, 1000 in all), and
both are refused for the phrases above, or when the guard cannot read them now.

| Message | Why |
|---|---|
| `Update opencode to 2.0.30: elicitation patch now in-tree (dropped), re-vendored, licences re-derived, no copyleft.` (sr#1385135) | good: what changed, in words a reviewer checks |
| `Update python-ormsgpack to 1.13.0: py3.15/PyPy3.12/GraalPy3.13 support, frozendict, Fragment, unpackb leak fix.` (sr#1385121) | good |
| `Update monero to 0.18.5.4. Devel builds green on … s390x still building. Note: VUL sweep not done, no bugwarden in this env.` (sr#1385068) | work notes; refused |
| `Forward python-langsmith update to Factory.` (sr#1385057) | says nothing about the update; refused |
| `Update python-comfyui-workflow-templates to 0.11.85 (metadata-only bump, pins core 0.3.376 / json 0.1.111).` (sr#1385053) | names the pins, not the two requests to stage with |

Pass the text by file (`-m "$(cat FILE)"`, a PR's `--description "$(cat FILE)"`, written in
an earlier call) and read the request back once filed (`references/osc-usage.md` "Requests").

## Answering a reviewer

A reviewer's question on **your own** request is answered in its thread. pr-guard lets that
reply post without asking, so hold it for the user's go: give them the draft first:

```
osc comment list request <id>                                  # "( ID ) On … <user> wrote:"
osc comment create -p <comment-id> -c "$(cat FILE)" request <id>
```

- **One to three short sentences that answer what was asked**, nothing else: no
  restatement of the question, no history of the work, no thanks-for-reviewing.
- **When the answer is a change**, say what changes ("Dropped the BuildRequires; resubmitting
  as a supersede.") and hand it to Block 2; the reply does not wait for the fix.
- **When you do not know**, say what you will check, and check it before anything else.
- **On anyone else's request**, draft the reply and post it only on the user's go
  (core directive 10).
- **Speak only as what you are.** No first-person claim the user did not make ("I use this
  daily"), and no request for maintainership or other roles unless the user asked for one.

## Comments: reading them, posting an approved one

Reading a thread never needs the user's go:

```
osc comment list request <id>                                                # an OBS request
tea comments list --login src.opensuse.org --repo <owner>/<pkg> <n>          # a Gitea issue or PR
tea pulls review-comments --login src.opensuse.org --repo <owner>/<pkg> <n>  # inline review comments, ids
git-obs -G src.opensuse.org api /repos/<owner>/<pkg>/issues/<n>/comments     # any other read: a GET
```

`tea comments` with no subcommand **adds** a comment, whatever flag follows (there is no
`--issue`), so pr-guard asks before it and names the read above.

**Once the user has approved the exact text, post it yourself** on your own request or PR,
or one in a repository you maintain: pr-guard lets the plain form through,
`osc comment create -c "$(cat FILE)" request <id>`, or
`tea comments --login src.opensuse.org --repo <owner>/<pkg> <n> '<text>'` with the text
inline on one line, no `$`, backslash or backtick, and the command alone in the call. Hand
the user a command only when the guard asks: someone else's item, or any other form.
opencode refuses an ask, so there the user runs it.

## Comments: what OBS renders

OBS renders comments (on requests, packages and projects) with Redcarpet: `autolink`,
`fenced_code_blocks` and `no_intra_emphasis`, through a safe renderer. A request
description and an accept or decline reason are plain text instead, shown with their line
breaks.

- **Works:** paragraphs, `-` and `1.` lists, `**bold**`, `*italic*`, `` `code` ``,
  fenced code blocks, `[text](url)`, bare URLs, `#` headings.
- **Does not:** tables, `~~strikethrough~~`, task lists. **A single newline does not break
  a line**: separate paragraphs, and a list from the text above it, by a blank line.
- **Becomes a link:** `sr#N`, `req#N`, `request#N`, and issue ids such as `boo#N`, `bsc#N`
  and `CVE-…`. **`@user` links that user and notifies them** — write it only to ask that
  person something.

House style for a comment longer than one line:

- a one-line lead that says the point (the verdict, the answer, the ask);
- short paragraphs or a list, each item starting with its key phrase in **bold**;
- `code` for file names, macros, options and commands, a fenced block for anything that
  spans lines;
- `sr#`/`boo#` ids instead of URLs; no tables; no headings in a short comment.

A decline or accept reason stays one plain line; the detail goes in a comment posted
first. Example: comment 2312532 on sr#1382638, a numbered list with a bold lead per point,
behind the decline line "New packages must follow the current guidelines: … See the
review comment on this request for the full list; please resubmit once fixed."
