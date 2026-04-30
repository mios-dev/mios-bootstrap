#!/usr/bin/env bash
#
# MiOS Bootstrap -- Interactive Ignition Installer
#
# Usage:
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MiOS-DEV/MiOS-bootstrap/main/install.sh)"
#
set -euo pipefail

# --- Defaults ---
DEFAULT_USER="mios"
DEFAULT_HOST="mios"
DEFAULT_USER_FULLNAME="MiOS User"
DEFAULT_USER_SHELL="/bin/bash"
DEFAULT_USER_GROUPS="wheel,libvirt,kvm,video,render,input,dialout"
DEFAULT_SSH_KEY_TYPE="ed25519"
DEFAULT_IMAGE="ghcr.io/MiOS-DEV/mios:latest"
DEFAULT_BRANCH="main"

MIOS_REPO="https://github.com/mios-dev/MiOS.git"
BOOTSTRAP_REPO="https://github.com/MiOS-DEV/MiOS-bootstrap.git"

# --- UI Helpers ---
_BOLD=$(tput bold 2>/dev/null || echo "")
_CYAN=$(tput setaf 6 2>/dev/null || echo "")
_GREEN=$(tput setaf 2 2>/dev/null || echo "")
_YELLOW=$(tput setaf 3 2>/dev/null || echo "")
_RED=$(tput setaf 1 2>/dev/null || echo "")
_RESET=$(tput sgr0 2>/dev/null || echo "")

log_info()  { printf '%s[INFO]%s %s\n' "${_CYAN}" "${_RESET}" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n' "${_GREEN}" "${_RESET}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "${_YELLOW}" "${_RESET}" "$*" >&2; }
log_err()   { printf '%s[ERR ]%s %s\n' "${_RED}" "${_RESET}" "$*" >&2; }
log_phase() { printf '\n%s%s== %s ==%s\n\n' "${_BOLD}" "${_CYAN}" "$*" "${_RESET}"; }

# --- Logic ---
require_root() { [[ $EUID -eq 0 ]] || { log_err "Run as root: sudo $0"; exit 1; }; }

detect_host_kind() {
    if command -v bootc >/dev/null 2>&1 && bootc status --format=json 2>/dev/null | grep -q '"booted"'; then echo "bootc"
    elif [[ -f /etc/os-release ]] && grep -qE '^ID(_LIKE)?=.*fedora' /etc/os-release; then echo "fhs-fedora"
    else echo "unsupported"; fi
}

gather_choices() {
    log_phase "Installation profile"
    read -p "Linux username [$DEFAULT_USER]: " LINUX_USER; LINUX_USER=${LINUX_USER:-$DEFAULT_USER}
    read -p "Hostname [$DEFAULT_HOST]: " HOSTNAME_VAL; HOSTNAME_VAL=${HOSTNAME_VAL:-$DEFAULT_HOST}
    read -p "Full name [$DEFAULT_USER_FULLNAME]: " USER_FULLNAME; USER_FULLNAME=${USER_FULLNAME:-$DEFAULT_USER_FULLNAME}
    
    printf "Setting password for '$LINUX_USER':\n"
    read -rs -p "Password: " USER_PASSWORD; echo
    read -rs -p "Confirm: " PW2; echo
    [[ "$USER_PASSWORD" == "$PW2" ]] || { log_err "Passwords mismatch"; exit 1; }
    
    INSTALL_MODE="fhs"
    [[ "$(detect_host_kind)" == "bootc" ]] && INSTALL_MODE="bootc"
}

apply_profile() {
    log_phase "Apply profile to host"
    log_info "Setting hostname -> $HOSTNAME_VAL"
    hostnamectl set-hostname "$HOSTNAME_VAL"

    # CRITICAL FIX: Filter existing groups
    local existing_groups=""
    IFS=',' read -ra ADDR <<< "$DEFAULT_USER_GROUPS"
    for group in "${ADDR[@]}"; do
        if getent group "$group" >/dev/null; then
            [[ -n "$existing_groups" ]] && existing_groups+=","
            existing_groups+="$group"
        else
            log_warn "Group '$group' does not exist, skipping."
        fi
    done

    if id -u "$LINUX_USER" >/dev/null 2>&1; then
        log_info "Updating existing user $LINUX_USER"
        usermod -aG "$existing_groups" "$LINUX_USER"
    else
        log_info "Creating '$LINUX_USER' (groups: $existing_groups)"
        useradd -m -G "$existing_groups" -s "$DEFAULT_USER_SHELL" -c "$USER_FULLNAME" "$LINUX_USER"
    fi
    echo "$LINUX_USER:$USER_PASSWORD" | chpasswd
}

trigger_merge() {
    log_phase "MiOS Total Root Merge"
    if [[ "$INSTALL_MODE" == "bootc" ]]; then
        bootc switch "$DEFAULT_IMAGE"
    else
        log_info "Merging MiOS core repository onto /"
        [[ -d "/.git" ]] || git init /
        git -C / remote add origin "$MIOS_REPO" 2>/dev/null || git -C / remote set-url origin "$MIOS_REPO"
        git -C / fetch --depth=1 origin "$DEFAULT_BRANCH"
        git -C / checkout -f "$DEFAULT_BRANCH"
        
        log_info "Merging MiOS bootstrap overlays"
        local tmp="/tmp/mios-boot-src"
        rm -rf "$tmp" && git clone --depth=1 "$BOOTSTRAP_REPO" "$tmp"
        for d in etc usr var srv; do
            [[ -d "$tmp/$d" ]] && cp -rv "$tmp/$d/"* "/$d/" 2>/dev/null || true
        done
        
        if [[ -f "/usr/share/mios/PACKAGES.md" ]]; then
            log_info "Installing package stack from manifest..."
            local pkgs=$(sed -n '/^```packages-/,/^```$/{/^```/d;/^#/d;/^$/d;p}' /usr/share/mios/PACKAGES.md | tr '\n' ' ')
            dnf install -y --skip-unavailable --best $pkgs || log_warn "Package installation warnings."
        fi
        
        [[ -x "/install.sh" ]] && /install.sh
    fi
}

main() {
    require_root
    log_phase "MiOS Bootstrap Installer (Total Root Merge Mode)"
    [[ "$(detect_host_kind)" == "unsupported" ]] && { log_err "Fedora required"; exit 1; }
    gather_choices
    apply_profile
    trigger_merge
    log_phase "Complete - Reboot recommended"
}

main "$@"
