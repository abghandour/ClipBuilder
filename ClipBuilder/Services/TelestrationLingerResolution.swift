import Foundation

/// Render-only relationships. Neither these associations nor their window
/// offsets are written into a TimelineClip or a saved document.
nonisolated enum TelestrationLingerResolution {
    static func attaching(to clips: [MultitrackRenderer.ResolvedClip]) -> [MultitrackRenderer.ResolvedClip] {
        guard clips.contains(where: {
            $0.lingering != nil || ($0.telestration.map { TelestrationRules.lingerDuration(of: $0) > 0 } ?? false)
        }) else { return clips }
        var result = clips
        let tracks = Dictionary(grouping: clips.indices, by: { clips[$0].track })
        for indices in tracks.values {
            for current in indices {
                let following = clips[current]
                guard following.lingering == nil, !following.hold, !following.bumper, following.role != .cutaway, following.stayCut != true else { continue }
                // Choose the visible hold before inspecting its drawing/source.
                // An opaque top hold must not reveal a hidden hold's stay.
                let candidates = indices.filter {
                    clips[$0].hold && !clips[$0].bumper
                        && abs(clips[$0].startTime + clips[$0].duration - following.startTime) <= 1.0 / 60 + 1e-9
                }
                guard let previous = candidates.max(by: {
                    MultitrackRenderer.drawOrder(clips[$0]) < MultitrackRenderer.drawOrder(clips[$1])
                }) else { continue }
                let hold = clips[previous]
                guard hold.sourcePath == following.sourcePath, let drawing = hold.telestration,
                      TelestrationRules.lingerDuration(of: drawing) > 0 else { continue }
                var linger = drawing
                linger.offset = nil
                result[current].lingering = linger
                result[current].lingeringHold = [hold]
            }
        }
        // A later contact pause on this picture suspends an existing stay.
        // Automatic moving splits share provenance; user cuts still end it.
        // A new drawn hold replaces the carried drawing.
        for indices in tracks.values {
            let ordered = indices.sorted { clips[$0].startTime < clips[$1].startTime }
            for current in ordered {
                let clip = result[current]
                guard clip.lingering == nil, clip.telestration == nil,
                      !clip.bumper, clip.role != .cutaway else { continue }
                let candidates = indices.filter {
                    $0 != current && abs(result[$0].startTime + result[$0].duration - clip.startTime) <= 1.0 / 60 + 1e-9
                }
                guard let previous = candidates.max(by: {
                    MultitrackRenderer.drawOrder(result[$0]) < MultitrackRenderer.drawOrder(result[$1])
                }) else { continue }
                let before = result[previous]
                let sameLineage = (clip.slowLineage != nil && clip.slowLineage == before.slowLineage)
                    || (clip.slowGroup != nil && clip.slowGroup == before.slowGroup)
                // Old groups identify their entry/exit; an unmarked cut inside
                // one group is ambiguous, so conservatively end the stay.
                let automatic = clip.stayCut == false || (sameLineage
                    && (clip.slowGroup != before.slowGroup || clip.flashIn != nil))
                guard clip.stayCut != true, clip.hold || before.hold || automatic,
                      before.sourcePath == clip.sourcePath,
                      CenterStageContinuity.sourceContinuous(before, clip),
                      var drawing = before.lingering else { continue }
                let elapsed = (drawing.offset ?? 0) + (before.hold ? 0 : before.duration)
                guard elapsed < TelestrationRules.carriedDuration(of: drawing) else { continue }
                drawing.offset = elapsed > 0 ? elapsed : nil
                result[current].lingering = drawing
                result[current].lingeringHold = before.lingeringHold
            }
        }
        return result
    }

    /// Prepasses operate on crop-block pieces; their clock starts later than
    /// the original moving clip. Segment rendering uses originalStart directly.
    static func drawingForPiece(_ clip: MultitrackRenderer.ResolvedClip) -> Telestration? {
        guard var drawing = clip.lingering else { return nil }
        let offset = (drawing.offset ?? 0) + (clip.hold ? 0 : max(0, clip.startTime - clip.originalStart))
        guard offset < TelestrationRules.carriedDuration(of: drawing) else { return nil }
        drawing.offset = offset > 0 ? offset : nil
        return drawing
    }

    static func cacheEvidence(_ clips: [MultitrackRenderer.ResolvedClip]) -> [Telestration?]? {
        clips.contains { $0.lingering != nil } ? clips.map(\.lingering) : nil
    }

    static func screenEvidence(_ clips: [MultitrackRenderer.ResolvedClip]) -> [TelestrationScreenStay.Mapping?]? {
        clips.contains { $0.lingering != nil && $0.screenStay != nil }
            ? clips.map { $0.lingering == nil ? nil : $0.screenStay } : nil
    }

    static func holdEvidence(_ clips: [MultitrackRenderer.ResolvedClip]) -> [MultitrackRenderer.ResolvedClip?]? {
        clips.contains { $0.lingering != nil && $0.lingeringHold != nil }
            ? clips.map { $0.lingering == nil ? nil : $0.lingeringHold?.first } : nil
    }

    /// Explicit zero has the same pixels and segment identity as an old
    /// drawing with no linger key. The saved model keeps its original value.
    static func cacheDrawing(_ drawing: Telestration) -> Telestration {
        var drawing = drawing
        for index in drawing.figures.indices where drawing.figures[index].linger == 0 {
            drawing.figures[index].linger = nil
        }
        return drawing
    }
}

extension MultitrackRenderer {
    /// Windowing for a render keeps a separate, transient drawing map. Resolve
    /// against the full document first, before the preceding hold disappears.
    nonisolated static func windowed(_ input: TimelineDocument, scenes: [SceneRecord],
                                     lingering existing: [UUID: Telestration] = [:],
                                     lingerHolds existingHolds: [UUID: ResolvedClip] = [:],
                                     continuity existingRuns: [CenterStageContinuity.Run] = [],
                                     stayTransitions existingTransitions: [UUID: Double] = [:],
                                     centerStageCamera: String = "balanced",
                                     from lower: Double, to upper: Double) -> (document: TimelineDocument, lingering: [UUID: Telestration], lingerHolds: [UUID: ResolvedClip], continuity: [CenterStageContinuity.Run], stayTransitions: [UUID: Double]) {
        let document = windowed(input, from: lower, to: upper)
        let surviving = Set(document.videoTrack.map(\.uid))
        var lingering: [UUID: Telestration] = [:]
        var holds: [UUID: ResolvedClip] = [:]
        let resolved = RenderContext.$settings.withValue(input.renderSettings) {
            resolveClips(document: input, scenes: scenes, centerStageCamera: input.framingCamera ?? centerStageCamera,
                lingering: existing, lingerHolds: existingHolds)
        }
        let planned = plannedSegments(resolved)
        let synchronized = TelestrationTransition.synchronize(planned.segments, transitions: planned.transitions,
            timed: usesTimedAssembly(input, transitions: planned.transitions), duration: RenderContext.transitions.xfadeDuration,
            context: existingTransitions)
        var stayTransitions = existingTransitions
        for clip in synchronized.flatMap(\.clips) {
            if let id = TelestrationTransition.contextID(clip), let start = clip.stayTransitionStart {
                stayTransitions[id] = start
            }
        }
        let runs = RenderContext.$settings.withValue(input.renderSettings) {
            let inputs = resolved.map { clip in
                var clip = clip
                if let window = input.videoTrack[safe: clip.documentIndex]?.contentWindow {
                    applyContentWindow(window, to: &clip)
                }
                return clip
            }
            return (existingRuns.isEmpty ? CenterStageContinuity.runs(inputs, ignoringStoredPaths: true) : existingRuns)
                .filter { run in run.members.contains { surviving.contains($0.id) } }
        }
        for clip in resolved {
            guard var drawing = clip.lingering, input.videoTrack.indices.contains(clip.documentIndex) else { continue }
            let item = input.videoTrack[clip.documentIndex]
            guard surviving.contains(item.uid) else { continue }
            let offset = (drawing.offset ?? 0) + (clip.hold ? 0 : max(0, lower - clip.originalStart))
            guard offset < TelestrationRules.carriedDuration(of: drawing) else { continue }
            drawing.offset = offset > 0 ? offset : nil
            lingering[item.uid] = drawing
            if var hold = clip.lingeringHold?.first {
                // Keep the original content box when its document row is
                // removed. The renderer applies it once, alongside other clips.
                if let row = input.videoTrack[safe: hold.documentIndex], row.uid == hold.stayHoldID,
                   let window = row.contentWindow {
                    hold.contentWindow = window
                }
                holds[item.uid] = hold
            }
        }
        for clip in resolved where clip.hold && clip.lingering != nil {
            if let id = TelestrationTransition.contextID(clip), let start = stayTransitions[id] {
                stayTransitions[id] = start - max(0, lower - clip.originalStart)
            }
        }
        let keptHolds = surviving.union(holds.values.compactMap(\.stayHoldID))
        return (document, lingering, holds, runs, stayTransitions.filter { keptHolds.contains($0.key) })
    }
}
