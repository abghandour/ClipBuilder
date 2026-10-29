import Foundation
import CoreGraphics

/// Pad coordinates use a top-left origin; renderer shadow Y points upwards.
nonisolated enum ShadowOffsetMapping {
    static func position(x: Double, y: Double, side: Double = 44) -> CGPoint {
        CGPoint(x: (clamp(x) + 3) / 6 * side, y: (3 - clamp(y)) / 6 * side)
    }
    static func offset(at point: CGPoint, side: Double = 44) -> CGPoint {
        guard side > 0 else { return .zero }
        return CGPoint(x: clamp(point.x / side * 6 - 3), y: clamp(3 - point.y / side * 6))
    }
    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(3, max(-3, value)) : 0 }
}
