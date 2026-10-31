import Foundation

/// The analysis steps a recording still needs, by file type, behind the
/// Sources pane's "Analyze (N steps)" footer. Renaming and video generation
/// are not analysis and never count.
nonisolated enum AnalysisSteps {
    enum Step: String, CaseIterable, Sendable {
        case people, scenes, transcript, exchanges, fightScore

        var title: String {
            switch self {
            case .people: "Detect people"
            case .scenes: "Create scenes"
            case .transcript: "Transcribe"
            case .exchanges: "Group exchanges"
            case .fightScore: "Score fight action"
            }
        }

        /// Steps that land in a new analyze batch; the rest update the video in place.
        var needsBatch: Bool { self == .scenes || self == .exchanges }
    }

    /// Fight scoring below this version predates attempts and counts as missing.
    static let currentFightScoreVersion = 2

    /// What the pipeline produces for a type. Podcast and Interview take the
    /// podcast pass (transcript first, then exchanges); Fight adds scoring;
    /// everything else, untyped included, gets the visual pass.
    static func expected(for type: VideoType?) -> [Step] {
        switch type {
        case .podcast, .interview: [.people, .transcript, .exchanges]
        case .fight: [.people, .scenes, .fightScore]
        default: [.people, .scenes, .transcript]
        }
    }

    /// Expected steps with no result yet, or one older than the current pipeline.
    static func missing(video: VideoRecord, report: AnalysisCoverage.Report,
                        peopleCount: Int, passes: [AnalysisPassRecord]) -> [Step] {
        expected(for: video.type).filter { step in
            switch step {
            case .people:
                peopleCount == 0 && video.peopleDetectedAt == nil
            case .transcript:
                !report.hasTranscript
            case .scenes:
                !report.hasRun || report.state == .outdated(stage: "Visual analysis")
            case .exchanges:
                !report.hasRun || report.state == .missingExchanges
                    || report.state == .outdated(stage: "Podcast exchanges")
            case .fightScore:
                !passes.contains {
                    $0.videoID == video.id && $0.pass == .fightScore && $0.status == .completed
                        && $0.version >= currentFightScoreVersion
                }
            }
        }
    }

    static func buttonTitle(count: Int) -> String {
        "Analyze (\(count) step\(count == 1 ? "" : "s"))"
    }
}
