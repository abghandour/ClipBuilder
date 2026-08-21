import SwiftUI

/// Scene browser + rating: source files on the left, scene cards on the
/// right with favorite/grade voting and transcripts.
struct ScenesView: View {
    @Environment(AppStore.self) private var store

    @State private var selectedRunIDs: Set<Int64> = []
    @State private var tagFilter: String?
    @State private var showHidden = false
    @State private var searchText = ""
    @State private var transcriptVideo: VideoRecord?
    @State private var renamingRun: AnalysisRun?
    @State private var renameText = ""
    @State private var deletingRuns: [AnalysisRun] = []
    @State private var infoRun: AnalysisRun?
    @State private var showGenerateSheet = false
    @State private var curatingScene: SceneRecord?
    @State private var sortByScore = false
    @State private var minScore = 0.0
    @State private var showSequenceParts = false

    /// Sentinel tag for the "All Batches" row — Set-based selection can't
    /// hold a nil the way the old single-selection did.
    private static let allBatchesID: Int64 = -1

    /// The batches to filter by; nil = show everything (nothing selected,
    /// or "All Batches" is part of the selection).
    private var runFilter: Set<Int64>? {
        selectedRunIDs.isEmpty || selectedRunIDs.contains(Self.allBatchesID)
            ? nil : selectedRunIDs
    }

    private var selectedRuns: [AnalysisRun] {
        store.analysisRuns.filter { selectedRunIDs.contains($0.id) }
    }

    /// Exactly one real batch selected → its info button shows.
    private var selectedRun: AnalysisRun? {
        let runs = selectedRuns
        return runs.count == 1 ? runs[0] : nil
    }

    private var filteredScenes: [SceneRecord] {
        let needle = searchText.lowercased()
        let runFilter = runFilter
        var result = store.scenes.filter { scene in
            if let runFilter, !(scene.runID.map(runFilter.contains) ?? false) { return false }
            if !showHidden && scene.excluded { return false }
            if let tagFilter, !scene.tags.contains(tagFilter) { return false }
            if minScore > 0, (scene.score ?? -1) < minScore { return false }
            if !needle.isEmpty {
                let haystack = (scene.videoFilename + " " + scene.tags.joined(separator: " ")).lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
        // Broken-down sequences show as ONE card by default — their action
        // beats collapse under the parent unless explicitly shown.
        if !showSequenceParts {
            let visibleIDs = Set(result.map(\.id))
            result = result.filter { scene in
                guard let parent = scene.parentSceneID else { return true }
                return !visibleIDs.contains(parent)
            }
        }
        if sortByScore {
            result.sort { ($0.score ?? -1) > ($1.score ?? -1) }
        }
        return result
    }

    private var allTags: [String] {
        Array(Set(store.scenes.flatMap(\.tags))).sorted()
    }

    /// The displayed scenes as a Generate Video source. A person: filter
    /// (or framed: — the person inside the 9:16 framing) becomes the
    /// Wizard's source-people pick; any other tag rides as a content-tag
    /// constraint.
    private var generateSource: GenerateVideoSource {
        var personKeys: Set<String> = []
        var tags: [String] = []
        if let tagFilter {
            if tagFilter.hasPrefix("person:") {
                personKeys = [String(tagFilter.dropFirst("person:".count))]
            } else if tagFilter.hasPrefix("framed:") {
                personKeys = [String(tagFilter.dropFirst("framed:".count))]
            } else {
                tags = [tagFilter]
            }
        }
        return .scenes(filteredScenes, personKeys: personKeys, tags: tags)
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
        .navigationTitle("Raw Scenes")
        .navigationSubtitle("\(filtered.count) scenes")
        .searchable(text: $searchText, prompt: "Filter by file or tag")
        .toolbar {
            if let run = selectedRun {
                ToolbarItem {
                    Button("Batch Info", systemImage: "info.circle") {
                        infoRun = run
                    }
                    .help("All parameters and instructions used for this analyze batch")
                }
            }
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
                Picker("Order", selection: $sortByScore) {
                    Label("By time", systemImage: "clock").tag(false)
                    Label("Top scored", systemImage: "star").tag(true)
                }
                .pickerStyle(.menu)
                .help("Order the grid by source order or by entertainment score")
            }
            ToolbarItem {
                Picker("Score", selection: $minScore) {
                    Text("All scores").tag(0.0)
                    Text("Score ≥ 5").tag(5.0)
                    Text("Score ≥ 7").tag(7.0)
                }
                .pickerStyle(.menu)
                .help("Only show scenes at or above an entertainment score")
            }
            ToolbarItem {
                Toggle("Sequence Actions", systemImage: "list.bullet.indent",
                       isOn: $showSequenceParts)
                    .help("Show the individual actions inside broken-down sequences — hidden by default, the sequence card stands for them")
            }
            ToolbarItem {
                Toggle("Show Hidden", systemImage: "eye.slash", isOn: $showHidden)
                    .help("Include scenes hidden by low-quality auto-detection or by you")
            }
            ToolbarItem {
                Button {
                    showGenerateSheet = true
                } label: {
                    ToolbarBubbleLabel(text: "Generate Video", systemImage: "wand.and.stars")
                }
                .disabled(filtered.isEmpty)
                .help("Describe a video to create from the displayed scenes — the current batch, tag, and search filters carry into the AI Wizard")
            }
        }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateVideoSheet(source: generateSource)
        }
        .sheet(item: $transcriptVideo) { video in
            TranscriptSheet(video: video)
        }
        .sheet(item: $infoRun) { run in
            BatchInfoSheet(run: run)
        }
        .sheet(item: $curatingScene) { scene in
            CurateSceneSheet(sceneID: scene.id)
        }
    }

    private var fileList: some View {
        List(selection: $selectedRunIDs) {
            Section("Analyze Batches") {
                HStack {
                    Image(systemName: "square.grid.3x3")
                    Text("All Batches")
                    Spacer()
                    Text("\(store.scenes.count)")
                        .foregroundStyle(.secondary)
                }
                .tag(Self.allBatchesID)
                ForEach(store.analysisRuns) { run in
                    HStack {
                        Image(systemName: "sparkles.rectangle.stack")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(run.name)
                                .lineLimit(2)
                            if !run.instructions.isEmpty {
                                Text(run.instructions)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text("\(run.sceneCount)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .tag(run.id)
                    .help(batchTooltip(run))
                    .contextMenu {
                        Button("Batch Info…") {
                            infoRun = run
                        }
                        Button("Rename…") {
                            renameText = run.name
                            renamingRun = run
                        }
                        Button("Delete Batch…", role: .destructive) {
                            deletingRuns = [run]
                        }
                        // Right-clicking inside a multi-selection offers the
                        // whole selection; Delete (⌫) does the same.
                        if selectedRunIDs.contains(run.id), selectedRuns.count > 1 {
                            Button("Delete \(selectedRuns.count) Selected Batches…", role: .destructive) {
                                deletingRuns = selectedRuns
                            }
                        }
                        Divider()
                        Button("Transcript…") {
                            transcriptVideo = store.videos.first { $0.id == run.videoID }
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([run.videoURL])
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            let runs = selectedRuns
            if !runs.isEmpty { deletingRuns = runs }
        }
        .alert("Rename Analyze Batch", isPresented: Binding(
            get: { renamingRun != nil },
            set: { if !$0 { renamingRun = nil } })
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let run = renamingRun { store.renameAnalysisRun(run, to: renameText) }
                renamingRun = nil
            }
            Button("Cancel", role: .cancel) { renamingRun = nil }
        }
        .confirmationDialog(
            deletingRuns.count == 1
                ? "Delete “\(deletingRuns.first?.name ?? "")”?"
                : "Delete \(deletingRuns.count) analyze batches?",
            isPresented: Binding(get: { !deletingRuns.isEmpty },
                                 set: { if !$0 { deletingRuns = [] } })
        ) {
            Button(deletingRuns.count == 1 ? "Delete Batch" : "Delete \(deletingRuns.count) Batches",
                   role: .destructive) {
                for run in deletingRuns {
                    selectedRunIDs.remove(run.id)
                    store.deleteAnalysisRun(run)
                }
                deletingRuns = []
            }
            Button("Cancel", role: .cancel) { deletingRuns = [] }
        } message: {
            Text(deletingRuns.count == 1
                 ? "This deletes the batch's scenes along with their tags and ratings. The source video is not touched."
                 : "This deletes these batches' scenes along with their tags and ratings. The source videos are not touched.")
        }
    }

    private func batchTooltip(_ run: AnalysisRun) -> String {
        var lines = ["Analyzed \(run.createdAt ?? "—")"]
        if let model = run.model { lines.append("Model: \(run.provider.map { "\($0) — " } ?? "")\(model)") }
        if !run.instructions.isEmpty { lines.append("Instructions: \(run.instructions)") }
        return lines.joined(separator: "\n")
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
                                      onTranscript: {
                                          transcriptVideo = store.videos.first { $0.id == scene.videoID }
                                      },
                                      onCurate: { curatingScene = scene })
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

/// Everything an analyze batch ran with — the model, sampling, transcript
/// choice, and instructions — plus a shortcut to re-run the analysis with
/// those options loaded for editing.
private struct BatchInfoSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let run: AnalysisRun

    /// Notes shown for the batch: its snapshot when recorded, else the
    /// video's current notes (older batches didn't snapshot them).
    @State private var notes: [AnalysisRunNote] = []
    @State private var notesAreFallback = false

    private var samplingLabel: String {
        run.sampleInterval > 0
            ? String(format: "Every %gs", run.sampleInterval)
            : "Automatic (1–3s by length)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(run.name)
                .font(.headline)
                .padding()

            Form {
                LabeledContent("Source video", value: run.videoFilename)
                LabeledContent("Analyzed", value: run.createdAt ?? "—")
                LabeledContent("Model", value: run.model.map { "\(run.provider.map { "\($0) — " } ?? "")\($0)" } ?? "—")
                LabeledContent("Frame sampling", value: samplingLabel)
                LabeledContent("Transcript included", value: run.hasTranscript ? "Yes" : "No")
                LabeledContent("Scenes", value: "\(run.sceneCount)")
                Section("Instructions") {
                    if run.instructions.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(run.instructions)
                            .textSelection(.enabled)
                    }
                }
                Section("Video notes") {
                    if notes.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(notes, id: \.self) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(note.at.timecode)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(note.note)
                                    .textSelection(.enabled)
                            }
                        }
                        if notesAreFallback {
                            Text("This batch predates note snapshots — showing the video's current notes, which may differ from what the run used.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Edit & Re-run Analysis…") {
                    dismiss()
                    store.reanalyzeBatch(run)
                }
                .help("Opens the Analyze tab with this batch's options loaded into the model plan — adjust anything, then start. The result lands in a new batch.")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 440)
        .frame(minHeight: 360)
        .task {
            if let snapshot = run.noteSnapshot {
                notes = snapshot
            } else {
                notes = await store.videoNotes(for: run.videoID)
                    .map { AnalysisRunNote(at: $0.atTime, note: $0.note) }
                notesAreFallback = !notes.isEmpty
            }
        }
    }
}

struct SceneCard: View {
    @Environment(AppStore.self) private var store
    let scene: SceneRecord
    let onTranscript: () -> Void
    /// Opens the Curate workbench modal (framing + trim → save as curated).
    var onCurate: (() -> Void)?

    /// Actions broken out of this scene (it's a sequence when > 0).
    private var childCount: Int {
        store.scenes.count(where: { $0.parentSceneID == scene.id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SceneInlinePlayer(scene: scene)
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    Text(String(format: "%.1fs", scene.duration))
                        .font(.caption2.monospacedDigit())
                        .padding(4)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    if let score = scene.score {
                        Text(String(format: "%.1f", score))
                            .font(.caption2.bold().monospacedDigit())
                            .padding(4)
                            .background(score >= 7.5 ? .green.opacity(0.85)
                                        : score >= 5 ? .yellow.opacity(0.85)
                                        : .gray.opacity(0.7),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.black)
                            .padding(6)
                            .allowsHitTesting(false)
                            .help(scene.narrative ?? "Entertainment score")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        if scene.wide {
                            Text("WIDE")
                                .font(.caption2.bold())
                                .padding(3)
                                .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white)
                        }
                        if childCount > 0 {
                            Text("SEQ · \(childCount)")
                                .font(.caption2.bold())
                                .padding(3)
                                .background(.purple.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white)
                                .help("A sequence broken into \(childCount) action scene(s) — show them with the Sequence Actions toolbar toggle")
                        }
                    }
                    .padding(6)
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomTrailing) {
                    if (scene.excitement ?? 0) >= 0.35 {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.caption2)
                            .padding(4)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.orange)
                            .padding(6)
                            .allowsHitTesting(false)
                            .help("The crowd reacted here — audio excitement boosted this scene's score")
                    }
                }
                .opacity(scene.excluded ? 0.4 : 1)

            Text("\(scene.videoFilename)  \(scene.startTime.timecode)–\(scene.endTime.timecode)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if scene.parentSceneID != nil {
                Text("↳ part of a sequence")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !scene.tags.isEmpty {
                SceneTagLine(tags: scene.tags)
            }

            if let narrative = scene.narrative {
                Text(narrative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(narrative)
            }

            HStack(spacing: 8) {
                Button {
                    if scene.curated {
                        store.curateScene(scene, curated: false)
                    } else if let onCurate {
                        onCurate()
                    } else {
                        store.curateScene(scene, curated: true)
                    }
                } label: {
                    Image(systemName: scene.curated ? "checkmark.seal.fill" : "checkmark.seal")
                        .foregroundStyle(scene.curated ? .green : .secondary)
                }
                .help(scene.curated
                      ? "In the Curated set — click to remove"
                      : "Curate this scene: preview and apply Center Stage, trim, then save it as good to go")

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
            if scene.curated {
                Button("Remove from Curated") {
                    store.curateScene(scene, curated: false)
                }
            } else {
                Button("Curate…") {
                    onCurate?()
                }
            }
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
