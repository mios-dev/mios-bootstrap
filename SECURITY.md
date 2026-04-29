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
# Security Hardening Checklist

MiOS ships with defense-in-depth security hardening enabled by default, adapted from SecureBlue's audit framework and Fedora's security guidelines. This document details every hardening measure, its rationale, and how to override it if your workload requires it.

## Kernel Boot Parameters

Shipped via `/usr/lib/bootc/kargs.d/00-mios.toml`  no bootloader modification needed. These are applied by bootc at boot time.

| Parameter | Purpose | Override |
|-----------|---------|----------|
| `slab_nomerge` | Prevent slab cache merging (heap isolation) | Remove from kargs.d TOML |
| `init_on_alloc=1` | Zero memory on allocation | Set `=0` to disable |
| `init_on_free=1` | Zero memory on deallocation | Set `=0` to disable |
| `page_alloc.shuffle=1` | Randomize page allocator freelists | Set `=0` to disable |
| `randomize_kstack_offset=on` | Randomize kernel stack offsets per syscall | Set `=off` to disable |
| `pti=on` | Page Table Isolation (Meltdown mitigation) | Set `=off` (not recommended) |
| `vsyscall=none` | Disable legacy vsyscall table | Set `=emulate` for legacy apps |
| `iommu=pt` | IOMMU passthrough for VFIO | Required for GPU passthrough |
| `amd_iommu=on` / `intel_iommu=on` | Enable IOMMU | Required for VFIO |
| `nvidia-drm.modeset=1` | NVIDIA DRM modesetting for Wayland | Required for GNOME Wayland |
| `lockdown=confidentiality` | Kernel lockdown mode (v2.1+) | Remove to allow unsigned modules |
| `spectre_v2=on` | Spectre v2 mitigation (v2.1+) | Performance cost ~2-5% |
| `spec_store_bypass_disable=on` | Spectre v4 SSB mitigation (v2.1+) | Performance cost ~1-2% |
| `l1tf=full,force` | L1 Terminal Fault mitigation (v2.1+) | Affects HyperThreading |
| `gather_data_sampling=force` | GDS/Downfall mitigation (v2.1+) | Intel-specific |

## Kernel Sysctl Hardening

Shipped via `/usr/lib/sysctl.d/99-mios-hardening.conf`. Admin overrides go in `/etc/sysctl.d/`.

### Kernel pointer and debug restrictions

| Sysctl | Value | Purpose |
|--------|-------|---------|
| `kernel.kptr_restrict` | `2` | Hide kernel pointers from all users |
| `kernel.dmesg_restrict` | `1` | Restrict dmesg to root |
| `kernel.perf_event_paranoid` | `3` | Disable perf for unprivileged users |
| `kernel.sysrq` | `0` | Disable Magic SysRq (prevents local DoS) |
| `kernel.yama.ptrace_scope` | `2` | Only root can ptrace (prevents credential theft) |
| `kernel.unprivileged_bpf_disabled` | `1` | Block unprivileged eBPF (attack surface reduction) |
| `net.core.bpf_jit_harden` | `2` | Harden BPF JIT compiler |
| `kernel.kexec_load_disabled` | `1` | Prevent runtime kernel replacement (v2.1+) |
| `kernel.io_uring_disabled` | `2` | Block io_uring syscalls (v2.1+) |

### Network hardening

| Sysctl | Value | Purpose |
|--------|-------|---------|
| `net.ipv4.tcp_syncookies` | `1` | SYN flood protection |
| `net.ipv4.conf.all.accept_redirects` | `0` | Block ICMP redirects |
| `net.ipv4.conf.all.send_redirects` | `0` | Don't send ICMP redirects |
| `net.ipv4.conf.all.rp_filter` | `1` | Reverse path filtering (anti-spoof) |
| `net.ipv4.conf.all.accept_source_route` | `0` | Block source-routed packets |
| `net.ipv4.conf.all.log_martians` | `1` | Log impossible addresses |
| `net.ipv4.icmp_echo_ignore_broadcasts` | `1` | Ignore broadcast pings |
| `net.ipv4.tcp_timestamps` | `0` | Disable TCP timestamps (fingerprinting) |

IPv6 equivalents are also set for `accept_redirects` and `accept_source_route`.

### Filesystem protection

| Sysctl | Value | Purpose |
|--------|-------|---------|
| `fs.suid_dumpable` | `0` | No core dumps for SUID binaries |
| `fs.protected_hardlinks` | `1` | Restrict hardlink creation |
| `fs.protected_symlinks` | `1` | Restrict symlink following |
| `fs.protected_fifos` | `2` | Restrict FIFO creation in sticky dirs |
| `fs.protected_regular` | `2` | Restrict regular file creation in sticky dirs |

## SELinux

MiOS runs SELinux in **enforcing** mode. Custom policies are split into per-rule individual `.te` modules:

- `mios_portabled`  systemd-portabled D-Bus for sysext/confext (systemd 258+)
- `mios_kvmfr`  Looking Glass shared memory device access for VMs
- `mios_cdi`  NVIDIA CDI spec generation fcontext (v2.1+)
- `mios_quadlet`  Podman quadlet container management (v2.1+)
- `mios_sysext`  systemd-sysext extension activation (v2.1+)

Additional booleans enabled:

- `container_use_cephfs`  Podman containers accessing CephFS
- `virt_use_samba`  libvirt VMs accessing SMB shares

Fcontext for bootc home path:

- `/var/home(/.*)?` labeled `user_home_dir_t`

### Checking SELinux status

```bash
# Current mode
getenforce

# Recent denials
ausearch -m AVC -ts recent

# All MiOS custom policies
semodule -l | grep mios
```

## Firewall

MiOS uses `firewalld` with a default-deny posture:

- Default zone: `drop` (all incoming traffic dropped unless explicitly allowed)
- Cockpit (9090/tcp)  allowed for web management
- SSH (22/tcp)  allowed
- Libvirt bridge  allowed for VM networking
- CrowdSec bouncer  integrated with nftables

### Viewing firewall rules

```bash
firewall-cmd --list-all
firewall-cmd --list-all-zones
```

## CrowdSec (Host-Based IPS)

CrowdSec runs in **sovereign/offline mode**  no data is sent to the CrowdSec cloud. It monitors system logs for brute-force attacks, port scans, and other threats, then applies bans via the nftables firewall bouncer.

```bash
# Check CrowdSec status
sudo cscli metrics
sudo cscli decisions list
sudo cscli alerts list
```

## fapolicyd (Application Whitelisting)

When enabled, fapolicyd restricts which executables can run based on the RPM database and configured trust rules. This prevents execution of unauthorized binaries.

```bash
# Check status
systemctl status fapolicyd

# View trust database
fapolicyd-cli --dump-db | head -20
```

## USBGuard (USB Device Control)

When enabled, USBGuard blocks unauthorized USB devices by default. On first boot, generate a policy from currently connected devices:

```bash
# Generate initial policy from connected devices
sudo usbguard generate-policy > /etc/usbguard/rules.conf
sudo systemctl restart usbguard

# List current devices
sudo usbguard list-devices

# Allow a blocked device
sudo usbguard allow-device <id>
```

## Composefs (Verified Boot Filesystem)

MiOS enables composefs via `/usr/lib/ostree/prepare-root.conf`:

```toml
[composefs]
enabled = true

[etc]
transient = true

[root]
transient-ro = true
```

Composefs provides content-addressed deduplication and verified boot  the filesystem integrity is checked at mount time. The `transient = true` for `/etc` means `/etc` changes are ephemeral by default; persistent changes require explicit configuration.

## Image Signing

MiOS images are signed with cosign via GitHub Actions OIDC (keyless signing). Verify any image before deploying:

```bash
cosign verify \
  --certificate-identity-regexp="https://github.com/Kabuki94/MiOS-bootstrap" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/kabuki94/mios:latest
```

## Overriding Hardening

All hardening settings can be overridden by administrators:

- **Kernel boot params**: create a higher-priority file in `/usr/lib/bootc/kargs.d/` or use `bootc kargs edit`
- **Sysctl**: create overrides in `/etc/sysctl.d/` (higher priority than `/usr/lib/sysctl.d/`)
- **SELinux**: `sudo setenforce 0` (temporary) or edit `/etc/selinux/config` (persistent  not recommended)
- **Firewall**: `firewall-cmd --add-service=...` or `firewall-cmd --add-port=...`
- **CrowdSec**: `sudo cscli decisions delete --all` to clear bans
- **fapolicyd**: add trust rules in `/etc/fapolicyd/fapolicyd.trust`
- **USBGuard**: `sudo usbguard allow-device <id>` or edit `/etc/usbguard/rules.conf`

## Security Reporting

To report a security vulnerability, use GitHub's private vulnerability reporting feature (Security tab  Report a vulnerability) or file a Security issue using the provided template. Do not disclose sensitive vulnerabilities in public issues.

---
###  Bootc Ecosystem & Resources
- **Core:** [containers/bootc](https://github.com/containers/bootc) | [bootc-image-builder](https://github.com/osautomation/bootc-image-builder) | [bootc.pages.dev](https://bootc.pages.dev/)
- **Upstream:** [Fedora Bootc](https://github.com/fedora-cloud/fedora-bootc) | [CentOS Bootc](https://gitlab.com/CentOS/bootc) | [ublue-os/main](https://github.com/ublue-os/main)
- **Tools:** [uupd](https://github.com/ublue-os/uupd) | [rechunk](https://github.com/hhd-dev/rechunk) | [cosign](https://github.com/sigstore/cosign)
- **Project Repository:** [Kabuki94/MiOS-bootstrap](https://github.com/Kabuki94/MiOS-bootstrap)
- **Sole Proprietor:** MiOS-DEV
---
<!--  MiOS Proprietary Artifact | Copyright (c) 2026 MiOS-DEV -->
