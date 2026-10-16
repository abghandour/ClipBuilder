import Foundation
import Testing
@testable import Clip_Builder

@Suite("Mini Wizard Transcript picks")
struct MiniWizardTranscriptTests {
    private func row(_ id: Int64, _ start: Double, _ end: Double, _ text: String, videoID: Int64 = 1,
                     translation: Bool = false) -> TranscriptRow {
        TranscriptRow(id: id, videoID: videoID, language: translation ? "en" : "pt", isTranslation: translation,
                      startTime: start, endTime: end, text: text, originalText: nil,
                      wordsJSON: nil, provider: nil, model: nil)
    }

    private func pick(_ id: Int64, _ start: Double, _ end: Double, position: Int = 0) -> TranscriptPick {
        TranscriptPick(id: id, videoID: 1, position: position, start: start, end: end,
                       originalStart: start, originalEnd: end, sceneID: nil)
    }

    private var rows: [TranscriptRow] {
        [row(1, 0, 4, "One two three four"), row(2, 4, 8, "Five six seven eight"),
         row(3, 8, 12, "Nine ten eleven twelve"), row(4, 0, 4, "Um dois três quatro", translation: true),
         row(5, 0, 4, "Other video", videoID: 2)]
    }

    @Test func textAndTitleFollowTheWordsInsideTheRange() {
        #expect(MiniWizardTranscriptRules.text(for: 3...9, rows: rows) == "four Five six seven eight Nine")
        #expect(MiniWizardTranscriptRules.title(for: 3...9, rows: rows, number: 2) == "four Five six seven eight Nine")
        #expect(MiniWizardTranscriptRules.title(for: 50...60, rows: rows, number: 2) == "Pick 2")
        let long = [row(9, 0, 100, Array(repeating: "word", count: 40).joined(separator: " "))]
        let title = MiniWizardTranscriptRules.title(for: 0...100, rows: long, number: 1)
        #expect(title.count <= MiniWizardTranscriptRules.titleLimit && title.hasSuffix("…"))
        #expect(!title.hasSuffix("wor…"), "cut at a word boundary")
        let wide = MiniWizardTranscriptRules.title(for: 0...100, rows: long, number: 1, limit: 90)
        #expect(wide.count > title.count && wide.count <= 90)
    }

    @Test func titleScopesRowsToThePickVideo() {
        #expect(MiniWizardTranscriptRules.title(for: pick(1, 0, 4), rows: rows, number: 1) == "One two three four")
        var other = pick(2, 0, 4)
        other.videoID = 2
        #expect(MiniWizardTranscriptRules.title(for: other, rows: rows, number: 3) == "Other video")
    }

    @Test func planIsTheWholePassageOnItsScene() {
        let plan = MiniWizardTranscriptRules.plan(for: pick(7, 3.5, 9), sceneID: 42, name: "A title")
        #expect(plan.clips.count == 1)
        #expect(plan.clips.first?.sceneID == 42)
        #expect(plan.clips.first?.start == 3.5 && plan.clips.first?.end == 9)
        #expect(plan.targetDuration == 5.5)
        #expect(plan.headline == "A title" && plan.rationale == "A title")
        #expect(plan.transitions.isEmpty && plan.musicVolume == 0 && plan.provenance == nil)
    }

    @Test func draftRangeStartsAtTheNextLineAfterTheLastPick() {
        #expect(MiniWizardTranscriptRules.draftRange(rows: rows, videoID: 1, after: nil, duration: 12) == 0...4)
        #expect(MiniWizardTranscriptRules.draftRange(rows: rows, videoID: 1, after: 4, duration: 12) == 4...8)
        #expect(MiniWizardTranscriptRules.draftRange(rows: rows, videoID: 1, after: 6, duration: 12) == 8...12)
        // Past the last line, fall back to the first line rather than nothing.
        #expect(MiniWizardTranscriptRules.draftRange(rows: rows, videoID: 1, after: 20, duration: 12) == 0...4)
        // No transcript lines for this video: a short span at the start.
        let empty = MiniWizardTranscriptRules.draftRange(rows: rows, videoID: 3, after: nil, duration: 30)
        #expect(empty.lowerBound == 0 && empty.upperBound >= TranscriptQATrim.minimumSpan)
        // Lines shorter than the minimum span are widened to it.
        let short = [row(1, 10, 10.2, "Hi")]
        #expect(MiniWizardTranscriptRules.draftRange(rows: short, videoID: 1, after: nil, duration: 30)
                == 10...(10 + TranscriptQATrim.minimumSpan))
    }

    @Test func runCountsPicksAsKeptFootage() {
        var run = MiniWizardRun(projectID: 1, video: Fixtures.video(), footageKind: .transcript, length: .automatic,
                                batchID: "b", candidates: [], options: WizardOptions())
        #expect(!run.hasFootage && run.keptCount == 0)
        run.transcript = MiniWizardTranscript(rows: rows, labels: [:], picks: [])
        #expect(run.hasFootage && run.keptCount == 0)
        #expect(run.summary == "0 picks")
        run.transcript?.picks = [pick(1, 0, 4)]
        #expect(run.keptCount == 1 && run.summary == "1 pick")
        run.transcript?.picks.append(pick(2, 4, 8, position: 1))
        #expect(run.summary == "2 picks")
    }
}

@Suite("Range review pick policy")
struct RangeReviewPickPolicyTests {
    @Test func pickPolicyKeepsAnEmptyRangeAndTrimsLikeQA() {
        let policy = RangeReviewItem.TrimPolicy.pick
        #expect(policy.clamp(12...12, limits: 0...100) == 12...12)
        #expect(policy.clamp(120...120, limits: 0...100) == 100...100)
        #expect(policy.clamp(12...12.2, limits: 0...100) == RangeReviewItem.TrimPolicy.qa.clamp(12...12.2, limits: 0...100))
        #expect(policy.minimumSpan == RangeReviewItem.TrimPolicy.qa.minimumSpan)
    }

    @Test func spanCoversBothWordsInEitherOrder() {
        let a = TranscriptQATrim.Word(id: 0, text: "a", start: 1, end: 1.5)
        let b = TranscriptQATrim.Word(id: 5, text: "b", start: 4, end: 4.8)
        #expect(TranscriptQAWordPanel<Int>.span(from: a, to: b) == 1...4.8)
        #expect(TranscriptQAWordPanel<Int>.span(from: b, to: a) == 1...4.8)
        #expect(TranscriptQAWordPanel<Int>.span(from: a, to: a) == 1...1.5)
    }
}
