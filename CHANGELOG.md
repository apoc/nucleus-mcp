# Changelog

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
