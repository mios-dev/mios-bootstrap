param(
    [string]$TomlPath,
    [string]$UupChannel,
    [string]$BakeDrivers,
    [string]$GamingOptimize
)

$orig = $TomlPath
if (-not (Test-Path $orig)) { $orig = 'C:\MiOS\mios.toml' }
if (-not (Test-Path $orig)) { throw "mios.toml not found at $orig" }

$c = Get-Content $orig -Raw

# Replace UUP channel
$chan = $UupChannel.ToLower()
$c = $c -replace '(?s)(\[editions.mios-xbox\].*?autounattend.uup_channel\s*=\s*")[^"]*(")', ('${1}' + $chan + '${2}')

# Replace/Insert bake_host_drivers
$bake = if ($BakeDrivers -eq 'Enabled') { 'true' } else { 'false' }
if ($c -match 'autounattend.bake_host_drivers\s*=') {
    $c = $c -replace 'autounattend.bake_host_drivers\s*=\s*\w+', "autounattend.bake_host_drivers = $bake"
} else {
    $c = $c -replace '(\[editions.mios-xbox\])', "`$1`r`nautounattend.bake_host_drivers = $bake"
}

# Replace debloat_profile
$game = if ($GamingOptimize -eq 'Enabled') { 'gaming' } else { 'minimal' }
$c = $c -replace '(?s)(\[editions.mios-xbox\].*?autounattend.debloat_profile\s*=\s*")[^"]*(")', ('${1}' + $game + '${2}')

$c | Set-Content "$env:TEMP\mios_run.toml" -Encoding utf8 -Force
