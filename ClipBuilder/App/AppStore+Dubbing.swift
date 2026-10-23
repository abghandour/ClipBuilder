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
                                   engine: dubEngine == .siri ? .siri : nil)
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
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.key, $0.displayName) })
        let target = DubReview.Target.builder(timelineID: openTimelineID, revision: builder.revision)
        let generation = profileGeneration
        jobs.start(.dub, title: "Review dub", project: activeProject, profileGeneration: generation) { _ in
            let prepared = await DubPreparation.reopening(document: document, scenes: scenes,
                                                         settings: settings, lines: lines, speakerNames: names)
            return .dub(DubReview(prepared: prepared, target: target, profileGeneration: generation))
        }
    }

    /// Re-prepares every line whose text, speaker or voice changed in the
    /// review, in one background job. Voices are per speaker: `settings.voices`
    /// decides each line's voice, so a voice change re-fits all that speaker's lines.
    func updateDubReview(_ review: DubReview, jobID: UUID, lines: [DubLine], settings: DubSettings,
                         speech: DubPreparation.Speech? = nil) {
        guard review.profileGeneration == profileGeneration else { return }
        let jobs = jobs
        let speech = speech ?? .forEngine(settings.engine)
        jobs.start(.dub, title: "Update dub lines", project: activeProject, profileGeneration: profileGeneration,
                   subjectID: jobID.uuidString) { log in
            var updated = review
            let settings = try DubPreparation.assigningVoices(lines: lines, settings: settings,
                                                              installed: await speech.voices(settings.language),
                                                              genders: review.prepared.speakerGenders)
            updated.prepared.settings = settings
            let previous = Dictionary(uniqueKeysWithValues: review.prepared.lines.map { ($0.id, $0) })
            var result: [DubLine] = []
            for (index, var line) in lines.enumerated() {
                try Task.checkCancellation()
                line.voice = settings.voices[line.speakerKey] ?? line.voice
                if let old = previous[line.id], old.text == line.text, old.voice == line.voice, old.audio != nil {
                    line = old; line.speakerKey = lines[index].speakerKey
                } else {
                    log("Dub line \(index + 1) of \(lines.count)")
                    line = try await DubPreparation.fit(line, slot: updated.prepared.slots[line.id] ?? 0,
                        overlapping: updated.prepared.overlaps.contains(line.id), speech: speech)
                }
                result.append(line)
                log("PROGRESS: \(Double(index + 1) / Double(lines.count))")
            }
            updated.prepared.lines = result
            try Task.checkCancellation()
            if case .render(let id) = review.target, !self.dubReviews.isPending(id) { throw CancellationError() }
            jobs.markReviewed(jobID)
            return .dub(updated)
        }
    }

    @discardableResult
    func applyDubReview(_ review: DubReview, jobID: UUID, remember: Bool = true) -> Bool {
        guard review.profileGeneration == profileGeneration else { return false }
        switch review.target {
        case let .builder(timelineID, revision):
            guard openTimelineID == timelineID, builder.revision == revision else {
                presentError("The timeline changed while the dub was being reviewed. Start Dub again for the current edit.")
                return false
            }
            builder.setDub(settings: review.prepared.settings, lines: review.prepared.lines)
        case .render(let id):
            guard dubReviews.isPending(id) else { return false }
            dubReviews.apply(id, prepared: review.prepared)
        }
        if remember {
            var editing = editingDefaults
            var voices = editing.dubVoices ?? [:]
            for (speaker, voice) in review.prepared.settings.voices { voices[speaker] = voice }
            editing.dubVoices = voices
            activeProfile.editing = editing
            saveActiveProfile()
        }
        jobs.markReviewed(jobID)
        return true
    }

    func cancelDubReview(_ review: DubReview) {
        if case .render(let id) = review.target { dubReviews.cancel(id) }
    }
}
