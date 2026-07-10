# MiOS Bootstrap & Installation Guide

This guide contains the detailed bootstrap steps, self-development workflows, build phases, setup commands, and file layouts for the `mios-bootstrap` installation layer.

## 1. Day-0 — Windows entry (thin shell only)

The Windows entry point is **strictly an entry point** — it provisions and hands off; it does NOT build. The build runs inside MiOS-DEV.

```text
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/Get-MiOS.ps1 | iex"
```

The contract is **one paste, one shot, no follow-up step required.**

`Get-MiOS.ps1` does *all* of the following before handing off:

1. **Self-cache-busts** at the top — Fastly's 5-min TTL on `raw.githubusercontent.com` is invisible; every paste pulls fresh.
2. **Full reset** — reaps prior MiOS state: temp clones, persistent clones, WSL distros (`MiOS`, `MiOS-DEV`, `podman-MiOS-DEV`, `MiOS-BUILDER`), podman machines, Hyper-V `MiOS-*` VMs, install dirs (`M:\MiOS`, `C:\MiOS`, `%PROGRAMDATA%\MiOS`), Start Menu shortcuts, uninstall registry key. **No partial state, no carry-over.**
3. **Force-clones to TEMP** — first stage runs from `$env:TEMP\mios-bootstrap-<rand>`. (Carve-out: when *already inside* MiOS-DEV, the live `/` is the working tree.)
4. **Two-pass self-elevation** — Pass 1 (user) installs Windows Terminal + MiOS scheme, Geist Mono Nerd Font, oh-my-posh, fastfetch, MiOS native-app shortcut. Pass 2 (admin) provisions disk + machines.
5. **Provisions `M:\` at exactly 256 GB NTFS** (label `MIOS-DEV`). `shrink_mb = 262656` (256 GiB + 512 MB buffer) so Windows Explorer shows `M:\` as 256 GB. Junctions all candidate podman-machine storage paths (`%LOCALAPPDATA%\containers\podman\machine`, `%USERPROFILE%\.local\share\containers\podman\machine`, `%PROGRAMDATA%\containers\podman\machine`) onto `M:\podman\machine\*` **before** any `podman` command runs.
6. **Clones to `M:\`** — `git clone` of `mios.git` and `mios-bootstrap.git` to `M:\MiOS\repo\{mios,mios-bootstrap}`.
7. **Provisions Podman Desktop + the `MiOS-DEV` podman machine** with full parity: `podman-MiOS-DEV ≡ MiOS`. Achieved by `bootc switch localhost/mios:latest` + reboot at the end of `mios-build-driver`. Every layered RPM, every Quadlet container image (including the local inference lanes), every Flatpak, every served model baked into `mios-llm-light`, every systemd unit enabled. **No partial overlays.**
8. **Stops at MiOS-DEV-ready** — prints hint banner, returns. The build is **operator-triggered** by typing `mios build` in the WT MiOS profile.

### After `mios build`: SSH handoff into MiOS-DEV

Operator types `mios build` in the WT MiOS profile. From that point forward, **everything heavy runs inside MiOS-DEV via SSH** — this is the boundary where the user-facing installer hands the system over to the in-image build pipeline:

* MiOS-DEV does its own local fetch + overlay + installations
* MiOS-DEV brings itself inline with the expected MiOS OCI image(s)
* The operator is prompted (inside MiOS-DEV) to confirm SSOT TOML selections — those selections are edited in the HTML configurator in a **local browser** (Epiphany on MiOS-DEV, rendered to Windows via WSLg + wayland/mutter window portal)
* Selections overlay onto MiOS-DEV's filesystem
* The full build pipeline kicks off, producing every image type and format MiOS targets.

The Windows-side bootstrap has NO business cloning the repos to a final location, prompting for identity, or running phases 4–8 on its own — those move into MiOS-DEV via the SSH handoff.

### The build dashboard

The dashboard renders in the **Windows-Terminal MiOS-DEV SSH window** (running locally on the podman-MiOS-DEV machine, displayed in the Windows terminal — *not* a streamed proxy). It combines the unified installation status output with `mios dash`:

* MiOS banner / header ASCII art
* fastfetch stats
* MiOS MOTD stats

`mios.bat` is an equivalent shortcut: `WinKey+R` → `mios.bat` invokes the same `irm | iex` one-liner with cache-bust appended (`?cb=<unix-time>`) and self-elevates via `cmd`'s `net session` probe. The `irm | iex` shape is the contract; the `.bat` is one wrapper.

**Terminal dimensions:** every spawned window opens at exactly 80 cols × 40 rows (`wt.exe --size 80,40`, `[Console]::SetWindowSize(80,40)`, `stty cols 80 rows 40`).

---

## 2. Day-N — Self-development loop

Once Day-0 has produced a booted MiOS host, the system can rebuild itself. This is the "self-replicating" half: editing `/` on a running MiOS box edits the source, and the next `bootc upgrade` bakes it. The loop runs inside MiOS-DEV (or any Fedora-bootc-capable host):

1. Boot any Fedora-based machine that can be installed to (or already inside MiOS-DEV)
2. `curl | bash` the bootstrap URL (or `irm | iex` on Windows)
3. Acknowledgements
4. **SSOT TOML/HTML prompt** — operator edits `mios.toml` via `mios.html` in a local browser (Epiphany via WSLg + wayland/mutter on Windows)
5. Save selections to overlay files
6. Overlay the local system with all MiOS packages + dependencies
7. Pull remaining repo files
8. Complete installations + overlays
9. **Develop directly inside MiOS-DEV.** Dev environment is OpenAI-API-compatible only and routes through `MIOS_AI_ENDPOINT`. Repo files materialized from every source.
10. Iterate, commit, push — **dual-push:** local Forgejo (`http://mios@localhost:3000/mios/mios.git`) AND/OR GitHub (`origin main`)
11. Push triggers CI/CD: Forgejo Runner OR GitHub Actions builds `MiOS(NON-DEV)`
12. Test deployments locally for ALL formats
13. Debug → repeat
14. Pull latest at MiOS-DEV's root (`git -C / pull`); re-overlay
15. Loop — back to step 2, now at Day-N+1

**`.git` IS `/` is the load-bearing premise.** Edits to `/` are edits to the source. The next boot IS the edit.

```bash
# Linux entry
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mios-dev/mios-bootstrap/main/build-mios.sh)"
```

Each interactive prompt auto-accepts the resolved-from-`mios.toml` default after **90 seconds** idle. Override with `MIOS_PROMPT_TIMEOUT=` (seconds; `0` waits forever, `1` is the fastest unattended setting).

---

## 3. Build artifact matrix

The same OCI image is cut into deployment-shape outputs for ALL of — so a single immutable image lands on whatever substrate the operator runs:

* **Hyper-V** — `.vhdx` + `.ps1` launcher
* **WSL2/g** — `.tar` / `.vhdx` with WSLg windowing
* **QEMU** — `qcow2`
* **OCI image** — canonical bootc surface
* **Live-CD / Live-USB**
* **USB installer** — Anaconda / coreos-installer
* **RAW disk image** — `dd`-able

Build outputs land on `M:\` (the operator-chosen data partition by default per `env.defaults`), NEVER under `%LOCALAPPDATA%`.

---

## 4. Phase model (0..4)

This is the installer's view of the lifecycle; the OCI image it produces is then deployed by `bootc switch`/`upgrade` and reverted by `bootc rollback`.

| Phase | Owner | Purpose |
|---|---|---|
| Phase-0 | `mios-bootstrap` | Preflight, profile load (3-layer overlay), interactive identity capture |
| Phase-1 | `mios-bootstrap` | Total Root Merge — clone `mios.git` into `/`, overlay `etc/`, `usr/`, `var/` |
| Phase-2 | `mios` | Build — `dnf install` from `mios.toml [packages]` SSOT, OR `bootc switch ghcr.io/mios-dev/mios:latest` |
| Phase-3 | both | `systemd-sysusers` + `systemd-tmpfiles` + `daemon-reload` + services + per-user `~/.config/mios/{profile.toml,system-prompt.md}` staging |
| Phase-4 | `mios-bootstrap` | Reboot |

The 11-phase pipeline in `mios.git` (`mios-pipeline.{sh,ps1}`) is the finer-grained orchestrator that bootstrap calls into for Phase-2+. Inside Phase-2, numbered `automation/NN-name.sh` scripts run in numeric order; the prefix encodes dependency order. The scripts that stand up the AI plane (the inference lanes, the agent units, the pgvector schema) are just more numbered steps — the same mechanism that installs packages also stands up the brain.

---

## 5. Two Windows Terminal profiles

| Profile | `commandline` | Notes |
|---|---|---|
| **MiOS** | `pwsh.exe` → MiOS PS profile body (dashboard + `mios <verb>` dispatcher) | Verbs: `dash`, `config`, `update`, `pull`, `help` → Windows host; `build`, `dev` → pass through to dev VM via `wsl.exe`. |
| **MiOS-DEV** | `wsl.exe -d <BuilderDistro> --user mios` | Direct dev-VM shell. |

**Don't bind the MiOS profile to `wsl.exe` directly** — that hits `WSL_E_DISTRO_NOT_FOUND` when the distro name doesn't match. Distro names are locked: `MIOS_WSL_DISTRO=MiOS`, `MIOS_BUILDER_DISTRO=MiOS-DEV`. Podman derives `podman-MiOS-DEV` from these; renaming breaks `podman machine` discovery.

---

## 6. Setup commands

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

---

## 7. Where things live (this repo)

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

---

## 8. What gets persisted on a deployed host

* `/etc/mios/install.env` — non-secret installation metadata (mode 0640)
* `/etc/mios/profile.toml` — user-edit overlay (writable; preserved across `bootc upgrade`)
* `/etc/mios/ai/system-prompt.md` — host AI prompt
* `~/.config/mios/profile.toml` (per user) — per-user overlay
* `~/.config/mios/system-prompt.md` (per user) — per-user AI prompt
* `~mios/.ssh/id_ed25519` — generated SSH key (mode 0600)
* `~mios/.git-credentials` — only if a GitHub PAT was provided (mode 0600)

Passwords are piped to `chpasswd` and **never written to disk in plaintext**.
