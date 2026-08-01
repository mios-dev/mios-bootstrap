#!/usr/bin/env bash
# AI-hint: Legacy entry point for MiOS full install (Linux/WSL). Redirects to MiOS-Cat install.

set -e

CAT_PATH="$(dirname "${BASH_SOURCE[0]}")/cat/MiOS-Cat.sh"
if [[ ! -f "$CAT_PATH" ]]; then
    curl -fsSL "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/cat/MiOS-Cat.sh" | bash -s -- install "$@"
    exit $?
fi

bash "$CAT_PATH" install "$@"
