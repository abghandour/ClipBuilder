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

/// A user note anchored at a timestamp in a source video — injected into
/// that video's analysis prompt as highest-priority guidance.
nonisolated struct VideoNote: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var atTime: Double
    var note: String
}

/// One analysis pass over a video: when it ran, the instructions and notes
/// context it used, and which model produced it. Scenes belong to a batch,
/// so re-analyzing a video adds a new batch alongside the old one.
nonisolated struct AnalysisRun: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var name: String
    var instructions: String
    var provider: String?
    var model: String?
    /// Whether this batch's analyze run produced (or kept) a transcript.
    var hasTranscript: Bool
    /// Seconds between sampled frames; 0 = automatic (1–3s by length).
    var sampleInterval: Double
    /// Snapshot of the video's timestamped notes at analysis time
    /// ([AnalysisRunNote] JSON); nil for batches that predate note snapshots.
    var notesJSON: String?
    var createdAt: String?
    // Denormalized from the joined videos row for display.
    var videoFilename: String
    var videoPath: String
    var sceneCount: Int

    var videoURL: URL { URL(fileURLWithPath: videoPath) }

    /// Decoded note snapshot; nil when this batch predates note snapshots.
    var noteSnapshot: [AnalysisRunNote]? {
        guard let data = notesJSON?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([AnalysisRunNote].self, from: data)
    }
}

/// One timestamped note as recorded on an analyze batch.
nonisolated struct AnalysisRunNote: Codable, Sendable, Hashable {
    var at: Double
    var note: String
}

/// One user-drawn box around a VIP subject, anchored at a video timestamp.
/// Coordinates are fractions of the video frame with a top-left origin.
nonisolated struct SubjectRect: Codable, Sendable, Hashable {
    var at: Double
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// A named person the user marked in a source video by drawing one or more
/// colored boxes ("VIP subjects"). The analyzer sends each box's frame as a
/// reference so it can tag scenes featuring the subject, and the wizard maps
/// the name back to those tags when instructions mention the person.
nonisolated struct VideoSubject: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var name: String
    var colorIndex: Int
    var rectsJSON: String
    var createdAt: String?
    // Denormalized from the joined videos row for display.
    var videoFilename: String

    var rects: [SubjectRect] {
        guard let data = rectsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SubjectRect].self, from: data)) ?? []
    }

    /// The scene tag the analyzer records for footage featuring this subject.
    var tag: String { "vip:\(name)" }

    var colorName: String { SubjectPalette.entry(colorIndex).name }

    static func encodeRects(_ rects: [SubjectRect]) -> String {
        (try? JSONEncoder().encode(rects))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

/// Border colors cycled per subject — named so prompts can say "the yellow
/// box", with RGB components usable from both SwiftUI and CoreGraphics.
nonisolated enum SubjectPalette {
    static let entries: [(name: String, red: Double, green: Double, blue: Double)] = [
        ("yellow", 1.00, 0.84, 0.04),
        ("red",    1.00, 0.27, 0.23),
        ("green",  0.20, 0.84, 0.29),
        ("blue",   0.10, 0.52, 1.00),
        ("orange", 1.00, 0.58, 0.00),
        ("purple", 0.75, 0.35, 0.95),
        ("cyan",   0.35, 0.82, 0.98),
        ("pink",   1.00, 0.35, 0.62),
    ]

    static func entry(_ index: Int) -> (name: String, red: Double, green: Double, blue: Double) {
        entries[((index % entries.count) + entries.count) % entries.count]
    }
}

nonisolated struct SceneRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var runID: Int64?
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
    var rationale: String?
    var batchID: String?

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

/// Structured review of one generated video: whole-video verdict plus
/// per-dimension thumbs ("hook"/"pacing"/"music"/"scenes" → 1 or -1).
nonisolated struct GenerationReview: Sendable, Hashable {
    var generatedVideoID: Int64
    var verdict: Int              // 1 liked, -1 disliked, 0 unset
    var dimensions: [String: Int]
    var note: String
    var createdAt: String?

    static let dimensionKeys = ["hook", "pacing", "music", "scenes"]
}

nonisolated struct ClipReview: Sendable, Hashable {
    var clipIndex: Int
    var sceneID: Int64?
    var verdict: Int              // 1 or -1
    var reasons: [String]

    static let negativeReasons = ["wrong scene", "too long", "too short",
                                  "bad transition", "text overlay off", "wrong position"]
}

/// A review joined with its video's name and plan rationale — what the
/// wizard prompt and the lessons distiller consume.
nonisolated struct ReviewSummary: Sendable {
    var review: GenerationReview
    var clips: [ClipReview]
    var videoFilename: String
    var rationale: String?
    var videoDeleted: Bool
}

/// One A/B choice between two variations of the same wizard run.
nonisolated struct PreferenceRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var chosenRationale: String
    var rejectedRationale: String
    var createdAt: String?
}

/// A distilled style rule the wizard applies to every future generation.
/// Pinned lessons are user-authored hard constraints; unpinned ones are
/// machine-distilled and replaced by the next distillation pass.
nonisolated struct WizardLesson: Identifiable, Sendable, Hashable {
    var id: Int64
    var text: String
    var pinned: Bool
    var evidence: String
}

/// Variations from one wizard run, presented side by side for an A/B pick.
nonisolated struct ComparisonBatch: Identifiable, Sendable, Hashable {
    var id: String                // the shared batch_id
    var videos: [GeneratedVideoRecord]
}

/// One clip of a generated video's timeline resolved for the review panel:
/// which source footage played at that position.
nonisolated struct ReviewableClip: Identifiable, Sendable, Hashable {
    var index: Int
    var sceneID: Int64?
    var videoFile: String
    var start: Double
    var end: Double

    var id: Int { index }
    var duration: Double { end - start }
    var url: URL { URL(fileURLWithPath: videoFile) }
}

extension GeneratedVideoRecord {
    /// Clips from either stored timeline format: the wizard's flat array
    /// ([{"type": "clip", ...}]) or the Builder's TimelineDocument object.
    var reviewableClips: [ReviewableClip] {
        guard let data = timelineJSON.data(using: .utf8) else { return [] }
        if let flat = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return flat.filter { $0["type"] as? String == "clip" }.enumerated().map { index, clip in
                ReviewableClip(index: index,
                               sceneID: (clip["id"] as? NSNumber)?.int64Value,
                               videoFile: clip["video_file"] as? String ?? "",
                               start: (clip["start"] as? NSNumber)?.doubleValue ?? 0,
                               end: (clip["end"] as? NSNumber)?.doubleValue ?? 0)
            }
        }
        guard let document = try? JSONDecoder().decode(TimelineDocument.self, from: data) else { return [] }
        return document.videoTrack.sorted { $0.startTime < $1.startTime }.enumerated().map { index, clip in
            ReviewableClip(index: index,
                           sceneID: clip.sceneID,
                           videoFile: clip.videoFile ?? "",
                           start: clip.sourceStart ?? 0,
                           end: clip.sourceEnd ?? (clip.sourceStart ?? 0) + clip.duration)
        }
    }
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
