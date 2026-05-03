# CLAUDE.md

> Agent entry point (un-labeled). Pointer file -- no MiOS-internal
> documentation. The filename exists for tooling discovery only; the
> content is vendor-neutral and OpenAI-API-shaped.

'MiOS' targets the OpenAI public API surface at
`MIOS_AI_ENDPOINT=http://localhost:8080/v1` (Architectural Law 5:
UNIFIED-AI-REDIRECTS). Every editor/CLI agent that picks up this file
resolves the same canonical prompt regardless of which repo it was
invoked from. No vendor branding lives in this file.

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
| Chat Completions | https://platform.openai.com/docs/api-reference/chat |
| Responses | https://platform.openai.com/docs/api-reference/responses |
| Function calling / tools | https://platform.openai.com/docs/guides/function-calling |
| Structured outputs | https://platform.openai.com/docs/guides/structured-outputs |
| Embeddings | https://platform.openai.com/docs/guides/embeddings |
| Realtime / Streaming | https://platform.openai.com/docs/guides/realtime |
| OpenAI Cookbook | https://cookbook.openai.com/ |
| Moderation policy | https://platform.openai.com/docs/guides/moderation |
| `agents.md` convention | https://agents.md/ |

## USER variable resolution (build entry)

Every `USER`-marked placeholder in this codebase is overridable at build
entry. The bootstrap installer detects the running user's identity at
install time, propagates it into `/etc/mios/install.env` and
`~/.config/mios/profile.toml`, and substitutes the placeholder before
the image is built. Day-0 shipped artifacts therefore default to the
literal `USER` token wherever shell expansion is unavailable (e.g.
inside markdown aggregates); shell scripts use `$USER`, `$HOME`,
`$env:USERNAME`, `$env:USERPROFILE`, etc. so resolution happens at
runtime. The only other user-related identifier permitted in the
codebase is `mios` / `MiOS`, the project's own brand and default
account name.

## Local trace

`API.md` in this repo tracks the served subset of the OpenAI surface
for the deployed LocalAI build. Verify any specific endpoint with
`GET /v1/models` against `MIOS_AI_ENDPOINT` before relying on it.

## Operating context

- **cwd:** `/` is the repo root and the deployed system root.
- **Confirm before:** `git push`, `bootc upgrade`, `dnf install`,
  `systemctl`, `rm -rf`.
- **Deliverables:** complete replacement files only.
- **Memory:** `/var/lib/mios/ai/memory/`
- **Scratch:** `/var/lib/mios/ai/scratch/`
