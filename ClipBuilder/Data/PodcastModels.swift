import Foundation

nonisolated enum PodcastLayout: String, Codable, Sendable, CaseIterable {
    case singleCamera = "single_camera"
    case splitHorizontal = "split_horizontal"
    /// Several fixed feeds in cells (a video call, a stacked two-up): each
    /// speaker lives in one tile of `PodcastTile`s.
    case grid = "grid"

    var label: String {
        switch self {
        case .singleCamera: "Single camera"
        case .splitHorizontal: "Side by side"
        case .grid: "Grid"
        }
    }
}

/// One cell of a grid layout, normalized to the source frame (top-left
/// origin), with the person the People pass put there when known.
nonisolated struct PodcastTile: Codable, Sendable, Hashable, Identifiable {
    var index: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var personKey: String? = nil

    var id: Int { index }
    var centerX: Double { x + w / 2 }
    var centerY: Double { y + h / 2 }
    func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= x + w && py >= y && py <= y + h
    }
}

nonisolated enum PodcastSpeakerSide: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case full
    case unknown
}

/// A diarized stretch of speech. Audio owns the initial cluster and
/// confidence; the sparse picture pass may resolve a screen side, and the
/// People pass may attach a profile-wide identity.
nonisolated struct SpeakerTurn: Identifiable, Codable, Sendable, Hashable {
    var id: Int64 = 0
    var videoID: Int64
    var start: Double
    var end: Double
    var cluster: Int
    var confidence: Double
    var pictureSide: PodcastSpeakerSide = .unknown
    var pictureConfidence: Double = 0
    var resolvedSide: PodcastSpeakerSide = .unknown
    var personKey: String? = nil
    /// Grid layouts: the tile the speaker was seen talking in.
    var tile: Int? = nil
}

nonisolated struct PictureTalkerSignal: Sendable, Hashable {
    var start: Double
    var end: Double
    var side: PodcastSpeakerSide
    var confidence: Double
    /// Grid layouts: the tile whose mouth moved most during the turn.
    var tile: Int? = nil
}

nonisolated struct PodcastLanguageCandidate: Sendable, Hashable {
    var identifier: String
    var confidence: Double
}

nonisolated struct PodcastExchange: Sendable, Hashable {
    var start: Double
    var end: Double
    var title: String
    var summary: String
    var score: Double
    var speakerKeys: [String]
}

nonisolated enum PodcastFramingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case followSpeaker = "follow_speaker"
    case splitZoom = "split_zoom"
    case original

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followSpeaker: "Follow speaker"
        case .splitZoom: "Split Zoom feeds"
        case .original: "Original framing"
        }
    }
}
