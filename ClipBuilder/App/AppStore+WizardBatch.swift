import Foundation

/// The render both wizards share: kept takes become separate videos or one
/// reel, rendered one after another with every caption requested up front,
/// traits and reports finishing while the next reel renders, and a timings
/// summary at the end. Express gathers its takes from its candidates; the
/// AI Wizard from its saved selections' best takes.
/// What the shared batch does with its takes: render them (Generate), or
/// build each one's Builder timeline with every setting applied (Open in Editor).
nonisolated enum WizardBatchMode: Sendable {
    case render, openInEditor
}

/// The batch's takes after the shared preparation, and the options they render with.
nonisolated struct WizardBatchTakes: Sendable {
    var takes: [WizardSelectionTake]
    var options: WizardOptions
    var tagFields: [PersonTagField]
}

extension AppStore {
    /// The steps Generate and Open in Editor share: gather the takes, choose
    /// the camera focus, combine into one reel, write the name tag text, and
    /// the one-reel hard-cut default.
    func prepareWizardBatchTakes(database: Database, profile: BrandProfile, options: WizardOptions,
                                 oneReel: Bool, cameraFocus: Bool,
                                 gatherTakes: @Sendable (Database) async throws -> [WizardSelectionTake],
                                 combine: @Sendable (Database, [WizardSelectionTake]) async throws -> WizardSelectionTake,
                                 stage: (String) -> Void,
                                 preparationSink: (_ stage: String?) -> @Sendable (String) -> Void) async throws -> WizardBatchTakes {
        let wizard = wizard
        var takes = try await gatherTakes(database)
        guard !takes.isEmpty else { throw WizardSelectionError.missingTake }
        if cameraFocus, options.requestedFraming.subject == .auto,
           takes.contains(where: { $0.plan.framing == nil }) {
            let name = "Choosing camera focus"
            stage(name)
            let emit = preparationSink(name)
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
            let emit = preparationSink(nil)
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
        return WizardBatchTakes(takes: takes, options: renderOptions, tagFields: tagFields)
    }

    func generateWizardBatch(projectID: Int64, options: WizardOptions, oneReel: Bool, cameraFocus: Bool,
                             formatName: String, stopMessage: String, failureTitle: String,
                             gatherTakes: @escaping @Sendable (Database) async throws -> [WizardSelectionTake],
                             combine: @escaping @Sendable (Database, [WizardSelectionTake]) async throws -> WizardSelectionTake,
                             source: WizardRunResults.Source = .wizard,
                             highlight: WizardHighlightCapture? = nil,
                             mode: WizardBatchMode = .render,
                             onResults: @escaping @MainActor () -> Void = {}) {
        guard let database, !isWizardRunning else { return }
        if mode == .openInEditor {
            openWizardBatchInEditor(database: database, projectID: projectID, options: options, oneReel: oneReel,
                                    cameraFocus: cameraFocus, gatherTakes: gatherTakes, combine: combine)
            return
        }
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
                    let prepared = try await prepareWizardBatchTakes(database: database, profile: profile,
                        options: options, oneReel: oneReel, cameraFocus: cameraFocus,
                        gatherTakes: gatherTakes, combine: combine,
                        stage: { stage in
                            wizardStatus = WizardRunStatus(stage: stage, fraction: 0)
                            appendLog(\.wizardLog, [stage])
                        },
                        preparationSink: { stage in sink(group: "Preparation", stage: stage) })
                    let takes = prepared.takes
                    let renderOptions = prepared.options
                    let tagFields = prepared.tagFields
                    // Each separate video owns a timeline, rather than becoming another version of the first.
                    let batches = takes.map { _ in UUID().uuidString }
                    renderBatches = Set(batches)
                    let count = takes.count
                    let preparedTagFields = tagFields
                    // Reels render one after another; each reel's traits and
                    // report run while the next reel renders.
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
                            emit: sink(group: "Reel \(index + 1) of \(count)", stage: stage))
                    }, finishEmit: { index, line in
                        sink(group: "Reel \(index + 1) of \(count)", prefix: "Reel \(index + 1): ")(line)
                    }, waiting: { pending in
                        Task { @MainActor in
                            guard generation == self.profileGeneration, self.isWizardRunning else { return }
                            self.wizardStatus = WizardRunStatus(
                                stage: pending == 1 ? "Finishing the last reel" : "Finishing \(pending) reels", fraction: 1)
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
                    wizardResults = WizardRunResults(videos: fresh, source: source)
                    await recordWizardTimelines(fresh, projectID: projectID, formatName: formatName)
                    if let highlight { await recordHighlights(forGenerated: fresh, projectID: projectID, capture: highlight) }
                }
            }
        }
    }

    /// The AI Wizard's Generate: every selection in this project that has a
    /// best take renders with the Settings card's look, as separate videos or
    /// one reel, like Express's kept candidates.
    func generateWizardSelections(options: WizardOptions, oneReel: Bool, selectionIDs: Set<Int64>? = nil,
                                  mode: WizardBatchMode = .render) {
        guard let projectID = activeProjectID else { return }
        let kept = wizardSelections.filter {
            $0.selection.projectID == projectID && $0.selection.bestTakeID != nil
                && (selectionIDs?.contains($0.id) ?? true)
        }
        guard !kept.isEmpty else { return }
        let refs = kept.map { ($0.id, $0.selection.bestTakeID!) }
        let combinedName = kept.count == 1 ? kept[0].selection.name : "\(kept[0].selection.name) + \(kept.count - 1) more"
        var options = options
        options.projectID = projectID
        options.accountBenchmarks = igBenchmarks
        options.localHashtags = OnDevicePolicy.isEnabled(item: "hashtags", config: settings.ai)
        let highlight = WizardHighlightCapture(flow: .fullSelection, settings: highlightSettings(options: options))
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
        }, highlight: highlight, mode: mode)
    }

    /// True while an Open in Editor job is building timelines for this project.
    func isOpeningWizardInEditor(projectID: Int64?) -> Bool {
        guard let projectID else { return false }
        return jobs.running.contains { $0.kind == .openInEditor && $0.projectID == projectID }
    }

    /// Open in Editor: the batch's shared preparation, then each reel's take
    /// becomes the document Generate would render (`WizardEngine.editorDocument`)
    /// saved as its own Builder timeline, named after its selection. A
    /// background job with a status-bar row; the first timeline opens in the
    /// Builder when every one is saved.
    private func openWizardBatchInEditor(database: Database, projectID: Int64, options: WizardOptions,
                                         oneReel: Bool, cameraFocus: Bool,
                                         gatherTakes: @escaping @Sendable (Database) async throws -> [WizardSelectionTake],
                                         combine: @escaping @Sendable (Database, [WizardSelectionTake]) async throws -> WizardSelectionTake) {
        guard !isOpeningWizardInEditor(projectID: projectID) else { return }
        let profile = activeProfile
        let generation = profileGeneration
        let wizard = wizard
        let project = projects.first { $0.id == projectID } ?? activeProject
        jobs.start(.openInEditor, title: "Open in Editor — \(project?.name ?? "Project")", project: project,
                   profileGeneration: generation, subjectID: "wizard-editor-\(projectID)") { [weak self] log in
            guard let self else { return nil }
            try await self.wizardSelectionSaveTask?.value
            try await self.sceneEditSaveTask?.value
            let prepared = try await self.prepareWizardBatchTakes(database: database, profile: profile,
                options: options, oneReel: oneReel, cameraFocus: cameraFocus,
                gatherTakes: gatherTakes, combine: combine,
                stage: { log($0) }, preparationSink: { _ in log })
            let count = prepared.takes.count
            // Every save goes through the database captured at the start; the
            // context is rechecked after every suspension so Stop or a profile
            // switch never saves a later reel into the wrong profile.
            func checkContext() throws {
                try Task.checkCancellation()
                guard self.profileGeneration == generation, self.database === database else { throw CancellationError() }
            }
            var created: [(id: Int64, name: String)] = []
            var failures: [String] = []
            for (index, take) in prepared.takes.enumerated() {
                try checkContext()
                log("PROGRESS:\(Double(index) / Double(max(1, count)))")
                log(count == 1 ? "Building the timeline…" : "Building timeline \(index + 1) of \(count)…")
                let selectionName = try? await database.wizardSelection(id: take.selectionID)?.name
                try checkContext()
                let base = selectionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = base.isEmpty ? (count == 1 ? "Wizard reel" : "Wizard reel \(index + 1)") : base
                do {
                    let document = try await wizard.editorDocument(take: take, options: prepared.options,
                        profile: profile, database: database, tagTextPrepared: true,
                        preparedTagFields: prepared.tagFields, emit: log)
                    try checkContext()
                    let data = try JSONEncoder().encode(document)
                    guard let json = String(data: data, encoding: .utf8) else {
                        throw AppJobEmptyResult(message: "Could not encode the timeline.")
                    }
                    let id = try await database.createTimeline(projectID: projectID, name: name, documentJSON: json)
                    try checkContext()
                    created.append((id, name))
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    try checkContext()
                    failures.append(name)
                    let reason = (error as? AppJobEmptyResult)?.message ?? error.userMessage
                    self.logEvent("job", "Open in Editor: \"\(name)\" failed: \(reason)")
                    log("Could not build \"\(name)\": \(reason)")
                }
            }
            try checkContext()
            let failureNote = failures.isEmpty ? ""
                : " Failed: \(failures.map { "\"\($0)\"" }.joined(separator: ", "))."
            guard let first = created.first else {
                throw AppJobEmptyResult(message: count == 1 ? "Could not build the timeline.\(failureNote)"
                                        : "Could not build any of the \(count) timelines.\(failureNote)")
            }
            // Open the first saved timeline only after every save finished and
            // the job still belongs to the active profile.
            let updatedProjects = try await database.fetchProjects()
            try checkContext()
            self.projects = updatedProjects
            if self.activeProjectID == projectID {
                let updatedTimelines = try await database.fetchTimelines(projectID: projectID)
                try checkContext()
                if self.activeProjectID == projectID {
                    self.timelines = updatedTimelines
                    if let timeline = updatedTimelines.first(where: { $0.id == first.id }) {
                        self.openTimelineRecord(timeline)
                        self.builderPlanResult = BuilderPlanResult(store: self, openRequested: false)
                    }
                }
            }
            log((created.count == 1 ? "Saved \"\(first.name)\" and opened it in the Builder."
                : "Saved \(created.count) timelines; opened \"\(first.name)\" in the Builder.") + failureNote)
            return nil
        }
    }
}
