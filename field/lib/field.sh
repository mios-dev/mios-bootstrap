#!/usr/bin/env bash
# Shared backend for MiOS-Field Linux/WSL launcher.
# Implements Law 9 (ONE-CANONICAL-NAME) and Task T-261 parity with MiOS-Field.psm1.
# Folded losslessly with installation/mios-common.sh (Task T-1118).

COMMON_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../installation" && pwd)/mios-common.sh"
if [[ -f "$COMMON_SH" ]]; then
    source "$COMMON_SH"
fi


function Show_MiOSFieldMenu() {
    echo -e "\033[36m==========================================================\033[0m"
    echo -e "\033[36m                MiOS-Field Unified Launcher                 \033[0m"
    echo -e "\033[36m==========================================================\033[0m"
    echo " 1) Stage (Download artifacts to USB)"
    echo " 2) Install (Headless deployment)"
    echo " 3) Build (Compile MiOS from source)"
    echo " 4) Update (Self-update scripts)"
    echo " 5) Provision (Offline model provisioning)"
    echo " 6) Manual (Interactive shell)"
    echo " 7) Verify (Validate media layout)"
    echo " 0) Exit"
    echo -e "\033[36m==========================================================\033[0m"
    
    read -p "Select an option: " choice
    case "$choice" in
        1) Invoke_MiOSFieldStage "$@" ;;
        2) Invoke_MiOSFieldInstall "$@" ;;
        3) Invoke_MiOSFieldBuild "$@" ;;
        4) Invoke_MiOSFieldUpdate "$@" ;;
        5) Invoke_MiOSFieldProvision "$@" ;;
        6) Invoke_MiOSFieldManual "$@" ;;
        7) Invoke_MiOSFieldVerify "$@" ;;
        0) exit 0 ;;
        *) echo "Invalid choice." ; Show_MiOSFieldMenu "$@" ;;
    esac
}

# Media staging and verification are implemented in installation/mios-common.sh.

function Invoke_MiOSFieldInstall() {
    echo -e "\033[32m[MiOS-Field] Executing verb: install\033[0m"
    local bootstrap_path="$(dirname "${BASH_SOURCE[0]}")/../../bootstrap.sh"
    if [[ -f "$bootstrap_path" ]]; then
        bash "$bootstrap_path" "$@"
    else
        echo "bootstrap.sh not found." >&2
        return 1
    fi
}

function Invoke_MiOSFieldBuild() {
    echo -e "\033[32m[MiOS-Field] Executing verb: build\033[0m"
    local build_path="$(dirname "${BASH_SOURCE[0]}")/../../build-mios.sh"
    if [[ -f "$build_path" ]]; then
        bash "$build_path" "$@"
    else
        echo "build-mios.sh not found." >&2
        return 1
    fi
}

function Invoke_MiOSFieldUpdate() {
    echo -e "\033[32m[MiOS-Field] Executing verb: update\033[0m"
    echo "Refreshing staged payloads and their manifest..."
    local drive="${1:-/mnt/usb}"
    local archive="$drive/MiOS-Data/images/mios-latest.tar"
    if [[ -f "$archive" ]]; then
        invoke_mios_stage "$drive" --archive "$archive"
    else
        invoke_mios_stage "$drive"
    fi
}

function Invoke_MiOSFieldProvision() {
    echo -e "\033[32m[MiOS-Field] Executing verb: provision\033[0m"
    echo "Provisioning models from MiOS-Data..."
    local drive="${1:-/mnt/usb}"
    local targetDir="${2:-/usr/share/mios/vllm/model}"
    local modelsSource="$drive/MiOS-Data/models"
    [[ -f "$modelsSource/models.json" ]] || { echo "No model inventory found on $drive." >&2; return 1; }
    python3 - "$modelsSource" "$targetDir" <<'PY'
import hashlib, json, pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
try:
    inventory = json.loads((source / 'models.json').read_text(encoding='utf-8-sig'))
    catalog = inventory['catalog']
    if not catalog:
        raise ValueError('No model weights are staged')
    for model in catalog:
        name = model['name']
        if pathlib.Path(name).name != name or name in ('.', '..'):
            raise ValueError('Invalid model name')
        path = source / name
        if not path.is_file() or path.stat().st_size != model['size_bytes']:
            raise ValueError('Model size mismatch: ' + name)
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != model['sha256']:
            raise ValueError('Model checksum mismatch: ' + name)
    target.mkdir(parents=True, exist_ok=True)
    for model in catalog:
        shutil.copy2(source / model['name'], target / model['name'])
    print(f'Provisioned {len(catalog)} verified models to {target}')
except (OSError, ValueError, KeyError, TypeError) as error:
    print(f'Model provisioning failed: {error}', file=sys.stderr)
    sys.exit(1)
PY
}

function Invoke_MiOSFieldManual() {
    echo -e "\033[32m[MiOS-Field] Executing verb: manual\033[0m"
    bash
}
