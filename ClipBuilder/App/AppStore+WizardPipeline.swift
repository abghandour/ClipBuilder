import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - Wizard Pipeline

    // The run's plan + per-unit done marks ("people:12", "analysis:12",
    // "naming", …) so Resume re-enters exactly where the run stopped instead
    // of redoing (and re-billing) finished steps.

    /// A stopped run with remaining work — the bottom bar offers Resume.
    var canResumePipeline: Bool {
        !isPipelineRunning && pipelineStage == "stopped" && pipelineOptions != nil
    }

    /// One Wizard Pipeline run: every checked step for the selected videos,
    /// sequentially, while the app stays usable. People, transcription, and
    /// the analysis batch run as phases; research, curation, framing,
    /// generation, and covers follow per video; renames apply automatically
    /// at the end. Review prompts (new people) are deferred to the end — the
    /// run never stops to ask.
    func startPipeline(videos targets: [VideoRecord], options: PipelineOptions) {
        guard !isPipelineRunning, !targets.isEmpty else { return }
        guard !isAnalyzing, !isWizardRunning else {
            presentError("Another analysis or generation is already running — stop it or let it finish first.")
            return
        }
        pipelineTargets = targets
        pipelineProjectID = activeProjectID
        pipelineProjectName = activeProject?.name
        pipelineOptions = options
        pipelineDone = []
        pipelineRunIDs = [:]
        pipelineGenerated = []
        pipelineDeferredPeople = nil
        pipelineLog = []
        appendLog(\.pipelineLog, ["Wizard Pipeline: \(targets.count) video(s)"])
        runPipeline()
    }

    /// Pick a stopped run back up — finished steps are skipped via their
    /// done marks.
    func resumePipeline() {
        guard canResumePipeline else { return }
        guard !isAnalyzing, !isWizardRunning else {
            presentError("Another analysis or generation is already running — stop it or let it finish first.")
            return
        }
        appendLog(\.pipelineLog, ["Resuming…"])
        runPipeline()
    }

    private func runPipeline() {
        guard let database, let options = pipelineOptions else { return }
        let targets = pipelineTargets
        isPipelineRunning = true
        pipelineStage = "starting"

        // One progress unit per (step, video); naming runs once for all.
        var totalUnits = 0
        if options.detectPeople { totalUnits += targets.count }
        if options.transcribe { totalUnits += targets.count }
        if options.analyze || options.fightScoring { totalUnits += targets.count }
        if options.fightResearch { totalUnits += targets.count }
        if options.curate { totalUnits += targets.count }
        if options.framing { totalUnits += targets.count }
        if options.generate { totalUnits += targets.count }
        if options.generate && options.coverFrame { totalUnits += targets.count }
        if options.proposeNames { totalUnits += 1 }
        let total = Double(max(1, totalUnits))

        pipelineTask = Task {
            // Settings saves enqueue an actor update; Start and Resume must
            // apply the latest routing before any phase can dispatch AI.
            await ai.updateConfig(effectiveAIConfig)
            // The operation closure is nonisolated by type; pin it to the main
            // actor so the nested helpers that touch pipeline state are too.
            await SampledFrameCache.$current.withValue(SampledFrameCache()) { @MainActor in
            var unitsDone = Double(pipelineDone.count)
            pipelineProgress = min(1, unitsDone / total)
            // Mark a unit finished; done units are skipped on Resume.
            // Local functions do not inherit the closure's actor, hence the
            // explicit isolation on each helper.
            @MainActor func finish(_ key: String) {
                pipelineDone.insert(key)
                unitsDone += 1
                pipelineProgress = min(1, unitsDone / total)
            }
            @MainActor func completed(_ key: String) -> Bool { pipelineDone.contains(key) }
            @MainActor func log(_ message: String) { appendLog(\.pipelineLog, [message]) }
            // Sendable relay for service `log:` closures.
            let relay: @Sendable (String) -> Void = logSink(\.pipelineLog)
            // The run never prompts: rename proposals from inner passes are
            // superseded by the pipeline's own rename step, and new-people
            // reviews queue for the end.
            @MainActor func swallowPrompts() {
                if options.proposeNames { pendingRenameReview = nil }
                if let people = pendingPeopleReview {
                    pipelineDeferredPeople = people
                    pendingPeopleReview = nil
                }
            }

            // 1. People roster + portraits per video.
            if options.detectPeople {
                for video in targets where !completed("people:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "people — \(video.filename)"
                    log("Detecting people in \(video.filename)…")
                    _ = await detectPeopleInVideo(video, refreshLibrary: false)
                    swallowPrompts()
                    finish("people:\(video.id)")
                }
                await refreshAllNow()
            }

            // 2. Transcription (skips videos that already have one).
            if options.transcribe {
                let transcription = transcription
                let language = editingDefaults.footage.language
                for video in targets where !completed("transcribe:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "transcribing — \(video.filename)"
                    let existing = (try? await database.fetchTranscripts(videoID: video.id)) ?? []
                    if existing.isEmpty {
                        log("Transcribing \(video.filename)…")
                        do {
                            _ = try await transcription.transcribeForVideo(video: video, database: database,
                                                                   languageCode: language, log: relay)
                        } catch {
                            log("\(video.filename): transcription failed — \(error.userMessage)")
                        }
                    } else {
                        log("\(video.filename): transcript already exists")
                    }
                    finish("transcribe:\(video.id)")
                }
            }

            // 3. The analysis batch — one analyze() call covers every video
            // still lacking one (fight scoring rides inside per the
            // checkbox); the fresh run ids scope the follow-up steps.
            if options.analyze, !Task.isCancelled {
                let pending = targets.filter { !completed("analysis:\($0.id)") }
                if !pending.isEmpty {
                    let runsBeforeAnalysis = (try? await database.fetchAnalysisRuns()) ?? []
                    let before = Dictionary(grouping: runsBeforeAnalysis, by: \.videoID)
                        .mapValues { Set($0.map(\.id)) }
                    pipelineStage = "analyzing \(pending.count) video(s)"
                    log("Analyzing \(pending.count) video(s) — full details in the Raw Videos activity log")
                    analyze(videos: pending, includeFightScoring: options.fightScoring,
                            originatingProjectName: pipelineProjectName)
                    await analysisTask?.value
                    await refreshAllNow()
                    swallowPrompts()
                    let storedRuns = (try? await database.fetchAnalysisRuns()) ?? []
                    for video in pending {
                        let prior = before[video.id] ?? []
                        if let fresh = storedRuns.first(where: {
                            $0.videoID == video.id && !prior.contains($0.id)
                        }) {
                            pipelineRunIDs[video.id] = fresh.id
                            log("\(video.filename): analyzed into “\(fresh.name)”")
                            finish("analysis:\(video.id)")
                        }
                        // No fresh run (cancelled mid-batch) — left unmarked
                        // so Resume analyzes it.
                    }
                }
            } else if options.fightScoring {
                for video in targets where !completed("analysis:\(video.id)") {
                    if Task.isCancelled { break }
                    let current = videos.first { $0.id == video.id } ?? video
                    if current.type?.supportsFightFeatures == false {
                        log("\(video.filename): not a fight — scoring skipped")
                    } else {
                        pipelineStage = "fight scoring — \(video.filename)"
                        let allScenes = (try? await database.fetchScenes(includeExcluded: true)) ?? []
                        do {
                            _ = try await analyzer.scoreFightAction(
                                video: current, scenes: allScenes.filter { $0.videoID == video.id },
                                profile: activeProfile, database: database,
                                provider: nil, model: nil, log: relay)
                        } catch {
                            log("\(video.filename): fight scoring failed — \(error.userMessage)")
                        }
                    }
                    finish("analysis:\(video.id)")
                }
            }

            // 4. Per-video follow-ups.
            for video in targets {
                if Task.isCancelled { break }
                // Analysis may have (re)classified the video — work from the
                // fresh record in the originating project, never whichever
                // project happens to be visible now.
                let projectVideos = (try? await database.fetchVideos(projectID: pipelineProjectID)) ?? []
                let current = projectVideos.first { $0.id == video.id } ?? video
                let runID = pipelineRunIDs[video.id]

                if options.fightResearch, !completed("research:\(video.id)") {
                    pipelineStage = "fight research — \(current.filename)"
                    if fightResearch[current.id] != nil {
                        log("\(current.filename): fight research already on record")
                    } else if current.type?.supportsFightFeatures == false {
                        log("\(current.filename): not a fight — research skipped")
                    } else {
                        let identity = await guessFightIdentity(video: current)
                        if identity.fighters.trimmingCharacters(in: .whitespaces).isEmpty {
                            log("\(current.filename): couldn't derive the fight identity — research skipped")
                        } else {
                            do {
                                _ = try await runFightResearch(video: current, identity: identity,
                                                               log: relay)
                                log("\(current.filename): fight research done (\(identity.fighters))")
                            } catch {
                                log("\(current.filename): fight research failed — \(error.userMessage)")
                            }
                        }
                    }
                    finish("research:\(video.id)")
                }

                if options.curate, !completed("curate:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "AI Favorites — \(current.filename)"
                    let projectScenes = (try? await database.fetchScenes(
                        videoID: current.id, projectID: pipelineProjectID
                    )) ?? []
                    let pool = projectScenes.filter { scene in
                        !scene.favorite && !scene.excluded
                            && (runID == nil || scene.runID == runID)
                    }
                    if pool.isEmpty {
                        log("\(current.filename): no new favorite candidates")
                    } else {
                        do {
                            let curation = try await proposeFavorites(for: pool, provider: nil,
                                                                     model: nil, log: relay)
                            try await database.setScenesFavorite(curation.value.map(\.sceneID), favorite: true,
                                                                 provenance: curation.provenance)
                            await refreshAllNow()
                            log("\(current.filename): favorited \(curation.value.count) of \(pool.count) scenes")
                        } catch {
                            log("\(current.filename): AI Favorites failed — \(error.userMessage)")
                        }
                    }
                    finish("curate:\(video.id)")
                }

                if options.framing, !completed("framing:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "framing — \(current.filename)"
                    let defaults = UserDefaults.standard
                    let camera = defaults.string(forKey: "analysis.framingCamera")
                        ?? FramingService.staticCamera
                    let tagPeople = defaults.object(forKey: "analysis.framingTagPeople") == nil
                        ? true : defaults.bool(forKey: "analysis.framingTagPeople")
                    log("Framing \(current.filename)…")
                    await detectFraming(video: current, camera: camera, tagFramedPeople: tagPeople,
                                        refreshLibrary: false)
                    await refreshAllNow()
                    finish("framing:\(video.id)")
                }

                if options.generate, !completed("generate:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "generating — \(current.filename)"
                    let storedRuns = (try? await database.fetchAnalysisRuns()) ?? []
                    let runIDs = runID.map { [$0] }
                        ?? Set(storedRuns.filter { $0.videoID == current.id }.map(\.id))
                    let transcriptsAvailable = storedRuns.contains {
                        runIDs.contains($0.id) && $0.hasTranscript
                    }
                    let storedScenes = (try? await database.fetchScenes(
                        videoID: current.id, projectID: pipelineProjectID
                    )) ?? []
                    var wizard = Self.wizardOptionsFromForm(transcriptsAvailable: transcriptsAvailable, log: log)
                    wizard.projectID = pipelineProjectID
                    wizard.accountBenchmarks = igBenchmarks
                    // The pipeline's selected videos own its source scope, even
                    // when presentation settings came from a pasted Wizard run.
                    wizard.sourcesRestricted = false
                    wizard.sourceSceneSelection = false
                    wizard.sourceSceneIDs = []
                    wizard.sourceVideoPaths = []
                    wizard.sourcePeople = []
                    wizard.selectedRunIDs = runIDs
                    // Favorite scope only when this video's batch actually has
                    // favorite scenes (holds across Resume, unlike a counter).
                    wizard.favoritesOnly = options.curate && storedScenes.contains { scene in
                        scene.videoID == current.id && scene.favorite
                            && (runID == nil || scene.runID == runID)
                    }
                    wizard.critiqueLoop = options.critique
                    wizard.workflow = .automatic
                    if wizard.selectedRunIDs.isEmpty {
                        log("\(current.filename): no analyze batch to generate from — skipped")
                    } else {
                        log("Generating a reel from \(current.filename)…")
                        let before = Set(((try? await database.fetchGeneratedVideos(
                            projectID: pipelineProjectID
                        )) ?? []).map(\.id))
                        runWizard(options: wizard)
                        await wizardTask?.value
                        await refreshAllNow()
                        let fresh = ((try? await database.fetchGeneratedVideos(
                            projectID: pipelineProjectID
                        )) ?? []).filter { !before.contains($0.id) }
                            .sorted { $0.id < $1.id }
                        // One combined results sheet at the end beats a
                        // pop-up per video mid-run.
                        wizardResults = nil
                        if fresh.isEmpty {
                            log("\(current.filename): generation produced nothing"
                                + (wizardFailureMessage.map { " — \($0)" } ?? ""))
                        } else {
                            pipelineGenerated += fresh
                            log("\(current.filename): \(fresh.count) reel(s) rendered")
                        }
                    }
                    finish("generate:\(video.id)")
                }

                if options.generate && options.coverFrame, !completed("cover:\(video.id)") {
                    if Task.isCancelled { break }
                    pipelineStage = "cover frames — \(current.filename)"
                    // Per-video reel tracking doesn't survive Resume, so this
                    // covers any of the run's reels still lacking a cover.
                    let projectOutputs = (try? await database.fetchGeneratedVideos(
                        projectID: pipelineProjectID
                    )) ?? []
                    for reelID in pipelineGenerated.map(\.id) where !Task.isCancelled {
                        guard let reel = projectOutputs.first(where: { $0.id == reelID }),
                              reel.coverTime == nil else { continue }
                        if let picks = try? await proposeCoverFrames(for: reel, provider: nil,
                                                                     model: nil, log: { _ in }),
                           let top = picks.value.first {
                            setCoverFrame(reel, time: top.time, provenance: picks.provenance)
                            log("\(reel.filename): cover set at \(top.time.timecode)")
                        }
                    }
                    finish("cover:\(video.id)")
                }
            }

            // 5. File renames — applied automatically in pipeline mode
            // ("fire and forget"); derived analyze-batch labels follow via
            // renameVideo.
            if options.proposeNames, !completed("naming"), !Task.isCancelled {
                pipelineStage = "renaming files"
                pendingRenameReview = nil
                let projectVideos = (try? await database.fetchVideos(projectID: pipelineProjectID)) ?? []
                let current = targets.map { target in
                    projectVideos.first { $0.id == target.id } ?? target
                }
                do {
                    let suggestions = try await suggestFileNames(for: current, provider: nil,
                                                                 model: nil, log: relay)
                    if suggestions.isEmpty {
                        log("No file renames needed")
                    } else {
                        for suggestion in suggestions {
                            guard let video = projectVideos.first(where: { $0.id == suggestion.videoID })
                            else { continue }
                            log("Renamed \(suggestion.currentFilename) → \(suggestion.suggestedName)")
                            renameVideo(video, to: suggestion.suggestedName,
                                        provenance: suggestion.provenance)
                        }
                        await refreshAllNow()
                    }
                } catch {
                    log("File naming failed — \(error.userMessage)")
                }
                finish("naming")
            }

            await refreshAllNow()
            swallowPrompts()
            if Task.isCancelled {
                pipelineStage = "stopped"
                log("Wizard Pipeline stopped — Resume in the bottom bar picks up where it left off.")
            } else {
                if !pipelineGenerated.isEmpty {
                    wizardResults = WizardRunResults(videos: pipelineGenerated)
                }
                // Deferred mid-run prompts present now that the run is over.
                if let people = pipelineDeferredPeople {
                    pendingPeopleReview = people
                    pipelineDeferredPeople = nil
                }
                pipelineProgress = 1
                pipelineStage = "done"
                log("Wizard Pipeline finished — \(pipelineGenerated.count) reel(s) ready.")
                pipelineOptions = nil
            }
            isPipelineRunning = false
            }
        }
    }

    /// Read the saved planning and presentation subsets used by the Wizard
    /// and the pipeline sheet. The running pipeline supplies its own per-video
    /// source scope, Automatic workflow, and critique choice.
    static func wizardOptionsFromForm(transcriptsAvailable: Bool, defaults: UserDefaults = .standard,
                                      log: (String) -> Void = { _ in }) -> WizardOptions {
        WizardDefaults.migrateLegacy(defaults: defaults)
        let copied = AISettingsJSON.decode(WizardOptions.self, defaults.string(forKey: AISettingsPreferences.snapshotKey))
        let base = copied ?? WizardOptions()
        var step1 = base.step1
        var step2 = base.step2
        let audio = WizardDefaults.audioMode(defaults: defaults)
        step2.useMusic = audio.useMusic && !WizardEngine.availableMusic().isEmpty
        step2.muteSource = audio.muteSource && step2.useMusic == true
        step2.musicFolder = step2.useMusic == true ? WizardDefaults.musicFolder(defaults: defaults) : nil
        step1.formatPreset = defaults.string(forKey: "wizard.formatPreset") ?? "custom"
        let recipe = ReelRecipe.recipe(id: step1.formatPreset ?? "custom") ?? .custom
        if recipe.capabilities.sources != .scenes {
            step1.formatPreset = ReelRecipe.custom.id
            log("Pipeline: using Custom because \(recipe.title) requires a recording; automated reels use each video's analyzed scenes.")
        }
        let text = WizardDefaults.textMode(defaults: defaults)
            .output(transcriptsAvailable: transcriptsAvailable, recipe: step1.formatPreset ?? "custom")
        step2.addCaptions = text.captions
        step2.enableTextOverlays = text.headlines
        step2.highlightFraming = defaults.string(forKey: "wizard.highlightFraming").flatMap(CropRecipe.Kind.init(rawValue:))
        step2.podcastFraming = PodcastFramingMode(rawValue: defaults.string(forKey: "wizard.podcastFraming") ?? "") ?? .followSpeaker
        step2.framingCamera = defaults.string(forKey: "wizard.framingCamera") ?? WizardDefaults.fallbackFramingCamera
        let layoutMode = WizardLayoutMode(rawValue: defaults.string(forKey: WizardDefaults.layoutModeKey) ?? "")
            ?? .automatic
        step1.screenCropLayouts = WizardDefaults.screenCropLayouts(for: layoutMode, defaults: defaults)
        step2.allowedTransitions = WizardDefaults.allowedTransitions(defaults: defaults)
        // Saved research is useful context when it exists; a run should not
        // ask the user to decide whether a missing record is useful.
        step1.useFightResearch = true
        step1.aiInstructions = defaults.string(forKey: "wizard.aiInstructions") ?? ""
        let durationMode = WizardDefaults.durationMode(defaults: defaults)
        let customDuration = defaults.object(forKey: WizardDefaults.customDurationKey) == nil
            ? 20 : defaults.integer(forKey: WizardDefaults.customDurationKey)
        step1.targetDurationSeconds = durationMode.duration
            ?? (durationMode == .custom ? min(180, max(3, customDuration)) : nil)
        let taste = defaults.string(forKey: "wizard.tastePreset") ?? ""
        step1.tastePreset = taste.isEmpty ? nil : taste
        let branding = WizardDefaults.brandingOverride(defaults: defaults).resolved(defaults: defaults)
        step2.includeWatermark = copied?.includeWatermark ?? branding.includeWatermark
        step2.includeHeadline = copied?.includeHeadline ?? branding.includeHeadline
        step2.includeOutro = copied?.includeOutro ?? branding.includeOutro
        step1.workflow = WizardWorkflow(rawValue: defaults.string(forKey: WizardDefaults.workflowKey) ?? "") ?? .automatic
        step1.modelOverride = defaults.string(forKey: "wizard.modelOverride").flatMap { $0.isEmpty ? nil : $0 }
        step1.critiqueLoop = defaults.string(forKey: "wizard.outcome") == ReelRecipe.Workflow.iterate.rawValue
        step1.critiqueTargetScore = defaults.object(forKey: "wizard.critiqueTargetScore") == nil ? 85 : defaults.integer(forKey: "wizard.critiqueTargetScore")
        step1.critiqueMaxVersions = defaults.object(forKey: "wizard.critiqueMaxVersions") == nil ? 3 : defaults.integer(forKey: "wizard.critiqueMaxVersions")
        step2.musicTrack = defaults.string(forKey: "wizard.musicTrack").flatMap { $0.isEmpty ? nil : $0 }
        step2.overlayStyle = defaults.string(forKey: "wizard.overlayStyle").flatMap { $0.isEmpty ? nil : $0 }
        step2.pinnedOverlayTemplate = defaults.string(forKey: "wizard.pinnedOverlayTemplate").flatMap { $0.isEmpty ? nil : $0 }
        step2.overlayAnimation = defaults.string(forKey: "wizard.overlayAnimation").flatMap { $0.isEmpty ? nil : $0 }
        step2.overlayPlacement = defaults.string(forKey: "wizard.overlayPlacement").flatMap { $0.isEmpty ? nil : $0 }
        step2.captionLanguage = defaults.string(forKey: "wizard.captionLanguage").flatMap { $0.isEmpty ? nil : $0 }
        step2.useBRoll = defaults.object(forKey: "wizard.useBRoll") == nil || defaults.bool(forKey: "wizard.useBRoll")
        step2.brollInstructions = defaults.string(forKey: "wizard.brollInstructions") ?? ""
        var options = WizardOptions.merge(step1: step1, step2: step2, base: base)
        options.readBumperDefaults(defaults)
        return options
    }

    /// Stop the run: the pipeline task plus whichever inner engine (analysis
    /// or wizard) is mid-flight right now.
    func cancelPipeline() {
        appendLog(\.pipelineLog, ["Stopping…"])
        pipelineTask?.cancel()
        cancelAnalysis()
        cancelWizard()
    }

    /// Clear the finished run's bottom bar (the log and any resumable state
    /// go with it).
    func dismissPipelineBar() {
        guard !isPipelineRunning else { return }
        pipelineStage = ""
        pipelineProgress = 0
        pipelineLog = []
        pipelineOptions = nil
        pipelineTargets = []
        pipelineDone = []
        pipelineRunIDs = [:]
        pipelineGenerated = []
    }
}
