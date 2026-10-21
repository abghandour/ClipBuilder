import Foundation

/// All times are on the source clock. No decoding or timeline mutation here.
nonisolated enum VIPBRollSchedule {
    struct Break: Sendable, Equatable {
        var start: Double
        var duration: Double
        var tile: Int?
        var expressive: Bool
    }

    static let minimum = 2.5, maximum = 4.0, lead = 3.0, gap = 4.0, share = 0.35

    /// Non-VIP speech plus silence, subtracting even overlapping VIP speech.
    /// Resolve unnamed turns through their feed so they cannot hide VIP speech.
    static func eligible(turns: [SpeakerTurn], vipKeys: Set<String>, tiles: [PodcastTile],
                         range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        guard !vipKeys.isEmpty else { return [] }
        let forbidden = CropRecipePlanner.merged(turns.compactMap { turn -> ClosedRange<Double>? in
            let key = turn.personKey ?? CropRecipePlanner.tile(for: turn, tiles: tiles)
                .flatMap { index in tiles.first { $0.index == index }?.personKey }
            guard key.map(vipKeys.contains) == true else { return nil }
            let start = max(range.lowerBound, turn.start), end = min(range.upperBound, turn.end)
            return end > start ? start...end : nil
        })
        var result: [ClosedRange<Double>] = []
        var cursor = range.lowerBound
        for span in forbidden {
            if span.lowerBound > cursor { result.append(cursor...span.lowerBound) }
            cursor = max(cursor, span.upperBound)
        }
        if cursor < range.upperBound { result.append(cursor...range.upperBound) }
        return result
    }

    /// `peaks` arrives in descending score order; its tuple deliberately keeps
    /// the scheduling API independent of how expression scores are measured.
    static func breaks(range: ClosedRange<Double>, eligible: [ClosedRange<Double>],
                       peaks: [(time: Double, tile: Int)], speakerChanges: [Double],
                       rotate: Bool = false, vipTiles: [Int] = []) -> [Break] {
        guard range.lowerBound.isFinite, range.upperBound.isFinite else { return [] }
        let spans = CropRecipePlanner.merged(eligible.compactMap { span -> ClosedRange<Double>? in
            let start = max(range.lowerBound + lead, span.lowerBound)
            let end = min(range.upperBound, span.upperBound)
            return start.isFinite && end.isFinite && end - start >= minimum ? start...end : nil
        })
        var result: [Break] = []
        var remaining = (range.upperBound - range.lowerBound) * share
        let changes = speakerChanges.filter(\.isFinite).sorted()

        func accept(start: Double, end: Double, tile: Int?, expressive: Bool) {
            var end = min(end, start + remaining)
            // Trimming can expose an earlier change in the new final second.
            while let change = changes.first(where: { $0 > start && $0 < end && $0 >= end - 1 }) {
                end = change
            }
            let duration = end - start
            guard duration >= minimum, duration <= maximum,
                  result.allSatisfy({ start >= $0.start + $0.duration + gap - 1e-6
                      || end + gap <= $0.start + 1e-6 }) else { return }
            result.append(Break(start: start, duration: duration, tile: tile, expressive: expressive))
            remaining -= duration
        }

        if rotate {
            // Work chronologically so alternation means consecutive on-screen breaks,
            // not consecutive entries in the expression score ranking.
            for span in spans {
                var cursor = max(span.lowerBound, result.last.map { $0.start + $0.duration + gap } ?? span.lowerBound)
                while remaining >= minimum {
                    let candidates = peaks.filter {
                        $0.time.isFinite && span.contains($0.time)
                            && max(span.lowerBound, $0.time - maximum / 2) >= cursor
                            && min(span.upperBound, $0.time + maximum / 2)
                                - max(span.lowerBound, $0.time - maximum / 2) >= minimum
                    }
                    let preferred = candidates.filter { $0.tile != result.last?.tile }
                    var accepted = false
                    for peak in preferred.isEmpty ? candidates : preferred {
                        let count = result.count
                        accept(start: max(span.lowerBound, peak.time - maximum / 2),
                               end: min(span.upperBound, peak.time + maximum / 2), tile: peak.tile, expressive: true)
                        if result.count > count, let last = result.last {
                            cursor = last.start + last.duration + gap
                            accepted = true
                            break
                        }
                    }
                    if !accepted { break }
                }
            }
        } else {
            for peak in peaks where peak.time.isFinite {
                guard let span = spans.first(where: { $0.contains(peak.time) }) else { continue }
                accept(start: max(span.lowerBound, peak.time - maximum / 2),
                       end: min(span.upperBound, peak.time + maximum / 2), tile: peak.tile, expressive: true)
            }
        }
        if result.isEmpty {
            let length = spans.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            guard length >= minimum else { return [] }
            let count = max(1, Int((length / max(10, length / 3)).rounded(.down)))
            // Space centers along eligible time, skipping the ineligible gaps.
            for index in 0..<count {
                var offset = length * (Double(index) + 0.5) / Double(count)
                for span in spans {
                    let length = span.upperBound - span.lowerBound
                    if offset > length { offset -= length; continue }
                    let duration = min(3, length)
                    let start = max(span.lowerBound, min(span.upperBound - duration, span.lowerBound + offset - duration / 2))
                    let tile = rotate && !vipTiles.isEmpty ? vipTiles[result.count % vipTiles.count] : nil
                    accept(start: start, end: start + duration, tile: tile, expressive: false)
                    break
                }
            }
        }
        return result.sorted { $0.start < $1.start }
    }
}
