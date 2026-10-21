import Foundation

/// Pure luminance maths; scores are relative motion, not emotion/model labels.
nonisolated enum VIPExpressionScore {
    static func change(_ patch: [Float], from previous: [Float]) -> Double {
        guard !patch.isEmpty, patch.count == previous.count else { return 0 }
        return zip(patch, previous).reduce(0) { $0 + Double(abs($1.0 - $1.1)) } / Double(patch.count)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func normalized(_ samples: [(time: Double, score: Double)]) -> [(time: Double, score: Double)] {
        // A luminance-unit floor prevents codec noise in an almost still feed
        // from producing enormous ratios when its median is zero.
        let baseline = max(1, median(samples.map(\.score)))
        return samples.map { ($0.time, $0.score / baseline) }
    }

    static func peaks(_ samples: [(time: Double, score: Double)], minimumGap: Double) -> [Double] {
        let samples = samples.filter { $0.time.isFinite && $0.score.isFinite }.sorted { $0.time < $1.time }
        guard samples.count >= 3 else { return [] }
        let floor = 1.8 * max(1, median(samples.map(\.score)))
        let maxima = (1..<(samples.count - 1)).filter {
            samples[$0].score > floor && samples[$0].score > samples[$0 - 1].score
                && samples[$0].score >= samples[$0 + 1].score
        }.sorted {
            samples[$0].score == samples[$1].score ? samples[$0].time < samples[$1].time
                : samples[$0].score > samples[$1].score
        }
        var selected: [Double] = []
        for index in maxima where selected.allSatisfy({ abs($0 - samples[index].time) >= minimumGap }) {
            selected.append(samples[index].time)
        }
        return selected.sorted()
    }
}
