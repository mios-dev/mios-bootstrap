#Requires -Version 5.1
# MiOS Unified Installer & Builder -- Windows 11 / PowerShell
#
#   irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1 | iex
#
# Flags:
#   -BuildOnly    Pull latest + build only (skip first-time setup)
#   -Unattended   Accept all defaults, no prompts

param([switch]$BuildOnly, [switch]$Unattended)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ── Paths & constants ─────────────────────────────────────────────────────────
$MiosVersion      = "v0.2.2"
$MiosInstallDir   = Join-Path $env:LOCALAPPDATA "Programs\MiOS"
$MiosRepoDir      = Join-Path $MiosInstallDir "repo"
$MiosDistroDir    = Join-Path $MiosInstallDir "distros"
$MiosConfigDir    = Join-Path $env:APPDATA "MiOS"
$MiosDataDir      = Join-Path $env:LOCALAPPDATA "MiOS"
$MiosLogDir       = Join-Path $MiosDataDir "logs"
$MiosRepoUrl      = "https://github.com/mios-dev/mios.git"
$MiosBootstrapUrl = "https://github.com/mios-dev/mios-bootstrap.git"
$BuilderDistro    = "MiOS-BUILDER"
$LegacyDistro     = "podman-machine-default"
$UninstallRegKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MiOS"
$StartMenuDir     = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\MiOS"

# ── Log file ──────────────────────────────────────────────────────────────────
$null = New-Item -ItemType Directory -Path $MiosLogDir -Force -ErrorAction SilentlyContinue
$LogStamp     = [datetime]::Now.ToString("yyyyMMdd-HHmmss")
$LogFile      = Join-Path $MiosLogDir "mios-install-$LogStamp.log"
$BuildLogFile = Join-Path $MiosLogDir "mios-build-$LogStamp.log"

function Write-Log {
    param([string]$M, [string]$L = "INFO")
    $ts = [datetime]::Now.ToString("HH:mm:ss.fff")
    "[$ts][$L] $M" | Out-File $LogFile -Append -Encoding UTF8 -EA SilentlyContinue
    if ($L -eq "ERROR") { $script:ErrCount++ }
    if ($L -eq "WARN")  { $script:WarnCount++ }
}

# ── Dashboard state ───────────────────────────────────────────────────────────
$script:DW         = [math]::Max(66, [math]::Min(([Console]::WindowWidth - 2), 80))
$script:PhaseNames = @(
    "Hardware + Prerequisites",   # 0
    "Detecting environment",       # 1
    "Directories and repos",       # 2
    "MiOS-BUILDER distro",         # 3
    "WSL2 configuration",          # 4
    "Seeding repo",                # 5
    "Identity",                    # 6
    "Writing identity",            # 7
    "App registration",            # 8
    "Building OCI image"           # 9
)
$script:TotalPhases  = $script:PhaseNames.Count
$script:PhStat       = @(0,0,0,0,0,0,0,0,0,0)   # 0=wait 1=run 2=ok 3=fail 4=warn
$script:PhStart      = @{}
$script:PhEnd        = @{}
$script:CurPhase     = -1
$script:CurStep      = "Starting..."
$script:ErrCount     = 0
$script:WarnCount    = 0
$script:ScriptStart  = [datetime]::Now
$script:DashRow      = 0
$script:DashHeight   = 0
$script:FinalRc      = 0

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

function Show-Dashboard {
    try {
    $w  = [int]$script:DW
    if ($w -lt 66) { $w = 66 }
    $in = $w - 4          # usable inner width (inside "| " and " |")
    $sep = "+" + ("-" * ($w - 2)) + "+"

    $done  = [int]($script:PhStat | Where-Object { $_ -eq 2 } | Measure-Object).Count
    $fail  = [int]($script:PhStat | Where-Object { $_ -eq 3 } | Measure-Object).Count
    $elapsed = [datetime]::Now - $script:ScriptStart
    $elStr   = fmtSpan $elapsed

    $statusStr = if ($fail -gt 0) { "FAILED" } `
                 elseif ($script:CurPhase -ge 0 -and $script:PhStat[$script:CurPhase] -eq 1) { "RUNNING" } `
                 else { "IDLE" }

    $curName = if ($script:CurPhase -ge 0) { [string]$script:PhaseNames[$script:CurPhase] } else { "Initializing" }
    $phLabel = "[$($script:CurPhase)/$($script:TotalPhases-1)] $curName"

    $step = [string]$script:CurStep
    if ($step.Length -gt $in) { $step = $step.Substring(0,$in-3)+"..." }

    $barW   = [math]::Max(10, $in - 12)
    $barStr = pbar $done $script:TotalPhases $barW

    $statStr = "Errors:$($script:ErrCount)  Warns:$($script:WarnCount)  Status:$statusStr"

    # Phase table col widths
    $nameW = [math]::Max(8, $in - 16)

    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add($sep)
    # Header row: title left, elapsed right
    $title = " MiOS $MiosVersion  --  Build Dashboard"
    $right = "[ $elStr ] "
    $mid   = [math]::Max(0, $in - $title.Length - $right.Length + 2)
    $rows.Add("| $title$(' ' * $mid)$right |".PadRight($w-1).Substring(0,$w-1) + "|")
    $rows.Add($sep)
    $rows.Add(("| Ph : " + $phLabel.PadRight($in-6).Substring(0,[math]::Min($phLabel.Length,$in-6)).PadRight($in-6) + " |").PadRight($w))
    $rows.Add(("| Op : " + $step.PadRight($in-6) + " |").PadRight($w))
    $rows.Add(("| " + $statStr.PadRight($in) + " |").PadRight($w))
    $rows.Add($sep)
    $rows.Add(("| " + $barStr.PadRight($in) + " |").PadRight($w))
    $rows.Add($sep)
    # Column headers
    $hdr = "  # State " + "Phase Name".PadRight($nameW) + " Time"
    $rows.Add(("| " + $hdr.PadRight($in) + " |").PadRight($w))
    $div = "--- ----- " + ("-" * $nameW) + " -----"
    $rows.Add(("| " + $div.PadRight($in) + " |").PadRight($w))

    for ($i = 0; $i -lt $script:TotalPhases; $i++) {
        $st = switch ([int]$script:PhStat[$i]) {
            0 { "[ ]  " }
            1 { "[>>] " }
            2 { "[OK] " }
            3 { "[XX] " }
            4 { "[!!] " }
            default { "[??] " }
        }
        $nm = [string]$script:PhaseNames[$i]
        if ($nm.Length -gt $nameW) { $nm = $nm.Substring(0,$nameW-3)+"..." }
        $t = ""
        if ($null -ne $script:PhStart[$i]) {
            try {
                $ps = [datetime]$script:PhStart[$i]
                $pe = if ($null -ne $script:PhEnd[$i]) { [datetime]$script:PhEnd[$i] } else { [datetime]::Now }
                $t = fmtSpan ($pe - $ps)
            } catch { $t = "--:--" }
        }
        $phRow = ("{0,3} {1} {2} {3,5}" -f $i,$st,$nm.PadRight($nameW),$t)
        $rows.Add(("| " + $phRow.PadRight($in) + " |").PadRight($w))
    }
    $rows.Add($sep)
    $logShort = try { Split-Path $LogFile -Leaf } catch { $LogFile }
    $logInner = $in - 5
    if ($logShort.Length -gt $logInner) { $logShort = "..."+$logShort.Substring($logShort.Length-($logInner-3)) }
    $rows.Add(("| Log: " + $logShort.PadRight($logInner) + " |").PadRight($w))
    $rows.Add($sep)

    # Redraw at saved position
    try {
        [Console]::SetCursorPosition(0, $script:DashRow)
        foreach ($row in $rows) {
            if ($row.Length -lt $w) { $row = $row.PadRight($w) }
            elseif ($row.Length -gt $w) { $row = $row.Substring(0,$w) }
            [Console]::Write($row)
            [Console]::Write([Environment]::NewLine)
        }
        $script:DashHeight = $rows.Count
        [Console]::SetCursorPosition(0, $script:DashRow + $script:DashHeight)
    } catch { <# non-interactive / piped -- skip cursor ops #> }

    } catch {
        # Dashboard render error -- log and continue; never let dashboard kill the script
        try { "[$([datetime]::Now.ToString('HH:mm:ss.fff'))][WARN] dashboard render error: $_" | Out-File $LogFile -Append -Encoding UTF8 -EA SilentlyContinue } catch {}
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

function Read-Line([string]$Prompt, [string]$Default = "") {
    [Console]::SetCursorPosition(0, $script:DashRow + $script:DashHeight) 2>$null
    Write-Host "  $Prompt" -NoNewline -ForegroundColor White
    if ($Default) { Write-Host " [$Default]" -NoNewline -ForegroundColor DarkGray }
    Write-Host ": " -NoNewline
    if ($Unattended) { Write-Host $Default -ForegroundColor DarkGray; return $Default }
    $v = Read-Host
    return (([string]::IsNullOrWhiteSpace($v)) ? $Default : $v)
}

function Read-Password([string]$Prompt = "Password") {
    [Console]::SetCursorPosition(0, $script:DashRow + $script:DashHeight) 2>$null
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
    try {
        $h = (& podman run --rm docker.io/library/alpine:latest sh -c "apk add -q openssl && openssl passwd -6 -salt '$salt' '$Plain'" 2>$null) -join ""
        if ($LASTEXITCODE -eq 0 -and $h -match '^\$6\$') { return $h.Trim() }
    } catch {}
    throw "Cannot generate sha512crypt hash — install openssl or run from a distro."
}

function Get-Hardware {
    $ramGB = try { [math]::Round((Get-CimInstance Win32_PhysicalMemory|Measure-Object Capacity -Sum).Sum/1GB) } catch { 16 }
    $cpus  = [Environment]::ProcessorCount
    $gpu   = try { Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Microsoft Basic" } | Select-Object -First 1 } catch { $null }
    $gpuName   = if ($gpu) { $gpu.Name } else { "Unknown" }
    $hasNvidia = $gpuName -match "NVIDIA|GeForce|Quadro|RTX|GTX|Tesla"
    $baseImage = if ($hasNvidia) { "ghcr.io/ublue-os/ucore-hci:stable-nvidia" } else { "ghcr.io/ublue-os/ucore-hci:stable" }
    $aiModel   = if ($ramGB -ge 32) { "qwen2.5-coder:14b" } elseif ($ramGB -ge 12) { "qwen2.5-coder:7b" } else { "phi4-mini:3.8b-q4_K_M" }
    $diskFreeGB    = try { [math]::Floor((Get-PSDrive C -EA Stop).Free/1GB) } catch { 200 }
    $builderDiskGB = [math]::Max(80, $diskFreeGB - 20)
    return @{ RamGB=$ramGB; Cpus=$cpus; GpuName=$gpuName; HasNvidia=$hasNvidia
              BaseImage=$baseImage; AiModel=$aiModel; DiskGB=$builderDiskGB }
}

function Find-ActiveDistro {
    foreach ($d in @($BuilderDistro, $LegacyDistro)) {
        try {
            $r = (& wsl.exe -d $d --exec bash -c "test -f /Justfile && echo ready" 2>$null) -join ""
            if ($r.Trim() -eq "ready") { return $d }
        } catch {}
    }
    return $null
}

function Sync-RepoToDistro([string]$Distro, [string]$WinPath) {
    $wsl = ConvertTo-WslPath $WinPath
    try {
        & wsl.exe -d $Distro --user root --exec bash -c `
            "git -C / fetch 'file://$wsl' main 2>/dev/null && git -C / reset --hard FETCH_HEAD 2>/dev/null"
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function New-BuilderDistro([hashtable]$HW) {
    Set-Step "Initializing MiOS-BUILDER ($($HW.Cpus) CPUs / $($HW.RamGB)GB / $($HW.DiskGB)GB disk)"
    # Reserve 2 GB for the host kernel/BIOS -- physical RAM is always slightly less
    # than the nominal GB count, so allocating RamGB*1024 MB overcommits and fails.
    $ramMB = [math]::Max(4096, $HW.RamGB * 1024 - 2048)
    & podman machine init $BuilderDistro `
        --cpus $HW.Cpus --memory $ramMB --disk-size $HW.DiskGB `
        --rootful --now 2>&1 | ForEach-Object { Write-Log "podman-init: $_" }
    if ($LASTEXITCODE -ne 0) { throw "podman machine init failed (exit $LASTEXITCODE)" }
    & podman machine set --default $BuilderDistro 2>&1 | Out-Null
    Log-Ok "MiOS-BUILDER created and set as default Podman machine"

    # Wait up to 90 s for WSL2 to register the distro (podman machine init --now is async)
    Set-Step "Waiting for $BuilderDistro WSL2 distro to register..."
    $deadline = (Get-Date).AddSeconds(90)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        $r = (& wsl.exe -d $BuilderDistro --exec bash -c "echo ok" 2>$null) -join ""
        if ($r.Trim() -eq "ok") { $ready = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $ready) { throw "$BuilderDistro not accessible after 90 s -- check: wsl --list" }
    Log-Ok "$BuilderDistro WSL2 distro is accessible"

    Set-Step "Installing dev stack (git just podman buildah skopeo openssl python3)"
    $pkgs = "git just podman buildah skopeo openssl python3 fuse-overlayfs shadow-utils podman-compose"
    & wsl.exe -d $BuilderDistro --user root --exec bash -c `
        "dnf install -y --setopt=install_weak_deps=False $pkgs >>$BuildLogFile 2>&1 && dnf clean all >>$BuildLogFile 2>&1"
    Log-Ok "Dev stack installed"

    Set-Step "Installing Ollama (AI runtime)"
    & wsl.exe -d $BuilderDistro --user root --exec bash -c `
        "curl -fsSL https://ollama.com/install.sh | sh >>$BuildLogFile 2>&1 || true"
    Log-Ok "MiOS-BUILDER ready (feature-complete)"
}

function Invoke-WslBuild([string]$Distro, [string]$BaseImage, [string]$AiModel) {
    & wsl.exe -d $Distro --user root --exec bash -c `
        "command -v just &>/dev/null || dnf install -y just >>$BuildLogFile 2>&1"

    Set-Step "Launching: just build (inside $Distro)"
    Write-Log "BUILD START  base=$BaseImage  model=$AiModel"

    # Stream build output line-by-line: update dashboard Step, write to log
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "wsl.exe"
    $psi.Arguments = "-d $Distro --user root --cd / --exec bash -c " +
                     "'MIOS_BASE_IMAGE=''$BaseImage'' MIOS_AI_MODEL=''$AiModel'' just build 2>&1'"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $false
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $lineCount = 0

    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        $line | Out-File $BuildLogFile -Append -Encoding UTF8 -EA SilentlyContinue
        $lineCount++
        # Show last meaningful line in Step (skip blank/separator lines)
        if ($line.Trim() -ne "" -and $line -notmatch '^[-=+]{5,}$') {
            $script:CurStep = "[L$lineCount] " + ($line.TrimStart()).Substring(0, [math]::Min($line.TrimStart().Length, 52))
        }
        # Refresh dashboard at most once per second
        if ($sw.ElapsedMilliseconds -ge 1000) {
            Show-Dashboard
            $sw.Restart()
        }
    }

    $proc.WaitForExit()
    $rc = $proc.ExitCode
    Write-Log "BUILD END  exit=$rc  lines=$lineCount"
    return $rc
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
Write-Host ("| MiOS $MiosVersion  --  Unified Windows Installer" + (" " * $pad) + " |") -ForegroundColor Cyan
Write-Host ("| Immutable Fedora AI Workstation" + (" " * ($script:DW - 34)) + " |") -ForegroundColor Cyan
Write-Host ("| WSL2 + Podman  |  Offline Build Pipeline" + (" " * ($script:DW - 43)) + " |") -ForegroundColor Cyan
Write-Host $b                                                                       -ForegroundColor Cyan
Write-Host ""

# Capture the row where the dashboard will be drawn (right after banner)
$script:DashRow = try { [Console]::CursorTop } catch { 0 }
Show-Dashboard   # draw initial (all phases pending)

# ── Phase 0 -- Hardware + Prerequisites ──────────────────────────────────────
Start-Phase 0
$HW = Get-Hardware
Write-Log "hw: CPU=$($HW.Cpus)  RAM=$($HW.RamGB)GB  Disk=$($HW.DiskGB)GB  GPU=$($HW.GpuName)"
Write-Log "hw: Base=$($HW.BaseImage)  Model=$($HW.AiModel)"

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

    Start-Phase 9
    $rc = Invoke-WslBuild -Distro $activeDistro -BaseImage $HW.BaseImage -AiModel $HW.AiModel
    if ($rc -eq 0) { End-Phase 9 } else { End-Phase 9 -Fail; $ExitCode = $rc }
} else {

    if ($BuildOnly) { End-Phase 1 -Fail; throw "-BuildOnly: no MiOS build environment found. Run without -BuildOnly first." }
    Log-Ok "No existing distro -- starting full install"
    End-Phase 1

    # ── Phase 2 -- Directories and repos ─────────────────────────────────────
    Start-Phase 2
    foreach ($d in @($MiosInstallDir,$MiosRepoDir,$MiosDistroDir,$MiosConfigDir,$MiosDataDir,$MiosLogDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    Log-Ok "Directories under $MiosInstallDir"

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
    End-Phase 2

    # ── Phase 3 -- MiOS-BUILDER distro ───────────────────────────────────────
    Start-Phase 3
    $distroOk = $false
    try {
        $distroOk = ((& wsl.exe -d $BuilderDistro --exec bash -c "echo ok" 2>$null) -join "").Trim() -eq "ok"
    } catch {}

    if ($distroOk) {
        Log-Ok "$BuilderDistro already exists"
    } else {
        New-BuilderDistro -HW $HW
    }
    End-Phase 3

    # ── Phase 4 -- WSL2 .wslconfig ───────────────────────────────────────────
    Start-Phase 4
    $wslCfg = Join-Path $env:USERPROFILE ".wslconfig"
    if ((Test-Path $wslCfg) -and ((Get-Content $wslCfg -Raw) -match "\[wsl2\]")) {
        Log-Ok ".wslconfig already configured"
    } else {
        @"

[wsl2]
# MiOS-managed -- all host resources allocated to MiOS-BUILDER
memory=$($HW.RamGB)GB
processors=$($HW.Cpus)
swap=4GB
localhostForwarding=true
networkingMode=mirrored
guiApplications=true
"@ | Add-Content -Path $wslCfg
        Log-Ok ".wslconfig: $($HW.RamGB)GB RAM, $($HW.Cpus) CPUs, mirrored"
    }
    End-Phase 4

    # ── Phase 5 -- Seed mios.git to / inside MiOS-BUILDER ───────────────────
    Start-Phase 5
    $seeded = $false
    try {
        $seeded = ((& wsl.exe -d $BuilderDistro --exec bash -c "test -f /Justfile && echo y" 2>$null) -join "").Trim() -eq "y"
    } catch {}

    if ($seeded) {
        Set-Step "Already seeded -- syncing from Windows clone"
        Sync-RepoToDistro -Distro $BuilderDistro -WinPath (Join-Path $MiosRepoDir "mios") | Out-Null
        Log-Ok "Repo synced"
    } else {
        Set-Step "Cloning mios.git to / inside MiOS-BUILDER"
        & wsl.exe -d $BuilderDistro --user root --exec bash -c `
            "git init / && git -C / remote add origin '$MiosRepoUrl' && git -C / fetch --depth=1 origin main && git -C / reset --hard FETCH_HEAD" `
            2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "mios.git clone to / failed (exit $LASTEXITCODE)" }
        Log-Ok "mios.git seeded to /"
    }
    End-Phase 5

    # ── Phase 6 -- Identity ───────────────────────────────────────────────────
    Start-Phase 6
    $script:CurStep = "Waiting for identity input..."
    Show-Dashboard
    $MiosUser     = Read-Line "Linux username" "mios"
    $MiosHostname = Read-Line "Hostname"       "mios"
    $pwPlain      = Read-Password "Password"
    if ([string]::IsNullOrWhiteSpace($pwPlain)) { $pwPlain = "mios" }
    $MiosHash     = Get-PasswordHash $pwPlain
    Log-Ok "Identity: user=$MiosUser  host=$MiosHostname  password=(hashed)"
    End-Phase 6

    # ── Phase 7 -- Write identity ─────────────────────────────────────────────
    Start-Phase 7
    # Pipe via stdin -- Podman machine rootfs does not mount the Windows drive
    $envContent = "MIOS_USER=`"$MiosUser`"`nMIOS_HOSTNAME=`"$MiosHostname`"`nMIOS_USER_PASSWORD_HASH=`"$MiosHash`""
    $envContent | & wsl.exe -d $BuilderDistro --user root --exec bash -c `
        "mkdir -p /etc/mios && cat > /etc/mios/install.env && chmod 0640 /etc/mios/install.env" `
        2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Log-Ok "/etc/mios/install.env written" } `
    else { Log-Warn "install.env write failed (non-fatal -- set MIOS_* vars manually)" }
    End-Phase 7

    # ── Phase 8 -- App registration + Start Menu ──────────────────────────────
    Start-Phase 8
    $pwsh      = if (Get-Command pwsh -EA SilentlyContinue) { (Get-Command pwsh).Source } else { "powershell.exe" }
    $selfSc    = Join-Path $MiosRepoDir "mios-bootstrap\install.ps1"
    $uninstSc  = Join-Path $MiosInstallDir "uninstall.ps1"
    $uninstCmd = "$pwsh -ExecutionPolicy Bypass -File `"$uninstSc`""

    if (-not (Test-Path $UninstallRegKey)) { New-Item -Path $UninstallRegKey -Force | Out-Null }
    @{
        DisplayName="MiOS - Immutable Fedora AI Workstation"; DisplayVersion=$MiosVersion
        Publisher="MiOS-DEV"; InstallLocation=$MiosInstallDir
        UninstallString=$uninstCmd; QuietUninstallString="$uninstCmd -Quiet"
        URLInfoAbout="https://github.com/mios-dev/mios"; NoModify=[int]1; NoRepair=[int]1
    }.GetEnumerator() | ForEach-Object {
        $regType = if ($_.Value -is [int]) { "DWord" } else { "String" }
        Set-ItemProperty -Path $UninstallRegKey -Name $_.Key -Value $_.Value -Type $regType
    }

    if (-not (Test-Path $StartMenuDir)) { New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null }
    @(
        @{ F="MiOS Setup.lnk";         T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$selfSc`"";            D="Re-run full MiOS setup" },
        @{ F="MiOS Build.lnk";         T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$selfSc`" -BuildOnly";  D="Pull latest + build MiOS OCI image" },
        @{ F="MiOS WSL Terminal.lnk";  T="wsl.exe"; A="-d $BuilderDistro --user root";                         D="Open MiOS-BUILDER terminal (root)" },
        @{ F="MiOS Podman Shell.lnk";  T=$pwsh;     A="-NoProfile -Command podman machine ssh $BuilderDistro"; D="SSH into MiOS-BUILDER Podman machine" },
        @{ F="Uninstall MiOS.lnk";     T=$pwsh;     A="-ExecutionPolicy Bypass -File `"$uninstSc`"";           D="Remove MiOS" }
    ) | ForEach-Object { New-Shortcut (Join-Path $StartMenuDir $_.F) $_.T $_.A $_.D $MiosInstallDir }
    Log-Ok "Add/Remove Programs + Start Menu created"

    # Uninstaller script
    $B = $BuilderDistro
    @"
#Requires -Version 5.1
param([switch]`$Quiet)
`$I='$($MiosInstallDir-replace"'","''")'; `$D='$($MiosDataDir-replace"'","''")'; `$C='$($MiosConfigDir-replace"'","''")'; `$S='$($StartMenuDir-replace"'","''")'; `$K='$($UninstallRegKey-replace"'","''")'; `$B='$B'
if (-not `$Quiet) {
    Write-Host ''; Write-Host '  MiOS Uninstaller' -ForegroundColor Red; Write-Host ''
    Write-Host "  Removes: `$I, `$D, `$B Podman machine, Start Menu"
    Write-Host "  Preserves: `$C (config)"; Write-Host ''
    if ((Read-Host "  Type 'yes' to confirm") -ne 'yes') { Write-Host '  Aborted.'; exit 0 }
}
try { podman machine stop `$B 2>`$null } catch {}
try { podman machine rm -f `$B 2>`$null } catch {}
try { wsl --unregister `$B 2>`$null } catch {}
foreach (`$p in @(`$I,`$D,`$S)) { if (Test-Path `$p) { Remove-Item `$p -Recurse -Force } }
if (Test-Path `$K) { Remove-Item `$K -Recurse -Force }
Write-Host ''; Write-Host "  MiOS removed. Config at `$C preserved." -ForegroundColor Green
"@ | Set-Content $uninstSc -Encoding UTF8
    Log-Ok "uninstall.ps1 written"
    End-Phase 8

    # ── Phase 9 -- Build ──────────────────────────────────────────────────────
    Start-Phase 9
    $rc = Invoke-WslBuild -Distro $BuilderDistro -BaseImage $HW.BaseImage -AiModel $HW.AiModel
    if ($rc -eq 0) { End-Phase 9 } else { End-Phase 9 -Fail; $ExitCode = $rc }

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
        Write-Host $b -ForegroundColor Green
        $l = "| MiOS $MiosVersion built successfully!  (total: $totalTime)"
        Write-Host ($l.PadRight($script:DW - 1) + "|") -ForegroundColor Green
        Write-Host ("| Image : localhost/mios:latest  in $BuilderDistro".PadRight($script:DW - 1) + "|") -ForegroundColor White
        Write-Host ("| Logs  : $MiosLogDir".PadRight($script:DW - 1) + "|") -ForegroundColor DarkGray
        Write-Host $b -ForegroundColor Green
    } else {
        Write-Host $b -ForegroundColor Red
        Write-Host ("| BUILD FAILED (exit $ExitCode)  --  Errors: $($script:ErrCount)".PadRight($script:DW - 1) + "|") -ForegroundColor Red
        Write-Host ("| Full log: $LogFile".PadRight($script:DW - 1) + "|") -ForegroundColor Yellow
        Write-Host ("| Build log: $BuildLogFile".PadRight($script:DW - 1) + "|") -ForegroundColor Yellow
        Write-Host ("| Re-run: wsl -d $BuilderDistro --user root --cd / -- just build".PadRight($script:DW - 1) + "|") -ForegroundColor DarkGray
        Write-Host $b -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Log directory: $MiosLogDir" -ForegroundColor DarkGray
    Write-Host ""
    if (-not $Unattended) {
        Write-Host "  Press Enter to close..." -ForegroundColor DarkGray -NoNewline
        $null = Read-Host
    }
    exit $ExitCode
}
