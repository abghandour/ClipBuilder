import AppKit
import SwiftUI

/// Three honest views of the same learning: what this profile can offer the
/// Wizard, what the Wizard last actually read, and what leaves the Mac.
@MainActor
struct LearnedPreviewSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview, lastPlan, shared
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Learning overview"
            case .lastPlan: "Last plan prompt"
            case .shared: "Shared document"
            }
        }
    }

    let profileName: String
    let local: LearnedPreferences
    let contributors: [LearnedPreferences]
    let muted: Set<String>
    let sharedJSON: String
    let onDone: () -> Void

    @State private var tab: Tab = .overview
    @State private var attempt = 0
    @State private var record: LastPlanRecord?
    @State private var copied = false

    private var report: LearnedMerge.Report {
        LearnedMerge.mergeReport(local: local, contributors: contributors, muted: muted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Spacer()
                Button(copied ? "Copied" : "Copy") { copy() }
                    .disabled(copyText.isEmpty)
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            Text(caption).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                switch tab {
                case .overview: overview
                case .lastPlan: lastPlan
                case .shared: monospaced(sharedJSON)
                }
            }
        }
        .padding(24).frame(minWidth: 680, minHeight: 560)
        .task(id: profileName) {
            record = LastPlanRecord.load(profile: profileName)
            attempt = record?.acceptedAttempt ?? 0
        }
        .onChange(of: tab) { copied = false }
    }

    private var caption: String {
        switch tab {
        case .overview:
            "What is available to the Wizard from this profile. Each run selects from this by its own settings; the shared part is what other Macs add."
        case .lastPlan:
            "The exact text the Wizard sent the last time it planned a reel for this profile, with the images it attached."
        case .shared:
            "Snapshot of what Publish uploads now. Publish runs a pending distill first, so the uploaded document can differ."
        }
    }

    // MARK: Overview

    private var overview: some View {
        let report = report
        return VStack(alignment: .leading, spacing: 20) {
            ForEach(LearnedPreferences.Kind.allCases, id: \.rawValue) { kind in
                let winners = report.winners.filter { $0.section == kind }
                let excluded = report.excluded.filter { $0.line.section == kind }
                if !winners.isEmpty || !excluded.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(LearnedSectionInfo.entry(kind).title).font(.headline)
                            Text("\(winners.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ForEach(winners) { line in
                            Text(line.text).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(excluded) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.line.text).font(.system(.callout, design: .monospaced))
                                    .strikethrough().foregroundStyle(.secondary)
                                Text(item.reason.label).font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            if report.winners.isEmpty && report.excluded.isEmpty {
                Text("Nothing learned yet.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Last plan

    @ViewBuilder private var lastPlan: some View {
        if let record, !record.attempts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Planned \(record.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout)
                    if record.attempts.count > 1 {
                        Picker("Attempt", selection: $attempt) {
                            ForEach(record.attempts.indices, id: \.self) { index in
                                Text(attemptLabel(record, index)).tag(index)
                            }
                        }
                        .pickerStyle(.segmented).fixedSize()
                    }
                    Spacer()
                }
                if let current = record.attempts.indices.contains(attempt) ? record.attempts[attempt] : nil {
                    if let provider = current.provider {
                        Text("Answered by \(provider)\(current.model.map { " · \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !current.frames.isEmpty {
                        Text("Attached images: " + current.frames.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = outcomeNote(record, current) {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                    monospaced(current.prompt)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No plan yet", systemImage: "wand.and.stars")
            } description: {
                Text("Generate a reel with the AI Wizard for this profile. The exact prompt it sends is kept here.")
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func attemptLabel(_ record: LastPlanRecord, _ index: Int) -> String {
        let base = index == 0 ? "First" : "Retry \(index)"
        switch record.attempts[index].outcome {
        case .failed, .cancelled: return base + " (failed)"
        case .pending: return base + " (no answer)"
        case .answered: return record.acceptedAttempt == index ? base + " (used)" : base
        }
    }
    /// What happened to this request, when it was not simply used.
    static func outcomeNote(_ record: LastPlanRecord, _ attempt: LastPlanRecord.Attempt) -> String? {
        switch attempt.outcome {
        case .failed(let message): return "This request failed: \(message)"
        case .cancelled: return "This request was cancelled before it answered."
        case .pending: return "The app stopped before this request answered."
        case .answered:
            if record.acceptedAttempt == nil { return "No usable plan came back from this run." }
            if let used = record.acceptedAttempt, record.attempts.indices.contains(used),
               record.attempts[used] != attempt { return "Answered, but the plan from another attempt was used." }
            return nil
        }
    }
    private func outcomeNote(_ record: LastPlanRecord, _ attempt: LastPlanRecord.Attempt) -> String? {
        Self.outcomeNote(record, attempt)
    }

    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Copy

    private var copyText: String {
        switch tab {
        case .overview:
            let report = report
            let local = report.winners.filter(\.local).map(\.text).joined(separator: "\n")
            return local + LearnedMerge.contributorBlock(report.winners)
        case .lastPlan:
            guard let record, record.attempts.indices.contains(attempt) else { return "" }
            return record.attempts[attempt].prompt
        case .shared:
            return sharedJSON
        }
    }
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        copied = true
    }
}
