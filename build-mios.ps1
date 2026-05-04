#Requires -Version 5.1
# 'MiOS' Unified Installer & Builder -- Windows 11 / PowerShell
#
#   irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1 | iex
#
# Flags:
#   -BuildOnly    Pull latest + build only (skip first-time setup)
#   -Unattended   Accept all defaults, no prompts

param([switch]$BuildOnly, [switch]$Unattended)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# Acknowledgment banner. Inlined (script is irm-piped). Respects
# $env:MIOS_AGREEMENT_BANNER=quiet for unattended runs.
if ($env:MIOS_AGREEMENT_BANNER -notin @('quiet','silent','off','0','false','FALSE')) {
    [Console]::Error.WriteLine(@"
[mios] By invoking build-mios.ps1 you acknowledge AGREEMENTS.md
       (Apache-2.0 main + bundled-component licenses in LICENSES.md +
        attribution in CREDITS.md). 'MiOS' is a research project
       (pronounced 'MyOS'; generative, seed-script-derived).
"@)
}

# ── Install scope detection ───────────────────────────────────────────────────
# 'MiOS' installs as a native Windows app. Two scopes:
#
#   AllUsers  -- machine-wide install at C:\Program Files\MiOS\
#                Add/Remove Programs in HKLM. Distros + images in
#                C:\ProgramData\MiOS. Per-user logs/config still use
#                %LOCALAPPDATA%\MiOS / %APPDATA%\MiOS so each Windows
#                account on the box gets its own state.
#
#   CurrentUser -- per-user install at %LOCALAPPDATA%\Programs\MiOS\
#                  Add/Remove Programs in HKCU. Used as a fallback when
#                  the operator declines UAC elevation, or when the
#                  installer is invoked under a standard (non-admin)
#                  account.
#
# Detection: a process is "admin" if it holds the Administrators
# built-in role. The 'irm | iex' one-liner from Get-MiOS.ps1 will refuse
# to elevate itself (UAC cannot prompt mid-pipeline); operators are
# expected to run from an elevated PowerShell when AllUsers is desired.
$script:IsAdmin = $false
try {
    $script:IsAdmin = ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $script:IsAdmin = $false }

$MiosScope = if ($script:IsAdmin) { "AllUsers" } else { "CurrentUser" }

# ── Paths & constants ─────────────────────────────────────────────────────────
$MiosVersion      = "v0.2.2"
$MiosRepoUrl      = "https://github.com/mios-dev/mios.git"
$MiosBootstrapUrl = "https://github.com/mios-dev/mios-bootstrap.git"
# Podman machine name -- canonical "MiOS-DEV" (was MiOS-BUILDER pre-v0.2.3).
# Backed by WSL distro `podman-MiOS-DEV` once `podman machine init` runs.
# Both names are recognized at install-time so existing MiOS-BUILDER
# distros are accepted (and not destroyed) until the next podman machine rm.
$DevDistro        = "MiOS-DEV"
$BuilderDistro    = $DevDistro
$LegacyDevName    = "MiOS-BUILDER"
$MiosWslDistro    = "MiOS"
$LegacyDistro     = "podman-machine-default"

if ($script:IsAdmin) {
    # AllUsers (machine-wide native Windows app layout).
    $MiosInstallDir   = Join-Path ${env:ProgramFiles} "MiOS"            # C:\Program Files\MiOS
    $MiosProgramData  = Join-Path ${env:ProgramData}  "MiOS"            # C:\ProgramData\MiOS
    $MiosRepoDir      = Join-Path $MiosInstallDir   "repo"              # code (git checkouts)
    $MiosBinDir       = Join-Path $MiosInstallDir   "bin"               # entry-point scripts
    $MiosShareDir     = Join-Path $MiosInstallDir   "share"             # mios-bootstrap etc/usr trees
    $MiosDistroDir    = Join-Path $MiosProgramData  "distros"           # multi-GB WSL2 artifacts
    $MiosImagesDir    = Join-Path $MiosProgramData  "images"            # qcow2 / vhdx / iso outputs
    $MiosMachineCfg   = Join-Path $MiosProgramData  "config"            # global non-secret install.env
    $StartMenuDir     = Join-Path ${env:ProgramData} "Microsoft\Windows\Start Menu\Programs\MiOS"
    $UninstallRegKey  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MiOS"
} else {
    # CurrentUser fallback.
    $MiosInstallDir   = Join-Path ${env:LOCALAPPDATA} "Programs\MiOS"
    $MiosProgramData  = Join-Path ${env:LOCALAPPDATA} "MiOS\machine-state"
    $MiosRepoDir      = Join-Path $MiosInstallDir    "repo"
    $MiosBinDir       = Join-Path $MiosInstallDir    "bin"
    $MiosShareDir     = Join-Path $MiosInstallDir    "share"
    $MiosDistroDir    = Join-Path $MiosInstallDir    "distros"
    $MiosImagesDir    = Join-Path $MiosInstallDir    "images"
    $MiosMachineCfg   = Join-Path $MiosInstallDir    "config"
    $StartMenuDir     = Join-Path ${env:APPDATA}     "Microsoft\Windows\Start Menu\Programs\MiOS"
    $UninstallRegKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MiOS"
}

# Per-user state regardless of scope. These resolve via $env:USERNAME /
# $env:USERPROFILE so each Windows account on a machine-wide install
# still gets its own logs and per-user identity overlay -- the "user
# variables" half of the install contract.
$MiosConfigDir    = Join-Path ${env:APPDATA}      "MiOS"               # %APPDATA%\MiOS
$MiosDataDir      = Join-Path ${env:LOCALAPPDATA} "MiOS"               # %LOCALAPPDATA%\MiOS
$MiosLogDir       = Join-Path $MiosDataDir        "logs"

# ── Log files ─────────────────────────────────────────────────────────────────
# UNIFIED COUNTING SYSTEM: there is exactly one logged counter timeline --
# the Write-Log entries written to $LogFile by [IO.File]::AppendAllText.
# Show-Dashboard writes directly to the console (in-place repaint via
# SetCursorPosition) and is NEVER captured to the log file. This keeps
# the log a single chronological event stream instead of being flooded
# by hundreds of repainted dashboard frames per minute.
#
# Why no Start-Transcript: Start-Transcript wraps stdout at the host
# layer, so [Console]::Write calls from Show-Dashboard get captured.
# Each 150ms repaint then duplicates the entire ~20-row dashboard into
# the log. Direct file append-only logging avoids this entirely.
$null = New-Item -ItemType Directory -Path $MiosLogDir -Force -ErrorAction SilentlyContinue
$LogStamp       = [datetime]::Now.ToString("yyyyMMdd-HHmmss")
$LogFile        = Join-Path $MiosLogDir "mios-install-$LogStamp.log"
$BuildDetailLog = Join-Path $MiosLogDir "mios-build-$LogStamp.log"
[Environment]::SetEnvironmentVariable("MIOS_UNIFIED_LOG", $LogFile)
[Environment]::SetEnvironmentVariable("MIOS_BUILD_LOG",   $BuildDetailLog)

# Initialize the unified log with a session header so post-mortem readers
# can identify the run boundary the same way Start-Transcript used to.
try {
    [System.IO.File]::AppendAllText(
        $LogFile,
        ("=" * 78 + "`n" +
         "MiOS install session  start=$LogStamp  pid=$PID  user=$env:USERNAME  host=$env:COMPUTERNAME`n" +
         "=" * 78 + "`n"),
        [Text.Encoding]::UTF8)
} catch {}

function Write-Log {
    param([string]$M, [string]$L = "INFO")
    $ts = [datetime]::Now.ToString("HH:mm:ss.fff")
    $line = "[$ts][$L] $M"
    # Append to the unified log directly. No transcript -> dashboard
    # frames cannot leak in. This is THE single canonical counting
    # system for the run; every event flows through here.
    try { [System.IO.File]::AppendAllText($LogFile, ($line + "`n"), [Text.Encoding]::UTF8) } catch {}
    # Mirror to the live console for operator visibility. Show-Dashboard
    # repaints over these rows on its next tick, which is fine -- the log
    # file already has the canonical record.
    Write-Host $line
    if ($L -eq "ERROR") { $script:ErrCount++ }
    if ($L -eq "WARN")  { $script:WarnCount++ }
}

# ── Dashboard state ───────────────────────────────────────────────────────────
$script:DW         = [math]::Max(66, [math]::Min(([Console]::WindowWidth - 2), 80))
$script:PhaseNames = @(
    "Hardware + Prerequisites",
    "Detecting environment",
    "Directories and repos",
    "MiOS-DEV distro",
    "WSL2 configuration",
    "Verifying build context",
    "Identity",
    "Writing identity",
    "App registration",
    "Building OCI image",
    "Exporting WSL2 image",
    "Registering 'MiOS' WSL2",
    "Building disk images",
    "Deploying Hyper-V VM"
)
$script:TotalPhases   = $script:PhaseNames.Count
$script:PhStat        = @(0,0,0,0,0,0,0,0,0,0,0,0,0,0)
$script:PhStart       = @{}
$script:PhEnd         = @{}
$script:CurPhase      = -1
$script:CurStep       = "Starting..."
$script:ErrCount      = 0
$script:WarnCount     = 0
$script:ScriptStart   = [datetime]::Now
$script:DashRow       = 0
$script:DashHeight    = 0
$script:FinalRc       = 0
$script:BuildSubTotal = 48
$script:BuildSubDone  = 0
$script:BuildSubStep  = ""
$script:GhcrToken     = ""
# Live build tracking -- updated each loop tick; shown in debug row
$script:DebugLine     = ""
$script:LineCount     = 0
$script:HWInfo        = ""   # set after Get-Hardware; shown in dashboard info row
$script:IdentInfo     = ""   # set after phase 6 identity; User/Host/Base/Model row
# Shared state between main thread and background spinner runspace.
# SpinnerRow = -1 means unknown (spinner write suppressed until first render).
$script:DashSync = [hashtable]::Synchronized(@{
    Running    = $true
    Rendering  = $false   # set by the main thread around Show-Dashboard's
                          # buffer writes so the background heartbeat skips
                          # its spinner stamp during render -- prevents the
                          # spinner from bleeding into separator rows when
                          # the row count changes between renders.
    SpinnerRow = -1
    SpinnerCol = 2        # "| X" -- spinner is the first char inside the row body
})
$script:BgPs = $null
$script:BgRs = $null

# ── Dashboard functions ───────────────────────────────────────────────────────
function fmtSpan([timespan]$s) {
    if ($s.TotalHours -ge 1) { return "{0}:{1:D2}:{2:D2}" -f [int]$s.TotalHours,$s.Minutes,$s.Seconds }
    return "{0:D2}:{1:D2}" -f [int]$s.TotalMinutes,$s.Seconds
}

function pbar([int]$done,[int]$total,[int]$width) {
    $pct = if ($total -gt 0) { [int](($done/$total)*100) } else { 0 }
    $f   = if ($total -gt 0) { [int](($done/$total)*$width) } else { 0 }
    $bar = if ($f -gt 0) { ("=" * ([math]::Max(0,$f-1))) + ">" } else { "" }
    return "[{0}] {1,3}%  {2}/{3}" -f $bar.PadRight($width),$pct,$done,$total
}

function Update-BuildSubPhase([string]$line) {
    # Strip BuildKit "#N 0.123 " prefix
    $stripped = ($line -replace '^\s*#\d+\s+[\d.]+\s+', '').TrimStart()
    $script:LineCount++

    if ($stripped -match '\+-\s*STEP\s+(\d+)/(\d+)\s*:\s*(\S+)') {
        # Step start marker: "+- STEP NN/TT : scriptname.sh"
        $script:BuildSubTotal = [int]$Matches[2]
        $script:BuildSubStep  = $Matches[3] -replace '\.sh$', ''
        $script:BuildSubDone  = [math]::Max(0, [int]$Matches[1] - 1)
        $script:CurStep       = "Step $($Matches[1])/$($Matches[2]) -- $($script:BuildSubStep)"
        $script:DebugLine     = $stripped
    } elseif ($stripped -match '\+--\s+\[') {
        # Step end marker
        $script:BuildSubDone = [math]::Min($script:BuildSubDone + 1, $script:BuildSubTotal)
        $script:DebugLine    = $stripped
    } elseif (-not [string]::IsNullOrWhiteSpace($stripped)) {
        $c = ($stripped -replace '\s+', ' ').Trim()
        if ($c.Length -gt 120) { $c = $c.Substring(0, 117) + '...' }
        $script:CurStep   = $c
        $script:DebugLine = $c
    }
}

function Show-Dashboard {
    try {
    # ── Sizing -- max 80 cols (standard tty0/console) ──────────────────────────
    $winW = try { [Console]::WindowWidth  } catch { 80 }
    $bufH = try { [Console]::BufferHeight } catch { 9999 }
    # Always 1 char narrower than actual terminal so old content to the right
    # of the box is blanked on overwrite; capped at 80 for tty0 portability.
    $w  = [math]::Max(40, [math]::Min(80, $winW - 1))
    $in = $w - 4   # inner content width: "| " + content + " |"
    $sepD = ("+" + ("-" * ($w - 2)) + "+").PadRight($winW)
    $sepE = ("+" + ("=" * ($w - 2)) + "+").PadRight($winW)

    # ── Row helper -- script block closes over $in/$winW from caller scope ─────
    $mkRow = {
        param([string]$c)
        ("| " + $c.PadRight($in) + " |").PadRight($winW)
    }

    # ── State ─────────────────────────────────────────────────────────────────
    $phDone = [int]($script:PhStat | Where-Object { $_ -ge 2 } | Measure-Object).Count
    $phFail = [int]($script:PhStat | Where-Object { $_ -eq 3 } | Measure-Object).Count
    $elapsed   = [datetime]::Now - $script:ScriptStart
    $elStr     = fmtSpan $elapsed
    $statusStr = if ($phFail -gt 0) { "FAILED" } `
                 elseif ($script:CurPhase -ge 0 -and $script:PhStat[$script:CurPhase] -eq 1) { "RUNNING" } `
                 else { "IDLE" }
    $curName   = if ($script:CurPhase -ge 0) { [string]$script:PhaseNames[$script:CurPhase] } else { "Initializing" }

    # Spinner -- 500ms tick; visible on slow/remote consoles, animates even when
    # build output is silent.
    $spinChar = @('|','/','-',[char]92)[[int]($elapsed.TotalMilliseconds / 500) % 4]

    $step = (([string]$script:CurStep) -replace '\s+', ' ').Trim()
    $stepMax = [math]::Max(3, $in - 8)
    if ($step.Length -gt $stepMax) { $step = $step.Substring(0, $stepMax - 3) + "..." }

    # ── Single unified progress bar (phases + build steps = one global count) ─
    $stDone  = [math]::Max(0, $script:BuildSubDone)
    $stTotal = [math]::Max(1, $script:BuildSubTotal)
    $glDone  = $phDone + $stDone
    $glTotal = $script:TotalPhases + $stTotal
    $barW    = [math]::Max(4, $in - 24)
    $glPct = 0; if ($glTotal -gt 0) { $glPct = [int](($glDone / $glTotal) * 100) }
    $glFRaw = 0; if ($glTotal -gt 0) { $glFRaw = [int](($glDone / $glTotal) * $barW) }
    $glF     = [math]::Max(0, $glFRaw)
    if ($glF -gt 0) { $glFill = ("=" * ($glF - 1)) + ">" } else { $glFill = "" }
    $glFill  = $glFill.PadRight($barW)
    $glBarL  = "[{0}] {1,3}%  {2}/{3}" -f $glFill,$glPct,$glDone,$glTotal

    # ── Phase table col widths ────────────────────────────────────────────────
    # Single table layout used by header / divider / data rows:
    #
    #   "{0,2} {1,-6} {2,-nameW} {3,5}"
    #     idx  tag   name        time
    #     2  +1+ 6  +1+ nameW   +1+ 5  = 16 + nameW
    #
    # Setting nameW = $in - 16 makes every row land at exactly $in
    # characters of content, so the right "|" border sits in the same
    # column on all three rows -- no more zigzag right edge.
    $nameW = [math]::Max(8, $in - 16)
    $tableFmt = "{0,2} {1,-6} {2,-${nameW}} {3,5}"

    # ── Assemble rows ─────────────────────────────────────────────────────────
    $rows = [System.Collections.Generic.List[string]]::new()

    # Header -- gap computed so total row width = $w, then padded to $winW
    $rows.Add($sepE)
    $title = " 'MiOS' $MiosVersion  --  Build Dashboard"
    $right = "[ $elStr ] "
    $gap   = [math]::Max(0, $in - $title.Length - $right.Length)
    $hdr   = "| $title" + (" " * $gap) + "$right |"
    $rows.Add($hdr.PadRight($winW))
    $rows.Add($sepE)

    # Hardware info row (populated after Get-Hardware; blank during early phases)
    if ($script:HWInfo) {
        $hw = ([string]$script:HWInfo)
        if ($hw.Length -gt $in) { $hw = $hw.Substring(0,$in-3)+"..." }
        $rows.Add((& $mkRow $hw))
    }

    # Identity row (populated after phase 6; blank before)
    if ($script:IdentInfo) {
        $id = ([string]$script:IdentInfo)
        if ($id.Length -gt $in) { $id = $id.Substring(0,$in-3)+"..." }
        $rows.Add((& $mkRow $id))
    }

    if ($script:HWInfo -or $script:IdentInfo) { $rows.Add($sepD) }

    # ── ONE counter, ONE bar ──────────────────────────────────────────────────
    # Single global step counter (phases + build sub-steps) rendered as
    # one progress bar. The textual "Phase [N/Total]" and "(step X/Y)"
    # rows used to duplicate this same metric three different ways and
    # are intentionally gone -- the bar's "N/M" suffix is THE counter.
    # Current operation + spinner share one row above the bar so the
    # operator sees what's running without a second phase-counter line.
    $phTag = switch ([int]$script:PhStat[[math]::Max(0,$script:CurPhase)]) {
        1 { "[>>]" } 2 { "[OK]" } 3 { "[XX]" } 4 { "[!!]" } default { "[ ]" }
    }
    # Now-line: phase name + live operation stream + spinner. No
    # numeric counters here -- those live in the bar below.
    $opRowIdx = $rows.Count
    $nowLine  = "$spinChar  $phTag $curName -- $step"
    if ($nowLine.Length -gt $in) { $nowLine = $nowLine.Substring(0, $in - 3) + "..." }
    $rows.Add((& $mkRow $nowLine))
    $rows.Add($sepD)

    # The single global counter -- bar + percent + N/M of the unified
    # phase+substep total. This is THE counter; nothing else displays
    # progress numerically.
    $rows.Add((& $mkRow $glBarL))
    $rows.Add($sepD)

    # Side notes (not counters): error/warning tally + status. Errors
    # are not progress, so they get their own one-line row separate from
    # the counter row above. "Lines" was meaningless to operators and
    # was contributing to the visual noise -- dropped.
    $rows.Add((& $mkRow "Errors:$($script:ErrCount)  Warnings:$($script:WarnCount)  Status:$statusStr"))
    $rows.Add($sepD)

    # Phase table -- header, divider, and data rows ALL go through the
    # single $tableFmt printf template so the right border lands at
    # the same column on every row. Status tags are padded to 6 chars
    # to align under the "[Stat]" header column.
    $rows.Add((& $mkRow ($tableFmt -f " #", "[Stat]", "Phase Name", " Time")))
    $rows.Add((& $mkRow ($tableFmt -f "--", "------", ("-" * $nameW), "-----")))
    for ($i = 0; $i -lt $script:TotalPhases; $i++) {
        $st = switch ([int]$script:PhStat[$i]) {
            0 { "[ ]"  } 1 { "[>>]" } 2 { "[OK]" } 3 { "[XX]" } 4 { "[!!]" } default { "[??]" }
        }
        $nm = [string]$script:PhaseNames[$i]
        if ($nm.Length -gt $nameW) { $nm = $nm.Substring(0,$nameW-3)+"..." }
        $t = ""
        if ($null -ne $script:PhStart[$i]) {
            try {
                $ps = [datetime]$script:PhStart[$i]
                $pe = if ($null -ne $script:PhEnd[$i]) { [datetime]$script:PhEnd[$i] } else { [datetime]::Now }
                $t  = fmtSpan ($pe - $ps)
            } catch { $t = "--:--" }
        }
        $rows.Add((& $mkRow ($tableFmt -f $i, $st, $nm, $t)))
    }
    $rows.Add($sepD)

    # Log footer -- unified log only ($BuildDetailLog is merged in at exit)
    $logLeaf = try { Split-Path $LogFile -Leaf } catch { "?" }
    $rows.Add((& $mkRow "Log: $logLeaf"))
    $rows.Add($sepE)

    # ── Render at fixed position; full-width overwrite eliminates bleed ────────
    $dashStart = [math]::Min($script:DashRow, [math]::Max(0, $bufH - $rows.Count - 2))
    # Lock out the background heartbeat for the duration of the buffer
    # writes so the spinner can't stamp a "/" or "-" into a separator
    # row mid-render. The heartbeat sees Rendering=$true on its next
    # 120 ms tick and skips its [Console]::Write.
    $script:DashSync.Rendering = $true
    try {
        $script:DashSync.SpinnerRow = $dashStart + $opRowIdx
        [Console]::SetCursorPosition(0, $dashStart)
        foreach ($row in $rows) {
            [Console]::Write($row)
            [Console]::Write([Environment]::NewLine)
        }
        $script:DashHeight = $rows.Count
        [Console]::SetCursorPosition(0, [math]::Min($dashStart + $script:DashHeight, $bufH - 1))
    } finally {
        $script:DashSync.Rendering = $false
    }

    } catch {
        Write-Host "[$([datetime]::Now.ToString('HH:mm:ss.fff'))][WARN] dashboard render error: $_"
    }
}

function Start-Phase([int]$i) {
    $script:CurPhase   = $i
    $script:PhStat[$i] = 1
    $script:PhStart[$i] = [datetime]::Now
    $script:CurStep    = $script:PhaseNames[$i]
    Write-Log "START phase $i : $($script:PhaseNames[$i])"
    Show-Dashboard
}

function End-Phase([int]$i, [switch]$Fail, [switch]$Warn) {
    $script:PhStat[$i] = if ($Fail) { 3 } elseif ($Warn) { 4 } else { 2 }
    $script:PhEnd[$i]  = [datetime]::Now
    $spanStr = try {
        if ($null -ne $script:PhStart[$i]) { fmtSpan ([datetime]$script:PhEnd[$i] - [datetime]$script:PhStart[$i]) } else { "--:--" }
    } catch { "--:--" }
    $tag     = if ($Fail) { "FAIL" } elseif ($Warn) { "WARN" } else { "OK  " }
    $lvl     = if ($Fail) { "ERROR" } else { "INFO" }
    Write-Log "$tag  phase $i : $($script:PhaseNames[$i]) ($spanStr)" $lvl
    Show-Dashboard
}

function Set-Step([string]$T) {
    $script:CurStep = $T
    Write-Log "step: $T"
    Show-Dashboard
}

function Log-Ok([string]$T)   { Write-Log "ok   $T";          Set-Step $T }
function Log-Warn([string]$T) { Write-Log "warn $T" "WARN";   Set-Step "WARN: $T" }
function Log-Fail([string]$T) { Write-Log "fail $T" "ERROR";  Set-Step "FAIL: $T" }

# ── Utility helpers ───────────────────────────────────────────────────────────
function ConvertTo-WslPath([string]$P) {
    $P = $P -replace '\\','/'
    if ($P -match '^([A-Za-z]):(.*)') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
    return $P
}

function Move-BelowDash {
    try {
        $targetRow = [math]::Min($script:DashRow + $script:DashHeight, [Console]::BufferHeight - 1)
        [Console]::SetCursorPosition(0, $targetRow)
    } catch {}
}

function Read-Line([string]$Prompt, [string]$Default = "") {
    Move-BelowDash
    Write-Host "  $Prompt" -NoNewline -ForegroundColor White
    if ($Default) { Write-Host " [$Default]" -NoNewline -ForegroundColor DarkGray }
    Write-Host ": " -NoNewline
    if ($Unattended) { Write-Host $Default -ForegroundColor DarkGray; return $Default }
    $v = Read-Host
    return (([string]::IsNullOrWhiteSpace($v)) ? $Default : $v)
}

function Read-Model([string]$Default = "qwen2.5-coder:7b") {
    # AI model menu prompt -- feature parity with build-mios.sh's
    # prompt_model. Drives MIOS_OLLAMA_BAKE_MODELS at build time and
    # MIOS_AI_MODEL in install.env at runtime. Same auto-accept
    # semantics as the rest of the Phase-6 prompts.
    Move-BelowDash
    Write-Host ""
    Write-Host "  AI model (Architectural Law 5 -- baked into the image):" -ForegroundColor White
    Write-Host "    1) qwen2.5-coder:7b   -- 12 GB RAM, code-specialized, default" -ForegroundColor DarkGray
    Write-Host "    2) qwen2.5-coder:14b  -- 24+ GB RAM, larger code reasoning" -ForegroundColor DarkGray
    Write-Host "    3) llama3.2:3b        -- 8 GB RAM, fast" -ForegroundColor DarkGray
    Write-Host "    4) custom             -- enter your own ollama model id" -ForegroundColor DarkGray
    $choice = Read-Line "Choice [1-4]" "1"
    switch ($choice) {
        "1"     { return "qwen2.5-coder:7b" }
        ""      { return "qwen2.5-coder:7b" }
        "2"     { return "qwen2.5-coder:14b" }
        "3"     { return "llama3.2:3b" }
        "4"     { return (Read-Line "Custom model id (e.g. mistral:7b)" $Default) }
        default { Write-Host "  invalid choice '$choice'; using default '$Default'" -ForegroundColor Yellow; return $Default }
    }
}

function Resolve-MiosTomlAiDefaults([string]$RepoDir) {
    # Read [ai].model / [ai].embed_model / [ai].bake_models out of the
    # unified mios.toml dotfile. Walks the same layered overlay
    # build-mios.sh's resolve_profile_layers walks, so per-host edits
    # to /etc/mios/mios.toml or ~/.config/mios/mios.toml seed the
    # interactive prompt without re-cloning. Pure regex parser; no TOML
    # library dependency. Returns a hashtable -- caller picks fields.
    $defaults = @{
        Model       = "qwen2.5-coder:7b"
        EmbedModel  = "nomic-embed-text"
        BakeModels  = "qwen2.5-coder:7b,nomic-embed-text"
    }
    $layers = @()
    foreach ($p in @(
        (Join-Path $RepoDir       "mios-bootstrap\mios.toml"),
        (Join-Path $env:APPDATA   "MiOS\mios.toml"),
        (Join-Path $env:USERPROFILE ".config\mios\mios.toml")
    )) { if (Test-Path $p) { $layers += $p } }

    foreach ($card in $layers) {
        try {
            $text = Get-Content -Raw -Path $card -ErrorAction Stop
        } catch { continue }
        # Extract the [ai] section body up to the next [section] header
        # or end-of-file. (?ms) for multiline + dot-matches-newline.
        $m = [regex]::Match($text, '(?ms)^\[ai\]\s*$(.*?)(?=^\[|\z)')
        if (-not $m.Success) { continue }
        $body = $m.Groups[1].Value
        foreach ($kv in @(
            @{ Key='model';        Slot='Model' },
            @{ Key='embed_model';  Slot='EmbedModel' },
            @{ Key='bake_models';  Slot='BakeModels' }
        )) {
            $rx = [regex]::new('(?m)^\s*' + [regex]::Escape($kv.Key) + '\s*=\s*"([^"]*)"')
            $hit = $rx.Match($body)
            if ($hit.Success) { $defaults[$kv.Slot] = $hit.Groups[1].Value }
        }
    }
    return $defaults
}

function Open-Configurator([string]$RepoDir) {
    # Open /usr/share/mios/configurator/index.html for the operator to
    # edit the unified mios.toml. Canonical path: launch Epiphany IN
    # MiOS-DEV via WSLg so the configurator runs inside the same
    # environment that built it. The window appears on the Windows
    # desktop; the saved mios.toml lands in the dev VM's FHS-compliant
    # ~/Downloads (which IS the bootc-style home/user/Downloads
    # location, since MiOS-DEV mirrors the deployed MiOS layout). The
    # PowerShell side then picks up that file and overlays it as the
    # new source for the build pipeline -- so the operator's Epiphany
    # save IS the build's input.
    #
    # Falls back to the operator's default Windows browser if MiOS-DEV
    # isn't reachable or Epiphany is unavailable (covers fresh installs
    # before the dev distro has finished provisioning).
    if ($Unattended) { return }
    if ($env:MIOS_NO_CONFIGURATOR -eq "1") { return }

    $resp = Read-Line "Open MiOS configurator (Epiphany on MiOS-DEV via WSLg)?" "y"
    if ($resp -notmatch '^(y|yes|true|1)$') { return }

    $candidates = @(
        (Join-Path $RepoDir "mios\usr\share\mios\configurator\index.html"),
        (Join-Path $MiosShareDir "system\usr\share\mios\configurator\index.html"),
        (Join-Path $MiosShareDir "bootstrap\usr\share\mios\configurator\index.html")
    )
    $html = $null
    foreach ($c in $candidates) { if (Test-Path $c) { $html = $c; break } }
    if (-not $html) {
        Write-Log "Configurator HTML not found locally -- skipping GUI step" "WARN"
        return
    }

    if (Open-ConfiguratorInDev -RepoDir $RepoDir -Html $html) { return }
    Log-Warn "MiOS-DEV / Epiphany unavailable -- falling back to Windows default browser"
    Open-ConfiguratorOnWindows -RepoDir $RepoDir -Html $html
}

function Open-ConfiguratorInDev([string]$RepoDir, [string]$Html) {
    # Probe MiOS-DEV (canonical name then legacy fallback)
    $wslDistro = $null
    foreach ($candidate in @("podman-$DevDistro", $DevDistro, "podman-$LegacyDevName")) {
        $probe = (& wsl.exe -d $candidate --exec bash -c "echo ok" 2>$null) -join ""
        if ($probe.Trim() -eq "ok") { $wslDistro = $candidate; break }
    }
    if (-not $wslDistro) { return $false }

    # Find the regular user (uid 1000) inside the dev VM. Podman machines
    # default to "user"; we honor whatever's actually there.
    $devUser = ((& wsl.exe -d $wslDistro --exec bash -c "getent passwd 1000 | cut -d: -f1" 2>$null) -join "").Trim()
    if (-not $devUser) { $devUser = "user" }

    # Convert C:\path\index.html -> /mnt/c/path/index.html
    $drive    = $Html.Substring(0,1).ToLower()
    $htmlWsl  = "/mnt/$drive" + ($Html.Substring(2) -replace '\\','/')

    # Resolve the seed mios.toml the configurator should pre-load. Pick
    # the highest-precedence existing layer; the bash side will copy it
    # into the dev VM's ~/Downloads/mios.toml as the working file.
    $sources = @(
        (Join-Path $env:APPDATA "MiOS\mios.toml"),
        (Join-Path $RepoDir "mios-bootstrap\mios.toml"),
        (Join-Path $RepoDir "mios\usr\share\mios\mios.toml")
    )
    $seedToml = $null
    foreach ($s in $sources) { if (Test-Path $s) { $seedToml = $s; break } }
    $seedTomlWsl = ""
    if ($seedToml) {
        $sd = $seedToml.Substring(0,1).ToLower()
        $seedTomlWsl = "/mnt/$sd" + ($seedToml.Substring(2) -replace '\\','/')
    }

    Write-Host ""
    Write-Host "  Launching Epiphany on $wslDistro (user: $devUser) ..." -ForegroundColor Cyan
    Write-Host "  Configurator URL:    file://~/Downloads/mios-configurator.html" -ForegroundColor Gray
    Write-Host "  Working mios.toml:   /home/$devUser/Downloads/mios.toml" -ForegroundColor Gray
    Write-Host "  WSLg routes the Epiphany window to the Windows desktop." -ForegroundColor Gray
    Write-Host ""

    $bashScript = @'
#!/usr/bin/env bash
# Generated by build-mios.ps1 / Open-ConfiguratorInDev.
set -euo pipefail
SRC_HTML="${1:?html path required}"
SEED_TOML="${2:-}"
USER_NAME="${3:-user}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
DL_DIR="$USER_HOME/Downloads"

sudo -u "$USER_NAME" install -d -m 0755 "$DL_DIR"

# Seed the working mios.toml in ~/Downloads. The configurator's "Pick file"
# button binds to it; "Save" overwrites in place (File System Access API)
# or, if the WebKit build lacks FSA, the operator triggers a download that
# also lands here.
if [[ -n "$SEED_TOML" && -r "$SEED_TOML" ]]; then
    sudo -u "$USER_NAME" install -m 0644 "$SEED_TOML" "$DL_DIR/mios.toml"
elif [[ ! -f "$DL_DIR/mios.toml" ]]; then
    sudo -u "$USER_NAME" touch "$DL_DIR/mios.toml"
fi

# Copy the HTML configurator into ~/Downloads where Epiphany's flatpak
# sandbox can read it via the home-portal default exposure.
sudo -u "$USER_NAME" install -m 0644 "$SRC_HTML" "$DL_DIR/mios-configurator.html"

# Ensure flathub remote + Epiphany flatpak are present (system-wide install).
flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
if ! flatpak list --system --app --columns=application 2>/dev/null | grep -qx org.gnome.Epiphany; then
    echo "[configurator] installing org.gnome.Epiphany flatpak (one-time, ~250 MB)..."
    flatpak install --system --noninteractive --assumeyes --or-update flathub org.gnome.Epiphany \
        2>&1 | grep -E '^(Installing|Updating|Already|Error|Warning)' || true
fi

# Resolve the WSLg display sockets for the regular user. WSLg sets
# WAYLAND_DISPLAY=wayland-0 + DISPLAY=:0 in $HOME/.profile, but a
# sudo invocation strips those -- pull them from /run/user/1000.
RT="/run/user/$(id -u "$USER_NAME")"
[[ -d "$RT" ]] || RT="/tmp/runtime-$USER_NAME"
sudo -u "$USER_NAME" mkdir -p "$RT"

# Launch Epiphany detached. Browsers refuse to run as root, so we drop
# to the regular user. The flatpak run wrapper picks up the seat's
# Wayland socket via XDG_RUNTIME_DIR.
sudo -u "$USER_NAME" \
    XDG_RUNTIME_DIR="$RT" \
    DISPLAY=":0" \
    WAYLAND_DISPLAY="wayland-0" \
    PULSE_SERVER="unix:$RT/pulse/native" \
    flatpak run org.gnome.Epiphany \
        "file://$DL_DIR/mios-configurator.html" >/dev/null 2>&1 &
disown
echo "[configurator] Epiphany launched -- window should appear on the Windows desktop"
echo "[configurator] save target: $DL_DIR/mios.toml"
'@

    # PowerShell @'...'@ here-strings produce CRLF line endings on
    # Windows. The bash shebang then becomes "#!/usr/bin/env bash\r"
    # and `env` errors with "bash\r: No such file or directory".
    # Strip CR before base64-encoding so the script lands clean inside
    # the WSL distro.
    $bashScript = $bashScript -replace "`r`n", "`n" -replace "`r", "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bashScript))
    $stage = "set -e; echo '$b64' | base64 -d > /tmp/launch-config.sh && chmod +x /tmp/launch-config.sh; " +
             "/tmp/launch-config.sh '$htmlWsl' '$seedTomlWsl' '$devUser'"
    & wsl.exe -d $wslDistro --exec bash -c $stage 2>&1 | ForEach-Object { Write-Log "configurator: $_" }
    if ($LASTEXITCODE -ne 0) { Log-Warn "Epiphany launch returned rc=$LASTEXITCODE -- falling back"; return $false }

    Write-Host ""
    Write-Host "  In Epiphany on the Windows desktop:" -ForegroundColor Cyan
    Write-Host "    1. Click 'Pick file' (or 'Open (fallback)') -> ~/Downloads/mios.toml" -ForegroundColor Gray
    Write-Host "    2. Edit identity / AI / desktop / flatpaks / quadlets" -ForegroundColor Gray
    Write-Host "    3. Click 'Save' -- the file overwrites ~/Downloads/mios.toml" -ForegroundColor Gray
    Write-Host ""
    $null = Read-Host "  Press Enter when finished editing in Epiphany"

    # Pick up the saved mios.toml from MiOS-DEV's ~/Downloads and
    # promote it as the build source. We write to BOTH:
    #   1. %APPDATA%\MiOS\mios.toml   -- runtime per-user overlay
    #   2. mios-bootstrap clone root   -- seed-merge inputs to podman build
    # so the very next build/install pass uses the operator's edits.
    $tomlContent = (& wsl.exe -d $wslDistro --user $devUser --exec cat "/home/$devUser/Downloads/mios.toml" 2>$null) -join "`n"
    if ([string]::IsNullOrWhiteSpace($tomlContent)) {
        Log-Warn "No saved mios.toml found at /home/$devUser/Downloads/ -- continuing with vendor default"
        return $true
    }

    $userLayer = Join-Path $env:APPDATA "MiOS\mios.toml"
    $userDir   = Split-Path -Parent $userLayer
    if (-not (Test-Path $userDir)) { New-Item -ItemType Directory -Path $userDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($userLayer, $tomlContent, [Text.UTF8Encoding]::new($false))

    $bootstrapToml = Join-Path $RepoDir "mios-bootstrap\mios.toml"
    if (Test-Path (Split-Path -Parent $bootstrapToml)) {
        [System.IO.File]::WriteAllText($bootstrapToml, $tomlContent, [Text.UTF8Encoding]::new($false))
        Log-Ok "Saved mios.toml -> $userLayer + $bootstrapToml (build pipeline picks up on next pass)"
    } else {
        Log-Ok "Saved mios.toml -> $userLayer"
    }
    return $true
}

function Open-ConfiguratorOnWindows([string]$RepoDir, [string]$Html) {
    # Legacy / fallback path: run the configurator in the operator's
    # default Windows browser. Used when MiOS-DEV isn't reachable yet
    # (e.g. fresh install before Phase 3 finishes) or when WSLg is
    # disabled. Saves go through the Windows Downloads folder via the
    # standard <input type="file"> + downloads flow.
    $stagingDir = Join-Path $env:TEMP "mios-configurator"
    if (-not (Test-Path $stagingDir)) { New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null }
    $stamp   = [datetime]::Now.ToString("yyyyMMdd-HHmmss")
    $staging = Join-Path $stagingDir "mios-$stamp.toml"
    $sources = @(
        (Join-Path $env:APPDATA "MiOS\mios.toml"),
        (Join-Path $RepoDir "mios-bootstrap\mios.toml"),
        (Join-Path $RepoDir "mios\usr\share\mios\mios.toml")
    )
    $src = $null
    foreach ($s in $sources) { if (Test-Path $s) { $src = $s; break } }
    if ($src) { Copy-Item -Path $src -Destination $staging -Force }
    else      { New-Item -ItemType File -Path $staging -Force | Out-Null }

    $stagingForUrl = ($staging -replace '\\', '/' -replace ' ', '%20')
    $url = "file:///$($Html -replace '\\', '/' -replace ' ', '%20')?suggested_path=$stagingForUrl"
    Write-Host ""
    Write-Host "  Opening configurator: $url" -ForegroundColor Cyan
    Write-Host "  Staging file:         $staging" -ForegroundColor Cyan
    Write-Host ""
    try { Start-Process $url -ErrorAction Stop }
    catch { Log-Warn "Browser launch failed: $($_.Exception.Message). Open manually: $url" }
    $null = Read-Host "  Press Enter when finished editing in the browser"

    if ((Test-Path $staging) -and ((Get-Item $staging).Length -gt 0)) {
        $userLayer = Join-Path $env:APPDATA "MiOS\mios.toml"
        $userDir   = Split-Path -Parent $userLayer
        if (-not (Test-Path $userDir)) { New-Item -ItemType Directory -Path $userDir -Force | Out-Null }
        Copy-Item -Path $staging -Destination $userLayer -Force
        $bootstrapToml = Join-Path $RepoDir "mios-bootstrap\mios.toml"
        if (Test-Path (Split-Path -Parent $bootstrapToml)) {
            Copy-Item -Path $staging -Destination $bootstrapToml -Force
        }
        Log-Ok "Staged $staging -> $userLayer (+ bootstrap clone if present)"
    }
}

function Read-Password([string]$Prompt = "Password") {
    Move-BelowDash
    Write-Host "  $Prompt [default: mios]: " -NoNewline -ForegroundColor White
    if ($Unattended) { Write-Host "(default)" -ForegroundColor DarkGray; return "" }
    if ($PSVersionTable.PSVersion.Major -ge 7) { return (Read-Host -MaskInput) }
    $ss = Read-Host -AsSecureString
    $b  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Get-PasswordHash([string]$Plain) {
    if ($Plain -eq "mios" -or [string]::IsNullOrWhiteSpace($Plain)) {
        return '$6$miosmios0$ShHuf/TnPoEmEX//L9mrNNuP7kZ6l9aj/qV9WFj5LnjL3lunhKEwnJfY6tvlJbRiWkLTtPmdwCgWeOQB9eXuW.'
    }
    $salt = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
    foreach ($d in @($BuilderDistro, $LegacyDistro)) {
        try {
            $h = (& wsl.exe -d $d --exec openssl passwd -6 -salt $salt $Plain 2>$null) -join ""
            if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
        } catch {}
    }
    # Podman machine SSH (machine-os not accessible via wsl.exe)
    try {
        $mls = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
               Where-Object { $_ -match "^$([regex]::Escape($BuilderDistro))\s+true" }
        if ($mls) {
            $h = (& podman machine ssh $BuilderDistro -- bash -c "openssl passwd -6 -salt '$salt' '$Plain'" 2>$null) -join ""
            if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
        }
    } catch {}
    try {
        $h = (& podman run --rm docker.io/library/alpine:latest sh -c "apk add -q openssl && openssl passwd -6 -salt '$salt' '$Plain'" 2>$null) -join ""
        if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
    } catch {}
    throw "Cannot generate sha512crypt hash -- install openssl or run from a distro."
}

function Get-Hardware {
    $ramGB = try { [math]::Round((Get-CimInstance Win32_PhysicalMemory|Measure-Object Capacity -Sum).Sum/1GB) } catch { 16 }
    # OS-reported RAM (bytes) -- this is what podman validates against; may be less than nominal GB count
    $osTotalRamMB = try { [math]::Floor((Get-CimInstance Win32_ComputerSystem -EA Stop).TotalPhysicalMemory / 1MB) } catch { $ramGB * 1024 }
    $cpus  = [Environment]::ProcessorCount
    $gpu   = try { Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft Basic" } | Select-Object -First 1 } catch { $null }
    $gpuName   = if ($gpu) { $gpu.Name } else { "Unknown" }
    $hasNvidia = $gpuName -match "NVIDIA|GeForce|Quadro|RTX|GTX|Tesla"
    $baseImage = if ($hasNvidia) { "ghcr.io/ublue-os/ucore-hci:stable-nvidia" } else { "ghcr.io/ublue-os/ucore-hci:stable" }
    $aiModel   = if ($ramGB -ge 32) { "qwen2.5-coder:14b" } elseif ($ramGB -ge 12) { "qwen2.5-coder:7b" } else { "phi4-mini:3.8b-q4_K_M" }
    $diskFreeGB    = try { [math]::Floor((Get-PSDrive C -EA Stop).Free/1GB) } catch { 200 }
    $builderDiskGB = [math]::Max(80, $diskFreeGB - 20)
    return @{ RamGB=$ramGB; OsTotalRamMB=$osTotalRamMB; Cpus=$cpus; GpuName=$gpuName; HasNvidia=$hasNvidia
              BaseImage=$baseImage; AiModel=$aiModel; DiskGB=$builderDiskGB }
}

function Find-ActiveDistro {
    # Check legacy WSL distros ('MiOS' already applied via bootc switch, has /Justfile)
    foreach ($d in @($BuilderDistro, $LegacyDistro)) {
        try {
            $r = (& wsl.exe -d $d --exec bash -c "test -f /Justfile && echo ready" 2>$null) -join ""
            if ($r.Trim() -eq "ready") { return $d }
        } catch {}
    }
    # Check if BuilderDistro is a running Podman machine (machine-os: no /Justfile but can still build)
    try {
        $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
              Where-Object { $_ -match "^$([regex]::Escape($BuilderDistro))\s+true" }
        if ($ml) { return $BuilderDistro }
    } catch {}
    return $null
}

function Sync-RepoToDistro([string]$Distro, [string]$WinPath) {
    $wsl = ConvertTo-WslPath $WinPath
    # Try direct WSL file:// fetch (works when Windows drive is mounted at /mnt/)
    try {
        & wsl.exe -d $Distro --user root --exec bash -c `
            "git -C / fetch 'file://$wsl' main 2>/dev/null && git -C / reset --hard FETCH_HEAD 2>/dev/null"
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}
    # Podman machine fallback: Windows drive not mounted; pull from GitHub origin instead
    try {
        & podman machine ssh $Distro -- bash -c `
            "cd / && git fetch --depth=1 origin main 2>/dev/null && git reset --hard FETCH_HEAD 2>/dev/null"
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Initialize-MiosDataDisk {
    <#
    .SYNOPSIS
        Shrink C: by exactly $ShrinkMB and create a dedicated MiOS-DEV partition
        in the freed space. Redirect podman-machine storage onto that partition
        so MiOS-DEV's VHDX (which internally hosts the ext4 root) lives on the
        new drive end-to-end.

    .NOTES
        WSL2 STORES DISTROS AS VHDX FILES. The VHDX format requires a Windows-
        accessible host filesystem (NTFS or ReFS) -- a raw ext4 host partition
        cannot host a VHDX. The new partition is therefore formatted NTFS, and
        MiOS-DEV's Linux root inside the VHDX *is* ext4 (mkfs'd by WSL2 at first
        boot). Result: the operator's "ext partition for MiOS-DEV" requirement
        is satisfied at the WSL/Linux layer, with the host wrapper as the thin
        NTFS shell that WSL2 strictly requires.

        Idempotent: a partition labeled $VolumeLabel on $DriveLetter is treated
        as already-initialized and the function returns without shrinking again.
    #>
    param(
        [int]$ShrinkMB     = 262144,
        [string]$DriveLetter = 'M',
        [string]$VolumeLabel = 'MIOS-DEV'
    )

    Set-Step "Sizing MiOS data disk ($ShrinkMB MB on ${DriveLetter}:)..."

    # 0. Already-initialized? Skip.
    $existing = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if ($existing -and $existing.FileSystemLabel -eq $VolumeLabel) {
        Log-Ok "MiOS data disk already on ${DriveLetter}: ($([math]::Round($existing.Size/1GB,1)) GB, $($existing.FileSystem))"
        return "${DriveLetter}:\"
    }
    if ($existing) {
        throw "Drive ${DriveLetter}: already exists with label '$($existing.FileSystemLabel)' -- pass a different -DriveLetter or remove the volume manually"
    }

    # 1. Locate C: partition + its disk
    $sysLetter = ([Environment]::GetEnvironmentVariable('SystemDrive')).TrimEnd(':')
    $cPart = Get-Partition -DriveLetter $sysLetter
    $supported = Get-PartitionSupportedSize -DriveLetter $sysLetter
    $shrinkBytes = [int64]$ShrinkMB * 1MB
    $newCSize = $cPart.Size - $shrinkBytes

    if ($shrinkBytes -gt ($cPart.Size - $supported.SizeMin)) {
        throw "Cannot shrink ${sysLetter}: by $ShrinkMB MB. Min partition size is $([math]::Round($supported.SizeMin/1GB,1)) GB; current $([math]::Round($cPart.Size/1GB,1)) GB; max shrinkable $([math]::Round(($cPart.Size-$supported.SizeMin)/1GB,1)) GB. Free space on ${sysLetter}: or move pagefile/hibernation file to allow more shrink."
    }

    # 2. Free space on disk after shrink (for new partition placement)
    $disk = Get-Disk -Number $cPart.DiskNumber
    if ($disk.PartitionStyle -ne 'GPT' -and $disk.PartitionStyle -ne 'MBR') {
        throw "Disk $($disk.Number) has unsupported partition style '$($disk.PartitionStyle)'"
    }

    # 3. Shrink C:
    Set-Step "Shrinking ${sysLetter}: $([math]::Round($cPart.Size/1GB,1))GB -> $([math]::Round($newCSize/1GB,1))GB ..."
    Resize-Partition -DriveLetter $sysLetter -Size $newCSize -ErrorAction Stop
    Log-Ok "${sysLetter}: shrunk by $ShrinkMB MB"

    # 4. Create new partition in freed space, exact size match
    Set-Step "Creating $VolumeLabel partition (${ShrinkMB}MB) on disk $($disk.Number)..."
    $newPart = New-Partition -DiskNumber $disk.Number -Size $shrinkBytes -DriveLetter $DriveLetter -ErrorAction Stop

    # 5. Format NTFS (host wrapper -- VHDX inside carries ext4)
    Format-Volume -DriveLetter $DriveLetter -FileSystem NTFS -NewFileSystemLabel $VolumeLabel `
        -AllocationUnitSize 4096 -Confirm:$false -Force | Out-Null
    Log-Ok "${DriveLetter}: created (${ShrinkMB}MB NTFS, label=$VolumeLabel) -- VHDX inside hosts ext4"

    return "${DriveLetter}:\"
}

function Set-PodmanMachineStorageOn {
    <#
    .SYNOPSIS
        Junction %LOCALAPPDATA%\containers\podman\machine -> $DataRoot\podman\machine
        BEFORE `podman machine init` runs, so MiOS-DEV's VHDX is created on the
        new drive in the first place (no post-hoc move + symlink dance needed).

    .NOTES
        Idempotent: existing junction with the same target is left alone. If a
        real directory already exists at the default path, its contents are
        moved over and the directory replaced with a junction.
    #>
    param([Parameter(Mandatory)][string]$DataRoot)

    $defaultDir = Join-Path $env:LOCALAPPDATA 'containers\podman\machine'
    $targetDir  = Join-Path $DataRoot 'podman\machine'
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    if (Test-Path $defaultDir) {
        $item = Get-Item $defaultDir -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $current = $item.Target -join ''
            if ($current -and ($current -ieq $targetDir -or $current -ieq "\??\$targetDir")) {
                Log-Ok "podman-machine storage already junctioned -> $targetDir"
                return
            }
            # Different target -- remove and re-link
            cmd /c rmdir "`"$defaultDir`"" | Out-Null
        } else {
            # Real directory exists -- move children to target then remove
            Set-Step "Migrating existing podman-machine state to $targetDir ..."
            Get-ChildItem $defaultDir -Force | Move-Item -Destination $targetDir -Force
            Remove-Item $defaultDir -Force -Recurse -ErrorAction SilentlyContinue
        }
    } else {
        $parent = Split-Path $defaultDir -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }

    # Create the junction (cmd's mklink is the standards path for NTFS reparse points)
    cmd /c mklink /J "`"$defaultDir`"" "`"$targetDir`"" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to junction $defaultDir -> $targetDir (mklink exit $LASTEXITCODE)"
    }
    Log-Ok "podman-machine storage junctioned $defaultDir -> $targetDir"
}

function New-BuilderDistro([hashtable]$HW) {
    Set-Step "Initializing $DevDistro ($($HW.Cpus) CPUs / $($HW.RamGB)GB / $($HW.DiskGB)GB disk)"
    # Cap at the OS-reported physical RAM (what podman validates) minus 512 MB safety margin.
    # Nominal $HW.RamGB rounds up from actual hardware, causing podman to reject the request.
    $ramMB = [math]::Max(4096, [math]::Min($HW.OsTotalRamMB - 512, $HW.RamGB * 1024 - 512))

    # Provision the dedicated MiOS data disk (shrink C: by 262144 MB, create
    # NTFS partition for the VHDX) and redirect podman-machine storage onto
    # it BEFORE `podman machine init`. Honors $env:MIOS_DATA_DISK_LETTER and
    # $env:MIOS_DATA_DISK_MB env-var overrides; defaults are M:\ and 262144 MB.
    $diskGB = $HW.DiskGB
    if ($env:MIOS_SKIP_DATA_DISK -notin @('1','true','TRUE','yes')) {
        $shrinkMB    = if ($env:MIOS_DATA_DISK_MB)     { [int]$env:MIOS_DATA_DISK_MB }     else { 262144 }
        $driveLetter = if ($env:MIOS_DATA_DISK_LETTER) { $env:MIOS_DATA_DISK_LETTER }      else { 'M' }
        try {
            $dataRoot = Initialize-MiosDataDisk -ShrinkMB $shrinkMB -DriveLetter $driveLetter -VolumeLabel 'MIOS-DEV'
            Set-PodmanMachineStorageOn -DataRoot $dataRoot
            # Resize VHDX max to fit the new data disk (free GB minus a small
            # safety margin). The $HW.DiskGB default was computed against C:'s
            # free space and would oversubscribe the new partition otherwise.
            $newFreeGB = [math]::Floor((Get-Volume -DriveLetter $driveLetter).SizeRemaining / 1GB)
            $clamped   = [math]::Max(80, [math]::Min($HW.DiskGB, $newFreeGB - 8))
            if ($clamped -ne $HW.DiskGB) {
                Log-Ok "Clamped VHDX max from $($HW.DiskGB) GB to $clamped GB to fit ${driveLetter}: ($newFreeGB GB free)"
                $diskGB = $clamped
            }
        } catch {
            Log-Warn "MiOS data-disk provisioning failed: $_"
            Log-Warn "Continuing with default %LOCALAPPDATA% storage (set MIOS_SKIP_DATA_DISK=1 to silence this)"
        }
    }

    $initSw = [System.Diagnostics.Stopwatch]::StartNew()
    & podman machine init $BuilderDistro `
        --cpus $HW.Cpus --memory $ramMB --disk-size $diskGB `
        --rootful --now 2>&1 | ForEach-Object {
            Write-Log "podman-init: $_"
            if ($initSw.ElapsedMilliseconds -ge 150) {
                $clean = ($_ -replace '\x1b\[[0-9;]*[mGKHFJ]','').Trim()
                if ($clean) { $script:CurStep = $clean.Substring(0,[math]::Min($clean.Length,80)) }
                Show-Dashboard
                $initSw.Restart()
            }
        }
    if ($LASTEXITCODE -ne 0) { throw "podman machine init failed (exit $LASTEXITCODE)" }
    & podman machine set --default $BuilderDistro 2>&1 | Out-Null
    Log-Ok "$DevDistro created and set as default Podman machine"

    # Rootful machine-os distros are not accessible via wsl.exe or podman machine ssh.
    # Build runs from the Windows Podman client via the machine's API -- no exec needed.
    # Just verify the API is up (it should be immediately after --now).
    Set-Step "Verifying $DevDistro Podman API..."
    $deadline = (Get-Date).AddSeconds(30)
    $apiOk = $false
    while ((Get-Date) -lt $deadline) {
        $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
              Where-Object { $_ -match "^$([regex]::Escape($BuilderDistro))\s+true" }
        if ($ml) { $apiOk = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $apiOk) { throw "$BuilderDistro not in running state after 30 s -- check: podman machine ls" }
    Log-Ok "$DevDistro Podman API ready"
    # Overlay seed is invoked once at end of Phase 3 (covers both the
    # newly-created path and the already-running path); see the call
    # site directly above End-Phase 3 in the main flow.
}

function Invoke-MiosOverlaySeed {
    # Seed the full MiOS package surface as a live overlay inside the
    # MiOS-DEV WSL2 distro. Reads PACKAGES.md from the cloned mios.git
    # checkout and runs `dnf5 install` per fenced ```packages-*``` block.
    #
    # Why: every CLI/utility/dev tool that ships in the deployed MiOS
    # OCI image is installed live on the Windows-side dev machine too,
    # so `wsl -d podman-MiOS-DEV` lands the operator in a shell that
    # is package-equivalent to a deployed MiOS host (minus kernel/UEFI
    # which only apply to bare-metal/Hyper-V/QEMU shapes).
    #
    # Idempotent via a sentinel: skip if /var/lib/mios/.overlay-seeded
    # is newer than the source PACKAGES.md.
    Set-Step "Seeding MiOS package overlay onto $DevDistro..."
    $packagesMd = Join-Path $MiosRepoDir "mios\usr\share\mios\PACKAGES.md"
    if (-not (Test-Path $packagesMd)) {
        Log-Warn "PACKAGES.md not found at $packagesMd -- overlay seed skipped"
        return
    }
    $wslDistro = "podman-$DevDistro"

    # Confirm the distro is reachable via wsl.exe (rootful machines on
    # newer Podman builds register as podman-<Name>; older builds may
    # register without prefix -- try both).
    $sshOk = $false
    foreach ($candidate in @($wslDistro, $DevDistro)) {
        $probe = (& wsl.exe -d $candidate --exec bash -c "echo ok" 2>$null) -join ""
        if ($probe.Trim() -eq "ok") { $wslDistro = $candidate; $sshOk = $true; break }
    }
    if (-not $sshOk) {
        Log-Warn "Cannot wsl.exe into $DevDistro -- overlay seed deferred to first manual run"
        return
    }

    # Stage PACKAGES.md + the highest-precedence mios.toml + the overlay
    # installer inside the distro's /tmp. Using `wsl --exec cp` from the
    # Windows path avoids podman-machine-cp's rootful permission quirks.
    # The bash overlay reads [packages.dev_overlay].sections from
    # /tmp/mios.toml -- this is what consolidates the SSOT (no longer
    # blanket-installs every PACKAGES.md section; honors operator's
    # configurator-saved selection).
    $drive = $packagesMd.Substring(0,1).ToLower()
    $packagesWslPath = "/mnt/$drive" + ($packagesMd.Substring(2) -replace '\\','/')

    $tomlSources = @(
        (Join-Path $env:APPDATA "MiOS\mios.toml"),
        (Join-Path $MiosRepoDir "mios-bootstrap\mios.toml"),
        (Join-Path $MiosRepoDir "mios\usr\share\mios\mios.toml")
    )
    $tomlPath = $null
    foreach ($t in $tomlSources) { if (Test-Path $t) { $tomlPath = $t; break } }
    $tomlWslPath = ""
    if ($tomlPath) {
        $td = $tomlPath.Substring(0,1).ToLower()
        $tomlWslPath = "/mnt/$td" + ($tomlPath.Substring(2) -replace '\\','/')
    }

    $overlayScript = @'
#!/usr/bin/env bash
# mios-overlay.sh -- live system overlay seeder for MiOS-DEV.
# Generated by build-mios.ps1 / Invoke-MiosOverlaySeed.
set -uo pipefail

SENTINEL="/var/lib/mios/.overlay-seeded"
SRC_MD="${SRC_MD:-/tmp/PACKAGES.md}"
PACKAGES_MD="/tmp/PACKAGES.lf.md"
LOG_DIR="/tmp/mios-overlay-logs"
mkdir -p "$LOG_DIR" && chmod 0777 "$LOG_DIR"

# Skip if already seeded and PACKAGES.md is older than the sentinel.
if [[ -f "$SENTINEL" && "$SENTINEL" -nt "$SRC_MD" ]]; then
    echo "[mios-overlay] sentinel newer than PACKAGES.md -> skip"
    exit 0
fi

# Normalize CRLF (OneDrive-synced source).
tr -d '\r' < "$SRC_MD" > "$PACKAGES_MD"

# Resolve the dev-overlay section list from the user's mios.toml. The
# layered resolver (highest wins): per-user (~/.config/mios/mios.toml),
# host (/etc/mios/mios.toml), bootstrap clone, vendor (PACKAGES.md
# bootstrap default). The PowerShell side stages the highest-precedence
# layer at $SRC_TOML before invoking us. Falls back to a hardcoded
# minimal list if no [packages.dev_overlay].sections array is present.
SRC_TOML="${SRC_TOML:-/tmp/mios.toml}"
DEFAULT_SECTIONS=(
    base security utils build-toolchain containers
    cockpit storage virt
    gpu-mesa gpu-nvidia gpu-amd-compute gpu-intel-compute
    gnome-flatpak-runtime
    ai sbom-tools self-build network-discovery updater
    cockpit-plugins-build k3s-selinux-build uki
)

# Naive TOML scrape: pull the array under [packages.dev_overlay].sections
# (or [packages].dev_overlay.sections inline form). Tolerates the
# single-line + multi-line array shapes the configurator emits.
parse_sections_from_toml() {
    [[ -r "$SRC_TOML" ]] || return 1
    awk '
        /^\[packages\.dev_overlay\][[:space:]]*$/ { in_block=1; next }
        in_block && /^\[/                        { in_block=0; next }
        in_block && /^[[:space:]]*sections[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "", $0); collecting=1
        }
        collecting {
            print
            if ($0 ~ /\]/) { collecting=0 }
        }
    ' "$SRC_TOML" \
        | tr -d '[]\n' \
        | tr ',' '\n' \
        | sed -E 's/^[[:space:]]*"?([^"#]*)"?[[:space:]]*$/\1/' \
        | sed '/^$/d'
}

mapfile -t SECTIONS < <(parse_sections_from_toml || true)
SECTIONS_SOURCE="mios.toml [packages.dev_overlay]"
if (( ${#SECTIONS[@]} == 0 )); then
    SECTIONS=("${DEFAULT_SECTIONS[@]}")
    SECTIONS_SOURCE="hardcoded minimal default"
fi
echo "[mios-overlay] sections (${#SECTIONS[@]}, from ${SECTIONS_SOURCE}): ${SECTIONS[*]}"

get_pkgs() {
    sed -n "/^\`\`\`packages-${1}$/,/^\`\`\`$/{/^\`\`\`/d;/^$/d;/^#/d;p}" "$PACKAGES_MD"
}

# Add Fedora-version-pinned RPMFusion (free + nonfree).
fedver=$(rpm -E %fedora 2>/dev/null || echo 43)
sudo dnf5 install -y --skip-unavailable \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedver}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedver}.noarch.rpm" \
    >"$LOG_DIR/00-rpmfusion.log" 2>&1 || true

# Hard always-skip list. This wins even if the operator typed e.g.
# "kernel" into mios.toml -- those sections are WSL-incompatible or
# anti-pattern fences and refusing them is the right move.
ALWAYS_SKIP_RE='^(kernel|boot|moby|bloat|critical)$'

install_section() {
    local sec="$1"
    [[ "$sec" =~ $ALWAYS_SKIP_RE ]] && { echo "[mios-overlay] SKIP $sec (always-skipped)"; return; }
    local pkgs
    pkgs=$(get_pkgs "$sec" | tr '\n' ' ')
    [[ -z "${pkgs// }" ]] && { echo "[mios-overlay] EMPTY $sec"; return; }
    echo "[mios-overlay] INSTALL $sec"
    # shellcheck disable=SC2086
    sudo dnf5 install -y --skip-unavailable --skip-broken --allowerasing \
        $pkgs >"$LOG_DIR/$sec.log" 2>&1
    # rc=1 from terminal systemd scriptlets is benign on podman-machine
    # WSL distros that lack a live system D-Bus -- packages still land.
}

# Foundation (repos must be first), then user-selected sections.
install_section repos
for sec in "${SECTIONS[@]}"; do
    [[ "$sec" == "repos" ]] && continue
    install_section "$sec"
done

# Critical safe-subset (skip kernel-core/gdm/libvirt on WSL).
echo "[mios-overlay] INSTALL critical (WSL-safe subset)"
sudo dnf5 install -y --skip-unavailable --skip-broken --allowerasing \
    bootc chrony cockpit firewalld NetworkManager pipewire tuned \
    >"$LOG_DIR/critical.log" 2>&1 || true

sudo install -d -m 0755 /var/lib/mios
sudo touch "$SENTINEL"

# Install a wrapper at /usr/local/bin/mios-dev-seed so the operator can
# re-run the overlay manually inside the dev distro after editing
# PACKAGES.md (e.g. `wsl -d podman-MiOS-DEV -- sudo mios-dev-seed`).
sudo install -d -m 0755 /usr/local/bin
sudo install -m 0755 /tmp/mios-overlay.sh /usr/local/bin/mios-dev-seed

# Drop a profile.d hint so `wsl -d podman-MiOS-DEV` greets the operator
# with the dev-VM context. Quiet for non-interactive shells.
sudo tee /etc/profile.d/mios-dev-motd.sh >/dev/null <<'PROFILE'
# MiOS-DEV operator hint -- only on interactive shells.
if [[ -n "${PS1-}" && -t 1 ]]; then
    pkgs=$(rpm -qa | wc -l 2>/dev/null || echo ?)
    echo "MiOS-DEV (Podman-WSL2 dev VM, $pkgs pkgs)  --  refresh: sudo mios-dev-seed"
fi
PROFILE
sudo chmod 0644 /etc/profile.d/mios-dev-motd.sh

echo "[mios-overlay] done -- $(rpm -qa | wc -l) packages installed"
echo "[mios-overlay] manual refresh: sudo mios-dev-seed"
'@

    # Materialize the script + a copy of PACKAGES.md inside the distro
    # via stdin; avoids cross-FS quoting headaches and works for both
    # /mnt/c-mounted paths and rootful machines.
    # CRLF -> LF: PowerShell @'...'@ here-strings produce CRLF on
    # Windows; without normalization the bash shebang becomes
    # "#!/usr/bin/env bash\r" -> "env: 'bash\r': No such file or
    # directory" -> the entire overlay silently no-ops on the dev VM.
    $overlayScript = $overlayScript -replace "`r`n", "`n" -replace "`r", "`n"
    $b64Script = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($overlayScript))
    $stageToml = ""
    if ($tomlWslPath) {
        $stageToml = "cp '$tomlWslPath' /tmp/mios.toml; "
    }
    $stage = "set -e; sudo install -d -m 0777 /tmp; " +
             "echo '$b64Script' | base64 -d > /tmp/mios-overlay.sh && chmod +x /tmp/mios-overlay.sh; " +
             "cp '$packagesWslPath' /tmp/PACKAGES.md; " +
             $stageToml +
             "/tmp/mios-overlay.sh"
    & wsl.exe -d $wslDistro --exec bash -c $stage 2>&1 | ForEach-Object { Write-Log "overlay-seed: $_" }
    if ($LASTEXITCODE -ne 0) {
        Log-Warn "overlay seed exited rc=$LASTEXITCODE -- partial install possible (packages may still be present; rerun safe)"
    } else {
        Log-Ok "MiOS package overlay seeded into $DevDistro"
    }
}

function Invoke-MiosQuadletOverlay {
    # Mirror the MiOS FHS overlay (Quadlets, systemd units, sysusers,
    # tmpfiles, libexec, profile.d, /etc/mios config templates) onto the
    # dev distro so MiOS-DEV runs the same container surface as a deployed
    # MiOS host. After this:
    #   - Podman Desktop (Windows) sees mios-cockpit-link, mios-forge, etc.
    #     under the MiOS-DEV machine connection -- each carries
    #     io.podman_desktop.openInBrowser labels for one-click access.
    #   - Cockpit on the dev VM (https://localhost:9090, mirrored networking)
    #     renders the same containers + system services as a deployed host.
    #
    # Idempotent via /var/lib/mios/.quadlet-overlay-seeded; re-runs are no-ops
    # unless the source mios.git Containerfile has been touched since the
    # sentinel. Set MIOS_SKIP_DEV_QUADLETS=1 to bypass entirely.
    if ($env:MIOS_SKIP_DEV_QUADLETS -in @('1','true','TRUE','yes')) {
        Log-Warn "MIOS_SKIP_DEV_QUADLETS set -- Quadlet overlay skipped"
        return
    }

    Set-Step "Overlaying MiOS Quadlets + systemd units onto $DevDistro..."
    $miosRoot = Join-Path $MiosRepoDir "mios"
    if (-not (Test-Path (Join-Path $miosRoot "Containerfile"))) {
        Log-Warn "mios.git checkout missing at $miosRoot -- Quadlet overlay skipped"
        return
    }
    $wslDistro = "podman-$DevDistro"
    $sshOk = $false
    foreach ($candidate in @($wslDistro, $DevDistro)) {
        $probe = (& wsl.exe -d $candidate --exec bash -c "echo ok" 2>$null) -join ""
        if ($probe.Trim() -eq "ok") { $wslDistro = $candidate; $sshOk = $true; break }
    }
    if (-not $sshOk) { Log-Warn "Cannot wsl.exe into $DevDistro -- Quadlet overlay deferred"; return }

    # Convert C:\path\to\mios -> /mnt/c/path/to/mios for the WSL side.
    $drive = $miosRoot.Substring(0,1).ToLower()
    $miosRootWsl = "/mnt/$drive" + ($miosRoot.Substring(2) -replace '\\','/')

    $enableAi     = if ($env:MIOS_DEV_ENABLE_AI     -in @('1','true','TRUE','yes')) { '1' } else { '0' }
    $enableRunner = if ($env:MIOS_DEV_ENABLE_RUNNER -in @('1','true','TRUE','yes')) { '1' } else { '0' }

    $overlayScript = @'
#!/usr/bin/env bash
# mios-quadlet-overlay.sh -- mirror MiOS FHS overlay into MiOS-DEV.
# Generated by build-mios.ps1 / Invoke-MiosQuadletOverlay.
set -uo pipefail

SRC="${1:?source mios.git path required}"
SENTINEL="/var/lib/mios/.quadlet-overlay-seeded"

# Skip if sentinel is newer than the source mios.git's Containerfile
# (cheap proxy for "has the source tree changed since last overlay").
if [[ -f "$SENTINEL" && "$SENTINEL" -nt "$SRC/Containerfile" ]]; then
    echo "[quadlet-overlay] sentinel newer than mios.git -> skip"
    exit 0
fi

echo "[quadlet-overlay] mirroring FHS overlay from $SRC ..."

# Build a deterministic list of paths to mirror via a single tar pipe.
# Each find branch is best-effort -- a missing source is simply absent
# from the list, so the script no-ops on stripped checkouts rather than
# erroring out.
LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
{
    cd "$SRC" || exit 1
    find etc/containers/systemd                                 -type f 2>/dev/null
    find usr/share/containers/systemd                           -type f 2>/dev/null
    find usr/lib/systemd/system            -maxdepth 1          -name 'mios-*' 2>/dev/null
    find usr/lib/systemd/system            -mindepth 2          -name '*mios*.conf' -path '*.service.d/*' 2>/dev/null
    find usr/lib/systemd/system            -mindepth 2          -name '*.conf' -path 'usr/lib/systemd/system/dbus-broker.service.d/*' 2>/dev/null
    find usr/lib/systemd/journald.conf.d                        -name '*mios*' 2>/dev/null
    find usr/lib/sysusers.d                                     -name '*mios*' 2>/dev/null
    find usr/lib/tmpfiles.d                                     -name '*mios*' 2>/dev/null
    find usr/libexec/mios                                       -type f 2>/dev/null
    find etc/profile.d                                          -name '*mios*' 2>/dev/null
    for d in etc/mios/forge etc/mios/ai etc/mios/system-prompts; do
        find "$d" -type f 2>/dev/null
    done
} | sort -u > "$LIST"

count=$(wc -l < "$LIST")
echo "[quadlet-overlay] $count files to mirror"

if (( count == 0 )); then
    echo "[quadlet-overlay] nothing to mirror -- mios.git tree may be stripped"
    exit 0
fi

# Single tar pipe: preserves perms/ownership in archive, extracts onto /
# under sudo so root-owned destinations (e.g. /etc/mios/) work.
sudo tar -C "$SRC" -cf - --files-from="$LIST" 2>/dev/null \
    | sudo tar -C / -xf - 2>&1 \
    | grep -vE '^tar:' || true

# Realize sysusers + tmpfiles, then reload systemd so the new units
# (and Quadlet-generated *.service files) are visible.
echo "[quadlet-overlay] realizing sysusers / tmpfiles / daemon-reload ..."
sudo systemd-sysusers 2>&1 | tail -3 || true
sudo systemd-tmpfiles --create 2>&1 | tail -3 || true
sudo systemctl daemon-reload 2>&1 | tail -3 || true

# ALWAYS-ON LIGHTWEIGHT SET: Cockpit (web console at :9090), the
# Podman-Desktop discovery shim that surfaces MiOS containers in PD's
# UI, and the self-hosted Forgejo forge (small SQLite-backed git host).
# Plus NVIDIA CDI plumbing (mios-cdi-detect + nvidia-cdi-refresh) so
# Podman containers on MiOS-DEV can claim /dev/dxg (WSL2 GPU surface)
# via the same Container Device Interface spec a deployed bare-metal
# MiOS host uses. mios-cdi-detect.service auto-no-ops when no GPU is
# present (no /dev/nvidia0 / no /dev/dxg) and explicitly passes
# --mode=wsl to `nvidia-ctk cdi generate` when systemd-detect-virt
# reports wsl, so it works correctly on the dev VM out of the box.
# Each enable is best-effort -- a unit that ConditionVirtualization-skips
# itself just no-ops with status=inactive (success).
LIGHT_SET=(cockpit.socket mios-cockpit-link.service mios-forge.service \
           mios-cdi-detect.service nvidia-cdi-refresh.path)
for svc in "${LIGHT_SET[@]}"; do
    if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
        echo "[quadlet-overlay] enable --now $svc"
        sudo systemctl enable --now "$svc" 2>&1 | grep -vE 'created symlink' || true
    else
        echo "[quadlet-overlay] skip $svc (unit not present -- pkg may be missing)"
    fi
done

# OPT-IN HEAVY SET: AI inference + Forgejo Runner. Gated by env vars
# threaded through from the PowerShell side -- defaults to skip so
# the dev VM doesn't pull multi-GB images on first boot.
if [[ "${MIOS_DEV_ENABLE_AI:-0}" == "1" ]]; then
    echo "[quadlet-overlay] enable --now mios-ai + ollama (heavy)"
    sudo systemctl enable --now mios-ai.service ollama.service 2>&1 | grep -vE 'created symlink' || true
fi
if [[ "${MIOS_DEV_ENABLE_RUNNER:-0}" == "1" ]]; then
    echo "[quadlet-overlay] enable --now mios-forgejo-runner (heavy)"
    sudo systemctl enable --now mios-forgejo-runner.service 2>&1 | grep -vE 'created symlink' || true
fi

# Install the operator-facing terminal flatpak so MiOS-DEV mirrors a
# deployed MiOS host's UX: open Ptyxis on the Windows desktop via WSLg
# -> default tab spawns into the host shell via flatpak-spawn --host
# -> the operator types `ollama list`, `mios "..."`, `mios-ollama chat
# "..."` and hits the Ollama Quadlet on :11434 + LocalAI on :8080
# directly. Idempotent (--or-update). Also pulls the few other
# substrate-class flatpaks (Nautilus, Bazaar, Flatseal) so the
# emulated MiOS environment carries its file manager and app store.
echo "[quadlet-overlay] installing GNOME Flatpaks for WSLg portal (one-time, ~600MB)..."
flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
# Substrate-class Flatpaks: terminal, file manager, app store, Flatpak
# permissions UI, default browser. Each routes through WSLg as a Windows
# desktop window; the gnome-flatpak-runtime RPM section provides the
# host-side portals/audio/theming these need to render correctly.
for ref in org.gnome.Ptyxis \
           org.gnome.Nautilus \
           io.github.kolunmi.Bazaar \
           com.github.tchx84.Flatseal \
           org.gnome.Epiphany; do
    if ! flatpak list --system --app --columns=application 2>/dev/null | grep -qx "$ref"; then
        flatpak install --system --noninteractive --assumeyes --or-update flathub "$ref" \
            2>&1 | grep -E '^(Installing|Updating|Already|Error|Warning)' || true
    fi
done

sudo install -d -m 0755 /var/lib/mios
sudo touch "$SENTINEL"

active=$(systemctl --no-legend list-units 'mios-*' 2>/dev/null | wc -l)
echo "[quadlet-overlay] done -- $active mios-* units active"
echo "[quadlet-overlay] Cockpit:        https://localhost:9090/  (host LAN reachable via mirrored networking)"
echo "[quadlet-overlay] Podman Desktop: containers under MiOS-DEV machine carry openInBrowser labels"
echo "[quadlet-overlay] Terminal:       Ptyxis flatpak ready -- launch via WSLg, default tab is host shell"
echo "[quadlet-overlay] Ollama:         set MIOS_DEV_ENABLE_AI=1 then re-run for the local Ollama Quadlet"
'@

    # CRLF -> LF (see Invoke-MiosOverlaySeed for the rationale).
    $overlayScript = $overlayScript -replace "`r`n", "`n" -replace "`r", "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($overlayScript))
    $stage = "set -e; export MIOS_DEV_ENABLE_AI='$enableAi' MIOS_DEV_ENABLE_RUNNER='$enableRunner'; " +
             "echo '$b64' | base64 -d > /tmp/mios-quadlet-overlay.sh && chmod +x /tmp/mios-quadlet-overlay.sh; " +
             "/tmp/mios-quadlet-overlay.sh '$miosRootWsl'"
    & wsl.exe -d $wslDistro --exec bash -c $stage 2>&1 | ForEach-Object { Write-Log "quadlet-overlay: $_" }
    if ($LASTEXITCODE -ne 0) {
        Log-Warn "Quadlet overlay rc=$LASTEXITCODE -- partial overlay possible (units may still be present; rerun safe)"
    } else {
        Log-Ok "MiOS Quadlet overlay applied to $DevDistro"
    }
}

function Invoke-GhcrLogin([string]$Token) {
    if ([string]::IsNullOrWhiteSpace($Token)) {
        Write-Log "ghcr-login: no token (set MIOS_GITHUB_TOKEN or provide one in phase 6)"
        return
    }
    Set-Step "Authenticating podman to ghcr.io..."
    $Token | & podman login ghcr.io --username "mios-dev" --password-stdin 2>&1 |
        ForEach-Object { Write-Log "ghcr-login: $_" }
    if ($LASTEXITCODE -eq 0) { Log-Ok "Authenticated to ghcr.io" }
    else { Log-Warn "ghcr.io login failed -- build may fail pulling base image" }
}

function Invoke-WindowsPodmanBuild([string]$BaseImage, [string]$MiosUser, [string]$MiosHostname,
                                   [string]$AiModel = "qwen2.5-coder:7b",
                                   [string]$EmbedModel = "nomic-embed-text",
                                   [string]$BakeModels = "qwen2.5-coder:7b,nomic-embed-text") {
    $repoPath = Join-Path $MiosRepoDir "mios"

    # ── Universal MiOS-SEED merge ────────────────────────────────────────────
    # Overlay mios-bootstrap onto mios.git BEFORE invoking podman build so the
    # build context contains both layers. Without this, only mios.git's tree
    # is in the build context and bootstrap-owned files (etc/skel/.config/mios/,
    # etc/mios/profile.toml, mios.toml at root, agent entry-point .md files)
    # never reach the OCI image -- WSL/bootc deploys would diverge from the
    # Linux Total-Root-Merge path. seed-merge.ps1 is the canonical PowerShell
    # implementation; seed-merge.sh is its bash twin invoked from build-mios.sh.
    $bootstrapPath = Join-Path $MiosRepoDir "mios-bootstrap"
    $seedScript    = Join-Path $bootstrapPath "seed-merge.ps1"
    if (Test-Path $seedScript) {
        Set-Step "Universal MiOS-SEED: overlay mios-bootstrap onto mios.git"
        try {
            & $seedScript -MiosDir $repoPath -BootstrapDir $bootstrapPath
            Log-Ok "Bootstrap overlay merged into build context (mios.git tree)"
        } catch {
            Log-Warn "seed-merge failed: $_"
            Log-Warn "Build will proceed with mios.git tree only -- bootstrap files (skel, mios.toml, agent .md) will NOT be in the OCI image"
        }
    } else {
        Log-Warn "seed-merge.ps1 not found at $seedScript -- skipping Universal SEED merge"
    }

    Set-Step "podman build (Windows client → $BuilderDistro)"
    Write-Log "BUILD START (Windows API build)  base=$BaseImage  user=$MiosUser  host=$MiosHostname  ai=$AiModel"

    # Run via cmd.exe so 2>&1 merges stderr (podman build progress) into stdout stream.
    # Build args propagate operator selections from the Phase-6 prompts
    # (or layered mios.toml [ai] defaults) into the Containerfile ARGs of
    # the same name. 37-ollama-prep.sh reads MIOS_OLLAMA_BAKE_MODELS to
    # decide which model set to bake into /usr/share/ollama/models.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "cmd.exe"
    $psi.Arguments = ("/c podman build --progress=plain --no-cache " +
                      "--build-arg `"BASE_IMAGE=$BaseImage`" " +
                      "--build-arg `"MIOS_USER=$MiosUser`" " +
                      "--build-arg `"MIOS_HOSTNAME=$MiosHostname`" " +
                      "--build-arg `"MIOS_FLATPAKS=`" " +
                      "--build-arg `"MIOS_AI_MODEL=$AiModel`" " +
                      "--build-arg `"MIOS_AI_EMBED_MODEL=$EmbedModel`" " +
                      "--build-arg `"MIOS_OLLAMA_BAKE_MODELS=$BakeModels`" " +
                      "-t localhost/mios:latest . 2>&1")
    $psi.WorkingDirectory       = $repoPath
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $false
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        # Write to detail log only -- no Write-Host here.
        # Printing raw build lines to the console scrolls the terminal buffer
        # and drifts the dashboard position on every tick.
        try { [System.IO.File]::AppendAllText($BuildDetailLog, $line + "`n", [Text.Encoding]::UTF8) } catch {}
        Update-BuildSubPhase $line
        if ($sw.ElapsedMilliseconds -ge 150) { Show-Dashboard; $sw.Restart() }
    }
    $proc.WaitForExit()
    Write-Log "BUILD END (Windows)  exit=$($proc.ExitCode)  lines=$($script:LineCount)"
    return $proc.ExitCode
}

function Invoke-WslBuild([string]$Distro, [string]$BaseImage, [string]$AiModel,
                          [string]$MiosUser = "mios", [string]$MiosHostname = "mios",
                          [string]$EmbedModel = "nomic-embed-text",
                          [string]$BakeModels = "") {
    if ([string]::IsNullOrWhiteSpace($BakeModels)) {
        $BakeModels = "$AiModel,$EmbedModel"
    }
    # Authenticate to ghcr.io before any pull/build.  GHCR now returns 403 on
    # anonymous bearer-token requests for ublue-os images; a GitHub PAT is required.
    $tok = if ($env:MIOS_GITHUB_TOKEN) { $env:MIOS_GITHUB_TOKEN }
           elseif ($env:GITHUB_TOKEN)  { $env:GITHUB_TOKEN }
           else                         { $script:GhcrToken }
    Invoke-GhcrLogin -Token $tok

    # Detect access method: wsl.exe > podman machine ssh > Windows podman build
    $useWsl      = $false
    $useSsh      = $false
    $useWinBuild = $false
    try {
        $r = (& wsl.exe -d $Distro --exec bash -c "echo ok" 2>$null) -join ""
        if ($r.Trim() -eq "ok") { $useWsl = $true }
    } catch {}
    if (-not $useWsl) {
        try {
            $r = (& podman machine ssh $Distro -- bash -c "echo ok" 2>$null) -join ""
            if ($r.Trim() -eq "ok") { $useSsh = $true }
        } catch {}
    }
    if (-not $useWsl -and -not $useSsh) { $useWinBuild = $true }

    if ($useWinBuild) {
        return Invoke-WindowsPodmanBuild -BaseImage $BaseImage -MiosUser $MiosUser -MiosHostname $MiosHostname `
                                          -AiModel $AiModel -EmbedModel $EmbedModel -BakeModels $BakeModels
    }

    $justCheck = "command -v just &>/dev/null || dnf install -y just"
    if ($useSsh) {
        & podman machine ssh $Distro -- bash -c $justCheck 2>$null | Out-Null
    } else {
        & wsl.exe -d $Distro --user root --exec bash -c $justCheck 2>$null | Out-Null
    }

    # ── Universal MiOS-SEED merge (inside WSL distro) ─────────────────────────
    # Sync-RepoToDistro brought mios.git into / via `git fetch + reset --hard`.
    # That path strips untracked files, so we can't pre-merge on the Windows
    # side -- the merge has to happen INSIDE WSL after the sync, before
    # `just build` invokes podman build. Clone mios-bootstrap into
    # /tmp/mios-bootstrap, run seed-merge.sh against /, then build.
    Set-Step "Universal MiOS-SEED: overlay mios-bootstrap onto / inside $Distro"
    $bootstrapRepoUrl = if ($env:MIOS_BOOTSTRAP_REPO) { $env:MIOS_BOOTSTRAP_REPO } else { $MiosBootstrapUrl }
    $bootstrapRef     = if ($env:MIOS_BOOTSTRAP_REF)  { $env:MIOS_BOOTSTRAP_REF  } else { "main" }
    $seedScript = @"
set -e
if [ ! -d /tmp/mios-bootstrap/.git ]; then
    rm -rf /tmp/mios-bootstrap
    git clone --depth=1 --branch '$bootstrapRef' '$bootstrapRepoUrl' /tmp/mios-bootstrap
fi
if [ -x /tmp/mios-bootstrap/seed-merge.sh ]; then
    /tmp/mios-bootstrap/seed-merge.sh / /tmp/mios-bootstrap
else
    echo '[seed-merge] WARN: /tmp/mios-bootstrap/seed-merge.sh not found -- bootstrap overlay skipped' >&2
fi
"@
    if ($useSsh) {
        & podman machine ssh $Distro -- bash -c $seedScript 2>&1 | ForEach-Object { Write-Log "seed-merge: $_" }
    } else {
        & wsl.exe -d $Distro --user root --exec bash -c $seedScript 2>&1 | ForEach-Object { Write-Log "seed-merge: $_" }
    }
    if ($LASTEXITCODE -eq 0) {
        Log-Ok "Bootstrap overlay merged into WSL distro / (Universal MiOS-SEED)"
    } else {
        Log-Warn "seed-merge inside ${Distro} returned non-zero -- build will proceed; bootstrap files may be missing from the image"
    }

    Set-Step "Launching: just build (inside $Distro)"
    Write-Log "BUILD START  base=$BaseImage  model=$AiModel"

    # Stream build output line-by-line: update dashboard Step, write to log
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($useSsh) {
        $psi.FileName  = "podman"
        $psi.Arguments = "machine ssh $Distro -- bash -c " +
                         "'cd / && MIOS_BASE_IMAGE=''$BaseImage'' MIOS_AI_MODEL=''$AiModel'' just build 2>&1'"
    } else {
        $psi.FileName  = "wsl.exe"
        $psi.Arguments = "-d $Distro --user root --cd / --exec bash -c " +
                         "'MIOS_BASE_IMAGE=''$BaseImage'' MIOS_AI_MODEL=''$AiModel'' just build 2>&1'"
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $false
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()

    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        try { [System.IO.File]::AppendAllText($BuildDetailLog, $line + "`n", [Text.Encoding]::UTF8) } catch {}
        Update-BuildSubPhase $line
        if ($sw.ElapsedMilliseconds -ge 150) { Show-Dashboard; $sw.Restart() }
    }

    $proc.WaitForExit()
    $rc = $proc.ExitCode
    Write-Log "BUILD END (WSL/SSH)  exit=$rc  lines=$($script:LineCount)"
    return $rc
}

function Export-WslTar([string]$OutFile) {
    # Stream localhost/mios:latest filesystem from machine → Windows tar via podman socket API
    Set-Step "Creating container snapshot of localhost/mios:latest..."
    $contLines = (& podman create localhost/mios:latest /bin/true 2>$null)
    $contId = ($contLines | Where-Object { $_ -match '^[0-9a-f]{12,64}$' } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($contId)) {
        $contId = ($contLines | Select-Object -Last 1)
    }
    if ([string]::IsNullOrWhiteSpace($contId)) { throw "podman create returned no container ID" }
    $contId = $contId.Trim()
    Write-Log "export container: $contId"
    try {
        Set-Step "Streaming container filesystem → $([System.IO.Path]::GetFileName($OutFile))..."
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = "podman"
        $psi.Arguments              = "export $contId"
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $fs   = [System.IO.File]::Create($OutFile)
        $sw   = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $buf    = New-Object byte[] 65536
            $stream = $proc.StandardOutput.BaseStream
            while ($true) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $fs.Write($buf, 0, $n)
                if ($sw.ElapsedMilliseconds -ge 2000) {
                    $mb = [math]::Round($fs.Length / 1MB)
                    Set-Step "Exporting WSL2 tar... ${mb} MB"
                    $sw.Restart()
                }
            }
        } finally { $fs.Close() }
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "podman export exited $($proc.ExitCode)" }
        return $true
    } finally {
        & podman rm $contId 2>$null | Out-Null
    }
}

function Import-MiosWsl([string]$TarFile, [string]$InstallDir) {
    # Register WSL2 distro from tar (replaces existing 'MiOS' distro if present)
    if (-not (Test-Path $TarFile)) { throw "WSL2 tar not found: $TarFile" }
    try { & wsl.exe --unregister $MiosWslDistro 2>$null | Out-Null } catch {}
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    Set-Step "wsl --import $MiosWslDistro ..."
    & wsl.exe --import $MiosWslDistro $InstallDir $TarFile --version 2 2>&1 |
        ForEach-Object { Write-Log "wsl-import: $_" }
    if ($LASTEXITCODE -ne 0) { throw "wsl --import exited $LASTEXITCODE" }
    # Set default user in the new distro
    try {
        & wsl.exe -d $MiosWslDistro --user root --exec bash -c `
            "id mios &>/dev/null && echo '[user]\ndefault=mios' >> /etc/wsl.conf || true" 2>$null | Out-Null
    } catch {}
    return $true
}

function Invoke-BibBuild([string[]]$Types, [string]$MachineOutDir, [int]$TimeoutMin = 60) {
    # Run bootc-image-builder inside the machine via Windows podman API (→ machine socket)
    # Types: 'qcow2', 'raw', 'anaconda-iso', 'vmdk'
    $typeArgs = ($Types | ForEach-Object { "--type $_" }) -join " "
    Set-Step "BIB: $($Types -join '+')..."
    Write-Log "BIB start: types=$($Types -join ',')  out=$MachineOutDir"

    # Pre-create the output directory on the BUILDER MACHINE filesystem.
    # podman volume bind-mounts require the host-side path to exist before
    # the container starts; otherwise crun fails with `statfs ENOENT`.
    # CRITICAL: must run via `podman machine ssh` -- running `mkdir` inside
    # a transient alpine container only creates the dir in the container's
    # ephemeral fs, which evaporates before the BIB container starts.
    Set-Step "BIB: creating output dir on builder machine..."
    $machineName = if ($env:MIOS_BUILDER_MACHINE) { $env:MIOS_BUILDER_MACHINE } else { $DevDistro.ToLower() }
    & podman machine ssh $machineName -- "sudo mkdir -p '$MachineOutDir' && sudo chmod 0755 '$MachineOutDir'" 2>&1 |
        ForEach-Object { Write-Log "bib-mkdir: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "WARN: 'podman machine ssh ... mkdir' returned $LASTEXITCODE -- BIB will likely fail with statfs ENOENT"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "cmd.exe"
    $psi.Arguments = ("/c podman run --rm --privileged --pull=newer " +
        "--security-opt label=type:unconfined_t " +
        "-v /var/lib/containers/storage:/var/lib/containers/storage " +
        "-v ${MachineOutDir}:/output:z " +
        "quay.io/centos-bootc/bootc-image-builder:latest " +
        "$typeArgs --local localhost/mios:latest 2>&1")
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $done = $false
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        Write-Log "bib: $line"
        if ($sw.ElapsedMilliseconds -ge 2000) {
            $elapsed = [math]::Floor($timer.Elapsed.TotalMinutes)
            Set-Step "BIB ${elapsed}min: $($line.Substring(0,[math]::Min($line.Length,60)))"
            $sw.Restart()
        }
        if ($timer.Elapsed.TotalMinutes -ge $TimeoutMin) {
            Write-Log "WARN: BIB timeout after ${TimeoutMin}min -- killing"
            $proc.Kill()
            break
        }
    }
    $proc.WaitForExit()
    Write-Log "BIB end: exit=$($proc.ExitCode)"
    return $proc.ExitCode -eq 0
}

function Copy-FromMachine([string]$MachinePath, [string]$WinDest) {
    # podman machine cp MiOS-DEV:/path/in/machine C:\windows\path
    Set-Step "Copying $([System.IO.Path]::GetFileName($MachinePath)) from machine..."
    & podman machine cp "${BuilderDistro}:${MachinePath}" $WinDest 2>&1 |
        ForEach-Object { Write-Log "machine-cp: $_" }
    return ($LASTEXITCODE -eq 0)
}

function New-MiosHyperVVm([string]$RawPath, [int]$RamGB = 8) {
    if (-not (Get-Command New-VM -EA SilentlyContinue)) {
        Write-Log "Hyper-V module not available -- skipping VM creation"
        return $false
    }
    # Convert raw → vhdx if Convert-VHD is available
    $vhdxPath = [System.IO.Path]::ChangeExtension($RawPath, ".vhdx")
    if (Get-Command Convert-VHD -EA SilentlyContinue) {
        Set-Step "Converting raw → vhdx..."
        try {
            Convert-VHD -Path $RawPath -DestinationPath $vhdxPath -VHDType Dynamic -EA Stop
        } catch {
            Write-Log "Convert-VHD failed: $_ -- trying raw rename"
            $vhdxPath = [System.IO.Path]::ChangeExtension($RawPath, ".vhd")
            Copy-Item $RawPath $vhdxPath -Force
        }
    } else {
        # Raw can be used as a fixed VHD by Hyper-V if renamed .vhd
        $vhdxPath = [System.IO.Path]::ChangeExtension($RawPath, ".vhd")
        Copy-Item $RawPath $vhdxPath -Force
    }
    if (-not (Test-Path $vhdxPath)) { throw "VHDX/VHD not found after conversion" }

    # Remove existing VM if present
    $vmName = $MiosWslDistro
    try { Remove-VM -Name $vmName -Force -EA SilentlyContinue } catch {}

    Set-Step "Creating Hyper-V VM: $vmName..."
    $vm = New-VM -Name $vmName -MemoryStartupBytes ($RamGB * 1GB) `
                 -VHDPath $vhdxPath -Generation 2 -EA Stop
    Set-VMFirmware  -VMName $vmName -EnableSecureBoot Off
    Set-VMProcessor -VMName $vmName -Count ([math]::Max(2, [int]([Environment]::ProcessorCount / 2)))
    Set-VMMemory    -VMName $vmName -DynamicMemoryEnabled $true `
                    -MinimumBytes 2GB -MaximumBytes ($RamGB * 1GB)
    Log-Ok "Hyper-V VM '$vmName' created from $([System.IO.Path]::GetFileName($vhdxPath))"
    return $true
}

function Invoke-DeployPipeline([hashtable]$HW) {
    $artifactDir = Join-Path $MiosDistroDir "artifacts"
    $wslFsDir    = Join-Path $MiosDistroDir "MiOS"
    if (-not (Test-Path $artifactDir)) { New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null }
    if (-not (Test-Path $wslFsDir))    { New-Item -ItemType Directory -Path $wslFsDir    -Force | Out-Null }

    # ── Phase 10: Export WSL2 tar ──────────────────────────────────────────────
    Start-Phase 10
    $wslTar = Join-Path $artifactDir "mios-wsl2.tar"
    $wslOk  = $false
    try {
        $wslOk = Export-WslTar -OutFile $wslTar
        $sizeMB = [math]::Round((Get-Item $wslTar).Length / 1MB)
        Log-Ok "WSL2 tar: ${sizeMB}MB → $wslTar"
        End-Phase 10
    } catch {
        Log-Warn "WSL2 export: $_"
        End-Phase 10 -Warn
    }

    # ── Phase 11: Register WSL2 distro ────────────────────────────────────────
    Start-Phase 11
    if ($wslOk) {
        try {
            $null = Import-MiosWsl -TarFile $wslTar -InstallDir $wslFsDir
            Log-Ok "WSL2 distro '$MiosWslDistro' registered at $wslFsDir"
            End-Phase 11
        } catch {
            Log-Warn "WSL2 import: $_"
            End-Phase 11 -Warn
        }
    } else {
        Log-Warn "Skipped (no WSL2 tar)"
        End-Phase 11 -Warn
    }

    # ── Phase 12: BIB disk images (qcow2 + raw) ───────────────────────────────
    Start-Phase 12
    $bibMachineDir = "/tmp/mios-bib-output"
    $bibOk = $false
    try {
        $bibOk = Invoke-BibBuild -Types @('qcow2','raw') -MachineOutDir $bibMachineDir
        if ($bibOk) {
            # Copy artifacts from machine to Windows
            $cpOk = @{}
            foreach ($pair in @(
                @{ src="$bibMachineDir/qcow2/disk.qcow2"; dst=Join-Path $artifactDir "mios.qcow2" },
                @{ src="$bibMachineDir/image/disk.raw";   dst=Join-Path $artifactDir "mios.raw"   }
            )) {
                try {
                    $cpOk[$pair.dst] = Copy-FromMachine $pair.src $pair.dst
                    if ($cpOk[$pair.dst]) {
                        $sz = [math]::Round((Get-Item $pair.dst).Length / 1GB, 1)
                        Log-Ok "$([System.IO.Path]::GetFileName($pair.dst)): ${sz}GB"
                    }
                } catch { Write-Log "WARN: copy $($pair.src): $_" }
            }
            End-Phase 12
        } else {
            Log-Warn "BIB build failed (non-fatal -- OCI image still available in $BuilderDistro)"
            End-Phase 12 -Warn
        }
    } catch {
        Log-Warn "BIB phase: $_"
        End-Phase 12 -Warn
    }

    # ── Phase 13: Hyper-V VM from raw disk ────────────────────────────────────
    Start-Phase 13
    $rawPath = Join-Path $artifactDir "mios.raw"
    if ($bibOk -and (Test-Path $rawPath)) {
        try {
            $vmOk = New-MiosHyperVVm -RawPath $rawPath -RamGB ([math]::Max(4, [math]::Min($HW.RamGB / 2, 16)))
            if ($vmOk) { End-Phase 13 } else { Log-Warn "Hyper-V not available"; End-Phase 13 -Warn }
        } catch {
            Log-Warn "Hyper-V VM: $_"
            End-Phase 13 -Warn
        }
    } else {
        Log-Warn "Skipped (no raw disk image)"
        End-Phase 13 -Warn
    }
}

function New-Shortcut([string]$Path,[string]$Target,[string]$Args="",[string]$Desc="",[string]$Dir="") {
    $ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath = $Target
    if ($Args) { $sc.Arguments = $Args }
    if ($Desc) { $sc.Description = $Desc }
    if ($Dir)  { $sc.WorkingDirectory = $Dir }
    $sc.Save()
}

# =============================================================================
# MAIN -- wrapped so the window NEVER closes on error
# =============================================================================
$ExitCode = 0
try {

# ── Banner (printed before dashboard so it doesn't scroll under it) ───────────
Clear-Host
$b = "+" + ("=" * ($script:DW - 2)) + "+"
$pad = [math]::Max(0, $script:DW - 4 - "MiOS $MiosVersion  --  Unified Windows Installer".Length)
Write-Host $b                                                                       -ForegroundColor Cyan
Write-Host ("| 'MiOS' $MiosVersion  --  Unified Windows Installer" + (" " * $pad) + " |") -ForegroundColor Cyan
Write-Host ("| Immutable Fedora AI Workstation" + (" " * ($script:DW - 34)) + " |") -ForegroundColor Cyan
Write-Host ("| WSL2 + Podman  |  Offline Build Pipeline" + (" " * ($script:DW - 43)) + " |") -ForegroundColor Cyan
Write-Host $b                                                                       -ForegroundColor Cyan
Write-Host ""

# Capture the row where the dashboard will be drawn (right after banner)
$script:DashRow = try { [Console]::CursorTop } catch { 0 }

# ── Background heartbeat -- keeps spinner animating independently ──────────────
# Runs on a dedicated runspace so the operator always sees spinner movement.
# A frozen spinner means a true fault/hang/timeout, not just a slow operation.
$script:BgRs = [runspacefactory]::CreateRunspace()
$script:BgRs.Open()
$script:BgRs.SessionStateProxy.SetVariable('dashSync', $script:DashSync)
$script:BgPs = [powershell]::Create()
$script:BgPs.Runspace = $script:BgRs
$null = $script:BgPs.AddScript({
    # Background spinner heartbeat. Writes a single character at
    # (SpinnerRow, SpinnerCol) every 120 ms so the operator sees the
    # script is still alive even when the main render loop is blocked
    # on a long sub-process.
    #
    # Race protection: dashSync.Rendering is set to $true by the main
    # thread immediately before Show-Dashboard writes its rows, and
    # cleared afterwards. The heartbeat skips its write while that
    # flag is set, which prevents the previous spinner-bleed bug
    # where the heartbeat stamped a "/" or "-" into a separator row
    # that had just been drawn over the row the spinner used to occupy.
    $chars = @('|', '/', '-', [char]92)
    $i = 0
    while ($dashSync.Running) {
        [System.Threading.Thread]::Sleep(120)
        if ($dashSync.Rendering) { continue }
        $row = $dashSync.SpinnerRow
        $col = $dashSync.SpinnerCol
        if ($row -ge 0) {
            try {
                $prevTop = [Console]::CursorTop
                $prevLeft = [Console]::CursorLeft
                [Console]::SetCursorPosition($col, $row)
                [Console]::Write($chars[$i % 4])
                [Console]::SetCursorPosition($prevLeft, $prevTop)
            } catch {}
            $i++
        }
    }
})
$script:BgHandle = $script:BgPs.BeginInvoke()

Show-Dashboard   # draw initial (all phases pending)

# ── Phase 0 -- Hardware + Prerequisites ──────────────────────────────────────
Start-Phase 0
$HW = Get-Hardware
Write-Log "hw: CPU=$($HW.Cpus)  RAM=$($HW.RamGB)GB  Disk=$($HW.DiskGB)GB  GPU=$($HW.GpuName)"
Write-Log "hw: Base=$($HW.BaseImage)  Model=$($HW.AiModel)"
$gpuShort = $HW.GpuName -replace 'NVIDIA GeForce ','RTX ' -replace 'NVIDIA Quadro ','Quadro '
$script:HWInfo    = "Host:$($env:COMPUTERNAME)  RAM:$($HW.RamGB)GB  CPU:$($HW.Cpus)c  GPU:$gpuShort  Base:$($HW.BaseImage -replace 'ghcr.io/ublue-os/ucore-hci:','')"
$script:IdentInfo = "Base:$($HW.BaseImage -replace 'ghcr.io/ublue-os/ucore-hci:','')  Model:$($HW.AiModel)"
Show-Dashboard

$preOk = $true
if (Get-Command git    -EA SilentlyContinue) { Log-Ok "Git $((& git --version 2>&1) -replace 'git version ','')" }
else { Log-Fail "Git not found -- winget install Git.Git"; $preOk = $false }
if (Get-Command wsl    -EA SilentlyContinue) { Log-Ok "WSL2 available" }
else { Log-Warn "WSL2 not found -- run: wsl --install" }
if (Get-Command podman -EA SilentlyContinue) { Log-Ok "Podman $((& podman --version 2>&1) -replace 'podman version ','')" }
else { Log-Warn "Podman not found -- winget install RedHat.Podman-Desktop" }

if (-not $preOk) { End-Phase 0 -Fail; throw "Prerequisites missing -- see log: $LogFile" }
End-Phase 0

# ── Phase 1 -- Detecting existing build environment ──────────────────────────
Start-Phase 1
$activeDistro = Find-ActiveDistro

if ($activeDistro) {
    Log-Ok "MiOS repo found in $activeDistro"
    $miosRepo = Join-Path $MiosRepoDir "mios"
    if (Test-Path (Join-Path $miosRepo ".git")) {
        Set-Step "Pulling Windows-side repo and syncing to $activeDistro"
        Push-Location $miosRepo
        try { git pull --ff-only -q 2>&1 | Out-Null } catch {}
        Pop-Location
        Sync-RepoToDistro -Distro $activeDistro -WinPath $miosRepo | Out-Null
        Log-Ok "Repo synced to $activeDistro"
    }
    End-Phase 1
    # Skip phases 2-8, go straight to build
    for ($s = 2; $s -le 8; $s++) {
        $script:PhStat[$s] = 2
        $script:PhStart[$s] = [datetime]::Now
        $script:PhEnd[$s]   = [datetime]::Now
    }
    Show-Dashboard

    # Collect GHCR token in rebuild path (phase 6 is skipped above).
    $script:GhcrToken = if ($env:MIOS_GITHUB_TOKEN) { $env:MIOS_GITHUB_TOKEN }
                        elseif ($env:GITHUB_TOKEN)   { $env:GITHUB_TOKEN }
                        else { Read-Line "GitHub PAT for ghcr.io base image pull" "" }

    Start-Phase 9
    $rc = Invoke-WslBuild -Distro $activeDistro -BaseImage $HW.BaseImage -AiModel $HW.AiModel
    if ($rc -eq 0) {
        End-Phase 9
        Invoke-DeployPipeline -HW $HW
    } else { End-Phase 9 -Fail; $ExitCode = $rc }
} else {

    if ($BuildOnly) { End-Phase 1 -Fail; throw "-BuildOnly: no 'MiOS' build environment found. Run without -BuildOnly first." }
    Log-Ok "No existing distro -- starting full install"
    End-Phase 1

    # ── Phase 2 -- Directories and repos ─────────────────────────────────────
    Start-Phase 2
    Write-Log "install scope: $MiosScope  install dir: $MiosInstallDir  programdata: $MiosProgramData"
    foreach ($d in @(
        $MiosInstallDir, $MiosRepoDir, $MiosBinDir, $MiosShareDir,
        $MiosProgramData, $MiosDistroDir, $MiosImagesDir, $MiosMachineCfg,
        $MiosConfigDir, $MiosDataDir, $MiosLogDir
    )) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    Log-Ok "Directories under $MiosInstallDir ($MiosScope scope)"

    foreach ($r in @(
        @{ Path=(Join-Path $MiosRepoDir "mios");           Url=$MiosRepoUrl;      Name="mios.git" },
        @{ Path=(Join-Path $MiosRepoDir "mios-bootstrap"); Url=$MiosBootstrapUrl; Name="mios-bootstrap.git" }
    )) {
        if (Test-Path (Join-Path $r.Path ".git")) {
            Set-Step "Updating $($r.Name)"
            Push-Location $r.Path; try { git pull --ff-only -q 2>&1 | Out-Null } catch {}; Pop-Location
        } else {
            Set-Step "Cloning $($r.Name)"
            git clone --depth 1 $r.Url $r.Path 2>&1 | Out-Null
        }
        Log-Ok $r.Name
    }

    # ── Materialize bootstrap files into the install dir ─────────────────────
    # Both repos are cloned into $MiosRepoDir, but a "native Windows app"
    # install also exposes the bootstrap-side templates and entry scripts
    # under predictable, non-git-shaped paths so Windows tooling, shortcuts,
    # and the uninstaller don't have to traverse a .git working tree.
    #
    #   $MiosBinDir                     entry-point .ps1 scripts (Get-MiOS, build-mios, uninstall)
    #   $MiosShareDir\bootstrap\etc     mios-bootstrap/etc tree (skel templates, mios.toml)
    #   $MiosShareDir\bootstrap\usr     mios-bootstrap/usr tree (system overlay templates)
    #   $MiosShareDir\system\usr        mios.git/usr tree (factory FHS overlay; read-only ref)
    #
    # robocopy is used over Copy-Item so we get incremental sync semantics
    # (only changed files re-copy on re-run). /MIR mirrors content + deletes
    # stale files; /NJH /NJS suppress the header/summary so output stays terse.
    Set-Step "Materializing bootstrap files into install dir"
    $bootstrapSrc = Join-Path $MiosRepoDir "mios-bootstrap"
    $miosSrc      = Join-Path $MiosRepoDir "mios"
    $copyPairs = @(
        @{ Src=(Join-Path $bootstrapSrc "etc"); Dst=(Join-Path $MiosShareDir "bootstrap\etc") },
        @{ Src=(Join-Path $bootstrapSrc "usr"); Dst=(Join-Path $MiosShareDir "bootstrap\usr") },
        @{ Src=(Join-Path $miosSrc      "usr"); Dst=(Join-Path $MiosShareDir "system\usr")    }
    )
    foreach ($p in $copyPairs) {
        if (Test-Path $p.Src) {
            $null = New-Item -ItemType Directory -Path $p.Dst -Force -ErrorAction SilentlyContinue
            & robocopy $p.Src $p.Dst /MIR /NJH /NJS /NFL /NDL /NP 2>&1 | Out-Null
        }
    }
    # Stage entry-point scripts under $MiosBinDir so Start Menu shortcuts
    # and PATH integration target a stable, non-git location.
    foreach ($script in @("Get-MiOS.ps1","build-mios.ps1","build-mios.sh","bootstrap.ps1","bootstrap.sh")) {
        $srcFile = Join-Path $bootstrapSrc $script
        if (Test-Path $srcFile) {
            Copy-Item -Path $srcFile -Destination (Join-Path $MiosBinDir $script) -Force
        }
    }
    # Drop a VERSION marker at the install root so external tools (and the
    # operator) can identify the installed release without a git query.
    Set-Content -Path (Join-Path $MiosInstallDir "VERSION") -Value $MiosVersion -Encoding ASCII -Force
    Log-Ok "Bootstrap files materialized under $MiosShareDir"
    End-Phase 2

    # ── Phase 3 -- MiOS-DEV distro (formerly MiOS-BUILDER) ───────────────────
    Start-Phase 3
    $machineRunning = $false
    # Check via Podman API first (covers rootful machine-os distros inaccessible via wsl.exe).
    # Accept BOTH the canonical "MiOS-DEV" and the legacy "MiOS-BUILDER" names so existing
    # installs don't get redundantly recreated. If only the legacy name is found we adopt it
    # in-place by re-pointing $BuilderDistro -- the operator can `podman machine rm` and
    # re-run for the canonical name.
    try {
        $names = @($DevDistro, $LegacyDevName)
        foreach ($n in $names) {
            $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
                  Where-Object { $_ -match "^$([regex]::Escape($n))\s+true" }
            if ($ml) {
                if ($n -eq $LegacyDevName) {
                    Log-Warn "Detected legacy machine '$LegacyDevName' -- reusing in place. Rename: 'podman machine rm $LegacyDevName' then re-run."
                    $script:BuilderDistro = $n
                }
                $machineRunning = $true
                break
            }
        }
    } catch {}
    # Also accept a stopped machine and start it
    if (-not $machineRunning) {
        try {
            $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
                  Where-Object { $_ -match "^$([regex]::Escape($BuilderDistro))" }
            if ($ml) {
                Set-Step "Starting existing $BuilderDistro machine..."
                $startOut = @(& podman machine start $BuilderDistro 2>&1)
                $startOut | ForEach-Object { Write-Log "podman-start: $_" }
                if ($LASTEXITCODE -eq 0) {
                    $machineRunning = $true; Log-Ok "$BuilderDistro started"
                } elseif (($startOut -join " ") -match "DISTRO_NOT_FOUND|bootstrap script failed|WSL_E_DISTRO") {
                    # Stale Podman machine metadata -- WSL distro was deleted but Podman registry entry remains.
                    # Force-remove the stale entry so New-BuilderDistro can re-init cleanly.
                    Write-Log "podman-start: stale machine registration detected -- removing $BuilderDistro" "WARN"
                    & podman machine rm --force $BuilderDistro 2>&1 | ForEach-Object { Write-Log "podman-rm: $_" }
                }
            }
        } catch {}
    }
    # Legacy: accept wsl.exe-accessible distro too ('MiOS' already applied)
    if (-not $machineRunning) {
        try {
            $r = (& wsl.exe -d $BuilderDistro --exec bash -c "echo ok" 2>$null) -join ""
            if ($r.Trim() -eq "ok") { $machineRunning = $true }
        } catch {}
    }

    if ($machineRunning) {
        Log-Ok "$BuilderDistro already running"
    } else {
        New-BuilderDistro -HW $HW
    }

    # Run the overlay seed regardless of whether the machine was just created or
    # was already running. Idempotent via /var/lib/mios/.overlay-seeded -- a
    # second pass is a no-op when PACKAGES.md hasn't changed since last seed.
    # This is what catches the re-run case (operator runs build-mios.ps1 again
    # after editing PACKAGES.md): every section delta gets installed live.
    Invoke-MiosOverlaySeed

    # Quadlet/systemd overlay -- copies the MiOS FHS overlay into MiOS-DEV and
    # enables the lightweight container set (cockpit.socket, mios-cockpit-link,
    # mios-forge). Heavy services (mios-ai, mios-forgejo-runner) are opt-in via
    # MIOS_DEV_ENABLE_AI=1 / MIOS_DEV_ENABLE_RUNNER=1. Idempotent via
    # /var/lib/mios/.quadlet-overlay-seeded sentinel.
    Invoke-MiosQuadletOverlay

    End-Phase 3

    # ── Phase 4 -- WSL2 .wslconfig ───────────────────────────────────────────
    Start-Phase 4
    $wslCfg = Join-Path $env:USERPROFILE ".wslconfig"

    # Required keys -- always ensure these are present regardless of existing config.
    # Mirrored networking + localhostForwarding are essential for Cockpit (port 9090)
    # and general WSL2 → Windows host reachability.
    $requiredKeys = [ordered]@{
        memory              = "$($HW.RamGB)GB"
        processors          = "$($HW.Cpus)"
        swap                = "4GB"
        localhostForwarding = "true"
        networkingMode      = "mirrored"
        guiApplications     = "true"
    }

    $cfgRaw = if (Test-Path $wslCfg) { Get-Content $wslCfg -Raw } else { "" }

    if ($cfgRaw -notmatch "\[wsl2\]") {
        # No [wsl2] section at all -- append one wholesale
        $block = "`n[wsl2]`n# MiOS-managed -- host resources for MiOS-DEV`n"
        foreach ($kv in $requiredKeys.GetEnumerator()) { $block += "$($kv.Key)=$($kv.Value)`n" }
        Add-Content -Path $wslCfg -Value $block
        Log-Ok ".wslconfig: wrote [wsl2] -- $($HW.RamGB)GB RAM, $($HW.Cpus) CPUs, mirrored"
    } else {
        # [wsl2] exists -- patch each required key in place; append missing ones
        $lines    = (Get-Content $wslCfg)
        $inWsl2   = $false
        $patched  = [System.Collections.Generic.List[string]]::new()
        $inserted = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($line in $lines) {
            if ($line -match "^\[wsl2\]") { $inWsl2 = $true }
            elseif ($line -match "^\[")   { $inWsl2 = $false }

            if ($inWsl2 -and $line -match "^(\w+)\s*=") {
                $key = $Matches[1]
                if ($requiredKeys.Contains($key)) {
                    $patched.Add("$key=$($requiredKeys[$key])")
                    $null = $inserted.Add($key)
                    continue
                }
            }
            $patched.Add($line)

            # After [wsl2] header, inject any keys not yet seen in the section
            if ($line -match "^\[wsl2\]") {
                foreach ($kv in $requiredKeys.GetEnumerator()) {
                    if (-not $inserted.Contains($kv.Key)) {
                        # We will add them below after scanning the full section;
                        # set a sentinel so the post-loop block fires once.
                    }
                }
            }
        }

        # Append any required keys that never appeared in [wsl2]
        $missing = $requiredKeys.Keys | Where-Object { -not $inserted.Contains($_) }
        if ($missing) {
            # Find insertion point: after [wsl2] header line
            $insertIdx = ($patched | Select-String -Pattern "^\[wsl2\]" | Select-Object -First 1).LineNumber
            $offset = 0
            foreach ($key in $missing) {
                $patched.Insert($insertIdx + $offset, "$key=$($requiredKeys[$key])")
                $offset++
            }
        }

        Set-Content -Path $wslCfg -Value $patched -Encoding UTF8
        Log-Ok ".wslconfig: merged [wsl2] -- $($HW.RamGB)GB RAM, $($HW.Cpus) CPUs, mirrored"
    }
    End-Phase 4

    # ── Phase 5 -- Verify Windows build context ──────────────────────────────
    # Build runs via 'podman build' from the Windows clone -- no machine exec needed.
    Start-Phase 5
    $repoPath = Join-Path $MiosRepoDir "mios"
    if (Test-Path (Join-Path $repoPath "Containerfile")) {
        Log-Ok "Build context ready at $repoPath"
    } else {
        throw "mios.git Containerfile missing at $repoPath -- re-run without -BuildOnly to reclone"
    }
    End-Phase 5

    # ── Optional GUI configurator (between Phase 5 and Phase 6) ──────────────
    # Operator can pre-fill mios.toml fields via the HTML page; the
    # Phase-6 prompts that follow then default to whatever was saved.
    # Skipped when -Unattended or MIOS_NO_CONFIGURATOR=1.
    Open-Configurator -RepoDir $MiosRepoDir

    # ── Phase 6 -- Identity ───────────────────────────────────────────────────
    Start-Phase 6
    $script:CurStep = "Waiting for identity input..."
    Show-Dashboard
    # Re-resolve mios.toml [ai] defaults after the configurator step so
    # the prompts seed from whatever the operator saved in the GUI.
    $aiDefaultsPre = Resolve-MiosTomlAiDefaults -RepoDir $MiosRepoDir
    $MiosUser     = Read-Line "Linux username" "mios"
    $MiosHostname = Read-Line "Hostname"       "mios"
    $pwPlain      = Read-Password "Password"
    if ([string]::IsNullOrWhiteSpace($pwPlain)) { $pwPlain = "mios" }
    $MiosHash     = Get-PasswordHash $pwPlain
    # GitHub PAT is required to pull ghcr.io/ublue-os/ucore-hci (GHCR anon bearer token returns 403).
    # Check env first; fall back to prompt so interactive installs work without pre-setting the var.
    $script:GhcrToken = if ($env:MIOS_GITHUB_TOKEN) { $env:MIOS_GITHUB_TOKEN }
                        elseif ($env:GITHUB_TOKEN)   { $env:GITHUB_TOKEN }
                        else { Read-Line "GitHub PAT for ghcr.io base image pull (github.com/settings/tokens)" "" }
    $tokStatus = if ($script:GhcrToken) { "provided (masked)" } else { "none -- anonymous pull (may fail)" }

    # AI model selection (feature parity with build-mios.sh:prompt_model).
    # Defaults seed from the layered mios.toml [ai] section so per-host
    # overrides flow through automatically; Get-Hardware's RAM-driven
    # suggestion is used as the fallback if mios.toml didn't supply one.
    $aiDefaults = Resolve-MiosTomlAiDefaults -RepoDir $MiosRepoDir
    $defaultModel = if ($aiDefaults.Model) { $aiDefaults.Model } else { $HW.AiModel }
    $MiosAiModel       = Read-Model -Default $defaultModel
    $MiosAiEmbedModel  = Read-Line "AI embedding model" $aiDefaults.EmbedModel
    $MiosOllamaBakeModels = "$MiosAiModel,$MiosAiEmbedModel"

    Log-Ok "Identity: user=$MiosUser  host=$MiosHostname  password=(hashed)  ghcr=$tokStatus  ai=$MiosAiModel"
    $script:IdentInfo = "User:$MiosUser  Host:$MiosHostname  Base:$($HW.BaseImage -replace 'ghcr.io/ublue-os/ucore-hci:','')  Model:$MiosAiModel"
    End-Phase 6

    # ── Phase 7 -- Write identity ─────────────────────────────────────────────
    Start-Phase 7
    $envContent = @"
MIOS_USER="$MiosUser"
MIOS_HOSTNAME="$MiosHostname"
MIOS_USER_PASSWORD_HASH="$MiosHash"
MIOS_AI_MODEL="$MiosAiModel"
MIOS_AI_EMBED_MODEL="$MiosAiEmbedModel"
MIOS_OLLAMA_BAKE_MODELS="$MiosOllamaBakeModels"
"@.Trim()
    $writeCmd  = "mkdir -p /etc/mios && cat > /etc/mios/install.env && chmod 0640 /etc/mios/install.env"
    $written = $false

    # Try wsl.exe (works when machine runs 'MiOS' after bootc switch)
    $envContent | & wsl.exe -d $BuilderDistro --user root --exec bash -c $writeCmd 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $written = $true }

    # Try podman machine ssh (works for some machine configurations)
    if (-not $written) {
        $envContent | & podman machine ssh $BuilderDistro -- bash -c $writeCmd 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $written = $true }
    }

    # Fallback: write via privileged container that mounts the machine's host filesystem.
    # Rootful machine-os exposes / to privileged containers via -v /:/host.
    if (-not $written) {
        Set-Step "Writing identity via privileged container..."
        $envContent | & podman run --rm -i --privileged --security-opt label=disable `
            -v /:/host:z `
            docker.io/library/alpine:latest `
            sh -c "mkdir -p /host/etc/mios && cat > /host/etc/mios/install.env && chmod 0640 /host/etc/mios/install.env" `
            2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $written = $true }
    }

    if ($written) { Log-Ok "/etc/mios/install.env written" } `
    else { Log-Warn "install.env write failed (non-fatal -- firstboot will use default identity; set MIOS_* vars manually)" }
    End-Phase 7

    # ── Phase 8 -- App registration + Start Menu ──────────────────────────────
    Start-Phase 8
    $pwsh      = if (Get-Command pwsh -EA SilentlyContinue) { (Get-Command pwsh).Source } else { "powershell.exe" }
    # Entry-point scripts live under $MiosBinDir (materialized in Phase 2).
    # Prefer build-mios.ps1 (current canonical entry); fall back to the
    # legacy install.ps1 redirector if an old install is being re-run.
    $selfSc    = if (Test-Path (Join-Path $MiosBinDir "build-mios.ps1")) {
                     Join-Path $MiosBinDir "build-mios.ps1"
                 } else {
                     Join-Path $MiosRepoDir "mios-bootstrap\install.ps1"
                 }
    $uninstSc  = Join-Path $MiosBinDir "uninstall.ps1"
    $uninstCmd = "$pwsh -ExecutionPolicy Bypass -File `"$uninstSc`""

    if (-not (Test-Path $UninstallRegKey)) { New-Item -Path $UninstallRegKey -Force | Out-Null }
    @{
        DisplayName="MiOS - Immutable Fedora AI Workstation"; DisplayVersion=$MiosVersion
        Publisher="MiOS-DEV"; InstallLocation=$MiosInstallDir
        UninstallString=$uninstCmd; QuietUninstallString="$uninstCmd -Quiet"
        URLInfoAbout="https://github.com/mios-dev/mios"
        InstallScope=$MiosScope
        NoModify=[int]1; NoRepair=[int]1
    }.GetEnumerator() | ForEach-Object {
        $regType = if ($_.Value -is [int]) { "DWord" } else { "String" }
        Set-ItemProperty -Path $UninstallRegKey -Name $_.Key -Value $_.Value -Type $regType
    }

    if (-not (Test-Path $StartMenuDir)) { New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null }
    @(
        @{ F="MiOS Setup.lnk";         T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$selfSc`"";            D="Re-run full 'MiOS' setup" },
        @{ F="MiOS Build.lnk";         T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$selfSc`" -BuildOnly";  D="Pull latest + build 'MiOS' OCI image" },
        @{ F="MiOS Terminal.lnk";        T="wsl.exe"; A="-d $MiosWslDistro";                                    D="Open 'MiOS' workstation terminal" },
        @{ F="MiOS Dev Shell.lnk";     T="wsl.exe"; A="-d podman-$DevDistro --user root";                      D="Open $DevDistro terminal (root)" },
        @{ F="MiOS Podman Shell.lnk";  T=$pwsh;     A="-NoProfile -Command podman machine ssh $DevDistro";    D="SSH into $DevDistro Podman machine" },
        @{ F="Uninstall MiOS.lnk";     T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$uninstSc`"";           D="Remove MiOS" }
    ) | ForEach-Object { New-Shortcut (Join-Path $StartMenuDir $_.F) $_.T $_.A $_.D $MiosInstallDir }
    Log-Ok "Add/Remove Programs + Start Menu created"

    # Uninstaller script. Removes the install dir + machine-wide
    # ProgramData state + Start Menu + registry entry + Podman/WSL2
    # distros. Preserves per-user config ($MiosConfigDir) so re-installs
    # pick up the operator's last identity.
    $B = $BuilderDistro
    @"
#Requires -Version 5.1
param([switch]`$Quiet)
`$I='$($MiosInstallDir-replace"'","''")'
`$P='$($MiosProgramData-replace"'","''")'
`$D='$($MiosDataDir-replace"'","''")'
`$C='$($MiosConfigDir-replace"'","''")'
`$S='$($StartMenuDir-replace"'","''")'
`$K='$($UninstallRegKey-replace"'","''")'
`$B='$B'
`$M='$MiosWslDistro'
if (-not `$Quiet) {
    Write-Host ''; Write-Host '  ''MiOS'' Uninstaller' -ForegroundColor Red; Write-Host ''
    Write-Host "  Removes: `$I, `$P, `$D, ``$B`` + ``$M`` (Podman + WSL2 distros), Start Menu"
    Write-Host "  Preserves: `$C (per-user config)"; Write-Host ''
    if ((Read-Host "  Type 'yes' to confirm") -ne 'yes') { Write-Host '  Aborted.'; exit 0 }
}
try { podman machine stop `$B 2>`$null } catch {}
try { podman machine rm -f `$B 2>`$null } catch {}
try { wsl --unregister `$B 2>`$null } catch {}
try { wsl --unregister `$M 2>`$null } catch {}
foreach (`$p in @(`$I,`$P,`$D,`$S)) { if (Test-Path `$p) { Remove-Item `$p -Recurse -Force -ErrorAction SilentlyContinue } }
if (Test-Path `$K) { Remove-Item `$K -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''; Write-Host "  'MiOS' removed. Per-user config at `$C preserved." -ForegroundColor Green
"@ | Set-Content $uninstSc -Encoding UTF8
    Log-Ok "uninstall.ps1 written"
    End-Phase 8

    # ── Phase 9 -- Build ──────────────────────────────────────────────────────
    Start-Phase 9
    # Pass the operator-chosen model selection (Phase 6 prompt) through
    # to the build so 37-ollama-prep.sh bakes the right pair into
    # /usr/share/ollama/models. MIOS_AI_MODEL takes precedence over the
    # hardware-driven default in Get-Hardware.
    $rc = Invoke-WslBuild -Distro $BuilderDistro -BaseImage $HW.BaseImage `
                          -AiModel $MiosAiModel -EmbedModel $MiosAiEmbedModel `
                          -BakeModels $MiosOllamaBakeModels `
                          -MiosUser $MiosUser -MiosHostname $MiosHostname
    if ($rc -eq 0) {
        End-Phase 9
        Invoke-DeployPipeline -HW $HW
    } else { End-Phase 9 -Fail; $ExitCode = $rc }

} # end full-install branch

} catch {
    $ExitCode = 1   # set FIRST -- must be reached even if Show-Dashboard below also fails
    $errMsg = "$_"
    Write-Log "FATAL: $errMsg" "ERROR"
    $script:CurStep = "FATAL: $($errMsg.Substring(0,[math]::Min($errMsg.Length,120)))"
    if ($script:CurPhase -ge 0 -and $script:PhStat[$script:CurPhase] -eq 1) {
        try { End-Phase $script:CurPhase -Fail } catch {}
    }
    Show-Dashboard
} finally {
    # Always show final summary and keep window open
    try { [Console]::SetCursorPosition(0, $script:DashRow + $script:DashHeight) } catch {}

    $totalTime = fmtSpan ([datetime]::Now - $script:ScriptStart)
    Write-Host ""
    $b = "+" + ("=" * ($script:DW - 2)) + "+"
    if ($ExitCode -eq 0) {
        $artifactDir = Join-Path $MiosDistroDir "artifacts"
        Write-Host $b -ForegroundColor Green
        $l = "| 'MiOS' $MiosVersion built and deployed!  (total: $totalTime)"
        Write-Host ($l.PadRight($script:DW - 1) + "|") -ForegroundColor Green
        Write-Host ("| OCI   : localhost/mios:latest  in $BuilderDistro".PadRight($script:DW - 1) + "|") -ForegroundColor White
        $wslLine = "| WSL2  : wsl -d $MiosWslDistro"
        $wslDistroOk = (& wsl.exe -l --quiet 2>$null) -join " " -match $MiosWslDistro
        if ($wslDistroOk) {
            Write-Host ($wslLine.PadRight($script:DW - 1) + "|") -ForegroundColor Cyan
        } else {
            Write-Host ("| WSL2  : see $artifactDir\mios-wsl2.tar".PadRight($script:DW - 1) + "|") -ForegroundColor DarkGray
        }
        $qcow2 = Join-Path $artifactDir "mios.qcow2"
        $raw   = Join-Path $artifactDir "mios.raw"
        if (Test-Path $qcow2) { Write-Host ("| QEMU  : $qcow2".PadRight($script:DW - 1) + "|") -ForegroundColor Cyan }
        if (Test-Path $raw)   { Write-Host ("| RAW   : $raw".PadRight($script:DW - 1) + "|") -ForegroundColor Cyan }
        $hvVm = try { Get-VM -Name $MiosWslDistro -EA SilentlyContinue } catch { $null }
        if ($hvVm) { Write-Host ("| HV    : Hyper-V VM '$MiosWslDistro' ready -- Start-VM -Name $MiosWslDistro".PadRight($script:DW - 1) + "|") -ForegroundColor Cyan }
        Write-Host ("| Logs  : $MiosLogDir".PadRight($script:DW - 1) + "|") -ForegroundColor DarkGray
        Write-Host $b -ForegroundColor Green
    } else {
        Write-Host $b -ForegroundColor Red
        Write-Host ("| BUILD FAILED (exit $ExitCode)  --  Errors: $($script:ErrCount)".PadRight($script:DW - 1) + "|") -ForegroundColor Red
        Write-Host ("| Log  : $LogFile".PadRight($script:DW - 1) + "|") -ForegroundColor Yellow
        Write-Host ("| Re-run : podman build --no-cache -t localhost/mios:latest $MiosRepoDir\mios".PadRight($script:DW - 1) + "|") -ForegroundColor DarkGray
        Write-Host $b -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Log directory: $MiosLogDir" -ForegroundColor DarkGray
    Write-Host ""
    if (-not $Unattended) {
        Write-Host "  Press Enter to close..." -ForegroundColor DarkGray -NoNewline
        $null = Read-Host
    }
    # Stop the background heartbeat runspace cleanly before exit. There is
    # no transcript to close (the unified log is written directly via
    # [IO.File]::AppendAllText), so dashboard frames never reach the log.
    try {
        $script:DashSync.Running = $false
        [System.Threading.Thread]::Sleep(200)   # let background loop exit its Sleep(120)
        if ($script:BgPs)  { try { $script:BgPs.Stop() }    catch {}; try { $script:BgPs.Dispose() }  catch {} }
        if ($script:BgRs)  { try { $script:BgRs.Close() }   catch {} }
    } catch {}
    # Merge raw build output (BuildDetailLog) into the unified log so a
    # post-mortem reader has a single file with the full picture.
    if (Test-Path $BuildDetailLog) {
        try {
            [System.IO.File]::AppendAllText($LogFile, "`n`n---- BUILD OUTPUT ----`n", [Text.Encoding]::UTF8)
            $detail = [System.IO.File]::ReadAllText($BuildDetailLog, [Text.Encoding]::UTF8)
            [System.IO.File]::AppendAllText($LogFile, $detail, [Text.Encoding]::UTF8)
            Remove-Item $BuildDetailLog -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    # Inject unified log into OCI image at /usr/share/mios/build-log.txt
    if ($ExitCode -eq 0) {
        try {
            $cid = (& podman create localhost/mios:latest 2>$null) -join ""
            if ($LASTEXITCODE -eq 0 -and $cid.Trim()) {
                $cid = $cid.Trim()
                & podman cp $LogFile "${cid}:/usr/share/mios/build-log.txt" 2>$null
                & podman commit --quiet $cid localhost/mios:latest 2>$null | Out-Null
                & podman rm -f $cid 2>$null | Out-Null
            }
        } catch {}
    }
    exit $ExitCode
}
