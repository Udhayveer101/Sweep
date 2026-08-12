import Foundation
import Testing
@testable import SweepCore

/// Performance measurements against the real home folder. Read-only — scanners never delete —
/// but slow and machine-dependent, so they are opt-in:
///
///     SWEEP_PERF=1 swift test --filter Performance
private let perfEnabled = ProcessInfo.processInfo.environment["SWEEP_PERF"] != nil

@Suite("Performance", .enabled(if: perfEnabled), .serialized)
struct PerformanceTests {

    @Test("Per-scanner timing on the real home folder")
    func perScanner() async {
        let ctx = ScanContext(installed: InstalledApps.scanDisk())
        for scanner in defaultScanners {
            let start = Date()
            let result = await scanner.scan(ctx)
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "%-22@ %6.2fs  %5d items  %@",
                         scanner.category.rawValue as NSString, elapsed,
                         result.items.count, Format.bytes(result.totalBytes)))
        }
    }

    @Test("Whole-scan wall clock at different concurrency limits")
    func concurrency() async throws {
        let ctx = ScanContext(installed: InstalledApps.scanDisk())
        for limit in [1, 4, 8] {
            let start = Date()
            let report = try await ScanOrchestrator(maxConcurrent: limit).scan(context: ctx)
            print(String(format: "concurrency %d: %6.2fs, %d items, %@",
                         limit, Date().timeIntervalSince(start),
                         report.allItems.count, Format.bytes(report.totalBytes)))
        }
    }

    @Test("A scan can be cancelled promptly")
    func cancellationIsPrompt() async throws {
        let ctx = ScanContext(installed: InstalledApps.scanDisk())
        let orchestrator = ScanOrchestrator()
        let start = Date()
        let task = Task { try await orchestrator.scan(context: ctx) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = try? await task.value
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "cancelled after %.2fs", elapsed))
        #expect(elapsed < 20, "cancellation should not wait for the whole scan")
    }
}
