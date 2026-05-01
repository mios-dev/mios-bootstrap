# VARIABLES.md

> Every prompt the bootstrap installer asks, with defaults and notes.
> Snapshot v0.2.2.

## Defaults convention

Everything defaults to **mios**. The user only types when they want to
override. Pressing Enter at any prompt accepts the default.

## Prompts (in order)

| Prompt | Default | Notes |
|---|---|---|
| Linux username | `mios` | Will be a sudoer (added to `wheel`). |
| Hostname | `mios` | Applied via `hostnamectl set-hostname`. |
| Full name (GECOS) | `MiOS User` | Cosmetic; appears in `finger` / `getent passwd`. |
| Password | (none -- prompt twice) | Hashed via `chpasswd`. Never written to disk in plaintext. |
| SSH key | generate ed25519 | Choices: `g` generate / `e` use existing path / `s` skip. |
| GitHub PAT | skip | If provided, configures `credential.helper store` for the user. |
| Image tag (bootc hosts) | `ghcr.io/MiOS-DEV/mios:latest` | Passed to `bootc switch`. |
| Build vs FHS (non-bootc) | FHS | Choose between local build and FHS overlay install. |

## Persisted profile

After the install applies, `/etc/mios/install.env` records the non-secret
choices (username, hostname, GECOS, groups, install mode, image tag, ISO
timestamp, bootstrap version). Mode 0640.

## Secrets

- Password -- never persisted; hashed by `chpasswd`.
- GitHub PAT -- written to `~mios/.git-credentials` (mode 0600) if provided.
- SSH private key -- in `~mios/.ssh/id_ed25519` (mode 0600).

## Override sources at runtime (post-install)

Once MiOS is running, the deployed system reads runtime env in this order
(later overrides earlier):

1. `/etc/mios/install.env` -- non-secret install metadata.
2. `/etc/mios/runtime.env` -- system-wide runtime overrides (admin-managed).
3. `~/.config/mios/env` -- per-user XDG override (user-managed).

## License

Apache-2.0.
