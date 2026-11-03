import Foundation
import CoreGraphics

/// One frame of measured camera motion: how far the picture content moved
/// since the previous sample, as fractions of the feed's width and height,
/// top-left origin (positive dx = content moved right, dy = moved down).
nonisolated struct CameraMotionSample: Codable, Sendable, Equatable {
    var time: Double
    var dx: Double
    var dy: Double
    /// The source itself cut to another shot at this frame: the picture
    /// changed wholesale, so the shift is meaningless and the camera should
    /// jump, not glide.
    var cut = false

    init(time: Double, dx: Double, dy: Double, cut: Bool = false) {
        self.time = time
        self.dx = dx
        self.dy = dy
        self.cut = cut
    }
}

/// Reduce camera motion: finds the stretches where the recording camera
/// shook, and reshapes a camera path so the crop zooms in enough to cancel
/// the shake there. Pure; the measurement lives in `CameraMotionMeter`.
nonisolated enum CameraMotionPlanning {
    /// A shake envelope above this fraction of the frame counts as camera motion.
    static let threshold = 0.004
    /// Half-width of the envelope and margin windows: a shaky stretch starts
    /// this long before the first wobble and ends this long after the last.
    static let window = 0.5
    /// Half-width of the baseline fit. A pan is close to straight over 2 s;
    /// slower hand-held sway than that is shake and gets cancelled.
    static let baselineWindow = 1.0
    /// The crop never gives up more than this fraction of the frame per side.
    static let maxMargin = 0.08
    /// Keyframe cadence inside shaky stretches, the same as the measurement
    /// cadence, so the counter-move is not itself a coarser wobble; ffmpeg
    /// ramps linearly between keyframes.
    static let keyframeInterval = 1.0 / 30

    struct Shake: Sendable, Equatable {
        var time: Double
        /// High-pass drift, fractions of the frame.
        var x: Double
        var y: Double
        /// The shake envelope (largest |shake| within `window`), per axis.
        var envelopeX: Double
        var envelopeY: Double
        /// The smoothed envelope the crop keeps as margin, per axis.
        var marginX: Double
        var marginY: Double
    }

    struct Profile: Sendable, Equatable {
        var shakes: [Shake]
        /// Stretches whose envelope exceeds `threshold`, merged across short gaps.
        var sections: [ClosedRange<Double>]
        var peak: Double
        /// Times of the source's own shot changes.
        var cuts: [Double] = []

        func shake(at time: Double) -> Shake? { CameraMotionPlanning.interpolate(shakes, at: time) }
    }

    /// nil when nothing in the clip shakes above the threshold.
    static func profile(_ samples: [CameraMotionSample], threshold: Double = threshold,
                        window: Double = window, baselineWindow: Double = baselineWindow) -> Profile? {
        let sorted = samples.filter { $0.dx.isFinite && $0.dy.isFinite }.sorted { $0.time < $1.time }
        let cuts = Self.cuts(in: samples)
        guard sorted.count >= 2 else { return nil }
        var drift: [(time: Double, x: Double, y: Double)] = []
        var x = 0.0, y = 0.0
        for sample in sorted {
            // A shot change is not camera motion: the drift continues from
            // where it was.
            if !sample.cut {
                x += sample.dx
                y += sample.dy
            }
            drift.append((sample.time, x, y))
        }
        let times = drift.map(\.time)
        func windowed(_ index: Int, _ window: Double = window) -> Range<Int> {
            let lower = times.partitionPoint { $0 < times[index] - window }
            let upper = times.partitionPoint { $0 <= times[index] + window }
            return lower..<max(upper, lower + 1)
        }
        var shakes = drift.indices.map { index -> Shake in
            // The baseline is a straight line fitted through the window, so
            // a steady pan (and a window cut short at either end of the
            // clip) is intended motion, not shake.
            let range = windowed(index, baselineWindow)
            let (baseX, baseY) = Self.fitted(drift[range], at: drift[index].time)
            return Shake(time: drift[index].time, x: drift[index].x - baseX, y: drift[index].y - baseY,
                         envelopeX: 0, envelopeY: 0, marginX: 0, marginY: 0)
        }
        // The baseline fit straddling a cut mixes two shots; nothing within
        // the window of a cut counts as shake.
        for index in shakes.indices where cuts.contains(where: { abs($0 - shakes[index].time) <= window }) {
            shakes[index].x = 0
            shakes[index].y = 0
        }
        for index in shakes.indices {
            let range = windowed(index)
            shakes[index].envelopeX = shakes[range].map { abs($0.x) }.max() ?? 0
            shakes[index].envelopeY = shakes[range].map { abs($0.y) }.max() ?? 0
        }
        let peak = shakes.map { max($0.envelopeX, $0.envelopeY) }.max() ?? 0
        guard peak > threshold else { return nil }
        for index in shakes.indices {
            let range = windowed(index)
            let count = Double(range.count)
            // Only shaky stretches earn a margin; the average ramps it in and out.
            shakes[index].marginX = min(maxMargin, shakes[range].reduce(0) {
                $0 + (max($1.envelopeX, $1.envelopeY) > threshold ? $1.envelopeX : 0) } / count)
            shakes[index].marginY = min(maxMargin, shakes[range].reduce(0) {
                $0 + (max($1.envelopeX, $1.envelopeY) > threshold ? $1.envelopeY : 0) } / count)
        }
        var sections: [ClosedRange<Double>] = []
        for shake in shakes where max(shake.envelopeX, shake.envelopeY) > threshold {
            if let last = sections.last, shake.time - last.upperBound <= window {
                sections[sections.count - 1] = last.lowerBound...shake.time
            } else {
                sections.append(shake.time...shake.time)
            }
        }
        return Profile(shakes: shakes, sections: sections, peak: peak, cuts: cuts)
    }

    /// Times of the source's own shot changes, in order.
    static func cuts(in samples: [CameraMotionSample]) -> [Double] {
        samples.filter(\.cut).map(\.time).sorted()
    }

    /// Least-squares line through the points, evaluated at `time`.
    private static func fitted(_ points: ArraySlice<(time: Double, x: Double, y: Double)>, at time: Double) -> (Double, Double) {
        let n = Double(points.count)
        let meanT = points.reduce(0) { $0 + $1.time } / n
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        let variance = points.reduce(0) { $0 + ($1.time - meanT) * ($1.time - meanT) }
        guard variance > 1e-12 else { return (meanX, meanY) }
        let slopeX = points.reduce(0) { $0 + ($1.time - meanT) * ($1.x - meanX) } / variance
        let slopeY = points.reduce(0) { $0 + ($1.time - meanT) * ($1.y - meanY) } / variance
        return (meanX + slopeX * (time - meanT), meanY + slopeY * (time - meanT))
    }

    static func interpolate(_ shakes: [Shake], at time: Double) -> Shake? {
        guard let first = shakes.first, let last = shakes.last else { return nil }
        if time <= first.time { return first }
        if time >= last.time { return last }
        let upper = shakes.partitionPoint { $0.time <= time }
        let a = shakes[upper - 1], b = shakes[upper]
        let span = b.time - a.time
        let f = span > 0 ? (time - a.time) / span : 1
        func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * f }
        return Shake(time: time, x: mix(a.x, b.x), y: mix(a.y, b.y),
                     envelopeX: mix(a.envelopeX, b.envelopeX), envelopeY: mix(a.envelopeY, b.envelopeY),
                     marginX: mix(a.marginX, b.marginX), marginY: mix(a.marginY, b.marginY))
    }

    /// The crop at one moment: shrunk (per axis, keeping `aspect` and the
    /// centre) until it has `margin` room inside `bounds`, moved by `shake`
    /// so the content holds still, and clamped to the frame. All in pixels.
    static func stabilized(crop: CGRect, shake: CGPoint, margin: CGSize, bounds: CGRect,
                           minHeight: Double, aspect: Double) -> CGRect {
        guard crop.width > 0, crop.height > 0, bounds.width > 0, bounds.height > 0 else { return crop }
        // Clearance on the tighter side of each axis; shrinking around the
        // crop's own centre adds half the removed size to both sides.
        let roomX = max(0, min(crop.minX - bounds.minX, bounds.maxX - crop.maxX))
        let roomY = max(0, min(crop.minY - bounds.minY, bounds.maxY - crop.maxY))
        var height = crop.height
        if margin.width > roomX || margin.height > roomY {
            let byWidth = (crop.width - 2 * max(0, margin.width - roomX)) / aspect
            let byHeight = crop.height - 2 * max(0, margin.height - roomY)
            height = min(crop.height, max(minHeight, min(byWidth, byHeight)))
        }
        height = min(height, bounds.height, bounds.width / aspect)
        var result = CGRect(x: crop.midX - height * aspect / 2, y: crop.midY - height / 2,
                            width: height * aspect, height: height)
        result.origin.x += shake.x
        result.origin.y += shake.y
        result.origin.x = min(max(bounds.minX, result.origin.x), bounds.maxX - result.width)
        result.origin.y = min(max(bounds.minY, result.origin.y), bounds.maxY - result.height)
        return result
    }

    /// The extra keyframe times a path needs inside the shaky stretches.
    static func denseTimes(_ profile: Profile, through duration: Double,
                           interval: Double = keyframeInterval) -> [Double] {
        var times: [Double] = []
        for section in profile.sections {
            var time = (section.lowerBound / interval).rounded(.down) * interval
            while time <= min(section.upperBound, duration) + 1e-9 {
                if time >= 0 { times.append(time) }
                time += interval
            }
        }
        return times
    }

    static func summary(_ profile: Profile?, duration: Double, cuts: [Double] = []) -> String {
        let cutNote = cuts.isEmpty ? "" : "; \(cuts.count) shot change\(cuts.count == 1 ? "" : "s") in the source"
        guard let profile else { return "Reduce camera motion: no camera shake above \(Int(threshold * 1000))‰ of the frame" + cutNote }
        let shaky = profile.sections.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        return String(format: "Reduce camera motion: %d shaky stretch%@, %.1f s of %.1f s, shake up to %.1f%% of the frame",
                      profile.sections.count, profile.sections.count == 1 ? "" : "es", shaky, duration, profile.peak * 100) + cutNote
    }
}

private extension Array where Element == Double {
    /// First index whose element does not satisfy `belongsInFirstPartition` (array must be sorted accordingly).
    func partitionPoint(_ belongsInFirstPartition: (Double) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if belongsInFirstPartition(self[mid]) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

private extension Array where Element == CameraMotionPlanning.Shake {
    func partitionPoint(_ belongsInFirstPartition: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if belongsInFirstPartition(self[mid]) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
