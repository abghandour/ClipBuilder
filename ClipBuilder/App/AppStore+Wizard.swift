import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppStore {
    // MARK: - Generated videos

    func setGeneratedVideoFavorite(_ video: GeneratedVideoRecord, favorite: Bool) {
        guard let database else { return }
        let generation = profileGeneration
        Task {
            do {
                try await database.setGeneratedVideoFavorite(video.id, favorite: favorite)
                guard generation == profileGeneration,
                      let index = generatedVideos.firstIndex(where: { $0.id == video.id }) else { return }
                generatedVideos[index].favorite = favorite
            } catch {
                guard generation == profileGeneration else { return }
                presentError("Could not save the favorite", error)
            }
        }
    }

    func deleteGeneratedVideo(_ video: GeneratedVideoRecord, removeFile: Bool) {
        guard let database else { return }
        Task {
            do {
                try await database.deleteGeneratedVideo(id: video.id)
            } catch {
                presentError("Could not delete the video", error)
                return
            }
            if removeFile {
                try? FileManager.default.removeItem(at: video.url)
            }
            generatedVideos.removeAll { $0.id == video.id }
            feedback.removeAll { $0.generatedVideoID == video.id }
        }
    }

    func addFeedback(for video: GeneratedVideoRecord, text: String) {
        guard let database else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await database.addFeedback(generatedVideoID: video.id, text: trimmed)
                feedback = try await database.fetchAllFeedback()
            } catch {
                presentError("Could not save the feedback", error)
            }
        }
    }

    // MARK: - Reviews + lessons

    func loadReview(for video: GeneratedVideoRecord) async -> (review: GenerationReview, clips: [ClipReview])? {
        guard let database else { return nil }
        return try? await database.fetchReview(generatedVideoID: video.id)
    }

    func saveReview(_ review: GenerationReview, clips: [ClipReview]) {
        guard let database else { return }
        Task {
            do {
                try await database.saveReview(review, clips: clips)
            } catch {
                presentError("Could not save the review", error)
            }
        }
    }

    /// Record the A/B pick for the presented batch (winner vs. every other
    /// variation), then surface the next queued batch if any.
    func resolveComparison(_ batch: ComparisonBatch, winner: GeneratedVideoRecord?) {
        if let database, let winner {
            let losers = batch.videos.filter { $0.id != winner.id }
            Task {
                for loser in losers {
                    do {
                        try await database.addPreference(chosenID: winner.id, rejectedID: loser.id,
                                                         chosenRationale: winner.rationale ?? "",
                                                         rejectedRationale: loser.rationale ?? "")
                    } catch {
                        presentError("Could not save the preference", error)
                    }
                }
            }
        }
        comparisonQueue.removeAll { $0.id == batch.id }
        pendingComparison = comparisonQueue.first
    }

    func distillLessons() {
        guard let database, !isDistillingLessons else { return }
        isDistillingLessons = true
        let wizard = wizard
        let generation = profileGeneration
        Task {
            do {
                let count = try await wizard.distillLessons(database: database, emit: logSink(\.wizardLog))
                await refreshLessons(from: database, generation: generation)
                appendLog(\.wizardLog, ["Distilled \(count) lesson(s) from your reviews"])
            } catch {
                presentError("Lesson distillation failed", error)
            }
            isDistillingLessons = false
        }
    }

    /// Distill the profile's house style from every analyzed Instagram reel
    /// (weighted by performance) and save it — the wizard injects it into
    /// every plan.
    func distillHouseStyle() {
        guard let database, !isDistillingHouseStyle else { return }
        isDistillingHouseStyle = true
        let wizard = wizard
        let existing = activeProfile.houseStyle
        Task {
            do {
                let style = try await wizard.distillHouseStyle(database: database,
                                                               existing: existing, emit: logSink(\.wizardLog))
                activeProfile.houseStyle = style.value
                activeProfile.houseStyleProvenance = style.provenance
                saveActiveProfile()
                appendLog(\.wizardLog, ["House style updated from the analyzed reels"])
            } catch {
                presentError("House style distillation failed", error)
            }
            isDistillingHouseStyle = false
        }
    }

    // MARK: - Wizard Brain export/import

    /// Write the portable Wizard Brain (lessons + taste + house style, with
    /// exemplar frames inlined) to a JSON file the user can back up in git
    /// or hand to another user.
    func exportWizardBrain(to url: URL) {
        guard let database else { return }
        let profile = activeProfile
        let generation = profileGeneration
        Task {
            do {
                let lessons = try await database.fetchLessons()
                try await AppJobWork.run {
                    let brain = WizardBrain.assemble(profile: profile, lessons: lessons)
                    try brain.write(to: url)
                }
                guard generation == profileGeneration else { return }
                wizardBrainStatus = "Exported \(lessons.count) lesson(s), \(profile.tasteCategories.count) video type(s), taste rubric, and house style to \(url.lastPathComponent)"
            } catch {
                presentError("Wizard Brain export failed", error)
            }
        }
    }

    /// Merge a Wizard Brain file into this profile: new lessons are added
    /// (duplicates by text are skipped, pinned stays pinned), new video-type
    /// categories are added with their exemplar frames restored to disk, and
    /// the taste rubric / house style fill in only when empty locally —
    /// nothing the user already has is overwritten.
    func importWizardBrain(from url: URL) {
        guard let database else { return }
        let generation = profileGeneration
        let profileName = activeProfile.profileName
        Task {
            do {
                let brain = try await AppJobWork.run { try WizardBrain.read(from: url) }
                guard generation == profileGeneration else { return }
                var notes: [String] = []

                let existingTexts = Set((try await database.fetchLessons()).map {
                    $0.text.lowercased()
                })
                var addedLessons = 0
                var skippedLessons = 0
                for lesson in brain.lessons {
                    let text = lesson.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if existingTexts.contains(text.lowercased()) {
                        skippedLessons += 1
                        continue
                    }
                    _ = try await database.addLesson(
                        text: text, pinned: lesson.pinned,
                        evidence: lesson.evidence.isEmpty ? "imported" : "\(lesson.evidence) · imported")
                    addedLessons += 1
                }
                let refreshedLessons = try await database.fetchLessons()
                guard generation == profileGeneration else { return }
                lessons = refreshedLessons
                notes.append("\(addedLessons) lesson(s) added"
                             + (skippedLessons > 0 ? " (\(skippedLessons) already present)" : ""))

                var addedCategories = 0
                var skippedCategories = 0
                for category in brain.categories {
                    if activeProfile.tasteCategories.contains(where: { $0.key == category.key }) {
                        skippedCategories += 1
                        continue
                    }
                    let frames = try await AppJobWork.run {
                        Self.writeImportedTasteFrames(category.exemplarFramesBase64, key: category.key, profileName: profileName)
                    }
                    guard generation == profileGeneration else { return }
                    activeProfile.tasteCategories.append(
                        TasteCategory(key: category.key, label: category.label,
                                      rubric: category.rubric, exemplarFrames: frames,
                                      studiedCount: category.studiedCount))
                    addedCategories += 1
                }
                notes.append("\(addedCategories) video type(s) added"
                             + (skippedCategories > 0 ? " (\(skippedCategories) kept yours)" : ""))

                let localRubricEmpty = activeProfile.tasteRubric
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if localRubricEmpty, !brain.tasteRubric.isEmpty {
                    activeProfile.tasteRubric = brain.tasteRubric
                    notes.append("taste rubric imported")
                } else if !brain.tasteRubric.isEmpty {
                    notes.append("taste rubric kept yours")
                }
                let localHouseStyleEmpty = activeProfile.houseStyle
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if localHouseStyleEmpty, !brain.houseStyle.isEmpty {
                    activeProfile.houseStyle = brain.houseStyle
                    notes.append("house style imported")
                } else if !brain.houseStyle.isEmpty {
                    notes.append("house style kept yours")
                }
                saveActiveProfile()
                wizardBrainStatus = "Imported \(url.lastPathComponent) (from \"\(brain.profileName)\"): "
                    + notes.joined(separator: ", ")
            } catch {
                presentError("Wizard Brain import failed", error)
            }
        }
    }

    /// Restore inlined exemplar frames to this profile's taste-frames folder.
    nonisolated private static func writeImportedTasteFrames(_ framesBase64: [String], key: String, profileName: String) -> [String] {
        let directory = SettingsStore.tasteFramesDirectory(profileName: profileName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        var paths: [String] = []
        for (index, base64) in framesBase64.prefix(8).enumerated() {
            guard let data = Data(base64Encoded: base64) else { continue }
            let url = directory.appendingPathComponent("imported-\(key)-\(stamp)-\(index).jpg")
            if (try? data.write(to: url)) != nil { paths.append(url.path) }
        }
        return paths
    }

    /// Re-reads the rulebook; a result from a database the user has since
    /// switched away from is dropped rather than shown under the new profile.
    func refreshLessons(from database: Database? = nil, generation: Int? = nil) async {
        let generation = generation ?? profileGeneration
        guard let database = database ?? self.database else { return }
        guard let rows = try? await database.fetchLessons(), generation == profileGeneration,
              database === self.database else { return }
        lessons = rows
    }
    func addLesson(text: String) {
        guard let database else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let generation = profileGeneration
        Task {
            do {
                try await database.addLesson(text: trimmed, pinned: true, evidence: "added by you")
                await refreshLessons(from: database, generation: generation)
            } catch {
                presentError("Could not save the lesson", error)
            }
        }
    }

    func updateLesson(_ lesson: WizardLesson, text: String? = nil, pinned: Bool? = nil) {
        guard let database else { return }
        let newText = text ?? lesson.text
        let newPinned = pinned ?? lesson.pinned
        let generation = profileGeneration
        Task {
            do {
                try await database.updateLesson(id: lesson.id, text: newText, pinned: newPinned)
                await refreshLessons(from: database, generation: generation)
            } catch {
                presentError("Could not update the lesson", error)
            }
        }
    }

    func deleteLesson(_ lesson: WizardLesson) {
        guard let database else { return }
        let generation = profileGeneration
        Task {
            do {
                try await database.deleteLesson(id: lesson.id)
                guard generation == profileGeneration else { return }
                lessons.removeAll { $0.id == lesson.id }
            } catch {
                presentError("Could not delete the lesson", error)
            }
        }
    }

    // MARK: - Wizard

    /// "Generate Video" from the Analyze tab: hand the description to the
    /// Wizard immediately (so the user lands on a live form), then analyze
    /// any un-analyzed selections and AI-parse the description into settings,
    /// updating the handoff in place. A failed parse degrades to passing the
    /// raw description as instructions — this never blocks the wizard.
    func generateSampleVideo(description: String, videos: [VideoRecord]) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !videos.isEmpty else { return }
        let unanalyzed = videos.filter { $0.visualAnalyzedAt == nil }
        let willAnalyze = !unanalyzed.isEmpty && !isAnalyzing
        let handoff = WizardPromptHandoff(description: trimmed, videoIDs: Set(videos.map(\.id)),
            statusMessage: willAnalyze ? "Analyzing \(unanalyzed.count) video(s), then interpreting your request…" : "Interpreting your request…")
        if willAnalyze { analyze(videos: unanalyzed) }
        startGenerateRequest(handoff, waitForAnalysis: willAnalyze || isAnalyzing)
    }

    /// "Generate Video" from the Scenes/People screens: the currently
    /// displayed scenes are the source, so their analyze batches plus the
    /// active people/tag filters ride into the Wizard alongside the parsed
    /// description. Scenes only exist for analyzed footage, so there is no
    /// analyze-first step here.
    func generateSampleVideo(description: String, scenes: [SceneRecord],
                             personKeys: Set<String>, tags: [String]) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !scenes.isEmpty else { return }
        let handoff = WizardPromptHandoff(description: trimmed, videoIDs: [],
            runIDs: Set(scenes.compactMap(\.runID)), personKeys: personKeys, tags: tags,
            statusMessage: "Interpreting your request…")
        startGenerateRequest(handoff, waitForAnalysis: false)
    }

    /// AI-parse a "Generate Video" description into settings, updating the
    /// pending handoff in place.
    private func startGenerateRequest(_ handoff: WizardPromptHandoff, waitForAnalysis: Bool) {
        let project = activeProject
        let projectKey = activeProjectID ?? 0
        let generation = profileGeneration
        let profile = activeProfile
        let wizard = wizard
        let useLocal = OnDevicePolicy.isEnabled(item: "wizard-request", config: settings.ai)
        let formatPreset = UserDefaults.standard.string(forKey: "wizard.formatPreset") ?? "custom"
        for job in jobs.running where job.kind == .generateRequest && job.projectID == project?.id { jobs.cancel(job.id) }
        wizardPromptRequests[projectKey] = handoff
        requestedSection = .wizard
        jobs.start(.generateRequest, title: "Generate Video Request", project: project,
                   profileGeneration: generation) { [self] log in
            var completed = handoff
            log(handoff.statusMessage ?? "Interpreting your request…")
            // Waiting is cancellable without cancelling the independent analysis task.
            while waitForAnalysis && isAnalyzing { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation()
            guard generation == profileGeneration else { throw CancellationError() }
            log("Interpreting your request…")
            do {
                completed.parsed = try await wizard.parseRequest(description: handoff.description, profile: profile,
                    emit: log, useLocal: useLocal, formatPreset: formatPreset)
            } catch {
                try Task.checkCancellation()
                completed.parseFailed = true
                appendLog(\.wizardLog, ["Could not interpret the request with AI — it will be passed to the wizard as-is. (\(error.userMessage))"])
            }
            try Task.checkCancellation()
            guard generation == profileGeneration else { throw CancellationError() }
            completed.statusMessage = nil
            wizardPromptRequests[projectKey] = completed
            return .generateRequest(completed)
        }
    }

    func cancelGenerateRequest() {
        for job in jobs.running where job.kind == .generateRequest && job.projectID == activeProjectID { jobs.cancel(job.id) }
        pendingWizardPrompt = nil
    }

    func runWizard(options: WizardOptions) {
        guard let database, !isWizardRunning else { return }
        var options = options.neutralized(for: ReelRecipe.recipe(id: options.formatPreset) ?? .custom)
        options.projectID = options.projectID ?? activeProjectID
        guard let projectID = options.projectID else { return }
        options.localHashtags = OnDevicePolicy.isEnabled(item: "hashtags", config: settings.ai)
        options.accountBenchmarks = igBenchmarks
        isWizardRunning = true
        wizardProjectID = projectID
        wizardProjectName = projects.first(where: { $0.id == projectID })?.name ?? activeProject?.name
        wizardLog = []
        lastWizardOptions = options
        wizardFailureMessage = nil
        wizardStatus = WizardRunStatus(stage: "Starting…", fraction: 0)
        let profile = activeProfile
        let wizard = wizard
        // Everything this run produces belongs to the profile (database) it
        // started in; after a profile switch its results must not land here.
        let generation = profileGeneration
        wizardTask = Task {
            await AIRunCapture.context.withValue(AIRunCapture()) {
            defer {
                isWizardRunning = false
                wizardStatus = nil
                wizardProjectID = nil
            }
            let previousIDs = Set(((try? await database.fetchGeneratedVideos(projectID: projectID)) ?? []).map(\.id))
            if options.formatPreset == "podcast_highlights" {
                do {
                    var review = try await wizard.findPodcastHighlights(options: options, settings: settings.podcast,
                                                                         database: database, emit: logSink(\.analysisLog), progress: { status, fraction in
                        await MainActor.run {
                            guard generation == self.profileGeneration, self.isWizardRunning else { return }
                            self.wizardStatus = WizardRunStatus(stage: status, fraction: fraction)
                        }
                    })
                    guard generation == profileGeneration else { return }
                    review.profileGeneration = generation
                    pendingPodcastHighlights = review
                } catch is CancellationError {
                    appendLog(\.wizardLog, ["Finding highlights stopped."])
                } catch { presentError("Could not find podcast highlights", error) }
                return
            }
            if options.reviewProposedCuts {
                do {
                    let prepared = try await wizard.plan(options: options, profile: profile,
                                                         database: database,
                                                         emit: logSink(\.wizardLog))
                    guard generation == profileGeneration else { return }
                    pendingCutReview = ProposedCutReviewRequest(plan: prepared.plan,
                                                               sceneMap: prepared.sceneMap,
                                                               options: options)
                } catch is CancellationError {
                    appendLog(\.wizardLog, ["Planning stopped."])
                } catch {
                    presentError("Could not prepare proposed cuts", error)
                }
                return
            }
            await wizard.run(options: options, profile: profile, database: database) { message in
                Task { @MainActor in
                    self.appendLog(\.wizardLog, [message])
                    self.updateWizardStatus(from: message)
                }
            }
            guard generation == profileGeneration else { return }
            await refreshAllNow()
            // Results sheet first (watch/rate/retry); any A/B comparison
            // queued below appears after it is dismissed.
            let fresh = ((try? await database.fetchGeneratedVideos(projectID: projectID)) ?? [])
                .filter { !previousIDs.contains($0.id) }
                .sorted { $0.id < $1.id }
            if !fresh.isEmpty {
                wizardResults = WizardRunResults(videos: fresh)
                await recordWizardTimelines(fresh, projectID: projectID,
                                            formatName: options.formatPreset)
            } else if !Task.isCancelled {
                // Nothing produced and the user didn't stop it — surface the
                // failure where the user is looking instead of leaving only a
                // red line in the log scrollback.
                wizardFailureMessage = Self.failureSummary(from: wizardLog)
            }
            queueComparisons(previousIDs: previousIDs)
        }
        }
    }

    /// Both entry points use the same stored exchanges and sentence-safe finder.
    func createPodcastHighlightTimelines(maxSeconds: Double?, maxCount: Int? = nil, requestText: String = "") async throws -> [String] {
        guard let database, let projectID = activeProjectID else { throw AIError.unusableResponse("Open a project first.") }
        let generation = profileGeneration
        var options = WizardOptions()
        options.projectID = projectID
        options.formatPreset = "podcast_highlights"
        options.highlightMaxSeconds = maxSeconds ?? settings.podcast.highlightMaxSeconds
        options.highlightMaxCount = maxCount
        let videos = try await database.fetchVideos(projectID: projectID)
        let projectScenes = try await database.fetchScenes(projectID: projectID, includeExcluded: false)
        let sourcePaths = Set(builder.document.videoTrack.filter { !$0.isCutaway }.compactMap { clip in
            clip.videoFile ?? projectScenes.first { $0.id == clip.sceneID }?.videoPath
        })
        let podcastIDs = Set(projectScenes.filter { $0.tags.contains("podcast-exchange") }.map(\.videoID))
        let podcastPaths = Set(videos.filter {
            sourcePaths.contains($0.path) && ($0.type == .podcast || $0.type == .interview || podcastIDs.contains($0.id))
        }.map(\.path))
        if !podcastPaths.isEmpty { options.sourcesRestricted = true; options.sourceVideoPaths = podcastPaths }
        let review = try await wizard.findPodcastHighlights(options: options, settings: settings.podcast,
                                                            database: database, emit: logSink(\.analysisLog), requestText: requestText)
        try Task.checkCancellation()
        guard generation == profileGeneration, activeProjectID == projectID else { throw CancellationError() }
        var names: [String] = []
        for candidate in review.candidates {
            try Task.checkCancellation()
            guard generation == profileGeneration, activeProjectID == projectID else { throw CancellationError() }
            let cuts = try await PodcastHighlightBRollPlacement.plan(candidate: candidate, video: review.video,
                scenes: review.scenes, turns: review.turns, roster: review.roster, segments: review.segments,
                options: review.options, threshold: review.highlightThreshold, ai: ai, people: review.people, log: logSink(\.analysisLog))
            try Task.checkCancellation()
            guard generation == profileGeneration else { throw CancellationError() }
            let document = PodcastHighlightTimeline.build(candidate: candidate, video: review.video, scenes: review.scenes,
                turns: review.turns, roster: review.roster, segments: review.segments, layouts: ScreenCropStore.all(),
                settings: review.options.renderSettings, threshold: review.highlightThreshold, options: review.options, plannedCuts: cuts, people: review.people, log: logSink(\.analysisLog))
            let name = "\(review.video.filename) — \(candidate.title)"
            var created = false
            guard let task = createTimeline(named: name, document: document, projectID: projectID, open: false,
                                            onCreated: { _ in created = true }) else {
                throw AIError.unusableResponse("Could not create the highlight timeline.")
            }
            await task.value
            guard created else { throw AIError.unusableResponse("Could not save highlight timeline: \(name)") }
            names.append(name)
        }
        return names
    }

    @discardableResult
    func renderPodcastHighlights(_ request: PodcastHighlightReviewRequest, selected: Set<UUID>) -> Bool {
        guard !isWizardRunning else {
            wizardFailureMessage = "Another Builder run is active. Wait for it to finish before rendering these highlights."
            return false
        }
        guard request.profileGeneration == profileGeneration else {
            wizardFailureMessage = "The profile changed. Find highlights again in the current profile."
            return false
        }
        guard let database, let projectID = request.options.projectID else {
            wizardFailureMessage = "Open the project again before rendering highlights."
            return false
        }
        let approved = request.candidates.filter { selected.contains($0.id) }
        guard !approved.isEmpty else {
            wizardFailureMessage = "Select at least one highlight to render."
            return false
        }
        wizardFailureMessage = nil
        awaitingPodcastReviewDismissal = pendingPodcastHighlights != nil
        pendingPodcastHighlights = nil
        isWizardRunning = true
        wizardProjectID = projectID
        wizardProjectName = projects.first { $0.id == projectID }?.name
        let generation = profileGeneration
        let profile = activeProfile
        let batchID = UUID().uuidString
        let renderer = multitrackRenderer
        wizardTask = Task {
            defer { isWizardRunning = false; wizardStatus = nil; wizardProjectID = nil }
            var timelineNames: [String: String] = [:]
            var reused: [GeneratedVideoRecord] = []
            let layouts = ScreenCropStore.all()
            do {
                for (index, candidate) in approved.enumerated() {
                    try Task.checkCancellation()
                    guard generation == profileGeneration else { throw CancellationError() }
                    wizardStatus = WizardRunStatus(stage: "Rendering highlight \(index + 1) of \(approved.count)",
                                                   fraction: Double(index) / Double(approved.count))
                    // Same recording, range, framing, B-roll pool, options, layouts and
                    // brand as an earlier reel that is still on disk: open that one.
                    let fingerprint = try? PodcastHighlightRenderKey.make(candidate: candidate, request: request, layouts: layouts,
                        profile: profile, sourceFingerprint: SourceIdentityCache.shared.fingerprint(of: request.video.url))
                    if let fingerprint,
                       let existing = try await database.generatedVideo(projectID: projectID, renderFingerprint: fingerprint) {
                        appendLog(\.wizardLog, ["Highlight \(index + 1) “\(candidate.title)” was already rendered with these settings: "
                            + "opening \(URL(fileURLWithPath: existing.path).lastPathComponent) instead of rendering again."])
                        reused.append(existing)
                        continue
                    }
                    let result = try await AIRunCapture.context.withValue(AIRunCapture()) {
                        let cuts = try await PodcastHighlightBRollPlacement.plan(candidate: candidate, video: request.video,
                            scenes: request.scenes, turns: request.turns, roster: request.roster, segments: request.segments,
                            options: request.options, threshold: request.highlightThreshold, ai: ai, people: request.people, log: logSink(\.analysisLog))
                        try Task.checkCancellation()
                        guard generation == profileGeneration else { throw CancellationError() }
                        let document = PodcastHighlightTimeline.build(candidate: candidate, video: request.video, scenes: request.scenes,
                            turns: request.turns, roster: request.roster, segments: request.segments, layouts: ScreenCropStore.all(),
                            settings: request.options.renderSettings, threshold: request.highlightThreshold,
                            options: request.options, plannedCuts: cuts, people: request.people, log: logSink(\.analysisLog))
                        return try await renderer.render(document: document, scenes: request.scenes, profile: profile,
                            database: database, projectID: projectID,
                            outputName: MultitrackRenderer.outputBaseName(project: request.video.filename, timeline: candidate.title),
                            batchID: batchID, wizardOptions: request.options, roles: request.roles + (AIRunCapture.current?.roles ?? []),
                            renderFingerprint: fingerprint, emit: logSink(\.wizardLog))
                    }
                    timelineNames[result.url.path] = "\(request.video.filename) — \(candidate.title)"
                }
            } catch is CancellationError { appendLog(\.wizardLog, ["Highlight rendering stopped."]) }
            catch { presentError("Could not render podcast highlights", error) }
            guard generation == profileGeneration else { return }
            await refreshAllNow()
            let fresh = ((try? await database.fetchGeneratedVideos(projectID: projectID)) ?? []).filter { $0.batchID == batchID }
            if !fresh.isEmpty {
                await recordWizardTimelines(fresh, projectID: projectID, formatName: "podcast_highlights", timelineNames: timelineNames)
                guard generation == profileGeneration else { return }
            }
            if !fresh.isEmpty || !reused.isEmpty {
                let results = WizardRunResults(videos: fresh + reused)
                if awaitingPodcastReviewDismissal {
                    podcastResultsAfterDismissal = results
                } else {
                    wizardResults = results
                }
            }
        }
        return true
    }

    /// SwiftUI calls this after the review sheet's dismissal animation finishes.
    func podcastHighlightReviewDidDismiss() {
        awaitingPodcastReviewDismissal = false
        if let results = podcastResultsAfterDismissal {
            podcastResultsAfterDismissal = nil
            wizardResults = results
        }
    }

    func renderApprovedCuts(_ plan: WizardPlan, options: WizardOptions) {
        guard let database, !isWizardRunning else { return }
        var options = options
        options.projectID = options.projectID ?? activeProjectID
        guard let projectID = options.projectID else { return }
        pendingCutReview = nil
        isWizardRunning = true
        wizardProjectID = projectID
        wizardProjectName = projects.first(where: { $0.id == projectID })?.name ?? activeProject?.name
        wizardStatus = WizardRunStatus(stage: "Rendering approved cuts", fraction: 0.3)
        let profile = activeProfile
        let wizard = wizard
        let generation = profileGeneration
        wizardTask = Task {
            await AIRunCapture.context.withValue(AIRunCapture()) {
            defer {
                isWizardRunning = false
                wizardStatus = nil
                wizardProjectID = nil
            }
            let previousIDs = Set(((try? await database.fetchGeneratedVideos(projectID: projectID)) ?? []).map(\.id))
            do {
                try await wizard.renderApprovedPlan(plan, options: options, profile: profile,
                                                    database: database, emit: logSink(\.wizardLog))
            } catch is CancellationError {
                appendLog(\.wizardLog, ["Render stopped."])
            } catch {
                presentError("Could not render approved cuts", error)
            }
            guard generation == profileGeneration else { return }
            await refreshAllNow()
            let fresh = ((try? await database.fetchGeneratedVideos(projectID: projectID)) ?? [])
                .filter { !previousIDs.contains($0.id) }
            if !fresh.isEmpty {
                wizardResults = WizardRunResults(videos: fresh)
                await recordWizardTimelines(fresh, projectID: projectID,
                                            formatName: options.formatPreset)
            }
        }
        }
    }

    /// Re-run the wizard with the same options as the last run.
    func retryWizard() {
        guard var options = lastWizardOptions else { return }
        // The saved options carry the project of the failed run; a retry
        // always targets the project on screen.
        options.projectID = activeProjectID
        wizardResults = nil
        runWizard(options: options)
    }

    /// Resolve a generated video's filename (as logged) to its file URL.
    /// Falls back to scanning the profile's dated output folders because the
    /// cached record list only refreshes after the run finishes.
    func generatedVideoURL(named filename: String) -> URL? {
        if let record = generatedVideos.first(where: { $0.filename == filename }) {
            return record.url
        }
        let root = activeProfile.outputFolderURL
        let dated = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for directory in dated.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let candidate = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Map engine log lines onto stage + overall progress: planning ~0-0.3,
    /// assembly 0.3-0.9, caption 0.9-1. Unknown lines leave the status
    /// untouched.
    /// "clip 3/12" progress marker in engine log lines, compiled once.
    private static let clipProgressPattern = /clip (\d+)\/(\d+)/

    private func updateWizardStatus(from rawMessage: String) {
        // Phase lines arrive with leading newlines for log readability.
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        func set(_ stage: String, detail: String = "", fraction: Double) {
            var status = wizardStatus ?? WizardRunStatus(stage: stage, fraction: 0)
            if status.stage != stage {
                status.stage = stage
                status.stageChangedAt = Date()
            }
            status.detail = detail
            status.fraction = min(1, max(status.fraction, fraction))
            wizardStatus = status
        }

        if message.hasPrefix("Phase 1") {
            set("Researching what performs on Reels", fraction: 0)
        } else if message.hasPrefix("Loading scenes") {
            set("Loading your scenes and music", fraction: 0.02)
        } else if message.hasPrefix("Phase 2: Planning the timeline") {
            set("Planning the timeline",
                detail: "The AI is designing the edit — this step can take a few minutes.",
                fraction: 0.05)
        } else if message.hasPrefix("Plan: ") {
            set("Plan ready", fraction: 0.3)
        } else if message.hasPrefix("Phase 3: Assembling") {
            set("Assembling the video",
                detail: "Cutting clips and burning in overlays.",
                fraction: 0.32)
        } else if let match = message.firstMatch(of: Self.clipProgressPattern) {
            if let index = Double(match.1), let total = Double(match.2), total > 0 {
                set("Cutting clip \(Int(index)) of \(Int(total))",
                    detail: "Extracting and styling each planned clip.",
                    fraction: 0.32 + 0.5 * (index / total))
            }
        } else if message.hasPrefix("Assembling ") {
            set("Joining clips with transitions", fraction: 0.85)
        } else if message.hasPrefix("Adding music") {
            set("Adding music", fraction: 0.9)
        } else if message.hasPrefix("Generating Instagram caption") {
            set("Writing the Instagram caption", fraction: 0.93)
        } else if message.contains(" complete! ") {
            set("Finishing up", fraction: 0.97)
        } else if message.hasPrefix("All done!") {
            set("Done", fraction: 1)
        }
    }

    /// New multi-variation batches from the finished run become A/B picks;
    /// each choice is preference data for future generations.
    func queueComparisons(previousIDs: Set<Int64>) {
        let fresh = generatedVideos.filter { !previousIDs.contains($0.id) && $0.batchID != nil }
        let batches = Dictionary(grouping: fresh) { $0.batchID! }
            .filter { $0.value.count > 1 }
            .map { ComparisonBatch(id: $0.key, videos: $0.value.sorted { $0.id < $1.id }) }
            .sorted { ($0.videos.first?.id ?? 0) < ($1.videos.first?.id ?? 0) }
        guard !batches.isEmpty else { return }
        comparisonQueue = batches
        pendingComparison = batches.first
    }

    func cancelWizard() {
        wizardTask?.cancel()
    }

    /// The most useful line of a failed run's log: the DONE:error payload
    /// when the engine reported one, else the last error-prefixed line.
    private static func failureSummary(from log: [String]) -> String {
        if let done = log.last(where: { $0.hasPrefix("DONE:error") }) {
            let detail = done.dropFirst("DONE:error".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return detail.isEmpty ? "The generation failed." : detail
        }
        if let error = log.last(where: { $0.hasPrefix("Error") }) {
            return error
        }
        return "The run finished without producing a video — see the log for details."
    }
}
