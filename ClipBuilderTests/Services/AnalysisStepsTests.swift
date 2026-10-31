import Foundation
import Testing
@testable import Clip_Builder

@Suite("Analysis steps footer")
struct AnalysisStepsTests {
    private func video(_ type: VideoType?, peopleDetected: Bool = false) -> VideoRecord {
        var video = Fixtures.video()
        video.videoType = type?.rawValue
        video.peopleDetectedAt = peopleDetected ? "2026-10-31 10:00:00" : nil
        return video
    }

    private func report(hasRun: Bool = false, hasTranscript: Bool = false,
                        state: AnalysisCoverage.State = .needsAnalysis) -> AnalysisCoverage.Report {
        AnalysisCoverage.Report(qaCount: 0, hasTranscript: hasTranscript, hasRun: hasRun,
                                latestPipeline: hasRun ? 1 : nil, state: state)
    }

    private func pass(version: Int, status: AnalysisPassRecord.Status = .completed) -> AnalysisPassRecord {
        AnalysisPassRecord(videoID: 1, pass: .fightScore, version: version, status: status,
                           startedAt: "2026-10-31 10:00:00", completedAt: nil, note: nil)
    }

    @Test("Expected steps follow the file type; untyped takes the visual pass")
    func expectedByType() {
        #expect(AnalysisSteps.expected(for: .podcast) == [.people, .transcript, .exchanges])
        #expect(AnalysisSteps.expected(for: .interview) == [.people, .transcript, .exchanges])
        #expect(AnalysisSteps.expected(for: .fight) == [.people, .scenes, .fightScore])
        #expect(AnalysisSteps.expected(for: .recap) == [.people, .scenes, .transcript])
        #expect(AnalysisSteps.expected(for: nil) == [.people, .scenes, .transcript])
    }

    @Test("A fresh recording is missing every expected step")
    func fresh() {
        #expect(AnalysisSteps.missing(video: video(.training), report: report(), peopleCount: 0, passes: [])
                == [.people, .scenes, .transcript])
        #expect(AnalysisSteps.missing(video: video(.podcast), report: report(), peopleCount: 0, passes: [])
                == [.people, .transcript, .exchanges])
    }

    @Test("Done steps drop out: a roster or the people stamp, a transcript, a current batch")
    func partial() {
        let done = report(hasRun: true, hasTranscript: true, state: .upToDate)
        #expect(AnalysisSteps.missing(video: video(.training), report: done, peopleCount: 2, passes: []).isEmpty)
        #expect(AnalysisSteps.missing(video: video(.training, peopleDetected: true), report: done, peopleCount: 0, passes: []).isEmpty)
        #expect(AnalysisSteps.missing(video: video(.training), report: done, peopleCount: 0, passes: []) == [.people])
        let transcriptOnly = report(hasTranscript: true, state: .transcriptOnly)
        #expect(AnalysisSteps.missing(video: video(.training), report: transcriptOnly, peopleCount: 1, passes: []) == [.scenes])
    }

    @Test("Outdated or missing exchanges count as missing for talking footage")
    func exchanges() {
        let roster = video(.interview, peopleDetected: true)
        #expect(AnalysisSteps.missing(video: roster, report: report(hasRun: true, hasTranscript: true, state: .missingExchanges),
                                      peopleCount: 1, passes: []) == [.exchanges])
        #expect(AnalysisSteps.missing(video: roster, report: report(hasRun: true, hasTranscript: true, state: .outdated(stage: "Podcast exchanges")),
                                      peopleCount: 1, passes: []) == [.exchanges])
        #expect(AnalysisSteps.missing(video: roster, report: report(hasRun: true, hasTranscript: true, state: .upToDate),
                                      peopleCount: 1, passes: []).isEmpty)
    }

    @Test("Fight scoring is missing until a completed v2 pass exists")
    func fightScoring() {
        let fight = video(.fight, peopleDetected: true)
        let done = report(hasRun: true, state: .upToDate)
        #expect(AnalysisSteps.missing(video: fight, report: done, peopleCount: 1, passes: []) == [.fightScore])
        #expect(AnalysisSteps.missing(video: fight, report: done, peopleCount: 1, passes: [pass(version: 1)]) == [.fightScore])
        #expect(AnalysisSteps.missing(video: fight, report: done, peopleCount: 1, passes: [pass(version: 2, status: .failed)]) == [.fightScore])
        #expect(AnalysisSteps.missing(video: fight, report: done, peopleCount: 1, passes: [pass(version: 2)]).isEmpty)
        #expect(AnalysisSteps.missing(video: fight, report: report(hasRun: true, state: .outdated(stage: "Visual analysis")),
                                      peopleCount: 1, passes: [pass(version: 2)]) == [.scenes])
    }

    @Test("Button title pluralizes")
    func title() {
        #expect(AnalysisSteps.buttonTitle(count: 1) == "Analyze (1 step)")
        #expect(AnalysisSteps.buttonTitle(count: 3) == "Analyze (3 steps)")
    }
}
