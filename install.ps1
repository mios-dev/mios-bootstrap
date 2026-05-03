#Requires -Version 5.1
# 'MiOS' bootstrap installer (Windows) -- legacy redirector.
#
# Renamed to build-mios.ps1 to align with the cross-platform entry-point
# convention (build-mios.{sh,ps1}). This redirector exists so existing
# 'irm ... install.ps1 | iex' one-liners keep working.

param([switch]$BuildOnly, [switch]$Unattended)

$ErrorActionPreference = "Stop"
$target = Join-Path $PSScriptRoot 'build-mios.ps1'
if (-not (Test-Path $target)) {
    # When running piped via irm | iex, $PSScriptRoot is empty -- fetch the
    # canonical script over the network instead.
    $url = "https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/build-mios.ps1"
    & ([scriptblock]::Create((Invoke-RestMethod $url))) @PSBoundParameters
    exit $LASTEXITCODE
}
& $target @PSBoundParameters
exit $LASTEXITCODE
