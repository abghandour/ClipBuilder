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
        let styles = [style.name, style.description]
        var lines = Array(item.text.components(separatedBy: "\n").prefix(2)).enumerated().map {
            styles[$0.offset].uppercase ? $0.element.uppercased() : $0.element
        }
        func measure(_ size: Int) -> NameTagLayout {
            let pixels = CGFloat(size) * CGFloat(videoHeight) / 1920
            let fonts = lines.indices.map {
                resolveFont(size: pixels * max(0.1, styles[$0].scale), family: styles[$0].font,
                            bold: styles[$0].bold, italic: styles[$0].italic)
            }
            let padding = ceil(pixels * 0.24)
            let gap = pixels * 0.12
            let geometry = TagLayout.layout(lines: lines.indices.map {
                TagLayout.Line(size: CGSize(width: lineWidth(lines[$0], font: fonts[$0]),
                    height: CTFontGetAscent(fonts[$0]) + CTFontGetDescent(fonts[$0])),
                    underlineThickness: styles[$0].underline
                        ? CTFontGetSize(fonts[$0]) * max(0, styles[$0].underlineThickness) : 0)
            }, padding: padding, gap: gap, alignment: style.alignment, images: style.images, aspects: aspects)
            return NameTagLayout(fontSize: size, lines: lines, fonts: fonts,
                size: geometry.bounds.size, padding: padding, lineGap: gap, geometry: geometry)
        }
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
        if style.bgOn {
            context.saveGState()
            context.setFillColor(Self.cgColor(style.bgColor))
            context.setAlpha(min(1, max(0, style.bgOpacity)))
            let radius = max(0, style.cornerRadius) * Double(videoHeight) / 1920 * fit
            context.addPath(CGPath(roundedRect: cgRect(geometry.textBlock), cornerWidth: radius,
                                  cornerHeight: radius, transform: nil))
            context.fillPath()
            context.restoreGState()
        }
        drawImages(behind: true)
        let styles = [style.name, style.description]
        for index in layout.lines.indices {
            let font = CTFontCreateCopyWithAttributes(layout.fonts[index], CTFontGetSize(layout.fonts[index]) * fit, nil, nil)
            context.setFillColor(Self.cgColor(styles[index].color))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: offset.x + geometry.origins[index].x * fit,
                y: CGFloat(videoHeight) - offset.y - geometry.origins[index].y * fit - CTFontGetAscent(font))
            CTLineDraw(line(layout.lines[index], font: font), context)
            if let underline = geometry.underlines[index] {
                context.setFillColor(Self.cgColor(styles[index].underlineColor ?? styles[index].color))
                context.fill(cgRect(underline))
            }
        }
        drawImages(behind: false)
    }
}
