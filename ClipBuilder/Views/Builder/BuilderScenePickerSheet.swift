import SwiftUI

/// A focused source picker for Builder's primary Add action. The persistent
/// source browser remains available for drag-and-drop; this version answers
/// the simpler question, “which clip should start here?”
struct BuilderScenePickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    private var scenes: [SceneRecord] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.scenes.filter { !$0.excluded } }
        return store.scenes.filter { scene in
            guard !scene.excluded else { return false }
            return scene.videoFilename.localizedCaseInsensitiveContains(needle)
                || scene.tags.contains { $0.localizedCaseInsensitiveContains(needle) }
                || (scene.narrative?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.spaceM) {
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Text("Add a Video Clip")
                        .font(.headline)
                    Text("Choose a scene to place at the playhead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.spaceL)

            TextField("Search scenes", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Theme.spaceL)
                .padding(.bottom, Theme.spaceM)

            if scenes.isEmpty {
                ContentUnavailableView.search
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: Theme.spaceM,
                                                    alignment: .top)], spacing: Theme.spaceM) {
                        ForEach(scenes) { scene in
                            Button {
                                store.builder.addScene(scene, at: store.builder.playhead)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: Theme.spaceS) {
                                    VideoThumbnail(url: scene.videoURL,
                                                   time: (scene.startTime + scene.endTime) / 2,
                                                   cornerRadius: Theme.mediaRadius)
                                        .aspectRatio(9 / 16, contentMode: .fit)
                                        .overlay(alignment: .bottomLeading) {
                                            DurationBadge(seconds: scene.duration)
                                                .padding(Theme.spaceXS)
                                        }
                                    Text(scene.videoFilename)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Label("Add at playhead", systemImage: "plus")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .padding(Theme.spaceS)
                                .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                            }
                            .buttonStyle(.plain)
                            .help("Add \(scene.videoFilename) at \(store.builder.playhead.timecode)")
                            .accessibilityLabel("Add \(scene.videoFilename) at playhead")
                        }
                    }
                    .padding(Theme.spaceL)
                }
            }
        }
        .frame(width: 620, height: 620)
        .modalCloseButton { dismiss() }
    }
}
