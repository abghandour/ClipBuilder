import Foundation

/// Builder-only drawings share the reel splitter without acquiring its pause marker.
nonisolated enum TelestrationHoldRules {
    static func insertionReason(in clip: TimelineClip, at timelineTime: Double) -> String? {
        if clip.bumper { return "Drawings cannot be added to a bumper." }
        if clip.isCutaway { return "Drawings cannot be added to B-roll." }
        if clip.hold == true { return "Use Add drawing or Edit drawing on this freeze frame." }
        guard timelineTime.isFinite, clip.startTime.isFinite, clip.duration.isFinite,
              clip.effectiveSpeed.isFinite, clip.effectiveSpeed > 0,
              let start = clip.sourceStart, start.isFinite, start >= 0,
              let end = clip.sourceEnd, end.isFinite,
              (start + clip.sourceSpan).isFinite, start + clip.sourceSpan <= end + 1e-9 else {
            return "The clip's source bounds are unavailable."
        }
        let elapsed = timelineTime - clip.startTime
        guard elapsed >= 0, elapsed < clip.duration else { return "Move the playhead inside this clip." }
        guard elapsed >= StrikeFreezeRules.minimumPiece - 1e-9,
              clip.duration - elapsed >= StrikeFreezeRules.minimumPiece - 1e-9 else {
            return "Move the playhead at least 0.25 seconds from either end of this clip."
        }
        return nil
    }

    static func insertion(in clip: TimelineClip, at timelineTime: Double,
                          drawing: Telestration) -> [TimelineClip]? {
        guard insertionReason(in: clip, at: timelineTime) == nil,
              drawing.duration.isFinite, StrikeFreezeRules.drawingHoldRange.contains(drawing.duration),
              let start = clip.sourceStart else { return nil }
        var drawing = drawing
        drawing.time = start + (timelineTime - clip.startTime) * clip.effectiveSpeed
        drawing.offset = nil
        var source = clip
        // The reel splitter refuses a second automatic freeze. A manual cut
        // is allowed, but every piece must retain the original flag exactly.
        source.strikeImpactsFrozen = nil
        var pieces = StrikeFreezeRules.pieces(source, pauses: [
            .init(time: drawing.time, duration: drawing.duration, drawing: drawing)
        ])
        guard pieces.count == 3 else { return nil }
        for index in pieces.indices { pieces[index].strikeImpactsFrozen = clip.strikeImpactsFrozen }
        return pieces
    }

    static func applying(_ drawing: Telestration?, to hold: TimelineClip) -> TimelineClip {
        var result = hold
        let offset = hold.telestration?.offset ?? 0
        result.telestration = drawing.map {
            var anchored = $0
            anchored.time = hold.sourceStart ?? $0.time
            anchored.offset = offset > 0 ? offset : nil
            return anchored
        }
        if let drawing {
            // A piece of a drawing split by a bumper or a cut stays that piece:
            // the part after the split keeps its place in the animation, and
            // the part before it keeps the length it was cut to.
            let remaining = max(StrikeFreezeRules.minimumPiece, drawing.duration - offset)
            let cutShort = hold.telestration.map { hold.duration < $0.duration - offset - 1e-6 } ?? false
            result.duration = cutShort ? min(hold.duration, remaining) : remaining
        } else {
            result.duration = min(StrikeFreezeRules.holdRange.upperBound,
                                  max(StrikeFreezeRules.holdRange.lowerBound, hold.duration))
        }
        if let path = hold.cameraPath {
            result.cameraPath = HoldClipRules.cameraPath(path, duration: result.duration)
        }
        return result
    }
}
