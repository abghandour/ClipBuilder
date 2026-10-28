import Foundation

/// A timed source assigned to one stable layout area. Visual roles never select program audio.
nonisolated struct AreaSegment: Codable, Hashable, Sendable {
    var areaID: String
    var sourceID: Int64?
    var sourcePath: String
    /// Source-clock seconds, before playback speed is applied.
    var start: Double
    var duration: Double
    var role: Role?
    var framing: Picture
    var audio: AudioPolicy = .muted

    typealias Role = ScreenCropArea.Role
    /// Offset on the composition clock; source `start` remains independent.
    var timelineStart: Double?
    var region: FreeCropRect?
    var focus: AreaFocus?
    enum AudioPolicy: String, Codable, Hashable, Sendable {
        /// Program audio is supplied by the main recording, independent of this area's visual source.
        case program
        case muted
    }
    enum Picture: Codable, Hashable, Sendable {
        case `static`(window: FreeCropRect?)
        case recipe(CropRecipe)
    }
    enum CodingKeys: String, CodingKey {
        case areaID = "area_id"
        case sourceID = "source_id"
        case sourcePath = "source_path"
        case start, duration, role, framing, audio, region, focus
        case timelineStart = "timeline_start"
    }
}

/// Audio follows the composition's main recording even when its first area changes source.
nonisolated struct FramingProgramAudio: Codable, Hashable, Sendable {
    var path: String
    var start: Double
    var visualStart: Double? = nil

    enum CodingKeys: String, CodingKey {
        case path, start
        case visualStart = "visual_start"
    }
}
