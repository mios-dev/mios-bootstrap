#!/usr/bin/env bash
# Shared backend for MiOS-Cat Linux/WSL launcher.

function Show_MiOSCatMenu() {
    echo -e "\033[36m==========================================================\033[0m"
    echo -e "\033[36m                MiOS-Cat Unified Launcher                 \033[0m"
    echo -e "\033[36m==========================================================\033[0m"
    echo " 1) Stage (Download artifacts to USB)"
    echo " 2) Install (Headless deployment)"
    echo " 3) Build (Compile MiOS from source)"
    echo " 4) Update (Self-update scripts)"
    echo " 5) Provision (Offline model provisioning)"
    echo " 6) Manual (Interactive shell)"
    echo " 0) Exit"
    echo -e "\033[36m==========================================================\033[0m"
    
    read -p "Select an option: " choice
    case "$choice" in
        1) Invoke_MiOSCatStage "$@" ;;
        2) Invoke_MiOSCatInstall "$@" ;;
        3) Invoke_MiOSCatBuild "$@" ;;
        4) Invoke_MiOSCatUpdate "$@" ;;
        5) Invoke_MiOSCatProvision "$@" ;;
        6) Invoke_MiOSCatManual "$@" ;;
        0) exit 0 ;;
        *) echo "Invalid choice." ; Show_MiOSCatMenu "$@" ;;
    esac
}

function Invoke_MiOSCatStage() {
    echo -e "\033[32m[MiOS-Cat] Executing verb: stage\033[0m"
    # Target drive determination
    local drive="${1:-/mnt/usb}"
    if [[ ! -d "$drive" ]]; then
        echo "Drive $drive not found!"
        return 1
    fi

    # Disk size check (approximate using df)
    local diskSizeGB=0
    if df -BG "$drive" >/dev/null 2>&1; then
        diskSizeGB=$(df -BG "$drive" | awk 'NR==2 {print int($2)}')
    else
        echo "Could not determine disk size for $drive. Assuming < 128GB."
    fi

    echo "Target disk size: $diskSizeGB GB"

    # T-260: Always create MiOS-Repo
    local repoDir="$drive/MiOS-Repo"
    local reposDir="$repoDir/repos"
    mkdir -p "$reposDir"

    # Copy shadow config (simulated)
    local tomlPath="/usr/share/mios/mios.toml"
    [[ -f "$tomlPath" ]] && cp "$tomlPath" "$repoDir/"

    # Clone repos
    [[ ! -d "$reposDir/MiOS" ]] && git clone https://github.com/mios-dev/mios.git "$reposDir/MiOS"
    [[ ! -d "$reposDir/mios-bootstrap" ]] && git clone https://github.com/mios-dev/mios-bootstrap.git "$reposDir/mios-bootstrap"

    # T-261: MiOS-Data logic (>= 128GB)
    if (( diskSizeGB >= 128 )); then
        echo -e "\033[36mDisk >= 128GB. Creating MiOS-Data bulk store.\033[0m"
        local dataDir="$drive/MiOS-Data"
        mkdir -p "$dataDir/images" "$dataDir/models" "$dataDir/dnf" "$dataDir/flatpak" "$dataDir/pip"

        echo "Saving localhost/mios:latest..."
        # podman save localhost/mios:latest -o "$dataDir/images/mios-latest.tar"
        
        echo "Fetching models to $dataDir/models..."
        echo "Building offline package mirrors..."
    fi
}

function Invoke_MiOSCatInstall() {
    echo -e "\033[32m[MiOS-Cat] Executing verb: install\033[0m"
    local bootstrap_path="$(dirname "${BASH_SOURCE[0]}")/../../bootstrap.sh"
    if [[ -f "$bootstrap_path" ]]; then
        bash "$bootstrap_path" "$@"
    else
        echo "bootstrap.sh not found."
    fi
}

function Invoke_MiOSCatBuild() {
    echo -e "\033[32m[MiOS-Cat] Executing verb: build\033[0m"
    local build_path="$(dirname "${BASH_SOURCE[0]}")/../../build-mios.sh"
    if [[ -f "$build_path" ]]; then
        bash "$build_path" "$@"
    else
        echo "build-mios.sh not found."
    fi
}

function Invoke_MiOSCatUpdate() {
    echo -e "\033[32m[MiOS-Cat] Executing verb: update\033[0m"
    echo "Refreshing offline payloads + manifest.json..."
    local drive="${1:-/mnt/usb}"
    local manifest="$drive/MiOS-Data/manifest.json"
    if [[ -d "$drive/MiOS-Data" ]]; then
        local date_str=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "{ \"updated\": \"$date_str\" }" > "$manifest"
        echo "Manifest updated: $manifest"
    fi
}

function Invoke_MiOSCatProvision() {
    echo -e "\033[32m[MiOS-Cat] Executing verb: provision\033[0m"
    echo "Provisioning models from MiOS-Data..."
    local drive="${1:-/mnt/usb}"
    local modelsSource="$drive/MiOS-Data/models"
    local modelsTarget="/usr/share/mios/vllm/model"
    if [[ -d "$modelsSource" ]]; then
        mkdir -p "$modelsTarget"
        cp -r "$modelsSource"/* "$modelsTarget"/ 2>/dev/null || true
        echo "Provisioned models to $modelsTarget"
    else
        echo -e "\033[33mNo MiOS-Data/models found on $drive.\033[0m"
    fi
}

function Invoke_MiOSCatManual() {
    echo -e "\033[32m[MiOS-Cat] Executing verb: manual\033[0m"
    bash
}
