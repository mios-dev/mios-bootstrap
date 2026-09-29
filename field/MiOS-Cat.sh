#!/usr/bin/env bash
# MiOS-Cat.sh -- canonical Linux/WSL launcher for MiOS.
# Implements Law 9 (ONE-CANONICAL-NAME). Dispatches verbs.

set -e

VERB="$1"
shift || true
VERBARGS=("$@")

LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/cat.sh"
if [[ ! -f "$LIB_PATH" ]]; then
    echo "Backend library not found at $LIB_PATH" >&2
    exit 1
fi
source "$LIB_PATH"

if [[ -z "$VERB" ]]; then
    Show_MiOSCatMenu "${VERBARGS[@]}"
    exit $?
fi

case "$VERB" in
    stage)
        Invoke_MiOSCatStage "${VERBARGS[@]}"
        ;;
    verify)
        Invoke_MiOSCatVerify "${VERBARGS[@]}"
        ;;
    install)
        Invoke_MiOSCatInstall "${VERBARGS[@]}"
        ;;
    wsl|import)
        Invoke_MiOSCatInstall -Target "$VERB" "${VERBARGS[@]}"
        ;;
    build)
        Invoke_MiOSCatBuild "${VERBARGS[@]}"
        ;;
    update)
        Invoke_MiOSCatUpdate "${VERBARGS[@]}"
        ;;
    provision)
        Invoke_MiOSCatProvision "${VERBARGS[@]}"
        ;;
    manual)
        Invoke_MiOSCatManual "${VERBARGS[@]}"
        ;;
    *)
        echo "Unknown verb: $VERB. Valid verbs: stage, verify, install, build, update, provision, manual, wsl, import." >&2
        exit 1
        ;;
esac
