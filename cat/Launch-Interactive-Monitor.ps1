# Launch MiOS-Cat Live Monitor (Python Rich Cross-Platform TUI) on active user desktop using CMD START
$pyScript = 'C:\mios-bootstrap\cat\autounattend\mios_monitor.py'

# 1. Register Scheduled Task with explicit Interactive Logon Principal
try {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c start `"MiOS-Cat Live Monitor`" python.exe `"$pyScript`""
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 1)
    Register-ScheduledTask -TaskName 'MiOSMonitorInteractiveSession' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName 'MiOSMonitorInteractiveSession' | Out-Null
} catch {}

# 2. Launch via cmd.exe /c start to guarantee visible GUI console window on Session 1 Desktop
try {
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c start `"MiOS-Cat Live Monitor`" python.exe `"$pyScript`"" -WindowStyle Normal
} catch {}

# 3. Create Desktop Shortcuts (.bat and .lnk)
$desktop = [Environment]::GetFolderPath('Desktop')
if ($desktop -and (Test-Path $desktop)) {
    $batPath = Join-Path $desktop "MiOS-Cat Live Monitor.bat"
    $batContent = "@echo off`r`nstart `"MiOS-Cat Live Monitor`" python.exe `"C:\mios-bootstrap\cat\autounattend\mios_monitor.py`"`r`n"
    [System.IO.File]::WriteAllText($batPath, $batContent)

    $shortcutPath = Join-Path $desktop "MiOS-Cat Live Monitor.lnk"
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($shortcutPath)
    $sc.TargetPath = "python.exe"
    $sc.Arguments = "`"$pyScript`""
    $sc.WorkingDirectory = "C:\mios-bootstrap\cat"
    $sc.IconLocation = "shell32.dll,220"
    $sc.Save()
}
