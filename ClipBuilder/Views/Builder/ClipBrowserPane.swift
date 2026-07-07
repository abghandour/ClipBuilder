import SwiftUI

/// Scene browser for the Builder: filter the analyzed scenes and drag them
/// onto the timeline (or click + to append to Track I).
struct ClipBrowserPane: View {
    @Environment(AppStore.self) private var store

    @State private var searchText = ""
    @State private var tagFilter: String?
    @State private var favoritesOnly = false
    @State private var orientation = OrientationFilter.all
    @State private var playingScene: SceneRecord?

    enum OrientationFilter: String, CaseIterable {
        case all = "All"
        case vertical = "Vertical"
        case wide = "Wide"
    }

    private var filteredScenes: [SceneRecord] {
        store.scenes.filter { scene in
            if scene.excluded { return false }
            if favoritesOnly && !scene.favorite { return false }
            if orientation == .wide && !scene.wide { return false }
            if orientation == .vertical && scene.wide { return false }
            if let tagFilter, !scene.tags.contains(tagFilter) { return false }
            if !searchText.isEmpty {
                let haystack = (scene.videoFilename + " " + scene.tags.joined(separator: " ")).lowercased()
                if !haystack.contains(searchText.lowercased()) { return false }
            }
            return true
        }
    }

    private var allTags: [String] {
        Array(Set(store.scenes.flatMap(\.tags))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Filter scenes", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Tag", selection: $tagFilter) {
                        Text("All Tags").tag(String?.none)
                        ForEach(allTags, id: \.self) { tag in
                            Text(tag).tag(String?.some(tag))
                        }
                    }
                    .labelsHidden()
                    Picker("Orientation", selection: $orientation) {
                        ForEach(OrientationFilter.allCases, id: \.self) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .labelsHidden()
                    Toggle(isOn: $favoritesOnly) {
                        Image(systemName: "heart.fill")
                    }
                    .toggleStyle(.button)
                    .help("Favorites only")
                }
                .controlSize(.small)
            }
            .padding(10)

            Divider()

            if filteredScenes.isEmpty {
                ContentUnavailableView("No Scenes", systemImage: "square.grid.3x3",
                                       description: Text("Analyze source videos, then drag scenes onto the timeline."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .top)],
                              spacing: 8) {
                        ForEach(filteredScenes) { scene in
                            BrowserSceneCard(scene: scene,
                                             onAdd: { store.builder.addScene(scene) },
                                             onPlay: { playingScene = scene })
                        }
                    }
                    .padding(10)
                }
            }
        }
        .sheet(item: $playingScene) { scene in
            PlayerSheet(url: scene.videoURL,
                        title: "\(scene.videoFilename) \(scene.startTime.timecode)–\(scene.endTime.timecode)",
                        startTime: scene.startTime)
        }
    }
}

/// Compact draggable scene card. The drag payload is "scene:<id>", which the
/// timeline lanes decode in their drop destinations.
struct BrowserSceneCard: View {
    let scene: SceneRecord
    let onAdd: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VideoThumbnail(url: scene.videoURL, time: (scene.startTime + scene.endTime) / 2)
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    Text(String(format: "%.1fs", scene.duration))
                        .font(.caption2.monospacedDigit())
                        .padding(3)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 3) {
                        if scene.wide {
                            Text("WIDE")
                                .font(.system(size: 8, weight: .bold))
                                .padding(2)
                                .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.white)
                        }
                        if scene.favorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(4)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button(action: onAdd) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Add to timeline")
                    .padding(4)
                }
            Text(scene.videoFilename)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .draggable("scene:\(scene.id)")
        .highPriorityGesture(TapGesture(count: 2).onEnded { onPlay() })
        .contextMenu {
            Button("Add to Timeline") { onAdd() }
            Button("Play") { onPlay() }
        }
    }
}
