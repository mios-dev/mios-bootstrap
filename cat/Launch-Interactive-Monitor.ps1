# Launch MiOS-Cat Live Monitor directly on active logged-on user desktop screen
$monScript = 'C:\mios-bootstrap\cat\autounattend\Monitor-MiosCat.ps1'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Focus {
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SwitchToThisWindow(IntPtr hWnd, bool fUnknown);
}
"@

# 1. Launch standard PowerShell console process
$proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$monScript`"" -PassThru

# 2. Force focus into active foreground via Win32 P/Invoke
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Milliseconds 200
    $proc.Refresh()
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        [Win32Focus]::ShowWindowAsync($proc.MainWindowHandle, 9) | Out-Null
        [Win32Focus]::ShowWindowAsync($proc.MainWindowHandle, 5) | Out-Null
        [Win32Focus]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
        [Win32Focus]::SwitchToThisWindow($proc.MainWindowHandle, $true) | Out-Null
        break
    }
}

# 3. Scheduled Task fallback
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
