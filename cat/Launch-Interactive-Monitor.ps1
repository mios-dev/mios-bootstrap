# Launch MiOS-Cat Live Monitor directly on active logged-on user desktop screen
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoExit -ExecutionPolicy Bypass -File C:\mios-bootstrap\cat\autounattend\Monitor-MiosCat.ps1'
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 1)

Register-ScheduledTask -TaskName 'MiOSMonitorUserInteractive' -Action $action -Settings $settings -User $user -Force | Out-Null
Start-ScheduledTask -TaskName 'MiOSMonitorUserInteractive'

# Also create Desktop Shortcut for instant one-click visibility
$desktop = [Environment]::GetFolderPath('Desktop')
if ($desktop -and (Test-Path $desktop)) {
    $shortcutPath = Join-Path $desktop "MiOS-Cat Live Monitor.lnk"
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($shortcutPath)
    $sc.TargetPath = "powershell.exe"
    $sc.Arguments = "-NoExit -ExecutionPolicy Bypass -File C:\mios-bootstrap\cat\autounattend\Monitor-MiosCat.ps1"
    $sc.WorkingDirectory = "C:\mios-bootstrap\cat"
    $sc.IconLocation = "shell32.dll,220"
    $sc.Save()
}
