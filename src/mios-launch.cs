using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

class MiOSLaunch {
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int q, uint f);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L,T,R,B; }

    static int Main(string[] args) {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch {}
        string profile = (args.Length > 0) ? args[0] : "MiOS";
        string cols = (args.Length > 1) ? args[1] : "80";
        string rows = (args.Length > 2) ? args[2] : "20";
        // Resolve wt.exe via APPX install location (preferred) or PATH.
        string wt = null;
        try {
            string ps = "powershell.exe";
            var psi = new ProcessStartInfo(ps, "-NoProfile -Command \"(Get-AppxPackage Microsoft.WindowsTerminal).InstallLocation\"");
            psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.CreateNoWindow = true;
            var p = Process.Start(psi); string loc = p.StandardOutput.ReadToEnd().Trim(); p.WaitForExit();
            if (!string.IsNullOrEmpty(loc)) {
                string cand = Path.Combine(loc, "wt.exe");
                if (File.Exists(cand)) wt = cand;
            }
        } catch {}
        if (wt == null) {
            foreach (string d in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';')) {
                if (string.IsNullOrEmpty(d)) continue;
                try { string c = Path.Combine(d, "wt.exe"); if (File.Exists(c)) { wt = c; break; } } catch {}
            }
        }
        if (wt == null) { MessageBox.Show("Windows Terminal (wt.exe) not found. Re-run the MiOS bootstrap.","MiOS",MessageBoxButtons.OK,MessageBoxIcon.Error); return 1; }
        // Operator rationale (image #11): "Subsequent MiOS windows should
        // launch nested inside one-another as a new tab". Use SHARED
        // window name "MiOS" (not per-profile) so wt.exe routes every
        // MiOS click into the SAME window. New tab if MiOS window
        // exists; new window if it doesn't. -p selects the profile
        // for the new tab. Plus: same window name = same hwnd lookup
        // for centering, so MiOS / MiOS-WIN / MiOS Help all center
        // identically (was: per-profile window name made every click
        // a separate hwnd that the centering loop sometimes missed).
        DateTime spawnAt = DateTime.UtcNow;
        try {
            var psi = new ProcessStartInfo(wt, "-w MiOS --size " + cols + "," + rows + " --focus -p " + profile);
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            Process.Start(psi);
        } catch (Exception ex) { MessageBox.Show("wt.exe spawn failed: " + ex.Message,"MiOS",MessageBoxButtons.OK,MessageBoxIcon.Error); return 2; }
        // Find the WT window we just spawned + center it on the
        // operator's active monitor. 12 ticks @ 500ms = ~6s of
        // persistent re-centering to defeat WT's post-spawn layout
        // renegotiations.
        IntPtr hwnd = IntPtr.Zero;
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(8000);
        while (DateTime.UtcNow < deadline && hwnd == IntPtr.Zero) {
            try {
                var ps = Process.GetProcessesByName("WindowsTerminal").Where(p => p.StartTime.ToUniversalTime() >= spawnAt.AddSeconds(-1)).OrderByDescending(p => p.StartTime).FirstOrDefault();
                if (ps != null && ps.MainWindowHandle != IntPtr.Zero && IsWindowVisible(ps.MainWindowHandle)) hwnd = ps.MainWindowHandle;
            } catch {}
            if (hwnd == IntPtr.Zero) Thread.Sleep(150);
        }
        if (hwnd == IntPtr.Zero) return 0;
        Point cur = Cursor.Position;
        Screen scr = Screen.FromPoint(cur);
        for (int i = 0; i < 12; i++) {
            RECT r;
            if (GetWindowRect(hwnd, out r)) {
                int w = r.R - r.L, h = r.B - r.T;
                if (w > 0 && h > 0) {
                    int x = scr.WorkingArea.X + Math.Max(0, scr.WorkingArea.Width  - w) / 2;
                    int y = scr.WorkingArea.Y + Math.Max(0, scr.WorkingArea.Height - h) / 2;
                    // SWP_NOZORDER | SWP_NOACTIVATE = 0x14
                    SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, 0x14);
                }
            }
            Thread.Sleep(500);
        }
        return 0;
    }
}
