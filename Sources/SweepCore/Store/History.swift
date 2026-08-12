import Foundation

/// Local-only, append-only record of every cleanup run.
///
/// A history log is itself sensitive — it describes what was on the user's Mac — so it never
/// leaves the machine, and the app has no networking code of any kind.
/// (Vault: Improvement Opportunities #7, plus its stated privacy caveat.)
public actor HistoryStore {
    public let fileURL: URL
    private var cache: [CleanupReport]?

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sweep", isDirectory: true)
        self.fileURL = base.appendingPathComponent("history.json")
    }

    public func all() -> [CleanupReport] {
        if let cache { return cache }
        let loaded: [CleanupReport]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.sweep.decode([CleanupReport].self, from: data) {
            loaded = decoded
        } else {
            loaded = []
        }
        cache = loaded
        return loaded
    }

    @discardableResult
    public func record(_ report: CleanupReport) -> Bool {
        var reports = all()
        reports.insert(report, at: 0)
        // Bounded so the log cannot grow without limit on a long-lived install.
        if reports.count > 200 { reports.removeLast(reports.count - 200) }
        cache = reports
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.sweep.encode(reports)
            try data.write(to: fileURL, options: [.atomic])
            // Owner-only: the log lists paths that existed on this Mac.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    /// Case-insensitive search across item names, paths and categories.
    public func search(_ query: String) -> [ItemOutcome] {
        let q = query.lowercased()
        guard !q.isEmpty else { return all().flatMap(\.outcomes) }
        return all().flatMap(\.outcomes).filter {
            $0.displayName.lowercased().contains(q)
                || $0.path.lowercased().contains(q)
                || $0.category.title.lowercased().contains(q)
        }
    }

    public func totalBytesFreed() -> Int64 {
        all().reduce(0) { $0 + $1.verifiedBytesFreed }
    }

    public func clear() {
        cache = []
        try? FileManager.default.removeItem(at: fileURL)
    }
}

extension JSONEncoder {
    static var sweep: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var sweep: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
