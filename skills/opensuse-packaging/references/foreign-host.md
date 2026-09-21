# Running the skill off openSUSE

The skill was developed and tested on openSUSE, where `osc`, `spec-cleaner`,
`rpm`, the `build` script and the OBS source services are system packages. On
another distro the packaging rules are unchanged, but the environment needs
three adjustments. Nothing here alters the openSUSE path.

## Tool discovery

The bundled `scripts/` call bare `osc`, and the skill assumes bare
`spec-cleaner` and `git-obs`. If the toolchain lives outside the default
`PATH` (a venv, `~/.local/bin`), export it first — every script call and every
sub-agent brief inherits it:

`export PATH="$HOME/.local/bin:$PATH"`

A tool that is genuinely missing must be installed, not worked around.

## Source services on a foreign host

`osc build` and `osc commit` run the project's `localonly` source services
(e.g. `format_spec_file` on `home:*:branches:*` projects). When the matching
`obs-service-*` package is not installed on the host, osc aborts demanding it;
pass `--noservice` to both commands instead. The services are a local
convenience, not part of the build — and the spec-cleaner pass in the core
directive already covers the formatting the service would do. This is the same
reason `osc service runall` stays forbidden:
`references/source-services.md` "Service modes decide what you run AND what
you commit".

## Containers

`osc build` needs working device nodes in the build root. In a container where
`mknod` is blocked, the build script bind-mounts the host devices once it
detects the container — `touch /run/.containerenv` (or `/.dockerenv`) is the
signal. Without it, `configure`-style feature tests misdetect a broken
`/dev/null`.
