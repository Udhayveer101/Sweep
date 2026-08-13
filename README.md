# Sweep

A macOS cleanup app that finds files your Mac no longer needs, explains why it thinks so, and
moves them to the Trash so you can change your mind.

Built as an independent product informed by published research into this product category
(see `docs/ARCHITECTURE.md` for where specific decisions come from). It is not a clone of any
existing tool and contains no third-party proprietary code, algorithms, assets, or branding.

## What makes it different

Every finding is explained. Each item carries the rules that produced its verdict: what matched,
how confidently, and how old it is, all visible in one click.

Only "safe" is ever pre-selected. Files you wrote yourself are found but never selected for you,
and a match by name alone is never enough to pre-select a deletion.

Deletions go to the Trash first, with a real way back. Nothing is removed permanently unless you
opt in, and after a cleanup one button puts everything back. That button stays available.

Sweep never confuses "empty" with "blocked". A folder macOS refuses to let it read is reported as
unreadable, not as empty.

It knows the difference between changed and used. Sweep reads the record macOS keeps of what has
been opened (LaunchServices) and treats a missing record as unknown, never as "never used".

It tells you what it could not do. Skipped and failed items are listed one by one with a specific
reason, and the headline "freed" figure is what verification confirmed is gone, not what was
attempted.

No elevation, ever. Sweep touches only files inside your home folder. It installs no privileged
helper, no launch agent, and no daemon.

Nothing about your files leaves your Mac. The cleanup history is stored locally and is readable
only by you.

## Protection (malware scanning)

Sweep can also look for malware. It runs as an optional part of the same scan rather than as a
separate app.

Protection is off by default and switched on beside the Scan button. A storage scan takes
seconds and the malware pass takes minutes, so it runs only when you ask for it. Sweep remembers
the choice.

It is an on-demand scanner, not real-time protection. Real-time protection needs an Apple
entitlement Sweep does not have, so Sweep does not claim it.

Detection is layered rather than a single test. Sweep looks at the code signature, notarization
and revocation state, where macOS recorded the file coming from, what starts automatically,
known-bad file hashes, known-bad signing certificates, and YARA rules, including the rules macOS
itself ships.

Trust does most of the work. Code that is signed by Apple, notarized, or carries an intact
Developer ID is set aside rather than picked over. On one real Mac that accounted for all 8,214
programs examined, and the scan reported nothing.

Only exact matches are ever pre-selected. A file hash or a signing-certificate match can arrive
ticked; anything weaker is shown for review and left alone.

Nothing is deleted. Detected items go to a reversible quarantine with a journal, and you can put
any of them back.

Sweep says what it could not check, including unreadable locations and how old the definitions
are.

It also shows what macOS has already done. XProtect removes malware silently and has no
interface of its own, so Sweep reports its version and rule count.

Threat definitions are downloaded periodically and matched on your Mac. Nothing about your files
is sent anywhere: not names, not paths, not hashes, not contents.

## Requirements

macOS 14 or later, on Apple Silicon or Intel. Sweep links against system frameworks plus YARA-X
(BSD-3-Clause), which is bundled inside the app, so there is nothing to install separately.
The only thing Sweep uses the network for is fetching threat definitions.

Permissions: Sweep may ask for Desktop, Documents, and Downloads access. Full Disk Access is
optional and only widens what macOS lets it see.

## Install

Download the DMG from [Releases](https://github.com/Udhayveer101/Sweep/releases), open it, and
drag Sweep to Applications. Then just open it. The app is signed with a Developer ID certificate
and notarized by Apple, so there is no Gatekeeper warning to work around.

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
swift test                                   # 172 tests, 28 suites
```

The suites cover filesystem traversal, each scanner, the safety engine's refusal rules, the
cleanup executor and its restore path, storage accounting, and the orchestrator. For the
protection scanner they cover threat correlation, the trust baseline, quarantine and restore,
candidate gating, persistence parsing, provenance, code-signature inspection, and how
definitions are stored and migrated.

A live protection scan against your own Mac is opt-in, because what it finds depends on what you
have installed:

```bash
SWEEP_PROTECTION_LIVE=1 swift test --filter LiveProtection
```

It prints what was examined and found, and it asserts the rule that matters most: nothing may be
pre-selected for removal without exact-identity evidence.

Performance measurements also run against your real home folder, and are opt-in for the same
reason:

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

`~/Music` and `~/Pictures` are deliberately not scanned. Music and Photos manage their contents,
and walking them would make macOS prompt for media-library access Sweep does not need.

## Full Disk Access

Optional. Without it, macOS hides some caches and logs from Sweep and scans find less. The app
detects this, says so plainly, and works anyway. Sweep never demands it and never nags.

## Safety model

Every finding lands in one of four buckets, and the bucket decides what Sweep is allowed to do.

| Verdict | Meaning | Pre-selected? |
|---|---|---|
| Safe to delete | Regenerable data, matched by a rule with corroborating evidence: age, size, and the owning app not running | Yes |
| Your call | Real but plausibly wanted, such as your screenshots and large unopened files | No, listed only |
| Protected | Never eligible, and the list cannot be overridden, including by you | Never |
| Unknown | Sweep could not gather enough evidence to judge | Never |

The safety engine is consulted twice: once at scan time, and again for every item immediately
before it is touched, because scan results are stale by the time they are acted on. Deletions go
to the Trash and stay restorable. See [`docs/SECURITY.md`](docs/SECURITY.md).

## Architecture

`SweepCore` is a plain Swift library with no UI dependency, and `SweepApp` is a SwiftUI shell
over it. Inside Core, Scanners produce candidates, Safety classifies and gates them, Malware
gathers protection evidence and classifies threats, Execute performs and verifies the cleanup
with a restore log, Store handles storage accounting and usage evidence, and Brand holds the
vector icon definition. Full breakdown in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Release

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, run
`./make-app.sh release && ./make-dmg.sh`, tag `vX.Y.Z`, and attach the DMG to a GitHub release.
Signing and notarization are covered in [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md), along with
which steps need credentials that are not in the repository.

## Security

To report a security issue, open a GitHub issue if it is not sensitive, or use GitHub's private
vulnerability reporting on this repository if it is. The threat model, the guarantees the safety
engine enforces, and the accepted limitations are documented in
[`docs/SECURITY.md`](docs/SECURITY.md).

## Documentation

- [`docs/INSTALL.md`](docs/INSTALL.md) covers installing, permissions, uninstalling, and troubleshooting
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) covers the pipeline, module boundaries, and why each decision was made
- [`docs/SECURITY.md`](docs/SECURITY.md) covers the threat model, safety guarantees, and the adversarial review
- [`docs/STORAGE.md`](docs/STORAGE.md) covers storage accounting, why Apple's numbers differ, and the usage-evidence model
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) covers signing, notarization, and what cannot be finished locally

## License

No license has been chosen for this project, so default copyright applies and all rights are
reserved. The source is public to read, but there is no grant to reuse or redistribute it.
Adding a license is a decision for the author, not something to assume.
