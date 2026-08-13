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
- **It never confuses "empty" with "blocked".** A folder macOS refuses to let Sweep read is
  reported as unreadable, never as empty.
- **It knows the difference between changed and used.** Sweep reads the open-record macOS keeps
  (LaunchServices), and treats a missing record as *unknown*, never as "never used".
- **It tells you what it could not do.** Skipped and failed items are listed individually with
  a specific reason, and the headline "freed" number is what verification confirmed is gone —
  not what was attempted.
- **No elevation, ever.** Sweep touches only files inside your home folder. It installs no
  privileged helper, no launch agent, no daemon, and has no networking code at all.
- **Nothing leaves your Mac.** The cleanup history is stored locally, owner-readable only.

## Protection (malware scanning)

Sweep can also look for malware, as an optional scope of the same scan rather than a separate app.

- **Off by default, switched on beside the Scan button.** A storage scan takes seconds; the
  malware pass takes minutes, so it runs only when you ask for it. The choice is remembered.
- **On-demand, not real-time.** Real-time protection needs an Apple entitlement Sweep does not
  have, so it does not claim it.
- **Layered evidence, never one test.** Code signature, notarization and revocation state, macOS
  download provenance, startup-item enumeration, known-bad hashes, known-bad signing
  certificates, and YARA rules — including the rules macOS itself ships.
- **Trust does most of the work.** Apple-signed, notarized, and intact Developer ID code is
  suppressed rather than scrutinised. On one real Mac that accounted for all 8,214 programs
  examined, with zero findings.
- **Only exact matches are ever pre-selected.** A file hash or signing-certificate match can be
  pre-selected for you; anything weaker is shown for review and never ticked.
- **Nothing is deleted.** Detected items go to a reversible, journalled quarantine you can undo.
- **It tells you what it could not check** — unreadable locations, and how old the definitions are.
- **It shows what macOS already did.** XProtect removes malware silently with no interface;
  Sweep surfaces its version and rule count.

Threat definitions are downloaded periodically and matched locally. Nothing about your files —
no names, paths, hashes, or contents — is ever sent anywhere.

## Requirements

macOS 14 or later. Apple Silicon or Intel. Sweep links against system frameworks plus YARA-X
(BSD-3-Clause), which is bundled inside the app — there is nothing to install separately.
Networking is used for one thing only: fetching threat definitions.

Permissions: Sweep may ask for Desktop, Documents, and Downloads access. Full Disk Access is
optional and only widens what macOS lets it see.

## Install

Download `Sweep-1.0.1.dmg` from [Releases](https://github.com/Udhayveer101/Sweep/releases), open
it, and drag Sweep to Applications. Then just open it — the app is signed with a Developer ID
certificate and notarized by Apple, so there is no Gatekeeper warning to work around.

Permissions and troubleshooting are covered in [`docs/INSTALL.md`](docs/INSTALL.md).

## Build from source

```bash
./make-app.sh release      # build/Sweep.app
./make-dmg.sh              # build/Sweep-<version>.dmg
```

`make-app.sh` regenerates the icon from its source drawing on every build, so the shipped asset
cannot drift from the code that defines it.

For development:

```bash
swift build
swift test
```

## Testing

```bash
swift test                                   # 163 tests, 26 suites
SWEEP_PERF=1 swift test --filter Performance # opt-in, runs against your real home folder
```

The suites cover filesystem traversal, each scanner, the safety engine's refusal rules, the
cleanup executor and its restore path, storage accounting, the orchestrator, and — for the
protection scanner — threat correlation, the trust baseline, quarantine and restore, candidate
gating, persistence parsing, provenance, code-signature inspection and definition handling.

A live scan against your own Mac is opt-in, because its results depend on what you have
installed:

```bash
SWEEP_PROTECTION_LIVE=1 swift test --filter LiveProtection
```

It prints what was examined and found, and asserts the rule that matters most: nothing may be
pre-selected for removal without exact-identity evidence.

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

## Safety model

Every finding lands in one of four buckets, and the bucket decides what Sweep is allowed to do:

| Verdict | Meaning | Pre-selected? |
|---|---|---|
| **Safe to delete** | Regenerable data, matched by a rule with corroborating evidence — age, size, and the owning app not running | Yes |
| **Your call** | Real but plausibly wanted: your screenshots, large unopened files | No — listed only |
| **Protected** | Never eligible, and the list cannot be overridden, including by you | Never |
| **Unknown** | Sweep could not gather enough evidence to judge | Never |

The safety engine is consulted twice: once at scan time, and again for every item immediately
before it is touched, because scan results are stale by the time they are acted on. Deletions
go to the Trash and stay restorable. See [`docs/SECURITY.md`](docs/SECURITY.md).

## Architecture

`SweepCore` is a plain Swift library with no UI dependency; `SweepApp` is a SwiftUI shell over
it. Inside Core: **Scanners** produce candidates, **Safety** classifies and gates them,
**Execute** performs and verifies the cleanup with a restore log, **Store** handles storage
accounting and usage evidence, **Brand** holds the vector icon definition. Full breakdown in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Release

Bump `CFBundleShortVersionString`/`CFBundleVersion` in `Resources/Info.plist`, then
`./make-app.sh release && ./make-dmg.sh`, tag `vX.Y.Z`, and attach the DMG to a GitHub release.
Signing and notarization steps — and exactly which of them are currently blocked — are in
[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

## Security

To report a security issue, open a GitHub issue if it is not sensitive, or use GitHub's private
vulnerability reporting on this repository if it is. The threat model, the guarantees the
safety engine enforces, and the accepted limitations are documented in
[`docs/SECURITY.md`](docs/SECURITY.md).

## Documentation

- [`docs/INSTALL.md`](docs/INSTALL.md) — installing, permissions, uninstalling, troubleshooting
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the pipeline, module boundaries, and why each decision was made
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model, safety guarantees, and the adversarial review
- [`docs/STORAGE.md`](docs/STORAGE.md) — storage accounting, why Apple's numbers differ, and the usage-evidence model
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) — signing, notarization, and what genuinely cannot be finished locally

## License

No license has been chosen for this project, so default copyright applies: all rights reserved.
The source is public to read, but there is no grant to reuse or redistribute it. Adding a
license is a decision for the author, not something to assume.

