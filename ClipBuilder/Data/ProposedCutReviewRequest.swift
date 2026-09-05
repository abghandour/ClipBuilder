import Foundation

/// A validated Wizard plan paused before rendering for per-cut review.
nonisolated struct ProposedCutReviewRequest: Identifiable, Sendable {
    let id = UUID()
    var plan: WizardPlan
    var sceneMap: [Int64: SceneRecord]
    var options: WizardOptions
}
