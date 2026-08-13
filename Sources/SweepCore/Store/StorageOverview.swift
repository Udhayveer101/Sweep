import Foundation

/// Volume figures and an honest map of what Sweep does and does not account for.
///
/// The motivating problem: macOS System Settings › Storage shows categories (Applications,
/// System Data, macOS, Other Users & Shared, Photos, Mail, Messages…) whose numbers come from
/// system-level accounting that third-party apps cannot reproduce. Summing directories does not
/// give the same answer, for reasons that are real rather than cosmetic:
///
///  * **Purgeable space.** APFS reports space that macOS can reclaim on demand (caches, local
///    snapshots, offloaded iCloud files) as available-when-needed but occupied right now.
///    `volumeAvailableCapacityForImportantUsage` includes it; the raw `volumeAvailableCapacity`
///    and `statfs` do not. On the machine this was developed against the gap was ~30 GB.
///  * **APFS clones.** Copied files share blocks until modified, so per-file allocated sizes can
///    sum to far more than the space actually consumed.
///  * **Local snapshots.** Time Machine snapshots occupy real space attributed to no directory.
///  * **Sealed system volume.** "macOS" spans a read-only sealed volume Sweep never traverses.
///  * **TCC.** Locations the user has not granted access to cannot be measured at all.
///
/// So Sweep reports two clearly-labelled kinds of number and never blurs them: figures the
/// system gives it, and figures it measured itself. It never claims its own total equals
/// Apple's.
public struct StorageOverview: Sendable {

    // MARK: - System-reported (from the volume itself, not computed by Sweep)

    public let totalCapacity: Int64
    /// Free space as the filesystem reports it, excluding anything purgeable.
    /// This is *not* the figure System Settings shows as available: see `freeCapacity`.
    public let availableCapacity: Int64
    /// What macOS says is available for important usage: this *includes* purgeable space.
    public let availableForImportantUsage: Int64
    /// When these figures were read. Displayed so a user can tell current data from stale.
    public let measuredAt: Date

    /// Free space **on the same basis System Settings uses**: purgeable space counts as free,
    /// because macOS will reclaim it automatically when something needs the room.
    ///
    /// Verified by measurement rather than assumed: on the development machine
    /// `total − availableForImportantUsage` = 298.85 GB against System Settings' 298.73 GB,
    /// while `total − availableCapacity` = 328.51 GB: an error of exactly the purgeable amount.
    /// Using raw availability here is the specific bug this property exists to prevent.
    public var freeCapacity: Int64 { availableForImportantUsage }

    public var usedCapacity: Int64 { max(0, totalCapacity - availableForImportantUsage) }

    /// Space macOS can reclaim by itself (caches, local snapshots, evicted iCloud files).
    /// It is a *subset of free space*, not a fourth independent number, so the figures add up.
    /// Derived from two system values; Apple exposes no direct "purgeable" API, and the UI
    /// labels it accordingly.
    public var reclaimableByMacOS: Int64 { max(0, availableForImportantUsage - availableCapacity) }

    /// What would still be occupied if macOS reclaimed everything it could right now.
    public var usedExcludingReclaimable: Int64 { max(0, totalCapacity - availableCapacity) }

    public init(totalCapacity: Int64, availableCapacity: Int64,
                availableForImportantUsage: Int64, measuredAt: Date = Date()) {
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
        self.measuredAt = measuredAt
    }

    /// Reads the volume's current figures. It is a statfs-backed syscall, not a traversal:
    /// measured at ~0.002 ms in an optimised build (~12 ms in a debug build, where Foundation
    /// bridging dominates). Cheap enough to call on every screen appearance, so it needs
    /// neither a cache nor a loading state. Which is precisely why the display cannot go stale.
    public static func read(path: String = NSHomeDirectory(), now: Date = Date()) -> StorageOverview? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity,
              let available = v.volumeAvailableCapacity else { return nil }
        // Absent on some volume types (network shares, certain disk images); falling back to raw
        // availability keeps the arithmetic consistent rather than producing a negative figure.
        let important: Int64 = v.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        return StorageOverview(totalCapacity: Int64(total),
                               availableCapacity: Int64(available),
                               availableForImportantUsage: max(important, Int64(available)),
                               measuredAt: now)
    }
}

/// One row of the honest coverage map: a category macOS shows the user, and what Sweep can
/// legitimately say about it.
public struct CoverageEntry: Sendable, Identifiable, Hashable {
    public enum Level: String, Sendable {
        /// Sweep scans this area and its figure is meaningful on its own terms.
        case covered
        /// Sweep scans part of it. Its number is a subset and must never be presented as the total.
        case partial
        /// Deliberately out of scope. Sweep reports no number rather than a misleading one.
        case notCovered
    }

    public var id: String { macOSCategory }
    /// The label as macOS System Settings › Storage presents it.
    public let macOSCategory: String
    public let level: Level
    /// Which Sweep categories, if any, look inside this area.
    public let sweepCategories: [SweepCategory]
    /// Why the level is what it is. Shown to the user verbatim.
    public let explanation: String

    public init(macOSCategory: String, level: Level, sweepCategories: [SweepCategory] = [], explanation: String) {
        self.macOSCategory = macOSCategory
        self.level = level
        self.sweepCategories = sweepCategories
        self.explanation = explanation
    }
}

public enum StorageCoverage {

    /// Every category macOS currently presents in System Settings › Storage, each mapped to what
    /// Sweep actually does. Categories Sweep cannot address are listed explicitly as not covered
    /// rather than omitted, so the user can see the boundary instead of inferring it from silence.
    public static let map: [CoverageEntry] = [
        CoverageEntry(
            macOSCategory: "Applications",
            level: .notCovered,
            explanation: "Sweep does not uninstall applications, so it reports no figure here. Removing an app is a decision with consequences Sweep is not designed to reason about."),
        CoverageEntry(
            macOSCategory: "Bin (Trash)",
            level: .covered,
            sweepCategories: [.trash],
            explanation: "Sweep reads your Trash directly. macOS also counts the Trash of other volumes and other user accounts here, which Sweep does not touch, so its figure can be smaller than the system's."),
        CoverageEntry(
            macOSCategory: "Developer",
            level: .partial,
            sweepCategories: [.developerJunk],
            explanation: "Sweep covers regenerable build products and package caches. It does not count source code, simulators, or SDKs, which are not junk."),
        CoverageEntry(
            macOSCategory: "Documents",
            level: .partial,
            sweepCategories: [.largeOldFiles, .screenRecordings, .staleInstallers],
            explanation: "Sweep surfaces large unopened files, screen captures and installers, and never pre-selects any of them. It deliberately does not attempt to total your documents."),
        CoverageEntry(
            macOSCategory: "iCloud Drive",
            level: .notCovered,
            explanation: "Files stored in iCloud may be placeholders on this Mac. Deleting them locally can remove them from iCloud on every device, so Sweep does not touch this area at all."),
        CoverageEntry(
            macOSCategory: "Mail",
            level: .notCovered,
            explanation: "Mail data is a live database. Sweep protects it and reports no figure."),
        CoverageEntry(
            macOSCategory: "Messages",
            level: .notCovered,
            explanation: "Messages data is a live database, and its attachments are your content. Protected."),
        CoverageEntry(
            macOSCategory: "Photos",
            level: .notCovered,
            explanation: "A Photos library is a managed bundle whose internals must only be changed by Photos. Protected."),
        CoverageEntry(
            macOSCategory: "Other Users & Shared",
            level: .notCovered,
            explanation: "Belongs to other accounts on this Mac. Sweep works only inside your own home folder and cannot read it."),
        CoverageEntry(
            macOSCategory: "macOS",
            level: .notCovered,
            explanation: "The operating system, largely on a read-only sealed volume protected by System Integrity Protection. Nothing here can or should be removed by an app."),
        CoverageEntry(
            macOSCategory: "System Data",
            level: .partial,
            sweepCategories: [.userCaches, .userLogs],
            explanation: "A catch-all macOS uses for caches, logs, snapshots, swap and other system-managed files. Sweep addresses only the part inside your own Library: caches and logs it can attribute to an app. Most of System Data is outside its scope and Sweep does not estimate the remainder."),
    ]

    /// Sweep categories that no macOS storage row corresponds to cleanly, kept visible so the
    /// mapping is auditable in both directions.
    public static let sweepOnly: [SweepCategory] = [.appLeftovers]
}
