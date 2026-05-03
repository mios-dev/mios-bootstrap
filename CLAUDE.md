# CLAUDE.md

> Claude agent entry point. Pointer file -- no MiOS-internal documentation.

MiOS targets the OpenAI public API surface at
`MIOS_AI_ENDPOINT=http://localhost:8080/v1` (Architectural Law 5:
UNIFIED-AI-REDIRECTS). All Claude/Cline/Cursor/Codex/Gemini sessions resolve
the same canonical prompt regardless of which repo they were invoked from.

## Canonical prompt

```
/usr/share/mios/ai/system.md          (image-baked, deployed from mios-bootstrap)
  /etc/mios/ai/system-prompt.md       (host-local override)
    ~/.config/mios/system-prompt.md   (per-user override)
```

Highest layer present wins; `$MIOS_AI_SYSTEM_PROMPT` overrides them all.

## OpenAI API documents and standards (source of truth)

| Surface | URL |
|---|---|
| API Reference | https://platform.openai.com/docs/api-reference |
| Models catalog | https://platform.openai.com/docs/models |
| Function calling / tools | https://platform.openai.com/docs/guides/function-calling |
| Structured outputs | https://platform.openai.com/docs/guides/structured-outputs |
| Embeddings | https://platform.openai.com/docs/guides/embeddings |
| Realtime / Streaming | https://platform.openai.com/docs/guides/realtime |
| OpenAI Cookbook | https://cookbook.openai.com/ |
| Moderation policy | https://platform.openai.com/docs/guides/moderation |
| `agents.md` convention | https://agents.md/ |

## Local trace

`API.md` in this repo tracks the served subset of the OpenAI surface for the
deployed LocalAI build. Verify any specific endpoint with
`GET /v1/models` against `MIOS_AI_ENDPOINT` before relying on it.

## Operating context

- **cwd:** `/` is the repo root and the deployed system root.
- **Confirm before:** `git push`, `bootc upgrade`, `dnf install`,
  `systemctl`, `rm -rf`.
- **Deliverables:** complete replacement files only.
- **Memory:** `/var/lib/mios/ai/memory/`
- **Scratch:** `/var/lib/mios/ai/scratch/`
