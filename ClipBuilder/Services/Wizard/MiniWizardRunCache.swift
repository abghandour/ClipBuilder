import Foundation

/// Pure retention rules for the current Express source. Length only affects Highlights.
nonisolated enum MiniWizardRunCache {
    static func retain(_ runs: inout [MiniWizardFlow.FootageKind: MiniWizardRun],
                       projectID: Int64, videoID: Int64, length: MiniWizardFlow.Length) {
        runs = runs.filter { kind, run in
            run.projectID == projectID && run.video.id == videoID
                && (kind != .highlights || run.length == length)
        }
    }

    static func invalidateTranscripts(_ runs: inout [MiniWizardFlow.FootageKind: MiniWizardRun],
                                      videoIDs: Set<Int64>) {
        for kind in [MiniWizardFlow.FootageKind.qa, .transcript] {
            if let run = runs[kind], videoIDs.contains(run.video.id) { runs[kind] = nil }
        }
    }
}
