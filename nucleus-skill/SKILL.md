---
name: nucleus-skill
description: >
  Use for ANY codebase navigation when mcp__nucleus__* tools are available.
  Encodes tool selection and multi-stage workflows. Includes cognitive memory for persistent learnings.
version: 3.3
---

# Nucleus MCP Navigation

**Prerequisite:** `mcp__nucleus__*` tools available? Use directly. Otherwise fallback to `Task(subagent_type=Explore)`.

**Stability:** All results are static analysis only. No runtime/control-flow resolution. Session-scoped (not persisted). Responses include `stability: "ephemeral_session"` as machine-readable signal.

## Session Lifecycle (NON-NEGOTIABLE)

**CRITICAL: BEFORE ANY IMPLEMENTATION, LARGE EXPLORATORY WORK OR ISSUE ANALYSIS:**
```
cognitive_trigger(reason="start", description="<task intent>")
```

The `description` is **required** — it drives semantic auto-recall of relevant memories in the response. This is NOT optional. This is NOT "when convenient". This is FIRST.

| Task Type                             | Requires `start`? |
|---------------------------------------|-------------------|
| Multi-step implementation             | **YES - ALWAYS**  |
| Multi-file edit sequence              | **YES - ALWAYS**  |
| Feature, bugfix, refactor             | **YES - ALWAYS**  |
| Large exploratory search              | **YES - ALWAYS**  |
| Deep architectural / design question  | **YES - ALWAYS**  |
| Simple factual question (in context)  | No                |

**ALL FOUR REASONS:**

| Reason | When to Call | `description` | Effect |
|--------|--------------|---------------|--------|
| `start` | Beginning implementation work | **Required** — task intent | Idle → Active, auto-recalls relevant memories |
| `end` | Task complete (tests pass, code compiles) | Not used | Active → Reflecting, enables write_memory/update_memory |
| `problem_appeared` | Unexpected error blocks progress | **Required** — problem description | Active → Blocked, auto-recalls relevant memories |
| `problem_solved` | Blocking issue resolved | Not used | Blocked → Active, resumes work |

**`include_architectural`** (optional, for `start` only): Set `true` on first interaction with an unfamiliar project to also retrieve architectural/workflow memories alongside task-specific recall.

**MUST CALL `problem_appeared` WHEN:**
- Unexpected error blocks progress
- Design assumption proves incorrect
- External dependency or tooling failure
- Need to pause implementation to investigate

**MUST CALL `problem_solved` WHEN:**
- Blocking issue resolved
- Workaround found and accepted
- User clarification unblocks progress

**WHEN TASK COMPLETES:**
```
cognitive_trigger(reason="end")
```

Then call `write_memory` directly — it handles duplicate detection and consolidation internally.

**Failure to call `cognitive_trigger(start)` means:**
- Past learnings are NOT surfaced
- You work blind to institutional knowledge
- The entire memory system is bypassed

## Activation Triggers

| Query Pattern | Tool Chain |
|---------------|------------|
| "where is X" / "find X" | `search_code(intent="exploration")` → `search_symbols(intent="exploration")` |
| "implementation of X" | `search_symbols` → `get_symbol` |
| "how does X work" | `search_code(intent="logic")` → `get_symbol` |
| "who calls X" | `search_symbols` → `get_usages` |
| "change signature of X" / refactor | `search_symbols` → `get_symbol` → `get_usages` → `get_symbol` per caller |
| "what is this reference" / "go to definition" | `resolve_symbol_at` |
| "what depends on this file" / impact | `get_dependency_graph(direction="inbound")` |
| "what does this file use" / context | `get_dependency_graph(direction="outbound")` |
| "who implements X" / "implementors" | `search_symbols` → `get_implementors` |
| "what's in file" | `file_overview` → `get_symbols` |
| "class API" / "struct methods" | `search_symbols` → `class_overview` |
| "compare implementations" / "parallel impls" | `class_overview` on each |
| "what's in directory" | `list_dir` |
| "project overview" / "what's indexed" | `project_info` |
| "before writing code" | `find_similar_code` |
| "structural exploration"| `search_code(intent="debug")` |
| starting implementation | `cognitive_trigger(reason="start", description="...")` |
| finishing implementation | `cognitive_trigger(reason="end")` → `write_memory` |
| additional recall | `read_memory(query="...")` (beyond auto-recall) |

## Tool Selection (prefer rightmost)

```
search_code → search_symbols → get_symbol → get_usages
(discovery)   (get symbol_id)   (inspect)    (impact)
     ↑              ↑               ↑            ↑
 unknown       know name       have ID      refactoring
                                   ↓
                            get_implementors
                            (trait/interface)

get_dependency_graph
(file-level impact — replaces 5-15 get_usages calls)

resolve_symbol_at
(position-based — "what does this reference point to?")
```

**Start from what you know:**
- Know symbol name? → `search_symbols` directly
- Have `symbol_id`? → `get_symbol` directly
- Know file + line? → `resolve_symbol_at` directly
- Refactoring? → `get_usages` directly
- File-level impact? → `get_dependency_graph` directly
- Modifying trait/interface? → `get_implementors` directly
- Unknown territory? → `search_code` (only then)

## Tool Reference

| Tool | Precision | Output |
|------|-----------|--------|
| `search_code` | File | Ranked files (supports `intent`, `directories`) |
| `search_symbols` | Line | `symbols` (exact) or `exploratory` (fallback). Prefer `symbols`. **Accepts arrays** — batch multiple names in one call. Supports `directories` scoping. |
| `get_symbol` | Line | Definition, signature, relations |
| `get_symbols` | Line | Batch fetch (1-20 IDs) |
| `get_usages` | Line | All references + snippets. **Intent labels** (`invocation`, `import`, `type_reference`, `implementation`, `inheritance`) — use to separate test vs production callers. |
| `get_implementors` | Line | Types implementing trait/interface + relation |
| `class_overview` | Line | API surface: methods, bases, traits (no bodies). Replaces file_overview + N×get_symbol. Valid kinds: `struct`, `trait`, `impl` only (NOT `class`, NOT `enum`). |
| `file_overview` | Line | Symbol index + selection signals |
| `list_dir` | Directory | Files + subdirs with pagination |
| `project_info` | Project | Index stats, languages, directories |
| `get_dependency_graph` | File | Inbound/outbound file deps with symbols, total counts |
| `resolve_symbol_at` | Line | Definition from file position (4-tier: ref, definition, import, nearby) |
| `find_similar_code` | Chunk | Similarity scores. Also: cross-module pattern discovery. |
| `cognitive_trigger` | Session | State transitions, auto-recalls memories via `description` |
| `read_memory` | Semantic | Additional topic-specific recall (beyond auto-recall) |
| `write_memory` | Persistent | Memory ID, inline consolidation candidates, conflict memories |
| `update_memory` | Persistent | Amended content, impact, inline conflict memories |

## Symbol IDs

Format: `sym_<id>` (opaque, content-addressable). Source: `search_symbols` or `file_overview`. Never fabricate.

## Body Modes (get_symbol)

| Mode | Parameter | Lines |
|------|-----------|-------|
| Preview | default | ≤25 |
| Full | `body_mode: "full"` | ≤500 |
| Windowed | `range: {start_line, line_count}` | Custom |

**Strategy:** Check `line_count` from search first. Use `full` for >25 lines.

## file_overview

**Params:** `file` (required), `depth` (0=top-level, 1=+methods, 99=all)

**Selection signals:** `line_count`, `is_private` (omitted=public or unknown), `signature_preview`, `doc_summary`

## list_dir

**Params:** `path` (required), `limit` (default 100), `offset` (default 0)

**Pagination:** Returns `pagination: { total_count, has_more }`. Use `offset` to fetch additional pages.

## project_info

**Purpose:** Epistemic scaffolding — "what assumptions can I make before reasoning?"

**Params:** None (v1)

**Returns:** `files` (total, by_language), `symbols` (total, by_kind), `directories` (top-level, ≥10 files), `languages` (indexed only), `index` (status, last_indexed_at)

**INVARIANT:** Reports index state, not repository truth. Languages not listed may exist but are not indexed.

## Cognitive Memory

**Purpose:** Persist learnings across sessions. Memories are anchored to code locations and retrieved semantically.

**State Machine:**
```
Idle →[start]→ Active →[end]→ Reflecting →[start]→ Active (new task)
                 │  ▲
      [problem_appeared]  [problem_solved]
                 │  │
                 ▼  │
               Blocked
```

**Nesting:** Multiple agents can call `start`/`end` concurrently. The server uses depth counting — nested `start` increments depth, nested `end` decrements it. Only the outermost transitions change state. Subagent `end` will NOT kill the parent's session.

**Lifecycle:**
1. `cognitive_trigger(reason="start", description="<task intent>")` — Begin task, auto-recalls relevant memories in response
2. Work on implementation (use `read_memory` for additional topic-specific recall if needed)
3. `cognitive_trigger(reason="end")` — End task, enter Reflecting
4. Persist phase (Reflecting state):
   - Call `write_memory` directly — duplicate detection and consolidation are built-in
   - If duplicate returned: review `existing_memory` inline content, use `update_memory` to amend
   - If `consolidation_candidates` returned: merge via `update_memory` + `supersedes_ids`, or keep both
5. `cognitive_trigger(reason="start", description="<next task intent>")` — Begin next task

**Compliance:** If no memories are persisted during Reflecting, a WARNING is injected on next `start`.

**Consolidation:** When `write_memory` returns `consolidation_candidates`, review the inline content:
- To merge: `update_memory` on the existing memory with combined content, then `write_memory` with `supersedes_ids`
- To keep both: no action needed

**Memory Kinds:** `code`, `workflow`, `architecture`, `tooling`, `decision`

**Anchors:** Required for `code`/`workflow`/`tooling`. Types: `file`, `symbol`, `pattern`

## Deduplication

```
find_similar_code(code: "<draft>", threshold: 0.7)
```

| Score | Action |
|-------|--------|
| ≥0.85 | STOP — reuse |
| 0.7–0.85 | CONSIDER — generalize |
| <0.7 | PROCEED |

## Anti-Patterns

| Wrong | Right |
|-------|-------|
| Explore/Grep for navigation | `search_code` |
| Edit from `search_code` alone | → `search_symbols` first |
| Skip impact check | `get_usages` before refactor |
| Modify trait without checking implementors | `get_implementors` before trait changes |
| Multiple `get_usages` for file-level impact | `get_dependency_graph` (single call) |
| Fabricate `symbol_id` | Obtain via tools |
| `Read(file)` for code inspection | `file_overview` → `get_symbol` |
| `write_memory` in Active state | Call `cognitive_trigger(reason="end")` first to enter Reflecting |
| Skipping `cognitive_trigger(start)` | Always start sessions for implementation AND deep exploration |
| Generic memory content | Anchor to specific code locations |
| Ignoring `consolidation_candidates` from `write_memory` | Review inline content, merge or keep both |

## Cost Policy

**Rule**: `get_symbol` BEFORE `Read` for code inspection. Read is last-resort.

**Workflow**:
```
search_symbols/file_overview → get_symbol → [Read only if fallback triggered]
```

**Fallback to Read permitted ONLY when**:
1. Symbol body truncated AND cross-file context required
2. Symbol resolution fails (stale/invalid ID)
3. File not indexed (file_overview returns empty)

## Details

Full examples, failure modes, schemas: `DETAILS.md`
