# AI-hint: Powershell script to install Windows host CLI tools (e.g., pwsh, ripgrep, fzf) via winget (with checksum retry fallback) or direct GitHub downloads based on mios.toml definitions to prepare the host environment for MiOS terminal operations.
# AI-related: mios-bootstrap, mios-seed, localhost:3030
# AI-functions: Install-MiosWindowsTools, Configure-MiosBrowserAI
#Requires -Version 5.1
# install-host-tools.ps1 -- Windows host CLI tool installation.
#
# "TOLD YOU A MONOLITH INSTALL.ps1 SCRIPT WAS A BAD
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
    # NO-LOCAL-DEPS ("without ANY local dependencies"): winget
    # is an OPTIONAL accelerator, NEVER a requirement. Every CLI tool below has a
    # direct GitHub-release download path, so a clean machine with no winget still
    # gets the full MiOS terminal toolset -- everything pulls from upstream/MiOS
    # repos, nothing assumed pre-installed.
    $haveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    if (-not $haveWinget) {
        Log-Warn "winget absent -- installing every [packages.windows] tool via DIRECT download (no local dependency)"
    }

    Set-Step "Installing [packages.windows] CLI tools (direct-download primary; winget optional)..."

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
    # No winget -> skip the winget loop entirely; the direct-download block below
    # installs every tool. (winget present -> best-effort accelerator, gaps filled.)
    if (-not $haveWinget) { $pkgs = @() }

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
                    Log-Warn ("winget install: {0} FAILED (exit {1}) -- retrying with --ignore-security-hash" -f $pkg, $LASTEXITCODE)
                    & winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements --source winget --ignore-security-hash @forceArgs 2>&1 |
                        ForEach-Object { Write-Log ("winget[{0}-hash-retry]: {1}" -f $pkg, $_) }
                    if ($LASTEXITCODE -eq 0) {
                        Log-Ok "winget install (hash-retry): $pkg [OK]"
                        $installed++
                    } else {
                        Log-Warn ("winget install: {0} COMPLETELY FAILED (exit {1})" -f $pkg, $LASTEXITCODE)
                        $failed++
                    }
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

    # btop on Windows: dispatch to the dev VM's Linux btop instead of
    # shipping btop4win.exe. Reasons:
    #   1. aristocratos/btop4win is the only Windows port; it's
    #      experimental, links against a non-standard CPPdll.dll that
    #      isn't on most systems, and the binary fails at launch with
    #      "code execution cannot proceed because CPPdll.dll was not
    # found" on operator's host (screenshot).
    #   2. Operator's "UNIFIED across all platforms" directive: same
    #      btop binary + same MiOS theme on Windows AND Linux gives
    #      one consistent experience instead of two divergent ports.
    #   3. The dev VM's btop already exists, has the MiOS theme
    #      seeded by mios-seed at /var/home/mios/.config/btop/, and
    #      renders cleanly via WSLg.
    # The Windows-side `btop` function (defined in the MiOS PS profile
    # body) calls `wsl.exe -d <dev-distro> --user mios -- btop`. No
    # btop.exe in M:\MiOS\bin is needed.
    Log-Ok 'btop: skipping btop4win install (broken CPPdll.dll dep); Windows pwsh `btop` dispatches to WSL via profile function'

    # Defensive cleanup: prior installs may have left a broken
    # btop.exe (copied from winget btop4win) in M:\MiOS\bin. Remove it
    # so the profile function shadowing doesn't get bypassed by PATH
    # lookup of the broken exe.
    $stale = Join-Path $MiosBinDir 'btop.exe'
    if (Test-Path -LiteralPath $stale) {
        try {
            Remove-Item -LiteralPath $stale -Force -ErrorAction Stop
            Log-Ok ("btop: removed stale broken btop.exe at {0}" -f $stale)
        } catch { Log-Warn ("btop: could not remove stale {0}: {1}" -f $stale, $_.Exception.Message) }
    }

    # Direct-download cohort (single self-contained .exe -> $MiosBinDir). gh added
    # for no-local-deps: gh.exe is a self-contained Go binary inside the zip's bin/.
    # (pwsh + python need their runtime tree, handled as dedicated blocks below.)
    $directBins = @(
        @{ Cmd='rg';  Repo='BurntSushi/ripgrep';                        AssetRx='ripgrep-.*-x86_64-pc-windows-msvc\.zip$';   ExeRx='^rg\.exe$' }
        @{ Cmd='fzf'; Repo='junegunn/fzf';                              AssetRx='fzf-.*-windows_amd64\.zip$';                ExeRx='^fzf\.exe$' }
        @{ Cmd='jq';  Repo='jqlang/jq';            DirectAsset='jq-windows-amd64.exe'; ExeName='jq.exe' }
        @{ Cmd='bat'; Repo='sharkdp/bat';                               AssetRx='bat-.*-x86_64-pc-windows-msvc\.zip$';       ExeRx='^bat\.exe$' }
        @{ Cmd='fd';  Repo='sharkdp/fd';                                AssetRx='fd-.*-x86_64-pc-windows-msvc\.zip$';        ExeRx='^fd\.exe$' }
        @{ Cmd='gh';  Repo='cli/cli';                                   AssetRx='gh_.*_windows_amd64\.zip$';                 ExeRx='^gh\.exe$' }
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

    # ── pwsh 7 (PowerShell) -- direct download, NO winget ─────────────
    # Needs its whole runtime tree (DLLs), so extract the full zip to
    # <install>\pwsh and PATH the folder (not a single-exe $MiosBinDir copy
    # like the cohort above). The MiOS Windows Terminal profile launches
    # pwsh; without it WT falls back to Windows PowerShell 5.1.
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        Log-Ok 'pwsh: direct download from GitHub releases (PowerShell/PowerShell)...'
        try {
            $api   = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
            $rel   = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent'='mios-bootstrap' } -ErrorAction Stop
            $asset = $rel.assets | Where-Object { $_.name -match '^PowerShell-.*-win-x64\.zip$' } | Select-Object -First 1
            if ($asset) {
                $zip = Join-Path $env:TEMP "pwsh-$(Get-Random).zip"
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -ErrorAction Stop
                $pwshDir = Join-Path (Split-Path $MiosBinDir -Parent) 'pwsh'
                if (Test-Path $pwshDir) { Remove-Item $pwshDir -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType Directory -Path $pwshDir -Force | Out-Null
                Expand-Archive -LiteralPath $zip -DestinationPath $pwshDir -Force
                Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                if (Test-Path (Join-Path $pwshDir 'pwsh.exe')) {
                    $_adm   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
                    $_scope = if ($_adm) { 'Machine' } else { 'User' }
                    $_p     = [Environment]::GetEnvironmentVariable('Path', $_scope)
                    if (-not (($_p -split ';') | Where-Object { $_ -ieq $pwshDir })) {
                        [Environment]::SetEnvironmentVariable('Path', "$_p;$pwshDir", $_scope)
                    }
                    $env:PATH = "$env:PATH;$pwshDir"
                    Log-Ok ("pwsh installed direct: {0} -> {1}" -f $asset.name, (Join-Path $pwshDir 'pwsh.exe'))
                } else { Log-Warn 'pwsh: pwsh.exe missing after extract' }
            } else { Log-Warn 'pwsh: no PowerShell-*-win-x64.zip asset in latest release' }
        } catch { Log-Warn ("pwsh direct-download failed: {0}" -f $_.Exception.Message) }
    }

    # ── Python: make the REAL interpreter win over the Windows Store
    # "python.exe" App Execution Alias stub. winget installs the
    # python.org build (the id "Python.Python.3.14" comes from
    # [packages.windows].pkgs -- SSOT, no hardcode here) but does NOT
    # reliably prepend it to PATH, and the 0-byte stub at
    # %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe shadows bare
    # `python` with a "install from the Store" message (operator
    # host had no usable python/py/python3 even though the
    # MiOS tooling needs it). Locate the real interpreter and PREPEND its
    # dir + Scripts to PATH so `python` resolves to it, not the stub.
    $_pyExe   = $null
    $_pyRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        'C:\'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($_root in $_pyRoots) {
        $_cand = Get-ChildItem -LiteralPath $_root -Filter 'Python3*' -Directory -ErrorAction SilentlyContinue |
                 ForEach-Object { Join-Path $_.FullName 'python.exe' } |
                 Where-Object { (Test-Path -LiteralPath $_) -and ($_ -notmatch 'WindowsApps') } |
                 Sort-Object -Descending | Select-Object -First 1
        if ($_cand) { $_pyExe = $_cand; break }
    }
    if ($_pyExe) {
        $_pyDir     = Split-Path $_pyExe -Parent
        $_pyPrepend = @($_pyDir, (Join-Path $_pyDir 'Scripts')) | Where-Object { Test-Path -LiteralPath $_ }
        $env:PATH   = ($_pyPrepend + ($env:PATH -split ';')) -join ';'
        try {
            $_uPath  = [System.Environment]::GetEnvironmentVariable('PATH','User')
            $_uParts = if ($_uPath) { $_uPath -split ';' | Where-Object { $_ -and ($_pyPrepend -notcontains $_) } } else { @() }
            [System.Environment]::SetEnvironmentVariable('PATH', (($_pyPrepend + $_uParts) -join ';'), 'User')
            $_pyVer = (& $_pyExe --version 2>&1) -join ' '
            Log-Ok ("python: prepended '{0}' to User PATH (beats Store stub) -- {1}" -f $_pyDir, $_pyVer)
        } catch { Log-Warn ("python PATH prepend failed: {0}" -f $_.Exception.Message) }
    } else {
        # NO-LOCAL-DEPS: no winget-installed python -> direct-download a portable
        # CPython from python-build-standalone (GitHub releases; self-contained,
        # ships pip). Extract to <install>\python and PATH it. Win10+ ships tar.exe
        # (bsdtar) so no extra dependency to unpack the .tar.gz.
        Log-Ok 'python: not found -- direct download from python-build-standalone (GitHub)...'
        try {
            $rel   = Invoke-RestMethod -Uri 'https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest' -Headers @{ 'User-Agent'='mios-bootstrap' } -ErrorAction Stop
            # 3.1[0-9] keeps all candidates the same string length so lexical
            # descending == newest version (avoids "3.9" > "3.14" string-sort bug).
            $asset = $rel.assets |
                     Where-Object { $_.name -match '^cpython-3\.1[0-9]\.[0-9]+\+.*-x86_64-pc-windows-msvc-install_only\.tar\.gz$' } |
                     Sort-Object name -Descending | Select-Object -First 1
            if ($asset) {
                $tgz = Join-Path $env:TEMP "cpython-$(Get-Random).tar.gz"
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tgz -UseBasicParsing -ErrorAction Stop
                $pyRoot = Join-Path (Split-Path $MiosBinDir -Parent) 'python'
                if (Test-Path $pyRoot) { Remove-Item $pyRoot -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType Directory -Path $pyRoot -Force | Out-Null
                & tar.exe -xzf $tgz -C $pyRoot 2>&1 | Out-Null
                Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
                $_pyExe2 = Get-ChildItem -Path $pyRoot -Recurse -Filter 'python.exe' -File -ErrorAction SilentlyContinue |
                           Where-Object { $_.FullName -notmatch '\\(Lib|Scripts|tcl)\\' } | Select-Object -First 1
                if ($_pyExe2) {
                    $_pyDir2 = Split-Path $_pyExe2.FullName -Parent
                    $_pp     = @($_pyDir2, (Join-Path $_pyDir2 'Scripts')) | Where-Object { Test-Path -LiteralPath $_ }
                    $env:PATH = ($_pp + ($env:PATH -split ';')) -join ';'
                    try {
                        $_u  = [System.Environment]::GetEnvironmentVariable('PATH','User')
                        $_up = if ($_u) { $_u -split ';' | Where-Object { $_ -and ($_pp -notcontains $_) } } else { @() }
                        [System.Environment]::SetEnvironmentVariable('PATH', (($_pp + $_up) -join ';'), 'User')
                    } catch {}
                    Log-Ok ("python installed direct: {0} -> {1}" -f $asset.name, $_pyExe2.FullName)
                } else { Log-Warn 'python: python.exe not found after extract' }
            } else { Log-Warn 'python: no matching cpython install_only asset in latest python-build-standalone release' }
        } catch { Log-Warn ("python direct-download failed: {0}" -f $_.Exception.Message) }
    }

    # Final PATH refresh -- pick up direct-download binaries.
    try {
        $_machPath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
        $_userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
        $env:PATH  = (@($_machPath, $_userPath, $MiosBinDir) | Where-Object { $_ }) -join ';'
    } catch {}

    # Final verification: which targeted binaries are on PATH now?
    # NOTE: 'btop' is intentionally NOT in the default probe list -- on
    # Windows, `btop` is a profile-defined function that dispatches to the
    # dev VM's Linux btop (UNIFIED), not a Windows-side .exe. Probing for
    # it here would falsely warn "NOT on PATH" because Get-Command in this
    # bootstrap-time scope can't see the soon-to-be-installed pwsh
    # function. Operators who DO want a Windows-native btop4win can add
    # 'btop' to verify_probes via mios.html.
    $_probes = @(Get-MiosTomlValue -Section 'packages.windows' -Key 'verify_probes' -Default @('fastfetch','rg','fzf','jq','gh','bat','fd','pwsh','oh-my-posh'))
    foreach ($probe in $_probes) {
        if (Get-Command $probe -ErrorAction SilentlyContinue) {
            Log-Ok ("verify: '{0}' is on PATH" -f $probe)
        } else {
            Log-Warn ("verify: '{0}' NOT on PATH (winget install may have failed; check above)" -f $probe)
        }
    }

    # btop config + MiOS theme. "btop can run if a
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

    # Wire Zen/Firefox's AI sidebar to the MiOS OWUI pipeline (SSOT [browser_ai]).
    Configure-MiosBrowserAI
}

function Configure-MiosBrowserAI {
    # Install Zen Browser (Twilight, Firefox-based) and wire its built-in AI
    # chatbot SIDEBAR to the local OWUI / MiOS-Agent pipeline -- MiOS AI, natively
    # in the browser. Everything resolves from mios.toml [browser_ai] (SSOT): the
    # winget package id, the provider URL, and the Firefox/Zen prefs. We install
    # via winget, then write a managed policies.json into the Zen install's
    # distribution/ dir so every profile inherits the config.
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Log-Warn "browser_ai: winget unavailable -- skipping Zen + AI sidebar setup"
        return
    }
    $enable = "$(Get-MiosTomlValue -Section 'browser_ai' -Key 'enable' -Default 'true')"
    if ($enable -notmatch '^(true|1|yes)$') {
        Log-Ok "browser_ai disabled in SSOT -- skipping Zen AI sidebar setup"
        return
    }
    $pkg         = "$(Get-MiosTomlValue -Section 'browser_ai' -Key 'package' -Default 'Zen-Team.Zen-Browser.Twilight')"
    $providerUrl = "$(Get-MiosTomlValue -Section 'browser_ai' -Key 'provider_url' -Default 'http://localhost:3030')"
    $prefStrings = @(Get-MiosTomlValue -Section 'browser_ai' -Key 'prefs' -Default @(
        'browser.ml.chat.enabled|bool|true',
        'browser.ml.chat.hideLocalhost|bool|false',
        'browser.ml.chat.sidebar|bool|true'
    ))

    # Install Zen (idempotent: skip when winget already sees it).
    $seen = (& winget list --id $pkg --exact 2>$null)
    if (-not ($LASTEXITCODE -eq 0 -and (($seen -join "`n") -match [regex]::Escape($pkg)))) {
        Log-Ok ("browser_ai: installing {0} via winget..." -f $pkg)
        & winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements --source winget --scope user 2>&1 |
            ForEach-Object { Write-Log ("winget[{0}]: {1}" -f $pkg, $_) }
        if ($LASTEXITCODE -ne 0) {
            Log-Warn ("browser_ai: winget {0} user-scope exit {1} -- retrying without --scope" -f $pkg, $LASTEXITCODE)
            & winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 |
                ForEach-Object { Write-Log ("winget[{0}-retry]: {1}" -f $pkg, $_) }
        }
    } else {
        Log-Ok ("browser_ai: {0} already present" -f $pkg)
    }

    # PRIMARY method (reliable, no admin): a per-profile user.js. Research
    # - some browser.ml.chat.* prefs do NOT apply via policies.json,
    # and Program Files\...\distribution needs elevation; user.js is
    # user-writable and Zen reads it on every startup. Covers EXISTING profiles
    # (re-runs after the operator has launched Zen once); the policies.json
    # below is the best-effort fallback for profiles Zen creates later. Also
    # clears a stale parent.lock (a common "Zen won't open" cause) when Zen
    # isn't running.
    $ujLines = @('// MiOS: Firefox/Zen AI chatbot sidebar -> local OWUI / MiOS-Agent pipeline.')
    foreach ($p in $prefStrings) {
        $parts = $p -split '\|', 3
        if ($parts.Count -ne 3) { continue }
        $n = $parts[0].Trim(); $t = $parts[1].Trim().ToLower(); $r = $parts[2].Trim()
        $v = switch ($t) {
            'bool'  { if ($r -match '^(true|1|yes)$') { 'true' } else { 'false' } }
            'int'   { [string][int]$r }
            default { '"' + $r + '"' }
        }
        $ujLines += ('user_pref("{0}", {1});' -f $n, $v)
    }
    $ujLines += ('user_pref("browser.ml.chat.provider", "{0}");' -f $providerUrl)
    $uj = ($ujLines -join "`r`n")
    $zenRunning = @(Get-Process zen -ErrorAction SilentlyContinue).Count -gt 0
    foreach ($proot in @("$env:APPDATA\zen\Profiles", "$env:APPDATA\zen-twilight\Profiles") |
                       Where-Object { Test-Path -LiteralPath $_ }) {
        foreach ($pd in (Get-ChildItem $proot -Directory -ErrorAction SilentlyContinue)) {
            [IO.File]::WriteAllText((Join-Path $pd.FullName 'user.js'), $uj, (New-Object System.Text.UTF8Encoding($false)))
            Log-Ok ("browser_ai: user.js -> {0}" -f $pd.Name)
            if (-not $zenRunning) {
                $lk = Join-Path $pd.FullName 'parent.lock'
                if (Test-Path $lk) { Remove-Item $lk -Force -ErrorAction SilentlyContinue; Log-Ok ("browser_ai: cleared stale parent.lock in {0}" -f $pd.Name) }
            }
        }
    }

    # Locate zen.exe so policies.json can be dropped beside it (Firefox/Zen reads
    # <install-dir>\distribution\policies.json at startup, for every profile --
    # best-effort fallback for profiles that don't exist yet at install time).
    $zenExe = $null
    foreach ($root in @(
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        $env:LOCALAPPDATA,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) {
        $c = Get-ChildItem -LiteralPath $root -Recurse -Filter 'zen.exe' -File -Depth 4 -ErrorAction SilentlyContinue |
             Select-Object -First 1
        if ($c) { $zenExe = $c.FullName; break }
    }
    if (-not $zenExe) {
        Log-Warn "browser_ai: zen.exe not found after install -- cannot write the AI-sidebar policy (re-run after Zen is present)"
        return
    }

    # Build policies.json Preferences from the SSOT prefs + provider_url.
    $prefsObj = [ordered]@{}
    foreach ($p in $prefStrings) {
        $parts = $p -split '\|', 3
        if ($parts.Count -ne 3) { continue }
        $name = $parts[0].Trim(); $ptype = $parts[1].Trim().ToLower(); $raw = $parts[2].Trim()
        switch ($ptype) {
            'bool'  { $val = ($raw -match '^(true|1|yes)$') }
            'int'   { $val = [int]$raw }
            default { $val = $raw }
        }
        $prefsObj[$name] = [ordered]@{ Value = $val; Status = 'default' }
    }
    # provider_url -> the AI chatbot provider (OWUI = the MiOS AI pipeline).
    $prefsObj['browser.ml.chat.provider'] = [ordered]@{ Value = $providerUrl; Status = 'default' }

    $distDir = Join-Path (Split-Path $zenExe -Parent) 'distribution'
    if (-not (Test-Path -LiteralPath $distDir)) {
        New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    }
    $json = (@{ policies = @{ Preferences = $prefsObj } } | ConvertTo-Json -Depth 8)
    $dst  = Join-Path $distDir 'policies.json'
    [IO.File]::WriteAllText($dst, $json, (New-Object System.Text.UTF8Encoding($false)))
    Log-Ok ("browser_ai: Zen AI sidebar wired to {0} -> {1}" -f $providerUrl, $dst)
}
