# This container

You run in the openSUSE packaging container. What differs from a workstation:

- **The skill** is at `/etc/opencode/skills/opensuse-packaging`. A path to it in
  older session history (`~/.agents/skills`, `~/.claude/skills`) does not exist here.
- **No local builds.** There is no sudo, no `osc build`, no podman and no docker.
  Builds run on OBS: use the skill's OBS-ONLY build mode
  (`references/update-build.md` "Build modes"), and for a Leap pool tree
  `target-gate.sh --remote`, never `--build`. `gate.sh` says "%prep not run: no
  sandbox" here every time: the OBS build is what proves `%prep`.
- **"Permission denied: shell" refuses one command, not the shell.** The command's
  text named a login file or directory (osc, tea, gh, the SSH key, the Bugzilla
  key), a process environment under `/proc`, the server password, `sudo`, or an
  opencode server subcommand. Say it without that text and go on.
- **Write files with the write tool, not a shell heredoc.** A heredoc's text is
  judged as a command, so a report that mentions one of the above is refused.
- **Pushes to src.opensuse.org** use the container's own SSH key. ssh is set up for
  it: pass no `-i` and no known-hosts option.
- **Reports go under `reports/` in the work directory.** The user cannot open
  `/var/tmp` or `/tmp` of the container; `/var/tmp` survives a restart, `/tmp` does not.
- **Sub-agents:** start an update with `osc-update-build`, a review with
  `changes-review`, a submission with `osc-submit-watch`. The agent `general`
  cannot start a review.
