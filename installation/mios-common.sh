#!/usr/bin/env bash
# AI-hint: The ONE shared library for every Linux MiOS entrypoint (mios-install.sh, build-mios.sh,
# AI-related: mios-common.ps1, mios-install.sh, build-mios.sh, cat/MiOS-Cat.sh, usr/lib/mios/mios_toml.py, mios.toml

mios_ssot_layers() {
    local p
    for p in \
        "${HOME}/.config/mios/mios.toml" \
        "/etc/mios/mios.toml" \
        "${_MIOS_REPO_ROOT:-}/mios.toml" \
        "/usr/share/mios/mios.toml"; do
        [[ -n "$p" && "$p" != "/mios.toml" && -f "$p" ]] && printf '%s\n' "$p"
    done
    return 0   # never let a false final [[ -f ]] make the loop exit non-zero (breaks callers under set -o pipefail)
}
mios_ssot_value() {
    local section="$1" key="$2" default="${3:-}" path v
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        v="$(awk -v section="$section" -v key="$key" '
            /^[[:space:]]*\[/ { h=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/,"",h); insec=(h==section); next }
            insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
                line=$0
                if (match(line, /"[^"]*"/)) { print substr(line, RSTART+1, RLENGTH-2); exit }
                sub(/^[^=]*=[[:space:]]*/,"",line); sub(/[[:space:]]+#.*$/,"",line); sub(/[[:space:]]+$/,"",line)
                print line; exit
            }
        ' "$path" 2>/dev/null || true)"
        if [[ -n "$v" ]]; then printf '%s\n' "$v"; return 0; fi
    done < <(mios_ssot_layers)
    [[ -n "$default" ]] && printf '%s\n' "$default"
    return 0
}
mios_ssot_path() {
    if [[ -f "/usr/share/mios/mios.toml" ]]; then printf '/usr/share/mios/mios.toml\n'; return 0; fi
    mios_ssot_layers | tail -n1 || true
    return 0
}

_mios_rgb() { local h="${1#\#}"; [[ "$h" =~ ^[0-9A-Fa-f]{6}$ ]] || { printf ''; return; }; printf '%d;%d;%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }
mios_init_theme() {
    _bold=''; _reset=''; _cInfo=''; _cOk=''; _cWarn=''; _cErr=''; _cAccent=''
    if [[ -n "${MIOS_NO_COLOR:-}${NO_COLOR:-}" ]] || [[ ! -t 1 && "${MIOS_FORCE_COLOR:-0}" != 1 ]]; then return 0; fi
    local info ok warn err accent
    info="$(_mios_rgb "$(mios_ssot_value colors info    '#1A407F')")"
    ok="$(_mios_rgb   "$(mios_ssot_value colors success '#3E7765')")"
    warn="$(_mios_rgb "$(mios_ssot_value colors warning '#F35C15')")"
    err="$(_mios_rgb  "$(mios_ssot_value colors error   '#DC271B')")"
    accent="$(_mios_rgb "$(mios_ssot_value colors accent '#1A407F')")"
    _bold=$'\033[1m'; _reset=$'\033[0m'
    [[ -n "$info" ]]   && _cInfo=$'\033[38;2;'"${info}m"
    [[ -n "$ok" ]]     && _cOk=$'\033[38;2;'"${ok}m"
    [[ -n "$warn" ]]   && _cWarn=$'\033[38;2;'"${warn}m"
    [[ -n "$err" ]]    && _cErr=$'\033[38;2;'"${err}m"
    [[ -n "$accent" ]] && _cAccent=$'\033[38;2;'"${accent}m"
}
mios_init_theme
log_info()  { printf '%s[INFO]%s %s\n' "${_cInfo}"   "${_reset}" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n' "${_cOk}"     "${_reset}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "${_cWarn}"   "${_reset}" "$*" >&2; }
log_err()   { printf '%s[ERR ]%s %s\n' "${_cErr}"    "${_reset}" "$*" >&2; }
log_phase() { printf '\n%s%s== %s ==%s\n\n' "${_bold}" "${_cAccent}" "$*" "${_reset}"; }
die()       { log_err "$*"; exit 1; }

find_mios_bin() {
    local name="$1" p
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    for p in "/usr/bin/${name}" "/usr/libexec/mios/${name}"; do
        [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

mios_self_elevate() {
    if [[ "$(id -u)" -eq 0 ]]; then return 0; fi
    log_info "this step needs root -- re-executing via 'sudo -E'..."
    exec sudo -E "$@"
}

mios_ensure_repo() {
    local root="${1:-$HOME/mios-bootstrap}"
    [[ -f "${root}/installation/mios-install.sh" ]] && { printf '%s\n' "$root"; return 0; }
    log_info "mios-bootstrap not present -- fetching it (git, else a GitHub tarball)..."
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 'https://github.com/mios-dev/mios-bootstrap.git' "$root" >/dev/null 2>&1 || true
    fi
    if [[ ! -f "${root}/installation/mios-install.sh" ]]; then
        local tgz; tgz="$(mktemp -d)/mios-bootstrap.tgz"
        if curl -fsSL 'https://codeload.github.com/mios-dev/mios-bootstrap/tar.gz/refs/heads/main' -o "$tgz" 2>/dev/null; then
            mkdir -p "$root"; tar -xzf "$tgz" -C "$root" --strip-components=1 2>/dev/null || true
        fi
        rm -rf "$(dirname "$tgz")" 2>/dev/null || true
    fi
    printf '%s\n' "$root"
}

mios_ensure_rust() {
    if command -v cargo >/dev/null 2>&1; then
        log_ok "Rust already present: $(cargo --version 2>/dev/null)"
        return 0
    fi
    if command -v dnf5 >/dev/null 2>&1; then
        dnf5 install -y rust cargo >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y rust cargo >/dev/null 2>&1 || true
    fi
    if ! command -v cargo >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null 2>&1 || true
        [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    fi
    if command -v cargo >/dev/null 2>&1; then
        log_ok "Rust installed: $(cargo --version 2>/dev/null)"
        return 0
    fi
    log_warn "Rust could not be installed (no repo/network?) -- native components deferred"
    return 1
}
