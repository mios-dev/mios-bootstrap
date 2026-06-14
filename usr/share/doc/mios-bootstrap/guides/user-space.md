<!-- AI-hint: Documentation of MiOS user-space configuration — the layered resolution of profile TOMLs and AI system prompts, the per-user/host/vendor overlay model, and the schema for identity, auth, and AI endpoint/model fields. This is the user-editable seam of the immutable image: where an operator's choices override vendor defaults without re-baking the OCI image.
     AI-related: /etc/mios/profile.toml, /usr/share/mios/profile.toml, /etc/mios/ai/system-prompt.md, /usr/share/mios/ai/system.md, /etc/mios/install.env, /usr/share/mios/mios.toml, mios-llm-light, MIOS_AI_ENDPOINT, ghcr.io/mios-dev/mios:latest -->
# 'MiOS' User-Space Configuration

**Version:** v0.2.4

## Purpose

MiOS is an immutable, `bootc`/OCI-shaped Fedora workstation that is *also* a
local, self-replicating agentic AI operating system: the same image that ships
GNOME/Wayland, GPU wiring, KVM passthrough, and a k3s+Ceph cluster path also
ships a full local inference + agent stack behind one OpenAI-compatible endpoint.
Because the image is immutable — `/usr` is a read-only composefs mount baked into
the OCI image — operator choices cannot live *in* `/usr`. They live here, in
**user space**: a thin, layered overlay where per-user and host settings shadow
the vendor defaults without re-baking the image.

This document specifies that overlay — how profile TOMLs and AI system prompts
resolve, what fields they expose, and what persisted state an install writes.
It is the seam between the unchanging image and the operator who runs it. Its
audience is operators and bootstrap maintainers.

> **Where this sits in the whole.** The deeper SSOT for *everything*
> operator-tunable (packages, ports, AI lanes, services) is
> `/usr/share/mios/mios.toml`, resolved through the same three-layer overlay
> described below. The `profile.toml` covered here is the identity/auth/AI slice
> of that model — the part a person edits on first run. Both feed the build
> pipeline → OCI image → `bootc` lifecycle, and the AI fields point every agent
> and tool at the one local brain (Architectural Law 5).

## Profile layers

Three TOML layers overlay at runtime (higher precedence first); empty string
values do NOT override non-empty values in lower layers (an empty user TOML is
the vendor-default state, not an error):

1. `~/.config/mios/profile.toml` -- per-user (seeded from `/etc/skel/.config/mios/`)
2. `/etc/mios/profile.toml` -- host admin override (this repo's editable copy)
3. `/usr/share/mios/profile.toml` -- vendor defaults (baked into the image by `mios.git`)

`install.sh:resolve_profile_layers` walks all three and field-level overlays
them. This is the same highest-wins discipline `mios.toml` uses, so an operator
who learns one learns both.

## AI prompt layers

The agent system prompt resolves in the same order:

1. `${MIOS_AI_SYSTEM_PROMPT}` (env var)
2. `~/.config/mios/system-prompt.md`
3. `/etc/mios/ai/system-prompt.md`
4. `/usr/share/mios/ai/system.md` (canonical -- this repo)

The canonical prompt at the bottom of the stack is the vendor identity baked into
the image; the higher layers let a host or user refine it without touching the
image. This is the prompt the local agent stack runs under — the same agents that
the AI fields below point at.

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

**How the AI fields wire into the system.** The `[ai].endpoint` is the single
OpenAI-compatible front door — `MIOS_AI_ENDPOINT` — that every agent and tool
resolves to (Architectural Law 5, **UNIFIED-AI-REDIRECTS**). No vendor-cloud URL
ever appears; the endpoint stays on `localhost`. Behind it:

- `[ai].model` (e.g. `qwen2.5-coder:7b`, or larger tags like `gemma4:12b`) is
  served by **`mios-llm-light`** (`:11450`) — the primary local inference lane: a
  `llama.cpp` multi-model server fronted by the upstream `llama-swap` proxy image,
  which auto-swaps the everyday chat/reasoning models behind one endpoint and
  KV-pages each conversation to disk. Heavy GPU lanes (`mios-llm-heavy` /
  `mios-llm-heavy-alt`) exist but are gated off by default on VRAM grounds.
- `[ai].embed_model` (`nomic-embed-text`) is served by that *same*
  `mios-llm-light` lane via OpenAI-compatible `/v1/embeddings`. Those embeddings
  back vector recall in the unified agent datastore, **PostgreSQL + pgvector**
  (the `mios-pgvector` container on `:5432`).

The model tags speak the OpenAI/Ollama-compatible API, so any OpenAI-API client
talks to them unchanged — but the *inference engine* is `llama.cpp` (and gated
SGLang/vLLM heavy lanes), not a hosted service or a vendor account. In effect,
setting two fields in a user TOML aims the whole local agent stack — inference
lanes → agent-pipe/Hermes orchestration → pgvector memory → MCP/A2A tooling — at
the operator's chosen brain.

## Persisted state

An install writes only the minimum durable state; secrets are never written in
plaintext:

| Path | Contents | Mode |
|---|---|---|
| `/etc/mios/install.env` | Non-secret install metadata (the derived env bridge) | 0640 |
| `/etc/mios/profile.toml` | Host profile overrides | 0644 |
| `~mios/.ssh/id_ed25519` | Generated SSH key | 0600 |
| `~mios/.git-credentials` | GitHub PAT (if provided) | 0600 |

Passwords are piped to `chpasswd` and never written to disk in plaintext. This
respects the immutable-image contract (Law 2, **NO-MKDIR-IN-VAR**): durable
state goes to declared `/etc` and `/var` paths, never scattered at build time,
so a `bootc upgrade` carries the host forward and a `bootc rollback` reverts the
image without clobbering the operator's identity and keys.

## Re-seeding user homes

`install.sh:seed_user_skel_for_all_accounts` runs on every install. Every
uid ≥ 1000 user gets the latest
`~/.config/mios/{profile.toml,system-prompt.md}` from `/etc/skel/`. This is how
new vendor defaults reach existing accounts across image upgrades: the image
ships fresh templates in `/etc/skel`, the seeding step lays them into each home,
and the operator's own edits in the higher overlay layers continue to win. The
seam stays consistent every time the OCI image rolls forward.
