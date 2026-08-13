import CoreServices
import Foundation

/// How much the app trusts its own conclusion about an item.
///
/// Confidence is about *evidence quality*, and is deliberately separate from `Risk`, which is
/// about consequences. A cache with weak evidence and a document with strong evidence can both
/// be `.review`, for entirely different reasons.
public enum Confidence: String, Codable, Sendable, Comparable {
    /// Direct evidence from a system that records actual use.
    case high
    /// Indirect but sound evidence. E.g. a file only its owning app writes to, and it has not
    /// been written to in a long time.
    case medium
    /// Weak evidence. Timestamps only, of a kind that does not establish use.
    case low
    /// No usable evidence at all. Never sufficient to recommend anything.
    case none

    private var order: Int {
        switch self { case .high: 3; case .medium: 2; case .low: 1; case .none: 0 }
    }
    public static func < (a: Confidence, b: Confidence) -> Bool { a.order < b.order }
}

/// What macOS can actually tell us about whether something is used.
///
/// The central correctness rule of this type: **`modified` is not `lastUsed`, and `accessed` is
/// not `lastOpened`.** They are collected separately, labelled separately, and weighted
/// separately. `accessed` (POSIX atime) is recorded for display but never raises confidence:
/// backup, indexing, and antivirus passes all touch it, so it does not evidence *user* activity.
public struct UsageEvidence: Sendable, Codable, Hashable {

    /// Last time LaunchServices recorded this item being opened (`kMDItemLastUsedDate`).
    /// This is the only signal that means "a user opened this". Nil means *no evidence*,
    /// which is not the same as "never opened".
    public var lastUsed: Date?
    /// `kMDItemUseCount`. How many times LaunchServices has recorded an open.
    public var useCount: Int?
    /// POSIX mtime, or the newest mtime in a directory tree. Means "last written", which for
    /// app-managed data (caches, logs) is a good activity signal and for user documents is not.
    public var modified: Date
    /// Birth time where the filesystem records one.
    public var created: Date?
    /// POSIX atime. Displayed, never trusted. See the type doc.
    public var accessed: Date?
    /// `kMDItemDateAdded`. When the item arrived in its folder (e.g. when it was downloaded).
    public var added: Date?
    /// The owning application is running right now.
    public var isRunning: Bool
    /// True when Spotlight could not be consulted for this path at all, so the absence of
    /// `lastUsed` carries no information whatsoever.
    public var metadataUnavailable: Bool

    public init(lastUsed: Date? = nil, useCount: Int? = nil, modified: Date, created: Date? = nil,
                accessed: Date? = nil, added: Date? = nil, isRunning: Bool = false,
                metadataUnavailable: Bool = false) {
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.modified = modified
        self.created = created
        self.accessed = accessed
        self.added = added
        self.isRunning = isRunning
        self.metadataUnavailable = metadataUnavailable
    }

    // MARK: - Interpretation

    /// Days since the strongest *use* signal available, or nil when there is no use signal.
    /// Deliberately does not fall back to `modified`: that would silently restate a write as a use.
    public func daysSinceLastUse(now: Date = Date()) -> Int? {
        guard let lastUsed else { return nil }
        return Int(now.timeIntervalSince(lastUsed) / 86_400)
    }

    public func daysSinceModified(now: Date = Date()) -> Int {
        Int(now.timeIntervalSince(modified) / 86_400)
    }

    /// How much this evidence supports a claim about whether the item is still in use.
    ///
    /// - `.high`. The item is running, or LaunchServices has a recorded open date.
    /// - `.medium`. No use record, but the item is app-managed data whose write time is a
    ///   sound activity proxy, and Spotlight was reachable (so the absence is informative).
    /// - `.low`. Write time only, on data a write time does not describe well.
    /// - `.none`. Spotlight unavailable and nothing else to go on.
    public func confidence(for category: SweepCategory) -> Confidence {
        if isRunning || lastUsed != nil { return .high }
        switch category.evidenceModel {
        case .appManagedWrites:
            // Nobody "opens" a cache folder, so no use record is expected. The write time is
            // the real signal, and it is trustworthy here because only the owning app writes.
            return .medium
        case .userOpenable:
            // These are things a person opens (a disk image, a trashed file). Spotlight having
            // no open record is therefore informative: but only if Spotlight was reachable.
            return metadataUnavailable ? .low : .medium
        case .userAuthored:
            // Sweep never pre-selects these, and it will not pretend to know whether a document
            // matters to its owner.
            return .low
        }
    }

    /// Plain-language evidence lines, shown verbatim in the UI so a verdict is never a black box.
    public func statements(now: Date = Date(), category: SweepCategory) -> [Rationale] {
        var out: [Rationale] = []
        if isRunning {
            out.append(Rationale(rule: "In use now",
                                 detail: "The application that owns this is running."))
        }
        if let lastUsed, let days = daysSinceLastUse(now: now) {
            let count = useCount.map { " Opened \($0) time(s) in total." } ?? ""
            out.append(Rationale(
                rule: "Last opened",
                detail: "macOS recorded this being opened \(days) day(s) ago (\(Self.day(lastUsed))).\(count)"))
        } else if metadataUnavailable {
            out.append(Rationale(
                rule: "No usage record",
                detail: "macOS has no opened-date for this path, and Spotlight could not be consulted, so this is unknown, not 'never used'."))
        } else {
            out.append(Rationale(
                rule: "No usage record",
                detail: category.writeTimeIsMeaningful
                    ? "macOS has no opened-date for this, which is expected because apps write here without a user ever opening it. Its write time is the meaningful signal."
                    : "macOS has no opened-date for this. That means unknown, not 'never used'."))
        }
        out.append(Rationale(
            rule: "Last changed",
            detail: "Written \(daysSinceModified(now: now)) day(s) ago (\(Self.day(modified))). A write is not the same as a use."))
        if let created {
            out.append(Rationale(rule: "Created", detail: Self.day(created)))
        }
        if let added, created == nil || abs(added.timeIntervalSince(created!)) > 86_400 {
            out.append(Rationale(rule: "Added to this folder", detail: Self.day(added)))
        }
        if let accessed {
            out.append(Rationale(
                rule: "Last accessed (not trusted)",
                detail: "\(Self.day(accessed)). macOS updates this for backups and indexing too, so Sweep never bases a decision on it."))
        }
        return out
    }

    static func day(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }
}

/// How a category's contents come to exist, which determines which timestamps mean anything.
public enum EvidenceModel: String, Sendable {
    /// Written by an application, never opened by a person. Write time is the activity signal;
    /// an absent open-record is expected and says nothing.
    case appManagedWrites
    /// Things a person opens directly. An absent open-record is genuine evidence: provided
    /// Spotlight was reachable.
    case userOpenable
    /// Content the user created. No timestamp establishes whether it still matters to them.
    case userAuthored
}

extension SweepCategory {
    public var evidenceModel: EvidenceModel {
        switch self {
        case .userCaches, .userLogs, .developerJunk, .appLeftovers: .appManagedWrites
        case .trash, .staleInstallers: .userOpenable
        case .largeOldFiles, .screenRecordings: .userAuthored
        }
    }

    /// True when modification time is a sound proxy for "still in use".
    public var writeTimeIsMeaningful: Bool { evidenceModel == .appManagedWrites }
}

/// Reads macOS metadata for a path. Kept behind one type so it can be swapped in tests and so
/// every Spotlight assumption lives in one auditable place.
public struct MetadataReader: Sendable {
    public init() {}

    /// Collects every usage signal macOS exposes for a path.
    ///
    /// `treeModified` lets a caller pass the newest modification date of a whole directory tree,
    /// which it has usually already computed during the size walk: re-walking here would double
    /// the I/O for no new information.
    public func evidence(for path: String, treeModified: Date? = nil, isRunning: Bool = false) -> UsageEvidence {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey,
                                         .contentAccessDateKey, .addedToDirectoryDateKey]
        let values = try? url.resourceValues(forKeys: keys)

        var lastUsed: Date?
        var useCount: Int?
        var added = values?.addedToDirectoryDate
        var unavailable = true
        if let item = MDItemCreate(nil, path as CFString) {
            unavailable = false
            lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            useCount = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? Int
            if added == nil { added = MDItemCopyAttribute(item, "kMDItemDateAdded" as CFString) as? Date }
        }

        return UsageEvidence(
            lastUsed: lastUsed,
            useCount: useCount,
            modified: treeModified ?? values?.contentModificationDate ?? Date.distantPast,
            created: values?.creationDate,
            accessed: values?.contentAccessDate,
            added: added,
            isRunning: isRunning,
            metadataUnavailable: unavailable)
    }
}
