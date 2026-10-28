import Foundation
import Testing
@testable import Clip_Builder

struct TranscriptSetsTests {
    private func original(_ database: Database, videoID: Int64, key: String, text: String = "Original") async throws {
        try await database.replaceTranscripts(videoID: videoID, transcriptionKey: key, language: "pt",
            isTranslation: false, segments: [.init(start: 0, end: 4, text: text, words: nil)],
            provider: "apple", model: "Original model")
    }

    @Test func retranscriptionAllocatesNewKeyAndKeepsPreviousSet() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let segments = [TranscriptSegment(start: 0, end: 4, text: "First", words: nil)]
        let first = try await TranscriptionService.storeOriginal(videoID: id, language: "en", segments: segments, database: temp.database)
        let before = try await temp.database.fetchTranscripts(videoID: id, transcriptionKey: first)
        let second = try await TranscriptionService.storeOriginal(videoID: id, language: "en",
            segments: [.init(start: 0, end: 4, text: "Second", words: nil)], database: temp.database)
        #expect(first != second)
        #expect(try await temp.database.fetchTranscripts(videoID: id, transcriptionKey: first) == before)
        #expect(try await temp.database.fetchTranscripts(videoID: id, transcriptionKey: second).map(\.text) == ["Second"])
        #expect(try await temp.database.transcriptionSets(videoID: id).count == 2)
        #expect(before.first?.transcriptionCreatedAt?.hasPrefix("1970") == false)
    }

    @Test func activeTranscriptionHonorsPinMissingPinAndAutomatic() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        try await original(temp.database, videoID: id, key: "a")
        try await original(temp.database, videoID: id, key: "z")
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE transcripts SET transcription_created_at = '2026-10-12T00:00:00Z'")
        #expect(try await temp.database.activeTranscription(videoID: id).key == "z")
        try await temp.database.setActiveTranscriptionKey(videoID: id, key: "a")
        #expect(try await temp.database.activeTranscription(videoID: id).isPinned)
        #expect(try await temp.database.activeTranscription(videoID: id).key == "a")
        #expect(try await temp.database.latestTranscription(videoID: id).key == "z")
        try await temp.database.setActiveTranscriptionKey(videoID: id, key: "not-here")
        let fallback = try await temp.database.activeTranscription(videoID: id)
        #expect(fallback.key == "z" && fallback.missingPin && !fallback.isPinned)
        let reopened = try Database(path: temp.path)
        #expect(try await reopened.video(id: id)?.activeTranscriptionKey == "not-here")
        try await reopened.setActiveTranscriptionKey(videoID: id, key: nil)
        #expect(try await reopened.activeTranscription(videoID: id).key == "z")
        #expect(try await reopened.activeTranscription(videoID: id).missingPin == false)
    }

    @Test func predicateReadsPinnedOriginalAndItsTranslations() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        try await original(temp.database, videoID: id, key: "old", text: "Portuguese")
        try await temp.database.replaceTranscripts(videoID: id, transcriptionKey: "old", language: "en",
            isTranslation: true, segments: [.init(start: 0, end: 4, text: "English", words: nil)],
            provider: "translator", model: "ZZZ Translation model")
        try await temp.database.replaceTranscripts(videoID: id, transcriptionKey: "new", language: "fr",
            isTranslation: false, segments: [.init(start: 0, end: 4, text: "French", words: nil)], provider: "test", model: "new")
        try await temp.database.setActiveTranscriptionKey(videoID: id, key: "old")
        #expect(try await temp.database.fetchTranscripts(videoID: id).map(\.text) == ["Portuguese", "English"])
        #expect(try await temp.database.transcriptSegments(videoID: id, start: 0, end: 4).map(\.text) == ["Portuguese"])
        #expect(try await temp.database.transcriptSegments(videoID: id, start: 0, end: 4, language: "en").map(\.text) == ["English"])
        #expect(try await temp.database.originalTranscriptLanguage(videoID: id) == "pt")
        #expect(try await temp.database.hasTranscriptTranslation(videoID: id, language: "en"))
        #expect(try await temp.database.fetchTranscriptCounts()[id] == 2)
        #expect(try await temp.database.videoIDsWithOriginalTranscripts().contains(id))
        let set = try #require(try await temp.database.transcriptionSets(videoID: id).first { $0.id == "old" })
        #expect(set.model == "Original model" && set.provider == "apple" && set.language == "pt")
        #expect(set.segmentCount == 1 && set.hasTranslations && set.isActive && set.isPinned)
    }

    @Test func speakerTurnsAttachToExplicitSourceKey() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        try await original(temp.database, videoID: id, key: "old")
        try await original(temp.database, videoID: id, key: "new")
        try await temp.database.setActiveTranscriptionKey(videoID: id, key: "new")
        let turn = SpeakerTurn(videoID: id, start: 0, end: 4, cluster: 1, confidence: 1)
        try await temp.database.replaceSpeakerTurns(videoID: id, transcriptionKey: "old", turns: [turn])
        #expect(try await temp.database.fetchSpeakerTurns(videoID: id).isEmpty)
        #expect(try await temp.database.fetchSpeakerTurns(videoID: id, transcriptionKey: "old").count == 1)
        try await temp.database.setActiveTranscriptionKey(videoID: id, key: "old")
        #expect(try await temp.database.fetchSpeakerTurns(videoID: id).count == 1)
    }

    @Test func recutAndBackupsKeepSourceKeyAcrossNewTranscription() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        try await original(temp.database, videoID: id, key: "old", text: "one two")
        let source = try #require(try await temp.database.fetchTranscripts(videoID: id).first)
        try await original(temp.database, videoID: id, key: "new")
        try await temp.database.setActiveTranscriptionKey(videoID: id, key: "new")
        try await temp.database.recutTranscript(videoID: id, transcriptionKey: "old", pieces: [
            .init(start: 0, end: 2, text: "one", words: nil, sourceRowID: source.id, speakerKey: "host", split: true),
            .init(start: 2, end: 4, text: "two", words: nil, sourceRowID: source.id, speakerKey: "guest", split: true)
        ])
        let cut = try await temp.database.fetchTranscripts(videoID: id, transcriptionKey: "old")
        #expect(cut.map(\.text) == ["one", "two"] && cut.allSatisfy { $0.transcriptionKey == "old" })
        #expect(try await temp.database.hasTranscriptBackup(videoID: id) == false)
        _ = try await TranscriptionService.storeOriginal(videoID: id, language: "en",
            segments: [.init(start: 0, end: 4, text: "Third", words: nil)], database: temp.database)
        try await temp.database.setActiveTranscriptionKey(videoID: id, key: "old")
        #expect(try await temp.database.hasTranscriptBackup(videoID: id))
        #expect(try await temp.database.restoreTranscriptBackup(videoID: id))
        #expect(try await temp.database.fetchTranscripts(videoID: id).map(\.text) == ["one two"])
        #expect(try await temp.database.transcriptionSets(videoID: id).count == 3)
    }

    @Test func legacyVideoOnlyBackupMigratesToFootageSyncKey() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        try await original(temp.database, videoID: id, key: "temporary", text: "Legacy original")
        var rows = try await temp.database.fetchTranscripts(videoID: id)
        rows[0].transcriptionKey = nil
        rows[0].transcriptionCreatedAt = nil
        let json = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.executeScript("""
            DROP TABLE transcript_backups;
            CREATE TABLE transcript_backups (video_id INTEGER PRIMARY KEY REFERENCES videos(id), json TEXT NOT NULL, created_at TEXT);
            UPDATE transcripts SET transcription_key = NULL, transcription_created_at = NULL;
            PRAGMA user_version = 32;
            """)
        try raw.execute("INSERT INTO transcript_backups VALUES (?, ?, '2026-10-12')", [.integer(id), .text(json)])
        let reopened = try Database(path: temp.path)
        let key = try #require(try await reopened.activeTranscription(videoID: id).key)
        #expect(key != "temporary")
        #expect(try raw.query("SELECT transcription_key FROM transcript_backups").first?["transcription_key"]?.stringValue == key)
        #expect(try await reopened.transcriptBackup(videoID: id)?.first?.transcriptionKey == key)
        try await original(reopened, videoID: id, key: "new")
        try await reopened.setActiveTranscriptionKey(videoID: id, key: key)
        #expect(try await reopened.restoreTranscriptBackup(videoID: id))
        #expect(try await reopened.fetchTranscripts(videoID: id).map(\.text) == ["Legacy original"])
    }

    @Test func derivedDataFromAnotherSetIsAbsentAndPreserved() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        try await original(temp.database, videoID: id, key: "old")
        try await temp.database.replaceTranscriptFeatures(videoID: id, transcriptionKey: "old",
            features: [.init(id: 0, videoID: id, startTime: 0, endTime: 4, text: "Original", speakerKey: nil, energy: 1, kind: .speech)],
            proposals: [.init(id: 0, videoID: id, kind: .silence, startTime: 1, endTime: 2, reason: "pause", decision: .accepted)])
        try await temp.database.replaceTopicRanges(videoID: id, transcriptionKey: "old",
            topics: [.init(id: 0, videoID: id, title: "Topic", startTime: 0, endTime: 4, summary: "Summary", speakerKeys: [])])
        try await temp.database.replaceVoiceProfiles(videoID: id, transcriptionKey: "old",
            profiles: [.init(personKey: "host", videoID: id, vector: [1, 0], windows: 3, correctionWindows: 1)])
        try await temp.database.setPodcastLayout(videoID: id, transcriptionKey: "old", layout: .singleCamera, seamX: nil, confidence: 1)
        try await original(temp.database, videoID: id, key: "new")
        try await temp.database.setActiveTranscriptionKey(videoID: id, key: "new")
        #expect(try await temp.database.fetchTranscriptFeatures(videoID: id).isEmpty)
        #expect(try await temp.database.fetchEditProposals(videoID: id).isEmpty)
        #expect(try await temp.database.fetchTopicRanges(videoID: id).isEmpty)
        #expect(try await temp.database.fetchVoiceProfiles().isEmpty)
        #expect(try await temp.database.video(id: id)?.podcastLayout == nil)
        try await temp.database.replaceTranscriptFeatures(videoID: id, transcriptionKey: "new", features: [], proposals: [])
        try await temp.database.replaceTopicRanges(videoID: id, transcriptionKey: "new", topics: [])
        try await temp.database.replaceVoiceProfiles(videoID: id, transcriptionKey: "new", profiles: [])
        try await temp.database.setActiveTranscriptionKey(videoID: id, key: "old")
        #expect(try await temp.database.fetchTranscriptFeatures(videoID: id).count == 1)
        #expect(try await temp.database.fetchEditProposals(videoID: id).count == 1)
        #expect(try await temp.database.fetchTopicRanges(videoID: id).count == 1)
        // A voice profile is one row per person per video (people merges rely on
        // that key); a re-map under any set replaces the video's whole contribution.
        #expect(try await temp.database.fetchVoiceProfiles().isEmpty)
        #expect(try await temp.database.video(id: id)?.podcastLayout == "single_camera")
    }
}
