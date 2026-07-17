# AI-hint: MiOS-Xbox Stage-1 FULL-SCREEN SETUP EXPERIENCE. The ONE topmost,
# borderless, all-monitors window the customer sees at first boot. It is a pure
# READER: every ~1s it reads C:\ProgramData\MiOS\provision-state.json (written
# atomically by MiOS-Provision.ps1 + the in-distro POSIX twin) and renders the single
# total_pct bar + current phase label + MiOS branding (bg #282262 / accent #1A407F /
# cursor #F35C15). It withholds the desktop until Complete=1, then removes its relaunch
# hook and closes so the shell / Xbox FSE takes over. Degrade-open: an error state is
# shown with a "continue to desktop" escape (Esc) so provisioning can never hard-brick
# the box. Dependency-free (built-in WPF); single-instance; runs -STA.
# AI-related: mios-bootstrap, MiOS-Progress.psm1, MiOS-Provision.ps1, New-MiOSAutounattend.ps1, mios.toml [autounattend.provision]
#Requires -Version 5.1
[CmdletBinding()]
param([string]$StateDir = 'C:\ProgramData\MiOS')

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# WPF requires STA; relaunch ourselves in an STA host if we were started MTA.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',$PSCommandPath,'-StateDir',$StateDir) -WindowStyle Hidden | Out-Null } catch {}
    return
}

# Single-instance per interactive session (mutex lives in the session-local namespace).
$created = $false
$mtx = New-Object System.Threading.Mutex($true, 'MiOS-SetupExperience', [ref]$created)
if (-not $created) { return }

$stateFile = Join-Path $StateDir 'provision-state.json'
$runKey    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runValue  = 'MiOS-SetupExperience'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction SilentlyContinue

# --- palette (SSOT-aligned brand colors) ------------------------------------
$BG     = '#282262'   # deep MiOS indigo
$BG2    = '#1B1746'   # darker vignette
$ACCENT = '#1A407F'   # MiOS accent
$CURSOR = '#F35C15'   # MiOS cursor/heat accent
$INK    = '#EDECFF'   # near-white ink
$MUTED  = '#9A96C8'   # muted ink

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False"
        Topmost="True" WindowStartupLocation="Manual" Background="$BG">
  <Grid>
    <Grid.Background>
      <RadialGradientBrush GradientOrigin="0.5,0.4" Center="0.5,0.42" RadiusX="0.9" RadiusY="0.9">
        <GradientStop Color="$BG" Offset="0"/>
        <GradientStop Color="$BG2" Offset="1"/>
      </RadialGradientBrush>
    </Grid.Background>
    <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="920">
      <TextBlock x:Name="Brand" Text="MiOS" FontFamily="Segoe UI" FontSize="72" FontWeight="Bold"
                 Foreground="$INK" HorizontalAlignment="Center" Margin="0,0,0,4"/>
      <TextBlock Text="Setting up your personal operating system" FontFamily="Segoe UI" FontSize="18"
                 Foreground="$MUTED" HorizontalAlignment="Center" Margin="0,0,0,44"/>
      <Grid Width="900">
        <Border Background="#33FFFFFF" CornerRadius="11" Height="22"/>
        <Border x:Name="Fill" HorizontalAlignment="Left" Width="0" Height="22" CornerRadius="11">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="$ACCENT" Offset="0"/>
              <GradientStop Color="$CURSOR" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>
      </Grid>
      <Grid Width="900" Margin="0,16,0,0">
        <TextBlock x:Name="Phase" Text="Preparing..." FontFamily="Segoe UI" FontSize="17"
                   Foreground="$INK" HorizontalAlignment="Left"/>
        <TextBlock x:Name="Pct" Text="0%" FontFamily="Segoe UI" FontSize="17" FontWeight="SemiBold"
                   Foreground="$CURSOR" HorizontalAlignment="Right"/>
      </Grid>
      <TextBlock x:Name="Err" Text="" FontFamily="Segoe UI" FontSize="14" TextWrapping="Wrap"
                 Foreground="#FFB4A0" HorizontalAlignment="Center" Margin="0,26,0,0" MaxWidth="900"/>
      <TextBlock x:Name="Hint" Text="This can take several minutes and may restart. Please wait."
                 FontFamily="Segoe UI" FontSize="13" Foreground="$MUTED"
                 HorizontalAlignment="Center" Margin="0,34,0,0"/>
    </StackPanel>
  </Grid>
</Window>
"@

try {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    # If WPF is somehow unavailable, do NOT block the desktop -- degrade-open.
    return
}

$brand = $win.FindName('Brand')
$fill  = $win.FindName('Fill')
$phase = $win.FindName('Phase')
$pct   = $win.FindName('Pct')
$err   = $win.FindName('Err')
$hint  = $win.FindName('Hint')

# Cover ALL monitors (virtual screen bounds), not just the primary.
$win.Left   = [Windows.SystemParameters]::VirtualScreenLeft
$win.Top    = [Windows.SystemParameters]::VirtualScreenTop
$win.Width  = [Windows.SystemParameters]::VirtualScreenWidth
$win.Height = [Windows.SystemParameters]::VirtualScreenHeight

$script:trackWidth = 900.0
$script:done = $false

function Complete-Handoff {
    if ($script:done) { return }
    $script:done = $true
    # Stop relaunching the bar + do not auto-logon forever; then reveal the shell/FSE.
    try { Remove-ItemProperty -Path $runKey -Name $runValue -Force -ErrorAction SilentlyContinue } catch {}
    try { $win.Close() } catch {}
}

# Esc = continue to desktop now (provisioning keeps running headless in Session 0).
$win.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'Escape') { try { $win.Close() } catch {} } })

# Re-assert topmost defensively so nothing (a toast, an installer) steals the front.
$win.Add_SourceInitialized({ $win.Topmost = $true; try { $win.Activate() } catch {} })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    $win.Topmost = $true
    $total = 0; $label = 'Preparing...'; $curState = 'pending'; $note = ''; $complete = $false
    try {
        if (Test-Path -LiteralPath $stateFile) {
            $raw = [IO.File]::ReadAllText($stateFile)
            if ($raw -and $raw.Trim()) {
                $st = $raw | ConvertFrom-Json
                $total = [int]$st.total_pct
                if ($st.phases) {
                    $idx = [int]$st.phase_index
                    if ($idx -lt 0) { $idx = 0 }
                    if ($idx -ge $st.phases.Count) { $idx = $st.phases.Count - 1 }
                    $cur = $st.phases[$idx]
                    if ($cur) { $label = "$($cur.label)"; $curState = "$($cur.state)"; if ($cur.note) { $note = "$($cur.note)" } }
                    $fb = $st.phases | Where-Object { "$($_.id)" -eq 'firstboot' } | Select-Object -First 1
                    if ($fb -and "$($fb.state)" -eq 'done') { $complete = $true }
                }
                if ($total -ge 100) { $complete = $true }
            }
        }
    } catch {}
    # Registry/file corroboration of completion (belt-and-suspenders).
    if (-not $complete) {
        try { if ((Get-ItemProperty -Path 'HKLM:\SOFTWARE\MiOS\Provision' -Name 'Complete' -ErrorAction Stop).Complete -eq 1) { $complete = $true } } catch {}
    }
    if (-not $complete) { if (Test-Path (Join-Path $StateDir 'provision.complete')) { $complete = $true } }

    if ($total -lt 0) { $total = 0 }; if ($total -gt 100) { $total = 100 }
    $fill.Width = [double]$script:trackWidth * ($total / 100.0)
    $pct.Text = "$total%"
    $phase.Text = $label

    if ($curState -eq 'error') {
        $err.Text = "A step needs attention: $note`nMiOS will keep trying in the background. Press Esc to continue to the desktop."
        $hint.Text = 'You can continue to the desktop and MiOS will finish setting up in the background.'
    } else {
        $err.Text = ''
    }

    if ($complete) {
        $total = 100; $fill.Width = [double]$script:trackWidth; $pct.Text = '100%'
        $phase.Text = 'Ready'
        $timer.Stop()
        Complete-Handoff
    }
})

$win.Add_Loaded({ $timer.Start() })
try { [void]$win.ShowDialog() } finally { try { $mtx.ReleaseMutex() } catch {}; try { $mtx.Dispose() } catch {} }
