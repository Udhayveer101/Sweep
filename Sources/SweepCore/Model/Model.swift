import Foundation

// MARK: - Categories

/// A user-facing grouping of cleanup findings. Each category is owned by exactly one scanner.
public enum SweepCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case userCaches
    case userLogs
    case trash
    case developerJunk
    case staleInstallers
    case appLeftovers
    case largeOldFiles
    case screenRecordings

    public var title: String {
        switch self {
        case .userCaches: "App Caches"
        case .userLogs: "Log Files"
        case .trash: "Trash"
        case .developerJunk: "Developer Junk"
        case .staleInstallers: "Old Installers"
        case .appLeftovers: "Leftovers From Removed Apps"
        case .largeOldFiles: "Large & Unopened Files"
        case .screenRecordings: "Screenshots & Screen Recordings"
        }
    }

    /// Plain-language statement of what removing items in this category does.
    /// Deliberately neutral — no urgency, no "your Mac is at risk" framing.
    /// (Vault: Improvement Opportunities #3, MacKeeper cautionary case.)
    public var consequence: String {
        switch self {
        case .userCaches:
            "Apps rebuild these automatically. The first launch after cleaning may be slightly slower."
        case .userLogs:
            "Diagnostic records of past activity. Removing them only affects troubleshooting old issues."
        case .trash:
            "Items you already moved to the Trash. Emptying it is permanent."
        case .developerJunk:
            "Build products and dependency caches. Tools re-download or rebuild them on the next build."
        case .staleInstallers:
            "Installer files kept after the software was installed. The installed app is unaffected."
        case .appLeftovers:
            "Support files whose owning app is no longer installed. Reinstalling the app recreates them."
        case .largeOldFiles:
            "Your own files. Nothing here is selected for you — review each one."
        case .screenRecordings:
            "Screenshots and screen recordings you captured. They are not backed up anywhere by Sweep."
        }
    }
}

// MARK: - Risk

/// Safety classification assigned by `SafetyEngine`. The pipeline never deletes anything
/// that is not `.safe`, and never auto-selects anything that is not `.safe`.
/// (Vault: Safety Architecture 3-tier model.)
public enum Risk: String, Codable, Sendable, Comparable {
    /// Well-understood, regenerable, and clear of every protection rule. Eligible for auto-selection.
    case safe
    /// Removable but consequential or ambiguous. Shown, never auto-selected.
    case review
    /// Not classifiable with confidence. Shown, never auto-selected, never auto-deleted.
    case unknown
    /// Refused outright. Never offered for deletion.
    case protected

    private var order: Int {
        switch self { case .safe: 0; case .review: 1; case .unknown: 2; case .protected: 3 }
    }
    public static func < (a: Risk, b: Risk) -> Bool { a.order < b.order }
}

/// Why the safety engine reached its verdict. Surfaced verbatim in the UI so the
/// classification is never a black box. (Vault: Cleanup System Pipeline, disclosure opportunity.)
public struct Rationale: Codable, Sendable, Hashable {
    public let rule: String
    public let detail: String
    public init(rule: String, detail: String) {
        self.rule = rule
        self.detail = detail
    }
}

// MARK: - Items

/// One discovered cleanup candidate, plus everything needed to re-validate it at delete time.
public struct Item: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let category: SweepCategory
    /// Fully resolved, symlink-free path. Always absolute.
    public let path: String
    public let displayName: String
    public let bytes: Int64
    /// Newest modification date anywhere in the item (a directory reports its newest descendant).
    public let modified: Date
    /// Number of files the item covers (1 for a plain file).
    public let fileCount: Int
    public let risk: Risk
    public let rationale: [Rationale]
    /// True when the recommendation engine pre-selected this for the user.
    public let autoSelected: Bool
    /// Bundle identifier this item was attributed to, when attribution succeeded.
    public let owningBundleID: String?
    /// How confidently the item was attributed to an app. Nil when attribution does not apply.
    public let attribution: Attribution?

    public init(
        id: UUID = UUID(),
        category: SweepCategory,
        path: String,
        displayName: String,
        bytes: Int64,
        modified: Date,
        fileCount: Int = 1,
        risk: Risk,
        rationale: [Rationale],
        autoSelected: Bool = false,
        owningBundleID: String? = nil,
        attribution: Attribution? = nil
    ) {
        self.id = id
        self.category = category
        self.path = path
        self.displayName = displayName
        self.bytes = bytes
        self.modified = modified
        self.fileCount = fileCount
        self.risk = risk
        self.rationale = rationale
        self.autoSelected = autoSelected
        self.owningBundleID = owningBundleID
        self.attribution = attribution
    }

    public func with(risk: Risk, rationale: [Rationale], autoSelected: Bool) -> Item {
        Item(id: id, category: category, path: path, displayName: displayName, bytes: bytes,
             modified: modified, fileCount: fileCount, risk: risk, rationale: rationale,
             autoSelected: autoSelected, owningBundleID: owningBundleID, attribution: attribution)
    }
}

/// Confidence tier for associating a file with an application.
/// Disclosed to the user rather than hidden. (Vault: Architecture Proposal decision #4.)
public enum Attribution: String, Codable, Sendable, Comparable {
    /// Directory name is an exact bundle identifier of an app that exists (or existed) on this Mac.
    case exactBundleID
    /// Path sits under a documented per-app convention (Containers, Application Support/<name>).
    case pathConvention
    /// Name resemblance only. Lowest confidence — never sufficient for auto-selection on its own.
    case nameHeuristic

    private var order: Int {
        switch self { case .exactBundleID: 0; case .pathConvention: 1; case .nameHeuristic: 2 }
    }
    public static func < (a: Attribution, b: Attribution) -> Bool { a.order < b.order }
}

// MARK: - Scan results

public struct CategoryResult: Sendable, Identifiable {
    public var id: SweepCategory { category }
    public let category: SweepCategory
    public var items: [Item]
    /// Locations skipped and why — permission denials, vanished paths, unreadable directories.
    public var skipped: [SkipRecord]
    public var failure: ScanFailure?

    public init(category: SweepCategory, items: [Item] = [], skipped: [SkipRecord] = [], failure: ScanFailure? = nil) {
        self.category = category
        self.items = items
        self.skipped = skipped
        self.failure = failure
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var selectedBytes: Int64 { items.filter(\.autoSelected).reduce(0) { $0 + $1.bytes } }
}

public struct SkipRecord: Sendable, Codable, Hashable, Error {
    public enum Reason: String, Codable, Sendable {
        case permissionDenied
        case vanished
        case unreadable
        case notPermittedNeedsFullDiskAccess
        case crossedVolume
        case symlink
        case depthLimit
        case budgetExceeded
    }
    public let path: String
    public let reason: Reason
    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }
}

/// A scanner failing is isolated: the orchestrator records it and keeps the other results.
public struct ScanFailure: Sendable, Codable, Hashable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public struct ScanReport: Sendable {
    public var categories: [CategoryResult]
    public let started: Date
    public let finished: Date
    public let cancelled: Bool
    /// True when at least one location was refused for lack of Full Disk Access.
    public let limitedByPermissions: Bool

    public init(categories: [CategoryResult], started: Date, finished: Date, cancelled: Bool, limitedByPermissions: Bool) {
        self.categories = categories
        self.started = started
        self.finished = finished
        self.cancelled = cancelled
        self.limitedByPermissions = limitedByPermissions
    }

    public var allItems: [Item] { categories.flatMap(\.items) }
    public var totalBytes: Int64 { categories.reduce(0) { $0 + $1.totalBytes } }
    public var recommendedBytes: Int64 { categories.reduce(0) { $0 + $1.selectedBytes } }
    public var partial: Bool { cancelled || categories.contains { $0.failure != nil } }
}

// MARK: - Cleanup results

public struct ItemOutcome: Sendable, Codable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case trashed
        case deleted
        /// Refused at delete time because re-validation failed. Always carries a reason.
        case skipped
        case failed
    }
    public var id: String { path }
    public let path: String
    public let displayName: String
    public let category: SweepCategory
    public let bytes: Int64
    public let status: Status
    /// Human-readable reason. Required for `.skipped` and `.failed`.
    /// (Vault: Improvement Opportunities #5 — report skipped/failed with a specific reason.)
    public let reason: String?
    /// Where the item now lives in the Trash, when recoverable.
    public let trashPath: String?

    public init(path: String, displayName: String, category: SweepCategory, bytes: Int64,
                status: Status, reason: String? = nil, trashPath: String? = nil) {
        self.path = path
        self.displayName = displayName
        self.category = category
        self.bytes = bytes
        self.status = status
        self.reason = reason
        self.trashPath = trashPath
    }
}

public struct CleanupReport: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let started: Date
    public let finished: Date
    public var outcomes: [ItemOutcome]
    /// Bytes confirmed gone by the verification pass — not the bytes we hoped to free.
    public var verifiedBytesFreed: Int64
    public let cancelled: Bool

    public init(id: UUID = UUID(), started: Date, finished: Date, outcomes: [ItemOutcome],
                verifiedBytesFreed: Int64, cancelled: Bool) {
        self.id = id
        self.started = started
        self.finished = finished
        self.outcomes = outcomes
        self.verifiedBytesFreed = verifiedBytesFreed
        self.cancelled = cancelled
    }

    public var succeeded: [ItemOutcome] { outcomes.filter { $0.status == .trashed || $0.status == .deleted } }
    public var problems: [ItemOutcome] { outcomes.filter { $0.status == .skipped || $0.status == .failed } }
    public var recoverable: Bool { succeeded.contains { $0.trashPath != nil } }
}

// MARK: - Progress

public enum ScanEvent: Sendable {
    case started(SweepCategory)
    case progress(SweepCategory, scannedPaths: Int)
    case finished(CategoryResult)
}

public enum CleanupEvent: Sendable {
    case progress(completed: Int, total: Int, current: String)
    case finished(CleanupReport)
}
