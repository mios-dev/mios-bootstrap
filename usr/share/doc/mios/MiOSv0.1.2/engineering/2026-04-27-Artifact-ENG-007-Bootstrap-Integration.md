<!-- 🌐 MiOS Artifact | Proprietor: MiOS Project | https://github.com/mios-project/mios -->
# MiOS Bootstrap Repository Integration

```json:knowledge
{
  "summary": "Complete guide for logging artifacts and auto-updating Wiki in the MiOS-bootstrap repository for every build, push, and local build entry point",
  "logic_type": "engineering",
  "tags": [
    "bootstrap",
    "wiki",
    "artifacts",
    "build-logs",
    "automation"
  ],
  "relations": {
    "depends_on": [
      "tools/log-to-bootstrap.sh",
      "Justfile",
      "artifacts/ai-rag/"
    ],
    "impacts": [
      "MiOS-bootstrap repository",
      "GitHub Wiki",
      "CI/CD pipeline"
    ]
  },
  "version": "1.0.0"
}
```

> **Repository:** https://github.com/mios-project/MiOS-bootstrap
> **Purpose:** Home of fully compiled artifacts every build, push, local build entry point
> **Auto-Update:** Wiki automatically updates with every artifacts-as-logs/build-logs to bootstrap repo

---

## Overview

The MiOS-bootstrap repository serves as the **distribution hub** for all MiOS artifacts, build logs, and documentation. It automatically syncs with every build to ensure the Wiki and artifact packages are always up-to-date.

### Key Features

1. **Automatic Artifact Logging** — Every build copies compressed artifacts to bootstrap repo
2. **Build Log Tracking** — Latest build logs synced to `build-logs/VERSION/`
3. **Wiki Auto-Update** — GitHub Wiki automatically updated with every artifact sync
4. **Version-Specific Storage** — All artifacts organized by MiOS version
5. **XZ Compression** — Primary artifacts use XZ (LZMA2) for 37% better compression than GZ

---

## Repository Structure

```
MiOS-bootstrap/
├── ai-rag-packages/
│   └── v0.1.2/
│       ├── mios-complete-rag-TIMESTAMP.tar.xz       (509 KB) ← PRIMARY
│       ├── mios-complete-rag-TIMESTAMP.tar.gz       (814 KB) [legacy]
│       ├── mios-knowledge-complete-TIMESTAMP.tar.xz (4.2 KB)
│       ├── repo-rag-snapshot.json.xz                (588 KB)
│       ├── manifest.json.xz                         (588 KB)
│       ├── mios-knowledge-graph.json
│       ├── script-inventory.json
│       ├── rag-manifest.yaml
│       ├── manifest.json                            (metadata)
│       └── README.md
├── build-logs/
│   └── v0.1.2/
│       └── latest-build.log
├── output/
│   └── v0.1.2/
│       ├── *.sha256                                 (checksums)
│       ├── *.json                                   (metadata)
│       └── *.txt                                    (build info)
└── wiki/
    └── v0.1.2/
        ├── INDEX.md
        ├── README.md
        ├── AI-AGENT-GUIDE.md
        ├── SELF-BUILD.md
        ├── SECURITY.md
        ├── llms.txt
        ├── ai-integration/
        │   ├── 2026-04-27-Artifact-AI-000-Index.md
        │   ├── 2026-04-27-Artifact-AI-001-RAG-Integration.md
        │   ├── 2026-04-27-Artifact-AI-002-Quick-Reference.md
        │   ├── 2026-04-27-Artifact-AI-003-Prompts-Library.md
        │   └── 2026-04-27-Artifact-AI-004-Knowledge-Graph.md
        └── engineering/
            └── 2026-04-27-Artifact-ENG-006-FHS-Compliance-Audit.md
```

---

## Setup

### 1. Clone Bootstrap Repository

```bash
# Clone the bootstrap repository
git clone https://github.com/mios-project/MiOS-bootstrap ~/MiOS-bootstrap

# Clone the Wiki repository (for auto-updates)
git clone https://github.com/mios-project/MiOS-bootstrap.wiki ~/MiOS-bootstrap.wiki
```

### 2. Set Environment Variable (Optional)

```bash
# Add to ~/.bashrc or ~/.zshrc
export BOOTSTRAP_REPO="${HOME}/MiOS-bootstrap"
```

If not set, the script defaults to `${HOME}/MiOS-bootstrap`.

---

## Usage

### Option 1: Just Targets (Recommended)

```bash
# Log artifacts to bootstrap after any build
just log-bootstrap

# Build with unified logging + auto-log to bootstrap
just build-and-log

# Full pipeline: build → rechunk → log to bootstrap
just all-bootstrap
```

### Option 2: Direct Script Execution

```bash
# From MiOS repository root
./tools/log-to-bootstrap.sh

# With custom bootstrap location
BOOTSTRAP_REPO=/path/to/MiOS-bootstrap ./tools/log-to-bootstrap.sh
```

---

## Automated Workflows

### Local Build Entry Point

**After every local build:**

```bash
# Standard build
just build

# Then log to bootstrap
just log-bootstrap
```

**Or use combined target:**

```bash
just build-and-log
```

### CI/CD Pipeline Integration

Add to `.github/workflows/build-sign.yml`:

```yaml
- name: Log artifacts to bootstrap
  run: |
    git clone https://github.com/mios-project/MiOS-bootstrap /tmp/bootstrap
    git clone https://github.com/mios-project/MiOS-bootstrap.wiki /tmp/bootstrap.wiki
    BOOTSTRAP_REPO=/tmp/bootstrap ./tools/log-to-bootstrap.sh

- name: Push bootstrap updates
  run: |
    cd /tmp/bootstrap
    git config user.name "MiOS Bot"
    git config user.email "bot@mios-project.com"
    git add .
    git commit -m "Automated artifact sync for MiOS ${{ env.VERSION }}"
    git push

- name: Push Wiki updates
  run: |
    cd /tmp/bootstrap.wiki
    git config user.name "MiOS Bot"
    git config user.email "bot@mios-project.com"
    git push
```

### Windows Build Entry Point

Update `mios-build-local.ps1`:

```powershell
# After successful build
Write-Host "▶ Logging artifacts to bootstrap..." -ForegroundColor Cyan

if (Test-Path "$env:USERPROFILE\MiOS-bootstrap\.git") {
    wsl bash -c "./tools/log-to-bootstrap.sh"
    Write-Host "✓ Artifacts logged to bootstrap" -ForegroundColor Green
} else {
    Write-Warning "MiOS-bootstrap repository not found. Clone it first:"
    Write-Host "  git clone https://github.com/mios-project/MiOS-bootstrap $env:USERPROFILE\MiOS-bootstrap"
}
```

---

## What Gets Logged

### 1. AI RAG Artifacts

**Primary Packages (XZ Compression):**
- `mios-complete-rag-TIMESTAMP.tar.xz` (509 KB)
  - Complete repository: specs/, automation/, usr/, etc/, var/, home/, tools/, config/, evals/
  - 722 files preserved
  - 99.95% compression ratio

- `mios-knowledge-complete-TIMESTAMP.tar.xz` (4.2 KB)
  - Knowledge graph + script inventory + RAG manifest

**Repository-Level Artifacts:**
- `repo-rag-snapshot.json.xz` (588 KB)
  - Full semantic knowledge index

- `manifest.json.xz` (588 KB)
  - Complete project manifest

**Individual Files:**
- `mios-knowledge-graph.json` (3.3 KB)
- `script-inventory.json` (8.2 KB)
- `rag-manifest.yaml` (1.9 KB)

**Legacy Packages (GZ Compression):**
- `mios-complete-rag-TIMESTAMP.tar.gz` (814 KB)
- `mios-context-TIMESTAMP.tar.gz` (749 KB)
- `mios-docs-TIMESTAMP.tar.gz` (31 KB)

### 2. Build Logs

- Latest build log from `logs/build-*.log` → `build-logs/VERSION/latest-build.log`

### 3. Output Metadata

- Checksums: `*.sha256`
- Metadata: `*.json`
- Build info: `*.txt`

*Note: Large disk images (ISO, RAW, VHD, QCOW2) are NOT copied to bootstrap repo (use GitHub Releases instead)*

### 4. Wiki Documentation

**Core Documentation:**
- INDEX.md
- README.md
- AI-AGENT-GUIDE.md
- SELF-BUILD.md
- SECURITY.md
- llms.txt

**AI Integration:**
- All files from `specs/ai-integration/`

**Engineering:**
- FHS Compliance Audit
- (Additional specs as needed)

---

## Wiki Auto-Update Mechanism

### How It Works

1. **Artifact Sync** — `tools/log-to-bootstrap.sh` runs after every build
2. **Wiki Detection** — Script checks for `MiOS-bootstrap.wiki` repository at `${BOOTSTRAP_REPO}/../MiOS-bootstrap.wiki`
3. **Documentation Sync** — All docs from `wiki/VERSION/` synced to Wiki repo
4. **Index Generation** — `Home.md` automatically generated with:
   - Latest version number
   - Links to all AI integration docs
   - Links to core documentation
   - Links to engineering specs
   - Quick start guide
5. **Auto-Commit** — Wiki changes auto-committed with message: `Auto-update Wiki for MiOS VERSION - DATE`

### Wiki Pages Created

| Wiki Page | Source | Description |
|-----------|--------|-------------|
| `Home.md` | Auto-generated | Wiki landing page with latest version |
| `AI-Integration-Index.md` | `specs/ai-integration/...-AI-000-Index.md` | AI integration overview |
| `RAG-Integration.md` | `specs/ai-integration/...-AI-001-RAG-Integration.md` | Complete RAG guide |
| `Quick-Reference.md` | `specs/ai-integration/...-AI-002-Quick-Reference.md` | AI agent quick ref |
| `Prompts-Library.md` | `specs/ai-integration/...-AI-003-Prompts-Library.md` | AI prompt templates |
| `Knowledge-Graph.md` | `specs/ai-integration/...-AI-004-Knowledge-Graph.md` | Knowledge graph docs |
| `INDEX.md` | Root `INDEX.md` | MiOS AI Agent Hub |
| `README.md` | Root `README.md` | Project overview |
| `AI-AGENT-GUIDE.md` | Root `AI-AGENT-GUIDE.md` | AI coding agent guide |
| `SELF-BUILD.md` | Root `SELF-BUILD.md` | Build instructions |
| `SECURITY.md` | Root `SECURITY.md` | Security hardening |
| `llms.txt` | Root `llms.txt` | AI ingestion index |
| `engineering/*.md` | `specs/engineering/*.md` | Engineering specs |

### Manual Wiki Push

If auto-commit succeeded but push is required:

```bash
cd ~/MiOS-bootstrap.wiki
git push
```

---

## Manifest Generation

The script auto-generates `manifest.json` in the artifacts directory:

```json
{
  "mios_version": "v0.1.2",
  "generated_at": "2026-04-27T18:00:00Z",
  "artifacts": {
    "ai_rag": { ... },
    "wiki": { ... },
    "core_docs": { ... }
  },
  "stats": {
    "original_repo_size": "928 MB",
    "compressed_xz_size": "509 KB",
    "compressed_gz_size": "814 KB",
    "compression_ratio_xz": "99.95%",
    "compression_ratio_gz": "99.91%",
    "total_files_preserved": 722
  },
  "compression": {
    "primary_format": "XZ (LZMA2)",
    "legacy_format": "GZ (gzip)",
    "recommendation": "Use .tar.xz packages for 37% better compression"
  },
  "foss_ai_apis": [
    "Ollama",
    "llama.cpp",
    "LocalAI",
    "vLLM"
  ]
}
```

---

## Verification

### Check Bootstrap Sync

```bash
cd ~/MiOS-bootstrap

# Check artifacts
ls -lh ai-rag-packages/v0.1.2/

# Check build logs
ls -lh build-logs/v0.1.2/

# Check Wiki docs
ls -lh wiki/v0.1.2/

# View manifest
cat ai-rag-packages/v0.1.2/manifest.json
```

### Check Wiki Sync

```bash
cd ~/MiOS-bootstrap.wiki

# Check Wiki pages
ls -lh *.md

# View Home page
cat Home.md

# Check git status
git status
git log -1
```

---

## Troubleshooting

### Bootstrap Repo Not Found

```bash
# Clone it
git clone https://github.com/mios-project/MiOS-bootstrap ~/MiOS-bootstrap

# Or set custom location
export BOOTSTRAP_REPO=/path/to/MiOS-bootstrap
```

### Wiki Repo Not Found

```bash
# Clone it
git clone https://github.com/mios-project/MiOS-bootstrap.wiki ~/MiOS-bootstrap.wiki

# Or adjust path in script (default: ${BOOTSTRAP_REPO}/../MiOS-bootstrap.wiki)
```

### rsync Not Found

```bash
# Fedora/RHEL
sudo dnf install rsync

# Debian/Ubuntu
sudo apt install rsync

# macOS
brew install rsync
```

### Permission Denied

```bash
# Ensure bootstrap repo is writable
chmod -R u+w ~/MiOS-bootstrap

# Check git permissions
cd ~/MiOS-bootstrap
git config --list
```

---

## Integration with Build Pipeline

### Recommended Workflow

**For every build:**

```bash
# 1. Build with logging
just build-logged

# 2. Log to bootstrap (includes Wiki auto-update)
just log-bootstrap

# 3. Commit and push bootstrap updates
cd ~/MiOS-bootstrap
git add .
git commit -m "Add MiOS v0.1.2 artifacts - $(date -u +%Y-%m-%d)"
git push

# 4. Push Wiki updates (already committed by script)
cd ~/MiOS-bootstrap.wiki
git push
```

**Or use single command:**

```bash
just build-and-log
```

### For Releases

```bash
# Full pipeline with bootstrap logging
just all-bootstrap

# Manually push to GitHub
cd ~/MiOS-bootstrap
git push

cd ~/MiOS-bootstrap.wiki
git push
```

---

## Best Practices

1. **Always log after builds** — Use `just log-bootstrap` after every successful build
2. **Use XZ compression** — 37% smaller than GZ, included by default
3. **Push regularly** — Keep bootstrap repo and Wiki in sync with main repo
4. **Version artifacts** — All artifacts organized by VERSION from `VERSION` file
5. **Verify sync** — Check `manifest.json` after logging to confirm all artifacts copied
6. **Automate in CI/CD** — Add bootstrap logging to GitHub Actions workflows
7. **Keep Wiki updated** — Script auto-commits, but manual push may be required

---

## References

- **Main Repository:** https://github.com/mios-project/mios
- **Bootstrap Repository:** https://github.com/mios-project/MiOS-bootstrap
- **Wiki:** https://github.com/mios-project/MiOS-bootstrap/wiki
- **Script:** [tools/log-to-bootstrap.sh](../../tools/log-to-bootstrap.sh)
- **Justfile Targets:** [Justfile](../../Justfile) (lines 99-108)
- **Compression Summary:** [artifacts/COMPRESSION-SUMMARY.md](../../artifacts/COMPRESSION-SUMMARY.md)
- **FHS Compliance:** [specs/engineering/2026-04-27-Artifact-ENG-006-FHS-Compliance-Audit.md](2026-04-27-Artifact-ENG-006-FHS-Compliance-Audit.md)

---

<!-- ⚖️ MiOS Proprietary Artifact | Copyright (c) 2026 MiOS Project -->
