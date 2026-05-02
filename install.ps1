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
$MiosWslDistro    = "MiOS"
$LegacyDistro     = "podman-machine-default"
$UninstallRegKey  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MiOS"
$StartMenuDir     = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\MiOS"

# ── Log file ──────────────────────────────────────────────────────────────────
$null = New-Item -ItemType Directory -Path $MiosLogDir -Force -ErrorAction SilentlyContinue
$LogStamp = [datetime]::Now.ToString("yyyyMMdd-HHmmss")
$LogFile  = Join-Path $MiosLogDir "mios-install-$LogStamp.log"
# Unified log — all build output (including podman build lines) goes to the same file
$BuildLogFile = $LogFile
[Environment]::SetEnvironmentVariable("MIOS_UNIFIED_LOG", $LogFile)
try { Start-Transcript -Path $LogFile -Append -Force | Out-Null } catch {}

function Write-Log {
    param([string]$M, [string]$L = "INFO")
    $ts = [datetime]::Now.ToString("HH:mm:ss.fff")
    # Write-Host is captured by Start-Transcript; Out-File to the same path causes
    # a TerminatingError (file lock) that -EA SilentlyContinue cannot suppress.
    Write-Host "[$ts][$L] $M"
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
    "Verifying build context",     # 5
    "Identity",                    # 6
    "Writing identity",            # 7
    "App registration",            # 8
    "Building OCI image",          # 9
    "Exporting WSL2 image",        # 10
    "Registering MiOS WSL2",       # 11
    "Building disk images",        # 12
    "Deploying Hyper-V VM"         # 13
)
$script:TotalPhases  = $script:PhaseNames.Count
$script:PhStat       = @(0,0,0,0,0,0,0,0,0,0,0,0,0,0)   # 0=wait 1=run 2=ok 3=fail 4=warn
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
$script:BuildSubTotal = 48   # updated from build.sh "+- STEP NN/TT" header
$script:BuildSubDone  = 0
$script:BuildSubStep  = ""
$script:GhcrToken     = ""   # GitHub PAT for ghcr.io; set in phase 6 or from env

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
    # Strip BuildKit "#N 0.123 " prefix so bare content reaches the matchers
    $stripped = ($line -replace '^\s*#\d+\s+[\d.]+\s+', '').TrimStart()

    # Step start: "+- STEP NN/TT : scriptname"
    if ($stripped -match '\+-\s*STEP\s+(\d+)/(\d+)\s*:\s*(\S+)') {
        $script:BuildSubTotal = [int]$Matches[2]
        $script:BuildSubStep  = $Matches[3] -replace '\.sh$', ''
        $script:BuildSubDone  = [math]::Max(0, [int]$Matches[1] - 1)
        $script:CurStep       = "Step $($Matches[1])/$($Matches[2]) — $($script:BuildSubStep)"
    # Step end: "+-- [ DONE ] / +-- [FAILED] / +-- [ WARN ]"
    } elseif ($stripped -match '\+--\s+\[') {
        $script:BuildSubDone = [math]::Min($script:BuildSubDone + 1, $script:BuildSubTotal)
    } else {
        # Every other non-empty line updates Op: live — this is the frozen-dashboard fix.
        # Without this, Op: shows the static "podman build (Windows client → ...)" for the
        # entire build duration because no other branch ever touched $script:CurStep.
        if (-not [string]::IsNullOrWhiteSpace($stripped)) {
            $c = ($stripped -replace '\s+', ' ').Trim()
            if ($c.Length -gt 80) { $c = $c.Substring(0, 77) + '...' }
            $script:CurStep = $c
        }
    }
}

function Show-Dashboard {
    try {
    $w  = [int]$script:DW
    if ($w -lt 66) { $w = 66 }
    $in = $w - 4          # usable inner width (inside "| " and " |")
    $sep = "+" + ("-" * ($w - 2)) + "+"

    $done  = [int]($script:PhStat | Where-Object { $_ -eq 2 } | Measure-Object).Count
    $fail  = [int]($script:PhStat | Where-Object { $_ -eq 3 } | Measure-Object).Count
    $globalDone  = $done + $script:BuildSubDone
    $globalTotal = $script:TotalPhases + $script:BuildSubTotal
    $elapsed = [datetime]::Now - $script:ScriptStart
    $elStr   = fmtSpan $elapsed

    $statusStr = if ($fail -gt 0) { "FAILED" } `
                 elseif ($script:CurPhase -ge 0 -and $script:PhStat[$script:CurPhase] -eq 1) { "RUNNING" } `
                 else { "IDLE" }

    $curName = if ($script:CurPhase -ge 0) { [string]$script:PhaseNames[$script:CurPhase] } else { "Initializing" }
    $phLabel = "[$($script:CurPhase)/$($script:TotalPhases-1)] $curName"
    if ($script:CurPhase -eq 9 -and $script:BuildSubTotal -gt 0) {
        $phLabel += "  ($($script:BuildSubDone)/$($script:BuildSubTotal) steps)"
    }

    $spinChars = @('|', '/', '-', '\')
    $spinChar  = $spinChars[[int](([datetime]::Now - $script:ScriptStart).TotalMilliseconds / 250) % 4]
    $step = [string]$script:CurStep
    $stepMax = $in - 10
    if ($step.Length -gt $stepMax) { $step = $step.Substring(0,$stepMax-3)+"..." }
    $stepLine = "$spinChar $step"

    $barW   = [math]::Max(10, $in - 12)
    $barStr = pbar $globalDone $globalTotal $barW

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
    $rows.Add(("| Op : " + $stepLine.PadRight($in-6) + " |").PadRight($w))
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
        $bufH = try { [Console]::BufferHeight } catch { 9999 }
        $dashStart = [math]::Min($script:DashRow, $bufH - 1)
        [Console]::SetCursorPosition(0, $dashStart)
        foreach ($row in $rows) {
            if ($row.Length -lt $w) { $row = $row.PadRight($w) }
            elseif ($row.Length -gt $w) { $row = $row.Substring(0,$w) }
            [Console]::Write($row)
            [Console]::Write([Environment]::NewLine)
        }
        $script:DashHeight = $rows.Count
        $dashEnd = [math]::Min($dashStart + $script:DashHeight, $bufH - 1)
        [Console]::SetCursorPosition(0, $dashEnd)
    } catch { <# non-interactive / piped -- skip cursor ops #> }

    } catch {
        # Dashboard render error -- log and continue; never let dashboard kill the script
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
    throw "Cannot generate sha512crypt hash — install openssl or run from a distro."
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
    # Check legacy WSL distros (MiOS already applied via bootc switch, has /Justfile)
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

function New-BuilderDistro([hashtable]$HW) {
    Set-Step "Initializing MiOS-BUILDER ($($HW.Cpus) CPUs / $($HW.RamGB)GB / $($HW.DiskGB)GB disk)"
    # Cap at the OS-reported physical RAM (what podman validates) minus 512 MB safety margin.
    # Nominal $HW.RamGB rounds up from actual hardware, causing podman to reject the request.
    $ramMB = [math]::Max(4096, [math]::Min($HW.OsTotalRamMB - 512, $HW.RamGB * 1024 - 512))
    $initSw = [System.Diagnostics.Stopwatch]::StartNew()
    & podman machine init $BuilderDistro `
        --cpus $HW.Cpus --memory $ramMB --disk-size $HW.DiskGB `
        --rootful --now 2>&1 | ForEach-Object {
            Write-Log "podman-init: $_"
            if ($initSw.ElapsedMilliseconds -ge 400) {
                $clean = ($_ -replace '\x1b\[[0-9;]*[mGKHFJ]','').Trim()
                if ($clean) { $script:CurStep = $clean.Substring(0,[math]::Min($clean.Length,80)) }
                Show-Dashboard
                $initSw.Restart()
            }
        }
    if ($LASTEXITCODE -ne 0) { throw "podman machine init failed (exit $LASTEXITCODE)" }
    & podman machine set --default $BuilderDistro 2>&1 | Out-Null
    Log-Ok "MiOS-BUILDER created and set as default Podman machine"

    # Rootful machine-os distros are not accessible via wsl.exe or podman machine ssh.
    # Build runs from the Windows Podman client via the machine's API -- no exec needed.
    # Just verify the API is up (it should be immediately after --now).
    Set-Step "Verifying MiOS-BUILDER Podman API..."
    $deadline = (Get-Date).AddSeconds(30)
    $apiOk = $false
    while ((Get-Date) -lt $deadline) {
        $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
              Where-Object { $_ -match "^$([regex]::Escape($BuilderDistro))\s+true" }
        if ($ml) { $apiOk = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $apiOk) { throw "$BuilderDistro not in running state after 30 s -- check: podman machine ls" }
    Log-Ok "MiOS-BUILDER Podman API ready"
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

function Invoke-WindowsPodmanBuild([string]$BaseImage, [string]$MiosUser, [string]$MiosHostname) {
    $repoPath = Join-Path $MiosRepoDir "mios"
    Set-Step "podman build (Windows client → $BuilderDistro)"
    Write-Log "BUILD START (Windows API build)  base=$BaseImage  user=$MiosUser  host=$MiosHostname"

    # Run via cmd.exe so 2>&1 merges stderr (podman build progress) into stdout stream
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "cmd.exe"
    $psi.Arguments = ("/c podman build --progress=plain --no-cache " +
                      "--build-arg `"BASE_IMAGE=$BaseImage`" " +
                      "--build-arg `"MIOS_USER=$MiosUser`" " +
                      "--build-arg `"MIOS_HOSTNAME=$MiosHostname`" " +
                      "--build-arg `"MIOS_FLATPAKS=`" " +
                      "-t localhost/mios:latest . 2>&1")
    $psi.WorkingDirectory       = $repoPath
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
        Write-Host $line
        $lineCount++
        Update-BuildSubPhase $line
        if ($sw.ElapsedMilliseconds -ge 250) { Show-Dashboard; $sw.Restart() }
    }
    $proc.WaitForExit()
    Write-Log "BUILD END  exit=$($proc.ExitCode)  lines=$lineCount"
    return $proc.ExitCode
}

function Invoke-WslBuild([string]$Distro, [string]$BaseImage, [string]$AiModel,
                          [string]$MiosUser = "mios", [string]$MiosHostname = "mios") {
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
        return Invoke-WindowsPodmanBuild -BaseImage $BaseImage -MiosUser $MiosUser -MiosHostname $MiosHostname
    }

    $justCheck = "command -v just &>/dev/null || dnf install -y just"
    if ($useSsh) {
        & podman machine ssh $Distro -- bash -c $justCheck 2>$null | Out-Null
    } else {
        & wsl.exe -d $Distro --user root --exec bash -c $justCheck 2>$null | Out-Null
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
    $lineCount = 0

    while (-not $proc.StandardOutput.EndOfStream) {
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        Write-Host $line
        $lineCount++
        Update-BuildSubPhase $line
        if ($sw.ElapsedMilliseconds -ge 250) { Show-Dashboard; $sw.Restart() }
    }

    $proc.WaitForExit()
    $rc = $proc.ExitCode
    Write-Log "BUILD END  exit=$rc  lines=$lineCount"
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
    # Register WSL2 distro from tar (replaces existing MiOS distro if present)
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

    # Pre-create the output directory inside the machine — podman volume mounts require
    # the host-side path to exist before the container starts.
    Set-Step "BIB: creating output dir in machine..."
    & podman run --rm --privileged --security-opt label=disable `
        docker.io/library/alpine:latest `
        mkdir -p $MachineOutDir 2>&1 | ForEach-Object { Write-Log "bib-mkdir: $_" }
    if ($LASTEXITCODE -ne 0) { Write-Log "WARN: bib mkdir returned $LASTEXITCODE (may still work)" }

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
    # podman machine cp MiOS-BUILDER:/path/in/machine C:\windows\path
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
    $machineRunning = $false
    # Check via Podman API first (covers rootful machine-os distros inaccessible via wsl.exe)
    try {
        $ml = (& podman machine ls --format "{{.Name}} {{.Running}}" 2>$null) |
              Where-Object { $_ -match "^$([regex]::Escape($BuilderDistro))\s+true" }
        if ($ml) { $machineRunning = $true }
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
                    # Stale Podman machine metadata — WSL distro was deleted but Podman registry entry remains.
                    # Force-remove the stale entry so New-BuilderDistro can re-init cleanly.
                    Write-Log "podman-start: stale machine registration detected -- removing $BuilderDistro" "WARN"
                    & podman machine rm --force $BuilderDistro 2>&1 | ForEach-Object { Write-Log "podman-rm: $_" }
                }
            }
        } catch {}
    }
    # Legacy: accept wsl.exe-accessible distro too (MiOS already applied)
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
    End-Phase 3

    # ── Phase 4 -- WSL2 .wslconfig ───────────────────────────────────────────
    Start-Phase 4
    $wslCfg = Join-Path $env:USERPROFILE ".wslconfig"

    # Required keys — always ensure these are present regardless of existing config.
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
        # No [wsl2] section at all — append one wholesale
        $block = "`n[wsl2]`n# MiOS-managed -- host resources for MiOS-BUILDER`n"
        foreach ($kv in $requiredKeys.GetEnumerator()) { $block += "$($kv.Key)=$($kv.Value)`n" }
        Add-Content -Path $wslCfg -Value $block
        Log-Ok ".wslconfig: wrote [wsl2] — $($HW.RamGB)GB RAM, $($HW.Cpus) CPUs, mirrored"
    } else {
        # [wsl2] exists — patch each required key in place; append missing ones
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
        Log-Ok ".wslconfig: merged [wsl2] — $($HW.RamGB)GB RAM, $($HW.Cpus) CPUs, mirrored"
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

    # ── Phase 6 -- Identity ───────────────────────────────────────────────────
    Start-Phase 6
    $script:CurStep = "Waiting for identity input..."
    Show-Dashboard
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
    Log-Ok "Identity: user=$MiosUser  host=$MiosHostname  password=(hashed)  ghcr=$tokStatus"
    End-Phase 6

    # ── Phase 7 -- Write identity ─────────────────────────────────────────────
    Start-Phase 7
    $envContent = "MIOS_USER=`"$MiosUser`"`nMIOS_HOSTNAME=`"$MiosHostname`"`nMIOS_USER_PASSWORD_HASH=`"$MiosHash`""
    $writeCmd  = "mkdir -p /etc/mios && cat > /etc/mios/install.env && chmod 0640 /etc/mios/install.env"
    $written = $false

    # Try wsl.exe (works when machine runs MiOS after bootc switch)
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
        @{ F="MiOS Terminal.lnk";        T="wsl.exe"; A="-d $MiosWslDistro";                                    D="Open MiOS workstation terminal" },
        @{ F="MiOS Builder Shell.lnk";  T="wsl.exe"; A="-d $BuilderDistro --user root";                         D="Open MiOS-BUILDER terminal (root)" },
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
    $rc = Invoke-WslBuild -Distro $BuilderDistro -BaseImage $HW.BaseImage -AiModel $HW.AiModel `
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
        $l = "| MiOS $MiosVersion built and deployed!  (total: $totalTime)"
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
        Write-Host ("| Full log: $LogFile".PadRight($script:DW - 1) + "|") -ForegroundColor Yellow
        Write-Host ("| Full log: $LogFile".PadRight($script:DW - 1) + "|") -ForegroundColor Yellow
        Write-Host ("| Re-run: podman build --no-cache -t localhost/mios:latest $MiosRepoDir\mios".PadRight($script:DW - 1) + "|") -ForegroundColor DarkGray
        Write-Host $b -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Log directory: $MiosLogDir" -ForegroundColor DarkGray
    Write-Host ""
    if (-not $Unattended) {
        Write-Host "  Press Enter to close..." -ForegroundColor DarkGray -NoNewline
        $null = Read-Host
    }
    try { Stop-Transcript | Out-Null } catch {}
    exit $ExitCode
}
