import Foundation
import Testing
@testable import Clip_Builder

struct DubTranslationGateTests {
    private func seed(_ temp: TempDatabase) async throws -> Int64 {
        let id = try await temp.seedVideo()
        try await temp.database.replaceTranscripts(videoID: id, transcriptionKey: "dub-test", language: "en",
            isTranslation: false, segments: [
                .init(start: 0, end: 2, text: "One", words: nil),
                .init(start: 3, end: 5, text: "Two", words: nil),
                .init(start: 10, end: 12, text: "Outside", words: nil),
            ], provider: "fixture", model: nil)
        return id
    }

    @Test func deviceFirstThenModelOnlyForMissingRowsWithinClips() async throws {
        let temp = try await TempDatabase()
        let id = try await seed(temp)
        let stub = CaptionTranslationStub()
        let rows = try await DubTranslationGate.ensure(videoID: id, file: "interview.mp4", ranges: [0..<5],
            language: "pt-BR", ai: stub.service { _, _ in "1. Dois" }, database: temp.database,
            onDevice: { rows, language in
                #expect(language == "pt-BR" && rows.map(\.text) == ["One", "Two"])
                return [rows[0].id: "Um"]
            })
        #expect(stub.calls().map(\.texts) == [["Two"]])
        #expect(rows.map(\.text) == ["Um", "Dois"])
        #expect(rows.allSatisfy { $0.language == "pt-BR" && $0.isTranslation })
        let before = try await temp.database.fetchTranscripts(videoID: id)
        _ = try await DubTranslationGate.ensure(videoID: id, file: "interview.mp4", ranges: [0..<5],
            language: "pt-BR", ai: stub.service(), database: temp.database,
            onDevice: { _, _ in Issue.record("Existing translations should be reused"); return [:] })
        #expect(stub.calls().count == 1)
        #expect(try await temp.database.fetchTranscripts(videoID: id) == before)
    }

    @Test func partialTranslationFailsWithExactMessageAndNeverStoresOriginalFallback() async throws {
        let temp = try await TempDatabase()
        let id = try await seed(temp)
        let stub = CaptionTranslationStub()
        await #expect(throws: ScriptError.invalid("No pt-BR translation for interview.mp4; translate the transcript first")) {
            _ = try await DubTranslationGate.ensure(videoID: id, file: "interview.mp4", ranges: [0..<5],
                language: "pt-BR", ai: stub.service { _, _ in "No answer" }, database: temp.database,
                onDevice: { rows, _ in [rows[0].id: "Um"] })
        }
        #expect(try await temp.database.fetchTranscripts(videoID: id).allSatisfy { !$0.isTranslation })
    }

    @Test func fillingMissingRangePreservesReviewedTranslationsAndSourceAttribution() async throws {
        let temp = try await TempDatabase()
        let id = try await seed(temp)
        try await temp.database.replaceTranscripts(videoID: id, transcriptionKey: "dub-test", language: "pt-BR",
            isTranslation: true, segments: [.init(start: 0, end: 2, text: "Um", words: [
                .init(word: "Um", start: 0.1, end: 1.8),
            ])], provider: "fixture", model: nil)
        let saved = try #require(try await temp.database.fetchTranscripts(videoID: id).first { $0.isTranslation })
        try await temp.database.setTranscriptSpeaker(ids: [saved.id], speaker: .person(key: "host"))
        let second = try #require(try await temp.database.fetchTranscripts(videoID: id).first {
            !$0.isTranslation && $0.startTime == 3
        })
        try await temp.database.setTranscriptSpeaker(ids: [second.id], speaker: .unknown)
        let before = try #require(try await temp.database.fetchTranscripts(videoID: id).first { $0.id == saved.id })
        let stub = CaptionTranslationStub()
        let rows = try await DubTranslationGate.ensure(videoID: id, file: "source.mp4", ranges: [0..<5],
            language: "pt-BR", ai: stub.service(), database: temp.database,
            onDevice: { rows, _ in Dictionary(uniqueKeysWithValues: rows.map { ($0.id, "Dois") }) })
        #expect(rows.first == before)
        #expect(rows.last?.speaker == .unknown)
        #expect(stub.calls().isEmpty)
    }

    @Test func installedFailureFallsBackAndCancellationNeverDoes() async throws {
        let temp = try await TempDatabase()
        let id = try await seed(temp)
        let stub = CaptionTranslationStub()
        let rows = try await DubTranslationGate.ensure(videoID: id, file: "source.mp4", ranges: [0..<2],
            language: "pt-BR", ai: stub.service { _, _ in "1. Um" }, database: temp.database,
            onDevice: { _, _ in throw ScriptError.invalid("Not installed") })
        #expect(rows.map(\.text) == ["Um"])
        await #expect(throws: CancellationError.self) {
            _ = try await DubTranslationGate.ensure(videoID: id, file: "source.mp4", ranges: [3..<5],
                language: "pt-BR", ai: stub.service(), database: temp.database,
                onDevice: { _, _ in throw CancellationError() })
        }
        #expect(stub.calls().count == 1)
    }

    @Test func noTranscriptFailsInsteadOfSpeakingSourceText() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        let stub = CaptionTranslationStub()
        await #expect(throws: ScriptError.invalid("No en-US translation for empty.mp4; translate the transcript first")) {
            _ = try await DubTranslationGate.ensure(videoID: id, file: "empty.mp4", ranges: [0..<4],
                language: "en-US", ai: stub.service(), database: temp.database)
        }
        #expect(stub.calls().isEmpty)
    }
}
