# Storage accounting and usage evidence

## Why Sweep's numbers differ from System Settings › Storage

macOS presents categories (Applications, Bin, Developer, Documents, iCloud Drive, Mail, Messages,
Photos, Other Users & Shared, macOS, System Data) whose figures come from system-level accounting.
They cannot be reproduced by summing directories, for reasons that are structural:

- **Purgeable space.** Caches, local snapshots and evicted iCloud files count as available-when-
  needed. `volumeAvailableCapacityForImportantUsage` includes them, raw availability does not.
  Measured on the development machine: 182.24 GB vs 152.01 GB, a 30.25 GB gap.
- **APFS clones.** Copied files share blocks until modified, so per-file sizes over-sum.
- **Local snapshots.** Occupy real space attributed to no directory.
- **Sealed system volume.** "macOS" spans a read-only, SIP-protected volume.
- **TCC.** Locations without permission cannot be measured at all.
- **"System Data" is a residual, not a place.** It is what remains after other categories are
  attributed. No app can reproduce it by walking folders.

## What Sweep therefore does

It reports two clearly separated kinds of number and never blends them:

| Kind | Source | Shown as |
|---|---|---|
| System-reported | Volume resource keys | "Figures reported by macOS for this volume" |
| Measured by Sweep | Its own traversal | Per-category totals, always a subset |
| Not knowable | none | No number, plus the reason |

The "What Sweep covers…" sheet maps every macOS category to `covered` / `partly covered` /
`out of scope` with a plain-language explanation. A test keeps that map complete in both
directions.

## Usage evidence: what "used" actually means

The rule this codebase is built around: **`lastModified` is not `lastUsed`, and `lastAccessed`
is not `lastOpened`.**

| Signal | Source | Meaning |
|---|---|---|
| `kMDItemLastUsedDate` | LaunchServices via Spotlight | A person opened this. The only true use signal. |
| `kMDItemUseCount` | Spotlight | How many opens were recorded. |
| mtime | Foundation | Last write. Strong for app-managed data, weak for user documents. |
| atime | Foundation | **Not trusted.** Backup, indexing and antivirus all update it. |
| Running process | AppKit snapshot | Definitive current use. |

`kMDItemLastUsedDate == nil` means **no evidence**, not "never used". Treating nil as unused would
be the largest false-positive source in a tool like this, so evidence is confidence-tiered:

- high: a recorded open date, or the owner is running.
- medium: app-written data whose write time is a sound proxy; or a user-openable item whose
  absent open record is informative because Spotlight *was* reachable.
- low: timestamps only, on content where they establish nothing.
- none: Spotlight unreachable and nothing else to go on.

`.safe` requires at least `medium`. Weak evidence can never produce a pre-selected deletion.

## Freshness

The volume figures are re-read on every event that can change them. The storage panel
appearing, the app becoming active, waking from sleep, a volume mounting or unmounting, and the
completion of a cleanup or a restore. There is no timer and no cache.

That is affordable because a read is a syscall, not a traversal: ~0.002 ms optimised. Caching it
would buy nothing and would introduce the one failure mode worth avoiding here, which is showing a stale
number as though it were current. The panel displays the time the figures were read so the claim
is checkable.

A read that fails (an unreadable or disconnected volume) clears the figures and shows the reason,
rather than leaving the previous values on screen.

## Cost

Adding the metadata layer did not slow scanning: 15.6 s versus 16.3 s for a full scan at
concurrency 4, because evidence reuses the modification date the size walk already computed
instead of re-walking the tree.
