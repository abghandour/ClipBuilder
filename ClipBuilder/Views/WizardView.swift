import SwiftUI

// MAP: saved form state; source/layout controls; Find the moments card;
// Make the reel card; selections; run summary; handoffs and step options.

/// Footage and idea entry converge on one reviewable run configuration.
struct WizardView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.selectedTab") private var settingsTab = "profile"

    @AppStorage("wizard.entryMode") private var entryMode = "footage"
    @AppStorage("wizard.sourceGridExpanded") private var sourceGridExpanded = true
    @FocusState private var sourcesFocused: Bool
    @State private var enteredWithHandoff = false
    @State private var reviewingIdea = false
    @State private var proposedSceneIDs: Set<Int64>?

    @AppStorage("wizard.aiInstructions") private var aiInstructions = ""
    @AppStorage("wizard.highlightMaxCount") private var highlightMaxCount = 0
    @State private var highlightMaxSeconds = 30.0
    @State private var highlightVideoPath = ""
    @AppStorage("wizard.formatPreset") private var formatPreset = "custom"
    @AppStorage("wizard.lastSceneRecipe") private var lastSceneRecipeID = "custom"
    @AppStorage("wizard.tastePreset") private var tastePreset = ""
    @AppStorage(WizardDefaults.durationModeKey) private var durationModeRaw = WizardDurationMode.automatic.rawValue
    @AppStorage(WizardDefaults.customDurationKey) private var customDuration = 20
    @AppStorage(WizardDefaults.audioModeKey) private var audioModeRaw = WizardAudioMode.mix.rawValue
    @AppStorage(WizardDefaults.textModeKey) private var textModeRaw = WizardTextMode.automatic.rawValue
    @AppStorage("wizard.useFightResearch") private var useFightResearch = true
    @AppStorage("wizard.critiqueLoop") private var critiqueLoop = true
    @AppStorage("wizard.outcome") private var outcomeRaw = "oneReel"
    @AppStorage("wizard.critiqueTargetScore") private var critiqueTargetScore = 85
    @AppStorage("wizard.critiqueMaxVersions") private var critiqueMaxVersions = 3
    @AppStorage("wizard.captionLanguage") private var captionLanguage = ""
    @AppStorage(WizardDefaults.workflowKey) private var reviewWorkflowRaw = WizardWorkflow.automatic.rawValue
    @AppStorage("wizard.musicTrack") private var musicTrackRaw = ""
    @AppStorage("wizard.overlayStyle") private var overlayStyleRaw = ""
    @AppStorage("wizard.pinnedOverlayTemplate") private var overlayTemplateRaw = ""
    @AppStorage("wizard.overlayAnimation") private var overlayAnimationRaw = ""
    @AppStorage("wizard.overlayPlacement") private var overlayPlacementRaw = ""
    @AppStorage("wizard.framingCamera") private var framingCameraRaw = WizardDefaults.fallbackFramingCamera
    @AppStorage(WizardDefaults.limitTransitionsKey) private var limitTransitions = false
    @AppStorage(WizardDefaults.allowedTransitionsKey) private var transitionsRaw = ""
    @State private var lookExpanded = false
    @State private var deletingSelection: WizardSelectionSummary?
    @State private var musicTracks: [String] = []
    @State private var overlayTemplates: [String] = []
    @AppStorage("wizard.highlightFraming") private var highlightFramingRaw = ""
    @AppStorage("wizard.useBRoll") private var useBRoll = true
    @AppStorage("wizard.brollInstructions") private var brollInstructions = ""
    @AppStorage("wizard.podcastFraming") private var podcastFramingRaw = PodcastFramingMode.followSpeaker.rawValue
    @AppStorage(WizardDefaults.layoutModeKey) private var layoutModeRaw = WizardLayoutMode.automatic.rawValue
    @AppStorage(WizardDefaults.selectedLayoutsKey) private var selectedLayoutsRaw = ""
    @AppStorage("wizard.bumperIntro") private var includeIntroBumper = false
    @AppStorage("wizard.bumperOutro") private var includeOutroBumper = false
    @AppStorage("wizard.bumperMiddle") private var includeMiddleBumper = false
    @AppStorage(WizardDefaults.brandingOverrideKey) private var brandingOverrideRaw = WizardBrandingOverride.savedDefault.rawValue
    @AppStorage("wizard.limitToSelection") private var limitToSelection = false
    @AppStorage("wizard.favoritesOnly") private var favoritesOnly = false
    /// Comma-joined Analyze batch IDs — AppStorage cannot persist a Set.
    @AppStorage("wizard.selectedRunIDs") private var selectedRunIDsRaw = ""
    /// Comma-joined person keys (empty means anyone in the selected scenes).
    @AppStorage("wizard.sourcePeople") private var sourcePeopleRaw = ""
    @AppStorage(SceneStacks.levelKey) private var stackLevelRaw = SceneStackLevel.standard.rawValue

    @AppStorage("wizard.modelOverride") private var copiedModelOverride = ""
    @AppStorage(AISettingsPreferences.sourceNameKey) private var pastedSourceName = "another run"
    @AppStorage(AISettingsPreferences.snapshotKey) private var pastedSnapshot = ""
    @AppStorage(WizardDefaults.musicFolderKey) private var musicFolderRaw = ""
    @State private var runPacing: EditPacing?
    @State private var runRenderSettings: RenderSettings?
    @State private var musicCount = 0
    @State private var libraryMusicCount = 0
    @State private var musicFolders: [String] = []
    @State private var showTrainingGuide = false
    @State private var primaryProviderUnavailable = false
    @State private var showSourcePicker = false
    @State private var showManualBuild = false
    @State private var transcriptVideoIDs: Set<Int64> = []
    @State private var pendingDispatch: PendingDispatch?

    private struct SourcePoolKey: Equatable {
        var scenesVersion: Int
        var favoritesOnly: Bool
        var limitToSelection: Bool
        var selectedRunIDsRaw: String
        var personTags: Set<String>
        var recipeID: String
        var stackLevel: String
        var proposedSceneIDs: Set<Int64>?
    }
    @State private var sourcePoolMemo = MemoBox<SourcePoolKey, [SceneRecord]>()

    private var recipe: ReelRecipe { ReelRecipe.recipe(id: formatPreset) ?? .custom }
    private var formPlan: WizardFormPlan { WizardFormPlan(recipe: recipe) }
    private var capabilities: ReelRecipe.Capabilities { formPlan.capabilities }

    private var fromIdea: Bool { entryMode == "idea" && !enteredWithHandoff }
    private var needsFootageProposal: Bool { fromIdea && !reviewingIdea }
    private var isFindingFootage: Bool {
        store.jobs.running.contains { $0.kind == .generateRequest && $0.projectID == store.activeProjectID }
    }
    private var canStart: Bool {
        if needsFootageProposal {
            return !aiInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !store.scenes.isEmpty && !isFindingFootage && !store.isWizardRunning
        }
        return canGenerate && !isFindingFootage
    }

    private var copiedOptions: WizardOptions? {
        AISettingsJSON.decode(WizardOptions.self, pastedSnapshot)
    }

    private var effectivePacing: EditPacing {
        WizardDefaults.resolvedPacing(run: runPacing, copied: copiedOptions, profile: store.activeProfile.defaultPacing)
    }

    private var effectiveRenderSettings: RenderSettings {
        WizardDefaults.resolvedRenderSettings(run: runRenderSettings, copied: copiedOptions,
                                             profile: store.activeProfile.defaultRenderSettings)
    }

    private var pacingBinding: Binding<EditPacing> {
        Binding(get: { effectivePacing }, set: { runPacing = $0 })
    }

    private var renderSettingsBinding: Binding<RenderSettings> {
        Binding(get: { effectiveRenderSettings }, set: { runRenderSettings = $0 })
    }

    private func settingOrigin(edited: Bool, copied: Bool) -> String {
        edited ? "This run" : copied ? "Copied override" : "Profile default"
    }

    private var fightResearchBinding: Binding<Bool> {
        Binding(
            get: {
                AISettingsJSON.decode(WizardOptions.self, pastedSnapshot)?.useFightResearch ?? useFightResearch
            },
            set: {
                useFightResearch = $0
                updateCopiedOption("useFightResearch", .bool($0))
            }
        )
    }

    private var durationMode: WizardDurationMode {
        WizardDurationMode(rawValue: durationModeRaw) ?? .automatic
    }

    private var durationModeBinding: Binding<WizardDurationMode> {
        Binding(
            get: { durationMode },
            set: { durationModeRaw = $0.rawValue }
        )
    }

    private var audioMode: WizardAudioMode {
        WizardAudioMode(rawValue: audioModeRaw) ?? .mix
    }

    private var audioModeBinding: Binding<WizardAudioMode> {
        Binding(
            get: { audioMode },
            set: { audioModeRaw = $0.rawValue }
        )
    }

    private var textMode: WizardTextMode {
        WizardTextMode(rawValue: textModeRaw) ?? .automatic
    }

    private var textModeBinding: Binding<WizardTextMode> {
        Binding(
            get: { textMode },
            set: { textModeRaw = $0.rawValue }
        )
    }

    private var layoutMode: WizardLayoutMode {
        WizardLayoutMode(rawValue: layoutModeRaw) ?? .automatic
    }

    /// Multi-select of Screen Crop layouts for the "Choose layouts…" mode.
    private var selectedLayouts: Set<String> {
        Set(selectedLayoutsRaw.split(separator: ",").map(String.init))
    }

    private var layoutChecklist: some View {
        let layouts = ScreenCropStore.all().filter { !$0.areas.isEmpty }
        return VStack(alignment: .leading, spacing: 4) {
            if layouts.isEmpty {
                Text("No layouts yet — create some under Resources → Screen Crop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(layouts) { layout in
                    Toggle(isOn: Binding(
                        get: { selectedLayouts.contains(layout.name) },
                        set: { on in
                            var chosen = selectedLayouts
                            if on { chosen.insert(layout.name) } else { chosen.remove(layout.name) }
                            selectedLayoutsRaw = chosen.sorted().joined(separator: ",")
                        })) {
                        HStack(spacing: 6) {
                            Text(layout.name)
                            Text(layout.areas.map(\.name).joined(separator: " · "))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.callout)
                    }
                    .toggleStyle(.checkbox)
                }
                if selectedLayouts.isDisjoint(with: layouts.map(\.name)) {
                    Text("Pick at least one layout, or the run stays single scene.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 4)
    }

    private var layoutModeBinding: Binding<WizardLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { layoutModeRaw = $0.rawValue }
        )
    }

    private var brandingOverride: WizardBrandingOverride {
        WizardBrandingOverride(rawValue: brandingOverrideRaw) ?? .savedDefault
    }

    private var brandingOverrideBinding: Binding<WizardBrandingOverride> {
        Binding(
            get: { brandingOverride },
            set: {
                brandingOverrideRaw = $0.rawValue
                let branding = $0.resolved()
                updateCopiedOption("includeWatermark", .bool(branding.includeWatermark))
                updateCopiedOption("includeHeadline", .bool(branding.includeHeadline))
                updateCopiedOption("includeOutro", .bool(branding.includeOutro))
            }
        )
    }

    private var resolvedBranding: WizardBrandingMode {
        brandingOverride.resolved()
    }

    /// The saved batch selection is a global preference; only batches that
    /// belong to the current project count (Home: every batch).
    private var selectedRunIDs: Set<Int64> {
        let saved = Set(selectedRunIDsRaw.split(separator: ",").compactMap { Int64($0) })
        return saved.intersection(Set(store.analysisRuns.map(\.id)))
    }

    private func setSelectedRunIDs(_ ids: Set<Int64>) {
        selectedRunIDsRaw = ids.sorted().map(String.init).joined(separator: ",")
    }

    /// The latest Analyze batch of each handed-off video.
    private func latestRunIDs(forVideoIDs videoIDs: Set<Int64>) -> Set<Int64> {
        var latest: [Int64: AnalysisRun] = [:]
        for run in store.analysisRuns where videoIDs.contains(run.videoID) {
            let current = latest[run.videoID]
            if current == nil || (run.createdAt ?? "") > (current?.createdAt ?? "") {
                latest[run.videoID] = run
            }
        }
        return Set(latest.values.map(\.id))
    }

    private var analyzedSceneCount: Int {
        store.sceneIndex.usableCount
    }

    /// People who appear in this project's scenes. Identities are
    /// profile-wide, but a project can only plan around people it has
    /// footage of.
    private var projectPeople: [PersonRecord] {
        let tags = Set(store.sceneIndex.personTagsByVideo.values.flatMap { $0 })
        return store.people.filter { tags.contains($0.tag) }
    }

    /// The saved people filter is a global preference; names without
    /// footage in this project are ignored rather than filtering to nothing.
    private var selectedSourcePeople: Set<String> {
        let saved = Set(sourcePeopleRaw.split(separator: ",").map(String.init))
        return saved.intersection(Set(projectPeople.map(\.key)))
    }

    private var eligibleSourcePeople: [PersonRecord] {
        guard limitToSelection, !selectedRunIDs.isEmpty else { return projectPeople }
        var tags = Set<String>()
        for runID in selectedRunIDs {
            tags.formUnion(store.sceneIndex.personTagsByRun[runID] ?? [])
        }
        return store.people.filter { tags.contains($0.tag) }
    }

    /// Readiness and caption summaries use the same original transcript rows.
    private var transcriptsAvailable: Bool {
        !Set(sourcePool.map(\.videoID)).isDisjoint(with: transcriptVideoIDs)
    }

    private var manualTargetDuration: Int {
        switch durationMode {
        case .custom:
            min(180, max(3, customDuration))
        default:
            durationMode.duration ?? 20
        }
    }

    private var podcastHighlightVideos: [VideoRecord] {
        WizardFormPlan.podcastHighlightVideos(videos: store.videos, scenes: store.scenes)
    }

    private var readiness: [WizardFormPlan.Readiness] {
        formPlan.readiness(pool: capabilities.sources == .podcastRecording ? store.scenes : sourcePool,
                           videos: store.videos, transcripts: transcriptVideoIDs,
                           selectedVideoPath: highlightVideoPath, limitToSelection: limitToSelection,
                           selectedRunIDs: selectedRunIDs, favoritesOnly: favoritesOnly,
                           providerIssue: capabilities.sources == .scenes && primaryProviderUnavailable
                               ? "No AI provider is available" : nil)
    }

    private var canGenerate: Bool {
        !store.isWizardRunning && !readiness.contains(where: \.isBlocking)
    }

    private var workflow: ReelRecipe.Workflow {
        recipe.workflow == .highlights ? .highlights : (ReelRecipe.Workflow(rawValue: outcomeRaw) == .iterate ? .iterate : .oneReel)
    }

    private var workflowBinding: Binding<ReelRecipe.Workflow> {
        Binding(get: { workflow }, set: { workflow in
            outcomeRaw = workflow.rawValue
            critiqueLoop = workflow == .iterate
            formatPreset = workflow == .highlights ? ReelRecipe.podcastHighlights.id
                : WizardFormPlan.recipeForSceneHandoff(current: recipe, lastSceneRecipeID: lastSceneRecipeID).id
        })
    }

    private var transcriptRefreshKey: String {
        "\(store.profileGeneration):\(store.activeProjectID ?? 0):\(store.scenesVersion):"
            + store.videos.map { "\($0.id):\($0.speechAnalyzedAt ?? "")" }.joined(separator: ",")
    }

    private func refreshTranscriptAvailability() async {
        transcriptVideoIDs = []
        let key = transcriptRefreshKey
        guard let database = store.database else { return }
        let available = (try? await database.videoIDsWithOriginalTranscripts()) ?? []
        guard !Task.isCancelled, key == transcriptRefreshKey else { return }
        transcriptVideoIDs = available.intersection(store.videos.map(\.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.pendingWizardPrompt?.statusMessage != nil || store.pendingWizardPrompt?.parseFailed == true {
                generateRequestBanner
            }
            configurationForm
        }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            enteredWithHandoff = store.pendingWizardPrompt?.proposesFootage == false || store.pendingWizardTemplate != nil
            if store.pendingWizardTemplate != nil {
                formatPreset = WizardFormPlan.recipeForSceneHandoff(current: recipe, lastSceneRecipeID: lastSceneRecipeID).id
            }
            if capabilities.sources == .scenes { lastSceneRecipeID = recipe.id }
            sourcesFocused = !fromIdea
            highlightMaxSeconds = store.settings.podcast.highlightMaxSeconds
            if highlightVideoPath.isEmpty { highlightVideoPath = podcastHighlightVideos.first?.path ?? "" }
        }
        .onChange(of: pastedSnapshot) { oldValue, newValue in
            let old = AISettingsJSON.decode(WizardOptions.self, oldValue)
            let new = AISettingsJSON.decode(WizardOptions.self, newValue)
            if old?.pacing != new?.pacing { runPacing = nil }
            if old?.renderSettings != new?.renderSettings { runRenderSettings = nil }
        }
        .onChange(of: store.activeProfile.id) { _, _ in
            runPacing = nil
            runRenderSettings = nil
            proposedSceneIDs = nil
            reviewingIdea = false
        }
        .onChange(of: store.activeProjectID) { _, _ in
            proposedSceneIDs = nil
            reviewingIdea = false
            enteredWithHandoff = store.pendingWizardPrompt?.proposesFootage == false || store.pendingWizardTemplate != nil
            if let handoff = store.pendingWizardPrompt { applyPromptHandoff(handoff) }
        }
        .onChange(of: store.pendingWizardTemplate) { _, handoff in
            if handoff != nil {
                enteredWithHandoff = true
                formatPreset = WizardFormPlan.recipeForSceneHandoff(current: recipe, lastSceneRecipeID: lastSceneRecipeID).id
                sourcesFocused = true
            }
        }
        .onChange(of: aiInstructions) { _, value in
            if reviewingIdea, value != store.pendingWizardPrompt?.description {
                reviewingIdea = false
            }
        }
        .onChange(of: entryMode) { _, _ in
            reviewingIdea = false
            if store.pendingWizardPrompt?.proposesFootage == true {
                store.cancelGenerateRequest()
                proposedSceneIDs = nil
            }
        }
        .onChange(of: podcastHighlightVideos.map(\.path)) {
            if !podcastHighlightVideos.contains(where: { $0.path == highlightVideoPath }) {
                highlightVideoPath = podcastHighlightVideos.first?.path ?? ""
            }
        }
        .screenTitle("AI Wizard", subtitle: store.videos.isEmpty ? "No sources in this project"
                                                 : capabilities.sources == .podcastRecording
                                                    ? "Choose a recording for highlights" : "\(analyzedSceneCount) scenes available")
        .toolbar {
            ToolbarItem { AIPasteSettingsBar(kind: .wizard) }
            ToolbarItemGroup {
            Button("Training Guide", systemImage: "questionmark.circle") {
                showTrainingGuide = true
            }
            .help("How to teach the Wizard your taste")
            }
        }
        .sheet(isPresented: $showTrainingGuide) {
            HelpSheet()
        }
        .sheet(isPresented: $showSourcePicker) {
            WizardSourcePickerSheet(favoritesOnly: $favoritesOnly,
                                    limitToSelection: $limitToSelection,
                                    selectedRunIDsRaw: $selectedRunIDsRaw,
                                    sourcePeopleRaw: $sourcePeopleRaw)
                .environment(store)
        }
        .sheet(isPresented: $showManualBuild) {
            ManualBuildSheet(
                scenes: manualBuildPool,
                targetDuration: manualTargetDuration,
                includeOutro: resolvedBranding.includeOutro,
                batchNames: Dictionary(uniqueKeysWithValues: store.analysisRuns.map {
                    ($0.id, $0.name.isEmpty ? $0.videoFilename : $0.name)
                }),
                selectedBatchIDs: limitToSelection
                    ? store.analysisRuns.map(\.id).filter(selectedRunIDs.contains)
                    : []
            )
        }
        .sheet(item: $pendingDispatch) { pending in
            DispatchPlanSheet(operation: pending.operation, onStart: pending.run)
        }
        .task(id: WizardFormPlan.ProviderAvailabilityKey(task: formPlan.primaryTask, config: store.settings.ai)) {
            let candidates = await store.ai.dispatchCandidates(task: formPlan.primaryTask)
            guard !Task.isCancelled else { return }
            primaryProviderUnavailable = candidates.isEmpty
        }
        .task(id: transcriptRefreshKey) { await refreshTranscriptAvailability() }
        .task {
            migrateLegacySelections()
            refreshMusicCount()
        }
        .task {
            if let handoff = store.pendingWizardPrompt {
                applyPromptHandoff(handoff)
            }
        }
        .onChange(of: store.pendingWizardPrompt) { _, handoff in
            if let handoff {
                applyPromptHandoff(handoff)
            }
        }
        .onDisappear {
            store.saveActiveProfile()
        }
    }

    private var reviewWorkflow: WizardWorkflow {
        WizardWorkflow(rawValue: reviewWorkflowRaw) ?? .automatic
    }

    private var selectionReview: Bool { reviewWorkflow != .automatic }

    private var lookRecipe: ReelRecipe {
        store.currentWizardSelection.flatMap { ReelRecipe.recipe(id: $0.selection.recipe) } ?? recipe
    }

    private var lookFormPlan: WizardFormPlan { WizardFormPlan(recipe: lookRecipe) }
    private var lookCapabilities: ReelRecipe.Capabilities { lookFormPlan.capabilities }

    private var lookTranscriptsAvailable: Bool {
        guard let take = store.currentWizardSelection?.bestTake else { return transcriptsAvailable }
        let videoIDs = Set((take.plan.footage ?? []).compactMap(\.videoID))
        return !transcriptVideoIDs.isDisjoint(with: videoIDs)
    }

    private func presentationOptions(for selection: WizardSelectionSummary? = nil) -> WizardOptions {
        let selectedRecipe = selection.flatMap { ReelRecipe.recipe(id: $0.selection.recipe) } ?? lookRecipe
        let videoIDs = Set((selection?.bestTake?.plan.footage ?? []).compactMap(\.videoID))
        let available = selection == nil ? lookTranscriptsAvailable : !transcriptVideoIDs.isDisjoint(with: videoIDs)
        var options = formOptions()
        options.formatPreset = selectedRecipe.id
        let text = textMode.output(transcriptsAvailable: available, recipe: selectedRecipe.id)
        options.addCaptions = text.captions
        options.enableTextOverlays = text.headlines
        return options.neutralized(for: selectedRecipe)
    }

    private var step2Collapsed: Bool {
        WizardFormPlan.step2Collapsed(hasSelection: store.currentWizardSelection != nil, workflow: reviewWorkflow)
    }

    private var configurationForm: some View {
        Form {
            if !enteredWithHandoff {
                Picker("Start with", selection: $entryMode) {
                    Text("From footage").tag("footage")
                    Text("From an idea").tag("idea")
                }
                .pickerStyle(.segmented)
            }
            Picker("Workflow", selection: $reviewWorkflowRaw) {
                ForEach(WizardWorkflow.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            if !pastedSnapshot.isEmpty {
                HStack {
                    Label("Pasted from \(pastedSourceName)", systemImage: "doc.on.clipboard")
                    Spacer()
                    Button("Clear") { AISettingsPreferences.clearWizardPaste(defaults: .standard) }
                        .lineLimit(1).fixedSize()
                }
            }
            Section("1 Find the moments") {
                FormGroupHeader("Sources")
                sourceFields
                FormGroupHeader("Outcome")
                outcomeFields
                planningFields
                selectionsRow
                Button(needsFootageProposal ? "Find footage" : "Find the moments", systemImage: "wand.and.stars") {
                    findMoments()
                }
                .lineLimit(1).fixedSize()
                .disabled(!canStart)
            }
            Section("2 Make the reel") {
                if let selection = store.currentWizardSelection, let take = selection.bestTake {
                    Text("From \(selection.selection.name) · \(WizardSelectionRules.takeLabel(take))")
                        .font(.callout.weight(.medium)).lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    if WizardSelectionRules.resolvedPlan(take.plan, scenes: store.scenes) == nil {
                        FormCaption("Footage changed. Open the selection and ask for another take.", tone: .warning)
                    }
                }
                if step2Collapsed {
                    FormCaption(editingSummary)
                } else {
                    DisclosureGroup(isExpanded: $lookExpanded) {
                        lookFields
                    } label: {
                        Text(editingSummary).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let selection = store.currentWizardSelection, let take = selection.bestTake {
                    Button("Render", systemImage: "film") {
                        store.renderWizardSelection(selection.id, takeID: take.id, options: presentationOptions())
                    }
                    .lineLimit(1).fixedSize()
                    .disabled(store.isWizardRunning || WizardSelectionRules.resolvedPlan(take.plan, scenes: store.scenes) == nil)
                } else {
                    FormCaption("Find the moments first")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isFindingFootage)
        .safeAreaInset(edge: .bottom, spacing: 0) { generationBar }
        .task(id: "\(store.profileGeneration):\(store.activeProjectID ?? 0):\(store.isWizardRunning):\(store.scenesVersion)") {
            await store.refreshWizardSelections()
        }
        .onChange(of: store.wizardLookRevision) { _, _ in lookExpanded = true }
        .confirmationDialog("Delete this selection and its takes? Rendered outputs are kept.",
            isPresented: Binding(get: { deletingSelection != nil }, set: { if !$0 { deletingSelection = nil } })) {
            Button("Delete selection", role: .destructive) {
                if let selection = deletingSelection { store.deleteWizardSelection(selection.id) }
                deletingSelection = nil
            }
        }
    }

    @ViewBuilder private var outcomeFields: some View {
        Picker("Outcome", selection: workflowBinding) {
            ForEach(ReelRecipe.Workflow.allCases) { workflow in
                Text(workflow.title).tag(workflow)
            }
        }
        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        .help("Choose one take, or let the content critic compare takes on small previews. Only the best take is rendered.")
        if workflow == .iterate {
            Stepper("Target score: \(critiqueTargetScore)", value: $critiqueTargetScore, in: 60...95, step: 5)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            Stepper("Attempts: \(critiqueMaxVersions)", value: $critiqueMaxVersions, in: 2...5)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            FormCaption("The critic can request a better version until it approves or the attempt limit is reached. Every version is kept in the Library.")
        }
        if WizardFormPlan.showsCriticBriefControls(outcome: workflow) { CriticBriefControls() }
        Picker("Recipe", selection: $formatPreset) {
            ForEach(Array(ReelRecipe.menuSections(workflow: workflow, preferredSources: capabilities.sources).enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                ForEach(section) { recipe in
                    Text(recipe.title).tag(recipe.id)
                }
            }
        }
        .onChange(of: formatPreset) { oldValue, newValue in
            if let previous = ReelRecipe.recipe(id: oldValue), previous.capabilities.sources == .scenes {
                lastSceneRecipeID = previous.id
            }
            if (ReelRecipe.recipe(id: newValue) ?? .custom).capabilities.sources == .podcastRecording {
                outcomeRaw = ReelRecipe.Workflow.highlights.rawValue
                critiqueLoop = false
                highlightMaxSeconds = store.settings.podcast.highlightMaxSeconds
                highlightVideoPath = podcastHighlightVideos.first?.path ?? ""
            } else {
                if outcomeRaw == ReelRecipe.Workflow.highlights.rawValue {
                    outcomeRaw = ReelRecipe.Workflow.oneReel.rawValue
                    critiqueLoop = false
                }
                lastSceneRecipeID = newValue
            }
        }
        .fieldHelp(WizardFieldHelp.recipe)

        if let recipe = ReelRecipe.recipe(id: formatPreset) {
            FormCaption(recipe.summary)
        }

        if capabilities.length == .maxSecondsAndCount {
            Picker("Maximum highlights", selection: $highlightMaxCount) {
                Text("No limit").tag(0)
                Text("Choose a count").tag(max(1, highlightMaxCount))
            }
            if highlightMaxCount > 0 {
                Stepper("Up to \(highlightMaxCount) highlights", value: $highlightMaxCount, in: 1...Int.max)
            }
            Stepper(value: $highlightMaxSeconds, in: 5...120, step: 1) {
                Text("Maximum reel length: \(highlightMaxSeconds, format: .number)s")
            }
            FormCaption("Every candidate is reviewed before rendering. No captions, branding or music.")
        }

        if capabilities.length == .targetDuration {
            Picker("Length", selection: durationModeBinding) {
                ForEach(WizardDurationMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .fieldHelp(WizardFormPlan.lengthHelp(recipe: recipe))
            FieldCaption(WizardFormPlan.lengthHelp(recipe: recipe))

            if durationMode == .custom {
                HStack {
                    Text("Custom length")
                    Spacer()
                    TextField("Seconds", value: $customDuration, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 58)
                        .fieldHelp(WizardFieldHelp.customLength)
                    Stepper("Custom length", value: $customDuration, in: 3...180)
                        .labelsHidden()
                        .fieldHelp(WizardFieldHelp.customLength)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: customDuration) { _, value in
                    let clamped = min(180, max(3, value))
                    if clamped != value { customDuration = clamped }
                }
            }
        }
        FormGroupHeader("Brief")
        briefFields
        if !pastedSnapshot.isEmpty {
            DisclosureGroup("Copied planning details") {
                ForEach(["pinnedOverlayText", "templateLabel"], id: \.self) { key in
                    TextField(key == "pinnedOverlayText" ? "Exact on-screen wording" : "Reference label", text: Binding(get: {
                        AISettingsJSON.decode([String: JSONSetting].self, pastedSnapshot)?[key]?.string ?? ""
                    }, set: { updateCopiedOption(key, $0.isEmpty ? .null : .string($0)) }))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    @ViewBuilder private var planningFields: some View {
        FormGroupHeader("Planning")
        if formPlan.step1Controls.contains(.fightResearch) {
            Toggle("Fight research and learned rules", isOn: fightResearchBinding)
        }
        if capabilities.styleReference {
            Picker("Style reference", selection: $tastePreset) {
                Text("Profile taste").tag("")
                Text("No style reference").tag("none")
                if !store.activeProfile.tasteCategories.isEmpty {
                    Divider()
                    ForEach(store.activeProfile.tasteCategories) { category in
                        Text(category.label).tag("cat:\(category.key)")
                    }
                }
            }
            .fieldHelp(WizardFieldHelp.styleReference)
            FieldCaption(WizardFieldHelp.styleReference)
        }

        if capabilities.layouts {
            Picker("Layouts", selection: layoutModeBinding) {
                ForEach(WizardLayoutMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .fieldHelp(WizardFieldHelp.layouts)
            if layoutMode == .selected {
                layoutChecklist
            } else {
                FormCaption(layoutMode == .singleScene
                     ? "Every clip fills the frame on its own."
                     : "Layouts approved under Resources → Screen Crop may be used.")
            }
        }

        DisclosureGroup("Planning AI settings") {
            TaskModelPickers(tasks: formPlan.step1Models)
            TextField("Model override", text: $copiedModelOverride, prompt: Text("Automatic"))
                .textFieldStyle(.roundedBorder)
                .fieldHelp(WizardFieldHelp.modelOverride)
            FormCaption("Routing rows are shared defaults saved to Settings. Model override applies to planning for this run.")
        }
    }

    @ViewBuilder private var lookFields: some View {
        FormGroupHeader("Output")
        RenderSettingsControls(settings: renderSettingsBinding)
        HStack {
            Text(settingOrigin(edited: runRenderSettings != nil, copied: copiedOptions?.renderSettings != nil))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Save as default") {
                store.activeProfile.defaultRenderSettings = effectiveRenderSettings
                store.saveActiveProfile()
            }
            .controlSize(.small).lineLimit(1).fixedSize()
        }

        if lookCapabilities.audioMusic || lookCapabilities.onScreenText {
            FormGroupHeader("Sound and text")
        }
        if lookCapabilities.audioMusic {
            Picker("Audio", selection: audioModeBinding) {
                ForEach(WizardAudioMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .fieldHelp(WizardFieldHelp.audio)
            FieldCaption(WizardFieldHelp.audio)

            if audioMode.useMusic, !musicFolders.isEmpty {
                Picker("Music from", selection: $musicFolderRaw) {
                    Text("Whole library").tag("")
                    Divider()
                    ForEach(musicFolders, id: \.self) { folder in
                        Text(folder).tag(folder)
                    }
                }
                .fieldHelp(WizardFieldHelp.musicFolder)
                .onChange(of: musicFolderRaw) { refreshMusicCount() }
            }

            if audioMode.useMusic {
                Picker("Track", selection: $musicTrackRaw) {
                    Text("Automatic").tag("")
                    ForEach(musicTracks, id: \.self) { Text($0).tag($0) }
                }
                FormCaption("Automatic picks a track long enough for this take from the chosen folder.")
            }
            if audioMode.useMusic && musicCount == 0 {
                HStack {
                    Label(musicFolderRaw.isEmpty
                          ? "No music has been added yet"
                          : "The “\(musicFolderRaw)” folder has no music — the whole library will be used",
                          systemImage: "music.note.list")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Music") {
                        store.requestedSection = .music
                    }
                    .controlSize(.small)
                }
            }
        }

        if lookCapabilities.onScreenText {
            Picker("On-screen text", selection: textModeBinding) {
                ForEach(WizardTextMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .fieldHelp(WizardFieldHelp.onScreenText)
            FieldCaption(WizardFieldHelp.onScreenText)

            if (textMode == .captions || textMode == .both), !lookTranscriptsAvailable {
                FormCaption("No transcript is available in these sources, so captions will be skipped.", tone: .warning)
            }

            if textMode == .captions || textMode == .both {
                Picker("Caption language", selection: $captionLanguage) {
                    Text("Original audio language").tag("")
                    ForEach(store.activeProfile.captionLanguages, id: \.self) { language in
                        Text(Locale.current.localizedString(forIdentifier: language) ?? language)
                            .tag(language)
                    }
                }
                .fieldHelp(WizardFieldHelp.captionLanguage)
                FieldCaption(WizardFieldHelp.captionLanguage)
            }
        }

        if lookFormPlan.step2Controls.contains(.overlayStyle) { overlayControls }
        FormGroupHeader("Pacing and transitions")
        EditPacingControls(pacing: pacingBinding)
        HStack {
            Text(settingOrigin(edited: runPacing != nil, copied: copiedOptions?.pacing != nil))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Save as default") {
                store.activeProfile.defaultPacing = effectivePacing
                store.saveActiveProfile()
            }
            .controlSize(.small).lineLimit(1).fixedSize()
        }

        transitionControls
        if lookFormPlan.step2Controls.contains(.cameraFocus) {
            FormGroupHeader("Camera focus")
            WizardCameraFocusPicker(selection: cameraFocusBinding, allowsOriginal: lookCapabilities.offersOriginalFraming)
        }
        if lookFormPlan.step2Controls.contains(.framingCamera) {
            Picker("Framing camera", selection: $framingCameraRaw) {
                Text("Smooth").tag("smooth")
                Text("Balanced").tag("balanced")
                Text("Fast").tag("fast")
            }
        }
        if lookFormPlan.step2Controls.contains(.bRoll) {
            FormGroupHeader("B-roll")
            WizardPodcastControls(plan: lookFormPlan, useBRoll: $useBRoll, instructions: $brollInstructions)
        }
        if lookCapabilities.bumpers {
            FormGroupHeader("Bumpers")
            bumperToggle("Include an intro", placement: .intro, value: $includeIntroBumper)
            bumperToggle("Include an outro", placement: .outro, value: $includeOutroBumper)
            bumperToggle("Include one at random in the middle", placement: .anywhere, value: $includeMiddleBumper)
        }

        if lookCapabilities.branding {
            FormGroupHeader("Branding")
            Picker("Brand elements", selection: brandingOverrideBinding) {
                ForEach(WizardBrandingOverride.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .fieldHelp(WizardFieldHelp.branding)
            FieldCaption(WizardFieldHelp.branding)
            if store.activeProfile.logoPath.isEmpty,
               resolvedBranding.includeWatermark || resolvedBranding.includeOutro {
                FormCaption("No brand logo is set. Add one in Settings → Profile to use the watermark or outro.", tone: .warning)
            }
        }

        if !lookFormPlan.step2Models(useBRoll: useBRoll, instructions: brollInstructions).isEmpty {
            DisclosureGroup("Caption and B-roll AI settings") {
                TaskModelPickers(tasks: lookFormPlan.step2Models(useBRoll: useBRoll, instructions: brollInstructions))
            }
        }
    }

    private var overlayControls: some View {
        Group {
            Picker("Overlay template", selection: $overlayTemplateRaw) {
                Text("Preset style").tag("")
                ForEach(overlayTemplates, id: \.self) { Text($0).tag($0) }
            }
            if overlayTemplateRaw.isEmpty {
                Picker("Overlay style", selection: $overlayStyleRaw) {
                    Text("Automatic").tag("")
                    ForEach(WizardTextStyle.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
            }
            Picker("Animation", selection: $overlayAnimationRaw) {
                Text("Automatic").tag("")
                ForEach(WizardTextStyle.animations, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
            }
            Picker("Placement", selection: $overlayPlacementRaw) {
                Text("Automatic").tag("")
                ForEach(WizardTextStyle.placements, id: \.self) { Text($0.capitalized).tag($0) }
            }
        }
    }

    private var transitionControls: some View {
        DisclosureGroup("Allowed transitions") {
            Toggle("Use all approved transitions", isOn: Binding(get: { !limitTransitions }, set: { limitTransitions = !$0 }))
            if limitTransitions {
                ForEach(RenderEngine.allTransitions.filter { $0 != "cut" }, id: \.self) { name in
                    Toggle(name.replacingOccurrences(of: "_", with: " ").capitalized, isOn: Binding(get: {
                        transitionsRaw.split(separator: ",").map(String.init).contains(name)
                    }, set: { enabled in
                        var names = Set(transitionsRaw.split(separator: ",").map(String.init))
                        if enabled { names.insert(name) } else { names.remove(name) }
                        transitionsRaw = names.sorted().joined(separator: ",")
                        updateCopiedOption("allowedTransitions", .array(names.sorted().map(JSONSetting.string)))
                    }))
                }
            }
            FormCaption("Hard cuts form the backbone. Allowed effects add an accent every third boundary; no effects means cuts only.")
        }
        .onChange(of: limitTransitions) { _, limited in
            updateCopiedOption("allowedTransitions", limited
                ? .array(transitionsRaw.split(separator: ",").map { .string(String($0)) }) : .null)
        }
    }

    private var projectSelections: [WizardSelectionSummary] {
        store.wizardSelections.filter { $0.selection.projectID == store.activeProjectID }
    }

    private var selectionsRow: some View {
        Group {
            FormGroupHeader("Selections")
            if projectSelections.isEmpty {
                FormCaption("Find the moments to save a selection you can return to and render in different styles.")
            } else {
                ForEach(projectSelections) { summary in
                    HStack(spacing: Theme.spaceS) {
                        Button(summary.selection.name) {
                            store.openWizardSelection(summary.id, options: presentationOptions(for: summary))
                        }
                        .buttonStyle(.link)
                        .lineLimit(1).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(summary.takes.count) \(summary.takes.count == 1 ? "take" : "takes")")
                            Text(summary.selection.editedAt ?? "")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                        Button("Render") {
                            store.activeWizardSelectionID = summary.id
                            lookExpanded = true
                        }
                        .lineLimit(1).fixedSize()
                        .help("Use this selection's best take in Make the reel")
                        Button("Delete selection", systemImage: "trash") { deletingSelection = summary }
                            .labelStyle(.iconOnly).help("Delete selection")
                    }
                    .disabled(store.isWizardRunning)
                }
            }
        }
    }

    private var editingSummary: String {
        let text = textMode.output(transcriptsAvailable: lookTranscriptsAvailable, recipe: lookRecipe.id)
        let effectiveAudio = libraryMusicCount == 0 && audioMode.useMusic ? WizardAudioMode.original : audioMode
        return lookFormPlan.editingSummary(audio: effectiveAudio, captions: text.captions, headlines: text.headlines,
            critique: critiqueLoop, branding: brandingOverride == .savedDefault ? "Brand default" : brandingOverride.title,
            useBRoll: useBRoll)
    }

    private var sourceFields: some View {
        Group {
            if reviewingIdea {
                Text("Review the matched footage, then confirm below to continue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let proposedSceneIDs, capabilities.sources == .scenes {
                restrictionChip("Idea match: \(proposedSceneIDs.count) scenes") { self.proposedSceneIDs = nil }
            }
            if capabilities.sources == .podcastRecording {
                // One recording at a time: clicking another swaps, clicking
                // the selected one clears.
                WizardSourceGrid(videos: podcastHighlightVideos,
                                 selectedPaths: highlightVideoPath.isEmpty ? [] : [highlightVideoPath],
                                 isExpanded: $sourceGridExpanded,
                                 subtitle: { recordingSubtitle($0) }) { video in
                    highlightVideoPath = highlightVideoPath == video.path ? "" : video.path
                }
            } else {
                HStack {
                    Text("\(sourcePool.count) usable scenes · \(Set(sourcePool.map(\.videoID)).count) videos")
                    Spacer()
                    Button("Edit") { showSourcePicker = true }
                        .lineLimit(1).fixedSize()
                        .focused($sourcesFocused)
                }
                // Every analyzed video contributes until one is clicked off;
                // the grid then narrows the run to the videos still selected.
                WizardSourceGrid(videos: analyzedVideos,
                                 selectedPaths: Set(analyzedVideos.filter(videoContributes).map(\.path)),
                                 isExpanded: $sourceGridExpanded,
                                 subtitle: { analyzedSubtitle($0) }) { video in
                    toggleVideo(video)
                }
                Text(sourceSummary).font(.caption).foregroundStyle(.secondary)
                if favoritesOnly {
                    restrictionChip("Favorites only") { favoritesOnly = false }
                }
                if limitToSelection {
                    restrictionChip("Selected Analyze batches: \(selectedRunIDs.count)") { limitToSelection = false }
                }
                WizardSourceEvidence(scenes: Array(sourcePool.prefix(6)),
                    people: projectPeople.filter { selectedSourcePeople.contains($0.key) })
                copiedSourceRestrictions
                Text(framingStatus).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(readiness.enumerated()), id: \.offset) { _, item in
                if case let .warning(message, action) = item {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button(action.rawValue) { recover(action) }
                            .controlSize(.small).lineLimit(1).fixedSize()
                    }
                }
            }
        }
    }

    /// Videos with at least one Analyze batch, in library order.
    private var analyzedVideos: [VideoRecord] {
        let ids = Set(store.analysisRuns.map(\.videoID))
        return store.videos.filter { ids.contains($0.id) }
    }

    private func runs(of video: VideoRecord) -> [AnalysisRun] {
        store.analysisRuns.filter { $0.videoID == video.id }
    }

    /// Whether this video's scenes are in the pool: everything contributes
    /// until the run is limited to chosen batches.
    private func videoContributes(_ video: VideoRecord) -> Bool {
        WizardFormPlan.videoContributes(runIDs: runs(of: video).map(\.id),
                                        limitToSelection: limitToSelection, selectedRunIDs: selectedRunIDs)
    }

    private func toggleVideo(_ video: VideoRecord) {
        let change = WizardFormPlan.togglingVideo(
            runIDs: runs(of: video).map(\.id),
            newestRunID: runs(of: video).max { ($0.createdAt ?? "") < ($1.createdAt ?? "") }?.id,
            allRunsByVideo: Dictionary(grouping: store.analysisRuns, by: \.videoID).mapValues { runs in
                runs.max { ($0.createdAt ?? "") < ($1.createdAt ?? "") }.map { [$0.id] } ?? []
            },
            limitToSelection: limitToSelection, selectedRunIDs: selectedRunIDs)
        limitToSelection = change.limitToSelection
        setSelectedRunIDs(change.selectedRunIDs)
    }

    private func recordingSubtitle(_ video: VideoRecord) -> String {
        let exchanges = store.scenes.count {
            $0.videoID == video.id && !$0.excluded && !$0.ignored && $0.tags.contains("podcast-exchange")
        }
        return "\(video.duration.timecode) · \(transcriptVideoIDs.contains(video.id) ? "transcript" : "no transcript") · \(exchanges) exchange\(exchanges == 1 ? "" : "s")"
    }

    private func analyzedSubtitle(_ video: VideoRecord) -> String {
        let scenes = sourcePool.count { $0.videoID == video.id }
        let batches = runs(of: video).count
        return "\(video.duration.timecode) · \(scenes) scene\(scenes == 1 ? "" : "s") · \(batches) batch\(batches == 1 ? "" : "es")"
    }

    private func recover(_ action: WizardFormPlan.RecoveryAction) {
        switch action {
        case .sources:
            sourceGridExpanded = true
            if store.videos.isEmpty { store.requestedSection = .sources }
            else if capabilities.sources == .scenes { showSourcePicker = true }
            else { sourcesFocused = true }
        case .analyze: store.requestedSection = .analyze
        case .aiSettings:
            settingsTab = "ai"
            openSettings()
        }
    }

    @ViewBuilder private var briefFields: some View {
        TextField(recipe.briefPrompt, text: $aiInstructions, axis: .vertical)
            .lineLimit(3...6)
            .textFieldStyle(.roundedBorder)
            .fieldHelp(WizardFieldHelp.instructions(for: recipe))
        if capabilities.referenceTemplate, let handoff = store.pendingWizardTemplate {
            referenceTemplateChip(handoff)
        }
    }

    private var cameraFocusBinding: Binding<String> {
        Binding(get: {
            lookCapabilities.offersOriginalFraming && podcastFramingRaw == PodcastFramingMode.original.rawValue
                ? WizardCameraFocus.original : highlightFramingRaw
        }, set: { value in
            podcastFramingRaw = value == WizardCameraFocus.original
                ? PodcastFramingMode.original.rawValue : PodcastFramingMode.followSpeaker.rawValue
            if value != WizardCameraFocus.original { highlightFramingRaw = value }
        })
    }

    private var runSummary: String {
        let names = projectPeople.filter { selectedSourcePeople.contains($0.key) }.map(\.displayName)
        let source = capabilities.sources == .podcastRecording
            ? store.videos.first(where: { $0.path == highlightVideoPath })?.filename ?? "the selected recording"
            : names.isEmpty ? "in this project" : "of " + names.joined(separator: ", ")
        return formPlan.runSummary(sceneCount: sourcePool.count, source: source,
            targetSeconds: durationMode.duration ?? (durationMode == .custom ? customDuration : nil),
            highlightCount: highlightMaxCount, highlightSeconds: highlightMaxSeconds,
            captions: textMode.output(transcriptsAvailable: transcriptsAvailable, recipe: formatPreset).captions,
            critique: workflow == .iterate, selectionReview: selectionReview,
            critiqueTargetScore: critiqueTargetScore, critiqueMaxVersions: critiqueMaxVersions)
            + (capabilities.offersCameraFocus ? " · " + WizardCameraFocus.name(cameraFocusBinding.wrappedValue) : "")
    }

    private func bumperToggle(_ title: String, placement: BumperPlacement, value: Binding<Bool>) -> some View {
        let count = store.bumpers.count { $0.placements.contains(placement) }
        let optionKey: String = switch placement {
        case .intro: "includeIntroBumper"
        case .outro: "includeOutroBumper"
        case .anywhere: "includeMiddleBumper"
        }
        let help: FieldHelp = switch placement {
        case .intro: WizardFieldHelp.bumperIntro
        case .outro: WizardFieldHelp.bumperOutro
        case .anywhere: WizardFieldHelp.bumperMiddle
        }
        return Group {
            Toggle(title, isOn: value).disabled(count == 0)
                .onChange(of: value.wrappedValue) { _, enabled in
                    updateCopiedOption(optionKey, .bool(enabled))
                }
                .fieldHelp(help)
            FormCaption(count == 0 ? "No bumpers allow this placement. Add one in Resources → Bumpers."
                        : "\(count) bumper\(count == 1 ? "" : "s") allow\(count == 1 ? "s" : "") this placement.")
        }
    }

    private func referenceTemplateChip(_ handoff: WizardTemplateHandoff) -> some View {
        HStack(spacing: 10) {
            if let url = handoff.thumbnailURL {
                CachedImage(url: url, maxPixel: 160)
                    .frame(width: 34, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
                    .frame(width: 34, height: 56)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.secondary)
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(handoff.label)
                Text("Hook, pacing, and text style will guide this reel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove Template", systemImage: "xmark.circle.fill") {
                store.pendingWizardTemplate = nil
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help("Remove this reference template")
        }
    }

    private var generationBar: some View {
        VStack(spacing: 8) {
            Text(needsFootageProposal ? "Find matching footage in this project, then review the selection before generating." : runSummary)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                if isFindingFootage {
                    Button("Stop finding footage", role: .destructive) { store.cancelGenerateRequest() }
                        .lineLimit(1).fixedSize()
                } else if store.isWizardRunning {
                    Button(role: .destructive) {
                        store.cancelWizard()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                } else if reviewWorkflow == .automatic || needsFootageProposal || capabilities.sources == .podcastRecording {
                    Button {
                        startGeneration()
                    } label: {
                        Label(needsFootageProposal ? "Find footage" : (capabilities.sources == .podcastRecording ? "Find highlights" : "Generate reel"), systemImage: "wand.and.stars")
                    }
                    .controlSize(.large)
                    .lineLimit(1).fixedSize()
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canStart)
                }

                Spacer()

                if capabilities.sources == .scenes {
                    Button("Build manually…") {
                        showManualBuild = true
                    }
                    .lineLimit(1).fixedSize()
                    .disabled(!canGenerate || isFindingFootage || store.isManualBuildRendering)
                    .help("Build this reel yourself from the same source selection, scene by scene")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var copiedSourceRestrictions: some View {
        if let copied = copiedOptions, copied.sourcesRestricted {
            VStack(alignment: .leading, spacing: 6) {
                if copied.sourceSceneSelection {
                    restrictionChip("Copied scenes: \(copied.sourceSceneIDs.count)") {
                        updateCopiedOption("sourceSceneSelection", .bool(false))
                        updateCopiedOption("sourceSceneIDs", .array([]))
                        updateCopiedOption("sourcesRestricted", .bool(false))
                    }
                } else if !copied.sourceVideoPaths.isEmpty {
                    ForEach(copied.sourceVideoPaths.sorted(), id: \.self) { path in
                        restrictionChip("Copied video: " + URL(fileURLWithPath: path).lastPathComponent) {
                            let remaining = copied.sourceVideoPaths.subtracting([path])
                            updateCopiedOption("sourceVideoPaths", .array(remaining.sorted().map { .string($0) }))
                            if remaining.isEmpty { updateCopiedOption("sourcesRestricted", .bool(false)) }
                        }
                    }
                } else {
                    restrictionChip("Copied Analyze batches: \(copied.selectedRunIDs.count)") {
                        updateCopiedOption("sourcesRestricted", .bool(false))
                    }
                }
            }
        }
    }

    private func restrictionChip(_ title: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption).lineLimit(1)
            Button("Remove restriction", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
    }

    private var sourceSummary: String {
        var summary: String
        if limitToSelection {
            summary = selectedRunIDs.isEmpty
                ? "Choose Analyze batches"
                : "\(selectedRunIDs.count) Analyze batch\(selectedRunIDs.count == 1 ? "" : "es")"
        } else if favoritesOnly {
            summary = "Favorite scenes"
        } else {
            summary = proposedSceneIDs != nil ? "Footage matched to your idea"
                : copiedOptions?.sourcesRestricted == true ? "Copied source selection" : "All analyzed scenes"
        }

        let names = projectPeople
            .filter { selectedSourcePeople.contains($0.key) }
            .map(\.displayName)
        if !names.isEmpty {
            summary += " · " + names.prefix(2).joined(separator: ", ")
            if names.count > 2 { summary += " +\(names.count - 2)" }
        }
        return summary
    }

    private var framingStatus: String {
        let wideScenes = sourcePool.filter(\.wide)
        guard !wideScenes.isEmpty else {
            return "No wide scenes in this source selection."
        }
        let saved = wideScenes.filter { $0.centerStagePath != nil }.count
        if saved == wideScenes.count {
            return "Framing: all \(saved) wide scenes use their saved 9:16 framing."
        }
        return "Framing: \(saved) of \(wideScenes.count) wide scenes use saved 9:16 framing; the rest use an automatic crop."
    }

    /// Shared source policy for both AI planning and the manual alternative.
    /// Memoized because the form reads the eligible selection in several rows.
    private var sourcePool: [SceneRecord] {
        let personTags = Set(store.people
            .filter { selectedSourcePeople.contains($0.key) }
            .map(\.tag))
        let key = SourcePoolKey(scenesVersion: store.scenesVersion,
                                favoritesOnly: favoritesOnly,
                                limitToSelection: limitToSelection,
                                selectedRunIDsRaw: selectedRunIDsRaw,
                                personTags: personTags, recipeID: recipe.id, stackLevel: stackLevelRaw, proposedSceneIDs: proposedSceneIDs)
        if !pastedSnapshot.isEmpty { return computeSourcePool(personTags: personTags) }
        return sourcePoolMemo(key) { computeSourcePool(personTags: personTags) }
    }

    private func computeSourcePool(personTags: Set<String>) -> [SceneRecord] {
        var pool = store.scenes.filter { !$0.excluded && !$0.ignored }
        if let copied = AISettingsJSON.decode(WizardOptions.self, pastedSnapshot), copied.sourcesRestricted {
            pool = pool.filter { copied.includesCopiedSource($0) }
        }
        if let proposedSceneIDs { pool = pool.filter { proposedSceneIDs.contains($0.id) } }
        pool = SceneStacks.tops(pool, level: .from(stackLevelRaw))
        if favoritesOnly {
            pool = pool.filter(\.favorite)
        }
        if limitToSelection {
            let runIDs = selectedRunIDs
            pool = pool.filter { $0.runID.map(runIDs.contains) ?? false }
        }

        if !personTags.isEmpty {
            pool = pool.filter { !personTags.isDisjoint(with: $0.tags) }
        }
        if recipe.id == ReelRecipe.podcast.id {
            pool = WizardEngine.podcastScenes(pool, log: { _ in })
        }
        let positivelyRated = pool.filter { !($0.gradeCount > 0 && ($0.gradeAverage ?? 5) <= 2) }
        return positivelyRated.isEmpty ? pool : positivelyRated
    }

    /// The manual wizard proposes focused beats from the same source pool.
    private var manualBuildPool: [SceneRecord] {
        var pool = sourcePool
        let byVideo = Dictionary(grouping: pool, by: \.videoID)
        pool = pool.filter { scene in
            guard let group = byVideo[scene.videoID] else { return true }
            return !group.contains {
                $0.id != scene.id
                    && $0.startTime >= scene.startTime - 0.25
                    && $0.endTime <= scene.endTime + 0.25
                    && $0.duration <= scene.duration - 1.0
            }
        }
        pool = SceneStacks.tops(pool, level: .from(stackLevelRaw))

        func rank(_ scene: SceneRecord) -> Double {
            var value = scene.score ?? scene.excitement.map { $0 * 10 } ?? -1
            if scene.tags.contains(where: { $0.hasPrefix("highlight") }) { value += 5 }
            return value
        }

        if pool.contains(where: { rank($0) >= 0 }) {
            let groups = Dictionary(grouping: pool) { $0.runID ?? -1 }
            let batchCount = max(1, groups.count)
            let totalBudget = max(Double(manualTargetDuration) * 4, 60)
            let perBatchBudget = max(totalBudget / Double(batchCount), 30)
            let perBatchMinimum = max(12 / batchCount, 6)
            var shortlist: [SceneRecord] = []
            for scenes in groups.values {
                var total = 0.0
                var kept = 0
                for scene in scenes.sorted(by: { rank($0) > rank($1) }) {
                    if total >= perBatchBudget, kept >= perBatchMinimum { break }
                    shortlist.append(scene)
                    total += scene.duration
                    kept += 1
                }
            }
            pool = shortlist
        }

        return pool.sorted {
            if $0.videoID != $1.videoID { return $0.videoID < $1.videoID }
            return $0.startTime < $1.startTime
        }
    }

    private func refreshMusicCount() {
        musicFolders = WizardEngine.musicFolders()
        libraryMusicCount = WizardEngine.availableMusic().count
        // A folder that was renamed or emptied falls back to the library.
        if !musicFolderRaw.isEmpty,
           let resolved = AssetStore.resolveFolderName(musicFolderRaw, of: .music),
           resolved != musicFolderRaw {
            musicFolderRaw = resolved
        }
        musicTracks = WizardEngine.availableMusic(inFolder: musicFolderRaw).map(\.name)
        musicCount = musicTracks.count
        if !musicTrackRaw.isEmpty && !musicTracks.contains(musicTrackRaw) { musicTrackRaw = "" }
        overlayTemplates = OverlayTemplateStore.list().map(\.name)
    }

    private func migrateLegacySelections() {
        let defaults = UserDefaults.standard
        WizardDefaults.migrateLegacy(defaults: defaults)
        if defaults.string(forKey: "wizard.outcome") == nil {
            outcomeRaw = WizardFormPlan.outcome(recipe: recipe, critiqueLoop: critiqueLoop).rawValue
        }
        critiqueLoop = workflow == .iterate
        critiqueTargetScore = min(95, max(60, critiqueTargetScore))
        critiqueMaxVersions = min(5, max(2, critiqueMaxVersions))
        audioModeRaw = WizardDefaults.audioMode(defaults: defaults).rawValue
        textModeRaw = WizardDefaults.textMode(defaults: defaults).rawValue
        durationModeRaw = WizardDefaults.durationMode(defaults: defaults).rawValue
        layoutModeRaw = WizardLayoutMode(rawValue: defaults.string(forKey: WizardDefaults.layoutModeKey) ?? "")?.rawValue
            ?? WizardLayoutMode.automatic.rawValue
        brandingOverrideRaw = WizardDefaults.brandingOverride(defaults: defaults).rawValue

        // Learned categories used to appear as recipes. Keep the person's
        // intent, but put it in the optional style reference where it belongs.
        if formatPreset.hasPrefix("cat:") {
            if tastePreset.isEmpty { tastePreset = formatPreset }
            formatPreset = "custom"
        }
    }

    private func startGeneration() {
        if needsFootageProposal {
            guard canStart else { return }
            store.proposeFootage(for: aiInstructions)
            return
        }
        if capabilities.sources == .podcastRecording {
            runWizard()
            return
        }
        if store.settings.ai.mutedDispatchPlans.contains(DispatchOperation.generate.rawValue) {
            runWizard()
            store.appendLog(\.wizardLog, ["Model-plan prompt is muted — reset Smart Dispatcher in Settings → AI to show it again."])
        } else {
            pendingDispatch = PendingDispatch(operation: .generate) {
                runWizard()
            }
        }
    }

    private var generateRequestBanner: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Generate Video Request", systemImage: "wand.and.stars")
                .font(.headline)
            Text("“\(store.pendingWizardPrompt?.description ?? "")”")
            if let pendingStatus = store.pendingWizardPrompt?.statusMessage {
                let line = store.jobs.running.last(where: {
                    $0.kind == .generateRequest && $0.projectID == store.activeProjectID
                })?.statusLine ?? ""
                let status = line.isEmpty ? pendingStatus : line
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            } else if store.pendingWizardPrompt?.parseFailed == true {
                Label(store.pendingWizardPrompt?.proposesFootage == true
                      ? "Couldn't finish interpreting the idea. Review Sources and the original brief before continuing."
                      : "Couldn't interpret the request with AI — it was added to the brief as written.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(store.pendingWizardPrompt?.statusMessage != nil ? "Stop" : "Close") {
                    store.cancelGenerateRequest()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary)
    }

    private func applyPromptHandoff(_ handoff: WizardPromptHandoff) {
        if handoff.proposesFootage {
            guard handoff.statusMessage == nil else { return }
            reviewingIdea = true
            sourcesFocused = true
            proposedSceneIDs = handoff.proposedSceneIDs ?? []
            limitToSelection = false
            favoritesOnly = false
            sourcePeopleRaw = ""
            updateCopiedOption("sourcesRestricted", .bool(false))
            aiInstructions = handoff.description
            if capabilities.sources == .podcastRecording {
                highlightVideoPath = store.videos.first { handoff.videoIDs.contains($0.id) }?.path ?? ""
            }
            return
        }
        enteredWithHandoff = true
        proposedSceneIDs = nil
        if !handoff.runIDs.isEmpty || !handoff.videoIDs.isEmpty {
            formatPreset = WizardFormPlan.recipeForSceneHandoff(
                current: recipe, lastSceneRecipeID: lastSceneRecipeID).id
        }
        if !handoff.runIDs.isEmpty {
            setSelectedRunIDs(handoff.runIDs)
            limitToSelection = true
            favoritesOnly = false
        } else if !handoff.videoIDs.isEmpty {
            setSelectedRunIDs(latestRunIDs(forVideoIDs: handoff.videoIDs))
            limitToSelection = true
            favoritesOnly = false
        }
        if !handoff.personKeys.isEmpty {
            sourcePeopleRaw = handoff.personKeys.sorted().joined(separator: ",")
        }

        guard let parsed = handoff.parsed else {
            aiInstructions = ([tagFilterLine(handoff.tags), handoff.description]
                .compactMap { $0 }).joined(separator: "\n")
            return
        }

        if let duration = parsed.targetDurationSeconds {
            customDuration = min(180, max(3, duration))
            durationModeRaw = WizardDurationMode.custom.rawValue
        }
        if capabilities.offersCameraFocus, let framing = parsed.highlightFraming {
            podcastFramingRaw = PodcastFramingMode.followSpeaker.rawValue
            highlightFramingRaw = framing.rawValue
        }
        if capabilities.bRoll, let enabled = parsed.useBRoll { useBRoll = enabled }
        if let useMusic = parsed.useMusic {
            if useMusic, audioMode == .original {
                audioModeRaw = WizardAudioMode.mix.rawValue
            } else if !useMusic {
                audioModeRaw = WizardAudioMode.original.rawValue
            }
        }
        if let folder = parsed.musicFolder {
            musicFolderRaw = folder
            refreshMusicCount()
        }
        applyParsedTextOptions(captions: parsed.addCaptions,
                               headlines: parsed.enableTextOverlays)
        if let template = parsed.overlayTemplate { overlayTemplateRaw = template }

        var lines: [String] = []
        let contentTags = handoff.tags + parsed.contentTags.filter { !handoff.tags.contains($0) }
        if let tagLine = tagFilterLine(contentTags) {
            lines.append(tagLine)
        }
        if !parsed.residualInstructions.isEmpty {
            lines.append(parsed.residualInstructions)
        }
        aiInstructions = lines.joined(separator: "\n")
    }

    private func applyParsedTextOptions(captions: Bool?, headlines: Bool?) {
        switch (captions, headlines) {
        case let (.some(captions), .some(headlines)):
            switch (captions, headlines) {
            case (true, true): textModeRaw = WizardTextMode.both.rawValue
            case (true, false): textModeRaw = WizardTextMode.captions.rawValue
            case (false, true): textModeRaw = WizardTextMode.headlines.rawValue
            case (false, false): textModeRaw = WizardTextMode.none.rawValue
            }
        case (.some(true), nil):
            textModeRaw = WizardTextMode.captions.rawValue
        case (nil, .some(true)):
            textModeRaw = WizardTextMode.headlines.rawValue
        case (.some(false), nil), (nil, .some(false)), (nil, nil):
            break
        }
    }

    private func tagFilterLine(_ tags: [String]) -> String? {
        tags.isEmpty ? nil
            : "Only use footage tagged: \(tags.joined(separator: ", ")). Skip everything else."
    }

    private func updateCopiedOption(_ key: String, _ value: JSONSetting) {
        guard var settings = AISettingsJSON.decode([String: JSONSetting].self, pastedSnapshot) else { return }
        settings[key] = value
        pastedSnapshot = AISettingsJSON.encode(settings) ?? ""
    }

    private func findMoments() {
        if needsFootageProposal { startGeneration(); return }
        guard canGenerate, !isFindingFootage else { return }
        let options = formOptions()
        if capabilities.sources == .podcastRecording { store.runWizard(options: options) }
        else { store.findWizardMoments(options: options) }
    }

    private func runWizard() {
        guard canGenerate, !isFindingFootage else { return }
        var options = formOptions()
        options.workflow = .automatic
        store.runWizard(options: options)
    }

    private func formOptions() -> WizardOptions {

        let musicAvailable = !WizardEngine.availableMusic().isEmpty
        let audio = audioMode
        let text = textMode.output(transcriptsAvailable: transcriptsAvailable, recipe: formatPreset)
        let branding = resolvedBranding
        let pasted = AISettingsJSON.decode(WizardOptions.self, UserDefaults.standard.string(forKey: AISettingsPreferences.snapshotKey))
        var options = pasted ?? WizardOptions()
        options.stackLevel = stackLevelRaw
        options.modelOverride = copiedModelOverride.isEmpty ? nil : copiedModelOverride
        options.useMusic = audio.useMusic && musicAvailable
        options.musicFolder = options.useMusic && !musicFolderRaw.isEmpty ? musicFolderRaw : nil
        options.renderSettings = effectiveRenderSettings
        options.pacing = effectivePacing
        options.captionLanguage = captionLanguage.isEmpty ? nil : captionLanguage
        options.workflow = reviewWorkflow
        options.projectID = store.activeProjectID
        options.musicTrack = musicTrackRaw.isEmpty ? nil : musicTrackRaw
        options.overlayStyle = overlayStyleRaw.isEmpty ? nil : overlayStyleRaw
        options.pinnedOverlayTemplate = overlayTemplateRaw.isEmpty ? nil : overlayTemplateRaw
        options.overlayAnimation = overlayAnimationRaw.isEmpty ? nil : overlayAnimationRaw
        options.overlayPlacement = overlayPlacementRaw.isEmpty ? nil : overlayPlacementRaw
        options.muteSource = audio.muteSource && options.useMusic
        options.addCaptions = text.captions
        options.enableTextOverlays = text.headlines
        options.framingCamera = framingCameraRaw
        options.screenCropLayouts = WizardDefaults.screenCropLayouts(for: layoutMode)
        options.allowedTransitions = pasted?.allowedTransitions ?? WizardOptions.allowedTransitionsFromDefaults()
        options.useFightResearch = pasted?.useFightResearch ?? useFightResearch
        options.aiInstructions = aiInstructions
        options.targetDurationSeconds = durationMode.duration
            ?? (durationMode == .custom ? min(180, max(3, customDuration)) : nil)
        options.formatPreset = formatPreset
        options.highlightFraming = CropRecipe.Kind(rawValue: highlightFramingRaw)
        options.useBRoll = useBRoll
        options.brollInstructions = brollInstructions
        options.podcastFraming = PodcastFramingMode(rawValue: podcastFramingRaw) ?? .followSpeaker
        options = WizardFormPlan.applyingOutcome(workflow, to: options)
        options.critiqueTargetScore = critiqueTargetScore
        options.critiqueMaxVersions = critiqueMaxVersions
        options.tastePreset = tastePreset.isEmpty ? nil : tastePreset
        options.includeWatermark = pasted?.includeWatermark ?? branding.includeWatermark
        options.includeHeadline = pasted?.includeHeadline ?? branding.includeHeadline
        options.includeOutro = pasted?.includeOutro ?? branding.includeOutro
        options.includeIntroBumper = pasted?.includeIntroBumper ?? includeIntroBumper
        options.includeOutroBumper = pasted?.includeOutroBumper ?? includeOutroBumper
        options.includeMiddleBumper = pasted?.includeMiddleBumper ?? includeMiddleBumper
        options.selectedRunIDs = limitToSelection ? selectedRunIDs : []
        options.favoritesOnly = favoritesOnly

        let eligibleKeys = Set(eligibleSourcePeople.map(\.key))
        options.sourcePeople = Array(selectedSourcePeople).sorted()
            .filter(eligibleKeys.contains)

        if let handoff = store.pendingWizardTemplate {
            options.templateJSON = handoff.templateJSON
            options.templateLabel = handoff.label
        }
        if store.pendingWizardPrompt?.proposesFootage != true, let parsed = store.pendingWizardPrompt?.parsed {
            options.pinnedOverlayText = parsed.overlayText
        }
        options = formPlan.applyingIdeaSources(to: options, proposedSceneIDs: proposedSceneIDs)
        if capabilities.sources == .podcastRecording {
            options.highlightMaxSeconds = highlightMaxSeconds
            options.highlightMaxCount = highlightMaxCount
            options.sourcesRestricted = true
            options.sourceSceneSelection = false
            options.sourceSceneIDs = []
            options.sourceVideoPaths = [highlightVideoPath]
            options.selectedRunIDs = []
            options.sourcePeople = []
        }
        return WizardOptions.merge(step1: options.step1, step2: options.step2, base: options)
    }
}
