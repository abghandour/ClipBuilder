import Foundation

extension AppStore {
    func runMissingAnalysisPasses(video: VideoRecord, request: AnalysisRequest, run: AnalysisRun, missing: [String]) async throws {
        guard let database else { return }
        var video = video
        video.videoType = request.videoType
        let profile = try await analysisProfile(for: request, current: activeProfile)
        let podcast = AISettingsJSON.decode(PodcastSettings.self, request.podcastJSON) ?? podcastEditingSettings
        try await AnalysisRequestContext.$current.withValue(request) {
            // Dependencies first. No scenes pass is started here.
            for name in ["transcript", "people", "exchanges", "fightScore"] where missing.contains(name) {
                try Task.checkCancellation()
                analysisStage = "running missing \(name)"
                guard let kind = AnalysisPassRecord.Pass(rawValue: name) else { continue }
                if kind == .fightScore {
                    _ = try await analyzer.scoreFightAction(video: video, profile: profile,
                        database: database, runKey: run.runKey, log: logSink(\.analysisLog))
                    let receipts = try await database.fetchAnalysisPasses()
                    guard receipts.last(where: { $0.videoID == video.id && $0.pass == .fightScore && $0.runKey == run.runKey })?.status == .completed else {
                        throw ScriptError.invalid("Fight scoring did not complete; it remains a missing pass.")
                    }
                    continue
                }
                let pass = try await database.startAnalysisPass(videoID: video.id, pass: kind,
                    version: request.passVersions[name] ?? 1, runKey: run.runKey)
                do {
                    switch kind {
                    case .transcript:
                        _ = try await transcription.transcribeForVideo(video: video, database: database,
                            languageCode: request.language, log: logSink(\.analysisLog))
                        try await database.markAnalysisRunTranscribed(id: run.id)
                    case .people:
                        _ = try await analyzer.detectPeopleOnly(video: video, profile: profile, database: database,
                            provider: nil, model: nil, log: logSink(\.analysisLog))
                    case .exchanges:
                        let rows = try await database.fetchTranscripts(videoID: video.id, transcriptionKey: request.transcriptKey).filter { !$0.isTranslation }
                        guard !rows.isEmpty else { throw ScriptError.invalid("The transcript required by this analysis is missing.") }
                        let turns = try await database.fetchSpeakerTurns(videoID: video.id, transcriptionKey: request.transcriptKey)
                        let outcome = try await PodcastExchangeSegmenter(ai: ai).segment(
                            segments: rows.map { TranscriptSegment(start: $0.startTime, end: $0.endTime, text: $0.text, words: $0.words) },
                            turns: turns, provider: nil, model: nil, log: logSink(\.analysisLog),
                            useLocal: request.onDevice["podcast-exchanges"] ?? false)
                        try await database.addAnalysisExchanges(run: run, ranges: PodcastAnalysisService.exchangeTagRanges(
                            outcome.exchanges, layout: video.podcastLayout.flatMap(PodcastLayout.init(rawValue:)) ?? .singleCamera, highlightThreshold: podcast.highlightThreshold))
                    default: break
                    }
                    try await database.finishAnalysisPass(pass, status: .completed)
                } catch {
                    try? await database.finishAnalysisPass(pass, status: error is CancellationError ? .cancelled : .failed)
                    throw error
                }
            }
        }
    }
}
