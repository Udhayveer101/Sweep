import Foundation

/// Snapshot of what is currently running, supplied by the app layer (AppKit) so that
/// `SweepCore` stays Foundation-only and fully testable without a GUI session.
public struct RunningApps: Sendable, Hashable {
    public var bundleIDs: Set<String>
    /// Resolved bundle paths, e.g. `/Applications/Xcode.app`.
    public var bundlePaths: Set<String>
    public init(bundleIDs: Set<String> = [], bundlePaths: Set<String> = []) {
        self.bundleIDs = bundleIDs
        self.bundlePaths = bundlePaths
    }
    public static let none = RunningApps()
}

/// Tunable thresholds. Every value here is an age-in-days used as the auto-selection proxy.
///
/// Age-as-safety-proxy is the one heuristic the research found holding consistently across
/// every mature product in this space; it is used only to decide *pre-selection*, never to
/// decide whether something may be deleted at all. (Vault: Safety Architecture.)
public struct SafetyPolicy: Sendable, Hashable, Codable {
    public var cacheAgeDays: Int = 30
    public var logAgeDays: Int = 14
    public var developerJunkAgeDays: Int = 7
    public var installerAgeDays: Int = 30
    public var leftoverAgeDays: Int = 30
    public var trashAgeDays: Int = 30
    /// Items below this size are still reported but never pre-selected — the risk/reward is poor.
    public var minimumAutoSelectBytes: Int64 = 1_000_000
    /// User-extensible protection tier. Anything at or under these paths is refused outright.
    /// (Vault: Architecture Proposal decision #3 — two-tier ignore list.)
    public var userProtectedPaths: Set<String> = []

    public init() {}
}

/// Decides what may be deleted, and separately, what may be pre-selected for the user.
///
/// Two hard guarantees this type is responsible for:
///  1. Nothing outside the user's home directory is ever eligible. Sweep performs no
///     privileged operations at all, so system locations are out of scope by construction.
///  2. A path is only eligible if it is symlink-free, on the home volume, and clear of every
///     protection rule — re-checked immediately before deletion, not just at scan time.
public struct SafetyEngine: Sendable {
    public let home: String
    public let policy: SafetyPolicy
    private let homeVolumeID: String?

    public init(home: String = NSHomeDirectory(), policy: SafetyPolicy = SafetyPolicy()) {
        self.home = FS.normalize(home)
        self.policy = policy
        self.homeVolumeID = FS.volumeIdentifier(of: self.home)
    }

    // MARK: - Immutable protection tier

    /// Paths, relative to home, that Sweep refuses to touch under any circumstance.
    /// Redundant with macOS protections in places; kept as defence in depth.
    static let protectedRelativePaths: [String] = [
        "Library/Keychains",
        "Library/Mobile Documents",          // iCloud Drive
        "Library/Application Support/MobileSync", // iOS device backups
        "Library/Messages",
        "Library/Mail",
        "Library/Safari",
        "Library/Cookies",
        "Library/Calendars",
        "Library/Accounts",
        "Library/IdentityServices",
        "Library/Preferences",               // out of scope for every Sweep category
        "Library/Group Containers",
        ".ssh",
        ".gnupg",
        ".aws",
        ".kube",
        ".docker/config.json",
        "Applications",                      // Sweep does not uninstall apps
    ]

    /// Directory names that mark a user-authored document store wherever they appear.
    static let protectedComponents: Set<String> = [
        "Photos Library.photoslibrary",
        "Keychains",
        ".Trashes",
    ]

    // MARK: - Eligibility (the hard gate)

    public enum Refusal: String, Sendable, Error {
        case outsideHome = "Outside your home folder — Sweep only ever touches files you own."
        case protectedLocation = "In a protected location."
        case userProtected = "You added this path to Sweep's protected list."
        case containsSymlink = "Path contains a symbolic link."
        case differentVolume = "On a different volume than your home folder."
        case isHomeRoot = "This is your home folder itself."
        case inUse = "In use by a running application."
        case notFound = "No longer exists."
        case changed = "Changed since it was scanned."
    }

    /// The single authority on "may this path be deleted at all". Called at scan time *and*
    /// again immediately before every deletion.
    public func eligibility(of rawPath: String, runningApps: RunningApps = .none) -> Refusal? {
        // Check for symlinks on the *lexical* path first. `FS.normalize` resolves symlinks away,
        // which would silently turn "a link inside my home" into whatever it points at — and a
        // link pointing back inside the home folder would then look perfectly ordinary.
        let lexical = FS.lexical(rawPath)
        if lexical != home, FS.isDescendant(lexical, of: home), FS.containsSymlink(lexical, upTo: home) {
            return .containsSymlink
        }

        let path = FS.normalize(rawPath)

        guard path != home else { return .isHomeRoot }
        guard FS.isDescendant(path, of: home) else { return .outsideHome }

        for p in policy.userProtectedPaths {
            let n = FS.normalize(p)
            if path == n || FS.isDescendant(path, of: n) { return .userProtected }
        }

        let relative = String(path.dropFirst(home.count + 1))
        for protected in Self.protectedRelativePaths {
            if relative == protected || relative.hasPrefix(protected + "/") { return .protectedLocation }
        }
        for component in relative.split(separator: "/") {
            if Self.protectedComponents.contains(String(component)) { return .protectedLocation }
        }

        // Reject if any component of the path is a symlink. `FS.normalize` resolves symlinks, so a
        // path that survives normalization unchanged relative to its lexical form has none — but we
        // check explicitly because the caller may hand us an unnormalized path.
        if FS.containsSymlink(path, upTo: home) { return .containsSymlink }

        // A traversal that crossed onto another volume (external disk, network mount, APFS
        // sibling) must not be deleted through the home-scope assumption.
        if let homeVolumeID, let v = FS.volumeIdentifier(of: path), v != homeVolumeID {
            return .differentVolume
        }

        if let refusal = runningAppRefusal(path: path, runningApps: runningApps) { return refusal }

        return nil
    }

    private func runningAppRefusal(path: String, runningApps: RunningApps) -> Refusal? {
        guard !runningApps.bundleIDs.isEmpty else { return nil }
        // A cache/support directory named after a running app's bundle ID is live data.
        let last = (path as NSString).lastPathComponent
        if runningApps.bundleIDs.contains(last) { return .inUse }
        for component in path.split(separator: "/") where runningApps.bundleIDs.contains(String(component)) {
            return .inUse
        }
        return nil
    }

    // MARK: - Classification

    /// The outcome of classification: a consequence tier, an evidence-quality tier, and the
    /// full reasoning behind both.
    public struct Verdict: Sendable {
        public let risk: Risk
        public let confidence: Confidence
        public let rationale: [Rationale]
    }

    /// Assigns a risk tier, a confidence tier, and the reasoning behind them. `.protected` items
    /// are dropped by the scanners before they ever reach the UI.
    ///
    /// Two rules govern everything here and are enforced at the end regardless of category:
    ///  * `.safe` requires at least `.medium` confidence. Weak evidence can never produce a
    ///    pre-selected deletion.
    ///  * An item whose owning application is running is never `.safe`.
    public func classify(
        path: String,
        category: SweepCategory,
        evidence: UsageEvidence,
        bytes: Int64,
        attribution: Attribution?,
        now: Date = Date(),
        runningApps: RunningApps = .none
    ) -> Verdict {
        if let refusal = eligibility(of: path, runningApps: runningApps) {
            return Verdict(risk: .protected, confidence: .high,
                           rationale: [Rationale(rule: "Protected", detail: refusal.rawValue)])
        }

        let confidence = evidence.confidence(for: category)
        var rationale = evidence.statements(now: now, category: category)
        let threshold = ageThreshold(for: category)
        let ageDays = evidence.daysSinceModified(now: now)

        func verdict(_ risk: Risk, _ rule: String, _ detail: String) -> Verdict {
            rationale.insert(Rationale(rule: rule, detail: detail), at: 0)
            // The two invariants, applied centrally so no category can forget them.
            var final = risk
            if final == .safe && confidence < .medium {
                rationale.append(Rationale(
                    rule: "Not enough evidence",
                    detail: "Sweep could not establish this well enough to select it for you."))
                final = .review
            }
            if final == .safe && evidence.isRunning {
                rationale.append(Rationale(
                    rule: "Active",
                    detail: "The owning application is running, so this is left for you to decide."))
                final = .review
            }
            return Verdict(risk: final, confidence: confidence, rationale: rationale)
        }

        switch category {
        case .largeOldFiles, .screenRecordings:
            // User-authored content. No timestamp makes this Sweep's decision.
            return verdict(.review, "Your own file",
                           "Sweep found this but will never select it for you. Age says nothing about whether you still want it.")

        case .appLeftovers:
            guard let attribution else {
                return verdict(.unknown, "Unattributed",
                               "Could not determine which app this belonged to, so Sweep will not act on it.")
            }
            rationale.insert(Rationale(rule: "Attribution", detail: attributionDetail(attribution)), at: 0)
            if attribution == .nameHeuristic {
                return verdict(.review, "Weak match",
                               "Matched by folder name only. That is too weak to select a deletion for you.")
            }
            if ageDays < threshold {
                return verdict(.review, "Recently written",
                               "Something wrote to this \(ageDays) day(s) ago, which is unexpected for an app that is gone.")
            }
            return verdict(.safe, "Owner absent",
                           "The app that created this is not installed, and nothing has written to it in \(ageDays) days.")

        case .trash:
            if let days = evidence.daysSinceLastUse(now: now), days < threshold {
                return verdict(.review, "Opened recently",
                               "You opened this \(days) day(s) ago even though it is in the Trash.")
            }
            if ageDays < threshold {
                return verdict(.review, "Recently trashed",
                               "Trashed about \(ageDays) day(s) ago. Recent enough that Sweep leaves the choice to you.")
            }
            return verdict(.safe, "Already discarded",
                           "You moved this to the Trash over \(threshold) days ago. Emptying it cannot be undone.")

        case .staleInstallers:
            if let days = evidence.daysSinceLastUse(now: now), days < threshold {
                return verdict(.review, "Opened recently",
                               "You opened this installer \(days) day(s) ago, so it may still be in use.")
            }
            if ageDays < threshold {
                return verdict(.review, "Recent", "Downloaded or changed \(ageDays) day(s) ago.")
            }
            if bytes < policy.minimumAutoSelectBytes {
                return verdict(.review, "Small",
                               "Under \(Format.bytes(policy.minimumAutoSelectBytes)) — not worth pre-selecting.")
            }
            return verdict(.safe, "Installer already used",
                           "No record of it being opened, and it has not changed in \(ageDays) days. The installed app is unaffected.")

        case .userCaches, .userLogs, .developerJunk:
            if let attribution {
                rationale.insert(Rationale(rule: "Attribution", detail: attributionDetail(attribution)), at: 0)
            }
            if ageDays < threshold {
                return verdict(.review, "In active use",
                               "Written to \(ageDays) day(s) ago, under the \(threshold)-day threshold.")
            }
            if bytes < policy.minimumAutoSelectBytes {
                return verdict(.review, "Small",
                               "Under \(Format.bytes(policy.minimumAutoSelectBytes)) — not worth pre-selecting.")
            }
            return verdict(.safe, "Regenerable",
                           "\(category.consequence) Nothing has written to it in \(ageDays) days.")
        }
    }

    func ageThreshold(for category: SweepCategory) -> Int {
        switch category {
        case .userCaches: policy.cacheAgeDays
        case .userLogs: policy.logAgeDays
        case .developerJunk: policy.developerJunkAgeDays
        case .staleInstallers: policy.installerAgeDays
        case .appLeftovers: policy.leftoverAgeDays
        case .trash: policy.trashAgeDays
        case .largeOldFiles, .screenRecordings: Int.max
        }
    }

    private func attributionDetail(_ a: Attribution) -> String {
        switch a {
        case .exactBundleID: "Matched to an app by exact bundle identifier — the strongest signal Sweep uses."
        case .pathConvention: "Matched by Apple's documented per-app folder layout."
        case .nameHeuristic: "Matched by folder name resemblance only — the weakest signal Sweep uses."
        }
    }
}
