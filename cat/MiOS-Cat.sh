#!/usr/bin/env bash
# MiOS-Cat.sh -- DEFUNCT shim in cat/. Delegates to canonical field/MiOS-Field.sh.
# Folded losslessly to canonical installation conventions (ADR-0013, Task T-1118).
# Delegates directly to installation/mios-install.sh.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/../installation/mios-install.sh"
if [[ ! -f "$TARGET_SCRIPT" ]]; then
    TARGET_SCRIPT="$SCRIPT_DIR/../field/MiOS-Field.sh"
fi

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    echo "[FATAL] Canonical installation script not found at: $TARGET_SCRIPT" >&2
    exit 1
fi

exec bash "$TARGET_SCRIPT" "$@"
