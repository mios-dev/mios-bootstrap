#!/usr/bin/env bash
# MiOS-Cat.sh -- DEFUNCT backward-compat shim. Delegates to canonical MiOS-Field.sh.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/MiOS-Field.sh" "$@"
