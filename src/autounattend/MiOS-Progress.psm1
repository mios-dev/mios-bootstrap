# AI-hint: MiOS Stage-1 PROGRESS CONTRACT. The single-writer, atomic, MONOTONIC
# progress bus every provisioning surface reports into so ONE full-screen bar can
# render the whole first-boot. Exports Write-MiOSProgress -Step <id> -Pct <n>
# -State pending|running|done|error: it read-modify-writes C:\ProgramData\MiOS\
# provision-state.json (temp+rename atomic) and mirrors the aggregate to
# HKLM\SOFTWARE\MiOS\Provision (TotalPct/Phase/State/Complete). Phase weights come
# from mios.toml [autounattend.provision.weights] (operator-tunable) with sane
# defaults. The POSIX twin write-mios-progress.sh writes the SAME json from inside
# the WSL distro over /mnt/c/ProgramData/MiOS so in-distro steps report into the
# one bar. SINGLE WRITER: only MiOS-Provision.ps1 (Windows) and the sh twin it
# invokes (in-distro, serialized by the driver) ever write; the bar only reads.
# AI-related: mios-bootstrap, MiOS-Provision.ps1, MiOS-SetupExperience.ps1, write-mios-progress.sh, New-MiOSISO.ps1, mios.toml [autounattend.provision]
# AI-functions: Get-MiOSProgressPhases, Write-MiOSProgress, Get-MiOSProgressState, Initialize-MiOSProgress
#Requires -Version 5.1
Set-StrictMode -Off

# --- Canonical phase order + labels (SSOT for the whole bar). Order IS the bar. ---
$script:MiOSPhaseOrder = @(
    'wsl-feature'
    'seed-stage'
    'wsl-import'
    'm-volume'
    'podman-machine'
    'image-load'
    'distro-boot'
    'firstboot'
)
$script:MiOSPhaseLabels = @{
    'wsl-feature'    = 'Enabling Windows virtualization'
    'seed-stage'     = 'Staging the MiOS seed image'
    'wsl-import'     = 'Importing the MiOS system'
    'm-volume'       = 'Preparing the MiOS data volume'
    'podman-machine' = 'Starting the container engine'
    'image-load'     = 'Loading MiOS containers'
    'distro-boot'    = 'Starting the MiOS brain'
    'firstboot'      = 'Finalizing your MiOS'
}
# Default weights (operator-tunable via mios.toml). Need NOT sum to 100 -- the total
# is normalized by the weight sum, so a tuned table stays a valid 0..100 bar.
$script:MiOSDefaultWeights = [ordered]@{
    'wsl-feature'    = 8
    'seed-stage'     = 5
    'wsl-import'     = 30
    'm-volume'       = 5
    'podman-machine' = 10
    'image-load'     = 22
    'distro-boot'    = 15
    'firstboot'      = 5
}

$script:MiOSStateDefault = 'C:\ProgramData\MiOS\provision-state.json'
$script:MiOSRegKey       = 'HKLM:\SOFTWARE\MiOS\Provision'

# Locate mios.toml (embedded repo copy first -- offline; then M: overlays). Returns
# $null when none is present (defaults are then authoritative -- degrade-open).
function script:Find-MiOSToml {
    foreach ($c in @(
        'C:\ProgramData\MiOS\repo\mios-bootstrap\mios.toml'
        'M:\etc\mios\mios.toml'
        'M:\usr\share\mios\mios.toml'
        (Join-Path $PSScriptRoot '..\..\mios.toml')
    )) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

# Minimal, self-contained reader for the [autounattend.provision.weights] sub-table
# ONLY (this module must not depend on MiOS-Provision.lib.ps1 -- the bar imports it
# as the unprivileged desktop user). Falls back to the default weight for any key the
# operator did not override, so the bar is always well-formed.
function script:Read-MiOSWeights {
    $w = [ordered]@{}
    foreach ($k in $script:MiOSDefaultWeights.Keys) { $w[$k] = [double]$script:MiOSDefaultWeights[$k] }
    $toml = script:Find-MiOSToml
    if (-not $toml) { return $w }
    try {
        $section = ''
        foreach ($raw in [IO.File]::ReadAllLines($toml)) {
            $line = $raw.Trim()
            if (-not $line -or $line.StartsWith('#')) { continue }
            $line = ($line -replace '\s+#.*$', '').Trim()
            if (-not $line) { continue }
            if ($line -match '^\[(?<s>[^\]]+)\]$') { $section = $Matches['s']; continue }
            if ($section -eq 'autounattend.provision.weights' -and
                $line -match '^(?<k>[A-Za-z0-9_\-\.]+)\s*=\s*(?<v>.+)$') {
                $key = $Matches['k'].Trim()
                $val = $Matches['v'].Trim().Trim('"', "'")
                if ($w.Contains($key)) { [double]$parsed = 0; if ([double]::TryParse($val, [ref]$parsed)) { $w[$key] = $parsed } }
            }
        }
    } catch {}
    return $w
}

# Public: the ordered phase descriptor list (id/label/weight), all defaults applied.
function Get-MiOSProgressPhases {
    $w = script:Read-MiOSWeights
    $out = @()
    foreach ($id in $script:MiOSPhaseOrder) {
        $out += [pscustomobject]@{
            id     = $id
            label  = $script:MiOSPhaseLabels[$id]
            weight = [double]$w[$id]
        }
    }
    return $out
}

function script:New-MiOSStateObject {
    $phases = @()
    foreach ($p in (Get-MiOSProgressPhases)) {
        $phases += [ordered]@{ id = $p.id; label = $p.label; weight = $p.weight; state = 'pending'; pct = 0 }
    }
    return [ordered]@{
        schema        = 1
        phase_index   = 0
        total_pct     = 0
        reboot_pending = $false
        updated       = ([DateTime]::UtcNow.ToString('o'))
        phases        = $phases
    }
}

# Read the state json, tolerating a transient partial/locked read (the writer renames
# atomically, so a well-formed file is either the old or the new one -- never torn).
function Get-MiOSProgressState {
    param([string]$StateFile = $script:MiOSStateDefault)
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $raw = [IO.File]::ReadAllText($StateFile)
            if ($raw -and $raw.Trim()) { return ($raw | ConvertFrom-Json) }
        } catch { Start-Sleep -Milliseconds 120 }
    }
    return $null
}

function script:Write-MiOSRegistryMirror {
    param([int]$TotalPct, [string]$Phase, [string]$State, [int]$Complete)
    try {
        if (-not (Test-Path -LiteralPath $script:MiOSRegKey)) { New-Item -Path $script:MiOSRegKey -Force | Out-Null }
        New-ItemProperty -Path $script:MiOSRegKey -Name 'TotalPct'  -Value $TotalPct  -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -Path $script:MiOSRegKey -Name 'Phase'     -Value $Phase     -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $script:MiOSRegKey -Name 'State'     -Value $State     -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $script:MiOSRegKey -Name 'Complete'  -Value $Complete  -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -Path $script:MiOSRegKey -Name 'Updated'   -Value ([DateTime]::UtcNow.ToString('o')) -PropertyType String -Force | Out-Null
    } catch {}   # registry mirror is best-effort (the json is the source of truth)
}

# Recompute the MONOTONIC weighted aggregate + phase_index from the phase array.
function script:Update-MiOSAggregate {
    param($State)
    $sumW = 0.0; $acc = 0.0; $idx = 0; $seenActive = $false; $allDone = $true
    for ($i = 0; $i -lt $State.phases.Count; $i++) {
        $ph  = $State.phases[$i]
        $wt  = [double]$ph.weight
        $sumW += $wt
        $eff = 0.0
        switch ("$($ph.state)") {
            'done'    { $eff = 100.0 }
            'running' { $eff = [double]$ph.pct }
            'error'   { $eff = [double]$ph.pct }   # freeze at last reported pct
            default   { $eff = 0.0 }               # pending
        }
        $acc += $wt * ($eff / 100.0)
        if ("$($ph.state)" -ne 'done') { $allDone = $false }
        if (-not $seenActive -and "$($ph.state)" -ne 'done') { $idx = $i; $seenActive = $true }
    }
    if (-not $seenActive) { $idx = [Math]::Max(0, $State.phases.Count - 1) }
    $total = if ($sumW -gt 0) { [int][Math]::Round(100.0 * $acc / $sumW) } else { 0 }
    # MONOTONIC: never let the bar go backwards, even if a phase re-reports lower.
    $prev = [int]$State.total_pct
    if ($total -lt $prev) { $total = $prev }
    if ($allDone) { $total = 100 }
    $State.phase_index = $idx
    $State.total_pct   = $total
    return $allDone
}

<#
.SYNOPSIS
    Report one phase's progress into the single MiOS provisioning bar (atomic + monotonic).
.PARAMETER Step   Phase id (one of the canonical phases; see Get-MiOSProgressPhases).
.PARAMETER Pct    0..100 progress WITHIN the phase (ignored/forced to 100 for done, 0 for pending).
.PARAMETER State  pending | running | done | error.
.PARAMETER RebootPending  Optional: set/clear the reboot_pending flag (left unchanged when omitted).
.PARAMETER Note   Optional free-form note persisted on the phase (diagnostics).
.PARAMETER StateFile  Override the state json path (default C:\ProgramData\MiOS\provision-state.json).
#>
function Write-MiOSProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Step,
        [int]$Pct = 0,
        [Parameter(Mandatory)][ValidateSet('pending','running','done','error')][string]$State,
        [object]$RebootPending = $null,
        [string]$Note,
        [string]$StateFile = $script:MiOSStateDefault
    )
    if ($script:MiOSPhaseOrder -notcontains $Step) {
        Write-Warning "Write-MiOSProgress: unknown phase '$Step' (ignored)."
        return
    }
    $dir = Split-Path -Parent $StateFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    # Load-or-init, then reconcile the phase set against the canonical order so a
    # weight change (operator retuned mios.toml) or a stale file is self-healing.
    $existing = Get-MiOSProgressState -StateFile $StateFile
    $st = script:New-MiOSStateObject
    if ($existing -and $existing.phases) {
        foreach ($ph in $st.phases) {
            $old = $existing.phases | Where-Object { "$($_.id)" -eq "$($ph.id)" } | Select-Object -First 1
            if ($old) { $ph.state = "$($old.state)"; $ph.pct = [int]$old.pct }
        }
        if ($existing.total_pct)   { $st.total_pct = [int]$existing.total_pct }
        if ($null -ne $existing.reboot_pending) { $st.reboot_pending = [bool]$existing.reboot_pending }
    }

    # Clamp + normalize the reported pct per the terminal state.
    $p = [int]$Pct; if ($p -lt 0) { $p = 0 }; if ($p -gt 100) { $p = 100 }
    switch ($State) { 'done' { $p = 100 } 'pending' { if ($Pct -le 0) { $p = 0 } } }

    foreach ($ph in $st.phases) {
        if ("$($ph.id)" -eq $Step) {
            $ph.state = $State
            $ph.pct   = $p
            if ($PSBoundParameters.ContainsKey('Note')) { $ph['note'] = "$Note" }
        }
    }
    if ($null -ne $RebootPending) { $st.reboot_pending = [bool]$RebootPending }
    $st.updated = ([DateTime]::UtcNow.ToString('o'))

    $allDone = script:Update-MiOSAggregate -State $st

    # --- ATOMIC WRITE: serialize to a temp sibling, then rename over the target. ---
    $json = ($st | ConvertTo-Json -Depth 6)
    $tmp  = "$StateFile.$PID.tmp"
    $enc  = New-Object System.Text.UTF8Encoding($false)
    for ($try = 0; $try -lt 4; $try++) {
        try {
            [IO.File]::WriteAllText($tmp, $json, $enc)
            Move-Item -LiteralPath $tmp -Destination $StateFile -Force
            break
        } catch {
            Start-Sleep -Milliseconds 150
            if ($try -eq 3) { try { [IO.File]::WriteAllText($StateFile, $json, $enc) } catch {} }
        }
    }

    # --- mirror the aggregate to HKLM (DWORD/SZ) for any non-file consumer. ---
    $curLabel = ($st.phases[$st.phase_index]).label
    $curState = ($st.phases[$st.phase_index]).state
    script:Write-MiOSRegistryMirror -TotalPct ([int]$st.total_pct) -Phase "$curLabel" -State "$curState" -Complete ([int]([bool]$allDone))

    return $st
}

# Idempotently reset the bar to an all-pending baseline (call once at driver start-of-run
# ONLY if no state exists -- never wipe an in-progress bar across a reboot).
function Initialize-MiOSProgress {
    param([string]$StateFile = $script:MiOSStateDefault, [switch]$Force)
    if ((Test-Path -LiteralPath $StateFile) -and -not $Force) { return (Get-MiOSProgressState -StateFile $StateFile) }
    $dir = Split-Path -Parent $StateFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $st = script:New-MiOSStateObject
    [void](script:Update-MiOSAggregate -State $st)
    $enc = New-Object System.Text.UTF8Encoding($false)
    try { [IO.File]::WriteAllText($StateFile, ($st | ConvertTo-Json -Depth 6), $enc) } catch {}
    script:Write-MiOSRegistryMirror -TotalPct 0 -Phase ($st.phases[0].label) -State 'pending' -Complete 0
    return $st
}

Export-ModuleMember -Function Write-MiOSProgress, Get-MiOSProgressState, Get-MiOSProgressPhases, Initialize-MiOSProgress
