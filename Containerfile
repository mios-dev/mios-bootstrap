# syntax=docker/dockerfile:1.9
# ============================================================================
# MiOS - Unified Image (v0.1.5)
# ============================================================================
# One image. Every role. Every surface. Every GPU vendor.
#
# Base:     Controlled by MIOS_BASE_IMAGE in .env.mios
#           Default: ghcr.io/ublue-os/ucore-hci:stable-nvidia
#           Already ships signed NVIDIA kmods (kmod-nvidia-open) matched to
#           the ucore-hci kernel.
# AMD:      Mesa + ROCm in-image (PACKAGES.md packages-gpu-amd-compute)
# Intel:    intel-compute-runtime + intel-media-driver (packages-gpu-intel-compute)
#
# v0.1.3 Architecture: Rootfs-Native Repository
#   - usr/, etc/, var/ directories promoted to the repository root.
#   - matches upstream bootc and native Linux filesystem standards.
# ============================================================================

ARG BASE_IMAGE=ghcr.io/ublue-os/ucore-hci:stable-nvidia # @track:IMG_BASE

# ----------------------------------------------------------------------------
# ctx stage: build context (scripts, system_files, manifests, overlay dirs)
# ----------------------------------------------------------------------------
FROM scratch AS ctx
COPY automation/           /ctx/automation/
COPY usr/                  /ctx/usr/
COPY etc/                  /ctx/etc/
COPY var/                  /ctx/var/
COPY home/                 /ctx/home/
# v0.1.3: PACKAGES.md moved to usr/share/mios/ for FHS compliance.
COPY usr/share/mios/PACKAGES.md                          /ctx/PACKAGES.md
COPY VERSION            /ctx/VERSION
COPY config/artifacts/       /ctx/bib-configs/
COPY tools/             /ctx/tools/

# ----------------------------------------------------------------------------
# main stage
# ----------------------------------------------------------------------------
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="MiOS"
LABEL org.opencontainers.image.description="Unified immutable cloud-native workstation OS (desktop/k3s/ha/hybrid)"
LABEL org.opencontainers.image.source="https://github.com/Kabuki94/MiOS-bootstrap"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.version="v0.1.5"
LABEL containers.bootc="1"
LABEL ostree.bootable="1"

# Set /sbin/init as the default command for bootc compatibility
CMD ["/sbin/init"]

# Build-time user provisioning - injected by mios-build-local.ps1 via --build-arg.
# 31-user.sh reads these as MIOS_USER / MIOS_PASSWORD_HASH env vars.
# ARG values do NOT persist into the final image (unlike ENV).
ARG MIOS_USER=mios
ARG MIOS_PASSWORD_HASH=
ARG MIOS_HOSTNAME=mios
ARG MIOS_FLATPAKS=

# Build context mounted read-only
COPY --from=ctx /ctx /ctx

# Inject flatpaks into the install list if provided
RUN if [[ -n "${MIOS_FLATPAKS}" ]]; then \
        echo "${MIOS_FLATPAKS}" | tr ',' '\n' > /ctx/usr/share/mios/flatpak-list; \
    fi

# Pre-pull images for Logically Bound Images (LBI)
# DISABLED: nested podman-pull requires --privileged buildkit which docker/build-push-action
# does not grant on ubuntu-24.04 GitHub-hosted runners. Either enable LBI via a Quadlet
# AutoUpdate=registry pull at first boot, or move pre-pulls to a self-hosted runner with
# privileged buildkit. Keeping the intent here for the migration path.
# RUN podman pull docker.io/postgres:15 || true \
#  && podman pull docker.io/ollama/ollama:latest || true \
#  && podman pull docker.io/guacamole/guacamole:latest || true \
#  && podman pull docker.io/guacamole/guacd:latest || true \
#  && podman pull quay.io/ceph/ceph:latest || true

 # Install essential security packages
 RUN dnf install -y --skip-unavailable --setopt=install_weak_deps=False \
     policycoreutils-python-utils \
     selinux-policy-targeted \
     firewalld \
     audit \
     fapolicyd \
     crowdsec \
     usbguard \
     kernel-devel \
  && dnf clean all

# ---------------------------------------------------------------------------
# Overlay rootfs content onto the system.
# ---------------------------------------------------------------------------
# MiOS v0.1.3: delegate system_files overlay to the script so the
# /usr/local -> /var/usrlocal symlink on ucore/bootc bases is handled correctly.
RUN bash /ctx/automation/08-system-files-overlay.sh

# Run the full numbered pipeline (orchestrated by automation/build.sh).
RUN --mount=type=cache,dst=/var/cache/libdnf5,sharing=locked \
    --mount=type=cache,dst=/var/cache/dnf,sharing=locked     \
    set -e; \
    chmod +x /ctx/automation/build.sh /ctx/automation/*.sh 2>/dev/null || true; \
    chmod +x /usr/libexec/mios/copy-build-log.sh; \
    /ctx/automation/build.sh

# MANDATORY CLEANUP for bootc container lint
RUN rm -rf /var/log/* /var/tmp/* /var/cache/dnf/* /var/cache/libdnf5/* /tmp/* \
 && find /run -mindepth 1 -maxdepth 1 ! -name 'secrets' -exec rm -rf {} + 2>/dev/null || true

# Install bootc bash completions
RUN bootc completion bash > /etc/bash_completion.d/bootc

# -- systemd-sysext consolidation ----------
RUN mkdir -p /usr/lib/extensions/source \
 && chmod +x /ctx/tools/mios-sysext-pack.sh \
 && /ctx/tools/mios-sysext-pack.sh /usr/lib/extensions/source || true

RUN rm -rf /ctx \
 && ostree container commit
RUN bootc container lint
