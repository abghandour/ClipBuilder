import Foundation

nonisolated struct DubReview: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case builder(timelineID: Int64?, revision: Int)
        case render(UUID)
    }
    var prepared: DubPreparation.Prepared
    var target: Target
    var profileGeneration: Int
}
