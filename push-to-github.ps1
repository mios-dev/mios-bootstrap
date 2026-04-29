# ============================================================================
# push-to-github.ps1  MiOS release deliverable (v0.1.3 baseline)
# ----------------------------------------------------------------------------
# Single source of truth for the release pipeline. Per INDEX.md 4 + the
# /push-version skill, this script is rewritten per release and never split
# into push-vX.Y.Z.ps1 siblings.
#
# Behaviour:
#   1. Clone github.com/Kabuki94/MiOS-bootstrap into a temp directory.
#   2. Optionally overlay a staged companion directory (-StagedDir) onto the
#      working tree, preserving layout relative to repo root. Files-only 
#      directories are walked and replaced file by file. Nothing is deleted.
#   3. Bump VERSION to -Version (default: read from local VERSION file).
#   4. Stamp CHANGELOG.md with a top-of-file release block dated today.
#   5. Commit with a structured release message.
#   6. Push to main using $env:GH_TOKEN or the configured credential helper.
#   7. Print a summary: changed paths, commit SHA, GHCR tag.
#
# This is the deliverable. Humans run it; the agent does not push for you.
# ============================================================================

[CmdletBinding()]
param(
    [string]$Version,
    [string]$Message = 'release sync',
    [string]$StagedDir,
    [string]$Repo = 'github.com/Kabuki94/MiOS-bootstrap',
    [string]$Branch = 'main',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok  ([string]$msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "    $msg" -ForegroundColor Yellow }

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'VERSION'))) {
    throw "push-to-github.ps1 must live at the repo root next to VERSION."
}

if (-not $Version) {
    $Version = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
    Write-Warn "No -Version given; using local VERSION file: $Version"
}

if ($StagedDir) {
    if (-not (Test-Path -LiteralPath $StagedDir -PathType Container)) {
        throw "Staged companion directory not found: $StagedDir"
    }
    $StagedDir = (Resolve-Path -LiteralPath $StagedDir).Path
}

# Token discovery  never echoed to stdout.
$token = $env:GH_TOKEN
if (-not $token) { $token = $env:GITHUB_TOKEN }
if (-not $token) {
    Write-Warn 'No GH_TOKEN/GITHUB_TOKEN in environment; relying on git credential helper.'
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mios-push-" + [guid]::NewGuid().ToString('N').Substring(0,8))
Write-Step "Working directory: $workDir"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

try {
    $cloneUrl = if ($token) { "https://x-access-token:$token@$Repo.git" } else { "https://$Repo.git" }
    $safeUrl  = "https://$Repo.git"

    Write-Step "Cloning $safeUrl ($Branch)  full history."
    git clone --branch $Branch $cloneUrl $workDir 2>&1 | ForEach-Object { Write-Verbose $_ }
    if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)." }

    if ($StagedDir) {
        Write-Step "Overlaying staged files from $StagedDir"
        $stagedFiles = Get-ChildItem -LiteralPath $StagedDir -Recurse -File
        foreach ($f in $stagedFiles) {
            $rel = $f.FullName.Substring($StagedDir.Length).TrimStart('\','/')
            $dst = Join-Path $workDir $rel
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstDir)) {
                New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
            }
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
            Write-Ok "copied $rel"
        }
    } else {
        Write-Step "No -StagedDir; pushing local working tree state under $repoRoot"
        # Mirror the working repo into the clone (excluding .git).
        $rsyncSrc = (Resolve-Path -LiteralPath $repoRoot).Path
        Get-ChildItem -LiteralPath $rsyncSrc -Force -Recurse -File |
            Where-Object { $_.FullName -notlike (Join-Path $rsyncSrc '.git*') } |
            ForEach-Object {
                $rel = $_.FullName.Substring($rsyncSrc.Length).TrimStart('\','/')
                if ($rel -like '.git\*' -or $rel -eq '.git') { return }
                $dst = Join-Path $workDir $rel
                $dstDir = Split-Path -Parent $dst
                if (-not (Test-Path -LiteralPath $dstDir)) {
                    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
                }
                Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
            }
    }

    Write-Step "Bumping VERSION  $Version"
    Set-Content -LiteralPath (Join-Path $workDir 'VERSION') -Value $Version -NoNewline -Encoding utf8

    $changelog = Join-Path $workDir 'CHANGELOG.md'
    if (Test-Path -LiteralPath $changelog) {
        $today = Get-Date -Format 'yyyy-MM-dd'
        $existing = Get-Content -LiteralPath $changelog -Raw
        $header = "# Changelog`r`nAll notable changes to this project will be documented in this file.`r`n"
        $body = $existing
        if ($body.StartsWith($header)) { $body = $body.Substring($header.Length).TrimStart() }
        $newBlock = "## [v$Version] - $today`r`n`r`n- $Message`r`n`r`n"
        Set-Content -LiteralPath $changelog -Value ($header + "`r`n" + $newBlock + $body) -Encoding utf8
        Write-Ok "CHANGELOG.md stamped v$Version ($today)"
    } else {
        Write-Warn "CHANGELOG.md missing in clone  skipping changelog stamp."
    }

    Push-Location $workDir
    try {
        git add --all 2>&1 | ForEach-Object { Write-Verbose $_ }
        $status = git status --porcelain
        if (-not $status) {
            Write-Warn 'No changes to commit. Nothing to push.'
            return
        }

        $commitMsg = "release: v$Version  $Message"
        if ($DryRun) {
            Write-Step "DRY RUN  skipping commit/push. Pending changes:"
            Write-Host $status
            return
        }

        git -c user.name='MiOS bot' -c user.email='mios@users.noreply.github.com' `
            commit -m $commitMsg 2>&1 | ForEach-Object { Write-Verbose $_ }
        if ($LASTEXITCODE -ne 0) { throw "git commit failed (exit $LASTEXITCODE)." }

        $sha = (git rev-parse HEAD).Trim()
        Write-Step "Pushing to $Branch"
        git push origin $Branch 2>&1 | ForEach-Object { Write-Verbose $_ }
        if ($LASTEXITCODE -ne 0) { throw "git push failed (exit $LASTEXITCODE)." }

        Write-Ok "Commit: $sha"
        Write-Ok "GHCR tag (built by CI): ghcr.io/kabuki94/mios:$Version"
    }
    finally {
        Pop-Location
    }
}
finally {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
