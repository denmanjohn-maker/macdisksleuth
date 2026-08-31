# DiskSleuth

**The disk analyzer that tells you the truth on APFS.**

Every popular disk-usage tool was designed for a filesystem Apple stopped shipping years ago. On modern macOS, copy-on-write clones get double-counted, hard links inflate totals, sparse and compressed files report sizes they don't occupy, and Time Machine local snapshots quietly hold on to space you thought you freed. The result: numbers that don't match Finder, and deletions that don't give you your disk back.

DiskSleuth reports what is *really* on disk — and what deleting something will *really* free.

## Three honest size lenses

| Lens | Meaning |
|---|---|
| **Logical** | What the files claim to be (what most tools show) |
| **Physical** | What the disk actually holds — clones, hard links, sparse ranges, and compression counted once |
| **Freeable** | What deleting this would give back *right now* |

An 8 GB video that's a clone of another file shows **8 GB logical, ~0 freeable** — because deleting it frees almost nothing. DiskSleuth is the tool that tells you that *before* you empty the Trash and wonder where your space went.

## What's in the box

- `disksleuth` — a fast CLI: `scan`, `top`, `info`, `overview`, `snapshots`
- **DiskSleuth.app** — a native SwiftUI app with an interactive sunburst, size-lens toggle, and delete-to-Trash that shows true freeable bytes
- `DiskSleuthKit` — the shared engine, usable as a Swift package

Built on `getattrlistbulk` with APFS extended attributes (`PRIVATESIZE`, `CLONEID`, extent flags) — the fast path, with per-file clone/sparse/dataless awareness and zero file opens (iCloud placeholders are never downloaded).

## Install

Requires macOS 14+.

```sh
git clone https://github.com/denmanjohn-maker/macdisksleuth.git
cd macdisksleuth
swift build -c release
.build/release/disksleuth --help
```

GUI app:

```sh
brew install xcodegen   # once
make app                # builds App/DiskSleuth.xcodeproj → DiskSleuth.app
```

Homebrew formula/cask: coming soon.

## Quick tour

```sh
disksleuth info ~/Movies/render.mov   # truth card: 3 sizes, clone family, "deleting frees X"
disksleuth scan ~ --top 15            # biggest items, honest sizes
disksleuth overview                   # capacity, purgeable space, local snapshots
disksleuth snapshots                  # what Time Machine is still holding
```

> **Tip:** grant your terminal Full Disk Access (System Settings → Privacy & Security) for complete results. DiskSleuth records every folder it couldn't read and says so, rather than silently under-counting.

## How the accounting works

Shared bytes (clones, hard links) are counted **once, in the deepest folder that contains all files sharing them** — so per-folder numbers are deterministic, nothing is double-counted, and totals match the volume. Full semantics: [docs/truth-engine.md](docs/truth-engine.md).

## License

MIT — see [LICENSE](LICENSE).
