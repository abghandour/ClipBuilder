import Foundation
import Testing
@testable import Clip_Builder

@Suite("Caption paging")
struct CaptionPagingTests {
    private func fits(_ text: String) -> Bool { text.split(separator: " ").count <= 6 }

    @Test func pagesPreserveEveryWholeWordAndNeverExceedTheMeasuredLimit() {
        let text = (1...47).map { "word\($0)" }.joined(separator: " ")
        let pages = CaptionPaging.pages(text: text, start: 10, end: 35, fits: fits)
        #expect(pages.count > 1)
        #expect(pages.allSatisfy { fits($0.text) })
        #expect(pages.map(\.text).joined(separator: " ") == text)
        #expect(pages.first?.start == 10 && pages.last?.end == 35)
        #expect(zip(pages, pages.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test func sentenceThenCommaBreaksArePreferredOnlyInTheLastThird() {
        let sentence = CaptionPaging.pages(text: "One two three four. Five, six seven eight", start: 0, end: 10, fits: fits)
        #expect(sentence.first?.text == "One two three four.")
        let comma = CaptionPaging.pages(text: "One two three four, five six seven eight", start: 0, end: 10, fits: fits)
        #expect(comma.first?.text == "One two three four,")
        let early = CaptionPaging.pages(text: "One. Two three four five six seven eight", start: 0, end: 10, fits: fits)
        #expect(early.first?.text == "One. Two three four five six")
    }

    @Test func timedPagesUseWordsAndBridgeSilenceWithoutRunningPastTheSegment() {
        let words = (0..<8).map {
            TranscriptWord(word: "w\($0)", start: 10 + Double($0), end: 10.3 + Double($0))
        }
        let pages = CaptionPaging.pages(text: words.map(\.word).joined(separator: " "), start: 9, end: 17.2,
                                       words: words, fits: fits)
        #expect(pages.count == 2)
        #expect(pages[0].start == 10 && pages[0].end == 16)
        #expect(pages[1].start == 16 && pages[1].end == 17.2)
    }

    @Test func untimedTranslationsUseCharacterProportionsAndBorrowForShortPages() {
        let originalWords = [TranscriptWord(word: "original", start: 0, end: 1)]
        let pages = CaptionPaging.pages(text: "Longer translated words here plus another tiny", start: 0, end: 10,
                                       words: originalWords, fits: fits)
        let weight = Double(pages[0].text.count) / Double(pages.map { $0.text.count }.reduce(0, +))
        #expect(abs(pages[0].end - 10 * weight) < 0.000001)
        let borrowed = CaptionPaging.pages(text: "Longer translated words here plus another x", start: 5, end: 7, fits: fits)
        #expect(borrowed.count == 2)
        #expect(abs((borrowed[1].end - borrowed[1].start) - 0.8) < 0.000001)
        #expect(abs((borrowed[0].end - borrowed[0].start) - 1.2) < 0.000001)
    }

    @Test func aVeryShortSegmentNeverOverrunsOrLosesWords() {
        let pages = CaptionPaging.pages(text: "a b c d e f g h i j k l m", start: 0, end: 1, fits: fits)
        #expect(pages.count == 3 && pages.last?.end == 1)
        #expect(pages.allSatisfy { abs($0.end - $0.start - 1.0 / 3) < 0.000001 })
    }

    @Test func shortTailMergesWhenTheMeasurementAllowsIt() {
        // A fit oracle need not be monotonic (e.g. an alternate balanced
        // layout becomes available). Recheck the complete merged tail.
        let pages = CaptionPaging.pages(text: "a b c d e f", start: 0, end: 1, fits: {
            let count = $0.split(separator: " ").count
            return count <= 6 && count != 5
        })
        #expect(pages == [CaptionPage(text: "a b c d e f", start: 0, end: 1)])
    }

    @Test func blankInvalidAndIndivisibleInputs() {
        #expect(CaptionPaging.pages(text: " \n ", start: 0, end: 1, fits: fits).isEmpty)
        #expect(CaptionPaging.pages(text: "word", start: 2, end: 1, fits: fits).isEmpty)
        let pages = CaptionPaging.pages(text: "indivisible", start: 0, end: 1, fits: { _ in false })
        #expect(pages.map(\.text) == ["indivisible"])
    }

    @Test func actualCaptionFontAndSafeWidthAgreeWithPaging() {
        let safe = PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: 9.0 / 16)
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: safe)
        let segment = TranscriptSegment(start: 0, end: 25,
            text: Array(repeating: "This is a long answer, with several complete thoughts.", count: 10).joined(separator: " "))
        let pages = renderer.pages(for: segment)
        #expect(pages.count > 1)
        #expect(pages.allSatisfy { renderer.rowCount(for: $0.text) <= 2 })
        #expect(pages.map(\.text).joined(separator: " ") == segment.text)
    }
}

extension CaptionPagingTests {
    @Test func renderQueryRetainsOriginalWordClocksButNeverAppliesThemToTranslations() async throws {
        let temp = try TempDatabase()
        let id = try await temp.seedVideo()
        let words = [TranscriptWord(word: "Original", start: 1.2, end: 1.8)]
        try await temp.database.replaceTranscripts(videoID: id, language: "pt", isTranslation: false,
            segments: [.init(start: 1, end: 2, text: "Original", words: words)], provider: nil, model: nil)
        try await temp.database.replaceTranscripts(videoID: id, language: "en", isTranslation: true,
            segments: [.init(start: 1, end: 2, text: "Translation", words: words)], provider: nil, model: nil)
        let originals = try await temp.database.transcriptSegments(videoID: id, start: 0, end: 3)
        let translated = try await temp.database.transcriptSegments(videoID: id, start: 0, end: 3, language: "en")
        #expect(originals.first?.words == words)
        #expect(translated.first?.words == nil && translated.first?.text == "Translation")
    }
}
