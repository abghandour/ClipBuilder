import Foundation

/// One Wizard run (proxies, final render and variants) owns these per-source
/// snapshots. Access is under FightWorkCoordinator's claim for the same key.
actor WizardStrikeHighlightSnapshot {
    @TaskLocal static var current: WizardStrikeHighlightSnapshot?
    /// Initial marking pass plus two retries, per database/video for this run.
    nonisolated static let incompleteRetryLimit = 2
    private struct Source {
        var generation: Int64
        var rulesVersion: Int
        var result: StrikeHighlightMarker.Result
    }
    private var sources: [FightWorkCoordinator.Key: Source] = [:]
    private var attempts: [FightWorkCoordinator.Key: Int] = [:]
    private var exhaustedLogged: Set<FightWorkCoordinator.Key> = []
    private var pauseSkipMessages: Set<String> = []

    func shouldLogPauseSkip(_ message: String) -> Bool {
        pauseSkipMessages.insert(message).inserted
    }

    func result(for key: FightWorkCoordinator.Key, generation: Int64) -> StrikeHighlightMarker.Result? {
        guard let source = sources[key], source.generation == generation,
              source.rulesVersion == StrikeHighlightRules.version,
              source.result.complete || attempts[key, default: 0] > Self.incompleteRetryLimit else { return nil }
        return source.result
    }

    func beginAttempt(for key: FightWorkCoordinator.Key) -> Bool {
        guard attempts[key, default: 0] <= Self.incompleteRetryLimit else { return false }
        attempts[key, default: 0] += 1
        return true
    }

    /// Incomplete attempts stay charged across generation changes for this run.
    /// Only a confirmed read has a generation and can supply a cached result.
    func save(_ result: StrikeHighlightMarker.Result, for key: FightWorkCoordinator.Key) -> Bool {
        // A healthy generation must not consume the incomplete-work budget.
        if result.complete { attempts[key, default: 0] = max(0, attempts[key, default: 0] - 1) }
        if let generation = result.generation {
            sources[key] = Source(generation: generation, rulesVersion: StrikeHighlightRules.version, result: result)
        }
        return !result.complete && attempts[key, default: 0] > Self.incompleteRetryLimit
            && exhaustedLogged.insert(key).inserted
    }
}
