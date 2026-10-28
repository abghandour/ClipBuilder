import Foundation

/// The focus-frame Zoom slider: 1× is the frame at its largest (its longer side
/// spans the source), larger values shrink it around its own centre. Source
/// fractions only; the preview's wheel and pinch zoom work in preview points.
nonisolated enum FocusFrameZoom {
    static let range: ClosedRange<Double> = 1...4
    /// The smaller side never drops below this fraction of the source.
    static let minimumSide = 0.05

    /// How far `frame` is zoomed in; nil (full source at the current shape) reads 1×.
    static func zoom(_ frame: FreeCropRect?) -> Double {
        guard let frame else { return range.lowerBound }
        let span = max(frame.wFrac, frame.hFrac)
        guard span.isFinite, span > 0 else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, 1 / span))
    }

    /// `current` (or `base` when nothing is stored) scaled uniformly so its longer
    /// side spans 1/zoom of the source, kept centred and inside the source. nil
    /// when the result is the base frame again, so the row reads "Full source".
    static func frame(zoom: Double, current: FreeCropRect?, base: FreeCropRect) -> FreeCropRect? {
        let start = current ?? base
        let clamped = min(range.upperBound, max(range.lowerBound, zoom.isFinite ? zoom : range.lowerBound))
        let span = max(start.wFrac, start.hFrac)
        guard span.isFinite, span > 0, start.wFrac > 0, start.hFrac > 0 else { return current }
        var factor = (1 / clamped) / span
        let shorter = min(start.wFrac, start.hFrac) * factor
        if shorter < minimumSide { factor = minimumSide / min(start.wFrac, start.hFrac) }
        let width = min(1, start.wFrac * factor)
        let height = min(1, start.hFrac * factor)
        let x = min(1 - width, max(0, start.xFrac + start.wFrac / 2 - width / 2))
        let y = min(1 - height, max(0, start.yFrac + start.hFrac / 2 - height / 2))
        let result = FreeCropRect(xFrac: x, yFrac: y, wFrac: width, hFrac: height)
        return matches(result, base) ? nil : result
    }

    private static func matches(_ a: FreeCropRect, _ b: FreeCropRect) -> Bool {
        abs(a.xFrac - b.xFrac) < 0.0005 && abs(a.yFrac - b.yFrac) < 0.0005
            && abs(a.wFrac - b.wFrac) < 0.0005 && abs(a.hFrac - b.hFrac) < 0.0005
    }
}
