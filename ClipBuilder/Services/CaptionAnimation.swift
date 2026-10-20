import CoreGraphics
import Foundation

nonisolated enum CaptionAnimation {
    struct Frame: Hashable, Sendable {
        var scale: CGFloat = 1
        var offsetY: CGFloat = 0
        var alpha: CGFloat = 1
        var at: Double = 0
    }

    static func duration(for style: String) -> Double {
        style == "pop" ? 0.18 : (["slide-up", "fade"].contains(style) ? 0.16 : 0)
    }

    /// `duration` is the requested entrance length, already bounded by the
    /// first state's window. The identity endpoint starts the steady PNG.
    static func frames(for style: String, duration: Double) -> [Frame] {
        guard duration.isFinite, duration > 0 else { return [Frame()] }
        switch style {
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
