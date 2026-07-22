try {
    $r = (Invoke-WebRequest -Uri 'https://www.system-rescue.org/Download/' -UseBasicParsing -TimeoutSec 6 -Headers @{'User-Agent'='MiOS-Cat'}).Content
    if ($r -match 'systemrescue-([0-9]+\.[0-9]+)-amd64\.iso') {
        Set-Content -LiteralPath "$env:TEMP\sysrescue_ver.txt" -Value $Matches[1]
    }
} catch {}
