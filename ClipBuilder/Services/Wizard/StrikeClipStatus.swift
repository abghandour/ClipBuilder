import Foundation

/// What saved strike metadata can promise before extraction. No marking, AI,
/// media reads or render work is performed to produce this explanation.
nonisolated struct StrikeClipStatus: Equatable, Sendable {
    enum Pause: Equatable, Sendable {
        case off
        case none(reason: String)
        /// Duration of each hold, after the engine's clamp.
        case pauses(count: Int, seconds: Double)
        case mixedPauses(seconds: [Double])
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
    var slowAddedDuration = 0.0
    var flashes = 0
    var impactNotes: [String] = []
    var movingDrawings = 0
    var motionFallbackReasons: [String] = []

    var symbol: String { movingDrawings > 0 ? "pencil.and.scribble" : pause == .off ? "viewfinder" : "snowflake" }

    static let noStrike = "No strike found in this clip"

    var line: String {
        if let unavailableReason { return unavailableReason }
        var parts: [String] = []
        if marksEnabled { parts.append(marks == 1 ? "1 mark" : "\(marks) marks") }
        if slowAddedDuration > 0 {
            parts.append("slow motion +\(slowAddedDuration.formatted(.number.precision(.fractionLength(0...2)))) s")
        }
        if flashes > 0 { parts.append("\(flashes) flash\(flashes == 1 ? "" : "es")") }
        if movingDrawings > 0 { parts.append("drawing over the moving picture") }
        if !motionFallbackReasons.isEmpty {
            parts.append("the picture pauses (\(motionFallbackReasons.joined(separator: "; ")))")
        }
        parts += impactNotes
        switch pause {
        case .off:
            if marks == 0, slowAddedDuration == 0, flashes == 0, impactNotes.isEmpty,
               movingDrawings == 0, motionFallbackReasons.isEmpty { return markingIncomplete ? "Strike marking not finished" : Self.noStrike }
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
        case .mixedPauses(let seconds):
            let total = seconds.reduce(0, +).formatted(.number.precision(.fractionLength(0...2)))
            parts.append("\(seconds.count) pauses · \(total) s total")
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
        if case .mixedPauses = pause { return true }
        return false
    }
}

nonisolated enum StrikeClipStatusRules {
    struct Saved: Sendable {
        var tracks: [StrikeHighlightRules.Track] = []
        /// Read independently: drawable() deliberately zeros Track.contact.
        var contacts: [Double] = []
        var complete = true
        var drawings: [Telestration] = []
        var companionScenes: [Int64: SceneRecord] = [:]
        var companionTypes: [Int64: VideoType] = [:]
        var companionContacts: [String: [Double]] = [:]
        var companionDrawings: [String: [Telestration]] = [:]
        /// Whether each companion source's strikes are all marked.
        var companionComplete: [String: Bool] = [:]

        var hasDrawings: Bool { !drawings.isEmpty || companionDrawings.values.contains { !$0.isEmpty } }
    }

    /// `unknownJoins` names boundaries before Generate, never invented effects.
    /// The caller substitutes cuts at those boundaries; known outside joins
    /// (intro/outro) still go through the real eligibility checks.
    static func status(index: Int, plan: WizardPlan, scene: SceneRecord, sourceType: VideoType?,
                       saved: Saved, options: WizardOptions, xfadeDuration: Double,
                       unknownJoins: Set<Int> = [], randomRecipes: Bool = true,
                       cut: TimelineDocument? = nil,
                       preparation: WizardStrikePauses.Preparation? = nil) -> StrikeClipStatus {
        var saved = saved
        if options.drawnPauses == false { saved.drawings = []; saved.companionDrawings = [:] }
        let clip = plan.clips[index]
        var scenes = saved.companionScenes
        scenes[scene.id] = scene
        var types = saved.companionTypes
        types[scene.videoID] = sourceType
        var contactsByPath = saved.companionContacts
        contactsByPath[scene.videoPath] = saved.contacts
        var drawingsByPath = saved.companionDrawings
        drawingsByPath[scene.videoPath] = saved.drawings
        // The same cut, and so the same visible pictures, that Generate pauses.
        let extracted = clip.start.isFinite && clip.end.isFinite && clip.end > clip.start && clip.speed.isFinite && clip.speed > 0
            ? WizardSharedPauses.expanded(cut ?? cutDocument(clip: clip, plan: plan, scene: scene,
                sourceType: sourceType, options: options, sceneMap: scenes)) : nil
        let visible = extracted.map { WizardSharedPauses.visibleSources($0, sceneMap: scenes, main: scene.videoPath) }
        let candidates = WizardSharedPauses.candidates(clip, sceneMap: scenes, sourceTypes: types,
            contacts: contactsByPath, drawings: drawingsByPath, options: options, visible: visible)
        let drawings = candidates.drawings
        let unmarked = (sourceType == .fight && !saved.complete)
            || WizardSharedPauses.sources(clip, sceneMap: scenes).contains {
                $0.companion && types[$0.scene.videoID] == .fight && visible?.contains(($0.scene.videoPath as NSString).standardizingPath) != false
                    && saved.companionComplete[$0.scene.videoPath] == false
            }
        guard sourceType == .fight || candidates.useContacts || !drawings.isEmpty else {
            return .init(marks: 0, pause: .off, marksEnabled: false)
        }
        let marks = sourceType == .fight && options.strikeHighlights == true
            ? StrikeHighlightBurn.tracks(saved.tracks.map(StrikeHighlightRules.drawable),
                                         start: clip.start, duration: clip.end - clip.start).count : 0
        var result = StrikeClipStatus(marks: marks, pause: .off, marksEnabled: sourceType == .fight && options.strikeHighlights == true,
                                      markingIncomplete: unmarked)
        let useContacts = candidates.useContacts
        guard useContacts || !drawings.isEmpty else { return result }
        guard clip.start.isFinite, clip.end.isFinite, clip.end > clip.start,
              clip.speed.isFinite, clip.speed > 0 else {
            result.pause = .none(reason: "source pieces could not be split safely")
            return result
        }
        let document = cut ?? cutDocument(clip: clip, plan: plan, scene: scene, sourceType: sourceType, options: options, sceneMap: scenes)
        let prepared = preparation ?? WizardStrikePauses.prepare(plan: plan, cuts: [index: document],
            sceneMap: scenes, sourceTypes: types,
            contacts: contactsByPath, drawings: drawingsByPath, options: options, xfadeDuration: xfadeDuration)
        result.hardCutJoin = prepared.joins.changed(beside: index)
        result.movingDrawings = prepared.timings[index]?.movingDrawings.count ?? 0
        result.motionFallbackReasons = prepared.timings[index]?.motionFallbackReasons ?? []
        if WizardStrikePauses.impactRequested(options) {
            result.slowAddedDuration = prepared.timings[index]?.stretches.reduce(0) { $0 + $1.addedDuration } ?? 0
            let starts = prepared.cuts[index]?.videoTrack.filter { $0.flashIn != nil }.map(\.startTime) ?? []
            result.flashes = Set(starts.map { ($0 * 1000).rounded() }).count
            result.impactNotes = prepared.messages.filter {
                $0.contains("clip \(index + 1) —") || $0 == WizardStrikePauses.dubSkipMessage
            }
            if !WizardStrikePauses.requested(options), drawings.isEmpty { return result }
        }
        if let reason = WizardStrikePauses.skipReason(index: index, plan: plan, cut: document,
            scene: scene, sourceType: sourceType, options: options) {
            result.pause = .none(reason: reason)
            return result
        }
        if result.movingDrawings > 0, prepared.timings[index]?.pauses.isEmpty == true {
            result.unknownTransition = unknownJoins.contains(index - 1) || unknownJoins.contains(index)
            return result
        }
        // timing calls StrikeFreezeRules.selection: speed, edge spacing,
        // duplicates, the contact cap and hold length are the engine's rules.
        let expanded = WizardSharedPauses.expanded(document)
        let timing = candidates.resolved(for: clip, seconds: options.strikeImpactFreeze,
            tracks: expanded.videoTrack.count > 1 || !clip.areaClips.isEmpty ? WizardSharedPauses.tracks(expanded) : nil)
        result.filteredContacts = timing.filteredContacts
        guard !timing.pauses.isEmpty else {
            let contacts = candidates.contacts.filter { $0.isFinite && $0 >= clip.start && $0 <= clip.end }
            let reasons = Set(contacts.compactMap {
                StrikeFreezeRules.boundaryReason(start: clip.start, end: clip.end, speed: clip.speed, contact: $0)
            })
            let reason: String
            if !drawings.isEmpty {
                reason = "drawings too close to an edge or another pause, or over the limit"
            } else if contacts.isEmpty {
                reason = unmarked ? "strike marking not finished"
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
        let lengths = (prepared.timings[index]?.pauses ?? []).map(\.duration)
        if let length = lengths.first, lengths.allSatisfy({ $0 == length }) {
            result.pause = .pauses(count: lengths.count, seconds: length)
        } else {
            result.pause = .mixedPauses(seconds: lengths)
        }
        result.unknownTransition = unknownJoins.contains(index - 1) || unknownJoins.contains(index)
        result.conditionalTransition = result.unknownTransition && randomRecipes
        return result
    }

    static func cutDocument(clip: WizardPlanClip, plan: WizardPlan, scene: SceneRecord,
                            sourceType: VideoType?, options: WizardOptions,
                            sceneMap: [Int64: SceneRecord] = [:]) -> TimelineDocument {
        let context = FramingContext(scene: scene, range: clip.start...max(clip.start, clip.end),
            canvasAspect: options.renderSettings.aspectRatio, chosenSubject: plan.framing, type: sourceType)
        var scenes = sceneMap
        scenes[scene.id] = scene
        return WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: scenes,
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
            // After the marks count "pauses on 0" says the joins rule them out; on its own
            // (a reel with only drawings) it reads as noise, so it is left out.
            if !parts.isEmpty {
                parts.append(certain == possible ? "pauses on \(certain)" : "pauses on up to \(possible) (Random)")
            } else if possible > 0 {
                let clips = { (count: Int) in "\(count) \(count == 1 ? "clip" : "clips")" }
                parts.append(certain == possible ? "Pauses on \(clips(certain))" : "Pauses on up to \(clips(possible)) (Random)")
            }
        }
        if statuses.contains(where: \.markingIncomplete) { parts.append("saved so far") }
        let added = statuses.reduce(0) { $0 + $1.slowAddedDuration }
        if added > 0 { parts.append("slow motion adds \(added.formatted(.number.precision(.fractionLength(0...2)))) s") }
        let flashes = statuses.reduce(0) { $0 + $1.flashes }
        if flashes > 0 { parts.append("\(flashes) flashes") }
        return parts.joined(separator: " · ")
    }
}
