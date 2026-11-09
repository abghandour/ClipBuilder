import Foundation
import Testing
@testable import Clip_Builder

struct DubTakeCutterTests {
    private func alignment(_ text: String) -> DubTakeAlignment {
        let characters = text.map(String.init)
        return DubTakeAlignment(characters: characters,
            starts: characters.indices.map { Double($0) * 0.1 },
            ends: characters.indices.map { Double($0 + 1) * 0.1 })
    }

    @Test func sourceTrimsSelectWholeWordsOnTheVoiceClock() throws {
        let text = "one two three four"
        let selected = DubTakeCutter.text(text, rowStart: 10, rowEnd: 18, start: 12, end: 16)
        #expect(selected == "two three")
        let cut = try #require(DubTakeCutter.timeRange(text: text, alignment: alignment(text),
            rowStart: 10, rowEnd: 18, start: 12, end: 16))
        #expect(abs(cut.lowerBound - 0.4) < 0.0001)
        #expect(abs(cut.upperBound - 1.3) < 0.0001)
        #expect(DubTakeCutter.text(text, rowStart: 10, rowEnd: 18, start: 12.1, end: 17.9) == "three")
    }

    @Test func unicodePunctuationAndWhitespaceKeepWordBoundaries() throws {
        let text = "  Olá,\t世界!  👋🏽 fim. "
        let cut = try #require(DubTakeCutter.timeRange(text: text, alignment: alignment(text),
            rowStart: 0, rowEnd: 4, start: 1, end: 3))
        #expect(cut.upperBound > cut.lowerBound)
        #expect(DubTakeCutter.text(text, rowStart: 0, rowEnd: 4, start: 1, end: 3) == "世界! 👋🏽")
    }

    @Test func existingSourceWordTimesTakePrecedenceOverProportionalTrimming() throws {
        let text = "one two three four"
        let words = [TranscriptWord(word: "one", start: 0, end: 0.2),
                     TranscriptWord(word: "two", start: 0.2, end: 0.4),
                     TranscriptWord(word: "three", start: 0.4, end: 0.6),
                     TranscriptWord(word: "four", start: 0.6, end: 4)]
        #expect(DubTakeCutter.text(text, rowStart: 0, rowEnd: 4, start: 0.2, end: 0.6, words: words) == "two three")
        let cut = try #require(DubTakeCutter.timeRange(text: text, alignment: alignment(text),
            rowStart: 0, rowEnd: 4, start: 0.2, end: 0.6, words: words))
        #expect(abs(cut.lowerBound - 0.4) < 0.0001 && abs(cut.upperBound - 1.3) < 0.0001)
    }

    @Test func malformedMissingOrDifferentAlignmentNeverCuts() {
        var bad = alignment("hello world")
        bad.ends.removeLast()
        #expect(!bad.isValid)
        #expect(DubTakeCutter.timeRange(text: "hello world", alignment: bad,
            rowStart: 0, rowEnd: 2, start: 1, end: 2) == nil)
        #expect(DubTakeCutter.timeRange(text: "hello world", alignment: nil,
            rowStart: 0, rowEnd: 2, start: 1, end: 2) == nil)
        #expect(DubTakeCutter.timeRange(text: "hello world", alignment: alignment("different words"),
            rowStart: 0, rowEnd: 2, start: 1, end: 2) == nil)
        bad = alignment("hello world"); bad.starts[2] = .nan
        #expect(!bad.isValid)
        bad = alignment("hello world"); bad.starts[2] = -1
        #expect(!bad.isValid)
    }

    @Test func invalidAndEmptySourceSpansAreRejected() {
        for (start, end) in [(1.0, 1.0), (2, 1), (.nan, 2), (0, .infinity)] {
            #expect(DubTakeCutter.wordRange(text: "one two", rowStart: 0, rowEnd: 2, start: start, end: end) == nil)
        }
        #expect(DubTakeCutter.wordRange(text: "one two", rowStart: 0, rowEnd: 0, start: 0, end: 2) == nil)
        #expect(DubTakeCutter.wordRange(text: "one two", rowStart: 0, rowEnd: 2, start: 0.1, end: 0.2) == nil)
        #expect(DubTakeCutter.text("one two", rowStart: 0, rowEnd: 2, start: -100, end: 100) == "one two")
    }
}
