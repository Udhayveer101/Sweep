import Foundation

// MARK: - Shared item construction

extension ScanContext {
    /// Measures a candidate path, gathers macOS usage evidence for it, and runs both through
    /// the safety engine. Returns nil when the path vanished or the engine refuses it outright.
    func makeItem(path: String,
                  category: SweepCategory,
                  displayName: String? = nil,
                  attribution: Attribution? = nil,
                  owningBundleID: String? = nil,
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

        // Reuse the newest modification date the size walk already computed rather than
        // re-reading it: one traversal, not two.
        let bundleID = owningBundleID ?? (attribution == .exactBundleID
            ? (path as NSString).lastPathComponent : nil)
        let running = bundleID.map { runningApps.bundleIDs.contains($0) } ?? false
        let evidence = metadata.evidence(for: path, treeModified: agg.newestModification, isRunning: running)

        let verdict = safety.classify(
            path: path, category: category, evidence: evidence, bytes: agg.bytes,
            attribution: attribution, now: now, runningApps: runningApps)
        guard verdict.risk != .protected else { return nil }

        return Item(category: category,
                    path: path,
                    displayName: displayName ?? (path as NSString).lastPathComponent,
                    bytes: agg.bytes,
                    modified: agg.newestModification,
                    fileCount: max(agg.fileCount, 1),
                    risk: verdict.risk,
                    confidence: verdict.confidence,
                    evidence: evidence,
                    rationale: verdict.rationale,
                    autoSelected: false,
                    owningBundleID: bundleID,
                    attribution: attribution)
    }

    /// Lists a scanner root, recording an unreadable root distinctly from an empty one.
    func rootChildren(_ path: String, into result: inout CategoryResult) -> [String] {
        switch FS.children(of: path) {
        case .success(let entries):
            return entries
        case .failure(let skip):
            // Absent is fine (the folder simply does not exist here); unreadable is not, because
            // it silently turns into "nothing found".
            if skip.reason != .vanished && FS.exists(path) {
                result.unreadableRoots.append(path)
                result.skipped.append(skip)
            }
            return []
        }
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
        for entry in ctx.rootChildren(ctx.path("Library/Caches"), into: &result) {
            if Task.isCancelled { return result }
            let name = (entry as NSString).lastPathComponent
            if developerOwnedCacheNames.contains(name) { continue }
            let match = ctx.installed.attribute(folderName: name)
            if let item = ctx.makeItem(path: entry, category: category,
                                       attribution: match.attribution,
                                       owningBundleID: match.bundleID, into: &result.skipped) {
                result.items.append(item)
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
        for entry in ctx.rootChildren(ctx.path("Library/Logs"), into: &result) {
            if Task.isCancelled { return result }
            let match = ctx.installed.attribute(folderName: (entry as NSString).lastPathComponent)
            if let item = ctx.makeItem(path: entry, category: category,
                                       attribution: match.attribution,
                                       owningBundleID: match.bundleID, into: &result.skipped) {
                result.items.append(item)
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
        // ~/.Trash is TCC-protected: without Full Disk Access this listing fails, and reporting
        // that as "nothing found" would tell the user their Trash is empty when it is not.
        for entry in ctx.rootChildren(ctx.path(".Trash"), into: &result) {
            if Task.isCancelled { return result }
            if let item = ctx.makeItem(path: entry, category: category, into: &result.skipped) {
                result.items.append(item)
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
                                               displayName: "\(loc.label): \(name)",
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
            for entry in ctx.rootChildren(ctx.path(folder), into: &result) {
                if Task.isCancelled { return result }
                guard Self.extensions.contains((entry as NSString).pathExtension.lowercased()) else { continue }
                if let item = ctx.makeItem(path: entry, category: category, into: &result.skipped) {
                    result.items.append(item)
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
            for entry in ctx.rootChildren(base, into: &result) {
                if Task.isCancelled { return result }
                let folderName = (entry as NSString).lastPathComponent
                // The folder name is a hint, not the answer: a container records the bundle
                // identifier that actually owns it, which survives renames and UUID-named folders.
                let declared = ContainerMetadata.owningBundleID(ofContainerAt: entry)
                let identity = declared ?? folderName
                guard !Self.systemPrefixes.contains(where: { identity.hasPrefix($0) || folderName.hasPrefix($0) }) else { continue }
                guard let match = orphanMatch(identity: identity, folderName: folderName,
                                              declared: declared != nil, installed: ctx.installed)
                else { continue }
                if let item = ctx.makeItem(path: entry, category: category,
                                           displayName: displayName(folder: folderName, declared: declared),
                                           attribution: match.attribution,
                                           owningBundleID: match.bundleID, into: &result.skipped) {
                    result.items.append(item)
                }
            }
        }
        return result
    }

    private func displayName(folder: String, declared: String?) -> String {
        guard let declared, declared != folder else { return folder }
        return "\(folder) (\(declared))"
    }

    /// Nil when the folder is *not* an orphan (its app is installed, or we cannot tell).
    func orphanMatch(identity: String, folderName: String, declared: Bool,
                     installed: InstalledApps) -> (attribution: Attribution, bundleID: String?)? {
        if InstalledApps.looksLikeBundleID(identity) {
            if installed.bundleIDs.contains(identity) { return nil }
            // Versioned or suffixed identifiers: com.vendor.App.helper belongs to com.vendor.App.
            if installed.bundleIDs.contains(where: { identity.hasPrefix($0 + ".") }) { return nil }
            // A folder named for an app whose bundle ID we never read (unreadable Info.plist)
            // but whose name matches an installed app.
            if let leaf = identity.split(separator: ".").last.map(String.init)?.lowercased(),
               installed.names.contains(leaf) { return nil }
            // A container that states its own owner is the strongest signal available.
            return (declared ? .exactBundleID : .exactBundleID, identity)
        }
        let lowered = folderName.lowercased()
        if installed.names.contains(lowered) { return nil }
        if installed.names.contains(where: { lowered.hasPrefix($0) || $0.hasPrefix(lowered) }) { return nil }
        return (.nameHeuristic, nil)
    }
}

/// Reads the identifier a sandbox container declares for itself.
///
/// A container directory is not reliably named after its owner: it can be renamed, and the
/// owning app can be renamed independently. `containermanagerd` writes the real bundle
/// identifier into the container, which is why this beats matching on the folder name.
public enum ContainerMetadata {
    static let metadataFile = ".com.apple.containermanagerd.metadata.plist"

    public static func owningBundleID(ofContainerAt path: String) -> String? {
        let plist = path + "/" + metadataFile
        guard let data = FileManager.default.contents(atPath: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["MCMMetadataIdentifier"] as? String
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
