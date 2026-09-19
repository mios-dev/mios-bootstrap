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

# Non-root user with passwordless sudo, matching mios.git's devcontainer so the
# two repos present the same account. visudo -cf fails the build on a malformed
# rule rather than shipping one that silently grants nothing.
RUN useradd -m -u 1000 -s /usr/bin/zsh mios-dev \
    && echo "mios-dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/mios-dev \
    && chmod 0440 /etc/sudoers.d/mios-dev \
    && visudo -cf /etc/sudoers.d/mios-dev

ENV MIOS_DEVCONTAINER=1

WORKDIR /mios-bootstrap
USER mios-dev
CMD ["/usr/bin/zsh"]
