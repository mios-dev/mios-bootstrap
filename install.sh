#!/bin/bash
# MiOS Bootstrap Installer
# Deploys the MiOS repository as a Linux filesystem-native integrated build environment
# Supports curl-to-bash bootstrapping.
#
# Usage: curl -sL https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/install.sh | sudo bash

set -euo pipefail

# Refuse to run on a host already managed by bootc -- /usr is read-only composefs
# and the FHS overlay we lay down here would be discarded on next boot. Use
# `bootc switch` against ghcr.io/kabuki94/mios:latest instead.
if command -v bootc >/dev/null 2>&1 && bootc status --format=json 2>/dev/null | grep -q '"booted"'; then
    echo "[FAIL] This host is bootc-managed. install.sh is for non-bootc Fedora Server hosts." >&2
    echo "       Use 'sudo bootc switch ghcr.io/kabuki94/mios:latest' instead." >&2
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Installation paths (FHS 3.0)
INSTALL_PREFIX="/usr"
MIOS_SRC_DIR="${INSTALL_PREFIX}/src/mios"
MIOS_SHARE_DIR="${INSTALL_PREFIX}/share/mios"
MIOS_ETC_DIR="/etc/mios"
MIOS_VAR_LIB_DIR="/var/lib/mios"
MIOS_VAR_LOG_DIR="/var/log/mios"
MIOS_BIN_DIR="/usr/local/bin"
MIOS_TMPFILES_DIR="/etc/tmpfiles.d"

info() { echo -e "${BLUE}  ${NC}$*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]  ${NC}$*"; }
error() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

run_preflight() {
    info "Running preflight checks..."
    # If mios-preflight exists in source, run it. Otherwise, assume pre-installed.
    if [[ -f "${MIOS_SRC_DIR}/tools/preflight.sh" ]]; then
        bash "${MIOS_SRC_DIR}/tools/preflight.sh"
    elif command -v mios-preflight &>/dev/null; then
        mios-preflight
    fi
}

bootstrap_source() {
    # Skip bootstrap if --no-clone is passed or if we are already in the target dir
    if [[ "${NO_CLONE:-false}" == "true" ]]; then
        info "Skipping source bootstrap (--no-clone active)."
        return
    fi

    if [[ ! -d "${MIOS_SRC_DIR}/.git" ]]; then
        info "Bootstrapping MiOS source to ${MIOS_SRC_DIR}..."
        mkdir -p "$(dirname "${MIOS_SRC_DIR}")"
        # Ensure git is present for initial clone
        command -v git >/dev/null 2>&1 || {
            info "Installing git for initial bootstrap..."
            if command -v dnf &>/dev/null; then dnf install -y git; elif command -v apt-get &>/dev/null; then apt-get update && apt-get install -y git; fi
        }
        git clone https://github.com/Kabuki94/MiOS-bootstrap.git "${MIOS_SRC_DIR}"
    else
        info "MiOS source already exists, updating..."
        cd "${MIOS_SRC_DIR}" && git pull
    fi
}

install_mios() {
    echo ""
    echo "+==============================================================+"
    echo "           MiOS Bootstrap Installer (FHS Native)             "
    echo "+==============================================================+"
    echo ""

    bootstrap_source
    run_preflight

    info "Creating FHS directory structure..."
    mkdir -p "${MIOS_SHARE_DIR}" "${MIOS_ETC_DIR}" "${MIOS_BIN_DIR}" "${MIOS_TMPFILES_DIR}"
    success "Created system directories"

    info "Syncing system files..."
    # Symlink share to src for live updates
    ln -sfn "${MIOS_SRC_DIR}" "${MIOS_SHARE_DIR}"
    
    # Install templates
    mkdir -p "${MIOS_ETC_DIR}/templates"
    cp -r "${MIOS_SRC_DIR}/etc/mios/templates/"* "${MIOS_ETC_DIR}/templates/"
    
    cat > "${MIOS_ETC_DIR}/manifest.json" <<EOF
{
  "mios_version": "$(cat "${MIOS_SRC_DIR}/VERSION" 2>/dev/null || echo 'v0.1.3')",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "paths": {
    "src": "${MIOS_SRC_DIR}",
    "share": "${MIOS_SHARE_DIR}",
    "etc": "${MIOS_ETC_DIR}",
    "var_lib": "${MIOS_VAR_LIB_DIR}",
    "var_log": "${MIOS_VAR_LOG_DIR}"
  }
}
EOF
    success "Installed system configuration"

    info "Creating tmpfiles.d configuration..."
    cat > "${MIOS_TMPFILES_DIR}/mios.conf" <<EOF
# MiOS Unified State Folders (USR-OVER-ETC)
d /usr/lib/mios/artifacts  0755 root root -
d /usr/lib/mios/backups    0700 root root -
d /usr/lib/mios/snapshots  0755 root root -
d /usr/lib/mios/logs       0755 root root -

d /var/lib/mios            0755 root root -
L+ /var/lib/mios/artifacts - - - - /usr/lib/mios/artifacts
L+ /var/lib/mios/backups   - - - - /usr/lib/mios/backups
L+ /var/lib/mios/snapshots - - - - /usr/lib/mios/snapshots
d /var/log/mios            0755 root root -
L+ /var/log/mios/builds    - - - - /usr/lib/mios/logs
EOF
    systemd-tmpfiles --create "${MIOS_TMPFILES_DIR}/mios.conf"
    success "Created /var directories"

    info "Installing mios command..."
    cat > "${MIOS_BIN_DIR}/mios" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Refuse to run on a host already managed by bootc -- /usr is read-only composefs
# and the FHS overlay we lay down here would be discarded on next boot. Use
# `bootc switch` against ghcr.io/kabuki94/mios:latest instead.
if command -v bootc >/dev/null 2>&1 && bootc status --format=json 2>/dev/null | grep -q '"booted"'; then
    echo "[FAIL] This host is bootc-managed. install.sh is for non-bootc Fedora Server hosts." >&2
    echo "       Use 'sudo bootc switch ghcr.io/kabuki94/mios:latest' instead." >&2
    exit 1
fi

MIOS_SRC_DIR="/usr/src/mios"
if [[ ! -d "$MIOS_SRC_DIR" ]]; then
    echo "[FAIL] MiOS source not found at $MIOS_SRC_DIR" >&2
    exit 1
fi
# Always ensure we are in the source dir for just
cd "$MIOS_SRC_DIR"
exec /usr/bin/just "$@"
EOF
    chmod +x "${MIOS_BIN_DIR}/mios"
    
    # Also link the unified CLI
    ln -sf "${MIOS_SRC_DIR}/usr/bin/mios" "${MIOS_BIN_DIR}/mios-cli"
    
    success "Installed mios command"

    echo ""
    echo "+==============================================================+"
    echo "              [OK] MiOS Installation Complete                   "
    echo "+==============================================================+"
    echo ""
    info "Next steps:"
    echo "  1. Initialize user-space: ${CYAN}mios user${NC}"
    echo "  2. Build your OS image:  ${CYAN}mios build${NC}"
    echo ""
}

uninstall_mios() {
    warn "This will remove MiOS from system directories."
    read -p "Continue? [y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

    [[ -d "${MIOS_SRC_DIR}" ]] && rm -rf "${MIOS_SRC_DIR}" && success "Removed ${MIOS_SRC_DIR}"
    [[ -L "${MIOS_SHARE_DIR}" ]] && rm -f "${MIOS_SHARE_DIR}" && success "Removed ${MIOS_SHARE_DIR}"
    [[ -d "${MIOS_ETC_DIR}" ]] && rm -rf "${MIOS_ETC_DIR}" && success "Removed ${MIOS_ETC_DIR}"
    [[ -f "${MIOS_BIN_DIR}/mios" ]] && rm -f "${MIOS_BIN_DIR}/mios" && success "Removed mios command"
    [[ -f "${MIOS_BIN_DIR}/mios-cli" ]] && rm -f "${MIOS_BIN_DIR}/mios-cli" && success "Removed mios-cli command"
    [[ -f "${MIOS_TMPFILES_DIR}/mios.conf" ]] && rm -f "${MIOS_TMPFILES_DIR}/mios.conf"
    success "MiOS uninstalled"
}

main() {
    NO_CLONE=false
    for arg in "$@"; do
        case $arg in
            --uninstall) check_root; uninstall_mios; exit 0 ;;
            --no-clone)  NO_CLONE=true ;;
        esac
    done
    check_root
    install_mios
}

main "$@"
