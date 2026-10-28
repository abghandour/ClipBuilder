import Foundation
import CoreGraphics

/// Tag-local geometry, with a top-left origin. Images are relative to the
/// padded text block, and the union is what the placement planner fits.
nonisolated enum TagLayout {
    struct Line: Sendable {
        var size: CGSize
        var underlineThickness: CGFloat = 0
        var strikethrough: CGFloat = 0
        var chipPadding: CGFloat = 0
        var chipPaddingY: CGFloat?
        /// Top-relative half x-height position, when font metrics are available.
        var strikethroughY: CGFloat?
    }
    struct Result: Sendable {
        var textBlock: CGRect
        var origins: [CGPoint]
        var underlines: [CGRect?]
        var chips: [CGRect?]
        var strikethroughs: [CGRect?]
        var images: [UUID: CGRect]
        var bounds: CGRect
    }

    static func layout(lines: [Line], padding: CGFloat, gap: CGFloat,
                       alignment: String, images: [TagImage], aspects: [UUID: CGFloat], paddingY: CGFloat? = nil) -> Result {
        let paddingY = paddingY ?? padding
        let width = (lines.map { $0.size.width + max(0, $0.chipPadding) * 2 }.max() ?? 0) + padding * 2
        let height = lines.reduce(CGFloat.zero) { $0 + $1.size.height + $1.underlineThickness * 2 + max(0, $1.chipPaddingY ?? $1.chipPadding) * 2 }
            + gap * CGFloat(max(0, lines.count - 1)) + paddingY * 2
        let block = CGRect(x: 0, y: 0, width: width, height: height)
        var top = paddingY
        var origins: [CGPoint] = []
        var underlines: [CGRect?] = []
        var chips: [CGRect?] = []
        var strikethroughs: [CGRect?] = []
        for line in lines {
            let chipPadding = max(0, line.chipPadding)
            let chipPaddingY = max(0, line.chipPaddingY ?? line.chipPadding)
            top += chipPaddingY
            let x = alignment == "center" ? (width - line.size.width) / 2
                : alignment == "trailing" ? width - padding - chipPadding - line.size.width : padding + chipPadding
            origins.append(CGPoint(x: x, y: top))
            underlines.append(line.underlineThickness > 0
                ? CGRect(x: x, y: top + line.size.height + line.underlineThickness,
                         width: line.size.width, height: line.underlineThickness) : nil)
            chips.append(chipPadding > 0
                ? CGRect(x: x - chipPadding, y: top - chipPaddingY, width: line.size.width + chipPadding * 2,
                         height: line.size.height + line.underlineThickness * 2 + chipPaddingY * 2) : nil)
            strikethroughs.append(line.strikethrough > 0
                ? CGRect(x: x, y: top + (line.strikethroughY ?? line.size.height / 2),
                         width: line.size.width, height: line.strikethrough) : nil)
            top += line.size.height + line.underlineThickness * 2 + chipPaddingY + gap
        }
        var rects: [UUID: CGRect] = [:]
        var bounds = block
        for image in images {
            guard let aspect = aspects[image.id], aspect > 0, aspect.isFinite else { continue }
            let w = max(0, image.width) * width
            let h = w / aspect
            let rect = CGRect(x: image.x * width - w / 2, y: image.y * height - h / 2, width: w, height: h)
            rects[image.id] = rect
            bounds = bounds.union(rect)
        }
        return Result(textBlock: block, origins: origins, underlines: underlines, chips: chips, strikethroughs: strikethroughs, images: rects, bounds: bounds)
    }
}
