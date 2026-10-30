import Foundation
import Testing
@testable import Clip_Builder

@Suite("Express per-kind run cache")
struct MiniWizardRunCacheTests {
    private func run(_ kind: MiniWizardFlow.FootageKind, projectID: Int64 = 1,
                     videoID: Int64 = 1, length: MiniWizardFlow.Length = .automatic) -> MiniWizardRun {
        MiniWizardRun(projectID: projectID, video: Fixtures.video(id: videoID), footageKind: kind,
                      length: length, batchID: kind.rawValue, candidates: [], options: WizardOptions())
    }

    @Test func returningToQAReusesItsRunAndKeepsTranscriptEdits() {
        var runs: [MiniWizardFlow.FootageKind: MiniWizardRun] = [.qa: run(.qa)]
        runs[.qa]?.requestedCard = .settings
        // Q&A -> Transcript -> Q&A: retention must never evict the other kind.
        MiniWizardRunCache.retain(&runs, projectID: 1, videoID: 1, length: .automatic)
        runs[.transcript] = run(.transcript)
        runs[.transcript]?.transcript = MiniWizardTranscript(rows: [], labels: [:], picks: [
            TranscriptPick(id: 9, videoID: 1, position: 0, start: 2, end: 5,
                           originalStart: 2, originalEnd: 5, sceneID: nil)
        ])
        MiniWizardRunCache.retain(&runs, projectID: 1, videoID: 1, length: .automatic)
        #expect(runs.count == 2)
        #expect(runs[.qa]?.batchID == "qa")
        #expect(runs[.qa]?.requestedCard == .settings)
        #expect(runs[.transcript]?.transcript?.picks.first?.id == 9)
    }

    @Test func lengthChangeInvalidatesOnlyHighlights() {
        var runs = Dictionary(uniqueKeysWithValues: MiniWizardFlow.FootageKind.allCases.map {
            ($0, run($0, length: $0 == .highlights ? .fifteen : .automatic))
        })
        MiniWizardRunCache.retain(&runs, projectID: 1, videoID: 1, length: .thirty)
        #expect(runs[.highlights] == nil)
        #expect(Set(runs.keys) == [.qa, .transcript, .fightMetrics])
    }

    @Test func switchingSourceOrProjectDropsEveryOldKind() {
        let originals = Dictionary(uniqueKeysWithValues: MiniWizardFlow.FootageKind.allCases.map { ($0, run($0)) })
        var runs = originals
        MiniWizardRunCache.retain(&runs, projectID: 1, videoID: 2, length: .automatic)
        #expect(runs.isEmpty)
        runs = originals
        MiniWizardRunCache.retain(&runs, projectID: 2, videoID: 1, length: .automatic)
        #expect(runs.isEmpty)
    }

    @Test func transcriptInvalidationPreservesIndependentKindsAndOtherVideos() {
        var runs: [MiniWizardFlow.FootageKind: MiniWizardRun] = [
            .qa: run(.qa), .transcript: run(.transcript),
            .fightMetrics: run(.fightMetrics), .highlights: run(.highlights)
        ]
        runs[.fightMetrics]?.requestedCard = .settings
        MiniWizardRunCache.invalidateTranscripts(&runs, videoIDs: [2])
        #expect(runs.count == 4)
        MiniWizardRunCache.invalidateTranscripts(&runs, videoIDs: [1])
        #expect(runs[.qa] == nil)
        #expect(runs[.transcript] == nil)
        #expect(runs[.highlights]?.batchID == "highlights")
        #expect(runs[.fightMetrics]?.requestedCard == .settings)
    }
}
