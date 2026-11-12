import Foundation
import Testing
@testable import Clip_Builder

@Suite("Transcript picks per transcript set")
struct TranscriptPickSetTests {
    private func video(in temp: TempDatabase) async throws -> Int64 {
        let url = temp.path.deletingLastPathComponent().appendingPathComponent("sets.mp4")
        try Data("fixture".utf8).write(to: url)
        return try await temp.database.registerVideo(hash: UUID().uuidString, filename: "sets.mp4", path: url.path,
                                                     duration: 60, width: 1920, height: 1080, wide: true)
    }

    private func transcribe(_ database: Database, videoID: Int64, key: String) async throws {
        _ = try await database.replaceTranscripts(videoID: videoID, transcriptionKey: key, language: "en", isTranslation: false,
            segments: [TranscriptSegment(start: 0, end: 3, text: "One two three", words: nil)], provider: "test", model: key)
    }

    @Test("A pick shows only under the set it was made on; older unstamped picks stay with the set that was active")
    func picksFollowTheSet() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await video(in: temp)
        let projectID = try await database.createProject(profileName: "Test", name: "Sets", videoIDs: [videoID])
        try await transcribe(database, videoID: videoID, key: "a")
        try await transcribe(database, videoID: videoID, key: "b")
        try await database.setActiveTranscriptionKey(videoID: videoID, key: "a")
        let onA = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 0, end: 1)
        // A pick from an older app or Team Sync carries no set.
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("""
            INSERT INTO transcript_picks (video_id, project_id, position, start_time, end_time, original_start, original_end, kept)
            VALUES (?, ?, 9, 1, 2, 1, 2, 1)
            """, [.integer(videoID), .integer(projectID)])
        #expect(try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).count == 2)

        #expect(try await database.switchTranscriptionSet(videoID: videoID, key: "b") == "a")
        #expect(try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).isEmpty)
        let onB = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 2, end: 3)
        try await database.deleteTranscriptPicks(projectID: projectID, videoID: videoID)
        #expect(try await database.transcriptPick(id: onB.id) == nil)
        #expect(try await database.transcriptPick(id: onA.id) != nil, "clearing one set's list leaves the other's")

        _ = try await database.switchTranscriptionSet(videoID: videoID, key: "a")
        #expect(try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).count == 2)

        // A screen still showing set b must not write into set a's list.
        await #expect(throws: TranscriptPickSetError.self) {
            try await database.deleteTranscriptPicks(projectID: projectID, videoID: videoID, set: .shown("b"))
        }
        await #expect(throws: TranscriptPickSetError.self) {
            _ = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 4, end: 5, set: .shown("b"))
        }
        await #expect(throws: TranscriptPickSetError.self) {
            _ = try await database.restoreTranscriptPicks(projectID: projectID, videoID: videoID, expected: [], picks: [],
                                                          set: .shown("b"))
        }
        #expect(try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).count == 2)
    }

    @Test("A new transcription claims unstamped picks for the set that was active before it")
    func aNewSetDoesNotTakeOlderPicks() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await video(in: temp)
        let projectID = try await database.createProject(profileName: "Test", name: "Sets", videoIDs: [videoID])
        try await transcribe(database, videoID: videoID, key: "a")
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("""
            INSERT INTO transcript_picks (video_id, project_id, position, start_time, end_time, original_start, original_end, kept)
            VALUES (?, ?, 0, 1, 2, 1, 2, 1)
            """, [.integer(videoID), .integer(projectID)])
        // Unpinned: the newer set becomes active by itself, as after a re-transcription.
        try await Task.sleep(for: .milliseconds(20))
        try await transcribe(database, videoID: videoID, key: "b")
        try await database.setActiveTranscriptionKey(videoID: videoID, key: nil)
        #expect(try await database.activeTranscription(videoID: videoID).key == "b")
        #expect(try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).isEmpty)
        try await database.setActiveTranscriptionKey(videoID: videoID, key: "a")
        #expect(try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).count == 1)
    }

    @Test("Picks of a deleted set come back into view")
    func picksOfADeletedSetReturn() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await video(in: temp)
        let projectID = try await database.createProject(profileName: "Test", name: "Sets", videoIDs: [videoID])
        try await transcribe(database, videoID: videoID, key: "a")
        try await transcribe(database, videoID: videoID, key: "b")
        try await database.setActiveTranscriptionKey(videoID: videoID, key: "a")
        _ = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 0, end: 1)
        try await database.setActiveTranscriptionKey(videoID: videoID, key: "b")
        #expect(try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).isEmpty)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("DELETE FROM transcripts WHERE video_id = ? AND transcription_key = 'a'", [.integer(videoID)])
        #expect(try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).count == 1)
    }

    @Test("A split writes both halves or neither")
    func aSplitIsAllOrNothing() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await video(in: temp)
        let projectID = try await database.createProject(profileName: "Test", name: "Split", videoIDs: [videoID])
        try await transcribe(database, videoID: videoID, key: "a")
        try await transcribe(database, videoID: videoID, key: "b")
        try await database.setActiveTranscriptionKey(videoID: videoID, key: "a")
        let first = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 10, end: 20)
        let last = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 30, end: 40)

        // The page still shows set b: nothing is written, not even the first half.
        await #expect(throws: TranscriptPickSetError.self) {
            _ = try await database.splitTranscriptPick(projectID: projectID, videoID: videoID, id: first.id, start: 10,
                at: 15, end: 20, kept: true, order: [first.id, last.id], index: 1, set: .shown("b"))
        }
        #expect(try await database.transcriptPick(id: first.id)?.end == 20)

        let added = try await database.splitTranscriptPick(projectID: projectID, videoID: videoID, id: first.id, start: 10,
            at: 15, end: 20, kept: true, order: [first.id, last.id], index: 1, set: .shown("a"))
        let picks = try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID)
        #expect(picks.map(\.id) == [first.id, added.id, last.id])
        #expect(picks.map(\.end) == [15, 20, 40])
        // The new half belongs to set a, like the pick it came from.
        _ = try await database.switchTranscriptionSet(videoID: videoID, key: "b")
        #expect(try await database.fetchTranscriptPicks(projectID: projectID, videoID: videoID).isEmpty)
    }

    @Test("Schema 51 moves the unreleased side table's links into the synced column and queues them")
    func theSideTableMovesIntoTheColumn() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await video(in: temp)
        let projectID = try await database.createProject(profileName: "Test", name: "Upgrade", videoIDs: [videoID])
        try await transcribe(database, videoID: videoID, key: "a")
        let stamped = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 0, end: 1)
        let plain = try await database.addTranscriptPick(projectID: projectID, videoID: videoID, start: 1, end: 2)

        // The library as a build before schema 51 left it, attached to a team.
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE transcript_picks SET transcription_key = NULL")
        try raw.execute("ALTER TABLE transcript_picks DROP COLUMN transcription_key")
        try raw.execute("""
            CREATE TABLE transcript_pick_sets (
                pick_id INTEGER PRIMARY KEY REFERENCES transcript_picks(id) ON DELETE CASCADE,
                transcription_key TEXT NOT NULL)
            """)
        try raw.execute("INSERT INTO transcript_pick_sets VALUES (?, 'a')", [.integer(stamped.id)])
        try raw.execute("INSERT INTO sync_binding VALUES (1, ?, ?)", [.text(UUID().uuidString), .text(UUID().uuidString)])
        try raw.execute("DELETE FROM sync_outbox")
        try raw.execute("PRAGMA user_version = 50")

        _ = try Database(path: temp.path)
        let keys = try raw.query("SELECT id, transcription_key FROM transcript_picks ORDER BY id")
        #expect(keys.first { $0["id"]?.intValue == stamped.id }?["transcription_key"]?.stringValue == "a")
        #expect(keys.first { $0["id"]?.intValue == plain.id }?["transcription_key"]?.stringValue == nil)
        #expect(try raw.query("SELECT 1 FROM sqlite_master WHERE name = 'transcript_pick_sets'").isEmpty)
        // Only the pick that gained a set is pushed.
        let queued = try raw.query("""
            SELECT p.id FROM sync_outbox o JOIN transcript_picks p ON p.sync_id = o.sync_id WHERE o."table" = 'transcript_picks'
            """).compactMap { $0["id"]?.intValue }
        #expect(queued == [stamped.id])
        #expect(SyncTable.history.first { $0.name == "transcript_picks" }?.columns.contains("transcription_key") == true)
    }
}
