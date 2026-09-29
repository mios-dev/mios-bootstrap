# tests/test_cat_staging.ps1
# Two-sided unit and integration tests for MiOS-Cat OCI data staging (Task T-261).
# Verifies positive controls (large disk stages OCI archive, extracts layout, small disk skips MiOS-Data)
# and negative controls (invalid media path, insufficient disk space, corrupted OCI archive).

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

$testRoot = Join-Path $PSScriptRoot "..\field"
$libPath = Join-Path $testRoot "lib\MiOS-Cat.psm1"

if (-not (Test-Path -LiteralPath $libPath)) {
    Write-Error "MiOS-Cat.psm1 not found at $libPath"
    exit 1
}

Import-Module (Resolve-Path $libPath) -Force

$passedCount = 0
$failedCount = 0

function Assert-Condition {
    param(
        [string]$TestName,
        [bool]$Condition,
        [string]$Details = ""
    )
    if ($Condition) {
        Write-Host "  [+] PASS: $TestName" -ForegroundColor Green
        $script:passedCount++
    } else {
        Write-Host "  [!] FAIL: $TestName" -ForegroundColor Red
        if ($Details) {
            Write-Host "      Details: $Details" -ForegroundColor Yellow
        }
        $script:failedCount++
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  MiOS-Cat OCI Staging & Field Verification Tests (T-261) " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# Test Suite 1: Positive Control -- Large Removable Media (>= 512 GB)
# -------------------------------------------------------------------------
Write-Host "`n[Suite 1] Positive Control: Large disk (>= 512GB) stages Repo + Data + OCI Layout" -ForegroundColor Yellow
$tempDrive1 = Join-Path ([System.IO.Path]::GetTempPath()) ("mios_test_large_" + [System.Guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Force -Path $tempDrive1

try {
    $res1 = Invoke-MiOSCatStage -DriveLetter $tempDrive1 -SimulatedDiskSizeGB 512 -SimulatedFreeSpaceGB 100 -Extract
    Assert-Condition "Stage returns success ($res1)" ($res1 -eq $true)
    Assert-Condition "Global LASTEXITCODE is 0" ($global:LASTEXITCODE -eq 0)

    # Verify MiOS-Repo shadow config
    $repoDir = Join-Path $tempDrive1 "MiOS-Repo"
    Assert-Condition "MiOS-Repo directory exists" (Test-Path -LiteralPath $repoDir)
    Assert-Condition "MiOS-Repo/mios.toml exists" (Test-Path -LiteralPath (Join-Path $repoDir "mios.toml"))
    Assert-Condition "MiOS-Repo/repos exists" (Test-Path -LiteralPath (Join-Path $repoDir "repos"))

    # Verify MiOS-Data bulk store
    $dataDir = Join-Path $tempDrive1 "MiOS-Data"
    $imagesDir = Join-Path $dataDir "images"
    $modelsDir = Join-Path $dataDir "models"
    $stagedTar = Join-Path $imagesDir "mios-latest.tar"
    $manifestPath = Join-Path $dataDir "manifest.json"

    Assert-Condition "MiOS-Data directory exists on 512GB+ disk" (Test-Path -LiteralPath $dataDir)
    Assert-Condition "MiOS-Data/images exists" (Test-Path -LiteralPath $imagesDir)
    Assert-Condition "MiOS-Data/models exists" (Test-Path -LiteralPath $modelsDir)
    Assert-Condition "Staged OCI archive (mios-latest.tar) exists" (Test-Path -LiteralPath $stagedTar)
    Assert-Condition "Staged OCI archive size > 0" ((Get-Item -LiteralPath $stagedTar).Length -gt 0)

    # Verify extracted OCI Image Layout
    $extractDir = Join-Path $imagesDir "extracted"
    Assert-Condition "OCI extracted directory exists" (Test-Path -LiteralPath $extractDir)
    Assert-Condition "Extracted oci-layout exists" (Test-Path -LiteralPath (Join-Path $extractDir "oci-layout"))
    Assert-Condition "Extracted index.json exists" (Test-Path -LiteralPath (Join-Path $extractDir "index.json"))
    Assert-Condition "Extracted blobs directory exists" (Test-Path -LiteralPath (Join-Path $extractDir "blobs"))

    # Verify manifest.json
    Assert-Condition "MiOS-Data/manifest.json exists" (Test-Path -LiteralPath $manifestPath)
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Assert-Condition "manifest.json has gate_passed=true" ($manifest.gate_passed -eq $true)
        Assert-Condition "manifest.json specifies disk_size_gb=512" ($manifest.disk_size_gb -eq 512)
        Assert-Condition "manifest.json has oci_archive with sha256" (-not [string]::IsNullOrEmpty($manifest.oci_archive.sha256))
        Assert-Condition "manifest.json has oci_archive.extracted=true" ($manifest.oci_archive.extracted -eq $true)
    }

    # Verify media layout check
    $verifyPass = Invoke-MiOSCatVerify -DriveLetter $tempDrive1 -MinDiskGB 512
    Assert-Condition "Invoke-MiOSCatVerify passes on valid 512GB media" ($verifyPass -eq $true)
} finally {
    if (Test-Path -LiteralPath $tempDrive1) {
        Remove-Item -LiteralPath $tempDrive1 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------------
# Test Suite 2: Positive Control -- Small Removable Media (< 512 GB)
# -------------------------------------------------------------------------
Write-Host "`n[Suite 2] Positive Control: Small disk (< 512GB) stages Repo and SKIPS MiOS-Data per T-261" -ForegroundColor Yellow
$tempDrive2 = Join-Path ([System.IO.Path]::GetTempPath()) ("mios_test_small_" + [System.Guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Force -Path $tempDrive2

try {
    $res2 = Invoke-MiOSCatStage -DriveLetter $tempDrive2 -SimulatedDiskSizeGB 64 -SimulatedFreeSpaceGB 30
    Assert-Condition "Stage returns success on small disk ($res2)" ($res2 -eq $true)
    Assert-Condition "Global LASTEXITCODE is 0" ($global:LASTEXITCODE -eq 0)

    # Verify MiOS-Repo shadow config
    $repoDir2 = Join-Path $tempDrive2 "MiOS-Repo"
    Assert-Condition "MiOS-Repo directory exists on small stick" (Test-Path -LiteralPath $repoDir2)
    Assert-Condition "MiOS-Repo/mios.toml exists on small stick" (Test-Path -LiteralPath (Join-Path $repoDir2 "mios.toml"))

    # T-261 Core Invariant: MiOS-Data MUST be skipped on small disks
    $dataDir2 = Join-Path $tempDrive2 "MiOS-Data"
    $dataAbsent = -not (Test-Path -LiteralPath $dataDir2)
    Assert-Condition "T-261 Invariant: MiOS-Data is SKIPPED on <512GB disk" $dataAbsent

    # Verify media layout check
    $verifySmall = Invoke-MiOSCatVerify -DriveLetter $tempDrive2 -MinDiskGB 512
    Assert-Condition "Invoke-MiOSCatVerify passes on valid small media layout" ($verifySmall -eq $true)
} finally {
    if (Test-Path -LiteralPath $tempDrive2) {
        Remove-Item -LiteralPath $tempDrive2 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------------
# Test Suite 3: Negative Control -- Invalid / Non-Existent Target Media
# -------------------------------------------------------------------------
Write-Host "`n[Suite 3] Negative Control: Invalid / Non-Existent Media aborts with explicit error" -ForegroundColor Yellow
$nonExistentPath = "Z:\NonExistentDrive_T261_" + [System.Guid]::NewGuid().ToString("N")
$errOutput1 = $null

$res3 = Invoke-MiOSCatStage -DriveLetter $nonExistentPath -ErrorVariable errOutput1 2>$null
Assert-Condition "Stage returns failure ($res3 = false)" ($res3 -eq $false)
Assert-Condition "Global LASTEXITCODE is non-zero (1)" ($global:LASTEXITCODE -eq 1)

$layoutCheckBad = Test-MiOSMediaLayout -TargetPath $nonExistentPath 2>$null
Assert-Condition "Test-MiOSMediaLayout returns false for non-existent path" ($layoutCheckBad -eq $false)

# -------------------------------------------------------------------------
# Test Suite 4: Negative Control -- Insufficient Disk Space
# -------------------------------------------------------------------------
Write-Host "`n[Suite 4] Negative Control: Insufficient disk space aborts cleanly with explicit error" -ForegroundColor Yellow
$tempDrive4 = Join-Path ([System.IO.Path]::GetTempPath()) ("mios_test_nospace_" + [System.Guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Force -Path $tempDrive4

try {
    # Simulate 512GB total drive but only 0.2GB free (less than 10GB required)
    $res4 = Invoke-MiOSCatStage -DriveLetter $tempDrive4 -SimulatedDiskSizeGB 512 -SimulatedFreeSpaceGB 0.2 2>$null
    Assert-Condition "Stage returns failure when space is insufficient ($res4 = false)" ($res4 -eq $false)
    Assert-Condition "Global LASTEXITCODE is non-zero (1) on insufficient space" ($global:LASTEXITCODE -eq 1)

    # MiOS-Data should not have been created
    $dataDir4 = Join-Path $tempDrive4 "MiOS-Data"
    Assert-Condition "MiOS-Data was NOT created due to space abort" (-not (Test-Path -LiteralPath $dataDir4))
} finally {
    if (Test-Path -LiteralPath $tempDrive4) {
        Remove-Item -LiteralPath $tempDrive4 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------------
# Test Suite 5: Negative Control -- Corrupted OCI Archive Extraction
# -------------------------------------------------------------------------
Write-Host "`n[Suite 5] Negative Control: Corrupted / invalid OCI archive fails layout verification" -ForegroundColor Yellow
$corruptedTar = Join-Path ([System.IO.Path]::GetTempPath()) ("corrupted_oci_" + [System.Guid]::NewGuid().ToString("N") + ".tar")
$corruptedExtract = Join-Path ([System.IO.Path]::GetTempPath()) ("corrupted_extract_" + [System.Guid]::NewGuid().ToString("N"))

try {
    # Create invalid tar (arbitrary text payload missing oci-layout and index.json)
    $tempBogusDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bogus_src_" + [System.Guid]::NewGuid().ToString("N"))
    $null = New-Item -ItemType Directory -Force -Path $tempBogusDir
    "this is not an oci archive" | Out-File -FilePath (Join-Path $tempBogusDir "not-oci.txt") -Encoding ascii
    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        & tar.exe -cf $corruptedTar -C $tempBogusDir not-oci.txt 2>&1 | Out-Null
    } else {
        [System.IO.File]::WriteAllText($corruptedTar, "corrupted tar bytes")
    }
    Remove-Item -LiteralPath $tempBogusDir -Recurse -Force -ErrorAction SilentlyContinue

    $extractRes = Expand-MiOSOCIImage -ArchiveFilePath $corruptedTar -DestinationPath $corruptedExtract 2>$null
    Assert-Condition "Expand-MiOSOCIImage fails on corrupted archive ($extractRes = false)" ($extractRes -eq $false)
    Assert-Condition "Global LASTEXITCODE is non-zero (1) on corrupted archive" ($global:LASTEXITCODE -eq 1)
} finally {
    if (Test-Path -LiteralPath $corruptedTar) { Remove-Item -LiteralPath $corruptedTar -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $corruptedExtract) { Remove-Item -LiteralPath $corruptedExtract -Recurse -Force -ErrorAction SilentlyContinue }
}

# -------------------------------------------------------------------------
# Test Suite 6: CLI Parity & Shim Invocation (cat/MiOS-Cat.ps1 and field/MiOS-Cat.ps1)
# -------------------------------------------------------------------------
Write-Host "`n[Suite 6] CLI Invocation Parity: cat/MiOS-Cat.ps1 and field/MiOS-Cat.ps1" -ForegroundColor Yellow
$tempDrive6 = Join-Path ([System.IO.Path]::GetTempPath()) ("mios_test_cli_" + [System.Guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Force -Path $tempDrive6

try {
    $cliScript = Join-Path $PSScriptRoot "..\field\MiOS-Cat.ps1"
    $shimScript = Join-Path $PSScriptRoot "..\cat\MiOS-Cat.ps1"

    Assert-Condition "field/MiOS-Cat.ps1 exists" (Test-Path -LiteralPath $cliScript)
    Assert-Condition "cat/MiOS-Cat.ps1 exists" (Test-Path -LiteralPath $shimScript)

    # Test field/MiOS-Cat.ps1 stage with -NoElevate
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $cliScript stage -DriveLetter $tempDrive6 -SimulatedDiskSizeGB 512 -SimulatedFreeSpaceGB 50 -NoElevate 2>&1 | Out-Null
    Assert-Condition "field/MiOS-Cat.ps1 stage executed with exit code 0" ($LASTEXITCODE -eq 0)

    # Test cat/MiOS-Cat.ps1 verify
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $shimScript verify -DriveLetter $tempDrive6 -MinDiskGB 512 2>&1 | Out-Null
    Assert-Condition "cat/MiOS-Cat.ps1 verify executed with exit code 0" ($LASTEXITCODE -eq 0)
} finally {
    if (Test-Path -LiteralPath $tempDrive6) {
        Remove-Item -LiteralPath $tempDrive6 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Test Summary: Passed = $passedCount, Failed = $failedCount" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failedCount -gt 0) {
    exit 1
} else {
    exit 0
}
