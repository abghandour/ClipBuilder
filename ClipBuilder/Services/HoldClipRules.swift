import Foundation

/// Screen-time edits and camera sampling for a single held source frame.
nonisolated enum HoldClipRules {
    static func duration(_ requested: Double, precision: TimelinePrecision) -> Double {
        min(5, max(precision.minimumDuration, requested))
    }

    /// Keep two equal positions so consumers that require a path can use it.
    static func cameraPath(_ path: [CameraPathKeyframe], at time: Double = 0,
                           duration: Double) -> [CameraPathKeyframe] {
        guard var first = CenterStageService.interpolated(path, at: time) else { return [] }
        first.t = 0
        var last = first
        last.t = max(1.0 / 30, duration)
        return [first, last]
    }
}
