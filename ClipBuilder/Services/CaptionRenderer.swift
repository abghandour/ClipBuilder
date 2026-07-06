import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Renders caption text to transparent PNGs for ffmpeg overlay burn-in —
/// the Core Text port of captions.py's Pillow renderer: same wrap width,
/// padding, outline, and position math so output matches the Python app.
nonisolated struct CaptionRenderer {

    struct RenderedCaption {
        var pngURL: URL
        var width: Int
        var height: Int
    }

    var videoWidth: Int
    var videoHeight: Int
    var style: CaptionStyle

    // MARK: - Color / font resolution

    static func parseHexColor(_ string: String, fallback: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
        var hex = string.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return fallback }
        return (CGFloat((value >> 16) & 0xff) / 255,
                CGFloat((value >> 8) & 0xff) / 255,
                CGFloat(value & 0xff) / 255)
    }

    private func resolveFont(size: CGFloat) -> CTFont {
        let familyNames: [String]
        switch style.font.lowercased() {
        case "serif": familyNames = ["Times New Roman", "Times", "Georgia"]
        case "mono": familyNames = ["Menlo", "Courier", "Courier New"]
        case "sans", "": familyNames = ["Helvetica Neue", "Helvetica", "Arial"]
        default: familyNames = [style.font, "Helvetica Neue"]
        }
        for name in familyNames {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            // CTFontCreateWithName falls back silently; accept the first result.
            return font
        }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    // MARK: - Layout

    private func lineWidth(_ text: String, font: CTFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Greedy word-wrap to 86% of the video width (captions.py behavior).
    private func wrap(_ text: String, font: CTFont) -> [String] {
        let available = CGFloat(videoWidth) * 0.86
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if lineWidth(candidate, font: font) <= available || current.isEmpty {
                current = candidate
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [text] : lines
    }

    // MARK: - Rendering

    /// Render one caption to a PNG in `directory`. Font size defaults to
    /// max(36, videoW / 22); explicit `fontSize` overrides (text overlays).
    func render(text: String, to directory: URL,
                fontSize explicitSize: CGFloat? = nil) throws -> RenderedCaption {
        let fontSize = explicitSize ?? max(36, CGFloat(videoWidth) / 22)
        let font = resolveFont(size: fontSize)
        let lines = wrap(text, font: font)

        let padX = max(18, videoWidth / 60)
        let padY = max(10, Int(fontSize) / 4)
        let lineGap = max(4, Int(fontSize) / 6)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = Int((ascent + descent).rounded(.up))

        let maxLineWidth = lines.map { lineWidth($0, font: font) }.max() ?? 0
        let textHeight = lineHeight * lines.count + lineGap * (lines.count - 1)
        let boxWidth = min(videoWidth, Int(maxLineWidth.rounded(.up)) + padX * 2)
        let boxHeight = textHeight + padY * 2

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: boxWidth, height: boxHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let (tr, tg, tb) = Self.parseHexColor(style.color, fallback: (1, 1, 1))
        let hasBackground = style.bgOn
        if hasBackground {
            let (br, bg, bb) = Self.parseHexColor(style.bgColor, fallback: (0, 0, 0))
            let radius = CGFloat(max(6, Int(fontSize) / 6))
            let rect = CGRect(x: 0, y: 0, width: CGFloat(boxWidth), height: CGFloat(boxHeight))
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            context.setFillColor(CGColor(red: br, green: bg, blue: bb, alpha: 0.7))
            context.fillPath()
        }

        let showOutline = !hasBackground
        for (index, lineText) in lines.enumerated() {
            let width = lineWidth(lineText, font: font)
            let x = (CGFloat(boxWidth) - width) / 2
            // CoreGraphics origin is bottom-left; line 0 is the top line.
            let baselineY = CGFloat(boxHeight - padY - (index + 1) * lineHeight - index * lineGap) + descent

            func draw(_ color: CGColor, offsetX: CGFloat, offsetY: CGFloat) {
                let attributed = NSAttributedString(string: lineText, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: x + offsetX, y: baselineY + offsetY)
                CTLineDraw(line, context)
            }

            if showOutline {
                let outline = CGColor(red: 0, green: 0, blue: 0, alpha: 220.0 / 255.0)
                for dx in [-1, 0, 1] {
                    for dy in [-1, 0, 1] where !(dx == 0 && dy == 0) {
                        draw(outline, offsetX: CGFloat(dx), offsetY: CGFloat(dy))
                    }
                }
            }
            draw(CGColor(red: tr, green: tg, blue: tb, alpha: 1), offsetX: 0, offsetY: 0)
        }

        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let pngURL = directory.appendingPathComponent("caption_\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return RenderedCaption(pngURL: pngURL, width: boxWidth, height: boxHeight)
    }

    /// Overlay pixel position for a rendered caption box — captions.py math.
    func position(for caption: RenderedCaption, positionOverride: String? = nil) -> (x: Int, y: Int) {
        let marginV = max(40, videoHeight / 18)
        let x = (videoWidth - caption.width) / 2
        switch (positionOverride ?? style.position).lowercased() {
        case "top": return (x, marginV)
        case "middle": return (x, (videoHeight - caption.height) / 2)
        default: return (x, videoHeight - caption.height - marginV)
        }
    }
}
