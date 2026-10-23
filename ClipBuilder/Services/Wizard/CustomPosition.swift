import CoreGraphics
import Foundation

/// A position the user chose by dragging an element in the preview: the
/// element's centre as fractions of the canvas, stored in the same string
/// setting as the named choices ("bottom", "topTrailing", …) as
/// `custom:<x>,<y>`, so it travels with presets, memory and provenance
/// without new fields.
nonisolated struct CustomPosition: Hashable, Sendable {
    static let prefix = "custom:"

    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = min(1, max(0, x.isFinite ? x : 0.5))
        self.y = min(1, max(0, y.isFinite ? y : 0.5))
    }

    /// nil for nil, named choices and malformed strings.
    init?(_ string: String?) {
        guard let string, string.hasPrefix(Self.prefix) else { return nil }
        let parts = string.dropFirst(Self.prefix.count).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)), x.isFinite, y.isFinite else { return nil }
        self.init(x: x, y: y)
    }

    static func isCustom(_ string: String?) -> Bool { CustomPosition(string) != nil }

    var string: String { String(format: "%@%.4f,%.4f", Self.prefix, x, y) }

    var point: CGPoint { CGPoint(x: x, y: y) }

    /// The top-left origin of a box of `size` centred on this position
    /// inside `bounds`, pushed inside when it would cross an edge (a box
    /// larger than the bounds is centred on them).
    func origin(size: CGSize, in bounds: CGRect) -> CGPoint {
        let canvasX = bounds.minX + x * bounds.width, canvasY = bounds.minY + y * bounds.height
        return Self.origin(center: CGPoint(x: canvasX, y: canvasY), size: size, in: bounds)
    }

    /// The same clamp for a centre already in `bounds` coordinates.
    static func origin(center: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            upper < lower ? (lower + upper) / 2 : min(upper, max(lower, value))
        }
        return CGPoint(x: clamp(center.x - size.width / 2, bounds.minX, bounds.maxX - size.width),
                       y: clamp(center.y - size.height / 2, bounds.minY, bounds.maxY - size.height))
    }
}
