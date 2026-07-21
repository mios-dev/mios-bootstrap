# Win32 P/Invoke to force-pop the Live Monitor console window into the active foreground
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

$monScript = 'C:\mios-bootstrap\cat\autounattend\Monitor-MiosCat.ps1'

# Start powershell process
$proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$monScript`"" -PassThru

# Wait up to 3 seconds for window handle
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
