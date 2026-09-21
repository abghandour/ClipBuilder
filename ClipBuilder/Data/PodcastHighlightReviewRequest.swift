import Foundation

nonisolated struct PodcastHighlightReviewRequest: Identifiable, Sendable {
    var id = UUID()
    var video: VideoRecord
    var candidates: [HighlightCandidate]
    var scenes: [SceneRecord]
    var segments: [TranscriptSegment]
    var turns: [SpeakerTurn]
    var roster: [VideoPersonRecord]
    /// Everyone the profile knows, so footage of someone the reel names counts as in context.
    var people: [PersonRecord] = []
    var options: WizardOptions
    var roles: [AIRole] = []
    var profileGeneration: Int = 0
    var highlightThreshold: Double = 7
}
