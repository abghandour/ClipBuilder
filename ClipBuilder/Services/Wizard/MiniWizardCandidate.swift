import Foundation

nonisolated struct MiniWizardCandidate: Identifiable, Sendable {
    var selection: WizardSelectionRecord
    var take: WizardSelectionTake
    var kept = true
    var note = ""

    var id: Int64 { selection.id }
}
