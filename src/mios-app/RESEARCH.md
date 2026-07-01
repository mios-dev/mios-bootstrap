# MiOS App — feasibility research (Gecko/Surfer vs. alternatives)

> Scaffold-stage research note, not an implementation decision. Read alongside
> `README.md` in this directory before writing any MiOS App code.

## Question

Could MiOS App — the future client pulled to deploy MiOS locally and/or join
the cluster VPN as a remote client — be built as a custom browser chrome
(3-pane IDE-style shell) forked from Firefox/Gecko via the Surfer toolchain
(`@zen-browser/surfer`), the way the Zen Browser project does it?

## What Surfer actually is

`@zen-browser/surfer` is a CLI (forked from an abandoned tool, "Gluon") that
automates maintaining a **patch-and-rebuild fork of stock Firefox source** —
it is not a from-scratch browser engine. `surfer.json` pins a Mozilla release;
`surfer download` fetches that Firefox source tarball; `surfer import` applies
the fork's own patch set (JS/CSS/prefs, occasionally C++/Rust) on top; the
resulting tree is then built with Mozilla's own `mach build`/`mach package`.
Zen Browser itself is exactly this pipeline, split across `dev`/`stable`
branches.

## Build reality

Compiling Firefox/Gecko from source is a heavy, real build: Mozilla's own
docs list ~30 GB disk (Linux/macOS, ~40 GB Windows), 8 GB+ RAM, 4+ physical
cores recommended, SSD strongly advised, plus the full Rust/clang/NodeJS
toolchain `mach bootstrap` installs. "Quick mach build" claims should be
treated skeptically — Mozilla's own slow-build documentation and community
reports both describe routine multi-hour builds on modest hardware.

## Fit for a bootc/OCI immutable image

Technically possible, but disproportionate for this repo's job. Baking a
from-source Gecko build into the image means carrying a 30–40 GB+ transient
build tree and a full native toolchain (Rust, clang, Node) through every
image rebuild, multiplying `just build` time by hours, unless very carefully
discarded in a multi-stage build — extra weight this installer/config-layer
repo has no current justification for.

**Cheaper alternatives that reach a similar end state:**

- Package **Zen Browser** itself (Flathub, or a community Fedora Copr) as a
  prebuilt binary and layer MiOS chrome customization (`userChrome.css`,
  `userChrome.js`) and branding on top — no from-source build at all.
- Patch stock Firefox/Firefox-ESR the same way, if staying off a third-party
  fork's release cadence matters more than the head start Zen provides.

## `userChrome.js` / privileged JS / native process execution

- `userChrome.css` is fully supported today via the standard
  `toolkit.legacyUserProfileCustomizations.stylesheets` pref.
- Privileged `userChrome.js` (arbitrary chrome-context JS) requires a
  third-party loader such as `fx-autoconfig` — **unsupported by Mozilla**,
  and historically fragile across Firefox version bumps. This is the
  mechanism the earlier "MiOS Cockpit" panel proposal depended on.
- `nsIProcess` (XPCOM) can spawn local binaries, but only from that same
  chrome-privileged context — so it inherits the same unsupported-loader
  risk, not a separate one.
- Mozilla's supported customization surface (`mozilla.cfg` / enterprise
  policies / WebExtensions) does **not** cover spawning local processes or
  arbitrary chrome layout injection — those stay in fork/unsupported
  territory regardless of tooling.

## Verdict

A 3-pane custom browser chrome via a from-source Surfer/Gecko fork is a
multi-week effort with a real per-Firefox-release maintenance tax, and is
heavy relative to what an installer/config repo needs to ship. The lower-risk
path to the same "3-pane IDE-style shell + local MCP/agent panel" experience
is: **prebuilt Zen Browser (or Firefox/ESR) + `userChrome.css` +
`fx-autoconfig`-style loader for the privileged panel JS**, days not weeks,
with the fork-maintenance question deferred entirely.

This is a build-approach question, separate from MiOS App's actual job
described in `README.md` (a client that deploys MiOS locally and joins the
cluster VPN) — that job does not require a browser fork at all; the browser
angle is one possible future "hybrid IDE shell" surface for it, not a
prerequisite.

## Open questions for a later, non-scaffold pass

- Does MiOS App need a custom browser chrome at all, or does a normal
  desktop app (webview + local panels) satisfy the "AIO surface" goal
  more cheaply?
- If a Gecko-based shell is still wanted later, is Zen Browser upstream
  itself (rather than a MiOS-specific Surfer fork) sufficient with just
  `userChrome.css`/branding on top?
- What does "connect as a MiOS client to the cluster VPN" require
  concretely — WireGuard config distribution? An existing peer enrollment
  flow? That is orthogonal to the browser-chrome question and should be
  scoped independently.
