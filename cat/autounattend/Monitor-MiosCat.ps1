<#
.SYNOPSIS
    MiOS Dedicated Live SSOT-Driven Build & Flash Monitor
    Sourced 100% LIVE from mios.toml SSOT and Real-Time Process & File State.
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
if (Test-Path $libPath) { . $libPath }

if (-not $TomlPath) {
    $c = @(
        $env:MIOS_TOML,
        'C:\mios-bootstrap\mios.toml',
        'C:\MiOS\usr\share\mios\mios.toml',
        'M:\etc\mios\mios.toml'
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $TomlPath = if ($c) { $c } else { 'C:\mios-bootstrap\mios.toml' }
}

$toml = if (Get-Command Read-MiosToml -ErrorAction SilentlyContinue) { Read-MiosToml -Path $TomlPath } else { @{} }

$ssotVersion = if (Get-Command Get-Toml -ErrorAction SilentlyContinue) { Get-Toml $toml 'meta.mios_version' '2026.07' } else { '2026.07' }
$ssotTagline = if (Get-Command Get-Toml -ErrorAction SilentlyContinue) { Get-Toml $toml 'branding.tagline' 'Dedicated AIO Operating System' } else { 'Dedicated AIO Operating System' }
$ssotUser    = $env:USERNAME
$ssotHost    = $env:COMPUTERNAME

$accentHex   = if (Get-Command Get-Toml -ErrorAction SilentlyContinue) { Get-Toml $toml 'cat.accent_color' '1A407F' } else { '1A407F' }
$accentHex   = $accentHex.TrimStart('#')
if ($accentHex.Length -lt 6) { $accentHex = '1A407F' }

$r = [Convert]::ToByte($accentHex.Substring(0,2), 16)
$g = [Convert]::ToByte($accentHex.Substring(2,2), 16)
$b = [Convert]::ToByte($accentHex.Substring(4,2), 16)

# -----------------------------------------------------------------------------
# 2. ANSI TrueColor & Theme Palette
# -----------------------------------------------------------------------------
$e = [char]27
$cReset   = "$e[0m"
$cBold    = "$e[1m"
$cAccent  = "$e[38;2;${r};${g};${b}m$cBold"
$cHeader  = "$e[38;2;96;165;250m$cBold"
$cSuccess = "$e[38;2;16;185;129m$cBold"
$cWarn    = "$e[38;2;245;158;11m$cBold"
$cError   = "$e[38;2;239;68;68m$cBold"
$cMuted   = "$e[38;2;100;116;139m"
$cFg      = "$e[38;2;241;245;249m"
$cBadge   = "$e[48;2;30;41;59m$e[38;2;226;232;240m"

[Console]::Title = "MiOS-Cat v$ssotVersion -- SSOT Live Build & Flash Monitor"

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

$stages = @(
    @{ Id=1; Name="Preflight Checks & SSOT Init";  MinPct=0.0;  MaxPct=10.0 },
    @{ Id=2; Name="Medicat & Core Downloads";      MinPct=10.0; MaxPct=25.0 },
    @{ Id=3; Name="Localhost WinPE WIM Servicing"; MinPct=25.0; MaxPct=40.0 },
    @{ Id=4; Name="WinPE Unmount & Compression";  MinPct=40.0; MaxPct=50.0 },
    @{ Id=5; Name="MiOS-Xbox ISO Compilation";     MinPct=50.0; MaxPct=65.0 },
    @{ Id=6; Name="Dedicated Directory Staging";   MinPct=65.0; MaxPct=75.0 },
    @{ Id=7; Name="Fail-Fast Verification Gate";   MinPct=75.0; MaxPct=85.0 },
    @{ Id=8; Name="Ventoy Bootloader & Theme";     MinPct=85.0; MaxPct=90.0 },
    @{ Id=9; Name="32-Thread Robocopy USB Flash";  MinPct=90.0; MaxPct=98.0 },
    @{ Id=10;Name="Branding & Installation Complete";MinPct=98.0;MaxPct=100.0 }
)

$lastOverallPct = 0.0

# -----------------------------------------------------------------------------
# 3. Main Live Refresh Loop
# -----------------------------------------------------------------------------
while ($true) {
    # Resolve SINGLE LATEST active log file to prevent stale historical log pollution
    $primaryLog = 'C:\Windows\Temp\mios-cat-install.log'
    $chosenLog = $null

    if ((Test-Path $primaryLog) -and (Get-Item $primaryLog).Length -gt 0) {
        $chosenLog = $primaryLog
    } else {
        $latestTaskLog = Get-ChildItem -Path "C:\Users\Administrator\.gemini\antigravity-ide\brain\dba6616d-053d-43cd-b86d-a98f223952b8\.system_generated\tasks\task-*.log" -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending |
                         Select-Object -First 1 -ExpandProperty FullName
        if ($latestTaskLog) { $chosenLog = $latestTaskLog }
    }

    $allLines = @()
    if ($chosenLog -and (Test-Path $chosenLog)) {
        try {
            $stream = [System.IO.File]::Open($chosenLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($stream)
            while (-not $reader.EndOfStream) {
                $allLines += $reader.ReadLine()
            }
            $reader.Close()
            $stream.Close()
        } catch {}
    }

    # Slice log lines after the LAST run start marker to discard stale historical errors
    $startIdx = -1
    for ($i = $allLines.Count - 1; $i -ge 0; $i--) {
        if ($allLines[$i] -match '\[START\]|RUNNING PREFLIGHT CHECKS|STARTING MiOS-Cat INSTALLATION') {
            $startIdx = $i
            break
        }
    }
    if ($startIdx -ge 0) {
        $allLines = $allLines[$startIdx..($allLines.Count - 1)]
    }

    # Inspect active running processes
    $proc7z = Get-Process 7z, 7za -ErrorAction SilentlyContinue
    $procRobo = Get-Process robocopy -ErrorAction SilentlyContinue
    $procDism = Get-Process dism -ErrorAction SilentlyContinue
    $procCurl = Get-Process curl -ErrorAction SilentlyContinue

    # Calculate real-time USB drive D: bytes & files
    $usbFiles = 0
    $usbMB = 0.0
    if (Test-Path "D:\") {
        try {
            $stats = Get-ChildItem -Path "D:\" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            if ($stats) {
                $usbFiles = $stats.Count
                $usbMB = [math]::Round(($stats.Sum / 1MB), 2)
            }
        } catch {}
    }

    # Calculate real-time AIO Stage bytes & files
    $stageMB = 0.0
    $stagePath = "M:\MiOS\medicat_stage\AIO_Stage"
    if (Test-Path $stagePath) {
        try {
            $stgStats = Get-ChildItem -Path $stagePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            if ($stgStats) { $stageMB = [math]::Round(($stgStats.Sum / 1MB), 2) }
        } catch {}
    }

    # Determine Active Stage & Task Description
    $currentStageId = 1
    $subTaskPct = 0.0
    $subTaskName = "Initializing preflight checks & environment..."
    $alerts = @()

    foreach ($line in $allLines) {
        if (-not $line) { continue }
        if ($line -match "RUNNING PREFLIGHT CHECKS") { $currentStageId = 1; $subTaskName = "Preflight safety checks verified..." }
        elseif ($line -match "PHASE 1: ALL-IN-ONE|Core Medicat archive|Downloading|Pulling") { $currentStageId = 2; $subTaskName = "Extracting/staging core archives to SSD..." }
        elseif ($line -match "Extracting Mini_Windows WIM|Servicing|Mounting") { $currentStageId = 3; $subTaskName = "Localhost DISM servicing of MiOS_PE.wim..." }
        elseif ($line -match "Exporting and compressing Localhost|trim_path") { $currentStageId = 4; $subTaskName = "Compressing MiOS_PE.wim with /Compress:max..." }
        elseif ($line -match "Compiling MiOS-Xbox Installer ISO|autounattend|New-MiOSISO") { $currentStageId = 5; $subTaskName = "Compiling MiOS-Xbox Installer ISO..." }
        elseif ($line -match "Writing MiOS-PE|Writing Documents|PortableApps") { $currentStageId = 6; $subTaskName = "Staging dedicated MiOS-PE & Documents folders..." }
        elseif ($line -match "SINGLE FLASH PASS|Zero USB writes") { $currentStageId = 7; $subTaskName = "Fail-fast verification passed. Starting flash..." }
        elseif ($line -match "Ventoy|autorun\.inf") { $currentStageId = 8; $subTaskName = "Applying Ventoy tree menu & theme configuration..." }
        elseif ($line -match "Writing PortableApps suite|robocopy .* D:") { $currentStageId = 9; $subTaskName = "Robocopy 32-thread write to USB drive D:..." }
        elseif ($line -match "MiOS-Cat DEDICATED USB INSTALLATION COMPLETED|AIO SUCCESS") { $currentStageId = 10; $subTaskPct = 100.0; $subTaskName = "Build & flash completed successfully!" }

        if ($line -match '(\d+\.\d+)%') {
            $val = [double]$Matches[1]
            if ($val -le 100.0) { $subTaskPct = $val }
        }

        if ($line -match '\[!\]|\[WARNING\]|\[FATAL ERROR\]|ERROR') {
            $cleanAlert = $line -replace '\s+', ' '
            if ($cleanAlert.Length -gt 85) { $cleanAlert = $cleanAlert.Substring(0, 85) + "..." }
            if ($alerts -notcontains $cleanAlert) { $alerts += $cleanAlert }
        }
    }

    # Override stage based on live active processes
    if ($proc7z) {
        $currentStageId = [math]::Max($currentStageId, 2)
        $subTaskName = "7-Zip Extracting Payloads (7z active) | SSD Stage: $stageMB MB"
    }
    if ($procDism) {
        $currentStageId = [math]::Max($currentStageId, 3)
        $subTaskName = "DISM Servicing WinPE / Image (DISM active)..."
    }
    if ($procRobo) {
        $currentStageId = [math]::Max($currentStageId, 9)
        $subTaskName = "Robocopy 32-thread flashing to D: | Written: $usbFiles files ($usbMB MB)"
    }

    $stg = $stages | Where-Object Id -eq $currentStageId | Select-Object -First 1
    $range = $stg.MaxPct - $stg.MinPct
    $calcPct = $stg.MinPct + ($range * ($subTaskPct / 100.0))
    if ($calcPct -gt $lastOverallPct) { $lastOverallPct = $calcPct }
    if ($currentStageId -eq 10 -and $subTaskPct -eq 100.0) { $lastOverallPct = 100.0 }

    # -----------------------------------------------------------------------------
    # Render Dashboard UI
    # -----------------------------------------------------------------------------
    Clear-Host
    Write-Host ("{0}+------------------------------------------------------------------------------+" -f $cAccent)
    Write-Host ("{0}|      {1}M i O S   v{2}   --   S S O T   L I V E   F L A S H   M O N I T O R{3}        |" -f $cAccent, $cWarn, $ssotVersion, $cAccent)
    Write-Host ("{0}+------------------------------------------------------------------------------+{1}" -f $cAccent, $cReset)
    Write-Host (" {0}  SSOT Config : {1}{2}{3}" -f $cMuted, $cFg, $TomlPath, $cReset)
    Write-Host (" {0}  Target USB  : {1}D:\ (Files: {2} | Size: {3} MB){4}" -f $cMuted, $cFg, $usbFiles, $usbMB, $cReset)
    Write-Host (" {0}  SSD Stage   : {1}{2} MB{3}" -f $cMuted, $cFg, $stageMB, $cReset)
    Write-Host ("{0}--------------------------------------------------------------------------------{1}" -f $cMuted, $cReset)

    Write-Host (" {0}  ACTIVE STAGE  {1} {2}Stage {3} of 10 : {4}{5}{6}" -f $cBadge, $cReset, $cBold, $currentStageId, $cAccent, $stg.Name, $cReset)
    Write-Host (" {0}  CURRENT TASK  {1} {2}{3}{4}" -f $cBadge, $cReset, $cFg, $subTaskName, $cReset)
    Write-Host ""

    Write-Host ("  Overall Progress : {0}" -f (Format-ProgressBar -pct $lastOverallPct -width 48))
    Write-Host ("  Sub-Task Progress: {0}" -f (Format-ProgressBar -pct $subTaskPct -width 48))
    Write-Host ""
    Write-Host ("{0}--------------------------------------------------------------------------------{1}" -f $cMuted, $cReset)

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

    if ($alerts.Count -gt 0) {
        Write-Host ("{0} ALERTS AND WARNINGS ({1}):{2}" -f $cWarn, $alerts.Count, $cReset)
        foreach ($alt in ($alerts | Select-Object -Last 3)) {
            Write-Host ("   {0}[!]{1} {2}" -f $cWarn, $cReset, $alt)
        }
        Write-Host ("{0}--------------------------------------------------------------------------------{1}" -f $cMuted, $cReset)
    }

    Write-Host ("{0} LIVE LOG TAIL:{1}" -f $cBold, $cReset)
    $tail = $allLines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[\=\-\#]+\s*$' } | Select-Object -Last 5
    if ($tail) {
        foreach ($tLine in $tail) {
            $cleanLine = $tLine.Trim() -replace "$e\[[0-9;]*m", ""
            if ($cleanLine.Length -gt 80) { $cleanLine = $cleanLine.Substring(0, 80) + "..." }
            Write-Host ("   {0}>{1} {2}{3}{4}" -f $cMuted, $cReset, $cFg, $cleanLine, $cReset)
        }
    } else {
        Write-Host ("   {0}> Monitoring active tasks live...{1}" -f $cMuted, $cReset)
    }

    Write-Host ("{0}--------------------------------------------------------------------------------{1}" -f $cMuted, $cReset)

    if ($lastOverallPct -ge 100.0) {
        Write-Host ("`n  {0}[AIO SUCCESS] Build and Flash Complete! You can close this monitor.{1}`n" -f $cSuccess, $cReset)
        break
    }

    Start-Sleep -Seconds 1
}
