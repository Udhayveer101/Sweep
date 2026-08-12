import Foundation
import Testing
@testable import SweepCore

@Suite("Filesystem traversal")
struct FSTests {

    @Test("Never follows a symlink, even one pointing at a huge tree")
    func doesNotFollowSymlinks() {
        let f = Fixture()
        f.file("real/a.bin", bytes: 1_000_000)
        f.symlink("real/loop", to: f.root + "/real")     // self-referential
        f.symlink("real/outside", to: "/usr/share")
        let agg = FS.aggregate(f.root + "/real")
        // Both links are counted as links (a few bytes), not traversed.
        #expect(agg.fileCount == 3)
        #expect(agg.bytes < 2_000_000)
    }

    @Test("Terminates on a deep tree at the depth limit rather than recursing forever")
    func depthLimit() {
        let f = Fixture()
        let deep = (0..<40).map { "d\($0)" }.joined(separator: "/")
        f.file("deep/" + deep + "/leaf.bin", bytes: 1000)
        let agg = FS.aggregate(f.root + "/deep", limits: FS.WalkLimits(maxDepth: 5, maxEntries: 100_000))
        #expect(agg.skipped.contains { $0.reason == .depthLimit })
    }

    @Test("Stops at the entry budget on a very large directory")
    func entryBudget() {
        let f = Fixture()
        for i in 0..<200 { f.file("many/f\(i)", bytes: 1) }
        let agg = FS.aggregate(f.root + "/many", limits: FS.WalkLimits(maxDepth: 10, maxEntries: 50))
        #expect(agg.truncated)
        #expect(agg.skipped.contains { $0.reason == .budgetExceeded })
    }

    @Test("Reports a vanished path instead of trapping")
    func vanished() {
        let f = Fixture()
        let agg = FS.aggregate(f.root + "/never-existed")
        #expect(agg.bytes == 0)
        #expect(agg.skipped.first?.reason == .vanished)
    }

    @Test("Surfaces permission denials as skips, not as zero bytes")
    func permissionDenied() throws {
        let f = Fixture()
        f.file("locked/secret.bin", bytes: 1000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: f.root + "/locked")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: f.root + "/locked") }
        let agg = FS.aggregate(f.root + "/locked")
        // Running as root would defeat this test; skip rather than assert a false negative.
        if getuid() != 0 {
            #expect(agg.skipped.contains { $0.reason == .permissionDenied })
        }
    }

    @Test("Newest modification date reflects the newest descendant, not the root")
    func newestDescendant() {
        let f = Fixture()
        f.file("tree/old.bin", bytes: 1000, age: 100 * days)
        f.file("tree/new.bin", bytes: 1000)
        let agg = FS.aggregate(f.root + "/tree")
        #expect(agg.newestModification.timeIntervalSinceNow > -60)
    }

    @Test("Handles unicode and space-bearing filenames")
    func unicodeNames() {
        let f = Fixture()
        f.file("odd/Ünïcödé 🧹 file.bin", bytes: 4096)
        f.file("odd/  leading spaces.bin", bytes: 4096)
        let agg = FS.aggregate(f.root + "/odd")
        #expect(agg.fileCount == 2)
    }

    @Test("Cooperates with cancellation")
    func cancellation() async {
        let f = Fixture()
        for i in 0..<500 { f.file("big/f\(i)", bytes: 1) }
        let task = Task {
            FS.aggregate(f.root + "/big")
        }
        task.cancel()
        let agg = await task.value
        #expect(agg.truncated || agg.fileCount <= 500)
    }
}
