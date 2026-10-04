import Testing
@testable import Clip_Builder

struct WizardCaptionChoicesTests {
    private func row(_ id: Int64, start: Double, end: Double, translated: Bool = false) -> TranscriptRow {
        TranscriptRow(id: id, videoID: 1, language: translated ? "en" : "pt", isTranslation: translated,
                      startTime: start, endTime: end, text: "Line \(id)", originalText: nil,
                      wordsJSON: nil, provider: nil, model: nil)
    }

    @Test func onlyOverlappingRowsAndNoDuplicatesForRepeatedCuts() {
        let rows = [row(1, start: 0, end: 10), row(2, start: 10, end: 20), row(3, start: 20, end: 30)]
        let selected = WizardCaptionChoices.rowsNeedingTranslation(originals: rows, translations: [],
            ranges: [(10, 20), (12, 18)], padding: 0)
        #expect(selected.map(\.id) == [2])
    }

    @Test func paddingIncludesEdgesButNotRowsOnlyTouchingThePaddedBoundary() {
        let rows = [row(1, start: 8, end: 9), row(2, start: 9, end: 10), row(3, start: 10, end: 20),
                    row(4, start: 20, end: 21), row(5, start: 21, end: 22)]
        #expect(WizardCaptionChoices.rowsNeedingTranslation(originals: rows, translations: [],
            ranges: [(10, 20)], padding: 1).map(\.id) == [2, 3, 4])
    }

    @Test func skipOnlyMatchingStoredTimeRanges() {
        let rows = [row(1, start: 0, end: 10), row(2, start: 10, end: 20), row(3, start: 20, end: 30)]
        let translated = [row(4, start: 0, end: 10, translated: true), row(5, start: 11, end: 19, translated: true)]
        #expect(WizardCaptionChoices.rowsNeedingTranslation(originals: rows, translations: translated,
            ranges: [(0, 30)]).map(\.id) == [2, 3])
    }

    @Test func nothingMissingAndNoRangesReturnEmpty() {
        let originals = [row(1, start: 0, end: 10)]
        #expect(WizardCaptionChoices.rowsNeedingTranslation(originals: originals,
            translations: [row(2, start: 0, end: 10, translated: true)], ranges: [(0, 10)]).isEmpty)
        #expect(WizardCaptionChoices.rowsNeedingTranslation(originals: originals, translations: [], ranges: []).isEmpty)
    }
}
