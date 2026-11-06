import Foundation

/// The transcript review stays available after its kept exchanges become selections.
nonisolated struct MiniWizardQA: Sendable {
    var sections: [TranscriptQASections.Section]
    var rows: [TranscriptRow]
    var labels: [Int64: String]
    var turns: [SpeakerTurn]
    var kept: Set<Int64>
    /// The kept exchanges in output order (qa_picks positions). Kept ids
    /// missing here follow in transcript order.
    var keptOrder: [Int64] = []
    var speakerSpans: [TranscriptQATrim.SpeakerSpan] = []
    /// The exchanges came from a transcript that has since been replaced.
    var fromOlderTranscript = false
}
