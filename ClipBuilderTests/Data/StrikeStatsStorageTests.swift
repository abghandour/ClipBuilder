import Foundation
import Testing
@testable import Clip_Builder

@Suite("Strike stats storage")
struct StrikeStatsStorageTests {
    @Test func oldDatabaseMigratesOptionalEventColumns() async throws {
        let directory = try TempDirectory(prefix: "StrikeStatsMigration")
        let path = directory.url.appendingPathComponent("old.db")
        let raw = try SQLiteConnection(path: path.path)
        try raw.executeScript("""
            CREATE TABLE fight_events (
                id INTEGER PRIMARY KEY, video_id INTEGER NOT NULL, at_time REAL NOT NULL,
                fighter_key TEXT NOT NULL DEFAULT '', action TEXT NOT NULL, points REAL NOT NULL,
                provider TEXT, model TEXT
            );
            INSERT INTO fight_events VALUES (1, 1, 4, 'a', 'takedown', 4, NULL, NULL);
            PRAGMA user_version = 30;
            """)
        let migrated = try Database(path: path)
        let columns = try raw.columnNames(of: "fight_events")
        for column in ["target_key", "end_time", "outcome", "detail", "scoring_version", "generation"] {
            #expect(columns.contains(column))
        }
        let old = try #require(try await migrated.fetchFightEvents().first)
        #expect(old.points == 4 && old.scoringVersion == nil && old.generation == nil && old.endTime == nil)
    }

    @Test func staleGenerationIsDiscardedIncludingEmptyReplacement() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let old = try await temp.database.fightEventGeneration(videoID: videoID)
        let row = FightEventRecord(id: 0, videoID: videoID, time: 1, fighterKey: "a", action: "strike", points: 1)
        #expect(try await temp.database.replaceFightEventRecords(videoID: videoID, events: [row], expectedGeneration: old))
        #expect(try await !temp.database.replaceFightEventRecords(videoID: videoID, events: [], expectedGeneration: old))
        #expect(try await temp.database.fetchFightEvents().count == 1)
        let first = try await temp.database.fightEventGeneration(videoID: videoID)
        #expect(try await temp.database.fetchFightEvents().first?.generation == first)
        #expect(try await temp.database.replaceFightEventRecords(videoID: videoID, events: [], expectedGeneration: first))
        #expect(try await !temp.database.isFightEventGenerationCurrent(videoID: videoID, generation: first))
    }

    @Test func passStatesAndCoverageUseSavedPassesEvenWithoutResults() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        for status in AnalysisPassRecord.Status.allCases {
            let pass = try await temp.database.startAnalysisPass(videoID: videoID, pass: .fightScore, version: 2)
            try await temp.database.finishAnalysisPass(pass, status: status)
            let rows = try await temp.database.fetchAnalysisPasses()
            #expect(rows.last?.status == status)
            #expect((rows.last?.completedAt == nil) == (status == .running))
            let copy = AnalysisCoverage.fightMessage(videoID: videoID, passes: rows, legacyEvents: [])
            #expect(status == .completed ? copy.contains("scored v2") : copy.contains(status.rawValue))
        }
        let pose = try await temp.database.startAnalysisPass(videoID: videoID, pass: .strikePose, version: 1)
        try await temp.database.finishAnalysisPass(pose, status: .completed)
        let copy = AnalysisCoverage.fightMessage(videoID: videoID, passes: try await temp.database.fetchAnalysisPasses(), legacyEvents: [])
        #expect(copy.contains("scored v2") && copy.contains("pose v1"))
        #expect(try await temp.database.fetchFightEvents().isEmpty)
        let legacy = FightEventRecord(id: 1, videoID: videoID, time: 0, fighterKey: "a", action: "takedown", points: 4)
        #expect(AnalysisCoverage.fightMessage(videoID: videoID, passes: [], legacyEvents: [legacy]) == "scored v1 (no attempts)")
    }

    @Test func syncOldPayloadStampsGenerationWithoutClearingOtherData() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await temp.database.bindSync(to: scope)
        let raw = try SQLiteConnection(path: temp.path.path)
        let videoSyncID = try #require(try raw.query("SELECT sync_id FROM videos WHERE id = ?", [.integer(videoID)]).first?["sync_id"]?.stringValue)
        let table = try SyncTable.named("fight_events")
        let syncID = UUID().uuidString.lowercased()
        var wire = try SyncMapping.wire(local: ["video_id": .text(videoSyncID), "at_time": .real(1),
            "fighter_key": .text("a"), "action": .text("submission_attempt"), "points": .real(5)],
            syncID: syncID, scope: scope, table: table)
        for column in ["target_key", "end_time", "outcome", "detail", "scoring_version", "generation"] { wire.removeValue(forKey: column) }
        let sceneCount = try await temp.database.fetchScenes().count
        #expect(try await temp.database.applySyncRows([wire], scope: scope, table: table, advanceCursor: false))
        let first = try #require(try await temp.database.fetchFightEvents().first)
        #expect(first.generation != nil && first.scoringVersion == nil && first.points == 5)
        wire["points"] = .number(6)
        _ = try await temp.database.applySyncRows([wire], scope: scope, table: table, advanceCursor: false)
        let second = try #require(try await temp.database.fetchFightEvents().first)
        #expect(try #require(second.generation) > #require(first.generation))
        #expect(try await temp.database.fetchScenes().count == sceneCount)
        #expect(try raw.query("SELECT 1 FROM sqlite_master WHERE name = 'strike_metrics'").isEmpty)
        let tombstone = try SyncMapping.wire(local: nil, syncID: syncID, scope: scope, table: table)
        _ = try await temp.database.applySyncRows([tombstone], scope: scope, table: table, advanceCursor: false)
        #expect(try await temp.database.fetchFightEvents().isEmpty)
        #expect(try await temp.database.fightEventGeneration(videoID: videoID) > #require(second.generation))
    }
}
