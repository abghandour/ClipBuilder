import Foundation

nonisolated struct BumperAsset: Identifiable, Sendable, Hashable {
    var path: String
    var displayName: String
    var placements: Set<BumperPlacement> = Set(BumperPlacement.allCases)
    var duration: Double?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    func clip(at time: Double) -> TimelineClip? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        var clip = TimelineClip()
        clip.bumper = true
        clip.bumperName = displayName
        clip.videoFile = path
        clip.sourceStart = 0
        clip.sourceEnd = duration
        clip.startTime = time
        clip.duration = duration
        clip.captions = "none"
        return clip
    }
}
