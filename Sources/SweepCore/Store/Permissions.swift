import Foundation

/// Detects whether Sweep currently has Full Disk Access, without ever prompting.
///
/// macOS provides no API to query TCC status, so the only honest test is to attempt a read
/// that TCC gates and observe the result. This is a read of a system-owned file, not a write,
/// and it is why the app degrades cleanly instead of assuming access it may not have.
/// (Vault: Full Disk Access. Hands-on verification confirmed these exact denials.)
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// The probe files were absent, so nothing can be concluded either way.
        case indeterminate
    }

    /// Files readable only with Full Disk Access on a stock macOS install.
    ///
    /// More than one, because any single path can be absent on a given machine (a user who has
    /// never opened Safari has no Bookmarks.plist) and a missing file is not a denial.
    public static let probes = [
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
        NSHomeDirectory() + "/Library/Mail",
    ]

    /// Opens each probe and reads `errno`, rather than treating any failure as a denial.
    /// TCC answers a blocked read with `EPERM`/`EACCES`; `ENOENT` means the machine simply does
    /// not have that file and proves nothing; anything else is a real error the app should not
    /// dress up as a permission verdict.
    public static func status(probes: [String] = FullDiskAccess.probes) -> Status {
        var sawDenial = false
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            switch errno {
            case EPERM, EACCES: sawDenial = true
            default: continue // ENOENT and friends: no conclusion from this path.
            }
        }
        return sawDenial ? .denied : .indeterminate
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
    /// Whether a scan also runs the protection (malware) pass.
    ///
    /// Off by default and opt-in: the protection pass costs minutes on a large disk, while the
    /// cleanup scan takes seconds, so bundling it into every scan would make the ordinary case
    /// slower for a check most runs do not need. Persisted with the rest of Settings: the user
    /// should not have to re-choose this at every launch.
    public var protectionEnabled = false
    /// Access key for threat-definition feeds that require one. Optional: without it those
    /// feeds are reported as not configured rather than silently skipped, and the scanner
    /// still runs every layer that needs no network at all.
    public var threatFeedAuthKey: String?

    public init() {}

    /// Decodes leniently: every field falls back to its default when the key is absent.
    ///
    /// Swift's synthesised decoding throws on a missing key even when the property has a default
    /// value, and `load(from:)` turns any throw into a fresh `Settings()`. Without this, adding a
    /// single new setting would silently discard the user's protected paths and preferences on
    /// first launch of the new version. Verified by `SettingsTests`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        protectedPaths = try container.decodeIfPresent([String].self, forKey: .protectedPaths)
            ?? defaults.protectedPaths
        deletePermanently = try container.decodeIfPresent(Bool.self, forKey: .deletePermanently)
            ?? defaults.deletePermanently
        policy = try container.decodeIfPresent(SafetyPolicy.self, forKey: .policy) ?? defaults.policy
        showTechnicalDetail = try container.decodeIfPresent(Bool.self, forKey: .showTechnicalDetail)
            ?? defaults.showTechnicalDetail
        threatFeedAuthKey = try container.decodeIfPresent(String.self, forKey: .threatFeedAuthKey)
        protectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .protectionEnabled)
            ?? defaults.protectionEnabled
    }

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
