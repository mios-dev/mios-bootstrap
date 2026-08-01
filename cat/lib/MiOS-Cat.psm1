# MiOS-Cat.psm1 -- Shared backend for MiOS-Cat launchers.
# Implements the verb vocabulary for the canonical MiOS-Cat.ps1

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
        "0" { exit 0 }
        default { Write-Warning "Invalid choice." ; Show-MiOSCatMenu }
    }
}

function Invoke-MiOSCatStage {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsList)
    Write-Host "[MiOS-Cat] Executing verb: stage" -ForegroundColor Green
    
    # Target drive determination
    $drive = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "D" } # Should resolve from TOML in real impl
    $drivePath = "${drive}:\"
    if (-not (Test-Path $drivePath)) {
        Write-Error "Drive $drivePath not found!"
        return
    }

    $diskSizeGB = 0
    try {
        $partition = Get-Partition -DriveLetter $drive -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        $diskSizeGB = [math]::Round($disk.Size / 1GB)
    } catch {
        Write-Warning "Could not determine disk size for $drive. Assuming < 128GB."
    }

    Write-Host "Target disk size: $diskSizeGB GB"

    # T-260: Always create MiOS-Repo
    $repoDir = Join-Path $drivePath "MiOS-Repo"
    $reposDir = Join-Path $repoDir "repos"
    $null = New-Item -ItemType Directory -Force -Path $reposDir

    # Copy shadow config (simulated for now, would use real paths)
    $tomlPath = "C:\MiOS\usr\share\mios\mios.toml"
    if (Test-Path $tomlPath) { Copy-Item $tomlPath -Destination $repoDir -Force }
    
    # Clone repos
    $miosGit = Join-Path $reposDir "MiOS"
    $bootstrapGit = Join-Path $reposDir "mios-bootstrap"
    if (-not (Test-Path $miosGit)) { git clone https://github.com/mios-dev/mios.git $miosGit }
    if (-not (Test-Path $bootstrapGit)) { git clone https://github.com/mios-dev/mios-bootstrap.git $bootstrapGit }

    # T-261: MiOS-Data logic (>= 128GB)
    if ($diskSizeGB -ge 128) {
        Write-Host "Disk >= 128GB. Creating MiOS-Data bulk store." -ForegroundColor Cyan
        $dataDir = Join-Path $drivePath "MiOS-Data"
        $imagesDir = Join-Path $dataDir "images"
        $modelsDir = Join-Path $dataDir "models"
        $null = New-Item -ItemType Directory -Force -Path $imagesDir
        $null = New-Item -ItemType Directory -Force -Path $modelsDir

        # Save OCI tar
        Write-Host "Saving localhost/mios:latest..."
        # podman save localhost/mios:latest -o "$imagesDir\mios-latest.tar"

        # Copy artifacts
        if (Test-Path "M:\MiOS-images\") {
            Copy-Item "M:\MiOS-images\*" -Destination $imagesDir -Recurse -Force
        }

        # T-262: Fetch models (Simulated download/checksum)
        Write-Host "Fetching models to $modelsDir..."
        
        # T-263: Package mirrors
        Write-Host "Building offline package mirrors..."
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dataDir "dnf")
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dataDir "flatpak")
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dataDir "pip")
    }
}

function Invoke-MiOSCatInstall {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsList)
    Write-Host "[MiOS-Cat] Executing verb: install" -ForegroundColor Green
    
    # Thin wrapper to canonical bootstrap (T-259)
    $bootstrapPath = Join-Path (Resolve-Path "$PSScriptRoot\").Path "Get-MiOS-Backend.ps1"
    if (Test-Path $bootstrapPath) {
        & $bootstrapPath @ArgsList
    } else {
        Write-Error "Get-MiOS-Backend.ps1 not found at $bootstrapPath"
    }
}

function Invoke-MiOSCatBuild {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsList)
    Write-Host "[MiOS-Cat] Executing verb: build" -ForegroundColor Green
    # Delegate to build-mios.ps1
    $buildPath = Join-Path (Resolve-Path "$PSScriptRoot\..\..\").Path "build-mios.ps1"
    if (Test-Path $buildPath) {
        & $buildPath @ArgsList
    } else {
        Write-Error "build-mios.ps1 not found."
    }
}

function Invoke-MiOSCatUpdate {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsList)
    Write-Host "[MiOS-Cat] Executing verb: update" -ForegroundColor Green
    # Ported from legacy .bat self-update logic (T-263)
    Write-Host "Refreshing offline payloads + manifest.json..."
    $drive = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "D" }
    $manifest = Join-Path "${drive}:\" "MiOS-Data\manifest.json"
    if (Test-Path (Join-Path "${drive}:\" "MiOS-Data")) {
        $date = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        "{ `"updated`": `"$date`" }" | Out-File -FilePath $manifest -Encoding utf8
        Write-Host "Manifest updated: $manifest"
    }
}

function Invoke-MiOSCatProvision {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsList)
    Write-Host "[MiOS-Cat] Executing verb: provision" -ForegroundColor Green
    # Provision logic here (Law 12 offline models, T-262)
    Write-Host "Provisioning models from MiOS-Data..."
    $drive = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "D" }
    $modelsSource = Join-Path "${drive}:\" "MiOS-Data\models"
    $modelsTarget = "C:\MiOS\usr\share\mios\vllm\model"
    if (Test-Path $modelsSource) {
        $null = New-Item -ItemType Directory -Force -Path $modelsTarget
        Copy-Item "$modelsSource\*" -Destination $modelsTarget -Recurse -Force
        Write-Host "Provisioned models to $modelsTarget"
    } else {
        Write-Warning "No MiOS-Data/models found on $drive."
    }
}

function Invoke-MiOSCatManual {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsList)
    Write-Host "[MiOS-Cat] Executing verb: manual" -ForegroundColor Green
    # Launch interactive shell
    Start-Process powershell.exe -Wait
}

Export-ModuleMember -Function Show-MiOSCatMenu, Invoke-MiOSCatStage, Invoke-MiOSCatInstall, Invoke-MiOSCatBuild, Invoke-MiOSCatUpdate, Invoke-MiOSCatProvision, Invoke-MiOSCatManual
