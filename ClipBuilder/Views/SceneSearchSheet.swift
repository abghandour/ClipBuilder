import SwiftUI

/// Natural-language scene search: describe the moment ("the head kick that
/// drops him", "corner advice between rounds") and the model returns the
/// matching scenes, applied to the grid as a ranked filter.
struct SceneSearchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Scenes in the current batch scope — what the query runs against.
    let candidates: [SceneRecord]
    /// Delivers (query, ranked scene ids, the model that ranked them) back
    /// to the grid.
    var onResults: (String, [Int64], AIProvenance) -> Void

    @State private var query = ""
    @State private var isRunning = false
    @State private var statusLine = ""
    @State private var errorMessage: String?
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

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusLine.isEmpty ? "Searching…" : statusLine)
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
                Button(isRunning ? "Searching…" : "Search") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty
                              || candidates.isEmpty || isRunning)
            }
        }
        .padding(20)
        .frame(width: 480)
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        let (provider, model) = ModelPicker.parse(modelTag)
        isRunning = true
        errorMessage = nil
        Task {
            do {
                let ids = try await store.findScenes(matching: trimmed, in: candidates,
                                                     provider: provider, model: model) { message in
                    if let line = AIProgressLine.from(message) { Task { @MainActor in statusLine = line } }
                }
                if ids.value.isEmpty {
                    errorMessage = "No scenes match that — try describing what's visible, or name the people involved."
                } else {
                    onResults(trimmed, ids.value, ids.provenance)
                    dismiss()
                }
            } catch {
                errorMessage = error.userMessage
            }
            isRunning = false
        }
    }
}
