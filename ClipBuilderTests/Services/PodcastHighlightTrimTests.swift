import Foundation
import Testing
@testable import Clip_Builder

@Suite("Podcast highlight trimming")
struct PodcastHighlightTrimTests {
    /// Two lines: "we trained for months" 10–12s and "and it ended in eight seconds" 12.5–15s.
    private func makeTrim() -> PodcastHighlightTrim {
        let first = TranscriptSegment(start: 10, end: 12, text: "we trained for months", words: [
            TranscriptWord(word: "we", start: 10.0, end: 10.3),
            TranscriptWord(word: "trained", start: 10.4, end: 10.9),
            TranscriptWord(word: "for", start: 11.0, end: 11.2),
            TranscriptWord(word: "months", start: 11.3, end: 12.0),
        ])
        let second = TranscriptSegment(start: 12.5, end: 15, text: "and it ended in eight seconds", words: [
            TranscriptWord(word: "and", start: 12.5, end: 12.7),
            TranscriptWord(word: "it", start: 12.8, end: 12.9),
            TranscriptWord(word: "ended", start: 13.0, end: 13.4),
            TranscriptWord(word: "in", start: 13.5, end: 13.6),
            TranscriptWord(word: "eight", start: 13.7, end: 14.0),
            TranscriptWord(word: "seconds", start: 14.1, end: 15.0),
        ])
        let turns = [SpeakerTurn(videoID: 1, start: 9, end: 12.2, cluster: 0, confidence: 1, personKey: "host"),
                     SpeakerTurn(videoID: 1, start: 12.2, end: 16, cluster: 1, confidence: 1)]
        let roster = [VideoPersonRecord(videoID: 1, personID: 7, key: "host", name: "Marcello", descriptor: "", portraitAt: 0)]
        return PodcastHighlightTrim(segments: [second, first], turns: turns, roster: roster, duration: 3600)
    }

    @Test("Lines keep source order, carry speaker changes, and flatten to timed words")
    func lines() {
        let trim = makeTrim()
        #expect(trim.lines.map(\.start) == [10, 12.5])
        #expect(trim.lines.map(\.speaker) == ["Marcello", "Speaker 2"])
        #expect(trim.words.count == 10)
        #expect(trim.words.map(\.id) == Array(0..<10))
        #expect(trim.duration == 3600)
    }

    @Test("A segment without word timings is one word spanning the segment")
    func untimedSegment() {
        let trim = PodcastHighlightTrim(segments: [TranscriptSegment(start: 3, end: 5, text: "  hello there ", words: nil)],
                                        duration: 10)
        #expect(trim.words.count == 1)
        #expect(trim.words[0].text == "hello there")
        #expect(trim.snappedStart(4.9) == 3 - PodcastHighlightTrim.cutPadding)
    }

    @Test("Handle drags snap outward to the nearest word boundaries")
    func snapping() {
        let trim = makeTrim()
        let range = trim.snapped(start: 10.55, end: 13.55)
        #expect(abs(range.lowerBound - (10.4 - PodcastHighlightTrim.cutPadding)) < 0.001)
        #expect(abs(range.upperBound - (13.6 + PodcastHighlightTrim.cutPadding)) < 0.001)
        // Beyond the transcript's reach, the nearest word still wins.
        #expect(abs(trim.snappedStart(-5) - (10 - PodcastHighlightTrim.cutPadding)) < 0.001)
        #expect(abs(trim.snappedEnd(9999) - (15 + PodcastHighlightTrim.cutPadding)) < 0.001)
    }

    @Test("A selection shorter than a second grows to the minimum span")
    func minimumSpan() {
        let trim = makeTrim()
        let range = trim.snapped(start: 10.4, end: 10.5)
        #expect(range.upperBound - range.lowerBound >= PodcastHighlightTrim.minimumSpan - 0.001)
        #expect(range.lowerBound < range.upperBound)
    }

    @Test("Clicking a word moves the nearer end: outside extends, inside trims")
    func wordSelection() throws {
        let trim = makeTrim()
        let selection = 12.42...14.08   // "and it ended in eight"
        let before = try #require(trim.words.first { $0.text == "trained" })
        let extendedStart = trim.range(selection, selecting: before)
        #expect(abs(extendedStart.lowerBound - (10.4 - PodcastHighlightTrim.cutPadding)) < 0.001)
        #expect(abs(extendedStart.upperBound - 14.08) < 0.001)

        let after = try #require(trim.words.first { $0.text == "seconds" })
        let extendedEnd = trim.range(selection, selecting: after)
        #expect(abs(extendedEnd.lowerBound - 12.42) < 0.001)
        #expect(abs(extendedEnd.upperBound - (15 + PodcastHighlightTrim.cutPadding)) < 0.001)

        let insideNearEnd = try #require(trim.words.first { $0.text == "in" })
        #expect(trim.edge(for: insideNearEnd, in: selection) == .end)
        let trimmedEnd = trim.range(selection, selecting: insideNearEnd)
        #expect(abs(trimmedEnd.upperBound - (13.6 + PodcastHighlightTrim.cutPadding)) < 0.001)

        let insideNearStart = try #require(trim.words.first { $0.text == "it" })
        #expect(trim.edge(for: insideNearStart, in: selection) == .start)
        let trimmedStart = trim.range(selection, selecting: insideNearStart)
        #expect(abs(trimmedStart.lowerBound - (12.8 - PodcastHighlightTrim.cutPadding)) < 0.001)
    }

    @Test("Words inside the selection and the line at a time are found")
    func membership() throws {
        let trim = makeTrim()
        let range = 12.42...14.08
        let inside = trim.words.filter { trim.contains($0, in: range) }.map(\.text)
        #expect(inside == ["and", "it", "ended", "in", "eight"])
        #expect(trim.lineID(at: 11) == 0)
        #expect(trim.lineID(at: 13) == 1)
        #expect(trim.lineID(at: 2) == nil)
    }

    @Test("A candidate counts as trimmed once an end moves more than a frame")
    func trimmedFlag() {
        let original = HighlightCandidate(sourceStart: 10, sourceEnd: 20, title: "t", reason: "r", score: 8,
                                          kind: .whole, speakerKeys: [])
        var edited = original
        #expect(!edited.isTrimmed(from: original))
        edited.sourceEnd = 20.01
        #expect(!edited.isTrimmed(from: original))
        edited.sourceEnd = 19
        #expect(edited.isTrimmed(from: original))
    }
}
