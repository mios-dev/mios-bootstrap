@echo off
:: AI-hint: Thin Windows .bat shim for the mios-install unified provisioning dispatcher -- resolves pwsh.exe/powershell.exe and forwards all arguments unchanged to mios-install.ps1 (the canonical implementation beside it), then mirrors its exit code. Contains zero dispatcher logic of its own.
:: AI-related: installation\mios-install.ps1, installation\mios-install.sh, installation\README.md, cat\MiOS-Cat.ps1, cat\MiOS-Cat.bat, build-mios.ps1, build-mios.sh, Get-MiOS.ps1, mios.toml
:: AI-functions: (none -- pure forwarder, no functions of its own)
::
:: mios-install.bat -- unified MiOS provisioning dispatcher (Windows cmd.exe entry point)
::
:: One dispatcher for direct launching of provisioning FROM ANY STAGE and
:: targeted building of specific images/deployment TYPES (live / xbox /
:: fedora / bootc / oci / seed / flash / build / update). This .bat is a
:: THIN launcher only: it validates that mios-install.ps1 exists beside it,
:: picks a PowerShell host, forwards every argument verbatim, and returns
:: the same exit code the underlying pipeline returned. All target
:: validation, --type/--stage/--dry-run/--unattended parsing, the
:: target-to-entrypoint mapping table, and per-target self-elevation live in
:: mios-install.ps1 -- see installation/README.md for the full grammar and
:: design rationale. This dispatcher never moves, renames, or rewrites the
:: existing entrypoints it calls (MiOS-Cat.bat, build-mios.ps1, build-mios.sh,
:: the autounattend\*.ps1 scripts, mios-build, mios-update) -- it only builds
:: the right argv/env for one of them and launches it.
::
:: DESIGN NOTE -- do NOT "fix" this to match MiOS-Cat's .bat-canonical /
:: .ps1-shim convention; the relationship here is deliberately the INVERSE.
:: MiOS-Cat.bat is canonical (with MiOS-Cat.ps1 as its thin shim) because
:: MiOS-Cat targets factory-fresh Windows boxes where cmd.exe is the only
:: guaranteed-present, double-click-safe, execution-policy-free handle.
:: mios-install is reached only after the repo is already cloned and being
:: operated from a shell (Get-MiOS.ps1's job, not this dispatcher's -- see
:: README.md "Not covered by any target"), so mios-install.ps1 is free to
:: carry the real grammar and THIS .bat exists purely for callers/scripts
:: that only have cmd.exe available.
::
:: Usage:
::   mios-install.bat <target> [--type <name>] [--stage <name>] [--dry-run] [--unattended] [-- <native args>]
::
:: Targets: live | xbox | fedora | bootc | oci | seed | flash | build | update
:: Stages:  prereqs | fetch | service | iso | flash
::
:: Examples:
::   mios-install.bat flash --dry-run
::   mios-install.bat xbox --type vm --stage flash
::   mios-install.bat oci --stage iso --unattended
::   mios-install.bat seed -- -BuilderDistro MiOS-DEV-2 -Force
::
:: Exit code: mirrors mios-install.ps1's exit code, which in turn mirrors
:: the wrapped entrypoint's exit code -- same convention MiOS-Cat.ps1 uses
:: forwarding into MiOS-Cat.bat (`& $target; exit $LASTEXITCODE`).

setlocal
cd /d "%~dp0"

set "MIOS_INSTALL_PS1=%~dp0mios-install.ps1"
if not exist "%MIOS_INSTALL_PS1%" (
    echo [mios-install] ERROR: mios-install.ps1 not found beside this shim ^(%MIOS_INSTALL_PS1%^) -- cannot forward. 1>&2
    exit /b 1
)

:: Prefer pwsh.exe (PowerShell 7+) when present on PATH; fall back to the
:: always-present Windows PowerShell 5.1. Neither the dispatcher nor the
:: entrypoints it wraps require pwsh-7 -- same "5.1 baseline, pwsh is a
:: bonus" posture as build-mios.ps1.
set "MIOS_PSEXE=powershell.exe"
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% equ 0 set "MIOS_PSEXE=pwsh.exe"

"%MIOS_PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%MIOS_INSTALL_PS1%" %*
set "MIOS_INSTALL_RC=%ERRORLEVEL%"

endlocal & exit /b %MIOS_INSTALL_RC%
