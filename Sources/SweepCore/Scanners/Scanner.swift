import Foundation

/// Everything a scanner is allowed to know. Scanners never reach for global state, which is
/// what makes them testable against a fixture directory tree instead of a real home folder.
public struct ScanContext: Sendable {
    public let home: String
    public let safety: SafetyEngine
    public let runningApps: RunningApps
    public let installed: InstalledApps
    public let now: Date
    public let limits: FS.WalkLimits

    public init(home: String = NSHomeDirectory(),
                safety: SafetyEngine? = nil,
                runningApps: RunningApps = .none,
                installed: InstalledApps = InstalledApps(bundleIDs: [], names: []),
                now: Date = Date(),
                limits: FS.WalkLimits = .default) {
        let h = FS.normalize(home)
        self.home = h
        self.safety = safety ?? SafetyEngine(home: h)
        self.runningApps = runningApps
        self.installed = installed
        self.now = now
        self.limits = limits
    }

    func path(_ relative: String) -> String { home + "/" + relative }
}

public protocol CleanupScanner: Sendable {
    var category: SweepCategory { get }
    /// Must never throw and never trap: a scanner that hits trouble reports it in the result.
    func scan(_ ctx: ScanContext) async -> CategoryResult
}

// MARK: - Installed application inventory

/// What is installed right now, used to decide whether a support folder is a leftover.
public struct InstalledApps: Sendable, Hashable {
    public let bundleIDs: Set<String>
    /// Lowercased app names without the `.app` extension.
    public let names: Set<String>

    public init(bundleIDs: Set<String>, names: Set<String>) {
        self.bundleIDs = bundleIDs
        self.names = names
    }

    /// Reads the standard application directories. Unreadable locations are skipped rather
    /// than treated as "nothing installed" — a false empty inventory would make every support
    /// folder look orphaned, which is the worst possible failure mode for this scanner.
    public static func scanDisk(home: String = NSHomeDirectory()) -> InstalledApps {
        var ids = Set<String>()
        var names = Set<String>()
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", home + "/Applications"]
        for root in roots {
            guard case .success(let entries) = FS.children(of: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let name = (entry as NSString).lastPathComponent
                names.insert(String(name.dropLast(4)).lowercased())
                if let id = bundleID(atAppPath: entry) { ids.insert(id) }
            }
        }
        return InstalledApps(bundleIDs: ids, names: names)
    }

    static func bundleID(atAppPath path: String) -> String? {
        let plist = path + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    /// True when a folder name looks like a reverse-DNS bundle identifier.
    public static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }
}
