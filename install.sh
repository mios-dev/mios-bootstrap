#!/usr/bin/env bash
#
# MiOS Bootstrap -- Interactive Ignition Installer (Total Root Merge Mode)
#
# SSOT: This script installs EVERYTHING a fully built MiOS system has.
# It transforms a bare Fedora host into a self-building MiOS workstation.
#
set -euo pipefail

# ============================================================================
# Defaults
# ============================================================================
DEFAULT_USER="mios"
DEFAULT_HOST="mios"
DEFAULT_USER_FULLNAME="MiOS User"
DEFAULT_USER_SHELL="/bin/bash"
DEFAULT_USER_GROUPS="wheel,libvirt,kvm,video,render,input,dialout"
DEFAULT_SSH_KEY_TYPE="ed25519"
DEFAULT_BRANCH="main"

MIOS_REPO="https://github.com/mios-dev/MiOS.git"
PROFILE_DIR="/etc/mios"
PROFILE_FILE="${PROFILE_DIR}/install.env"

# ============================================================================
# Logging & UI
# ============================================================================
_BOLD=$(tput bold 2>/dev/null || echo "")
_RED=$(tput setaf 1 2>/dev/null || echo "")
_GREEN=$(tput setaf 2 2>/dev/null || echo "")
_YELLOW=$(tput setaf 3 2>/dev/null || echo "")
_CYAN=$(tput setaf 6 2>/dev/null || echo "")
_DIM=$(tput dim 2>/dev/null || echo "")
_RESET=$(tput sgr0 2>/dev/null || echo "")

log_info()  { printf '%s[INFO]%s %s\n' "${_CYAN}" "${_RESET}" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n' "${_GREEN}" "${_RESET}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "${_YELLOW}" "${_RESET}" "$*" >&2; }
log_err()   { printf '%s[ERR ]%s %s\n' "${_RED}" "${_RESET}" "$*" >&2; }
log_phase() { printf '\n%s%s== %s ==%s\n\n' "${_BOLD}" "${_CYAN}" "$*" "${_RESET}"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Bootstrap must run as root: sudo $0"
        exit 1
    fi
}

detect_host_kind() {
    if command -v bootc >/dev/null 2>&1 && bootc status --format=json 2>/dev/null | grep -q '"booted"'; then
        echo "bootc"
    elif [[ -f /etc/os-release ]] && grep -qE '^ID(_LIKE)?=.*fedora' /etc/os-release; then
        echo "fhs-fedora"
    else
        echo "unsupported"
    fi
}

check_network() {
    local host
    for host in github.com; do
        if ! curl -fsSL --max-time 5 -o /dev/null "https://${host}/" 2>/dev/null; then
            log_err "No network reachability to ${host}."
            exit 1
        fi
    done
    log_ok "Network reachability verified"
}

prompt_default() {
    local question="$1" default="$2" answer
    read -r -p "$(printf '%s%s%s [%s%s%s]: ' "${_BOLD}" "${question}" "${_RESET}" "${_DIM}" "${default}" "${_RESET}")" answer
    echo "${answer:-$default}"
}

prompt_password() {
    local prompt="$1" pw1 pw2
    while :; do
        printf '%s%s%s: ' "${_BOLD}" "${prompt}" "${_RESET}" >&2
        read -rs pw1; echo >&2
        printf '%sConfirm:%s ' "${_BOLD}" "${_RESET}" >&2
        read -rs pw2; echo >&2
        if [[ "$pw1" == "$pw2" && -n "$pw1" ]]; then
            echo "$pw1"
            return 0
        fi
        log_warn "Passwords don't match or are empty."
    done
}

prompt_yesno() {
    local question="$1" default="${2:-y}" answer hint
    if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    read -r -p "$(printf '%s%s%s %s: ' "${_BOLD}" "${question}" "${_RESET}" "${hint}")" answer
    answer="${answer:-$default}"
    case "${answer,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================================
# Core Logic
# ============================================================================
main() {
    require_root
    log_phase "MiOS Bootstrap Installer (Full Build Mode)"

    local hostkind=$(detect_host_kind)
    if [[ "$hostkind" == "unsupported" ]]; then
        log_err "Host is not Fedora. MiOS requires a Fedora-based host."
        exit 1
    fi
    log_info "Detected host: ${hostkind}"

    check_network

    # --- 1. Gather Profile ---
    LINUX_USER="$(prompt_default 'Linux username' "${DEFAULT_USER}")"
    HOSTNAME_VAL="$(prompt_default 'Hostname' "${DEFAULT_HOST}")"
    USER_FULLNAME="$(prompt_default 'Full name (GECOS)' "${DEFAULT_USER_FULLNAME}")"
    USER_PASSWORD="$(prompt_password 'Password')"

    log_phase "Review profile"
    printf "  User: %s\n  Host: %s\n  Mode: Total Root Overlay\n\n" "$LINUX_USER" "$HOSTNAME_VAL"
    if ! prompt_yesno 'Proceed with these settings?' y; then exit 0; fi

    # --- 2. Apply Profile ---
    log_phase "Applying system profile"
    hostnamectl set-hostname "$HOSTNAME_VAL"

    local existing_groups=""
    IFS=',' read -ra ADDR <<< "${DEFAULT_USER_GROUPS}"
    for group in "${ADDR[@]}"; do
        if getent group "$group" >/dev/null; then
            [[ -n "$existing_groups" ]] && existing_groups+=","
            existing_groups+="$group"
        else
            log_warn "Group '$group' missing on host, skipping."
        fi
    done

    if id -u "$LINUX_USER" >/dev/null 2>&1; then
        log_info "User '$LINUX_USER' exists; updating groups + password"
        usermod -aG "$existing_groups" "$LINUX_USER"
        usermod -c "$USER_FULLNAME" "$LINUX_USER"
    else
        log_info "Creating '$LINUX_USER' (groups: $existing_groups)"
        useradd -m -G "$existing_groups" -s "$DEFAULT_USER_SHELL" -c "$USER_FULLNAME" "$LINUX_USER"
    fi
    echo "$LINUX_USER:$USER_PASSWORD" | chpasswd
    log_ok "User profile applied."

    # --- 3. Total Root Merge ---
    log_phase "MiOS Core Installation (Root Merge)"
    log_info "Merging MiOS repository onto system root (/) ..."
    if [[ ! -d "/.git" ]]; then
        git init /
        git -C / remote add origin "$MIOS_REPO" 2>/dev/null || git -C / remote set-url origin "$MIOS_REPO"
    fi
    git -C / fetch --depth=1 origin "$DEFAULT_BRANCH"
    git -C / checkout -f "$DEFAULT_BRANCH"
    log_ok "MiOS source tree merged to root."

    # --- 4. Package Installation ---
    log_phase "Installing MiOS System Stack"
    if [[ -f "/usr/share/mios/PACKAGES.md" ]]; then
        log_info "Extracting package list from /usr/share/mios/PACKAGES.md..."
        local pkgs
        pkgs=$(sed -n '/^```packages-/,/^```$/{/^```/d;/^#/d;/^$/d;p}' /usr/share/mios/PACKAGES.md | tr '\n' ' ')
        
        if [[ -n "$pkgs" ]]; then
            local dnf_cmd="dnf"
            command -v dnf5 >/dev/null 2>&1 && dnf_cmd="dnf5"
            log_info "Executing: $dnf_cmd install -y --skip-unavailable --best [PACKAGES]"
            $dnf_cmd install -y --skip-unavailable --best $pkgs || log_warn "Some packages failed to install."
            log_ok "Package stack installation complete."
        else
            log_err "No packages found in manifest!"
        fi
    else
        log_err "CRITICAL: /usr/share/mios/PACKAGES.md not found!"
        exit 1
    fi

    # --- 5. System Initialization ---
    log_phase "System Initialization"
    if [[ -x "/install.sh" ]]; then
        log_info "Running /install.sh to finalize FHS overlay..."
        /install.sh
        log_ok "Initialization complete."
    else
        log_err "/install.sh not found or not executable!"
        exit 1
    fi

    log_phase "MiOS Installation Complete"
    if prompt_yesno 'Reboot now to enter MiOS?' y; then
        systemctl reboot
    fi
}

main "$@"
