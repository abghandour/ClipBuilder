import AppKit
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

    /// FIFO of pending alerts; the main window presents the first entry and
    /// dequeues on dismiss, so one failure can't silently replace another.
    private(set) var errorQueue: [AppError] = []
    var currentError: AppError? { errorQueue.first }

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
    var wizardLog: [String] = []
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
    var isConnectingInstagram = false
    private var igAnalyzeTasks: [Int64: Task<Void, Never>] = [:]
    /// Template picked in the Instagram tab, consumed by the Wizard's next
    /// run (or dismissed from its chip).
    var pendingWizardTemplate: WizardTemplateHandoff?
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

    // MARK: - Services

    let ai: AIService
    let thumbnails = ThumbnailService()
    let renderEngine = RenderEngine()
    let transcription = TranscriptionService()
    private let analyzer: Analyzer
    private let wizard: WizardEngine
    private let multitrackRenderer: MultitrackRenderer
    private let instagram: InstagramService
    private var watcher: FolderWatcher?

    init() {
        let settings = SettingsStore.loadSettings()
        self.settings = settings
        ai = AIService(config: settings.ai)
        analyzer = Analyzer(ai: ai)
        wizard = WizardEngine(ai: ai, render: renderEngine)
        multitrackRenderer = MultitrackRenderer(render: renderEngine)
        instagram = InstagramService(ai: ai)

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
        generatedVideos = []
        feedback = []
        igAccounts = []
        igSelectedAccountID = nil
        igMedia = []
        igTemplatedMediaIDs = []
        pendingWizardTemplate = nil
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
                presentError("Could not load the library", error)
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

    func analyze(videos targets: [VideoRecord], provider: String? = nil, model: String? = nil) {
        guard let database, !isAnalyzing else { return }
        isAnalyzing = true
        analysisLog = []
        analysisProgress = 0
        let profile = activeProfile
        let analyzer = analyzer
        analysisTask = Task {
            defer {
                isAnalyzing = false
                refreshAll()
            }
            for (index, video) in targets.enumerated() {
                if Task.isCancelled { break }
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
                } catch is CancellationError {
                    break
                } catch let error as AIError {
                    analysisLog.append("\(video.filename): \(error)")
                    if case .quotaExhausted = error {
                        analysisLog.append("Quota exhausted — stopping the batch.")
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
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
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
                let result = try await renderer.render(document: document, scenes: scenes,
                                                       profile: profile, database: database) { message in
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

    /// Load a generated video's saved timeline back into the builder.
    func openInBuilder(_ video: GeneratedVideoRecord) {
        guard let data = video.timelineJSON.data(using: .utf8),
              let document = try? JSONDecoder().decode(TimelineDocument.self, from: data),
              !document.videoTrack.isEmpty else {
            presentError("This video's timeline uses the old linear format and can't be edited in the Builder.")
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
        wizardTask = Task {
            await wizard.run(options: options, profile: profile, database: database) { message in
                Task { @MainActor in self.wizardLog.append(message) }
            }
            isWizardRunning = false
            refreshAll()
        }
    }

    func cancelWizard() {
        wizardTask?.cancel()
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
    func analyzeInstagramTemplate(media: IGMediaRecord, force: Bool = false) {
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
                                                    force: force) { message in
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
                                                          label: templateLabel(for: media))
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
    /// a timeline document. Shares the wizard's log panel and stop button.
    func planIntoBuilder(options: WizardOptions) {
        guard let database, !isWizardRunning else { return }
        isWizardRunning = true
        wizardLog = []
        requestedSection = .wizard   // show the live log while planning
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
                    requestedSection = .builder
                }
            } catch {
                presentError("Timeline planning failed", error)
            }
            isWizardRunning = false
        }
    }
}
