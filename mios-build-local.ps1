# MiOS Local Build Script
# Called by bootstrap.ps1 after configuration collection
# Reads registry.toml and executes podman build with all variables

$ErrorActionPreference = "Stop"

# ============================================================================
# Configuration Loading
# ============================================================================

$MiosConfigFile = Join-Path $env:APPDATA "MiOS\registry.toml"
$MiosSecretsFile = Join-Path $env:LOCALAPPDATA "MiOS\state\secrets.env"
$MiosLogsDir = Join-Path $env:LOCALAPPDATA "MiOS\state\logs"
$MiosBuildDir = Join-Path $env:LOCALAPPDATA "MiOS\cache\builds"

# Create log directory
if (-not (Test-Path $MiosLogsDir)) {
    New-Item -ItemType Directory -Path $MiosLogsDir -Force | Out-Null
}

$BuildLog = Join-Path $MiosLogsDir "build-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    Write-Host $logLine
    Add-Content -Path $BuildLog -Value $logLine
}

Write-Log "MiOS Local Build Starting" "INFO"
Write-Log "Config File: $MiosConfigFile" "INFO"
Write-Log "Build Log: $BuildLog" "INFO"

# ============================================================================
# Load Configuration from registry.toml
# ============================================================================

if (-not (Test-Path $MiosConfigFile)) {
    Write-Log "ERROR: registry.toml not found at $MiosConfigFile" "FAIL"
    Write-Host "  Please run bootstrap.ps1 first to generate configuration." -ForegroundColor Red
    exit 1
}

Write-Log "Loading configuration from registry.toml..." "INFO"

# Parse TOML (simple parser for our specific format)
$config = @{}
$currentSection = $null

Get-Content $MiosConfigFile | ForEach-Object {
    $line = $_.Trim()

    # Skip comments and empty lines
    if ($line -match '^\s*#' -or $line -eq '') { return }

    # Section headers
    if ($line -match '^\[tags\.(\w+)\]') {
        $currentSection = $matches[1]
        $config[$currentSection] = @{}
        return
    }

    # Key-value pairs
    if ($currentSection -and $line -match '^(\w+)\s*=\s*"(.+)"') {
        $key = $matches[1]
        $value = $matches[2]
        $config[$currentSection][$key] = $value
    }
}

# Extract build variables
$MIOS_VERSION = $config['VAR_VERSION']['value']
$MIOS_USER = $config['VAR_USER']['value']
$MIOS_HOSTNAME = $config['VAR_HOSTNAME']['value']
$MIOS_FLATPAKS = $config['VAR_FLATPAKS']['value']
$IMG_BASE = $config['IMG_BASE']['value']

Write-Log "Version: $MIOS_VERSION" "INFO"
Write-Log "User: $MIOS_USER" "INFO"
Write-Log "Hostname: $MIOS_HOSTNAME" "INFO"
Write-Log "Flatpaks: $($MIOS_FLATPAKS.Split(',').Count) apps" "INFO"
Write-Log "Base Image: $IMG_BASE" "INFO"

# Load password hash from secrets
if (Test-Path $MiosSecretsFile) {
    $secrets = Get-Content $MiosSecretsFile
    $MIOS_PASSWORD_HASH = ($secrets | Select-String "MIOS_PASSWORD_HASH=").ToString().Split('=')[1]
} else {
    Write-Log "ERROR: secrets.env not found" "FAIL"
    exit 1
}

# ============================================================================
# Podman Build
# ============================================================================

Write-Host ""
Write-Host "  +==================================================================+" -ForegroundColor Cyan
Write-Host "  |  MiOS v$MIOS_VERSION - Starting Container Build                     |" -ForegroundColor Cyan
Write-Host "  +==================================================================+" -ForegroundColor Cyan
Write-Host ""

$buildArgs = @(
    "--build-arg", "MIOS_USER=$MIOS_USER",
    "--build-arg", "MIOS_HOSTNAME=$MIOS_HOSTNAME",
    "--build-arg", "MIOS_PASSWORD_HASH=$MIOS_PASSWORD_HASH",
    "--build-arg", "MIOS_FLATPAKS=$MIOS_FLATPAKS",
    "--build-arg", "BASE_IMAGE=$IMG_BASE",
    "-t", "localhost/mios:latest",
    "-t", "localhost/mios:$MIOS_VERSION",
    "."
)

Write-Log "Starting podman build..." "INFO"
Write-Log "Build arguments: MIOS_USER, MIOS_HOSTNAME, MIOS_PASSWORD_HASH, MIOS_FLATPAKS, BASE_IMAGE" "INFO"

try {
    $buildOutput = & podman build @buildArgs 2>&1
    $buildOutput | ForEach-Object {
        Write-Host $_
        Add-Content -Path $BuildLog -Value $_
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "  +==================================================================+" -ForegroundColor Green
        Write-Host "  |  [OK] Build Complete                                             |" -ForegroundColor Green
        Write-Host "  +==================================================================+" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Image: localhost/mios:latest" -ForegroundColor Green
        Write-Host "  Image: localhost/mios:$MIOS_VERSION" -ForegroundColor Green
        Write-Host "  Log: $BuildLog" -ForegroundColor Gray
        Write-Host ""

        Write-Log "Build completed successfully" "OK"
    } else {
        throw "Build failed with exit code $LASTEXITCODE"
    }
} catch {
    Write-Host ""
    Write-Host "  +==================================================================+" -ForegroundColor Red
    Write-Host "  |  [FAIL] Build Failed                                             |" -ForegroundColor Red
    Write-Host "  +==================================================================+" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Error: $_" -ForegroundColor Red
    Write-Host "  Log: $BuildLog" -ForegroundColor Gray
    Write-Host ""

    Write-Log "Build failed: $_" "FAIL"
    exit 1
}

# ============================================================================
# Post-Build Actions
# ============================================================================

Write-Host "  Post-Build Actions:" -ForegroundColor Yellow
Write-Host ""

# Verify image exists
$imageCheck = & podman images localhost/mios:latest --format "{{.Repository}}:{{.Tag}}" 2>$null
if ($imageCheck) {
    Write-Host "  [OK] Image verification passed" -ForegroundColor Green
    Write-Log "Image verification passed" "OK"
} else {
    Write-Host "  [WARN] Image not found in podman images list" -ForegroundColor Yellow
    Write-Log "Image verification warning" "WARN"
}

# Show next steps
Write-Host ""
Write-Host "  +==================================================================+" -ForegroundColor Cyan
Write-Host "  |  Next Steps                                                      |" -ForegroundColor Cyan
Write-Host "  +==================================================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Test the image:" -ForegroundColor White
Write-Host "     podman run -it localhost/mios:latest" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Export to ISO (requires bootc-image-builder):" -ForegroundColor White
Write-Host "     # (Run from main MiOS repo)" -ForegroundColor Gray
Write-Host "     just iso" -ForegroundColor Gray
Write-Host ""
Write-Host "  3. Push to registry:" -ForegroundColor White
Write-Host "     podman push localhost/mios:latest ghcr.io/yourusername/mios:$MIOS_VERSION" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. Rebuild with different config:" -ForegroundColor White
Write-Host "     notepad `$env:APPDATA\MiOS\registry.toml" -ForegroundColor Gray
Write-Host "     .\mios-build-local.ps1" -ForegroundColor Gray
Write-Host ""

Write-Log "Build session complete" "INFO"
