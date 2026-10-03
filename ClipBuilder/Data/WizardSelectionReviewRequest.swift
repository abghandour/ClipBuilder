import Foundation

nonisolated struct WizardSelectionSummary: Identifiable, Sendable {
    var selection: WizardSelectionRecord
    var takes: [WizardSelectionTake]
    var id: Int64 { selection.id }
    var bestTake: WizardSelectionTake? {
        takes.first { $0.id == selection.bestTakeID } ?? takes.last
    }
}

nonisolated struct WizardSelectionReviewRequest: Identifiable, Sendable {
    let id = UUID()
    var selection: WizardSelectionRecord
    var takes: [WizardSelectionTake]
    var selectedTakeID: Int64
    var scenes: [SceneRecord]
    var options: WizardOptions
}
