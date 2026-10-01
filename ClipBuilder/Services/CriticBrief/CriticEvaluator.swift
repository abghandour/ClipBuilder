import Foundation

nonisolated enum CriticEvaluator {
    struct Result: Sendable {
        var reportURL: URL
        var passed: Bool
        var count: Int
        var summary: String {
            "Evaluated \(count) reels. \(passed ? "Brief enabled" : "Default: without brief"). Report: \(reportURL.path)"
        }
    }

    static func evaluate(database: Database, profile: BrandProfile, ai: AIService,
                         benchmarks: AccountBenchmarks?,
                         emit: @escaping @Sendable (String) -> Void) async throws -> Result {
        let store = CriticBriefStore(profile: profile)
        guard let brief = try await AppJobWork.run({ store.load() }) else {
            throw AppJobEmptyResult(message: "Refresh Critic Brief before evaluating it.")
        }
        let frames = try await AppJobWork.run { try store.frames(for: brief) }
        let currentPool = try await CriticExemplars.select(database: database, profile: profile, emit: emit)
        let candidates = try await database.criticExemplarCandidates()
        let videos = try await database.fetchGeneratedVideos()
        let pairs = try await database.criticPreferencePairs()
        let teacherIDs = Set(brief.exemplars.map(\.id) + currentPool.exemplars.map(\.id))
        let holdout = try await AppJobWork.run {
            CriticAgreement.holdout(videos: videos, exemplarIDs: teacherIDs,
                existingPaths: Set(videos.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)),
                exemplarPaths: Set(candidates.filter { teacherIDs.contains($0.id) }.map(\.path)))
        }
        guard !holdout.isEmpty else {
            throw AppJobEmptyResult(message: "No labeled local reels outside the exemplar pool. Generate and rate more reels first.")
        }
        let sceneMap = Dictionary(uniqueKeysWithValues: try await database.fetchScenes(includeExcluded: true).map { ($0.id, $0) })
        var rows: [CriticAgreement.Row] = []
        emit("Evaluating \(holdout.count) reels: \(holdout.count * 2) critique calls, about 12 frames each.")
        for (index, video) in holdout.enumerated() {
            try Task.checkCancellation()
            var options = AISettingsJSON.decode(WizardRunSettings.self, video.settingsJSON)?.options ?? WizardOptions()
            options.accountBenchmarks = benchmarks
            let plan = plan(for: video)
            emit("Evaluating reel \(index + 1)/\(holdout.count): \(video.filename)")
            // Neither condition receives earlier scores or labels. Do not replace saved critiques.
            let without = try await ReelCritic.critique(video: video.url, duration: video.duration,
                plan: plan, sceneMap: sceneMap, options: options, profile: profile,
                attempt: 1, previous: [], ai: ai, emit: emit, database: database, generatedID: video.id)
            let with = try await ReelCritic.critique(video: video.url, duration: video.duration,
                plan: plan, sceneMap: sceneMap, options: options, profile: profile,
                attempt: 1, previous: [], ai: ai, emit: emit, database: database, generatedID: video.id,
                brief: brief, referenceFrames: frames)
            rows.append(.init(id: video.id, favorite: video.favorite, audience: video.audiencePercentile,
                              without: without, with: with))
            emit("PROGRESS:\(Double(index + 1) / Double(holdout.count))")
        }
        try Task.checkCancellation()
        let report = CriticAgreement.report(rows: rows, pairs: pairs, brief: brief)
        return try await AppJobWork.run {
            let directory = SettingsStore.cacheDirectory.appendingPathComponent("on-device-agreement", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Date.now.ISO8601Format().replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("critic-agreement-\(stamp)-\(UUID().uuidString.prefix(8)).md")
            try report.text.write(to: url, atomically: true, encoding: .utf8)
            try Task.checkCancellation()
            try store.saveDecision(.init(briefKey: brief.key, measuredAt: .now, passed: report.passed, reportPath: url.path, briefBuiltAt: brief.builtAt))
            return Result(reportURL: url, passed: report.passed, count: holdout.count)
        }
    }

    static func plan(for video: GeneratedVideoRecord) -> WizardPlan {
        let objects = video.planClipsJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let document = AISettingsJSON.decode(TimelineDocument.self, video.timelineJSON)
        var clips = objects.compactMap { object -> WizardPlanClip? in
            guard let id = (object["scene_id"] as? NSNumber)?.int64Value,
                  let start = (object["start"] as? NSNumber)?.doubleValue,
                  let end = (object["end"] as? NSNumber)?.doubleValue, end > start else { return nil }
            var clip = WizardPlanClip(sceneID: id, start: start, end: end)
            clip.speed = max(0.05, (object["speed"] as? NSNumber)?.doubleValue ?? 1)
            clip.reason = object["reason"] as? String
            return clip
        }
        if clips.isEmpty, let document {
            clips = document.videoTrack.compactMap { clip in
                guard let id = clip.sceneID, let start = clip.sourceStart,
                      let end = clip.sourceEnd, end > start else { return nil }
                var result = WizardPlanClip(sceneID: id, start: start, end: end)
                result.speed = max(0.05, clip.speed ?? 1)
                return result
            }
        }
        return WizardPlan(targetDuration: video.duration, rationale: video.rationale ?? "Saved rendered reel",
                          musicName: document?.soundTrack.first?.name, musicVolume: 0, clips: clips, transitions: [])
    }
}
