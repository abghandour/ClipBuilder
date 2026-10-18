import Foundation

/// The render both wizards share: kept takes become separate videos or one
/// reel, rendered one after another with every caption requested up front,
/// traits and reports finishing while the next reel renders, and a timings
/// summary at the end. Express gathers its takes from its candidates; the
/// AI Wizard from its saved selections' best takes.
extension AppStore {
    func generateWizardBatch(projectID: Int64, options: WizardOptions, oneReel: Bool, cameraFocus: Bool,
                             formatName: String, stopMessage: String, failureTitle: String,
                             gatherTakes: @escaping @Sendable (Database) async throws -> [WizardSelectionTake],
                             combine: @escaping @Sendable (Database, [WizardSelectionTake]) async throws -> WizardSelectionTake,
                             onResults: @escaping @MainActor () -> Void = {}) {
        guard let database, !isWizardRunning else { return }
        let profile = activeProfile
        let generation = profileGeneration
        let wizard = wizard
        beginWizardSelectionWork(projectID: projectID, stage: "Making reel 1", options: options)
        let timings = WizardTiming.Collector()
        let batchStarted = ContinuousClock.now
        wizardTask = Task {
            await AIRunCapture.context.withValue(AIRunCapture()) {
                defer { finishWizardSelectionWork(generation: generation) }
                var renderBatches: Set<String> = []
                // Timing lines fold into one summary per reel; everything else is logged.
                // Stage detail only follows lines from the stage on screen.
                func sink(group: String, stage: String? = nil, prefix: String = "") -> @Sendable (String) -> Void {
                    { message in
                        if timings.record(message, group: group) { return }
                        let line = message.hasPrefix("VIDEO:") ? message : prefix + message
                        Task { @MainActor in
                            guard generation == self.profileGeneration, self.isWizardRunning else { return }
                            self.appendLog(\.wizardLog, [line])
                            if let stage, self.wizardStatus?.stage == stage { self.wizardStatus?.detail = message }
                        }
                    }
                }
                do {
                    try await wizardSelectionSaveTask?.value
                    try await sceneEditSaveTask?.value
                    var takes = try await gatherTakes(database)
                    guard !takes.isEmpty else { throw WizardSelectionError.missingTake }
                    if cameraFocus, options.highlightFraming == nil, options.podcastFraming != .original,
                       takes.contains(where: { $0.plan.framing == nil }) {
                        let stage = "Choosing camera focus"
                        wizardStatus = WizardRunStatus(stage: stage, fraction: 0)
                        appendLog(\.wizardLog, [stage])
                        let emit = sink(group: "Preparation", stage: stage)
                        takes = try await WizardTiming.measure("camera focus", emit: emit) {
                            try await wizard.chooseCameraFocus(takes: takes, options: options,
                                                               profile: profile, database: database, emit: emit)
                        }
                    }
                    if oneReel, takes.count > 1 {
                        try Task.checkCancellation()
                        takes = [try await combine(database, takes)]
                    }
                    var tagFields: [PersonTagField] = []
                    if options.usesNameTags, var tagPlan = takes.first?.plan {
                        tagPlan.clips = takes.flatMap { $0.plan.clips }
                        let scenes = try await database.fetchScenes(ids: SceneReferences.ids(in: tagPlan))
                        let emit = sink(group: "Preparation")
                        tagFields = try await WizardTiming.measure("tag text", emit: emit) {
                            try await wizard.prepareTagText(plan: tagPlan, options: options, profile: profile,
                                sceneMap: Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) }),
                                database: database, emit: emit)
                        }
                    }
                    var renderOptions = options
                    // One reel joins takes with hard cuts unless the user chose a transition.
                    if oneReel, options.transitionChoice == nil {
                        renderOptions.allowedTransitions = ["cut"]
                    }
                    // Each separate video owns a timeline, rather than becoming another version of the first.
                    let batches = takes.map { _ in UUID().uuidString }
                    renderBatches = Set(batches)
                    let count = takes.count
                    let preparedTagFields = tagFields
                    // Every caption request starts now, so the last reel's model
                    // round trip has the whole batch of renders to hide behind.
                    let captions = await wizard.startCaptionRequests(takes: takes, options: renderOptions,
                        profile: profile, database: database) { index, line in
                        sink(group: "Reel \(index + 1) of \(count)")(line)
                    }
                    defer { captions.values.forEach { $0.cancel() } }
                    // Reels render one after another; each reel's social caption
                    // and report run while the next reel renders.
                    try await WizardReelBatch.run(count: count, render: { index in
                        guard await generation == self.profileGeneration else { throw CancellationError() }
                        let stage = "Making reel \(index + 1) of \(count)"
                        await MainActor.run {
                            self.wizardStatus = WizardRunStatus(stage: stage, fraction: Double(index) / Double(count))
                            self.appendLog(\.wizardLog, [stage])
                        }
                        return try await wizard.makeReel(take: takes[index], options: renderOptions, profile: profile,
                            database: database, batchID: batches[index], tagTextPrepared: true,
                            preparedTagFields: preparedTagFields, deferFinish: true,
                            captionRequest: captions[takes[index].id],
                            emit: sink(group: "Reel \(index + 1) of \(count)", stage: stage))
                    }, finishEmit: { index, line in
                        sink(group: "Reel \(index + 1) of \(count)", prefix: "Reel \(index + 1): ")(line)
                    }, waiting: { pending in
                        Task { @MainActor in
                            guard generation == self.profileGeneration, self.isWizardRunning else { return }
                            self.wizardStatus = WizardRunStatus(
                                stage: pending == 1 ? "Writing the last caption" : "Writing \(pending) captions", fraction: 1)
                        }
                    })
                } catch is CancellationError {
                    if generation == profileGeneration { appendLog(\.wizardLog, [stopMessage]) }
                } catch {
                    if generation == profileGeneration { presentError(failureTitle, error) }
                }
                guard generation == profileGeneration else { return }
                if !timings.groupNames.isEmpty {
                    appendLog(\.wizardLog, timings.summaryLines(total: WizardTiming.seconds(batchStarted.duration(to: .now))))
                }
                await refreshAllNow()
                guard generation == profileGeneration else { return }
                await refreshWizardSelections()
                let fresh = ((try? await database.fetchGeneratedVideos(projectID: projectID)) ?? [])
                    .filter { renderBatches.contains($0.batchID ?? "") }.sorted { $0.id < $1.id }
                guard generation == profileGeneration else { return }
                if !fresh.isEmpty {
                    onResults()
                    wizardResults = WizardRunResults(videos: fresh)
                    await recordWizardTimelines(fresh, projectID: projectID, formatName: formatName)
                }
            }
        }
    }

    /// The AI Wizard's Generate: every selection in this project that has a
    /// best take renders with the Settings card's look, as separate videos or
    /// one reel, like Express's kept candidates.
    func generateWizardSelections(options: WizardOptions, oneReel: Bool) {
        guard let projectID = activeProjectID else { return }
        let kept = wizardSelections.filter { $0.selection.projectID == projectID && $0.selection.bestTakeID != nil }
        guard !kept.isEmpty else { return }
        let refs = kept.map { ($0.id, $0.selection.bestTakeID!) }
        let combinedName = kept.count == 1 ? kept[0].selection.name : "\(kept[0].selection.name) + \(kept.count - 1) more"
        var options = options
        options.projectID = projectID
        options.accountBenchmarks = igBenchmarks
        options.localHashtags = OnDevicePolicy.isEnabled(item: "hashtags", config: settings.ai)
        generateWizardBatch(projectID: projectID, options: options, oneReel: oneReel,
                            cameraFocus: options.formatPreset == "podcast" || options.formatPreset == "interview",
                            formatName: options.formatPreset,
                            stopMessage: "Render stopped.", failureTitle: "Could not make the reels",
                            gatherTakes: { database in
            var takes: [WizardSelectionTake] = []
            for (selectionID, takeID) in refs {
                try Task.checkCancellation()
                guard let selection = try await database.wizardSelection(id: selectionID), selection.projectID == projectID else {
                    throw WizardSelectionError.missingSelection
                }
                let saved = try await database.fetchWizardSelectionTakes(selectionID: selectionID)
                guard let take = saved.first(where: { $0.id == takeID }) else { throw WizardSelectionError.missingTake }
                takes.append(take)
            }
            return takes
        }, combine: { database, takes in
            try await database.recordCombinedWizardTake(projectID: projectID, name: combinedName,
                                                        takes: takes, options: options.step1)
        })
    }
}
