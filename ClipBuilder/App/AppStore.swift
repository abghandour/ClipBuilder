import Foundation
import Observation

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
    var generatedVideos: [GeneratedVideoRecord] = []
    var feedback: [FeedbackRecord] = []

    var lastError: String?

    // Analysis job
    var isAnalyzing = false
    var analysisLog: [String] = []
    var analysisProgress: Double = 0
    var analysisStage = ""

    // Transcription job
    var transcribingVideoIDs: Set<Int64> = []

    // Wizard job
    var isWizardRunning = false
    var wizardLog: [String] = []

    // Clip Builder
    let builder = BuilderTimelineModel()
    var isBuilderRendering = false
    var builderLog: [String] = []
    /// Set by views (e.g. "Open in Builder") to ask the main window to switch
    /// sidebar sections; the window consumes and clears it.
    var requestedSection: SidebarSection?

    // MARK: - Services

    let ai: AIService
    let thumbnails = ThumbnailService()
    let renderEngine = RenderEngine()
    let transcription = TranscriptionService()
    private let analyzer: Analyzer
    private let wizard: WizardEngine
    private let multitrackRenderer: MultitrackRenderer
    private var watcher: FolderWatcher?

    init() {
        let settings = SettingsStore.loadSettings()
        self.settings = settings
        ai = AIService(config: settings.ai)
        analyzer = Analyzer(ai: ai)
        wizard = WizardEngine(ai: ai, render: renderEngine)
        multitrackRenderer = MultitrackRenderer(render: renderEngine)

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

    // MARK: - Profiles

    private func openActiveProfile() {
        ProfileStore.ensureFolders(for: activeProfile)
        do {
            database = try Database(path: SettingsStore.databaseURL(profileName: activeProfile.profileName))
        } catch {
            database = nil
            lastError = "Could not open profile database: \(error)"
        }
        watcher?.watch(activeProfile.sourceFolderURL)
        builder.load(profileName: activeProfile.profileName)
        refreshAll()
        scanSourceFolder()
    }

    func switchProfile(named name: String) {
        guard let profile = profiles.first(where: { $0.profileName == name }) else { return }
        activeProfile = profile
        SettingsStore.saveActiveProfileName(name)
        videos = []
        scenes = []
        generatedVideos = []
        feedback = []
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
            lastError = "Could not save profile: \(error)"
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
            lastError = "Could not create profile: \(error)"
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

    // MARK: - Data refresh

    func refreshAll() {
        guard let database else { return }
        Task {
            do {
                let videos = try await database.fetchVideos()
                let scenes = try await database.fetchScenes()
                let generated = try await database.fetchGeneratedVideos()
                let feedback = try await database.fetchAllFeedback()
                self.videos = videos
                self.scenes = scenes
                self.generatedVideos = generated
                self.feedback = feedback
                self.builder.updateScenes(scenes)
            } catch {
                lastError = "Could not load data: \(error)"
            }
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
                lastError = "Scan failed: \(error)"
            }
        }
    }

    // MARK: - Analysis

    func analyze(videos targets: [VideoRecord], provider: String? = nil, model: String? = nil) {
        guard let database, !isAnalyzing else { return }
        isAnalyzing = true
        analysisLog = []
        analysisProgress = 0
        let profile = activeProfile
        let analyzer = analyzer
        Task {
            defer {
                isAnalyzing = false
                refreshAll()
            }
            for (index, video) in targets.enumerated() {
                let base = Double(index) / Double(targets.count)
                let span = 1.0 / Double(targets.count)
                do {
                    try await analyzer.analyzeVisual(
                        video: video, profile: profile, database: database,
                        provider: provider, model: model,
                        log: { message in
                            Task { @MainActor in self.analysisLog.append(message) }
                        },
                        progress: { fraction, stage in
                            Task { @MainActor in
                                self.analysisProgress = base + span * fraction
                                self.analysisStage = stage
                            }
                        })
                    analysisLog.append("\(video.filename): done")
                } catch let error as AIError {
                    analysisLog.append("\(video.filename): \(error)")
                    if case .quotaExhausted = error {
                        analysisLog.append("Quota exhausted — stopping the batch.")
                        break
                    }
                } catch {
                    analysisLog.append("\(video.filename): \(error)")
                }
            }
            analysisProgress = 1
            analysisStage = "done"
        }
    }

    func transcribe(video: VideoRecord, force: Bool = false) {
        guard let database, !transcribingVideoIDs.contains(video.id) else { return }
        transcribingVideoIDs.insert(video.id)
        let transcription = transcription
        let language = settings.transcribeLanguage
        Task {
            defer {
                transcribingVideoIDs.remove(video.id)
                refreshAll()
            }
            do {
                _ = try await transcription.transcribe(video: video, database: database,
                                                       languageCode: language, force: force,
                                                       log: { message in
                    Task { @MainActor in self.analysisLog.append(message) }
                })
                analysisLog.append("\(video.filename): transcription saved")
            } catch {
                lastError = "Transcription failed: \(error)"
            }
        }
    }

    // MARK: - Scene actions

    func toggleFavorite(_ scene: SceneRecord) {
        guard let database else { return }
        Task {
            try? await database.setSceneFavorite(scene.id, favorite: !scene.favorite)
            refreshAll()
        }
    }

    func setExcluded(_ scene: SceneRecord, excluded: Bool) {
        guard let database else { return }
        Task {
            try? await database.setSceneExcluded(scene.id, excluded: excluded)
            refreshAll()
        }
    }

    func grade(_ scene: SceneRecord, score: Int) {
        guard let database else { return }
        Task {
            try? await database.addGrade(sceneID: scene.id, score: score)
            refreshAll()
        }
    }

    // MARK: - Generated videos

    func deleteGeneratedVideo(_ video: GeneratedVideoRecord, removeFile: Bool) {
        guard let database else { return }
        Task {
            try? await database.deleteGeneratedVideo(id: video.id)
            if removeFile {
                try? FileManager.default.removeItem(at: video.url)
            }
            refreshAll()
        }
    }

    func addFeedback(for video: GeneratedVideoRecord, text: String) {
        guard let database else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            try? await database.addFeedback(generatedVideoID: video.id, text: trimmed)
            refreshAll()
        }
    }

    // MARK: - Clip Builder

    /// Render the builder timeline through the multitrack pipeline and file
    /// the result into the Library. Mirrors the runWizard job pattern.
    func renderBuilderTimeline() {
        guard let database, !isBuilderRendering else { return }
        guard !builder.document.videoTrack.isEmpty else {
            lastError = "Add clips to the timeline first."
            return
        }
        isBuilderRendering = true
        builderLog = []
        let document = builder.document
        let scenes = builder.scenes
        let profile = activeProfile
        let renderer = multitrackRenderer
        Task {
            do {
                let result = try await renderer.render(document: document, scenes: scenes,
                                                       profile: profile, database: database) { message in
                    Task { @MainActor in self.builderLog.append(message) }
                }
                builderLog.append("Done: \(result.url.lastPathComponent) (\(result.duration.timecode))")
            } catch {
                builderLog.append("Failed: \(error)")
                lastError = "Builder render failed: \(error)"
            }
            isBuilderRendering = false
            refreshAll()
        }
    }

    /// Load a generated video's saved timeline back into the builder.
    func openInBuilder(_ video: GeneratedVideoRecord) {
        guard let data = video.timelineJSON.data(using: .utf8),
              let document = try? JSONDecoder().decode(TimelineDocument.self, from: data),
              !document.videoTrack.isEmpty else {
            lastError = "This video's timeline uses the old linear format and can't be edited in the Builder."
            return
        }
        builder.loadDocument(document)
        requestedSection = .builder
    }

    // MARK: - Wizard

    func runWizard(options: WizardOptions) {
        guard let database, !isWizardRunning else { return }
        isWizardRunning = true
        wizardLog = []
        let profile = activeProfile
        let wizard = wizard
        Task {
            await wizard.run(options: options, profile: profile, database: database) { message in
                Task { @MainActor in self.wizardLog.append(message) }
            }
            isWizardRunning = false
            refreshAll()
        }
    }
}
