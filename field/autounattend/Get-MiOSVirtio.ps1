<#
.SYNOPSIS
  Browser-assisted, Anubis-safe fetch of the FULL latest virtio-win.iso, with automated transport.

.DESCRIPTION
  fedorapeople.org (the virtio-win source) is now behind an Anubis proof-of-work bot-wall that no
  CLI tool (curl / Invoke-WebRequest / wget) can pass -- but a real browser solves it in ~1 second.
  This opens the download in the default browser (which solves Anubis and downloads the signed ISO),
  PAUSES until the ISO fully lands in a Downloads folder (size-stable, no .crdownload/.part partial,
  valid ISO9660 'CD001' signature), then transports it to -Dest for the build to bake. The pipeline
  resumes automatically the moment the file is complete.

.PARAMETER Dest        Where the build expects virtio-win.iso (the build cache path).
.PARAMETER Url         Download URL (default: fedorapeople latest-virtio).
.PARAMETER TimeoutMin  How long to wait for the download to complete (default 25).
.PARAMETER MinSizeMB   Minimum size to consider a real ISO (default 200; the real file is ~700 MB).
#>
[CmdletBinding()]
param(
    [string]$Dest,
    [string]$Url = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso',
    [int]$TimeoutMin = 25,
    [int]$MinSizeMB = 200
)

function Test-IsoValid([string]$p) {
    if (-not $p -or -not (Test-Path -LiteralPath $p) -or (Get-Item -LiteralPath $p).Length -lt ($MinSizeMB * 1MB)) { return $false }
    try {
        $fs = [IO.File]::OpenRead($p)
        try { [void]$fs.Seek(0x8001, 'Begin'); $b = New-Object byte[] 5; [void]$fs.Read($b, 0, 5); return ([Text.Encoding]::ASCII.GetString($b) -eq 'CD001') }
        finally { $fs.Close() }
    } catch { return $false }
}
function Test-Complete([string]$p) {
    # a browser download is done when the .crdownload/.part sidecar is gone AND size is stable
    if ((Test-Path -LiteralPath "$p.crdownload") -or (Test-Path -LiteralPath "$p.part") -or (Test-Path -LiteralPath "$p.tmp")) { return $false }
    $s1 = (Get-Item -LiteralPath $p).Length; Start-Sleep -Seconds 3
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    return ((Get-Item -LiteralPath $p).Length -eq $s1) -and (Test-IsoValid $p)
}

# Already have a valid one at the destination? Nothing to do.
if ($Dest -and (Test-IsoValid $Dest)) { Write-Host "[virtio] already present + valid at $Dest" -ForegroundColor Green; exit 0 }

# Candidate landing folders (default Downloads for whoever is logged in, plus TEMP).
$dirs = @(
    (Join-Path $env:USERPROFILE 'Downloads'),
    (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'),
    'C:\Users\Administrator\Downloads',
    $env:TEMP
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

# FAST PATH: if a valid, complete virtio-win ISO is ALREADY in a landing folder (a prior download,
# or one the user kicked off ahead of time), use it directly -- no browser, no waiting. Newest wins.
$existing = @($dirs |
    ForEach-Object { Get-ChildItem $_ -Filter 'virtio-win*.iso' -File -ErrorAction SilentlyContinue } |
    Where-Object { (Test-IsoValid $_.FullName) -and (Test-Complete $_.FullName) } |
    Sort-Object LastWriteTime -Descending) | Select-Object -First 1
if ($existing) {
    Write-Host "[virtio] using already-downloaded ISO: $($existing.FullName)" -ForegroundColor Green
    if (-not $Dest) { exit 0 }
    $dd = Split-Path -Parent $Dest
    if ($dd -and -not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
    Copy-Item -LiteralPath $existing.FullName -Destination $Dest -Force
    if (Test-IsoValid $Dest) { Write-Host "[virtio] transported -> $Dest (build will now bake it)" -ForegroundColor Green; exit 0 }
    Write-Host "[virtio] copy of existing ISO to $Dest did not validate -- falling through to browser fetch." -ForegroundColor Yellow
}

# Snapshot existing virtio ISOs so we only pick up the NEW / freshly-updated download.
$before = @{}
foreach ($d in $dirs) { foreach ($f in @(Get-ChildItem $d -Filter 'virtio-win*.iso' -File -ErrorAction SilentlyContinue)) { $before[$f.FullName] = $f.Length } }

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  MiOS -- virtio-win.iso needs a BROWSER download (Anubis bot-wall)" -ForegroundColor Cyan
Write-Host "  Opening your browser to the virtio-win download now." -ForegroundColor Cyan
Write-Host "  If it does not start on its own, click the download link/button." -ForegroundColor Cyan
Write-Host "  Leave it running -- the build PAUSES and RESUMES automatically" -ForegroundColor Cyan
Write-Host "  the moment the ISO finishes downloading." -ForegroundColor Cyan
Write-Host "  Waiting up to $TimeoutMin min. Landing folder(s):" -ForegroundColor Cyan
$dirs | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkCyan }
Write-Host "==================================================================" -ForegroundColor Cyan

try { Start-Process $Url } catch { Write-Host "[virtio] could not auto-open the browser -- open this URL manually:`n    $Url" -ForegroundColor Yellow }

$deadline = (Get-Date).AddMinutes($TimeoutMin)
$found = $null
while ((Get-Date) -lt $deadline -and -not $found) {
    foreach ($d in $dirs) {
        foreach ($f in @(Get-ChildItem $d -Filter 'virtio-win*.iso' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            $isNew = (-not $before.ContainsKey($f.FullName)) -or ($before[$f.FullName] -ne $f.Length)
            if ($isNew -and (Test-IsoValid $f.FullName) -and (Test-Complete $f.FullName)) { $found = $f.FullName; break }
        }
        if ($found) { break }
    }
    if (-not $found) {
        $rem = [int]($deadline - (Get-Date)).TotalMinutes
        Write-Host "    ...waiting for virtio-win.iso to finish downloading (${rem} min left)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 6
    }
}

if (-not $found) { Write-Host "[virtio] timed out after $TimeoutMin min -- no completed virtio-win*.iso appeared." -ForegroundColor Yellow; exit 1 }

Write-Host "[virtio] download complete: $found" -ForegroundColor Green
if ($Dest) {
    $dd = Split-Path -Parent $Dest
    if ($dd -and -not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
    Copy-Item -LiteralPath $found -Destination $Dest -Force
    if (Test-IsoValid $Dest) { Write-Host "[virtio] transported -> $Dest (build will now bake it)" -ForegroundColor Green; exit 0 }
    Write-Host "[virtio] copy to $Dest did not validate." -ForegroundColor Yellow; exit 1
}
exit 0
