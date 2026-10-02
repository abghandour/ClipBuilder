import Foundation

/// Source-time calculations shared by proposed-cut controls and their tests.
nonisolated enum ProposedCutTrim {
    static let minimumSpan = 0.5

    nonisolated struct Window: Equatable {
        var start: Double
        var span: Double

        var end: Double { start + span }
        var rulerInterval: Double { span > 90 ? 10 : 5 }
        var minimumSpan: Double { min(ProposedCutTrim.minimumSpan, span) }

        func needsRecentering(_ range: ClosedRange<Double>) -> Bool {
            let margin = span * 0.05
            return range.lowerBound <= start + margin || range.upperBound >= end - margin
        }

        func playheadX(at time: Double, width: Double) -> Double? {
            guard span > 0, time >= start, time <= end else { return nil }
            return width * (time - start) / span - 1
        }
    }

    static func clamp(start: Double, end: Double, scene: ClosedRange<Double>) -> ClosedRange<Double> {
        // A scene shorter than the minimum can only offer its full duration.
        let span = min(minimumSpan, duration(scene))
        let lower = min(max(scene.lowerBound, start), scene.upperBound - span)
        let upper = min(scene.upperBound, max(lower + span, end))
        return lower...upper
    }

    static func window(for range: ClosedRange<Double>, scene: ClosedRange<Double>) -> Window {
        let range = clamp(start: range.lowerBound, end: range.upperBound, scene: scene)
        // Keep long cuts visible in full, with up to twenty seconds on either side.
        let span = min(duration(scene), max(30, duration(range) + 40))
        let start = min(max(scene.lowerBound, midpoint(range) - span / 2), scene.upperBound - span)
        return Window(start: start, span: span)
    }

    static func settingStart(at time: Double, in range: ClosedRange<Double>,
                             scene: ClosedRange<Double>) -> ClosedRange<Double> {
        clamp(start: time, end: max(time + minimumSpan, range.upperBound), scene: scene)
    }

    static func settingEnd(at time: Double, in range: ClosedRange<Double>,
                           scene: ClosedRange<Double>) -> ClosedRange<Double> {
        clamp(start: min(range.lowerBound, time - minimumSpan), end: time, scene: scene)
    }

    static func differs(_ range: ClosedRange<Double>, proposedStart: Double, proposedEnd: Double) -> Bool {
        abs(range.lowerBound - proposedStart) > 0.001 || abs(range.upperBound - proposedEnd) > 0.001
    }

    static func duration(_ range: ClosedRange<Double>) -> Double { range.upperBound - range.lowerBound }

    static func midpoint(_ range: ClosedRange<Double>) -> Double { range.lowerBound + duration(range) / 2 }

    static func range(start: Double, end: Double) -> ClosedRange<Double> { start...max(start, end) }

    static func timecode(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}
