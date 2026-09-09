import Foundation
import Testing
@testable import Clip_Builder

struct PodcastLocalRulesTests {
    @Test func modelCannotMoveLockedExchange() async throws {
        let stub = try StubAI(response: #"{"exchanges":[{"first_sentence":0,"last_sentence":3,"title":"Combined","summary":"Answer","score":7}]}"#)
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Why?", words: nil),
            TranscriptSegment(start: 1, end: 4, text: "Because it mattered.", words: nil),
            TranscriptSegment(start: 6, end: 7, text: "What next?", words: nil),
            TranscriptSegment(start: 7, end: 10, text: "We continued.", words: nil),
        ]
        let turns = segments.enumerated().map { index, segment in
            SpeakerTurn(videoID: 1, start: segment.start, end: segment.end, cluster: index % 2, confidence: 1)
        }
        let result = try await PodcastExchangeSegmenter(ai: stub.service).segment(
            segments: segments, turns: turns, provider: "claude", model: nil, log: { _ in }, useLocal: true)
        #expect(result.exchanges.contains { $0.start == 0 && $0.end == 4 })
        #expect(try String(contentsOf: stub.prompts, encoding: .utf8).contains("LOCKED"))
        #expect(try String(contentsOf: stub.calls, encoding: .utf8) == "call\n")
    }
    @Test func preservesLockedBoundary() {
        let fixed = PodcastExchange(start: 0, end: 10, title: "Q", summary: "", score: 0, speakerKeys: [])
        let moved = PodcastExchange(start: 0, end: 20, title: "Title", summary: "", score: 0.4, speakerKeys: [])
        let result = PodcastLocalRules.preserve([moved], locked: [fixed])
        #expect(result.map(\.end) == [10, 20])
        #expect(result.first?.title == "Title")
    }
    @Test func fallbackScore() {
        let segments = [TranscriptSegment(start: 0, end: 10, text: "What happened? This was an unexpected finish.", words: nil)]
        let score = PodcastLocalRules.score(segments: segments, start: 0, end: 10)
        #expect(score > 0 && score <= 0.5)
    }
}

extension PodcastLocalRulesTests {
    private static let segments = [
        TranscriptSegment(start: 0, end: 1, text: "Why?", words: nil),
        TranscriptSegment(start: 1, end: 4, text: "Because it mattered.", words: nil),
        TranscriptSegment(start: 6, end: 7, text: "What next?", words: nil),
        TranscriptSegment(start: 7, end: 10, text: "We continued.", words: nil),
    ]
    private static func exchange(_ start: Double, _ end: Double) -> PodcastExchange {
        PodcastExchange(start: start, end: end, title: "", summary: "", score: 0, speakerKeys: [])
    }
    @Test func lockedNeedsQuestionSingleAnswerAndPause() {
        let turns = Self.segments.enumerated().map { index, segment in
            SpeakerTurn(videoID: 1, start: segment.start, end: segment.end, cluster: index % 2, confidence: 1)
        }
        #expect(PodcastLocalRules.locked(Self.exchange(0, 4), segments: Self.segments, turns: turns))
        // Two people answer inside the window.
        let split = turns + [SpeakerTurn(videoID: 1, start: 2.5, end: 4, cluster: 0, confidence: 1)]
        #expect(!PodcastLocalRules.locked(Self.exchange(0, 4), segments: Self.segments, turns: split))
        // No question mark on the opening row.
        var statement = Self.segments
        statement[0].text = "Why"
        #expect(!PodcastLocalRules.locked(Self.exchange(0, 4), segments: statement, turns: turns))
        // The next row follows too closely.
        var tight = Self.segments
        tight[2].start = 5
        #expect(!PodcastLocalRules.locked(Self.exchange(0, 4), segments: tight, turns: turns))
        // Nothing follows at all, or the exchange is too long to be unambiguous.
        #expect(!PodcastLocalRules.locked(Self.exchange(6, 10), segments: Self.segments, turns: turns))
        #expect(!PodcastLocalRules.locked(Self.exchange(0, 95), segments: Self.segments, turns: turns))
    }
    @Test func preserveSplitsAModelExchangeAroundALock() {
        let spanning = PodcastExchange(start: 0, end: 30, title: "Whole", summary: "", score: 0.6, speakerKeys: [])
        var fixed = Self.exchange(10, 20)
        fixed.speakerKeys = ["a"]
        let result = PodcastLocalRules.preserve([spanning], locked: [fixed])
        #expect(result.map { "\($0.start)-\($0.end)" } == ["0.0-10.0", "10.0-20.0", "20.0-30.0"])
        #expect(result[1].title == "Whole")
        #expect(result[1].speakerKeys == ["a"])
        // A lock the model dropped entirely is reinstated.
        #expect(PodcastLocalRules.preserve([], locked: [fixed]).map(\.start) == [10])
    }
    @Test func offPathSendsNoLocksAndLeavesFallbackUnscored() async throws {
        let stub = try StubAI(response: #"{"exchanges":[{"first_sentence":0,"last_sentence":3,"title":"Combined","summary":"Answer","score":7}]}"#)
        let turns = Self.segments.enumerated().map { index, segment in
            SpeakerTurn(videoID: 1, start: segment.start, end: segment.end, cluster: index % 2, confidence: 1)
        }
        let result = try await PodcastExchangeSegmenter(ai: stub.service).segment(
            segments: Self.segments, turns: turns, provider: "claude", model: nil, log: { _ in }, useLocal: false)
        #expect(result.exchanges.count == 1)
        #expect(result.exchanges.first?.start == 0 && result.exchanges.first?.end == 10)
        #expect(result.provenance?.technique == nil)
        #expect(!(try String(contentsOf: stub.prompts, encoding: .utf8)).contains("LOCKED"))
        let broken = try StubAI(response: "not json")
        let fallback = try await PodcastExchangeSegmenter(ai: broken.service).segment(
            segments: Self.segments, turns: turns, provider: "claude", model: nil, log: { _ in }, useLocal: false)
        #expect(fallback.exchanges.allSatisfy { $0.score == 0 })
        #expect(fallback.provenance == nil)
        let local = try await PodcastExchangeSegmenter(ai: broken.service).segment(
            segments: Self.segments, turns: turns, provider: "claude", model: nil, log: { _ in }, useLocal: true)
        #expect(fallback.exchanges.count == local.exchanges.count)
        #expect(local.exchanges.allSatisfy { $0.score > 0 })
        #expect(local.provenance?.technique == "transcript-features")
    }
}
