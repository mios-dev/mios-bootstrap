<!-- AI-hint: Per-tool entry stub for the Gemini CLI on the mios-bootstrap repo (the user-facing installer + user-editable layer of MiOS). Defers all agent identity to the canonical agent prompt (AGENTS.md -> /usr/share/mios/ai/system.md) and records only the Gemini-CLI delta: layered prompt loading order and the binding to the single OpenAI-compatible AI endpoint (MIOS_AI_ENDPOINT, default http://localhost:8080/v1) per Architectural Law 5. The endpoint fronts the local mios-llm-light inference lane, the agent-pipe/MiOS-Hermes orchestration, and PostgreSQL+pgvector memory.
     AI-related: AGENTS.md, /usr/share/mios/ai/system.md, /etc/mios/ai/system-prompt.md, ~/.config/mios/system-prompt.md, MIOS_AI_ENDPOINT, http://localhost:8080/v1, usr/share/mios/llamacpp/llama-swap.yaml, mios-llm-light, mios-agent-pipe, mios-pgvector -->
# GEMINI.md

> _`GEMINI.md` — per-tool stub for the **Gemini CLI** on `mios-bootstrap.git`.
> The canonical agent entry point for this repo is **[`AGENTS.md`](AGENTS.md)**
> (the [agents.md][1] standard), which defers to the deployed vendor canonical
> **`/usr/share/mios/ai/system.md`**. This stub does NOT re-state the agent
> identity, posture, or tool-loop — it records ONLY the Gemini-CLI loading order
> and the endpoint binding. No hardcoded topics, apps, or keywords._
>
> [1]: https://agents.md

## What this is, and where it fits

MiOS is an immutable, `bootc`/OCI-shaped Fedora workstation that is also a local,
self-replicating **agentic AI OS**: one OCI image boots the desktop, upgrades
like a `git pull`, rolls back like a Ctrl-Z, and ships a full agent stack baked
in. Every agent on the host — whether it arrives as Open WebUI, the `mios` CLI,
Claude Code, or the **Gemini CLI** — is just another node speaking to **one local
brain** over **one OpenAI-API-compatible endpoint**. There is no vendor lock-in
and no per-tool "API key to the cloud": the editor/CLI you happen to use is
interchangeable plumbing in front of the same inference lanes, agent
orchestration, and memory.

This repo (`mios-bootstrap.git`) is the **interactive installer and
user-editable layer** of that system — Phase 0..4, the three-layer profile
model, the AI prompt files, and the user templates. (The system FHS overlay,
Containerfile, Quadlets, and Architectural Laws live in `mios.git`.) This file
exists so the Gemini CLI plugs into the running system correctly. It carries only
the **Gemini-CLI delta** — how to load the shared identity and which endpoint to
bind. Everything substantive lives once in the canonical agent prompt and is
shared by every agent.

## Role and Objective

The Gemini CLI runs as a **MiOS agent** — one node in the local MiOS AIOS, not a
standalone Google chatbot. **Operate under the canonical agent prompt** — the
single system identity for every agent on this host. Load it and behave exactly
as it specifies; everything below is the Gemini-CLI delta only.

## Loading order

Identity is a three-layer SSOT, mirroring the `mios.toml`/`profile.toml` override
model (**highest layer wins**). Load the vendor canonical first, then apply each
override layer if present:

1. Load `/usr/share/mios/ai/system.md` (vendor canonical, shipped in the image).
2. Apply `/etc/mios/ai/system-prompt.md` if present (host/admin override, deployed
   by bootstrap).
3. Apply `~/.config/mios/system-prompt.md` if present (per-user override, seeded
   from `etc/skel/` on first login).

## Endpoint binding (Architectural Law 5)

The Gemini CLI routes through the **same OpenAI-API-compatible endpoint as every
other MiOS agent** — `MIOS_AI_ENDPOINT`, default `http://localhost:8080/v1` —
per **Architectural Law 5 (UNIFIED-AI-REDIRECTS)**: no agent or tool may hardcode
a vendor URL or port; they all resolve this one endpoint. No
`gemini.googleapis.com` endpoints; no proprietary protocols — function-calling
and the tool-calling loop go through the OpenAI-compatible surface.

What sits behind that endpoint is the MiOS inference and orchestration stack, not
a cloud:

- **Inference** — the everyday lane is **`mios-llm-light`**, the primary local
  LLM engine (llama.cpp behind the upstream `ghcr.io/mostlygeek/llama-swap` proxy
  image) on **`:11450`**. It auto-swaps GGUF chat/reasoning models behind one
  endpoint, KV-pages each conversation, serves embeddings (`nomic-embed-text` via
  OpenAI-compatible `/v1/embeddings`), and hosts the `mios-opencode` coder model —
  config in
  [`usr/share/mios/llamacpp/llama-swap.yaml`](usr/share/mios/llamacpp/llama-swap.yaml).
  Heavy work, when enabled, falls to the GPU lanes **`mios-llm-heavy`** (SGLang,
  `:11441`) and **`mios-llm-heavy-alt`** (vLLM), both gated/off-by-default on
  VRAM. These speak the OpenAI/Ollama-compatible API, so any OpenAI-API client
  talks to them unchanged — but the *engine* is `llama.cpp`/SGLang/vLLM, not a
  hosted service.
- **Orchestration** — requests flow through the MiOS agent pipeline: the
  **agent-pipe** router/dispatch gateway and the **MiOS-Hermes** OpenAI-compatible
  agent gateway, which inject the canonical identity per request (it is not baked
  into any model), run the tool-calling loop over the unified **MCP**
  tool/skill/recipe surface, and delegate across peer agents over **A2A**.
- **Memory** — the unified agent datastore is **PostgreSQL + pgvector**
  (`mios-pgvector`), holding agent memory, events, tool calls, sessions, skills,
  scratch, and a `knowledge` table of finished Q+A with vector recall (embeddings
  from `nomic-embed-text` on `mios-llm-light`).

So the Gemini CLI's job is narrow and clear: **bind to `MIOS_AI_ENDPOINT` only**,
load the shared identity, and let the MiOS stack behind that one endpoint —
inference lanes → agent-pipe/Hermes orchestration → pgvector memory → MCP/A2A —
do the rest.
