<#
.SYNOPSIS
    MiOS Dedicated Live SSOT-Driven Build & Flash Monitor
    Fully Branded, SSOT-Themed ([colors]) Live Telemetry Stream.
#>
param(
    [string]$LogPath,
    [string]$TomlPath
)

# -----------------------------------------------------------------------------
# 1. VT Console Mode & UTF-8 Encoding Activation (Kernel32 P/Invoke)
# -----------------------------------------------------------------------------
$script:NoColor = $false
try {
    if (-not ($env:MIOS_NO_COLOR -or $env:NO_COLOR)) {
        $vtSig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);' +
                 '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);' +
                 '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
        $k = Add-Type -MemberDefinition $vtSig -Name 'MiosVtMon' -Namespace 'MiosCat' -PassThru -ErrorAction Stop
        $h = $k::GetStdHandle(-11); $m = 0
        if ($k::GetConsoleMode($h, [ref]$m)) { [void]$k::SetConsoleMode($h, ($m -bor 0x0004)) }
    }
} catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Set Console Geometry (120x42)
try {
    $rawUI = $host.UI.RawUI
    $bufSize = $rawUI.BufferSize
    $winSize = $rawUI.WindowSize
    if ($bufSize.Width -lt 120) { $bufSize.Width = 120 }
    if ($bufSize.Height -lt 500) { $bufSize.Height = 500 }
    $rawUI.BufferSize = $bufSize
    if ($winSize.Width -ne 120 -or $winSize.Height -ne 42) {
        $winSize.Width = 120
        $winSize.Height = 42
        $rawUI.WindowSize = $winSize
    }
} catch {}

# -----------------------------------------------------------------------------
# 2. SSOT [colors] & Theme Resolution
# -----------------------------------------------------------------------------
if (-not $TomlPath) {
    $c = @(
        $env:MIOS_TOML,
        'C:\mios-bootstrap\mios.toml',
        'C:\MiOS\usr\share\mios\mios.toml',
        'M:\etc\mios\mios.toml'
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $TomlPath = if ($c) { $c } else { 'C:\mios-bootstrap\mios.toml' }
}

function Get-TomlColor {
    param([string]$Text, [string]$Key, [int[]]$Fallback)
    if ($Text) {
        $m = [regex]::Match($Text, "(?ms)^\s*\[colors\]\s*(.*?)(?=^\s*\[|\z)")
        if ($m.Success) {
            $km = [regex]::Match($m.Groups[1].Value, "(?m)^\s*" + [regex]::Escape($Key) + "\s*=\s*`"#?([0-9A-Fa-f]{6})`"")
            if ($km.Success) {
                $h = $km.Groups[1].Value
                return @([Convert]::ToInt32($h.Substring(0,2),16),[Convert]::ToInt32($h.Substring(2,2),16),[Convert]::ToInt32($h.Substring(4,2),16))
            }
        }
    }
    return $Fallback
}

$rawToml = if (Test-Path $TomlPath) { Get-Content -Raw -LiteralPath $TomlPath -ErrorAction SilentlyContinue } else { '' }

$pal = @{
    bg      = Get-TomlColor $rawToml 'bg'      @(40,34,98)
    fg      = Get-TomlColor $rawToml 'fg'      @(231,223,211)
    accent  = Get-TomlColor $rawToml 'accent'  @(26,64,127)
    cursor  = Get-TomlColor $rawToml 'cursor'  @(243,92,21)
    success = Get-TomlColor $rawToml 'success' @(62,119,101)
    warning = Get-TomlColor $rawToml 'warning' @(243,92,21)
    error   = Get-TomlColor $rawToml 'error'   @(220,39,27)
    muted   = Get-TomlColor $rawToml 'muted'   @(148,142,142)
    subtle  = Get-TomlColor $rawToml 'subtle'  @(183,201,215)
    cyan    = @(6,182,212)
    mag     = @(217,70,239)
}

$ESC = [char]27
function C { param([int[]]$rgb, [string]$t) "$ESC[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$t$ESC[0m" }
function B { param([string]$t) "$ESC[1m$t$ESC[0m" }

$ssotVersion = '2026.07'
$ssotTagline = 'Dedicated AIO Operating System -- SSOT Live Build & Flash Monitor'
[Console]::Title = "MiOS-Cat v$ssotVersion -- SSOT Live Telemetry Stream"

# Unicode framing characters using [char]
$cBoxHoriz = [char]0x2550
$cBoxVert  = [char]0x2551
$cBoxTL    = [char]0x2554
$cBoxTR    = [char]0x2557
$cBoxBL    = [char]0x255A
$cBoxBR    = [char]0x255D
$cBoxLDivider = [char]0x2560
$cBoxRDivider = [char]0x2563
$cBoxPipe  = [char]0x2502

$charBlock = [char]0x2588
$charShade = [char]0x2591
$symOk     = [char]0x2714
$symWarn   = [char]0x26A0
$symErr    = [char]0x2716
$symMag    = [char]0x26A1
$symInfo   = [char]0x2139

$spin = @([char]0x280B, [char]0x2819, [char]0x2839, [char]0x2838, [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827, [char]0x2807, [char]0x280F)
$spinIdx = 0

function Format-ProgressBar {
    param([double]$pct, [int]$width = 65)
    $pctClamped = [math]::Min(100.0, [math]::Max(0.0, $pct))
    $filled = [int][math]::Round(($pctClamped / 100.0) * $width)
    $empty = $width - $filled
    if ($filled -lt 0) { $filled = 0 }
    if ($empty -lt 0) { $empty = 0 }

    $barFilled = [string]$charBlock * $filled
    $barEmpty  = [string]$charShade * $empty
    
    $color = if ($pctClamped -ge 100.0) { $pal.success } elseif ($pctClamped -gt 70.0) { $pal.subtle } elseif ($pctClamped -gt 30.0) { $pal.accent } else { $pal.warning }
    return ("{0}[{1}{2}{3}] {4:F1}%" -f (C $color ""), $barFilled, (C $pal.muted ""), $barEmpty, $pctClamped)
}

function Colorize-LogLine {
    param([string]$line, [int]$maxLen = 110)
    if (-not $line) { return "" }
    $clean = $line.Trim() -replace "\x1b\[[0-9;]*m", ""
    if ($clean.Length -gt $maxLen) { $clean = $clean.Substring(0, $maxLen) + "..." }

    if ($clean -match '\[OK\]|\[DONE\]|\[SUCCESS\]|100\.0%') {
        return ("   " + (C $pal.success "$symOk $clean"))
    } elseif ($clean -match '\[!\]|\[WARNING\]|\[WAIT\]|retry|fallback') {
        return ("   " + (C $pal.warning "$symWarn $clean"))
    } elseif ($clean -match '\[ERROR\]|\[FATAL\]|FAILED|die') {
        return ("   " + (C $pal.error "$symErr $clean"))
    } elseif ($clean -match 'Extracting|Servicing|Compiling|Flashing|Robocopy|Converting|Removing') {
        return ("   " + (C $pal.mag "$symMag $clean"))
    } elseif ($clean -match '\[\*\]|\[INFO\]|Stage|Building') {
        return ("   " + (C $pal.cyan "$symInfo $clean"))
    } else {
        return ("   " + (C $pal.fg "> $clean"))
    }
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
# 3. Main Fast Non-Blocking Live Refresh Loop (0ms Drive Measurement)
# -----------------------------------------------------------------------------
while ($true) {
    $spinIdx = ($spinIdx + 1) % $spin.Count
    $curSpin = $spin[$spinIdx]

    # Fast Instant USB D: Space Query via System.IO.DriveInfo (0ms)
    $usbMB = 0.0
    if (Test-Path "D:\") {
        try {
            $dInfo = New-Object System.IO.DriveInfo('D')
            if ($dInfo.IsReady) {
                $usbMB = [math]::Round(($dInfo.TotalSize - $dInfo.AvailableFreeSpace) / 1MB, 1)
            }
        } catch {}
    }

    # Fast Instant SSD M: Space Query via System.IO.DriveInfo (0ms)
    $stageMB = 0.0
    if (Test-Path "M:\") {
        try {
            $mInfo = New-Object System.IO.DriveInfo('M')
            if ($mInfo.IsReady) {
                $stageMB = [math]::Round(($mInfo.TotalSize - $mInfo.AvailableFreeSpace) / 1MB, 1)
            }
        } catch {}
    }

    # Resolve SINGLE LATEST active installer log file
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
            $fs = [System.IO.File]::Open($chosenLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $out = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
            $allLines = $out -split "`r?`n"
        } catch {}
    }

    # Slice log lines after the LAST run start marker
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

    # Stream active DISM log if modified recently
    $dismLogPath = 'C:\Windows\Logs\DISM\dism.log'
    $dismLines = @()
    if (Test-Path $dismLogPath) {
        $dismItem = Get-Item $dismLogPath
        if ($dismItem.LastWriteTime -ge (Get-Date).AddMinutes(-10)) {
            try {
                $fs = [System.IO.File]::Open($dismLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $sr = New-Object System.IO.StreamReader($fs)
                $dAll = ($sr.ReadToEnd() -split "`r?`n")
                $sr.Close(); $fs.Close()
                $dismLines = $dAll | Where-Object { $_ -match 'DISM Package Manager|Processing|Image|Mounting|Unmounting' } | Select-Object -Last 4
            } catch {}
        }
    }

    # Inspect active running subprocesses safely
    $activeProcs = @()
    $totalRamMB = 0.0
    foreach ($procName in @('7z', '7za', 'robocopy', 'dism', 'curl', 'aria2c', 'wimlib-imagex')) {
        try {
            $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
            foreach ($p in $procs) {
                if ($p -and -not $p.HasExited) {
                    $ram = [math]::Round(($p.WorkingSet64 / 1MB), 1)
                    $totalRamMB += $ram
                    $activeProcs += [pscustomobject]@{ Name = $p.ProcessName; Id = $p.Id; Ram = "${ram}MB" }
                }
            }
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
        elseif ($line -match "Extracting Mini_Windows WIM|Servicing Mini_Windows|Mounting") { $currentStageId = 3; $subTaskName = "Localhost DISM servicing of MiOS_PE.wim..." }
        elseif ($line -match "Exporting and compressing Localhost|trim_path") { $currentStageId = 4; $subTaskName = "Compressing MiOS_PE.wim with /Compress:max..." }
        elseif ($line -match "Compiling MiOS-Xbox|autounattend|New-MiOSISO|Removing 44 capabilities|Mounting install image") { $currentStageId = 5; $subTaskName = "Compiling MiOS-Xbox Installer ISO..." }
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
            if ($cleanAlert.Length -gt 100) { $cleanAlert = $cleanAlert.Substring(0, 100) + "..." }
            if ($alerts -notcontains $cleanAlert) { $alerts += $cleanAlert }
        }
    }

    # Fine-tune task description from the last active log line
    $lastLogLine = $allLines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[\=\-\#]+\s*$' } | Select-Object -Last 1
    if ($lastLogLine) {
        $cleanTask = $lastLogLine.Trim() -replace "\x1b\[[0-9;]*m", ""
        if ($cleanTask.Length -gt 90) { $cleanTask = $cleanTask.Substring(0, 90) + "..." }
        $subTaskName = "$curSpin $cleanTask"
    }

    $stg = $stages | Where-Object Id -eq $currentStageId | Select-Object -First 1
    $range = $stg.MaxPct - $stg.MinPct
    $calcPct = $stg.MinPct + ($range * ($subTaskPct / 100.0))
    if ($calcPct -gt $lastOverallPct) { $lastOverallPct = $calcPct }
    if ($currentStageId -eq 10 -and $subTaskPct -eq 100.0) { $lastOverallPct = 100.0 }

    # Combine multi-source live log lines for 10-line streaming tail
    $combinedTail = @()
    $combinedTail += ($allLines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[\=\-\#]+\s*$' } | Select-Object -Last 8)
    if ($dismLines) { $combinedTail += ($dismLines | ForEach-Object { "[DISM] $_" }) }
    $recentTail = $combinedTail | Select-Object -Last 10

    # -----------------------------------------------------------------------------
    # 4. Render SSOT-Themed Graphical Dashboard (120 Cols x 42 Rows)
    # -----------------------------------------------------------------------------
    Clear-Host
    $topLine   = [string]$cBoxTL + ([string]$cBoxHoriz * 118) + [string]$cBoxTR
    $divLine   = [string]$cBoxLDivider + ([string]$cBoxHoriz * 118) + [string]$cBoxRDivider
    $botLine   = [string]$cBoxBL + ([string]$cBoxHoriz * 118) + [string]$cBoxBR
    $v = [string]$cBoxVert

    Write-Host (C $pal.accent $topLine)
    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.warning "                 M i O S   v$ssotVersion   --   S S O T   L I V E   F L A S H   M O N I T O R                ") -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.muted ("                 " + $ssotTagline.PadRight(80))) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent $divLine)

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.subtle "  SSOT Config : ") -NoNewline
    Write-Host (C $pal.fg $TomlPath.PadRight(98)) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.subtle "  Target USB  : ") -NoNewline
    Write-Host (C $pal.fg ("D:\ (Used Space: $usbMB MB)".PadRight(98))) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.subtle "  SSD Stage   : ") -NoNewline
    Write-Host (C $pal.fg ("M:\ (SSD Volume Used: $stageMB MB)".PadRight(98))) -NoNewline
    Write-Host (C $pal.accent " $v")

    $procStr = if ($activeProcs.Count) { ($activeProcs | ForEach-Object { "$($_.Name)[PID:$($_.Id) RAM:$($_.Ram)]" }) -join ' ' } else { "Idle / Waiting for Subprocess Dispatch" }
    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.subtle "  Subprocesses: ") -NoNewline
    Write-Host (C $pal.cyan ("$procStr (Total RAM: ${totalRamMB} MB)".PadRight(98))) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent $divLine)

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.accent "  ACTIVE STAGE  ") -NoNewline
    Write-Host (C $pal.fg " Stage $currentStageId of 10 : ") -NoNewline
    Write-Host (C $pal.warning ($stg.Name.PadRight(80))) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.accent "  CURRENT TASK  ") -NoNewline
    Write-Host (C $pal.fg ($subTaskName.PadRight(98))) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host ("                                                                                                                          ") -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host ("  Overall Progress : " + (Format-ProgressBar -pct $lastOverallPct -width 65)) -NoNewline
    Write-Host (C $pal.accent "           $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host ("  Sub-Task Progress: " + (Format-ProgressBar -pct $subTaskPct -width 65)) -NoNewline
    Write-Host (C $pal.accent "           $v")

    Write-Host (C $pal.accent $divLine)

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (B " PIPELINE STAGES STATUS:                                                                                                ") -NoNewline
    Write-Host (C $pal.accent " $v")

    for ($s = 1; $s -le 10; $s += 2) {
        $stg1 = $stages | Where-Object Id -eq $s
        $stg2 = $stages | Where-Object Id -eq ($s + 1)

        $b1 = if ($s -lt $currentStageId) { (C $pal.success "[ DONE ]") } elseif ($s -eq $currentStageId) { (C $pal.warning "[$curSpin RUN ]") } else { (C $pal.muted "[QUEUED ]") }
        $b2 = if (($s + 1) -lt $currentStageId) { (C $pal.success "[ DONE ]") } elseif (($s + 1) -eq $currentStageId) { (C $pal.warning "[$curSpin RUN ]") } else { (C $pal.muted "[QUEUED ]") }

        $str1 = (" {0} Stg {1:D2}: {2}" -f $b1, $s, $stg1.Name.PadRight(35))
        $str2 = (" {0} Stg {1:D2}: {2}" -f $b2, ($s + 1), $stg2.Name.PadRight(35))
        
        Write-Host (C $pal.accent "$v ") -NoNewline
        Write-Host ("  $str1  $cBoxPipe  $str2                                ") -NoNewline
        Write-Host (C $pal.accent " $v")
    }

    Write-Host (C $pal.accent $divLine)

    if ($alerts.Count -gt 0) {
        Write-Host (C $pal.accent "$v ") -NoNewline
        Write-Host (C $pal.warning " ALERTS AND WARNINGS ($($alerts.Count)):                                                                                    ") -NoNewline
        Write-Host (C $pal.accent " $v")
        foreach ($alt in ($alerts | Select-Object -Last 2)) {
            Write-Host (C $pal.accent "$v ") -NoNewline
            Write-Host (C $pal.warning ("   ! " + $alt.PadRight(110))) -NoNewline
            Write-Host (C $pal.accent " $v")
        }
        Write-Host (C $pal.accent $divLine)
    }

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (B " LIVE MULTI-SOURCE LOG STREAM:                                                                                          ") -NoNewline
    Write-Host (C $pal.accent " $v")

    if ($recentTail) {
        foreach ($tLine in $recentTail) {
            $formattedLine = Colorize-LogLine -line $tLine -maxLen 110
            Write-Host (C $pal.accent "$v ") -NoNewline
            Write-Host ($formattedLine.PadRight(118)) -NoNewline
            Write-Host (C $pal.accent " $v")
        }
    } else {
        Write-Host (C $pal.accent "$v ") -NoNewline
        Write-Host (C $pal.muted "   > Monitoring active build pipeline live...                                                                          ") -NoNewline
        Write-Host (C $pal.accent " $v")
    }

    Write-Host (C $pal.accent $botLine)

    if ($lastOverallPct -ge 100.0) {
        Write-Host ("`n  " + (C $pal.success "[AIO SUCCESS] Build and Flash Complete! You can close this monitor.") + "`n")
        break
    }

    Start-Sleep -Milliseconds 500
}
