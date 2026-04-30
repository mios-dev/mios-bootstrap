# MiOS — Complete Engineering Reference & Software Bill of Materials

**Version:** v0.2.0
**Generated:** 2026-04-30
**Sources:** `github.com/mios-dev/mios` (commit at clone), `github.com/mios-dev/mios-bootstrap` (commit at clone), project knowledge files, `usr/share/mios/PACKAGES.md` (SSOT)

This document is the consolidated, file-grounded engineering reference for MiOS (formerly CloudWS-bootc / CloudWS-OS — all three names refer to the same project). Every claim below is traceable to a path in one of the two repositories or a project-knowledge document. Where memory or prior notes contradict the live repos, **the live repos win** and that is called out explicitly.

---

## 0. Project Identity & Naming

| Attribute | Value |
|---|---|
| Current name | **MiOS** |
| Prior names | CloudWS-bootc, CloudWS-OS (deprecated; do not use in new docs) |
| Proprietor | MiOS-DEV |
| License | Apache-2.0 (root `LICENSE`); component licenses in `LICENSES.md` |
| System repo | `https://github.com/mios-dev/mios` |
| Bootstrap repo | `https://github.com/mios-dev/mios-bootstrap` |
| Published image | `ghcr.io/mios-dev/mios:latest` |
| Image tags | `latest`, `v0.2.0`, branch refs, PR refs, semver (per `.github/workflows/mios-ci.yml`) |
| Memory caveat | User memory still contains references to `Kabuki94/CloudWS-bootc` and `Kabuki94/MiOS`. Those are stale. The current canonical org is **mios-dev** and the canonical repos are the two cloned above. |

### What MiOS is, in one paragraph

MiOS is an immutable, bootc-managed, OCI-image-delivered Linux workstation/server OS built from a Universal Blue `ucore-hci` NVIDIA-signed base, distro-synced to Fedora 44 userspace while preserving the ucore base kernel. It packages the GNOME 50 desktop, the full KVM/QEMU/VFIO virtualization stack with Looking Glass B7 (built in-image), Podman + Quadlet sidecars, K3s, Ceph (cephadm-orchestrated), an OpenAI-compatible local AI surface backed by LocalAI, plus a defense-in-depth security stack (SELinux enforcing + custom modules, fapolicyd, CrowdSec, USBGuard, fapolicyd, kernel hardening kargs, sigstore/cosign keyless image verification). It boots identically on bare metal, Hyper-V (VHDX), WSL2 (tarball), QEMU/KVM (RAW), and from an Anaconda installer ISO, and it can rebuild itself — a running MiOS host has every tool needed to produce its own next image.

---

## 1. Repository Topology

There are two repositories. They cooperate. The system repo holds the OS image; the bootstrap repo holds the user-facing installer.

### 1.1 `mios-dev/mios` — the **system layer** (380 files, ~27 MB)

```
mios/
├── Containerfile               # Two-stage OCI build (ctx + main)
├── Justfile                    # Linux-native build orchestrator
├── VERSION                     # 0.2.0
├── image-versions.yml          # Renovate-managed base image digests
├── renovate.json               # Renovate config (best-practices + digest pinning)
├── root-manifest.json          # 217 KB inventory of every root file with rendered content
├── ai-context.json             # AI agent context manifest
├── llms.txt / llms-full.txt    # AI ingestion indices
├── system-prompt.md            # Authoritative agent identity (deployed to /usr/share/mios/ai/)
│
├── README.md                   # Project overview
├── INDEX.md                    # SSOT — Universal Agent Hub (immutable laws)
├── ARCHITECTURE.md             # Hardware / FS / Virt blueprint
├── ENGINEERING.md              # Security framework, build modes, kernel hardening
├── DEPLOY.md                   # Deployment scenarios (workstation, CI, airgap, multi-user)
├── SELF-BUILD.md               # 5 build modes (Bootstrap, CI/CD, Win-Local, Linux-Local, Self)
├── SECURITY.md                 # Full hardening checklist with override paths
├── CONTRIBUTING.md             # Project conventions
├── LICENSES.md                 # Component licenses (proprietary + OSS + firmware)
├── AGENTS.md / AI-AGENT-GUIDE.md  # Both deprecated → see INDEX.md
│
├── build-mios.sh               # Fedora Server ignition installer (interactive)
├── install.sh                  # FHS overlay installer for non-bootc Fedora hosts
├── mios-build-local.ps1        # 5-phase Windows build orchestrator (PS7+)
├── preflight.ps1               # Windows prereq checker (WSL2, Hyper-V, Podman)
├── push-to-github.ps1          # Single, version-stable release pipeline
│
├── automation/                 # The numbered build pipeline (see §3)
│   ├── build.sh                # Master runner; executes 01-99 in order
│   ├── lib/{common,packages,masking}.sh
│   ├── 01-repos.sh … 99-postcheck.sh   # 50+ numbered phase scripts
│   ├── ai-bootstrap.sh
│   ├── enroll-mok.sh
│   ├── generate-mok-key.sh
│   ├── bcvk-wrapper.sh
│   ├── mios-build-builder.ps1  # Podman machine provisioner
│   ├── validate-kargs.py
│   └── manifest.json
│
├── usr/                        # FHS overlay → bakes into image at /usr
│   ├── bin/mios                # Python OpenAI client CLI (49 lines)
│   ├── libexec/mios/{copy-build-log.sh,gpu-detect,motd,role-apply}
│   ├── lib/                    # Config overlays (see §6)
│   │   ├── bootc/kargs.d/      # 14 kargs.d TOMLs (security, GPU, VFIO, console)
│   │   ├── sysctl.d/           # 4 hardening + perf sysctl drop-ins
│   │   ├── modprobe.d/         # NVIDIA, KVMFR, nouveau blacklist, vmw_vsock blacklist
│   │   ├── modules-load.d/     # VFIO stack + ceph/rbd
│   │   ├── tmpfiles.d/         # 16 tmpfiles drop-ins (every /var dir declared)
│   │   ├── sysusers.d/         # mios, mios-ai, mios-virt, core (podman-compat)
│   │   ├── systemd/system/     # 70+ MiOS unit files & drop-ins
│   │   ├── greenboot/          # 5 required + 4 wanted health checks
│   │   ├── fapolicyd/          # Custom rules + zero-trust deny
│   │   ├── dracut/conf.d/      # 5 dracut conf drop-ins (verify, hyperv, virtio, nvidia)
│   │   ├── uupd/config.json    # Updater config
│   │   ├── crowdsec/           # journalctl acquisition
│   │   ├── ostree/             # composefs prepare-root config (referenced)
│   │   ├── repart.d/, sysupdate.d/, usbguard/, ssh/, sssd/, xrdp/,
│   │   │  waydroid/, NetworkManager/, libvirt/, rancher/, cockpit/,
│   │   │  cloud/, environment.d/, firewalld/, X11/, profile.d/,
│   │   │  pam.d/, sudoers.d/, udev/
│   │   └── …
│   └── share/mios/
│       ├── PACKAGES.md         # ★ THE SSOT for all packages (727 lines, 30 sections)
│       ├── ai/v1/{models.json,context.json,mcp.json,system.md,knowledge.md}
│       └── memory/             # AI agent memory store (placeholder)
│
├── etc/                        # FHS overlay → bakes into image at /etc
│   └── containers/systemd/     # Quadlet sidecars (see §7)
│       ├── mios.network        # 10.89.0.0/24 podman network
│       ├── mios-ai.container   # docker.io/localai/localai:v2.20.0
│       ├── mios-ceph.container # quay.io/ceph/ceph:latest (mon)
│       └── mios-k3s.container  # docker.io/rancher/k3s:v1.32.1-k3s1
│
├── home/                       # /etc/skel-style user template
├── srv/ai/                     # /srv/ai overlay
├── tools/                      # Helper scripts (sysext-pack, etc.)
├── agents/research/            # Placeholder for agent research artifacts
├── v1/chat/                    # OpenAI API surface placeholders (currently empty)
├── config/{artifacts,bootstrap}/  # bib.toml, iso.toml, ignition configs
│
├── .github/workflows/mios-ci.yml   # Build → cosign sign → push → optional smoke
├── .devcontainer/                  # Codespaces / dev container
│
└── FOUND-THE-FILES.tar             # Legacy archive (kept for reference)
    mios-legacy.tar                 # Older state archive
```

### 1.2 `mios-dev/mios-bootstrap` — the **installer** (32 files, ~9 MB)

```
mios-bootstrap/
├── VERSION                     # v0.2.0
├── README.md                   # Installer overview, install one-liner
├── install.sh                  # ★ Interactive ignition installer (sudo bash)
├── bootstrap.sh / bootstrap.ps1
├── system-prompt.md            # SSOT for AI behavior, deployed to /etc/mios/ai/
├── identity.env.example
├── .env.mios                   # User-runtime defaults
├── image-versions.yml          # Mirror of system repo's pinning
├── llms.txt
├── USER-SPACE-GUIDE.md
├── VARIABLES.md
├── IMPLEMENTATION-SUMMARY.md
├── profile/README.md           # Skeleton for future dotfiles
├── etc/mios/{manifest.json,rag-manifest.yaml}
├── usr/share/mios/knowledge/
│   ├── mios-knowledge-graph.json
│   └── script-inventory.json
└── var/lib/mios/{artifacts,snapshots}/MiOSv0.1.{2,3}/
    └── *.tar.{xz,gz}, *.json.xz   # Compressed historical RAG artifacts
```

The bootstrap repo is what an end user actually runs:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.sh)"
```

It detects host kind (bootc-managed vs FHS Fedora), gathers identity (username, hostname, GECOS, password, SSH key, GitHub PAT, image tag — every field defaults to `mios`), persists non-secrets to `/etc/mios/install.env`, and either:

- **bootc host:** `bootc switch ghcr.io/mios-dev/mios:latest`
- **FHS host:** clones the system repo and runs its `install.sh` to apply the FHS overlay.

---

## 2. Base Image & Supply Chain

### 2.1 Base image

| Component | Source | Purpose |
|---|---|---|
| **Base OS** | `ghcr.io/ublue-os/ucore-hci:stable-nvidia` | Universal Blue CoreOS with pre-signed `kmod-nvidia-open` matched to the ucore-hci kernel |
| **Base alternates** (per `build-mios.sh` menu) | `ghcr.io/ublue-os/ucore-hci:stable` (no NVIDIA), `ghcr.io/ublue-os/ucore:stable` (minimal) | Selectable at install time |
| **Userspace overlay** | Fedora 44 (added via `automation/01-repos.sh` two-phase distro-sync) | Brings F44 desktop/userspace stack |
| **Kernel policy** | **Never upgraded in-container.** Inherited from ucore-hci. | Avoids broken initramfs from dracut-under-tmpfs |

> **Memory caveat:** older project memory says base is `quay.io/fedora/fedora-bootc:rawhide`. That is the *secondary/legacy* base used in earlier MiOS-1 variant work. The active base per the live `Containerfile` is `ucore-hci:stable-nvidia`.

### 2.2 Pinned digests (`image-versions.yml`)

```yaml
ucore_hci_stable_nvidia_digest: sha256:3f4474648ab2835bdb8a29f1afe8805de96a32bc0.1.1345ecf485a395aa1d1d
# bootc-image-builder digest: populated by Renovate
# image-builder-cli digest: future-evaluation only

rechunk:
  tool: bootc-base-imagectl
  max_layers: 67
```

`renovate.json` is configured for `config:best-practices` + `docker:pinDigests`, with auto-merge for digest updates after a 7-day stability period; PRs touching `image-versions.yml` are gated on `MiOS-DEV` review.

### 2.3 External tooling images

| Image | Where | Purpose |
|---|---|---|
| `quay.io/centos-bootc/bootc-image-builder:latest` | Justfile, `mios-build-local.ps1`, BIB target generation | Converts OCI image → RAW / VHD / ISO / WSL |
| `docker.io/localai/localai:v2.20.0` | `etc/containers/systemd/mios-ai.container` | OpenAI-compatible inference backend |
| `quay.io/ceph/ceph:latest` | `etc/containers/systemd/mios-ceph.container` | Ceph monitor sidecar |
| `docker.io/rancher/k3s:v1.32.1-k3s1` | `etc/containers/systemd/mios-k3s.container` | K3s server sidecar (also installed as binary; Quadlet variant available) |
| `anchore/syft:latest` | `Justfile` `sbom` target | CycloneDX SBOM generation |
| `docker.io/library/alpine:latest`, `docker.io/library/python:3-slim` | `mios-build-local.ps1` fallback | Hash generation when no MiOS image yet exists (first build only) |

### 2.4 External package repos enabled in build (`automation/01-repos.sh` + `05-enable-external-repos.sh`)

- RPM Fusion Free Rawhide
- RPM Fusion Nonfree Rawhide (NVIDIA, multimedia codecs)
- Fedora 44 + Fedora 44 Updates (priority=95, overlaid on the ucore base)
- `fedora-workstation-repositories`
- CrowdSec official repo (Fedora 40 fallback for Rawhide compat)
- Universal Blue COPR `ublue-os/packages` (for `uupd`)
- `dnf-plugins-core`, `dnf5-plugins`

Base ucore/Fedora repos are pinned to `priority=98` so third-party repos can't supplant them.

### 2.5 Image signing (cosign keyless)

- Workflow: `.github/workflows/mios-ci.yml`
- Signed via `sigstore/cosign-installer@v3` with `COSIGN_EXPERIMENTAL=1` (GitHub OIDC keyless)
- Verification command (from `SECURITY.md`):
  ```bash
  cosign verify \
    --certificate-identity-regexp="https://github.com/MiOS-DEV/MiOS-bootstrap" \
    --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
    ghcr.io/mios-dev/mios:latest
  ```
- Sigstore trust roots installed by `automation/42-cosign-policy.sh`: `fulcio_v1.crt.pem`, `rekor.pub`, `ublue-os.pub`, `ublue-cosign.pub`, `mios-cosign.pub` → `/usr/share/pki/containers/`
- `policy.json` lives at `/usr/lib/containers/policy.json` (USR-OVER-ETC)
- Runtime cosign binary pinned to **v2.x** static (not v3 — v3 breaks rpm-ostree OCI 1.1 bundle format)

---

## 3. Build Pipeline

### 3.1 Containerfile (top-level, two-stage)

```dockerfile
ARG BASE_IMAGE=ghcr.io/ublue-os/ucore-hci:stable-nvidia

FROM scratch AS ctx
COPY automation/   /ctx/automation/
COPY usr/          /ctx/usr/
COPY etc/          /ctx/etc/
COPY home/         /ctx/home/
COPY usr/share/mios/PACKAGES.md  /ctx/PACKAGES.md
COPY VERSION                     /ctx/VERSION
COPY config/artifacts/           /ctx/bib-configs/
COPY tools/                      /ctx/tools/

FROM ${BASE_IMAGE}
LABEL org.opencontainers.image.title="MiOS"
LABEL containers.bootc="1"
LABEL ostree.bootable="1"
CMD ["/sbin/init"]

ARG MIOS_USER=mios
ARG MIOS_PASSWORD_HASH=
ARG MIOS_HOSTNAME=mios
ARG MIOS_FLATPAKS=

COPY --from=ctx /ctx /ctx

# (1) Inject Flatpak list if provided
# (2) Install essential security packages (selinux-policy-targeted, firewalld,
#     audit, fapolicyd, crowdsec, usbguard, kernel-devel, ...)
# (3) Apply system_files overlay via 08-system-files-overlay.sh
# (4) Run automation/build.sh (numbered pipeline) with dnf5 cache mounts
# (5) Mandatory cleanup of /var/log, /var/tmp, /var/cache/dnf, /tmp, /run/*
# (6) Install bootc bash completions
# (7) Pack systemd-sysext consolidation
# (8) ostree container commit
# (9) bootc container lint   (ABSOLUTE final instruction — Law #4)
```

### 3.2 `automation/build.sh` orchestrator

- Sources `lib/common.sh` and `lib/packages.sh`
- Sets `SYSTEMD_OFFLINE=1` and `container=podman` to suppress scriptlet hangs
- Iterates `automation/[0-9][0-9]-*.sh` in order, skipping `08-system-files-overlay.sh` (run by Containerfile pre-pipeline) and `37-ollama-prep.sh` (local-only, large model pulls)
- Uses `set -uo pipefail` (not `set -e`) so per-script exits are caught and logged but don't kill the build; tracks fail count
- After numbered scripts: removes `bloat` packages, hides `gnome-tour` / `gnome-initial-setup` via `NoDisplay=true`, masks `packagekit.service`
- Runs post-build validation: presence of all `critical` packages, NVIDIA kmods, MOK certs, Blackwell VFIO karg, `malcontent-libs`, `gnome-software`
- Runs `99-postcheck.sh` for technical invariant validation
- Preserves logs to `/usr/lib/mios/logs/` (immutable Day-2 diagnostics path)

### 3.3 Numbered phase scripts (50 scripts)

Grouped by purpose. Scripts marked `*` are gated/conditional.

| # | Script | Purpose |
|---|---|---|
| 01 | repos.sh | Set `install_weak_deps=False` globally; elevate base repos to priority 98; add Fedora 44 repos; **two-phase distro-sync** (phase 1: dnf/rpm/filesystem/systemd/glibc/dbus-broker; phase 2: full userspace); resolves filesystem `%posttrans` lua scriptlet failure that previously aborted 1100+ pkg transactions |
| 02 | kernel.sh | Install kernel-devel/headers/tools (NEVER kernel-core itself) |
| 05 | enable-external-repos.sh | RPM Fusion, ublue-os/packages COPR, CrowdSec repo |
| 08 | system-files-overlay.sh | Copy `/ctx/usr`, `/ctx/etc`, `/ctx/home` onto rootfs; handles `/usr/local → /var/usrlocal` symlink quirk on ucore/bootc bases |
| 10 | gnome.sh | Install GNOME 50 minimal shell (~25 packages); explicitly add gstreamer1 family for ABI compat with F43 base; configure dconf defaults |
| 11 | hardware.sh | Mesa + linux-firmware; conditional AMD/Intel compute stacks |
| 12 | virt.sh | KVM/QEMU/libvirt/swtpm/edk2-ovmf; OVMF & swtpm runtime dirs; libvirt URI defaults |
| 13 | ceph-k3s.sh | `ceph` package set + cephadm; download K3s binary with sha256 verification; copy install.sh |
| 18 | apply-boot-fixes.sh | Fix USBGuard config perms (0600); restore exec bits stripped by global chmod (`/usr/libexec/mios/*`, `mios-*` scripts); libvirt qemu hook +x; sysusers for systemd-resolved; ordering-cycle drop-ins; OCI/WSL2 service gating |
| 19 | k3s-selinux.sh | Compile `k3s-selinux` from source (no Fedora package exists) |
| 20 | services.sh | Enable core services (firewalld, libvirtd, podman.socket, etc.) |
| 20 | fapolicyd-trust.sh | Establish trust DB |
| 21 | moby-engine.sh | (gated) Optional Docker engine compat layer |
| 22 | freeipa-client.sh | FreeIPA + SSSD setup |
| 23 | uki-render.sh | UKI generation prep (future composefs+UKI chain) |
| 25 | firewall-ports.sh | Open Cockpit (9090), SSH (22), libvirt bridge |
| 26 | gnome-remote-desktop.sh | GNOME RDP service config |
| 30 | locale-theme.sh | en_US.UTF-8, Adwaita-dark via dconf (`color-scheme='prefer-dark'`, `ADW_DEBUG_COLOR_SCHEME=prefer-dark`) — **NOT** `GTK_THEME=Adwaita-dark` (that breaks libadwaita GTK4 apps) |
| 31 | user.sh | Read `MIOS_USER` and `MIOS_PASSWORD_HASH` ARGs; create user with hash via `chpasswd -e`; group memberships; sudoers drop-in |
| 32 | hostname.sh | `hostnamectl set-hostname` (mios default; randomized for HA mode) |
| 33 | firewall.sh | Default-deny posture; allow Cockpit, SSH, libvirt bridge, CrowdSec bouncer |
| 34 | gpu-detect.sh | Stage of mios-gpu-detect first-boot service |
| 35 | gpu-passthrough.sh | VFIO setup |
| 35 | gpu-pv-shim.sh | Para-virtualized GPU shim (Intel/AMD virt) |
| 35 | init-service.sh | Bootstrap init service registration |
| 36 | akmod-guards.sh | Guards against akmod-nvidia install on ucore-hci (already pre-signed) |
| 36 | tools.sh | CLI utilities install |
| 37 | aichat.sh | Install `aichat` + `aichat-ng` Rust LLM CLIs |
| 37 | flatpak-env.sh | Flatpak setup (Flathub remote at user level) |
| 37 | ollama-prep.sh | (CI-skipped) local Ollama model staging |
| 37 | selinux.sh | Compile and load 5 custom SELinux modules: `mios_portabled`, `mios_kvmfr`, `mios_cdi`, `mios_quadlet`, `mios_sysext`; set booleans `container_use_cephfs=on`, `virt_use_samba=on`; fcontext `/var/home(/.*)?` → `user_home_dir_t` |
| 38 | vm-gating.sh | `ConditionVirtualization=` drop-ins for bare-metal-only services |
| 39 | desktop-polish.sh | Wallpapers, default apps |
| 40 | composefs-verity.sh | composefs prepare-root.conf with `enabled = true`, `etc.transient = true`, `root.transient-ro = true` |
| 42 | cosign-policy.sh | Pin cosign v2.x; install Sigstore trust roots; install `policy.json` to `/usr/lib/containers/`; jq-validate |
| 43 | uupd-installer.sh | Install `uupd` (replaces `bootc-fetch-apply-updates.timer` + flatpak/distrobox timers) |
| 44 | podman-machine-compat.sh | Stage `core` user for Podman-machine compat |
| 45 | nvidia-cdi-refresh.sh | NVIDIA Container Device Interface (CDI) generator timer |
| 46 | greenboot.sh | Configure greenboot-rs (Rust rewrite, F43+) — `MAX_BOOT_ATTEMPTS=3`, watchdog+grace=1h |
| 47 | hardening.sh | Apply hardening drop-ins |
| 49 | finalize.sh | Final fix-ups before lint |
| 50 | enable-log-copy-service.sh | Enable mios-copy-build-log.service |
| 52 | bake-kvmfr.sh | Build the KVMFR kernel module from Looking Glass sources, sign with MOK |
| 53 | bake-lookingglass-client.sh | Compile Looking Glass B7 client from source against the build deps section |
| 90 | generate-sbom.sh | Per-build SBOM |
| 98 | boot-config.sh | systemd-boot/grub finalization |
| 99 | cleanup.sh | Final image cleanup before commit |
| 99 | postcheck.sh | Technical invariant validation (USR-OVER-ETC, NO-MKDIR-IN-VAR, BOUND-IMAGES, lint readiness) |

### 3.4 Helper scripts under `automation/`

- `ai-bootstrap.sh` — refresh AI manifests, UKB (Unified Knowledge Base), Wiki documentation
- `enroll-mok.sh` / `generate-mok-key.sh` — Machine Owner Key generation/enrollment for signed kernel modules
- `bcvk-wrapper.sh` — `bcvk` (bootc Virtual Kernel) wrapper
- `validate-kargs.py` — Python karg-policy validator
- `mios-build-builder.ps1` — Provisions the dedicated `mios-builder` Podman machine on Windows hosts (rootful, all cores, all RAM, 250 GB disk)

---

## 4. Software Bill of Materials (SBOM) — RPMs from `usr/share/mios/PACKAGES.md`

`PACKAGES.md` is the **single source of truth** for all RPMs. `automation/lib/packages.sh` parses fenced code blocks tagged `packages-<category>` via:
```bash
sed -n "/^\`\`\`packages-${category}$/,/^\`\`\`$/{/^\`\`\`/d;/^$/d;/^#/d;p}" PACKAGES.md
```

### 4.1 Repository enablement (`packages-repos`)
`rpmfusion-free-release-rawhide`, `rpmfusion-nonfree-release-rawhide`, `fedora-workstation-repositories`, `dnf-plugins-core`, `dnf5-plugins`

### 4.2 Kernel extras (`packages-kernel`)
`kernel-modules-extra`, `kernel-devel`, `kernel-headers`, `kernel-tools`, `glibc-headers`, `glibc-devel`, `python3`

> The base kernel itself is inherited from ucore-hci. Installing `kernel`/`kernel-core` in-container triggers dracut-under-tmpfs and breaks the initramfs — explicitly forbidden.

### 4.3 GNOME 50 desktop (`packages-gnome`) — minimal shell
**Core shell:** `gnome-shell`, `gnome-session-wayland-session`, `gnome-control-center`, `gnome-keyring`, `gdm`
**Desktop apps:** `ptyxis`, `nautilus`, `gnome-software`, `gnome-remote-desktop`, `gnome-backgrounds`
**Extensions:** `gnome-shell-extension-appindicator`, `gnome-shell-extension-dash-to-dock`
**Portals:** `xdg-user-dirs`, `xdg-utils`, `xdg-desktop-portal`, `xdg-desktop-portal-gnome`, `xdg-desktop-portal-gtk`
**Audio:** `pipewire-alsa`, `pipewire-pulseaudio`, `wireplumber`
**GStreamer (mandatory ABI fix):** `gstreamer1`, `gstreamer1-plugins-base`, `gstreamer1-plugins-good`
**Hardware:** `upower`, `gnome-bluetooth`, `bluez`, `bluez-tools`
**Flatpak:** `flatpak`
**FS access:** `gvfs`, `gvfs-smb`, `gvfs-mtp`
**Networking:** `NetworkManager-wifi`, `NetworkManager-openvpn-gnome`, `nm-connection-editor`
**Locale:** `glibc-langpack-en`
**Qt-Adwaita parity:** `qt6-qtbase-gui`, `qt6-qtwayland`, `qadwaitadecorations-qt5`, `adw-gtk3-theme`

> All GNOME Core Apps (`papers`, `loupe`, `gnome-text-editor`, `gnome-disk-utility`, `gnome-system-monitor`, `baobab`, `gnome-tweaks`, etc.) are **commented out by default** in `packages-gnome-core-apps` — Epiphany Flatpak handles documents/photos/media natively.

### 4.4 GPU stacks
- **Mesa (`packages-gpu-mesa`):** `mesa-vulkan-drivers`, `mesa-dri-drivers`, `mesa-va-drivers-freeworld`, `vulkan-loader`, `vulkan-tools`, `libva-utils`, `linux-firmware`
- **AMD ROCm (`packages-gpu-amd-compute`):** `rocm-opencl`, `rocm-hip`, `rocm-runtime`, `rocm-smi`, `rocminfo`
- **Intel Compute (`packages-gpu-intel-compute`):** `intel-compute-runtime`, `intel-media-driver` (`level-zero` and `intel-gpu-tools` removed: not in F44 / missing libproc2.so.0)
- **NVIDIA (`packages-gpu-nvidia`):** `akmod-nvidia`, `xorg-x11-drv-nvidia-cuda`, `nvidia-container-toolkit` (≥1.17.8 for CVE-2025-23266/23267; 1.19+ uses CDI by default), `nvidia-persistenced`, `nvidia-settings`, `xorg-x11-drv-nvidia-power`, `nvidia-container-selinux`

> RTX 50 (Blackwell) specifics: open kernel modules are the **only** option; VFIO reset bug → `vfio_pci.disable_idle_d3=1` karg in `13-rtx50-vfio-workaround.toml`.

### 4.5 Virtualization (`packages-virt`)
`cockpit`, `qemu-kvm`, `libvirt`, `libvirt-daemon`, `virt-install`, `virt-manager`, `edk2-ovmf`, `swtpm`, `swtpm-tools`, `dnsmasq`, `mdevctl`, `libguestfs-tools`, `virt-viewer`, `virt-v2v`, `qemu-device-display-virtio-gpu`, `dracut-live`, `virt-firmware`, `python3-cryptography`

### 4.6 Container runtime (`packages-containers`)
`podman`, `podman-compose`, `buildah`, `skopeo`, `bootc`, `osbuild`, `osbuild-composer`, `osbuild-selinux`, `composer-cli`, `rpm-ostree`, `crun`, `netavark`, `aardvark-dns`, `slirp4netns`, `composefs`, `container-selinux`, `qemu-img`, `image-builder`, `bootc-image-builder`, `dracut-live`, `squashfs-tools`, `selinux-policy-devel`, `containers-common`, `toolbox`, `kubectl`, `helm`, `make`, `gcc`, `gcc-c++`, `cmake`, `golang`, `podman-plugins`, `cosign`

> `podman-docker` removed: conflicts with `moby-engine` from ucore-hci base.

### 4.7 Self-build experimental (`packages-self-build`)
`bootc-base-imagectl` (rechunker), `konflux-image-tools`

### 4.8 Boot & update management (`packages-boot`)
`bootupd`, `dnf5-plugins`, `systemd-boot-unsigned`, `efibootmgr`, `systemd-ukify`, `binutils`, `efitools`, `sbsigntools`, `tpm2-tss`

### 4.9 Cockpit (`packages-cockpit`)
`cockpit`, `cockpit-system`, `cockpit-ws`, `cockpit-bridge`, `cockpit-storaged`, `cockpit-networkmanager`, `cockpit-podman`, `cockpit-machines`, `cockpit-ostree`, `cockpit-selinux`, `cockpit-files`, `pcp`, `pcp-system-tools`

### 4.10 Windows interop & remote desktop (`packages-wintools`)
`hyperv-tools`, `samba`, `samba-client`, `cifs-utils`, `freerdp`, `freerdp-libs`

### 4.11 Security (`packages-security`)
`crowdsec`, `crowdsec-firewall-bouncer-nftables`, `firewalld`, `fapolicyd`, `fapolicyd-selinux`, `usbguard`, `setroubleshoot-server`, `policycoreutils-python-utils`, `audit`, `tpm2-tools`, `clevis`, `clevis-luks`, `aide`, `openscap-scanner`, `scap-security-guide`, `libpwquality`, `nftables`, `policycoreutils`, `setools-console`, `cosign`, `iptables-legacy` (WSL2 has no nftables kernel support; coexists on bare metal)

### 4.12 Gaming (`packages-gaming`)
`steam`, `gamescope`, `gnome-shell-extension-gamemode`, `wine`, `wine-mono`, `wine-dxvk`, `winetricks`, `lutris`, `gamemode`, `mangohud`, `vulkan-tools`, `dosbox-staging`, `protontricks`, `steam-devices`

### 4.13 Guest agents (`packages-guests`)
`qemu-guest-agent`, `hyperv-daemons`, `open-vm-tools`, `spice-vdagent`, `spice-webdavd`, `libvirt-nss`

### 4.14 Storage (`packages-storage`)
`nfs-utils`, `rpcbind`, `glusterfs`, `glusterfs-fuse`, `glusterfs-server`, `ceph-common`, `iscsi-initiator-utils`, `targetcli`, `device-mapper-multipath`, `sg3_utils`, `lvm2`, `stratis-cli`, `stratisd`, `xfsprogs`, `btrfs-progs`, `e2fsprogs`, `mdadm`, `ntfs-3g`

### 4.15 Ceph distributed storage (`packages-ceph`)
`ceph-common`, `cephadm`, `ceph-fuse`, `ceph-selinux`

> All Ceph server daemons (MON/OSD/MGR/MDS) run as Podman containers via cephadm — only the orchestrator binary + clients are baked in.

### 4.16 K3s lightweight Kubernetes (`packages-k3s`)
`container-selinux`

> The K3s binary itself is downloaded directly (not via dnf) by `13-ceph-k3s.sh` from `github.com/k3s-io/k3s/releases/latest`, sha256-verified, and installed to `/usr/local/bin/k3s`. K3s SELinux policy is compiled from source by `19-k3s-selinux.sh` (no Fedora-Rawhide RPM exists).

### 4.17 High Availability (`packages-ha`)
`pacemaker`, `corosync`, `pcs`, `fence-agents-all`, `fence-virt`, `resource-agents`, `sbd`, `booth`, `booth-core`, `booth-test`, `dlm`, `corosync-qdevice`, `corosync-qnetd`, `libqb`, `libibverbs`

### 4.18 CLI utilities (`packages-utils`)
`git`, `tmux`, `vim-enhanced`, `wget2-wget`, `curl`, `btop`, `nvtop`, `fastfetch`, `lm_sensors`, `smartmontools`, `tuned`, `tuned-ppd`, `fuse`, `fuse3`, `7zip-standalone`, `unzip`, `zstd`, `rsync`, `tree`, `jq`, `yq`, `bc`, `patch`, `openssl`, `distrobox`, `just`, `driverctl`, `tmt`, `ansible-core`, `wslu`, `python3-pip`, `cloud-init`, `libei`, `strace`, `lsof`, `iotop`, `socat`, `syft`, `oras-cli`

### 4.19 Android / Waydroid (`packages-android`)
`waydroid` (Mesa/AMD/Intel only; NVIDIA lacks full 3D in Waydroid)

### 4.20 Looking Glass build deps (`packages-looking-glass-build`)
**Removed after compilation** to keep image small:
`cmake`, `gcc`, `gcc-c++`, `make`, `binutils`, `pkgconf-pkg-config`, `libglvnd-devel`, `fontconfig`, `fontconfig-devel`, `spice-protocol`, `nettle-devel`, `gnutls-devel`, `libXi-devel`, `libXinerama-devel`, `libXcursor-devel`, `libXpresent-devel`, `libXScrnSaver-devel`, `libxkbcommon-x11-devel`, `wayland-devel`, `wayland-protocols-devel`, `libdecor-devel`, `pipewire-devel`, `libsamplerate-devel`

### 4.21 Cockpit plugin build deps (`packages-cockpit-plugins-build`)
`npm`, `gettext`

### 4.22 Network discovery / mDNS (`packages-network-discovery`)
`avahi`, `avahi-tools`, `nss-mdns`

### 4.23 Phosh mobile session (`packages-phosh`)
`phosh`, `phoc`, `gnome-calls`, `feedbackd`

### 4.24 Updater stack (`packages-updater`)
`uupd`, `greenboot`, `greenboot-default-health-checks`

### 4.25 FreeIPA & SSSD (`packages-freeipa`)
`freeipa-client`, `sssd`, `sssd-tools`, `libsss_nss_idmap`

### 4.26 AI shell tools (`packages-ai`)
`aichat`, `aichat-ng`

### 4.27 Critical validation set (`packages-critical`)
**Must be present in final image** (post-build validation):
`gnome-shell`, `gdm`, `podman`, `bootc`, `libvirt`, `kernel`, `firewalld`, `cockpit`, `NetworkManager`, `pipewire`, `tuned`, `chrony`, `openssh-server`

### 4.28 Bloat (`packages-bloat`) — actively removed
`malcontent-control`, `malcontent-pam`, `malcontent-tools`, `gnome-tour`, `gnome-initial-setup`, `PackageKit`, `PackageKit-command-not-found`

> **Footgun preserved:** `malcontent-libs` and `malcontent` itself are kept — `gnome-control-center` and `flatpak` link against `libmalcontent-0.so.0`. Calling `dnf remove malcontent` directly cascades to remove `gnome-shell`/`gdm`. Only the listed `*-control`/`*-pam`/`*-tools` are safely removed.

### 4.29 Network UPS Tools (`packages-nut`)
`nut`, `nut-client`, `nut-xml`, `usbutils` — managed via Distrobox (decouple hardware config from immutable core)

---

## 5. From-Source Components

| Component | Built by | Notes |
|---|---|---|
| **Looking Glass B7** client | `automation/53-bake-lookingglass-client.sh` | Compiles from upstream sources using `packages-looking-glass-build` (devel set removed after) |
| **KVMFR kernel module** | `automation/52-bake-kvmfr.sh` | Built from Looking Glass `module/` tree, signed with MOK key from `automation/generate-mok-key.sh`/`enroll-mok.sh`. 128 MB shmem default in `/usr/lib/modprobe.d/kvmfr.conf` |
| **K3s binary** | `automation/13-ceph-k3s.sh` | Pulled from GitHub releases, sha256-verified |
| **K3s SELinux policy** | `automation/19-k3s-selinux.sh` | Compiled from source (no Fedora package) |
| **MiOS SELinux modules** | `automation/37-selinux.sh` | 5 individual `.te` modules: `mios_portabled`, `mios_kvmfr`, `mios_cdi`, `mios_quadlet`, `mios_sysext` |
| **cosign v2.x** | `automation/42-cosign-policy.sh` | Static binary downloaded from sigstore/cosign releases (NOT v3 — v3 breaks rpm-ostree OCI 1.1) |

---

## 6. System Overlay (`usr/lib/`)

### 6.1 Kernel boot args (`usr/lib/bootc/kargs.d/`)

14 TOML files merged at boot. All match `architectures=["x86_64"]`.

| File | Kargs |
|---|---|
| `00-mios.toml` | `iommu=pt amd_iommu=on rd.driver.blacklist=nouveau modprobe.blacklist=nouveau systemd.show-status=true systemd.mount-extra=/var/lib/containers:none:bind,rw,x-systemd.makefs console=tty0 console=ttyS0,115200n8` |
| `01-mios-hardening.toml` | `slab_nomerge randomize_kstack_offset=on pti=on vsyscall=none lockdown=confidentiality spectre_v2=on spectre_bhi=on spec_store_bypass_disable=on l1tf=full,force gather_data_sampling=force tsx=off kvm.nx_huge_pages=force` |
| `01-mios-vfio.toml` | `intel_iommu=on amd_iommu=on iommu=pt rd.driver.pre=vfio-pci vfio-pci.ids= kvm-intel.nested=1` |
| `02-mios-gpu.toml` | `amdgpu.pplib=0 i915.enable_guc=3` |
| `10-mios-console.toml` | `plymouth.enable=0` |
| `10-mios-verbose.toml` | `systemd.show-status=true systemd.log_level=info console=tty0 console=ttyS0,115200n8` |
| `10-nvidia.toml` | `nvidia.NVreg_OpenRmEnableUnsupportedGpus=1 nvidia-drm.modeset=1 nvidia-drm.fbdev=1` |
| `12-intel-xe.toml` | `i915.force_probe=* xe.force_probe=*` |
| `13-rtx50-vfio-workaround.toml` | `vfio_pci.disable_idle_d3=1` |
| `15-rootflags.toml` | `rootflags=discard=async,noatime` |
| `16-nested-virt.toml` | `kvm_intel.nested=1 kvm_intel.ept=1 kvm_intel.enable_shadow_vmcs=1 kvm_amd.nested=1` |
| `20-vfio.toml` | `intel_iommu=on kvm.ignore_msrs=1 vfio_pci.ids=` |
| `30-security.toml` | `slab_nomerge lockdown=integrity` (overrides `01-mios-hardening`'s `confidentiality` so MOK-signed NVIDIA modules can load) |
| `31-secureblue-extended.toml` | `page_poison=1 slub_debug=FZ debugfs=off oops=panic iommu=force iommu.strict=1 iommu.passthrough=0 random.trust_bootloader=off random.trust_cpu=off efi=disable_early_pci_dma itlb_multihit=flush,force tsx_async_abort=full,force mds=full,force` |

### 6.2 Sysctl (`usr/lib/sysctl.d/`)

| File | Highlights |
|---|---|
| `99-mios-hardening.conf` | `kernel.kptr_restrict=2`, `dmesg_restrict=1`, `yama.ptrace_scope=2`, **`unprivileged_userns_clone=1`** (kept ON — rootless Podman/Waydroid/Steam need it), TCP/RP filter hardening, `fs.protected_*` set, `net.core.bpf_jit_harden=2`, `kernel.unprivileged_bpf_disabled=1`, `kernel.sysrq=0`, `kernel.printk=3 3 3 3` |
| `99-mios-vmhost.conf` | `vm.swappiness=10`, `overcommit_memory=1`, `dirty_ratio=20`, IP forwarding on, bridge nf-call on, large inotify watches |
| `90-mios-le9uo.conf` | le9uo + BORE scheduler tuning: `watermark_scale_factor=200`, `min_free_kbytes=1048576`, BORE-friendly sched_* values |
| `90-mios-overlayfs.conf` | OverlayFS / sysext + container neighbor table (`gc_thresh3=4096`) |

### 6.3 Modprobe (`usr/lib/modprobe.d/`)

- `blacklist-nouveau.conf` — blacklist nouveau, `modeset=0`
- `blacklist-vmw_vsock.conf` — `vmw_vsock_vmci_transport`
- `kvmfr.conf` — `options kvmfr static_size_mb=128`
- `mios-nvidia-blacklist.conf` — nvidia blacklisted by default; `mios-gpu-detect.service` removes this file at first boot **only if** an NVIDIA GPU is actually present (so VMs without NVIDIA passthrough don't load the driver and conflict with hyperv_drm/virtio-gpu)
- `nvidia-open.conf` — `NVreg_OpenRmEnableUnsupportedGpus=1`, `NVreg_UseKernelSuspendNotifiers=1` (driver 595+), `NVreg_PreserveVideoMemoryAllocations=1`, `nvidia_drm modeset=1 fbdev=1`
- `nvidia.conf` — `NVreg_EnableGpuFirmware=1`, `NVreg_PreserveVideoMemoryAllocations=1`

### 6.4 Modules-load (`usr/lib/modules-load.d/`)

- `mios-vfio.conf`: `vfio`, `vfio_iommu_type1`, `vfio-pci` (note: kvmfr is **not** autoloaded — users `modprobe kvmfr` only when running Looking Glass, to avoid wasted shmem reservation)
- `mios.conf`: `ntsync`, `hv_sock`, `ceph`, `rbd`

### 6.5 Tmpfiles (`usr/lib/tmpfiles.d/`)

Every `/var` directory used by MiOS is declared here (NO-MKDIR-IN-VAR Law). 16 drop-ins covering: backups, ceph, cpu cgroups, crowdsec, freeipa/SSSD/certmonger/ipa-client, GPU runtime + CDI, GNOME Remote Desktop, infrastructure (cockpit/libvirt/k3s/ceph/journal), iommu, MiOS general (`/etc/mios`, `/var/lib/mios`, `/var/log/mios`, `/var/lib/mios/mcp`), nfs, pxe, virtio, WSL2 hacks.

### 6.6 Sysusers (`usr/lib/sysusers.d/`)

- `mios.conf`: groups `kvm 36`, `video 39`, `render 105` (pinned, soft-static upstream), `libvirt`, `input`, `dialout`, `docker`; user `mios` with all those + `wheel`
- `mios-ai.conf`: `mios-ai` user (nologin shell, `/var/lib/mios/ai` home), in `video`+`render`
- `mios-virt.conf` / `50-mios.conf`: `mios-virt` (UID 800, system service; pinned 800-899)
- `20-podman-machine.conf`: `core` user with mios-equivalent groups (Podman-machine compat)

### 6.7 Dracut (`usr/lib/dracut/conf.d/`)

5 drop-ins: `10-mios-generic.conf`, `50-mios-hyperv.conf`, `51-mios-virtio.conf`, `52-mios-nvidia-exclude.conf`, `90-mios-verify.conf`

---

## 7. Quadlet Sidecars (`etc/containers/systemd/`)

The four files become four `*.service` units at boot via the systemd Quadlet generator. All run as unprivileged users with `Delegate=yes` (UNPRIVILEGED-QUADLETS Law).

### 7.1 `mios.network`
`Subnet=10.89.0.0/24`, `Gateway=10.89.0.1`, `Label=io.mios.network=core`

### 7.2 `mios-ai.container` — OpenAI-compatible inference
- Image: `docker.io/localai/localai:v2.20.0`
- Port: `8080:8080`
- Volumes: `/srv/ai/models`, `/srv/ai/mcp`, `/etc/mios/ai` (ro)
- Env: `MODELS_PATH=/build/models`, `THREADS=4`, `CONTEXT_SIZE=4096`
- User/Group: `mios-ai` / `mios-ai`
- Restart: on-failure, RestartSec 10s, TimeoutStartSec 900s

### 7.3 `mios-ceph.container` — Ceph monitor
- Image: `quay.io/ceph/ceph:latest`, `Exec=mon`
- Network: `mios.network`
- Volumes: `/var/lib/ceph`, `/etc/ceph`

### 7.4 `mios-k3s.container` — Rootless K3s (Quadlet variant)
- Image: `docker.io/rancher/k3s:v1.32.1-k3s1`, `Exec=server --disable=traefik`
- Privileged: `true`, `K3S_TOKEN=mios-cluster-secret`
- Volumes: `/var/lib/rancher/k3s`, `/usr/share/mios/k3s-manifests` (ro)

> All four `*.container` images are LBI candidates — symlinked into `/usr/lib/bootc/bound-images.d/` for offline pre-pull (BOUND-IMAGES Law). Note: build-time pre-pull is currently disabled in the Containerfile; at-boot pull via Quadlet `AutoUpdate=registry` is the operative path.

---

## 8. Systemd Services & Targets (`usr/lib/systemd/system/`)

70+ MiOS unit files and drop-ins. Major groupings:

### 8.1 Targets (multi-stage boot composition)
- `mios-firstboot.target` — first-boot orchestration
- `mios-desktop.target` — desktop role
- `mios-headless.target` — server role
- `mios-hybrid.target` — both
- `mios-ha-node.target` — HA cluster node
- `mios-k3s-master.target` / `mios-k3s-worker.target` — K3s cluster role

### 8.2 First-boot services
`mios-role.service` (selects target), `mios-gpu-detect.service`, `mios-cdi-detect.service`, `mios-nvidia-cdi.service`, `mios-libvirtd-setup.service`, `mios-ceph-bootstrap.service`, `mios-k3s-init.service`, `mios-ha-bootstrap.service`, `mios-flatpak-install.service`, `mios-freeipa-enroll.service`, `mios-grd-setup.service`, `mios-cpu-isolate.service`, `mios-selinux-init.service`, `mios-sriov-init.service`

### 8.3 Recurring / utility
- `mios-podman-gc.service` + `mios-podman-gc.timer`
- `mios-mcp.service` (MCP server)
- `mios-verify.service` / `mios-verify-root.service`
- `mios-boot-diag.service`
- `mios-copy-build-log.service`
- `mios-gpu-status.service`, `mios-gpu-{nvidia,amd,intel}.service`, `mios-gpu-pv-detect.service`
- `mios-kvmfr-load.service`
- `mios-hyperv-enhanced.service`
- `mios-waydroid-init.service`
- `mios-wsl-init.service` / `mios-wsl-firstboot.service`
- `dbus-daemon-wsl.service`

### 8.4 Drop-ins (override base behavior)
40+ `.service.d/` directories adding `ConditionVirtualization=` gating, ordering fixes, capability bounds, etc. Notable: `gdm.service.d/`, `libvirtd.service.d/`, `firewalld.service.d/`, `crowdsec.service.d/`, `fapolicyd.service.d/`, `pacemaker.service.d/`, `dbus-broker.service.d/`, `polkit.service.d/`, `systemd-resolved.service.d/`, `tuned.service.d/`, `usbguard.service.d/`, `nvidia-cdi-refresh.service.d/`, `osbuild-composer.service.d/`, `chronyd.service.d/`, `auditd.service.d/`, `multipathd.service.d/`, `nfs-server.service.d/`, `cockpit.socket.d/`

### 8.5 Mount units
`var-home.mount`, `var-lib-containers.mount`

---

## 9. Greenboot Health Checks (`usr/lib/greenboot/`)

Configuration: `MAX_BOOT_ATTEMPTS=3`, watchdog enabled, 1-hour grace period. Greenboot-rs (Rust rewrite, F43+ default).

### 9.1 Required (must pass — failure triggers `bootc rollback`)
1. `10-mios-role.sh` — `mios-role.service` is active and `/var/lib/mios/role.active` exists
2. `15-composefs-verity.sh` — composefs is mounted as root (if `enabled = verity` is set), fsverity active on `/usr/bin/bash`
3. `20-podman.sh` — `podman.socket` is active
4. `30-network.sh` — DNS resolves `ghcr.io` within 30s (uses `systemd-resolve`, not curl/wget)

### 9.2 Wanted (logged but non-fatal)
1. `30-nvidia-cdi.sh` — NVIDIA CDI generation succeeded
2. `40-role-target.sh` — selected role target reached
3. `50-mios-ha-cluster.sh` — pacemaker/corosync healthy
4. `60-k3s.sh` — K3s cluster reachable

### 9.3 Fail handler
`fail.d/00-log-fail.sh` — captures journal & system state before rollback.

---

## 10. Security Stack — Layers

### 10.1 Kernel-level
- 14 kargs.d TOML files (see §6.1) — slab/heap, KASLR, lockdown=integrity (with confidentiality intent overridden so MOK-enrolled modules load), Spectre/Meltdown/L1TF/MDS/TSX mitigations, IOMMU forced, EFI early DMA disabled, randomness anti-trust on bootloader/CPU
- 4 sysctl.d drop-ins (see §6.2) — kptr_restrict, dmesg_restrict, ptrace yama=2, BPF JIT harden, unprivileged BPF disabled, SysRq off, fs protections, TCP/RP hardening
- Modprobe blacklists (nouveau, vmw_vsock)

### 10.2 SELinux (enforcing mode)
- 5 custom MiOS modules: `mios_portabled` (systemd-portabled D-Bus), `mios_kvmfr` (Looking Glass shmem), `mios_cdi` (NVIDIA CDI fcontext), `mios_quadlet` (Podman Quadlet container management), `mios_sysext` (systemd-sysext activation)
- Booleans: `container_use_cephfs=on`, `virt_use_samba=on`
- fcontext: `/var/home(/.*)?` → `user_home_dir_t`
- k3s SELinux compiled from source

### 10.3 Application whitelisting — fapolicyd
- `/usr/lib/fapolicyd/fapolicyd.conf`: `permissive=0`, `trust=file,rpmdb`, `rpmdb_path=/usr/share/rpm` (bootc-correct), `filter_default=0`, watch ext{2,3,4}/tmpfs/xfs/vfat/iso9660/btrfs/overlay
- Custom rules:
  - `70-bootc-ostree.rules` — ostree path trust
  - `90-mios-deny.rules` — **zero-trust** deny on `/var/home/`, `/home/`, `/run/media/`, `/mnt/` for any executable not RPM-trusted

### 10.4 Network IDS — CrowdSec (sovereign / offline)
- Acquisition: `/usr/lib/crowdsec/acquis.d/journalctl.yaml` (journald source)
- Bouncer: `crowdsec-firewall-bouncer-nftables` integrates with firewalld
- No data sent to CrowdSec cloud; local sqlite at `/var/lib/crowdsec`

### 10.5 USB device control — USBGuard
- Default: block unauthorized USB; admin generates initial policy on first boot via `usbguard generate-policy > /etc/usbguard/rules.conf`

### 10.6 Firewalld
- Default zone: `drop`
- Allowed: SSH 22/tcp, Cockpit 9090/tcp, libvirt bridge, CrowdSec bouncer (nftables)

### 10.7 Audit & compliance
- `audit`, `aide` (file integrity), `openscap-scanner` + `scap-security-guide` (compliance), `setroubleshoot-server`, `setools-console`

### 10.8 Composefs verified boot
`/usr/lib/ostree/prepare-root.conf`:
```toml
[composefs]
enabled = true

[etc]
transient = true

[root]
transient-ro = true
```

### 10.9 TPM2 / LUKS automation
`tpm2-tools`, `clevis`, `clevis-luks` — automated LUKS unlock via TPM2/Tang.

### 10.10 Image signing — see §2.5

---

## 11. AI / Agent Surface

MiOS is **OpenAI-API native**. All agents target `http://localhost:8080/v1`.

### 11.1 Endpoints
| Path | Method | Backed by |
|---|---|---|
| `/v1/chat/completions` | POST | LocalAI Quadlet sidecar |
| `/v1/models` | GET | `/usr/share/mios/ai/v1/models.json` |
| `/v1/embeddings` | POST | LocalAI |
| `/v1/mcp` | FS | `/usr/share/mios/ai/v1/mcp.json` |

### 11.2 Manifest files
- `models.json` — declares the `mi-os-7b` model
- `context.json` — project metadata, endpoints
- `mcp.json` — MCP server registration: `mios-system → /usr/bin/mios-status --mcp-mode`
- `system.md` — full agent identity (deployed copy of `system-prompt.md`)
- `knowledge.md` — local knowledge index

### 11.3 CLI client
`/usr/bin/mios` (Python, 49 lines) — reads `system.md`, sends POST to local `/v1/chat/completions` with `model=mi-os-7b`, prints the response. Replaceable; client is intentionally thin.

### 11.4 Inference backend
LocalAI v2.20.0 in Quadlet sidecar. Models live in `/srv/ai/models`. MCP servers in `/srv/ai/mcp`. Per-host system prompt at `/etc/mios/ai/system-prompt.md` (deployed by bootstrap from the bootstrap repo's `system-prompt.md`).

---

## 12. Build Modes (5)

Per `SELF-BUILD.md`:

| Mode | Trigger | Driver |
|---|---|---|
| **0 — Bootstrap** | `curl ... | sudo bash` (mios-bootstrap `install.sh`) | Installs prereqs, clones MiOS, applies FHS overlay, registers `mios` CLI |
| **1 — CI/CD** | Push to `main` or weekly schedule | `.github/workflows/mios-ci.yml` builds → cosigns → pushes to GHCR |
| **2 — Windows local** | `mios-build-local.ps1` | 5-phase orchestrator: prereq check → Podman machine → build (with `MIOS_USER`/`MIOS_PASSWORD_HASH`/`MIOS_HOSTNAME`/`MIOS_FLATPAKS` build-args) → rechunk → BIB target generation (RAW/VHDX/WSL/ISO) → optional GHCR push |
| **3 — Linux local** | `just build` / `just iso` / `just all` | Justfile targets, BIB via `quay.io/centos-bootc/bootc-image-builder:latest` |
| **4 — Self-build** | Running MiOS host runs `podman build` | Uses local MiOS image as helper for hash gen, qemu-img conversion, BIB |

### 12.1 Output targets

| Target | Path | Format | Builder |
|---|---|---|---|
| OCI image | `localhost/mios:latest` → `ghcr.io/mios-dev/mios:VERSION` | OCI v1 | `podman build` |
| RAW disk | `~/Documents/MiOS/images/mios-bootable.raw` | 80 GiB ext4 | BIB `--type raw` |
| VHDX | `~/Documents/MiOS/deployments/mios-hyperv.vhdx` | Hyper-V Gen2 | BIB `--type vhd` → `qemu-img convert -m 16 -W -f vpc -O vhdx` |
| WSL2 tarball | `~/Documents/MiOS/deployments/mios-wsl.tar` | WSL2 import | `bootc container export` (preferred) or `podman export` (fallback) |
| ISO | `~/Documents/MiOS/images/mios-installer.iso` | Anaconda installer | BIB `--type anaconda-iso` with `iso.toml` (kickstart inj) |
| SBOM | `artifacts/sbom/mios-sbom.json` | CycloneDX | `anchore/syft scan` |

### 12.2 Rechunking
After build, `bootc-base-imagectl rechunk --max-layers 67` produces 5–10× smaller Day-2 deltas. The rechunker tool is preferentially the freshly-built MiOS image itself (self-build); falls back to `quay.io/centos-bootc/centos-bootc:stream10` if needed.

---

## 13. CI/CD (`.github/workflows/mios-ci.yml`)

```
build (ubuntu-24.04)
├── checkout
├── setup-qemu
├── setup-buildx
├── login to ghcr.io (GITHUB_TOKEN)
├── compute tags (latest, v0.2.0, branch, PR, semver)
├── docker/build-push-action@v6 (provenance: true, sbom: true)
├── install cosign (sigstore/cosign-installer@v3)
└── cosign keyless sign (COSIGN_EXPERIMENTAL=1, OIDC)

smoke-test (PR-only, ubuntu-24.04)
└── podman build (best-effort, non-fatal)
```

Permissions: `contents:read`, `packages:write`, `id-token:write` (OIDC for cosign).

---

## 14. Architectural Laws (from `INDEX.md`)

These laws are **absolute**. Violating them causes state drift, build failure, or both.

1. **USR-OVER-ETC** — Never write static config to `/etc` at build time. Use `/usr/lib/<component>.d/`. `/etc/` is for admin overrides only.
2. **NO-MKDIR-IN-VAR** — Declare all `/var` dirs via `tmpfiles.d`. Build-time `/var` overlays are architectural violations.
3. **BOUND-IMAGES** — All primary Quadlet sidecar containers must be symlinked into `/usr/lib/bootc/bound-images.d/`.
4. **BOOTC-CONTAINER-LINT** — `RUN bootc container lint` must be the final instruction in every Containerfile.
5. **UNIFIED-AI-REDIRECTS** — Use agnostic env vars (`MIOS_AI_KEY`, `MIOS_AI_MODEL`) targeting `http://localhost:8080/v1`. No vendor-specific defaults.
6. **UNPRIVILEGED-QUADLETS** — All AI/Worker Quadlets must define unprivileged `User=`/`Group=` and `Delegate=yes` in `[Service]`.

---

## 15. Known Issues, Footguns, Hard-Won Lessons

### 15.1 dnf5 vs dnf4 option names
`install_weak_deps=False` (underscore, dnf5) vs `install_weakdeps=False` (no underscore, dnf4). dnf5 silently ignores the dnf4 form. Globally set in `/usr/lib/dnf/dnf.conf` by `01-repos.sh`.

### 15.2 Filesystem `%posttrans` lua scriptlet
F44 `filesystem` package's lua scriptlet fails in containerized builds. **Two-phase distro-sync** in `01-repos.sh` upgrades dnf/rpm/filesystem/systemd/glibc/dbus-broker FIRST in isolation, then runs the full userspace upgrade. Without this, a single scriptlet failure aborted 1162-package transactions and left F43 core libs with F44 desktop packages — a broken ABI.

### 15.3 ucore-hci NVIDIA already signed
**Never** install `akmod-nvidia` on ucore-hci:stable-nvidia — it ships pre-signed `kmod-nvidia-open` matched to its kernel and ublue MOK. `36-akmod-guards.sh` enforces this.

### 15.4 malcontent dependency trap
- Safe to remove: `malcontent-control`, `malcontent-pam`, `malcontent-tools`
- **Must keep:** `malcontent`, `malcontent-libs` (gnome-control-center + flatpak link against `libmalcontent-0.so.0`)
- **Never** `dnf remove malcontent` — cascades to remove `gnome-shell`/`gdm`

### 15.5 GTK4 / libadwaita theming
Never set `GTK_THEME=Adwaita-dark` (breaks libadwaita GTK4 apps). Use `ADW_DEBUG_COLOR_SCHEME=prefer-dark` + `color-scheme='prefer-dark'` via dconf. Under Hyper-V/llvmpipe rendering, also set `GSK_RENDERER=cairo` and `GDK_DISABLE=vulkan`.

### 15.6 Bash arithmetic under `set -euo pipefail`
`((VAR++))` exits 1 when `VAR` is 0 — kills the script. **Always** use `VAR=$((VAR + 1))`.

### 15.7 BIB config format
- TOML config → mount as `/config.toml`
- JSON config → mount as `/config.json`
- BIB selects parser by file extension; mounting as the wrong name crashes with `found config.json and also config.toml`

### 15.8 BIB `--squash-all` strips OCI metadata
`--squash-all` strips `ostree.final-diffid` metadata required by bootc-image-builder. **Never** use it with BIB targets.

### 15.9 SELinux fapolicyd type
Use `xdm_var_run_t`, **not** `xdm_t`.

### 15.10 cosign v3 incompatible with rpm-ostree
`cosign` is pinned to v2.x in `42-cosign-policy.sh`. v3 produces OCI 1.1 bundle format that rpm-ostree can't consume.

### 15.11 WSL2 specifics
- WSL2 kernel has no nftables → `iptables-legacy` package required (coexists with nftables on bare metal)
- `wsl --list` returns UTF-16 output that breaks PowerShell `-match` — workaround: unconditionally `wsl --unregister` and suppress errors
- `dbus-daemon-wsl.service` and `mios-wsl-firstboot.service` handle WSL-specific init quirks
- Service gating via `ConditionVirtualization=!wsl` (native systemd v252+)

### 15.12 RTX 50 (Blackwell) VFIO reset bug
Kernel arg `vfio_pci.disable_idle_d3=1` in `13-rtx50-vfio-workaround.toml`. Documented in `/usr/share/doc/mios-vfio-warning.txt` per PACKAGES.md note.

### 15.13 SELinux policy version mismatch
F44 modules compiled for policy version 24, base supports 4-23. Produces `semodule: Failed!` warnings throughout build for `chcon_t`, `fapolicyd_t` (×2), `systemd_portabled_t`. **Non-fatal** — these four policy types remain skipped.

### 15.14 NVIDIA Container Toolkit CVE
Required version: `nvidia-container-toolkit ≥ v1.17.8` (CVE-2025-23266 / 23267). 1.19+ uses CDI by default. Pinned implicitly via Fedora repos.

### 15.15 Disabled in-Containerfile LBI pre-pull
The `podman pull docker.io/postgres:15 || true` style pre-pulls in the Containerfile are **commented out** because nested podman-pull requires `--privileged` BuildKit, which `docker/build-push-action@v6` does not grant on `ubuntu-24.04` GitHub runners. Migration path: enable LBI via Quadlet `AutoUpdate=registry` at first boot, or move pre-pulls to a self-hosted runner.

---

## 16. Proprietary Component Licenses (from `LICENSES.md`)

By using MiOS, the user accepts:

| Component | License | Notes |
|---|---|---|
| NVIDIA GPU Driver (590+) | NVIDIA Software License | `akmod-nvidia` (MiOS-1) or pre-signed by ublue (MiOS-2) |
| NVIDIA Container Toolkit | Apache-2.0 | Open source; CDI specs |
| NVIDIA Persistenced | NVIDIA License | GPU low-latency state |
| Steam | Steam Subscriber Agreement | User must accept SSA on first launch |
| Wine / DXVK | LGPL-2.1 | Open source compat layer |
| VirtIO-Win ISO | Red Hat License | Windows guest drivers; downloaded at build time |
| Geist Font | OFL-1.1 | Vercel monospace/sans |

OSS major components (full list in `LICENSES.md`): Linux kernel (GPL-2.0), systemd (LGPL-2.1), GNOME (GPL-2.0+/LGPL-2.1+), Mesa (MIT), Podman/Buildah/Skopeo (Apache-2.0), bootc (Apache-2.0), K3s (Apache-2.0), Pacemaker/Corosync (GPL-2.0), CrowdSec (MIT), Looking Glass (GPL-2.0), Waydroid (GPL-3.0), Gamescope (BSD-2-Clause), Ceph (LGPL-2.1/3.0), Flatpak (LGPL-2.1), Cockpit (LGPL-2.1), ROCm (MIT/Various), fapolicyd (GPL-3.0), USBGuard (GPL-2.0).

Firmware blobs: `linux-firmware` and `microcode_ctl` under various redistribution licenses, see `/usr/share/licenses/linux-firmware/` on a running system.

---

## 17. Per-Build SBOM Generation

Every CI build generates **SPDX and CycloneDX** SBOMs:
- Built-in: `docker/build-push-action@v6` with `sbom: true` → BuildKit SBOM
- Independent: `automation/90-generate-sbom.sh` runs syft if available
- Manual: `just sbom` → `anchore/syft:latest scan` to `artifacts/sbom/mios-sbom.json` (CycloneDX)
- SBOMs are attached to OCI image via cosign and available as GitHub Actions artifacts

---

## 18. Variable Conventions (`mios-bootstrap/.env.mios`)

User-runtime defaults sourced as fallback when `/etc/mios/install.env` and `~/.config/mios/env` don't override:

```bash
MIOS_DEFAULT_USER="mios"
MIOS_DEFAULT_HOST="mios"
MIOS_AI_ENDPOINT="http://localhost:8080/v1"
MIOS_AI_MODEL="default"
MIOS_FLATPAKS="org.gnome.Epiphany,com.github.tchx84.Flatseal,io.github.kolunmi.Bazaar,com.mattjakeman.ExtensionManager"
MIOS_REPO_URL="https://github.com/mios-dev/mios"
MIOS_BOOTSTRAP_REPO_URL="https://github.com/mios-dev/mios-bootstrap"
MIOS_IMAGE_NAME="ghcr.io/mios-dev/mios"
MIOS_IMAGE_TAG="latest"
MIOS_BRANCH="main"
```

Build-args injected by `mios-build-local.ps1` via `--build-arg`:
- `MAKEFLAGS="-j$cpu"`
- `MIOS_USER` (default `mios`)
- `MIOS_PASSWORD_HASH` (SHA-512 crypt; **plaintext never in build log/image metadata**)
- `MIOS_HOSTNAME`
- `MIOS_FLATPAKS`
- `BASE_IMAGE` (override for ucore-hci alternates)

---

## 19. Hardware Targeting

Per `ARCHITECTURE.md` and per memory:
- Reference platform: AMD Ryzen 9 9950X3D + NVIDIA RTX 4090
- Primary GPU IDs in passthrough config: `10de:2204,10de:1aef`
- CPU pinning: X3D / hybrid-core shielding via `mios-cpu-isolate.service`
- Scheduler: BORE (Burst-Oriented Response Enhancer) — sysctl tuning in `90-mios-le9uo.conf`
- Tickrate: 1000 Hz
- Memory: zram (zstd-compressed) with le9uo anti-thrashing patches
- I/O: BFQ for slow disks, Kyber for NVMe

---

## 20. Quick-Reference Cheatsheet

```bash
# ── Build (Linux) ──
just preflight            # System prereqs check
just build                # OCI image
just rechunk              # Rechunk for 5-10x smaller deltas
just raw                  # 80 GiB RAW disk image via BIB
just iso                  # Anaconda installer ISO
just sbom                 # CycloneDX SBOM
just all                  # Full pipeline

# ── Build (Windows) ──
.\preflight.ps1           # Prereq check (WSL2, Hyper-V, Podman, PS7)
.\mios-build-local.ps1    # 5-phase orchestrator with workflow menu

# ── Install (end user, on target Fedora host) ──
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/install.sh)"

# ── Day-2 (on a deployed MiOS host) ──
sudo bootc upgrade                          # Pull + stage next image
sudo systemctl reboot                       # Activate
sudo bootc switch ghcr.io/mios-dev/mios:vX  # Move to a different tag
sudo bootc rollback                         # Undo most recent upgrade
mios <prompt>                                # OpenAI chat against local LocalAI

# ── Verify image signature ──
cosign verify \
  --certificate-identity-regexp="https://github.com/MiOS-DEV/MiOS-bootstrap" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/mios-dev/mios:latest

# ── SBOM extraction (deployed host) ──
syft scan ghcr.io/mios-dev/mios:latest -o spdx-json
syft scan ghcr.io/mios-dev/mios:latest -o cyclonedx-json
```

---

## Appendix A — Filesystem Layout (FHS 3.0 + bootc)

| Path | Type | Persistence | Owner |
|---|---|---|---|
| `/usr` | composefs | immutable, content-addressed dedup | image |
| `/etc` | overlay (transient by composefs config) | persistent (admin overrides only) | host |
| `/var` | ext4/btrfs | persistent (declared via tmpfiles.d) | host |
| `/home` | symlink | → `/var/home` | host |
| `/usr/lib/bootc/kargs.d/` | composefs | immutable | image |
| `/usr/lib/bootc/install/` | composefs | immutable | image |
| `/usr/lib/bootc/bound-images.d/` | composefs | immutable | image |
| `/usr/share/mios/` | composefs | immutable | image |
| `/etc/mios/` | overlay | persistent (install profile) | host |
| `/etc/mios/install.env` | file (0640) | persistent | bootstrap-installer |
| `/etc/mios/ai/system-prompt.md` | file | persistent (per-host AI behavior) | bootstrap |
| `/var/lib/mios/` | dir | persistent (state, role markers) | tmpfiles |
| `/var/log/mios/` | dir | persistent (build log archive) | tmpfiles |
| `/usr/lib/mios/logs/` | composefs | immutable (snapshot of build log) | build |
| `/run/mios/` | tmpfs | volatile | tmpfiles |

---

## Appendix B — Reconciliation with prior project memory

The following items in user memory are **stale** as of `mios@v0.2.0`:

| Memory says | Actual repo state |
|---|---|
| GitHub: `Kabuki94/CloudWS-bootc` | `mios-dev/mios` + `mios-dev/mios-bootstrap` |
| Local clone path `C:\Users\Administrator\Documents\GitHub\CloudWS-bootc` | Stale; new clones use the mios-dev URLs |
| Two image variants MiOS-1 (Fedora rawhide bootc) and MiOS-2 (ucore-hci) | Single canonical image now: ucore-hci:stable-nvidia base + F44 overlay |
| Image tag `ghcr.io/kabuki94/cloudws-bootc:latest` | `ghcr.io/mios-dev/mios:latest` |
| `cloud-ws.ps1` orchestrator | Replaced by `mios-build-local.ps1` |
| Renamed-files-only PowerShell heredoc phase | Long superseded; current arch is the numbered `automation/` pipeline |
| `Containerfile` "two-stage OCI build" | Still accurate (✅) |
| `PACKAGES.md` as SSOT | Still accurate (✅), now lives at `usr/share/mios/PACKAGES.md` (FHS-correct) |
| `system_files/` overlay | Replaced by rootfs-native `usr/`, `etc/`, `var/`, `home/`, `srv/` directories at repo root (v0.2.0 architecture) |
| `Justfile` for Linux-native builds | Still accurate (✅) |

The accurate items in memory (build-up principles, kernel-not-upgraded-in-container, dnf5 install_weak_deps spelling, malcontent trap, BIB config format, BORE+1000Hz+le9uo, ucore-hci pre-signed NVIDIA, etc.) all remain correct.

---

*End of MiOS-Engineering-Reference. This document is the consolidated SBOM and engineering reference; for live updates, always cross-check `usr/share/mios/PACKAGES.md` and `INDEX.md` in the system repo.*
