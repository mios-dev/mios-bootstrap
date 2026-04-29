# MiOS Variable System

**Version:** 1.0.0
**Date:** 2026-04-28
**Compatibility:** OpenAI API, FOSS AI APIs, bootc 1.1.x, FHS 3.0

---

## Overview

MiOS uses a **comprehensive variable tracking and metadata system** that is:
- **FHS 3.0 compliant** - Variables stored in Linux-native filesystem locations
- **bootc/OCI compatible** - Build-time vs runtime variable separation
- **AI API compatible** - All variables queryable and modifiable via OpenAI-compatible functions
- **User-friendly** - TOML configuration files, not shell scripts
- **Merge-safe** - Fedora Server deployment merges, never overwrites

---

## Variable Taxonomy

### 1. Build-Time Variables
**Mutability:** Immutable in final OCI image
**Set during:** `podman build` execution
**Storage:** Containerfile ARG → Image layers

Examples:
- `MIOS_BASE_IMAGE` - Base OCI image to build from
- `MIOS_USER` - Default username baked into image
- `MIOS_PASSWORD_HASH` - Password hash baked into image

### 2. Runtime Variables
**Mutability:** Mutable after deployment
**Set during:** System boot / user session
**Storage:** `/etc/mios/runtime.env`, `~/.config/mios/*.toml`

Examples:
- `MIOS_AI_KEY` - AI API key (secret)
- `MIOS_AI_MODEL` - AI model selection
- `MIOS_HOSTNAME` - System hostname (override)

### 3. User-Ignitable Variables
**Mutability:** Transient (changeable before each build)
**Set during:** Build preparation
**Storage:** `~/.config/mios/*.toml`

Examples:
- `MIOS_BASE_IMAGE` - Select which base image to use
- `MIOS_FLATPAKS` - Comma-separated Flatpak app IDs
- `MIOS_IMAGE_NAME` - Output image name and registry

### 4. Tracked Variables
**Mutability:** Varies
**Identifier:** `@track:MARKER` comment in source files
**Purpose:** Automatic propagation across multiple files

Examples:
- `@track:IMG_BASE` → MIOS_BASE_IMAGE locations
- `@track:REGISTRY_DEFAULT` → MIOS_IMAGE_NAME locations
- `@track:IMG_BIB` → MIOS_BIB_IMAGE locations

---

## Filesystem Storage Locations (FHS 3.0)

### Build-Time Immutable (`/usr/share/mios/`)
```
/usr/share/mios/
├── PACKAGES.md          # Package SSOT
├── defaults.env         # Default variable values
└── flatpak-list         # Default Flatpak apps
```

**Mutability:** Immutable (baked into OCI image)
**Managed by:** `podman build`
**Layer:** OCI image layer

---

### System Configuration (`/etc/mios/`)
```
/etc/mios/
├── runtime.env          # Runtime environment variables
└── ignition.toml        # Build ignition configuration
```

**Mutability:** Admin-editable
**Managed by:** System administrator
**Layer:** Persistent overlay (survives `bootc upgrade`)

**Example `/etc/mios/runtime.env`:**
```bash
# MiOS Runtime Environment
MIOS_AI_ENDPOINT="http://localhost:11434"
MIOS_AI_MODEL="llama3.1:8b"
MIOS_ROLE="desktop"
```

---

### User Configuration (`~/.config/mios/`)
```
~/.config/mios/
├── env.toml             # User environment variables
├── images.toml          # User image selections
├── build.toml           # User build preferences
├── flatpaks.list        # User Flatpak list
└── ai.env               # User AI configuration (secrets, not committed)
```

**Mutability:** User-editable
**Managed by:** User
**Layer:** XDG Base Directory (user home)

**Example `~/.config/mios/env.toml`:**
```toml
[mios]
user = "myusername"
hostname = "myworkstation"

[ai]
model = "llama3.1:70b"
temperature = 0.7
```

**Example `~/.config/mios/images.toml`:**
```toml
[base]
image = "ghcr.io/ublue-os/ucore-hci:stable-nvidia"

[builder]
image = "quay.io/centos-bootc/bootc-image-builder:latest"

[output]
name = "ghcr.io/myuser/mios"
tag = "latest"
```

**Example `~/.config/mios/flatpaks.list`:**
```
org.mozilla.firefox
org.gnome.Calendar
com.visualstudio.code
io.podman_desktop.PodmanDesktop
```

---

### System State (`/var/lib/mios/state/`)
```
/var/lib/mios/state/
├── role                 # Detected role: desktop | k3s | ha
├── gpu                  # Detected GPU: nvidia | amd | intel | none
└── platform             # Detected platform: none | wsl | microsoft | kvm
```

**Mutability:** System-managed (auto-detected)
**Managed by:** `automation/*-detect.sh` scripts
**Layer:** Persistent state

**Example `/var/lib/mios/state/role`:**
```
desktop
```

---

### Cache Data (`/var/cache/mios/`)
```
/var/cache/mios/
├── build-cache/         # Build artifact cache
└── embeddings/          # AI embedding cache
```

**Mutability:** Ephemeral (safe to delete)
**Managed by:** Build and AI tools
**Layer:** Cache

---

## Variable Propagation Flow

### Build Entry Points

#### 1. Justfile (Linux/WSL2)
```bash
# Load user environment
source ./tools/load-user-env.sh

# Build with user variables
just build
```

**Flow:**
1. `tools/load-user-env.sh` reads `~/.config/mios/*.toml`
2. Exports as `MIOS_*` environment variables
3. `Justfile` passes to `podman build --build-arg`
4. `Containerfile` receives as `ARG` directives

---

#### 2. Containerfile (OCI Build)
```dockerfile
ARG MIOS_BASE_IMAGE=ghcr.io/ublue-os/ucore-hci:stable-nvidia
ARG MIOS_USER=mios
ARG MIOS_PASSWORD_HASH=
ARG MIOS_HOSTNAME=mios
ARG MIOS_FLATPAKS=

FROM ${MIOS_BASE_IMAGE}

# Variables available during build
RUN echo "Building for user: ${MIOS_USER}"
```

**Flow:**
1. `ARG` directives declare build-time variables
2. Default values used if not provided by `--build-arg`
3. Available within `RUN` instructions
4. **NOT** persisted in final image (unless converted to `ENV`)

---

#### 3. Runtime Propagation
```bash
# systemd unit file
[Service]
EnvironmentFile=/etc/mios/runtime.env
ExecStart=/usr/bin/mios-service
```

**Flow:**
1. `/etc/mios/runtime.env` read by systemd
2. Variables available in service environment
3. Shell profiles source `/usr/lib/profile.d/mios-env.sh`
4. User sessions have `MIOS_*` variables

---

## User-Ignitable Variables Reference

### Image Selection

| Variable | Default | User-Editable | File | Mutability |
|----------|---------|---------------|------|------------|
| `MIOS_BASE_IMAGE` | `ghcr.io/ublue-os/ucore-hci:stable-nvidia` | ✅ | `images.toml` | build_time |
| `MIOS_IMAGE_NAME` | `ghcr.io/kabuki94/mios` | ✅ | `images.toml` | build_time |
| `MIOS_BIB_IMAGE` | `quay.io/centos-bootc/bootc-image-builder:latest` | ✅ | `images.toml` | build_time |

---

### User Provisioning

| Variable | Default | User-Editable | File | Mutability | Security |
|----------|---------|---------------|------|------------|----------|
| `MIOS_USER` | `mios` | ✅ | `env.toml` | build_time | Low |
| `MIOS_PASSWORD_HASH` | `` | ✅ | `env.toml` | build_time | **Critical** |
| `MIOS_HOSTNAME` | `mios` | ✅ | `env.toml` | runtime | Low |

**Generate Password Hash:**
```bash
python3 -c 'import crypt; print(crypt.crypt("mypassword", crypt.mksalt(crypt.METHOD_SHA512)))'
```

---

### Package Selection

| Variable | Default | User-Editable | File | Mutability |
|----------|---------|---------------|------|------------|
| `MIOS_FLATPAKS` | `` | ✅ | `flatpaks.list` | build_time |

**Format:** One Flatpak app ID per line (not comma-separated in file)

---

### AI Configuration

| Variable | Default | User-Editable | File | Mutability | Security |
|----------|---------|---------------|------|------------|----------|
| `MIOS_AI_KEY` | `` | ✅ | `ai.env` | runtime | **Critical** |
| `MIOS_AI_MODEL` | `llama3.1:8b` | ✅ | `env.toml` | runtime | Low |
| `MIOS_AI_ENDPOINT` | `http://localhost:8080/v1` | ✅ | `env.toml` | runtime | Low |
| `MIOS_AI_TEMPERATURE` | `0.7` | ✅ | `env.toml` | runtime | Low |

---

## Ignition Workflow (Fedora Server Deployment)

### Step 1: Install Fedora Server
```bash
# Install Fedora Server (minimal)
# Clean FHS filesystem structure
```

---

### Step 2: Install Build Dependencies
```bash
sudo dnf install -y podman buildah just git
```

**Merge Behavior:** Package manager handles (no conflicts)

---

### Step 3: Clone MiOS Repository
```bash
git clone https://github.com/Kabuki94/MiOS-bootstrap.git
cd mios
```

---

### Step 4: Deploy MiOS Overlay (MERGE ONLY)
```bash
sudo ./tools/mios-init.sh deploy
```

**Merge Rules:**
- `usr/` → `/usr/` (MERGE: add new files, preserve existing)
- `etc/` → `/etc/` (MERGE: install templates, skip if exists)
- `var/` → `/var/` (DECLARE via tmpfiles.d, no mkdir)
- `home/` → `/home/` (MERGE: install skeleton, preserve user data)

**Conflict Resolution:**
- If `/usr/bin/mios` exists → SKIP (already deployed)
- If `/etc/mios/runtime.env` exists → PRESERVE (user edited)
- If `/var/lib/mios` exists → PRESERVE (has state data)

**Implementation:**
```bash
# Uses rsync with --ignore-existing
rsync -av --ignore-existing mios/usr/ /usr/
rsync -av --ignore-existing mios/etc/ /etc/
```

---

### Step 5: Activate tmpfiles.d
```bash
sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/mios.conf
```

**Effect:** Creates `/var/lib/mios/`, `/var/log/mios/`, etc.

---

### Step 6: Initialize User Space
```bash
./tools/init-user-space.sh
```

**Effect:** Creates `~/.config/mios/*.toml` from templates

---

### Step 7: Edit User Variables
```bash
# Edit user configuration
vim ~/.config/mios/env.toml
vim ~/.config/mios/images.toml
vim ~/.config/mios/flatpaks.list
```

---

### Step 8: Build MiOS Image
```bash
just build
```

**Effect:** Builds OCI image using user variables

---

## Build Stage Variables

### Pre-Build Stage
**Variables:** `MIOS_BASE_IMAGE`, `MIOS_IMAGE_NAME`, `MIOS_USER`, `MIOS_PASSWORD_HASH`, `MIOS_FLATPAKS`
**Source:** `~/.config/mios/*.toml`
**Propagation:** `Containerfile ARG`

---

### Build-Time Stage
**Variables:** `PACKAGES_MD`, `VERSION`, `MIOS_BUILD_STATE`
**Source:** `Containerfile COPY`, `automation/build.sh`
**Propagation:** Layer commits

---

### Post-Build Stage
**Variables:** `IMAGE_TAG`, `RECHUNK_LAYERS`
**Source:** `Justfile` targets
**Propagation:** `podman` commands

---

### Deployment Stage
**Variables:** `MIOS_HOSTNAME`, `MIOS_AI_KEY`, `MIOS_AI_MODEL`
**Source:** `/etc/mios/runtime.env`, `systemd EnvironmentFile`
**Propagation:** systemd units, shell profiles

---

### Runtime Stage
**Variables:** `MIOS_AI_*`, `MIOS_ROLE`, `GPU_VENDOR`
**Source:** `~/.config/mios/runtime.env`, `/var/lib/mios/state/`
**Propagation:** Environment variables, `systemd-detect-virt`

---

## AI API Integration

### Query Variable Metadata
```json
{
  "function": "mios_variable_get",
  "parameters": {
    "variable_name": "MIOS_BASE_IMAGE",
    "scope": "build_time"
  },
  "returns": {
    "name": "MIOS_BASE_IMAGE",
    "value": "ghcr.io/ublue-os/ucore-hci:stable-nvidia",
    "default": "ghcr.io/ublue-os/ucore-hci:stable-nvidia",
    "mutability": "build_time",
    "tracked_in": ["Containerfile:19", "Justfile:45"],
    "user_editable": true
  }
}
```

---

### Modify Variable
```json
{
  "function": "mios_variable_set",
  "parameters": {
    "variable_name": "MIOS_AI_MODEL",
    "value": "llama3.1:70b",
    "scope": "user_config"
  },
  "returns": {
    "status": "success",
    "message": "Updated ~/.config/mios/env.toml: ai.model = \"llama3.1:70b\""
  }
}
```

---

## Tracked Variables (@track: Markers)

Variables with `@track:MARKER` comments are automatically tracked across files:

### Example: MIOS_BASE_IMAGE
```bash
# Containerfile:19
ARG BASE_IMAGE=ghcr.io/ublue-os/ucore-hci:stable-nvidia # @track:IMG_BASE

# Justfile:45
--build-arg BASE_IMAGE={{env_var_or_default("MIOS_BASE_IMAGE", "ghcr.io/ublue-os/ucore-hci:stable-nvidia")}}

# .ai/variables.json
"tracked_in": [
  "Containerfile:19",
  "Justfile:45"
],
"marker": "@track:IMG_BASE"
```

**Purpose:** AI agents know all locations to update when changing this variable

---

## Security Considerations

### Critical Variables (Never Commit)
- `MIOS_PASSWORD_HASH` - User password hash
- `MIOS_AI_KEY` - AI API key
- Any variable in `ai.env` file

**Storage:** `~/.config/mios/ai.env` (add to `.gitignore`)

---

### Placeholder System
Use placeholders in templates:
- `INJ_PASSWORD_HASH` - Password hash placeholder
- `INJ_USERNAME` - Username placeholder
- `INJ_API_KEY` - API key placeholder

---

## Quick Reference

### List All Variables
```bash
# Show all MIOS_* variables
env | grep '^MIOS_' | sort
```

---

### Load User Environment
```bash
# Source user configuration
source ./tools/load-user-env.sh

# Check loaded variables
env | grep '^MIOS_'
```

---

### Edit User Configuration
```bash
# Edit environment
vim ~/.config/mios/env.toml

# Edit images
vim ~/.config/mios/images.toml

# Edit Flatpaks
vim ~/.config/mios/flatpaks.list
```

---

### Build with Custom Variables
```bash
# Set inline
MIOS_BASE_IMAGE="registry.fedoraproject.org/fedora-bootc:rawhide" just build

# Or edit config first
vim ~/.config/mios/images.toml
just build
```

---

## Troubleshooting

### Variables Not Loaded
**Solution:** Source `tools/load-user-env.sh` before running `just`

### Wrong Base Image Used
**Solution:** Check `~/.config/mios/images.toml` and `MIOS_BASE_IMAGE` env var

### Secrets in Image
**Solution:** Never use `ENV` for secrets in Containerfile, use runtime `/etc/mios/runtime.env`

### State Not Persisting
**Solution:** Check `/var/lib/mios/state/` is declared in `/usr/lib/tmpfiles.d/mios.conf`

---

## Related Files

- [.ai/variables.json](.ai/variables.json) - Complete variable metadata
- [.ai/filesystem-structure.yaml](.ai/filesystem-structure.yaml) - FHS storage locations
- [tools/load-user-env.sh](tools/load-user-env.sh) - TOML parser and loader
- [tools/init-user-space.sh](tools/init-user-space.sh) - User config initializer
- [Containerfile](Containerfile) - Build-time ARG variables
- [Justfile](Justfile) - Build entry point with env_var_or_default()

---

**Generated:** 2026-04-28
**Version:** 1.0.0
**License:** Personal Property - MiOS-DEV
