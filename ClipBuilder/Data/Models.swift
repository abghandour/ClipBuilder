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
    /// When the people-only pass last ran — the gate tag detection requires.
    var peopleDetectedAt: String?

    var url: URL { URL(fileURLWithPath: path) }
}

/// A distinct person the analyzer detected across the profile's footage.
/// Identity is the AI-assigned `key` (matched visually across videos via the
/// descriptor); the user gives them a real name in the People section.
nonisolated struct PersonRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var key: String
    var name: String
    var descriptor: String

    /// The scene tag the analyzer records for footage featuring this person.
    var tag: String { "person:\(key)" }

    var displayName: String { name.isEmpty ? "Unnamed person" : name }
}

/// A person first detected during the current analysis run — queued for the
/// end-of-run review sheet where the user names them or folds them into an
/// existing identity.
nonisolated struct DetectedNewPerson: Identifiable, Sendable, Hashable {
    var key: String
    var descriptor: String
    /// Name the analyzer lifted from the video filename, offered as a pre-fill.
    var suggestedName: String?
    var videoURL: URL
    var videoFilename: String
    /// Midpoint of the person's first visible range — the review sheet's frame.
    var sampleTime: Double

    var id: String { key }
}

/// Payload for the end-of-analysis people review sheet: everyone the run
/// detected that wasn't already in the registry.
nonisolated struct PeopleReviewRequest: Identifiable, Sendable {
    let id = UUID()
    var people: [DetectedNewPerson]
}

/// The result the analyzer extracted from a video: who beat whom, how, and
/// (when visible) at which event. Drives the wizard's result headlines and
/// captions for fight-recap reels.
nonisolated struct FightOutcome: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var runID: Int64
    /// "ko", "tko", "submission", "decision", "draw", "no-contest".
    var method: String
    /// Person keys from the registry; nil when the analyzer couldn't tell.
    var winnerKey: String?
    var loserKey: String?
    /// Event name if visible in broadcast graphics (e.g. "UFC 330").
    var event: String?
}

/// A user note anchored at a timestamp in a source video — injected into
/// that video's analysis prompt as highest-priority guidance.
nonisolated struct VideoNote: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var atTime: Double
    var note: String
}

/// A user-drawn box identifying one person at one moment of a video —
/// ground truth handed to the analyzer so people recognition stops guessing.
/// Coordinates are normalized (0–1) in display space, top-left origin.
/// One person the people-only pass found in a specific video, with the
/// portrait box its roster avatar is cropped from.
nonisolated struct VideoPersonRecord: Identifiable, Sendable, Hashable {
    var videoID: Int64
    var personID: Int64
    var key: String
    var name: String
    var descriptor: String
    var portraitAt: Double
    var portraitBox: PortraitBox?

    var id: Int64 { personID }
    var displayName: String { name.isEmpty ? key : name }

    /// Normalized top-left box around the person at `portraitAt`.
    nonisolated struct PortraitBox: Codable, Sendable, Hashable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }
}

/// A user-framed Center Stage keyframe: "at this moment, frame it exactly
/// here." Normalized top-left display coordinates; a hard hint the camera
/// path passes through, overriding tracking around its timestamp.
nonisolated struct CameraHint: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var atTime: Double
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

nonisolated struct PersonMarker: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var atTime: Double
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// nil until the user picks who the box marks.
    var personID: Int64?
    /// The boxed person must be EXCLUDED for the whole video: never framed
    /// by Center Stage and never registered/tagged by the analyzer.
    var ignored = false
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

nonisolated struct SceneRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var videoID: Int64
    var runID: Int64?
    /// Effective range: curation edits already substituted in.
    var startTime: Double
    var endTime: Double
    /// The range analysis originally detected — the editor's reset target.
    var originalStart: Double = 0
    var originalEnd: Double = 0
    /// Promoted to the Curated set (the wizard can be told to use only these).
    var curated: Bool = false
    /// The analyzer's beat-by-beat story of the sequence.
    var narrative: String?
    /// Entertainment score 0–10 (escalation-aware, audio-excitement boosted).
    var score: Double?
    /// Crowd-loudness excitement 0–1 measured from the source audio.
    var excitement: Double?
    /// Set on breakdown actions: the sequence scene they were cut from.
    var parentSceneID: Int64?
    var excluded: Bool
    var ignored: Bool
    var favorite: Bool
    var cropXFrac: Double?
    var freeCropsJSON: String?
    var centerStagePathJSON: String?
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

    /// Decoded Center Stage camera path recorded during analysis; nil when
    /// the scene wasn't tracked (or tracked poorly).
    var centerStagePath: SceneCameraPath? {
        guard let data = centerStagePathJSON?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SceneCameraPath.self, from: data)
    }
}

/// One Center Stage camera keyframe: the crop rect normalized to the source
/// frame (top-left origin), at a time relative to the scene start.
nonisolated struct CameraPathKeyframe: Codable, Sendable, Hashable {
    var t: Double
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// A scene's stored Center Stage camera path, with the camera preset it was
/// computed with — a render only reuses it when the presets match.
nonisolated struct SceneCameraPath: Codable, Sendable, Hashable {
    var camera: String
    var keyframes: [CameraPathKeyframe]
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
    /// Playback speed (0.5 = slow-motion replay); screen time stretches.
    var speed: Double = 1

    var id: Int { index }
    var duration: Double { (end - start) / speed }
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
                           end: clip.sourceEnd ?? (clip.sourceStart ?? 0) + clip.sourceSpan,
                           speed: clip.effectiveSpeed)
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
