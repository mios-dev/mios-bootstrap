# AI-hint: The ONE shared library for every Windows MiOS entrypoint (mios-install, Get-MiOS,
# MiOS-Cat helpers, build-mios). Dot-source it: `. "$PSScriptRoot\mios-common.ps1"`. It replaces the
# 4x self-elevate, 6x repo-fetch, and 5x hand-rolled mios.toml resolvers with one contract each, and
# provides the SSOT-derived themed console. SSOT resolution mirrors usr/lib/mios/mios_toml.py's
# layering: user > host > vendor (highest layer wins). No side effects on load beyond defining funcs.
# AI-related: mios-install.ps1, Get-MiOS.ps1, cat\MiOS-Cat.bat, usr\lib\mios\mios_toml.py, mios.toml

# ---- SSOT: one layered resolver (user > host > vendor), the only toml reader anyone needs ---------
function Get-MiosSsotLayers {
    # Ordered HIGHEST-priority first. user (operator overrides) > host > vendor (canonical/repo).
    $layers = @()
    $user = Join-Path $env:USERPROFILE '.config\mios\mios.toml'
    if (Test-Path -LiteralPath $user) { $layers += $user }
    foreach ($hostLayer in @('C:\ProgramData\mios\mios.toml', 'C:\MiOS\etc\mios\mios.toml')) {
        if (Test-Path -LiteralPath $hostLayer) { $layers += $hostLayer }
    }
    foreach ($vendor in @(
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'mios.toml'),   # repo-local (mios-bootstrap\mios.toml)
            'C:\MiOS\usr\share\mios\mios.toml',                            # canonical vendor SSOT
            'C:\MiOS\mios.toml')) {
        if ((Test-Path -LiteralPath $vendor) -and ($layers -notcontains $vendor)) { $layers += $vendor }
    }
    return $layers
}
function Get-MiosSsotValue {
    # One SSOT value, honouring layering: the first (highest) layer that defines [Section].Key wins.
    param([string]$Section, [string]$Key, [string]$Default = $null)
    foreach ($path in (Get-MiosSsotLayers)) {
        try { $text = Get-Content -Raw -LiteralPath $path -ErrorAction Stop } catch { continue }
        $sec = [regex]::Match($text, "(?ms)^\s*\[" + [regex]::Escape($Section) + "\]\s*(.*?)(?=^\s*\[|\z)")
        if (-not $sec.Success) { continue }
        $km = [regex]::Match($sec.Groups[1].Value, "(?m)^\s*" + [regex]::Escape($Key) + "\s*=\s*`"([^`"]*)`"")
        if ($km.Success) { return ($km.Groups[1].Value -replace '\\\\','\') }
    }
    return $Default
}
function Get-MiosSsotPath {
    # The canonical vendor SSOT for display ("your config lives here"), else the lowest layer present.
    if (Test-Path -LiteralPath 'C:\MiOS\usr\share\mios\mios.toml') { return 'C:\MiOS\usr\share\mios\mios.toml' }
    $l = Get-MiosSsotLayers; if ($l.Count) { $l[-1] } else { $null }
}

# ---- Theme: SSOT [colors] at runtime, ANSI/VT force-enabled (renders on bare WPS 5.1) -------------
function Enable-MiosVt {
    $script:NoColor = $false
    if ($env:MIOS_NO_COLOR -or $env:NO_COLOR) { $script:NoColor = $true; return }
    try {
        $sig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);' +
               '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);' +
               '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
        $k = Add-Type -MemberDefinition $sig -Name 'MiosVt' -Namespace 'MiosCommon' -PassThru -ErrorAction Stop
        $h = $k::GetStdHandle(-11); $m = 0
        if ($k::GetConsoleMode($h, [ref]$m)) { [void]$k::SetConsoleMode($h, ($m -bor 0x0004)) }
    } catch {}
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
}
function ConvertTo-MiosRgb {
    param([string]$Hex, [int[]]$Fallback)
    if ($Hex -and $Hex -match '^#?([0-9A-Fa-f]{6})$') {
        $h = $matches[1]
        return @([Convert]::ToInt32($h.Substring(0,2),16), [Convert]::ToInt32($h.Substring(2,2),16), [Convert]::ToInt32($h.Substring(4,2),16))
    }
    return $Fallback
}
function Get-MiosPalette {
    $defs = @{ bg='#282262'; fg='#E7DFD3'; accent='#1A407F'; cursor='#F35C15'; success='#3E7765';
               warning='#F35C15'; error='#DC271B'; info='#1A407F'; muted='#948E8E'; subtle='#B7C9D7'; silver='#E0E0E0' }
    $pal = @{}
    foreach ($key in $defs.Keys) {
        $val = Get-MiosSsotValue -Section 'colors' -Key $key -Default $defs[$key]
        $pal[$key] = ConvertTo-MiosRgb -Hex $val -Fallback (ConvertTo-MiosRgb -Hex $defs[$key] -Fallback @(200,200,200))
    }
    $script:Pal = $pal
    $script:TomlPath = Get-MiosSsotPath
}
$script:ESC = [char]27
function C { param([int[]]$rgb, [string]$t) if ($script:NoColor) { return $t }; "$script:ESC[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$t$script:ESC[0m" }
function B { param([string]$t) if ($script:NoColor) { return $t }; "$script:ESC[1m$t$script:ESC[0m" }
function Rule { param([int]$w=64) C $script:Pal.accent ([string]([char]0x2550) * $w) }
function Write-MiosLine {
    param([string]$Kind, [string]$Text)
    switch ($Kind) {
        'ok'   { Write-Host ("  " + (C $script:Pal.success '[ OK ]') + " $Text") }
        'info' { Write-Host ("  " + (C $script:Pal.info    '[INFO]') + " $Text") }
        'warn' { Write-Host ("  " + (C $script:Pal.warning '[WARN]') + " $Text") }
        'err'  { Write-Host ("  " + (C $script:Pal.error   '[ERR ]') + " $Text") }
        default{ Write-Host "  $Text" }
    }
}
function Write-MiosKV { param([string]$Key, [string]$Value) Write-Host ("    " + (C $script:Pal.subtle ("{0,-9}" -f $Key)) + " " + (C $script:Pal.fg $Value)) }

# ---- Elevation: one Test/Invoke, used by every entrypoint that needs Administrator ---------------
function Test-MiosAdmin {
    try { (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false }
}
function Invoke-MiosSelfElevate {
    param([string[]]$OrigArgs, [string]$ScriptPath = $PSCommandPath)
    if (Test-MiosAdmin) { return }
    Write-MiosLine 'info' 'This step needs Administrator -- relaunching with a UAC prompt (click Yes)...'
    $psExe = (Get-Process -Id $PID).Path
    try {
        $p = Start-Process -FilePath $psExe -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File', $ScriptPath) + $OrigArgs) -Verb RunAs -PassThru -Wait
        exit $p.ExitCode
    } catch { Write-MiosLine 'err' "Elevation was declined -- re-run from an Administrator terminal. ($($_.Exception.Message))"; exit 1 }
}

# ---- Repo fetch: one Ensure-Repo (git, else GitHub zip). Canonical checkout = C:\mios-bootstrap ---
function Ensure-MiosRepo {
    param([string]$Root = 'C:\mios-bootstrap')
    if (Test-Path (Join-Path $Root 'installation\mios-install.ps1')) { return $Root }
    Write-MiosLine 'info' 'mios-bootstrap not present -- fetching it (git, else a GitHub zip)...'
    if (Get-Command git -ErrorAction SilentlyContinue) {
        try { & git clone --depth 1 'https://github.com/mios-dev/mios-bootstrap.git' $Root 2>&1 | Out-Null } catch {}
    }
    if (-not (Test-Path (Join-Path $Root 'installation\mios-install.ps1'))) {
        $zip = Join-Path $env:TEMP 'mios-bootstrap.zip'
        $tmp = Join-Path $env:TEMP ('mios-bs-' + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://codeload.github.com/mios-dev/mios-bootstrap/zip/refs/heads/main' -OutFile $zip -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
            if ($inner) { New-Item -ItemType Directory -Force -Path $Root | Out-Null; Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $Root -Recurse -Force }
        } catch { Write-MiosLine 'warn' "Could not fetch mios-bootstrap: $($_.Exception.Message)" }
        finally { Remove-Item $zip,$tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $Root
}

# ---- Live monitor: the ONE spawn every install entry uses so a foreground, fully-branded ----------
# Windows Terminal dashboard pops up EVERY run and follows the install log. Opt out with
# $env:MIOS_NO_MONITOR=1; force even on dry-runs / for debugging with $env:MIOS_MONITOR=1 (or the
# installer's --monitor flag). Remote monitoring: point Monitor-MiosFlash.ps1 -LogPath at a shared
# log path (e.g. a UNC / synced folder) and run it on another machine against the same file.
function Get-MiosMonitorPaths {
    $dir = Join-Path $env:TEMP 'mios'
    try { if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } } catch { $dir = $env:TEMP }
    @{ Log = (Join-Path $dir 'mios-cat-flash.log'); Marker = (Join-Path $dir 'mios-cat-flash.marker'); Dir = $dir }
}
function Resolve-MiosMonitorScript {
    @((Join-Path $PSScriptRoot 'MiOS-Monitor.ps1'), 'C:\mios-bootstrap\installation\MiOS-Monitor.ps1') |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
function Start-MiosMonitor {
    param([string]$LogPath, [string]$MarkerPath, [string]$Title = 'MiOS-Cat')
    if ("$($env:MIOS_NO_MONITOR)".ToLower() -in @('1','true','yes','on') -or
        "$($env:MIOS_UNIFIED)".ToLower() -in @('1','true','yes','on') -or
        "$($env:MIOS_HEADLESS)".ToLower() -in @('1','true','yes','on') -or
        "$($env:MIOS_MONITOR_RUNNING)".ToLower() -in @('1','true','yes','on')) { return $null }

    # Single-window check: prevent spawning duplicate monitor windows if one is already active
    try {
        $existing = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.MainWindowTitle -like '*MiOS*Monitor*' -or $_.MainWindowTitle -like '*MiOS-Cat*'
        }
        if ($existing) { return $null }
    } catch {}

    $mon = Resolve-MiosMonitorScript
    if (-not $mon) { return $null }
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $mon)
    if ($LogPath)    { $a += @('-LogPath', $LogPath) }
    if ($MarkerPath) { $a += @('-MarkerPath', $MarkerPath) }
    try {
        $env:MIOS_MONITOR_RUNNING = '1'
        if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
            # foreground Windows Terminal tab (single-token title -- a spaced title mis-parses in wt)
            Start-Process wt.exe -ArgumentList (@('new-tab','--title', ($Title -replace '\s','-'), 'pwsh') + $a) -ErrorAction Stop
        } else {
            $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
            Start-Process $exe -ArgumentList $a -ErrorAction Stop
        }
    } catch {}
}

function Get-MiosBackgroundInstaller {
    [CmdletBinding()] param([string]$Hint = 'mios-install')
    $clean = $Hint -replace '^.*[\\/]', '' -replace '\.exe$', ''
    return Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match [regex]::Escape($clean) -or
        $_.MainWindowTitle -match [regex]::Escape($clean) -or
        ($_.CommandLine -and $_.CommandLine -match [regex]::Escape($clean))
    }
}

function Install-MiosRust {
    # Law 14 / ADR-0011: Rust is MiOS's native tier. MiOS PROVIDES it as a dependency and installs
    # it on the base Windows system DURING STAGING, so every native component is buildable on ANY
    # Windows machine. Idempotent. Prefers winget (Rustlang.Rustup); falls back to the official
    # rustup-init.exe with the GNU host triple -> no Visual Studio / MSVC required (fully portable).
    [CmdletBinding()] param([string]$Toolchain = 'stable')
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if ((Get-Command cargo -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $cargoBin 'cargo.exe'))) {
        if (Test-Path (Join-Path $cargoBin 'cargo.exe')) { $env:PATH = "$cargoBin;$env:PATH" }
        Write-MiosLine 'ok' ("Rust already present: " + ((cargo --version 2>$null) -join ''))
        return $true
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try { winget install --id Rustlang.Rustup -e --silent --accept-source-agreements --accept-package-agreements 2>$null | Out-Null } catch {}
    }
    if (-not (Test-Path (Join-Path $cargoBin 'cargo.exe'))) {
        try {
            $init = Join-Path $env:TEMP 'rustup-init.exe'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-gnu/rustup-init.exe' -OutFile $init -UseBasicParsing -ErrorAction Stop
            & $init -y --default-host x86_64-pc-windows-gnu --default-toolchain $Toolchain --profile minimal 2>$null | Out-Null
        } catch {}
    }
    if (Test-Path (Join-Path $cargoBin 'cargo.exe')) { $env:PATH = "$cargoBin;$env:PATH" }
    if (Get-Command cargo -ErrorAction SilentlyContinue) {
        Write-MiosLine 'ok' ("Rust installed: " + ((cargo --version 2>$null) -join ''))
        return $true
    }
    Write-MiosLine 'warn' 'Rust could not be installed now (offline?) -- native components build on next staging with connectivity.'
    return $false
}
