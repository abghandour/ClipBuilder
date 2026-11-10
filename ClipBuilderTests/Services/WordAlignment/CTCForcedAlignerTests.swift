import Foundation
import Testing
@testable import Clip_Builder

/// Synthetic emissions: class 0 is blank, 1 = "a", 2 = "b", 3 = "c". Each
/// frame hears one class clearly and the rest barely.
struct CTCForcedAlignerTests {
    private static let step = 0.02
    private static let vocabulary = WordAlignerVocabulary(
        vocab: ["<pad>": 0, "a": 1, "b": 2, "c": 3, "|": 4], blank: 0, sampleRate: 16000, windowSeconds: 20)

    private static func emissions(_ heard: [Int], classes: Int = 5) -> CTCEmissions {
        var values: [Float] = []
        for peak in heard {
            for index in 0..<classes { values.append(index == peak ? Float(log(0.97)) : Float(log(1e-4))) }
        }
        return CTCEmissions(frames: heard.count, classes: classes, values: values, secondsPerFrame: step)
    }

    /// `count` blank frames with the given classes heard at the given frames.
    private static func frames(_ count: Int, _ heard: [Int: Int]) -> [Int] {
        (0..<count).map { heard[$0] ?? 0 }
    }

    @Test func tokensLandOnTheFramesThatHearThem() throws {
        let emissions = Self.emissions([0, 1, 0, 2, 2, 0, 3])
        let spans = try #require(CTCForcedAligner.align(emissions, frames: 0..<7, tokens: [1, 2, 3], blank: 0))
        #expect(spans.map(\.first) == [1, 3, 6])
        #expect(spans.map(\.end) == [2, 5, 7])
        #expect(spans.allSatisfy { $0.confidence > -0.1 })
    }

    @Test func aRepeatedLetterNeedsABlankBetween() throws {
        let spans = try #require(CTCForcedAligner.align(Self.emissions([1, 0, 1]), frames: 0..<3, tokens: [1, 1], blank: 0))
        #expect(spans.map(\.first) == [0, 2])
        #expect(CTCForcedAligner.align(Self.emissions([1, 1]), frames: 0..<2, tokens: [1, 1], blank: 0) == nil)
    }

    @Test func tokensThatCannotFitAreRefused() {
        #expect(CTCForcedAligner.align(Self.emissions([1, 2]), frames: 0..<2, tokens: [1, 2, 3], blank: 0) == nil)
        #expect(CTCForcedAligner.align(Self.emissions([1, 2]), frames: 0..<2, tokens: [], blank: 0) == nil)
        #expect(CTCForcedAligner.align(Self.emissions([1, 2]), frames: 0..<9, tokens: [1], blank: 0) == nil)
    }

    @Test func aWildcardAbsorbsSpeechTheTranscriptDoesNotSpell() throws {
        // "c c" is spoken before the word; the leading wildcard takes it.
        let emissions = Self.emissions([3, 0, 3, 0, 1, 2, 0])
        let spans = try #require(CTCForcedAligner.align(emissions, frames: 0..<7,
            tokens: [CTCForcedAligner.wildcard, 1, 2, CTCForcedAligner.wildcard], blank: 0))
        #expect(spans[1].first == 4)
        #expect(spans[2].first == 5)
    }

    @Test func aWordLeavesThePauseTheRecognizerGaveIt() {
        // Spoken: "ab" at 0.04 s, a long pause, "ba" at 0.80 s. The
        // recognizer stretched the first word across the pause.
        let emissions = Self.emissions(Self.frames(60, [2: 1, 3: 2, 40: 2, 41: 1]))
        let words = [TranscriptWord(word: "ab", start: 0, end: 1.0), TranscriptWord(word: "Ba,", start: 1.0, end: 1.14)]
        let result = CTCForcedAligner.retime(words: words, emissions: emissions, vocabulary: Self.vocabulary)
        #expect(result.aligned == 2)
        #expect(result.kept == 0)
        #expect(result.words.map(\.word) == ["ab", "Ba,"])
        #expect(abs(result.words[0].start - 0.04) < 0.001)
        // Two frames heard plus the tail the model clips.
        #expect(abs(result.words[0].end - 0.14) < 0.001)
        #expect(abs(result.words[1].start - 0.80) < 0.001)
        #expect(result.words[1].end <= 60 * Self.step)
    }

    @Test func theTailNeverRunsIntoTheNextWord() {
        let emissions = Self.emissions(Self.frames(20, [2: 1, 3: 2, 4: 2, 5: 1]))
        let words = [TranscriptWord(word: "ab", start: 0, end: 0.1), TranscriptWord(word: "ba", start: 0.1, end: 0.2)]
        let result = CTCForcedAligner.retime(words: words, emissions: emissions, vocabulary: Self.vocabulary).words
        #expect(result[0].end <= result[1].start)
        #expect(abs(result[1].start - 0.08) < 0.001)
    }

    @Test func aWordTheModelCannotSpellKeepsItsPlaceBetweenNeighbours() {
        let emissions = Self.emissions(Self.frames(100, [5: 1, 6: 2, 70: 2, 71: 1]))
        let words = [TranscriptWord(word: "ab", start: 0.06, end: 0.3),
                     TranscriptWord(word: "2026", start: 0.5, end: 0.9),
                     TranscriptWord(word: "ba", start: 1.3, end: 1.5)]
        let result = CTCForcedAligner.retime(words: words, emissions: emissions, vocabulary: Self.vocabulary)
        #expect(result.aligned == 2)
        #expect(result.kept == 1)
        #expect(result.words[1].start == 0.5)
        #expect(result.words[1].end == 0.9)
        #expect(abs(result.words[2].start - 1.40) < 0.001)
    }

    @Test func aBarelyHeardWordFarFromItsRecognizerTimeIsNotMoved() {
        // "c" is never heard. The only room for it is before "ba" at 2 s,
        // far from the 5 s the recognizer gave it: it is clamped into the
        // gap instead of dragging "ba" to 5 s.
        let emissions = Self.emissions(Self.frames(300, [5: 1, 6: 2, 100: 2, 101: 1]))
        let words = [TranscriptWord(word: "ab", start: 0.1, end: 0.2),
                     TranscriptWord(word: "c", start: 5.0, end: 5.1),
                     TranscriptWord(word: "ba", start: 5.1, end: 5.3)]
        let result = CTCForcedAligner.retime(words: words, emissions: emissions, vocabulary: Self.vocabulary)
        #expect(result.kept == 1)
        #expect(abs(result.words[2].start - 2.0) < 0.001)
        #expect(result.words[1].start >= result.words[0].start)
        #expect(result.words[1].start <= result.words[2].start)
        // With no room left it is empty, never laid over the next word.
        #expect(result.words[1].end <= result.words[2].start)
    }

    @Test func wordsWithTheSameRecognizerTimeNeverOverlap() {
        let emissions = Self.emissions(Self.frames(100, [10: 1, 11: 2]))
        let words = [TranscriptWord(word: "7", start: 0.5, end: 0.9), TranscriptWord(word: "8", start: 0.5, end: 0.9),
                     TranscriptWord(word: "ab", start: 0.9, end: 1.0)]
        let result = CTCForcedAligner.retime(words: words, emissions: emissions, vocabulary: Self.vocabulary).words
        for index in 0..<2 {
            #expect(result[index].start <= result[index].end)
            #expect(result[index].end <= result[index + 1].start)
        }
    }

    @Test func stitchedWindowsKeepEveryFrameOnce() {
        // The shipped model: 20 s windows of 16 kHz audio, 999 rows each.
        let window = 320_000, rows = 999
        #expect(WordAlignerWindows.stride(window: window, rows: rows) == 320)
        // Forty minutes: the stitched frame count is the file's length in
        // strides, so frame n is exactly n * 20 ms with no drift.
        for total in [1, 319, 320, 321, 192_000, 320_000, 320_001, 2_880_000, 38_400_000, 38_400_123] {
            let plan = WordAlignerWindows.plan(total: total, window: window, rows: rows)
            var frame = 0
            for item in plan {
                #expect(item.start % 320 == 0)
                #expect(item.start / 320 + item.rows.lowerBound == frame)
                #expect(item.rows.upperBound <= rows)
                #expect(item.count > 0 && item.count <= window)
                #expect(item.start + item.count <= total)
                frame += item.rows.count
            }
            #expect(frame == (total + 319) / 320)
            #expect(plan.first?.start == 0)
        }
        #expect(WordAlignerWindows.plan(total: 0, window: window, rows: rows).isEmpty)
    }

    @Test func aWordStretchedFarPastItsRecognizerLengthKeepsItsTime() {
        // "ab" is spelled but said with two seconds between its letters.
        let emissions = Self.emissions(Self.frames(200, [10: 1, 110: 2, 150: 3]))
        let words = [TranscriptWord(word: "ab", start: 0.2, end: 0.5), TranscriptWord(word: "c", start: 3.0, end: 3.1)]
        let result = CTCForcedAligner.retime(words: words, emissions: emissions, vocabulary: Self.vocabulary)
        #expect(result.kept == 1)
        #expect(result.words[0].start == 0.2)
        #expect(result.words[0].end == 0.5)
        #expect(abs(result.words[1].start - 3.0) < 0.001)
    }

    @Test func segmentsFollowTheirWords() {
        let emissions = Self.emissions(Self.frames(60, [2: 1, 3: 2, 40: 2, 41: 1]))
        let segments = [
            TranscriptSegment(start: 0, end: 1.0, text: "ab", words: [TranscriptWord(word: "ab", start: 0, end: 1.0)]),
            TranscriptSegment(start: 1.0, end: 1.05, text: "untimed", words: nil),
            TranscriptSegment(start: 1.0, end: 1.14, text: "ba", words: [TranscriptWord(word: "ba", start: 1.0, end: 1.14)])
        ]
        let result = CTCForcedAligner.retime(segments: segments, emissions: emissions, vocabulary: Self.vocabulary)
        #expect(result.aligned == 2)
        #expect(result.segments.map(\.text) == ["ab", "untimed", "ba"])
        #expect(abs(result.segments[0].start - 0.04) < 0.001)
        #expect(abs(result.segments[0].end - 0.14) < 0.001)
        #expect(result.segments[1].start == 1.0)
        #expect(result.segments[1].words == nil)
        #expect(abs(result.segments[2].start - 0.80) < 0.001)
    }

    @Test func manyBlocksStayInOrder() {
        // 60 words, one every half second, each recognized 0.3 s late. The
        // spellings cycle every six words (3 s), further than the search
        // margin, so no shifted placement scores the same.
        let spellings: [(String, [Int])] = [("ab", [1, 2]), ("ca", [3, 1]), ("bc", [2, 3]),
                                            ("ba", [2, 1]), ("ac", [1, 3]), ("cb", [3, 2])]
        var heard: [Int: Int] = [:]
        var words: [TranscriptWord] = []
        for index in 0..<60 {
            let frame = 10 + index * 25
            let (word, letters) = spellings[index % spellings.count]
            heard[frame] = letters[0]
            heard[frame + 1] = letters[1]
            let time = Double(frame) * Self.step + 0.3
            words.append(TranscriptWord(word: word, start: time, end: time + 0.5))
        }
        let emissions = Self.emissions(Self.frames(1600, heard))
        let result = CTCForcedAligner.retime(words: words, emissions: emissions, vocabulary: Self.vocabulary)
        #expect(result.aligned == 60)
        for index in 0..<60 {
            #expect(abs(result.words[index].start - Double(10 + index * 25) * Self.step) < 0.001)
            if index > 0 { #expect(result.words[index - 1].end <= result.words[index].start) }
        }
    }

    @Test func theVocabularyReadsTheShippedFile() throws {
        let json = #"{"vocab": {"<pad>": 0, "|": 4, "a": 7, "ç": 37}, "blank": 0, "sample_rate": 16000, "window_seconds": 20, "source": "x", "license": "apache-2.0"}"#
        let vocabulary = try JSONDecoder().decode(WordAlignerVocabulary.self, from: Data(json.utf8))
        #expect(vocabulary.letters == ["a": 7, "ç": 37])
        #expect(CTCForcedAligner.tokens(for: "Ça,", letters: vocabulary.letters) == [37, 7])
        #expect(CTCForcedAligner.tokens(for: "2026", letters: vocabulary.letters).isEmpty)
    }

    @Test func preciseTimingAppliesOnlyToPortuguese() {
        #expect(WordAlignerModel.applies(timing: .precise, language: "pt"))
        #expect(WordAlignerModel.applies(timing: .precise, language: "pt-BR"))
        #expect(!WordAlignerModel.applies(timing: .precise, language: "en"))
        #expect(!WordAlignerModel.applies(timing: .recognizer, language: "pt"))
    }

    @Test func theSettingDecodesFromOlderFiles() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.wordTimingChoice == .recognizer)
        var settings = AppSettings()
        settings.wordTimingChoice = .precise
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.wordTimingChoice == .precise)
    }
}
