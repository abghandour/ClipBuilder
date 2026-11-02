import Foundation

/// One chip per analysis step a recording's type expects, for the Sources
/// Status column: what each step produced, what is missing or stale, and
/// what is running. Clicking a chip that is not done runs that step and the
/// missing steps before it in pipeline order.
nonisolated enum AnalysisStepPresentation {
    enum State: Sendable, Equatable {
        /// Produced and current; the title carries the count.
        case done
        /// Expected for this type and never produced.
        case missing
        /// Produced, but by an older pipeline, another type, another
        /// transcript, or judged wrong: run again.
        case outdated
        case running
    }

    struct Chip: Sendable, Equatable, Identifiable {
        var step: AnalysisSteps.Step
        var state: State
        var title: String
        var help: String
        var id: String { step.rawValue }
    }

    struct Inputs: Sendable, Equatable {
        var type: VideoType?
        var report: AnalysisCoverage.Report
        var peopleCount: Int
        var peopleDetectedAt: String?
        var sceneCount: Int
        var qaCount: Int
        var speakerNaming: SpeakerClusterNaming.Verdict?
        /// Steps `AnalysisSteps.missing` reports for the file.
        var missing: [AnalysisSteps.Step]
        var running: Set<AnalysisSteps.Step> = []
    }

    static func chips(_ input: Inputs) -> [Chip] {
        AnalysisSteps.expected(for: input.type).compactMap { step in chip(step, input) }
    }

    private static func chip(_ step: AnalysisSteps.Step, _ input: Inputs) -> Chip? {
        if input.running.contains(step) {
            return Chip(step: step, state: .running, title: runningTitle(step), help: runningTitle(step))
        }
        let missing = input.missing.contains(step)
        switch step {
        case .people:
            if input.peopleCount > 0 {
                return Chip(step: step, state: .done, title: "\(input.peopleCount) \(input.peopleCount == 1 ? "person" : "people")",
                            help: "\(input.peopleCount) \(input.peopleCount == 1 ? "person" : "people") found")
            }
            if input.peopleDetectedAt != nil {
                return Chip(step: step, state: .done, title: "No people", help: "The people pass ran and found nobody")
            }
            return Chip(step: step, state: .missing, title: "People", help: "People not detected yet. Click to detect them.")
        case .transcript:
            if input.report.hasTranscript && !input.report.transcriptUsable {
                return Chip(step: step, state: .outdated, title: "Transcript",
                            help: "The transcript is in another language than the video, or too thin. Click to transcribe again.")
            }
            if input.report.hasTranscript {
                return Chip(step: step, state: .done, title: "Transcript", help: "Transcript ready")
            }
            return Chip(step: step, state: .missing, title: "Transcript", help: "Not transcribed yet. Click to transcribe.")
        case .speakerNames:
            if let verdict = input.speakerNaming {
                if verdict.isSuspicious {
                    return Chip(step: step, state: .outdated, title: "Speakers", help: verdict.reason + " Click to name speakers again.")
                }
                return Chip(step: step, state: .done, title: "Speakers", help: "Each line has its speaker")
            }
            return Chip(step: step, state: .missing, title: "Speakers",
                        help: input.report.hasTranscript ? "Speakers not named yet. Click to name them."
                            : "Speakers are named after transcription. Click to transcribe and name them.")
        case .scenes:
            if missing, input.report.hasRun {
                return Chip(step: step, state: .outdated, title: sceneTitle(input.sceneCount), help: outdatedHelp(input.report, "Click to analyze again."))
            }
            if input.report.hasRun {
                return Chip(step: step, state: .done, title: sceneTitle(input.sceneCount), help: "Scenes from the active analysis batch")
            }
            return Chip(step: step, state: .missing, title: "Scenes", help: "Not analyzed yet. Click to create scenes.")
        case .exchanges:
            if missing, input.report.hasRun {
                return Chip(step: step, state: .outdated, title: input.qaCount > 0 ? "\(input.qaCount) Q&A" : "Q&A",
                            help: outdatedHelp(input.report, "Click to group exchanges again."))
            }
            if input.report.hasRun, input.qaCount > 0 {
                return Chip(step: step, state: .done, title: "\(input.qaCount) Q&A", help: "\(input.qaCount) Q&A exchanges")
            }
            return Chip(step: step, state: .missing, title: "Q&A",
                        help: input.report.hasTranscript ? "Exchanges not grouped yet. Click to group them."
                            : "Exchanges are grouped from the transcript. Click to transcribe and group them.")
        case .fightScore:
            // Fight types keep the fight stats cell, which carries versions
            // and the re-score control.
            return nil
        }
    }

    /// The chip's step and every missing step before it in pipeline order.
    static func stepsToRun(for step: AnalysisSteps.Step, type: VideoType?, missing: [AnalysisSteps.Step]) -> [AnalysisSteps.Step] {
        let order = AnalysisSteps.expected(for: type)
        guard let index = order.firstIndex(of: step) else { return [] }
        var steps = order.prefix(index).filter { missing.contains($0) }
        steps.append(step)
        return steps
    }

    private static func sceneTitle(_ count: Int) -> String { count > 0 ? "\(count) scene\(count == 1 ? "" : "s")" : "Scenes" }

    private static func runningTitle(_ step: AnalysisSteps.Step) -> String {
        switch step {
        case .people: "Detecting people…"
        case .scenes: "Analyzing…"
        case .transcript: "Transcribing…"
        case .speakerNames: "Naming speakers…"
        case .exchanges: "Grouping exchanges…"
        case .fightScore: "Scoring…"
        }
    }

    private static func outdatedHelp(_ report: AnalysisCoverage.Report, _ action: String) -> String {
        switch report.state {
        case .outdated(let stage) where stage == AnalysisCoverage.typeChangedStage:
            "Analyzed as \(report.ranAs?.label ?? "another type"); the type changed since. \(action)"
        case .outdated(let stage):
            "\(stage) predates the current pipeline. \(action)"
        case .missingExchanges:
            "No exchanges were grouped. \(action)"
        default:
            action
        }
    }
}
