import Foundation

/// Whole-timeline pauses are owned by the holds, including after ordinary
/// Builder edits. Reel/legacy holds without a pause group are not dub freezes.
nonisolated enum DubFreezes {
    static func intervals(in document: TimelineDocument) -> [Range<Double>] {
        merged(document.videoTrack.compactMap { clip in
            guard clip.hold == true, clip.pauseGroup != nil,
                  clip.startTime.isFinite, clip.duration.isFinite, clip.duration > 0 else { return nil }
            return clip.startTime..<(clip.startTime + clip.duration)
        })
    }

    static func intervals(in document: TimelineDocument, clock: RenderClock) -> [Range<Double>] {
        // Split at joins before mapping: each piece belongs to its own
        // segment, including ends exactly on a crossfade/recipe boundary.
        merged(intervals(in: document).flatMap { interval in
            let boundaries = [interval.lowerBound] + clock.starts.filter {
                $0 > interval.lowerBound && $0 < interval.upperBound
            } + [interval.upperBound]
            return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
                let lower = clock.map(start), upper = clock.map(end, end: true)
                return upper > lower ? lower..<upper : nil
            }
        })
    }

    static func merged(_ intervals: [Range<Double>]) -> [Range<Double>] {
        var result: [Range<Double>] = []
        for interval in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) where !interval.isEmpty {
            if let last = result.last, interval.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, interval.upperBound)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// The planning clock contains motion only. At a freeze the clock stops.
    static func motionTime(_ time: Double, freezes: [Range<Double>]) -> Double {
        freezes.reduce(time) { result, freeze in
            result - min(freeze.upperBound - freeze.lowerBound, max(0, time - freeze.lowerBound))
        }
    }

    /// At the collapsed boundary, speech starts after the freeze.
    static func timelineTime(_ time: Double, freezes: [Range<Double>]) -> Double {
        var result = time
        for freeze in freezes {
            guard result >= freeze.lowerBound else { break }
            result += freeze.upperBound - freeze.lowerBound
        }
        return result
    }
}
