# MiOS Bootstrap Repository

**Version:** MiOSv0.1.4
**Architecture:** Linux Filesystem Native
**Updated:** 2026-04-28

## 📁 Linux Filesystem Native Structure

This repository follows standard Linux Filesystem Hierarchy Standard (FHS 3.0) where **artifacts, logs, snapshots, and wiki are unified** in native Linux FS layout.

```
MiOS-bootstrap/
├── var/
│   ├── log/mios/              # Build logs and runtime logs
│   │   └── builds/MiOSv0.1.4/
│   │       └── latest.log
│   └── lib/mios/              # State data
│       ├── artifacts/MiOSv0.1.4/     # Compressed packages
│       │   ├── mios-complete-rag-*.tar.xz (509 KB)
│       │   └── mios-knowledge-complete-*.tar.xz (4.2 KB)
│       └── snapshots/MiOSv0.1.4/     # Repository snapshots
│           ├── repo-rag-snapshot.json.xz (588 KB)
│           └── manifest.json.xz (588 KB)
├── usr/
│   └── share/
│       ├── doc/mios/MiOSv0.1.4/      # Documentation (wiki content)
│       │   ├── INDEX.md
│       │   ├── README.md
│       │   ├── AI-AGENT-GUIDE.md
│       │   ├── SELF-BUILD.md
│       │   ├── SECURITY.md
│       │   ├── ai-integration/
│       │   └── engineering/
│       └── mios/              # Application data
│           ├── knowledge/     # Knowledge graphs
│           └── prompts/       # AI prompts
└── etc/mios/                  # Configuration
    ├── manifest.json          # Unified manifest
    └── rag-manifest.yaml      # FOSS AI configuration
```

## 🌐 FOSS AI APIs Compliance

All artifacts follow **FOSS AI APIs protocol**:

- **Discovery:** Check `/usr/share/doc/mios` for documentation (wiki content)
- **Knowledge Base:** `/usr/share/mios/knowledge/mios-knowledge-graph.json`
- **Configuration:** `/etc/mios/rag-manifest.yaml`
- **Artifacts:** `/var/lib/mios/artifacts/MiOSv0.1.4/`
- **Build Logs:** `/var/log/mios/builds/MiOSv0.1.4/latest.log`

### Supported APIs
- Ollama (http://localhost:11434)
- llama.cpp (native inference)
- LocalAI (OpenAI-compatible)
- vLLM (high-throughput)

## 🚀 Quick Start

### Extract Complete Repository

```bash
# Navigate to artifacts
cd var/lib/mios/artifacts/MiOSv0.1.4

# Extract XZ-compressed package (509 KB, 99.95% compression)
tar -xJf mios-complete-rag-*.tar.xz -C ~/mios
```

### Initialize FOSS AI

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh
ollama pull llama3.1:8b

# Load knowledge graph
cat usr/share/mios/knowledge/mios-knowledge-graph.json | \
  ollama run llama3.1:8b "Initialize MiOS context"
```

### Read Documentation

```bash
# All documentation in standard location
ls usr/share/doc/mios/MiOSv0.1.4/

# AI integration guides
ls usr/share/doc/mios/MiOSv0.1.4/ai-integration/

# Engineering specs
ls usr/share/doc/mios/MiOSv0.1.4/engineering/
```

## 📊 Statistics

- **Original Repository:** 928 MB
- **Compressed (XZ):** 509 KB
- **Compression Ratio:** 99.95%
- **Files Preserved:** 722
- **FHS Compliance:** 100%

## 📚 Documentation

All documentation follows standard Linux conventions:

- **Main Docs:** `/usr/share/doc/mios/MiOSv0.1.4/`
- **AI Integration:** `/usr/share/doc/mios/MiOSv0.1.4/ai-integration/`
- **Engineering Specs:** `/usr/share/doc/mios/MiOSv0.1.4/engineering/`

## 🔄 Updates

This repository updates automatically with every MiOS build:

```bash
# From main MiOS repository
just build-and-log-native

# Or manually
./tools/prepare-bootstrap-native.sh
```

## 📖 Manifest

Unified manifest at: `etc/mios/manifest.json`

Contains:
- Filesystem layout
- Artifact locations  
- FOSS AI compliance info
- FHS compliance status
- Wiki integration details

## 🔗 References

- **Main Repository:** https://github.com/Kabuki94/MiOS-bootstrap
- **Bootstrap (this repo):** https://github.com/Kabuki94/MiOS-bootstrap
- **FHS 3.0:** https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.html

---

**Architecture:** Linux Filesystem Native  
**License:** Personal Property - MiOS-DEV
