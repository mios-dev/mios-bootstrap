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
# 1. Fullscreen Window Maximization & VT Activation (Kernel32 & User32 P/Invoke)
# -----------------------------------------------------------------------------
$script:NoColor = $false
try {
    if (-not ($env:MIOS_NO_COLOR -or $env:NO_COLOR)) {
        $vtSig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);' +
                 '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);' +
                 '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
        $k = Add-Type -MemberDefinition $vtSig -Name 'MiosVtMonMax3' -Namespace 'MiosCat' -PassThru -ErrorAction Stop
        $h = $k::GetStdHandle(-11); $m = 0
        if ($k::GetConsoleMode($h, [ref]$m)) { [void]$k::SetConsoleMode($h, ($m -bor 0x0004)) }
    }
} catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Force Console Window to MAXIMIZE (SW_MAXIMIZE = 3)
try {
    $user32Sig = '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
    $u32 = Add-Type -MemberDefinition $user32Sig -Name 'MiosMaxWin3' -Namespace 'MiosCat' -PassThru -ErrorAction Stop
    $hwnd = (Get-Process -Id $PID).MainWindowHandle
    if ($hwnd -ne [IntPtr]::Zero) {
        $u32::ShowWindow($hwnd, 3) | Out-Null
    }
} catch {}

# Hide cursor to prevent flicker
try { [Console]::CursorVisible = $false } catch {}

# Stretch Console Window & Buffer to Maximum Screen Dimensions
try {
    $maxW = [Console]::LargestWindowWidth
    $maxH = [Console]::LargestWindowHeight
    if ($maxW -gt 80 -and $maxH -gt 30) {
        $rawUI = $host.UI.RawUI
        $rawUI.BufferSize = New-Object System.Management.Automation.Host.Size($maxW, $maxH)
        $rawUI.WindowSize = New-Object System.Management.Automation.Host.Size($maxW, $maxH)
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
    param([double]$pct, [int]$width = 80)
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
    param([string]$line, [int]$maxLen = 160)
    if (-not $line) { return "" }
    $clean = $line.Trim() -replace "\x1b\[[0-9;]*m", ""
    if ($clean.Length -gt $maxLen) { $clean = $clean.Substring(0, $maxLen) + "..." }

    if ($clean -match '\[OK\]|\[DONE\]|\[SUCCESS\]|100\.0%') {
        return ("   " + (C $pal.success "$symOk $clean"))
    } elseif ($clean -match '\[!\]|\[WARNING\]|\[WAIT\]|retry|fallback') {
        return ("   " + (C $pal.warning "$symWarn $clean"))
    } elseif ($clean -match '\[ERROR\]|\[FATAL\]|FAILED|die') {
        return ("   " + (C $pal.error "$symErr $clean"))
    } elseif ($clean -match 'Extracting|Servicing|Compiling|Flashing|Robocopy|Converting|Removing|Disabling|Baking|staged|wallpaper|SetupComplete|virtio|dism') {
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
Clear-Host

# -----------------------------------------------------------------------------
# 3. Main Dynamic Fullscreen Live Refresh Loop (Zero-Scroll Cursor Position)
# -----------------------------------------------------------------------------
while ($true) {
    # Set Cursor Position to Top-Left (0, 0) instead of Clear-Host to prevent viewport scroll
    try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }

    $spinIdx = ($spinIdx + 1) % $spin.Count
    $curSpin = $spin[$spinIdx]

    # Dynamically detect current screen dimensions
    $winW = [math]::Max(120, $host.UI.RawUI.WindowSize.Width)
    $winH = [math]::Max(40, $host.UI.RawUI.WindowSize.Height)
    $innerWidth = $winW - 4

    # Keep Buffer Size matched to Window Size so scrolling CANNOT occur
    try {
        if ($host.UI.RawUI.BufferSize.Width -ne $winW -or $host.UI.RawUI.BufferSize.Height -ne $winH) {
            $host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($winW, $winH)
        }
    } catch {}

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

    # Resolve Active Log File: Prioritize Large Active Task Logs Over 73-byte Stub Files
    $taskLogs = Get-ChildItem -Path "C:\Users\Administrator\.gemini\antigravity-ide\brain\dba6616d-053d-43cd-b86d-a98f223952b8\.system_generated\tasks\task-*.log" -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 500 } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -ExpandProperty FullName

    $chosenLog = if ($taskLogs -and $taskLogs.Count) { $taskLogs[0] } else { 'C:\Windows\Temp\mios-cat-install.log' }

    $allLines = @()
    if ($chosenLog -and (Test-Path $chosenLog)) {
        try {
            $fs = [System.IO.File]::Open($chosenLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $out = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
            $allLines = $out -split "`r?`n"
        } catch {}
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
    $isDismRunning = $false
    foreach ($procName in @('7z', '7za', 'robocopy', 'dism', 'curl', 'aria2c', 'wimlib-imagex')) {
        try {
            $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
            foreach ($p in $procs) {
                if ($p -and -not $p.HasExited) {
                    $ram = [math]::Round(($p.WorkingSet64 / 1MB), 1)
                    $totalRamMB += $ram
                    $activeProcs += [pscustomobject]@{ Name = $p.ProcessName; Id = $p.Id; Ram = "${ram}MB" }
                    if ($procName -eq 'dism') { $isDismRunning = $true }
                }
            }
        } catch {}
    }

    # Global Pipeline Stage Determination
    $currentStageId = 1
    $subTaskPct = 0.0
    $subTaskName = "Initializing preflight checks & environment..."
    $alerts = @()

    foreach ($line in $allLines) {
        if (-not $line) { continue }
        if ($line -match "RUNNING PREFLIGHT CHECKS") { $currentStageId = [math]::Max($currentStageId, 1); $subTaskName = "Preflight safety checks verified..." }
        if ($line -match "PHASE 1: ALL-IN-ONE|Core Medicat archive|Downloading|Pulling") { $currentStageId = [math]::Max($currentStageId, 2); $subTaskName = "Extracting/staging core archives to SSD..." }
        if ($line -match "Extracting Mini_Windows WIM|Servicing Mini_Windows|Mounting.*boot\.wim") { $currentStageId = [math]::Max($currentStageId, 3); $subTaskName = "Localhost DISM servicing of MiOS_PE.wim..." }
        if ($line -match "Exporting and compressing Localhost|trim_path|Rebuilding boot\.wim") { $currentStageId = [math]::Max($currentStageId, 4); $subTaskName = "Compressing MiOS_PE.wim with /Compress:max..." }
        if ($line -match "Compiling MiOS-Xbox|autounattend|New-MiOSISO|Removing.*capabilities|Disabling|Mounting.*26100|Stock ISO|oscdimg|Baking|wallpaper|SetupComplete|virtio|Dismount -Save") { $currentStageId = [math]::Max($currentStageId, 5); $subTaskName = "Compiling MiOS-Xbox Installer ISO..." }
        if ($line -match "Writing MiOS-PE|Writing Documents|PortableApps") { $currentStageId = [math]::Max($currentStageId, 6); $subTaskName = "Staging dedicated MiOS-PE & Documents folders..." }
        if ($line -match "SINGLE FLASH PASS|Zero USB writes") { $currentStageId = [math]::Max($currentStageId, 7); $subTaskName = "Fail-fast verification passed. Starting flash..." }
        if ($line -match "Ventoy|autorun\.inf") { $currentStageId = [math]::Max($currentStageId, 8); $subTaskName = "Applying Ventoy tree menu & theme configuration..." }
        if ($line -match "Writing PortableApps suite|robocopy .* D:") { $currentStageId = [math]::Max($currentStageId, 9); $subTaskName = "Robocopy 32-thread write to USB drive D:..." }
        if ($line -match "MiOS-Cat DEDICATED USB INSTALLATION COMPLETED|AIO SUCCESS") { $currentStageId = 10; $subTaskPct = 100.0; $subTaskName = "Build & flash completed successfully!" }

        if ($line -match '(\d+\.\d+)%') {
            $val = [double]$Matches[1]
            if ($val -le 100.0) { $subTaskPct = $val }
        }

        if ($line -match '\[!\]|\[WARNING\]|\[FATAL ERROR\]|ERROR') {
            $cleanAlert = $line -replace '\s+', ' '
            if ($cleanAlert.Length -gt ($innerWidth - 10)) { $cleanAlert = $cleanAlert.Substring(0, ($innerWidth - 10)) + "..." }
            if ($alerts -notcontains $cleanAlert) { $alerts += $cleanAlert }
        }
    }

    # If DISM is running or log shows image servicing, enforce Stage 5 minimum
    if ($isDismRunning -or ($allLines -match 'virtio|Dismount -Save|Baking|wallpaper|SetupComplete')) {
        $currentStageId = [math]::Max($currentStageId, 5)
    }

    # Display the latest active log line as the current subtask
    $lastLogLine = $allLines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[\=\-\#]+\s*$' } | Select-Object -Last 1
    if ($lastLogLine) {
        $cleanTask = $lastLogLine.Trim() -replace "\x1b\[[0-9;]*m", ""
        if ($cleanTask.Length -gt ($innerWidth - 20)) { $cleanTask = $cleanTask.Substring(0, ($innerWidth - 20)) + "..." }
        $subTaskName = "$curSpin $cleanTask"
    }

    $stg = $stages | Where-Object Id -eq $currentStageId | Select-Object -First 1
    $range = $stg.MaxPct - $stg.MinPct
    $calcPct = $stg.MinPct + ($range * ($subTaskPct / 100.0))
    if ($calcPct -gt $lastOverallPct) { $lastOverallPct = $calcPct }
    if ($currentStageId -eq 10 -and $subTaskPct -eq 100.0) { $lastOverallPct = 100.0 }

    # Calculate exact available height for streaming log lines (28 lines fixed layout)
    $maxLogLines = [math]::Max(4, $winH - 28)
    $combinedTail = @()
    $combinedTail += ($allLines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[\=\-\#]+\s*$' } | Select-Object -Last ($maxLogLines - 2))
    if ($dismLines) { $combinedTail += ($dismLines | ForEach-Object { "[DISM] $_" }) }
    $recentTail = $combinedTail | Select-Object -Last $maxLogLines

    # -----------------------------------------------------------------------------
    # 4. Render FULLSCREEN SSOT-Themed Graphical Dashboard (Zero-Scroll Safe)
    # -----------------------------------------------------------------------------
    $topLine   = [string]$cBoxTL + ([string]$cBoxHoriz * ($innerWidth + 2)) + [string]$cBoxTR
    $divLine   = [string]$cBoxLDivider + ([string]$cBoxHoriz * ($innerWidth + 2)) + [string]$cBoxRDivider
    $botLine   = [string]$cBoxBL + ([string]$cBoxHoriz * ($innerWidth + 2)) + [string]$cBoxBR
    $v = [string]$cBoxVert

    $hdrTitle = "M i O S   v$ssotVersion   --   S S O T   L I V E   F L A S H   M O N I T O R"
    $hdrPad = [math]::Max(0, [int](($innerWidth - $hdrTitle.Length) / 2))

    Write-Host (C $pal.accent $topLine)
    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.warning ((" " * $hdrPad) + $hdrTitle.PadRight($innerWidth - $hdrPad))) -NoNewline
    Write-Host (C $pal.accent " $v")

    $subTitlePad = [math]::Max(0, [int](($innerWidth - $ssotTagline.Length) / 2))
    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.muted ((" " * $subTitlePad) + $ssotTagline.PadRight($innerWidth - $subTitlePad))) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent $divLine)

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.subtle "  SSOT Config : ") -NoNewline
    Write-Host (C $pal.fg $TomlPath.PadRight($innerWidth - 16)) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.subtle "  Target USB  : ") -NoNewline
    Write-Host (C $pal.fg ("D:\ (Used Space: $usbMB MB)".PadRight($innerWidth - 16))) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.subtle "  SSD Stage   : ") -NoNewline
    Write-Host (C $pal.fg ("M:\ (SSD Volume Used: $stageMB MB)".PadRight($innerWidth - 16))) -NoNewline
    Write-Host (C $pal.accent " $v")

    $procStr = if ($activeProcs.Count) { ($activeProcs | ForEach-Object { "$($_.Name)[PID:$($_.Id) RAM:$($_.Ram)]" }) -join ' ' } else { "Idle / Waiting for Subprocess Dispatch" }
    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.subtle "  Subprocesses: ") -NoNewline
    Write-Host (C $pal.cyan ("$procStr (Total RAM: ${totalRamMB} MB)".PadRight($innerWidth - 16))) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent $divLine)

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.accent "  ACTIVE STAGE  ") -NoNewline
    Write-Host (C $pal.fg " Stage $currentStageId of 10 : ") -NoNewline
    Write-Host (C $pal.warning ($stg.Name.PadRight($innerWidth - 32))) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (C $pal.accent "  CURRENT TASK  ") -NoNewline
    Write-Host (C $pal.fg ($subTaskName.PadRight($innerWidth - 16))) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host ((" " * $innerWidth)) -NoNewline
    Write-Host (C $pal.accent " $v")

    $barWidth = [math]::Min(100, $innerWidth - 30)
    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (("  Overall Progress : " + (Format-ProgressBar -pct $lastOverallPct -width $barWidth)).PadRight($innerWidth)) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (("  Sub-Task Progress: " + (Format-ProgressBar -pct $subTaskPct -width $barWidth)).PadRight($innerWidth)) -NoNewline
    Write-Host (C $pal.accent " $v")

    Write-Host (C $pal.accent $divLine)

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (B (" PIPELINE STAGES STATUS:".PadRight($innerWidth))) -NoNewline
    Write-Host (C $pal.accent " $v")

    $colW = [int](($innerWidth - 10) / 2)
    for ($s = 1; $s -le 10; $s += 2) {
        $stg1 = $stages | Where-Object Id -eq $s
        $stg2 = $stages | Where-Object Id -eq ($s + 1)

        $b1 = if ($s -lt $currentStageId) { (C $pal.success "[ DONE ]") } elseif ($s -eq $currentStageId) { (C $pal.warning "[$curSpin RUN ]") } else { (C $pal.muted "[QUEUED ]") }
        $b2 = if (($s + 1) -lt $currentStageId) { (C $pal.success "[ DONE ]") } elseif (($s + 1) -eq $currentStageId) { (C $pal.warning "[$curSpin RUN ]") } else { (C $pal.muted "[QUEUED ]") }

        $str1 = (" {0} Stg {1:D2}: {2}" -f $b1, $s, $stg1.Name.PadRight($colW - 14))
        $str2 = (" {0} Stg {1:D2}: {2}" -f $b2, ($s + 1), $stg2.Name.PadRight($colW - 14))
        
        Write-Host (C $pal.accent "$v ") -NoNewline
        Write-Host (("  $str1  $cBoxPipe  $str2").PadRight($innerWidth)) -NoNewline
        Write-Host (C $pal.accent " $v")
    }

    Write-Host (C $pal.accent $divLine)

    if ($alerts.Count -gt 0) {
        Write-Host (C $pal.accent "$v ") -NoNewline
        Write-Host (C $pal.warning ((" ALERTS AND WARNINGS (" + $alerts.Count + "):").PadRight($innerWidth))) -NoNewline
        Write-Host (C $pal.accent " $v")
        foreach ($alt in ($alerts | Select-Object -Last 2)) {
            Write-Host (C $pal.accent "$v ") -NoNewline
            Write-Host (C $pal.warning ("   ! " + $alt.PadRight($innerWidth - 5))) -NoNewline
            Write-Host (C $pal.accent " $v")
        }
        Write-Host (C $pal.accent $divLine)
    }

    Write-Host (C $pal.accent "$v ") -NoNewline
    Write-Host (B (" LIVE MULTI-SOURCE LOG STREAM:".PadRight($innerWidth))) -NoNewline
    Write-Host (C $pal.accent " $v")

    if ($recentTail) {
        foreach ($tLine in $recentTail) {
            $formattedLine = Colorize-LogLine -line $tLine -maxLen ($innerWidth - 10)
            Write-Host (C $pal.accent "$v ") -NoNewline
            Write-Host ($formattedLine.PadRight($innerWidth)) -NoNewline
            Write-Host (C $pal.accent " $v")
        }
    } else {
        Write-Host (C $pal.accent "$v ") -NoNewline
        Write-Host (C $pal.muted ("   > Monitoring active build pipeline live...".PadRight($innerWidth))) -NoNewline
        Write-Host (C $pal.accent " $v")
    }

    Write-Host (C $pal.accent $botLine) -NoNewline

    if ($lastOverallPct -ge 100.0) {
        Write-Host ("`n  " + (C $pal.success "[AIO SUCCESS] Build and Flash Complete! You can close this monitor.") + "`n")
        break
    }

    Start-Sleep -Milliseconds 500
}
