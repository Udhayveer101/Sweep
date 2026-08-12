import AppKit
import Foundation
import Observation
import SweepCore

/// The one place UI state lives. Everything expensive happens off the main actor; only the
/// resulting values are published back here.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case cleaning
        case done
    }

    var phase: Phase = .idle
    var report: ScanReport?
    var cleanupReport: CleanupReport?
    var selection: Set<UUID> = []
    var expandedCategory: SweepCategory?
    var scanningCategories: Set<SweepCategory> = []
    var completedCategories: Set<SweepCategory> = []
    var cleanupProgress: (completed: Int, total: Int, current: String)?
    var errorMessage: String?
    var settings = Settings.load(from: Settings.defaultURL)
    var fullDiskAccess: FullDiskAccess.Status = .indeterminate
    var history: [CleanupReport] = []
    var undoSecondsRemaining: Int = 0
    var undoResult: Restorer.Result?

    private let orchestrator = ScanOrchestrator()
    private let historyStore = HistoryStore()
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?

    // MARK: - Derived

    var selectedItems: [Item] {
        (report?.allItems ?? []).filter { selection.contains($0.id) }
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    func items(in category: SweepCategory) -> [Item] {
        report?.categories.first { $0.category == category }?.items ?? []
    }

    func result(for category: SweepCategory) -> CategoryResult? {
        report?.categories.first { $0.category == category }
    }

    // MARK: - Lifecycle

    func load() async {
        fullDiskAccess = FullDiskAccess.status()
        history = await historyStore.all()
    }

    // MARK: - Scanning

    func startScan() {
        guard !isBusy else { return }
        phase = .scanning
        report = nil
        cleanupReport = nil
        selection = []
        scanningCategories = []
        completedCategories = []
        errorMessage = nil

        let context = makeContext()
        scanTask = Task { [orchestrator] in
            do {
                let report = try await orchestrator.scan(context: context) { event in
                    Task { @MainActor [weak self] in self?.apply(event) }
                }
                await MainActor.run {
                    self.report = report
                    self.selection = Set(report.allItems.filter(\.autoSelected).map(\.id))
                    self.expandedCategory = report.categories.first { !$0.items.isEmpty }?.category
                    self.phase = .results
                }
            } catch is CancellationError {
                await MainActor.run { self.phase = .idle }
            } catch {
                await MainActor.run {
                    self.errorMessage = "The scan could not start: \(error.localizedDescription)"
                    self.phase = .idle
                }
            }
        }
    }

    private func apply(_ event: ScanEvent) {
        switch event {
        case .started(let category):
            scanningCategories.insert(category)
        case .progress:
            break
        case .finished(let result):
            scanningCategories.remove(result.category)
            completedCategories.insert(result.category)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
    }

    /// Built fresh for every scan so a newly quit app is not treated as still running.
    private func makeContext() -> ScanContext {
        var policy = settings.policy
        policy.userProtectedPaths = Set(settings.protectedPaths)
        let running = RunningApps(
            bundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            bundlePaths: Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }))
        return ScanContext(home: NSHomeDirectory(),
                           safety: SafetyEngine(home: NSHomeDirectory(), policy: policy),
                           runningApps: running,
                           installed: InstalledApps.scanDisk())
    }

    // MARK: - Selection

    func toggle(_ item: Item) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func setSelection(for category: SweepCategory, selected: Bool) {
        for item in items(in: category) where item.risk != .protected {
            if selected { selection.insert(item.id) } else { selection.remove(item.id) }
        }
    }

    func clearSelection() { selection = [] }

    func selectRecommended() {
        selection = Set((report?.allItems ?? []).filter(\.autoSelected).map(\.id))
    }

    func selectionState(for category: SweepCategory) -> Bool? {
        let ids = items(in: category).map(\.id)
        guard !ids.isEmpty else { return false }
        let n = ids.filter { selection.contains($0) }.count
        return n == 0 ? false : (n == ids.count ? true : nil)
    }

    // MARK: - Cleanup

    func runCleanup() {
        guard !isBusy, !selectedItems.isEmpty else { return }
        phase = .cleaning
        let items = selectedItems
        let executor = CleanupExecutor(
            safety: SafetyEngine(home: NSHomeDirectory(), policy: currentPolicy()),
            permanentOverride: settings.deletePermanently)
        let running = RunningApps(
            bundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))

        cleanupTask = Task.detached(priority: .userInitiated) { [historyStore] in
            let report = executor.run(items: items, runningApps: running) { event in
                if case .progress(let completed, let total, let current) = event {
                    Task { @MainActor [weak self] in
                        self?.cleanupProgress = (completed, total, current)
                    }
                }
            }
            await historyStore.record(report)
            let all = await historyStore.all()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cleanupReport = report
                self.history = all
                self.cleanupProgress = nil
                self.phase = .done
                if report.recoverable { self.startUndoWindow() }
            }
        }
    }

    func cancelCleanup() {
        cleanupTask?.cancel()
    }

    private func currentPolicy() -> SafetyPolicy {
        var policy = settings.policy
        policy.userProtectedPaths = Set(settings.protectedPaths)
        return policy
    }

    // MARK: - Undo

    /// A visible grace period after every cleanup. The items are already in the Trash, so this
    /// is a genuine one-click restore rather than a progress bar the user must interrupt.
    private func startUndoWindow(seconds: Int = 15) {
        undoSecondsRemaining = seconds
        undoTask?.cancel()
        undoTask = Task { @MainActor in
            while undoSecondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                undoSecondsRemaining -= 1
            }
        }
    }

    func undoCleanup() {
        guard let report = cleanupReport else { return }
        undoTask?.cancel()
        undoSecondsRemaining = 0
        let result = Restorer().restore(report)
        undoResult = result
    }

    func dismissUndo() {
        undoTask?.cancel()
        undoSecondsRemaining = 0
    }

    /// Searches the locally-stored cleanup history. Kept in-memory: the history is already
    /// loaded and small enough that a round trip to the store would only add latency.
    func searchHistory(_ query: String) -> [ItemOutcome] {
        let q = query.lowercased()
        guard !q.isEmpty else { return history.flatMap(\.outcomes) }
        return history.flatMap(\.outcomes).filter {
            $0.displayName.lowercased().contains(q)
                || $0.path.lowercased().contains(q)
                || $0.category.title.lowercased().contains(q)
        }
    }

    // MARK: - Actions

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }

    func addProtectedPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or folders Sweep must never touch."
        guard panel.runModal() == .OK else { return }
        settings.protectedPaths.append(contentsOf: panel.urls.map(\.path))
        settings.protectedPaths = Array(Set(settings.protectedPaths)).sorted()
        saveSettings()
    }

    func saveSettings() {
        settings.save(to: Settings.defaultURL)
    }

    func reset() {
        phase = .idle
        report = nil
        cleanupReport = nil
        selection = []
        undoResult = nil
        dismissUndo()
    }
}
