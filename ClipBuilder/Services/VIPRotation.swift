import Foundation

/// VIP shots on the source clock, independent of rendering and persistence.
nonisolated enum VIPRotation {
    static let every = FramingHolds.rotation, minimumHold = FramingHolds.vipHold, tail = FramingHolds.tail

    struct Shot: Sendable, Equatable {
        var time: Double
        var tile: Int
    }

    static func shots(range: ClosedRange<Double>, segments: [CropRecipePlanner.Segment],
                      vipTiles: [Int], recentFirst: Int?) -> [Shot] {
        let order = Array(Set(vipTiles)).sorted()
        guard let first = order.first, range.lowerBound.isFinite, range.upperBound.isFinite,
              range.upperBound > range.lowerBound else { return [] }
        let segments = segments.sorted { $0.start < $1.start }
        func talker(at time: Double) -> Int? {
            segments.last { $0.start <= time && $0.end > time }?.talker
        }
        let initial = talker(at: range.lowerBound).flatMap { order.contains($0) ? $0 : nil }
            ?? recentFirst.flatMap { order.contains($0) ? $0 : nil } ?? first
        var shots = [Shot(time: range.lowerBound, tile: initial)]
        guard order.count > 1 else { return shots }
        var time = range.lowerBound
        var tick = time + every
        while let current = shots.last {
            let boundary = segments.flatMap { [$0.start, $0.end] }.filter { $0 > time + 1e-6 }.min()
                ?? range.upperBound
            let heldAt = current.time + minimumHold
            let next = min(boundary, tick, heldAt > time + 1e-6 ? heldAt : range.upperBound)
            // The last shot must also satisfy the minimum hold.
            guard next < range.upperBound - tail, next <= range.upperBound - minimumHold else { break }
            time = next
            let speaker = talker(at: time)
            var desired = current.tile
            if let speaker, order.contains(speaker) {
                desired = speaker
            } else if time >= tick - 1e-6 {
                // A VIP ending exactly on a tick keeps the picture until the next tick.
                let justStopped = segments.contains { abs($0.end - time) < 1e-6 && order.contains($0.talker) }
                if !justStopped, let index = order.firstIndex(of: current.tile) {
                    desired = order[(index + 1) % order.count]
                }
            }
            if desired != current.tile, time >= heldAt - 1e-6 {
                shots.append(Shot(time: time, tile: desired))
                tick = time + every
            } else if time >= tick - 1e-6 {
                tick += every
            }
        }
        return shots
    }
}
