#!/usr/bin/env bash
#
# MiOS Bootstrap -- Interactive Ignition Installer
#
# Usage:
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MiOS-DEV/MiOS-bootstrap/main/install.sh)"
#   # or after cloning:
#   sudo /path/to/MiOS-bootstrap/install.sh
#
# Global pipeline phases (numbered; reused everywhere this project speaks of
# "phases"):
#
#   Phase-0  mios-bootstrap    — preflight, profile load, host detection,
#                                interactive identity capture (this script).
#   Phase-1  overlay-merge     — clone mios.git into /, copy bootstrap
#                                overlays (etc/, usr/, var/, profile/) on top.
#   Phase-2  build             — optional self-build: `podman build` an OCI
#                                image from the merged tree. The numbered
#                                automation/[0-9][0-9]-*.sh scripts inside
#                                Containerfile are sub-phases of Phase-2.
#   Phase-3  apply             — systemd-sysusers, systemd-tmpfiles, daemon
#                                reload; create the Linux user; stage
#                                ~/.config/mios/{profile.toml,system-prompt.md}
#                                + ~/.ssh/; deploy /etc/mios/ai/system-prompt.md.
#   Phase-4  reboot            — interactive y/N to `systemctl reboot`.
#
# Idempotent: re-running with the same answers updates rather than duplicates.
# load_profile_defaults() reads /etc/mios/profile.toml on a previously-
# bootstrapped host (or this repo's etc/mios/profile.toml otherwise) so each
# re-run picks up edits.

set -euo pipefail

# ============================================================================
# Defaults — sourced from the user profile card (etc/mios/profile.toml in
# this repo, or /etc/mios/profile.toml on a previously-bootstrapped host).
# load_profile_defaults() below parses the TOML on-the-fly with sed/grep so
# we don't pull in any TOML library at install time.
# ============================================================================
DEFAULT_USER="mios"
DEFAULT_HOST="mios"
DEFAULT_USER_FULLNAME="MiOS User"
DEFAULT_USER_SHELL="/bin/bash"
DEFAULT_USER_GROUPS="wheel,libvirt,kvm,video,render,input,dialout,docker"
DEFAULT_SSH_KEY_TYPE="ed25519"
DEFAULT_IMAGE="ghcr.io/mios-dev/mios:latest"
DEFAULT_BRANCH="main"
DEFAULT_TIMEZONE="UTC"
DEFAULT_KEYBOARD="us"
DEFAULT_LANG="en_US.UTF-8"

MIOS_REPO="https://github.com/mios-dev/mios.git"
BOOTSTRAP_REPO="https://github.com/mios-dev/mios-bootstrap.git"
PROFILE_DIR="/etc/mios"
PROFILE_CARD="${PROFILE_DIR}/profile.toml"
PROFILE_FILE="${PROFILE_DIR}/install.env"
LOG_FILE="/var/log/mios-bootstrap.log"

# Pull a value from a TOML file. Args: <file> <section> <key>.
# Strips quotes and inline comments. Returns empty if missing.
toml_get() {
    local file="$1" section="$2" key="$3"
    [[ -f "$file" ]] || { echo ""; return; }
    awk -v sect="[${section}]" -v k="$key" '
        $0 == sect            { in_sect = 1; next }
        /^\[/                 { in_sect = 0 }
        in_sect && $1 == k    { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/^"|"$/, ""); print; exit }
    ' "$file"
}

# Parse a TOML array of strings into a comma-joined value (groups, flatpaks).
toml_get_array_csv() {
    local file="$1" section="$2" key="$3"
    [[ -f "$file" ]] || { echo ""; return; }
    awk -v sect="[${section}]" -v k="$key" '
        $0 == sect            { in_sect = 1; next }
        /^\[/                 { in_sect = 0 }
        in_sect && $1 == k    {
            sub(/^[^\[]*\[/, ""); sub(/\].*$/, "")
            gsub(/[ \t"]/, "")
            print
            exit
        }
    ' "$file"
}

# Resolve the active profile card path: /etc/mios/profile.toml first (a
# previous install), then this repo's checkout copy.
resolve_profile_card() {
    if [[ -f "$PROFILE_CARD" ]]; then
        echo "$PROFILE_CARD"; return
    fi
    local repo_card; repo_card="$(dirname "${BASH_SOURCE[0]}")/etc/mios/profile.toml"
    if [[ -f "$repo_card" ]]; then
        echo "$repo_card"; return
    fi
    echo ""
}

# Override DEFAULT_* from the resolved profile card (if any).
load_profile_defaults() {
    local card; card="$(resolve_profile_card)"
    [[ -n "$card" ]] || return 0
    log_info "Seeding defaults from profile card: ${card}"

    local v
    v="$(toml_get "$card" identity username)";  [[ -n "$v" ]] && DEFAULT_USER="$v"
    v="$(toml_get "$card" identity hostname)";  [[ -n "$v" ]] && DEFAULT_HOST="$v"
    v="$(toml_get "$card" identity fullname)";  [[ -n "$v" ]] && DEFAULT_USER_FULLNAME="$v"
    v="$(toml_get "$card" identity shell)";     [[ -n "$v" ]] && DEFAULT_USER_SHELL="$v"
    v="$(toml_get_array_csv "$card" identity groups)"; [[ -n "$v" ]] && DEFAULT_USER_GROUPS="$v"
    v="$(toml_get "$card" auth ssh_key_type)";  [[ -n "$v" ]] && DEFAULT_SSH_KEY_TYPE="$v"
    v="$(toml_get "$card" image ref)";          [[ -n "$v" ]] && DEFAULT_IMAGE="$v"
    v="$(toml_get "$card" image branch)";       [[ -n "$v" ]] && DEFAULT_BRANCH="$v"
    v="$(toml_get "$card" locale timezone)";    [[ -n "$v" ]] && DEFAULT_TIMEZONE="$v"
    v="$(toml_get "$card" locale keyboard_layout)"; [[ -n "$v" ]] && DEFAULT_KEYBOARD="$v"
    v="$(toml_get "$card" locale language)";    [[ -n "$v" ]] && DEFAULT_LANG="$v"
    v="$(toml_get "$card" bootstrap mios_repo)";      [[ -n "$v" ]] && MIOS_REPO="$v"
    v="$(toml_get "$card" bootstrap bootstrap_repo)"; [[ -n "$v" ]] && BOOTSTRAP_REPO="$v"
}

# ============================================================================
# Logging
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

# ============================================================================
# Preflight
# ============================================================================
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Bootstrap must run as root. Re-invoke with sudo:"
        log_err "  sudo $0"
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
    for host in github.com ghcr.io; do
        if ! curl -fsSL --max-time 5 -o /dev/null "https://${host}/" 2>/dev/null; then
            log_err "No network reachability to ${host}. Check your network and re-run."
            exit 1
        fi
    done
    log_ok "Network reachability verified"
}

# ============================================================================
# Prompts -- the "mios" defaults are baked in; user just hits Enter to accept.
# ============================================================================
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
        if [[ "$pw1" == "$pw2" ]]; then
            if [[ -z "$pw1" ]]; then
                log_warn "Empty password not allowed."
                continue
            fi
            echo "$pw1"
            return 0
        fi
        log_warn "Passwords don't match, please try again."
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
# Phase-0 (continued): gather installation profile
# ============================================================================
gather_user_choices() {
    log_phase "Phase-0 — Installation profile"
    log_info "Press Enter to accept defaults (everything defaults to MiOS)."
    echo

    LINUX_USER="$(prompt_default 'Linux username' "${DEFAULT_USER}")"
    HOSTNAME_VAL="$(prompt_default 'Hostname' "${DEFAULT_HOST}")"
    USER_FULLNAME="$(prompt_default 'Full name (GECOS)' "${DEFAULT_USER_FULLNAME}")"

    log_info "Setting password for '${LINUX_USER}' (will be a sudoer):"
    USER_PASSWORD="$(prompt_password 'Password')"

    SSH_CHOICE="$(prompt_default 'SSH key: (g)enerate ed25519 / (e)xisting path / (s)kip' 'g')"
    case "${SSH_CHOICE,,}" in
        e|existing) SSH_KEY_PATH="$(prompt_default 'Existing private key path' "/root/.ssh/id_${DEFAULT_SSH_KEY_TYPE}")" ;;
        s|skip)     SSH_KEY_PATH="" ;;
        *)          SSH_KEY_PATH="generate" ;;
    esac

    if prompt_yesno 'Configure GitHub PAT for git credential helper?' n; then
        printf '%sGitHub PAT (input hidden):%s ' "${_BOLD}" "${_RESET}"
        read -rs GH_TOKEN; echo
    else
        GH_TOKEN=""
    fi

    local hostkind
    hostkind="$(detect_host_kind)"
    if [[ "$hostkind" == "bootc" ]]; then
        IMAGE_TAG="$(prompt_default 'MiOS bootc image' "${DEFAULT_IMAGE}")"
        INSTALL_MODE="bootc"
    else
        # FHS mode is always "fhs" for total root overlay in this branch.
        INSTALL_MODE="fhs"
        IMAGE_TAG=""
    fi
}

# ============================================================================
# Phase-0 (continued): confirm before applying
# ============================================================================
print_summary() {
    log_phase "Phase-0 — Review profile"
    cat <<EOF
  ${_BOLD}Linux user${_RESET}     : ${LINUX_USER}  (full name: ${USER_FULLNAME})
  ${_BOLD}Sudo groups${_RESET}    : ${DEFAULT_USER_GROUPS}
  ${_BOLD}Hostname${_RESET}       : ${HOSTNAME_VAL}
  ${_BOLD}Password${_RESET}       : (set, hidden)
  ${_BOLD}SSH key${_RESET}        : ${SSH_KEY_PATH:-skip}
  ${_BOLD}GitHub PAT${_RESET}     : $([ -n "${GH_TOKEN:-}" ] && echo 'configured' || echo 'skip')
  ${_BOLD}Install mode${_RESET}   : ${INSTALL_MODE} (Total Root Overlay)

EOF
    if ! prompt_yesno 'Proceed with these settings?' y; then
        log_info "Aborted by user. No changes made."
        exit 0
    fi
}

# ============================================================================
# Phase-3: apply profile to host
# ============================================================================
apply_user_profile() {
    log_phase "Phase-3 — Apply profile to host"
    mkdir -p "${PROFILE_DIR}"
    chmod 0750 "${PROFILE_DIR}"

    log_info "Setting hostname -> ${HOSTNAME_VAL}"
    hostnamectl set-hostname "${HOSTNAME_VAL}"

    if id -u "${LINUX_USER}" >/dev/null 2>&1; then
        log_info "User '${LINUX_USER}' exists; updating groups + password"
        usermod -aG "${DEFAULT_USER_GROUPS}" "${LINUX_USER}"
        usermod -c "${USER_FULLNAME}" "${LINUX_USER}"
    else
        log_info "Creating '${LINUX_USER}' (groups: ${DEFAULT_USER_GROUPS})"
        useradd -m -G "${DEFAULT_USER_GROUPS}" -s "${DEFAULT_USER_SHELL}" -c "${USER_FULLNAME}" "${LINUX_USER}"
    fi
    echo "${LINUX_USER}:${USER_PASSWORD}" | chpasswd
    log_ok "User '${LINUX_USER}' configured"

    local home; home="$(getent passwd "${LINUX_USER}" | cut -d: -f6)"
    if [[ "$SSH_KEY_PATH" == "generate" ]]; then
        log_info "Generating ${DEFAULT_SSH_KEY_TYPE} key for ${LINUX_USER}"
        sudo -u "${LINUX_USER}" mkdir -p "${home}/.ssh"
        chmod 0700 "${home}/.ssh"
        sudo -u "${LINUX_USER}" ssh-keygen -q -t "${DEFAULT_SSH_KEY_TYPE}" -N '' \
            -C "mios@${HOSTNAME_VAL}" \
            -f "${home}/.ssh/id_${DEFAULT_SSH_KEY_TYPE}"
        log_ok "SSH key generated: ${home}/.ssh/id_${DEFAULT_SSH_KEY_TYPE}"
    elif [[ -n "$SSH_KEY_PATH" ]]; then
        if [[ ! -f "$SSH_KEY_PATH" ]]; then
            log_warn "SSH key path not found: ${SSH_KEY_PATH} -- skipping"
        else
            log_info "Installing SSH key from ${SSH_KEY_PATH}"
            sudo -u "${LINUX_USER}" mkdir -p "${home}/.ssh"
            cp "${SSH_KEY_PATH}" "${home}/.ssh/id_${DEFAULT_SSH_KEY_TYPE}"
            cp "${SSH_KEY_PATH}.pub" "${home}/.ssh/id_${DEFAULT_SSH_KEY_TYPE}.pub" 2>/dev/null || true
            chown "${LINUX_USER}:${LINUX_USER}" "${home}/.ssh"/*
            chmod 0600 "${home}/.ssh/id_${DEFAULT_SSH_KEY_TYPE}"
            log_ok "SSH key installed"
        fi
    fi

    if [[ -n "${GH_TOKEN:-}" ]]; then
        sudo -u "${LINUX_USER}" mkdir -p "${home}/.config/git"
        sudo -u "${LINUX_USER}" git config --file "${home}/.config/git/config" credential.helper store
        echo "https://${LINUX_USER}:${GH_TOKEN}@github.com" > "${home}/.git-credentials"
        chmod 0600 "${home}/.git-credentials"
        chown "${LINUX_USER}:${LINUX_USER}" "${home}/.git-credentials"
        log_ok "GitHub credential helper configured"
    fi

    cat > "${PROFILE_FILE}" <<EOF
# MiOS install profile -- written by mios-bootstrap install.sh
# Non-secret installation metadata. Passwords/tokens are NOT stored here.
MIOS_LINUX_USER="${LINUX_USER}"
MIOS_HOSTNAME="${HOSTNAME_VAL}"
MIOS_USER_FULLNAME="${USER_FULLNAME}"
MIOS_USER_GROUPS="${DEFAULT_USER_GROUPS}"
MIOS_INSTALL_MODE="${INSTALL_MODE}"
MIOS_IMAGE_TAG="${IMAGE_TAG}"
MIOS_INSTALLED_AT="$(date -u --iso-8601=seconds)"
MIOS_BOOTSTRAP_VERSION="0.2.0"
EOF
    chmod 0640 "${PROFILE_FILE}"
    log_ok "Profile env written: ${PROFILE_FILE}"

    # Persist the user-editable profile card alongside install.env so future
    # bootstrap re-runs (or `mios edit-env`) can amend defaults in TOML.
    if [[ ! -f "${PROFILE_CARD}" ]]; then
        local repo_card; repo_card="$(dirname "${BASH_SOURCE[0]}")/etc/mios/profile.toml"
        if [[ -f "$repo_card" ]]; then
            install -m 0644 "$repo_card" "${PROFILE_CARD}"
            log_ok "Profile card seeded: ${PROFILE_CARD}"
        fi
    fi
}

# ============================================================================
# Phase-3 (continued): deploy AI system prompt to host AND user home
# ============================================================================
deploy_system_prompt() {
    log_phase "Phase-3 — Deploy AI system prompt"
    install -d -m 0755 /etc/mios/ai

    local src_local prompt_url
    src_local="$(dirname "${BASH_SOURCE[0]}")/system-prompt.md"
    prompt_url="https://raw.githubusercontent.com/mios-dev/mios-bootstrap/${DEFAULT_BRANCH}/system-prompt.md"

    if [[ -f "$src_local" ]]; then
        log_info "Using local system-prompt.md from ${src_local}"
        install -m 0644 "$src_local" /etc/mios/ai/system-prompt.md
    else
        log_info "Fetching system prompt from ${prompt_url}"
        if curl -fsSL --max-time 30 "$prompt_url" -o /etc/mios/ai/system-prompt.md.new; then
            mv /etc/mios/ai/system-prompt.md.new /etc/mios/ai/system-prompt.md
            chmod 0644 /etc/mios/ai/system-prompt.md
        else
            rm -f /etc/mios/ai/system-prompt.md.new
            log_warn "Could not fetch system prompt"
            return 0
        fi
    fi
    log_ok "Host system prompt deployed: /etc/mios/ai/system-prompt.md"

    # Stage per-user copies for every existing human account (uid >= 1000,
    # excluding nobody/65534). Each user gets their own editable copy at
    # ~/.config/mios/system-prompt.md alongside ~/.config/mios/profile.toml.
    local home u
    while IFS=: read -r u _ uid _ _ home _; do
        [[ "$uid" -ge 1000 && "$uid" -lt 65534 && -d "$home" ]] || continue
        sudo -u "$u" install -d -m 0755 "${home}/.config/mios"
        install -o "$u" -g "$u" -m 0644 \
            /etc/mios/ai/system-prompt.md "${home}/.config/mios/system-prompt.md"
        log_ok "User system prompt staged: ${home}/.config/mios/system-prompt.md"
    done < /etc/passwd
}

# ============================================================================
# Phase-3 (continued): stage per-user profile card + system prompt for the
# bootstrap-created user. Called from trigger_mios_install after the new
# Linux user exists.
# ============================================================================
stage_user_profile_artifacts() {
    log_phase "Phase-3 — Stage per-user MiOS artifacts"
    local home; home="$(getent passwd "${LINUX_USER}" | cut -d: -f6)"
    [[ -n "$home" && -d "$home" ]] || { log_warn "User home not found; skipping per-user staging"; return 0; }

    sudo -u "${LINUX_USER}" install -d -m 0755 "${home}/.config/mios"

    local repo_card; repo_card="$(dirname "${BASH_SOURCE[0]}")/profile/.config/mios/profile.toml"
    if [[ -f "$repo_card" ]]; then
        install -o "${LINUX_USER}" -g "${LINUX_USER}" -m 0644 \
            "$repo_card" "${home}/.config/mios/profile.toml"
        log_ok "User profile card: ${home}/.config/mios/profile.toml"
    else
        log_warn "profile/.config/mios/profile.toml missing in bootstrap repo"
    fi

    if [[ -f /etc/mios/ai/system-prompt.md ]]; then
        install -o "${LINUX_USER}" -g "${LINUX_USER}" -m 0644 \
            /etc/mios/ai/system-prompt.md "${home}/.config/mios/system-prompt.md"
        log_ok "User system prompt: ${home}/.config/mios/system-prompt.md"
    fi
}

# ============================================================================
# Phase-1 + Phase-2: clone mios.git into /, apply bootstrap overlays, install
# packages from PACKAGES.md SSOT, run mios.git/install.sh for system init.
# Phase-2 (build) is implicit: on FHS hosts the package install + system-side
# init is the equivalent of "build the running system from the merged tree";
# on bootc hosts Phase-2 is `bootc switch` to a pre-built image.
# ============================================================================
trigger_mios_install() {
    log_phase "Phase-1 — Total Root Merge"
    
    case "${INSTALL_MODE}" in
        bootc)
            log_info "Switching bootc deployment to ${IMAGE_TAG}"
            bootc switch "${IMAGE_TAG}"
            log_ok "bootc deployment staged"
            ;;
        fhs)
            # 1. Initialize / as the git root for MiOS core
            log_info "Staging MiOS core repository (mios.git) to /"
            if [[ ! -d "/.git" ]]; then
                git init /
                git -C / remote add origin "${MIOS_REPO}"
            fi
            
            # Fetch and Force Checkout MiOS into root (respects .gitignore)
            git -C / fetch --depth=1 origin "${DEFAULT_BRANCH}"
            git -C / checkout -f "${DEFAULT_BRANCH}"
            log_ok "MiOS core (mios.git) merged to /"

            # 2. Apply MiOS-bootstrap repo overlays
            local bootstrap_tmp="/tmp/mios-bootstrap-src"
            log_info "Fetching MiOS-bootstrap overlays from ${BOOTSTRAP_REPO}"
            rm -rf "${bootstrap_tmp}"
            git clone --depth=1 "${BOOTSTRAP_REPO}" "${bootstrap_tmp}"
            
            log_info "Merging bootstrap system folders (etc, usr, var) to /"
            for d in etc usr var; do
                if [[ -d "${bootstrap_tmp}/${d}" ]]; then
                    cp -rv "${bootstrap_tmp}/${d}/"* "/${d}/" 2>/dev/null || true
                fi
            done
            
            local home; home="$(getent passwd "${LINUX_USER}" | cut -d: -f6)"
            if [[ -d "${bootstrap_tmp}/profile" ]]; then
                log_info "Staging user-space profile to ${home}"
                cp -rv "${bootstrap_tmp}/profile/"* "${home}/"
                chown -R "${LINUX_USER}:${LINUX_USER}" "${home}"
            fi
            rm -rf "${bootstrap_tmp}"
            log_ok "MiOS-bootstrap overlays applied"

            # 3. Phase-2: Comprehensive Package Installation (build the FHS host
            # from the merged source tree using PACKAGES.md SSOT).
            log_phase "Phase-2 — Build (FHS package install from PACKAGES.md)"
            if [[ -f "/usr/share/mios/PACKAGES.md" ]]; then
                log_info "Installing full MiOS package stack from manifest (PACKAGES.md)..."
                
                # Extract all package names from fenced code blocks tagged with ```packages-*
                local pkgs
                pkgs=$(sed -n '/^```packages-/,/^```$/{/^```/d;/^#/d;/^$/d;p}' /usr/share/mios/PACKAGES.md | tr '\n' ' ')
                
                if [[ -n "$pkgs" ]]; then
                    # Determine DNF command
                    local dnf_cmd="dnf"
                    command -v dnf5 >/dev/null 2>&1 && dnf_cmd="dnf5"
                    
                    log_info "Executing: $dnf_cmd install -y --skip-unavailable --best $pkgs"
                    $dnf_cmd install -y --skip-unavailable --best $pkgs || log_warn "Some packages failed to install."
                else
                    log_warn "No packages found in PACKAGES.md manifest."
                fi
            else
                log_err "CRITICAL: /usr/share/mios/PACKAGES.md not found! Package installation skipped."
            fi

            # 4. Phase-3: Final MiOS System Initiation (sysusers, tmpfiles,
            # daemon-reload, services).
            log_phase "Phase-3 — System Init (sysusers + tmpfiles + services)"
            if [[ -x "/install.sh" ]]; then
                log_info "Running MiOS system-side installer from /"
                bash "/install.sh"
                log_ok "MiOS FHS system overlay complete"
            else
                log_err "MiOS install.sh not found at /install.sh"
                exit 1
            fi
            ;;
    esac
}

# ============================================================================
# Phase-4: reboot prompt
# ============================================================================
reboot_prompt() {
    log_phase "Phase-4 — Reboot"
    if prompt_yesno 'Reboot now to activate MiOS?' y; then
        log_info "Rebooting in 3s..."
        sleep 3
        systemctl reboot
    else
        log_info "Skipping reboot. Run 'sudo systemctl reboot' when ready."
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    require_root
    log_phase "Phase-0 — mios-bootstrap (Total Root Merge Mode)"

    local hostkind
    hostkind="$(detect_host_kind)"
    if [[ "$hostkind" == "unsupported" ]]; then
        log_err "Host is not Fedora. Aborting."
        exit 1
    fi
    log_info "Detected host: ${hostkind}"

    check_network
    load_profile_defaults
    gather_user_choices
    print_summary

    # Phase-1 (overlay merge) and Phase-2 (build / package install) happen
    # inside trigger_mios_install. System groups are created there before
    # apply_user_profile needs them.
    trigger_mios_install

    # Phase-3a: deploy AI system prompt to host /etc/ AND every existing user home.
    deploy_system_prompt

    # Phase-3b: create the bootstrap user, set password, persist install.env
    # and seed /etc/mios/profile.toml.
    apply_user_profile

    # Phase-3c: stage the per-user profile.toml + system-prompt.md into the
    # newly-created user's home (idempotent on re-run).
    stage_user_profile_artifacts

    # Phase-4
    reboot_prompt
}

main "$@"
