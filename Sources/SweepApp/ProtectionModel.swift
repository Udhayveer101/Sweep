import AppKit
import Foundation
import Observation
import SweepCore

/// Protection state, kept beside the cleanup state rather than in a separate app.
///
/// The malware scanner runs as a *scope* of the same scan, not a second application: the
/// research found a combined scan is how security actually reaches cleanup users, provided a
/// finding breaks out of the ordinary results grid and gets its own decision.
/// (Vault: UI Integration Design.)
@MainActor
@Observable
final class ProtectionModel {
    var report: MalwareReport?
    var phase: ProtectionPhase?
    var examined: Int = 0
    var quarantined: [QuarantineEntry] = []
    var xprotect: XProtectStatus?
    var definitions: DefinitionsVersion?
    /// Findings the user has selected to quarantine.
    var selection: Set<UUID> = []
    var outcomes: [QuarantineOutcome] = []
    /// Items that stopped matching after a definitions update: offered back to the user.
    var restorable: [QuarantineEntry] = []
    var updating = false
    var updateProblems: [(feed: String, reason: String)] = []
    var errorMessage: String?
    /// Set when rule sets failed to load, so the UI can say the scan was narrower than intended.
    var ruleSetProblems: [String] = []

    private let scanner = MalwareScanner()
    private let quarantineStore = QuarantineStore()
    private let baselineStore = BaselineStore()
    private var scanTask: Task<Void, Never>?

    var findings: [Finding] { report?.findings ?? [] }
    var threats: [Finding] { report?.threats ?? [] }
    var hasThreats: Bool { !(report?.threats.isEmpty ?? true) }
    var selectedFindings: [Finding] { threats.filter { selection.contains($0.id) } }

    func load() async {
        xprotect = XProtectStatus.read()
        definitions = DefinitionsStore.load().version
        quarantined = await quarantineStore.entries()
    }

    /// Drops any previous protection result. Used when protection is switched off or a scan
    /// runs without it, so the UI never shows findings from a run that did not just happen.
    /// Quarantine contents are untouched: those are the user's, not this scan's.
    func clearResults() {
        report = nil
        phase = nil
        examined = 0
        selection = []
        outcomes = []
        ruleSetProblems = []
    }

    // MARK: - Scanning

    /// Runs a protection scan. Returns when finished so the caller can sequence it with cleanup.
    func scan() async {
        phase = .inventory
        examined = 0
        outcomes = []
        selection = []
        errorMessage = nil

        let store = DefinitionsStore.load()
        definitions = store.version
        let sets = YaraEngine.availableSets(definitionsDirectory: DefinitionsStore.defaultDirectory)
        let engine = YaraEngine(ruleSets: sets)
        ruleSetProblems = engine.failedSets.map { "\($0.name): \($0.reason)" }

        let context = ProtectionContext(
            definitions: store,
            baseline: baselineStore.load(),
            yara: engine.isLoaded ? engine : nil)

        do {
            let result = try await scanner.scan(context: context) { event in
                Task { @MainActor [weak self] in self?.apply(event) }
            }
            report = result
            selection = Set(result.findings.filter(\.autoSelected).map(\.id))
            phase = nil

            // Establish the trust baseline on the first completed scan, and never again:
            // silently re-baselining would trust anything that arrived since.
            if !baselineStore.exists {
                let hashes = Set(result.findings.compactMap(\.cdhash))
                baselineStore.establish(cdhashes: hashes)
            }
        } catch is MalwareScanner.AlreadyScanning {
            errorMessage = "A protection scan is already running."
            phase = nil
        } catch {
            errorMessage = "The protection scan could not finish: \(error.localizedDescription)"
            phase = nil
        }
    }

    private func apply(_ event: ProtectionEvent) {
        switch event {
        case .phase(let p): phase = p
        case .progress(let count, _): examined = count
        case .finished: phase = nil
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        phase = nil
    }

    // MARK: - Selection

    func toggle(_ finding: Finding) {
        if selection.contains(finding.id) { selection.remove(finding.id) } else { selection.insert(finding.id) }
    }

    // MARK: - Remediation

    /// Quarantines the selected findings. Never deletes: a detection is a fallible judgement,
    /// so the action must be reversible.
    func quarantineSelected() async {
        let items = selectedFindings
        guard !items.isEmpty else { return }
        let running = Set(ProcessInventory.running().map(\.pid))

        var results: [QuarantineOutcome] = []
        for finding in items {
            results.append(await quarantineStore.quarantine(finding, runningPIDs: running))
        }
        outcomes = results
        quarantined = await quarantineStore.entries()

        // Drop the ones that are now handled, keep the ones that were refused or failed so the
        // user can see what still needs attention.
        let handled = Set(results.filter { $0.status == .quarantined }.map(\.path))
        report?.findings.removeAll { handled.contains($0.path) }
        selection.subtract(items.filter { handled.contains($0.path) }.map(\.id))
    }

    func restore(_ entry: QuarantineEntry) async {
        let outcome = await quarantineStore.restore(entry)
        outcomes = [outcome]
        quarantined = await quarantineStore.entries()
        restorable.removeAll { $0.id == entry.id }
    }

    func discard(_ entry: QuarantineEntry) async {
        let outcome = await quarantineStore.discard(entry)
        outcomes = [outcome]
        quarantined = await quarantineStore.entries()
        restorable.removeAll { $0.id == entry.id }
    }

    // MARK: - Definitions

    /// Updates definitions, then re-checks quarantine against them.
    ///
    /// The re-check is the point: an item that no longer matches was a false positive, and it
    /// can be offered back with no user action. (Vault: False Positive Control: self-healing.)
    func updateDefinitions(authKey: String?) async {
        updating = true
        defer { updating = false }

        let updater = DefinitionsUpdater(authKey: authKey)
        let result = await updater.update()
        definitions = result.version
        updateProblems = result.problems

        guard result.changedAnything else { return }
        let store = DefinitionsStore.load()
        let sets = YaraEngine.availableSets(definitionsDirectory: DefinitionsStore.defaultDirectory)
        let engine = YaraEngine(ruleSets: sets)
        restorable = await quarantineStore.recheck(with: store, engine: engine.isLoaded ? engine : nil)
    }

    // MARK: - Actions

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }
}
