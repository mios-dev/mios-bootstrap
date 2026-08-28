[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$Type = '',
    [string]$Stage = '',
    [switch]$DryRun,
    [switch]$Unattended,
    [parameter(ValueFromRemainingArguments=$true)][string[]]$Passthrough = @()
)

# AI-hint: Unified MiOS provisioning installer (Windows) -- the canonical `mios-install`.
$ErrorActionPreference = 'Stop'
$script:Root    = Split-Path -Parent $PSScriptRoot           # repo root (installation\ is one level down)
$script:CatBat  = Join-Path $script:Root 'installation\MiOS-Cat.bat'
if (-not (Test-Path $script:CatBat)) { $script:CatBat = Join-Path $script:Root 'cat\MiOS-Cat.bat' }
$script:BuildPs = Join-Path $script:Root 'build-mios.ps1'
$script:AutoDir = Join-Path $script:Root 'cat\autounattend'

# ============================================================================
#  Shared library
# ============================================================================
. (Join-Path $PSScriptRoot 'mios-common.ps1')

function Show-MiosLogo {
    param([string]$Subtitle = 'the MiOS installer')
    $ac = $script:Pal.accent; $cu = $script:Pal.cursor; $mu = $script:Pal.muted; $su = $script:Pal.subtle
    Write-Host ""
    Write-Host ("  " + (C $ac (B '███╗   ███╗██╗ ██████╗ ███████╗')))
    Write-Host ("  " + (C $ac (B '████╗ ████║╚═╝██╔═══██╗██╔════╝')) + "   " + (C $cu (B 'C A T')))
    Write-Host ("  " + (C $ac (B '██╔████╔██║██╗██║   ██║███████╗')) + "   " + (C $mu $Subtitle))
    Write-Host ("  " + (C $ac (B '██║╚██╔╝██║██║██║   ██║╚════██║')))
    Write-Host ("  " + (C $ac (B '██║ ╚═╝ ██║██║╚██████╔╝███████║')) + "   " + (C $su 'SecureBoot · UEFI · GPT'))
    Write-Host ("  " + (C $ac (B '╚═╝     ╚═╝╚═╝ ╚═════╝ ╚══════╝')))
    Write-Host ("  " + (Rule))
}

# ============================================================================
#  Target catalog -- unified options
# ============================================================================
function Get-MiosCatalog {
    [ordered]@{
        'flash' = @{ title = 'Build a bootable MiOS-Cat USB'; platform='windows'; needsAdmin=$true; destructive=$true
            what = 'Wipes a USB stick and forges a complete MiOS boot drive: Ventoy bootloader (SecureBoot/UEFI/GPT), Fedora + MiOS-Xbox installers, recovery tools, and offline MiOS repos.'
            produces = 'A USB you can boot on ANY PC to install or recover MiOS.'
            cost = '20-40 min'
            needs = 'A blank USB stick + Administrator.' }
        'monitor' = @{ title = 'Launch unified live TUI system monitor / dashboard'; platform='windows'; needsAdmin=$false; destructive=$false; special='monitor'
            what = 'Renders the live multi-panel grid TUI dashboard directly in this active console window (system hardware telemetry, network service probes, and rolling system log stream).'
            produces = 'Full-grid live TUI dashboard.'
            cost = 'instant'; needs = 'Terminal console window.' }
        'live' = @{ title = 'Boot-and-chat live USB (zero install)'; platform='windows'; needsAdmin=$true; destructive=$true
            what = 'Same as flash, but tuned so the USB boots straight into an ephemeral MiOS.'
            produces = 'A USB that boots MiOS + local AI.'
            cost = '20-40 min'; needs = 'Blank USB stick + Administrator.' }
        'xbox' = @{ title = 'Build the MiOS-Xbox Windows image (--type iso|vm|provision)'; platform='windows'; needsAdmin=$false; destructive=$false
            what = 'Compiles the MiOS-Xbox gaming-tuned Windows 11 image.'
            produces = 'MiOS-Xbox.iso base image.'
            cost = '20-40 min'; needs = 'DISM.' }
        'oci' = @{ title = 'Build the MiOS OCI / bootc image'; platform='windows'; needsAdmin=$true; destructive=$false
            what = 'Builds the immutable MiOS container image (localhost/mios:latest).'
            produces = 'The bootc OCI image.'
            cost = '20-60 min'; needs = 'WSL2 + podman + Administrator.' }
        'build' = @{ title = 'Build the FULL artifact matrix'; platform='windows'; needsAdmin=$true; destructive=$false
            what = 'Builds all export formats: WSL2, Hyper-V, QEMU qcow2, live ISO.'
            produces = 'All MiOS deployment artifacts.'
            cost = '45-90 min'; needs = 'WSL2 + podman + Administrator.' }
        'configure' = @{ title = 'Open the MiOS Portal / configurator (edit SSOT)'; platform='windows'; needsAdmin=$false; destructive=$false; special='configure'
            what = 'Opens the MiOS Portal at http://localhost:<ports.agent_pipe>/configure to edit mios.toml.'
            produces = 'Live SSOT configurator.'
            cost = 'instant'; needs = 'MiOS Portal on SSOT agent_pipe port or offline configurator.' }
        'provision' = @{ title = 'Provision MiOS-Xbox on a target'; platform='windows'; needsAdmin=$true; destructive=$false
            what = 'Runs Invoke-MiOSProvision.ps1 using the SSOT configuration.'
            produces = 'Provisioned MiOS-Xbox.'
            cost = '10-20 min'; needs = 'Administrator.' }
        'test-vm' = @{ title = 'Deploy / test MiOS-Xbox VM (Hyper-V)'; platform='windows'; needsAdmin=$true; destructive=$false
            what = 'Runs Deploy-MiOSXbox.ps1 to create and boot a Hyper-V test VM.'
            produces = 'MiOS-Xbox Hyper-V VM.'
            cost = '2-5 min'; needs = 'Hyper-V + Administrator.' }
        'update' = @{ title = 'Update MiOS (pull latest)'; platform='windows'; needsAdmin=$false; destructive=$false; special='update'
            what = 'Pulls the latest MiOS and mios-bootstrap from their remotes.'
            produces = 'Updated repositories.'
            cost = '1-2 min'; needs = 'Internet connection.' }
        'repos' = @{ title = 'Repository Tools (open repos)'; platform='windows'; needsAdmin=$false; destructive=$false; special='repos'
            what = 'Opens the repository directories in Explorer.'
            produces = 'Explorer windows.'
            cost = 'instant'; needs = 'Explorer.' }
    }
}

function Show-MiosWelcome {
    $mu = $script:Pal.muted; $fg = $script:Pal.fg
    Write-Host ("  " + (C $fg 'This is the unified MiOS installer & dashboard dispatcher.'))
    Write-Host ("  " + (C $fg 'Select an option below. Ctrl+C exits at any time.'))
    Write-Host ("  " + (Rule))
}

function Invoke-MiosGuidedMenu {
    param([hashtable]$Catalog)
    Show-MiosLogo -Subtitle 'the MiOS installer & dashboard'
    Show-MiosWelcome
    $keys = @($Catalog.Keys)
    $cu = $script:Pal.cursor; $fg = $script:Pal.fg; $mu = $script:Pal.muted; $su = $script:Pal.subtle; $wa = $script:Pal.warning
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = $keys[$i]; $e = $Catalog[$k]
        $num = C $cu (B ("{0,2}" -f ($i+1)))
        $name = C $fg (B ("{0,-9}" -f $k))
        Write-Host ("  $num  $name " + (C $su $e.title))
        Write-Host ("         " + (C $mu $e.what))
        $tag = "        $((C $su 'time:')) $((C $fg $e.cost))"
        if ($e.destructive) { $tag += "    " + (C $wa (B 'WARNING: erases target USB')) }
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
    $fg=$script:Pal.fg; $su=$script:Pal.subtle; $cu=$script:Pal.cursor; $mu=$script:Pal.muted
    Write-Host ""
    Write-Host ("  " + (C $cu (B ('>> ' + $Target))) + "  " + (C $fg (B $Entry.title)))
    Write-Host ("  " + (Rule))
    Write-Host ("  " + (C $su 'What it does : ') + (C $fg $Entry.what))
    Write-Host ("  " + (C $su 'Produces     : ') + (C $fg $Entry.produces))
    Write-Host ("  " + (C $su 'Takes        : ') + (C $fg $Entry.cost))
    if ($script:TomlPath) { Write-Host ("  " + (C $su 'SSOT config  : ') + (C $mu $script:TomlPath)) }
    Write-Host ("  " + (Rule))
}

function Confirm-MiosProceed {
    param([hashtable]$Entry, [bool]$Unattended, [string]$Drive)
    if ($Unattended) { return $true }
    if (-not [Environment]::UserInteractive) { return $true }
    $wa=$script:Pal.warning; $cu=$script:Pal.cursor
    if ($Entry.destructive) {
        Write-Host ("  " + (C $wa (B "!!  This ERASES the entire target USB disk ($Drive). All data on it is lost.")))
        $ans = Read-Host ("  " + (C $cu (B "Type ERASE to wipe $Drive and build, or anything else to cancel")))
        if ($ans -cne 'ERASE') { Write-MiosLine 'info' 'Cancelled -- nothing touched.'; return $false }
        return $true
    }
    $ans = Read-Host ("  " + (C $cu (B 'Proceed? [Y/n]')))
    if ($ans -match '^(?i:n|no)$') { Write-MiosLine 'info' 'Cancelled.'; return $false }
    return $true
}

function Resolve-Target {
    param([string]$Target, [string]$Type, [string]$Stage, [bool]$Unattended, [string[]]$Passthrough)
    $ssot = if ($script:TomlPath) { $script:TomlPath } else { Join-Path $script:Root 'mios.toml' }
    $r = @{ Kind='ps'; Exe=$null; Args=@(); Env=@{}; NeedsAdmin=$false; Notes=@(); Platform='windows'; Drive='D:' }
    switch ($Target) {
        { $_ -in 'live','flash','cat' } {
            $r.Kind='bat'; $r.NeedsAdmin=$true
            $r.Exe=Join-Path $PSScriptRoot 'MiOS-Cat.bat'
            $r.Args=$Passthrough
            if ($Unattended) { $r.Env['NONINTERACTIVE']='1' }
            $d = Get-MiosSsotValue -Section 'cat' -Key 'drivepath'
            if ($d) { $r.Drive = "$($d):" }
        }
        { $_ -in 'monitor','dashboard','applet','tui' } {
            $r.Kind='py'
            $r.Exe=Resolve-MiosMonitorScript
            $r.Args=$Passthrough
            $r.NeedsAdmin=$false
        }
        'provision' {
            $r.Exe=(Join-Path $script:AutoDir 'Invoke-MiOSProvision.ps1'); $r.Args=@('-TomlPath', $ssot) + $Passthrough
        }
        'test-vm' {
            $r.Exe=(Join-Path $script:AutoDir 'Deploy-MiOSXbox.ps1'); $r.Args=$Passthrough
        }
        'xbox' {
            $r.Exe=(Join-Path $script:AutoDir 'Build-MiOSXboxISO.ps1'); $r.Args=@('-TomlPath', $ssot) + $Passthrough
        }
        'oci' {
            $r.Exe=$script:BuildPs; $r.NeedsAdmin=$true; $r.Args=@('-Unattended') + $Passthrough
        }
        'build' { $r.Exe=$script:BuildPs; $r.NeedsAdmin=$true; $r.Args=@('-Unattended') + $Passthrough }
        'configure' {
            $r.Kind='special'; $r.Special='configure'
        }
        'update' {
            $r.Kind='special'; $r.Special='update'
        }
        'repos' {
            $r.Kind='special'; $r.Special='repos'
        }
        default  { throw "unknown target '$Target'." }
    }
    return $r
}

# ============================================================================
#  Main Entrypoint Dispatcher
# ============================================================================
$catalog = Get-MiosCatalog

if (-not $Target -or $Target -in @('help','menu','--help','-h')) {
    $Target = Invoke-MiosGuidedMenu -Catalog $catalog
}

if (-not $catalog.Contains($Target)) {
    Write-MiosLine 'err' "Unknown target '$Target'. Available targets: $($catalog.Keys -join ', ')"
    exit 1
}

$entry = $catalog[$Target]
if ($entry.Contains('special')) {
    if ($entry['special'] -eq 'configure') {
        # SSOT-resolved configurator port ([ports].agent_pipe); '8640' is only the
        # last-resort fallback if the TOML can't be read. Get-MiosSsotValue is the
        # real resolver (mios-common.ps1:30) -- AGY's Get-MiosTomlValue does not exist.
        $port = Get-MiosSsotValue -Section 'ports' -Key 'agent_pipe' -Default '8640'
        Start-Process "http://localhost:${port}/configure"
        exit 0
    }
    if ($entry['special'] -eq 'repos') {
        Write-MiosLine 'info' 'Opening repository directories in Explorer...'
        $miosRepo = Join-Path (Split-Path $script:Root -Parent) 'MiOS'
        if (Test-Path $miosRepo) { Start-Process explorer.exe $miosRepo }
        Start-Process explorer.exe $script:Root
        exit 0
    }
    if ($entry['special'] -eq 'update') {
        Write-MiosLine 'info' 'Checking for and pulling updates for MiOS and mios-bootstrap...'
        try {
            if ([System.Net.Dns]::GetHostAddresses('github.com')) {
                $miosRepo = Join-Path (Split-Path $script:Root -Parent) 'MiOS'
                if (Test-Path $miosRepo) {
                    cd $miosRepo; git fetch; git pull
                }
                cd $script:Root; git fetch; git pull
                Write-MiosLine 'pass' 'Update check complete.'
                exit 0
            }
        } catch {
            Write-MiosLine 'err' 'OFFLINE: Internet unreachable - cannot pull updates right now.'
            exit 1
        }
    }
}

Show-MiosTargetBrief -Target $Target -Entry $entry -Type $Type -Stage $Stage
if (-not (Confirm-MiosProceed -Entry $entry -Unattended $Unattended -Drive 'D:')) { exit 0 }

# Consolidated installer surface: EVERY install/build target comes WITH the live monitor.
# Launch mios mon (the unified TUI) in its own window so the operator watches the whole
# pipeline live -- matches MiOS-Cat.bat's ensure_live_monitor. The 'monitor' target itself and
# the early-exit special targets (configure/repos/update) never reach here. Suppressed by
# MIOS_NO_MONITOR=1 (headless/CI/nested).
if ($env:MIOS_NO_MONITOR -ne '1') {
    $monScript = Resolve-MiosMonitorScript
    if ($monScript) {
        $monPy = if (Test-Path "$env:LOCALAPPDATA\Programs\Python\Python314\python.exe") { "$env:LOCALAPPDATA\Programs\Python\Python314\python.exe" } else { 'python' }
        try { Start-Process -FilePath $monPy -ArgumentList "`"$monScript`"" -WindowStyle Normal; Write-MiosLine 'info' 'live monitor launched (mios mon) -- watching the install pipeline' }
        catch { Write-MiosLine 'warn' "could not launch live monitor: $($_.Exception.Message)" }
    }
}

$plan = Resolve-Target -Target $Target -Type $Type -Stage $Stage -Unattended $Unattended -Passthrough $Passthrough
if ($plan.NeedsAdmin) { Invoke-MiosSelfElevate -ArgList $PSBoundParameters.Values }

if ($plan.Kind -eq 'ps') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $plan.Exe @($plan.Args)
    exit $LASTEXITCODE
}

if ($plan.Kind -eq 'py') {
    & python $plan.Exe @($plan.Args)
    exit $LASTEXITCODE
}

if ($Plan.Kind -eq 'bat') {
    Write-MiosLine 'info' "Launching MiOS-Cat.bat stage"
    & cmd.exe /c "`"$($plan.Exe)`"" @($plan.Args)
    exit $LASTEXITCODE
}
