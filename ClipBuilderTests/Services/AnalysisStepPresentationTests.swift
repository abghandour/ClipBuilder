import Foundation
import Testing
@testable import Clip_Builder

@Suite("Analysis step chips")
struct AnalysisStepPresentationTests {
    private func report(hasRun: Bool, hasTranscript: Bool, usable: Bool = true,
                        state: AnalysisCoverage.State = .upToDate, ranAs: VideoType? = nil) -> AnalysisCoverage.Report {
        AnalysisCoverage.Report(qaCount: 0, hasTranscript: hasTranscript, transcriptUsable: usable, hasRun: hasRun,
                                latestPipeline: nil, ranAs: ranAs, state: state)
    }

    @Test("an interview shows people, transcript, speakers and Q&A in pipeline order, each with its state")
    func interviewChips() {
        let fresh = AnalysisStepPresentation.chips(.init(
            type: .interview, report: report(hasRun: false, hasTranscript: false), peopleCount: 0, peopleDetectedAt: nil,
            sceneCount: 0, qaCount: 0, speakerNaming: nil,
            missing: [.people, .transcript, .speakerNames, .exchanges]))
        #expect(fresh.map(\.step) == [.people, .transcript, .speakerNames, .exchanges])
        #expect(fresh.allSatisfy { $0.state == .missing })
        #expect(fresh[2].help.contains("after transcription"))

        let done = AnalysisStepPresentation.chips(.init(
            type: .interview, report: report(hasRun: true, hasTranscript: true), peopleCount: 2, peopleDetectedAt: "t",
            sceneCount: 4, qaCount: 3, speakerNaming: .init(reasons: []), missing: []))
        #expect(done.map(\.state) == [.done, .done, .done, .done])
        #expect(done.map(\.title) == ["2 people", "Transcript", "Speakers", "3 Q&A"])
    }

    @Test("a people pass that found nobody is done, not missing; a suspicious speaker map is outdated")
    func peopleAndSpeakers() {
        let chips = AnalysisStepPresentation.chips(.init(
            type: .podcast, report: report(hasRun: true, hasTranscript: true), peopleCount: 0, peopleDetectedAt: "2026-11-02",
            sceneCount: 0, qaCount: 2, speakerNaming: .init(reasons: ["Shared name."]), missing: [.speakerNames]))
        #expect(chips[0].state == .done && chips[0].title == "No people")
        #expect(chips[2].state == .outdated && chips[2].help.hasPrefix("Shared name."))
    }

    @Test("a transcript in the wrong language, a type change and running work show as outdated or running")
    func outdatedAndRunning() {
        let wrongLanguage = AnalysisStepPresentation.chips(.init(
            type: .other, report: report(hasRun: true, hasTranscript: true, usable: false), peopleCount: 1, peopleDetectedAt: "t",
            sceneCount: 5, qaCount: 0, speakerNaming: nil, missing: [.transcript]))
        #expect(wrongLanguage.map(\.step) == [.people, .scenes, .transcript])
        #expect(wrongLanguage[2].state == .outdated && wrongLanguage[2].help.contains("another language"))
        #expect(wrongLanguage[1].state == .done && wrongLanguage[1].title == "5 scenes")

        let typeChanged = AnalysisStepPresentation.chips(.init(
            type: .fight, report: report(hasRun: true, hasTranscript: false, state: .outdated(stage: AnalysisCoverage.typeChangedStage), ranAs: .interview),
            peopleCount: 1, peopleDetectedAt: "t", sceneCount: 3, qaCount: 0, speakerNaming: nil, missing: [.scenes, .fightScore]))
        #expect(typeChanged.map(\.step) == [.people, .scenes], "fight scoring keeps its own cell")
        #expect(typeChanged[1].state == .outdated && typeChanged[1].help.contains("Analyzed as Interview"))

        let running = AnalysisStepPresentation.chips(.init(
            type: .interview, report: report(hasRun: false, hasTranscript: false), peopleCount: 0, peopleDetectedAt: nil,
            sceneCount: 0, qaCount: 0, speakerNaming: nil, missing: [.people, .transcript, .speakerNames, .exchanges],
            running: [.transcript]))
        #expect(running[1].state == .running && running[1].title == "Transcribing…")
    }

    @Test("clicking a chip runs it with the missing steps before it, never the ones after")
    func stepsToRun() {
        let missing: [AnalysisSteps.Step] = [.transcript, .speakerNames, .exchanges]
        #expect(AnalysisStepPresentation.stepsToRun(for: .speakerNames, type: .interview, missing: missing) == [.transcript, .speakerNames])
        #expect(AnalysisStepPresentation.stepsToRun(for: .exchanges, type: .interview, missing: missing) == [.transcript, .speakerNames, .exchanges])
        #expect(AnalysisStepPresentation.stepsToRun(for: .transcript, type: .interview, missing: missing) == [.transcript])
        #expect(AnalysisStepPresentation.stepsToRun(for: .people, type: .interview, missing: missing) == [.people])
        #expect(AnalysisStepPresentation.stepsToRun(for: .fightScore, type: .interview, missing: missing).isEmpty)
    }
}
