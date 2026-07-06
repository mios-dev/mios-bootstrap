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
    $ids = @((Get-Toml $Toml 'autounattend.xbox.feature_ids' '59765208') -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })
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
    $hives = @(
        @{ h = 'MIOS_SW';  f = (Join-Path $Mount 'Windows\System32\config\SOFTWARE') }
        @{ h = 'MIOS_SYS'; f = (Join-Path $Mount 'Windows\System32\config\SYSTEM') }
        # NB: DO NOT offline-edit Users\Default\NTUSER.DAT here. Editing a USER hive
        # inside a mounted WIM corrupts it (the NTUSER.DAT.LOG transaction is not flushed
        # on dismount), so every profile created from Default fails to load -> "The User
        # Profile Service service failed the sign-in." The per-user debloat intent is
        # already covered by the machine-wide HKLM policies above + SetupComplete's LIVE
        # guest-side Default-hive edit (safe: real registry, proper transactions).
    )
    $ok = @{}
    foreach ($x in $hives) { if (Test-Path $x.f) { & reg.exe load "HKLM\$($x.h)" $x.f 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $ok[$x.h] = $true } } }
    $applied = 0
    try {
        $plan = @()
        if ($ok['MIOS_SW'])  { foreach ($e in @($pol.software))     { $plan += @{ h = 'MIOS_SW';  e = $e } } }
        if ($ok['MIOS_SYS']) { foreach ($e in @($pol.system))       { $plan += @{ h = 'MIOS_SYS'; e = $e } } }
        # (default_user intentionally NOT applied offline -- see the hive list above.)
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
    Write-Host "[*] Offline debloat applied ($applied policy ops): telemetry/AI/Copilot/consumer-features/OneDrive off + DiagTrack/dmwappushservice disabled." -ForegroundColor Cyan
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
        } else { Write-Host "    [!] Bibata: no cursor set found in archive (got $($allCur.Count) .cur/.ani files) -- cursor scheme skipped" -ForegroundColor Yellow }
    } catch { Write-Host "    [!] Bibata cursor stage skipped: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow }

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
            if (-not $vurl) { $vurl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso' }
            $variant = Get-Toml $Toml 'autounattend.remote.virtio_variant' 'w11'
            $cache = Join-Path $WorkRoot 'virtio'; New-Item -ItemType Directory -Force -Path $cache | Out-Null
            $viso = Join-Path $cache 'virtio-win.iso'
            # Fetch + mount with a corrupt-cache retry: a partial/aborted prior download
            # passes a naive size check but fails Mount-DiskImage ("corrupted and
            # unreadable"). On a mount failure, DELETE the bad cache and re-fetch ONCE
            # before giving up -- so a single network hiccup doesn't permanently poison
            # the cache. virtio-win.iso is ~700 MB, so a <200 MB file is definitely partial.
            $vm = $null
            for ($try = 0; $try -lt 2 -and -not $vm; $try++) {
                if (-not (Test-Path $viso) -or (Get-Item $viso).Length -lt 200MB) {
                    Write-Host "    fetching virtio-win.iso (one-time, cached under $cache) ..." -ForegroundColor DarkGray
                    $op = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri $vurl -OutFile $viso -UseBasicParsing -ErrorAction Stop
                    $ProgressPreference = $op
                }
                try { $vm = Mount-DiskImage -ImagePath $viso -PassThru -ErrorAction Stop }
                catch {
                    Write-Host "    cached virtio-win.iso unmountable ($($_.Exception.Message.Split([Environment]::NewLine)[0].Trim())) -- deleting + re-fetching" -ForegroundColor Yellow
                    Remove-Item $viso -Force -ErrorAction SilentlyContinue
                }
            }
            if (-not $vm) { throw "virtio-win.iso could not be mounted after re-fetch" }
            $vl = ($vm | Get-Volume).DriveLetter + ':\'
            $inf = @(Get-ChildItem -Path $vl -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "\\$variant\\amd64\\" })
            if (-not $inf.Count) { $inf = @(Get-ChildItem -Path $vl -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\amd64\\' }) }
            Write-Host "    injecting $($inf.Count) virtio driver package(s) offline ($variant/amd64) ..." -ForegroundColor DarkGray
            foreach ($d in $inf) { try { Add-WindowsDriver -Path $Mount -Driver $d.FullName -ForceUnsigned -ErrorAction Stop | Out-Null } catch {} }
        } catch { Write-Host "    virtio bake skipped ($($_.Exception.Message.Split([Environment]::NewLine)[0])) -- non-fatal" -ForegroundColor Yellow }
        finally { if ($viso) { try { Dismount-DiskImage -ImagePath $viso -ErrorAction SilentlyContinue | Out-Null } catch {} } }
    }

    # ---- (C) render mios-remote.cmd (runtime: RDU membership + fw + WinRM + loopback) --
    # Accounts resolve EXACTLY like New-MiOSAutounattendXml: [[accounts]] else [identity].
    $accounts = @($Toml.accounts)
    if ($accounts.Count -eq 0) { $accounts = @(@{ name = (Get-Toml $Toml 'identity.username' 'mios') }) }
    $users = @($accounts | ForEach-Object { "$($_.name)".Trim() } | Where-Object { $_ })
    $grantUsers = (Get-Toml $Toml 'autounattend.remote.grant_rdp_users' 'true')   -match '^(?i:true|1|yes)$'
    $doPsr      = (Get-Toml $Toml 'autounattend.remote.enable_psremoting' 'true') -match '^(?i:true|1|yes)$'
    $doLoop     = (Get-Toml $Toml 'autounattend.remote.loopback_adapter' 'false') -match '^(?i:true|1|yes)$'
    $r = @('@echo off', 'set "L=%WINDIR%\Temp\mios-remote.log"', 'echo [MiOS] remote-access apply %DATE% %TIME%>>"%L%"')
    $r += 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f>>"%L%" 2>&1'
    $r += 'netsh advfirewall firewall set rule group="remote desktop" new enable=Yes>>"%L%" 2>&1'
    if ($grantUsers) {
        foreach ($u in $users) { $r += ('net localgroup "Remote Desktop Users" "{0}" /add>>"%L%" 2>&1' -f $u) }
        $r += 'echo [MiOS] granted enhanced-session sign-in to: ' + ($users -join ', ') + '>>"%L%"'
    }
    if ($doSsh) {
        $r += 'powershell -NoProfile -ExecutionPolicy Bypass -Command "if ((Get-WindowsCapability -Online -Name ''OpenSSH.Server*'').State -ne ''Installed''){ Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 }">>"%L%" 2>&1'
        $r += 'sc config sshd start= auto>>"%L%" 2>&1'
        $r += 'sc config ssh-agent start= auto>>"%L%" 2>&1'
        $r += 'net start sshd>>"%L%" 2>&1'
        $r += 'netsh advfirewall firewall add rule name="OpenSSH Server (sshd)" dir=in action=allow protocol=TCP localport=22>>"%L%" 2>&1'
    }
    if ($doPsr) { $r += 'powershell -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck">>"%L%" 2>&1' }
    if ($doLoop) { $r += 'powershell -NoProfile -ExecutionPolicy Bypass -Command "pnputil /add-driver $env:WINDIR\INF\netloop.inf /install">>"%L%" 2>&1' }
    $r += 'echo [MiOS] remote-access done %DATE% %TIME%>>"%L%"'
    $r += 'exit /b 0'
    [IO.File]::WriteAllText((Join-Path $ScriptsDst 'mios-remote.cmd'), (($r -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    Write-Host "    rendered mios-remote.cmd ($($users.Count) desktop acct(s) -> Remote Desktop Users; SSH=$doSsh PSR=$doPsr Loopback=$doLoop) -> beside SetupComplete" -ForegroundColor Green
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
        Export-WindowsImage -SourceImagePath $esd -SourceIndex $ei.ImageIndex -DestinationImagePath $wim -CompressionType Max | Out-Null
        Remove-Item $esd -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem $wim | ForEach-Object { $_.IsReadOnly = $false }
    $idx = (Get-WindowsImage -ImagePath $wim | Where-Object { $_.ImageName -match 'Pro' } | Select-Object -First 1).ImageIndex
    if (-not $idx) { $idx = (Get-WindowsImage -ImagePath $wim | Select-Object -First 1).ImageIndex }
    $mount = Join-Path (Split-Path $MediaRoot) 'mount'
    # Robustly clear any stale/corrupt WIM mount from a prior interrupted run. A broken
    # mount makes Dismount-WindowsImage throw "The request is not supported" -- a native
    # DISM exception that -ErrorAction can't suppress -- which would otherwise wedge
    # EVERY future build. Discard the specific mount, force-clear corrupt mount points,
    # then recreate the dir. All non-fatal.
    if (Test-Path $mount) {
        try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
        catch { Write-Host "    stale mount at $mount ($($_.Exception.Message.Split([Environment]::NewLine)[0])) -- clearing" -ForegroundColor Yellow }
    }
    try { Clear-WindowsCorruptMountPoint -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { & dism.exe /Cleanup-Wim 2>&1 | Out-Null } catch {}
    if (Test-Path $mount) { try { Remove-Item $mount -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
    New-Item -ItemType Directory -Force -Path $mount | Out-Null
    Write-Host "[*] Mounting install image index $idx ..." -ForegroundColor Cyan
    Mount-WindowsImage -Path $mount -ImagePath $wim -Index $idx | Out-Null
    $_serviced = $false
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
        foreach ($stage in 'MiOS-Host.ps1','MiOS-XBOX-Hydrate.ps1','MiOS-Daemon.ps1') {
            $src = Join-Path $PSScriptRoot $stage
            if (Test-Path $src) { Copy-Item $src (Join-Path $hostDst $stage) -Force; Write-Host "    staged $stage -> image ProgramData\MiOS" -ForegroundColor DarkGray }
        }
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
            Copy-Item $scSrc (Join-Path $scriptsDst 'SetupComplete.cmd') -Force
            Write-Host "    baked SetupComplete.cmd -> image \Windows\Setup\Scripts (SYSTEM first-boot trigger)" -ForegroundColor Green
        } else { Write-Host "[!] SetupComplete.cmd NOT found next to New-MiOSISO -- first-boot MiOS trigger MISSING!" -ForegroundColor Red }
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
        $_serviced = $true   # reached only if every servicing step above succeeded
    } finally {
        # DISCARD on any error inside the try -- never COMMIT a half-serviced image
        # (the original bug: finally always -Save). The exception still propagates.
        if ($_serviced) {
            Write-Host "[*] Committing image (Dismount -Save) ..." -ForegroundColor Cyan
            Dismount-WindowsImage -Path $mount -Save | Out-Null
        } else {
            Write-Host "[!] Servicing failed -- discarding the half-serviced image." -ForegroundColor Yellow
            Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null
        }
    }
    # Trim servicing bloat: re-export Max to a new wim, swap in. On a slim native
    # build the converter's ResetBase already shrank the image and Stage-2 changed
    # little, so this second full re-archive (the big time sink) is skipped.
    $slim = $BuiltNative -and ((Get-Toml $Toml 'autounattend.uup_convert.slim_build' 'true') -match '^(?i:true|1|yes)$')
    if ($slim) {
        Write-Host "[*] Slim native build -- skipping the Stage-2 Export trim (converter ResetBase already shrank)." -ForegroundColor DarkGray
    } else {
        $trim = "$wim.trim"
        Write-Host "[*] Export-WindowsImage -CompressionType Max (trim) ..." -ForegroundColor Cyan
        Export-WindowsImage -SourceImagePath $wim -SourceIndex $idx -DestinationImagePath $trim -CompressionType Max | Out-Null
        Move-Item -LiteralPath $trim -Destination $wim -Force
    }
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
    $cl = '"{0}" -m -o -u2 -udfver102 "-l{1}" "{2}" "{3}" "{4}" > "{5}" 2>&1' -f $oscdimg, $Label, $bootdata, $MediaRoot, $OutIso, $ocLog
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
$buildRoot = Resolve-MiOSBuildRoot $toml
if (-not $OutIso)  { $OutIso  = Get-Toml $toml 'autounattend.iso_out' (Join-Path $buildRoot 'iso\MiOS-Xbox.iso') }
$label = Get-Toml $toml 'autounattend.iso_label' 'MiOS-Xbox'
if (-not $WorkDir) { $WorkDir = Join-Path $buildRoot 'isobuild' }

# Stage 0 -- source ISO (fetch Dev-channel if not supplied). $fetched tells Stage-2
# whether the converter built minimal natively (only true when WE ran it, not -SourceIso).
$fetched = -not $SourceIso
if (-not $SourceIso) {
    Write-Host "[*] No -SourceIso; fetching stock ISO via mios-uup-fetch (channel from SSOT) ..." -ForegroundColor Cyan
    $SourceIso = & (Join-Path $PSScriptRoot 'mios-uup-fetch.ps1') -TomlPath $TomlPath -Esd:$Esd
}
if (-not (Test-Path $SourceIso)) { throw "Source ISO not found: $SourceIso" }

# Stage 1 -- extract to a writable media tree.
$media = Expand-MiOSIso -Iso $SourceIso -Dest (Join-Path $WorkDir 'media')

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
& (Join-Path $PSScriptRoot 'New-MiOSAutounattend.ps1') -TomlPath $TomlPath -OutXml (Join-Path $media 'autounattend.xml') | Out-Null
Copy-Item (Join-Path $media 'autounattend.xml') (Join-Path $media 'sources\autounattend.xml') -Force -ErrorAction SilentlyContinue

# Stage 4 -- master the bootable ISO.
Build-MiOSBootableIso -MediaRoot $media -OutIso $OutIso -Label $label

Write-Host "[+] MiOS-XBOX ISO: $OutIso" -ForegroundColor Green
Write-Host "    DISM-serviced + Xbox FSE enabled; boot to install, FirstLogon runs MiOS bootstrap." -ForegroundColor DarkGray
return $OutIso
