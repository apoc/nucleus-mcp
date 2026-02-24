# Nucleus MCP Server

**Agentic Code Intelligence via Model Context Protocol**

Nucleus is an MCP (Model Context Protocol) server that provides AI agents with deep, semantic understanding of codebases. It combines semantic search, keyword matching, and code structure analysis to answer both conceptual queries ("Where is the auth logic?") and precise navigation ("Who calls `verify_token`?").

## Features

- **Hybrid Search**: Semantic concept matching, exact keyword search, and structural analysis (who calls whom)
- **Incremental Indexing**: Only changed files are re-indexed
- **Multi-Language Support**: Rust, Python, TypeScript, C, C++, C#, Dart, Go, Java, Lua, and YARA
- **Local-First**: All data stored in `.nucleus/` within your project — no external services required
- **Cognitive Memory**: Agents persist learnings across sessions
- **GPU Accelerated**: Supports CUDA, DirectML, OpenVINO, and Metal (macOS)

## Quick Start

### 1. Download & Install

1. Download the latest release ZIP for your platform from the [Releases](https://github.com/apoc/nucleus-mcp/releases) page.
2. Unpack the ZIP to your desired install location, e.g.:

```powershell
# Windows example
Expand-Archive -Path nucleus-server_win64.zip -DestinationPath "C:\Tools\nucleus"
```

> **macOS and Linux:** Coming soon.

### 2. GPU Setup (Windows)

Run the setup script to install the inference runtime libraries into the same directory as the binary:

**DirectML (Windows — works with any GPU)**
```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup-gpu.ps1 directml -OutputDir "C:\Tools\nucleus"
```

**NVIDIA CUDA**
```powershell
# Requires CUDA Toolkit 11.8+ and cuDNN 8.x
powershell -ExecutionPolicy Bypass -File scripts/setup-gpu.ps1 cuda -OutputDir "C:\Tools\nucleus"
```

**Intel OpenVINO**
```powershell
# For Intel CPUs, integrated/discrete GPUs (Arc), and NPUs
powershell -ExecutionPolicy Bypass -File scripts/setup-gpu.ps1 openvino -OutputDir "C:\Tools\nucleus"
```

Supported Intel hardware:
- **CPU** — Any Intel CPU (Core, Xeon)
- **iGPU** — Integrated graphics (11th gen+)
- **dGPU** — Discrete GPUs (Intel Arc A-series)
- **NPU** — Neural Processing Unit (Intel Core Ultra / Meteor Lake and newer)

**CPU only**
```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup-gpu.ps1 cpu -OutputDir "C:\Tools\nucleus"
```

Replace `C:\Tools\nucleus` with the path where you unpacked the binary.

You can also override the temporary download directory:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup-gpu.ps1 directml `
    -OutputDir "C:\Tools\nucleus" `
    -TempDir "D:\scratch"
```

**macOS (Apple Silicon):** No setup needed — GPU acceleration via Metal is automatic.

### 3. First Run (Model Download)

Run the server once in a console to download AI models and verify the setup:

```bash
C:\Tools\nucleus\nucleus-server --root /path/to/your/project
```

On first run, embedding and reranking models are downloaded automatically (~2.3–3.3 GB depending on configuration — embedding model plus ~1.1 GB reranker). The console output shows model loading, GPU device selection, and indexing progress.

Models are cached in:
- **Windows:** `%LOCALAPPDATA%\fastembed\`
- **macOS/Linux:** `~/.cache/fastembed/`

Override with: `FASTEMBED_CACHE_PATH=/custom/path`

### 4. Add to Your MCP Client

#### Claude Desktop (`~/.claude/claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "nucleus": {
      "command": "C:\\Tools\\nucleus\\nucleus-server",
      "args": []
    }
  }
}
```

#### VS Code (`.vscode/mcp.json` or User Settings)

```json
{
  "servers": {
    "nucleus": {
      "command": "C:\\Tools\\nucleus\\nucleus-server",
      "args": [],
      "type": "stdio"
    }
  }
}
```

#### Cursor (`~/.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "nucleus": {
      "command": "C:\\Tools\\nucleus\\nucleus-server",
      "args": []
    }
  }
}
```

#### Claude Code (CLI)

```bash
claude mcp add nucleus C:\Tools\nucleus\nucleus-server
```

> Replace `C:\Tools\nucleus\nucleus-server` with the actual path to your binary in all examples above.

## Available Tools

### Code Search & Navigation

| Tool | Description |
|------|-------------|
| `search_code` | Semantic search across the codebase. Returns file-level results with matched symbols. |
| `search_symbols` | Search for symbols by name. Returns precise locations with line numbers. |
| `get_symbol` | Get full symbol definition by ID — signature, docstring, code, and relations. |
| `get_symbols` | Batch fetch multiple symbol definitions. |
| `get_usages` | Get all references to a symbol with locations and code snippets. |
| `resolve_symbol_at` | Resolve the reference at a given file and line to its definition. Returns `symbol_id` and location. |
| `find_similar_code` | Find code similar to a snippet. Use before writing new code to check for existing patterns. |
| `find_duplicate_code` | Detect near-duplicate code clusters across the codebase. Scores ≥0.95 are clones, 0.90–0.95 are similar. |
| `file_overview` | Get structural overview of all symbols in a file. |
| `class_overview` | Get API surface of a class/struct: methods, bases, traits — without bodies. |
| `get_implementors` | Get all types that implement a trait or interface. |
| `get_dependency_graph` | File-level dependency graph: who imports this file (inbound) and what it imports (outbound). |

### Project & Index Management

| Tool | Description |
|------|-------------|
| `list_dir` | List contents of a directory within the indexed project. |
| `project_info` | Get project statistics: file counts, symbol counts, languages, index health. |
| `status` | Get indexing status and system health. |
| `reindex` | Trigger a full or incremental reindex. Use `{"force": true}` to rebuild from scratch. |

### Cognitive Memory

| Tool | Description |
|------|-------------|
| `cognitive_trigger` | Manage the memory session lifecycle: `start`, `end`, `problem_appeared`, `problem_solved`. |
| `read_memory` | Retrieve relevant memories using semantic search. |
| `write_memory` | Persist a new memory (code patterns, decisions, learnings). |
| `update_memory` | Amend an existing memory. |

## Configuration

Create `.nucleus/config.json` in your project root to customize behavior:

```json
{
  "embedding": {
    "model": "Qwen3",
    "max_length": 512,
    "batch_size": 32
  },
  "indexer": {
    "include": ["**/*.rs", "**/*.py", "**/*.ts", "**/*.js"],
    "exclude": ["target", "node_modules", ".git", "dist"],
    "max_file_size_bytes": 10485760
  }
}
```

### Embedding Models

| Model | Size | Description |
|-------|------|-------------|
| `Qwen3` (default) | ~1.2 GB | Best for code search. Dense vectors only. |
| `BGEM3` | ~2.2 GB | Hybrid search with both dense and sparse vectors. |

To switch models, update `config.json` and run `reindex` with `force: true`.

## Environment Variables

### Core

| Variable | Description | Default |
|----------|-------------|---------|
| `NUCLEUS_EP` | Execution provider (Windows/Linux): `cuda`, `openvino`, `directml`, `cpu` | Auto-detect |
| `FASTEMBED_CACHE_PATH` | Model cache directory | OS default (see above) |
| `RUST_LOG` | Logging level: `error`, `warn`, `info`, `debug`, `trace` | `info` |

### CUDA Tuning (NVIDIA GPUs)

| Variable | Default | Description |
|----------|---------|-------------|
| `NUCLEUS_CUDA_MEM_LIMIT` | unlimited | GPU memory limit in bytes |
| `NUCLEUS_CUDA_CUDNN_CONV_ALGO` | `EXHAUSTIVE` | Algorithm search: `DEFAULT`, `HEURISTIC`, `EXHAUSTIVE` |
| `NUCLEUS_CUDA_ARENA_STRATEGY` | `SameAsRequested` | Memory strategy: `NextPowerOfTwo`, `SameAsRequested` |

### OpenVINO Tuning (Intel)

| Variable | Default | Description |
|----------|---------|-------------|
| `NUCLEUS_OPENVINO_DEVICE` | `GPU` | Device: `GPU`, `GPU.0`, `NPU`, `CPU` |
| `NUCLEUS_OPENVINO_PRECISION` | `FP16` | Precision: `FP16`, `FP32` |
| `NUCLEUS_OPENVINO_STREAMS` | `8` | Parallel execution streams (1–255) |
| `NUCLEUS_OPENVINO_CACHE_DIR` | auto | Model cache directory |

## Upgrading

After upgrading Nucleus, you may need to reindex:

```bash
# Delete existing index and restart the server
rm -rf .nucleus/

# Or trigger via MCP tool:
# reindex with force: true
```

**When to reindex:**
- After upgrading to a new Nucleus version
- After changing the embedding model
- If search results seem stale or incomplete

