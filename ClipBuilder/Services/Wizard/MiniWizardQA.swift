import Foundation

/// The transcript review stays available after its kept exchanges become selections.
nonisolated struct MiniWizardQA: Sendable {
    var sections: [TranscriptQASections.Section]
    var rows: [TranscriptRow]
    var labels: [Int64: String]
    var turns: [SpeakerTurn]
    var kept: Set<Int64>
}
