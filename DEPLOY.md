# MiOS Deployment Guide - Linux Filesystem Native

**Version:** MiOS v0.1.3
**Date:** 2026-04-27

---

##  Overview

This guide explains how to deploy MiOS as a **Linux filesystem-native integrated build environment** on a minimal Fedora server. The repository installs itself into FHS-compliant system locations and becomes a fully integrated system for building and deploying MiOS images.

---

## [GOAL] Deployment Model

### Concept

MiOS deploys as a **native Linux application** following the Filesystem Hierarchy Standard (FHS 3.0):

```
/usr/share/mios/        # Application data (scripts, templates, source)
/etc/mios/              # System configuration
/var/lib/mios/          # State data (artifacts, snapshots)
/var/log/mios/          # Build logs
/usr/local/bin/mios     # CLI command
$HOME/.config/mios/     # User configuration (XDG)
```

### Use Cases

1. **Build Server** - Dedicated server for building MiOS images
2. **CI/CD Pipeline** - Automated build and deployment
3. **Development Workstation** - Local development environment
4. **Airgap Environment** - Offline build system

---

## [START] Quick Start - Minimal Fedora Server

### Prerequisites

- **System:** Fedora Server 40+ (minimal installation)
- **Hardware:** 4GB RAM minimum, 20GB disk space
- **Network:** Internet access for initial setup
- **Access:** Root/sudo privileges

### Step 1: Install Fedora Server (Minimal)

```bash
# Boot from Fedora Server ISO
# Select: Minimal Install
# Configure network, hostname, root password
# Reboot into minimal Fedora environment
```

### Step 2: Install Required Packages

```bash
# Update system
sudo dnf update -y

# Install prerequisites
sudo dnf install -y git podman just rsync

# Verify installations
git --version
podman --version
just --version
```

**Package Descriptions:**
- `git` - Version control (clone MiOS repository)
- `podman` - Container runtime (build OCI images)
- `just` - Command runner (build orchestration)
- `rsync` - File synchronization (deployment)

### Step 3: Clone MiOS Repository

```bash
# Clone to temporary location
cd /tmp
git clone https://github.com/Kabuki94/MiOS-bootstrap.git
cd mios
```

### Step 4: Run Bootstrap Installer

```bash
# Install MiOS to system directories
sudo ./install.sh
```

**What This Does:**
1. Creates FHS directory structure
2. Installs MiOS to `/usr/share/mios/`
3. Copies configuration templates to `/etc/mios/`
4. Creates `/var` directories via tmpfiles.d
5. Installs `mios` command to `/usr/local/bin/`
6. Sets proper permissions

### Step 5: Initialize User-Space

```bash
# As regular user (not root)
mios init-user-space
```

**Creates:**
- `~/.config/mios/` - Your configuration
- `~/.local/share/mios/` - Your data
- `~/.cache/mios/` - Your cache
- `~/.local/state/mios/logs/` - Your build logs

### Step 6: Configure Build Environment

```bash
# Edit environment configuration
mios edit-env

# Edit OCI image preferences
mios edit-images

# Edit build configuration
mios edit-build
```

### Step 7: Build MiOS

```bash
# Build MiOS OCI image
mios build

# Or full pipeline with logging
mios build-and-log
```

---

## [DIR] Filesystem Layout After Installation

### System Directories (Root-Owned)

```
/usr/share/mios/                    # Application installation
+-- Containerfile                   # OCI build instructions
+-- Justfile                        # Build orchestration
+-- VERSION                         # MiOS version
+-- automation/                     # Build automation scripts
+-- etc/                            # System files (copied to image)
+-- usr/                            # User files (copied to image)
+-- var/                            # Variable data (tmpfiles.d)
+-- specs/                          # Specifications and docs
+-- tools/                          # Build and deployment tools

/etc/mios/                          # System configuration
+-- templates/                      # Configuration templates
|   +-- default.env.toml            # Environment template
|   +-- default.images.toml         # OCI images template
|   +-- default.build.toml          # Build config template
|   +-- flatpaks.list               # Flatpak apps template
+-- manifest.json                   # Installation manifest

/var/lib/mios/                      # State data (created by tmpfiles.d)
+-- artifacts/                      # Built artifacts
+-- snapshots/                      # Build snapshots
+-- images/                         # Downloaded images

/var/log/mios/                      # Build logs (created by tmpfiles.d)
+-- builds/                         # Per-build logs

/usr/local/bin/
+-- mios                            # CLI command wrapper

/etc/tmpfiles.d/
+-- mios.conf                       # /var directory declarations
```

### User Directories (Per-User, XDG)

```
$HOME/.config/mios/                 # User configuration
+-- env.toml                        # Environment overrides
+-- images.toml                     # OCI image preferences
+-- build.toml                      # Build configuration
+-- flatpaks.list                   # Flatpak applications
+-- credentials/                    # Credentials (gitignored)

$HOME/.local/share/mios/            # User data
+-- artifacts/                      # User artifacts
+-- templates/                      # User templates

$HOME/.cache/mios/                  # User cache
+-- podman/                         # Podman build cache
+-- downloads/                      # Temporary downloads

$HOME/.local/state/mios/            # User state
+-- logs/                           # User build logs
```

---

## [TOOL] MiOS Command Reference

The `mios` command is a wrapper around `just` that runs in the installed directory.

### Build Commands

```bash
# Build OCI image
mios build

# Build with logging
mios build-logged

# Build and log to bootstrap
mios build-and-log

# Build all artifacts (QCOW2, ISO, etc.)
mios all
```

### User-Space Commands

```bash
# Initialize user-space
mios init-user-space

# Re-initialize (overwrite configs)
mios reinit-user-space

# Show user-space paths
mios show-user-space

# Show environment variables
mios show-env

# Edit configurations
mios edit-env
mios edit-images
mios edit-build
mios edit-flatpaks
```

### Artifact Commands

```bash
# Generate QCOW2 image
mios qcow2

# Generate ISO installer
mios iso

# Generate RAW disk image
mios raw

# Rechunk OSTree for composefs
mios rechunk
```

---

## [NET] Deployment Scenarios

### Scenario 1: Local Development Workstation

```bash
# Install on Fedora Workstation
sudo dnf install -y git podman just rsync
git clone https://github.com/Kabuki94/MiOS-bootstrap.git
cd mios
sudo ./install.sh

# Configure for local development
mios init-user-space
mios edit-images  # Set base image for your GPU

# Build locally
mios build
```

### Scenario 2: CI/CD Build Server

```bash
# Minimal Fedora Server
sudo dnf install -y git podman just rsync
git clone https://github.com/Kabuki94/MiOS-bootstrap.git
cd mios
sudo ./install.sh

# Configure for CI
mios init-user-space
mios edit-images  # Set registry and push_on_build=true

# Automated build (in CI pipeline)
mios build-and-log
```

### Scenario 3: Airgap/Offline Environment

```bash
# 1. On internet-connected machine - download dependencies
podman pull ghcr.io/ublue-os/ucore-hci:stable-nvidia
podman pull quay.io/centos-bootc/bootc-image-builder:latest
podman save -o mios-base-images.tar \
    ghcr.io/ublue-os/ucore-hci:stable-nvidia \
    quay.io/centos-bootc/bootc-image-builder:latest

# 2. Transfer to airgap machine
scp mios-base-images.tar airgap-server:/tmp/

# 3. On airgap machine - load images
podman load -i /tmp/mios-base-images.tar

# 4. Install MiOS
git clone file:///path/to/mios-mirror
cd mios
sudo ./install.sh

# 5. Configure for offline
mios init-user-space
mios edit-images  # Set mirrors to local registry

# Build
mios build
```

### Scenario 4: Multi-User Build Server

```bash
# Install MiOS (root)
sudo ./install.sh

# Each user initializes their own space
# User 1
su - developer1
mios init-user-space
mios edit-env  # Set personal preferences
mios build

# User 2
su - developer2
mios init-user-space
mios edit-env  # Different preferences
mios build

# Builds are isolated per-user in ~/.config/mios/
```

---

## [SYNC] Update and Maintenance

### Update MiOS Installation

```bash
# Pull latest changes
cd /tmp
git clone https://github.com/Kabuki94/MiOS-bootstrap.git
cd mios

# Re-install (overwrites /usr/share/mios/ and /etc/mios/)
sudo ./install.sh

# User configs in ~/.config/mios/ are preserved
```

### Update User Configuration Templates

```bash
# Re-initialize user-space with new templates
mios reinit-user-space

# This overwrites ~/.config/mios/*.toml with new templates
# Backup your configs first if you have customizations
```

### Clean Build Cache

```bash
# Remove Podman build cache
podman system prune -a

# Remove user build cache
rm -rf ~/.cache/mios/build-cache

# Remove old logs
rm -rf ~/.local/state/mios/logs/*.log
```

---

## [CLEAN]  Uninstallation

### Remove MiOS from System

```bash
# Run uninstaller
cd /tmp/mios  # Or wherever you cloned
sudo ./install.sh --uninstall
```

**What This Removes:**
- `/usr/share/mios/` - Application data
- `/etc/mios/` - System configuration
- `/usr/local/bin/mios` - CLI command
- `/etc/tmpfiles.d/mios.conf` - tmpfiles config

**What This Keeps:**
- `/var/lib/mios/` - State data (artifacts)
- `/var/log/mios/` - Build logs
- `$HOME/.config/mios/` - User configuration

### Remove User Configuration

```bash
# Remove user-space (per-user)
rm -rf ~/.config/mios
rm -rf ~/.local/share/mios
rm -rf ~/.cache/mios
rm -rf ~/.local/state/mios
```

### Complete Removal

```bash
# Uninstall system
sudo ./install.sh --uninstall

# Remove /var data
sudo rm -rf /var/lib/mios /var/log/mios

# Remove user configs (per-user)
rm -rf ~/.config/mios ~/.local/share/mios ~/.cache/mios ~/.local/state/mios
```

---

##  Troubleshooting

### Issue: "mios: command not found"

```bash
# Check if MiOS is installed
ls -la /usr/local/bin/mios

# If not installed, run:
sudo ./install.sh

# Check PATH
echo $PATH | grep -q '/usr/local/bin' || echo "Add /usr/local/bin to PATH"
```

### Issue: "Permission denied" when running mios

```bash
# Check permissions
ls -la /usr/local/bin/mios

# Should be executable
sudo chmod +x /usr/local/bin/mios
```

### Issue: Podman fails with "permission denied"

```bash
# Ensure Podman is set up for rootless
podman system migrate

# Test Podman
podman run --rm alpine echo "Podman works"

# If still failing, check subuid/subgid
grep $USER /etc/subuid /etc/subgid
```

### Issue: "just: command not found"

```bash
# Install just
sudo dnf install -y just

# Or install from GitHub releases
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin
```

### Issue: Build fails with "No such base image"

```bash
# Check image configuration
mios show-env | grep BASE_IMAGE

# Pull base image manually
podman pull ghcr.io/ublue-os/ucore-hci:stable-nvidia

# Or edit image config
mios edit-images
```

---

## [STAT] Verification

### Verify Installation

```bash
# Check installation manifest
cat /etc/mios/manifest.json | jq .

# Check system directories
ls -la /usr/share/mios/
ls -la /etc/mios/
ls -la /var/lib/mios/
ls -la /var/log/mios/

# Check mios command
which mios
mios show-user-space
```

### Verify User-Space

```bash
# Check user configuration
mios show-user-space

# Check environment variables
mios show-env

# List user configs
ls -la ~/.config/mios/
```

### Test Build

```bash
# Test simple build
mios build

# Check build output
podman images | grep mios

# Check logs
ls -la ~/.local/state/mios/logs/
```

---

##  References

- **Installation Script:** [install.sh](install.sh)
- **User-Space Guide:** [USER-SPACE-GUIDE.md](USER-SPACE-GUIDE.md)
- **FHS 3.0 Spec:** https://refspecs.linuxfoundation.org/FHS_3.0/
- **XDG Spec:** https://specifications.freedesktop.org/basedir-spec/
- **Podman Docs:** https://docs.podman.io/
- **Just Manual:** https://just.systems/man/

---

**Generated:** 2026-04-27
**MiOS Version:** v0.1.3
**License:** Personal Property - MiOS-DEV
