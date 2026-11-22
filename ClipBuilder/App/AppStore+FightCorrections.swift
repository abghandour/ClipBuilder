import Foundation

extension AppStore {
    func correctFightEvent(_ event: FightEventRecord, replacement: FightEventRecord) async throws {
        try await saveFightReview(FightCorrectionRecord(event: event, kind: .edit, replacement: replacement))
    }

    func removeFightEvent(_ event: FightEventRecord) async throws {
        try await saveFightReview(FightCorrectionRecord(event: event, kind: .remove))
    }

    func addFightEvent(_ event: FightEventRecord) async throws {
        try await saveFightReview(FightCorrectionRecord(event: event, kind: .add))
    }

    func confirmFightEvent(_ event: FightEventRecord) async throws {
        try await saveFightReview(FightCorrectionRecord(event: event, kind: .confirm))
    }

    func undoFightCorrection(_ correction: FightCorrectionRecord) async throws {
        try await changeFightReview(videoID: correction.videoID) { database in
            try await database.deleteFightCorrection(id: correction.id, videoID: correction.videoID)
        }
    }

    private func saveFightReview(_ correction: FightCorrectionRecord) async throws {
        try await changeFightReview(videoID: correction.videoID) { database in
            _ = try await database.saveFightCorrection(correction)
        }
    }

    private func changeFightReview(videoID: Int64, operation: (Database) async throws -> Void) async throws {
        do {
            guard let database else { throw AIError.notConfigured("No profile database is open.") }
            guard !fightScoringInFlight.contains(videoID) else {
                throw AIError.notConfigured("Wait for fight scoring or strike marking to finish before correcting an action.")
            }
            let profile = profileGeneration
            try await operation(database)
            let events = try await database.fetchFightEvents(videoID: videoID)
            guard profile == profileGeneration, self.database === database else { return }
            // The property observer also bumps strikeHighlightRevision.
            fightEvents[videoID] = events
        } catch {
            ErrorLog.record("Fight Action correction", error.localizedDescription)
            throw error
        }
    }
}
