import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - Projects

    func initializeProjectWorkspace() async {
        guard let database else { return }
        await googleDrive.attach(profile: activeProfile, database: database)
        do {
            let legacyJSON = BuilderStateStore.load(profileName: activeProfile.profileName)
                .flatMap { try? JSONEncoder().encode($0) }
                .flatMap { String(data: $0, encoding: .utf8) }
            try await database.ensureDefaultProject(profileName: activeProfile.profileName,
                                                    legacyTimelineJSON: legacyJSON)
            projects = try await database.fetchProjects()
            let lastOpenedID = try await database.lastOpenedProjectID()
            let homeID = try await database.homeProjectID(profileName: activeProfile.profileName)
            guard let initialID = lastOpenedID ?? homeID else {
                isShowingProjectsHome = true
                return
            }
            await loadProject(initialID, persistCurrent: false)
        } catch {
            presentError("Could not load projects", error)
        }
    }

    func showProjectsHome() {
        flushActiveProjectState()
        isShowingProjectsHome = true
    }

    /// Returns the load so callers that must wait for the switch (tests,
    /// termination) can; UI callers ignore it.
    @discardableResult
    func selectProject(_ id: Int64) -> Task<Void, Never>? {
        guard id != activeProjectID || isShowingProjectsHome else { return nil }
        return Task { await loadProject(id, persistCurrent: true) }
    }

    func loadProject(_ id: Int64, persistCurrent: Bool) async {
        guard let database else { return }
        if persistCurrent {
            builder.flushPendingAutosave()
            flushActiveProjectState()
        }
        // A project switch is not a profile switch: analysis and Wizard
        // runs keep their generation and still deliver their follow-ups.
        isLoadingProject = true
        defer { isLoadingProject = false }
        let generation = profileGeneration
        timelineViewStates = [:]
        activeProjectID = id
        isShowingProjectsHome = false
        openTimelineID = nil
        // A failed run's Try Again must not replay into the project we left.
        lastWizardOptions = nil
        resetHighlightHistory()
        wizardFailureMessage = nil
        videos = []
        scenes = []
        historyScenes = []
        referencedScenes = []
        sceneReferences = []
        analysisPasses = []
        analysisRuns = []
        transcriptCounts = [:]
        transcriptFacts = [:]
        speakerNamingSummaries = [:]
        generatedVideos = []
        fightResearch = [:]
        fightEvents = [:]
        do {
            try await database.touchProject(id: id)
            let snapshot = try await database.fetchLibrarySnapshot(projectID: id)
            let loadedTimelines = try await database.fetchTimelines(projectID: id)
            let loadedProjects = try await database.fetchProjects()
            let homeAvailability = try await database.countVideosNotInProject(id)
            // A profile switch or another project load meanwhile owns the lists now.
            guard generation == profileGeneration, activeProjectID == id else { return }
            timelines = loadedTimelines
            projects = loadedProjects
            homeVideosNotInProjectCount = homeAvailability
            applyLibrarySnapshot(snapshot, generation: generation)
            let state = projectState(for: activeProject)
            if SidebarSection(rawValue: state.section) == .wizardMini {
                wizardMode = .express
            }
            selectedSection = state.section == "curated" ? .scenes
                : SidebarSection(rawValue: state.section)?.projectDestination ?? .sources
            sceneMode = "all"
            outputsSort = state.outputsSort
            outputsScrollID = state.outputsScrollID
            sourceSelection = state.sourceSelection.intersection(Set(videos.map(\.id)))
            sourceScrollID = state.sourceScrollID
            sceneSelection = state.sceneSelection.intersection(Set(scenes.map(\.id)))
            sceneScrollID = state.sceneScrollID
            // Negative IDs are the built-in rows (All batches, Recent, Interviews, ...).
            let runIDs = Set(analysisRuns.map(\.id))
            sceneRunSelection = state.sceneRunSelection.filter { $0 < 0 || runIDs.contains($0) }
            sceneTagFilter = state.sceneTagFilter
            sceneSearchText = state.sceneSearchText
            sceneShowHidden = state.sceneShowHidden
            sceneSortByScore = state.sceneSortByScore
            sceneMinimumScore = state.sceneMinimumScore
            sceneShowSequenceParts = state.sceneShowSequenceParts
            timelineScrollX = state.timelineScrollX
            timelineScrollY = state.timelineScrollY
            let restoredSection = selectedSection
            if let timelineID = state.openTimelineID,
               let timeline = timelines.first(where: { $0.id == timelineID }) {
                openTimelineRecord(timeline, state: timeline.viewState == nil ? state : nil)
                // Opening the timeline lands on Timelines; the user may have
                // quit on another section with the timeline still open.
                selectedSection = restoredSection
            } else {
                builder.closeTimeline(defaultRenderSettings: activeProfile.defaultRenderSettings)
            }
        } catch {
            presentError("Could not open the project", error)
        }
        Task { await refreshLanguageReadiness() }
        projectStateVersion &+= 1
    }

    func cycleProject(offset: Int) {
        let active = projects.filter { !$0.archived }
        guard active.count > 1, let activeProjectID,
              let index = active.firstIndex(where: { $0.id == activeProjectID }) else { return }
        let next = (index + offset + active.count) % active.count
        selectProject(active[next].id)
    }

    func createProject(named name: String, videoIDs: [Int64] = []) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let database else { return }
        Task {
            do {
                let id = try await database.createProject(profileName: activeProfile.profileName,
                                                          name: trimmed, videoIDs: videoIDs)
                projects = try await database.fetchProjects()
                await loadProject(id, persistCurrent: true)
            } catch {
                presentError("Could not create the project", error)
            }
        }
    }

    func renameProject(_ project: ProjectRecord, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let database else { return }
        Task {
            do {
                try await database.renameProject(id: project.id, name: trimmed)
                projects = try await database.fetchProjects()
            } catch { presentError("Could not rename the project", error) }
        }
    }

    func duplicateProject(_ project: ProjectRecord) {
        guard let database else { return }
        Task {
            do {
                let id = try await database.duplicateProject(
                    id: project.id, profileName: activeProfile.profileName,
                    name: "\(project.name) Copy"
                )
                projects = try await database.fetchProjects()
                await loadProject(id, persistCurrent: true)
            } catch { presentError("Could not duplicate the project", error) }
        }
    }

    func setProjectArchived(_ project: ProjectRecord, archived: Bool) {
        guard let database else { return }
        Task {
            do {
                try await database.setProjectArchived(id: project.id, archived: archived)
                projects = try await database.fetchProjects()
                if archived, activeProjectID == project.id { showProjectsHome() }
            } catch { presentError("Could not update the project", error) }
        }
    }

    func deleteProject(_ project: ProjectRecord, moveTimelinesToHome: Bool) {
        guard !project.isHome, let database else { return }
        guard !busyProjectIDs.contains(project.id) else {
            presentError("\(project.name) has a render or analysis running. Stop it or wait for it to finish before deleting the project.")
            return
        }
        let wasActive = activeProjectID == project.id
        if wasActive {
            builder.flushPendingAutosave()
            flushActiveProjectState()
        }
        Task {
            do {
                guard let homeID = try await database.homeProjectID(profileName: activeProfile.profileName) else {
                    presentError("Could not find this profile's Home project.")
                    return
                }
                if moveTimelinesToHome {
                    try await database.moveTimelines(from: project.id, to: homeID)
                }
                try await database.deleteProject(id: project.id)
                projects = try await database.fetchProjects()
                if wasActive {
                    await loadProject(homeID, persistCurrent: false)
                } else if activeProjectID == homeID {
                    timelines = try await database.fetchTimelines(projectID: homeID)
                }
            } catch { presentError("Could not delete the project", error) }
        }
    }

    func addVideos(_ videoIDs: [Int64], to projectID: Int64) {
        guard !videoIDs.isEmpty, let database else { return }
        let generation = profileGeneration
        Task {
            do {
                try await database.assignVideos(videoIDs, to: projectID)
                let updated = try await database.fetchProjects()
                guard generation == profileGeneration, self.database === database else { return }
                projects = updated
                await refreshHomeAvailability()
                guard generation == profileGeneration, self.database === database else { return }
                if activeProjectID == projectID { refreshAll() }
            } catch {
                guard generation == profileGeneration, self.database === database else { return }
                presentError("Could not add the files to the project", error)
            }
        }
    }

    func removeVideos(_ videoIDs: [Int64], from projectID: Int64) {
        guard !videoIDs.isEmpty, let database else { return }
        let generation = profileGeneration
        Task {
            do {
                try await database.removeVideos(videoIDs, from: projectID)
                let updated = try await database.fetchProjects()
                guard generation == profileGeneration, self.database === database else { return }
                projects = updated
                await refreshHomeAvailability()
                guard generation == profileGeneration, self.database === database else { return }
                if activeProjectID == projectID { refreshAll() }
            } catch {
                guard generation == profileGeneration, self.database === database else { return }
                presentError("Could not remove the files from the project", error)
            }
        }
    }

    /// The active profile belongs to a team: its records are shared, so a
    /// removed source is offloaded and hidden here rather than deleted.
    var isTeamAttachedProfile: Bool {
        activeProfile.teamID != nil && activeProfile.profileID != nil
    }

    /// The Sources page's remove action, offered in every project including
    /// Home. Team-attached profile: the local copy is offloaded to Drive when
    /// one exists and the row is hidden on this Mac; teammates keep it.
    /// Otherwise the row is retired: hidden, out of every project, with its
    /// scenes, transcripts and batches kept so the same file added again is
    /// not analyzed twice. A file inside the profile's source folder goes to
    /// the Trash (files elsewhere are left alone).
    func removeSources(_ videos: [VideoRecord]) {
        guard !videos.isEmpty, let database else { return }
        let ids = videos.map(\.id)
        let profile = activeProfile
        let generation = profileGeneration
        if isTeamAttachedProfile {
            let offloadable = videos.map(\.driveMedia).filter {
                $0.fileID != nil && !$0.offloaded && FileManager.default.fileExists(atPath: $0.path)
            }
            Task {
                do {
                    // Hide first: the Sources preview player holds a lease on
                    // the file until the row leaves the list, and an offload
                    // refuses a file in use.
                    try await database.setVideosHidden(ids, true)
                    guard generation == profileGeneration else { return }
                    await refreshAllNow()
                    if !offloadable.isEmpty {
                        let deadline = ContinuousClock.now + .seconds(5)
                        while ContinuousClock.now < deadline {
                            var busy = false
                            for item in offloadable where await DriveMediaResolver.shared.isInUse(item.path) { busy = true }
                            if !busy { break }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        do {
                            try await offloadReconnecting(offloadable, profile: profile.profileName)
                        } catch {
                            // Keep the rows visible rather than hiding a file that is still here.
                            try? await database.setVideosHidden(ids, false)
                            refreshAll()
                            throw error
                        }
                    }
                    guard generation == profileGeneration else { return }
                    appendLog(\.analysisLog, ["Hid \(ids.count) source(s) on this Mac"
                        + (offloadable.isEmpty ? "" : " and removed \(offloadable.count) local cop\(offloadable.count == 1 ? "y" : "ies")")])
                    refreshAll()
                } catch { presentError("Could not remove the sources: " + GoogleDriveError.message(for: error)) }
            }
            return
        }
        let folder = profile.sourceFolderURL.standardizedFileURL.path
        Task {
            do {
                try await database.retireVideos(ids)
                guard generation == profileGeneration else { return }
                await refreshAllNow()
                let trashed = await Task.detached(priority: .utility) { () -> Int in
                    var count = 0
                    for video in videos {
                        guard let path = video.path else { continue }
                        let url = URL(fileURLWithPath: path).standardizedFileURL
                        guard url.deletingLastPathComponent().path == folder,
                              FileManager.default.fileExists(atPath: url.path) else { continue }
                        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { count += 1 }
                    }
                    return count
                }.value
                appendLog(\.analysisLog, ["Removed \(ids.count) source(s) from every project; analysis kept"
                    + (trashed > 0 ? ", \(trashed) file(s) moved to the Trash" : "")])
                refreshProjectCatalog()
                refreshAll()
            } catch { presentError("Could not remove the sources", error) }
        }
    }

    /// Offload, and when Google's session has lapsed, open the sign-in flow
    /// (the same one Drive jobs use), wait for it, and try once more.
    private func offloadReconnecting(_ media: [DriveMedia], profile: String) async throws {
        do {
            try await googleDrive.offload(media, profile: profile)
        } catch GoogleDriveError.reconnect {
            googleDrive.connect(profile: profile)
            // Sign-in happens in the browser; give it a generous window.
            let deadline = ContinuousClock.now + .seconds(180)
            while googleDrive.connecting.contains(profile), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
            guard googleDrive.states[profile]?.isConnected == true else { throw GoogleDriveError.reconnect }
            try await googleDrive.offload(media, profile: profile)
        }
    }

    func refreshHomeAvailability() async {
        guard let database, let projectID = activeProjectID, !isHomeProject else {
            homeVideosNotInProjectCount = 0
            return
        }
        let generation = profileGeneration
        let count = try? await database.countVideosNotInProject(projectID)
        guard generation == profileGeneration, self.database === database, activeProjectID == projectID else { return }
        if let count { homeVideosNotInProjectCount = count }
    }

    func availableVideosForProjectPicker() async -> [HomeVideoCandidate] {
        guard let database, let projectID = activeProjectID, !isHomeProject else { return [] }
        let generation = profileGeneration
        do {
            let videos = try await database.fetchVideosNotInProject(projectID)
            let ids = videos.map(\.id)
            let facts = try await database.fetchVideoFacts(ids: ids)
            let names = try await database.projectNames(forVideos: ids)
            guard generation == profileGeneration, self.database === database, activeProjectID == projectID else { return [] }
            return videos.map { video in
                let fact = facts[video.id] ?? HomeVideoCandidate.Facts()
                return HomeVideoCandidate(video: video, hasScenes: fact.hasScenes, hasTranscript: fact.hasTranscript,
                                          projectIDs: fact.projectIDs, projectNames: names[video.id] ?? [])
            }
        } catch {
            guard generation == profileGeneration, self.database === database, activeProjectID == projectID else { return [] }
            presentError("Could not load videos from Home", error)
            return []
        }
    }

    private func projectState(for project: ProjectRecord?) -> ProjectUIState {
        guard let json = project?.uiStateJSON?.data(using: .utf8),
              let state = try? JSONDecoder().decode(ProjectUIState.self, from: json) else {
            return ProjectUIState()
        }
        return state
    }

    func persistActiveProjectState() {
        guard let database, let activeProjectID, let json = activeProjectStateJSON() else { return }
        Task { try? await database.saveProjectUIState(id: activeProjectID, json: json) }
        persistOpenTimelineViewState()
    }

    /// The current per-project UI state, encoded; nil with no project open.
    private func activeProjectStateJSON() -> String? {
        guard activeProjectID != nil else { return nil }
        let state = ProjectUIState(
            section: selectedSection.projectDestination.rawValue,
            openTimelineID: openTimelineID,
            playhead: builder.playhead,
            zoom: Double(builder.pointsPerSecond),
            sceneFilter: sceneMode,
            outputsSort: outputsSort,
            outputsScrollID: outputsScrollID,
            sourceSelection: sourceSelection,
            sourceScrollID: sourceScrollID,
            sceneSelection: sceneSelection,
            sceneScrollID: sceneScrollID,
            sceneRunSelection: sceneRunSelection,
            sceneTagFilter: sceneTagFilter,
            sceneSearchText: sceneSearchText,
            sceneShowHidden: sceneShowHidden,
            sceneSortByScore: sceneSortByScore,
            sceneMinimumScore: sceneMinimumScore,
            sceneShowSequenceParts: sceneShowSequenceParts,
            timelineSelection: builder.selection,
            timelineFocusedTrack: builder.focusedTrack,
            timelineScrollX: timelineScrollX,
            timelineScrollY: timelineScrollY
        )
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func scheduleProjectStateSave() {
        guard activeProjectID != nil else { return }
        projectStateSaveTask?.cancel()
        projectStateSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistActiveProjectState()
        }
    }

    func flushActiveProjectState() {
        projectStateSaveTask?.cancel()
        projectStateSaveTask = nil
        persistActiveProjectState()
    }

    /// Cmd-Q path: write the open timeline and the project UI state and
    /// wait for the database to have them, so nothing is lost to the
    /// autosave debounce or an unawaited task when the process exits.
    func flushForTermination() async {
        flushPendingProfileSave()
        clearBuilderPreviewCache()
        guard let database else { return }
        builder.cancelPendingAutosave()
        if let timelineID = builder.timelineID {
            saveTimeline(id: timelineID, document: builder.document)
        }
        // Includes saves from timelines/profiles closed while an encode was pending.
        while !timelineSaveTasks.isEmpty {
            let tasks = Array(timelineSaveTasks.values)
            for task in tasks { await task.value }
        }
        projectStateSaveTask?.cancel()
        projectStateSaveTask = nil
        if let activeProjectID, let json = activeProjectStateJSON() {
            try? await database.saveProjectUIState(id: activeProjectID, json: json)
        }
        if let (id, json) = openTimelineViewStateJSON() {
            try? await database.saveTimelineViewState(id: id, json: json)
        }
    }

    func selectSection(_ section: SidebarSection) {
        if section == .wizardMini { wizardMode = .express }
        if let tab = TextLooksTab.tab(for: section) { TextLooksTab.remember(tab) }
        if activeProjectID != nil || section == .learned || section.projectDestination == .text {
            isShowingProjectsHome = false
        }
        selectedSection = section.projectDestination
    }

    @discardableResult
    func refreshProjectCatalog() -> Task<Void, Never>? {
        guard let database else { return nil }
        let generation = profileGeneration
        return Task {
            let updated = try? await database.fetchProjects()
            guard generation == profileGeneration, self.database === database else { return }
            projects = updated ?? projects
            if let activeProjectID {
                let loaded = try? await database.fetchTimelines(projectID: activeProjectID)
                guard generation == profileGeneration, self.database === database, self.activeProjectID == activeProjectID else { return }
                timelines = loaded ?? timelines
            }
            analysisComparisonKeys = [:]
            await refreshHomeAvailability()
            await refreshLanguageReadiness()
        }
    }

    /// Continuous edits (sliders, colour wells, typing) save once they settle
    /// rather than rewriting the profile on every tick. Any real save, a
    /// profile switch and quitting flush it first.
    func scheduleActiveProfileSave() {
        pendingProfileSave?.cancel()
        let generation = profileGeneration
        pendingProfileSave = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, generation == profileGeneration else { return }
            pendingProfileSave = nil
            saveActiveProfile()
        }
    }

    func flushPendingProfileSave() {
        guard pendingProfileSave != nil else { return }
        saveActiveProfile()
    }

    @discardableResult
    func saveActiveProfile() -> Task<Void, Never>? {
        pendingProfileSave?.cancel()
        pendingProfileSave = nil
        if activeProfile.editing == nil, activeProfile.teamID == nil {
            activeProfile.editing = editingDefaults
        }
        LearnedCache.invalidate(profile: activeProfile.profileName)
        if let old = ProfileStore.load(name: activeProfile.profileName) {
            let date = Date()
            if old.houseStyle != activeProfile.houseStyle || old.learnedHookStyle != activeProfile.learnedHookStyle
                || old.learnedLayoutPreference != activeProfile.learnedLayoutPreference
                || old.defaultPacing != activeProfile.defaultPacing || old.captionLanguages != activeProfile.captionLanguages {
                activeProfile.learnedSharing.updatedAt["style"] = date
            }
            if old.tasteRubric != activeProfile.tasteRubric || old.tasteCategories != activeProfile.tasteCategories
                || old.tasteExemplarFrames != activeProfile.tasteExemplarFrames {
                activeProfile.learnedSharing.updatedAt["taste"] = date
            }
            if old.tagSchema != activeProfile.tagSchema || old.hashtags != activeProfile.hashtags {
                activeProfile.learnedSharing.updatedAt["vocabulary"] = date
            }
        }
        do {
            try ProfileStore.save(activeProfile)
            var syncTask: Task<Void, Never>?
            if activeProfile.teamID != nil, !teamSync.syncing, let database {
                let generation = profileGeneration
                let teamID = activeProfile.teamID
                syncTask = Task {
                    guard generation == profileGeneration, !teamSync.syncing else { return }
                    do {
                        let canSeed = try await database.canSeedProfileEditingDefaults()
                        guard generation == profileGeneration, teamID == activeProfile.teamID,
                              !teamSync.syncing else { return }
                        if activeProfile.editing == nil, canSeed {
                            var seeded = activeProfile
                            seeded.editing = editingDefaults
                            try ProfileStore.save(seeded)
                            activeProfile = seeded
                            if let index = profiles.firstIndex(where: { $0.profileName == seeded.profileName }) {
                                profiles[index] = seeded
                            }
                        }
                        try await database.saveSyncProfile(activeProfile)
                    }
                    catch {
                        guard generation == profileGeneration else { return }
                        presentError("Could not queue the shared profile", error)
                    }
                }
            }
            if let index = profiles.firstIndex(where: { $0.profileName == activeProfile.profileName }) {
                profiles[index] = activeProfile
            }
            ProfileStore.ensureFolders(for: activeProfile)
            watcher?.watch(activeProfile.sourceFolderURL, recursive: true,
                           ignoring: [activeProfile.outputFolderURL])
            return syncTask
        } catch {
            presentError("Could not save the profile", error)
            return nil
        }
    }

    func applyLearnedEditingDefaults(_ insights: EditingPerformanceInsights) {
        guard activeProfile.useLearnedEditingDefaults else { return }
        activeProfile.learnedHookStyle = insights.suggestedHook ?? activeProfile.learnedHookStyle
        activeProfile.learnedLayoutPreference = insights.suggestedLayout ?? activeProfile.learnedLayoutPreference
        if let cadence = insights.suggestedCadence {
            activeProfile.defaultPacing.cadence = cadence >= 26 ? .twoSeconds
                : cadence >= 18 ? .threeSeconds : .mixedTwoToFour
        }
        saveActiveProfile()
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

    /// Shared task pickers persist both routing fields on every selection.
    func setTaskModel(task: String, provider: String?, model: String?) {
        settings.ai.tasks[task] = provider
        settings.ai.taskModels[task] = model
        saveSettings()
    }

    func saveSettings() {
        SettingsStore.save(settings)
        let config = effectiveAIConfig
        Task { await ai.updateConfig(config) }
    }

    func useTeamAIChoice(task: String) {
        settings.ai.tasks[task] = nil
        settings.ai.taskModels[task] = nil
        saveSettings()
    }

    func useRecommendedAIChoice(task: String) {
        settings.ai.tasks[task] = nil
        settings.ai.taskModels[task] = nil
        if AIRoutingResolver.flag(task: task, local: settings.ai, team: activeProfile.aiRouting) != .recommended {
            let top = AICatalog.topRecommended(task: task)
            settings.ai.tasks[task] = top.provider
            settings.ai.taskModels[task] = top.model
        }
        saveSettings()
    }

    /// Publish explicit choices, including catalog fallbacks, without sharing
    /// binaries, cooldowns, on-device policy, or other per-Mac settings.
    func recommendAIRoutingToTeam() {
        let config = effectiveAIConfig
        var routing = activeProfile.aiRouting ?? ProfileAIRouting()
        for task in AICatalog.tasks + ["translate"] {
            let provider = config.tasks[task] ?? AICatalog.taskDefaults[task] ?? "claude"
            // Match AIService's routing-task fallback before provider defaults.
            let routeModel = task == "route"
                ? AICatalog.recommendedChains[task]?.first(where: { $0.provider == provider })?.model : nil
            let model = config.taskModels[task].flatMap { $0.isEmpty ? nil : $0 }
                ?? routeModel
                ?? config.providers[provider]?.model.flatMap { $0.isEmpty ? nil : $0 }
                ?? AICatalog.provider(provider)?.defaultModel ?? ""
            routing.tasks[task] = provider
            routing.taskModels[task] = model
            settings.ai.tasks[task] = nil
            settings.ai.taskModels[task] = nil
        }
        activeProfile.aiRouting = routing
        saveActiveProfile()
        saveSettings()
    }

    /// Restore the catalog's top picks and the Analyze/Generate plan prompts,
    /// overriding team choices or provider defaults only where they differ.
    func resetDispatcher() {
        settings.ai.tasks = [:]
        settings.ai.taskModels = [:]
        settings.ai.mutedDispatchPlans = []
        for task in AICatalog.tasks + ["translate"] {
            if AIRoutingResolver.flag(task: task, local: settings.ai, team: activeProfile.aiRouting) != .recommended {
                let top = AICatalog.topRecommended(task: task)
                settings.ai.tasks[task] = top.provider
                settings.ai.taskModels[task] = top.model
            }
        }
        saveSettings()
    }
}
