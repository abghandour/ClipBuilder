import CoreGraphics
import Foundation

nonisolated enum CaptionAnimation {
    struct Frame: Hashable, Sendable {
        var scale: CGFloat = 1
        var offsetY: CGFloat = 0
        var alpha: CGFloat = 1
        var at: Double = 0
        /// Nil preserves whole-page animation and visibility. Fixed reveals
        /// carry these through every renderer and the raster cache together.
        var visibleWords: Int?
        var wordIndex: Int?
        /// Word index to how far its Glow shadow has grown, 0...1. A word
        /// that is not listed has its full glow.
        var glow: [Int: Double] = [:]
    }

    /// Glow steps at the output frame rate: the times, after the word is
    /// released, at which each next share of the glow starts.
    static func glowSteps(duration: Double, fps: Double = 30) -> [(at: Double, progress: Double)] {
        guard duration.isFinite, duration > 0 else { return [] }
        let count = max(1, Int((duration * fps).rounded()))
        return (0..<count).map { (Double($0) / fps, Double($0 + 1) / Double(count + 1)) }
    }

    /// Cuts the overlays of one page so an emphasis word has no glow until
    /// `release`, then grows it over `duration`, and has it in full after.
    static func growingGlow(_ overlays: [CaptionOverlayPlan.Overlay], word: Int, release: Double,
                            duration: Double) -> [CaptionOverlayPlan.Overlay] {
        let steps = glowSteps(duration: duration)
        guard !steps.isEmpty else { return overlays }
        // Boundaries: nothing before release, each step, full from the end.
        var marks: [(start: Double, progress: Double?)] = [(-.infinity, 0)]
        marks += steps.map { (release + $0.at, $0.progress) }
        marks.append((release + duration, nil))
        return overlays.flatMap { overlay -> [CaptionOverlayPlan.Overlay] in
            guard overlay.raster.emphasis.contains(word),
                  overlay.raster.frame.visibleWords.map({ word < $0 }) ?? true else { return [overlay] }
            return marks.indices.compactMap { index in
                let start = max(overlay.start, marks[index].start)
                let end = min(overlay.end, index + 1 < marks.count ? marks[index + 1].start : .infinity)
                guard end > start + 0.000_001 else { return nil }
                var piece = overlay
                piece.start = start
                piece.end = end
                if let progress = marks[index].progress { piece.raster.frame.glow[word] = progress }
                return piece
            }
        }
    }

    static func duration(for style: String) -> Double {
        if style == "soft-fade" { return 0.1 }
        return ["pop", "bounce"].contains(style) ? 0.18 : (["slide-up", "fade"].contains(style) ? 0.16 : 0)
    }

    /// Reserve the same raster envelope throughout an entrance, including its overshoot.
    static func maximumScale(for style: String) -> Double {
        switch style {
        case "pop": 1.08
        case "bounce": 1.12
        default: 1
        }
    }

    /// `duration` is the requested entrance length, already bounded by the
    /// first state's window. The identity endpoint starts the steady PNG.
    static func frames(for style: String, duration: Double) -> [Frame] {
        guard duration.isFinite, duration > 0 else { return [Frame()] }
        switch style {
        case "soft-fade":
            // Three 30-fps intervals, sampled from a short linear entrance.
            // Opacity-only approximation: the source does not isolate subtle
            // blur from compression and the moving background.
            return [0.13, 0.49, 0.83, 1].enumerated().map {
                Frame(alpha: $0.element, at: Double($0.offset) / 3 * duration)
            }
        case "bounce":
            // A damped spring: compress, overshoot, then settle on both sides of identity.
            return zip([0.72, 1.12, 0.95, 1.025, 0.992, 1.003, 1.0],
                       [0.0, 0.25, 0.45, 0.65, 0.8, 0.9, 1.0]).map {
                Frame(scale: $0, at: $1 * duration)
            }
        case "pop":
            return zip([0.85, 0.98, 1.08, 1.03, 1.0], [0.0, 0.25, 0.5, 0.75, 1.0]).map {
                Frame(scale: $0, at: $1 * duration)
            }
        case "slide-up":
            return (0...4).map {
                let progress = Double($0) / 4
                return Frame(offsetY: 24 * (1 - progress), at: progress * duration)
            }
        case "fade":
            return (0...4).map {
                let progress = Double($0) / 4
                return Frame(alpha: progress, at: progress * duration)
            }
        default: return [Frame()]
        }
    }
}
