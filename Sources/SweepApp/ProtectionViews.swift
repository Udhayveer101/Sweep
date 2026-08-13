import SwiftUI
import SweepCore

// MARK: - Threat banner

/// Shown above the cleanup results when the protection scan found something.
///
/// A threat must break out of the ordinary results grid rather than sitting beside "3 duplicate
/// files": junk is a quantity, malware is a category, and they deserve different decisions.
/// (Vault: UI Integration Design.)
struct ThreatBanner: View {
    @Environment(AppModel.self) private var model
    @State private var showingDetail = false

    var body: some View {
        let protection = model.protection
        if protection.hasThreats {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(protection))
                        .font(.headline)
                    Text(subhead(protection))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review…") { showingDetail = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.35)))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .accessibilityElement(children: .combine)
            .sheet(isPresented: $showingDetail) { ProtectionDetailView() }
        }
    }

    private func headline(_ protection: ProtectionModel) -> String {
        let actionable = protection.report?.actionable.count ?? 0
        if actionable > 0 {
            return "\(actionable) item(s) match known malware"
        }
        return "\(protection.threats.count) item(s) worth reviewing"
    }

    private func subhead(_ protection: ProtectionModel) -> String {
        let actionable = protection.report?.actionable.count ?? 0
        if actionable > 0 {
            return "Sweep can move these to quarantine, where you can put them back."
        }
        return "Nothing matches known malware. These are unusual enough to be worth your eyes."
    }
}

// MARK: - Protection summary (clean state)

/// The zero-findings state — roughly 99% of scans, and the screen that has to earn trust.
///
/// Deliberately quiet and factual. It reports what was examined, what was not, and how old the
/// definitions are; it never says "you are protected", because Sweep cannot know that.
/// (Vault: Security Scan UX Principles, rules 1–3.)
struct ProtectionSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let protection = model.protection
        if let report = protection.report, !protection.hasThreats {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: report.isTrulyClean ? "checkmark.shield" : "shield.lefthalf.filled")
                        .foregroundStyle(report.isTrulyClean ? .green : .secondary)
                        .accessibilityHidden(true)
                    Text("No known threats found")
                        .font(.headline)
                }
                Text(coverage(report))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let definitions = protection.definitions {
                    Text(definitionsLine(definitions))
                        .font(.footnote)
                        .foregroundStyle(definitions.isStale() ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                } else {
                    Text("No threat definitions have been downloaded yet, so only macOS's own signals were used.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let xprotect = protection.xprotect {
                    Text("macOS protection: \(xprotect.summary)")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        }
    }

    private func coverage(_ report: MalwareReport) -> String {
        var parts = ["Examined \(report.coverage.artifactsExamined) program(s) and script(s)"]
        if report.coverage.artifactsTrusted > 0 {
            parts.append("\(report.coverage.artifactsTrusted) were signed by Apple or an identified developer")
        }
        var text = parts.joined(separator: "; ") + "."
        // "Could not look" must never read as "found nothing".
        if !report.coverage.unreadable.isEmpty {
            text += " \(report.coverage.unreadable.count) location(s) could not be read — those were not checked."
        }
        if report.cancelled { text += " The scan was stopped early, so this is a partial result." }
        return text
    }

    private func definitionsLine(_ definitions: DefinitionsVersion) -> String {
        definitions.isStale()
            ? "Threat definitions are out of date (\(definitions.summary)). Update them for a fuller check."
            : "Threat definitions: \(definitions.summary)."
    }
}

// MARK: - Detail

struct ProtectionDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var expanded: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Protection")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)

            Divider()

            List {
                if !model.protection.threats.isEmpty {
                    Section("Found") {
                        ForEach(model.protection.threats) { finding in
                            FindingRow(finding: finding, expanded: $expanded)
                        }
                    }
                }
                let unchecked = model.protection.findings.filter { $0.threat == .unknown }
                if !unchecked.isEmpty {
                    Section("Not checked") {
                        ForEach(unchecked) { finding in
                            FindingRow(finding: finding, expanded: $expanded)
                        }
                    }
                }
                if !model.protection.quarantined.isEmpty {
                    Section("Quarantined") {
                        ForEach(model.protection.quarantined) { entry in
                            QuarantineRow(entry: entry)
                        }
                    }
                }
                if !model.protection.outcomes.isEmpty {
                    Section("Results") {
                        ForEach(model.protection.outcomes) { outcome in
                            OutcomeRow(outcome: outcome)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            ProtectionFooter(confirming: $confirming)
        }
        .frame(minWidth: 680, minHeight: 480)
        .confirmationDialog("Quarantine \(model.protection.selectedFindings.count) item(s)?",
                            isPresented: $confirming) {
            Button("Move to Quarantine", role: .destructive) {
                Task { await model.protection.quarantineSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing is deleted. Each item is moved somewhere it cannot run, and you can put any of them back from this window.")
        }
    }
}

/// One finding, with its evidence available in a click.
///
/// Every row can answer "why was this flagged?" — the malware analogue of the cleanup side's
/// per-item rationale, which the app already surfaces.
struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: Finding
    @Binding var expanded: UUID?

    private var isExpanded: Bool { expanded == finding.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if finding.threat.isThreat {
                    Toggle("", isOn: Binding(
                        get: { model.protection.selection.contains(finding.id) },
                        set: { _ in model.protection.toggle(finding) }))
                    .labelsHidden()
                    .accessibilityLabel("Select \(finding.displayName)")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.displayName).font(.body.weight(.medium))
                    Text(finding.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                ThreatBadge(threat: finding.threat, confidence: finding.confidence)
            }

            Text(finding.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(isExpanded ? "Hide evidence" : "Show evidence") {
                    expanded = isExpanded ? nil : finding.id
                }
                .buttonStyle(.link)
                .font(.caption)
                Button("Reveal in Finder") { model.protection.reveal(finding.path) }
                    .buttonStyle(.link)
                    .font(.caption)
                if let pid = finding.runningPID {
                    Text("Running now (pid \(pid))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(finding.signals.enumerated()), id: \.offset) { _, signal in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .padding(.top, 6)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(signal.detail).font(.caption)
                                Text(signal.name.map { "\(signal.source) — \($0)" } ?? signal.source)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let persistence = finding.persistence {
                        Text("Startup entry: \(persistence.configPath)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(finding.threat.meaning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
    }
}

struct ThreatBadge: View {
    let threat: ThreatClass
    let confidence: ThreatConfidence

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(threat.title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(0.18), in: Capsule())
                .foregroundStyle(tint)
            Text(confidenceText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(threat.title), \(confidenceText)")
    }

    private var tint: Color {
        switch threat {
        case .knownMalware, .maliciousPersistence: .red
        case .suspicious: .orange
        case .pua: .yellow
        case .unknown: .secondary
        case .clean: .green
        }
    }

    private var confidenceText: String {
        switch confidence {
        case .high: "certain"
        case .medium: "likely"
        case .low: "unconfirmed"
        }
    }
}

struct QuarantineRow: View {
    @Environment(AppModel.self) private var model
    let entry: QuarantineEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.body)
                Text(entry.originalPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Quarantined \(entry.quarantined.formatted(.relative(presentation: .named)))"
                     + (entry.detectionName.map { " — \($0)" } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Put Back") { Task { await model.protection.restore(entry) } }
            Button("Delete") { Task { await model.protection.discard(entry) } }
                .foregroundStyle(.red)
        }
        .padding(.vertical, 2)
    }
}

struct OutcomeRow: View {
    let outcome: QuarantineOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(outcome.displayName).font(.callout)
                if let reason = outcome.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch outcome.status {
        case .quarantined: "shield.fill"
        case .restored: "arrow.uturn.backward.circle"
        case .refused: "hand.raised"
        case .failed: "exclamationmark.triangle"
        case .needsRestart: "arrow.clockwise.circle"
        }
    }

    private var tint: Color {
        switch outcome.status {
        case .quarantined, .restored: .green
        case .refused, .needsRestart: .orange
        case .failed: .red
        }
    }
}

struct ProtectionFooter: View {
    @Environment(AppModel.self) private var model
    @Binding var confirming: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let definitions = model.protection.definitions {
                    Text("Definitions: \(definitions.summary)")
                        .font(.caption)
                        .foregroundStyle(definitions.isStale() ? .orange : .secondary)
                } else {
                    Text("No threat definitions downloaded yet.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !model.protection.ruleSetProblems.isEmpty {
                    Text("Some rule sets did not load: \(model.protection.ruleSetProblems.joined(separator: "; "))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if !model.protection.restorable.isEmpty {
                    Text("\(model.protection.restorable.count) quarantined item(s) no longer match anything — you can put them back.")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            if model.protection.updating {
                ProgressView().controlSize(.small)
            }
            Button("Update Definitions") {
                Task { await model.protection.updateDefinitions(authKey: model.settings.threatFeedAuthKey) }
            }
            .disabled(model.protection.updating)
            Button("Quarantine \(model.protection.selectedFindings.count) Item(s)") { confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.protection.selectedFindings.isEmpty)
        }
        .padding(16)
    }
}
