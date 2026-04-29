# MiOS-bootstrap

> Interactive ignition installer for MiOS. The user-facing entry point.

**Version:** v0.2.0
**System repo:** https://github.com/Kabuki94/MiOS

---

## What this is

This repository is the **installer** for MiOS. It's the only thing end users
interact with directly. It contains:

- `install.sh` -- the interactive installer (run as root). Prompts for
  Linux username, hostname, password, SSH key, GitHub PAT, and image tag --
  everything defaults to `mios` until the user overrides.
- `system-prompt.md` -- the **SSOT for AI behavior** on every MiOS host.
  Bootstrap deploys this to `/etc/mios/ai/system-prompt.md` during install,
  where LocalAI loads it as the system prompt for all chat completions.
  Customize per host (edit the deployed file) or fleet-wide (fork bootstrap).
- User-space env templates (`.env.mios`, `identity.env.example`)
- User-facing docs (`USER-SPACE-GUIDE.md`, `VARIABLES.md`)
- A `profile/` skeleton for dotfiles and per-user systemd units (populate
  as the project grows)

## What this is NOT

- Not the OS image. Pre-built images live at `ghcr.io/kabuki94/mios:latest`.
- Not the build infrastructure. Containerfile, Justfile, build scripts, and
  the FHS overlay all live in https://github.com/Kabuki94/MiOS.
- Not a Docker / OCI thing. Bootstrap runs on a target Fedora host, not in
  a container.

## Install one-liner

On a fresh Fedora bootc-capable host (Fedora Server 41+ or Fedora bootc):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/install.sh)"
```

Bootstrap prompts for installation profile, applies it, then either:

- `bootc switch ghcr.io/kabuki94/mios:latest` (bootc hosts), or
- Clones MiOS and runs its FHS overlay installer (non-bootc hosts).

Reboot when prompted. MiOS is now running.

## Defaults

| Variable | Default |
|---|---|
| Linux username | `mios` |
| Hostname | `mios` |
| Full name (GECOS) | `MiOS User` |
| Login shell | `/bin/bash` |
| Sudo groups | `wheel,libvirt,kvm,video,render,input,dialout` |
| SSH key | generate ed25519 |
| GitHub PAT | skip |
| MiOS image | `ghcr.io/kabuki94/mios:latest` |

The user is prompted for each; pressing Enter accepts the default.

## What gets persisted

- `/etc/mios/install.env` -- non-secret installation metadata (mode 0640)
- `~mios/.ssh/id_ed25519` -- generated SSH key (mode 0600)
- `~mios/.git-credentials` -- if a GitHub PAT was provided (mode 0600)

Passwords go through `chpasswd` and are never written to disk in plaintext.

## Idempotency

Re-running the installer with the same answers updates rather than duplicates.
Existing users are amended (not recreated); existing SSH keys are not
overwritten by the "generate" path (use a different keypair name to layer).

## License

Apache-2.0. See [LICENSE](LICENSE).
