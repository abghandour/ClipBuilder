import Foundation

/// Talker full screen with a shot clock: one person at a time, cutting to
/// whoever talks, but never the same picture for longer than `maxShot`, and
/// never a change sooner than `minShot` after the last one. Every change of
/// the person shown restarts the clock.
nonisolated enum TalkerShotPlanning {
    static let maxShot = 8.0
    static let minShot = 2.0
    static let maxRange = 3.0...30.0
    static let minRange = 1.0...10.0

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// Both timings clamped to their ranges, with Min never above Max.
    static func timings(max maxValue: Double?, min minValue: Double?) -> (max: Double, min: Double) {
        let maxShot = clamp(maxValue ?? maxShot, to: maxRange)
        let minShot = Swift.min(maxShot, clamp(minValue ?? minShot, to: minRange))
        return (maxShot, minShot)
    }

    /// When the picture changes and to which tile, from the recording's
    /// talker segments (source seconds, in order, covering `range`).
    ///
    /// While the person shown is the one talking, the picture holds until
    /// the talker changes (the move waits for `minShot` since the last
    /// change) or `maxShot` runs out, whichever comes first. A forced cut
    /// goes to the most recent other person who has spoken so far, else
    /// round-robin through the others in `order` (`recent` lists everyone
    /// from the start, so who has spoken is read off the segments). While
    /// the person shown is not the one talking, the picture moves to the
    /// talker once `minShot` has passed.
    static func events(segments: [CropRecipePlanner.Segment], range: ClosedRange<Double>, order: [Int],
                       maxShot: Double, minShot: Double) -> [(time: Double, tile: Int?)] {
        guard let first = segments.first else { return [] }
        let end = range.upperBound
        func segment(at time: Double) -> CropRecipePlanner.Segment? {
            segments.last { $0.start <= time + 1e-9 && time < $0.end - 1e-9 } ?? (time >= end - 1e-9 ? nil : segments.last)
        }
        var shown = first.talker
        var since = range.lowerBound
        var events: [(time: Double, tile: Int?)] = [(range.lowerBound, shown)]
        var rotation = 0
        var time = range.lowerBound
        func change(to tile: Int, at moment: Double) {
            shown = tile
            since = moment
            events.append((moment, tile))
        }
        while time < end - 1e-6 {
            guard let current = segment(at: time) else { break }
            let countBefore = events.count
            let next: Double
            if shown == current.talker {
                let forced = since + maxShot
                if forced < current.end - 1e-6, forced < end - 1e-6 {
                    // The same person has held the picture long enough.
                    let others = order.filter { $0 != current.talker }
                    guard !others.isEmpty else { next = current.end; time = next; continue }
                    let target: Int
                    let spoken = Set(segments.lazy.filter { $0.start < forced - 1e-9 }.map(\.talker))
                    if let recent = current.recent.first(where: { $0 != current.talker && spoken.contains($0) }) {
                        target = recent
                    } else {
                        target = others[rotation % others.count]
                        rotation += 1
                    }
                    change(to: target, at: forced)
                    next = forced
                } else {
                    // The talker changes at the segment's end; the picture
                    // follows once the shot has lasted `minShot`.
                    let moveAt = max(current.end, since + minShot)
                    guard moveAt < end - 1e-6, let then = segment(at: moveAt) else { break }
                    if then.talker != shown { change(to: then.talker, at: moveAt) }
                    next = moveAt
                }
            } else {
                let moveAt = since + minShot
                guard moveAt < end - 1e-6, let then = segment(at: moveAt) else { break }
                if then.talker != shown { change(to: then.talker, at: moveAt) }
                next = moveAt
            }
            // A forced cut can land on the moment the loop stands at (Min
            // equal to Max); the changed picture is progress, a repeat is not.
            guard next > time + 1e-9 || events.count > countBefore, events.count < 10_000 else { break }
            time = next
        }
        return events
    }
}
