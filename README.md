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
make xcode              # or: generate the project and open it in Xcode
```

> **Building in Xcode?** The `.xcodeproj` is generated, not checked in — run `make xcode` (or `make generate`) first, then build the **DiskSleuth** scheme in `App/DiskSleuth.xcodeproj`. Opening `Package.swift` at the repo root only gives you the CLI and library targets; the app won't appear there. If command-line builds complain that `xcodebuild` requires Xcode, point developer tools at the full Xcode once: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

Homebrew formula/cask: coming soon.

## Quick tour

```sh
disksleuth info ~/Movies/render.mov   # truth card: 3 sizes, clone family, "deleting frees X"
disksleuth scan ~ --top 15            # biggest items, honest sizes
disksleuth overview                   # capacity, purgeable space, local snapshots
disksleuth snapshots                  # what Time Machine is still holding
```

Filter and sort the rankings:

```sh
disksleuth top ~ --ext mov,mp4 --min-size 500MB              # big videos only
disksleuth top ~ --only clone --sort freeable,logical         # clones: what deleting really frees
disksleuth top ~/Library --include '*cache*' --exclude '.DS_Store'
disksleuth top ~ --dirs --min-percent 2 --reverse             # folders ≥ 2% of the total, smallest first
disksleuth scan ~ --min-size 1GB                              # fold small items; totals stay true
```

`top` filters: `--min-size`/`--max-size` (e.g. `100MB`, `1.5GiB`), `--min-percent`, `--ext`/`--exclude-ext`, `--include`/`--exclude` (globs; a pattern with `/` matches the full path), and `--only clone,hardlink,sparse,dataless,compressed,shared-outside`. Sort with `--sort` (`logical`, `physical`, `freeable`, `name`, `path` — comma-separated for tiebreaks) and `--reverse`. See `disksleuth top --help`.

> **Tip:** grant your terminal Full Disk Access (System Settings → Privacy & Security) for complete results. DiskSleuth records every folder it couldn't read and says so, rather than silently under-counting.

## How the accounting works

Shared bytes (clones, hard links) are counted **once, in the deepest folder that contains all files sharing them** — so per-folder numbers are deterministic, nothing is double-counted, and totals match the volume. Full semantics: [docs/truth-engine.md](docs/truth-engine.md).

## License

MIT — see [LICENSE](LICENSE).
