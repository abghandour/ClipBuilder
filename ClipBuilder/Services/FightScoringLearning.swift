import Foundation

/// The retry's optional final step. Its failure is recorded, never propagated
/// to the already committed scoring pass.
nonisolated enum FightScoringLearning {
    @concurrent
    static func update(database: Database, ai: AIService, log: @escaping @Sendable (String) -> Void) async -> Int? {
        do {
            try Task.checkCancellation()
            let snapshot = try await database.fightLearningSnapshot()
            guard snapshot.corrections.count >= FightCorrections.learningThreshold else { return nil }
            log("Learning fight scoring rules from \(snapshot.corrections.count) corrections…")
            let prompt = FightCorrections.lessonsPrompt(corrections: snapshot.corrections, roster: snapshot.roster, existing: snapshot.lessons)
            let response = try await ai.call(prompt: prompt, task: .fightLessons, frames: nil, log: log)
            try Task.checkCancellation()
            return try await database.saveFightScoringLessons(response: response.text, snapshot: snapshot)
        } catch {
            ErrorLog.record("Fight scoring lessons", error.localizedDescription)
            log("Fight scoring lessons were not updated: \(error.localizedDescription). The retry result is kept.")
            return nil
        }
    }
}
