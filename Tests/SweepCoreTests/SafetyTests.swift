import Foundation
import Testing
@testable import SweepCore

@Suite("Safety engine — eligibility")
struct EligibilityTests {

    @Test("Refuses anything outside the home folder")
    func outsideHome() {
        let f = Fixture()
        #expect(f.engine.eligibility(of: "/System/Library/Caches") == .outsideHome)
        #expect(f.engine.eligibility(of: "/usr/local/lib") == .outsideHome)
        #expect(f.engine.eligibility(of: "/") == .outsideHome)
        #expect(f.engine.eligibility(of: FS.normalize(f.root + "/../elsewhere")) == .outsideHome)
    }

    @Test("Refuses the home folder itself")
    func homeRoot() {
        let f = Fixture()
        #expect(f.engine.eligibility(of: f.root) == .isHomeRoot)
        #expect(f.engine.eligibility(of: f.root + "/") == .isHomeRoot)
    }

    @Test("Refuses every immutable protected location")
    func protectedLocations() {
        let f = Fixture()
        for relative in SafetyEngine.protectedRelativePaths {
            #expect(f.engine.eligibility(of: f.root + "/" + relative) == .protectedLocation,
                    "expected \(relative) to be protected")
            #expect(f.engine.eligibility(of: f.root + "/" + relative + "/child") == .protectedLocation)
        }
    }

    @Test("A protected prefix does not over-match a sibling with the same first letters")
    func prefixIsComponentAware() {
        let f = Fixture()
        // "Library/Mail" is protected; "Library/MailSomethingElse" is a different folder.
        #expect(f.engine.eligibility(of: f.root + "/Library/MailSomethingElse") == nil)
        #expect(FS.isDescendant("/a/bc", of: "/a/b") == false)
        #expect(FS.isDescendant("/a/b/c", of: "/a/b") == true)
        #expect(FS.isDescendant("/a/b", of: "/a/b") == false)
    }

    @Test("Refuses a path whose parent is a symlink pointing outside the scope")
    func symlinkEscape() {
        let f = Fixture()
        f.dir("Library/Caches")
        f.symlink("Library/Caches/escape", to: "/etc")
        #expect(f.engine.eligibility(of: f.root + "/Library/Caches/escape") == .containsSymlink)
        #expect(f.engine.eligibility(of: f.root + "/Library/Caches/escape/passwd") == .containsSymlink)
    }

    @Test("Refuses a Photos library found anywhere in the tree")
    func photosLibraryAnywhere() {
        let f = Fixture()
        #expect(f.engine.eligibility(of: f.root + "/Pictures/Photos Library.photoslibrary/database") == .protectedLocation)
    }

    @Test("Honours the user-extensible protection tier")
    func userProtected() {
        let f = Fixture()
        var policy = SafetyPolicy()
        policy.userProtectedPaths = [f.root + "/Library/Caches/precious"]
        let engine = SafetyEngine(home: f.root, policy: policy)
        #expect(engine.eligibility(of: f.root + "/Library/Caches/precious") == .userProtected)
        #expect(engine.eligibility(of: f.root + "/Library/Caches/precious/inner") == .userProtected)
        #expect(engine.eligibility(of: f.root + "/Library/Caches/other") == nil)
    }

    @Test("Refuses data belonging to a running application")
    func runningApp() {
        let f = Fixture()
        let running = RunningApps(bundleIDs: ["com.example.live"])
        #expect(f.engine.eligibility(of: f.root + "/Library/Caches/com.example.live",
                                     runningApps: running) == .inUse)
        #expect(f.engine.eligibility(of: f.root + "/Library/Caches/com.example.live/Data",
                                     runningApps: running) == .inUse)
        #expect(f.engine.eligibility(of: f.root + "/Library/Caches/com.example.dead",
                                     runningApps: running) == nil)
    }

    @Test("Handles unicode, spaces and unusual names without refusing them incorrectly")
    func awkwardNames() {
        let f = Fixture()
        for name in ["Ünïcödé Cache", "with space", "emoji 🧹", "trailing.dots...", "-leading-dash"] {
            #expect(f.engine.eligibility(of: f.root + "/Library/Caches/" + name) == nil,
                    "unexpectedly refused \(name)")
        }
    }
}

@Suite("Safety engine — classification")
struct ClassificationTests {
    let now = Date()

    /// Evidence with only a modification date — the common case for app-written data.
    func ev(_ offset: TimeInterval, lastUsed: Date? = nil, running: Bool = false,
            metadataUnavailable: Bool = false) -> UsageEvidence {
        UsageEvidence(lastUsed: lastUsed, modified: now.addingTimeInterval(offset),
                      isRunning: running, metadataUnavailable: metadataUnavailable)
    }

    @Test("Old, large, regenerable cache is safe")
    func safeCache() {
        let f = Fixture()
        let v = f.engine.classify(
            path: f.root + "/Library/Caches/com.example.dead", category: .userCaches,
            evidence: ev(-60 * days), bytes: 50_000_000,
            attribution: .exactBundleID, now: now)
        #expect(v.risk == .safe)
        #expect(!v.rationale.isEmpty)
    }

    @Test("Recently written cache is shown but never auto-selected")
    func recentCache() {
        let f = Fixture()
        let v = f.engine.classify(
            path: f.root + "/Library/Caches/com.example.dead", category: .userCaches,
            evidence: ev(-2 * days), bytes: 50_000_000,
            attribution: .exactBundleID, now: now)
        #expect(v.risk == .review)
    }

    @Test("Small items are not worth pre-selecting")
    func tinyItem() {
        let f = Fixture()
        let v = f.engine.classify(
            path: f.root + "/Library/Caches/tiny", category: .userCaches,
            evidence: ev(-300 * days), bytes: 1_000,
            attribution: .exactBundleID, now: now)
        #expect(v.risk == .review)
    }

    @Test("User-authored categories are never safe, no matter how old")
    func userFilesNeverAutoSelected() {
        let f = Fixture()
        for category in [SweepCategory.largeOldFiles, .screenRecordings] {
            let v = f.engine.classify(
                path: f.root + "/Documents/thesis.mov", category: category,
                evidence: ev(-3650 * days), bytes: 5_000_000_000,
                attribution: nil, now: now)
            #expect(v.risk == .review, "\(category) must never be auto-selectable")
        }
    }

    @Test("A leftover matched only by name is never auto-selected")
    func nameHeuristicIsNeverSafe() {
        let f = Fixture()
        let v = f.engine.classify(
            path: f.root + "/Library/Application Support/Something", category: .appLeftovers,
            evidence: ev(-999 * days), bytes: 500_000_000,
            attribution: .nameHeuristic, now: now)
        #expect(v.risk == .review)
    }

    @Test("An unattributable leftover is classified unknown, and unknown is never deleted")
    func unknownStaysUnknown() {
        let f = Fixture()
        let v = f.engine.classify(
            path: f.root + "/Library/Application Support/Mystery", category: .appLeftovers,
            evidence: ev(-999 * days), bytes: 500_000_000,
            attribution: nil, now: now)
        #expect(v.risk == .unknown)
    }

    @Test("Protected paths classify as protected regardless of category or age")
    func protectedBeatsEverything() {
        let f = Fixture()
        let v = f.engine.classify(
            path: f.root + "/Library/Keychains/login.keychain-db", category: .userCaches,
            evidence: ev(-9999 * days), bytes: 900_000_000,
            attribution: .exactBundleID, now: now)
        #expect(v.risk == .protected)
    }
}
