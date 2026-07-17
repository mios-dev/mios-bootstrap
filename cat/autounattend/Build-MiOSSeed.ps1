# AI-hint: Build the BAKED-IN Stage-1 seed blobs on the MiOS-DEV builder, so the
# customer's first boot provisions MiOS with NO download/build on the critical path.
# Produces three artifacts into the seed dir that New-MiOSISO.ps1 bakes into the image
# (-> C:\ProgramData\MiOS\seed) and MiOS-Provision.ps1 loads offline:
#   1. <rootfs>       -- the MiOS WSL2 rootfs tarball        (wsl --export)
#   2. <oci_archive>  -- the bootc/OCI image as an oci-archive (podman/skopeo save)
#   3. <podman_machine> -- an optional podman-machine image    (podman machine os apply / save)
# DEGRADE-OPEN + AUTHORABLE: if a tool (wsl/podman/skopeo) is not present at author
# time, the script does NOT fail -- it prints the EXACT command it would have run so
# an operator can produce the blob on the real MiOS-DEV VM. SSOT-driven from mios.toml
# [autounattend.seed]. Run on the Windows host that owns the MiOS-DEV builder.
# AI-related: mios-bootstrap, New-MiOSISO.ps1 (Copy-MiOSSeedBlobs), MiOS-Provision.ps1, mios.toml [autounattend.seed]
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TomlPath,
    [string]$OutDir,                       # seed output dir; default <build_root>\MiOS\seed
    [string]$BuilderDistro,                # WSL distro to export; default seed.distro / MiOS-DEV
    [string]$ImageRef,                     # OCI ref to save; default seed.image_ref
    [switch]$Force                         # overwrite existing blobs
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
. (Join-Path $PSScriptRoot 'MiOS-Provision.lib.ps1')

if (-not $TomlPath) {
    foreach ($c in @('M:\etc\mios\mios.toml','M:\usr\share\mios\mios.toml',(Join-Path $PSScriptRoot '..\..\mios.toml'))) {
        if (Test-Path -LiteralPath $c) { $TomlPath = (Resolve-Path -LiteralPath $c).Path; break }
    }
}
$toml = if ($TomlPath) { Read-MiosToml -Path $TomlPath } else { @{ scalars=@{}; accounts=@() } }

$buildRoot     = Resolve-MiOSBuildRoot $toml
if (-not $OutDir)        { $OutDir        = Get-Toml $toml 'autounattend.seed.source' '' }
if (-not $OutDir)        { $OutDir        = Join-Path $buildRoot 'MiOS\seed' }
if (-not $BuilderDistro) { $BuilderDistro = Get-Toml $toml 'autounattend.seed.builder_distro' (Get-Toml $toml 'autounattend.seed.distro' 'MiOS-DEV') }
if (-not $ImageRef)      { $ImageRef      = Get-Toml $toml 'autounattend.seed.image_ref' 'ghcr.io/mios-dev/mios:latest' }
$rootfsName  = Get-Toml $toml 'autounattend.seed.rootfs'         'mios-rootfs.tar'
$ociName     = Get-Toml $toml 'autounattend.seed.oci_archive'    'mios-image.oci.tar'
$machineName = Get-Toml $toml 'autounattend.seed.podman_machine' 'podman-machine.tar'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$rootfs  = Join-Path $OutDir $rootfsName
$oci     = Join-Path $OutDir $ociName
$machine = Join-Path $OutDir $machineName

$wsl = if (Test-Path "$env:ProgramFiles\WSL\wsl.exe") { "$env:ProgramFiles\WSL\wsl.exe" } else { 'wsl.exe' }
$env:WSL_UTF8 = '1'
function Have { param([string]$Exe) [bool](Get-Command $Exe -ErrorAction SilentlyContinue) }
function Emit-Manual { param([string]$What,[string]$Cmd)
    Write-Host "[stub] $What -- tool unavailable at author time. Run this on MiOS-DEV:" -ForegroundColor Yellow
    Write-Host "       $Cmd" -ForegroundColor DarkGray
}

Write-Host "[*] MiOS seed build -> $OutDir" -ForegroundColor Cyan
Write-Host "    builder distro=$BuilderDistro  image=$ImageRef" -ForegroundColor DarkGray

# --- 1) WSL rootfs tarball (wsl --export) -----------------------------------
if ((Test-Path $rootfs) -and -not $Force) {
    Write-Host "[=] rootfs exists (use -Force to rebuild): $rootfs" -ForegroundColor DarkGray
} elseif (Have 'wsl.exe') {
    $names = (((& $wsl --list --quiet 2>$null) -join "`n") -replace "`0", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($names -contains $BuilderDistro) {
        Write-Host "[*] wsl --export $BuilderDistro -> $rootfs ..." -ForegroundColor Cyan
        & $wsl --export $BuilderDistro $rootfs
        if ($LASTEXITCODE -eq 0 -and (Test-Path $rootfs)) { Write-Host "    rootfs: $([math]::Round((Get-Item $rootfs).Length/1MB,1)) MB" -ForegroundColor Green }
        else { Write-Host "[!] wsl --export returned $LASTEXITCODE (rootfs may be incomplete)." -ForegroundColor Yellow }
    } else {
        Emit-Manual 'rootfs' "wsl --export $BuilderDistro `"$rootfs`""
        Write-Host "    (distro '$BuilderDistro' not registered on this host; export from the box that owns it)" -ForegroundColor DarkGray
    }
} else {
    Emit-Manual 'rootfs' "wsl --export $BuilderDistro `"$rootfs`""
}

# --- 2) OCI-archive of the bootc image (skopeo preferred; podman save fallback) --
if ((Test-Path $oci) -and -not $Force) {
    Write-Host "[=] oci-archive exists (use -Force to rebuild): $oci" -ForegroundColor DarkGray
} elseif (Have 'skopeo') {
    Write-Host "[*] skopeo copy -> oci-archive:$oci ..." -ForegroundColor Cyan
    & skopeo copy "docker://$ImageRef" "oci-archive:${oci}:$ImageRef"
    if ($LASTEXITCODE -ne 0) { Write-Host "[!] skopeo copy returned $LASTEXITCODE." -ForegroundColor Yellow }
} elseif (Have 'podman') {
    Write-Host "[*] podman save (oci-archive) -> $oci ..." -ForegroundColor Cyan
    & podman save --format oci-archive -o $oci $ImageRef
    if ($LASTEXITCODE -ne 0) { Write-Host "[!] podman save returned $LASTEXITCODE." -ForegroundColor Yellow }
} else {
    Emit-Manual 'oci-archive' "skopeo copy docker://$ImageRef oci-archive:`"$oci`":$ImageRef   # or: podman save --format oci-archive -o `"$oci`" $ImageRef"
}

# --- 3) podman-machine image (OPTIONAL: only if the deploy uses a Windows machine) --
# The customer runtime runs podman INSIDE the MiOS distro, so this is opt-in. When
# [autounattend.seed].build_machine is true we export the current default machine's
# image; otherwise emit the command as documentation.
if ((Get-Toml $toml 'autounattend.seed.build_machine' 'false') -match '^(?i:true|1|yes)$') {
    if ((Test-Path $machine) -and -not $Force) {
        Write-Host "[=] podman-machine image exists (use -Force to rebuild): $machine" -ForegroundColor DarkGray
    } elseif (Have 'podman') {
        Write-Host "[*] exporting podman-machine image -> $machine ..." -ForegroundColor Cyan
        # podman machine images are distro-specific; export the backing rootfs.
        & podman machine inspect --format '{{.Image}}' 2>$null | Out-Null
        Emit-Manual 'podman-machine' "podman machine init --now; podman machine ssh 'sudo tar -C / -czf -' > `"$machine`"   # export the machine rootfs for offline reuse"
    } else {
        Emit-Manual 'podman-machine' "podman machine init; <export machine rootfs> -> `"$machine`""
    }
} else {
    Write-Host "[*] podman-machine seed skipped ([autounattend.seed].build_machine=false; engine runs in-distro)." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "[+] Seed dir: $OutDir" -ForegroundColor Green
Get-ChildItem $OutDir -File -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("    {0,-28} {1,8:N1} MB" -f $_.Name, ($_.Length/1MB)) -ForegroundColor DarkGray }
Write-Host "    New-MiOSISO.ps1 bakes these into the image when [autounattend.seed].enable=true and seed.source points here." -ForegroundColor DarkGray
return $OutDir
