import SwiftUI

/// The Express cards share the full Wizard’s saved selections and renderer.
struct MiniWizardView: View {
    @Environment(\.workspacePageVisible) private var pageVisible
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
    /// Videos with active scenes; the others in `videos` are transcript-only.
    @State private var sceneVideoIDs: Set<Int64> = []
    @State private var transcriptVideoID: Int64?
    @State private var confirmRemoveBRoll = false
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
        guard let video = selectedVideo else { return nil }
        let expected = MiniWizardFlow(video: video,
            hasPodcastExchangeScenes: podcastVideoIDs.contains(video.id),
            hasTranscript: hasTranscript, hasScenes: sceneVideoIDs.contains(video.id),
            footageKind: footageKind).effectiveFootageKind
        guard let run = store.miniRuns[expected], run.projectID == store.activeProjectID,
              run.video.id == video.id, (expected != .highlights || run.length == length) else { return nil }
        return run
    }

    /// Every loaded section for the source, in a fixed order so each keeps
    /// its view identity across switches.
    private var mountedRuns: [MiniWizardRun] {
        guard let video = selectedVideo, let projectID = store.activeProjectID else { return [] }
        return MiniWizardFlow.FootageKind.allCases.compactMap { kind in
            guard let run = store.miniRuns[kind], run.projectID == projectID, run.video.id == video.id,
                  kind != .highlights || run.length == length else { return nil }
            return run
        }
    }

    /// The open section's review, with the other loaded sections kept
    /// mounted but hidden: switching back costs no rebuild of their word
    /// layouts and lists, and their scroll and selection state survive.
    /// Hidden sections take no height, no clicks, no accessibility focus,
    /// and see the page as hidden so their players pause.
    private func footageReviews(pageHeight: CGFloat) -> some View {
        let openKind = currentRun?.footageKind
        return ZStack(alignment: .top) {
            ForEach(mountedRuns, id: \.footageKind) { run in
                let visible = run.footageKind == openKind
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    MiniFootageCard(run: run, pageHeight: pageHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: visible ? nil : 0, alignment: .top)
                .clipped()
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)
                .environment(\.workspacePageVisible, visible && pageVisible)
            }
        }
    }

    /// The List tab: drops reorder the reel, Delete takes a clip out of it.
    private var previewListConfig: WizardPreviewListConfig {
        WizardPreviewListConfig(onReorder: { store.reorderMiniReel($0) },
                                canReorder: !store.isWizardRunning,
                                onDelete: { store.removeMiniReelItem(clipID: $0) },
                                onDeleteAll: { store.removeAllMiniReelItems() },
                                onSelect: { store.revealMiniReelItem(clipID: $0) },
                                summary: generateSummary)
    }

    /// The output format's width / height, for the plain player column.
    private var playerAspect: CGFloat {
        let options = miniSettings.effective(for: flow,
            introAvailable: store.bumpers.contains { $0.placements.contains(.intro) },
            outroAvailable: store.bumpers.contains { $0.placements.contains(.outro) })
        return CGFloat(options.previewOptions(profile: store.activeProfile).renderSettings.aspectRatio)
    }

    /// The reel as preview clips: every selected item across the sections.
    private func reelClips(videoID: Int64) -> [WizardPreviewClip] {
        WizardPreviewClips.reel(items: store.miniReelItems, runs: store.miniRuns, videoID: videoID, scenes: store.scenes)
    }

    private var flow: MiniWizardFlow {
        MiniWizardFlow(video: selectedVideo,
                       hasPodcastExchangeScenes: selectedVideo.map { podcastVideoIDs.contains($0.id) } ?? false,
                       hasTranscript: hasTranscript,
                       hasScenes: selectedVideo.map { sceneVideoIDs.contains($0.id) } ?? true,
                       footageKind: footageKind, length: length,
                       captionsEnabled: miniSettings.captions, transcriptLanguage: transcriptLanguage,
                       hasFootage: currentRun?.hasFootage == true || !store.miniReelItems.isEmpty,
                       hasKeptFootage: (currentRun?.keptCount ?? 0) > 0 || !store.miniReelItems.isEmpty,
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
                WizardPlayerColumn(clips: reelClips(videoID: video.id), aspect: playerAspect,
                    footer: generateFooter,
                    headerAccessory: AnyView(MiniStartOverButton(hasChanges: hasChangesToReset, startOver: startOver)),
                    emptyMessage: sceneVideoIDs.contains(video.id) ? "No kept footage yet. Keep footage in the Footage step to play it here."
                        : "No scenes to preview yet. Run Analyze on this source in Sources to see it here.",
                    list: previewListConfig)
                    .id("\(store.profileGeneration):\(store.activeProjectID ?? 0):\(video.id)")
                    .rememberedPaneWidth("pane.express.preview", min: 240, initial: 320, max: 900)
            }
        }
        .screenTitle("AI Wizard", subtitle: "Express")
        .confirmationDialog("Remove all B-rolls from this reel?", isPresented: $confirmRemoveBRoll) {
            Button("Remove All B-Rolls", role: .destructive) {
                guard let run = currentRun else { return }
                store.removeAllMiniBRoll(batchID: run.batchID)
                miniSettings.didEditBRoll()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The kept footage will stay in the reel.") }
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
        .task(id: HistoryKey(generation: store.profileGeneration, scope: historyScope)) {
            if let scope = historyScope { await store.loadHighlightHistory(scope) }
        }
        .onAppear(perform: restoreAnswers)
        .onChange(of: footageKind) { _, kind in
            UITiming.expressTabChanged(to: kind.rawValue)
            if currentRun != nil { UITiming.responseReady(screen: "Express", what: kind.rawValue) }
        }
        .onChange(of: currentRun?.batchID) { _, _ in
            if currentRun != nil { UITiming.responseReady(screen: "Express", what: footageKind.rawValue) }
        }
        .onChange(of: store.profileGeneration) { _, _ in restoreAnswers() }
        // The focus frame was dragged on the previous source's picture.
        .onChange(of: videoPath) { _, _ in miniSettings.framing.focusFrame = nil }
        .onChange(of: miniSettings) { _, value in
            guard settingsProfile == profileName, store.activeProfile.profileName == profileName else { return }
            value.remember(profileName: profileName)
        }
        .task(id: transcriptKey) { await loadTranscriptLanguage() }
        .onChange(of: store.scenesVersion) { _, _ in store.refreshMiniQASections() }
        .onChange(of: store.transcriptCountsVersion) { _, _ in
            if store.isLoadingMiniFootage, [.qa, .transcript].contains(store.miniFootageKind) {
                store.cancelMiniFootageLoad()
                autoLoad(autoLoadKey)
            }
        }
        // Navigation from a finished step (generate, keep) reopens the page.
        .onChange(of: currentRun?.requestedCard) { _, _ in collapsedCard = nil }
        // `initial` so a request parked while this form was being re-created
        // (profile switch, page hidden) runs as soon as it is on screen.
        .onChange(of: store.pendingWizardAssistantRequest, initial: true) { _, request in
            guard let request, store.wizardMode == .express, pageVisible else { return }
            store.pendingWizardAssistantRequest = nil
            runAssistantRequest(request.text)
        }
        // Ask AI suggestions and actions that need this form's settings and
        // flow: only Express's own commands, also when the page comes back
        // into view after one was sent.
        .onAssistantCommand("\(WizardAssistant.expressNamespace).") { runAssistantCommand($0) }
        // What Ask AI reads: the form as resolved here, not the remembered answers.
        .onChange(of: assistantPage, initial: true) { _, page in store.assistant.expressPage = page }
        // Sources → AI Wizard with one video: take it as the source and open
        // Footage so its scenes, exchanges or transcript picks can be chosen.
        .onChange(of: store.pendingExpressSourcePath, initial: true) { _, path in
            guard let path, store.wizardMode == .express, pageVisible else { return }
            store.pendingExpressSourcePath = nil
            instructionsFocused = false
            videoPath = path
            open(.footage)
        }
        // Select on a List row: show that item's section; the section's
        // review selects the item and clears the request.
        .onChange(of: store.miniReelReveal, initial: true) { _, reveal in
            guard let reveal, pageVisible else { return }
            instructionsFocused = false
            if flow.footageKinds.contains(reveal.kind) { footageKind = reveal.kind }
            open(.footage)
        }
        .onChange(of: autoLoadKey, initial: true) { _, key in autoLoad(key) }
        // A load skipped while another run was busy, or while sources were
        // still loading, happens once that finishes.
        .onChange(of: store.isWizardRunning) { _, running in if !running { autoLoad(autoLoadKey) } }
        .onChange(of: isLoading) { _, loading in if !loading { autoLoad(autoLoadKey) } }
        .onChange(of: instructionsFocused) { _, focused in
            if !focused { saveInstructions() }
        }
        .onChange(of: pageVisible) { _, visible in if !visible { saveInstructions() } }
        .onDisappear { saveInstructions() }
    }

    /// The run summary and Generate sit under the preview, outside the
    /// collapsible cards, so a collapsed Settings card never hides the button.
    private var generateFooter: AnyView? {
        guard let projectID = store.activeProjectID, flow.canExpand(.settings), settingsProfile == profileName else { return nil }
        return AnyView(MiniGeneratePanel(settings: $miniSettings, flow: flow, projectID: projectID))
    }

    /// The preview column's Summary tab, under the same condition as the footer.
    private var generateSummary: AnyView? {
        guard let run = currentRun, flow.canExpand(.settings), settingsProfile == profileName else { return nil }
        return AnyView(MiniGenerateSummary(settings: miniSettings, flow: flow, run: run))
    }

    /// Anything a fresh page would not have: a source, a run, a loaded
    /// preset, or a setting that differs from the profile's defaults.
    private var hasChangesToReset: Bool {
        selectedVideo != nil || currentRun != nil || loadedPreset != nil
            || footageKind != .highlights || length != .automatic
            || miniSettings != MiniWizardSettings.defaults(profile: store.activeProfile)
    }

    /// Forget the source, the footage runs and every answer, and reopen
    /// 1 Source. The AI instructions stay: they belong to the profile.
    private func startOver() {
        instructionsFocused = false
        saveInstructions()
        store.resetMiniFootage()
        miniSettings = MiniWizardSettings.defaults(profile: store.activeProfile)
        MiniWizardPresetStore.rememberLoaded(nil, profileName: profileName)
        loadedPreset = nil
        footageKind = .highlights
        length = .automatic
        settingsTab = .picture
        videoPath = ""
        collapsedCard = nil
        pendingCard = .source
        store.appendLog(\.wizardLog, ["Express: reset to Source"])
    }

    private var brollCount: Int {
        currentRun.map { MiniBRollRules.pieces($0).reduce(0) { $0 + $1.cuts.count } } ?? 0
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
                             headerTap: headerTap(.footage),
                             accessory: historyScope.map { AnyView(historyBar($0)) }) {
                        if let scope = historyScope { historyCaption(scope) }
                        if !flow.isCollapsed(.footage) {
                            if selectedVideo == nil {
                                FormCaption("Pick a source in 1 Source first.")
                            } else {
                                footageControls.disabled(store.isWizardRunning)
                                // Space, not a rule, parts the controls from the review.
                                footageReviews(pageHeight: page.size.height)
                                    .padding(.top, Theme.spaceS)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if flow.isPodcastOrInterview {
                        MiniCard(number: 3, title: "B-roll", summary: flow.summary(for: .broll),
                            isOpen: flow.visibleCard == .broll, headerTap: headerTap(.broll),
                            accessory: brollCount > 0 ? AnyView(Text(brollCount == 1 ? "1 B-roll" : "\(brollCount) B-rolls")
                                .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                                .padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: .capsule)) : nil) {
                            if flow.visibleCard == .broll {
                                Button("Remove All B-Rolls", role: .destructive) { confirmRemoveBRoll = true }
                                    .lineLimit(1).fixedSize().disabled(brollCount == 0 || store.isWizardRunning)
                                if let run = currentRun, flow.canExpand(.broll) {
                                    MiniBRollPanel(run: run, settings: $miniSettings)
                                        .id(run.batchID)
                                } else {
                                    FormCaption("Keep footage in 2 Footage first.")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    MiniCard(number: flow.isPodcastOrInterview ? 4 : 3,
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
                .padding(Theme.spaceL)
                // minWidth 0: a card that still outgrows the column overflows
                // on the right instead of being centred and cut on both sides.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
        // Express cards part their rows with space, not rules.
        .environment(\.settingsRowDividers, false)
    }

    // MARK: - Highlight history

    private struct HistoryKey: Equatable {
        var generation: Int
        var scope: HighlightHistoryScope?
    }

    /// Express history lists the project's saved highlights of this source.
    private var historyScope: HighlightHistoryScope? {
        guard let projectID = store.activeProjectID, let video = selectedVideo, !video.hash.isEmpty else { return nil }
        return .express(projectID: projectID, videoHash: video.hash)
    }

    private func historyBar(_ scope: HighlightHistoryScope) -> some View {
        HighlightHistoryBar(entries: store.highlightHistory(scope), selectedID: store.selectedHighlightIDs[scope],
            unavailable: store.unavailableHighlightIDs, disabled: store.isWizardRunning || settingsProfile != profileName,
            reRenderTitle: "Re-render",
            reRenderHelp: "Open this highlight and render it again with its settings",
            onSelect: { openHighlight($0) }, onOpen: { openHighlight($0) },
            onReRender: { openHighlight($0, thenRender: true) })
    }

    @ViewBuilder
    private func historyCaption(_ scope: HighlightHistoryScope) -> some View {
        if let id = store.selectedHighlightIDs[scope] {
            HighlightHistoryCaption(warning: store.highlightOpenWarnings[id],
                detail: store.openedExpressBatch(for: id) != nil
                    ? store.selectedHighlight(scope).map { record in
                        "Opened " + ([HighlightHistoryNavigation.shortLabel(for: record),
                                      HighlightHistoryNavigation.planSummary(record.plan)]
                            .compactMap { $0 }.joined(separator: " · ")) + ". Its settings are in Settings."
                    } : nil)
        }
    }

    /// Open: the entry's plan becomes the Highlights candidate and its
    /// Settings, length and output mode replace the page's. Re-render opens
    /// it first unless it is the run on screen, then renders.
    private func openHighlight(_ id: Int64, thenRender: Bool = false) {
        guard let scope = historyScope, let video = selectedVideo else { return }
        Task {
            // Re-render of the run on screen needs no Open.
            if !thenRender || store.openedExpressBatch(for: id) == nil {
                guard let opened = await store.openExpressHighlight(id: id, scope: scope, video: video),
                      selectedVideo?.id == video.id else { return }
                instructionsFocused = false
                footageKind = .highlights
                length = opened.length
                if let mini = opened.mini { miniSettings = mini }
                if let mode = opened.outputMode { miniSettings.outputMode = mode }
                collapsedCard = nil
            }
            guard thenRender else { return }
            var renderFlow = flow
            renderFlow.footageKind = .highlights
            renderFlow.length = store.miniRuns[.highlights]?.length ?? length
            renderFlow.outputMode = miniSettings.outputMode
            // The reel now holds the opened candidates (the run change
            // reconciled it); Re-render makes the reel as it stands.
            store.generateMiniReel(settings: miniSettings, flow: renderFlow)
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
                if click.requested == .settings || click.requested == .broll { keepFootage(for: click.requested) }
            }
        }
    }

    /// Q&A and Transcript picks become kept footage when Settings opens (the
    /// step the old "Video Generation Settings" button performed).
    private func keepFootage(for card: MiniWizardFlow.Card) {
        guard let run = currentRun, run.keptCount > 0, !store.isWizardRunning else { return }
        switch run.footageKind {
        case .qa: store.recordMiniQASelections(opening: card) { open(card) }
        case .transcript: store.recordMiniTranscriptSelections(opening: card) { open(card) }
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
                default: "Transcript shows every spoken line. Mark a passage and press Add. Picks are kept with this video; only checked picks become footage. No AI model runs for this step."
            }
            FormCaption(caption)
            if let selectedVideo, !selectedVideo.isPresent {
                FormCaption(VideoRecord.notPresentReason, tone: .warning)
            }
        }
        if currentRun == nil, store.isLoadingMiniFootage {
            ProgressView(store.miniFootageStage ?? "Loading footage…")
        }
    }

    private struct AutoLoadKey: Equatable {
        var videoID: Int64?
        var kind: MiniWizardFlow.FootageKind?
        var hasRun: Bool
        var length: MiniWizardFlow.Length
        var revision: Int
    }

    /// Q&A, Transcript and Fight metrics need no model: they load as soon as a
    /// source is chosen, whichever card is open, so saved picks count as kept
    /// footage after a relaunch without a visit to the Footage card.
    private var autoLoadKey: AutoLoadKey {
        // A source without scenes offers nothing until its transcript check
        // lands; loading Highlights for it would only fail.
        let kind = flow.footageKinds.isEmpty ? nil : flow.effectiveFootageKind
        return AutoLoadKey(videoID: selectedVideo?.id,
                           kind: kind,
                           hasRun: currentRun != nil, length: length, revision: store.miniFootageRevision)
    }

    private func autoLoad(_ key: AutoLoadKey) {
        guard let selectedVideo, !isLoading else { return }
        store.selectMiniFootage(flow: flow)
        guard key.kind != nil, !key.hasRun, selectedVideo.isPresent,
              !store.isWizardRunning else { return }
        if key.kind == .highlights { store.restoreMiniHighlights(flow: flow) }
        else { store.generateMiniFootage(flow: flow) }
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
            FormCaption("No analyzed or transcribed videos in this project")
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
            FormCaption("Choose one analyzed or transcribed video.")
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
        SourceCell(choice: SourceChoice(video), selected: selectedVideo?.id == video.id) {
            instructionsFocused = false
            videoPath = video.path ?? ""
        }
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
            let transcribedIDs = try await database.videoIDsWithOriginalTranscripts()
            guard !Task.isCancelled, key == sourceKey, store.activeProfile.profileName == profileName else { return }
            let analyzedIDs = Set(scenes.map(\.videoID))
            // Analyzed sources offer every footage kind; a source that was only
            // transcribed still offers Transcript picks, so it is listed too.
            sceneVideoIDs = analyzedIDs.filter { id in fetchedVideos.contains { $0.id == id && $0.analyzedAt != nil } }
            // Footage that is not on this Mac is left to Sources (download it there).
            videos = fetchedVideos.filter { $0.isLocal && (sceneVideoIDs.contains($0.id) || transcribedIDs.contains($0.id)) }
            projectHasVideos = fetchedVideos.contains(where: \.isLocal)
            let validated = MiniWizardMemory.validatedVideoPath(videoPath, videos: videos)
            if validated != videoPath {
                store.resetMiniFootage()
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
            sceneVideoIDs = []
            loadError = "Could not load analyzed videos: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private var transcriptKey: String {
        "\(store.profileGeneration):\(selectedVideo?.id ?? -1):\(store.videosVersion):\(store.scenesVersion):\(store.transcriptCountsVersion)"
    }

    private func loadTranscriptLanguage() async {
        if transcriptVideoID != selectedVideo?.id {
            transcriptLanguage = nil
            hasTranscript = false
            transcriptVideoID = selectedVideo?.id
        }
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

    /// Ask AI: the text becomes the Highlights instructions and Generate is pressed.
    private func runAssistantRequest(_ text: String) {
        guard selectedVideo != nil else {
            store.presentNotice("Ask AI", "Choose a source video first.")
            return
        }
        instructionsFocused = false
        instructions.wrappedValue = text
        saveInstructions()
        footageKind = .highlights
        store.generateMiniFootage(flow: flow)
    }

    // MARK: - Ask AI

    private var introAvailable: Bool { store.bumpers.contains { $0.placements.contains(.intro) } }
    private var outroAvailable: Bool { store.bumpers.contains { $0.placements.contains(.outro) } }

    /// The Generate footer's own condition (`generateFooter` plus the
    /// panel's disabled state).
    private var canGenerateKept: Bool {
        guard let projectID = store.activeProjectID, flow.canExpand(.settings), settingsProfile == profileName else { return false }
        return !store.miniReelItems.isEmpty && !store.isWizardRunning && !store.isWizardBatchJobRunning(projectID: projectID)
    }

    /// The Highlights candidate selected in Footage, when the run on screen has one.
    private var selectedCandidate: MiniWizardCandidate? {
        guard let run = currentRun, run.footageKind == .highlights, let id = run.selectedSelectionID else { return nil }
        return run.candidates.first { $0.id == id }
    }

    /// What Ask AI reads from Express (WizardAssistant.ExpressPage).
    private var assistantPage: WizardAssistant.ExpressPage {
        var page = WizardAssistant.ExpressPage()
        let flow = flow
        page.projectID = store.activeProjectID
        page.sourceName = selectedVideo?.filename
        page.sourceSeconds = selectedVideo?.duration
        page.hasTranscript = hasTranscript
        page.footageKind = flow.effectiveFootageKind
        page.length = length
        page.settings = miniSettings.effective(for: flow, introAvailable: introAvailable, outroAvailable: outroAvailable)
        page.keptCount = currentRun?.keptCount ?? 0
        page.canGenerate = canGenerateKept
        page.selectedCandidate = selectedCandidate?.selection.name
        return page
    }

    /// Ask AI actions (WizardAssistant.actions): the same calls this form's
    /// own controls make, with their checks.
    private func runAssistantCommand(_ command: AssistantCommand) {
        // An Ask AI settings patch (WizardAssistant.expressSettings) lands
        // first, so an action sent with it runs on the new settings.
        if let patch = command.settings, settingsProfile == profileName {
            var instructionsText: String?
            let kindBefore = footageKind
            WizardAssistant.applyExpress(patch, settings: &miniSettings, length: &length, instructions: &instructionsText,
                                         footageKind: &footageKind)
            if let instructionsText {
                instructions.wrappedValue = instructionsText
                saveInstructions()
            }
            // The store's footage selection follows the form at once, so an
            // action in the same answer runs on the kind just chosen rather
            // than the batch the store still holds.
            if footageKind != kindBefore { store.selectMiniFootage(flow: flow) }
        }
        if command.isSettingsOnly { return }
        let id = command.actionID
        // The rough cut sheet's Apply (and its Generate): the sheet's framing
        // becomes the page's before anything runs.
        if id == WizardAssistant.applyFramingAction || id == WizardAssistant.generateWithFramingAction {
            guard settingsProfile == profileName else { return }
            if let value = Framing.split(command.text) { miniSettings.framing = value }
            // The sheet's Overlays tab: its choices replace the page's, the
            // rest of the settings stay.
            if let overlays = command.expressOverlays { miniSettings = miniSettings.adoptingOverlays(from: overlays) }
        }
        if id == WizardAssistant.findHighlightsAction {
            // The brief is already in the instructions (from the patch or
            // typed earlier); find the highlights with it.
            runAssistantRequest(instructions.wrappedValue)
            return
        }
        if let toggle = WizardAssistant.expressToggles.first(where: {
            id == WizardAssistant.setActionID($0.field, on: true, express: true)
                || id == WizardAssistant.setActionID($0.field, on: false, express: true)
        }) {
            guard settingsProfile == profileName else { return }
            miniSettings[keyPath: toggle.keyPath] = id.hasSuffix(".on")
            return
        }
        switch id {
        case "express.length.30":
            length = .thirty
        case "wizard.history":
            open(.footage)
        case "wizard.regenerate":
            // The candidate's own Regenerate (MiniHighlightReviewView): the
            // selected one, with the typed note or the note already on it.
            guard !store.isWizardRunning else {
                store.presentNotice("Ask AI", "The Wizard is already working.")
                return
            }
            guard let candidate = selectedCandidate else {
                store.presentNotice("Ask AI", "Select a Highlights candidate in Footage first, then Regenerate.")
                return
            }
            var note = candidate.note
            if let typed = command.text?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
                note = typed
                if let index = store.miniRun?.candidates.firstIndex(where: { $0.id == candidate.id }) {
                    store.miniRun?.candidates[index].note = typed
                }
            }
            store.regenerateMiniCandidate(selectionID: candidate.id, note: note)
        case WizardAssistant.applyFramingAction:
            break
        case "wizard.generate", WizardAssistant.generateWithFramingAction, "wizard.openInEditor", "wizard.roughCut":
            guard canGenerateKept else {
                store.presentNotice("Ask AI", store.isWizardRunning ? "The Wizard is already working."
                                    : "Keep footage in 2 Footage first, then Generate.")
                return
            }
            store.generateMiniReel(settings: miniSettings, flow: flow,
                mode: id == "wizard.openInEditor" ? .openInEditor : id == "wizard.roughCut" ? .roughCut : .render)
        default:
            break
        }
    }

    private func saveInstructions() {
        guard instructionsDirty, store.activeProfile.profileName == profileName else { return }
        store.saveActiveProfile()
        instructionsDirty = false
    }
}
