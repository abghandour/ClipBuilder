import Foundation

extension AppStore {
    /// Source/tab navigation is independent of AI generation and pick-saving work.
    func selectMiniFootage(flow: MiniWizardFlow) {
        guard let projectID = activeProjectID, let video = flow.video else { return }
        let kind = flow.effectiveFootageKind
        if miniFootageVideoID != video.id || miniFootageKind != kind
            || (kind == .highlights && miniFootageLength != flow.length) {
            cancelMiniFootageLoad()
        }
        MiniWizardRunCache.retain(&miniRuns, projectID: projectID, videoID: video.id, length: flow.length)
        loadMiniReel(projectID: projectID, videoID: video.id)
        miniFootageVideoID = video.id
        miniFootageKind = kind
        miniFootageLength = flow.length
    }

    func cancelMiniFootageLoad() {
        miniFootageTask?.cancel()
        miniFootageTask = nil
        miniFootageLoadID = nil
        isLoadingMiniFootage = false
        miniFootageStage = nil
    }

    func resetMiniFootage() {
        cancelMiniFootageLoad()
        clearMiniReel()
        miniRuns = [:]
        miniFootageVideoID = nil
    }

    func beginMiniFootageLoad(stage: String) -> UUID {
        cancelMiniFootageLoad()
        let id = UUID()
        miniFootageLoadID = id
        isLoadingMiniFootage = true
        miniFootageStage = stage
        return id
    }

    func finishMiniFootageLoad(_ id: UUID) {
        guard miniFootageLoadID == id else { return }
        miniFootageTask = nil
        miniFootageLoadID = nil
        isLoadingMiniFootage = false
        miniFootageStage = nil
    }

    /// Share the transcript cache with the transcript sheet and reject stale profile/edit reads.
    func miniTranscriptRows(videoID: Int64) async throws -> [TranscriptRow] {
        if let cached = blurbTranscripts[videoID] { return cached }
        guard let database else { throw CancellationError() }
        let generation = profileGeneration
        let version = transcriptCountsVersion
        let rows = try await database.fetchTranscripts(videoID: videoID)
        try Task.checkCancellation()
        guard generation == profileGeneration, version == transcriptCountsVersion else { throw CancellationError() }
        blurbTranscripts[videoID] = rows
        return rows
    }

    func generateMiniFootage(flow: MiniWizardFlow) {
        selectMiniFootage(flow: flow)
        if flow.effectiveFootageKind == .qa {
            loadMiniQA(flow: flow)
            return
        }
        if flow.effectiveFootageKind == .transcript {
            loadMiniTranscript(flow: flow)
            return
        }
        if flow.effectiveFootageKind == .fightMetrics {
            loadMiniFight(flow: flow)
            return
        }
        guard let video = flow.video, flow.effectiveFootageKind == .highlights,
              let database, let projectID = activeProjectID, !isWizardRunning else { return }
        guard video.isPresent else { presentError(VideoRecord.notPresentReason); return }
        var options = WizardOptions()
        options.projectID = projectID
        options.sourceVideoPaths = [video.path ?? ""]
        options.sourcesRestricted = true
        options.formatPreset = flow.isPodcastOrInterview ? ReelRecipe.podcastHighlights.id : "custom"
        options.targetDurationSeconds = flow.length.seconds
        options.highlightMaxSeconds = flow.length.seconds.map(Double.init) ?? editingDefaults.podcast.highlightMaxSeconds
        options.highlightMaxCount = 3
        options.aiInstructions = activeProfile.miniInstructions ?? ""
        options.useBRoll = flow.isPodcastOrInterview && MiniWizardSettings.remembered(profile: activeProfile).includesBRoll
        options.manualBRoll = true
        options.critiqueLoop = false
        options.workflow = .automatic
        let previousPlans: [WizardPlan] = miniRun.flatMap { $0.video.id == video.id && $0.footageKind == .highlights ? $0.candidates.map { $0.take.plan } : nil } ?? []
        let profile = activeProfile
        let generation = profileGeneration
        let podcastSettings = podcastEditingSettings
        let wizard = wizard
        cancelMiniFootageLoad()
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
                            .map { MiniBRollRules.preservingCuts(in: $0, from: previousPlans) }
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
                    UserDefaults.standard.set(batch, forKey: MiniWizardMemory.batchKey(profileName: profile.profileName,
                        projectID: projectID, videoID: video.id, kind: .highlights, length: flow.length))
                    miniRuns[.highlights] = MiniWizardRun(projectID: projectID, video: video, footageKind: .highlights,
                        length: flow.length, batchID: batch, candidates: candidates, options: options,
                        selectedSelectionID: candidates.first?.id)
                    appendLog(\.wizardLog, ["Express: \(candidates.count) candidates ready to review."])
                    await recordHighlightCandidates(candidates, projectID: projectID, flow: .expressHighlights,
                        batchID: batch, settings: highlightSettings(options: options, length: flow.length))
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
        let podcastSettings = podcastEditingSettings
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
                        options.useBRoll = MiniWizardSettings.remembered(profile: profile).includesBRoll
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
                        let reviewed = MiniBRollRules.preservingCuts(in: plan,
                            from: run.candidates.filter { $0.id == selectionID }.map { $0.take.plan })
                        try Task.checkCancellation()
                        take = try await database.recordWizardTake(projectID: run.projectID, selectionID: selectionID,
                            options: run.options.step1, plan: reviewed, note: feedback)
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
                    if let candidate = miniRun?.candidates[index] {
                        let parent = try? await database.latestHighlightID(projectID: run.projectID, selectionID: selectionID)
                        let typed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        await recordHighlightCandidates([candidate], projectID: run.projectID, flow: .expressHighlights,
                            batchID: run.batchID, settings: highlightSettings(options: run.options, length: run.length),
                            parentID: parent, note: typed.isEmpty ? nil : typed)
                    }
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
        guard video.isPresent else { presentError(VideoRecord.notPresentReason); return }
        var options = WizardOptions()
        options.projectID = projectID
        options.sourceVideoPaths = [video.path ?? ""]
        options.sourcesRestricted = true
        options.formatPreset = "podcast"
        options.useBRoll = flow.isPodcastOrInterview && MiniWizardSettings.remembered(profile: activeProfile).includesBRoll
        options.manualBRoll = true
        options.critiqueLoop = false
        options.workflow = .automatic
        selectMiniFootage(flow: flow)
        guard miniRuns[.qa] == nil, !isLoadingMiniFootage else { return }
        let loadID = beginMiniFootageLoad(stage: "Loading Q&A exchanges")
        miniFootageTask = Task {
            defer { finishMiniFootageLoad(loadID) }
            do {
                try await sceneEditSaveTask?.value
                try Task.checkCancellation()
                let rows = try await miniTranscriptRows(videoID: video.id)
                let scenes = try await database.fetchScenes(projectID: projectID, scope: .active, includeExcluded: true)
                    .filter { $0.videoID == video.id }
                guard generation == profileGeneration, activeProjectID == projectID else { return }
                let speakers = await speakerTurns(videoID: video.id)
                try Task.checkCancellation()
                guard generation == profileGeneration, activeProjectID == projectID else { return }
                let people = people
                let fromOlderTranscript = AnalysisCoverage.exchangesFromOtherTranscript(
                    run: activeLayer(videoID: video.id).run,
                    transcriptKey: rows.first { !$0.isTranslation }?.transcriptionKey)
                // Kept exchanges live in qa_picks per project; the old
                // per-profile UserDefaults list is imported once.
                let profileName = activeProfile.profileName
                let legacyKept = MiniWizardMemory.qaKept(profileName: profileName, videoID: video.id)
                _ = try? await qaPickSaveTask?.value
                let rememberedOrder = try await database.fetchQAPicks(projectID: projectID, videoID: video.id,
                                                                      importing: legacyKept.sorted())
                let remembered = Set(rememberedOrder)
                if !legacyKept.isEmpty { MiniWizardMemory.saveQAKept([], profileName: profileName, videoID: video.id) }
                try Task.checkCancellation()
                guard generation == profileGeneration, activeProjectID == projectID else { return }
                let qa = await Task.detached(priority: .userInitiated) {
                    let namedTurns = TranscriptSpeakers.named(speakers.turns, roster: speakers.roster)
                    let labels = rows.reduce(into: [Int64: String]()) { labels, row in
                        labels[row.id] = TranscriptSpeakers.label(for: row, turns: namedTurns,
                                                                 roster: speakers.roster, people: people)
                    }
                    let sections = TranscriptQASections.sections(scenes: scenes, rows: rows, labels: labels)
                    // Nothing is kept until selected; restore only exchanges still present.
                    return MiniWizardQA(sections: sections, rows: rows, labels: labels,
                        turns: speakers.turns, kept: remembered.intersection(Set(sections.map(\.id))),
                        keptOrder: rememberedOrder.filter { id in sections.contains { $0.id == id } },
                        speakerSpans: TranscriptSpeakers.spans(turns: namedTurns, roster: speakers.roster),
                        fromOlderTranscript: fromOlderTranscript)
                }.value
                try Task.checkCancellation()
                guard miniFootageLoadID == loadID, generation == profileGeneration else { return }
                let batch = MiniWizardMemory.batchID(profileName: activeProfile.profileName,
                    projectID: projectID, videoID: video.id, kind: .qa)
                let saved = try await database.miniSavedCandidates(projectID: projectID, miniBatch: batch)
                guard !Task.isCancelled, generation == profileGeneration, activeProjectID == projectID else { return }
                guard miniFootageLoadID == loadID else { return }
                miniRuns[.qa] = MiniWizardRun(projectID: projectID, video: video, footageKind: .qa,
                    length: .automatic, batchID: batch, candidates: saved, options: options, qa: qa)
                appendLog(\.wizardLog, ["Express: \(qa.sections.count) Q&A exchanges ready to review."])
            } catch is CancellationError {
                if miniFootageLoadID == loadID, generation == profileGeneration { appendLog(\.wizardLog, ["Loading Q&A stopped."]) }
            } catch {
                if !Task.isCancelled, miniFootageLoadID == loadID, generation == profileGeneration { presentError("Could not load Q&A exchanges", error) }
            }
        }
    }

    /// Scene edits are shared with the Transcript sheet; keep its saved ranges visible in Mini.
    func refreshMiniQASections() {
        guard !isLoadingProject, let run = miniRuns[.qa], run.projectID == activeProjectID,
              var qa = run.qa else { return }
        qa.sections = TranscriptQASections.sections(scenes: scenes.filter { $0.videoID == run.video.id },
                                                   rows: qa.rows, labels: qa.labels)
        qa.kept.formIntersection(Set(qa.sections.map(\.id)))
        qa.keptOrder.removeAll { !qa.kept.contains($0) }
        // Grouping the exchanges again lands a run made from the current
        // transcript; the warning goes with it.
        qa.fromOlderTranscript = AnalysisCoverage.exchangesFromOtherTranscript(
            run: activeLayer(videoID: run.video.id).run,
            transcriptKey: qa.rows.first { !$0.isTranslation }?.transcriptionKey)
        miniRuns[.qa]?.qa = qa
    }

    /// Ticking an exchange saves only that change (insert or delete the
    /// toggled scenes' qa_picks rows), never a rewrite of the whole list,
    /// so kept exchanges a teammate synced in are not deleted.
    func setMiniQAKept(_ kept: Set<Int64>, batchID: String) {
        guard let run = miniRuns[.qa], run.batchID == batchID,
              run.projectID == activeProjectID, let qa = run.qa, let database else { return }
        miniRuns[.qa]?.qa?.kept = kept
        let sectionIDs = qa.sections.map(\.id)
        // Already-kept exchanges keep their list order; new ticks join in
        // transcript order after them.
        let ordered = qa.keptOrder.filter(kept.contains)
            + sectionIDs.filter { kept.contains($0) && !qa.keptOrder.contains($0) }
            + kept.subtracting(sectionIDs).subtracting(qa.keptOrder).sorted()
        miniRuns[.qa]?.qa?.keptOrder = ordered
        let added = kept.subtracting(qa.kept)
        let inserted = ordered.filter(added.contains)
        let deleted = Array(qa.kept.subtracting(kept))
        guard !inserted.isEmpty || !deleted.isEmpty else { return }
        let projectID = run.projectID
        let videoID = run.video.id
        let previous = qaPickSaveTask
        let generation = profileGeneration
        qaPickSaveTask = Task {
            _ = try? await previous?.value
            do {
                try await database.applyQAPickDelta(projectID: projectID, videoID: videoID,
                                                    inserted: inserted, deleted: deleted)
            } catch {
                if generation == profileGeneration { presentError("Could not save the kept exchanges", error) }
                throw error
            }
        }
    }

    /// `ids` is the kept list in its new order; a rewrite of qa_picks.
    func reorderMiniQAKept(_ ids: [Int64], batchID: String) {
        guard let run = miniRuns[.qa], run.batchID == batchID,
              run.projectID == activeProjectID, let qa = run.qa, let database, !isWizardRunning else { return }
        let ordered = ids.filter(qa.kept.contains) + qa.keptOrder.filter { !ids.contains($0) }
            + qa.kept.subtracting(ids).subtracting(qa.keptOrder).sorted()
        guard ordered != qa.keptOrder else { return }
        miniRuns[.qa]?.qa?.keptOrder = ordered
        let projectID = run.projectID
        let videoID = run.video.id
        let previous = qaPickSaveTask
        let generation = profileGeneration
        qaPickSaveTask = Task {
            _ = try? await previous?.value
            do {
                try await database.reorderQAPicks(projectID: projectID, videoID: videoID, sceneIDs: ordered)
            } catch {
                if generation == profileGeneration { presentError("Could not reorder the kept exchanges", error) }
                throw error
            }
        }
    }

    /// Reorders the Highlights candidates; remembered next to their kept state.
    func reorderMiniHighlightCandidates(_ ids: [Int64], batchID: String) {
        guard let run = miniRun, run.batchID == batchID, run.footageKind == .highlights, !isWizardRunning else { return }
        let byID = Dictionary(run.candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { byID[$0] } + run.candidates.filter { !ids.contains($0.id) }
        guard ordered.map(\.id) != run.candidates.map(\.id) else { return }
        miniRun?.candidates = ordered
        UserDefaults.standard.set(ordered.map { String($0.id) }, forKey: MiniWizardMemory.highlightOrderKey(batchID))
    }

    /// After a Team Sync pull that changed Express picks, reload the picks
    /// of every open Express run from the database, once that kind's pending
    /// local writes have finished. A write queued meanwhile wins: the run is
    /// left alone and the next pull reloads it.
    func refreshMiniPicksAfterSync(changedTables: Set<String>) async {
        guard let database, !isWizardRunning else { return }
        let generation = profileGeneration
        if changedTables.contains("transcript_picks"), let run = miniRuns[.transcript], run.transcript != nil {
            let pending = transcriptPickSaveTask
            _ = try? await pending?.value
            if let picks = try? await database.fetchTranscriptPicks(projectID: run.projectID, videoID: run.video.id),
               generation == profileGeneration, transcriptPickSaveTask == pending, !isWizardRunning,
               miniRuns[.transcript]?.batchID == run.batchID, miniRuns[.transcript]?.transcript != nil {
                miniRuns[.transcript]?.transcript?.picks = picks
            }
        }
        if changedTables.contains("fight_picks"), let run = miniRuns[.fightMetrics], run.fight != nil {
            let pending = fightPickSaveTask
            _ = try? await pending?.value
            if let picks = try? await database.fetchFightPicks(projectID: run.projectID, videoID: run.video.id),
               generation == profileGeneration, fightPickSaveTask == pending, !isWizardRunning,
               miniRuns[.fightMetrics]?.batchID == run.batchID, miniRuns[.fightMetrics]?.fight != nil {
                miniRuns[.fightMetrics]?.fight?.picks = picks
            }
        }
        if changedTables.contains("qa_picks"), let run = miniRuns[.qa], run.qa != nil {
            let pending = qaPickSaveTask
            _ = try? await pending?.value
            if let kept = try? await database.fetchQAPicks(projectID: run.projectID, videoID: run.video.id),
               generation == profileGeneration, qaPickSaveTask == pending, !isWizardRunning,
               miniRuns[.qa]?.batchID == run.batchID, let qa = miniRuns[.qa]?.qa {
                miniRuns[.qa]?.qa?.kept = Set(kept).intersection(qa.sections.map(\.id))
                miniRuns[.qa]?.qa?.keptOrder = kept.filter { id in qa.sections.contains { $0.id == id } }
            }
        }
    }

    /// Save the chosen ranges, preserving manual source-clock cutaways.
    func recordMiniQASelections(opening card: MiniWizardFlow.Card = .settings, then: @escaping @MainActor () -> Void = {}) {
        guard let run = miniRuns[.qa], run.projectID == activeProjectID,
              let qa = run.qa, run.keptCount > 0, let database, !isWizardRunning else { return }
        let generation = profileGeneration
        beginWizardSelectionWork(projectID: run.projectID, stage: "Saving Q&A selections", options: run.options)
        wizardTask = Task {
            var saved = false
            defer {
                finishWizardSelectionWork(generation: generation)
                if saved, !Task.isCancelled, generation == profileGeneration,
                   activeProjectID == run.projectID, miniRuns[.qa]?.batchID == run.batchID { then() }
            }
            do {
                _ = try? await qaPickSaveTask?.value
                try await sceneEditSaveTask?.value
                try await wizardSelectionSaveTask?.value
                try Task.checkCancellation()
                guard generation == profileGeneration, activeProjectID == run.projectID,
                      miniRuns[.qa]?.batchID == run.batchID else { return }
                let candidates = try await database.replaceMiniQASelections(projectID: run.projectID,
                    videoID: run.video.id, miniBatch: run.batchID, kept: qa.kept, order: qa.keptOrder, rows: qa.rows,
                    labels: qa.labels, turns: qa.turns, options: run.options.step1)
                guard generation == profileGeneration, activeProjectID == run.projectID,
                      miniRuns[.qa]?.batchID == run.batchID else { return }
                miniRuns[.qa]?.candidates = candidates
                miniRuns[.qa]?.selectedSelectionID = candidates.first?.id
                refreshMiniQASections()
                miniRuns[.qa]?.requestedCard = candidates.isEmpty ? .footage : card
                saved = !candidates.isEmpty
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
    /// The render behind Generate, Preview and Edit: one reel from the
    /// candidates the reel names, in reel order, across every loaded section
    /// (`generateMiniReel` loads and records them first). The section on
    /// screen lends its options and batch to the combined take.
    func generateMiniVideos(settings miniSettings: MiniWizardSettings, flow: MiniWizardFlow,
                            mode: WizardBatchMode = .render) {
        guard let key = miniReelKey, key.projectID == activeProjectID, database != nil, !isWizardRunning else { return }
        let runs = miniRuns.filter { $0.value.projectID == key.projectID && $0.value.video.id == key.videoID }
        guard let run = runs[flow.effectiveFootageKind]
            ?? MiniReelRules.kinds(miniReelItems).compactMap({ runs[$0] }).first else { return }
        let candidates = MiniReelRules.candidates(items: miniReelItems, runs: runs)
        guard !candidates.isEmpty else { return }
        let batchIDs = Set(runs.values.map(\.batchID))
        let chosen = miniSettings.effective(for: flow,
            introAvailable: bumpers.contains { $0.placements.contains(.intro) },
            outroAvailable: bumpers.contains { $0.placements.contains(.outro) })
        let profile = activeProfile
        var base = run.options
        base.manualBRoll = true
        base.pacing = profile.defaultPacing
        base.critiqueLoop = false
        base.accountBenchmarks = igBenchmarks
        base.localHashtags = OnDevicePolicy.isEnabled(item: "hashtags", config: settings.ai)
        var step2 = chosen.previewOptions(profile: profile, base: base).step2
        // Chosen bumpers are stored by library path; resolve to this Mac's files.
        func bumperPath(_ libraryPath: String?, _ placement: BumperPlacement) -> String? {
            guard let libraryPath else { return nil }
            return bumpers.first { $0.libraryPath == libraryPath && $0.placements.contains(placement) }?.path
        }
        step2.introBumperPath = chosen.introVideo ? bumperPath(chosen.introBumper, .intro) : nil
        step2.outroBumperPath = chosen.outroVideo ? bumperPath(chosen.outroBumper, .outro) : nil
        let options = WizardOptions.merge(step1: base.step1, step2: step2, base: base)
        // Express's takes are gathered from its candidates; the render itself is
        // the batch both wizards share.
        let batchID = run.batchID
        let footageKind = run.footageKind
        let selectionIDs = candidates.map { ($0.id, $0.take.id) }
        let combinedName = candidates[0].selection.name
        let highlight = WizardHighlightCapture(flow: WizardHighlightFlow(footageKind: footageKind),
            settings: highlightSettings(options: options, run: run, mini: miniSettings, length: flow.length))
        generateWizardBatch(projectID: run.projectID, options: options, oneReel: true,
                            cameraFocus: flow.showsCameraFocus, formatName: run.options.formatPreset,
                            stopMessage: "Express rendering stopped.", failureTitle: "Could not generate Express reel",
                            gatherTakes: { database in
            var takes: [WizardSelectionTake] = []
            for (selectionID, takeID) in selectionIDs {
                try Task.checkCancellation()
                guard let selection = try await database.wizardSelection(id: selectionID),
                      selection.projectID == run.projectID, batchIDs.contains(selection.miniBatch ?? "") else {
                    throw WizardSelectionError.missingSelection
                }
                let saved = try await database.fetchWizardSelectionTakes(selectionID: selection.id)
                guard let take = saved.first(where: { $0.id == takeID })
                    ?? saved.first(where: { $0.id == selection.bestTakeID }) ?? saved.last else {
                    throw WizardSelectionError.missingTake
                }
                takes.append(take)
            }
            return takes
        }, combine: { database, takes in
            try await database.recordMiniCombinedTake(projectID: run.projectID, miniBatch: batchID,
                                                      allowedBatches: batchIDs, name: combinedName,
                                                      takes: takes, options: run.options.step1)
        }, source: .express, highlight: highlight, mode: mode,
           roughCutOverlays: mode == .roughCut ? RoughCutOverlays(settings: chosen, showsNameTags: flow.showsNameTags,
                                                                  showsCaptionLanguage: flow.offersCaptionLanguage) : nil,
           onResults: { [weak self] in
            // Results is the root sheet; its dismissal leaves Mini ready for another render.
            guard let self, self.miniRun?.batchID == batchID, footageKind == self.miniRun?.footageKind else { return }
            self.miniRun?.requestedCard = .settings
        })
    }
}
