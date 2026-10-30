import Foundation

/// Cheap identities for the Sources comparison previews, before any database
/// reads or source fingerprint work.
nonisolated enum AnalysisComparisonMemo {
    struct Key: Hashable, Sendable {
        var videoID: Int64
        var planKey: String
        var videoHash: String
        var transcriptCountsVersion: Int
        var videoPeopleVersion: Int
    }

    static func planKey(_ plan: AnalysisCheckpoint.Plan) -> String {
        // Sorted JSON includes every stored plan field and escapes free text,
        // unlike delimiter-joined fields. Do not normalize away provider/notes.
        AnalysisRequest.json(plan)
    }
}
