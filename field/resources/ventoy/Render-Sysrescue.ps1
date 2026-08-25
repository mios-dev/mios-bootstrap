<#
.SYNOPSIS
  Project [cat.sysrescue] (+ [identity].default_password) from mios.toml SSOT onto the
  flashed SystemRescue surfaces: (1) rewrite the deployed Ventoy grub.cfg boot options
  (rootpass / nofirewall / ar_source label), and (2) emit a runtime env file the autorun
  firstboot script sources for the mios user + password + connection-header toggle.

  SSOT is defined ONCE in mios.toml and rendered here at build/flash time; nothing is
  hand-maintained on the stick. Degrade-open: any failure leaves the checked-in grub.cfg
  defaults (rootpass=mios nofirewall ...) in place, which already boot SSH-enabled.
.NOTES
  Called by installation\MiOS-Cat.bat after the Ventoy config is deployed to the stick.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$TargetDrive,          # e.g. "D"
  [string]$TomlPath = "",
  [string]$PartitionLabel = "MiOS-Cat"                 # fallback ar_source label ([cat.sysrescue].ar_source_label)
)
$ErrorActionPreference = 'Stop'
function Note($m){ Write-Host "[render-sysrescue] $m" }

try {
  # --- resolve the SSOT mios.toml (arg -> repo-local -> canonical MiOS host copy) --------
  if (-not $TomlPath -or -not (Test-Path -LiteralPath $TomlPath)) {
    $cand = @(
      (Join-Path $PSScriptRoot '..\..\..\mios.toml'),          # cat\resources\ventoy -> repo root
      'C:\MiOS\usr\share\mios\mios.toml'
    )
    $TomlPath = $cand | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  }
  if (-not $TomlPath) { Note "no mios.toml found -- leaving grub.cfg defaults (degrade-open)."; return }
  $toml = Get-Content -Raw -LiteralPath $TomlPath

  # --- minimal SSOT readers: G=top-level key, GS=key within a [section] --------------------
  function G([string]$k,[string]$def=''){
    $m=[regex]::Match($toml,('(?m)^\s*'+[regex]::Escape($k)+'\s*=\s*(?:"([^"\r\n]*)"|(\d+)|(true|false))'))
    if($m.Success){ if($m.Groups[1].Value){$m.Groups[1].Value}elseif($m.Groups[2].Value){$m.Groups[2].Value}else{$m.Groups[3].Value} } else { $def }
  }
  function GS([string]$sec,[string]$k,[string]$def=''){
    $sm=[regex]::Match($toml,('(?ms)^\s*\['+[regex]::Escape($sec)+'\]\s*(.*?)(?=\r?\n\s*\[|\Z)'))
    if($sm.Success){
      $m=[regex]::Match($sm.Groups[1].Value,('(?m)^\s*'+[regex]::Escape($k)+'\s*=\s*(?:"([^"\r\n]*)"|(\d+)|(true|false))'))
      if($m.Success){ if($m.Groups[1].Value){$m.Groups[1].Value}elseif($m.Groups[2].Value){$m.Groups[2].Value}else{$m.Groups[3].Value} } else { $def }
    } else { $def }
  }
  function IsTrue($v){ "$v" -match '^(?i:true|1|yes)$' }

  if (-not (IsTrue (GS 'cat.sysrescue' 'enable' 'true'))) { Note "[cat.sysrescue].enable=false -- skipping."; return }

  # --- resolve the projected values (one SSOT password chain: sysrescue.password -> default_password)
  $user   = GS 'cat.sysrescue' 'username' 'mios'
  $pass   = GS 'cat.sysrescue' 'password' ''
  if (-not $pass) { $pass = G 'default_password' 'mios' }
  $nofw   = IsTrue (GS 'cat.sysrescue' 'nofirewall' 'true')
  $rootlg = IsTrue (GS 'cat.sysrescue' 'root_login' 'true')
  $header = IsTrue (GS 'cat.sysrescue' 'connection_header' 'true')
  $label  = GS 'cat.sysrescue' 'ar_source_label' ''
  if (-not $label) { $label = $PartitionLabel }
  if (-not $label) { $label = 'MiOS-Cat' }
  # Passphrase gating the superuser-only "Wipe MiOS" GRUB entry. GRUB word-splits the
  # `password` line, so strip anything that would break parsing (keep alnum . _ -).
  $wipePass = GS 'cat.sysrescue' 'wipe_passphrase' 'mios'
  $wipePass = ($wipePass -replace '[^\w.\-]', '')
  if (-not $wipePass) { $wipePass = 'mios' }

  # --- (1) render the deployed grub.cfg boot options from the checked-in defaults ----------
  # SAFETY: ar_suffixes SPLITS the autorun paths so they can never cross -- the SSH boot entries
  # run autorun0 (the safe firstboot: mios user + connection header), while the destructive
  # whole-disk WIPE lives on autorun9, reachable ONLY from the explicit "WIPE ALL DISKS" menu
  # entry. The plain-`autorun` slot is left empty. We render rootpass/nofirewall + the ar_source
  # partition label from SSOT; the ar_suffixes split is structural (defined in the grub.cfg).
  $grub = "${TargetDrive}:\ventoy\sysrescue_grub.cfg"
  if (Test-Path -LiteralPath $grub) {
    $c = Get-Content -Raw -LiteralPath $grub
    $c = $c -replace 'password rescue mios', ("password rescue " + $wipePass)   # BEFORE rootpass=mios
    $c = $c -replace 'rootpass=mios', ("rootpass=" + $pass)
    $c = $c -replace 'by-label/MiOS-Cat', ("by-label/" + $label)
    if (-not $nofw)   { $c = $c -replace ' nofirewall','' }
    if (-not $rootlg) { $c = $c -replace 'rootpass=[^\s]+\s*','' }
    Set-Content -LiteralPath $grub -Value $c -Encoding ASCII
    Note "grub.cfg rendered (root login, pass=<ssot>, nofirewall=$nofw, label=$label; Wipe MiOS gated by superuser passphrase on autorun9)."
  } else { Note "deployed grub.cfg not found at $grub -- skipped (Ventoy config may not be staged)." }

  # --- (1b) render the SYSLINUX (BIOS/legacy) SystemRescue boot config the same way --------
  $syslinux = "${TargetDrive}:\ventoy\sysrescue_syslinux.cfg"
  if (Test-Path -LiteralPath $syslinux) {
    $s = Get-Content -Raw -LiteralPath $syslinux
    $s = $s -replace 'rootpass=mios', ("rootpass=" + $pass)
    $s = $s -replace 'by-label/MiOS-Cat', ("by-label/" + $label)
    if (-not $nofw) { $s = $s -replace ' nofirewall','' }
    Set-Content -LiteralPath $syslinux -Value $s -Encoding ASCII
    Note "syslinux.cfg (BIOS path) rendered (pass=<ssot>, nofirewall=$nofw, label=$label)."
  }

  # --- (2) emit the runtime SSOT env the autorun0 firstboot script sources -----------------
  # Written to the PARTITION ROOT (beside autorun0), so 01-sysrescue-firstboot.sh finds it via
  # dirname($0) when SystemRescue mounts the ar_source device and runs <mount>/autorun0.
  $hv = if ($header) { '1' } else { '0' }
  $envLines = @(
    "# Rendered from mios.toml [cat.sysrescue] SSOT by Render-Sysrescue.ps1. Do not hand-edit.",
    "MIOS_SR_USER='$user'",
    "MIOS_SR_PASS='$pass'",
    "MIOS_SR_HEADER='$hv'"
  )
  Set-Content -LiteralPath "${TargetDrive}:\mios-sysrescue.env" -Value $envLines -Encoding ASCII
  Note "runtime SSOT env -> \mios-sysrescue.env at partition root (user=$user, header=$header)."
} catch {
  Note ("non-fatal: " + $_.Exception.Message.Split([Environment]::NewLine)[0] + " -- grub.cfg defaults stand (SSH still enabled).")
}
