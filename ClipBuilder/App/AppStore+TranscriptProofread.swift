import Foundation

/// Proofread as a background job, and the profile's corrections list.
extension AppStore {
    /// The project's setting; on unless the project turned it off.
    var proofreadsNewTranscripts: Bool { activeProject?.languages?.proofreadNewTranscripts ?? true }

    nonisolated static func proofreadSubject(videoID: Int64, setKey: String?) -> String {
        "\(videoID):\(setKey ?? "")"
    }

    func proofreadJob(videoID: Int64, setKey: String?) -> AppJob? {
        jobs.latest(.proofread, subjectID: Self.proofreadSubject(videoID: videoID, setKey: setKey))
    }

    /// What a transcription service calls when it stores a video's very
    /// first transcript. Captures this profile and project: a transcript
    /// that lands after either changed is not proofread.
    func firstTranscriptHandler() -> @Sendable (Int64, String) -> Void {
        let generation = profileGeneration
        let projectID = activeProjectID
        return { [weak self] videoID, key in
            Task { @MainActor [weak self] in
                guard let self, generation == self.profileGeneration, projectID == self.activeProjectID,
                      self.proofreadsNewTranscripts else { return }
                guard let video = self.videos.first(where: { $0.id == videoID }) else { return }
                self.startProofreading(video: video, setKey: key, automatic: true)
            }
        }
    }

    /// `automatic` runs wait for the video's transcription, speaker map and
    /// analysis to settle first: those replace lines, and a suggestion made
    /// for a line that no longer exists is dropped.
    func startProofreading(video: VideoRecord, setKey: String?, automatic: Bool = false) {
        guard let database else { return }
        let generation = profileGeneration
        let corrections = activeProfile.transcriptCorrections ?? []
        let ai = AIService(config: effectiveAIConfig)
        let videoID = video.id
        jobs.start(.proofread, title: "Proofread — \(video.filename)", project: activeProject,
                   profileGeneration: generation,
                   subjectID: Self.proofreadSubject(videoID: videoID, setKey: setKey)) { [self] log in
            if automatic {
                log("Waiting for the transcript to settle…")
                // At most 20 minutes; then proofread what is there.
                for _ in 0..<600 where transcribingVideoIDs.contains(videoID)
                    || speakerMappingVideoIDs.contains(videoID) || isAnalyzing {
                    try await Task.sleep(for: .seconds(2))
                }
            }
            guard generation == profileGeneration, self.database === database else { throw CancellationError() }
            let rows = try await database.fetchTranscripts(videoID: videoID, transcriptionKey: setKey)
            let names = ((try? await database.fetchVideoPeople(videoID: videoID)) ?? []).map(\.name)
            let chunks = try await AppJobWork.run { TranscriptProofreading.chunks(rows: rows) }
            guard !chunks.isEmpty else {
                log("Nothing to proofread: this transcript has no per-word text.")
                return nil
            }
            var found = 0
            for chunk in chunks {
                try Task.checkCancellation()
                log("Proofreading part \(chunk.number) of \(chunks.count)…")
                let prompt = try await AppJobWork.run {
                    try TranscriptProofreading.prompt(chunk: chunk, total: chunks.count, names: names, corrections: corrections)
                }
                let response = try await ai.call(prompt: prompt, task: .proofread, frames: nil, log: log)
                let suggestions = try await AppJobWork.run {
                    TranscriptProofreading.grouped(try TranscriptProofreading.parse(response.text, chunk: chunk))
                }
                try Task.checkCancellation()
                guard generation == profileGeneration, self.database === database else { throw CancellationError() }
                // Each finished part is saved at once; Stop keeps them.
                found += try await database.storeTranscriptSuggestions(suggestions, covered: chunk.covered, read: chunk.read)
                guard generation == profileGeneration, self.database === database else { throw CancellationError() }
                transcriptMarksRevision[videoID, default: 0] &+= 1
                log("PROGRESS:\(Double(chunk.number) / Double(chunks.count))")
            }
            log(found == 0 ? "Proofread found nothing to check."
                : "Proofread: \(found) word\(found == 1 ? "" : "s") to check in the Transcript editor.")
            return nil
        }
    }

    /// Add or replace the profile's correction for this word.
    func alwaysFixTranscriptWord(_ rule: TranscriptCorrectionRules.Rule) {
        var rules = activeProfile.transcriptCorrections ?? []
        rules.removeAll { TranscriptCorrectionRules.key($0.from) == TranscriptCorrectionRules.key(rule.from) }
        rules.append(rule)
        activeProfile.transcriptCorrections = rules
        saveActiveProfile()
    }

    func deleteTranscriptCorrection(_ rule: TranscriptCorrectionRules.Rule) {
        activeProfile.transcriptCorrections?.removeAll { $0 == rule }
        saveActiveProfile()
    }
}
