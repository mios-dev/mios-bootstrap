#!/usr/bin/env bash
# AI-hint: Thin redirector for build-mios.sh delegating to installation/mios-install.sh
# AI-related: installation/mios-install.sh, installation/mios-common.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/installation/mios-install.sh"

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "[mios] Error: ${INSTALL_SH} not found at ${INSTALL_SH}" >&2
    exit 1
fi

target="fedora"
if [[ "${INSTALL_MODE:-}" == "bootc" ]]; then
    target="bootc"
elif command -v bootc >/dev/null 2>&1 && bootc status --format=json 2>/dev/null | grep -q '"booted"'; then
    target="bootc"
fi

exec bash "$INSTALL_SH" "$target" "$@"
