import Foundation

/// In-progress Mini review. The selections and takes themselves live in the database.
nonisolated struct MiniWizardRun: Sendable {
    var projectID: Int64
    var video: VideoRecord
    var footageKind: MiniWizardFlow.FootageKind
    var length: MiniWizardFlow.Length
    var batchID: String
    var candidates: [MiniWizardCandidate]
    var options: WizardOptions
    var requestedCard: MiniWizardFlow.Card = .footage
    var selectedSelectionID: Int64?
    var qa: MiniWizardQA? = nil

    var hasFootage: Bool { footageKind == .qa ? qa != nil : !candidates.isEmpty }
    var keptCount: Int {
        if footageKind == .qa {
            guard let qa else { return 0 }
            return qa.kept.intersection(Set(qa.sections.map(\.id))).count
        }
        return candidates.filter { $0.kept && !$0.take.plan.clips.isEmpty }.count
    }
    var summary: String {
        MiniWizardFlow.footageSummary(kind: footageKind,
            count: footageKind == .qa ? qa?.sections.count ?? 0 : candidates.count, keptCount: keptCount)
    }
}
