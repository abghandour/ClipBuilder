import SwiftUI

struct MediaSuggestionsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [MediaSuggestion] = []
    @State private var accepted = Set<String>()

    var body: some View {
        NavigationStack {
            Group {
                if suggestions.isEmpty {
                    ContentUnavailableView(
                        "No Matching Media", systemImage: "photo.stack",
                        description: Text(
                            "Tag images and mark scenes as B-roll, then add subject clips to the timeline."))
                } else {
                    List(suggestions) { suggestion in
                        HStack(spacing: 12) {
                            preview(suggestion)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(suggestion.kind == .photo ? "Photo" : "B-roll").bold()
                                Text(suggestion.reason).foregroundStyle(.secondary)
                                Text("Place at \(suggestion.atTime.timecode)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button(accepted.contains(suggestion.id) ? "Added" : "Add") { accept(suggestion) }
                                .disabled(accepted.contains(suggestion.id))
                        }
                    }
                }
            }
            .navigationTitle("Photo & B-roll Suggestions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .frame(width: 720, height: 560)
        .task { await load() }
    }

    @ViewBuilder
    private func preview(_ suggestion: MediaSuggestion) -> some View {
        if let path = suggestion.path {
            ImageThumbnail(url: URL(fileURLWithPath: path)).frame(width: 120, height: 72)
        } else if let sceneID = suggestion.sceneID,
            let scene = store.scenes.first(where: { $0.id == sceneID })
        {
            VideoThumbnail(
                url: scene.videoURL, time: (scene.startTime + scene.endTime) / 2,
                cornerRadius: 6
            ).frame(width: 120, height: 72)
        }
    }

    private func load() async {
        guard let database = store.database else { return }
        let assets = (try? await database.fetchAssetMetadata(kind: AssetKind.images.rawValue)) ?? []
        suggestions = MediaSuggestionService.suggestions(
            document: store.builder.document,
            scenes: store.scenes,
            people: store.people, assets: assets)
    }

    private func accept(_ suggestion: MediaSuggestion) {
        if let path = suggestion.path {
            store.builder.playhead = suggestion.atTime
            store.builder.addImage(path: path)
        } else if let id = suggestion.sceneID,
            let scene = store.scenes.first(where: { $0.id == id })
        {
            store.builder.addScene(scene, at: suggestion.atTime, track: 0)
        }
        accepted.insert(suggestion.id)
    }
}
