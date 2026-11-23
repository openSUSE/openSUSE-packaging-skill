#!UseOBSRepositories
#!BuildTag: opensuse-packaging-agent:latest

# skill.tar holds this repository under skill/.
FROM opensuse/tumbleweed:latest AS src
ADD skill.tar /src/

# geectl is not shipped on OBS: build it from its git source in a builder stage
# and copy only the binary into the final image; the toolchain stays out of it.
FROM opensuse/tumbleweed:latest AS geectl
RUN zypper -n in --no-recommends cargo gcc git \
    && zypper clean -a
RUN cargo install --root /usr/local --locked \
        --git https://github.com/scarabeusiv/geectl --rev b22368d

FROM opensuse/tumbleweed:latest

LABEL org.opencontainers.image.title="openSUSE packaging agent"
LABEL org.opencontainers.image.description="opencode with the openSUSE-packaging skill, its guards and the tools it calls"
LABEL org.opencontainers.image.source="https://github.com/openSUSE/openSUSE-packaging-skill"

RUN zypper -n in --no-recommends \
        opencode python3-ruamel.yaml gitea-tea gh bugwarden spec-cleaner rpmlint \
        obs-service-source_validator obs-service-download_files obs-service-obs_scm \
        obs-scm-bridge \
        obs-service-tar obs-service-recompress obs-service-set_version \
        spec-cleaner-format_spec_file obs-service-node_modules obs-service-cargo \
        obs-service-go_modules rpmcrab rpmdevtools wget \
        git-core openssh-clients python3-base jq curl hostname procps socat \
        mcp-server-memory mcp-server-sequential-thinking \
    && zypper clean -a

COPY --from=src /src/skill/contrib/harness/opencode-v2/opencode.jsonc /etc/opencode/
COPY --from=src /src/skill/contrib/harness/opencode-v2/pool-pr-guard.ts \
                /src/skill/contrib/harness/opencode-v2/bug-guard.ts /etc/opencode/plugins/
COPY --from=src /src/skill/skills/opensuse-packaging/ /etc/opencode/skills/opensuse-packaging/
COPY --from=src /src/skill/skills/opensuse-packaging/scripts/pr-guard.py \
                /src/skill/skills/opensuse-packaging/scripts/_pr_guard.py \
                /src/skill/skills/opensuse-packaging/scripts/bug-guard.py /home/agent/.claude/hooks/
COPY --from=src /src/skill/contrib/container/CONTAINER.md /etc/opencode/
COPY --from=src /src/skill/contrib/container/ssh_known_hosts /etc/ssh/ssh_known_hosts
COPY --from=src /src/skill/contrib/container/ssh_config /etc/ssh/ssh_config.d/50-src-opensuse.conf
COPY --from=geectl /usr/local/bin/geectl /usr/local/bin/geectl
COPY opencode.json /etc/opencode/
COPY image-check /usr/local/bin/

# opencode drops an agent file whose frontmatter it cannot read, and the playbooks
# carry another harness's: each gets a wrapper that points at it.
RUN set -eu; skill=/etc/opencode/skills/opensuse-packaging; mkdir /etc/opencode/agent; \
    for f in "$skill"/agents/*.md; do \
        name=$(sed -n '2,/^---$/s/^name: //p' "$f"); \
        { echo ---; sed -n '2,/^---$/{/^description: /p}' "$f"; echo "mode: subagent"; \
          grep -q '^tools:.*Edit' "$f" || printf 'permission:\n  edit: deny\n'; \
          echo ---; \
          echo "Read $f in full, then follow it exactly."; \
          echo "The skill root, the base of every scripts/ and references/ path in it, is $skill."; \
        } > "/etc/opencode/agent/$name.md"; \
    done

# pr-guard takes the skill's scripts for the real ones only as a git checkout at
# its pinned ref, and only those may write a gate stamp or open a pool PR. The
# copy becomes such a checkout, which the agent cannot write; git reads a
# repository of another owner only when the system config names it.
RUN set -eu; skill=/etc/opencode/skills/opensuse-packaging; \
    git -C "$skill" init -q -b main; \
    git -C "$skill" add -A; \
    git -C "$skill" -c user.name=image -c user.email=image@localhost commit -q -m image; \
    git -C "$skill" update-ref refs/remotes/origin/main HEAD; \
    printf '[safe]\n\tdirectory = %s\n' "$skill" > /etc/gitconfig

# A push to github.com over https takes the gh login the container was given, and
# no other host gets it. `gh auth setup-git` would write this into a home that is
# read-only here.
RUN printf '[credential "https://github.com"]\n\thelper =\n\thelper = !/usr/bin/gh auth git-credential\n' >> /etc/gitconfig

# The agent runs as the caller's user: nothing baked here may be writable by it.
# geectl keeps no state or trusted-certs directory, so nothing of its own needs
# pre-creating here.
RUN mkdir -p /work /home/agent/.config/tea \
        /home/agent/.config/mcp-bugzilla /home/agent/.config/opencode \
        /home/agent/.local/share/mcp-memory /home/agent/.config/gh \
        /home/agent/.config/git /home/agent/.ssh \
    && echo 'version: "1"' > /home/agent/.config/gh/config.yml \
    && echo 'unset OPENCODE_PASSWORD' > /etc/opencode/shell-env \
    && chown -R root:root /etc/opencode /home/agent /usr/local/bin/image-check \
    && chmod -R a+rX,go-w /etc/opencode /home/agent \
    && chmod 0644 /etc/ssh/ssh_known_hosts /etc/ssh/ssh_config.d/50-src-opensuse.conf \
    && chmod 0755 /home/agent /usr/local/bin/image-check

# BASH_ENV: the server runs each command in a bash, which reads that file first
# and so starts without the server password.
ENV HOME=/home/agent \
    BASH_ENV=/etc/opencode/shell-env \
    MEMORY_FILE_PATH=/home/agent/.local/share/mcp-memory/memory.jsonl \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_PROJECT_CONFIG=1 \
    OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 \
    PR_GUARD_SKILL_DIR=/etc/opencode/skills/opensuse-packaging
WORKDIR /work

RUN image-check

CMD ["opencode", "serve", "--hostname", "127.0.0.1", "--port", "4096"]
