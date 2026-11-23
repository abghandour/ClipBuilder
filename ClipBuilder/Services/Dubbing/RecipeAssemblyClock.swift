import Foundation

/// The frame boundaries used by concatenateTimed, including encoder tails
/// measured on recipe remainders and bridges. Never used for non-recipe joins.
nonisolated enum RecipeAssemblyClock {
    struct Piece: Sendable {
        var originalIndex: Int
        var expandedIndex: Int
        var head: Double
        var tail: Double
    }

    static func ranges(durations: [Double], overlaps: [Int: Double]) -> [Range<Double>] {
        var sourceCursor = 0.0
        var previousEnd = 0
        var outputEnd = 0
        return durations.enumerated().map { index, duration in
            sourceCursor += duration
            let count = max(1, Int((sourceCursor * 30).rounded()) - previousEnd)
            previousEnd += count
            let overlap = index == 0 ? 0 : Int(((overlaps[index - 1] ?? 0) * 30).rounded())
            let start = outputEnd - overlap
            outputEnd = start + count
            return (Double(start) / 30)..<(Double(outputEnd) / 30)
        }
    }
}
