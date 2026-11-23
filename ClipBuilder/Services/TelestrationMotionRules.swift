import Foundation

/// One picture's source intervals, after pauses, become ordinary speed pieces.
nonisolated enum TelestrationMotionRules {
    static let severalPictures = "the clip shows several pictures"

    static func paused(_ drawing: Telestration) -> Telestration {
        var drawing = drawing
        drawing.motion = nil
        return drawing
    }

    /// Kept drawings include paused drawings: neither kind may be crossed.
    static func fallbackReason(_ drawing: Telestration, in pieces: [TimelineClip],
                               drawings: [Telestration]) -> String? {
        guard let motion = drawing.motion else { return nil }
        guard let piece = pieces.first(where: {
            guard let start = $0.sourceStart else { return false }
            return $0.hold != true && !$0.bumper && !$0.isCutaway
                && drawing.time >= start - 1e-9 && drawing.time < start + $0.sourceSpan - 1e-9
        }), let start = piece.sourceStart else { return "no moving footage at the drawing" }
        let speed = piece.effectiveSpeed
        guard motion.isFinite, (0.25...1).contains(motion), speed.isFinite,
              speed * motion >= StrikeImpactRules.minimumSpeed else { return "speed would be below 0.25×" }
        let end = drawing.time + drawing.duration * motion * speed
        guard end.isFinite, drawing.duration.isFinite else { return "invalid drawing duration" }
        if drawings.contains(where: { other in
            guard other != drawing else { return false }
            let otherEnd = other.time + other.duration * (other.motion ?? 0) * speed
            return (other.time >= drawing.time - 1e-9 && other.time < end - 1e-9)
                || (other.time < drawing.time && otherEnd > drawing.time + 1e-9)
        }) { return "overlaps another drawing" }
        if pieces.contains(where: {
            $0.hold == true && ($0.sourceStart ?? -.infinity) >= drawing.time - 1e-9
                && ($0.sourceStart ?? .infinity) < end - 1e-9
        }) { return "overlaps a contact pause or drawn pause" }
        let clipEnd = pieces.filter { $0.hold != true }.compactMap { part in
            part.sourceStart.map { $0 + part.sourceSpan }
        }.max() ?? start + piece.sourceSpan
        guard (clipEnd - end) / speed >= StrikeFreezeRules.minimumPiece - 1e-9 else {
            return "not enough footage after the drawing"
        }
        let tail = (start + piece.sourceSpan - end) / speed
        let head = (drawing.time - start) / speed
        guard (head <= 1e-9 || head >= StrikeFreezeRules.minimumPiece - 1e-9),
              tail >= -1e-9, (tail <= 1e-9 || tail >= StrikeFreezeRules.minimumPiece - 1e-9),
              drawing.duration >= StrikeFreezeRules.minimumPiece - 1e-9 else { return "a piece would be too short" }
        return nil
    }

    static func moving(_ pieces: [TimelineClip], drawings: [Telestration])
        -> (pieces: [TimelineClip], stretches: [StrikeImpactRules.Stretch], fallback: [Telestration]) {
        let candidates = drawings.filter { $0.motion != nil }.sorted { $0.time < $1.time }
        guard !candidates.isEmpty else { return (pieces, [], []) }
        var result = pieces
        var stretches: [StrikeImpactRules.Stretch] = []
        var fallback: [Telestration] = []
        for drawing in candidates {
            // Check against the original pieces for conflicts, then against
            // earlier automatic splits for the remaining minimum head piece.
            guard fallbackReason(drawing, in: pieces, drawings: drawings) == nil,
                  fallbackReason(drawing, in: result, drawings: []) == nil,
                  let motion = drawing.motion,
                  let index = result.firstIndex(where: {
                      guard let start = $0.sourceStart else { return false }
                      return $0.hold != true && !$0.bumper && !$0.isCutaway
                          && drawing.time >= start - 1e-9 && drawing.time < start + $0.sourceSpan - 1e-9
                  }), let start = result[index].sourceStart else {
                fallback.append(paused(drawing))
                continue
            }
            let piece = result[index], speed = piece.effectiveSpeed
            let end = drawing.time + drawing.duration * motion * speed
            var parts: [TimelineClip] = []
            var cursor = piece.startTime
            if drawing.time > start + 1e-9 {
                var head = StrikeImpactRules.slice(piece, from: start, to: drawing.time)
                head.duration = (drawing.time - start) / speed
                parts.append(head)
                cursor += head.duration
            }
            var middle = StrikeImpactRules.slice(piece, from: drawing.time, to: end)
            middle.startTime = cursor
            middle.duration = drawing.duration
            middle.speed = speed * motion
            middle.telestration = drawing
            parts.append(middle)
            if end < start + piece.sourceSpan - 1e-9 {
                var tail = StrikeImpactRules.slice(piece, from: end, to: start + piece.sourceSpan)
                tail.startTime = cursor + drawing.duration
                tail.duration = (start + piece.sourceSpan - end) / speed
                parts.append(tail)
            }
            let stretch = StrikeImpactRules.Stretch(start: drawing.time, end: end, factor: motion)
            let added = drawing.duration * (1 - motion)
            for later in result.indices where later > index { result[later].startTime += added }
            result.replaceSubrange(index...index, with: parts)
            stretches.append(stretch)
        }
        return (result, stretches, fallback)
    }
}
