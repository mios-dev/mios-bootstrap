#Requires -Version 5.1
# MiOS Unified Installer — Windows 11 / PowerShell
#
# One-liner entry point (does everything in sequence):
#   irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1 | iex
#
# Re-run at any time — fully idempotent. Detects existing setup and goes
# straight to build when the environment is already prepared.
#
# Optional flags (for shortcuts and automation):
#   -BuildOnly   Skip setup, pull latest repos, run build
#   -Unattended  Accept all defaults without prompting

param(
    [switch]$BuildOnly,
    [switch]$Unattended
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ─── Canonical paths ──────────────────────────────────────────────────────────
$MiosInstallDir   = Join-Path $env:LOCALAPPDATA "Programs\MiOS"
$MiosRepoDir      = Join-Path $MiosInstallDir "repo"
$MiosBinDir       = Join-Path $MiosInstallDir "bin"
$MiosConfigDir    = Join-Path $env:APPDATA "MiOS"
$MiosDataDir      = Join-Path $env:LOCALAPPDATA "MiOS"
$MiosVersion      = "v0.2.0"
$MiosRepoUrl      = "https://github.com/mios-dev/mios.git"
$MiosBootstrapUrl = "https://github.com/mios-dev/mios-bootstrap.git"
$WslDistro        = "podman-machine-default"
$UninstallRegKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MiOS"
$StartMenuDir     = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\MiOS"

# ─── Helpers ──────────────────────────────────────────────────────────────────
function Write-Phase { param([string]$T); Write-Host ""; Write-Host "  $T" -ForegroundColor Cyan; Write-Host ("  " + "─"*$T.Length) -ForegroundColor DarkGray }
function Write-Ok    { param([string]$T); Write-Host "  + $T" -ForegroundColor Green }
function Write-Step  { param([string]$T); Write-Host "  > $T" -ForegroundColor White }
function Write-Warn  { param([string]$T); Write-Host "  ! $T" -ForegroundColor Yellow }
function Write-Fail  { param([string]$T); Write-Host "  x $T" -ForegroundColor Red }

function Read-Line {
    param([string]$Prompt, [string]$Default = "")
    Write-Host "  $Prompt" -NoNewline -ForegroundColor White
    if ($Default) { Write-Host " [$Default]" -NoNewline -ForegroundColor DarkGray }
    Write-Host ": " -NoNewline
    if ($Unattended) { Write-Host $Default -ForegroundColor DarkGray; return $Default }
    $v = Read-Host
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}

function Read-Password {
    param([string]$Prompt)
    Write-Host "  $Prompt [default: mios]: " -NoNewline -ForegroundColor White
    if ($Unattended) { Write-Host "(default)" -ForegroundColor DarkGray; return "" }
    if ($PSVersionTable.PSVersion.Major -ge 7) { $v = Read-Host -MaskInput }
    else {
        $ss = Read-Host -AsSecureString
        $b  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { $v = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }
    if ([string]::IsNullOrWhiteSpace($v)) { return "" }   # empty → caller uses 'mios'
    return $v
}

function Get-PasswordHash {
    param([string]$PlainText)
    # Pre-computed canonical hash for the default 'mios' password (openssl passwd -6 -salt miosmios0 mios)
    if ($PlainText -eq "mios") {
        return '$6$miosmios0$ShHuf/TnPoEmEX//L9mrNNuP7kZ6l9aj/qV9WFj5LnjL3lunhKEwnJfY6tvlJbRiWkLTtPmdwCgWeOQB9eXuW.'
    }
    $salt = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    # Try podman-machine-default (openssl guaranteed there)
    try {
        $h = & wsl.exe -d $WslDistro openssl passwd -6 -salt $salt $PlainText 2>$null
        if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
    } catch {}
    # Fallback: Podman alpine
    try {
        $h = & podman run --rm docker.io/library/alpine:latest sh -c "apk add -q openssl &>/dev/null && openssl passwd -6 -salt '$salt' '$PlainText'" 2>$null
        if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
    } catch {}
    throw "Cannot generate sha512crypt hash — ensure podman-machine-default or Podman is available."
}

function New-Shortcut {
    param([string]$Path, [string]$Target, [string]$Args = "", [string]$Desc = "", [string]$Dir = "")
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath = $Target
    if ($Args) { $sc.Arguments       = $Args }
    if ($Desc) { $sc.Description     = $Desc }
    if ($Dir)  { $sc.WorkingDirectory = $Dir }
    $sc.Save()
}

function Invoke-WslBuild {
    Write-Step "Ensuring 'just' is installed in $WslDistro..."
    & wsl.exe -d $WslDistro bash -lc "command -v just &>/dev/null || sudo dnf install -y just &>/dev/null"
    Write-Step "Running: sudo just build (inside $WslDistro)"
    Write-Host ""
    & wsl.exe -d $WslDistro bash -lc "cd / && sudo just build"
    return $LASTEXITCODE
}

# ─── Banner ───────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  +================================================+" -ForegroundColor Cyan
Write-Host "  |  MiOS $MiosVersion -- Unified Windows Installer       |" -ForegroundColor Cyan
Write-Host "  |  Immutable Fedora AI Workstation (WSL2/Podman) |" -ForegroundColor Cyan
Write-Host "  +================================================+" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 0 — Prerequisites
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 0 — Prerequisites"

$ok = $true
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok ("Git " + (git --version 2>$null) -replace "git version ","")
} else {
    Write-Fail "Git not found. Install: winget install Git.Git"; $ok = $false
}
if (Get-Command wsl -ErrorAction SilentlyContinue) { Write-Ok "WSL2 available" }
else { Write-Warn "WSL2 not found — enable with: wsl --install" }
if (Get-Command podman -ErrorAction SilentlyContinue) {
    Write-Ok ("Podman " + (podman --version 2>$null) -replace "podman version ","")
} else { Write-Warn "Podman Desktop not found — install: winget install RedHat.Podman-Desktop" }

if (-not $ok) { Write-Host ""; Write-Fail "Prerequisites missing. Aborting."; exit 1 }

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1 — Quick-path: existing MiOS + WSL setup → update repos + build
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 1 — Detecting existing setup"

$wslReady = $null
try {
    $wslReady = (& wsl.exe -d $WslDistro bash -c "test -f /Justfile && echo ready" 2>$null)
    $wslReady = ($wslReady -join "").Trim()
} catch {}

if ($wslReady -eq "ready") {
    Write-Ok "MiOS repo found at / in $WslDistro"
    Write-Step "Pulling latest changes..."
    try { & wsl.exe -d $WslDistro bash -lc "cd / && sudo git fetch --depth=1 origin main && sudo git reset --hard FETCH_HEAD" 2>$null } catch {}

    Write-Host ""
    Write-Host "  +================================================+" -ForegroundColor Cyan
    Write-Host "  |  Starting MiOS build                           |" -ForegroundColor Cyan
    Write-Host "  +================================================+" -ForegroundColor Cyan
    Write-Host ""

    $rc = Invoke-WslBuild
    Write-Host ""
    if ($rc -eq 0) { Write-Ok "Build complete." } else { Write-Fail "Build exited $rc — check output above." }
    exit $rc
} else {
    Write-Step "No existing setup found — running full install."
}

if ($BuildOnly) {
    Write-Fail "-BuildOnly specified but no MiOS setup found in $WslDistro. Run install first."
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2 — Create directories + clone repositories
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 2 — Directories and repositories"

foreach ($d in @($MiosInstallDir,$MiosRepoDir,$MiosBinDir,$MiosConfigDir,$MiosDataDir,(Join-Path $MiosDataDir "logs"))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Write-Ok "Directories under $MiosInstallDir"

$miosRepo      = Join-Path $MiosRepoDir "mios"
$bootstrapRepo = Join-Path $MiosRepoDir "mios-bootstrap"

foreach ($s in @(
    @{ Path=$miosRepo;      Url=$MiosRepoUrl;      Name="mios" },
    @{ Path=$bootstrapRepo; Url=$MiosBootstrapUrl; Name="mios-bootstrap" }
)) {
    if (Test-Path (Join-Path $s.Path ".git")) {
        Write-Step "Updating $($s.Name)..."
        Push-Location $s.Path; try { git pull --ff-only -q 2>&1 | Out-Null } catch {}; Pop-Location
    } else {
        Write-Step "Cloning $($s.Name)..."
        git clone --depth 1 $s.Url $s.Path 2>&1 | Out-Null
    }
    Write-Ok "$($s.Name) ready"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3 — WSL2 configuration
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 3 — WSL2 configuration"

$wslCfg = Join-Path $env:USERPROFILE ".wslconfig"
if ((Test-Path $wslCfg) -and ((Get-Content $wslCfg -Raw) -match "\[wsl2\]")) {
    Write-Ok ".wslconfig already configured"
} else {
    try { $ram = [math]::Max(8,[math]::Min(16,[math]::Floor((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum/1GB*0.75))) } catch { $ram = 8 }
    $cpu = [Environment]::ProcessorCount
    @"

[wsl2]
memory=${ram}GB
processors=$cpu
swap=4GB
localhostForwarding=true
networkingMode=mirrored
"@ | Add-Content -Path $wslCfg
    Write-Ok ".wslconfig: ${ram}GB RAM, $cpu CPUs (mirrored networking)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4 — Identity (username / password / hostname)
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 4 — Identity"
Write-Host "  Press Enter to accept defaults. Default password is 'mios'." -ForegroundColor DarkGray
Write-Host ""

$MiosUser     = Read-Line "Linux username" "mios"
$MiosHostname = Read-Line "Hostname"       "mios"
$pwPlain      = Read-Password "Password"

if ([string]::IsNullOrWhiteSpace($pwPlain)) { $pwPlain = "mios" }
$MiosPasswordHash = Get-PasswordHash $pwPlain

Write-Host ""
Write-Ok "User: $MiosUser  Hostname: $MiosHostname  Password: (hashed)"

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5 — Write identity into WSL (/etc/mios/install.env)
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 5 — Writing identity to WSL"

$tmpEnv = Join-Path $env:TEMP "mios-install.env"
@"
MIOS_USER="$MiosUser"
MIOS_HOSTNAME="$MiosHostname"
MIOS_USER_PASSWORD_HASH="$MiosPasswordHash"
"@ | Set-Content $tmpEnv -Encoding UTF8

try {
    $wslTmp = (& wsl.exe -d $WslDistro wslpath ($tmpEnv -replace '\\','/') 2>$null).Trim()
    & wsl.exe -d $WslDistro bash -lc "sudo mkdir -p /etc/mios && sudo cp '$wslTmp' /etc/mios/install.env && sudo chmod 0640 /etc/mios/install.env"
    Write-Ok "/etc/mios/install.env written in $WslDistro"
} catch {
    Write-Warn "Could not write install.env to WSL (non-fatal — defaults will apply)"
}
Remove-Item $tmpEnv -ErrorAction SilentlyContinue

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 6 — Windows application registration + Start Menu
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 6 — Application registration"

$pwsh        = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { "powershell.exe" }
$selfScript  = Join-Path $bootstrapRepo "install.ps1"
$uninstScript = Join-Path $MiosInstallDir "uninstall.ps1"
$uninstCmd   = "$pwsh -ExecutionPolicy Bypass -File `"$uninstScript`""

# Add/Remove Programs
if (-not (Test-Path $UninstallRegKey)) { New-Item -Path $UninstallRegKey -Force | Out-Null }
@{
    DisplayName          = "MiOS - Immutable Fedora AI Workstation"
    DisplayVersion       = $MiosVersion
    Publisher            = "MiOS-DEV"
    InstallLocation      = $MiosInstallDir
    UninstallString      = $uninstCmd
    QuietUninstallString = "$uninstCmd -Quiet"
    URLInfoAbout         = "https://github.com/mios-dev/mios"
    NoModify             = [int]1
    NoRepair             = [int]1
}.GetEnumerator() | ForEach-Object {
    $t = if ($_.Value -is [int]) { "DWord" } else { "String" }
    Set-ItemProperty -Path $UninstallRegKey -Name $_.Key -Value $_.Value -Type $t
}
Write-Ok "Registered in Add/Remove Programs (HKCU)"

# Start Menu
if (-not (Test-Path $StartMenuDir)) { New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null }
@(
    @{ File="MiOS Setup.lnk";       Target=$pwsh;     Args="-ExecutionPolicy Bypass -File `"$selfScript`"";             Desc="Re-run MiOS setup wizard";      Dir=$MiosInstallDir },
    @{ File="MiOS Build.lnk";       Target=$pwsh;     Args="-ExecutionPolicy Bypass -File `"$selfScript`" -BuildOnly";   Desc="Pull latest + build MiOS image"; Dir=$MiosInstallDir },
    @{ File="MiOS WSL Terminal.lnk"; Target="wsl.exe"; Args="-d $WslDistro";                                             Desc="Open MiOS WSL2 terminal";        Dir=$env:USERPROFILE },
    @{ File="Uninstall MiOS.lnk";   Target=$pwsh;     Args="-ExecutionPolicy Bypass -File `"$uninstScript`"";            Desc="Remove MiOS";                    Dir=$MiosInstallDir }
) | ForEach-Object {
    New-Shortcut (Join-Path $StartMenuDir $_.File) $_.Target $_.Args $_.Desc $_.Dir
}
Write-Ok "Start Menu group 'MiOS' (4 shortcuts)"

# Write uninstaller
@"
#Requires -Version 5.1
param([switch]`$Quiet)
`$ErrorActionPreference = 'Stop'
`$I = '$($MiosInstallDir  -replace "'","''")'
`$D = '$($MiosDataDir     -replace "'","''")'
`$C = '$($MiosConfigDir   -replace "'","''")'
`$S = '$($StartMenuDir    -replace "'","''")'
`$K = '$($UninstallRegKey -replace "'","''")'
`$W = '$WslDistro'
if (-not `$Quiet) {
    Write-Host ''; Write-Host '  MiOS Uninstaller' -ForegroundColor Red; Write-Host ''
    Write-Host "  Removes: `$I, `$D, Start Menu, Add/Remove Programs entry"
    Write-Host "  Preserves: `$C (config)"; Write-Host ''
    if ((Read-Host "  Type 'yes' to confirm") -ne 'yes') { Write-Host '  Aborted.'; exit 0 }
}
try { `$d = wsl --list --quiet 2>`$null; if (`$d -match `$W) { wsl --unregister `$W 2>`$null } } catch {}
foreach (`$p in @(`$I,`$D,`$S)) { if (Test-Path `$p) { Remove-Item `$p -Recurse -Force } }
if (Test-Path `$K) { Remove-Item `$K -Recurse -Force }
Write-Host ''; Write-Host "  MiOS removed. Config at `$C preserved." -ForegroundColor Green
"@ | Set-Content $uninstScript -Encoding UTF8
Write-Ok "uninstall.ps1 written"

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 7 — Build
# ═══════════════════════════════════════════════════════════════════════════════
Write-Phase "Phase 7 — Building MiOS OCI image"
Write-Host "  This takes 15-30 minutes. Output streams live from WSL." -ForegroundColor DarkGray
Write-Host ""

$rc = Invoke-WslBuild

# ═══════════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
if ($rc -eq 0) {
    Write-Host "  +================================================+" -ForegroundColor Green
    Write-Host "  |  MiOS installed and built successfully!        |" -ForegroundColor Green
    Write-Host "  +================================================+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Start Menu shortcuts created under 'MiOS':" -ForegroundColor White
    Write-Host "    MiOS Setup       -- re-run this installer at any time" -ForegroundColor DarkGray
    Write-Host "    MiOS Build       -- pull latest + rebuild" -ForegroundColor DarkGray
    Write-Host "    MiOS WSL Terminal -- open a shell inside the build distro" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Image: localhost/mios:latest (in $WslDistro Podman storage)" -ForegroundColor DarkGray
} else {
    Write-Host "  +================================================+" -ForegroundColor Red
    Write-Host "  |  Build failed (exit $rc)                       |" -ForegroundColor Red
    Write-Host "  +================================================+" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Run 'MiOS WSL Terminal' and check: sudo just build" -ForegroundColor Yellow
}
Write-Host ""
exit $rc
