# Agent container

One image holding opencode 2.x, this skill, its guards and the tools the skill calls. The
agent works inside the container, and so does the opencode client you talk to it through:
the host lends it a terminal. A draft, like the rest of `contrib/`.

| File | What it is |
|---|---|
| `Dockerfile` | the image, built by OBS from this repository |
| `opencode.json` | what the container adds to `../harness/opencode-v2/opencode.jsonc`: the MCP servers and the denies around opencode's own server and credentials |
| `image-check` | the last build step: a failure leaves no image |
| `skill-container` | the launcher you run on the host |

## What the image holds

- opencode, with `/etc/opencode` as its managed configuration: the harness permission
  rules, both guard plugins, the skill, one sub-agent per playbook in `agents/`.
- `pr-guard.py` and `bug-guard.py` where the plugins look for them, byte-identical to the
  skill's copies.
- osc, git-obs, tea, gh, spec-cleaner, rpmlint, rpmcrab, rpmdevtools, git, ssh, jq, curl,
  wget and the source services `source_validator`, `download_files`, `obs_scm`, `tar`,
  `recompress`, `set_version`, `format_spec_file`, `node_modules`, `cargo_vendor`,
  `go_modules`, with the cargo and go those two call, and `obs_scm_bridge`, which osc
  needs to check out a package kept in git.
- Three MCP servers: bugzilla (bugwarden), memory, sequentialthinking.

What the image holds under `/etc/opencode` and `/home/agent` is owned by root, and the
agent runs as your user on a read-only root file system: the files that hold its rules are
out of its reach. What is mounted there when the container starts is the agent's: the
volumes, the cache, the logins. So is the server that applies the rules, see "Limits".
`OPENCODE_DISABLE_PROJECT_CONFIG=1` is set because a project's `opencode.json` can unload a
plugin of the managed configuration.

Not in the image: a build root (`osc build` does not work, so packages are built by OBS,
`references/update-build.md` "Build modes") and podman. gcc, clang, cargo and go are there
for the two vendoring services.

## Run it

On the host: rootless podman, osc, gh, jq, a `python3` that imports `osc` and
`ruamel.yaml` without `PYTHONPATH` and your user site directory (the launcher starts it
with `-I`), and working logins for osc (api.opensuse.org), tea (src.opensuse.org), gh
(github.com), the bugzilla MCP server and one opencode model integration. opencode 2.x is
needed there by `secrets` alone, which asks it for that login. The launcher runs its own
commands in `/` and takes them from `/usr/local/bin:/usr/bin:/bin`, whatever your `PATH`
holds; `SKILL_CONTAINER_PATH` names other directories. The rest of your environment
reaches them as it is: see "Limits". Only that opencode is looked up on your `PATH` and
runs with it, in `/`; `OPENCODE` names another by its absolute path. A relative
`--workdir`, `--memory` or `--bugzilla-key` is read against the directory you started the
launcher in.

```
skill-container secrets --model-auth <integration>
skill-container up --workdir ~/obs/work [--memory FILE] [--image IMAGE]
                   [--model provider/model]
skill-container attach [--continue | --session ID]
skill-container run [--continue | --session ID] <message>
skill-container down
```

- **`secrets`: run it yourself, never from an agent.** It copies into podman secrets the
  api.opensuse.org login of osc (read through osc, so a keyring works), the
  src.opensuse.org logins of tea, the github.com login of gh (read through gh, likewise),
  the Bugzilla API key file and what `opencode auth export <integration>` prints. It
  prints the five secret names. No other server's login is copied. Which GitHub token
  the agent gets is yours to choose: `secrets` copies the one gh uses where you run it.
  That is your host login's, with all its scopes, unless `GH_CONFIG_DIR` names another
  gh config directory, whose login is then the one copied, or `GH_TOKEN` or
  `GITHUB_TOKEN` holds a token, which then replaces the stored one. For a narrower
  token, log in with it into a gh config directory of its own and name that directory
  when you run `secrets`. The secrets are replaced one by one: after
  a failure, run it again. An API-key integration is the plain case. An account login
  (OAuth) is copied as `opencode auth export` prints it at that moment: host and
  container then each renew it on their own. Tried once: after an hour of sessions in
  the container the host's login still answered. No renewal fell into that hour, so
  whether both outlast one is not known. If one stops, log in again on the host and run
  `secrets`, `down` and `up`.
  Name the integration whose login serves the model's
  provider: opencode can serve a provider through another integration's login, and a
  key left under the provider's own name may be one it no longer uses, or an expired
  one. `secrets` does not try the login; the first `run` does.
  `opencode auth list` names the integrations; run it
  outside the work directory, because opencode loads the plugins of the directory it
  starts in. `secrets` does not know the work directory: run it with the `PATH` you use
  for `up`, which `up` checks, and with no `OPENCODE` that names a file the agent could
  have written.
- **`up`** starts the container on the work directory `--workdir` names, mounted at the
  same path, and waits until the server has loaded both guard plugins; if it does not, the
  container is removed. The first start takes about a minute. The server listens inside
  the container only, with no port on the host, behind a password `up` makes anew for
  each container and keeps as a sixth secret. `up` refuses a work directory that is not
  yours, your home directory, one above it, a dot-directory in it, or one that holds or
  lies in your configuration directory, your runtime directory, podman's storage or its
  volumes. It refuses one with no directory above it that is yours and closed to
  everyone else (mode 0700): the
  agent runs as you and can make a file there setuid to you, which then runs as you for
  every local user who can reach it. `~/obs/work` passes when your home directory is
  closed; a directory under `/var/tmp` passes below one you made with mode 0700. From `/`
  down to that closed directory each one must be root's or yours and take no entry from
  group or others, unless it is sticky like `/var/tmp`: whoever writes one can swap what
  lies below it. The same is asked of podman's volumes. It refuses while the container
  runs.
- **`up --memory FILE`** gives the container that memory graph to read, in place of its
  volume: the agent reads what the sessions on your host wrote there and keeps no memory
  of its own, because the mount is read-only and its writes fail. Podman mounts the
  file's directory and relabels it for containers, so `up` takes a file only when it is
  alone in its directory, outside the work directory and podman's storage and volumes,
  and holds nothing but entities and relations, and when no directory above it, as far up
  as a closed one of yours, is
  another user's or takes entries from group or others without being sticky.
- `up` refuses a work directory or a graph that a symlink leads to: name each by its real
  path. It refuses either while a running container that your `podman ps` lists, whatever
  started it, has a directory or a volume above or below it mounted for writing with
  `--volume` or `--mount`. It does not see every way a container writes the host: see
  "Limits".
- The launcher refuses a `PATH`, `LD_LIBRARY_PATH`, `LD_PRELOAD` or `LD_AUDIT` with an
  entry that is empty, a relative path or has a `.` or `..` in it, and `up`, `attach` and
  `run` one with an entry that lies in the work directory, as written or where its links
  lead: there the agent could leave a command or a library for the host to load. A
  library named without a slash in `LD_PRELOAD` or `LD_AUDIT` is taken: the loader looks
  it up in its own directories.
- **`attach`** and **`run`** start an opencode client in a second container, made from
  the image the server runs, and remove it when the client ends. Podman keeps no log of
  it: under `attach` that log would hold your screen and what you typed. It joins the
  server's network and user namespace and gets the server password and, under `attach`,
  your terminal. It gets no login, no volume and no file of yours, and an empty read-only
  directory where the work directory is: a session belongs to the directory its client
  starts in. Why the client does not run on the host is under "Limits". A permission
  that asks is answered in `attach`; `run` refuses it. `attach` needs a terminal and
  passes on `-c`, `--continue`, `-s`, `--session` and `--prompt` and no other argument:
  opencode would read a further word as a command or a directory. `run` passes on `-c`,
  `--continue`, `-s`, `--session`, `--fork`, `-m`, `--model`, `--agent`, `--format`,
  `--title` and `--thinking`, and its other words are the message. A `run` starts a new
  session; `--continue` takes the one used last and `--session` one by its id. Both
  commands refuse any other argument that starts with `-`. opencode's `--auto`, `--yolo`
  and `--dangerously-skip-permissions` answer every permission with yes and are not
  among them. Nor is `--file` of `run`: the client's container holds no file of yours.
  A value or a message that starts with `-` is refused as well: give a value as
  `--flag=value`.
  An answer of "always" is forgotten at the next `up`, `attach` or `run`: opencode keeps
  it in the state volume, which the agent writes. `run` prints the reply with control
  characters removed, colours kept, for a terminal that reads UTF-8, and gives the client
  no input; `attach` is opencode's own terminal interface: it is not filtered. The
  client starts with the `TERM` and `COLORTERM` of your environment, with
  `FORCE_HYPERLINK=0` and without your proxy settings. Its interface settings (theme,
  key bindings) are the image's and last for one `attach`: those of an opencode on your
  host do not reach it. Ctrl-Z stops the client inside its container: the interface
  leaves the screen, `attach` does not return and no key detaches it. Close that
  terminal; a client's container that outlives its `attach` stays until `down`.
- **`down`** removes the container, and a client still on it.

Sessions, the memory graph, gate stamps and `/var/tmp` live in the volumes
`opensuse-packaging-state`, `-memory`, `-toolstate` and `-scratch`: a new container, or a
newer image, continues where the last one stopped. With `--memory` the graph is your
file, read-only, and the `-memory` volume is not used. `podman volume rm` and
`podman secret rm` remove them. Your own opencode settings for the container (a default
model, an `AGENTS.md`) go into `~/.config/skill-container/opensuse-packaging/`, mounted
read-only. `SKILL_CONTAINER_NAME` (default `opensuse-packaging`) is the name all of these
start with: the container, its secrets and volumes, the default image
`localhost/NAME-agent:latest` and that directory. Another name is another set of them,
with secrets of its own.

## Limits

The container keeps the agent away from the rest of your home directory. It is not a
boundary between the agent and what is inside the container.

- **The logins are inside the container.** OBS takes nothing but the account password. The
  agent can use them, and one set on reading them can: the denies match the text of a
  command, as `../harness/README.md` says.
- **The guards catch mistakes, not an agent set on evading them.** The agent's commands run
  as the same user as the opencode server, and that server switches off every deny, every
  question and both guard plugins for whoever has its password. A command starts without
  the password, and one that names the password, a process environment, or opencode with
  `--server` or one of its server subcommands is denied. Nothing else is: opencode's other
  subcommands, which get nothing from the server without the password; `ps e` or a read
  under `/proc`, which shows the password; `curl`, which reaches the same API with it; a
  second opencode service started with its configuration elsewhere, which lists no guard
  plugin. Closing that needs the commands to run as another user than the server, which
  this image does not do.
- **The state volume holds what the agent wrote.** Its commands can write opencode's
  database. An approval saved there answers a question in every later session. Rules
  written onto a session answer every question of that session and switch off the denies
  of the configuration from its next prompt on; the guard plugins still refuse. A
  session's history can be rewritten before `--continue` loads it. `up`, `attach` and `run`
  remove the session rules they find and the saved approvals of every project the server
  lists, and stop when a list cannot be read or a rule stays. An approval of a project
  the server does not list is found only by a query opencode does not document. That
  clears what was left behind. An agent set on keeping its rules puts them back: a
  database trigger writes them onto the next session.
- **The server has no port on the host.** It listens on the loopback of the container's
  own network, behind a password `up` makes anew for each container; `podman port` lists
  nothing for it. A client reaches it from a container that joins that network, which
  the launcher starts through your podman.
- **A client runs what its server names, so the client runs in a container.** opencode's
  terminal interface asks the server for its plugin list and loads, where the client
  runs, each plugin listed there with a part for the interface. Started on the host, as
  an earlier draft of this launcher did, `attach` ran the agent's plugins as you, with
  your logins in reach and no key pressed: one left in `.opencode/plugins/` of the work
  directory and one written there after the client had started (2.2.6 and 2.2.7), and
  two in other directories of the work directory, which the server's configuration named
  (2.2.7). `run` loaded none (2.2.7). The agent has the server's password and runs as
  its user: count on it being able to make the server name what it likes.
  The launcher therefore starts no opencode on the host for `attach` and `run`. The
  client's container is made from the server's image and joins its network and its user
  namespace; it has the server password and, under `attach`, your terminal. It has a
  read-only root, no login, no volume, no file of yours, and an empty read-only
  directory where the work directory is. Started like that beside a server that listed
  two plugins in the work directory, the client (2.2.6) loaded neither, `run` answered
  and `attach` drew the session; with the work directory mounted too, it loaded both.
  Count on the agent running code in the client's container all the same. Not tried: a
  plugin the server names as a package, which the client would fetch, and whatever else
  a client takes from its server. Such code has what the client has: the server
  password, which the agent has anyway, the server's network, and under `attach` your
  terminal.
- **`attach` hands your terminal to a program the agent may steer.** Treat it like an ssh
  session to a machine you do not trust. What the client's container writes reaches the
  terminal as it is, and what you type there reaches the container. Code the agent runs
  there can draw anything: a permission dialog, a prompt that looks like your shell's
  after the client seems to have ended. It reads every key until the container is gone,
  and it sends the terminal any control sequence: in a terminal that takes them, one
  that sets the title, one that writes your clipboard, one the terminal answers with
  text that arrives as if you had typed it. None of that was tried. Type no password
  into an attached session, and when one ends in a way you did not expect, close that
  terminal. Without such code the server still drives the interface: whoever has its
  password can make `attach` run any command of the interface's own list, as if you had
  chosen it. Those that start a program (an editor for the prompt, the opener for a
  link or for opencode's documentation) start it in the client's container, not on your
  host: the client opens no browser of yours. `run` gives the client no terminal: its
  output passes the filter and it reads nothing.
- **A link in an attached session is the agent's text.**
  *Hyperlinks of the terminal.* A terminal can show a label and keep the target to
  itself, and it opens that target on its own. The client sent a terminal such links
  when the terminal named itself: through `VTE_VERSION` in the environment (with 2.2.7
  the label `https://login.example.org/session` carried an address at
  `attacker.example`), or by answering the client's question for its name (XTVERSION)
  as kitty, WezTerm or ghostty (2.2.7; with 2.2.6 only kitty was tried). The launcher
  starts the client with `FORCE_HYPERLINK=0` and, of your environment, `TERM` and
  `COLORTERM` alone. With that variable the client sent no such link in any case tried
  and drew the target after the label. That was measured with a client on the host, and
  it binds the client alone: code the agent runs in the client's container writes the
  terminal a link of its own.
  *What stays.* Your terminal may make a link of an address it sees drawn and open it
  on a gesture of its own, and you may copy one. The address is the agent's text, and
  the site a browser opens from it is not always the one it seems to name:
  `https://login.example.org:443@attacker.example/`,
  `https://attacker.example\@login.example.org/` and
  `https:attacker.example//login.example.org/` all open `attacker.example`, and a letter
  of another script can stand for a Latin one. These are examples, not a rule to read an
  address by. Treat an address in an attached session as you would one in a stranger's
  mail: in your browser it is a page the agent chose, enough for one that imitates a
  sign-in, one that asks you to approve an application or a device, or a request a site
  takes from a link alone.
- **The work directory is shared with the host, and the agent's files are yours.** The
  agent can leave there what runs when you use the directory yourself: a git
  `core.fsmonitor` or `core.hooksPath`, an `.envrc`, a spec with `%(...)`, a plugin for
  an opencode you start there. Give it a directory of its own and run nothing in it on
  the host, opencode least of all. It can also make a file setuid
  to you and open the directory to everyone: only the closed directory above, which `up`
  asks for, keeps another local user from running that file as you. Keep that directory
  closed while the work directory exists, and do not move the work directory out of it.
- **`up` checks a path and podman mounts it a moment later.** Whoever writes a directory
  above the work directory or the graph can put a link there in between, and podman
  mounts where the link leads. `up` refuses when another user can write such a directory
  or a running container that your `podman ps` lists writes it through a bind mount or a
  volume. It does not know your other processes, a container kept elsewhere (root's
  podman, another storage root, docker), what a container mounts with `--volumes-from`
  from one that is not running, the upper directory of an overlay mount
  (`:O,upperdir=`), a root file system given with `--rootfs`, or where a volume's data
  lies when you made the volume with `--opt device=`: podman names such a volume by its
  own path. With SELinux enforcing, podman relabels
  the link and not what it leads to, which the container then
  cannot read unless it carries a container label already.
- Podman keeps the secrets unencrypted under your home directory, mode 0600, like the
  tools' own config files. The state volume holds the imported model credential: treat it
  like a secret. `up` removes the model logins the server lists for the volume before it
  imports the secret's, and stops when one stays, so a new key takes effect with the next
  `secrets` and `up`. The database in the volume is the agent's to write: one set on it
  can keep a model login of its own there as the one in use, for one with a trigger that
  puts it back when the secret's is imported.
- Leap pool PRs do not work yet: the guard lets `pool-pr.sh` through only from a git
  checkout of the skill under `~/.claude/skills`, and the image has neither.
- **The GitHub token is your host login's, with all its scopes, unless you gave `secrets`
  another.** The rules deny by their text the commands that print it (`gh auth token`,
  `gh auth status`, one that names `oauth_token`); like the other logins, one set on
  reading it can. No rule looks at what `gh` does with it: the agent can do on GitHub
  what the token allows, with your host login's a push, a merge or a release included.
- **A graph given with `--memory` is read whole**: the agent sees what every project of
  yours wrote there. Nothing the agent writes reaches it. Podman's relabel of its
  directory (`container_file_t`) stays after `down`.
- **The launcher checks `PATH` and the loader's lists, nothing else of your environment.**
  A variable that names a path in the work directory can make the launcher, or a command
  it runs, load what the agent wrote there: `BASH_ENV`, `CONTAINERS_CONF`, `GCONV_PATH`,
  `LOCPATH` and the like. Python's own variables are the exception, because of `-I`.
  Start the launcher outside the work directory: the shell that reads it has loaded its
  libraries before the first check runs. An entry that reaches its directory through a
  link in the work directory that leads out again is not found, and the agent can turn
  that link.
- Nothing limits where the container connects to.

## Build

OBS builds the image; a failed `image-check` fails the build. The project needs, for the
repository that builds it (here `containers`):

```
%if "%_repository" == "containers"
Type: docker
Repotype: none
Patterntype: none
BuildEngine: podman
Required: iproute2
%endif
```

`Required: iproute2` is there because the build brings the loopback interface up only when
the build root has `ip`, and `image-check` starts a server on it. The repository takes its
base image from `openSUSE:Containers:Tumbleweed` and its packages from
`openSUSE:Tumbleweed`. `mcp-server-memory` and `mcp-server-sequential-thinking` are built
by `modelcontextprotocol-servers`, new in Factory in November 2026: until a snapshot
carries it, add a repository that does.

The package holds one `_service`, pinned to a commit of this repository:

```xml
<services>
  <service name="obs_scm">
    <param name="scm">git</param>
    <param name="url">https://github.com/openSUSE/openSUSE-packaging-skill.git</param>
    <param name="revision">COMMIT</param>
    <param name="filename">skill</param>
    <param name="version">_none_</param>
    <param name="extract">contrib/container/Dockerfile</param>
    <param name="extract">contrib/container/opencode.json</param>
    <param name="extract">contrib/container/image-check</param>
  </service>
  <service name="tar" mode="buildtime"/>
</services>
```

A new skill release reaches the image by moving `revision`; a changed package in
Tumbleweed rebuilds it without anyone asking.

`podman run --rm --network=none IMAGE image-check` repeats the check on a built image.
