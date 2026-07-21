# Launch MiOS-Cat Live Monitor directly on active logged-on user desktop screen
$monScript = 'C:\mios-bootstrap\cat\autounattend\Monitor-MiosCat.ps1'

# 1. Register Scheduled Task with explicit Interactive Logon Principal (Session 1 Desktop Injection)
try {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoExit -ExecutionPolicy Bypass -File `"$monScript`""
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 1)
    Register-ScheduledTask -TaskName 'MiOSMonitorInteractiveSession' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName 'MiOSMonitorInteractiveSession' | Out-Null
} catch {}

# 2. Win32 P/Invoke Focus
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Focus2 {
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SwitchToThisWindow(IntPtr hWnd, bool fUnknown);
}
"@

try {
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$monScript`"" -PassThru
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 200
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            [Win32Focus2]::ShowWindowAsync($proc.MainWindowHandle, 9) | Out-Null
            [Win32Focus2]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
            [Win32Focus2]::SwitchToThisWindow($proc.MainWindowHandle, $true) | Out-Null
            break
        }
    }
} catch {}

# 3. Create Desktop Shortcuts (.bat and .lnk) for instant desktop access
$desktop = [Environment]::GetFolderPath('Desktop')
if ($desktop -and (Test-Path $desktop)) {
    # .bat shortcut
    $batPath = Join-Path $desktop "MiOS-Cat Live Monitor.bat"
    $batContent = "@echo off`r`npowershell.exe -NoExit -ExecutionPolicy Bypass -File `"C:\mios-bootstrap\cat\autounattend\Monitor-MiosCat.ps1`"`r`n"
    [System.IO.File]::WriteAllText($batPath, $batContent)

    # .lnk shortcut
    $shortcutPath = Join-Path $desktop "MiOS-Cat Live Monitor.lnk"
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($shortcutPath)
    $sc.TargetPath = "powershell.exe"
    $sc.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$monScript`""
    $sc.WorkingDirectory = "C:\mios-bootstrap\cat"
    $sc.IconLocation = "shell32.dll,220"
    $sc.Save()
}
