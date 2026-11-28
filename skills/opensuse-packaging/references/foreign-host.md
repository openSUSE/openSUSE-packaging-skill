# Running the skill off openSUSE

The skill was developed and tested on openSUSE, where `spec-cleaner`,
`rpm`, the `build` script and the OBS source services are system packages
(and `geectl` is installed with `cargo install geectl`). On
another distro the packaging rules are unchanged, but the environment needs
three adjustments. Nothing here alters the openSUSE path.

## Tool discovery

The bundled `scripts/` are being switched to bare `geectl` (that switch lands as its own layer), and the skill assumes bare
`spec-cleaner` and `git-obs`. If the toolchain lives outside the default
`PATH` (a venv, `~/.local/bin`), export it first — every script call and every
sub-agent brief inherits it:

`export PATH="$HOME/.local/bin:$PATH"`

A tool that is genuinely missing must be installed, not worked around.

## Source services on a foreign host

`geectl local-build build` and `geectl commit` run the project's `localonly` source services
(e.g. `format_spec_file` on `home:*:branches:*` projects). A `format_spec_file`
service is satisfied by the `spec-cleaner-format_spec_file` package:
`references/spec-cleaner.md` "Checking a spec file". When the matching
`obs-service-*` package is not installed on the host, the local build does not
need it — `geectl local-build build` runs the services in the container — and
`geectl commit --noservice` skips the services a commit would run. The services are a local
convenience, not part of the build — and the spec-cleaner pass in the core
directive already covers the formatting the service would do.

## Containers

`geectl local-build build` needs working device nodes in the build root. In a container where
`mknod` is blocked, the build needs the host devices available — without them,
`configure`-style feature tests misdetect a broken `/dev/null`.
