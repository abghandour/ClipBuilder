import SwiftUI

struct SoundbiteSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: VideoRecord
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
                modelTag = ModelPicker.bestAvailableTag(for: "soundbites",
                                                        available: availableProviders)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Soundbites")
                .font(.title3.bold())
            Text("Mines the transcript of \(video.filename) for the most quotable self-contained moments — the lines worth building a reel around — each with timestamps and a suggested overlay caption.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ModelPicker(title: "Model", task: "soundbites", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Find Soundbites") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func run() {
        let store = store
        let video = video
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.soundbites, title: "Soundbites — \(video.filename)",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            let result = try await store.findSoundbites(in: video, provider: provider, model: model, log: log)
            return .soundbites(video: video, items: result.value, provenance: result.provenance)
        }
        dismiss()
    }
}
