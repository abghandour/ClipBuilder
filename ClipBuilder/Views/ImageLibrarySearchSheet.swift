import SwiftUI

/// Natural-language search over the subject and event metadata attached to
/// owned photos. Results filter the Images library without moving any files.
struct ImageLibrarySearchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let candidates: [AssetItem]
    let metadata: [String: LibraryAssetMetadata]
    let folder: [String]

    @State private var query = ""
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask the Image Library")
                .font(.title3.bold())
            Text(
                "Describe a fighter, event, topic, or kind of visual. The search uses the image subjects and tags already stored in this profile."
            )
            .foregroundStyle(.secondary)

            TextField("e.g. training photos of the featured fighter", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .onSubmit(run)

            ModelPicker(
                title: "Model", task: "search", selection: $modelTag,
                availableProviders: availableProviders
            )
            .fixedSize()

            HStack {
                Spacer()
                Button("Cancel", action: dismiss.callAsFunction)
                Button("Search", action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .appJobSetupPresentation()
        .task {
            queryFocused = true
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "search", available: availableProviders)
            }
        }
    }

    private func run() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let store = store
        let candidates = candidates, metadata = metadata
        let folder = folder
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.imageSearch, title: "Image Search — \(query)",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            let paths = try await store.searchImages(query: query, candidates: candidates, metadata: metadata,
                                                    provider: provider, model: model, log: log)
            guard !paths.isEmpty else { throw AppJobEmptyResult(message: "No tagged images matched that request.") }
            return .imageSearch(query: query, paths: paths, folder: folder)
        }
        dismiss()
    }
}
