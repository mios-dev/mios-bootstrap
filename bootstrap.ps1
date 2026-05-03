#Requires -Version 5.1
# 'MiOS' Bootstrap -- redirector
#
# The unified entry point is now install.ps1.
# This file is retained so existing shortcuts and docs that reference
# bootstrap.ps1 keep working, but it simply delegates to install.ps1.
#
# One-liner (preferred):
#   irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1 | iex

param([switch]$BuildOnly, [switch]$Unattended)

$installScript = Join-Path $PSScriptRoot "install.ps1"

if (Test-Path $installScript) {
    & $installScript @PSBoundParameters
} else {
    # Running piped -- fetch install.ps1 directly
    $url = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1"
    & ([scriptblock]::Create((Invoke-RestMethod $url))) @PSBoundParameters
}
