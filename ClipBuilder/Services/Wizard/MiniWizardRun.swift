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
    var transcript: MiniWizardTranscript? = nil
    var fight: MiniWizardFight? = nil

    var hasFootage: Bool {
        switch footageKind {
        case .qa: qa != nil
        case .transcript: transcript != nil
        case .fightMetrics: fight != nil
        case .highlights: !candidates.isEmpty
        }
    }
    var keptCount: Int {
        switch footageKind {
        case .qa:
            guard let qa else { return 0 }
            return qa.kept.intersection(Set(qa.sections.map(\.id))).count
        case .transcript:
            return transcript?.picks.count ?? 0
        case .fightMetrics:
            return fight?.picks.count ?? 0
        case .highlights:
            return candidates.filter { $0.kept && !$0.take.plan.clips.isEmpty }.count
        }
    }
    var summary: String {
        let count = switch footageKind {
        case .qa: qa?.sections.count ?? 0
        case .transcript: transcript?.picks.count ?? 0
        case .fightMetrics: fight?.picks.count ?? 0
        case .highlights: candidates.count
        }
        return MiniWizardFlow.footageSummary(kind: footageKind, count: count, keptCount: keptCount)
    }
}
