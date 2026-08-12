import Foundation
import Testing
@testable import SweepCore

@Suite("Scanners")
struct ScannerTests {

    @Test("Cache scanner reports per-app caches and pre-selects only the old, large ones")
    func caches() async {
        let f = Fixture()
        f.file("Library/Caches/com.example.dead/blob.bin", bytes: 20_000_000)
        f.ageTree("Library/Caches/com.example.dead", age: 90 * days)
        f.file("Library/Caches/com.example.busy/blob.bin", bytes: 20_000_000)

        var result = await CacheScanner().scan(f.context())
        result = RecommendationEngine().apply(to: [result])[0]

        let dead = result.items.first { $0.path.hasSuffix("com.example.dead") }
        let busy = result.items.first { $0.path.hasSuffix("com.example.busy") }
        #expect(dead?.risk == .safe)
        #expect(dead?.autoSelected == true)
        #expect(busy?.risk == .review)
        #expect(busy?.autoSelected == false)
        #expect(dead?.attribution == .exactBundleID)
    }

    @Test("Cache scanner never reports a running app's cache")
    func runningAppCacheHidden() async {
        let f = Fixture()
        f.file("Library/Caches/com.example.live/blob.bin", bytes: 20_000_000)
        f.ageTree("Library/Caches/com.example.live", age: 90 * days)
        let ctx = f.context(running: RunningApps(bundleIDs: ["com.example.live"]))
        let result = await CacheScanner().scan(ctx)
        #expect(result.items.isEmpty)
    }

    @Test("Developer junk expands derived data per project and leaves recent builds alone")
    func developerJunk() async {
        let f = Fixture()
        f.file("Library/Developer/Xcode/DerivedData/OldProj-abc/Build/x.o", bytes: 30_000_000)
        f.ageTree("Library/Developer/Xcode/DerivedData/OldProj-abc", age: 60 * days)
        f.file("Library/Developer/Xcode/DerivedData/NewProj-xyz/Build/x.o", bytes: 30_000_000)
        f.file(".npm/_cacache/index/x", bytes: 10_000_000)
        f.ageTree(".npm/_cacache", age: 60 * days)

        var result = await DeveloperJunkScanner().scan(f.context())
        result = RecommendationEngine().apply(to: [result])[0]

        #expect(result.items.contains { $0.displayName.contains("OldProj-abc") && $0.risk == .safe })
        #expect(result.items.contains { $0.displayName.contains("NewProj-xyz") && $0.risk == .review })
        #expect(result.items.contains { $0.displayName == "npm cache" })
    }

    @Test("Cache and developer scanners never report the same bytes twice")
    func noDoubleCounting() async {
        let f = Fixture()
        f.file("Library/Caches/CocoaPods/pod.bin", bytes: 10_000_000)
        f.ageTree("Library/Caches/CocoaPods", age: 60 * days)
        let cache = await CacheScanner().scan(f.context())
        let dev = await DeveloperJunkScanner().scan(f.context())
        let cachePaths = Set(cache.items.map(\.path))
        let devPaths = Set(dev.items.map(\.path))
        #expect(cachePaths.isDisjoint(with: devPaths))
        #expect(devPaths.contains { $0.hasSuffix("CocoaPods") })
    }

    @Test("Leftover scanner distinguishes orphans from installed apps and tiers its confidence")
    func leftovers() async {
        let f = Fixture()
        let installed = InstalledApps(bundleIDs: ["com.example.keep"], names: ["keep", "notes"])
        f.file("Library/Application Support/com.example.keep/data.bin", bytes: 5_000_000, age: 400 * days)
        f.file("Library/Application Support/com.example.gone/data.bin", bytes: 5_000_000, age: 400 * days)
        f.file("Library/Application Support/Notes/data.bin", bytes: 5_000_000, age: 400 * days)
        f.file("Library/Application Support/Wibble/data.bin", bytes: 5_000_000, age: 400 * days)
        f.file("Library/Application Support/com.apple.something/data.bin", bytes: 5_000_000, age: 400 * days)
        f.ageTree("Library/Application Support", age: 400 * days)

        var result = await LeftoverScanner().scan(f.context(installed: installed))
        result = RecommendationEngine().apply(to: [result])[0]
        let names = Set(result.items.map(\.displayName))

        #expect(!names.contains("com.example.keep"))      // installed
        #expect(!names.contains("Notes"))                 // installed, by name
        #expect(!names.contains("com.apple.something"))   // system vendor, never reported
        #expect(names.contains("com.example.gone"))
        #expect(names.contains("Wibble"))

        let gone = result.items.first { $0.displayName == "com.example.gone" }
        let wibble = result.items.first { $0.displayName == "Wibble" }
        #expect(gone?.attribution == .exactBundleID)
        #expect(gone?.risk == .safe)
        #expect(wibble?.attribution == .nameHeuristic)
        #expect(wibble?.risk == .review, "a name-only match must never be pre-selected")
    }

    @Test("Leftover scanner refuses to run rather than call everything an orphan")
    func leftoverBailsWithoutInventory() async {
        let f = Fixture()
        f.file("Library/Application Support/com.example.gone/data.bin", bytes: 5_000_000, age: 400 * days)
        let ctx = f.context(installed: InstalledApps(bundleIDs: [], names: []))
        let result = await LeftoverScanner().scan(ctx)
        #expect(result.items.isEmpty)
        #expect(result.failure != nil)
    }

    @Test("Large-file scanner finds big untouched files and never pre-selects them")
    func largeFiles() async {
        let f = Fixture()
        f.file("Movies/holiday.mov", bytes: 300_000_000, age: 400 * days)
        f.file("Movies/recent.mov", bytes: 300_000_000)
        f.file("Movies/small.mov", bytes: 1_000, age: 400 * days)

        var result = await LargeFileScanner().scan(f.context())
        result = RecommendationEngine().apply(to: [result])[0]
        #expect(result.items.map(\.displayName) == ["holiday.mov"])
        #expect(result.items.allSatisfy { !$0.autoSelected })
    }

    @Test("Screen-capture scanner matches by name pattern only, and never pre-selects")
    func screenCaptures() async {
        let f = Fixture()
        f.file("Desktop/Screenshot 2026-01-01 at 10.00.00.png", bytes: 3_000_000, age: 200 * days)
        f.file("Desktop/Screen Recording 2026-01-02.mov", bytes: 80_000_000, age: 200 * days)
        f.file("Desktop/family-photo.png", bytes: 3_000_000, age: 200 * days)

        var result = await ScreenCaptureScanner().scan(f.context())
        result = RecommendationEngine().apply(to: [result])[0]
        #expect(result.items.count == 2)
        #expect(!result.items.contains { $0.displayName == "family-photo.png" })
        #expect(result.items.allSatisfy { !$0.autoSelected })
    }

    @Test("Installer scanner only claims disk images and packages")
    func installers() async {
        let f = Fixture()
        f.file("Downloads/App.dmg", bytes: 50_000_000, age: 90 * days)
        f.file("Downloads/Tool.pkg", bytes: 50_000_000, age: 90 * days)
        f.file("Downloads/report.pdf", bytes: 50_000_000, age: 90 * days)
        var result = await InstallerScanner().scan(f.context())
        result = RecommendationEngine().apply(to: [result])[0]
        #expect(Set(result.items.map(\.displayName)) == ["App.dmg", "Tool.pkg"])
        #expect(result.items.allSatisfy { $0.risk == .safe })
    }

    @Test("A directory that vanishes mid-scan is recorded, not fatal")
    func vanishingDuringScan() async {
        let f = Fixture()
        f.file("Library/Caches/com.example.ghost/blob.bin", bytes: 5_000_000, age: 90 * days)
        let ctx = f.context()
        // Remove it after the listing would have happened but before measurement, by measuring
        // a path we delete first — the scanner must tolerate the gap.
        try? FileManager.default.removeItem(atPath: f.root + "/Library/Caches/com.example.ghost")
        let result = await CacheScanner().scan(ctx)
        #expect(result.items.isEmpty)
        #expect(result.failure == nil)
    }

    @Test("Bundle-identifier detection accepts real ids and rejects ordinary folder names")
    func bundleIDHeuristic() {
        #expect(InstalledApps.looksLikeBundleID("com.example.app"))
        #expect(InstalledApps.looksLikeBundleID("org.mozilla.firefox"))
        #expect(!InstalledApps.looksLikeBundleID("Google"))
        #expect(!InstalledApps.looksLikeBundleID("my.folder"))
        #expect(!InstalledApps.looksLikeBundleID("com..empty"))
    }
}
