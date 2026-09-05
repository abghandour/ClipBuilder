import Foundation

nonisolated struct EditProposal: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case silence, filler, falseStart, noise, plannedClip, bRoll, photo
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
