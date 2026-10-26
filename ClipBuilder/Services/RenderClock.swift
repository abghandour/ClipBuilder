import Foundation
import Synchronization

/// The seconds each join of an assembly took out of the clock, by gap index
/// (gap k joins segment k and k + 1). Filled while segments are joined.
nonisolated final class JoinOverlaps: Sendable {
    private let values = Mutex<[Int: Double]>([:])

    func record(_ gap: Int, _ overlap: Double) {
        values.withLock { $0[gap] = max(0, overlap) }
    }

    var all: [Int: Double] { values.withLock { $0 } }
}

/// Maps timeline seconds to seconds of the assembled video. Crossfades and
/// recipe bridges overlap neighbouring segments, so everything after a join
/// plays earlier by the overlap so far. Work burned per segment (captions,
/// fused overlays) rides the segment and needs no mapping; work applied to
/// the assembled video (dubbed speech, music, final-pass overlays, deferred
/// burn-ins) must map its timeline times through this.
nonisolated struct RenderClock: Sendable, Equatable {
    /// Segment start times on the timeline, ascending.
    private(set) var starts: [Double] = [0]
    /// Seconds removed before each segment (shifts[0] == 0).
    private(set) var shifts: [Double] = [0]

    static let identity = RenderClock()

    init() {}

    /// `overlaps[k]` is the join between segment k and k + 1.
    init(segmentStarts: [Double], overlaps: [Int: Double]) {
        guard !segmentStarts.isEmpty else { return }
        starts = segmentStarts
        shifts = [0]
        for index in 1..<max(1, segmentStarts.count) {
            shifts.append(shifts[index - 1] + (overlaps[index - 1] ?? 0))
        }
    }

    var isIdentity: Bool { shifts.allSatisfy { $0 == 0 } }

    /// A start time takes the shift of the segment it falls in. An end time
    /// that lands exactly on a join belongs to the segment before it.
    func map(_ time: Double, end: Bool = false) -> Double {
        guard !isIdentity else { return time }
        var index = 0
        for (candidate, start) in starts.enumerated() {
            let inside = end ? start < time - 0.0005 : start <= time + 0.0005
            if inside { index = candidate } else { break }
        }
        return max(0, time - shifts[index])
    }

    func map(_ lines: [DubLine]) -> [DubLine] {
        guard !isIdentity else { return lines }
        return lines.map { line in
            var line = line
            // A negative start (speech already under way) keeps its offset.
            line.start = line.start < 0 ? line.start : map(line.start)
            return line
        }
    }
}
