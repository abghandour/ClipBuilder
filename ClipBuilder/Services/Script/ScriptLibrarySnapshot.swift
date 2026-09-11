import Foundation

/// App-resolved inputs, never decoded from a script. Callers pass only the
/// active project's videos and scenes. All later reads use this value copy.
nonisolated struct ScriptLibrarySnapshot: Sendable {
    var projectID: Int64?
    var prerequisiteOutcomes: [Int64: [BuilderPrerequisiteKind: PrerequisiteOutcome]] = [:]
    var videos: [VideoRecord] = []
    var scenes: [SceneRecord] = []
    var people: [PersonRecord] = []
    var videosWithPeople: Set<Int64> = []
    var transcripts: [TranscriptRow] = []
    var features: [TranscriptFeatureSegment] = []
    var proposals: [EditProposal] = []
    var tags: [String] = []
    var layouts: [ScreenCropLayout] = []
    var bumpers: [String: BumperAsset] = [:]
    var sounds: [String: String] = [:]
    var images: [String: String] = [:]

    /// Explicit Library refresh preserves resource identities captured at session
    /// creation. It never subscribes to AppStore or hydrates the live document.
    func refreshed(database: Database, language: String = "") async throws -> Self {
        var copy = self
        copy.videos = try await database.fetchVideos(projectID: projectID)
        copy.scenes = try await database.fetchScenes(projectID: projectID)
        copy.people = try await database.fetchPeople()
        copy.transcripts = []; copy.features = []; copy.proposals = []
        copy.videosWithPeople = []; copy.prerequisiteOutcomes = [:]
        let started = ContinuousClock.now
        for video in copy.videos {
            try Task.checkCancellation()
            guard started.duration(to: .now) < .seconds(10) else {
                throw ScriptError.invalid("Library snapshot exceeded ten seconds.")
            }
            copy.transcripts += try await database.fetchTranscripts(videoID: video.id)
            copy.features += try await database.fetchTranscriptFeatures(videoID: video.id)
            copy.proposals += try await database.fetchEditProposals(videoID: video.id)
            if !(try await database.fetchVideoPeople(videoID: video.id)).isEmpty { copy.videosWithPeople.insert(video.id) }
            for kind in BuilderPrerequisiteKind.allCases {
                let signature = "v1:\(video.hash):\(kind == .transcript ? language : "")"
                if let outcome = try await database.prerequisiteResult(kind: kind, video: video,
                                                                       signature: signature, language: language) {
                    copy.prerequisiteOutcomes[video.id, default: [:]][kind] = outcome
                }
            }
        }
        return copy
    }

    /// Task-local lookup confines resource overrides to a synchronous edit;
    /// normal UI and rendering continue resolving their live resources.
    @MainActor
    func withLayouts<T>(_ body: () throws -> T) rethrows -> T {
        try ScriptLayoutScope.$layouts.withValue(layouts, operation: body)
    }

    func sourceDuration(for clip: TimelineClip) -> Double? {
        if let id = clip.sceneID, let scene = scenes.first(where: { $0.id == id }) { return scene.videoDuration }
        return videos.first { $0.path == clip.videoFile }?.duration
    }
}

nonisolated enum ScriptLayoutScope {
    @TaskLocal static var layouts: [ScreenCropLayout]?
}
