<!-- 🌐 MiOS Artifact | Proprietor: MiOS-DEV | https://github.com/Kabuki94/MiOS-bootstrap -->
# AI Agent Wiki Discovery Pattern

```json:knowledge
{
  "summary": "Complete guide for FOSS AI agents to discover and use constantly-updating Wiki pages for current tasks, research patterns, artifacts, and build logs",
  "logic_type": "ai-integration",
  "tags": [
    "wiki",
    "ai-agents",
    "discovery",
    "foss-ai",
    "live-documentation"
  ],
  "relations": {
    "depends_on": [
      "tools/log-to-bootstrap.sh",
      "artifacts/ai-rag/mios-knowledge-graph.json",
      "artifacts/ai-rag/rag-manifest.yaml"
    ],
    "impacts": [
      "AI agent initialization",
      "RAG retrieval patterns",
      "Knowledge freshness"
    ]
  },
  "version": "1.0.0"
}
```

> **Wiki URL:** https://github.com/Kabuki94/MiOS-bootstrap/wiki
> **Update Frequency:** Every build, push, and local build entry point
> **Purpose:** PRIMARY source for current/new tasks and research patterns

---

## Overview

The MiOS Wiki serves as the **live documentation hub** that updates automatically with every build. AI agents must prioritize Wiki pages over static knowledge graphs for current information.

### Why Wiki-First?

1. **Always Current** — Updates with every build via `tools/log-to-bootstrap.sh`
2. **Artifact Tracking** — Build logs and compressed artifacts logged automatically
3. **Research Patterns** — Latest engineering specs and audits available immediately
4. **Version-Specific** — Documentation organized by MiOS version (v0.1.3, etc.)
5. **FOSS-Friendly** — No proprietary APIs required, pure GitHub Wiki

---

## Discovery Pattern for AI Agents

### Phase 1: Initialization

When an AI agent initializes with MiOS context:

```yaml
# From rag-manifest.yaml
live_documentation:
  wiki_url: https://github.com/Kabuki94/MiOS-bootstrap/wiki
  priority: "Wiki pages are PRIMARY source for current tasks and research patterns"
```

**Action:** Load `mios-knowledge-graph.json` and immediately note:

```json
"live_documentation": {
  "wiki": "https://github.com/Kabuki94/MiOS-bootstrap/wiki",
  "update_frequency": "Every build, push, and local build entry point",
  "purpose": "ALWAYS check Wiki for current tasks, research patterns, artifacts, and build logs",
  "primary_source": "Wiki pages reflect latest state - use for current/new tasks",
  "static_source": "This knowledge graph is snapshot - refer to Wiki for updates"
}
```

### Phase 2: Task Planning

**Before executing any task:**

1. Check if Wiki has current information:
   - New engineering specs
   - Latest build logs
   - Updated research patterns
   - Recent artifact uploads

2. Fetch relevant Wiki page (if web access available):
   ```bash
   # Example: Check Wiki for latest AI integration patterns
   curl -s https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/AI-Integration-Index.md
   ```

3. If offline: Use static knowledge graph as fallback, but note that information may be outdated

### Phase 3: Execution

**During task execution:**

- **Refer to Wiki** for procedural updates (e.g., build workflow changes)
- **Use static docs** for immutable laws (USR-OVER-ETC, NO-MKDIR-IN-VAR) — these don't change
- **Check build logs** in Wiki for recent build failures or patterns

### Phase 4: Verification

**After completing task:**

- Check if Wiki has updated guidance based on recent builds
- Verify against latest Wiki version of relevant specs
- Note any discrepancies between static knowledge and Wiki

---

## Key Wiki Pages for AI Agents

### Essential Pages (Always Check First)

| Wiki Page | URL | Purpose | Update Frequency |
|-----------|-----|---------|------------------|
| **Home** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/Home | Landing page with latest version, quick start | Every build |
| **AI Integration Index** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/AI-Integration-Index | AI RAG overview, artifact links | Every build |
| **Quick Reference** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/Quick-Reference | Essential commands, file hierarchy | Every build |
| **AI Agent Guide** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/AI-AGENT-GUIDE | Hard rules, immutable laws, protected files | As needed |
| **INDEX** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/INDEX | Architecture laws, directory map | Every build |

### Documentation Pages

| Wiki Page | URL | Purpose |
|-----------|-----|---------|
| **README** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/README | Project overview |
| **SELF-BUILD** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/SELF-BUILD | Build modes (CI/CD, Windows, Linux, self-build) |
| **SECURITY** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/SECURITY | Security hardening patterns |
| **llms.txt** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/llms.txt | AI ingestion index |

### AI Integration Pages

| Wiki Page | URL | Purpose |
|-----------|-----|---------|
| **RAG Integration** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/RAG-Integration | Complete FOSS AI RAG setup |
| **Prompts Library** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/Prompts-Library | Task-specific AI prompts |
| **Knowledge Graph** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/Knowledge-Graph | Structured knowledge documentation |

### Engineering Specs

| Wiki Page | URL | Purpose |
|-----------|-----|---------|
| **FHS Compliance Audit** | https://github.com/Kabuki94/MiOS-bootstrap/wiki/engineering/2026-04-27-Artifact-ENG-006-FHS-Compliance-Audit | Linux filesystem compliance |

---

## Implementation for FOSS AI APIs

### Ollama

```bash
# System prompt with Wiki discovery
ollama run llama3.1:8b

>>> /set system """
You are a MiOS expert. IMPORTANT: Always check the MiOS Wiki for current information:
https://github.com/Kabuki94/MiOS-bootstrap/wiki

Key pages to reference:
- Home: Latest version and quick start
- AI-Integration-Index: Current AI patterns
- Quick-Reference: Essential commands

The Wiki updates with every build. Use it as PRIMARY source for current tasks.
"""

>>> How do I add a package to MiOS?
# Agent should first reference Wiki Quick-Reference or AI Agent Guide
```

### llama.cpp with Function Calling

```python
import requests
import json

def fetch_wiki_page(page_name):
    """Fetch Wiki page content"""
    url = f"https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/{page_name}.md"
    response = requests.get(url)
    return response.text if response.status_code == 200 else None

# Define function for model
functions = [
    {
        "name": "fetch_wiki_page",
        "description": "Fetch current MiOS Wiki page content. Use for latest documentation.",
        "parameters": {
            "type": "object",
            "properties": {
                "page_name": {
                    "type": "string",
                    "description": "Wiki page name (e.g., 'Home', 'Quick-Reference')"
                }
            },
            "required": ["page_name"]
        }
    }
]

# Model can now call fetch_wiki_page() to get latest info
```

### LocalAI with RAG

```python
from langchain.document_loaders import WebBaseLoader
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain.vectorstores import Chroma
from langchain.embeddings import HuggingFaceEmbeddings

# Wiki pages to index
wiki_pages = [
    "https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/Home.md",
    "https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/AI-Integration-Index.md",
    "https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/Quick-Reference.md",
    "https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/AI-AGENT-GUIDE.md",
]

# Load and split Wiki content
loader = WebBaseLoader(wiki_pages)
documents = loader.load()
text_splitter = RecursiveCharacterTextSplitter(chunk_size=512, chunk_overlap=50)
chunks = text_splitter.split_documents(documents)

# Create vector store with FOSS embeddings
embeddings = HuggingFaceEmbeddings(model_name="all-MiniLM-L6-v2")
vectorstore = Chroma.from_documents(chunks, embeddings)

# Query with Wiki context
query = "How do I add a package to MiOS?"
docs = vectorstore.similarity_search(query, k=3)
# Use retrieved Wiki content as context for LLM
```

### vLLM with Context Injection

```python
from vllm import LLM, SamplingParams
import requests

# Fetch latest Wiki content
def get_wiki_context():
    wiki_home = requests.get("https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/Home.md").text
    wiki_quick_ref = requests.get("https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/Quick-Reference.md").text
    return f"# MiOS Wiki Context\n\n{wiki_home}\n\n{wiki_quick_ref}"

# Initialize vLLM
llm = LLM(model="meta-llama/Llama-3.1-8B-Instruct")

# Inject Wiki context into system prompt
wiki_context = get_wiki_context()
system_prompt = f"""You are a MiOS expert.

{wiki_context}

Use the above Wiki content as your PRIMARY source for current MiOS information.
"""

# Generate with Wiki context
prompts = [f"{system_prompt}\n\nUser: How do I build MiOS?"]
outputs = llm.generate(prompts, SamplingParams(temperature=0.7, max_tokens=512))
```

---

## Automatic Wiki Updates

### How It Works

1. **Every Build:**
   ```bash
   just build-and-log  # Builds + logs artifacts to bootstrap
   ```

2. **Artifact Logging:**
   - `tools/log-to-bootstrap.sh` runs
   - Copies artifacts to `MiOS-bootstrap/ai-rag-packages/v0.1.3/`
   - Copies docs to `MiOS-bootstrap/wiki/v0.1.3/`
   - Copies build logs to `MiOS-bootstrap/build-logs/v0.1.3/`

3. **Wiki Sync:**
   - Script detects `MiOS-bootstrap.wiki` repository
   - Syncs all docs from `wiki/v0.1.3/` to Wiki repo
   - Auto-generates `Home.md` with latest version
   - Creates individual Wiki pages for AI integration docs
   - Auto-commits changes with timestamp

4. **Result:**
   - Wiki reflects latest build within minutes
   - AI agents can fetch updated docs immediately
   - Build logs available for troubleshooting

### What Gets Updated

**Every Build:**
- `Home.md` — Latest version, artifact links
- All core docs (INDEX, README, AI-AGENT-GUIDE, etc.)
- All AI integration docs
- Engineering specs (FHS audit, etc.)

**Every Build with Logs:**
- `build-logs/VERSION/latest-build.log` — Most recent build output

**Every Build with Outputs:**
- `output/VERSION/*.sha256` — Checksums for disk images
- `output/VERSION/*.json` — Build metadata

---

## Discovery Workflow for New Tasks

### Task: Add New Feature to MiOS

**Step 1: Check Wiki First**

```bash
# Fetch latest AI Agent Guide
curl -s https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/AI-AGENT-GUIDE.md | grep -A 20 "Protected Files"
```

**Step 2: Load Static Knowledge (if needed)**

```bash
# Use knowledge graph as baseline
cat mios-knowledge-graph.json | jq '.immutable_laws'
```

**Step 3: Cross-Reference**

- Wiki: Current build patterns, recent changes
- Static: Immutable laws, core architecture

**Step 4: Execute with Latest Info**

- Follow Wiki guidance for procedures
- Respect static laws for architecture

### Task: Troubleshoot Build Failure

**Step 1: Check Latest Build Log**

```bash
# Fetch from bootstrap repo
curl -s https://raw.githubusercontent.com/Kabuki94/MiOS-bootstrap/main/build-logs/v0.1.3/latest-build.log | tail -100
```

**Step 2: Check Wiki for Recent Patterns**

```bash
# Check if Wiki has updated troubleshooting guide
curl -s https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/AI-AGENT-GUIDE.md | grep -A 30 "Troubleshooting"
```

**Step 3: Apply Fix Based on Latest Info**

---

## Best Practices for AI Agents

### 1. **Wiki-First for Procedures**

✅ **DO:** Check Wiki for current build workflows, task patterns, recent research

❌ **DON'T:** Rely solely on static knowledge graph for procedural information

### 2. **Static-First for Laws**

✅ **DO:** Use static knowledge graph for immutable laws (USR-OVER-ETC, etc.)

❌ **DON'T:** Expect immutable laws to change in Wiki

### 3. **Hybrid Approach**

```python
def get_mios_context(task_type):
    if task_type == "architecture":
        # Immutable laws don't change
        return load_static_knowledge_graph()
    elif task_type == "build_procedure":
        # Procedures evolve
        return fetch_wiki_page("SELF-BUILD")
    elif task_type == "troubleshooting":
        # Check latest build logs
        return fetch_latest_build_log()
    else:
        # Default: Check Wiki first, fallback to static
        wiki_content = fetch_wiki_page("Home")
        return wiki_content if wiki_content else load_static_knowledge_graph()
```

### 4. **Cache Wiki Content (with TTL)**

```python
from datetime import datetime, timedelta

wiki_cache = {}
CACHE_TTL = timedelta(hours=1)  # Refresh every hour

def get_wiki_page_cached(page_name):
    now = datetime.now()
    if page_name in wiki_cache:
        content, timestamp = wiki_cache[page_name]
        if now - timestamp < CACHE_TTL:
            return content

    # Fetch fresh content
    content = fetch_wiki_page(page_name)
    wiki_cache[page_name] = (content, now)
    return content
```

### 5. **Fallback Gracefully**

```python
def get_mios_docs(prefer_wiki=True):
    if prefer_wiki:
        try:
            return fetch_wiki_page("Home")
        except Exception as e:
            print(f"Wiki unavailable: {e}, falling back to static docs")
            return load_static_readme()
    else:
        return load_static_readme()
```

---

## Integration Checklist

### For AI Agent Developers

- [ ] Include Wiki URL in system prompt initialization
- [ ] Add Wiki page fetching function (if web access available)
- [ ] Implement Wiki-first discovery pattern for procedural tasks
- [ ] Cache Wiki content with reasonable TTL (1-24 hours)
- [ ] Fallback to static knowledge graph when offline
- [ ] Cross-reference Wiki and static knowledge for accuracy
- [ ] Prioritize Wiki for: build logs, artifacts, recent specs
- [ ] Prioritize static for: immutable laws, core architecture

### For MiOS Developers

- [ ] Run `just log-bootstrap` after every build
- [ ] Push Wiki updates regularly (`cd ~/MiOS-bootstrap.wiki && git push`)
- [ ] Verify Wiki sync with `cat ~/MiOS-bootstrap.wiki/Home.md`
- [ ] Keep bootstrap repo up-to-date with artifacts
- [ ] Test Wiki discovery with sample AI prompts
- [ ] Update prompts library when adding new Wiki pages

---

## Example: Complete AI Agent Initialization

```python
import json
import requests

class MiOSAgent:
    def __init__(self):
        # Load static knowledge graph
        with open("mios-knowledge-graph.json") as f:
            self.static_knowledge = json.load(f)

        # Note Wiki as primary source
        self.wiki_base = self.static_knowledge["live_documentation"]["wiki"]
        print(f"✓ Loaded static knowledge (snapshot)")
        print(f"✓ Wiki URL: {self.wiki_base}")
        print(f"⚠️ Will check Wiki for current information")

    def get_context(self, task):
        """Get context for task, preferring Wiki"""
        if task in ["add_package", "build", "troubleshoot"]:
            # Fetch latest from Wiki
            try:
                wiki_page = self.fetch_wiki_page("Quick-Reference")
                print(f"✓ Using Wiki (current): Quick-Reference")
                return wiki_page
            except:
                print(f"⚠️ Wiki unavailable, using static knowledge")
                return self.static_knowledge
        else:
            # Use static for architecture
            return self.static_knowledge

    def fetch_wiki_page(self, page_name):
        """Fetch Wiki page content"""
        url = f"https://raw.githubusercontent.com/wiki/Kabuki94/MiOS-bootstrap/{page_name}.md"
        response = requests.get(url, timeout=5)
        response.raise_for_status()
        return response.text

# Initialize agent
agent = MiOSAgent()

# Get context for task
context = agent.get_context("add_package")
print(context[:500])  # Preview context
```

---

## References

- **Wiki Home:** https://github.com/Kabuki94/MiOS-bootstrap/wiki
- **Bootstrap Repo:** https://github.com/Kabuki94/MiOS-bootstrap
- **Logging Script:** [tools/log-to-bootstrap.sh](../../tools/log-to-bootstrap.sh)
- **Knowledge Graph:** [artifacts/ai-rag/mios-knowledge-graph.json](../../artifacts/ai-rag/mios-knowledge-graph.json)
- **RAG Manifest:** [artifacts/ai-rag/rag-manifest.yaml](../../artifacts/ai-rag/rag-manifest.yaml)
- **Prompts Library:** [2026-04-27-Artifact-AI-003-Prompts-Library.md](2026-04-27-Artifact-AI-003-Prompts-Library.md)

---

<!-- ⚖️ MiOS Proprietary Artifact | Copyright (c) 2026 MiOS-DEV -->
