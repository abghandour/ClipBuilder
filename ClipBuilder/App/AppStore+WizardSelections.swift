import Foundation

extension AppStore {
    var currentWizardSelection: WizardSelectionSummary? {
        wizardSelections.first { $0.id == activeWizardSelectionID && $0.selection.projectID == activeProjectID }
            ?? wizardSelections.first { $0.selection.projectID == activeProjectID }
    }

    /// Refresh only the project still on screen when the database read completes.
    func refreshWizardSelections() async {
        guard let database, let projectID = activeProjectID else { wizardSelections = []; return }
        let generation = profileGeneration
        do {
            _ = try? await wizardSelectionSaveTask?.value
            let selections = try await database.fetchWizardSelections(projectID: projectID)
            var summaries: [WizardSelectionSummary] = []
            for selection in selections {
                let takes = try await database.fetchWizardSelectionTakes(selectionID: selection.id)
                summaries.append(WizardSelectionSummary(selection: selection, takes: takes))
            }
            guard generation == profileGeneration, activeProjectID == projectID else { return }
            wizardSelections = summaries
            if !summaries.contains(where: { $0.id == activeWizardSelectionID }) {
                activeWizardSelectionID = summaries.first?.id
            }
        } catch { if generation == profileGeneration { presentError("Could not load selections", error) } }
    }

    func openWizardSelection(_ id: Int64, takeID: Int64? = nil, options: WizardOptions? = nil) {
        guard let database, !isWizardRunning else { return }
        let generation = profileGeneration
        let projectID = activeProjectID
        Task {
            do {
                _ = try? await wizardSelectionSaveTask?.value
                guard let selection = try await database.wizardSelection(id: id),
                      selection.projectID == projectID else { throw WizardSelectionError.missingSelection }
                let takes = try await database.fetchWizardSelectionTakes(selectionID: id)
                guard let chosen = takes.first(where: { $0.id == (takeID ?? selection.bestTakeID) }) ?? takes.last else {
                    throw WizardSelectionError.missingTake
                }
                let scenes = try await database.fetchScenes(projectID: selection.projectID)
                let transcriptIDs = try await database.videoIDsWithOriginalTranscripts()
                let transcriptsAvailable = !transcriptIDs.isDisjoint(with: scenes.map(\.videoID))
                let options = options ?? wizardSelectionRenderOptions(transcriptsAvailable: transcriptsAvailable)
                guard generation == profileGeneration, activeProjectID == projectID,
                      !isWizardRunning, !Task.isCancelled else { return }
                wizardSelectionSaveTask = nil
                var merged = WizardOptions.merge(step1: selection.step1Options, step2: options.step2, base: options)
                merged.workflow = options.resolvedWorkflow
                merged.projectID = selection.projectID
                activeWizardSelectionID = id
                pendingWizardSelectionReview = WizardSelectionReviewRequest(selection: selection, takes: takes,
                    selectedTakeID: chosen.id, scenes: scenes, options: merged)
            } catch { if generation == profileGeneration { presentError("Could not open the selection", error) } }
        }
    }

    func openWizardSelection(for output: GeneratedVideoRecord) {
        guard let takeID = output.selectionTakeID, let database else { return }
        let generation = profileGeneration
        Task {
            guard let take = try? await database.wizardSelectionTake(id: takeID),
                  generation == profileGeneration else { return }
            openWizardSelection(take.selectionID, takeID: takeID)
        }
    }

    /// Serial writes ensure Accept and Another take observe the last committed drag.
    func saveWizardTakePlan(_ plan: WizardPlan, takeID: Int64) {
        guard let database else { return }
        enqueueWizardSelectionSave {
            guard let take = try await database.wizardSelectionTake(id: takeID),
                  let selection = try await database.wizardSelection(id: take.selectionID) else {
                throw WizardSelectionError.missingTake
            }
            let scenes = try await database.fetchScenes(projectID: selection.projectID)
            guard let resolved = WizardSelectionRules.resolvedPlan(plan, scenes: scenes) else {
                throw WizardSelectionError.footageChanged
            }
            try await database.updateWizardSelectionTakePlan(id: takeID, plan: resolved)
        }
    }

    func renameWizardSelection(_ id: Int64, name: String) {
        guard let database else { return }
        enqueueWizardSelectionSave { try await database.renameWizardSelection(id: id, name: name) }
    }

    private func enqueueWizardSelectionSave(_ save: @escaping @Sendable () async throws -> Void) {
        let previous = wizardSelectionSaveTask
        let generation = profileGeneration
        wizardSelectionSaveTask = Task {
            // A later edit can repair a failed save; actions still await this write.
            _ = try? await previous?.value
            do { try await save() }
            catch {
                if generation == profileGeneration { presentError("Could not save the selection", error) }
                throw error
            }
        }
    }

    private func afterWizardSelectionDismissal(_ action: @escaping () -> Void) {
        wizardSelectionAfterDismissal = action
        pendingWizardSelectionReview = nil
    }

    func wizardSelectionReviewDidDismiss() {
        let action = wizardSelectionAfterDismissal
        wizardSelectionAfterDismissal = nil
        action?()
        Task { await refreshWizardSelections() }
    }

    func keepWizardSelectionForLater() {
        pendingWizardSelectionReview = nil
    }

    func anotherWizardTake(selectionID: Int64, note: String, options: WizardOptions) {
        afterWizardSelectionDismissal {
            self.findWizardMoments(options: options, selectionID: selectionID, note: note)
        }
    }

    func acceptWizardSelection(_ selectionID: Int64, takeID: Int64, options: WizardOptions, openInBuilder: Bool = false) {
        let generation = profileGeneration
        let projectID = activeProjectID
        afterWizardSelectionDismissal {
            Task {
                do {
                    try await self.wizardSelectionSaveTask?.value
                    guard generation == self.profileGeneration, projectID == self.activeProjectID else { return }
                    guard let database = self.database,
                          let selection = try await database.wizardSelection(id: selectionID),
                          selection.projectID == self.activeProjectID,
                          let take = try await database.wizardSelectionTake(id: takeID),
                          take.selectionID == selectionID else { throw WizardSelectionError.missingTake }
                    let scenes = try await database.fetchScenes(projectID: selection.projectID)
                    guard let plan = WizardSelectionRules.resolvedPlan(take.plan, scenes: scenes) else {
                        throw WizardSelectionError.footageChanged
                    }
                    try await database.setBestWizardSelectionTake(selectionID: selectionID, takeID: takeID)
                    guard generation == self.profileGeneration, projectID == self.activeProjectID else { return }
                    self.activeWizardSelectionID = selectionID
                    await self.refreshWizardSelections()
                    guard generation == self.profileGeneration, projectID == self.activeProjectID else { return }
                    if openInBuilder {
                        var merged = WizardOptions.merge(step1: selection.step1Options, step2: options.step2, base: options)
                        merged.projectID = selection.projectID
                        self.openReviewedPlanInBuilder(plan,
                            sceneMap: Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) }), options: merged)
                    } else if options.resolvedWorkflow == .reviewMomentsAndLook {
                        self.requestedSection = .wizard
                        self.wizardLookRevision += 1
                    } else {
                        self.renderWizardSelection(selectionID, takeID: takeID, options: options)
                    }
                } catch {
                    if generation == self.profileGeneration { self.presentError("Could not accept the take", error) }
                }
            }
        }
    }

    func deleteWizardSelection(_ id: Int64) {
        guard let database, !isWizardRunning else { return }
        Task {
            do {
                try await wizardSelectionSaveTask?.value
                try await database.deleteWizardSelection(id: id)
                await refreshWizardSelections()
            } catch { presentError("Could not delete the selection", error) }
        }
    }

    func keepBestWizardTakeProxy(selectionID: Int64, takeID: Int64) {
        guard let database, !isWizardRunning else { return }
        let generation = profileGeneration
        Task {
            do {
                try await wizard.discardOtherTakeProxies(selectionID: selectionID, keeping: takeID, database: database)
                guard generation == profileGeneration else { return }
                await refreshWizardSelections()
            } catch { if generation == profileGeneration { presentError("Could not remove take previews", error) } }
        }
    }

    /// The page and Outputs reopen saved selections with the same step-2 defaults.
    func wizardSelectionRenderOptions(transcriptsAvailable: Bool) -> WizardOptions {
        var options = Self.wizardOptionsFromForm(transcriptsAvailable: transcriptsAvailable)
        let copied = AISettingsJSON.decode(WizardOptions.self,
            UserDefaults.standard.string(forKey: AISettingsPreferences.snapshotKey))
        options.renderSettings = WizardDefaults.resolvedRenderSettings(run: nil, copied: copied,
            profile: activeProfile.defaultRenderSettings)
        options.pacing = WizardDefaults.resolvedPacing(run: nil, copied: copied, profile: activeProfile.defaultPacing)
        options.projectID = activeProjectID
        return options
    }

    func findWizardMoments(options: WizardOptions, selectionID: Int64? = nil, note: String? = nil) {
        guard let database, let projectID = options.projectID ?? activeProjectID, !isWizardRunning else { return }
        let profile = activeProfile
        let generation = profileGeneration
        let wizard = wizard
        beginWizardSelectionWork(projectID: projectID, stage: "Finding the moments", options: options)
        wizardTask = Task {
            await AIRunCapture.context.withValue(AIRunCapture()) {
                defer { finishWizardSelectionWork(generation: generation) }
                do {
                    try await wizardSelectionSaveTask?.value
                    var options = options
                    var previous: [WizardSelectionTake] = []
                    if let selectionID {
                        guard let selection = try await database.wizardSelection(id: selectionID),
                              selection.projectID == projectID else { throw WizardSelectionError.missingSelection }
                        let workflow = options.resolvedWorkflow
                        options = WizardOptions.merge(step1: selection.step1Options, step2: options.step2, base: options)
                        options.workflow = workflow
                        previous = try await database.fetchWizardSelectionTakes(selectionID: selectionID)
                        let scenes = try await database.fetchScenes(projectID: projectID)
                        let liveIDs = Set(scenes.map(\.id))
                        let liveRuns = Set(scenes.compactMap(\.runID))
                        let footageChanged = previous.contains { WizardSelectionRules.resolvedPlan($0.plan, scenes: scenes) == nil }
                        if (options.sourceSceneSelection && (!options.sourceSceneIDs.isSubset(of: liveIDs) || footageChanged))
                            || (!options.selectedRunIDs.isEmpty && options.selectedRunIDs.isDisjoint(with: liveRuns)) {
                            // Re-analysis removed an explicit scene/batch restriction. Stay on
                            // the same source videos instead of falling back to the whole project.
                            let paths = Set(previous.flatMap { $0.plan.footage ?? [] }.compactMap(\.videoPath))
                            guard !paths.isEmpty else { throw WizardSelectionError.footageChanged }
                            options.sourceSceneSelection = false
                            options.sourceSceneIDs = []
                            options.sourceVideoPaths = paths
                            options.sourcesRestricted = true
                            options.selectedRunIDs = []
                            appendLog(\.wizardLog, ["Source analysis changed — finding moments in the same source videos."])
                        }
                    }
                    options.projectID = projectID
                    options.accountBenchmarks = igBenchmarks
                    options.localHashtags = OnDevicePolicy.isEnabled(item: "hashtags", config: settings.ai)
                    let result = try await wizard.findMoments(options: options, note: note, previousTakes: previous,
                        profile: profile, database: database, emit: wizardSelectionLogSink())
                    let best = try await wizard.iterateTakes(first: result.take, options: options,
                        profile: profile, database: database, emit: wizardSelectionLogSink())
                    try Task.checkCancellation()
                    guard generation == profileGeneration, activeProjectID == projectID else { return }
                    await refreshWizardSelections()
                    // Release the running gate before opening the review. Dismissal has
                    // already completed, even when a fake/fast planner returns immediately.
                    finishWizardSelectionWork(generation: generation)
                    openWizardSelection(best.selectionID, takeID: best.id, options: options)
                } catch is CancellationError { appendLog(\.wizardLog, ["Finding moments stopped."]) }
                catch { if generation == profileGeneration { presentError("Could not find the moments", error) } }
            }
        }
    }

    /// Render and Accept change only the look; content iteration belongs to step 1.
    func renderWizardSelection(_ selectionID: Int64, takeID: Int64? = nil, options: WizardOptions) {
        guard let database, let projectID = activeProjectID, !isWizardRunning else { return }
        var options = options
        options.projectID = projectID
        options.accountBenchmarks = igBenchmarks
        options.localHashtags = OnDevicePolicy.isEnabled(item: "hashtags", config: settings.ai)
        let generation = profileGeneration
        let profile = activeProfile
        let wizard = wizard
        beginWizardSelectionWork(projectID: projectID, stage: "Making the reel", options: options)
        wizardTask = Task {
            await AIRunCapture.context.withValue(AIRunCapture()) {
                defer { finishWizardSelectionWork(generation: generation) }
                let previousIDs = Set(((try? await database.fetchGeneratedVideos(projectID: projectID)) ?? []).map(\.id))
                do {
                    try await wizardSelectionSaveTask?.value
                    guard let selection = try await database.wizardSelection(id: selectionID),
                          selection.projectID == projectID else { throw WizardSelectionError.missingSelection }
                    let takes = try await database.fetchWizardSelectionTakes(selectionID: selectionID)
                    guard let take = takes.first(where: { $0.id == (takeID ?? selection.bestTakeID) }) ?? takes.last else {
                        throw WizardSelectionError.missingTake
                    }
                    try await wizard.makeReel(take: take, options: options, profile: profile,
                        database: database, batchID: UUID().uuidString, emit: wizardSelectionLogSink())
                } catch is CancellationError { appendLog(\.wizardLog, ["Render stopped."]) }
                catch { if generation == profileGeneration { presentError("Could not make the reel", error) } }
                guard generation == profileGeneration else { return }
                await refreshAllNow()
                await refreshWizardSelections()
                let fresh = ((try? await database.fetchGeneratedVideos(projectID: projectID)) ?? [])
                    .filter { !previousIDs.contains($0.id) }.sorted { $0.id < $1.id }
                if !fresh.isEmpty {
                    wizardResults = WizardRunResults(videos: fresh)
                    await recordWizardTimelines(fresh, projectID: projectID, formatName: options.formatPreset)
                }
            }
        }
    }

    func beginWizardSelectionWork(projectID: Int64, stage: String, options: WizardOptions) {
        isWizardRunning = true
        wizardProjectID = projectID
        wizardProjectName = projects.first { $0.id == projectID }?.name
        wizardStatus = WizardRunStatus(stage: stage, fraction: 0)
        wizardLog = []
        wizardFailureMessage = nil
        lastWizardOptions = options
    }

    func finishWizardSelectionWork(generation: Int) {
        guard generation == profileGeneration else { return }
        isWizardRunning = false
        wizardStatus = nil
        wizardProjectID = nil
    }

    func wizardSelectionLogSink() -> @Sendable (String) -> Void {
        let generation = profileGeneration
        return { message in
            Task { @MainActor in
                guard generation == self.profileGeneration else { return }
                self.appendLog(\.wizardLog, [message])
                self.updateWizardStatus(from: message)
            }
        }
    }
}
