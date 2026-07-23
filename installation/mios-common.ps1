# AI-hint: Shared library for the mios-install unified dispatcher and its wrapped entrypoints.
# Contains:
#   1. Enable-MiosVt / Get-MiosPalette / C / B / Rule / Write-MiosLine / Write-MiosKV  (SSOT [colors] console theme)
#   2. Get-MiosSsotValue (three-layer vendor<host<user overlay resolver)
#   3. Test-MiosAdmin / Invoke-MiosSelfElevate (ONE elevation implementation)
#   4. Ensure-MiosRepo (git clone / pull when mios-install runs on bare Windows)
# AI-related: installation\mios-install.ps1, installation\mios-install.sh, cat\MiOS-Cat.bat, mios.toml
# AI-functions: Enable-MiosVt, Get-MiosPalette, C, B, Rule, Write-MiosLine, Write-MiosKV,
#   Get-MiosSsotValue, Test-MiosAdmin, Invoke-MiosSelfElevate, Ensure-MiosRepo, Resolve-MiosMonitorScript, Start-MiosMonitor

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Enable-MiosVt {
    if ($env:MIOS_NO_COLOR -or $env:NO_COLOR) { return $false }
    if ($env:OS -notmatch 'Windows') { return $true }
    try {
        $sig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);' +
               '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);' +
               '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
        $type = Add-Type -MemberDefinition $sig -Name ('MiosCommonVt_' + [Guid]::NewGuid().ToString('N')) -Namespace 'MiosVt' -PassThru -ErrorAction Stop
        $h = $type::GetStdHandle(-11); $m = 0
        if ($type::GetConsoleMode($h, [ref]$m)) {
            return [bool]$type::SetConsoleMode($h, ($m -bor 0x0004 -bor 0x0001))
        }
    } catch {}
    return $false
}

function Get-MiosSsotValue {
    param(
        [Parameter(Mandatory=$true)][string]$Section,
        [Parameter(Mandatory=$true)][string]$Key,
        [string]$Default = '',
        [string]$TomlPath = ''
    )
    if (-not $TomlPath) {
        $TomlPath = @(
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'mios.toml'),
            'C:\MiOS\usr\share\mios\mios.toml',
            '/usr/share/mios/mios.toml'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $TomlPath -or -not (Test-Path $TomlPath)) { return $Default }
    try {
        $raw = Get-Content -Raw -LiteralPath $TomlPath -ErrorAction Stop
        $secMatch = [regex]::Match($raw, "(?ms)^\s*\[" + [regex]::Escape($Section) + "\]\s*(.*?)(?=^\s*\[|\z)")
        if ($secMatch.Success) {
            $keyMatch = [regex]::Match($secMatch.Groups[1].Value, "(?m)^\s*" + [regex]::Escape($Key) + "\s*=\s*(?:`"([^`"]*)`"|'([^']*)'|(\S+))")
            if ($keyMatch.Success) {
                for ($g = 1; $g -le 3; $g++) {
                    if ($keyMatch.Groups[$g].Success) { return $keyMatch.Groups[$g].Value }
                }
            }
        }
    } catch {}
    return $Default
}

function Get-MiosPalette {
    param([string]$TomlPath = '')
    $fallback = @{
        bg      = @(40,34,98)
        fg      = @(231,223,211)
        accent  = @(26,64,127)
        cursor  = @(243,92,21)
        success = @(62,119,101)
        warning = @(243,92,21)
        error   = @(220,39,27)
        muted   = @(148,142,142)
        subtle  = @(183,201,215)
    }
    return $fallback
}

$script:MiosVtOk = Enable-MiosVt
$script:Pal      = Get-MiosPalette
$script:TomlPath = @(
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'mios.toml'),
    'C:\MiOS\usr\share\mios\mios.toml'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function C {
    param([int[]]$rgb, [string]$t)
    if (-not $script:MiosVtOk -or $env:MIOS_NO_COLOR -or $env:NO_COLOR) { return $t }
    $e = [char]27
    return "$e[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$t$e[0m"
}

function B {
    param([string]$t)
    if (-not $script:MiosVtOk -or $env:MIOS_NO_COLOR -or $env:NO_COLOR) { return $t }
    $e = [char]27
    return "$e[1m$t$e[0m"
}

function Rule {
    param([int]$Width = 64)
    return (C $script:Pal.muted ("=" * $Width))
}

function Write-MiosLine {
    param([string]$Level, [string]$Message)
    $tag = switch ($Level.ToLower()) {
        'info'  { C $script:Pal.accent  (B '[INFO]') }
        'warn'  { C $script:Pal.warning (B '[WARN]') }
        'err'   { C $script:Pal.error   (B '[FAIL]') }
        'pass'  { C $script:Pal.success (B '[PASS]') }
        default { C $script:Pal.muted   (B "[$Level]") }
    }
    Write-Host "  $tag $Message"
}

function Write-MiosKV {
    param([string]$Key, [string]$Value)
    $k = (C $script:Pal.subtle ("{0,-14}" -f $Key))
    $v = (C $script:Pal.fg $Value)
    Write-Host "  $k : $v"
}

function Test-MiosAdmin {
    if ($env:OS -notmatch 'Windows') { return $true }
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Invoke-MiosSelfElevate {
    param([string[]]$ArgList = @())
    if (Test-MiosAdmin) { return $true }
    if ($env:NONINTERACTIVE -eq '1') {
        Write-MiosLine 'err' 'Administrator privileges required for non-interactive execution.'
        exit 1
    }
    Write-MiosLine 'warn' 'Requesting administrator privileges (UAC prompt)...'
    $script = $MyInvocation.PSCommandPath
    $argsStr = ($ArgList | ForEach-Object { "`"$_`"" }) -join ' '
    try {
        $proc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" $argsStr" -Verb RunAs -PassThru
        $proc.WaitForExit()
        exit $proc.ExitCode
    } catch {
        Write-MiosLine 'err' 'Elevation declined or failed.'
        exit 1
    }
}

function Ensure-MiosRepo {
    param([string]$TargetDir = 'C:\mios-bootstrap')
    if (Test-Path $TargetDir) { return $TargetDir }
    Write-MiosLine 'info' "Fetching MiOS repository to $TargetDir ..."
    try {
        git clone --depth=1 https://github.com/mios-dev/mios-bootstrap.git $TargetDir
        return $TargetDir
    } catch {
        Write-MiosLine 'err' "Failed to clone repo to $TargetDir."
        exit 1
    }
}

function Resolve-MiosMonitorScript {
    @((Join-Path (Split-Path $script:Root -Parent) 'MiOS\usr\libexec\mios\MiOS-Mon.py'), 'C:\MiOS\usr\libexec\mios\MiOS-Mon.py') |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Start-MiosMonitor {
    param([string]$LogPath, [string]$MarkerPath, [string]$Title = 'MiOS-Cat', [switch]$InProcess)
    if ("$($env:MIOS_NO_MONITOR)".ToLower() -in @('1','true','yes','on') -or
        "$($env:MIOS_UNIFIED)".ToLower() -in @('1','true','yes','on') -or
        "$($env:MIOS_HEADLESS)".ToLower() -in @('1','true','yes','on') -or
        "$($env:MIOS_MONITOR_RUNNING)".ToLower() -in @('1','true','yes','on')) { return $null }

    $mon = Resolve-MiosMonitorScript
    if (-not $mon) { return $null }
    
    # Single-console, in-process execution: render live monitor directly without background windows
    $env:MIOS_MONITOR_RUNNING = '1'
    & python $mon
    return $null
}
