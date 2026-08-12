import Foundation

/// Runs the scanners concurrently, isolates their failures, and streams progress.
///
/// Concurrency is capped rather than unbounded: these scanners are disk-bound, and running
/// eight full-tree walks at once makes the whole scan slower, not faster. The cap is also what
/// keeps memory flat on a large home folder.
public actor ScanOrchestrator {
    public enum State: Sendable, Equatable {
        case idle
        case scanning
    }

    private var state: State = .idle
    private let maxConcurrent: Int
    private let scanners: [any CleanupScanner]

    public init(scanners: [any CleanupScanner] = defaultScanners, maxConcurrent: Int = 4) {
        self.scanners = scanners
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public var isScanning: Bool { state == .scanning }

    public struct AlreadyScanning: Error, Sendable {
        public let message = "A scan is already running."
    }

    /// Single-scan-in-flight lock: two concurrent scans would race on the same paths and
    /// double-report the same bytes.
    public func scan(context: ScanContext,
                     onEvent: @Sendable @escaping (ScanEvent) -> Void = { _ in }) async throws -> ScanReport {
        guard state == .idle else { throw AlreadyScanning() }
        state = .scanning
        defer { state = .idle }

        let started = Date()
        var results: [SweepCategory: CategoryResult] = [:]
        let scanners = self.scanners
        let limit = maxConcurrent

        await withTaskGroup(of: CategoryResult.self) { group in
            var next = 0
            func addTask(_ scanner: any CleanupScanner) {
                group.addTask {
                    onEvent(.started(scanner.category))
                    let result = await scanner.scan(context)
                    onEvent(.finished(result))
                    return result
                }
            }
            while next < scanners.count && next < limit {
                addTask(scanners[next]); next += 1
            }
            while let result = await group.next() {
                results[result.category] = result
                if next < scanners.count {
                    addTask(scanners[next]); next += 1
                }
            }
        }

        let cancelled = Task.isCancelled
        let ordered = Self.deduplicate(scanners.compactMap { results[$0.category] })
        let recommended = RecommendationEngine().apply(to: ordered)
        let limited = recommended.contains { r in
            !r.unreadableRoots.isEmpty
                || r.skipped.contains { $0.reason == .permissionDenied || $0.reason == .notPermittedNeedsFullDiskAccess }
        }
        return ScanReport(categories: recommended, started: started, finished: Date(),
                          cancelled: cancelled, limitedByPermissions: limited)
    }

    /// Guarantees no path — nor any path nested inside another reported path — is offered twice.
    ///
    /// Two scanners claiming the same bytes would inflate the totals and, worse, queue the same
    /// item for deletion twice, so the second attempt would fail with a confusing "already gone".
    /// Scanner declaration order decides the winner.
    static func deduplicate(_ categories: [CategoryResult]) -> [CategoryResult] {
        var claimed: [String] = []
        return categories.map { category in
            var c = category
            c.items = c.items.filter { item in
                if claimed.contains(where: { item.path == $0 || FS.isDescendant(item.path, of: $0) }) {
                    return false
                }
                claimed.append(item.path)
                return true
            }
            return c
        }
    }
}

/// Decides what arrives pre-selected. The only rule is: `.safe` and nothing else.
///
/// Deliberately free of any urgency or persuasion logic. Findings are reported as found;
/// the engine never inflates a total or nudges toward a larger selection.
/// (Vault: Improvement Opportunities #3.)
public struct RecommendationEngine: Sendable {
    public init() {}

    public func apply(to categories: [CategoryResult]) -> [CategoryResult] {
        categories.map { category in
            var c = category
            c.items = c.items.map { item in
                item.with(risk: item.risk, rationale: item.rationale, autoSelected: item.risk == .safe)
            }
            c.items.sort { $0.risk == $1.risk ? $0.bytes > $1.bytes : $0.risk < $1.risk }
            return c
        }
    }

    /// Neutral, factual one-liner for a category. No exclamation marks, no "your Mac is slow".
    ///
    /// Distinguishes "looked and found nothing" from "could not look", because conflating them
    /// tells the user their Trash is empty when macOS is simply refusing Sweep access to it.
    public func summary(for category: CategoryResult) -> String {
        let selected = category.items.filter(\.autoSelected)
        if category.wasBlocked && category.items.isEmpty { return "Could not be read — needs permission." }
        if category.items.isEmpty { return "Nothing found." }
        if selected.isEmpty {
            return "\(category.items.count) item(s), \(Format.bytes(category.totalBytes)). None selected — review them yourself."
        }
        return "\(selected.count) of \(category.items.count) item(s) selected, \(Format.bytes(category.selectedBytes)) of \(Format.bytes(category.totalBytes))."
    }
}
