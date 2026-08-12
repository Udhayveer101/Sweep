# Sweep

A macOS cleanup app that finds files your Mac no longer needs, explains why it thinks so, and
moves them to the Trash so you can change your mind.

Built as an independent product informed by published research into this product category
(see `docs/ARCHITECTURE.md` for where specific decisions come from). It is not a clone of any
existing tool and contains no third-party proprietary code, algorithms, assets, or branding.

## What makes it different

- **Every finding is explained.** Each item carries the rules that produced its verdict —
  what matched, how confidently, and how old it is — visible in one click.
- **Only "safe" is ever pre-selected.** Files you authored are found but never selected for
  you. A match by name alone is never enough to pre-select a deletion.
- **Trash first, with a real way back.** Nothing is deleted permanently unless you opt in.
  After a cleanup, one button puts everything back, and it stays available.
- **It tells you what it could not do.** Skipped and failed items are listed individually with
  a specific reason, and the headline "freed" number is what verification confirmed is gone —
  not what was attempted.
- **No elevation, ever.** Sweep touches only files inside your home folder. It installs no
  privileged helper, no launch agent, no daemon, and has no networking code at all.
- **Nothing leaves your Mac.** The cleanup history is stored locally, owner-readable only.

## Requirements

macOS 14 or later. Apple Silicon or Intel.

## Build and run

```bash
./make-app.sh release
```

That produces `build/Sweep.app`. Open it with `open build/Sweep.app`.

For development:

```bash
swift build
swift test
```

Performance measurements run against your real home folder and are opt-in:

```bash
SWEEP_PERF=1 swift test --filter Performance
```

## What it scans

| Category | Where | Pre-selects? |
|---|---|---|
| App Caches | `~/Library/Caches` | Only if old, large, and its app is not running |
| Log Files | `~/Library/Logs` | Only if older than 14 days |
| Trash | `~/.Trash` | Only items trashed over 30 days ago (removal is permanent) |
| Developer Junk | DerivedData, npm, Gradle, Cargo, pip, CocoaPods, SwiftPM, Homebrew, pub, Yarn | Only if untouched for 7 days |
| Old Installers | `.dmg`/`.pkg` in Downloads and Desktop | Only if older than 30 days |
| Leftovers From Removed Apps | Application Support, Containers, Saved Application State | Only on an exact bundle-identifier match with the app absent |
| Screenshots & Screen Recordings | Desktop, Downloads, Documents, Movies | Never |
| Large & Unopened Files | Desktop, Downloads, Documents, Movies | Never |

`~/Music` and `~/Pictures` are deliberately not scanned: their contents are managed by Music
and Photos, and walking them would make macOS prompt for media-library access Sweep does not
need.

## Full Disk Access

Optional. Without it macOS hides some caches and logs from Sweep, so scans find less — the app
detects this, says so plainly, and works anyway. Sweep never demands it and never nags.

## Documentation

- `docs/ARCHITECTURE.md` — the pipeline, module boundaries, and why each decision was made
- `docs/SECURITY.md` — threat model, safety guarantees, and the adversarial review
- `docs/DEPLOYMENT.md` — signing, notarization, and what genuinely cannot be finished locally
