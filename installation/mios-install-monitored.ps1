$LogFile = "C:\mios-bootstrap\installation\mios-install-live.log"
"" | Set-Content $LogFile  # clear log

# Run mios-install.ps1, tee ALL output (stdout + stderr) to log file in real-time
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\mios-install.ps1" @args 2>&1 | Tee-Object -FilePath $LogFile -Append
exit $LASTEXITCODE
