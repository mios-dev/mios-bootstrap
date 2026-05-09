#Requires -Version 5.1
# install-host-tools.ps1 -- Windows host CLI tool installation.
#
# Operator 2026-05-09: "TOLD YOU A MONOLITH INSTALL.ps1 SCRIPT WAS A BAD
# IDEA AND THAT THE BOOTSTRAP SHOULD BE DOING MOST OF THE HOST_SIDE
# SETUP AND INSTALLATIONS". Per feedback_mios_dev_is_the_builder:
# build-mios.ps1 is for the build (podman/bootc inside MiOS-DEV) ONLY.
# Host-side setup is staged here and dot-sourced by build-mios.ps1
# at runtime. Splitting also keeps each .ps1 small enough that AMSI
# heuristics don't combine multiple flag patterns the way a 500KB
# monolith did (operator's 17:01 / 17:09 installs both AMSI-blocked).
#
# Defines: Install-MiosWindowsTools
#
# Reads SSOT [packages.windows] from mios.toml: pkgs (string array),
# bin_map (pipe-separated "pkg-id|bin" strings), verify_probes (string
# array). Vendor defaults baked here as final fallback.

function Install-MiosWindowsTools {
    # Install [packages.windows] CLI tools via winget BEFORE branding
    # runs. Reads SSOT (mios.toml [packages.windows]) so the package
    # list is operator-tunable via mios.html. Includes
    # Microsoft.PowerShell (pwsh 7), fastfetch, btop, sharkdp.bat/.fd,
    # ripgrep, fzf, jq, gh, etc. -- everything the MiOS terminal
    # experience depends on.
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Log-Warn "winget not available -- [packages.windows] CLI tools NOT installed (fastfetch / btop / pwsh / etc. will be missing)"
        return
    }

    Set-Step "Installing [packages.windows] CLI tools via winget (SSOT: mios.toml)..."

    # Resolve [packages.windows].pkgs from mios.toml. Layered overlay:
    # operator host override > vendor on M:\ > bootstrap shadow.
    $rx        = '(?ms)^\[packages\.windows\]\s*$.*?^\s*pkgs\s*=\s*\[(?<list>.*?)\]\s*$'
    $pkgs      = @()
    $sourceOk  = ''
    $candidates = @('M:\etc\mios\mios.toml', 'M:\usr\share\mios\mios.toml', (Join-Path $MiosBootstrapShadow 'mios.toml'))
    foreach ($cand in $candidates) {
        if (-not (Test-Path -LiteralPath $cand)) { continue }
        try {
            $tomlText = [IO.File]::ReadAllText($cand, (New-Object System.Text.UTF8Encoding($false)))
        } catch { continue }
        $m = [regex]::Match($tomlText, $rx)
        if (-not $m.Success) { continue }
        $stripped = ($m.Groups['list'].Value -split "`n" |
                     ForEach-Object { ($_ -replace '#.*$', '').Trim() }) -join ' '
        $tryPkgs = @(
            $stripped -split ',' |
            ForEach-Object {
                $s = $_.Trim().Trim('"', "'", ' ', "`t", "`r", "`n")
                if ($s) { $s }
            }
        )
        if ($tryPkgs.Count -gt 0) {
            $pkgs     = $tryPkgs
            $sourceOk = $cand
            break
        }
    }
    if ($pkgs.Count -eq 0) {
        throw "Cannot resolve [packages.windows].pkgs from any of: $($candidates -join ', '). Per operator SSOT directive 'ALL values source from the toml' there is no hardcoded fallback. Verify [packages.windows] section is intact in mios.toml (vendor copy at M:\usr\share\mios\mios.toml is canonical -- run 'mios pull' to refresh, or re-run the irm|iex one-liner)."
    }
    Log-Ok "[packages.windows] resolved $($pkgs.Count) package(s) from $sourceOk"

    # SSOT: package-ID -> expected-bin map resolves through mios.toml
    # [packages.windows].bin_map (pipe-separated "pkg-id|bin" strings)
    # with vendor defaults baked here.
    $_defaultBinMap = @(
        'BurntSushi.ripgrep.MSI|rg',
        'junegunn.fzf|fzf',
        'jqlang.jq|jq',
        'sharkdp.bat|bat',
        'sharkdp.fd|fd',
        'GitHub.cli|gh',
        'fastfetch-cli.fastfetch|fastfetch',
        'aristocratos.btop4win|btop4win',
        'Microsoft.PowerShell|pwsh',
        'JanDeDobbeleer.OhMyPosh|oh-my-posh'
    )
    $_binMapStrings = @(Get-MiosTomlValue -Section 'packages.windows' -Key 'bin_map' -Default $_defaultBinMap)
    $pkgBinMap = @{}
    foreach ($_entry in $_binMapStrings) {
        $_parts = $_entry -split '\|', 2
        if ($_parts.Length -eq 2 -and -not [string]::IsNullOrWhiteSpace($_parts[0]) -and -not [string]::IsNullOrWhiteSpace($_parts[1])) {
            $pkgBinMap[$_parts[0].Trim()] = $_parts[1].Trim()
        }
    }
    $installed = 0
    $skipped   = 0
    $failed    = 0
    foreach ($pkg in $pkgs) {
        try {
            $probe = & winget list --id $pkg --exact 2>$null
            $wingetSeesIt = ($LASTEXITCODE -eq 0 -and (($probe -join "`n") -match [regex]::Escape($pkg)))
            $expectedBin  = $pkgBinMap[$pkg]
            $binOnPath    = $null
            if ($expectedBin) {
                $binOnPath = (Get-Command $expectedBin -ErrorAction SilentlyContinue) -ne $null
            }
            if ($wingetSeesIt -and (-not $expectedBin -or $binOnPath)) {
                Log-Ok ("winget already-present: {0}" -f $pkg)
                $skipped++
                continue
            }
            if ($wingetSeesIt -and $expectedBin -and -not $binOnPath) {
                Log-Warn ("winget claims {0} present but '{1}' not on PATH -- forcing reinstall" -f $pkg, $expectedBin)
            } else {
                Log-Ok ("winget installing: {0}..." -f $pkg)
            }
            $forceArgs = if ($wingetSeesIt) { @('--force') } else { @() }
            & winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements --source winget --scope user @forceArgs 2>&1 |
                ForEach-Object { Write-Log ("winget[{0}]: {1}" -f $pkg, $_) }
            if ($LASTEXITCODE -eq 0) {
                Log-Ok "winget install: $pkg [OK]"
                $installed++
            } else {
                Log-Warn ("winget install: {0} user-scope exit {1} -- retrying without --scope" -f $pkg, $LASTEXITCODE)
                & winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements --source winget @forceArgs 2>&1 |
                    ForEach-Object { Write-Log ("winget[{0}-retry]: {1}" -f $pkg, $_) }
                if ($LASTEXITCODE -eq 0) {
                    Log-Ok "winget install (retry): $pkg [OK]"
                    $installed++
                } else {
                    Log-Warn ("winget install: {0} FAILED (exit {1})" -f $pkg, $LASTEXITCODE)
                    $failed++
                }
            }
        } catch {
            Log-Warn ("winget install: {0} -- {1}" -f $pkg, $_.Exception.Message)
            $failed++
        }
    }
    Log-Ok ("[packages.windows] winget summary: {0} installed / {1} already-present / {2} failed" -f $installed, $skipped, $failed)

    # PATH augmentation. winget install --scope user lands binaries
    # under %LOCALAPPDATA%\Microsoft\WinGet\Packages\<id>_*\ and updates
    # User PATH -- but only on NEXT shell launch. Probe install dirs
    # NOW + add to current $env:PATH AND persist to User PATH.
    $exeDirs = New-Object System.Collections.Generic.HashSet[string]
    $linksDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
    if (Test-Path $linksDir) { [void]$exeDirs.Add($linksDir) }

    foreach ($wingetRoot in @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:ProgramFiles 'WinGet\Packages')
    )) {
        if (-not (Test-Path $wingetRoot)) { continue }
        try {
            Get-ChildItem -Path $wingetRoot -Recurse -Filter '*.exe' -File -ErrorAction SilentlyContinue -Depth 5 |
                ForEach-Object {
                    if ($_.DirectoryName) { [void]$exeDirs.Add($_.DirectoryName) }
                }
        } catch {}
    }
    $extraPaths = @($exeDirs)
    if (Test-Path $MiosBinDir) { $extraPaths += $MiosBinDir }
    $extraPaths = $extraPaths | Sort-Object -Unique

    try {
        $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
        $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
        $combined  = (@($_machPath, $_userPath) + $extraPaths | Where-Object { $_ }) -join ';'
        $env:PATH  = $combined
        Log-Ok ('$env:PATH refreshed (+{0} winget package dirs)' -f $extraPaths.Count)
    } catch {
        Log-Warn "PATH refresh failed: $($_.Exception.Message)"
    }

    if ($extraPaths.Count -gt 0) {
        try {
            $userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
            $userParts = if ($userPath) { $userPath -split ';' } else { @() }
            $newParts  = @($userParts) + ($extraPaths | Where-Object { $_ -and ($userParts -notcontains $_) })
            $newUserPath = ($newParts | Where-Object { $_ }) -join ';'
            if ($newUserPath -ne $userPath) {
                [System.Environment]::SetEnvironmentVariable('PATH', $newUserPath, 'User')
                Log-Ok ('User PATH persisted (+{0} new dirs)' -f ($newParts.Count - $userParts.Count))
            }
        } catch {
            Log-Warn "User PATH persist failed: $($_.Exception.Message)"
        }
    }

    # Direct-download fallbacks for fastfetch + btop + rg/fzf/jq/bat/fd
    # cohort. Lands binaries in $MiosBinDir for guaranteed PATH reach.
    if (-not (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
        Log-Ok 'fastfetch: winget unsuccessful -- attempting direct download from GitHub releases...'
        try {
            $api = 'https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest'
            $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent'='mios-bootstrap' } -ErrorAction Stop
            $asset = $rel.assets | Where-Object { $_.name -match 'windows-amd64\.zip$' } | Select-Object -First 1
            if ($asset) {
                $zip = Join-Path $env:TEMP "fastfetch-$(Get-Random).zip"
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -ErrorAction Stop
                $extractRoot = Join-Path $env:TEMP "fastfetch-$(Get-Random)"
                Expand-Archive -LiteralPath $zip -DestinationPath $extractRoot -Force
                $exe = Get-ChildItem -Path $extractRoot -Recurse -Filter 'fastfetch.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($exe) {
                    Copy-Item -Path $exe.FullName -Destination (Join-Path $MiosBinDir 'fastfetch.exe') -Force
                    Log-Ok ("fastfetch installed direct: {0} -> {1}" -f $asset.name, (Join-Path $MiosBinDir 'fastfetch.exe'))
                }
                Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Log-Warn 'fastfetch: no windows-amd64.zip asset found in latest release'
            }
        } catch { Log-Warn ("fastfetch direct-download failed: {0}" -f $_.Exception.Message) }
    }

    if (-not (Get-Command btop -ErrorAction SilentlyContinue)) {
        Log-Ok 'btop: probing winget btop4win install + GitHub fallback...'
        $btopExe = $null
        $wingetBtop = Get-ChildItem -Path $wingetRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^aristocratos\.btop4win' } |
            Select-Object -First 1
        if ($wingetBtop) {
            $cand = Get-ChildItem -Path $wingetBtop.FullName -Recurse -Filter 'btop4win.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cand) { $btopExe = $cand.FullName }
        }
        if (-not $btopExe) {
            try {
                $api = 'https://api.github.com/repos/aristocratos/btop4win/releases/latest'
                $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent'='mios-bootstrap' } -ErrorAction Stop
                $asset = $rel.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
                if ($asset) {
                    $zip = Join-Path $env:TEMP "btop4win-$(Get-Random).zip"
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -ErrorAction Stop
                    $extractRoot = Join-Path $env:TEMP "btop4win-$(Get-Random)"
                    Expand-Archive -LiteralPath $zip -DestinationPath $extractRoot -Force
                    $cand = Get-ChildItem -Path $extractRoot -Recurse -Filter 'btop4win.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($cand) { $btopExe = $cand.FullName }
                    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                }
            } catch { Log-Warn ("btop direct-download failed: {0}" -f $_.Exception.Message) }
        }
        if ($btopExe -and (Test-Path -LiteralPath $btopExe)) {
            $dst = Join-Path $MiosBinDir 'btop.exe'
            try {
                Copy-Item -Path $btopExe -Destination $dst -Force
                Log-Ok ("btop installed: {0} -> {1}" -f $btopExe, $dst)
            } catch { Log-Warn ("btop copy failed: {0}" -f $_.Exception.Message) }
        }
    }

    $directBins = @(
        @{ Cmd='rg';  Repo='BurntSushi/ripgrep';                        AssetRx='ripgrep-.*-x86_64-pc-windows-msvc\.zip$';   ExeRx='^rg\.exe$' }
        @{ Cmd='fzf'; Repo='junegunn/fzf';                              AssetRx='fzf-.*-windows_amd64\.zip$';                ExeRx='^fzf\.exe$' }
        @{ Cmd='jq';  Repo='jqlang/jq';            DirectAsset='jq-windows-amd64.exe'; ExeName='jq.exe' }
        @{ Cmd='bat'; Repo='sharkdp/bat';                               AssetRx='bat-.*-x86_64-pc-windows-msvc\.zip$';       ExeRx='^bat\.exe$' }
        @{ Cmd='fd';  Repo='sharkdp/fd';                                AssetRx='fd-.*-x86_64-pc-windows-msvc\.zip$';        ExeRx='^fd\.exe$' }
    )
    foreach ($db in $directBins) {
        if (Get-Command $db.Cmd -ErrorAction SilentlyContinue) { continue }
        Log-Ok ("{0}: winget unsuccessful -- attempting direct download from GitHub releases..." -f $db.Cmd)
        try {
            $api = "https://api.github.com/repos/$($db.Repo)/releases/latest"
            $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent'='mios-bootstrap' } -ErrorAction Stop
            if ($db.DirectAsset) {
                $asset = $rel.assets | Where-Object { $_.name -eq $db.DirectAsset } | Select-Object -First 1
                if ($asset) {
                    $dst = Join-Path $MiosBinDir $db.ExeName
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dst -UseBasicParsing -ErrorAction Stop
                    Log-Ok ("{0} installed direct: {1} -> {2}" -f $db.Cmd, $asset.name, $dst)
                } else {
                    Log-Warn ("{0}: no '{1}' asset in latest release of {2}" -f $db.Cmd, $db.DirectAsset, $db.Repo)
                }
            } else {
                $asset = $rel.assets | Where-Object { $_.name -match $db.AssetRx } | Select-Object -First 1
                if ($asset) {
                    $zip = Join-Path $env:TEMP "$($db.Cmd)-$(Get-Random).zip"
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -ErrorAction Stop
                    $extractRoot = Join-Path $env:TEMP "$($db.Cmd)-$(Get-Random)"
                    Expand-Archive -LiteralPath $zip -DestinationPath $extractRoot -Force
                    $exe = Get-ChildItem -Path $extractRoot -Recurse -File -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -match $db.ExeRx } | Select-Object -First 1
                    if ($exe) {
                        $dst = Join-Path $MiosBinDir ($db.Cmd + '.exe')
                        Copy-Item -Path $exe.FullName -Destination $dst -Force
                        Log-Ok ("{0} installed direct: {1} -> {2}" -f $db.Cmd, $asset.name, $dst)
                    } else {
                        Log-Warn ("{0}: no exe matching /{1}/ inside {2}" -f $db.Cmd, $db.ExeRx, $asset.name)
                    }
                    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
                } else {
                    Log-Warn ("{0}: no asset matching /{1}/ in latest release of {2}" -f $db.Cmd, $db.AssetRx, $db.Repo)
                }
            }
        } catch { Log-Warn ("{0} direct-download failed: {1}" -f $db.Cmd, $_.Exception.Message) }
    }

    # Final PATH refresh -- pick up direct-download binaries.
    try {
        $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
        $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
        $env:PATH  = (@($_machPath, $_userPath, $MiosBinDir) | Where-Object { $_ }) -join ';'
    } catch {}

    # Final verification: which targeted binaries are on PATH now?
    $_probes = @(Get-MiosTomlValue -Section 'packages.windows' -Key 'verify_probes' -Default @('fastfetch','btop','rg','fzf','jq','gh','bat','fd','pwsh','oh-my-posh'))
    foreach ($probe in $_probes) {
        if (Get-Command $probe -ErrorAction SilentlyContinue) {
            Log-Ok ("verify: '{0}' is on PATH" -f $probe)
        } else {
            Log-Warn ("verify: '{0}' NOT on PATH (winget install may have failed; check above)" -f $probe)
        }
    }

    # btop config + MiOS theme. Operator 2026-05-09: "btop can run if a
    # preset can fit the dimensions provided--just need a profile preset
    # (make it match the entire MiOS themes and color palette)". Source
    # at src/btop/btop.conf + src/btop/mios.theme. Target M:\MiOS\btop\
    # via BTOP_CONFIG_DIR env var so config lives on the MiOS-owned
    # drive (per feedback_mios_m_drive_everything) rather than %APPDATA%.
    $_btopDst = 'M:\MiOS\btop'
    $_btopThemesDst = Join-Path $_btopDst 'themes'
    foreach ($_d in @($_btopDst, $_btopThemesDst)) {
        if (-not (Test-Path -LiteralPath $_d)) {
            New-Item -ItemType Directory -Path $_d -Force | Out-Null
        }
    }
    $_btopSrcCandidates = @(
        (Join-Path $MiosRepoDir 'src\btop'),
        (Join-Path $MiosBootstrapShadow 'src\btop')
    )
    $_btopSrc = $null
    foreach ($_c in $_btopSrcCandidates) {
        if (Test-Path -LiteralPath $_c) { $_btopSrc = $_c; break }
    }
    if ($_btopSrc) {
        $_confSrc  = Join-Path $_btopSrc 'btop.conf'
        $_themeSrc = Join-Path $_btopSrc 'mios.theme'
        if (Test-Path -LiteralPath $_confSrc)  { Copy-Item -LiteralPath $_confSrc  -Destination (Join-Path $_btopDst 'btop.conf') -Force }
        if (Test-Path -LiteralPath $_themeSrc) { Copy-Item -LiteralPath $_themeSrc -Destination (Join-Path $_btopThemesDst 'mios.theme') -Force }
        Log-Ok "btop config + mios.theme staged at $_btopDst"
        # BTOP_CONFIG_DIR tells btop where to find config + themes.
        try {
            [Environment]::SetEnvironmentVariable('BTOP_CONFIG_DIR', $_btopDst, 'User')
            $env:BTOP_CONFIG_DIR = $_btopDst
            Log-Ok "BTOP_CONFIG_DIR=$_btopDst set in User env"
        } catch {
            Log-Warn "BTOP_CONFIG_DIR set failed: $($_.Exception.Message)"
        }
    } else {
        Log-Warn "btop config source not found (probed: $($_btopSrcCandidates -join ', ')) -- skipping btop theme stage"
    }
}
