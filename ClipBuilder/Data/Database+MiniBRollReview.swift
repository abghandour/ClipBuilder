import Foundation

extension Database {
    /// Picks/Q&A rebuild selections when moving between review and Settings.
    /// Capture the reviewed source-clock cuts before deleting those takes.
    func miniReviewedBRoll(projectID: Int64, miniBatch: String) throws -> [Int64: [BRollCut]] {
        var result: [Int64: [BRollCut]] = [:]
        for selection in try fetchWizardSelections(projectID: projectID, miniBatch: miniBatch) {
            guard let take = try fetchWizardSelectionTakes(selectionID: selection.id).last else { continue }
            for clip in take.plan.clips {
                if let cuts = clip.brollCuts { result[clip.sceneID] = cuts }
            }
        }
        return result
    }
}

extension Database {
    func miniSavedCandidates(projectID: Int64, miniBatch: String) throws -> [MiniWizardCandidate] {
        try fetchWizardSelections(projectID: projectID, miniBatch: miniBatch).compactMap { selection in
            guard let take = try fetchWizardSelectionTakes(selectionID: selection.id).last else { return nil }
            return MiniWizardCandidate(selection: selection, take: take)
        }
    }

    /// Pick identity survives relaunch, reordering, and repeated identical source ranges.
    func miniBRollByPick(projectID: Int64, miniBatch: String) throws -> [Int64: [BRollCut]] {
        var result: [Int64: [BRollCut]] = [:]
        for candidate in try miniSavedCandidates(projectID: projectID, miniBatch: miniBatch) {
            for clip in candidate.take.plan.clips {
                if let pickID = clip.miniPickID { result[pickID] = clip.brollCuts ?? [] }
            }
        }
        return result
    }
}
