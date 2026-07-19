# AI-hint: Unified MiOS provisioning installer (Windows) -- the canonical `mios-install`. It is a
# GUIDED, SELF-EXPLAINING, MiOS-branded front-end (SSOT [colors] rendered at runtime, ANSI/VT force-
# enabled so it looks right even on a bare Windows PowerShell 5.1 host) over the existing entrypoints:
# it explains every choice, warns before anything destructive, confirms, then resolves the ONE real
# entrypoint + argv/env that satisfies the request and runs it with live themed monitoring. It never
# reimplements those entrypoints (MiOS-Cat.bat, build-mios.ps1, cat\autounattend\*.ps1) or moves them.
# Runs on a factory Windows install: missing bits are explained, and the wrapped entrypoints self-
# provision (WSL2/podman for image builds; the repo self-fetches for the web one-liner in Get-MiOS.ps1).
# AI-related: mios-install.sh, mios-install.bat, README.md, Monitor-MiosFlash.ps1, cat\MiOS-Cat.bat,
# build-mios.ps1, Get-MiOS.ps1, cat\autounattend\Build-MiOSXboxISO.ps1, Deploy-MiOSXbox.ps1,
# Invoke-MiOSProvision.ps1, Build-MiOSSeed.ps1, mios.toml
# AI-functions: Resolve-MiosTomlPath, Get-MiosTomlValueSimple, Get-MiosPalette, Enable-MiosVt, C, B,
#   Show-MiosLogo, Rule, Write-MiosLine, Write-MiosKV, Get-MiosCatalog, Show-MiosWelcome,
#   Invoke-MiosGuidedMenu, Show-MiosTargetBrief, Confirm-MiosProceed, Test-MiosAdmin,
#   Invoke-MiosSelfElevate, Resolve-Target, Invoke-MiosMonitored
#
#   mios-install [<target>] [--type <name>] [--stage <name>] [--dry-run] [--unattended] [-- <native args>]
#   No target (or `help`/`menu`) -> the guided menu, which explains every option.

$ErrorActionPreference = 'Stop'
$script:Root    = Split-Path -Parent $PSScriptRoot           # repo root (installation\ is one level down)
$script:CatBat  = Join-Path $script:Root 'cat\MiOS-Cat.bat'
$script:BuildPs = Join-Path $script:Root 'build-mios.ps1'
$script:AutoDir = Join-Path $script:Root 'cat\autounattend'

# ============================================================================
#  SSOT theme -- read [colors] from mios.toml at RUNTIME; force ANSI/VT so the
#  branding renders on a bare Windows PowerShell 5.1 host (VT is off there by default)
# ============================================================================
function Resolve-MiosTomlPath {
    foreach ($c in @((Join-Path $script:Root 'mios.toml'), 'C:\MiOS\usr\share\mios\mios.toml', 'C:\MiOS\mios.toml')) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}
function Get-MiosTomlValueSimple {
    param([string]$TomlText, [string]$Section, [string]$Key)
    if (-not $TomlText) { return $null }
    $m = [regex]::Match($TomlText, "(?ms)^\s*\[" + [regex]::Escape($Section) + "\]\s*(.*?)(?=^\s*\[|\z)")
    if (-not $m.Success) { return $null }
    $km = [regex]::Match($m.Groups[1].Value, "(?m)^\s*" + [regex]::Escape($Key) + "\s*=\s*`"([^`"]*)`"")
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
function Enable-MiosVt {
    $script:NoColor = $false
    if ($env:MIOS_NO_COLOR -or $env:NO_COLOR) { $script:NoColor = $true; return }
    try {
        $sig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);' +
               '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);' +
               '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
        $k = Add-Type -MemberDefinition $sig -Name 'MiosVt' -Namespace 'MiosInstall' -PassThru -ErrorAction Stop
        $h = $k::GetStdHandle(-11); $m = 0
        if ($k::GetConsoleMode($h, [ref]$m)) { [void]$k::SetConsoleMode($h, ($m -bor 0x0004)) }
    } catch {}
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
}
function Get-MiosPalette {
    $toml = Resolve-MiosTomlPath
    $text = if ($toml) { Get-Content -Raw -LiteralPath $toml } else { $null }
    $script:TomlPath = $toml
    $defs = @{ bg='#282262'; fg='#E7DFD3'; accent='#1A407F'; cursor='#F35C15'; success='#3E7765';
               warning='#F35C15'; error='#DC271B'; info='#1A407F'; muted='#948E8E'; subtle='#B7C9D7'; silver='#E0E0E0' }
    $pal = @{}
    foreach ($key in $defs.Keys) {
        $val = Get-MiosTomlValueSimple -TomlText $text -Section 'colors' -Key $key
        if (-not $val) { $val = $defs[$key] }
        $pal[$key] = ConvertTo-Rgb -Hex $val -Fallback (ConvertTo-Rgb -Hex $defs[$key] -Fallback @(200,200,200))
    }
    $script:Pal = $pal
}
$script:ESC = [char]27
# C: colored text (SSOT palette); B: bold. Text is a param, so no bare-var/backtick pitfalls.
function C { param([int[]]$rgb, [string]$t) if ($script:NoColor) { return $t }; "$script:ESC[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$t$script:ESC[0m" }
function B { param([string]$t) if ($script:NoColor) { return $t }; "$script:ESC[1m$t$script:ESC[0m" }
function Rule { param([int]$w=64) C $script:Pal.accent ([string]([char]0x2550) * $w) }

function Show-MiosLogo {
    param([string]$Subtitle = 'the MiOS installer')
    $ac = $script:Pal.accent; $cu = $script:Pal.cursor; $mu = $script:Pal.muted; $su = $script:Pal.subtle
    Write-Host ""
    Write-Host ("  " + (C $ac (B '███╗   ███╗██╗ ██████╗ ███████╗')))
    Write-Host ("  " + (C $ac (B '████╗ ████║██║██╔═══██╗██╔════╝')) + "   " + (C $cu (B 'C A T')))
    Write-Host ("  " + (C $ac (B '██╔████╔██║██║██║   ██║███████╗')) + "   " + (C $mu $Subtitle))
    Write-Host ("  " + (C $ac (B '██║╚██╔╝██║██║██║   ██║╚════██║')))
    Write-Host ("  " + (C $ac (B '██║ ╚═╝ ██║██║╚██████╔╝███████║')) + "   " + (C $su 'SecureBoot · UEFI · GPT'))
    Write-Host ("  " + (C $ac (B '╚═╝     ╚═╝╚═╝ ╚═════╝ ╚══════╝')))
    Write-Host ("  " + (Rule))
}
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
function Write-MiosKV {
    param([string]$Key, [string]$Value)
    Write-Host ("    " + (C $script:Pal.subtle ("{0,-9}" -f $Key)) + " " + (C $script:Pal.fg $Value))
}

# ============================================================================
#  Target catalog -- every option, in plain English (what / produces / cost / warning)
# ============================================================================
function Get-MiosCatalog {
    [ordered]@{
        'flash' = @{ title = 'Build a bootable MiOS-Cat USB'; platform='windows'; needsAdmin=$true; destructive=$true
            what = 'Wipes a USB stick and forges a complete MiOS boot drive: the Ventoy bootloader (SecureBoot/UEFI/GPT), the Fedora + MiOS-Xbox installers, recovery tools (WinPE + SystemRescue), and an offline copy of the MiOS repos.'
            produces = 'A USB you can boot on ANY PC to install or recover MiOS.'
            cost = '20-40 min (downloads + image builds, faster if cached)'
            needs = 'A blank USB stick, and this machine as Administrator.' }
        'live' = @{ title = 'Boot-and-chat live USB (zero install)'; platform='windows'; needsAdmin=$true; destructive=$true
            what = 'Same as flash, but tuned so the USB boots straight into an ephemeral MiOS that you can chat with -- no install, nothing written to the target PC.'
            produces = 'A USB that boots MiOS + its local AI, then discards everything on reboot.'
            cost = '20-40 min'; needs = 'A blank USB stick + Administrator.' }
        'xbox' = @{ title = 'Build the MiOS-Xbox Windows image  (--type iso|vm|provision)'; platform='windows'; needsAdmin=$false; destructive=$false
            what = 'Compiles the MiOS-Xbox edition: a debloated, gaming-tuned Windows 11 image. --type iso builds the installer ISO (default); vm boots it in Hyper-V; provision applies it to this box.'
            produces = 'MiOS-Xbox.iso (or a running VM), universal base drivers, no vendor bloat.'
            cost = 'iso: 20-40 min (UUP + DISM + oscdimg)'; needs = 'DISM (ships with Windows). vm needs Hyper-V (Administrator).' }
        'oci' = @{ title = 'Build the MiOS OCI / bootc image'; platform='windows'; needsAdmin=$true; destructive=$false
            what = 'Builds the immutable MiOS container image (localhost/mios:latest) inside the MiOS-DEV WSL2/podman builder, which is auto-provisioned if this is a fresh Windows.'
            produces = 'The bootc OCI image (add --stage iso for the full qcow2/raw disk matrix).'
            cost = '20-60 min first run (installs WSL2 + podman, pulls layers)'; needs = 'WSL2 + podman (auto-installed) + Administrator.' }
        'build' = @{ title = 'Build the FULL artifact matrix'; platform='windows'; needsAdmin=$true; destructive=$false
            what = 'Everything oci does, plus every export format: WSL2 .tar/.vhdx, Hyper-V .vhdx, QEMU qcow2, live ISO, and BIB disk images.'
            produces = 'All MiOS deployment artifacts under the builder output dir.'
            cost = '45-90 min'; needs = 'WSL2 + podman (auto-installed) + Administrator.' }
        'seed' = @{ title = 'Provision the MiOS-DEV builder (seed)'; platform='windows'; needsAdmin=$false; destructive=$false
            what = 'Stands up the MiOS-DEV WSL2 build distro on this machine so you can build images locally, without building anything yet.'
            produces = 'A ready MiOS-DEV builder distro.'
            cost = '10-30 min'; needs = 'WSL2 (auto-installed).' }
        'fedora' = @{ title = 'Deploy MiOS on bare-metal Fedora  (Linux/target)'; platform='linux'; needsAdmin=$false; destructive=$false
            what = 'Turns a minimal Fedora host into a full mutable MiOS server (build-mios.sh overlay). Runs ON the Linux target, not here.'
            produces = 'A native MiOS server, at parity with the WSL MiOS-Dev but bare-metal.'
            cost = 'runs on the target'; needs = 'A Fedora host; set $env:MIOS_REMOTE_HOST to ssh it, or copy the printed command.' }
        'bootc' = @{ title = 'Immutable bootc install/upgrade  (--type switch|upgrade, Linux/target)'; platform='linux'; needsAdmin=$false; destructive=$false
            what = 'switch: point an already-bootc Fedora host at the MiOS image. upgrade: pull the newest MiOS onto an installed host. Runs ON the Linux target.'
            produces = 'An immutable MiOS bootc host.'
            cost = 'runs on the target'; needs = 'A bootc/MiOS host; $env:MIOS_REMOTE_HOST or the printed command.' }
        'update' = @{ title = 'Upgrade an installed MiOS host  (Linux/target)'; platform='linux'; needsAdmin=$false; destructive=$false
            what = 'Runs mios-update on an already-installed MiOS host to pull + apply the latest image.'
            produces = 'An up-to-date MiOS host.'
            cost = 'runs on the target'; needs = 'An installed MiOS host; $env:MIOS_REMOTE_HOST or the printed command.' }
        'configure' = @{ title = 'Open the MiOS Portal / configurator (edit the SSOT)'; platform='windows'; needsAdmin=$false; destructive=$false; special='configure'
            what = 'Opens the MiOS Portal at http://localhost:8640/configure -- the ONE web surface where you edit mios.toml (the SSOT). Changes save to your user layer and project to every MiOS surface. Falls back to the MiOS-DEV launcher, then the offline configurator HTML, if the Portal is not up.'
            produces = 'The live SSOT configurator (or the offline mios.html).'
            cost = 'instant'; needs = 'The MiOS Portal (agent-pipe) on :8640, the MiOS-DEV builder, or an offline configurator.' }
    }
}

# ============================================================================
#  Guided, self-explaining menu
# ============================================================================
function Show-MiosWelcome {
    $mu = $script:Pal.muted; $fg = $script:Pal.fg; $su = $script:Pal.subtle
    Write-Host ("  " + (C $fg 'This is the MiOS installer. Pick what you want to build or deploy below -- each option'))
    Write-Host ("  " + (C $fg 'explains what it does, what it produces, and how long it takes before anything happens.'))
    Write-Host ("  " + (C $mu 'Nothing is erased or built until you choose it and confirm. Ctrl+C exits at any time.'))
    Write-Host ("  " + (Rule))
}
function Invoke-MiosGuidedMenu {
    param([hashtable]$Catalog)
    Show-MiosLogo -Subtitle 'the MiOS installer'
    Show-MiosWelcome
    $keys = @($Catalog.Keys)
    $cu = $script:Pal.cursor; $fg = $script:Pal.fg; $mu = $script:Pal.muted; $su = $script:Pal.subtle; $wa = $script:Pal.warning
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = $keys[$i]; $e = $Catalog[$k]
        $num = C $cu (B ("{0,2}" -f ($i+1)))
        $name = C $fg (B ("{0,-7}" -f $k))
        Write-Host ("  $num  $name " + (C $su $e.title))
        Write-Host ("       " + (C $mu $e.what))
        $tag = "      $((C $su 'time:')) $((C $fg $e.cost))"
        if ($e.destructive) { $tag += "    " + (C $wa (B 'WARNING: erases the target USB')) }
        Write-Host $tag
        Write-Host ""
    }
    Write-Host ("  " + (Rule))
    Write-Host ("   " + (C $cu (B ' 0')) + "  " + (C $fg (B 'quit')) + "    " + (C $mu 'exit without doing anything'))
    Write-Host ""
    while ($true) {
        $sel = Read-Host ("  " + (C $cu (B 'Choose 1-' + $keys.Count + ' (or 0 to quit)')))
        if ($sel -match '^\s*0\s*$' -or $sel -match '^(?i:q|quit|exit)$') { Write-MiosLine 'info' 'Nothing done. Bye.'; exit 0 }
        if ($sel -match '^\s*(\d+)\s*$' -and [int]$matches[1] -ge 1 -and [int]$matches[1] -le $keys.Count) {
            return $keys[[int]$matches[1] - 1]
        }
        Write-MiosLine 'warn' "Enter a number 1-$($keys.Count), or 0 to quit."
    }
}
function Show-MiosTargetBrief {
    param([string]$Target, [hashtable]$Entry, [string]$Type, [string]$Stage)
    $ac=$script:Pal.accent; $fg=$script:Pal.fg; $su=$script:Pal.subtle; $cu=$script:Pal.cursor; $mu=$script:Pal.muted; $wa=$script:Pal.warning
    Write-Host ""
    Write-Host ("  " + (C $cu (B ('>> ' + $Target))) + "  " + (C $fg (B $Entry.title)))
    Write-Host ("  " + (Rule))
    Write-Host ("  " + (C $su 'What it does : ') + (C $fg $Entry.what))
    Write-Host ("  " + (C $su 'Produces     : ') + (C $fg $Entry.produces))
    Write-Host ("  " + (C $su 'Takes        : ') + (C $fg $Entry.cost))
    Write-Host ("  " + (C $su 'Needs        : ') + (C $fg $Entry.needs))
    if ($Type)  { Write-Host ("  " + (C $su 'Type         : ') + (C $fg $Type)) }
    if ($Stage) { Write-Host ("  " + (C $su 'Stage        : ') + (C $fg $Stage)) }
    if ($script:TomlPath) { Write-Host ("  " + (C $su 'SSOT config  : ') + (C $mu $script:TomlPath)) }
    Write-Host ("  " + (Rule))
}
function Confirm-MiosProceed {
    param([hashtable]$Entry, [bool]$Unattended, [string]$Drive)
    if ($Unattended) { return $true }
    if (-not [Environment]::UserInteractive) { return $true }
    $wa=$script:Pal.warning; $cu=$script:Pal.cursor; $fg=$script:Pal.fg
    if ($Entry.destructive) {
        Write-Host ("  " + (C $wa (B "!!  This ERASES the entire target USB disk ($Drive). All data on it is lost.")))
        $ans = Read-Host ("  " + (C $cu (B "Type ERASE to wipe $Drive and build, or anything else to cancel")))
        if ($ans -cne 'ERASE') { Write-MiosLine 'info' 'Cancelled -- nothing was touched.'; return $false }
        return $true
    }
    $ans = Read-Host ("  " + (C $cu (B 'Proceed? [Y/n]')))
    if ($ans -match '^(?i:n|no)$') { Write-MiosLine 'info' 'Cancelled.'; return $false }
    return $true
}

# ============================================================================
#  Elevation
# ============================================================================
function Test-MiosAdmin {
    try { (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false }
}
function Invoke-MiosSelfElevate {
    param([string[]]$OrigArgs)
    if (Test-MiosAdmin) { return }
    Write-MiosLine 'info' 'This step needs Administrator -- relaunching with a UAC prompt (click Yes)...'
    $psExe = (Get-Process -Id $PID).Path
    try {
        $p = Start-Process -FilePath $psExe -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath) + $OrigArgs) -Verb RunAs -PassThru -Wait
        exit $p.ExitCode
    } catch { Write-MiosLine 'err' "Elevation was declined -- re-run from an Administrator terminal. ($($_.Exception.Message))"; exit 1 }
}

# ============================================================================
#  Target -> entrypoint resolution + themed monitored execution (unchanged logic)
# ============================================================================
function Resolve-Target {
    param([string]$Target, [string]$Type, [string]$Stage, [bool]$Unattended, [string[]]$Passthrough)
    $ssot = if ($script:TomlPath) { $script:TomlPath } else { Join-Path $script:Root 'mios.toml' }
    $r = @{ Kind='ps'; Exe=$null; Args=@(); Env=@{}; NeedsAdmin=$false; Notes=@(); Platform='windows'; Drive='D:' }
    switch ($Target) {
        { $_ -in 'live','flash' } {
            if ($Type -and $Type -notin 'usb','live') { throw "target '$Target' only supports --type usb (got '$Type')" }
            $r.Kind='bat'; $r.Exe=$script:CatBat; $r.Args=@('stage') + $Passthrough; $r.NeedsAdmin=$true
            if ($Unattended) { $r.Env['NONINTERACTIVE']='1' }
            $ssotText = if (Test-Path $ssot) { Get-Content -Raw $ssot } else { '' }
            $d = Get-MiosTomlValueSimple -TomlText $ssotText -Section 'cat' -Key 'drivepath'
            if ($d) { $r.Drive = "$($d):" }
        }
        'xbox' {
            $t = if ($Type) { $Type } else { 'iso' }
            switch ($t) {
                'iso'       { $r.Exe=(Join-Path $script:AutoDir 'Build-MiOSXboxISO.ps1'); $r.Args=@('-TomlPath', $ssot) + $Passthrough }
                'vm'        { $r.Exe=(Join-Path $script:AutoDir 'Deploy-MiOSXbox.ps1'); $r.NeedsAdmin=$true; $a=@('-TomlPath', $ssot); if ($Stage -eq 'flash') { $a += '-SkipBuild' }; $r.Args=$a + $Passthrough }
                'provision' { $r.Exe=(Join-Path $script:AutoDir 'Invoke-MiOSProvision.ps1'); $r.Args=@('-TomlPath', $ssot) + $Passthrough }
                default     { throw "target 'xbox' supports --type iso|vm|provision (got '$t')" }
            }
        }
        'oci' {
            $r.Exe=$script:BuildPs; $r.NeedsAdmin=$true; $r.Args=@('-Unattended') + $Passthrough
            if ($Stage -eq 'iso') { $r.Notes += 'full BIB qcow2/raw matrix' } else { $r.Env['MIOS_SKIP_BIB']='1' }
        }
        'build' { $r.Exe=$script:BuildPs; $r.NeedsAdmin=$true; $r.Args=@('-Unattended') + $Passthrough }
        'seed'  { $r.Exe=(Join-Path $script:AutoDir 'Build-MiOSSeed.ps1'); $r.Args=@() + $Passthrough }
        'fedora' {
            if ($Type -and $Type -ne 'fhs') { throw "target 'fedora' only supports --type fhs (got '$Type')" }
            $r.Platform='linux'; $e='INSTALL_MODE=fhs'; if ($Unattended) { $e += ' MIOS_FHS_TOTAL_ROOT_MERGE=1 MIOS_PROMPT_TIMEOUT=1' }
            $r.RemoteCmd = "sudo -E env $e bash ./build-mios.sh"
        }
        'bootc' {
            $t = if ($Type) { $Type } else { 'switch' }; $r.Platform='linux'
            switch ($t) {
                'switch'  { $e='INSTALL_MODE=bootc'; if ($Unattended) { $e += ' MIOS_PROMPT_TIMEOUT=1' }; $r.RemoteCmd = "sudo -E env $e bash ./build-mios.sh" }
                'upgrade' { $flag = if ($Stage -eq 'prereqs') { '--check' } else { '--apply' }; $r.RemoteCmd = "sudo mios-update $flag" }
                default   { throw "target 'bootc' supports --type switch|upgrade (got '$t')" }
            }
        }
        'update' { $r.Platform='linux'; $flag = if ($Stage -eq 'prereqs') { '--check' } else { '--apply' }; $r.RemoteCmd = "sudo mios-update $flag" }
        default  { throw "unknown target '$Target'." }
    }
    return $r
}
function Invoke-MiosMonitored {
    param([hashtable]$Plan, [bool]$DryRun, [string]$Target)
    $start = Get-Date
    foreach ($k in $Plan.Env.Keys) { Set-Item -Path "env:$k" -Value $Plan.Env[$k] }
    if ($Plan.Platform -eq 'linux') {
        Write-Host ""; Write-MiosLine 'info' "'$Target' runs on the Linux target machine, not on Windows."
        $cmd = $Plan.RemoteCmd
        if ($env:MIOS_REMOTE_HOST -and -not $DryRun) {
            Write-MiosLine 'info' "ssh $($env:MIOS_REMOTE_HOST): $cmd"
            & ssh $env:MIOS_REMOTE_HOST $cmd; $rc = $LASTEXITCODE
            return $rc
        }
        Write-MiosLine 'info' 'Run this ON the target host (or set $env:MIOS_REMOTE_HOST to ssh it for you):'
        Write-Host ""; Write-Host ("    " + (C $script:Pal.cursor $cmd)); Write-Host ""
        return 0
    }
    $exe = $Plan.Exe
    if (-not (Test-Path -LiteralPath $exe)) { Write-MiosLine 'err' "entrypoint not found (repo incomplete?): $exe"; return 1 }
    $argStr = if ($Plan.Args.Count) { ' ' + ($Plan.Args -join ' ') } else { '' }
    Write-Host ""; Write-MiosLine 'info' ("Launching " + (Split-Path -Leaf $exe) + $argStr)
    foreach ($k in $Plan.Env.Keys) { Write-MiosKV 'env' ("{0}={1}" -f $k, $Plan.Env[$k]) }
    if ($DryRun) { Write-Host ""; Write-MiosLine 'info' 'DRY-RUN -- nothing was executed.'; return 0 }
    Write-Host ("  " + (Rule)); Write-Host ("  " + (C $script:Pal.subtle 'live output (elapsed | line):')); Write-Host ""
    $gut = C $script:Pal.accent ([string][char]0x2502)
    if ($Plan.Kind -eq 'bat') {
        & cmd.exe /c "`"$exe`"" @($Plan.Args) 2>&1 | ForEach-Object { Write-Host ("   $gut " + (C $script:Pal.muted ("{0:mm}:{0:ss}" -f ((Get-Date)-$start))) + " $_") }
        $rc = $LASTEXITCODE
    } else {
        $psHost = (Get-Process -Id $PID).Path
        & $psHost -NoProfile -ExecutionPolicy Bypass -File $exe @($Plan.Args) 2>&1 | ForEach-Object { Write-Host ("   $gut " + (C $script:Pal.muted ("{0:mm}:{0:ss}" -f ((Get-Date)-$start))) + " $_") }
        $rc = $LASTEXITCODE
    }
    if ($null -eq $rc) { $rc = 0 }
    Write-Host ("  " + (Rule))
    $dur = "{0:mm}m{0:ss}s" -f ((Get-Date)-$start)
    if ($rc -eq 0) { Write-Host ("  " + (C $script:Pal.success (B "  DONE  '$Target' completed in $dur."))) }
    else           { Write-Host ("  " + (C $script:Pal.error   (B "  FAILED  '$Target' exited $rc after $dur -- see the output above."))) }
    return $rc
}

# ============================================================================
#  Configure -- open the unified Portal / configurator (the one SSOT editor)
# ============================================================================
function Invoke-MiosConfigure {
    $url = 'http://localhost:8640/configure'
    $up = $false
    foreach ($probe in 'http://localhost:8640/portal/config/status', $url) {
        try { $resp = Invoke-WebRequest -Uri $probe -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop; if ($resp) { $up = $true; break } } catch {}
    }
    if ($up) {
        Write-MiosLine 'ok' "MiOS Portal is up -- opening the SSOT configurator: $url"
        try { Start-Process $url } catch { Write-MiosLine 'info' "Open it in a browser: $url" }
        return 0
    }
    Write-MiosLine 'warn' 'The MiOS Portal (:8640) is not answering yet.'
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        $distros = & wsl.exe -l -q 2>$null
        if ($distros -match 'MiOS-DEV') {
            Write-MiosLine 'info' 'Launching the configurator via the MiOS-DEV builder (brings the Portal up if needed)...'
            try { Start-Process 'wsl.exe' -ArgumentList '-d','MiOS-DEV','--','/usr/libexec/mios/mios-configurator-launch'; return 0 } catch {}
        }
    }
    foreach ($off in (Join-Path $env:USERPROFILE 'Downloads\mios-configurator.html'), (Join-Path $env:USERPROFILE 'Downloads\mios.html')) {
        if (Test-Path $off) {
            Write-MiosLine 'info' "Portal offline -- opening the offline configurator: $off"
            try { Start-Process $off } catch { Write-MiosLine 'info' "Open it in a browser: $off" }
            return 0
        }
    }
    Write-MiosLine 'err' 'No Portal on :8640, no MiOS-DEV builder, and no offline configurator found.'
    Write-MiosLine 'info' 'Build the MiOS image first ("oci" or "seed"); the Portal then serves the configurator at http://localhost:8640/configure.'
    return 1
}

# ============================================================================
#  Main
# ============================================================================
Enable-MiosVt
Get-MiosPalette
$catalog = Get-MiosCatalog
$argv = @($args)

# Parse flags out first; the first non-flag token is the target (optional).
$Target = $null; $Type = $null; $Stage = $null; $DryRun = $false; $Unattended = $false; $Passthrough = @()
$i = 0
while ($i -lt $argv.Count) {
    $a = $argv[$i]
    switch -regex ($a) {
        '^(?i:-h|--help|/\?)$'    { $Target = 'help'; $i++; continue }
        '^--type$'                { $Type = $argv[$i+1]; $i += 2; continue }
        '^--type=(.+)$'           { $Type = $matches[1]; $i++; continue }
        '^--stage$'               { $Stage = $argv[$i+1]; $i += 2; continue }
        '^--stage=(.+)$'          { $Stage = $matches[1]; $i++; continue }
        '^--dry-run$'             { $DryRun = $true; $i++; continue }
        '^--unattended$'          { $Unattended = $true; $i++; continue }
        '^--$'                    { if ($i+1 -lt $argv.Count) { $Passthrough += @($argv[($i+1)..($argv.Count-1)]) }; $i = $argv.Count; continue }
        '^-'                      { $Passthrough += $a; $i++; continue }
        default                   { if (-not $Target) { $Target = $a.ToLower() } else { $Passthrough += $a }; $i++; continue }
    }
}

# No target, or explicit help/menu -> the guided, explained menu.
if (-not $Target -or $Target -in 'help','menu') {
    $Target = Invoke-MiosGuidedMenu -Catalog $catalog
    $script:FromMenu = $true
}

if (-not $catalog.Contains($Target)) {
    Show-MiosLogo
    Write-MiosLine 'err' "'$Target' isn't a MiOS install target."
    Write-MiosLine 'info' "Valid: $(( @($catalog.Keys)) -join ', ') -- or run with no arguments for the guided menu."
    exit 2
}
if ($Stage -and $Stage -notin 'prereqs','fetch','service','iso','flash') {
    Write-MiosLine 'err' "invalid --stage '$Stage' (valid: prereqs|fetch|service|iso|flash)"; exit 2
}

$entry = $catalog[$Target]
if (-not $script:FromMenu) { Show-MiosLogo }
Show-MiosTargetBrief -Target $Target -Entry $entry -Type $Type -Stage $Stage

# 'configure' opens the unified Portal/configurator instead of running a build pipeline.
if ($entry.special -eq 'configure') { exit (Invoke-MiosConfigure) }

try {
    $plan = Resolve-Target -Target $Target -Type $Type -Stage $Stage -Unattended $Unattended -Passthrough $Passthrough
} catch { Write-MiosLine 'err' $_.Exception.Message; exit 2 }

if (-not $DryRun -and -not (Confirm-MiosProceed -Entry $entry -Unattended $Unattended -Drive $plan.Drive)) { exit 0 }

if ($plan.NeedsAdmin -and -not $DryRun -and $plan.Platform -eq 'windows') {
    Invoke-MiosSelfElevate -OrigArgs $argv
}

exit (Invoke-MiosMonitored -Plan $plan -DryRun $DryRun -Target $Target)
