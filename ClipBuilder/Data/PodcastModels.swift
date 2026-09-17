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
    /// Where the face usually sits in this feed (fractions of the source
    /// frame), from the frames the layout pass looked at.
    var faceX: Double? = nil
    var faceY: Double? = nil
    /// The part of the cell that actually shows picture (fractions of the
    /// source frame): call apps letterbox feeds inside their cells, and a
    /// crop that spans the whole cell would carry the black bars along.
    var pictureX: Double? = nil
    var pictureY: Double? = nil
    var pictureW: Double? = nil
    var pictureH: Double? = nil

    var id: Int { index }
    var faceCenter: (x: Double, y: Double)? {
        guard let faceX, let faceY else { return nil }
        return (faceX, faceY)
    }
    /// The cell trimmed to its picture, or the cell itself when the layout
    /// pass found no bars. Crops and feed regions come from this.
    var picture: PodcastTile {
        guard let pictureX, let pictureY, let pictureW, let pictureH, pictureW > 0, pictureH > 0 else { return self }
        var trimmed = self
        trimmed.x = pictureX; trimmed.y = pictureY; trimmed.w = pictureW; trimmed.h = pictureH
        trimmed.pictureX = nil; trimmed.pictureY = nil; trimmed.pictureW = nil; trimmed.pictureH = nil
        return trimmed
    }
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

nonisolated struct PodcastExchange: Sendable, Hashable, Codable {
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
