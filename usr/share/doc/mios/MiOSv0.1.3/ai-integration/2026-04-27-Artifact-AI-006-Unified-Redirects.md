<!-- 🌐 MiOS Artifact | Proprietor: MiOS-DEV | https://github.com/Kabuki94/MiOS-bootstrap -->
# 🌐 MiOS Unified AI Redirects

```json:knowledge
{
  "summary": "Unified AI API patterns and redirects for MiOS. Agnostic targeting of FOSS and Proprietary (Gemini/Claude) interfaces.",
  "logic_type": "documentation",
  "tags": [
    "MiOS",
    "AI",
    "API",
    "Agnostic",
    "Gemini",
    "Claude",
    "OpenAI"
  ],
  "relations": {
    "depends_on": [
      "INDEX.md",
      "ai-context.json"
    ],
    "impacts": [
      ".well-known/ai-tools.json"
    ]
  },
  "last_rag_sync": "2026-04-27T17:45:00Z",
  "version": "0.1.3"
}
```

## 🧩 Architectural Philosophy

MiOS treats AI APIs as **pluggable system services**. To prevent provider lock-in while maintaining high-fidelity integration with leading models (Gemini, Claude), we implement a **Unified Redirect Layer**.

1. **Protocol Priority:** Open-Source / Local APIs (OpenAI Protocol compatible) are the primary target.
2. **Standardized Redirects:** Gemini and Claude patterns are supported via standard environment-mapped redirects.
3. **FHS Compliance:** All configuration follows Linux Filesystem standards (USR-OVER-ETC).

---

## 🛠️ Unified API Map

| Abstract Target | Primary Protocol | Redirect (Gemini) | Redirect (Claude) |
|-----------------|------------------|-------------------|-------------------|
| `ai.mios.local` | OpenAI v1 (Local) | Vertex AI API | Anthropic API |
| `mcp.mios.local`| Model Context Protocol | Google MCP Server | Anthropic MCP |
| `rag.mios.local`| Vector Search | Vertex Search | Pinecone / Custom |

---

## 📂 Filesystem Standards (FHS)

### 1. User Configuration (XDG)
Stored in `${XDG_CONFIG_HOME:-$HOME/.config}/mios/ai/`.
- `config.toml`: Master API configuration.
- `endpoints.json`: Dynamic redirect mapping.

### 2. System Configuration (USR-OVER-ETC)
Stored in `/usr/lib/mios/ai/`.
- `default-redirects.json`: Read-only factory default patterns.
- `supported-models.md`: Capability manifest.

### 3. Runtime State
Stored in `/run/mios/ai/`.
- `active-redirects`: Symlinks to current provider configuration.

---

## 🔑 Environment Redirects

All MiOS-native tools should use these agnostic environment variables:

| Agnostic Variable | Gemini Redirect | Claude Redirect |
|-------------------|-----------------|-----------------|
| `MIOS_AI_KEY`     | `GOOGLE_API_KEY`| `ANTHROPIC_API_KEY` |
| `MIOS_AI_MODEL`   | `gemini-2.0-pro`| `claude-3-5-sonnet` |
| `MIOS_AI_ENDPOINT`| Vertex Endpoint | Anthropic Endpoint |

---

## 🔄 Protocol Shims

### OpenAI Compatibility
MiOS provides a local proxy at `http://localhost:8080/v1` that shims various providers into a single OpenAI-compatible interface.

- **FOSS:** Routes to Ollama / vLLM.
- **Gemini:** Shims Vertex AI via `google-cloud-aiplatform`.
- **Claude:** Shims Anthropic via `anthropic-sdk`.

### System Prompt Redirects
System instructions are injected based on the provider's standard patterns:
- **Gemini:** Injected via `system_instruction` in the generate request.
- **Claude:** Injected via the `system` parameter in the messages API.
- **FOSS:** Injected via the `system` role in the chat completions array.

---

## 📜 Usage Patterns for Agents

When an AI agent (Gemini CLI, Claude Code, Aider) operates on MiOS, it should:
1. **Detect Context:** Read `/run/mios/ai/active-redirects` to see the current provider.
2. **Target Standards:** Use the OpenAI-compatible local proxy if available.
3. **Fallback Gracefully:** If direct provider access is required, use the Agnostic Variables mapped above.

---
<!-- ⚖️ MiOS Proprietary Artifact | Copyright (c) 2026 MiOS-DEV -->
