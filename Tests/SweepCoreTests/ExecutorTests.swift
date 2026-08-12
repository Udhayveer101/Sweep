import Foundation
import Testing
@testable import SweepCore

/// Builds an item exactly as a scanner would, so executor tests exercise the real path.
private func item(_ path: String, category: SweepCategory = .userCaches, risk: Risk = .safe) -> Item {
    let agg = FS.aggregate(path)
    return Item(category: category, path: path,
                displayName: (path as NSString).lastPathComponent,
                bytes: agg.bytes,
                modified: agg.newestModification,
                risk: risk, rationale: [], autoSelected: risk == .safe)
}

@Suite("Cleanup executor", .serialized)
struct ExecutorTests {

    @Test("Deletes what it was given and verifies the result rather than assuming it")
    func deletesAndVerifies() {
        let f = Fixture()
        let a = f.file("Library/Caches/gone/a.bin", bytes: 4096)
        _ = a
        let target = f.root + "/Library/Caches/gone"
        let executor = CleanupExecutor(safety: f.engine, permanentOverride: true)
        let report = executor.run(items: [item(target)])
        #expect(report.succeeded.count == 1)
        #expect(report.verifiedBytesFreed > 0)
        #expect(!FS.exists(target))
    }

    @Test("Refuses an item that changed between the scan and the cleanup")
    func toctouChange() {
        let f = Fixture()
        let path = f.file("Library/Caches/hot/a.bin", bytes: 4096)
        let target = f.root + "/Library/Caches/hot"
        var candidate = item(target)
        // Simulate a stale scan result: the item is recorded as older than it now is.
        candidate = Item(category: .userCaches, path: target, displayName: "hot",
                         bytes: candidate.bytes, modified: Date().addingTimeInterval(-1000),
                         risk: .safe, rationale: [], autoSelected: true)
        FileManager.default.createFile(atPath: path, contents: Data(count: 8192))

        let report = CleanupExecutor(safety: f.engine, permanentOverride: true).run(items: [candidate])
        #expect(report.succeeded.isEmpty)
        #expect(report.problems.first?.status == .skipped)
        #expect(report.problems.first?.reason == SafetyEngine.Refusal.changed.rawValue)
        #expect(FS.exists(target), "a changed item must survive")
    }

    @Test("Refuses an item that vanished, and says so")
    func vanished() {
        let f = Fixture()
        let target = f.root + "/Library/Caches/never"
        let candidate = Item(category: .userCaches, path: target, displayName: "never",
                             bytes: 100, modified: Date(), risk: .safe, rationale: [], autoSelected: true)
        let report = CleanupExecutor(safety: f.engine, permanentOverride: true).run(items: [candidate])
        #expect(report.problems.first?.reason == SafetyEngine.Refusal.notFound.rawValue)
    }

    @Test("Refuses a protected path even if one is handed to it directly")
    func refusesProtected() {
        let f = Fixture()
        let target = f.dir("Library/Keychains")
        let candidate = Item(category: .userCaches, path: target, displayName: "Keychains",
                             bytes: 100, modified: Date(), risk: .safe, rationale: [], autoSelected: true)
        let report = CleanupExecutor(safety: f.engine, permanentOverride: true).run(items: [candidate])
        #expect(report.succeeded.isEmpty)
        #expect(FS.exists(target))
    }

    @Test("Never deletes items classified review-worthy or unknown, whatever the caller asks")
    func refusesNonSafeRisk() {
        let f = Fixture()
        let target = f.dir("Library/Caches/unknown-thing")
        for risk in [Risk.unknown, .protected] {
            let candidate = Item(category: .appLeftovers, path: target, displayName: "x",
                                 bytes: 100, modified: Date(), risk: risk, rationale: [])
            let report = CleanupExecutor(safety: f.engine, permanentOverride: true).run(items: [candidate])
            #expect(report.succeeded.isEmpty)
            #expect(FS.exists(target))
        }
    }

    @Test("Refuses to follow a symlink handed in as a cleanup target")
    func refusesSymlink() {
        let f = Fixture()
        f.dir("real-data")
        f.file("real-data/precious.bin", bytes: 4096)
        let link = f.symlink("Library/Caches/link", to: f.root + "/real-data")
        let candidate = Item(category: .userCaches, path: link, displayName: "link",
                             bytes: 100, modified: Date(), risk: .safe, rationale: [], autoSelected: true)
        let report = CleanupExecutor(safety: f.engine, permanentOverride: true).run(items: [candidate])
        #expect(report.succeeded.isEmpty)
        #expect(FS.exists(f.root + "/real-data/precious.bin"), "the link's target must be untouched")
    }

    @Test("One failure does not stop the rest of the run")
    func failureIsolation() {
        let f = Fixture()
        let good1 = f.dir("Library/Caches/good1")
        f.file("Library/Caches/good1/x.bin", bytes: 4096)
        let bad = f.root + "/Library/Caches/missing"
        let good2 = f.dir("Library/Caches/good2")
        f.file("Library/Caches/good2/x.bin", bytes: 4096)

        let items = [item(good1),
                     Item(category: .userCaches, path: bad, displayName: "missing", bytes: 1,
                          modified: Date(), risk: .safe, rationale: []),
                     item(good2)]
        let report = CleanupExecutor(safety: f.engine, permanentOverride: true).run(items: items)
        #expect(report.succeeded.count == 2)
        #expect(report.problems.count == 1)
        #expect(report.problems.allSatisfy { $0.reason?.isEmpty == false })
    }

    @Test("Every reported problem carries a specific reason, never a bare failure")
    func problemsAlwaysExplained() {
        let f = Fixture()
        let items = [
            Item(category: .userCaches, path: f.root + "/Library/Caches/a", displayName: "a",
                 bytes: 1, modified: Date(), risk: .safe, rationale: []),
            Item(category: .userCaches, path: "/etc/passwd", displayName: "passwd",
                 bytes: 1, modified: Date(), risk: .safe, rationale: []),
        ]
        let report = CleanupExecutor(safety: f.engine, permanentOverride: true).run(items: items)
        #expect(report.problems.count == 2)
        for problem in report.problems {
            #expect((problem.reason ?? "").count > 5)
        }
    }

    @Test("Trash-first keeps the item recoverable, and Restorer puts it back")
    func trashRoundTrip() throws {
        // Uses the real home so that a real Trash move happens, in a uniquely named scratch
        // folder that is cleaned up whichever way the test ends.
        let scratch = NSHomeDirectory() + "/.sweep-selftest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let target = scratch + "/disposable"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target + "/x.bin", contents: Data(count: 4096))
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let engine = SafetyEngine(home: NSHomeDirectory())
        let report = CleanupExecutor(safety: engine).run(items: [item(target)])

        guard let outcome = report.succeeded.first else {
            Issue.record("expected the item to be trashed: \(report.problems.map { $0.reason ?? "" })")
            return
        }
        #expect(outcome.status == .trashed)
        #expect(outcome.trashPath != nil)
        #expect(FS.exists(outcome.trashPath!), "the item should be sitting in the Trash")
        #expect(!FS.exists(target))

        let restored = Restorer().restore(report)
        #expect(restored.restored == [target])
        #expect(FS.exists(target + "/x.bin"), "restore must bring the contents back too")
        #expect(restored.failed.isEmpty)
    }

    @Test("Restore declines when something already occupies the original location")
    func restoreCollision() {
        let report = CleanupReport(
            started: Date(), finished: Date(),
            outcomes: [ItemOutcome(path: NSHomeDirectory(), displayName: "home",
                                   category: .userCaches, bytes: 1, status: .trashed,
                                   reason: nil, trashPath: NSHomeDirectory())],
            verifiedBytesFreed: 1, cancelled: false)
        let result = Restorer().restore(report)
        #expect(result.restored.isEmpty)
        #expect(result.failed.count == 1)
    }
}

@Suite("Orchestrator")
struct OrchestratorTests {

    @Test("Runs scanners concurrently and returns one result per scanner")
    func runsAll() async throws {
        let f = Fixture()
        f.file("Library/Caches/com.example.gone/x.bin", bytes: 20_000_000)
        f.ageTree("Library/Caches/com.example.gone", age: 90 * days)
        f.file("Downloads/App.dmg", bytes: 20_000_000, age: 90 * days)

        let report = try await ScanOrchestrator().scan(context: f.context())
        #expect(report.categories.count == defaultScanners.count)
        #expect(report.totalBytes > 0)
        #expect(report.recommendedBytes > 0)
        #expect(report.recommendedBytes <= report.totalBytes)
    }

    @Test("Refuses a second simultaneous scan instead of racing on the same paths")
    func singleScanInFlight() async throws {
        let f = Fixture()
        for i in 0..<300 { f.file("Library/Caches/c\(i)/x.bin", bytes: 1024) }
        let orchestrator = ScanOrchestrator()
        let ctx = f.context()

        async let first: ScanReport = orchestrator.scan(context: ctx)
        try await Task.sleep(nanoseconds: 1_000_000)
        var rejected = false
        do { _ = try await orchestrator.scan(context: ctx) } catch { rejected = true }
        _ = try await first
        #expect(rejected)
        // And the lock releases afterwards.
        _ = try await orchestrator.scan(context: ctx)
    }

    @Test("A failing scanner is isolated and the other results still arrive")
    func failureIsolation() async throws {
        struct Exploding: CleanupScanner {
            let category = SweepCategory.userLogs
            func scan(_ ctx: ScanContext) async -> CategoryResult {
                CategoryResult(category: category, failure: ScanFailure("scanner blew up"))
            }
        }
        let f = Fixture()
        f.file("Library/Caches/com.example.gone/x.bin", bytes: 20_000_000)
        f.ageTree("Library/Caches/com.example.gone", age: 90 * days)

        let report = try await ScanOrchestrator(scanners: [Exploding(), CacheScanner()])
            .scan(context: f.context())
        #expect(report.partial)
        #expect(report.categories.first { $0.category == .userLogs }?.failure != nil)
        #expect(report.categories.first { $0.category == .userCaches }?.items.isEmpty == false)
    }

    @Test("Emits a start and finish event for every category")
    func events() async throws {
        let f = Fixture()
        final class Box: @unchecked Sendable { var events: [ScanEvent] = []; let lock = NSLock() }
        let box = Box()
        _ = try await ScanOrchestrator(scanners: [CacheScanner(), TrashScanner()])
            .scan(context: f.context()) { event in
                box.lock.lock(); box.events.append(event); box.lock.unlock()
            }
        let started = box.events.filter { if case .started = $0 { true } else { false } }
        let finished = box.events.filter { if case .finished = $0 { true } else { false } }
        #expect(started.count == 2)
        #expect(finished.count == 2)
    }

    @Test("No path is ever reported by two scanners, directly or by nesting")
    func deduplicates() async throws {
        let f = Fixture()
        f.file("Library/Caches/com.example.gone/x.bin", bytes: 20_000_000)
        f.ageTree("Library/Caches/com.example.gone", age: 90 * days)
        f.file("Library/Application Support/com.example.gone/y.bin", bytes: 20_000_000)
        f.ageTree("Library/Application Support/com.example.gone", age: 400 * days)

        let report = try await ScanOrchestrator().scan(context: f.context())
        let paths = report.allItems.map(\.path)
        #expect(Set(paths).count == paths.count, "a path was reported twice")
        // The cache folder belongs to the cache scanner, not the leftover scanner.
        let leftovers = report.categories.first { $0.category == .appLeftovers }?.items ?? []
        #expect(!leftovers.contains { $0.path.contains("/Library/Caches/") })
    }

    @Test("A nested path is dropped when an ancestor is already claimed")
    func deduplicatesNested() {
        let parent = Item(category: .userCaches, path: "/home/u/Library/Caches/app",
                          displayName: "app", bytes: 10, modified: Date(), risk: .safe, rationale: [])
        let child = Item(category: .appLeftovers, path: "/home/u/Library/Caches/app/inner",
                         displayName: "inner", bytes: 5, modified: Date(), risk: .safe, rationale: [])
        let out = ScanOrchestrator.deduplicate([
            CategoryResult(category: .userCaches, items: [parent]),
            CategoryResult(category: .appLeftovers, items: [child]),
        ])
        #expect(out[0].items.count == 1)
        #expect(out[1].items.isEmpty)
    }

    @Test("Only safe items arrive pre-selected")
    func onlySafeIsPreselected() async throws {
        let f = Fixture()
        f.file("Movies/big.mov", bytes: 300_000_000, age: 400 * days)
        f.file("Library/Caches/com.example.gone/x.bin", bytes: 20_000_000)
        f.ageTree("Library/Caches/com.example.gone", age: 90 * days)
        let report = try await ScanOrchestrator().scan(context: f.context())
        for item in report.allItems {
            #expect(item.autoSelected == (item.risk == .safe))
        }
        #expect(report.allItems.contains { $0.risk == .review })
    }
}

@Suite("History")
struct HistoryTests {

    @Test("Records, searches and totals cleanup runs, and stays owner-readable only")
    func roundTrip() async throws {
        let dir = URL(fileURLWithPath: Fixture().root)
        let store = HistoryStore(directory: dir)
        let report = CleanupReport(
            started: Date(), finished: Date(),
            outcomes: [ItemOutcome(path: "/a/b/Slack cache", displayName: "Slack cache",
                                   category: .userCaches, bytes: 500, status: .trashed)],
            verifiedBytesFreed: 500, cancelled: false)
        #expect(await store.record(report))
        #expect(await store.all().count == 1)
        #expect(await store.totalBytesFreed() == 500)
        #expect(await store.search("slack").count == 1)
        #expect(await store.search("nothing-like-this").isEmpty)

        let perms = try FileManager.default.attributesOfItem(atPath: await store.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)

        // Survives a fresh instance reading from disk.
        let reopened = HistoryStore(directory: dir)
        #expect(await reopened.all().count == 1)
    }

    @Test("Caps its own growth")
    func bounded() async {
        let store = HistoryStore(directory: URL(fileURLWithPath: Fixture().root))
        for _ in 0..<210 {
            await store.record(CleanupReport(started: Date(), finished: Date(),
                                             outcomes: [], verifiedBytesFreed: 1, cancelled: false))
        }
        #expect(await store.all().count == 200)
    }
}
