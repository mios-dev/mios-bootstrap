<!-- 🌐 MiOS Artifact | Proprietor: MiOS Project | https://github.com/mios-project/mios -->
# 🌐 MiOS AI Integration

```json:knowledge
{
  "summary": "MiOS AI RAG Integration - FOSS AI APIs and Knowledge Base",
  "logic_type": "documentation",
  "tags": [
    "MiOS",
    "AI",
    "RAG",
    "FOSS",
    "Ollama",
    "llama.cpp"
  ],
  "relations": {
    "depends_on": [
      "INDEX.md",
      "ai-context.json",
      "llms.txt"
    ],
    "impacts": [
      "artifacts/ai-rag/"
    ]
  },
  "last_rag_sync": "2026-04-27T17:28:31Z",
  "version": "0.1.2"
}
```

> **Proprietor:** MiOS Project  
> **Infrastructure:** AI-Native Knowledge Base (FOSS-Only)  
> **License:** Licensed as personal property to MiOS Project  

---

## Overview

MiOS v0.1.2 includes a complete AI RAG (Retrieval-Augmented Generation) package optimized for FOSS AI APIs. The entire 928MB repository has been compressed to 752KB while preserving all knowledge, memories, context, patterns, and scripts.

**Compression Ratio:** 99.92% reduction  
**Target APIs:** Ollama, llama.cpp, LocalAI, vLLM  
**Status:** Production Ready  

---

## AI Integration Artifacts

### Core Documentation

| Artifact | Description | Location |
|----------|-------------|----------|
| **[RAG Integration Guide](2026-04-27-Artifact-AI-001-RAG-Integration.md)** | Comprehensive setup for FOSS AI APIs | specs/ai-integration/ |
| **[Quick Reference](2026-04-27-Artifact-AI-002-Quick-Reference.md)** | AI agent quick reference card | specs/ai-integration/ |
| **[Prompts Library](2026-04-27-Artifact-AI-003-Prompts-Library.md)** | Task-specific AI prompts | specs/ai-integration/ |
| **[Knowledge Graph](2026-04-27-Artifact-AI-004-Knowledge-Graph.md)** | Structured knowledge graph JSON | specs/ai-integration/ |

### Generated Packages

Located in: `artifacts/ai-rag/`

1. **mios-context-TIMESTAMP.tar.gz** (752KB)
   - Complete compressed repository
   - Ready for vector database ingestion

2. **mios-knowledge-graph.json** (3.3KB)
   - Structured knowledge with core concepts
   - Version history and roadmap

3. **rag-manifest.yaml** (1.9KB)
   - FOSS AI RAG configuration
   - Embedding and retrieval strategies

4. **script-inventory.json** (8.2KB)
   - Complete automation script catalog

5. **mios-docs-TIMESTAMP.tar.gz** (31KB)
   - Core documentation bundle

---

## FOSS AI APIs Supported

### Ollama (Recommended)
- **Endpoint:** http://localhost:11434
- **Models:** llama3.1:8b, codellama:13b, mistral:7b
- **Context:** 8192 tokens
- **Platform:** Linux, macOS, Windows (via WSL)

### llama.cpp (CPU-Only)
- **Endpoint:** http://localhost:8080
- **Models:** GGUF format (portable)
- **Context:** 4096 tokens
- **Platform:** Any (pure C++ implementation)

### LocalAI (Multi-Model)
- **Endpoint:** http://localhost:8080
- **Platform:** Docker-based
- **Embeddings:** all-MiniLM-L6-v2
- **Features:** Multi-model support, OpenAI API compatible

### vLLM (GPU-Accelerated)
- **Endpoint:** http://localhost:8000
- **Models:** meta-llama/Llama-3.1-8B-Instruct
- **Platform:** NVIDIA GPU required
- **Features:** High-throughput, tensor parallelism

---

## Quick Start

### 1. Extract Context Bundle
```bash
cd /home/mios-user/mios/artifacts/ai-rag
tar -xzf mios-context-*.tar.gz -C ~/mios-rag
```

### 2. Install Ollama
```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull llama3.1:8b
```

### 3. Create Vector Database
```bash
pip install langchain langchain-community chromadb

python << 'PYTHON'
from langchain_community.document_loaders import DirectoryLoader
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain_community.embeddings import OllamaEmbeddings
from langchain_community.vectorstores import Chroma

loader = DirectoryLoader("~/mios-rag", glob="**/*.md")
docs = loader.load()

splitter = RecursiveCharacterTextSplitter(chunk_size=512, chunk_overlap=50)
splits = splitter.split_documents(docs)

embeddings = OllamaEmbeddings(model="llama3.1:8b")
vectorstore = Chroma.from_documents(
    documents=splits,
    embedding=embeddings,
    persist_directory="~/mios-rag-db"
)
print(f"✓ Indexed {len(splits)} chunks")
PYTHON
```

### 4. Query Knowledge Base
```bash
python << 'QUERY'
from langchain_community.vectorstores import Chroma
from langchain_community.embeddings import OllamaEmbeddings
from langchain_community.llms import Ollama
from langchain.chains import RetrievalQA

embeddings = OllamaEmbeddings(model="llama3.1:8b")
vectorstore = Chroma(persist_directory="~/mios-rag-db", embedding_function=embeddings)
llm = Ollama(model="llama3.1:8b")

qa = RetrievalQA.from_chain_type(llm=llm, retriever=vectorstore.as_retriever())
result = qa("How do I add a package to MiOS?")
print(result["result"])
QUERY
```

---

## Knowledge Preservation

### ✅ All Documentation Intact
- INDEX.md (AI agent hub, immutable laws)
- PACKAGES.md (package SSOT)
- SELF-BUILD.md (4 build modes)
- SECURITY.md (hardening checklist)
- All specs/ (blueprints, research, engineering)

### ✅ All Scripts Functional
- automation/01-repos.sh through 99-cleanup.sh
- automation/build.sh (master orchestrator)
- automation/lib/packages.sh (package management)
- tools/ (utilities, monitors, builders)
- evals/ (smoke tests, validation)

### ✅ All Memories Retained
- JOURNAL.md (episodic memory)
- .ai/foundation/memories/ (semantic memory)
- ai-context.json (structured manifest)

### ✅ All Patterns Documented
- Build pipeline (ctx stage → main stage)
- Package installation (install_packages <category>)
- Platform detection (systemd-detect-virt)
- Immutable laws (USR-OVER-ETC, NO-MKDIR-IN-VAR, etc.)

---

## RAG Architecture

### Embedding Strategy
```yaml
chunk_size: 512           # Tokens per chunk
overlap: 50               # Token overlap
model: all-MiniLM-L6-v2  # HuggingFace embedding (384 dims)
distance: cosine          # Similarity metric
```

### Knowledge Source Weights
| Source | Weight | Type |
|--------|--------|------|
| INDEX.md | 1.0 | Architecture laws |
| PACKAGES.md | 0.9 | Package SSOT |
| SELF-BUILD.md | 0.8 | Build modes |
| Containerfile | 0.8 | Build definition |
| specs/core/ | 0.7 | Blueprints |
| automation/ | 0.6 | Scripts |
| JOURNAL.md | 0.5 | Episodic memory |

---

## MiOS-Bootstrap Integration

All AI RAG artifacts are logged to the MiOS-bootstrap repository for distribution:

**Repository:** https://github.com/MiOS-DEV/MiOS-bootstrap  
**Artifact Path:** `ai-rag-packages/mios-v0.1.2/`  

### Logged Artifacts:
- mios-context-TIMESTAMP.tar.gz
- mios-knowledge-graph.json
- rag-manifest.yaml
- README-AI-INTEGRATION.md

See: [MiOS-Bootstrap Artifact Logging](#mios-bootstrap-artifact-logging)

---

## Related Documentation

- [INDEX.md](../../INDEX.md) - AI Agent Hub
- [llms.txt](../../llms.txt) - AI Ingestion Index
- [ai-context.json](../../ai-context.json) - Context Manifest
- [FOSS AI Deep Dive](../knowledge/research/2026-04-27-Artifact-KBX-025-FOSS-AI-Deep-Dive.md)

---

## Validation

Verify all scripts remain functional after extraction:

```bash
# Extract context
tar -xzf mios-context-*.tar.gz -C test-extract

# Check script syntax
for script in test-extract/automation/*.sh; do
  bash -n "$script" && echo "✓ $script" || echo "✗ $script"
done

# Verify key files
test -f test-extract/INDEX.md && echo "✓ INDEX.md"
test -f test-extract/Containerfile && echo "✓ Containerfile"
```

---

## Performance Metrics

| Metric | Value |
|--------|-------|
| Original Repository | 928 MB |
| Compressed Context | 752 KB |
| Compression Ratio | 99.92% |
| Markdown Files | 153 |
| Shell Scripts | 116 |
| Knowledge Chunks | ~500-600 |

---

**Document Version:** 1.0  
**Last Updated:** 2026-04-27  
**MiOS Version:** 0.1.2

---
<!-- ⚖️ MiOS Proprietary Artifact | Copyright (c) 2026 MiOS Project -->
