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
        timelineViewStates = [:]
        activeProjectID = id
        isShowingProjectsHome = false
        openTimelineID = nil
        // A failed run's Try Again must not replay into the project we left.
        lastWizardOptions = nil
        wizardFailureMessage = nil
        videos = []
        scenes = []
        analysisRuns = []
        generatedVideos = []
        fightResearch = [:]
        fightEvents = [:]
        do {
            try await database.touchProject(id: id)
            let snapshot = try await database.fetchLibrarySnapshot(projectID: id)
            timelines = try await database.fetchTimelines(projectID: id)
            projects = try await database.fetchProjects()
            applyLibrarySnapshot(snapshot, generation: profileGeneration)
            let state = projectState(for: activeProject)
            selectedSection = state.section == "curated" ? .scenes
                : SidebarSection(rawValue: state.section)?.projectDestination ?? .sources
            sceneMode = "all"
            outputsSort = state.outputsSort
            outputsScrollID = state.outputsScrollID
            sourceSelection = state.sourceSelection.intersection(Set(videos.map(\.id)))
            sourceScrollID = state.sourceScrollID
            sceneSelection = state.sceneSelection.intersection(Set(scenes.map(\.id)))
            sceneScrollID = state.sceneScrollID
            sceneRunSelection = state.sceneRunSelection.intersection(Set(analysisRuns.map(\.id)))
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
        Task {
            do {
                try await database.assignVideos(videoIDs, to: projectID)
                projects = try await database.fetchProjects()
                if activeProjectID == projectID { refreshAll() }
            } catch { presentError("Could not add the files to the project", error) }
        }
    }

    func removeVideos(_ videoIDs: [Int64], from projectID: Int64) {
        guard !videoIDs.isEmpty, let database else { return }
        Task {
            do {
                try await database.removeVideos(videoIDs, from: projectID)
                projects = try await database.fetchProjects()
                if activeProjectID == projectID { refreshAll() }
            } catch { presentError("Could not remove the files from the project", error) }
        }
    }

    func availableVideosForProjectPicker() async -> [VideoRecord] {
        guard let database, let activeProjectID else { return [] }
        return (try? await database.fetchVideosNotInProject(activeProjectID)) ?? []
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
        if activeProjectID != nil || section == .learned { isShowingProjectsHome = false }
        selectedSection = section.projectDestination
        persistActiveProjectState()
    }

    func refreshProjectCatalog() {
        guard let database else { return }
        Task {
            projects = (try? await database.fetchProjects()) ?? projects
            if let activeProjectID {
                timelines = (try? await database.fetchTimelines(projectID: activeProjectID)) ?? timelines
            }
        }
    }

    func saveActiveProfile() {
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
            if let index = profiles.firstIndex(where: { $0.profileName == activeProfile.profileName }) {
                profiles[index] = activeProfile
            }
            ProfileStore.ensureFolders(for: activeProfile)
            watcher?.watch(activeProfile.sourceFolderURL)
        } catch {
            presentError("Could not save the profile", error)
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
}
