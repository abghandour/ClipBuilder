import SwiftUI

struct GapReportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    var body: some View {
        setup
        .frame(minWidth: 520, idealWidth: 560, minHeight: 280)
        .appJobSetupPresentation()
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

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Build Report") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func run() {
        let store = store
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.gapReport, title: "Content Gaps",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            let result = try await store.generateGapReport(provider: provider, model: model, log: log)
            return .gapReport(result.value, provenance: result.provenance)
        }
        dismiss()
    }
}
