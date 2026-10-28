import Foundation
import CoreGraphics
import CoreText

/// Rasterizes a resolved run. Layout, timing and placement remain with each surface.
nonisolated struct TextDecorPainter {
    var scale: CGFloat = 1 // pixels per reference pixel at 1080 wide
    var naturalKerning = false

    static func font(family: String?, size: CGFloat, decor: TextDecor) -> CTFont {
        let d = decor.resolved()
        let family = family == "serif" ? "Times New Roman" : family == "mono" ? "Menlo"
            : family == nil || family == "sans" || family == "" ? "Helvetica Neue" : family!
        var font = CTFontCreateWithName(family as CFString, size, nil)
        if d.weight == "black" {
            let descriptor = CTFontDescriptorCreateWithAttributes([
                kCTFontFamilyNameAttribute: CTFontCopyFamilyName(font),
                kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.62, kCTFontWidthTrait: 0.0],
            ] as CFDictionary)
            font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        } else if d.weight == "bold" {
            font = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
        }
        if d.italic == true {
            if let italic = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) {
                font = italic
            } else {
                var skew = CGAffineTransform(a: 1, b: 0, c: tan(.pi / 15), d: 1, tx: 0, ty: 0)
                font = CTFontCreateWithName(CTFontCopyPostScriptName(font), size, &skew)
            }
        }
        return font
    }

    func line(_ text: String, font: CTFont, decor: TextDecor) -> CTLine {
        let d = decor.resolved()
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): TextColor.cgColor(d.color),
        ]
        if !naturalKerning || d.letterSpacing != 0 {
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = (d.letterSpacing ?? 0) * scale
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    func width(_ text: String, font: CTFont, decor: TextDecor) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font: font, decor: decor), nil, nil, nil))
    }

    func background(in context: CGContext, rect: CGRect, decor: TextDecor, radius: CGFloat? = nil) {
        let d = decor.resolved()
        let radius = radius ?? (d.bgRadius ?? 6) * scale
        if d.bgOn == true {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(TextColor.cgColor(d.bgColor).copy(alpha: d.bgOpacity ?? 1)!)
            context.fillPath()
        }
        if d.borderOn == true {
            let width = (d.borderWidth ?? 2) * scale
            let border = rect.insetBy(dx: -width / 2, dy: -width / 2)
            context.addPath(CGPath(roundedRect: border, cornerWidth: radius + width / 2,
                                   cornerHeight: radius + width / 2, transform: nil))
            context.setStrokeColor(TextColor.cgColor(d.borderColor))
            context.setLineWidth(width)
            context.strokePath()
        }
    }

    /// Text is already cased by the layout pass so measurement and drawing agree.
    func draw(_ text: String, font: CTFont, at origin: CGPoint, decor: TextDecor,
              in context: CGContext, backgroundRect: CGRect? = nil, radius: CGFloat? = nil,
              drawBackground: Bool = true) {
        let d = decor.resolved()
        let size = CTFontGetSize(font)
        let width = width(text, font: font, decor: d)
        let rect = backgroundRect ?? CGRect(x: origin.x, y: origin.y - CTFontGetDescent(font),
            width: width, height: CTFontGetAscent(font) + CTFontGetDescent(font))
            .insetBy(dx: -(d.bgPaddingX ?? 0.125) * size, dy: -(d.bgPaddingY ?? 0.125) * size)
        context.saveGState()
        defer { context.restoreGState() }
        if drawBackground { background(in: context, rect: rect, decor: d, radius: radius) }
        // A transparency layer applies opacity once, including overlapping glyphs/rules.
        let opacity = d.textOpacity ?? 1
        if opacity < 1 { context.setAlpha(opacity); context.beginTransparencyLayer(auxiliaryInfo: nil) }
        let shadowOffset = CGSize(width: (d.shadowX ?? 0) * size, height: (d.shadowY ?? -0.08) * size)
        let shadowColor = TextColor.cgColor(d.shadowColor).copy(alpha: d.shadowOpacity ?? 0.75)!
        if d.shadowOn == true, d.shadowStyle == "soft" {
            context.setShadow(offset: shadowOffset, blur: (d.shadowBlur ?? 0.15) * size, color: shadowColor)
        }
        let stroke = d.strokeOn == true ? (d.strokeWidth ?? 1) * scale : 0
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): (d.letterSpacing ?? 0) * scale,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): TextColor.cgColor(d.color),
        ]
        if naturalKerning && d.letterSpacing == 0 {
            attributes.removeValue(forKey: NSAttributedString.Key(kCTKernAttributeName as String))
        }
        if stroke > 0 {
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = TextColor.cgColor(d.strokeColor).copy(alpha: d.strokeOpacity ?? 0.86)
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -100 * stroke / size
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textMatrix = .identity
        context.textPosition = origin
        let thickness = d.underlineThickness.map { $0 * size } ?? max(1, CTFontGetUnderlineThickness(font))
        var rules: [CGRect] = []
        if d.underline == true {
            rules.append(CGRect(x: origin.x, y: origin.y + CTFontGetUnderlinePosition(font), width: width, height: thickness))
        }
        if d.strikethrough == true {
            rules.append(CGRect(x: origin.x, y: origin.y + CTFontGetXHeight(font) / 2, width: width, height: max(1, CTFontGetUnderlineThickness(font))))
        }
        if d.shadowOn == true, d.shadowStyle != "soft" {
            // Hard: one sharp copy at the offset. Extrude: copies from the
            // offset back to the text, one pixel apart, so the letters look
            // like solid blocks. Colour glyphs (emoji) have no outline path
            // and cast nothing, matching the gradient fill behaviour.
            let silhouette = CGMutablePath()
            silhouette.addPath(glyphPath(line, origin: origin))
            for rect in rules { silhouette.addRect(rect) }
            hardShadow(silhouette, offset: shadowOffset, color: shadowColor, stroke: stroke,
                       strokeOpacity: d.strokeOpacity ?? 0.86, extrude: d.shadowStyle == "extrude", in: context)
        }
        if let end = d.fillEndColor {
            let path = glyphPath(line, origin: origin)
            // Draw the normal run first: colour glyphs (emoji) have no outline
            // path and retain their original bitmap while text gets the gradient.
            CTLineDraw(line, context)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.saveGState()
            context.addPath(path); context.clip()
            gradient(in: context, rect: path.boundingBoxOfPath, start: d.color, end: end, angle: d.fillAngle ?? 0)
            context.restoreGState()
        } else {
            // Keep CoreText's fast colour-glyph path for flat fills (including emoji).
            CTLineDraw(line, context)
        }
        if stroke > 0 {
            context.setStrokeColor(TextColor.cgColor(d.strokeColor).copy(alpha: d.strokeOpacity ?? 0.86)!)
            context.setLineWidth(stroke * 2)
            for rect in rules { context.stroke(rect) }
        }
        for (index, rect) in rules.enumerated() {
            context.setFillColor(TextColor.cgColor(index == 0 && d.underline == true ? d.underlineColor ?? d.color : d.color))
            context.fill(rect)
            if let end = d.fillEndColor, d.underlineColor == nil {
                context.saveGState(); context.clip(to: rect)
                gradient(in: context, rect: CGRect(x: origin.x, y: origin.y, width: width, height: size),
                         start: d.color, end: end, angle: d.fillAngle ?? 0)
                context.restoreGState()
            }
        }
        if opacity < 1 { context.endTransparencyLayer() }
    }

    private func hardShadow(_ path: CGPath, offset: CGSize, color: CGColor, stroke: CGFloat,
                            strokeOpacity: Double, extrude: Bool, in context: CGContext) {
        let length = max(abs(offset.width), abs(offset.height))
        guard length > 0 else { return }
        // Group the copies so an opacity below 1 does not darken the overlaps.
        context.saveGState()
        context.setAlpha(color.alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(color.copy(alpha: 1)!)
        // The outline's own opacity decides how much it widens the silhouette.
        context.setStrokeColor(color.copy(alpha: strokeOpacity)!)
        context.setLineWidth(stroke) // CoreText centres its stroke on the outline too
        context.setLineJoin(.round)
        let steps = extrude ? max(1, Int(length.rounded(.up))) : 1
        for step in stride(from: steps, through: 1, by: -1) {
            let fraction = CGFloat(step) / CGFloat(steps)
            let transform = CGAffineTransform(translationX: offset.width * fraction, y: offset.height * fraction)
            var copy = transform
            context.addPath(path.copy(using: &copy) ?? path)
            context.fillPath()
            if stroke > 0 {
                context.addPath(path.copy(using: &copy) ?? path)
                context.strokePath()
            }
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func glyphPath(_ line: CTLine, origin: CGPoint) -> CGPath {
        let result = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var points = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &points)
            for index in 0..<count {
                if let path = CTFontCreatePathForGlyph(font, glyphs[index], nil) {
                    let transform = CGAffineTransform(translationX: origin.x + points[index].x, y: origin.y + points[index].y)
                    result.addPath(path, transform: transform)
                }
            }
        }
        return result
    }

    private func gradient(in context: CGContext, rect: CGRect, start: String?, end: String, angle: Double) {
        let radians = angle * .pi / 180
        let dx = cos(radians), dy = -sin(radians) // 90 degrees goes top to bottom
        let half = (abs(dx) * rect.width + abs(dy) * rect.height) / 2
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [TextColor.cgColor(start), TextColor.cgColor(end)] as CFArray, locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient,
            start: CGPoint(x: rect.midX - dx * half, y: rect.midY - dy * half),
            end: CGPoint(x: rect.midX + dx * half, y: rect.midY + dy * half),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
