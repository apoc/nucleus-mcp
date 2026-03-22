# Changelog

## v0.3.0

### HTTP/SSE Transport

**New: `--http` mode** — `nucleus-server --http` listens on `127.0.0.1:4040/mcp` using the MCP Streamable HTTP protocol. Supports stateful sessions, SSE notifications, and concurrent multi-client access.

**New: Shared project sessions** — Multiple clients connecting to the same root share a single project session (DB, file watcher, indexer, vector store). No duplicate reindexing or write contention.

**New: Notification fan-out** — Indexing notifications delivered concurrently to all connected clients. Per-client opt-in via notify flag.

**New: Model preloading** — HTTP mode downloads all models at startup, eliminating first-connect delays.

### Dependencies

- rmcp 1.2.0, lancedb 0.27.0 stable, lance-index/lance-linalg 3.0 from crates.io

## v0.2.3

### C# Support

C# cross-file reference resolution is now fully functional. `get_usages`, `get_dependency_graph`, and `resolve_symbol_at` now correctly resolve symbols across files in C# projects, including projects that use dotted directory naming conventions (e.g. `Zentra.API/`). Fully qualified generic type arguments (e.g. `MapHub<Zentra.API.Hubs.NotificationHub>`, `AddScoped<Ns.IService, Ns.Impl>`) are now extracted and resolved as references.

### GPU Setup

**Fixed: DirectML crash when DML provider is absent** — Server no longer crashes on startup when `onnxruntime_providers_dml.dll` is not installed. Falls back to CPU automatically with a warning. `NUCLEUS_EP=directml` behaves the same way.

**Fixed: `setup-gpu.ps1` installs the correct ORT runtime** — The script now installs ORT 1.24.3, matching the bundled runtime. The previous version (1.23.0) caused a silent ABI mismatch that hung the server at session initialisation.

## v0.2.2

### MCP Schema Sanitization

Tool parameter schemas now emit clean JSON Schema 2020-12 without non-standard extensions that caused warnings and rendering issues in MCP clients.

**Fixed: Non-standard `format` values** — schemars emits `"format": "uint"`, `"uint32"`, `"float"`, `"double"` for Rust numeric types. These are not part of JSON Schema 2020-12 and caused Ajv validation warnings that corrupted TUI output in MCP clients. Added `strip_nonstandard_formats` transform applied at schema generation time via `#[schemars(transform = ...)]` on all 20 param structs. Only standard formats (date-time, email, uuid, etc.) are preserved.

**Fixed: Unresolved `$ref`/`$defs`** — Nested enum and struct types (McpSearchIntent, SymbolKindFilter, BodyMode, SymbolRange, SourceAnchorInput, ImpactClaim, VerificationSignal) were emitted behind `$ref` pointers with `$defs` blocks. MCP clients (including OMP/Anthropic provider) extract only `properties` and `required` from schemas, dropping `$defs` entirely — leaving dangling `$ref` that LLMs see as opaque pointers. Added `#[schemars(inline)]` to all 7 types so they are inlined directly.

**Improved: Tool descriptions for memory anchors** — `write_memory` and `update_memory` tool descriptions now explicitly list allowed `anchor_type` values (`file`, `symbol`, `pattern`) and `role` values (`primary`, `supporting`, `example`, `historical`) as defense-in-depth since no MCP client resolves `$ref`.

### Embedding Coverage Reporting

**Fixed: Stale `embedding_coverage` during reindex** — The `embedding_coverage` metric in the status endpoint stayed frozen at its pre-reindex value (e.g. 0.1546) throughout the entire embedding run because it was only recomputed from the database at job completion. Now `mark_file_embedded()` also refreshes the coverage estimate from in-memory counters (`(total_indexed - files_to_embed + files_embedded) / total_indexed`), so the status endpoint reflects real-time progress. The authoritative DB-backed computation still runs at job completion to reconcile.

## v0.2.1

### TypeScript/JavaScript Cross-File Reference Resolution

Major accuracy improvements for TS/JS monorepo workspaces. Verified against oh-my-pi (1,653 files, 13k+ symbols, 94k+ refs).

**Fixed: Import name filtering** — The explicit import resolver now checks that the import's `local_name` matches the reference being resolved. Previously, all imports in a file were tried for every reference, causing unrelated package imports to pull symbols from the wrong package (e.g., `import { Text } from "@oh-my-pi/pi-tui"` causing `fuzzyFilter` to misresolve to tui's version).

**Fixed: Re-export extraction** — `export * from`, `export { A, B } from`, and `export * as ns from` statements are now parsed as import records. Barrel files create proper dependency edges for star and named re-exports.

**Fixed: Package subpath resolution** — Scoped package imports with subpaths (`@scope/pkg/utils/fuzzy`) now try `src/` and `lib/` prefixed variants, matching the common convention where source files live under `pkg/src/`.

**Fixed: Multi-project workspace scoping** — TS import resolution now uses `package.json` files to build a package-name-to-directory map, correctly scoping resolution within multi-project Bun/npm workspaces.

**Fixed: Case-sensitive name disambiguation** — When multiple candidates exist in the same file (e.g., `fuzzyMatch` function and `FuzzyMatch` interface), the resolver now uses exact case match against the import's local name instead of giving up.

**Fixed: Local shadow bypass** — Imported names that are also re-declared locally (`import { fuzzyMatch } ...` followed by `const fuzzyMatch = ...`) are no longer suppressed from cross-file resolution.

### Known Limitations

Barrel files containing only re-exports (`export * from`) show 0 inbound/0 outbound in `get_dependency_graph`. The dependency graph queries only the `refs` table; pure re-export files have no symbols or identifier references. Import records are stored but not yet surfaced as dependency edges.
