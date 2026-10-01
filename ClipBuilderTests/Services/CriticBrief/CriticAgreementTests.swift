import Foundation
import Testing
@testable import Clip_Builder

struct CriticAgreementTests {
    private func critique(_ score: Int, forecast: Int? = nil) -> ReelCritique {
        .init(score: score, summary: "", strengths: [], issues: [], notes: [], regenerate: false, forecast: forecast)
    }

    @Test func metricsUseFixedPairedRowsAndStrictWins() throws {
        let rows = [
            CriticAgreement.Row(id: 1, favorite: true, audience: 90, without: critique(50, forecast: 10), with: critique(90, forecast: 90)),
            .init(id: 2, favorite: false, audience: 50, without: critique(50, forecast: 50), with: critique(70, forecast: 50)),
            .init(id: 3, favorite: false, audience: 10, without: critique(90, forecast: 90), with: critique(30, forecast: 10))]
        let pairs: [CriticAgreement.Pair] = [.init(chosen: 1, rejected: 2), .init(chosen: 2, rejected: 3), .init(chosen: 1, rejected: 99)]
        let before = CriticAgreement.metrics(rows: rows, pairs: pairs, withBrief: false)
        let after = CriticAgreement.metrics(rows: rows, pairs: pairs, withBrief: true)
        #expect(before.pairCount == 2 && before.pairwise == 0)
        #expect(after.pairwise == 1 && after.favoriteGap == 40)
        #expect(after.scoreSpearman == 1 && before.forecastSpearman == -1 && after.forecastSpearman == 1)
        #expect(CriticAgreement.keep(without: before, with: after))
        #expect(CriticAgreement.report(rows: rows, pairs: pairs, brief: CriticBriefFixtures.brief()).text.contains("generated:1"))
    }

    @Test func spearmanHandlesTiesAndInsufficientEvidence() {
        #expect(CriticAgreement.spearman([1, 2, 2, 4], [10, 20, 20, 40]) == 1)
        #expect(CriticAgreement.spearman([1, 2, 3], [30, 20, 10]) == -1)
        #expect(CriticAgreement.spearman([1, 1], [2, 3]) == nil)
        #expect(CriticAgreement.spearman([], []) == nil)
        #expect(CriticAgreement.spearman([1], [1]) == nil)
    }

    @Test func exactKeepThresholdsAndFallback() {
        var before = CriticAgreement.Metrics(pairCount: 8, pairwise: 0.5, scoreSpearman: 0.1)
        var after = CriticAgreement.Metrics(pairCount: 8, pairwise: 0.6, scoreSpearman: 0.2)
        #expect(CriticAgreement.keep(without: before, with: after))
        after.pairwise = 0.59; after.scoreSpearman = 1
        #expect(!CriticAgreement.keep(without: before, with: after))
        before.pairCount = 7; after.pairCount = 7; after.scoreSpearman = 0.25
        #expect(CriticAgreement.keep(without: before, with: after))
        after.scoreSpearman = 0.249
        #expect(!CriticAgreement.keep(without: before, with: after))
        after.scoreSpearman = nil
        #expect(!CriticAgreement.keep(without: before, with: after))
    }

    @Test func holdoutExcludesTeachersSiblingsAndMissingFiles() {
        let videos = (1...30).map { Fixtures.generatedVideo(id: Int64($0), batchID: $0 <= 2 ? "teacher" : nil) }
        let held = CriticAgreement.holdout(videos: videos, exemplarIDs: ["generated:1"],
            existingPaths: Set(videos.filter { $0.id != 30 }.map(\.path)))
        #expect(held.count == 24 && held.first?.id == 29)
        #expect(!held.contains { $0.id <= 2 || $0.id == 30 })
    }

    @Test func gateIsBoundToMeasuredBrief() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CriticBriefStore(profile: Fixtures.brand(), root: folder)
        var brief = CriticBriefFixtures.brief()
        #expect(!store.enabledByDefault(brief))
        try store.saveDecision(.init(briefKey: brief.key, measuredAt: .now, passed: true, reportPath: "report", briefBuiltAt: brief.builtAt))
        #expect(store.enabledByDefault(brief))
        brief.builtAt = .now
        #expect(!store.enabledByDefault(brief))
        brief.key = "different"
        #expect(!store.enabledByDefault(brief))
    }
}
