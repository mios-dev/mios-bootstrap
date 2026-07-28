
# MiOS Build Monitor - watches for a new build log and tails it live
# Writes a condensed error/warning stream to mios-monitor-alerts.log

param([string]$LogDir = "M:\MiOS\medicat_stage\isobuild_live\logs")

$alertLog = "C:\mios-bootstrap\installation\mios-monitor-alerts.log"
"[$(Get-Date -f 'HH:mm:ss')] Monitor started. Waiting for new build log in: $LogDir" | Tee-Object -FilePath $alertLog

$seenLog = $null
$lastSize = 0

while ($true) {
    # Detect newest build log
    $logs = Get-ChildItem $LogDir -Filter "build-*.log" -EA SilentlyContinue | Sort-Object LastWriteTime -Descending
    $newest = $logs | Select-Object -First 1

    if ($newest -and $newest.FullName -ne $seenLog) {
        $seenLog = $newest.FullName
        $lastSize = 0
        "[$(Get-Date -f 'HH:mm:ss')] >>> Watching new build log: $seenLog" | Tee-Object -FilePath $alertLog -Append
    }

    if ($seenLog -and (Test-Path $seenLog)) {
        $content = Get-Content $seenLog -Raw -EA SilentlyContinue
        if ($content -and $content.Length -gt $lastSize) {
            $newText = $content.Substring($lastSize)
            $lastSize = $content.Length

            # Output all new lines
            $newText -split "`n" | Where-Object { $_.Trim() } | ForEach-Object {
                Write-Host $_

                # Alert on errors/fatals
                if ($_ -match 'TerminatingError|FATAL|FAILED|ERROR:|Access.*denied|cannot access|not supported|Dismount.*Error' -and $_ -notmatch '^\*\*\*\*') {
                    "[$(Get-Date -f 'HH:mm:ss')] [ALERT] $_" | Add-Content $alertLog
                }
                # Flag progress milestones
                elseif ($_ -match '^\[[\*\+!]|====') {
                    "[$(Get-Date -f 'HH:mm:ss')] [INFO] $($_.Trim())" | Add-Content $alertLog
                }
            }
        }
    }

    Start-Sleep -Milliseconds 1500
}
