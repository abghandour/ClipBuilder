import AppKit
import Foundation
import Observation

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

    var settings: AppSettings
    var profiles: [BrandProfile] = []
    var activeProfile: BrandProfile
    private(set) var database: Database?

    var videos: [VideoRecord] = []
    var scenes: [SceneRecord] = []
    var analysisRuns: [AnalysisRun] = []
    var people: [PersonRecord] = []
    /// Saved fight research by video id — the Analyze page's column and the
    /// wizards' story/caption injection read from here.
    var fightResearch: [Int64: FightResearchRecord] = [:]
    /// Videos whose fight research is being crawled right now.
    var fightResearchInFlight: Set<Int64> = []
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
    private var comparisonQueue: [ComparisonBatch] = []

    /// FIFO of pending alerts; the main window presents the first entry and
    /// dequeues on dismiss, so one failure can't silently replace another.
    private(set) var errorQueue: [AppError] = []
    var currentError: AppError? { errorQueue.first }

    /// Hand-off from the Scenes screen: open the Analyze tab with this video
    /// selected and the model-plan sheet prefilled from a past batch.
    var pendingAnalyzeSetup: VideoRecord?

    // Analysis job
    var isAnalyzing = false
    var analysisLog: [String] = []
    var analysisProgress: Double = 0
    var analysisStage = ""
    private var analysisTask: Task<Void, Never>?

    // Transcription job
    var transcribingVideoIDs: Set<Int64> = []
    private var transcriptionTasks: [Int64: Task<Void, Never>] = [:]

    // Wizard job
    var isWizardRunning = false
    /// True while a Builder pre-fill plan runs — drives the Builder's
    /// loading overlay.
    var isPlanningIntoBuilder = false
    var wizardLog: [String] = []
    /// Human-readable progress for the running generation, derived from the
    /// engine's log stream — so multi-minute AI calls don't look like a hang.
    var wizardStatus: WizardRunStatus?
    /// Videos produced by the finished run, presented as the results sheet.
    var wizardResults: WizardRunResults?
    /// Options of the last run — "Retry" in the results sheet re-runs them.
    private(set) var lastWizardOptions: WizardOptions?
    /// Why the last generation produced nothing — shown as a banner in the
    /// wizard's log panel with a Try Again, instead of only a red log line.
    var wizardFailureMessage: String?
    /// Presents the Training Guide sheet from the main window (Help menu).
    var showTrainingGuide = false
    var isDistillingLessons = false
    var isDistillingHouseStyle = false
    /// Result line of the last Wizard Brain export/import, for Settings.
    var wizardBrainStatus: String?
    private var wizardTask: Task<Void, Never>?

    // Clip Builder
    let builder = BuilderTimelineModel()
    var isBuilderRendering = false
    var builderLog: [String] = []
    private var builderRenderTask: Task<Void, Never>?

    // Instagram
    var igAccounts: [IGAccountRecord] = []
    var igSelectedAccountID: Int64?
    var igMedia: [IGMediaRecord] = []
    var isFetchingInstagram = false
    var igLog: [String] = []
    private var igFetchTask: Task<Void, Never>?
    /// Media rows with a cached template analysis (for the selected account).
    var igTemplatedMediaIDs: Set<Int64> = []
    var igAnalyzingMediaIDs: Set<Int64> = []
    var igDownloadingMediaIDs: Set<Int64> = []
    var isConnectingInstagram = false
    var isPublishingToInstagram = false
    /// A taste-exemplar study is running (one at a time).
    var isStudyingTaste = false
    private var igAnalyzeTasks: [Int64: Task<Void, Never>] = [:]
    /// Template picked in the Instagram tab, consumed by the Wizard's next
    /// run (or dismissed from its chip).
    var pendingWizardTemplate: WizardTemplateHandoff?
    /// "Generate Video" request from the Analyze/Scenes/People screens; the
    /// Wizard seeds its form from it and keeps it until the user dismisses
    /// its card.
    var pendingWizardPrompt: WizardPromptHandoff?
    /// Set by views (e.g. "Open in Builder") to ask the main window to switch
    /// sidebar sections; the window consumes and clears it.
    var requestedSection: SidebarSection?

    // Updates
    /// What an update check concluded; the main window presents it as one
    /// alert. `.upToDate` is only set for manual checks — the launch check
    /// stays silent unless there is something to install.
    var updateCheckResult: UpdateCheckResult?
    var isDownloadingUpdate = false
    private var hasCheckedForUpdatesAtLaunch = false

    // Required command-line tools (ffmpeg, ffprobe, yt-dlp)
    var isInstallingTools = false
    private var hasCheckedToolsAtLaunch = false
    /// Optional AI provider CLIs currently installing (keys: "qwen", "kimi").
    var installingProviderCLIs: Set<String> = []

    // MARK: - Services

    let ai: AIService
    let thumbnails = ThumbnailService()
    let renderEngine = RenderEngine()
    let transcription = TranscriptionService()
    private let analyzer: Analyzer
    private let wizard: WizardEngine
    private let multitrackRenderer: MultitrackRenderer
    private let instagram: InstagramService
    private let fightResearchService: FightResearchService
    private var watcher: FolderWatcher?

    init() {
        let settings = SettingsStore.loadSettings()
        self.settings = settings
        ai = AIService(config: settings.ai)
        analyzer = Analyzer(ai: ai)
        wizard = WizardEngine(ai: ai, render: renderEngine)
        multitrackRenderer = MultitrackRenderer(render: renderEngine)
        instagram = InstagramService(ai: ai)
        fightResearchService = FightResearchService(ai: ai)

        let defaultProfile = ProfileStore.ensureDefaultProfile()
        var loaded = ProfileStore.listProfiles()
        if loaded.isEmpty { loaded = [defaultProfile] }
        profiles = loaded
        let activeName = SettingsStore.loadActiveProfileName()
        activeProfile = loaded.first { $0.profileName == activeName } ?? loaded[0]

        watcher = FolderWatcher { [weak self] in
            self?.scanSourceFolder()
        }
        openActiveProfile()
    }

    // MARK: - Errors

    func presentError(_ message: String) {
        errorQueue.append(AppError(message: message))
    }

    /// Queue an alert for a failed operation; user-initiated cancellations
    /// are not errors and are dropped.
    func presentError(_ context: String, _ error: Error) {
        guard !(error is CancellationError) else { return }
        presentError("\(context): \(error.userMessage)")
    }

    func dismissCurrentError() {
        if !errorQueue.isEmpty { errorQueue.removeFirst() }
    }

    // MARK: - Profiles

    private func openActiveProfile() {
        ProfileStore.ensureFolders(for: activeProfile)
        do {
            database = try Database(path: SettingsStore.databaseURL(profileName: activeProfile.profileName))
        } catch {
            database = nil
            presentError("Could not open the profile database", error)
        }
        watcher?.watch(activeProfile.sourceFolderURL)
        builder.load(profileName: activeProfile.profileName)
        refreshAll()
        loadInstagramCache()
        scanSourceFolder()
    }

    func switchProfile(named name: String) {
        guard let profile = profiles.first(where: { $0.profileName == name }) else { return }
        activeProfile = profile
        SettingsStore.saveActiveProfileName(name)
        videos = []
        scenes = []
        people = []
        generatedVideos = []
        feedback = []
        lessons = []
        pendingComparison = nil
        comparisonQueue = []
        igAccounts = []
        igSelectedAccountID = nil
        igMedia = []
        igTemplatedMediaIDs = []
        pendingWizardTemplate = nil
        pendingWizardPrompt = nil
        wizardResults = nil
        openActiveProfile()
    }

    func saveActiveProfile() {
        do {
            try ProfileStore.save(activeProfile)
            if let index = profiles.firstIndex(where: { $0.profileName == activeProfile.profileName }) {
                profiles[index] = activeProfile
            }
            ProfileStore.ensureFolders(for: activeProfile)
            watcher?.watch(activeProfile.sourceFolderURL)
        } catch {
            presentError("Could not save the profile", error)
        }
    }

    func createProfile(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, ProfileStore.load(name: trimmed) == nil else { return }
        let profile = BrandProfile(name: trimmed)
        do {
            try ProfileStore.save(profile)
            profiles = ProfileStore.listProfiles()
            switchProfile(named: trimmed)
        } catch {
            presentError("Could not create the profile", error)
        }
    }

    func deleteProfile(named name: String) {
        guard name != "Default" else { return }
        try? ProfileStore.delete(name: name)
        try? FileManager.default.removeItem(at: SettingsStore.databaseURL(profileName: name))
        profiles = ProfileStore.listProfiles()
        if profiles.isEmpty {
            profiles = [ProfileStore.ensureDefaultProfile()]
        }
        if activeProfile.profileName == name {
            switchProfile(named: profiles[0].profileName)
        }
    }

    func saveSettings() {
        SettingsStore.save(settings)
        let config = settings.ai
        Task { await ai.updateConfig(config) }
    }

    /// Forget the smart dispatcher's remembered choices: recommended models
    /// apply again and the plan prompts return before Analyze and Generate.
    func resetDispatcher() {
        settings.ai.tasks = [:]
        settings.ai.taskModels = [:]
        settings.ai.mutedDispatchPlans = []
        saveSettings()
    }

    // MARK: - Data refresh

    func refreshAll() {
        Task { await refreshAllNow() }
    }

    /// Awaitable refresh for callers that need the fresh lists (e.g. the
    /// wizard's post-run variation-batch detection).
    func refreshAllNow() async {
        guard let database else { return }
        do {
            let videos = try await database.fetchVideos()
            let scenes = try await database.fetchScenes()
            let analysisRuns = try await database.fetchAnalysisRuns()
            let people = try await database.fetchPeople()
            let generated = try await database.fetchGeneratedVideos()
            let feedback = try await database.fetchAllFeedback()
            let lessons = try await database.fetchLessons()
            let research = (try? await database.fetchFightResearch()) ?? []
            self.fightResearch = Dictionary(uniqueKeysWithValues: research.map { ($0.videoID, $0) })
            let events = (try? await database.fetchFightEvents()) ?? []
            self.fightEvents = Dictionary(grouping: events, by: \.videoID)
            self.videos = videos
            self.scenes = scenes
            self.analysisRuns = analysisRuns
            self.people = people
            self.generatedVideos = generated
            self.feedback = feedback
            self.lessons = lessons
            self.builder.updateScenes(scenes)
        } catch {
            presentError("Could not load the library", error)
        }
    }

    /// Register any new files dropped into the profile's Input folder.
    func scanSourceFolder() {
        guard let database else { return }
        let profile = activeProfile
        let analyzer = analyzer
        Task {
            do {
                let discovered = try await analyzer.scanSourceFolder(profile: profile, database: database)
                if discovered > 0 {
                    analysisLog.append("Discovered \(discovered) new video(s)")
                }
                refreshAll()
            } catch {
                presentError("Folder scan failed", error)
            }
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
            var failures: [String] = []
            for url in videos where url.deletingLastPathComponent().standardizedFileURL != folder {
                do {
                    if try Self.copyIntoFolder(url, folder: folder) { copied += 1 }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.userMessage)")
                }
            }
            await MainActor.run { [copied, failures] in
                if copied > 0 {
                    self.analysisLog.append("Added \(copied) video(s) to the Input folder")
                    self.scanSourceFolder()
                }
                for failure in failures {
                    self.presentError("Could not add \(failure)")
                }
            }
        }
    }

    /// Collision handling: an existing file with the same name and size is
    /// treated as already imported; otherwise a numbered name is picked.
    nonisolated private static func copyIntoFolder(_ url: URL, folder: URL) throws -> Bool {
        let fm = FileManager.default
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            let sourceSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let existingSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if sourceSize == existingSize { return false }
            let base = url.deletingPathExtension().lastPathComponent
            var counter = 2
            repeat {
                destination = folder.appendingPathComponent("\(base) \(counter).\(url.pathExtension)")
                counter += 1
            } while fm.fileExists(atPath: destination.path)
        }
        try fm.copyItem(at: url, to: destination)
        return true
    }

    // MARK: - Analysis

    /// Batch name stamped at analysis time: "<video name without extension>
    /// MM/dd/yy", with a " v<n>" counter from the second batch of the same
    /// video on (the first stays unsuffixed).
    private static func analysisRunName(for video: VideoRecord, at date: Date = .now,
                                        existingBatchCount: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy"
        let base = (video.filename as NSString).deletingPathExtension
        var name = "\(base) \(formatter.string(from: date))"
        if existingBatchCount >= 1 { name += " v\(existingBatchCount + 1)" }
        return name
    }

    /// Every run is a full pass that lands in a new analyze batch alongside
    /// any earlier ones — delete unwanted batches from the Scenes screen.
    func analyze(videos targets: [VideoRecord], provider: String? = nil, model: String? = nil,
                 includeFightScoring: Bool = true) {
        guard let database, !isAnalyzing else { return }
        isAnalyzing = true
        analysisLog = []
        analysisProgress = 0
        let profile = activeProfile
        let analyzer = analyzer
        // Instructions and sampling density come from the dispatch plan
        // sheet (persisted, so muted runs keep the last-used values).
        let instructions = UserDefaults.standard.string(forKey: "analysis.instructions") ?? ""
        let storedInterval = UserDefaults.standard.double(forKey: "analysis.sampleInterval")
        // People attribution is mandatory: the people-detection pass gates
        // tagging, and every scene must carry whoever is in it.
        let detectPeople = true
        let autoZoomUnframed = UserDefaults.standard.bool(forKey: "analysis.autoZoomUnframed")
        let breakdownTags: [String] = UserDefaults.standard.bool(forKey: "analysis.autoBreakdown")
            ? (UserDefaults.standard.string(forKey: "analysis.breakdownTags") ?? "")
                .split(separator: ",").map(String.init)
            : []
        // Center Stage moved to curation: paths are computed per scene from
        // the Raw Scenes "Curate" modal, never during analysis.
        // One-shot trim from the plan sheet — consumed and cleared here so a
        // leftover range never silently applies to a later run.
        let trimStart = UserDefaults.standard.object(forKey: "analysis.trimStart") as? Double
        let trimEnd = UserDefaults.standard.object(forKey: "analysis.trimEnd") as? Double
        UserDefaults.standard.removeObject(forKey: "analysis.trimStart")
        UserDefaults.standard.removeObject(forKey: "analysis.trimEnd")
        let trimRange: (start: Double, end: Double)? = {
            guard targets.count == 1, let trimStart, let trimEnd, trimEnd > trimStart else { return nil }
            return (trimStart, trimEnd)
        }()
        // One-shot required-people filter from the plan sheet's roster.
        let requiredPeopleKeys = (UserDefaults.standard.string(forKey: "analysis.requiredPeople") ?? "")
            .split(separator: ",").map(String.init)
        UserDefaults.standard.removeObject(forKey: "analysis.requiredPeople")
        let sampleInterval: Double? = storedInterval > 0 ? storedInterval : nil
        let includeTranscript = UserDefaults.standard.bool(forKey: "analysis.includeTranscript")
        let transcription = transcription
        let language = settings.transcribeLanguage
        if !instructions.isEmpty { analysisLog.append("Using analysis instructions: \(instructions)") }
        analysisTask = Task {
            defer {
                isAnalyzing = false
                refreshAll()
            }
            // The roster's checked people become a hard filter: every kept
            // range must show ALL of them with most of their body visible.
            var instructions = instructions
            if !requiredPeopleKeys.isEmpty {
                let people = (try? await database.fetchPeople()) ?? []
                let names = requiredPeopleKeys.map { key in
                    people.first { $0.key == key }
                        .map { "\($0.displayName) (key \"\($0.key)\")" } ?? key
                }
                let filterLine = "HARD FILTER: Only include time ranges where ALL of these people are on screen AT THE SAME TIME, each with more than half of their body visible: "
                    + names.joined(separator: ", ")
                    + ". Omit every range where any of them is absent, mostly occluded, or barely in frame."
                instructions = instructions.isEmpty ? filterLine : filterLine + "\n" + instructions
                analysisLog.append("Requiring people in every scene: \(names.joined(separator: ", "))")
            }
            // People first seen anywhere in this batch — reviewed once at the
            // end. Later videos already treat them as known (people are
            // refetched per video), so keys never repeat across videos.
            var newPeople: [DetectedNewPerson] = []
            var renameSuggestions: [RenameSuggestion] = []
            for (index, video) in targets.enumerated() {
                if Task.isCancelled { break }
                let base = Double(index) / Double(targets.count)
                let span = 1.0 / Double(targets.count)
                do {
                    let notes = (try? await database.videoNotes(videoID: video.id)) ?? []
                    if !notes.isEmpty {
                        analysisLog.append("\(video.filename): applying \(notes.count) timestamped note(s)")
                    }
                    // Refetched per video so people discovered earlier in this
                    // batch keep their identity in the following videos.
                    let knownPeople = (try? await database.fetchPeople()) ?? []
                    let markers = (try? await database.personMarkers(videoID: video.id)) ?? []
                    // Counted from the DB right before the run, so mid-batch
                    // additions are seen and the v-counter never repeats.
                    let existingBatches = ((try? await database.fetchAnalysisRuns()) ?? [])
                        .count { $0.videoID == video.id }
                    let (runID, videoNewPeople, suggestedFilename) = try await analyzer.analyzeVisual(
                        video: video, profile: profile, database: database,
                        runName: Self.analysisRunName(for: video,
                                                      existingBatchCount: existingBatches)
                            + (trimRange.map { " (\($0.start.timecode)–\($0.end.timecode))" } ?? ""),
                        provider: provider, model: model,
                        instructions: instructions, notes: notes,
                        knownPeople: knownPeople,
                        personMarkers: markers,
                        detectPeople: detectPeople,
                        autoZoomUnframed: autoZoomUnframed,
                        breakdownTags: breakdownTags,
                        trimRange: trimRange,
                        sampleInterval: sampleInterval,
                        force: true,
                        log: { message in
                            Task { @MainActor in self.analysisLog.append(message) }
                        },
                        progress: { fraction, stage in
                            Task { @MainActor in
                                self.analysisProgress = base + span * fraction
                                self.analysisStage = stage
                            }
                        })
                    let pendingKeys = Set(newPeople.map(\.key))
                    newPeople.append(contentsOf: videoNewPeople.filter { !pendingKeys.contains($0.key) })
                    if let suggestedFilename {
                        renameSuggestions.append(RenameSuggestion(videoID: video.id,
                                                                  currentFilename: video.filename,
                                                                  suggestedName: suggestedFilename))
                    }
                    if includeTranscript {
                        // A transcript failure shouldn't undo a good analysis
                        // — log it and keep going.
                        do {
                            let existing = (try? await database.fetchTranscripts(videoID: video.id)) ?? []
                            if existing.isEmpty {
                                analysisStage = "transcribing"
                                _ = try await transcription.transcribe(
                                    video: video, database: database,
                                    languageCode: language,
                                    log: { message in
                                        Task { @MainActor in self.analysisLog.append(message) }
                                    })
                                analysisLog.append("\(video.filename): transcript saved")
                            } else {
                                analysisLog.append("\(video.filename): already has a transcript — keeping it")
                            }
                            if let runID {
                                try? await database.markAnalysisRunTranscribed(id: runID)
                            }
                        } catch is CancellationError {
                            break
                        } catch {
                            analysisLog.append("\(video.filename): transcription failed — \(error.userMessage)")
                        }
                    }
                    // Fight scoring: dense pass over the fight scenes so the
                    // pace/winning graphs light up right after analysis.
                    if includeFightScoring {
                        do {
                            analysisStage = "scoring fight action"
                            let allScenes = (try? await database.fetchScenes(includeExcluded: true)) ?? []
                            _ = try await analyzer.scoreFightAction(
                                video: video, scenes: allScenes.filter { $0.videoID == video.id },
                                profile: profile, database: database,
                                provider: provider, model: model,
                                log: { message in
                                    Task { @MainActor in self.analysisLog.append(message) }
                                })
                        } catch is CancellationError {
                            break
                        } catch {
                            analysisLog.append("\(video.filename): fight scoring failed — \(error.userMessage)")
                        }
                    }
                    analysisLog.append("\(video.filename): done")
                } catch is CancellationError {
                    break
                } catch let error as AIError {
                    analysisLog.append("\(video.filename): \(error)")
                    if case .quotaExhausted = error {
                        analysisLog.append("Quota exhausted — stopping the run.")
                        break
                    }
                } catch {
                    analysisLog.append("\(video.filename): \(error.userMessage)")
                }
            }
            if Task.isCancelled {
                analysisLog.append("Analysis stopped.")
                analysisStage = "stopped"
            } else {
                analysisProgress = 1
                analysisStage = "done"
            }
            if !newPeople.isEmpty {
                pendingPeopleReview = PeopleReviewRequest(people: newPeople)
            }
            // Presented via its own sheet — it waits behind the people
            // review when both exist.
            if !renameSuggestions.isEmpty {
                pendingRenameReview = RenameReviewRequest(suggestions: renameSuggestions)
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    // MARK: - Wizard Pipeline

    /// Fire-and-forget orchestration state — the bottom bar renders from
    /// these while the run works through its steps in the background.
    var isPipelineRunning = false
    var pipelineLog: [String] = []
    var pipelineProgress: Double = 0
    var pipelineStage = ""
    /// Opens the full pipeline log sheet (clicking the bottom bar).
    var showPipelineLog = false
    private var pipelineTask: Task<Void, Never>?
    // The run's plan + per-unit done marks ("people:12", "analysis:12",
    // "naming", …) so Resume re-enters exactly where the run stopped instead
    // of redoing (and re-billing) finished steps.
    private var pipelineTargets: [VideoRecord] = []
    private var pipelineOptions: PipelineOptions?
    private var pipelineDone: Set<String> = []
    private var pipelineRunIDs: [Int64: Int64] = [:]
    /// Reels rendered so far this run — the combined results sheet at the
    /// end covers pre-stop renders too.
    private var pipelineGenerated: [GeneratedVideoRecord] = []
    /// New-people review captured mid-run and re-queued when the run ends —
    /// the pipeline never prompts while it works.
    private var pipelineDeferredPeople: PeopleReviewRequest?

    /// A stopped run with remaining work — the bottom bar offers Resume.
    var canResumePipeline: Bool {
        !isPipelineRunning && pipelineStage == "stopped" && pipelineOptions != nil
    }

    /// One Wizard Pipeline run: every checked step for the selected videos,
    /// sequentially, while the app stays usable. People, transcription, and
    /// the analysis batch run as phases; research, curation, framing,
    /// generation, and covers follow per video; renames apply automatically
    /// at the end. Review prompts (new people) are deferred to the end — the
    /// run never stops to ask.
    func startPipeline(videos targets: [VideoRecord], options: PipelineOptions) {
        guard !isPipelineRunning, !targets.isEmpty else { return }
        guard !isAnalyzing, !isWizardRunning else {
            presentError("Another analysis or generation is already running — stop it or let it finish first.")
            return
        }
        pipelineTargets = targets
        pipelineOptions = options
        pipelineDone = []
        pipelineRunIDs = [:]
        pipelineGenerated = []
        pipelineDeferredPeople = nil
        pipelineLog = ["Wizard Pipeline: \(targets.count) video(s)"]
        runPipeline()
    }

    /// Pick a stopped run back up — finished steps are skipped via their
    /// done marks.
    func resumePipeline() {
        guard canResumePipeline else { return }
        guard !isAnalyzing, !isWizardRunning else {
            presentError("Another analysis or generation is already running — stop it or let it finish first.")
            return
        }
        pipelineLog.append("Resuming…")
        runPipeline()
    }

    private func runPipeline() {
        guard let database, let options = pipelineOptions else { return }
        let targets = pipelineTargets
        isPipelineRunning = true
        pipelineStage = "starting"

        // One progress unit per (step, video); naming runs once for all.
        var totalUnits = 0
        if options.detectPeople { totalUnits += targets.count }
        if options.transcribe { totalUnits += targets.count }
        if options.analyze || options.fightScoring { totalUnits += targets.count }
        if options.fightResearch { totalUnits += targets.count }
        if options.curate { totalUnits += targets.count }
        if options.framing { totalUnits += targets.count }
        if options.generate { totalUnits += targets.count }
        if options.generate && options.coverFrame { totalUnits += targets.count }
        if options.proposeNames { totalUnits += 1 }
        let total = Double(max(1, totalUnits))

        pipelineTask = Task {
            var unitsDone = Double(pipelineDone.count)
            pipelineProgress = min(1, unitsDone / total)
            // Mark a unit finished; done units are skipped on Resume.
            func finish(_ key: String) {
                pipelineDone.insert(key)
                unitsDone += 1
                pipelineProgress = min(1, unitsDone / total)
            }
            func completed(_ key: String) -> Bool { pipelineDone.contains(key) }
            func log(_ message: String) { pipelineLog.append(message) }
            // Sendable relay for service `log:` closures.
            let relay: @Sendable (String) -> Void = { message in
                Task { @MainActor in self.pipelineLog.append(message) }
            }
            // The run never prompts: rename proposals from inner passes are
            // superseded by the pipeline's own rename step, and new-people
            // reviews queue for the end.
            func swallowPrompts() {
                if options.proposeNames { pendingRenameReview = nil }
                if let people = pendingPeopleReview {
                    pipelineDeferredPeople = people
                    pendingPeopleReview = nil
                }
            }

            // 1. People roster + portraits per video.
            if options.detectPeople {
                for video in targets where !completed("people:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "people — \(video.filename)"
                    log("Detecting people in \(video.filename)…")
                    _ = await detectPeopleInVideo(video)
                    swallowPrompts()
                    finish("people:\(video.id)")
                }
            }

            // 2. Transcription (skips videos that already have one).
            if options.transcribe {
                let transcription = transcription
                let language = settings.transcribeLanguage
                for video in targets where !completed("transcribe:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "transcribing — \(video.filename)"
                    let existing = (try? await database.fetchTranscripts(videoID: video.id)) ?? []
                    if existing.isEmpty {
                        log("Transcribing \(video.filename)…")
                        do {
                            _ = try await transcription.transcribe(video: video, database: database,
                                                                   languageCode: language, log: relay)
                        } catch {
                            log("\(video.filename): transcription failed — \(error.userMessage)")
                        }
                    } else {
                        log("\(video.filename): transcript already exists")
                    }
                    finish("transcribe:\(video.id)")
                }
            }

            // 3. The analysis batch — one analyze() call covers every video
            // still lacking one (fight scoring rides inside per the
            // checkbox); the fresh run ids scope the follow-up steps.
            if options.analyze, !Task.isCancelled {
                let pending = targets.filter { !completed("analysis:\($0.id)") }
                if !pending.isEmpty {
                    let before = Dictionary(grouping: analysisRuns, by: \.videoID)
                        .mapValues { Set($0.map(\.id)) }
                    pipelineStage = "analyzing \(pending.count) video(s)"
                    log("Analyzing \(pending.count) video(s) — full details in the Raw Videos activity log")
                    analyze(videos: pending, includeFightScoring: options.fightScoring)
                    await analysisTask?.value
                    await refreshAllNow()
                    swallowPrompts()
                    for video in pending {
                        let prior = before[video.id] ?? []
                        if let fresh = analysisRuns.first(where: { $0.videoID == video.id && !prior.contains($0.id) }) {
                            pipelineRunIDs[video.id] = fresh.id
                            log("\(video.filename): analyzed into “\(fresh.name)”")
                            finish("analysis:\(video.id)")
                        }
                        // No fresh run (cancelled mid-batch) — left unmarked
                        // so Resume analyzes it.
                    }
                }
            } else if options.fightScoring {
                for video in targets where !completed("analysis:\(video.id)") {
                    if Task.isCancelled { break }
                    let current = videos.first { $0.id == video.id } ?? video
                    if current.type?.supportsFightFeatures == false {
                        log("\(video.filename): not a fight — scoring skipped")
                    } else {
                        pipelineStage = "fight scoring — \(video.filename)"
                        let allScenes = (try? await database.fetchScenes(includeExcluded: true)) ?? []
                        do {
                            _ = try await analyzer.scoreFightAction(
                                video: current, scenes: allScenes.filter { $0.videoID == video.id },
                                profile: activeProfile, database: database,
                                provider: nil, model: nil, log: relay)
                        } catch {
                            log("\(video.filename): fight scoring failed — \(error.userMessage)")
                        }
                    }
                    finish("analysis:\(video.id)")
                }
            }

            // 4. Per-video follow-ups.
            for video in targets {
                if Task.isCancelled { break }
                // Analysis may have (re)classified the video — work from the
                // fresh record.
                let current = videos.first { $0.id == video.id } ?? video
                let runID = pipelineRunIDs[video.id]

                if options.fightResearch, !completed("research:\(video.id)") {
                    pipelineStage = "fight research — \(current.filename)"
                    if fightResearch[current.id] != nil {
                        log("\(current.filename): fight research already on record")
                    } else if current.type?.supportsFightFeatures == false {
                        log("\(current.filename): not a fight — research skipped")
                    } else {
                        let identity = await guessFightIdentity(video: current)
                        if identity.fighters.trimmingCharacters(in: .whitespaces).isEmpty {
                            log("\(current.filename): couldn't derive the fight identity — research skipped")
                        } else {
                            do {
                                _ = try await runFightResearch(video: current, identity: identity,
                                                               log: relay)
                                log("\(current.filename): fight research done (\(identity.fighters))")
                            } catch {
                                log("\(current.filename): fight research failed — \(error.userMessage)")
                            }
                        }
                    }
                    finish("research:\(video.id)")
                }

                if options.curate, !completed("curate:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "curating — \(current.filename)"
                    let pool = scenes.filter { scene in
                        scene.videoID == current.id && !scene.curated && !scene.excluded
                            && (runID == nil || scene.runID == runID)
                    }
                    if pool.isEmpty {
                        log("\(current.filename): nothing new to curate")
                    } else {
                        do {
                            let proposals = try await proposeCuration(for: pool, provider: nil,
                                                                      model: nil, log: relay)
                            for proposal in proposals {
                                try? await database.setSceneCurated(proposal.sceneID, curated: true)
                            }
                            await refreshAllNow()
                            log("\(current.filename): curated \(proposals.count) of \(pool.count) scenes")
                        } catch {
                            log("\(current.filename): curation failed — \(error.userMessage)")
                        }
                    }
                    finish("curate:\(video.id)")
                }

                if options.framing, !completed("framing:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "framing — \(current.filename)"
                    let defaults = UserDefaults.standard
                    let camera = defaults.string(forKey: "analysis.framingCamera")
                        ?? FramingService.staticCamera
                    let tagPeople = defaults.object(forKey: "analysis.framingTagPeople") == nil
                        ? true : defaults.bool(forKey: "analysis.framingTagPeople")
                    log("Framing \(current.filename)…")
                    await detectFraming(video: current, camera: camera, tagFramedPeople: tagPeople)
                    finish("framing:\(video.id)")
                }

                if options.generate, !completed("generate:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "generating — \(current.filename)"
                    var wizard = Self.wizardOptionsFromForm()
                    wizard.selectedRunIDs = runID.map { [$0] }
                        ?? Set(analysisRuns.filter { $0.videoID == current.id }.map(\.id))
                    // Curated scope only when this video's batch actually has
                    // curated scenes (holds across Resume, unlike a counter).
                    wizard.curatedOnly = options.curate && scenes.contains { scene in
                        scene.videoID == current.id && scene.curated
                            && (runID == nil || scene.runID == runID)
                    }
                    wizard.critiqueLoop = options.critique
                    if wizard.selectedRunIDs.isEmpty {
                        log("\(current.filename): no analyze batch to generate from — skipped")
                    } else {
                        log("Generating a reel from \(current.filename)…")
                        let before = Set(generatedVideos.map(\.id))
                        runWizard(options: wizard)
                        await wizardTask?.value
                        await refreshAllNow()
                        let fresh = generatedVideos.filter { !before.contains($0.id) }
                            .sorted { $0.id < $1.id }
                        // One combined results sheet at the end beats a
                        // pop-up per video mid-run.
                        wizardResults = nil
                        if fresh.isEmpty {
                            log("\(current.filename): generation produced nothing"
                                + (wizardFailureMessage.map { " — \($0)" } ?? ""))
                        } else {
                            pipelineGenerated += fresh
                            log("\(current.filename): \(fresh.count) reel(s) rendered")
                        }
                    }
                    finish("generate:\(video.id)")
                }

                if options.generate && options.coverFrame, !completed("cover:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "cover frames — \(current.filename)"
                    // Per-video reel tracking doesn't survive Resume, so this
                    // covers any of the run's reels still lacking a cover.
                    for reelID in pipelineGenerated.map(\.id) where !Task.isCancelled {
                        guard let reel = generatedVideos.first(where: { $0.id == reelID }),
                              reel.coverTime == nil else { continue }
                        if let top = try? await proposeCoverFrames(for: reel, provider: nil,
                                                                   model: nil, log: { _ in }).first {
                            setCoverFrame(reel, time: top.time)
                            log("\(reel.filename): cover set at \(top.time.timecode)")
                        }
                    }
                    finish("cover:\(video.id)")
                }
            }

            // 5. File renames — applied automatically in pipeline mode
            // ("fire and forget"); derived analyze-batch labels follow via
            // renameVideo.
            if options.proposeNames, !completed("naming"), !Task.isCancelled {
                pipelineStage = "renaming files"
                pendingRenameReview = nil
                let current = targets.map { target in
                    videos.first { $0.id == target.id } ?? target
                }
                do {
                    let suggestions = try await suggestFileNames(for: current, provider: nil,
                                                                 model: nil, log: relay)
                    if suggestions.isEmpty {
                        log("No file renames needed")
                    } else {
                        for suggestion in suggestions {
                            guard let video = videos.first(where: { $0.id == suggestion.videoID })
                            else { continue }
                            log("Renamed \(suggestion.currentFilename) → \(suggestion.suggestedName)")
                            renameVideo(video, to: suggestion.suggestedName)
                        }
                        await refreshAllNow()
                    }
                } catch {
                    log("File naming failed — \(error.userMessage)")
                }
                finish("naming")
            }

            await refreshAllNow()
            swallowPrompts()
            if Task.isCancelled {
                pipelineStage = "stopped"
                log("Wizard Pipeline stopped — Resume in the bottom bar picks up where it left off.")
            } else {
                if !pipelineGenerated.isEmpty {
                    wizardResults = WizardRunResults(videos: pipelineGenerated)
                }
                // Deferred mid-run prompts present now that the run is over.
                if let people = pipelineDeferredPeople {
                    pendingPeopleReview = people
                    pipelineDeferredPeople = nil
                }
                pipelineProgress = 1
                pipelineStage = "done"
                log("Wizard Pipeline finished — \(pipelineGenerated.count) reel(s) ready.")
                pipelineOptions = nil
            }
            isPipelineRunning = false
        }
    }

    /// The Wizard form's persisted settings as WizardOptions — mirrors
    /// WizardView.runWizard()'s mapping (keep the two in sync) so pipeline
    /// reels honor the same format, branding, audio, and duration the user
    /// set up on the AI Wizard screen. Batch scoping, curatedOnly, and the
    /// critique flag stay the pipeline's to decide; the source-people filter
    /// deliberately doesn't apply (a per-video run could end up with zero
    /// eligible scenes).
    private static func wizardOptionsFromForm() -> WizardOptions {
        let defaults = UserDefaults.standard
        func bool(_ key: String, default fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        var options = WizardOptions()
        options.muteSource = bool("wizard.muteSource", default: false)
        options.useMusic = bool("wizard.useMusic", default: true)
            && !WizardEngine.availableMusic().isEmpty
        options.addCaptions = bool("wizard.addCaptions", default: false)
        options.autoCropWide = bool("wizard.autoCropWide", default: true)
        options.centerStageWide = bool("wizard.centerStageWide", default: false)
        options.centerStageCamera = defaults.string(forKey: "wizard.centerStageCamera") ?? "balanced"
        options.allowWideSplit = bool("wizard.allowWideSplit", default: false)
        options.enableTextOverlays = bool("wizard.enableTextOverlays", default: false)
        options.useFightResearch = bool("wizard.useFightResearch", default: true)
        options.aiInstructions = defaults.string(forKey: "wizard.aiInstructions") ?? ""
        let duration = defaults.object(forKey: "wizard.targetDuration") == nil
            ? 10 : defaults.integer(forKey: "wizard.targetDuration")
        options.targetDurationSeconds = min(180, max(3, duration))
        options.formatPreset = defaults.string(forKey: "wizard.formatPreset") ?? "custom"
        let taste = defaults.string(forKey: "wizard.tastePreset") ?? ""
        options.tastePreset = taste.isEmpty ? nil : taste
        options.includeWatermark = bool("wizard.includeWatermark", default: true)
        options.includeHeadline = bool("wizard.includeHeadline", default: true)
        options.includeOutro = bool("wizard.includeOutro", default: true)
        return options
    }

    /// Stop the run: the pipeline task plus whichever inner engine (analysis
    /// or wizard) is mid-flight right now.
    func cancelPipeline() {
        pipelineLog.append("Stopping…")
        pipelineTask?.cancel()
        cancelAnalysis()
        cancelWizard()
    }

    /// Clear the finished run's bottom bar (the log and any resumable state
    /// go with it).
    func dismissPipelineBar() {
        guard !isPipelineRunning else { return }
        pipelineStage = ""
        pipelineProgress = 0
        pipelineLog = []
        pipelineOptions = nil
        pipelineTargets = []
        pipelineDone = []
        pipelineRunIDs = [:]
        pipelineGenerated = []
    }

    // MARK: - Analyze batches

    /// Load a past batch's options back into the analysis settings and route
    /// to the Analyze tab with the plan sheet open — edit, then re-run.
    func reanalyzeBatch(_ run: AnalysisRun) {
        guard let video = videos.first(where: { $0.id == run.videoID }) else {
            presentError("The source video for this analyze batch is no longer in the library.")
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(run.instructions, forKey: "analysis.instructions")
        defaults.set(run.sampleInterval, forKey: "analysis.sampleInterval")
        defaults.set(run.hasTranscript, forKey: "analysis.includeTranscript")
        if let provider = run.provider {
            settings.ai.tasks["analysis"] = provider
            if let model = run.model { settings.ai.taskModels["analysis"] = model }
            saveSettings()
        }
        pendingAnalyzeSetup = video
        requestedSection = .analyze
    }

    func renameAnalysisRun(_ run: AnalysisRun, to rawName: String) {
        guard let database else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != run.name else { return }
        Task {
            do {
                try await database.renameAnalysisRun(id: run.id, name: name)
                await refreshAllNow()
            } catch {
                presentError("Could not rename the analyze batch", error)
            }
        }
    }

    /// Delete a batch with its scenes, tags, and grades.
    func deleteAnalysisRun(_ run: AnalysisRun) {
        guard let database else { return }
        Task {
            do {
                try await database.deleteAnalysisRun(id: run.id)
                await refreshAllNow()
            } catch {
                presentError("Could not delete the analyze batch", error)
            }
        }
    }

    // MARK: - Overlay wizard

    /// Read the overlay elements out of a reference image (text, logos,
    /// badges — people and background are discarded) and save them as a new
    /// overlay template. Logo/badge regions are cropped out of the image
    /// into the Images library so the template can render them.
    /// Returns the created template's name.
    func extractOverlayTemplate(from imageURL: URL, provider: String?, model: String?,
                                log: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let imageData = try? Data(contentsOf: imageURL),
              let image = NSImage(contentsOf: imageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AIError.notConfigured("Could not read the image.")
        }
        let prompt = """
        You are extracting the OVERLAY DESIGN from one frame of a social video so it can be recreated as a reusable overlay template.

        Identify ONLY overlay elements: text captions/titles, name plates, logos, channel badges, watermarks, stickers. DISCARD everything that is part of the footage itself — people, background, scenery.

        Return a JSON object:
        {"overlays": [
          {"kind": "text", "text": "<exact text>", "x": <0-1 center x>, "y": <0-1 center y>, "w": <0-1 width>, "h": <0-1 height>, "fontcolor": "#hex", "bold": true|false, "italic": true|false, "bgcolor": "#hex or null", "box_opacity": <0-1, 0 when no background plate>, "dynamic": true|false},
          {"kind": "image", "x": ..., "y": ..., "w": ..., "h": ..., "description": "<what it is, e.g. 'UFC logo'>"}
        ]}

        Rules:
        - Coordinates are fractions of the full frame; x/y are the element's CENTER.
        - "kind":"text" for anything that is essentially styled text — recreate it as text, estimating color/bold/italic and any background plate.
        - "kind":"image" for graphical marks (logos, badges, icons) that cannot be recreated as plain text. Make the box tight around the mark.
        - "dynamic": true for the main caption-style text a future video would replace with its own words; false for names/labels/branding.
        - 2-8 elements typical. Return ONLY the JSON object.
        """
        let frame = AIFrame(jpeg: imageData, label: "reference frame")
        let response = try await ai.call(prompt: prompt, task: "overlay", frames: [frame],
                                         model: model, provider: provider, timeout: 180, log: log)
        guard let object = AIResponseParser.jsonObject(from: response),
              let rawOverlays = object["overlays"] as? [[String: Any]], !rawOverlays.isEmpty else {
            throw AIError.emptyResponse("overlay extraction (no overlays found)")
        }

        var composition = OverlayComposition()
        var croppedCount = 0
        for raw in rawOverlays {
            let x = (raw["x"] as? NSNumber)?.doubleValue ?? 0.5
            let y = (raw["y"] as? NSNumber)?.doubleValue ?? 0.5
            let w = min(1, max(0.02, (raw["w"] as? NSNumber)?.doubleValue ?? 0.3))
            let h = min(1, max(0.02, (raw["h"] as? NSNumber)?.doubleValue ?? 0.1))
            if (raw["kind"] as? String) == "image" {
                // Crop the mark out of the reference image into the library.
                let pixelWidth = Double(cgImage.width)
                let pixelHeight = Double(cgImage.height)
                let rect = CGRect(x: max(0, (x - w / 2)) * pixelWidth,
                                  y: max(0, (y - h / 2)) * pixelHeight,
                                  width: min(w, 1) * pixelWidth,
                                  height: min(h, 1) * pixelHeight).integral
                guard let crop = cgImage.cropping(to: rect) else { continue }
                let name = raw["description"] as? String ?? "overlay mark"
                let sanitized = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
                    .reduce(into: "") { if $1 != "-" || $0.last != "-" { $0.append($1) } }
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                let directory = AssetKind.images.rootURL
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var fileURL = directory.appendingPathComponent("\(sanitized.isEmpty ? "overlay" : sanitized).png")
                var counter = 2
                while FileManager.default.fileExists(atPath: fileURL.path) {
                    fileURL = directory.appendingPathComponent("\(sanitized.isEmpty ? "overlay" : sanitized)-\(counter).png")
                    counter += 1
                }
                let rep = NSBitmapImageRep(cgImage: crop)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: fileURL)
                var item = ImageOverlayItem(path: fileURL.path, startTime: 0, endTime: 3)
                item.xFrac = x
                item.yFrac = y
                item.wFrac = w
                item.unbounded = true
                composition.images.append(item)
                croppedCount += 1
            } else {
                let text = (raw["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var item = TextOverlayItem(text: text, startTime: 0, endTime: 3)
                item.xFrac = x
                item.yFrac = y
                item.wFrac = w
                item.hFrac = h
                item.fontcolor = raw["fontcolor"] as? String ?? "white"
                item.bold = raw["bold"] as? Bool ?? false
                item.italic = raw["italic"] as? Bool ?? false
                if let bg = raw["bgcolor"] as? String {
                    item.bgcolor = bg
                    item.boxOpacity = (raw["box_opacity"] as? NSNumber)?.doubleValue ?? 0.6
                }
                item.isDynamic = raw["dynamic"] as? Bool ?? false
                item.unbounded = true
                composition.texts.append(item)
            }
        }
        guard !composition.isEmpty else {
            throw AIError.emptyResponse("overlay extraction (nothing usable)")
        }
        let base = imageURL.deletingPathExtension().lastPathComponent
        let name = OverlayTemplateStore.uniqueName(base: "Wizard – \(base)")
        try OverlayTemplateStore.save(OverlayTemplate(name: name, composition: composition))
        log("Created overlay template \"\(name)\": \(composition.texts.count) text(s), \(croppedCount) cropped image(s)")
        return name
    }

    // MARK: - People

    func renamePerson(_ person: PersonRecord, to name: String) {
        guard let database else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await database.renamePerson(id: person.id, name: trimmed)
                people = try await database.fetchPeople()
            } catch {
                presentError("Could not rename the person", error)
            }
        }
    }

    func deletePerson(_ person: PersonRecord) {
        guard let database else { return }
        Task {
            do {
                try await database.deletePerson(person)
                await refreshAllNow()
            } catch {
                presentError("Could not delete the person", error)
            }
        }
    }

    func mergePeople(source: PersonRecord, into target: PersonRecord) {
        guard let database, source.id != target.id else { return }
        Task {
            do {
                try await database.mergePeople(source: source, into: target)
                await refreshAllNow()
            } catch {
                presentError("Could not merge the people", error)
            }
        }
    }

    /// Merge several people into one: every other selected person's scenes
    /// are retagged onto the survivor. The survivor keeps its name unless
    /// the merge sheet supplied an edited one.
    func mergePeople(_ selected: [PersonRecord], into survivor: PersonRecord,
                     renamingTo name: String? = nil) {
        guard let database else { return }
        Task {
            do {
                for person in selected where person.id != survivor.id {
                    try await database.mergePeople(source: person, into: survivor)
                }
                if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !trimmed.isEmpty, trimmed != survivor.name {
                    try await database.renamePerson(id: survivor.id, name: trimmed)
                }
                await refreshAllNow()
            } catch {
                presentError("Could not merge the people", error)
            }
        }
    }

    /// Apply the end-of-analysis people review in one pass: names land first,
    /// then duplicates fold into their targets. Merge targets are resolved
    /// transitively (A→B while B→C sends A's scenes to C), so chained
    /// assignments in one review can't point at a person that just vanished.
    func applyPeopleReview(names: [String: String], merges: [String: Int64]) {
        guard let database else { return }
        Task {
            do {
                var current = try await database.fetchPeople()
                for (key, name) in names {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard merges[key] == nil, !trimmed.isEmpty,
                          let record = current.first(where: { $0.key == key }) else { continue }
                    try await database.renamePerson(id: record.id, name: trimmed)
                }
                current = try await database.fetchPeople()
                let mergesByID: [Int64: Int64] = Dictionary(uniqueKeysWithValues:
                    merges.compactMap { key, targetID in
                        current.first { $0.key == key }.map { ($0.id, targetID) }
                    })
                func resolve(_ id: Int64) -> Int64 {
                    var seen: Set<Int64> = []
                    var id = id
                    while let next = mergesByID[id], seen.insert(id).inserted { id = next }
                    return id
                }
                for (sourceID, targetID) in mergesByID {
                    let resolved = resolve(targetID)
                    // A resolved target that is itself still a merge source
                    // means a cycle (A→B, B→A) — skip rather than merge into
                    // a person about to disappear.
                    guard mergesByID[resolved] == nil,
                          let source = current.first(where: { $0.id == sourceID }),
                          let target = current.first(where: { $0.id == resolved }),
                          source.id != target.id else { continue }
                    try await database.mergePeople(source: source, into: target)
                }
                await refreshAllNow()
            } catch {
                presentError("Could not apply the people review", error)
            }
        }
    }

    /// Split support: move one scene from a person to another (or a brand-new
    /// person named `newPersonName`, or nobody when both are nil).
    func reassignScene(_ scene: SceneRecord, from person: PersonRecord,
                       to target: PersonRecord?, newPersonName: String? = nil) {
        guard let database else { return }
        Task {
            do {
                var destination = target
                if destination == nil, let newPersonName {
                    destination = try await database.createPerson(name: newPersonName)
                }
                try await database.reassignScenePerson(sceneID: scene.id, from: person,
                                                       to: destination)
                await refreshAllNow()
            } catch {
                presentError("Could not reassign the scene", error)
            }
        }
    }

    // MARK: - Video notes

    func videoNotes(for videoID: Int64) async -> [VideoNote] {
        guard let database else { return [] }
        return (try? await database.videoNotes(videoID: videoID)) ?? []
    }

    /// Add a timestamped note; returns the video's refreshed note list.
    func addVideoNote(videoID: Int64, at atTime: Double, text: String) async -> [VideoNote] {
        guard let database else { return [] }
        do {
            try await database.addVideoNote(videoID: videoID, at: atTime, note: text)
        } catch {
            presentError("Could not save the note", error)
        }
        return (try? await database.videoNotes(videoID: videoID)) ?? []
    }

    func deleteVideoNote(_ note: VideoNote) async -> [VideoNote] {
        guard let database else { return [] }
        do {
            try await database.deleteVideoNote(id: note.id)
        } catch {
            presentError("Could not delete the note", error)
        }
        return (try? await database.videoNotes(videoID: note.videoID)) ?? []
    }

    // MARK: - Person markers

    func personMarkers(for videoID: Int64) async -> [PersonMarker] {
        guard let database else { return [] }
        return (try? await database.personMarkers(videoID: videoID)) ?? []
    }

    /// Draw a new identity box; returns the video's refreshed marker list.
    func addPersonMarker(videoID: Int64, at atTime: Double,
                         x: Double, y: Double, width: Double, height: Double) async -> [PersonMarker] {
        guard let database else { return [] }
        do {
            try await database.addPersonMarker(videoID: videoID, at: atTime,
                                               x: x, y: y, width: width, height: height)
        } catch {
            presentError("Could not save the person marker", error)
        }
        return (try? await database.personMarkers(videoID: videoID)) ?? []
    }

    func updatePersonMarker(_ marker: PersonMarker) async -> [PersonMarker] {
        guard let database else { return [] }
        do {
            try await database.updatePersonMarker(marker)
        } catch {
            presentError("Could not update the person marker", error)
        }
        return (try? await database.personMarkers(videoID: marker.videoID)) ?? []
    }

    func deletePersonMarker(_ marker: PersonMarker) async -> [PersonMarker] {
        guard let database else { return [] }
        do {
            try await database.deletePersonMarker(id: marker.id)
        } catch {
            presentError("Could not delete the person marker", error)
        }
        return (try? await database.personMarkers(videoID: marker.videoID)) ?? []
    }

    /// The person's first marker plus its video URL, for face avatars.
    func personMarkerReference(for personID: Int64) async -> (url: URL, marker: PersonMarker)? {
        guard let database else { return nil }
        guard let reference = try? await database.markerReference(personID: personID),
              !reference.videoPath.isEmpty else { return nil }
        return (URL(fileURLWithPath: reference.videoPath), reference.marker)
    }

    /// Hide/unhide a person on the People screen. Hidden people keep their
    /// identity — detection still reuses their key and their scene tags stay
    /// — they just move to the Hidden bucket at the bottom of the list.
    func setPersonHidden(_ person: PersonRecord, hidden: Bool) {
        guard let database else { return }
        Task {
            do {
                try await database.setPersonHidden(id: person.id, hidden: hidden)
                people = try await database.fetchPeople()
            } catch {
                presentError("Could not update the person", error)
            }
        }
    }

    /// Hand-pick a person's avatar frame — or reset to automatic with nils.
    /// The picked frame + face box render everywhere the avatar shows.
    func setPersonAvatar(_ person: PersonRecord, videoID: Int64?, time: Double?,
                         box: VideoPersonRecord.PortraitBox?) {
        guard let database else { return }
        let boxJSON = box.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        Task {
            do {
                try await database.setPersonAvatar(id: person.id, videoID: videoID,
                                                   time: time, boxJSON: boxJSON)
                people = try await database.fetchPeople()
            } catch {
                presentError("Could not save the avatar", error)
            }
        }
    }

    /// "New Person…" from a marker's dropdown — creates the registry entry
    /// and refreshes the people list. Returns the new record.
    func createPerson(named name: String) async -> PersonRecord? {
        guard let database else { return nil }
        do {
            let person = try await database.createPerson(name: name)
            people = try await database.fetchPeople()
            return person
        } catch {
            presentError("Could not create the person", error)
            return nil
        }
    }

    /// Rename a source video: move the file in the Input folder and update
    /// its row (scenes join the videos table, so they follow). Content
    /// hashing means the folder watcher won't re-register it as new.
    func renameVideo(_ video: VideoRecord, to rawName: String) {
        guard let database else { return }
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, name != video.filename else { return }
        let ext = video.url.pathExtension
        if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() {
            name += ".\(ext)"
        }
        let destination = video.url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            presentError("A file named \(name) already exists in the Input folder.")
            return
        }
        do {
            try FileManager.default.moveItem(at: video.url, to: destination)
        } catch {
            presentError("Could not rename the video", error)
            return
        }
        Task {
            do {
                try await database.renameVideo(id: video.id, filename: name, path: destination.path)
                await renameAnalysisBatches(for: video, newFilename: name)
                await refreshAllNow()
            } catch {
                presentError("Could not save the new name", error)
            }
        }
    }

    /// Batch labels carry the filename — after a video rename, rebuild every
    /// label still derived from the old name into the current format:
    /// "<name without extension> MM/dd/yy" (+ " v<n>" from the second batch
    /// of the video on), keeping a trailing "(start–end)" trim-window
    /// suffix. Labels the user hand-renamed (no trace of the old filename)
    /// are left alone.
    private func renameAnalysisBatches(for video: VideoRecord, newFilename: String) async {
        guard let database else { return }
        let oldBase = (video.filename as NSString).deletingPathExtension
        let newBase = (newFilename as NSString).deletingPathExtension
        let runs = ((try? await database.fetchAnalysisRuns()) ?? [])
            .filter { $0.videoID == video.id }
            .sorted { $0.id < $1.id }
        // Auto-derived labels: the legacy "… — as of <date>" stamp or the
        // current "… MM/dd/yy [vN] [(trim)]" one. Catches labels still
        // carrying a name from before an earlier rename, too.
        func isDerived(_ label: String) -> Bool {
            label.contains(video.filename) || label.contains(oldBase)
                || label.contains(" — as of ")
                || label.range(of: #"\d{2}/\d{2}/\d{2}( v\d+)?( \([0-9:.]+–[0-9:.]+\))?$"#,
                               options: .regularExpression) != nil
        }
        for (index, run) in runs.enumerated() where isDerived(run.name) {
            var label = "\(newBase) \(Self.shortDate(run.createdAt))"
            if index >= 1 { label += " v\(index + 1)" }
            if let window = run.name.range(of: #" \([0-9:.]+–[0-9:.]+\)$"#,
                                           options: .regularExpression) {
                label += String(run.name[window])
            }
            try? await database.renameAnalysisRun(id: run.id, name: label)
        }
    }

    /// SQLite "YYYY-MM-DD hh:mm:ss" (UTC) → local "MM/dd/yy"; today if
    /// unparseable. The full timestamp must convert to local time BEFORE
    /// dropping the time, else late-evening batches land on the wrong day.
    private static func shortDate(_ sqliteDate: String?) -> String {
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.dateFormat = "MM/dd/yy"
        guard let sqliteDate else { return output.string(from: .now) }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.timeZone = TimeZone(identifier: "UTC")
        input.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = input.date(from: sqliteDate) {
            return output.string(from: date)
        }
        // Date-only fallback: keep it in UTC on both ends so the calendar
        // day survives.
        input.dateFormat = "yyyy-MM-dd"
        if let date = input.date(from: String(sqliteDate.prefix(10))) {
            output.timeZone = TimeZone(identifier: "UTC")
            return output.string(from: date)
        }
        return output.string(from: .now)
    }

    // MARK: - File Name Wizard

    /// Build a descriptive filename proposal for each video from the
    /// metadata already on record — people detection, video type, fight
    /// outcome/research, scene narratives, moments, transcript — one
    /// text-only AI call per video (no frame extraction). Returns sanitized
    /// proposals for the review sheet; a video whose best name is its
    /// current one is skipped. Applying a proposal goes through
    /// `renameVideo`, so derived analyze-batch labels follow (scene titles
    /// join the videos table and follow automatically).
    func suggestFileNames(for videos: [VideoRecord], provider: String?, model: String?,
                          log: @escaping @Sendable (String) -> Void) async throws -> [RenameSuggestion] {
        guard let database else { throw AIError.notConfigured("No profile is open.") }
        // Latest outcome per video, fetched once for the whole batch.
        let outcomes = (try? await database.fetchOutcomes()) ?? []
        var suggestions: [RenameSuggestion] = []
        var lastError: Error?
        for (index, video) in videos.enumerated() {
            log("Naming \(video.filename) (\(index + 1)/\(videos.count))…")
            let scenes = (try? await database.fetchScenes(videoID: video.id)) ?? []
            let people = (try? await database.fetchVideoPeople(videoID: video.id)) ?? []
            let moments = (try? await database.moments(videoID: video.id)) ?? []
            let transcripts = (try? await database.fetchTranscripts(videoID: video.id)) ?? []
            let prompt = FileNamer.prompt(video: video, scenes: scenes, people: people,
                                          outcome: outcomes.first { $0.videoID == video.id },
                                          research: fightResearch[video.id],
                                          moments: moments, transcripts: transcripts)
            do {
                let response = try await ai.call(prompt: prompt, task: "naming",
                                                 model: model, provider: provider,
                                                 timeout: 180, log: log)
                guard let (name, reason) = FileNamer.parseSuggestion(from: response) else {
                    log("\(video.filename): the model returned no usable name")
                    continue
                }
                let currentBase = (video.filename as NSString).deletingPathExtension
                guard name.caseInsensitiveCompare(currentBase) != .orderedSame else {
                    log("\(video.filename): the current name is already the best fit")
                    continue
                }
                if let reason { log("\(video.filename) → \(name) (\(reason))") }
                suggestions.append(RenameSuggestion(videoID: video.id,
                                                    currentFilename: video.filename,
                                                    suggestedName: name))
            } catch let error as AIError {
                // A dead quota dooms every remaining call — stop the batch.
                if case .quotaExhausted = error { throw error }
                lastError = error
                log("\(video.filename): \(error)")
            }
        }
        // Partial results beat an error; an error beats silently proposing
        // nothing.
        if suggestions.isEmpty, let lastError { throw lastError }
        return suggestions
    }

    // MARK: - AI Curator

    /// Judge the given uncurated scenes against the taste rubric (with the
    /// user's grading history and existing Curated picks as worked examples)
    /// and return proposed promotions for review. Chunked so any library
    /// size fits in the model's context.
    func proposeCuration(for candidates: [SceneRecord], provider: String?, model: String?,
                         log: @escaping @Sendable (String) -> Void) async throws -> [SceneCurator.Proposal] {
        let profile = activeProfile
        let graded = scenes.filter { $0.lastGrade != nil }
        let curatedExamples = scenes.filter(\.curated)
        var proposals: [SceneCurator.Proposal] = []
        var start = 0
        while start < candidates.count {
            let chunk = Array(candidates[start..<min(start + SceneCurator.batchSize, candidates.count)])
            if candidates.count > SceneCurator.batchSize {
                log("Judging scenes \(start + 1)–\(start + chunk.count) of \(candidates.count)…")
            }
            let prompt = SceneCurator.prompt(candidates: chunk, rubric: profile.tasteRubric,
                                             categories: profile.tasteCategories,
                                             graded: graded, curatedExamples: curatedExamples)
            let response = try await ai.call(prompt: prompt, task: "curate",
                                             model: model, provider: provider,
                                             timeout: 240, log: log)
            proposals += SceneCurator.parse(response, validIDs: Set(chunk.map(\.id)))
            start += SceneCurator.batchSize
        }
        return proposals
    }

    /// Apply the reviewed curator picks in one pass — batched DB writes and
    /// a single refresh, unlike per-scene `curateScene`.
    func applyCuration(sceneIDs: [Int64]) {
        guard let database else { return }
        Task {
            for id in sceneIDs {
                try? await database.setSceneCurated(id, curated: true)
            }
            await refreshAllNow()
        }
    }

    // MARK: - Natural-language scene search

    /// "The moment Ulberg hurts Błachowicz against the fence" → ranked scene
    /// ids from the candidate set, matched by the model on narratives, tags,
    /// people, and timing.
    func findScenes(matching query: String, in candidates: [SceneRecord],
                    provider: String?, model: String?,
                    log: @escaping @Sendable (String) -> Void) async throws -> [Int64] {
        // Most recent scenes win when the library outgrows one call.
        let scoped = candidates.count > SceneFinder.maxCandidates
            ? Array(candidates.sorted { $0.id > $1.id }.prefix(SceneFinder.maxCandidates))
            : candidates
        if scoped.count < candidates.count {
            log("Searching the \(scoped.count) most recent of \(candidates.count) scenes")
        }
        let prompt = SceneFinder.prompt(query: query, scenes: scoped, people: people)
        let response = try await ai.call(prompt: prompt, task: "search",
                                         model: model, provider: provider,
                                         timeout: 120, log: log)
        return SceneFinder.parse(response, validIDs: Set(scoped.map(\.id)))
    }

    // MARK: - Soundbite finder

    /// Mine a video's transcript for its most quotable self-contained
    /// moments. Throws a friendly error when the video has no transcript.
    func findSoundbites(in video: VideoRecord, provider: String?, model: String?,
                        log: @escaping @Sendable (String) -> Void) async throws -> [SoundbiteFinder.Soundbite] {
        guard let database else { throw AIError.notConfigured("No profile is open.") }
        let transcript = ((try? await database.fetchTranscripts(videoID: video.id)) ?? [])
            .filter { !$0.isTranslation }
        guard !transcript.isEmpty else {
            throw AIError.notConfigured("\(video.filename) has no transcript yet — run Transcribe on it first.")
        }
        let prompt = SoundbiteFinder.prompt(video: video, transcript: transcript)
        let response = try await ai.call(prompt: prompt, task: "soundbites",
                                         model: model, provider: provider,
                                         timeout: 180, log: log)
        let soundbites = SoundbiteFinder.parse(response, duration: video.duration)
        guard !soundbites.isEmpty else {
            throw AIError.unusableResponse("The model found no usable soundbites in the transcript.")
        }
        return soundbites
    }

    // MARK: - Cover frame picker

    /// Sample frames across a rendered reel and have a multimodal model rank
    /// the best thumbnail candidates for the Library card.
    func proposeCoverFrames(for video: GeneratedVideoRecord, provider: String?, model: String?,
                            log: @escaping @Sendable (String) -> Void) async throws -> [CoverFramePicker.Candidate] {
        let times = CoverFramePicker.sampleTimes(duration: video.duration)
        log("Sampling \(times.count) frames…")
        var frames: [AIFrame] = []
        for time in times {
            if let jpeg = await ThumbnailService.jpegFrame(url: video.url, at: time,
                                                          maxDimension: 768) {
                frames.append(AIFrame(jpeg: jpeg, label: String(format: "%.1fs", time)))
            }
        }
        guard !frames.isEmpty else {
            throw AIError.notConfigured("No frames could be read from \(video.filename).")
        }
        let response = try await ai.call(prompt: CoverFramePicker.prompt(filename: video.filename,
                                                                         duration: video.duration),
                                         task: "cover", frames: frames,
                                         model: model, provider: provider,
                                         timeout: 180, log: log)
        let candidates = CoverFramePicker.parse(response, sampledTimes: times)
        guard !candidates.isEmpty else {
            throw AIError.unusableResponse("The model returned no usable cover picks.")
        }
        return candidates
    }

    /// Remember the picked cover frame and patch the card in place.
    func setCoverFrame(_ video: GeneratedVideoRecord, time: Double) {
        guard let database else { return }
        Task {
            do {
                try await database.updateGeneratedCover(id: video.id, time: time)
                if let index = generatedVideos.firstIndex(where: { $0.id == video.id }) {
                    generatedVideos[index].coverTime = time
                }
            } catch {
                presentError("Could not save the cover frame", error)
            }
        }
    }

    // MARK: - Trim suggestion

    /// AI skim of the whole video proposing the section worth analyzing —
    /// fills the plan sheet's trim slider.
    func suggestTrim(for video: VideoRecord) async throws -> (start: Double, end: Double, reason: String) {
        try await analyzer.suggestTrim(video: video) { message in
            Task { @MainActor in self.analysisLog.append(message) }
        }
    }

    // MARK: - Duplicate detection

    /// Scan the library for the same footage imported more than once —
    /// metadata plus one mid-video frame per video, grouped with a keep
    /// recommendation. Report-only; an empty result means no duplicates.
    func findDuplicateVideos(provider: String?, model: String?,
                             log: @escaping @Sendable (String) -> Void) async throws -> [DuplicateFinder.Group] {
        guard let database else { throw AIError.notConfigured("No profile is open.") }
        guard videos.count >= 2 else {
            throw AIError.notConfigured("Fewer than two videos in the library — nothing to compare.")
        }
        let scoped = Array(videos.prefix(DuplicateFinder.maxVideos))
        if scoped.count < videos.count {
            log("Comparing the first \(scoped.count) of \(videos.count) videos")
        }
        var lines: [String] = []
        var frames: [AIFrame] = []
        for video in scoped {
            let people = ((try? await database.fetchVideoPeople(videoID: video.id)) ?? [])
                .map(\.displayName)
            var line = "- id \(video.id) | \(video.filename) | \(Int(video.duration))s | \(video.width)×\(video.height)"
            if let type = video.type?.label { line += " | \(type)" }
            if !people.isEmpty { line += " | people: \(people.joined(separator: ", "))" }
            if let research = fightResearch[video.id] { line += " | fight: \(research.fightLabel)" }
            lines.append(line)
            if let jpeg = await ThumbnailService.jpegFrame(url: video.url, at: video.duration / 2,
                                                          maxDimension: 512) {
                frames.append(AIFrame(jpeg: jpeg, label: "id \(video.id): \(video.filename)"))
            }
        }
        let response = try await ai.call(prompt: DuplicateFinder.prompt(inventory: lines.joined(separator: "\n")),
                                         task: "dedupe", frames: frames,
                                         model: model, provider: provider,
                                         timeout: 240, log: log)
        return DuplicateFinder.parse(response, validIDs: Set(scoped.map(\.id)))
    }

    // MARK: - Content gap report

    /// A strategist's pass over the whole pipeline — what to post next,
    /// what's sitting unused, what's blocking output — as a checklist
    /// referencing actual files.
    func generateGapReport(provider: String?, model: String?,
                           log: @escaping @Sendable (String) -> Void) async throws -> [GapReporter.Section] {
        guard let database else { throw AIError.notConfigured("No profile is open.") }
        var sceneCounts: [Int64: (total: Int, curated: Int)] = [:]
        for scene in scenes where !scene.excluded {
            sceneCounts[scene.videoID, default: (0, 0)].total += 1
            if scene.curated { sceneCounts[scene.videoID, default: (0, 0)].curated += 1 }
        }
        let batchCounts = Dictionary(grouping: analysisRuns, by: \.videoID).mapValues(\.count)
        var inventory: [String] = []
        let videoLines = videos.map { video in
            var line = "- \(video.filename) | \(Int(video.duration))s | \(video.type?.label ?? "unclassified")"
            let counts = sceneCounts[video.id] ?? (0, 0)
            line += " | \(batchCounts[video.id] ?? 0) analyze batch(es), \(counts.total) scenes, \(counts.curated) curated"
            if fightResearch[video.id] != nil { line += " | fight research done" }
            return line
        }
        inventory.append("## SOURCE VIDEOS (\(videos.count))\n" + (videoLines.isEmpty ? "(none)" : videoLines.joined(separator: "\n")))

        let generatedLines = generatedVideos.map { video in
            var line = "- \(video.filename) | \(Int(video.duration))s | generated \(video.generatedAt ?? "?")"
            if let critique = video.critique { line += " | critic \(critique.score)/100" }
            if let stats = video.instagramStats {
                line += " | PUBLISHED — \(ReelPerformance.label(stats, duration: video.duration))"
            } else if video.instagramMediaID != nil {
                line += " | published (no insights yet)"
            } else {
                line += " | NOT published"
            }
            return line
        }
        inventory.append("## GENERATED REELS (\(generatedVideos.count))\n" + (generatedLines.isEmpty ? "(none yet)" : generatedLines.joined(separator: "\n")))

        for account in igAccounts where account.isOwn {
            let media = (try? await database.fetchIGMedia(accountID: account.id)) ?? []
            let latest = media.compactMap(\.postedAt).max()
            var line = "@\(account.username): \(media.count) reels fetched"
            if let latest {
                line += ", most recent posted \(latest.formatted(date: .abbreviated, time: .omitted))"
            }
            inventory.append("## INSTAGRAM ACCOUNT\n" + line)
        }
        inventory.append("## TRAINING\n\(lessons.count) learned lesson(s), taste rubric \(activeProfile.tasteRubric.isEmpty ? "EMPTY" : "written"), house style \(activeProfile.houseStyle.isEmpty ? "EMPTY" : "written")")

        let response = try await ai.call(prompt: GapReporter.prompt(inventory: inventory.joined(separator: "\n\n"),
                                                                    domain: activeProfile.effectiveDomain),
                                         task: "gap", model: model, provider: provider,
                                         timeout: 240, log: log)
        let sections = GapReporter.parse(response)
        guard !sections.isEmpty else {
            throw AIError.unusableResponse("The report couldn't be read from the model's reply.")
        }
        return sections
    }

    // MARK: - Instagram performance lessons

    /// A performance-lesson distillation is running (one at a time).
    var isDistillingPerformanceLessons = false

    /// Correlate published reels' Instagram insights (and the account's own
    /// reels) with their traits, and distill lessons the wizard's planner
    /// treats as guidance. Replaces only its own previous batch of lessons.
    func distillPerformanceLessons() {
        guard let database, !isDistillingPerformanceLessons else { return }
        isDistillingPerformanceLessons = true
        Task {
            do {
                let published = generatedVideos.filter { $0.instagramStats != nil }
                var ownMedia: [IGMediaRecord] = []
                for account in igAccounts where account.isOwn {
                    ownMedia += (try? await database.fetchIGMedia(accountID: account.id)) ?? []
                }
                guard published.count >= 3 || ownMedia.count >= 5 else {
                    throw AIError.notConfigured("Not enough performance data yet — publish reels or refresh an owned Instagram account first.")
                }
                igLog.append("Distilling lessons from \(published.count) published reel(s) and \(ownMedia.count) account reel(s)…")
                let response = try await ai.call(
                    prompt: PerformanceLessons.prompt(published: published, ownMedia: ownMedia),
                    task: "distill", timeout: 240,
                    log: { message in Task { @MainActor in self.igLog.append(message) } })
                let distilled = PerformanceLessons.parse(response)
                guard !distilled.isEmpty else {
                    throw AIError.unusableResponse("No lessons came back from the model.")
                }
                // Replace only this pass's previous lessons — review-distilled
                // and pinned lessons are untouched.
                for lesson in (try? await database.fetchLessons()) ?? []
                where !lesson.pinned && lesson.evidence.hasPrefix(PerformanceLessons.evidencePrefix) {
                    try? await database.deleteLesson(id: lesson.id)
                }
                for lesson in distilled.prefix(PerformanceLessons.maxLessons) {
                    _ = try? await database.addLesson(
                        text: lesson.text, pinned: false,
                        evidence: "\(PerformanceLessons.evidencePrefix): \(lesson.evidence)")
                }
                lessons = (try? await database.fetchLessons()) ?? lessons
                igLog.append("Added \(min(PerformanceLessons.maxLessons, distilled.count)) performance lesson(s) — see AI Wizard → Learned Lessons.")
            } catch {
                presentError("Could not distill performance lessons", error)
            }
            isDistillingPerformanceLessons = false
        }
    }

    // MARK: - Profile starter

    /// Turn the brand interview into a founding taste rubric, house style,
    /// and starter categories — reviewed in the sheet before applying.
    func generateProfileStarter(audience: String, tone: String, inspiration: String, avoid: String,
                                provider: String?, model: String?,
                                log: @escaping @Sendable (String) -> Void) async throws -> ProfileStarter.Result {
        let prompt = ProfileStarter.prompt(domain: activeProfile.effectiveDomain,
                                           brand: activeProfile.brandName,
                                           audience: audience, tone: tone,
                                           inspiration: inspiration, avoid: avoid)
        let response = try await ai.call(prompt: prompt, task: "onboard",
                                         model: model, provider: provider,
                                         timeout: 240, log: log)
        guard let result = ProfileStarter.parse(response) else {
            throw AIError.unusableResponse("The style documents couldn't be read from the model's reply.")
        }
        return result
    }

    /// Write the reviewed starter into the profile. New categories are
    /// appended; an existing key is never overwritten (studying may have
    /// refined it already).
    func applyProfileStarter(_ result: ProfileStarter.Result,
                             rubric: Bool, houseStyle: Bool, categories: Bool) {
        if rubric { activeProfile.tasteRubric = result.rubric }
        if houseStyle { activeProfile.houseStyle = result.houseStyle }
        if categories {
            let existing = Set(activeProfile.tasteCategories.map(\.key))
            activeProfile.tasteCategories += result.categories.filter { !existing.contains($0.key) }
        }
        saveActiveProfile()
    }

    /// User pick from the Analyze table's Type column — the manual value
    /// sticks (analysis only fills the type in when it's empty).
    func setVideoType(_ video: VideoRecord, type: VideoType?) {
        guard let database else { return }
        Task {
            do {
                try await database.setVideoType(id: video.id, type: type?.rawValue)
                if let index = videos.firstIndex(where: { $0.id == video.id }) {
                    videos[index].videoType = type?.rawValue
                }
            } catch {
                presentError("Could not save the video type", error)
            }
        }
    }

    func transcribe(video: VideoRecord, force: Bool = false) {
        guard let database, !transcribingVideoIDs.contains(video.id) else { return }
        transcribingVideoIDs.insert(video.id)
        let transcription = transcription
        let language = settings.transcribeLanguage
        transcriptionTasks[video.id] = Task {
            defer {
                transcribingVideoIDs.remove(video.id)
                transcriptionTasks[video.id] = nil
                refreshAll()
            }
            do {
                _ = try await transcription.transcribe(video: video, database: database,
                                                       languageCode: language, force: force,
                                                       log: { message in
                    Task { @MainActor in self.analysisLog.append(message) }
                })
                analysisLog.append("\(video.filename): transcription saved")
            } catch is CancellationError {
                analysisLog.append("\(video.filename): transcription stopped")
            } catch {
                presentError("Transcription failed", error)
            }
        }
    }

    func cancelTranscription(videoID: Int64) {
        transcriptionTasks[videoID]?.cancel()
    }

    // MARK: - Scene actions

    /// Apply a single-scene change in place after its DB write — refetching
    /// the whole library for a one-row mutation made every rating click
    /// O(library size).
    private func updateScene(_ id: Int64, _ mutate: (inout SceneRecord) -> Void) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&scenes[index])
        builder.updateScenes(scenes)
    }

    func toggleFavorite(_ scene: SceneRecord) {
        guard let database else { return }
        let favorite = !scene.favorite
        Task {
            do {
                try await database.setSceneFavorite(scene.id, favorite: favorite)
                updateScene(scene.id) { $0.favorite = favorite }
            } catch {
                presentError("Could not save the favorite", error)
            }
        }
    }

    /// Pin one scene as the best of its stack of near-simultaneous scenes —
    /// it moves on top of the collapsed card and stays there. Clears the pin
    /// from the other members so exactly one scene per stack holds it;
    /// re-picking the AI's own choice just records it explicitly.
    func chooseStackBest(_ scene: SceneRecord, among members: [SceneRecord]) {
        guard let database else { return }
        Task {
            do {
                for member in members where member.stackChoice && member.id != scene.id {
                    try await database.setSceneStackChoice(member.id, chosen: false)
                    updateScene(member.id) { $0.stackChoice = false }
                }
                try await database.setSceneStackChoice(scene.id, chosen: true)
                updateScene(scene.id) { $0.stackChoice = true }
            } catch {
                presentError("Could not save the pick", error)
            }
        }
    }

    func setExcluded(_ scene: SceneRecord, excluded: Bool) {
        guard let database else { return }
        Task {
            do {
                try await database.setSceneExcluded(scene.id, excluded: excluded)
                updateScene(scene.id) { $0.excluded = excluded }
            } catch {
                presentError("Could not update the scene", error)
            }
        }
    }

    func grade(_ scene: SceneRecord, score: Int) {
        guard let database else { return }
        Task {
            do {
                try await database.addGrade(sceneID: scene.id, score: score)
                updateScene(scene.id) {
                    let total = ($0.gradeAverage ?? 0) * Double($0.gradeCount) + Double(score)
                    $0.gradeCount += 1
                    $0.gradeAverage = total / Double($0.gradeCount)
                    $0.lastGrade = score
                }
            } catch {
                presentError("Could not save the rating", error)
            }
        }
    }

    // MARK: - Generated videos

    func deleteGeneratedVideo(_ video: GeneratedVideoRecord, removeFile: Bool) {
        guard let database else { return }
        Task {
            do {
                try await database.deleteGeneratedVideo(id: video.id)
            } catch {
                presentError("Could not delete the video", error)
                return
            }
            if removeFile {
                try? FileManager.default.removeItem(at: video.url)
            }
            generatedVideos.removeAll { $0.id == video.id }
            feedback.removeAll { $0.generatedVideoID == video.id }
        }
    }

    func addFeedback(for video: GeneratedVideoRecord, text: String) {
        guard let database else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await database.addFeedback(generatedVideoID: video.id, text: trimmed)
                feedback = try await database.fetchAllFeedback()
            } catch {
                presentError("Could not save the feedback", error)
            }
        }
    }

    // MARK: - Reviews + lessons

    func loadReview(for video: GeneratedVideoRecord) async -> (review: GenerationReview, clips: [ClipReview])? {
        guard let database else { return nil }
        return try? await database.fetchReview(generatedVideoID: video.id)
    }

    func saveReview(_ review: GenerationReview, clips: [ClipReview]) {
        guard let database else { return }
        Task {
            do {
                try await database.saveReview(review, clips: clips)
            } catch {
                presentError("Could not save the review", error)
            }
        }
    }

    /// Record the A/B pick for the presented batch (winner vs. every other
    /// variation), then surface the next queued batch if any.
    func resolveComparison(_ batch: ComparisonBatch, winner: GeneratedVideoRecord?) {
        if let database, let winner {
            let losers = batch.videos.filter { $0.id != winner.id }
            Task {
                for loser in losers {
                    do {
                        try await database.addPreference(chosenID: winner.id, rejectedID: loser.id,
                                                         chosenRationale: winner.rationale ?? "",
                                                         rejectedRationale: loser.rationale ?? "")
                    } catch {
                        presentError("Could not save the preference", error)
                    }
                }
            }
        }
        comparisonQueue.removeAll { $0.id == batch.id }
        pendingComparison = comparisonQueue.first
    }

    func distillLessons() {
        guard let database, !isDistillingLessons else { return }
        isDistillingLessons = true
        let wizard = wizard
        Task {
            do {
                let count = try await wizard.distillLessons(database: database) { message in
                    Task { @MainActor in self.wizardLog.append(message) }
                }
                lessons = try await database.fetchLessons()
                wizardLog.append("Distilled \(count) lesson(s) from your reviews")
            } catch {
                presentError("Lesson distillation failed", error)
            }
            isDistillingLessons = false
        }
    }

    /// Distill the profile's house style from every analyzed Instagram reel
    /// (weighted by performance) and save it — the wizard injects it into
    /// every plan.
    func distillHouseStyle() {
        guard let database, !isDistillingHouseStyle else { return }
        isDistillingHouseStyle = true
        let wizard = wizard
        let existing = activeProfile.houseStyle
        Task {
            do {
                let style = try await wizard.distillHouseStyle(database: database,
                                                               existing: existing) { message in
                    Task { @MainActor in self.wizardLog.append(message) }
                }
                activeProfile.houseStyle = style
                saveActiveProfile()
                wizardLog.append("House style updated from the analyzed reels")
            } catch {
                presentError("House style distillation failed", error)
            }
            isDistillingHouseStyle = false
        }
    }

    // MARK: - Wizard Brain export/import

    /// Write the portable Wizard Brain (lessons + taste + house style, with
    /// exemplar frames inlined) to a JSON file the user can back up in git
    /// or hand to another user.
    func exportWizardBrain(to url: URL) {
        guard let database else { return }
        Task {
            do {
                let lessons = try await database.fetchLessons()
                let brain = WizardBrain.assemble(profile: activeProfile, lessons: lessons)
                try brain.write(to: url)
                wizardBrainStatus = "Exported \(lessons.count) lesson(s), \(activeProfile.tasteCategories.count) video type(s), taste rubric, and house style to \(url.lastPathComponent)"
            } catch {
                presentError("Wizard Brain export failed", error)
            }
        }
    }

    /// Merge a Wizard Brain file into this profile: new lessons are added
    /// (duplicates by text are skipped, pinned stays pinned), new video-type
    /// categories are added with their exemplar frames restored to disk, and
    /// the taste rubric / house style fill in only when empty locally —
    /// nothing the user already has is overwritten.
    func importWizardBrain(from url: URL) {
        guard let database else { return }
        Task {
            do {
                let brain = try WizardBrain.read(from: url)
                var notes: [String] = []

                let existingTexts = Set((try await database.fetchLessons()).map {
                    $0.text.lowercased()
                })
                var addedLessons = 0
                var skippedLessons = 0
                for lesson in brain.lessons {
                    let text = lesson.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if existingTexts.contains(text.lowercased()) {
                        skippedLessons += 1
                        continue
                    }
                    _ = try await database.addLesson(
                        text: text, pinned: lesson.pinned,
                        evidence: lesson.evidence.isEmpty ? "imported" : "\(lesson.evidence) · imported")
                    addedLessons += 1
                }
                lessons = try await database.fetchLessons()
                notes.append("\(addedLessons) lesson(s) added"
                             + (skippedLessons > 0 ? " (\(skippedLessons) already present)" : ""))

                var addedCategories = 0
                var skippedCategories = 0
                for category in brain.categories {
                    if activeProfile.tasteCategories.contains(where: { $0.key == category.key }) {
                        skippedCategories += 1
                        continue
                    }
                    let frames = writeImportedTasteFrames(category.exemplarFramesBase64,
                                                          key: category.key)
                    activeProfile.tasteCategories.append(
                        TasteCategory(key: category.key, label: category.label,
                                      rubric: category.rubric, exemplarFrames: frames,
                                      studiedCount: category.studiedCount))
                    addedCategories += 1
                }
                notes.append("\(addedCategories) video type(s) added"
                             + (skippedCategories > 0 ? " (\(skippedCategories) kept yours)" : ""))

                let localRubricEmpty = activeProfile.tasteRubric
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if localRubricEmpty, !brain.tasteRubric.isEmpty {
                    activeProfile.tasteRubric = brain.tasteRubric
                    notes.append("taste rubric imported")
                } else if !brain.tasteRubric.isEmpty {
                    notes.append("taste rubric kept yours")
                }
                let localHouseStyleEmpty = activeProfile.houseStyle
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if localHouseStyleEmpty, !brain.houseStyle.isEmpty {
                    activeProfile.houseStyle = brain.houseStyle
                    notes.append("house style imported")
                } else if !brain.houseStyle.isEmpty {
                    notes.append("house style kept yours")
                }
                saveActiveProfile()
                wizardBrainStatus = "Imported \(url.lastPathComponent) (from \"\(brain.profileName)\"): "
                    + notes.joined(separator: ", ")
            } catch {
                presentError("Wizard Brain import failed", error)
            }
        }
    }

    /// Restore inlined exemplar frames to this profile's taste-frames folder.
    private func writeImportedTasteFrames(_ framesBase64: [String], key: String) -> [String] {
        let directory = SettingsStore.tasteFramesDirectory(profileName: activeProfile.profileName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        var paths: [String] = []
        for (index, base64) in framesBase64.prefix(8).enumerated() {
            guard let data = Data(base64Encoded: base64) else { continue }
            let url = directory.appendingPathComponent("imported-\(key)-\(stamp)-\(index).jpg")
            if (try? data.write(to: url)) != nil { paths.append(url.path) }
        }
        return paths
    }

    func addLesson(text: String) {
        guard let database else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await database.addLesson(text: trimmed, pinned: true, evidence: "added by you")
                lessons = try await database.fetchLessons()
            } catch {
                presentError("Could not save the lesson", error)
            }
        }
    }

    func updateLesson(_ lesson: WizardLesson, text: String? = nil, pinned: Bool? = nil) {
        guard let database else { return }
        let newText = text ?? lesson.text
        let newPinned = pinned ?? lesson.pinned
        Task {
            do {
                try await database.updateLesson(id: lesson.id, text: newText, pinned: newPinned)
                lessons = try await database.fetchLessons()
            } catch {
                presentError("Could not update the lesson", error)
            }
        }
    }

    func deleteLesson(_ lesson: WizardLesson) {
        guard let database else { return }
        Task {
            do {
                try await database.deleteLesson(id: lesson.id)
                lessons.removeAll { $0.id == lesson.id }
            } catch {
                presentError("Could not delete the lesson", error)
            }
        }
    }

    // MARK: - Clip Builder

    /// Render the builder timeline through the multitrack pipeline and file
    /// the result into the Library. Mirrors the runWizard job pattern.
    func renderBuilderTimeline() {
        guard let database, !isBuilderRendering else { return }
        guard !builder.document.videoTrack.isEmpty else {
            presentError("Add clips to the timeline first.")
            return
        }
        isBuilderRendering = true
        builderLog = []
        let document = builder.document
        let scenes = builder.scenes
        let profile = activeProfile
        let renderer = multitrackRenderer
        builderRenderTask = Task {
            do {
                // The Builder honors the wizard's Center Stage camera preset.
                let camera = UserDefaults.standard.string(forKey: "wizard.centerStageCamera") ?? "balanced"
                let result = try await renderer.render(document: document, scenes: scenes,
                                                       profile: profile, database: database,
                                                       centerStageCamera: camera) { message in
                    Task { @MainActor in self.builderLog.append(message) }
                }
                builderLog.append("Done: \(result.url.lastPathComponent) (\(result.duration.timecode))")
            } catch is CancellationError {
                builderLog.append("Render stopped.")
            } catch {
                builderLog.append("Failed: \(error.userMessage)")
                presentError("Builder render failed", error)
            }
            isBuilderRendering = false
            refreshAll()
        }
    }

    func cancelBuilderRender() {
        builderRenderTask?.cancel()
    }

    // MARK: - Curated wizard

    var isCuratedRendering = false
    /// An exact (real-pipeline) preview render is in flight for the wizard.
    var isCuratedPreviewRendering = false

    /// Render a curated-wizard document through the Builder's multitrack
    /// pipeline, logging into the wizard's Generation Log. The branded outro
    /// card (a wizard-assemble feature the multitrack renderer doesn't have)
    /// is pre-rendered here and appended as a plain video clip.
    func renderCuratedDocument(_ document: TimelineDocument, includeOutro: Bool) {
        guard let database, !isCuratedRendering else { return }
        isCuratedRendering = true
        wizardLog.append("— Curated video: rendering \(document.videoTrack.count) clip(s) —")
        let profile = activeProfile
        let renderer = multitrackRenderer
        let scenes = self.scenes
        Task {
            do {
                let document = try await curatedDocument(document, includeOutro: includeOutro,
                                                         profile: profile)
                let camera = UserDefaults.standard.string(forKey: "wizard.centerStageCamera") ?? "balanced"
                let result = try await renderer.render(document: document, scenes: scenes,
                                                       profile: profile, database: database,
                                                       centerStageCamera: camera) { message in
                    Task { @MainActor in self.wizardLog.append(message) }
                }
                wizardLog.append("VIDEO:\(result.url.lastPathComponent):\(String(format: "%.1f", result.duration))")
            } catch is CancellationError {
                wizardLog.append("Curated render stopped.")
            } catch {
                wizardLog.append("Error: \(error.userMessage)")
                presentError("Curated video render failed", error)
            }
            isCuratedRendering = false
            refreshAll()
        }
    }

    /// The curated document exactly as a render receives it — the branded
    /// outro card appended when enabled. Shared by Generate and the exact
    /// preview so both see the same timeline.
    private func curatedDocument(_ document: TimelineDocument, includeOutro: Bool,
                                 profile: BrandProfile) async throws -> TimelineDocument {
        var document = document
        if includeOutro,
           profile.logoURL != nil || !(profile.socials["instagram"]?.handle ?? "").isEmpty {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("CuratedOutro-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            if let png = BrandRenderer.outroCard(profile: profile, to: scratch) {
                let card = scratch.appendingPathComponent("outro_card.mp4")
                try await BrandRenderer.cardClip(png: png, duration: 2.5, output: card)
                var clip = TimelineClip()
                clip.videoFile = card.path
                clip.sourceStart = 0
                clip.sourceEnd = 2.5
                clip.duration = 2.5
                clip.startTime = document.videoTrack.map { $0.startTime + $0.duration }.max() ?? 0
                clip.transIn = "fadeblack"
                document.videoTrack.append(clip)
                wizardLog.append("Branded outro card appended")
            }
        }
        return document
    }

    /// Exact preview for the curated wizard: the REAL render pipeline
    /// (framing, transitions, music, overlays, outro — identical output) to
    /// a temporary file the reel preview plays. Nothing lands in the
    /// Library. Returns nil on failure or cancellation.
    func renderCuratedExactPreview(_ document: TimelineDocument,
                                   includeOutro: Bool) async -> URL? {
        guard let database, !isCuratedPreviewRendering else { return nil }
        isCuratedPreviewRendering = true
        defer { isCuratedPreviewRendering = false }
        wizardLog.append("— Exact preview: rendering \(document.videoTrack.count) clip(s) —")
        let profile = activeProfile
        let renderer = multitrackRenderer
        let scenes = self.scenes
        do {
            let document = try await curatedDocument(document, includeOutro: includeOutro,
                                                     profile: profile)
            let camera = UserDefaults.standard.string(forKey: "wizard.centerStageCamera") ?? "balanced"
            let result = try await renderer.render(document: document, scenes: scenes,
                                                   profile: profile, database: database,
                                                   centerStageCamera: camera,
                                                   preview: true) { message in
                Task { @MainActor in self.wizardLog.append(message) }
            }
            return result.url
        } catch is CancellationError {
            wizardLog.append("Exact preview stopped.")
            return nil
        } catch {
            wizardLog.append("Exact preview failed: \(error.userMessage)")
            presentError("Exact preview failed", error)
            return nil
        }
    }

    // MARK: - Fight research

    /// Best-effort fight identity for the confirm sheet: named people on the
    /// video, the extracted outcome, and the filename.
    func guessFightIdentity(video: VideoRecord) async -> FightResearchService.Identity {
        guard let database else { return FightResearchService.Identity() }
        let keys = ((try? await database.fetchVideoPeople(videoID: video.id)) ?? []).map(\.key)
        let outcomes = ((try? await database.fetchOutcomes()) ?? [])
            .filter { $0.videoID == video.id }
        return FightResearchService.guessIdentity(video: video, people: people,
                                                  videoPersonKeys: keys, outcomes: outcomes)
    }

    /// Run (or re-run) the crawl + summarize for one video, then refresh the
    /// cached dictionary. Throws with actionable messages.
    func runFightResearch(video: VideoRecord, identity: FightResearchService.Identity,
                          log: @escaping @Sendable (String) -> Void) async throws -> FightResearchRecord {
        guard let database else {
            throw AIError.notConfigured("No profile database is open")
        }
        guard !fightResearchInFlight.contains(video.id) else {
            throw AIError.notConfigured("Research is already running for this video")
        }
        fightResearchInFlight.insert(video.id)
        defer { fightResearchInFlight.remove(video.id) }
        let record = try await fightResearchService.run(video: video, identity: identity,
                                                        profile: activeProfile,
                                                        database: database, emit: log)
        fightResearch[video.id] = record
        return record
    }

    /// Column-level refresh: re-crawl with the saved identity, logging into
    /// the analysis log panel.
    func refreshFightResearch(video: VideoRecord) {
        guard let existing = fightResearch[video.id],
              !fightResearchInFlight.contains(video.id) else { return }
        let identity = FightResearchService.Identity(fighters: existing.fightLabel,
                                                     event: existing.event,
                                                     date: existing.fightDate)
        Task {
            do {
                _ = try await runFightResearch(video: video, identity: identity) { message in
                    Task { @MainActor in self.analysisLog.append("Fight research: \(message)") }
                }
            } catch {
                presentError("Fight research failed for \(video.filename)", error)
            }
        }
    }

    /// User edits from the research sheet — identity + story only; the
    /// crawled sources and timestamp stay.
    func saveFightResearchEdits(videoID: Int64, fightLabel: String, event: String,
                                fightDate: String, summaryJSON: String) {
        guard let database else { return }
        Task {
            do {
                try await database.updateFightResearch(videoID: videoID, fightLabel: fightLabel,
                                                       event: event, fightDate: fightDate,
                                                       summaryJSON: summaryJSON)
                if var record = fightResearch[videoID] {
                    record.fightLabel = fightLabel
                    record.event = event
                    record.fightDate = fightDate
                    record.summaryJSON = summaryJSON
                    fightResearch[videoID] = record
                }
            } catch {
                presentError("Could not save the fight research edits", error)
            }
        }
    }

    /// Manual (re-)run of the fight-scoring pass for one video — the same
    /// pass that runs automatically at the end of analysis.
    func scoreFightAction(video: VideoRecord) {
        guard let database, !fightScoringInFlight.contains(video.id) else { return }
        fightScoringInFlight.insert(video.id)
        let profile = activeProfile
        Task {
            do {
                let scenes = ((try? await database.fetchScenes(includeExcluded: true)) ?? [])
                    .filter { $0.videoID == video.id }
                _ = try await analyzer.scoreFightAction(
                    video: video, scenes: scenes, profile: profile, database: database,
                    log: { message in
                        Task { @MainActor in self.analysisLog.append(message) }
                    })
                let events = (try? await database.fetchFightEvents()) ?? []
                fightEvents = Dictionary(grouping: events, by: \.videoID)
            } catch {
                presentError("Fight scoring failed for \(video.filename)", error)
            }
            fightScoringInFlight.remove(video.id)
        }
    }

    /// Load a curated-wizard document into the Builder for detail work.
    func openCuratedInBuilder(_ document: TimelineDocument) {
        builder.loadDocument(document)
        requestedSection = .builder
    }

    /// Load a generated video's saved timeline back into the builder.
    /// Videos rendered before documents were persisted stored a flat legacy
    /// format — those get a best-effort conversion (clips, transitions,
    /// music; their burned-in overlays were never recorded).
    func openInBuilder(_ video: GeneratedVideoRecord) {
        var document = video.timelineJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(TimelineDocument.self, from: $0) }
        if document?.videoTrack.isEmpty != false {
            let sceneMap = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
            document = WizardEngine.legacyTimelineDocument(fromFlat: video.timelineJSON,
                                                           scenes: sceneMap)
        }
        guard let document, !document.videoTrack.isEmpty else {
            presentError("This video's timeline couldn't be read, so it can't be edited in the Builder.")
            return
        }
        builder.loadDocument(document)
        requestedSection = .builder
    }

    // MARK: - Wizard

    /// "Generate Video" from the Analyze tab: hand the description to the
    /// Wizard immediately (so the user lands on a live form), then analyze
    /// any un-analyzed selections and AI-parse the description into settings,
    /// updating the handoff in place. A failed parse degrades to passing the
    /// raw description as instructions — this never blocks the wizard.
    func generateSampleVideo(description: String, videos: [VideoRecord]) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !videos.isEmpty else { return }
        let unanalyzed = videos.filter { $0.visualAnalyzedAt == nil }
        let willAnalyze = !unanalyzed.isEmpty && !isAnalyzing
        pendingWizardPrompt = WizardPromptHandoff(
            description: trimmed,
            videoIDs: Set(videos.map(\.id)),
            statusMessage: willAnalyze
                ? "Analyzing \(unanalyzed.count) video(s), then interpreting your request…"
                : "Interpreting your request…")
        requestedSection = .wizard
        Task {
            if willAnalyze {
                analyze(videos: unanalyzed)
                await analysisTask?.value
                guard pendingWizardPrompt?.description == trimmed else { return }
                pendingWizardPrompt?.statusMessage = "Interpreting your request…"
            }
            await interpretWizardPrompt(trimmed)
        }
    }

    /// "Generate Video" from the Scenes/People screens: the currently
    /// displayed scenes are the source, so their analyze batches plus the
    /// active people/tag filters ride into the Wizard alongside the parsed
    /// description. Scenes only exist for analyzed footage, so there is no
    /// analyze-first step here.
    func generateSampleVideo(description: String, scenes: [SceneRecord],
                             personKeys: Set<String>, tags: [String]) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !scenes.isEmpty else { return }
        pendingWizardPrompt = WizardPromptHandoff(
            description: trimmed,
            videoIDs: [],
            runIDs: Set(scenes.compactMap(\.runID)),
            personKeys: personKeys,
            tags: tags,
            statusMessage: "Interpreting your request…")
        requestedSection = .wizard
        Task { await interpretWizardPrompt(trimmed) }
    }

    /// AI-parse a "Generate Video" description into settings, updating the
    /// pending handoff in place.
    private func interpretWizardPrompt(_ trimmed: String) async {
        let profile = activeProfile
        let wizard = wizard
        do {
            let parsed = try await wizard.parseRequest(description: trimmed, profile: profile) { message in
                Task { @MainActor in self.wizardLog.append(message) }
            }
            // The user may have dismissed or replaced the request meanwhile.
            guard pendingWizardPrompt?.description == trimmed else { return }
            pendingWizardPrompt?.parsed = parsed
            pendingWizardPrompt?.statusMessage = nil
        } catch {
            guard pendingWizardPrompt?.description == trimmed else { return }
            pendingWizardPrompt?.statusMessage = nil
            pendingWizardPrompt?.parseFailed = true
            wizardLog.append("Could not interpret the request with AI — it will be passed to the wizard as-is. (\(error.userMessage))")
        }
    }

    func runWizard(options: WizardOptions) {
        guard let database, !isWizardRunning else { return }
        isWizardRunning = true
        wizardLog = []
        lastWizardOptions = options
        wizardFailureMessage = nil
        wizardStatus = WizardRunStatus(stage: "Starting…", fraction: 0)
        let profile = activeProfile
        let wizard = wizard
        let previousIDs = Set(generatedVideos.map(\.id))
        wizardTask = Task {
            await wizard.run(options: options, profile: profile, database: database) { message in
                Task { @MainActor in
                    self.wizardLog.append(message)
                    self.updateWizardStatus(from: message)
                }
            }
            isWizardRunning = false
            wizardStatus = nil
            await refreshAllNow()
            // Results sheet first (watch/rate/retry); any A/B comparison
            // queued below appears after it is dismissed.
            let fresh = generatedVideos
                .filter { !previousIDs.contains($0.id) }
                .sorted { $0.id < $1.id }
            if !fresh.isEmpty {
                wizardResults = WizardRunResults(videos: fresh)
            } else if !Task.isCancelled {
                // Nothing produced and the user didn't stop it — surface the
                // failure where the user is looking instead of leaving only a
                // red line in the log scrollback.
                wizardFailureMessage = Self.failureSummary(from: wizardLog)
            }
            queueComparisons(previousIDs: previousIDs)
        }
    }

    /// Re-run the wizard with the same options as the last run.
    func retryWizard() {
        guard let options = lastWizardOptions else { return }
        wizardResults = nil
        runWizard(options: options)
    }

    /// Resolve a generated video's filename (as logged) to its file URL.
    /// Falls back to scanning the profile's dated output folders because the
    /// cached record list only refreshes after the run finishes.
    func generatedVideoURL(named filename: String) -> URL? {
        if let record = generatedVideos.first(where: { $0.filename == filename }) {
            return record.url
        }
        let root = activeProfile.outputFolderURL
        let dated = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for directory in dated.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let candidate = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Map engine log lines onto stage + overall progress: planning ~0-0.3,
    /// assembly 0.3-0.9, caption 0.9-1. Unknown lines leave the status
    /// untouched.
    private func updateWizardStatus(from rawMessage: String) {
        // Phase lines arrive with leading newlines for log readability.
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        func set(_ stage: String, detail: String = "", fraction: Double) {
            var status = wizardStatus ?? WizardRunStatus(stage: stage, fraction: 0)
            if status.stage != stage {
                status.stage = stage
                status.stageChangedAt = Date()
            }
            status.detail = detail
            status.fraction = min(1, max(status.fraction, fraction))
            wizardStatus = status
        }

        if message.hasPrefix("Phase 1") {
            set("Researching what performs on Reels", fraction: 0)
        } else if message.hasPrefix("Loading scenes") {
            set("Loading your scenes and music", fraction: 0.02)
        } else if message.hasPrefix("Phase 2: Planning the timeline") {
            set("Planning the timeline",
                detail: "The AI is designing the edit — this step can take a few minutes.",
                fraction: 0.05)
        } else if message.hasPrefix("Plan: ") {
            set("Plan ready", fraction: 0.3)
        } else if message.hasPrefix("Phase 3: Assembling") {
            set("Assembling the video",
                detail: "Cutting clips and burning in overlays.",
                fraction: 0.32)
        } else if let range = message.range(of: #"clip (\d+)/(\d+)"#, options: .regularExpression) {
            let parts = message[range].dropFirst(5).split(separator: "/")
            if parts.count == 2, let index = Double(parts[0]), let total = Double(parts[1]), total > 0 {
                set("Cutting clip \(Int(index)) of \(Int(total))",
                    detail: "Extracting and styling each planned clip.",
                    fraction: 0.32 + 0.5 * (index / total))
            }
        } else if message.hasPrefix("Assembling ") {
            set("Joining clips with transitions", fraction: 0.85)
        } else if message.hasPrefix("Adding music") {
            set("Adding music", fraction: 0.9)
        } else if message.hasPrefix("Generating Instagram caption") {
            set("Writing the Instagram caption", fraction: 0.93)
        } else if message.contains(" complete! ") {
            set("Finishing up", fraction: 0.97)
        } else if message.hasPrefix("All done!") {
            set("Done", fraction: 1)
        }
    }

    /// New multi-variation batches from the finished run become A/B picks;
    /// each choice is preference data for future generations.
    private func queueComparisons(previousIDs: Set<Int64>) {
        let fresh = generatedVideos.filter { !previousIDs.contains($0.id) && $0.batchID != nil }
        let batches = Dictionary(grouping: fresh) { $0.batchID! }
            .filter { $0.value.count > 1 }
            .map { ComparisonBatch(id: $0.key, videos: $0.value.sorted { $0.id < $1.id }) }
            .sorted { ($0.videos.first?.id ?? 0) < ($1.videos.first?.id ?? 0) }
        guard !batches.isEmpty else { return }
        comparisonQueue = batches
        pendingComparison = batches.first
    }

    func cancelWizard() {
        wizardTask?.cancel()
    }

    /// The most useful line of a failed run's log: the DONE:error payload
    /// when the engine reported one, else the last error-prefixed line.
    private static func failureSummary(from log: [String]) -> String {
        if let done = log.last(where: { $0.hasPrefix("DONE:error") }) {
            let detail = done.dropFirst("DONE:error".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return detail.isEmpty ? "The generation failed." : detail
        }
        if let error = log.last(where: { $0.hasPrefix("Error") }) {
            return error
        }
        return "The run finished without producing a video — see the log for details."
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
    /// the installer can replace the app cleanly.
    func installUpdate(_ update: AppUpdate) {
        guard !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        Task {
            do {
                let pkg = try await UpdateService.downloadInstaller(update)
                UpdateService.launchInstaller(at: pkg)
                NSApp.terminate(nil)
            } catch {
                presentError("Could not download the update", error)
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
            analysisLog.append("\(missing.joined(separator: ", ")) not installed — installing now...")
            do {
                try await ToolInstaller.installMissing { message in
                    Task { @MainActor in self.analysisLog.append(message) }
                }
                analysisLog.append("All required tools are ready.")
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
        analysisLog.append("Installing \(label)...")
        Task {
            do {
                try await ProviderCLIInstaller.install(key) { message in
                    Task { @MainActor in self.analysisLog.append(message) }
                }
            } catch {
                presentError("Could not install \(label)", error)
            }
            installingProviderCLIs.remove(key)
        }
    }

    // MARK: - Instagram

    /// Load cached accounts (+ media for the remembered selection) — called
    /// from openActiveProfile alongside the other list loads.
    func loadInstagramCache() {
        guard let database else { return }
        Task {
            do {
                let accounts = try await database.fetchIGAccounts()
                igAccounts = accounts
                if igSelectedAccountID == nil || !accounts.contains(where: { $0.id == igSelectedAccountID }) {
                    igSelectedAccountID = accounts.first?.id
                }
                try await reloadIGMedia()
            } catch {
                presentError("Could not load Instagram cache", error)
            }
        }
    }

    private func reloadIGMedia() async throws {
        guard let database, let accountID = igSelectedAccountID else {
            igMedia = []
            igTemplatedMediaIDs = []
            return
        }
        igMedia = try await database.fetchIGMedia(accountID: accountID)
        igTemplatedMediaIDs = try await database.fetchIGTemplateMediaIDs(accountID: accountID)
    }

    func selectInstagramAccount(_ id: Int64?) {
        igSelectedAccountID = id
        guard let account = igAccounts.first(where: { $0.id == id }) else {
            igMedia = []
            return
        }
        Task {
            try? await reloadIGMedia()
            // Auto-refresh only when stale — the grid shows cache instantly.
            let stale = account.lastFetchedAt.map {
                Date().timeIntervalSince($0) > InstagramService.autoRefreshInterval
            } ?? true
            if stale && !isFetchingInstagram {
                refreshInstagram(username: account.username)
            }
        }
    }

    func addInstagramAccount(handle: String) {
        let username = handle.trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\t"))
        guard !username.isEmpty else { return }
        let ownHandle = activeProfile.socials["instagram"]?.handle
            .trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) ?? ""
        let isOwn = username.caseInsensitiveCompare(ownHandle) == .orderedSame
            || username.caseInsensitiveCompare(settings.instagram.connectedUsername) == .orderedSame
        let kind = isOwn ? "own" : "public"
        guard let database else { return }
        Task {
            do {
                let id = try await database.upsertIGAccount(username: username, kind: kind,
                                                            displayName: nil, igUserID: nil, followers: nil)
                igAccounts = try await database.fetchIGAccounts()
                igSelectedAccountID = id
                igMedia = []
                refreshInstagram(username: username)
            } catch {
                presentError("Could not add the account", error)
            }
        }
    }

    func removeInstagramAccount(_ account: IGAccountRecord) {
        guard let database else { return }
        Task {
            try? await database.deleteIGAccount(id: account.id)
            igAccounts = (try? await database.fetchIGAccounts()) ?? []
            if igSelectedAccountID == account.id {
                igSelectedAccountID = igAccounts.first?.id
                try? await reloadIGMedia()
            }
        }
    }

    func refreshInstagram(username: String) {
        guard let database, !isFetchingInstagram else { return }
        isFetchingInstagram = true
        igLog = []
        let settings = settings.instagram
        let account = igAccounts.first { $0.username.caseInsensitiveCompare(username) == .orderedSame }
        let kind = account?.kind ?? "public"
        let instagram = instagram
        igFetchTask = Task {
            do {
                try await instagram.refreshAccount(username: username, kind: kind,
                                                   database: database, settings: settings,
                                                   limit: settings.fetchLimit) { message in
                    Task { @MainActor in self.igLog.append(message) }
                }
                igAccounts = try await database.fetchIGAccounts()
                try await reloadIGMedia()
            } catch is CancellationError {
                igLog.append("Fetch stopped.")
            } catch {
                presentError("Instagram fetch failed", error)
            }
            isFetchingInstagram = false
        }
    }

    func cancelInstagramFetch() {
        igFetchTask?.cancel()
    }

    /// Download (if needed) and AI-analyze one reel into a cached template.
    func analyzeInstagramTemplate(media: IGMediaRecord, force: Bool = false,
                                  provider: String? = nil, model: String? = nil) {
        guard let database,
              let account = igAccounts.first(where: { $0.id == media.accountID }),
              !igAnalyzingMediaIDs.contains(media.id) else { return }
        igAnalyzingMediaIDs.insert(media.id)
        let settings = settings.instagram
        let instagram = instagram
        igAnalyzeTasks[media.id] = Task {
            do {
                try await instagram.analyzeTemplate(media: media, account: account,
                                                    database: database, settings: settings,
                                                    force: force,
                                                    provider: provider, model: model) { message in
                    Task { @MainActor in self.igLog.append(message) }
                }
                igTemplatedMediaIDs.insert(media.id)
                // Pick up the local_video_path the download wrote.
                try? await reloadIGMedia()
            } catch {
                presentError("Template analysis failed", error)
            }
            igAnalyzingMediaIDs.remove(media.id)
            igAnalyzeTasks[media.id] = nil
        }
    }

    func cancelInstagramAnalysis(mediaID: Int64) {
        igAnalyzeTasks[mediaID]?.cancel()
    }

    /// Download a reel without analyzing it — enough for inline playback.
    /// Returns the local file URL, or nil on failure (error already shown).
    func downloadInstagramReel(media: IGMediaRecord) async -> URL? {
        guard let database,
              let account = igAccounts.first(where: { $0.id == media.accountID }) else { return nil }
        igDownloadingMediaIDs.insert(media.id)
        defer { igDownloadingMediaIDs.remove(media.id) }
        do {
            let url = try await instagram.ensureDownloaded(
                media: media, account: account, database: database,
                settings: settings.instagram) { message in
                Task { @MainActor in self.igLog.append(message) }
            }
            try? await reloadIGMedia()
            return url
        } catch {
            presentError("Reel download failed", error)
            return nil
        }
    }

    /// The cached template analysis for a reel, decoded — nil if never analyzed.
    func instagramTemplate(mediaID: Int64) async -> ReelTemplate? {
        guard let database,
              let record = try? await database.fetchIGTemplate(mediaID: mediaID) else { return nil }
        return try? JSONDecoder().decode(ReelTemplate.self, from: Data(record.templateJSON.utf8))
    }

    // MARK: - Curation

    func curateScene(_ scene: SceneRecord, curated: Bool) {
        guard let database else { return }
        Task {
            try? await database.setSceneCurated(scene.id, curated: curated)
            refreshAll()
        }
    }

    /// Apply a curation trim/extend. Passing the original range clears the
    /// override. A stored camera path is recomputed for the new range so the
    /// preview stays truthful.
    func setSceneEditRange(_ scene: SceneRecord, start: Double, end: Double) {
        guard let database, end > start else { return }
        let clearing = abs(start - scene.originalStart) < 0.05
            && abs(end - scene.originalEnd) < 0.05
        Task {
            try? await database.setSceneEditRange(scene.id,
                                                  start: clearing ? nil : start,
                                                  end: clearing ? nil : end)
            if scene.centerStagePathJSON != nil, let stored = scene.centerStagePath {
                await computeCameraPath(sceneID: scene.id, videoID: scene.videoID,
                                        start: clearing ? scene.originalStart : start,
                                        end: clearing ? scene.originalEnd : end,
                                        camera: stored.camera)
            }
            refreshAll()
        }
    }

    /// Compute (or refresh) one scene's Center Stage path over a range,
    /// honoring markers, ignores, and hints.
    func computeCameraPath(sceneID: Int64, videoID: Int64,
                           start: Double, end: Double, camera: String) async {
        guard let database, end > start,
              let video = videos.first(where: { $0.id == videoID }) else { return }
        let centerStage = CenterStageService()
        let markers = (try? await database.personMarkers(videoID: videoID)) ?? []
        let named = markers.filter { $0.personID != nil && !$0.ignored }
        let ignored = markers.filter(\.ignored)
        let portraits = named.isEmpty ? []
            : await Analyzer.markerPortraits(url: video.url, markers: named,
                                             duration: video.duration)
        let avoidPortraits = ignored.isEmpty ? []
            : await Analyzer.markerPortraits(url: video.url, markers: ignored,
                                             duration: video.duration)
        let hints = ((try? await database.centerStageHints(videoID: videoID)) ?? [])
            .filter { $0.atTime >= start - 0.25 && $0.atTime <= end + 0.25 }
            .map { hint in
                (time: min(max(0, hint.atTime - start), end - start),
                 crop: CGRect(x: hint.x, y: hint.y, width: hint.width, height: hint.height))
            }
        guard let result = try? await centerStage.cameraPath(
                source: video.url, start: start, duration: end - start,
                focusPortraits: portraits, avoidPortraits: avoidPortraits,
                hints: hints, tuning: .named(camera)),
              result.keyframes.count >= 2 else { return }
        let path = SceneCameraPath(camera: camera, keyframes: result.keyframes)
        if let data = try? JSONEncoder().encode(path),
           let json = String(data: data, encoding: .utf8) {
            try? await database.setSceneCenterStagePath(sceneID, json: json)
        }
        refreshAll()
    }

    // MARK: - People-only pass

    /// A people-only detection is running (one at a time).
    var isDetectingPeople = false

    func videoPeople(for videoID: Int64) async -> [VideoPersonRecord] {
        guard let database else { return [] }
        return (try? await database.fetchVideoPeople(videoID: videoID)) ?? []
    }

    /// Run (or re-run) the people-only AI pass for one video and return the
    /// fresh roster. Provider/model override the dispatcher's routing (the
    /// analyze sheet passes its picker's live choice).
    func detectPeopleInVideo(_ video: VideoRecord,
                             provider: String? = nil,
                             model: String? = nil) async -> [VideoPersonRecord] {
        guard let database, !isDetectingPeople else { return [] }
        isDetectingPeople = true
        defer { isDetectingPeople = false }
        do {
            let (roster, suggestedFilename) = try await analyzer.detectPeopleOnly(
                video: video, profile: activeProfile, database: database,
                provider: provider, model: model) { message in
                Task { @MainActor in self.analysisLog.append(message) }
            }
            // A filename fix the pass noticed (auto-generated or misspelled
            // name) goes through the same review sheet as end-of-analysis
            // proposals — it presents once no other sheet is in the way.
            if let suggestedFilename {
                pendingRenameReview = RenameReviewRequest(suggestions: [
                    RenameSuggestion(videoID: video.id,
                                     currentFilename: video.filename,
                                     suggestedName: suggestedFilename),
                ])
            }
            refreshAll()
            return roster
        } catch {
            presentError("People detection failed", error)
            return (try? await database.fetchVideoPeople(videoID: video.id)) ?? []
        }
    }

    // MARK: - Framing pass

    /// A framing-detection pass is running (one at a time).
    var isDetectingFraming = false
    var framingProgress = 0.0

    /// Run (or re-run) the local framing pass for one video: a 9:16 rect
    /// (static) or camera path per scene, plus optional framed: people tags.
    func detectFraming(video: VideoRecord, camera: String, tagFramedPeople: Bool) async {
        guard let database, !isDetectingFraming else { return }
        isDetectingFraming = true
        framingProgress = 0
        defer { isDetectingFraming = false }
        do {
            _ = try await FramingService.detectFraming(
                video: video, database: database, camera: camera,
                tagFramedPeople: tagFramedPeople,
                log: { message in
                    Task { @MainActor in self.analysisLog.append(message) }
                },
                progress: { fraction in
                    Task { @MainActor in self.framingProgress = fraction }
                })
            refreshAll()
        } catch {
            presentError("Framing detection failed", error)
        }
    }

    // MARK: - Center Stage hints

    func centerStageHints(for videoID: Int64) async -> [CameraHint] {
        guard let database else { return [] }
        return (try? await database.centerStageHints(videoID: videoID)) ?? []
    }

    /// Save a user-framed camera hint and immediately recompute the stored
    /// paths of the scenes covering its moment. Returns the fresh hint list.
    func addCameraHint(videoID: Int64, at time: Double, rect: CGRect) async -> [CameraHint] {
        guard let database else { return [] }
        try? await database.addCenterStageHint(videoID: videoID, at: time,
                                               x: rect.minX, y: rect.minY,
                                               width: rect.width, height: rect.height)
        recomputeCenterStagePaths(videoID: videoID, around: time)
        return (try? await database.centerStageHints(videoID: videoID)) ?? []
    }

    func updateCameraHint(_ hint: CameraHint) async -> [CameraHint] {
        guard let database else { return [] }
        try? await database.updateCenterStageHint(hint)
        recomputeCenterStagePaths(videoID: hint.videoID, around: hint.atTime)
        return (try? await database.centerStageHints(videoID: hint.videoID)) ?? []
    }

    func deleteCameraHint(_ hint: CameraHint) async -> [CameraHint] {
        guard let database else { return [] }
        try? await database.deleteCenterStageHint(id: hint.id)
        recomputeCenterStagePaths(videoID: hint.videoID, around: hint.atTime)
        return (try? await database.centerStageHints(videoID: hint.videoID)) ?? []
    }

    /// Re-run the tracking pass for the stored camera paths of scenes
    /// covering `time` (nil = every scene of the video), so previews reflect
    /// an edited hint or ignore marker without a full re-analysis. Local
    /// only; runs in the background.
    private func recomputeCenterStagePaths(videoID: Int64, around time: Double?) {
        guard let database else { return }
        let affected = scenes.filter { scene in
            guard scene.videoID == videoID, scene.centerStagePathJSON != nil else { return false }
            guard let time else { return true }
            return scene.startTime - 0.25 <= time && time <= scene.endTime + 0.25
        }
        guard !affected.isEmpty,
              let video = videos.first(where: { $0.id == videoID }) else { return }
        Task {
            let centerStage = CenterStageService()
            let markers = (try? await database.personMarkers(videoID: videoID)) ?? []
            let named = markers.filter { $0.personID != nil && !$0.ignored }
            let ignored = markers.filter(\.ignored)
            let portraits = named.isEmpty ? []
                : await Analyzer.markerPortraits(url: video.url, markers: named,
                                                 duration: video.duration)
            let avoidPortraits = ignored.isEmpty ? []
                : await Analyzer.markerPortraits(url: video.url, markers: ignored,
                                                 duration: video.duration)
            let hints = (try? await database.centerStageHints(videoID: videoID)) ?? []
            // The framing moved, so who's inside it may have too — refresh
            // the framed: tags along with the paths (when the option is on).
            let tagFramed = (UserDefaults.standard.object(forKey: "analysis.framingTagPeople") as? Bool) ?? true
            let peopleReferences = tagFramed
                ? await FramingService.personSignatures(video: video, database: database) : []
            for scene in affected {
                guard let stored = scene.centerStagePath else { continue }
                // Static framings re-derive their rect (the edited hint wins
                // verbatim) — the tracker would turn them into moving paths.
                let path: SceneCameraPath?
                if stored.camera == FramingService.staticCamera {
                    path = await FramingService.staticScenePath(video: video, scene: scene,
                                                                hints: hints)
                } else {
                    let sceneHints = hints
                        .filter { $0.atTime >= scene.startTime - 0.25 && $0.atTime <= scene.endTime + 0.25 }
                        .map { hint in
                            (time: min(max(0, hint.atTime - scene.startTime), scene.duration),
                             crop: CGRect(x: hint.x, y: hint.y, width: hint.width, height: hint.height))
                        }
                    if let result = try? await centerStage.cameraPath(
                            source: video.url, start: scene.startTime, duration: scene.duration,
                            focusPortraits: portraits, avoidPortraits: avoidPortraits,
                            hints: sceneHints,
                            tuning: .named(stored.camera)),
                       result.keyframes.count >= 2 {
                        path = SceneCameraPath(camera: stored.camera, keyframes: result.keyframes)
                    } else {
                        path = nil
                    }
                }
                guard let path,
                      let data = try? JSONEncoder().encode(path),
                      let json = String(data: data, encoding: .utf8) else { continue }
                try? await database.setSceneCenterStagePath(scene.id, json: json)
                if tagFramed {
                    await FramingService.retagFramedPeople(video: video, scene: scene,
                                                           path: path, database: database,
                                                           people: peopleReferences)
                }
            }
            refreshAll()
        }
    }

    /// A marker's ignore flag changed — its effect spans the whole video,
    /// so every stored path of that video gets refreshed in the background.
    func markerIgnoreChanged(videoID: Int64) {
        recomputeCenterStagePaths(videoID: videoID, around: nil)
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
                    igLog.append("Learning from reel \(index + 1)/\(media.count)…")
                }
                do {
                    let video = try await instagram.ensureDownloaded(
                        media: item, account: account,
                        database: database, settings: settings) { message in
                        Task { @MainActor in self.igLog.append(message) }
                    }
                    let label = try await runTasteStudy(
                        video: video, label: "@\(account.username) reel",
                        performance: Self.performanceLine(item),
                        mediaID: item.id,
                        provider: provider, model: model) { message in
                        Task { @MainActor in self.igLog.append(message) }
                    }
                    igLog.append("Learned into “\(label)”")
                } catch {
                    igLog.append("Skipped a reel — \(error.userMessage)")
                }
            }
            try? await reloadIGMedia()
            igLog.append("Taste learning finished — review the video types in Settings → Profile")
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
                                            performance: "", mediaID: nil) { message in
                    Task { @MainActor in self.analysisLog.append(message) }
                }
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
    func connectInstagram(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isConnectingInstagram else { return }
        isConnectingInstagram = true
        Task {
            do {
                let account = try await GraphAPIProvider(token: trimmed, igUserID: nil)
                    .resolveAccount(matching: nil)
                try KeychainStore.save(trimmed, account: KeychainStore.graphTokenAccount)
                settings.instagram.connectedUsername = account.username
                settings.instagram.connectedIGUserID = account.id
                saveSettings()
                // Make the connected account browsable right away.
                addInstagramAccount(handle: account.username)
            } catch {
                presentError("Could not connect the Instagram account", error)
            }
            isConnectingInstagram = false
        }
    }

    /// Publish a Library video to the connected Instagram account as a Reel.
    /// Progress lines stream to `log`; throws with an actionable message on
    /// failure. On success the connected account refreshes so the new reel
    /// shows up in the Instagram tab.
    func publishReelToInstagram(video: GeneratedVideoRecord, caption: String,
                                shareToFeed: Bool,
                                log: @escaping @Sendable (String) -> Void)
        async throws -> GraphAPIProvider.PublishedReel {
        if video.qualityReport?.verdict == .blocked {
            throw InstagramError.fetchFailed(
                "This reel failed the release-quality gate. Open it in Builder and render a corrected version before publishing.")
        }
        guard !isPublishingToInstagram else {
            throw InstagramError.fetchFailed("Another publish is already running")
        }
        isPublishingToInstagram = true
        defer { isPublishingToInstagram = false }
        let result = try await instagram.publishReel(file: video.url, caption: caption,
                                                     shareToFeed: shareToFeed,
                                                     settings: settings.instagram, log: log)
        if let database {
            try? await database.markGeneratedVideoPublished(id: video.id,
                                                            instagramMediaID: result.mediaID)
            generatedVideos = (try? await database.fetchGeneratedVideos()) ?? generatedVideos
        }
        let username = settings.instagram.connectedUsername
        if !username.isEmpty {
            refreshInstagram(username: username)
        }
        return result
    }

    func disconnectInstagram() {
        KeychainStore.delete(account: KeychainStore.graphTokenAccount)
        settings.instagram.connectedUsername = ""
        settings.instagram.connectedIGUserID = ""
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
        Task {
            guard let templateJSON = await fetchTemplateJSON(mediaID: media.id) else { return }
            var options = WizardOptions()
            options.templateJSON = templateJSON
            options.templateLabel = templateLabel(for: media)
            // Overlays land as editable timeline items here, not burned in.
            options.enableTextOverlays = true
            planIntoBuilder(options: options)
        }
    }

    /// The Builder pre-fill job: wizard planning only, then load the plan as
    /// a timeline document. Opens the Builder immediately — a loading overlay
    /// there (isPlanningIntoBuilder) shows progress while the plan runs.
    func planIntoBuilder(options: WizardOptions) {
        guard let database, !isWizardRunning else { return }
        isWizardRunning = true
        isPlanningIntoBuilder = true
        wizardLog = []
        requestedSection = .builder
        let profile = activeProfile
        let wizard = wizard
        wizardTask = Task {
            do {
                let (plan, sceneMap) = try await wizard.plan(options: options, profile: profile,
                                                             database: database) { message in
                    Task { @MainActor in self.wizardLog.append(message) }
                }
                let document = WizardEngine.timelineDocument(from: plan, sceneMap: sceneMap)
                if document.videoTrack.isEmpty {
                    presentError("The plan produced no usable clips")
                } else {
                    wizardLog.append("Opening \(document.videoTrack.count) clips in the Builder...")
                    builder.loadDocument(document)
                }
            } catch is CancellationError {
                wizardLog.append("Pre-fill cancelled")
            } catch {
                presentError("Timeline planning failed", error)
            }
            isWizardRunning = false
            isPlanningIntoBuilder = false
        }
    }
}
