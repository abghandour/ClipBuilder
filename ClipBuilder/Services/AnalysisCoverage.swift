import Foundation

/// Coverage comes from saved runs and content, never a visual-analysis timestamp.
nonisolated enum AnalysisCoverage {
    nonisolated struct Report: Equatable, Sendable {
        var qaCount: Int
        var hasTranscript: Bool
        var hasRun: Bool
        var latestPipeline: Int?
        var state: State
    }

    nonisolated enum State: Equatable, Sendable {
        case upToDate
        case needsAnalysis
        case transcriptOnly
        case missingExchanges
        case outdated(stage: String)
        case untyped
    }

    nonisolated enum Action: Equatable, Sendable {
        case analyze, runExchanges, setType

        var title: String {
            switch self {
            case .analyze: "Analyze"
            case .runExchanges: "Run exchanges"
            case .setType: "Set type"
            }
        }
    }

    static func report(video: VideoRecord, runs: [AnalysisRun], scenes: [SceneRecord],
                       transcriptCount: Int) -> Report {
        let latest = runs.filter { $0.videoID == video.id }.max {
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? "") < ($1.createdAt ?? "") }
            return $0.id < $1.id
        }
        let qaCount = scenes.count { $0.videoID == video.id && !$0.ignored && $0.tags.contains("q&a") }
        let pipeline = AISettingsJSON.decode(AnalysisRunSettings.self, latest?.settingsJSON)?.pipeline
        let state: State
        if latest == nil {
            state = transcriptCount > 0 ? .transcriptOnly : .needsAnalysis
        } else if video.type == nil && video.duration < 300 && qaCount == 0 {
            state = .untyped
        } else if video.type?.usesPodcastPass == true && qaCount == 0 {
            state = .missingExchanges
        } else if (pipeline ?? 0) < AnalysisPipeline.current(for: video.type) {
            state = .outdated(stage: video.type?.usesPodcastPass == true ? "Podcast exchanges" : "Visual analysis")
        } else {
            state = .upToDate
        }
        return Report(qaCount: qaCount, hasTranscript: transcriptCount > 0, hasRun: latest != nil,
                      latestPipeline: pipeline, state: state)
    }

    static func action(for state: State) -> Action? {
        switch state {
        case .upToDate: nil
        case .needsAnalysis, .transcriptOnly: .analyze
        case .missingExchanges: .runExchanges
        case .outdated(let stage): stage == "Podcast exchanges" ? .runExchanges : .analyze
        case .untyped: .setType
        }
    }

    static func message(for state: State, type: VideoType?) -> String {
        switch state {
        case .upToDate:
            "Analysis is up to date."
        case .needsAnalysis:
            "This recording has not been analyzed. Choose Analyze to run its analysis stages."
        case .transcriptOnly:
            "This recording has a transcript but no analysis run. Choose Analyze to add scenes and, for Podcast or Interview, Q&A exchanges."
        case .missingExchanges:
            "Exchanges were never grouped for this \(type?.label.lowercased() ?? "recording"). Choose Run exchanges to group podcast exchanges and add the Q&A view."
        case .outdated(let stage):
            "\(stage) predates the current pipeline. Choose \(action(for: state)?.title ?? "Analyze") to update it."
        case .untyped:
            "This recording has no type, so Analyze cannot choose the podcast pass. Set the type to Podcast or Interview, then analyze."
        }
    }

    /// A state alone cannot distinguish an old pass from a current pass with no candidates.
    static func message(for report: Report, type: VideoType?) -> String {
        if report.state == .missingExchanges,
           (report.latestPipeline ?? 0) >= AnalysisPipeline.current(for: type) {
            return "No exchanges were found for this \(type?.label.lowercased() ?? "recording"). Choose Run exchanges to try podcast exchanges again."
        }
        return message(for: report.state, type: type)
    }
}
