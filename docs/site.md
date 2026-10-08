# Project site

`site/` is published to https://denmanjohn-maker.github.io/macdisksleuth/ by the **Pages** workflow on every push to `main` that touches `site/`.

**One-time setup:** repo Settings → Pages → Source: **GitHub Actions**.

## Adding screenshots

Drop PNGs into `site/img/` with these names. The page shows only the ones that exist, and hides the gallery entirely if there are none:

| File | What to capture |
|---|---|
| `overview.png` | Disk overview view |
| `sunburst.png` | Sunburst of a scanned folder |
| `lenses.png` | Size-lens toggle (logical / physical / freeable) |
| `delete.png` | Delete-to-Trash confirmation showing freeable bytes |
| `quickaction.png` | Finder Quick Actions menu with "Analyze with DiskSleuth" |
| `cli.png` | `disksleuth scan ~ --top 15` in a terminal |

Tips: ⇧⌘4 then Space then click a window for a clean capture with shadow. Keep each under ~500 KB (`sips -Z 1800 file.png` to downscale).
