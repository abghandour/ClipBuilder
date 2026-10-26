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

    /// Scenes keyed by id (first copy wins, as `first(where:)` would) and by
    /// video, so resolving many takes does not scan every scene per cut.
    struct SceneIndex: Sendable {
        let byID: [Int64: SceneRecord]
        let byVideo: [Int64: [SceneRecord]]

        init(_ scenes: [SceneRecord]) {
            byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            byVideo = Dictionary(grouping: scenes, by: \.videoID)
        }
    }

    static func snapshot(_ plan: WizardPlan, scenes: [SceneRecord]) -> WizardPlan {
        snapshot(plan, index: SceneIndex(scenes))
    }

    static func snapshot(_ plan: WizardPlan, index: SceneIndex) -> WizardPlan {
        var plan = plan
        let ids = Set(plan.clips.flatMap { [$0.sceneID] + $0.areaClips.map(\.sceneID) })
        let existing = plan.footage ?? []
        plan.footage = ids.sorted().compactMap { id in
            if let reference = existing.first(where: { $0.sceneID == id }) { return reference }
            guard let scene = index.byID[id] else { return nil }
            return WizardFootageReference(sceneID: id, videoID: scene.videoID, videoPath: scene.videoPath,
                start: scene.startTime, end: scene.endTime, videoDuration: scene.videoDuration)
        }
        return plan
    }

    /// A saved range must still refer to the same video and scene time range.
    /// Re-analysis commonly creates new IDs for identical footage. Remap those
    /// IDs, including multi-area cuts, before previewing or rendering the plan.
    static func resolvedPlan(_ original: WizardPlan, scenes: [SceneRecord]) -> WizardPlan? {
        resolvedPlan(original, index: SceneIndex(scenes))
    }

    static func resolvedPlan(_ original: WizardPlan, index: SceneIndex) -> WizardPlan? {
        let plan = original.footage == nil ? snapshot(original, index: index) : original
        let ids = Set(plan.clips.flatMap { [$0.sceneID] + $0.areaClips.map(\.sceneID) })
        var matches: [Int64: SceneRecord] = [:]
        for id in ids {
            guard let reference = plan.footage?.first(where: { $0.sceneID == id }),
                  let start = reference.start, let end = reference.end else { return nil }
            func same(_ scene: SceneRecord) -> Bool {
                scene.videoID == reference.videoID && scene.videoPath == reference.videoPath
                    && abs(scene.startTime - start) < 0.001 && abs(scene.endTime - end) < 0.001
                    && (reference.videoDuration == nil || abs(scene.videoDuration - reference.videoDuration!) < 0.001)
            }
            // The original id first; otherwise the newest identical range.
            let found: SceneRecord?
            if let own = index.byID[id], same(own) {
                found = own
            } else {
                let matching = reference.videoID.flatMap { index.byVideo[$0] }?.filter(same) ?? []
                found = matching.first(where: { $0.id == id }) ?? matching.max(by: { $0.id < $1.id })
            }
            guard let scene = found else { return nil }
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
