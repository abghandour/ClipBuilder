import Foundation

/// Stored with the plan so Analyze can replace scene IDs without breaking takes.
nonisolated struct WizardFootageReference: Codable, Sendable {
    var sceneID: Int64?
    var videoID: Int64?
    var videoPath: String?
    var start: Double?
    var end: Double?
    var videoDuration: Double?
}

nonisolated enum WizardSelectionRules {
    static func duration(_ plan: WizardPlan) -> Double {
        // Replays are already expanded into their own clips by the planner.
        plan.clips.reduce(0) { $0 + max(0, $1.end - $1.start) / max(0.25, $1.speed) }
    }

    static func takeLabel(_ take: WizardSelectionTake) -> String {
        "Take \(take.ordinal) · \(Int(duration(take.plan).rounded())) s · \(take.plan.clips.count) \(take.plan.clips.count == 1 ? "cut" : "cuts")"
    }

    static func snapshot(_ plan: WizardPlan, scenes: [SceneRecord]) -> WizardPlan {
        var plan = plan
        let ids = Set(plan.clips.flatMap { [$0.sceneID] + $0.areaClips.map(\.sceneID) })
        let existing = plan.footage ?? []
        plan.footage = ids.sorted().compactMap { id in
            if let reference = existing.first(where: { $0.sceneID == id }) { return reference }
            guard let scene = scenes.first(where: { $0.id == id }) else { return nil }
            return WizardFootageReference(sceneID: id, videoID: scene.videoID, videoPath: scene.videoPath,
                start: scene.startTime, end: scene.endTime, videoDuration: scene.videoDuration)
        }
        return plan
    }

    /// A saved range must still refer to the same video and scene time range.
    /// Re-analysis commonly creates new IDs for identical footage. Remap those
    /// IDs, including multi-area cuts, before previewing or rendering the plan.
    static func resolvedPlan(_ original: WizardPlan, scenes: [SceneRecord]) -> WizardPlan? {
        let plan = original.footage == nil ? snapshot(original, scenes: scenes) : original
        let ids = Set(plan.clips.flatMap { [$0.sceneID] + $0.areaClips.map(\.sceneID) })
        var matches: [Int64: SceneRecord] = [:]
        for id in ids {
            guard let reference = plan.footage?.first(where: { $0.sceneID == id }),
                  let start = reference.start, let end = reference.end,
                  let scene = scenes.filter({
                      $0.videoID == reference.videoID && $0.videoPath == reference.videoPath
                          && abs($0.startTime - start) < 0.001 && abs($0.endTime - end) < 0.001
                          && (reference.videoDuration == nil || abs($0.videoDuration - reference.videoDuration!) < 0.001)
                  }).max(by: { $0.id < $1.id }) else { return nil }
            matches[id] = scene
        }
        var resolved = plan
        for index in resolved.clips.indices {
            let clip = resolved.clips[index]
            guard let scene = matches[clip.sceneID], contains(scene, start: clip.start, end: clip.end) else { return nil }
            resolved.clips[index].sceneID = scene.id
            for area in clip.areaClips.indices {
                let cut = clip.areaClips[area]
                guard let source = matches[cut.sceneID], contains(source, start: cut.start, end: cut.end) else { return nil }
                resolved.clips[index].areaClips[area].sceneID = source.id
            }
        }
        resolved.footage = nil
        return snapshot(resolved, scenes: Array(matches.values))
    }

    private static func contains(_ scene: SceneRecord, start: Double, end: Double) -> Bool {
        start.isFinite && end.isFinite && end > start
            && start >= scene.startTime - 0.001 && end <= scene.endTime + 0.001
    }
}
