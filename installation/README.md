<!-- AI-hint: Usage + design reference for mios-install, the unified provisioning
     dispatcher that launches MiOS from ANY stage and targets a specific
     deployment TYPE (live / xbox / fedora / bootc / oci / seed / flash /
     build / update) by calling the EXISTING mios-bootstrap entrypoints with
     the right args -- it never moves, renames, or reimplements them.
     AI-related: installation/mios-install.ps1, installation/mios-install.sh,
     installation/mios-install.bat, installation/mios-common.ps1,
     installation/mios-common.sh, installation/UNIFY.md, cat/MiOS-Cat.bat, cat/MiOS-Cat.ps1,
     cat/MiOS-Cat.sh, build-mios.ps1, build-mios.sh, Get-MiOS.ps1,
     cat/autounattend/Build-MiOSXboxISO.ps1, cat/autounattend/New-MiOSISO.ps1,
     cat/autounattend/Deploy-MiOSXbox.ps1, cat/autounattend/Invoke-MiOSProvision.ps1,
     cat/autounattend/Build-MiOSSeed.ps1, mios-build, mios-update, mios.toml -->

# installation/ — the `mios-install` dispatcher

A **thin** cross-platform launcher that unifies every MiOS provisioning
entry point behind one CLI: pick a deployment **target**, optionally narrow
it to a **type** or jump straight to a **stage**, and `mios-install` builds
the right argv/env for the existing script and runs it.

**It does not replace anything.** Every file under `cat\`, `build-mios.ps1`,
`build-mios.sh`, and `Get-MiOS.ps1` stays exactly where it is, untouched.
`mios-install` adds the dispatcher (`mios-install.ps1`, `mios-install.sh`,
`mios-install.bat`), the shared `mios-common.{ps1,sh}` contract they source,
and this README. If you already know the entrypoint you want, calling it
directly still works — `mios-install` is a convenience funnel on top, not a
required layer.

**Run it with no target for the guided menu.** `mios-install` (no arguments)
opens an SSOT-themed, self-explaining menu: every target with what it does,
what it produces, what it costs, and what it needs — with a typed confirmation
before anything destructive. `mios-install configure` opens the MiOS Portal /
configurator (the one SSOT editor). And the web door reaches this same surface:
`… Get-MiOS.ps1 … -Action Install` (guided menu) / `-Action Configure` (Portal)
fetch the repo, then hand straight into `mios-install`. See
[UNIFY.md](UNIFY.md) for the full unification map.

## Contents

- `mios-install.ps1` — canonical Windows implementation. Full grammar,
  target table, `--dry-run`/`--unattended` logic. Self-elevates (UAC) only
  for targets that actually need Administrator (`live`, `flash`,
  `xbox --type vm`, `oci`) — same pattern as `cat\MiOS-Cat.ps1`.
- `mios-install.sh` — canonical Linux implementation. Same grammar; targets
  `fedora`, `bootc`, `build`, `update`, `flash` (via `cat\MiOS-Cat.sh`), and
  `live` run natively. Self-execs `sudo -E "$0" "$@"` only for targets that
  need root — the same convention `mios-build` / `mios-update` already use
  on an installed host.
- `mios-install.bat` — thin shim **only**: resolves `pwsh.exe` (falls back
  to `powershell.exe`), forwards `%*` to `mios-install.ps1` unchanged,
  mirrors `%ERRORLEVEL%`. This is the deliberate **inverse** of
  `cat\MiOS-Cat.bat`/`cat\MiOS-Cat.ps1`'s own convention — see
  "Why the .bat/.ps1 relationship looks backwards" below. Don't "fix" it to
  match MiOS-Cat.
- `mios-common.ps1` / `mios-common.sh` — the **one shared contract** both
  dispatchers source: the layered SSOT resolver (`Get-MiosSsotValue` /
  `mios_ssot_value`, `user > host > vendor`, mirroring
  `usr/lib/mios/mios_toml.py`), the SSOT-`[colors]` themed console/logger, one
  self-elevate, and one repo-fetch (`Ensure-MiosRepo` / `mios_ensure_repo`).
  This is what replaced the per-entrypoint copies of elevation / toml-resolve /
  theme. Other entrypoints migrate onto it incrementally (see UNIFY.md).
- `README.md` — this file. Human-readable target table + examples. The
  mapping data itself should not be hand-maintained twice — see
  "SSOT alignment" below.

## CLI grammar

```text
mios-install <target> [--type <name>] [--stage <name>] [--dry-run] [--unattended] [-- <native args>]
```

| Piece | Meaning |
|---|---|
| `<target>` | Required, positional. One of: `live`, `xbox`, `fedora`, `bootc`, `oci`, `seed`, `flash`, `build`, `update`, `configure`. Omit it entirely for the guided menu. |
| `--type <name>` | Narrows the target to a concrete flavor. Values are per-target — see the mapping table. Omit for the documented default. |
| `--stage <name>` | `prereqs \| fetch \| service \| iso \| flash` — jump into (or isolate) one point in the pipeline. See "The 5-stage funnel" below for what's real vs. best-effort per target. Omit to run the whole pipeline (every entrypoint's normal default behavior). |
| `--dry-run` | **Dispatcher-level only.** Prints the exact command line(s) and env vars `mios-install` *would* run, then exits 0. Nothing underneath is invoked. None of the 9 wrapped entrypoints has a native dry-run mode, so this is new behavior layered on top by the dispatcher, not a passed-through flag. |
| `--unattended` | Maps to whatever real non-interactive switch the chosen entrypoint already has (`-Unattended`, `NONINTERACTIVE=1`, `MIOS_PROMPT_TIMEOUT=1`, …). Where no such switch exists, `mios-install` says so and still runs interactively — it never fakes unattended-ness a script can't back up. |
| `-- <native args>` | Escape hatch. Everything after a literal `--` is appended **verbatim** to the underlying invocation. This is what keeps the dispatcher thin: long-tail flags (`-Edition`, `-Esd`, `-MergedPreset`, `-LogDir`, `-WorkDir`, `--tag`, `--builder-distro`, …) don't need a first-class dispatcher flag each — they go through `--`. |

```text
mios-install flash --dry-run
mios-install xbox --type vm --stage flash             # Deploy-MiOSXbox.ps1 -SkipBuild against an existing ISO
mios-install oci --stage iso --unattended              # full build_all-equivalent matrix, no prompts
mios-install update --check                             # -> mios-update --check (Linux, already-installed host)
mios-install seed -- -BuilderDistro MiOS-DEV-2 -Force
mios-install bootc --type upgrade --stage prereqs       # -> mios-update --check (dry preview, no changes)
mios-install.bat xbox --type iso -- -SourceIso D:\uup\MiOS-Xbox-src.iso
```

## The 5-stage funnel

A **descriptive** overlay, not a universal capability every entrypoint
supports. Each target's row in the mapping table below marks every stage
**REAL** (a genuine flag isolates it) or **best-effort** (documented mapping
only — the whole pipeline still runs). `mios-install` never claims isolation
an entrypoint doesn't actually have.

1. **prereqs** — tooling / elevation / dependency checks
2. **fetch** — acquire source material (git clone/pull, UUP ISO fetch,
   MediCat 7z, OCI image pull)
3. **service** — transform/build the payload (DISM servicing, podman build,
   dnf/overlay merge, bootc-switch staging)
4. **iso** — package the final artifact (oscdimg repack, USB
   branding + Start.exe compile, seed blob manifest, BIB qcow2/raw)
5. **flash** — write/activate on the target (USB device write, VM boot,
   reboot to apply, `bootc upgrade --apply`)

## Target → entrypoint mapping

| Target | `--type` (default first) | Platform | Calls | Concrete invocation | Stage support | `--unattended` maps to |
|---|---|---|---|---|---|---|
| `live` | `live` (no-op today — see note) | Windows | `cat\MiOS-Cat.bat` | `MiOS-Cat.bat stage` | none isolable (best-effort) — `start_install` is one monolithic pipeline | `NONINTERACTIVE=1` |
| `flash` | `usb` (only) | Windows | `cat\MiOS-Cat.bat` | `MiOS-Cat.bat stage` | same as `live` | `NONINTERACTIVE=1` |
| `flash` | `usb` (only) | Linux | `cat\MiOS-Cat.sh` | `./MiOS-Cat.sh` (Ventoy/MediCat kickstart, run as your **normal user** — see caveat below) | best-effort only | not supported — flag documented, still prompts |
| `xbox` | `iso` (default) | Windows | `cat\autounattend\Build-MiOSXboxISO.ps1` | `Build-MiOSXboxISO.ps1 -TomlPath <ssot> [-SkipPrereqs] [-SkipWsl]` | `prereqs`=REAL (`-SkipPrereqs`) · `fetch`=REAL (pass `-SourceIso <path>` through `--` to skip the UUP fetch; omit to force it) · `service`/`iso`=best-effort (no standalone flag at this wrapper — drop to `New-MiOSISO.ps1` directly for that) · `flash`=N/A (no device write here) | no native unattended switch found; the script is already non-interactive by default |
| `xbox` | `vm` | Windows | `cat\autounattend\Deploy-MiOSXbox.ps1` | `Deploy-MiOSXbox.ps1 -TomlPath <ssot> [-SkipBuild -SourceIso <path>] -VMName <name> -LogDir <path>` | `prereqs`/`fetch`/`service`/`iso`=best-effort · `flash`=**REAL**: `--stage flash` → `-SkipBuild -SourceIso <existing-iso>` (create+boot the Hyper-V VM only) | none documented; progress is tracked via a JSON state file, not a flag |
| `xbox` | `provision` | Windows | `cat\autounattend\Invoke-MiOSProvision.ps1` | `Invoke-MiOSProvision.ps1 -TomlPath <ssot> [-SkipBootstrap]` | `service`=REAL — this whole script *is* the service stage, standalone · others N/A | `-SkipBootstrap` approximates it (skips the online Get-MiOS.ps1 fallback) |
| `fedora` | `fhs` (only) | Linux, run **on the target** | `build-mios.sh` | `INSTALL_MODE=fhs MIOS_FHS_TOTAL_ROOT_MERGE=1 MIOS_PROMPT_TIMEOUT=1 sudo ./build-mios.sh` (last two env vars only with `--unattended`) | `prereqs`/`fetch`/`service`/`flash`=best-effort — one monolithic Phase-0..4 script, no stage flags; `MIOS_REPO`/`BOOTSTRAP_REPO` scope *what* is fetched, not *whether* | `MIOS_PROMPT_TIMEOUT=1` + `MIOS_FHS_TOTAL_ROOT_MERGE=1` (bypasses the destructive-merge confirmation) |
| `fedora` | `fhs` (only) | Windows, target is remote | `build-mios.sh` | **prints** the ready-to-paste remote command (`sudo bash -c "..."`) — no native remote-exec in the inventory. Optional: set `$env:MIOS_REMOTE_HOST` to ssh it over instead. | same as above, applied to the printed/ssh'd command | same env vars, surfaced in the printed command |
| `bootc` | `switch` (default) | Linux, run **on the target** | `build-mios.sh` | `INSTALL_MODE=bootc IMAGE_TAG=<ref> MIOS_PROMPT_TIMEOUT=1 sudo ./build-mios.sh` | `flash`=best-effort — Phase-4's reboot prompt is the flash stage; unattended answers "y" via the env var, not a dedicated flag | `MIOS_PROMPT_TIMEOUT=1` |
| `bootc` | `upgrade` | Linux, already-installed host | `mios-update` | `mios-update [--check\|--apply\|--rollback]` | `prereqs`=REAL (`--check`, dry preview) · `flash`=REAL (`--apply`, stages + reboots) · `fetch`/`service`/`iso` collapse into `bootc upgrade` internals, not isolable | `--apply` is the closest analog — it still runs unattended by construction |
| `oci` | `local` (default) | Windows | `build-mios.ps1` | `build-mios.ps1 -Unattended` with `$env:MIOS_SKIP_BIB=1` | see **caveat** below — `prereqs`/`service`=best-effort · `fetch`=real-ish via `MIOS_BOOTSTRAP_REPO`/`MIOS_BOOTSTRAP_REF` · `iso`=REAL-shaped: `--stage iso` omits `MIOS_SKIP_BIB` (full qcow2/raw/BIB matrix) · `flash`=N/A | `-Unattended` (the one real flag `MiOS-Cat.bat` itself passes) |
| `oci` | `full` | Windows | `build-mios.ps1` | `build-mios.ps1 -Unattended` (`MIOS_SKIP_BIB` unset) | same as `local`, `iso` stage forced on | `-Unattended` |
| `oci` | `push` | Windows | `build-mios.ps1` | same as `local`/`full` + `$env:MIOS_GITHUB_TOKEN` exported first | same | `-Unattended` |
| `seed` | `dev` (default) | Windows | `cat\autounattend\Build-MiOSSeed.ps1` | `Build-MiOSSeed.ps1 -TomlPath <ssot> [-OutDir <path>] [-BuilderDistro MiOS-DEV] [-ImageRef <ref>] [-Force]` | `service`=REAL, single-shot (the whole script *is* the service+iso stage) · `prereqs`/`fetch`/`flash`=N/A (exports from an already-built distro, no fetch of its own) | no native unattended flag; the script has no documented prompts — treat as always-unattended |
| `build` | (n/a) | Linux, already-installed host | `mios-build` | `mios-build [--apply\|--no-switch\|--tag <name>]` | `service`=default (podman build) · `flash`=REAL (`--apply`: build + switch + reboot) · `prereqs`/`fetch`/`iso`=N/A (operates on the tree already present) | `--apply` is closest; the script itself is always non-interactive |
| `update` | (n/a) | Linux, already-installed host | `mios-update` | `mios-update [--check\|--apply\|--rollback]` | identical entrypoint to the `bootc --type upgrade` row above | `--apply` |
| `update` | `repo` | Windows, bootstrap checkout | `cat\MiOS-Cat.bat` | `MiOS-Cat.bat update` (→ `sub_update`: `git fetch`/`pull` both `C:\MiOS` and `C:\mios-bootstrap`) | `fetch`=REAL — this whole target *is* the fetch stage · others N/A | `NONINTERACTIVE=1` |

`<ssot>` above resolves the same way every existing entrypoint already does:
`..\mios.toml` relative to the script, else `C:\MiOS\usr\share\mios\mios.toml`.

### Verified caveat — `oci` and `MIOS_SKIP_BIB`

`cat\MiOS-Cat.bat`'s own `build_oci`/`build_all` menu items really do
set/clear `$env:MIOS_SKIP_BIB` before calling `build-mios.ps1 -Unattended` —
that's a real, existing distinction in the **caller**, and `mios-install`
mirrors it rather than inventing a new env var. Read against the current
`build-mios.ps1` source, though: its `-BootstrapOnly`/`-BuildOnly`/
`-FullBuild` switches are now hard-forced no-ops
(`$BootstrapOnly = $true` unconditionally) — the Windows side's job today is
strictly *ack → provision the `MiOS-DEV` podman machine → install the
`mios build` launcher → stop*. The actual OCI build (and the BIB qcow2/raw
matrix) fires later, when the operator types `mios build` inside the
provisioned MiOS terminal, which SSHes into `MiOS-DEV` and runs
`/usr/libexec/mios/mios-build-driver` — see the root `README.md`'s "Windows
is provisioning + handoff only" note. In practice: `mios-install oci`
ensures the builder is ready and installs that launcher; it does not, by
itself, guarantee a finished image the way it did before this migration.
`mios-install` does not paper over this — it reports what `build-mios.ps1`
actually did and reminds the operator that `mios build` (inside the new
MiOS terminal, or over SSH into `MiOS-DEV` directly) is the next step if the
builder wasn't already provisioned.

### Verified caveat — `flash` on Linux is never run with `sudo`

`cat\MiOS-Cat.sh` explicitly checks `EUID` and **exits with an error** if
launched as root (`CheckNotElevated`) — it calls `sudo` itself, per command,
only where a step needs it. `mios-install flash` on Linux therefore runs
`./MiOS-Cat.sh` as your normal user, not `sudo ./MiOS-Cat.sh`; you'll be
prompted for your password inline when the script needs to elevate.

## Why some targets map where they do

- **`live` vs `flash`.** Both resolve to the *same* call today,
  `MiOS-Cat.bat stage`. `MiOS-Cat.bat`'s `start_install` settings
  (`extract_mode`, `force_format`, `drivepath`) are interactive-menu-only —
  there's no flag or env var yet for `mios-install` to lean on to make
  `live` produce a lighter zero-install payload distinct from `flash`'s full
  offline-repo payload. Until `MiOS-Cat.bat` optionally grows an additive
  env-var default for `extract_mode` (a separate, carefully-scoped change —
  *not* something to sneak in here, per the "don't touch the existing
  entrypoints" rule), `--type` on `live` is accepted but is a documented
  no-op that degrades to the same call as `flash`.
- **`fedora`/`bootc` are `build-mios.sh` with `INSTALL_MODE` forced**
  (`fedora` → `fhs`, `bootc` → `bootc`). `build-mios.sh` has no
  remote-host parameter — it's meant to run *on* the target. From Windows,
  `mios-install fedora|bootc` can't SSH anywhere the inventory doesn't
  support, so it prints the exact ready-to-paste command for you to run on
  the target box instead (optionally piping it over SSH if
  `$env:MIOS_REMOTE_HOST` is set).
- **`build`/`update` are Linux-only, already-installed-host maintenance
  verbs** (`mios-build`, `mios-update`) — distinct from `oci` (a Windows
  dev-distro producing a fresh artifact matrix from nothing) and from
  `bootc` (first-time switch of a bootc-booted host onto the MiOS image).
  Keeping these three separate avoids collapsing "provision" and "maintain"
  into one confusing verb.
- **`xbox --type vm` reuses `Deploy-MiOSXbox.ps1`'s own `-SkipBuild`
  switch** as the real `--stage flash` mapping (skip straight to VM
  create+boot against an existing ISO) — a genuine flag, not best-effort.
- **`oci`'s `--stage iso`** maps to *not* setting `MIOS_SKIP_BIB=1`
  (produces the full qcow2/raw/BIB matrix, i.e. what `MiOS-Cat.bat`'s own
  `build_all` branch requests); the default/`--stage service` sets
  `MIOS_SKIP_BIB=1` (what `build_oci` requests). See the verified caveat
  above for what that env var currently does — and doesn't — control inside
  `build-mios.ps1` itself.

## Why the .bat/.ps1 relationship looks backwards

`cat\MiOS-Cat.ps1` is already a thin, self-elevating shim that forwards
`@args` to `cat\MiOS-Cat.bat` — `.bat` canonical, `.ps1` shim. That's the
right call *there* because `MiOS-Cat` targets factory-fresh Windows boxes:
cmd.exe is always present, double-clickable, and has no
execution-policy gate to fight. `mios-install` is reached only *after*
`Get-MiOS.ps1` has already cloned the repo and the operator is running from
a real shell, so the constraint that forced `MiOS-Cat.bat` to be canonical
doesn't apply here. Per this design, `mios-install.ps1` carries the real
grammar (canonical) and `mios-install.bat` is the thin forwarder (shim) —
the *inverse* of `MiOS-Cat`'s own convention. Don't "fix" it to match.

## Conventions carried forward (not invented)

- **Exit code mirroring**: `& $target_script @args; exit $LASTEXITCODE`
  (Windows) / `"$@"; exit $?` (Linux) — exactly `MiOS-Cat.ps1`'s pattern.
- **Self-elevation** via UAC relaunch (Windows) / self-`sudo` re-exec
  (Linux) only for targets that actually need it — never blanket elevation.
- **`--dry-run`** prints the resolved command and does not execute — since
  none of the 9 wrapped entrypoints has a native dry-run mode, dispatcher-
  level dry-run is the only honest option.
- **Never pass a flag an entrypoint doesn't have.** Where `--stage`/`--type`
  ask for more isolation than an entrypoint can give, this doc says so
  (best-effort) instead of fabricating a capability — consistent with this
  repo's SSOT / no-hardcode / no-fake-drift posture (`mios-hardcode-lint`,
  the drift-gates already enforce this spirit elsewhere).

## SSOT alignment (Phase-3+ direction, not yet wired)

Per this repo's own convention — `mios.toml` is the one config surface,
and `mios-toml-get` / `Get-MiosTomlValue` / `usr/lib/mios/mios_toml.py`
already exist as the shared resolver both `build-mios.ps1` and
`MiOS-Cat.bat` use — the target → entrypoint mapping table above is a
candidate for a future `mios.toml` `[installation.targets.<name>]` section
(entrypoint path, arg templates, type/stage support flags) rather than
staying hand-maintained in two scripts. `mios.toml` does not have this
section yet (checked: no `[installation` block present). Until it lands,
`mios-install.ps1`/`.sh` hold this table directly, and this README is the
one place it's written out in full — treat the table above as the source
of truth to update if the underlying entrypoints' flags change, and update
`mios.toml` + both scripts together if/when the SSOT table ships, so this
file never drifts from what the scripts actually do.

## Out of scope — not re-wrapped here

`Get-MiOS.ps1`'s `-Action Default` (the `irm | iex` bootstrap-a-fresh-
Windows-box flow) and `-Action OfflineSync` (repo → USB robocopy sync) are
the *entry into this whole system*, not something `mios-install`
re-wraps — you only reach `mios-install` after `Get-MiOS.ps1` has already
cloned `mios-bootstrap` locally. `Get-MiOS.ps1` also exposes
`-Action BuildXboxISO` and `-Action FlashUSB`, which are themselves tiny
wrappers (around `Build-MiOSXboxISO.ps1` and `MiOS-Cat.bat` respectively) —
`mios-install xbox --type iso` and `mios-install flash` supersede those two
with the fuller `--type`/`--stage`/`--dry-run` grammar, but neither
`mios-install` nor this README should grow a path that calls back into
`Get-MiOS.ps1`. Keep that boundary one-directional: `Get-MiOS.ps1` →
(clone) → `mios-install`, never the reverse.
