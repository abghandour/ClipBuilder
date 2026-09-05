import Foundation

/// Shared transcript backbone consumed by topic splitting, cleanup proposals,
/// captions, and podcast-oriented planning.
nonisolated struct TranscriptFeatureSegment: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case speech, silence, filler, noise
    }

    var id: Int64
    var videoID: Int64
    var startTime: Double
    var endTime: Double
    var text: String
    var speakerKey: String?
    var energy: Double
    var kind: Kind

    var duration: Double { endTime - startTime }
}

/// A visual identity observed during a source range. Transcript enrichment
/// uses these on-device scene/person tags before its conversational fallback.
nonisolated struct TranscriptSpeakerHint: Sendable, Hashable {
    var startTime: Double
    var endTime: Double
    var personKey: String
}
