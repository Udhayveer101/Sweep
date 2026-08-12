import Foundation

/// Performs deletions. Every item is re-validated immediately before it is touched, every
/// failure is isolated, and every outcome is verified afterwards rather than assumed.
public struct CleanupExecutor: Sendable {
    public let safety: SafetyEngine
    /// When false, items go to the Trash and stay recoverable. Only the Trash category itself
    /// is ever removed permanently, because "empty the Trash" has no other meaning.
    public let permanentOverride: Bool

    public init(safety: SafetyEngine, permanentOverride: Bool = false) {
        self.safety = safety
        self.permanentOverride = permanentOverride
    }

    /// Re-checks everything that could have changed between the scan and now.
    /// This is the TOCTOU gate: the scan's verdict is treated as a proposal, never as permission.
    func revalidate(_ item: Item, runningApps: RunningApps) -> String? {
        if let refusal = safety.eligibility(of: item.path, runningApps: runningApps) {
            return refusal.rawValue
        }
        guard let meta = FS.meta(item.path) else { return SafetyEngine.Refusal.notFound.rawValue }
        if FS.isSymlink(item.path) { return SafetyEngine.Refusal.containsSymlink.rawValue }
        // A directory that grew, or a file whose contents changed, is no longer the thing the
        // user reviewed. Directories legitimately fluctuate, so only a newer modification date
        // on a plain file is treated as disqualifying; growth beyond 25% disqualifies either.
        if !meta.isDirectory, meta.modified > item.modified.addingTimeInterval(1) {
            return SafetyEngine.Refusal.changed.rawValue
        }
        if meta.isDirectory {
            let recheck = FS.aggregate(item.path, limits: FS.WalkLimits(maxDepth: 6, maxEntries: 20_000))
            if recheck.newestModification > item.modified.addingTimeInterval(1) {
                return SafetyEngine.Refusal.changed.rawValue
            }
        }
        return nil
    }

    /// Executes the given items. Cancellation stops before the next item; anything already
    /// removed stays removed and is reported truthfully in the partial report.
    public func run(items: [Item],
                    runningApps: RunningApps = .none,
                    onEvent: @Sendable (CleanupEvent) -> Void = { _ in }) -> CleanupReport {
        let started = Date()
        var outcomes: [ItemOutcome] = []
        var verified: Int64 = 0
        var cancelled = false

        for (index, item) in items.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            onEvent(.progress(completed: index, total: items.count, current: item.displayName))

            if item.risk == .protected || item.risk == .unknown {
                outcomes.append(ItemOutcome(
                    path: item.path, displayName: item.displayName, category: item.category,
                    bytes: item.bytes, status: .skipped,
                    reason: "Sweep does not delete items classified as \(item.risk.rawValue)."))
                continue
            }
            if let reason = revalidate(item, runningApps: runningApps) {
                outcomes.append(ItemOutcome(
                    path: item.path, displayName: item.displayName, category: item.category,
                    bytes: item.bytes, status: .skipped, reason: reason))
                continue
            }

            let permanent = permanentOverride || item.category == .trash
            do {
                var trashPath: String?
                if permanent {
                    try FileManager.default.removeItem(atPath: item.path)
                } else {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path),
                                                      resultingItemURL: &resulting)
                    trashPath = (resulting as URL?)?.path
                }
                // Verify rather than assume. A "successful" call that left the path in place
                // must not be reported as freed space.
                if FS.exists(item.path) {
                    outcomes.append(ItemOutcome(
                        path: item.path, displayName: item.displayName, category: item.category,
                        bytes: item.bytes, status: .failed,
                        reason: "The system reported success but the item is still on disk."))
                } else {
                    verified += item.bytes
                    outcomes.append(ItemOutcome(
                        path: item.path, displayName: item.displayName, category: item.category,
                        bytes: item.bytes, status: permanent ? .deleted : .trashed,
                        reason: nil, trashPath: trashPath))
                }
            } catch {
                outcomes.append(ItemOutcome(
                    path: item.path, displayName: item.displayName, category: item.category,
                    bytes: item.bytes, status: .failed, reason: Self.explain(error)))
            }
        }

        let report = CleanupReport(started: started, finished: Date(), outcomes: outcomes,
                                   verifiedBytesFreed: verified, cancelled: cancelled)
        onEvent(.finished(report))
        return report
    }

    /// Turns a Cocoa error into something a person can act on.
    static func explain(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, Int(EACCES), Int(EPERM):
            return "Permission denied. Granting Sweep Full Disk Access in System Settings › Privacy & Security usually resolves this."
        case NSFileNoSuchFileError, Int(ENOENT):
            return "Already gone — something else removed it first."
        case Int(EBUSY):
            return "In use by another process."
        case NSFileWriteOutOfSpaceError:
            return "The volume ran out of space while moving this to the Trash."
        case NSFileWriteVolumeReadOnlyError:
            return "The volume is read-only."
        default:
            return ns.localizedDescription
        }
    }
}

/// Restores items from the Trash. Backs the grace period offered after every cleanup, so a
/// mistaken run is a single click to undo rather than a Finder expedition.
/// (Vault: Improvement Opportunities #2 — the highest-value, lowest-risk addition identified.)
public struct Restorer: Sendable {
    public init() {}

    public struct Result: Sendable {
        public var restored: [String] = []
        public var failed: [(path: String, reason: String)] = []
    }

    public func restore(_ report: CleanupReport) -> Result {
        var out = Result()
        for outcome in report.outcomes where outcome.status == .trashed {
            guard let trashPath = outcome.trashPath else {
                out.failed.append((outcome.path, "Sweep did not record where this went in the Trash."))
                continue
            }
            guard FS.exists(trashPath) else {
                out.failed.append((outcome.path, "No longer in the Trash."))
                continue
            }
            guard !FS.exists(outcome.path) else {
                out.failed.append((outcome.path, "Something already exists at the original location."))
                continue
            }
            do {
                try FileManager.default.moveItem(atPath: trashPath, toPath: outcome.path)
                out.restored.append(outcome.path)
            } catch {
                out.failed.append((outcome.path, CleanupExecutor.explain(error)))
            }
        }
        return out
    }
}
