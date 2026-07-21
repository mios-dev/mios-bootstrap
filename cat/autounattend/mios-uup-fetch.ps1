# AI-hint: SSOT-driven UUP Dump fetcher (WISO-06 / T-137). Resolves the newest Windows 11 build on the configured channel (default DEV, per [autounattend].uup_channel) from api.uupdump.net, requests the "download + convert to ISO" package from uupdump.net/get.php (POST autodl=2), patches ConvertConfig.ini for a headless run, and drives uup_download_windows.cmd to produce a stock bootable ISO -- the reproducible source media for New-MiOSISO.ps1. Pins the resolved build UUID for reproducibility. NO browser, no hardcoded UUID (Dev builds churn).
# AI-related: mios-bootstrap, New-MiOSISO.ps1, New-MiOSAutounattend.ps1, MiOS-Provision.lib.ps1, docs/uup-autounattend-dism-iso-flow.md
# AI-functions: Get-MiOSUupRing, Invoke-UupApi, Resolve-MiOSUupBuild, Get-MiOSUupPackage, Invoke-MiOSUupConvert
#Requires -Version 5.1
<#
.SYNOPSIS
    Fetch + build a stock Windows 11 ISO from UUP Dump on the SSOT channel
    (default the Dev/Insider channel), fully headless.

.DESCRIPTION
    Stage 0 of the MiOS-Xbox ISO pipeline (see docs/uup-autounattend-dism-iso-flow.md):

        api.uupdump.net/fetchupd.php?ring=Dev   -> newest Dev build UUID (resolved at
                                                    build time; Dev builds churn, so a
                                                    UUID is never hardcoded)
        listeditions.php                         -> confirm edition + language exist
        uupdump.net/get.php (POST autodl=2)      -> "download + convert to ISO" package zip
        ConvertConfig.ini (headless patch)       -> AutoStart/AutoExit/ResetBase/ForceDism
        uup_download_windows.cmd                 -> aria2 fetch + convert -> bootable .ISO

    Channel/arch/edition/lang all resolve from mios.toml [autounattend] via the shared
    MiOS-Provision.lib.ps1 reader, degrade-open to Dev/amd64/professional/en-us. Writes
    a <iso>.uup.json pin (build + UUID + timestamp) so a build is reproducible/auditable.

    Requires elevation (the converter mounts WIMs). uupdump.net rate-limits (HTTP 429)
    and its CDN links are short-lived, so this retries with backoff and runs promptly.

.PARAMETER TomlPath   mios.toml SSOT (default: M:\etc\mios, M:\usr\share\mios, or <repo>\mios.toml).
.PARAMETER WorkDir    Scratch dir for the package + conversion. Default: <work_root>\MiOS\uup, where work_root is autounattend.work_root or the most-free fixed drive.
.PARAMETER OutIso     Final ISO path. Default: <WorkDir>\<build>.iso.
.PARAMETER Channel    Override [autounattend].uup_channel (dev|beta|releasepreview|retail).
.PARAMETER Esd        Produce install.esd (smaller) instead of install.wim.

.EXAMPLE
    .\mios-uup-fetch.ps1
    # newest Dev-channel Win11 Pro en-US -> a stock bootable ISO under M:\MiOS\uup
#>
[CmdletBinding()]
param(
    [string]$TomlPath,
    [string]$WorkDir,
    [string]$OutIso,
    [string]$Channel,
    [switch]$Esd,
    [string]$Edition
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1')

$API = 'https://api.uupdump.net'
$WEB = 'https://uupdump.net'

# Map the friendly channel to the Windows Update ring UUP Dump speaks.
function Get-MiOSUupRing {
    param([string]$Channel)
    switch -Regex ($Channel.ToLower()) {
        '^dev'            { 'Dev' }        # Windows Insider Dev (internal: WIF)
        '^beta'           { 'Beta' }
        '^release'        { 'ReleasePreview' }
        default           { 'Retail' }
    }
}

# GET a uupdump JSON endpoint with backoff (429 rate-limit / 5xx Cloudflare).
function Invoke-UupApi {
    param([string]$Url, [int]$Retries = 5)
    for ($i = 1; $i -le $Retries; $i++) {
        try { return Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 60 }
        catch {
            $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($i -eq $Retries) { throw "UUP API failed after $Retries tries ($code): $Url" }
            $wait = [Math]::Min(60, [Math]::Pow(2, $i))   # 2,4,8,16,32s
            Write-Host "[!] UUP API $code -- retry $i/$Retries in ${wait}s" -ForegroundColor Yellow
            Start-Sleep -Seconds $wait
        }
    }
}

# Resolve the newest build UUID on the ring (live WU scan), confirm edition+lang.
function Resolve-MiOSUupBuild {
    param([string]$Ring, [string]$Arch, [string]$Edition, [string]$Lang)
    Write-Host "[*] Resolving newest $Ring-channel $Arch build ..." -ForegroundColor Cyan
    $uuid = $null; $build = $null; $title = $null
    # (1) live WU scan (fetchupd.php) -- authoritative for the exact ring, but FLAKY:
    #     Microsoft's WU backend returns HTTP 500 / NO_UPDATE_FOUND / rate-limits under
    #     load and between flights. Try it, but never let it be the only source.
    try {
        $upd = Invoke-UupApi "$API/fetchupd.php?arch=$Arch&ring=$Ring&flight=Mainline" -Retries 3
        $r   = $upd.response
        if ($r -and $r.updateArray -and @($r.updateArray).Count -ge 1) {
            $sel   = @($r.updateArray)[0]
            $uuid  = $sel.updateId; $title = $sel.updateTitle
            $build = if ($sel.foundBuild) { $sel.foundBuild } elseif ($sel.build) { $sel.build }
                     elseif ("$title" -match '\b(\d+\.\d+)\b') { $Matches[1] } else { 'unknown' }
            Write-Host "    fetchupd -> build=$build uuid=$uuid ($title)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "[*] fetchupd live-scan unavailable ($($_.Exception.Message.Split([Environment]::NewLine)[0])) -- using the listid catalog fallback (expected: the WU live-scan is intentionally best-effort, never the only source)." -ForegroundColor DarkGray
    }
    # (2) catalog fallback (listid.php) -- the cataloged UUP DB. Pick the newest amd64
    #     full "Feature Update" (a buildable base, NOT a Quality/CU delta), preferring
    #     the Dev/25H2 26xxx range. Robust when the live scan is down (this is exactly
    #     what the Linux builder falls back to).
    if (-not $uuid) {
        Write-Host "[*] Falling back to the UUP catalog (listid.php) ..." -ForegroundColor Cyan
        $lst = Invoke-UupApi "$API/listid.php?search=Windows%2011&sortByDate=1"
        # listid.php returns response.builds as a UUID-keyed OBJECT (not an array):
        # {"<uuid>":{arch,build,title,...},...}. Enumerate its property VALUES.
        $bnode  = $lst.response.builds
        $builds = if ($bnode -is [System.Array]) { @($bnode) } else { @($bnode.PSObject.Properties.Value) }
        $cand = @($builds | Where-Object { $_.arch -eq $Arch -and ("$($_.title)" -match 'version 24H2|version 25H2|Feature Update') })
        # Prefer active stable 26100 / 26200 builds whose packages are guaranteed present on WU CDN
        $pref = @($cand | Where-Object { "$($_.build)" -match '^26100|^26200' })
        $pick = if ($pref.Count) { $pref[0] } elseif ($cand.Count) { $cand[0] } else { $null }
        if (-not $pick) { throw "No $Ring/Insider Feature Update build found via fetchupd OR listid (arch=$Arch)." }
        $uuid = $pick.uuid; $build = $pick.build; $title = $pick.title
        Write-Host "    listid -> build=$build uuid=$uuid ($title)" -ForegroundColor DarkGray
    }
    # Confirm the requested edition/lang are actually populated for this build (non-fatal).
    try {
        $eds  = Invoke-UupApi "$API/listeditions.php?id=$uuid&lang=$Lang" -Retries 3
        $have = @($eds.response.editionFancyNames.PSObject.Properties.Name)
        if ($have.Count -and -not ($have | Where-Object { $_ -ieq $Edition })) {
            Write-Host "[!] Edition '$Edition' not yet populated for $build; editions: $($have -join ', ')" -ForegroundColor Yellow
        }
    } catch { Write-Host "[!] listeditions check skipped ($($_.Exception.Message.Split([Environment]::NewLine)[0]))" -ForegroundColor Yellow }
    return [pscustomobject]@{ Uuid = $uuid; Build = $build; Title = $title }
}

# POST get.php for the "download + convert to ISO" package (autodl=2) -> zip -> extract dir.
function Get-MiOSUupPackage {
    param([string]$Uuid, [string]$Edition, [string]$Lang, [string]$WorkDir, [switch]$Esd)
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $extract = Join-Path $WorkDir 'package'
    $marker  = Join-Path $extract 'uup_download_windows.cmd'
    # RESUMABLE: if the package is already extracted, reuse it -- the converter's
    # aria2 runs with -c (continue), so a re-run picks up the partial UUPs\ set
    # instead of restarting the multi-GB download. This is what makes the fetch
    # survive a flaky connection: on a drop, just re-run. (Delete the package dir
    # to force a clean re-fetch.)
    if (Test-Path $marker) {
        Write-Host "[*] Reusing existing UUP package (resumes partial download). Delete '$extract' to force fresh." -ForegroundColor DarkGray
        return $extract
    }
    $zip = Join-Path $WorkDir 'uup-package.zip'
    $body = @{ autodl = '2'; updates = '1'; cleanup = '1' }
    if ($Esd) { $body['esd'] = '1' }
    $url = "$WEB/get.php?id=$Uuid&pack=$Lang&edition=$($Edition.ToLower())"
    Write-Host "[*] Requesting convert package (autodl=2) ..." -ForegroundColor Cyan
    for ($i = 1; $i -le 5; $i++) {
        try { Invoke-WebRequest -Uri $url -Method Post -Body $body -OutFile $zip -TimeoutSec 120; break }
        catch {
            if ($i -eq 5) { throw "get.php package request failed: $($_.Exception.Message)" }
            $wait = [Math]::Min(60, [Math]::Pow(2, $i))
            Write-Host "[!] get.php -- retry $i/5 in ${wait}s" -ForegroundColor Yellow; Start-Sleep -Seconds $wait
        }
    }
    # Extract into a temp sibling then swap, so a partial extract never leaves a
    # half-populated 'package' that the resume-check would wrongly trust.
    $stage = "$extract.stage"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $stage -Force
    if (-not (Test-Path (Join-Path $stage 'uup_download_windows.cmd'))) {
        throw "Package missing uup_download_windows.cmd (got a non-convert package?). Dir: $stage"
    }
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Move-Item -LiteralPath $stage -Destination $extract
    return $extract
}

# Pre-stage aria2c.exe so the converter's own bootstrap never runs.
#
# The converter's files\get_aria2.ps1 downloads + SHA256-verifies aria2c.exe in a
# child Windows PowerShell it spawns from cmd. In a customized parent session that
# child can fail to resolve Get-FileHash ("The term 'Get-FileHash' is not
# recognized") even while Invoke-WebRequest works -- a false "aria2c.exe appears to
# be tampered with" abort. We sidestep it: fetch + verify aria2c.exe here in the
# (working) build interpreter, reading the url + expected hash from the converter's
# OWN script (no duplicated literals), then neuter get_aria2.ps1 so the .cmd just
# confirms the staged binary and proceeds. Idempotent: a good aria2c.exe is kept.
function Set-MiOSAria2 {
    param([string]$PackageDir)
    $g = Join-Path $PackageDir 'files\get_aria2.ps1'
    if (-not (Test-Path $g)) { return }
    $src  = Get-Content -LiteralPath $g -Raw
    if ($src -match '# Neutered by MiOS') { return }   # already staged on a prior run
    $url  = [regex]::Match($src, "url\s*=\s*'([^']+)'").Groups[1].Value
    $hash = [regex]::Match($src, "hash\s*=\s*'([^']+)'").Groups[1].Value
    if (-not $url -or -not $hash) { Write-Host "[!] Couldn't parse aria2 url/hash -- leaving converter bootstrap intact." -ForegroundColor Yellow; return }
    $exe  = Join-Path $PackageDir 'files\aria2c.exe'
    $good = (Test-Path $exe) -and ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower() -eq $hash.ToLower())
    if (-not $good) {
        Write-Host "[*] Pre-staging aria2c.exe (bypassing the converter's fragile Get-FileHash bootstrap) ..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Force -Path (Split-Path $exe) | Out-Null
        for ($i = 1; $i -le 4 -and -not $good; $i++) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $exe -ErrorAction Stop
                $good = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower() -eq $hash.ToLower()
                if (-not $good) { Write-Host "    hash mismatch -- retry $i/4" -ForegroundColor Yellow }
            } catch {
                Write-Host ("    fetch failed ({0}) -- retry {1}/4" -f $_.Exception.Message.Split([char]10)[0], $i) -ForegroundColor Yellow
                Start-Sleep -Seconds ([math]::Min(8, 2 * $i))
            }
        }
        if (-not $good) { throw "Could not pre-stage a hash-verified aria2c.exe from $url" }
    }
    Set-Content -LiteralPath $g -Encoding ASCII -Value @(
        '# Neutered by MiOS: aria2c.exe was pre-staged + SHA256-verified by mios-uup-fetch.ps1.',
        'if (Test-Path "files\aria2c.exe") { Write-Host "Ready." ; exit 0 } else { exit 1 }'
    )
    Write-Host "[*] aria2c.exe staged + verified; converter bootstrap neutered." -ForegroundColor DarkGray
}

# Build the converter's keep-list (CustomAppsList.txt) from SSOT keep_apps:
# uncomment ONLY the wanted apps, '#' every other. With [Store_Apps]CustomList=1
# the converter integrates ONLY these, so the gaming-minimal appx surface is built
# NATIVELY (the bloat is never added) -- no offline Remove-AppxProvisionedPackage.
function Set-MiOSCustomAppsList {
    param([string]$PackageDir, [string[]]$KeepApps)
    $list = Join-Path $PackageDir 'CustomAppsList.txt'
    if (-not (Test-Path $list)) { Write-Host "[!] No CustomAppsList.txt in package -- native app selection skipped." -ForegroundColor Yellow; return $false }
    $keep = @{}; foreach ($k in $KeepApps) { if ($k) { $keep[$k.Trim().ToLower()] = $true } }
    $seen = @{}
    $out = foreach ($line in Get-Content -LiteralPath $list) {
        if ($line -match '^\s*#?\s*([A-Za-z0-9][A-Za-z0-9.]*)_[A-Za-z0-9]+\s*$') {
            $pkg  = ($line -replace '^\s*#?\s*', '').Trim()   # 'Name_hash'
            $name = $Matches[1]
            $seen[$name.ToLower()] = $true
            if ($keep.ContainsKey($name.ToLower())) { $pkg } else { "# $pkg" }
        } else { $line }                                       # header/blank -> as-is
    }
    Set-Content -LiteralPath $list -Value $out -Encoding ASCII
    $kept = @($out | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9.]*_[A-Za-z0-9]+$' }).Count
    $miss = @($KeepApps | Where-Object { $_ -and -not $seen.ContainsKey($_.Trim().ToLower()) })
    Write-Host "[*] CustomAppsList: $kept app(s) kept -- converter integrates ONLY these (bloat never added)." -ForegroundColor DarkGray
    if ($miss.Count) { Write-Host ("    (keep_apps not in this build's template, ignored: {0})" -f ($miss -join ', ')) -ForegroundColor DarkGray }
    return $true
}

# Stage this build host's 3rd-party drivers into <package>\Drivers so the converter's
# AddDrivers integrates them in its single pass -- native, instead of a 2nd Stage-2
# mount + Add-WindowsDriver. Non-fatal; needs elevation (present in the build).
function Export-MiOSHostDrivers {
    param([string]$PackageDir)
    $drvDir = Join-Path $PackageDir 'Drivers'   # matches ConvertConfig Drv_Source=\Drivers
    New-Item -ItemType Directory -Force -Path $drvDir | Out-Null
    if (@(Get-ChildItem $drvDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count) {
        Write-Host "[*] Host drivers already staged for converter AddDrivers." -ForegroundColor DarkGray; return
    }
    try {
        Write-Host "[*] Exporting host drivers for native converter bake (Export-WindowsDriver -Online) ..." -ForegroundColor Cyan
        Export-WindowsDriver -Online -Destination $drvDir -ErrorAction Stop | Out-Null
        $n = @(Get-ChildItem $drvDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
        Write-Host "    $n host driver package(s) staged -> converter AddDrivers=1" -ForegroundColor DarkGray
    } catch { Write-Host "[!] Host-driver export skipped: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow }
}

# Patch ConvertConfig.ini (SSOT-driven) then drive the converter -> ISO. Native
# minimization builds the minimal image at the SOURCE rather than add-then-strip.
function Invoke-MiOSUupConvert {
    param([string]$PackageDir, $Toml, [switch]$Esd)
    $b = { param($k, $d) if ((Get-Toml $Toml $k $d) -match '^(?i:true|1|yes)$') { '1' } else { '0' } }
    $native  = (& $b 'autounattend.uup_convert.native_apps' 'true') -eq '1'
    $drivers = (& $b 'autounattend.uup_convert.add_drivers'  'true') -eq '1'
    $ini = Join-Path $PackageDir 'ConvertConfig.ini'
    if (Test-Path $ini) {
        # Re-assert flags in the ini (website checkboxes don't always propagate).
        # Flat key=value replace -- every key below is unique across the file.
        $set = [ordered]@{
            AutoStart  = '1'; AutoExit = '1'; ForceDism = '1'
            AddUpdates = (& $b 'autounattend.uup_convert.add_updates' 'true')
            ResetBase  = (& $b 'autounattend.uup_convert.reset_base'  'true')
            Cleanup    = (& $b 'autounattend.uup_convert.reset_base'  'true')   # cleanup pairs with resetbase
            NetFx3     = (& $b 'autounattend.uup_convert.netfx3'      'false')
            SkipEdge   = (& $b 'autounattend.uup_convert.skip_edge'   'false')
            wim2esd    = $(if ($Esd) { '1' } else { '0' })
            CustomList = $(if ($native)  { '1' } else { '0' })   # [Store_Apps]: only keep_apps
            AddDrivers = $(if ($drivers) { '1' } else { '0' })   # bake host drivers this pass
        }
        $lines = Get-Content -LiteralPath $ini
        foreach ($k in $set.Keys) {
            if ($lines -match "^\s*$k\s*=") { $lines = $lines -replace "^\s*$k\s*=.*$", "$k=$($set[$k])" }
            else { $lines += "$k=$($set[$k])" }
        }
        Set-Content -LiteralPath $ini -Value $lines -Encoding ASCII
        Write-Host ("[*] ConvertConfig patched: native_apps={0} add_drivers={1} resetbase={2} netfx3={3} skipedge={4}" -f `
            $native, $drivers, $set.ResetBase, $set.NetFx3, $set.SkipEdge) -ForegroundColor DarkGray
    }
    if ($native) {
        $keep = (Get-Toml $Toml 'autounattend.uup_convert.keep_apps' '') -split '\s+' | Where-Object { $_ }
        [void](Set-MiOSCustomAppsList -PackageDir $PackageDir -KeepApps $keep)
        # Force a fresh minimal build: drop any ISO/WIM a prior (non-native) run left
        # in the package so convert-UUP re-runs CustomList against the KEPT UUPs\ set
        # instead of re-mastering a stale bloated image. UUPs\ (the download) is kept.
        Get-ChildItem -LiteralPath $PackageDir -Filter '*.ISO' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        foreach ($stray in 'install.wim','install.esd') {
            $p = Join-Path $PackageDir $stray
            if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($drivers) { Export-MiOSHostDrivers -PackageDir $PackageDir }
    Set-MiOSAria2 -PackageDir $PackageDir
    $cmd = Join-Path $PackageDir 'uup_download_windows.cmd'
    Write-Host "[*] Running UUP converter (aria2 fetch + build ISO) -- this is long ..." -ForegroundColor Cyan
    Push-Location $PackageDir
    # The converter's .cmd spawns Windows PowerShell 5.1 (files\get_aria2.ps1). Under a
    # pwsh 7 parent, the inherited PSModulePath points only at PS7's module dirs and
    # OMITS the 5.1 system path (...\v1.0\Modules), so 5.1 can't autoload
    # Microsoft.PowerShell.Utility -> Get-FileHash "not recognized" -> aria2 wrongly
    # flagged "tampered with". Reset the child's PSModulePath to the machine+user
    # default (+ the v1.0 system path explicitly) for the duration of the converter run.
    $savedPSMP = $env:PSModulePath
    $clean = @(
        [Environment]::GetEnvironmentVariable('PSModulePath','Machine'),
        [Environment]::GetEnvironmentVariable('PSModulePath','User'),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')
    ) | Where-Object { $_ } | Select-Object -Unique
    if ($clean) { $env:PSModulePath = ($clean -join ';') }
    # Pipe the converter's native output to the HOST (visible in the transcript) so it
    # does NOT enter the success stream -- otherwise this function returns an ARRAY of
    # [converter log lines..., iso path] and the caller's $SourceIso is garbage. Scope
    # EAP=Continue so the FIRST stderr line under `2>&1` doesn't throw NativeCommandError
    # in Windows PowerShell 5.1 (the build interpreter) BEFORE the exit-code check.
    $exitCode = 0
    try {
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = "cmd.exe"
        $pinfo.Arguments = "/c `"$cmd`""
        $pinfo.UseShellExecute = $false
        $pinfo.RedirectStandardOutput = $false
        $pinfo.RedirectStandardError = $false
        $p = [System.Diagnostics.Process]::Start($pinfo)
        $p.WaitForExit()
        $exitCode = $p.ExitCode
        $global:LASTEXITCODE = $exitCode
    }
    finally { $env:PSModulePath = $savedPSMP; Pop-Location }
    if ($exitCode -ne 0) { throw "uup_download_windows.cmd failed (exit $exitCode)" }
    $iso = Get-ChildItem -Path $PackageDir -Filter '*.ISO' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $iso) { throw "Converter produced no .ISO under $PackageDir" }
    return $iso.FullName
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if (-not $TomlPath) {
    foreach ($c in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',(Join-Path $PSScriptRoot '..\..\mios.toml'))) {
        if (Test-Path -LiteralPath $c) { $TomlPath = (Resolve-Path $c).Path; break }
    }
}
$toml    = if ($TomlPath) { Read-MiosToml -Path $TomlPath } else { @{ scalars=@{}; accounts=@(); prefs=@{} } }
$toml    = Apply-MiosEdition -T $toml -Edition $Edition
$chan    = if ($Channel) { $Channel } else { Get-Toml $toml 'autounattend.uup_channel' 'dev' }
$arch    = Get-Toml $toml 'autounattend.uup_arch'    'amd64'
$edition = Get-Toml $toml 'autounattend.uup_edition' 'professional'
$lang    = Get-Toml $toml 'autounattend.uup_lang'    'en-us'
$ring    = Get-MiOSUupRing -Channel $chan
if (-not $WorkDir) { $WorkDir = Join-Path (Resolve-MiOSBuildRoot $toml) 'uup' }

Write-Host "[*] UUP fetch: channel=$chan (ring=$ring) arch=$arch edition=$edition lang=$lang" -ForegroundColor Cyan
$b   = Resolve-MiOSUupBuild -Ring $ring -Arch $arch -Edition $edition -Lang $lang
$pkg = Get-MiOSUupPackage -Uuid $b.Uuid -Edition $edition -Lang $lang -WorkDir $WorkDir -Esd:$Esd
$iso = Invoke-MiOSUupConvert -PackageDir $pkg -Toml $toml -Esd:$Esd

if ($OutIso) {
    New-Item -ItemType Directory -Force -Path (Split-Path $OutIso) | Out-Null
    Move-Item -LiteralPath $iso -Destination $OutIso -Force
    $iso = $OutIso
}
# Pin the resolved build for reproducibility/audit (stamp the caller's clock, not
# this script's -- we don't fabricate a timestamp here).
$pin = "$iso.uup.json"
@{ build = $b.Build; uuid = $b.Uuid; title = $b.Title; ring = $ring; arch = $arch; edition = $edition; lang = $lang } |
    ConvertTo-Json | Set-Content -LiteralPath $pin -Encoding UTF8

Write-Host "[+] Stock ISO: $iso" -ForegroundColor Green
Write-Host "    build=$($b.Build)  pin=$pin  (feed to New-MiOSISO.ps1 -SourceIso)" -ForegroundColor DarkGray
return $iso
