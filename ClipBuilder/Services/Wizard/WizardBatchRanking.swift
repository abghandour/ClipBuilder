import Foundation

nonisolated enum WizardBatchRanking {
    /// Unscored versions cannot win; ties go to the newest render (ID breaks
    /// same-second timestamps). Never rank unrelated batches together.
    static func best(in videos: [GeneratedVideoRecord], batchID: String) -> GeneratedVideoRecord? {
        videos.filter { $0.batchID == batchID && $0.critique != nil }.max {
            let left = $0.critique?.score ?? -1, right = $1.critique?.score ?? -1
            if left != right { return left < right }
            if $0.generatedAt != $1.generatedAt { return ($0.generatedAt ?? "") < ($1.generatedAt ?? "") }
            return $0.id < $1.id
        }
    }

    static func discards(in videos: [GeneratedVideoRecord], keeping best: GeneratedVideoRecord) -> [GeneratedVideoRecord] {
        guard let batch = best.batchID, self.best(in: videos, batchID: batch)?.id == best.id else { return [] }
        return videos.filter { $0.batchID == batch && $0.id != best.id }
    }
}
