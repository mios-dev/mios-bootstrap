$ErrorActionPreference = "Stop"

# --- Auto-Elevation ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Relaunching as Administrator..." -ForegroundColor Cyan
    
    $args = "-NoProfile -ExecutionPolicy Bypass"
    if ($MyInvocation.MyCommand.Path) {
        $args += " -File `"$($MyInvocation.MyCommand.Path)`""
    } else {
        # Handle irm | iex scenario by relaunching the bootstrap command
        $command = "irm https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/bootstrap.ps1 | iex"
        $args += " -Command `"$command`""
    }

    # Pass the token and env to the elevated process if it exists
    $envHash = @{ GHCR_TOKEN = $env:GHCR_TOKEN }
    Get-ChildItem Env: | Where-Object { $_.Name -match "^MIOS_" } | ForEach-Object {
        $envHash[$_.Name] = $_.Value
    }

    Start-Process powershell.exe -ArgumentList "$args" -Verb RunAs -Environment $envHash
    return
}

$RepoUrl = "https://github.com/Kabuki94/MiOS-bootstrap"
$MiosAppDir = Join-Path $env:LOCALAPPDATA "MiOS"
$MiosRepoDir = if ($env:MIOS_DIR) { $env:MIOS_DIR } else { Join-Path $MiosAppDir "repo" }
$MiosBuildsDir = if ($env:MIOS_BUILDS_DIR) { $env:MIOS_BUILDS_DIR } else { Join-Path $MiosAppDir "builds" }

# --- Credential Handling ---
if (-not $env:GHCR_TOKEN) {
    Write-Host "  Checking for GitHub credentials..." -ForegroundColor Gray
    $token = Read-Host -MaskInput -Prompt "  GitHub Personal Access Token (requires 'repo' scope, press enter to skip)"
    if ($token) { $env:GHCR_TOKEN = $token }
}

function Invoke-SecureWebRequest {
    param([string]$Uri, [string]$OutFile)
    $params = @{ Uri = $Uri; UseBasicParsing = $true }
    if ($env:GHCR_TOKEN -and ($Uri -match "github\.com" -or $Uri -match "ghcr\.io")) {
        $params.Headers = @{ Authorization = "Bearer $($env:GHCR_TOKEN)" }
    }
    if ($OutFile) { $params.OutFile = $OutFile }
    return Invoke-WebRequest @params
}

# Read version from repo VERSION file, fallback to hardcoded
$Ver = "v0.1.3"
try { $Ver = "v" + (Invoke-SecureWebRequest -Uri "$RepoUrl/raw/main/VERSION").Content.Trim() } catch { Write-Verbose "Failed to fetch version: $_" }

Write-Host ""
Write-Host "  +==============================================================+" -ForegroundColor Cyan
Write-Host ("  |  MiOS {0} -- MiOS Builder (Windows) " -f $Ver).PadRight(65) + "|" -ForegroundColor Cyan
Write-Host "  +==============================================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Repo:   $MiosRepoDir" -ForegroundColor Gray
Write-Host "  Builds: $MiosBuildsDir" -ForegroundColor Gray
Write-Host ""
Write-Host "  1) Run preflight check first (recommended)" -ForegroundColor White
Write-Host "  2) Clone repo + launch build (mios-build-local.ps1)" -ForegroundColor White
Write-Host "  3) Download build script only" -ForegroundColor White
Write-Host ""
$choice = Read-Host "  Choice [1-3]"
switch ($choice) {
    "1" {
        try {
            $tmp = "$env:TEMP\mios-preflight-$(Get-Random).ps1"
            Invoke-SecureWebRequest -Uri "$RepoUrl/raw/main/preflight.ps1" -OutFile $tmp
            & $tmp
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host "  Preflight failed: $_" -ForegroundColor Red
        }
    }
    "2" {
        if (-not (Test-Path $MiosRepoDir)) { New-Item -ItemType Directory -Path $MiosRepoDir -Force | Out-Null }
        
        if (Test-Path (Join-Path $MiosRepoDir ".git")) {
            Write-Host "  [OK] Repository found at $MiosRepoDir -- updating..." -ForegroundColor Cyan
            Push-Location $MiosRepoDir
            # Use --progress for localized TTY feedback
            git pull --rebase --progress
            Pop-Location
        }
        else {
            Write-Host "  Cloning $RepoUrl ..." -ForegroundColor Cyan
            # Use --progress for localized TTY feedback
            git clone --progress $RepoUrl $MiosRepoDir
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [X] Clone failed" -ForegroundColor Red
                return
            }
            Write-Host "  [OK] Repository cloned to $MiosRepoDir" -ForegroundColor Green
        }

        # Stage numbered build folder
        Write-Host "  Staging numbered build folder..." -ForegroundColor Cyan
        if (-not (Test-Path $MiosBuildsDir)) { New-Item -ItemType Directory -Path $MiosBuildsDir -Force | Out-Null }
        
        $buildFolders = Get-ChildItem $MiosBuildsDir -Directory -Filter "build-*"
        $lastBuild = 0
        if ($buildFolders) {
            $lastBuild = ($buildFolders.Name | ForEach-Object { $_ -replace "build-","" } | ForEach-Object { [int]$_ } | Sort-Object | Select-Object -Last 1)
        }
        $nextBuild = $lastBuild + 1
        $buildPath = Join-Path $MiosBuildsDir "build-$nextBuild"
        New-Item -ItemType Directory -Path $buildPath -Force | Out-Null

        Write-Host "  Copying repository to $buildPath ..." -ForegroundColor Cyan
        $items = Get-ChildItem -Path $MiosRepoDir -Recurse
        $totalItems = $items.Count
        $currentItem = 0
        foreach ($item in $items) {
            $currentItem++
            $percent = [int](($currentItem / $totalItems) * 100)
            Write-Progress -Activity "Staging Build v${Ver}" -Status "Copying: $($item.Name)" -PercentComplete $percent
            $dest = Join-Path $buildPath $item.FullName.Substring($MiosRepoDir.Length)
            $parent = Split-Path $dest -Parent
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            if (-not $item.PSIsContainer) { Copy-Item $item.FullName -Destination $dest -Force }
        }
        Write-Progress -Activity "Staging Build v${Ver}" -Completed

        Write-Host "  Launching build script from $buildPath ..." -ForegroundColor Cyan
        Push-Location $buildPath
        & .\mios-build-local.ps1
        Pop-Location
    }
    "3" {
        Invoke-SecureWebRequest -Uri "$RepoUrl/raw/main/mios-build-local.ps1" -OutFile "mios-build-local.ps1"
        Write-Host "  [OK] Saved. Run: .\mios-build-local.ps1" -ForegroundColor Green
    }
    default {
        Write-Host "  Invalid choice." -ForegroundColor Red
    }
}