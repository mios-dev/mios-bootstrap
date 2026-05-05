#!/usr/bin/env bash
# seed-merge.sh -- Universal MiOS-SEED merge step.
#
# Overlays mios-bootstrap onto a mios.git checkout so the Containerfile
# build context contains the FULL deployed root layout (mios.git system
# layer + mios-bootstrap user/AI layer) regardless of the host platform
# the build runs from. Both build entries invoke this:
#
#   mios-bootstrap/build-mios.sh   (Linux/Fedora -- Phase-1 of Total Root Merge)
#   mios-bootstrap/build-mios.ps1  (Windows -- PowerShell calls a native
#                                   re-implementation; logic kept identical)
#
# Day-0 builds from any platform produce an identical OCI image with:
#   - mios.git's factory FHS overlay   (etc/, usr/, var/, automation/, ...)
#   - mios-bootstrap's user/AI overlay (etc/skel/, etc/mios/, usr/share/mios/ai/)
#   - bootstrap's root-level files     (mios.toml, CLAUDE.md, AGENTS.md,
#                                       GEMINI.md, usr/share/doc/mios-bootstrap/concepts/ai-architecture.md, .cursorrules, ...)
# baked in. Every deploy shape (raw, vhdx, qcow2, ISO, WSL2 distro,
# Podman-WSL OCI host) lands the same content because they're produced
# by bootc-image-builder from the same OCI image.
#
# Idempotent: re-running on an already-merged tree produces no diff.
# Non-destructive: bootstrap files OVERLAY onto mios.git -- bootstrap
# wins when both repos own the same path (which is correct: bootstrap
# is the user/AI layer that bootstraps configure, mios.git is the
# read-only factory layer).
#
# Usage:
#   seed-merge.sh <path-to-mios.git> <path-to-mios-bootstrap.git>
#
# Both paths must exist; both must be valid git checkouts (or copies
# of the trees). The mios.git path is mutated in place; pass a copy
# if you need to keep the upstream checkout pristine.
set -euo pipefail

MIOS_DIR="${1:?usage: seed-merge.sh <mios.git path> <mios-bootstrap.git path>}"
BOOT_DIR="${2:?usage: seed-merge.sh <mios.git path> <mios-bootstrap.git path>}"

[[ -d "$MIOS_DIR" ]] || { echo "ERROR: mios.git not found: $MIOS_DIR" >&2; exit 1; }
[[ -d "$BOOT_DIR" ]] || { echo "ERROR: mios-bootstrap.git not found: $BOOT_DIR" >&2; exit 1; }

_log() { printf '[seed-merge] %s\n' "$*"; }

# 1. Directory-tree overlays. Bootstrap's etc/, usr/, var/, profile/
# layer ON TOP of mios.git's same directories. Use cp -a to preserve
# permissions, ownership where applicable, and timestamps. The trailing
# /. is intentional: it copies the CONTENTS of $BOOT_DIR/etc into
# $MIOS_DIR/etc rather than nesting the etc directory itself.
for dir in etc usr var profile; do
    if [[ -d "${BOOT_DIR}/${dir}" ]]; then
        _log "overlay: ${BOOT_DIR}/${dir}/. -> ${MIOS_DIR}/${dir}/"
        mkdir -p "${MIOS_DIR}/${dir}"
        cp -af "${BOOT_DIR}/${dir}/." "${MIOS_DIR}/${dir}/"
    fi
done

# 2. Root-level files. These are the user-facing entry points and the
# canonical user-edit dotfile that live at / on the deployed system.
# After merge, mios.git's checkout has these at its root, and the
# Containerfile picks them up via the new /ctx/rootfiles staging.
ROOT_FILES=(
    mios.toml
    CLAUDE.md AGENTS.md GEMINI.md usr/share/doc/mios-bootstrap/concepts/ai-architecture.md AGREEMENTS.md
    .cursorrules
    usr/share/doc/mios/reference/api.md usr/share/doc/mios/reference/credits.md system-prompt.md
    usr/share/doc/mios-bootstrap/reference/variables.md usr/share/doc/mios-bootstrap/guides/user-space.md usr/share/doc/mios-bootstrap/guides/install-architecture.md
    llms.txt
    bootstrap.sh bootstrap.ps1 install.sh install.ps1
    Get-MiOS.ps1 build-mios.sh build-mios.ps1
)
for file in "${ROOT_FILES[@]}"; do
    if [[ -f "${BOOT_DIR}/${file}" ]]; then
        cp -f "${BOOT_DIR}/${file}" "${MIOS_DIR}/${file}"
    fi
done

# 3. Stage the canonical mios.toml at its FHS-resolved location so the
# runtime resolver (tools/lib/userenv.sh) finds it without needing a
# bootstrap-side install step. /usr/share/mios/mios.toml is the vendor
# layer; /etc/mios/mios.toml is the host-local overlay (writable on the
# deployed system). Bootstrap stages BOTH at install time on Linux;
# baking them into the OCI image gives Windows/WSL deploys the same
# defaults out of the box.
if [[ -f "${BOOT_DIR}/mios.toml" ]]; then
    install -d "${MIOS_DIR}/usr/share/mios"
    install -m 0644 "${BOOT_DIR}/mios.toml" "${MIOS_DIR}/usr/share/mios/mios.toml"
    install -d "${MIOS_DIR}/etc/mios"
    install -m 0644 "${BOOT_DIR}/mios.toml" "${MIOS_DIR}/etc/mios/mios.toml"
fi

_log "Universal MiOS-SEED merge complete: ${BOOT_DIR} -> ${MIOS_DIR}"
