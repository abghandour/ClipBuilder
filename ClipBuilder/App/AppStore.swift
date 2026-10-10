import AppKit
import BugReporterKit
import Foundation
import Observation
import UniformTypeIdentifiers

// MAP — AppStore is split by feature. This file keeps the stored state,
// services, diagnostics, errors, profiles, logging, data refresh, updates,
// required tools, and the taste profile. Everything else is an extension:
//
//   AppStore+Projects.swift        projects: create, open, rename, delete, project state saves
//   AppStore+Analysis.swift        analysis runs, checkpoints, batches, people-only pass,
//                                  framing pass, Center Stage hints, auto caption translation
//   AppStore+WizardPipeline.swift  the fire-and-forget Wizard Pipeline (people → analysis → wizard)
//   AppStore+Wizard.swift          wizard runs, generated videos, reviews + lessons, brain export/import
//   AppStore+People.swift          people, video notes, person markers
//   AppStore+AITools.swift         overlay wizard, file names, AI favorites, scene search, soundbites,
//                                  cover frames, trim, duplicates, content gaps, IG lessons, profile starter
//   AppStore+Scenes.swift          scene actions, scene editing and favorites
//   AppStore+Timelines.swift       project timelines, Clip Builder (timeline editing), manual build
//   AppStore+FightResearch.swift   fight research
//   AppStore+Instagram.swift       Instagram accounts, media, publishing
//   AppStore+Jobs.swift            AppJobs starters (camera path, ...)
//   AppStore+ImageSearch.swift     image library search
//   AppStore+ReelModels.swift      on-device reel models
//
// Stored properties owned by those features live under "Feature state" below,
// because Swift extensions cannot declare stored properties.

/// Coarse progress of a wizard run: which stage it's in, how far along the
/// whole run is, and when the stage started (so the UI can show elapsed time
/// during multi-minute AI calls).
struct WizardRunStatus: Equatable {
    var stage: String
    var detail = ""
    /// Overall 0–1 across every requested video/variation.
    var fraction: Double
    var startedAt = Date()
    var stageChangedAt = Date()
}

/// The videos a finished wizard run produced — drives the results sheet.
struct WizardRunResults: Identifiable {
    let id = UUID()
    var videos: [GeneratedVideoRecord]
}

/// Main-actor app state: active profile, its database, background jobs, and
/// the cached lists the views render. One instance lives for the app.
@Observable
final class AppStore {
    // MARK: - State

    var settings: AppSettings { didSet { updateBugReportContext() } }
    var editingDefaults: ProfileEditingDefaults {
        activeProfile.editing ?? ProfileEditingDefaults(seedingFrom: settings)
    }
    var podcastEditingSettings: PodcastSettings {
        editingDefaults.podcast.settings(reviewCutsByDefault: settings.podcast.reviewCutsByDefault)
    }
    var profiles: [BrandProfile] = []
    var activeProfile: BrandProfile {
        didSet {
            updateBugReportContext()
            if oldValue.aiRouting != activeProfile.aiRouting {
                let config = effectiveAIConfig
                Task { await ai.updateConfig(config) }
            }
            if oldValue.profileName != activeProfile.profileName {
                logEvent("app", "Profile switched: \(activeProfile.profileName)")
            }
        }
    }
    var effectiveAIConfig: AIConfig {
        AIRoutingResolver.effectiveConfig(local: settings.ai, team: activeProfile.aiRouting)
    }
    var createdOverlayName: String?
    let teamSync = TeamSyncState()
    var teamSyncCoordinator: TeamSyncCoordinator { teamSync.coordinator }
    let jobs = AppJobs()
    let googleDrive = GoogleDriveTransfers.shared
    var database: Database?

    // Project workspace. Projects scope footage, scenes, timelines, and
    // outputs while people, Instagram, and resources remain profile-wide.
    var projects: [ProjectRecord] = [] { didSet { updateBugReportContext() } }
    var activeProjectID: Int64? {
        didSet {
            updateBugReportContext()
            if oldValue != activeProjectID {
                logEvent("app", "Project switched: \(activeProject?.name ?? "none")")
            }
        }
    }
    var timelines: [TimelineRecord] = []
    var selectedSection: SidebarSection = .sources {
        didSet {
            scheduleProjectStateSave()
            updateBugReportContext()
        }
    }
    var isShowingProjectsHome = false { didSet { updateBugReportContext() } }
    var openTimelineID: Int64?
    var sceneMode = "all" {
        didSet { scheduleProjectStateSave() }
    }
    var outputsSort = "newest" {
        didSet { scheduleProjectStateSave() }
    }
    var outputsScrollID: Int64? {
        didSet { scheduleProjectStateSave() }
    }
    var sourceSelection: Set<Int64> = [] {
        didSet { scheduleProjectStateSave() }
    }
    var sourceScrollID: Int64? {
        didSet { scheduleProjectStateSave() }
    }
    var sceneSelection: Set<Int64> = [] {
        didSet { scheduleProjectStateSave() }
    }
    var sceneScrollID: Int64? {
        didSet { scheduleProjectStateSave() }
    }
    var sceneRunSelection: Set<Int64> = [] {
        didSet { scheduleProjectStateSave() }
    }
    var sceneTagFilter: String? {
        didSet { scheduleProjectStateSave() }
    }
    var sceneSearchText = "" {
        didSet { scheduleProjectStateSave() }
    }
    var sceneShowHidden = false {
        didSet { scheduleProjectStateSave() }
    }
    var sceneSortByScore = false {
        didSet { scheduleProjectStateSave() }
    }
    var sceneMinimumScore = 0.0 {
        didSet { scheduleProjectStateSave() }
    }
    var sceneShowSequenceParts = false {
        didSet { scheduleProjectStateSave() }
    }
    var timelineScrollX = 0.0 {
        didSet { scheduleProjectStateSave() }
    }
    var timelineScrollY = 0.0 {
        didSet { scheduleProjectStateSave() }
    }

    // Captured when work starts so Activity remains truthful after the user
    // switches to another project.
    var analysisProjectName: String?
    var pipelineProjectID: Int64?
    var pipelineProjectName: String?
    var builderRenderProjectName: String?
    /// Project a Builder render is writing into (nil when idle).
    var builderRenderProjectID: Int64?
    /// Project the running Wizard is writing into (nil when idle).
    var wizardProjectID: Int64?
    /// Viewports of timelines touched this session, by timeline id. The
    /// authority while the app runs: list refetches (which follow every
    /// autosave) can race the viewport write and hand back a stale record.
    @ObservationIgnored var timelineViewStates: [Int64: TimelineViewState] = [:]
    /// Bumps once a project's rows AND its restored UI state are in place —
    /// views re-sync their local state on this, never on the bare project id,
    /// which changes before the state is loaded.
    var projectStateVersion = 0
    /// True while `loadProject` is between clearing the lists and applying
    /// the restored state; views must not persist their state meanwhile.
    var isLoadingProject = false
    /// Projects with a job in flight — deleting one would strand its output.
    var busyProjectIDs: Set<Int64> {
        var ids = jobs.busyProjectIDs
        for job in googleDrive.jobs where job.profile == activeProfile.profileName && job.status != .complete {
            if let id = job.projectID { ids.insert(id) }
        }
        if isWizardRunning, let wizardProjectID { ids.insert(wizardProjectID) }
        if isPipelineRunning, let pipelineProjectID { ids.insert(pipelineProjectID) }
        if isBuilderRendering, let builderRenderProjectID { ids.insert(builderRenderProjectID) }
        return ids
    }
    var wizardProjectName: String?

    var activeProject: ProjectRecord? {
        guard let activeProjectID else { return nil }
        return projects.first { $0.id == activeProjectID }
    }

    var isHomeProject: Bool { activeProject?.isHome == true }

    var openTimeline: TimelineRecord? {
        guard let openTimelineID else { return nil }
        return timelines.first { $0.id == openTimelineID }
    }

    var videos: [VideoRecord] = [] { didSet { videosVersion &+= 1 } }
    private(set) var videosVersion = 0
    @ObservationIgnored var rebuildSceneIndexAfterWrite = true
    var scenes: [SceneRecord] = [] {
        didSet {
            if rebuildSceneIndexAfterWrite { sceneIndex = SceneIndex(scenes) }
            rebuildSceneIndexAfterWrite = true
            scenesVersion &+= 1
        }
    }
    /// One-pass lookups over `scenes` (counts, person tags, favorite list),
    /// rebuilt whenever an index-affecting scene field changes so views do
    /// not re-scan the library for counts and tag sets.
    var sceneIndex = SceneIndex()
    /// Bumps with every `scenes` write — a cheap memo key for derived grids.
    private(set) var scenesVersion = 0
    /// Bumps on every profile switch. Long-running work captures it before
    /// its awaits and drops results that belong to a profile that is no
    /// longer active — ids collide across profiles, so stale rows would
    /// otherwise resolve against the wrong library.
    var profileGeneration = 0
    /// Per-log relays that batch background log lines into one append per
    /// turn (see `LogRelay`). Keyed by the log they feed.
    @ObservationIgnored private var logRelays: [ReferenceWritableKeyPath<AppStore, [String]>: LogRelay] = [:]
    /// Logs are capped at this many lines; a multi-hour run otherwise grows
    /// an observed array without bound.
    static let logLineCap = 4000
    var analysisRuns: [AnalysisRun] = [] { didSet { analysisRunsVersion &+= 1 } }
    private(set) var analysisRunsVersion = 0
    var transcriptCounts: [Int64: Int] = [:] { didSet { transcriptCountsVersion &+= 1 } }
    private(set) var transcriptCountsVersion = 0
    /// Distinct people the people pass found per video; the Sources table
    /// shows them as soon as a detection finishes.
    var videoPeopleCounts: [Int64: Int] = [:] { didSet { videoPeopleVersion &+= 1 } }
    /// Analyses that started and did not finish, by video — what Analyze
    /// offers to resume and the Sources table marks. Mirrors the
    /// `analysis_checkpoints` table.
    var analysisCheckpoints: [Int64: AnalysisCheckpoint] = [:]
    private(set) var videoPeopleVersion = 0
    var people: [PersonRecord] = []
    /// Saved fight research by video id — the Analyze page's column and the
    /// wizards' story/caption injection read from here.
    var fightResearch: [Int64: FightResearchRecord] = [:]
    /// Videos whose fight research is being crawled right now.
    var fightResearchInFlight: Set<Int64> = []
    var personResearchInFlight: Set<Int64> = []
    var personTagFieldsVersion = 0
    /// Roster context observed by people passes, including people without scene tags.
    @ObservationIgnored var personResearchVideoIDs: [Int64: Set<Int64>] = [:]
    /// Injectable per-person operation for network-free job/trigger tests.
    @ObservationIgnored var personResearchRunner: (@Sendable (PersonResearchRequest) async throws -> PersonResearchOutcome)?
    /// Scored fight-action events by video id — the pace/winning graphs
    /// under the video and scene timelines render from these.
    var fightEvents: [Int64: [FightEventRecord]] = [:]
    /// Videos whose fight-scoring pass is running right now.
    var fightScoringInFlight: Set<Int64> = []
    var generatedVideos: [GeneratedVideoRecord] = []
    var feedback: [FeedbackRecord] = []
    var lessons: [WizardLesson] = []

    /// Variation batch awaiting an A/B pick, presented by the main window
    /// after a multi-variation wizard run; further batches queue behind it.
    var pendingComparison: ComparisonBatch?
    /// People first detected by the just-finished analysis — presented for
    /// naming/merging as soon as the run ends.
    var pendingPeopleReview: PeopleReviewRequest?
    /// Filename proposals from the just-finished analysis, for files whose
    /// names looked auto-generated — presented after the people review.
    var pendingRenameReview: RenameReviewRequest?
    var comparisonQueue: [ComparisonBatch] = []

    /// FIFO of pending alerts; the main window presents the first entry and
    /// dequeues on dismiss, so one failure can't silently replace another.
    private(set) var errorQueue: [AppError] = []
    var currentError: AppError? { errorQueue.first }

    /// Hand-off from the Scenes screen: open the Analyze tab with this video
    /// selected and the model-plan sheet prefilled from a past batch.
    var pendingAnalyzeSetup: VideoRecord?

    // Analysis job
    var isAnalyzing = false {
        didSet { logDiagnosticOperation("Analysis", channel: "analysis", running: isAnalyzing, previously: oldValue) }
    }
    var analysisLog: [String] = []
    var analysisProgress: Double = 0
    var analysisStage = ""
    var analysisTask: Task<Void, Never>?

    // Transcription job
    var transcribingVideoIDs: Set<Int64> = []
    var transcriptionTasks: [Int64: Task<Void, Never>] = [:]

    // Wizard job
    var isWizardRunning = false
    /// True while a Builder pre-fill plan runs — drives the Builder's
    /// progress toolbar.
    var isPlanningIntoBuilder = false
    var builderPlanResult: BuilderPlanResult?
    /// The last "Render to Library" output, presented in a player as soon as
    /// the render finishes; cleared when the sheet closes.
    var finishedBuilderRender: FinishedRender?
    /// The live inline Wizard also supplies the window-wide status and log.
    var builderWizard: WizardSheetModel?
    var isScriptPreviewRunning = false
    var wizardLog: [String] = [] {
        didSet { updateDiagnosticStatus(wizardLog, previousCount: oldValue.count) }
    }
    /// Human-readable progress for the running generation, derived from the
    /// engine's log stream — so multi-minute AI calls don't look like a hang.
    var wizardStatus: WizardRunStatus? {
        didSet {
            if let wizardStatus {
                recordDiagnosticStatus("\(wizardStatus.stage): \(wizardStatus.detail)")
            }
        }
    }
    /// Videos produced by the finished run, presented as the results sheet.
    var wizardResults: WizardRunResults?
    var pendingPodcastHighlights: PodcastHighlightReviewRequest?
    var awaitingPodcastReviewDismissal = false
    var podcastResultsAfterDismissal: WizardRunResults?
    var pendingWizardSelectionReview: WizardSelectionReviewRequest?
    var wizardSelections: [WizardSelectionSummary] = []
    var miniRun: MiniWizardRun?
    /// Serial scene trims; Mini waits for the latest write before recording Q&A takes.
    var sceneEditSaveTask: Task<Void, Error>?
    var activeWizardSelectionID: Int64?
    var wizardLookRevision = 0
    var wizardSelectionSaveTask: Task<Void, Error>?
    var wizardSelectionAfterDismissal: (() -> Void)?
    /// Options of the last run — "Retry" in the results sheet re-runs them.
    var lastWizardOptions: WizardOptions?
    /// Why the last generation produced nothing — shown as a banner in the
    /// wizard's log panel with a Try Again, instead of only a red log line.
    var wizardFailureMessage: String?
    /// Videos the running analysis is working on right now (the Sources row
    /// spinner follows the job, not the selection).
    var analyzingVideoIDs: Set<Int64> = []
    /// Shown in the status bar after a run so a finished analysis is visible
    /// even when the video already had scenes.
    struct AnalysisCompletion: Equatable {
        var summary: String
        var failed: Int
        var stopped: Bool
    }
    var analysisCompletion: AnalysisCompletion?
    /// Presents the Training Guide sheet from the main window (Help menu).
    var showTrainingGuide = false
    /// File ▸ Export Resources… / Import Resources… sheets.
    var showResourceExport = false
    var resourceImportURL: URL?

    /// File ▸ Import Resources…: pick a bundle, then preview it in a sheet.
    func chooseResourceBundleToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Resources"
        panel.message = "Choose a Clip Builder resource bundle (.zip)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        resourceImportURL = url
    }

    /// After an import: re-register fonts, drop cached layout listings, and
    /// reload profiles so the switcher and the active profile reflect the
    /// files on disk.
    func resourcesDidChange(_ summary: ResourceImportSummary) async {
        let generation = profileGeneration
        if summary.imported + summary.replaced + summary.renamed > 0 {
            AssetStore.invalidateCatalog()
            OverlayTemplateStore.invalidateCache()
            // "Replace existing" rewrites files at their old paths; the
            // decoded-image cache is keyed by path, so drop it.
            ImageCache.removeAll()
        }
        if summary.fontsChanged { await Task.detached { AssetStore.registerFonts() }.value }
        guard generation == profileGeneration else { return }
        if summary.screenCropsChanged { ScreenCropStore.invalidateListing() }
        if summary.profilesChanged {
            let loaded = await Task.detached {
                let profiles = ProfileStore.listProfiles()
                return profiles.isEmpty ? [ProfileStore.ensureDefaultProfile()] : profiles
            }.value
            guard generation == profileGeneration else { return }
            profiles = loaded
            if let refreshed = profiles.first(where: { $0.profileName == activeProfile.profileName }) {
                activeProfile = refreshed
                teamSync.configure(store: self)
            }
        }
        if summary.preferencesApplied > 0 { WizardDefaults.migrateLegacy() }
    }
    var isDistillingLessons = false
    var isDistillingHouseStyle = false
    /// Result line of the last Wizard Brain export/import, for Settings.
    var wizardBrainStatus: String?
    var wizardTask: Task<Void, Never>?

    // Clip Builder
    let builder = BuilderTimelineModel()
    var isBuilderRendering = false {
        didSet { logDiagnosticOperation("Builder render", channel: "builder", running: isBuilderRendering, previously: oldValue) }
    }
    /// True while Builder is rendering an exact, temporary preview. Unlike a
    /// normal render, this never creates a Library item.
    var isBuilderPreviewRendering = false {
        didSet { logDiagnosticOperation("Builder preview render", channel: "builder-preview", running: isBuilderPreviewRendering, previously: oldValue) }
    }
    var builderLog: [String] = []
    var builderRenderTask: Task<Void, Never>?

    /// A rendered slice of the final video that plays in the Builder monitor.
    nonisolated struct BuilderInPlacePreview: Sendable, Equatable {
        /// Output range of the timeline this file covers.
        var window: ClosedRange<Double>
        var url: URL
        /// Content digest of everything that produced this file.
        var key: String
    }
    /// The slice currently playing in place; nil when the monitor shows the still.
    var builderPreview: BuilderInPlacePreview?
    /// The window being rendered for the user right now (not a prefetch).
    var builderPreviewWindow: ClosedRange<Double>?
    /// The range the last in-place playback covered, for Replay.
    var builderPreviewLastPlayed: ClosedRange<Double>?
    var builderPreviewTask: Task<Void, Never>?
    var builderPrefetchTask: Task<Void, Never>?
    /// Rendered slices by content key, most recently used last.
    var builderPreviewCache: [String: BuilderInPlacePreview] = [:]
    var builderPreviewCacheOrder: [String] = []
    static let builderPreviewCacheLimit = 12
    /// Where the playback chain started, so Replay covers the whole run.
    var builderPreviewChainStart: Double?

    // Instagram
    var igAccounts: [IGAccountRecord] = []
    var igSelectedAccountID: Int64?
    var igMedia: [IGMediaRecord] = []
    var isFetchingInstagram = false
    var igLog: [String] = []
    var igFetchTask: Task<Void, Never>?
    /// Media rows with a cached template analysis (for the selected account).
    var igTemplatedMediaIDs: Set<Int64> = []
    var igAnalyzingMediaIDs: Set<Int64> = []
    var igDownloadingMediaIDs: Set<Int64> = []
    /// The Reports tab's assembled report for the selected account.
    var igReport: InstagramReport?
    var igReportPeriod: ReportPeriod = ReportPeriod.from(
        id: UserDefaults.standard.string(forKey: "instagram.reportPeriod") ?? "last30")
    var isLoadingIGReport = false
    var isImportingPeaceGrappler = false
    /// Result line of the last peace-grappler history import, for Settings.
    var igImportStatus: String?
    /// What performs on the connected account — feeds the wizard, the
    /// critic, captions, and the publish sheet. Rebuilt after every
    /// refresh and import.
    var igBenchmarks: AccountBenchmarks?
    /// Bottom status strip for an Instagram refresh or history import —
    /// the Wizard Pipeline pattern: stage + progress, click for the log,
    /// stays as "done"/"stopped"/"failed" until dismissed.
    struct IGSyncStatus: Equatable {
        var title: String            // "Instagram Refresh" | "Report History Import"
        var stage: String
        var fraction: Double
        var running = true
    }
    var igStatus: IGSyncStatus?
    var igImportTask: Task<Void, Never>?
    var isConnectingInstagram = false
    var isPublishingToInstagram: Bool { jobs.hasLiveTask(kind: .instagramPublish) }
    /// A taste-exemplar study is running (one at a time).
    var isStudyingTaste = false
    var igAnalyzeTasks: [Int64: Task<Void, Never>] = [:]
    /// Template picked in the Instagram tab, consumed by the Wizard's next
    /// run (or dismissed from its chip).
    var pendingWizardTemplate: WizardTemplateHandoff?
    /// "Generate Video" request from the Analyze/Scenes/People screens; the
    /// Wizard seeds its form from it and keeps it until the user dismisses
    /// its card.
    var wizardPromptRequests: [Int64: WizardPromptHandoff] = [:]
    var pendingWizardPrompt: WizardPromptHandoff? {
        get { wizardPromptRequests[activeProjectID ?? 0] }
        set { wizardPromptRequests[activeProjectID ?? 0] = newValue }
    }
    /// Set by views (e.g. "Open in Builder") to ask the main window to switch
    /// sidebar sections; the window consumes and clears it.
    var requestedSection: SidebarSection?
    /// The person the People screen should select when it next shows (set
    /// with `requestedSection = .people`); the screen consumes and clears it.
    var requestedPersonID: Int64?

    // Updates
    /// What an update check concluded; the main window presents it as one
    /// alert. `.upToDate` is only set for manual checks — the launch check
    /// stays silent unless there is something to install.
    var updateCheckResult: UpdateCheckResult?
    var isDownloadingUpdate = false
    /// Set once the update flow has already run `flushForTermination()`, so
    /// the app delegate can answer `terminate` with `.terminateNow` instead
    /// of deferring (see `installUpdate`).
    @ObservationIgnored var hasFlushedForTermination = false
    private var hasCheckedForUpdatesAtLaunch = false

    // Required command-line tools (ffmpeg, ffprobe, yt-dlp)
    var isInstallingTools = false
    private var hasCheckedToolsAtLaunch = false
    /// Optional AI provider CLIs currently installing (keys: "qwen", "kimi").
    var installingProviderCLIs: Set<String> = []

    // MARK: - Feature state
    // Stored properties owned by the feature extensions (AppStore+*.swift);
    // Swift extensions cannot declare stored properties, so they live here.

    /// Videos whose fresh transcript should be translated to the language
    /// Settings names; a main window's translation runner drains it. Ids
    /// belong to the open profile: the queue empties on a profile switch.
    var autoTranslateQueue: [Int64] = []

    /// The video a runner has claimed (checking or translating it), so two
    /// windows' runners never work the same head.
    var autoTranslateInFlight: Int64?

    /// Fire-and-forget orchestration state — the bottom bar renders from
    /// these while the run works through its steps in the background.
    var isPipelineRunning = false

    var pipelineLog: [String] = [] {
        didSet { updateDiagnosticStatus(pipelineLog, previousCount: oldValue.count) }
    }

    var pipelineProgress: Double = 0

    var pipelineStage = "" {
        didSet {
            if !pipelineStage.isEmpty, oldValue != pipelineStage { recordDiagnosticStatus(pipelineStage) }
        }
    }

    /// Opens the full pipeline log sheet (clicking the bottom bar).
    var pipelineTask: Task<Void, Never>?

    var pipelineTargets: [VideoRecord] = []

    var pipelineOptions: PipelineOptions?

    var pipelineDone: Set<String> = []

    var pipelineRunIDs: [Int64: Int64] = [:]

    /// Reels rendered so far this run — the combined results sheet at the
    /// end covers pre-stop renders too.
    var pipelineGenerated: [GeneratedVideoRecord] = []

    /// New-people review captured mid-run and re-queued when the run ends —
    /// the pipeline never prompts while it works.
    var pipelineDeferredPeople: PeopleReviewRequest?

    /// A performance-lesson distillation is running (one at a time).
    var isDistillingPerformanceLessons = false

    @ObservationIgnored var timelineSaveVersion: UInt64 = 0

    @ObservationIgnored var pendingTimelineSaves: [TimelineSaveKey: TimelineSaveSnapshot] = [:]

    @ObservationIgnored var timelineSaveTasks: [TimelineSaveKey: Task<Void, Never>] = [:]

    @ObservationIgnored var wizardCommitInProgress = false

    @ObservationIgnored var wizardBeforeSnapshots: [TimelineSaveKey: (uuid: String, document: TimelineDocument)] = [:]

    @ObservationIgnored var timelineSaveFailures: [TimelineSaveKey: ApplyFailure] = [:]

    var isManualBuildRendering = false {
        didSet { logDiagnosticOperation("Manual build render", channel: "wizard", running: isManualBuildRendering, previously: oldValue) }
    }

    /// An exact (real-pipeline) preview render is in flight for the wizard.
    var isManualBuildPreviewRendering = false {
        didSet { logDiagnosticOperation("Manual build preview render", channel: "wizard", running: isManualBuildPreviewRendering, previously: oldValue) }
    }

    /// The manual build document exactly as a render receives it — the branded
    /// outro card appended when enabled. Shared by Generate and the exact
    /// preview so both see the same timeline.
    var manualBuildBumperSelection: (key: String, clips: [TimelineClip])?

    /// A people-only detection is running (one at a time).
    var isDetectingPeople = false

    /// Run (or re-run) the people-only AI pass for one video and return the
    /// fresh roster. Provider/model override the dispatcher's routing (the
    /// analyze sheet passes its picker's live choice).
    /// Status-bar text for a run over several videos ("2 of 3"); nil for one.
    var peopleDetectionStage: String?

    /// The video whose people are being detected right now (its Sources
    /// row shows the spinner).
    var detectingPeopleVideoID: Int64?

    /// A framing-detection pass is running (one at a time).
    var isDetectingFraming = false

    var framingProgress = 0.0

    // MARK: - Services

    let ai: AIService
    let thumbnails = ThumbnailService()
    let renderEngine = RenderEngine()
    var builderLibraryHydration: BuilderLibraryHydration { builder.scriptLibraryHydration }
    private var scriptPrerequisites: BuilderPrerequisites?

    /// Shared across Wizard sessions for per-kind/video in-flight deduplication.
    var builderPrerequisites: BuilderPrerequisites {
        if let scriptPrerequisites { return scriptPrerequisites }
        let adapters = BuilderPrerequisites { [weak self] in
            guard let self else { return nil }
            return self.captureBuilderPrerequisites()
        }
        scriptPrerequisites = adapters
        return adapters
    }

    /// Each run captures this profile's cleanup policy before leaving the UI.
    var transcription: TranscriptionService {
        TranscriptionService(podcastSettings: podcastEditingSettings)
    }
    let analyzer: Analyzer
    let podcastAnalysis: PodcastAnalysisService
    let wizard: WizardEngine
    let multitrackRenderer: MultitrackRenderer
    let instagram: InstagramService
    let fightResearchService: FightResearchService
    private(set) var bumpers: [BumperAsset] = []
    private var bumperWatchers: [URL: FolderWatcher] = [:]
    private var watchesBumpers = false
    private var bumperObserver: AssetCatalogSubscription?
    private var bumperRefresh: Task<Void, Never>?

    func refreshBumpers() {
        bumperRefresh?.cancel()
        let database = database
        bumperRefresh = Task { [weak self] in
            let loaded = (try? await database?.bumpers()) ?? []
            guard !Task.isCancelled else { return }
            self?.bumpers = loaded
            if self?.watchesBumpers == true {
                let folders = await AssetStore.foldersAsync(of: .bumpers)
                guard !Task.isCancelled else { return }
                self?.watchBumperFolders(folders)
            }
        }
    }

    private func watchBumperFolders(_ folders: Set<URL>) {
        for url in Array(bumperWatchers.keys) where !folders.contains(url) {
            bumperWatchers.removeValue(forKey: url)?.stop()
        }
        for url in folders where bumperWatchers[url] == nil {
            let watcher = FolderWatcher { AssetStore.invalidateCatalog(.bumpers) }
            watcher.watch(url)
            bumperWatchers[url] = watcher
        }
    }

    func bumperDisplayName(for clip: TimelineClip) -> String {
        if let asset = bumpers.first(where: { $0.path == clip.videoFile }) { return asset.displayName }
        if let name = clip.bumperName { return name }
        return clip.videoFile.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Bumper"
    }

    var watcher: FolderWatcher?
    @ObservationIgnored private let opensProfiles: Bool
    @ObservationIgnored var projectStateSaveTask: Task<Void, Never>?

    convenience init() {
        // What the CLIs offer today, before any picker is built (a small
        // file read; the Settings tab can ask again).
        AICatalog.applyDiscovered(ModelDiscovery.discover())
        let settings = SettingsStore.loadSettings()
        let defaultProfile = ProfileStore.ensureDefaultProfile()
        var loaded = ProfileStore.listProfiles()
        if loaded.isEmpty { loaded = [defaultProfile] }
        let activeName = SettingsStore.loadActiveProfileName()
        let active = loaded.first { $0.profileName == activeName } ?? loaded[0]
        self.init(settings: settings, profiles: loaded, active: active,
                  ai: AIService(config: AIRoutingResolver.effectiveConfig(local: settings.ai, team: active.aiRouting)),
                  startWatcher: true, openProfile: true)
        do {
            try migrateInstagramConnection()
        } catch {
            presentError("Could not migrate the Instagram connection; it will retry next launch", error)
        }
        // A saved data folder on an external or unmounted volume was ignored
        // while loading; forget it so the fallback is permanent and the
        // explanation shows once.
        if let rejected = SettingsStore.takeRejectedDataFolder() {
            UserDefaults.standard.removeObject(forKey: SettingsStore.dataFolderDefaultsKey)
            presentError("The data folder \(rejected.path) can't be used because \(rejected.reason). "
                         + "Databases and caches must stay on the internal disk, so Clip Builder is using "
                         + "the default folder \(SettingsStore.dataDirectory.path) instead. "
                         + "Video files can stay on external drives.")
        }
    }

    /// Dependency-injected construction for state tests and isolated tools.
    /// Production construction keeps using `init()` above.
    init(settings: AppSettings, profiles: [BrandProfile], active: BrandProfile,
         ai: AIService, database: Database? = nil, instagramService: InstagramService? = nil,
         startWatcher: Bool = false, openProfile: Bool = false) {
        self.settings = settings
        self.profiles = profiles
        activeProfile = active
        self.database = database
        self.ai = ai
        analyzer = Analyzer(ai: ai)
        podcastAnalysis = PodcastAnalysisService(ai: ai)
        wizard = WizardEngine(ai: ai, render: renderEngine)
        multitrackRenderer = MultitrackRenderer(render: renderEngine)
        let instagramPersistence = InstagramTokenPersistence()
        instagram = instagramService ?? InstagramService(ai: ai, persistTokenRefresh: { refresh, connection, token in
            try await instagramPersistence.save(refresh, connection: connection, replacing: token)
        })
        fightResearchService = FightResearchService(ai: ai)
        opensProfiles = openProfile
        jobs.store = self
        instagramPersistence.store = self

        builder.onTimelineAutosave = { [weak self] id, document in
            self?.saveTimeline(id: id, document: document)
        }
        builder.onUIStateChange = { [weak self] in
            self?.scheduleProjectStateSave()
        }

        // Settings reads the migrated wizard keys directly, so migrate before
        // any view (not only the Wizard tab) can show them.
        WizardDefaults.migrateLegacy()

        if startWatcher {
            watcher = FolderWatcher { [weak self] in
                self?.scanSourceFolder()
            }
        }
        bumperObserver = AssetCatalogSubscription { [weak self] in self?.refreshBumpers() }
        watchesBumpers = startWatcher
        if startWatcher { AssetStore.ensureRoots() }
        if openProfile { openActiveProfile() }
        refreshBumpers()
        updateBugReportContext()
    }

    // MARK: - Diagnostics

    @ObservationIgnored let bugReportContext = BugReportContextSnapshot()
    @ObservationIgnored var diagnosticLogSink: (String, String) -> Void = { BugReporter.log($0, $1) }

    /// Every log line the app produces, newest last, for the status bar's
    /// log drawer: analysis, pipeline, wizard, builder, Instagram, app and
    /// error channels all land here as well as in the diagnostic file.
    private(set) var unifiedLog: [AppLogLine] = []
    static let unifiedLogLimit = 1000
    @ObservationIgnored private var unifiedLogSequence = 0

    func recordUnifiedLog(channel: String, text: String) {
        guard let text = LogRelay.displayText(text) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for line in trimmed.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            unifiedLogSequence += 1
            unifiedLog.append(AppLogLine(id: unifiedLogSequence, time: Date(), channel: channel,
                                         text: String(line.prefix(2000))))
        }
        if unifiedLog.count > Self.unifiedLogLimit {
            unifiedLog.removeFirst(unifiedLog.count - Self.unifiedLogLimit)
        }
    }

    func clearUnifiedLog(channel: String = "") {
        if channel.isEmpty { unifiedLog.removeAll() }
        else { unifiedLog.removeAll { $0.channel == channel } }
    }

    /// Record one line for the status bar and the diagnostic file.
    func logEvent(_ channel: String, _ line: String) {
        recordUnifiedLog(channel: channel, text: line)
        diagnosticLogSink(channel, line)
    }
    @ObservationIgnored var diagnosticsDataFolder = "" { didSet { updateBugReportContext() } }
    @ObservationIgnored var diagnosticsFFmpegVersion: String? { didSet { updateBugReportContext() } }
    @ObservationIgnored private var diagnosticStatus: [String] = []
    @ObservationIgnored private var diagnosticStarts: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var observesBugReportState = false

    func updateBugReportContext() {
        let connected: Bool
        if case .connected = googleDrive.states[activeProfile.profileName] { connected = true }
        else { connected = false }
        bugReportContext.update(BugReportContext(
            profile: activeProfile.profileName, project: activeProject?.name ?? "",
            section: isShowingProjectsHome ? "projects" : selectedSection.rawValue,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            ffmpegVersion: diagnosticsFFmpegVersion,
            driveConnected: connected, instagramConnected: settings.instagram.isGraphConnected,
            dataFolder: diagnosticsDataFolder, recentStatus: diagnosticStatus
        ))
    }

    func startBugReportObservation() {
        guard !observesBugReportState else { return }
        observesBugReportState = true
        observeBugReportConnections()
    }

    private func observeBugReportConnections() {
        updateBugReportContext()
        withObservationTracking {
            _ = googleDrive.states
        } onChange: { [weak self] in
            // Observation fires before mutation; read and re-arm on the next actor turn.
            Task { @MainActor [weak self] in self?.observeBugReportConnections() }
        }
    }

    private func updateDiagnosticStatus(_ lines: [String], previousCount: Int) {
        guard !lines.isEmpty else { updateBugReportContext(); return }
        let count = min(3, max(1, lines.count - previousCount))
        diagnosticStatus.append(contentsOf: lines.suffix(count))
        diagnosticStatus = Array(diagnosticStatus.suffix(3))
        updateBugReportContext()
    }

    private func recordDiagnosticStatus(_ line: String) {
        diagnosticStatus.append(line)
        diagnosticStatus = Array(diagnosticStatus.suffix(3))
        updateBugReportContext()
    }

    private func logDiagnosticOperation(_ name: String, channel: String, running: Bool, previously: Bool) {
        guard running != previously else { return }
        if running {
            diagnosticStarts[name] = .now
            logEvent(channel, "\(name) start")
        } else if let start = diagnosticStarts.removeValue(forKey: name) {
            logEvent(channel, "\(name) end; duration=\(start.duration(to: .now))")
        }
    }

    // MARK: - Errors

    func presentError(_ message: String) {
        logEvent("error", message)
        errorQueue.append(AppError(message: message, context: message, details: message))
    }

    /// Queue an alert for a failed operation; user-initiated cancellations
    /// are not errors and are dropped.
    func presentError(_ context: String, _ error: Error) {
        let appError = AppError.failure(context: context, error: error)
        logEvent("error", "\(context): \(appError.details)")
        guard !(error is CancellationError) else { return }
        errorQueue.append(appError)
    }

    /// Open the provider CLI's sign-in in Terminal (from the error alert
    /// or Settings → AI). The CLI runs its own browser flow; the app just
    /// gets the user there.
    func openProviderSignIn(_ key: String) {
        let label = AICatalog.provider(key)?.label ?? key
        Task {
            let binary = await ai.binaryURL(forProvider: key)
            do {
                try ProviderAuth.openSignInTerminal(provider: key, binary: binary)
                // Signing in is the fix for the failure that started the
                // cooldown; the next call may try the provider again.
                await ai.clearCooldown(provider: key)
                appendLog(\.analysisLog, ["Opened \(label) sign-in in Terminal — finish there, then retry"])
            } catch {
                presentError("Couldn't open \(label) sign-in", error)
            }
        }
    }

    func dismissCurrentError() {
        if !errorQueue.isEmpty { errorQueue.removeFirst() }
    }

    private(set) var noticeQueue: [AppNotice] = []
    var currentNotice: AppNotice? { noticeQueue.first }

    /// Queue an informational alert (not an error: no report button).
    func presentNotice(_ title: String, _ message: String) {
        logEvent("notice", "\(title): \(message)")
        noticeQueue.append(AppNotice(title: title, message: message))
    }

    func dismissCurrentNotice() {
        if !noticeQueue.isEmpty { noticeQueue.removeFirst() }
    }

    /// "A, B and C" for a short list of names, "A and 4 more" past five.
    nonisolated static func nameList(_ names: [String]) -> String {
        let shown = names.prefix(5)
        let rest = names.count - shown.count
        var text = shown.count == 1 ? shown[0]
            : shown.dropLast().joined(separator: ", ") + " and " + (shown.last ?? "")
        if rest > 0 { text = shown.joined(separator: ", ") + " and \(rest) more" }
        return text
    }

    // MARK: - Profiles

    func openActiveProfile() {
        ProfileStore.ensureFolders(for: activeProfile)
        do {
            database = try Database(path: SettingsStore.databaseURL(profileName: activeProfile.profileName))
        } catch {
            database = nil
            presentError("Could not open the profile database", error)
        }
        refreshBumpers()
        watcher?.watch(activeProfile.sourceFolderURL)
        builder.load(profileName: activeProfile.profileName,
                     defaultRenderSettings: activeProfile.defaultRenderSettings)
        Task { await initializeProjectWorkspace() }
        loadInstagramCache()
        teamSync.configure(store: self)
        scanSourceFolder()
    }

    func switchProfile(named name: String) {
        guard let profile = profiles.first(where: { $0.profileName == name }) else { return }
        builder.flushPendingAutosave()
        flushActiveProjectState()
        activeProfile = profile
        SettingsStore.saveActiveProfileName(name)
        scriptPrerequisites?.cancelAll()
        profileGeneration &+= 1
        jobs.profileDidChange()
        videos = []
        scenes = []
        analysisRuns = []
        transcriptCounts = [:]
        people = []
        generatedVideos = []
        feedback = []
        lessons = []
        projects = []
        activeProjectID = nil
        timelines = []
        openTimelineID = nil
        isShowingProjectsHome = false
        fightResearch = [:]
        previousSpeakerMaps = [:]
        previousPeopleMerge = nil
        personResearchInFlight = []
        personResearchVideoIDs = [:]
        personTagFieldsVersion &+= 1
        fightEvents = [:]
        igBenchmarks = nil
        pendingComparison = nil
        comparisonQueue = []
        autoTranslateQueue = []
        autoTranslateInFlight = nil
        pendingPeopleReview = nil
        pendingRenameReview = nil
        pendingAnalyzeSetup = nil
        igAccounts = []
        igSelectedAccountID = nil
        igMedia = []
        igTemplatedMediaIDs = []
        igReport = nil
        pendingWizardTemplate = nil
        wizardPromptRequests = [:]
        pendingWizardSelectionReview = nil
        wizardSelectionAfterDismissal = nil
        wizardSelectionSaveTask = nil
        wizardSelections = []
        miniRun = nil
        sceneEditSaveTask = nil
        activeWizardSelectionID = nil
        pendingPodcastHighlights = nil
        podcastResultsAfterDismissal = nil
        wizardResults = nil
        wizardTask?.cancel()
        lastWizardOptions = nil
        wizardFailureMessage = nil
        timelineViewStates = [:]
        if opensProfiles {
            openActiveProfile()
        } else {
            builder.load(profileName: activeProfile.profileName,
                         defaultRenderSettings: activeProfile.defaultRenderSettings)
        }
    }

    // MARK: - Logging

    /// A `@Sendable` log sink for `keyPath` that coalesces bursts of lines
    /// into one main-actor append — hand it to services' `log:` parameters.
    @ObservationIgnored private var sectionLogRelays: [String: LogRelay] = [:]

    func logSink(_ keyPath: ReferenceWritableKeyPath<AppStore, [String]>, channel: String? = nil) -> @Sendable (String) -> Void {
        if let channel {
            if let relay = sectionLogRelays[channel] { return relay.sink }
            let relay = LogRelay { [weak self] lines in
                self?.appendLog(keyPath, lines, channel: channel)
            }
            sectionLogRelays[channel] = relay
            return relay.sink
        }
        if let relay = logRelays[keyPath] { return relay.sink }
        let relay = LogRelay { [weak self] lines in
            self?.appendLog(keyPath, lines)
        }
        logRelays[keyPath] = relay
        return relay.sink
    }

    /// Instagram sync/import lines go through `handleIGLog` (progress
    /// markers drive the status bar), batched and ordered like other logs.
    @ObservationIgnored private var igLogRelays: [String: LogRelay] = [:]

    func igLogSink(importScale: Double? = nil, channel: String = "instagram") -> @Sendable (String) -> Void {
        let key = channel + (importScale.map { "\($0)" } ?? "plain")
        if let relay = igLogRelays[key] { return relay.sink }
        let relay = LogRelay { [weak self] lines in
            guard let self else { return }
            var plain: [String] = []
            for line in lines {
                if line.hasPrefix("IGPROGRESS:") {
                    if !plain.isEmpty { self.appendLog(\.igLog, plain, channel: channel); plain = [] }
                    self.handleIGLog(line, importScale: importScale)
                } else {
                    plain.append(line)
                }
            }
            if !plain.isEmpty { self.appendLog(\.igLog, plain, channel: channel) }
        }
        igLogRelays[key] = relay
        return relay.sink
    }

    /// Append lines to a log in one write, trimming to the cap.
    func appendLog(_ keyPath: ReferenceWritableKeyPath<AppStore, [String]>, _ lines: [String], channel section: String? = nil) {
        let lines = lines.compactMap { LogRelay.displayText($0) }
        guard !lines.isEmpty else { return }
        if let channel = BugReporting.logChannel(for: keyPath) {
            for line in lines {
                recordUnifiedLog(channel: section ?? channel, text: line)
                diagnosticLogSink(channel, line)
            }
        }
        if diagnosticsFFmpegVersion == nil {
            for line in lines where line.contains("ffmpeg version ") {
                if let version = line.split(whereSeparator: \.isNewline)
                    .first(where: { $0.hasPrefix("ffmpeg version ") }) {
                    diagnosticsFFmpegVersion = String(version)
                    break
                }
            }
        }
        var log = self[keyPath: keyPath]
        log.append(contentsOf: lines)
        if log.count > Self.logLineCap {
            log.removeFirst(log.count - Self.logLineCap)
        }
        self[keyPath: keyPath] = log
    }

    // MARK: - Data refresh

    /// Coalesced: a refresh already in flight absorbs later requests and
    /// runs once more at the end, so a burst of calls costs two snapshots
    /// at most instead of one per call.
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var refreshQueued = false

    /// Transcript rows per video for scene blurbs; dropped on every refresh.
    private var blurbTranscripts: [Int64: [TranscriptRow]] = [:]

    /// What a scene is about: its narrative, else the first words of its
    /// transcript, else nothing.
    func sceneBlurb(_ scene: SceneRecord) async -> SceneBlurb? {
        if let narrative = scene.narrative, !narrative.trimmingCharacters(in: .whitespaces).isEmpty {
            return SceneBlurb.fromNarrative(narrative)
        }
        return SceneBlurb.fromTranscript(await transcriptRows(videoID: scene.videoID),
                                         start: scene.startTime, end: scene.endTime)
    }

    private var blurbSpeakers: [Int64: (turns: [SpeakerTurn], roster: [VideoPersonRecord])] = [:]
    /// The speaker turns a video had before its last Map Speakers Again,
    /// for showing what the map changed and for putting it back.
    var previousSpeakerMaps: [Int64: [SpeakerTurn]] = [:]
    /// One merge can be undone until another merge or a profile switch.
    var previousPeopleMerge: PeopleMergeSnapshot?
    /// Person avatars keep their crops in view state; bump only affected identities.
    var personPortraitVersions: [Int64: Int] = [:]

    func invalidatePersonReferences(videoID: Int64) {
        blurbTranscripts[videoID] = nil
        blurbSpeakers[videoID] = nil
        previousSpeakerMaps[videoID] = nil
        // A roster's identities can change without changing its count.
        videoPeopleVersion &+= 1
    }

    /// A video's speaker turns and roster, cached until the next refresh.
    func speakerTurns(videoID: Int64) async -> (turns: [SpeakerTurn], roster: [VideoPersonRecord]) {
        if let cached = blurbSpeakers[videoID] { return cached }
        guard let database else { return ([], []) }
        let turns = (try? await database.fetchSpeakerTurns(videoID: videoID)) ?? []
        let roster = (try? await database.fetchVideoPeople(videoID: videoID)) ?? []
        blurbSpeakers[videoID] = (turns, roster)
        return (turns, roster)
    }

    /// Set who says these transcript lines; the cached rows of the video
    /// are dropped so the player sheet and blurbs pick the change up.
    func setTranscriptSpeaker(rowIDs: [Int64], videoID: Int64,
                              speaker: TranscriptRow.SpeakerAttribution) async {
        guard let database else { return }
        do {
            try await database.setTranscriptSpeaker(ids: rowIDs, speaker: speaker)
            blurbTranscripts[videoID] = nil
        } catch {
            presentError("Could not change who says these lines", error)
        }
    }

    /// Re-cut a video's transcript so every row belongs to one speaker, from
    /// its stored speaker turns. Returns how many rows were split; nil when
    /// the video has no turns or the write failed.
    func recutTranscriptBySpeaker(videoID: Int64) async -> Int? {
        guard let database else { return nil }
        do {
            let turns = try await database.fetchSpeakerTurns(videoID: videoID)
            guard !turns.isEmpty else { return nil }
            // The transcriber's rows when nothing was corrected since the
            // last re-cut (so re-cuts never compound), else the current rows.
            let rows = try await database.transcriptRecutBase(videoID: videoID)
            let plan = TranscriptSpeakerRecut.plan(rows: rows, turns: turns)
            if plan.hasChanges {
                try await database.recutTranscript(videoID: videoID, pieces: plan.pieces)
            }
            blurbTranscripts[videoID] = nil
            return plan.splitRows
        } catch {
            presentError("Could not re-cut the transcript", error)
            return nil
        }
    }

    /// Run a talking video's speaker map again — the lines attributed by
    /// hand teach the tracker their voices — and re-cut the rows by the
    /// new turns. No model call; failures belong to the owning job.
    func mapSpeakersAgain(video: VideoRecord, status: (@Sendable (String) -> Void)? = nil) async throws -> Bool {
        try video.requirePresent()
        guard let database else { throw AIError.notConfigured("No profile is open.") }
        let generation = profileGeneration
        appendLog(\.analysisLog, ["\(video.filename): mapping speakers again"])
        let sink = logSink(\.analysisLog)
        let log: @Sendable (String) -> Void = { line in sink(line); status?(line) }
        let holdSeconds = editingDefaults.podcast.speakerHoldSeconds
        let before = try await database.fetchSpeakerTurns(videoID: video.id)
        try await PodcastAnalysisService.mapSpeakers(video: video, database: database,
                                                     holdSeconds: holdSeconds,
                                                     log: log)
        try Task.checkCancellation()
        guard generation == profileGeneration else { throw CancellationError() }
        if !before.isEmpty { previousSpeakerMaps[video.id] = before }
        blurbSpeakers[video.id] = nil
        blurbTranscripts[video.id] = nil
        return true
    }

    /// Put the speaker map from before the last Map Speakers Again back,
    /// and re-cut the rows to it.
    func undoSpeakerMap(video: VideoRecord) async -> Bool {
        guard let database, let before = previousSpeakerMaps[video.id] else { return false }
        do {
            try await database.replaceSpeakerTurns(videoID: video.id, turns: before)
            await PodcastAnalysisService.recutTranscriptBySpeaker(video: video, database: database, turns: before,
                                                                  log: logSink(\.analysisLog))
            appendLog(\.analysisLog, ["\(video.filename): previous speaker map restored (\(before.count) turns)"])
            previousSpeakerMaps[video.id] = nil
            blurbSpeakers[video.id] = nil
            blurbTranscripts[video.id] = nil
            return true
        } catch {
            presentError("Could not restore the previous speaker map", error)
            return false
        }
    }

    /// Put the transcriber's own rows back after a re-cut.
    func undoTranscriptRecut(videoID: Int64) async -> Bool {
        guard let database else { return false }
        do {
            let restored = try await database.restoreTranscriptBackup(videoID: videoID)
            if restored { blurbTranscripts[videoID] = nil }
            return restored
        } catch {
            presentError("Could not restore the transcript", error)
            return false
        }
    }

    func hasTranscriptRecut(videoID: Int64) async -> Bool {
        guard let database else { return false }
        return (try? await database.hasTranscriptBackup(videoID: videoID)) ?? false
    }

    /// A video's transcript rows, cached until the next refresh.
    func transcriptRows(videoID: Int64) async -> [TranscriptRow] {
        if let cached = blurbTranscripts[videoID] { return cached }
        guard let database else { return [] }
        let rows = (try? await database.fetchTranscripts(videoID: videoID)) ?? []
        blurbTranscripts[videoID] = rows
        return rows
    }

    func refreshAll() {
        blurbTranscripts = [:]
        blurbSpeakers = [:]
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        Task {
            repeat {
                refreshQueued = false
                await refreshAllNow()
            } while refreshQueued
            refreshInFlight = false
        }
    }

    /// Awaitable refresh for callers that need the fresh lists (e.g. the
    /// wizard's post-run variation-batch detection).
    func refreshAllNow() async {
        refreshBumpers()
        guard let database, let activeProjectID else { return }
        let generation = profileGeneration
        await googleDrive.attach(profile: activeProfile, database: database)
        do {
            let snapshot = try await database.fetchLibrarySnapshot(projectID: activeProjectID)
            applyLibrarySnapshot(snapshot, generation: generation)
            timelines = (try? await database.fetchTimelines(projectID: activeProjectID)) ?? timelines
            projects = (try? await database.fetchProjects()) ?? projects
        } catch {
            presentError("Could not load the library", error)
        }
    }

    /// Write a fetched snapshot into the published lists — unless the
    /// profile changed while the fetch was in flight, in which case the
    /// rows belong to the old profile and are dropped.
    func applyLibrarySnapshot(_ snapshot: LibrarySnapshot, generation: Int) {
        let timing = PerfSignpost.begin("SnapshotApply", metadata: "scenes=\(snapshot.scenes.count)")
        defer { PerfSignpost.end(timing) }
        guard generation == profileGeneration else { return }
        // Observation doesn't compare values: assigning an identical
        // array still invalidates every view reading it, so only the
        // lists that actually changed are written back.
        let research = Dictionary(uniqueKeysWithValues: snapshot.fightResearch.map { ($0.videoID, $0) })
        let events = Dictionary(grouping: snapshot.fightEvents, by: \.videoID)
        if fightResearch != research { fightResearch = research }
        if fightEvents != events { fightEvents = events }
        if videos != snapshot.videos { videos = snapshot.videos }
        if scenes != snapshot.scenes { scenes = snapshot.scenes }
        // Published Library lists can refresh while an open script retains its
        // fixed document baseline. Only the latest ordinary hydration is queued.
        let paths = Set(snapshot.videos.filter { $0.driveFileID != nil }.compactMap(\.path))
        builderLibraryHydration.refresh { [weak self] in
            guard let self, generation == self.profileGeneration else { return }
            if self.builder.driveBackedPaths != paths { self.builder.updateDriveBackedPaths(paths) }
            if self.builder.scenes != snapshot.scenes { self.builder.updateScenes(snapshot.scenes) }
        }
        if analysisRuns != snapshot.analysisRuns { analysisRuns = snapshot.analysisRuns }
        if transcriptCounts != snapshot.transcriptCounts { transcriptCounts = snapshot.transcriptCounts }
        if videoPeopleCounts != snapshot.videoPeopleCounts { videoPeopleCounts = snapshot.videoPeopleCounts }
        if analysisCheckpoints != snapshot.analysisCheckpoints { analysisCheckpoints = snapshot.analysisCheckpoints }
        if people != snapshot.people { people = snapshot.people }
        if generatedVideos != snapshot.generatedVideos { generatedVideos = snapshot.generatedVideos }
        if feedback != snapshot.feedback { feedback = snapshot.feedback }
        if lessons != snapshot.lessons { lessons = snapshot.lessons }
    }

    /// Re-read one scene row and swap it into the in-memory list — the
    /// single-row counterpart to `refreshAll` for edits that only touch one
    /// scene (curation, trims, camera paths).
    func replaceScene(id: Int64) async {
        guard let database else { return }
        guard let fresh = try? await database.fetchScene(id: id) else {
            refreshAll()
            return
        }
        guard let index = scenes.firstIndex(where: { $0.id == id }) else {
            refreshAll()
            return
        }
        if scenes[index] != fresh {
            scenes[index] = fresh
            builder.updateScene(fresh)
        }
    }

    /// Register any new files dropped into the profile's Input folder.
    func scanSourceFolder() {
        guard let database else { return }
        let profile = activeProfile
        let analyzer = analyzer
        let generation = profileGeneration
        Task {
            do {
                let scan = try await analyzer.scanSourceFolder(profile: profile, database: database)
                if scan.discovered > 0 {
                    appendLog(\.analysisLog, ["Discovered \(scan.discovered) new video(s)"])
                }
                if scan.repaired > 0 {
                    appendLog(\.analysisLog, ["Removed \(scan.repaired) duplicate registration(s) of files that were still copying"])
                }
                refreshAll()
                // Files still arriving are registered once they stop changing;
                // the folder watcher only sees the directory, not their growth.
                if scan.settling > 0 { scheduleSettledRescan(generation: generation) }
            } catch {
                presentError("Folder scan failed", error)
            }
        }
    }

    private var settledRescan: Task<Void, Never>?

    private func scheduleSettledRescan(generation: Int) {
        settledRescan?.cancel()
        settledRescan = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, generation == profileGeneration else { return }
            scanSourceFolder()
        }
    }

    /// Copy videos dragged into the app into the profile's Input folder,
    /// then scan so they appear immediately (the folder watcher would also
    /// catch them, but only after its debounce).
    func importVideos(_ urls: [URL]) {
        let videos = urls.filter { Analyzer.videoExtensions.contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else { return }
        let folder = activeProfile.sourceFolderURL.standardizedFileURL
        Task.detached {
            var copied = 0
            var alreadyThere: [String] = []
            var failures: [String] = []
            for url in videos {
                do {
                    if try Self.copyDestination(for: url, folder: folder).existed {
                        alreadyThere.append(url.lastPathComponent)
                    } else {
                        copied += 1
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.userMessage)")
                }
            }
            await MainActor.run { [copied, alreadyThere, failures] in
                if copied > 0 {
                    self.appendLog(\.analysisLog, ["Added \(copied) video(s) to the Input folder"])
                    self.scanSourceFolder()
                }
                // Adding what is already here must say so, not do nothing.
                if !alreadyThere.isEmpty {
                    self.presentNotice(alreadyThere.count == 1 ? "Already in Sources" : "Already in Sources (\(alreadyThere.count))",
                                       "\(Self.nameList(alreadyThere)) \(alreadyThere.count == 1 ? "is" : "are") already in the Input folder"
                                       + (copied > 0 ? "; the other \(copied) \(copied == 1 ? "was" : "were") added." : ". Nothing was added."))
                }
                for failure in failures {
                    self.presentError("Could not add \(failure)")
                }
            }
        }
    }

    /// Add dropped/imported files directly to a project. The profile folder
    /// remains the source of truth; after discovery, membership is attached
    /// through the join table so the same file can be reused elsewhere.
    func importVideos(_ urls: [URL], toProjectID projectID: Int64) {
        let inputs = urls.filter { Analyzer.videoExtensions.contains($0.pathExtension.lowercased()) }
        guard !inputs.isEmpty, let database else { return }
        let folder = activeProfile.sourceFolderURL.standardizedFileURL
        let profile = activeProfile
        let analyzer = analyzer
        Task {
            let copyResult = await Task.detached(priority: .utility) {
                var paths: [String] = []
                var failures: [String] = []
                for url in inputs {
                    do {
                        let destination = try Self.copyDestination(for: url, folder: folder)
                        paths.append(destination.url.path)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.userMessage)")
                    }
                }
                return (paths, failures)
            }.value
            do {
                _ = try await analyzer.scanSourceFolder(profile: profile, database: database)
                let normalized = Set(copyResult.0.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
                let matches = try await database.fetchVideos().filter {
                    normalized.contains($0.url.standardizedFileURL.path)
                }
                // Files the project already holds are reported, not re-added.
                let inProject = Set(try await database.fetchVideos(projectID: projectID).map(\.id))
                let duplicates = matches.filter { inProject.contains($0.id) }
                let additions = matches.filter { !inProject.contains($0.id) }
                try await database.assignVideos(additions.map(\.id), to: projectID)
                refreshProjectCatalog()
                if activeProjectID == projectID { refreshAll() }
                if !duplicates.isEmpty {
                    let names = duplicates.map(\.filename)
                    presentNotice(names.count == 1 ? "Already in This Project" : "Already in This Project (\(names.count))",
                                  "\(Self.nameList(names)) \(names.count == 1 ? "is" : "are") already in the project"
                                  + (additions.isEmpty ? ". Nothing was added." : "; the other \(additions.count) \(additions.count == 1 ? "was" : "were") added."))
                }
            } catch {
                presentError("Could not add files to the project", error)
            }
            for failure in copyResult.1 { presentError("Could not add \(failure)") }
        }
    }

    /// Collision handling: a file already inside the folder, or an existing
    /// file with the same name and size, is already imported (`existed`);
    /// otherwise the file is copied, under a numbered name on a name clash.
    nonisolated static func copyDestination(for url: URL, folder: URL) throws -> (url: URL, existed: Bool) {
        let fm = FileManager.default
        if url.deletingLastPathComponent().standardizedFileURL == folder {
            return (url.standardizedFileURL, true)
        }
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            let sourceSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let existingSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if sourceSize == existingSize { return (destination.standardizedFileURL, true) }
            let base = url.deletingPathExtension().lastPathComponent
            var counter = 2
            repeat {
                destination = folder.appendingPathComponent("\(base) \(counter).\(url.pathExtension)")
                counter += 1
            } while fm.fileExists(atPath: destination.path)
        }
        try fm.copyItem(at: url, to: destination)
        return (destination.standardizedFileURL, false)
    }

    // MARK: - Model discovery

    /// Bumped when the discovered model lists change, so Settings re-reads them.
    var modelCatalogVersion = 0
    private(set) var refreshingModels = false

    /// Ask the installed CLIs again which models they offer.
    func refreshDiscoveredModels() {
        guard !refreshingModels else { return }
        refreshingModels = true
        let configured = settings.ai.providers["antigravity"]?.bin
        let binary = configured.flatMap { $0.isEmpty ? nil : $0 } ?? "agy"
        Task {
            defer { refreshingModels = false }
            let found = await ModelDiscovery.refresh(antigravityBinary: binary)
            AICatalog.applyDiscovered(found)
            modelCatalogVersion &+= 1
        }
    }

    // MARK: - Updates

    /// One silent check per app run, from the main window's `.task`.
    func checkForUpdatesAtLaunch() {
        guard !hasCheckedForUpdatesAtLaunch else { return }
        hasCheckedForUpdatesAtLaunch = true
        checkForUpdates(userInitiated: false)
    }

    /// Look for a newer release. A launch check fails and passes silently;
    /// a manual one (the Check for Updates… menu item) always answers.
    func checkForUpdates(userInitiated: Bool = true) {
        Task {
            do {
                if let update = try await UpdateService.checkForUpdate() {
                    updateCheckResult = .updateAvailable(update)
                } else if userInitiated {
                    updateCheckResult = .upToDate
                }
            } catch {
                if userInitiated {
                    presentError("Update check failed", error)
                }
            }
        }
    }

    /// Download the update's pkg and hand it to Installer.app, then quit so
    /// the installer can replace the app cleanly. The quit waits for
    /// Installer to be running; if it never launches, the app stays open,
    /// reveals the pkg in Finder, and explains what went wrong.
    ///
    /// The flush happens here, before `terminate`, rather than through the
    /// delegate's `.terminateLater` path: that path spins a nested run loop
    /// inside `terminate`, and because this call site is itself a main-queue
    /// (Task) callout, the nested loop can never drain the main-actor flush
    /// task that would reply to it. The app then sits forever behind the
    /// "Downloading update…" overlay with Installer already open.
    func installUpdate(_ update: AppUpdate) {
        guard !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        Task {
            var pkg: URL?
            do {
                let downloaded = try await UpdateService.downloadInstaller(update)
                pkg = downloaded
                try await UpdateService.launchInstaller(at: downloaded)
                await flushForTermination()
                hasFlushedForTermination = true
                NSApp.terminate(nil)
            } catch {
                if let pkg {
                    NSWorkspace.shared.activateFileViewerSelecting([pkg])
                    presentError("Could not open the installer — double-click \(pkg.lastPathComponent) in Finder to update", error)
                } else {
                    presentError("Could not download the update", error)
                }
            }
            isDownloadingUpdate = false
        }
    }

    // MARK: - Required tools

    /// One check per app run: everything downstream of import (probing,
    /// frame extraction, rendering, reel downloads) needs the command-line
    /// tools, so a missing install is fixed automatically instead of
    /// surfacing as cryptic per-feature failures.
    func ensureToolsAtLaunch() {
        guard !hasCheckedToolsAtLaunch else { return }
        hasCheckedToolsAtLaunch = true
        Task {
            // locate() can fall through to a login-shell lookup — off main.
            let missing = await Task.detached { ToolInstaller.missingTools }.value
            if !missing.isEmpty { installMissingTools() }
        }
    }

    /// Install whichever required tools are missing (Homebrew when available,
    /// otherwise standalone builds), then rescan so files whose probe failed
    /// get real metadata.
    func installMissingTools() {
        guard !isInstallingTools else { return }
        isInstallingTools = true
        Task {
            let missing = await Task.detached { ToolInstaller.missingTools }.value
            guard !missing.isEmpty else {
                isInstallingTools = false
                return
            }
            appendLog(\.analysisLog, ["\(missing.joined(separator: ", ")) not installed — installing now..."])
            do {
                try await ToolInstaller.installMissing(log: logSink(\.analysisLog))
                appendLog(\.analysisLog, ["All required tools are ready."])
                scanSourceFolder()
            } catch {
                presentError("Could not install required tools", error)
            }
            isInstallingTools = false
        }
    }

    /// Optional AI CLIs (qwen, kimi) — never installed automatically; only
    /// when the user clicks Install on the provider in Settings → AI.
    func installProviderCLI(_ key: String) {
        guard !installingProviderCLIs.contains(key) else { return }
        installingProviderCLIs.insert(key)
        let label = AICatalog.provider(key)?.label ?? key
        appendLog(\.analysisLog, ["Installing \(label)..."])
        Task {
            do {
                try await ProviderCLIInstaller.install(key, log: logSink(\.analysisLog))
            } catch {
                presentError("Could not install \(label)", error)
            }
            installingProviderCLIs.remove(key)
        }
    }

    // MARK: - Taste profile

    /// Study an Instagram reel as a taste exemplar (routes through the
    /// batch learner so single and multi selections behave identically).
    func studyTasteExemplar(media: IGMediaRecord, provider: String? = nil, model: String? = nil) {
        learnFromReels([media], provider: provider, model: model)
    }

    /// Which category a reel's taste study landed in, if it was studied.
    func tasteStudyCategory(mediaID: Int64) async -> String? {
        guard let database else { return nil }
        return ((try? await database.tasteStudies()) ?? [:])[mediaID]
    }

    /// Batch-learn from reels: each is downloaded if needed, classified
    /// into a video-type category (with its engagement stats as weighting
    /// context), and merged into that category's rubric and exemplars.
    /// Sequential; a failed reel is skipped, not fatal.
    func learnFromReels(_ media: [IGMediaRecord], provider: String? = nil, model: String? = nil) {
        guard let database, !isStudyingTaste, !media.isEmpty else { return }
        isStudyingTaste = true
        let settings = settings.instagram
        let instagram = instagram
        Task {
            defer { isStudyingTaste = false }
            for (index, item) in media.enumerated() {
                guard let account = igAccounts.first(where: { $0.id == item.accountID }) else { continue }
                if media.count > 1 {
                    appendLog(\.igLog, ["Learning from reel \(index + 1)/\(media.count)…"])
                }
                do {
                    let video = try await instagram.ensureDownloaded(
                        media: item, account: account,
                        database: database, settings: settings, log: logSink(\.igLog))
                    let label = try await runTasteStudy(
                        video: video, label: "@\(account.username) reel",
                        performance: Self.performanceLine(item),
                        mediaID: item.id,
                        provider: provider, model: model, log: logSink(\.igLog))
                    appendLog(\.igLog, ["Learned into “\(label)”"])
                } catch {
                    appendLog(\.igLog, ["Skipped a reel — \(error.userMessage)"])
                }
            }
            try? await reloadIGMedia()
            appendLog(\.igLog, ["Taste learning finished — review the video types in Settings → Profile"])
        }
    }

    /// Study a local sample video (Settings → Profile) the same way.
    func studyTasteExemplar(url: URL) {
        guard !isStudyingTaste else { return }
        isStudyingTaste = true
        Task {
            defer { isStudyingTaste = false }
            do {
                _ = try await runTasteStudy(video: url, label: url.lastPathComponent,
                                            performance: "", mediaID: nil, log: logSink(\.analysisLog))
            } catch {
                presentError("Could not study the sample video", error)
            }
        }
    }

    /// Media ids that already taught the taste profile — for the grid badge.
    func tasteStudiedMediaIDs() async -> Set<Int64> {
        guard let database else { return [] }
        return Set(((try? await database.tasteStudies()) ?? [:]).keys)
    }

    /// "1.2M views, 40K likes" — engagement context the study weights by.
    private static func performanceLine(_ media: IGMediaRecord) -> String {
        ReelPerformance.label(media.stats, duration: media.duration)
    }

    /// One study: classify → distill → merge into the category. Returns the
    /// category label for logging.
    @discardableResult
    private func runTasteStudy(video url: URL, label: String, performance: String,
                               mediaID: Int64?,
                               provider: String? = nil, model: String? = nil,
                               log: @escaping @Sendable (String) -> Void) async throws -> String {
        let profile = activeProfile
        let result = try await analyzer.distillTasteRubric(
            video: url, label: label,
            existingRubric: profile.tasteRubric,
            categories: profile.tasteCategories,
            performance: performance,
            domain: profile.effectiveDomain,
            provider: provider, model: model, log: log)
        applyTasteStudy(result, from: profile)
        if let mediaID, let database {
            try? await database.recordTasteStudy(mediaID: mediaID,
                                                 categoryKey: result.categoryKey)
        }
        return result.categoryLabel
    }

    /// The study runs against a snapshot — only apply its result if the
    /// user hasn't switched profiles meanwhile. Learnings land on the
    /// classified category; each category keeps its newest 8 exemplar
    /// frames so prompts stay lean.
    private func applyTasteStudy(_ result: (categoryKey: String, categoryLabel: String,
                                            rubric: String,
                                            exemplarFrames: [(time: Double, jpeg: Data)]),
                                 from profile: BrandProfile) {
        guard activeProfile.profileName == profile.profileName else { return }
        var category = activeProfile.tasteCategories.first { $0.key == result.categoryKey }
            ?? TasteCategory(key: result.categoryKey, label: result.categoryLabel)
        category.rubric = result.rubric
        category.studiedCount += 1
        if !result.exemplarFrames.isEmpty {
            let directory = SettingsStore.tasteFramesDirectory(profileName: profile.profileName)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970)
            for (index, frame) in result.exemplarFrames.enumerated() {
                let url = directory
                    .appendingPathComponent("exemplar-\(result.categoryKey)-\(stamp)-\(index).jpg")
                guard (try? frame.jpeg.write(to: url)) != nil else { continue }
                category.exemplarFrames.append(url.path)
            }
            while category.exemplarFrames.count > 8 {
                let oldest = category.exemplarFrames.removeFirst()
                try? FileManager.default.removeItem(atPath: oldest)
            }
        }
        if let index = activeProfile.tasteCategories.firstIndex(where: { $0.key == category.key }) {
            activeProfile.tasteCategories[index] = category
        } else {
            activeProfile.tasteCategories.append(category)
        }
        saveActiveProfile()
    }

    /// Delete a learned video type and its exemplar frame files.
    func removeTasteCategory(key: String) {
        guard let index = activeProfile.tasteCategories.firstIndex(where: { $0.key == key }) else { return }
        for path in activeProfile.tasteCategories[index].exemplarFrames {
            try? FileManager.default.removeItem(atPath: path)
        }
        activeProfile.tasteCategories.remove(at: index)
        saveActiveProfile()
    }

    /// Remove one exemplar frame (Settings → Profile → Taste).
    func removeTasteExemplarFrame(path: String) {
        activeProfile.tasteExemplarFrames.removeAll { $0 == path }
        try? FileManager.default.removeItem(atPath: path)
        saveActiveProfile()
    }

    /// Validate a Meta Graph API token, store it in the Keychain, and mark
    /// the discovered account as connected. Runs from Settings → Instagram.
    @discardableResult
    func connectInstagram(token: String, session: URLSession = .shared,
                          saveToken: @escaping (String, String) throws -> Void = { try KeychainStore.save($0, account: $1) },
                          now: Date = Date()) -> Task<Void, Never>? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isConnectingInstagram else { return nil }
        isConnectingInstagram = true
        let generation = profileGeneration
        let ownHandle = activeProfile.socials["instagram"]?.handle
            .trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\t")) ?? ""
        return Task {
            defer { isConnectingInstagram = false }
            do {
                var flavor = InstagramTokenFlavor.detect(trimmed)
                let accounts: [GraphAPIProvider.ResolvedAccount]
                do {
                    accounts = try await GraphAPIProvider(token: trimmed, igUserID: nil, session: session, flavor: flavor)
                        .resolveAccounts()
                } catch {
                    let detectedError = error
                    try Task.checkCancellation()
                    do {
                        accounts = try await GraphAPIProvider(token: trimmed, igUserID: nil, session: session, flavor: flavor.other)
                            .resolveAccounts()
                        flavor = flavor.other
                    } catch {
                        try Task.checkCancellation()
                        throw detectedError
                    }
                }
                try Task.checkCancellation()
                guard generation == profileGeneration else { return }
                let account = accounts.first { $0.username.caseInsensitiveCompare(ownHandle) == .orderedSame }
                    ?? accounts.first { candidate in
                        !settings.instagram.connections.contains { $0.igUserID == candidate.id }
                    } ?? accounts[0]
                try saveToken(trimmed, KeychainStore.graphTokenAccount(igUserID: account.id))
                // PLAN-VERIFY: dashboard-generated Instagram Login tokens initially last 60 days.
                let connection = InstagramConnection(
                    username: account.username, igUserID: account.id, tokenFlavor: flavor.rawValue,
                    tokenExpiresAt: flavor == .instagram ? now.addingTimeInterval(60 * 86400) : nil,
                    tokenRefreshedAt: flavor == .instagram ? now : nil)
                if let index = settings.instagram.connections.firstIndex(where: { $0.id == connection.id }) {
                    settings.instagram.connections[index] = connection
                } else {
                    settings.instagram.connections.append(connection)
                }
                saveSettings()
                // Make the connected account browsable right away.
                addInstagramAccount(handle: account.username)
            } catch {
                guard generation == profileGeneration else { return }
                presentError("Could not connect the Instagram account", error)
            }
        }
    }

    /// Commit on the main actor so reconnect/disconnect cannot interleave between
    /// the identity check, Keychain write and settings update.
    @discardableResult
    func applyInstagramTokenRefresh(_ refresh: InstagramTokenRefresh, connection original: InstagramConnection,
                                    replacing token: String,
                                    readToken: (String) -> String? = { KeychainStore.read(account: $0) },
                                    saveToken: (String, String) throws -> Void = { try KeychainStore.save($0, account: $1) }) throws -> Bool {
        let key = KeychainStore.graphTokenAccount(igUserID: original.igUserID)
        guard let index = settings.instagram.connections.firstIndex(where: { $0.id == original.id }),
              settings.instagram.connections[index].tokenFlavor == "instagram",
              settings.instagram.connections[index].tokenRefreshedAt == original.tokenRefreshedAt,
              readToken(key) == token else { return false }
        try saveToken(refresh.token, key)
        settings.instagram.connections[index].tokenRefreshedAt = refresh.refreshedAt
        settings.instagram.connections[index].tokenExpiresAt = refresh.expiresAt
        saveSettings()
        return true
    }

    /// Publish a Library video to the connected Instagram account as a Reel.
    /// Progress lines stream to `log`; throws with an actionable message on
    /// failure. On success the connected account refreshes so the new reel
    /// shows up in the Instagram tab.
    func publishReelToInstagram(video: GeneratedVideoRecord, caption: String,
                                shareToFeed: Bool, account: IGAccountRecord,
                                log: @escaping @Sendable (String) -> Void)
        async throws -> GraphAPIProvider.PublishedReel {
        if video.qualityReport?.verdict == .blocked {
            throw InstagramError.fetchFailed(
                "This reel failed the release-quality gate. Open it in Builder and render a corrected version before publishing.")
        }
        guard settings.instagram.connection(for: account.username) != nil else {
            throw InstagramError.fetchFailed("@\(account.username) is not connected")
        }
        guard igAccounts.contains(where: { $0.id == account.id && $0.username == account.username }) else {
            throw InstagramError.fetchFailed("Add @\(account.username) on the Instagram screen first")
        }
        let database = database
        let generation = profileGeneration
        let projectID = activeProjectID
        let sourceScenes = scenes
        let username = account.username
        let result = try await instagram.publishReel(file: video.url, caption: caption,
                                                     shareToFeed: shareToFeed,
                                                     account: username, settings: settings.instagram, log: log)
        if let database {
            try? await database.markGeneratedVideoPublished(id: video.id,
                                                            instagramMediaID: result.mediaID)
            let recordedTraits = (try? await database.fetchGeneratedTraits()) ?? [:]
            if recordedTraits[video.id] == nil,
               let data = video.timelineJSON.data(using: .utf8),
               let document = try? JSONDecoder().decode(TimelineDocument.self, from: data) {
                try? await database.saveGeneratedTraits(
                    videoID: video.id,
                    traits: .derive(document: document, scenes: sourceScenes)
                )
            }
            let refreshed = try? await database.fetchGeneratedVideos(projectID: projectID)
            if generation == profileGeneration, projectID == activeProjectID, let refreshed { generatedVideos = refreshed }
        }
        guard generation == profileGeneration else { return result }
        activeProfile.instagramPublishAccount = username
        saveActiveProfile()
        refreshInstagram(username: username)
        return result
    }

    func disconnectInstagram(_ connection: InstagramConnection,
                             deleteToken: (String) -> Void = { KeychainStore.delete(account: $0) }) {
        deleteToken(KeychainStore.graphTokenAccount(igUserID: connection.igUserID))
        settings.instagram.connections.removeAll { $0.id == connection.id }
        saveSettings()
    }

    func migrateInstagramConnection(
        readToken: (String) -> String? = { KeychainStore.read(account: $0) },
        saveToken: (String, String) throws -> Void = { try KeychainStore.save($0, account: $1) },
        deleteToken: (String) -> Void = { KeychainStore.delete(account: $0) }
    ) throws {
        guard settings.instagram.connections.isEmpty, !settings.instagram.connectedUsername.isEmpty else { return }
        let migrated = InstagramConnectionMigration.migrate(settings.instagram)
        if let connection = migrated.connections.first,
           let token = readToken(KeychainStore.graphTokenAccount) {
            try saveToken(token, KeychainStore.graphTokenAccount(igUserID: connection.igUserID))
            deleteToken(KeychainStore.graphTokenAccount)
        }
        settings.instagram = migrated
        saveSettings()
    }

    private func templateLabel(for media: IGMediaRecord) -> String {
        var label = igAccounts.first { $0.id == media.accountID }
            .map { "@\($0.username)" } ?? "reel"
        if let views = media.stats.views {
            label += " · \(views.compactFormatted) views"
        }
        return label
    }

    private func fetchTemplateJSON(mediaID: Int64) async -> String? {
        guard let database,
              let record = try? await database.fetchIGTemplate(mediaID: mediaID),
              !record.templateJSON.isEmpty else {
            presentError("No template found for this reel — analyze it first")
            return nil
        }
        return record.templateJSON
    }

    /// Hand an analyzed reel's template to the Wizard and switch sections.
    func useTemplateInWizard(media: IGMediaRecord) {
        Task {
            guard let templateJSON = await fetchTemplateJSON(mediaID: media.id) else { return }
            pendingWizardTemplate = WizardTemplateHandoff(templateJSON: templateJSON,
                                                          label: templateLabel(for: media),
                                                          thumbnailPath: media.thumbnailPath)
            requestedSection = .wizard
        }
    }

    /// Plan (not render) a timeline from an analyzed reel's template and open
    /// it in the Builder for manual editing.
    func useTemplateInBuilder(media: IGMediaRecord) {
        let originatingProjectID = activeProjectID
        Task {
            guard let templateJSON = await fetchTemplateJSON(mediaID: media.id) else { return }
            var options = WizardOptions()
            options.templateJSON = templateJSON
            options.templateLabel = templateLabel(for: media)
            options.projectID = originatingProjectID
            // Overlays land as editable timeline items here, not burned in.
            options.enableTextOverlays = true
            planIntoBuilder(options: options)
        }
    }

    /// The Builder pre-fill job: wizard planning only, then load the plan as
    /// a timeline document. Opens the Builder immediately; App Log shows progress.
    func planIntoBuilder(options: WizardOptions) {
        guard let database, !isWizardRunning else { return }
        var options = options.neutralized(for: ReelRecipe.recipe(id: options.formatPreset) ?? .custom)
        options.accountBenchmarks = igBenchmarks
        options.projectID = options.projectID ?? activeProjectID
        guard let projectID = options.projectID else { return }
        isWizardRunning = true
        wizardProjectName = projects.first(where: { $0.id == projectID })?.name ?? activeProject?.name
        wizardStatus = WizardRunStatus(stage: "Planning Builder timeline", fraction: 0.1)
        isPlanningIntoBuilder = true
        wizardLog = []
        selectedSection = .timelines
        let generation = profileGeneration
        let profile = activeProfile
        let wizard = wizard
        wizardTask = Task {
            await AIRunCapture.context.withValue(AIRunCapture()) {
            do {
                let (plan, sceneMap) = try await wizard.plan(options: options, profile: profile,
                                                             database: database, emit: logSink(\.wizardLog, channel: "builder-prefill"))
                guard self.database === database, generation == profileGeneration, !Task.isCancelled else {
                    throw CancellationError()
                }
                _ = try await wizard.prepareTagText(plan: plan, options: options, profile: profile,
                    sceneMap: sceneMap, database: database, emit: logSink(\.wizardLog, channel: "builder-prefill"))
                let document = try await WizardEngine.timelineDocument(from: plan, sceneMap: sceneMap,
                    options: options, database: database, profile: profile, log: logSink(\.wizardLog, channel: "builder-prefill"))
                if document.videoTrack.isEmpty {
                    presentError("The plan produced no usable clips")
                } else {
                    appendLog(\.wizardLog, ["Opening \(document.videoTrack.count) clips in the Builder..."], channel: "builder-prefill")
                    createTimeline(named: "Wizard Draft", document: document, projectID: projectID, isWizardPlan: true)
                }
            } catch is CancellationError {
                appendLog(\.wizardLog, ["Pre-fill cancelled"], channel: "builder-prefill")
            } catch {
                presentError("Timeline planning failed", error)
            }
            isWizardRunning = false
            wizardStatus = nil
            isPlanningIntoBuilder = false
        }
        }
    }
}

extension AppStore {
    /// Explicit diagnostic action. Ordinary operations never run both paths.
    func compareOnDeviceWithModel() async -> [OnDeviceAgreement.Report] {
        guard let database else { return [] }
        let profile = activeProfile
        let sourceScenes = scenes
        let log = logSink(\.pipelineLog)
        var reports: [OnDeviceAgreement.Report] = []
        let root = SettingsStore.cacheDirectory.appendingPathComponent("on-device-agreement")
        let metadata = (try? await database.fetchAssetMetadata(kind: "images")) ?? []
        let imageRows = metadata.map { LocalTextMatcher.Row(id: $0.path, fields: $0.subjects + $0.tags) }
        // A sample set, not the whole library: every case below costs one or
        // two model calls, several of them multimodal.
        let sample = OnDeviceAgreement.sampleLimit
        let sourceVideos = Array(videos.prefix(sample))
        let outputVideos = Array(generatedVideos.prefix(sample))
        let queries = Array(Array(Set(sourceScenes.flatMap(\.tags) + metadata.flatMap { $0.subjects + $0.tags })).filter { !$0.isEmpty }.sorted().prefix(sample))
        for item in OnDeviceAgreement.items {
            var report = OnDeviceAgreement.Report(item: item, cases: [])
            log("Comparing \(item)…")
            do {
                switch item {
                case "file-naming":
                    for video in sourceVideos {
                        let roster = try await database.fetchVideoPeople(videoID: video.id)
                        guard roster.contains(where: { !$0.name.isEmpty }) else { continue }
                        let local = try await OnDevicePolicy.comparison.withValue(true) {
                            try await self.suggestFileNames(for: [video], provider: nil, model: nil, log: log)
                        }
                        let model = try await OnDevicePolicy.comparison.withValue(false) {
                            try await self.suggestFileNames(for: [video], provider: nil, model: nil, log: log)
                        }
                        report.cases.append(.exactCase(id: String(video.id), local: local.map(\.suggestedName).joined(), model: model.map(\.suggestedName).joined()))
                    }
                case "scene-search":
                    for query in queries where !sourceScenes.isEmpty {
                        let local = try await OnDevicePolicy.comparison.withValue(true) { try await self.findScenes(matching: query, in: sourceScenes, provider: nil, model: nil, log: log) }
                        let model = try await OnDevicePolicy.comparison.withValue(false) { try await self.findScenes(matching: query, in: sourceScenes, provider: nil, model: nil, log: log) }
                        report.cases.append(.exactCase(id: query, local: local.value.sorted().description, model: model.value.sorted().description))
                    }
                case "image-search":
                    for query in Array(Set(metadata.flatMap { $0.subjects + $0.tags })).sorted().prefix(sample) {
                        let local = LocalImageMatcher.match(query: query, rows: imageRows)
                        guard !local.isEmpty else { continue }
                        let inventory = metadata.enumerated().map { "id \($0.offset): \($0.element.subjects + $0.element.tags)" }.joined(separator: "\n")
                        let response = try await ai.call(prompt: "Rank the owned images which match this request: \(query)\n\(inventory)\nReturn only JSON: {\"ids\":[0,1]}. Include only strong matches, best first. Never invent an id.", task: .search, timeout: 120, log: log)
                        let ids = AIResponseParser.jsonObject(from: response.text)?["ids"] as? [Int] ?? []
                        let paths = ids.compactMap { metadata.indices.contains($0) ? metadata[$0].path : nil }
                        report.cases.append(.exactCase(id: query, local: local.sorted().description, model: paths.sorted().description))
                    }
                case "wizard-request":
                    let templates = OverlayTemplateStore.list().map(\.name)
                    for query in queries {
                        let description = "30 seconds of \(query) with subtitles no music"
                        let local = WizardRequestParser.parse(description, tags: profile.effectiveTags.values.flatMap(\.self), templates: templates)
                        guard local.confident else { continue }
                        let model = try await wizard.parseRequest(description: description, profile: profile, emit: log, useLocal: false)
                        report.cases.append(.init(id: description, local: String(describing: local.request), model: String(describing: model), agrees: local.request == model))
                    }
                case "trim":
                    for video in sourceVideos where !video.filename.hasPrefix("Screen Recording") && !video.filename.hasPrefix("ScreenRecording") {
                        let local = try await analyzer.suggestTrim(video: video, log: log, useLocal: true)
                        guard local.provenance.provider == "local" else { continue }
                        let model = try await analyzer.suggestTrim(video: video, log: log, useLocal: false)
                        report.cases.append(.init(id: String(video.id), local: "\(local.start)-\(local.end)", model: "\(model.start)-\(model.end)", agrees: abs(local.start - model.start) <= 0.5 && abs(local.end - model.end) <= 0.5))
                    }
                case "duplicates":
                    if sourceVideos.count >= 2 {
                        let local = try await OnDevicePolicy.comparison.withValue(true) { try await self.findDuplicateVideos(provider: nil, model: nil, log: log) }
                        let model = try await OnDevicePolicy.comparison.withValue(false) { try await self.findDuplicateVideos(provider: nil, model: nil, log: log) }
                        let a = local.value.map { "\($0.videoIDs.sorted()):\($0.keepID)" }.sorted()
                        let b = model.value.map { "\($0.videoIDs.sorted()):\($0.keepID)" }.sorted()
                        report.cases.append(.exactCase(id: "library", local: a.description, model: b.description))
                    }
                case "cover-frames":
                    for video in outputVideos {
                        let local = try await OnDevicePolicy.comparison.withValue(true) { try await self.proposeCoverFrames(for: video, provider: nil, model: nil, log: log) }
                        let model = try await OnDevicePolicy.comparison.withValue(false) { try await self.proposeCoverFrames(for: video, provider: nil, model: nil, log: log) }
                        report.cases.append(.exactCase(id: String(video.id), local: local.value.map(\.time).sorted().description, model: model.value.map(\.time).sorted().description))
                    }
                case "long-recording":
                    for video in sourceVideos where video.duration >= 300 {
                        let times = (0..<5).map { (Double($0) + 0.5) * video.duration / 5 }
                        let data = await ThumbnailService.jpegFrames(url: video.url, at: times)
                        var signals: [VisionImageTagger.Signals] = []
                        for case let frame? in data {
                            if let signal = try? await VisionImageTagger.inspect(frame) { signals.append(signal) }
                        }
                        let cuts = try await FFmpeg.sceneChangeTimestamps(of: video.url)
                        let rows = try await database.fetchTranscripts(videoID: video.id)
                        let fraction = rows.isEmpty ? nil : rows.filter { !$0.isTranslation }.reduce(0) { $0 + $1.endTime - $1.startTime } / video.duration
                        guard let local = LongRecordingClassifier.classify(frames: signals, cutsPerMinute: Double(cuts.count) * 60 / video.duration, speechFraction: fraction) else { continue }
                        var unclassified = video
                        unclassified.videoType = nil
                        let model = try await analyzer.classifyLongRecording(video: unclassified, provider: nil, model: nil, log: log)
                        report.cases.append(.exactCase(id: String(video.id), local: local, model: model?.rawValue ?? ""))
                    }
                case "image-tagging":
                    for row in metadata.prefix(sample) {
                        guard let data = try? Data(contentsOf: URL(fileURLWithPath: row.path)),
                              let signals = try? await VisionImageTagger.inspect(data) else { continue }
                        let prompt = "Tag this owned library image for editorial search. Return only JSON: {\"subjects\":[\"person/event/topic\"],\"tags\":[\"crowd|walkout|training|establishing-shot|action|portrait|graphic|other\"],\"is_broll\":true|false}. B-roll means a cutaway, atmosphere, training, walkout, crowd, or establishing visual."
                        let model = try await ai.call(prompt: prompt, task: .analyze, frames: [.init(jpeg: data, label: row.path)], timeout: 120, log: log)
                        guard let tag = VisionImageTagger.localTag(signals) else { continue }
                        let object = AIResponseParser.jsonObject(from: model.text)
                        let agrees = object?["tags"] as? [String] == [tag] && (object?["subjects"] as? [String] ?? []).isEmpty && object?["is_broll"] as? Bool == true
                        report.cases.append(.init(id: row.path, local: tag, model: model.text, agrees: agrees))
                    }
                case "podcast-exchanges":
                    for video in sourceVideos where video.type?.usesPodcastPass == true {
                        let rows = try await database.fetchTranscripts(videoID: video.id).filter { !$0.isTranslation }
                        let segments = rows.map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: nil) }
                        let turns = try await database.fetchSpeakerTurns(videoID: video.id)
                        let service = PodcastExchangeSegmenter(ai: ai)
                        let local = try await service.segment(segments: segments, turns: turns, provider: nil, model: nil, log: log, useLocal: true)
                        let model = try await service.segment(segments: segments, turns: turns, provider: nil, model: nil, log: log, useLocal: false)
                        let a = local.exchanges.map { "\($0.start)-\($0.end)" }
                        let b = model.exchanges.map { "\($0.start)-\($0.end)" }
                        report.cases.append(.exactCase(id: String(video.id), local: a.description, model: b.description))
                    }
                case "fight-queries":
                    let records = try await database.fetchFightResearch()
                    let known = people.map(\.name) + records.flatMap { FightNameResolver.names($0.fightLabel) }
                    for row in records.prefix(sample) {
                        let identity = FightResearchService.Identity(fighters: row.fightLabel, event: row.event, date: row.fightDate)
                        let local = await fightResearchService.comparisonQueryPlan(identity: identity, profile: profile, records: records, known: known, useLocal: true, emit: log)
                        let model = await fightResearchService.comparisonQueryPlan(identity: identity, profile: profile, records: records, known: known, useLocal: false, emit: log)
                        report.cases.append(.exactCase(id: String(row.id), local: local, model: model))
                    }
                case "hashtags":
                    for video in outputVideos {
                        let tags = Array(Set(sourceScenes.flatMap(\.tags))).sorted()
                        let plan = WizardPlan(targetDuration: video.duration, rationale: video.rationale ?? "", musicName: nil, musicVolume: 0, clips: [], transitions: [], headline: nil, introTitle: nil, fileName: nil)
                        let localPrompt = await wizard.captionPrompt(profile: profile, plan: plan, duration: video.duration, tags: tags, localHashtags: true)
                        let modelPrompt = await wizard.captionPrompt(profile: profile, plan: plan, duration: video.duration, tags: tags)
                        let local = try await ai.call(prompt: localPrompt, task: .captions, timeout: 60, log: log)
                        let model = try await ai.call(prompt: modelPrompt, task: .captions, timeout: 60, log: log)
                        let a = local.text.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("#") }.map { $0.lowercased() }.sorted()
                        let b = model.text.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("#") }.map { $0.lowercased() }.sorted()
                        report.cases.append(.exactCase(id: String(video.id), local: a.description, model: b.description))
                    }
                case "translation-batch":
                    for video in sourceVideos {
                        let rows = Array(try await database.fetchTranscripts(videoID: video.id).filter { !$0.isTranslation }.prefix(sample))
                        guard !rows.isEmpty else { continue }
                        let texts = rows.map(\.text)
                        let batch = try await ai.call(prompt: TranslationBatch.prompt(texts: texts, language: "pt-BR"), task: .translate, timeout: 60, log: log)
                        let translated = TranslationBatch.parse(batch.text, count: rows.count)
                        for (index, row) in rows.enumerated() {
                            let model = try await ai.call(prompt: "Translate this caption to pt-BR. Preserve names and meaning. Return only the translation:\n\(row.text)", task: .translate, timeout: 60, log: log)
                            report.cases.append(.exactCase(id: String(row.id), local: translated[index] ?? "", model: model.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    }
                default:
                    report.errors.append("Unknown comparison item")
                }
            } catch {
                report.errors.append(error.localizedDescription)
            }
            do {
                try OnDeviceAgreement.save(report, root: root)
                // Only a measured item moves its switch; an item with no
                // comparable cases keeps whatever the user set by hand.
                if report.errors.isEmpty, let percentage = report.percentage {
                    settings.ai.onDeviceAgreement[item] = percentage
                    settings.ai.onDeviceOverrides[item] = report.passed
                } else {
                    settings.ai.onDeviceAgreement.removeValue(forKey: item)
                }
            } catch { report.errors.append("Could not save report: \(error.localizedDescription)") }
            reports.append(report)
        }
        return reports
    }
}
