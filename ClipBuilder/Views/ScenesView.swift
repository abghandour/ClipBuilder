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
    /// How aggressively near-simultaneous takes collapse into one card —
    /// shared app-wide with every other scene surface.
    @AppStorage(SceneStacks.levelKey) private var stackLevelRaw = SceneStackLevel.standard.rawValue
    /// Card whose stack picker popover is open (long-press a stacked card).
    @State private var stackPickerID: Int64?

    private var stackLevel: SceneStackLevel { .from(stackLevelRaw) }

    // Grid selection: click selects, ⌘-click toggles, ⇧-click extends, and
    // the keyboard drives the whole triage loop (arrows move, Space
    // previews, ⏎ curates, G/B grade, F favorite, H hide, C curate).
    @State private var selectedSceneIDs: Set<Int64> = []
    @State private var selectionAnchorID: Int64?
    /// Columns currently laid out by the adaptive grid — keeps ↑/↓ movement
    /// honest at any window width.
    @State private var gridColumns = 1
    /// Scene playing in the Space-bar quick preview.
    @State private var previewScene: SceneRecord?
    @FocusState private var gridFocused: Bool

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

    /// The grid's contents after filters and collapses: the visible cards,
    /// plus every stacked card's full member list (best take first).
    private struct GridContents {
        var scenes: [SceneRecord] = []
        /// Top-card scene id → the whole stack behind it. Only real stacks
        /// (2+ members) are listed; every other card is a plain scene.
        var stacks: [Int64: [SceneRecord]] = [:]
    }

    private var gridContents: GridContents {
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
        // Takes of the same moment collapse behind their best one — the
        // user's remembered pick when they made one, otherwise the AI's.
        var contents = GridContents()
        for stack in SceneStacks.group(result, level: stackLevel) {
            contents.scenes.append(stack[0])
            if stack.count > 1 { contents.stacks[stack[0].id] = stack }
        }
        if sortByScore {
            contents.scenes.sort { ($0.score ?? -1) > ($1.score ?? -1) }
        }
        return contents
    }

    private var allTags: [String] {
        Array(Set(store.scenes.flatMap(\.tags))).sorted()
    }

    /// Any non-default grid filter — fills the toolbar Filter icon.
    private var filtersActive: Bool {
        tagFilter != nil || sortByScore || minScore > 0 || showSequenceParts || showHidden
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
        return .scenes(gridContents.scenes, personKeys: personKeys, tags: tags)
    }

    var body: some View {
        // Filter once per body pass — the subtitle and grid share the result.
        let contents = gridContents
        let filtered = contents.scenes
        // Takes tucked behind stack cards, so the subtitle can say how many
        // scenes the grouped grid really covers.
        let stackedAway = contents.stacks.values.reduce(0) { $0 + $1.count - 1 }
        HSplitView {
            fileList
                .rememberedPaneWidth("pane.scenes.batches", min: 220, initial: 260, max: 340)
                .frame(maxHeight: .infinity)
            sceneGrid(contents)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Raw Scenes")
        .navigationSubtitle(selectedSceneIDs.count > 1
                            ? "\(selectedSceneIDs.count) of \(filtered.count) scenes selected"
                            : stackedAway > 0
                                ? "\(filtered.count) moments — \(filtered.count + stackedAway) scenes"
                                : "\(filtered.count) scenes")
        .searchable(text: $searchText, prompt: "Filter by file or tag")
        .toolbar {
            if let run = selectedRun {
                ToolbarItem {
                    Button("Analyze Batch Info", systemImage: "info.circle") {
                        infoRun = run
                    }
                    .help("All parameters and instructions used for this analyze batch")
                }
            }
            ToolbarItem {
                Menu {
                    Picker("Tag", selection: $tagFilter) {
                        Text("All Tags").tag(String?.none)
                        ForEach(allTags, id: \.self) { tag in
                            Text(tag).tag(String?.some(tag))
                        }
                    }
                    Picker("Order", selection: $sortByScore) {
                        Label("By time", systemImage: "clock").tag(false)
                        Label("Top scored", systemImage: "star").tag(true)
                    }
                    Picker("Minimum score", selection: $minScore) {
                        Text("All scores").tag(0.0)
                        Text("Score ≥ 5").tag(5.0)
                        Text("Score ≥ 7").tag(7.0)
                    }
                    Divider()
                    SceneStackLevelPicker()
                    Toggle("Show Sequence Actions", isOn: $showSequenceParts)
                    Toggle("Show Hidden Scenes", isOn: $showHidden)
                    if filtersActive {
                        Divider()
                        Button("Reset Filters") {
                            tagFilter = nil
                            sortByScore = false
                            minScore = 0
                            showSequenceParts = false
                            showHidden = false
                        }
                    }
                } label: {
                    ToolbarBubbleLabel(
                        text: "Filter",
                        systemImage: filtersActive ? "line.3.horizontal.decrease.circle.fill"
                                                   : "line.3.horizontal.decrease.circle")
                }
                .help("Filter and order the grid: tag, entertainment score, similar-scene grouping, sequence actions, hidden scenes. The icon fills when a filter is active.")
            }
            ToolbarItem {
                Button {
                    showGenerateSheet = true
                } label: {
                    ToolbarBubbleLabel(text: "Generate Video", systemImage: "wand.and.stars")
                }
                .disabled(filtered.isEmpty)
                .help("Describe a video to create from the displayed scenes — the current analyze batch, tag, and search filters carry into the AI Wizard")
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
        .sheet(item: $previewScene) { scene in
            PlayerSheet(url: scene.videoURL,
                        title: "\(scene.videoFilename)  \(scene.startTime.timecode)–\(scene.endTime.timecode)",
                        startTime: scene.startTime, endTime: scene.endTime)
        }
    }

    private var fileList: some View {
        List(selection: $selectedRunIDs) {
            Section("Analyze Batches") {
                HStack {
                    Image(systemName: "square.grid.3x3")
                    Text("All Analyze Batches")
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
                        Button("Analyze Batch Info…") {
                            infoRun = run
                        }
                        Button("Rename…") {
                            renameText = run.name
                            renamingRun = run
                        }
                        Button("Delete Analyze Batch…", role: .destructive) {
                            deletingRuns = [run]
                        }
                        // Right-clicking inside a multi-selection offers the
                        // whole selection; Delete (⌫) does the same.
                        if selectedRunIDs.contains(run.id), selectedRuns.count > 1 {
                            Button("Delete \(selectedRuns.count) Selected Analyze Batches…", role: .destructive) {
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
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renamingRun = nil }
        }
        .confirmationDialog(
            deletingRuns.count == 1
                ? "Delete “\(deletingRuns.first?.name ?? "")”?"
                : "Delete \(deletingRuns.count) analyze batches?",
            isPresented: Binding(get: { !deletingRuns.isEmpty },
                                 set: { if !$0 { deletingRuns = [] } })
        ) {
            Button(deletingRuns.count == 1 ? "Delete Analyze Batch" : "Delete \(deletingRuns.count) Analyze Batches",
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
                 ? "This deletes the analyze batch's scenes along with their tags and ratings. The source video is not touched."
                 : "This deletes these analyze batches' scenes along with their tags and ratings. The source videos are not touched.")
        }
    }

    private func batchTooltip(_ run: AnalysisRun) -> String {
        var lines = ["Analyzed \(run.createdAt ?? "—")"]
        if let model = run.model { lines.append("Model: \(run.provider.map { "\($0) — " } ?? "")\(model)") }
        if !run.instructions.isEmpty { lines.append("Instructions: \(run.instructions)") }
        return lines.joined(separator: "\n")
    }

    private func sceneGrid(_ contents: GridContents) -> some View {
        let filtered = contents.scenes
        return Group {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "No Scenes",
                    systemImage: "square.grid.3x3",
                    description: Text("Run analysis on your source videos to detect scenes."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Theme.spaceM, alignment: .top)], spacing: Theme.spaceM) {
                            ForEach(filtered) { scene in
                                gridCard(scene, in: contents)
                                    .id(scene.id)
                            }
                        }
                        .padding()
                        // Column count feeds ↑/↓ keyboard movement.
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                            gridColumns = max(1, Int((width - 32 + Theme.spaceM) / (180 + Theme.spaceM)))
                        }
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($gridFocused)
                    .onMoveCommand { direction in
                        moveSelection(direction, in: filtered, proxy: proxy)
                    }
                    .onExitCommand {
                        selectedSceneIDs = []
                        selectionAnchorID = nil
                    }
                    .onDeleteCommand {
                        bulkSetHidden(in: filtered)
                    }
                    .onKeyPress(phases: .down) { press in
                        handleKey(press, in: filtered)
                    }
                }
            }
        }
    }

    /// One selectable grid cell: the card, its selection ring, and the
    /// click-to-select handling (⌘ toggles, ⇧ extends from the anchor).
    /// Cards fronting a stack also carry the long-press → picker popover.
    private func gridCard(_ scene: SceneRecord, in contents: GridContents) -> some View {
        let filtered = contents.scenes
        let stack = contents.stacks[scene.id]
        return SceneCard(scene: scene,
                  onTranscript: {
                      transcriptVideo = store.videos.first { $0.id == scene.videoID }
                  },
                  onCurate: { curatingScene = scene },
                  bulkActions: selectedSceneIDs.count > 1 && selectedSceneIDs.contains(scene.id)
                      ? SceneBulkActions(
                            count: selectedSceneIDs.count,
                            grade: { score in bulkGrade(score, in: filtered) },
                            curate: { bulkSetCurated(in: filtered) },
                            hide: { bulkSetHidden(in: filtered) },
                            addToBuilder: { bulkAddToBuilder(in: filtered) })
                      : nil,
                  stackMembers: stack,
                  onPickFromStack: stack != nil ? { stackPickerID = scene.id } : nil)
            .overlay {
                if selectedSceneIDs.contains(scene.id) {
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleCardClick(scene, in: filtered)
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                if stack != nil { stackPickerID = scene.id }
            }
            .popover(isPresented: Binding(
                get: { stackPickerID == scene.id },
                set: { if !$0 { stackPickerID = nil } })
            ) {
                if let stack {
                    SceneStackPicker(members: stack,
                                     onPick: { pick in
                                         stackPickerID = nil
                                         store.chooseStackBest(pick, among: stack)
                                     },
                                     onPreview: { previewScene = $0 })
                }
            }
            .accessibilityAddTraits(selectedSceneIDs.contains(scene.id) ? .isSelected : [])
    }

    // MARK: - Grid selection & keyboard triage

    /// The selection in the grid's display order.
    private func orderedSelection(in filtered: [SceneRecord]) -> [SceneRecord] {
        filtered.filter { selectedSceneIDs.contains($0.id) }
    }

    private func handleCardClick(_ scene: SceneRecord, in filtered: [SceneRecord]) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if selectedSceneIDs.contains(scene.id) {
                selectedSceneIDs.remove(scene.id)
            } else {
                selectedSceneIDs.insert(scene.id)
                selectionAnchorID = scene.id
            }
        } else if modifiers.contains(.shift), let anchor = selectionAnchorID,
                  let anchorIndex = filtered.firstIndex(where: { $0.id == anchor }),
                  let clickedIndex = filtered.firstIndex(where: { $0.id == scene.id }) {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            selectedSceneIDs = Set(filtered[range].map(\.id))
        } else {
            selectedSceneIDs = [scene.id]
            selectionAnchorID = scene.id
        }
        gridFocused = true
    }

    private func moveSelection(_ direction: MoveCommandDirection,
                               in filtered: [SceneRecord], proxy: ScrollViewProxy) {
        guard !filtered.isEmpty else { return }
        let current = selectionAnchorID.flatMap { id in
            filtered.firstIndex(where: { $0.id == id })
        }
        var next: Int
        switch (current, direction) {
        case (nil, _): next = 0
        case (let index?, .left): next = max(0, index - 1)
        case (let index?, .right): next = min(filtered.count - 1, index + 1)
        case (let index?, .up): next = index - gridColumns >= 0 ? index - gridColumns : index
        case (let index?, .down): next = index + gridColumns < filtered.count ? index + gridColumns : index
        @unknown default: return
        }
        let target = filtered[next]
        if NSEvent.modifierFlags.contains(.shift), let index = current {
            // ⇧-arrows extend from the current position; the anchor moves so
            // repeated presses keep growing the run.
            let range = min(index, next)...max(index, next)
            selectedSceneIDs.formUnion(filtered[range].map(\.id))
        } else {
            selectedSceneIDs = [target.id]
        }
        selectionAnchorID = target.id
        withAnimation { proxy.scrollTo(target.id) }
    }

    /// Grid keys: Space previews, ⏎ opens the Curate workbench, G/5 grades
    /// good, B/1 grades bad, F favorites, C curates, ⌘A selects all.
    private func handleKey(_ press: KeyPress, in filtered: [SceneRecord]) -> KeyPress.Result {
        let selection = orderedSelection(in: filtered)
        if press.modifiers.contains(.command) {
            if press.characters == "a" {
                selectedSceneIDs = Set(filtered.map(\.id))
                selectionAnchorID = filtered.last?.id
                return .handled
            }
            return .ignored
        }
        switch press.characters {
        case " ":
            guard let scene = selection.last ?? selection.first else { return .ignored }
            previewScene = scene
            return .handled
        case "\r":
            guard selection.count == 1, let scene = selection.first else { return .ignored }
            curatingScene = scene
            return .handled
        case "g", "5":
            guard !selection.isEmpty else { return .ignored }
            bulkGrade(5, in: filtered)
            return .handled
        case "b", "1":
            guard !selection.isEmpty else { return .ignored }
            bulkGrade(1, in: filtered)
            return .handled
        case "f":
            guard !selection.isEmpty else { return .ignored }
            bulkToggleFavorite(in: filtered)
            return .handled
        case "h":
            guard !selection.isEmpty else { return .ignored }
            bulkSetHidden(in: filtered)
            return .handled
        case "c":
            guard !selection.isEmpty else { return .ignored }
            bulkSetCurated(in: filtered)
            return .handled
        default:
            return .ignored
        }
    }

    private func bulkGrade(_ score: Int, in filtered: [SceneRecord]) {
        for scene in orderedSelection(in: filtered) {
            store.grade(scene, score: score)
        }
    }

    private func bulkToggleFavorite(in filtered: [SceneRecord]) {
        // "Make it so" semantics: any non-favorite → favorite all.
        let selection = orderedSelection(in: filtered)
        let makeFavorite = selection.contains { !$0.favorite }
        for scene in selection where scene.favorite != makeFavorite {
            store.toggleFavorite(scene)
        }
    }

    private func bulkSetCurated(in filtered: [SceneRecord]) {
        let selection = orderedSelection(in: filtered)
        guard !selection.isEmpty else { return }
        // Single scene goes through the full Curate workbench; a batch is
        // marked curated directly (trim/framing stay editable afterwards).
        if selection.count == 1, let scene = selection.first, !scene.curated {
            curatingScene = scene
            return
        }
        let makeCurated = selection.contains { !$0.curated }
        for scene in selection where scene.curated != makeCurated {
            store.curateScene(scene, curated: makeCurated)
        }
    }

    private func bulkSetHidden(in filtered: [SceneRecord]) {
        let selection = orderedSelection(in: filtered)
        let hide = selection.contains { !$0.excluded }
        for scene in selection where scene.excluded != hide {
            store.setExcluded(scene, excluded: hide)
        }
    }

    private func bulkAddToBuilder(in filtered: [SceneRecord]) {
        for scene in orderedSelection(in: filtered) {
            store.builder.addScene(scene)
        }
        store.requestedSection = .builder
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
                            Text("This analyze batch predates note snapshots — showing the video's current notes, which may differ from what the run used.")
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
                .help("Opens Raw Videos with this analyze batch's options loaded into the model plan — adjust anything, then start. The result lands in a new analyze batch.")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 440)
        .frame(minHeight: 360)
        .modalCloseButton { dismiss() }
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

/// Actions a SceneCard offers in its context menu when it's part of a
/// multi-selection — supplied by the grid, which owns the selection.
struct SceneBulkActions {
    var count: Int
    var grade: (Int) -> Void
    var curate: () -> Void
    var hide: () -> Void
    var addToBuilder: () -> Void
}

struct SceneCard: View {
    @Environment(AppStore.self) private var store
    let scene: SceneRecord
    let onTranscript: () -> Void
    /// Opens the Curate workbench modal (framing + trim → save as curated).
    var onCurate: (() -> Void)?
    /// Present when the card sits inside a multi-selection.
    var bulkActions: SceneBulkActions?
    /// Set when this card fronts a stack of near-simultaneous takes (2+
    /// members, this scene first) — draws the stack badge and deck chrome.
    var stackMembers: [SceneRecord]?
    /// Opens the stack picker (also reachable by long-pressing the card).
    var onPickFromStack: (() -> Void)?

    /// Actions broken out of this scene (it's a sequence when > 0).
    private var childCount: Int {
        store.scenes.count(where: { $0.parentSceneID == scene.id })
    }

    /// Takes hidden behind this card (0 when it isn't a stack).
    private var stackedCount: Int {
        max(0, (stackMembers?.count ?? 0) - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SceneInlinePlayer(scene: scene)
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    DurationBadge(seconds: scene.duration)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    if let score = scene.score {
                        ScoreBadge(score: score)
                            .padding(6)
                            .allowsHitTesting(false)
                            .help(scene.narrative ?? "Entertainment score")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        if scene.wide {
                            WideBadge()
                        }
                        if childCount > 0 {
                            Text("SEQ · \(childCount)")
                                .font(.caption2.bold())
                                .padding(3)
                                .background(.purple.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white)
                                .help("A sequence broken into \(childCount) action scene(s) — show them with the Sequence Actions toggle in the Filter menu")
                        }
                        if stackedCount > 0 {
                            SceneStackBadge(count: stackedCount + 1,
                                            userPicked: scene.stackChoice)
                        }
                    }
                    .padding(6)
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
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
                    Label(scene.curated ? "Remove from Curated" : "Curate Scene",
                          systemImage: scene.curated ? "checkmark.seal.fill" : "checkmark.seal")
                        .foregroundStyle(scene.curated ? .green : .secondary)
                }
                .help(scene.curated
                      ? "In the Curated set — click to remove"
                      : "Curate this scene: preview and apply Center Stage, trim, then save it as good to go")

                Button {
                    store.toggleFavorite(scene)
                } label: {
                    Label(scene.favorite ? "Unfavorite" : "Favorite",
                          systemImage: scene.favorite ? "heart.fill" : "heart")
                        .foregroundStyle(scene.favorite ? .red : .secondary)
                }
                .help(scene.favorite ? "Remove from favorites" : "Favorite")

                // The last grade stays stamped on the card, so graded scenes
                // are tellable from ungraded while triaging the grid.
                Button {
                    store.grade(scene, score: 5)
                } label: {
                    Label("Good Scene",
                          systemImage: (scene.lastGrade ?? 0) >= 3 ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .foregroundStyle((scene.lastGrade ?? 0) >= 3 ? .green : .secondary)
                }
                .help("Good scene (grade 5)")

                Button {
                    store.grade(scene, score: 1)
                } label: {
                    Label("Bad Scene",
                          systemImage: scene.lastGrade.map { $0 < 3 } == true ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .foregroundStyle(scene.lastGrade.map { $0 < 3 } == true ? .red : .secondary)
                }
                .help("Bad scene (grade 1)")

                if let average = scene.gradeAverage, scene.gradeCount > 0 {
                    Text(String(format: "%.1f", average))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Average of \(scene.gradeCount) grade\(scene.gradeCount == 1 ? "" : "s")")
                }

                Spacer()

                Button {
                    onTranscript()
                } label: {
                    Label("Transcript", systemImage: "text.quote")
                }
                .help("Transcript")

                Button {
                    store.setExcluded(scene, excluded: !scene.excluded)
                } label: {
                    Label(scene.excluded ? "Unhide Scene" : "Hide Scene",
                          systemImage: scene.excluded ? "eye" : "eye.slash")
                }
                .help(scene.excluded ? "Unhide scene" : "Hide scene")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(Theme.spaceS)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .sceneStackDeck(count: stackedCount + 1)
        .contextMenu {
            if let bulk = bulkActions {
                Section("\(bulk.count) Selected Scenes") {
                    Button("Grade Good") { bulk.grade(5) }
                    Button("Grade Bad") { bulk.grade(1) }
                    Button("Curate / Uncurate") { bulk.curate() }
                    Button("Hide / Unhide") { bulk.hide() }
                    Button("Add to Builder") { bulk.addToBuilder() }
                }
                Divider()
            }
            if let onPickFromStack {
                Button("Choose Best of \(stackedCount + 1) Similar Scenes…") {
                    onPickFromStack()
                }
                Divider()
            }
            if scene.curated {
                // Non-destructive: trims/framing are kept for re-curation.
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
                    description: Text("Transcribe this video from the Raw Videos screen."))
                    // Fill the sheet's remaining height so the header stays
                    // pinned to the top instead of centering with it.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .modalCloseButton { dismiss() }
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
                    Button("Save") {
                        save(row, text: editText)
                        editingRow = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 420)
            .modalCloseButton { editingRow = nil }
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
