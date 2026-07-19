#!/usr/bin/env bash
# AI-hint: The ONE shared library for every Linux MiOS entrypoint (mios-install.sh, build-mios.sh,
# cat/MiOS-Cat.sh, the curl|bash web door). Source it: `. "$(dirname "$0")/mios-common.sh"`. It is the
# bash sibling of installation/mios-common.ps1 -- same contracts, same SSOT layering (user > host >
# vendor, mirroring usr/lib/mios/mios_toml.py): ONE layered toml resolver (mios_ssot_value), the
# SSOT-[colors] themed logger (log_info/ok/warn/err/phase/die), ONE self-elevate (mios_self_elevate),
# ONE repo-fetch (mios_ensure_repo), and find_mios_bin. No side effects on source beyond setting the
# color vars + defining funcs. Safe under `set -euo pipefail`.
# AI-related: mios-common.ps1, mios-install.sh, build-mios.sh, cat/MiOS-Cat.sh, usr/lib/mios/mios_toml.py, mios.toml

# ---- SSOT: one layered resolver (user > host > vendor), the only toml reader anyone needs ---------
# Emits existing layer paths, HIGHEST priority first. _MIOS_REPO_ROOT (repo-local mios.toml) is set by
# the caller if it sources us from a repo checkout; else we fall back to the FHS/host locations only.
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
# mios_ssot_value SECTION KEY [DEFAULT] -- first (highest) layer that defines [SECTION].KEY wins.
mios_ssot_value() {
    local section="$1" key="$2" default="${3:-}" path v
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        v="$(awk -v section="$section" -v key="$key" '
            /^[[:space:]]*\[/ { h=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/,"",h); insec=(h==section); next }
            insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
                line=$0
                # Quoted value first (handles # inside hex colors like "#1A407F"); matches the PS resolver.
                if (match(line, /"[^"]*"/)) { print substr(line, RSTART+1, RLENGTH-2); exit }
                # Unquoted fallback: text after =, minus trailing inline comment + spaces.
                sub(/^[^=]*=[[:space:]]*/,"",line); sub(/[[:space:]]+#.*$/,"",line); sub(/[[:space:]]+$/,"",line)
                print line; exit
            }
        ' "$path" 2>/dev/null || true)"
        if [[ -n "$v" ]]; then printf '%s\n' "$v"; return 0; fi
    done < <(mios_ssot_layers)
    [[ -n "$default" ]] && printf '%s\n' "$default"
    return 0
}
# mios_ssot_path -- canonical vendor SSOT for display ("your config lives here"), else lowest layer.
mios_ssot_path() {
    if [[ -f "/usr/share/mios/mios.toml" ]]; then printf '/usr/share/mios/mios.toml\n'; return 0; fi
    mios_ssot_layers | tail -n1 || true
    return 0
}

# ---- Theme: SSOT [colors] truecolor when on a TTY, tput/plain fallback otherwise ------------------
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

# ---- Host maintenance binaries (mios-build / mios-update ship with the OS image, not this checkout) --
find_mios_bin() {
    local name="$1" p
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    for p in "/usr/bin/${name}" "/usr/libexec/mios/${name}"; do
        [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

# ---- Elevation: one self-exec via sudo -E (for entrypoints that do NOT self-sudo) ----------------
mios_self_elevate() {
    # mios_self_elevate "$0" "${ORIG_ARGS[@]}" -- re-execs this script under sudo, preserving env.
    if [[ "$(id -u)" -eq 0 ]]; then return 0; fi
    log_info "this step needs root -- re-executing via 'sudo -E'..."
    exec sudo -E "$@"
}

# ---- Repo fetch: one Ensure-Repo (git, else GitHub tarball). Canonical checkout = the sourced root --
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
