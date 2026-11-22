import CoreGraphics
import Foundation

/// Draws a strike highlight: a translucent green band along the attacking
/// limb and a red ring where it lands. One painter for the player overlay
/// and for anything that later burns the highlight into a render.
nonisolated enum StrikeHighlightPainter {
    /// The attacking limb.
    static let limbColor = (red: CGFloat(0.15), green: CGFloat(1.0), blue: CGFloat(0.35))
    /// Where the strike lands.
    static let impactColor = (red: CGFloat(1.0), green: CGFloat(0.16), blue: CGFloat(0.16))

    /// `rect` is where the video frame sits in the context. `topLeftOrigin`
    /// says which way the context's y axis runs (SwiftUI: true; a bitmap
    /// context: false).
    static func draw(_ highlight: StrikeHighlightRules.Highlight, opacity: Double, in context: CGContext,
                     rect: CGRect, topLeftOrigin: Bool) {
        guard opacity > 0, rect.width > 0, rect.height > 0 else { return }
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * rect.width,
                    y: topLeftOrigin ? rect.minY + point.y * rect.height : rect.maxY - point.y * rect.height)
        }
        func green(_ alpha: CGFloat) -> CGColor {
            CGColor(srgbRed: limbColor.red, green: limbColor.green, blue: limbColor.blue, alpha: alpha * CGFloat(opacity))
        }
        func red(_ alpha: CGFloat) -> CGColor {
            CGColor(srgbRed: impactColor.red, green: impactColor.green, blue: impactColor.blue, alpha: alpha * CGFloat(opacity))
        }
        let radius = max(8, highlight.radius * rect.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.setShadow(offset: .zero, blur: radius * 0.5, color: green(0.9))

        if let contour = highlight.contour, let first = contour.first, contour.count >= 3 {
            context.beginPath()
            context.move(to: place(first))
            for point in contour.dropFirst() { context.addLine(to: place(point)) }
            context.closePath()
            context.setFillColor(green(0.35))
            context.setStrokeColor(green(0.9))
            context.setLineWidth(max(1.5, radius * 0.08))
            context.setLineJoin(.round)
            context.drawPath(using: .fillStroke)
        } else if let first = highlight.limb.first, highlight.limb.count >= 2 {
            context.beginPath()
            context.move(to: place(first))
            for point in highlight.limb.dropFirst() { context.addLine(to: place(point)) }
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(radius * 0.8)
            context.setStrokeColor(green(0.45))
            context.strokePath()
        }

        let center = place(highlight.target)
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.setShadow(offset: .zero, blur: radius * 0.5, color: red(0.9))
        context.setFillColor(red(0.3))
        context.fillEllipse(in: circle)
        context.setLineWidth(max(2, radius * 0.12))
        context.setStrokeColor(red(0.95))
        context.strokeEllipse(in: circle)
    }

    /// The aspect-fit rectangle of a `aspect` (width over height) video in `size`.
    static func videoRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}
