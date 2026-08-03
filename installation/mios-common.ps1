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
    $candidatePaths = if ($TomlPath) { @($TomlPath) } else {
        @(
            (Join-Path $env:USERPROFILE '.config\mios\mios.toml'),
            'C:\ProgramData\MiOS\mios.toml',
            'C:\MiOS\usr\share\mios\mios.toml',
            'C:\Windows\Web\MiOS\mios.toml',
            'M:\etc\mios\mios.toml',
            'M:\usr\share\mios\mios.toml',
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'mios.toml'),
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'usr\share\mios\mios.toml'),
            '/usr/share/mios/mios.toml'
        )
    }
    foreach ($p in $candidatePaths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $raw = Get-Content -Raw -LiteralPath $p -ErrorAction Stop
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
    }
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
    param(
        [string]$ScriptPath = $MyInvocation.PSCommandPath,
        [string[]]$ArgList = @()
    )
    if (Test-MiosAdmin) { return $true }
    if ($env:NONINTERACTIVE -eq '1') {
        if (Get-Command 'Write-MiosLine' -ErrorAction SilentlyContinue) {
            Write-MiosLine 'err' 'Administrator privileges required for non-interactive execution.'
        } else {
            Write-Error 'Administrator privileges required for non-interactive execution.'
        }
        exit 1
    }
    if (Get-Command 'Write-MiosLine' -ErrorAction SilentlyContinue) {
        Write-MiosLine 'warn' 'Requesting administrator privileges (UAC prompt)...'
    } else {
        Write-Host '  [*] Requesting administrator privileges (UAC prompt)...' -ForegroundColor Yellow
    }
    if (-not $ScriptPath) {
        $ScriptPath = $MyInvocation.ScriptName
    }
    $psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ArgList
    try {
        $proc = Start-Process $psBin -ArgumentList $psArgs -Verb RunAs -PassThru
        $proc.WaitForExit()
        exit $proc.ExitCode
    } catch {
        if (Get-Command 'Write-MiosLine' -ErrorAction SilentlyContinue) {
            Write-MiosLine 'err' 'Elevation declined or failed.'
        } else {
            Write-Error 'Elevation declined or failed.'
        }
        exit 1
    }
}

function Ensure-MiosBootstrapRepo {
    param(
        [string]$TargetDir = 'C:\mios-bootstrap',
        [string]$RepoUrl = 'https://github.com/mios-dev/mios-bootstrap.git',
        [string]$ZipUrl = 'https://codeload.github.com/mios-dev/mios-bootstrap/zip/refs/heads/main',
        [string]$SentinelFile = 'cat\autounattend\Build-MiOSXboxISO.ps1'
    )
    if (Get-Command Get-MiosTomlValue -ErrorAction SilentlyContinue) {
        $cfgRepo = Get-MiosTomlValue -Key 'bootstrap.mios_repo' -Default $RepoUrl
        if ($cfgRepo) { $RepoUrl = $cfgRepo }
        $cfgDir = Get-MiosTomlValue -Key 'bootstrap.bootstrap_repo' -Default $TargetDir
        if ($cfgDir) { $TargetDir = $cfgDir }
    }

    $sentinelPath = Join-Path $TargetDir $SentinelFile
    if (Test-Path $sentinelPath) { return $TargetDir }

    if (Get-Command 'Write-MiosLine' -ErrorAction SilentlyContinue) {
        Write-MiosLine 'info' "mios-bootstrap repo missing -- fetching to $TargetDir ..."
    } else {
        Write-Host "  [*] mios-bootstrap repo missing -- fetching to $TargetDir ..." -ForegroundColor Cyan
    }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        try { & git clone --depth 1 $RepoUrl $TargetDir 2>&1 | Out-Null } catch {}
    }

    if (-not (Test-Path $sentinelPath)) {
        $zip = Join-Path $env:TEMP 'mios-bootstrap.zip'
        $tmp = Join-Path $env:TEMP ('mios-bs-' + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
            if ($inner) {
                New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
                Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $TargetDir -Recurse -Force
            }
        } catch {
            if (Get-Command 'Write-MiosLine' -ErrorAction SilentlyContinue) {
                Write-MiosLine 'warn' "Fetch failed: $($_.Exception.Message)"
            } else {
                Write-Host "  [!] Fetch failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        } finally {
            Remove-Item $zip,$tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path $sentinelPath)) {
        if (Get-Command 'Write-MiosLine' -ErrorAction SilentlyContinue) {
            Write-MiosLine 'err' "Failed to fetch mios-bootstrap repository to $TargetDir (sentinel $SentinelFile missing)"
        } else {
            Write-Error "Failed to fetch mios-bootstrap repository to $TargetDir (sentinel $SentinelFile missing)"
        }
        exit 1
    }

    return $TargetDir
}

function Ensure-MiosRepo {
    param([string]$TargetDir = 'C:\mios-bootstrap')
    return (Ensure-MiosBootstrapRepo -TargetDir $TargetDir)
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

function Read-MiosSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][string]$Prompt = "Secret:",
        [switch]$AsSecureString,
        [switch]$PersistDpapi,
        [string]$PersistPath = ""
    )
    if ($Prompt) {
        Write-Host "  $Prompt " -NoNewline -ForegroundColor White
    }
    
    $secure = Read-Host -MaskInput -AsSecureString
    if ($AsSecureString) {
        return $secure
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain = ""
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    if ($PersistDpapi) {
        if (-not $PersistPath) {
            $MiosAppDir = Join-Path $env:LOCALAPPDATA "MiOS"
            if (-not (Test-Path $MiosAppDir)) { New-Item -ItemType Directory -Path $MiosAppDir -Force | Out-Null }
            $PersistPath = Join-Path $MiosAppDir ".mios-secrets.dpapi"
        }
        $dir = Split-Path $PersistPath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        
        $encrypted = ConvertFrom-SecureString -SecureString $secure
        Set-Content -Path $PersistPath -Value $encrypted -Encoding UTF8
        
        try {
            $acl = Get-Acl $PersistPath
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                "FullControl", "Allow"
            )
            $acl.AddAccessRule($rule)
            Set-Acl $PersistPath $acl
        } catch {}
    }

    return $plain
}

function Get-MiosSecretDpapi {
    param([string]$PersistPath = "")
    if (-not $PersistPath) {
        $PersistPath = Join-Path $env:LOCALAPPDATA "MiOS\.mios-secrets.dpapi"
    }
    if (-not (Test-Path $PersistPath)) { return $null }
    try {
        $encrypted = Get-Content -Raw -Path $PersistPath
        return ConvertTo-SecureString $encrypted.Trim()
    } catch {
        return $null
    }
}

function Resolve-MiosDistro {
    param([string]$Default = 'podman-MiOS-DEV')
    if ($env:MIOS_WSL_DISTRO) { return $env:MIOS_WSL_DISTRO }
    try {
        $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        if (Test-Path $lxss) {
            $all = @(Get-ChildItem $lxss -ErrorAction SilentlyContinue |
                     ForEach-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DistributionName } |
                     Where-Object { $_ })
            $resolved = ($all | Where-Object { $_ -match 'MiOS' } | Select-Object -First 1)
            if ($resolved) { return $resolved }
            $defGuid = (Get-ItemProperty $lxss -Name DefaultDistribution -ErrorAction SilentlyContinue).DefaultDistribution
            if ($defGuid) {
                $defName = (Get-ItemProperty (Join-Path $lxss $defGuid) -ErrorAction SilentlyContinue).DistributionName
                if ($defName) { return $defName }
            }
            if ($all.Count -gt 0) { return $all[0] }
        }
    } catch {}
    return $Default
}
