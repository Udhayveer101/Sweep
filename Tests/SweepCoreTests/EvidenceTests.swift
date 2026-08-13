import Foundation
import Testing
@testable import SweepCore

@Suite("Usage evidence")
struct EvidenceTests {
    let now = Date()

    @Test("A write is never reported as a use")
    func writeIsNotUse() {
        let e = UsageEvidence(modified: now.addingTimeInterval(-5 * days))
        #expect(e.daysSinceLastUse(now: now) == nil, "no open record means no last-use figure")
        #expect(e.daysSinceModified(now: now) == 5)
        let text = e.statements(now: now, category: .userCaches).map(\.detail).joined()
        #expect(text.contains("not the same as a use"))
    }

    @Test("Access time is recorded but never raises confidence")
    func accessTimeIsNotTrusted() {
        let stale = UsageEvidence(modified: now.addingTimeInterval(-400 * days),
                                  accessed: now, isRunning: false)
        // atime is today, yet the item is still judged on its write time only.
        #expect(stale.confidence(for: .userCaches) == .medium)
        #expect(stale.daysSinceLastUse(now: now) == nil)
        let text = stale.statements(now: now, category: .userCaches).map(\.rule).joined()
        #expect(text.contains("not trusted"))
    }

    @Test("A recorded open date is the strongest signal")
    func launchServicesIsHighConfidence() {
        let e = UsageEvidence(lastUsed: now.addingTimeInterval(-3 * days), useCount: 12,
                              modified: now.addingTimeInterval(-500 * days))
        #expect(e.confidence(for: .staleInstallers) == .high)
        #expect(e.daysSinceLastUse(now: now) == 3)
    }

    @Test("A running owner is high confidence regardless of dates")
    func runningIsHighConfidence() {
        let e = UsageEvidence(modified: now.addingTimeInterval(-900 * days), isRunning: true)
        #expect(e.confidence(for: .userCaches) == .high)
    }

    @Test("Missing metadata means unknown, never 'never used'")
    func absentMetadataIsNotEvidence() {
        let blind = UsageEvidence(modified: now.addingTimeInterval(-400 * days),
                                  metadataUnavailable: true)
        // For an openable item, Spotlight being unreachable makes the absence meaningless.
        #expect(blind.confidence(for: .staleInstallers) == .low)
        let text = blind.statements(now: now, category: .staleInstallers).map(\.detail).joined()
        #expect(text.contains("not 'never used'"))
    }

    @Test("Evidence model differs per category, and user content is always weak evidence")
    func evidenceModels() {
        #expect(SweepCategory.userCaches.evidenceModel == .appManagedWrites)
        #expect(SweepCategory.staleInstallers.evidenceModel == .userOpenable)
        #expect(SweepCategory.largeOldFiles.evidenceModel == .userAuthored)
        let old = UsageEvidence(modified: now.addingTimeInterval(-999 * days))
        #expect(old.confidence(for: .largeOldFiles) == .low)
    }
}

@Suite("Confidence gates classification")
struct ConfidenceTests {
    let now = Date()

    @Test("Safe always requires at least medium confidence")
    func safeRequiresConfidence() {
        let f = Fixture()
        // Old, large, unattributed installer with Spotlight unreachable → low confidence.
        let blind = UsageEvidence(modified: now.addingTimeInterval(-400 * days),
                                  metadataUnavailable: true)
        let v = f.engine.classify(path: f.root + "/Downloads/x.dmg", category: .staleInstallers,
                                  evidence: blind, bytes: 500_000_000, attribution: nil, now: now)
        #expect(v.confidence == .low)
        #expect(v.risk == .review, "low confidence must never produce a pre-selected deletion")
        #expect(v.rationale.contains { $0.rule == "Not enough evidence" })
    }

    @Test("A running application's data is never safe, however old it looks")
    func runningIsNeverSafe() {
        let f = Fixture()
        let e = UsageEvidence(modified: now.addingTimeInterval(-900 * days), isRunning: true)
        let v = f.engine.classify(path: f.root + "/Library/Caches/com.example.live",
                                  category: .userCaches, evidence: e, bytes: 900_000_000,
                                  attribution: .exactBundleID, now: now)
        #expect(v.risk == .review)
        #expect(v.rationale.contains { $0.rule == "Active" })
    }

    @Test("A recently opened installer is not safe even when its file date is ancient")
    func recentOpenBeatsOldWriteDate() {
        let f = Fixture()
        let e = UsageEvidence(lastUsed: now.addingTimeInterval(-2 * days),
                              modified: now.addingTimeInterval(-800 * days))
        let v = f.engine.classify(path: f.root + "/Downloads/App.dmg", category: .staleInstallers,
                                  evidence: e, bytes: 500_000_000, attribution: nil, now: now)
        #expect(v.risk == .review)
        #expect(v.rationale.contains { $0.rule == "Opened recently" })
    }

    @Test("An unopened, unchanged installer is safe and says why")
    func unopenedInstallerIsSafe() {
        let f = Fixture()
        let e = UsageEvidence(modified: now.addingTimeInterval(-200 * days))
        let v = f.engine.classify(path: f.root + "/Downloads/App.dmg", category: .staleInstallers,
                                  evidence: e, bytes: 500_000_000, attribution: nil, now: now)
        #expect(v.risk == .safe)
        #expect(v.confidence == .medium)
    }

    @Test("Every verdict carries its reasoning")
    func verdictsAreExplainable() {
        let f = Fixture()
        for category in SweepCategory.allCases {
            let v = f.engine.classify(path: f.root + "/Library/Caches/thing", category: category,
                                      evidence: UsageEvidence(modified: now.addingTimeInterval(-100 * days)),
                                      bytes: 10_000_000, attribution: .exactBundleID, now: now)
            #expect(!v.rationale.isEmpty, "\(category) produced no explanation")
            #expect(v.rationale.allSatisfy { !$0.rule.isEmpty && !$0.detail.isEmpty })
        }
    }
}

@Suite("Unreadable locations are never reported as empty")
struct BlockedRootTests {

    @Test("A category whose root cannot be read says so instead of 'nothing found'")
    func blockedRootIsDistinctFromEmpty() async throws {
        let f = Fixture()
        let trash = f.dir(".Trash")
        f.file(".Trash/discarded.bin", bytes: 5_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: trash)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash) }
        guard getuid() != 0 else { return }   // root would defeat the test

        let result = await TrashScanner().scan(f.context())
        #expect(result.items.isEmpty)
        #expect(result.wasBlocked, "an unreadable root must be recorded")
        #expect(result.isTrulyEmpty == false)
        #expect(RecommendationEngine().summary(for: result).contains("Could not be read"))
    }

    @Test("A genuinely empty category is reported as empty")
    func emptyIsEmpty() async {
        let f = Fixture()
        f.dir(".Trash")
        let result = await TrashScanner().scan(f.context())
        #expect(result.items.isEmpty)
        #expect(result.isTrulyEmpty)
        #expect(RecommendationEngine().summary(for: result) == "Nothing found.")
    }

    @Test("A missing folder is not an error, it just does not exist here")
    func missingRootIsNotBlocked() async {
        let f = Fixture()
        let result = await TrashScanner().scan(f.context())
        #expect(result.wasBlocked == false)
        #expect(result.isTrulyEmpty)
    }

    @Test("A blocked root marks the whole scan as permission-limited")
    func blockedRootLimitsReport() async throws {
        let f = Fixture()
        let trash = f.dir(".Trash")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: trash)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash) }
        guard getuid() != 0 else { return }
        let report = try await ScanOrchestrator(scanners: [TrashScanner()]).scan(context: f.context())
        #expect(report.limitedByPermissions)
    }
}

@Suite("Application attribution")
struct AttributionTests {

    @Test("A container's declared identifier beats its folder name")
    func containerMetadataWins() {
        let f = Fixture()
        let container = f.dir("Library/Containers/SomeRenamedFolder")
        let plist: [String: Any] = ["MCMMetadataIdentifier": "com.vendor.RealApp"]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        FileManager.default.createFile(atPath: container + "/" + ContainerMetadata.metadataFile, contents: data)
        #expect(ContainerMetadata.owningBundleID(ofContainerAt: container) == "com.vendor.RealApp")
    }

    @Test("A helper's identifier resolves to its parent application")
    func helperBelongsToParent() {
        let scanner = LeftoverScanner()
        let installed = InstalledApps(bundleIDs: ["com.vendor.App"], names: ["app"])
        // com.vendor.App.helper must not be called an orphan while com.vendor.App is installed.
        #expect(scanner.orphanMatch(identity: "com.vendor.App.helper", folderName: "com.vendor.App.helper",
                                    declared: false, installed: installed) == nil)
        #expect(scanner.orphanMatch(identity: "com.other.Gone", folderName: "com.other.Gone",
                                    declared: false, installed: installed)?.attribution == .exactBundleID)
    }

    @Test("A renamed container whose owner is installed is not an orphan")
    func renamedContainerNotOrphan() {
        let scanner = LeftoverScanner()
        let installed = InstalledApps(bundleIDs: ["com.vendor.RealApp"], names: ["realapp"])
        #expect(scanner.orphanMatch(identity: "com.vendor.RealApp", folderName: "SomeRenamedFolder",
                                    declared: true, installed: installed) == nil)
    }

    @Test("Attribution tiers are ordered from strongest to weakest")
    func tierOrdering() {
        let installed = InstalledApps(bundleIDs: ["com.a.b"], names: ["notes"])
        #expect(installed.attribute(folderName: "com.a.b").attribution == .exactBundleID)
        #expect(installed.attribute(folderName: "Notes").attribution == .pathConvention)
        #expect(installed.attribute(folderName: "Wibble").attribution == .nameHeuristic)
        #expect(Attribution.exactBundleID < Attribution.pathConvention)
        #expect(Attribution.pathConvention < Attribution.nameHeuristic)
    }
}

@Suite("Storage overview")
struct StorageOverviewTests {

    @Test("Reports system figures and the reclaimable gap without inventing one")
    func systemFigures() throws {
        let overview = try #require(StorageOverview.read())
        #expect(overview.totalCapacity > 0)
        #expect(overview.availableCapacity > 0)
        // macOS counts purgeable space as available-for-important-usage, so this is never lower.
        #expect(overview.availableForImportantUsage >= overview.availableCapacity)
        #expect(overview.reclaimableByMacOS >= 0)
        #expect(overview.usedCapacity < overview.totalCapacity)
    }

    @Test("Used and free are computed on the same basis System Settings uses")
    func usedMatchesSystemSettingsBasis() {
        // Figures measured on the development machine, where System Settings showed 298.73 GB
        // used against a 494.38 GB volume. Using raw availability instead would report 328.51 GB
        //. Wrong by exactly the purgeable amount. This test pins the correct basis.
        let o = StorageOverview(totalCapacity: 494_384_795_648,
                                availableCapacity: 165_879_750_656,
                                availableForImportantUsage: 195_535_554_837)
        let gb = 1_000_000_000.0
        #expect(abs(Double(o.usedCapacity) / gb - 298.85) < 0.1)
        #expect(abs(Double(o.freeCapacity) / gb - 195.54) < 0.1)
        #expect(abs(Double(o.reclaimableByMacOS) / gb - 29.66) < 0.1)
        // The wrong basis, kept as a named property rather than silently discarded.
        #expect(abs(Double(o.usedExcludingReclaimable) / gb - 328.51) < 0.1)
    }

    @Test("Used and free always add up to capacity")
    func figuresAddUp() throws {
        let o = try #require(StorageOverview.read())
        #expect(o.usedCapacity + o.freeCapacity == o.totalCapacity)
        // Reclaimable is a subset of free, not a fourth independent number.
        #expect(o.reclaimableByMacOS <= o.freeCapacity)
    }

    @Test("A volume without the important-usage key never reports negative or inconsistent figures")
    func missingImportantUsageKey() {
        // Some volume types omit the key; the fallback must keep the arithmetic sane.
        let o = StorageOverview(totalCapacity: 1000, availableCapacity: 400,
                                availableForImportantUsage: 400)
        #expect(o.usedCapacity == 600)
        #expect(o.freeCapacity == 400)
        #expect(o.reclaimableByMacOS == 0)
    }

    @Test("Every read is stamped, and a re-read produces a newer stamp")
    func readsAreStamped() throws {
        let first = try #require(StorageOverview.read())
        let second = try #require(StorageOverview.read())
        #expect(second.measuredAt >= first.measuredAt)
        // Cheap enough to call on every screen appearance: this is what makes caching unnecessary.
        let start = Date()
        for _ in 0..<100 { _ = StorageOverview.read() }
        let perRead = Date().timeIntervalSince(start) / 100
        // Measured: ~0.002 ms in an optimised build, ~12 ms in this debug test build (debug
        // Foundation bridging dominates). The threshold is set to catch the regression that
        // actually matters. Someone making `read()` walk the filesystem, which would cost
        // seconds, not milliseconds.
        #expect(perRead < 0.1, "read() must stay a syscall, not become a filesystem walk")
    }

    @Test("Fresh figures track real changes on disk")
    func figuresTrackRealChanges() throws {
        let before = try #require(StorageOverview.read())
        // Occupy a measurable amount, then confirm a re-read notices it.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-storage-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data(count: 300_000_000).write(to: scratch)
        let after = try #require(StorageOverview.read())
        #expect(after.measuredAt > before.measuredAt)
        // A re-read must reflect what is actually on the volume rather than a cached figure.
        //
        // Deliberately *not* asserted as `after.freeCapacity <= before.freeCapacity`: macOS
        // reclaims purgeable space concurrently, so free space genuinely can rise while this
        // test writes 300 MB, and that assertion was observed failing on an otherwise-healthy
        // machine. What the test actually cares about is that the figure moved at all: a
        // cached or hard-coded `read()` would return an identical value.
        let moved = after.freeCapacity != before.freeCapacity
            || after.usedCapacity != before.usedCapacity
        #expect(moved, "read() must report fresh volume figures, not a cached snapshot")
    }

    @Test("Every macOS storage category is accounted for, covered or explicitly not")
    func coverageIsComplete() {
        let shown = ["Applications", "Bin (Trash)", "Developer", "Documents", "iCloud Drive",
                     "Mail", "Messages", "Photos", "Other Users & Shared", "macOS", "System Data"]
        let mapped = Set(StorageCoverage.map.map(\.macOSCategory))
        for category in shown {
            #expect(mapped.contains(category), "\(category) is missing from the coverage map")
        }
        // Nothing is silently unexplained.
        #expect(StorageCoverage.map.allSatisfy { $0.explanation.count > 20 })
        // Anything claiming coverage must name the scanners that provide it.
        #expect(StorageCoverage.map.allSatisfy { $0.level == .notCovered || !$0.sweepCategories.isEmpty })
        // And every Sweep category appears somewhere in the map, or is listed as Sweep-only.
        let claimed = Set(StorageCoverage.map.flatMap(\.sweepCategories) + StorageCoverage.sweepOnly)
        #expect(claimed == Set(SweepCategory.allCases))
    }
}
