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

function New-MiOSOCIArchive {
    param([string]$DestinationTarPath)
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("oci_tmp_" + [System.Guid]::NewGuid().ToString("N"))
    $null = New-Item -ItemType Directory -Force -Path $tmpDir
    $blobsDir = Join-Path $tmpDir "blobs\sha256"
    $null = New-Item -ItemType Directory -Force -Path $blobsDir

    # 1. oci-layout
    '{"imageLayoutVersion": "1.0.0"}' | Out-File -FilePath (Join-Path $tmpDir "oci-layout") -Encoding utf8 -NoNewline

    # 2. Config blob and manifest blob
    $configContent = '{"architecture":"amd64","os":"linux","rootfs":{"type":"layers","diff_ids":[]},"config":{}}'
    $configBytes = [System.Text.Encoding]::UTF8.GetBytes($configContent)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $configHash = -join ($sha.ComputeHash($configBytes) | ForEach-Object { '{0:x2}' -f $_ })
    [System.IO.File]::WriteAllBytes((Join-Path $blobsDir $configHash), $configBytes)

    $manifestContent = @"
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:$configHash",
    "size": $($configBytes.Length)
  },
  "layers": []
}
"@
    $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestContent)
    $manifestHash = -join ($sha.ComputeHash($manifestBytes) | ForEach-Object { '{0:x2}' -f $_ })
    [System.IO.File]::WriteAllBytes((Join-Path $blobsDir $manifestHash), $manifestBytes)

    # 3. index.json
    $indexContent = @"
{
  "schemaVersion": 2,
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:$manifestHash",
      "size": $($manifestBytes.Length),
      "annotations": {
        "org.opencontainers.image.ref.name": "latest"
      }
    }
  ]
}
"@
    $indexContent | Out-File -FilePath (Join-Path $tmpDir "index.json") -Encoding utf8 -NoNewline

    # Create tar
    $tarDir = Split-Path -Parent $DestinationTarPath
    if (-not (Test-Path -LiteralPath $tarDir)) { $null = New-Item -ItemType Directory -Force -Path $tarDir }
    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        & tar.exe -cf $DestinationTarPath -C $tmpDir oci-layout index.json blobs 2>&1 | Out-Null
    }
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Expand-MiOSOCIImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchiveFilePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )
    if (-not (Test-Path -LiteralPath $ArchiveFilePath)) {
        $global:LASTEXITCODE = 1
        return $false
    }
    $null = New-Item -ItemType Directory -Force -Path $DestinationPath
    try {
        if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
            & tar.exe -xf $ArchiveFilePath -C $DestinationPath 2>&1 | Out-Null
        }
        $hasLayout = Test-Path -LiteralPath (Join-Path $DestinationPath "oci-layout")
        $hasIndex = Test-Path -LiteralPath (Join-Path $DestinationPath "index.json")
        $hasBlobs = Test-Path -LiteralPath (Join-Path $DestinationPath "blobs")
        if ($hasLayout -and $hasIndex -and $hasBlobs) {
            $global:LASTEXITCODE = 0
            return $true
        } else {
            $global:LASTEXITCODE = 1
            return $false
        }
    } catch {
        $global:LASTEXITCODE = 1
        return $false
    }
}

function Test-MiOSMediaLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return $false
    }
    $repoDir = Join-Path $TargetPath "MiOS-Repo"
    if (-not (Test-Path -LiteralPath $repoDir)) {
        return $false
    }
    $dataDir = Join-Path $TargetPath "MiOS-Data"
    if (Test-Path -LiteralPath $dataDir) {
        if (-not (Test-Path -LiteralPath (Join-Path $dataDir "images"))) { return $false }
        if (-not (Test-Path -LiteralPath (Join-Path $dataDir "models"))) { return $false }
    }
    return $true
}

function Invoke-MiOSCatStage {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$DriveLetter = "D",

        [Parameter()]
        [int]$MinDiskGB = 0,

        [Parameter()]
        [int]$SimulatedDiskSizeGB = 0,

        [Parameter()]
        [double]$SimulatedFreeSpaceGB = 0,

        [Parameter()]
        [switch]$Extract
    )
    Write-Host "[MiOS-Cat] Executing verb: stage" -ForegroundColor Green

    $cleanLetter = $DriveLetter.TrimEnd(':\')
    $isPath = ($DriveLetter.Contains('\') -or $DriveLetter.Contains('/') -or (Test-Path -LiteralPath $DriveLetter))
    $drivePath = if ($isPath) { $DriveLetter } else { "${cleanLetter}:\" }

    if (-not (Test-Path -LiteralPath $drivePath)) {
        Write-Host "  [FAIL] Drive or directory $drivePath not found!" -ForegroundColor Red
        $global:LASTEXITCODE = 1
        return $false
    }

    # Resolve min_disk_gb threshold from parameter, environment, SSOT, or fallback to 512
    if ($MinDiskGB -le 0) {
        if ($env:MIOS_MIN_DISK_GB) {
            $parsedEnv = 0
            if ([int]::TryParse($env:MIOS_MIN_DISK_GB, [ref]$parsedEnv) -and $parsedEnv -gt 0) {
                $MinDiskGB = $parsedEnv
            }
        }
    }

    if ($MinDiskGB -le 0) {
        $candidatePaths = @(
            "C:\MiOS\usr\share\mios\mios.toml",
            "C:\MiOS\mios.toml",
            (Join-Path $PSScriptRoot "..\..\mios.toml"),
            (Join-Path $PSScriptRoot "..\..\usr\share\mios\mios.toml"),
            (Join-Path $PSScriptRoot "..\..\..\..\usr\share\mios\mios.toml"),
            "M:\usr\share\mios\mios.toml",
            "M:\etc\mios\mios.toml"
        )
        foreach ($ssotPath in $candidatePaths) {
            if ($ssotPath -and (Test-Path -LiteralPath $ssotPath)) {
                try {
                    $content = [System.IO.File]::ReadAllText($ssotPath)
                    $rxSec = '(?ms)^\s*\[(?:cat|field)\.data_partition\][ \t]*\r?\n(?<body>.*?)(?=^\s*\[|\z)'
                    $mSec = [regex]::Match($content, $rxSec)
                    if ($mSec.Success) {
                        $mKey = [regex]::Match($mSec.Groups['body'].Value, '(?m)^\s*min_disk_gb\s*=\s*(\d+)')
                        if ($mKey.Success) {
                            $MinDiskGB = [int]$mKey.Groups[1].Value
                            break
                        }
                    }
                    $mAny = [regex]::Match($content, '(?m)^\s*min_disk_gb\s*=\s*(\d+)')
                    if ($mAny.Success) {
                        $MinDiskGB = [int]$mAny.Groups[1].Value
                        break
                    }
                } catch {}
            }
        }
    }

    if ($MinDiskGB -le 0) {
        $MinDiskGB = 512
    }

    # Free space check (requires >= 10GB)
    $minRequiredFreeGB = 10
    $freeSpaceGB = 0.0
    if ($SimulatedFreeSpaceGB -gt 0) {
        $freeSpaceGB = $SimulatedFreeSpaceGB
    } else {
        try {
            $root = [System.IO.Path]::GetPathRoot((Resolve-Path $drivePath).Path)
            $driveInfo = [System.IO.DriveInfo]::new($root)
            $freeSpaceGB = [math]::Round($driveInfo.AvailableFreeSpace / 1GB, 2)
        } catch {}
    }

    if ($freeSpaceGB -gt 0 -and $freeSpaceGB -lt $minRequiredFreeGB) {
        Write-Host "  [FAIL] Insufficient free disk space on $drivePath ($freeSpaceGB GB available, $minRequiredFreeGB GB required)." -ForegroundColor Red
        $global:LASTEXITCODE = 1
        return $false
    }

    # Total disk size check
    $diskSizeGB = 0
    if ($SimulatedDiskSizeGB -gt 0) {
        $diskSizeGB = $SimulatedDiskSizeGB
    } elseif ($env:MIOS_SIMULATED_DISK_GB) {
        $simEnv = 0
        if ([int]::TryParse($env:MIOS_SIMULATED_DISK_GB, [ref]$simEnv) -and $simEnv -gt 0) {
            $diskSizeGB = $simEnv
        }
    }

    if ($diskSizeGB -le 0) {
        try {
            if (-not $isPath -or $cleanLetter.Length -eq 1) {
                $letterToProbe = if ($cleanLetter.Length -eq 1) { $cleanLetter } else { $cleanLetter.Substring(0, 1) }
                $vol = Get-Volume -DriveLetter $letterToProbe -ErrorAction SilentlyContinue
                if ($vol -and $vol.Size) {
                    $diskSizeGB = [math]::Round($vol.Size / 1GB)
                } else {
                    $part = Get-Partition -DriveLetter $letterToProbe -ErrorAction SilentlyContinue
                    if ($part) {
                        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
                        if ($disk -and $disk.Size) {
                            $diskSizeGB = [math]::Round($disk.Size / 1GB)
                        }
                    }
                }
            } else {
                $item = Get-Item -LiteralPath $drivePath -ErrorAction SilentlyContinue
                if ($item) {
                    $root = [System.IO.Path]::GetPathRoot($item.FullName)
                    $rootLetter = $root.TrimEnd(':\')
                    if ($rootLetter.Length -eq 1) {
                        $vol = Get-Volume -DriveLetter $rootLetter -ErrorAction SilentlyContinue
                        if ($vol -and $vol.Size) {
                            $diskSizeGB = [math]::Round($vol.Size / 1GB)
                        }
                    }
                }
            }
        } catch {}
    }

    Write-Host "Target disk: $drivePath (Total: $diskSizeGB GB, Free: $freeSpaceGB GB, min_disk_gb: $MinDiskGB GB)"

    # Always create MiOS-Repo (the lightweight config brain < 16GB)
    $repoDir = Join-Path $drivePath "MiOS-Repo"
    $reposDir = Join-Path $repoDir "repos"
    $null = New-Item -ItemType Directory -Force -Path $reposDir

    # Copy shadow config into MiOS-Repo
    $tomlCandidates = @(
        "C:\MiOS\usr\share\mios\mios.toml",
        "C:\MiOS\mios.toml",
        (Join-Path $PSScriptRoot "..\..\mios.toml"),
        (Join-Path $PSScriptRoot "..\..\usr\share\mios\mios.toml")
    )
    foreach ($cand in $tomlCandidates) {
        if (Test-Path -LiteralPath $cand) {
            Copy-Item -LiteralPath $cand -Destination $repoDir -Force
            break
        }
    }

    # Clone/copy repos into MiOS-Repo
    $miosGit = Join-Path $reposDir "MiOS"
    $bootstrapGit = Join-Path $reposDir "mios-bootstrap"
    if (-not (Test-Path -LiteralPath $miosGit)) {
        if (Test-Path "C:\MiOS\.git") {
            try { git clone --depth 1 "file:///C:/MiOS" $miosGit 2>$null } catch {}
        }
        if (-not (Test-Path -LiteralPath $miosGit) -and $env:MIOS_OFFLINE -ne "1") {
            try { git clone --depth 1 https://github.com/mios-dev/mios.git $miosGit 2>$null } catch {}
        }
    }
    if (-not (Test-Path -LiteralPath $bootstrapGit)) {
        if (Test-Path "C:\mios-bootstrap\.git") {
            try { git clone --depth 1 "file:///C:/mios-bootstrap" $bootstrapGit 2>$null } catch {}
        }
        if (-not (Test-Path -LiteralPath $bootstrapGit) -and $env:MIOS_OFFLINE -ne "1") {
            try { git clone --depth 1 https://github.com/mios-dev/mios-bootstrap.git $bootstrapGit 2>$null } catch {}
        }
    }

    # T-261: Stage separate MiOS-Data bulk store ONLY on disks meeting min_disk_gb gate
    if ($diskSizeGB -ge $MinDiskGB) {
        Write-Host "Disk >= ${MinDiskGB}GB gate met ($diskSizeGB GB). Staging separate MiOS-Data bulk store..." -ForegroundColor Cyan
        $dataDir = Join-Path $drivePath "MiOS-Data"
        $imagesDir = Join-Path $dataDir "images"
        $modelsDir = Join-Path $dataDir "models"
        $dnfDir = Join-Path $dataDir "dnf"
        $flatpakDir = Join-Path $dataDir "flatpak"
        $pipDir = Join-Path $dataDir "pip"

        $null = New-Item -ItemType Directory -Force -Path $imagesDir
        $null = New-Item -ItemType Directory -Force -Path $modelsDir
        $null = New-Item -ItemType Directory -Force -Path $dnfDir
        $null = New-Item -ItemType Directory -Force -Path $flatpakDir
        $null = New-Item -ItemType Directory -Force -Path $pipDir

        # Stage OCI archive for tools/install.sh offline path strictly into MiOS-Data/images/
        $stagedArchive = Join-Path $imagesDir "mios-latest.tar"
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
                & podman save --format oci-archive -o $stagedArchive localhost/mios:latest 2>&1 | Out-Null
            }
            if (-not (Test-Path -LiteralPath $stagedArchive) -or (Get-Item -LiteralPath $stagedArchive).Length -eq 0) {
                Write-Host "Generating standard OCI image archive structure -> $stagedArchive..." -ForegroundColor Cyan
                New-MiOSOCIArchive -DestinationTarPath $stagedArchive
            }
        }

        # Calculate sha256 of OCI archive
        $archiveSha256 = ""
        if (Test-Path -LiteralPath $stagedArchive) {
            $archiveSha256 = (Get-FileHash -LiteralPath $stagedArchive -Algorithm SHA256).Hash.ToLower()
        }

        # Extract OCI Image Layout if requested
        $extractedSuccessfully = $false
        if ($Extract) {
            $extractDir = Join-Path $imagesDir "extracted"
            Write-Host "Extracting OCI Image Layout to $extractDir..." -ForegroundColor Cyan
            $extractedSuccessfully = Expand-MiOSOCIImage -ArchiveFilePath $stagedArchive -DestinationPath $extractDir
        }

        # Copy build artifacts if available
        if (Test-Path "M:\MiOS-images\") {
            Copy-Item "M:\MiOS-images\*" -Destination $imagesDir -Recurse -Force
        }
        $buildDiskArtifacts = Get-ChildItem -Path "build\*.vhdx", "build\*.raw", "build\*.qcow2", "build\*.iso" -ErrorAction SilentlyContinue
        if ($buildDiskArtifacts) {
            foreach ($art in $buildDiskArtifacts) {
                Copy-Item $art.FullName -Destination $imagesDir -Force
            }
        }

        # Stage model artifacts into MiOS-Data/models/
        Write-Host "Staging model artifacts to $modelsDir..." -ForegroundColor Cyan
        $modelSources = @(
            "C:\MiOS\models",
            "M:\models",
            "M:\MiOS-models",
            "build\models",
            "usr\share\mios\vllm\model",
            "usr\share\mios\models"
        )
        $stagedModelCount = 0
        foreach ($ms in $modelSources) {
            if (Test-Path -LiteralPath $ms) {
                $mFiles = Get-ChildItem -Path $ms -File -Include "*.gguf", "*.bin", "*.safetensors", "*.pt", "*.json" -Recurse -ErrorAction SilentlyContinue
                if ($mFiles) {
                    foreach ($mf in $mFiles) {
                        Copy-Item $mf.FullName -Destination $modelsDir -Force
                        $stagedModelCount++
                    }
                }
            }
        }

        # Stamped models inventory / manifest
        $modelsManifest = Join-Path $modelsDir "models.json"
        $modelsList = @(
            @{ name = "lfm2-700m.gguf"; role = "live_chat"; format = "gguf" },
            @{ name = "granite-4.1-8b.gguf"; role = "live_chat_fallback"; format = "gguf" }
        )
        $modelsObj = @{
            staged_count = $stagedModelCount
            catalog = $modelsList
            updated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        $modelsObj | ConvertTo-Json -Depth 4 | Out-File -FilePath $modelsManifest -Encoding utf8

        # Stamp MiOS-Data manifest.json
        $manifestPath = Join-Path $dataDir "manifest.json"
        $manifestObj = [ordered]@{
            version = "1.0"
            updated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            disk_size_gb = $diskSizeGB
            min_disk_gb = $MinDiskGB
            gate_passed = $true
            oci_archive = [ordered]@{
                path = "MiOS-Data/images/mios-latest.tar"
                sha256 = $archiveSha256
                extracted = [bool]$extractedSuccessfully
            }
            components = [ordered]@{
                images = "MiOS-Data/images"
                models = "MiOS-Data/models"
                dnf = "MiOS-Data/dnf"
                flatpak = "MiOS-Data/flatpak"
                pip = "MiOS-Data/pip"
            }
        }
        $manifestObj | ConvertTo-Json -Depth 4 | Out-File -FilePath $manifestPath -Encoding utf8
        Write-Host "MiOS-Data bulk store staged successfully ($manifestPath)." -ForegroundColor Green
    } else {
        Write-Host "[MiOS-Cat] Disk size ($diskSizeGB GB) < min_disk_gb ($MinDiskGB GB) gate from [cat].data_partition." -ForegroundColor Yellow
        Write-Host "[MiOS-Cat] Skipping separate MiOS-Data bulk store staging (degrade-open offline mode: small USB stick carries MiOS-Repo config brain only)." -ForegroundColor Yellow
    }

    $global:LASTEXITCODE = 0
    return $true
}

function Invoke-MiOSCatVerify {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$DriveLetter = "D",

        [Parameter()]
        [int]$MinDiskGB = 512
    )
    $cleanLetter = $DriveLetter.TrimEnd(':\')
    $isPath = ($DriveLetter.Contains('\') -or $DriveLetter.Contains('/') -or (Test-Path -LiteralPath $DriveLetter))
    $drivePath = if ($isPath) { $DriveLetter } else { "${cleanLetter}:\" }

    if (-not (Test-Path -LiteralPath $drivePath)) {
        $global:LASTEXITCODE = 1
        return $false
    }

    $repoDir = Join-Path $drivePath "MiOS-Repo"
    if (-not (Test-Path -LiteralPath $repoDir) -or -not (Test-Path -LiteralPath (Join-Path $repoDir "mios.toml"))) {
        $global:LASTEXITCODE = 1
        return $false
    }

    $dataDir = Join-Path $drivePath "MiOS-Data"
    if (Test-Path -LiteralPath $dataDir) {
        $imagesDir = Join-Path $dataDir "images"
        $modelsDir = Join-Path $dataDir "models"
        $manifestPath = Join-Path $dataDir "manifest.json"
        if (-not (Test-Path -LiteralPath $imagesDir) -or
            -not (Test-Path -LiteralPath $modelsDir) -or
            -not (Test-Path -LiteralPath $manifestPath)) {
            $global:LASTEXITCODE = 1
            return $false
        }
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($manifest.gate_passed -ne $true) {
                $global:LASTEXITCODE = 1
                return $false
            }
        } catch {
            $global:LASTEXITCODE = 1
            return $false
        }
    }

    $global:LASTEXITCODE = 0
    return $true
}

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
    Write-Host "Refreshing offline payloads + manifest.json..."
    $cleanLetter = $DriveLetter.TrimEnd(':\')
    $drivePath = if ($DriveLetter.Contains('\') -or $DriveLetter.Contains('/')) { $DriveLetter } else { "${cleanLetter}:\" }
    $dataDir = Join-Path $drivePath "MiOS-Data"
    if (Test-Path $dataDir) {
        $manifest = Join-Path $dataDir "manifest.json"
        $dateStr = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $manifestObj = @{
            version = "1.0"
            updated = $dateStr
            components = @{
                images = "MiOS-Data/images"
                models = "MiOS-Data/models"
                dnf = "MiOS-Data/dnf"
                flatpak = "MiOS-Data/flatpak"
                pip = "MiOS-Data/pip"
            }
        }
        $manifestObj | ConvertTo-Json -Depth 4 | Out-File -FilePath $manifest -Encoding utf8
        Write-Host "Manifest updated: $manifest" -ForegroundColor Green
        $global:LASTEXITCODE = 0
        return $true
    } else {
        Write-Host "No MiOS-Data bulk store found on $drivePath to update." -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        return $false
    }
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
    if (Test-Path $modelsSource) {
        $null = New-Item -ItemType Directory -Force -Path $modelsTarget
        Copy-Item "$modelsSource\*" -Destination $modelsTarget -Recurse -Force
        Write-Host "Provisioned models to $modelsTarget" -ForegroundColor Green
        $global:LASTEXITCODE = 0
        return $true
    } else {
        Write-Host "No MiOS-Data\models found on $drivePath." -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        return $false
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
