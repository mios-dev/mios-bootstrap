<!-- [NET] MiOS Artifact | Proprietor: MiOS-DEV | https://github.com/Kabuki94/MiOS-bootstrap -->
# [NET] MiOS
```json:knowledge
{
  "summary": "> **Proprietor:** MiOS-DEV",
  "logic_type": "documentation",
  "tags": [
    "MiOS",
    "root"
  ],
  "relations": {
    "depends_on": [
      ".env.mios"
    ],
    "impacts": []
  }
}
```
> **Proprietor:** MiOS-DEV
> **Infrastructure:** Self-Building Infrastructure (Personal Property)
> **License:** Licensed as personal property to MiOS-DEV
---
# Component Licenses

MiOS includes software under various open-source and proprietary licenses. By using MiOS, you acknowledge and accept the license terms of all included components.

## Proprietary Components

These components are included in the MiOS image and are governed by their respective proprietary licenses. By booting and using MiOS, you agree to these terms.

| Component | License | Notes |
|-----------|---------|-------|
| NVIDIA GPU Driver (590+) | [NVIDIA Software License](https://www.nvidia.com/en-us/drivers/nvidia-license/) | Installed via akmod-nvidia (MiOS-1) or pre-signed by ublue (MiOS-2). Required for NVIDIA GPUs. |
| NVIDIA Container Toolkit | [Apache 2.0](https://github.com/NVIDIA/nvidia-container-toolkit/blob/main/LICENSE) | Open source. CDI specs for Podman GPU access. |
| NVIDIA Persistenced | [NVIDIA License](https://www.nvidia.com/en-us/drivers/nvidia-license/) | Keeps GPU initialized for low-latency access. |
| Steam | [Steam Subscriber Agreement](https://store.steampowered.com/subscriber_agreement/) | User must accept SSA on first launch. |
| Wine / DXVK | LGPL 2.1 | Open source. Windows compatibility layer. |
| VirtIO-Win ISO | [Red Hat License](https://github.com/virtio-win/virtio-win-pkg-automation/blob/master/LICENSE) | Windows guest drivers for KVM. Downloaded at build time. |
| Geist Font | [OFL 1.1](https://github.com/vercel/geist-font/blob/main/LICENSE.TXT) | Open source. Vercel's monospace/sans font. |

## Open-Source Licenses (Major Components)

| Component | License |
|-----------|---------|
| Linux Kernel | GPL 2.0 |
| systemd | LGPL 2.1 |
| GNOME (Mutter, GTK, libadwaita) | GPL 2.0+ / LGPL 2.1+ |
| Mesa | MIT |
| Podman / Buildah / Skopeo | Apache 2.0 |
| bootc | Apache 2.0 |
| K3s | Apache 2.0 |
| Pacemaker / Corosync | GPL 2.0 |
| CrowdSec | MIT |
| Looking Glass | GPL 2.0 |
| Waydroid | GPL 3.0 |
| Gamescope | BSD 2-Clause |
| Ceph | LGPL 2.1 / 3.0 |
| Flatpak | LGPL 2.1 |
| Cockpit | LGPL 2.1 |
| ROCm | MIT / Various |
| fapolicyd | GPL 3.0 |
| USBGuard | GPL 2.0 |

## Firmware

`linux-firmware` and `microcode_ctl` include binary firmware blobs under various redistribution licenses. These are required for hardware functionality (Wi-Fi, Bluetooth, GPU initialization). See `/usr/share/licenses/linux-firmware/` on a running system for individual firmware licenses.

## Your Responsibilities

- **Steam**: You must create a Steam account and accept the Steam Subscriber Agreement to use Steam.
- **NVIDIA**: The NVIDIA driver is included for hardware compatibility. No additional acceptance is required beyond using the system.
- **Flatpak apps**: Applications installed via Flatpak have their own licenses. Check each app's metadata on Flathub.
- **VM guests**: Windows VMs require valid Windows licenses. MiOS provides the virtualization infrastructure only.

## SBOM

Each CI build generates an SPDX and CycloneDX Software Bill of Materials listing every package and its license. SBOMs are attached to the OCI image via cosign and available as GitHub Actions artifacts.

---
###  Bootc Ecosystem & Resources
- **Core:** [containers/bootc](https://github.com/containers/bootc) | [bootc-image-builder](https://github.com/osautomation/bootc-image-builder) | [bootc.pages.dev](https://bootc.pages.dev/)
- **Upstream:** [Fedora Bootc](https://github.com/fedora-cloud/fedora-bootc) | [CentOS Bootc](https://gitlab.com/CentOS/bootc) | [ublue-os/main](https://github.com/ublue-os/main)
- **Tools:** [uupd](https://github.com/ublue-os/uupd) | [rechunk](https://github.com/hhd-dev/rechunk) | [cosign](https://github.com/sigstore/cosign)
- **Project Repository:** [Kabuki94/MiOS-bootstrap](https://github.com/Kabuki94/MiOS-bootstrap)
- **Sole Proprietor:** MiOS-DEV
---
<!--  MiOS Proprietary Artifact | Copyright (c) 2026 MiOS-DEV -->
