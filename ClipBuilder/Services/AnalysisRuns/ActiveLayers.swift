import Foundation

/// Automatic choices are derived locally. Only a manual pin is persisted.
nonisolated enum ActiveLayers {
    struct Resolution: Sendable {
        var run: AnalysisRun?
        var isPinned: Bool
        var missingPin: Bool
        var reason: String { isPinned ? "pinned" : "newest" }
    }

    struct TranscriptionResolution: Sendable {
        var set: TranscriptionSet?
        var isPinned: Bool
        var missingPin: Bool
        var key: String? { self.set?.id }
        var createdAt: String? { self.set?.createdAt }
        var reason: String { isPinned ? "pinned" : "newest" }
    }

    static func resolveTranscription(pinnedKey: String?, sets: [TranscriptionSet]) -> TranscriptionResolution {
        if let pinnedKey, let set = sets.first(where: { $0.id == pinnedKey }) {
            return TranscriptionResolution(set: set, isPinned: true, missingPin: false)
        }
        let newest = sets.max {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
        return TranscriptionResolution(set: newest, isPinned: false, missingPin: pinnedKey != nil)
    }

    static func isCompleted(_ run: AnalysisRun, passes: [AnalysisPassRecord]) -> Bool {
        let rows = passes.filter { $0.videoID == run.videoID && $0.pass == .scenes && $0.runKey == run.runKey }
        // Pre-pass-table batches remain eligible. A checkpoint is independent.
        return rows.isEmpty || rows.contains { $0.status == .completed }
    }

    static func resolve(videoID: Int64, pinnedRunKey: String?, runs: [AnalysisRun],
                        passes: [AnalysisPassRecord]) -> Resolution {
        let candidates = runs.filter { $0.videoID == videoID }
        if let pinnedRunKey, let pinned = candidates.first(where: { $0.runKey == pinnedRunKey }) {
            return Resolution(run: pinned, isPinned: true, missingPin: false)
        }
        let newest = candidates.filter { isCompleted($0, passes: passes) }.max {
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? "") < ($1.createdAt ?? "") }
            return ($0.runKey ?? "") < ($1.runKey ?? "")
        }
        return Resolution(run: newest, isPinned: false, missingPin: pinnedRunKey != nil)
    }
}
