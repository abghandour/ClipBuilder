import Foundation

nonisolated struct AnalysisDuplicatePrompt: Identifiable {
    let id = UUID()
    var video: VideoRecord
    var request: AnalysisRequest
    var run: AnalysisRun
    var missingPasses: [String]
}

nonisolated enum AnalysisDuplicatePolicy {
    case ask, runAnyway, missingOnly
}
