import Foundation
import Testing
@testable import Clip_Builder

struct TranscriptWordAlignmentTests {
    private let words: [TranscriptWord] = [
        .init(word: "One", start: 0, end: 1),
        .init(word: " two", start: 2, end: 3),
        .init(word: "three", start: 3, end: 4)
    ]

    @Test func keptWordsKeepClocksAndEditedSpelling() throws {
        let result = try #require(TranscriptWordAlignment.realign(text: "ONE, two three!", original: words, start: 0, end: 4))
        #expect(result.map(\.word) == ["ONE,", "two", "three!"])
        #expect(result.map(\.start) == words.map(\.start))
        #expect(result.map(\.end) == words.map(\.end))
    }

    @Test func insertedWordTakesGap() throws {
        let result = try #require(TranscriptWordAlignment.realign(text: "One extra two three", original: words, start: 0, end: 4))
        #expect(result[1] == TranscriptWord(word: "extra", start: 1, end: 2))
        #expect(result[2].start == words[1].start && result[2].end == words[1].end)
    }

    @Test func deletionLeavesNeighboursUntouched() throws {
        let result = try #require(TranscriptWordAlignment.realign(text: "One three", original: words, start: 0, end: 4))
        #expect(result == [words[0], words[2]])
    }

    @Test func replacementKeepsReplacedClock() throws {
        let original: [TranscriptWord] = [.init(word: "one", start: 0, end: 1),
            .init(word: "two", start: 1, end: 2), .init(word: "three", start: 2, end: 3)]
        let result = try #require(TranscriptWordAlignment.realign(text: "one new three", original: original, start: 0, end: 3))
        #expect(result[1] == TranscriptWord(word: "new", start: 1, end: 2))
    }

    @Test func zeroGapInsertionsRemainVisibleToConsumers() throws {
        let original: [TranscriptWord] = [.init(word: "one", start: 0, end: 1), .init(word: "two", start: 1, end: 2)]
        let text = "before one added two after"
        let aligned = try #require(TranscriptWordAlignment.realign(text: text, original: original, start: 0, end: 2))
        let json = String(decoding: try JSONEncoder().encode(aligned), as: UTF8.self)
        let row = TranscriptRow(id: 1, videoID: 1, language: "en", isTranslation: false,
            startTime: 0, endTime: 2, text: text, originalText: "one two", wordsJSON: json, provider: nil, model: nil)
        #expect(TranscriptQATrim.words(for: row).map(\.text).joined(separator: " ") == text)
        #expect(MiniWizardTranscriptRules.text(for: 0...2, rows: [row]) == text)
        let trim = PodcastHighlightTrim(segments: [.init(start: 0, end: 2, text: text, words: aligned)], duration: 2)
        #expect(trim.words.map(\.text).joined(separator: " ") == text)
        let pages = CaptionPaging.pages(text: text, start: 0, end: 2, words: aligned) { !$0.contains(" ") }
        #expect(pages.map(\.text).joined(separator: " ") == text)
        #expect(pages.allSatisfy { $0.end > $0.start })
    }

    @Test func missingOriginalReturnsNil() {
        #expect(TranscriptWordAlignment.realign(text: "new words", original: nil, start: 0, end: 3) == nil)
    }

    @Test func everyTokenGetsMonotonicClampedClock() throws {
        let original: [TranscriptWord] = [.init(word: "one", start: -2, end: 2),
            .init(word: "two", start: 1, end: 9)]
        let text = "before one added two after another"
        let result = try #require(TranscriptWordAlignment.realign(text: text, original: original, start: 0, end: 4))
        #expect(result.map(\.word) == text.split(separator: " ").map(String.init))
        #expect(result.allSatisfy { $0.start >= 0 && $0.end <= 4 && $0.start <= $0.end })
        #expect(zip(result, result.dropFirst()).allSatisfy { $0.end <= $1.start })
    }
}
