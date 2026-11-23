import Foundation
import Synchronization

/// The seconds each join of an assembly took out of the clock, by gap index
/// (gap k joins segment k and k + 1). Filled while segments are joined.
nonisolated final class JoinOverlaps: Sendable {
    private let values = Mutex<[Int: Double]>([:])
    private let pieces = Mutex<[Int: Range<Double>]>([:])
    nonisolated struct Bridge: Sendable, Equatable {
        var gap: Int
        var tail: Double
        var head: Double
        var range: Range<Double>

        func shifted(gapOffset: Int, timeOffset: Double) -> Bridge {
            Bridge(gap: gap + gapOffset, tail: tail, head: head,
                range: (range.lowerBound + timeOffset)..<(range.upperBound + timeOffset))
        }

        func mapped(through clock: RenderClock) -> Bridge {
            Bridge(gap: gap, tail: tail, head: head,
                range: clock.map(range.lowerBound)..<clock.map(range.upperBound, end: true))
        }
    }
    private let bridges = Mutex<[Bridge]>([])

    func bridge(gap: Int, tail: Double, head: Double, range: Range<Double>) {
        bridges.withLock { $0.append(Bridge(gap: gap, tail: tail, head: head, range: range)) }
    }

    var assembledBridges: [Bridge] { bridges.withLock { $0 } }

    func record(_ gap: Int, _ overlap: Double) {
        values.withLock { $0[gap] = max(0, overlap) }
    }

    var all: [Int: Double] { values.withLock { $0 } }

    func reconcile(_ index: Int, range: Range<Double>) {
        pieces.withLock { $0[index] = range }
    }

    var assembledPieces: [Int: Range<Double>] { pieces.withLock { $0 } }
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
    private var reconciled: [Int: Range<Double>] = [:]
    private var ends: [Double] = []
    private var bridges: [JoinOverlaps.Bridge] = []

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

    init(segmentStarts: [Double], segmentEnds: [Double], joins: JoinOverlaps) {
        self.init(segmentStarts: segmentStarts, overlaps: joins.all)
        guard !joins.assembledPieces.isEmpty else { return }
        reconciled = joins.assembledPieces
        ends = segmentEnds
        bridges = joins.assembledBridges
    }

    /// Unit-rate piece origins are assembly records, not mapped editorial
    /// endpoints: an incoming start can lie inside a compressed bridge.
    func assemblyPieces(segmentEnds: [Double]) -> [Int: Range<Double>] {
        Dictionary(uniqueKeysWithValues: starts.indices.compactMap { index in
            guard let end = segmentEnds[safe: index] else { return nil }
            let range = reconciled[index] ?? ((starts[index] - shifts[index])..<(end - shifts[index]))
            return (index, range)
        })
    }

    var isIdentity: Bool { reconciled.isEmpty && shifts.allSatisfy { $0 == 0 } }

    /// A start time takes the shift of the segment it falls in. An end time
    /// that lands exactly on a join belongs to the segment before it.
    func map(_ time: Double, end: Bool = false) -> Double {
        guard !isIdentity else { return time }
        for bridge in bridges {
            guard let stop = ends[safe: bridge.gap],
                  let next = starts[safe: bridge.gap + 1] else { continue }
            let lower = stop - bridge.tail, upper = next + bridge.head
            let consumed = upper - lower
            let measured = bridge.range.upperBound - bridge.range.lowerBound
            guard consumed > 0, abs(consumed - measured) > 1e-9,
                  time >= lower, time < upper || end && abs(time - upper) < 1e-9 else { continue }
            return max(0, bridge.range.lowerBound + (time - lower) * measured / consumed)
        }
        var index = 0
        for (candidate, start) in starts.enumerated() {
            let inside = end ? start < time - 0.0005 : start <= time + 0.0005
            if inside { index = candidate } else { break }
        }
        if let piece = reconciled[index], let stop = ends[safe: index], stop > starts[index] {
            // Encoder padding changes boundaries, not the speed of speech or
            // picture inside a piece. Keep a unit-rate local clock; the exact
            // endpoint includes the measured tail that concatenation retained.
            if time >= stop - 0.0005 {
                return max(0, piece.upperBound + max(0, time - stop))
            }
            return max(0, min(piece.upperBound, piece.lowerBound + time - starts[index]))
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
