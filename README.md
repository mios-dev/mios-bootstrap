<!-- AI-hint: Entry point for the MiOS installation workflow; defines the interactive bootstrap that turns a bare Windows/Fedora host into a deployed MiOS image, the three-layer user-editable profile model, and the system-wide config + RAG knowledge it seeds. MiOS is an immutable bootc/OCI Fedora workstation that is also a local agentic AI OS; this repo is its front door and user-editable layer.
     AI-related: /usr/share/mios/profile.toml, /etc/mios/ai/system-prompt.md, /usr/libexec/mios/mios-build-driver, /etc/mios/install.env, /etc/mios/profile.toml, mios-build-driver, mios-bootstrap, mios-dev, mios-build, mios-llm-light, localhost:8080 -->
# mios-bootstrap

Interactive installer for MiOS, and the user-editable layer of its
three-layer profile model. This is the **front door** to MiOS.

**What MiOS is.** MiOS is one thing built two ways at once: an immutable,
bootc/OCI-shaped Fedora workstation (the whole OS is a single container
image — boot it, `bootc upgrade` it like a `git pull`, `bootc rollback`
it like a Ctrl-Z) that is *also* a local, self-replicating, agentic AI
operating system. The same image that ships GNOME/Wayland, NVIDIA+ROCm+iGPU
via CDI, KVM/libvirt with VFIO passthrough, and a k3s+Ceph cluster path
also ships a full local agent stack behind one OpenAI-compatible endpoint.

**What this repo does in that whole.** The system image, FHS overlay,
Containerfile, Quadlets, and architectural laws live in `mios.git`. This
repo is the *user-facing entry surface*: it captures who you are (identity,
keys, image tag) into a layered profile, merges `mios.git` into the system
root (Phase-1 Total Root Merge), and hands off to the build pipeline that
produces the OCI image the bootc lifecycle then carries forward. End to
end: **bootstrap (this repo) → image build (`mios.git`) → bootc lifecycle
on the host.** Nothing here owns runtime system files — it owns the *path
in*.

**Version:** v0.2.4
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
  to `/etc/mios/ai/system-prompt.md`; the local agent stack loads it for
  chat completions through the unified AI endpoint (`MIOS_AI_ENDPOINT`
  — Architectural Law 5). Per-user
  copies live at `~/.config/mios/system-prompt.md`.
- `.env.mios` (deprecated, legacy) -- env-style user defaults; sourced
  by `install.sh` after TOML layers so explicit TOML wins. Migrate to
  `etc/mios/profile.toml`.
- `etc/mios/{manifest.json,rag-manifest.yaml}` -- installation metadata.
- `usr/share/mios/knowledge/*` -- RAG knowledge graphs. At runtime these
  are embedded (`nomic-embed-text`, served by the `mios-llm-light` lane)
  and recalled from the PostgreSQL+pgvector agent datastore.

## Install

### Windows 11

**Canonical entry — `WinKey+R` → paste → Enter → accept UAC:**

```text
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex"
```

That `irm | iex` shape is the entry contract. Run it from the Windows
Run dialog, cmd.exe, or any PowerShell session — no pre-existing pwsh,
no ExecutionPolicy override, no manual elevation needed.

`Get-MiOS.ps1` handles everything end-to-end:

1. **Self-cache-busts** on entry — Fastly's 5-min TTL on
   `raw.githubusercontent.com` is invisible to you; every paste pulls
   origin-fresh.
2. **Two-pass self-elevation** — Pass 1 (user) installs Windows Terminal
   + MiOS scheme, Geist Mono Nerd Font, oh-my-posh, fastfetch, and the
   MiOS native-app shortcut on Desktop + Start Menu. Pass 2 (admin)
   shrinks `C:\` and creates `M:\` at exactly 256 GB NTFS, installs
   Podman Desktop, provisions the `MiOS-DEV` podman machine, and clones
   `mios.git` + `mios-bootstrap` onto `M:\`.
3. **Auto-chains** into `/usr/libexec/mios/mios-build-driver` inside
   `MiOS-DEV` for the OCI build (Phase 6+: identity, OCI build, deploy).

`MiOS-DEV` is THE builder: every `podman build`, BIB run, and
`bootc switch` happens inside it, and it runs every Quadlet container
that ships in production. Windows is provisioning + handoff only.

**Equivalent shortcut: `mios.bat`** — `WinKey+R` → `mios.bat` (or double-
click the file). The .bat invokes the same `irm | iex` one-liner above
with cache-bust appended (`?cb=<unix-time>`); it self-elevates via cmd's
`net session` probe instead of the script's two-pass dance. Either entry
is valid; the `irm | iex` shape is the contract.

After installation, the `MiOS` Start Menu app opens the launcher (Build,
Enter Dev VM, Update, Dashboard, Configurator, Re-run Bootstrap, Open
Install Root). `mios-build` from any MiOS terminal re-runs the OCI build
inside the dev VM.

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
   bootstrap overlays (`etc/`, `usr/`, `var/`) on top. This is the
   load-bearing premise: **the repo root IS the deployed system root**,
   so edits to `/` on a running host are edits to the source the next
   `bootc upgrade` bakes.
3. **Phase-2** -- build: `dnf install` from the `[packages]` SSOT in
   `usr/share/mios/mios.toml` (FHS path) or
   `bootc switch ghcr.io/mios-dev/mios:latest` (bootc path).
4. **Phase-3** -- apply: `systemd-sysusers`, `systemd-tmpfiles`,
   `daemon-reload`, services; create the bootstrap user; seed every
   uid ≥ 1000 home from `/etc/skel/.config/mios/`.
5. **Phase-4** -- reboot prompt.

## Offline / Air-Gapped and Proxy Support

The MiOS bootstrap installer has built-in support for offline/air-gapped and proxied environments:
- **System Proxy**: If your host is behind a system proxy, `Get-MiOS.ps1` (via `Invoke-WebRequest` / `Invoke-RestMethod` using `-UseBasicParsing`), `git` clones, and `winget` packages will respect the standard Windows system proxy settings.
- **Offline Fallbacks**: When internet access is unavailable or limited, the installer automatically falls back to direct download/offline setups. For instance:
  - If `winget` is missing or fails, a direct MSI/executable installation is attempted for prerequisites like Git and Podman CLI.
  - Pre-seeded local packages and offline configuration are utilized where possible to minimize external network requests during initial provisioning.

## Profile resolution

Identity and tunables flow from one TOML with three layers, higher
precedence first. This is the same SSOT mechanism (`mios.toml`) the rest
of the system uses; the profile card is its identity slice.

1. `~/.config/mios/profile.toml` -- per-user (seeded from
   `/etc/skel/.config/mios/profile.toml`)
2. `/etc/mios/profile.toml` -- host (this repo's editable copy)
3. `/usr/share/mios/profile.toml` -- vendor defaults (mios.git)

`install.sh:resolve_profile_layers` walks all three at install time and
field-level overlays them into the runtime defaults. User-set fields
in higher layers win. Empty strings do NOT override non-empty values
below them (empty user TOML is the vendor-default state, not an error).

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
| `[ai] endpoint` | `http://localhost:8642/v1` |

`[ai] endpoint` is the **single OpenAI-compatible front door** (Law 5,
UNIFIED-AI-REDIRECTS) that every agent, tool, and editor on a deployed
host resolves to via `MIOS_AI_ENDPOINT`. It fronts the local inference
lanes — the primary `mios-llm-light` lane (llama.cpp behind the
[llama-swap](https://github.com/mostlygeek/llama-swap) proxy image on
`:11450`, serving the everyday models *and* embeddings) plus the gated
heavy GPU lanes — so the URL stays stable while the engine behind it can
change. No vendor-cloud URLs ever appear; the lanes speak the
OpenAI/Ollama-compatible API, which is the only addressable contract.

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

Idempotency is the bootstrap-side mirror of the OS-side promise: the same
inputs always reproduce the same deployed state, the same way the
single-image bootc lifecycle reproduces the same OS on every host that
pulls the ref.

## License

Apache-2.0. See `LICENSE`.
