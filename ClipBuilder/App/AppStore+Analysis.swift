import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - Analysis

    /// Batch name stamped at analysis time: "<video name without extension>
    /// MM/dd/yy", with a " v<n>" counter from the second batch of the same
    /// video on (the first stays unsuffixed).
    private static func analysisRunName(for video: VideoRecord, at date: Date = .now,
                                        existingBatchCount: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yy"
        let base = (video.filename as NSString).deletingPathExtension
        var name = "\(base) \(formatter.string(from: date))"
        if existingBatchCount >= 1 { name += " v\(existingBatchCount + 1)" }
        return name
    }

    /// Every run is a full pass that lands in a new analyze batch alongside
    /// any earlier ones — delete unwanted batches from the Scenes screen.
    func analyze(videos targets: [VideoRecord], provider: String? = nil, model: String? = nil,
                 includeFightScoring: Bool = true, originatingProjectName: String? = nil) {
        guard let database, !isAnalyzing else { return }
        isAnalyzing = true
        analysisCompletion = nil
        analyzingVideoIDs = Set(targets.map(\.id))
        analysisProjectName = originatingProjectName ?? activeProject?.name
        analysisLog = []
        analysisProgress = 0
        let profile = activeProfile
        let analyzer = analyzer
        // Instructions and sampling density come from the dispatch plan
        // sheet (persisted, so muted runs keep the last-used values).
        let instructions = UserDefaults.standard.string(forKey: "analysis.instructions") ?? ""
        let storedInterval = UserDefaults.standard.double(forKey: "analysis.sampleInterval")
        // People attribution is mandatory: the people-detection pass gates
        // tagging, and every scene must carry whoever is in it.
        let detectPeople = UserDefaults.standard.object(forKey: "analysis.detectPeople") as? Bool ?? true
        let autoZoomUnframed = UserDefaults.standard.bool(forKey: "analysis.autoZoomUnframed")
        let breakdownTags: [String] = UserDefaults.standard.bool(forKey: "analysis.autoBreakdown")
            ? (UserDefaults.standard.string(forKey: "analysis.breakdownTags") ?? "")
                .split(separator: ",").map(String.init)
            : []
        // Center Stage moved to curation: paths are computed per scene from
        // the Raw Scenes "Edit Scene" modal, never during analysis.
        // One-shot trim from the plan sheet — consumed and cleared here so a
        // leftover range never silently applies to a later run.
        let trimStart = UserDefaults.standard.object(forKey: "analysis.trimStart") as? Double
        let trimEnd = UserDefaults.standard.object(forKey: "analysis.trimEnd") as? Double
        UserDefaults.standard.removeObject(forKey: "analysis.trimStart")
        UserDefaults.standard.removeObject(forKey: "analysis.trimEnd")
        let trimRange: (start: Double, end: Double)? = {
            guard targets.count == 1, let trimStart, let trimEnd, trimEnd > trimStart else { return nil }
            return (trimStart, trimEnd)
        }()
        // One-shot required-people filter from the plan sheet's roster.
        let requiredPeopleKeys = (UserDefaults.standard.string(forKey: "analysis.requiredPeople") ?? "")
            .split(separator: ",").map(String.init)
        UserDefaults.standard.removeObject(forKey: "analysis.requiredPeople")
        let sampleInterval: Double? = storedInterval > 0 ? storedInterval : nil
        // Smart Sampling: phased analysis for long files, on unless switched off.
        let smartSampling = UserDefaults.standard.object(forKey: "analysis.smartSampling") as? Bool ?? true
        let pastedNotes = AISettingsJSON.decode([AnalysisRunNote].self, UserDefaults.standard.string(forKey: "analysis.pastedNotes"))
        UserDefaults.standard.removeObject(forKey: "analysis.pastedNotes")
        let includeTranscript = UserDefaults.standard.bool(forKey: "analysis.includeTranscript")
        let transcription = transcription
        let localClassification = OnDevicePolicy.isEnabled(item: "long-recording", config: settings.ai)
        let localPodcast = OnDevicePolicy.isEnabled(item: "podcast-exchanges", config: settings.ai)
        let podcastAnalysis = podcastAnalysis
        let language = settings.transcribeLanguage
        if !instructions.isEmpty { appendLog(\.analysisLog, ["Using analysis instructions: \(instructions)"]) }
        let generation = profileGeneration
        analysisTask = Task {
            await AIRunCapture.context.withValue(AIRunCapture()) {
            defer {
                isAnalyzing = false
                refreshAll()
            }
            // The roster's checked people become a hard filter: every kept
            // range must show ALL of them with most of their body visible.
            var instructions = instructions
            if !requiredPeopleKeys.isEmpty {
                let people = (try? await database.fetchPeople()) ?? []
                let names = requiredPeopleKeys.map { key in
                    people.first { $0.key == key }
                        .map { "\($0.displayName) (key \"\($0.key)\")" } ?? key
                }
                let filterLine = "HARD FILTER: Only include time ranges where ALL of these people are on screen AT THE SAME TIME, each with more than half of their body visible: "
                    + names.joined(separator: ", ")
                    + ". Omit every range where any of them is absent, mostly occluded, or barely in frame."
                instructions = instructions.isEmpty ? filterLine : filterLine + "\n" + instructions
                appendLog(\.analysisLog, ["Requiring people in every scene: \(names.joined(separator: ", "))"])
            }
            // The plan a fresh video's checkpoint carries, so a resumed run
            // keeps the settings it started with; the one-shot options were
            // consumed above and cannot be re-read later.
            let freshPlan = AnalysisCheckpoint.Plan(
                instructions: instructions, sampleInterval: sampleInterval,
                detectPeople: detectPeople, autoZoomUnframed: autoZoomUnframed, breakdownTags: breakdownTags,
                trimRange: trimRange.map { [$0.start, $0.end] }, requiredPeopleKeys: requiredPeopleKeys,
                pastedNotes: pastedNotes, smartSampling: smartSampling,
                includeTranscript: includeTranscript, includeFightScoring: includeFightScoring,
                provider: provider, model: model)
            // People first seen anywhere in this batch — reviewed once at the
            // end. Later videos already treat them as known (people are
            // refetched per video), so keys never repeat across videos.
            var newPeople: [DetectedNewPerson] = []
            var renameSuggestions: [RenameSuggestion] = []
            let runStarted = ContinuousClock.now
            var analyzed = 0, failed = 0
            for (index, video) in targets.enumerated() {
                if Task.isCancelled { break }
                analyzingVideoIDs = Set(targets[index...].map(\.id))
                AIRunCapture.current?.reset()
                var video = video
                let base = Double(index) / Double(targets.count)
                let span = 1.0 / Double(targets.count)
                // An interrupted run of this video carries on from its
                // checkpoint, under the settings it started with; anything
                // else starts a checkpoint of its own.
                var checkpoint: AnalysisCheckpoint
                var stopped = analysisCheckpoints[video.id]
                if stopped == nil { stopped = (try? await database.fetchAnalysisCheckpoint(videoID: video.id)) ?? nil }
                if let stopped {
                    checkpoint = stopped
                    checkpoint.lastError = nil
                    appendLog(\.analysisLog, ["\(video.filename): resuming the analysis stopped at \(stopped.percent)%"
                        + (stopped.stage.isEmpty ? "" : " (\(stopped.stage))") + " — keeping the settings of that run"])
                } else {
                    checkpoint = AnalysisCheckpoint(videoID: video.id, startedAt: .now, updatedAt: .now,
                                                    runName: "", plan: freshPlan)
                }
                let plan = checkpoint.plan
                let instructions = plan.instructions
                let sampleInterval = plan.sampleInterval
                let detectPeople = plan.detectPeople
                let autoZoomUnframed = plan.autoZoomUnframed
                let breakdownTags = plan.breakdownTags
                let smartSampling = plan.smartSampling
                let includeTranscript = plan.includeTranscript
                let includeFightScoring = plan.includeFightScoring
                let requiredPeopleKeys = plan.requiredPeopleKeys
                let pastedNotes = plan.pastedNotes
                let provider = plan.provider
                let model = plan.model
                let trimRange: (start: Double, end: Double)? = plan.trimRange.flatMap {
                    $0.count == 2 && $0[1] > $0[0] ? (start: $0[0], end: $0[1]) : nil
                }
                do {
                    let transcriptFeatures = localClassification ? ((try? await database.fetchTranscriptFeatures(videoID: video.id)) ?? []) : []
                    let speechFraction = transcriptFeatures.isEmpty ? nil : transcriptFeatures.filter { $0.kind == .speech }.reduce(0) { $0 + $1.endTime - $1.startTime } / max(1, video.duration)
                    let wantsCuts = (localClassification && video.type == nil && video.duration >= 300)
                        || (smartSampling && SmartSampling.appliesTo(duration: video.duration, customInterval: sampleInterval,
                                                                     trimmed: trimRange != nil, nativeVideo: false))
                    let cuts = wantsCuts ? await cachedDetectors(for: video)?.cuts : nil
                    if video.type == nil, video.duration >= 300,
                       let type = try await analyzer.classifyLongRecording(
                        video: video, provider: provider, model: model, log: logSink(\.analysisLog),
                        useLocal: localClassification, speechFraction: speechFraction, cuts: cuts) {
                        video.videoType = type.rawValue
                        try await database.setVideoType(id: video.id, type: type.rawValue)
                    }
                    let notes: [VideoNote]
                    if let pastedNotes {
                        notes = pastedNotes.enumerated().map {
                            VideoNote(id: Int64($0.offset), videoID: video.id, atTime: $0.element.at, note: $0.element.note)
                        }
                    } else {
                        notes = (try? await database.videoNotes(videoID: video.id)) ?? []
                    }
                    if !notes.isEmpty {
                        appendLog(\.analysisLog, ["\(video.filename): applying \(notes.count) timestamped note(s)"])
                    }
                    // Refetched per video so people discovered earlier in this
                    // batch keep their identity in the following videos.
                    let knownPeople = (try? await database.fetchPeople()) ?? []
                    let markers = (try? await database.personMarkers(videoID: video.id)) ?? []
                    // Counted from the DB right before the run, so mid-batch
                    // additions are seen and the v-counter never repeats.
                    let existingBatches = ((try? await database.fetchAnalysisRuns()) ?? [])
                        .count { $0.videoID == video.id }
                    let runName = checkpoint.runName.isEmpty
                        ? Self.analysisRunName(for: video, existingBatchCount: existingBatches)
                            + (trimRange.map { " (\($0.start.timecode)–\($0.end.timecode))" } ?? "")
                        : checkpoint.runName
                    checkpoint.runName = runName
                    await startAnalysisCheckpoint(checkpoint)
                    let videoID = video.id
                    let progress: @Sendable (Double, String) -> Void = { fraction, stage in
                        Task { @MainActor in
                            self.analysisProgress = base + span * fraction
                            self.analysisStage = stage
                            // Where the run is, for the resume prompt —
                            // written when the stage changes, not per tick.
                            if self.analysisCheckpoints[videoID]?.stage != stage {
                                await self.updateAnalysisCheckpoint(videoID: videoID) {
                                    $0.stage = stage
                                    $0.fraction = fraction
                                }
                            }
                        }
                    }
                    let runID: Int64?
                    let videoNewPeople: [DetectedNewPerson]
                    let suggestedFilename: String?
                    if let savedRunID = checkpoint.runID {
                        appendLog(\.analysisLog, ["\(video.filename): the analyze batch was saved before the stop — finishing the remaining steps"])
                        runID = savedRunID
                        videoNewPeople = checkpoint.newPeople
                        suggestedFilename = checkpoint.suggestedFilename
                    } else if video.type == .podcast {
                        let result = try await podcastAnalysis.analyze(
                            video: video, profile: profile, database: database,
                            runName: runName, provider: provider, model: model,
                            // Podcasts always perform the plan's EN/pt-BR-first
                            // detection; the generic transcription override is
                            // intentionally limited to non-podcast footage.
                            languageCode: "", analyzer: analyzer,
                            transcription: transcription,
                            highlightThreshold: settings.podcast.highlightThreshold,
                            holdSeconds: settings.podcast.speakerHoldSeconds,
                            log: logSink(\.analysisLog), progress: progress, useLocal: localPodcast,
                            checkpointing: PodcastCheckpointing(resume: checkpoint.podcast) { state in
                                await self.updateAnalysisCheckpoint(videoID: videoID) { $0.podcast = state }
                            })
                        runID = result.runID
                        videoNewPeople = result.newPeople
                        suggestedFilename = result.suggestedFilename
                        enqueueAutoTranslation(videoID: video.id)
                    } else {
                        let result = try await analyzer.analyzeVisual(
                            video: video, profile: profile, database: database,
                            runName: runName, provider: provider, model: model,
                            instructions: instructions, notes: notes,
                            knownPeople: knownPeople,
                            personMarkers: markers,
                            detectPeople: detectPeople,
                            autoZoomUnframed: autoZoomUnframed,
                            breakdownTags: breakdownTags,
                            trimRange: trimRange,
                            sampleInterval: sampleInterval,
                            smartSampling: smartSampling,
                            cuts: cuts,
                            force: true,
                            checkpointing: AnalysisCheckpointing(resume: checkpoint.visual) { state in
                                await self.updateAnalysisCheckpoint(videoID: videoID) { $0.visual = state }
                            },
                            log: logSink(\.analysisLog), progress: progress)
                        runID = result.runID
                        videoNewPeople = result.newPeople
                        suggestedFilename = result.suggestedFilename
                    }
                    if checkpoint.runID == nil {
                        // The batch is on disk: from here only the later
                        // stages remain, so the phase results can go.
                        checkpoint = await updateAnalysisCheckpoint(videoID: videoID) {
                            $0.runID = runID
                            $0.newPeople = videoNewPeople
                            $0.suggestedFilename = suggestedFilename
                            $0.visual = nil
                            $0.podcast = nil
                        } ?? checkpoint
                    }
                    if let runID, checkpoint.runID == runID, !checkpoint.transcriptDone, !checkpoint.fightScoringDone {
                        try await database.saveAnalysisSettings(id: runID, settings: AnalysisRunSettings(
                            instructions: instructions, sampleInterval: sampleInterval ?? 0,
                            includeTranscript: includeTranscript || video.type == .podcast, language: video.type == .podcast ? "" : language,
                            detectPeople: detectPeople, autoZoomUnframed: autoZoomUnframed, breakdownTags: breakdownTags,
                            smartSampling: smartSampling,
                            trimRange: trimRange.map { [$0.start, $0.end] }, notes: notes.map { AnalysisRunNote(at: $0.atTime, note: $0.note) },
                            provider: provider, model: model, videoPath: video.path, sourcePeople: requiredPeopleKeys, sourceProfile: profile.profileName))
                    }
                    let pendingKeys = Set(newPeople.map(\.key))
                    newPeople.append(contentsOf: videoNewPeople.filter { !pendingKeys.contains($0.key) })
                    if let suggestedFilename {
                        renameSuggestions.append(RenameSuggestion(videoID: video.id,
                                                                  currentFilename: video.filename,
                                                                  suggestedName: suggestedFilename))
                    }
                    if includeTranscript && video.type != .podcast && !checkpoint.transcriptDone {
                        // A transcript failure shouldn't undo a good analysis
                        // — log it and keep going.
                        do {
                            let existing = (try? await database.fetchTranscripts(videoID: video.id)) ?? []
                            if existing.isEmpty {
                                analysisStage = "transcribing"
                                _ = try await transcription.transcribe(
                                    video: video, database: database,
                                    languageCode: language,
                                    log: logSink(\.analysisLog))
                                appendLog(\.analysisLog, ["\(video.filename): transcript saved"])
                                enqueueAutoTranslation(videoID: video.id)
                            } else {
                                appendLog(\.analysisLog, ["\(video.filename): already has a transcript — keeping it"])
                            }
                            if let runID {
                                try? await database.markAnalysisRunTranscribed(id: runID)
                            }
                            // Talking footage gets the podcast pass's speaker map
                            // too: who speaks when, where they sit, so the
                            // Wizard can frame one person at a time.
                            if video.type == .interview {
                                analysisStage = "mapping speakers"
                                do {
                                    try await PodcastAnalysisService.mapSpeakers(
                                        video: video, database: database,
                                        holdSeconds: settings.podcast.speakerHoldSeconds,
                                        log: logSink(\.analysisLog))
                                } catch is CancellationError {
                                    break
                                } catch {
                                    appendLog(\.analysisLog, ["\(video.filename): speaker map failed — \(error.userMessage)"])
                                }
                            }
                            await updateAnalysisCheckpoint(videoID: videoID) { $0.transcriptDone = true }
                        } catch is CancellationError {
                            break
                        } catch {
                            appendLog(\.analysisLog, ["\(video.filename): transcription failed — \(error.userMessage)"])
                        }
                    }
                    // Fight scoring: dense pass over the fight scenes so the
                    // pace/winning graphs light up right after analysis.
                    if includeFightScoring && !checkpoint.fightScoringDone {
                        do {
                            analysisStage = "scoring fight action"
                            let allScenes = (try? await database.fetchScenes(includeExcluded: true)) ?? []
                            _ = try await analyzer.scoreFightAction(
                                video: video, scenes: allScenes.filter { $0.videoID == video.id },
                                profile: profile, database: database,
                                provider: provider, model: model,
                                log: logSink(\.analysisLog))
                            await updateAnalysisCheckpoint(videoID: videoID) { $0.fightScoringDone = true }
                        } catch is CancellationError {
                            break
                        } catch {
                            appendLog(\.analysisLog, ["\(video.filename): fight scoring failed — \(error.userMessage)"])
                        }
                    }
                    if let runID { try await database.updateAnalysisModels(id: runID) }
                    await clearAnalysisCheckpoint(videoID: videoID)
                    analyzed += 1
                    appendLog(\.analysisLog, ["\(video.filename): done"])
                } catch is CancellationError {
                    break
                } catch let error as AIError {
                    failed += 1
                    appendLog(\.analysisLog, ["\(video.filename): \(error)"])
                    let message = "\(error)"
                    await updateAnalysisCheckpoint(videoID: video.id) { $0.lastError = message }
                    if case .quotaExhausted = error {
                        appendLog(\.analysisLog, ["Quota exhausted — stopping the run."])
                        break
                    }
                } catch {
                    failed += 1
                    appendLog(\.analysisLog, ["\(video.filename): \(error.userMessage)"])
                    let message = error.userMessage
                    await updateAnalysisCheckpoint(videoID: video.id) { $0.lastError = message }
                }
            }
            analyzingVideoIDs = []
            let elapsed = runStarted.duration(to: .now).seconds
            let clock = String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
            if Task.isCancelled {
                let unfinished = targets.filter { analysisCheckpoints[$0.id] != nil }
                if !unfinished.isEmpty {
                    appendLog(\.analysisLog, ["Analysis stopped — \(unfinished.map(\.filename).joined(separator: ", ")) can resume from here: select and Analyze again."])
                }
                appendLog(\.analysisLog, ["Analysis stopped."])
                analysisStage = "stopped"
                analysisCompletion = AnalysisCompletion(summary: "Analysis stopped after \(clock) — \(analyzed) of \(targets.count) video\(targets.count == 1 ? "" : "s") finished.", failed: failed, stopped: true)
            } else {
                analysisProgress = 1
                analysisStage = "done"
                let names = targets.count == 1 ? targets[0].filename : "\(analyzed) of \(targets.count) videos"
                analysisCompletion = AnalysisCompletion(
                    summary: failed == 0 ? "Analyzed \(names) in \(clock). Scenes and people are ready on the Scenes screen."
                        : "Analyzed \(names) in \(clock); \(failed) failed — see the App Log.",
                    failed: failed, stopped: false)
            }
            // The run's video ids belong to the profile it started in.
            guard generation == profileGeneration else { return }
            if !newPeople.isEmpty {
                pendingPeopleReview = PeopleReviewRequest(people: newPeople)
            }
            // Presented via its own sheet — it waits behind the people
            // review when both exist.
            if !renameSuggestions.isEmpty {
                pendingRenameReview = RenameReviewRequest(suggestions: renameSuggestions)
            }
        }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    // MARK: - Automatic caption translation


    func enqueueAutoTranslation(videoID: Int64) {
        guard !settings.podcast.autoTranslateLanguage.isEmpty, !autoTranslateQueue.contains(videoID) else { return }
        autoTranslateQueue.append(videoID)
    }

    /// The head of the queue, claimed for one runner; nil while another
    /// claim stands or the queue is empty. Synchronous on the main actor,
    /// so overlapping runners cannot both take it.
    func claimAutoTranslation() -> Int64? {
        guard autoTranslateInFlight == nil, let videoID = autoTranslateQueue.first else { return nil }
        autoTranslateInFlight = videoID
        return videoID
    }

    /// A claimed video is done (translated, skipped or failed): drop it.
    /// A stale claim — the profile changed underneath — is ignored.
    func finishAutoTranslation(videoID: Int64) {
        guard autoTranslateInFlight == videoID else { return }
        autoTranslateInFlight = nil
        autoTranslateQueue.removeAll { $0 == videoID }
    }

    /// Give a claim back without dropping the video (the runner went away).
    func releaseAutoTranslation(videoID: Int64) {
        if autoTranslateInFlight == videoID { autoTranslateInFlight = nil }
    }

    // MARK: - Analysis checkpoints

    /// Record the start of a video's run; every later change goes through
    /// `updateAnalysisCheckpoint`.
    private func startAnalysisCheckpoint(_ checkpoint: AnalysisCheckpoint) async {
        analysisCheckpoints[checkpoint.videoID] = checkpoint
        try? await database?.saveAnalysisCheckpoint(checkpoint)
    }

    /// Apply a change to a video's checkpoint and write it through. The
    /// in-memory copy is updated before the write, so callers on the main
    /// actor never see a stale row between two updates.
    @discardableResult
    func updateAnalysisCheckpoint(videoID: Int64,
                                  _ mutate: @Sendable (inout AnalysisCheckpoint) -> Void) async -> AnalysisCheckpoint? {
        guard var checkpoint = analysisCheckpoints[videoID] else { return nil }
        mutate(&checkpoint)
        checkpoint.updatedAt = .now
        analysisCheckpoints[videoID] = checkpoint
        try? await database?.saveAnalysisCheckpoint(checkpoint)
        return checkpoint
    }

    private func clearAnalysisCheckpoint(videoID: Int64) async {
        analysisCheckpoints[videoID] = nil
        try? await database?.deleteAnalysisCheckpoint(videoID: videoID)
    }

    /// The user chose to start these videos over: forget where their
    /// interrupted runs got to.
    func discardAnalysisCheckpoints(videoIDs: [Int64]) async {
        for videoID in videoIDs { await clearAnalysisCheckpoint(videoID: videoID) }
    }

    // MARK: - Analyze batches

    /// Load a past batch's options back into the analysis settings and route
    /// to the Analyze tab with the plan sheet open — edit, then re-run.
    func reanalyzeBatch(_ run: AnalysisRun) {
        guard let video = videos.first(where: { $0.id == run.videoID }) else {
            presentError("The source video for this analyze batch is no longer in the library.")
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(run.instructions, forKey: "analysis.instructions")
        defaults.set(run.sampleInterval, forKey: "analysis.sampleInterval")
        defaults.set(run.hasTranscript, forKey: "analysis.includeTranscript")
        if let provider = run.provider {
            settings.ai.tasks["analysis"] = provider
            if let model = run.model { settings.ai.taskModels["analysis"] = model }
            saveSettings()
        }
        pendingAnalyzeSetup = video
        requestedSection = .analyze
    }

    func renameAnalysisRun(_ run: AnalysisRun, to rawName: String) {
        guard let database else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != run.name else { return }
        Task {
            do {
                try await database.renameAnalysisRun(id: run.id, name: name)
                await refreshAllNow()
            } catch {
                presentError("Could not rename the analyze batch", error)
            }
        }
    }

    /// Delete every analyze batch of the given videos, with their scenes,
    /// tags and grades; one refresh afterwards.
    func deleteAnalysisRuns(forVideos videoIDs: Set<Int64>) {
        guard let database else { return }
        let runs = analysisRuns.filter { videoIDs.contains($0.videoID) }
        guard !runs.isEmpty else { return }
        Task {
            do {
                for run in runs { try await database.deleteAnalysisRun(id: run.id) }
                appendLog(\.analysisLog, ["Removed \(runs.count) analyze batch(es) from \(videoIDs.count) video(s)"])
                await refreshAllNow()
            } catch {
                presentError("Could not remove the analyze batches", error)
            }
        }
    }

    /// Delete a batch with its scenes, tags, and grades.
    func deleteAnalysisRun(_ run: AnalysisRun) {
        guard let database else { return }
        Task {
            do {
                try await database.deleteAnalysisRun(id: run.id)
                await refreshAllNow()
            } catch {
                presentError("Could not delete the analyze batch", error)
            }
        }
    }

    // MARK: - People-only pass


    func videoPeople(for videoID: Int64) async -> [VideoPersonRecord] {
        guard let database else { return [] }
        return (try? await database.fetchVideoPeople(videoID: videoID)) ?? []
    }

    /// Every video in the library this person is known from: the people
    /// pass's roster plus any scene tagged with them, in library order.
    func personVideos(_ person: PersonRecord) async -> [VideoRecord] {
        var ids = Set(scenes.filter { !$0.ignored && $0.tags.contains(person.tag) }.map(\.videoID))
        if let database, let roster = try? await database.fetchVideoIDs(personID: person.id) {
            ids.formUnion(roster)
        }
        return videos.filter { ids.contains($0.id) }
    }

    /// The on-screen ranges the people pass recorded for this person in a
    /// video (empty when the pass only noted presence, or never ran).
    func personRanges(videoID: Int64, key: String) async -> [ScriptTimeRange] {
        guard let database,
              let ranges = try? await database.fetchVideoPeopleRanges(videoID: videoID)
        else { return [] }
        return ranges.first { $0.key == key }?.ranges ?? []
    }

    /// Seconds this person is on record as speaking in a video, from the
    /// podcast pass's speaker turns.
    func personSpeakingSeconds(videoID: Int64, key: String) async -> Double {
        guard let database, let turns = try? await database.fetchSpeakerTurns(videoID: videoID)
        else { return 0 }
        return turns.filter { $0.personKey == key }.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }


    /// Detect people in several videos one after another, in the background:
    /// the caller (the analysis sheet) closes and the user keeps working while
    /// the status bar and the analysis log follow the run.
    /// Lay a whole file out in the Builder by a crop recipe at the playhead,
    /// from the file's speaker turns, tiles and roster.
    func composeVideo(_ video: VideoRecord, recipe kind: CropRecipe.Kind, highlightTalker: Bool) {
        compose(.video(video), video: video, recipe: kind, highlightTalker: highlightTalker)
    }

    /// Lay one scene out by a crop recipe: the same, over the scene's range.
    func composeScene(_ scene: SceneRecord, recipe kind: CropRecipe.Kind, highlightTalker: Bool) {
        guard let video = videos.first(where: { $0.id == scene.videoID }) else {
            presentError("The scene's file is not in this project.")
            return
        }
        compose(.scene(scene), video: video, recipe: kind, highlightTalker: highlightTalker)
    }

    private func compose(_ source: BuilderTimelineModel.ComposeSource, video: VideoRecord,
                         recipe kind: CropRecipe.Kind, highlightTalker: Bool) {
        guard let database else { return }
        let name: String
        var range: ClosedRange<Double>?
        switch source {
        case .video: name = video.filename
        case .scene(let scene): name = "\(video.filename) \(scene.startTime.timecode)–\(scene.endTime.timecode)"; range = scene.startTime...scene.endTime
        }
        Task {
            do {
                let turns = try await database.fetchSpeakerTurns(videoID: video.id)
                let roster = try await database.fetchVideoPeople(videoID: video.id)
                let recipe = CropRecipe(kind: kind, highlightTalker: highlightTalker)
                let plan = try CropRecipePlanner.plan(recipe, video: video, range: range, turns: turns, roster: roster,
                                                      layouts: ScreenCropStore.all(),
                                                      canvasAspect: builder.document.renderSettings.aspectRatio)
                let result = builder.compose(plan, source: source, at: builder.playhead, highlightTalker: highlightTalker)
                appendLog(\.analysisLog, ["Composed \(name) as \(kind.name): \(result.clips.count) clip(s)"]
                    + plan.notes.map { "  " + $0 })
                if result.clips.isEmpty { presentError("The recipe placed nothing; the timeline has no room at the playhead.") }
            } catch {
                presentError("Compose \(name) as \(kind.name)", error)
            }
        }
    }

    /// One part of a video's analysis that can run again on its own, for
    /// instance with another model, without redoing the rest.
    enum AnalysisStage: String, CaseIterable, Sendable {
        /// Tagging for footage; the transcript-first pass for podcasts.
        case analysis
        /// The podcast pass: exchanges from the transcript (podcasts only).
        case exchanges
        case people
        /// The transcript itself (on-device; no model to pick).
        case transcript

        var title: String {
            switch self {
            case .analysis: "Video analysis"
            case .exchanges: "Podcast exchanges"
            case .people: "People detection"
            case .transcript: "Transcript"
            }
        }

        /// The routing task whose model the stage uses; nil when nothing is picked.
        var task: String? {
            switch self {
            case .analysis: "analysis"
            case .exchanges: "exchanges"
            case .people: "people"
            case .transcript: nil
            }
        }

        /// The stage behind a role name in the AI details sheet.
        static func forRole(_ role: String, podcast: Bool) -> AnalysisStage? {
            switch role {
            case "Tagging", "Video analysis": podcast ? .exchanges : .analysis
            case "Transcript", "Transcription": podcast ? .exchanges : .transcript
            case "Podcast exchanges": .exchanges
            case "People", "People detection": .people
            default: nil
            }
        }
    }

    /// Run one stage of a video's analysis again with the given model. The
    /// tagging and podcast stages land in a new analyze batch like a full
    /// run; people detection and transcription update the video in place.
    func rerun(_ stage: AnalysisStage, video: VideoRecord, provider: String? = nil, model: String? = nil) {
        switch stage {
        case .people:
            detectPeople(in: [video], provider: provider, model: model)
        case .transcript:
            transcribe(video: video, force: true)
        case .analysis, .exchanges:
            guard let database, !isAnalyzing else { return }
            let podcast = video.type == .podcast || stage == .exchanges
            isAnalyzing = true
            analysisCompletion = nil
            analyzingVideoIDs = [video.id]
            analysisProjectName = activeProject?.name
            analysisLog = []
            analysisProgress = 0
            analysisStage = podcast ? "grouping exchanges" : "tagging"
            let profile = activeProfile
            let analyzer = analyzer
            let transcription = transcription
            let podcastAnalysis = podcastAnalysis
            let settings = settings
            let localPodcast = OnDevicePolicy.isEnabled(item: "podcast-exchanges", config: settings.ai)
            appendLog(\.analysisLog, ["\(video.filename): running \(stage.title) again"
                + (model.map { " with \($0)" } ?? "")])
            analysisTask = Task {
                await AIRunCapture.context.withValue(AIRunCapture()) {
                    defer {
                        isAnalyzing = false
                        refreshAll()
                    }
                    do {
                        let existingBatches = ((try? await database.fetchAnalysisRuns()) ?? []).count { $0.videoID == video.id }
                        let runName = Self.analysisRunName(for: video, existingBatchCount: existingBatches)
                        let progress: @Sendable (Double, String) -> Void = { fraction, stage in
                            Task { @MainActor in
                                self.analysisProgress = fraction
                                self.analysisStage = stage
                            }
                        }
                        let runID: Int64?
                        if podcast {
                            let result = try await podcastAnalysis.analyze(
                                video: video, profile: profile, database: database,
                                runName: runName, provider: provider, model: model,
                                languageCode: "", analyzer: analyzer, transcription: transcription,
                                highlightThreshold: settings.podcast.highlightThreshold,
                                holdSeconds: settings.podcast.speakerHoldSeconds,
                                log: logSink(\.analysisLog), progress: progress, useLocal: localPodcast,
                                capturedSettings: settings.podcast)
                            runID = result.runID
                        } else {
                            let knownPeople = (try? await database.fetchPeople()) ?? []
                            let markers = (try? await database.personMarkers(videoID: video.id)) ?? []
                            let notes = (try? await database.videoNotes(videoID: video.id)) ?? []
                            let result = try await analyzer.analyzeVisual(
                                video: video, profile: profile, database: database,
                                runName: runName, provider: provider, model: model,
                                notes: notes, knownPeople: knownPeople, personMarkers: markers,
                                // People have their own stage; this one only tags.
                                detectPeople: false, smartSampling: true, force: true,
                                log: logSink(\.analysisLog), progress: progress)
                            runID = result.runID
                        }
                        if let runID {
                            try await database.saveAnalysisSettings(id: runID, settings: AnalysisRunSettings(
                                includeTranscript: podcast, detectPeople: false, smartSampling: true,
                                provider: provider, model: model, videoPath: video.path, sourceProfile: profile.profileName))
                            try await database.updateAnalysisModels(id: runID)
                        }
                        appendLog(\.analysisLog, ["\(video.filename): \(stage.title) done"])
                    } catch is CancellationError {
                        appendLog(\.analysisLog, ["\(video.filename): \(stage.title) cancelled"])
                    } catch {
                        appendLog(\.analysisLog, ["\(video.filename): \(stage.title) failed — \(error.userMessage)"])
                        presentError("\(stage.title) for \(video.filename)", error)
                    }
                }
            }
        }
    }

    func detectPeople(in videos: [VideoRecord], provider: String? = nil, model: String? = nil) {
        guard !videos.isEmpty, !isDetectingPeople else { return }
        isDetectingPeople = true
        Task {
            defer { isDetectingPeople = false; peopleDetectionStage = nil }
            for (index, video) in videos.enumerated() {
                peopleDetectionStage = videos.count > 1 ? "Detecting people \(index + 1) of \(videos.count)" : nil
                _ = await runPeopleDetection(video, provider: provider, model: model, refreshLibrary: true)
            }
            appendLog(\.analysisLog, ["People detection finished for \(videos.count) video(s)"])
        }
    }

    func detectPeopleInVideo(_ video: VideoRecord,
                             provider: String? = nil,
                             model: String? = nil,
                             refreshLibrary: Bool = true) async -> [VideoPersonRecord] {
        guard !isDetectingPeople else { return [] }
        isDetectingPeople = true
        defer { isDetectingPeople = false }
        return await runPeopleDetection(video, provider: provider, model: model, refreshLibrary: refreshLibrary)
    }

    private func runPeopleDetection(_ video: VideoRecord, provider: String?, model: String?,
                                    refreshLibrary: Bool) async -> [VideoPersonRecord] {
        guard let database else { return [] }
        detectingPeopleVideoID = video.id
        defer { detectingPeopleVideoID = nil }
        do {
            let (roster, suggestedFilename) = try await analyzer.detectPeopleOnly(
                video: video, profile: activeProfile, database: database,
                provider: provider, model: model, log: logSink(\.analysisLog))
            // A filename fix the pass noticed (auto-generated or misspelled
            // name) goes through the same review sheet as end-of-analysis
            // proposals — it presents once no other sheet is in the way.
            if let suggestedFilename {
                pendingRenameReview = RenameReviewRequest(suggestions: [
                    RenameSuggestion(videoID: video.id,
                                     currentFilename: video.filename,
                                     suggestedName: suggestedFilename),
                ])
            }
            videoPeopleCounts[video.id] = Set(roster.map(\.key)).count
            if refreshLibrary { refreshAll() }
            return roster
        } catch {
            presentError("People detection failed", error)
            return (try? await database.fetchVideoPeople(videoID: video.id)) ?? []
        }
    }

    // MARK: - Framing pass


    /// Run (or re-run) the local framing pass for one video: a 9:16 rect
    /// (static) or camera path per scene, plus optional framed: people tags.
    func detectFraming(video: VideoRecord, camera: String, tagFramedPeople: Bool,
                       refreshLibrary: Bool = true) async {
        guard let database, !isDetectingFraming else { return }
        isDetectingFraming = true
        framingProgress = 0
        defer { isDetectingFraming = false }
        do {
            _ = try await FramingService.detectFraming(
                video: video, database: database, camera: camera,
                tagFramedPeople: tagFramedPeople,
                log: logSink(\.analysisLog),
                progress: { fraction in
                    Task { @MainActor in self.framingProgress = fraction }
                })
            if refreshLibrary { refreshAll() }
        } catch {
            presentError("Framing detection failed", error)
        }
    }

    // MARK: - Center Stage hints

    func centerStageHints(for videoID: Int64) async -> [CameraHint] {
        guard let database else { return [] }
        return (try? await database.centerStageHints(videoID: videoID)) ?? []
    }

    /// Save a user-framed camera hint and immediately recompute the stored
    /// paths of the scenes covering its moment. Returns the fresh hint list.
    func addCameraHint(videoID: Int64, at time: Double, rect: CGRect) async -> [CameraHint] {
        guard let database else { return [] }
        try? await database.addCenterStageHint(videoID: videoID, at: time,
                                               x: rect.minX, y: rect.minY,
                                               width: rect.width, height: rect.height)
        recomputeCenterStagePaths(videoID: videoID, around: time)
        return (try? await database.centerStageHints(videoID: videoID)) ?? []
    }

    func updateCameraHint(_ hint: CameraHint) async -> [CameraHint] {
        guard let database else { return [] }
        try? await database.updateCenterStageHint(hint)
        recomputeCenterStagePaths(videoID: hint.videoID, around: hint.atTime)
        return (try? await database.centerStageHints(videoID: hint.videoID)) ?? []
    }

    func deleteCameraHint(_ hint: CameraHint) async -> [CameraHint] {
        guard let database else { return [] }
        try? await database.deleteCenterStageHint(id: hint.id)
        recomputeCenterStagePaths(videoID: hint.videoID, around: hint.atTime)
        return (try? await database.centerStageHints(videoID: hint.videoID)) ?? []
    }

    /// Re-run the tracking pass for the stored camera paths of scenes
    /// covering `time` (nil = every scene of the video), so previews reflect
    /// an edited hint or ignore marker without a full re-analysis. Local
    /// only; runs in the background.
    private func recomputeCenterStagePaths(videoID: Int64, around time: Double?) {
        guard let database else { return }
        let affected = scenes.filter { scene in
            guard scene.videoID == videoID, scene.centerStagePathJSON != nil else { return false }
            guard let time else { return true }
            return scene.startTime - 0.25 <= time && time <= scene.endTime + 0.25
        }
        guard !affected.isEmpty,
              let video = videos.first(where: { $0.id == videoID }) else { return }
        let canvasAspect = activeProfile.defaultRenderSettings.aspectRatio
        Task {
            let centerStage = CenterStageService()
            let markers = (try? await database.personMarkers(videoID: videoID)) ?? []
            let named = markers.filter { $0.personID != nil && !$0.ignored }
            let ignored = markers.filter(\.ignored)
            let portraits = named.isEmpty ? []
                : await Analyzer.markerPortraits(url: video.url, markers: named,
                                                 duration: video.duration)
            let avoidPortraits = ignored.isEmpty ? []
                : await Analyzer.markerPortraits(url: video.url, markers: ignored,
                                                 duration: video.duration)
            let hints = (try? await database.centerStageHints(videoID: videoID)) ?? []
            // The framing moved, so who's inside it may have too — refresh
            // the framed: tags along with the paths (when the option is on).
            let tagFramed = (UserDefaults.standard.object(forKey: "analysis.framingTagPeople") as? Bool) ?? true
            let peopleReferences = tagFramed
                ? await FramingService.personSignatures(video: video, database: database) : []
            for scene in affected {
                guard let stored = scene.centerStagePath else { continue }
                // Static framings re-derive their rect (the edited hint wins
                // verbatim) — the tracker would turn them into moving paths.
                let path: SceneCameraPath?
                let framingStarted = ContinuousClock.now
                if stored.camera == FramingService.staticCamera {
                    path = await FramingService.staticScenePath(video: video, scene: scene,
                                                                hints: hints)
                } else {
                    let sceneHints = hints
                        .filter { $0.atTime >= scene.startTime - 0.25 && $0.atTime <= scene.endTime + 0.25 }
                        .map { hint in
                            (time: min(max(0, hint.atTime - scene.startTime), scene.duration),
                             crop: CGRect(x: hint.x, y: hint.y, width: hint.width, height: hint.height))
                        }
                    if let result = try? await centerStage.cameraPath(
                            source: video.url, start: scene.startTime, duration: scene.duration,
                            focusPortraits: portraits, avoidPortraits: avoidPortraits,
                            hints: sceneHints,
                            tuning: .named(stored.camera),
                            aspect: canvasAspect),
                       result.keyframes.count >= 2 {
                        path = SceneCameraPath(camera: stored.camera, keyframes: result.keyframes)
                    } else {
                        path = nil
                    }
                }
                guard let path,
                      let data = try? JSONEncoder().encode(path),
                      let json = String(data: data, encoding: .utf8) else { continue }
                try? await database.setSceneCenterStagePath(
                    scene.id, json: json, seconds: (ContinuousClock.now - framingStarted).seconds)
                if tagFramed {
                    await FramingService.retagFramedPeople(video: video, scene: scene,
                                                           path: path, database: database,
                                                           people: peopleReferences)
                }
            }
            refreshAll()
        }
    }

    /// A marker's ignore flag changed — its effect spans the whole video,
    /// so every stored path of that video gets refreshed in the background.
    func markerIgnoreChanged(videoID: Int64) {
        recomputeCenterStagePaths(videoID: videoID, around: nil)
    }
}
