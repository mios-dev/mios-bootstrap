# field/lib/MiOS-Cat.psm1 -- shared backend for MiOS-Cat.
# Implements T-261: Separate MiOS-Data bulk store staging on disks meeting min_disk_gb gate.
# Folded losslessly with installation/mios-common.ps1 (Task T-1118).

$commonPath = Join-Path $PSScriptRoot "..\..\installation\mios-common.ps1"
if (Test-Path -LiteralPath $commonPath) {
    . $commonPath
}


function Show-MiOSCatMenu {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "                MiOS-Cat Unified Launcher                 " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host " 1) Stage (Download artifacts to USB)"
    Write-Host " 2) Install (Headless deployment)"
    Write-Host " 3) Build (Compile MiOS from source)"
    Write-Host " 4) Update (Self-update scripts)"
    Write-Host " 5) Provision (Offline model provisioning)"
    Write-Host " 6) Verify (Validate media layout and artifacts)"
    Write-Host " 7) Manual (Interactive shell)"
    Write-Host " 8) WSL Import (Import pre-built rootfs/VHDX)"
    Write-Host " 0) Exit"
    Write-Host "==========================================================" -ForegroundColor Cyan

    $choice = Read-Host "Select an option"
    switch ($choice) {
        "1" { Invoke-MiOSCatStage }
        "2" { Invoke-MiOSCatInstall }
        "3" { Invoke-MiOSCatBuild }
        "4" { Invoke-MiOSCatUpdate }
        "5" { Invoke-MiOSCatProvision }
        "6" { Invoke-MiOSCatVerify }
        "7" { Invoke-MiOSCatManual }
        "8" { Invoke-MiOSCatInstall @('-Target', 'wsl') }
        "0" { return }
        default { Write-Host "Invalid choice."; Show-MiOSCatMenu }
    }
}

# Stage and verify are implemented once in installation/mios-common.ps1.
# This field module exports their compatibility names for existing callers.

function Invoke-MiOSCatInstall {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsList)
    Write-Host "[MiOS-Cat] Executing verb: install" -ForegroundColor Green
    $ps1Path = Join-Path $PSScriptRoot "..\..\installation\mios-install.ps1"
    if (Test-Path $ps1Path) {
        $psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        if ($ArgsList -and $ArgsList.Count -gt 0) {
            & $psBin -NoProfile -ExecutionPolicy Bypass -File $ps1Path @ArgsList
        } else {
            & $psBin -NoProfile -ExecutionPolicy Bypass -File $ps1Path
        }
    } else {
        Write-Host "installation\mios-install.ps1 not found." -ForegroundColor Red
    }
}

function Invoke-MiOSCatBuild {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsList)
    Write-Host "[MiOS-Cat] Executing verb: build" -ForegroundColor Green
    $ps1Path = Join-Path $PSScriptRoot "..\..\build-mios.ps1"
    if (Test-Path $ps1Path) {
        $psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        if ($ArgsList -and $ArgsList.Count -gt 0) {
            & $psBin -NoProfile -ExecutionPolicy Bypass -File $ps1Path @ArgsList
        } else {
            & $psBin -NoProfile -ExecutionPolicy Bypass -File $ps1Path
        }
    } else {
        Write-Host "build-mios.ps1 not found." -ForegroundColor Red
    }
}

function Invoke-MiOSCatUpdate {
    param(
        [Parameter(Position = 0)]
        [string]$DriveLetter = "D"
    )
    Write-Host "[MiOS-Cat] Executing verb: update" -ForegroundColor Green
    Write-Host "Refreshing staged payloads and their manifest..."
    $cleanLetter = $DriveLetter.TrimEnd(':\')
    $drivePath = if ($DriveLetter.Contains('\') -or $DriveLetter.Contains('/')) { $DriveLetter } else { "${cleanLetter}:\" }
    $dataDir = Join-Path $drivePath "MiOS-Data"
    $archive = Join-Path $dataDir 'images/mios-latest.tar'
    if (Test-Path -LiteralPath $archive -PathType Leaf) {
        return Invoke-MiosStage -DriveLetter $DriveLetter -ArchivePath $archive
    }
    return Invoke-MiosStage -DriveLetter $DriveLetter
}

function Invoke-MiOSCatProvision {
    param(
        [Parameter(Position = 0)]
        [string]$DriveLetter = "D",
        [Parameter()]
        [string]$TargetDir = ""
    )
    Write-Host "[MiOS-Cat] Executing verb: provision" -ForegroundColor Green
    Write-Host "Provisioning models from MiOS-Data..."
    $cleanLetter = $DriveLetter.TrimEnd(':\')
    $drivePath = if ($DriveLetter.Contains('\') -or $DriveLetter.Contains('/')) { $DriveLetter } else { "${cleanLetter}:\" }
    $modelsSource = Join-Path $drivePath "MiOS-Data\models"
    $modelsTarget = if ($TargetDir) { $TargetDir } else { "C:\MiOS\usr\share\mios\vllm\model" }
    $inventoryPath = Join-Path $modelsSource 'models.json'
    if (-not (Test-Path -LiteralPath $inventoryPath)) {
        Write-Host "No model inventory found on $drivePath." -ForegroundColor Red
        $global:LASTEXITCODE = 1; return $false
    }
    try {
        $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
        if (@($inventory.catalog).Count -eq 0) { throw 'No model weights are staged' }
        foreach ($model in @($inventory.catalog)) {
            if ($model.name -match '[\\/]' -or $model.name -in @('.', '..')) { throw 'Invalid model name' }
            $source = Join-Path $modelsSource $model.name
            if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
                (Get-Item -LiteralPath $source).Length -ne [long]$model.size_bytes -or
                (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $model.sha256) { throw "Model checksum mismatch: $($model.name)" }
        }
        $null = New-Item -ItemType Directory -Force -Path $modelsTarget
        foreach ($model in @($inventory.catalog)) {
            Copy-Item -LiteralPath (Join-Path $modelsSource $model.name) -Destination $modelsTarget -Force -ErrorAction Stop
        }
        Write-Host "Provisioned $(@($inventory.catalog).Count) verified models to $modelsTarget" -ForegroundColor Green
        $global:LASTEXITCODE = 0; return $true
    } catch {
        Write-Host "Model provisioning failed: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1; return $false
    }
}

function Invoke-MiOSCatManual {
    Write-Host "[MiOS-Cat] Executing verb: manual" -ForegroundColor Green
    powershell
}

Export-ModuleMember -Function Show-MiOSCatMenu, `
    Invoke-MiOSCatStage, `
    Invoke-MiOSCatInstall, `
    Invoke-MiOSCatBuild, `
    Invoke-MiOSCatUpdate, `
    Invoke-MiOSCatProvision, `
    Invoke-MiOSCatVerify, `
    Invoke-MiOSCatManual, `
    Expand-MiOSOCIImage, `
    Test-MiOSMediaLayout, `
    New-MiOSOCIArchive
