import Foundation

/// The analysis steps a recording still needs, by file type, behind the
/// Sources pane's "Analyze (N steps)" footer. Renaming and video generation
/// are not analysis and never count.
nonisolated enum AnalysisSteps {
    /// True when a missing-steps batch must not start (`AppStore.isMissingStepsBatchBusy`).
    static func batchBusy(batchRunning: Bool, analyzing: Bool, detectingPeople: Bool, transcribing: Bool,
                          fightScoring: Bool, mappingSpeakers: Bool) -> Bool {
        batchRunning || analyzing || detectingPeople || transcribing || fightScoring || mappingSpeakers
    }

    enum Step: String, CaseIterable, Sendable {
        case people, scenes, transcript, speakerNames, exchanges, fightScore

        var title: String {
            switch self {
            case .people: "Detect people"
            case .scenes: "Create scenes"
            case .transcript: "Transcribe"
            case .speakerNames: "Name speakers"
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
        case .podcast, .interview: [.people, .transcript, .speakerNames, .exchanges]
        case .fight: [.people, .scenes, .fightScore]
        case .recap: [.people, .scenes, .transcript, .fightScore]
        default: [.people, .scenes, .transcript]
        }
    }

    /// Expected steps with no result yet, or one older than the current pipeline.
    static func missing(video: VideoRecord, report: AnalysisCoverage.Report,
                        peopleCount: Int, passes: [AnalysisPassRecord],
                        speakerNaming: SpeakerClusterNaming.Verdict? = nil) -> [Step] {
        expected(for: video.type).filter { step in
            switch step {
            case .people:
                peopleCount == 0 && video.peopleDetectedAt == nil
            case .transcript:
                !report.hasTranscript || !report.transcriptUsable
            case .speakerNames:
                speakerNaming?.isSuspicious == true
            case .scenes:
                !report.hasRun || report.state == .outdated(stage: "Visual analysis")
            case .exchanges:
                !report.hasRun || report.state == .missingExchanges
                    || report.state == .outdated(stage: "Podcast exchanges")
            case .fightScore:
                !fightScoreCurrent(videoID: video.id, passes: passes)
            }
        }
    }

    /// A completed current-version score that is not older than the file's
    /// latest scene analysis. Scenes drive the scoring pass, so a score
    /// taken before the scenes were rebuilt describes footage that no longer
    /// exists in the project.
    static func fightScoreCurrent(videoID: Int64, passes: [AnalysisPassRecord]) -> Bool {
        guard let score = latestFightScore(videoID: videoID, passes: passes) else { return false }
        return !fightScoreOutdated(score, videoID: videoID, passes: passes)
    }

    /// True when a current-version score exists but the scenes were rebuilt after it.
    static func fightScoreOutdated(videoID: Int64, passes: [AnalysisPassRecord]) -> Bool {
        guard let score = latestFightScore(videoID: videoID, passes: passes) else { return false }
        return fightScoreOutdated(score, videoID: videoID, passes: passes)
    }

    private static func latestFightScore(videoID: Int64, passes: [AnalysisPassRecord]) -> AnalysisPassRecord? {
        passes.filter {
            $0.videoID == videoID && $0.pass == .fightScore && $0.status == .completed
                && $0.version >= currentFightScoreVersion
        }.max { started($0) < started($1) }
    }

    private static func fightScoreOutdated(_ score: AnalysisPassRecord, videoID: Int64, passes: [AnalysisPassRecord]) -> Bool {
        guard let scenes = passes.filter({ $0.videoID == videoID && $0.pass == .scenes && $0.status == .completed })
            .max(by: { started($0) < started($1) }) else { return false }
        return started(score) < started(scenes)
    }

    /// Passes store a fractional epoch; anything else sorts first.
    private static func started(_ pass: AnalysisPassRecord) -> Double { Double(pass.startedAt) ?? 0 }

    static func buttonTitle(count: Int) -> String {
        "Analyze (\(count) step\(count == 1 ? "" : "s"))"
    }

    /// Files with at least one missing step, and the steps summed over them.
    static func summary(_ missing: [Int64: [Step]]) -> (files: Int, steps: Int) {
        let present = missing.filter { !$0.value.isEmpty }
        return (present.count, present.values.reduce(0) { $0 + $1.count })
    }

    static func batchButtonTitle(files: Int, steps: Int) -> String {
        "\(files) file\(files == 1 ? "" : "s") · Analyze \(steps) step\(steps == 1 ? "" : "s")"
    }
}

/// One press of the Sources "N files · Analyze N steps" button. In-place steps
/// (people, transcript, fight score) run first for the files that need nothing
/// else; files that need a new analyze batch wait until that work is idle, so
/// the batch's own people detection is never skipped behind the in-place run.
/// When everything is idle the profile syncs with the team, if attached, so
/// teammates receive the results instead of paying for the same AI work.
nonisolated struct AnalysisStepBatch: Sendable, Equatable {
    /// Files still waiting for their analyze batch, with the steps each needs.
    var batch: [Int64: [AnalysisSteps.Step]]
    var syncWhenDone: Bool
    /// The profile generation that started the run; a switch abandons it.
    var generation: Int = 0
    /// Phase 2's request capture is in flight; the batch stays queued until
    /// analyze actually starts, so a run that could not start is retried.
    var starting: Bool = false

    enum Action: Equatable {
        case wait
        case startBatch([Int64: [AnalysisSteps.Step]])
        case finish(sync: Bool)
    }

    static func partition(_ missing: [Int64: [AnalysisSteps.Step]])
        -> (inPlace: [Int64: [AnalysisSteps.Step]], batch: [Int64: [AnalysisSteps.Step]]) {
        var inPlace: [Int64: [AnalysisSteps.Step]] = [:]
        var batch: [Int64: [AnalysisSteps.Step]] = [:]
        for (id, steps) in missing where !steps.isEmpty {
            if steps.contains(where: \.needsBatch) {
                batch[id] = steps.filter { $0 != .speakerNames }
                if steps.contains(.speakerNames) { inPlace[id] = [.speakerNames] }
            } else {
                inPlace[id] = steps
            }
        }
        return (inPlace, batch)
    }

    /// Decide from the store's in-flight flags what happens next.
    func next(inPlaceBusy: Bool, analyzing: Bool) -> Action {
        if inPlaceBusy || analyzing || starting { return .wait }
        if !batch.isEmpty { return .startBatch(batch) }
        return .finish(sync: syncWhenDone)
    }
}
