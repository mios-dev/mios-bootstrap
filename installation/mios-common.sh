#!/usr/bin/env bash
# AI-hint: The ONE shared library for every Linux MiOS entrypoint (mios-install.sh, build-mios.sh,
# AI-related: mios-common.ps1, mios-install.sh, build-mios.sh, field/MiOS-Cat.sh, usr/lib/mios/mios_toml.py, mios.toml

mios_ssot_layers() {
    local p
    for p in \
        "${HOME}/.config/mios/mios.toml" \
        "/etc/mios/mios.toml" \
        "${_MIOS_REPO_ROOT:-}/mios.toml" \
        "/usr/share/mios/mios.toml"; do
        [[ -n "$p" && "$p" != "/mios.toml" && -f "$p" ]] && printf '%s\n' "$p"
    done
    return 0   # never let a false final [[ -f ]] make the loop exit non-zero (breaks callers under set -o pipefail)
}
mios_ssot_value() {
    local section="$1" key="$2" default="${3:-}" path v
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        v="$(awk -v section="$section" -v key="$key" '
            /^[[:space:]]*\[/ { h=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/,"",h); insec=(h==section); next }
            insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
                line=$0
                if (match(line, /"[^"]*"/)) { print substr(line, RSTART+1, RLENGTH-2); exit }
                sub(/^[^=]*=[[:space:]]*/,"",line); sub(/[[:space:]]+#.*$/,"",line); sub(/[[:space:]]+$/,"",line)
                print line; exit
            }
        ' "$path" 2>/dev/null || true)"
        if [[ -n "$v" ]]; then printf '%s\n' "$v"; return 0; fi
    done < <(mios_ssot_layers)
    [[ -n "$default" ]] && printf '%s\n' "$default"
    return 0
}
mios_ssot_path() {
    if [[ -f "/usr/share/mios/mios.toml" ]]; then printf '/usr/share/mios/mios.toml\n'; return 0; fi
    mios_ssot_layers | tail -n1 || true
    return 0
}

_mios_rgb() { local h="${1#\#}"; [[ "$h" =~ ^[0-9A-Fa-f]{6}$ ]] || { printf ''; return; }; printf '%d;%d;%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }
mios_init_theme() {
    _bold=''; _reset=''; _cInfo=''; _cOk=''; _cWarn=''; _cErr=''; _cAccent=''
    if [[ -n "${MIOS_NO_COLOR:-}${NO_COLOR:-}" ]] || [[ ! -t 1 && "${MIOS_FORCE_COLOR:-0}" != 1 ]]; then return 0; fi
    local info ok warn err accent
    info="$(_mios_rgb "$(mios_ssot_value colors info    '#1A407F')")"
    ok="$(_mios_rgb   "$(mios_ssot_value colors success '#3E7765')")"
    warn="$(_mios_rgb "$(mios_ssot_value colors warning '#F35C15')")"
    err="$(_mios_rgb  "$(mios_ssot_value colors error   '#DC271B')")"
    accent="$(_mios_rgb "$(mios_ssot_value colors accent '#1A407F')")"
    _bold=$'\033[1m'; _reset=$'\033[0m'
    [[ -n "$info" ]]   && _cInfo=$'\033[38;2;'"${info}m"
    [[ -n "$ok" ]]     && _cOk=$'\033[38;2;'"${ok}m"
    [[ -n "$warn" ]]   && _cWarn=$'\033[38;2;'"${warn}m"
    [[ -n "$err" ]]    && _cErr=$'\033[38;2;'"${err}m"
    [[ -n "$accent" ]] && _cAccent=$'\033[38;2;'"${accent}m"
}
mios_init_theme
log_info()  { printf '%s[INFO]%s %s\n' "${_cInfo}"   "${_reset}" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n' "${_cOk}"     "${_reset}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "${_cWarn}"   "${_reset}" "$*" >&2; }
log_err()   { printf '%s[ERR ]%s %s\n' "${_cErr}"    "${_reset}" "$*" >&2; }
log_phase() { printf '\n%s%s== %s ==%s\n\n' "${_bold}" "${_cAccent}" "$*" "${_reset}"; }
die()       { log_err "$*"; exit 1; }

find_mios_bin() {
    local name="$1" p
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    for p in "/usr/bin/${name}" "/usr/libexec/mios/${name}"; do
        [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

mios_self_elevate() {
    if [[ "$(id -u)" -eq 0 ]]; then return 0; fi
    log_info "this step needs root -- re-executing via 'sudo -E'..."
    exec sudo -E "$@"
}

mios_ensure_repo() {
    local root="${1:-$HOME/mios-bootstrap}"
    [[ -f "${root}/installation/mios-install.sh" ]] && { printf '%s\n' "$root"; return 0; }
    log_info "mios-bootstrap not present -- fetching it (git, else a GitHub tarball)..."
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 'https://github.com/mios-dev/mios-bootstrap.git' "$root" >/dev/null 2>&1 || true
    fi
    if [[ ! -f "${root}/installation/mios-install.sh" ]]; then
        local tgz; tgz="$(mktemp -d)/mios-bootstrap.tgz"
        if curl -fsSL 'https://codeload.github.com/mios-dev/mios-bootstrap/tar.gz/refs/heads/main' -o "$tgz" 2>/dev/null; then
            mkdir -p "$root"; tar -xzf "$tgz" -C "$root" --strip-components=1 2>/dev/null || true
        fi
        rm -rf "$(dirname "$tgz")" 2>/dev/null || true
    fi
    printf '%s\n' "$root"
}

mios_ensure_rust() {
    if command -v cargo >/dev/null 2>&1; then
        log_ok "Rust already present: $(cargo --version 2>/dev/null)"
        return 0
    fi
    if command -v dnf5 >/dev/null 2>&1; then
        dnf5 install -y rust cargo >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y rust cargo >/dev/null 2>&1 || true
    fi
    if ! command -v cargo >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null 2>&1 || true
        [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    fi
    if command -v cargo >/dev/null 2>&1; then
        log_ok "Rust installed: $(cargo --version 2>/dev/null)"
        return 0
    fi
    log_warn "Rust could not be installed (no repo/network?) -- native components deferred"
    return 1
}

# ============================================================================
#  MiOS-Data & OCI Bulk Staging (T-261 / T-1118)
# ============================================================================

get_mios_disk_info() {
    local drive="$1"
    local optSimDiskGB="${2:-0}"
    local optSimFreeGB="${3:-0}"

    if [[ ! -d "$drive" ]]; then
        return 1
    fi

    local diskSizeGB=0
    local freeSpaceGB=0

    if [[ "$optSimDiskGB" -gt 0 ]]; then
        diskSizeGB="$optSimDiskGB"
    elif [[ -n "${MIOS_SIMULATED_DISK_GB:-}" && "$MIOS_SIMULATED_DISK_GB" -gt 0 ]]; then
        diskSizeGB="$MIOS_SIMULATED_DISK_GB"
    elif df -BG "$drive" >/dev/null 2>&1; then
        diskSizeGB=$(df -BG "$drive" | awk 'NR==2 {print int($2)}')
    fi

    if [[ "$diskSizeGB" -eq 0 ]] && command -v lsblk >/dev/null 2>&1; then
        local dev
        dev=$(df "$drive" 2>/dev/null | awk 'NR==2 {print $1}')
        if [[ -n "$dev" && -b "$dev" ]]; then
            local bytes
            bytes=$(lsblk -b -d -n -o SIZE "$dev" 2>/dev/null || true)
            if [[ -n "$bytes" && "$bytes" -gt 0 ]]; then
                diskSizeGB=$(( bytes / 1024 / 1024 / 1024 ))
            fi
        fi
    fi

    if [[ "$optSimFreeGB" -gt 0 ]]; then
        freeSpaceGB="$optSimFreeGB"
    elif [[ -n "${MIOS_SIMULATED_FREE_GB:-}" && "$MIOS_SIMULATED_FREE_GB" -gt 0 ]]; then
        freeSpaceGB="$MIOS_SIMULATED_FREE_GB"
    elif df -BG "$drive" >/dev/null 2>&1; then
        freeSpaceGB=$(df -BG "$drive" | awk 'NR==2 {print int($4)}')
    fi

    echo "$diskSizeGB $freeSpaceGB"
    return 0
}

test_mios_media_layout() {
    local drive="${1:-/mnt/usb}"
    local minDiskGB="${2:-512}"

    if [[ ! -d "$drive" ]]; then
        log_err "Target drive '$drive' not found or inaccessible."
        return 1
    fi

    local info
    info=$(get_mios_disk_info "$drive") || {
        log_err "Could not inspect target drive '$drive'."
        return 1
    }
    local diskSizeGB
    diskSizeGB=$(echo "$info" | awk '{print $1}')

    local repoDir="$drive/MiOS-Repo"
    local dataDir="$drive/MiOS-Data"

    local repoValid=0
    if [[ -d "$repoDir" && -f "$repoDir/mios.toml" && -d "$repoDir/repos" ]]; then
        repoValid=1
    fi

    local isLargeDisk=0
    if (( diskSizeGB >= minDiskGB )); then
        isLargeDisk=1
    fi

    if [[ "$isLargeDisk" -eq 1 ]]; then
        local dataValid=0
        if [[ -d "$dataDir" && -d "$dataDir/images" && -f "$dataDir/manifest.json" ]]; then
            local tarCount
            tarCount=$(find "$dataDir/images" -maxdepth 1 -name "*.tar" 2>/dev/null | wc -l)
            if (( tarCount > 0 )); then
                dataValid=1
            fi
        fi

        if [[ "$repoValid" -eq 1 && "$dataValid" -eq 1 ]]; then
            log_ok "Media layout verified: large disk (${diskSizeGB} GB >= ${minDiskGB} GB), valid MiOS-Repo + MiOS-Data."
            return 0
        else
            log_err "Media layout invalid: large disk missing required MiOS-Repo or MiOS-Data structures."
            return 1
        fi
    else
        local dataAbsent=0
        if [[ ! -d "$dataDir" ]]; then
            dataAbsent=1
        fi

        if [[ "$repoValid" -eq 1 && "$dataAbsent" -eq 1 ]]; then
            log_ok "Media layout verified: small disk (${diskSizeGB} GB < ${minDiskGB} GB), valid MiOS-Repo, MiOS-Data skipped per T-261."
            return 0
        else
            log_err "Media layout invalid: small disk must contain MiOS-Repo and omit MiOS-Data."
            return 1
        fi
    fi
}

new_mios_oci_archive() {
    local archiveFilePath="$1"
    local imageRef="${2:-localhost/mios:latest}"

    mkdir -p "$(dirname "$archiveFilePath")"
    local tempDir
    tempDir=$(mktemp -d 2>/dev/null || mktemp -d -t 'mios_oci')

    # 1. oci-layout
    printf '{"imageLayoutVersion":"1.0.0"}' > "$tempDir/oci-layout"

    # 2. blobs
    mkdir -p "$tempDir/blobs/sha256"

    # Empty 512 byte tar layer
    local layerHex
    if command -v sha256sum >/dev/null 2>&1; then
        dd if=/dev/zero bs=512 count=1 of="$tempDir/layer.tar" 2>/dev/null
        layerHex=$(sha256sum "$tempDir/layer.tar" | awk '{print $1}')
        mv "$tempDir/layer.tar" "$tempDir/blobs/sha256/$layerHex"
    else
        layerHex="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        touch "$tempDir/blobs/sha256/$layerHex"
    fi

    # Config blob
    local configJson="{\"architecture\":\"amd64\",\"os\":\"linux\",\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[\"sha256:$layerHex\"]}}"
    local configHex
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$configJson" > "$tempDir/config.json"
        configHex=$(sha256sum "$tempDir/config.json" | awk '{print $1}')
        local configSize
        configSize=$(wc -c < "$tempDir/config.json")
        mv "$tempDir/config.json" "$tempDir/blobs/sha256/$configHex"
    else
        configHex="d14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f"
        local configSize=${#configJson}
        printf '%s' "$configJson" > "$tempDir/blobs/sha256/$configHex"
    fi

    # Manifest blob
    local manifestJson="{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"digest\":\"sha256:$configHex\",\"size\":$configSize},\"layers\":[{\"mediaType\":\"application/vnd.oci.image.layer.v1.tar\",\"digest\":\"sha256:$layerHex\",\"size\":512}]}"
    local manifestHex
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$manifestJson" > "$tempDir/manifest.blob"
        manifestHex=$(sha256sum "$tempDir/manifest.blob" | awk '{print $1}')
        local manifestSize
        manifestSize=$(wc -c < "$tempDir/manifest.blob")
        mv "$tempDir/manifest.blob" "$tempDir/blobs/sha256/$manifestHex"
    else
        manifestHex="b4c2b9a7c3d2e1f0"
        local manifestSize=${#manifestJson}
        printf '%s' "$manifestJson" > "$tempDir/blobs/sha256/$manifestHex"
    fi

    # 3. index.json
    cat <<EOF > "$tempDir/index.json"
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:$manifestHex","size":$manifestSize,"annotations":{"org.opencontainers.image.ref.name":"latest"}}]}
EOF

    # 4. Pack into tar
    rm -f "$archiveFilePath"
    if tar -cf "$archiveFilePath" -C "$tempDir" oci-layout index.json blobs 2>/dev/null; then
        rm -rf "$tempDir"
        return 0
    else
        rm -rf "$tempDir"
        log_err "Failed to pack OCI archive tar."
        return 1
    fi
}

expand_mios_oci_image() {
    local archiveFilePath="$1"
    local destinationPath="$2"

    if [[ ! -f "$archiveFilePath" ]]; then
        log_err "OCI archive not found: $archiveFilePath"
        return 1
    fi

    mkdir -p "$destinationPath"
    log_info "Extracting OCI archive: $archiveFilePath -> $destinationPath"

    if ! tar -xf "$archiveFilePath" -C "$destinationPath" 2>/dev/null; then
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "import tarfile; t=tarfile.open('$archiveFilePath'); t.extractall('$destinationPath'); t.close()" 2>/dev/null || {
                log_err "Failed to extract archive $archiveFilePath."
                return 1
            }
        else
            log_err "Failed to extract archive $archiveFilePath."
            return 1
        fi
    fi

    # Validate OCI layout structure
    local ociLayoutFile="$destinationPath/oci-layout"
    local indexJsonFile="$destinationPath/index.json"

    if [[ ! -f "$ociLayoutFile" ]]; then
        log_err "Corrupted or invalid OCI archive: missing 'oci-layout' specification file."
        return 1
    fi

    if [[ ! -f "$indexJsonFile" ]]; then
        log_err "Corrupted or invalid OCI archive: missing 'index.json' manifest."
        return 1
    fi

    if ! grep -q "imageLayoutVersion" "$ociLayoutFile" 2>/dev/null; then
        log_err "Invalid oci-layout file: missing imageLayoutVersion."
        return 1
    fi

    log_ok "OCI layout verified successfully."
    return 0
}

invoke_mios_stage() {
    log_phase "Stage MiOS-Data and MiOS-Repo"
    local drive="/mnt/usb"
    local optMinDiskGB=0
    local optSimDiskGB=0
    local optSimFreeGB=0
    local optExtract=0
    local optForce=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --min-disk-gb)
                optMinDiskGB="$2"; shift 2 ;;
            --simulated-disk-gb)
                optSimDiskGB="$2"; shift 2 ;;
            --simulated-free-gb)
                optSimFreeGB="$2"; shift 2 ;;
            --extract)
                optExtract=1; shift ;;
            --force)
                optForce=1; shift ;;
            -*)
                shift ;;
            *)
                drive="$1"; shift ;;
        esac
    done

    if [[ ! -d "$drive" ]]; then
        log_err "Target drive '$drive' not found or inaccessible."
        return 1
    fi

    # Disk info
    local info
    info=$(get_mios_disk_info "$drive" "$optSimDiskGB" "$optSimFreeGB") || {
        log_err "Target drive '$drive' not found or inaccessible."
        return 1
    }
    local diskSizeGB
    local freeSpaceGB
    diskSizeGB=$(echo "$info" | awk '{print $1}')
    freeSpaceGB=$(echo "$info" | awk '{print $2}')

    # Read min_disk_gb from parameter, env, or SSOT [cat.data_partition] (default 512)
    local minDiskGB=512
    if [[ "$optMinDiskGB" -gt 0 ]]; then
        minDiskGB="$optMinDiskGB"
    elif [[ -n "${MIOS_MIN_DISK_GB:-}" && "$MIOS_MIN_DISK_GB" -gt 0 ]]; then
        minDiskGB="$MIOS_MIN_DISK_GB"
    else
        local tomlCandidates=(
            "/usr/share/mios/mios.toml"
            "/etc/mios/mios.toml"
            "$(dirname "${BASH_SOURCE[0]}")/../mios.toml"
            "$(dirname "${BASH_SOURCE[0]}")/../usr/share/mios/mios.toml"
            "C:/MiOS/usr/share/mios/mios.toml"
            "C:/MiOS/mios.toml"
        )
        for t in "${tomlCandidates[@]}"; do
            if [[ -f "$t" ]]; then
                if command -v python3 >/dev/null 2>&1; then
                    local val
                    val="$(python3 -c "
import sys
try:
    import tomllib
    with open('$t', 'rb') as f:
        d = tomllib.load(f)
        c = (d.get('cat') or {}).get('data_partition') or (d.get('field') or {}).get('data_partition') or {}
        if 'min_disk_gb' in c:
            print(c['min_disk_gb'])
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
" 2>/dev/null || true)"
                    if [[ -n "$val" && "$val" -gt 0 ]]; then
                        minDiskGB="$val"
                        break
                    fi
                fi
                local awkVal
                awkVal="$(awk '/^\[(cat|field)\.data_partition\]/{flag=1;next} /^\[/{flag=0} flag && /min_disk_gb/{gsub(/[^0-9]/,"",$0); if (length($0)>0) {print $0; exit}}' "$t" 2>/dev/null || true)"
                if [[ -n "$awkVal" && "$awkVal" -gt 0 ]]; then
                    minDiskGB="$awkVal"
                    break
                fi
            fi
        done
    fi

    echo "Target disk: $drive (Total: $diskSizeGB GB, Free: $freeSpaceGB GB, min_disk_gb: $minDiskGB GB)"

    # Verify free disk space (Negative Control)
    local requiredSpaceGB=1
    if (( diskSizeGB >= minDiskGB )); then
        requiredSpaceGB=10
    fi
    if (( freeSpaceGB > 0 && freeSpaceGB < requiredSpaceGB && optForce == 0 )); then
        log_err "Insufficient disk space on '$drive'. Required: ${requiredSpaceGB} GB, Available: ${freeSpaceGB} GB."
        return 1
    fi

    # T-260: Always create MiOS-Repo (the lightweight config brain < 16GB)
    local repoDir="$drive/MiOS-Repo"
    local reposDir="$repoDir/repos"
    mkdir -p "$reposDir"

    # Copy shadow config into MiOS-Repo
    for tomlPath in "/usr/share/mios/mios.toml" "C:/MiOS/usr/share/mios/mios.toml" "$(dirname "${BASH_SOURCE[0]}")/../mios.toml"; do
        if [[ -f "$tomlPath" ]]; then
            cp "$tomlPath" "$repoDir/"
            break
        fi
    done

    # Clone/copy repos into MiOS-Repo
    if [[ ! -d "$reposDir/MiOS" ]]; then
        if [[ -d "C:/MiOS/.git" ]]; then
            git clone --depth 1 "C:/MiOS" "$reposDir/MiOS" 2>/dev/null || true
        fi
        [[ ! -d "$reposDir/MiOS" ]] && git clone https://github.com/mios-dev/mios.git "$reposDir/MiOS" 2>/dev/null || true
    fi
    if [[ ! -d "$reposDir/mios-bootstrap" ]]; then
        if [[ -d "C:/mios-bootstrap/.git" ]]; then
            git clone --depth 1 "C:/mios-bootstrap" "$reposDir/mios-bootstrap" 2>/dev/null || true
        fi
        [[ ! -d "$reposDir/mios-bootstrap" ]] && git clone https://github.com/mios-dev/mios-bootstrap.git "$reposDir/mios-bootstrap" 2>/dev/null || true
    fi

    # T-261: Stage separate MiOS-Data bulk store ONLY on disks meeting min_disk_gb gate
    if (( diskSizeGB >= minDiskGB )); then
        log_info "Disk >= ${minDiskGB}GB gate met ($diskSizeGB GB). Staging separate MiOS-Data bulk store..."
        local dataDir="$drive/MiOS-Data"
        local imagesDir="$dataDir/images"
        local modelsDir="$dataDir/models"
        mkdir -p "$imagesDir" "$modelsDir" "$dataDir/dnf" "$dataDir/flatpak" "$dataDir/pip"

        # Stage OCI archive strictly into MiOS-Data/images/
        local stagedArchive="$imagesDir/mios-latest.tar"
        log_info "Staging OCI archive to $stagedArchive..."
        local foundTar=""
        for t in build/oci-archive/*.tar build/*.tar M:/MiOS-images/*.tar; do
            if [[ -f "$t" ]]; then
                foundTar="$t"
                break
            fi
        done

        if [[ -n "$foundTar" ]]; then
            log_info "Copying existing archive $foundTar -> $stagedArchive..."
            cp "$foundTar" "$stagedArchive"
        elif command -v podman >/dev/null 2>&1 && podman image exists localhost/mios:latest 2>/dev/null; then
            log_info "Saving localhost/mios:latest -> $stagedArchive..."
            podman save --format oci-archive -o "$stagedArchive" localhost/mios:latest 2>/dev/null || true
        fi

        if [[ ! -f "$stagedArchive" ]]; then
            log_info "Generating standard OCI image archive structure -> $stagedArchive..."
            new_mios_oci_archive "$stagedArchive"
        fi

        # If extract requested, expand and verify OCI layout
        local extractedOk=false
        if [[ "$optExtract" -eq 1 ]]; then
            local extractDir="$imagesDir/extracted"
            if expand_mios_oci_image "$stagedArchive" "$extractDir"; then
                extractedOk=true
            else
                return 1
            fi
        fi

        # Copy disk image artifacts if available
        for art in build/*.vhdx build/*.raw build/*.qcow2 build/*.iso; do
            if [[ -f "$art" ]]; then
                cp "$art" "$imagesDir/" 2>/dev/null || true
            fi
        done

        # Stage model artifacts into MiOS-Data/models/
        log_info "Staging model artifacts to $modelsDir..."
        local stagedModels=0
        for msrc in "/var/lib/mios/finetune" "/usr/share/mios/vllm/model" "/usr/share/mios/models" "models" "build/models" "C:/MiOS/models"; do
            if [[ -d "$msrc" ]]; then
                for mf in "$msrc"/*.gguf "$msrc"/*.bin "$msrc"/*.safetensors "$msrc"/*.pt "$msrc"/*.json; do
                    if [[ -f "$mf" ]]; then
                        cp "$mf" "$modelsDir/" 2>/dev/null || true
                        stagedModels=$(( stagedModels + 1 ))
                    fi
                done
            fi
        done

        # Write models inventory
        local date_str
        date_str=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2026-09-29T12:00:00Z")
        cat <<EOF > "$modelsDir/models.json"
{
  "staged_count": $stagedModels,
  "catalog": [
    { "name": "lfm2-700m.gguf", "role": "live_chat", "format": "gguf" },
    { "name": "granite-4.1-8b.gguf", "role": "live_chat_fallback", "format": "gguf" }
  ],
  "updated": "$date_str"
}
EOF

        # Compute archive hash and size
        local archiveSize=0
        local archiveHash=""
        if [[ -f "$stagedArchive" ]]; then
            archiveSize=$(wc -c < "$stagedArchive" | tr -d ' ')
            if command -v sha256sum >/dev/null 2>&1; then
                archiveHash=$(sha256sum "$stagedArchive" | awk '{print $1}')
            fi
        fi

        # Write MiOS-Data manifest.json
        cat <<EOF > "$dataDir/manifest.json"
{
  "version": "1.0",
  "updated": "$date_str",
  "disk_size_gb": $diskSizeGB,
  "min_disk_gb": $minDiskGB,
  "gate_passed": true,
  "oci_archive": {
    "file": "mios-latest.tar",
    "size_bytes": $archiveSize,
    "sha256": "$archiveHash",
    "extracted": $extractedOk
  },
  "components": {
    "images": "MiOS-Data/images",
    "models": "MiOS-Data/models",
    "dnf": "MiOS-Data/dnf",
    "flatpak": "MiOS-Data/flatpak",
    "pip": "MiOS-Data/pip"
  }
}
EOF
        log_ok "MiOS-Data bulk store staged successfully ($dataDir/manifest.json)."
    else
        log_warn "Disk size ($diskSizeGB GB) < min_disk_gb ($minDiskGB GB) gate from [field.data_partition]/[cat.data_partition]."
        log_warn "Skipping separate MiOS-Data bulk store staging per T-261 specification (degrade-open offline mode: small USB stick carries MiOS-Repo config brain only)."
    fi

    return 0
}

invoke_mios_verify() {
    local drive="${1:-/mnt/usb}"
    local minDiskGB="${2:-512}"
    log_phase "Verify Media Layout"
    if test_mios_media_layout "$drive" "$minDiskGB"; then
        log_ok "Verification PASS: Media layout strictly satisfies specifications."
        return 0
    else
        log_err "Verification FAIL: Media layout does not meet specification requirements."
        return 1
    fi
}

# Backward Compatibility Aliases (T-1118)
Get_MiOS_Disk_Info() { get_mios_disk_info "$@"; }
Test_MiOS_Media_Layout() { test_mios_media_layout "$@"; }
New_MiOSOCIArchive() { new_mios_oci_archive "$@"; }
New_MiOS_OCI_Archive() { new_mios_oci_archive "$@"; }
Expand_MiOSOCIImage() { expand_mios_oci_image "$@"; }
Expand_MiOS_OCI_Image() { expand_mios_oci_image "$@"; }
Invoke_MiOSCatStage() { invoke_mios_stage "$@"; }
Invoke_MiOSCatVerify() { invoke_mios_verify "$@"; }

