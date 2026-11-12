import Foundation

/// One passage the user picked from a transcript in AI Wizard Express. Stored
/// per video; its scene is created only when the picks become selections.
nonisolated struct TranscriptPick: Identifiable, Sendable, Equatable {
    var id: Int64
    var videoID: Int64
    var position: Int
    var start: Double
    var end: Double
    var originalStart: Double
    var originalEnd: Double
    var sceneID: Int64?
    /// Owning project; nil for a legacy pick no project has adopted yet.
    var projectID: Int64? = nil
    /// Unchecked picks stay in the list but are left out of the footage.
    var kept: Bool = true

    var range: ClosedRange<Double> { start...max(start, end) }
    var originalRange: ClosedRange<Double> { originalStart...max(originalStart, originalEnd) }
}

/// The transcript review stays available after its picks become selections.
nonisolated struct MiniWizardTranscript: Sendable {
    var rows: [TranscriptRow]
    var labels: [Int64: String]
    var picks: [TranscriptPick]
    var speakerSpans: [TranscriptQATrim.SpeakerSpan] = []
    /// The transcript set `rows` and `picks` were read from.
    var setKey: String? = nil
}
