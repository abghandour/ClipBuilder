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

    private func pass(version: Int, status: AnalysisPassRecord.Status = .completed,
                      kind: AnalysisPassRecord.Pass = .fightScore, startedAt: String = "1793480000.000000000") -> AnalysisPassRecord {
        AnalysisPassRecord(videoID: 1, pass: kind, version: version, status: status,
                           startedAt: startedAt, completedAt: nil, note: nil)
    }

    @Test("Expected steps follow the file type; untyped takes the visual pass")
    func expectedByType() {
        #expect(AnalysisSteps.expected(for: .podcast) == [.people, .transcript, .speakerNames, .exchanges])
        #expect(AnalysisSteps.expected(for: .interview) == [.people, .transcript, .speakerNames, .exchanges])
        #expect(AnalysisSteps.expected(for: .fight) == [.people, .scenes, .fightScore])
        #expect(AnalysisSteps.expected(for: .recap) == [.people, .scenes, .transcript, .fightScore])
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
        // A transcript in the wrong language or too thin is still a missing step.
        var stale = done
        stale.transcriptUsable = false
        #expect(AnalysisSteps.missing(video: video(.training), report: stale, peopleCount: 2, passes: []) == [.transcript])
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

    @Test("A score taken before the scenes were rebuilt is outdated; recaps expect scoring too")
    func fightScoreFreshness() {
        let fight = video(.fight, peopleDetected: true)
        let done = report(hasRun: true, state: .upToDate)
        let olderScore = [pass(version: 2, startedAt: "1793480000.0"), pass(version: 1, kind: .scenes, startedAt: "1793485000.0")]
        #expect(AnalysisSteps.missing(video: fight, report: done, peopleCount: 1, passes: olderScore) == [.fightScore])
        #expect(AnalysisSteps.fightScoreOutdated(videoID: 1, passes: olderScore))
        #expect(AnalysisCoverage.fightMessage(videoID: 1, passes: olderScore, legacyEvents: []) == "scored v2 · scenes changed since")
        // A re-score after the scenes, even without a run key, is current again.
        let rescored = olderScore + [pass(version: 2, startedAt: "1793486000.0")]
        #expect(AnalysisSteps.missing(video: fight, report: done, peopleCount: 1, passes: rescored).isEmpty)
        #expect(!AnalysisSteps.fightScoreOutdated(videoID: 1, passes: rescored))
        // The same-batch order (scenes stamped a second before the score) is current.
        let sameBatch = [pass(version: 1, kind: .scenes, startedAt: "1793469243.8"), pass(version: 2, startedAt: "1793469244.9")]
        #expect(AnalysisSteps.missing(video: fight, report: done, peopleCount: 1, passes: sameBatch).isEmpty)
        // Scenes passes of another video do not age this score; no scenes pass at all keeps it.
        var other = pass(version: 1, kind: .scenes, startedAt: "1793490000.0")
        other.videoID = 2
        #expect(AnalysisSteps.missing(video: fight, report: done, peopleCount: 1, passes: [pass(version: 2), other]).isEmpty)
        #expect(!AnalysisSteps.fightScoreOutdated(videoID: 1, passes: []))
        let recap = video(.recap, peopleDetected: true)
        #expect(AnalysisSteps.missing(video: recap, report: report(hasRun: true, hasTranscript: true, state: .upToDate),
                                      peopleCount: 1, passes: []) == [.fightScore])
    }

    @Test("Button title pluralizes")
    func title() {
        #expect(AnalysisSteps.buttonTitle(count: 1) == "Analyze (1 step)")
        #expect(AnalysisSteps.buttonTitle(count: 3) == "Analyze (3 steps)")
    }

    @Test("Suspicious naming adds one in-place step to talking footage only")
    func speakerNames() {
        let done = report(hasRun: true, hasTranscript: true, state: .upToDate)
        let suspicious = SpeakerClusterNaming.Verdict(reasons: ["Shared name"])
        for type in [VideoType.podcast, .interview] {
            #expect(AnalysisSteps.missing(video: video(type), report: done, peopleCount: 2, passes: [],
                                          speakerNaming: suspicious) == [.speakerNames])
            #expect(AnalysisSteps.missing(video: video(type), report: done, peopleCount: 2, passes: [],
                                          speakerNaming: .init(reasons: [])).isEmpty)
        }
        #expect(AnalysisSteps.missing(video: video(.training), report: done, peopleCount: 2, passes: [],
                                      speakerNaming: suspicious).isEmpty)
        #expect(AnalysisSteps.Step.speakerNames.title == "Name speakers")
        #expect(!AnalysisSteps.Step.speakerNames.needsBatch)
    }
}

@Suite("Analysis step batch")
struct AnalysisStepBatchTests {
    @Test("Speaker mapping is awaited in place even when exchanges also need a batch")
    func speakerNamesBeforeBatch() {
        let parts = AnalysisStepBatch.partition([1: [.speakerNames], 2: [.people, .speakerNames, .exchanges]])
        #expect(parts.inPlace == [1: [.speakerNames], 2: [.speakerNames]])
        #expect(parts.batch == [2: [.people, .exchanges]])
        let run = AnalysisStepBatch(batch: parts.batch, syncWhenDone: true)
        #expect(run.next(inPlaceBusy: true, analyzing: false) == .wait)
    }

    @Test("Summary counts files with missing steps and sums their steps; the label reads N files · Analyze N steps")
    func summary() {
        let missing: [Int64: [AnalysisSteps.Step]] = [1: [.people, .scenes], 2: [.transcript], 3: []]
        let summary = AnalysisSteps.summary(missing)
        #expect(summary.files == 2)
        #expect(summary.steps == 3)
        #expect(AnalysisSteps.batchButtonTitle(files: 2, steps: 3) == "2 files · Analyze 3 steps")
        #expect(AnalysisSteps.batchButtonTitle(files: 1, steps: 1) == "1 file · Analyze 1 step")
    }

    @Test("Files needing scenes or exchanges go to the batch; the rest run in place")
    func partition() {
        let missing: [Int64: [AnalysisSteps.Step]] = [1: [.people, .transcript], 2: [.transcript, .exchanges], 3: [.fightScore], 4: []]
        let parts = AnalysisStepBatch.partition(missing)
        #expect(Set(parts.inPlace.keys) == [1, 3])
        #expect(Set(parts.batch.keys) == [2])
    }

    @Test("In-place work finishes before the batch starts, and the run ends with a team sync")
    func phases() {
        var run = AnalysisStepBatch(batch: [2: [.exchanges]], syncWhenDone: true)
        #expect(run.next(inPlaceBusy: true, analyzing: false) == .wait)
        #expect(run.next(inPlaceBusy: false, analyzing: false) == .startBatch([2: [.exchanges]]))
        run.starting = true
        #expect(run.next(inPlaceBusy: false, analyzing: false) == .wait)
        run.starting = false
        run.batch = [:]
        #expect(run.next(inPlaceBusy: false, analyzing: true) == .wait)
        #expect(run.next(inPlaceBusy: false, analyzing: false) == .finish(sync: true))
        #expect(AnalysisStepBatch(batch: [:], syncWhenDone: false).next(inPlaceBusy: false, analyzing: false) == .finish(sync: false))
    }
}
