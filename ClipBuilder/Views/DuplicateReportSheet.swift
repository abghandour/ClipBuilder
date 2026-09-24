import SwiftUI

struct DuplicateReportSheet: View {
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
                modelTag = ModelPicker.bestAvailableTag(for: "dedupe",
                                                        available: availableProviders)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan for Duplicates")
                .font(.title3.bold())
            Text("Compares the library's \(store.videos.count) videos — metadata plus one frame each — and reports footage imported more than once (re-downloads, different resolutions, shorter cuts), recommending which copy to keep. Nothing is deleted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ModelPicker(title: "Model", task: "dedupe", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Scan Library") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.videos.count < 2)
            }
        }
        .padding(20)
    }

    private func run() {
        let store = store
        let videos = store.videos
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.duplicates, title: "Scan for Duplicates",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            let result = try await store.findDuplicateVideos(provider: provider, model: model, log: log)
            return .duplicateReport(videos: videos, groups: result.value, provenance: result.provenance)
        }
        dismiss()
    }
}
