# Architecture

## The pipeline

```
Discovery      each scanner knows its own locations
   ↓
Scan           FS.aggregate, symlink-refusing, depth- and budget-bounded
   ↓
Classify       attribution tiering (bundle ID → path convention → name)
   ↓
Risk assess    SafetyEngine, the only authority on "may this be deleted"
   ↓
Recommend      RecommendationEngine, pre-selects .safe and nothing else
   ↓
User review    every item inspectable, every verdict explained
   ↓
Cleanup        CleanupExecutor re-validates each item immediately before touching it
   ↓
Verify         confirms the path is actually gone before counting the bytes
   ↓
Report         per-item outcomes with reasons; local-only history log
```

Each stage is a separate type with no shared mutable state, which is what makes them
independently testable against fixture directory trees rather than a real home folder.

## The protection pipeline

Malware scanning is an optional second scope of the same scan, not a second application. It is
off by default and enabled by the Protection control beside the Scan button, because the cleanup
pass costs seconds and the protection pass costs minutes. Bundling them would make the common
case slower for a check most runs do not need. The choice persists in `Settings`. It reuses the
cleanup side's shape (discover, gather evidence, classify, recommend, act, verify, report)
and its safety instincts.

```
Inventory      candidate artifacts only (Mach-O, scripts, bundles, persistence, extensions)
   ↓
Trust          Apple-signed / notarized / intact Developer ID / pre-existing ⇒ suppressed
   ↓
Evidence       signature · provenance · persistence · hash IOC · certificate · YARA rules
   ↓
Correlate      ThreatCorrelator, the only type allowed to reach a verdict
   ↓
Classify       threat class × confidence tier
   ↓
User review    every finding explains itself; only exact-identity matches are pre-selected
   ↓
Quarantine     reversible, journalled, verified. Nothing is ever deleted
   ↓
Report         per-item outcomes with reasons, plus what was *not* scanned
```

Layers emit `Signal`s, never verdicts. That separation is what lets third-party rule sets be
used safely: a rule match on validly-signed, non-revoked code is demoted rather than raised.

## Modules

| Type | Responsibility |
|---|---|
| `SweepCore` | All logic. Foundation only, with no AppKit and no SwiftUI, so it is testable headlessly. |
| `SweepApp` | SwiftUI layer. Owns AppKit concerns: running-app snapshots, Finder reveal, panels. |
| `FS` | Filesystem primitives. Every traversal is bounded and refuses symlinks. |
| `SafetyEngine` | Eligibility (hard gate) and classification (risk tier + rationale). |
| `CleanupScanner` (protocol) | 8 implementations, one per category, each owning its locations. |
| `ScanOrchestrator` | Bounded-concurrency fan-out, failure isolation, dedup, single-scan lock. |
| `RecommendationEngine` | Pre-selection and neutral summary text. |
| `CleanupExecutor` | Re-validation, deletion, per-item verification. |
| `Restorer` | Puts a cleanup back from the Trash. |
| `HistoryStore` | Local-only, bounded, owner-readable-only cleanup log. |
| `FullDiskAccess` | Probe-based TCC detection (errno-classified, multi-path) with graceful degradation. Re-read on `didBecomeActive`, so returning from System Settings updates the banner without a relaunch. |
| `MalwareScanner` | Protection-scan orchestration, bounded concurrency, coverage accounting. |
| `CodeSignatureInspector` | `SecStaticCode` validity, notarization, revocation, cdhash, Team ID. |
| `TrustBaseline` | Decides what needs no accusing. The main false-positive control. |
| `ThreatCorrelator` | The only authority on "is this a threat", mirroring `SafetyEngine`. |
| `PersistenceEnumerator` | launchd, plug-in surfaces, shell init, cron. |
| `QuarantineStore` | Reversible isolation with a journal and verified restore. |
| `DefinitionsUpdater` | HTTPS-only definition fetch, verified atomic swap, rollback. |
| `YaraEngine` | YARA-X binding; reads Apple's live XProtect rules in place. |
| `XProtectStatus` | Surfaces what macOS's own protection is doing. |

## Decisions and why

### The malware scanner is on-demand, and says so
Real-time protection needs the Endpoint Security entitlement, which Apple grants case-by-case
with no published criteria. Sweep is architected as though it will never arrive, and the UI
never implies protection it does not provide. See `docs/SECURITY.md`.

### Detection is layered, and trust suppresses
No single test may condemn a file. The trust baseline removes the overwhelming majority of the
corpus cheaply, and only the residue reaches the expensive layers. Measured on one real Mac:
8,214 artifacts examined, all suppressed by trust, 0 findings, ~155 s.

### No privileged helper, no elevation
The scope is user-owned files only. Narrowing the scope removes the need for a privileged
helper entirely: no `SMAppService` registration, no XPC surface, no admin prompt, and no
installed component that outlives the app. This is the single biggest attack-surface decision
in the project, and it is a deliberate trade: Sweep cannot clean `/Library` or system caches.
That is the correct trade for a tool whose main risk is deleting the wrong thing.

### Safety is one shared layer, not per-scanner logic
Scanners produce candidates; they do not decide what may be deleted. `SafetyEngine.eligibility`
is called at scan time *and* again immediately before every deletion. A scanner cannot bypass
it, and the executor refuses anything it has not personally re-checked.

### A two-tier protection list
An immutable tier ships with the app (keychains, iCloud Drive, Mail, Messages, Safari, iOS
backups, SSH/GPG/cloud credentials, Photos libraries, Preferences, the Applications folder) and
a user-extensible tier is added through Settings. The immutable tier cannot be edited away.

### Attribution is tiered and disclosed, not a black box
`exactBundleID` > `pathConvention` > `nameHeuristic`. The tier is shown to the user in plain
words, and a name-only match is never sufficient to pre-select a deletion. This is the piece of
the problem where a confident-but-wrong match does real damage, so the weakest signal is
explicitly demoted rather than blended into an opaque score.

### Age as a pre-selection proxy, never as deletion permission
Every category has an age threshold used solely to decide what arrives pre-checked. Age never
grants permission to delete; eligibility does.

### Risk and confidence are two axes, not one
`Risk` is about consequences (`safe`/`review`/`unknown`/`protected`). `Confidence` is about
evidence quality (`high`/`medium`/`low`/`none`). Two invariants are enforced centrally so no
category can forget them: `.safe` requires at least `.medium` confidence, and an item whose
owning application is running is never `.safe`. See `docs/STORAGE.md` for the evidence model.

### "Could not look" is never rendered as "nothing there"
`CategoryResult` tracks `unreadableRoots` separately from an empty item list, because a
TCC-blocked folder and an empty folder are indistinguishable at the API level and must not be
indistinguishable in the UI. This fixed a real bug: with the Trash protected, Sweep showed
"Nothing found / Zero KB" while macOS reported 5.36 GB in it.

### Bounded concurrency, measured rather than assumed
The orchestrator caps concurrent scanners at 4. Measured on an M1, macOS 26.5.1, warm cache:

| Concurrency | Wall clock |
|---|---|
| 1 | 38.0 s |
| 4 | 16.3 s |
| 8 | 20.6 s |

These scanners are disk-bound; more concurrency past 4 causes I/O contention and gets *slower*.
Cancellation takes effect in ~0.5 s. Reproduce with `SWEEP_PERF=1 swift test --filter Performance`.

### Deduplication is structural
Two scanners claiming the same bytes would inflate totals and queue the same path for deletion
twice. `LeftoverScanner` does not claim `~/Library/Caches` (the cache scanner owns it), and the
orchestrator additionally drops any item nested inside an already-claimed path.

### Verification, not optimism
The executor re-checks that each path is gone after removing it. The reported "freed" figure is
the sum of verified removals only. A call that returns success but leaves the file in place is
reported as a failure, because that is what it is.

## Concurrency model

`SweepCore` is Swift 6 strict-concurrency clean. Scanners are `Sendable` structs, the
orchestrator and history store are actors, and `AppModel` is `@MainActor`. Scanning and cleanup
run off the main actor; only results cross back. Cancellation is cooperative (`Task.isCancelled`)
and is checked inside the directory walk, not merely between scanners.

## Research lineage

Design decisions trace to the accumulated research in the CleanMyMac Obsidian vault, principally
the three-tier detected/shown/auto-selected safety model, the "review before execute" principle,
the undo-grace-period gap, disclosed leftover matching, per-item skip reasons, a local-only
cleanup history, and the observation that narrowing scope avoids needing privilege. Concrete
sources are recorded in the vault note `27 - Implementation`.
