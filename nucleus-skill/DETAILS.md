# Nucleus MCP Navigation — Detailed Reference

## Purpose

This document provides **detailed reasoning and examples** for codebase navigation
using the Nucleus MCP server. It encodes expert patterns and prevents common
failure modes.

For quick reference, see `SKILL.md`.

---

## The Precedence Problem (Root Cause Analysis)

### Why Agents Default to Explore Instead of Nucleus

When given a codebase navigation task, agents often spawn `Task(subagent_type=Explore)` instead of using Nucleus MCP tools directly. This happens due to three factors:

1. **Agent Role Precedence**: Once an Explore agent is spawned, its tool universe is fixed to (Glob, Grep, Read). MCP tools are invisible. The decision tree prunes Nucleus before any reasoning happens.

2. **Habitual Search Priors**: Grep/Glob patterns are older, cheaper, and "never wrong" (just inefficient). Under uncertainty, agents fall back to what has always worked.

3. **Pull-Based Skill Invocation**: Skills require active recognition → decision → context switch. Generic exploration requires no such switch.

### The Mechanism

```
Agent receives: "Where is the auth logic?"
                    │
                    ▼
        ┌─────────────────────┐
        │ Decision Point      │  ← THIS is where Nucleus must win
        │                     │
        │ Option A: Explore   │  ← Lower activation cost, wins by default
        │ Option B: Nucleus   │  ← Higher precision, but requires intent
        └─────────────────────┘
                    │
        Agent picks Explore (habit)
                    │
                    ▼
        ┌─────────────────────┐
        │ Explore Agent       │
        │ Tools: Glob, Grep,  │  ← Nucleus not visible here
        │        Read         │
        └─────────────────────┘
                    │
        Nucleus never considered
```

### The Fix

The check must happen BEFORE agent role selection:

```
Agent receives: "Where is the auth logic?"
                    │
                    ▼
        ┌─────────────────────┐
        │ Is Nucleus MCP      │  ← NEW: Check first
        │ available?          │
        └─────────────────────┘
                    │
            ┌───────┴───────┐
            │               │
           YES              NO
            │               │
            ▼               ▼
    Use Nucleus        Fallback to
    directly           Explore agent
```

**Nucleus is the navigation substrate. Explore is the fallback.**

---

## Mental Model

Nucleus is a **knowledge graph**, not a search tool.

**Core concept:** `symbol_id` is a join key for graph traversal, not just an opaque handle.

```
search_symbols("UserBuilder") → sym_42
        │
        ├─→ get_symbol(sym_42)  → full definition + signature
        │
        └─→ get_usages(sym_42)  → all call sites → more symbol_ids → traverse further
```

The two-step `search → get` pattern enables:
- Explicit ambiguity handling (multiple matches, you pick)
- Stable identity for chained traversal
- Lightweight search, heavy inspection on demand

---

## Tool Semantics (Authoritative)

### `search_code`
- Use for **conceptual discovery**
- Returns **ranked files** with snippets
- `matched_symbols` array is populated via **graph expansion only** — may be empty for pure vector matches
- **Does NOT guarantee line numbers**
- Results are *not edit-ready*

#### Search Intents
The `intent` parameter (supported by `search_code` and `search_symbols`) biases the search strategy for different tasks:
- `logic` (default): Use for finding implementation details and "how-to". High reranker weight.
- `exploration`: Use for finding definitions and API surface. Biased toward lexical (BM25) search.
- `usage`: Use for finding call sites and examples. Semantic-heavy.
- `debug`: Use for tracing flows and structural dependencies. Graph-heavy.

If line numbers are required, use `search_symbols` with the function/class name from the snippet to obtain a valid `symbol_id`.

---

### `search_symbols`
- Use when you **know the symbol name**
- **Primary source for `symbol_id`** — returns IDs in `sym_<id>` format (opaque, content-addressable)
- Returns **precise locations with line numbers**
- Suitable for navigation and editing
- **Query Parameter**: Accepts an array of strings (e.g., `["User", "Auth"]`) for efficient batch lookup.
- Supports batch lookup when multiple names are known
- **Directory scoping**: Optional `directories` parameter restricts both exact match and exploratory fallback to specified directory prefixes (e.g., `["nucleus-index", "nucleus-store"]`). Critical for multi-project repos to avoid cross-project noise.

A result with `location.line` is **edit-grade**.

**Important**: Symbol IDs are opaque tokens. Never fabricate IDs from file paths or symbol names — always obtain via this tool.

#### Response includes `line_count`

Each match now includes `line_count` (estimated from byte ranges):

```json
{
  "symbol_id": "sym_42",
  "name": "process_request",
  "kind": "fn",
  "line_count": 57,
  "location": { "file": "handler.rs", "line": 120 }
}
```

**Agent strategy**: Check `line_count` before calling `get_symbol`:
- Small symbol (≤25 lines): Default preview mode is sufficient
- Medium symbol (26-500 lines): Use `body_mode: "full"` to get complete body
- Large symbol (>500 lines): Use `range` parameter for windowed extraction

---

### `get_symbol`
- Use to **inspect a definition before editing**
- Returns:
  - precise location (file + line)
  - signature
  - docstring
  - code snippet (configurable size)
  - implementation relations
  - truncation metadata (when applicable)
- Prefer this before making changes

#### Body Extraction Modes

Control how much code is returned using `body_mode` or `range`:

| Mode | Parameter | Behavior |
|------|-----------|----------|
| Preview (default) | omit or `body_mode: "preview"` | First 25 lines |
| Full | `body_mode: "full"` | Complete body (max 500 lines) |
| Windowed | `range: { start_line: N, line_count: M }` | Lines N to N+M within symbol |

**Precedence**: `range` > `body_mode` > default

#### Usage Examples

```jsonc
// Default preview (first 25 lines)
get_symbol({ "symbol_id": "sym_123" })

// Full body (capped at 500 lines)
get_symbol({ "symbol_id": "sym_123", "body_mode": "full" })

// Lines 50-75 within symbol
get_symbol({ "symbol_id": "sym_123", "range": { "start_line": 50, "line_count": 25 } })
```

#### Truncation Metadata

When truncation occurs, the response includes explicit metadata:

| Field | When Present | Meaning |
|-------|--------------|---------|
| `truncation_reason` | `is_truncated: true` | Why: `"preview_limit"`, `"server_limit"`, or `"windowed"` |
| `preview_limit` | Preview mode truncated | Exposes the 25-line cap |
| `server_max_lines` | Full mode truncated | Exposes the 500-line cap |
| `start_line` | Windowed mode | Starting line offset within symbol |

**Example responses**:

```jsonc
// Preview mode, truncated
{
  "shown_lines": 25,
  "total_lines": 127,
  "is_truncated": true,
  "truncation_reason": "preview_limit",
  "preview_limit": 25
}

// Full mode, hit server cap
{
  "shown_lines": 500,
  "total_lines": 645,
  "is_truncated": true,
  "truncation_reason": "server_limit",
  "server_max_lines": 500
}

// Windowed mode
{
  "shown_lines": 25,
  "total_lines": 127,
  "is_truncated": true,
  "truncation_reason": "windowed",
  "start_line": 50
}

// Full mode, no truncation needed
{
  "shown_lines": 57,
  "total_lines": 57,
  "is_truncated": false
}
```

#### Strategy for Large Symbols

For symbols >500 lines (rare but possible):

1. Use `body_mode: "full"` to get first 500 lines
2. If more needed, use `range: { start_line: 500, line_count: 500 }` for next window
3. Repeat until full symbol is retrieved

**Tip**: Most symbols fit within the 500-line cap. Use `line_count` from `search_symbols` to plan your fetch strategy before calling `get_symbol`.

---

### `get_symbols`
- Use for **batch fetching multiple symbols** (1-20 IDs per call)
- Reduces round-trips when exploring a file or analyzing impact
- Same response format as `get_symbol` per symbol
- Partial failures allowed (some symbols may fail, others succeed)
- **No windowed `range` support** — use `body_mode` only. For windowed extraction, use `get_symbol` per ID.

```jsonc
// Batch fetch after file_overview
get_symbols({
  "symbol_ids": ["sym_101", "sym_102", "sym_103"],
  "body_mode": "preview"
})
```

**Response includes summary:**
```json
{ "summary": { "requested": 3, "resolved": 3, "ok": 2, "errors": 1 } }
```

---

### `get_usages`
- Use for **impact analysis**
- Returns all references with line numbers
- Required before refactoring or API changes
- Pagination may apply

---

### `get_dependency_graph`
- Use for **file-level impact analysis** — "what breaks if I change this file?"
- Aggregates symbol-level refs into file-level dependency relationships
- Replaces 5-15 `get_usages` calls with a single call
- Self-references (file referencing its own symbols) are excluded

#### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `file` | Yes | — | File path (relative to repo root) |
| `direction` | No | `"both"` | `"inbound"`, `"outbound"`, or `"both"` |
| `limit` | No | 30 | Max files per direction |

#### Response Format

```json
{
  "status": "ok",
  "file": "nucleus-store/src/state_db.rs",
  "inbound": [
    {
      "file": "nucleus-index/src/indexer.rs",
      "references": [
        { "symbol": "insert_file", "symbol_id": "sym_abc", "kind": "call", "count": 3 },
        { "symbol": "get_file_by_path", "symbol_id": "sym_def", "kind": "call", "count": 2 }
      ]
    }
  ],
  "outbound": [
    {
      "file": "nucleus-core/src/error.rs",
      "references": [
        { "symbol": "NucleusError", "symbol_id": "sym_xyz", "kind": "type_use", "count": 1 }
      ]
    }
  ],
  "total_inbound_files": 12,
  "total_outbound_files": 5,
  "truncated": false
}
```

**Key fields:**
- `total_inbound_files` / `total_outbound_files`: Always present for scale awareness (hub files may have hundreds of dependents)
- `truncated`: `true` when results capped by limit — check total counts for full picture
- Omitted directions (when using `"inbound"` or `"outbound"`) are `null`, not empty arrays

#### When to Use

| Scenario | Tool |
|----------|------|
| "What breaks if I change this file?" | `get_dependency_graph(direction="inbound")` |
| "What does this file depend on?" | `get_dependency_graph(direction="outbound")` |
| "Full context for this file" | `get_dependency_graph` (both directions) |
| Need symbol-level call sites | `get_usages` (per-symbol, with snippets) |

---

### `resolve_symbol_at`
- Use to **resolve a reference at a known file position** to its definition
- An **index introspection tool**, not an IDE replacement
- Coverage ~70-80%: local variables, some generics, and unresolved cross-module refs are not captured

#### Resolution Tiers (4-tier fallback)

| Tier | Method | Confidence | Description |
|------|--------|------------|-------------|
| 1 | `ref` | Ground truth | Direct reference from refs table. Innermost span wins. |
| 2 | `definition` | Ground truth | Cursor is on a symbol definition itself. |
| 3 | `import_heuristic` | Best-effort | Resolved via import qualified_path lookup. |
| 4 | (unresolved) | — | No indexed reference found. Returns nearby symbols as hints. |

#### Response Formats

**Resolved (ref or definition):**
```json
{
  "status": "resolved",
  "resolution_method": "ref",
  "stale": false,
  "source": { "file": "src/indexer.rs", "line": 670, "text": "db.get_file_by_path(&path)" },
  "definition": {
    "symbol_name": "get_file_by_path",
    "symbol_id": "sym_Xyz123",
    "kind": "fn",
    "file": "src/state_db.rs",
    "line": 412,
    "signature": "pub fn get_file_by_path(&self, path: &str) -> Result<Option<FileRecord>>"
  },
  "reference_kind": "call"
}
```

**Unresolved:**
```json
{
  "status": "unresolved",
  "stale": false,
  "context": "No indexed reference at this position. Coverage: ~70-80% of references.",
  "nearby_symbols": [
    { "name": "embed_indexed_files", "symbol_id": "sym_abc", "kind": "fn", "line": 596 }
  ]
}
```

#### Key Fields

| Field | Description |
|-------|-------------|
| `stale` | `true` when file changed since indexing (byte offsets may be wrong) |
| `resolution_method` | `"ref"`, `"definition"`, or `"import_heuristic"` |
| `reference_kind` | `"call"`, `"import"`, `"type_use"`, `"impl"`, `"inherit"` |
| `nearby_symbols` | Top 3 symbols by byte proximity (unresolved tier only) |

#### Column Disambiguation

When multiple refs exist on the same line, use `column` (1-based) to target a specific reference:
```jsonc
// Without column: resolves to enclosing definition (largest span)
resolve_symbol_at({ "file": "src/resolution.rs", "line": 124 })

// With column: resolves to specific call at that position
resolve_symbol_at({ "file": "src/resolution.rs", "line": 124, "column": 50 })
```

#### When to Use

| Scenario | Tool |
|----------|------|
| Know file + line, want definition | `resolve_symbol_at` |
| Know symbol name, want definition | `search_symbols` → `get_symbol` |
| Following a chain of references | `resolve_symbol_at` repeatedly |
| Need all callers of a symbol | `get_usages` |

---

### `class_overview`
- Use to **understand class/struct API surface** before editing
- Returns methods (with signatures, visibility, docstrings), base classes, and traits **without implementation bodies**
- **PREFER over `get_symbol` + `file_overview`** when you need to understand what a type does and what contracts it fulfills
- One call replaces: `file_overview` + multiple `get_symbol` calls + manual trait-to-impl mapping

#### When class_overview Wins
- Understanding a struct's dependencies from its constructor (e.g., what `Arc<dyn ...>` it takes)
- Seeing which traits a struct implements and all methods at once
- Comparing parallel implementations across modules (e.g., similar service structs)
- Planning refactors: see the full method surface before editing

#### Valid Symbol Kinds
Only works with: `struct`, `trait`, `impl` (NOT `class`, NOT `enum`). OOP classes (Python, Java, C++, etc.) are indexed as `struct`.

#### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `symbol_id` | Yes | Symbol ID of a struct, class, trait, or impl block |

#### Response Fields

| Field | Description |
|-------|-------------|
| `methods` | Array of method signatures with visibility |
| `bases` | Base classes (C++/Python inheritance) |
| `traits` | Implemented traits (Rust) or interfaces |

**INVARIANT:** `bases` and `traits` represent declared relationships in source code, not runtime behavior or method resolution order.

#### Usage Example

```jsonc
// First, find the class
search_symbols({ "query": ["UserService"] })
// → { "symbol_id": "sym_42", "kind": "struct", ... }

// Then get its API surface
class_overview({ "symbol_id": "sym_42" })
// → { "methods": [...], "traits": ["Debug", "Clone"], ... }
```

#### When to Use

| Scenario | Tool |
|----------|------|
| Need full method implementation | `get_symbol` with `body_mode: "full"` |
| Need API surface only (what methods exist) | `class_overview` |
| Need all symbols in a file | `file_overview` |

---

### `find_similar_code`
- Use **before writing new code**
- Detects existing similar implementations
- Prevents duplication
- Similarity is **semantic** (code structure and naming patterns), NOT functional equivalence
- Two implementations doing the same thing with different patterns may score low
- Similar-looking code doing different things may score high

#### Cross-Domain Pattern Discovery
Also valuable for **impact analysis at the pattern level**: finding all code that follows the same structural pattern across different modules.

**Examples:**
- All service impls that validate-then-iterate
- All handlers with the same request/response shape
- All modules using a particular initialization pattern

This goes beyond deduplication — use it to understand how widely a pattern is used before changing it.

---

### `file_overview`
- Use to **understand file structure** before editing
- Returns **ordered list** of all symbols with selection signals
- Each symbol includes `symbol_id` for direct `get_symbol`/`get_symbols` follow-up
- Symbols ordered by source position; parents always precede children

#### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `file` | Yes | File path (relative to repo root, any slash format accepted) |
| `depth` | No | Maximum nesting depth (default: 0 = top-level only) |

**Depth semantics:**

| Depth | When to use |
|-------|-------------|
| 0 (default) | Initial scan - just "what's in here?" (classes, functions, constants). Fastest, smallest output. |
| 1 | See class structure including methods. Good for understanding API surface. |
| 2+ | Rarely needed. Only for nested classes or deeply structured code. |
| 99 | Return all symbols regardless of depth (explicit opt-in). |

**Note:** Default is conservative (top-level only). Increase depth selectively after initial scan.

**Note:** Depth filtering is purely numeric and does not guarantee parent presence for every returned symbol.

#### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Symbol name |
| `kind` | string | Symbol kind (`fn`, `struct`, `impl`, `mod`, etc.) |
| `symbol_id` | string | ID for `get_symbol`/`get_symbols`/`get_usages` (format: `sym_<id>`) |
| `depth` | number | Nesting depth (0 = top-level). Omitted when 0. |
| `line` | number | 1-based line number |
| `line_count` | number | Lines in symbol body (selection signal) |
| `is_private` | boolean | Internal/private symbol. Omitted when false (public) or unknown. More reliable for Rust/TypeScript; less reliable for Python/C. |
| `signature_preview` | string | ≤80 chars, truncated hint (non-authoritative) |
| `doc_summary` | string? | ≤100 chars, first doc line (intent hint) |
| `parent_id` | string? | Parent symbol ID for grouping (format: `sym_<id>`) |

#### Selection Signals

Use these fields to decide which symbols to inspect before fetching:

| Signal | Use Case |
|--------|----------|
| `line_count` | Prioritize large symbols (>50 lines = likely core logic) |
| `is_private` | Omitted = public API or unknown; present = internal helper |
| `signature_preview` | Quick method shape without full fetch |
| `doc_summary` | Understand intent before drilling in |

#### Example Response

```json
{
  "status": "ok",
  "file": "src/server.rs",
  "language": "rust",
  "symbol_count": 61,
  "symbols": [
    {"name": "TOOL_SCHEMAS", "kind": "const", "symbol_id": "sym_101", "line": 45, "line_count": 3, "is_private": true},
    {"name": "NucleusServer", "kind": "struct", "symbol_id": "sym_102", "line": 120, "line_count": 15, "doc_summary": "Main server handler for MCP protocol"},
    {"name": "NucleusServer", "kind": "impl", "symbol_id": "sym_103", "line": 135, "line_count": 450, "is_private": true},
    {"name": "search", "kind": "fn", "symbol_id": "sym_104", "depth": 1, "line": 200, "line_count": 87, "parent_id": "sym_103", "signature_preview": "pub async fn search(&self, query: &str) -> Result<…>"},
    {"name": "tests", "kind": "mod", "symbol_id": "sym_105", "line": 900, "line_count": 150, "is_private": true},
    {"name": "test_search", "kind": "fn", "symbol_id": "sym_106", "depth": 1, "line": 910, "line_count": 25, "is_private": true, "parent_id": "sym_105"}
  ],
  "stability": "ephemeral_session",
  "stability_note": "Symbols reflect static analysis only..."
}
```

#### Usage Examples

```jsonc
// Top-level only (default)
file_overview({ "file": "src/server.rs" })

// Include methods/fields
file_overview({ "file": "src/server.rs", "depth": 1 })

// All depths (explicit)
file_overview({ "file": "src/server.rs", "depth": 99 })
```

#### Path Normalization

The tool accepts any path format and normalizes internally:
- `src/server.rs` → works
- `src\server.rs` → works (backslashes converted)
- `./src/server.rs` → works (leading `./` stripped)

#### Limitations

- No struct fields (not extracted by parser)
- No enum variants (not extracted by parser)
- Hierarchy derived from byte containment, not AST parent pointers

---

### `list_dir`
- Use to **explore directory contents** within the indexed project
- Returns files and subdirectories at the specified path
- Supports **pagination** for large directories

#### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `path` | Yes | — | Directory path relative to project root |
| `limit` | No | 100 | Maximum entries per page (1-1000) |
| `offset` | No | 0 | Number of entries to skip |

#### Response Format

```json
{
  "status": "ok",
  "path": "src/",
  "entries": [
    { "name": "lib.rs", "type": "file" },
    { "name": "parser/", "type": "directory" }
  ],
  "pagination": {
    "total_count": 45,
    "has_more": false
  }
}
```

#### Pagination Pattern

For directories with many entries, use `offset` to paginate:

```jsonc
// First page
list_dir({ "path": "src/", "limit": 20 })
// → pagination: { total_count: 45, has_more: true }

// Second page
list_dir({ "path": "src/", "limit": 20, "offset": 20 })
// → pagination: { total_count: 45, has_more: true }

// Third page (final)
list_dir({ "path": "src/", "limit": 20, "offset": 40 })
// → pagination: { total_count: 45, has_more: false }
```

#### When to Use

| Scenario | Tool |
|----------|------|
| Need symbol-level detail in a file | `file_overview` |
| Need to list directory contents | `list_dir` |
| Need project-wide statistics | `project_info` |

---

### `project_info`
- Use for **epistemic scaffolding** — "what assumptions can I make before reasoning?"
- Returns indexed state, NOT repository truth
- All values describe what is currently indexed and queryable

#### Parameters

None (v1). Returns all available statistics.

#### Response Format

```json
{
  "files": {
    "total": 1842,
    "by_language": { "rust": 612, "typescript": 403, "lua": 17 }
  },
  "symbols": {
    "total": 12431,
    "by_kind": { "function": 8201, "class": 431, "struct": 912, "module": 2887 }
  },
  "directories": [
    { "path": "backend/", "files": 712 },
    { "path": "frontend/", "files": 398 }
  ],
  "languages": {
    "rust": { "indexed": true },
    "typescript": { "indexed": true }
  },
  "index": {
    "status": "fresh",
    "last_indexed_at": "2026-02-03T09:41:00Z"
  }
}
```

#### Field Semantics

| Field | Description |
|-------|-------------|
| `files.total` | Count of indexed files |
| `files.by_language` | File counts grouped by detected language |
| `symbols.total` | Count of indexed symbols (excluding orphans) |
| `symbols.by_kind` | Symbol counts grouped by kind (fn, struct, class, etc.) |
| `directories` | Top-level directories with ≥10 files, max 20, sorted by file count descending |
| `languages` | Languages with indexed files (absence ≠ non-existence) |
| `index.status` | `"fresh"` (up-to-date), `"partial"` (pending embeddings), or `"indexing"` (in progress) |
| `index.last_indexed_at` | ISO 8601 timestamp of last completed index |

#### Non-Negotiable Invariants

```
INVARIANT 1: project_info MUST NEVER block on missing data.
             Partial, degraded, or zeroed responses are always preferable to errors.

INVARIANT 2: All counts reflect indexed state only.
             Languages not listed may exist in the repository but are not indexed.

INVARIANT 3: Directory aggregation is best-effort and workspace-unaware in v1.
             Monorepo structures may produce suboptimal groupings.
```

#### Directory Aggregation Rules

| Rule | Value |
|------|-------|
| Depth | 1 (first path component only) |
| min_files | 10 (directories with fewer files omitted) |
| max_dirs | 20 (hard cap) |
| Sort | File count descending |
| Workspace-aware | No (v1 limitation) |

#### Usage Example

```jsonc
// Get project overview before planning implementation
project_info({})
// → Use files.by_language to understand tech stack
// → Use symbols.by_kind to calibrate search expectations
// → Use directories to identify code organization
// → Check index.status before relying on search results
```

#### When to Use

| Scenario | Use project_info? |
|----------|------------------|
| Starting work on unfamiliar codebase | ✅ Yes — calibrate expectations |
| Planning large refactor | ✅ Yes — understand scope |
| Quick symbol lookup | ❌ No — use search_symbols directly |
| After indexing completes | ✅ Yes — verify index health |

---

## Score Interpretation

Results from `search_code` include multiple scoring signals:

| Score | Meaning | High When |
|-------|---------|-----------|
| `dense_score` | Semantic similarity (concept match) | Query and code share meaning |
| `sparse_score` | Lexical overlap (term match) | Exact/partial name matches |
| `graph_boost` | Reference graph centrality | Symbol is heavily referenced |
| **Final Score** | **Normalized Blend** | Blended via Sigmoid + Intent Weights |

**Score Stability**: 
Nucleus applies **Sigmoid Activation** to raw reranker logits before blending. This ensures the final score is always a stable blend of H-GAR and Reranking signals, preventing one signal from mathematically "masking" the other.

**When to trust which:**
- **Known symbol name** → `sparse_score` (lexical match matters)
- **Conceptual query** ("error handling") → `dense_score` (semantic)
- **Core infrastructure** → `graph_boost` (highly connected = important)

---

## Exploratory Mode

When `search_symbols` returns no exact match, it falls back to **exploratory mode** via semantic search:

```json
{
  "query": "UserBuilder",
  "symbols": [],
  "exploratory": [
    { "location": { "file": "src/user.rs", "line": 45 }, "confidence": 0.73, "match_reason": "semantic_search", "snippet": "..." }
  ]
}
```

**Response interpretation:**
- `symbols` populated → Exact name match found (use `symbol_id` directly)
- `symbols` empty + `exploratory` populated → Semantic fallback (evidence, not confirmation)
- Both empty → No results for this query

**Agents SHOULD prefer `symbols` over `exploratory` results when both are present.** The `intent` parameter only affects exploratory fallback scoring, not exact matching.

**Use case:** Fuzzy/partial name lookups, typos, discovering related code.

---

## Precision Signals

Interpret precision explicitly:

- **Data**: `location.line` present → result includes a line number
- **Metadata**: `precision_hint.level == "line"` → tool confirms edit-grade precision
- **Coverage**: `index_coverage.status` may indicate partial indexing

Prefer metadata signals when available; fall back to data inspection.

Never assume edit safety without line-level precision.

---

## Common Failure Modes (Avoid)

| Failure | Why it's wrong |
|---------|----------------|
| Editing based on `search_code` results alone | File-level results lack precise locations |
| Skipping `get_usages` before refactoring | May break unknown callers |
| Writing new code without `find_similar_code` | Duplicates existing implementations |
| Treating semantic similarity as exact match | Similarity is advisory, not proof |
| Fabricating `symbol_id` from file path + name | IDs are opaque `sym_<id>` tokens; guessed IDs fail with "stale or invalid" |
| Assuming `matched_symbols` is always populated | Only filled via graph expansion; may be empty for pure vector matches |
| Using `search_code` → `get_symbol` directly | Use `search_code` → `search_symbols` → `get_symbol` (search_symbols provides valid IDs) |
| Ignoring `line_count` from `search_symbols` | Wastes tokens on truncated previews; use `body_mode: "full"` for large symbols |
| Not checking `is_truncated` in response | May miss important code at end of symbol; use `range` to fetch remaining lines |
| Guessing symbol names in unfamiliar file | Use `file_overview` first to see all symbols and their hierarchy |
| Calling `get_symbol` repeatedly in a loop | Use `get_symbols` for batch fetch (1-20 IDs per call) |
| Ignoring `is_private` / `line_count` in file_overview | Use selection signals to prioritize which symbols to inspect |
| Using `Read` for code inspection without attempting `get_symbol` first | Wastes 5-10x tokens; violates Cost Policy |
| Calling `get_usages` per-symbol for file-level impact | Use `get_dependency_graph` — single call replaces 5-15 `get_usages` calls |
| Using `search_symbols` when you already know file + line | Use `resolve_symbol_at` — direct position-based resolution |
| Assuming `resolve_symbol_at` covers all references | Coverage ~70-80%; local variables and some generics are not indexed |

---

## Cost Policy (Authoritative)

### The Rule

**Do not call Read for code inspection unless get_symbol has been attempted and fallback criteria are met.**

### Fallback Criteria (Authoritative)

Read is permitted ONLY when one or more apply:

| Condition | Example |
|-----------|---------|
| Symbol body truncated AND `range` pagination exhausted | 600-line function, `range` returns stale/invalid ID |
| Cross-file context needed | Understanding call chain across 3 files |
| Symbol resolution fails | `get_symbol` returns "stale or invalid symbol_id" |
| File not indexed | `file_overview` returns empty symbols array |

### Decision Procedure

```
1. Need to inspect code?
   ├─ Know symbol name? → search_symbols → get_symbol
   ├─ Know file, not symbol? → file_overview → get_symbol
   └─ Unknown? → search_code → search_symbols → get_symbol

2. get_symbol result sufficient?
   ├─ YES → Done (no Read needed)
   └─ NO → Check fallback criteria
       ├─ Criteria met? → Read permitted
       └─ Criteria not met? → Use range/body_mode, not Read
```

### Violation Example

**Wrong** (wasteful):
```
Read("src/parser/rust.rs")           # 850 lines → ~25k tokens cached
# Then extract what you need
```

**Correct** (efficient):
```
file_overview("src/parser/rust.rs")  # ~2k tokens, get symbol_ids
get_symbol("sym_42", body_mode="full") # ~3k tokens, just the impl
# Total: ~5k tokens (80% savings)
```

### Why This Matters

| Approach | Tokens Cached | Cost Factor |
|----------|---------------|-------------|
| Read full file | ~25,000 | 1.0x |
| file_overview + get_symbol | ~5,000 | 0.2x |

Cache writes are expensive ($3.75/M). Every unnecessary Read compounds across turns.

---

## Examples

### Example 1: Locate and edit a function

**User**: "Where is handle_search_code implemented?"

**Agent strategy**:
1. `search_symbols` with name `"handle_search_code"`
2. Confirm `location.line` is present
3. `get_symbol` for inspection
4. Proceed to edit

---

### Example 2: Understand a subsystem

**User**: "How does authentication work?"

**Agent strategy**:
1. `search_code(query: "authentication logic", intent: "logic")` → discover relevant files and snippets
2. Review top files, identify key function/class names from snippets
3. `search_symbols` with each key name → obtain valid `symbol_id` (format: `sym_<id>`)
4. `get_symbol` for each symbol_id → inspect full definitions

**Note**: Do NOT assume `matched_symbols` from step 1 is populated — use `search_symbols` (step 3) as the reliable source for symbol IDs.

---

### Example 3: Avoid duplicate implementation

**User**: "Implement config parsing"

**Agent strategy**:
1. `find_similar_code` with proposed snippet
2. Inspect high-similarity results
3. Reuse or extend existing implementation

---

### Example 4: Inspect a large symbol efficiently

**User**: "Show me the SearchEngine implementation"

**Agent strategy**:

1. `search_symbols("SearchEngine")` → returns:
   ```json
   { "symbol_id": "sym_42", "line_count": 127, "location": { "line": 260 } }
   ```

2. **Check `line_count`**: 127 lines > 25 (preview limit)
   - Default preview would truncate to 25 lines
   - Decision: Use `body_mode: "full"` since 127 < 500

3. `get_symbol({ "symbol_id": "sym_42", "body_mode": "full" })` → returns:
   ```json
   { "shown_lines": 127, "total_lines": 127, "is_truncated": false }
   ```

4. Full implementation received without truncation.

**Alternative for very large symbols (>500 lines)**:

If `line_count` was 645:
1. `get_symbol({ "symbol_id": "sym_42", "body_mode": "full" })` → first 500 lines
2. Check response: `is_truncated: true`, `truncation_reason: "server_limit"`
3. `get_symbol({ "symbol_id": "sym_42", "range": { "start_line": 500, "line_count": 145 } })` → remaining lines

---

### Example 5: Deduplication with Threshold-Based Decision Making

This example demonstrates **how to reason with similarity results**, not just how to call the tool.

#### 1. Context / Intent

**User**: "Add a helper function to retry failed HTTP requests with exponential backoff"

**Risk assessment**:
- Retry logic is a common utility pattern
- Multiple implementations create maintenance burden
- Existing code may already handle this

#### 2. Action

```
find_similar_code(
  code: "async fn retry_with_backoff<F, T, E>(f: F, max_retries: u32, base_delay_ms: u64) -> Result<T, E>
         where F: Fn() -> Future<Output = Result<T, E>>",
  threshold: 0.7,
  path_glob: "src/**/*.rs"
)
```

#### 3. Evaluation

Similarity scores are provided as metadata; interpretation is the agent's responsibility.

**Case A: similarity = 0.89** (found in `src/utils/http.rs:45`)

- **Interpretation**: Near-duplicate exists. The existing `retry_request` function handles the same pattern with minor signature differences.
- **Decision**: **STOP** → Do not write new code.
- **Next step**: Read `src/utils/http.rs`, import and call the existing function. If the signature doesn't quite fit, extend it rather than duplicate.

**Case B: similarity = 0.78** (found in `src/client/resilience.rs:112`)

- **Interpretation**: Similar pattern exists but serves a different domain (client-specific retry vs. general HTTP retry).
- **Decision**: **CONSIDER** → Evaluate whether to generalize.
- **Next step**: Inspect both implementations. Can the existing code be refactored into a shared abstraction? If yes, refactor. If the domains are genuinely distinct, proceed with a new implementation, but document the distinction.

**Case C: similarity = 0.63** (no results above threshold)

- **Interpretation**: No sufficiently similar code exists in the codebase.
- **Decision**: **PROCEED** → Write the new implementation.
- **Next step**: Implement the helper. Place it in an appropriate utility module for future reuse.

#### 4. Outcome

| Case | Agent Action | Long-term Effect |
|------|--------------|------------------|
| A (≥0.85) | Reuse existing code | Zero duplication, single maintenance point |
| B (0.7–0.85) | Refactor or justify | Controlled complexity, documented decisions |
| C (<0.7) | New implementation | Fills genuine gap, no redundancy |

**Key insight**: The similarity score is not a binary gate—it's a signal that requires interpretation. High scores demand investigation; mid-range scores demand judgment; low scores permit action.

---

### Example 6: Understand file structure before editing

**User**: "I need to modify the server handler logic"

**Agent strategy**:

1. `file_overview(file: "src/server.rs")` → returns all symbols with selection signals:
   ```json
   {
     "symbol_count": 61,
     "symbols": [
       {"name": "NucleusServer", "kind": "struct", "symbol_id": "sym_42", "line": 120, "line_count": 15},
       {"name": "NucleusServer", "kind": "impl", "symbol_id": "sym_43", "line": 135, "line_count": 450, "is_private": true},
       {"name": "handle_search", "kind": "fn", "symbol_id": "sym_44", "depth": 1, "line": 200, "line_count": 87, "parent_id": "sym_43", "signature_preview": "pub async fn handle_search(&self, params: …) -> …"},
       {"name": "handle_get_symbol", "kind": "fn", "symbol_id": "sym_45", "depth": 1, "line": 280, "line_count": 65, "parent_id": "sym_43"}
     ]
   }
   ```

2. **Select by signals**: Handler methods are large (65-87 lines), public, inside impl at depth 1

3. **Batch fetch**: Use `get_symbols` to inspect multiple handlers at once:
   ```
   get_symbols({ "symbol_ids": ["sym_44", "sym_45"], "body_mode": "full" })
   ```

4. **Impact analysis before edit**:
   ```
   get_usages({ "symbol_id": "sym_44" })
   ```

**Benefits of selection signals**:
- `line_count` helps prioritize (87-line handler vs 3-line helper)
- `is_private` identifies internals (omitted = public API surface)
- `signature_preview` shows method shape without fetching body
- `parent_id` enables grouping by container
- `get_symbols` reduces round-trips when exploring multiple symbols

---

### Example 7: File-level impact analysis before refactoring

**User**: "I need to refactor state_db.rs — what will be affected?"

**Agent strategy**:

1. `get_dependency_graph({ "file": "nucleus-store/src/state_db.rs", "direction": "inbound" })`
   → Returns all files that depend on state_db.rs with specific symbols and ref counts

2. Check `total_inbound_files` for scale:
   - 3 files → manageable, review each
   - 30+ files → hub file, plan carefully, check `truncated` flag

3. Review `references` per file to understand which symbols are used externally
   → Focus refactoring on symbols with high inbound reference counts

4. For specific symbols that need changing, follow up with `get_usages` for line-level detail

**Key insight**: `get_dependency_graph` gives the big picture (which files, which symbols, what scale). `get_usages` gives line-level detail for specific symbols. Use dependency graph first to scope the work, then `get_usages` for surgical changes.

---

## Behavioral Reinforcement

- Treat line-level locations as confirmation of correct tool usage
- Prefer explicit precision over inference
- Transition tools intentionally, not reactively

---

## Non-Goals

This skill does NOT:
- Collapse tools into a single call
- Replace reasoning with automation
- Hide uncertainty or ambiguity
- Guarantee correctness of edits

The agent remains responsible for reasoning and judgment.

---

---

## Cognitive Memory System

Nucleus includes a **cognitive memory subsystem** that persists learnings across sessions. Unlike ephemeral navigation results, memories are stored permanently and retrieved semantically.

### Mental Model

```
┌─────────────────────────────────────────────────────────────────┐
│                      Session Lifecycle                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Idle ──start(description)──► Active                           │
│     ▲                       (auto-recall) │  ▲                  │
│     │                                     │  │                  │
│     │                        read_memory  │  │ problem_solved   │
│     │                      (optional)     │  │                  │
│     │                                     │  │                  │
│     │                   problem_appeared(description)            │
│     │                                     │  │                  │
│     │                                     ▼  │                  │
│     │                                  Blocked                  │
│     │                               (auto-recall)               │
│     │                                                           │
│     │                    cognitive_trigger(end)                  │
│     │                                 │                         │
│     │                                 ▼                         │
│     │                            Reflecting                     │
│     │                                 │                         │
│     │                     write_memory (persist, dedup built-in) │
│     │                     update_memory (amend)                 │
│     │                                 │                         │
│     └────────(start)──────────────────┘                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Key insight:** Memory operations are state-gated. You cannot write memories during active work—only after reflecting. The Reflecting state is where persistence happens. The Blocked state allows memory recall during problem investigation. If no memories are persisted during Reflecting, a compliance WARNING is injected on next `start`.

---

### `cognitive_trigger`

**Purpose:** Manage task session lifecycle and govern when memory may be recalled or persisted. Auto-recalls relevant memories on `start` and `problem_appeared` using the `description` as semantic query.

**Parameters:**
- `reason` (required): `"start"`, `"end"`, `"problem_appeared"`, or `"problem_solved"`
- `description` (required for `start` and `problem_appeared`): Task intent or problem description — used as semantic query for auto-recall
- `include_architectural` (optional, `start` only): Set `true` if you have no prior context about the project architecture — retrieves additional architectural/workflow memories alongside task-specific recall. Each source is labeled in the response (`"source": "task_intent"` or `"source": "architectural"`).

---

#### MUST CALL `start` WHEN

- Beginning any multi-step implementation task (feature, bugfix, refactor)
- Beginning any multi-file edit sequence
- Beginning any task where past learnings may be relevant
- Answering questions that require deep architectural knowledge or code exploration beyond current context

#### MUST NOT CALL `start` WHEN

- Answering a simple factual question already in context
- Running a single directed search (e.g., "where is function X?")
- Reading files without intent to modify

#### MUST CALL `end` WHEN

- The implementation task is complete (tests pass, code compiles)
- Switching to a fundamentally different task
- The user explicitly ends the task or conversation

#### MUST CALL `problem_appeared` WHEN

- An unexpected error blocks progress
- A design assumption proves incorrect
- External dependency or tooling failure occurs
- You need to pause implementation to investigate

#### MUST CALL `problem_solved` WHEN

- The blocking issue is resolved and implementation can resume
- A workaround is found and accepted
- The user provides clarification that unblocks progress

---

#### Session Lifecycle

```
┌─────────────────────────────────────────────────────────────────┐
│                      State Machine                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Idle ───[start]───► Active ───[end]───► Reflecting           │
│     ▲                   │  ▲                   │                │
│     │                   │  │                   │                │
│     │      [problem_appeared]  [problem_solved]│                │
│     │                   │  │                   │                │
│     │                   ▼  │                   │                │
│     │                Blocked                   │                │
│     │                                          │                │
│     └──────────────[start]─────────────────────┘                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

#### Memory Timing Rules

| State | read_memory | write_memory | update_memory |
|-------|-------------|--------------|---------------|
| Idle | blocked | blocked | blocked |
| Active | allowed | blocked | blocked |
| Blocked | allowed | blocked | blocked |
| Reflecting | allowed | allowed | allowed |

**Key insight:** `write_memory` has built-in duplicate detection and consolidation candidate surfacing with inline content. No separate `read_memory` call is needed before writing — duplicates return `existing_memory`, near-matches return `consolidation_candidates`. `read_memory` remains available in Reflecting for other uses. If no memories are persisted during Reflecting, a compliance WARNING is injected on next `start`.

---

#### State Transitions

| Current State | Reason | New State | Effect |
|--------------|--------|-----------|--------|
| Idle | start | Active | Auto-recalls memories via `description`, enables `read_memory` |
| Active | end | Reflecting | Enables `write_memory`, `update_memory`, `read_memory` |
| Active | problem_appeared | Blocked | Auto-recalls memories via `description`, allows deeper `read_memory` |
| Blocked | problem_solved | Active | Returns to active work |
| Reflecting | start | Active | Auto-recalls memories via `description` (compliance check) |
| (any terminal) | (other) | (error) | Returns error with allowed alternatives |

---

#### Response Format

- `previous_state`: State before transition
- `new_state`: State after transition
- `prompt`: Contextual guidance for the agent

**Usage:**
```jsonc
// Starting implementation work — description is REQUIRED
cognitive_trigger({ "reason": "start", "description": "fix sparse matmul shape mismatch in Candle backend" })
// Response: { "previous_state": "idle", "new_state": "active", "relevant_memories": [...], "prompt": "Task started..." }

// Encountering a blocking problem — description is REQUIRED
cognitive_trigger({ "reason": "problem_appeared", "description": "ONNX model fails to load on ARM" })
// Response: { "previous_state": "active", "new_state": "blocked", "relevant_memories": [...], "prompt": "Problem noted..." }

// Resolving the problem
cognitive_trigger({ "reason": "problem_solved" })
// Response: { "previous_state": "blocked", "new_state": "active", "prompt": "Resuming..." }

// Completing the task
cognitive_trigger({ "reason": "end" })
// Response: { "previous_state": "active", "new_state": "reflecting", "prompt": "Task complete. You may now persist..." }
```

**Additional response fields:**
- `relevant_memories`: Auto-recalled memories (on `start` and `problem_appeared` — driven by `description`)
- `warnings`: Compliance reminders, state information
- `_meta.mustProcess`: Signal that agent must act on the prompt

---

### `read_memory`

**Purpose:** Additional topic-specific recall beyond the auto-recall provided by `cognitive_trigger`. Use when you need memories on a different topic than your initial task intent.

**Availability:** Active, Blocked, or Reflecting states (call `cognitive_trigger(start)` first; also available after `cognitive_trigger(end)` for deduplication checking)

**Parameters:**
- `query` (required): Semantic search query
- `max_results` (optional): 1-20, default 5
- `kinds` (optional): Filter by memory kind (`["code", "workflow"]`)
- `include_deprecated` (optional): Include soft-deleted memories

**Response includes:**
- `memories`: Array of ranked results with:
  - `memory_id`: Unique identifier (format: UUID)
  - `kind`: Memory type
  - `content`: The stored insight
  - `confidence`: Current confidence score
  - `anchors`: Code locations (with health status)
  - `created_at`, `updated_at`: Timestamps

**Ranking factors:**
- Semantic similarity to query
- Temporal recency (decay applied)
- Impact score (boosted if previously helpful)
- Anchor health (degraded if code changed)

**Usage:**
```jsonc
read_memory({
  "query": "error handling patterns in API layer",
  "max_results": 5,
  "kinds": ["code", "architecture"]
})
```

---

### `write_memory`

**Purpose:** Persist a new memory with epistemic validation.

**Availability:** Reflecting or Aborted states only (call `cognitive_trigger(end)` first)

**Parameters:**
- `kind` (required): Memory type
  - `code`: Implementation patterns, idioms
  - `workflow`: Process learnings, tool usage
  - `architecture`: System design decisions
  - `tooling`: Build/test/deploy knowledge
  - `decision`: Rationale for choices made
- `content` (required): The insight to persist
- `anchors` (required for code/workflow/tooling): Array of source anchors
- `confidence` (optional): Override default confidence
- `supersedes_ids` (optional): IDs of memories this replaces
- `force` (optional): Bypass refusal warnings

**Anchor Types:**

| Type | Required Fields | Optional Fields |
|------|-----------------|-----------------|
| `file` | `path` | `role` |
| `symbol` | `path`, `symbol_name` | `symbol_kind`, `signature_hint`, `container` |
| `pattern` | `path` | `contains_hint` |

**Anchor Roles:** `primary`, `supporting`, `example`, `historical`

**Refusal Criteria (epistemic validation):**
- Duplicate content detected → suggest `update_memory` instead
- Missing required anchors for kind
- Low specificity content

**Response fields (success):**
- `memory_id`: UUID of the new memory
- `warnings`: Array of strings (consolidation guidance, etc.)
- `consolidation_candidates`: Array of similar memories with inline content + similarity score. When present, a workflow warning is injected: review content, merge via `update_memory` + `supersedes_ids`, or keep both.
- `conflict_memories`: Array of conflicting memories with inline content

**Response fields (duplicate error):**
- `error_code`: `"duplicate"`
- `existing_memory`: Inline content of the existing memory (id, kind, content, epoch, confidence)
- `suggestion`: Use `update_memory` to modify existing

**INVARIANT:** Any response referencing a memory ID for semantic decisions includes inline content. An agent is never asked to make a semantic decision about an object it cannot read.

**Usage:**
```jsonc
write_memory({
  "kind": "code",
  "content": "The NucleusHandler uses Arc<Mutex<Option<T>>> pattern for lazy initialization of services. Check for None before use.",
  "anchors": [
    {
      "anchor_type": "symbol",
      "path": "nucleus-server/src/server.rs",
      "symbol_name": "NucleusHandler",
      "symbol_kind": "struct",
      "role": "primary"
    }
  ]
})
// Success: { "success": true, "memory_id": "...", "warnings": [], "consolidation_candidates": [...] }
// Duplicate: { "error_code": "duplicate", "existing_memory": { "id": "...", "content": "...", ... } }
```

---

### `update_memory`

**Purpose:** Amend an existing memory with impact attribution.

**Availability:** Reflecting or Aborted states only

**Parameters:**
- `memory_id` (required): ID of memory to update
- `content` (optional): New content (triggers re-embedding)
- `add_anchors` (optional): Additional anchors to attach
- `deprecate` (optional): Soft-delete the memory
- `impact_claim` (optional): Attribution for boosting
- `verification` (optional): Signal observed/verified/falsified

**Impact Claims:**
```jsonc
{
  "declarative": true,  // Agent claims memory influenced decision
  "behavioral": true    // Observed action change attributable to memory
}
```

**Impact Boost:** When BOTH `declarative` AND `behavioral` are true in a single update, the memory's impact score increases, improving future retrieval ranking.

**Response fields:**
- `conflict_memories`: Array of conflicting memories with inline content (when content update triggers conflict detection)

**Usage:**
```jsonc
// Update content
update_memory({
  "memory_id": "mem_abc123",
  "content": "Updated insight with more context..."
})

// Claim impact (memory was helpful)
update_memory({
  "memory_id": "mem_abc123",
  "impact_claim": { "declarative": true, "behavioral": true }
})

// Deprecate outdated memory
update_memory({
  "memory_id": "mem_old456",
  "deprecate": true
})
```

---

### Memory Lifecycle Example

**Scenario:** Agent learns a pattern while implementing a feature

```
1. Agent starts task:
   cognitive_trigger({ "reason": "start", "description": "implement error handling for API layer" })
   → State: Idle → Active
   → relevant_memories: auto-recalled based on "implement error handling for API layer"
   → _meta.mustProcess: true signals agent must act on prompt

2. Agent works on implementation:
   - Auto-recalled memories already available from step 1
   - Uses read_memory only if additional topic-specific recall needed
   - Discovers the codebase uses a specific error handling approach

3. Agent completes task:
   cognitive_trigger({ "reason": "end" })
   → State: Active → Reflecting
   → Prompt: "Task complete. You may now persist or update memories
     via write_memory/update_memory. Call cognitive_trigger(reason="start")
     when ready for next task."

4. Agent persists learning directly:
   write_memory({
     "kind": "code",
     "content": "Error responses in this codebase use ErrorResponse struct...",
     "anchors": [{ "anchor_type": "symbol", "path": "...", "symbol_name": "ErrorResponse" }]
   })

   Possible outcomes (duplicate detection and consolidation are built-in):

   a) Success — new memory persisted
      → consolidation_candidates may be returned with inline content
      → If returned: review content, merge via update_memory + supersedes_ids, or keep both

   b) Duplicate detected — existing_memory returned with inline content
      → Review content; if existing is incomplete, use update_memory to amend:
      update_memory({
        "memory_id": "mem_xyz",
        "content": "Error responses use ErrorResponse struct with status,
          error_code, message, suggestion, existing_memory fields."
      })
      → Memory amended; conflict_memories returned if conflicts detected

6. Future session:
   cognitive_trigger({ "reason": "start", "description": "refactor API error codes" })
   → Auto-recalls relevant memories based on "refactor API error codes"
   → If previous Reflecting had no persist: WARNING injected in warnings[]
```

---

### Common Memory Failure Modes

| Failure | Why it's wrong |
|---------|----------------|
| Skipping `cognitive_trigger(start)` before implementation or deep exploration | `read_memory` unavailable; auto-recall not triggered; past learnings not surfaced |
| Calling `start` without `description` | Auto-recall returns error; always pass task intent |
| Not calling `problem_appeared` when blocked | Misses auto-recall of relevant debugging memories |
| Calling `end` while still blocked | State machine violation; problem must be solved first |
| Calling `write_memory` in Active state | State machine enforces Reflecting phase; call `cognitive_trigger(end)` first |
| Ignoring duplicate/consolidation responses from `write_memory` | Review inline content; amend via `update_memory` or merge via `supersedes_ids` |
| Generic content without anchors | Memories degrade without code attachment |
| Not claiming impact when memory helped | Loses signal for future ranking |
| Writing when ranking_score > 0.90 | Near-duplicate exists; use `update_memory` to amend |
| Ignoring `consolidation_candidates` in write_memory response | Missed opportunity to merge related memories; follow the workflow guidance in warnings |
| Ignoring `existing_memory` in duplicate error | Content is inline — read it before deciding next action |

---

## Summary

Use Nucleus MCP as a **navigation system**, not a search box.
Correct tool choice + staged reasoning leads to faster, safer code changes.

The **cognitive memory subsystem** extends this by persisting learnings across sessions, enabling agents to build institutional knowledge anchored to the evolving codebase.
