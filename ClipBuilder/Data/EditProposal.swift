import Foundation

nonisolated struct EditProposal: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case silence, filler, falseStart, noise, plannedClip, bRoll, photo
        /// A word said twice in a row (stutter); the first goes.
        case repeatWord
        /// An earlier take of a line said again shortly after.
        case retake

        /// The kinds transcript analysis proposes as cuts (the rest mark
        /// footage to keep or add).
        static let cleanupCuts: [Kind] = [.silence, .filler, .falseStart, .noise, .repeatWord, .retake]

        var isCleanupCut: Bool { Self.cleanupCuts.contains(self) }

        var label: String {
            switch self {
            case .silence: "Silence"
            case .filler: "Filler word"
            case .falseStart: "False start"
            case .noise: "Noise"
            case .plannedClip: "Planned clip"
            case .bRoll: "B-roll"
            case .photo: "Photo"
            case .repeatWord: "Repeated word"
            case .retake: "Retake"
            }
        }
    }

    enum Decision: String, Codable, CaseIterable, Sendable {
        case pending, accepted, rejected
    }

    var id: Int64
    var videoID: Int64?
    var kind: Kind
    var startTime: Double
    var endTime: Double
    var reason: String
    var decision: Decision

    var duration: Double { endTime - startTime }
}
