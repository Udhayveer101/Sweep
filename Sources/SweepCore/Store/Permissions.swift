import Foundation

/// Detects whether Sweep currently has Full Disk Access, without ever prompting.
///
/// macOS provides no API to query TCC status, so the only honest test is to attempt a read
/// that TCC gates and observe the result. This is a read of a system-owned file, not a write,
/// and it is why the app degrades cleanly instead of assuming access it may not have.
/// (Vault: Full Disk Access — hands-on verification confirmed these exact denials.)
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// The probe files were absent, so nothing can be concluded either way.
        case indeterminate
    }

    /// Files readable only with Full Disk Access on a stock macOS install.
    public static let probes = [
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
    ]

    public static func status(probes: [String] = FullDiskAccess.probes) -> Status {
        var sawProbe = false
        for path in probes {
            guard FS.exists(path) else { continue }
            sawProbe = true
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return .granted
            }
        }
        return sawProbe ? .denied : .indeterminate
    }

    /// What the user loses without it, stated plainly rather than as a scare prompt.
    public static let explanation = """
        Sweep works without Full Disk Access, but macOS will hide some app caches and logs from \
        it, so scans will find less. Nothing else changes: Sweep still only touches files inside \
        your home folder, and still moves everything to the Trash.
        """

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

/// User-adjustable settings. Persisted as JSON next to the history log; no defaults database,
/// no iCloud sync, nothing that leaves the machine.
public struct Settings: Codable, Sendable, Equatable {
    /// User-extensible protection tier, on top of the immutable one in `SafetyEngine`.
    public var protectedPaths: [String] = []
    /// Off by default and deliberately hard to reach: Trash-first is the safety net.
    public var deletePermanently = false
    public var policy = SafetyPolicy()
    /// Opt-in only, and it never relaxes any safety rule.
    public var showTechnicalDetail = false
    /// Access key for threat-definition feeds that require one. Optional: without it those
    /// feeds are reported as not configured rather than silently skipped, and the scanner
    /// still runs every layer that needs no network at all.
    public var threatFeedAuthKey: String?

    public init() {}

    public static func load(from url: URL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder.sweep.decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder.sweep.encode(self).write(to: url, options: [.atomic])
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sweep/settings.json")
    }
}
