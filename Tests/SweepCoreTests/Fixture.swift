import Foundation
@testable import SweepCore

/// A throwaway directory tree that stands in for a home folder. Every destructive test runs
/// against one of these: never against the machine's real home.
final class Fixture {
    let root: String

    init(_ label: String = "sweep") {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve immediately: /var is a symlink to /private/var, and an unresolved root would
        // make every path in the fixture look like it contains a symlink.
        root = FS.normalize(base.path)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    func dir(_ relative: String) -> String {
        let p = root + "/" + relative
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 2_000_000, age: TimeInterval = 0) -> String {
        let p = root + "/" + relative
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(count: bytes))
        if age > 0 { touch(p, age: age) }
        return p
    }

    /// Ages an entire subtree. Directory modification dates count as activity signals, so a
    /// realistically "old" tree needs its intermediate directories aged too.
    func ageTree(_ relative: String, age: TimeInterval) {
        let root = self.root + "/" + relative
        guard let e = FileManager.default.enumerator(atPath: root) else { return }
        var paths = [root]
        while let sub = e.nextObject() as? String { paths.append(root + "/" + sub) }
        for p in paths.sorted(by: { $0.count > $1.count }) { touch(p, age: age) }
    }

    func touch(_ path: String, age: TimeInterval) {
        let date = Date().addingTimeInterval(-age)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    @discardableResult
    func symlink(_ relative: String, to target: String) -> String {
        let p = root + "/" + relative
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: p, withDestinationPath: target)
        return p
    }

    var engine: SafetyEngine { SafetyEngine(home: root) }

    func context(now: Date = Date(),
                 installed: InstalledApps = InstalledApps(bundleIDs: ["com.example.keep"], names: ["keep"]),
                 running: RunningApps = .none,
                 policy: SafetyPolicy = SafetyPolicy()) -> ScanContext {
        ScanContext(home: root, safety: SafetyEngine(home: root, policy: policy),
                    runningApps: running, installed: installed, now: now)
    }
}

let days: TimeInterval = 86_400
