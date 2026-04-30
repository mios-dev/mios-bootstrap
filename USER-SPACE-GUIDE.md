# MiOS User-Space Configuration Guide

**Version:** MiOS v0.2.0
**Date:** 2026-04-27

---

##  Overview

MiOS v0.2.0 introduces **user-space separation** following the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html). This separates mutable user configuration from the immutable system repository, enabling:

[OK] **Environment-independent configuration** - Move between machines without conflicts
[OK] **Secure credential management** - Credentials never committed to git
[OK] **Multi-user support** - Each user has their own configuration
[OK] **TOML-based configuration** - Structured, human-readable config files
[OK] **Backwards compatible** - Legacy `.env` still works (deprecated)

---

## [START] Quick Start

### 1. Initialize User-Space

```bash
# Clone MiOS repository
git clone https://github.com/MiOS-DEV/MiOS-bootstrap.git
cd mios

# Initialize your user-space configuration
just init-user-space
```

This creates:
- `~/.config/mios/` - Your configuration files
- `~/.local/share/mios/` - Your data files
- `~/.cache/mios/` - Your cache files
- `~/.local/state/mios/` - Your logs and state

### 2. Customize Configuration

```bash
# Edit environment settings
just edit-env

# Edit OCI image preferences
just edit-images

# Edit build configuration
just edit-build

# Add Flatpak applications
just edit-flatpaks
```

### 3. Add Credentials (Optional)

```bash
# GitHub Personal Access Token
echo "ghp_your_token_here" > ~/.config/mios/credentials/github-token
chmod 600 ~/.config/mios/credentials/github-token

# Container registry authentication
podman login ghcr.io
cp ~/.config/containers/auth.json ~/.config/mios/credentials/registry-auth.json
```

### 4. Build MiOS

```bash
# Build with your user configuration
just build

# Or full pipeline with logging
just build-and-log
```

---

## [DIR] Directory Structure

### XDG Base Directory Layout

```
$HOME/
+-- .config/mios/              # XDG_CONFIG_HOME - Configuration files
|   +-- env.toml               # Environment configuration
|   +-- images.toml            # OCI image references
|   +-- build.toml             # Build configuration
|   +-- flatpaks.list          # Flatpak applications
|   +-- credentials/           # Credentials (gitignored)
|   |   +-- github-token       # GitHub PAT
|   |   +-- registry-auth.json # Container registry auth
|   |   +-- ssh-keys/          # SSH keys
|   +-- README.md              # Quick reference
|
+-- .local/share/mios/         # XDG_DATA_HOME - User data
|   +-- artifacts/             # Downloaded artifacts
|   +-- images/                # Downloaded OCI images
|   +-- templates/             # User templates
|   +-- plugins/               # User plugins
|
+-- .cache/mios/               # XDG_CACHE_HOME - Cache files
|   +-- podman/                # Podman build cache
|   +-- downloads/             # Temporary downloads
|   +-- build-cache/           # Build artifacts cache
|
+-- .local/state/mios/         # XDG_STATE_HOME - Logs & state
    +-- logs/                  # Build logs
    |   +-- build-*.log
    +-- history.log            # Command history
    +-- last-build.json        # Last build metadata
```

### Repository Structure (System Files)

```
mios/                          # Repository root (SYSTEM ONLY)
+-- etc/mios/templates/        # System default templates
|   +-- default.env.toml       # Environment template
|   +-- default.images.toml    # Images template
|   +-- default.build.toml     # Build template
|   +-- flatpaks.list          # Flatpaks template
+-- Containerfile              # OCI build instructions
+-- Justfile                   # Build orchestration
+-- VERSION                    # System version
+-- usr/                       # System files (copied to image)
+-- etc/                       # System configuration
+-- var/                       # System variable data
+-- automation/                # Build automation scripts
```

**Key Principle:** Repository contains **system defaults only**. User configuration lives in `$HOME/.config/mios/`.

---

##   Configuration Files

### 1. env.toml - Environment Configuration

Location: `~/.config/mios/env.toml`

```toml
[mios]
version = "v0.2.0"
user = "your-username"
hostname = "your-hostname"

[build]
no_cache = false
parallel_jobs = 4
verbose = false

[logging]
log_dir = ""  # Auto: ~/.local/state/mios/logs
retain_days = 30
log_level = "info"

[preferences]
editor = "vim"
shell = "bash"
terminal = "gnome-terminal"
```

### 2. images.toml - OCI Image Configuration

Location: `~/.config/mios/images.toml`

```toml
[base]
# Choose your base image:
# - ghcr.io/ublue-os/ucore-hci:stable-nvidia (NVIDIA GPUs)
# - ghcr.io/ublue-os/ucore-hci:stable (Intel/AMD GPUs)
# - ghcr.io/ublue-os/ucore:stable (minimal)
image = "ghcr.io/ublue-os/ucore-hci:stable-nvidia"

[builder]
image = "quay.io/centos-bootc/bootc-image-builder:latest"

[output]
name = "localhost/mios"
tags = ["latest", "v0.2.0"]
registry = "ghcr.io"
repository = "your-username/mios"

[registry]
push_on_build = false
use_auth = false
tls_verify = true
```

### 3. build.toml - Build Configuration

Location: `~/.config/mios/build.toml`

```toml
[artifacts]
enabled = ["qcow2", "iso"]
output_dir = "./output"

[qcow2]
enabled = true
disk_size = "50G"

[iso]
enabled = false
installer_type = "anaconda"
minsize = true

[flatpaks]
enabled = false
source_file = ""  # Auto: ~/.config/mios/flatpaks.list

[nvidia]
enabled = true
driver_version = "latest"
cuda = true

[users]
default_user = "mios"
default_groups = ["wheel"]

[hostname]
default = "mios"

[timezone]
default = "UTC"

[locale]
default = "en_US.UTF-8"
```

### 4. flatpaks.list - Flatpak Applications

Location: `~/.config/mios/flatpaks.list`

```
# One Flatpak application ID per line
# Lines starting with # are comments

# Web Browsers
org.mozilla.firefox

# Development Tools
com.visualstudio.code

# Media & Graphics
org.blender.Blender
org.gimp.GIMP
```

---

##  Credential Management

### GitHub Personal Access Token

```bash
# Create token at: https://github.com/settings/tokens
# Required scopes: repo, workflow, read:packages

echo "ghp_your_token_here" > ~/.config/mios/credentials/github-token
chmod 600 ~/.config/mios/credentials/github-token
```

### Container Registry Authentication

```bash
# Authenticate with Podman
podman login ghcr.io

# Copy auth file to MiOS credentials
cp ~/.config/containers/auth.json ~/.config/mios/credentials/registry-auth.json
chmod 600 ~/.config/mios/credentials/registry-auth.json
```

### SSH Keys for Private Repositories

```bash
# Use existing SSH key
cp ~/.ssh/id_ed25519 ~/.config/mios/credentials/ssh-keys/
chmod 600 ~/.config/mios/credentials/ssh-keys/id_ed25519

# Or generate new key
ssh-keygen -t ed25519 -f ~/.config/mios/credentials/ssh-keys/id_ed25519 -C "mios-build"
```

### Secure Boot MOK Key

```bash
# Generate MOK key
cd ~/mios
./tools/generate-mok-key.sh

# Move to credentials
mv MOK.priv ~/.config/mios/credentials/mok-key.priv
mv MOK.pem ~/.config/mios/credentials/mok-cert.pem
chmod 600 ~/.config/mios/credentials/mok-key.priv
```

**IMPORTANT:** The `credentials/` directory is automatically gitignored and will **never** be committed.

---

## [SYNC] Configuration Priority

Variables are loaded in priority order (later overrides earlier):

1. **System Defaults** (`etc/mios/templates/`)
   - Shipped with MiOS
   - Read-only, version-controlled

2. **User Configuration** (`~/.config/mios/`)
   - Your overrides
   - Mutable, transient

3. **Environment Variables** (e.g., `MIOS_BASE_IMAGE`)
   - Shell environment
   - Session-specific

4. **Command-Line Arguments**
   - Direct overrides
   - Highest priority

### Example

```bash
# System default (etc/mios/templates/default.images.toml)
base.image = "ghcr.io/ublue-os/ucore-hci:stable-nvidia"

# User override (~/.config/mios/images.toml)
base.image = "ghcr.io/ublue-os/ucore-hci:stable"

# Environment variable (highest priority)
export MIOS_BASE_IMAGE="ghcr.io/custom/image:latest"

# Result: Uses "ghcr.io/custom/image:latest"
```

---

## [ENG]  Common Tasks

### Check User-Space Status

```bash
just show-user-space
```

Output:
```
MiOS User-Space Directories:
  Config:  /home/user/.config/mios/
  Data:    /home/user/.local/share/mios/
  Cache:   /home/user/.cache/mios/
  State:   /home/user/.local/state/mios/

Configuration files:
  [OK] env.toml
  [OK] images.toml
  [OK] build.toml
```

### Show Loaded Environment Variables

```bash
just show-env
```

Output:
```
MiOS Environment Variables:
  MIOS_BASE_IMAGE=ghcr.io/ublue-os/ucore-hci:stable-nvidia
  MIOS_BIB_IMAGE=quay.io/centos-bootc/bootc-image-builder:latest
  MIOS_HOSTNAME=mios
  MIOS_IMAGE_NAME=localhost/mios:latest
  MIOS_USER=mios
  ...
```

### Re-initialize User-Space (Overwrite Configs)

```bash
# WARNING: This will overwrite your existing configurations
just reinit-user-space
```

### Migrate from Legacy .env

If you have an existing `.env` file:

```bash
# 1. Initialize user-space
just init-user-space

# 2. Manually migrate variables from .env to ~/.config/mios/env.toml

# 3. Remove old .env (optional - it's gitignored)
rm .env
```

---

## [NET] Multi-Environment Portability

User-space configuration is designed to be portable across environments:

### Development Machine

```toml
# ~/.config/mios/images.toml
[base]
image = "ghcr.io/ublue-os/ucore-hci:stable-nvidia"  # Your dev GPU

[output]
name = "localhost/mios"
push_on_build = false
```

### CI/CD Pipeline

```toml
# ~/.config/mios/images.toml (on CI machine)
[base]
image = "ghcr.io/ublue-os/ucore:stable"  # Minimal base

[output]
name = "ghcr.io/your-org/mios"
repository = "your-org/mios"
push_on_build = true
```

The repository stays the same - only user configuration changes!

---

## [CLEAN] Cleanup

### Remove User-Space Configuration

```bash
# Remove all user-space files
rm -rf ~/.config/mios
rm -rf ~/.local/share/mios
rm -rf ~/.cache/mios
rm -rf ~/.local/state/mios
```

### Remove Build Artifacts

```bash
# Remove local build cache
rm -rf ~/.cache/mios/build-cache

# Remove old logs
rm -rf ~/.local/state/mios/logs/*.log
```

---

##  Troubleshooting

### "User config not found" Error

```bash
# Initialize user-space
just init-user-space
```

### Environment Variables Not Loading

```bash
# Check if configuration files exist
just show-user-space

# Manually load and check
source ./tools/load-user-env.sh
env | grep MIOS_
```

### Build Using Wrong Base Image

```bash
# Check loaded environment
just show-env | grep BASE_IMAGE

# Edit image configuration
just edit-images

# Set explicit override
export MIOS_BASE_IMAGE="your-image:tag"
just build
```

### Credentials Not Working

```bash
# Check file permissions
ls -la ~/.config/mios/credentials/

# Credentials should be 600 (read/write for owner only)
chmod 600 ~/.config/mios/credentials/*
```

---

##  References

- **Engineering Spec:** [ENG-008: User-Space Separation](specs/engineering/2026-04-27-Artifact-ENG-008-UserSpace-Separation.md)
- **XDG Spec:** https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
- **TOML Spec:** https://toml.io/en/v0.2.0
- **System Templates:** [etc/mios/templates/](etc/mios/templates/)

---

## [TIP] Tips & Best Practices

1. **Use version control for your user configs** (optional)
   - Create a private dotfiles repo
   - Sync `~/.config/mios/` (exclude `credentials/`)

2. **Different configs for different machines**
   - Laptop: Smaller disk sizes, local images
   - Workstation: Larger disks, push to registry
   - CI/CD: Minimal base, automated push

3. **Backup your credentials**
   - Use a password manager
   - Encrypted backup of `~/.config/mios/credentials/`

4. **Test configuration changes**
   ```bash
   # Show what would be used without building
   just show-env
   ```

5. **Keep system templates updated**
   ```bash
   # After git pull
   just reinit-user-space --force
   ```

---

**Generated:** 2026-04-27
**MiOS Version:** v0.2.0
**License:** Personal Property - MiOS-DEV
