import Foundation

/// A small value snapshot for the Express view's cancellable status task.
/// Equality watches only inputs that can affect strike eligibility.
nonisolated struct MiniStrikeStatusRequest: Equatable, Sendable {
    struct Clip: Equatable, Sendable {
        var preview: WizardPreviewClip
        var plan: WizardPlanClip
        var planAvailable: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.preview == rhs.preview && lhs.planAvailable == rhs.planAvailable
                && lhs.plan.speed == rhs.plan.speed && lhs.plan.replay == rhs.plan.replay
                && lhs.plan.reason == rhs.plan.reason && lhs.plan.layout == rhs.plan.layout
                && lhs.plan.screenCrop == rhs.plan.screenCrop
                && lhs.plan.areaClips.count == rhs.plan.areaClips.count
                && zip(lhs.plan.areaClips, rhs.plan.areaClips).allSatisfy {
                    $0.area == $1.area && $0.sceneID == $1.sceneID && $0.start == $1.start && $0.end == $1.end
                }
        }
    }

    var dataKey: String
    var videoID: Int64?
    var isFight: Bool
    var clips: [Clip]
    var options: WizardOptions
    var xfadeDuration: Double

    var companionSceneIDs: Set<Int64> { Set(clips.flatMap { $0.plan.areaClips.map(\.sceneID) }) }
    var snapshotKey: String { "\(dataKey):\(companionSceneIDs.sorted())" }

    var visible: Bool {
        (isFight && options.strikeHighlights == true)
            || (WizardStrikePauses.contactsRequested(options) && (isFight || clips.contains { !$0.plan.areaClips.isEmpty }))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.options, b = rhs.options
        return lhs.dataKey == rhs.dataKey && lhs.videoID == rhs.videoID && lhs.isFight == rhs.isFight
            && lhs.clips == rhs.clips && lhs.xfadeDuration == rhs.xfadeDuration
            && a.drawnPauses == b.drawnPauses && a.strikeHighlightStyle == b.strikeHighlightStyle
            && a.strikeSlowMotion == b.strikeSlowMotion && a.strikeFlash == b.strikeFlash
            && a.strikeHighlights == b.strikeHighlights && a.strikeImpactFreeze == b.strikeImpactFreeze
            && a.transitionChoice == b.transitionChoice && a.allowedTransitions == b.allowedTransitions
            && a.dubLanguage == b.dubLanguage && a.includeIntroBumper == b.includeIntroBumper
            && a.includeOutroBumper == b.includeOutroBumper && a.includeMiddleBumper == b.includeMiddleBumper
            && a.includeOutro == b.includeOutro && a.formatPreset == b.formatPreset
            && a.useBRoll == b.useBRoll && a.manualBRoll == b.manualBRoll
            && a.brollInstructions == b.brollInstructions && a.requestedFraming == b.requestedFraming
            && a.pacing == b.pacing && a.useMusic == b.useMusic
            && a.renderSettings.aspectRatio == b.renderSettings.aspectRatio
    }

    /// Live pick ranges win over saved takes. Highlight cuts retain their
    /// speed/composition/replay metadata instead of assuming all previews are 1×.
    static func clips(_ previews: [WizardPreviewClip], runs: [MiniWizardRun]) -> [Clip] {
        var saved: [String: WizardPlanClip] = [:]
        for run in runs where run.footageKind == .highlights {
            for candidate in run.candidates {
                for (index, clip) in candidate.take.plan.clips.enumerated() {
                    saved["take-\(candidate.id)-\(index)"] = clip
                }
            }
        }
        return previews.map { preview in
            var plan = saved[preview.id] ?? WizardPlanClip(sceneID: preview.scene.id, start: preview.start, end: preview.end)
            plan.sceneID = preview.scene.id
            plan.start = preview.start
            plan.end = preview.end
            plan.brollCuts = preview.brollCuts
            let available = MiniReelRules.key(of: preview.id)?.kind != .highlights || saved[preview.id] != nil
            return Clip(preview: preview, plan: plan, planAvailable: available)
        }
    }

    struct Result: Sendable {
        var statuses: [String: StrikeClipStatus]
        var summary: String
    }

    func evaluate(saved: StrikeClipStatusRules.Saved) -> Result {
        var saved = saved
        if options.drawnPauses == false { saved.drawings = []; saved.companionDrawings = [:] }
        guard visible || saved.hasDrawings || (WizardStrikePauses.contactsRequested(options) && saved.companionTypes.values.contains(.fight)) else { return Result(statuses: [:], summary: "") }
        var plan = WizardPlan(targetDuration: 0, rationale: "", musicName: nil, musicVolume: 0,
                              clips: clips.map(\.plan), transitions: [])
        plan.framing = clips.first?.preview.chosenSubject
        if options.formatPreset != "podcast" { plan = WizardPlanRules.applyPacing(plan: plan, pacing: options.pacing) }
        let random = options.transitionChoice == WizardPlanRules.randomTransitionChoice
        let pool = Set(options.allowedTransitions ?? RenderEngine.allTransitions)
            .intersection(RenderEngine.allTransitions).subtracting(["cut"])
        let unknown: Set<Int>
        if random, pool.count > 1, pool.allSatisfy({ TransitionRecipes.isRecipe($0) }), let recipe = pool.sorted().first {
            // The exact effect is unknown, but every possible join has the
            // same recipe exclusion. Do not promise even a possible pause.
            unknown = []
            plan.transitions = Array(repeating: recipe, count: max(0, plan.clips.count - 1))
        } else if random, pool.count > 1 {
            unknown = Set(0..<max(0, plan.clips.count - 1))
            plan.transitions = Array(repeating: "cut", count: max(0, plan.clips.count - 1))
        } else {
            unknown = []
            plan.transitions = WizardStrikePauses.renderTransitions(plan: plan, options: options)
        }
        // Resolve the whole reel once so the neighbour also reports a changed
        // join, even when only the other side has an eligible contact.
        var sceneMap = Dictionary(clips.map { ($0.preview.scene.id, $0.preview.scene) }, uniquingKeysWith: { first, _ in first })
        var sourceTypes: [Int64: VideoType] = isFight
            ? Dictionary(clips.map { ($0.preview.scene.videoID, VideoType.fight) }, uniquingKeysWith: { first, _ in first }) : [:]
        var contacts = Dictionary(clips.map { ($0.preview.scene.videoPath, saved.contacts) }, uniquingKeysWith: { first, _ in first })
        var drawings = Dictionary(clips.map { ($0.preview.scene.videoPath, saved.drawings) }, uniquingKeysWith: { first, _ in first })
        sceneMap.merge(saved.companionScenes, uniquingKeysWith: { main, _ in main })
        sourceTypes.merge(saved.companionTypes, uniquingKeysWith: { main, _ in main })
        contacts.merge(saved.companionContacts, uniquingKeysWith: { main, _ in main })
        drawings.merge(saved.companionDrawings, uniquingKeysWith: { main, _ in main })
        var cuts: [Int: TimelineDocument] = [:]
        for (index, input) in clips.enumerated() where input.planAvailable {
            let clip = plan.clips[index]
            guard clip.start.isFinite, clip.end.isFinite, clip.end > clip.start,
                  clip.speed.isFinite, clip.speed > 0 else { continue }
            cuts[index] = StrikeClipStatusRules.cutDocument(clip: clip, plan: plan,
                scene: input.preview.scene, sourceType: isFight ? .fight : nil, options: options, sceneMap: sceneMap)
        }
        let prepared = WizardStrikePauses.prepare(plan: plan, cuts: cuts, sceneMap: sceneMap,
            sourceTypes: sourceTypes, contacts: contacts, drawings: drawings, options: options, xfadeDuration: xfadeDuration)
        var statuses: [String: StrikeClipStatus] = [:]
        for (index, input) in clips.enumerated() {
            var status = StrikeClipStatusRules.status(index: index, plan: plan, scene: input.preview.scene,
                sourceType: isFight ? .fight : nil, saved: saved, options: options, xfadeDuration: xfadeDuration, unknownJoins: unknown,
                randomRecipes: pool.contains { TransitionRecipes.isRecipe($0) }, cut: cuts[index], preparation: prepared)
            if !input.planAvailable { status.unavailableReason = "Strike status awaits the saved Highlight take" }
            statuses[input.preview.id] = status
        }
        return Result(statuses: statuses, summary: StrikeClipStatusRules.summary(clips.compactMap { statuses[$0.preview.id] },
            marks: options.strikeHighlights == true, pauses: WizardStrikePauses.requested(options) || saved.hasDrawings))
    }
}
