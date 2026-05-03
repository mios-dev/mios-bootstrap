# mios-bootstrap

Interactive installer for MiOS. End-user entry point and the
user-editable layer of the three-layer profile model.

**Version:** v0.2.2
**System repo:** <https://github.com/mios-dev/mios>

## Contents

- `install.sh` -- interactive Phase-0..4 orchestrator. Prompts for Linux
  username, hostname, password, SSH key, GitHub PAT, and image tag --
  everything defaults to `mios` until the user overrides.
- `etc/mios/profile.toml` -- user-editable profile (TOML) that overlays
  the vendor defaults shipped by `mios.git` at
  `/usr/share/mios/profile.toml`.
- `etc/skel/.config/mios/{profile.toml,system-prompt.md}` -- per-user
  templates seeded into every Linux user's home (uid ≥ 1000) by
  `install.sh:seed_user_skel_for_all_accounts` and by `useradd -m` for
  future users.
- `system-prompt.md` -- host AI prompt redirector. Bootstrap deploys this
  to `/etc/mios/ai/system-prompt.md`; LocalAI loads it for chat
  completions. Per-user copies live at `~/.config/mios/system-prompt.md`.
- `.env.mios` (deprecated, legacy) -- env-style user defaults; sourced
  by `install.sh` after TOML layers so explicit TOML wins. Migrate to
  `etc/mios/profile.toml`.
- `etc/mios/{manifest.json,rag-manifest.yaml}` -- installation metadata.
- `usr/share/mios/knowledge/*` -- RAG knowledge graphs.

## Install

### Windows 11 (Podman Desktop + WSL2)

```powershell
# Canonical one-liner (admin PowerShell):
irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex

# Or the direct invocation if you prefer to skip the wrapper:
irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/build-mios.ps1 | iex

# The legacy install.ps1 URL still works (now a redirector to build-mios.ps1).
```

Each interactive prompt auto-accepts the resolved-from-`mios.toml`
default after **90 seconds** idle. Override with
`$env:MIOS_PROMPT_TIMEOUT` (seconds; `0` waits forever, `1` is the
fastest unattended setting).

One script -- all phases in sequence, fully idempotent:

1. Checks prerequisites (Git, WSL2, Podman Desktop)
2. Creates `%LOCALAPPDATA%\Programs\MiOS\`, clones both repos
3. Configures `%USERPROFILE%\.wslconfig` (memory/CPU/mirrored networking)
4. Collects identity -- username, hostname, password (all default to `mios`, just press Enter)
5. Writes identity into the WSL2 distro (`/etc/mios/install.env`)
6. Registers in Add/Remove Programs and creates the **'MiOS'** Start Menu group
7. Runs `just build` inside `podman-machine-default`

Re-running is safe -- if the WSL2 distro already has the repo at `/`, it pulls
the latest and goes straight to build with no prompts.

Prerequisites: [Git](https://git-scm.com/download/win), [Podman Desktop](https://podman-desktop.io), WSL2 (`wsl --install`).

### Linux (Fedora bootc)

On any Fedora bootc-capable host (Fedora Server 41+ or Fedora bootc):

```bash
# Canonical one-liner (legacy install.sh URL also works as a redirector):
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/build-mios.sh)"
```

Each interactive prompt auto-accepts the resolved-from-`mios.toml`
default after **90 seconds** idle. Override with
`MIOS_PROMPT_TIMEOUT=` (seconds; `0` waits forever, `1` is the fastest
unattended setting).

The installer:

1. **Phase-0** -- preflight, profile-card load (three-layer overlay),
   interactive identity capture (defaults from layered profile).
2. **Phase-1** -- Total Root Merge: clone `mios.git` into `/`, copy
   bootstrap overlays (`etc/`, `usr/`, `var/`) on top.
3. **Phase-2** -- build: `dnf install` from `usr/share/mios/PACKAGES.md`
   SSOT (FHS path) or `bootc switch ghcr.io/mios-dev/mios:latest` (bootc
   path).
4. **Phase-3** -- apply: `systemd-sysusers`, `systemd-tmpfiles`,
   `daemon-reload`, services; create the bootstrap user; seed every
   uid ≥ 1000 home from `/etc/skel/.config/mios/`.
5. **Phase-4** -- reboot prompt.

## Profile resolution

Three layers, higher precedence first:

1. `~/.config/mios/profile.toml` -- per-user (seeded from
   `/etc/skel/.config/mios/profile.toml`)
2. `/etc/mios/profile.toml` -- host (this repo's editable copy)
3. `/usr/share/mios/profile.toml` -- vendor defaults (mios.git)

`install.sh:resolve_profile_layers` walks all three at install time and
field-level overlays them into the runtime defaults. User-set fields
in higher layers win. Empty strings do NOT override non-empty values
below them.

## Defaults

The shipped defaults are identical between `etc/mios/profile.toml`
(this repo) and `/usr/share/mios/profile.toml` (mios.git). Edit
`etc/mios/profile.toml` here, or `/etc/mios/profile.toml` on a deployed
host, to override per-host. Edit `~/.config/mios/profile.toml` per user.

**Defaults policy (project-wide invariant):** every boolean feature
flag -- `[quadlets.enable]` entries, `[ai] enable_*`, `[network]
allow_*`, `[bootstrap] install_packages` / `reboot_on_finish` -- ships
`true`. The system never disables a component via static config; when
a component is incompatible with the host, systemd `Condition*`
directives on the underlying unit short-circuit it at boot/pre-boot.
Operators can still set a flag to `false` to force-disable. See
`INDEX.md` §5 in the system repo for the active gating table.

| Field | Default |
|---|---|
| `[identity] username` | `mios` |
| `[identity] hostname` | `mios` |
| `[identity] fullname` | `'MiOS' User` |
| `[identity] shell` | `/bin/bash` |
| `[identity] groups` | `wheel,libvirt,kvm,video,render,input,dialout,docker` |
| `[auth] ssh_key_type` | `ed25519` |
| `[auth] ssh_key_action` | `generate` |
| `[image] ref` | `ghcr.io/mios-dev/mios:latest` |
| `[ai] endpoint` | `http://localhost:8080/v1` |

Pressing Enter at any prompt accepts the resolved layered default.

## What gets persisted

- `/etc/mios/install.env` -- non-secret installation metadata (mode 0640)
- `/etc/mios/profile.toml` -- user-edit overlay (writable; preserved across `bootc upgrade`)
- `/etc/mios/ai/system-prompt.md` -- host AI prompt
- `~/.config/mios/profile.toml` (per user) -- per-user overlay
- `~/.config/mios/system-prompt.md` (per user) -- per-user AI prompt
- `~mios/.ssh/id_ed25519` -- generated SSH key (mode 0600)
- `~mios/.git-credentials` -- only if a GitHub PAT was provided (mode 0600)

Passwords are piped to `chpasswd` and never written to disk in plaintext.

## Idempotency

Re-running the installer with the same answers updates rather than
duplicates. Existing users are amended (not recreated); existing SSH
keys are not overwritten by the `generate` path (use a different keypair
name to layer). `seed_user_skel_for_all_accounts` re-runs every
install -- every uid ≥ 1000 user gets the latest
`~/.config/mios/{profile.toml,system-prompt.md}` content.

## License

Apache-2.0. See `LICENSE`.
