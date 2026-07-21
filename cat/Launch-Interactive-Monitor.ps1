# Launch MiOS-Cat Live Monitor (Python Rich Cross-Platform TUI) on active user desktop screen
$pyScript = 'C:\mios-bootstrap\cat\autounattend\mios_monitor.py'
$desktop = [Environment]::GetFolderPath('Desktop')
$batPath = Join-Path $desktop "MiOS-Cat Live Monitor.bat"

# 1. Write Desktop Launcher Batch Script
$batContent = "@echo off`r`nstart `"MiOS Live Monitor`" python.exe `"C:\mios-bootstrap\cat\autounattend\mios_monitor.py`"`r`n"
[System.IO.File]::WriteAllText($batPath, $batContent)

# 2. Launch via Explorer Shell Execution to force visible foreground desktop window
try {
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$batPath`""
} catch {}

# 3. Register Scheduled Task with explicit Interactive Logon Principal as backup
try {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c start `"MiOS Live Monitor`" python.exe `"$pyScript`""
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 1)
    Register-ScheduledTask -TaskName 'MiOSMonitorInteractiveSession' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName 'MiOSMonitorInteractiveSession' | Out-Null
} catch {}
