<!-- AI-hint: How MiOS + its services come up as boot-time system services BEFORE any logon/desktop/RDP on the MiOS-XBOX Windows edition. Documents the researched hard constraint (wsl.exe cannot run as LocalSystem), the dedicated mios-svc account model, the specialize-pass provisioner, the MiOS-Host ONSTART keep-alive task, RDP enablement, and the honest limits (services "started before logon", not "app-ready before shell"). -->
<!-- AI-related: MiOS-Host.ps1, New-MiOSHostServiceCommands (MiOS-Provision.lib.ps1), New-MiOSAutounattend.ps1, New-MiOSISO.ps1, mios.toml [autounattend.service] -->

# MiOS as boot-time system services (up before logon)

Requirement: **MiOS and all MiOS services run at Windows boot, before the logon
screen / desktop / RDP session shows a desktop** — not via per-user post-logon
`FirstLogonCommands`.

## The hard constraint that shapes the design

**`wsl.exe` cannot run as `LocalSystem` / `NT AUTHORITY\SYSTEM`.** WSL is tied to a
user profile — a distro registers in `HKCU\...\Lxss`, and SYSTEM's profile is
separate — so a distro is invisible to SYSTEM and importing under SYSTEM fails.
A WSL maintainer confirms this is "by design" (microsoft/WSL#11280). The Session-0
*access* barrier (a service/task calling WSL with no interactive user) was fixed in
WSL 2.0.0, but only via the packaged `C:\Program Files\WSL\wsl.exe`, and still only
under a **real user account**, never SYSTEM.

→ The MiOS boot service therefore runs under a **dedicated, NON-admin local account
`mios-svc`** (SSOT `[autounattend.service].svc_user`). The interactive/Xbox desktop
user must be a **different** account (running `wsl` as the same account the boot
service uses would tear down the boot instance).

## Architecture

```
Windows boot
  └─ specialize pass (SYSTEM, pre-OOBE, pre-logon)   ← New-MiOSHostServiceCommands
       ├─ enable VirtualMachinePlatform + WSL         (the MiOS-brain minimum)
       ├─ create .\mios-svc  (non-admin)
       ├─ enable RDP  (fDenyTSConnections=0 + firewall group + NLA)
       └─ schtasks /create MiOS-Host /sc ONSTART /ru mios-svc  → MiOS-Host.ps1
  └─ every boot, Session 0, BEFORE logon             ← MiOS-Host.ps1 (as mios-svc)
       ├─ FIRST run only: irm Get-MiOS.ps1 | iex      (heavy install: wsl import +
       │                                               podman + Quadlet units)
       └─ every run: start distro + hold it alive
            wsl -d MiOS --exec … sleep infinity        (host-side keep-alive)
              └─ inside: /etc/wsl.conf [boot] systemd=true
                   └─ systemd brings up podman.socket + MiOS Quadlet services
  └─ Winlogon → (auto-login local user) → Xbox FSE shell   ← AFTER services are up
```

Why each choice:
- **specialize `Microsoft-Windows-Deployment\RunSynchronous`** is the earliest
  SYSTEM-context, pre-OOBE, pre-logon answer-file hook, and (unlike
  `SetupComplete.cmd`) is not disabled under OEM product keys. It does the *minimal*
  one-time setup and hands the heavy install to the service.
- **ONSTART scheduled task** (not a raw service): a bare `wsl.exe` keep-alive is not
  a valid Windows service (no service-control dispatcher → SCM error 1053); an
  ONSTART task runs it directly, in Session 0, before any logon. (An NSSM/WinSW
  wrapper is the alternative if a true Service entry is wanted.)
- **Host-side `--exec sleep infinity`** is the reliable keep-alive. `vmIdleTimeout=-1`
  alone does not stop teardown on last-process-exit, and an in-distro systemd holder
  regressed (WSL 2.5.10/2.6.1) — so the holder lives on the host side.

## RDP

Three settings, all required (setting `fDenyTSConnections` alone is insufficient):
`fDenyTSConnections=0`, the "remote desktop" firewall group enabled, and
`UserAuthentication=1` (NLA). Windows **Home cannot host RDP** — MiOS-XBOX targets
Pro/Enterprise.

## Honest limits (verify on the target build)

- **"Started before logon" ≠ "app-ready before the shell."** Automatic Session-0
  services start at boot before any interactive/RDP session — but there is **no
  supported knob to make Winlogon/the shell WAIT** until the MiOS plane reports
  ready. If the Xbox dashboard needs the plane ready, it should poll a MiOS health
  endpoint. Use plain **Automatic** (not Delayed-Start).
- **`wsl.exe` under Session 0 is version-sensitive** — use the packaged
  `C:\Program Files\WSL\wsl.exe`; test on the exact 24H2/25H2/Dev build.
- **Service-account credential** is stored in the answer file + the task — a
  first-boot temporary cred (SSOT `[identity].default_password`); rotate on first run.
- The account should generally **not** be in Administrators (an admin identity from a
  service has hit `Access is denied` on some builds); grant it "Log on as a batch job"
  (schtasks does this when registering with stored creds).

## SSOT

`mios.toml [autounattend.service]`: `enable`, `svc_user`, `svc_password`
(empty → `[identity].default_password`), `wsl_distro`, `host_script`, `enable_rdp`.
