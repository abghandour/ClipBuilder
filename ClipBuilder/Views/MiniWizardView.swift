import SwiftUI

/// The three Mini steps share the full Wizard’s saved selections and renderer.
struct MiniWizardView: View {
    @Environment(AppStore.self) private var store
    let profileName: String

    @AppStorage private var videoPath: String
    @AppStorage private var footageKind: MiniWizardFlow.FootageKind
    @AppStorage private var settingsTab: MiniWizardFlow.SettingsTab
    @AppStorage private var length: MiniWizardFlow.Length
    @FocusState private var instructionsFocused: Bool
    @State private var instructionsDirty = false
    @State private var videos: [VideoRecord] = []
    @State private var projectHasVideos = false
    @State private var podcastVideoIDs: Set<Int64> = []
    @State private var loadedProjectID: Int64?
    @State private var loadedGeneration: Int?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadID = 0
    @State private var miniSettings = MiniWizardSettings()
    @State private var presetSheet: PresetSheet?
    @State private var loadedPreset: MiniWizardPresetStore.Loaded?
    @State private var settingsProfile: String?
    @State private var transcriptLanguage: String?
    @State private var hasTranscript = false
    @State private var collapsedCard: MiniWizardFlow.Card?
    /// Navigation before a run exists; a run carries its own requested card.
    @State private var pendingCard: MiniWizardFlow.Card = .source

    init(profileName: String) {
        self.profileName = profileName
        _videoPath = AppStorage(wrappedValue: "", MiniWizardMemory.key(for: .videoPath, profileName: profileName))
        _footageKind = AppStorage(wrappedValue: .highlights, MiniWizardMemory.key(for: .footageKind, profileName: profileName))
        _settingsTab = AppStorage(wrappedValue: .picture, MiniWizardMemory.key(for: .settingsTab, profileName: profileName))
        _length = AppStorage(wrappedValue: .automatic, MiniWizardMemory.key(for: .length, profileName: profileName))
    }

    private struct SourceKey: Equatable {
        var generation: Int
        var projectID: Int64?
        var videosVersion: Int
        var scenesVersion: Int
        var reloadID: Int
    }

    private var sourceKey: SourceKey {
        SourceKey(generation: store.profileGeneration, projectID: store.activeProjectID,
                  videosVersion: store.videosVersion, scenesVersion: store.scenesVersion, reloadID: reloadID)
    }

    private var projectVideos: [VideoRecord] {
        guard loadedProjectID == store.activeProjectID, loadedGeneration == store.profileGeneration else { return [] }
        return videos
    }

    private var selectedVideo: VideoRecord? { projectVideos.first { $0.path == videoPath } }

    private var currentRun: MiniWizardRun? {
        guard let run = store.miniRun, run.projectID == store.activeProjectID,
              run.video.path == selectedVideo?.path, (run.footageKind != .highlights || run.length == length) else { return nil }
        // The same rule the Footage picker uses, so a Transcript run on an
        // ordinary video with a transcript is recognised as the current run.
        let expected = MiniWizardFlow(video: run.video,
                                      hasPodcastExchangeScenes: podcastVideoIDs.contains(run.video.id),
                                      hasTranscript: hasTranscript, footageKind: footageKind).effectiveFootageKind
        guard run.footageKind == expected else { return nil }
        return run
    }

    private var flow: MiniWizardFlow {
        MiniWizardFlow(video: selectedVideo,
                       hasPodcastExchangeScenes: selectedVideo.map { podcastVideoIDs.contains($0.id) } ?? false,
                       hasTranscript: hasTranscript,
                       footageKind: footageKind, length: length,
                       captionsEnabled: miniSettings.captions, transcriptLanguage: transcriptLanguage,
                       hasFootage: currentRun?.hasFootage == true,
                       hasKeptFootage: (currentRun?.keptCount ?? 0) > 0,
                       requestedCard: currentRun?.requestedCard ?? pendingCard, collapsedCard: collapsedCard,
                       outputMode: miniSettings.outputMode)
    }

    private var instructions: Binding<String> {
        Binding(
            get: { store.activeProfile.profileName == profileName ? store.activeProfile.miniInstructions ?? "" : "" },
            set: { text in
                guard store.activeProfile.profileName == profileName else { return }
                store.activeProfile.miniInstructions = text.isEmpty ? nil : text
                instructionsDirty = true
            }
        )
    }

    var body: some View {
        HSplitView {
            settingsColumn.frame(minWidth: 480, maxWidth: .infinity)
            if let video = selectedVideo {
                WizardPreviewColumn(scenes: store.scenes.filter { $0.videoID == video.id },
                    clips: currentRun.map { WizardPreviewClips.kept(run: $0, scenes: store.scenes) } ?? [],
                    options: miniSettings.effective(for: flow,
                        introAvailable: store.bumpers.contains { $0.placements.contains(.intro) },
                        outroAvailable: store.bumpers.contains { $0.placements.contains(.outro) })
                        .previewOptions(profile: store.activeProfile),
                    profile: store.activeProfile, thumbnails: store.thumbnails,
                    footer: generateFooter,
                    onMove: { element, position in
                        switch element {
                        case .caption(let slot):
                            if let slot {
                                var positions = miniSettings.speakerCaptionPositions ?? [:]
                                positions[slot] = position.string
                                miniSettings.speakerCaptionPositions = positions
                            } else { miniSettings.captionPosition = position.string }
                        case .nameTag: miniSettings.nameTagPosition = position.string
                        case .overlay: miniSettings.overlayPosition = position.string
                        }
                    })
                    .id("\(store.profileGeneration):\(store.activeProjectID ?? 0):\(video.id)")
                    .rememberedPaneWidth("pane.express.preview", min: 240, initial: 320, max: 480)
            }
        }
        .screenTitle("AI Wizard Express")
        .sheet(item: $presetSheet) { sheet in
            let lastUsed = UserDefaults.standard.string(forKey: MiniWizardPresetStore.lastUsedKey(profileName: profileName))
            switch sheet {
            case .save:
                PresetSaveSheet(title: "Save Settings", lastUsed: lastUsed,
                                presets: { store.expressPresets(profileName: profileName) },
                                make: { MiniWizardPreset(name: $0, savedAt: Date(), settings: miniSettings) },
                                persist: { store.saveExpressPresets($0, profileName: profileName) }) { preset in
                    MiniWizardPresetStore.rememberLoaded(.init(name: preset.name, settings: preset.settings), profileName: profileName)
                    loadedPreset = MiniWizardPresetStore.loaded(profileName: profileName)
                }
            case .load:
                PresetLoadSheet(title: "Load Settings", lastUsed: lastUsed,
                                presets: { store.expressPresets(profileName: profileName) },
                                persist: { store.saveExpressPresets($0, profileName: profileName) },
                                summary: { preset in
                                    preset.savedAt.formatted(date: .abbreviated, time: .shortened) + " · "
                                        + MiniWizardFlow(outputMode: preset.settings.outputMode).settingsSummary(preset.settings)
                                },
                                onLoad: { preset in
                                    MiniWizardPresetStore.rememberLoaded(.init(name: preset.name, settings: preset.settings), profileName: profileName)
                                    miniSettings = preset.settings
                                    loadedPreset = MiniWizardPresetStore.loaded(profileName: profileName)
                                },
                                onRenamed: { oldName, newName in
                                    guard let tracked = MiniWizardPresetStore.loaded(profileName: profileName), tracked.name == oldName else { return }
                                    MiniWizardPresetStore.rememberLoaded(newName.map { .init(name: $0, settings: tracked.settings) }, profileName: profileName)
                                    loadedPreset = MiniWizardPresetStore.loaded(profileName: profileName)
                                },
                                imports: ("From the AI Wizard",
                                          WizardPresetBridge.miniPresets(from: store.wizardPresets(profileName: profileName))))
            }
        }
        .task(id: sourceKey) { await loadSources() }
        .onAppear(perform: restoreAnswers)
        .onChange(of: store.profileGeneration) { _, _ in restoreAnswers() }
        .onChange(of: miniSettings) { _, value in
            guard settingsProfile == profileName, store.activeProfile.profileName == profileName else { return }
            value.remember(profileName: profileName)
        }
        .task(id: transcriptKey) { await loadTranscriptLanguage() }
        .onChange(of: store.scenesVersion) { _, _ in store.refreshMiniQASections() }
        // Navigation from a finished step (generate, keep) reopens the page.
        .onChange(of: currentRun?.requestedCard) { _, _ in collapsedCard = nil }
        .onChange(of: autoLoadKey, initial: true) { _, key in autoLoad(key) }
        // A load skipped while another run was busy, or while sources were
        // still loading, happens once that finishes.
        .onChange(of: store.isWizardRunning) { _, running in if !running { autoLoad(autoLoadKey) } }
        .onChange(of: isLoading) { _, loading in if !loading { autoLoad(autoLoadKey) } }
        .onChange(of: instructionsFocused) { _, focused in
            if !focused { saveInstructions() }
        }
        .onDisappear { saveInstructions() }
    }

    /// The run summary and Generate sit under the preview, outside the
    /// collapsible cards, so a collapsed Settings card never hides the button.
    private var generateFooter: AnyView? {
        guard let run = currentRun, flow.canExpand(.settings), settingsProfile == profileName else { return nil }
        return AnyView(MiniGeneratePanel(settings: $miniSettings, flow: flow, run: run))
    }

    private var settingsColumn: some View {
        GeometryReader { page in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spaceL) {
                    MiniCard(number: 1, title: "Source", summary: flow.summary(for: .source),
                             isOpen: !flow.isCollapsed(.source), headerTap: headerTap(.source)) {
                        if !flow.isCollapsed(.source) {
                            sourceGrid.disabled(store.isWizardRunning)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    MiniCard(number: 2, title: "Footage",
                             summary: currentRun?.summary ?? flow.summary(for: .footage),
                             isOpen: !flow.isCollapsed(.footage),
                             headerTap: headerTap(.footage)) {
                        if !flow.isCollapsed(.footage) {
                            if selectedVideo == nil {
                                FormCaption("Pick a source in 1 Source first.")
                            } else {
                                footageControls.disabled(store.isWizardRunning)
                                if let run = currentRun {
                                    Divider()
                                    MiniFootageCard(run: run, pageHeight: page.size.height)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    MiniCard(number: 3,
                        title: MiniWizardPresetStore.cardTitle(loaded: loadedPreset, current: miniSettings),
                        summary: flow.canExpand(.settings)
                            ? flow.settingsSummary(miniSettings.effective(for: flow,
                                introAvailable: store.bumpers.contains { $0.placements.contains(.intro) },
                                outroAvailable: store.bumpers.contains { $0.placements.contains(.outro) }))
                            : flow.summary(for: .settings),
                        isOpen: flow.visibleCard == .settings && settingsProfile == profileName,
                        headerTap: headerTap(.settings),
                        accessory: AnyView(presetButtons)) {
                        if flow.visibleCard == .settings, settingsProfile == profileName {
                            if let run = currentRun, flow.canExpand(.settings) {
                                MiniSettingsCard(settings: $miniSettings, tab: $settingsTab, flow: flow, run: run)
                            } else {
                                FormCaption(selectedVideo == nil ? "Pick a source in 1 Source first."
                                    : "Choose and keep footage in 2 Footage first.")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(Theme.spaceXL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func open(_ card: MiniWizardFlow.Card) {
        collapsedCard = nil
        pendingCard = card
        store.miniRun?.requestedCard = card
    }

    /// Clicking a card's header toggles it; any card opens at any time.
    private func headerTap(_ card: MiniWizardFlow.Card) -> (() -> Void)? {
        {
            guard let click = flow.headerClick(card) else { return }
            collapsedCard = click.collapsed
            if click.collapsed == nil {
                pendingCard = click.requested
                store.miniRun?.requestedCard = click.requested
                if click.requested == .settings { keepFootageForSettings() }
            }
        }
    }

    /// Q&A and Transcript picks become kept footage when Settings opens (the
    /// step the old "Video Generation Settings" button performed).
    private func keepFootageForSettings() {
        guard let run = currentRun, run.keptCount > 0, !store.isWizardRunning else { return }
        switch run.footageKind {
        case .qa: store.recordMiniQASelections()
        case .transcript: store.recordMiniTranscriptSelections()
        case .fightMetrics: store.recordMiniFightSelections()
        case .highlights: break
        }
    }

    @ViewBuilder
    private var footageControls: some View {
        if flow.showsFootageKind {
            MiniRow("Footage") {
                Picker("Footage", selection: $footageKind) {
                    ForEach(flow.footageKinds, id: \.self) { kind in
                        Text(kind.label).lineLimit(1).fixedSize().tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Footage")
            }
        }
        if flow.showsLength {
            MiniRow("Length") {
                Picker("Length", selection: $length) {
                    ForEach(flow.lengthOptions, id: \.self) { option in
                        Text(option.label).lineLimit(1).fixedSize().tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Length")
            }
        }
        // Only Highlights asks a model, so only Highlights has instructions
        // and a model to choose. Q&A lists the exchanges analysis found.
        let usesAI = flow.effectiveFootageKind == .highlights
        if usesAI {
            FormGroupHeader("Instructions for the AI")
            TextEditor(text: instructions)
                .font(.body)
                .frame(minHeight: 80, idealHeight: 100)
                .focused($instructionsFocused)
                .accessibilityLabel("Instructions for the AI")
                .onSubmit { saveInstructions() }
            FormCaption("Optional. Saved with this profile and shared by its projects.")
            HStack(spacing: Theme.spaceS) {
                Button {
                    instructionsFocused = false
                    saveInstructions()
                    store.generateMiniFootage(flow: flow)
                } label: {
                    Text("Generate highlights").lineLimit(1).fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedVideo == nil || store.isWizardRunning)
                MiniModelButton(tasks: [flow.isPodcastOrInterview ? "highlights" : "wizard"])
            }
        } else {
            // Q&A, Transcript and Fight metrics load on their own (see autoLoadKey); no button to press.
            let kind = flow.effectiveFootageKind
            let caption: String = switch kind {
                case .qa: "Q&A lists the question-and-answer exchanges found when this video was analyzed. No AI model runs for this step."
                case .fightMetrics: "Fight metrics lists every scored action in time order. Select actions and add them as separate picks or as one stretch. Picks are kept with this video. No AI model runs for this step."
                default: "Transcript shows every spoken line. Mark a passage and press Add. Picks are kept with this video. No AI model runs for this step."
            }
            let loading: String = switch kind {
                case .qa: "Loading Q&A exchanges…"
                case .fightMetrics: "Loading fight actions…"
                default: "Loading transcript…"
            }
            FormCaption(caption)
            if let selectedVideo, !selectedVideo.isPresent {
                FormCaption(VideoRecord.notPresentReason, tone: .warning)
            } else if currentRun == nil, store.isWizardRunning {
                ProgressView(loading)
            }
        }
    }

    private struct AutoLoadKey: Equatable {
        var videoID: Int64?
        var kind: MiniWizardFlow.FootageKind?
        var hasRun: Bool
    }

    /// Q&A, Transcript and Fight metrics need no model: they load as soon as a
    /// source is chosen, whichever card is open, so saved picks count as kept
    /// footage after a relaunch without a visit to the Footage card.
    private var autoLoadKey: AutoLoadKey {
        let kind = flow.effectiveFootageKind
        return AutoLoadKey(videoID: selectedVideo?.id,
                           kind: kind != .highlights ? kind : nil,
                           hasRun: currentRun != nil)
    }

    private func autoLoad(_ key: AutoLoadKey) {
        guard key.kind != nil, !key.hasRun, let selectedVideo, selectedVideo.isPresent,
              !store.isWizardRunning, !isLoading else { return }
        store.generateMiniFootage(flow: flow)
    }

    @ViewBuilder
    private var sourceGrid: some View {
        if let loadError {
            FormCaption(loadError, tone: .warning)
            Button { reloadID += 1 } label: {
                Text("Reload sources").lineLimit(1).fixedSize()
            }
        } else if isLoading && projectVideos.isEmpty {
            ProgressView("Loading analyzed videos…")
        } else if projectVideos.isEmpty {
            FormCaption("No analyzed videos in this project")
            Button { store.requestedSection = .sources } label: {
                Text("Open Sources").lineLimit(1).fixedSize()
            }
            if projectHasVideos {
                FormCaption("Analyze a video first")
                Button { store.requestedSection = .analyze } label: {
                    Text("Open Analyze").lineLimit(1).fixedSize()
                }
            }
        } else {
            FormCaption("Choose one analyzed video.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: Theme.spaceM,
                                        alignment: .top)], spacing: Theme.spaceM) {
                ForEach(projectVideos) { video in
                    sourceCell(video)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceCell(_ video: VideoRecord) -> some View {
        let selected = selectedVideo?.id == video.id
        return Button {
            instructionsFocused = false
            videoPath = video.path ?? ""
        } label: {
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                VideoThumbnail(url: video.url, time: min(1, video.duration / 2), cornerRadius: Theme.mediaRadius)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.mediaRadius)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(Theme.spaceXS)
                        }
                    }
                Text(video.filename)
                    .font(.caption)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.middle)
                Text("\(video.type?.label ?? "Unknown type") · \(video.duration.timecode)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(video.filename), \(video.type?.label ?? "Unknown type"), \(video.duration.timecode)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Choose \(video.filename)")
    }

    private func loadSources() async {
        let key = sourceKey
        guard let database = store.database, let projectID = key.projectID else {
            videos = []
            podcastVideoIDs = []
            projectHasVideos = false
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        do {
            let fetchedVideos = try await database.fetchVideos(projectID: projectID)
            let scenes = try await database.fetchScenes(projectID: projectID, scope: .active)
            guard !Task.isCancelled, key == sourceKey, store.activeProfile.profileName == profileName else { return }
            let analyzedIDs = Set(scenes.map(\.videoID))
            videos = fetchedVideos.filter { $0.analyzedAt != nil && analyzedIDs.contains($0.id) }
            projectHasVideos = !fetchedVideos.isEmpty
            let validated = MiniWizardMemory.validatedVideoPath(videoPath, videos: videos)
            if validated != videoPath {
                if store.miniRun?.projectID == projectID, store.miniRun?.video.path == videoPath {
                    store.miniRun = nil
                }
                videoPath = validated
            }
            podcastVideoIDs = Set(scenes.filter { $0.tags.contains("podcast-exchange") }.map(\.videoID))
            loadedProjectID = projectID
            loadedGeneration = key.generation
            isLoading = false
        } catch {
            guard !Task.isCancelled, key == sourceKey, store.activeProfile.profileName == profileName else { return }
            videos = []
            podcastVideoIDs = []
            loadError = "Could not load analyzed videos: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private var transcriptKey: String {
        "\(store.profileGeneration):\(selectedVideo?.id ?? -1):\(store.videosVersion):\(store.scenesVersion)"
    }

    private func loadTranscriptLanguage() async {
        transcriptLanguage = nil
        hasTranscript = false
        let key = transcriptKey
        guard let video = selectedVideo, let database = store.database else { return }
        // Original segments carry the language; translated English rows must not hide this choice.
        let language = try? await database.originalTranscriptLanguage(videoID: video.id)
        guard !Task.isCancelled, key == transcriptKey else { return }
        transcriptLanguage = language
        hasTranscript = language != nil
    }

    /// Save the current answers under a name, or bring back a saved set.
    private var presetButtons: some View {
        HStack(spacing: Theme.spaceS) {
            Button {
                presetSheet = .save
            } label: {
                Label("Save…", systemImage: "square.and.arrow.down").lineLimit(1).fixedSize()
            }
            .help("Save these settings under a name")
            Button {
                presetSheet = .load
            } label: {
                Label("Load…", systemImage: "tray.and.arrow.up").lineLimit(1).fixedSize()
            }
            .help("Load, rename or delete saved settings")
            Button {
                // Back to the profile's starting point; the preview follows the settings.
                miniSettings = MiniWizardSettings.defaults(profile: store.activeProfile)
                MiniWizardPresetStore.rememberLoaded(nil, profileName: profileName)
                loadedPreset = nil
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise").lineLimit(1).fixedSize()
            }
            .help("Restore every setting to its default")
        }
        .controlSize(.small)
        .disabled(store.isWizardRunning)
    }

    private func restoreAnswers() {
        guard store.activeProfile.profileName == profileName else { return }
        // Source answers use profile-keyed AppStorage; Settings restores from the same key catalog.
        miniSettings = MiniWizardSettings.remembered(profile: store.activeProfile)
        loadedPreset = MiniWizardPresetStore.loaded(profileName: profileName)
        settingsProfile = profileName
        store.refreshMiniQASections()
    }

    private func saveInstructions() {
        guard instructionsDirty, store.activeProfile.profileName == profileName else { return }
        store.saveActiveProfile()
        instructionsDirty = false
    }
}
