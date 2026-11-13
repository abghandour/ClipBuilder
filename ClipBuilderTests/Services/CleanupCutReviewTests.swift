import Foundation
import Testing
@testable import Clip_Builder

@Suite("Cleanup cuts: what the review sheet lists, counts and shows around a cut")
struct CleanupCutReviewTests {
    private func cut(_ id: Int64, _ kind: EditProposal.Kind, _ start: Double, _ end: Double,
                     _ decision: EditProposal.Decision = .pending) -> EditProposal {
        EditProposal(id: id, videoID: 1, kind: kind, startTime: start, endTime: end, reason: "", decision: decision)
    }

    private func row(_ id: Int64, _ start: Double, _ end: Double, _ words: [(String, Double, Double)],
                     translation: Bool = false) -> TranscriptRow {
        let timed = words.map { TranscriptWord(word: $0.0, start: $0.1, end: $0.2) }
        let json = timed.isEmpty ? nil : String(decoding: try! JSONEncoder().encode(timed), as: UTF8.self)
        return TranscriptRow(id: id, videoID: 1, language: "pt", isTranslation: translation, startTime: start, endTime: end,
                             text: words.isEmpty ? "a whole line" : words.map(\.0).joined(separator: " "),
                             originalText: nil, wordsJSON: json, provider: "apple", model: "m")
    }

    @Test("The summary counts each decision and the seconds removed now and at most")
    func summary() {
        let cuts = [cut(1, .silence, 10, 12, .accepted), cut(2, .filler, 20, 20.5), cut(3, .repeatWord, 30, 31, .rejected)]
        let summary = CleanupCutReview.summary(cuts)
        #expect(summary.pending == 1 && summary.cut == 1 && summary.kept == 1 && summary.total == 3)
        #expect(abs(summary.removedSeconds - 2) < 0.001)
        #expect(abs(summary.possibleSeconds - 2.5) < 0.001, "a kept cut removes nothing")
        #expect(summary.count(.pending) == 1 && summary.count(.all) == 3)
        let overlapping = [cut(1, .silence, 10, 12, .accepted), cut(2, .filler, 11, 13, .accepted), cut(3, .filler, 12.5, 14)]
        #expect(abs(CleanupCutReview.summary(overlapping).removedSeconds - 3) < 0.001, "an overlap counts once")
        #expect(abs(CleanupCutReview.summary(overlapping).possibleSeconds - 4) < 0.001)
    }

    @Test("Only kinds that remove footage are reviewed")
    func reviewedKinds() {
        let all = [cut(1, .silence, 0, 1), cut(2, .bRoll, 2, 3), cut(3, .plannedClip, 4, 5), cut(4, .retake, 6, 7)]
        #expect(CleanupCutReview.cuts(all).map(\.id) == [1, 4])
    }

    @Test("Filters by state and kind; a cut just decided stays listed while it is sticky")
    func shown() {
        let cuts = [cut(1, .silence, 10, 12, .accepted), cut(2, .filler, 20, 20.5), cut(3, .filler, 30, 31, .rejected)]
        #expect(CleanupCutReview.shown(cuts, state: .pending, kind: nil).map(\.id) == [2])
        #expect(CleanupCutReview.shown(cuts, state: .pending, kind: nil, sticky: [1]).map(\.id) == [1, 2])
        #expect(CleanupCutReview.shown(cuts, state: .all, kind: .filler).map(\.id) == [2, 3])
        #expect(CleanupCutReview.shown(cuts, state: .kept, kind: .silence, sticky: [2]).isEmpty, "sticky never beats the kind")
        let kinds = CleanupCutReview.kinds(cuts, state: .all)
        #expect(kinds.map(\.kind) == [.silence, .filler] && kinds.map(\.count) == [1, 2])
        #expect(CleanupCutReview.kinds(cuts, state: .cut).map(\.kind) == [.silence])
    }

    @Test("The context is the removed words between the words before and after, across lines")
    func context() {
        let rows = [row(1, 0, 2, [("vamos", 0, 0.5), ("começar.", 0.5, 1.0), ("Paris", 1.2, 1.6)]),
                    row(2, 2, 4, [("Paris.", 2.0, 2.4), ("Bentem", 2.6, 3.0), ("Wait", 3.0, 3.4)]),
                    row(9, 0, 4, [("ignored", 1.2, 1.6)], translation: true)]
        let context = CleanupCutReview.context(for: cut(1, .falseStart, 1.1, 2.5), rows: rows, span: 1)
        #expect(context == .init(before: "começar.", removed: "Paris Paris.", after: "Bentem"))
        let silence = CleanupCutReview.context(for: cut(2, .silence, 1.02, 1.18), rows: rows)
        #expect(silence.removed.isEmpty && silence.before == "vamos começar." && silence.after == "Paris Paris. Bentem Wait")
    }

    @Test("Without word timings the context is the line the cut starts in")
    func contextWithoutWords() {
        let rows = [row(1, 0, 5, []), row(2, 5, 9, [])]
        #expect(CleanupCutReview.context(for: cut(1, .silence, 6, 7), rows: rows) == .init(after: "a whole line"))
        #expect(CleanupCutReview.context(for: cut(1, .silence, 6, 7), rows: []).isEmpty)
    }

    @Test("The same button twice puts a cut back to undecided")
    func toggled() {
        #expect(CleanupCutReview.toggled(.pending, to: .accepted) == .accepted)
        #expect(CleanupCutReview.toggled(.accepted, to: .accepted) == .pending)
        #expect(CleanupCutReview.toggled(.accepted, to: .rejected) == .rejected)
    }

    @Test("A nudged edge stays inside the file and never crosses the other edge")
    func nudged() {
        let base = cut(1, .silence, 1, 2)
        #expect(CleanupCutReview.nudged(base, start: -0.5, duration: 10).startTime == 0.5)
        #expect(CleanupCutReview.nudged(base, start: -5, duration: 10).startTime == 0)
        #expect(abs(CleanupCutReview.nudged(base, start: 5, duration: 10).startTime - 1.95) < 0.001)
        #expect(CleanupCutReview.nudged(base, end: 20, duration: 10).endTime == 10)
        #expect(abs(CleanupCutReview.nudged(base, end: -5, duration: 10).endTime - 1.05) < 0.001)
        #expect(CleanupCutReview.nudged(base, end: 20, duration: 0).endTime == 22, "an unknown duration does not clamp")
    }

    @Test("Arrow keys move to the neighbour and stop at the ends; Shift-click takes the run between")
    func movement() {
        let cuts = [cut(1, .silence, 0, 1), cut(2, .filler, 2, 3), cut(3, .filler, 4, 5)]
        #expect(CleanupCutReview.neighbour(of: nil, in: cuts, forward: true) == 1)
        #expect(CleanupCutReview.neighbour(of: 1, in: cuts, forward: true) == 2)
        #expect(CleanupCutReview.neighbour(of: 3, in: cuts, forward: true) == 3)
        #expect(CleanupCutReview.neighbour(of: 1, in: cuts, forward: false) == 1)
        #expect(CleanupCutReview.neighbour(of: 9, in: cuts, forward: false) == 1, "a row no longer listed starts over")
        #expect(CleanupCutReview.neighbour(of: 1, in: [], forward: true) == nil)
        #expect(CleanupCutReview.range(from: 3, to: 1, in: cuts) == [1, 2, 3])
        #expect(CleanupCutReview.range(from: nil, to: 2, in: cuts) == [2])
        #expect(CleanupCutReview.range(from: 9, to: 2, in: cuts) == [2])
    }

    @Test("Times read as minutes, seconds and tenths; SRT uses hours and milliseconds")
    func times() {
        #expect(CleanupCutReview.timecode(85.47) == "1:25.5")
        #expect(CleanupCutReview.timecode(59.96) == "1:00.0")
        #expect(CleanupCutReview.length(102.6) == "1:43")
        #expect(SubRipExport.time(3725.0405) == "01:02:05,041")
        let rows = [row(2, 5, 9, [("dois", 5, 6)]), row(1, 0, 5, [("um", 0, 1)])]
        #expect(SubRipExport.document(rows) == "1\n00:00:00,000 --> 00:00:05,000\num\n\n2\n00:00:05,000 --> 00:00:09,000\ndois\n")
    }
}
