import Foundation

/// Assembly-only pauses. The editorial plan and its source ranges never change.
nonisolated enum WizardStrikePauses {
    static let dubSkipMessage = "Pause on contact: skipped for dubbed reels; holds have no speech."

    struct Pause: Sendable, Equatable {
        /// Seconds on the unpaused output clock (already divided by speed).
        var time: Double
        var duration: Double
    }

    struct Timing: Sendable, Equatable {
        var plannedDuration: Double
        var pauses: [Pause] = []
        var filteredContacts = 0
        var addedDuration: Double { pauses.reduce(0) { $0 + $1.duration } }
        var outputDuration: Double { plannedDuration + addedDuration }

        /// A label starting at contact appears on the held frame; a label
        /// ending there ends before it. A spanning label covers the whole hold.
        func outputTime(_ time: Double) -> Double {
            time + pauses.reduce(0) { $0 + ($1.time < time - 1e-9 ? $1.duration : 0) }
        }

        func captions(_ overlays: [CaptionOverlayPlan.Overlay]) -> [CaptionOverlayPlan.Overlay] {
            if plannedDuration <= 1e-9, !pauses.isEmpty {
                return overlays.filter { $0.start <= 1e-9 && $0.end > 0 }.map { item in
                    var item = item
                    item.start = 0
                    item.end = outputDuration
                    return item
                }
            }
            return overlays.map { item in
                var item = item
                item.start = outputTime(item.start)
                item.end = outputTime(item.end)
                return item
            }
        }
    }

    /// The single decision about selected contacts, hold length and paused
    /// length. Edge spacing, deduplication and the cap belong to StrikeFreezeRules.
    static func timing(for clip: WizardPlanClip, contacts: [Double], seconds: Double?) -> Timing {
        let duration = clip.speed.isFinite && clip.speed > 0 ? max(0, (clip.end - clip.start) / clip.speed) : 0
        var result = Timing(plannedDuration: duration)
        guard let seconds, seconds.isFinite, seconds > 0 else { return result }
        var source = TimelineClip()
        source.sourceStart = clip.start
        source.sourceEnd = clip.end
        source.duration = duration
        source.speed = clip.speed
        source.precision = .speech
        let hold = min(StrikeFreezeRules.holdRange.upperBound, max(StrikeFreezeRules.holdRange.lowerBound, seconds))
        let selected = StrikeFreezeRules.selection(source, contacts: contacts)
        result.filteredContacts = selected.filtered
        result.pauses = selected.contacts.map {
            Pause(time: ($0 - clip.start) / clip.speed, duration: hold)
        }
        return result
    }

    static func requested(_ options: WizardOptions) -> Bool {
        guard let seconds = options.strikeImpactFreeze else { return false }
        return seconds.isFinite && seconds > 0
    }

    /// A rough cut keeps its presentation options separate from the final
    /// reel's eligibility. Only the current pause switch/seconds override it.
    static func eligibilityOptions(_ options: WizardOptions, original: WizardOptions?) -> WizardOptions {
        var result = original ?? options
        result.strikeImpactFreeze = options.strikeImpactFreeze
        return result
    }

    /// Reject what can be known before expensive source marking. Contact edge
    /// spacing is checked afterwards, using the same final-reel plan.
    static func skipReason(index: Int, plan: WizardPlan, cut: TimelineDocument?, scene: SceneRecord,
                           sourceType: VideoType?, options: WizardOptions) -> String? {
        let clip = plan.clips[index]
        if options.dubLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "dubbed reels have no speech during holds"
        }
        if let cut, cut.videoTrack.count != 1 || cut.videoTrack.first?.track != 0
            || cut.videoTrack.first?.isCutaway == true || cut.videoTrack.first?.framingPlan?.isComposed == true {
            return "composed or B-roll cut needs a shared multi-source pause"
        }
        if clip.layout != nil || !clip.areaClips.isEmpty || (options.useBRoll && !(clip.brollCuts ?? []).isEmpty) {
            return "composed or B-roll cut needs a shared multi-source pause"
        }
        if options.manualBRoll != true, options.useBRoll,
           (ReelRecipe.recipe(id: options.formatPreset) ?? .custom).capabilities.bRoll,
           (options.requestedFraming.subject == .auto ? plan.framing : options.requestedFraming.subject) == .vipFocus
                || !options.brollInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           WizardPodcastBRoll.eligibleSource(type: sourceType, scene: scene,
               start: clip.start, end: clip.end, speed: clip.speed) {
            return "automatic cutaways would cover or retime the held frame"
        }
        if options.includeMiddleBumper || (index == 0 && options.includeIntroBumper)
            || (index == plan.clips.count - 1 && options.includeOutroBumper) {
            return "bumper placement needs the unsplit cut"
        }
        let joins = transitions(index: index, plan: plan, options: options)
        if TransitionRecipes.isRecipe(joins.incoming) || TransitionRecipes.isRecipe(joins.outgoing) {
            return "recipe transition joins need the unsplit cut"
        }
        if let original = cut?.videoTrack.first {
            let duration = timing(for: clip, contacts: [], seconds: nil).plannedDuration
            if abs((original.sourceStart ?? -1) - clip.start) >= 1e-9
                || abs(original.sourceSpan - (clip.end - clip.start)) >= 1e-9
                || abs(original.duration - duration) >= 1e-9 {
                return "extraction source clock differs from the planned clip"
            }
        }
        return nil
    }

    static func contactPaths(plan: WizardPlan, cuts: [Int: TimelineDocument], sceneMap: [Int64: SceneRecord],
                             sourceTypes: [Int64: VideoType], options: WizardOptions) -> Set<String> {
        guard requested(options) else { return [] }
        return Set(plan.clips.enumerated().compactMap { index, clip in
            guard let scene = sceneMap[clip.sceneID], sourceTypes[scene.videoID] == .fight,
                  skipReason(index: index, plan: plan, cut: cuts[index], scene: scene,
                             sourceType: sourceTypes[scene.videoID], options: options) == nil else { return nil }
            return scene.videoPath
        })
    }

    private static func transitions(index: Int, plan: WizardPlan, options: WizardOptions) -> (incoming: String, outgoing: String) {
        let incoming = index > 0 ? plan.transitions[safe: index - 1] ?? "cut"
            : options.formatPreset == "compilation" && plan.introTitle != nil ? "fade" : "cut"
        let outgoing = index < plan.clips.count - 1 ? plan.transitions[safe: index] ?? "cut"
            : options.includeOutro ? "fadeblack" : "cut"
        return (incoming, outgoing)
    }

    struct Eligibility: Sendable {
        var plan: WizardPlan
        var options: WizardOptions
    }

    /// Pause previews and Generate must choose the same random joins for a
    /// saved selection. Only pause-enabled renders use this stable shuffle.
    static func renderTransitions(plan: WizardPlan, options: WizardOptions) -> [String] {
        guard requested(options) else {
            return WizardPlanRules.transitions(choice: options.transitionChoice,
                allowed: options.allowedTransitions, count: plan.clips.count - 1)
        }
        var generator = TransitionGenerator()
        for clip in plan.clips {
            for value in [UInt64(bitPattern: clip.sceneID), clip.start.bitPattern, clip.end.bitPattern] {
                generator.state = (generator.state ^ value) &* 1099511628211
            }
        }
        return WizardPlanRules.transitions(choice: options.transitionChoice, allowed: options.allowedTransitions,
            count: plan.clips.count - 1, using: &generator)
    }

    private nonisolated struct TransitionGenerator: RandomNumberGenerator {
        var state: UInt64 = 14695981039346656037
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    struct Preparation: Sendable {
        var cuts: [Int: TimelineDocument]
        var timings: [Int: Timing]
        var messages: [String]
        var joins: Joins
    }

    struct JoinChange: Sendable, Equatable {
        /// Boundary after this clip; -1 is the title card, count - 1 the outro.
        var boundary: Int
        var clip: Int
    }

    struct Joins: Sendable, Equatable {
        var transitions: [String]
        var incoming: String
        var outgoing: String
        var changes: [JoinChange] = []

        func changed(beside index: Int) -> Bool {
            changes.contains { $0.boundary == index - 1 || $0.boundary == index }
        }

        func messages(clipCount: Int) -> [String] {
            changes.map { change in
                let destination = change.boundary == clipCount - 1 ? "the outro" : "clip \(change.boundary + 2)"
                return "Pause on contact: clip \(change.clip + 1) — transition into \(destination) replaced by a cut to keep the pause."
            }
        }
    }

    /// The only pause-to-join override. Feed it timings AFTER eligibility and
    /// safe splitting, never raw contacts. Both sides inspect the original join;
    /// a shared boundary is changed/logged once, in reel order. Recipe bridges
    /// remain subject to skipReason and are never converted here.
    static func resolveJoins(plan: WizardPlan, options: WizardOptions, timings: [Int: Timing],
                             xfadeDuration: Double) -> Joins {
        var result = Joins(transitions: plan.transitions,
            incoming: plan.clips.isEmpty ? "cut" : transitions(index: 0, plan: plan, options: options).incoming,
            outgoing: plan.clips.isEmpty ? "cut" : transitions(index: plan.clips.count - 1, plan: plan, options: options).outgoing)
        guard requested(options) else { return result }
        var changed: [Int: Int] = [:]
        for index in plan.clips.indices {
            guard let timing = timings[index], let first = timing.pauses.first, let last = timing.pauses.last else { continue }
            let joins = transitions(index: index, plan: plan, options: options)
            for (boundary, span, name) in [(index - 1, first.time, joins.incoming),
                                         (index, timing.plannedDuration - last.time, joins.outgoing)] {
                guard !TransitionRecipes.isRecipe(name),
                      !edgeSupportsTransition(span, name: name, xfadeDuration: xfadeDuration) else { continue }
                if changed[boundary] == nil { changed[boundary] = index }
            }
        }
        for (boundary, clip) in changed.sorted(by: { $0.key < $1.key }) {
            if boundary == -1 { result.incoming = "cut" }
            else if boundary == plan.clips.count - 1 { result.outgoing = "cut" }
            else { result.transitions[boundary] = "cut" }
            result.changes.append(JoinChange(boundary: boundary, clip: clip))
        }
        return result
    }

    /// Both proxy/document building and final extraction use these exact cuts.
    /// Unsupported multi-source cuts remain wholly unchanged, including timing.
    static func prepare(plan: WizardPlan, cuts: [Int: TimelineDocument], sceneMap: [Int64: SceneRecord],
                        sourceTypes: [Int64: VideoType], contacts: [String: [Double]],
                        options: WizardOptions, xfadeDuration: Double,
                        presentation: Eligibility? = nil) -> Preparation {
        let renderPlan = presentation?.plan ?? plan
        let renderOptions = presentation?.options ?? options
        var result = Preparation(cuts: cuts, timings: [:], messages: [],
            joins: resolveJoins(plan: renderPlan, options: renderOptions, timings: [:], xfadeDuration: xfadeDuration))
        for (index, clip) in plan.clips.enumerated() {
            result.timings[index] = timing(for: clip, contacts: [], seconds: nil)
        }
        guard requested(options) else { return result }
        if options.dubLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            result.messages = [dubSkipMessage]
            return result
        }
        for (index, clip) in plan.clips.enumerated() {
            guard let scene = sceneMap[clip.sceneID], sourceTypes[scene.videoID] == .fight,
                  var cut = cuts[index] else { continue }
            if let reason = skipReason(index: index, plan: plan, cut: cut, scene: scene,
                                       sourceType: sourceTypes[scene.videoID], options: options)
                ?? skipReason(index: index, plan: renderPlan, cut: cut, scene: scene,
                              sourceType: sourceTypes[scene.videoID], options: renderOptions) {
                result.messages.append("Pause on contact: skipped clip \(index + 1) — \(reason).")
                continue
            }
            let timing = timing(for: clip, contacts: contacts[scene.videoPath] ?? [],
                                seconds: options.strikeImpactFreeze)
            // One short line per clip, also when every in-range contact was
            // filtered. The caller deduplicates these through the run snapshot.
            if timing.filteredContacts > 0 {
                result.messages.append("Pause on contact: clip \(index + 1) — skipped \(timing.filteredContacts) contact(s) (spacing or limit).")
            }
            guard !timing.pauses.isEmpty else { continue }
            guard let original = cut.videoTrack.first else { continue }
            let contacts = timing.pauses.map { clip.start + $0.time * clip.speed }
            let pieces = StrikeFreezeRules.pieces(original, contacts: contacts, hold: timing.pauses[0].duration)
            guard !pieces.isEmpty else {
                if timing.filteredContacts > 0 { result.messages.removeLast() }
                result.messages.append("Pause on contact: skipped clip \(index + 1) — source pieces could not be split safely.")
                continue
            }
            cut.videoTrack = pieces
            mapLayers(in: &cut, timing: timing)
            result.cuts[index] = cut
            result.timings[index] = timing
        }
        result.joins = resolveJoins(plan: renderPlan, options: renderOptions, timings: result.timings,
                                    xfadeDuration: xfadeDuration)
        result.messages += result.joins.messages(clipCount: renderPlan.clips.count)
        return result
    }

    /// Ask the renderer's join policy instead of copying its affordability rule.
    private static func edgeSupportsTransition(_ duration: Double, name: String, xfadeDuration: Double) -> Bool {
        guard name != "cut" else { return true }
        let requested = RenderEngine.consumedOverlap(name, xfadeDuration: xfadeDuration)
        guard let gaps = try? RenderEngine.resolvedGaps(durations: [duration, duration], transitions: [name],
            configured: xfadeDuration, maximumOverlap: nil), let gap = gaps.first else { return false }
        return gap.duration >= requested - 1e-9
    }

    static func mapLayers(in document: inout TimelineDocument, timing: Timing) {
        guard !timing.pauses.isEmpty else { return }
        for index in document.textOverlays.indices {
            document.textOverlays[index].startTime = timing.outputTime(document.textOverlays[index].startTime)
            document.textOverlays[index].endTime = timing.outputTime(document.textOverlays[index].endTime)
        }
        for index in document.imageOverlays.indices {
            document.imageOverlays[index].startTime = timing.outputTime(document.imageOverlays[index].startTime)
            document.imageOverlays[index].endTime = timing.outputTime(document.imageOverlays[index].endTime)
            document.imageOverlays[index].track = document.imageOverlays[index].track?.map { key in
                var key = key
                key.time = timing.outputTime(key.time)
                return key
            }
        }
        for index in document.cropBlocks.indices {
            let start = document.cropBlocks[index].startTime
            document.cropBlocks[index].duration = timing.outputTime(start + document.cropBlocks[index].duration) - timing.outputTime(start)
            document.cropBlocks[index].startTime = timing.outputTime(start)
        }
        for index in document.overlayBlocks.indices {
            let start = document.overlayBlocks[index].startTime
            document.overlayBlocks[index].duration = timing.outputTime(start + document.overlayBlocks[index].duration) - timing.outputTime(start)
            document.overlayBlocks[index].startTime = timing.outputTime(start)
            // Block item windows are local to the block, not to the cut.
            for item in document.overlayBlocks[index].composition.texts.indices {
                let value = document.overlayBlocks[index].composition.texts[item]
                document.overlayBlocks[index].composition.texts[item].startTime = timing.outputTime(start + value.startTime) - timing.outputTime(start)
                document.overlayBlocks[index].composition.texts[item].endTime = timing.outputTime(start + value.endTime) - timing.outputTime(start)
            }
            for item in document.overlayBlocks[index].composition.images.indices {
                let value = document.overlayBlocks[index].composition.images[item]
                document.overlayBlocks[index].composition.images[item].startTime = timing.outputTime(start + value.startTime) - timing.outputTime(start)
                document.overlayBlocks[index].composition.images[item].endTime = timing.outputTime(start + value.endTime) - timing.outputTime(start)
                document.overlayBlocks[index].composition.images[item].track = value.track?.map { key in
                    var key = key
                    key.time = timing.outputTime(start + key.time) - timing.outputTime(start)
                    return key
                }
            }
        }
        for index in document.soundTrack.indices {
            let start = document.soundTrack[index].startTime
            document.soundTrack[index].duration = timing.outputTime(start + document.soundTrack[index].duration) - timing.outputTime(start)
            document.soundTrack[index].startTime = timing.outputTime(start)
        }
    }
}
