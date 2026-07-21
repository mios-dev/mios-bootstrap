# Launch MiOS-Cat Live Monitor (Python Rich Cross-Platform TUI) on active user desktop
$pyScript = 'C:\mios-bootstrap\cat\autounattend\mios_monitor.py'

# 1. Register Scheduled Task with explicit Interactive Logon Principal
try {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $action = New-ScheduledTaskAction -Execute 'python.exe' -Argument "`"$pyScript`""
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 1)
    Register-ScheduledTask -TaskName 'MiOSMonitorInteractiveSession' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName 'MiOSMonitorInteractiveSession' | Out-Null
} catch {}

# 2. Win32 P/Invoke Focus + Maximize
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32FocusMaxPy {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SwitchToThisWindow(IntPtr hWnd, bool fUnknown);
}
"@

try {
    $proc = Start-Process -FilePath "python.exe" -ArgumentList "`"$pyScript`"" -PassThru
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 200
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            [Win32FocusMaxPy]::ShowWindow($proc.MainWindowHandle, 3) | Out-Null # SW_MAXIMIZE = 3
            [Win32FocusMaxPy]::ShowWindowAsync($proc.MainWindowHandle, 3) | Out-Null
            [Win32FocusMaxPy]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
            [Win32FocusMaxPy]::SwitchToThisWindow($proc.MainWindowHandle, $true) | Out-Null
            break
        }
    }
} catch {}

# 3. Create Desktop Shortcuts (.bat and .lnk)
$desktop = [Environment]::GetFolderPath('Desktop')
if ($desktop -and (Test-Path $desktop)) {
    $batPath = Join-Path $desktop "MiOS-Cat Live Monitor.bat"
    $batContent = "@echo off`r`npython.exe `"C:\mios-bootstrap\cat\autounattend\mios_monitor.py`"`r`n"
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
