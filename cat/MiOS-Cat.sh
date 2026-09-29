#!/usr/bin/env bash
# MiOS-Cat.sh -- canonical launcher shim for MiOS in cat/
# Implements Law 9 (ONE-CANONICAL-NAME). Delegates to field/MiOS-Cat.sh.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/../field/MiOS-Cat.sh"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    echo "[FATAL] Canonical field script not found at: $TARGET_SCRIPT" >&2
    exit 1
fi

exec bash "$TARGET_SCRIPT" "$@"
