import SwiftUI

/// Natural-language search over the subject and event metadata attached to
/// owned photos. Results filter the Images library without moving any files.
struct ImageLibrarySearchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let candidates: [AssetItem]
    let metadata: [String: LibraryAssetMetadata]
    var onResults: ([String]) -> Void

    @State private var query = ""
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    @State private var isRunning = false
    @State private var errorMessage: String?
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

            if isRunning { ProgressView("Searching images…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("Cancel", action: dismiss.callAsFunction)
                Button("Search", action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            queryFocused = true
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "search", available: availableProviders)
            }
        }
    }

    private func run() {
        guard !isRunning else { return }
        let useLocal = OnDevicePolicy.isEnabled(item: "image-search", config: store.settings.ai)
        if useLocal {
            let rows = candidates.map { item in
                let info = metadata[item.url.path]
                return LocalTextMatcher.Row(id: item.url.path,
                    fields: (info?.subjects ?? []) + (info?.tags ?? []),
                    date: (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
            let paths = LocalImageMatcher.match(query: query, rows: rows)
            if !paths.isEmpty {
                store.appendLog(\.pipelineLog, ["Matched \(paths.count) images by keyword"])
                onResults(paths)
                dismiss()
                return
            }
        }
        store.appendLog(\.pipelineLog, [useLocal ? "Keyword match found nothing — asking the model" : "Image search — asking the model"])
        let inventory = candidates.enumerated().map { index, item in
            let info = metadata[item.url.path]
            return
                "- id \(index) | \(item.name) | subjects: \(info?.subjects.joined(separator: ", ") ?? "untagged") | tags: \(info?.tags.joined(separator: ", ") ?? "untagged")"
        }.joined(separator: "\n")
        let prompt = """
            Rank the owned images which match this request: \(query)

            \(inventory)

            Return only JSON: {"ids":[0,1]}. Include only strong matches, best first. Never invent an id.
            """
        let (provider, model) = ModelPicker.parse(modelTag)
        isRunning = true
        errorMessage = nil
        Task {
            do {
                let response = try await store.ai.call(
                    prompt: prompt, task: "search",
                    model: model, provider: provider,
                    timeout: 120, log: { _ in })
                let object = AIResponseParser.jsonObject(from: response.text)
                let ids = object?["ids"] as? [Int] ?? []
                let paths = ids.compactMap { candidates.indices.contains($0) ? candidates[$0].url.path : nil }
                guard !paths.isEmpty else {
                    errorMessage = "No tagged images matched that request."
                    isRunning = false
                    return
                }
                onResults(paths)
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
            isRunning = false
        }
    }
}
