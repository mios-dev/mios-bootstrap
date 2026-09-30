#!/usr/bin/env bash
# MiOS-Field.sh -- canonical Linux/WSL launcher for MiOS.
# Implements Law 9 (ONE-CANONICAL-NAME). Dispatches verbs.

set -e

VERB="$1"
shift || true
VERBARGS=("$@")

LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/field.sh"
if [[ ! -f "$LIB_PATH" ]]; then
    echo "Backend library not found at $LIB_PATH" >&2
    exit 1
fi
source "$LIB_PATH"

if [[ -z "$VERB" ]]; then
    Show_MiOSFieldMenu "${VERBARGS[@]}"
    exit $?
fi

case "$VERB" in
    flash|live)
        Show_MiOSFieldMenu "${VERBARGS[@]}"
        ;;
    stage)
        Invoke_MiOSFieldStage "${VERBARGS[@]}"
        ;;
    verify)
        Invoke_MiOSFieldVerify "${VERBARGS[@]}"
        ;;
    install)
        Invoke_MiOSFieldInstall "${VERBARGS[@]}"
        ;;
    build)
        Invoke_MiOSFieldBuild "${VERBARGS[@]}"
        ;;
    update)
        Invoke_MiOSFieldUpdate "${VERBARGS[@]}"
        ;;
    provision)
        Invoke_MiOSFieldProvision "${VERBARGS[@]}"
        ;;
    manual)
        Invoke_MiOSFieldManual "${VERBARGS[@]}"
        ;;
    *)
        INSTALL_SCRIPT="${_MIOS_REPO_ROOT}/installation/mios-install.sh"
        if [[ ! -f "$INSTALL_SCRIPT" ]]; then
            echo "MiOS installer not found: $INSTALL_SCRIPT" >&2
            exit 1
        fi
        exec bash "$INSTALL_SCRIPT" "$VERB" "${VERBARGS[@]}"
        ;;
esac
