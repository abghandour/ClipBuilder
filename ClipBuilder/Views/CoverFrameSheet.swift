import SwiftUI

/// Cover-frame picker: the AI samples frames across a rendered reel and
/// ranks the best thumbnail candidates; clicking one makes it the Library
/// card's cover.
struct CoverFrameSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: GeneratedVideoRecord

    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a Cover Frame")
                .font(.title3.bold())
            Text("The AI samples frames across \(video.filename) and ranks the strongest thumbnails — sharp, expressive, readable at cover size. Click one to make it the card's cover.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ModelPicker(title: "Model", task: "cover", selection: $modelTag,
                        availableProviders: availableProviders).fixedSize()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Propose Covers") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 500)
        .appJobSetupPresentation()
        .modalCloseButton { dismiss() }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "cover",
                                                        available: availableProviders)
            }
        }
    }

    private func run() {
        let store = store
        let video = video
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.coverFrames, title: "Cover Frames — \(video.filename)",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            let result = try await store.proposeCoverFrames(for: video, provider: provider, model: model, log: log)
            return .coverFrames(video: video, candidates: result.value, provenance: result.provenance)
        }
        dismiss()
    }
}
