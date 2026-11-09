import Foundation

extension AppStore {
    /// The profile's dub voice engine. Siri needs a one-time setup per language
    /// (voice download plus shortcut), driven from the dub language picker.
    var dubEngine: DubVoiceEngine {
        get { editingDefaults.footage.dubEngine.flatMap(DubVoiceEngine.init(rawValue:)) ?? .mac }
        set {
            var editing = editingDefaults
            editing.footage.dubEngine = newValue == .mac ? nil : newValue.rawValue
            activeProfile.editing = editing
            saveActiveProfile()
        }
    }

    typealias PrepareDub = @Sendable (TimelineDocument, DubSettings, @escaping @Sendable (String) -> Void) async throws -> DubPreparation.Prepared

    @discardableResult
    func dubTimeline(language: String, originalLevel: Double = 0.15, replaceOriginal: Bool = true,
                     prepare: PrepareDub? = nil) -> UUID? {
        guard database != nil || prepare != nil, !builder.document.videoTrack.isEmpty else { return nil }
        let document = builder.document
        let target = DubReview.Target.builder(timelineID: openTimelineID, revision: builder.revision)
        let generation = profileGeneration
        let settings = DubSettings(language: language, voices: editingDefaults.dubVoices ?? [:],
                                   originalLevel: originalLevel, replaceOriginal: replaceOriginal,
                                   engine: dubEngine == .mac ? nil : dubEngine)
        let database = database, ai = ai
        let scenes = builder.scenes
        return jobs.start(.dub, title: "Dub timeline", project: activeProject, profileGeneration: generation,
                          subjectID: "timeline-\(openTimelineID.map(String.init) ?? "unsaved")") { log in
            let prepared: DubPreparation.Prepared
            if let prepare {
                prepared = try await prepare(document, settings, log)
            } else if let database {
                let referenced = try await database.fetchScenes(ids: Set(document.videoTrack.compactMap(\.sceneID)))
                let allScenes = referenced + scenes.filter { scene in !referenced.contains { $0.id == scene.id } }
                prepared = try await DubPreparation.prepare(document: document, scenes: allScenes, settings: settings,
                                                            database: database, ai: ai,
                                                            speech: .forEngine(settings.engine), log: log)
            } else { throw CancellationError() }
            return .dub(DubReview(prepared: prepared, target: target, profileGeneration: generation))
        }
    }

    func reviewTimelineDub() {
        guard let settings = builder.document.dub, let lines = builder.document.dubLines, !lines.isEmpty else { return }
        let document = builder.document, scenes = builder.scenes
        let database = database
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.key, $0.displayName) })
        let target = DubReview.Target.builder(timelineID: openTimelineID, revision: builder.revision)
        let generation = profileGeneration
        jobs.start(.dub, title: "Review dub", project: activeProject, profileGeneration: generation) { _ in
            let prepared = await DubPreparation.reopening(document: document, scenes: scenes,
                                                         settings: settings, lines: lines, speakerNames: names, database: database)
            return .dub(DubReview(prepared: prepared, target: target, profileGeneration: generation))
        }
    }

    /// Re-prepares every line whose text, speaker or voice changed in the
    /// review, in one background job. Voices are per speaker: `settings.voices`
    /// decides each line's voice, so a voice change re-fits all that speaker's lines.
    /// Returns the update job's ID so an open review sheet can follow it and
    /// adopt the result in place (`AppJobs.adoptReviewInPlace`).
    @discardableResult
    func updateDubReview(_ review: DubReview, jobID: UUID, lines: [DubLine], settings: DubSettings,
                         speech: DubPreparation.Speech? = nil) -> UUID? {
        guard review.profileGeneration == profileGeneration else { return nil }
        let jobs = jobs
        let database = database
        let speech = speech ?? .forEngine(settings.engine)
        return jobs.start(.dub, title: "Update dub lines", project: activeProject, profileGeneration: profileGeneration,
                   subjectID: jobID.uuidString) { log in
            var updated = review
            let installed = try await DubPreparation.includingReusableVoices(await speech.voices(settings.language),
                lines: lines, settings: settings, genders: review.prepared.speakerGenders, database: database)
            let settings = try DubPreparation.assigningVoices(lines: lines, settings: settings,
                                                              installed: installed,
                                                              genders: review.prepared.speakerGenders)
            updated.prepared.settings = settings
            let previous = Dictionary(uniqueKeysWithValues: review.prepared.lines.map { ($0.id, $0) })
            let slots = updated.prepared.slots, overlaps = updated.prepared.overlaps
            updated.prepared.lines = try await ElevenLabsDubUsage.withLogging(
                enabled: settings.engine == .elevenLabs, log: log) {
                var result: [DubLine] = []
                for (index, var line) in lines.enumerated() {
                    try Task.checkCancellation()
                    line.voice = settings.voices[line.speakerKey] ?? line.voice
                    if let old = previous[line.id], old.text == line.text, old.voice == line.voice,
                       let audio = old.audio,
                       (!ElevenLabsVoices.isElevenLabs(line.voice)
                        || DubTakeStore.hasAudio(DubSynthesizer.cacheDirectory.appendingPathComponent(audio))) {
                        line = old; line.speakerKey = lines[index].speakerKey
                        if ElevenLabsVoices.isElevenLabs(line.voice) {
                            ElevenLabsDubUsage.current?.reuse(characters: line.text.count)
                        }
                    } else {
                        log("Dub line \(index + 1) of \(lines.count)")
                        line = try await DubPreparation.fit(line, slot: slots[line.id] ?? 0,
                            overlapping: overlaps.contains(line.id), speech: speech, database: database,
                            preview: settings.engine == .elevenLabs)
                    }
                    result.append(line)
                    log("PROGRESS: \(Double(index + 1) / Double(lines.count))")
                }
                return result
            }
            try Task.checkCancellation()
            if case .render(let id) = review.target, !self.dubReviews.isPending(id) { throw CancellationError() }
            // Reviewed wording is remembered on Apply only, so Cancel discards it.
            jobs.markReviewed(jobID)
            return .dub(updated)
        }
    }

    @discardableResult
    func applyDubReview(_ review: DubReview, jobID: UUID, remember: Bool = true,
                        speech: DubPreparation.Speech? = nil) -> Bool {
        guard review.profileGeneration == profileGeneration else { return false }
        guard canApplyDubReview(review) else { return false }
        if review.prepared.lines.contains(where: { $0.draft == true }) {
            let database = database
            let generation = profileGeneration
            let project = activeProject
            let finalJobID = jobs.start(.dub, title: "Finalize dub", project: project, profileGeneration: generation,
                       subjectID: "apply-\(jobID)", cleanup: { [weak self] in
                // Also covers Stop before the job body starts.
                if case .render(let id) = review.target { self?.dubReviews.cancel(id) }
            }) { [self] log in
                let prepared = try await ElevenLabsDubUsage.withLogging(enabled: true, log: log) {
                    try await DubPreparation.finalize(review.prepared, database: database, speech: speech, log: log)
                }
                try Task.checkCancellation()
                guard profileGeneration == generation, self.database === database,
                      canApplyDubReview(review) else { throw CancellationError() }
                if let database { try await database.rememberDubReview(prepared.lines) }
                try Task.checkCancellation()
                guard profileGeneration == generation, self.database === database,
                      canApplyDubReview(review) else { throw CancellationError() }
                commitDubReview(review, prepared: prepared, remember: remember)
                return nil
            }
            if case .render(let id) = review.target { dubReviews.finalizing(id, jobID: finalJobID) }
            jobs.markReviewed(jobID)
            return true
        }
        commitDubReview(review, prepared: review.prepared, remember: remember)
        if let database {
            let lines = review.prepared.lines
            jobs.start(.dub, title: "Save reviewed dub", project: activeProject, profileGeneration: profileGeneration) { _ in
                try await database.rememberDubReview(lines)
                return nil
            }
        }
        jobs.markReviewed(jobID)
        return true
    }

    private func canApplyDubReview(_ review: DubReview) -> Bool {
        guard review.profileGeneration == profileGeneration else { return false }
        switch review.target {
        case let .builder(timelineID, revision):
            guard openTimelineID == timelineID, builder.revision == revision else {
                presentError("The timeline changed while the dub was being reviewed. Start Dub again for the current edit.")
                return false
            }
            return true
        case .render(let id): return dubReviews.isPending(id)
        }
    }

    private func commitDubReview(_ review: DubReview, prepared: DubPreparation.Prepared, remember: Bool) {
        switch review.target {
        case .builder:
            builder.setDub(settings: prepared.settings, lines: prepared.lines)
        case .render(let id):
            dubReviews.apply(id, prepared: prepared)
        }
        if remember {
            var editing = editingDefaults
            var voices = editing.dubVoices ?? [:]
            for (speaker, voice) in prepared.settings.voices { voices[speaker] = voice }
            editing.dubVoices = voices
            activeProfile.editing = editing
            saveActiveProfile()
        }
    }

    func cancelDubReview(_ review: DubReview) {
        if case .render(let id) = review.target { dubReviews.cancel(id) }
    }
}
