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

# Acknowledgment banner. Delegates to install.ps1 which prints its own;
# kept here for the case where install.ps1 isn't yet on disk.
if ($env:MIOS_AGREEMENT_BANNER -notin @('quiet','silent','off','0','false','FALSE')) {
    [Console]::Error.WriteLine(@"
[mios] By invoking bootstrap.ps1 you acknowledge AGREEMENTS.md
       (Apache-2.0 main + bundled-component licenses in LICENSES.md +
        attribution in CREDITS.md). 'MiOS' is a research project
       (pronounced 'MyOS'; generative, seed-script-derived).
"@)
}

$installScript = Join-Path $PSScriptRoot "install.ps1"

if (Test-Path $installScript) {
    & $installScript @PSBoundParameters
} else {
    # Running piped -- fetch install.ps1 directly
    $url = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.ps1"
    & ([scriptblock]::Create((Invoke-RestMethod $url))) @PSBoundParameters
}
