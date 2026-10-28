import Foundation
import Testing
@testable import Clip_Builder

struct TranscriptEditingTests {
    private func seed(_ temp: TempDatabase) async throws -> (Int64, [TranscriptRow]) {
        let id = try await temp.seedVideo()
        try await temp.database.replaceTranscripts(videoID: id, transcriptionKey: "source", language: "en",
            isTranslation: false, segments: [
                .init(start: 0, end: 3, text: "one two", words: [.init(word: "one", start: 0, end: 1), .init(word: "two", start: 2, end: 3)]),
                .init(start: 3, end: 4, text: "three", words: nil)
            ], provider: "test", model: "test")
        return (id, try await temp.database.fetchTranscripts(videoID: id))
    }

    @Test func editThenRevertRestoresExactTextAndWordJSON() async throws {
        let temp = try await TempDatabase()
        let (id, before) = try await seed(temp)
        try await temp.database.updateTranscriptText(id: before[0].id, text: "ONE extra two")
        try await temp.database.updateTranscriptText(id: before[0].id, text: "one changed two")
        let edited = try #require(try await temp.database.fetchTranscripts(videoID: id).first)
        #expect(edited.originalText == before[0].text)
        #expect(edited.originalWordsJSON == before[0].wordsJSON)
        #expect(edited.wordsJSON != before[0].wordsJSON)
        try await temp.database.revertTranscriptText(id: edited.id)
        let restored = try #require(try await temp.database.fetchTranscripts(videoID: id).first)
        #expect(restored.text == before[0].text && restored.wordsJSON == before[0].wordsJSON)
        #expect(restored.originalText == nil && restored.originalWordsJSON == nil)
    }

    @Test func typingTheOriginalBackIsARevert() async throws {
        let temp = try await TempDatabase()
        let (id, before) = try await seed(temp)
        try await temp.database.updateTranscriptText(id: before[0].id, text: "one changed two")
        try await temp.database.updateTranscriptText(id: before[0].id, text: before[0].text)
        let row = try #require(try await temp.database.fetchTranscripts(videoID: id).first)
        #expect(row == before[0])
        #expect(try await temp.database.editedTranscriptCount(videoID: id) == 0)
    }

    @Test func revertWithoutOriginalWordsAlignsOriginalTextOntoCurrentWords() async throws {
        let temp = try await TempDatabase()
        let (id, before) = try await seed(temp)
        try await temp.database.updateTranscriptText(id: before[0].id, text: "one changed two")
        // A row pulled by Team Sync carries original_text but not original_words.
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE transcripts SET original_words = NULL WHERE id = ?", [.integer(before[0].id)])
        try await temp.database.revertTranscriptTexts(videoID: id)
        let row = try #require(try await temp.database.fetchTranscripts(videoID: id).first)
        #expect(row.text == "one two" && row.originalText == nil && row.originalWordsJSON == nil)
        #expect(row.words?.map(\.word) == ["one", "two"])
        #expect(row.words?.first?.start == 0 && row.words?.last?.end == 3)
    }

    @Test func revertAllCountsOnlyEditedRowsInSet() async throws {
        let temp = try await TempDatabase()
        let (id, rows) = try await seed(temp)
        try await temp.database.updateTranscriptTexts(rows.map { (id: $0.id, text: "changed") })
        #expect(try await temp.database.editedTranscriptCount(videoID: id) == 2)
        #expect(try await temp.database.transcriptionSets(videoID: id).first?.editedCount == 2)
        #expect(try await temp.database.revertTranscriptTexts(videoID: id, transcriptionKey: "other") == 0)
        #expect(try await temp.database.revertTranscriptTexts(videoID: id) == 2)
        #expect(try await temp.database.fetchTranscripts(videoID: id) == rows)
        #expect(try await temp.database.revertTranscriptTexts(videoID: id) == 0)
    }

    @Test func derivedRefreshAndUnforcedTranscriptionUseEditedRowsWithoutDiskCache() async throws {
        let temp = try await TempDatabase()
        let (id, rows) = try await seed(temp)
        try await temp.database.updateTranscriptText(id: rows[0].id, text: "Corrected words")
        let video = try #require(try await temp.database.video(id: id))
        let service = TranscriptionService(cacheDirectory: temp.directory.url.appendingPathComponent("empty-cache"))
        try await service.refreshDerived(video: video, database: temp.database)
        #expect(try await temp.database.fetchTranscriptFeatures(videoID: id).contains { $0.text.contains("Corrected") })
        let result = try await service.transcribeForVideo(video: video, database: temp.database, force: false, log: { _ in })
        #expect(result.transcriptionKey == "source")
        #expect(result.segments.first?.text == "Corrected words")
        #expect(try await temp.database.transcriptionSets(videoID: id).count == 1)
    }

    @Test func recutAndBackupRestoreCarryOriginalWords() async throws {
        let temp = try await TempDatabase()
        let (id, rows) = try await seed(temp)
        try await temp.database.updateTranscriptText(id: rows[0].id, text: "one extra two")
        let edited = try await temp.database.fetchTranscripts(videoID: id)
        let pieces = edited.map {
            TranscriptSpeakerRecut.Piece(start: $0.startTime, end: $0.endTime, text: $0.text,
                words: $0.words, sourceRowID: $0.id, speakerKey: $0.speakerKey, split: false)
        }
        try await temp.database.recutTranscript(videoID: id, transcriptionKey: "source", pieces: pieces)
        #expect(try await temp.database.fetchTranscripts(videoID: id).first?.originalWordsJSON == rows[0].wordsJSON)
        #expect(try await temp.database.restoreTranscriptBackup(videoID: id))
        let restored = try #require(try await temp.database.fetchTranscripts(videoID: id).first)
        #expect(restored.originalWordsJSON == rows[0].wordsJSON)
        try await temp.database.revertTranscriptText(id: restored.id)
        #expect(try await temp.database.fetchTranscripts(videoID: id).first?.wordsJSON == rows[0].wordsJSON)
    }

    @Test func legacyBackupWithoutOriginalWordsStillDecodesAndRevertsExactly() async throws {
        let temp = try await TempDatabase()
        let (id, rows) = try await seed(temp)
        var legacy = rows
        legacy[0].originalText = legacy[0].text
        legacy[0].text = "one extra two"
        let encoded = try JSONEncoder().encode(legacy)
        var objects = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for index in objects.indices { objects[index].removeValue(forKey: "originalWordsJSON") }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: objects), as: UTF8.self)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("INSERT INTO transcript_backups (video_id, transcription_key, json) VALUES (?, 'source', ?)",
            [.integer(id), .text(json)])
        #expect(try await temp.database.restoreTranscriptBackup(videoID: id))
        let restored = try #require(try await temp.database.fetchTranscripts(videoID: id).first)
        #expect(restored.originalWordsJSON == rows[0].wordsJSON)
        #expect(restored.words?.map(\.word) == ["one", "extra", "two"])
        try await temp.database.revertTranscriptText(id: restored.id)
        #expect(try await temp.database.fetchTranscripts(videoID: id).first?.wordsJSON == rows[0].wordsJSON)
    }

    @Test func migrationBackfillsPreviouslyEditedRows() async throws {
        let temp = try await TempDatabase()
        let (id, rows) = try await seed(temp)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE transcripts SET original_text = text, text = 'one extra two' WHERE id = ?", [.integer(rows[0].id)])
        try raw.execute("ALTER TABLE transcripts DROP COLUMN original_words")
        try raw.execute("PRAGMA user_version = 34")
        let reopened = try Database(path: temp.path)
        let migrated = try #require(try await reopened.fetchTranscripts(videoID: id).first)
        #expect(migrated.originalWordsJSON == rows[0].wordsJSON)
        let words = try JSONDecoder().decode([TranscriptWord].self, from: Data(try #require(migrated.wordsJSON).utf8))
        #expect(words.map(\.word) == ["one", "extra", "two"])
        try await reopened.revertTranscriptText(id: migrated.id)
        #expect(try await reopened.fetchTranscripts(videoID: id).first == rows[0])
    }
}
