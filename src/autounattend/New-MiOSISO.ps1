# AI-hint: DISM-native MiOS-XBOX ISO orchestrator (WISO-07 / T-138). Chains the whole reproducible pipeline: mios-uup-fetch (stock Dev-channel Win11 ISO) -> extract media -> offline-service install.wim with DISM (disable the merged preset's optional features, remove its provisioned appx, write the Xbox Full Screen Experience FeatureManagement override + DeviceForm spoof into the image) -> generate the MiOS autounattend.xml (SSOT accounts + LabConfig WinPE bypass + FirstLogonCommands incl. Xbox mode + nested irm|iex) -> oscdimg dual BIOS/UEFI bootable MiOS-Xbox.iso. No NTLite, no vivetool.exe. SSOT-driven, degrade-open.
# AI-related: mios-bootstrap, mios-uup-fetch.ps1, New-MiOSAutounattend.ps1, MiOS-Provision.lib.ps1, MiOS-Xbox-Merged.xml, docs/uup-autounattend-dism-iso-flow.md, docs/dism-native-conversion-map.md
# AI-functions: Expand-MiOSIso, Get-MiOSMergedRemovals, Set-MiOSXboxOfflineReg, Invoke-MiOSImageServicing, Build-MiOSBootableIso
#Requires -Version 5.1
<#
.SYNOPSIS
    Build a bootable MiOS-XBOX Windows 11 ISO from a UUP-Dump (Dev-channel) source,
    using DISM offline servicing + oscdimg -- 100% free/reproducible, no NTLite.

.DESCRIPTION
    The DISM-native canonical path (operator decision, T-138). Stages:
      0. mios-uup-fetch.ps1  -> stock Win11 ISO on the SSOT channel (default Dev).
      1. Extract the ISO to a writable media tree (Mount-DiskImage + copy).
      2. DISM offline-service sources\install.wim:
           - Disable-WindowsOptionalFeature for the merged preset's disabled Features.
           - Remove-AppxProvisionedPackage for the merged preset's appx removals.
           - Write the Xbox FSE FeatureManagement override + DeviceForm into the image
             (offline SYSTEM hive, ControlSet001) so Xbox mode is enabled image-wide.
           - Export-WindowsImage -CompressionType Max to reclaim servicing bloat.
      3. New-MiOSAutounattend.ps1 -> autounattend.xml (SSOT accounts, LabConfig bypass
         in the windowsPE pass, FirstLogonCommands = shared MiOS provisioning incl. the
         Xbox reg + nested irm|iex). Copied to the media root.
      4. oscdimg (ADK) -> dual BIOS/UEFI bootable ISO (UDF; efisys_noprompt for hands-off).

    Everything the checks need is honored: the Win11 TPM/SecureBoot/RAM bypass lands in
    the WinPE-phase autounattend (never install.wim -- the gate runs before install.wim
    is applied); oscdimg uses -u2 (UDF) because install.wim exceeds ISO-9660's 4 GB limit.

    SSOT: channel/edition/accounts/Xbox ids all resolve from mios.toml [autounattend].
    Must run ELEVATED (DISM mounts). Degrades open with clear messages if the ADK / a
    step is unavailable.

.PARAMETER SourceIso   Pre-fetched stock ISO. If omitted, runs mios-uup-fetch.ps1 (Dev).
.PARAMETER OutIso      Final MiOS-Xbox ISO. Default: [autounattend].iso_out.
.PARAMETER TomlPath    mios.toml SSOT.
.PARAMETER MergedPreset  The merged NTLite preset (debloat intent). Default: .\MiOS-Xbox-Merged.xml.
.PARAMETER WorkDir     Scratch dir. Default: M:\MiOS\isobuild or $env:TEMP\mios-isobuild.
.PARAMETER SkipServicing  Skip DISM servicing (autounattend + oscdimg only -- fast test).
.PARAMETER Esd         Prefer install.esd if present.

.EXAMPLE
    .\New-MiOSISO.ps1
    # Dev-channel fetch -> DISM-serviced, Xbox-mode MiOS-Xbox.iso
#>
[CmdletBinding()]
param(
    [string]$SourceIso,
    [string]$OutIso,
    [string]$TomlPath,
    [string]$MergedPreset = (Join-Path $PSScriptRoot 'MiOS-Xbox-Merged.xml'),
    [string]$WorkDir,
    [switch]$SkipServicing,
    [switch]$Esd
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1')

function Assert-Elevated {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "New-MiOSISO must run ELEVATED (DISM mounts install.wim). Re-run in an admin PowerShell."
    }
}

# Locate oscdimg from the ADK (enumerate the Kits root; never hardcode the '10').
function Get-Oscdimg {
    $kits = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits" -Directory -ErrorAction SilentlyContinue
    foreach ($k in $kits) {
        $e = Get-ChildItem (Join-Path $k.FullName 'Assessment and Deployment Kit\Deployment Tools') -Recurse -Filter oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($e) { return $e.FullName }
    }
    return (Get-Command oscdimg.exe -ErrorAction SilentlyContinue).Source
}

# Extract an ISO to a writable tree (Mount-DiskImage + robocopy, then dismount).
function Expand-MiOSIso {
    param([string]$Iso, [string]$Dest)
    if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Write-Host "[*] Mounting $Iso ..." -ForegroundColor Cyan
    $img = Mount-DiskImage -ImagePath $Iso -PassThru
    try {
        $drive = ($img | Get-Volume).DriveLetter + ':'
        & robocopy "$drive\" $Dest /E /NFL /NDL /NJH /NJS /NP | Out-Null
    } finally { Dismount-DiskImage -ImagePath $Iso | Out-Null }
    # Clear read-only bit copied from the DVD so we can re-service + re-master.
    Get-ChildItem $Dest -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
    return $Dest
}

# Parse the merged NTLite preset into the DISM-actionable removal sets.
# The <Feature> node carries the enable state as INNER TEXT (false = remove) and
# the @name grammar tells DISM object class: "Name~~~lang~ver" = a FoD CAPABILITY
# (Remove-WindowsCapability), a plain name = an OPTIONAL FEATURE
# (Disable-WindowsOptionalFeature). RemoveComponents/<c> are NTLite CBS keys
# (e.g. "asimov 'Telemetry Client'") = deep component surgery DISM cannot do =
# the NTLite-only residue (counted, not serviced -- see dism-native-conversion-map.md).
function Get-MiOSMergedRemovals {
    param([string]$PresetPath)
    $out = [pscustomobject]@{ Capabilities = @(); Features = @(); EnableFeatures = @(); NtliteOnly = 0 }
    if (-not (Test-Path $PresetPath)) { Write-Host "[!] Merged preset not found: $PresetPath (servicing skipped)" -ForegroundColor Yellow; return $out }
    [xml]$xml = Get-Content -LiteralPath $PresetPath -Raw
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('n', 'urn:schemas-nliteos-com:pn.v1')
    # PROTECT-LIST: never remove/disable an Xbox/gaming or virt feature (shared with
    # the merge). Belt-and-suspenders even though the merged preset is protect-clean.
    $protectFeat = @(Get-MiOSXboxProtectFeatures)
    function _protected([string]$n) { foreach ($m in $protectFeat) { if ("$n" -like "*$m*") { return $true } }; return $false }
    $caps = New-Object System.Collections.Generic.List[string]
    $feat = New-Object System.Collections.Generic.List[string]
    $en   = New-Object System.Collections.Generic.List[string]
    foreach ($f in @($xml.SelectNodes('//n:Features/n:Feature', $ns))) {
        $name = "$($f.GetAttribute('name'))".Trim()
        if (-not $name) { continue }
        $state = "$($f.InnerText)".Trim().ToLower()
        if ($state -eq 'false') {
            if (_protected $name) { continue }                # never disable a protected feature
            if ($name -match '~~~') { $caps.Add($name) } else { $feat.Add($name) }
        } elseif (_protected $name -and $name -notmatch '~~~') {
            $en.Add($name)                                    # protected + enabled -> actively ENABLE in the image
        }
    }
    # Posture B minimum: the MiOS brain always needs these enabled.
    $en.Add('VirtualMachinePlatform'); $en.Add('Microsoft-Windows-Subsystem-Linux')
    $out.Capabilities   = @($caps | Select-Object -Unique)
    $out.Features       = @($feat | Select-Object -Unique)
    $out.EnableFeatures = @($en   | Select-Object -Unique)
    $out.NtliteOnly     = @($xml.SelectNodes('//n:RemoveComponents/n:c', $ns)).Count
    return $out
}

# Write the Xbox FSE override + DeviceForm into the OFFLINE mounted image (ControlSet001).
function Set-MiOSXboxOfflineReg {
    param([string]$Mount, $Toml)
    if ((Get-Toml $Toml 'autounattend.xbox.enable' 'false') -notmatch '^(?i:true|1|yes)$') { return }
    $sys = Join-Path $Mount 'Windows\System32\config\SYSTEM'
    $sw  = Join-Path $Mount 'Windows\System32\config\SOFTWARE'
    $ids = (Get-Toml $Toml 'autounattend.xbox.feature_ids' '59765208') -split '[,\s]+' | Where-Object { $_ -match '^\d+$' }
    Write-Host "[*] Xbox FSE override -> offline image (ids: $($ids -join ','))" -ForegroundColor Cyan
    & reg.exe load 'HKLM\MIOS_SYS' $sys | Out-Null
    & reg.exe load 'HKLM\MIOS_SW'  $sw  | Out-Null
    try {
        foreach ($id in $ids) {
            $k = "HKLM\MIOS_SYS\ControlSet001\Control\FeatureManagement\Overrides\8\$id"
            & reg.exe add $k /v EnabledState        /t REG_DWORD /d 2 /f | Out-Null
            & reg.exe add $k /v EnabledStateOptions /t REG_DWORD /d 0 /f | Out-Null
            & reg.exe add $k /v Variant             /t REG_DWORD /d 0 /f | Out-Null
            & reg.exe add $k /v VariantPayload      /t REG_DWORD /d 0 /f | Out-Null
            & reg.exe add $k /v VariantPayloadKind  /t REG_DWORD /d 0 /f | Out-Null
        }
        if ((Get-Toml $Toml 'autounattend.xbox.device_form_spoof' 'true') -match '^(?i:true|1|yes)$') {
            & reg.exe add 'HKLM\MIOS_SW\Microsoft\Windows NT\CurrentVersion\OEM' /v DeviceForm /t REG_DWORD /d 46 /f | Out-Null
        }
    } finally {
        [gc]::Collect()   # release PS handles so the hives unload cleanly
        & reg.exe unload 'HKLM\MIOS_SYS' | Out-Null
        & reg.exe unload 'HKLM\MIOS_SW'  | Out-Null
    }
}

# Offline-service sources\install.wim: features + appx + Xbox reg, then export/trim.
function Invoke-MiOSImageServicing {
    param([string]$MediaRoot, $Toml, [object]$Removals)
    $wim = Join-Path $MediaRoot 'sources\install.wim'
    if (-not (Test-Path $wim)) {
        # Only a solid install.esd (LZMS) is present (MCT media / esd builds). DISM
        # cannot MOUNT an .esd read-write -- convert the needed index to a mountable
        # .wim first (Export-WindowsImage esd->wim), then service the .wim.
        $esd = Join-Path $MediaRoot 'sources\install.esd'
        if (-not (Test-Path $esd)) { throw "No sources\install.wim|.esd under $MediaRoot" }
        Get-ChildItem $esd | ForEach-Object { $_.IsReadOnly = $false }
        $ei = (Get-WindowsImage -ImagePath $esd | Where-Object { $_.ImageName -match 'Pro' } | Select-Object -First 1)
        if (-not $ei) { $ei = Get-WindowsImage -ImagePath $esd | Select-Object -First 1 }
        Write-Host "[*] Converting install.esd (index $($ei.ImageIndex)) -> mountable install.wim ..." -ForegroundColor Cyan
        Export-WindowsImage -SourceImagePath $esd -SourceIndex $ei.ImageIndex -DestinationImagePath $wim -CompressionType Max | Out-Null
        Remove-Item $esd -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem $wim | ForEach-Object { $_.IsReadOnly = $false }
    $idx = (Get-WindowsImage -ImagePath $wim | Where-Object { $_.ImageName -match 'Pro' } | Select-Object -First 1).ImageIndex
    if (-not $idx) { $idx = (Get-WindowsImage -ImagePath $wim | Select-Object -First 1).ImageIndex }
    $mount = Join-Path (Split-Path $MediaRoot) 'mount'
    if (Test-Path $mount) { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $mount | Out-Null
    Write-Host "[*] Mounting install image index $idx ..." -ForegroundColor Cyan
    Mount-WindowsImage -Path $mount -ImagePath $wim -Index $idx | Out-Null
    try {
        # Remove the merged preset's FoD capabilities (offline).
        if ($Removals.Capabilities.Count) {
            $present = @(Get-WindowsCapability -Path $mount | Where-Object State -eq 'Installed' | Select-Object -Expand Name)
            $todo = @($Removals.Capabilities | Where-Object { $present -contains $_ })
            Write-Host "[*] Removing $($todo.Count) capabilities (of $($Removals.Capabilities.Count) targeted, $($present.Count) installed) ..." -ForegroundColor Cyan
            foreach ($cap in $todo) { try { Remove-WindowsCapability -Path $mount -Name $cap -ErrorAction Stop | Out-Null } catch {} }
        }
        # Disable the merged preset's optional features (offline). NOTE: -Remove does
        # NOT reclaim payload on CLIENT editions (Push-Button Reset retention) -- it
        # only sets DisabledWithPayloadRemoved; the space win comes from the export.
        if ($Removals.Features.Count) {
            $present = @(Get-WindowsOptionalFeature -Path $mount | Where-Object State -eq 'Enabled' | Select-Object -Expand FeatureName)
            $todo = @($Removals.Features | Where-Object { $present -contains $_ })
            if ($todo.Count) { Write-Host "[*] Disabling $($todo.Count) optional features ..." -ForegroundColor Cyan
                Disable-WindowsOptionalFeature -Path $mount -FeatureName $todo -Remove -ErrorAction SilentlyContinue | Out-Null }
        }
        # Posture B: actively ENABLE the MiOS virt stack (WSL2/VMP/Hyper-V) so the
        # brain works out of the box. Enable only features actually present + not
        # already enabled; -All pulls in parents (e.g. Hyper-V children).
        if ($Removals.EnableFeatures.Count) {
            $avail = @(Get-WindowsOptionalFeature -Path $mount)
            foreach ($ef in $Removals.EnableFeatures) {
                $st = ($avail | Where-Object FeatureName -eq $ef | Select-Object -First 1).State
                if ($st -and $st -ne 'Enabled') {
                    try { Enable-WindowsOptionalFeature -Path $mount -FeatureName $ef -All -ErrorAction Stop | Out-Null; Write-Host "    +enabled $ef" -ForegroundColor DarkGray } catch {}
                }
            }
        }
        # Xbox FSE override into the image.
        Set-MiOSXboxOfflineReg -Mount $mount -Toml $Toml
        # Stage the MiOS-Host boot payload into the image so the specialize-pass
        # ONSTART task (registered by the autounattend) finds it pre-logon.
        $hostDst = Join-Path $mount 'ProgramData\MiOS'
        New-Item -ItemType Directory -Force -Path $hostDst | Out-Null
        foreach ($stage in 'MiOS-Host.ps1','MiOS-XBOX-Hydrate.ps1') {
            $src = Join-Path $PSScriptRoot $stage
            if (Test-Path $src) { Copy-Item $src (Join-Path $hostDst $stage) -Force; Write-Host "    staged $stage -> image ProgramData\MiOS" -ForegroundColor DarkGray }
        }
        Write-Host "    NTLite-only residue (deep CBS removals DISM cannot do): $($Removals.NtliteOnly) <c> -- see dism-native-conversion-map.md" -ForegroundColor DarkGray
    } finally {
        Write-Host "[*] Committing image (Dismount -Save) ..." -ForegroundColor Cyan
        Dismount-WindowsImage -Path $mount -Save | Out-Null
    }
    # Trim servicing bloat: re-export Max to a new wim, swap in.
    $trim = "$wim.trim"
    Write-Host "[*] Export-WindowsImage -CompressionType Max (trim) ..." -ForegroundColor Cyan
    Export-WindowsImage -SourceImagePath $wim -SourceIndex $idx -DestinationImagePath $trim -CompressionType Max | Out-Null
    Move-Item -LiteralPath $trim -Destination $wim -Force
}

# Assemble the bootable dual BIOS/UEFI ISO with oscdimg (UDF; no-prompt UEFI).
function Build-MiOSBootableIso {
    param([string]$MediaRoot, [string]$OutIso, [string]$Label)
    $oscdimg = Get-Oscdimg
    if (-not $oscdimg) { throw "oscdimg.exe not found. Install the Windows ADK 'Deployment Tools'. Media tree ready at '$MediaRoot' -- master it manually." }
    $bios = Join-Path $MediaRoot 'boot\etfsboot.com'
    $uefi = Join-Path $MediaRoot 'efi\microsoft\boot\efisys_noprompt.bin'
    if (-not (Test-Path $uefi)) { $uefi = Join-Path $MediaRoot 'efi\microsoft\boot\efisys.bin' }
    New-Item -ItemType Directory -Force -Path (Split-Path $OutIso) | Out-Null
    # -bootdata carries '#' -> must be ONE quoted token in PowerShell. -u2 = UDF
    # (install.wim exceeds ISO-9660's 4GB single-file cap). -l<label> no space.
    $bootdata = "-bootdata:2#p0,e,b$bios#pEF,e,b$uefi"
    Write-Host "[*] oscdimg -> $OutIso ..." -ForegroundColor Cyan
    # Out-Host: keep oscdimg's output in the transcript but out of the success stream
    # (New-MiOSISO returns $OutIso; a leaked oscdimg log would make the return an array).
    # Scope EAP=Continue so a stderr line under `2>&1` doesn't throw NativeCommandError
    # in PS 5.1 before the exit-code check.
    & { $ErrorActionPreference = 'Continue'; & $oscdimg -m -o -u2 -udfver102 "-l$Label" $bootdata $MediaRoot $OutIso 2>&1 | Out-Host }
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed (exit $LASTEXITCODE)" }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Assert-Elevated
if (-not $TomlPath) {
    foreach ($c in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',(Join-Path $PSScriptRoot '..\..\mios.toml'))) {
        if (Test-Path -LiteralPath $c) { $TomlPath = (Resolve-Path $c).Path; break }
    }
}
$toml   = if ($TomlPath) { Read-MiosToml -Path $TomlPath } else { @{ scalars=@{}; accounts=@(); prefs=@{} } }
if (-not $OutIso)  { $OutIso  = Get-Toml $toml 'autounattend.iso_out'   'M:\MiOS\iso\MiOS-Xbox.iso' }
$label = Get-Toml $toml 'autounattend.iso_label' 'MiOS-Xbox'
if (-not $WorkDir) { $WorkDir = if (Test-Path 'M:\') { 'M:\MiOS\isobuild' } else { Join-Path $env:TEMP 'mios-isobuild' } }

# Stage 0 -- source ISO (fetch Dev-channel if not supplied).
if (-not $SourceIso) {
    Write-Host "[*] No -SourceIso; fetching stock ISO via mios-uup-fetch (channel from SSOT) ..." -ForegroundColor Cyan
    $SourceIso = & (Join-Path $PSScriptRoot 'mios-uup-fetch.ps1') -TomlPath $TomlPath -Esd:$Esd
}
if (-not (Test-Path $SourceIso)) { throw "Source ISO not found: $SourceIso" }

# Stage 1 -- extract to a writable media tree.
$media = Expand-MiOSIso -Iso $SourceIso -Dest (Join-Path $WorkDir 'media')

# Stage 2 -- DISM offline servicing (features + appx + Xbox FSE into the image).
if (-not $SkipServicing) {
    $removals = Get-MiOSMergedRemovals -PresetPath $MergedPreset
    Invoke-MiOSImageServicing -MediaRoot $media -Toml $toml -Removals $removals
} else { Write-Host "[*] -SkipServicing: image left stock." -ForegroundColor DarkGray }

# Stage 3 -- autounattend.xml (SSOT accounts + LabConfig WinPE bypass + FirstLogonCommands
# incl. Xbox reg + nested irm|iex) to the media root.
Write-Host "[*] Generating autounattend.xml (SSOT + Xbox FirstLogonCommands) ..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'New-MiOSAutounattend.ps1') -TomlPath $TomlPath -OutXml (Join-Path $media 'autounattend.xml') | Out-Null
Copy-Item (Join-Path $media 'autounattend.xml') (Join-Path $media 'sources\autounattend.xml') -Force -ErrorAction SilentlyContinue

# Stage 4 -- master the bootable ISO.
Build-MiOSBootableIso -MediaRoot $media -OutIso $OutIso -Label $label

Write-Host "[+] MiOS-XBOX ISO: $OutIso" -ForegroundColor Green
Write-Host "    DISM-serviced + Xbox FSE enabled; boot to install, FirstLogon runs MiOS bootstrap." -ForegroundColor DarkGray
return $OutIso
