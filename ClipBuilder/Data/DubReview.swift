import Foundation

nonisolated struct DubReview: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case builder(timelineID: Int64?, revision: Int)
        case render(UUID)
        /// Reviewed ahead of Generate: saving remembers the voices and the
        /// reworded lines for the render to come, and changes nothing else.
        case beforeRender
    }
    var prepared: DubPreparation.Prepared
    var target: Target
    var profileGeneration: Int
    var initialLineID: UUID? = nil
}
