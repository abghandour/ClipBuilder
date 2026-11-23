import Foundation

/// A dub window is cut after laying speech out on the full assembly clock.
/// Dubbed bumper documents use their full bounded assembly clock. Other
/// surviving joins retain the window's clamping. No offsets are persisted.
nonisolated enum DubRenderWindow {
    /// Render-only policy from the full document, independent of surviving
    /// speech. Encodable only for preview cache evidence; never persisted.
    nonisolated struct State: Encodable, Sendable, Equatable {
        var enabled: Bool
        var replacementActive: Bool
        var frameBounded: Bool
        var replaceBeforeAssembly: Bool
    }

    static func state(document: TimelineDocument) -> State? {
        guard document.dubLines?.isEmpty == false else { return nil }
        let enabled = document.dub?.enabled == true
        return State(enabled: enabled, replacementActive: enabled && document.dub?.replaceOriginal == true,
            frameBounded: MultitrackRenderer.usesFrameBoundedBumpers(document, transitions: []),
            replaceBeforeAssembly: DubSourceEnvelope.replacesFootageBeforeAssembly(document))
    }

    nonisolated struct Evidence: Encodable, Sendable {
        var start: Double
        var end: Double
        var freezes: [Range<Double>]
        var state: State?
    }

    static func clock(document: TimelineDocument, window: TimelineDocument,
                      scenes: [SceneRecord], camera: String, lower: Double) -> RenderClock {
        guard document.dubLines?.isEmpty == false else { return .identity }
        // A window can remove every hold (or even the bumper). Its full-clock
        // prediction must still use the original document's assembly policy.
        let frameBounded = MultitrackRenderer.usesFrameBoundedBumpers(document, transitions: [])
        if frameBounded {
            var full = document
            if full.framingCamera == nil { full.framingCamera = camera }
            let planned = RenderContext.$settings.withValue(full.renderSettings) {
                let assembly = WizardPreviewClips.assembly(of: full, scenes: scenes,
                    xfadeDuration: RenderContext.transitions.xfadeDuration, exists: { _ in true })
                return MultitrackRenderer.plannedSegments(MultitrackRenderer.resolveClips(document: assembly.document, scenes: scenes))
            }
            let joins = RenderEngine.frameAssemblyJoins(durations: planned.segments.map(\.duration),
                transitions: planned.transitions, transitionDuration: RenderContext.transitions.xfadeDuration)
            return RenderClock(segmentStarts: planned.segments.map(\.start),
                segmentEnds: planned.segments.map(\.end), joins: joins)
        }
        func plan(_ document: TimelineDocument) -> (starts: [Double], overlaps: [Int: Double]) {
            var document = document
            if document.framingCamera == nil { document.framingCamera = camera }
            let assembly = RenderContext.$settings.withValue(document.renderSettings) {
                WizardPreviewClips.assembly(of: document, scenes: scenes,
                    xfadeDuration: RenderContext.transitions.xfadeDuration, exists: { _ in true })
            }
            return (assembly.segments.map(\.start), assembly.overlaps)
        }
        let full = plan(document), local = plan(window)
        var overlaps = full.overlaps
        for index in local.starts.indices where index > 0 {
            let boundary = local.starts[index] + lower
            if let original = full.starts.firstIndex(where: { abs($0 - boundary) < 0.001 }), original > 0 {
                overlaps[original - 1] = local.overlaps[index - 1] ?? 0
            }
        }
        return RenderClock(segmentStarts: full.starts, overlaps: overlaps)
    }

    static func evidence(document: TimelineDocument, clock: RenderClock, lower: Double, upper: Double) -> Evidence? {
        guard document.dubLines?.isEmpty == false else { return nil }
        return Evidence(start: clock.map(lower), end: clock.map(upper, end: true),
            freezes: DubFreezes.intervals(in: document, clock: clock), state: state(document: document))
    }

    static func lines(_ input: TimelineDocument, clock: RenderClock, lower: Double, upper: Double) -> [DubLine]? {
        let freezes = DubFreezes.intervals(in: input, clock: clock)
        let start = clock.map(lower), end = clock.map(upper, end: true)
        return input.dubLines?.compactMap { original in
            var mapped = original
            mapped.start = original.start < 0 ? original.start : clock.map(original.start)
            let layout = DubPauseRules.layout(mapped, freezes: freezes)
            guard mapped.start < end, layout.end > start else { return nil }
            var line = original
            if mapped.start <= start {
                let consumed = layout.segments.reduce(0.0) { result, segment in
                    result + min(segment.duration, max(0, start - segment.start))
                }
                line.start = -consumed
            } else if original.start < lower {
                // An overlapping join can move the window before this line,
                // even when its owner was removed from the window.
                line.start = mapped.start - start
            } else {
                // The surviving assembly maps this positive timeline start.
                line.start -= lower
            }
            return line
        }
    }
}
