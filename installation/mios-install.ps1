# AI-hint: Unified provisioning dispatcher (Windows) -- the canonical implementation of
# `mios-install`, a THIN launcher that validates <target>/--type/--stage, resolves the ONE
# existing entrypoint + argv/env that satisfies the request, and calls it (never reimplements
# it), wrapped in beautiful MiOS-branded, SSOT-derived (runtime [colors]) monitoring of the
# pipeline build/target. Wraps MiOS-Cat.bat, build-mios.ps1, and cat\autounattend\*.ps1.
# Linux-only verbs (build-mios.sh, mios-update) are ssh'd to $env:MIOS_REMOTE_HOST or printed
# ready-to-paste. Sibling to build-mios.ps1/.sh, Get-MiOS.ps1 and cat\; nothing is moved.
# AI-related: mios-install.sh, mios-install.bat, README.md, cat\MiOS-Cat.bat,
# build-mios.ps1, cat\autounattend\Build-MiOSXboxISO.ps1, cat\autounattend\Deploy-MiOSXbox.ps1,
# cat\autounattend\Invoke-MiOSProvision.ps1, cat\autounattend\Build-MiOSSeed.ps1,
# cat\autounattend\Monitor-MiosCat.ps1, mios.toml
# AI-functions: Get-MiosTomlValueSimple, Resolve-MiosTomlPath, Get-MiosPalette, Write-MiosBanner,
#   Write-MiosPhase, Write-MiosLine, Write-MiosKV, Write-MiosSummary, Show-Usage, Test-MiosAdmin,
#   Invoke-MiosSelfElevate, Resolve-Target, Invoke-MiosMonitored
#
# mios-install.ps1 -- unified MiOS provisioning dispatcher (Windows PowerShell 5.1+/pwsh)
#
#   mios-install <target> [--type <name>] [--stage <name>] [--dry-run] [--unattended] [-- <native args>]
#
# Targets: live | xbox | fedora | bootc | oci | seed | flash | build | update
# Stages:  prereqs | fetch | service | iso | flash
# See installation\README.md for the full grammar + the target -> entrypoint mapping table.

$ErrorActionPreference = 'Stop'
$script:Root    = Split-Path -Parent $PSScriptRoot           # repo root (installation\ is one level down)
$script:CatBat  = Join-Path $script:Root 'cat\MiOS-Cat.bat'
$script:BuildPs = Join-Path $script:Root 'build-mios.ps1'
$script:AutoDir = Join-Path $script:Root 'cat\autounattend'

# ============================================================================
#  SSOT theme -- read [colors] from mios.toml at RUNTIME and build an ANSI palette
# ============================================================================
function Resolve-MiosTomlPath {
    $candidates = @(
        (Join-Path $script:Root 'mios.toml'),
        'C:\MiOS\usr\share\mios\mios.toml',
        'C:\MiOS\mios.toml'
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Get-MiosTomlValueSimple {
    param([string]$TomlText, [string]$Section, [string]$Key)
    if (-not $TomlText) { return $null }
    # naive but sufficient: find the [Section] header, read until the next [header], match Key = "value"
    $pattern = "(?ms)^\s*\[" + [regex]::Escape($Section) + "\]\s*(.*?)(?=^\s*\[|\z)"
    $m = [regex]::Match($TomlText, $pattern)
    if (-not $m.Success) { return $null }
    $body = $m.Groups[1].Value
    $km = [regex]::Match($body, "(?m)^\s*" + [regex]::Escape($Key) + "\s*=\s*`"([^`"]*)`"")
    if ($km.Success) { return $km.Groups[1].Value }
    return $null
}

function ConvertTo-Rgb {
    param([string]$Hex, [int[]]$Fallback)
    if ($Hex -and $Hex -match '^#?([0-9A-Fa-f]{6})$') {
        $h = $matches[1]
        return @([Convert]::ToInt32($h.Substring(0,2),16), [Convert]::ToInt32($h.Substring(2,2),16), [Convert]::ToInt32($h.Substring(4,2),16))
    }
    return $Fallback
}

function Get-MiosPalette {
    # Returns a hashtable of ANSI-ready color escape strings, SSOT-derived, degrade-open.
    $toml = Resolve-MiosTomlPath
    $text = if ($toml) { Get-Content -Raw -LiteralPath $toml } else { $null }
    $script:TomlPath = $toml
    # try to enable VT / detect color support
    $script:UseColor = $true
    try { if (-not $Host.UI.SupportsVirtualTerminal -and -not $env:WT_SESSION) { $script:UseColor = $false } } catch { }
    if ($env:MIOS_NO_COLOR -or $env:NO_COLOR) { $script:UseColor = $false }
    $defs = @{
        bg='#282262'; fg='#E7DFD3'; accent='#1A407F'; cursor='#F35C15'; success='#3E7765';
        warning='#F35C15'; error='#DC271B'; info='#1A407F'; muted='#948E8E'; subtle='#B7C9D7';
        silver='#E0E0E0'
    }
    $pal = @{}
    foreach ($k in $defs.Keys) {
        $val = Get-MiosTomlValueSimple -TomlText $text -Section 'colors' -Key $k
        if (-not $val) { $val = $defs[$k] }
        $rgb = ConvertTo-Rgb -Hex $val -Fallback (ConvertTo-Rgb -Hex $defs[$k] -Fallback @(200,200,200))
        $pal[$k] = $rgb
    }
    $script:Pal = $pal
    return $pal
}

$script:ESC = [char]27
function Fg   { param([int[]]$rgb) if (-not $script:UseColor) { return '' }; "$($script:ESC)[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m" }
function Bg   { param([int[]]$rgb) if (-not $script:UseColor) { return '' }; "$($script:ESC)[48;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m" }
function Rst  { if (-not $script:UseColor) { return '' }; "$($script:ESC)[0m" }
function Bold { if (-not $script:UseColor) { return '' }; "$($script:ESC)[1m" }

# ============================================================================
#  Themed output primitives
# ============================================================================
function Write-MiosBanner {
    param([string]$Target, [string]$Type, [string]$Stage)
    $ac = Fg $script:Pal.accent; $fg = Fg $script:Pal.fg; $cu = Fg $script:Pal.cursor
    $su = Fg $script:Pal.subtle; $mu = Fg $script:Pal.muted; $r = Rst; $b = Bold
    $line = ('=' * 66)
    $tt = if ($Type) { $Type } else { '(default)' }
    $ss = if ($Stage) { $Stage } else { 'full pipeline' }
    Write-Host ""
    Write-Host "${ac}${line}${r}"
    Write-Host "${ac}${b}   M i O S  ${r}${cu}${b}/installation${r}  ${mu}-- unified provisioning dispatcher${r}"
    Write-Host "${ac}${line}${r}"
    Write-Host "  ${su}target${r}  ${fg}${b}${Target}${r}"
    Write-Host "  ${su}type${r}    ${fg}${tt}${r}"
    Write-Host "  ${su}stage${r}   ${fg}${ss}${r}"
    if ($script:TomlPath) { Write-Host "  ${su}ssot${r}    ${mu}$($script:TomlPath)${r}" }
    Write-Host "${ac}${line}${r}"
}

function Write-MiosPhase {
    param([string]$Text)
    $ac = Fg $script:Pal.accent; $cu = Fg $script:Pal.cursor; $r = Rst; $b = Bold
    Write-Host ""
    Write-Host ("$ac$b== $r$cu$b$Text$r $ac$b==$r")
}

function Write-MiosLine {
    param([string]$Kind, [string]$Text)
    $r = Rst
    switch ($Kind) {
        'ok'   { Write-Host ("$(Fg $script:Pal.success)[ OK ]$r $Text") }
        'info' { Write-Host ("$(Fg $script:Pal.info)[INFO]$r $Text") }
        'warn' { Write-Host ("$(Fg $script:Pal.warning)[WARN]$r $Text") }
        'err'  { Write-Host ("$(Fg $script:Pal.error)[ERR ]$r $Text") }
        default{ Write-Host $Text }
    }
}

function Write-MiosKV {
    param([string]$Key, [string]$Value)
    $su = Fg $script:Pal.subtle; $fg = Fg $script:Pal.fg; $r = Rst
    Write-Host ("  {0}{1,-10}{2} {3}{4}{5}" -f $su, $Key, $r, $fg, $Value, $r)
}

function Write-MiosSummary {
    param([string]$Target, [int]$ExitCode, [timespan]$Elapsed, [bool]$DryRun)
    $ac = Fg $script:Pal.accent; $r = Rst; $b = Bold
    $line = ('-' * 66)
    Write-Host ""
    Write-Host "$ac$line$r"
    $dur = "{0:mm}m{0:ss}s" -f $Elapsed
    if ($DryRun) {
        Write-Host ("$(Fg $script:Pal.info)$b  DRY-RUN$r  {0}nothing was executed$r" -f (Fg $script:Pal.muted))
    } elseif ($ExitCode -eq 0) {
        Write-Host ("$(Fg $script:Pal.success)$b  SUCCESS$r  target '$Target' completed in $dur $(Fg $script:Pal.muted)(exit 0)$r")
    } else {
        Write-Host ("$(Fg $script:Pal.error)$b  FAILED$r   target '$Target' exited $ExitCode after $dur")
    }
    Write-Host "$ac$line$r"
}

# ============================================================================
#  Usage
# ============================================================================
function Show-Usage {
    $ac = Fg $script:Pal.accent; $fg = Fg $script:Pal.fg; $su = Fg $script:Pal.subtle
    $cu = Fg $script:Pal.cursor; $mu = Fg $script:Pal.muted; $r = Rst; $b = Bold
    Write-Host ""
    Write-Host "${ac}${b} MiOS ${r}${cu}${b} mios-install${r} ${mu}-- one dispatcher, every deployment target${r}"
    Write-Host ""
    Write-Host "${su} USAGE${r}"
    Write-Host "   mios-install ${fg}<target>${r} [--type <name>] [--stage <name>] [--dry-run] [--unattended] [-- <native args>]"
    Write-Host ""
    Write-Host "${su} TARGETS${r}"
    Write-Host "   ${fg}live${r}     boot-and-chat live USB           ${mu}-> MiOS-Cat.bat stage${r}"
    Write-Host "   ${fg}flash${r}    build the bootable MiOS-Cat USB  ${mu}-> MiOS-Cat.bat stage${r}"
    Write-Host "   ${fg}xbox${r}     Windows/Xbox image  --type iso|vm|provision"
    Write-Host "   ${fg}oci${r}      MiOS OCI/bootc image            ${mu}-> build-mios.ps1 -Unattended${r}"
    Write-Host "   ${fg}seed${r}     MiOS-DEV builder seed           ${mu}-> Build-MiOSSeed.ps1${r}"
    Write-Host "   ${fg}build${r}    full artifact matrix            ${mu}-> build-mios.ps1 -Unattended${r}"
    Write-Host "   ${fg}fedora${r}   mutable Fedora bare-metal        ${mu}-> build-mios.sh (Linux/target)${r}"
    Write-Host "   ${fg}bootc${r}    immutable bootc  --type switch|upgrade"
    Write-Host "   ${fg}update${r}   upgrade an installed host       ${mu}-> mios-update (Linux/target)${r}"
    Write-Host ""
    Write-Host "${su} STAGES${r}  ${mu} prereqs | fetch | service | iso | flash  (best-effort unless the target isolates it)${r}"
    Write-Host ""
    Write-Host "${su} EXAMPLES${r}"
    Write-Host "   mios-install flash --dry-run"
    Write-Host "   mios-install xbox --type vm --stage flash"
    Write-Host "   mios-install oci --stage iso --unattended"
    Write-Host "   mios-install seed -- -BuilderDistro MiOS-DEV-2 -Force"
    Write-Host ""
}

# ============================================================================
#  Elevation
# ============================================================================
function Test-MiosAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Invoke-MiosSelfElevate {
    param([string[]]$OrigArgs)
    if (Test-MiosAdmin) { return }
    Write-MiosLine 'info' 'target needs Administrator -- relaunching elevated (UAC)...'
    $psExe = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath) + $OrigArgs
    try {
        $p = Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -PassThru -Wait
        exit $p.ExitCode
    } catch {
        Write-MiosLine 'err' "elevation was declined or failed: $($_.Exception.Message)"
        exit 1
    }
}

# ============================================================================
#  Target -> entrypoint resolution (the mapping table README documents)
# ============================================================================
function Resolve-Target {
    param([string]$Target, [string]$Type, [string]$Stage, [bool]$Unattended, [string[]]$Passthrough)
    $ssot = if ($script:TomlPath) { $script:TomlPath } else { Join-Path $script:Root 'mios.toml' }
    $r = @{ Kind='ps'; Exe=$null; Args=@(); Env=@{}; NeedsAdmin=$false; Notes=@(); PrintOnly=$false; Platform='windows' }

    switch ($Target) {
        { $_ -in 'live','flash' } {
            if ($Type -and $Type -notin 'usb','live') { throw "target '$Target' only supports --type usb (got '$Type')" }
            $r.Kind='bat'; $r.Exe=$script:CatBat; $r.Args=@('stage') + $Passthrough; $r.NeedsAdmin=$true
            if ($Unattended) { $r.Env['NONINTERACTIVE']='1' }
            $r.Notes += 'MiOS-Cat.bat stage is one monolithic pipeline; --stage is documentation-only here.'
        }
        'xbox' {
            $t = if ($Type) { $Type } else { 'iso' }
            switch ($t) {
                'iso' {
                    $r.Exe=(Join-Path $script:AutoDir 'Build-MiOSXboxISO.ps1'); $r.Args=@('-TomlPath', $ssot) + $Passthrough
                }
                'vm' {
                    $r.Exe=(Join-Path $script:AutoDir 'Deploy-MiOSXbox.ps1'); $r.NeedsAdmin=$true
                    $a=@('-TomlPath', $ssot)
                    if ($Stage -eq 'flash') { $a += '-SkipBuild'; $r.Notes += 'stage flash -> -SkipBuild (boot an existing ISO into a Hyper-V VM).' }
                    $r.Args=$a + $Passthrough
                }
                'provision' {
                    $r.Exe=(Join-Path $script:AutoDir 'Invoke-MiOSProvision.ps1'); $r.Args=@('-TomlPath', $ssot) + $Passthrough
                }
                default { throw "target 'xbox' supports --type iso|vm|provision (got '$t')" }
            }
        }
        'oci' {
            $r.Exe=$script:BuildPs; $r.NeedsAdmin=$true; $r.Args=@('-Unattended') + $Passthrough
            if ($Stage -eq 'iso') { $r.Notes += 'stage iso -> full BIB qcow2/raw matrix (MIOS_SKIP_BIB omitted).' }
            else { $r.Env['MIOS_SKIP_BIB']='1'; $r.Notes += 'OCI-only build (MIOS_SKIP_BIB=1); use --stage iso for the full disk-image matrix.' }
        }
        'build' {
            $r.Exe=$script:BuildPs; $r.NeedsAdmin=$true; $r.Args=@('-Unattended') + $Passthrough
            $r.Notes += 'full artifact matrix (OCI + BIB + WSL/Hyper-V/QEMU exports).'
        }
        'seed' {
            $r.Exe=(Join-Path $script:AutoDir 'Build-MiOSSeed.ps1'); $r.Args=@() + $Passthrough
        }
        'fedora' {
            if ($Type -and $Type -ne 'fhs') { throw "target 'fedora' only supports --type fhs (got '$Type')" }
            $r.Platform='linux'
            $env = 'INSTALL_MODE=fhs'
            if ($Unattended) { $env += ' MIOS_FHS_TOTAL_ROOT_MERGE=1 MIOS_PROMPT_TIMEOUT=1' }
            $r.RemoteCmd = "sudo -E env $env bash ./build-mios.sh"
            $r.Notes += 'Linux-only: run ON the target host.'
        }
        'bootc' {
            $t = if ($Type) { $Type } else { 'switch' }
            $r.Platform='linux'
            switch ($t) {
                'switch'  {
                    $env='INSTALL_MODE=bootc'
                    if ($Unattended) { $env += ' MIOS_PROMPT_TIMEOUT=1' }
                    $r.RemoteCmd = "sudo -E env $env bash ./build-mios.sh"
                    $r.Notes += "bootc switch only engages if the target is already bootc-booted; else it falls back to fhs."
                }
                'upgrade' {
                    $flag = if ($Stage -eq 'prereqs') { '--check' } elseif ($Stage -eq 'flash') { '--apply' } else { '--apply' }
                    $r.RemoteCmd = "sudo mios-update $flag"
                }
                default { throw "target 'bootc' supports --type switch|upgrade (got '$t')" }
            }
        }
        'update' {
            $r.Platform='linux'
            $flag = if ($Stage -eq 'prereqs') { '--check' } else { '--apply' }
            $r.RemoteCmd = "sudo mios-update $flag"
        }
        default { throw "unknown target '$Target'. Run with --help for the list." }
    }
    return $r
}

# ============================================================================
#  Monitored execution
# ============================================================================
function Invoke-MiosMonitored {
    param([hashtable]$Plan, [bool]$DryRun, [string]$Target)
    $start = Get-Date

    # env
    foreach ($k in $Plan.Env.Keys) { Set-Item -Path "env:$k" -Value $Plan.Env[$k] }

    if ($Plan.Platform -eq 'linux') {
        Write-MiosPhase "Linux target -- not runnable from Windows directly"
        $cmd = $Plan.RemoteCmd
        if ($env:MIOS_REMOTE_HOST) {
            Write-MiosLine 'info' "ssh $($env:MIOS_REMOTE_HOST): $cmd"
            if ($DryRun) { Write-MiosSummary -Target $Target -ExitCode 0 -Elapsed ((Get-Date)-$start) -DryRun $true; return 0 }
            & ssh $env:MIOS_REMOTE_HOST $cmd
            $rc = $LASTEXITCODE
            Write-MiosSummary -Target $Target -ExitCode $rc -Elapsed ((Get-Date)-$start) -DryRun $false
            return $rc
        } else {
            Write-MiosLine 'warn' 'no $env:MIOS_REMOTE_HOST set -- run this ON the target host:'
            $cu = Fg $script:Pal.cursor; $r = Rst
            Write-Host ""
            Write-Host ("    $cu$cmd$r")
            Write-Host ""
            Write-MiosSummary -Target $Target -ExitCode 0 -Elapsed ((Get-Date)-$start) -DryRun $true
            return 0
        }
    }

    # Windows exe/bat/ps1
    $exe = $Plan.Exe
    if (-not (Test-Path -LiteralPath $exe)) { Write-MiosLine 'err' "entrypoint not found: $exe"; return 1 }
    Write-MiosPhase "Resolved pipeline"
    Write-MiosKV 'call' (Split-Path -Leaf $exe)
    if ($Plan.Args.Count) { Write-MiosKV 'args' ($Plan.Args -join ' ') }
    foreach ($k in $Plan.Env.Keys) { Write-MiosKV "env" ("{0}={1}" -f $k, $Plan.Env[$k]) }
    foreach ($n in $Plan.Notes) { Write-MiosLine 'info' $n }

    if ($DryRun) { Write-MiosSummary -Target $Target -ExitCode 0 -Elapsed ((Get-Date)-$start) -DryRun $true; return 0 }

    Write-MiosPhase "Running -- live monitoring"
    $gut = "$(Fg $script:Pal.accent)|$(Rst)"
    $rc = 0
    if ($Plan.Kind -eq 'bat') {
        & cmd.exe /c "`"$exe`"" @($Plan.Args) 2>&1 | ForEach-Object {
            $el = "{0:mm}:{0:ss}" -f ((Get-Date)-$start)
            Write-Host "$gut $(Fg $script:Pal.muted)$el$(Rst) $_"
        }
        $rc = $LASTEXITCODE
    } else {
        # run the child .ps1 in its own host process for a reliable exit code + clean isolation
        $psHost = (Get-Process -Id $PID).Path
        & $psHost -NoProfile -ExecutionPolicy Bypass -File $exe @($Plan.Args) 2>&1 | ForEach-Object {
            $el = "{0:mm}:{0:ss}" -f ((Get-Date)-$start)
            Write-Host "$gut $(Fg $script:Pal.muted)$el$(Rst) $_"
        }
        $rc = $LASTEXITCODE
    }
    if ($null -eq $rc) { $rc = 0 }
    Write-MiosSummary -Target $Target -ExitCode $rc -Elapsed ((Get-Date)-$start) -DryRun $false
    return $rc
}

# ============================================================================
#  Argument parsing
# ============================================================================
[void](Get-MiosPalette)

$argv = @($args)
if ($argv.Count -eq 0) { Show-Usage; exit 0 }
switch ($argv[0]) { { $_ -in '-h','--help','help','/?' } { Show-Usage; exit 0 } }
if ($argv[0] -like '-*') { Get-MiosPalette | Out-Null; Write-MiosLine 'err' "missing required <target> as the first argument (got '$($argv[0])'). Run --help."; exit 2 }

$Target = $argv[0].ToLower()
$Type = $null; $Stage = $null; $DryRun = $false; $Unattended = $false
$Passthrough = @()
$i = 1
while ($i -lt $argv.Count) {
    $a = $argv[$i]
    switch -regex ($a) {
        '^--type$'       { $Type  = $argv[$i+1]; $i += 2; continue }
        '^--type=(.+)$'  { $Type  = $matches[1]; $i += 1; continue }
        '^--stage$'      { $Stage = $argv[$i+1]; $i += 2; continue }
        '^--stage=(.+)$' { $Stage = $matches[1]; $i += 1; continue }
        '^--dry-run$'    { $DryRun = $true; $i += 1; continue }
        '^--unattended$' { $Unattended = $true; $i += 1; continue }
        '^--$'           { if ($i+1 -lt $argv.Count) { $Passthrough += @($argv[($i+1)..($argv.Count-1)]) }; $i = $argv.Count; continue }
        default          { $Passthrough += $a; $i += 1; continue }
    }
}

$validTargets = @('live','xbox','fedora','bootc','oci','seed','flash','build','update')
if ($Target -notin $validTargets) { Write-MiosLine 'err' "invalid target '$Target' (valid: $($validTargets -join ', '))"; exit 2 }
if ($Stage -and $Stage -notin 'prereqs','fetch','service','iso','flash') { Write-MiosLine 'err' "invalid --stage '$Stage' (valid: prereqs|fetch|service|iso|flash)"; exit 2 }

Write-MiosBanner -Target $Target -Type $Type -Stage $Stage

try {
    $plan = Resolve-Target -Target $Target -Type $Type -Stage $Stage -Unattended $Unattended -Passthrough $Passthrough
} catch {
    Write-MiosLine 'err' $_.Exception.Message
    exit 2
}

if ($plan.NeedsAdmin -and -not $DryRun -and $plan.Platform -eq 'windows') {
    Invoke-MiosSelfElevate -OrigArgs $argv
}

$exit = Invoke-MiosMonitored -Plan $plan -DryRun $DryRun -Target $Target
exit $exit
