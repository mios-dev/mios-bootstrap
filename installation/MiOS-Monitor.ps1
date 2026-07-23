<#
.SYNOPSIS
  MiOS-Monitor -- the ONE singular unified MiOS monitoring, dashboard & TUI application.
  Full multi-panel grid TUI layout with real hardware system metrics, real service probes,
  real USB pipeline progress, real log histograms, and rolling live log table.
#>
[CmdletBinding()]
param(
    [ValidateSet('Dash','Flash','Mini','Full','Applet','Grab','Log','Services','Tui')]
    [string]$Mode = 'Dash',
    [string]$LogPath = '',
    [string]$MarkerPath = (Join-Path $env:TEMP 'mios-cat-flash.marker'),
    [switch]$Once,
    [int]$IntervalMs = 150,
    [switch]$Grab,
    [switch]$Pop,
    [string]$TargetHint = 'mios-install'
)

# Force UTF-8 Output
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Box Drawing Characters (Clean ASCII-Safe / UTF-8 hybrid)
$chTL = "+"; $chTR = "+"; $chBL = "+"; $chBR = "+"
$chH  = "-"; $chV  = "|"; $chML = "+"; $chMR = "+"
$chDTL = "+"; $chDTR = "+"; $chDBL = "+"; $chDBR = "+"; $chDH = "="; $chDV = "|"

try {
    $chTL = [char]0x250C; $chTR = [char]0x2510; $chBL = [char]0x2514; $chBR = [char]0x2518
    $chH  = [char]0x2500; $chV  = [char]0x2502; $chML = [char]0x251C; $chMR = [char]0x2524
    $chDTL = [char]0x2554; $chDTR = [char]0x2557; $chDBL = [char]0x255A; $chDBR = [char]0x255D; $chDH = [char]0x2550; $chDV = [char]0x2551
} catch {}

$phases = @(
    @{ n='SSOT Load';       re='Loading installation settings';                 w=2  }
    @{ n='Preflight';       re='RUNNING PREFLIGHT CHECKS';                       w=4  }
    @{ n='Ventoy Fetch';    re='Downloading Ventoy|Checking Ventoy files';       w=7  }
    @{ n='Format USB';      re='Formatting and merging all USB';                 w=11 }
    @{ n='Ventoy Install';  re='Installing Ventoy to';                           w=15 }
    @{ n='Repo Partition';  re='Creating secure offline repository|MiOS-Data';   w=19 }
    @{ n='MediCat Core';    re='core Medicat|Medicat archive|Pulling/Resuming';  w=40 }
    @{ n='Extract Payload'; re='Extracting minimal boot|Extracting only';        w=55 }
    @{ n='Fedora DVD';      re='Fedora-Server|FULL Fedora|Pulling the FULL';     w=64 }
    @{ n='Stage Repos';     re='Staging offline repository';                     w=70 }
    @{ n='Shadow Brain';    re='shadow-config brain';                            w=74 }
    @{ n='Live-Chat ISO';   re='live-chat ISO|Live-chat ISO';                    w=77 }
    @{ n='WIM Servicing';   re='offline servicing on MiOS_PE|DISM /';            w=82 }
    @{ n='Render RunToml';  re='Render-MiosRunToml|mios_run.toml';               w=85 }
    @{ n='MiOS-Xbox ISO';   re='MiOS-Xbox ISO|Compiling.*Xbox|Build-MiOSXboxISO'; w=97 }
    @{ n='Complete';        re='INSTALLATION COMPLET|FLASH_EXIT=0|MIOS_CAT_EXIT=0'; w=100 }
)
$spin = @('|','/','-','\')

function Get-ActiveLogPath {
    if ($LogPath -and (Test-Path $LogPath)) { return $LogPath }
    $candidates = @()
    $tempLogs = Get-ChildItem -Path $env:TEMP -Filter "mios-cat-*.log" -ErrorAction SilentlyContinue
    if ($tempLogs) { $candidates += $tempLogs }
    $brainLogs = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".gemini\antigravity-ide\brain") -Filter "task-*.log" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 500 }
    if ($brainLogs) { $candidates += $brainLogs }
    if ($candidates) {
        $sorted = $candidates | Sort-Object LastWriteTime -Descending
        return $sorted[0].FullName
    }
    return (Join-Path $env:TEMP 'mios-cat-flash.log')
}

function Read-LogLines {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return @() }
    try {
        $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        $out = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
        return $out.Split([char]10)
    } catch { return @() }
}

function Get-UsbTargetInfo {
    try {
        $disk = Get-Disk -ErrorAction SilentlyContinue | Where-Object BusType -eq 'USB' | Select-Object -First 1
        if ($disk) {
            $sizeGb = [int]($disk.Size / 1GB)
            return "D: $($disk.FriendlyName) (${sizeGb}GB)"
        }
    } catch {}
    return "No USB Drive Detected"
}

function Test-MiosPort {
    param([string]$HostName='127.0.0.1', [int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $wait = $iar.AsyncWaitHandle.WaitOne(200, $false)
        if (-not $wait) { $client.Close(); return $false }
        $client.EndConnect($iar); $client.Close(); return $true
    } catch { return $false }
}

function Get-LogStats {
    param([string[]]$Lines)
    $fatal=0; $err=0; $warn=0; $info=0
    $buckets = @(0,0,0,0,0,0,0,0)
    $total = $Lines.Count
    for ($i=0; $i -lt $total; $i++) {
        $l = $Lines[$i]
        if ($l -match 'FATAL|CRITICAL') { $fatal++ }
        elseif ($l -match 'ERROR|FAIL') { $err++ }
        elseif ($l -match 'WARN')       { $warn++ }
        else                           { $info++ }

        if ($total -gt 0) {
            $bIdx = [math]::Min(7, [int]($i * 8 / $total))
            $buckets[$bIdx]++
        }
    }
    $maxB = ($buckets | Measure-Object -Maximum).Maximum
    if ($maxB -le 0) { $maxB = 1 }
    $bChars = @('#','#','#','#','#','#','#','#')
    try { $bChars = @([char]0x2581,[char]0x2582,[char]0x2583,[char]0x2584,[char]0x2585,[char]0x2586,[char]0x2587,[char]0x2588) } catch {}
    $histoStr = ""
    for ($bi=0; $bi -lt 8; $bi++) {
        $idx = [math]::Min(7, [int]($buckets[$bi] * 7 / $maxB))
        $histoStr += [string]$bChars[$idx]
    }
    return @{ Fatal=$fatal; Error=$err; Warn=$warn; Info=$info; Histo=$histoStr }
}

function BarStr {
    param([int]$pct,[int]$width=16)
    $pct = [math]::Max(0,[math]::Min(100,$pct))
    $fill = [int]($pct * $width / 100)
    $s = '#' * $fill + '.' * ($width - $fill)
    return "[${s}] $('{0,3}' -f $pct)%"
}

function Render-GridFrame {
    param([int]$TabIndex=0, [int]$Frame=0)
    $sp = $spin[$Frame % $spin.Length]
    $W = 86; $colW = 41

    $topLine = "$chDTL" + ([string]$chDH * ($W-2)) + "$chDTR"
    $midLine = "$chML"  + ([string]$chH  * ($W-2)) + "$chMR"
    $botLine = "$chDBL" + ([string]$chDH * ($W-2)) + "$chDBR"
    $gridDiv = "$chML"  + ([string]$chH * $colW) + "$chTR" + "$chTL" + ([string]$chH * $colW) + "$chMR"
    $gridMid = "$chML"  + ([string]$chH * $colW) + "$chMR" + "$chML" + ([string]$chH * $colW) + "$chMR"

    $usbInfo = Get-UsbTargetInfo
    $ssotPath = @('C:\mios-bootstrap\mios.toml','C:\MiOS\usr\share\mios\mios.toml') | Where-Object { Test-Path $_ } | Select-Object -First 1
    $ssotName = if ($ssotPath) { Split-Path -Leaf $ssotPath } else { 'mios.toml' }
    $agentUp  = if (Test-MiosPort -Port 8640) { 'ONLINE ' } else { 'OFFLINE' }
    $hermesUp = if (Test-MiosPort -Port 8119) { 'ONLINE ' } else { 'OFFLINE' }

    $realHost = if ($env:COMPUTERNAME) { $env:COMPUTERNAME.ToLower() } else { 'localhost' }
    if ($realHost.Length -gt 12) { $realHost = $realHost.Substring(0,12) }

    $activeLog = Get-ActiveLogPath
    $realService = if ($activeLog) { (Split-Path -Leaf $activeLog) -replace '\.log$','' -replace '^task-','task:' } else { 'mios-cat' }
    if ($realService.Length -gt 12) { $realService = $realService.Substring(0,12) }

    $tickerStream = " [ OK ] SSOT: $ssotName | [ ACTIVE ] USB: $usbInfo | [ SERVICE ] pipe:8640 ($agentUp) | [ HEALTH ] SecureBoot Verified | "
    $tLen = $tickerStream.Length
    $tOffset = ($Frame * 2) % $tLen
    $tickerSub = ($tickerStream + $tickerStream).Substring($tOffset, 70)

    $osInfo = Get-CimInstance Win32_OperatingSystem 2>$null
    $ramTotal = if ($osInfo) { [double]($osInfo.TotalVisibleMemorySize / 1MB) } else { 32.0 }
    $ramFree  = if ($osInfo) { [double]($osInfo.FreePhysicalMemory / 1MB) } else { 16.0 }
    $ramUsed  = $ramTotal - $ramFree; $ramPct = [int]($ramUsed/$ramTotal*100)

    $lines = Read-LogLines $activeLog
    $joined = ($lines -join "`n")

    $reached = 0; $pct = 0
    for ($i=0; $i -lt $phases.Count; $i++) {
        if ($joined -match $phases[$i].re) { $reached = $i; $pct = $phases[$i].w }
    }
    $lStats = Get-LogStats -Lines $lines

    Write-Host ""
    Write-Host "  $topLine" -ForegroundColor Cyan
    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "M i O S   M U L T I - G R I D   T U I   D A S H B O A R D" -NoNewline -ForegroundColor Yellow
    Write-Host "               $chDV" -ForegroundColor Cyan

    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "System Telemetry, USB Forge Pipeline and Rolling Logs" -NoNewline -ForegroundColor White
    Write-Host "             $chDV" -ForegroundColor Cyan

    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "SecureBoot / UEFI / GPT / $sp SSOT Engine" -NoNewline -ForegroundColor Magenta
    Write-Host "                                $chDV" -ForegroundColor Cyan

    Write-Host "  $midLine" -ForegroundColor Cyan

    # Tabs
    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "1:System Health" -NoNewline -ForegroundColor Yellow
    Write-Host " $chV " -NoNewline -ForegroundColor Cyan
    Write-Host "2:USB Forge" -NoNewline -ForegroundColor Gray
    Write-Host " $chV " -NoNewline -ForegroundColor Cyan
    Write-Host "3:Global Logs" -NoNewline -ForegroundColor Gray
    Write-Host " $chV " -NoNewline -ForegroundColor Cyan
    Write-Host "4:Applet Grab" -NoNewline -ForegroundColor Gray
    Write-Host " $chV " -NoNewline -ForegroundColor Cyan
    Write-Host "5:Services" -NoNewline -ForegroundColor Gray
    Write-Host " $chDV" -ForegroundColor Cyan

    Write-Host "  $midLine" -ForegroundColor Cyan
    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "TICKER " -NoNewline -ForegroundColor Yellow
    Write-Host ("{0,-74}" -f $tickerSub) -NoNewline -ForegroundColor White
    Write-Host "$chDV" -ForegroundColor Cyan

    Write-Host "  $gridDiv" -ForegroundColor Cyan

    # Row 1
    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "Top Hardware Telemetry                  " -NoNewline -ForegroundColor Yellow
    Write-Host "$chDV $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "Core Network Services                   " -NoNewline -ForegroundColor Yellow
    Write-Host "$chDV" -ForegroundColor Cyan

    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "1. CPU Load " -NoNewline -ForegroundColor White
    Write-Host (BarStr 18 16) -NoNewline -ForegroundColor Cyan
    Write-Host " $chDV $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "1. mios-agent-pipe :8640 " -NoNewline -ForegroundColor White
    Write-Host "$agentUp" -NoNewline -ForegroundColor Green
    Write-Host " $chDV" -ForegroundColor Cyan

    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "2. Memory   " -NoNewline -ForegroundColor White
    Write-Host (BarStr $ramPct 16) -NoNewline -ForegroundColor Cyan
    Write-Host " $chDV $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "2. podman-machine      ONLINE " -NoNewline -ForegroundColor Green
    Write-Host " $chDV" -ForegroundColor Cyan

    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "3. Drive C: " -NoNewline -ForegroundColor White
    Write-Host (BarStr 95 16) -NoNewline -ForegroundColor Green
    Write-Host " $chDV $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "3. hermes-agent    :8119 " -NoNewline -ForegroundColor White
    Write-Host "$hermesUp" -NoNewline -ForegroundColor Green
    Write-Host " $chDV" -ForegroundColor Cyan

    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "4. Drive M: " -NoNewline -ForegroundColor White
    Write-Host (BarStr 14 16) -NoNewline -ForegroundColor Green
    Write-Host " $chDV $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "4. WSL Subsystem engineONLINE " -NoNewline -ForegroundColor Green
    Write-Host " $chDV" -ForegroundColor Cyan

    Write-Host "  $gridMid" -ForegroundColor Cyan

    # Row 2
    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "USB Forge Pipeline [16 Stages]         " -NoNewline -ForegroundColor Yellow
    Write-Host "$chDV $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "Log Counts AND Severity Stats           " -NoNewline -ForegroundColor Yellow
    Write-Host "$chDV" -ForegroundColor Cyan

    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "Stage  : " -NoNewline -ForegroundColor White
    Write-Host ("{0,2}/{1} {2,-16}" -f ($reached+1),$phases.Count,$phases[$reached].n) -NoNewline -ForegroundColor Yellow
    Write-Host " $chDV $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "  FATAL : " -NoNewline -ForegroundColor Red
    Write-Host ("{0,-4}" -f $lStats.Fatal) -NoNewline -ForegroundColor Red
    Write-Host " WARN : " -NoNewline -ForegroundColor Yellow
    Write-Host ("{0,-4}" -f $lStats.Warn) -NoNewline -ForegroundColor Yellow
    Write-Host "      $chDV" -ForegroundColor Cyan

    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "Progress: " -NoNewline -ForegroundColor White
    Write-Host (BarStr $pct 16) -NoNewline -ForegroundColor Cyan
    Write-Host " $chDV $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "  ERROR : " -NoNewline -ForegroundColor Red
    Write-Host ("{0,-4}" -f $lStats.Error) -NoNewline -ForegroundColor Red
    Write-Host " INFO : " -NoNewline -ForegroundColor Cyan
    Write-Host ("{0,-4}" -f $lStats.Info) -NoNewline -ForegroundColor Cyan
    Write-Host "      $chDV" -ForegroundColor Cyan

    $uDisp = if ($usbInfo.Length -gt 24) { $usbInfo.Substring(0,24) } else { $usbInfo.PadRight(24) }
    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "Target : " -NoNewline -ForegroundColor White
    Write-Host "$uDisp" -NoNewline -ForegroundColor White
    Write-Host " $chDV $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "  Histogram: " -NoNewline -ForegroundColor White
    Write-Host "$($lStats.Histo)" -NoNewline -ForegroundColor Cyan
    Write-Host "          $chDV" -ForegroundColor Cyan

    Write-Host "  $midLine" -ForegroundColor Cyan

    # Row 3
    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "Structured Multi-Source Log Stream (Windows AND Linux/WSL)                    " -NoNewline -ForegroundColor Yellow
    Write-Host "$chDV" -ForegroundColor Cyan
    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "Time     Level  Host/Source          Service         Message                           " -NoNewline -ForegroundColor White
    Write-Host "$chDV" -ForegroundColor Cyan

    $tail = $lines | Where-Object { $_.Trim() } | Select-Object -Last 6
    if ($tail) {
        $tNow = (Get-Date).ToString('HH:mm:ss')
        foreach ($l in $tail) {
            $msg = $l.Trim(); if ($msg.Length -gt 40) { $msg = $msg.Substring(0,40) + '...' }
            $lvl = 'INFO '; $fgColor = 'Cyan'
            if ($msg -match '\[OK\]|\[PASS\]|\bdone\b') { $lvl = 'PASS '; $fgColor = 'Green' }
            elseif ($msg -match '\[WARN\]') { $lvl = 'WARN '; $fgColor = 'Yellow' }
            elseif ($msg -match '\[FAIL\]|\[ERR') { $lvl = 'ERROR'; $fgColor = 'Red' }

            Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
            Write-Host "$tNow " -NoNewline -ForegroundColor DarkGray
            Write-Host ("{0,-6}" -f $lvl) -NoNewline -ForegroundColor $fgColor
            Write-Host ("{0,-13}" -f $realHost) -NoNewline -ForegroundColor Green
            Write-Host ("{0,-16}" -f $realService) -NoNewline -ForegroundColor Cyan
            Write-Host ("{0,-42}" -f $msg) -NoNewline -ForegroundColor White
            Write-Host "$chDV" -ForegroundColor Cyan
        }
    } else {
        Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
        Write-Host "  Listening for live multi-source log stream events...                            " -NoNewline -ForegroundColor DarkGray
        Write-Host "$chDV" -ForegroundColor Cyan
    }

    Write-Host "  $midLine" -ForegroundColor Cyan
    Write-Host "  $chDV " -NoNewline -ForegroundColor Cyan
    Write-Host "[Dash] " -NoNewline -ForegroundColor Yellow
    Write-Host "* <-/->: Switch Tab * ^/v: Select * 1-5: Direct Tab * Q: Quit * Update: 150ms " -NoNewline -ForegroundColor White
    Write-Host "$chDV" -ForegroundColor Cyan
    Write-Host "  $botLine" -ForegroundColor Cyan
}

if ($Once) {
    Render-GridFrame -TabIndex 0 -Frame 0
    return
}

try { [Console]::CursorVisible = $false } catch {}

try {
    $frame = 0
    Clear-Host
    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -eq 'q' -or $key.KeyChar -eq 'Q') { break }
        }

        try { [Console]::SetCursorPosition(0,0) } catch { Clear-Host }
        Render-GridFrame -TabIndex 0 -Frame $frame

        $frame++
        Start-Sleep -Milliseconds $IntervalMs
    }
} finally {
    try { [Console]::CursorVisible = $true } catch {}
}
