import SwiftUI
import SweepCore

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            BrandMark(size: 88)

            VStack(spacing: 8) {
                Text("Sweep")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Finds files your Mac no longer needs, explains why, and moves them to the Trash so you can change your mind.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Button(action: model.startScan) {
                Text("Scan").frame(width: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            StoragePanel()

            if model.fullDiskAccess == .denied {
                PermissionBanner()
            }

            if let last = model.history.first {
                Text("Last cleanup \(last.finished.formatted(.relative(presentation: .named))) — \(Format.bytes(last.verifiedBytesFreed)) freed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HistoryStrip()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PermissionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sweep does not have Full Disk Access", systemImage: "lock")
                .font(.headline)
            Text(FullDiskAccess.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Privacy & Security…") { model.openFullDiskAccessSettings() }
                Button("Scan anyway") { model.startScan() }
                    .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct HistoryStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.history.isEmpty {
            let total = model.history.reduce(0) { $0 + $1.verifiedBytesFreed }
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                Text("\(model.history.count) previous cleanup(s), \(Format.bytes(total)) freed in total.")
                Text("Stored only on this Mac.").foregroundStyle(.tertiary)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Scanning

struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Looking through your home folder…")
                .font(.title3)
            Text("Nothing is deleted during a scan.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(SweepCategory.allCases, id: \.self) { category in
                    HStack(spacing: 8) {
                        if model.completedCategories.contains(category) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if model.scanningCategories.contains(category) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
                        }
                        Text(category.title)
                            .foregroundStyle(model.completedCategories.contains(category) ? .primary : .secondary)
                        Spacer()
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(width: 320)
            .padding(16)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))

            Button("Cancel", role: .cancel) { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Results

struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let report = model.report, report.allItems.isEmpty {
                EmptyResultsView(report: report)
            } else {
                // An explicit two-pane layout rather than NavigationSplitView: the split view
                // negotiates its own window sizing and pushed the detail column outside the
                // window frame in this single-window app.
                HStack(spacing: 0) {
                    CategorySidebar()
                        .frame(width: 270)
                    Divider()
                    Group {
                        if let category = model.expandedCategory {
                            ItemList(category: category)
                        } else {
                            ContentUnavailableView("Select a category", systemImage: "sidebar.left")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            ResultsFooter(confirming: $confirming)
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button(model.settings.deletePermanently ? "Delete Permanently" : "Move to Trash",
                   role: .destructive) { model.runCleanup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmTitle: String {
        "Clean \(model.selectedItems.count) item(s), \(Format.bytes(model.selectedBytes))?"
    }

    private var confirmMessage: String {
        let trashPart = model.settings.deletePermanently
            ? "These will be deleted permanently and cannot be recovered. You turned this on in Settings."
            : "Everything goes to the Trash, so you can put it back. Sweep also offers a 15-second undo afterwards."
        let trashCategory = model.selectedItems.contains { $0.category == .trash }
            ? " Items already in the Trash are removed permanently — that is what emptying the Trash means."
            : ""
        return trashPart + trashCategory
    }
}

struct EmptyResultsView: View {
    let report: ScanReport

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.green)
            Text("Nothing worth cleaning").font(.title2)
            Text("Sweep looked in every location it covers and found nothing it would recommend removing. That is a good result, not an error.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if report.limitedByPermissions {
                Text("Some locations were hidden from Sweep by macOS. Granting Full Disk Access would let it look in those too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CategorySidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.expandedCategory) {
            ForEach(model.report?.categories ?? []) { result in
                CategoryRow(result: result)
                    .tag(result.category)
            }
        }
        .listStyle(.sidebar)
    }
}

struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let result: CategoryResult

    var body: some View {
        HStack(spacing: 10) {
            // A genuine tri-state control: a partly-selected category clears on click rather
            // than expanding the selection, which is the destructive direction to guess wrong.
            Button {
                let state = model.selectionState(for: result.category)
                model.setSelection(for: result.category, selected: state == false)
            } label: {
                Image(systemName: checkboxSymbol)
                    .foregroundStyle(model.selectionState(for: result.category) == false
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .disabled(result.items.isEmpty)
            .help(selectionHelp)
            .accessibilityLabel("\(result.category.title): \(selectionHelp)")

            VStack(alignment: .leading, spacing: 2) {
                Text(result.category.title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // A blocked category has no honest number to show, so it shows none.
            Text(result.wasBlocked && result.items.isEmpty ? "—" : Format.bytes(result.totalBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(result.items.isEmpty ? .tertiary : .secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var checkboxSymbol: String {
        switch model.selectionState(for: result.category) {
        case true: "checkmark.square.fill"
        case false: "square"
        default: "minus.square.fill"
        }
    }

    private var selectionHelp: String {
        switch model.selectionState(for: result.category) {
        case true: "everything selected — click to clear"
        case false: "nothing selected — click to select all"
        default: "partly selected — click to clear"
        }
    }

    private var subtitle: String {
        if result.failure != nil { return "Could not be scanned" }
        if result.wasBlocked && result.items.isEmpty { return "Blocked by macOS" }
        if result.items.isEmpty { return "Nothing found" }
        let selected = result.items.filter { model.selection.contains($0.id) }.count
        return "\(selected) of \(result.items.count) selected"
    }
}

struct ItemList: View {
    @Environment(AppModel.self) private var model
    let category: SweepCategory

    var body: some View {
        let result = model.result(for: category)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(category.title).font(.title2)
                Text(category.consequence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = result?.failure {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let skipped = result?.skipped, !skipped.isEmpty {
                    SkipSummary(skipped: skipped)
                }
            }
            .padding(20)

            Divider()

            if model.items(in: category).isEmpty {
                if result?.wasBlocked == true {
                    BlockedRootNotice(roots: result?.unreadableRoots ?? [])
                } else {
                    ContentUnavailableView("Nothing found here", systemImage: "tray",
                                           description: Text("Sweep checked this category and found nothing."))
                }
            } else {
                List {
                    ForEach(model.items(in: category)) { item in
                        ItemRow(item: item)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct SkipSummary: View {
    @Environment(AppModel.self) private var model
    let skipped: [SkipRecord]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(skipped.prefix(50), id: \.self) { record in
                    Text("\(describe(record.reason)) — \(record.path)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if skipped.count > 50 {
                    Text("…and \(skipped.count - 50) more.").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("\(skipped.count) location(s) could not be read")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func describe(_ reason: SkipRecord.Reason) -> String {
        switch reason {
        case .permissionDenied, .notPermittedNeedsFullDiskAccess: "macOS denied access"
        case .vanished: "disappeared while scanning"
        case .unreadable: "unreadable"
        case .crossedVolume: "on another volume"
        case .symlink: "is a link"
        case .depthLimit: "nested too deeply"
        case .budgetExceeded: "too many files to measure fully"
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: Item
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { model.selection.contains(item.id) },
                                         set: { _ in model.toggle(item) }))
                    .labelsHidden()
                    .disabled(item.risk == .protected)
                    .accessibilityLabel("Select \(item.displayName)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).lineLimit(1).truncationMode(.middle)
                    Text("\(item.fileCount) file(s) · last changed \(item.modified.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ConfidenceBadge(confidence: item.confidence)
                RiskBadge(risk: item.risk)
                Text(Format.bytes(item.bytes))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 72, alignment: .trailing)
                Button {
                    showDetail.toggle()
                } label: {
                    Image(systemName: showDetail ? "chevron.up" : "info.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Why Sweep suggests this")
            }

            if showDetail {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.rationale, id: \.self) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(r.rule).font(.caption.bold()).frame(width: 110, alignment: .leading)
                            Text(r.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if model.settings.showTechnicalDetail {
                        Text(item.path).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    Button("Reveal in Finder") { model.reveal(item.path) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.leading, 30)
                .padding(.bottom, 4)
            }
        }
        .contextMenu {
            Button("Reveal in Finder") { model.reveal(item.path) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
    }
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Risk: \(label)")
    }

    private var label: String {
        switch risk {
        case .safe: "Safe"
        case .review: "Your call"
        case .unknown: "Unidentified"
        case .protected: "Protected"
        }
    }

    private var color: Color {
        switch risk {
        case .safe: .green
        case .review: .orange
        case .unknown: .secondary
        case .protected: .red
        }
    }
}

struct ResultsFooter: View {
    @Environment(AppModel.self) private var model
    @Binding var confirming: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectedItems.count) item(s) selected — \(Format.bytes(model.selectedBytes))")
                    .font(.callout.monospacedDigit())
                if let report = model.report {
                    Text(footnote(report)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(model.selection.isEmpty ? "Select Recommended" : "Clear Selection") {
                model.selection.isEmpty ? model.selectRecommended() : model.clearSelection()
            }
            Button("Start Over") { model.reset() }
            Button(model.settings.deletePermanently ? "Delete…" : "Move to Trash…") {
                confirming = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedItems.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func footnote(_ report: ScanReport) -> String {
        var parts = ["Found \(Format.bytes(report.totalBytes)) in total"]
        if report.limitedByPermissions { parts.append("some locations were hidden by macOS") }
        if report.partial { parts.append("the scan finished only partly") }
        return parts.joined(separator: " · ") + "."
    }
}

// MARK: - Cleaning

struct CleaningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if let progress = model.cleanupProgress, progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .frame(width: 320)
                Text(progress.current).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(width: 320)
                Text("\(progress.completed) of \(progress.total)").font(.caption).foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.large)
                Text("Cleaning up…").font(.title3)
            }
            Button("Stop", role: .cancel) { model.cancelCleanup() }
            Text("Stopping keeps whatever has already been moved to the Trash.")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Done

struct DoneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let report = model.cleanupReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(report)
                        // Shown for as long as the items are still recoverable, not just during
                        // the countdown — a grace period that expires while the user is reading
                        // is a cliff, not a safety net.
                        if report.recoverable || model.undoResult != nil {
                            UndoBanner()
                        }
                        if !report.problems.isEmpty {
                            ProblemList(problems: report.problems)
                        }
                        if !report.succeeded.isEmpty {
                            SucceededList(outcomes: report.succeeded)
                        }
                    }
                    .padding(24)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.reset() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func header(_ report: CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(report.cancelled ? "Cleanup stopped" : "Cleanup finished")
                .font(.title2)
            // The headline number is what verification confirmed is gone, not what was attempted.
            Text("\(Format.bytes(report.verifiedBytesFreed)) freed, confirmed by re-checking each item after removal.")
                .foregroundStyle(.secondary)
            if !report.problems.isEmpty {
                Text("\(report.problems.count) item(s) were left alone. Each one is listed below with the reason.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct UndoBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = model.undoResult {
                Label("Put \(result.restored.count) item(s) back", systemImage: "arrow.uturn.backward")
                    .font(.headline)
                if !result.failed.isEmpty {
                    ForEach(result.failed, id: \.path) { failure in
                        Text("\(( failure.path as NSString).lastPathComponent): \(failure.reason)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Label("Everything went to the Trash", systemImage: "trash")
                        .font(.headline)
                    Spacer()
                    Button(model.undoSecondsRemaining > 0
                           ? "Put Everything Back (\(model.undoSecondsRemaining))"
                           : "Put Everything Back") { model.undoCleanup() }
                        .buttonStyle(.borderedProminent)
                    if model.undoSecondsRemaining > 0 {
                        Button("Keep") { model.dismissUndo() }
                    }
                }
                Text("This stays available while you are on this screen. Afterwards the items remain in the Trash, so you can still recover them there until you empty it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProblemList: View {
    let problems: [ItemOutcome]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Left alone").font(.headline)
            ForEach(problems) { outcome in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: outcome.status == .failed ? "xmark.circle" : "minus.circle")
                        .foregroundStyle(outcome.status == .failed ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.displayName)
                        Text(outcome.reason ?? "No reason recorded.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct SucceededList: View {
    let outcomes: [ItemOutcome]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(outcomes) { outcome in
                    HStack {
                        Text(outcome.displayName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(outcome.status == .deleted ? "deleted" : "in Trash")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Format.bytes(outcome.bytes)).font(.caption.monospacedDigit())
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("\(outcomes.count) item(s) removed").font(.headline)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Section("Protected paths") {
                    Text("Sweep never touches these, on top of the locations it always protects.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.settings.protectedPaths, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove") {
                                model.settings.protectedPaths.removeAll { $0 == path }
                                model.saveSettings()
                            }
                            .buttonStyle(.link)
                        }
                    }
                    Button("Add…") { model.addProtectedPath() }
                }
                Section("Advanced") {
                    Toggle("Show file paths and technical detail", isOn: $model.settings.showTechnicalDetail)
                        .onChange(of: model.settings.showTechnicalDetail) { model.saveSettings() }
                    Toggle("Delete permanently instead of moving to the Trash",
                           isOn: $model.settings.deletePermanently)
                        .onChange(of: model.settings.deletePermanently) { model.saveSettings() }
                    Text("Leaving this off is what makes a mistaken cleanup recoverable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 520, height: 420)
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading) {
            if model.history.isEmpty {
                ContentUnavailableView("No cleanups yet", systemImage: "clock",
                                       description: Text("Sweep records every cleanup here, on this Mac only."))
            } else if query.isEmpty {
                List {
                    ForEach(model.history) { report in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.finished.formatted(date: .abbreviated, time: .shortened))
                            Text("\(Format.bytes(report.verifiedBytesFreed)) freed · \(report.succeeded.count) removed · \(report.problems.count) left alone")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .searchable(text: $query, prompt: "Search cleaned items")
            } else {
                let matches = model.searchHistory(query)
                List {
                    if matches.isEmpty {
                        Text("Nothing matches “\(query)”.").foregroundStyle(.secondary)
                    }
                    ForEach(matches) { outcome in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outcome.displayName).lineLimit(1).truncationMode(.middle)
                            Text("\(outcome.category.title) · \(Format.bytes(outcome.bytes)) · \(outcome.status.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .searchable(text: $query, prompt: "Search cleaned items")
            }
        }
        .padding()
    }
}

// MARK: - Blocked locations

/// Shown where a category would otherwise render as "nothing found". macOS refusing to let
/// Sweep read a folder must never be presented as that folder being empty.
struct BlockedRootNotice: View {
    @Environment(AppModel.self) private var model
    let roots: [String]

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.circle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.orange)
            Text("Sweep could not look here").font(.title3)
            Text("macOS blocked access to \(roots.count == 1 ? "this location" : "these locations"). "
                 + "This is not the same as the location being empty — Sweep does not know what is inside.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(roots, id: \.self) { root in
                    Text(root)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Button("Open Privacy & Security…") { model.openFullDiskAccessSettings() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Confidence

struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .help(explanation)
            .accessibilityLabel("Evidence: \(label). \(explanation)")
    }

    private var label: String {
        switch confidence {
        case .high: "Strong evidence"
        case .medium: "Good evidence"
        case .low: "Weak evidence"
        case .none: "No evidence"
        }
    }

    private var symbol: String {
        switch confidence {
        case .high: "checkmark.seal"
        case .medium: "info.circle"
        case .low: "questionmark.circle"
        case .none: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch confidence {
        case .high: .green
        case .medium: .secondary
        case .low: .orange
        case .none: .red
        }
    }

    private var explanation: String {
        switch confidence {
        case .high: "macOS records this being opened, or its app is running right now."
        case .medium: "No open-record, but this is app-written data whose write time is a sound signal."
        case .low: "Only timestamps that do not establish whether it is used."
        case .none: "Sweep could not gather usable evidence, so it will not act on this."
        }
    }
}

// MARK: - Storage overview

/// Presents the volume's current figures on the same basis System Settings uses.
///
/// Refreshed every time this view appears, plus on app activation, wake, and volume
/// mount/unmount (see `AppModel.refreshStorage`). A read costs ~0.002 ms, so the figures are
/// simply always current — there is no cache to go stale and no loading state to show.
struct StoragePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This Mac").font(.headline)
                Spacer()
                Button("What Sweep covers…") { model.showingCoverage = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }

            if let storage = model.storage {
                HStack(spacing: 18) {
                    figure("Capacity", storage.totalCapacity)
                    figure("Used", storage.usedCapacity)
                    figure("Free", storage.freeCapacity)
                }
                if storage.reclaimableByMacOS > 0 {
                    Text("Free space includes \(Format.bytes(storage.reclaimableByMacOS)) macOS can reclaim by itself — caches, local snapshots and files already stored in iCloud. Counting it as free is what System Settings does too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Read from this volume \(storage.measuredAt.formatted(date: .omitted, time: .standard)).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Figures read at \(storage.measuredAt.formatted(date: .omitted, time: .standard))")
            } else {
                Label(model.storageError ?? "Storage information is unavailable.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        // Every appearance of this panel re-reads the system figures.
        .onAppear { model.refreshStorage() }
        .sheet(isPresented: $model.showingCoverage) {
            CoverageSheet().onAppear { model.refreshStorage() }
        }
    }

    private func figure(_ label: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Format.bytes(bytes)).font(.callout.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CoverageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What Sweep covers").font(.title2)
                Text("These are the categories macOS shows in System Settings › Storage. Sweep works only inside your home folder and never estimates areas it cannot measure, so several rows below carry no number by design.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            List(StorageCoverage.map) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.macOSCategory).font(.headline)
                        Spacer()
                        CoverageBadge(level: entry.level)
                    }
                    Text(entry.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !entry.sweepCategories.isEmpty {
                        Text("Sweep looks at: " + entry.sweepCategories.map(\.title).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
    }
}

struct CoverageBadge: View {
    let level: CoverageEntry.Level

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch level {
        case .covered: "Covered"
        case .partial: "Partly covered"
        case .notCovered: "Out of scope"
        }
    }

    private var color: Color {
        switch level {
        case .covered: .green
        case .partial: .orange
        case .notCovered: .secondary
        }
    }
}
