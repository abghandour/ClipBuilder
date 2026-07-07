import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Renders builder text overlays to full-frame transparent PNGs — the Core
/// Text port of video.py's Pillow _render_text_image(). The PNG is the size
/// of the video (1080x1920) and gets overlaid at 0:0, so slide/fade filter
/// expressions work on the whole frame exactly like the Python pipeline.
nonisolated struct TextOverlayRenderer {
    var videoWidth = 1080
    var videoHeight = 1920

    // MARK: - Color / font

    /// Port of _parse_color: #hex, 0xhex, or a small set of names.
    static func parseColor(_ string: String?, fallback: (CGFloat, CGFloat, CGFloat) = (1, 1, 1))
        -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let string else { return fallback }
        var hex = string.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        else if hex.hasPrefix("0x") { hex.removeFirst(2) }
        else {
            switch hex {
            case "white": return (1, 1, 1)
            case "black": return (0, 0, 0)
            case "red": return (1, 0, 0)
            case "yellow": return (1, 1, 0)
            default: return fallback
            }
        }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { return fallback }
        return (CGFloat((value >> 16) & 0xff) / 255,
                CGFloat((value >> 8) & 0xff) / 255,
                CGFloat(value & 0xff) / 255)
    }

    private func resolveFont(size: CGFloat, family: String?, bold: Bool, italic: Bool) -> CTFont {
        let base = CTFontCreateWithName((family?.isEmpty == false ? family! : "Helvetica Neue") as CFString,
                                        size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    // MARK: - Measurement

    private func line(_ text: String, font: CTFont) -> CTLine {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        return CTLineCreateWithAttributedString(attributed)
    }

    private func lineWidth(_ text: String, font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font: font), nil, nil, nil))
    }

    /// Word-wrap to a pixel width (port of _wrap_text).
    private func wrap(_ text: String, font: CTFont, maxWidth: CGFloat) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [text] }
        var lines: [String] = []
        var current = words[0]
        for word in words.dropFirst() {
            let candidate = current + " " + word
            if lineWidth(candidate, font: font) <= maxWidth {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        lines.append(current)
        return lines
    }

    // MARK: - Rendering

    /// Render one overlay item to a full-frame PNG in `directory`.
    func render(_ item: TextOverlayItem, to directory: URL) throws -> URL {
        let width = videoWidth
        let height = videoHeight
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let (tr, tg, tb) = Self.parseColor(item.fontcolor)
        let textColor = CGColor(red: tr, green: tg, blue: tb, alpha: 1)

        if let wFrac = item.wFrac, let hFrac = item.hFrac,
           let xFrac = item.xFrac, let yFrac = item.yFrac, wFrac > 0, hFrac > 0 {
            drawFittedBox(in: context, item: item, textColor: textColor,
                          boxWidth: Int(Double(width) * wFrac), boxHeight: Int(Double(height) * hFrac),
                          centerX: Int(Double(width) * xFrac), centerY: Int(Double(height) * yFrac))
        } else {
            drawLegacy(in: context, item: item, textColor: textColor)
        }

        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let pngURL = directory.appendingPathComponent("overlay_\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return pngURL
    }

    /// WYSIWYG mode: auto-fit the largest font whose wrapped lines fill the
    /// destination box, then center the block (port of the w_frac/h_frac
    /// branch, including the binary search and 0.15em line spacing).
    private func drawFittedBox(in context: CGContext, item: TextOverlayItem, textColor: CGColor,
                               boxWidth: Int, boxHeight: Int, centerX: Int, centerY: Int) {
        func metrics(for size: CGFloat) -> (font: CTFont, lines: [String], lineHeight: CGFloat,
                                            spacing: CGFloat, totalHeight: CGFloat, maxWidth: CGFloat) {
            let font = resolveFont(size: size, family: item.fontfamily,
                                   bold: item.bold, italic: item.italic)
            let lines = wrap(item.text, font: font, maxWidth: CGFloat(boxWidth))
            let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font)
            let spacing = (size * 0.15).rounded(.down)
            let total = lineHeight * CGFloat(lines.count) + spacing * CGFloat(max(0, lines.count - 1))
            let maxLineWidth = lines.map { lineWidth($0, font: font) }.max() ?? 0
            return (font, lines, lineHeight, spacing, total, maxLineWidth)
        }

        var low = 6, high = max(boxWidth, boxHeight), best = 6
        while low <= high {
            let mid = (low + high) / 2
            let m = metrics(for: CGFloat(mid))
            if m.totalHeight <= CGFloat(boxHeight) && m.maxWidth <= CGFloat(boxWidth) {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let m = metrics(for: CGFloat(best))

        let boxLeft = centerX - boxWidth / 2
        let boxTop = centerY - boxHeight / 2
        if item.boxOpacity > 0 {
            fillRoundedBackground(in: context, item: item,
                                  topLeft: (boxLeft, boxTop), size: (boxWidth, boxHeight))
        }

        var cursorTop = CGFloat(boxTop) + (CGFloat(boxHeight) - m.totalHeight) / 2
        let ascent = CTFontGetAscent(m.font)
        for text in m.lines {
            let width = lineWidth(text, font: m.font)
            let x = CGFloat(boxLeft) + (CGFloat(boxWidth) - width) / 2
            drawLine(text, font: m.font, color: textColor, in: context,
                     x: x, baselineFromTop: cursorTop + ascent)
            cursorTop += m.lineHeight + m.spacing
        }
    }

    /// Legacy mode: one unwrapped line at a fractional point or a named
    /// position (top 8%, center, bottom 85% — video.py fallback branch).
    private func drawLegacy(in context: CGContext, item: TextOverlayItem, textColor: CGColor) {
        let font = resolveFont(size: CGFloat(item.fontsize), family: item.fontfamily,
                               bold: item.bold, italic: item.italic)
        let width = lineWidth(item.text, font: font)
        let ascent = CTFontGetAscent(font)
        let textHeight = ascent + CTFontGetDescent(font)

        var x: CGFloat
        var top: CGFloat
        if let xFrac = item.xFrac, let yFrac = item.yFrac {
            x = CGFloat(videoWidth) * CGFloat(xFrac) - width / 2
            top = CGFloat(videoHeight) * CGFloat(yFrac) - textHeight / 2
        } else {
            x = (CGFloat(videoWidth) - width) / 2
            switch item.position {
            case "top": top = CGFloat(videoHeight) * 0.08
            case "center", "middle": top = (CGFloat(videoHeight) - textHeight) / 2
            default: top = CGFloat(videoHeight) * 0.85
            }
        }

        if item.boxOpacity > 0 {
            fillRoundedBackground(in: context, item: item,
                                  topLeft: (Int(x), Int(top)),
                                  size: (Int(width.rounded(.up)), Int(textHeight.rounded(.up))))
        }
        drawLine(item.text, font: font, color: textColor, in: context,
                 x: x, baselineFromTop: top + ascent)
    }

    /// Rounded background box with 5px padding and 4px radius (Pillow parity).
    private func fillRoundedBackground(in context: CGContext, item: TextOverlayItem,
                                       topLeft: (x: Int, y: Int), size: (w: Int, h: Int)) {
        let (br, bg, bb) = Self.parseColor(item.bgcolor, fallback: (0, 0, 0))
        let pad = 5
        let rect = CGRect(x: CGFloat(topLeft.x - pad),
                          y: CGFloat(videoHeight - topLeft.y - size.h - pad),
                          width: CGFloat(size.w + pad * 2),
                          height: CGFloat(size.h + pad * 2))
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(path)
        context.setFillColor(CGColor(red: br, green: bg, blue: bb,
                                     alpha: CGFloat(min(1, max(0, item.boxOpacity)))))
        context.fillPath()
    }

    /// Draw one text line given a baseline measured from the frame's top edge
    /// (CoreGraphics origin is bottom-left).
    private func drawLine(_ text: String, font: CTFont, color: CGColor, in context: CGContext,
                          x: CGFloat, baselineFromTop: CGFloat) {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: x, y: CGFloat(videoHeight) - baselineFromTop)
        CTLineDraw(line, context)
    }
}
