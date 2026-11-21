import Foundation

/// What saved strike metadata can promise before extraction. No marking, AI,
/// media reads or render work is performed to produce this explanation.
nonisolated struct StrikeClipStatus: Equatable, Sendable {
    enum Pause: Equatable, Sendable {
        case off
        case none(reason: String)
        /// Duration of each hold, after the engine's clamp.
        case pauses(count: Int, seconds: Double)
    }

    var marks: Int
    var pause: Pause
    var marksEnabled: Bool
    var conditionalTransition = false
    var unknownTransition = false
    var hardCutJoin = false
    var markingIncomplete = false
    var filteredContacts = 0
    var unavailableReason: String? = nil

    static let noStrike = "No strike found in this clip"

    var line: String {
        if let unavailableReason { return unavailableReason }
        var parts: [String] = []
        if marksEnabled { parts.append(marks == 1 ? "1 mark" : "\(marks) marks") }
        switch pause {
        case .off:
            if marks == 0 { return markingIncomplete ? "Strike marking not finished" : Self.noStrike }
        case .none(let reason):
            if marks == 0, reason == Self.noStrike {
                if !hardCutJoin { return reason }
                parts.append(reason)
            } else {
                parts.append("pause skipped: \(reason)")
            }
        case .pauses(let count, let seconds):
            let length = seconds.formatted(.number.precision(.fractionLength(0...2)))
            parts.append(count == 1 ? "pause \(length) s" : "\(count) pauses × \(length) s")
            if conditionalTransition { parts.append("may be skipped for a recipe transition (Random)") }
        }
        if hardCutJoin { parts.append("neighbouring join is a hard cut") }
        if unknownTransition { parts.append("join may become a hard cut (Random)") }
        if markingIncomplete { parts.append("marking incomplete") }
        return parts.joined(separator: " · ")
    }

    var help: String {
        var text = line + ". Based on saved strike marks and current clip settings."
        if filteredContacts > 0 { text += " \(filteredContacts) contact(s) excluded by spacing or the pause limit." }
        if unknownTransition { text += " Generate chooses Random joins; ordinary transitions become cuts where needed to keep pauses. Recipe joins still skip pauses." }
        if markingIncomplete { text += " Generate may find more marks and contacts." }
        text += " Music beat snapping or the extracted cut can still change eligibility."
        return text
    }

    var hasPause: Bool {
        if case .pauses = pause { return true }
        return false
    }
}

nonisolated enum StrikeClipStatusRules {
    struct Saved: Sendable {
        var tracks: [StrikeHighlightRules.Track] = []
        /// Read independently: drawable() deliberately zeros Track.contact.
        var contacts: [Double] = []
        var complete = true
    }

    /// `unknownJoins` names boundaries before Generate, never invented effects.
    /// The caller substitutes cuts at those boundaries; known outside joins
    /// (intro/outro) still go through the real eligibility checks.
    static func status(index: Int, plan: WizardPlan, scene: SceneRecord, sourceType: VideoType?,
                       saved: Saved, options: WizardOptions, xfadeDuration: Double,
                       unknownJoins: Set<Int> = [], randomRecipes: Bool = true,
                       cut: TimelineDocument? = nil,
                       preparation: WizardStrikePauses.Preparation? = nil) -> StrikeClipStatus {
        guard sourceType == .fight else { return .init(marks: 0, pause: .off, marksEnabled: false) }
        let clip = plan.clips[index]
        let marks = options.strikeHighlights == true
            ? StrikeHighlightBurn.tracks(saved.tracks.map(StrikeHighlightRules.drawable),
                                         start: clip.start, duration: clip.end - clip.start).count : 0
        var result = StrikeClipStatus(marks: marks, pause: .off, marksEnabled: options.strikeHighlights == true,
                                      markingIncomplete: !saved.complete)
        guard WizardStrikePauses.requested(options) else { return result }
        guard clip.start.isFinite, clip.end.isFinite, clip.end > clip.start,
              clip.speed.isFinite, clip.speed > 0 else {
            result.pause = .none(reason: "source pieces could not be split safely")
            return result
        }
        let document = cut ?? cutDocument(clip: clip, plan: plan, scene: scene, sourceType: sourceType, options: options)
        let prepared = preparation ?? WizardStrikePauses.prepare(plan: plan, cuts: [index: document],
            sceneMap: [scene.id: scene], sourceTypes: [scene.videoID: .fight],
            contacts: [scene.videoPath: saved.contacts], options: options, xfadeDuration: xfadeDuration)
        result.hardCutJoin = prepared.joins.changed(beside: index)
        if let reason = WizardStrikePauses.skipReason(index: index, plan: plan, cut: document,
            scene: scene, sourceType: sourceType, options: options) {
            result.pause = .none(reason: reason)
            return result
        }
        // timing calls StrikeFreezeRules.selection: speed, edge spacing,
        // duplicates, the contact cap and hold length are the engine's rules.
        let timing = WizardStrikePauses.timing(for: clip, contacts: saved.contacts, seconds: options.strikeImpactFreeze)
        result.filteredContacts = timing.filteredContacts
        guard !timing.pauses.isEmpty else {
            let contacts = saved.contacts.filter { $0.isFinite && $0 >= clip.start && $0 <= clip.end }
            let reasons = Set(contacts.compactMap {
                StrikeFreezeRules.boundaryReason(start: clip.start, end: clip.end, speed: clip.speed, contact: $0)
            })
            let reason: String
            if contacts.isEmpty {
                reason = !saved.complete ? "strike marking not finished"
                    : marks > 0 ? "no contact inside this clip" : StrikeClipStatus.noStrike
            } else if reasons.count > 1 {
                reason = "too close to the clip start or end"
            } else {
                reason = reasons.first ?? "source pieces could not be split safely"
            }
            result.pause = .none(reason: reason)
            return result
        }
        guard prepared.timings[index]?.pauses.isEmpty == false else {
            result.pause = .none(reason: "source pieces could not be split safely")
            return result
        }
        result.pause = .pauses(count: timing.pauses.count, seconds: timing.pauses[0].duration)
        result.unknownTransition = unknownJoins.contains(index - 1) || unknownJoins.contains(index)
        result.conditionalTransition = result.unknownTransition && randomRecipes
        return result
    }

    static func cutDocument(clip: WizardPlanClip, plan: WizardPlan, scene: SceneRecord,
                            sourceType: VideoType?, options: WizardOptions) -> TimelineDocument {
        let context = FramingContext(scene: scene, range: clip.start...max(clip.start, clip.end),
            canvasAspect: options.renderSettings.aspectRatio, chosenSubject: plan.framing, type: sourceType)
        return WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene],
            settings: options.renderSettings,
            framingPlan: FramingPlanner.resolve(framing: options.requestedFraming, context: context))
    }

    static func summary(_ statuses: [StrikeClipStatus], marks: Bool, pauses: Bool) -> String {
        if statuses.contains(where: { $0.unavailableReason != nil }) { return "Strike status awaits saved Highlight takes" }
        var parts: [String] = []
        if marks { parts.append("Marks on \(statuses.count { $0.marks > 0 }) of \(statuses.count) clips") }
        if pauses {
            let certain = statuses.count { $0.hasPause && !$0.conditionalTransition }
            let possible = statuses.count { $0.hasPause }
            parts.append(certain == possible ? "pauses on \(certain)" : "pauses on up to \(possible) (Random)")
        }
        if statuses.contains(where: \.markingIncomplete) { parts.append("saved so far") }
        return parts.joined(separator: " · ")
    }
}
