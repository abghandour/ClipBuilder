import Foundation

/// Accepted transcript cleanup cuts (Transcript Tools) applied to the
/// Builder timeline: the clip inspector's "Apply cleanup cuts" button.
extension AppStore {
    /// Library video ids by source path, for Builder clips that reference a
    /// file rather than a scene.
    var videoIDsByPath: [String: Int64] {
        Dictionary(videos.compactMap { video in video.path.map { ($0, video.id) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The video ids the Builder timeline's main clips play.
    func builderVideoIDs() -> Set<Int64> {
        let byPath = videoIDsByPath
        return Set(builder.document.videoTrack.compactMap { builder.cutSource(for: $0, videoIDsByPath: byPath)?.videoID })
    }

    /// Accepted cleanup cuts (source seconds) for each of `videoIDs`.
    func acceptedCleanupCuts(videoIDs: Set<Int64>) async -> [Int64: [ClosedRange<Double>]] {
        guard let database else { return [:] }
        var cuts: [Int64: [ClosedRange<Double>]] = [:]
        for videoID in videoIDs.sorted() {
            let proposals = (try? await database.fetchEditProposals(videoID: videoID)) ?? []
            let ranges = proposals
                .filter { $0.decision == .accepted && $0.kind.isCleanupCut && $0.endTime > $0.startTime }
                .map { $0.startTime...$0.endTime }
            if !ranges.isEmpty { cuts[videoID] = ranges }
        }
        return cuts
    }

    /// Read the accepted cuts for the timeline's videos and cut them out.
    /// Returns the seconds removed (0 when nothing changed), or nil when the
    /// timeline changed during the read and nothing was applied.
    /// The cuts are read asynchronously, so the open timeline, profile and
    /// document revision are captured first; if any changed during the read
    /// the cuts are dropped (they were computed for another document).
    @discardableResult
    func applyAcceptedCleanupCuts() async -> Double? {
        let snapshot = builderCutSnapshot
        let cuts = await acceptedCleanupCuts(videoIDs: builderVideoIDs())
        guard builderCutSnapshot == snapshot else {
            appendLog(\.builderLog, ["Cleanup cuts not applied: the timeline changed while the cuts were read"],
                      channel: "builder")
            return nil
        }
        guard !cuts.isEmpty else { return 0 }
        return builder.applyAcceptedCleanupCuts(cuts, videoIDsByPath: videoIDsByPath)
    }

    /// Identity of the Builder document that async cleanup-cut reads were
    /// started for: profile generation, open timeline and document revision.
    struct BuilderCutSnapshot: Equatable {
        let profileGeneration: Int
        let timelineID: Int64?
        let revision: Int
    }

    var builderCutSnapshot: BuilderCutSnapshot {
        .init(profileGeneration: profileGeneration, timelineID: builder.timelineID, revision: builder.revision)
    }
}
