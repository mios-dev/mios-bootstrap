#Requires -Version 5.1
# MiOS Unified Installer & Builder — Windows 11 / PowerShell
#
#   irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1 | iex
#
# All phases run in sequence. Re-run at any time — fully idempotent.
# Detects existing MiOS-BUILDER, syncs repos offline, and goes straight to build.
#
# Flags:
#   -BuildOnly    Pull latest + build (skip first-time setup)
#   -Unattended   Accept all defaults, no prompts

param([switch]$BuildOnly, [switch]$Unattended)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ─── Canonical paths ──────────────────────────────────────────────────────────
$MiosInstallDir    = Join-Path $env:LOCALAPPDATA "Programs\MiOS"
$MiosRepoDir       = Join-Path $MiosInstallDir "repo"
$MiosDistroDir     = Join-Path $MiosInstallDir "distros"
$MiosConfigDir     = Join-Path $env:APPDATA "MiOS"
$MiosDataDir       = Join-Path $env:LOCALAPPDATA "MiOS"
$MiosVersion       = "v0.2.0"
$MiosRepoUrl       = "https://github.com/mios-dev/mios.git"
$MiosBootstrapUrl  = "https://github.com/mios-dev/mios-bootstrap.git"
$BuilderDistro     = "MiOS-BUILDER"   # dedicated build WSL2 distro
$LegacyDistro      = "podman-machine-default"  # migration fallback
$UninstallRegKey   = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MiOS"
$StartMenuDir      = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\MiOS"

# ─── Helpers ──────────────────────────────────────────────────────────────────
function Write-Phase { param([string]$T)
    Write-Host ""; Write-Host "  $T" -ForegroundColor Cyan
    Write-Host ("  " + "─" * $T.Length) -ForegroundColor DarkGray }
function Write-Ok   { param([string]$T); Write-Host "  + $T" -ForegroundColor Green }
function Write-Step { param([string]$T); Write-Host "  > $T" -ForegroundColor White }
function Write-Warn { param([string]$T); Write-Host "  ! $T" -ForegroundColor Yellow }
function Write-Fail { param([string]$T); Write-Host "  x $T" -ForegroundColor Red }
function Write-Info { param([string]$T); Write-Host "    $T" -ForegroundColor DarkGray }

function Read-Line {
    param([string]$Prompt, [string]$Default = "")
    Write-Host "  $Prompt" -NoNewline -ForegroundColor White
    if ($Default) { Write-Host " [$Default]" -NoNewline -ForegroundColor DarkGray }
    Write-Host ": " -NoNewline
    if ($Unattended) { Write-Host $Default -ForegroundColor DarkGray; return $Default }
    $v = Read-Host
    return (([string]::IsNullOrWhiteSpace($v)) ? $Default : $v)
}

function Read-Password {
    param([string]$Prompt = "Password")
    Write-Host "  $Prompt [default: mios]: " -NoNewline -ForegroundColor White
    if ($Unattended) { Write-Host "(default)" -ForegroundColor DarkGray; return "" }
    if ($PSVersionTable.PSVersion.Major -ge 7) { return (Read-Host -MaskInput) }
    $ss = Read-Host -AsSecureString
    $b  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Get-PasswordHash {
    param([string]$Plain)
    if ($Plain -eq "mios" -or [string]::IsNullOrWhiteSpace($Plain)) {
        return '$6$miosmios0$ShHuf/TnPoEmEX//L9mrNNuP7kZ6l9aj/qV9WFj5LnjL3lunhKEwnJfY6tvlJbRiWkLTtPmdwCgWeOQB9eXuW.'
    }
    $salt = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    foreach ($d in @($BuilderDistro, $LegacyDistro)) {
        try {
            $h = & wsl.exe -d $d openssl passwd -6 -salt $salt $Plain 2>$null
            if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
        } catch {}
    }
    try {
        $h = & podman run --rm docker.io/library/alpine:latest sh -c "apk add -q openssl &>/dev/null && openssl passwd -6 -salt '$salt' '$Plain'" 2>$null
        if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
    } catch {}
    throw "Cannot generate sha512crypt hash."
}

function Get-Hardware {
    $ramGB = try { [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1GB) } catch { 16 }
    $cpus  = [Environment]::ProcessorCount
    $gpu   = try { Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft Basic" } | Select-Object -First 1 } catch { $null }
    $gpuName   = if ($gpu) { $gpu.Name } else { "Unknown" }
    $hasNvidia = $gpuName -match "NVIDIA|GeForce|Quadro|RTX|GTX|Tesla"
    $hasAmd    = $gpuName -match "AMD|Radeon|RX\s"
    $baseImage = if ($hasNvidia) { "ghcr.io/ublue-os/ucore-hci:stable-nvidia" } else { "ghcr.io/ublue-os/ucore-hci:stable" }
    $aiModel   = if ($ramGB -ge 32) { "qwen2.5-coder:14b" } elseif ($ramGB -ge 12) { "qwen2.5-coder:7b" } else { "phi4-mini:3.8b-q4_K_M" }
    $wslRam    = [math]::Max(8, [math]::Min(24, [math]::Floor($ramGB * 0.75)))
    return @{ RamGB=$ramGB; Cpus=$cpus; GpuName=$gpuName; HasNvidia=$hasNvidia; HasAmd=$hasAmd
              BaseImage=$baseImage; AiModel=$aiModel; WslRam=$wslRam }
}

function Find-ActiveDistro {
    # Returns the distro name that has MiOS at /, preferring MiOS-BUILDER
    foreach ($d in @($BuilderDistro, $LegacyDistro)) {
        try {
            $r = (& wsl.exe -d $d bash -c "test -f /Justfile && echo ready" 2>$null -join "").Trim()
            if ($r -eq "ready") { return $d }
        } catch {}
    }
    return $null
}

function Sync-RepoToDistro {
    param([string]$Distro, [string]$WindowsRepoPath)
    # Sync Windows-side clone to WSL via file:// — no internet, no hanging
    $wslPath = $null
    try { $wslPath = (& wsl.exe -d $Distro wslpath ($WindowsRepoPath -replace '\\','/') 2>$null -join "").Trim() } catch {}
    if ($wslPath) {
        & wsl.exe -d $Distro bash -c "sudo git -C / fetch ""file://$wslPath"" main 2>/dev/null && sudo git -C / reset --hard FETCH_HEAD 2>/dev/null" 2>$null
        return $true
    }
    return $false
}

function New-BuilderDistro {
    param([hashtable]$HW)
    Write-Step "Creating MiOS-BUILDER WSL2 distro from Fedora container..."
    $builderDir = Join-Path $MiosDistroDir $BuilderDistro
    New-Item -ItemType Directory -Path $builderDir -Force | Out-Null
    $rootfs = Join-Path $env:TEMP "mios-builder-rootfs.tar"

    # Pull Fedora and export rootfs via Podman
    Write-Info "Pulling registry.fedoraproject.org/fedora:latest..."
    & podman pull registry.fedoraproject.org/fedora:latest 2>&1 | Where-Object { $_ -match "Trying|Writing|Storing" } | ForEach-Object { Write-Info $_ }
    Write-Info "Exporting rootfs..."
    & podman create --name mios-builder-init registry.fedoraproject.org/fedora:latest sh 2>&1 | Out-Null
    & podman export mios-builder-init -o $rootfs
    & podman rm -f mios-builder-init 2>&1 | Out-Null

    Write-Info "Importing as WSL2 distro $BuilderDistro..."
    & wsl.exe --import $BuilderDistro $builderDir $rootfs --version 2
    Remove-Item $rootfs -ErrorAction SilentlyContinue
    Write-Ok "$BuilderDistro WSL2 distro created"

    # Install build stack inside MiOS-BUILDER
    Write-Step "Installing build stack (Podman, just, git, openssl, python3)..."
    $pkgs = "git just podman buildah skopeo openssl python3 fuse-overlayfs shadow-utils"
    & wsl.exe -d $BuilderDistro bash -c "dnf install -y --setopt=install_weak_deps=False $pkgs &>/dev/null && dnf clean all &>/dev/null"
    Write-Ok "Build stack ready"
}

function Invoke-WslBuild {
    param([string]$Distro, [string]$BaseImage, [string]$AiModel)
    # Ensure just is present
    & wsl.exe -d $Distro bash -c "command -v just &>/dev/null || dnf install -y just &>/dev/null"
    Write-Step "Running: sudo just build (inside $Distro)"
    Write-Host ""
    $env:MIOS_BASE_IMAGE = $BaseImage
    $env:MIOS_AI_MODEL   = $AiModel
    & wsl.exe -d $Distro bash -lc "cd / && MIOS_BASE_IMAGE='$BaseImage' MIOS_AI_MODEL='$AiModel' sudo just build"
    return $LASTEXITCODE
}

function New-Shortcut {
    param([string]$Path, [string]$Target, [string]$Args="", [string]$Desc="", [string]$Dir="")
    $ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath = $Target
    if ($Args) { $sc.Arguments = $Args }; if ($Desc) { $sc.Description = $Desc }; if ($Dir) { $sc.WorkingDirectory = $Dir }
    $sc.Save()
}

# ─── Banner ───────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  +================================================+" -ForegroundColor Cyan
Write-Host "  |  MiOS $MiosVersion  --  Unified Windows Installer     |" -ForegroundColor Cyan
Write-Host "  |  Immutable Fedora AI Workstation               |" -ForegroundColor Cyan
Write-Host "  |  WSL2 + Podman  |  Offline Build Pipeline      |" -ForegroundColor Cyan
Write-Host "  +================================================+" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 0 — Hardware detection + prerequisites
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 0 — Hardware + Prerequisites"

$HW = Get-Hardware
Write-Info "CPU  : $($HW.Cpus) threads"
Write-Info "RAM  : $($HW.RamGB) GB  (WSL2 allocation: $($HW.WslRam) GB)"
Write-Info "GPU  : $($HW.GpuName)"
Write-Info "Base : $($HW.BaseImage)"
Write-Info "Model: $($HW.AiModel)"
Write-Host ""

$preOk = $true
if (Get-Command git   -EA SilentlyContinue) { Write-Ok  ("Git "    + ((git --version 2>$null) -replace "git version ","")) } else { Write-Fail "Git not found — winget install Git.Git"; $preOk=$false }
if (Get-Command wsl   -EA SilentlyContinue) { Write-Ok  "WSL2 available" } else { Write-Warn "WSL2 not found — run: wsl --install" }
if (Get-Command podman -EA SilentlyContinue) { Write-Ok ("Podman " + ((podman --version 2>$null) -replace "podman version ","")) } else { Write-Warn "Podman not found — winget install RedHat.Podman-Desktop" }
if (-not $preOk) { Write-Host ""; Write-Fail "Prerequisites missing."; exit 1 }

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1 — Quick-path: existing MiOS-BUILDER or podman-machine-default
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 1 — Detecting existing build environment"

$activeDistro = Find-ActiveDistro

if ($activeDistro) {
    Write-Ok "MiOS repo found in $activeDistro"

    # Update Windows-side repos first (fast, always works)
    $miosRepo = Join-Path $MiosRepoDir "mios"
    if (Test-Path (Join-Path $miosRepo ".git")) {
        Write-Step "Pulling Windows-side repo..."
        Push-Location $miosRepo; try { git pull --ff-only -q 2>&1 | Out-Null } catch {}; Pop-Location
        # Sync into WSL via file:// — no internet, no hanging
        Write-Step "Syncing into $activeDistro (offline file sync)..."
        Sync-RepoToDistro -Distro $activeDistro -WindowsRepoPath $miosRepo | Out-Null
        Write-Ok "Repo up to date"
    }

    Write-Host ""
    Write-Host "  +================================================+" -ForegroundColor Cyan
    Write-Host "  |  Building MiOS OCI image in $activeDistro" -ForegroundColor Cyan
    Write-Host "  +================================================+" -ForegroundColor Cyan

    $rc = Invoke-WslBuild -Distro $activeDistro -BaseImage $HW.BaseImage -AiModel $HW.AiModel
    Write-Host ""
    if ($rc -eq 0) { Write-Ok "Build complete. Image: localhost/mios:latest" }
    else           { Write-Fail "Build failed (exit $rc) — open 'MiOS WSL Terminal' and run: sudo just build" }
    exit $rc
}

if ($BuildOnly) { Write-Fail "-BuildOnly: no MiOS build environment found. Run without -BuildOnly first."; exit 1 }

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2 — Windows directories + repo clone
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 2 — Directories and repositories"

foreach ($d in @($MiosInstallDir,$MiosRepoDir,$MiosDistroDir,$MiosConfigDir,$MiosDataDir,(Join-Path $MiosDataDir "logs"))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Write-Ok "Directories under $MiosInstallDir"

foreach ($s in @(
    @{ Path=(Join-Path $MiosRepoDir "mios");           Url=$MiosRepoUrl;      Name="mios.git" },
    @{ Path=(Join-Path $MiosRepoDir "mios-bootstrap"); Url=$MiosBootstrapUrl; Name="mios-bootstrap.git" }
)) {
    if (Test-Path (Join-Path $s.Path ".git")) {
        Write-Step "Updating $($s.Name)..."
        Push-Location $s.Path; try { git pull --ff-only -q 2>&1 | Out-Null } catch {}; Pop-Location
    } else {
        Write-Step "Cloning $($s.Name)..."
        git clone --depth 1 $s.Url $s.Path 2>&1 | Out-Null
    }
    Write-Ok "$($s.Name)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3 — Create MiOS-BUILDER WSL2 distro
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 3 — MiOS-BUILDER distro"

$distroExists = $false
try {
    $r = (& wsl.exe -d $BuilderDistro bash -c "echo ok" 2>$null -join "").Trim()
    $distroExists = ($r -eq "ok")
} catch {}

if ($distroExists) {
    Write-Ok "$BuilderDistro already exists"
} else {
    New-BuilderDistro -HW $HW
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4 — WSL2 .wslconfig
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 4 — WSL2 configuration"

$wslCfg = Join-Path $env:USERPROFILE ".wslconfig"
if ((Test-Path $wslCfg) -and ((Get-Content $wslCfg -Raw) -match "\[wsl2\]")) {
    Write-Ok ".wslconfig already configured"
} else {
    @"

[wsl2]
# MiOS-managed — $($HW.WslRam)GB / $($HW.Cpus) CPUs auto-detected
memory=$($HW.WslRam)GB
processors=$($HW.Cpus)
swap=4GB
localhostForwarding=true
networkingMode=mirrored
"@ | Add-Content -Path $wslCfg
    Write-Ok ".wslconfig: $($HW.WslRam)GB RAM, $($HW.Cpus) CPUs, mirrored networking"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5 — Clone mios.git to / inside MiOS-BUILDER
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 5 — Seeding MiOS-BUILDER repo"

$repoSeeded = $false
try {
    $r = (& wsl.exe -d $BuilderDistro bash -c "test -f /Justfile && echo seeded" 2>$null -join "").Trim()
    $repoSeeded = ($r -eq "seeded")
} catch {}

if ($repoSeeded) {
    Write-Ok "Repo already at / — syncing from Windows clone..."
    Sync-RepoToDistro -Distro $BuilderDistro -WindowsRepoPath (Join-Path $MiosRepoDir "mios") | Out-Null
    Write-Ok "Synced"
} else {
    Write-Step "Initializing git root and cloning mios.git to /..."
    & wsl.exe -d $BuilderDistro bash -c "git init / && git -C / remote add origin '$MiosRepoUrl' && git -C / fetch --depth=1 origin main && git -C / reset --hard FETCH_HEAD" 2>&1 | Out-Null
    Write-Ok "mios.git cloned to /"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 6 — Identity (username / password / hostname)
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 6 — Identity"
Write-Info "Press Enter to accept all defaults (user=mios, hostname=mios, password=mios)."
Write-Host ""

$MiosUser     = Read-Line "Linux username" "mios"
$MiosHostname = Read-Line "Hostname"       "mios"
$pwPlain      = Read-Password "Password"
if ([string]::IsNullOrWhiteSpace($pwPlain)) { $pwPlain = "mios" }
$MiosHash     = Get-PasswordHash $pwPlain
Write-Host ""
Write-Ok "User=$MiosUser  Hostname=$MiosHostname  Password=(hashed)"

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 7 — Write identity into MiOS-BUILDER
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 7 — Writing identity to MiOS-BUILDER"

$tmpEnv = Join-Path $env:TEMP "mios-install.env"
@"
MIOS_USER="$MiosUser"
MIOS_HOSTNAME="$MiosHostname"
MIOS_USER_PASSWORD_HASH="$MiosHash"
"@ | Set-Content $tmpEnv -Encoding UTF8

try {
    $wslTmp = (& wsl.exe -d $BuilderDistro wslpath ($tmpEnv -replace '\\','/') 2>$null -join "").Trim()
    & wsl.exe -d $BuilderDistro bash -c "mkdir -p /etc/mios && cp '$wslTmp' /etc/mios/install.env && chmod 0640 /etc/mios/install.env"
    Write-Ok "/etc/mios/install.env written"
} catch { Write-Warn "Could not write install.env (non-fatal)" }
Remove-Item $tmpEnv -ErrorAction SilentlyContinue

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 8 — Windows application registration + Start Menu
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 8 — Application registration"

$pwsh       = if (Get-Command pwsh -EA SilentlyContinue) { (Get-Command pwsh).Source } else { "powershell.exe" }
$selfScript = Join-Path $MiosRepoDir "mios-bootstrap\install.ps1"
$uninstScr  = Join-Path $MiosInstallDir "uninstall.ps1"
$uninstCmd  = "$pwsh -ExecutionPolicy Bypass -File `"$uninstScr`""

if (-not (Test-Path $UninstallRegKey)) { New-Item -Path $UninstallRegKey -Force | Out-Null }
@{
    DisplayName          = "MiOS - Immutable Fedora AI Workstation"
    DisplayVersion       = $MiosVersion
    Publisher            = "MiOS-DEV"
    InstallLocation      = $MiosInstallDir
    UninstallString      = $uninstCmd
    QuietUninstallString = "$uninstCmd -Quiet"
    URLInfoAbout         = "https://github.com/mios-dev/mios"
    NoModify=[int]1; NoRepair=[int]1
}.GetEnumerator() | ForEach-Object {
    Set-ItemProperty -Path $UninstallRegKey -Name $_.Key -Value $_.Value -Type (if ($_.Value -is [int]) {"DWord"} else {"String"})
}

if (-not (Test-Path $StartMenuDir)) { New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null }
@(
    @{ F="MiOS Setup.lnk";       T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$selfScript`"";             D="Re-run full MiOS setup" },
    @{ F="MiOS Build.lnk";       T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$selfScript`" -BuildOnly";   D="Pull latest + build MiOS OCI image" },
    @{ F="MiOS WSL Terminal.lnk"; T="wsl.exe"; A="-d $BuilderDistro";                                         D="Open MiOS-BUILDER terminal" },
    @{ F="Uninstall MiOS.lnk";   T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$uninstScr`"";               D="Remove MiOS" }
) | ForEach-Object { New-Shortcut (Join-Path $StartMenuDir $_.F) $_.T $_.A $_.D $MiosInstallDir }
Write-Ok "Add/Remove Programs + Start Menu 'MiOS' (4 shortcuts)"

# Write uninstaller
@"
#Requires -Version 5.1
param([switch]`$Quiet)
`$I='$($MiosInstallDir -replace "'","''")'; `$D='$($MiosDataDir -replace "'","''")'; `$C='$($MiosConfigDir -replace "'","''")'; `$S='$($StartMenuDir -replace "'","''")'; `$K='$($UninstallRegKey -replace "'","''")'; `$B='$BuilderDistro'
if (-not `$Quiet) {
    Write-Host ''; Write-Host '  MiOS Uninstaller' -ForegroundColor Red; Write-Host ''
    Write-Host "  Removes: `$I, `$D, `$B WSL2 distro, Start Menu"
    Write-Host "  Preserves: `$C (config)"; Write-Host ''
    if ((Read-Host "  Type 'yes' to confirm") -ne 'yes') { Write-Host '  Aborted.'; exit 0 }
}
try { wsl --unregister `$B 2>`$null } catch {}
foreach (`$p in @(`$I,`$D,`$S)) { if (Test-Path `$p) { Remove-Item `$p -Recurse -Force } }
if (Test-Path `$K) { Remove-Item `$K -Recurse -Force }
Write-Host ''; Write-Host "  MiOS removed. Config at `$C preserved." -ForegroundColor Green
"@ | Set-Content $uninstScr -Encoding UTF8
Write-Ok "uninstall.ps1 written"

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 9 — Build
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 9 — Building MiOS OCI image"
Write-Info "Base image : $($HW.BaseImage)"
Write-Info "AI model   : $($HW.AiModel)"
Write-Info "Build host : $BuilderDistro (Fedora + Podman)"
Write-Info "Est. time  : 15-30 min on first run (OCI layers cached after)"
Write-Host ""

$rc = Invoke-WslBuild -Distro $BuilderDistro -BaseImage $HW.BaseImage -AiModel $HW.AiModel

# ═══════════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
if ($rc -eq 0) {
    Write-Host "  +================================================+" -ForegroundColor Green
    Write-Host "  |  MiOS built successfully!                      |" -ForegroundColor Green
    Write-Host "  +================================================+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Image    : localhost/mios:latest (in $BuilderDistro)" -ForegroundColor White
    Write-Host "  Builder  : $BuilderDistro WSL2 distro" -ForegroundColor DarkGray
    Write-Host "  Base     : $($HW.BaseImage)" -ForegroundColor DarkGray
    Write-Host "  AI model : $($HW.AiModel)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Start Menu > MiOS Build   — pull latest + rebuild at any time" -ForegroundColor DarkGray
    Write-Host "             > MiOS WSL Terminal — open $BuilderDistro shell" -ForegroundColor DarkGray
} else {
    Write-Host "  +================================================+" -ForegroundColor Red
    Write-Host "  |  Build failed (exit $rc)                       |" -ForegroundColor Red
    Write-Host "  +================================================+" -ForegroundColor Red
    Write-Host ""
    Write-Warn "Open 'MiOS WSL Terminal' and check output with: sudo just build"
}
Write-Host ""
exit $rc
