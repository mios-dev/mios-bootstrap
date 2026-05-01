# MiOS Unified Bootstrap v2 - Windows (PowerShell 5.1+)
# Repository: MiOS-DEV/MiOS-bootstrap
# Single-pass configuration wizard - ALL variables collected upfront
# Usage: irm https://raw.githubusercontent.com/MiOS-DEV/MiOS-bootstrap/main/bootstrap-v2.ps1 | iex

$ErrorActionPreference = "Stop"

# ============================================================================
# XDG-Style Directory Structure (Windows-adapted)
# ============================================================================
$XDG_DATA_HOME = Join-Path $env:LOCALAPPDATA "MiOS"          # ~/.local/share/mios
$XDG_CONFIG_HOME = Join-Path $env:APPDATA "MiOS"             # ~/.config/mios
$XDG_CACHE_HOME = Join-Path $env:LOCALAPPDATA "MiOS\cache"   # ~/.cache/mios
$XDG_STATE_HOME = Join-Path $env:LOCALAPPDATA "MiOS\state"   # ~/.local/state/mios

$MiosConfigFile = Join-Path $XDG_CONFIG_HOME "registry.toml" # Single source of truth
$MiosEnvFile = Join-Path $XDG_CONFIG_HOME "build.env"        # Legacy support
$MiosSecretsFile = Join-Path $XDG_STATE_HOME "secrets.env"   # SHA-512 hashes + tokens
$MiosLogsDir = Join-Path $XDG_STATE_HOME "logs"
$MiosBuildDir = Join-Path $XDG_CACHE_HOME "builds"
$MiosRepoDir = Join-Path $XDG_DATA_HOME "repo"

$PublicInstaller = "https://raw.githubusercontent.com/MiOS-DEV/MiOS-bootstrap/main/mios-build-local.ps1"

# ============================================================================
# Helper Functions
# ============================================================================

function Set-SecureACL {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    try {
        $acl = Get-Acl $Path
        $acl.SetAccessRuleProtection($true, $false)
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $currentUser, "FullControl", "Allow"
        )
        $acl.AddAccessRule($rule)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "Administrators", "FullControl", "Allow"
        )
        $acl.AddAccessRule($adminRule)
        Set-Acl $Path $acl
    } catch {
        Write-Host "  [!] Warning: Could not restrict permissions on $Path" -ForegroundColor Yellow
    }
}

function Read-Secret {
    param([string]$Prompt)
    Write-Host "  $Prompt " -NoNewline -ForegroundColor White
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return Read-Host -MaskInput
    }
    $sec  = Read-Host -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-WithDefault {
    param([string]$Prompt, [string]$Default = "")
    Write-Host "  $Prompt " -NoNewline -ForegroundColor White
    if ($Default) { Write-Host "[$Default] " -NoNewline -ForegroundColor DarkGray }
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val
}

function Get-SHA512Hash {
    param([string]$PlainText)
    $salt = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })

    # Try WSL openssl first (fastest, no container pull needed)
    try {
        $hash = & wsl openssl passwd -6 -salt $salt $PlainText 2>$null
        if ($LASTEXITCODE -eq 0 -and $hash -match '^\$6\$') { return $hash.Trim() }
    } catch {}

    # Fallback: MiOS helper image
    $HelperImage = "ghcr.io/mios-dev/mios:latest"
    try {
        $hash = & podman run --rm $HelperImage openssl passwd -6 -salt $salt $PlainText 2>$null
        if ($LASTEXITCODE -eq 0 -and $hash -match '^\$6\$') { return $hash.Trim() }
    } catch {}

    # Fallback: alpine
    try {
        $hash = & podman run --rm docker.io/library/alpine:latest sh -c "apk add --quiet openssl >/dev/null 2>&1 && openssl passwd -6 -salt '$salt' '$PlainText'" 2>$null
        if ($LASTEXITCODE -eq 0 -and $hash -match '^\$6\$') { return $hash.Trim() }
    } catch {}

    throw "Failed to generate sha512crypt hash. Ensure WSL or Podman is available."
}

# ============================================================================
# Main Wizard
# ============================================================================

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║  MiOS v0.2.0 -- Unified Bootstrap Wizard                         ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This wizard collects ALL configuration variables ONCE," -ForegroundColor Gray
Write-Host "  then propagates them through the entire build pipeline." -ForegroundColor Gray
Write-Host ""

# Stage directories
Write-Host "  [1/7] Creating XDG-compliant directories..." -ForegroundColor Yellow
foreach ($d in @($XDG_DATA_HOME, $XDG_CONFIG_HOME, $XDG_CACHE_HOME, $XDG_STATE_HOME, $MiosLogsDir, $MiosBuildDir, $MiosRepoDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "    Created: $d" -ForegroundColor DarkGray
    }
}
Write-Host "  [OK]" -ForegroundColor Green
Write-Host ""

# Configure WSL2
Write-Host "  [2/7] Configuring WSL2 for MiOS..." -ForegroundColor Yellow
try {
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    $totalRAM = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
    $wslRAM = [Math]::Max(16, [Math]::Floor($totalRAM / 1GB * 0.80))
    $wslCPUs = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

    $wslConfig = @"
# MiOS v0.2.0 - WSL2 Configuration
[wsl2]
memory=${wslRAM}GB
processors=${wslCPUs}
swap=8GB
localhostForwarding=true
nestedVirtualization=true
vmIdleTimeout=-1
systemd=true

[experimental]
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
"@

    if (Test-Path $wslConfigPath) {
        $backup = "${wslConfigPath}.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $wslConfigPath $backup -Force
        Write-Host "    Backed up existing .wslconfig to $backup" -ForegroundColor DarkGray
    }
    $wslConfig | Set-Content $wslConfigPath -Encoding UTF8
    Write-Host "  [OK] ${wslRAM}GB RAM, $wslCPUs CPUs" -ForegroundColor Green
} catch {
    Write-Host "  [!] Failed to configure .wslconfig (non-fatal)" -ForegroundColor Yellow
}
Write-Host ""

# ============================================================================
# Phase 3: Collect ALL Variables Upfront
# ============================================================================

Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "  ║  [3/7] Configuration Collection - Answer ALL questions below     ║" -ForegroundColor Yellow
Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""

# User Account
Write-Host "  ┌─ User Account ────────────────────────────────────────────────┐" -ForegroundColor Cyan
$MIOS_USER = Read-WithDefault "Admin username:" "mios"
while ($true) {
    $pw1 = Read-Secret "Admin password:"
    if (-not $pw1) { Write-Host "  [!] Password cannot be empty." -ForegroundColor Red; continue }
    $pw2 = Read-Secret "Confirm password:"
    if ($pw1 -eq $pw2) {
        $MIOS_PASSWORD = $pw1
        $MIOS_PASSWORD_HASH = Get-SHA512Hash $pw1
        break
    }
    Write-Host "  [!] Passwords do not match. Try again." -ForegroundColor Red
}
Write-Host "  └───────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

# Hostname
Write-Host "  ┌─ Hostname ────────────────────────────────────────────────────┐" -ForegroundColor Cyan
$suffix = '{0:D5}' -f (Get-Random -Minimum 10000 -Maximum 99999)
$hbase = Read-WithDefault "Hostname base (suffix -$suffix will be appended):" "mios"
$MIOS_HOSTNAME = "$hbase-$suffix"
Write-Host "    Full hostname: $MIOS_HOSTNAME" -ForegroundColor DarkGray
Write-Host "  └───────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

# GitHub Access (for private MiOS repository)
Write-Host "  ┌─ GitHub Access ───────────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  " -NoNewline
Write-Host "MiOS is a private repository - GitHub credentials required" -ForegroundColor Yellow
Write-Host ""
$GITHUB_USER = Read-Host "  GitHub username"
if ([string]::IsNullOrWhiteSpace($GITHUB_USER)) {
    Write-Host "  [!] GitHub username is required to clone MiOS repository." -ForegroundColor Red
    exit 1
}
$GITHUB_TOKEN = Read-Secret "GitHub PAT (with repo scope):"
if ([string]::IsNullOrWhiteSpace($GITHUB_TOKEN)) {
    Write-Host "  [!] GitHub token is required to clone MiOS repository." -ForegroundColor Red
    exit 1
}
Write-Host "  └───────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

# Flatpak Selection
Write-Host "  ┌─ Flatpak Applications ────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  " -NoNewline
Write-Host "DEFAULT apps:" -ForegroundColor White
Write-Host "    - Flatseal, LocalSend, Bottles, Ptyxis, Pods, " -ForegroundColor DarkGray
Write-Host "      Extension Manager, Warehouse" -ForegroundColor DarkGray
Write-Host ""
$addMore = Read-Host "  Add more Flatpaks? (comma-separated IDs, or press Enter to skip)"
$MIOS_FLATPAKS = @(
    "com.github.tchx84.Flatseal",
    "org.localsend.localsend_app",
    "com.usebottles.bottles",
    "app.devsuite.Ptyxis",
    "com.github.marhkb.Pods",
    "com.mattjakeman.ExtensionManager",
    "io.github.flattool.Warehouse"
)
if (![string]::IsNullOrWhiteSpace($addMore)) {
    $additionalFlatpaks = $addMore -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $MIOS_FLATPAKS += $additionalFlatpaks
    Write-Host "    Added: $($additionalFlatpaks -join ', ')" -ForegroundColor Green
}
$MIOS_FLATPAKS_STR = $MIOS_FLATPAKS -join ','
Write-Host "    Total: $($MIOS_FLATPAKS.Count) apps" -ForegroundColor DarkGray
Write-Host "  └───────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

# Registry Push (Optional)
Write-Host "  ┌─ Registry Push (Optional) ────────────────────────────────────┐" -ForegroundColor Cyan
$GHCR_USER = Read-WithDefault "GHCR username (skip for local-only):" ""
if ($GHCR_USER) {
    $GHCR_TOKEN = Read-Secret "GHCR token (PAT with packages:write scope):"
} else {
    Write-Host "    Skipping registry push (local build only)" -ForegroundColor DarkGray
    $GHCR_TOKEN = ""
}
Write-Host "  └───────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

# Summary
Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "  ║  Configuration Summary                                           ║" -ForegroundColor Yellow
Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""
Write-Host "    Admin User:       $MIOS_USER"
Write-Host "    Password Hash:    $($MIOS_PASSWORD_HASH.Substring(0,20))... (SHA-512)"
Write-Host "    Hostname:         $MIOS_HOSTNAME"
Write-Host "    GitHub User:      $GITHUB_USER (for private repo access)"
Write-Host "    Flatpaks:         $($MIOS_FLATPAKS.Count) apps"
if ($GHCR_USER) {
    Write-Host "    Registry Push:    $GHCR_USER (enabled)"
} else {
    Write-Host "    Registry Push:    Disabled (local build only)"
}
Write-Host "    Config File:      $MiosConfigFile"
Write-Host ""
$confirm = Read-Host "  Proceed with these settings? [Y/n]"
if ($confirm -and $confirm.ToLower() -eq "n") {
    Write-Host "  Aborted by user." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# Phase 4: Write registry.toml (Single Source of Truth)
# ============================================================================

Write-Host ""
Write-Host "  [4/7] Writing registry.toml (single source of truth)..." -ForegroundColor Yellow

$registryToml = @"
# MiOS Registry - Single Source of Truth for Build Variables
# Generated: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
# XDG-Compliant Path: $MiosConfigFile

[metadata]
version = "0.2.0"
generated_at = "$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
generated_by = "bootstrap-v2.ps1"

[tags.VAR_VERSION]
value = "0.2.0"
subscribers = [
    "VERSION",
    "Justfile:VERSION",
    "Containerfile:org.opencontainers.image.version"
]

[tags.VAR_USER]
value = "$MIOS_USER"
subscribers = [
    "automation/31-user.sh:C_USER",
    "usr/lib/sysusers.d/10-mios.conf"
]

[tags.VAR_HOSTNAME]
value = "$MIOS_HOSTNAME"
subscribers = [
    "automation/32-hostname.sh:MIOS_HOSTNAME",
    "etc/hostname"
]

[tags.VAR_PASSWORD_HASH]
value = "$MIOS_PASSWORD_HASH"
subscribers = [
    "automation/31-user.sh:C_HASH"
]

[tags.VAR_FLATPAKS]
value = "$MIOS_FLATPAKS_STR"
subscribers = [
    "Containerfile:MIOS_FLATPAKS",
    "usr/lib/systemd/system/mios-flatpak-install.service"
]

[tags.IMG_BASE]
value = "ghcr.io/ublue-os/ucore-hci:stable-nvidia"
subscribers = [
    "Containerfile:BASE_IMAGE",
    "Justfile:MIOS_BASE_IMAGE"
]

[tags.IMG_BIB]
value = "quay.io/centos-bootc/bootc-image-builder:latest"
subscribers = [
    "Justfile:BIB_IMAGE"
]
"@

if ($GHCR_USER) {
    $registryToml += @"

[tags.VAR_GHCR_USER]
value = "$GHCR_USER"
subscribers = [
    "Justfile:GHCR_USER"
]
"@
}

$registryToml | Set-Content $MiosConfigFile -Encoding UTF8
Set-SecureACL $MiosConfigFile
Write-Host "  [OK] Saved to: $MiosConfigFile" -ForegroundColor Green
Write-Host ""

# Write secrets to separate file (SHA-512 hashes + tokens)
Write-Host "  [5/7] Writing secrets.env (hashed credentials)..." -ForegroundColor Yellow
$secretsContent = @"
# MiOS Secrets - SHA-512 Hashes and Tokens
# Generated: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
# SECURITY: This file contains hashed passwords and tokens.
#           Permissions are restricted to current user + Administrators.

MIOS_PASSWORD_HASH=$MIOS_PASSWORD_HASH
GITHUB_USER=$GITHUB_USER
GITHUB_TOKEN=$GITHUB_TOKEN
"@

if ($GHCR_TOKEN) {
    $secretsContent += "`nGHCR_TOKEN=$GHCR_TOKEN"
}

$secretsContent | Set-Content $MiosSecretsFile -Encoding UTF8
Set-SecureACL $MiosSecretsFile
Write-Host "  [OK] Saved to: $MiosSecretsFile" -ForegroundColor Green
Write-Host ""

# Write legacy .env file for compatibility
Write-Host "  [6/7] Writing build.env (legacy compatibility)..." -ForegroundColor Yellow
$envContent = @"
# MiOS Build Configuration (Legacy Format)
# Generated: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
# Modern builds should read from registry.toml instead.

MIOS_USER=$MIOS_USER
MIOS_HOSTNAME=$MIOS_HOSTNAME
MIOS_FLATPAKS=$MIOS_FLATPAKS_STR
"@

if ($GHCR_USER) {
    $envContent += "`nGHCR_USER=$GHCR_USER"
}

$envContent | Set-Content $MiosEnvFile -Encoding UTF8
Write-Host "  [OK] Saved to: $MiosEnvFile" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Phase 7: Launch Build
# ============================================================================

Write-Host "  [7/7] Launching MiOS build pipeline..." -ForegroundColor Yellow
Write-Host ""

$env:MIOS_CONFIG_FILE = $MiosConfigFile
$env:MIOS_SECRETS_FILE = $MiosSecretsFile
$env:MIOS_USER = $MIOS_USER
$env:MIOS_HOSTNAME = $MIOS_HOSTNAME
$env:MIOS_PASSWORD_HASH = $MIOS_PASSWORD_HASH
$env:MIOS_FLATPAKS = $MIOS_FLATPAKS_STR
$env:MIOS_AUTOINSTALL = "1"
$env:MIOS_DIR = $MiosRepoDir
$env:MIOS_BUILDS_DIR = $MiosBuildDir
$env:MIOS_LOGS_DIR = $MiosLogsDir

if ($GHCR_USER) {
    $env:GHCR_USER = $GHCR_USER
    $env:GHCR_TOKEN = $GHCR_TOKEN
}

# Clone repositories to persistent Windows application data directory
Write-Host "  Cloning MiOS repositories to $MiosRepoDir..." -ForegroundColor Gray

$MiosSystemRepo = Join-Path $MiosRepoDir "mios"
$MiosBootstrapRepo = Join-Path $MiosRepoDir "mios-bootstrap"

$gitCredHelper = if ($GITHUB_TOKEN) { "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" } else { "https://github.com" }

try {
    foreach ($repoSpec in @(
        @{ Url = "https://github.com/MiOS-DEV/MiOS.git"; Dest = $MiosSystemRepo; Name = "mios" },
        @{ Url = "https://github.com/MiOS-DEV/MiOS-bootstrap.git"; Dest = $MiosBootstrapRepo; Name = "mios-bootstrap" }
    )) {
        $cloneUrl = if ($GITHUB_TOKEN) {
            $repoSpec.Url -replace "https://", "https://${GITHUB_USER}:${GITHUB_TOKEN}@"
        } else { $repoSpec.Url }

        if (Test-Path (Join-Path $repoSpec.Dest ".git")) {
            Write-Host "    Updating $($repoSpec.Name)..." -ForegroundColor DarkGray
            & git -C $repoSpec.Dest pull --ff-only 2>&1 | Out-Null
        } else {
            Write-Host "    Cloning $($repoSpec.Name)..." -ForegroundColor DarkGray
            & git clone --depth 1 $cloneUrl $repoSpec.Dest 2>&1 | Out-Null
        }
        Write-Host "    [OK] $($repoSpec.Name) → $($repoSpec.Dest)" -ForegroundColor DarkGray
    }
    Write-Host "  [OK] Repositories cloned" -ForegroundColor Green
} catch {
    Write-Host "  [!] Git clone failed: $_ (non-fatal, will use downloaded build script)" -ForegroundColor Yellow
}

# Run build script: prefer cloned copy, fallback to download
$buildScript = Join-Path $MiosBootstrapRepo "mios-build-local.ps1"
if (-not (Test-Path $buildScript)) {
    $buildScript = Join-Path $MiosSystemRepo "mios-build-local.ps1"
}

try {
    if (Test-Path $buildScript) {
        Write-Host "  Using build script: $buildScript" -ForegroundColor DarkGray
    } else {
        Write-Host "  Fetching mios-build-local.ps1 from MiOS-bootstrap..." -ForegroundColor Gray
        $buildScript = Join-Path $MiosLogsDir "mios-build-local.ps1"
        Invoke-WebRequest -Uri $PublicInstaller -OutFile $buildScript -UseBasicParsing
        Write-Host "  [OK] Build script downloaded" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  ════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Starting MiOS build (estimated time: 15-20 minutes)" -ForegroundColor Cyan
    Write-Host "  ════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    & $buildScript

} catch {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║  Build Failed                                                    ║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Error: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Troubleshooting:" -ForegroundColor Yellow
    Write-Host "    1. Check internet connection" -ForegroundColor Gray
    Write-Host "    2. Verify Podman Desktop is installed" -ForegroundColor Gray
    Write-Host "    3. Review logs at: $MiosLogsDir" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Manual build:" -ForegroundColor Yellow
    Write-Host "    git clone https://github.com/MiOS-DEV/MiOS-bootstrap.git" -ForegroundColor Gray
    Write-Host "    cd MiOS-bootstrap" -ForegroundColor Gray
    Write-Host "    .\mios-build-local.ps1" -ForegroundColor Gray
    exit 1
} finally {
    Remove-Item $buildScript -ErrorAction SilentlyContinue
}
