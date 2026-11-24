import Foundation

/// Assembly-only pauses. The editorial plan and its source ranges never change.
nonisolated enum WizardStrikePauses {
    static let dubSkipMessage = "Pause on contact: skipped for dubbed reels; holds have no speech."

    struct Pause: Sendable, Equatable {
        /// Seconds on the unpaused output clock (already divided by speed).
        var time: Double
        var duration: Double
        var drawing: Telestration? = nil
        /// Drawing owner video path; nil means the main source.
        var source: String? = nil
    }

    struct Timing: Sendable, Equatable {
        var plannedDuration: Double
        var pauses: [Pause] = []
        /// Intervals on the original planned screen clock.
        var stretches: [StrikeImpactRules.Stretch] = []
        var movingDrawings: [Telestration] = []
        var motionFallbackReasons: [String] = []
        var filteredSlowContacts = 0
        var impactSplit = false
        var filteredContacts = 0
        var filteredDrawings = 0
        /// Shared cuts only: the shortest whole stretch at each end, when a
        /// companion picture starts or stops nearer the edge than a pause.
        var headSegment: Double? = nil
        var tailSegment: Double? = nil
        var addedDuration: Double { pauses.reduce(0) { $0 + $1.duration } + stretches.reduce(0) { $0 + $1.addedDuration } }
        var outputDuration: Double { plannedDuration + addedDuration }

        /// A label starting at contact appears on the held frame; a label
        /// ending there ends before it. A spanning label covers the whole hold.
        func outputTime(_ time: Double) -> Double {
            time + pauses.reduce(0) { $0 + ($1.time < time - 1e-9 ? $1.duration : 0) }
                + stretches.reduce(0) { $0 + $1.addedTime(at: time) }
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

        /// Add keys at changes of rate so interpolation follows the same
        /// piecewise clock as the picture. Existing pause-only maps stay intact.
        func imageKeys(_ keys: [ImageTrackKey], origin: Double = 0) -> [ImageTrackKey] {
            var samples = keys
            if !stretches.isEmpty, let first = keys.first, let last = keys.last {
                let boundaries = stretches.flatMap { [$0.start, $0.end] } + pauses.map(\.time)
                for time in Set(boundaries).sorted() {
                    let local = time - origin
                    guard local > first.time, local < last.time,
                          !samples.contains(where: { abs($0.time - local) < 1e-9 }),
                          var key = ImageTrackKey.interpolate(keys, at: local) else { continue }
                    key.time = local
                    samples.append(key)
                }
            }
            var result = samples.map { key in
                var key = key
                key.time = outputTime(origin + key.time) - outputTime(origin)
                return key
            }
            if !stretches.isEmpty {
                for pause in pauses {
                    guard let first = keys.first, let last = keys.last,
                          pause.time - origin >= first.time, pause.time - origin < last.time,
                          var key = ImageTrackKey.interpolate(keys, at: pause.time - origin) else { continue }
                    key.time = outputTime(pause.time) + pause.duration - outputTime(origin)
                    result.append(key)
                }
                result.sort { $0.time < $1.time }
            }
            return result
        }
    }

    /// The single decision about selected contacts, hold length and paused
    /// length. Edge spacing, deduplication and the cap belong to StrikeFreezeRules.
    static func timing(for clip: WizardPlanClip, contacts: [Double], seconds: Double?) -> Timing {
        timing(for: clip, contacts: contacts, seconds: seconds, drawings: [])
    }

    static func timing(for clip: WizardPlanClip, contacts: [Double], seconds: Double?, drawings: [Telestration]) -> Timing {
        if drawings.contains(where: { $0.motion != nil }) {
            return motionTiming(for: clip, contacts: contacts, seconds: seconds, drawings: drawings)
        }
        let duration = clip.speed.isFinite && clip.speed > 0 ? max(0, (clip.end - clip.start) / clip.speed) : 0
        var result = Timing(plannedDuration: duration)
        var source = TimelineClip()
        source.sourceStart = clip.start
        source.sourceEnd = clip.end
        source.duration = duration
        source.speed = clip.speed
        source.precision = .speech
        // Keep the old selection path exactly intact when there are no drawings.
        if !drawings.isEmpty {
            let candidates = drawings.enumerated().filter {
                $0.element.time.isFinite && $0.element.time >= clip.start && $0.element.time <= clip.end
            }.sorted {
                $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
            }.map { $0.element }
            guard clip.start.isFinite, clip.start >= 0, clip.end.isFinite, clip.end > clip.start,
                  clip.speed.isFinite, clip.speed > 0 else {
                result.filteredDrawings = candidates.count
                return result
            }
            let minimum = StrikeFreezeRules.minimumPiece * clip.speed
            var kept: [Telestration] = []
            for drawing in candidates {
                guard drawing.duration.isFinite, StrikeFreezeRules.drawingHoldRange.contains(drawing.duration),
                      StrikeFreezeRules.boundaryReason(start: clip.start, end: clip.end, speed: clip.speed, contact: drawing.time) == nil,
                      drawing.time - (kept.last?.time ?? clip.start) >= minimum - 1e-9,
                      kept.count < StrikeFreezeRules.maximumDrawings else {
                    result.filteredDrawings += 1
                    continue
                }
                kept.append(drawing)
            }
            result.pauses = kept.map { Pause(time: ($0.time - clip.start) / clip.speed, duration: $0.duration, drawing: $0) }
            if let seconds, seconds.isFinite, seconds > 0 {
                let available = contacts.filter { contact in
                    !kept.contains { abs($0.time - contact) <= 0.25 + 1e-9 || abs($0.time - contact) < minimum - 1e-9 }
                }
                let selected = StrikeFreezeRules.selection(source, contacts: available)
                // Replaced by a drawing is not a skip; too close to one is.
                let crowded = contacts.filter { contact in
                    contact >= clip.start && contact <= clip.end && !available.contains(contact)
                        && !kept.contains { abs($0.time - contact) <= 0.25 + 1e-9 }
                }.count
                result.filteredContacts = selected.filtered + crowded
                let hold = min(StrikeFreezeRules.holdRange.upperBound, max(StrikeFreezeRules.holdRange.lowerBound, seconds))
                result.pauses += selected.contacts.map { Pause(time: ($0 - clip.start) / clip.speed, duration: hold) }
            }
            result.pauses.sort { $0.time < $1.time }
            return result
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return result }
        let hold = min(StrikeFreezeRules.holdRange.upperBound, max(StrikeFreezeRules.holdRange.lowerBound, seconds))
        let selected = StrikeFreezeRules.selection(source, contacts: contacts)
        result.filteredContacts = selected.filtered
        result.pauses = selected.contacts.map {
            Pause(time: ($0 - clip.start) / clip.speed, duration: hold)
        }
        return result
    }

    /// Retain the old drawing/spacing selection. Only a moving drawing that
    /// survives every split replaces contacts throughout its source span.
    private static func motionTiming(for clip: WizardPlanClip, contacts: [Double], seconds: Double?,
                                     drawings: [Telestration]) -> Timing {
        let paused = drawings.map(TelestrationMotionRules.paused)
        let selection = timing(for: clip, contacts: [], seconds: nil, drawings: paused)
        var kept = selection.pauses.compactMap { pause -> Telestration? in
            guard let drawing = pause.drawing else { return nil }
            return drawings.first { TelestrationMotionRules.paused($0) == drawing }
        }
        var source = TimelineClip()
        source.sourceStart = clip.start
        source.sourceEnd = clip.end
        source.speed = clip.speed
        source.duration = selection.plannedDuration
        source.precision = .speech
        var reasons: [String] = []
        while true {
            // Resolve conflicts against all kept drawings before changing any
            // of them, so overlapping moving spans cannot win by array order.
            let failures = kept.indices.compactMap { index -> (Int, String)? in
                guard kept[index].motion != nil,
                      let reason = TelestrationMotionRules.fallbackReason(kept[index], in: [source], drawings: kept) else { return nil }
                return (index, reason)
            }
            for (index, reason) in failures {
                kept[index].motion = nil
                reasons.append(reason)
            }
            let moving = kept.filter { $0.motion != nil }
            let available = contacts.filter { contact in
                !moving.contains { contact >= $0.time && contact < $0.time + $0.sourceSpan * clip.speed }
            }
            var result = timing(for: clip, contacts: available, seconds: seconds,
                drawings: kept.map(TelestrationMotionRules.paused))
            result.filteredDrawings = selection.filteredDrawings
            result.pauses.removeAll { pause in
                moving.contains { TelestrationMotionRules.paused($0) == pause.drawing }
            }
            let pauses = result.pauses.map {
                StrikeFreezeRules.Pause(time: clip.start + $0.time * clip.speed, duration: $0.duration, drawing: $0.drawing)
            }
            let pieces = pauses.isEmpty ? [source] : StrikeFreezeRules.pieces(source, pauses: pauses)
            let applied = TelestrationMotionRules.moving(pieces, drawings: moving)
            if applied.fallback.isEmpty {
                result.movingDrawings = moving
                result.stretches = applied.stretches.map {
                    .init(start: ($0.start - clip.start) / clip.speed,
                          end: ($0.end - clip.start) / clip.speed, factor: $0.factor)
                }
                result.impactSplit = !moving.isEmpty
                result.motionFallbackReasons = Array(Set(reasons)).sorted()
                return result
            }
            for fallback in applied.fallback {
                guard let index = kept.firstIndex(where: { TelestrationMotionRules.paused($0) == fallback }) else { continue }
                reasons.append(TelestrationMotionRules.fallbackReason(kept[index], in: pieces, drawings: kept)
                    ?? "a piece would be too short")
                kept[index].motion = nil
            }
        }
    }

    static func requested(_ options: WizardOptions) -> Bool {
        guard let seconds = options.strikeImpactFreeze else { return false }
        return seconds.isFinite && seconds > 0
    }

    static func impactRequested(_ options: WizardOptions) -> Bool {
        options.strikeFlash == true || StrikeImpactRules.strength(saved: options.strikeSlowMotion ?? "") != nil
    }

    static func contactsRequested(_ options: WizardOptions) -> Bool {
        requested(options) || impactRequested(options)
    }

    /// Fetch by video once, then use the same source-path keys as contacts.
    static func drawings(plan: WizardPlan, sceneMap: [Int64: SceneRecord], database: Database) async throws -> [String: [Telestration]] {
        let scenes = plan.clips.flatMap { WizardSharedPauses.sources($0, sceneMap: sceneMap).map(\.scene) }
        let records = try await database.fetchTelestrations(videoIDs: scenes.map(\.videoID))
        return Dictionary(scenes.map { ($0.videoPath, (records[$0.videoID] ?? []).map(\.drawing)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// A rough cut keeps its presentation options separate from the final
    /// reel's eligibility. Only the current pause switch/seconds override it.
    static func eligibilityOptions(_ options: WizardOptions, original: WizardOptions?) -> WizardOptions {
        var result = original ?? options
        result.drawnPauses = options.drawnPauses
        result.removeFillerWords = options.removeFillerWords
        result.strikeImpactFreeze = options.strikeImpactFreeze
        result.strikeSlowMotion = options.strikeSlowMotion
        result.strikeFlash = options.strikeFlash
        return result
    }

    /// Reject what can be known before expensive source marking. Contact edge
    /// spacing is checked afterwards, using the same final-reel plan.
    static func skipReason(index: Int, plan: WizardPlan, cut: TimelineDocument?, scene: SceneRecord,
                           sourceType: VideoType?, options: WizardOptions) -> String? {
        let clip = plan.clips[index]
        let cut = cut.map { WizardSharedPauses.expanded($0) }
        if options.dubLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "dubbed reels have no speech during holds"
        }
        if cut?.videoTrack.contains(where: \.isCutaway) == true
            || (options.useBRoll && !(clip.brollCuts ?? []).isEmpty) {
            return "B-roll cutaways would cover the held frame"
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
        if let cut, cut.videoTrack.count == 1, let original = cut.videoTrack.first, original.track == 0 {
            let duration = timing(for: clip, contacts: [], seconds: nil).plannedDuration
            if abs((original.sourceStart ?? -1) - clip.start) >= 1e-9
                || abs(original.sourceSpan - (clip.end - clip.start)) >= 1e-9
                || abs(original.duration - duration) >= 1e-9 {
                return "extraction source clock differs from the planned clip"
            }
        } else if let cut {
            let originals = cut.videoTrack.filter { $0.track == 0 }
            guard !originals.isEmpty else { return "extraction source clock differs from the planned clip" }
            for original in originals {
                let sourceStart = clip.start + original.startTime * clip.speed
                let span = original.duration * clip.speed
                if abs((original.sourceStart ?? -1) - sourceStart) >= 1e-9
                    || abs(original.sourceSpan - span) >= 1e-9
                    || abs(original.effectiveSpeed - clip.speed) >= 1e-9
                    || original.startTime < 0
                    || sourceStart + span > clip.end + 1e-9 {
                    return "extraction source clock differs from the planned clip"
                }
            }
        }
        return nil
    }

    static func contactPaths(plan: WizardPlan, cuts: [Int: TimelineDocument], sceneMap: [Int64: SceneRecord],
                             sourceTypes: [Int64: VideoType], options: WizardOptions) -> Set<String> {
        guard contactsRequested(options) else { return [] }
        var paths = Set<String>()
        for (index, clip) in plan.clips.enumerated() {
            guard let scene = sceneMap[clip.sceneID],
                  skipReason(index: index, plan: plan, cut: cuts[index], scene: scene,
                             sourceType: sourceTypes[scene.videoID], options: options) == nil else { continue }
            for source in WizardSharedPauses.sources(clip, sceneMap: sceneMap)
                where sourceTypes[source.scene.videoID] == .fight {
                paths.insert(source.scene.videoPath)
            }
        }
        return paths
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
    /// The clips whose own footage (or a companion's) carries a saved drawing.
    static func drawnClips(plan: WizardPlan, sceneMap: [Int64: SceneRecord], drawings: [String: [Telestration]]) -> Set<Int> {
        Set(plan.clips.indices.filter { index in
            WizardSharedPauses.sources(plan.clips[index], sceneMap: sceneMap).contains { source in
                (drawings[source.scene.videoPath] ?? []).contains { $0.time >= source.start && $0.time < source.end }
            }
        })
    }

    /// Random never costs a clip its drawing: a recipe transition (which needs the
    /// unsplit cut, so the drawing would be skipped) at either join of a drawn clip is
    /// replaced by a plain one from the allowed pool, or a hard cut when there is none.
    /// A transition the user chose by name is left as chosen.
    static func sparingDrawings(_ transitions: [String], drawn: Set<Int>, options: WizardOptions) -> [String] {
        guard options.transitionChoice == WizardPlanRules.randomTransitionChoice, options.drawnPauses != false,
              !drawn.isEmpty else { return transitions }
        let valid = Set(RenderEngine.allTransitions)
        var seen = Set<String>()
        let pool = (options.allowedTransitions ?? RenderEngine.allTransitions).filter {
            $0 != "cut" && valid.contains($0) && !TransitionRecipes.isRecipe($0) && seen.insert($0).inserted
        }
        var result = transitions
        for join in result.indices where TransitionRecipes.isRecipe(result[join])
            && (drawn.contains(join) || drawn.contains(join + 1)) {
            // Stable for a plan, and not the neighbour's effect when the pool allows.
            let before = join > 0 ? result[join - 1] : nil
            let candidates = pool.count > 1 ? pool.filter { $0 != before } : pool
            result[join] = candidates.isEmpty ? "cut" : candidates[join % candidates.count]
        }
        return result
    }

    static func renderTransitions(plan: WizardPlan, options: WizardOptions) -> [String] {
        guard contactsRequested(options) else {
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
        var drawing = false
        var impact = false
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
                return "\(change.impact ? "Contact effects" : change.drawing ? "Drawing" : "Pause on contact"): clip \(change.clip + 1) — transition into \(destination) replaced by a cut to keep the \(change.impact ? "contact effect" : "pause")."
            }
        }
    }

    /// The only pause-to-join override. Feed it timings AFTER eligibility and
    /// safe splitting, never raw contacts. Both sides inspect the original join;
    /// a shared boundary is changed/logged once, in reel order. Recipe bridges
    /// remain subject to skipReason and are never converted here.
    static func resolveJoins(plan: WizardPlan, options: WizardOptions, timings: [Int: Timing],
                             xfadeDuration: Double) -> Joins {
        let timings = options.drawnPauses == false ? timings.mapValues { timing in
            var result = timing
            result.pauses = timing.pauses.filter { $0.drawing == nil }
            return result
        } : timings
        var result = Joins(transitions: plan.transitions,
            incoming: plan.clips.isEmpty ? "cut" : transitions(index: 0, plan: plan, options: options).incoming,
            outgoing: plan.clips.isEmpty ? "cut" : transitions(index: plan.clips.count - 1, plan: plan, options: options).outgoing)
        guard contactsRequested(options) || timings.values.contains(where: { !$0.movingDrawings.isEmpty || $0.pauses.contains { $0.drawing != nil } }) else { return result }
        var changed: [Int: Int] = [:]
        for index in plan.clips.indices {
            guard let timing = timings[index], !timing.pauses.isEmpty || timing.impactSplit else { continue }
            let head = timing.impactSplit ? timing.headSegment ?? timing.outputDuration
                : min(timing.pauses.first?.time ?? timing.plannedDuration, timing.headSegment ?? .infinity)
            let tail = timing.impactSplit ? timing.tailSegment ?? timing.outputDuration
                : min(timing.plannedDuration - (timing.pauses.last?.time ?? 0), timing.tailSegment ?? .infinity)
            let joins = transitions(index: index, plan: plan, options: options)
            for (boundary, span, name) in [(index - 1, head, joins.incoming),
                                         (index, tail, joins.outgoing)] {
                guard !TransitionRecipes.isRecipe(name),
                      !edgeSupportsTransition(span, name: name, xfadeDuration: xfadeDuration) else { continue }
                if changed[boundary] == nil { changed[boundary] = index }
            }
        }
        for (boundary, clip) in changed.sorted(by: { $0.key < $1.key }) {
            if boundary == -1 { result.incoming = "cut" }
            else if boundary == plan.clips.count - 1 { result.outgoing = "cut" }
            else { result.transitions[boundary] = "cut" }
            let pause = boundary < clip ? timings[clip]?.pauses.first : timings[clip]?.pauses.last
            result.changes.append(JoinChange(boundary: boundary, clip: clip, drawing: pause?.drawing != nil, impact: timings[clip]?.impactSplit == true))
        }
        return result
    }

    /// Both proxy/document building and final extraction use these exact cuts.
    /// All pictures in a shared cut pause together on the same output clock.
    private static func preparePauses(plan: WizardPlan, cuts: [Int: TimelineDocument], sceneMap: [Int64: SceneRecord],
                        sourceTypes: [Int64: VideoType], contacts: [String: [Double]],
                        drawings: [String: [Telestration]] = [:],
                        options: WizardOptions, xfadeDuration: Double,
                        presentation: Eligibility? = nil) -> Preparation {
        let drawings = options.drawnPauses == false ? [:] : drawings
        let renderPlan = presentation?.plan ?? plan
        let renderOptions = presentation?.options ?? options
        var result = Preparation(cuts: cuts, timings: [:], messages: [],
            joins: resolveJoins(plan: renderPlan, options: renderOptions, timings: [:], xfadeDuration: xfadeDuration))
        for (index, clip) in plan.clips.enumerated() {
            result.timings[index] = timing(for: clip, contacts: [], seconds: nil)
        }
        let hasDrawings = plan.clips.contains { clip in
            WizardSharedPauses.sources(clip, sceneMap: sceneMap).contains { source in
                drawings[source.scene.videoPath]?.contains { $0.time >= source.start && $0.time <= source.end } == true
            }
        }
        guard requested(options) || hasDrawings else { return result }
        if options.dubLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            if requested(options) { result.messages.append(dubSkipMessage) }
            if hasDrawings { result.messages.append("Drawing: skipped for dubbed reels; holds have no speech.") }
            return result
        }
        for (index, clip) in plan.clips.enumerated() {
            guard let scene = sceneMap[clip.sceneID],
                  var cut = cuts[index] else { continue }
            cut = WizardSharedPauses.expanded(cut)
            var candidates = WizardSharedPauses.candidates(clip, sceneMap: sceneMap, sourceTypes: sourceTypes,
                contacts: contacts, drawings: drawings, options: options,
                visible: WizardSharedPauses.visibleSources(cut, sceneMap: sceneMap, main: scene.videoPath))
            let clipDrawings = candidates.drawings
            let useContacts = candidates.useContacts
            guard useContacts || !clipDrawings.isEmpty else { continue }
            if let reason = skipReason(index: index, plan: plan, cut: cut, scene: scene,
                                       sourceType: sourceTypes[scene.videoID], options: options)
                ?? skipReason(index: index, plan: renderPlan, cut: cut, scene: scene,
                              sourceType: sourceTypes[scene.videoID], options: renderOptions) {
                if useContacts { result.messages.append("Pause on contact: skipped clip \(index + 1) — \(reason).") }
                if !clipDrawings.isEmpty { result.messages.append("Drawing: skipped clip \(index + 1) — \(reason).") }
                continue
            }
            let tracks = WizardSharedPauses.tracks(cut)
            let shared = cut.videoTrack.count > 1 || !clip.areaClips.isEmpty
                || (clipDrawings.contains { $0.motion != nil } && WizardSharedPauses.showsSeveralPictures(clip, cut: cut))
            var timing = candidates.resolved(for: clip, seconds: options.strikeImpactFreeze, tracks: shared ? tracks : nil)
            // The extracted source may differ within eligibility's tolerance.
            // Validate its actual pieces too; a failed motion must become a
            // pause and return its replaced contacts to selection, never vanish.
            if !shared, let original = cut.videoTrack.first {
                while !timing.movingDrawings.isEmpty {
                    let pauses = timing.pauses.map {
                        StrikeFreezeRules.Pause(time: clip.start + $0.time * clip.speed,
                            duration: $0.duration, drawing: $0.drawing)
                    }
                    let pieces = pauses.isEmpty ? [original] : StrikeFreezeRules.pieces(original, pauses: pauses)
                    let moved = TelestrationMotionRules.moving(pieces, drawings: timing.movingDrawings)
                    guard !moved.fallback.isEmpty else { break }
                    var reasons = timing.motionFallbackReasons
                    for index in candidates.drawings.indices where moved.fallback.contains(TelestrationMotionRules.paused(candidates.drawings[index])) {
                        reasons.append(TelestrationMotionRules.fallbackReason(candidates.drawings[index], in: pieces,
                            drawings: candidates.drawings) ?? "a piece would be too short")
                        candidates.drawings[index].motion = nil
                        candidates.originals[index].drawing.motion = nil
                    }
                    timing = candidates.resolved(for: clip, seconds: options.strikeImpactFreeze, tracks: nil)
                    timing.motionFallbackReasons = Array(Set(reasons + timing.motionFallbackReasons)).sorted()
                }
            }
            let messageStart = result.messages.count
            // One short line per clip, also when every in-range contact was
            // filtered. The caller deduplicates these through the run snapshot.
            if timing.filteredContacts > 0 {
                result.messages.append("Pause on contact: clip \(index + 1) — skipped \(timing.filteredContacts) contact(s) (spacing or limit).")
            }
            if timing.filteredDrawings > 0 {
                result.messages.append("Drawing: clip \(index + 1): skipped \(timing.filteredDrawings) (too close to an edge or another pause).")
            }
            if !timing.motionFallbackReasons.isEmpty {
                result.messages.append("Drawing: clip \(index + 1): the picture pauses (\(timing.motionFallbackReasons.joined(separator: "; ")))")
            }
            guard !timing.pauses.isEmpty || !timing.movingDrawings.isEmpty else { continue }
            guard let original = cut.videoTrack.first else { continue }
            let pauses = timing.pauses.map {
                StrikeFreezeRules.Pause(time: clip.start + $0.time * clip.speed, duration: $0.duration, drawing: $0.drawing)
            }
            var pieces: [TimelineClip]
            if timing.pauses.isEmpty {
                pieces = [original]
            } else if shared {
                pieces = StrikeFreezeRules.sharedPieces(tracks,
                    pauses: WizardSharedPauses.pauses(timing, mainSource: scene.videoPath))?.flatMap { $0 } ?? []
            } else if clipDrawings.isEmpty, let first = timing.pauses.first {
                pieces = StrikeFreezeRules.pieces(original, contacts: pauses.map(\.time), hold: first.duration)
            } else {
                pieces = StrikeFreezeRules.pieces(original, pauses: pauses)
            }
            guard !pieces.isEmpty else {
                result.messages.removeSubrange(messageStart...)
                if useContacts { result.messages.append("Pause on contact: skipped clip \(index + 1) — source pieces could not be split safely.") }
                if !clipDrawings.isEmpty { result.messages.append("Drawing: skipped clip \(index + 1) — source pieces could not be split safely.") }
                continue
            }
            if !timing.movingDrawings.isEmpty {
                let moving = TelestrationMotionRules.moving(pieces, drawings: timing.movingDrawings)
                pieces = moving.pieces
                timing.stretches = moving.stretches.map {
                    .init(start: ($0.start - clip.start) / clip.speed,
                          end: ($0.end - clip.start) / clip.speed, factor: $0.factor)
                }
                timing.impactSplit = true
                for index in pieces.indices { pieces[index].timedAssembly = true }
                if let edges = WizardSharedPauses.edgeSegments(pieces) {
                    timing.headSegment = edges.head
                    timing.tailSegment = edges.tail
                }
            }
            if shared, pieces.contains(where: { $0.track != 0 }), let edges = WizardSharedPauses.edgeSegments(pieces) {
                timing.headSegment = edges.head
                timing.tailSegment = edges.tail
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

    /// Keep the established pause path intact. Impact effects operate on its
    /// pieces, then remap layers from the untouched cut through the full clock.
    static func prepare(plan: WizardPlan, cuts: [Int: TimelineDocument], sceneMap: [Int64: SceneRecord],
                        sourceTypes: [Int64: VideoType], contacts: [String: [Double]],
                        drawings: [String: [Telestration]] = [:], options: WizardOptions,
                        xfadeDuration: Double, presentation: Eligibility? = nil) -> Preparation {
        var result = preparePauses(plan: plan, cuts: cuts, sceneMap: sceneMap, sourceTypes: sourceTypes,
            contacts: contacts, drawings: drawings, options: options, xfadeDuration: xfadeDuration, presentation: presentation)
        guard impactRequested(options) else { return result }
        let renderPlan = presentation?.plan ?? plan
        let renderOptions = presentation?.options ?? options
        if options.dubLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            if !result.messages.contains(dubSkipMessage) { result.messages.append(dubSkipMessage) }
            return result
        }
        let strength = StrikeImpactRules.strength(saved: options.strikeSlowMotion ?? "").flatMap(StrikeImpactRules.Strength.init(rawValue:))
        var selectionOptions = options
        if !requested(options) { selectionOptions.strikeImpactFreeze = StrikeHighlightRules.impactHold }
        let drawings = options.drawnPauses == false ? [:] : drawings
        // Recompute join notices after all new boundaries have been installed.
        let oldJoinMessages = Set(result.joins.messages(clipCount: renderPlan.clips.count))
        result.messages.removeAll { oldJoinMessages.contains($0) }
        for (index, clip) in plan.clips.enumerated() {
            guard let scene = sceneMap[clip.sceneID], let input = cuts[index],
                  var cut = result.cuts[index], var timing = result.timings[index] else { continue }
            let expanded = WizardSharedPauses.expanded(input)
            let shared = WizardSharedPauses.showsSeveralPictures(clip, cut: expanded)
            let candidates = WizardSharedPauses.candidates(clip, sceneMap: sceneMap, sourceTypes: sourceTypes,
                contacts: contacts, drawings: drawings, options: selectionOptions,
                visible: WizardSharedPauses.visibleSources(expanded, sceneMap: sceneMap, main: scene.videoPath))
            guard candidates.useContacts else { continue }
            if let reason = skipReason(index: index, plan: plan, cut: expanded, scene: scene,
                sourceType: sourceTypes[scene.videoID], options: options)
                ?? skipReason(index: index, plan: renderPlan, cut: expanded, scene: scene,
                    sourceType: sourceTypes[scene.videoID], options: renderOptions) {
                let message = "Pause on contact: skipped clip \(index + 1) — \(reason)."
                if !result.messages.contains(message) { result.messages.append(message) }
                continue
            }
            let selected = requested(options) ? timing : candidates.resolved(for: clip,
                seconds: selectionOptions.strikeImpactFreeze, tracks: shared ? WizardSharedPauses.tracks(expanded) : nil)
            var kept = selected.pauses.filter { pause in
                pause.drawing == nil || candidates.contacts.contains {
                    abs($0 - (clip.start + pause.time * clip.speed)) < 1e-9
                }
            }.map { clip.start + $0.time * clip.speed }
            if !selected.movingDrawings.isEmpty {
                kept += selected.movingDrawings.filter { drawing in
                    candidates.contacts.contains { abs($0 - drawing.time) < 1e-9 }
                }.map(\.time)
                kept.sort()
            }
            if !requested(options), selected.filteredContacts > 0 {
                result.messages.append("Pause on contact: clip \(index + 1) — skipped \(selected.filteredContacts) contact(s) (spacing or limit).")
            }
            guard !kept.isEmpty else { continue }
            if timing.pauses.isEmpty && timing.movingDrawings.isEmpty { cut = expanded }
            var pieces = cut.videoTrack
            if let strength, shared {
                let pausedTiming = timing
                let screenContacts = kept.map { pausedTiming.outputTime(($0 - clip.start) / clip.speed) }
                if let slowed = StrikeImpactRules.sharedSlowing(WizardSharedPauses.tracks(cut),
                    contacts: screenContacts, strength: strength) {
                    pieces = slowed.tracks.flatMap { $0 }
                    timing.stretches = slowed.stretches.map {
                        .init(start: pausedTiming.plannedTime(forOutput: $0.start),
                              end: pausedTiming.plannedTime(forOutput: $0.end), factor: $0.factor)
                    }
                    timing.filteredSlowContacts = slowed.skipped
                    if slowed.skipped > 0 {
                        result.messages.append("Slow motion into contact: clip \(index + 1) — skipped \(slowed.skipped) contact(s) (overlap, minimum piece or speed below 0.25×).")
                    }
                }
            }
            if let strength, !shared {
                let slowContacts = kept.filter { contact in
                    !timing.movingDrawings.contains { drawing in
                        max(clip.start, contact - strength.lead) < drawing.time + drawing.sourceSpan * clip.speed - 1e-9
                            && contact > drawing.time + 1e-9
                    }
                }
                let slowed = StrikeImpactRules.slowing(pieces, contacts: slowContacts, strength: strength)
                pieces = slowed.pieces
                timing.stretches += slowed.stretches.map {
                    .init(start: ($0.start - clip.start) / clip.speed,
                          end: ($0.end - clip.start) / clip.speed, factor: $0.factor)
                }
                if !timing.movingDrawings.isEmpty { timing.stretches.sort { $0.start < $1.start } }
                timing.filteredSlowContacts = slowed.skipped + kept.count - slowContacts.count
                if timing.filteredSlowContacts > 0 {
                    result.messages.append("Slow motion into contact: clip \(index + 1) — skipped \(timing.filteredSlowContacts) contact(s) (overlap, minimum piece or speed below 0.25×).")
                }
            }
            if options.strikeFlash == true {
                if shared {
                    // Flash each picture at the same reel instant, using its
                    // own source clock. No picture gains or loses time.
                    for contact in kept {
                        let time = timing.outputTime((contact - clip.start) / clip.speed)
                        pieces = pieces.flatMap { piece -> [TimelineClip] in
                            guard time >= piece.startTime - 1e-9,
                                  time < piece.startTime + piece.duration - 1e-9,
                                  let start = piece.sourceStart else { return [piece] }
                            let source = start + (piece.hold == true ? 0 : (time - piece.startTime) * piece.effectiveSpeed)
                            return StrikeImpactRules.flashed([piece], contacts: [source])
                        }
                    }
                } else {
                    pieces = StrikeImpactRules.flashed(pieces, contacts: kept)
                }
            }
            timing.impactSplit = !timing.stretches.isEmpty || pieces.contains { $0.flashIn != nil }
            // Captions and voice-over follow the planned clock, so the pieces are
            // assembled on it in whole frames, as a reel with pauses is.
            if timing.impactSplit {
                for index in pieces.indices where !pieces[index].bumper { pieces[index].timedAssembly = true }
            }
            if timing.impactSplit, let edges = WizardSharedPauses.edgeSegments(pieces) {
                timing.headSegment = edges.head
                timing.tailSegment = edges.tail
            }
            // Layers are still on the original cut clock, never remap the
            // already paused copy a second time.
            var mapped = expanded
            mapped.videoTrack = pieces
            mapLayers(in: &mapped, timing: timing)
            result.cuts[index] = mapped
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
        guard !timing.pauses.isEmpty || !timing.stretches.isEmpty else { return }
        for index in document.textOverlays.indices {
            document.textOverlays[index].startTime = timing.outputTime(document.textOverlays[index].startTime)
            document.textOverlays[index].endTime = timing.outputTime(document.textOverlays[index].endTime)
        }
        for index in document.imageOverlays.indices {
            document.imageOverlays[index].startTime = timing.outputTime(document.imageOverlays[index].startTime)
            document.imageOverlays[index].endTime = timing.outputTime(document.imageOverlays[index].endTime)
            document.imageOverlays[index].track = document.imageOverlays[index].track.map { timing.imageKeys($0) }
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
                document.overlayBlocks[index].composition.images[item].track = value.track.map {
                    timing.imageKeys($0, origin: start)
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
