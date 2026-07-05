<!-- AI-hint: How to authenticate + launch the automated, elevated MiOS-XBOX ISO build (Build-MiOSXboxISO.ps1) inside a remote Windows App / AVD / Windows 365 Cloud PC / Dev Box / Remote-PC session -- without re-typing admin creds and without a UAC click. Covers the three auth boundaries (connect / elevate / launch+double-hop), the ranked recommendation (pre-registered elevated scheduled task, gMSA or SYSTEM), and the Register-MiOSBuildTask.ps1 helper. -->
<!-- AI-related: Build-MiOSXboxISO.ps1, Register-MiOSBuildTask.ps1, New-MiOSISO.ps1 -->

# Authing the launch of the automated build in a remote session

You connect via **Windows App** (the 2024 rebrand of the Remote Desktop client →
AVD / Windows 365 Cloud PC / Dev Box / Remote PC) and want to kick off the
long-running, **elevated** MiOS-XBOX build (DISM mounts + web fetch + oscdimg)
with no credential re-typing and no UAC stall. There are **three distinct auth
boundaries** — conflating them is the usual mistake:

1. **Connect** — proving who you are to the session broker (Entra ID / RDP NLA).
2. **Elevate** — getting a full admin token in the session with no UAC click.
3. **Launch** — authorizing the build to *start* unattended, and letting it reach
   the web/UNC (the **double-hop**).

## The MiOS answer (right-sized for a single build box)

**A pre-registered elevated scheduled task, triggered on demand.** `Register-MiOSBuildTask.ps1`
registers `Build-MiOSXboxISO.ps1` with `-RunLevel Highest` + `ExecutionTimeLimit=0`;
you trigger it from *any* shell — including inside the remote session — with:

```powershell
Start-ScheduledTask -TaskName MiOS-Build
```

Why this solves all three boundaries at once:
- **Elevate:** elevation is authorized **at registration** (a one-time elevated
  step); the Task Scheduler service launches the build with a full token — **no UAC
  prompt**, no interactive stall on a multi-hour DISM/oscdimg run. (UAC *does* work
  over RDP — a Windows App connection is a RemoteInteractive/type-10 *interactive*
  logon — but the admin token is split, so the task pattern is the no-click path.)
- **Launch + double-hop:** the task runs under **its own principal**, so the build's
  web/UNC fetch is a **first hop from the build host** — the PowerShell-Remoting
  double-hop (network logon with no forwardable ticket) never applies. No CredSSP,
  no delegation config.
- **No stored password:** MiOS's build needs **DISM + oscdimg**, not WSL, so it runs
  fine as **`NT AUTHORITY\SYSTEM`** (the default principal) — already elevated, zero
  credential. On a domain, use a **gMSA** (`-Principal gmsa -GmsaAccount 'DOM\gMSA$'`)
  for a passwordless AD identity that also gets Kerberos to internal resources.

```powershell
# one-time, elevated:
.\Register-MiOSBuildTask.ps1                    # SYSTEM (passwordless, local)
#   or  -Principal gmsa -GmsaAccount 'CONTOSO\gMSA_Build$'   (domain, passwordless)
# thereafter, from any shell (incl. the remote session):
Start-ScheduledTask -TaskName MiOS-Build
Get-ScheduledTaskInfo -TaskName MiOS-Build      # LastTaskResult / LastRunTime
```

## Connect-time SSO (so the session itself is passwordless)

For AVD / Windows 365 / Dev Box, enable Entra **single sign-on** so the operator
lands passwordless (FIDO2 / Windows Hello for Business) and a Primary Refresh Token
is minted in the session:
- Host-pool RDP property **`enablerdsaadauth:i:1`** (Dev Box: the "Enable single
  sign-on" pool toggle).
- Tenant: enable RDP auth on the **Windows Cloud Login** service principal
  (`270efc09-cd0d-444b-a71f-39af4910ec45`) via
  `Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -IsRemoteDesktopProtocolEnabled`.
- Session hosts must be **Entra-joined or hybrid-joined**; the *client* PC needs no
  join. Conditional Access (MFA / device compliance) is enforced at the cloud-service
  phase against the **Azure Virtual Desktop** app (`9cdead84-…`).

For a plain **Remote PC** (RDP to your own box) there's no Entra/PRT — it's classic
NLA/CredSSP over Kerberos/NTLM; the scheduled-task launch mechanism above is
unchanged.

## Alternatives (when they're worth it)

- **Build-per-push / full audit → self-hosted CI runner + OIDC.** A GitHub Actions
  self-hosted runner installed as a Windows **service under an admin account** (steps
  run elevated); the job authenticates to Azure via `azure/login@v2` **OIDC / workload
  identity federation — no stored secret** (only three non-secret GUIDs). "Launch"
  becomes a `git push`. Azure DevOps agent + a WIF service connection is equivalent.
- **Azure VM / Arc host → Run Command.** `az vm run-command invoke … RunPowerShellScript`
  (or Arc `az connectedmachine run-command`) runs the build **as SYSTEM**, authorized
  purely by control-plane RBAC (`…/runCommand/action`) — no in-guest creds, no session.

## Secrets (if the build needs external secrets beyond its own identity)

Compose a passwordless *identity* with a *vault*: run the task as **gMSA/SYSTEM**, and
have it *retrieve* PATs/signing passwords from **Azure Key Vault + managed identity**
(Azure VM/Arc), or a local **SecretManagement/SecretStore** vault (offline). Avoid
storing a bootstrap secret.

## Anti-patterns (do NOT)

`runas /savecred` (reusable stored admin creds); **CredSSP** for the double-hop
(plaintext-capable creds cached on the target — Microsoft-discouraged);
**unconstrained delegation** (impersonate-anywhere; top AD attack primitive);
`LocalAccountTokenFilterPolicy=1` unless required (re-opens pass-the-hash); any
`RunAsUser/RunAsPassword` path that re-introduces a stored password.
