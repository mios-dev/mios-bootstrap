# Launch MiOS-Cat Live Monitor directly on active logged-on user desktop screen
$monScript = 'C:\mios-bootstrap\cat\autounattend\Monitor-MiosCat.ps1'

# 1. Launch standard PowerShell console directly in foreground
try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$monScript`"" -ErrorAction SilentlyContinue
} catch {}

# 2. Backup launch via cmd start
try {
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c start `"MiOS Live Flash Monitor`" powershell.exe -NoExit -ExecutionPolicy Bypass -File `"$monScript`"" -ErrorAction SilentlyContinue
} catch {}

# 3. Scheduled Task fallback for user token
try {
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoExit -ExecutionPolicy Bypass -File `"$monScript`""
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 1)
    Register-ScheduledTask -TaskName 'MiOSMonitorUserInteractive' -Action $action -Settings $settings -User $user -Force | Out-Null
    Start-ScheduledTask -TaskName 'MiOSMonitorUserInteractive' | Out-Null
} catch {}

# 4. Ensure Desktop Shortcut exists
$desktop = [Environment]::GetFolderPath('Desktop')
if ($desktop -and (Test-Path $desktop)) {
    $shortcutPath = Join-Path $desktop "MiOS-Cat Live Monitor.lnk"
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($shortcutPath)
    $sc.TargetPath = "powershell.exe"
    $sc.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$monScript`""
    $sc.WorkingDirectory = "C:\mios-bootstrap\cat"
    $sc.IconLocation = "shell32.dll,220"
    $sc.Save()
}
