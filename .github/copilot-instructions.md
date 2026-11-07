# Copilot instructions — macdisksleuth

## Build / test / lint

- Swift 6 package (`swift-tools-version: 6.0`), two products: `MacDiskSleuthKit` (library) and `macdisksleuth` (executable).
- Build: `swift build` (debug), `swift build -c release`.
- Test: `swift test`.
- App (macOS only): `make app` (xcodegen generate + xcodebuild), `make xcode`, `make generate`, `make clean`.
- No linter configured; the package is the linter. Keep code Swift 6-clean (no `#if compiler(...)` fallbacks, no `@available` shims).
- CI (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on `macos-15` and `macos-latest`.

## What this repo is

macdisksleuth is a read-only disk forensics tool that answers "where did my disk's space really go?" by scanning APFS volumes with `getattrlistbulk(2)` and reconstructing a file graph from extended attributes. It ships two surfaces: a `macdisksleuth` CLI (`scan`, `top`, `recommend`, `info`, `overview`, `snapshots`, `cleanup`) and a SwiftUI app (`App/MacDiskSleuth.app`).

## Architecture

- `ScanEngine.scan()` — entry point. Canonicalizes the path with `realpath`, opens the root with `O_RDONLY | O_DIRECTORY | O_CLOEXEC`, probes volume identity, then hands a `ScanContext` (immutable, shared) to worker threads.
- `GraphBuilder` (actor) — the accounting model. Struct-of-arrays storage (name arena, offsets, lengths, parents, depths, logicalArr, physicalArr, uniqueArr, flagsArr), hardlink/clone registries, `PermissionLedger`, and a `ScanSummary`.
- `FileGraph` — immutable result with CSR child indexing (`childStart`/`childItems`). `FileGraphEditing` mutates it.
- `NodeFlags` — node classification flags.
- `Query` (`NodeFilter`, `NodeSort`, `SizeParser`) — query layer.
- `Advice` (`Recommender`, `CleanupKnowledge`, `PathPatternTrie`, `Recommendation`) — "top things to delete": a rule base of disposable/protected macOS paths matched by a component-wise glob NFA during one DFS of the graph, ranked by freeable bytes × safety × per-member staleness. Generic large files are only considered outside Library folders, hidden folders, bundles and the OS; clones are skipped and reported.
- `Volume` (`VolumeService`, `VolumeSpaceUsed`, `Snapshots`, `FDAProbe`, `Subprocess`) — volume identity, capacities, snapshots, TCC probe, subprocess wrapper.
- `Attributes` (`BulkDirectoryReader`, `DirectoryLister`, `FallbackDirectoryReader`, `SingleItemReader`, `RawEntry`, `AttrEntryParser`, `AttrConstants`, `ScanError`, `DirHandle`) — directory enumeration with a bulk/fast-path fallback.
- `Output` (`Arguments`, `ScanRunner`, `Style`, `TreePrinter`, `RecommendationPrinter`) — CLI rendering.

## Key conventions

### The three size lenses

Every node reports three numbers, and they are not interchangeable:

- **physical** — allocated bytes for this path (own extents, or the shared extent for hardlinks/clones).
- **logical** — apparent size (includes holes, so sparse files report their full length).
- **unique** — what deleting *this one path* frees.

Every node also carries `modified` (its own mtime, from `ATTR_CMN_MODTIME`) and `newestModified` (the newest mtime anywhere in its subtree, rolled up in `finalize`). Staleness reasoning uses the latter.

### The LCA charging rule

Shared bytes are counted once, in the deepest folder that contains all files sharing them. Directory rollups would multi-count shared extents, so corrections are charged at the LCA of each sharing group. Hardlink bytes are subtracted from physical at the LCA; freed-if-all-deleted bytes are added to unique when the whole group is inside the tree.

### Clone families

A clone family (one cloneID) is the set of files wholly sharing extents; it is charged once physically. Writing to a clone splits the family (new cloneID, refcount drops), so per-file numbers stay exact and the orphaned sharing is flagged rather than silently over- or under-promised.

### Honesty rules

- Diverged clones are flagged `✳`; per-file numbers stay exact.
- Unreadable folders are flagged `⛔` and totaled, never silently skipped.
- Time Machine snapshot space is reported as "unknown" rather than invented.

### Scanning

- `getattrlistbulk(2)` with APFS extended attributes (`PRIVATESIZE`, `CLONEID`, `EXT_FLAGS`, `CLONE_REFCNT`); `readdir`+`fstatat` fallback.
- Zero file opens: iCloud placeholders are never downloaded.
- Symlinks are recorded, never followed. Dataless directories are never descended. Firmlinks are skipped.
- The `/System/Volumes/Data` subtree is traversed only for content no firmlink covers.
- Device/inode visited-set prevents double-counting.

### Testing

- Fixtures are built with `clonefile(2)`, `link(2)`, sparse files, backdated mtimes (`setModificationDate`), and permission-denied directories in a temp directory, so engine numbers can be asserted against ground truth the kernel itself reports (`st_blocks`).
- Recommendation tests build a miniature home folder and pass its path as `RecommendationContext.homeDirectory`, so `~`-based rules resolve inside the fixture.
- Tests use `@Suite`/`@Test` with `@Testing`, `#expect`, and a `within(_ actual, of expected, tolerance:)` helper (APFS physical sizes come in 4 KiB block granularity).
- Tests are gated on volume capability where needed (`FixtureTree.volumeSupportsCloning(at:)`).
- `TestHelpers.swift` provides `scanGraph(_ path, options:)` and `FileGraph.node(at:)`/`sizes(at:)`.

### CLI conventions

- Commands: `scan`, `top`, `recommend`, `info`, `overview`, `snapshots`, `cleanup`.
- `scan` prints the top 5 recommendations after the tree (`--recommendations N`, 0 hides); `recommend` prints only them. `--notify` posts a macOS notification via osascript. Recommendations never delete anything.
- Shared flags: `--json`, `--no-color`, `--si` (binary units).
- Output is human-readable by default, bar-charted, and machine-readable with `--json`.
- Destructive actions (`--remove-snapshots`) require `--dry-run` first and usually `sudo`.

## Repo layout

- `Sources/MacDiskSleuthKit/` — library.
- `Sources/macdisksleuth/` — CLI.
- `App/` — SwiftUI app (XcodeGen-generated `.xcodeproj` from `App/project.yml`, not checked in).
- `Tests/` — `MacDiskSleuthKitTests` + `FixtureSupport`.
- `docs/truth-engine.md` — detailed truth-engine semantics.
- `README.md` — overview, CLI usage, build instructions.