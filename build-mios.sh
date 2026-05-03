#!/usr/bin/env bash
#
# 'MiOS' Bootstrap -- Interactive Ignition Installer
#
# Usage:
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/MiOS-DEV/MiOS-bootstrap/main/install.sh)"
#   # or after cloning:
#   sudo /path/to/MiOS-bootstrap/install.sh
#
# By invoking this script you acknowledge AGREEMENTS.md (Apache-2.0
# main + bundled-component licenses in LICENSES.md + attribution in
# CREDITS.md). 'MiOS' is a research project (pronounced 'MyOS';
# generative, seed-script-derived).
#
# Global pipeline phases (numbered; reused everywhere this project speaks of
# "phases"):
#
#   Phase-0  mios-bootstrap    -- preflight, profile load, host detection,
#                                interactive identity capture (this script).
#   Phase-1  overlay-merge     -- clone mios.git into /, copy bootstrap
#                                overlays (etc/, usr/, var/, profile/) on top.
#   Phase-2  build             -- optional self-build: `podman build` an OCI
#                                image from the merged tree. The numbered
#                                automation/[0-9][0-9]-*.sh scripts inside
#                                Containerfile are sub-phases of Phase-2.
#   Phase-3  apply             -- systemd-sysusers, systemd-tmpfiles, daemon
#                                reload; create the Linux user; stage
#                                ~/.config/mios/{profile.toml,system-prompt.md}
#                                + ~/.ssh/; deploy /etc/mios/ai/system-prompt.md.
#   Phase-4  reboot            -- interactive y/N to `systemctl reboot`.
#
# Idempotent: re-running with the same answers updates rather than duplicates.
# load_profile_defaults() reads /etc/mios/profile.toml on a previously-
# bootstrapped host (or this repo's etc/mios/profile.toml otherwise) so each
# re-run picks up edits.

set -euo pipefail

# Acknowledgment banner -- inlined (script is curl-piped). Respects
# MIOS_AGREEMENT_BANNER=quiet for unattended runs.
case "${MIOS_AGREEMENT_BANNER:-}" in
    quiet|silent|off|0|false|FALSE) ;;
    *)
        cat >&2 <<'__EOF__'
[mios] By invoking build-mios.sh you acknowledge AGREEMENTS.md
       (Apache-2.0 main + bundled-component licenses in LICENSES.md +
        attribution in CREDITS.md). 'MiOS' is a research project
       (pronounced 'MyOS'; generative, seed-script-derived).
__EOF__
        ;;
esac

# ============================================================================
# Defaults -- sourced from the user profile card (etc/mios/profile.toml in
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
# Canonical user-edit copy lives in mios-bootstrap.git/mios.toml (repo root).
# /etc/mios/mios.toml is the host-installed copy of that file. Legacy
# /etc/mios/profile.toml is still recognized by the resolver for
# pre-unification deployments.
PROFILE_CARD="${PROFILE_DIR}/mios.toml"
PROFILE_CARD_LEGACY="${PROFILE_DIR}/profile.toml"
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

# Profile resolution. Each layer overlays the one above. Returned as a
# space-separated list of paths (lowest precedence first).
#
#   1. /usr/share/mios/mios.toml           vendor defaults (mios.git)
#   2. /usr/share/mios/profile.toml        legacy vendor defaults (mios.git)
#   3. <bootstrap-checkout>/mios.toml      user-edit copy at repo root  <-- canonical
#   4. <bootstrap-checkout>/etc/mios/profile.toml  legacy user-edit copy
#   5. /etc/mios/mios.toml                 host-installed user-edit (re-run)
#   6. /etc/mios/profile.toml              legacy host-installed copy
#
# Empty strings in higher layers do NOT override non-empty defaults below
# them -- that's how this implements "user-set fields supersede defaults"
# without requiring sparse TOML files.
resolve_profile_layers() {
    local layers=()
    [[ -f /usr/share/mios/mios.toml ]]    && layers+=(/usr/share/mios/mios.toml)
    [[ -f /usr/share/mios/profile.toml ]] && layers+=(/usr/share/mios/profile.toml)
    local bootstrap_root; bootstrap_root="$(dirname "${BASH_SOURCE[0]}")"
    [[ -f "${bootstrap_root}/mios.toml" ]]              && layers+=("${bootstrap_root}/mios.toml")
    [[ -f "${bootstrap_root}/etc/mios/profile.toml" ]]  && layers+=("${bootstrap_root}/etc/mios/profile.toml")
    [[ -f "$PROFILE_CARD" ]]        && layers+=("$PROFILE_CARD")
    [[ -f "$PROFILE_CARD_LEGACY" ]] && layers+=("$PROFILE_CARD_LEGACY")
    printf '%s\n' "${layers[@]}"
}

# Read a single key, walking layers in order. Higher layers override lower.
toml_get_layered() {
    local section="$1" key="$2" array_mode="${3:-}"
    local fn="toml_get"
    [[ "$array_mode" == "array" ]] && fn="toml_get_array_csv"
    local result=""
    while IFS= read -r card; do
        local v; v="$($fn "$card" "$section" "$key")"
        [[ -n "$v" ]] && result="$v"
    done < <(resolve_profile_layers)
    echo "$result"
}

# Override DEFAULT_* from the merged profile-card layers.
load_profile_defaults() {
    local layers; layers=$(resolve_profile_layers | tr '\n' ' ')
    [[ -n "$layers" ]] || return 0
    log_info "Loading profile layers (lowest→highest precedence):"
    while IFS= read -r card; do log_info "  * ${card}"; done < <(resolve_profile_layers)

    local v
    v="$(toml_get_layered identity username)";        [[ -n "$v" ]] && DEFAULT_USER="$v"
    v="$(toml_get_layered identity hostname)";        [[ -n "$v" ]] && DEFAULT_HOST="$v"
    v="$(toml_get_layered identity fullname)";        [[ -n "$v" ]] && DEFAULT_USER_FULLNAME="$v"
    v="$(toml_get_layered identity shell)";           [[ -n "$v" ]] && DEFAULT_USER_SHELL="$v"
    v="$(toml_get_layered identity groups array)";    [[ -n "$v" ]] && DEFAULT_USER_GROUPS="$v"
    v="$(toml_get_layered auth ssh_key_type)";        [[ -n "$v" ]] && DEFAULT_SSH_KEY_TYPE="$v"
    v="$(toml_get_layered image ref)";                [[ -n "$v" ]] && DEFAULT_IMAGE="$v"
    v="$(toml_get_layered image branch)";             [[ -n "$v" ]] && DEFAULT_BRANCH="$v"
    v="$(toml_get_layered locale timezone)";          [[ -n "$v" ]] && DEFAULT_TIMEZONE="$v"
    v="$(toml_get_layered locale keyboard_layout)";   [[ -n "$v" ]] && DEFAULT_KEYBOARD="$v"
    v="$(toml_get_layered locale language)";          [[ -n "$v" ]] && DEFAULT_LANG="$v"
    v="$(toml_get_layered bootstrap mios_repo)";      [[ -n "$v" ]] && MIOS_REPO="$v"
    v="$(toml_get_layered bootstrap bootstrap_repo)"; [[ -n "$v" ]] && BOOTSTRAP_REPO="$v"

    # Legacy .env.mios fallback (deprecated; sourced last so explicit TOML wins).
    local legacy_env; legacy_env="$(dirname "${BASH_SOURCE[0]}")/.env.mios"
    if [[ -f "$legacy_env" ]]; then
        log_info "Sourcing legacy ${legacy_env} (deprecated; migrate to profile.toml)"
        # shellcheck source=/dev/null
        set +u; source "$legacy_env"; set -u
        [[ -n "${MIOS_DEFAULT_USER:-}" ]] && DEFAULT_USER="${MIOS_DEFAULT_USER}"
        [[ -n "${MIOS_DEFAULT_HOST:-}" ]] && DEFAULT_HOST="${MIOS_DEFAULT_HOST}"
        [[ -n "${MIOS_IMAGE_NAME:-}" && -n "${MIOS_IMAGE_TAG:-}" ]] && \
            DEFAULT_IMAGE="${MIOS_IMAGE_NAME}:${MIOS_IMAGE_TAG}"
    fi
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

# ── Spinner ───────────────────────────────────────────────────────────────────
_SPIN_PID=0
spin_start() {
    local msg="${1:-Working...}"
    printf '%s  %s...%s\n' "${_CYAN}" "$msg" "${_RESET}" >&2
    (
        local i=0 chars='|/-\'
        while true; do
            printf '\r  %s %s %s  ' "${_CYAN}" "${chars:$((i % 4)):1}" "$msg${_RESET}" >&2
            i=$((i + 1))
            sleep 0.2
        done
    ) &
    _SPIN_PID=$!
}
spin_stop() {
    if [[ "$_SPIN_PID" -ne 0 ]]; then
        kill "$_SPIN_PID" 2>/dev/null || true
        wait "$_SPIN_PID" 2>/dev/null || true
        _SPIN_PID=0
    fi
    printf '\r%s\r' "$(tput el 2>/dev/null || printf '%80s')" >&2
}

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

install_prerequisites() {
    local missing=()
    for cmd in git curl openssl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    log_info "Installing missing prerequisites: ${missing[*]}"
    local dnf_cmd="dnf"
    command -v dnf5 &>/dev/null && dnf_cmd="dnf5"
    spin_start "Installing ${missing[*]}"
    $dnf_cmd install -y --skip-unavailable "${missing[@]}" || {
        spin_stop
        log_err "Failed to install prerequisites: ${missing[*]}"
        exit 1
    }
    spin_stop
    log_ok "Prerequisites ready: ${missing[*]}"
}

# ============================================================================
# Prompts -- the "mios" defaults are baked in; user just hits Enter to accept,
# or stays idle for $MIOS_PROMPT_TIMEOUT seconds (default 180 = 3 minutes) for
# the prompt to auto-accept the default. Set MIOS_PROMPT_TIMEOUT=0 to disable
# the timeout (wait forever); set MIOS_PROMPT_TIMEOUT=1 in CI for fastest
# unattended runs.
# ============================================================================
: "${MIOS_PROMPT_TIMEOUT:=180}"

prompt_default() {
    local question="$1" default="$2" answer
    if [[ "${MIOS_PROMPT_TIMEOUT}" -gt 0 ]]; then
        if read -r -t "${MIOS_PROMPT_TIMEOUT}" -p "$(printf '%s%s%s [%s%s%s] (auto-accept in %ds): ' "${_BOLD}" "${question}" "${_RESET}" "${_DIM}" "${default}" "${_RESET}" "${MIOS_PROMPT_TIMEOUT}")" answer; then
            echo "${answer:-$default}"
        else
            # 'read' exits with non-zero on EOF or timeout. Either way we take
            # the default and emit a one-line note to stderr so the operator
            # can audit the unattended decision in the install log.
            printf '\n%s%s%s [auto-accept after %ds] -> %s\n' "${_DIM}" "${question}" "${_RESET}" "${MIOS_PROMPT_TIMEOUT}" "${default}" >&2
            echo "${default}"
        fi
    else
        read -r -p "$(printf '%s%s%s [%s%s%s]: ' "${_BOLD}" "${question}" "${_RESET}" "${_DIM}" "${default}" "${_RESET}")" answer
        echo "${answer:-$default}"
    fi
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
    log_phase "Phase-0 -- Installation profile"
    log_info "Press Enter to accept defaults (everything defaults to 'MiOS')."
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
    log_phase "Phase-0 -- Review profile"
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
    log_phase "Phase-3 -- Apply profile to host"
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
# 'MiOS' install profile -- written by mios-bootstrap install.sh
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
    # The canonical user-edit copy lives at mios-bootstrap.git/mios.toml
    # (repo root); we stage it to /etc/mios/mios.toml. The legacy
    # etc/mios/profile.toml is still picked up if present.
    if [[ ! -f "${PROFILE_CARD}" ]]; then
        local bootstrap_root; bootstrap_root="$(dirname "${BASH_SOURCE[0]}")"
        local src=""
        if   [[ -f "${bootstrap_root}/mios.toml" ]];               then src="${bootstrap_root}/mios.toml"
        elif [[ -f "${bootstrap_root}/etc/mios/profile.toml" ]];   then src="${bootstrap_root}/etc/mios/profile.toml"
        fi
        if [[ -n "$src" ]]; then
            install -m 0644 "$src" "${PROFILE_CARD}"
            log_ok "Profile card seeded from $(basename "$src"): ${PROFILE_CARD}"
        fi
    fi
}

# ============================================================================
# Phase-3 (continued): deploy AI system prompt to host AND user home
# ============================================================================
deploy_system_prompt() {
    log_phase "Phase-3 -- Deploy AI system prompt"
    install -d -m 0755 /etc/mios/ai

    local src_local prompt_url
    src_local="$(dirname "${BASH_SOURCE[0]}")/system-prompt.md"
    prompt_url="https://raw.githubusercontent.com/mios-dev/mios-bootstrap/${DEFAULT_BRANCH}/system-prompt.md"

    if [[ -f "$src_local" ]]; then
        log_info "Using local system-prompt.md from ${src_local}"
        install -m 0644 "$src_local" /etc/mios/ai/system-prompt.md
    else
        log_info "Fetching system prompt from ${prompt_url}"
        spin_start "Downloading system-prompt.md"
        if curl -fsSL --max-time 30 "$prompt_url" -o /etc/mios/ai/system-prompt.md.new; then
            spin_stop
            mv /etc/mios/ai/system-prompt.md.new /etc/mios/ai/system-prompt.md
            chmod 0644 /etc/mios/ai/system-prompt.md
        else
            spin_stop
            rm -f /etc/mios/ai/system-prompt.md.new
            log_warn "Could not fetch system prompt"
            return 0
        fi
    fi
    log_ok "Host system prompt deployed: /etc/mios/ai/system-prompt.md"

    # Stage per-user copies for every existing human account
    # (uid 1000-65533). Single helper avoids duplicate logic across
    # deploy_system_prompt + stage_user_profile_artifacts; the call sites
    # remain distinct so the bootstrap-created user still gets the
    # name-bearing log line.
    seed_user_skel_for_all_accounts
}

# ============================================================================
# Multi-user seeder: copy /etc/skel/.config/mios/* into every existing user's
# home, owned by that user. Called from deploy_system_prompt (after the host
# /etc/mios/ai/system-prompt.md is in place) and again from
# stage_user_profile_artifacts (after the bootstrap-created user is added).
# Idempotent: install(1) overwrites with current content, mode is enforced.
# ============================================================================
seed_user_skel_for_all_accounts() {
    local skel_root=/etc/skel/.config/mios
    [[ -d "$skel_root" ]] || {
        log_warn "etc/skel/.config/mios missing -- per-user staging skipped"
        return 0
    }

    local u home uid sh
    while IFS=: read -r u _ uid _ _ home sh; do
        [[ "$uid" -ge 1000 && "$uid" -lt 65534 && -d "$home" ]] || continue
        sudo -u "$u" install -d -m 0755 "${home}/.config" "${home}/.config/mios"
        local f
        for f in "$skel_root"/*; do
            [[ -f "$f" ]] || continue
            install -o "$u" -g "$u" -m 0644 "$f" "${home}/.config/mios/$(basename "$f")"
        done
        log_ok "Seeded ${home}/.config/mios/ for ${u} (uid ${uid})"
    done < /etc/passwd
}

# ============================================================================
# Phase-3 (continued): stage per-user profile card + system prompt for the
# bootstrap-created user. Reads from /etc/skel/.config/mios/, the FHS-native
# template surface that mios-bootstrap.git populates from etc/skel/.
# ============================================================================
stage_user_profile_artifacts() {
    log_phase "Phase-3 -- Stage per-user 'MiOS' artifacts"
    local home; home="$(getent passwd "${LINUX_USER}" | cut -d: -f6)"
    [[ -n "$home" && -d "$home" ]] || {
        log_warn "User home not found; skipping per-user staging"
        return 0
    }

    sudo -u "${LINUX_USER}" install -d -m 0755 "${home}/.config" "${home}/.config/mios"

    local skel_root=/etc/skel/.config/mios
    if [[ -d "$skel_root" ]]; then
        local f
        for f in "$skel_root"/*; do
            [[ -f "$f" ]] || continue
            install -o "${LINUX_USER}" -g "${LINUX_USER}" -m 0644 \
                "$f" "${home}/.config/mios/$(basename "$f")"
            log_ok "User artifact: ${home}/.config/mios/$(basename "$f")"
        done
    else
        log_warn "etc/skel/.config/mios missing -- bootstrap user staging skipped"
    fi

    # Re-run the multi-user pass so a newly added user picks up the same
    # content as everyone else (idempotent).
    seed_user_skel_for_all_accounts
}

# ============================================================================
# Phase-1 + Phase-2: clone mios.git into /, apply bootstrap overlays, install
# packages from PACKAGES.md SSOT, run mios.git/install.sh for system init.
# Phase-2 (build) is implicit: on FHS hosts the package install + system-side
# init is the equivalent of "build the running system from the merged tree";
# on bootc hosts Phase-2 is `bootc switch` to a pre-built image.
# ============================================================================
trigger_mios_install() {
    log_phase "Phase-1 -- Total Root Merge"
    
    case "${INSTALL_MODE}" in
        bootc)
            log_info "Switching bootc deployment to ${IMAGE_TAG}"
            bootc switch "${IMAGE_TAG}"
            log_ok "bootc deployment staged"
            ;;
        fhs)
            local dnf_cmd="dnf"
            command -v dnf5 >/dev/null 2>&1 && dnf_cmd="dnf5"

            # 1. Initialize / as the git root for 'MiOS' core
            log_info "Staging 'MiOS' core repository (mios.git) to /"
            if [[ ! -d "/.git" ]]; then
                git init /
                git -C / remote add origin "${MIOS_REPO}"
            fi
            spin_start "Fetching mios.git (system layer)"
            git -C / fetch --depth=1 origin "${DEFAULT_BRANCH}" 2>&1 | tail -3
            git -C / reset --hard FETCH_HEAD
            spin_stop
            log_ok "MiOS core (mios.git) merged to /"

            # 2. Apply MiOS-bootstrap repo overlays
            local bootstrap_tmp="/tmp/mios-bootstrap-src"
            log_info "Fetching MiOS-bootstrap overlays from ${BOOTSTRAP_REPO}"
            spin_start "Cloning mios-bootstrap.git (user layer)"
            rm -rf "${bootstrap_tmp}"
            git clone --depth=1 "${BOOTSTRAP_REPO}" "${bootstrap_tmp}" 2>&1 | tail -3
            spin_stop

            log_info "Merging bootstrap system folders (etc, usr) to /"
            for d in etc usr; do
                if [[ -d "${bootstrap_tmp}/${d}" ]]; then
                    cp -a "${bootstrap_tmp}/${d}/." "/${d}/" 2>/dev/null || true
                fi
            done
            rm -rf "${bootstrap_tmp}"
            log_ok "MiOS-bootstrap overlays applied"

            # 3. Phase-2: RPM package install from PACKAGES.md SSOT.
            # Build-only blocks (kernel kmods, selinux policy source, looking-glass
            # build deps, cockpit plugin build deps) are excluded -- they only make
            # sense inside the OCI build pipeline, not on a running FHS host.
            log_phase "Phase-2 -- FHS package install (from PACKAGES.md)"
            local packages_md="/usr/share/mios/PACKAGES.md"
            if [[ -f "$packages_md" ]]; then
                # Excluded block names: build-time / image-only groups
                local -a exclude_blocks=(
                    packages-kernel
                    packages-k3s-selinux-build
                    packages-looking-glass-build
                    packages-cockpit-plugins-build
                    packages-self-build
                )
                local exclude_pat
                exclude_pat=$(printf '|%s' "${exclude_blocks[@]}")
                exclude_pat="${exclude_pat:1}"   # strip leading |

                local pkgs
                pkgs=$(awk -v excl="$exclude_pat" '
                    /^```packages-/ {
                        block = $0; sub(/^```/,"",block); sub(/[[:space:]].*$/,"",block)
                        if (block ~ excl) { skip=1 } else { skip=0 }
                        next
                    }
                    /^```$/ { skip=0; next }
                    skip || /^#/ || /^$/ { next }
                    { print }
                ' "$packages_md" | tr '\n' ' ')

                if [[ -n "$pkgs" ]]; then
                    # Install repos meta-packages first so that subsequent packages
                    # can resolve from RPMFusion, CrowdSec, Terra, etc.
                    local repo_pkgs
                    repo_pkgs=$(sed -n '/^```packages-repos/,/^```$/{/^```/d;/^#/d;/^$/d;p}' "$packages_md" | tr '\n' ' ')
                    if [[ -n "$repo_pkgs" ]]; then
                        log_info "Setting up additional repos..."
                        spin_start "Installing repo packages"
                        # shellcheck disable=SC2086
                        $dnf_cmd install -y --skip-unavailable $repo_pkgs 2>&1 | grep -E '^(Install|Upgrade|Error|Warning|Failed)' || true
                        spin_stop
                        $dnf_cmd makecache --refresh 2>/dev/null || true
                        log_ok "Repos configured"
                    fi

                    log_info "Installing full 'MiOS' component stack..."
                    spin_start "dnf install (this takes several minutes)"
                    # shellcheck disable=SC2086
                    $dnf_cmd install -y --skip-unavailable --best $pkgs 2>&1 \
                        | grep -E '^\s*(Installing|Upgrading|Removing|Error|Warning|Nothing)' || true
                    spin_stop
                    log_ok "Package installation complete"
                else
                    log_warn "No packages extracted from PACKAGES.md"
                fi
            else
                log_err "PACKAGES.md not found at ${packages_md} -- package installation skipped"
            fi

            # 4. Phase-3: systemd-sysusers, systemd-tmpfiles, daemon-reload.
            # This wires up 'MiOS' user/group definitions and creates /var/ paths
            # declared in usr/lib/tmpfiles.d/mios*.conf.
            log_phase "Phase-3 -- System init (sysusers + tmpfiles + daemon-reload)"
            spin_start "Running systemd-sysusers"
            systemctl-sysusers 2>/dev/null || systemd-sysusers 2>/dev/null || log_warn "systemd-sysusers not available"
            spin_stop
            spin_start "Running systemd-tmpfiles --create"
            systemd-tmpfiles --create 2>/dev/null || log_warn "systemd-tmpfiles failed"
            spin_stop
            if systemctl is-system-running --quiet 2>/dev/null; then
                spin_start "Reloading systemd daemon"
                systemctl daemon-reload
                spin_stop
                log_ok "Systemd daemon reloaded"
            fi
            log_ok "FHS system init complete"
            ;;
    esac
}

# ============================================================================
# Phase-4: reboot prompt
# ============================================================================
reboot_prompt() {
    log_phase "Phase-4 -- Reboot"
    if prompt_yesno 'Reboot now to activate 'MiOS'?' y; then
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
    log_phase "Phase-0 -- mios-bootstrap (Total Root Merge Mode)"

    local hostkind
    hostkind="$(detect_host_kind)"
    if [[ "$hostkind" == "unsupported" ]]; then
        log_err "Host is not Fedora. Aborting."
        exit 1
    fi
    log_info "Detected host: ${hostkind}"

    check_network
    install_prerequisites
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
