import Foundation

extension AppStore {
    /// Nil means the read became stale. Database is an actor: neither the
    /// source-file fallback lookup nor the highlight query blocks the UI.
    func savedStrikeContacts(for clip: TimelineClip) async throws -> [Double]? {
        let generation = profileGeneration
        let project = activeProjectID
        let timeline = openTimelineID
        let model = builder
        guard StrikeFreezeRules.sameContactSource(model.clip(clip.uid), clip) else { return nil }
        guard let database else { return [] }
        let scene = model.scene(for: clip)
        guard let start = clip.sourceStart ?? scene?.startTime, start.isFinite,
              clip.sourceSpan.isFinite, clip.sourceSpan >= 0 else { return [] }
        let end = start + clip.sourceSpan
        guard end.isFinite else { return [] }
        let range = start...end
        let path = model.sourceURL(for: clip)?.path
        var videoID = scene?.videoID ?? model.scenes.first { $0.videoPath == path }?.videoID
        if videoID == nil, let path {
            videoID = try await database.fetchVideos(projectID: project).first { $0.url.path == path }?.id
        }
        let contacts: [Double]
        if let videoID {
            contacts = try await database.fetchStrikeContacts(videoIDs: [videoID], overlapping: range)[videoID] ?? []
        } else { contacts = [] }
        guard !Task.isCancelled, generation == profileGeneration, self.database === database,
              project == activeProjectID, timeline == openTimelineID, model === builder,
              StrikeFreezeRules.sameContactSource(model.clip(clip.uid), clip) else { return nil }
        return contacts
    }

    func freezeOnImpacts(_ clip: TimelineClip) async {
        let generation = profileGeneration
        let database = database
        let project = activeProjectID
        let timeline = openTimelineID
        do {
            guard let contacts = try await savedStrikeContacts(for: clip),
                  !Task.isCancelled, generation == profileGeneration, self.database === database,
                  project == activeProjectID, timeline == openTimelineID,
                  builder.clip(clip.uid) == clip else { return }
            // No suspension between these identity checks and the edit.
            let count = try builder.freezeOnImpacts(clip.uid, contacts: contacts).get()
            presentNotice("Freeze on Impacts", count > 0 ? "Froze \(count) impacts"
                : "No impact far enough from the clip's edges")
        } catch {
            guard !Task.isCancelled, generation == profileGeneration, self.database === database,
                  project == activeProjectID, timeline == openTimelineID,
                  builder.clip(clip.uid) == clip else { return }
            presentError("Could not freeze impacts", error)
        }
    }
}
