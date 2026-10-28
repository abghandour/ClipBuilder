import Foundation

/// The speeds a trim surface can play at, and the one the user last chose.
nonisolated enum PlaybackSpeed {
    static let range: ClosedRange<Double> = 0.25...3
    static let step = 0.25
    static let key = "playback.trimSpeed"
    /// The choices in the speed menu beside the slider.
    static let presets: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    /// The speedometer needle sits low for slow speeds and high for fast ones.
    static func symbol(_ rate: Double) -> String {
        switch rate {
        case ..<1: "gauge.with.dots.needle.0percent"
        case 1: "gauge.with.dots.needle.33percent"
        case ..<2: "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.100percent"
        }
    }

    static func label(_ rate: Double) -> String {
        let text = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
        return text + "×"
    }

    /// `rate` on the slider's quarter-speed stops, inside its range; anything
    /// unusable is normal speed.
    static func nearest(_ rate: Double) -> Double {
        guard rate.isFinite, rate > 0 else { return 1 }
        let snapped = (rate / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    static func stored(_ defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: key) == nil ? 1 : nearest(defaults.double(forKey: key))
    }

    static func store(_ rate: Double, _ defaults: UserDefaults = .standard) {
        defaults.set(nearest(rate), forKey: key)
    }
}
