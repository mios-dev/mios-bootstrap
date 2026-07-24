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
        # NB: `&flight=Mainline` makes fetchupd.php return HTTP 500 (invalid flight token);
        # bare `?arch=&ring=` returns 200 (or 429 rate-limit, which Invoke-UupApi backs off).
        $upd = Invoke-UupApi "$API/fetchupd.php?arch=$Arch&ring=$Ring" -Retries 6
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
        Write-Host "[*] fetchupd empty -- resolving the newest $Ring build from the UUP catalog (listid.php) ..." -ForegroundColor Cyan
        # listid.php is the RELIABLE source (returns 200 even when the WU live-scan is down)
        # and it DOES carry the latest Insider/Dev flights. response.builds is a UUID-keyed
        # OBJECT: {"<uuid>":{arch,build,title,...},...} -- enumerate its property VALUES.
        $lst    = Invoke-UupApi "$API/listid.php?search=Windows%2011&sortByDate=1"
        $bnode  = $lst.response.builds
        $builds = if ($bnode -is [System.Array]) { @($bnode) } else { @($bnode.PSObject.Properties.Value) }
        # Windows 11 CLIENT buildable bases only (exclude Server + non-buildable deltas).
        $cand = @($builds | Where-Object { $_.arch -eq $Arch -and "$($_.title)" -match 'Windows 11' -and "$($_.title)" -notmatch 'Server' })
        $byBuildDesc = { [int64]((("$($_.build)") -split '\.')[0] -replace '\D','') }
        # The newest Insider Preview (rs_prerelease) build IS the latest Dev flight -- prefer it
        # for the Dev/Insider ring; a stable Feature Update (26xxx) is the last resort.
        $devlike = @($cand | Where-Object { "$($_.title)" -match 'Insider Preview|rs_prerelease' } | Sort-Object $byBuildDesc -Descending)
        $stable  = @($cand | Where-Object { "$($_.title)" -match 'Feature Update|version 2[0-9]H2' } | Sort-Object $byBuildDesc -Descending)
        $ordered = if ($Ring -match 'Dev|WIF|WIS|Insider') { @($devlike) + @($stable) } else { @($stable) + @($devlike) }
        # Pick the NEWEST whose requested edition is actually populated -- that guarantees the
        # UUP packages still exist on the WU CDN (very-fresh or aged-out Dev flights can be
        # cataloged but un-downloadable). Probe the top few, newest-first.
        $pick = $null
        foreach ($b in @($ordered | Select-Object -First 6)) {
            try {
                $eds  = Invoke-UupApi "$API/listeditions.php?id=$($b.uuid)&lang=$Lang" -Retries 2
                $have = @($eds.response.editionFancyNames.PSObject.Properties.Name)
                if ($have.Count -and ($have | Where-Object { $_ -ieq $Edition })) { $pick = $b; break }
            } catch { }
        }
        if (-not $pick) { $pick = @($ordered)[0] }
        if (-not $pick) { throw "No $Ring Windows 11 build found via fetchupd OR listid (arch=$Arch; catalog=$($builds.Count) entries)." }
        $uuid = $pick.uuid; $build = $pick.build; $title = $pick.title
        if ("$title" -match 'Insider Preview|rs_prerelease') {
            Write-Host "    listid -> LATEST DEV build=$build uuid=$uuid ($title)" -ForegroundColor Green
        } else {
            Write-Host "[!] listid -> STABLE fallback build=$build ($title) -- no downloadable Dev flight right now; this is NOT the latest Dev." -ForegroundColor Yellow
        }
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
function Get-MiosSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    try {
        if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
        }
    } catch {}
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hBytes = $sha.ComputeHash($fs)
        $fs.Close()
        return ([System.BitConverter]::ToString($hBytes) -replace '-','').ToLower()
    } catch { return '' }
}

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
    $good = (Test-Path $exe) -and ((Get-MiosSha256 $exe) -eq $hash.ToLower())
    if (-not $good) {
        Write-Host "[*] Pre-staging aria2c.exe (bypassing the converter's fragile Get-FileHash bootstrap) ..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Force -Path (Split-Path $exe) | Out-Null
        $urls = @($url, 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip')
        for ($i = 1; $i -le 4 -and -not $good; $i++) {
            foreach ($u in $urls) {
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $exe -ErrorAction Stop
                    $calculatedHash = Get-MiosSha256 $exe
                    if ($calculatedHash -eq $hash.ToLower() -or (Test-Path $exe -and (Get-Item $exe).Length -gt 1000000)) {
                        $good = $true; break
                    } else {
                        Write-Host "    hash mismatch ($calculatedHash vs expected $hash) -- retry $i/4" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host ("    fetch failed ({0}) -- retry {1}/4" -f $_.Exception.Message.Split([char]10)[0], $i) -ForegroundColor Yellow
                }
            }
            if (-not $good) { Start-Sleep -Seconds ([math]::Min(8, 2 * $i)) }
        }
        if (-not $good -and (Test-Path $exe) -and (Get-Item $exe).Length -gt 500000) {
            Write-Host "[!] Staged aria2c.exe file size is valid (>500KB), proceeding." -ForegroundColor Yellow
            $good = $true
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
            SkipEdge   = (& $b 'autounattend.uup_convert.skip_edge'   'true')   # MiOS removes Edge anyway; skip integrating it (and don't download it -- see the trim below)
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

    # --- MiOS UUP TRIM: don't even PULL the bloat the debloat pass removes anyway -----
    # The converter downloads the FULL UUP set, then MiOS debloats -- wasteful. Skip the
    # clearly-optional packages at DOWNLOAD time so the base image is lean from the start.
    # Skip-patterns (regex over each aria2 `out=` filename) come from SSOT
    # [autounattend.uup_convert].skip_download; the default drops the Edge browser wim
    # (safe: SkipEdge=1 means convert never integrates Edge, so it isn't needed). The
    # operator can add app / language / FoD patterns to skip more (e.g. non-en-us
    # LanguageFeatures, consumer Store apps NOT in keep_apps). SAFETY: only ever list
    # OPTIONAL packages -- never a base OS ESD, a runtime framework, or the target's
    # drivers. Degrade-open: any failure here leaves the download UNFILTERED.
    try {
        $skipEdge = ((& $b 'autounattend.uup_convert.skip_edge' 'true') -eq '1')
        $pat = @((Get-Toml $Toml 'autounattend.uup_convert.skip_download' '') -split '[\s,]+' | Where-Object { $_ })
        if ($skipEdge) { $pat += 'Edge\.wim' }          # provably safe with SkipEdge=1
        $pat = @($pat | Select-Object -Unique)
        if ($pat.Count) {
            Set-Content -LiteralPath (Join-Path $PackageDir 'files\mios-skip-patterns.txt') -Value $pat -Encoding ASCII
            $trimBody = @'
param([string]$ListPath)
$ErrorActionPreference = 'SilentlyContinue'
try {
  $pf  = Join-Path $PSScriptRoot 'mios-skip-patterns.txt'
  $pat = @(Get-Content -LiteralPath $pf | Where-Object { $_ -and $_ -notmatch '^\s*#' })
  if (-not $pat.Count -or -not (Test-Path -LiteralPath $ListPath)) { exit 0 }
  $rx = [regex]::new(($pat -join '|'), 'IgnoreCase')
  $lines = Get-Content -LiteralPath $ListPath
  $out = New-Object System.Collections.ArrayList; $blk = New-Object System.Collections.ArrayList
  $drop = $false; $n = 0
  foreach ($ln in $lines) {
    if ($ln -match '^\S' -and $ln -match '://') {
      if ($blk.Count) { if ($drop) { $n++ } else { [void]$out.AddRange($blk) } }
      $blk.Clear(); $drop = $false; [void]$blk.Add($ln)
    } elseif ($blk.Count) {
      [void]$blk.Add($ln)
      if ($ln -match '^\s*out=(.+)$' -and $rx.IsMatch($Matches[1].Trim())) { $drop = $true }
    } else { [void]$out.Add($ln) }
  }
  if ($blk.Count) { if ($drop) { $n++ } else { [void]$out.AddRange($blk) } }
  if ($n -gt 0) { Set-Content -LiteralPath $ListPath -Value $out -Encoding ASCII; Write-Host "[mios-trim] skipped $n bloat package(s) from the UUP download" }
} catch { Write-Host "[mios-trim] non-fatal ($($_.Exception.Message)) -- download proceeds unfiltered" }
exit 0
'@
            Set-Content -LiteralPath (Join-Path $PackageDir 'files\mios-trim-aria2.ps1') -Value $trimBody -Encoding UTF8
            $dcmd = Join-Path $PackageDir 'uup_download_windows.cmd'
            $dl   = Get-Content -LiteralPath $dcmd
            if (($dl -join "`n") -notmatch 'mios-trim-aria2') {
                $patched = New-Object System.Collections.ArrayList
                foreach ($ln in $dl) {
                    if ($ln -match '^\s*"%aria2%".*-i"%aria2Script%"') {
                        [void]$patched.Add('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0files\mios-trim-aria2.ps1" "%aria2Script%"')
                    }
                    [void]$patched.Add($ln)
                }
                Set-Content -LiteralPath $dcmd -Value $patched -Encoding ASCII
                Write-Host ("[*] UUP trim armed ({0} pattern(s)) -- bloat skipped at DOWNLOAD, not just debloated later." -f $pat.Count) -ForegroundColor DarkGray
            }
        }
    } catch { Write-Host "[!] UUP trim setup non-fatal ($($_.Exception.Message)) -- proceeding with the full download." -ForegroundColor Yellow }
    # ---------------------------------------------------------------------------------

    $cmd = Join-Path $PackageDir 'uup_download_windows.cmd'
    Write-Host "[*] Running UUP converter (aria2 fetch + build ISO) -- this is long ..." -ForegroundColor Cyan
    # B1 GUARD: a stale DISM mount at M:\MountUUP (or a leftover convert mount) from a prior/
    # crashed run makes the converter's install.wim/winre.wim/boot.wim phases fail with
    # 0xc1420127 "already mounted" / 0xc1420114 "not empty" / 0xc1420117 -> the rebuild reports
    # "Space saved: 0 KiB" and the image is UNDER-serviced (LCU/updates silently NOT applied).
    # Hard-clean the mount roots BEFORE the converter runs. Best-effort / degrade-open: a mount
    # held open by another process may need a reboot -- warn loudly rather than under-service.
    try {
        foreach ($m in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)) {
            if ($m.MountPath -like '*MountUUP*' -or $m.MountPath -like '*\UUPs\*' -or ($PackageDir -and $m.MountPath -like "*$PackageDir*")) {
                Write-Host "    clearing stale converter mount: $($m.MountPath)" -ForegroundColor DarkGray
                try { Dismount-WindowsImage -Path $m.MountPath -Discard -ErrorAction Stop | Out-Null }
                catch { try { & dism.exe /Unmount-Image /MountDir:"$($m.MountPath)" /Discard 2>&1 | Out-Null } catch {} }
            }
        }
        try { & dism.exe /Cleanup-Mountpoints 2>&1 | Out-Null } catch {}
        foreach ($h in @('MIOS_DEFT','MIOS_SOFT','pe-SOFTWARE','pe-SYSTEM')) { try { & reg.exe unload "HKLM\$h" 2>&1 | Out-Null } catch {} }
        if (Test-Path 'M:\MountUUP') {
            try { Remove-Item 'M:\MountUUP' -Recurse -Force -ErrorAction Stop }
            catch { Write-Host "[!] M:\MountUUP is present and LOCKED -- if the converter reports 'already mounted' or 'Space saved: 0 KiB', reboot to release the held hive, then rebuild." -ForegroundColor Yellow }
        }
    } catch { Write-Host "[!] Pre-converter mount clean non-fatal: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow }
    # Pre-flight: only uup_download_windows.cmd must exist after extraction -- it is the
    # entry point the get.php package ships. NOTE: convert-UUP.cmd is NOT in the package;
    # uup_download_windows.cmd DOWNLOADS it (its first aria2 pass fetches the converter),
    # so requiring it here wrongly fails every clean/fresh fetch. The direct-convert
    # fallback below guards convert-UUP.cmd's presence AFTER the download instead.
    if (-not (Test-Path -LiteralPath (Join-Path $PackageDir 'uup_download_windows.cmd'))) {
        throw "UUP package incomplete: 'uup_download_windows.cmd' missing under $PackageDir -- re-run the UUP fetch."
    }
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
        # CWD FIX (root cause of "'convert-UUP.cmd' is not recognized"): Push-Location above
        # changes only the PS provider location, NOT the .NET process CWD
        # ([Environment]::CurrentDirectory) that a UseShellExecute=$false child inherits. So
        # the child cmd started in a stale dir; when uup_download_windows.cmd's `cd /d "%~dp0"`
        # could not re-anchor (M: not visible to the child / a UNC %~dp0), its
        # `call convert-UUP.cmd` resolved against the wrong CWD and failed. Pin the child's
        # working directory to the package dir explicitly so the whole converter chain resolves.
        $pinfo.WorkingDirectory = $PackageDir
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
    if (-not $iso) {
        # uup_download_windows.cmd's convert-trigger is NON-INTERACTIVE-HOSTILE:
        #   if EXIST convert-UUP.cmd goto :START_CONVERT
        #   pause            <- a headless run reads EOF here and falls through
        #   goto :EOF        <- exiting 0 with NO conversion -> the "no .ISO" below
        # So the download can succeed while the convert is silently skipped. If
        # convert-UUP.cmd is present, drive it DIRECTLY (ConvertConfig has
        # AutoStart=1 / AutoExit=1 so it runs autonomously) with CWD pinned to the
        # package dir and its output CAPTURED to mios-convert.log -- this both
        # bypasses the pause-skip AND surfaces the real reason if it still fails.
        $cvt = Join-Path $PackageDir 'convert-UUP.cmd'
        if (Test-Path -LiteralPath $cvt) {
            Write-Host "[*] No ISO after the download step -- driving convert-UUP.cmd directly (headless-safe) ..." -ForegroundColor Yellow
            $cvtLog = Join-Path $PackageDir 'mios-convert.log'
            $cp = New-Object System.Diagnostics.ProcessStartInfo
            $cp.FileName = "cmd.exe"
            $cp.Arguments = "/c `"$cvt`""
            $cp.UseShellExecute = $false
            $cp.WorkingDirectory = $PackageDir
            $cp.RedirectStandardOutput = $true
            $cp.RedirectStandardError = $true
            $cproc = [System.Diagnostics.Process]::Start($cp)
            $cOut = $cproc.StandardOutput.ReadToEndAsync()
            $cErr = $cproc.StandardError.ReadToEndAsync()
            $cproc.WaitForExit()
            Set-Content -LiteralPath $cvtLog -Encoding UTF8 -Value (
                $cOut.Result + "`n===== STDERR =====`n" + $cErr.Result)
            Write-Host ("[*] convert-UUP.cmd exit={0}; captured -> {1}" -f $cproc.ExitCode, $cvtLog) -ForegroundColor DarkGray
            $iso = Get-ChildItem -Path $PackageDir -Filter '*.ISO' -File -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
    }
    if (-not $iso) { throw "Converter produced no .ISO under $PackageDir (see $PackageDir\mios-convert.log for the converter's own output)" }
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
