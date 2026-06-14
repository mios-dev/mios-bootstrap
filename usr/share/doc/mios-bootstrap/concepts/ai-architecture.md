<!-- AI-hint: The mios-bootstrap AI entry point — explains how the user-overlay repo's AI files (system prompt, model/MCP/vars manifests, knowledge graphs) layer onto the vendor defaults, and how every agent and tool resolves to the single local OpenAI-compatible endpoint that fronts MiOS's local inference lanes and agent pipeline. Read this to understand what mios-bootstrap owns in the AI plane and how its config resolves.
     AI-related: /etc/mios/profile.toml, /usr/share/mios/ai/system.md, /usr/share/mios/ai/models.json, /usr/share/mios/ai/mcp.json, /usr/share/mios/ai/vars.json, /usr/share/mios/knowledge/, /usr/share/mios/profile.toml, /etc/mios/ai/system-prompt.md, /etc/mios/ai/config.json, /usr/share/mios/llamacpp/llama-swap.yaml, mios-bootstrap -->
# 'MiOS' Bootstrap -- AI Entry Point

## Purpose & place in the whole system

MiOS is one thing built two ways at once: an **immutable, bootc/OCI-shaped
Fedora workstation** (the whole OS is a single container image -- boot it,
`bootc upgrade` it like a `git pull`, `bootc rollback` it like a Ctrl-Z) that is
*also* a **local, self-hosted agentic AI operating system**. The same image that
ships the GNOME/Wayland desktop also ships a full local inference + agent stack,
so the OS can reason about itself, drive its own tools, and -- because the whole
thing is one rebuildable OCI image -- effectively re-create itself.

This document is the **AI entry point for `mios-bootstrap.git`**, the interactive
installer and user-editable layer of MiOS. It does not describe the runtime
engines in depth (the system layer in `mios.git` owns those); it describes
**which AI files this repo owns, how they overlay the vendor defaults, and how
every agent and tool resolves to the one local AI endpoint.** Its audience is the
operator customizing a deployment and the agent loading its own configuration.

The locally hosted MiOS AI models orchestrate all work in this stack.
Every agent CLI, IDE plugin, and runtime tool routes through
`MIOS_AI_ENDPOINT=http://localhost:8080/v1` (Architectural Law 5,
**UNIFIED-AI-REDIRECTS**) and defers to those models. Strict adherence to OpenAI
API standards and patterns -- no vendor branding, no vendor-native protocols, no
proprietary side-channels. The AI files inventoried below are what those locally
hosted models load and serve.

Merge order: `mios.git` (system layer) ← `mios-bootstrap.git` (user overlay).
Bootstrap profile values, AI files, and skel templates overlay the vendor
defaults at install time.

## How the AI files fit the end-to-end pipeline

The files this repo owns are the **configuration surface** of MiOS's AI plane;
the engines that consume them ship in `mios.git`. End to end:

```
build pipeline (numbered automation/) → OCI image → bootc lifecycle on the host
                                                          │
   this repo's AI files overlay the vendor defaults ──────┤
                                                          ▼
   MIOS_AI_ENDPOINT (http://localhost:8080/v1, Law 5)
                                                          │
   ┌──────────────────────────────────────────────────────────────────────┐
   │ inference lanes → agent-pipe/Hermes orchestration → pgvector memory →  │
   │ MCP (tools) / A2A (agents)                                             │
   └──────────────────────────────────────────────────────────────────────┘
```

- **Inference lanes** (named by *function*, served behind the endpoint):
  - `mios-llm-light` (`:11450`) is the **primary** lane -- a `llama.cpp`
    multi-model server fronted by the upstream
    [llama-swap](https://github.com/mostlygeek/llama-swap) proxy image. It
    auto-swaps the everyday chat/reasoning models behind one endpoint, KV-pages
    each conversation to disk, **and** serves embeddings (`nomic-embed-text`,
    OpenAI-compatible `/v1/embeddings`) plus the `mios-opencode` coder model.
    Model map: `/usr/share/mios/llamacpp/llama-swap.yaml`.
  - `mios-llm-heavy` (`:11441`, served-name `mios-heavy`) is the heavy GPU lane
    (SGLang); `mios-llm-heavy-alt` is the alternate (vLLM). Both are gated off by
    default on VRAM grounds.
  - These speak the OpenAI/Ollama-compatible API, so any OpenAI-API client talks
    to them unchanged -- but the *inference engine* is `llama.cpp`/SGLang/vLLM,
    not a hosted service.
- **Orchestration** -- the **agent-pipe** (`:8640`) is the router/dispatch
  gateway every front-end talks to; **MiOS-Hermes** (`:8642`) is the
  OpenAI-compatible agent gateway (sessions, tool-loop, skills, browser control);
  a **prefilter** (`:8641`) injects fan-out hints on decomposable prompts; the
  **opencode-gateway** (`:8633`) makes the coder peer a real `/v1` council member.
- **Memory** -- the unified agent datastore is **PostgreSQL + pgvector**
  (`mios-pgvector` on `:5432`), holding agent memory, events, tool calls,
  sessions, skills, scratch, and a `knowledge` table of finished Q+A with vector
  recall (embeddings from `nomic-embed-text` on `mios-llm-light`).
- **Tools & federation** -- agents call tools over **MCP** and reach other agents
  over **A2A**; `web_search` is backed by a local **SearXNG** (`:8888`).

The throughline: **inference lanes → agent-pipe/Hermes orchestration → pgvector
memory → MCP/A2A**, all behind the single `MIOS_AI_ENDPOINT`. The files below are
what you edit to steer that pipeline without touching the engines.

## What mios-bootstrap.git owns

| Path | Purpose |
|---|---|
| `/install.sh` | Linux installer |
| `/install.ps1` | Windows installer (Podman machine + WSL2 + build pipeline) |
| `/etc/mios/profile.toml` | Host-local profile -- edit to customize this deployment |
| `/etc/skel/.config/mios/` | User dotfile templates (seeded on `useradd -m`) |
| `/usr/share/mios/ai/system.md` | Agent system prompt (host-override layer) |
| `/usr/share/mios/ai/models.json` | OpenAI `/v1/models` model catalog |
| `/usr/share/mios/ai/mcp.json` | MCP server registry |
| `/usr/share/mios/ai/vars.json` | Global variables index (all version pins, ports, paths) |
| `/usr/share/mios/knowledge/` | RAG knowledge graphs |

## User customization (`etc/mios/profile.toml`)

| Section | Key fields |
|---|---|
| `[identity]` | `username`, `fullname`, `hostname`, `shell`, `groups` |
| `[locale]` | `timezone`, `keyboard_layout`, `language` |
| `[auth]` | `ssh_key_action`, `password_policy`, `github_pat` |
| `[ai]` | `endpoint`, `model`, `embed_model`, `enable_localai` |
| `[desktop]` | `session`, `color_scheme`, `flatpaks` |
| `[image]` | `ref`, `branch` (bootc switch target) |
| `[bootstrap]` | `mode` (`auto`/`bootc`/`fhs`), repo URLs, `reboot_on_finish` |
| `[quadlets.enable]` | Per-Quadlet enable/disable flags |

Secrets (`password_hash`, `luks_passphrase`, `github_pat`) are never committed.

## Profile resolution (three layers, higher wins)

```
~/.config/mios/profile.toml     per-user  (highest)
/etc/mios/profile.toml          host-local
/usr/share/mios/profile.toml    vendor defaults (lowest)
```

Empty strings do **not** override non-empty values below; an empty user TOML is
the vendor-default state, not an error.

## AI system prompt resolution

```
$MIOS_AI_SYSTEM_PROMPT > ~/.config/mios/system-prompt.md > /etc/mios/ai/system-prompt.md > /usr/share/mios/ai/system.md
```

## Local AI stack

- **base_url:** `http://localhost:8080/v1` (`MIOS_AI_ENDPOINT`) -- the single
  OpenAI-compatible front door; resolves to the local inference lanes above. No
  vendor-cloud URLs.
- **model:** resolved from `[ai].model` in `mios.toml` (the served reasoning
  model on `mios-llm-light`; e.g. `gemma4:12b`). Auto-selected from
  `[ai.host_thresholds]` when unset (`MIOS_AI_MODEL`).
- **embed_model:** `nomic-embed-text`, served by `mios-llm-light` via OpenAI-compat
  `/v1/embeddings` (`MIOS_AI_EMBED_MODEL`) -- the same embeddings drive pgvector
  recall.
- **models registry:** `/usr/share/mios/ai/models.json`
- **MCP registry:** `/usr/share/mios/ai/mcp.json`
- **inference config:** `/etc/mios/ai/config.json` (base_url, models)
- **global vars:** `/usr/share/mios/ai/vars.json`

> **Inference engines.** The endpoint is served by the `mios-llm-light` lane
> (`:11450`, `llama.cpp` via the upstream `llama-swap` proxy image), which also
> serves embeddings, with gated heavy GPU lanes (`mios-llm-heavy` SGLang `:11441`,
> `mios-llm-heavy-alt` vLLM). The unified agent datastore is **PostgreSQL +
> pgvector**. The earlier Ollama/SurrealDB/Qdrant stack has been removed; Ollama
> survives only as an *upstream API-compat reference* (the lanes speak the
> OpenAI/Ollama-compatible API) and in historical migration notes -- not as a
> live MiOS backend.

## Full agent context

Load `/usr/share/mios/ai/system.md` for the complete prompt. For the image-baked
authoritative version, see `/usr/share/mios/ai/system.md` in the deployed image
(same file, image layer). The system-layer companion is
`/usr/share/mios/ai/INDEX.md` (the architectural contract) in `mios.git`.
