import Foundation

/// The render both wizards share: kept takes become separate videos or one
/// reel, rendered one after another with every caption requested up front,
/// traits and reports finishing while the next reel renders, and a timings
/// summary at the end. Express gathers its takes from its candidates; the
/// AI Wizard from its saved selections' best takes.
/// What the shared batch does with its takes: render them (Generate),
/// build each one's Builder timeline with every setting applied (Open in
/// Editor), or render each one small and plain for a framing check (Rough cut).
nonisolated enum WizardBatchMode: Sendable {
    case render, openInEditor, roughCut
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
                             roughCutOverlays: RoughCutOverlays? = nil,
                             onResults: @escaping @MainActor () -> Void = {}) {
        guard let database, !isWizardRunning else { return }
        switch mode {
        case .openInEditor:
            openWizardBatchInEditor(database: database, projectID: projectID, options: options, oneReel: oneReel,
                                    cameraFocus: cameraFocus, gatherTakes: gatherTakes, combine: combine)
            return
        case .roughCut:
            // Preview opens the sheet with the cuts prepared, not rendered;
            // Play in the sheet renders them.
            // Express's sheet starts its Overlays tab from the page's choices.
            renderWizardBatchRoughCut(database: database, projectID: projectID, options: options, oneReel: oneReel,
                                      cameraFocus: cameraFocus, gatherTakes: gatherTakes, combine: combine,
                                      namespace: source == .express ? WizardAssistant.expressNamespace : WizardAssistant.fullNamespace,
                                      extras: RoughCutExtras(overlays: roughCutOverlays), renderCuts: false)
            return
        case .render:
            break
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

    /// True while a rough cut is rendering for this project.
    func isRoughCutRunning(projectID: Int64?) -> Bool {
        guard let projectID else { return false }
        return jobs.running.contains { $0.kind == .roughCut && $0.projectID == projectID }
    }

    /// True while either Builder-bound batch job (Open in Editor, Rough cut)
    /// runs for this project; Generate and both buttons wait for it.
    func isWizardBatchJobRunning(projectID: Int64?) -> Bool {
        isOpeningWizardInEditor(projectID: projectID) || isRoughCutRunning(projectID: projectID)
    }

    /// Where one rough cut job's files live: per profile database and per
    /// job, so a review still on screen never sees another job's files.
    nonisolated static func roughCutDirectory(database: Database, jobID: UUID) -> URL {
        SettingsStore.cacheDirectory.appendingPathComponent("rough-cuts", isDirectory: true)
            .appendingPathComponent(database.path.deletingPathExtension().lastPathComponent, isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    /// Deletes rough cut folders no retained job result still points at.
    private func pruneRoughCuts(keeping current: URL) {
        let live = Set(jobs.items.flatMap { job -> [URL] in
            guard case .roughCut(let review)? = job.result else { return [] }
            return review.cuts.compactMap { $0.url?.deletingLastPathComponent() }
        }).union([current])
        let root = current.deletingLastPathComponent()
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders where !live.contains { $0.standardizedFileURL == folder.standardizedFileURL } {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Rough cut: the batch's shared preparation with every non-framing
    /// layer turned off (`WizardRoughCut.options`), each take's document
    /// built as Open in Editor would, stripped (`WizardRoughCut.strip`) and
    /// rendered small through the exact-preview path. Nothing is saved to
    /// the library; the files sit in the cache until the next rough cut of
    /// the project. The result opens a player sheet with Generate.
    /// `renderCuts: false` stops after the documents are built: the review
    /// carries unrendered cuts and their preview clips, and the sheet's Play
    /// starts the render (`rerunRoughCut`).
    @discardableResult
    private func renderWizardBatchRoughCut(database: Database, projectID: Int64, options: WizardOptions,
                                           oneReel: Bool, cameraFocus: Bool,
                                           gatherTakes: @escaping @Sendable (Database) async throws -> [WizardSelectionTake],
                                           combine: @escaping @Sendable (Database, [WizardSelectionTake]) async throws -> WizardSelectionTake,
                                           namespace: String, requestID: UUID = UUID(),
                                           extras: RoughCutExtras = RoughCutExtras(), renderCuts: Bool = true) -> UUID? {
        guard !isWizardBatchJobRunning(projectID: projectID) else { return nil }
        let profile = activeProfile
        let generation = profileGeneration
        let wizard = wizard
        let renderer = multitrackRenderer
        let project = projects.first { $0.id == projectID } ?? activeProject
        let roughOptions = WizardRoughCut.options(options, extras: extras)
        let jobID = UUID()
        let directory = Self.roughCutDirectory(database: database, jobID: jobID)
        // The request outlives the job so the review sheet can run it again
        // with other framing; requests no retained review points at go.
        let retained = Set(jobs.items.compactMap { job -> UUID? in
            guard case .roughCut(let review)? = job.result else { return nil }
            return review.requestID
        })
        roughCutRequests = roughCutRequests.filter { retained.contains($0.key) }
        roughCutRequests[requestID] = RoughCutRequest(projectID: projectID, options: options, oneReel: oneReel,
            cameraFocus: cameraFocus, gatherTakes: gatherTakes, combine: combine, namespace: namespace)
        let framing = options.requestedFraming
        let canvasAspect = options.renderSettings.aspectRatio
        return jobs.start(.roughCut, title: "\(renderCuts ? "Rough cut" : "Rough cut preview") — \(project?.name ?? "Project")", project: project,
                   profileGeneration: generation, subjectID: "wizard-rough-\(projectID)") { [weak self] log in
            guard let self else { return nil }
            func checkContext() throws {
                try Task.checkCancellation()
                guard self.profileGeneration == generation, self.database === database else { throw CancellationError() }
            }
            try await self.wizardSelectionSaveTask?.value
            try await self.sceneEditSaveTask?.value
            let prepared = try await self.prepareWizardBatchTakes(database: database, profile: profile,
                options: roughOptions, oneReel: oneReel, cameraFocus: cameraFocus,
                gatherTakes: gatherTakes, combine: combine,
                stage: { log($0) }, preparationSink: { _ in log })
            // Preparation can return after a Stop; nothing on disk changes until
            // the job is known to be current.
            try checkContext()
            let count = prepared.takes.count
            if renderCuts {
                self.pruneRoughCuts(keeping: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            // The folder belongs to the review once the job returns it; until
            // then a failure or Stop takes it away.
            var handedOver = false
            defer { if renderCuts, !handedOver { try? FileManager.default.removeItem(at: directory) } }
            var cuts: [RoughCut] = []
            var failures: [String] = []
            var previewClips: [WizardPreviewClip] = []
            let editing = profile.editing ?? ProfileEditingDefaults(seedingFrom: SettingsStore.loadSettings())
            for (index, take) in prepared.takes.enumerated() {
                try checkContext()
                log("PROGRESS:\(Double(index) / Double(max(1, count)))")
                log(renderCuts ? (count == 1 ? "Rendering the rough cut…" : "Rendering rough cut \(index + 1) of \(count)…")
                    : (count == 1 ? "Preparing the rough cut…" : "Preparing rough cut \(index + 1) of \(count)…"))
                let selectionName = try? await database.wizardSelection(id: take.selectionID)?.name
                try checkContext()
                let base = selectionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = base.isEmpty ? (count == 1 ? "Rough cut" : "Rough cut \(index + 1)") : base
                do {
                    let document = WizardRoughCut.strip(try await wizard.editorDocument(take: take, options: prepared.options,
                        profile: profile, database: database, tagTextPrepared: true,
                        preparedTagFields: prepared.tagFields, emit: log), extras: extras)
                    try checkContext()
                    let sceneIDs = Set(take.sceneIDs).union(document.videoTrack.compactMap(\.sceneID))
                    let scenes = try await database.fetchScenes(ids: sceneIDs)
                    try checkContext()
                    let takeClips = WizardPreviewClips.rendered(document, take: take, name: name, scenes: scenes,
                                                                xfadeDuration: editing.transitions.xfadeDuration)
                    guard renderCuts else {
                        cuts.append(RoughCut(url: nil, name: name, duration: RoughCut.plannedDuration(of: takeClips),
                                             takeID: take.id))
                        previewClips += takeClips
                        continue
                    }
                    let result = try await renderer.render(document: document, scenes: scenes, profile: profile,
                                                           database: database, preview: true, emit: log)
                    // The exact-preview path leaves its file to the caller.
                    defer { try? FileManager.default.removeItem(at: result.url) }
                    try checkContext()
                    let destination = directory.appendingPathComponent("rough-\(index + 1).mp4")
                    try FileManager.default.copyItemReplacing(at: result.url, to: destination)
                    cuts.append(RoughCut(url: destination, name: name, duration: result.duration, takeID: take.id))
                    previewClips += takeClips
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    try checkContext()
                    failures.append(name)
                    self.logEvent("job", "Rough cut: \"\(name)\" failed: \(error.userMessage)")
                    log("Could not render \"\(name)\": \(error.userMessage)")
                }
            }
            try checkContext()
            let failureNote = failures.isEmpty ? ""
                : " Failed: \(failures.map { "\"\($0)\"" }.joined(separator: ", "))."
            guard !cuts.isEmpty else {
                let verb = renderCuts ? "render" : "prepare"
                throw AppJobEmptyResult(message: count == 1 ? "Could not \(verb) the rough cut.\(failureNote)"
                                        : "Could not \(verb) any of the \(count) rough cuts.\(failureNote)")
            }
            log((renderCuts ? (cuts.count == 1 ? "Rough cut ready (\(cuts[0].duration.timecode))." : "\(cuts.count) rough cuts ready.")
                : (cuts.count == 1 ? "Rough cut prepared; press play to render it." : "\(cuts.count) rough cuts prepared; press play to render them."))
                + failureNote)
            handedOver = true
            // What the sheet's framing rows need: the recordings behind the
            // takes and their footage type.
            let takeScenes = try await database.fetchScenes(ids: Set(prepared.takes.flatMap { take in
                take.sceneIDs + take.plan.clips.map(\.sceneID) }))
            let videoIDs = Array(Set(takeScenes.map(\.videoID))).sorted()
            let sourceType = videoIDs.lazy.compactMap { id in self.videos.first { $0.id == id }?.type }.first ?? .other
            return .roughCut(RoughCutReview(projectID: projectID, cuts: cuts, namespace: namespace, requestID: requestID,
                framing: framing, sourceType: sourceType, videoIDs: videoIDs, canvasAspect: canvasAspect,
                extras: extras, previewClips: previewClips))
        }
    }

    /// The review sheet's "Regenerate": the same takes, page and options
    /// as the stored request, with the sheet's framing, effect and
    /// transition. A new job; the open sheet watches it by the returned id
    /// and swaps in its cuts.
    @discardableResult
    func rerunRoughCut(requestID: UUID, framing: Framing, extras: RoughCutExtras = RoughCutExtras()) -> UUID? {
        guard let database, let request = roughCutRequests[requestID] else {
            presentNotice("Rough cut", "That rough cut's request is gone. Start a new one from the page.")
            return nil
        }
        guard !isWizardRunning, !isWizardBatchJobRunning(projectID: request.projectID) else {
            presentNotice("Rough cut", "The Wizard is already working on this project.")
            return nil
        }
        var options = request.options
        options.framing = framing
        roughCutRequests[requestID]?.options = options
        return renderWizardBatchRoughCut(database: database, projectID: request.projectID, options: options,
                                         oneReel: request.oneReel, cameraFocus: request.cameraFocus,
                                         gatherTakes: request.gatherTakes, combine: request.combine,
                                         namespace: request.namespace, requestID: requestID, extras: extras)
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
                    self.logEvent("error", "Open in Editor: \"\(name)\" failed: \(reason)")
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
