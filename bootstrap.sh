#!/usr/bin/env bash
# AI-hint: Legacy entry point for MiOS bootstrap phase (Linux/WSL). Redirects to MiOS-Field install.

set -e

# Canonical launcher first; the defunct MiOS-Cat shim keeps older checkouts working.
FIELD_PATH="$(dirname "${BASH_SOURCE[0]}")/field/MiOS-Field.sh"
CAT_PATH="$(dirname "${BASH_SOURCE[0]}")/field/MiOS-Cat.sh"
if [[ -f "$FIELD_PATH" ]]; then
    TARGET="$FIELD_PATH"
elif [[ -f "$CAT_PATH" ]]; then
    TARGET="$CAT_PATH"
else
    curl -fsSL "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/field/MiOS-Field.sh" | bash -s -- install "$@"
    exit $?
fi

bash "$TARGET" install "$@"
