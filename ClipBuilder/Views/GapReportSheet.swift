import SwiftUI

/// Content gap report: a strategist's checklist over the whole pipeline —
/// what to post next, what's sitting unused, what's blocking output —
/// referencing the library's actual files.
struct GapReportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isRunning = false
    @State private var statusLine = ""
    @State private var errorMessage: String?
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    @State private var sections: [GapReporter.Section]?

    var body: some View {
        Group {
            if let sections {
                report(sections)
            } else {
                setup
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 280, idealHeight: 440)
        .modalCloseButton { dismiss() }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "gap",
                                                        available: availableProviders)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Content Gaps")
                .font(.title3.bold())
            Text("A strategist's pass over everything on record — \(store.videos.count) source videos, \(store.generatedVideos.count) generated reels, Instagram history — answering: what should be posted next, what's sitting unused, and what's blocking more output.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ModelPicker(title: "Model", task: "gap", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusLine.isEmpty ? "Reading the pipeline…" : statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isRunning ? "Analyzing…" : "Build Report") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning)
            }
        }
        .padding(20)
    }

    private func report(_ sections: [GapReporter.Section]) -> some View {
        VStack(spacing: 0) {
            Text("Content Gaps")
                .font(.headline)
                .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.callout.bold())
                            ForEach(section.items, id: \.self) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(item)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            }

            HStack {
                Button("Copy Report", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(GapReporter.plainText(sections),
                                                   forType: .string)
                }
                Spacer()
                Button("Open AI Wizard") {
                    store.requestedSection = .wizard
                    dismiss()
                }
                .help("Jump to the Wizard to act on the report")
            }
            .padding()
        }
    }

    private func run() {
        let (provider, model) = ModelPicker.parse(modelTag)
        isRunning = true
        errorMessage = nil
        Task {
            do {
                sections = try await store.generateGapReport(
                    provider: provider, model: model) { message in
                    if let line = AIProgressLine.from(message) { Task { @MainActor in statusLine = line } }
                }
            } catch {
                errorMessage = error.userMessage
            }
            isRunning = false
        }
    }
}
