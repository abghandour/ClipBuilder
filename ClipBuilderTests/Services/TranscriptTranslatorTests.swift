import Foundation
import Testing
@testable import Clip_Builder

struct TranscriptTranslatorTests {
    private func seed(_ temp: TempDatabase, count: Int) async throws -> (Int64, [TranscriptRow]) {
        let id = try await temp.seedVideo()
        let segments = (0..<count).map { index in
            TranscriptSegment(start: Double(index * 2), end: Double(index * 2 + 2), text: "Original \(index)", words: nil)
        }
        try await temp.database.replaceTranscripts(videoID: id, language: "pt", isTranslation: false,
            segments: segments, provider: "fixture", model: nil)
        return (id, try await temp.database.fetchTranscripts(videoID: id))
    }

    @Test func chunksBy25EvenWhenBatchPolicyIsOff() async throws {
        let temp = try TempDatabase()
        let (id, originals) = try await seed(temp, count: 56)
        let stub = CaptionTranslationStub()
        let outcome = try await TranscriptTranslator.translateBatched(videoID: id, originals: originals, target: "en",
            ai: stub.service(), database: temp.database, onDevice: { _, _ in [:] }, log: { stub.log($0) })
        #expect(stub.calls().map { $0.texts.count } == [25, 25, 6])
        #expect(stub.calls().flatMap(\.texts) == originals.map(\.text))
        #expect(stub.calls().allSatisfy { $0.timeout == 120 })
        #expect(stub.logs() == ["Captions: translated 25 of 56 lines", "Captions: translated 50 of 56 lines",
                                "Captions: translated 56 of 56 lines"])
        #expect(outcome.segments == 56)
        let stored = try await temp.database.fetchTranscripts(videoID: id).filter(\.isTranslation)
        #expect(stored.count == 56)
        #expect(stored.allSatisfy { $0.technique == "numbered-translation-batch" })
    }

    @Test func retriesOnlyUnansweredRowsThenFallsBackAndPreservesStoredRows() async throws {
        let temp = try TempDatabase()
        let (id, originals) = try await seed(temp, count: 5)
        try await temp.database.replaceTranscripts(videoID: id, language: "en", isTranslation: true,
            segments: [.init(start: 0, end: 2, text: "Old answer", words: nil),
                       .init(start: 8, end: 10, text: "Stored unanswered", words: nil),
                       .init(start: 100, end: 102, text: "Outside cut", words: nil)], provider: "fixture", model: nil)
        let stub = CaptionTranslationStub()
        let ai = stub.service { index, _ in index == 0 ? "1. Answer zero\n3. Answer two" : (index == 1 ? "1. Answer one" : "No answers") }
        _ = try await TranscriptTranslator.translateBatched(videoID: id, originals: originals, target: "en",
            ai: ai, database: temp.database, onDevice: { _, _ in [:] }, log: { stub.log($0) })
        #expect(stub.calls().map(\.texts) == [originals.map(\.text), ["Original 1", "Original 3"], ["Original 4"]])
        let stored = try await temp.database.fetchTranscripts(videoID: id).filter(\.isTranslation)
        #expect(stored.map(\.text) == ["Answer zero", "Answer one", "Answer two", "Original 3", "Stored unanswered", "Outside cut"])
        #expect(stub.logs().contains { $0.contains("could not translate 2 lines") })
        #expect(try await temp.database.fetchTranscripts(videoID: id).filter { !$0.isTranslation } == originals)
    }

    @Test func completelyUnansweredChunkIsRetriedInSmallerBatches() async throws {
        let temp = try TempDatabase()
        let (id, originals) = try await seed(temp, count: 25)
        let stub = CaptionTranslationStub()
        _ = try await TranscriptTranslator.translateBatched(videoID: id, originals: originals, target: "en",
            ai: stub.service { _, _ in "No numbered answers" }, database: temp.database, onDevice: { _, _ in [:] })
        #expect(stub.calls().map { $0.texts.count } == [25, 12, 12, 1])
        let stored = try await temp.database.fetchTranscripts(videoID: id).filter(\.isTranslation)
        #expect(stored.map(\.text) == originals.map(\.text))
    }

    @Test func cancellationBetweenChunksDoesNotWritePartialTrack() async throws {
        let temp = try TempDatabase()
        let (id, originals) = try await seed(temp, count: 26)
        try await temp.database.replaceTranscripts(videoID: id, language: "en", isTranslation: true,
            segments: [.init(start: 100, end: 102, text: "Keep me", words: nil)], provider: "fixture", model: nil)
        let before = try await temp.database.fetchTranscripts(videoID: id)
        let stub = CaptionTranslationStub()
        let task = Task {
            try await TranscriptTranslator.translateBatched(videoID: id, originals: originals, target: "en",
                ai: stub.service(), database: temp.database, onDevice: { _, _ in [:] }, log: { message in
                    if message == "Captions: translated 25 of 26 lines" {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(stub.calls().count == 1)
        #expect(try await temp.database.fetchTranscripts(videoID: id) == before)
    }

    @Test func deviceAnswersAreExcludedFromAIBatches() async throws {
        let temp = try TempDatabase()
        let (id, originals) = try await seed(temp, count: 3)
        let stub = CaptionTranslationStub()
        _ = try await TranscriptTranslator.translateBatched(videoID: id, originals: originals, target: "en",
            ai: stub.service(), database: temp.database, onDevice: { rows, target in
                #expect(target == "en")
                return [rows[0].id: "On device", rows[1].id: "  "]
            })
        #expect(stub.calls().map(\.texts) == [["Original 1", "Original 2"]])
        let stored = try await temp.database.fetchTranscripts(videoID: id).filter(\.isTranslation)
        #expect(stored.map(\.text) == ["On device", "English Original 1", "English Original 2"])
    }

    @Test func deviceFailureFallsBackToAI() async throws {
        let temp = try TempDatabase()
        let (id, originals) = try await seed(temp, count: 1)
        let stub = CaptionTranslationStub()
        _ = try await TranscriptTranslator.translateBatched(videoID: id, originals: originals, target: "en",
            ai: stub.service(), database: temp.database, onDevice: { _, _ in throw AIError.unusableResponse("Device unavailable") })
        #expect(stub.calls().map(\.texts) == [["Original 0"]])
    }

    @Test func allDeviceAnswersAvoidAIAndStillEmitProgress() async throws {
        let temp = try TempDatabase()
        let (id, originals) = try await seed(temp, count: 26)
        let stub = CaptionTranslationStub()
        _ = try await TranscriptTranslator.translateBatched(videoID: id, originals: originals, target: "en",
            ai: stub.service(), database: temp.database, onDevice: { rows, _ in
                Dictionary(uniqueKeysWithValues: rows.map { ($0.id, "Device \($0.text)") })
            }, log: { stub.log($0) })
        #expect(stub.calls().isEmpty)
        #expect(stub.logs() == ["Captions: translated 25 of 26 lines", "Captions: translated 26 of 26 lines"])
        let stored = try await temp.database.fetchTranscripts(videoID: id).filter(\.isTranslation)
        #expect(stored.map(\.text) == originals.map { "Device \($0.text)" })
    }

    @Test func deviceCancellationDoesNotStartAIOrWriteCaptions() async throws {
        let temp = try TempDatabase()
        let (id, originals) = try await seed(temp, count: 1)
        let stub = CaptionTranslationStub()
        await #expect(throws: CancellationError.self) {
            _ = try await TranscriptTranslator.translateBatched(videoID: id, originals: originals, target: "en",
                ai: stub.service(), database: temp.database, onDevice: { _, _ in throw CancellationError() })
        }
        #expect(stub.calls().isEmpty)
        #expect(try await temp.database.fetchTranscripts(videoID: id) == originals)
    }

    @Test func nothingMissingDoesNotCallOrLogOrRewrite() async throws {
        let temp = try TempDatabase()
        let (id, _) = try await seed(temp, count: 1)
        let before = try await temp.database.fetchTranscripts(videoID: id)
        let stub = CaptionTranslationStub()
        _ = try await TranscriptTranslator.translateBatched(videoID: id, originals: [], target: "en",
            ai: stub.service(), database: temp.database, onDevice: { _, _ in
                Issue.record("No device work expected")
                return [:]
            }, log: { stub.log($0) })
        #expect(stub.calls().isEmpty && stub.logs().isEmpty)
        #expect(try await temp.database.fetchTranscripts(videoID: id) == before)
    }
}
