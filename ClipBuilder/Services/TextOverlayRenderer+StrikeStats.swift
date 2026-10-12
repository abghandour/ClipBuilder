import CoreGraphics
import CoreText
import Foundation

nonisolated extension TextOverlayRenderer {
    func drawStrikeStats(in context: CGContext, item: TextOverlayItem) {
        guard let payload = item.stat else { return }
        let lines = StrikeStatsCopy.lines(payload)
        let scale = CGFloat(videoHeight) / 1920
        let width = CGFloat(videoWidth) * min(0.9, item.wFrac ?? 0.86)
        let padding = 24 * scale
        var size = CGFloat(max(22, item.fontsize)) * scale
        // Preserve full numerator/denominator and qualifications; fit rather than truncate.
        while size > 10 * scale {
            let font = resolveFont(size: size, family: item.fontfamily, bold: false, italic: false)
            if lines.allSatisfy({ lineWidth($0, font: font) <= width - padding * 2 }) { break }
            size -= scale
        }
        let rowHeight = size * 1.5
        let height = rowHeight * CGFloat(lines.count) + padding * 2
        let center = safeArea?.clampedCenter(x: item.xFrac ?? 0.5, y: item.yFrac ?? 0.55,
                                             width: Double(width) / Double(videoWidth),
                                             height: Double(height) / Double(videoHeight))
        let x = CGFloat(center?.x ?? item.xFrac ?? 0.5) * CGFloat(videoWidth) - width / 2
        let y = CGFloat(1 - (center?.y ?? item.yFrac ?? 0.55)) * CGFloat(videoHeight) - height / 2
        let box = CGRect(x: x, y: y, width: width, height: height)
        let background = Self.parseColor(item.bgcolor, fallback: (0.05, 0.05, 0.05))
        context.setFillColor(CGColor(red: background.r, green: background.g, blue: background.b,
                                    alpha: item.boxOpacity))
        let radius = CGFloat(item.boxRadius ?? 12) * scale
        context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        let color = Self.parseColor(item.fontcolor)
        for (index, text) in lines.enumerated() {
            let font = resolveFont(size: size, family: item.fontfamily, bold: index == 0 || item.bold, italic: item.italic)
            context.setFillColor(CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1))
            context.textPosition = CGPoint(x: x + padding, y: y + height - padding - size - CGFloat(index) * rowHeight)
            CTLineDraw(line(text, font: font), context)
        }
    }
}
