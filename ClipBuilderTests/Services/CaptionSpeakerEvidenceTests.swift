import Testing
@testable import Clip_Builder

struct CaptionSpeakerEvidenceTests {
    @Test func clusterOnlyTurnsUseRosterPeopleAndDiscardExcessClusters() async throws {
        let temp = try TempDatabase()
        let fixture = try await Fixtures.personCorrection(in: temp)
        try seedClusters(in: temp, videoID: fixture.video.id, guest: fixture.from, host: fixture.to)

        let evidence = await CaptionSpeakerEvidence.load(database: temp.database, videoID: fixture.video.id)
        #expect(evidence.turns.map(\.personKey) == [fixture.to.key, fixture.from.key, nil])
        #expect(evidence.turns.map(\.cluster) == [0, 1, 2])
        #expect(evidence.rosterKeys == [fixture.to.key, fixture.from.key])
        #expect(evidence.names == [fixture.from.key: fixture.from.displayName, fixture.to.key: fixture.to.displayName])
        #expect(evidence.rows.count == 1)
        #expect(evidence.rows.first?.text == "A hand-assigned line")
        #expect(evidence.rows.first?.speakerKey == nil)
        #expect(CaptionSpeakerOrder.ordinals(turns: evidence.turns, rows: evidence.rows,
            roster: evidence.rosterKeys) == [fixture.to.key: 1, fixture.from.key: 2])
        // Naming is read-time evidence; the stored analysis remains cluster-only.
        let stored = try await temp.database.fetchSpeakerTurns(videoID: fixture.video.id)
        #expect(stored.allSatisfy { $0.personKey == nil })
    }

    @Test func storedKeysOutsideTheRosterAreClearedAndRosterKeysArePreserved() async throws {
        let temp = try TempDatabase()
        let fixture = try await Fixtures.personCorrection(in: temp)
        let raw = try SQLiteConnection(path: temp.path.path)
        for (index, key) in ["speaker-99", "removed-person"].enumerated() {
            try raw.execute("""
                INSERT INTO speaker_turns (video_id, start_time, end_time, cluster, person_key)
                VALUES (?, ?, ?, ?, ?)
                """, [.integer(fixture.video.id), .real(Double(4 + index)), .real(Double(5 + index)),
                      .integer(Int64(index + 1)), .text(key)])
        }
        let evidence = await CaptionSpeakerEvidence.load(database: temp.database, videoID: fixture.video.id)
        #expect(evidence.turns.map(\.personKey) == [fixture.from.key, nil, nil])
        #expect(evidence.rows.first?.speakerKey == fixture.from.key)
    }

    @Test func multipleVideosAreNamedIndependentlyInTheSuppliedOrder() async throws {
        let temp = try TempDatabase()
        let fixture = try await Fixtures.personCorrection(in: temp)
        try seedClusters(in: temp, videoID: fixture.video.id, guest: fixture.from, host: fixture.to)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE speaker_turns SET person_key = NULL WHERE video_id = ?",
                        [.integer(fixture.otherVideo.id)])
        let evidence = await CaptionSpeakerEvidence.load(database: temp.database,
            videoIDs: [fixture.otherVideo.id, fixture.video.id])
        #expect(evidence.turns.map(\.videoID) == [fixture.otherVideo.id, fixture.video.id, fixture.video.id, fixture.video.id])
        #expect(evidence.turns.map(\.personKey) == [fixture.from.key, fixture.to.key, fixture.from.key, nil])
        #expect(evidence.rows.map(\.videoID) == [fixture.otherVideo.id, fixture.video.id])
        #expect(evidence.roster.map(\.videoID) == [fixture.otherVideo.id, fixture.video.id, fixture.video.id])
        #expect(evidence.names.count == 2)
        #expect(CaptionSpeakerOrder.ordinals(turns: evidence.turns, rows: evidence.rows,
            roster: evidence.rosterKeys) == [fixture.from.key: 1, fixture.to.key: 2])
    }

    @Test func explicitTranscriptionFiltersTurnsBeforeNaming() async throws {
        let temp = try TempDatabase()
        let fixture = try await Fixtures.personCorrection(in: temp)
        try seedClusters(in: temp, videoID: fixture.video.id, guest: fixture.from, host: fixture.to)
        try await temp.database.replaceSpeakerTurns(videoID: fixture.video.id, transcriptionKey: "preview", turns: [
            .init(videoID: fixture.video.id, start: 0, end: 10, cluster: 7, confidence: 1)])
        let evidence = await CaptionSpeakerEvidence.load(database: temp.database,
            videoID: fixture.video.id, transcriptionKey: "preview")
        #expect(evidence.turns.map(\.cluster) == [7])
        #expect(evidence.turns.map(\.personKey) == [fixture.from.key])
        #expect(evidence.rows.count == 1)
    }

    @Test func missingVideoAndEmptySelectionReturnEmptyEvidence() async throws {
        let temp = try TempDatabase()
        let missing = await CaptionSpeakerEvidence.load(database: temp.database, videoID: -1)
        let empty = await CaptionSpeakerEvidence.load(database: temp.database, videoIDs: [])
        for evidence in [missing, empty] {
            #expect(evidence.turns.isEmpty && evidence.rows.isEmpty && evidence.roster.isEmpty)
            #expect(evidence.rosterKeys.isEmpty && evidence.names.isEmpty)
        }
    }

    private func seedClusters(in temp: TempDatabase, videoID: Int64,
                              guest: PersonRecord, host: PersonRecord) throws {
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE video_people SET vip = 1 WHERE video_id = ? AND person_id = ?",
                        [.integer(videoID), .integer(guest.id)])
        try raw.execute("INSERT INTO video_people (video_id, person_id, portrait_at, vip) VALUES (?, ?, 0, 0)",
                        [.integer(videoID), .integer(host.id)])
        try raw.execute("UPDATE transcripts SET speaker_key = NULL WHERE video_id = ?", [.integer(videoID)])
        try raw.execute("DELETE FROM speaker_turns WHERE video_id = ?", [.integer(videoID)])
        // The VIP speaks longest but appears after the host in the roster and timeline.
        for (cluster, start, end) in [(0, 0.0, 2.0), (1, 2.0, 8.0), (2, 8.0, 9.0)] {
            try raw.execute("""
                INSERT INTO speaker_turns (video_id, start_time, end_time, cluster, confidence)
                VALUES (?, ?, ?, ?, 1)
                """, [.integer(videoID), .real(start), .real(end), .integer(Int64(cluster))])
        }
    }
}
