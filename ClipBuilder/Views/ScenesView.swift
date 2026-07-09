import SwiftUI

/// Scene browser + rating: source files on the left, scene cards on the
/// right with favorite/grade voting and transcripts.
struct ScenesView: View {
    @Environment(AppStore.self) private var store

    @State private var selectedVideoID: Int64?
    @State private var tagFilter: String?
    @State private var showHidden = false
    @State private var searchText = ""
    @State private var playingScene: SceneRecord?
    @State private var transcriptVideo: VideoRecord?

    private var filteredScenes: [SceneRecord] {
        let needle = searchText.lowercased()
        return store.scenes.filter { scene in
            if let selectedVideoID, scene.videoID != selectedVideoID { return false }
            if !showHidden && scene.excluded { return false }
            if let tagFilter, !scene.tags.contains(tagFilter) { return false }
            if !needle.isEmpty {
                let haystack = (scene.videoFilename + " " + scene.tags.joined(separator: " ")).lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
    }

    private var allTags: [String] {
        Array(Set(store.scenes.flatMap(\.tags))).sorted()
    }

    var body: some View {
        // Filter once per body pass — the subtitle and grid share the result.
        let filtered = filteredScenes
        HSplitView {
            fileList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340, maxHeight: .infinity)
            sceneGrid(filtered)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Scenes")
        .navigationSubtitle("\(filtered.count) scenes")
        .searchable(text: $searchText, prompt: "Filter by file or tag")
        .toolbar {
            ToolbarItem {
                Picker("Tag", selection: $tagFilter) {
                    Text("All Tags").tag(String?.none)
                    ForEach(allTags, id: \.self) { tag in
                        Text(tag).tag(String?.some(tag))
                    }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem {
                Toggle("Show Hidden", systemImage: "eye.slash", isOn: $showHidden)
                    .help("Include scenes hidden by low-quality auto-detection or by you")
            }
        }
        .sheet(item: $playingScene) { scene in
            PlayerSheet(url: scene.videoURL,
                        title: "\(scene.videoFilename) \(scene.startTime.timecode)–\(scene.endTime.timecode)",
                        startTime: scene.startTime)
        }
        .sheet(item: $transcriptVideo) { video in
            TranscriptSheet(video: video)
        }
    }

    private var fileList: some View {
        // One pass over scenes instead of an O(scenes) filter per row.
        let sceneCounts = store.scenes.reduce(into: [Int64: Int]()) { $0[$1.videoID, default: 0] += 1 }
        return List(selection: $selectedVideoID) {
            Section("Source Videos") {
                HStack {
                    Image(systemName: "square.grid.3x3")
                    Text("All Videos")
                    Spacer()
                    Text("\(store.scenes.count)")
                        .foregroundStyle(.secondary)
                }
                .tag(Int64?.none)
                ForEach(store.videos) { video in
                    HStack {
                        Image(systemName: video.wide ? "rectangle" : "rectangle.portrait")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(video.filename)
                                .lineLimit(1)
                            Text(video.duration.timecode)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(sceneCounts[video.id] ?? 0)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .tag(Int64?.some(video.id))
                    .contextMenu {
                        Button("Transcript…") {
                            transcriptVideo = video
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([video.url])
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sceneGrid(_ filtered: [SceneRecord]) -> some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "No Scenes",
                    systemImage: "square.grid.3x3",
                    description: Text("Run analysis on your source videos to detect scenes."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(filtered) { scene in
                            SceneCard(scene: scene,
                                      onPlay: { playingScene = scene },
                                      onTranscript: {
                                          transcriptVideo = store.videos.first { $0.id == scene.videoID }
                                      })
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

struct SceneCard: View {
    @Environment(AppStore.self) private var store
    let scene: SceneRecord
    let onPlay: () -> Void
    let onTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onPlay) {
                VideoThumbnail(url: scene.videoURL, time: (scene.startTime + scene.endTime) / 2)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text(String(format: "%.1fs", scene.duration))
                            .font(.caption2.monospacedDigit())
                            .padding(4)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                    .overlay(alignment: .topTrailing) {
                        if scene.wide {
                            Text("WIDE")
                                .font(.caption2.bold())
                                .padding(3)
                                .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
                    .opacity(scene.excluded ? 0.4 : 1)
            }
            .buttonStyle(.plain)

            Text("\(scene.videoFilename)  \(scene.startTime.timecode)–\(scene.endTime.timecode)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !scene.tags.isEmpty {
                TagWrap(tags: scene.tags, limit: 4)
            }

            HStack(spacing: 8) {
                Button {
                    store.toggleFavorite(scene)
                } label: {
                    Image(systemName: scene.favorite ? "heart.fill" : "heart")
                        .foregroundStyle(scene.favorite ? .red : .secondary)
                }
                .help("Favorite")

                Button {
                    store.grade(scene, score: 5)
                } label: {
                    Image(systemName: "hand.thumbsup")
                }
                .help("Good scene (grade 5)")

                Button {
                    store.grade(scene, score: 1)
                } label: {
                    Image(systemName: "hand.thumbsdown")
                }
                .help("Bad scene (grade 1)")

                if let average = scene.gradeAverage, scene.gradeCount > 0 {
                    Text(String(format: "%.1f", average))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onTranscript()
                } label: {
                    Image(systemName: "text.quote")
                }
                .help("Transcript")

                Button {
                    store.setExcluded(scene, excluded: !scene.excluded)
                } label: {
                    Image(systemName: scene.excluded ? "eye" : "eye.slash")
                }
                .help(scene.excluded ? "Unhide scene" : "Hide scene")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Add to Builder") {
                store.builder.addScene(scene)
                store.requestedSection = .builder
            }
        }
    }
}

/// Transcript viewer/editor for one source video.
struct TranscriptSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: VideoRecord

    @State private var rows: [TranscriptRow] = []
    @State private var editingRow: TranscriptRow?
    @State private var editText = ""
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Transcript — \(video.filename)")
                        .font(.headline)
                    if let provider = rows.first?.provider {
                        Text("Transcribed by \(provider)\(rows.first?.model.map { " (\($0))" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Re-transcribe") {
                    store.transcribe(video: video, force: true)
                    dismiss()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "text.quote",
                    description: Text("Transcribe this video from the Analyze tab."))
            } else {
                List(rows) { row in
                    HStack(alignment: .top) {
                        Text("\(row.startTime.timecode)–\(row.endTime.timecode)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(row.text)
                            .textSelection(.enabled)
                        Spacer()
                        if row.originalText != nil {
                            Button("Revert") {
                                revert(row)
                            }
                            .controlSize(.mini)
                        }
                        Button("Edit") {
                            editText = row.text
                            editingRow = row
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
        .frame(width: 620, height: 480)
        .task { await load() }
        .sheet(item: $editingRow) { row in
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit Segment")
                    .font(.headline)
                TextEditor(text: $editText)
                    .frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                HStack {
                    Spacer()
                    Button("Cancel") { editingRow = nil }
                    Button("Save") {
                        save(row, text: editText)
                        editingRow = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 420)
        }
    }

    private func load() async {
        guard let database = store.database else { return }
        rows = (try? await database.fetchTranscripts(videoID: video.id)) ?? []
        isLoading = false
    }

    private func save(_ row: TranscriptRow, text: String) {
        guard let database = store.database else { return }
        Task {
            try? await database.updateTranscriptText(id: row.id, text: text)
            await load()
        }
    }

    private func revert(_ row: TranscriptRow) {
        guard let database = store.database else { return }
        Task {
            try? await database.revertTranscriptText(id: row.id)
            await load()
        }
    }
}
