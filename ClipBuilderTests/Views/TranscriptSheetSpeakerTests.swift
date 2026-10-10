import Foundation
import Testing
@testable import Clip_Builder

@Suite("Transcript sheet speaker helpers")
struct TranscriptSheetSpeakerTests {
    private func row(_ id: Int64, _ start: Double, _ end: Double, key: String? = nil) -> TranscriptRow {
        TranscriptRow(id: id, videoID: 1, language: "pt", isTranslation: false, startTime: start, endTime: end,
                      text: "…", originalText: nil, wordsJSON: nil, provider: "apple", model: "m", speakerKey: key)
    }

    private func turn(_ start: Double, _ end: Double, key: String?) -> SpeakerTurn {
        var turn = SpeakerTurn(videoID: 1, start: start, end: end, cluster: 0, confidence: 1)
        turn.personKey = key
        return turn
    }

    private let roster = [
        VideoPersonRecord(videoID: 1, personID: 1, key: "a", name: "Ana", descriptor: "", portraitAt: 0),
        VideoPersonRecord(videoID: 1, personID: 2, key: "b", name: "Bo", descriptor: "", portraitAt: 0),
    ]

    @Test("lines whose speaker the new map changed carry the old name; hand-attributed lines and unchanged lines do not")
    func changedLabels() {
        let before = [turn(0, 10, key: "a"), turn(10, 20, key: "b")]
        let after = [turn(0, 5, key: "a"), turn(5, 20, key: "b"), turn(20, 25, key: "a")]
        let rows = [row(1, 0, 4), row(2, 6, 9), row(3, 12, 15), row(4, 21, 24), row(5, 6, 9, key: "a")]
        let changed = TranscriptSpeakers.changedLabels(rows: rows, before: before, after: after, roster: roster)
        #expect(changed == [2: "Ana", 4: "no speaker"])
        #expect(TranscriptSpeakers.changedLabels(rows: rows, before: [], after: after, roster: roster).isEmpty)
    }

    @Test("a speaker block ends where its last line ends")
    func blockEnds() {
        let rows = [row(1, 0, 2, key: "a"), row(2, 2, 5, key: "a"), row(3, 5, 7, key: "b"), row(4, 8, 9, key: "a")]
        let ends = TranscriptSheet.blockEnds(rows) { $0.speakerKey == $1.speakerKey }
        #expect(ends == [5, 5, 7, 9])
        #expect(TranscriptSheet.blockEnds([]) { _, _ in true }.isEmpty)
    }

    @Test("three visible lines in one exchange have first, middle and last edges")
    func exchangeSpansThreeRows() {
        let rows = [row(1, 0, 2), row(2, 2, 5), row(3, 5, 7)]
        let spans = TranscriptSheet.exchangeSpans(rows) { _ in 10 }
        #expect(spans == [0: .first, 1: .middle, 2: .last])
    }

    @Test("a single visible line in an exchange has both bracket ends")
    func exchangeSpansSingleRow() {
        let spans = TranscriptSheet.exchangeSpans([row(1, 0, 2)]) { _ in 10 }
        #expect(spans == [0: .only])
    }

    @Test("back-to-back exchanges close one bracket before opening the next")
    func exchangeSpansAdjacentExchanges() {
        let rows = [row(1, 0, 2), row(2, 2, 5), row(3, 5, 7), row(4, 7, 9)]
        let spans = TranscriptSheet.exchangeSpans(rows) { $0.id <= 2 ? 10 : 20 }
        #expect(spans == [0: .first, 1: .last, 2: .first, 3: .last])
    }

    @Test("lines outside exchanges have no bracket edge")
    func exchangeSpansOmitUnmatchedRows() {
        let rows = [row(1, 0, 2), row(2, 2, 5), row(3, 5, 7), row(4, 7, 9)]
        let spans = TranscriptSheet.exchangeSpans(rows) { $0.id == 2 || $0.id == 3 ? 10 : nil }
        #expect(spans == [1: .first, 2: .last])
        #expect(TranscriptSheet.exchangeSpans(rows) { _ in nil }.isEmpty)
        #expect(TranscriptSheet.exchangeSpans([]) { _ in 10 }.isEmpty)
    }

    @Test("a visible gap splits the same exchange into separate bracket runs")
    func exchangeSpansVisibleGap() {
        let rows = [row(1, 0, 2), row(2, 2, 5), row(3, 5, 7)]
        let spans = TranscriptSheet.exchangeSpans(rows) { $0.id == 2 ? nil : 10 }
        #expect(spans == [0: .only, 2: .only])
    }

    @Test("filtering out a gap keeps the remaining exchange lines in one run")
    func exchangeSpansFilteredGap() {
        let rows = [row(1, 0, 2), row(2, 2, 5), row(3, 5, 7)]
        let visible = rows.filter { $0.id != 2 }
        let spans = TranscriptSheet.exchangeSpans(visible) { _ in 10 }
        #expect(spans == [0: .first, 1: .last])
    }

    @Test("the mapping status drops the filename prefix and keeps other lines whole")
    func statusLine() {
        #expect(TranscriptSheet.statusLine("Podcast 02.mp4: transcript re-cut by speaker — 3 rows split") == "transcript re-cut by speaker — 3 rows split")
        #expect(TranscriptSheet.statusLine("Voice embeddings: 3712 windows through the model") == "Voice embeddings: 3712 windows through the model")
    }
}
