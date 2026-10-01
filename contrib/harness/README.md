# Harness snippets

Drafts, installed by hand, one directory per harness:

- **Permission snippets** for each harness below keep credentials inside the tools, the
  rule of the skill's `references/osc-usage.md` "Tool discipline": no agent reads an osc,
  tea or gh credential file or `.netrc`, prints a token, passes a key on a command line or
  talks to the OBS or Gitea API past osc, tea and git-obs. They also refuse a PR merge on
  src.opensuse.org, a Factory request with `--nodevelproject` and `sudo chroot`.
- **The pool PR guard**, for Claude Code and opencode (1.x and 2.x): `scripts/pr-guard.py`
  as a hook.

**You install them yourself.** An agent must not change its own permissions, and Claude
Code's auto mode refuses the edit as self-modification. **Merge, do not replace**: each
file holds only the keys to add to your settings. Show each diff before applying it.

The patterns match text, not intent. A path spelled with a glob, a variable or split
quoting (`.ne""trc`), a script written first and run later, or a program that opens the
file itself gets past every one of them. For a hard boundary, run the agent in a sandbox
or container that does not mount these files.

## Permission snippets

| Harness | File | Goes into |
|---|---|---|
| Claude Code | `claude/settings.json` | `permissions.deny` of `~/.claude/settings.json` |
| opencode 1.x | `opencode/opencode.jsonc` | the `permission` keys of `~/.config/opencode/opencode.jsonc` (or `.json`) |
| opencode 2.x | `opencode-v2/opencode.jsonc` | the end of the `permissions` array of `~/.config/opencode/opencode.jsonc` (or `.json`) |
| grok | `grok/config.toml` | `[permission]` `deny` of `~/.grok/config.toml` |
| Gemini CLI | `gemini/opensuse-packaging.toml` | copy to `~/.gemini/policies/opensuse-packaging.toml` |
| Antigravity CLI (`agy`) | `agy/settings.json` | `~/.gemini/antigravity-cli/settings.json`, with `/home/USER` replaced |
| Codex CLI | `codex/opensuse-packaging.rules`, `codex/config.toml`, `codex/requirements.toml` | a copy in `~/.codex/rules/`, with `/home/USER` replaced; merged into `~/.codex/config.toml`; optionally, as root, `/etc/codex/requirements.toml` |
| Kimi Code | `kimi/config.toml`, `kimi/opensuse-packaging.py` | appended to `~/.kimi-code/config.toml`; the hook copied to `~/.kimi-code/hooks/` |

Every snippet denies, as far as its harness can express it:

- the credential files `~/.config/osc/`, `~/.oscrc`, `~/.config/tea/`,
  `~/.config/gh/hosts.yml`, `~/.netrc` and `~/.git-credentials`, osc's cookie jar
  (`~/.local/state/osc/`) and the bugzilla MCP key (`~/.config/mcp-bugzilla/`), to the
  read tool and on a command line, where all of `~/.config/gh/` counts (not
  `~/.config/ghostty`);
- what prints a secret:
  - gh: `gh auth token`, `gh auth status` as a whole (`-t` also hides in `-at`) and `gh
    auth git-credential`;
  - git-obs: `git-obs login list` as a whole (`--show-tokens` has prefixes) and `git-obs
    login gitcredentials-helper`;
  - tea: `tea login helper`, its alias `git-credential`, and `tea login edit`/`e`, also
    spelled `logins`;
  - osc: `osc config --dump-...` (plain `--dump` hides the passwords and stays allowed;
    `--dump-` counts only on an osc command line, so `curl --dump-header` runs),
    `osc config <apiurl> pass`/`passx`, `osc token` as a whole (it lists and creates
    tokens with their secrets; `--delete` and `--trigger` go with it), `osc api` on
    `/person/<login>/token`, and HTTP debugging: `-H` alone or in a short-option cluster
    (`-qH`, `-Hq`, `-qvH`; which clusters each harness takes is under Limits),
    `--http-d...`, `--http-f...`, and `http_debug`/`http_full_debug` as an environment
    variable, `--setopt` or config key;
  - git: `git credential fill`, and `git credential-<helper> get` or
    `git-credential-<helper> get`;
  - the desktop keyring, which holds gh's token: `secret-tool lookup` and `search`;
  - an `Authorization:` header passed with `-H` (also in a cluster, as in `curl -sH`) or
    `--header` (matched as `uthorization`, so either case), `--apikey`, `--apisecret`,
    and a password in a URL (`scheme://<user>:<password>@`);
- handing git a credential by hand (`GIT_ASKPASS=`, `SSH_ASKPASS=`, `core.askPass`), and
  `curl` to `api.opensuse.org`, `build.opensuse.org` or `src.opensuse.org/api`;
- merging a PR on src.opensuse.org, pool or not, with `tea`, `git-obs` or `git obs` or
  through the API (`gh` is not matched), `osc sr`/`creq` with `--nodevelproject`, and
  `sudo chroot`.

The rules match the mechanism, not the word, where the two differ: work on the
openssh-askpass and git-credential-* packages, a grep for `api-key` or `Authorization:` in
a source tree, `osc config --dump`, `tea logins list`, and a commit or request message
that mentions a token or a config pass still run. The Claude Code,
opencode, grok and Codex blocks are meant to match the openQA skill's rule for rule where
the two overlap, and the opencode 2.x block the opencode 1.x one; the Gemini CLI and
Antigravity snippets cover the same set in their own form. The opencode snippets also deny
`.env` files but allow `.env.example`, and ask before a PR create. `tests/test-harness.sh`
checks that every snippet parses, names the whole set and every path it claims for its read
tool, has the command globs of Claude Code, grok and both opencode snippets refuse its
probes and leave packaging commands alone, runs the Gemini CLI rules and the Kimi hook
against probes and against 64 KB of pathological input, and, where
codex and kimi are installed, has `codex execpolicy check` and `kimi doctor config` judge
theirs. One shared list of commands to refuse and to let through goes through the globs,
the Gemini CLI rules and the Kimi hook alike, and every glob, every Gemini CLI
alternative and every Kimi rule and credential path must be the only one to refuse
some probe, so deleting any of them turns the suite red.

These are pattern lists, and no pattern list is complete. Limits every harness shares:

- A global option before the subcommand hides it from a rule that expects the
  subcommand next: `tea --login x pr merge 3`, `tea logins --output simple e`, `git -C
  dir obs pr merge`, `osc -A URL sr --nodevelproject`, `osc -A URL token`. The Claude
  Code, grok and opencode globs catch none of these, nor do the Codex and Antigravity
  prefixes; the Gemini CLI rules and the Kimi hook catch the merge behind `--login`, the
  request and the token call behind `-A`, and neither of the other two (checked by
  `tests/test-harness.sh`). The Gemini CLI rules take one global option before `osc
  token` or `osc config`, the Kimi hook up to sixteen.
- `osc` takes an option by any unambiguous prefix, so `--nod` is `--nodevelproject`: the
  `osc sr *--nodevelproject*` rules miss it, the Kimi hook and the Gemini CLI rule take
  `--nod`. The Codex rules list every prefix of the HTTP-debug and `--dump-full` options;
  Antigravity lists only the full names.
- osc HTTP-debug clusters: the Gemini CLI rules and the Kimi hook take any short-option
  cluster that holds `H`. The Claude Code, grok and opencode globs take a word starting
  `-H` anywhere, and a cluster ending in `H` when osc's first word is an option (`osc
  -qvH ls`, `osc -A URL -qvH ls`); `osc ls -qvH` passes them. The same glob also
  refuses a message after a global option that holds a word ending in `H` (`osc -A URL
  vc -m 'Update to OpenSSH 9.9'`). The Codex and Antigravity prefixes list `-H`, `-qH`,
  `-vH`, `-Hq`, `-Hv`, `-qvH` and `-vqH` right after `osc`.
- Only the Kimi hook joins a backslash-continued line (`gh auth \` then `token` on the
  next line), as Bash does; the other harnesses see two words apart.
- The API hosts are matched on `curl` only; the Kimi hook also takes `wget`; none takes
  httpie's `http` or a header given another way (a config file, httpie's `Name:value`).
- `osc api /person/<login>/token` and `git credential-<helper> get` are beyond the Codex
  and Antigravity prefixes, which list only the `git-credential-<helper> get` form of a
  few helpers. `gh config get oauth_token` is refused nowhere; it prints the token when
  gh keeps it in `hosts.yml`.
- False positives the globs keep: the glob for a password in a URL also refuses an osc
  call whose explicit URL argument holds a `:` and an `@` (an XPath search, say), and
  `*-H*uthorization*` refuses `grep -H Authorization` and a command that passes through a
  `perl-HTTP-*` directory and mentions `Authorization`. The Gemini CLI and Kimi regexes
  avoid both.
- The Kimi hook splits a command at every `&` outside quotes, `2>&1` included, and reads
  `$'...'` as a plain single-quoted word; either can put a rule's parts in different
  simple commands.
- Secrets outside files are covered only as far as `secret-tool lookup` and `search`: any
  other keyring reader over D-Bus, SSH private keys under `~/.ssh`, an agent socket, or a
  credential helper not named above is not.
- The skill's own gate scripts, `pool-pr.sh`, `target-gate.sh` and `leap-sync.sh`, read
  no credential themselves: they reach src.opensuse.org through
  `git-obs -G src.opensuse.org api` and push over SSH, so git-obs reads its login (the tea
  config by default) and ssh its key. A profile that denies those files to every process
  (Codex's `credentials-strict`, Antigravity's sandboxed terminal) breaks the scripts
  through them.

### Claude Code

Checked on 2.1.283 in a throw-away home: `claude doctor`, which names every malformed
rule (tried with a planted one), reports none of the 93. Matching was measured by the
openQA skill on the same version, in print mode: a `Read(...)` rule stops the Read tool
but **not** `cat` of the same file, and a `Bash(*...*)` rule stops the command. So every
path has both.

- The pool PR guard's hook ships apart, in `claude/pr-guard-hook.json`: merge it only once
  the guard is pinned ("Install the guard"). `python3` exits 2 on a missing script, and
  Claude Code takes exit 2 as a refusal of every Bash, Write and Edit call.
- Rules that start with a command (`tea pr m *`, `curl *...`, `osc sr *...`) are prefixes:
  opencode's miss the command behind `env`, `command` or `A=1`; Claude Code's were not
  measured that way.
- A deny cannot be narrowed by an allow here, so `osc token` is refused whole, and `tea
  pr *merge *` also refuses a PR create whose title holds the word "merge".

### opencode 1.x

Checked on 1.18.32 in a throw-away home with dummy credential files, under `env -i` with
D-Bus disabled. `opencode debug config` loaded all 103 rules then (5 `external_directory`,
87 `bash`, 11 `read`); the three `bash` rules added since, for a quoted `~/.config/gh` and
for `~/.local/state/osc`, are checked by the suite's matcher only. `opencode debug agent
build --tool read` refuses every credential path of the set from a git worktree, from
outside git and with the home directory as the worktree, with the `read` rules alone as
well, and reads an openssh-askpass spec; `--tool bash` refuses every command of the set
and the secret printers as text behind `echo`, and lets packaging commands and greps of
source trees run; `--tool grep` is refused a search of the tea config directory from a
project.

- The last matching rule wins, in file order. The `bash` block's `"*": "allow"` must be
  its first key, also when the openQA skill's snippet is merged beside this one; leave it
  out to keep a default of your own, placed first. The `read` block has no `"*"`: allow is
  the default there, and a `"*"` merged after another snippet's denies would undo them.
- `read` patterns are matched against the path relative to the worktree, or to `/`
  outside git, so they start with `*`: `~/`, `$HOME/` and absolute patterns never match,
  and `*/.config/...` misses when the home directory is the worktree (both measured with
  the first snippet).
- The merge denies come after the create asks: a merge POST to a pool repository matches
  both.
- The built-in `.env` rules only ask, and an "always" answer approves every read for the
  session; hence the explicit denies. The oscrc read rule is `*oscrc*`, broader than the
  openQA skill's `*.oscrc`.
- A project's own `opencode.json` can re-allow what the global file denies;
  `OPENCODE_DISABLE_PROJECT_CONFIG=1` prevents that (both measured).
- The grep tool ignores `read` rules. `external_directory` stops it outside the project,
  and does nothing when opencode starts in the home directory: there grep finds the
  credential files (measured).
- Patterns that start with a command miss it behind `env`, `command` or `A=1` (measured).

### opencode 2.x

Checked on 2.0.21 in a throw-away home with dummy credential files, under a bare
environment with D-Bus disabled. There is no `debug agent --tool`, so a local
OpenAI-compatible stub returned scripted tool calls to `opencode run --standalone`, and
every verdict below is the tool's own. `opencode debug agents` lists all 102 entries of
`opencode-v2/opencode.jsonc` (5 `external_directory`, 86 `shell`, 11 `read`) after the base
policy. A second opencode service needs its own port (`opencode service set port N` in the
throw-away home); on the default one every command hung.

- opencode 2.x still loads the 1.x snippet: `permission.bash` becomes `shell`, in key
  order, so its `"*"` allow stays first. A `permissions` array in the same file is
  appended after those entries, so use one snippet, not both. Edits to the file reached the
  running service within seconds; `opencode reload` answered 503 here.
- The 1.x plugin does not run. A 1.x `pool-pr-guard.ts` in the plugins directory logs
  "Plugin must export a default definition with an id and an effect or setup function",
  `opencode plugin list` lists the file with the ID `-`, a plugin that failed to load
  (right after a restart, nothing at all), and a `tea pulls merge` ran unrefused.
- The last matching entry wins, in array order, over a base policy whose first entry allows
  everything. There is no `"*"` allow in the 2.x snippet: one appended after other entries
  would undo them.
- A `shell` pattern ending in ` *` also matches the bare command (`sudo chroot`, `tea pr m`,
  a bare `tea pr create` asks). Three 1.x patterns, `*.config/gh`, `osc -*H` and
  `*git-credential-* get`, are therefore left out: their ` *` twins cover them.
- The shell scanner cuts a call into simple commands: a merge after `||`, `;`, `&&` or `|`,
  in `( )`, `$( )` or backquotes is refused. All 111 refuse probes of the suite's fixtures
  are (two that `cd` into `~/.config` or `~/.local/state` first ask about that directory,
  then the deny holds), and the 58 ordinary commands run (a non-interactive `run`
  rejects the PR-create asks unless it has `--auto`). `echo "tea pulls merge --repo
  pool/x 1"` and `git commit -m 'tea pr merge 3'` run, `echo "gh auth token"` is
  refused. `bash -c '...'` is not unwrapped.
- Patterns that start with a command miss it behind `env`, `command` or `A=1`: `env tea
  pulls merge`, `command tea pr merge 3`, `A=1 osc sr --nodevelproject` and `env osc token`
  ran. `*`-prefixed ones (`gh auth token`) hold behind `env` and `A=1`. The global-option
  forms of the shared Limits ran too.
- `read` takes `path` (1.x: `filePath`). With the `read` entries alone, every credential
  path of the set is refused from a git worktree, outside git and with the home directory
  as the worktree. `~/`, `$HOME/` and absolute patterns now match, but only a path outside
  both the project and its git worktree: never with the home directory as the worktree. The
  `*` prefix works in all three, so the snippet keeps it. With the whole snippet,
  `external_directory` refuses five of the paths and `read` the other three (`~/.oscrc`,
  `~/.netrc`, `~/.git-credentials`); `.env` is refused, `.env.example` read. Without
  `--auto`, an external path asks first, and a non-interactive run rejects the ask.
- The grep and glob tools, aimed at the tea config directory from a project, are refused by
  `external_directory`; aimed at its parent, `~/.config`, grep is only asked, and with
  `--auto` it found the credential files there. The grep resource is the regex, not the
  path, so no rule can name it. With the home directory as the worktree, both find the
  credential files with no ask at all.
- A project's own `opencode.json` can re-allow what the global file denies;
  `OPENCODE_DISABLE_PROJECT_CONFIG=1` prevents that. An `experimental.policies` deny in the
  global file (`shell:*gh auth token*`, `read:*.netrc`) held against that project file and
  `--auto` ("Blocked by configuration policy"); a policy in a project file: not run here.
- `--auto` keeps every deny and turns the PR-create asks into runs.
- The 2.x guard plugin, with the pinned guard in the same home: `true || tea pulls merge
  --repo AI/zzz 1` and the `pool/zzz` create are refused with the guard's own message, the
  `AI/zzz` create and an `echo` of a merge command run, and a write under `target-gate/` and
  a `cat` of the tea config are refused. The `execute.before` event carries `tool` and
  `input`: `shell` takes `command` and `workdir`, `write` `path` and `content`, `edit`
  `path`, `oldString` and `newString`. The hook runs before the permission check, and a
  relative `workdir` is relative to the project, so the plugin resolves it against its
  location.

### grok

Checked on 1.0.32: `grok inspect --json` loads all 91 rules with none skipped. An unknown
rule is dropped silently (a planted `Frob(x)` counted 0), so compare the count after
merging. Matching was not run here (it needs a model call); the openQA skill measured it:
a deny beats every allow and ask and holds under always-approve, command globs match the
whole command and each segment, and `*` crosses spaces and `/`.

- A leading `~/` is literal text, so home paths use `**/`, and `X/**` does not match `X`,
  so a directory is listed both ways.
- grok also reads `~/.claude/settings.json`: with the Claude snippet merged it loads those
  93 rules too (184), whose `Read(~/...)` rules do not match in grok. It lists the guard's
  PreToolUse hook as enabled once `claude/pr-guard-hook.json` is merged; whether grok
  hands the guard an event it can judge is not verified, so do not count on the guard in
  grok.
- As in Claude Code, a deny cannot be narrowed, so `osc token` is refused whole.

### Gemini CLI

Not installed here. Written against the policy engine of gemini-cli `main`
(`packages/core/src/policy/`): `tests/test-harness.sh` runs the rules through a port of
its loader (`commandRegex` becomes `"command":"` + the regex, and a quantified group that
holds a quantifier is refused), probes them, and times each rule on 64 KB of pathological
input; the CLI itself was not run. A file in
`~/.gemini/policies/` is the user tier: priority 999 there outranks YOLO mode and "allow
for all future sessions" answers; only the admin tier outranks it.

- `settings.json` `tools.exclude` is deprecated and cannot match a path.
- The `--policy` flag and the `policyPaths` setting replace the user tier, and drop this
  file with it.
- The shell regexes scan the JSON arguments from the command onwards, its description and
  directory included: a commit message or a description that quotes a merge, a printer
  or a credential path is refused too. File tools already refuse paths outside the
  workspace; do not start Gemini in the home directory.
- The CLI runs the rules in-process, so a slow regex hangs it. A gap between two parts
  inside a floating gap backtracked cubically: the first version's `osc config ... pass`
  rule never finished on a 64 KB command. A rule of several parts is now a row of
  lookaheads tried at the start of each simple command and stopped at the next `;`, `&`
  or `|`, one lazy scan each; the slowest rule takes under 0.2 s on the suite's
  pathological input. The parts may come in any order within one simple command, so
  `osc ls && grep -H x` runs.
- A regex cannot track quotes, so a quoted `;`, `&` or `|` ends a row's scan like a real
  one: `osc sr -m "fix; see bug" --nodevelproject` passes (the suite checks that it
  does), and so does a backslash-continued line.
- Pool PR creation is not gated: the guard is not wired for Gemini.

### Antigravity CLI (`agy`)

Written from the permissions documentation of antigravity.google, as the openQA skill's
was. On 1.2.5, in a throw-away home, `agy --log-file F agents` logs "CLI settings
initialized" with all 57 deny entries; it logs any string, so that shows the file is read,
not that each rule is valid. Check `/permissions`, Global, deny after merging.

- Targets are absolute: replace `/home/USER` with your home directory.
- `command()` rules match a command prefix, so the snippet lists the prefixes the set has:
  the gh, git-obs, tea, osc and git printers, the known `git-credential-<helper> get`
  forms, the merges and `--nodevelproject` right after the subcommand, and `sudo chroot`.
  They cannot catch a path anywhere in a command, an option before the subcommand, a
  header or a key in a URL, `osc config <apiurl> pass`, the HTTP-debug environment and
  config forms, or a `curl` to the APIs.
- The file rules are enforced by the operating system only for commands run in the
  terminal sandbox, which `enableTerminalSandbox` turns on; `allowNonWorkspaceAccess:
  false` keeps the file tools in the workspace. The sandbox was not run here (agy needs a
  signed-in model), so it is untested whether those rules also keep osc, tea, git-obs, gh
  and the skill's gate scripts (through git-obs) from reading their credentials in agy's
  terminal. If they do, drop the entries for `~/.config/osc`, `~/.oscrc`, `~/.config/tea`,
  `~/.config/gh/hosts.yml` and the cookie jar.
- Whether the rules survive `--dangerously-skip-permissions` is not verified: do not use
  that flag with this skill.

### Codex CLI

Checked on 0.154.0 in a throw-away home under `env -i` with D-Bus disabled: `codex
execpolicy check --resolve-host-executables` decides all 72 probes as intended, gaps
included, and exits 1 with "failed to parse policy" on a failing `match` example or a
syntax error (both tried). `codex sandbox -P <profile> -C <dir> -- <command>` gives the
sandbox's verdict on dummy files and a dummy osc config. The profile names match the
openQA skill's: if its snippet is merged already, add these keys to the same tables (TOML
refuses a table twice).

What the default `credentials` profile covers is narrow. It denies `.netrc`,
`~/.git-credentials`, the bugzilla key, and `.env` and `.env.local` at the workspace root,
to every sandboxed process; `.env.example`, an openssh-askpass spec and project files
stay readable (measured). The tool configs and the cookie jar are covered only by the
rules, and there only for a reader given the exact absolute path: `grep`, `sed`, `python3`,
a path with `~`, `cat -n` or a relative path in another `workdir` get past. Only the
opt-in `credentials-strict` profile denies them to every process.

- The profile runs every command in a workspace-write sandbox with no-new-privileges:
  only the workspace and `/tmp` are writable, `/var/tmp` is not, and `sudo` refuses to
  run (all measured). A local `osc build` therefore cannot run inside Codex, and the
  skill's gate scripts, which default their temporary files to `/var/tmp`, need `TMPDIR`
  set to a writable root. A path that must stay writable goes into
  `[permissions.credentials.filesystem]` as `"<path>" = "write"` (measured).
- osc takes a lock beside its cookie jar on every call, so the profile makes
  `~/.local/state/osc` writable; without it every osc command failed with "Read-only file
  system" (measured with a dummy config). The directory must exist before Codex starts,
  since a write entry for a missing path lets nothing create it (measured): run osc once
  outside Codex. `credentials-strict` still denies the cookie jar file itself (measured).
  Accepting an unknown certificate writes `~/.config/osc/trusted-certs`, which needs its
  own write entry.
- The workspace's `.git` stays read-only under this profile, so `git commit` and every
  osc call in a git package checkout fail (measured; osc takes a lock under `.git/obs`).
  A deny list also keeps an escalated call sandboxed, so approving it does not help. The
  commented `".git" = "write"` lifts that (measured), and with it lets the agent write
  `.git/hooks` and `.git/config`, which run outside the sandbox on your next git command.
  Weigh that before enabling it.
- Rules are exact argv prefixes, and a `bash -lc` script is split only when it is plain
  words: `cat -n FILE`, a path spelled with `~`, `FOO=1 cat FILE`, `sudo -E chroot`,
  `osc -A URL sr --nodevelproject`, `osc sr -m x --nodevelproject` (the flag not right
  after the subcommand), `osc -A URL token`, `osc config <apiurl> pass`, `tea pr --repo X
  merge 3` and `git-obs -G x pr merge` get past them. A header, a key in a URL, the
  askpass and HTTP-debug environment forms and `curl` to the APIs cannot be expressed.
- A parse error or a failing example in any rules file drops them all, `/etc/codex/rules`
  included: `codex exec` refuses to start and the TUI only warns. Check after every edit.
- `exec_command` takes a `workdir` the rules never see: `cat config.yml` run in
  `~/.config/tea` gets past them (measured on 0.154.0); only `credentials-strict` stops it.
- The profile is dropped by `-s`, `-c sandbox_mode=...`, `--approve-for-me`,
  `--dangerously-bypass-approvals-and-sandbox`, `codex exec --ignore-user-config` and a
  `sandbox_mode` in a project config (measured on 0.154.0, not re-run here). Only
  `requirements.toml`, as root, survives them, by refusing to start Codex in those modes;
  it was not tried here.
- Any glob in a profile is expanded with rg before every command, and one unreadable
  directory under its root, or more than 8192 matches, fails every command (measured with
  `**/.env` and one unreadable directory in the workspace). So the profile names literal
  paths only, and `.env` is denied at the workspace root, not in subdirectories.
- `credentials-strict` also keeps osc, tea, git-obs, gh and the skill's gate scripts
  (through git-obs) from reading their credentials inside Codex (osc then asks for a user
  name), so it is opt-in per session. gh's token lives in the keyring, reached over D-Bus,
  not a file: the commented socket deny cuts it off.

### Kimi Code

Kimi 0.42.0 parses `[permission]` rules but does not enforce them, so the snippet is a
PreToolUse hook. Checked on 0.42.0 in a throw-away home under `env -i`: `kimi doctor
config` accepts the entry and rejects an unknown key or event name (both tried), but does
not compile the matcher, so `tests/test-harness.sh` does, and checks it selects Bash,
Read, Grep, Write and MCP tools. The suite feeds the hook 277 events on stdin: it refuses
the set, including a `;` inside a quoted message, a continued line, `$(osc token)`, an
abbreviated `--api` before `token`, an MCP search scoped to the home directory, a
relative path resolved against an ACP session's `workDir`, the process directory or the
Bash call's own `cwd`, a Grep over the home directory and a Write to its own config,
refuses input that is not JSON, and lets ordinary calls and the openssh-askpass and
git-credential-* packages through.

- One invalid `[[hooks]]` entry anywhere makes Kimi ignore every hook, with only a warning
  on stderr, and a matcher that does not compile skips its hook silently: run `kimi doctor
  config` after every edit. Appending such an entry is also the easy way to switch the
  guard off. The hook refuses Write and Edit on its config and itself, but a shell command
  can still change them.
- It fails open when `python3` is missing, on the 10 s timeout and on a kill: Kimi runs
  the call. Errors inside the hook, bad input and a missing script refuse it. A command
  is cut into simple commands at `;`, `&`, `|` and newlines outside quotes, in one pass,
  after a backslash-newline is deleted, as Bash does. A rule is tried only if all its
  parts occur somewhere, and then only on the simple commands that hold its first part;
  osc's subcommand is found by walking the words of every osc call (split at blanks,
  backquotes, `$`, parentheses and braces) past at most sixteen global options, an
  abbreviated `--apiurl`, `--config` or `--setopt` taking its value, not by a regex; and a
  text over 64 KB is refused unread. The suite times every regex part on 64 KB of
  pathological input (the slowest takes 0.02 s) and the hook on its worst cases, the
  slowest about 0.35 s, so a long command cannot outrun the timeout. Earlier
  versions took 16 s on 63 KB of `osc sr tea pr`, 10 s or more on `-H` and a run of
  spaces or on `git-credential-` repeated, and over 30 s on a run of osc global options.
- Kimi runs a hook in its own process directory, which an ACP or web session need not
  share; the hook also resolves relative paths against the session's `workDir` from
  `session_index.jsonl`, skipping a line cut short by a concurrent write, and resolves
  each word of a Bash command against the call's `cwd`, or, without one, against every
  directory the session may run in.
- It matches text: a variable, `cd` into a directory and a relative name, a glob, `eval`,
  `python3 -c` or a script written first and run later get past it. It errs the other way
  too: a Grep rooted at the home directory, `~/.config`, `~/.local` or `/` is refused, and
  `tea` or `git obs` with `pr` and the word `merge` anywhere in one command.
- MCP arguments are checked only under keys that look like a path, URL or command; one
  under a path, directory, root or scope key is also refused when the credentials lie
  below it.

## The pool PR guard

The guard keeps every agent from opening, updating or merging a `pool/` PR on
src.opensuse.org outside `pool-pr.sh` (through `tea`, `git-obs` or `git obs`, or the API),
merging any other src.opensuse.org PR the same ways (`gh` is not judged; a merge URL on a
pool or unnamed repository is refused however it is sent, and elsewhere counts unless the
call provably only reads), pushing to a branch that heads an open pool PR, writing a
`target-gate.sh` stamp, running an emulated `osc build`, filing a request against the
scmsync'd `openSUSE:Backports:SLE-16.x` projects, filing a submit request with
`--nodevelproject`, a request through the API (`/request?cmd=create`) or one whose message
has over 300 characters of prose (every line but a `- ` list item), a list line over 100
characters or over 1000 in all (read from `-m`, `-F`, stdin, a variable or an
`echo`/`printf`/`cat` substitution; one it cannot read is refused), or writing into a
`*:Update` or `*:Maintenance:*` project outside `home:` (a commit, an `osc api` write or
another direct write such as `branch`, `copypac`, `rdelete`, `repo add` or a `meta` write)
or one it cannot place. A `-h`/`--help` call of `tea`, `git-obs`, `git` or `osc` is not
judged, and a refusal redacts the credentials it would echo (URL userinfo,
`Authorization`/`Bearer` values, `token=`).

On the agent's own commands (not the scripts or program code they run) it also refuses
reading a credential file — tea's, osc's, gh's, netrc, git's credential store, osc's
cookie jar, an MCP server's `api-key` — other than by `ls`, `stat` or `test` or a grep for
one `build-*` setting; setting or running an askpass program; the tools' own secret
printers (`gh auth` token/status/git-credential, `tea login` helper/edit, `git-obs login
list`, git's credential `fill`/`get`, `secret-tool` lookup/search, osc's `--dump-full`,
HTTP debugging, `token` and `config … pass`); a credential on the command line of `curl`,
`wget`, HTTPie, `tea api`, `git-obs api` or git; and `curl`, `wget` or HTTPie calls to the
OBS or Gitea API, which `osc api` and `git-obs -G src.opensuse.org api` make with their own
logins. This backs the snippets' deny patterns above with the guard's parsing: a path is
resolved through the call's cwd, values, brace expansions, globs and symlinks, and a tool
through its wrappers (`xargs -a` and GNU `parallel` inputs included), variables and
options. The Read tool stays with the snippets.

| File | Goes to | Does |
|---|---|---|
| `scripts/pr-guard.py`, `scripts/_pr_guard.py` | `~/.claude/hooks/` | the guard: `pr-guard.py` runs the prefilter, and reads its rules from `_pr_guard.py` beside it only on a match |
| `claude/pr-guard-hook.json` | its `hooks` entry into `~/.claude/settings.json` | a PreToolUse hook on `Bash\|Monitor\|Write\|Edit`; the deny rules of `claude/settings.json` keep the Edit and Write tools off the hook and harness config |
| `opencode/pool-pr-guard.ts` | `~/.config/opencode/plugins/pool-pr-guard.ts` | the same guard for opencode 1.x: prefilters in TypeScript, spawns the guard only on a match, refuses the call when it exits non-zero |
| `opencode-v2/pool-pr-guard.ts` | the same target, instead of the 1.x file | the same for opencode 2.x, on its plugin API (`execute.before` hook of the `shell`, `write` and `edit` tools) |
| `opencode/opencode.jsonc` | merged into `~/.config/opencode/opencode.jsonc` | a pattern backstop: deny PR merges, ask on PR creates, each `git-obs` pattern also spelled `git obs` |
| `opencode-v2/opencode.jsonc` | appended to the `permissions` array of the same file, instead of the 1.x block | the same backstop in 2.x's array form |

Both harnesses run one **pinned copy** of the guard. It is not updated with the skill:
the guard polices the skill's own scripts, so a change to it is a decision, not a pull.

## Install the guard

Wait until the branch that brought this guard is merged into `origin/main` **and** the
skill checkout has fetched it (`git -C <checkout> fetch origin`). The guard runs the
checkout's scripts unread once they match `origin/main`. Until the merge, that is the old
`leap-sync.sh`, which pushes and opens or updates pool PRs itself with no gate, and a
`git stash` or `checkout main` in the checkout would bring it back.

1. Pin the guard, both files:

   ```
   install -D -m 0444 -t "$HOME/.claude/hooks" skills/opensuse-packaging/scripts/pr-guard.py skills/opensuse-packaging/scripts/_pr_guard.py
   ```

   To update it later, read `diff -u` of each installed file against the skill's copy
   first, then re-run the `install`. Without `_pr_guard.py` every call the prefilter
   matches is refused.

2. Claude Code: once step 1 is done, add the PreToolUse entry of
   `claude/pr-guard-hook.json` to `hooks.PreToolUse` in `~/.claude/settings.json`, next to
   the existing entries, and the rules of `claude/settings.json` to `permissions.deny`.
   Then delete any allow rule that pre-approves pool PR traffic from the project settings
   (`.claude/settings.local.json`): `tea pr create --repo pool/...`, `curl -X POST` to
   `.../repos/pool/...`. A hook's refusal wins over an allow rule, but an allow rule for
   exactly the guarded call says the opposite of the policy.

3. opencode: take the files for your version (`opencode --version`), 1.x or 2.x, never
   both: neither version loads the other's plugin, and both go to the same target. On 1.x:

   ```
   install -D -m 0444 contrib/harness/opencode/pool-pr-guard.ts "$HOME/.config/opencode/plugins/pool-pr-guard.ts"
   ```

   On 2.x:

   ```
   install -D -m 0444 contrib/harness/opencode-v2/pool-pr-guard.ts "$HOME/.config/opencode/plugins/pool-pr-guard.ts"
   ```

   Merge the matching snippet into `~/.config/opencode/opencode.jsonc`: its `permission`
   block on 1.x, its `permissions` entries at the end of that array on 2.x. On 1.x,
   restart every running opencode TUI: a running one keeps the plugins it started with. On
   2.x the service holds the plugins: `opencode service restart`. A plugin file removed
   from the plugins directory was still listed 12 s later, and right after a restart
   `opencode plugin list` says "No plugins found" for several seconds (measured), so ask
   again until it lists the ID `opensuse-packaging.pool-pr-guard`. If it never does, or
   lists the file with the ID `-` (a plugin that failed to load, such as the 1.x file),
   the guard is not wired.

4. The guard runs the scripts of the skill checkout's `scripts/` unread only **as
   merged**. Every file that `scripts/` tracks, in the index or at the pinned ref, must
   hash (`git hash-object --no-filters`) to its blob at `refs/remotes/origin/main` of that
   checkout (not `HEAD`). The scripts run their siblings, so one edited, added or dropped
   file untrusts them all, and so does a call that writes into `scripts/`. A script must
   also be run by its path and get no environment change but `TMPDIR`, `LC_ALL`, `LANG`,
   `NO_COLOR` and `CHANGES_AUTHOR`. A local edit or an unmerged commit is read like any
   other script, which for `pool-pr.sh` means refused, until it is merged and fetched
   (`git -C <checkout> fetch origin`). Sourcing one, or feeding it on stdin, is refused:
   the scripts find their siblings from their own path. The guard finds the checkout at
   `~/.claude/skills/opensuse-packaging`, then `~/.agents/skills/opensuse-packaging`;
   export `PR_GUARD_SKILL_DIR` in the harness's environment if it lives elsewhere, and
   `PR_GUARD_PIN_REF` to pin another ref. An installer copy that is not a git checkout
   has no pinned ref, so its scripts are read like any other.

## What reaches the guard

The prefilter matches any path, `tea`, `git-obs` or `git obs`, `src.opensuse.org`, `push`,
`send-pack`, `target-gate`, `osc`, a shell or interpreter, `. FILE`, a command named by a
variable (`$OSC ci`), and for the credential rules `gh`, `credential`, `secret-tool`,
`netrc`, `oscrc`, askpass, `Authorization`, `curl`, `wget`, `http`/`https` and `xh`, each
also read with its quotes and backslashes dropped (`o''sc`): a file a command runs is where
a POST hides. A command named by a variable is judged as the tool its value names; one
only the shell knows as every guarded tool, and as osc only when the variable is named for
it. A call whose working directory is inside a `target-gate` directory, or a directory of
credential files (tea's, osc's, gh's, an MCP server's, osc's state), is judged too. The
rest of the command line decides nothing.

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
- running a skill script adds three git queries;
- the credential rules left an unmatched call as it was and added ~20 ms to a matched
  one, measured side by side with the guard before them (~66 ms and ~160 → ~181 ms on
  that run): `_pr_guard.py` grew by a sixth, and compiling it is most of the cost.

## Smoke test

Safe: nothing is run, only judged.

```
for owner in pool AI; do
  printf '{"tool_name": "Bash", "cwd": "/", "tool_input": {"command": "true || tea pulls create --repo %s/zzz --title t"}}' "$owner" \
    | python3 "$HOME/.claude/hooks/pr-guard.py"; echo "rc=$?"
done
```

`pool` prints `BLOCKED [create-tea]` and `rc=2`; `AI` prints `rc=0`. Then, in each
harness, ask the agent to run `true || tea pulls merge --repo AI/zzz 1`: the call must
be refused with the guard's message, as a merge is on any repository. The `pool/zzz`
create must be refused too, the `AI/zzz` create must run, and so must
`echo "tea pulls merge --repo pool/zzz 1"`, which only prints the words.

## How a refusal travels

- Claude Code blocks a call only on **exit 2** and hands the model the guard's stderr.
  Any other non-zero exit is a non-blocking error, so the guard turns every failure
  after a match (an unresolvable remote, a failed PR lookup, a missing `_pr_guard.py`,
  a crash) into exit 2.
- Claude Code runs a call unjudged when the hook is killed at its `timeout` (60 s in
  `claude/pr-guard-hook.json`) or cannot start: `python3` missing is exit 127, a
  non-blocking error, as the Kimi hook fails open on its timeout. So the open-PR lookups
  of one call stop at 40 s in all and refuse the call past that.
- The opencode plugins throw on any non-zero exit, on their own 60 s timeout, and when
  `python3` or the pinned guard cannot be spawned: they fail closed. On 2.x the thrown
  message reaches the model verbatim, and a missing `python3` and a missing guard script
  were both refused (measured). That refuses only calls that matched the prefilter; the
  rest never reach the guard.

## Limits

- In Claude Code a hook killed at its 60 s timeout, or a missing `python3`, lets the call
  run unjudged. Only the open-PR lookups share a 40 s budget; the git queries a push
  needs (10 s each) are not budgeted. The opencode plugins refuse in both cases.
- Trust in the skill's scripts is trust in the checkout's `origin/main`: moving that ref
  by hand (`update-ref`, a fetch from another remote) re-blesses whatever it names.
- A script run by bare name from `PATH` is not read, nor a program held in a variable
  the call does not set or made by a substitution (`$CMD`, `eval "$CMD"`,
  `bash -c "$(cat F)"`).
- After a `cd` to a variable the call did not set, or to a `$(...)`, the working
  directory is unknown (values the call set, a loop's words and globs are followed; a
  variable a loop reassigns holds all its values; `read`, `mapfile`, `printf -v` and
  `declare -n` leave it unknown): a push, an unnamed `tea` or `git-obs` call, an
  `osc commit`, or a script run by relative path is refused.
- A heredoc written into a file is not read when it is written; only the Write and
  Edit tools' content is. The file is read by a later call that runs it; the call that
  writes it cannot run it (`exec-written`).
- The Claude Edit and Write denies stop those tools, not a shell command that edits the
  same files.
- A push through a helper is not seen: a Python `def git(*a)`, a shell function
  `g() { git "$@"; }`, `git -c alias.x=push x`.
- A pulls URL assembled without a literal `/pulls` (`base + 'pulls'`, `urljoin`,
  `"${API}pulls"`) is not seen, nor a request body set after construction
  (`r.data = ...`).
- Perl's LWP and HTTP::Tiny requests are not seen, and `ruby`, `bun`, `deno` and `php`
  programs are not read.
- Commands run through `flock` or `script` are not unwrapped, and words `xargs` reads
  from stdin are not seen (`echo B | xargs git push fork` is
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
- A PR create's repository held in a program variable (`["tea", ..., "--repo", R]`) is
  judged by the clone's remotes. An f-string is judged by its literal owner:
  `f"pool/{pkg}"` is pool, `f"{o}/{pkg}"` is unknown and refused. A merge is refused on
  any repository.
- A request body option (`--json`, `--data`, `--form`, `--upload-file`) counts only on
  a `curl`, `wget` or `tea api` line, or in the argument list that names the tool. One
  added to that list later (`cmd += ["--json", body]`) is not seen.
- git's arguments are not judged for stamps, so git writing into a stamp directory
  itself (`--work-tree`, `--output`) is not seen; a redirection is.
- The opencode plugins do not send `patch`/`apply_patch` tool calls to the guard. On 2.x the
  model ids `gpt-5` and `gpt-5.1-codex` were offered `patch` (one `patchText` argument) in
  place of `write` and `edit` (measured with a stub provider), so for such a model nothing
  of the Write and Edit judgement applies.
- A merge through the pulls API is judged whatever its host; `gh` is not judged, so
  `gh pr merge` on a GitHub repository runs. A curl or wget request whose URL or method
  comes from a config file (`-K`, `--next`, a wgetrc) is not seen.
- Braces are expanded in every word of a command that may read, quoted ones too (the parser
  has dropped the quotes by then), so a quoted `{…}` can only refuse more: one past 64
  words, or a braced word over 1 KB, is refused as unknown.
- The credential rules read the agent's own commands only. A script's body, program code
  (`python3 -c`, a heredoc fed to Python) and Write/Edit content are not scanned for
  them, and the Read tool is left to the snippets. Nor are a credential file named by a
  variable the call does not set, one read where the guard cannot place the directory
  (but for `oscrc` and `cookiejar`), words `xargs` reads from stdin, an API URL passed
  through a shell function's arguments, or a recursive search with no path in a call the
  prefilter lets through.
- A script that runs its own arguments (`"$@"`) is not followed, and `"$@"` or an array
  in a script's command position is its arguments, not judged; on the call's own command
  line an unknown one is refused.
- The prefilter reads the text as written and with its quotes and backslashes dropped:
  a command name only an expansion spells (`${X:-osc}`, `$(echo osc)`) is not seen.
- Request messages are measured on osc command lines only: not in program code running
  osc, and not in PR descriptions (`tea`, `git-obs`). A message another program writes, a
  printf width or reused format, or a brace expansion is refused as unknown.
- The maintenance rule reads osc command lines only, not program code running osc, and
  covers the direct writes it names, not every osc subcommand that writes: `rebuild`,
  `restartbuild`/`abortbuild`, `service remoterun` and `meta prjconf`/`attribute`/`pattern`
  are among those it does not judge.
