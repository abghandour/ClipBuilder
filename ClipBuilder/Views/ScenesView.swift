import SwiftUI

/// Scene browser + rating: source files on the left, scene cards on the
/// right with favorite/grade voting and transcripts.
struct ScenesView: View {
    @Environment(AppStore.self) private var store
    let curatedOnly: Bool

    init(curatedOnly: Bool = false) {
        self.curatedOnly = curatedOnly
    }

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
    @State private var showAskSheet = false
    @State private var showAICurate = false
    /// Active AI search: the query plus its ranked scene ids — the grid
    /// narrows to these (rank order) until cleared from the banner.
    @State private var aiMatches: (query: String, ids: [Int64], provenance: AIProvenance)?

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

    /// Everything `gridContents` depends on; the memo recomputes only when
    /// one of these changes (a click that only moves selection doesn't).
    private struct GridKey: Equatable {
        var scenesVersion: Int
        var searchText: String
        var runFilter: Set<Int64>?
        var showHidden: Bool
        var tagFilter: String?
        var minScore: Double
        var aiMatchIDs: [Int64]?
        var showSequenceParts: Bool
        var stackLevel: SceneStackLevel
        var sortByScore: Bool
        var curatedOnly: Bool
    }

    @State private var gridMemo = MemoBox<GridKey, GridContents>()

    private var gridContents: GridContents {
        let key = GridKey(scenesVersion: store.scenesVersion, searchText: searchText,
                          runFilter: runFilter, showHidden: showHidden, tagFilter: tagFilter,
                          minScore: minScore, aiMatchIDs: aiMatches?.ids,
                          showSequenceParts: showSequenceParts, stackLevel: stackLevel,
                          sortByScore: sortByScore, curatedOnly: curatedOnly)
        return gridMemo(key) { computeGridContents() }
    }

    private func computeGridContents() -> GridContents {
        let needle = searchText.lowercased()
        let runFilter = runFilter
        var result = store.scenes.filter { scene in
            if curatedOnly && !scene.curated { return false }
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
        // An active AI search narrows to its matches on top of the filters.
        if let aiMatches {
            let allowed = Set(aiMatches.ids)
            result = result.filter { allowed.contains($0.id) }
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
        } else if let aiMatches {
            // Best match first, the way the model ranked them.
            let rank = Dictionary(uniqueKeysWithValues:
                aiMatches.ids.enumerated().map { ($1, $0) })
            contents.scenes.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        }
        return contents
    }

    /// Scenes the AI search runs against: the current batch scope, hidden
    /// scenes excluded — grid filters like tags deliberately don't narrow
    /// the query's reach.
    private var searchCandidates: [SceneRecord] {
        store.scenes.filter { scene in
            if let runFilter, !(scene.runID.map(runFilter.contains) ?? false) { return false }
            return !scene.excluded
        }
    }

    /// The AI Curator's pool: uncurated cards currently in view (stack tops
    /// only). A multi-selection narrows the judging to just those cards.
    private var curateCandidates: [SceneRecord] {
        let pool = gridContents.scenes.filter { !$0.curated && !$0.excluded }
        let selected = pool.filter { selectedSceneIDs.contains($0.id) }
        return selected.count >= 2 ? selected : pool
    }

    private var allTags: [String] {
        store.sceneIndex.allTags
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
            VStack(spacing: 0) {
                if let aiMatches {
                    aiSearchBanner(aiMatches)
                    Divider()
                }
                sceneGrid(contents)
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenTitle("Scenes", subtitle: selectedSceneIDs.count > 1 ? "\(selectedSceneIDs.count) of \(filtered.count) scenes selected" : curatedOnly ? "\(filtered.count) curated scenes" : stackedAway > 0 ? "\(filtered.count) moments — \(filtered.count + stackedAway) scenes" : "\(filtered.count) scenes")
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
                Button {
                    showAskSheet = true
                } label: {
                    ToolbarBubbleLabel(text: "Ask", systemImage: "sparkle.magnifyingglass")
                }
                .disabled(searchCandidates.isEmpty)
                .help("Describe a moment in plain language — the AI reads every scene's story, tags, and people and filters the grid to the matches, best first")
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
                    showAICurate = true
                } label: {
                    ToolbarBubbleLabel(text: "AI Curate", systemImage: "checkmark.seal")
                }
                .disabled(curateCandidates.isEmpty)
                .help("The AI judges the uncurated scenes in view against your taste rubric and grading history and proposes keepers for the Curated set — every pick reviewed before applying. Select 2+ scenes to judge just those.")
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
        .sheet(isPresented: $showAskSheet) {
            SceneSearchSheet(candidates: searchCandidates) { query, ids, provenance in
                aiMatches = (query, ids, provenance)
                selectedSceneIDs = []
            }
        }
        .sheet(isPresented: $showAICurate) {
            AICurateSheet(candidates: curateCandidates)
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
        .onAppear { restoreProjectState() }
        .onChange(of: store.projectStateVersion) { restoreProjectState() }
        .onChange(of: persistedSceneState) { saveProjectState() }
    }

    /// Strip above the grid while an AI search filters it — says what was
    /// asked and clears back to the full grid.
    private func aiSearchBanner(_ match: (query: String, ids: [Int64], provenance: AIProvenance)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.secondary)
            Text("AI search: “\(match.query)”")
                .font(.callout)
                .lineLimit(1)
            ProvenanceBadge(provenance: match.provenance, style: .model, role: "Ranked by")
            Spacer()
            Button("Clear") { aiMatches = nil }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
                        if let provenance = run.provenance {
                            ProvenanceBadge(provenance: provenance, role: "Analyzed by", size: 12)
                        }
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
        if let provenance = run.provenance { lines.append("Model: \(provenance.shortLabel)") }
        if !run.instructions.isEmpty { lines.append("Instructions: \(run.instructions)") }
        return lines.joined(separator: "\n")
    }

    private func sceneGrid(_ contents: GridContents) -> some View {
        let filtered = contents.scenes
        return Group {
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label("No Scenes", systemImage: "square.grid.3x3")
                } description: {
                    Text("Run analysis on your source videos to detect scenes.")
                } actions: {
                    Button("Open Raw Videos") { store.requestedSection = .analyze }
                        .buttonStyle(.borderedProminent)
                }
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
                        .scrollTargetLayout()
                        // Column count feeds ↑/↓ keyboard movement.
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                            gridColumns = max(1, Int((width - 32 + Theme.spaceM) / (180 + Theme.spaceM)))
                        }
                    }
                    .scrollPosition(id: Binding(
                        get: { store.sceneScrollID },
                        set: { store.sceneScrollID = $0 }
                    ))
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

    private struct PersistedSceneState: Equatable {
        var runSelection: Set<Int64>
        var sceneSelection: Set<Int64>
        var tagFilter: String?
        var searchText: String
        var showHidden: Bool
        var sortByScore: Bool
        var minimumScore: Double
        var showSequenceParts: Bool
    }

    private var persistedSceneState: PersistedSceneState {
        PersistedSceneState(
            runSelection: selectedRunIDs,
            sceneSelection: selectedSceneIDs,
            tagFilter: tagFilter,
            searchText: searchText,
            showHidden: showHidden,
            sortByScore: sortByScore,
            minimumScore: minScore,
            showSequenceParts: showSequenceParts
        )
    }

    private func saveProjectState() {
        // While a project loads, the local state is the previous project's.
        guard !store.isLoadingProject else { return }
        store.sceneRunSelection = selectedRunIDs
        store.sceneSelection = selectedSceneIDs
        store.sceneTagFilter = tagFilter
        store.sceneSearchText = searchText
        store.sceneShowHidden = showHidden
        store.sceneSortByScore = sortByScore
        store.sceneMinimumScore = minScore
        store.sceneShowSequenceParts = showSequenceParts
    }

    private func restoreProjectState() {
        selectedRunIDs = store.sceneRunSelection.intersection(Set(store.analysisRuns.map(\.id)))
        selectedSceneIDs = store.sceneSelection.intersection(Set(store.scenes.map(\.id)))
        selectionAnchorID = selectedSceneIDs.first
        tagFilter = store.sceneTagFilter
        searchText = store.sceneSearchText
        showHidden = store.sceneShowHidden
        sortByScore = store.sceneSortByScore
        minScore = store.sceneMinimumScore
        showSequenceParts = store.sceneShowSequenceParts
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
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selectedSceneIDs.contains(scene.id) ? .isSelected : [])
            .accessibilityLabel("Select scene from \(scene.videoFilename), \(scene.startTime.timecode) to \(scene.endTime.timecode)")
            .accessibilityValue(selectedSceneIDs.contains(scene.id) ? "Selected" : "Not selected")
            .accessibilityAction(named: "Select Scene") {
                handleCardClick(scene, in: filtered)
            }
            .accessibilityAction(named: "Choose Similar Scene") {
                if stack != nil { stackPickerID = scene.id }
            }
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
        let selection = orderedSelection(in: filtered)
        guard !selection.isEmpty else { return }
        if selection.count == 1, let scene = selection.first {
            store.grade(scene, score: score)
        } else {
            store.gradeScenes(selection, score: score)
        }
    }

    private func bulkToggleFavorite(in filtered: [SceneRecord]) {
        // "Make it so" semantics: any non-favorite → favorite all.
        let selection = orderedSelection(in: filtered)
        let makeFavorite = selection.contains { !$0.favorite }
        let changed = selection.filter { $0.favorite != makeFavorite }
        if changed.count == 1, let scene = changed.first {
            store.toggleFavorite(scene)
        } else {
            store.setScenesFavorite(changed, favorite: makeFavorite)
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
        let changed = selection.filter { $0.curated != makeCurated }
        if changed.count == 1, let scene = changed.first {
            store.curateScene(scene, curated: makeCurated)
        } else {
            store.setScenesCurated(changed, curated: makeCurated)
        }
    }

    private func bulkSetHidden(in filtered: [SceneRecord]) {
        let selection = orderedSelection(in: filtered)
        let hide = selection.contains { !$0.excluded }
        let changed = selection.filter { $0.excluded != hide }
        if changed.count == 1, let scene = changed.first {
            store.setExcluded(scene, excluded: hide)
        } else {
            store.setScenesExcluded(changed, excluded: hide)
        }
    }

    private func bulkAddToBuilder(in filtered: [SceneRecord]) {
        store.addScenesToBuilder(orderedSelection(in: filtered))
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
                LabeledContent("Model") {
                    if let provenance = run.provenance {
                        ProvenanceBadge(provenance: provenance, style: .full, role: "Analyzed by")
                    } else {
                        Text("—")
                    }
                }
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

    /// The analyze batch that produced this scene — its provider/model.
    private var analysisProvenance: AIProvenance? {
        store.analysisRuns.first { $0.id == scene.runID }?.provenance
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
                    HStack(spacing: 4) {
                        if let score = scene.score {
                            ScoreBadge(score: score)
                                .allowsHitTesting(false)
                                .help(scene.narrative ?? "Entertainment score")
                        }
                        if let analysisProvenance {
                            ProvenanceBadge(provenance: analysisProvenance, role: "Analyzed by",
                                            size: 11, plated: true)
                        }
                    }
                    .padding(6)
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
                Spacer()

                Menu("More", systemImage: "ellipsis") {
                    Button(scene.favorite ? "Unfavorite" : "Favorite",
                           systemImage: scene.favorite ? "heart.fill" : "heart") {
                        store.toggleFavorite(scene)
                    }
                    Divider()
                    Button("Good Scene", systemImage: "hand.thumbsup") {
                        store.grade(scene, score: 5)
                    }
                    Button("Bad Scene", systemImage: "hand.thumbsdown") {
                        store.grade(scene, score: 1)
                    }
                    Divider()
                    Button("Transcript", systemImage: "text.quote") {
                        onTranscript()
                    }
                    Button(scene.excluded ? "Unhide Scene" : "Hide Scene",
                           systemImage: scene.excluded ? "eye" : "eye.slash") {
                        store.setExcluded(scene, excluded: !scene.excluded)
                    }
                    Button(scene.isBRoll ? "Remove B-roll Mark" : "Mark as B-roll",
                           systemImage: scene.isBRoll ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle") {
                        store.setSceneBRoll(scene, isBRoll: !scene.isBRoll)
                    }
                }
                .help("Rate, favorite, transcribe, or hide this scene")
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
                store.addScenesToBuilder([scene])
            }
            Button(scene.isBRoll ? "Remove B-roll Mark" : "Mark as B-roll") {
                store.setSceneBRoll(scene, isBRoll: !scene.isBRoll)
            }
        }
    }
}
