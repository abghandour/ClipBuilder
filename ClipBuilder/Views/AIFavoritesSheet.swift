import SwiftUI

struct AIFavoritesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let candidates: [SceneRecord]
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
                modelTag = ModelPicker.bestAvailableTag(for: "curate",
                                                        available: availableProviders)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Favorites")
                .font(.title3.bold())
            Text("Judges the \(candidates.count) non-favorite scene\(candidates.count == 1 ? "" : "s") in view against your taste rubric — using your own grades and existing Favorite picks as worked examples — and proposes the keepers. You review every pick before it joins Favorites.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ModelPicker(title: "Model", task: "curate", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                    .help("Choose the AI provider and model that will propose favorites")
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Judge Scenes") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(candidates.isEmpty)
                    .help("Ask AI Favorites to propose scenes for your review")
            }
        }
        .padding(20)
    }

    private func run() {
        let store = store
        let candidates = candidates
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.aiFavorites, title: "AI Favorites — \(candidates.count) scenes",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            let result = try await store.proposeFavorites(for: candidates, provider: provider, model: model, log: log)
            guard !result.value.isEmpty else {
                throw AppJobEmptyResult(message: "AI Favorites selected nothing — none of these scenes clearly met the rubric.")
            }
            return .favorites(candidates: candidates, proposals: result.value, provenance: result.provenance)
        }
        dismiss()
    }
}
