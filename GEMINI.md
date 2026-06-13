<!-- AI-hint: Defines the Gemini CLI tool configuration and prompt loading hierarchy, ensuring it routes through the local OpenAI-compatible gateway at port 8080 instead of direct Google APIs.
     AI-related: /usr/share/mios/ai/system.md, /etc/mios/ai/system-prompt.md, localhost:8080 -->
# GEMINI.md

Per-tool stub for Gemini CLI. Canonical prompt:
`/usr/share/mios/ai/system.md`.

## Loading order

1. Load `/usr/share/mios/ai/system.md`.
2. Apply `/etc/mios/ai/system-prompt.md` if present (host override).
3. Apply `~/.config/mios/system-prompt.md` if present (user override).

Gemini routes through the same OpenAI-API-compatible endpoint
(`http://localhost:8080/v1`) per Architectural Law 5. No
gemini.googleapis.com endpoints; no proprietary protocols.
