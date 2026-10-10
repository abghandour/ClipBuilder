import Foundation
import Testing
@testable import Clip_Builder

@Suite("Database people")
struct DatabasePeopleTests {
    @Test("Reassignment moves all references in one video and keeps portrait and person fields",
          arguments: [false, true])
    func reassignPerson(nobody: Bool) async throws {
        let temp = try TempDatabase()
        let fixture = try await Fixtures.personCorrection(in: temp)
        let raw = try SQLiteConnection(path: temp.path.path)
        let otherBefore = try videoRows(raw, videoID: fixture.otherVideo.id)
        let portraitBefore = try #require(try raw.query("SELECT * FROM video_people WHERE video_id = ?",
                                                       [.integer(fixture.video.id)]).first)
        // A collision must leave exactly one target tag, alongside unrelated tags.
        let sceneID = try #require(try await temp.database.fetchScenes(videoID: fixture.video.id).first?.id)
        try raw.execute("INSERT INTO scene_tags (scene_id, tag) VALUES (?, ?)",
                        [.integer(sceneID), .text(fixture.to.tag)])
        let target = nobody ? nil : fixture.to
        try await temp.database.reassignPerson(videoID: fixture.video.id, from: fixture.from, to: target)

        let scenes = try await temp.database.fetchScenes(videoID: fixture.video.id)
        #expect(scenes.count == 2)
        #expect(scenes.allSatisfy { !$0.tags.contains(fixture.from.tag) && $0.tags.contains("fixture") })
        #expect(scenes.filter { $0.tags.contains(fixture.to.tag) }.count == (nobody ? 1 : 2))
        let turns = try await temp.database.fetchSpeakerTurns(videoID: fixture.video.id)
        #expect(turns.count == 1)
        #expect(turns.first?.personKey == target?.key)
        let transcripts = try await temp.database.fetchTranscripts(videoID: fixture.video.id)
        #expect(transcripts.count == 1)
        #expect(transcripts.first?.speakerKey == target?.key)
        #expect(transcripts.first?.text == "A hand-assigned line")
        let topics = try await temp.database.fetchTopicRanges(videoID: fixture.video.id)
        #expect(topics.first?.speakerKeys == [fixture.to.key])
        let markers = try await temp.database.personMarkers(videoID: fixture.video.id)
        #expect(markers.count == 1)
        #expect(markers.first?.personID == target?.id)
        let voices = try await temp.database.fetchVoiceProfiles().filter { $0.videoID == fixture.video.id }
        #expect(voices.count == (nobody ? 0 : 1))
        if !nobody {
            #expect(voices.first?.personKey == fixture.to.key)
            #expect(voices.first?.vector == [1, 0])
            #expect(voices.first?.correctionWindows == 2)
        }
        let roster = try raw.query("SELECT * FROM video_people WHERE video_id = ?", [.integer(fixture.video.id)])
        #expect(roster.count == (nobody ? 0 : 1))
        if !nobody {
            #expect(roster.first?["person_id"]?.intValue == fixture.to.id)
            for field in ["portrait_at", "portrait_json", "ranges_json", "sync_id"] {
                #expect(roster.first?[field]?.stringValue == portraitBefore[field]?.stringValue)
            }
        }
        #expect(try videoRows(raw, videoID: fixture.otherVideo.id) == otherBefore)
        #expect(try await temp.database.fetchPeople().contains { $0.id == fixture.from.id })
        #expect(try raw.query("SELECT value FROM person_tag_fields WHERE person_key = ?",
                             [.text(fixture.from.key)]).first?["value"]?.stringValue == "Host")
    }

    @Test("An existing target keeps its portrait and voice while roster ranges form a sorted union")
    func mergeExistingTarget() async throws {
        let temp = try TempDatabase()
        let fixture = try await Fixtures.personCorrection(in: temp)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("""
            INSERT INTO video_people (video_id, person_id, portrait_at, portrait_json, ranges_json)
            VALUES (?, ?, 7, '{"x":0.5,"y":0.1,"w":0.2,"h":0.3}',
                '[{"start":20,"end":24},{"start":3,"end":9},{"start":0,"end":4}]')
            """, [.integer(fixture.video.id), .integer(fixture.to.id)])
        try raw.execute("""
            INSERT INTO voice_profiles (video_id, person_key, vector_json, windows)
            VALUES (?, ?, '[0,1]', 8)
            """, [.integer(fixture.video.id), .text(fixture.to.key)])
        let before = try #require(try raw.query("SELECT * FROM video_people WHERE video_id = ? AND person_id = ?",
                                               [.integer(fixture.video.id), .integer(fixture.to.id)]).first)
        try await temp.database.reassignPerson(videoID: fixture.video.id, from: fixture.from, to: fixture.to)
        let ranges = try await temp.database.fetchVideoPeopleRanges(videoID: fixture.video.id)
        #expect(ranges.count == 1)
        #expect(ranges.first?.ranges == [.init(start: 0, end: 12), .init(start: 20, end: 24)])
        let after = try #require(try raw.query("SELECT * FROM video_people WHERE video_id = ?",
                                              [.integer(fixture.video.id)]).first)
        for field in ["portrait_at", "portrait_json", "sync_id"] {
            #expect(after[field]?.stringValue == before[field]?.stringValue)
        }
        let voices = try await temp.database.fetchVoiceProfiles().filter { $0.videoID == fixture.video.id }
        #expect(voices.count == 1)
        #expect(voices.first?.personKey == fixture.to.key)
        #expect(voices.first?.vector == [0, 1])
        #expect(voices.first?.windows == 8)
    }

    @Test("Corrections cover older transcription sets and leave unrelated topic JSON untouched")
    func transcriptionHistoryAndTopics() async throws {
        let temp = try TempDatabase()
        let fixture = try await Fixtures.personCorrection(in: temp)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("""
            INSERT INTO speaker_turns (video_id, start_time, end_time, cluster, person_key, transcription_key)
            VALUES (?, 0, 4, 0, ?, 'older')
            """, [.integer(fixture.video.id), .text(fixture.from.key)])
        try raw.execute("""
            INSERT INTO transcripts (video_id, start_time, end_time, text, speaker_key, transcription_key)
            VALUES (?, 0, 4, 'Older line', ?, 'older')
            """, [.integer(fixture.video.id), .text(fixture.from.key)])
        let unchangedJSON = "[ \"unrelated-person\" ]"
        try raw.execute("""
            INSERT INTO topic_ranges (video_id, title, start_time, end_time, speaker_keys_json)
            VALUES (?, 'Unrelated', 10, 12, ?)
            """, [.integer(fixture.video.id), .text(unchangedJSON)])
        try raw.execute("""
            INSERT INTO topic_ranges (video_id, title, start_time, end_time, speaker_keys_json)
            VALUES (?, 'Only source', 12, 14, ?)
            """, [.integer(fixture.video.id), .text(String(decoding: try JSONEncoder().encode([fixture.from.key]), as: UTF8.self))])
        let counts = try await temp.database.personReferenceCounts(videoID: fixture.video.id, person: fixture.from)
        #expect(counts.scenes == 2 && counts.turns == 2)
        try await temp.database.reassignPerson(videoID: fixture.video.id, from: fixture.from, to: nil)
        for (table, column) in [("speaker_turns", "person_key"), ("transcripts", "speaker_key")] {
            let rows = try raw.query("SELECT \(column) FROM \(table) WHERE video_id = ?", [.integer(fixture.video.id)])
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0[column]?.stringValue == nil })
        }
        let topics = try raw.query("SELECT title, speaker_keys_json FROM topic_ranges WHERE video_id = ?", [.integer(fixture.video.id)])
        #expect(topics.first { $0["title"]?.stringValue == "Unrelated" }?["speaker_keys_json"]?.stringValue == unchangedJSON)
        #expect(topics.first { $0["title"]?.stringValue == "Only source" }?["speaker_keys_json"]?.stringValue == "[]")
    }

    @Test("A late decode failure rolls back the whole move and its outbox writes")
    func rollback() async throws {
        let temp = try TempDatabase()
        let fixture = try await Fixtures.personCorrection(in: temp)
        try await temp.database.bindSync(to: SyncScope(teamID: UUID(), profileID: UUID()))
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("INSERT INTO video_people (video_id, person_id, ranges_json) VALUES (?, ?, 'broken')",
                        [.integer(fixture.video.id), .integer(fixture.to.id)])
        let before = try videoRows(raw, videoID: fixture.video.id)
        try raw.execute("DELETE FROM sync_outbox")
        await #expect(throws: DecodingError.self) {
            try await temp.database.reassignPerson(videoID: fixture.video.id, from: fixture.from, to: fixture.to)
        }
        #expect(try videoRows(raw, videoID: fixture.video.id) == before)
        #expect(try raw.query("SELECT * FROM sync_outbox").isEmpty)
    }

    @Test("Reassigning to self is a no-op; removing the last sighting keeps the person")
    func selfAndOrphan() async throws {
        let temp = try TempDatabase()
        let fixture = try await Fixtures.personCorrection(in: temp)
        let raw = try SQLiteConnection(path: temp.path.path)
        let before = try videoRows(raw, videoID: fixture.video.id)
        try raw.execute("DELETE FROM sync_outbox")
        try await temp.database.reassignPerson(videoID: fixture.video.id, from: fixture.from, to: fixture.from)
        #expect(try videoRows(raw, videoID: fixture.video.id) == before)
        #expect(try raw.query("SELECT * FROM sync_outbox").isEmpty)
        for video in [fixture.video, fixture.otherVideo] {
            try await temp.database.reassignPerson(videoID: video.id, from: fixture.from, to: nil)
        }
        #expect(try await temp.database.fetchPeople().contains { $0.id == fixture.from.id })
        #expect(try raw.query("SELECT * FROM person_tag_fields").count == 1)
    }

    private func videoRows(_ raw: SQLiteConnection, videoID: Int64) throws -> [String: [[String: String]]] {
        var result: [String: [[String: String]]] = [:]
        for table in ["speaker_turns", "transcripts", "topic_ranges", "voice_profiles", "person_markers", "video_people"] {
            result[table] = try raw.query("SELECT * FROM \(table) WHERE video_id = ? ORDER BY rowid", [.integer(videoID)])
                .map { $0.mapValues { $0.stringValue ?? "NULL" } }
        }
        result["scene_tags"] = try raw.query("""
            SELECT st.* FROM scene_tags st JOIN scenes s ON s.id = st.scene_id
            WHERE s.video_id = ? ORDER BY st.rowid
            """, [.integer(videoID)]).map { $0.mapValues { $0.stringValue ?? "NULL" } }
        return result
    }
}
