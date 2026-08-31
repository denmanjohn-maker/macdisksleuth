# The truth engine

DiskSleuth's job is to answer two questions honestly on modern macOS:

1. **What is really on this disk?**
2. **What will deleting this really give back?**

APFS makes both questions harder than they look, and most tools answer them
with numbers designed for a filesystem Apple retired in 2017. This document
defines exactly what DiskSleuth's numbers mean.

## The three lenses

| Lens | Source | Meaning |
|---|---|---|
| **Logical** | `ATTR_FILE_DATALENGTH` | What files claim to be. Matches `ls -l` and most tools. |
| **Physical** | `ATTR_FILE_ALLOCSIZE`, shared bytes counted **once** | What the disk actually holds. |
| **Freeable** | `ATTR_CMNEXT_PRIVATESIZE` + group analysis | What deleting the item frees **right now**. |

Why they diverge:

- **Clones** (copy-on-write): Finder duplicates, `cp -c`, and many app "Save As"
  paths create files that share every block with their original. Logical counts
  them twice; the disk stores them once. `du` double-counts clones.
- **Hard links**: one file, many names. `du` handles these; naive scanners don't.
- **Sparse files**: `Docker.raw` may claim 60 GB and occupy 12 GB.
- **Compressed files** (decmpfs): most of `/Applications` and `/System` is
  transparently compressed; logical exceeds physical, and that saving is real.
- **Dataless files**: iCloud/File Provider placeholders occupy ~0 local bytes
  no matter what they claim. DiskSleuth **never opens files**, so scanning
  can't accidentally trigger downloads.

## Where shared bytes are counted

> Shared bytes are counted **once, in the deepest folder that contains all
> files sharing them.**

That single rule makes per-folder numbers deterministic and keeps every level
of the tree self-consistent:

- A 10 MB file hard-linked into `a/` and `b/` contributes 10 MB to their common
  parent's physical size — not 20 MB — and its "freeable" appears only at that
  parent, because deleting just `a/` or just `b/` frees nothing.
- A clone family (original + N clones) contributes its shared base once, at the
  family's lowest common ancestor. Each individual clone reports **freeable ≈ 0**,
  which is the truth Finder won't tell you before you empty the Trash.
- If some links or clones live **outside** the scanned tree, the shared bytes
  are marked *"shares bytes with content elsewhere"* (✳) and excluded from
  freeable — deleting everything you scanned still wouldn't free them.

### The diverged-clone honesty rule

Writing into a clone splits it from its APFS clone family (it gets a new clone
ID) even though unwritten extents remain physically shared. macOS exposes no
way to re-link those files. DiskSleuth handles this the only honest way:

- Per-file numbers stay **exact** (`PRIVATESIZE` is the kernel's own answer).
- The file is flagged ✳ — its residual sharing can't be attributed to a folder.
- Folder physical totals may over-count such extents (every other tool does
  too, for *all* clones; DiskSleuth's over-count is limited to diverged ones).

## Space that isn't files

`disksleuth overview` reconciles the numbers Finder, `df`, and Apple's Storage
pane each report differently:

- **Purgeable space** = "available for important usage" − "available now".
  Finder adds it to *available*; `df` doesn't. Both are telling a partial truth.
- **Local Time Machine snapshots** keep deleted blocks referenced. Deleting
  files may free nothing until snapshots thin (macOS does this under pressure,
  or `tmutil thinlocalsnapshots`). macOS does not report per-snapshot sizes —
  DiskSleuth says "unknown" rather than inventing a number. Whenever snapshots
  exist, freeable numbers carry the caveat: *freed space may appear gradually*.
- **Per-volume usage** comes from `ATTR_VOL_SPACEUSED`, because `statfs` on
  APFS reports container-wide totals for every volume in the container.
- **"System Data"**: `overview --deep` scans the major roots and names the
  remainder — the bucket Apple's Storage pane won't itemize.

## What the scanner reads (and what it never does)

- Enumeration uses `getattrlistbulk(2)` — bulk metadata, hundreds of entries
  per syscall — with APFS extended attributes (`PRIVATESIZE`, `CLONEID`,
  `EXT_FLAGS`, `CLONE_REFCNT`) riding along. A `readdir`+`fstatat` fallback
  covers filesystems that refuse bulk reads; missing attributes degrade
  the lenses gracefully (physical falls back to `st_blocks`).
- Scanning `/` follows the firmlink map the way you think about your Mac:
  `/Users`, `/Applications` etc. count at their visible locations; the literal
  `/System/Volumes/Data` subtree is traversed only for content no firmlink
  covers. A (device, inode) visited-set makes double-counting structurally
  impossible.
- Symlinks are recorded, never followed. Dataless directories are never
  descended into (that would trigger File Provider downloads).
- Every unreadable folder is **recorded, flagged (⛔), and totaled** — never
  silently skipped. If DiskSleuth can't see something, it tells you exactly
  how much of the map is dark and how to light it (Full Disk Access).

## Verifying it yourself

```sh
# make a clone and watch du lie:
dd if=/dev/urandom of=orig.bin bs=1m count=64
cp -c orig.bin clone.bin
du -sh .                      # ~128M — wrong
disksleuth scan . --depth 1   # physical ~64M — right
disksleuth info clone.bin     # "Deleting frees ~0 B now"
```

The test suite builds real fixtures — `clonefile(2)`, `link(2)`, sparse files,
permission-denied directories — and asserts the engine's numbers against the
kernel's own (`st_blocks`, `PRIVATESIZE`) on every run.
