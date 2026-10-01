import Foundation
import Testing
@testable import Clip_Builder

struct WizardBatchRankingTests {
    private func video(_ id: Int64, score: Int?, batch: String? = "run", date: String = "2026-09-29") -> GeneratedVideoRecord {
        var row = Fixtures.generatedVideo(id: id, batchID: batch)
        row.generatedAt = date
        row.critiqueJSON = score.flatMap {
            AISettingsJSON.encode(ReelCritique(score: $0, summary: "", strengths: [], issues: [], notes: [], regenerate: false))
        }
        return row
    }

    @Test func highestScoreWinsAndTiesChooseLatest() {
        let rows = [video(1, score: 90), video(2, score: 90), video(3, score: 80),
                    video(4, score: nil), video(5, score: 100, batch: "other")]
        #expect(WizardBatchRanking.best(in: rows, batchID: "run")?.id == 2)
        let dated = [video(10, score: 90, date: "2026-09-28"), video(2, score: 90)]
        #expect(WizardBatchRanking.best(in: dated, batchID: "run")?.id == 2)
        #expect(WizardBatchRanking.best(in: [video(1, score: nil)], batchID: "run") == nil)
    }

    @Test func discardIsConfinedToWinningBatch() throws {
        let rows = [video(1, score: 90), video(2, score: 60), video(3, score: nil),
                    video(4, score: 50, batch: "other"), video(5, score: 50, batch: nil)]
        let best = try #require(WizardBatchRanking.best(in: rows, batchID: "run"))
        #expect(WizardBatchRanking.discards(in: rows, keeping: best).map(\.id) == [2, 3])
        #expect(WizardBatchRanking.discards(in: rows, keeping: rows[1]).isEmpty)
        #expect(WizardBatchRanking.discards(in: rows, keeping: rows[4]).isEmpty)
    }
}
