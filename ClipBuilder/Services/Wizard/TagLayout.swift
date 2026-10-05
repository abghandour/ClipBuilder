import Foundation
import CoreGraphics

/// Tag-local geometry, with a top-left origin. Images are relative to the
/// padded text block, and the union is what the placement planner fits.
nonisolated enum TagLayout {
    struct Line: Sendable {
        var size: CGSize
        var underlineThickness: CGFloat = 0
    }
    struct Result: Sendable {
        var textBlock: CGRect
        var origins: [CGPoint]
        var underlines: [CGRect?]
        var images: [UUID: CGRect]
        var bounds: CGRect
    }

    static func layout(lines: [Line], padding: CGFloat, gap: CGFloat,
                       alignment: String, images: [TagImage], aspects: [UUID: CGFloat]) -> Result {
        let width = (lines.map(\.size.width).max() ?? 0) + padding * 2
        let height = lines.reduce(CGFloat.zero) { $0 + $1.size.height + $1.underlineThickness * 2 }
            + gap * CGFloat(max(0, lines.count - 1)) + padding * 2
        let block = CGRect(x: 0, y: 0, width: width, height: height)
        var top = padding
        var origins: [CGPoint] = []
        var underlines: [CGRect?] = []
        for line in lines {
            let x = alignment == "center" ? (width - line.size.width) / 2
                : alignment == "trailing" ? width - padding - line.size.width : padding
            origins.append(CGPoint(x: x, y: top))
            underlines.append(line.underlineThickness > 0
                ? CGRect(x: x, y: top + line.size.height + line.underlineThickness,
                         width: line.size.width, height: line.underlineThickness) : nil)
            top += line.size.height + line.underlineThickness * 2 + gap
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
        return Result(textBlock: block, origins: origins, underlines: underlines, images: rects, bounds: bounds)
    }
}
