#!/bin/bash
# MiOS Public Bootstrap — Linux / WSL2
# Repository: Kabuki94/MiOS-bootstrap
# Usage: curl -fsSL https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/bootstrap.sh | bash
set -euo pipefail

PRIVATE_INSTALLER="https://raw.githubusercontent.com/Kabuki94/mios/main/install.sh"

_r=$'\033[0m'; _b=$'\033[1m'; _dim=$'\033[2m'; _c=$'\033[36m'; _g=$'\033[32m'; _red=$'\033[31m'; _y=$'\033[33m'

echo ""
echo "  ${_c}╔══════════════════════════════════════════════════════════════╗${_r}"
echo "  ${_c}║  MiOS — Local Build Configuration                           ║${_r}"
echo "  ${_c}╚══════════════════════════════════════════════════════════════╝${_r}"
echo ""

# ── GitHub PAT (required for private repo access) ─────────────────────────
if [[ -z "${GHCR_TOKEN:-}" ]]; then
    read -rsp "  ${_b}GitHub PAT${_r} (requires 'repo' scope): " GHCR_TOKEN; echo ""
fi
if [[ -z "${GHCR_TOKEN:-}" ]]; then
    echo "  ${_red}[!] Token required.${_r}"; exit 1
fi
export GHCR_TOKEN

echo ""
echo "  ${_y}── Build Configuration ─────────────────────────────────────────${_r}"
echo ""

# ── Admin username ─────────────────────────────────────────────────────────
if [[ -z "${MIOS_USER:-}" ]]; then
    read -rp "  Admin username ${_dim}[mios]${_r}: " MIOS_USER
    MIOS_USER="${MIOS_USER:-mios}"
else
    echo "  Admin username: ${MIOS_USER}  ${_dim}(env)${_r}"
fi
export MIOS_USER

# ── Admin password ─────────────────────────────────────────────────────────
if [[ -z "${MIOS_PASSWORD:-}" ]]; then
    while true; do
        read -rsp "  Admin password: " MIOS_PASSWORD; echo ""
        [[ -z "${MIOS_PASSWORD:-}" ]] && { echo "  ${_red}[!] Password cannot be empty.${_r}"; continue; }
        read -rsp "  Confirm password: " _c2; echo ""
        [[ "$MIOS_PASSWORD" == "$_c2" ]] && break
        echo "  ${_red}[!] Mismatch — try again.${_r}"
    done
else
    echo "  Admin password: ${_dim}(env — masked)${_r}"
fi
export MIOS_PASSWORD

# ── Hostname ───────────────────────────────────────────────────────────────
# Produces <base>-<5-digit> e.g. "kabu-ws-83427" — unique per build
if [[ -z "${MIOS_HOSTNAME:-}" ]]; then
    read -rp "  Hostname base ${_dim}[mios]${_r} (5-digit suffix appended): " _hbase
    _hbase="${_hbase:-mios}"
    _suf=$(shuf -i 10000-99999 -n1 2>/dev/null || printf '%05d' $(( RANDOM % 90000 + 10000 )))
    export MIOS_HOSTNAME="${_hbase}-${_suf}"
else
    echo "  Hostname: ${MIOS_HOSTNAME}  ${_dim}(env)${_r}"
fi

# ── Optional: GHCR push credentials ───────────────────────────────────────
if [[ -z "${MIOS_GHCR_USER:-}" ]]; then
    echo ""
    read -rp "  GHCR push username ${_dim}[skip]${_r}: " MIOS_GHCR_USER
fi
export MIOS_GHCR_USER="${MIOS_GHCR_USER:-}"

if [[ -n "$MIOS_GHCR_USER" && -z "${MIOS_GHCR_PUSH_TOKEN:-}" ]]; then
    read -rsp "  GHCR push token ${_dim}[reuse GitHub PAT]${_r}: " MIOS_GHCR_PUSH_TOKEN; echo ""
    export MIOS_GHCR_PUSH_TOKEN="${MIOS_GHCR_PUSH_TOKEN:-$GHCR_TOKEN}"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "  ${_y}── Summary ──────────────────────────────────────────────────────${_r}"
echo ""
printf "    %-20s %s\n" "Admin user:"     "$MIOS_USER"
printf "    %-20s %s\n" "Admin password:" "(masked)"
printf "    %-20s %s\n" "Hostname:"       "$MIOS_HOSTNAME"
printf "    %-20s %s\n" "Registry push:"  "${MIOS_GHCR_USER:-none (local build only)}"
echo ""
read -rp "  ${_b}Proceed?${_r} [Y/n]: " _ok
[[ "${_ok,,}" == "n" ]] && { echo "  Aborted."; exit 0; }

# ── Fetch and execute private installer ───────────────────────────────────
export MIOS_AUTOINSTALL=1
echo ""
echo "  [+] Fetching private installer..."
_tmp=$(mktemp /tmp/mios-install-XXXXXX.sh)
if curl -fsSL -H "Authorization: token $GHCR_TOKEN" "$PRIVATE_INSTALLER" -o "$_tmp"; then
    chmod +x "$_tmp"
    echo "  ${_g}[OK]${_r} Launching installer."
    echo ""
    bash "$_tmp"
    rm -f "$_tmp"
else
    rm -f "$_tmp"
    echo "  ${_red}[!] Failed to fetch installer. Check token and repo permissions.${_r}"
    exit 1
fi
