import Foundation

/// The ripple a cut leaves on a timeline: `removed` stretches (timeline
/// seconds of the uncut document) close up and everything after them moves
/// left. `time(_:)` is monotone; a time inside a removed stretch maps to
/// where that stretch began. Used by `TimelineDocument.applyingCuts` to move
/// every timed item along with the footage.
nonisolated struct TimelineCutMap: Sendable, Equatable {
    /// Disjoint, sorted, non-empty stretches.
    let removed: [Range<Double>]

    init(removed: [Range<Double>]) {
        var merged: [Range<Double>] = []
        for span in removed.filter({ $0.upperBound > $0.lowerBound }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        self.removed = merged
    }

    /// Removed seconds before `t`.
    func removedBefore(_ t: Double) -> Double {
        removed.reduce(0) { total, span in
            if span.upperBound <= t { return total + (span.upperBound - span.lowerBound) }
            if span.lowerBound < t { return total + (t - span.lowerBound) }
            return total
        }
    }

    /// Where `t` lands after the cut.
    func time(_ t: Double) -> Double { t - removedBefore(t) }

    /// Whether `t` falls inside a removed stretch.
    func isRemoved(_ t: Double) -> Bool {
        removed.contains { $0.lowerBound <= t && t < $0.upperBound }
    }

    /// Seconds cut from the front of `start..<end`: from `start` to the first
    /// kept time (at most the whole item).
    func headTrim(from start: Double, to end: Double) -> Double {
        guard let span = removed.first(where: { $0.lowerBound <= start && start < $0.upperBound }) else { return 0 }
        return min(span.upperBound, end) - start
    }

    /// `clip` moved by the cut. A bumper keeps its length; any other clip
    /// loses the removed time it spans, its source trimmed to match (the
    /// head from the front, the rest from the tail). Nil when what is left
    /// is shorter than `minimumPiece`. `baseSource` gives the resolved source
    /// start of a clip whose `sourceStart` is nil (an untrimmed scene clip).
    func clip(_ clip: TimelineClip, minimumPiece: Double,
              baseSource: (TimelineClip) -> Double?) -> TimelineClip? {
        var moved = clip
        let start = clip.startTime, end = clip.startTime + clip.duration
        moved.startTime = time(start)
        if clip.bumper { return moved }
        let duration = time(end) - moved.startTime
        guard abs(duration - clip.duration) > 1e-9 else { return moved }
        guard duration >= minimumPiece else { return nil }
        let speed = clip.effectiveSpeed
        let head = headTrim(from: start, to: end) * speed
        let base = clip.sourceStart ?? baseSource(clip) ?? 0
        moved.sourceStart = base + head
        moved.sourceEnd = base + head + duration * speed
        moved.duration = duration
        if let path = clip.cameraPath, path.count >= 2 {
            let sliced = CenterStageService.slice(path, from: head, duration: duration * speed)
            moved.cameraPath = sliced.count >= 2 ? sliced : nil
        }
        return moved
    }
}
