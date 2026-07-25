#!/usr/bin/env bash
# AI-hint: Thin host-aware redirector script delegating to installation/mios-install.sh (AGY-106).
set -euo pipefail

# Redirector to unified Linux installer (AGY-106)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="fedora"
if command -v bootc >/dev/null 2>&1 && bootc status >/dev/null 2>&1; then
    TARGET="bootc"
elif [[ -f /run/ostree-booted ]]; then
    TARGET="bootc"
fi

if [[ -f "${SCRIPT_DIR}/installation/mios-install.sh" ]]; then
    exec bash "${SCRIPT_DIR}/installation/mios-install.sh" "$TARGET" "$@"
elif [[ -f "${SCRIPT_DIR}/../mios-bootstrap/installation/mios-install.sh" ]]; then
    exec bash "${SCRIPT_DIR}/../mios-bootstrap/installation/mios-install.sh" "$TARGET" "$@"
else
    echo "[build-mios] Error: installation/mios-install.sh not found." >&2
    exit 1
fi
