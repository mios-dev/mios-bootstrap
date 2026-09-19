# AI-hint: Defines the Fedora-based development container for mios-bootstrap,
# the interactive installer and user-editable overlay layer. Carries the shared
# MiOS dev toolchain plus what this repo's shell installers, TOML SSOT and
# smoke tests need to run and lint.
# AI-related: mios-dev, install.sh, mios.toml
#
# This is the DEVELOPMENT container for editing this source tree. It is not the
# OS image (that is mios.git's Containerfile) and not the MiOS-DEV builder VM.
# Fedora is pinned rather than floating on :latest so the image name and the
# container's contents cannot drift apart, per the repo's pinning convention
# (newest stable upstream, bumped forward on next touch).
ARG FEDORA_VERSION=44
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION}

# Shared MiOS dev toolchain (kept in step with the mios.git and -dev-loop
# devcontainers), plus this repo's own needs: ShellCheck for the installers,
# python3 for the TOML SSOT (tomllib is stdlib), podman/skopeo for the build
# handoff, rsync for the overlay merge.
RUN dnf install -y --setopt=install_weak_deps=False \
        git jq yq rsync curl wget \
        python3 python3-pip \
        nodejs npm \
        sudo zsh \
        ShellCheck \
        podman skopeo \
        findutils grep sed gawk diffutils patch \
        ripgrep tar gzip unzip zip \
        util-linux openssl \
    && dnf clean all

# Agent CLIs available by default: the Claude Code CLI system-wide here, and
# the Antigravity CLI (agy) plus the dev-loop skill per-user at postCreate,
# by delegating to -dev-loop's own setup script rather than duplicating it.
RUN npm install -g @anthropic-ai/claude-code

# Non-root user with passwordless sudo, matching mios.git's devcontainer so the
# two repos present the same account. visudo -cf fails the build on a malformed
# rule rather than shipping one that silently grants nothing.
RUN useradd -m -u 1000 -s /usr/bin/zsh mios-dev \
    && echo "mios-dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/mios-dev \
    && chmod 0440 /etc/sudoers.d/mios-dev \
    && visudo -cf /etc/sudoers.d/mios-dev

ENV MIOS_DEVCONTAINER=1

# The Antigravity CLI is baked into the image rather than left to postCreate.
# Two reasons postCreate could not be trusted: a Codespaces prebuild does not
# re-run postCreateCommand for codespaces created from that prebuild, and the
# dev-loop checkout agy used to come from lives in a PRIVATE repo that a public
# repo's codespace token cannot clone -- so it failed silently behind `|| true`.
#
# Guarded on purpose: a transient network failure must degrade to a warning,
# never fail the image build. A failed devcontainer build drops Codespaces into
# a recovery container with nothing installed at all, which is far worse.
USER mios-dev
RUN set -u; tmp="$(mktemp -d)"; \
    if curl -fsSL --retry 4 --retry-delay 2 https://antigravity.google/cli/install.sh -o "$tmp/install.sh" \
       && [ -s "$tmp/install.sh" ] && bash "$tmp/install.sh" >/dev/null 2>&1; then \
         /home/mios-dev/.local/bin/agy --version; \
    else \
         echo "WARNING: Antigravity CLI not installed at build time" >&2; \
    fi; \
    rm -rf "$tmp"
ENV PATH="/home/mios-dev/.local/bin:${PATH}"

WORKDIR /mios-bootstrap
CMD ["/usr/bin/zsh"]
