import Foundation

// MARK: - Shared item construction

extension ScanContext {
    /// Measures a candidate path and runs it through the safety engine.
    /// Returns nil when the path vanished or the safety engine refuses it outright.
    func makeItem(path: String,
                  category: SweepCategory,
                  displayName: String? = nil,
                  attribution: Attribution? = nil,
                  into skipped: inout [SkipRecord]) -> Item? {
        guard FS.exists(path) else {
            skipped.append(SkipRecord(path: path, reason: .vanished))
            return nil
        }
        if FS.isSymlink(path) {
            skipped.append(SkipRecord(path: path, reason: .symlink))
            return nil
        }
        let agg = FS.aggregate(path, limits: limits)
        skipped.append(contentsOf: agg.skipped)
        guard agg.bytes > 0 else { return nil }

        let (risk, rationale) = safety.classify(
            path: path, category: category,
            modified: agg.newestModification, bytes: agg.bytes,
            attribution: attribution, now: now, runningApps: runningApps)
        guard risk != .protected else { return nil }

        return Item(category: category,
                    path: path,
                    displayName: displayName ?? (path as NSString).lastPathComponent,
                    bytes: agg.bytes,
                    modified: agg.newestModification,
                    fileCount: max(agg.fileCount, 1),
                    risk: risk,
                    rationale: rationale,
                    autoSelected: false,
                    owningBundleID: attribution == .exactBundleID ? (path as NSString).lastPathComponent : nil,
                    attribution: attribution)
    }
}

/// Names under `~/Library/Caches` owned by the developer-junk scanner, so the two scanners
/// never both report the same bytes.
let developerOwnedCacheNames: Set<String> = [
    "CocoaPods", "org.swift.swiftpm", "Homebrew", "com.apple.dt.Xcode", "node-gyp", "Yarn", "pip",
]

// MARK: - Caches

public struct CacheScanner: CleanupScanner {
    public let category = SweepCategory.userCaches
    public init() {}

    public func scan(_ ctx: ScanContext) async -> CategoryResult {
        var result = CategoryResult(category: category)
        let root = ctx.path("Library/Caches")
        switch FS.children(of: root) {
        case .failure(let skip):
            result.skipped.append(skip)
            return result
        case .success(let entries):
            for entry in entries {
                if Task.isCancelled { return result }
                let name = (entry as NSString).lastPathComponent
                if developerOwnedCacheNames.contains(name) { continue }
                let attribution: Attribution? =
                    InstalledApps.looksLikeBundleID(name) ? .exactBundleID :
                    (ctx.installed.names.contains(name.lowercased()) ? .pathConvention : .nameHeuristic)
                if let item = ctx.makeItem(path: entry, category: category,
                                           attribution: attribution, into: &result.skipped) {
                    result.items.append(item)
                }
            }
        }
        return result
    }
}

// MARK: - Logs

public struct LogScanner: CleanupScanner {
    public let category = SweepCategory.userLogs
    public init() {}

    public func scan(_ ctx: ScanContext) async -> CategoryResult {
        var result = CategoryResult(category: category)
        let root = ctx.path("Library/Logs")
        switch FS.children(of: root) {
        case .failure(let skip):
            result.skipped.append(skip)
        case .success(let entries):
            for entry in entries {
                if Task.isCancelled { return result }
                let name = (entry as NSString).lastPathComponent
                let attribution: Attribution? = InstalledApps.looksLikeBundleID(name) ? .exactBundleID : .pathConvention
                if let item = ctx.makeItem(path: entry, category: category,
                                           attribution: attribution, into: &result.skipped) {
                    result.items.append(item)
                }
            }
        }
        return result
    }
}

// MARK: - Trash

public struct TrashScanner: CleanupScanner {
    public let category = SweepCategory.trash
    public init() {}

    public func scan(_ ctx: ScanContext) async -> CategoryResult {
        var result = CategoryResult(category: category)
        switch FS.children(of: ctx.path(".Trash")) {
        case .failure(let skip):
            result.skipped.append(skip)
        case .success(let entries):
            for entry in entries {
                if Task.isCancelled { return result }
                if let item = ctx.makeItem(path: entry, category: category, into: &result.skipped) {
                    result.items.append(item)
                }
            }
        }
        return result
    }
}

// MARK: - Developer junk

public struct DeveloperJunkScanner: CleanupScanner {
    public let category = SweepCategory.developerJunk
    public init() {}

    /// Locations whose contents are, by the tool vendor's own design, reproducible.
    /// `expandChildren` reports each child separately so a user can keep one project's
    /// derived data while clearing another's.
    static let locations: [(relative: String, label: String, expandChildren: Bool)] = [
        ("Library/Developer/Xcode/DerivedData", "Xcode derived data", true),
        ("Library/Developer/CoreSimulator/Caches", "Simulator caches", false),
        ("Library/Caches/CocoaPods", "CocoaPods cache", false),
        ("Library/Caches/org.swift.swiftpm", "Swift Package Manager cache", false),
        ("Library/Caches/Homebrew", "Homebrew download cache", false),
        (".npm/_cacache", "npm cache", false),
        (".gradle/caches", "Gradle cache", false),
        (".cargo/registry/cache", "Cargo registry cache", false),
        (".cache/pip", "pip cache", false),
        (".pub-cache/hosted", "Dart/Flutter package cache", false),
        (".yarn/cache", "Yarn cache", false),
    ]

    public func scan(_ ctx: ScanContext) async -> CategoryResult {
        var result = CategoryResult(category: category)
        for loc in Self.locations {
            if Task.isCancelled { return result }
            let root = ctx.path(loc.relative)
            guard FS.exists(root) else { continue }
            if loc.expandChildren, case .success(let entries) = FS.children(of: root) {
                for entry in entries {
                    let name = (entry as NSString).lastPathComponent
                    if let item = ctx.makeItem(path: entry, category: category,
                                               displayName: "\(loc.label) — \(name)",
                                               attribution: .pathConvention, into: &result.skipped) {
                        result.items.append(item)
                    }
                }
            } else if let item = ctx.makeItem(path: root, category: category,
                                              displayName: loc.label,
                                              attribution: .pathConvention, into: &result.skipped) {
                result.items.append(item)
            }
        }
        return result
    }
}

// MARK: - Stale installers

public struct InstallerScanner: CleanupScanner {
    public let category = SweepCategory.staleInstallers
    public init() {}

    static let extensions: Set<String> = ["dmg", "pkg", "mpkg"]

    public func scan(_ ctx: ScanContext) async -> CategoryResult {
        var result = CategoryResult(category: category)
        for folder in ["Downloads", "Desktop"] {
            switch FS.children(of: ctx.path(folder)) {
            case .failure(let skip):
                result.skipped.append(skip)
            case .success(let entries):
                for entry in entries {
                    if Task.isCancelled { return result }
                    guard Self.extensions.contains((entry as NSString).pathExtension.lowercased()) else { continue }
                    if let item = ctx.makeItem(path: entry, category: category, into: &result.skipped) {
                        result.items.append(item)
                    }
                }
            }
        }
        return result
    }
}

// MARK: - Leftovers from removed apps

/// Finds support data whose owning application is no longer installed.
///
/// Matching is deliberately tiered and disclosed rather than a single opaque score:
/// an exact bundle identifier is trusted, a documented folder convention is trusted less,
/// and a bare name resemblance is reported but never pre-selected.
/// (Vault: Architecture Proposal decision #4; Nektony/PureMac as reference points.)
public struct LeftoverScanner: CleanupScanner {
    public let category = SweepCategory.appLeftovers
    public init() {}

    /// `Library/Caches` is deliberately absent: `CacheScanner` already owns it, and claiming it
    /// here would report the same bytes in two categories and queue the same path for deletion
    /// twice.
    static let roots = ["Library/Application Support", "Library/Containers", "Library/Saved Application State"]

    /// Vendor prefixes that belong to the OS itself or to frameworks with no user-visible app.
    /// Reporting these as "leftovers" would be a false positive with real consequences.
    static let systemPrefixes = ["com.apple.", "com.microsoft.autoupdate", "CrashReporter", "MobileSync"]

    public func scan(_ ctx: ScanContext) async -> CategoryResult {
        var result = CategoryResult(category: category)
        // An empty inventory means we could not read the Applications folders. Reporting every
        // support folder as orphaned in that case would be dangerously wrong, so bail out loudly.
        guard !ctx.installed.bundleIDs.isEmpty || !ctx.installed.names.isEmpty else {
            result.failure = ScanFailure("Could not read the Applications folders, so Sweep cannot tell which apps are still installed. Leftover detection was skipped.")
            return result
        }

        for root in Self.roots {
            if Task.isCancelled { return result }
            let base = ctx.path(root)
            guard case .success(let entries) = FS.children(of: base) else {
                if case .failure(let skip) = FS.children(of: base) { result.skipped.append(skip) }
                continue
            }
            for entry in entries {
                if Task.isCancelled { return result }
                let name = (entry as NSString).lastPathComponent
                guard !Self.systemPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                guard let attribution = orphanAttribution(name: name, installed: ctx.installed) else { continue }
                if let item = ctx.makeItem(path: entry, category: category,
                                           displayName: name, attribution: attribution,
                                           into: &result.skipped) {
                    result.items.append(item)
                }
            }
        }
        return result
    }

    /// Nil when the folder is *not* an orphan (its app is installed, or we cannot tell).
    func orphanAttribution(name: String, installed: InstalledApps) -> Attribution? {
        if InstalledApps.looksLikeBundleID(name) {
            if installed.bundleIDs.contains(name) { return nil }
            // A bundle ID whose app is absent is the strongest orphan signal available.
            let lastComponent = name.split(separator: ".").last.map(String.init)?.lowercased()
            if let lastComponent, installed.names.contains(lastComponent) { return nil }
            return .exactBundleID
        }
        let lowered = name.lowercased()
        if installed.names.contains(lowered) { return nil }
        // Folder named after an installed app with decoration, e.g. "Foo Helper" for "Foo".
        if installed.names.contains(where: { lowered.hasPrefix($0) || $0.hasPrefix(lowered) }) { return nil }
        return .nameHeuristic
    }
}

// MARK: - Large & unopened files

public struct LargeFileScanner: CleanupScanner {
    public let category = SweepCategory.largeOldFiles
    public init() {}

    public var minimumBytes: Int64 = 200_000_000
    public var unopenedDays: Int = 180

    public init(minimumBytes: Int64 = 200_000_000, unopenedDays: Int = 180) {
        self.minimumBytes = minimumBytes
        self.unopenedDays = unopenedDays
    }

    /// Deliberately excludes ~/Music and ~/Pictures: their contents are managed by Music and
    /// Photos, walking them makes macOS prompt for media-library access Sweep has no need for,
    /// and library bundles are protected by the safety engine anyway. Asking for a permission
    /// the feature does not require is exactly the least-privilege failure to avoid.
    static let searchRoots = ["Downloads", "Desktop", "Documents", "Movies"]

    public func scan(_ ctx: ScanContext) async -> CategoryResult {
        var result = CategoryResult(category: category)
        let cutoff = ctx.now.addingTimeInterval(-Double(unopenedDays) * 86_400)
        for root in Self.searchRoots {
            if Task.isCancelled { return result }
            let base = ctx.path(root)
            guard FS.exists(base) else { continue }
            walk(base, depth: 0, cutoff: cutoff, ctx: ctx, into: &result)
        }
        result.items.sort { $0.bytes > $1.bytes }
        return result
    }

    private func walk(_ dir: String, depth: Int, cutoff: Date, ctx: ScanContext, into result: inout CategoryResult) {
        guard depth < ctx.limits.maxDepth, !Task.isCancelled else { return }
        guard case .success(let entries) = FS.children(of: dir) else {
            if case .failure(let skip) = FS.children(of: dir) { result.skipped.append(skip) }
            return
        }
        for entry in entries {
            if Task.isCancelled { return }
            guard !FS.isSymlink(entry), let m = FS.meta(entry) else { continue }
            if m.isDirectory {
                // Bundles (.app, .photoslibrary, .rtfd) are single user-facing objects, not folders to walk.
                if (entry as NSString).pathExtension.isEmpty {
                    walk(entry, depth: depth + 1, cutoff: cutoff, ctx: ctx, into: &result)
                }
                continue
            }
            guard m.bytes >= minimumBytes, m.modified < cutoff else { continue }
            if let item = ctx.makeItem(path: entry, category: category, into: &result.skipped) {
                result.items.append(item)
            }
        }
    }
}

// MARK: - Screenshots and screen recordings

/// A category no researched competitor except one covers, and a real accumulation source.
/// (Vault: Improvement Opportunities #9.)
public struct ScreenCaptureScanner: CleanupScanner {
    public let category = SweepCategory.screenRecordings
    public init() {}

    static let prefixes = ["screenshot", "screen shot", "screen recording", "simulator screen shot",
                           "simulator screenshot", "cleanshot"]
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "mov", "mp4", "heic"]

    public func scan(_ ctx: ScanContext) async -> CategoryResult {
        var result = CategoryResult(category: category)
        // ~/Pictures omitted for the same least-privilege reason as LargeFileScanner.
        for root in ["Desktop", "Downloads", "Documents", "Movies"] {
            if Task.isCancelled { return result }
            guard case .success(let entries) = FS.children(of: ctx.path(root)) else { continue }
            for entry in entries {
                if Task.isCancelled { return result }
                let name = (entry as NSString).lastPathComponent.lowercased()
                guard Self.extensions.contains((entry as NSString).pathExtension.lowercased()),
                      Self.prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                if let item = ctx.makeItem(path: entry, category: category, into: &result.skipped) {
                    result.items.append(item)
                }
            }
        }
        result.items.sort { $0.modified > $1.modified }
        return result
    }
}

public let defaultScanners: [any CleanupScanner] = [
    CacheScanner(), LogScanner(), TrashScanner(), DeveloperJunkScanner(),
    InstallerScanner(), LeftoverScanner(), ScreenCaptureScanner(), LargeFileScanner(),
]
