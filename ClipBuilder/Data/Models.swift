import Foundation

/// Row models mirroring the ClipBuilder SQLite schema (one DB per profile).
/// Field names track the Python app's columns so existing databases open
/// unchanged.

nonisolated struct VideoRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var hash: String
    var filename: String
    var path: String
    var duration: Double
    var width: Int
    var height: Int
    var wide: Bool
    var discoveredAt: String?
    var analyzedAt: String?
    var visualAnalyzedAt: String?
    var speechAnalyzedAt: String?
    var visualAnalyzerProvider: String?
    var visualAnalyzerModel: String?
    var speechAnalyzerProvider: String?
    var speechAnalyzerModel: String?

    var url: URL { URL(fileURLWithPath: path) }
}

nonisolated struct SceneRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var startTime: Double
    var endTime: Double
    var excluded: Bool
    var ignored: Bool
    var favorite: Bool
    var cropXFrac: Double?
    var freeCropsJSON: String?
    var tags: [String]
    var gradeAverage: Double?
    var gradeCount: Int
    // Denormalized from the joined videos row for display/rendering.
    var videoPath: String
    var videoFilename: String
    var videoDuration: Double
    var wide: Bool

    var duration: Double { endTime - startTime }
    var videoURL: URL { URL(fileURLWithPath: videoPath) }
}

nonisolated struct MomentRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var atTime: Double
    var note: String
    var dialog: String?
}

nonisolated struct TranscriptRow: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var language: String
    var isTranslation: Bool
    var startTime: Double
    var endTime: Double
    var text: String
    var originalText: String?
    var wordsJSON: String?
    var provider: String?
    var model: String?
}

nonisolated struct GeneratedVideoRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var path: String
    var duration: Double
    var timelineJSON: String
    var caption: String
    var generatedAt: String?
    var wizardProvider: String?
    var wizardModel: String?
    var captionProvider: String?
    var captionModel: String?

    var url: URL { URL(fileURLWithPath: path) }
    var filename: String { url.lastPathComponent }
}

nonisolated struct WizardResearchRecord: Sendable {
    var id: Int64
    var topic: String
    var resultJSON: String
    var researchedAt: Date?
    var provider: String?
    var model: String?
}

nonisolated struct FeedbackRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var generatedVideoID: Int64
    var feedback: String
    var createdAt: String?
    var videoPath: String?
    var videoDuration: Double?
}

/// One transcript segment as produced by a transcription provider (matches
/// the Python cache JSON: {start, end, text, words: [{word, start, end}]}).
nonisolated struct TranscriptSegment: Codable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var words: [TranscriptWord]?
}

nonisolated struct TranscriptWord: Codable, Sendable {
    var word: String
    var start: Double
    var end: Double
}
