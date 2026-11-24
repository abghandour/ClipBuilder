import Foundation

/// Stored evidence only: shared by the Sources state and render log.
nonisolated enum GazeReport {
    struct Summary: Sendable {
        var tile: Int
        var share: Double
        var seconds: [GazeMeter.Span.Kind: Double]

        func line(clipNumber: Int) -> String? {
            guard share >= 1.0 / 3 else { return nil }
            let details = GazeMeter.Span.Kind.allCases.compactMap { kind -> String? in
                guard let duration = seconds[kind], duration > 0 else { return nil }
                return String(format: "%@ %.1f s", locale: Locale(identifier: "en_US_POSIX"), kind.rawValue, duration)
            }.joined(separator: ", ")
            return "Gaze: looks away \(Int((share * 100).rounded()))% of clip \(clipNumber) (\(details))"
        }
    }

    static func summary(_ records: [GazeSpanRecord], range: ClosedRange<Double>,
                        separateFeeds: Bool) -> Summary {
        let current = records.filter { $0.meterVersion == GazeMeter.meterVersion && (separateFeeds || $0.tile == 0) }
        let tiles = Dictionary(grouping: current, by: \.tile)
        var best = Summary(tile: 0, share: 0, seconds: [:])
        for tile in tiles.keys.sorted() {
            let spans = tiles[tile, default: []].map(\.span)
            let share = GazeMeter.share(spans, of: range)
            guard share > best.share else { continue }
            var seconds: [GazeMeter.Span.Kind: Double] = [:]
            for kind in GazeMeter.Span.Kind.allCases {
                seconds[kind] = GazeMeter.share(spans.filter { $0.kind == kind }, of: range)
                    * max(0, range.upperBound - range.lowerBound)
            }
            best = Summary(tile: tile, share: share, seconds: seconds)
        }
        return best
    }
}
