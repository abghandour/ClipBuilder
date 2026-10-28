import Foundation
import CoreGraphics
import CoreText
import ImageIO
import OSLog

nonisolated extension TextOverlayRenderer {
    @concurrent
    static func tagImageAspects(_ style: TagStyle) async -> [UUID: CGFloat] {
        tagImages(style).mapValues { CGFloat($0.width) / CGFloat($0.height) }
    }

    /// Called by the render worker or the detached preview worker.
    static func tagImages(_ style: TagStyle) -> [UUID: CGImage] {
        var images: [UUID: CGImage] = [:]
        for item in style.images {
            let url = URL(fileURLWithPath: (item.path as NSString).expandingTildeInPath)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                  ] as CFDictionary) else {
                Logger(subsystem: "ClipBuilder", category: "Tags").warning("Skipping unavailable tag image: \(item.path, privacy: .public)")
                continue
            }
            images[item.id] = image
        }
        return images
    }

    func styledNameTagLayout(_ item: TextOverlayItem, style: TagStyle, maxWidth: CGFloat,
                             aspects: [UUID: CGFloat]) -> NameTagLayout {
        let style = style.applyingSharedStyle(textStyles)
        let styles = [style.name, style.description]
        var lines = Array(item.text.components(separatedBy: "\n").prefix(2)).enumerated().map {
            TextCasing.apply($0.element, casing: styles[$0.offset].resolvedTextDecor(over: style.lineDecor).casing)
        }
        func measure(_ size: Int) -> NameTagLayout {
            let pixels = CGFloat(size) * CGFloat(videoHeight) / 1920
            let fonts = lines.indices.map {
                let decor = styles[$0].resolvedTextDecor(over: style.lineDecor)
                return TextDecorPainter.font(family: styles[$0].fontOverride ?? styles[$0].font, size: pixels * (decor.size ?? 1), decor: decor)
            }
            let padding = ceil(pixels * (style.boxDecor.bgPaddingX ?? 0.24))
            let paddingY = ceil(pixels * (style.boxDecor.bgPaddingY ?? 0.24))
            let gap = pixels * (0.12 + ((style.lineDecor.lineHeight ?? 1) - 1))
            let geometry = TagLayout.layout(lines: lines.indices.map {
                TagLayout.Line(size: CGSize(width: TextDecorPainter(scale: CGFloat(videoWidth) / 1080, naturalKerning: true).width(lines[$0], font: fonts[$0], decor: styles[$0].resolvedTextDecor(over: style.lineDecor)),
                    height: (CTFontGetAscent(fonts[$0]) + CTFontGetDescent(fonts[$0])) * (styles[$0].resolvedTextDecor(over: style.lineDecor).lineHeight ?? 1)),
                    underlineThickness: styles[$0].underline
                        ? CTFontGetSize(fonts[$0]) * max(0, styles[$0].underlineThickness) : 0,
                    strikethrough: styles[$0].resolvedStrikethrough ? max(1, CTFontGetUnderlineThickness(fonts[$0])) : 0,
                    chipPadding: styles[$0].resolvedTextDecor(over: style.lineDecor).bgOn == true
                        ? CTFontGetSize(fonts[$0]) * (styles[$0].resolvedTextDecor(over: style.lineDecor).bgPaddingX ?? 0.18) : 0,
                    chipPaddingY: styles[$0].resolvedTextDecor(over: style.lineDecor).bgOn == true
                        ? CTFontGetSize(fonts[$0]) * (styles[$0].resolvedTextDecor(over: style.lineDecor).bgPaddingY ?? 0.18) : 0,
                    strikethroughY: CTFontGetAscent(fonts[$0]) - CTFontGetXHeight(fonts[$0]) / 2)
            }, padding: padding, gap: gap, alignment: style.boxDecor.alignment ?? style.alignment, images: style.images, aspects: aspects, paddingY: paddingY)
            return NameTagLayout(fontSize: size, lines: lines, fonts: fonts,
                size: geometry.bounds.size, padding: padding, lineGap: gap, geometry: geometry)
        }
        let cap = min(style.boxDecor.maxWidthFrac ?? 1, styles.map { $0.resolvedTextDecor(over: style.lineDecor).maxWidthFrac ?? 1 }.min() ?? 1)
        let maxWidth = min(maxWidth, cap * CGFloat(videoWidth))
        var size = max(22, item.fontsize)
        var result = measure(size)
        while size > 22 && result.size.width > maxWidth {
            size -= 1
            result = measure(size)
        }
        if result.size.width > maxWidth {
            let originals = lines
            var limit = lines.map(\.count).max() ?? 0
            while result.size.width > maxWidth && limit > 0 {
                limit -= 1
                lines = originals.map { $0.count > limit ? String($0.prefix(limit)) + "…" : $0 }
                result = measure(size)
            }
        }
        return result
    }

    func drawStyledNameTag(in context: CGContext, item: TextOverlayItem, style: TagStyle) {
        context.saveGState()
        defer { context.restoreGState() }
        let box = item.normalizedBox
        let rect = CGRect(x: box.minX * Double(videoWidth), y: box.minY * Double(videoHeight),
                          width: box.width * Double(videoWidth), height: box.height * Double(videoHeight))
        guard rect.width > 0, rect.height > 0 else { return }
        let images = Self.tagImages(style)
        let layout = styledNameTagLayout(item, style: style, maxWidth: .greatestFiniteMagnitude,
            aspects: images.mapValues { CGFloat($0.width) / CGFloat($0.height) })
        guard let geometry = layout.geometry else { return }
        let fit = min(1, rect.width / max(1, layout.size.width), rect.height / max(1, layout.size.height))
        let offset = CGPoint(x: rect.minX - geometry.bounds.minX * fit,
                             y: rect.minY - geometry.bounds.minY * fit)
        func cgRect(_ local: CGRect) -> CGRect {
            CGRect(x: offset.x + local.minX * fit, y: CGFloat(videoHeight) - offset.y - local.maxY * fit,
                   width: local.width * fit, height: local.height * fit)
        }
        func drawImages(behind: Bool) {
            for image in style.images where image.behindText == behind {
                guard let cgImage = images[image.id], let local = geometry.images[image.id] else { continue }
                context.saveGState()
                context.setAlpha(min(1, max(0, image.opacity)))
                context.draw(cgImage, in: cgRect(local))
                context.restoreGState()
            }
        }
        let painter = TextDecorPainter(scale: CGFloat(videoWidth) / 1080 * fit, naturalKerning: true)
        let boxDecor = style.boxDecor
        if boxDecor.bgPerLine != true {
            painter.background(in: context, rect: cgRect(geometry.textBlock), decor: boxDecor,
                               radius: style.decor == nil ? style.cornerRadius * Double(videoHeight) / 1920 * fit : nil)
        }
        drawImages(behind: true)
        let styles = [style.name, style.description]
        for index in layout.lines.indices {
            if styles[index].decor == nil && style.decor == nil, let chip = geometry.chips[index] {
                context.saveGState()
                context.setFillColor(Self.cgColor(styles[index].resolvedBackgroundColor))
                context.setAlpha(styles[index].resolvedBackgroundOpacity)
                let radius = styles[index].resolvedCornerRadius * Double(videoHeight) / 1920 * fit
                context.addPath(CGPath(roundedRect: cgRect(chip), cornerWidth: radius,
                                      cornerHeight: radius, transform: nil))
                context.fillPath()
                context.restoreGState()
            }
        }
        for index in layout.lines.indices {
            let font = CTFontCreateCopyWithAttributes(layout.fonts[index], CTFontGetSize(layout.fonts[index]) * fit, nil, nil)
            let lineDecor = styles[index].resolvedTextDecor(over: style.lineDecor)
            let lineWidth = painter.width(layout.lines[index], font: font, decor: lineDecor)
            let explicitAlignment = styles[index].decor?.alignment
            let localX = explicitAlignment == "center" ? (geometry.textBlock.width * fit - lineWidth) / 2
                : explicitAlignment == "trailing" ? (geometry.textBlock.width - layout.padding) * fit - lineWidth
                : explicitAlignment == "leading" ? layout.padding * fit : geometry.origins[index].x * fit
            let origin = CGPoint(x: offset.x + localX,
                y: CGFloat(videoHeight) - offset.y - geometry.origins[index].y * fit - CTFontGetAscent(font))
            var decor = styles[index].resolvedTextDecor(over: style.lineDecor)
            let modern = styles[index].decor != nil || style.decor != nil
            if boxDecor.bgPerLine == true {
                let rect = CGRect(x: origin.x, y: origin.y - CTFontGetDescent(font),
                    width: painter.width(layout.lines[index], font: font, decor: decor),
                    height: CTFontGetAscent(font) + CTFontGetDescent(font))
                    .insetBy(dx: -CTFontGetSize(font) * (boxDecor.bgPaddingX ?? 0.125),
                             dy: -CTFontGetSize(font) * (boxDecor.bgPaddingY ?? 0.125))
                painter.background(in: context, rect: rect, decor: boxDecor)
            }
            if !modern { decor.underline = false; decor.strikethrough = false }
            painter.draw(layout.lines[index], font: font, at: origin, decor: decor, in: context, drawBackground: modern)
            if !modern, let underline = geometry.underlines[index] {
                context.setFillColor(Self.cgColor(styles[index].underlineColor ?? styles[index].color))
                context.fill(cgRect(underline))
            }
            if !modern, let strike = geometry.strikethroughs[index] {
                context.setFillColor(Self.cgColor(styles[index].color))
                context.fill(cgRect(strike))
            }
        }
        drawImages(behind: false)
    }
}
