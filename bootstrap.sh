#!/usr/bin/env bash
# AI-hint: Legacy entry point for MiOS bootstrap phase (Linux/WSL). Redirects to MiOS-Field install.

set -e

# Use local cat if available (cloned tree), otherwise fetch from main
FIELD_PATH="$(dirname "${BASH_SOURCE[0]}")/field/MiOS-Field.sh"
if [[ ! -f "$FIELD_PATH" ]]; then
    curl -fsSL "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/field/MiOS-Field.sh" | bash -s -- install "$@"
    exit $?
fi

bash "$FIELD_PATH" install "$@"
