import Foundation

nonisolated enum AnalysisDuplicates {
    static func successfulRuns(videoID: Int64, runs: [AnalysisRun], passes: [AnalysisPassRecord]) -> [AnalysisRun] {
        runs.filter { run in
            guard run.videoID == videoID else { return false }
            let rows = passes.filter { $0.videoID == videoID && $0.runKey == run.runKey && $0.pass == .scenes }
            return rows.isEmpty ? run.sceneCount > 0 : rows.contains { $0.status == .completed }
        }.sorted {
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            return ($0.runKey ?? "") > ($1.runKey ?? "")
        }
    }

    static func duplicate(videoID: Int64, request: AnalysisRequest, runs: [AnalysisRun], passes: [AnalysisPassRecord]) -> AnalysisRun? {
        successfulRuns(videoID: videoID, runs: runs, passes: passes).first { $0.requestHash == request.fingerprint }
    }

    /// Receipts take precedence over output counts: empty success is complete,
    /// and failed/cancelled attempts do not become success from leftover rows.
    static func missingPasses(request: AnalysisRequest, run: AnalysisRun, passes: [AnalysisPassRecord],
                              qaCount: Int = 0, peopleCount: Int = 0, hasTranscript: Bool = false) -> [String] {
        request.requestedPasses.filter { name in
            if name == "scenes" { return false }
            let rows = passes.filter {
                $0.videoID == run.videoID && $0.pass.rawValue == name && ($0.runKey == run.runKey || $0.runKey == nil)
            }
            if let last = rows.last { return last.status != .completed || last.version < (request.passVersions[name] ?? 1) }
            switch name {
            case "exchanges": return qaCount == 0
            case "people": return peopleCount == 0
            case "transcript": return !hasTranscript
            default: return true
            }
        }.sorted()
    }
}
