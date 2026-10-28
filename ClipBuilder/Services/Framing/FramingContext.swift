import Foundation

/// Evidence on the original source clock, shared by preview and generation.
nonisolated struct FramingContext: Sendable {
    var video: VideoRecord
    var type: VideoType
    var range: ClosedRange<Double>
    var canvasAspect: Double
    var roster: [VideoPersonRecord]
    var turns: [SpeakerTurn]
    var feeds: [PodcastTile]
    var storedPath: SceneCameraPath?
    var layouts: [ScreenCropLayout]
    var hasBRoll: Bool
    var sourceRoles: [String: String] = [:]
    var sources: [VideoRecord] = []
    var brollCuts: [PodcastHighlightBRollPlanner.Cut] = []
    var scenes: [SceneRecord] = []
    var chosenSubject: Framing.Subject?

    var sourceID: Int64 { video.id }
    var sourcePath: String { video.url.path }
    var width: Int { video.width }
    var height: Int { video.height }
    /// A run's own VIP choice (`Framing.vips`); nil follows the People tags.
    var vipOverride: Set<String>?
    var vipIDs: Set<String> { vipOverride ?? Set(roster.filter(\.isVIP).map(\.key)) }

    init(video: VideoRecord, range: ClosedRange<Double>, canvasAspect: Double,
         type: VideoType? = nil, roster: [VideoPersonRecord] = [], turns: [SpeakerTurn] = [],
         storedPath: SceneCameraPath? = nil, layouts: [ScreenCropLayout] = [],
         hasBRoll: Bool = false, chosenSubject: Framing.Subject? = nil) {
        self.video = video
        self.type = type ?? video.type ?? .other
        self.range = range
        self.canvasAspect = canvasAspect
        self.roster = roster
        self.turns = turns
        self.feeds = CropRecipePlanner.tiles(video: video, roster: roster)
        self.storedPath = storedPath
        self.layouts = layouts
        self.hasBRoll = hasBRoll
        self.chosenSubject = chosenSubject
    }

    init(scene: SceneRecord, range: ClosedRange<Double>, canvasAspect: Double,
         chosenSubject: Framing.Subject? = nil, type: VideoType? = nil) {
        let inferred: VideoType = scene.tags.contains("fight") ? .fight : scene.tags.contains("training") ? .training
            : scene.tags.contains("podcast") ? .podcast : .other
        let video = VideoRecord(id: scene.videoID, hash: "", filename: scene.videoURL.lastPathComponent,
            path: scene.videoPath, duration: max(scene.endTime, range.upperBound),
            width: scene.videoWidth, height: scene.videoHeight, wide: scene.wide,
            videoType: (type ?? inferred).rawValue)
        self.init(video: video, range: range, canvasAspect: canvasAspect,
                  storedPath: scene.centerStagePath, chosenSubject: chosenSubject)
    }
}
