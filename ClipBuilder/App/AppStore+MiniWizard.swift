import Foundation

extension AppStore {
    func generateMiniFootage(flow: MiniWizardFlow) {
        if flow.effectiveFootageKind == .qa {
            loadMiniQA(flow: flow)
            return
        }
        guard let video = flow.video, flow.effectiveFootageKind == .highlights,
              let database, let projectID = activeProjectID, !isWizardRunning else { return }
        var options = WizardOptions()
        options.projectID = projectID
        options.sourceVideoPaths = [video.path]
        options.sourcesRestricted = true
        options.formatPreset = flow.isPodcastOrInterview ? ReelRecipe.podcastHighlights.id : "custom"
        options.targetDurationSeconds = flow.length.seconds
        options.highlightMaxSeconds = flow.length.seconds.map(Double.init) ?? settings.podcast.highlightMaxSeconds
        options.highlightMaxCount = 3
        options.aiInstructions = activeProfile.miniInstructions ?? ""
        options.critiqueLoop = false
        options.workflow = .automatic
        let profile = activeProfile
        let generation = profileGeneration
        let podcastSettings = settings.podcast
        let wizard = wizard
        beginWizardSelectionWork(projectID: projectID, stage: "Finding Express highlights", options: options)
        wizardTask = Task {
            await AIRunCapture.context.withValue(AIRunCapture()) {
                defer { finishWizardSelectionWork(generation: generation) }
                do {
                    try await wizardSelectionSaveTask?.value
                    let batch: String
                    if flow.isPodcastOrInterview {
                        let review = try await wizard.findPodcastHighlights(options: options, settings: podcastSettings,
                            database: database, profile: profile, emit: wizardSelectionLogSink(),
                            requestText: options.aiInstructions, interpretRequest: false)
                        let plans = WizardEngine.miniHighlightPlans(review.candidates, videoID: video.id, scenes: review.scenes)
                        guard !plans.isEmpty else {
                            throw AIError.unusableResponse("No podcast highlights fit this length. Try another length or instructions.")
                        }
                        batch = UUID().uuidString
                        for (index, plan) in plans.prefix(3).enumerated() {
                            try Task.checkCancellation()
                            _ = try await database.recordWizardTake(projectID: projectID, options: options.step1,
                                plan: plan, miniBatch: batch, fallbackName: "Candidate \(index + 1)")
                        }
                    } else {
                        batch = try await wizard.findCandidates(count: 3, options: options, profile: profile,
                            database: database, emit: wizardSelectionLogSink()).miniBatch
                    }
                    let selections = try await database.fetchWizardSelections(projectID: projectID, miniBatch: batch)
                    var candidates: [MiniWizardCandidate] = []
                    for selection in selections {
                        if let take = try await database.fetchWizardSelectionTakes(selectionID: selection.id).last {
                            candidates.append(MiniWizardCandidate(selection: selection, take: take))
                        }
                    }
                    try Task.checkCancellation()
                    guard generation == profileGeneration, activeProjectID == projectID else { return }
                    miniRun = MiniWizardRun(projectID: projectID, video: video, footageKind: .highlights,
                        length: flow.length, batchID: batch, candidates: candidates, options: options,
                        selectedSelectionID: candidates.first?.id)
                    appendLog(\.wizardLog, ["Express: \(candidates.count) candidates ready to review."])
                    await refreshWizardSelections()
                } catch is CancellationError {
                    if generation == profileGeneration { appendLog(\.wizardLog, ["Finding Express footage stopped."]) }
                } catch {
                    if generation == profileGeneration { presentError("Could not find Express footage", error) }
                }
            }
        }
    }

    func regenerateMiniCandidate(selectionID: Int64, note: String) {
        guard let run = miniRun, run.footageKind == .highlights,
              run.projectID == activeProjectID, let database, !isWizardRunning,
              run.candidates.contains(where: { $0.id == selectionID }) else { return }
        let profile = activeProfile
        let generation = profileGeneration
        let wizard = wizard
        let podcastSettings = settings.podcast
        // Capture the current edited cuts, not the original planner response.
        let ranges = run.candidates.filter { $0.id != selectionID && $0.kept }
            .flatMap { WizardPlanRules.footageRanges($0.take.plan) }
        let rule = WizardPlanRules.avoidRangesRule(ranges)
        let feedback = [note.trimmingCharacters(in: .whitespacesAndNewlines), rule]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        beginWizardSelectionWork(projectID: run.projectID, stage: "Regenerating Express candidate", options: run.options)
        wizardTask = Task {
            await AIRunCapture.context.withValue(AIRunCapture()) {
                defer { finishWizardSelectionWork(generation: generation) }
                do {
                    try await wizardSelectionSaveTask?.value
                    guard let selection = try await database.wizardSelection(id: selectionID),
                          selection.projectID == run.projectID, selection.miniBatch == run.batchID else {
                        throw WizardSelectionError.missingSelection
                    }
                    let previous = try await database.fetchWizardSelectionTakes(selectionID: selectionID)
                    guard !previous.isEmpty else { throw WizardSelectionError.missingTake }
                    let take: WizardSelectionTake
                    if run.options.formatPreset == ReelRecipe.podcastHighlights.id {
                        var options = run.options
                        options.highlightMaxCount = 1
                        let request = [options.aiInstructions, feedback].filter { !$0.isEmpty }.joined(separator: "\n\n")
                        let review = try await wizard.findPodcastHighlights(options: options, settings: podcastSettings,
                            database: database, profile: profile, emit: wizardSelectionLogSink(), requestText: request,
                            interpretRequest: false, avoidingRanges: ranges)
                        guard let plan = WizardEngine.miniHighlightPlans(review.candidates,
                            videoID: run.video.id, scenes: review.scenes).first,
                              WizardPlanRules.avoidsRanges(plan, ranges: ranges) else {
                            throw AIError.unusableResponse("No replacement avoids the other kept candidates. Try another note or unkeep a candidate.")
                        }
                        try Task.checkCancellation()
                        take = try await database.recordWizardTake(projectID: run.projectID, selectionID: selectionID,
                            options: run.options.step1, plan: plan, note: feedback)
                    } else {
                        take = try await wizard.findMoments(options: run.options, note: feedback,
                            previousTakes: previous, avoidingRanges: ranges, profile: profile,
                            database: database, emit: wizardSelectionLogSink()).take
                    }
                    try Task.checkCancellation()
                    guard generation == profileGeneration, activeProjectID == run.projectID,
                          miniRun?.batchID == run.batchID,
                          let index = miniRun?.candidates.firstIndex(where: { $0.id == selectionID }) else { return }
                    miniRun?.candidates[index].take = take
                    miniRun?.candidates[index].note = ""
                    miniRun?.selectedSelectionID = selectionID
                    miniRun?.requestedCard = .footage
                    await refreshWizardSelections()
                } catch is CancellationError {
                    if generation == profileGeneration { appendLog(\.wizardLog, ["Regenerating Express candidate stopped."]) }
                } catch {
                    if generation == profileGeneration { presentError("Could not regenerate the candidate", error) }
                }
            }
        }
    }

    func saveMiniCandidatePlan(_ plan: WizardPlan, selectionID: Int64, takeID: Int64) {
        guard !isWizardRunning, miniRun?.projectID == activeProjectID,
              let index = miniRun?.candidates.firstIndex(where: { $0.id == selectionID && $0.take.id == takeID }) else { return }
        miniRun?.candidates[index].take.plan = plan
        miniRun?.candidates[index].take.criticScore = nil
        miniRun?.candidates[index].take.criticNotes = nil
        saveWizardTakePlan(plan, takeID: takeID)
    }
}

extension AppStore {
    /// Load the same stored rows, speaker labels and Q&A section rules as the Transcript sheet.
    private func loadMiniQA(flow: MiniWizardFlow) {
        guard let video = flow.video, let database, let projectID = activeProjectID, !isWizardRunning else { return }
        let generation = profileGeneration
        var options = WizardOptions()
        options.projectID = projectID
        options.sourceVideoPaths = [video.path]
        options.sourcesRestricted = true
        options.formatPreset = "podcast"
        options.critiqueLoop = false
        options.workflow = .automatic
        beginWizardSelectionWork(projectID: projectID, stage: "Loading Q&A exchanges", options: options)
        wizardTask = Task {
            defer { finishWizardSelectionWork(generation: generation) }
            do {
                try await sceneEditSaveTask?.value
                try Task.checkCancellation()
                let rows = try await database.fetchTranscripts(videoID: video.id)
                let scenes = try await database.fetchScenes(projectID: projectID, includeExcluded: true)
                    .filter { $0.videoID == video.id }
                guard generation == profileGeneration, activeProjectID == projectID else { return }
                let speakers = await speakerTurns(videoID: video.id)
                try Task.checkCancellation()
                guard generation == profileGeneration, activeProjectID == projectID else { return }
                let labels = rows.reduce(into: [Int64: String]()) { labels, row in
                    labels[row.id] = TranscriptSpeakers.label(for: row, turns: speakers.turns,
                                                             roster: speakers.roster, people: people)
                }
                let sections = TranscriptQASections.sections(scenes: scenes, rows: rows, labels: labels)
                let qa = MiniWizardQA(sections: sections, rows: rows, labels: labels,
                                      turns: speakers.turns, kept: Set(sections.map(\.id)))
                miniRun = MiniWizardRun(projectID: projectID, video: video, footageKind: .qa,
                    length: .automatic, batchID: UUID().uuidString, candidates: [], options: options, qa: qa)
                appendLog(\.wizardLog, ["Express: \(sections.count) Q&A exchanges ready to review."])
            } catch is CancellationError {
                if generation == profileGeneration { appendLog(\.wizardLog, ["Loading Q&A stopped."]) }
            } catch {
                if generation == profileGeneration { presentError("Could not load Q&A exchanges", error) }
            }
        }
    }

    /// Scene edits are shared with the Transcript sheet; keep its saved ranges visible in Mini.
    func refreshMiniQASections() {
        guard !isLoadingProject, let run = miniRun, run.projectID == activeProjectID,
              run.footageKind == .qa, var qa = run.qa else { return }
        qa.sections = TranscriptQASections.sections(scenes: scenes.filter { $0.videoID == run.video.id },
                                                   rows: qa.rows, labels: qa.labels)
        qa.kept.formIntersection(Set(qa.sections.map(\.id)))
        miniRun?.qa = qa
    }

    /// Moving to Settings creates saved takes without planning or rendering anything.
    func recordMiniQASelections() {
        guard let run = miniRun, run.projectID == activeProjectID, run.footageKind == .qa,
              let qa = run.qa, run.keptCount > 0, let database, !isWizardRunning else { return }
        let generation = profileGeneration
        beginWizardSelectionWork(projectID: run.projectID, stage: "Saving Q&A selections", options: run.options)
        wizardTask = Task {
            defer { finishWizardSelectionWork(generation: generation) }
            do {
                try await sceneEditSaveTask?.value
                try Task.checkCancellation()
                guard generation == profileGeneration, activeProjectID == run.projectID,
                      miniRun?.batchID == run.batchID else { return }
                let candidates = try await database.replaceMiniQASelections(projectID: run.projectID,
                    videoID: run.video.id, miniBatch: run.batchID, kept: qa.kept, rows: qa.rows,
                    labels: qa.labels, turns: qa.turns, options: run.options.step1)
                guard generation == profileGeneration, activeProjectID == run.projectID,
                      miniRun?.batchID == run.batchID else { return }
                miniRun?.candidates = candidates
                miniRun?.selectedSelectionID = candidates.first?.id
                refreshMiniQASections()
                miniRun?.requestedCard = candidates.isEmpty ? .footage : .settings
                appendLog(\.wizardLog, ["Express: saved \(candidates.count) Q&A selections."])
                await refreshWizardSelections()
            } catch is CancellationError {
                if generation == profileGeneration { appendLog(\.wizardLog, ["Saving Q&A selections stopped."]) }
            } catch {
                if generation == profileGeneration { presentError("Could not save Q&A selections", error) }
            }
        }
    }
}

extension AppStore {
    /// Render accepted takes sequentially; Stop prevents the remaining items from starting.
    func generateMiniVideos(settings miniSettings: MiniWizardSettings, flow: MiniWizardFlow, batchID: String) {
        guard let run = miniRun, run.batchID == batchID, run.projectID == activeProjectID,
              let database, !isWizardRunning else { return }
        let candidates = run.candidates.filter {
            $0.kept && !$0.take.plan.clips.isEmpty && (run.footageKind != .qa || run.qa?.kept.contains($0.take.sceneIDs.first ?? -1) == true)
        }
        guard !candidates.isEmpty else { return }
        let chosen = miniSettings.effective(for: flow,
            introAvailable: bumpers.contains { $0.placements.contains(.intro) },
            outroAvailable: bumpers.contains { $0.placements.contains(.outro) })
        let profile = activeProfile
        let generation = profileGeneration
        let wizard = wizard
        var base = run.options
        base.renderSettings = profile.defaultRenderSettings
        base.pacing = profile.defaultPacing
        base.critiqueLoop = false
        base.accountBenchmarks = igBenchmarks
        base.localHashtags = OnDevicePolicy.isEnabled(item: "hashtags", config: settings.ai)
        let step2 = chosen.step2Options(base: base.step2)
        let options = WizardOptions.merge(step1: base.step1, step2: step2, base: base)
        let count = flow.outputCount(keptCount: candidates.count)
        beginWizardSelectionWork(projectID: run.projectID, stage: "Making reel 1 of \(count)", options: options)
        wizardTask = Task {
            await AIRunCapture.context.withValue(AIRunCapture()) {
                defer { finishWizardSelectionWork(generation: generation) }
                var renderBatches: Set<String> = []
                do {
                    try await wizardSelectionSaveTask?.value
                    try await sceneEditSaveTask?.value
                    var takes: [WizardSelectionTake] = []
                    for candidate in candidates {
                        try Task.checkCancellation()
                        guard let selection = try await database.wizardSelection(id: candidate.id),
                              selection.projectID == run.projectID, selection.miniBatch == run.batchID else {
                            throw WizardSelectionError.missingSelection
                        }
                        let saved = try await database.fetchWizardSelectionTakes(selectionID: selection.id)
                        guard let take = saved.first(where: { $0.id == candidate.take.id })
                            ?? saved.first(where: { $0.id == selection.bestTakeID }) ?? saved.last else {
                            throw WizardSelectionError.missingTake
                        }
                        takes.append(take)
                    }
                    if flow.showsCameraFocus, options.highlightFraming == nil, options.podcastFraming != .original,
                       takes.contains(where: { $0.plan.framing == nil }) {
                        let stage = "Choosing camera focus"
                        wizardStatus = WizardRunStatus(stage: stage, fraction: 0)
                        appendLog(\.wizardLog, [stage])
                        takes = try await wizard.chooseCameraFocus(takes: takes, options: options,
                            profile: profile, database: database, emit: { message in
                                Task { @MainActor in
                                    guard generation == self.profileGeneration, self.isWizardRunning else { return }
                                    self.appendLog(\.wizardLog, [message])
                                    if self.wizardStatus?.stage == stage { self.wizardStatus?.detail = message }
                                }
                            })
                    }
                    if chosen.outputMode == .oneReel {
                        try Task.checkCancellation()
                        takes = [try await database.recordMiniCombinedTake(projectID: run.projectID,
                            miniBatch: run.batchID, name: candidates[0].selection.name,
                            takes: takes, options: run.options.step1)]
                    }
                    var tagFields: [PersonTagField] = []
                    if options.usesNameTags, var tagPlan = takes.first?.plan {
                        tagPlan.clips = takes.flatMap { $0.plan.clips }
                        let scenes = try await database.fetchScenes(projectID: run.projectID, includeExcluded: true)
                        tagFields = try await wizard.prepareTagText(plan: tagPlan, options: options, profile: profile,
                            sceneMap: Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) }),
                            database: database, emit: wizardSelectionLogSink())
                    }
                    for (index, take) in takes.enumerated() {
                        try Task.checkCancellation()
                        guard generation == profileGeneration else { throw CancellationError() }
                        let stage = "Making reel \(index + 1) of \(takes.count)"
                        wizardStatus = WizardRunStatus(stage: stage, fraction: Double(index) / Double(takes.count))
                        appendLog(\.wizardLog, [stage])
                        var renderOptions = options
                        if chosen.outputMode == .oneReel { renderOptions.allowedTransitions = ["cut"] }
                        let emit: @Sendable (String) -> Void = { message in
                            Task { @MainActor in
                                guard generation == self.profileGeneration, self.isWizardRunning,
                                      self.wizardStatus?.stage == stage else { return }
                                self.appendLog(\.wizardLog, [message])
                                self.wizardStatus?.detail = message
                            }
                        }
                        // Each separate video owns a timeline, rather than becoming another version of the first.
                        let renderBatch = UUID().uuidString
                        renderBatches.insert(renderBatch)
                        try await wizard.makeReel(take: take, options: renderOptions, profile: profile,
                            database: database, batchID: renderBatch, tagTextPrepared: true, preparedTagFields: tagFields, emit: emit)
                    }
                } catch is CancellationError {
                    if generation == profileGeneration { appendLog(\.wizardLog, ["Express rendering stopped."]) }
                } catch {
                    if generation == profileGeneration { presentError("Could not generate Express videos", error) }
                }
                guard generation == profileGeneration else { return }
                await refreshAllNow()
                guard generation == profileGeneration else { return }
                await refreshWizardSelections()
                let fresh = ((try? await database.fetchGeneratedVideos(projectID: run.projectID)) ?? [])
                    .filter { renderBatches.contains($0.batchID ?? "") }.sorted { $0.id < $1.id }
                guard generation == profileGeneration else { return }
                if !fresh.isEmpty {
                    // Results is the root sheet; its dismissal leaves Mini ready for another render.
                    if miniRun?.batchID == run.batchID { miniRun?.requestedCard = .settings }
                    wizardResults = WizardRunResults(videos: fresh)
                    await recordWizardTimelines(fresh, projectID: run.projectID, formatName: run.options.formatPreset)
                }
            }
        }
    }
}
