import Foundation

extension AppStore {
    @discardableResult
    func startCameraPath(sceneID: Int64, videoID: Int64, start: Double, end: Double, camera: String,
                         reportsFailure: Bool = true) -> UUID {
        let key = CameraPathJobKey(sceneID: sceneID, start: start, end: end, camera: camera)
        return jobs.start(.cameraPath, title: "Center Stage — Scene \(sceneID)", project: activeProject,
                   profileGeneration: profileGeneration, subjectID: key.subjectID, subjectGroupID: key.groupID,
                   reportsFailure: reportsFailure) { [self] log in
            log("Tracking the subject…")
            try await computeCameraPath(sceneID: sceneID, videoID: videoID, start: start, end: end, camera: camera)
            log("Camera path saved.")
            return nil
        }
    }

    func startSpeakerMapping(video: VideoRecord) {
        let generation = profileGeneration
        jobs.start(.mapSpeakers, title: "Map Speakers — \(video.filename)", project: activeProject,
                   profileGeneration: profileGeneration, subjectID: String(video.id)) { [self] log in
            _ = try await mapSpeakersAgain(video: video, status: log)
            _ = await transcriptRows(videoID: video.id)
            guard generation == profileGeneration else { throw CancellationError() }
            log("Speakers mapped again. The transcript is ready.")
            return nil
        }
    }

    func startTrimSuggestion(video: VideoRecord) {
        jobs.start(.suggestTrim, title: "Suggest Trim — \(video.filename)", project: activeProject,
                   profileGeneration: profileGeneration, subjectID: String(video.id)) { [self] log in
            let suggestion = try await suggestTrim(for: video, log: log)
            return .trim(start: suggestion.start, end: suggestion.end, reason: suggestion.reason,
                         provenance: suggestion.provenance)
        }
    }

    func startModelEvaluation(_ item: ReelModelItem, adopting model: LearnedModelArtifact? = nil) {
        guard let destination = reelModelStore else { return }
        let profile = activeProfile.profileName
        jobs.start(.evaluateReelModel, title: "Evaluate \(item.rawValue)", project: nil,
                   profileGeneration: profileGeneration, subjectID: item.rawValue) { [self] log in
            if let model {
                let source = LearnedLibrary(profile: profile).directory.appendingPathComponent(model.contributor)
                    .appendingPathComponent("models/\(model.item.filename)-v\(model.version).\(model.item.artifactExtension)")
                try await AppJobWork.run { try model.adopt(from: source, to: destination) }
            }
            try Task.checkCancellation()
            log("Evaluating against this profile’s examples…")
            let report = try await evaluateReelModel(item)
            log(report.summary)
            return nil
        }
    }

    func startPublishingLessons() {
        let profile = activeProfile
        let benchmarks = igBenchmarks
        jobs.start(.publishLessons, title: "Publish AI Lessons", project: nil,
                   profileGeneration: profileGeneration, subjectID: profile.profileName) { [self] log in
            log("Publishing learned preferences…")
            try await googleDrive.publishLearned(profile: profile, benchmarks: benchmarks)
            log("Published AI Lessons.")
            return nil
        }
    }

    func startTranscriptAnalysis(video: VideoRecord) {
        guard let database else { return }
        let settings = settings.podcast
        jobs.start(.transcriptAnalysis, title: "Analyze Transcript — \(video.filename)", project: activeProject,
                   profileGeneration: profileGeneration, subjectID: String(video.id)) { log in
            let original = try await database.fetchTranscripts(videoID: video.id).filter { !$0.isTranslation }
            let people = try await database.fetchVideoPeople(videoID: video.id)
            let scenes = try await database.fetchScenes(includeExcluded: true).filter { $0.videoID == video.id }
            log("Finding topics, pauses, and filler…")
            let (features, proposals, topics) = try await AppJobWork.run {
                let segments = original.map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: nil) }
                let result = TranscriptFeatureAnalyzer.analyze(
                    segments: segments, videoID: video.id, speakerKeys: people.map(\.key), mediaDuration: video.duration,
                    speakerHints: TranscriptFeatureAnalyzer.speakerHints(scenes: scenes, personKeys: people.map(\.key)),
                    deadAirThreshold: settings.deadAirSeconds, fillerRunThreshold: settings.fillerRunSeconds)
                try Task.checkCancellation()
                return (result.features, settings.cleanupCutPolicy.applied(to: result.proposals),
                        TopicSegmenter.segment(result.features, videoID: video.id))
            }
            try Task.checkCancellation()
            try await database.replaceTranscriptFeatures(videoID: video.id, features: features, proposals: proposals)
            try await database.replaceTopicRanges(videoID: video.id, topics: topics)
            log("Created \(topics.count) topics and \(proposals.count) cleanup proposals.")
            return nil
        }
    }
}
