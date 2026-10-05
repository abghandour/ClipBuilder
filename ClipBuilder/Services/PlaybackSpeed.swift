import Foundation

/// The speeds a trim surface can play at, and the one the user last chose.
nonisolated enum PlaybackSpeed {
    static let range: ClosedRange<Double> = 0.25...3
    static let step = 0.25
    static let key = "playback.trimSpeed"

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
