import SwiftUI

/// Natural-language scene search: describe the moment ("the head kick that
/// drops him", "corner advice between rounds") and the model returns the
/// matching scenes, applied to the grid as a ranked filter.
struct SceneSearchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Scenes in the current batch scope — what the query runs against.
    let candidates: [SceneRecord]
    let context: SceneSearchContext
    @State private var query = ""
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask the Library")
                .font(.title3.bold())
            Text("Describe the moment you're looking for in plain language — people, actions, story beats. The AI reads every scene's story and tags (\(candidates.count) scenes in view) and filters the grid to the matches.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("e.g. the moment Ulberg hurts Błachowicz against the fence",
                      text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .onSubmit { run() }

            HStack {
                ModelPicker(title: "Model", task: "search", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Search") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty
                              || candidates.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .appJobSetupPresentation()
        .modalCloseButton { dismiss() }
        .task {
            queryFocused = true
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "search",
                                                        available: availableProviders)
            }
        }
    }

    private func run() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let store = store
        let candidates = candidates
        let context = context
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.sceneSearch, title: "Scene Search — \(query)",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            let result = try await store.findScenes(matching: query, in: candidates, provider: provider, model: model, log: log)
            guard !result.value.isEmpty else {
                throw AppJobEmptyResult(message: "No scenes match that — try describing what's visible, or name the people involved.")
            }
            return .sceneSearch(query: query, ids: result.value, provenance: result.provenance, context: context)
        }
        dismiss()
    }
}
