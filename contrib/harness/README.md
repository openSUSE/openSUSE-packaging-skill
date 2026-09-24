# Harness wiring for `pr-guard.py`

Drafts, not installed by anything. They wire
`skills/opensuse-packaging/scripts/pr-guard.py` into the two agent harnesses so that no
agent opens, updates or merges a `pool/` PR on src.opensuse.org outside `pool-pr.sh`
(through `tea`, `git-obs` or `git obs`, or the API), pushes to a branch that heads an open
pool PR, writes a `target-gate.sh` stamp, runs an emulated `osc build`, or files a request
against the scmsync'd `openSUSE:Backports:SLE-16.x` projects.

| File | Goes to | Does |
|---|---|---|
| `scripts/pr-guard.py`, `scripts/_pr_guard.py` | `~/.claude/hooks/` | the guard: `pr-guard.py` runs the prefilter, and reads its rules from `_pr_guard.py` beside it only on a match |
| `claude-settings-snippet.json` | merged into `~/.claude/settings.json` | a PreToolUse hook on `Bash\|Monitor\|Write\|Edit`, plus deny rules that keep the agent from editing the hook and harness config |
| `opencode-pool-pr-guard.ts` | `~/.config/opencode/plugins/pool-pr-guard.ts` | the same guard for opencode: prefilters in TypeScript, spawns the guard only on a match, refuses the call when it exits non-zero |
| `opencode-permission-snippet.jsonc` | merged into `~/.config/opencode/opencode.jsonc` | a pattern backstop: deny pool merges, ask on PR creates, each `git-obs` pattern also spelled `git obs` |

Both harnesses run one **pinned copy** of the guard. It is not updated with the skill:
the guard polices the skill's own scripts, so a change to it is a decision, not a pull.

## Install

Wait until the branch that brought this guard is merged into `origin/main` **and** the
skill checkout has fetched it (`git -C <checkout> fetch origin`). The guard runs the
checkout's scripts unread once they match `origin/main`. Until the merge, that is the old
`leap-sync.sh`, which pushes and opens or updates pool PRs itself with no gate, and a
`git stash` or `checkout main` in the checkout would bring it back.

Show each diff before applying it.

1. Pin the guard, both files:

   ```
   install -D -m 0444 -t "$HOME/.claude/hooks" skills/opensuse-packaging/scripts/pr-guard.py skills/opensuse-packaging/scripts/_pr_guard.py
   ```

   To update it later, read `diff -u` of each installed file against the skill's copy
   first, then re-run the `install`. Without `_pr_guard.py` every call the prefilter
   matches is refused.

2. Claude Code: add the snippet's PreToolUse entry to `hooks.PreToolUse` in
   `~/.claude/settings.json`, next to the existing entries, and its rules to
   `permissions.deny`. Then delete any allow rule that pre-approves pool PR traffic from
   the project settings (`.claude/settings.local.json`): `tea pr create --repo pool/...`,
   `curl -X POST` to `.../repos/pool/...`. A hook's refusal wins over an allow rule, but
   an allow rule for exactly the guarded call says the opposite of the policy.

3. opencode:

   ```
   install -D -m 0444 contrib/harness/opencode-pool-pr-guard.ts "$HOME/.config/opencode/plugins/pool-pr-guard.ts"
   ```

   Merge the snippet's `permission` block into `~/.config/opencode/opencode.jsonc`, then
   restart every running opencode TUI: a running one keeps the plugins it started with.

4. The guard runs the scripts of the skill checkout's `scripts/` unread only **as
   merged**. Every file that `scripts/` tracks, in the index or at the pinned ref, must
   hash (`git hash-object --no-filters`) to its blob at `refs/remotes/origin/main` of that
   checkout (not `HEAD`). The scripts run their siblings, so one edited, added or dropped
   file untrusts them all, and so does a call that writes into `scripts/`. A script must
   also be run by its path and get no environment change but `TMPDIR`, `LC_ALL`, `LANG`
   and `NO_COLOR`. A local edit or an unmerged commit is read like any other script,
   which for `pool-pr.sh` means refused, until it is merged and fetched
   (`git -C <checkout> fetch origin`). Sourcing one, or feeding it on stdin, is refused:
   the scripts find their siblings from their own path. The guard finds the checkout at
   `~/.claude/skills/opensuse-packaging`, then `~/.agents/skills/opensuse-packaging`;
   export `PR_GUARD_SKILL_DIR` in the harness's environment if it lives elsewhere, and
   `PR_GUARD_PIN_REF` to pin another ref. An installer copy that is not a git checkout
   has no pinned ref, so its scripts are read like any other.

## What reaches the guard

The prefilter matches any path, `tea`, `git-obs` or `git obs`, `src.opensuse.org`,
`push`, `send-pack`, `target-gate`, `osc`, a shell or interpreter, and `. FILE`: a file a
command runs is where a POST hides. A call whose working directory is inside a
`target-gate` directory is judged too. The rest of the command line decides nothing.

A matched command is judged one parsed command at a time: a commit message, a grep
pattern or an echo that quotes a pool merge is text, not a merge. Program text is read
whole: every script a command runs, inline code (`-c`, `-e`), and text fed to a shell or
interpreter (heredoc, here-string, `< FILE`, a pipe from `echo`, `printf` or `cat`). A
program piped in from anything else is refused. `tea` and `git-obs` without a repository
act on the clone that a `cd`, subshell or `env -C` leaves; a branch, remote URL or
repository held in a variable is unknown, so the call is refused.

A script's path is expanded before it is read. Values the call assigns (the words of a
`for` loop included), `$PWD`, `$TMPDIR` and `$HOME` are substituted, and globs are matched
in the tracked directory. A path the command line runs that still cannot be expanded, or
whose variables give it more than 64 spellings, is refused (`exec-unresolved`). A file the call
writes (a `>`/`>>` redirection, `tee`, `cp`/`mv`/`install`, `sed -i`, `perl -i`,
`curl -o`/`-O`) cannot run later in the same call (`exec-written`), because the guard
would judge what the file held before. Run it in the next call, where it is read.

A stamp directory is a `target-gate` path component directly under a git directory: one
named `*.git`, or one holding `HEAD` and `objects/`. A parent only the shell knows counts
too: `"$(git rev-parse --git-common-dir)/target-gate"`, a variable set from one, or
`$UNSET/target-gate`. A bare `target-gate` names one only when the working directory is a
git directory. A command touches a stamp when it names a stamp directory, runs inside
one, or reads program text that names `target-gate` at all. Two exceptions: the skill's
own `target-gate.sh`, run by path while pinned, and git's arguments, since a branch, commit
message or grep pattern is text (a redirection is still judged). Some commands may look at
a stamp: `ls`, `cat`, `jq`, `grep`, `rg`, `head`, `tail`, `less`, `stat`, `wc`, `echo` and
`printf`; `find` without `-exec`, `-delete` or `-fprint`; `sed` without `-i`; `awk`; and
`python3 -m json.tool` without an output file. That holds only while they redirect no
output to a file and their program or options (`sed w`, `awk print >`) name no stamp. The
Write and Edit tools are refused for any path with a `target-gate` component.

Measured on an aarch64 host with Python 3.13, `python3 pr-guard.py < EVENT`:
- a call the prefilter lets through takes ~63 ms, about what python3 needs to import
  json and re. The single-file guard before the prefilter split took ~195 ms;
- a matched call that needs no lookup takes ~113 ms, most of it compiling
  `_pr_guard.py` (was ~198 ms);
- a push adds a few git queries and one Gitea lookup;
- running a skill script adds three git queries.

## Smoke test

Safe: nothing is run, only judged.

```
for owner in pool AI; do
  printf '{"tool_name": "Bash", "cwd": "/", "tool_input": {"command": "true || tea pulls merge --repo %s/zzz 1"}}' "$owner" \
    | python3 "$HOME/.claude/hooks/pr-guard.py"; echo "rc=$?"
done
```

`pool` prints `BLOCKED [merge-tea]` and `rc=2`; `AI` prints `rc=0`. Then, in each
harness, ask the agent to run `true || tea pulls merge --repo pool/zzz 1`: the call must
be refused with the guard's message. The `AI/zzz` variant must run, and so must
`echo "tea pulls merge --repo pool/zzz 1"`, which only prints the words.

## How a refusal travels

- Claude Code blocks a call only on **exit 2** and hands the model the guard's stderr.
  Any other non-zero exit is a non-blocking error, so the guard turns every failure
  after a match (an unresolvable remote, a failed PR lookup, a missing `_pr_guard.py`,
  a crash) into exit 2.
- The opencode plugin throws on any non-zero exit, and when `python3` or the pinned
  guard cannot be spawned. That refuses only calls that matched the prefilter; the rest
  never reach the guard.

## Limits

- Trust in the skill's scripts is trust in the checkout's `origin/main`: moving that ref
  by hand (`update-ref`, a fetch from another remote) re-blesses whatever it names.
- A script run by bare name from `PATH` is not read, nor a program held in a variable
  the call does not set or made by a substitution (`$CMD`, `eval "$CMD"`,
  `bash -c "$(cat F)"`).
- After `cd "$VAR"` or `cd "$(...)"` the working directory is unknown: a push, an
  unnamed `tea` or `git-obs` call, or a script run by relative path is refused.
- A heredoc written into a file is not read when it is written; only the Write and
  Edit tools' content is. The file is read by a later call that runs it; the call that
  writes it cannot run it (`exec-written`).
- The deny rules stop the Edit and Write tools, not a shell command that edits the same
  files.
- A push through a helper is not seen: a Python `def git(*a)`, a shell function
  `g() { git "$@"; }`, `git -c alias.x=push x`.
- A pulls URL assembled without a literal `/pulls` (`base + 'pulls'`, `urljoin`,
  `"${API}pulls"`) is not seen, nor a request body set after construction
  (`r.data = ...`).
- Perl's LWP and HTTP::Tiny requests are not seen, and `ruby`, `bun`, `deno` and `php`
  programs are not read.
- Commands run through `watch`, `flock`, `script` or `find -exec` are not unwrapped,
  and words `xargs` reads from stdin are not seen (`echo B | xargs git push fork` is
  judged as a push of the current branch).
- A script whose shebang is `env -S` and whose name has no `.sh` is read as program
  code, so its shell pushes are not parsed.
- A `PATH` shim for `osc` or the build tools, set up in an earlier call, is used by the
  skill's scripts.
- In a script the guard reads, a helper it calls by a computed path (`$HERE/b.sh`,
  `$(dirname "$0")/b.sh`) is not read. A local module run with `python3 -m`, or one a
  script imports, is not read either.
- A file only counts as written if the guard can place its path, and only when the
  shell writes it. Writes by other tools (`git checkout`/`apply`, `patch`, `tar`,
  `rsync`, `ln`, `wget -O`, program code) are missed.
- A wildcard refspec that renames (`refs/heads/a-*:refs/heads/b-*`) is judged by the
  local branch names.
- A repository held in a program variable (`["tea", ..., "--repo", R]`) is judged by
  the clone's remotes. An f-string is judged by its literal owner: `f"pool/{pkg}"` is
  pool, `f"{o}/{pkg}"` is unknown and refused.
- A request body option (`--json`, `--data`, `--form`, `--upload-file`) counts only on
  a `curl`, `wget` or `tea api` line, or in the argument list that names the tool. One
  added to that list later (`cmd += ["--json", body]`) is not seen.
- git's arguments are not judged for stamps, so git writing into a stamp directory
  itself (`--work-tree`, `--output`) is not seen; a redirection is.
- The opencode plugin does not send `patch`/`apply_patch` tool calls to the guard.
