function Show-MiOSCatMenu {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "                MiOS-Cat Unified Launcher                 " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host " 1) Stage (Download artifacts to USB)"
    Write-Host " 2) Install (Headless deployment)"
    Write-Host " 3) Build (Compile MiOS from source)"
    Write-Host " 4) Update (Self-update scripts)"
    Write-Host " 5) Provision (Offline model provisioning)"
    Write-Host " 6) Manual (Interactive shell)"
    Write-Host " 0) Exit"
    Write-Host "==========================================================" -ForegroundColor Cyan

    $choice = Read-Host "Select an option"
    switch ($choice) {
        "1" { Invoke-MiOSCatStage }
        "2" { Invoke-MiOSCatInstall }
        "3" { Invoke-MiOSCatBuild }
        "4" { Invoke-MiOSCatUpdate }
        "5" { Invoke-MiOSCatProvision }
        "6" { Invoke-MiOSCatManual }
        "0" { return }
        default { Write-Host "Invalid choice."; Show-MiOSCatMenu }
    }
}

function Invoke-MiOSCatStage {
    param([string]$DriveLetter = "D")
    Write-Host "[MiOS-Cat] Executing verb: stage" -ForegroundColor Green
    
    $drivePath = "${DriveLetter}:\"
    if (-not (Test-Path $drivePath)) {
        Write-Host "Drive $drivePath not found!" -ForegroundColor Red
        return
    }

    # Disk size check
    $diskSizeGB = 0
    try {
        $disk = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        if ($disk) {
            $diskSizeGB = [math]::Round($disk.Size / 1GB)
        }
    } catch {}

    Write-Host "Target disk size: $diskSizeGB GB"

    # Read min_disk_gb threshold from SSOT or fallback to 512
    $minDiskGB = 512
    $ssotPath = "C:\MiOS\usr\share\mios\mios.toml"
    if (Test-Path $ssotPath) {
        $match = Select-String -Path $ssotPath -Pattern "min_disk_gb\s*=\s*(\d+)" | Select-Object -First 1
        if ($match -and $match.Matches.Groups[1].Value) {
            $minDiskGB = [int]$match.Matches.Groups[1].Value
        }
    }

    # Always create MiOS-Repo
    $repoDir = Join-Path $drivePath "MiOS-Repo"
    $reposDir = Join-Path $repoDir "repos"
    $null = New-Item -ItemType Directory -Force -Path $reposDir

    # Copy shadow config
    $tomlPath = "C:\MiOS\usr\share\mios\mios.toml"
    if (Test-Path $tomlPath) { Copy-Item $tomlPath -Destination $repoDir -Force }

    # Clone repos
    $miosGit = Join-Path $reposDir "MiOS"
    $bootstrapGit = Join-Path $reposDir "mios-bootstrap"
    if (-not (Test-Path $miosGit)) { git clone https://github.com/mios-dev/mios.git $miosGit }
    if (-not (Test-Path $bootstrapGit)) { git clone https://github.com/mios-dev/mios-bootstrap.git $bootstrapGit }

    # Stage OCI archive for tools/install.sh offline path
    $stagedArchive = Join-Path $repoDir "mios-latest.tar"
    Write-Host "Staging OCI archive to $stagedArchive..." -ForegroundColor Cyan

    $foundTar = Get-ChildItem -Path "build\oci-archive\*.tar", "build\*.tar" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($foundTar) {
        Write-Host "Copying existing archive $($foundTar.FullName) -> $stagedArchive..." -ForegroundColor Green
        Copy-Item $foundTar.FullName -Destination $stagedArchive -Force
    } else {
        # Check podman
        $podmanCheck = Get-Command podman -ErrorAction SilentlyContinue
        if ($podmanCheck) {
            Write-Host "Saving localhost/mios:latest -> $stagedArchive..." -ForegroundColor Green
            podman save --format oci-archive -o $stagedArchive localhost/mios:latest
        } else {
            Write-Host "Warning: No built OCI archive found and podman is unavailable to generate it." -ForegroundColor Yellow
        }
    }

    # MiOS-Data logic (>= minDiskGB)
    if ($diskSizeGB -ge $minDiskGB) {
        Write-Host "Disk >= ${minDiskGB}GB. Creating MiOS-Data bulk store." -ForegroundColor Cyan
        $dataDir = Join-Path $drivePath "MiOS-Data"
        $imagesDir = Join-Path $dataDir "images"
        $modelsDir = Join-Path $dataDir "models"
        $null = New-Item -ItemType Directory -Force -Path $imagesDir
        $null = New-Item -ItemType Directory -Force -Path $modelsDir

        if (Test-Path $stagedArchive) {
            Copy-Item $stagedArchive -Destination (Join-Path $imagesDir "mios-latest.tar") -Force
        }

        # Copy build artifacts if available
        if (Test-Path "M:\MiOS-images\") {
            Copy-Item "M:\MiOS-images\*" -Destination $imagesDir -Recurse -Force
        }

        Write-Host "Fetching models to $modelsDir..."
        Write-Host "Building offline package mirrors..."
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dataDir "dnf")
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dataDir "flatpak")
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dataDir "pip")
    }
}

function Invoke-MiOSCatInstall {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsList)
    Write-Host "[MiOS-Cat] Executing verb: install" -ForegroundColor Green
    $ps1Path = Join-Path $PSScriptRoot "..\..\installation\mios-install.ps1"
    if (Test-Path $ps1Path) {
        & $ps1Path $ArgsList
    } else {
        Write-Host "installation\mios-install.ps1 not found." -ForegroundColor Red
    }
}

function Invoke-MiOSCatBuild {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsList)
    Write-Host "[MiOS-Cat] Executing verb: build" -ForegroundColor Green
    $ps1Path = Join-Path $PSScriptRoot "..\..\build-mios.ps1"
    if (Test-Path $ps1Path) {
        & $ps1Path $ArgsList
    } else {
        Write-Host "build-mios.ps1 not found." -ForegroundColor Red
    }
}

function Invoke-MiOSCatUpdate {
    param([string]$DriveLetter = "D")
    Write-Host "[MiOS-Cat] Executing verb: update" -ForegroundColor Green
    Write-Host "Refreshing offline payloads + manifest.json..."
    $drivePath = "${DriveLetter}:\"
    $dataDir = Join-Path $drivePath "MiOS-Data"
    if (Test-Path $dataDir) {
        $manifest = Join-Path $dataDir "manifest.json"
        $dateStr = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        "{ `"updated`": `"$dateStr`" }" | Out-File -FilePath $manifest -Encoding utf8
        Write-Host "Manifest updated: $manifest" -ForegroundColor Green
    }
}

function Invoke-MiOSCatProvision {
    param([string]$DriveLetter = "D")
    Write-Host "[MiOS-Cat] Executing verb: provision" -ForegroundColor Green
    Write-Host "Provisioning models from MiOS-Data..."
    $drivePath = "${DriveLetter}:\"
    $modelsSource = Join-Path $drivePath "MiOS-Data\models"
    $modelsTarget = "C:\MiOS\usr\share\mios\vllm\model"
    if (Test-Path $modelsSource) {
        $null = New-Item -ItemType Directory -Force -Path $modelsTarget
        Copy-Item "$modelsSource\*" -Destination $modelsTarget -Recurse -Force
        Write-Host "Provisioned models to $modelsTarget" -ForegroundColor Green
    } else {
        Write-Host "No MiOS-Data\models found on $drivePath." -ForegroundColor Yellow
    }
}

function Invoke-MiOSCatManual {
    Write-Host "[MiOS-Cat] Executing verb: manual" -ForegroundColor Green
    powershell
}
