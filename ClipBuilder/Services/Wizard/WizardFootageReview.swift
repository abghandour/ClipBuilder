import Foundation

/// Pure adapter from the Wizard's saved selections and takes to the shared
/// range review (the Express Footage card's view). One row per take, cuts as
/// children; "kept" means the take is its selection's best take.
nonisolated enum WizardFootageReview {
    /// A review row's identity: the take, with the selection it belongs to.
    struct TakeRef: Hashable, Sendable {
        var selectionID: Int64
        var takeID: Int64
    }

    static func items(selections: [WizardSelectionSummary], scenes: [SceneRecord],
                      videos: [VideoRecord]) -> [RangeReviewItem] {
        let sceneMap = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let videoMap = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selections.flatMap { summary in
            summary.takes.sorted { $0.ordinal < $1.ordinal }.map { take in
                item(for: take, in: summary, sceneMap: sceneMap, videoMap: videoMap)
            }
        }
    }

    private static func item(for take: WizardSelectionTake, in summary: WizardSelectionSummary,
                             sceneMap: [Int64: SceneRecord], videoMap: [Int64: VideoRecord]) -> RangeReviewItem {
        let resolved = WizardSelectionRules.resolvedPlan(take.plan, scenes: Array(sceneMap.values))
        let plan = resolved ?? take.plan
        let fallback = videoMap.values.first ?? placeholderVideo
        let cuts = plan.clips.enumerated().map { index, clip -> RangeReviewItem in
            let scene = resolved == nil ? nil : sceneMap[clip.sceneID]
            var source = scene.flatMap { videoMap[$0.videoID] } ?? fallback
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
            let range = ProposedCutTrim.range(start: clip.start, end: clip.end)
            let title = "Cut \(index + 1) · \(ProposedCutTrim.duration(range).formatted(.number.precision(.fractionLength(1)))) s"
            return RangeReviewItem(id: .init(ownerID: take.id, revisionID: take.id, cutIndex: index),
                title: title, titleHelp: title, keepLabel: "", captions: [], video: source,
                range: scene == nil ? range : ProposedCutTrim.clamp(start: clip.start, end: clip.end, scene: limits),
                originalRange: range, limits: limits, trimPolicy: .wizard, isAvailable: scene != nil)
        }
        var item = cuts.first ?? RangeReviewItem(
            id: .init(ownerID: take.id, revisionID: take.id), title: "", titleHelp: "",
            keepLabel: "", captions: [], video: fallback, range: 0...0, originalRange: 0...0,
            limits: 0...0, trimPolicy: .wizard, isAvailable: false)
        item.id = .init(ownerID: take.id, revisionID: take.id)
        let label = "Take \(take.ordinal)"
        item.title = summary.takes.count > 1 ? "\(summary.selection.name) · \(label)" : summary.selection.name
        item.titleHelp = item.title
        item.keepLabel = "Use \(label) of \(summary.selection.name)"
        var captions: [RangeReviewItem.Caption] = [
            .init(text: "\(WizardSelectionRules.duration(take.plan).formatted(.number.precision(.fractionLength(1)))) s · "
                + "\(take.plan.clips.count) \(take.plan.clips.count == 1 ? "cut" : "cuts")"
                + (take.criticScore.map { " · \($0)/100" } ?? ""), monospaced: true),
            .init(text: take.plan.rationale, lineLimit: 2),
        ]
        if let note = take.note, !note.isEmpty { captions.append(.init(text: "Asked: \(note)", lineLimit: 1)) }
        item.captions = captions
        item.children = cuts.count > 1 ? cuts : []
        return item
    }

    /// The videos a selection's takes draw from: the recorded footage, else
    /// the takes' scenes resolved against the analysis on this Mac.
    static func videoIDs(of summary: WizardSelectionSummary, scenes: [SceneRecord]) -> Set<Int64> {
        videoIDs(of: summary, sceneVideos: sceneVideoIDs(scenes))
    }

    /// Scene id to video id, built once and shared by every selection: a
    /// per-selection map made the Wizard's footage check O(selections × scenes).
    static func sceneVideoIDs(_ scenes: [SceneRecord]) -> [Int64: Int64] {
        var map = [Int64: Int64](minimumCapacity: scenes.count)
        for scene in scenes where map[scene.id] == nil { map[scene.id] = scene.videoID }
        return map
    }

    static func videoIDs(of summary: WizardSelectionSummary, sceneVideos: [Int64: Int64]) -> Set<Int64> {
        var ids = Set<Int64>()
        for take in summary.takes {
            if let footage = take.plan.footage, !footage.isEmpty {
                ids.formUnion(footage.compactMap(\.videoID))
            } else {
                ids.formUnion(take.sceneIDs.compactMap { sceneVideos[$0] })
                ids.formUnion(take.plan.clips.compactMap { sceneVideos[$0.sceneID] })
            }
        }
        return ids
    }

    /// Selections that use footage from the chosen sources, so changing the
    /// source changes the footage on review, as Express does. A selection
    /// whose footage cannot be traced stays visible.
    static func selections(_ selections: [WizardSelectionSummary], usingVideos videoIDs: Set<Int64>,
                           scenes: [SceneRecord]) -> [WizardSelectionSummary] {
        let sceneVideos = sceneVideoIDs(scenes)
        return selections.filter { summary in
            let used = Self.videoIDs(of: summary, sceneVideos: sceneVideos)
            return used.isEmpty || !used.isDisjoint(with: videoIDs)
        }
    }

    /// Take ids that are their selection's best take: the ones a batch renders.
    /// The engine sets the best take when it finds moments, so nil means the
    /// user left the selection out.
    static func keptIDs(_ selections: [WizardSelectionSummary]) -> Set<Int64> {
        Set(selections.compactMap(\.selection.bestTakeID))
    }

    /// Keeping a take makes it its selection's best take; unkeeping the best
    /// take leaves the selection without one. Returns the selections whose
    /// best take changes, with the new value.
    static func bestTakeChanges(from kept: Set<Int64>, in selections: [WizardSelectionSummary]) -> [(selectionID: Int64, takeID: Int64?)] {
        selections.compactMap { summary in
            let keptTakes = summary.takes.filter { kept.contains($0.id) }
            // A take the user just checked replaces the current best one, even
            // an older take; otherwise the best take stays while it is kept.
            let newlyKept = keptTakes.filter { $0.id != summary.selection.bestTakeID }
            let chosen = (newlyKept.isEmpty ? keptTakes : newlyKept).max { $0.ordinal < $1.ordinal }?.id
            return chosen == summary.selection.bestTakeID ? nil : (summary.id, chosen)
        }
    }

    static func take(_ ref: RangeReviewItem.ID, in selections: [WizardSelectionSummary]) -> (WizardSelectionSummary, WizardSelectionTake)? {
        for summary in selections {
            if let take = summary.takes.first(where: { $0.id == ref.ownerID }) { return (summary, take) }
        }
        return nil
    }

    /// Resolve against current analysis, then modify only the targeted cut.
    static func trimming(_ itemID: RangeReviewItem.ID, to range: ClosedRange<Double>,
                         take: WizardSelectionTake, scenes: [SceneRecord]) -> WizardPlan? {
        guard itemID.ownerID == take.id, itemID.revisionID == take.id,
              var plan = WizardSelectionRules.resolvedPlan(take.plan, scenes: scenes) else { return nil }
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

    private static var placeholderVideo: VideoRecord {
        VideoRecord(id: 0, hash: "", filename: "Unavailable", path: nil, duration: 0, width: 0, height: 0, wide: false,
                    discoveredAt: nil, analyzedAt: nil, visualAnalyzedAt: nil, speechAnalyzedAt: nil,
                    visualAnalyzerProvider: nil, visualAnalyzerModel: nil, speechAnalyzerProvider: nil,
                    speechAnalyzerModel: nil, peopleDetectedAt: nil)
    }
}
