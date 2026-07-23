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
.PARAMETER WorkDir     Scratch dir. Default: <work_root>\MiOS\isobuild, where work_root is autounattend.work_root or the most-free fixed drive.
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
    [string]$MergedPreset = '',
    [string]$WorkDir,
    [switch]$SkipServicing,
    [switch]$Esd,
    [string]$Edition
)
$ErrorActionPreference = 'Stop'
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $MergedPreset) { $MergedPreset = Join-Path $PSScriptRoot 'MiOS-Xbox-Merged.xml' }
. (Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1')

function Invoke-MiOSLiveMonitorAuto {
    try {
        $monScript = 'C:\mios-bootstrap\installation\MiOS-Monitor.ps1'
        if (-not (Test-Path $monScript)) { $monScript = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'installation\MiOS-Monitor.ps1' }
        if (Test-Path $monScript) {
            $existing = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*MiOS-Monitor*' }
            if (-not $existing) {
                Write-Host "[MONITOR] Spawning live interactive desktop monitor window..." -ForegroundColor Cyan
                schtasks /create /tn ShowMonitorUI /tr "powershell.exe -NoExit -ExecutionPolicy Bypass -File `"$monScript`"" /sc ONCE /st 00:00 /it /f *>$null
                schtasks /run /tn ShowMonitorUI *>$null
                Start-Process powershell -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$monScript`"" -WindowStyle Normal -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}
Invoke-MiOSLiveMonitorAuto

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
    Write-Host "[*] Extracting $Iso ..." -ForegroundColor Cyan
    $7z = Get-Command 7z.exe -ErrorAction SilentlyContinue
    $7zExe = if ($7z) { $7z.Source } elseif (Test-Path 'C:\Program Files\7-Zip\7z.exe') { 'C:\Program Files\7-Zip\7z.exe' } else { $null }
    if ($7zExe) {
        & $7zExe x "$Iso" "-o$Dest" -y | Out-Null
    } else {
        $img = Mount-DiskImage -ImagePath $Iso -PassThru
        try {
            $drive = ($img | Get-Volume).DriveLetter + ':'
            & robocopy "$drive\" $Dest /E /NFL /NDL /NJH /NJS /NP | Out-Null
        } finally { Dismount-DiskImage -ImagePath $Iso | Out-Null }
    }
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
    param([string]$PresetPath, $Toml)
    $out = [pscustomobject]@{ Capabilities = @(); Features = @(); EnableFeatures = @(); Appx = @(); NtliteOnly = 0 }
    if (-not (Test-Path $PresetPath)) { Write-Host "[!] Merged preset not found: $PresetPath (servicing skipped)" -ForegroundColor Yellow; return $out }
    [xml]$xml = Get-Content -LiteralPath $PresetPath -Raw
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('n', 'urn:schemas-nliteos-com:pn.v1')
    # PROTECT-LIST: never remove/disable an Xbox/gaming or virt feature (shared with
    # the merge). Belt-and-suspenders even though the merged preset is protect-clean.
    $protectFeat = @(Get-MiOSXboxProtectFeatures)
    function _protected([string]$n) { foreach ($m in $protectFeat) { if ("$n" -like "*$m*") { return $true } }; return $false }
    # KEEP-SET: never strip an app the converter's CustomList integrated ON PURPOSE
    # (SSOT autounattend.uup_convert.keep_apps -- Xbox stack / Store / media codecs /
    # Snipping / Terminal). The NTLite preset's removal <c> set overlaps the keep-set
    # (e.g. HEVC/AV1/VP9 codecs), and without this the Stage-2 strip wins -> the gaming/
    # streaming codecs the operator kept get removed. Excluding here protects BOTH the
    # offline Remove-AppxProvisionedPackage AND the SetupComplete fallback strip, since
    # mios-remove-appx.txt + the $rmset both derive from $out.Appx.
    $keepApps = @{}
    foreach ($k in (@((Get-Toml $Toml 'autounattend.uup_convert.keep_apps' '') -split '[,\s]+') | Where-Object { $_ })) { $keepApps["$k".ToLower()] = $true }
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
    # The <c> RemoveComponents are NTLite CBS keys. The appx-package-style ones
    # (e.g. microsoft.microsoftsolitairecollection, msteams, clipchamp.clipchamp)
    # ARE removable OFFLINE via Remove-AppxProvisionedPackage (matched by
    # DisplayName in the servicing step); the deep-OS CBS-only ones (asimov, ceip,
    # ndu, ...) are the true NtliteOnly residue DISM can't touch. We pass every <c>
    # first-token as an appx candidate and exact-match it against the image's
    # provisioned packages, so non-appx tokens are safe no-ops -- no heuristic gate.
    $capp = New-Object System.Collections.Generic.List[string]
    $ccnt = 0
    foreach ($c in @($xml.SelectNodes('//n:RemoveComponents/n:c', $ns))) {
        $ccnt++
        $tok = ("$($c.InnerText)".Trim() -split '\s+')[0]
        if ($tok -and -not (_protected $tok) -and -not $keepApps.ContainsKey("$tok".ToLower())) { $capp.Add($tok) }
    }
    $out.Capabilities   = @($caps | Select-Object -Unique)
    $out.Features       = @($feat | Select-Object -Unique)
    $out.EnableFeatures = @($en   | Select-Object -Unique)
    $out.Appx           = @($capp | Select-Object -Unique)
    $out.NtliteOnly     = $ccnt
    return $out
}

# Write the Xbox FSE override + DeviceForm into the OFFLINE mounted image (ControlSet001).
function Set-MiOSXboxOfflineReg {
    param([string]$Mount, $Toml)
    if ((Get-Toml $Toml 'autounattend.xbox.enable' 'false') -notmatch '^(?i:true|1|yes)$') { return }
    $sys = Join-Path $Mount 'Windows\System32\config\SYSTEM'
    $sw  = Join-Path $Mount 'Windows\System32\config\SOFTWARE'
    $ids = @((Get-Toml $Toml 'autounattend.xbox.feature_ids' '58989070,59765208') -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })
    # Union the full god-mode set from the reviewable data file so the image boots with
    # ALL Xbox/gaming/2026-UI features on, not just the FSE flag. Non-existent ids on a
    # given build are harmless no-ops (an unused override key).
    $featFile = Join-Path $PSScriptRoot 'mios-xbox-features.txt'
    if (Test-Path $featFile) {
        $ids += @(Get-Content -LiteralPath $featFile | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ -match '^\d+$' })
    }
    $ids = @($ids | Select-Object -Unique)
    Write-Host "[*] Xbox/gaming feature overrides -> offline image ($($ids.Count) ids, EnabledState=2)" -ForegroundColor Cyan
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

# Neutralize the debloat DISM can't component-remove. The ~200 deep NTLite CBS
# component keys (asimov/ceip/ndu/...) have NO DISM API (dism-native-conversion-map.md)
# -- their FILES stay, but their telemetry / AI / Copilot / consumer-feature /
# OneDrive BEHAVIOUR is killed here via offline registry + service policy from the
# tracked mios-debloat.json. Applied to the mounted image's SOFTWARE + SYSTEM
# (services) + Default-user NTUSER.DAT. Every op is idempotent + defensive (non-fatal).
function Set-MiOSDebloatOffline {
    param([string]$Mount, $Toml, [string]$PolicyPath)
    if ((Get-Toml $Toml 'autounattend.debloat' 'true') -notmatch '^(?i:true|1|yes)$') {
        Write-Host "[*] Offline debloat disabled (SSOT autounattend.debloat=false)." -ForegroundColor DarkGray; return
    }
    if (-not (Test-Path $PolicyPath)) { Write-Host "[!] Debloat policy not found: $PolicyPath (skipped)." -ForegroundColor Yellow; return }
    $pol = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json
    # SOFTWARE + SYSTEM unload cleanly with a plain [gc]::Collect() (no user-hive .LOG
    # transaction to flush). The per-user default_user array is handled SEPARATELY below
    # against Users\Default\NTUSER.DAT with the proven handle-release procedure -- see the
    # default_user block after the finally.
    $hives = @(
        @{ h = 'MIOS_SW';  f = (Join-Path $Mount 'Windows\System32\config\SOFTWARE') }
        @{ h = 'MIOS_SYS'; f = (Join-Path $Mount 'Windows\System32\config\SYSTEM') }
    )
    $ok = @{}
    foreach ($x in $hives) { if (Test-Path $x.f) { & reg.exe load "HKLM\$($x.h)" $x.f 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $ok[$x.h] = $true } } }
    $applied = 0
    try {
        $plan = @()
        if ($ok['MIOS_SW'])  { foreach ($e in @($pol.software))     { $plan += @{ h = 'MIOS_SW';  e = $e } } }
        if ($ok['MIOS_SYS']) { foreach ($e in @($pol.system))       { $plan += @{ h = 'MIOS_SYS'; e = $e } } }
        # (default_user is applied in its own pass after this finally -- see below.)
        foreach ($p in $plan) {
            $full = "HKLM\$($p.h)\$($p.e.key)"
            try {
                if ($p.e.delete) { & reg.exe delete $full /v $p.e.name /f 2>&1 | Out-Null }
                else { & reg.exe add $full /v $p.e.name /t $p.e.type /d "$($p.e.data)" /f 2>&1 | Out-Null }
                $applied++
            } catch {}
        }
        if ($ok['MIOS_SYS']) {
            foreach ($s in @($pol.system_services)) {
                try { & reg.exe add "HKLM\MIOS_SYS\ControlSet001\Services\$($s.name)" /v Start /t REG_DWORD /d $s.start /f 2>&1 | Out-Null; $applied++ } catch {}
            }
        }
    } finally {
        [gc]::Collect()
        foreach ($h in $ok.Keys) { & reg.exe unload "HKLM\$h" 2>&1 | Out-Null }
    }
    # default_user: apply the per-user Content Delivery Manager / advertising-id / Bing-search
    # debloat to the mounted Default NTUSER.DAT so EVERY account created at OOBE inherits a
    # clean Start (this is what the JSON's default_user array was for -- it was previously
    # dead). This is the SAME offline Default-hive edit Set-MiOSIdentityOffline performs a few
    # steps later in this very servicing pass, and it is SAFE with the proven handle-release
    # procedure (reg.exe + [gc]::Collect + [gc]::WaitForPendingFinalizers + Start-Sleep before
    # unload, with a retry). The old "offline user-hive editing corrupts the profile" warning
    # was PROCEDURAL (missing the flush/sleep), not inherent. Loaded/unloaded here in its own
    # pass under a DISTINCT key (MIOS_DEFU) and sequentially before the identity-bake's own
    # Default-hive load, so the two never overlap. Every op is idempotent + per-op non-fatal.
    $du = @($pol.default_user)
    $defHive = Join-Path $Mount 'Users\Default\NTUSER.DAT'
    if ($du.Count -and (Test-Path $defHive)) {
        & reg.exe load 'HKLM\MIOS_DEFU' $defHive 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            try {
                foreach ($e in $du) {
                    $full = "HKLM\MIOS_DEFU\$($e.key)"
                    try {
                        if ($e.delete) { & reg.exe delete $full /v $e.name /f 2>&1 | Out-Null }
                        else { & reg.exe add $full /v $e.name /t $e.type /d "$($e.data)" /f 2>&1 | Out-Null }
                        $applied++
                    } catch {}
                }
            } finally {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Seconds 3
                & reg.exe unload 'HKLM\MIOS_DEFU' 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { [gc]::Collect(); Start-Sleep -Seconds 3; & reg.exe unload 'HKLM\MIOS_DEFU' 2>&1 | Out-Null }
            }
            Write-Host "    default_user debloat -> Default NTUSER.DAT ($($du.Count) CDM/ad-id/Bing-search ops; inherited by every OOBE account)" -ForegroundColor DarkGray
        } else { Write-Host "    [!] could not load Default NTUSER.DAT (default_user debloat skipped -- non-fatal)" -ForegroundColor Yellow }
    }
    Write-Host "[*] Offline debloat applied ($applied policy ops): telemetry/AI/Copilot/consumer-features/OneDrive off + DiagTrack/dmwappushservice disabled + per-user CDM/ad-id/search cleaned in Default hive." -ForegroundColor Cyan
}

function Set-MiOSCustomDefaults {
    param([string]$Mount)
    Write-Host "[*] Baking custom unattend settings as offline defaults ..." -ForegroundColor Cyan

    $scriptsDst = Join-Path $Mount 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Force -Path $scriptsDst | Out-Null

    $taskbarXml = @'
<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1"> <CustomTaskbarLayoutCollection PinListPlacement="Replace"> <defaultlayout:TaskbarLayout> <taskbar:TaskbarPinList> <taskbar:DesktopApp DesktopApplicationLinkPath="#leaveempty" /> </taskbar:TaskbarPinList> </defaultlayout:TaskbarLayout> </CustomTaskbarLayoutCollection> </LayoutModificationTemplate>
'@
    Set-Content -Path (Join-Path $scriptsDst 'TaskbarLayoutModification.xml') -Value $taskbarXml -Encoding Utf8

    $unlockVbs = @'
Const HKU = &H80000003
Set reg = GetObject("winmgmts://./root/default:StdRegProv")
Set fso = CreateObject("Scripting.FileSystemObject")
If reg.EnumKey(HKU, "", sids) = 0 Then
  If Not IsNull(sids) Then
    For Each sid In sids
      key = sid + "\Software\Policies\Microsoft\Windows\Explorer"
      name = "LockedStartLayout"
      If reg.GetDWORDValue(HKU, key, name, existing) = 0 Then
        reg.SetDWORDValue HKU, key, name, 0
      End If
    Next
  End If
End If
'@
    Set-Content -Path (Join-Path $scriptsDst 'UnlockStartLayout.vbs') -Value $unlockVbs -Encoding Utf8

    $unlockXml = @'
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"> <Triggers> <EventTrigger> <Enabled>true</Enabled> <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Application"&gt;&lt;Select Path="Application"&gt;*[System[Provider[@Name='UnattendGenerator'] and EventID=1]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription> </EventTrigger> </Triggers> <Principals> <Principal id="Author"> <UserId>S-1-5-18</UserId> <RunLevel>LeastPrivilege</RunLevel> </Principal> </Principals> <Settings> <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy> <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries> <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries> <AllowHardTerminate>true</AllowHardTerminate> <StartWhenAvailable>false</StartWhenAvailable> <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable> <IdleSettings> <StopOnIdleEnd>true</StopOnIdleEnd> <RestartOnIdle>false</RestartOnIdle> </IdleSettings> <AllowStartOnDemand>true</AllowStartOnDemand> <Enabled>true</Enabled> <Hidden>false</Hidden> <RunOnlyIfIdle>false</RunOnlyIfIdle> <WakeToRun>false</WakeToRun> <ExecutionTimeLimit>PT72H</ExecutionTimeLimit> <Priority>7</Priority> </Settings> <Actions Context="Author"> <Exec> <Command>C:\Windows\System32\wscript.exe</Command> <Arguments>C:\Windows\Setup\Scripts\UnlockStartLayout.vbs</Arguments> </Exec> </Actions> </Task>
'@
    Set-Content -Path (Join-Path $scriptsDst 'UnlockStartLayout.xml') -Value $unlockXml -Encoding Utf8

    $vboxPs1 = @'
& { foreach( $letter in 'DEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray() ) { $exe = "${letter}:\VBoxWindowsAdditions.exe"; if( Test-Path -LiteralPath $exe ) { $certs = "${letter}:\cert"; Start-Process -FilePath "${certs}\VBoxCertUtil.exe" -ArgumentList "add-trusted-publisher ${certs}\vbox*.cer", "--root ${certs}\vbox*.cer" -Wait; Start-Process -FilePath $exe -ArgumentList '/with_wddm', '/S' -Wait; return; } } 'VBoxGuestAdditions.iso is not attached to this VM.'; } *>&1 | Out-String -Width 1KB -Stream >> 'C:\Windows\Setup\Scripts\VBoxGuestAdditions.log';
'@
    Set-Content -Path (Join-Path $scriptsDst 'VBoxGuestAdditions.ps1') -Value $vboxPs1 -Encoding Utf8

    $vmwarePs1 = @'
& { foreach( $letter in 'DEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray() ) { $exe = "${letter}:\setup.exe"; if( ( Get-Item -LiteralPath $exe -ErrorAction 'SilentlyContinue' | Select-Object -ExpandProperty 'VersionInfo' | Select-Object -ExpandProperty 'ProductName' ) -eq 'VMware Tools' ) { Start-Process -FilePath $exe -ArgumentList '/s /v /qn REBOOT=R' -Wait; return; } } 'VMware Tools image (windows.iso) is not attached to this VM.'; } *>&1 | Out-String -Width 1KB -Stream >> 'C:\Windows\Setup\Scripts\VMwareTools.log';
'@
    Set-Content -Path (Join-Path $scriptsDst 'VMwareTools.ps1') -Value $vmwarePs1 -Encoding Utf8

    $virtioPs1 = @'
& { foreach( $letter in 'DEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray() ) { $exe = "${letter}:\virtio-win-guest-tools.exe"; if( Test-Path -LiteralPath $exe ) { Start-Process -FilePath $exe -ArgumentList '/passive', '/norestart' -Wait; return; } } 'VirtIO Guest Tools image (virtio-win-*.iso) is not attached to this VM.'; } *>&1 | Out-String -Width 1KB -Stream >> 'C:\Windows\Setup\Scripts\VirtIoGuestTools.log';
'@
    Set-Content -Path (Join-Path $scriptsDst 'VirtIoGuestTools.ps1') -Value $virtioPs1 -Encoding Utf8

    $parallelsPs1 = @'
& { foreach( $letter in 'DEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray() ) { $exe = "${letter}:\PTAgent.exe"; if( Test-Path -LiteralPath $exe ) { Start-Process -FilePath $exe -ArgumentList '/install_silent' -Wait; return; } } 'Parallels Tools image (prl-tools-win-*.iso) is not attached to this VM.'; } *>&1 | Out-String -Width 1KB -Stream >> 'C:\Windows\Setup\Scripts\ParallelsTools.log';
'@
    Set-Content -Path (Join-Path $scriptsDst 'ParallelsTools.ps1') -Value $parallelsPs1 -Encoding Utf8

    $startPinsPs1 = @'
$json = '{"pinnedList":[]}'; if( [System.Environment]::OSVersion.Version.Build -lt 20000 ) { return; } $key = 'Registry::HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; New-Item -Path $key -ItemType 'Directory' -ErrorAction 'SilentlyContinue'; Set-ItemProperty -LiteralPath $key -Name 'ConfigureStartPins' -Value $json -Type 'String';
'@
    Set-Content -Path (Join-Path $scriptsDst 'SetStartPins.ps1') -Value $startPinsPs1 -Encoding Utf8

    $defaultShellDst = Join-Path $Mount 'Users\Default\AppData\Local\Microsoft\Windows\Shell'
    New-Item -ItemType Directory -Force -Path $defaultShellDst | Out-Null
    $shellXml = @'
<LayoutModificationTemplate Version="1" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"> <LayoutOptions StartTileGroupCellWidth="6" /> <DefaultLayoutOverride> <StartLayoutCollection> <StartLayout GroupCellWidth="6" xmlns="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" /> </StartLayoutCollection> </DefaultLayoutOverride> </LayoutModificationTemplate>
'@
    Set-Content -Path (Join-Path $defaultShellDst 'LayoutModification.xml') -Value $shellXml -Encoding Utf8

    $specializePs1 = @'
$scripts = @( { net.exe accounts /maxpwage:UNLIMITED; }; { reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v "DisableCloudOptimizedContent" /t REG_DWORD /d 1 /f; [System.Diagnostics.EventLog]::CreateEventSource( 'UnattendGenerator', 'Application' ); }; { Register-ScheduledTask -TaskName 'UnlockStartLayout' -Xml $( Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UnlockStartLayout.xml' -Raw ); }; { reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f }; { netsh.exe advfirewall firewall set rule group="@FirewallAPI.dll,-28752" new enable=Yes; reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f; }; { icacls.exe C:\ /remove:g "*S-1-5-11" }; { Set-ExecutionPolicy -Scope 'LocalMachine' -ExecutionPolicy 'RemoteSigned' -Force; }; { reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f; }; { reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f; reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\FVE" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f; try { manage-bde.exe -off C: } catch {}; try { Get-BitLockerVolume | Where-Object { $_.VolumeStatus -ne 'FullyDecrypted' } | Disable-BitLocker -ErrorAction SilentlyContinue } catch {}; }; { compact.exe /CompactOS:always; }; { reg.exe add "HKLM\Software\Policies\Microsoft\Edge" /v HideFirstRunExperience /t REG_DWORD /d 1 /f; }; { & 'C:\Windows\Setup\Scripts\SetStartPins.ps1'; }; { Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ControlAnimations" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\AnimateMinMax" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\TaskbarAnimations" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\DWMAeroPeekEnabled" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\MenuAnimation" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\TooltipAnimation" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\SelectionFade" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\DWMSaveThumbnailEnabled" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\CursorShadow" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ListviewShadow" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ThumbnailsOrIcon" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ListviewAlphaSelect" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\DragFullWindows" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ComboBoxAnimation" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\FontSmoothing" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\ListBoxSmoothScrolling" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; Set-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\DropShadow" -Name 'DefaultValue' -Value 1 -Type 'DWord' -Force; }; { reg.exe add "HKLM\System\CurrentControlSet\Control\Session Manager" /v "DisableWpbtExecution" /t REG_DWORD /d 1 /f; }; ); & { [float] $complete = 0; [float] $increment = 100 / $scripts.Count; foreach( $script in $scripts ) { Write-Progress -Id 0 -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete $complete; '*** Will now execute command "{0}".' -f $( $script.ToString().Trim() -replace '\s+', ' ' -replace '^(.{99})(.+)$', '$1...'; ); $start = [datetime]::Now; & $script; '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds; "`r`n" * 3; $complete += $increment; } } *>&1 | Out-String -Width 1KB -Stream >> "C:\Windows\Setup\Scripts\Specialize.log";
'@
    Set-Content -Path (Join-Path $scriptsDst 'Specialize.ps1') -Value $specializePs1 -Encoding Utf8

    $userOncePs1 = @'
$scripts = @(
    { [System.Diagnostics.EventLog]::WriteEntry( 'UnattendGenerator', "User '$env:USERNAME' has requested to unlock the Start menu layout.", [System.Diagnostics.EventLogEntryType]::Information, 1 ); };
    { @( Get-ChildItem -LiteralPath $env:USERPROFILE -Force -Recurse -Depth 2; ) | Where-Object -FilterScript { $_.Attributes.HasFlag( [System.IO.FileAttributes]::ReparsePoint ); } | Remove-Item -Force -Recurse -Verbose; };
    { Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type 'DWord' -Value 1; };
    { Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideIcons' -Type 'DWord' -Value 1; };
    { Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAl' -Type 'DWord' -Value 0; };
    { Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarDa' -Type 'DWord' -Value 0; };
    { Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarMn' -Type 'DWord' -Value 0; };
    { Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton' -Type 'DWord' -Value 1; };
    { Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0; };
    { New-Item -Path 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Force | Out-Null; Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Name '{645FF040-5081-101B-9F08-00AA002F954E}' -Type 'DWord' -Value 1; Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Name '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' -Type 'DWord' -Value 1; Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Name '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' -Type 'DWord' -Value 1; Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Name '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}' -Type 'DWord' -Value 1; };
    { New-Item -Path 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Start' -Force | Out-Null; Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'Start_ShowSettings' -Type 'DWord' -Value 1; Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'Start_ShowFileExplorer' -Type 'DWord' -Value 1; Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'Start_ShowNetwork' -Type 'DWord' -Value 1; Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'Start_ShowUserFiles' -Type 'DWord' -Value 1; Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'Start_ShowDownloads' -Type 'DWord' -Value 1; Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'Start_ShowDocuments' -Type 'DWord' -Value 1; };
    { Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'Favorites' -Type 'Binary' -Value ([byte[]]@()); };
    { Set-ItemProperty -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Type 'DWord' -Value 1 -Force; };
    { Get-Process -Name 'explorer' -ErrorAction 'SilentlyContinue' | Where-Object -FilterScript { $_.SessionId -eq ( Get-Process -Id $PID ).SessionId; } | Stop-Process -Force; }
); & { [float] $complete = 0; [float] $increment = 100 / $scripts.Count; foreach( $script in $scripts ) { Write-Progress -Id 0 -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete $complete; '*** Will now execute command "{0}".' -f $( $script.ToString().Trim() -replace '\s+', ' ' -replace '^(.{99})(.+)$', '$1...'; ); $start = [datetime]::Now; & $script; '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds; "`r`n" * 3; $complete += $increment; } } *>&1 | Out-String -Width 1KB -Stream >> "$env:TEMP\UserOnce.log";
'@
    Set-Content -Path (Join-Path $scriptsDst 'UserOnce.ps1') -Value $userOncePs1 -Encoding Utf8

    $defaultUserPs1 = @'
$scripts = @(
    { reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "StartLayoutFile" /t REG_SZ /d "C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml" /f; reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "LockedStartLayout" /t REG_DWORD /d 1 /f; };
    { reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideFileExt" /t REG_DWORD /d 0 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "HideIcons" /t REG_DWORD /d 1 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "TaskbarAl" /t REG_DWORD /d 0 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v "ShowTaskViewButton" /t REG_DWORD /d 1 /f; };
    { reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Search" /v SearchboxTaskbarMode /t REG_DWORD /d 0 /f; };
    { reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v "{645FF040-5081-101B-9F08-00AA002F954E}" /t REG_DWORD /d 1 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" /t REG_DWORD /d 1 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" /t REG_DWORD /d 1 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}" /t REG_DWORD /d 1 /f; };
    { reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Start" /v Start_ShowSettings /t REG_DWORD /d 1 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Start" /v Start_ShowFileExplorer /t REG_DWORD /d 1 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Start" /v Start_ShowNetwork /t REG_DWORD /d 1 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Start" /v Start_ShowUserFiles /t REG_DWORD /d 1 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Start" /v Start_ShowDownloads /t REG_DWORD /d 1 /f; reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Start" /v Start_ShowDocuments /t REG_DWORD /d 1 /f; };
    { $params = @{ LiteralPath = 'Registry::HKU\DefaultUser\Control Panel\Mouse'; Type = 'String'; Value = 0; Force = $true; }; Set-ItemProperty @params -Name 'MouseSpeed'; Set-ItemProperty @params -Name 'MouseThreshold1'; Set-ItemProperty @params -Name 'MouseThreshold2'; };
    { reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v DisableSearchBoxSuggestions /t REG_DWORD /d 1 /f; };
    { reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v TaskbarEndTask /t REG_DWORD /d 1 /f; };
    { reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle \""Normal\"" -ExecutionPolicy \""Unrestricted\"" -NoProfile -File \""C:\Windows\Setup\Scripts\UserOnce.ps1\""" /f; }
); & { [float] $complete = 0; [float] $increment = 100 / $scripts.Count; foreach( $script in $scripts ) { Write-Progress -Id 0 -Activity "Running scripts to modify the default user's registry hive. Do not close this window." -PercentComplete $complete; '*** Will now execute command "{0}".' -f $( $script.ToString().Trim() -replace '\s+', ' ' -replace '^(.{99})(.+)$', '$1...'; ); $start = [datetime]::Now; & $script; '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds; "`r`n" * 3; $complete += $increment; } } *>&1 | Out-String -Width 1KB -Stream >> "C:\Windows\Setup\Scripts\DefaultUser.log";
'@
    Set-Content -Path (Join-Path $scriptsDst 'DefaultUser.ps1') -Value $defaultUserPs1 -Encoding Utf8

    $firstLogonPs1 = @'
$scripts = @( { Set-ItemProperty -LiteralPath 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoLogonCount' -Type 'DWord' -Force -Value 0; }; { @( Get-ChildItem -LiteralPath 'C:\' -Force; Get-ChildItem -LiteralPath 'C:\Users' -Force; Get-ChildItem -LiteralPath 'C:\Users\Default' -Force -Recurse -Depth 2; Get-ChildItem -LiteralPath 'C:\Users\Public' -Force -Recurse -Depth 2; Get-ChildItem -LiteralPath 'C:\ProgramData' -Force; ) | Where-Object -FilterScript { $_.Attributes.HasFlag( [System.IO.FileAttributes]::ReparsePoint ); } | Remove-Item -Force -Recurse -Verbose; }; { & 'C:\Windows\Setup\Scripts\VBoxGuestAdditions.ps1'; }; { & 'C:\Windows\Setup\Scripts\VMwareTools.ps1'; }; { & 'C:\Windows\Setup\Scripts\VirtIoGuestTools.ps1'; }; { & 'C:\Windows\Setup\Scripts\ParallelsTools.ps1'; }; { cmd.exe /c "rmdir C:\Windows.old"; }; { Remove-Item -LiteralPath @( 'C:\Windows\Panther\unattend.xml'; 'C:\Windows\Panther\unattend-original.xml'; 'C:\Windows\Setup\Scripts\Wifi.xml'; ) -Force -ErrorAction 'SilentlyContinue' -Verbose; }; ); & { [float] $complete = 0; [float] $increment = 100 / $scripts.Count; foreach( $script in $scripts ) { Write-Progress -Id 0 -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete; '*** Will now execute command "{0}".' -f $( $script.ToString().Trim() -replace '\s+', ' ' -replace '^(.{99})(.+)$', '$1...'; ); $start = [datetime]::Now; & $script; '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds; "`r`n" * 3; $complete += $increment; } } *>&1 | Out-String -Width 1KB -Stream >> "C:\Windows\Setup\Scripts\FirstLogon.log";
'@
    Set-Content -Path (Join-Path $scriptsDst 'FirstLogon.ps1') -Value $firstLogonPs1 -Encoding Utf8
}

# Bake the MiOS FACTORY IDENTITY into the image OFFLINE, all SSOT-driven: the palette
# (accent -> DWM + dark + transparency), Geist Mono Nerd Font, Bibata-Modern-Classic
# cursor, a MiOS wallpaper, and OEM branding. Machine-wide bits (fonts/OEM) go into
# the offline SOFTWARE hive (HKLM -- safe). The PER-USER bits (palette/cursor/wallpaper)
# are emitted as mios-theme-default.reg for SetupComplete to import into the Default
# hive LIVE (offline user-hive editing corrupts the profile; live is safe). Every
# piece is defensive/non-fatal so one download hiccup can't fail the whole build.
function Set-MiOSIdentityOffline {
    param([string]$Mount, [string]$ScriptsDst, $Toml)
    $accent = ([string](Get-Toml $Toml 'colors.accent' '#1A407F')).TrimStart('#')
    if ($accent.Length -lt 6) { $accent = '1A407F' }
    $r = $accent.Substring(0,2); $g = $accent.Substring(2,2); $b = $accent.Substring(4,2)
    $dwm = ("ff$b$g$r").ToLower()   # DWM AccentColor is 0xAABBGGRR
    Write-Host "[*] MiOS identity bake: accent #$accent -> DWM 0x$dwm (dark + transparency + Geist + Bibata + wallpaper + OEM)" -ForegroundColor Cyan

    # --- wallpaper + logo -> Windows\Web\MiOS (the exact paths the lib branding references) ---
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $webDir = Join-Path $Mount 'Windows\Web\MiOS'; New-Item -ItemType Directory -Force -Path $webDir | Out-Null
        $bg = ([string](Get-Toml $Toml 'colors.bg' '#282262')).TrimStart('#')
        $c1 = [System.Drawing.ColorTranslator]::FromHtml("#$bg"); $c2 = [System.Drawing.ColorTranslator]::FromHtml("#$accent")
        $bmp = New-Object System.Drawing.Bitmap(2560,1440); $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $rectF = New-Object System.Drawing.Rectangle(0,0,2560,1440)
        $gfx.FillRectangle((New-Object System.Drawing.Drawing2D.LinearGradientBrush($rectF,$c1,$c2,45.0)),$rectF)
        $bmp.Save((Join-Path $webDir 'mios-wallpaper.jpg'),[System.Drawing.Imaging.ImageFormat]::Jpeg)
        $lg = New-Object System.Drawing.Bitmap(120,120); $lgx = [System.Drawing.Graphics]::FromImage($lg); $lgx.Clear($c2); $lg.Save((Join-Path $webDir 'mios-logo.bmp'),[System.Drawing.Imaging.ImageFormat]::Bmp)
        $gfx.Dispose(); $bmp.Dispose(); $lgx.Dispose(); $lg.Dispose(); Write-Host "    wallpaper + logo -> Windows\Web\MiOS" -ForegroundColor DarkGray
        
        # Stage the compiled wallpaper executables and WebView2 DLLs into the offline image
        $hostWebDir = "C:\Windows\Web\MiOS"
        if (Test-Path $hostWebDir) {
            Get-ChildItem -Path $hostWebDir -Include *.exe, *.dll, *.html, *.cs -File | ForEach-Object {
                Copy-Item $_.FullName (Join-Path $webDir $_.Name) -Force
            }
            Write-Host "    staged wallpaper service binaries and DLLs into the image offline" -ForegroundColor Green
        }
    } catch { Write-Host "    [!] wallpaper/logo skipped: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow }

    # --- Geist Mono Nerd Font: download, stage to Windows\Fonts, register offline (HKLM) ---
    $fontReg = @()
    try {
        $ftmp = Join-Path $env:TEMP ('mios-geist-'+[guid]::NewGuid().ToString('N').Substring(0,8)); New-Item -ItemType Directory -Force -Path $ftmp | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/GeistMono.zip' -OutFile (Join-Path $ftmp 'g.zip') -ErrorAction Stop
        Expand-Archive -Path (Join-Path $ftmp 'g.zip') -DestinationPath $ftmp -Force
        $faces = @(Get-ChildItem $ftmp -Recurse -Include *.ttf,*.otf -File | Where-Object { $_.Name -match 'Mono' -and $_.Name -notmatch 'Propo' })
        if (-not $faces.Count) { $faces = @(Get-ChildItem $ftmp -Recurse -Include *.ttf,*.otf -File) }
        $fontsDst = Join-Path $Mount 'Windows\Fonts'
        foreach ($f in $faces) {
            Copy-Item $f.FullName (Join-Path $fontsDst $f.Name) -Force
            $face = ([IO.Path]::GetFileNameWithoutExtension($f.Name)) -replace '([a-z])([A-Z])', '$1 $2'
            $fontReg += @{ name = "$face $(if($f.Extension -eq '.otf'){'(OpenType)'}else{'(TrueType)'})"; file = $f.Name }
        }
        Write-Host "    staged $($faces.Count) Geist Mono face(s) -> Windows\Fonts" -ForegroundColor DarkGray
    } catch { Write-Host "    [!] Geist font stage skipped: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow }
    if ($fontReg.Count) {
        $sw = Join-Path $Mount 'Windows\System32\config\SOFTWARE'; & reg.exe load 'HKLM\MIOS_FNT' $sw 2>&1 | Out-Null
        try { foreach ($fr in $fontReg) { & reg.exe add 'HKLM\MIOS_FNT\Microsoft\Windows NT\CurrentVersion\Fonts' /v $fr.name /t REG_SZ /d $fr.file /f 2>&1 | Out-Null } }
        finally { [gc]::Collect(); & reg.exe unload 'HKLM\MIOS_FNT' 2>&1 | Out-Null }
    }

    # --- Bibata-Modern-Classic cursor: download, stage the .cur/.ani into the image ---
    $curScheme = ''
    try {
        $btmp = Join-Path $env:TEMP ('mios-bibata-'+[guid]::NewGuid().ToString('N').Substring(0,8)); New-Item -ItemType Directory -Force -Path $btmp | Out-Null
        # Use the rate-limit-free /releases/latest/download/ redirect (the GitHub API
        # 403s without a token on a fresh build host -- the prior silent Bibata failure).
        # SSOT-overridable; fall through the API only if the direct asset name changed.
        $url = Get-Toml $Toml 'branding.cursor_url' 'https://github.com/ful1e5/Bibata_Cursor/releases/latest/download/Bibata-Modern-Classic-Windows.zip'
        try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile (Join-Path $btmp 'b.zip') -ErrorAction Stop }
        catch {
            $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/ful1e5/Bibata_Cursor/releases/latest' -Headers @{ 'User-Agent'='MiOS' } -ErrorAction Stop
            $url = ($rel.assets | Where-Object { $_.name -match 'Modern-Classic.*Windows.*\.zip$' } | Select-Object -First 1).browser_download_url
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile (Join-Path $btmp 'b.zip') -ErrorAction Stop
        }
        $zip = Join-Path $btmp 'b.zip'
        if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 20KB) { throw "download is not a valid zip ($([math]::Round((Get-Item $zip -EA SilentlyContinue).Length/1KB,1)) KB -- likely an HTML error page from a moved URL)" }
        Expand-Archive -Path $zip -DestinationPath $btmp -Force
        # Find the .cur/.ani cursors WHEREVER they landed (archive layout varies: root, a
        # single folder, or nested) -- group by directory + take the richest. The prior
        # ">=10 in a SUBdirectory" rule silently missed root/flat layouts (no message).
        $allCur = @(Get-ChildItem $btmp -Recurse -File -EA SilentlyContinue | Where-Object { $_.Extension -in '.cur','.ani' })
        $grp = $allCur | Group-Object DirectoryName | Sort-Object Count -Descending | Select-Object -First 1
        if ($grp -and $grp.Count -ge 8) {
            $curDst = Join-Path $Mount 'Windows\Cursors\Bibata-Modern-Classic'; New-Item -ItemType Directory -Force -Path $curDst | Out-Null
            Copy-Item (Join-Path $grp.Name '*.cur') $curDst -Force -EA SilentlyContinue
            Copy-Item (Join-Path $grp.Name '*.ani') $curDst -Force -EA SilentlyContinue
            $staged = @(Get-ChildItem $curDst -File -EA SilentlyContinue).Count
            $curScheme = 'Bibata-Modern-Classic'
            Write-Host "    staged $staged Bibata cursor(s) -> Windows\Cursors\Bibata-Modern-Classic" -ForegroundColor DarkGray

            # --- OEM Systems-Integrator Native Cursor Replacement ---
            # Overwrite default Windows Cursors in C:\Windows\Cursors so system contexts
            # (Winlogon, Logon Screen, Shutdown Screen, Default User) natively use custom cursors without unloading.
            $sysCur = Join-Path $Mount 'Windows\Cursors'
            $cMap = @{
                'aero_arrow.cur'   = 'pointer.cur'
                'aero_helpsel.cur' = 'help.cur'
                'aero_working.ani' = 'working.ani'
                'aero_busy.ani'    = 'busy.ani'
                'aero_cross.cur'   = 'cross.cur'
                'aero_text.cur'    = 'text.cur'
                'aero_unavail.cur' = 'unavail.cur'
                'aero_ns.cur'       = 'ns.cur'
                'aero_ew.cur'       = 'ew.cur'
                'aero_nwse.cur'     = 'nwse.cur'
                'aero_nesw.cur'     = 'nesw.cur'
                'aero_move.cur'     = 'move.cur'
                'aero_up.cur'       = 'up.cur'
                'aero_link.cur'     = 'link.cur'
                'aero_pin.cur'      = 'pin.cur'
                'aero_person.cur'   = 'person.cur'
            }
            foreach ($k in $cMap.Keys) {
                $src = Join-Path $curDst $cMap[$k]
                $dst = Join-Path $sysCur $k
                if (Test-Path $src) {
                    try {
                        if (Test-Path $dst) { Set-ItemProperty -Path $dst -Name IsReadOnly -Value $false -Force -EA SilentlyContinue }
                        Copy-Item $src $dst -Force -EA SilentlyContinue
                    } catch { }
                }
            }
            Write-Host "    overwrote system default cursors in Windows\Cursors\ (OEM native cursor retention on Shutdown/Logon)" -ForegroundColor Green

            # Register the scheme in HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\Schemes + Cursors\Default
            $swHive = Join-Path $Mount 'Windows\System32\config\SOFTWARE'
            if (Test-Path $swHive) {
                & reg.exe load 'HKLM\MIOS_CUR_SW' $swHive 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        $schVal = "%SystemRoot%\Cursors\Bibata-Modern-Classic\Pointer.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Help.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Working.ani,%SystemRoot%\Cursors\Bibata-Modern-Classic\Busy.ani,%SystemRoot%\Cursors\Bibata-Modern-Classic\Cross.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Text.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Unavail.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Vert.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Horiz.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Dyna1.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Dyna2.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Move.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Up.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Link.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Pin.cur,%SystemRoot%\Cursors\Bibata-Modern-Classic\Person.cur"
                        & reg.exe add "HKLM\MIOS_CUR_SW\Microsoft\Windows\CurrentVersion\Control Panel\Schemes" /v "Bibata-Modern-Classic" /t REG_EXPAND_SZ /d $schVal /f 2>&1 | Out-Null
                        $cRoles = @{
                            'Arrow'='Pointer.cur'; 'Help'='Help.cur'; 'AppStarting'='Working.ani'; 'Wait'='Busy.ani';
                            'Crosshair'='Cross.cur'; 'IBeam'='Text.cur'; 'No'='Unavail.cur'; 'SizeNS'='Vert.cur';
                            'SizeWE'='Horiz.cur'; 'SizeNWSE'='Dyna1.cur'; 'SizeNESW'='Dyna2.cur'; 'SizeAll'='Move.cur';
                            'UpArrow'='Up.cur'; 'Hand'='Link.cur'; 'Pin'='Pin.cur'; 'Person'='Person.cur'
                        }
                        foreach ($rName in $cRoles.Keys) {
                            $rPath = "%SystemRoot%\Cursors\Bibata-Modern-Classic\$($cRoles[$rName])"
                            & reg.exe add "HKLM\MIOS_CUR_SW\Microsoft\Windows\CurrentVersion\Control Panel\Cursors\Default" /v $rName /t REG_EXPAND_SZ /d $rPath /f 2>&1 | Out-Null
                        }
                        Write-Host "    registered Bibata-Modern-Classic in HKLM Control Panel\Schemes & Cursors\Default" -ForegroundColor Green
                    } finally {
                        [gc]::Collect()
                        & reg.exe unload 'HKLM\MIOS_CUR_SW' 2>&1 | Out-Null
                    }
                }
            }
        } else { Write-Host "    [!] Bibata: no cursor set found in archive (got $($allCur.Count) .cur/.ani files) -- cursor scheme skipped" -ForegroundColor Yellow }
    } catch { Write-Host "    [!] Bibata cursor stage skipped: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow }

    # --- MiOS.theme + Default-profile ACTIVE THEME (OEM full-shell theming that PERSISTS).
    #     Loose Personalize DWORDs are NOT enough: Windows re-applies the CurrentTheme
    #     (.theme) at EVERY logon and resets wallpaper / Start / taskbar / titlebar color /
    #     light-dark back to the default aero.theme -- exactly why the shell showed light
    #     after a re-logon. Fix the OEM way: ship a real MiOS.theme and make it the Default
    #     profile's CurrentTheme, so every account created at OOBE logs in with the FULL
    #     theme applied (dark Start/taskbar/titlebars + Mica transparency + MiOS accent +
    #     wallpaper + Bibata) and it persists. Offline Default-hive edit uses the CORRECT
    #     handle-release procedure (reg.exe + [gc]::Collect + WaitForPendingFinalizers +
    #     sleep before unload) -- the corruption that broke this before was procedural. ---
    try {
        $themesDst = Join-Path $Mount 'Windows\Resources\Themes'; New-Item -ItemType Directory -Force -Path $themesDst | Out-Null
        # ALL scalars from the SSOT; cursor map from the single Get-MiOSCursorMap (shared with
        # the lib -- never duplicated). accent = colors.accent; mode = theme.mode; the rest = [branding].
        $themeName = Get-Toml $Toml 'branding.theme_name' (Get-Toml $Toml 'meta.name' 'MiOS')
        $wpTheme   = (Get-Toml $Toml 'branding.wallpaper' 'C:\Windows\Web\MiOS\mios-wallpaper.jpg') -replace '(?i)^C:\\Windows', '%SystemRoot%'
        $wpStyle   = Get-Toml $Toml 'branding.wallpaper_style' '10'
        $curName   = Get-Toml $Toml 'branding.cursor_scheme' 'Bibata-Modern-Classic'
        $curDir    = Get-Toml $Toml 'branding.cursor_dir'    '%SystemRoot%\Cursors\Bibata-Modern-Classic'
        $darkVal   = if ((Get-Toml $Toml 'theme.mode' 'dark') -match '^(?i)light$') { '1' } else { '0' }
        $transp    = if ((Get-Toml $Toml 'theme.transparency' 'true') -match '^(?i:true|1|yes)$') { '1' } else { '0' }
        $cm = Get-MiOSCursorMap
        $theme = New-Object System.Collections.Generic.List[string]
        @('[Theme]',"DisplayName=$themeName",'','[Control Panel\Desktop]',"Wallpaper=$wpTheme","WallpaperStyle=$wpStyle",'',
          '[VisualStyles]','Path=%SystemRoot%\resources\Themes\Aero\Aero.msstyles','ColorStyle=NormalColor','Size=NormalSize','AutoColorization=0',
          ('ColorizationColor=0xFF{0}' -f $accent),"AppsUseLightTheme=$darkVal","SystemUsesLightTheme=$darkVal","EnableTransparency=$transp",'') | ForEach-Object { $theme.Add($_) }
        if ($curScheme) { $theme.Add('[Control Panel\Cursors]'); foreach ($k in $cm.Keys) { $theme.Add(('{0}={1}\{2}' -f $k, $curDir, $cm[$k])) }; $theme.Add("DefaultValue=$curName"); $theme.Add('') }
        @('[MasterThemeSelector]','MTSM=DABJDKT') | ForEach-Object { $theme.Add($_) }
        [IO.File]::WriteAllText((Join-Path $themesDst 'MiOS.theme'), (($theme -join "`r`n") + "`r`n"), [System.Text.Encoding]::Unicode)
        Write-Host "    staged MiOS.theme -> Windows\Resources\Themes" -ForegroundColor DarkGray
        $defHive = Join-Path $Mount 'Users\Default\NTUSER.DAT'
        if (Test-Path $defHive) {
            & reg.exe load 'HKLM\MIOS_DEFT' $defHive 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                foreach ($ln in (Get-MiOSPerUserBrandingReg -Toml $Toml -HivePrefix 'HKLM\MIOS_DEFT')) { & cmd.exe /c $ln 2>&1 | Out-Null }
                & reg.exe add 'HKLM\MIOS_DEFT\Software\Microsoft\Windows\CurrentVersion\Themes' /v CurrentTheme /t REG_EXPAND_SZ /d '%SystemRoot%\resources\Themes\MiOS.theme' /f 2>&1 | Out-Null
                [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Seconds 3
                & reg.exe unload 'HKLM\MIOS_DEFT' 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { [gc]::Collect(); Start-Sleep -Seconds 3; & reg.exe unload 'HKLM\MIOS_DEFT' 2>&1 | Out-Null }
                if ($LASTEXITCODE -eq 0) { Write-Host "    baked MiOS active theme into the Default profile (full-shell dark + accent + Bibata; persists per-account)" -ForegroundColor Green }
                else { Write-Host "    [!] Default-hive unload FAILED ($LASTEXITCODE) -- theme not baked (would risk profile corruption; skipped safely)" -ForegroundColor Red }
            } else { Write-Host "    [!] could not load Default NTUSER.DAT (MiOS.theme default-bake skipped)" -ForegroundColor Yellow }
        }
    } catch { Write-Host "    [!] MiOS.theme bake skipped: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow }

    # --- bake YOUR New-MiOSProvisionCommands as mios-identity.cmd. SetupComplete runs it
    #     LIVE as SYSTEM, pre-logon, SILENT -- ONE SSOT for OEM + Geist font-substitution +
    #     lockscreen + theme/accent/wallpaper/RGB + Bibata cursor + Linux layout + Xbox mode.
    #     HKLM + Default-hive writes apply to every account; OneDrive is removed. This is
    #     YOUR lib (MiOS-Provision.lib.ps1), not a reinvention. ---
    try {
        $prov = New-MiOSProvisionCommands -Toml $Toml
        $out = @('@echo off', 'set "L=%WINDIR%\Temp\mios-identity.log"', 'echo [MiOS] identity apply %DATE% %TIME%>>"%L%"')
        $n = 0
        foreach ($grp in $prov) {
            $out += ('echo [MiOS] {0}>>"%L%"' -f $grp.Description)
            foreach ($cmd in @($grp.Commands)) { $out += ("$cmd>>`"%L%`" 2>&1"); $n++ }
        }
        $out += 'exit /b 0'
        [IO.File]::WriteAllText((Join-Path $ScriptsDst 'mios-identity.cmd'), (($out -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
        Write-Host "[*] Baked mios-identity.cmd ($n commands from your New-MiOSProvisionCommands) -> SetupComplete runs it silent, pre-logon" -ForegroundColor Green
    } catch { Write-Host "[!] mios-identity.cmd bake FAILED: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Red }

    # --- ACCOUNT-DEPENDENT provisioning (mios-provision-live.ps1). KEYSTONE FIX:
    #     SetupComplete runs BEFORE the desktop account is created (PROVEN: mios-remote's
    #     `net localgroup "Remote Desktop Users" "mios"` returned System error 1317
    #     "The specified account does not exist" -- mios is created later, in oobeSystem,
    #     and auto-logs-in AFTER SetupComplete). So the two account-dependent operations --
    #     (1) adding the real account to Remote Desktop Users (enhanced-session sign-in)
    #     and (2) applying the PER-USER MiOS theme to the real account's OWN hive (under
    #     SYSTEM, HKCU is SYSTEM's; the Default-hive copy does NOT carry to mios, which
    #     Windows creates light-themed) -- must run AFTER the account exists. ONLOGON tasks
    #     were observed NOT to register in specialize, so this runs via a PROVEN MINUTE task
    #     (MiOS-Provision, registered by New-MiOSHostServiceCommands) as the admin svc
    #     account: it waits for the real account, applies RDU + theme to its live HKU\<sid>
    #     (or a loaded NTUSER.DAT), marker-gates, then self-deletes. --
    try {
        $perUserLines = @(Get-MiOSPerUserBrandingReg -Toml $Toml -HivePrefix '__HIVE__')
        $svcUser = Get-Toml $Toml 'autounattend.service.svc_user' 'mios-sudo'
        $plines = ($perUserLines | ForEach-Object { "  '" + ($_ -replace "'","''") + "'" }) -join ",`r`n"
        $tpl = @'
# MiOS live account provisioning. Runs as the admin svc account via the MiOS-Provision
# MINUTE task until the REAL desktop account exists, then (1) adds it to Remote Desktop
# Users so Hyper-V enhanced session / RDP signs in, and (2) applies the per-user MiOS
# theme (dark/accent/transparency/RGB + wallpaper + Bibata) to its ACTUAL profile hive.
# Marker-gated + self-deleting -- runs exactly once. All values are SSOT-derived at bake.
$ErrorActionPreference='SilentlyContinue'
$log='C:\ProgramData\MiOS\logs\provision-live.log'; New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
function Log($m){ "$([DateTime]::Now.ToString('HH:mm:ss')) $m" | Add-Content $log }
$marker='C:\ProgramData\MiOS\provision-live.done'
if (Test-Path $marker) { & schtasks.exe /delete /tn 'MiOS-Provision' /f 2>$null | Out-Null; exit 0 }
# Keep the RID-500 service account enabled -- OOBE can disable the built-in admin once the
# desktop account is created, which would stop the mios-sudo tasks (brain/Gaming). We run
# as SYSTEM so we can re-assert it before those tasks need to log on.
& net.exe user '__SVCUSER__' /active:yes 2>$null | Out-Null
$exclude=@('Public','Default','Default User','defaultuser0','__SVCUSER__','systemprofile','ServiceProfiles','All Users')
# Enumerate real desktop profiles via Win32_UserProfile -- it yields the authoritative
# SID + a Loaded (logged-in) flag DIRECTLY. Do NOT use NTAccount.Translate: as SYSTEM it
# throws "identity references could not be translated", which left $sid null so every
# tick deferred forever + never granted the right.
$profiles=@(Get-CimInstance Win32_UserProfile -EA SilentlyContinue | Where-Object { $_.LocalPath -like 'C:\Users\*' -and -not $_.Special -and ((Split-Path $_.LocalPath -Leaf) -notin $exclude) })
if (-not $profiles.Count) { Log 'no real desktop profile yet -- retry next MINUTE tick'; exit 0 }
$reg=@(
__REGLINES__
)
function Grant-Right($sidv,$right){
  try {
    $inf=Join-Path $env:TEMP 'mios-r.inf'; $sdb=Join-Path $env:TEMP 'mios-r.sdb'
    & secedit.exe /export /cfg $inf /areas USER_RIGHTS | Out-Null
    $ls=Get-Content $inf; $o=New-Object System.Collections.Generic.List[string]; $f=$false
    foreach($l in $ls){ if($l -match "^$right\s*="){ if($l -notmatch [regex]::Escape($sidv)){ $l=$l.TrimEnd()+",*$sidv" }; $f=$true }; $o.Add($l) }
    if(-not $f){ for($i=0;$i -lt $o.Count;$i++){ if($o[$i] -match '^\[Privilege Rights\]'){ $o.Insert($i+1,"$right = *$sidv"); break } } }
    $o | Set-Content $inf -Encoding Unicode
    & secedit.exe /import /cfg $inf /db $sdb | Out-Null
    & secedit.exe /configure /db $sdb /areas USER_RIGHTS | Out-Null
    Remove-Item $inf,$sdb -Force -EA SilentlyContinue
    Log "  granted $right"
  } catch { Log "  grant $right failed: $($_.Exception.Message)" }
}
$anyThemed=$false
foreach ($p in $profiles) {
  $u=Split-Path $p.LocalPath -Leaf
  $sid=$p.SID
  Log "provisioning $u (sid=$sid loaded=$($p.Loaded))"
  # (1) Remote Desktop Users membership + SeRemoteInteractiveLogonRight -- BY SID (no name
  #     translation). machine-wide + idempotent -> enhanced-session / RDP sign-in.
  try { Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $sid -ErrorAction Stop; Log "  added $u to Remote Desktop Users" }
  catch { if ("$($_.Exception.Message)" -match 'already') { Log "  $u already in Remote Desktop Users" } else { & net.exe localgroup 'Remote Desktop Users' $u /add 2>&1 | ForEach-Object { Log "  net-rdu: $_" } } }
  Grant-Right $sid 'SeRemoteInteractiveLogonRight'
  # (2) THEME -- only when the hive is LOADED (user logged in). Write to the LIVE HKU\<sid>
  #     ONLY -- never a separately-loaded NTUSER.DAT, which the user's own session clobbers
  #     on logoff (the bug that reverted the theme to light). Defer until logged on.
  if ($p.Loaded -and (Test-Path "Registry::HKEY_USERS\$sid")) {
    $hive="HKU\$sid"
    foreach ($ln in $reg) { & cmd.exe /c ($ln -replace '__HIVE__', $hive) 2>$null | Out-Null }
    Log "  MiOS theme applied to LIVE hive $hive"
    # refresh WITHOUT a clobbering reboot: restart this user's explorer so dark + accent +
    # cursor apply now (explorer re-reads them at start); the live-hive write persists.
    & RUNDLL32.EXE USER32.DLL,UpdatePerUserSystemParameters ,1 ,True 2>$null | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -EA SilentlyContinue | ForEach-Object { $own=$null; try { $own=$_.GetOwner().User } catch {}; if ($own -eq $u) { & taskkill.exe /PID $_.ProcessId /F 2>$null | Out-Null } }
    $anyThemed=$true
  } else { Log "  $u not logged in (Loaded=$($p.Loaded)) -- deferring theme; retry next tick" }
}
if ($anyThemed) {
  'done' | Set-Content $marker
  Log 'complete: theme applied to a LIVE session + RDU membership + SeRemoteInteractiveLogonRight granted -> self-deleting MiOS-Provision'
  & schtasks.exe /delete /tn 'MiOS-Provision' /f 2>$null | Out-Null
}
# else: nobody logged in yet -- exit WITHOUT the marker so the MINUTE task keeps retrying.
'@
        $ps = $tpl.Replace('__SVCUSER__', $svcUser).Replace('__REGLINES__', $plines)
        [IO.File]::WriteAllText((Join-Path $ScriptsDst 'mios-provision-live.ps1'), $ps, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "[*] Baked mios-provision-live.ps1 ($($perUserLines.Count) per-user reg ops) -> MINUTE task adds the real account to Remote Desktop Users + themes its profile post-creation" -ForegroundColor Green
    } catch { Write-Host "[!] mios-provision-live.ps1 bake FAILED: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Red }
}

# Bake the MiOS REMOTE-ACCESS + VIRT-INTEGRATION plane into the image so every
# deployment is reachable + host-integrated from factory. Three layers:
#   (A) OFFLINE SYSTEM hive  -- RDP listener on (fDenyTSConnections=0), NLA per SSOT,
#       TermService + sshd/ssh-agent set to autostart (safe: HKLM, not a user hive).
#   (B) OFFLINE OpenSSH.Server capability (Add-WindowsCapability -Path) + virtio-win
#       guest drivers (Add-WindowsDriver -Path), both non-fatal (online/skip fallback).
#   (C) mios-remote.cmd rendered from SSOT -- the RUNTIME bits that can't be baked:
#       adding the interactive desktop account(s) to "Remote Desktop Users" (WITHOUT
#       this, Hyper-V ENHANCED SESSION refuses sign-in -- "you need the right to sign
#       in through Remote Desktop Services"; the group carries SeRemoteInteractiveLogon
#       Right), firewall rules (RDP + SSH), Enable-PSRemoting, optional loopback NIC.
#       This can't run at specialize (the account is created later, in oobeSystem), so
#       SetupComplete calls it as SYSTEM (post-account, pre-logon). All SSOT-gated.
function Set-MiOSRemoteAccessOffline {
    param([string]$Mount, [string]$ScriptsDst, $Toml, [string]$WorkRoot)
    if ((Get-Toml $Toml 'autounattend.remote.enable' 'true') -notmatch '^(?i:true|1|yes)$') {
        Write-Host "[*] Remote-access bake disabled (SSOT autounattend.remote.enable=false)." -ForegroundColor DarkGray; return
    }
    Write-Host "[*] Baking the MiOS remote-access + virt-integration plane (RDP/enhanced-session/SSH/virtio) ..." -ForegroundColor Cyan
    $doSsh  = (Get-Toml $Toml 'autounattend.remote.openssh_server' 'true')    -match '^(?i:true|1|yes)$'

    # ---- (A) OFFLINE SYSTEM hive: RDP listener + NLA + service autostart ----------
    $sys = Join-Path $Mount 'Windows\System32\config\SYSTEM'
    $nla = if ((Get-Toml $Toml 'autounattend.remote.rdp_nla' 'true') -match '^(?i:true|1|yes)$') { 1 } else { 0 }
    & reg.exe load 'HKLM\MIOS_RSYS' $sys | Out-Null
    try {
        & reg.exe add 'HKLM\MIOS_RSYS\ControlSet001\Control\Terminal Server' /v fDenyTSConnections /t REG_DWORD /d 0 /f | Out-Null
        & reg.exe add 'HKLM\MIOS_RSYS\ControlSet001\Control\Terminal Server\WinStations\RDP-Tcp' /v UserAuthentication /t REG_DWORD /d $nla /f | Out-Null
        & reg.exe add 'HKLM\MIOS_RSYS\ControlSet001\Services\TermService' /v Start /t REG_DWORD /d 2 /f | Out-Null
        if ($doSsh) { foreach ($svc in 'sshd','ssh-agent') { & reg.exe add "HKLM\MIOS_RSYS\ControlSet001\Services\$svc" /v Start /t REG_DWORD /d 2 /f 2>&1 | Out-Null } }
        Write-Host "    RDP listener on (NLA=$nla), TermService/sshd autostart -> offline SYSTEM hive" -ForegroundColor DarkGray
    } finally { [gc]::Collect(); & reg.exe unload 'HKLM\MIOS_RSYS' | Out-Null }

    $sw = Join-Path $Mount 'Windows\System32\config\SOFTWARE'
    if (Test-Path $sw) {
        & reg.exe load 'HKLM\MIOS_RSW' $sw 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            try {
                & reg.exe add 'HKLM\MIOS_RSW\Microsoft\Windows NT\CurrentVersion\Guest\EnhancedSessionMode' /v EnhancedSessionModeAllowed /t REG_DWORD /d 1 /f 2>&1 | Out-Null
                Write-Host "    Hyper-V Enhanced Session Mode enabled -> offline SOFTWARE hive" -ForegroundColor DarkGray
            } finally { [gc]::Collect(); & reg.exe unload 'HKLM\MIOS_RSW' 2>&1 | Out-Null }
        }
    }

    # ---- (B1) OFFLINE OpenSSH.Server capability (non-fatal; online fallback in cmd) --
    if ($doSsh) {
        try {
            $cap = @(Get-WindowsCapability -Path $Mount -ErrorAction Stop | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1)
            if ($cap -and $cap.State -ne 'Installed') {
                Add-WindowsCapability -Path $Mount -Name $cap.Name -ErrorAction Stop | Out-Null
                Write-Host "    +capability $($cap.Name) (offline)" -ForegroundColor DarkGray
            } elseif ($cap) { Write-Host "    OpenSSH.Server already present in image" -ForegroundColor DarkGray }
        } catch { Write-Host "    OpenSSH.Server offline add skipped ($($_.Exception.Message.Split([Environment]::NewLine)[0])) -- online fallback in mios-remote.cmd" -ForegroundColor Yellow }
    }

    # ---- (B2) OFFLINE virtio-win guest drivers (KVM/QEMU/libvirt portability) -------
    if ((Get-Toml $Toml 'autounattend.remote.bake_virtio' 'true') -match '^(?i:true|1|yes)$') {
        $viso = $null
        try {
            $vurl = Get-Toml $Toml 'autounattend.remote.virtio_url' ''
            # LATEST/BETA build (NOT stable-virtio): it carries the ivshmem device driver +
            # newer components that Looking Glass needs on the Windows guest for the low-
            # latency KVMFR framebuffer relay. SSOT-overridable via [autounattend.remote].virtio_url.
            if (-not $vurl) { $vurl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso' }
            $variant = Get-Toml $Toml 'autounattend.remote.virtio_variant' 'w11'
            $cache = Join-Path $WorkRoot 'virtio'; New-Item -ItemType Directory -Force -Path $cache | Out-Null
            $viso = Join-Path $cache 'virtio-win.iso'
            # Fetch + VERIFY + mount, with a corrupt-cache retry loop. A partial/aborted
            # download or an HTML error page passes a naive size check but fails Mount-
            # DiskImage ("corrupted and unreadable") -- so verify the ISO9660 'CD001'
            # signature (offset 0x8001) after each download and re-fetch a bad file BEFORE
            # mounting, up to 4 attempts (the flash saw TWO corrupt downloads in a row --
            # the old loop only re-fetched on MOUNT failure, never integrity-checking the
            # download itself). virtio-win.iso is ~700 MB, so <200 MB is definitely partial.
            function Test-MiOSIsoValid([string]$p) {
                if (-not (Test-Path $p) -or (Get-Item $p).Length -lt 200MB) { return $false }
                try { $fs = [IO.File]::OpenRead($p); try { [void]$fs.Seek(0x8001, 'Begin'); $b = New-Object byte[] 5; [void]$fs.Read($b, 0, 5); return ([Text.Encoding]::ASCII.GetString($b) -eq 'CD001') } finally { $fs.Close() } } catch { return $false }
            }
            # BROWSER-ASSISTED fetch (Anubis-safe). fedorapeople.org is behind an Anubis proof-of-work
            # bot-wall that curl/IWR cannot pass, but a real browser solves it. If the cache is empty
            # and we're allowed, open the download in the browser and PAUSE here until the full signed
            # ISO lands + is transported to $viso -- then the loop below finds it cached and skips the
            # (doomed) CLI download. Gate: [autounattend.remote].virtio_browser_fetch = auto|true|false
            # ('auto' = do it when a user session is present). Set to 'false' for a truly headless CI.
            $vbf = Get-Toml $Toml 'autounattend.remote.virtio_browser_fetch' 'auto'
            if ((-not (Test-MiOSIsoValid $viso)) -and (($vbf -match '^(?i:true|1|yes|on)$') -or (($vbf -match '^(?i:auto)$') -and [Environment]::UserInteractive))) {
                $vHelper = Join-Path $PSScriptRoot 'Get-MiOSVirtio.ps1'
                if (Test-Path $vHelper) {
                    Write-Host "    virtio-win.iso not cached -- launching browser-assisted download (Anubis-safe); the build PAUSES until it lands ..." -ForegroundColor Cyan
                    try { & $vHelper -Dest $viso -Url $vurl -TimeoutMin 25 } catch { Write-Host "    browser-fetch helper error: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow }
                }
            }
            # Robust fetch. The old Invoke-WebRequest path was saving an HTML redirect/error page
            # (or a partial of the ~700 MB file) as 'virtio-win.iso' -> ISO9660 check failed every
            # attempt. curl.exe -f NEVER writes an HTTP-error body to the file, -L follows the
            # latest-virtio symlink redirect, and --retry rides transient mid-download drops. First
            # two attempts use the requested (latest) URL; the rest fall back to the stable-virtio
            # mirror, which is a real file (no symlink) -- so a flaky 'latest' can't fail the build.
            $vfallback = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'
            $vurls = @($vurl); if ($vurl -notlike '*stable-virtio*') { $vurls += $vfallback }
            $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
            $vm = $null
            for ($try = 0; $try -lt 5 -and -not $vm; $try++) {
                if (-not (Test-MiOSIsoValid $viso)) {
                    $u = if ($try -lt 2 -or $vurls.Count -lt 2) { $vurls[0] } else { $vurls[1] }
                    Write-Host "    fetching virtio-win.iso (attempt $($try + 1)/5) from $u ..." -ForegroundColor DarkGray
                    Remove-Item $viso -Force -ErrorAction SilentlyContinue
                    if (Test-Path $curlExe) {
                        & $curlExe -fL --retry 4 --retry-delay 5 --connect-timeout 30 -A 'Mozilla/5.0 (MiOS-Cat)' -o $viso $u 2>$null
                    } else {
                        $op = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri $u -OutFile $viso -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0 (MiOS-Cat)' } -MaximumRedirection 6 -ErrorAction Stop } catch {}
                        $ProgressPreference = $op
                    }
                    if (-not (Test-MiOSIsoValid $viso)) { Write-Host "    download failed the ISO9660 integrity check (partial/HTML) -- retrying$(if ($try + 1 -eq 2 -and $vurls.Count -gt 1) { ' (next: stable-virtio mirror)' } else { '' })" -ForegroundColor Yellow; continue }
                }
                try { $vm = Mount-DiskImage -ImagePath $viso -PassThru -ErrorAction Stop }
                catch {
                    Write-Host "    verified ISO still unmountable ($($_.Exception.Message.Split([Environment]::NewLine)[0].Trim())) -- deleting + re-fetching" -ForegroundColor Yellow
                    Remove-Item $viso -Force -ErrorAction SilentlyContinue
                }
            }
            if (-not $vm) { throw "virtio-win.iso could not be obtained (valid + mountable) after 5 attempts (latest + stable-virtio)" }
            $vl = ($vm | Get-Volume).DriveLetter + ':\'
            $inf = @(Get-ChildItem -Path $vl -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "\\$variant\\amd64\\" })
            if (-not $inf.Count) { $inf = @(Get-ChildItem -Path $vl -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\amd64\\' }) }
            Write-Host "    injecting $($inf.Count) virtio driver package(s) offline ($variant/amd64) ..." -ForegroundColor DarkGray
            foreach ($d in $inf) { try { Add-WindowsDriver -Path $Mount -Driver $d.FullName -ForceUnsigned -ErrorAction Stop | Out-Null } catch {} }
            # DON'T SKIP: also EMBED the full virtio-win.iso into the installed image so the
            # guest can (re)install the ivshmem + Looking Glass host drivers on demand -- the
            # LG-drivers ISO ships INSIDE MiOS-Xbox (at C:\MiOS\drivers) regardless of the
            # offline injection above. MiOS-XBOX-Hydrate can mount it to install LG host.
            $vembed = Join-Path $Mount 'MiOS\drivers'; New-Item -ItemType Directory -Force -Path $vembed | Out-Null
            Copy-Item -LiteralPath $viso -Destination (Join-Path $vembed 'virtio-win.iso') -Force
            Write-Host "    embedded virtio-win.iso -> image \MiOS\drivers (guest-side ivshmem / Looking-Glass install source)" -ForegroundColor Green
        } catch {
            # NON-FATAL (changed 2026-07-19): a failed OPTIONAL virtio download must NOT discard the
            # whole hard-built MiOS-Xbox image. The canonical source (fedorapeople.org) is now behind
            # an Anubis proof-of-work bot-wall that curl/Invoke-WebRequest cannot pass, so the ISO
            # would never build. virtio drivers only matter for KVM/QEMU guests + Looking-Glass
            # ivshmem; a bare-metal / Ventoy / Hyper-V MiOS-Xbox works without them. Warn loudly and
            # keep going. To bake virtio: browser-download virtio-win.iso (a browser passes Anubis)
            # and drop it at the path below, or point [autounattend.remote].virtio_url at a reachable
            # ISO, then rebuild -- the cached-file check reuses it and skips the download.
            Write-Host "    [!] virtio bake SKIPPED ($($_.Exception.Message.Split([Environment]::NewLine)[0]))" -ForegroundColor Yellow
            Write-Host "        fedorapeople.org is now behind an Anubis bot-wall -- no download tool can fetch virtio-win.iso automatically." -ForegroundColor Yellow
            Write-Host "        The MiOS-Xbox ISO WILL still build (virtio only matters for KVM/QEMU guests + Looking-Glass ivshmem)." -ForegroundColor Yellow
            Write-Host "        To include virtio: download virtio-win.iso in a browser and place it at:" -ForegroundColor Yellow
            Write-Host "          $viso" -ForegroundColor Cyan
            Write-Host "        (or set [autounattend.remote].virtio_url to a reachable ISO / local path), then rebuild." -ForegroundColor Yellow
        }
        finally { if ($viso) { try { Dismount-DiskImage -ImagePath $viso -ErrorAction SilentlyContinue | Out-Null } catch {} } }
    }

    # ---- (C) render mios-remote.cmd (runtime: RDU membership + fw + WinRM + loopback) --
    # Accounts resolve EXACTLY like New-MiOSAutounattendXml: [[accounts]] else [identity].
    $accounts = @($Toml.accounts)
    if ($accounts.Count -eq 0) { $accounts = @(@{ name = (Get-Toml $Toml 'identity.username' 'mios') }) }
    $users = @($accounts | ForEach-Object { "$($_.name)".Trim() } | Where-Object { $_ })
    $doSsh      = (Get-Toml $Toml 'autounattend.remote.openssh_server' 'true')  -match '^(?i:true|1|yes)$'
    $grantUsers = (Get-Toml $Toml 'autounattend.remote.grant_rdp_users' 'true')   -match '^(?i:true|1|yes)$'
    $doPsr      = (Get-Toml $Toml 'autounattend.remote.enable_psremoting' 'true') -match '^(?i:true|1|yes)$'
    $doLoop     = (Get-Toml $Toml 'autounattend.remote.loopback_adapter' 'false') -match '^(?i:true|1|yes)$'
    $r = @('@echo off', 'set "L=%WINDIR%\Temp\mios-remote.log"', 'echo [MiOS] remote-access apply %DATE% %TIME%>>"%L%"')
    $r += 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f>>"%L%" 2>&1'
    $r += 'reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Guest\EnhancedSessionMode" /v EnhancedSessionModeAllowed /t REG_DWORD /d 1 /f>>"%L%" 2>&1'
    $r += 'netsh advfirewall firewall set rule group="remote desktop" new enable=Yes>>"%L%" 2>&1'
    if ($grantUsers) {
        foreach ($u in $users) {
            $r += ('net localgroup "Remote Desktop Users" "{0}" /add>>"%L%" 2>&1' -f $u)
            $r += ('powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-LocalGroupMember -Group ''Remote Desktop Users'' -Member ''{0}'' -ErrorAction SilentlyContinue">>"%L%" 2>&1' -f $u)
        }
        $r += 'echo [MiOS] granted enhanced-session sign-in to: ' + ($users -join ', ') + '>>"%L%"'
    }
    if ($doSsh) {
        $r += 'dism /online /enable-feature /featurename:OpenSSH-Server-Package-Client /all /norestart>>"%L%" 2>&1'
        $r += 'powershell -NoProfile -ExecutionPolicy Bypass -Command "if ((Get-WindowsCapability -Online -Name ''OpenSSH.Server*'').State -ne ''Installed''){ try { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop } catch {} }">>"%L%" 2>&1'
        $r += 'reg add "HKLM\SOFTWARE\OpenSSH" /v DefaultShell /t REG_SZ /d "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" /f>>"%L%" 2>&1'
        $r += 'sc config sshd start= auto>>"%L%" 2>&1'
        $r += 'sc config ssh-agent start= auto>>"%L%" 2>&1'
        $r += 'net start sshd>>"%L%" 2>&1'
        $r += 'powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Service -Name sshd -StartupType Automatic -Status Running -ErrorAction SilentlyContinue">>"%L%" 2>&1'
        $r += 'netsh advfirewall firewall add rule name="OpenSSH Server (sshd)" dir=in action=allow protocol=TCP localport=22>>"%L%" 2>&1'
    }
    if ($doPsr) { $r += 'powershell -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck">>"%L%" 2>&1' }
    if ($doLoop) { $r += 'powershell -NoProfile -ExecutionPolicy Bypass -Command "pnputil /add-driver $env:WINDIR\INF\netloop.inf /install">>"%L%" 2>&1' }
    $r += 'echo [MiOS] remote-access done %DATE% %TIME%>>"%L%"'
    $r += 'exit /b 0'
    [IO.File]::WriteAllText((Join-Path $ScriptsDst 'mios-remote.cmd'), (($r -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    Write-Host "    rendered mios-remote.cmd ($($users.Count) desktop acct(s) -> Remote Desktop Users; SSH=$doSsh PSR=$doPsr Loopback=$doLoop) -> beside SetupComplete" -ForegroundColor Green
}

# STAGE-1 provisioning WIRING: render mios-provision.cmd from SSOT beside SetupComplete.
# SetupComplete `call`s it (as SYSTEM, pre-first-logon) to (1) register the reboot-
# surviving MiOS-Setup-Driver MINUTE task (MiOS-Provision.ps1, run as the RID-500 admin),
# (2) re-arm interactive AUTO-LOGON so the full-screen progress bar returns across the
# WSL/podman reboots (the driver clears the count at 100%), (3) arm the bar
# (MiOS-SetupExperience.ps1) at every interactive logon (it self-removes at 100%), and
# (4) kick the driver immediately so provisioning starts pre-logon in Session 0. The svc
# user/password are passed in by SetupComplete (%1/%2 = the LIVE creds it just set on the
# RID-500 account) with the SSOT-rendered values as standalone fallbacks. Gated on
# autounattend.provision.enable; degrade-open (skips cleanly if the driver isn't baked).
function Set-MiOSProvisionWiring {
    param([string]$Mount, [string]$ScriptsDst, $Toml)
    if ((Get-Toml $Toml 'autounattend.provision.enable' 'true') -notmatch '^(?i:true|1|yes)$') {
        Write-Host "[*] Stage-1 provision wiring disabled (SSOT autounattend.provision.enable=false)." -ForegroundColor DarkGray; return
    }
    $svcUser = Get-Toml $Toml 'autounattend.service.svc_user' 'mios-sudo'
    $svcPass = Get-Toml $Toml 'autounattend.service.svc_password' (Get-Toml $Toml 'identity.default_password' 'user')
    $accts   = Get-MiOSAccounts -Toml $Toml
    $desk    = @($accts)[0]
    $deskUser = [string]$desk.name
    $deskPw   = [string]$desk.password
    $count    = [int](Get-Toml $Toml 'autounattend.provision.autologon_count' '6')

    $WL  = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $RUN = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $barTr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File %MIOSPD%\MiOS-SetupExperience.ps1'
    $drvTr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File %MIOSPD%\MiOS-Provision.ps1'

    $p = New-Object System.Collections.Generic.List[string]
    $p.Add('@echo off')
    $p.Add('rem ============================================================================')
    $p.Add('rem  MiOS-Xbox STAGE-1 provisioning wiring  (RENDERED from SSOT by New-MiOSISO.ps1)')
    $p.Add('rem  Called by SetupComplete.cmd as SYSTEM, pre-first-logon. Registers the reboot-')
    $p.Add('rem  surviving provision DRIVER (MiOS-Provision.ps1) + the full-screen progress bar')
    $p.Add('rem  (MiOS-SetupExperience.ps1), and re-arms interactive auto-logon so the bar')
    $p.Add('rem  returns across the WSL/podman reboots and the desktop is withheld until 100%.')
    $p.Add('rem  Args: %1 = service account, %2 = service password (LIVE creds from SetupComplete);')
    $p.Add('rem  both fall back to the SSOT-rendered defaults below when not supplied.')
    $p.Add('rem ============================================================================')
    $p.Add('set "LOG=%WINDIR%\Temp\mios-setupcomplete.log"')
    $p.Add('set "MIOSPD=%ProgramData%\MiOS"')
    $p.Add('set "SVCUSER=%~1"')
    $p.Add('set "SVCPW=%~2"')
    $p.Add(('if "%SVCUSER%"=="" set "SVCUSER={0}"' -f $svcUser))
    $p.Add(('if "%SVCPW%"=="" set "SVCPW={0}"' -f $svcPass))
    $p.Add('if not exist "%MIOSPD%\MiOS-Provision.ps1" ( echo [MiOS] Stage-1 provision driver not baked -- wiring skipped>>"%LOG%" ^& goto :eof )')
    $p.Add('rem --- reboot-surviving DRIVER: MINUTE task as the RID-500 admin, HIGHEST ---------')
    $p.Add(('schtasks /create /tn "MiOS-Setup-Driver" /sc MINUTE /mo 1 /rl HIGHEST /ru "%SVCUSER%" /rp "%SVCPW%" /tr "{0}" /f>>"%LOG%" 2>&1' -f $drvTr))
    $p.Add('rem --- re-arm interactive AUTO-LOGON so the full-screen bar returns each boot -------')
    $p.Add('rem     (the driver clears AutoLogonCount when provisioning hits 100%). On Win11 26xxx')
    $p.Add('rem     -- the MiOS-Xbox target -- FirstLogonCommands (incl. the temp-password expire)')
    $p.Add('rem     are skipped, so this survives every provisioning reboot.')
    $p.Add(('reg add "{0}" /v AutoAdminLogon /t REG_SZ /d 1 /f>>"%LOG%" 2>&1' -f $WL))
    $p.Add(('reg add "{0}" /v DefaultUserName /t REG_SZ /d "{1}" /f>>"%LOG%" 2>&1' -f $WL, $deskUser))
    $p.Add(('reg add "{0}" /v DefaultDomainName /t REG_SZ /d "." /f>>"%LOG%" 2>&1' -f $WL))
    $p.Add(('reg add "{0}" /v DefaultPassword /t REG_SZ /d "{1}" /f>>"%LOG%" 2>&1' -f $WL, $deskPw))
    $p.Add(('reg add "{0}" /v AutoLogonCount /t REG_DWORD /d {1} /f>>"%LOG%" 2>&1' -f $WL, $count))
    $p.Add('rem --- arm the FULL-SCREEN progress bar at every interactive logon (self-removes at 100%) --')
    $p.Add(('reg add "{0}" /v "MiOS-SetupExperience" /t REG_SZ /d "{1}" /f>>"%LOG%" 2>&1' -f $RUN, $barTr))
    $p.Add('rem --- start provisioning NOW (pre-logon, Session 0) so the bar has progress to show --')
    $p.Add('schtasks /run /tn "MiOS-Setup-Driver">>"%LOG%" 2>&1')
    $p.Add('echo [MiOS] Stage-1 provision wiring armed (driver + full-screen bar + auto-logon re-arm)>>"%LOG%"')
    $p.Add('exit /b 0')

    [IO.File]::WriteAllText((Join-Path $ScriptsDst 'mios-provision.cmd'), (($p -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    Write-Host "    rendered mios-provision.cmd (driver task + full-screen bar + auto-logon re-arm; svc=$svcUser desktop=$deskUser count=$count) -> beside SetupComplete" -ForegroundColor Green
}

# Offline-service sources\install.wim: features + appx + Xbox reg, then export/trim.
function Invoke-MiOSImageServicing {
    param([string]$MediaRoot, $Toml, [object]$Removals, [switch]$BuiltNative)
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
        & dism.exe /Export-Image /SourceImageFile:"$esd" /SourceIndex:"$($ei.ImageIndex)" /DestinationImageFile:"$wim" /Compress:max | Out-Null
        Remove-Item $esd -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem $wim | ForEach-Object { $_.IsReadOnly = $false }
    $idx = (Get-WindowsImage -ImagePath $wim | Where-Object { $_.ImageName -match 'Pro' } | Select-Object -First 1).ImageIndex
    if (-not $idx) { $idx = (Get-WindowsImage -ImagePath $wim | Select-Object -First 1).ImageIndex }
    $mount = Join-Path (Split-Path $MediaRoot) 'mount'
    # Robustly clear ANY stale WIM mount that could block a fresh mount. A prior interrupted or
    # KILLED build can leave THIS wim mounted (with open file handles, or at our dir) -- so a plain
    # path-discard fails "already mounted for read/write" / "could not be completely unmounted".
    # Dismount EVERY mount whose ImagePath is this wim (or MountPath is our dir), run native
    # `dism /cleanup-wim`, clear corrupt mount points, and retry until nothing of this wim remains.
    # All non-fatal.
    for ($mAttempt = 1; $mAttempt -le 5; $mAttempt++) {
        foreach ($m in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)) {
            if ($m.ImagePath -eq $wim -or $m.MountPath -eq $mount -or $m.MountPath -like '*MountUUP*' -or $m.MountPath -like '*mount*') {
                try { Dismount-WindowsImage -Path $m.MountPath -Discard -ErrorAction Stop | Out-Null }
                catch {
                    try { & dism.exe /Unmount-Image /MountDir:"$($m.MountPath.TrimEnd('\'))" /Discard 2>&1 | Out-Null } catch {}
                }
            }
        }
        if (Test-Path "M:\MountUUP") { try { Dismount-WindowsImage -Path "M:\MountUUP" -Discard -ErrorAction SilentlyContinue | Out-Null } catch {} }
        if (Test-Path $mount) { try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null } catch {} }
        try { & dism.exe /Unmount-Image /MountDir:"$($mount.TrimEnd('\'))" /Discard 2>&1 | Out-Null } catch {}
        try { & dism.exe /Cleanup-Mountpoints 2>&1 | Out-Null } catch {}
        try { & dism.exe /Cleanup-Wim 2>&1 | Out-Null } catch {}
        try { Clear-WindowsCorruptMountPoint -ErrorAction SilentlyContinue | Out-Null } catch {}
        if (Test-Path $mount) {
            try { Remove-Item $mount -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            try { & cmd.exe /c "rd /s /q `"$mount`"" 2>&1 | Out-Null } catch {}
        }
        $staleLeft = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.ImagePath -eq $wim -or $_.MountPath -eq $mount -or $_.MountPath -like '*MountUUP*' })
        if ($staleLeft.Count -eq 0 -and (-not (Test-Path $mount) -or (Get-ChildItem $mount -ErrorAction SilentlyContinue).Count -eq 0)) { break }
        Start-Sleep -Seconds 2
    }
    if (Test-Path $mount) {
        if ((Get-ChildItem $mount -ErrorAction SilentlyContinue).Count -gt 0) {
            $mount = "M:\MountUUP_$([guid]::NewGuid().ToString().Substring(0,8))"
        }
    }
    New-Item -ItemType Directory -Force -Path $mount | Out-Null
    Write-Host "[*] Mounting install image index $idx to $mount ..." -ForegroundColor Cyan
    Mount-WindowsImage -Path $mount -ImagePath $wim -Index $idx | Out-Null
    $_serviced = $false
    try {
        # Remove the merged preset's FoD capabilities (offline).
        if ($Removals.Capabilities.Count) {
            $present = @(Get-WindowsCapability -Path $mount | Where-Object State -eq 'Installed' | Select-Object -Expand Name)
            $todo = @($Removals.Capabilities | Where-Object { $present -contains $_ })
            Write-Host "[*] Removing $($todo.Count) capabilities (of $($Removals.Capabilities.Count) targeted, $($present.Count) installed) ..." -ForegroundColor Cyan
            foreach ($cap in $todo) { try { Remove-WindowsCapability -Path $mount -Name $cap -ErrorAction SilentlyContinue | Out-Null } catch {} }
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
        # Remove the merged preset's provisioned appx OFFLINE -- the gaming-minimal
        # debloat (Solitaire, Teams, Outlook, Clipchamp, Bing, ...). Match the preset
        # <c> appx tokens against the image's own provisioned packages by DisplayName
        # (case-insensitive exact); Xbox/gaming/Store/framework appx are excluded via
        # the protect-list, and non-appx tokens simply don't match. This bakes DISM's
        # real Remove-AppxProvisionedPackage into install.wim -- no first-boot script.
        if ($Removals.Appx.Count) {
            $prov = @(Get-AppxProvisionedPackage -Path $mount)
            $rmset = @{}; foreach ($t in $Removals.Appx) { $rmset["$t".ToLower()] = $true }
            $todo = @($prov | Where-Object { $rmset.ContainsKey("$($_.DisplayName)".ToLower()) })
            Write-Host "[*] Removing $($todo.Count) provisioned appx (of $($prov.Count) in image; $($Removals.Appx.Count) targeted) ..." -ForegroundColor Cyan
            foreach ($p in $todo) { try { Remove-AppxProvisionedPackage -Path $mount -PackageName $p.PackageName -ErrorAction Stop | Out-Null; Write-Host "    -appx $($p.DisplayName)" -ForegroundColor DarkGray } catch {} }
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
        # Bake a BROAD common DRIVER PACK so MiOS-Xbox boots + gets online on most hardware out of
        # the box: chipset (AMD Adrenalin / Intel), base GPU, and network (Realtek / Intel / Qualcomm
        # WiFi + LAN). SSOT [autounattend].bake_driver_packs (default yes) + driver_pack_dir (a folder
        # of .inf trees on MiOS-Repo\drivers, populated by the build/operator). Degrade-open: skips
        # cleanly when the dir is empty (MiOS-PE's portable driver installer covers the rest at run).
        if ((Get-Toml $Toml 'autounattend.bake_driver_packs' 'true') -match '^(?i:true|1|yes)$') {
            $dpDir = Get-Toml $Toml 'autounattend.driver_pack_dir' ''
            if (-not $dpDir) { $dpDir = Join-Path (Split-Path $MediaRoot) 'driverpacks' }
            $dpInf = @(if (Test-Path $dpDir) { Get-ChildItem -Path $dpDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue })
            if ($dpInf.Count -gt 0) {
                Write-Host "[*] Injecting $($dpInf.Count) common driver package(s) offline from $dpDir (chipset/GPU/network) ..." -ForegroundColor Cyan
                Add-WindowsDriver -Path $mount -Driver $dpDir -Recurse -ForceUnsigned -ErrorAction SilentlyContinue | Out-Null
                $bw = Join-Path $MediaRoot 'sources\boot.wim'
                if (Test-Path $bw) {
                    $bm = Join-Path (Split-Path $MediaRoot) 'dpbootmount'; New-Item -ItemType Directory -Force -Path $bm | Out-Null
                    try { Mount-WindowsImage -Path $bm -ImagePath $bw -Index 1 -ErrorAction Stop | Out-Null
                          Add-WindowsDriver -Path $bm -Driver $dpDir -Recurse -ForceUnsigned -ErrorAction SilentlyContinue | Out-Null
                          Dismount-WindowsImage -Path $bm -Save -ErrorAction SilentlyContinue | Out-Null }
                    catch { try { Dismount-WindowsImage -Path $bm -Discard -ErrorAction SilentlyContinue | Out-Null } catch {} }
                }
            } else {
                Write-Host "[*] Driver-pack bake ON but $dpDir is empty -- populate MiOS-Repo\drivers with chipset/GPU/NIC .inf trees (AMD/Intel chipset, base GPU, Realtek/Intel/Qualcomm net). MiOS-PE's driver installer covers the rest at runtime." -ForegroundColor DarkGray
            }
        }
        # Optionally bake THIS BUILD HOST's third-party drivers into the image
        # (SSOT [autounattend].bake_host_drivers, default yes -- user-defined).
        # Export-WindowsDriver -Online dumps the host DriverStore's OEM/3rd-party
        # .inf packages; Add-WindowsDriver injects them offline so the custom image
        # boots this hardware out of the box. One-time, at build. Non-fatal.
        if ($BuiltNative) {
            Write-Host "[*] Host drivers baked natively in the converter pass (AddDrivers) -- Stage-2 skip." -ForegroundColor DarkGray
        } elseif ((Get-Toml $Toml 'autounattend.bake_host_drivers' 'true') -match '^(?i:true|1|yes)$') {
            $drv = Join-Path (Split-Path $MediaRoot) 'hostdrivers'
            New-Item -ItemType Directory -Force -Path $drv | Out-Null
            try {
                Write-Host "[*] Exporting build-host drivers (Export-WindowsDriver -Online) ..." -ForegroundColor Cyan
                Export-WindowsDriver -Online -Destination $drv -ErrorAction Stop | Out-Null
                $inf = @(Get-ChildItem -Path $drv -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
                Write-Host "[*] Injecting $($inf.Count) host driver package(s) offline (Add-WindowsDriver) ..." -ForegroundColor Cyan
                Add-WindowsDriver -Path $mount -Driver $drv -Recurse -ForceUnsigned -ErrorAction SilentlyContinue | Out-Null

                # Also inject same host drivers into all indexes of boot.wim to fix USB keyboards/controllers during setup
                $bootWim = Join-Path $MediaRoot 'sources\boot.wim'
                if (Test-Path $bootWim) {
                    Write-Host "[*] Injecting host drivers into early-boot image boot.wim (USB device fix) ..." -ForegroundColor Cyan
                    Get-ChildItem $bootWim | ForEach-Object { $_.IsReadOnly = $false }
                    $bootImages = Get-WindowsImage -ImagePath $bootWim
                    $bootMount = Join-Path (Split-Path $MediaRoot) 'bootmount'
                    foreach ($img in $bootImages) {
                        $bIdx = $img.ImageIndex
                        Write-Host "    Mounting boot.wim index $bIdx ($($img.ImageName)) ..." -ForegroundColor Cyan
                        New-Item -ItemType Directory -Force -Path $bootMount -ErrorAction SilentlyContinue | Out-Null
                        Mount-WindowsImage -Path $bootMount -ImagePath $bootWim -Index $bIdx | Out-Null
                        try {
                            Add-WindowsDriver -Path $bootMount -Driver $drv -Recurse -ForceUnsigned -ErrorAction SilentlyContinue | Out-Null
                        } finally {
                            try { Dismount-WindowsImage -Path $bootMount -Save -ErrorAction Stop | Out-Null }
                            catch {
                                Write-Host "    [!] Dismount save failed, discarding changes for index $bIdx ($($_.Exception.Message.Split([Environment]::NewLine)[0]))" -ForegroundColor Yellow
                                try { Dismount-WindowsImage -Path $bootMount -Discard -ErrorAction SilentlyContinue | Out-Null } catch {}
                            }
                            try { Remove-Item $bootMount -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                        }
                    }
                }
            } catch { Write-Host "[!] Host-driver bake skipped: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow }
        } else { Write-Host "[*] Host-driver bake disabled (SSOT bake_host_drivers=false)." -ForegroundColor DarkGray }
        # Xbox FSE override into the image.
        Set-MiOSXboxOfflineReg -Mount $mount -Toml $Toml
        # Neutralize telemetry/AI/consumer-features/OneDrive (the debloat DISM can't
        # component-remove) via offline registry + service policy.
        Set-MiOSDebloatOffline -Mount $mount -Toml $Toml -PolicyPath (Join-Path $PSScriptRoot 'mios-debloat.json')
        # Stage the MiOS-Host boot payload into the image so the specialize-pass
        # ONSTART task (registered by the autounattend) finds it pre-logon.
        $hostDst = Join-Path $mount 'ProgramData\MiOS'
        New-Item -ItemType Directory -Force -Path $hostDst | Out-Null
        foreach ($stage in 'MiOS-Host.ps1','MiOS-XBOX-Hydrate.ps1','MiOS-Daemon.ps1','MiOS-FirstBoot.ps1','MiOS-AccountSync.ps1',
                            'MiOS-Progress.psm1','MiOS-Provision.ps1','MiOS-SetupExperience.ps1','write-mios-progress.sh') {
            $src = Join-Path $PSScriptRoot $stage
            if (Test-Path $src) { Copy-Item $src (Join-Path $hostDst $stage) -Force; Write-Host "    staged $stage -> image ProgramData\MiOS" -ForegroundColor DarkGray }
        }
        # Reliable first-logon brain + gaming trigger: bake MiOS-FirstBoot.cmd into the
        # All-Users Startup folder. It runs (hidden) in the desktop user's real session --
        # where WSL works + the bootstrap self-elevates SILENTLY (ConsentPromptBehaviorAdmin
        # =0) -- fire-and-forget, one-time, self-removing. This is what actually deploys the
        # brain, since the service-account scheduled tasks do not register/run reliably.
        $startDst = Join-Path $mount 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup'
        New-Item -ItemType Directory -Force -Path $startDst | Out-Null
        $fbSrc = Join-Path $PSScriptRoot 'MiOS-FirstBoot.cmd'
        if (Test-Path $fbSrc) { Copy-Item $fbSrc (Join-Path $startDst 'MiOS-FirstBoot.cmd') -Force; Write-Host "    baked MiOS-FirstBoot.cmd -> All-Users Startup (first-logon brain + gaming deploy)" -ForegroundColor Green }
        # AIO-01: EMBED the installer repo (mios-bootstrap) into the image so a clean deploy is
        # OFFLINE (self-contained USB/bare-metal ISO -- no GitHub dependency). MiOS-Host prefers
        # this local Get-MiOS.ps1 (see MiOS-Host.ps1). ~34 MB minus .git. SSOT-gated; robocopy
        # for reliable recursive copy + exclusions.
        if ((Get-Toml $Toml 'autounattend.embed_repo' 'true') -match '^(?i:true|1|yes)$') {
            $repoSrc = Split-Path (Split-Path $PSScriptRoot)          # ...\mios-bootstrap
            $repoDst = Join-Path $mount 'ProgramData\MiOS\repo\mios-bootstrap'
            if (Test-Path (Join-Path $repoSrc 'Get-MiOS.ps1')) {
                New-Item -ItemType Directory -Force -Path $repoDst | Out-Null
                & robocopy.exe $repoSrc $repoDst /E /XD .git .claude node_modules /XF *.iso /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
                $embN = @(Get-ChildItem $repoDst -Recurse -File -EA SilentlyContinue).Count
                Write-Host "    embedded mios-bootstrap repo ($embN files) -> image ProgramData\MiOS\repo (offline installer)" -ForegroundColor Green
            } else { Write-Host "    [!] mios-bootstrap repo not found at $repoSrc -- embed skipped (irm|iex fallback)" -ForegroundColor Yellow }
        }
        # STAGE-1 SEED BAKE: copy the BAKED-IN provisioning seed blobs (WSL rootfs +
        # OCI-archive [+ optional podman-machine]) into the image so the first-boot driver
        # (MiOS-Provision.ps1) loads them OFFLINE -- no download/build on the critical path.
        # SSOT-gated (autounattend.seed.enable) + GUARDED: absent seeds are tolerated (the
        # driver falls back to today's embedded Get-MiOS build path). Blobs are large, so
        # they are staged VERBATIM inside the image at ProgramData\MiOS\seed (NOT re-exported
        # twice) -- the Export-WindowsImage Max pass below still compresses them once.
        if ((Get-Toml $Toml 'autounattend.seed.enable' 'true') -match '^(?i:true|1|yes)$') {
            $seedSrc = Get-Toml $Toml 'autounattend.seed.source' ''
            $seedCandidates = @()
            if ($seedSrc) { $seedCandidates += $seedSrc }
            $seedCandidates += @(
                (Join-Path (Resolve-MiOSBuildRoot $Toml) 'MiOS\seed')
                (Join-Path (Split-Path $MediaRoot) 'seed')
                (Join-Path $PSScriptRoot 'seed')
                'M:\MiOS\seed'
            )
            $seedFrom = $seedCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
            $seedBlobs = @(
                (Get-Toml $Toml 'autounattend.seed.rootfs'         'mios-rootfs.tar')
                (Get-Toml $Toml 'autounattend.seed.oci_archive'    'mios-image.oci.tar')
                (Get-Toml $Toml 'autounattend.seed.podman_machine' 'podman-machine.tar')
            )
            if ($seedFrom) {
                $seedDst = Join-Path $mount 'ProgramData\MiOS\seed'
                New-Item -ItemType Directory -Force -Path $seedDst | Out-Null
                $staged = 0
                foreach ($blob in $seedBlobs) {
                    $bsrc = Join-Path $seedFrom $blob
                    if (Test-Path -LiteralPath $bsrc) {
                        Copy-Item -LiteralPath $bsrc (Join-Path $seedDst $blob) -Force
                        Write-Host ("    staged seed {0} ({1:N0} MB) -> image ProgramData\MiOS\seed" -f $blob, ((Get-Item $bsrc).Length/1MB)) -ForegroundColor Green
                        $staged++
                    }
                }
                if ($staged -eq 0) { Write-Host "    [!] seed dir '$seedFrom' has no known blobs -- Stage-1 falls back to embedded Get-MiOS build (degrade-open)." -ForegroundColor Yellow }
            } else {
                Write-Host "    [*] No seed dir found (autounattend.seed.source / build_root\MiOS\seed) -- Stage-1 provisioning falls back to embedded Get-MiOS build (degrade-open). Run Build-MiOSSeed.ps1 on MiOS-DEV to bake offline seeds." -ForegroundColor DarkGray
            }
        } else { Write-Host "    [*] Seed bake disabled (SSOT autounattend.seed.enable=false)." -ForegroundColor DarkGray }
        # Render the MiOS-Daemon config from SSOT so intervals/distro are tunable.
        $daemonCfg = [ordered]@{
            tick_seconds     = [int](Get-Toml $Toml 'autounattend.daemon.tick_seconds' '60')
            update_every_min = [int](Get-Toml $Toml 'autounattend.daemon.update_every_min' '30')
            auto_update      = ((Get-Toml $Toml 'autounattend.daemon.auto_update' 'true') -match '^(?i:true|1|yes)$')
            distro           = (Get-Toml $Toml 'autounattend.daemon.distro' 'MiOS')
        }
        $daemonCfg | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $hostDst 'mios-daemon.json') -Encoding utf8
        Write-Host "    rendered mios-daemon.json (SSOT) -> image ProgramData\MiOS" -ForegroundColor DarkGray
        # KEYSTONE: bake SetupComplete.cmd -> \Windows\Setup\Scripts\. Windows Setup runs
        # it as SYSTEM at the END of setup (after specialize, before first logon). This is
        # the RELIABLE first-boot trigger -- Win11 26xxx silently skips FirstLogonCommands/
        # RunOnce under our unattended OOBE, so WITHOUT this MiOS never deploys (no theme,
        # no install, no Xbox mode -- exactly what a bare boot showed). SetupComplete
        # debloats, drops the all-users Startup launcher + ONLOGON task, and runs the MiOS
        # bootstrap (irm|iex) at first interactive logon.
        $scriptsDst = Join-Path $mount 'Windows\Setup\Scripts'
        New-Item -ItemType Directory -Force -Path $scriptsDst | Out-Null
        $scSrc = Join-Path $PSScriptRoot 'SetupComplete.cmd'
        if (Test-Path $scSrc) {
            # RENDER (not copy) from SSOT: SetupComplete's pre-logon account-guard names the
            # MiOS AI svc account + its password. Substitute the __SVCUSER__/__SVCPW__ tokens
            # so the baked guard matches the specialize pass + mios-provision.cmd -- NO
            # hardcoded identity. svc_user = the renamed built-in Administrator (RID 500);
            # svc_password = the service cred, else [identity].default_password.
            $scSvcUser = Get-Toml $Toml 'autounattend.service.svc_user' 'mios-sudo'
            $scSvcPass = Get-Toml $Toml 'autounattend.service.svc_password' (Get-Toml $Toml 'identity.default_password' 'user')
            $scSvcDesc = Get-Toml $Toml 'autounattend.service.svc_description' 'MiOS AI -- the renamed built-in Administrator (RID 500)'
            $scText = [IO.File]::ReadAllText($scSrc).Replace('__SVCUSER__', $scSvcUser).Replace('__SVCPW__', $scSvcPass).Replace('__SVCDESC__', $scSvcDesc)
            [IO.File]::WriteAllText((Join-Path $scriptsDst 'SetupComplete.cmd'), $scText, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "    baked SetupComplete.cmd (svc=$scSvcUser, SSOT-derived) -> image \Windows\Setup\Scripts (SYSTEM first-boot trigger)" -ForegroundColor Green
        } else { Write-Host "[!] SetupComplete.cmd NOT found next to New-MiOSISO -- first-boot MiOS trigger MISSING!" -ForegroundColor Red }

        # STAGE-1: render mios-provision.cmd beside SetupComplete (driver task + full-screen
        # progress bar + auto-logon re-arm, all from SSOT). SetupComplete `call`s it pre-logon.
        Set-MiOSProvisionWiring -Mount $mount -ScriptsDst $scriptsDst -Toml $Toml

        # Bake the custom unattend settings as offline defaults
        Set-MiOSCustomDefaults -Mount $mount

        # Bake the ONLOGON fallback cmd next to SetupComplete. The specialize pass
        # (New-MiOSHostServiceCommands) registers a "MiOS-FirstLogon" task pointing here,
        # so identity + remote apply even if Windows Setup skips SetupComplete on 26xxx.
        $flSrc = Join-Path $PSScriptRoot 'mios-firstlogon.cmd'
        if (Test-Path $flSrc) {
            Copy-Item $flSrc (Join-Path $scriptsDst 'mios-firstlogon.cmd') -Force
            Write-Host "    baked mios-firstlogon.cmd -> image \Windows\Setup\Scripts (ONLOGON fallback)" -ForegroundColor Green
        }
        # Bake the batch-logon grant helper. The specialize pass runs it (as SYSTEM) right
        # after creating the svc account so the MiOS-Host/Daemon tasks can actually log on
        # + run as that account (the stored-password batch-logon failure that kept the brain
        # from ever deploying). MiOS-Provision itself runs as SYSTEM so it needs no grant.
        $gbSrc = Join-Path $PSScriptRoot 'mios-grant-batch.ps1'
        if (Test-Path $gbSrc) {
            Copy-Item $gbSrc (Join-Path $scriptsDst 'mios-grant-batch.ps1') -Force
            Write-Host "    baked mios-grant-batch.ps1 -> image \Windows\Setup\Scripts (SeBatchLogonRight grant)" -ForegroundColor Green
        }
        # The interactive first-logon launcher SetupComplete copies to the Startup folder.
        # Bake the MiOS FACTORY IDENTITY offline (palette/dark/wallpaper reg + Geist
        # font + Bibata cursor + OEM branding), all from SSOT, applied SILENTLY by
        # SetupComplete's Default-hive edit. (No interactive mios-firstboot launcher --
        # the deploy is pre-logon in Session 0; the identity is baked, not scripted.)
        Set-MiOSIdentityOffline -Mount $mount -ScriptsDst $scriptsDst -Toml $Toml
        # Bake the REMOTE-ACCESS + VIRT-INTEGRATION plane (RDP right for enhanced session,
        # OpenSSH, WinRM, virtio) so every deployment is reachable + host-integrated from
        # factory. Renders mios-remote.cmd beside SetupComplete (runtime RDU group-add) +
        # offline-bakes RDP-on / sshd-autostart / virtio drivers into the image.
        Set-MiOSRemoteAccessOffline -Mount $mount -ScriptsDst $scriptsDst -Toml $Toml -WorkRoot (Split-Path $MediaRoot)
        # SSOT appx-removal list SetupComplete reads (mios-remove-appx.txt beside it), from
        # the same preset removals -- a fallback strip for anything left provisioned.
        if ($Removals.Appx.Count) {
            Set-Content -LiteralPath (Join-Path $scriptsDst 'mios-remove-appx.txt') -Encoding ASCII -Value @($Removals.Appx | Sort-Object -Unique)
            Write-Host "    baked mios-remove-appx.txt ($($Removals.Appx.Count) tokens) beside SetupComplete.cmd" -ForegroundColor DarkGray
        }
        Write-Host "    Deep CBS component FILES can't be DISM-removed (of $($Removals.NtliteOnly) <c>; see dism-native-conversion-map.md) -- their telemetry/AI/consumer behaviour is killed by the offline debloat policy above." -ForegroundColor DarkGray
        # DISM research gap P1 (component-store cleanup): reclaim the WinSxS bloat the
        # offline appx/feature/capability removals above leave behind by compacting the
        # component store (StartComponentCleanup) while the image is still mounted, BEFORE
        # the Dismount -Save. On the non-native (-SourceIso) path the UUP converter did NO
        # ResetBase, so add /ResetBase to shrink the store to a fresh baseline (fine for a
        # FACTORY image -- see RISK note in the change record). On a native build the
        # converter already ran /ResetBase, so this is skipped (mirrors the Stage-2 Export
        # trim skip below). Runs against the mounted image with an explicit roomy local
        # /ScratchDir on the work volume. NON-FATAL: any failure warns + continues so a
        # cleanup hiccup can NEVER discard the fully-serviced image ($_serviced stays true).
        if ((Get-Toml $Toml 'autounattend.component_cleanup' 'true') -notmatch '^(?i:true|1|yes)$') {
            Write-Host "[*] Component-store cleanup disabled (SSOT autounattend.component_cleanup=false)." -ForegroundColor DarkGray
        } elseif ($BuiltNative) {
            Write-Host "[*] Component-store cleanup skipped -- native converter already ran /ResetBase." -ForegroundColor DarkGray
        } else {
            try {
                $dismScratch = Join-Path (Split-Path $MediaRoot) 'dismscratch'
                New-Item -ItemType Directory -Force -Path $dismScratch | Out-Null
                Write-Host "[*] Component-store cleanup (DISM /Cleanup-Image /StartComponentCleanup /ResetBase) ..." -ForegroundColor Cyan
                & dism.exe /Image:$mount /Cleanup-Image /StartComponentCleanup /ResetBase /ScratchDir:$dismScratch 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-Host "    WinSxS compacted + baseline reset (superseded updates now non-removable -- factory image)." -ForegroundColor Green }
                else { Write-Host "    [!] component cleanup returned exit $LASTEXITCODE -- continuing (serviced image kept)." -ForegroundColor Yellow }
            } catch { Write-Host "    [!] component cleanup skipped: $($_.Exception.Message.Split([Environment]::NewLine)[0]) -- continuing (serviced image kept)." -ForegroundColor Yellow }
        }
        $_serviced = $true   # reached only if every servicing step above succeeded
    } finally {
        # DISCARD on any error inside the try -- never COMMIT a half-serviced image
        # (the original bug: finally always -Save). The exception still propagates.
        if ($_serviced) {
            Write-Host "[*] Committing image (Dismount -Save) ..." -ForegroundColor Cyan
            $dismountSuccess = $false
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                try {
                    Set-Location -Path $PSScriptRoot -ErrorAction SilentlyContinue
                    & cmd.exe /c "for %h in (MIOS_CUR_SW MIOS_DEFT MIOS_SYS MIOS_SOFT MIOS_DEF MIOS_DEFU MIOS_RSYS MIOS_RSW MIOS_NTUSER pe-default pe-software) do reg unload HKLM\%h >nul 2>&1"
                    & cmd.exe /c "for %h in (MIOS_CUR_SW MIOS_DEFT MIOS_SYS MIOS_SOFT MIOS_DEF MIOS_DEFU MIOS_RSYS MIOS_RSW MIOS_NTUSER pe-default pe-software) do reg unload HKU\%h >nul 2>&1"
                    [System.GC]::Collect()
                    [System.GC]::WaitForPendingFinalizers()
                    Start-Sleep -Seconds 3

                    $mountClean = $mount.TrimEnd('\')
                    $activeMount = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path.TrimEnd('\') -eq $mountClean } | Select-Object -First 1
                    if (-not $activeMount) {
                        $activeMount = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*$mountClean*" } | Select-Object -First 1
                    }
                    $targetPath = if ($activeMount -and $activeMount.Path) { $activeMount.Path } else { $mountClean }
                    $targetClean = $targetPath.TrimEnd('\')
                    $mountClean = $targetPath.TrimEnd('\')

                    $dismArgs = @("/Unmount-Image", "/MountDir:$mountClean", "/Commit")
                    $dismOut = & dism.exe $dismArgs 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $dismountSuccess = $true
                        break
                    }
                    try {
                        Dismount-WindowsImage -Path $mountClean -Save -ErrorAction Stop | Out-Null
                        $dismountSuccess = $true
                        break
                    } catch {
                        throw "dism.exe /Unmount-Image failed (exit $LASTEXITCODE): $dismOut"
                    }
                } catch {
                    Write-Host "    [!] Dismount save failed (attempt $attempt/5): $($_.Exception.Message.Split([Environment]::NewLine)[0]). Retrying in 4 seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 4
                }
            }
            if (-not $dismountSuccess) {
                Write-Host "    [!] Force-discarding due to repeated dismount save failures..." -ForegroundColor Yellow
                $activeMount = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path.TrimEnd('\') -eq $mountClean } | Select-Object -First 1
                $discardPath = if ($activeMount -and $activeMount.Path) { $activeMount.Path } else { $mountClean }
                Dismount-WindowsImage -Path $discardPath -Discard -ErrorAction SilentlyContinue | Out-Null
                throw "Dismount commit save failed permanently."
            }
        } else {
            Write-Host "[!] Servicing failed -- discarding the half-serviced image." -ForegroundColor Yellow
            Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null
        }
    }
    $esdFile = Join-Path (Split-Path $wim) 'install.esd'
    Write-Host "[*] Exporting and compressing to install.esd (Recovery/LZMS compression) ..." -ForegroundColor Cyan
    # Prevent race condition: wait for OS dismount handles to release completely
    Start-Sleep -Seconds 5
    $dismScratch = Join-Path (Split-Path $MediaRoot) 'dismscratch'
    New-Item -ItemType Directory -Force -Path $dismScratch -ErrorAction SilentlyContinue | Out-Null
    $dismArgs = @("/Export-Image", "/SourceImageFile:$wim", "/SourceIndex:$idx", "/DestinationImageFile:$esdFile", "/Compress:recovery", "/ScratchDir:$dismScratch")
    & dism.exe $dismArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dism.exe /Export-Image failed with exit code $LASTEXITCODE. install.wim is intact."
    }
    Remove-Item $wim -Force -ErrorAction SilentlyContinue
}

# Assemble the bootable dual BIOS/UEFI ISO with oscdimg (UDF; no-prompt UEFI).
function Build-MiOSBootableIso {
    param([string]$MediaRoot, [string]$OutIso, [string]$Label)
    $oscdimg = Get-Oscdimg
    if (-not $oscdimg) { throw "oscdimg.exe not found. Install the Windows ADK 'Deployment Tools'. Media tree ready at '$MediaRoot' -- master it manually." }
    $bios = Join-Path $MediaRoot 'boot\etfsboot.com'
    if (-not (Test-Path $bios)) { throw "BIOS boot file not found: $bios (media tree incomplete / not a bootable Windows source)." }
    $uefi = Join-Path $MediaRoot 'efi\microsoft\boot\efisys_noprompt.bin'
    if (-not (Test-Path $uefi)) { $uefi = Join-Path $MediaRoot 'efi\microsoft\boot\efisys.bin' }
    if (-not (Test-Path $uefi)) { throw "UEFI boot file not found under $MediaRoot\efi\microsoft\boot\." }
    New-Item -ItemType Directory -Force -Path (Split-Path $OutIso) | Out-Null
    # -bootdata carries '#' -> must be ONE quoted token in PowerShell. -u2 = UDF
    # (install.wim exceeds ISO-9660's 4GB single-file cap). -l<label> no space.
    $bootdata = "-bootdata:2#p0,e,b$bios#pEF,e,b$uefi"
    Write-Host "[*] oscdimg -> $OutIso ..." -ForegroundColor Cyan
    # oscdimg writes ALL its progress to STDERR; under PowerShell `2>&1` PS 5.1 wraps
    # each line as a NativeCommandError (alarming red text in the transcript) even
    # though oscdimg SUCCEEDS and $LASTEXITCODE is 0. Run it through cmd.exe with
    # cmd-level redirection to a log so PowerShell sees ONLY the exit code -- no
    # spurious error record. Check the code; surface the log tail only on failure.
    $ocLog = "$OutIso.oscdimg.log"
    $cl = '"{0}" -m -o -u2 -udfver102 "-l{1}" {2} "{3}" "{4}" > "{5}" 2>&1' -f $oscdimg, $Label, $bootdata, $MediaRoot, $OutIso, $ocLog
    & cmd.exe /c $cl
    if ($LASTEXITCODE -ne 0) {
        Get-Content $ocLog -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        throw "oscdimg failed (exit $LASTEXITCODE) -- see $ocLog"
    }
    Get-Content $ocLog -Tail 2 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Remove-Item $ocLog -Force -ErrorAction SilentlyContinue
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
$toml   = Apply-MiosEdition -T $toml -Edition $Edition
$buildRoot = Resolve-MiOSBuildRoot $toml
if (-not $OutIso)  { $OutIso  = Get-Toml $toml 'autounattend.iso_out' (Join-Path $buildRoot 'iso\MiOS-Xbox.iso') }
$label = Get-Toml $toml 'autounattend.iso_label' 'MiOS-Xbox'
if (-not $WorkDir) { $WorkDir = Join-Path $buildRoot 'isobuild' }

# Stage 0 -- source ISO (fetch Dev-channel if not supplied). $fetched tells Stage-2
# whether the converter built minimal natively (only true when WE ran it, not -SourceIso).
$fetched = -not $SourceIso
if (-not $SourceIso) {
    # Ensure any stale UUP converter mount points (M:\MountUUP, C:\MountUUP) are cleanly dismounted
    # and DISM mount points are purged before uup-converter-wim.cmd attempts to mount.
    foreach ($mDir in @('M:\MountUUP','C:\MountUUP')) {
        if (Test-Path $mDir) {
            try { Dismount-WindowsImage -Path $mDir -Discard -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
    }
    foreach ($m in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)) {
        if ($m.MountPath -like '*MountUUP*') {
            try { Dismount-WindowsImage -Path $m.MountPath -Discard -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
    }
    try { & dism.exe /Cleanup-Mountpoints 2>&1 | Out-Null } catch {}
    try { & dism.exe /Cleanup-Wim 2>&1 | Out-Null } catch {}
    try { Clear-WindowsCorruptMountPoint -ErrorAction SilentlyContinue | Out-Null } catch {}

    Write-Host "[*] No -SourceIso passed; checking for pre-built ISO in UUP package catalog..." -ForegroundColor Cyan
    $candidateIso = $null
    foreach ($searchDir in @((Join-Path $buildRoot 'uup\package'), (Join-Path $buildRoot '..\uup\package'), 'M:\MiOS\uup\package', 'M:\uup\package')) {
        if (Test-Path $searchDir) {
            $found = Get-ChildItem -Path $searchDir -Filter '*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $candidateIso = $found.FullName; break }
        }
    }
    if ($candidateIso) {
        $SourceIso = $candidateIso
        Write-Host "[*] Found pre-built stock ISO: $SourceIso" -ForegroundColor Green
    } else {
        Write-Host "[*] Fetching stock ISO via mios-uup-fetch (channel from SSOT) ..." -ForegroundColor Cyan
        $SourceIso = & (Join-Path $PSScriptRoot 'mios-uup-fetch.ps1') -TomlPath $TomlPath -Esd:$Esd -Edition $Edition
    }
}
if (-not (Test-Path $SourceIso)) { throw "Source ISO not found: $SourceIso" }

# Stage 1 -- extract to a writable media tree. Use a PER-RUN subdir (run_<pid>) so the wim +
# mount paths are unique to THIS build: an orphaned/Invalid WIM mount left by a prior interrupted
# build (Status=Invalid, held by dead kernel handles -- only a REBOOT fully reclaims it) can then
# never block this build with "already mounted for read/write". Best-effort reap old run_* dirs
# (a still-wedged one just gets skipped).
Get-ChildItem $WorkDir -Directory -Filter 'run_*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "run_$PID" } | ForEach-Object { try { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
$media = Expand-MiOSIso -Iso $SourceIso -Dest (Join-Path $WorkDir "run_$PID\media")

# Stage 2 -- DISM offline servicing (features + appx + Xbox FSE into the image).
if (-not $SkipServicing) {
    $removals = Get-MiOSMergedRemovals -PresetPath $MergedPreset -Toml $toml
    # Native fast-path: the converter built minimal (keep-set + drivers) ONLY when we
    # fetched AND native_apps is on. With an external -SourceIso the image is stock, so
    # Stage-2 still strips + bakes. BuiltNative lets Stage-2 skip that redundant work.
    $builtNative = $fetched -and ((Get-Toml $toml 'autounattend.uup_convert.native_apps' 'true') -match '^(?i:true|1|yes)$')
    Invoke-MiOSImageServicing -MediaRoot $media -Toml $toml -Removals $removals -BuiltNative:$builtNative
} else { Write-Host "[*] -SkipServicing: image left stock." -ForegroundColor DarkGray }

# Stage 3 -- autounattend.xml (SSOT accounts + LabConfig WinPE bypass + FirstLogonCommands
# incl. Xbox reg + nested irm|iex) to the media root.
Write-Host "[*] Generating autounattend.xml (SSOT + Xbox FirstLogonCommands) ..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'New-MiOSAutounattend.ps1') -TomlPath $TomlPath -OutXml (Join-Path $media 'autounattend.xml') -Edition $Edition | Out-Null
Copy-Item (Join-Path $media 'autounattend.xml') (Join-Path $media 'sources\autounattend.xml') -Force -ErrorAction SilentlyContinue

# Stage 4 -- master the bootable ISO.
Build-MiOSBootableIso -MediaRoot $media -OutIso $OutIso -Label $label

Write-Host "[+] MiOS-XBOX ISO: $OutIso" -ForegroundColor Green
Write-Host "    DISM-serviced + Xbox FSE enabled; boot to install, FirstLogon runs MiOS bootstrap." -ForegroundColor DarkGray
return $OutIso
