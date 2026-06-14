<!-- AI-hint: The primary entry point and source of truth for all AI agents in mios-bootstrap — the interactive installer + user-editable layer of MiOS. Defines the project identity, the whole-system context (immutable bootc/OCI Fedora workstation that is also a local self-replicating agentic AI OS), OpenAI-compatible interface standards, and this repo's role as the user-facing installer surface that drives the build pipeline into a deployed image.
     AI-related: /etc/mios/profile.toml, /usr/share/mios/profile.toml, /usr/share/mios/ai/system.md, /etc/mios/ai/system-prompt.md, /usr/share/mios/ai/, /usr/share/mios/mios.toml, /usr/share/mios/llamacpp/llama-swap.yaml, /etc/mios/install.env, mios-bootstrap, mios-dev, mios-pipeline, mios-pull, mios-llm-light, mios-pgvector -->
# AGENTS.md

> Canonical agent entry point for `mios-bootstrap.git` — the interactive
> installer + user-editable layer for MiOS. Follows the [agents.md][1]
> standard and is the SSOT for any agent CLI that arrives at this repo.
> Per-tool stubs (`CLAUDE.md`, `GEMINI.md`, `.cursorrules`, `.clinerules`,
> `system-prompt.md`) are thin redirectors that defer here.
>
> **Strict OpenAI API standards and patterns ONLY.** Every interface is
> OpenAI-API-compatible verb-for-verb. No vendor-native protocols, no
> proprietary side-channels, no fallback to vendor-cloud URLs, no
> vendor-specific agent / dev-tool product references in any AI file.
>
> **System repo:** <https://github.com/mios-dev/mios> — that's where
> the FHS overlay, Containerfile, automation scripts, and the six
> Architectural Laws live. This repo is the *user-facing entry surface*.
>
> [1]: https://agents.md

## 0. What MiOS is (so this repo's job makes sense)

MiOS is one thing built two ways at once: an **immutable, bootc/OCI-shaped
Fedora workstation** (the whole OS is a single container image — boot it,
`bootc upgrade` it like a `git pull`, `bootc rollback` it like a Ctrl-Z) that
is *also* a **local, self-replicating, agentic AI operating system**. The same
image that ships GNOME/Wayland, NVIDIA + ROCm + Intel iGPU via CDI, KVM/libvirt
with VFIO passthrough, and a k3s + Ceph one-node-cluster path also ships a full
local agent stack behind one OpenAI-compatible endpoint. The OS can reason about
itself, drive its own tools, and — because the whole thing is one rebuildable
OCI image — effectively re-create itself.

The system's lifecycle is a single throughline: **installer (this repo) →
build pipeline → OCI image → bootc lifecycle on the host.** `mios.git` is the
FHS overlay that gets baked into the image; `mios-bootstrap.git` (this repo) is
the user-facing entry surface that captures the operator's choices, performs the
Total Root Merge, drives the build, and hands a deployed, self-developing host
back to the operator. Everything below describes *this repo's* slice of that
whole: how a paste on Windows or a `curl | bash` on Linux becomes a booted,
agentic MiOS host that can then rebuild itself.

## 1. Repo identity

* **Project:** MiOS — pronounced *MyOS* (short for *My OS*). Research project,
  Apache-2.0. Generative: synthesized from seed scripts + curated docs, then
  expanded under human review.
* **Role:** interactive installer (Phase 0..4) and user-editable layer
  of the three-layer profile model (vendor < host < user). The *entry surface*
  for the build-pipeline → image → bootc lifecycle.
* **Version:** see `VERSION` (top-level).
* **Owns:** AI files (`usr/share/mios/ai/`), knowledge graphs, user
  profile templates, installer scripts (`Get-MiOS.ps1`,
  `bootstrap.{sh,ps1}`, `install.{sh,ps1}`, `build-mios.{sh,ps1}`,
  `seed-merge.{sh,ps1}`).
* **Does NOT own:** `Containerfile`, FHS system overlay, systemd units,
  Quadlet sidecars, kernel args, tmpfiles, sysusers — those live in
  `mios.git`. **Never double-track paths across the two repos.**

## 2. The three project-wide laws (this repo's slice)

These three are the installer-repo restatement of the system contract. The
full **six Architectural Laws** (USR-OVER-ETC, NO-MKDIR-IN-VAR, BOUND-IMAGES,
BOOTC-CONTAINER-LINT, UNIFIED-AI-REDIRECTS, UNPRIVILEGED-QUADLETS) are enforced
at build/lint time in `mios.git`; see §11 for Law 5, the one this layer touches
directly.

1. **Native Linux FHS folder structuring.** Files live where the
   Filesystem Hierarchy Standard says they live. Bootstrap files
   mirror those destinations even at this repo's root. (Aligns with the
   system's USR-OVER-ETC / NO-MKDIR-IN-VAR laws — static config in `/usr`,
   `/etc` for overrides only, `/var` declared via tmpfiles.)
2. **OpenAI API standards FULLY.** Every agent / model / tool surface
   is OpenAI-API-compatible: `/v1/chat/completions`, `/v1/responses`,
   `/v1/embeddings`, `/v1/models`, function-calling, structured
   outputs, MCP via the Responses API. **No vendor-specific
   agent / dev-tool product references in any AI file.** (This is the
   user-facing face of the system's UNIFIED-AI-REDIRECTS law.)
3. **MiOS is a root filesystem overlay; `.git` IS `/`.** Bootstrap is
   what *makes* `.git` equal `/` on a target host. The Total Root
   Merge in Phase-1 clones `mios.git` into `/` and overlays this
   repo's `etc/`, `usr/`, `var/` on top. The next boot IS the edit — the
   premise that makes MiOS self-developing.

## 3. `mios.toml` is THE singular SSOT

**`mios.toml` is the singular file that runs the entire pipeline.** It
is the **library of every verb, variable, and value** the codebase
consumes — packages, ports, AI inference lanes, services, agent behaviour,
identity, theme. Edited as HTML in a local browser by the defined user, saved
locally, and fetched by the pipeline. This is how an operator's choices reach
every downstream step of the build → image → bootc chain without a single
hardcoded literal.

### What the TOML carries (inline)

* **Packages** — RPMs, Flatpaks, OCI images, layered package sets per
  deployment shape (`[packages.<section>].pkgs`)
* **Dependencies** — every transitive requirement
* **Repositories** — GitHub remotes, local Forgejo URL, OCI registries,
  upstream git mirrors
* **Applications** — every layered Quadlet container, every Flatpak
  desktop app, every native window app
* **Tools** — CLI surfaces, helper scripts, dev tools
* **Settings** — every operator-tunable knob across the entire stack
* **Username / Linux account** — uid 1000 `mios` user, full credentials
  pipeline (`[identity]`, `[auth]`)
* **Color palette** — globally applied, **platform-agnostically**,
  across every terminal and console (Windows Terminal, conhost,
  GNOME Terminal, tmux, MOTD, fastfetch, oh-my-posh, dashboard
  borders, configurator HTML `:root`)
* **Extras / bloat / optional** — operator-toggled add-ons
* **Passwords + credentials** — operator-set, persisted only in the
  TOML overlay (never round-tripped through `install.env`'s readable
  bridge for secret keys)
* **Quadlets** — `[quadlets.enable]` table + per-Quadlet parameters
* **User preferences** — theme, terminal dims (80×40), locale,
  keyboard, timezone

### The edit-save-fetch lifecycle

1. **Edit:** operator opens `mios.html` in a **local browser**.
   No server, no extension, no install step. `file://` is fine.
2. **Save:** the configurator writes the updated TOML to disk.
   On Windows: `%USERPROFILE%\Downloads\mios.toml` (browsers can't
   write back to `file://`). On Linux: in-place to
   `~/.config/mios/mios.toml`.
3. **Fetch:** the pipeline (`mios build` on Windows, `mios-pipeline.sh`
   on Linux) reads the TOML from the layered overlay and uses it to
   drive every downstream step.
4. **Overlay/install:** TOML selections bake into the overlay
   **before** installation. No mid-install prompts that bypass the
   TOML.

The Windows `mios build` verb specifically promotes the newest
`mios*.toml` from `%USERPROFILE%\Downloads` to `M:\etc\mios` +
`M:\usr\share\mios` and archives the source as
`.imported-<timestamp>` BEFORE running `mios-pull --hard` so operator
edits aren't clobbered.

### Resolution layers (highest first)

```
~/.config/mios/profile.toml      # per-user (highest, seeded from /etc/skel)
/etc/mios/profile.toml           # host
/usr/share/mios/profile.toml     # vendor (lowest, always present)
```

`install.sh:resolve_profile_layers` walks all three at install time
and field-level overlays them into the runtime defaults. **User-set
fields in higher layers win. Empty strings do NOT override non-empty
values below them.**

**Empty / missing user TOML is the vendor-default state, not an error.**
**Hardcoded values that could live in `mios.toml` are bugs** — lift
them, expose them in the HTML configurator, then read them from the
layered overlay.

## 4. Day-0 — Windows entry (thin shell only)

The Windows entry point is **strictly an entry point** — it provisions and
hands off; it does NOT build. The build runs inside MiOS-DEV (§4 handoff).

```text
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex"
```

The contract is **one paste, one shot, no follow-up step required.**

`Get-MiOS.ps1` does *all* of the following before handing off:

1. **Self-cache-busts** at the top — Fastly's 5-min TTL on
   `raw.githubusercontent.com` is invisible; every paste pulls fresh.
2. **Full reset** — reaps prior MiOS state: temp clones, persistent
   clones, WSL distros (`MiOS`, `MiOS-DEV`, `podman-MiOS-DEV`,
   `MiOS-BUILDER`), podman machines, Hyper-V `MiOS-*` VMs, install
   dirs (`M:\MiOS`, `C:\MiOS`, `%PROGRAMDATA%\MiOS`), Start Menu
   shortcuts, uninstall registry key. **No partial state, no
   carry-over.**
3. **Force-clones to TEMP** — first stage runs from
   `$env:TEMP\mios-bootstrap-<rand>`. (Carve-out: when *already
   inside* MiOS-DEV, the live `/` is the working tree per Law 3.)
4. **Two-pass self-elevation** — Pass 1 (user) installs Windows
   Terminal + MiOS scheme, Geist Mono Nerd Font, oh-my-posh,
   fastfetch, MiOS native-app shortcut. Pass 2 (admin) provisions
   disk + machines.
5. **Provisions `M:\` at exactly 256 GB NTFS** (label `MIOS-DEV`).
   `shrink_mb = 262656` (256 GiB + 512 MB buffer) so Windows Explorer
   shows `M:\` as 256 GB (NTFS reserves ~16 MB for boot sector / $MFT).
   Junctions all candidate podman-machine storage paths
   (`%LOCALAPPDATA%\containers\podman\machine`,
   `%USERPROFILE%\.local\share\containers\podman\machine`,
   `%PROGRAMDATA%\containers\podman\machine`) onto
   `M:\podman\machine\*` **before** any `podman` command runs.
6. **Clones to `M:\`** — `git clone` of `mios.git` and
   `mios-bootstrap.git` to `M:\MiOS\repo\{mios,mios-bootstrap}`.
7. **Provisions Podman Desktop + the `MiOS-DEV` podman machine** with
   full parity: `podman-MiOS-DEV ≡ MiOS`. Achieved by `bootc switch
   localhost/mios:latest` + reboot at the end of `mios-build-driver`.
   Every layered RPM, every Quadlet container image (including the local
   inference lanes), every Flatpak, every served model baked into
   `mios-llm-light`, every systemd unit enabled. **No partial overlays.**
8. **Stops at MiOS-DEV-ready** — prints hint banner, returns. The
   build is **operator-triggered** by typing `mios build` in the WT
   MiOS profile.

### After `mios build`: SSH handoff into MiOS-DEV

Operator types `mios build` in the WT MiOS profile. From that point
forward, **everything heavy runs inside MiOS-DEV via SSH** — this is the
boundary where the user-facing installer hands the system over to the
in-image build pipeline:

* MiOS-DEV does its own local fetch + overlay + installations
* MiOS-DEV brings itself inline with the expected MiOS OCI image(s)
* The operator is prompted (inside MiOS-DEV) to confirm SSOT TOML
  selections — those selections are edited in the HTML configurator
  in a **local browser** (Epiphany on MiOS-DEV, rendered to Windows
  via WSLg + wayland/mutter window portal)
* Selections overlay onto MiOS-DEV's filesystem
* The full build pipeline kicks off, producing every image type and
  format MiOS targets (see §6)

The Windows-side bootstrap has NO business cloning the repos to a
final location, prompting for identity, or running phases 4–8 on its
own — those move into MiOS-DEV via the SSH handoff.

### The build dashboard

The dashboard renders in the **Windows-Terminal MiOS-DEV SSH window**
(running locally on the podman-MiOS-DEV machine, displayed in the
Windows terminal — *not* a streamed proxy). It combines the unified
installation status output with `mios dash`:

* MiOS banner / header ASCII art
* fastfetch stats
* MiOS MOTD stats

`mios.bat` is an equivalent shortcut: `WinKey+R` → `mios.bat` invokes
the same `irm | iex` one-liner with cache-bust appended (`?cb=<unix-time>`)
and self-elevates via `cmd`'s `net session` probe. The `irm | iex`
shape is the contract; the `.bat` is one wrapper.

**Terminal dimensions:** every spawned window opens at exactly
80 cols × 40 rows (`wt.exe --size 80,40`,
`[Console]::SetWindowSize(80,40)`, `stty cols 80 rows 40`).

## 5. Day-N — Self-development loop

Once Day-0 has produced a booted MiOS host, the system can rebuild itself.
This is the "self-replicating" half: editing `/` on a running MiOS box edits
the source, and the next `bootc upgrade` bakes it. The loop runs inside
MiOS-DEV (or any Fedora-bootc-capable host):

1. Boot any Fedora-based machine that can be installed to (or already
   inside MiOS-DEV)
2. `curl | bash` the bootstrap URL (or `irm | iex` on Windows)
3. Acknowledgements
4. **SSOT TOML/HTML prompt** — operator edits `mios.toml` via
   `mios.html` in a local browser (Epiphany via WSLg + wayland/mutter
   on Windows)
5. Save selections to overlay files
6. Overlay the local system with all MiOS packages + dependencies
7. Pull remaining repo files
8. Complete installations + overlays
9. **Develop directly inside MiOS-DEV.** Dev environment is
   OpenAI-API-compatible only and routes through `MIOS_AI_ENDPOINT`
   (the one local endpoint — see §11). Repo files materialized from
   every source.
10. Iterate, commit, push — **dual-push:** local Forgejo
    (`http://mios@localhost:3000/mios/mios.git`) AND/OR GitHub
    (`origin main`)
11. Push triggers CI/CD: Forgejo Runner OR GitHub Actions builds
    `MiOS(NON-DEV)`
12. Test deployments locally for ALL formats (see §6)
13. Debug → repeat
14. Pull latest at MiOS-DEV's root (`git -C / pull`); re-overlay
15. Loop — back to step 2, now at Day-N+1

**`.git` IS `/` is the load-bearing premise.** Edits to `/` are edits
to the source. The next boot IS the edit.

```bash
# Linux entry
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/build-mios.sh)"
```

Each interactive prompt auto-accepts the resolved-from-`mios.toml`
default after **90 seconds** idle. Override with
`MIOS_PROMPT_TIMEOUT=` (seconds; `0` waits forever, `1` is the fastest
unattended setting).

## 6. Build artifact matrix

The same OCI image is cut into deployment-shape outputs for ALL of — so a
single immutable image lands on whatever substrate the operator runs:

* **Hyper-V** — `.vhdx` + `.ps1` launcher
* **WSL2/g** — `.tar` / `.vhdx` with WSLg windowing
* **QEMU** — `qcow2`
* **OCI image** — canonical bootc surface
* **Live-CD / Live-USB**
* **USB installer** — Anaconda / coreos-installer
* **RAW disk image** — `dd`-able

Build outputs land on `M:\` (the operator-chosen data partition by
default per `env.defaults`), NEVER under `%LOCALAPPDATA%`.

## 7. Phase model (0..4)

This is the installer's view of the lifecycle; the OCI image it produces is
then deployed by `bootc switch`/`upgrade` and reverted by `bootc rollback`.

| Phase | Owner | Purpose |
|---|---|---|
| Phase-0 | `mios-bootstrap` | Preflight, profile load (3-layer overlay), interactive identity capture |
| Phase-1 | `mios-bootstrap` | Total Root Merge — clone `mios.git` into `/`, overlay `etc/`, `usr/`, `var/` |
| Phase-2 | `mios` | Build — `dnf install` from `mios.toml [packages]` SSOT, OR `bootc switch ghcr.io/mios-dev/mios:latest` |
| Phase-3 | both | `systemd-sysusers` + `systemd-tmpfiles` + `daemon-reload` + services + per-user `~/.config/mios/{profile.toml,system-prompt.md}` staging |
| Phase-4 | `mios-bootstrap` | Reboot |

The 11-phase pipeline in `mios.git` (`mios-pipeline.{sh,ps1}`) is the
finer-grained orchestrator that bootstrap calls into for Phase-2+. Inside
Phase-2, numbered `automation/NN-name.sh` scripts run in numeric order; the
prefix encodes dependency order. The scripts that stand up the AI plane (the
inference lanes, the agent units, the pgvector schema) are just more numbered
steps — the same mechanism that installs packages also stands up the brain.

## 8. Two Windows Terminal profiles

| Profile | `commandline` | Notes |
|---|---|---|
| **MiOS** | `pwsh.exe` → MiOS PS profile body (dashboard + `mios <verb>` dispatcher) | Verbs: `dash`, `config`, `update`, `pull`, `help` → Windows host; `build`, `dev` → pass through to dev VM via `wsl.exe`. |
| **MiOS-DEV** | `wsl.exe -d <BuilderDistro> --user mios` | Direct dev-VM shell. |

**Don't bind the MiOS profile to `wsl.exe` directly** — that hits
`WSL_E_DISTRO_NOT_FOUND` when the distro name doesn't match. Distro
names are locked: `MIOS_WSL_DISTRO=MiOS`,
`MIOS_BUILDER_DISTRO=MiOS-DEV`. Podman derives `podman-MiOS-DEV` from
these; renaming breaks `podman machine` discovery.

## 9. MiOS-DEV ≡ MiOS

MiOS-DEV is the **source upon which MiOS itself is based** — testbed
AND substrate. It mirrors the layered Quadlet container surface that
ships in production MiOS, so the build pipeline's tests and the
self-development workflow have the full runtime surface available.
Representative Quadlet units under `usr/share/containers/systemd/`:

* `mios-llm-light` — the **primary** local inference lane (llama.cpp behind
  the `llama-swap` proxy image, `:11450`; also serves embeddings via
  `nomic-embed-text`)
* `mios-llm-heavy` / `mios-llm-heavy-alt` — gated heavy GPU lanes (SGLang on
  `:11441` served-name `mios-heavy`; vLLM alternate). Off by default on VRAM
  grounds
* `mios-pgvector` — PostgreSQL + pgvector, the unified agent datastore
  (`:5432`)
* `mios-open-webui` — Open WebUI browser front-end (`:3030`)
* `mios-searxng` — SearXNG metasearch backing `web_search` (`:8888`)
* `mios-guacamole` (with `mios-guacd`, `mios-guacamole-postgres`) — browser
  desktop
* `mios-forge` / `mios-forgejo-runner` — local git forge + CI runner
* `mios-cockpit-link`, `mios-code-server`, the `mios-webtools-*` pod,
  `mios-adguard`, `mios-crowdsec-dashboard`, and the `mios-k3s` / `mios-ceph`
  cluster path
* (every Quadlet under `usr/share/containers/systemd/`)

The MiOS-Hermes gateway (`:8642`), the agent-pipe orchestrator (`:8640`), the
delegation prefilter (`:8641`), and the opencode `/v1` gateway (`:8633`) run as
service units alongside these containers (see §11). MiOS-DEV needs the `mios`
user appended (uid 1000, the same login user the production image ships) so the
same per-user configs and rootless podman behaviors carry across.

## 10. Loading order (system prompt)

This file (AGENTS.md) is the agents.md-standard repo entry. The runtime
LLM system prompt is `/usr/share/mios/ai/system.md`. Bootstrap deploys
this repo's `system-prompt.md` to `/etc/mios/ai/system-prompt.md`; the
local agent stack loads it for chat completions.

1. `~/.config/mios/system-prompt.md` — per-user override
2. `/etc/mios/ai/system-prompt.md` — host/admin override (deployed by
   bootstrap)
3. `/usr/share/mios/ai/system.md` — vendor canonical (lowest, from
   `mios.git`)

## 11. Endpoint contract (OpenAI-compatible)

Architectural Law 5 (**UNIFIED-AI-REDIRECTS**) — every OpenAI-API-shaped
client on the system resolves through `MIOS_AI_ENDPOINT`
(default `http://localhost:8080/v1`), `MIOS_AI_MODEL`, `MIOS_AI_KEY`.
**No vendor-cloud URLs. No vendor-specific agent / dev-tool product names
anywhere.** This is what lets any OpenAI-API-compatible editor/CLI client
talk to the same local brain with no vendor lock-in.

Behind that one endpoint is the local agent stack (verify ports against the
units / `mios.toml`):

* **agent-pipe** (`:8640`) — standalone orchestrator: router + refine +
  council/swarm fan-out + critic/polish; fronts Hermes for every gateway.
* **MiOS-Hermes** (`:8642`) — OpenAI-compatible agent gateway: sessions,
  tool-loop, skills, browser/CDP control.
* **prefilter** (`:8641`) — injects fan-out hints on decomposable prompts,
  forwards to Hermes.
* **mios-llm-light** (`:11450`) — **primary** inference lane: llama.cpp behind
  the upstream `llama-swap` proxy image (`ghcr.io/mostlygeek/llama-swap`),
  multi-model auto-swap + KV-cache paging; serves everyday models, the
  `mios-opencode` coder model, **and embeddings** (`nomic-embed-text`,
  OpenAI-compat `/v1/embeddings`). Model map:
  `usr/share/mios/llamacpp/llama-swap.yaml`.
* **mios-llm-heavy** (`:11441`, served-name `mios-heavy`) / **mios-llm-heavy-alt**
  — gated heavy GPU lanes (SGLang / vLLM), off by default on VRAM grounds.
* **opencode-gateway** (`:8633`) — opencode → OpenAI `/v1` shim; a real `/v1`
  council peer (loopback).
* **OWUI** (`:3030`) — Open WebUI front-end; **SearXNG** (`:8888`) backs
  `web_search`.
* **pgvector** (`:5432`) — PostgreSQL + pgvector, the unified agent datastore
  (agent memory, events, tool calls, sessions, skills, scratch, knowledge with
  vector recall, …).

The engines speak the OpenAI/Ollama-compatible API, so any OpenAI-API client
talks to them unchanged — `llama-swap` and that wire-compat API are the only
legitimate upstream references; the MiOS *unit identity* is `mios-llm-light`.
The throughline: **inference lanes → agent-pipe/Hermes orchestration →
pgvector memory → MCP (tools) / A2A (agents)**, all behind `MIOS_AI_ENDPOINT`.

## 12. Setup commands

```powershell
# Windows — canonical irm|iex from Win+R
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex"
```

```powershell
# After bootstrap, on the Windows host
mios dash      # dashboard
mios config    # open configurator HTML in a local browser
mios update    # pull latest mios.git + mios-bootstrap
mios build     # promote Downloads edits, SSH into MiOS-DEV, ignite build
mios dev       # drop into MiOS-DEV shell
mios help      # verb list
```

```bash
# Linux — canonical curl|bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/build-mios.sh)"
```

## 13. Operating rules for agents

* **cwd:** `/` IS the deployed system root. Bootstrap repo files map
  to FHS destinations (`etc/` → `/etc/`, `usr/` → `/usr/`, etc.).
* **Deliverables:** complete replacement files only. No diffs, no
  patches, no `# ... rest unchanged ...` placeholders.
* **Tone:** direct, technical, no hedging qualifiers, no emoji unless
  the user asked. Ground every suggestion in a concrete FHS path with
  file:line.
* **OpenAI-API-only.** Never reference vendor-specific agent CLIs,
  dev-tool products, or cloud-AI URLs in MiOS docs / code / commit
  messages. The OpenAI public API surface is the only addressable
  contract.
* **TOML-first.** Before adding a constant to a script, check whether
  the value is operator-tunable. If yes, add it to `mios.toml`,
  expose it in the HTML configurator, then read it from the layered
  overlay.
* **Confirm before:** `git push`, `bootc switch`, `bootc upgrade`,
  `dnf install`, `systemctl daemon-reload`, `rm -rf` (especially against
  `.git` or working tree), `git reset --hard`, `git clean -fd`,
  `wsl --unregister`, `podman machine rm`, `Remove-Partition`,
  `Disable-WindowsOptionalFeature`.
* **MiOS-DEV is THE builder.** ALL build operations (`podman build`,
  BIB, `bootc switch`, manifest gen) run **inside** `podman-MiOS-DEV`.
  Windows side is provisioning + handoff ONLY. Don't write commit
  messages or comments that contradict this.
* **Latest packages and software.** Default to newest stable upstream
  when pinning RPMs / OCI tags / binaries / base images. Bump
  conservative pins forward on next touch unless held for a
  documented reason.
* **Every repo file is tracked, whitelisted, and pushed.** When
  generating any artifact in `mios` / `mios-bootstrap`, add a
  `.gitignore` whitelist line, stage, commit, push. Pulling latest
  must restore full context.
* **No double-tracking.** `mios.git` owns the system FHS overlay;
  `mios-bootstrap.git` owns the user-facing installer. Never
  cross-track paths.

## 14. Persistence sanitization

Anything persisted to `/var/lib/mios/ai/memory/` or
`/var/lib/mios/ai/scratch/` must be vendor-neutral:

* Strip vendor-specific names (model names, organization names,
  product names) unless the user asked for them.
* Drop chat metadata (`user-id`, `session-id`, `conversation-id`).
* Reduce all paths to FHS canonicals; resolve symlinks before writing.
* Never persist secrets (PATs, API keys, passphrases). If a tool call
  returned one in a previous turn, redact it before saving.

> The durable agent datastore is **PostgreSQL + pgvector** (`mios-pgvector`,
> `:5432`) — these on-disk paths are the lightweight episodic/scratch journals,
> not the primary store.

## 15. Where things live (this repo)

| File | Purpose |
|---|---|
| `Get-MiOS.ps1` | Canonical Windows entry — `irm \| iex` target. |
| `install.{sh,ps1}` | Phase-0..4 orchestrator. |
| `bootstrap.{sh,ps1}` | Lower-level bootstrap primitives. |
| `build-mios.{sh,ps1}` | Linux build entry (also a redirector for `install.sh`). |
| `seed-merge.{sh,ps1}` | Total Root Merge primitive (Phase-1). |
| `etc/mios/profile.toml` | Host-layer profile overlay (TOML). |
| `etc/skel/.config/mios/{profile.toml,system-prompt.md}` | Per-user templates seeded into every uid≥1000 home. |
| `usr/share/mios/ai/{system.md,models.json,mcp.json}` | Deployed AI assets (SSOT here, materialized to `/usr/share/mios/ai/` at install). |
| `usr/share/mios/knowledge/*` | RAG knowledge graphs. |
| `mios.toml` | This repo's reference `mios.toml`. |
| `system-prompt.md` | Host-layer prompt redirector. |
| `identity.env.example` | Operator identity template. |
| `image-versions.yml` | Pinned upstream image versions. |
| `llms.txt` | LLM ingest index. |

## 16. What gets persisted on a deployed host

* `/etc/mios/install.env` — non-secret installation metadata (mode 0640)
* `/etc/mios/profile.toml` — user-edit overlay (writable; preserved
  across `bootc upgrade`)
* `/etc/mios/ai/system-prompt.md` — host AI prompt
* `~/.config/mios/profile.toml` (per user) — per-user overlay
* `~/.config/mios/system-prompt.md` (per user) — per-user AI prompt
* `~mios/.ssh/id_ed25519` — generated SSH key (mode 0600)
* `~mios/.git-credentials` — only if a GitHub PAT was provided (mode 0600)

Passwords are piped to `chpasswd` and **never written to disk in
plaintext**.

## 17. Failure mode

When a question is outside MiOS scope or the data isn't available
locally, say so explicitly:

> *"I don't have that on this host; check `<concrete file or URL>`."*

Don't fabricate FHS paths. Don't invent endpoint URLs. **Don't name
vendor-specific agent or dev-tool products.** If unsure between two
valid sources, name both and let the operator choose.
