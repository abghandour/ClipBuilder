import Foundation

/// One stretch of kept footage the Express preview can scrub through: the
/// scene it belongs to and the exact source range the render will use.
nonisolated struct WizardPreviewClip: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var scene: SceneRecord
    var start: Double
    var end: Double
    var brollCuts: [BRollCut]? = nil
    /// The rendered clock, after pacing, speed and transition overlaps.
    var outputStart: Double? = nil
    var outputDuration: Double? = nil
    var chosenSubject: Framing.Subject? = nil
    var drawingCompanions: [TelestrationSource] = []

    var range: ClosedRange<Double> { start...max(start, end) }
    var duration: Double { max(0, end - start) }
}

/// One moment of a kept clip, in source time, for a still pinned to it.
nonisolated struct WizardPreviewMoment: Equatable, Hashable, Sendable {
    var clipID: String
    var time: Double
}

/// The kept footage of an Express run as preview clips, in output order.
nonisolated enum WizardPreviewClips {
    /// Kept takes win once picks have become selections (the step Settings
    /// performs); before that the kept Q&A exchanges, transcript picks or
    /// fight picks stand in, with the same ranges the selections will get.
    static func kept(run: MiniWizardRun, scenes: [SceneRecord]) -> [WizardPreviewClip] {
        // Only this recording's scenes: a pick without a scene must never
        // borrow a longer overlapping scene from another video.
        let allByID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scenes = scenes.filter { $0.videoID == run.video.id }
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [WizardPreviewClip] = []
        // Q&A, Transcript and Fight picks are the live footage the user edits;
        // their saved takes lag until Settings records them again, so the
        // picks come first and the takes only stand in when there are none.
        var picked = pickClips(run: run, scenes: scenes, byID: byID)
        if !picked.isEmpty {
            let saved = run.candidates.flatMap { $0.take.plan.clips }
            for index in picked.indices {
                let piece = picked[index]
                let exact = saved.first { clip in
                    if let pickID = clip.miniPickID {
                        return piece.id == "pick-\(pickID)" || piece.id == "fight-\(pickID)"
                    }
                    return clip.sceneID == piece.scene.id && abs(clip.start - piece.start) < 0.001 && abs(clip.end - piece.end) < 0.001
                }
                picked[index].brollCuts = exact?.brollCuts
                if let exact { picked[index].drawingCompanions = TelestrationSource.companions(clip: exact, sceneMap: allByID) }
            }
            return picked
        }
        let takes = run.candidates.filter { $0.kept && !$0.take.plan.clips.isEmpty }
        if !takes.isEmpty {
            for candidate in takes {
                for (index, clip) in candidate.take.plan.clips.enumerated() where clip.end > clip.start {
                    guard let scene = byID[clip.sceneID] else { continue }
                    let title = candidate.take.plan.clips.count > 1
                        ? "\(candidate.selection.name) · \(index + 1)" : candidate.selection.name
                    result.append(.init(id: "take-\(candidate.id)-\(index)", title: title,
                                        scene: scene, start: clip.start, end: clip.end, brollCuts: clip.brollCuts,
                                        chosenSubject: candidate.take.plan.framing,
                                        drawingCompanions: TelestrationSource.companions(clip: clip, sceneMap: allByID)))
                }
            }
            return result
        }
        return result
    }

    /// The Express reel as preview clips, in reel order. A loaded section
    /// supplies the live range (and every cut of a Highlights candidate);
    /// otherwise, or for a Highlights item of another batch, the item's
    /// snapshot stands in.
    static func reel(items: [MiniReelItem], runs: [MiniWizardFlow.FootageKind: MiniWizardRun],
                     videoID: Int64, scenes: [SceneRecord]) -> [WizardPreviewClip] {
        let allScenes = scenes
        let allByID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scenes = scenes.filter { $0.videoID == videoID }
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let runs = runs.filter { $0.value.video.id == videoID }
        var result: [WizardPreviewClip] = []
        for item in items.sorted(by: { $0.position < $1.position }) {
            // A Highlights item from another Length's batch: the loaded
            // batch cannot speak for it, so its snapshot stands in.
            if let run = runs[item.kind],
               item.kind != .highlights || run.candidates.contains(where: { $0.id == item.itemID }) {
                result += liveClips(item, run: run, scenes: scenes, byID: byID, companionScenes: allScenes)
            } else if let scene = containing(item.range, id: item.sceneID, scenes: scenes, byID: byID) {
                result.append(.init(id: item.clipID, title: item.title, scene: scene,
                                    start: item.range.lowerBound, end: item.range.upperBound))
            }
        }
        // Reviewed B-roll cuts live on the recorded takes.
        let saved = runs.values.flatMap { $0.candidates.flatMap { $0.take.plan.clips } }
        for index in result.indices where result[index].brollCuts == nil {
            let piece = result[index]
            let exact = saved.first { clip in
                if let pickID = clip.miniPickID {
                    return piece.id == "pick-\(pickID)" || piece.id == "fight-\(pickID)"
                }
                return clip.sceneID == piece.scene.id && abs(clip.start - piece.start) < 0.001 && abs(clip.end - piece.end) < 0.001
            }
            result[index].brollCuts = exact?.brollCuts
            if let exact { result[index].drawingCompanions = TelestrationSource.companions(clip: exact, sceneMap: allByID) }
        }
        return result
    }

    private static func liveClips(_ item: MiniReelItem, run: MiniWizardRun, scenes: [SceneRecord],
                                  byID: [Int64: SceneRecord], companionScenes: [SceneRecord]) -> [WizardPreviewClip] {
        switch item.kind {
        case .qa:
            guard let qa = run.qa, qa.kept.contains(item.itemID),
                  let section = qa.sections.first(where: { $0.id == item.itemID }),
                  section.range.upperBound > section.range.lowerBound else { return [] }
            return [.init(id: item.clipID, title: section.question, scene: section.scene,
                          start: section.range.lowerBound, end: section.range.upperBound)]
        case .transcript:
            guard let pick = run.transcript?.picks.first(where: { $0.id == item.itemID }), pick.kept,
                  let scene = containing(pick.range, id: pick.sceneID, scenes: scenes, byID: byID) else { return [] }
            return [.init(id: item.clipID, title: item.title, scene: scene,
                          start: pick.range.lowerBound, end: pick.range.upperBound)]
        case .fightMetrics:
            guard let pick = run.fight?.picks.first(where: { $0.id == item.itemID }),
                  let scene = containing(pick.range, id: pick.sceneID, scenes: scenes, byID: byID) else { return [] }
            return [.init(id: item.clipID, title: "Stretch \(pick.position + 1)", scene: scene,
                          start: pick.range.lowerBound, end: pick.range.upperBound)]
        case .highlights:
            guard let candidate = run.candidates.first(where: { $0.id == item.itemID }), candidate.kept,
                  let plan = WizardSelectionRules.resolvedPlan(candidate.take.plan, scenes: companionScenes) else { return [] }
            let companionMap = Dictionary(companionScenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var result: [WizardPreviewClip] = []
            for (index, clip) in plan.clips.enumerated() where clip.end > clip.start {
                guard let scene = byID[clip.sceneID] else { continue }
                let title = plan.clips.count > 1
                    ? "\(candidate.selection.name) · \(index + 1)" : candidate.selection.name
                result.append(.init(id: "take-\(candidate.id)-\(index)", title: title, scene: scene,
                                    start: clip.start, end: clip.end, brollCuts: clip.brollCuts,
                                    chosenSubject: plan.framing,
                                    drawingCompanions: TelestrationSource.companions(clip: clip, sceneMap: companionMap)))
            }
            return result
        }
    }

    /// The kept takes of a batch (the Full wizard's and a rough cut's) as
    /// preview clips, in output order, titled by their selection.
    static func takes(_ takes: [WizardSelectionTake], names: [Int64: String],
                      scenes: [SceneRecord]) -> [WizardPreviewClip] {
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [WizardPreviewClip] = []
        for take in takes {
            let name = names[take.selectionID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let base = name.isEmpty ? "Take \(take.ordinal)" : name
            for (index, clip) in take.plan.clips.enumerated() where clip.end > clip.start {
                guard let scene = byID[clip.sceneID] else { continue }
                let title = take.plan.clips.count > 1 ? "\(base) · \(index + 1)" : base
                result.append(.init(id: "take-\(take.id)-\(index)", title: title,
                                    scene: scene, start: clip.start, end: clip.end, brollCuts: clip.brollCuts,
                                    chosenSubject: take.plan.framing,
                                    drawingCompanions: TelestrationSource.companions(clip: clip, sceneMap: byID)))
            }
        }
        return result
    }

    /// Seconds each join between main-track clips takes out of the reel:
    /// `[k]` is the join between clip k and k + 1, in start order.
    /// How the renderer assembles a document: its own segments and joins
    /// (`MultitrackRenderer.plannedSegments`), the time each join takes out,
    /// and where each segment starts in the finished reel.
    struct Assembly {
        /// The document as the renderer takes it: without a missing bumper
        /// at either end, and rebased if the first one went.
        var document = TimelineDocument()
        var segments: [MultitrackRenderer.Segment] = []
        /// `overlaps[k]` is the join between segment k and k + 1.
        var overlaps: [Int: Double] = [:]
        var outputs: [Double] = []

        /// A time on the document's timeline as a time in the reel.
        func output(_ time: Double) -> Double {
            guard !segments.isEmpty else { return time }
            var index = 0
            for (candidate, segment) in segments.enumerated() where segment.start <= time + 0.0005 { index = candidate }
            return outputs[index] + min(max(0, time - segments[index].start), segments[index].duration)
        }

        /// The clock the renderer reports for this assembly, built as it
        /// builds it. Work that must stay in step with what the renderer
        /// places by its clock (the voice-over mix) uses this one.
        var clock: RenderClock { RenderClock(segmentStarts: segments.map(\.start), overlaps: overlaps) }

        /// The clip on screen in a segment: of the main clips on the lowest
        /// layer the one drawn last (`MultitrackRenderer.orderedPlacements`),
        /// which where two overlap on a track is the later one.
        static func shownClip(in segment: MultitrackRenderer.Segment) -> MultitrackRenderer.ResolvedClip? {
            let footage = segment.clips.filter { $0.bumper || $0.role != .cutaway }
            guard let layer = footage.map(MultitrackRenderer.placementLayer(for:)).min() else { return nil }
            return footage.filter { MultitrackRenderer.placementLayer(for: $0) == layer }.max {
                ($0.originalStart, $0.originKey, $0.documentIndex) < ($1.originalStart, $1.originKey, $1.documentIndex)
            }
        }
    }

    /// `exists` says whether a bumper's file is there; a missing bumper at
    /// either end of the reel is not rendered (`removingMissingEdgeBumpers`).
    static func assembly(of document: TimelineDocument, scenes: [SceneRecord], xfadeDuration: Double,
                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Assembly {
        let document = MultitrackRenderer.removingMissingEdgeBumpers(document, exists: exists)
        let planned = MultitrackRenderer.plannedSegments(MultitrackRenderer.resolveClips(document: document, scenes: scenes))
        var assembly = Assembly(document: document, segments: planned.segments)
        assembly.overlaps = segmentOverlaps(
            durations: planned.segments.map(\.duration),
            bumpers: planned.segments.map { segment in
                segment.clips.first.flatMap { $0.bumper ? "\($0.sourcePath)|\($0.startTime)" : nil }
            },
            transitions: planned.transitions.map { $0 == "cut" ? nil : $0 },
            timed: MultitrackRenderer.usesTimedAssembly(document, transitions: planned.transitions),
            xfadeDuration: xfadeDuration)
        var cursor = 0.0
        for (index, segment) in planned.segments.enumerated() {
            if index > 0 { cursor -= assembly.overlaps[index - 1] ?? 0 }
            assembly.outputs.append(cursor)
            cursor += segment.duration
        }
        return assembly
    }

    /// The time each join between consecutive main clips takes out of the
    /// reel, with `cutaways` over them. Clips need a file and a source start.
    static func joinOverlaps(_ clips: [TimelineClip], cutaways: [TimelineClip] = [], xfadeDuration: Double) -> [Int: Double] {
        var document = TimelineDocument()
        document.videoTrack = clips + cutaways
        let assembly = Self.assembly(of: document, scenes: [], xfadeDuration: xfadeDuration, exists: { _ in true })
        var overlaps: [Int: Double] = [:]
        var before: Int?
        for (index, segment) in assembly.segments.enumerated() {
            let owner = MultitrackRenderer.joinClip(in: segment.clips)?.documentIndex
            if let owner, let before, owner != before, owner > 0, let overlap = assembly.overlaps[index - 1], overlap > 0 {
                overlaps[owner - 1, default: 0] += overlap
            }
            before = owner
        }
        return overlaps
    }

    /// The joins of segments; `transitions[k]` is the join between segment k
    /// and k + 1 (nil: a hard cut), `bumpers[k]` names the bumper segment k shows.
    private static func segmentOverlaps(durations: [Double], bumpers: [String?], transitions: [String?],
                                        timed: Bool, xfadeDuration: Double) -> [Int: Double] {
        guard durations.count > 1 else { return [:] }
        // A bumper is joined to its neighbours on its own (`MultitrackRenderer
        // .concatenateWithBumpers`): the segments between bumpers are runs,
        // and so are the segments of one bumper.
        var runs: [Range<Int>] = []
        var start = 0
        for index in durations.indices.dropFirst() {
            let previous = bumpers[index - 1], current = bumpers[index]
            let sameBumper = previous != nil && previous == current
            if !sameBumper && (previous != nil || current != nil) {
                runs.append(start..<index)
                start = index
            }
        }
        runs.append(start..<durations.count)
        var overlaps: [Int: Double] = [:]
        for run in runs where run.count > 1 {
            let within = runOverlaps(durations: Array(durations[run]),
                                     transitions: Array(transitions[run.lowerBound..<(run.upperBound - 1)]),
                                     xfadeDuration: xfadeDuration)
            for (gap, overlap) in within { overlaps[gap + run.lowerBound] = overlap }
        }
        for run in runs.dropFirst() {
            let gap = run.lowerBound - 1
            guard let name = transitions[gap] else { continue }
            let outgoing = durations[gap], incoming = durations[run.lowerBound]
            if TransitionRecipes.isRecipe(name) {
                let (tail, head) = TransitionRecipes.pieces(for: name)
                overlaps[gap] = outgoing - tail < 0.4 || incoming - head < 0.4
                    ? 0 : RenderEngine.consumedOverlap(name, xfadeDuration: xfadeDuration)
            } else {
                // Its own two segments set the limit, not the runs on either side.
                let fitted = min(RenderEngine.consumedOverlap(name, xfadeDuration: xfadeDuration), min(outgoing, incoming) * 0.4)
                overlaps[gap] = fitted >= 0.05 ? fitted : 0
            }
        }
        // Timed assembly runs on a 30 fps frame clock: every overlap is whole frames.
        if timed { overlaps = overlaps.mapValues { ($0 * 30).rounded() / 30 } }
        return overlaps
    }

    /// The joins of clips assembled together (no bumper among them).
    private static func runOverlaps(durations: [Double], transitions: [String?], xfadeDuration: Double) -> [Int: Double] {
        // Recipe bridges are not xfade runs; preserve their separate clock.
        // Ordinary joins use the renderer's affordability and fallback policy.
        let plainJoins = transitions.map { TransitionRecipes.isRecipe($0) ? nil : $0 }
        // A recipe the clips are too short for is rendered as a hard cut. One
        // that is rendered takes its pieces off the clips first, so a crossfade
        // next to it is fitted to what is left of them.
        let affordable = RenderEngine.affordableRecipes(durations: durations, transitions: transitions)
        let remaining = durations.indices.map { max(0, durations[$0] - affordable.headTrim[$0] - affordable.tailTrim[$0]) }
        var overlaps = MultitrackRenderer.crossfadeOverlaps(durations: remaining,
            transitions: plainJoins, transitionDuration: xfadeDuration)
        for (index, name) in affordable.recipe.enumerated() where name != nil {
            overlaps[index] = RenderEngine.consumedOverlap(name, xfadeDuration: xfadeDuration)
        }
        return overlaps
    }

    /// Where the document's applied filler cuts land in the finished reel.
    static func fillerMarkers(of document: TimelineDocument, scenes: [SceneRecord], xfadeDuration: Double,
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [FillerCutRules.Marker] {
        guard let spans = document.appliedFillerSpans, !spans.isEmpty else { return [] }
        let assembly = Self.assembly(of: document, scenes: scenes, xfadeDuration: xfadeDuration, exists: exists)
        let videoByPath = Dictionary(scenes.map { ($0.videoPath, $0.videoID) }, uniquingKeysWith: { first, _ in first })
        var pieces: [FillerCutRules.ShownPiece] = []
        for (index, segment) in assembly.segments.enumerated() {
            guard let clip = Assembly.shownClip(in: segment), !clip.bumper, !clip.hold,
                  let videoID = clip.videoID ?? videoByPath[clip.sourcePath] else { continue }
            let start = clip.sourceStart + max(0, segment.start - clip.startTime) * clip.speed
            pieces.append(.init(videoID: videoID, sourceStart: start, sourceEnd: start + segment.duration * clip.speed,
                                output: assembly.outputs[index]))
        }
        return FillerCutRules.markers(pieces: pieces, spans: spans)
    }

    /// The stripped document the renderer used, rather than the take's plan
    /// before pacing. Each take starts its own output clock at zero.
    static func rendered(_ document: TimelineDocument, take: WizardSelectionTake, name: String,
                         scenes: [SceneRecord], xfadeDuration: Double) -> [WizardPreviewClip] {
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // At each moment the main clip on screen on the lowest layer. A layout
        // block's other areas play over it, and a clip under another on its
        // own track shows only where it is alone.
        let assembly = Self.assembly(of: document, scenes: scenes, xfadeDuration: xfadeDuration)
        let document = assembly.document
        var shown: [Int: (output: Double, start: Double, end: Double)] = [:]
        for (index, segment) in assembly.segments.enumerated() {
            guard let owner = Assembly.shownClip(in: segment)?.documentIndex else { continue }
            if let span = shown[owner] {
                shown[owner] = (span.output, span.start, segment.end)
            } else {
                shown[owner] = (assembly.outputs[index], segment.start, segment.end)
            }
        }
        // Numbered over the clips that are on screen at some point.
        let clips = document.videoTrack.enumerated().filter { !$0.element.isCutaway && shown[$0.offset] != nil }
            .sorted { ($0.element.startTime, $0.offset) < ($1.element.startTime, $1.offset) }
        var result: [WizardPreviewClip] = []
        for (index, entry) in clips.enumerated() {
            let clip = entry.element
            guard let span = shown[entry.offset], span.end > span.start,
                  let scene = renderedScene(for: clip, take: take, byID: byID) else { continue }
            let speed = clip.hold == true ? 0 : clip.speed ?? 1
            let duration = clip.duration > 0 ? clip.duration : span.end - clip.startTime
            var sourceStart = clip.sourceStart ?? scene.startTime
            var sourceEnd = clip.sourceEnd ?? (sourceStart + duration * (clip.speed ?? 1))
            // Only the part that is shown: its start may be under another clip, or its end.
            let hiddenHead = span.start - clip.startTime, hiddenTail = clip.startTime + duration - span.end
            if hiddenHead > 0.001 { sourceStart += hiddenHead * speed }
            if hiddenTail > 0.001 { sourceEnd -= hiddenTail * speed }
            // A clip shown whole keeps its own length, to the digit.
            let shownDuration = hiddenHead > 0.001 || hiddenTail > 0.001 ? span.end - span.start : duration
            guard sourceEnd > sourceStart || clip.hold == true else { continue }
            let title = clips.count > 1 ? "\(name) · \(index + 1)" : name
            result.append(.init(id: "take-\(take.id)-\(index)", title: title, scene: scene,
                                start: sourceStart, end: sourceEnd,
                                outputStart: span.output, outputDuration: shownDuration,
                                chosenSubject: take.plan.framing))
        }
        return result
    }

    /// Trimmed TimelineClips serialize as file + source range, without a scene
    /// id. Recover only from this take's scenes on that same file; a card or an
    /// unrelated recording must never borrow the take's first scene.
    private static func renderedScene(for clip: TimelineClip, take: WizardSelectionTake,
                                      byID: [Int64: SceneRecord]) -> SceneRecord? {
        if let id = clip.sceneID { return byID[id] }
        guard let path = clip.videoFile, let start = clip.sourceStart else { return nil }
        let end = clip.sourceEnd ?? (start + clip.sourceSpan)
        let ids = Set(take.sceneIDs).union(take.plan.clips.map(\.sceneID))
        let candidates = ids.compactMap { byID[$0] }.filter { $0.videoPath == path }.sorted { $0.id < $1.id }
        if clip.hold == true {
            return candidates.first { $0.startTime <= start && start <= $0.endTime }
        }
        return candidates.max { overlap($0, start...max(start, end)) < overlap($1, start...max(start, end)) }
            .flatMap { overlap($0, start...max(start, end)) > 0 ? $0 : nil }
    }

    /// The moment of kept footage at the rendered playhead. In an overlap
    /// the incoming clip supplies the still. Untimed clips play back to back;
    /// past the end stays on the last clip's last moment.
    static func moment(in clips: [WizardPreviewClip], at time: Double) -> WizardPreviewMoment? {
        let time = max(0, time.isFinite ? time : 0)
        var cursor = 0.0
        var moment: WizardPreviewMoment?
        for clip in clips {
            let start = clip.outputStart ?? cursor
            let duration = clip.outputDuration ?? clip.duration
            if start > time, moment != nil { break }
            let fraction = duration > 0 ? min(1, max(0, (time - start) / duration)) : 0
            moment = WizardPreviewMoment(clipID: clip.id, time: clip.start + fraction * clip.duration)
            cursor = start + duration
        }
        return moment
    }

    /// The preview clips cut from one take, in output order.
    static func clips(_ clips: [WizardPreviewClip], ofTake takeID: Int64) -> [WizardPreviewClip] {
        clips.filter { $0.id.hasPrefix("take-\(takeID)-") }
    }

    private static func pickClips(run: MiniWizardRun, scenes: [SceneRecord], byID: [Int64: SceneRecord]) -> [WizardPreviewClip] {
        var result: [WizardPreviewClip] = []
        switch run.footageKind {
        case .qa:
            guard let qa = run.qa else { return [] }
            let ordered = MiniWizardQARules.ordering(qa.sections, by: qa.keptOrder)
            for section in ordered where qa.kept.contains(section.id) && section.scene.videoID == run.video.id {
                let range = section.range
                guard range.upperBound > range.lowerBound else { continue }
                result.append(.init(id: "qa-\(section.id)", title: section.question,
                                    scene: section.scene, start: range.lowerBound, end: range.upperBound))
            }
        case .transcript:
            // Numbered over the kept picks: the list and the reel count only those.
            for (index, pick) in (run.transcript?.picks ?? []).filter(\.kept).enumerated() {
                guard let scene = containing(pick.range, id: pick.sceneID, scenes: scenes, byID: byID) else { continue }
                result.append(.init(id: "pick-\(pick.id)", title: "Passage \(index + 1)",
                                    scene: scene, start: pick.range.lowerBound, end: pick.range.upperBound))
            }
        case .fightMetrics:
            for pick in run.fight?.picks ?? [] {
                guard let scene = containing(pick.range, id: pick.sceneID, scenes: scenes, byID: byID) else { continue }
                result.append(.init(id: "fight-\(pick.id)", title: "Stretch \(pick.position + 1)",
                                    scene: scene, start: pick.range.lowerBound, end: pick.range.upperBound))
            }
        case .highlights:
            break
        }
        return result
    }

    /// A pick's own scene when it has one; otherwise the scene overlapping the
    /// pick most, so the still can read that scene's transcript and framing.
    private static func containing(_ range: ClosedRange<Double>, id: Int64?, scenes: [SceneRecord],
                                   byID: [Int64: SceneRecord]) -> SceneRecord? {
        guard range.upperBound > range.lowerBound else { return nil }
        if let id, let scene = byID[id] { return scene }
        return scenes.filter { !$0.excluded && !$0.ignored }.max { lhs, rhs in
            overlap(lhs, range) < overlap(rhs, range)
        }.flatMap { overlap($0, range) > 0 ? $0 : nil }
    }

    private static func overlap(_ scene: SceneRecord, _ range: ClosedRange<Double>) -> Double {
        max(0, min(scene.endTime, range.upperBound) - max(scene.startTime, range.lowerBound))
    }

    /// m:ss, or h:mm:ss past an hour, for the scrubber's time readout.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
