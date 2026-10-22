import Foundation

extension AppStore {
    typealias PrepareDub = @Sendable (TimelineDocument, DubSettings, @escaping @Sendable (String) -> Void) async throws -> DubPreparation.Prepared

    @discardableResult
    func dubTimeline(language: String, originalLevel: Double = 0.15, replaceOriginal: Bool = false,
                     prepare: PrepareDub? = nil) -> UUID? {
        guard database != nil || prepare != nil, !builder.document.videoTrack.isEmpty else { return nil }
        let document = builder.document
        let target = DubReview.Target.builder(timelineID: openTimelineID, revision: builder.revision)
        let generation = profileGeneration
        let settings = DubSettings(language: language, voices: editingDefaults.dubVoices ?? [:],
                                   originalLevel: originalLevel, replaceOriginal: replaceOriginal)
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
                                                            database: database, ai: ai, log: log)
            } else { throw CancellationError() }
            return .dub(DubReview(prepared: prepared, target: target, profileGeneration: generation))
        }
    }

    func reviewTimelineDub() {
        guard let settings = builder.document.dub, let lines = builder.document.dubLines, !lines.isEmpty else { return }
        let document = builder.document, scenes = builder.scenes
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.key, $0.name) })
        let target = DubReview.Target.builder(timelineID: openTimelineID, revision: builder.revision)
        let generation = profileGeneration
        jobs.start(.dub, title: "Review dub", project: activeProject, profileGeneration: generation) { _ in
            let prepared = await DubPreparation.reopening(document: document, scenes: scenes,
                                                         settings: settings, lines: lines, speakerNames: names)
            return .dub(DubReview(prepared: prepared, target: target, profileGeneration: generation))
        }
    }

    func resynthesizeDubLine(_ line: DubLine, review: DubReview, jobID: UUID) {
        guard review.profileGeneration == profileGeneration else { return }
        let jobs = jobs
        jobs.start(.dub, title: "Update dub line", project: activeProject, profileGeneration: profileGeneration,
                   subjectID: line.id.uuidString) { log in
            var updated = review
            guard let index = updated.prepared.lines.firstIndex(where: { $0.id == line.id }) else { throw CancellationError() }
            log("Dub line \(index + 1) of \(updated.prepared.lines.count)")
            updated.prepared.lines[index] = try await DubPreparation.fit(line,
                slot: updated.prepared.slots[line.id] ?? 0, overlapping: updated.prepared.overlaps.contains(line.id))
            updated.prepared.settings.voices[line.speakerKey] = line.voice
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
