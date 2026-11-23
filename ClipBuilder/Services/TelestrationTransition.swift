import Foundation

nonisolated enum TelestrationTransition {
    static let cutMessage = "A figure stays across this join, so it plays as a cut"

    /// Colour/strength changes leave both pictures in place, including dips.
    /// Unknown names are conservative: they must not move a staying figure.
    static func requiresCut(_ name: String?) -> Bool {
        guard let name else { return false }
        return !["cut", "fade", "dissolve", "fadeblack", "fadewhite", "flash_black", "flash_white"].contains(name)
    }

    static func carriedHoldID(_ clip: MultitrackRenderer.ResolvedClip) -> UUID? {
        clip.lingeringHold?.first?.stayHoldID ?? clip.stayHoldID
    }

    /// A later plain pause has its own overlap, independent of the drawn hold.
    static func contextID(_ clip: MultitrackRenderer.ResolvedClip) -> UUID? {
        clip.hold && clip.lingering != nil ? clip.continuityClipID : clip.stayHoldID
    }

    /// The transition belongs to the bottom track, but any visible track
    /// can carry a figure across that same join.
    static func crossingHolds(outgoing: [MultitrackRenderer.ResolvedClip],
                              incoming: [MultitrackRenderer.ResolvedClip], at time: Double) -> Set<UUID> {
        Set(incoming.compactMap { next in
            guard let previous = outgoing.first(where: {
                $0.track == next.track && crosses(outgoing: $0, incoming: next, at: time)
            }) else { return nil }
            return carriedHoldID(previous)
        })
    }

    static func outgoing(in clips: [MultitrackRenderer.ResolvedClip],
                         incoming: MultitrackRenderer.ResolvedClip?) -> MultitrackRenderer.ResolvedClip? {
        guard let incoming, let snapshot = incoming.lingeringHold?.first else {
            return MultitrackRenderer.joinClip(in: clips)
        }
        return clips.filter { $0.hold && carriedHoldID($0) == snapshot.stayHoldID }
            .max { MultitrackRenderer.drawOrder($0) < MultitrackRenderer.drawOrder($1) }
            ?? MultitrackRenderer.joinClip(in: clips)
    }

    static func crosses(outgoing: MultitrackRenderer.ResolvedClip?, incoming: MultitrackRenderer.ResolvedClip?, at time: Double) -> Bool {
        guard let outgoing, let incoming, outgoing.hold,
              abs(incoming.originalStart - time) < 0.001,
              abs(outgoing.originalEnd - time) < 0.001,
              let hold = incoming.lingeringHold?.first,
              hold.stayHoldID != nil, hold.stayHoldID == carriedHoldID(outgoing),
              let drawing = hold.telestration else { return false }
        return TelestrationRules.lingerDuration(of: drawing) > 0
    }

    static func notice(document: TimelineDocument, scenes: [SceneRecord], clipID: UUID, entering: Bool) -> Bool {
        guard document.videoTrack.contains(where: {
            $0.hold == true && $0.telestration.map { TelestrationRules.lingerDuration(of: $0) > 0 } == true
        }) else { return false }
        let clips = RenderContext.$settings.withValue(document.renderSettings) {
            MultitrackRenderer.resolveClips(document: document, scenes: scenes)
        }
        let segments = MultitrackRenderer.buildLayeredSegments(clips)
        for index in 1..<max(1, segments.count) {
            let incoming = MultitrackRenderer.joinClip(in: segments[index].clips)
            let outgoing = outgoing(in: segments[index - 1].clips, incoming: incoming)
            // The join's own transition, decided as `plannedSegments` decides it:
            // a clip's entry or exit counts only where the clip really starts or ends.
            let start = segments[index].start
            let entry = incoming.flatMap { abs($0.originalStart - start) < 0.001 ? $0.transIn : nil }
            let exit = outgoing.flatMap { abs($0.originalEnd - start) < 0.001 ? $0.transOut : nil }
            // Either side's control describes this join, but only a clip that
            // really starts or ends here.
            let owner = entering
                ? incoming.flatMap { abs($0.originalStart - start) < 0.001 ? $0 : nil }
                : outgoing.flatMap { abs($0.originalEnd - start) < 0.001 ? $0 : nil }
            guard let owner, document.videoTrack.indices.contains(owner.documentIndex),
                  document.videoTrack[owner.documentIndex].uid == clipID,
                  !crossingHolds(outgoing: segments[index - 1].clips, incoming: segments[index].clips,
                      at: start).isEmpty else { continue }
            if requiresCut(entry ?? exit) { return true }
        }
        return false
    }

    /// Outgoing staying figures use the incoming piece's own clock during
    /// the overlap. This also covers a short stay already fading at the join.
    static func synchronize(_ segments: [MultitrackRenderer.Segment], transitions: [String?], timed: Bool,
                            duration: Double, context: [UUID: Double] = [:]) -> [MultitrackRenderer.Segment] {
        let overlaps = RenderEngine.crossfadeOverlaps(durations: segments.map(\.duration),
            transitions: transitions, transitionDuration: duration, applyingRecipeTrims: true)
        var result = segments
        for index in 1..<max(1, segments.count) {
            let holds = crossingHolds(outgoing: segments[index - 1].clips,
                incoming: segments[index].clips, at: segments[index].start)
            guard !holds.isEmpty,
                  let overlap = overlaps[index - 1], overlap > 0 else { continue }
            let used = timed ? (overlap * 30).rounded() / 30 : overlap
            for piece in result[index - 1].clips.indices {
                let clip = result[index - 1].clips[piece]
                guard let id = carriedHoldID(clip), holds.contains(id), clip.hold else { continue }
                result[index - 1].clips[piece].stayTransitionStart = segments[index - 1].end - used
                    - clip.originalStart + (clip.telestration?.offset ?? 0)
            }
        }
        // Drawn holds use their drawing clock; plain holds use their local
        // pause clock. Window context preserves/rebases the respective clock.
        for index in result.indices {
            for piece in result[index].clips.indices {
                if let id = contextID(result[index].clips[piece]), let start = context[id] {
                    result[index].clips[piece].stayTransitionStart = start
                }
            }
        }
        return result
    }

    static func state(_ drawing: Telestration, at time: Double, overlapStart: Double?) -> TelestrationRules.State {
        guard let overlapStart, time >= overlapStart else { return TelestrationRules.state(of: drawing, at: time) }
        var state = TelestrationRules.state(of: drawing, at: time)
        let staying = TelestrationRules.lingerState(of: drawing, at: time - overlapStart)
        // Preserve paint order, including figures that have finished fading.
        state.figures = drawing.figures.compactMap { figure in
            let candidates = (figure.linger ?? 0) > 0 ? staying.figures : state.figures
            return candidates.first { $0.figure == figure }
        }
        return state
    }
}
