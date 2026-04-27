# MiOS AI RAG Integration Guide

**Version:** 0.1.2  
**Target:** FOSS AI APIs (Ollama, llama.cpp, LocalAI, vLLM)  
**Compression Ratio:** 928MB → 752KB context bundle (99.92% reduction)

---

## 📦 What's Included

This compressed RAG package contains the complete MiOS knowledge base optimized for FOSS AI ingestion:

### Core Artifacts

1. **mios-knowledge-graph.json** (3.3KB)
   - Structured knowledge graph with core concepts
   - Version history (MiOS-1 → MiOS-2 → MiOS-NXT)
   - Immutable laws, build pipeline, security hardening
   - Integration points for Ollama, k3s, VFIO

2. **mios-context-TIMESTAMP.tar.gz** (752KB)
   - Complete compressed repository context
   - All documentation, scripts, configs preserved
   - Excludes: .git, node_modules, build outputs
   - Ready for vector database ingestion

3. **rag-manifest.yaml** (1.9KB)
   - Configuration for FOSS AI RAG systems
   - Embedding strategy (all-MiniLM-L6-v2, 512 token chunks)
   - Retrieval parameters (top_k=5, rerank enabled)
   - Endpoint configs for Ollama/llama.cpp/LocalAI/vLLM

4. **ai-prompts.md** (3.2KB)
   - System initialization prompt for AI agents
   - Task-specific prompts (add package, create script, debug build)
   - Template structures for common operations

5. **QUICKREF.md** (2.7KB)
   - Quick reference card for AI agents
   - Essential commands, file hierarchy, immutable laws
   - Common AI tasks with step-by-step instructions

6. **script-inventory.json** (8.2KB)
   - Complete catalog of automation scripts
   - Purpose descriptions for each numbered script
   - Execution order and dependencies

7. **mios-docs-TIMESTAMP.tar.gz** (31KB)
   - Core documentation bundle
   - README, INDEX, SELF-BUILD, SECURITY
   - specs/engineering/ and specs/core/

---

## 🚀 Quick Start with FOSS AI

### Option 1: Ollama (Recommended for Linux)

```bash
# 1. Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# 2. Pull models
ollama pull llama3.1:8b
ollama pull codellama:13b

# 3. Extract MiOS context
cd /path/to/mios/artifacts/ai-rag
tar -xzf mios-context-*.tar.gz -C ~/mios-rag

# 4. Create embedding index (using LangChain)
pip install langchain langchain-community chromadb
python << 'PYTHON'
from langchain_community.document_loaders import DirectoryLoader
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain_community.embeddings import OllamaEmbeddings
from langchain_community.vectorstores import Chroma

# Load documents
loader = DirectoryLoader("~/mios-rag", glob="**/*.md", show_progress=True)
docs = loader.load()

# Split into chunks
text_splitter = RecursiveCharacterTextSplitter(chunk_size=512, chunk_overlap=50)
splits = text_splitter.split_documents(docs)

# Create vector store
embeddings = OllamaEmbeddings(model="llama3.1:8b")
vectorstore = Chroma.from_documents(
    documents=splits,
    embedding=embeddings,
    persist_directory="~/mios-rag-db"
)
print(f"Indexed {len(splits)} chunks")
PYTHON

# 5. Query the knowledge base
python << 'QUERY'
from langchain_community.vectorstores import Chroma
from langchain_community.embeddings import OllamaEmbeddings
from langchain_community.llms import Ollama
from langchain.chains import RetrievalQA

embeddings = OllamaEmbeddings(model="llama3.1:8b")
vectorstore = Chroma(persist_directory="~/mios-rag-db", embedding_function=embeddings)
llm = Ollama(model="llama3.1:8b")

qa_chain = RetrievalQA.from_chain_type(
    llm=llm,
    chain_type="stuff",
    retriever=vectorstore.as_retriever(search_kwargs={"k": 5}),
    return_source_documents=True
)

result = qa_chain("How do I add a new package to MiOS?")
print(result["result"])
QUERY
```

### Option 2: llama.cpp (CPU-Only, Portable)

```bash
# 1. Build llama.cpp
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp && make

# 2. Download GGUF model
wget https://huggingface.co/TheBloke/Llama-2-13B-chat-GGUF/resolve/main/llama-2-13b-chat.Q4_K_M.gguf

# 3. Start server with MiOS context
./server -m llama-2-13b-chat.Q4_K_M.gguf \
  --ctx-size 4096 \
  --host 0.0.0.0 \
  --port 8080

# 4. Query via API
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "system", "content": "'"$(cat mios-knowledge-graph.json)"'"},
      {"role": "user", "content": "Explain MiOS immutable laws"}
    ]
  }'
```

### Option 3: LocalAI (Multi-Model, Docker)

```bash
# 1. Run LocalAI with Docker
docker run -p 8080:8080 \
  -v $PWD/models:/models \
  -v $PWD/mios-rag:/data \
  localai/localai:latest

# 2. Install model
curl http://localhost:8080/models/apply \
  -H "Content-Type: application/json" \
  -d '{"id": "ggml-gpt4all-j"}'

# 3. Create embeddings endpoint
curl http://localhost:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "all-MiniLM-L6-v2",
    "input": "'"$(cat QUICKREF.md)"'"
  }'
```

### Option 4: vLLM (High-Performance, GPU)

```bash
# 1. Install vLLM
pip install vllm

# 2. Start server
python -m vllm.entrypoints.openai.api_server \
  --model meta-llama/Llama-3.1-8B-Instruct \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 1

# 3. Query with MiOS context
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d @- << 'JSON'
{
  "model": "meta-llama/Llama-3.1-8B-Instruct",
  "messages": [
    {
      "role": "system",
      "content": "$(cat mios-knowledge-graph.json)"
    },
    {
      "role": "user",
      "content": "Show me how to create a new automation script"
    }
  ],
  "temperature": 0.7,
  "max_tokens": 1024
}
JSON
```

---

## 📊 RAG Architecture

### Embedding Strategy

```yaml
chunk_size: 512           # Tokens per chunk (optimal for FOSS models)
overlap: 50               # Token overlap for context preservation
model: all-MiniLM-L6-v2  # HuggingFace embedding (384 dimensions)
distance: cosine          # Similarity metric
```

### Retrieval Parameters

```yaml
top_k: 5                  # Return top 5 most relevant chunks
score_threshold: 0.7      # Minimum similarity score
rerank: true              # Use cross-encoder for reranking
context_window: 4096      # Model context size (adjust per model)
```

### Knowledge Source Weights

| Source | Weight | Type |
|--------|--------|------|
| INDEX.md | 1.0 | Architecture laws (always prioritize) |
| PACKAGES.md | 0.9 | Single source of truth |
| SELF-BUILD.md | 0.8 | Build modes |
| Containerfile | 0.8 | Build definition |
| specs/core/ | 0.7 | Blueprints |
| automation/ | 0.6 | Scripts |
| JOURNAL.md | 0.5 | Episodic memory |

---

## 🧠 AI Agent Initialization

### System Prompt Template

```markdown
You are an expert in MiOS v0.1.2, a bootc-based immutable Linux distribution.

**CRITICAL: Always read INDEX.md first for architecture laws.**

Core Knowledge:
- Based on Fedora Rawhide + ucore-hci
- Uses bootc (OCI → bootable OS) + composefs
- Self-building: running MiOS builds next MiOS
- Multi-surface: WSL2, Hyper-V, bare metal, k3s

Immutable Laws (NEVER violate):
1. USR-OVER-ETC: Static config in /usr/lib/, not /etc/
2. NO-MKDIR-IN-VAR: Use tmpfiles.d for /var dirs
3. BOOTC-CONTAINER-LINT: Final validation mandatory

Key Files:
- INDEX.md: AI agent hub
- PACKAGES.md: Package SSOT
- Containerfile: OCI build
- automation/build.sh: Master orchestrator

Before any suggestion, verify against INDEX.md laws.
```

### Example Queries

**Q: How do I add package 'nginx' to MiOS?**
```
A: Steps:
1. Edit specs/engineering/2026-04-26-Artifact-ENG-001-Packages.md
2. Find packages-networking or packages-web section
3. Add 'nginx' alphabetically
4. Update CHANGELOG v0.1.2
5. Verify automation/build.sh calls install_packages for that category
6. No Containerfile changes needed (PACKAGES.md is SSOT)
```

**Q: Create a script to configure custom firewall rules**
```
A: automation/42-custom-firewall.sh:
#!/bin/bash
# Configure custom firewall rules for MiOS
set -euo pipefail
source /ctx/automation/lib/common.sh

section "Custom Firewall Rules"

# Never mkdir /var - use tmpfiles.d if needed
systemd-tmpfiles --create <<EOF
d /var/lib/mios/firewall 0755 root root -
