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
    /// Auto placement clears platform UI; explicit positions use frame edges.
    var safeArea: PlatformSafeArea? = PlatformSafeArea.resolve(RenderContext.settings)

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
        let available = maxTextWidth
        var lines: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if lineWidth(candidate, font: font) <= available || current.isEmpty {
                current = candidate
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        // Balance two rows using the same measured widths used for drawing.
        if lines.count == 2 {
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            var best = CGFloat.greatestFiniteMagnitude
            for index in 1..<words.count {
                let pair = [words[..<index].joined(separator: " "), words[index...].joined(separator: " ")]
                let widths = pair.map { lineWidth($0, font: font) }
                if widths.allSatisfy({ $0 <= available }), abs(widths[0] - widths[1]) < best {
                    best = abs(widths[0] - widths[1])
                    lines = pair
                }
            }
        }
        return lines.isEmpty ? [text] : lines
    }

    private var maxTextWidth: CGFloat {
        let padding = CGFloat(max(18, videoWidth / 60) * 2)
        return min(CGFloat(videoWidth) * 0.86,
                   CGFloat(videoWidth) * (safeArea?.rect.width ?? 1) - padding)
    }

    func rowCount(for text: String) -> Int {
        wrap(text, font: resolveFont(size: max(36, CGFloat(videoWidth) / 22))).count
    }

    func pages(for segment: TranscriptSegment) -> [CaptionPage] {
        CaptionPaging.pages(text: segment.text, start: segment.start, end: segment.end,
                            words: segment.words, fits: { rowCount(for: $0) <= 2 })
    }

    /// Conservative two-row band, in top-left canvas pixels, shared with name tags.
    func twoRowBand(positionOverride: String? = nil) -> CGRect {
        if let positionOverride, positionOverride != "auto", safeArea != nil {
            var fullFrame = self
            fullFrame.safeArea = nil
            return fullFrame.twoRowBand(positionOverride: positionOverride)
        }
        let size = max(36, CGFloat(videoWidth) / 22)
        let font = resolveFont(size: size)
        let height = Int(ceil(CTFontGetAscent(font) + CTFontGetDescent(font))) * 2
            + max(4, Int(size) / 6) + max(10, Int(size) / 4) * 2
        let box = RenderedCaption(pngURL: URL(fileURLWithPath: "/"),
                                  width: Int(maxTextWidth) + max(18, videoWidth / 60) * 2, height: height)
        let origin = position(for: box, positionOverride: positionOverride)
        return CGRect(x: origin.x, y: origin.y, width: box.width, height: box.height)
    }

    // MARK: - Rendering

    /// Render one caption to a PNG in `directory`. Font size defaults to
    /// max(36, videoW / 22); explicit `fontSize` overrides (text overlays).
    func render(text: String, to directory: URL,
                fontSize explicitSize: CGFloat? = nil) throws -> RenderedCaption {
        var fontSize = explicitSize ?? max(36, CGFloat(videoWidth) / 22)
        let initialFont = resolveFont(size: fontSize)
        let longest = text.split(whereSeparator: \.isWhitespace)
            .map { lineWidth(String($0), font: initialFont) }.max() ?? 0
        if longest > maxTextWidth { fontSize *= maxTextWidth / longest }
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
            let x = Self.lineOrigin(width: width, boxWidth: CGFloat(boxWidth),
                                    padding: CGFloat(padX), alignment: style.alignment)
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

    /// Align wrapped lines inside the caption box; nil preserves centered captions.
    static func lineOrigin(width: CGFloat, boxWidth: CGFloat, padding: CGFloat,
                           alignment: String?) -> CGFloat {
        switch alignment {
        case "leading": padding
        case "trailing": max(padding, boxWidth - padding - width)
        default: (boxWidth - width) / 2
        }
    }

    /// Overlay pixel position for a rendered caption box — captions.py math.
    func position(for caption: RenderedCaption, positionOverride: String? = nil) -> (x: Int, y: Int) {
        // Auto retains the profile's historical placement and platform clearance.
        if positionOverride == nil || positionOverride == "auto" {
            return position(for: caption, clipPosition: style.position)
        }
        let margin = max(32, videoHeight / 28)
        let x = (videoWidth - caption.width) / 2
        let y: Int
        switch (positionOverride ?? style.position).lowercased() {
        case "top": y = margin
        case "middle": y = (videoHeight - caption.height) / 2
        default: y = videoHeight - margin - caption.height
        }
        return (x, y)
    }

    /// A Builder clip's caption row (bottom | middle | top): placed by the
    /// historical margins, then kept clear of the platform chrome when the
    /// timeline's safe area is on. The Wizard's explicit choices use
    /// `position(for:positionOverride:)` and the frame edge instead.
    func position(for caption: RenderedCaption, clipPosition: String) -> (x: Int, y: Int) {
        let margin = max(40, videoHeight / 18)
        let x = (videoWidth - caption.width) / 2
        let y: Int
        switch clipPosition.lowercased() {
        case "top": y = margin
        case "middle": y = (videoHeight - caption.height) / 2
        default: y = videoHeight - caption.height - margin
        }
        guard let safeArea else { return (x, y) }
        // Inside the safe area the caption keeps a smaller margin, so the
        // chrome-avoiding lift does not push it further than needed.
        let inset = max(16, videoHeight / 60)
        let origin = safeArea.clampedOrigin(
            x: Double(x) / Double(videoWidth), y: Double(y) / Double(videoHeight),
            width: Double(caption.width) / Double(videoWidth),
            height: Double(caption.height + inset * 2) / Double(videoHeight))
        return (Int((origin.x * Double(videoWidth)).rounded()),
                Int((origin.y * Double(videoHeight)).rounded()) + inset)
    }
}
