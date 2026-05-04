# CLAUDE.md

> Agent entry point (un-labeled). The locally hosted MiOS AI models
> orchestrate all work in this stack; any external agent CLI that
> discovers this file routes through the same OpenAI-API-compatible
> endpoint those models serve. Strict adherence to OpenAI API
> standards and patterns -- no vendor branding, no vendor-native
> protocols, no proprietary side-channels.

'MiOS' targets the OpenAI public API surface at
`MIOS_AI_ENDPOINT=http://localhost:8080/v1` (Architectural Law 5:
UNIFIED-AI-REDIRECTS). The locally hosted models behind that endpoint
are the orchestrators of every task in this codebase. External agents
defer to them: they resolve the same canonical prompt and call the
same OpenAI-shaped endpoint regardless of which repo, IDE, or CLI
they were invoked from.

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

## Working inside mios-bootstrap.git (this repo)

The notes below apply when an agent is editing `mios-bootstrap.git`
itself, as opposed to operating on a deployed MiOS host.

### What this whole stack is

A shell around the locally hosted OpenAI-API-compatible AI surface
(`MIOS_AI_ENDPOINT=http://localhost:8080/v1`, files under
`/usr/share/mios/ai/`) plus FHS-compliant account, dotfile, and
folder handling. The installer scripts do not invent OS conventions;
they bind the user's identity, dotfiles, and AI prompt overlays into
the standard FHS locations (`/etc/`, `/usr/share/`, `/var/lib/`,
`/etc/skel/`, `~/.config/`) and let the OpenAI-shaped AI files do the
work. Every change must preserve FHS compliance and leave the AI
surface OpenAI-API-compatible.

### Repo split (load-bearing)

- `mios.git` -- system layer: Containerfile, automation, FHS overlay
  baked into the OCI image, `usr/share/mios/PACKAGES.md` (RPM SSOT).
- `mios-bootstrap.git` (here) -- user/AI layer: entry-point scripts,
  `etc/mios/`, `etc/skel/`, `usr/share/mios/ai/`, knowledge graphs,
  canonical `mios.toml`.

Both repos resolve to the same `/` on a deployed host; `.gitignore`
in each partitions ownership. Never double-track a path.

### Two-repo merge: tmp staging, then safe overlay

The Phase-1 "Total Root Merge" never writes directly to `/`. Both
repo trees are staged into a tmp working tree first, the merged
overlay is built there, and only the resolved tree is copied over
the live root. This keeps the host recoverable if a fetch or merge
step fails mid-flight, and keeps the operation FHS-compliant
end-to-end (no half-applied state in `/etc`, `/usr`, or `/var`).

### Canonical entry points

| Script | Purpose |
|---|---|
| `build-mios.sh`  | Linux/Fedora installer (Phase-0..4 orchestrator) |
| `build-mios.ps1` | Windows installer (Podman Desktop + WSL2 builder) |
| `Get-MiOS.ps1`   | Windows `irm \| iex` wrapper that clones + launches `build-mios.ps1` |
| `bootstrap.{sh,ps1}`, `install.{sh,ps1}` | Legacy redirector stubs -> `build-mios.{sh,ps1}` |

Don't add logic to the redirector stubs.

### Phases

- Phase-0: preflight, profile load, identity capture
- Phase-1: tmp-staged Total Root Merge of `mios.git` + this repo's
  overlays, then safe copy onto `/`
- Phase-2: build (FHS: `dnf install` from `PACKAGES.md`; bootc:
  `bootc switch ghcr.io/mios-dev/mios:latest`)
- Phase-3: `systemd-sysusers`, `systemd-tmpfiles`, daemon-reload,
  account creation, `/etc/skel/.config/mios/` seeded into every
  uid >= 1000 home
- Phase-4: reboot prompt

### FHS-compliant account + folder handling

- Accounts created via `useradd`, supplementary groups from
  `[identity].groups` in `mios.toml`, password piped to `chpasswd`
  (never written to disk).
- Per-user dotfiles seeded from `/etc/skel/.config/mios/` -- both at
  account creation and on every install re-run via
  `seed_user_skel_for_all_accounts` (idempotent, covers every
  uid >= 1000).
- Host state: `/etc/mios/install.env` (0640), `/etc/mios/mios.toml`
  (0644), generated SSH keys at `~user/.ssh/id_*` (0600).

### One config file: `mios.toml` (three-layer overlay)

```
~/.config/mios/mios.toml         per-user  (highest)
/etc/mios/mios.toml              host-local (staged from this repo)
/usr/share/mios/mios.toml        vendor (baked from mios.git, lowest)
```

Resolver: `tools/lib/userenv.sh` in `mios.git`. Empty strings in
higher layers do NOT override non-empty values below them. Legacy
`etc/mios/profile.toml` is still recognized -- keep that fallback.

Secrets (`password_hash`, `luks_passphrase`, `github_pat`) are never
tracked; bootstrap writes them to root-owned mode-0600 files outside
this profile.

### AI surface invariants (Architectural Law 5)

- The locally hosted models behind `MIOS_AI_ENDPOINT` are the
  orchestrators of every task in this codebase. External agent CLIs
  (Claude, Gemini, Cursor, aichat, etc.) defer to them via the
  OpenAI-compatible endpoint -- they do not bypass it and they do
  not orchestrate independently.
- All clients resolve through `MIOS_AI_ENDPOINT`. No vendor-hardcoded
  URLs, no vendor-native protocols, no proprietary side-channels
  anywhere in this codebase.
- The served API mirrors the OpenAI public spec at
  `https://platform.openai.com/docs/api-reference` -- chat completions,
  responses, embeddings, function calling, structured outputs, all
  under `/v1`. Diverge only where LocalAI does, and document it in
  `API.md`.
- System prompt resolution:
  `$MIOS_AI_SYSTEM_PROMPT` -> `~/.config/mios/system-prompt.md`
  -> `/etc/mios/ai/system-prompt.md` -> `/usr/share/mios/ai/system.md`.

### Idempotency invariant

Every install function must be safe to re-run. Existing users get
amended (not recreated); existing SSH keys are not overwritten by
the `generate` path; skel seeding re-runs every install.

### Testing

No formal test suite. Validate with `bash -n build-mios.sh` /
`shellcheck`, `pwsh -NoProfile` parse-check on `build-mios.ps1`, and
end-to-end runs on a throwaway VM with `MIOS_PROMPT_TIMEOUT=1` and
`MIOS_AGREEMENT_BANNER=quiet`.
