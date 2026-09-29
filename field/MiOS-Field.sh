#!/usr/bin/env bash
# MiOS-Field.sh -- canonical Linux/WSL launcher for MiOS-Field.
# Dispatches verbs. MiOS-Cat.sh is a defunct shim that forwards here.

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

INSTALL_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../installation/mios-install.sh"
if [[ -f "$INSTALL_SCRIPT" ]]; then
    exec bash "$INSTALL_SCRIPT" "$VERB" "${VERBARGS[@]}"
fi

case "$VERB" in
    stage)
        Invoke_MiOSFieldStage "${VERBARGS[@]}"
        ;;
    verify)
        Invoke_MiOSFieldVerify "${VERBARGS[@]}"
        ;;
    install)
        Invoke_MiOSFieldInstall "${VERBARGS[@]}"
        ;;
    wsl|import)
        Invoke_MiOSFieldInstall -Target "$VERB" "${VERBARGS[@]}"
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
        echo "Unknown verb: $VERB. Valid MiOS-Field verbs: stage, verify, install, build, update, provision, manual, wsl, import." >&2
        exit 1
        ;;
esac
