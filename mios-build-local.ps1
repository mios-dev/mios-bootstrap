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

# Load password hash and GitHub credentials from secrets
if (Test-Path $MiosSecretsFile) {
    $secrets = Get-Content $MiosSecretsFile
    $MIOS_PASSWORD_HASH = ($secrets | Select-String "MIOS_PASSWORD_HASH=").ToString().Split('=')[1]

    # Extract GitHub credentials for private repo access
    $githubUserLine = $secrets | Select-String "GITHUB_USER="
    $githubTokenLine = $secrets | Select-String "GITHUB_TOKEN="

    if ($githubUserLine -and $githubTokenLine) {
        $GITHUB_USER = $githubUserLine.ToString().Split('=')[1]
        $GITHUB_TOKEN = $githubTokenLine.ToString().Split('=')[1]
    } else {
        Write-Log "ERROR: GitHub credentials not found in secrets.env" "FAIL"
        Write-Host "  [FAIL] GitHub credentials required to clone private MiOS repository" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Log "ERROR: secrets.env not found" "FAIL"
    exit 1
}

# ============================================================================
# Repository Setup
# ============================================================================

$MiosRepoDir = Join-Path $env:LOCALAPPDATA "MiOS\repo"
# Use authenticated URL for private repository
$MiosRepoUrl = "https://$($GITHUB_USER):$($GITHUB_TOKEN)@github.com/Kabuki94/MiOS.git"

if (-not (Test-Path $MiosRepoDir)) {
    Write-Log "Cloning MiOS repository..." "INFO"
    Write-Host "  Cloning MiOS repository to $MiosRepoDir..." -ForegroundColor Yellow

    $parentDir = Split-Path $MiosRepoDir -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    try {
        # Clone with authentication (output will not show token)
        git clone $MiosRepoUrl $MiosRepoDir 2>&1 | ForEach-Object {
            $line = $_.ToString()
            # Redact token from logs
            $line = $line -replace $GITHUB_TOKEN, "***TOKEN***"
            Write-Host $line
            Add-Content -Path $BuildLog -Value $line
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone failed with exit code $LASTEXITCODE"
        }
        Write-Log "Repository cloned successfully" "OK"
    } catch {
        Write-Log "Failed to clone repository: $_" "FAIL"
        Write-Host "  [FAIL] Could not clone MiOS repository" -ForegroundColor Red
        Write-Host "  Error: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Troubleshooting:" -ForegroundColor Yellow
        Write-Host "    1. Verify GitHub credentials are correct" -ForegroundColor Gray
        Write-Host "    2. Ensure PAT has 'repo' scope" -ForegroundColor Gray
        Write-Host "    3. Check network connectivity to GitHub" -ForegroundColor Gray
        exit 1
    }
} else {
    Write-Log "Repository already exists at $MiosRepoDir" "INFO"
    Write-Host "  Repository found at $MiosRepoDir" -ForegroundColor Gray

    # Optional: pull latest changes
    Write-Log "Updating repository..." "INFO"
    Push-Location $MiosRepoDir
    try {
        # Set remote URL with authentication
        git remote set-url origin $MiosRepoUrl 2>&1 | Out-Null
        git pull 2>&1 | ForEach-Object {
            $line = $_.ToString()
            # Redact token from logs
            $line = $line -replace $GITHUB_TOKEN, "***TOKEN***"
            Add-Content -Path $BuildLog -Value $line
        }
        Write-Log "Repository updated" "OK"
    } catch {
        Write-Log "Warning: Could not update repository: $_" "WARN"
    }
    Pop-Location
}

# Verify Containerfile exists
$containerfile = Join-Path $MiosRepoDir "Containerfile"
if (-not (Test-Path $containerfile)) {
    Write-Log "ERROR: Containerfile not found at $containerfile" "FAIL"
    Write-Host "  [FAIL] Containerfile not found in repository" -ForegroundColor Red
    exit 1
}

Write-Log "Containerfile verified at $containerfile" "OK"

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
    "-f", $containerfile,
    $MiosRepoDir
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
Write-Host "     cd $MiosRepoDir" -ForegroundColor Gray
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
