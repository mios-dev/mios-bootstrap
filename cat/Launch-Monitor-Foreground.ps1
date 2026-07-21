$code = @"
using System;
using System.Runtime.InteropServices;

public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
}
"@
Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue

$ps = Start-Process powershell.exe -ArgumentList "-NoExit -ExecutionPolicy Bypass -File C:\mios-bootstrap\cat\autounattend\Monitor-MiosCat.ps1" -PassThru -WindowStyle Normal
Start-Sleep -Seconds 2

if ($ps -and $ps.MainWindowHandle -ne [IntPtr]::Zero) {
    [Win32]::ShowWindowAsync($ps.MainWindowHandle, 9)
    [Win32]::SetForegroundWindow($ps.MainWindowHandle)
}
