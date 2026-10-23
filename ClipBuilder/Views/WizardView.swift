import Combine
import SwiftUI

// MAP: persisted answers, lifecycle, source policy, handoffs and submission.
// WizardView+Steps: four cards (Source, Plan, Footage, Settings) and navigation;
// WizardView+Fields: source/outcome/planning rows; WizardView+Look: presentation
// controls. WizardCardFlow owns the pure navigation and summary rules.

/// Footage and idea entry converge on one reviewable run configuration.
struct WizardView: View {
    // Internal members are shared only with this view's step/field extensions.
    @Environment(AppStore.self) var store
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.selectedTab") private var settingsTab = "profile"

    @AppStorage("wizard.entryMode") var entryMode = "footage"
    @AppStorage("wizard.sourceGridExpanded") var sourceGridExpanded = true
    @FocusState var sourcesFocused: Bool
    @State var enteredWithHandoff = false
    @State var reviewingIdea = false
    @State var proposedSceneIDs: Set<Int64>?

    @AppStorage("wizard.aiInstructions") var aiInstructions = ""
    @AppStorage("wizard.highlightMaxCount") var highlightMaxCount = 0
    @State var highlightMaxSeconds = 30.0
    @State var highlightVideoPath = ""
    @AppStorage("wizard.formatPreset") var formatPreset = "custom"
    @AppStorage("wizard.lastSceneRecipe") private var lastSceneRecipeID = "custom"
    @AppStorage("wizard.tastePreset") var tastePreset = ""
    @AppStorage(WizardDefaults.durationModeKey) private var durationModeRaw = WizardDurationMode.automatic.rawValue
    @AppStorage(WizardDefaults.customDurationKey) var customDuration = 20
    @AppStorage(WizardDefaults.audioModeKey) private var audioModeRaw = WizardAudioMode.mix.rawValue
    @AppStorage(WizardDefaults.textModeKey) private var textModeRaw = WizardTextMode.automatic.rawValue
    @AppStorage("wizard.useFightResearch") private var useFightResearch = true
    @AppStorage("wizard.critiqueLoop") private var critiqueLoop = true
    @AppStorage("wizard.outcome") private var outcomeRaw = "oneReel"
    @AppStorage("wizard.critiqueTargetScore") var critiqueTargetScore = 85
    @AppStorage("wizard.critiqueMaxVersions") var critiqueMaxVersions = 3
    @AppStorage("wizard.strikeStats") var strikeStats = false
    @AppStorage("wizard.strikeUnits") var strikeUnits = "km/h"
    @AppStorage("wizard.strikeSpeedCallouts") var strikeSpeedCallouts = true
    @AppStorage("wizard.strikeGrapplingCard") var strikeGrapplingCard = true
    @AppStorage("wizard.strikeRoundCard") var strikeRoundCard = true
    @AppStorage("wizard.nameTags") var nameTags = false
    @AppStorage("wizard.nameTagContent") private var nameTagContent: String?
    @AppStorage("wizard.nameTagStyle") private var nameTagStyle: String?
    @AppStorage("wizard.nameTagStyleID") var nameTagStyleID: String?
    @AppStorage("wizard.nameTagPosition") var nameTagPosition: String?
    @AppStorage("wizard.safeAreaOnly") var safeAreaOnly = false
    @AppStorage("wizard.safeAreaPlatforms") var safeAreaPlatforms = ""
    @State var captionPosition: String?
    @State var captionStyleID: String?
    @AppStorage("wizard.captionLanguage") var captionLanguage = ""
    @AppStorage("wizard.dubLanguage") var dubLanguage = ""
    @AppStorage(WizardDefaults.workflowKey) var reviewWorkflowRaw = WizardWorkflow.automatic.rawValue
    @AppStorage("wizard.musicTrack") var musicTrackRaw = ""
    @AppStorage("wizard.overlayStyle") var overlayStyleRaw = ""
    @AppStorage("wizard.pinnedOverlayTemplate") var overlayTemplateRaw = ""
    @AppStorage("wizard.overlayAnimation") var overlayAnimationRaw = ""
    @AppStorage("wizard.overlayPlacement") var overlayPlacementRaw = ""
    @AppStorage("wizard.framingCamera") var framingCameraRaw = WizardDefaults.fallbackFramingCamera
    @AppStorage(WizardDefaults.limitTransitionsKey) var limitTransitions = false
    @AppStorage(WizardDefaults.allowedTransitionsKey) var transitionsRaw = ""
    /// Express navigation: the requested card is the open card; any header opens.
    @State var requestedCard: WizardCardFlow.Card = .source
    @State var collapsedCard: WizardCardFlow.Card?
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var deletingSelection: WizardSelectionSummary?
    @State var musicTracks: [String] = []
    @State var overlayTemplates: [String] = []
    @AppStorage("wizard.highlightFraming") private var highlightFramingRaw = ""
    @AppStorage("wizard.interviewZoom") var interviewZoom = 0.0
    @AppStorage("wizard.interviewZoomMoves") var interviewZoomMoves = false
    @AppStorage("wizard.interviewCuts") var interviewCuts = false
    @AppStorage("wizard.interviewPunchIn") var interviewPunchIn = InterviewPunchIn.vip.rawValue
    @AppStorage("wizard.useBRoll") var useBRoll = true
    @AppStorage("wizard.brollInstructions") var brollInstructions = ""
    @AppStorage("wizard.podcastFraming") private var podcastFramingRaw = PodcastFramingMode.followSpeaker.rawValue
    @AppStorage(WizardDefaults.layoutModeKey) private var layoutModeRaw = WizardLayoutMode.automatic.rawValue
    @AppStorage(WizardDefaults.selectedLayoutsKey) private var selectedLayoutsRaw = ""
    @AppStorage("wizard.bumperIntro") var includeIntroBumper = false
    @AppStorage("wizard.bumperOutro") var includeOutroBumper = false
    @AppStorage("wizard.bumperMiddle") var includeMiddleBumper = false
    @AppStorage(WizardDefaults.brandingOverrideKey) private var brandingOverrideRaw = WizardBrandingOverride.savedDefault.rawValue
    /// On by default: footage starts with nothing selected and the clicked
    /// videos are remembered across launches. "All" is an explicit choice
    /// in the source picker.
    @AppStorage("wizard.limitToSelection") var limitToSelection = true
    @AppStorage("wizard.favoritesOnly") var favoritesOnly = false
    /// Express parity: kept selections render as separate videos or one reel.
    @AppStorage("wizard.outputMode") var outputModeRaw = MiniWizardFlow.OutputMode.separateVideos.rawValue
    @AppStorage("wizard.settingsTab") var settingsTabRaw = ""
    @AppStorage(WizardExpressExtras.transitionChoiceKey) var transitionChoiceRaw = ""
    @AppStorage(WizardExpressExtras.lookPresetKey) var lookPresetRaw = ""
    @AppStorage(WizardExpressExtras.lookIntensityKey) var lookIntensity = 1.0
    @AppStorage(WizardExpressExtras.overlayEnabledKey) var fixedOverlayOn = false
    @AppStorage(WizardExpressExtras.overlayTemplateKey) var fixedOverlayTemplate = ""
    @AppStorage(WizardExpressExtras.overlayStartKey) var fixedOverlayStart = 0.0
    @AppStorage(WizardExpressExtras.overlayDurationKey) var fixedOverlayDuration = 0.0
    @AppStorage(WizardExpressExtras.overlayTextsKey) var fixedOverlayTexts = ""
    @AppStorage(WizardExpressExtras.overlayPositionKey) var fixedOverlayPosition = ""
    @AppStorage(WizardExpressExtras.watermarkOverlayKey) var watermarkOverlay = ""
    @AppStorage(WizardExpressExtras.watermarkOpacityKey) var watermarkOpacity = 0.0
    @AppStorage(WizardExpressExtras.introBumperKey) var introBumperLibraryPath = ""
    @AppStorage(WizardExpressExtras.outroBumperKey) var outroBumperLibraryPath = ""
    @State var availableLookIDs: Set<String>?
    /// Footage follows the source: selections from other sources hide unless asked for.
    @State var showAllSelections = false
    var outputMode: MiniWizardFlow.OutputMode { MiniWizardFlow.OutputMode(rawValue: outputModeRaw) ?? .separateVideos }
    /// Comma-joined Analyze batch IDs — AppStorage cannot persist a Set.
    @AppStorage("wizard.selectedRunIDs") var selectedRunIDsRaw = ""
    /// Comma-joined person keys (empty means anyone in the selected scenes).
    @AppStorage("wizard.sourcePeople") var sourcePeopleRaw = ""
    @AppStorage(SceneStacks.levelKey) var stackLevelRaw = SceneStackLevel.standard.rawValue

    @AppStorage("wizard.modelOverride") var copiedModelOverride = ""
    @AppStorage(AISettingsPreferences.sourceNameKey) var pastedSourceName = "another run"
    @AppStorage(AISettingsPreferences.snapshotKey) var pastedSnapshot = ""
    @AppStorage(WizardDefaults.musicFolderKey) var musicFolderRaw = ""
    @State var runPacing: EditPacing?
    @State var runRenderSettings: RenderSettings?
    @State var musicCount = 0
    @State private var libraryMusicCount = 0
    @State var musicFolders: [String] = []
    @State private var showTrainingGuide = false
    @State private var primaryProviderUnavailable = false
    @State var showSourcePicker = false
    @State private var showManualBuild = false
    @State private var transcriptVideoIDs: Set<Int64> = []
    @State private var pendingDispatch: PendingDispatch?
    /// Presets and per-profile memory for the answers (Express parity).
    @State var presetSheet: PresetSheet?
    @State var presetTitle = "Settings"
    @State private var answersProfile: String?
    private let defaultsChanged = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)

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

    var recipe: ReelRecipe { ReelRecipe.recipe(id: formatPreset) ?? .custom }
    var formPlan: WizardFormPlan { WizardFormPlan(recipe: recipe) }
    var capabilities: ReelRecipe.Capabilities { formPlan.capabilities }

    var fromIdea: Bool { entryMode == "idea" && !enteredWithHandoff }
    var needsFootageProposal: Bool { fromIdea && !reviewingIdea }
    var isFindingFootage: Bool {
        store.jobs.running.contains { $0.kind == .generateRequest && $0.projectID == store.activeProjectID }
    }
    var canStart: Bool {
        if needsFootageProposal {
            return !aiInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !store.scenes.isEmpty && !isFindingFootage && !store.isWizardRunning
        }
        return canGenerate && !isFindingFootage
    }

    private func loadCaptionChoices() {
        let saved = WizardCaptionChoices.load(profileName: store.activeProfile.profileName)
        captionPosition = saved.captionPosition
        captionStyleID = saved.captionStyleID
    }

    func captionChoice(_ path: WritableKeyPath<WizardCaptionChoices, String?>) -> Binding<String?> {
        Binding(get: {
            let choices = WizardCaptionChoices(captionPosition: captionPosition, captionStyleID: captionStyleID)
            return choices[keyPath: path]
        }, set: { value in
            var choices = WizardCaptionChoices(captionPosition: captionPosition, captionStyleID: captionStyleID)
            choices[keyPath: path] = value
            captionPosition = choices.captionPosition
            captionStyleID = choices.captionStyleID
            choices.save(profileName: store.activeProfile.profileName)
        })
    }

    var copiedOptions: WizardOptions? {
        AISettingsJSON.decode(WizardOptions.self, pastedSnapshot)
    }

    var effectivePacing: EditPacing {
        WizardDefaults.resolvedPacing(run: runPacing, copied: copiedOptions, profile: store.activeProfile.defaultPacing)
    }

    var effectiveRenderSettings: RenderSettings {
        WizardDefaults.resolvedRenderSettings(run: runRenderSettings, copied: copiedOptions,
                                             profile: store.activeProfile.defaultRenderSettings)
    }

    var pacingBinding: Binding<EditPacing> {
        Binding(get: { effectivePacing }, set: { runPacing = $0 })
    }

    var renderSettingsBinding: Binding<RenderSettings> {
        Binding(get: { effectiveRenderSettings }, set: { runRenderSettings = $0 })
    }

    func settingOrigin(edited: Bool, copied: Bool) -> String {
        edited ? "This run" : copied ? "Copied override" : "Profile default"
    }

    var fightResearchBinding: Binding<Bool> {
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

    var durationMode: WizardDurationMode {
        WizardDurationMode(rawValue: durationModeRaw) ?? .automatic
    }

    var durationModeBinding: Binding<WizardDurationMode> {
        Binding(
            get: { durationMode },
            set: { durationModeRaw = $0.rawValue }
        )
    }

    var audioMode: WizardAudioMode {
        WizardAudioMode(rawValue: audioModeRaw) ?? .mix
    }

    var audioModeBinding: Binding<WizardAudioMode> {
        Binding(
            get: { audioMode },
            set: { audioModeRaw = $0.rawValue }
        )
    }

    var textMode: WizardTextMode {
        WizardTextMode(rawValue: textModeRaw) ?? .automatic
    }

    var textModeBinding: Binding<WizardTextMode> {
        Binding(
            get: { textMode },
            set: { textModeRaw = $0.rawValue }
        )
    }

    var layoutMode: WizardLayoutMode {
        WizardLayoutMode(rawValue: layoutModeRaw) ?? .automatic
    }

    /// Multi-select of Screen Crop layouts for the "Choose layouts…" mode.
    private var selectedLayouts: Set<String> {
        Set(selectedLayoutsRaw.split(separator: ",").map(String.init))
    }

    var layoutChecklist: some View {
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

    var layoutModeBinding: Binding<WizardLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { layoutModeRaw = $0.rawValue }
        )
    }

    private var brandingOverride: WizardBrandingOverride {
        WizardBrandingOverride(rawValue: brandingOverrideRaw) ?? .savedDefault
    }

    var brandingOverrideBinding: Binding<WizardBrandingOverride> {
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

    var resolvedBranding: WizardBrandingMode {
        brandingOverride.resolved()
    }

    /// The saved batch selection is a global preference; only batches that
    /// belong to the current project count (Home: every batch).
    var selectedRunIDs: Set<Int64> {
        let saved = Set(selectedRunIDsRaw.split(separator: ",").compactMap { Int64($0) })
        return saved.intersection(Set(store.analysisRuns.map(\.id)))
    }

    private func setSelectedRunIDs(_ ids: Set<Int64>) {
        selectedRunIDsRaw = ids.sorted().map(String.init).joined(separator: ",")
    }

    private func activeRunIDs(forVideoIDs videoIDs: Set<Int64>) -> Set<Int64> {
        Set(videoIDs.compactMap { store.activeLayer(videoID: $0).run?.id })
    }

    private var analyzedSceneCount: Int {
        store.sceneIndex.usableCount
    }

    /// People who appear in this project's scenes. Identities are
    /// profile-wide, but a project can only plan around people it has
    /// footage of.
    var projectPeople: [PersonRecord] {
        let tags = Set(store.sceneIndex.personTagsByVideo.values.flatMap { $0 })
        return store.people.filter { tags.contains($0.tag) }
    }

    /// The saved people filter is a global preference; names without
    /// footage in this project are ignored rather than filtering to nothing.
    var selectedSourcePeople: Set<String> {
        let saved = Set(sourcePeopleRaw.split(separator: ",").map(String.init))
        return saved.intersection(Set(projectPeople.map(\.key)))
    }

    var eligibleSourcePeople: [PersonRecord] {
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

    var podcastHighlightVideos: [VideoRecord] {
        WizardFormPlan.podcastHighlightVideos(videos: store.videos, scenes: store.scenes)
    }

    var readiness: [WizardFormPlan.Readiness] {
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

    var workflow: ReelRecipe.Workflow {
        recipe.workflow == .highlights ? .highlights : (ReelRecipe.Workflow(rawValue: outcomeRaw) == .iterate ? .iterate : .oneReel)
    }

    var workflowBinding: Binding<ReelRecipe.Workflow> {
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
        configurationForm
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if UserDefaults.standard.object(forKey: "wizard.dubLanguage") == nil {
                dubLanguage = store.editingDefaults.footage.dubLanguage ?? ""
            }
            adoptAnswers(for: store.activeProfile)
            loadCaptionChoices()
            enteredWithHandoff = store.pendingWizardPrompt?.proposesFootage == false || store.pendingWizardTemplate != nil
            if store.pendingWizardTemplate != nil {
                formatPreset = WizardFormPlan.recipeForSceneHandoff(current: recipe, lastSceneRecipeID: lastSceneRecipeID).id
            }
            if capabilities.sources == .scenes { lastSceneRecipeID = recipe.id }
            if enteredWithHandoff { open(.source) }
            sourcesFocused = !fromIdea
            highlightMaxSeconds = store.editingDefaults.podcast.highlightMaxSeconds
            if highlightVideoPath.isEmpty { highlightVideoPath = podcastHighlightVideos.first?.path ?? "" }
        }
        .onChange(of: pastedSnapshot) { oldValue, newValue in
            let old = AISettingsJSON.decode(WizardOptions.self, oldValue)
            let new = AISettingsJSON.decode(WizardOptions.self, newValue)
            if old?.pacing != new?.pacing { runPacing = nil }
            if old?.renderSettings != new?.renderSettings { runRenderSettings = nil }
            loadCaptionChoices()
            if old?.sourcesRestricted != new?.sourcesRestricted
                || old?.sourceSceneSelection != new?.sourceSceneSelection
                || old?.sourceSceneIDs != new?.sourceSceneIDs
                || old?.sourceVideoPaths != new?.sourceVideoPaths
                || old?.selectedRunIDs != new?.selectedRunIDs
                || old?.sourcePeople != new?.sourcePeople {
                open(.source)
            }
        }
        .onChange(of: store.activeProfile.id) { _, _ in
            runPacing = nil
            runRenderSettings = nil
            adoptAnswers(for: store.activeProfile)
            loadCaptionChoices()
            proposedSceneIDs = nil
            reviewingIdea = false
            resetCardProgress()
        }
        .onChange(of: store.activeProjectID) { _, _ in
            resetCardProgress()
            proposedSceneIDs = nil
            reviewingIdea = false
            enteredWithHandoff = store.pendingWizardPrompt?.proposesFootage == false || store.pendingWizardTemplate != nil
            if let handoff = store.pendingWizardPrompt { applyPromptHandoff(handoff) }
        }
        .onChange(of: store.pendingWizardTemplate) { _, handoff in
            if handoff != nil {
                enteredWithHandoff = true
                open(.source)
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
            open(.source)
            reviewingIdea = false
            if store.pendingWizardPrompt?.proposesFootage == true {
                store.cancelGenerateRequest()
                proposedSceneIDs = nil
            }
        }
        .onChange(of: formatPreset) { oldValue, newValue in
            if let previous = ReelRecipe.recipe(id: oldValue), previous.capabilities.sources == .scenes {
                lastSceneRecipeID = previous.id
            }
            if (ReelRecipe.recipe(id: newValue) ?? .custom).capabilities.sources == .podcastRecording {
                outcomeRaw = ReelRecipe.Workflow.highlights.rawValue
                critiqueLoop = false
                highlightMaxSeconds = store.editingDefaults.podcast.highlightMaxSeconds
                highlightVideoPath = podcastHighlightVideos.first?.path ?? ""
            } else {
                if outcomeRaw == ReelRecipe.Workflow.highlights.rawValue {
                    outcomeRaw = ReelRecipe.Workflow.oneReel.rawValue
                    critiqueLoop = false
                }
                lastSceneRecipeID = newValue
            }
        }
        .onChange(of: customDuration) { _, value in
            let clamped = min(180, max(3, value))
            if clamped != value { customDuration = clamped }
        }
        .onChange(of: limitTransitions) { _, limited in
            updateCopiedOption("allowedTransitions", limited
                ? .array(transitionsRaw.split(separator: ",").map { .string(String($0)) }) : .null)
        }
        .onChange(of: includeIntroBumper) { _, enabled in updateCopiedOption("includeIntroBumper", .bool(enabled)) }
        .onChange(of: includeOutroBumper) { _, enabled in updateCopiedOption("includeOutroBumper", .bool(enabled)) }
        .onChange(of: includeMiddleBumper) { _, enabled in updateCopiedOption("includeMiddleBumper", .bool(enabled)) }
        .onChange(of: musicFolderRaw) { refreshMusicCount() }
        .onChange(of: podcastHighlightVideos.compactMap(\.path)) {
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
        .task(id: WizardFormPlan.ProviderAvailabilityKey(task: formPlan.primaryTask, config: store.effectiveAIConfig)) {
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
                if handoff.statusMessage != nil || handoff.parseFailed { open(.source) }
            }
        }
        .onReceive(defaultsChanged) { _ in
            guard answersProfile == store.activeProfile.profileName else { return }
            WizardMemory.remember(profile: store.activeProfile, renderSettings: runRenderSettings, pacing: runPacing)
            refreshPresetTitle()
        }
        .sheet(item: $presetSheet) { sheet in
            let profileName = store.activeProfile.profileName
            let lastUsed = UserDefaults.standard.string(forKey: WizardPresetStore.lastUsedKey(profileName: profileName))
            switch sheet {
            case .save:
                PresetSaveSheet(title: "Save Wizard Settings", lastUsed: lastUsed,
                                presets: { store.wizardPresets(profileName: profileName) },
                                make: { name in
                                    WizardPreset(name: name, savedAt: Date(), settings: WizardPresetStore.presetFields(
                                        WizardMemory.capture(profile: store.activeProfile, renderSettings: runRenderSettings, pacing: runPacing)))
                                },
                                persist: { store.saveWizardPresets($0, profileName: profileName) }) { preset in
                    WizardPresetStore.rememberLoaded(.init(name: preset.name, settings: preset.settings), profileName: profileName)
                    refreshPresetTitle()
                }
            case .load:
                PresetLoadSheet(title: "Load Wizard Settings", lastUsed: lastUsed,
                                presets: { store.wizardPresets(profileName: profileName) },
                                persist: { store.saveWizardPresets($0, profileName: profileName) },
                                summary: WizardPresetStore.summary,
                                onLoad: { preset in loadPreset(preset) },
                                onRenamed: { oldName, newName in
                                    guard let tracked = WizardPresetStore.loaded(profileName: profileName), tracked.name == oldName else { return }
                                    WizardPresetStore.rememberLoaded(newName.map { .init(name: $0, settings: tracked.settings) }, profileName: profileName)
                                    refreshPresetTitle()
                                },
                                imports: ("From AI Wizard Express",
                                          WizardPresetBridge.wizardPresets(from: store.expressPresets(profileName: profileName))))
            }
        }
        .onDisappear {
            if answersProfile == store.activeProfile.profileName {
                WizardMemory.remember(profile: store.activeProfile, renderSettings: runRenderSettings, pacing: runPacing)
            }
            store.saveActiveProfile()
        }
    }

    /// Bring this profile's remembered answers into the live keys. A profile
    /// never remembered keeps whatever is live, so an install migrates in place.
    private func adoptAnswers(for profile: BrandProfile) {
        guard answersProfile != profile.profileName else { return }
        if let restored = WizardMemory.restore(profileName: profile.profileName) {
            runRenderSettings = restored.renderSettings
            runPacing = restored.pacing
        }
        answersProfile = profile.profileName
        refreshPresetTitle()
    }

    func refreshPresetTitle() {
        let loaded = WizardPresetStore.loaded(profileName: store.activeProfile.profileName)
        presetTitle = WizardPresetStore.cardTitle(loaded: loaded,
            current: WizardMemory.capture(profile: store.activeProfile, renderSettings: runRenderSettings, pacing: runPacing))
    }

    func loadPreset(_ preset: WizardPreset) {
        let profileName = store.activeProfile.profileName
        let restored = WizardMemory.apply(preset.settings, profileName: profileName)
        runRenderSettings = restored.renderSettings
        runPacing = restored.pacing
        loadCaptionChoices()
        WizardPresetStore.rememberLoaded(.init(name: preset.name, settings: preset.settings), profileName: profileName)
        refreshPresetTitle()
    }

    /// Save the current answers under a name, or bring back a saved set.
    var presetButtons: some View {
        HStack(spacing: Theme.spaceS) {
            Button { presetSheet = .save } label: {
                Label("Save…", systemImage: "square.and.arrow.down").lineLimit(1).fixedSize()
            }
            .help("Save these settings under a name")
            Button { presetSheet = .load } label: {
                Label("Load…", systemImage: "tray.and.arrow.up").lineLimit(1).fixedSize()
            }
            .help("Load, rename or delete saved settings")
        }
        .controlSize(.small)
        .disabled(store.isWizardRunning)
    }

    var reviewWorkflow: WizardWorkflow {
        WizardWorkflow(rawValue: reviewWorkflowRaw) ?? .automatic
    }

    private var selectionReview: Bool { reviewWorkflow != .automatic }

    private var lookRecipe: ReelRecipe {
        store.currentWizardSelection.flatMap { ReelRecipe.recipe(id: $0.selection.recipe) } ?? recipe
    }

    var lookFormPlan: WizardFormPlan { WizardFormPlan(recipe: lookRecipe) }
    var lookCapabilities: ReelRecipe.Capabilities { lookFormPlan.capabilities }

    var lookHasFightSources: Bool {
        guard lookCapabilities.fightResearch else { return false }
        let planned = store.currentWizardSelection?.bestTake?.plan.footage?.compactMap(\.videoID) ?? []
        let videoIDs = Set(planned.isEmpty ? sourcePool.map(\.videoID) : planned)
        return store.videos.contains { videoIDs.contains($0.id) && $0.type?.supportsFightFeatures == true }
    }

    var lookTranscriptsAvailable: Bool {
        guard let take = store.currentWizardSelection?.bestTake else { return transcriptsAvailable }
        let videoIDs = Set((take.plan.footage ?? []).compactMap(\.videoID))
        return !transcriptVideoIDs.isDisjoint(with: videoIDs)
    }

    func presentationOptions(for selection: WizardSelectionSummary? = nil) -> WizardOptions {
        let selectedRecipe = selection.flatMap { ReelRecipe.recipe(id: $0.selection.recipe) } ?? lookRecipe
        let videoIDs = Set((selection?.bestTake?.plan.footage ?? []).compactMap(\.videoID))
        let available = selection == nil ? lookTranscriptsAvailable : !transcriptVideoIDs.isDisjoint(with: videoIDs)
        var options = formOptions()
        options.formatPreset = selectedRecipe.id
        let text = textMode.output(transcriptsAvailable: available, recipe: selectedRecipe.id)
        options.captionPosition = captionPosition
        options.captionStyleID = captionStyleID
        options.addCaptions = text.captions
        options.enableTextOverlays = text.headlines
        options.nameTags = selectedRecipe.capabilities.offersCameraFocus && nameTags
        options.nameTagContent = nameTagContent
        options.nameTagStyle = nameTagStyle
        options.nameTagStyleID = nameTagStyleID
        options.nameTagPosition = nameTagPosition
        options.safeAreaOnly = safeAreaOnly
        let platforms = safeAreaPlatforms.split(separator: ",").compactMap { SocialPlatform(rawValue: String($0)) }
        options.safeAreaPlatforms = platforms.isEmpty ? nil : platforms
        options.strikeStats = strikeStats
        options.strikeUnits = strikeUnits
        options.strikeSpeedCallouts = strikeSpeedCallouts
        options.strikeGrapplingCard = strikeGrapplingCard
        options.strikeRoundCard = strikeRoundCard

        return options.neutralized(for: selectedRecipe)
    }

    var projectSelections: [WizardSelectionSummary] {
        store.wizardSelections.filter { $0.selection.projectID == store.activeProjectID }
    }

    var editingSummary: String {
        let text = textMode.output(transcriptsAvailable: lookTranscriptsAvailable, recipe: lookRecipe.id)
        let effectiveAudio = libraryMusicCount == 0 && audioMode.useMusic ? WizardAudioMode.original : audioMode
        return lookFormPlan.editingSummary(audio: effectiveAudio, captions: text.captions, headlines: text.headlines,
            critique: critiqueLoop, branding: brandingOverride == .savedDefault ? "Brand default" : brandingOverride.title,
            useBRoll: useBRoll)
    }

    /// Videos with at least one Analyze batch, in library order.
    var analyzedVideos: [VideoRecord] {
        let ids = Set(store.analysisRuns.map(\.videoID))
        return store.videos.filter { ids.contains($0.id) }
    }

    private func runs(of video: VideoRecord) -> [AnalysisRun] {
        store.analysisRuns.filter { $0.videoID == video.id }
    }

    /// Whether this video's scenes are in the pool: everything contributes
    /// until the run is limited to chosen batches.
    func videoContributes(_ video: VideoRecord) -> Bool {
        WizardFormPlan.videoContributes(runIDs: runs(of: video).map(\.id),
                                        limitToSelection: limitToSelection, selectedRunIDs: selectedRunIDs)
    }

    func toggleVideo(_ video: VideoRecord) {
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

    func recordingSubtitle(_ video: VideoRecord) -> String {
        let exchanges = store.scenes.count {
            $0.videoID == video.id && !$0.excluded && !$0.ignored && $0.tags.contains("podcast-exchange")
        }
        return "\(video.duration.timecode) · \(transcriptVideoIDs.contains(video.id) ? "transcript" : "no transcript") · \(exchanges) exchange\(exchanges == 1 ? "" : "s")"
    }

    func analyzedSubtitle(_ video: VideoRecord) -> String {
        let scenes = sourcePool.count { $0.videoID == video.id }
        let batches = runs(of: video).count
        return "\(video.duration.timecode) · \(scenes) scene\(scenes == 1 ? "" : "s") · \(batches) batch\(batches == 1 ? "" : "es")"
    }

    func recover(_ action: WizardFormPlan.RecoveryAction) {
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

    var cameraFocusBinding: Binding<String> {
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

    func bumperToggle(_ title: String, placement: BumperPlacement, value: Binding<Bool>,
                      bumper: Binding<String>? = nil) -> some View {
        let eligible = store.bumpers.filter { $0.placements.contains(placement) }
        let count = eligible.count
        let help: FieldHelp = switch placement {
        case .intro: WizardFieldHelp.bumperIntro
        case .outro: WizardFieldHelp.bumperOutro
        case .anywhere: WizardFieldHelp.bumperMiddle
        }
        return Group {
            WizardControlRow(title) {
                Toggle(title, isOn: value).disabled(count == 0)
            }
            .fieldHelp(help)
            FormCaption(count == 0 ? "No bumpers allow this placement. Add one in Resources → Bumpers."
                        : "\(count) bumper\(count == 1 ? "" : "s") allow\(count == 1 ? "s" : "") this placement.")
                .formDependent()
            // Express parity: a chosen bumper for this slot; Any keeps the planner's pick.
            if let bumper, value.wrappedValue, !eligible.isEmpty {
                WizardControlRow("\(placement == .intro ? "Intro" : "Outro") bumper") {
                    Picker(title, selection: Binding(
                        get: { eligible.contains { $0.libraryPath == bumper.wrappedValue } ? bumper.wrappedValue : "" },
                        set: { bumper.wrappedValue = $0 })) {
                        Text("Any").lineLimit(1).fixedSize().tag("")
                        ForEach(eligible) { asset in
                            Text(asset.displayName).lineLimit(1).fixedSize().tag(asset.libraryPath)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("\(title) bumper")
                }
                .formDependent()
            }
        }
    }

    func referenceTemplateChip(_ handoff: WizardTemplateHandoff) -> some View {
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

    var generationBar: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            Text(generationSummary)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceM) {
                    generationAction
                    Spacer(minLength: Theme.spaceS)
                    manualBuildAction
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    generationAction
                    manualBuildAction
                }
            }
        }
        .padding(.horizontal, Theme.spaceL)
        .padding(.vertical, Theme.spaceM)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    var generationSummary: String {
        if needsFootageProposal {
            return "Find matching footage in this project, then review the selection before generating."
        }
        if cardFlow.settingsRenders {
            let count = cardFlow.outputCount(oneReel: outputMode == .oneReel)
            return (count == 1 ? "1 video" : "\(count) videos") + " from the kept takes · " + cardFlow.summary(for: .settings)
        }
        return runSummary
    }

    @ViewBuilder var generationAction: some View {
        if isFindingFootage {
            Button("Stop finding footage", role: .destructive) { store.cancelGenerateRequest() }
                .lineLimit(1).fixedSize()
        } else if store.isWizardRunning {
            Button(role: .destructive) { store.cancelWizard() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .controlSize(.large).lineLimit(1).fixedSize()
        } else if cardFlow.settingsRenders {
            // Every kept selection renders, as Express renders its kept candidates.
            let flow = cardFlow
            Button {
                store.generateWizardSelections(options: presentationOptions(), oneReel: outputMode == .oneReel,
                                               selectionIDs: Set(visibleSelections.map(\.id)))
            } label: {
                Label(flow.generateTitle(oneReel: outputMode == .oneReel), systemImage: "film")
            }
            .controlSize(.large).lineLimit(1).fixedSize()
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(flow.isBusy)
            .help(flow.outputCount(oneReel: outputMode == .oneReel) == 1 ? "Render one video from the kept take"
                  : "Render \(flow.outputCount(oneReel: false)) videos, one per kept selection")
        } else if reviewWorkflow == .automatic || needsFootageProposal || capabilities.sources == .podcastRecording {
            Button {
                startGeneration()
            } label: {
                Label(needsFootageProposal ? "Find footage" : (capabilities.sources == .podcastRecording ? "Find highlights" : "Generate reel"), systemImage: "wand.and.stars")
            }
            .controlSize(.large).lineLimit(1).fixedSize()
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canStart)
        } else {
            Button("Find the moments", systemImage: "wand.and.stars", action: findMoments)
                .controlSize(.large).lineLimit(1).fixedSize()
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canStart)
        }
    }

    @ViewBuilder var manualBuildAction: some View {
        if capabilities.sources == .scenes {
            Button("Build manually…") { showManualBuild = true }
                .lineLimit(1).fixedSize()
                .disabled(!canGenerate || isFindingFootage || store.isManualBuildRendering)
                .help("Build this reel yourself from the same source selection, scene by scene")
        }
    }

    @ViewBuilder var copiedSourceRestrictions: some View {
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

    func restrictionChip(_ title: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption).lineLimit(1)
            Button("Remove restriction", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
    }

    var sourceSummary: String {
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

    var framingStatus: String {
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
    var sourcePool: [SceneRecord] {
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
        let copied = AISettingsJSON.decode(WizardOptions.self, pastedSnapshot)
        let explicitSources = (limitToSelection && !selectedRunIDs.isEmpty) || copied?.sourceSceneSelection == true || !(copied?.selectedRunIDs.isEmpty ?? true)
        var pool = (explicitSources ? store.historyScenes : store.scenes).filter { !$0.excluded && !$0.ignored }
        if let copied, copied.sourcesRestricted {
            pool = pool.filter { copied.includesCopiedSource($0) }
        }
        if let proposedSceneIDs { pool = pool.filter { proposedSceneIDs.contains($0.id) } }
        if limitToSelection {
            let runIDs = selectedRunIDs
            pool = pool.filter { $0.runID.map(runIDs.contains) ?? false }
        }
        pool = SceneStacks.tops(pool, level: .from(stackLevelRaw))
        if favoritesOnly {
            pool = pool.filter(\.favorite)
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

    func startGeneration() {
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

    private func applyPromptHandoff(_ handoff: WizardPromptHandoff) {
        if handoff.proposesFootage {
            guard handoff.statusMessage == nil else { return }
            reviewingIdea = true
            open(.source)
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
        open(.source)
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
            setSelectedRunIDs(activeRunIDs(forVideoIDs: handoff.videoIDs))
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

    func updateCopiedOption(_ key: String, _ value: JSONSetting) {
        guard var settings = AISettingsJSON.decode([String: JSONSetting].self, pastedSnapshot) else { return }
        settings[key] = value
        pastedSnapshot = AISettingsJSON.encode(settings) ?? ""
    }

    func findMoments() {
        if needsFootageProposal { startGeneration(); return }
        guard canGenerate, !isFindingFootage else { return }
        let options = formOptions()
        if capabilities.sources == .podcastRecording { store.runWizard(options: options) }
        else { store.findWizardMoments(options: options, presentReview: false) }
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
        options.dubLanguage = dubLanguage.isEmpty ? nil : dubLanguage
        options.workflow = reviewWorkflow
        options.projectID = store.activeProjectID
        options.musicTrack = musicTrackRaw.isEmpty ? nil : musicTrackRaw
        options.overlayStyle = overlayStyleRaw.isEmpty ? nil : overlayStyleRaw
        options.pinnedOverlayTemplate = overlayTemplateRaw.isEmpty ? nil : overlayTemplateRaw
        options.overlayAnimation = overlayAnimationRaw.isEmpty ? nil : overlayAnimationRaw
        options.overlayPlacement = overlayPlacementRaw.isEmpty ? nil : overlayPlacementRaw
        options.muteSource = audio.muteSource && options.useMusic
        options.captionPosition = captionPosition
        options.captionStyleID = captionStyleID
        options.addCaptions = text.captions
        options.enableTextOverlays = text.headlines
        options.nameTags = capabilities.offersCameraFocus && nameTags
        options.nameTagContent = nameTagContent
        options.nameTagStyle = nameTagStyle
        options.nameTagStyleID = nameTagStyleID
        options.nameTagPosition = nameTagPosition
        options.safeAreaOnly = safeAreaOnly
        let platforms = safeAreaPlatforms.split(separator: ",").compactMap { SocialPlatform(rawValue: String($0)) }
        options.safeAreaPlatforms = platforms.isEmpty ? nil : platforms
        options.strikeStats = strikeStats
        options.strikeUnits = strikeUnits
        options.strikeSpeedCallouts = strikeSpeedCallouts
        options.strikeGrapplingCard = strikeGrapplingCard
        options.strikeRoundCard = strikeRoundCard

        options.framingCamera = framingCameraRaw
        options.screenCropLayouts = WizardDefaults.screenCropLayouts(for: layoutMode)
        options.allowedTransitions = pasted?.allowedTransitions ?? WizardOptions.allowedTransitionsFromDefaults()
        options.useFightResearch = pasted?.useFightResearch ?? useFightResearch
        options.aiInstructions = aiInstructions
        options.targetDurationSeconds = durationMode.duration
            ?? (durationMode == .custom ? min(180, max(3, customDuration)) : nil)
        options.formatPreset = formatPreset
        options.highlightFraming = CropRecipe.Kind(rawValue: highlightFramingRaw)
        options.interviewZoom = highlightFramingRaw == CropRecipe.Kind.interview.rawValue ? interviewZoom : nil
        options.interviewZoomMoves = highlightFramingRaw == CropRecipe.Kind.interview.rawValue ? interviewZoomMoves : nil
        options.interviewCuts = highlightFramingRaw == CropRecipe.Kind.interview.rawValue ? interviewCuts : nil
        options.interviewPunchIn = highlightFramingRaw == CropRecipe.Kind.interview.rawValue ? interviewPunchIn : nil
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
        WizardExpressExtras.apply(to: &options) { libraryPath, placement in
            store.bumpers.first { $0.libraryPath == libraryPath && $0.placements.contains(placement) }?.path
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
