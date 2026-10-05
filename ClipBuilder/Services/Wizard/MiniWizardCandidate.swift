import Foundation

nonisolated struct MiniWizardCandidate: Identifiable, Sendable {
    var selection: WizardSelectionRecord
    var take: WizardSelectionTake {
        didSet {
            if take.id != oldValue.id { suggestedPlan = take.plan }
        }
    }
    /// Review-session reset target, preserved when a trim overwrites the take's plan.
    var suggestedPlan: WizardPlan
    var kept = true
    var note = ""

    init(selection: WizardSelectionRecord, take: WizardSelectionTake, kept: Bool = true, note: String = "") {
        self.selection = selection
        self.take = take
        self.suggestedPlan = take.plan
        self.kept = kept
        self.note = note
    }

    var id: Int64 { selection.id }
}
