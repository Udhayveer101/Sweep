import Foundation

/// Filesystem primitives shared by every scanner. All traversal here is symlink-refusing,
/// depth-bounded and budget-bounded so that a hostile or merely pathological directory tree
/// cannot hang or exhaust the app.
public enum FS {

    // MARK: - Paths

    /// Absolute, symlink-resolved, trailing-slash-free path. Does not require the file to exist.
    public static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        let standardized = (absolute as NSString).standardizingPath
        // `standardizingPath` resolves symlinks only for existing paths; realpath the deepest
        // existing ancestor so a non-existent leaf still ends up under a resolved parent.
        let resolved = (standardized as NSString).resolvingSymlinksInPath
        var out = resolved.isEmpty ? standardized : resolved
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// Absolute path with `~`, `.` and `..` resolved purely lexically: no filesystem access,
    /// and crucially no symlink resolution, so a symlink still appears as its own component.
    /// Used to detect symlinks *before* `normalize` would resolve them away.
    public static func lexical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        var stack: [Substring] = []
        for component in absolute.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(component)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    /// True when `path` is strictly inside `ancestor`. Component-aware, so `/a/bc` is not
    /// considered a descendant of `/a/b`.
    public static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        guard path != ancestor else { return false }
        let a = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(a)
    }

    /// True when any component of `path` below `root` is a symbolic link.
    public static func containsSymlink(_ path: String, upTo root: String) -> Bool {
        guard isDescendant(path, of: root) else { return isSymlink(path) }
        var current = root
        for component in path.dropFirst(root.count + 1).split(separator: "/") {
            current += "/" + component
            if isSymlink(current) { return true }
        }
        return false
    }

    public static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Identifier of the volume a path lives on, used to refuse cross-volume traversal.
    public static func volumeIdentifier(of path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return "\(st.st_dev)"
    }

    // MARK: - Metadata

    public struct Meta: Sendable {
        public let isDirectory: Bool
        public let bytes: Int64
        public let modified: Date
        public let deviceID: Int32
    }

    /// `lstat`-based metadata: never follows symlinks, so a link is reported as a link.
    public static func meta(_ path: String) -> Meta? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        // Prefer allocated blocks over apparent size: it is what actually frees up.
        let bytes = Int64(st.st_blocks) * 512
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        return Meta(isDirectory: isDir, bytes: bytes, modified: mtime, deviceID: st.st_dev)
    }

    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    // MARK: - Traversal

    public struct WalkLimits: Sendable {
        public var maxDepth: Int
        public var maxEntries: Int
        public init(maxDepth: Int = 24, maxEntries: Int = 400_000) {
            self.maxDepth = maxDepth
            self.maxEntries = maxEntries
        }
        public static let `default` = WalkLimits()
    }

    /// Aggregate of a directory subtree, computed without following symlinks or crossing volumes.
    public struct Aggregate: Sendable {
        public var bytes: Int64 = 0
        public var fileCount: Int = 0
        public var newestModification: Date = .distantPast
        public var skipped: [SkipRecord] = []
        public var truncated = false
    }

    /// Recursively measures `root`. Symlinks are counted as their own (tiny) size and never
    /// followed; entries on another device are skipped; the walk stops at the entry budget.
    /// Cancellation is cooperative via `Task.isCancelled`.
    public static func aggregate(_ root: String, limits: WalkLimits = .default) -> Aggregate {
        var out = Aggregate()
        guard let rootMeta = meta(root) else {
            out.skipped.append(SkipRecord(path: root, reason: .vanished))
            return out
        }
        let device = rootMeta.deviceID
        guard rootMeta.isDirectory else {
            out.bytes = rootMeta.bytes
            out.fileCount = 1
            out.newestModification = rootMeta.modified
            return out
        }

        var stack: [(path: String, depth: Int)] = [(root, 0)]
        out.newestModification = rootMeta.modified

        while let (dir, depth) = stack.popLast() {
            if Task.isCancelled { out.truncated = true; return out }
            if out.fileCount >= limits.maxEntries {
                out.truncated = true
                out.skipped.append(SkipRecord(path: dir, reason: .budgetExceeded))
                return out
            }
            if depth >= limits.maxDepth {
                out.skipped.append(SkipRecord(path: dir, reason: .depthLimit))
                continue
            }
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: dir)
            } catch {
                out.skipped.append(SkipRecord(path: dir, reason: skipReason(for: error)))
                continue
            }
            for name in names {
                // Checked per entry, not just per directory: a single directory holding a
                // million files must not blow the budget before the next loop iteration.
                if out.fileCount >= limits.maxEntries {
                    out.truncated = true
                    out.skipped.append(SkipRecord(path: dir, reason: .budgetExceeded))
                    return out
                }
                if Task.isCancelled { out.truncated = true; return out }
                let child = dir + "/" + name
                guard let m = meta(child) else {
                    out.skipped.append(SkipRecord(path: child, reason: .vanished))
                    continue
                }
                if isSymlink(child) {
                    // Counted but never traversed: following it could escape the scan root.
                    out.fileCount += 1
                    out.bytes += m.bytes
                    continue
                }
                if m.deviceID != device {
                    out.skipped.append(SkipRecord(path: child, reason: .crossedVolume))
                    continue
                }
                if m.modified > out.newestModification { out.newestModification = m.modified }
                if m.isDirectory {
                    out.bytes += m.bytes
                    stack.append((child, depth + 1))
                } else {
                    out.bytes += m.bytes
                    out.fileCount += 1
                }
            }
        }
        return out
    }

    /// Immediate children of a directory, symlinks excluded, sorted for stable output.
    public static func children(of dir: String) -> Result<[String], SkipRecord> {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
            return .success(names.map { dir + "/" + $0 })
        } catch {
            return .failure(SkipRecord(path: dir, reason: skipReason(for: error)))
        }
    }

    static func skipReason(for error: Error) -> SkipRecord.Reason {
        let code = (error as NSError).code
        switch code {
        case NSFileReadNoPermissionError, Int(EPERM), Int(EACCES): return .permissionDenied
        case NSFileNoSuchFileError, Int(ENOENT): return .vanished
        default: return .unreadable
        }
    }
}

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: n)
    }
}
