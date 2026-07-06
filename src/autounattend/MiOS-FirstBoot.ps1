# ============================================================================
#  MiOS-FirstBoot.ps1 -- reliable first-logon brain + gaming deploy trigger.
#  Staged into the image at C:\ProgramData\MiOS\ and launched (hidden) by the
#  All-Users Startup shortcut MiOS-FirstBoot.cmd at the FIRST interactive logon
#  (the auto-logon desktop user). WHY here and not a service-account scheduled
#  task: the renamed built-in-admin (mios-sudo) tasks would not register/run, and
#  the ONLOGON tasks never registered in specialize -- so the brain never
#  deployed. This runs in the REAL logged-in session (WSL needs a user profile)
#  and, with the guest's ConsentPromptBehaviorAdmin=0 (silent admin elevation,
#  baked in mios-debloat.json), the bootstrap's self-elevation raises NO UAC
#  prompt. Fire-and-forget so the desktop is not blocked; marker-gated one-time;
#  removes its own Startup shortcut when done. All non-interactive (agreement +
#  prompt env vars declared for the nested bootstrap).
# ============================================================================
$ErrorActionPreference = 'SilentlyContinue'
$state = 'C:\ProgramData\MiOS'
New-Item -ItemType Directory -Force -Path (Join-Path $state 'logs') | Out-Null
$log = Join-Path $state 'logs\firstboot.log'
function L($m) { "$([DateTime]::Now.ToString('HH:mm:ss')) $m" | Add-Content $log }
$startup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\MiOS-FirstBoot.cmd'
$marker = Join-Path $state 'firstboot.launched'
if (Test-Path $marker) { L 'already launched -- removing Startup shortcut'; Remove-Item $startup -Force -EA SilentlyContinue; exit 0 }
'launched' | Set-Content $marker
L 'first-logon deploy: firing MiOS brain install + Xbox hydration (hidden, detached)'
# Declared unattended so the nested Get-MiOS bootstrap never blocks on the AGREEMENTS
# gate or 90s prompts (inherited by the child processes below).
$env:MIOS_AGREEMENT_ACK    = 'accepted'
$env:MIOS_AGREEMENT_BANNER = 'silent'
$env:MIOS_PROMPT_TIMEOUT   = '1'
# Brain install (WSL2 + MiOS agent stack) -- self-elevates silently (ConsentPromptBehavior
# Admin=0). Fire-and-forget so first logon is not held for the long install.
if (Test-Path (Join-Path $state 'MiOS-Host.ps1')) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $state 'MiOS-Host.ps1')
    L 'started MiOS-Host.ps1 (brain install)'
}
# Gaming Services + Xbox app + WebView2 via winget msstore (Store-locked, cannot bake).
if (Test-Path (Join-Path $state 'MiOS-XBOX-Hydrate.ps1')) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $state 'MiOS-XBOX-Hydrate.ps1')
    L 'started MiOS-XBOX-Hydrate.ps1 (Gaming Services)'
}
Remove-Item $startup -Force -EA SilentlyContinue
L 'first-logon deploy fired; Startup shortcut removed'
exit 0
