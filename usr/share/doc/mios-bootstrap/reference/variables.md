# usr/share/doc/mios-bootstrap/reference/variables.md

Global variable index for 'MiOS' v0.2.4. All values defined here are the single authoritative source. Change a value in `usr/share/mios/env.defaults` (Linux) or the `# Paths & constants` block of `install.ps1` (Windows) to propagate it system-wide.

---

## Linux environment variables (`MIOS_*`)

Source file: `/usr/share/mios/env.defaults`  
Machine-readable index: `/usr/share/mios/ai/vars.json`

### Identity

| Variable | Default | Description |
|---|---|---|
| `MIOS_VERSION` | `0.2.2` | 'MiOS' release version |
| `MIOS_DEFAULT_USER` | `mios` | Default Linux username |
| `MIOS_DEFAULT_HOST` | `mios` | Default hostname |
| `MIOS_DEFAULT_SHELL` | `/bin/bash` | Default login shell |
| `MIOS_DEFAULT_TIMEZONE` | `UTC` | Default timezone |
| `MIOS_DEFAULT_LOCALE` | `en_US.UTF-8` | Default system locale |
| `MIOS_DEFAULT_GROUPS` | `wheel,libvirt,kvm,video,render,input,dialout,docker` | Supplementary groups |

### Repos & image refs

| Variable | Default | Description |
|---|---|---|
| `MIOS_REPO_URL` | `https://github.com/mios-dev/mios` | System layer git repo |
| `MIOS_BOOTSTRAP_REPO_URL` | `https://github.com/mios-dev/mios-bootstrap` | Bootstrap layer git repo |
| `MIOS_IMAGE_NAME` | `ghcr.io/mios-dev/mios` | OCI registry path |
| `MIOS_IMAGE_TAG` | `latest` | OCI image tag |
| `MIOS_IMAGE_REF` | `ghcr.io/mios-dev/mios:latest` | Full bootc reference |
| `MIOS_BRANCH` | `main` | Git branch |
| `MIOS_BASE_IMAGE` | `ghcr.io/ublue-os/ucore-hci:stable-nvidia` | Containerfile FROM |
| `MIOS_LOCAL_TAG` | `localhost/mios:latest` | Local build output |
| `MIOS_BIB_IMAGE` | `quay.io/centos-bootc/bootc-image-builder:latest` | bootc-image-builder ref |

### Sidecar versions (change here to update across the whole system)

| Variable | Default | Description |
|---|---|---|
| `MIOS_LOCALAI_VERSION` | `v2.20.0` | LocalAI version |
| `MIOS_LOCALAI_IMAGE` | `localai/localai:v2.20.0` | LocalAI container ref |
| `MIOS_K3S_VERSION` | `v1.32.1-k3s1` | k3s version |
| `MIOS_K3S_IMAGE` | `rancher/k3s:v1.32.1-k3s1` | k3s container ref |
| `MIOS_CEPH_VERSION` | `v18` | Ceph version |
| `MIOS_CEPH_IMAGE` | `quay.io/ceph/ceph:v18` | Ceph container ref |

### AI inference

| Variable | Default | Description |
|---|---|---|
| `MIOS_AI_ENDPOINT` | `http://localhost:8080/v1` | OpenAI-compatible base URL (LAW 5) |
| `MIOS_AI_MODEL` | `qwen2.5-coder:7b` | Inference model id |
| `MIOS_AI_EMBED_MODEL` | `nomic-embed-text` | Embedding model id |
| `MIOS_AI_KEY` | `` | API key (empty = no auth) |
| `MIOS_AI_PORT` | `8080` | LocalAI service port |

### Network

| Variable | Default | Description |
|---|---|---|
| `MIOS_QUADLET_SUBNET` | `10.89.0.0/24` | Quadlet container network |
| `MIOS_SSH_PORT` | `22` | SSH port |
| `MIOS_COCKPIT_PORT` | `9090` | Cockpit web console port |
| `MIOS_K3S_API_PORT` | `6443` | k3s API server port |
| `MIOS_FIREWALLD_ZONE` | `drop` | Default firewalld zone |

### Paths

| Variable | Default | Description |
|---|---|---|
| `MIOS_AI_DIR` | `/usr/share/mios/ai` | AI files directory |
| `MIOS_AI_MODELS_DIR` | `/srv/ai/models` | Model weights storage |
| `MIOS_AI_SCRATCH_DIR` | `/var/lib/mios/ai/scratch` | Volatile inter-agent scratchpad |
| `MIOS_AI_MEMORY_DIR` | `/var/lib/mios/ai/memory` | Persistent agent memory |
| `MIOS_AI_JOURNAL` | `/var/lib/mios/ai/journal.md` | Append-only action log |
| `MIOS_INSTALL_ENV` | `/etc/mios/install.env` | Host identity record (mode 0640) |
| `MIOS_PACKAGES_MD` | `/usr/share/mios/PACKAGES.md` | RPM package SSOT |
| `MIOS_WSLBOOT_DONE` | `/var/lib/mios/.wsl-firstboot-done` | WSL2 firstboot guard marker |

### Build

| Variable | Default | Description |
|---|---|---|
| `MIOS_RECHUNK_MAX_LAYERS` | `67` | bootc-base-imagectl rechunk cap |
| `MIOS_WSL_DISTRO` | `'MiOS'` | WSL2 deployed distro name |
| `MIOS_BUILDER_DISTRO` | `MiOS-DEV` | Podman-WSL2 dev machine name (renamed from MiOS-BUILDER in v0.2.3; legacy still recognized) |
| `MIOS_DATA_DISK_MB` | `262144` | Size in MB to shrink C: by and create a dedicated MiOS-DEV partition on |
| `MIOS_DATA_DISK_LETTER` | `M` | Drive letter assigned to the new partition |
| `MIOS_SKIP_DATA_DISK` | (unset) | Set to `1` to skip the C: shrink + new-partition step entirely |

---

## Windows PowerShell constants (`install.ps1`)

Defined in the `# Paths & constants` block at the top of `install.ps1`.

| Variable | Default | Description |
|---|---|---|
| `$MiosVersion` | `v0.2.4` | 'MiOS' version string |
| `$MiosInstallDir` | `%LOCALAPPDATA%\Programs\MiOS` | Windows install directory |
| `$MiosRepoDir` | `%LOCALAPPDATA%\Programs\MiOS\repo` | Cloned repo path |
| `$MiosDistroDir` | `%LOCALAPPDATA%\Programs\MiOS\distros` | WSL2 distro root dirs |
| `$MiosConfigDir` | `%APPDATA%\MiOS` | Config storage |
| `$MiosDataDir` | `%LOCALAPPDATA%\MiOS` | Data/logs storage |
| `$MiosLogDir` | `%LOCALAPPDATA%\MiOS\logs` | Log file directory |
| `$MiosRepoUrl` | `https://github.com/mios-dev/mios.git` | System repo URL |
| `$MiosBootstrapUrl` | `https://github.com/mios-dev/mios-bootstrap.git` | Bootstrap repo URL |
| `$BuilderDistro` | `MiOS-DEV` | Podman machine name (alias of `$DevDistro`, retained for back-compat) |
| `$DevDistro` | `MiOS-DEV` | Canonical podman-machine name (SSOT) |
| `$LegacyDevName` | `MiOS-BUILDER` | Legacy name accepted at install-time so prior installs aren't blown away |
| `$MiosWslDistro` | `'MiOS'` | Deployed 'MiOS' WSL2 distro name |
| `$LegacyDistro` | `podman-machine-default` | Legacy Podman distro name |

---

## Installer prompts (in order)

| Prompt | Default | Persisted to |
|---|---|---|
| Linux username | `mios` | `MIOS_DEFAULT_USER` → `/etc/mios/install.env` |
| Hostname | `mios` | `MIOS_DEFAULT_HOST` → `/etc/mios/install.env` |
| Full name (GECOS) | `'MiOS' User` | `/etc/mios/install.env` |
| Password | (prompted twice) | SHA-512 hash via `chpasswd` -- never written plaintext |
| SSH key | generate ed25519 | `~/.ssh/id_ed25519` (mode 0600) |
| GitHub PAT | skip | `~/.git-credentials` (mode 0600, if provided) |
| Image ref (bootc) | `ghcr.io/mios-dev/mios:latest` | `MIOS_IMAGE_REF` → `bootc switch` |
| Install mode | `auto` | `[bootstrap].mode` in profile.toml |

---

## Secrets policy

- Password: never persisted; hashed by `chpasswd`.
- GitHub PAT: written to `~/.git-credentials` (mode 0600) if provided; never committed.
- SSH private key: `~/.ssh/id_ed25519` (mode 0600).
- `MIOS_AI_KEY`: empty by default (local stack requires no auth); set in `~/.config/mios/env` for remote endpoints.

---

## Dotfiles

| Path | Owner | Description |
|---|---|---|
| `~/.config/mios/env` | user | Per-user `MIOS_*` overrides (highest precedence) |
| `~/.config/mios/profile.toml` | user | Per-user profile overrides |
| `~/.config/mios/system-prompt.md` | user | Per-user AI system prompt |
| `~/.ssh/id_ed25519` | user | Generated SSH key |
| `~/.git-credentials` | user | GitHub PAT (mode 0600) |
| `/etc/mios/install.env` | root | Host identity record (mode 0640) |
| `/etc/mios/profile.toml` | root | Host-level profile overrides |
| `/etc/mios/ai/system-prompt.md` | root | Host-level AI system prompt |
| `/etc/mios/ai/config.json` | root | Host-level AI inference config |
| `/usr/share/mios/env.defaults` | image | Vendor defaults (lowest precedence) |
| `/usr/share/mios/profile.toml` | image | Vendor profile defaults |
| `/usr/share/mios/ai/system.md` | image | Canonical AI system prompt |
