import Foundation

/// Cross-Mac footage identity for highlight history: scenes are recorded by
/// source video hash and source-time range, and resolved back to this Mac's
/// scenes when a row is opened. Pure, like `WizardSelectionRules.snapshot`.
nonisolated enum HighlightFootage {
    /// Seconds a local scene's edges may differ from the recorded range.
    static let tolerance = 0.05

    /// A recorded scene on this Mac: an existing scene, or the range to
    /// create one for (`sceneID == nil`).
    struct ResolvedScene: Sendable, Hashable {
        var videoID: Int64
        var start: Double
        var end: Double
        var sceneID: Int64?
    }

    /// Every scene the plan references (cuts, layout areas, B-roll), sorted by
    /// scene id. Scenes whose video is unknown are left out.
    static func snapshot(plan: WizardPlan, scenes: [SceneRecord], videos: [VideoRecord]) -> [HighlightFootageRef] {
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hashes = Dictionary(videos.map { ($0.id, $0.hash) }, uniquingKeysWith: { first, _ in first })
        let recorded = Dictionary((plan.footage ?? []).compactMap { reference in
            reference.sceneID.map { ($0, reference) }
        }, uniquingKeysWith: { first, _ in first })
        return SceneReferences.ids(in: plan).sorted().compactMap { id in
            if let scene = byID[id], let hash = hashes[scene.videoID], !hash.isEmpty {
                return HighlightFootageRef(sceneID: id, videoHash: hash, start: scene.startTime, end: scene.endTime)
            }
            // The plan's own snapshot covers a scene re-analysis removed.
            guard let reference = recorded[id], let videoID = reference.videoID,
                  let hash = hashes[videoID], !hash.isEmpty,
                  let start = reference.start, let end = reference.end else { return nil }
            return HighlightFootageRef(sceneID: id, videoHash: hash, start: start, end: end)
        }
    }

    static func videoHashes(_ refs: [HighlightFootageRef]) -> [String] {
        Array(Set(refs.map(\.videoHash)).filter { !$0.isEmpty }).sorted()
    }

    /// Hashes of recorded videos this library does not have.
    static func missingVideoHashes(_ refs: [HighlightFootageRef], localVideos: [VideoRecord]) -> [String] {
        let local = Set(localVideos.map(\.hash))
        return videoHashes(refs).filter { !local.contains($0) }
    }

    /// How far a plan clip may sit outside its scene; matches the
    /// containment check in `WizardSelectionRules.resolvedPlan`.
    static let containmentTolerance = 0.001

    /// One recorded range on this Mac: the closest scene of the same video
    /// whose edges are within `tolerance` and which fully contains the
    /// recorded range, else the exact recorded range to create. A scene that
    /// starts later or ends earlier than the recording (0.04…7.97 for 0…8)
    /// is never reused: the plan's clips keep their source times, and
    /// `resolvedPlan` would reject a clip that overhangs its scene. Nil when
    /// the video is not in the library.
    static func resolve(_ ref: HighlightFootageRef, localVideos: [VideoRecord],
                        scenes: [SceneRecord]) -> ResolvedScene? {
        guard let video = localVideos.first(where: { $0.hash == ref.videoHash && !ref.videoHash.isEmpty }) else {
            return nil
        }
        let candidates = scenes.filter {
            $0.videoID == video.id && abs($0.startTime - ref.start) <= tolerance
                && abs($0.endTime - ref.end) <= tolerance
                && $0.startTime <= ref.start + containmentTolerance
                && $0.endTime >= ref.end - containmentTolerance
        }
        // Closest edges first; the original id, then the newest, break ties.
        let best = candidates.min { lhs, rhs in
            let left = abs(lhs.startTime - ref.start) + abs(lhs.endTime - ref.end)
            let right = abs(rhs.startTime - ref.start) + abs(rhs.endTime - ref.end)
            if left != right { return left < right }
            if lhs.id == ref.sceneID { return true }
            if rhs.id == ref.sceneID { return false }
            return lhs.id > rhs.id
        }
        return ResolvedScene(videoID: video.id, start: best?.startTime ?? ref.start,
                             end: best?.endTime ?? ref.end, sceneID: best?.id)
    }

    /// Recorded scene id → this Mac's scene. Refs without a recorded scene id
    /// or whose video is missing are left out.
    static func resolve(refs: [HighlightFootageRef], localVideos: [VideoRecord],
                        scenes: [SceneRecord]) -> [Int64: ResolvedScene] {
        refs.reduce(into: [:]) { result, ref in
            guard let id = ref.sceneID, result[id] == nil,
                  let resolved = resolve(ref, localVideos: localVideos, scenes: scenes) else { return }
            result[id] = resolved
        }
    }

    /// The plan with every scene id replaced by this Mac's id, or nil when
    /// one is not mapped. The plan's own footage snapshot is dropped; the
    /// caller re-snapshots against local scenes.
    static func remap(_ plan: WizardPlan, sceneIDs: [Int64: Int64]) -> WizardPlan? {
        var plan = plan
        for index in plan.clips.indices {
            guard let id = sceneIDs[plan.clips[index].sceneID] else { return nil }
            plan.clips[index].sceneID = id
            for area in plan.clips[index].areaClips.indices {
                guard let id = sceneIDs[plan.clips[index].areaClips[area].sceneID] else { return nil }
                plan.clips[index].areaClips[area].sceneID = id
            }
            if var cuts = plan.clips[index].brollCuts {
                for cut in cuts.indices {
                    guard let id = sceneIDs[cuts[cut].sceneID] else { return nil }
                    cuts[cut].sceneID = id
                }
                plan.clips[index].brollCuts = cuts
            }
            // Pick ids are local rows; a teammate's plan must not point at ours.
            plan.clips[index].miniPickID = nil
        }
        plan.footage = nil
        return plan
    }

    /// A plan rebuilt from `generated_videos.plan_clips_json` for renders
    /// that kept no take (the full wizard's automatic reels).
    static func plan(fromPlanClipsJSON json: String?, rationale: String?, targetDuration: Double) -> WizardPlan? {
        guard let data = json?.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let clips: [WizardPlanClip] = rows.compactMap { row in
            guard let id = (row["scene_id"] as? NSNumber)?.int64Value,
                  let start = (row["start"] as? NSNumber)?.doubleValue,
                  let end = (row["end"] as? NSNumber)?.doubleValue else { return nil }
            var clip = WizardPlanClip(sceneID: id, start: start, end: end)
            clip.speed = (row["speed"] as? NSNumber)?.doubleValue ?? 1
            clip.reason = row["reason"] as? String
            return clip
        }
        guard !clips.isEmpty else { return nil }
        return WizardPlan(footage: nil, targetDuration: targetDuration, rationale: rationale ?? "",
                          musicName: nil, musicVolume: 0, clips: clips, transitions: [])
    }
}
