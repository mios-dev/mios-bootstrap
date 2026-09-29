#!/usr/bin/env bash
# field/lib/cat.sh -- backward-compat shim; delegates to canonical field/lib/field.sh
# MiOS-Cat is DEFUNCT. This file exists only so old callers do not break.
# Source field.sh for all implementations.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/field.sh"

# Alias all old MiOS-Cat function names to their MiOS-Field counterparts.
Show_MiOSCatMenu()    { Show_MiOSFieldMenu "$@"; }
Invoke_MiOSCatStage()    { Invoke_MiOSFieldStage "$@"; }
Invoke_MiOSCatVerify()   { Invoke_MiOSFieldVerify "$@"; }
Invoke_MiOSCatInstall()  { Invoke_MiOSFieldInstall "$@"; }
Invoke_MiOSCatBuild()    { Invoke_MiOSFieldBuild "$@"; }
Invoke_MiOSCatUpdate()   { Invoke_MiOSFieldUpdate "$@"; }
Invoke_MiOSCatProvision(){ Invoke_MiOSFieldProvision "$@"; }
Invoke_MiOSCatManual()   { Invoke_MiOSFieldManual "$@"; }
