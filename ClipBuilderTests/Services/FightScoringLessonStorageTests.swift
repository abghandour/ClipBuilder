import Foundation
import Testing
@testable import Clip_Builder

@Suite("Fight scoring lesson storage")
struct FightScoringLessonStorageTests {
    private func seed(_ temp: TempDatabase, count: Int = 5) async throws -> Int64 {
        let videoID = try await temp.seedVideo()
        for index in 0..<count {
            let event = FightEventRecord(id: 0, videoID: videoID, time: Double(index * 2), fighterKey: "a", action: "strike", points: 1)
            _ = try await temp.database.saveFightCorrection(.init(event: event, kind: .add))
        }
        return videoID
    }

    @Test func receiptsAreAtomicLocalAndSurviveReopen() async throws {
        let temp = try await TempDatabase()
        _ = try await seed(temp)
        let snapshot = try await temp.database.fightLearningSnapshot()
        #expect(snapshot.corrections.count == 5)
        #expect(try await temp.database.saveFightScoringLessons(response: #"{"lessons":["Trace the initiating limb."]}"#, snapshot: snapshot) == 1)
        let reopened = try await Task.detached { try Database(path: temp.path) }.value
        let next = try await reopened.fightLearningSnapshot()
        #expect(next.corrections.isEmpty && next.sourceCount == 5 && next.revision == 1)
        #expect(next.lessons.first?.sourceCount == 5)
        #expect(!SyncTable.all.contains { ["fight_scoring_lessons", "fight_correction_learning", "fight_scoring_learning_state"].contains($0.name) })
    }

    @Test func malformedResponseLeavesLessonsAndReceiptsUnchanged() async throws {
        let temp = try await TempDatabase()
        _ = try await seed(temp)
        let snapshot = try await temp.database.fightLearningSnapshot()
        try await temp.database.saveFightScoringLessons(response: #"{"lessons":["Existing rule."]}"#, snapshot: snapshot)
        _ = try await seed(temp)
        let next = try await temp.database.fightLearningSnapshot()
        await #expect(throws: (any Error).self) {
            try await temp.database.saveFightScoringLessons(response: #"{"lessons":["valid",1]}"#, snapshot: next)
        }
        let after = try await temp.database.fightLearningSnapshot()
        #expect(after.lessons == next.lessons && after.corrections == next.corrections && after.revision == next.revision)
    }

    @Test func changedCorrectionBecomesPendingAgainAndRescoreDoesNot() async throws {
        let temp = try await TempDatabase()
        let videoID = try await seed(temp)
        let snapshot = try await temp.database.fightLearningSnapshot()
        try await temp.database.saveFightScoringLessons(response: #"{"lessons":["Existing rule."]}"#, snapshot: snapshot)
        try await temp.database.replaceFightEventRecords(videoID: videoID, events: [])
        #expect(try await temp.database.fightLearningSnapshot().corrections.isEmpty)
        let current = try #require(try await temp.database.fetchFightEvents(videoID: videoID).first)
        var changed = current
        changed.fighterKey = "b"
        _ = try await temp.database.saveFightCorrection(.init(event: current, kind: .edit, replacement: changed))
        #expect(try await temp.database.fightLearningSnapshot().corrections.count == 1)
    }

    @Test func concurrentToggleRejectsStaleLearningAndRetainsDisabledState() async throws {
        let temp = try await TempDatabase()
        _ = try await seed(temp)
        let first = try await temp.database.fightLearningSnapshot()
        try await temp.database.saveFightScoringLessons(response: #"{"lessons":["Existing rule."]}"#, snapshot: first)
        _ = try await seed(temp)
        let stale = try await temp.database.fightLearningSnapshot()
        let lesson = try #require(stale.lessons.first)
        try await temp.database.setFightScoringLessonEnabled(id: lesson.id, enabled: false)
        await #expect(throws: (any Error).self) {
            try await temp.database.saveFightScoringLessons(response: #"{"lessons":["Existing rule."]}"#, snapshot: stale)
        }
        let fresh = try await temp.database.fightLearningSnapshot()
        try await temp.database.saveFightScoringLessons(response: #"{"lessons":["Existing rule.","New rule."]}"#, snapshot: fresh)
        let saved = try await temp.database.fetchFightScoringLessons()
        #expect(saved.first?.id == lesson.id && saved.first?.enabled == false)
        #expect(FightCorrections.enabledLessons(saved) == ["New rule."])
        try await temp.database.deleteFightScoringLesson(id: lesson.id)
        #expect(try await temp.database.fetchFightScoringLessons().count == 1)
        #expect(try await temp.database.fightScoringLessonSourceCount() == 10)
    }

    @Test func concurrentCorrectionEditRejectsStaleLearning() async throws {
        let temp = try await TempDatabase()
        let videoID = try await seed(temp)
        let stale = try await temp.database.fightLearningSnapshot()
        let event = try #require(try await temp.database.fetchFightEvents(videoID: videoID).first)
        var changed = event
        changed.detail = "kick|left|legs|right"
        _ = try await temp.database.saveFightCorrection(.init(event: event, kind: .edit, replacement: changed))
        await #expect(throws: (any Error).self) {
            try await temp.database.saveFightScoringLessons(response: #"{"lessons":["New rule."]}"#, snapshot: stale)
        }
        #expect(try await temp.database.fetchFightScoringLessons().isEmpty)
        #expect(try await temp.database.fightLearningSnapshot().corrections.count == 5)
    }

    @Test func correctionAddedDuringLearningRemainsPending() async throws {
        let temp = try await TempDatabase()
        let videoID = try await seed(temp)
        let snapshot = try await temp.database.fightLearningSnapshot()
        let event = FightEventRecord(id: 0, videoID: videoID, time: 9, fighterKey: "b", action: "strike", points: 1)
        let added = try await temp.database.saveFightCorrection(.init(event: event, kind: .add))
        try await temp.database.saveFightScoringLessons(response: #"{"lessons":["New rule."]}"#, snapshot: snapshot)
        let after = try await temp.database.fightLearningSnapshot()
        #expect(after.corrections.map(\.id) == [added.id])
        #expect(after.sourceCount == 5)
    }

    @Test func failedTransactionRollsBackRulesAndReceipts() async throws {
        let temp = try await TempDatabase()
        _ = try await seed(temp)
        let snapshot = try await temp.database.fightLearningSnapshot()
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.executeScript("""
            CREATE TRIGGER reject_learning BEFORE INSERT ON fight_correction_learning
            BEGIN SELECT RAISE(ABORT, 'test rollback'); END;
            """)
        await #expect(throws: (any Error).self) {
            try await temp.database.saveFightScoringLessons(response: #"{"lessons":["New rule."]}"#, snapshot: snapshot)
        }
        let after = try await temp.database.fightLearningSnapshot()
        #expect(after.lessons.isEmpty && after.corrections.count == 5 && after.sourceCount == 0)
    }

    @Test func anEmptyAnswerKeepsTheSavedLessonsAndTheirEvidence() async throws {
        let temp = try await TempDatabase()
        _ = try await seed(temp)
        let first = try await temp.database.fightLearningSnapshot()
        try await temp.database.saveFightScoringLessons(response: #"{"lessons":["Existing rule."]}"#, snapshot: first)
        _ = try await seed(temp)
        let next = try await temp.database.fightLearningSnapshot()
        await #expect(throws: (any Error).self) {
            try await temp.database.saveFightScoringLessons(response: #"{"lessons":[]}"#, snapshot: next)
        }
        let after = try await temp.database.fightLearningSnapshot()
        #expect(after.lessons == next.lessons && after.corrections == next.corrections && after.revision == next.revision)
    }
}
