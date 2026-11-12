import Foundation
import Testing
@testable import Clip_Builder

@Suite("Transcript translations shown and edited under their lines")
struct TranscriptTranslationRowsTests {
    private typealias Language = TranscriptTranslationRows.Language

    private func row(_ id: Int64, _ start: Double, _ end: Double, _ language: String = "pt", translation: Bool = false) -> TranscriptRow {
        TranscriptRow(id: id, videoID: 1, language: language, isTranslation: translation, startTime: start, endTime: end,
                      text: "…", originalText: nil, wordsJSON: nil, provider: "apple", model: "m")
    }

    @Test("A translation sits under the line with its range, else the one it overlaps most; none is dropped")
    func attached() {
        let rows = [row(1, 0, 12), row(2, 12, 15),
                    row(10, 0, 12, "en", translation: true), row(11, 12, 15, "en", translation: true),
                    row(12, 11, 14.5, "es", translation: true), row(13, 40, 41, "es", translation: true)]
        let attached = TranscriptTranslationRows.attached(rows)
        #expect(attached[1]?.map(\.id) == [10])
        #expect(attached[2]?.map(\.id) == [11, 12, 13], "by language; the stray line goes to the nearest")
        #expect(TranscriptTranslationRows.attached(rows.filter(\.isTranslation)).isEmpty)
    }

    @Test("Missing languages are the project's caption languages the transcript has in no form")
    func missing() {
        let rows = [row(1, 0, 12), row(10, 0, 12, "en-US", translation: true)]
        #expect(TranscriptTranslationRows.missing(captions: ["en", "pt-BR", "es", "es-MX", ""], rows: rows) == ["es"])
        #expect(TranscriptTranslationRows.missing(captions: ["en"], rows: [row(1, 0, 12)]) == ["en"])
        #expect(TranscriptTranslationRows.languages(rows) == [Language(code: "pt", isTranslation: false),
                                                             Language(code: "en-US", isTranslation: true)])
    }

    @Test("A pill hides or shows its language; the last one on show stays")
    func pills() {
        let all = [Language(code: "pt", isTranslation: false), Language(code: "en", isTranslation: true)]
        var hidden = TranscriptTranslationRows.toggling(all[0], hidden: [], all: all)
        #expect(hidden == [all[0]])
        hidden = TranscriptTranslationRows.toggling(all[1], hidden: hidden, all: all)
        #expect(hidden == [all[0]], "the only language left cannot be hidden")
        hidden = TranscriptTranslationRows.toggling(all[0], hidden: hidden, all: all)
        #expect(hidden.isEmpty)
    }

    @Test("A translation line edited by hand survives a re-translation; Revert returns the machine's text")
    func handEditKept() async throws {
        let temp = try await TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo()
        func segments(_ a: String, _ b: String) -> [TranscriptSegment] {
            [TranscriptSegment(start: 0, end: 1, text: a), TranscriptSegment(start: 1, end: 2, text: b)]
        }
        try await database.replaceTranscripts(videoID: videoID, transcriptionKey: "k", language: "pt", isTranslation: false,
                                              segments: segments("olá", "tchau"), provider: "apple", model: "m")
        try await database.replaceTranscripts(videoID: videoID, transcriptionKey: "k", language: "en", isTranslation: true,
                                              segments: segments("hello", "bye"), provider: "apple", model: "m")
        func translations() async throws -> [TranscriptRow] {
            try await database.fetchTranscripts(videoID: videoID, transcriptionKey: "k").filter(\.isTranslation)
        }
        let first = try #require(try await translations().first { $0.startTime == 0 })
        try await database.updateTranscriptTexts([(id: first.id, text: "hi there")])
        // A whole new pass, and a per-line refresh after the original changed.
        try await database.replaceTranscripts(videoID: videoID, transcriptionKey: "k", language: "en", isTranslation: true,
                                              segments: segments("HELLO", "BYE"), provider: "apple", model: "m")
        let originals = try await database.fetchTranscripts(videoID: videoID, transcriptionKey: "k").filter { !$0.isTranslation }
        try await database.storeDubTranslations(videoID: videoID, transcriptionKey: "k", originals: originals, target: "en",
            answered: Dictionary(uniqueKeysWithValues: originals.map { ($0.id, "machine") }), provider: nil, model: nil)
        var rows = try await translations().sorted { $0.startTime < $1.startTime }
        #expect(rows.map(\.text) == ["hi there", "machine"])
        try await database.revertTranscriptText(id: rows[0].id)
        rows = try await translations().sorted { $0.startTime < $1.startTime }
        #expect(rows[0].text == "hello" && rows[0].originalText == nil)
    }
}
