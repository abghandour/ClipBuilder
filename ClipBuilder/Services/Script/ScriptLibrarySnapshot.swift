import Foundation

/// App-resolved inputs, never decoded from a script. Callers pass only the
/// active project's videos and scenes. All later reads use this value copy.
nonisolated struct ScriptLibrarySnapshot: Sendable {
    var projectID: Int64?
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
