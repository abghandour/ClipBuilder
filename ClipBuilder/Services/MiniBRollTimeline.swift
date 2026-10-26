import Foundation

/// Cutaways are composited before the extraction pass burns captions and name tags.
nonisolated enum MiniBRollTimeline {
    static func adding(to document: TimelineDocument, clip: WizardPlanClip,
                       scenes: [SceneRecord], enabled: Bool) -> TimelineDocument {
        guard enabled, clip.end > clip.start else { return document }
        var result = document
        result.videoTrack += BRollCutMapping.timelineClips(clip.brollCuts ?? [],
            sourceRange: clip.start...clip.end, scenes: scenes)
        return result
    }
}
