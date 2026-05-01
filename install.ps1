#Requires -Version 5.1
# MiOS Windows Application Installer
# Installs MiOS as a Windows application with Start Menu integration and Add/Remove Programs entry.
#
# Usage (one-liner):
#   irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1 | iex
#
# Or with options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1))) -Unattended

param(
    [switch]$Unattended,
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "Programs\MiOS"),
    [string]$WslDistroName = "MiOS"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────
$MiosInstallDir      = $InstallRoot
$MiosRepoDir         = Join-Path $MiosInstallDir "repo"
$MiosBinDir          = Join-Path $MiosInstallDir "bin"
$MiosConfigDir       = Join-Path $env:APPDATA "MiOS"
$MiosDataDir         = Join-Path $env:LOCALAPPDATA "MiOS"
$MiosLogsDir         = Join-Path $MiosDataDir "logs"
$MiosRegistryFile    = Join-Path $MiosConfigDir "registry.toml"
$MiosUninstallScript = Join-Path $MiosInstallDir "uninstall.ps1"

$MiosRepoUrl         = "https://github.com/mios-dev/mios.git"
$MiosBootstrapUrl    = "https://github.com/mios-dev/mios-bootstrap.git"
$MiosVersion         = "v0.2.0"

$UninstallRegKey     = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MiOS"
$StartMenuDir        = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\MiOS"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("  " + ("─" * ($Text.Length))) -ForegroundColor DarkGray
}

function Write-Step   { param([string]$Text); Write-Host "  >> $Text" -ForegroundColor White }
function Write-Ok     { param([string]$Text); Write-Host "  + $Text" -ForegroundColor Green }
function Write-Warn   { param([string]$Text); Write-Host "  ! $Text" -ForegroundColor Yellow }
function Write-Fail   { param([string]$Text); Write-Host "  x $Text" -ForegroundColor Red }

function Test-CommandAvailable {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function New-Shortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments    = "",
        [string]$Description  = "",
        [string]$WorkingDir   = "",
        [string]$IconPath     = ""
    )
    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($ShortcutPath)
    $sc.TargetPath = $TargetPath
    if ($Arguments)  { $sc.Arguments       = $Arguments }
    if ($Description){ $sc.Description     = $Description }
    if ($WorkingDir) { $sc.WorkingDirectory = $WorkingDir }
    if ($IconPath)   { $sc.IconLocation    = $IconPath }
    $sc.Save()
}

# ─────────────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |        MiOS Windows Installer                |" -ForegroundColor Cyan
Write-Host "  |    Immutable Fedora AI Workstation           |" -ForegroundColor Cyan
Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Version : $MiosVersion"    -ForegroundColor DarkGray
Write-Host "  Install : $MiosInstallDir" -ForegroundColor DarkGray
Write-Host "  Config  : $MiosConfigDir"  -ForegroundColor DarkGray
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 0: Prerequisite checks
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Checking prerequisites"

$preflight = $true

if (Test-CommandAvailable "git") {
    $gitVer = (git --version 2>$null) -replace "git version ", ""
    Write-Ok "Git $gitVer"
} else {
    Write-Fail "Git not found. Install: winget install Git.Git"
    $preflight = $false
}

if (Test-CommandAvailable "wsl") {
    try { wsl --status 2>&1 | Out-Null } catch {}
    Write-Ok "WSL2 available"
} else {
    Write-Warn "WSL2 not found. Enable with: wsl --install"
    Write-Warn "Required for the MiOS build pipeline and runtime."
}

if (Test-CommandAvailable "podman") {
    $podmanVer = (podman --version 2>$null) -replace "podman version ", ""
    Write-Ok "Podman $podmanVer"
} else {
    Write-Warn "Podman not found. Required to build MiOS OCI images."
    Write-Warn "Install: winget install RedHat.Podman-Desktop"
}

if (-not $preflight) {
    Write-Host ""
    Write-Fail "Prerequisites not met. Install missing tools and re-run."
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Create directory structure
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Creating directory structure"

foreach ($dir in @($MiosInstallDir, $MiosRepoDir, $MiosBinDir, $MiosConfigDir, $MiosDataDir, $MiosLogsDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
Write-Ok "Directories ready under $MiosInstallDir"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Clone or update repositories
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Cloning MiOS repositories"

$miosRepo      = Join-Path $MiosRepoDir "mios"
$bootstrapRepo = Join-Path $MiosRepoDir "mios-bootstrap"

foreach ($spec in @(
    @{ Path = $miosRepo;      Url = $MiosRepoUrl;      Name = "mios.git" },
    @{ Path = $bootstrapRepo; Url = $MiosBootstrapUrl; Name = "mios-bootstrap.git" }
)) {
    if (Test-Path (Join-Path $spec.Path ".git")) {
        Write-Step "Updating $($spec.Name)..."
        Push-Location $spec.Path
        try { git pull --ff-only --quiet 2>&1 | Out-Null } catch {}
        Pop-Location
        Write-Ok "$($spec.Name) up to date"
    } else {
        Write-Step "Cloning $($spec.Name) to $($spec.Path)..."
        git clone --depth 1 $spec.Url $spec.Path 2>&1 | Out-Null
        Write-Ok "$($spec.Name) cloned"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Windows user-space config skeleton
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Writing configuration"

if (-not (Test-Path $MiosRegistryFile)) {
    $now = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $installDirEsc = $MiosInstallDir -replace '\\', '\\'
    $repoDirEsc    = $MiosRepoDir    -replace '\\', '\\'

    $toml = @"
# MiOS Windows Registry
# Generated by install.ps1 $MiosVersion on $now
# Edit any field to override. Re-run install.ps1 to refresh shortcuts and registry.

[install]
version        = "$MiosVersion"
install_dir    = "$installDirEsc"
repo_dir       = "$repoDirEsc"
installed_at   = "$now"
wsl_distro     = "$WslDistroName"

[build]
image_tag      = "latest"
mios_repo      = "$MiosRepoUrl"
bootstrap_repo = "$MiosBootstrapUrl"

[ai]
endpoint       = "http://localhost:8080/v1"
model          = "qwen2.5-coder:7b"
embed_model    = "nomic-embed-text"
"@
    Set-Content -Path $MiosRegistryFile -Value $toml -Encoding UTF8
    Write-Ok "registry.toml -> $MiosRegistryFile"
} else {
    Write-Ok "registry.toml already present -- preserved"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: .wslconfig
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Configuring WSL2"

$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"

if ((Test-Path $wslConfigPath) -and ((Get-Content $wslConfigPath -Raw) -match "\[wsl2\]")) {
    Write-Ok ".wslconfig already has [wsl2] section -- preserved"
} else {
    try {
        $totalRamGB = [math]::Round(
            (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB)
        $wslRamGB = [math]::Max(8, [math]::Min(16, [math]::Floor($totalRamGB * 0.75)))
    } catch { $wslRamGB = 8 }
    $wslCpus = [Environment]::ProcessorCount

    $wslBlock = @"

[wsl2]
# MiOS-managed -- sized for ${wslRamGB}GB / $wslCpus cores.
memory=${wslRamGB}GB
processors=$wslCpus
swap=4GB
localhostForwarding=true
networkingMode=mirrored
"@
    Add-Content -Path $wslConfigPath -Value $wslBlock
    Write-Ok ".wslconfig: memory=${wslRamGB}GB processors=$wslCpus (mirrored networking)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: Launcher scripts
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Writing launcher scripts"

$bootstrapLauncher = Join-Path $MiosBinDir "mios-bootstrap.ps1"
$buildLauncher     = Join-Path $MiosBinDir "mios-build.ps1"

Set-Content -Path $bootstrapLauncher -Encoding UTF8 -Value @'
#Requires -Version 5.1
# MiOS bootstrap launcher
$repoScript = Join-Path $PSScriptRoot "..\repo\mios-bootstrap\bootstrap.ps1"
if (-not (Test-Path $repoScript)) { Write-Error "bootstrap.ps1 not found. Re-run install.ps1."; exit 1 }
& $repoScript @args
'@

Set-Content -Path $buildLauncher -Encoding UTF8 -Value @'
#Requires -Version 5.1
# MiOS build launcher
$repoScript = Join-Path $PSScriptRoot "..\repo\mios\mios-build-local.ps1"
if (-not (Test-Path $repoScript)) { Write-Error "mios-build-local.ps1 not found. Re-run install.ps1."; exit 1 }
& $repoScript @args
'@

Write-Ok "Launchers written to $MiosBinDir"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6: Add/Remove Programs (HKCU -- no admin required)
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Registering application"

if (-not (Test-Path $UninstallRegKey)) { New-Item -Path $UninstallRegKey -Force | Out-Null }

$pwsh         = if (Test-CommandAvailable "pwsh") { (Get-Command pwsh).Source } else { "powershell.exe" }
$uninstallCmd = "$pwsh -ExecutionPolicy Bypass -File `"$MiosUninstallScript`""

@{
    DisplayName          = "MiOS - Immutable Fedora AI Workstation"
    DisplayVersion       = $MiosVersion
    Publisher            = "MiOS-DEV"
    InstallLocation      = $MiosInstallDir
    UninstallString      = $uninstallCmd
    QuietUninstallString = "$uninstallCmd -Quiet"
    URLInfoAbout         = "https://github.com/mios-dev/mios"
    NoModify             = [int]1
    NoRepair             = [int]1
}.GetEnumerator() | ForEach-Object {
    $type = if ($_.Value -is [int]) { "DWord" } else { "String" }
    Set-ItemProperty -Path $UninstallRegKey -Name $_.Key -Value $_.Value -Type $type
}
Write-Ok "Registered in Add/Remove Programs (HKCU)"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 7: Start Menu shortcuts
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Creating Start Menu shortcuts"

if (-not (Test-Path $StartMenuDir)) { New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null }

@(
    @{ File = "MiOS Bootstrap.lnk";   Target = $pwsh;     Args = "-ExecutionPolicy Bypass -File `"$bootstrapLauncher`""; Desc = "MiOS interactive setup wizard";  Dir = $MiosInstallDir },
    @{ File = "MiOS Build.lnk";       Target = $pwsh;     Args = "-ExecutionPolicy Bypass -File `"$buildLauncher`"";     Desc = "Build MiOS OCI image locally";    Dir = $MiosInstallDir },
    @{ File = "MiOS WSL Terminal.lnk"; Target = "wsl.exe"; Args = "--distribution $WslDistroName";                       Desc = "Open MiOS WSL2 terminal";          Dir = $env:USERPROFILE },
    @{ File = "Uninstall MiOS.lnk";   Target = $pwsh;     Args = "-ExecutionPolicy Bypass -File `"$MiosUninstallScript`""; Desc = "Remove MiOS";                   Dir = $MiosInstallDir }
) | ForEach-Object {
    New-Shortcut -ShortcutPath (Join-Path $StartMenuDir $_.File) `
        -TargetPath $_.Target -Arguments $_.Args -Description $_.Desc -WorkingDir $_.Dir
}
Write-Ok "Start Menu group 'MiOS' created (4 shortcuts)"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 8: Write uninstall.ps1
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Writing uninstaller"

$e = @{
    I = $MiosInstallDir  -replace "'", "''"
    D = $MiosDataDir     -replace "'", "''"
    C = $MiosConfigDir   -replace "'", "''"
    S = $StartMenuDir    -replace "'", "''"
    K = $UninstallRegKey -replace "'", "''"
    W = $WslDistroName   -replace "'", "''"
}

@"
#Requires -Version 5.1
# MiOS Uninstaller -- generated by install.ps1 $MiosVersion
param([switch]`$Quiet)
`$ErrorActionPreference = 'Stop'
`$InstallDir   = '$($e.I)'
`$DataDir      = '$($e.D)'
`$ConfigDir    = '$($e.C)'
`$StartMenuDir = '$($e.S)'
`$RegKey       = '$($e.K)'
`$WslDistro    = '$($e.W)'

if (-not `$Quiet) {
    Write-Host ''; Write-Host '  MiOS Uninstaller' -ForegroundColor Red; Write-Host ''
    Write-Host '  Removes:'
    Write-Host "    `$InstallDir"
    Write-Host "    `$DataDir"
    Write-Host '    Start Menu shortcuts'
    Write-Host '    Add/Remove Programs entry'
    Write-Host ''
    Write-Host "  Config at `$ConfigDir is preserved." -ForegroundColor DarkGray
    Write-Host ''
    `$c = Read-Host "  Type 'yes' to confirm"
    if (`$c -ne 'yes') { Write-Host '  Aborted.'; exit 0 }
}

try { `$d = wsl --list --quiet 2>`$null; if (`$d -match `$WslDistro) { wsl --unregister `$WslDistro 2>`$null } } catch {}
foreach (`$p in @(`$InstallDir, `$DataDir, `$StartMenuDir)) {
    if (Test-Path `$p) { Remove-Item `$p -Recurse -Force; Write-Host "  Removed `$p" }
}
if (Test-Path `$RegKey) { Remove-Item `$RegKey -Recurse -Force }
Write-Host ''; Write-Host "  MiOS removed. Config preserved at `$ConfigDir" -ForegroundColor Green
"@ | Set-Content -Path $MiosUninstallScript -Encoding UTF8

Write-Ok "uninstall.ps1 -> $MiosUninstallScript"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  +----------------------------------------------+" -ForegroundColor Green
Write-Host "  |      MiOS installed successfully!            |" -ForegroundColor Green
Write-Host "  +----------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host "  Start Menu >> MiOS Bootstrap   -- run the setup wizard"    -ForegroundColor White
Write-Host "             >> MiOS Build        -- build OCI image locally" -ForegroundColor White
Write-Host "             >> MiOS WSL Terminal -- open Linux shell"        -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "  1. Open 'MiOS Bootstrap' from the Start Menu to complete setup." -ForegroundColor White
Write-Host "  2. Or run the Linux bootstrap directly inside WSL2:"              -ForegroundColor White
Write-Host '     sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.sh)"' -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Repos : $MiosRepoDir"   -ForegroundColor DarkGray
Write-Host "  Config: $MiosConfigDir" -ForegroundColor DarkGray
Write-Host ""
