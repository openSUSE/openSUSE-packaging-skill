# This container

You run in the openSUSE packaging container. What differs from a workstation:

- **The skill** is at `/etc/opencode/skills/opensuse-packaging`. A path to it in
  older session history (`~/.agents/skills`, `~/.claude/skills`) does not exist here.
- **Builds run in containers.** A local build is `geectl local-build build`: geectl builds the package in a podman container (its one build vertical). The podman that spawns the build container lives on the host, where the work directory is shared, so a local build runs on the host. From here, builds run on OBS: use the skill's OBS-ONLY build mode (`references/update-build.md` "Build modes"), and for a Leap pool tree `target-gate.sh --remote`, never `--build`. `gate.sh` says "%prep not run: no sandbox" here every time: the sandbox needs user namespaces, which do not exist inside a container, so from here the OBS build is what proves `%prep`.
- **"Permission denied: shell" refuses one command, not the shell.** The command's
  text named a login file or directory (geectl, tea, gh, the SSH key, the Bugzilla
  key), a process environment under `/proc`, the server password, `sudo`, or an
  opencode server subcommand. Say it without that text and go on.
- **Write files with the write tool, not a shell heredoc.** A heredoc's text is
  judged as a command, so a report that mentions one of the above is refused.
- **Pushes to src.opensuse.org** use the container's own SSH key. ssh is set up for
  it: pass no `-i` and no known-hosts option.
- **Reports go under `reports/` in the work directory.** The user cannot open
  `/var/tmp` or `/tmp` of the container; `/var/tmp` survives a restart, `/tmp` does not.
- **Sub-agents:** start an update with `geectl-update-build`, a review with
  `changes-review`, a submission with `geectl-submit-watch`, the review of a
  contributor's submission with `incoming-review`. The agent `general`
  cannot start a review.
- **No accept, approval or decline of a contributor's submission here.** The
  guard refuses every call it would ask the user about: post the recorded
  comment, then report the item as waiting for the user's go, which they give
  on the host.
