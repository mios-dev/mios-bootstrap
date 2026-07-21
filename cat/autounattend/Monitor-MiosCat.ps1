<#
.SYNOPSIS
    MiOS Dedicated Live SSOT-Driven Build & Flash Monitor
    Sourced 100% LIVE from mios.toml SSOT via MiOS-Provision.lib.ps1 (Read-MiosToml).
#>
param(
    [string]$LogPath,
    [string]$TomlPath
)

# -----------------------------------------------------------------------------
# 1. Load Canonical SSOT Library & Resolve Configuration Live
# -----------------------------------------------------------------------------
$libPath = Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1'
if (-not (Test-Path $libPath)) {
    $libPath = 'C:\mios-bootstrap\cat\autounattend\MiOS-Provision.lib.ps1'
}
. $libPath

if (-not $TomlPath) {
    $c = @(
        $env:MIOS_TOML,
        'C:\mios-bootstrap\mios.toml',
        'C:\MiOS\usr\share\mios\mios.toml',
        'M:\etc\mios\mios.toml'
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $TomlPath = if ($c) { $c } else { 'C:\mios-bootstrap\mios.toml' }
}

# 100% LIVE SSOT Reading via Get-Toml (Zero hardcoded values)
$toml = Read-MiosToml -Path $TomlPath

$ssotVersion = Get-Toml $toml 'meta.mios_version' (Get-Toml $toml 'version' '')
$ssotTagline = Get-Toml $toml 'branding.tagline' (Get-Toml $toml 'branding.tagline_app' '')
$ssotUser    = Get-Toml $toml 'identity.username' $env:USERNAME
$ssotHost    = Get-Toml $toml 'identity.hostname' $env:COMPUTERNAME
$accentHex   = Get-Toml $toml 'cat.accent_color' (Get-Toml $toml 'colors.accent' (Get-Toml $toml 'theme.accent' '1A407F'))
$accentHex   = $accentHex.TrimStart('#')
if ($accentHex.Length -lt 6) { $accentHex = '1A407F' }

# Convert Live SSOT Accent Hex to TrueColor RGB
$r = [Convert]::ToByte($accentHex.Substring(0,2), 16)
$g = [Convert]::ToByte($accentHex.Substring(2,2), 16)
$b = [Convert]::ToByte($accentHex.Substring(4,2), 16)

# -----------------------------------------------------------------------------
# 2. Resolve Log Paths Dynamically
# -----------------------------------------------------------------------------
if (-not $LogPath) {
    $candidates = @(
        'C:\Windows\Temp\mios-cat-install.log',
        'C:\Windows\Temp\mios-setupcomplete.log'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $LogPath = $c; break }
    }
    if (-not $LogPath) { $LogPath = 'C:\Windows\Temp\mios-cat-install.log' }
}

# -----------------------------------------------------------------------------
# 3. ANSI TrueColor & Theme Palette (SSOT-Driven Live)
# -----------------------------------------------------------------------------
$e = [char]27
$cReset   = "$e[0m"
$cBold    = "$e[1m"

# Live Palette derived directly from SSOT Accent Color ($r,$g,$b)
$cAccent  = "$e[38;2;${r};${g};${b}m$cBold"
$cHeader  = "$e[38;2;96;165;250m$cBold"   # Soft Light Blue
$cSuccess = "$e[38;2;16;185;129m$cBold"  # Emerald Green
$cWarn    = "$e[38;2;245;158;11m$cBold"  # Amber Gold
$cError   = "$e[38;2;239;68;68m$cBold"   # Crimson Red
$cMuted   = "$e[38;2;100;116;139m"       # Slate Gray
$cFg      = "$e[38;2;241;245;249m"       # Off-White Text
$cBadge   = "$e[48;2;30;41;59m$e[38;2;226;232;240m"

[Console]::Title = "MiOS-Cat v$ssotVersion -- SSOT Dedicated Build Monitor"

# -----------------------------------------------------------------------------
# 4. Helper Functions
# -----------------------------------------------------------------------------
function Format-ProgressBar {
    param([double]$pct, [int]$width = 45)
    $pctClamped = [math]::Min(100.0, [math]::Max(0.0, $pct))
    $filled = [int][math]::Round(($pctClamped / 100.0) * $width)
    $empty = $width - $filled
    if ($filled -lt 0) { $filled = 0 }
    if ($empty -lt 0) { $empty = 0 }

    $barFilled = "#" * $filled
    $barEmpty  = "-" * $empty
    
    $color = if ($pctClamped -ge 100.0) { $cSuccess } elseif ($pctClamped -gt 70.0) { $cHeader } elseif ($pctClamped -gt 30.0) { $cAccent } else { $cWarn }
    return ("{0}[{1}{2}{3}] {4:F1}%{5}" -f $color, $barFilled, $cMuted, $barEmpty, $pctClamped, $cReset)
}

# 10 Defined Pipeline Stages with Progress Weightings
$stages = @(
    @{ Id=1; Name="Preflight Checks & SSOT Init";  MinPct=0.0;  MaxPct=10.0 },
    @{ Id=2; Name="Medicat & Arch/Fedora Fetch";   MinPct=10.0; MaxPct=25.0 },
    @{ Id=3; Name="Localhost WinPE WIM Servicing";  MinPct=25.0; MaxPct=40.0 },
    @{ Id=4; Name="WinPE Unmount & Compression";   MinPct=40.0; MaxPct=50.0 },
    @{ Id=5; Name="UUP Flight Fetch & Extract";    MinPct=50.0; MaxPct=65.0 },
    @{ Id=6; Name="DISM Debloat & Driver Inject";  MinPct=65.0; MaxPct=75.0 },
    @{ Id=7; Name="Install.wim/ESD Compression";   MinPct=75.0; MaxPct=85.0 },
    @{ Id=8; Name="Autounattend & oscdimg Build";  MinPct=85.0; MaxPct=90.0 },
    @{ Id=9; Name="AIO Gate & USB Formatting";     MinPct=90.0; MaxPct=95.0 },
    @{ Id=10;Name="32-Thread Robocopy USB Flash";  MinPct=95.0; MaxPct=100.0 }
)

# -----------------------------------------------------------------------------
# 5. Main Monitoring Loop
# -----------------------------------------------------------------------------
$lastOverallPct = 0.0

while ($true) {
    # Re-read SSOT live in loop for real-time config updates
    $toml = Read-MiosToml -Path $TomlPath
    $ssotVersion = Get-Toml $toml 'meta.mios_version' $ssotVersion
    $ssotTagline = Get-Toml $toml 'branding.tagline' $ssotTagline
    $ssotUser    = Get-Toml $toml 'identity.username' $ssotUser
    $ssotHost    = Get-Toml $toml 'identity.hostname' $ssotHost

    # Check for active build logs in addition to main log
    $activeLogs = @($LogPath)
    $buildLogs = Get-ChildItem -Path "M:\MiOS\isobuild_live\logs\build-*.log", "C:\MiOS\isobuild_live\logs\build-*.log" -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 2 | Select-Object -ExpandProperty FullName
    if ($buildLogs) { $activeLogs += $buildLogs }

    $allLines = @()
    foreach ($path in $activeLogs) {
        if (Test-Path $path) {
            try {
                $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $reader = New-Object System.IO.StreamReader($stream)
                while (-not $reader.EndOfStream) {
                    $allLines += $reader.ReadLine()
                }
                $reader.Close()
                $stream.Close()
            } catch {}
        }
    }

    # State tracking
    $currentStageId = 1
    $subTaskPct = 0.0
    $subTaskName = "Initializing SSOT pipeline..."
    $alerts = @()

    # Parse lines for stage transitions, DISM percentages, and warnings
    foreach ($line in $allLines) {
        if (-not $line) { continue }

        # Stage Detections
        if ($line -match "RUNNING PREFLIGHT CHECKS") { $currentStageId = 1; $subTaskName = "Verifying admin privileges & SSOT ($TomlPath)..." }
        elseif ($line -match "PHASE 1: ALL-IN-ONE|Pulling/Resuming core Medicat|Pulling SystemRescue|Pulling FULL Fedora") { $currentStageId = 2; $subTaskName = "Downloading/verifying core ISOs & archives..." }
        elseif ($line -match "Mounting WIM image on Localhost SSD|Injecting custom wallpaper") { $currentStageId = 3; $subTaskName = "Applying wallpaper, fonts & registry hives to WinPE..." }
        elseif ($line -match "Committing changes and unmounting|Exporting and compressing Localhost") { $currentStageId = 4; $subTaskName = "Exporting & compressing serviced MiOS_PE.wim..." }
        elseif ($line -match "Compiling MiOS-Xbox Installer ISO|UUP fetch: channel=") { $currentStageId = 5; $subTaskName = "Resolving UUP Dev flight & fetching stock packages..." }
        elseif ($line -match "Removing \d+ capabilities|Disabling \d+ optional features|Removing \d+ provisioned appx|Xbox/gaming feature overrides") { $currentStageId = 6; $subTaskName = "DISM offline debloat & driver package injections..." }
        elseif ($line -match "Exporting and compressing to install|Creating install.wim|Using LZX compression") { $currentStageId = 7; $subTaskName = "LZX/LZMS 32-thread compression of install image..." }
        elseif ($line -match "Generating autounattend.xml|oscdimg ->") { $currentStageId = 8; $subTaskName = "Generating autounattend & building ISO with oscdimg..." }
        elseif ($line -match "PHASE 2: TARGET DRIVE FORMAT|Formatting and merging all USB partitions|Installing Ventoy bootloader") { $currentStageId = 9; $subTaskName = "Formatting USB & installing Ventoy bootloader..." }
        elseif ($line -match "SINGLE FLASH PASS|robocopy .* Live_Operating_Systems") { $currentStageId = 10; $subTaskName = "Robocopy 32-thread write of AIO payload to target USB..." }
        elseif ($line -match "MiOS-Cat DEDICATED USB INSTALLATION COMPLETED|AIO SUCCESS") { $currentStageId = 10; $subTaskPct = 100.0; $subTaskName = "Build & flash completed successfully!" }

        # Sub-Task Progress Parsing (DISM, WIM, Robocopy, curl)
        if ($line -match '\[\s*(=+|\*+)?\s*(\d+\.\d+)%\s*\]') {
            $subTaskPct = [double]$Matches[2]
        }
        elseif ($line -match 'Archiving file data:\s*\d+\s*MiB of \d+\s*MiB \((\d+)%\) done') {
            $subTaskPct = [double]$Matches[1]
        }
        elseif ($line -match '(\d+\.\d+)%') {
            $val = [double]$Matches[1]
            if ($val -le 100.0) { $subTaskPct = $val }
        }

        # Warning & Error Alerts Detection
        if ($line -match '\[!\]|\[WARNING\]|\[FATAL ERROR\]|retry \d+/\d+') {
            $cleanAlert = $line -replace '\s+', ' '
            if ($cleanAlert.Length -gt 85) { $cleanAlert = $cleanAlert.Substring(0, 85) + "..." }
            if ($alerts -notcontains $cleanAlert) { $alerts += $cleanAlert }
        }
    }

    # Calculate Monotonic Overall Progress
    $stg = $stages | Where-Object Id -eq $currentStageId | Select-Object -First 1
    $range = $stg.MaxPct - $stg.MinPct
    $calcPct = $stg.MinPct + ($range * ($subTaskPct / 100.0))
    if ($calcPct -gt $lastOverallPct) { $lastOverallPct = $calcPct }
    if ($currentStageId -eq 10 -and $subTaskPct -eq 100.0) { $lastOverallPct = 100.0 }

    # -----------------------------------------------------------------------------
    # Render Framed Dashboard UI (SSOT-Driven Live)
    # -----------------------------------------------------------------------------
    Clear-Host
    Write-Host ("{0}+------------------------------------------------------------------------------+" -f $cAccent)
    Write-Host ("{0}|   __  __ _  ___  ___        ___      _                                      |" -f $cAccent)
    Write-Host ("{0}|  |  \/  (_)/ _ \/ __| ___  / __|__ _| |_                                    |" -f $cAccent)
    Write-Host ("{0}|  | |\/| | | (_) \__ \/___|| (__/ _` |  _|                                   |" -f $cAccent)
    Write-Host ("{0}|  |_|  |_|_|\___/|___/      \___\__,_|\__|                                   |" -f $cAccent)
    Write-Host ("{0}|      {1}M i O S   v{2}   --   S S O T   B U I L D   M O N I T O R{3}        |" -f $cAccent, $cWarn, $ssotVersion, $cAccent)
    Write-Host ("{0}+------------------------------------------------------------------------------+{1}" -f $cAccent, $cReset)
    Write-Host (" {0}  SSOT Config : {1}{2}{3}" -f $cMuted, $cFg, $TomlPath, $cReset)
    Write-Host (" {0}  User / Host : {1}{2} @ {3}{4}" -f $cMuted, $cFg, $ssotUser, $ssotHost, $cReset)
    Write-Host (" {0}  Tagline     : {1}{2}{3}" -f $cMuted, $cFg, $ssotTagline, $cReset)
    Write-Host ("{0}--------------------------------------------------------------------------------{1}" -f $cMuted, $cReset)

    # Status Bar
    Write-Host (" {0}  ACTIVE STAGE  {1} {2}Stage {3} of 10 : {4}{5}{6}" -f $cBadge, $cReset, $cBold, $currentStageId, $cAccent, $stg.Name, $cReset)
    Write-Host (" {0}  CURRENT TASK  {1} {2}{3}{4}" -f $cBadge, $cReset, $cFg, $subTaskName, $cReset)
    Write-Host ""

    # Overall Visual Progress Bar
    Write-Host ("  Overall Progress : {0}" -f (Format-ProgressBar -pct $lastOverallPct -width 48))
    Write-Host ("  Sub-Task Progress: {0}" -f (Format-ProgressBar -pct $subTaskPct -width 48))
    Write-Host ""
    Write-Host ("{0}--------------------------------------------------------------------------------{1}" -f $cMuted, $cReset)

    # Stage Matrix Breakdown
    Write-Host ("{0} PIPELINE STAGES:{1}" -f $cBold, $cReset)
    for ($s = 1; $s -le 10; $s++) {
        $stgItem = $stages | Where-Object Id -eq $s
        $badgeText = if ($s -lt $currentStageId) { "{0}[  DONE  ]{1}" -f $cSuccess, $cReset }
                     elseif ($s -eq $currentStageId) { "{0}[ RUNNING ]{1}" -f $cWarn, $cReset }
                     else { "{0}[ QUEUED  ]{1}" -f $cMuted, $cReset }
        $numStr = $s.ToString().PadLeft(2, ' ')
        Write-Host ("   {0} Stage {1} : {2}" -f $badgeText, $numStr, $stgItem.Name)
    }
    Write-Host ("{0}--------------------------------------------------------------------------------{1}" -f $cMuted, $cReset)

    # Alerts & Warnings Panel
    if ($alerts.Count -gt 0) {
        Write-Host ("{0} ALERTS AND WARNINGS ({1}):{2}" -f $cWarn, $alerts.Count, $cReset)
        foreach ($alt in ($alerts | Select-Object -Last 3)) {
            Write-Host ("   {0}[!]{1} {2}" -f $cWarn, $cReset, $alt)
        }
        Write-Host ("{0}--------------------------------------------------------------------------------{1}" -f $cMuted, $cReset)
    }

    # Live Log Tail (Last 5 lines, cleaned)
    Write-Host ("{0} LIVE LOG OUTPUT STREAM:{1}" -f $cBold, $cReset)
    $tail = $allLines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[\=\-\#]+\s*$' } | Select-Object -Last 5
    if ($tail) {
        foreach ($tLine in $tail) {
            $cleanLine = $tLine.Trim() -replace "$e\[[0-9;]*m", ""
            if ($cleanLine.Length -gt 80) { $cleanLine = $cleanLine.Substring(0, 80) + "..." }
            Write-Host ("   {0}>{1} {2}{3}{4}" -f $cMuted, $cReset, $cFg, $cleanLine, $cReset)
        }
    } else {
        Write-Host ("   {0}> Waiting for active log activity...{1}" -f $cMuted, $cReset)
    }

    Write-Host ("{0}--------------------------------------------------------------------------------{1}" -f $cMuted, $cReset)

    if ($lastOverallPct -ge 100.0) {
        Write-Host ("`n  {0}[AIO SUCCESS] Build and Flash Complete! You can close this monitor.{1}`n" -f $cSuccess, $cReset)
        break
    }

    Start-Sleep -Seconds 2
}
