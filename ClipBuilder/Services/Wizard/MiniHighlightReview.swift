import Foundation

/// Pure Highlights adapter. Both finder and planner candidates are saved takes.
nonisolated enum MiniHighlightReview {
    static func items(candidates: [MiniWizardCandidate], video: VideoRecord,
                      scenes: [SceneRecord]) -> [RangeReviewItem] {
        let sceneMap = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.map { candidate in
            let resolved = WizardSelectionRules.resolvedPlan(candidate.take.plan, scenes: scenes)
            let plan = resolved ?? candidate.take.plan
            let cuts = plan.clips.enumerated().map { index, clip in
                let scene = resolved == nil ? nil : sceneMap[clip.sceneID]
                var source = video
                if let scene {
                    source.id = scene.videoID
                    source.path = scene.videoPath
                    source.filename = scene.videoFilename
                    source.duration = scene.videoDuration
                    source.width = scene.videoWidth
                    source.height = scene.videoHeight
                    source.wide = scene.wide
                }
                let limits = scene.map { ProposedCutTrim.range(start: $0.startTime, end: $0.endTime) } ?? 0...0
                let proposed = candidate.suggestedPlan.clips.indices.contains(index)
                    ? candidate.suggestedPlan.clips[index] : clip
                let range = ProposedCutTrim.range(start: clip.start, end: clip.end)
                let title = "Cut \(index + 1) · \(ProposedCutTrim.duration(range).formatted(.number.precision(.fractionLength(1)))) s"
                return RangeReviewItem(id: .init(ownerID: candidate.id, revisionID: candidate.take.id, cutIndex: index),
                    title: title, titleHelp: title, keepLabel: "", captions: [], video: source,
                    range: scene == nil ? range : ProposedCutTrim.clamp(start: clip.start, end: clip.end, scene: limits),
                    originalRange: ProposedCutTrim.range(start: proposed.start, end: proposed.end),
                    limits: limits, trimPolicy: .wizard, isAvailable: scene != nil)
            }
            var item = cuts.first ?? RangeReviewItem(
                id: .init(ownerID: candidate.id, revisionID: candidate.take.id), title: "", titleHelp: "",
                keepLabel: "", captions: [], video: video, range: 0...0, originalRange: 0...0,
                limits: 0...0, trimPolicy: .wizard, isAvailable: false)
            item.id = .init(ownerID: candidate.id, revisionID: candidate.take.id)
            item.title = candidate.selection.name
            item.titleHelp = candidate.selection.name
            item.keepLabel = "Keep \(candidate.selection.name)"
            item.captions = [
                .init(text: "\(WizardSelectionRules.duration(candidate.take.plan).formatted(.number.precision(.fractionLength(1)))) s · Take \(candidate.take.ordinal)", monospaced: true),
                .init(text: candidate.take.plan.rationale, lineLimit: 2)
            ]
            item.children = cuts.count > 1 ? cuts : []
            return item
        }
    }

    static func keptIDs(_ candidates: [MiniWizardCandidate]) -> Set<Int64> {
        Set(candidates.filter(\.kept).map(\.id))
    }

    static func settingKept(_ kept: Set<Int64>, in candidates: [MiniWizardCandidate]) -> [MiniWizardCandidate] {
        candidates.map { candidate in
            var candidate = candidate
            candidate.kept = kept.contains(candidate.id)
            return candidate
        }
    }

    /// Resolve against current analysis, then modify only the targeted cut.
    /// Persistence still passes through saveMiniCandidatePlan/saveWizardTakePlan.
    static func trimming(_ itemID: RangeReviewItem.ID, to range: ClosedRange<Double>,
                         candidate: MiniWizardCandidate, scenes: [SceneRecord]) -> WizardPlan? {
        guard itemID.ownerID == candidate.id, itemID.revisionID == candidate.take.id,
              var plan = WizardSelectionRules.resolvedPlan(candidate.take.plan, scenes: scenes) else { return nil }
        let index = itemID.cutIndex ?? 0
        guard plan.clips.indices.contains(index),
              let scene = scenes.first(where: { $0.id == plan.clips[index].sceneID }),
              range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
        let updated = ProposedCutTrim.clamp(start: range.lowerBound, end: range.upperBound,
                                           scene: scene.startTime...scene.endTime)
        guard updated.upperBound > updated.lowerBound else { return nil }
        plan.clips[index].start = updated.lowerBound
        plan.clips[index].end = updated.upperBound
        return plan
    }
}
