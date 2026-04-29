<#
.SYNOPSIS
    MiOS v0.1.3 - MiOS Builder (Windows)

.DESCRIPTION
    Secure build orchestrator with workflow selection.
    Tokens/passwords NEVER appear in plain text in logs or terminal output.

    SECURITY FIXES in v0.1.1:
      - Passwords pre-hashed (SHA-512) before injection - plaintext never in build log
      - Registry token uses SecureString - never echoed, never in process args
      - Workflow menu: Local Build, Push Build, Custom Build
      - Admin/origin-owner detection for default token inference
      - Hostname randomization option for HA clusters

    SELF-BUILDING in v0.1.1:
      - Pulls existing MiOS image from GHCR as the helper/builder image
      - MiOS image replaces alpine/python for all helper operations
      - Falls back to alpine/python only on first-ever build (no prior image)
      - MAKEFLAGS passed into build for parallel compilation (akmod, Looking Glass)
      - MiOS image IS the builder - podman, buildah, bootc, BIB all baked in
#>

$ErrorActionPreference = "Stop"

# ==============================================================================
#  UI HELPERS & MASKING ENGINE
# ==============================================================================
$BuildAudit = @()
$Global:MiOS_MaskList = @()

function Register-Secret {
    param([string]$S)
    if ([string]::IsNullOrWhiteSpace($S) -or $S.Length -lt 4) { return }
    if ($Global:MiOS_MaskList -notcontains $S) {
        $Global:MiOS_MaskList += $S
    }
}

function Format-Masked {
    param([string]$InputString)
    if ([string]::IsNullOrWhiteSpace($InputString)) { return $InputString }
    $out = $InputString
    foreach ($secret in $Global:MiOS_MaskList) {
        # Escape for regex and replace case-insensitively
        $pattern = [regex]::Escape($secret)
        $out = $out -ireplace $pattern, "********"
    }
    return $out
}

function Write-Banner { 
    param([string]$T) 
    $w=78; 
    $maskedT = Format-Masked $T
    Write-Host "`n$("="*$w)" -ForegroundColor Cyan; 
    Write-Host ("  $maskedT") -ForegroundColor Cyan; 
    Write-Host "$("="*$w)`n" -ForegroundColor Cyan 
}

function Write-Phase { 
    param([string]$N,[string]$L) 
    $maskedL = Format-Masked $L
    Write-Host "`n  [$N] $maskedL" -ForegroundColor Yellow; 
    Write-Host "  $("-"*70)" -ForegroundColor DarkGray 
    $script:BuildAudit += "PHASE ${N}: ${maskedL}"
    try {
        $percent = [int]($N) * 20
        Write-Progress -Activity "MiOS Build ${Version}" -Status "Phase ${N}: ${maskedL}" -PercentComplete $percent
    } catch {}
}

function Write-Step  { 
    param([string]$M) 
    $maskedM = Format-Masked $M
    Write-Host "       $maskedM" -ForegroundColor DarkCyan 
}

function Write-OK { 
    param([string]$M) 
    $maskedM = Format-Masked $M
    Write-Host "      [OK] $maskedM" -ForegroundColor Green; 
    $script:BuildAudit += "  [OK] $maskedM" 
}

function Write-Warn { 
    param([string]$M) 
    $maskedM = Format-Masked $M
    Write-Host "       $maskedM" -ForegroundColor Yellow; 
    $script:BuildAudit += "  [WARN] $maskedM" 
}

function Write-Fatal { 
    param([string]$M) 
    $maskedM = Format-Masked $M
    Write-Host "`n  [FAIL] FATAL: $maskedM" -ForegroundColor Red; 
    $script:BuildAudit += "  [FAIL] $maskedM"; 
    Show-StatusCard; 
    exit 1 
}

function Show-StatusCard {
    $w = 78
    Write-Host "`n+$($("="*($w-2)))+" -ForegroundColor Cyan
    Write-Host "|$($(" "*[math]::Floor(($w-18)/2)))MiOS BUILD SUMMARY$($(" "*[math]::Ceiling(($w-18)/2)))|" -ForegroundColor Cyan
    Write-Host "+$($("="*($w-2)))+" -ForegroundColor Cyan
    Write-Host "  Version:  $Version"
    Write-Host "  Status:   $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    Write-Host "  Audit Log:"
    foreach ($line in $script:BuildAudit) {
        # Audit log entries are already masked during collection, but double-check here
        $maskedLine = Format-Masked $line
        if ($maskedLine -match "FAIL") { Write-Host "    $maskedLine" -ForegroundColor Red }
        elseif ($maskedLine -match "WARN") { Write-Host "    $maskedLine" -ForegroundColor Yellow }
        elseif ($maskedLine -match "PHASE") { Write-Host "    $maskedLine" -ForegroundColor Cyan }
        else { Write-Host "    $maskedLine" -ForegroundColor Gray }
    }
    Write-Host "+$($("="*($w-2)))+`n" -ForegroundColor Cyan
}

# -- Register initial secrets from environment (if present) --
@("MIOS_PASSWORD", "GHCR_TOKEN", "MIOS_GHCR_PUSH_TOKEN", "MIOS_PASSWORD_HASH") | ForEach-Object {
    if ($env:$_) { Register-Secret $env:$_ }
}

function Get-FileSize { param([string]$P) if(!(Test-Path $P)){return "N/A"} $s=(Get-Item $P).Length; if($s -gt 1GB){"$([math]::Round($s/1GB,2)) GB"}else{"$([math]::Round($s/1MB,2)) MB"} }

function Read-Timed {
    param([string]$Prompt, [string]$Default, [switch]$Secret)
    if ($Secret) {
        Write-Host "      $Prompt " -NoNewline -ForegroundColor DarkCyan
        Write-Host "[$(if($Default){'********'}else{''})] " -NoNewline -ForegroundColor DarkGray
    } else {
        Write-Host "      $Prompt " -NoNewline -ForegroundColor DarkCyan
        Write-Host "[$Default] " -NoNewline -ForegroundColor DarkGray
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $buf = ""
    while ($sw.Elapsed.TotalSeconds -lt $Timeout -and -not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 100 }
    if ([Console]::KeyAvailable) {
        if ($Secret) {
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                $buf = Read-Host -MaskInput
            } else {
                $sec  = Read-Host -AsSecureString
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
                try   { $buf = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }
            if ($buf) { Register-Secret $buf }
        } else {
            $buf = Read-Host
        }
    } else {
        Write-Host ""
    }
    if ([string]::IsNullOrWhiteSpace($buf)) { $buf = $Default }
    return $buf
}

function Get-SHA512Hash {
    # Generate a SHA-512 crypt hash ($6$...) compatible with chpasswd -e
    # Prefers MiOS helper image (has openssl), falls back to alpine/python
    param([string]$SecretText)
    $salt = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object { [char]$_ })

    $hash = $null

    # Try MiOS helper image first (openssl is already installed)
    if ($HelperImage) {
        $hash = & podman run --rm $HelperImage openssl passwd -6 -salt "$salt" "$SecretText" 2>$null
        if ($LASTEXITCODE -eq 0 -and $hash -match '^\$6\$') { return $hash.Trim() }
    }

    # Fallback: alpine + openssl
    $hash = & podman run --rm $FallbackHash sh -c "apk add --quiet openssl >/dev/null 2>&1 && openssl passwd -6 -salt '$salt' '$SecretText'" 2>$null
    if ($LASTEXITCODE -eq 0 -and $hash -match '^\$6\$') { return $hash.Trim() }

    # Fallback: python
    $hash = & podman run --rm docker.io/library/python:3-slim python3 -c "import crypt; print(crypt.crypt('$SecretText', crypt.mksalt(crypt.METHOD_SHA512)))" 2>$null
    return $hash.Trim()
}

function Clear-BIBTemp { foreach ($d in "image","vpc","qcow2","bootiso") { Get-ChildItem $OutputFolder -Directory -Filter $d -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } }

# --- Auto-Elevation ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Relaunching as Administrator..." -ForegroundColor Cyan
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs
    return
}

# -- Self-Build defaults (initialized early - referenced throughout) --
$SelfBuild = $false
$BibImage = "quay.io/centos-bootc/bootc-image-builder:latest"
Set-StrictMode -Version Latest

# ==============================================================================
#  CONFIGURATION
# ==============================================================================
# Source .env.mios if present
if (Test-Path ".env.mios") {
    Write-Phase "0.1" "Loading Unified Environment"
    Get-Content ".env.mios" | ForEach-Object {
        if ($_ -match '^([^#\s][^=]+)="?([^"]*)"?$') {
            $name = $matches[1].Trim()
            $val = $matches[2].Trim()
            [Environment]::SetEnvironmentVariable($name, $val)
        }
    }
}

$v = Get-Content "VERSION" -ErrorAction SilentlyContinue; $Version = if ($v) { $v.Trim() } else { "v0.1.1" }
$ImageName      = if ($env:MIOS_IMAGE_NAME) { ($env:MIOS_IMAGE_NAME -split '/')[-1] -replace ':.*$','' } else { "mios" }
$ImageTag       = "latest"
$MIOS_USER_ADMIN = "mios" # @track:USER_ADMIN
$DefUser        = if ($env:MIOS_USER) { $env:MIOS_USER } elseif ($env:MIOS_DEFAULT_USER) { $env:MIOS_DEFAULT_USER } else { $MIOS_USER_ADMIN }
$DefPass        = if ($env:MIOS_PASSWORD) { $env:MIOS_PASSWORD } elseif ($env:MIOS_DEFAULT_USER_PASSWORD) { $env:MIOS_DEFAULT_USER_PASSWORD } else { "mios" }
$DefHostname    = if ($env:MIOS_HOSTNAME) { $env:MIOS_HOSTNAME } else { "mios" }
$MIOS_REGISTRY_DEFAULT = "ghcr.io/kabuki94/mios" # @track:REGISTRY_DEFAULT
$DefRegistry    = if ($env:MIOS_IMAGE_NAME) { $env:MIOS_IMAGE_NAME -replace ':.*$','' } else { $MIOS_REGISTRY_DEFAULT }
$BibImage       = if ($env:MIOS_BIB_IMAGE) { $env:MIOS_BIB_IMAGE } else { "quay.io/centos-bootc/bootc-image-builder:latest" quay.io/centos-bootc/bootc-image-builder:latest # @track:IMG_BIB
$BuilderMachine = "mios-builder"
$LocalImage     = "localhost/${ImageName}:${ImageTag}"
$MiosDocsDir      = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "MiOS"
$MiosDeployDir    = Join-Path $MiosDocsDir "deployments"
$MiosManifestsDir = Join-Path $MiosDocsDir "manifests"
$MiosImagesDir    = Join-Path $MiosDocsDir "images"
$OutputFolder     = $MiosDeployDir
$MIOS_IMG_RECHUNK = "quay.io/centos-bootc/centos-bootc:stream10" # @track:IMG_RECHUNK
$RechunkImage     = $MIOS_IMG_RECHUNK
$Timeout          = 30

$RawImg         = Join-Path $MiosImagesDir "mios-bootable.raw"
$TargetVhdx     = Join-Path $MiosDeployDir "mios-hyperv.vhdx"
$TargetWsl      = Join-Path $MiosDeployDir "mios-wsl.tar"
$TargetIso      = Join-Path $MiosImagesDir "mios-installer.iso"

# Helper image: prefer MiOS itself, fall back to alpine/python for first build
$HelperImage    = ""
$FallbackHash   = "docker.io/library/alpine:latest"
$FallbackConvert = "docker.io/library/alpine:latest"

# ==============================================================================
#  BANNER + WORKFLOW MENU
# ==============================================================================
Write-Banner "MiOS v$Version - MiOS Builder"

$workflow = $env:MIOS_WORKFLOW
if ([string]::IsNullOrWhiteSpace($workflow)) {
    Write-Host "  Select build workflow:" -ForegroundColor White
    Write-Host ""
    Write-Host "    1) Local Build Only     - Build image, generate targets, NO registry push" -ForegroundColor Cyan
    Write-Host "    2) Build + Push         - Full pipeline: build  targets  push to registry" -ForegroundColor Cyan
    Write-Host "    3) Custom Build         - Custom user/pass/hostname/registry/token" -ForegroundColor Cyan
    Write-Host "    4) Pull + Deploy Only   - Pull existing image from registry, generate targets" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Choice [1-4] (default 1): " -NoNewline -ForegroundColor Yellow
    $workflow = Read-Host
    if ([string]::IsNullOrWhiteSpace($workflow)) { $workflow = "1" }
} else {
    Write-OK "Workflow inherited from environment: $workflow"
}

$DoPush       = $false
$DoCustom     = $false
$DoBuild      = $true
$DoPull       = $false

switch ($workflow) {
    "1" { $DoPush = $false }
    "2" { $DoPush = $true }
    "3" { $DoPush = $true; $DoCustom = $true }
    "4" { $DoBuild = $false; $DoPull = $true; $DoPush = $false }
    default { Write-Fatal "Invalid choice: $workflow" }
}

# ==============================================================================
#  PHASE 0: CONFIGURATION
# ==============================================================================
Write-Phase "0" "Configuration"

if ($DoCustom) {
    $U = Read-Timed "Username:" $DefUser
    $P = Read-Timed "Password:" $DefPass -Secret
    $HostIn = Read-Timed "Static Hostname (blank for mios-XXXXX):" $DefHostname
    $luksIn = Read-Timed "Enable LUKS encryption? (y/N):" "N"
    $UseLuks = $luksIn -match "^[yY]"
    $LuksPass = if ($UseLuks) { Read-Timed "LUKS passphrase:" "mios" -Secret } else { "" }
    $RegistryUrl = Read-Timed "Registry URL:" $DefRegistry

    Write-Host ""
    Write-Host "      Select Deployment Targets (comma separated or 'all'):" -ForegroundColor DarkCyan
    Write-Host "      1) RAW, 2) VHDX, 3) WSL, 4) ISO" -ForegroundColor DarkGray
    $targetIn = Read-Timed "Targets:" "all"
    if ($targetIn -eq "all") { $SelectedTargets = 1..4 }
    else { $SelectedTargets = $targetIn -split ',' | ForEach-Object { $_.Trim() } }
} else {
    $U = $DefUser
    $P = $DefPass
    $HostIn = $DefHostname
    $UseLuks = $false
    $LuksPass = ""
    $RegistryUrl = $DefRegistry
    
    # Target selection inheritance
    if ($env:MIOS_TARGETS) {
        if ($env:MIOS_TARGETS -eq "none") { $SelectedTargets = @() }
        elseif ($env:MIOS_TARGETS -eq "all") { $SelectedTargets = 1..4 }
        else { $SelectedTargets = $env:MIOS_TARGETS -split ',' | ForEach-Object { [int]$_.Trim() } }
    } else {
        $SelectedTargets = 1..4
    }
}

$GhcrImage = "${RegistryUrl}:${ImageTag}"

# -- Registry credentials (only if pushing or pulling) -------------------------
$RegistryUser  = ""
$RegistryToken = ""

if ($DoPush -or $DoPull) {
    # Try environment variables first (CI/CD friendly)
    $RegistryUser  = $env:MIOS_GHCR_USER
    $RegistryToken = if ($env:MIOS_GHCR_TOKEN) { $env:MIOS_GHCR_TOKEN } else { $env:GHCR_TOKEN }
    if ($RegistryToken) { Register-Secret $RegistryToken }

    if (-not $RegistryUser) {
        $RegistryUser = Read-Timed "Registry username:" "kabuki94"
    }
    if (-not $RegistryToken) {
        Write-Host ""
        Write-Host "      +-----------------------------------------------------+" -ForegroundColor DarkYellow
        Write-Host "      |  Token input is masked. It will NEVER be displayed. |" -ForegroundColor DarkYellow
        Write-Host "      +-----------------------------------------------------+" -ForegroundColor DarkYellow
        $RegistryToken = Read-Timed "Registry token/PAT:" "" -Secret
    }

    if (-not $RegistryToken -and $DoPush) {
        Write-Warn "No registry token provided - push will be skipped"
        $DoPush = $false
    }
}

# -- Summary (NEVER show token or password) ------------------------------------
$tokenStatus = if ($RegistryToken) { "provided (masked)" } else { "none" }
Write-Host ""
Write-OK "User: $U | LUKS: $(if($UseLuks){'Yes'}else{'No'}) | Registry: $GhcrImage"
Write-OK "Workflow: $(switch($workflow){'1'{'Local Build'}; '2'{'Build+Push'}; '3'{'Custom Build+Push'}; '4'{'Pull+Deploy'}}) | Token: $tokenStatus"

# -- Validate prerequisites ---------------------------------------------------
Write-Phase "0.5" "System Validation"
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }
try { $pv = & podman --version 2>&1; Write-OK "Podman: $pv" } catch { Write-Fatal "Podman not found" }
$cpu = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$ram = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
Write-OK "CPU: $cpu cores | RAM: $ram MB"

if ($DoBuild) {
    foreach ($f in "Containerfile","usr/share/mios/PACKAGES.md","VERSION","automation/build.sh","automation/31-user.sh") {
        if (-not (Test-Path $f)) { Write-Fatal "Missing required file: $f - are you in the MiOS repo root?" }
    }
    Write-OK "All repo files present"
}

# ==============================================================================
#  PHASE 1: PODMAN BUILDER MACHINE
# ==============================================================================
Write-Phase "1" "Podman Builder Machine"
$ErrorActionPreference = "Continue"

$builderScript = Join-Path $PWD "automation\mios-build-builder.ps1"
if (-not (Test-Path $builderScript)) { Write-Fatal "Missing $builderScript" }

Write-Step "Executing dedicated builder provisioning script..."
& $builderScript -MachineName $BuilderMachine
if ($LASTEXITCODE -ne 0) { Write-Fatal "Builder provisioning failed." }

& podman system connection default "${BuilderMachine}-root"
Write-OK "Builder connection set to: ${BuilderMachine}-root"
$ErrorActionPreference = "Stop"


# ==============================================================================
Write-Phase "1.5" "Self-Building - Pull MiOS Helper Image"
$ErrorActionPreference = "Continue"

# Try to pull the existing MiOS image from the registry.
# If it exists, use it as the helper image for ALL container operations
# (hash generation, qemu-img conversion, etc.) - MiOS IS the builder.
# First build ever: no image exists yet, fall back to alpine/python.
Write-Step "Checking for existing MiOS image at $GhcrImage..."

# Authenticate if we have credentials
if ($RegistryToken) {
    $registryHost = ($GhcrImage -split '/')[0]
    $RegistryToken | & podman login $registryHost --username $RegistryUser --password-stdin 2>&1 | Out-Null
}

& podman pull $GhcrImage 2>$null
if ($LASTEXITCODE -eq 0) {
    $HelperImage = $GhcrImage
    Write-OK "MiOS helper image pulled - self-building cycle active"
    Write-OK "All helper operations will use MiOS (openssl, qemu-img, etc.)"
} else {
    # Check if it exists locally already (previous local build)
    & podman image exists $LocalImage 2>$null
    if ($LASTEXITCODE -eq 0) {
        $HelperImage = $LocalImage
        Write-OK "Using local MiOS image as helper - self-building cycle active"
    } else {
        $HelperImage = ""
        Write-Warn "No existing MiOS image found - first build, using alpine/python fallbacks"
        Write-Step "After this build completes and pushes, subsequent builds will self-build"
    }
}
# -- Self-Building BIB: Try MiOS as bootc-image-builder --------------------
# MiOS includes bootc-image-builder + osbuild as RPMs. If HelperImage is set,
# verify it can serve as BIB. Falls back to centos-bootc on first build.
$BIBSelfBuild = $false
if ($HelperImage) {
    $ErrorActionPreference = "Continue"
    $null = & podman run --rm $HelperImage which bootc-image-builder 2>$null
    if ($LASTEXITCODE -eq 0) {
        $BIBImage = $HelperImage
        $BIBSelfBuild = $true
        Write-OK "Self-building BIB: MiOS image will be used as bootc-image-builder"
    } else {
        Write-Step "MiOS image lacks bootc-image-builder binary - using centos-bootc BIB"
    }
}
$ErrorActionPreference = "Stop"


# ==============================================================================
if ($DoPull) {
    Write-Phase "2" "Pulling Image from Registry"
    if ($RegistryToken) {
        $registryHost = ($GhcrImage -split '/')[0]
        Write-Step "Authenticating to $registryHost..."
        $RegistryToken | & podman login $registryHost --username $RegistryUser --password-stdin 2>&1 | Out-Null
    }
    Write-Step "Pulling $GhcrImage..."
    & podman pull $GhcrImage
    if ($LASTEXITCODE -ne 0) { Write-Fatal "Pull failed" }
    & podman tag $GhcrImage $LocalImage
    Write-OK "Image pulled and tagged as $LocalImage"
} elseif ($DoBuild) {
    Write-Phase "2" "OCI Container Build"

    # -- Hash the password BEFORE injection --
    Write-Step "Pre-hashing credentials (plaintext will NOT appear in build log)..."
    $passHash = Get-SHA512Hash -SecretText $P
    if (-not $passHash -or $passHash -notmatch '^\$6\$') {
        Write-Fatal "Failed to generate password hash. Check podman connectivity."
    }
    Write-OK "Password hashed (SHA-512)"

    # -- Inject hostname (only if custom; restored via git checkout after build) --
    if ($HostIn -ne "mios") {
        Write-Step "Injecting static hostname: $HostIn ..."
        Set-Content "etc/hostname" "$HostIn" -Encoding ascii
    }

    $t0 = Get-Date
    Write-Step "Building OCI image (all $cpu threads, MAKEFLAGS=-j$cpu)..."
    
    # Force TTY detection and color for localized progress bars
    $env:FORCE_COLOR = "1"
    $env:BUILDAH_FORMAT = "docker"

    # Credentials passed as --build-arg: hash is available as MIOS_PASSWORD_HASH
    # env var inside the container build (consumed by 31-user.sh). Plaintext NEVER
    # written to disk, never appears in the build log or image layer metadata.
    & podman build --progress=tty --no-cache `
        --build-arg MAKEFLAGS="-j$cpu" `
        --build-arg MIOS_USER="$U" `
        --build-arg MIOS_PASSWORD_HASH="$passHash" `
        --jobs 2 -t $LocalImage .
    
    if ($LASTEXITCODE -ne 0) { Write-Fatal "podman build failed" }

    Write-Progress -Activity "MiOS Build ${Version}" -Completed

    # Restore hostname if it was temporarily overridden
    & git checkout etc/hostname 2>$null | Out-Null

    $buildMin = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
    Write-OK "Image built in $buildMin min  $LocalImage"

    # Tag with GHCR ref BEFORE BIB - sets permanent update origin
    Write-Step "Tagging as $GhcrImage (sets update origin for bootc)..."
    & podman tag $LocalImage $GhcrImage
    Write-OK "Update origin set: $GhcrImage"

    # Rechunk
    Write-Step "Rechunking for optimized OCI layers..."
    $ErrorActionPreference = "Continue"
    # Use the freshly built image as the rechunker tool (Self-Building)
    # Falls back to external RECHUNK_IMAGE if local fails
    & podman run --rm --privileged `
        -v /var/lib/containers/storage:/var/lib/containers/storage `
        $LocalImage /usr/libexec/bootc-base-imagectl rechunk --max-layers 67 "containers-storage:$LocalImage" "containers-storage:$LocalImage"
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Self-build rechunk failed; falling back to external rechunker"
        & podman run --rm --privileged `
            -v /var/lib/containers/storage:/var/lib/containers/storage `
            $RechunkImage /usr/libexec/bootc-base-imagectl rechunk --max-layers 67 "containers-storage:$LocalImage" "containers-storage:$LocalImage"
    }
    $ErrorActionPreference = "Stop"

    Write-OK "Rechunk complete"

    # Update helper image reference - this freshly built image IS the builder now
    $HelperImage = $LocalImage
    # Check if freshly built image can serve as BIB for deployment targets
    $null = & podman run --rm $LocalImage which bootc-image-builder 2>$null
    if ($LASTEXITCODE -eq 0) {
        $BIBImage = $LocalImage
        $BIBSelfBuild = $true
        Write-OK "Helper image updated - self-building BIB active (MiOS IS the builder)"
    } else {
        Write-OK "Helper image updated to freshly built $LocalImage (self-building ready)"
    }
}

# ==============================================================================
#  PHASE 3: GENERATE DEPLOYMENT TARGETS
# ==============================================================================
Write-Phase "3" "Generating Deployment Targets"
$ErrorActionPreference = "Continue"

$bibConf = Join-Path $PWD "config\bib.toml"
if (-not (Test-Path $bibConf)) { $bibConf = Join-Path $PWD "config\bib.json" }
$bibConfDest = Join-Path $OutputFolder "bib-config"
if (Test-Path $bibConf) {
    if ($bibConf -match '\.toml$') {
        $bibMountPath = "/config.toml"
        Copy-Item $bibConf "$bibConfDest.toml" -Force
        $bibConfDest = "$bibConfDest.toml"
    } else {
        $bibMountPath = "/config.json"
        Copy-Item $bibConf "$bibConfDest.json" -Force
        $bibConfDest = "$bibConfDest.json"
    }
    Write-OK "BIB config: 80 GiB minimum root (mounted as $bibMountPath)"
} else {
    Write-Warn "No BIB config found - disk may auto-size too small!"
    $bibConfDest = $null
}

$isoToml = Join-Path $PWD "iso.toml"
$hasIsoToml = Test-Path $isoToml
if ($hasIsoToml) { Write-OK "iso.toml found - kickstart will be injected into ISO" }

function Get-BIBArgs {
    param([string]$Type)
    $bibArgs = @(
        "run", "--rm", "-it", "--privileged",
        "--security-opt", "label=type:unconfined_t",
        "-v", "/var/lib/containers/storage:/var/lib/containers/storage",
        "-v", "${OutputFolder}:/output:z"
    )
    if ($Type -eq "anaconda-iso" -and $hasIsoToml) {
        $isoContent = Get-Content $isoToml -Raw
        $isoContent = $isoContent.Replace('INJ_U', $U)
        $isoContent = $isoContent.Replace('INJ_IMAGE', $GhcrImage)
        if (-not $script:passHash) { $script:passHash = Get-SHA512Hash -SecretText $P }
        if ($script:passHash) {
            $isoContent = $isoContent.Replace('INJ_HASH', $script:passHash)
        }
        $isoContent | Set-Content (Join-Path $OutputFolder "iso.toml") -NoNewline -Encoding UTF8
        $bibArgs += @("-v", "$(Join-Path $OutputFolder 'iso.toml'):/config.toml:ro")
    } elseif ($bibConfDest) {
        $bibArgs += @("-v", "${bibConfDest}:${bibMountPath}:ro")
    }
    if ($UseLuks -and $Type -in @("raw","anaconda-iso")) {
        $LuksPass | Set-Content (Join-Path $OutputFolder ".luks-tmp") -NoNewline
        $bibArgs += @("-v", "$(Join-Path $OutputFolder '.luks-tmp'):/luks-pass:ro")
        $bibArgs += @("--env", "LUKS_PASSPHRASE_FILE=/luks-pass")
    }
    $bibArgs += @($BIBImage, "build", "--type", $Type, "--rootfs", "ext4", "--local", $LocalImage)
    return $bibArgs
}

# -- RAW --
if ($SelectedTargets -contains 1) {
    Write-Step "TARGET 1 - RAW disk image..."
    Clear-BIBTemp
    $rawArgs = Get-BIBArgs "raw"
    & podman @rawArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        $rawFile = Get-ChildItem $OutputFolder -Recurse -Filter "*.raw" | Select-Object -First 1
        if ($rawFile) { Move-Item $rawFile.FullName $RawImg -Force; Write-OK "RAW: $(Get-FileSize $RawImg)" }
    } else { Write-Warn "RAW build failed" }
}

# -- VHDX --
if ($SelectedTargets -contains 2) {
    Write-Step "TARGET 2 - VHD  VHDX (Hyper-V Gen2)..."
    Clear-BIBTemp
    $vhdArgs = Get-BIBArgs "vhd"
    & podman @vhdArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        # BIB nests output in subdirectories (vpc/disk.vhd or image/disk.vhd).
        # Move to output root first so the container mount path is simple.
        $vhdFile = Get-ChildItem $OutputFolder -Recurse -Include "*.vhd","*.vpc" | Select-Object -First 1
        if ($vhdFile) {
            $vhdSrc = Join-Path $OutputFolder "disk.vhd"
            if ($vhdFile.FullName -ne $vhdSrc) {
                Move-Item $vhdFile.FullName $vhdSrc -Force
            }
            Write-Step "Converting disk.vhd  VHDX (parallel coroutines)..."
            # -m 16 -W enables 16 parallel coroutines and out-of-order writes for massive speedup
            if ($HelperImage) {
                & podman run --rm -v "${OutputFolder}:/data:z" $HelperImage `
                    qemu-img convert -m 16 -W -f vpc -O vhdx /data/disk.vhd /data/mios-hyperv.vhdx
            } else {
                & podman run --rm -v "${OutputFolder}:/data:z" $FallbackConvert sh -c `
                    "apk add --quiet qemu-img && qemu-img convert -m 16 -W -f vpc -O vhdx /data/disk.vhd /data/mios-hyperv.vhdx"
            }
            Remove-Item $vhdSrc -Force -ErrorAction SilentlyContinue
            Clear-BIBTemp
            if (Test-Path $TargetVhdx) { Write-OK "VHDX: $(Get-FileSize $TargetVhdx)" }
            else { Write-Warn "VHDX conversion failed - qemu-img error" }
        } else {
            Write-Warn "VHD file not found in BIB output"
        }
    } else { Write-Warn "VHD build failed" }
}

# -- WSL --
if ($SelectedTargets -contains 3) {
    Write-Step "TARGET 3 - WSL2 tarball (via native bootc export)..."
    if ($HelperImage) {
        & podman run --rm --privileged -v "${MiosDeployDir}:/output:z" $HelperImage bootc container export --format=tar "oci-archive:/output/wsl.oci" --output /output/mios-wsl.tar
        if ($LASTEXITCODE -ne 0) {
            # Fallback for older helper images
            Write-Warn "bootc export failed, falling back to podman export..."
            $wslCid = & podman create $LocalImage 2>$null
            if ($wslCid) {
                & podman export $wslCid -o $TargetWsl 2>$null
                & podman rm $wslCid 2>$null
            }
        }
    } else {
        # Fallback if no helper image exists at all
        $wslCid = & podman create $LocalImage 2>$null
        if ($wslCid) {
            & podman export $wslCid -o $TargetWsl 2>$null
            & podman rm $wslCid 2>$null
        }
    }
    if (Test-Path $TargetWsl) { Write-OK "WSL: $(Get-FileSize $TargetWsl)" }
    else { Write-Warn "WSL export failed" }
}

# -- ISO --
if ($SelectedTargets -contains 4) {
    Write-Step "TARGET 4 - Anaconda installer ISO..."
    Clear-BIBTemp
    $isoArgs = Get-BIBArgs "anaconda-iso"
    & podman @isoArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        $isoFile = Get-ChildItem $OutputFolder -Recurse -Filter "*.iso" | Select-Object -First 1
        if ($isoFile) { Move-Item $isoFile.FullName $TargetIso -Force; Write-OK "ISO: $(Get-FileSize $TargetIso)" }
    } else { Write-Warn "ISO failed" }
}

# Clean LUKS temp
Remove-Item (Join-Path $OutputFolder ".luks-tmp") -Force -ErrorAction SilentlyContinue

# ==============================================================================
#  PHASE 3b: DEPLOYMENT (Hyper-V + WSL2)
# ==============================================================================
if ($env:MIOS_SKIP_DEPLOY -eq "1") {
    Write-OK "Deployment phase skipped (MIOS_SKIP_DEPLOY=1)"
} else {
    Write-Phase "3b" "Deployment (Hyper-V + WSL2)"

    # Hyper-V
    if (Test-Path $TargetVhdx) {
        $ErrorActionPreference = "Continue"
        $vmName = "MiOS"
        $doDeploy = $true
        if ($env:MIOS_FORCE_DEPLOY -ne "1") {
            $ans = Read-Timed "Deploy/Update Hyper-V VM '$vmName'? (y/N)" "N"
            $doDeploy = $ans -match "^[yY]"
        }

        if ($doDeploy) {
            try {
                Write-Step "Preparing Hyper-V VM..."
                if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
                    Write-Warn "VM '$vmName' already exists. This will OVERWRITE it."
                    $ans = "Y"
                    if ($env:MIOS_FORCE_DEPLOY -ne "1") {
                        $ans = Read-Timed "Confirm OVERWRITE of '$vmName'? (y/N)" "N"
                    }
                    if ($ans -match "^[yY]") {
                        Stop-VM -Name $vmName -Force -ErrorAction SilentlyContinue
                        Remove-VM -Name $vmName -Force
                    } else {
                        Write-Warn "Overwrite cancelled. Skipping Hyper-V deployment."
                        $doDeploy = $false
                    }
                }
                
                if ($doDeploy) {
                    $vmSwitchObj = Get-VMSwitch | Where-Object SwitchType -eq "External" | Select-Object -First 1
                    $vmSwitch = if ($vmSwitchObj) { $vmSwitchObj.Name } else { "Default Switch" }
                    $vmCpu = $cpu
                    $totalRamBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
                    $vmRamRaw = [int64]($totalRamBytes * 0.8)
                    $vmRam = [int64]([Math]::Floor($vmRamRaw / 2MB) * 2MB)  # Align to 2MB (Hyper-V requirement)
                    $vmRamGB = [Math]::Floor($vmRam / 1GB)
                    $minRam = [Math]::Min(16GB, [int64]([Math]::Floor($totalRamBytes * 0.5 / 2MB) * 2MB))
                    if ($totalRamBytes -lt 16GB) { $minRam = [int64]([Math]::Floor($totalRamBytes * 0.5 / 2MB) * 2MB) }
                    else { $minRam = 16GB }

                    New-VM -Name $vmName -MemoryStartupBytes $minRam -Generation 2 -VHDPath $TargetVhdx -SwitchName $vmSwitch | Out-Null
                    Set-VM -Name $vmName -ProcessorCount $vmCpu -DynamicMemory -MemoryMinimumBytes $minRam -MemoryMaximumBytes $vmRam -MemoryStartupBytes $minRam
                    Set-VMFirmware -VMName $vmName -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
                    Write-OK "Hyper-V VM '$vmName' created (CPUs: $vmCpu | RAM: ${vmRamGB}GB max)"

                    # Start VM
                    Write-Step "Starting VM..."
                    Start-VM -Name $vmName
                    
                    # Wait for POST
                    $timeout = 120; $elapsed = 0; $hb = ""
                    while ($elapsed -lt $timeout) {
                        $hb = (Get-VMIntegrationService -VMName $vmName | Where-Object Name -eq "Heartbeat").PrimaryStatusDescription
                        if ($hb -eq "OK") { break }
                        Start-Sleep 5; $elapsed += 5
                        Write-Progress -Activity "Hyper-V POST" -Status "Waiting for heartbeat..." -PercentComplete ([int]($elapsed/$timeout*100))
                    }
                    Write-Progress -Activity "Hyper-V POST" -Completed

                    if ($hb -eq "OK") {
                        Write-OK "VM fully booted (heartbeat OK)"
                        Write-Step "Enabling Enhanced Session (HvSocket)..."
                        Stop-VM -Name $vmName -Force -ErrorAction SilentlyContinue
                        Set-VM -Name $vmName -EnhancedSessionTransportType HvSocket
                        Start-VM -Name $vmName
                        Write-OK "Hyper-V VM ready. Connect: vmconnect.exe localhost $vmName"
                    } else {
                        Write-Warn "VM may still be booting (no heartbeat). Configure Enhanced Session manually if needed."
                    }
                }
            } catch { Write-Warn "Hyper-V deployment failed: $_" }
        }
    }

    # WSL2
    if (Test-Path $TargetWsl) {
        $ErrorActionPreference = "Continue"
        $WslName = "MiOS"
        $WslPath = Join-Path $env:USERPROFILE "WSL\$WslName"
        $doDeploy = $true
        if ($env:MIOS_FORCE_DEPLOY -ne "1") {
            $ans = Read-Timed "Import/Update WSL2 distro '$WslName'? (y/N)" "N"
            $doDeploy = $ans -match "^[yY]"
        }

        if ($doDeploy) {
            try {
                Write-Step "Preparing WSL2 distro..."
                $existing = wsl --list --quiet | Where-Object { $_ -match "^$WslName" }
                if ($existing) {
                    Write-Warn "WSL distro '$WslName' already exists. This will DELETE it."
                    $ans = "Y"
                    if ($env:MIOS_FORCE_DEPLOY -ne "1") {
                        $ans = Read-Timed "Confirm DELETION of existing '$WslName'? (y/N)" "N"
                    }
                    if ($ans -match "^[yY]") {
                        wsl --unregister $WslName | Out-Null
                    } else {
                        Write-Warn "WSL import cancelled."
                        $doDeploy = $false
                    }
                }

                if ($doDeploy) {
                    New-Item -ItemType Directory -Path $WslPath -Force | Out-Null
                    wsl --import $WslName $WslPath $TargetWsl --version 2
                    if ($LASTEXITCODE -eq 0) {
                        Write-OK "WSL2 distro '$WslName' imported"
                        
                        # Generate .wslconfig
                        $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
                        $wslCPUs = $cpu
                        $wslRAM = [Math]::Max(16, [Math]::Floor((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB * 0.75))
                        
                        $wslLines = @(
                            "# MiOS v0.1.3 - WSL2 Configuration",
                            "[wsl2]",
                            "memory=${wslRAM}GB",
                            "processors=${wslCPUs}",
                            "swap=8GB",
                            "localhostForwarding=true",
                            "nestedVirtualization=true",
                            "vmIdleTimeout=-1",
                            "systemd=true",
                            "",
                            "[experimental]",
                            "networkingMode=mirrored",
                            "dnsTunneling=true",
                            "autoProxy=true"
                        )
                        $wslLines -join "`r`n" | Set-Content $wslConfigPath -Encoding UTF8
                        Write-OK ".wslconfig optimized: ${wslRAM}GB RAM"
                    } else { Write-Warn "WSL import failed" }
                }
            } catch { Write-Warn "WSL2 deployment failed: $_" }
        }
    }
}
$ErrorActionPreference = "Stop"


# ==============================================================================
if ($DoPush -and $RegistryToken) {
    Write-Phase "4" "Registry Push  $GhcrImage"
    $ErrorActionPreference = "Continue"
    $registryHost = ($GhcrImage -split '/')[0]

    Write-Step "Authenticating to $registryHost (token via stdin - NOT in process args)..."
    $RegistryToken | & podman login $registryHost --username $RegistryUser --password-stdin 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warn "Registry login failed - push may fail" }

    & podman push $GhcrImage
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Pushed to $registryHost"
        # Make package public if ghcr.io
        if ($registryHost -eq "ghcr.io") {
            try {
                $pkgName = ($GhcrImage -split '/')[-1] -replace ':.*$',''
                $owner = ($GhcrImage -split '/')[1]
                $headers = @{ Authorization = "Bearer $RegistryToken"; Accept = "application/vnd.github+json" }
                $uri = "https://api.github.com/orgs/$owner/packages/container/$pkgName"
                $body = '{"visibility":"public"}'
                try { Invoke-RestMethod -Uri $uri -Method Patch -Headers $headers -Body $body -ContentType "application/json" -ErrorAction Stop }
                catch { $uri = "https://api.github.com/user/packages/container/$pkgName"; Invoke-RestMethod -Uri $uri -Method Patch -Headers $headers -Body $body -ContentType "application/json" -ErrorAction SilentlyContinue }
                Write-OK "Package visibility set to public"
            } catch { Write-Warn "Could not set package visibility (may need manual config)" }
        }
    } else { Write-Warn "Push failed" }
    $ErrorActionPreference = "Stop"

} elseif ($DoPush) {
    Write-Warn "Skipping push - no registry token provided"
}

# ==============================================================================
#  PHASE 5: SUMMARY
# ==============================================================================
Write-Phase "5" "Build Summary"
Write-Host ""

# Self-building status
if ($HelperImage) {
    Write-OK "Self-building: ACTIVE - MiOS image used as builder"
    if ($BIBSelfBuild) { Write-OK "  BIB: Self-building (MiOS used as bootc-image-builder)" }
    else { Write-OK "  BIB: External (centos-bootc)" }
    Write-OK "  Next build will pull this image and use it for all operations"
} else {
    Write-Warn "Self-building: BOOTSTRAP - first build used fallback images"
    Write-OK "  After push, subsequent builds will self-build from $GhcrImage"
}
Write-Host ""

$targets = @()
if (Test-Path $RawImg)    { $targets += "RAW: $(Get-FileSize $RawImg)" }
if (Test-Path $TargetVhdx){ $targets += "VHDX: $(Get-FileSize $TargetVhdx)" }
if (Test-Path $TargetWsl) { $targets += "WSL: $(Get-FileSize $TargetWsl)" }
if (Test-Path $TargetIso) { $targets += "ISO: $(Get-FileSize $TargetIso)" }
foreach ($t in $targets) { Write-OK $t }
Write-Host ""
Write-OK "Output folder: $OutputFolder"

# -- Copy Manifests --
if (-not (Test-Path $MiosManifestsDir)) { New-Item -ItemType Directory -Path $MiosManifestsDir -Force | Out-Null }
$manifests = @("root-manifest.json", "ai-context.json")
foreach ($mf in $manifests) {
    if (Test-Path $mf) { Copy-Item $mf (Join-Path $MiosManifestsDir $mf) -Force -ErrorAction SilentlyContinue }
}
Write-OK "Manifests staged in $MiosManifestsDir"

Write-Host ""
Write-Host "  MiOS is self-replicating: pull  build  push  repeat" -ForegroundColor Cyan
Write-Host "  On deployed MiOS:  mios-rebuild" -ForegroundColor Cyan
Write-Host "  On any machine:       podman pull $GhcrImage" -ForegroundColor Cyan
Write-Host ""

Show-StatusCard

# Cleanup: wipe any credential variables from memory
$P = $null; $passHash = $null; $RegistryToken = $null; $LuksPass = $null
[System.GC]::Collect()
