import Foundation

extension AppStore {
    var strikeStatsClip: TimelineClip? {
        if case .clip(let uid) = builder.selection,
           let clip = builder.document.videoTrack.first(where: { $0.uid == uid }) { return clip }
        return builder.document.videoTrack.first {
            !$0.bumper && $0.startTime <= builder.playhead && builder.playhead < $0.startTime + $0.duration
        }
    }

    func addStrikeStatsCard(_ kind: StrikeStatPayload.Kind) {
        guard let clip = strikeStatsClip,
              let video = videos.first(where: { video in
                  video.path == clip.videoFile || scenes.contains { $0.id == clip.sceneID && $0.videoID == video.id }
              }), video.type?.supportsFightFeatures == true else {
            presentError("Select a fight clip", AIError.notConfigured("Select a Fight or Recap clip before adding a stat card."))
            return
        }
        let scene = builder.scenes.first { $0.id == clip.sceneID }
        let start = clip.sourceStart ?? scene?.startTime ?? 0
        let end = start + clip.sourceSpan
        let time = min(max(start, start + (builder.playhead - clip.startTime) * clip.effectiveSpeed), max(start, end - 0.01))
        var payload = StrikeStatPayload(kind: kind, sourceVideoID: video.id, sourceTime: time,
                                        unit: .kmh, scope: .init(start: start, end: end, isRecap: video.type == .recap))
        let generation = profileGeneration
        let documentID = builder.timelineID
        Task {
            do {
                payload = try await strikeStatsSnapshot(payload)
                guard generation == profileGeneration, documentID == builder.timelineID,
                      builder.document.videoTrack.contains(where: { $0.uid == clip.uid }) else { return }
                let uid = builder.addText(at: clip.startTime + (time - start) / max(0.01, clip.effectiveSpeed))
                builder.updateStat(uid, payload: payload)
            } catch { presentError("Could not add stat card", error) }
        }
    }

    func refreshStrikeStats(_ item: TextOverlayItem) {
        guard let payload = item.stat else { return }
        let generation = profileGeneration
        Task {
            do {
                let refreshed = try await strikeStatsSnapshot(payload)
                guard generation == profileGeneration, builder.textItem(item.uid)?.stat == payload else { return }
                builder.updateStat(item.uid, payload: refreshed)
            } catch { presentError("Could not refresh stat card", error) }
        }
    }

    private func strikeStatsSnapshot(_ original: StrikeStatPayload) async throws -> StrikeStatPayload {
        guard let database, let videoID = original.sourceVideoID,
              let video = try await database.video(id: videoID) else {
            throw AIError.notConfigured("The source video is unavailable.")
        }
        let events = try await database.fetchFightEvents().filter { $0.videoID == videoID }
        let scenes = try await database.fetchScenes(includeExcluded: true).filter { $0.videoID == videoID }
        let outcomes = try await database.fetchOutcomes().filter { $0.videoID == videoID }
        let roster = try await database.fetchVideoPeople(videoID: videoID)
        let passes = try await database.fetchAnalysisPasses()
        let researchJSON = try await database.fetchFightResearch().first { $0.videoID == videoID }?.summaryJSON
        return try await AppJobWork.run {
            StrikeStatsSummary.snapshot(original, video: video, events: events, scenes: scenes,
                                        outcomes: outcomes, roster: roster, passes: passes, researchJSON: researchJSON)
        }
    }
}
