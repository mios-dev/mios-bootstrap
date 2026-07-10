<!-- AI-hint: Authoritative reference for MiOS system-wide environment variables and installer constants, defining default values for identity, repository/image refs, AI inference lanes, networking, paths, and build knobs used by the bootstrap and deployment scripts. MiOS is an immutable bootc/OCI Fedora workstation that is also a local agentic AI OS; every value here flows from the SSOT env.defaults / install.ps1 into the build pipeline and the deployed host.
     AI-related: /usr/share/mios/env.defaults, /usr/share/mios/ai/vars.json, /usr/share/mios/ai, /etc/mios/install.env, /usr/share/mios/PACKAGES.md, /etc/mios/profile.toml, /etc/mios/ai/system-prompt.md, /etc/mios/ai/config.json, /usr/share/mios/profile.toml, /usr/share/mios/ai/system.md, /usr/share/mios/llamacpp/llama-swap.yaml -->
# usr/share/doc/mios-bootstrap/reference/variables.md

Global variable index for 'MiOS' v0.2.4. **What this document is for:** MiOS is one
thing built two ways at once — an immutable, bootc/OCI-shaped Fedora workstation
(the whole OS is a single container image you `bootc upgrade` like a `git pull`
and `bootc rollback` like a Ctrl-Z) that is *also* a local, self-replicating,
agentic AI operating system. Both halves are parameterised by exactly one set of
variables, and this is their registry. Every value defined here is the single
authoritative source: it flows from the SSOT into the build pipeline (which bakes
the OCI image), through the bootc lifecycle (which deploys and rolls it back), and
into the running agent stack at boot. Change a value in
`usr/share/mios/env.defaults` (Linux) or the `# Paths & constants` block of
`install.ps1` (Windows) to propagate it system-wide.

These variables sit *below* the operator-tunable `mios.toml` SSOT: `mios.toml`
owns packages, ports, AI lanes, and agent behaviour and is rendered down into the
`MIOS_*` surface here. The variables in this file are the lower-level identity,
repo/image, and build constants that the bootstrap and build scripts consume
directly.

---

## Linux environment variables (`MIOS_*`)

Source file: `/usr/share/mios/env.defaults`  
Machine-readable index: `/usr/share/mios/ai/vars.json`

### Identity

| Variable | Default | Description |
|---|---|---|
| `MIOS_VERSION` | `0.2.4` | 'MiOS' release version |
| `MIOS_DEFAULT_USER` | `mios` | Default Linux username |
| `MIOS_DEFAULT_HOST` | `mios` | Default hostname |
| `MIOS_DEFAULT_SHELL` | `/bin/bash` | Default login shell |
| `MIOS_DEFAULT_TIMEZONE` | `UTC` | Default timezone |
| `MIOS_DEFAULT_LOCALE` | `en_US.UTF-8` | Default system locale |
| `MIOS_DEFAULT_GROUPS` | `wheel,libvirt,kvm,video,render,input,dialout,docker` | Supplementary groups |

### Repos & image refs

The image is the unit of delivery: the build pipeline assembles
`MIOS_LOCAL_TAG`, publishes it as `MIOS_IMAGE_REF`, and a host adopts it with
`bootc switch`/`bootc upgrade`. These variables name every link in that chain.

| Variable | Default | Description |
|---|---|---|
| `MIOS_REPO_URL` | `https://github.com/mios-dev/mios` | System layer git repo (FHS overlay baked into the image) |
| `MIOS_BOOTSTRAP_REPO_URL` | `https://github.com/mios-dev/mios-bootstrap` | Bootstrap layer git repo (interactive installer + user-editable layer) |
| `MIOS_IMAGE_NAME` | `ghcr.io/mios-dev/mios` | OCI registry path |
| `MIOS_IMAGE_TAG` | `latest` | OCI image tag |
| `MIOS_IMAGE_REF` | `ghcr.io/mios-dev/mios:latest` | Full bootc reference |
| `MIOS_BRANCH` | `main` | Git branch |
| `MIOS_BASE_IMAGE` | `ghcr.io/ublue-os/ucore-hci:stable-nvidia` | Containerfile `FROM` (Universal Blue ucore-hci) |
| `MIOS_LOCAL_TAG` | `localhost/mios:latest` | Local build output |
| `MIOS_BIB_IMAGE` | `quay.io/centos-bootc/bootc-image-builder:latest` | bootc-image-builder ref (cuts disk artifacts from the image) |

### Sidecar versions (change here to update across the whole system)

The optional cluster/HCI plane (Law 6 documented exceptions `mios-ceph` and
`mios-k3s`) lets a single MiOS box grow into a one-node cluster in place. These
pins keep that growth reproducible across every host that pulls the ref.

| Variable | Default | Description |
|---|---|---|
| `MIOS_K3S_VERSION` | `v1.32.1-k3s1` | k3s version |
| `MIOS_K3S_IMAGE` | `rancher/k3s:v1.32.1-k3s1` | k3s container ref |
| `MIOS_CEPH_VERSION` | `v18` | Ceph version |
| `MIOS_CEPH_IMAGE` | `quay.io/ceph/ceph:v18` | Ceph container ref |

### AI inference

This block parameterises the **agentic AI OS** half of MiOS. Every agent and
tool resolves a single OpenAI-compatible endpoint (`MIOS_AI_ENDPOINT`,
Architectural Law 5 — UNIFIED-AI-REDIRECTS); there are no vendor-cloud URLs and
no vendor-specific agent names anywhere. Behind that one contract endpoint sit
function-named local inference lanes — primary `mios-llm-light` (`:11450`,
llama.cpp behind the upstream `llama-swap` proxy image), with gated heavy GPU
lanes `mios-llm-heavy` (SGLang, `:11441`) and `mios-llm-heavy-alt` (vLLM,
`:11440`). `mios-llm-light` also serves the OpenAI-compatible `/v1/embeddings`
lane via `nomic-embed-text`, which feeds the PostgreSQL+pgvector agent memory.
The lanes speak the OpenAI/Ollama-compatible API, so any OpenAI-API client talks
to them unchanged.

| Variable | Default | Description |
|---|---|---|
| `MIOS_AI_ENDPOINT` | `http://localhost:8642/v1` | The single OpenAI-compatible base URL every agent/tool targets (LAW 5). No vendor-cloud URLs. |
| `MIOS_AI_MODEL` | `gemma4:12b` | Default inference model id (auto-selected by host RAM from `mios.toml [ai.host_thresholds]`) |
| `MIOS_AI_EMBED_MODEL` | `nomic-embed-text` | Embedding model id — served by `mios-llm-light`'s `/v1/embeddings` lane; backs pgvector recall |
| `MIOS_AI_KEY` | `` | API key (empty = no auth; the local stack requires none) |
| `MIOS_AI_PORT` | `8642` | Service port for the unified `MIOS_AI_ENDPOINT` contract |

> **Note.** `MIOS_AI_ENDPOINT`/`MIOS_AI_PORT` name the *unified contract*
> endpoint (Law 5). The underlying inference lanes — `mios-llm-light` on
> `:11450`, `mios-llm-heavy` on `:11441`, `mios-llm-heavy-alt` on `:11440` — are
> declared as Quadlets and tuned in `mios.toml` (`[llamacpp]`, `[ai.sglang]`,
> `[ai.vllm]`); the heavy lanes are gated off by default on VRAM grounds and stay
> inert until enabled and health-reachable. The agent-pipe orchestrator and the
> MiOS-Hermes gateway resolve clients to those lanes; never hard-code a lane port
> or vendor URL.

### Network

| Variable | Default | Description |
|---|---|---|
| `MIOS_QUADLET_SUBNET` | `10.89.0.0/24` | Quadlet container network |
| `MIOS_SSH_PORT` | `22` | SSH port |
| `MIOS_COCKPIT_PORT` | `9090` | Cockpit web console port |
| `MIOS_K3S_API_PORT` | `6443` | k3s API server port |
| `MIOS_FIREWALLD_ZONE` | `drop` | Default firewalld zone (deny-by-default posture) |

### Paths

The path variables encode the immutability contract: static config lives under
`/usr/` (Law 1, USR-OVER-ETC), every `/var/` path is tmpfiles-declared and never
written at build time (Law 2, NO-MKDIR-IN-VAR), and the agent's runtime memory
and scratch survive upgrades under `/var/`.

| Variable | Default | Description |
|---|---|---|
| `MIOS_AI_DIR` | `/usr/share/mios/ai` | AI files directory (vendor canonical, read-only) |
| `MIOS_AI_MODELS_DIR` | `/srv/ai/models` | Model weights storage |
| `MIOS_AI_SCRATCH_DIR` | `/var/lib/mios/ai/scratch` | Volatile inter-agent scratchpad |
| `MIOS_AI_MEMORY_DIR` | `/var/lib/mios/ai/memory` | Persistent agent memory (episodic; complements the pgvector datastore) |
| `MIOS_AI_JOURNAL` | `/var/lib/mios/ai/journal.md` | Append-only action log |
| `MIOS_INSTALL_ENV` | `/etc/mios/install.env` | Host identity record (mode 0640) |
| `MIOS_PACKAGES_MD` | `/usr/share/mios/PACKAGES.md` | RPM package SSOT |
| `MIOS_WSLBOOT_DONE` | `/var/lib/mios/.wsl-firstboot-done` | WSL2 firstboot guard marker |

### Build

These knobs drive the build pipeline (`Containerfile` → `automation/[NN]-*.sh`
in numeric order → rechunked OCI image) and the Windows provisioning step that
stands up the dedicated builder VM.

| Variable | Default | Description |
|---|---|---|
| `MIOS_RECHUNK_MAX_LAYERS` | `67` | bootc-base-imagectl rechunk cap |
| `MIOS_WSL_DISTRO` | `'MiOS'` | WSL2 deployed distro name |
| `MIOS_BUILDER_DISTRO` | `MiOS-DEV` | Podman-WSL2 dev/builder machine name (renamed from MiOS-BUILDER in v0.2.3; legacy still recognized) |
| `MIOS_DATA_DISK_MB` | `262144` | Size in MB to shrink C: by and create a dedicated MiOS-DEV partition on |
| `MIOS_DATA_DISK_LETTER` | `M` | Drive letter assigned to the new partition |
| `MIOS_SKIP_DATA_DISK` | (unset) | Set to `1` to skip the C: shrink + new-partition step entirely |

---

## Windows PowerShell constants (`install.ps1`)

Defined in the `# Paths & constants` block at the top of `install.ps1`. These
govern the Windows-side provisioning + handoff: the installer carves `M:\`,
provisions the `MiOS-DEV` podman machine (the builder), clones both repos, and
hands the OCI build off into that VM.

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

Each prompt auto-accepts its `mios.toml`-resolved default after **90 seconds**
idle (override with `MIOS_PROMPT_TIMEOUT=`; `0` = wait forever, `1` = fastest
unattended).

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
- `MIOS_AI_KEY`: empty by default (the local stack requires no auth); set in `~/.config/mios/env` only for remote endpoints.

---

## Dotfiles

Variable resolution is layered, highest precedence first: per-user
(`~/.config/mios/`) overrides host-level (`/etc/mios/`) overrides vendor defaults
(`/usr/share/mios/`). This mirrors the three-layer `mios.toml` overlay and the
USR-OVER-ETC law — `/etc/` is admin-override only; the immutable image ships the
floor.

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
| `/etc/mios/ai/config.json` | root | Host-level AI inference config (base_url, models) |
| `/usr/share/mios/env.defaults` | image | Vendor defaults (lowest precedence) |
| `/usr/share/mios/profile.toml` | image | Vendor profile defaults |
| `/usr/share/mios/ai/system.md` | image | Canonical AI system prompt |
