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
