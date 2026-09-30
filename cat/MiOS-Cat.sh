#!/usr/bin/env bash
# Legacy path retained for existing media. The canonical launcher is field/MiOS-Cat.sh.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/../field/MiOS-Cat.sh"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    echo "[FATAL] Canonical field script not found at: $TARGET_SCRIPT" >&2
    exit 1
fi

exec bash "$TARGET_SCRIPT" "$@"
