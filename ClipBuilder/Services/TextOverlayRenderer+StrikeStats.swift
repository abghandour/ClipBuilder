import CoreGraphics
import CoreText
import Foundation

nonisolated extension TextOverlayRenderer {
    func drawStrikeStats(in context: CGContext, item: TextOverlayItem) {
        guard let payload = item.stat else { return }
        let decor = item.resolvedTextDecor
        let painter = TextDecorPainter(scale: CGFloat(videoWidth) / 1080, naturalKerning: true)
        let lines = StrikeStatsCopy.lines(payload).map { TextCasing.apply($0, casing: decor.casing) }
        let scale = CGFloat(videoHeight) / 1920
        let width = CGFloat(videoWidth) * min(0.9, item.wFrac ?? 0.86, decor.maxWidthFrac ?? 1)
        let padding = item.decor?.bgPaddingX.map { CGFloat(item.fontsize) * scale * $0 } ?? 24 * scale
        let paddingY = item.decor?.bgPaddingY.map { CGFloat(item.fontsize) * scale * $0 } ?? 24 * scale
        var size = CGFloat(max(22, item.fontsize)) * scale
        // Preserve full numerator/denominator and qualifications; fit rather than truncate.
        while size > 10 * scale {
            let font = TextDecorPainter.font(family: item.fontfamily, size: size, decor: decor)
            if lines.allSatisfy({ painter.width($0, font: font, decor: decor) <= width - padding * 2 }) { break }
            size -= scale
        }
        let rowHeight = size * 1.5
        let height = rowHeight * CGFloat(lines.count) + paddingY * 2
        let center = safeArea?.clampedCenter(x: item.xFrac ?? 0.5, y: item.yFrac ?? 0.55,
                                             width: Double(width) / Double(videoWidth),
                                             height: Double(height) / Double(videoHeight))
        let x = CGFloat(center?.x ?? item.xFrac ?? 0.5) * CGFloat(videoWidth) - width / 2
        let y = CGFloat(1 - (center?.y ?? item.yFrac ?? 0.55)) * CGFloat(videoHeight) - height / 2
        let box = CGRect(x: x, y: y, width: width, height: height)
        if decor.bgPerLine != true {
            painter.background(in: context, rect: box, decor: decor,
                               radius: item.decor == nil ? CGFloat(item.boxRadius ?? 12) * scale : nil)
        }
        for (index, text) in lines.enumerated() {
            var rowDecor = decor
            if index == 0 && item.decor?.weight == nil { rowDecor.weight = "bold" }
            let font = TextDecorPainter.font(family: item.fontfamily, size: size, decor: rowDecor)
            let textWidth = painter.width(text, font: font, decor: rowDecor)
            let alignment = item.decor == nil ? "left" : item.alignment
            let origin = CGPoint(x: Self.alignedX(boxLeft: x + padding, boxWidth: width - padding * 2,
                lineWidth: textWidth, alignment: alignment),
                y: y + height - paddingY - size - CGFloat(index) * rowHeight)
            painter.draw(text, font: font, at: origin, decor: rowDecor, in: context,
                         drawBackground: decor.bgPerLine == true)
        }
    }
}
