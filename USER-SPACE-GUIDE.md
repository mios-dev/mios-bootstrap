# 'MiOS' User-Space Configuration

**Version:** v0.2.2

## Profile layers

Three TOML layers overlay at runtime (higher precedence first):

1. `~/.config/mios/profile.toml` — per-user (seeded from `/etc/skel/.config/mios/`)
2. `/etc/mios/profile.toml` — host admin override (this repo's editable copy)
3. `/usr/share/mios/profile.toml` — vendor defaults (baked into image by `mios.git`)

Empty string values do NOT override non-empty values in lower layers.

## AI prompt layers

Same resolution order:

1. `${MIOS_AI_SYSTEM_PROMPT}` (env var)
2. `~/.config/mios/system-prompt.md`
3. `/etc/mios/ai/system-prompt.md`
4. `/usr/share/mios/ai/system.md` (canonical — this repo)

## Key profile fields

| Section | Field | Default |
|---|---|---|
| `[identity]` | `username` | `mios` |
| `[identity]` | `hostname` | `mios` |
| `[identity]` | `shell` | `/bin/bash` |
| `[identity]` | `groups` | `wheel,libvirt,kvm,video,render,input,dialout,docker` |
| `[auth]` | `ssh_key_type` | `ed25519` |
| `[auth]` | `ssh_key_action` | `generate` |
| `[image]` | `ref` | `ghcr.io/mios-dev/mios:latest` |
| `[ai]` | `endpoint` | `http://localhost:8080/v1` |
| `[ai]` | `model` | `qwen2.5-coder:7b` |
| `[ai]` | `embed_model` | `nomic-embed-text` |

## Persisted state

| Path | Contents | Mode |
|---|---|---|
| `/etc/mios/install.env` | Non-secret install metadata | 0640 |
| `/etc/mios/profile.toml` | Host profile overrides | 0644 |
| `~mios/.ssh/id_ed25519` | Generated SSH key | 0600 |
| `~mios/.git-credentials` | GitHub PAT (if provided) | 0600 |

Passwords are piped to `chpasswd` and never written to disk in plaintext.

## Re-seeding user homes

`install.sh:seed_user_skel_for_all_accounts` runs on every install. Every uid≥1000 user gets the latest `~/.config/mios/{profile.toml,system-prompt.md}` from `/etc/skel/`.
