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

    /// The caption face at `size`; `family` defaults to the style's text font
    /// and the lit or emphasised word may ask for its own.
    private func resolveFont(size: CGFloat, family: String? = nil) -> CTFont {
        let family = family ?? style.font
        let familyNames: [String]
        switch family.lowercased() {
        case "serif": familyNames = ["Times New Roman", "Times", "Georgia"]
        case "mono": familyNames = ["Menlo", "Courier", "Courier New"]
        case "sans", "": familyNames = ["Helvetica Neue", "Helvetica", "Arial"]
        default: familyNames = [family, "Helvetica Neue"]
        }
        for name in familyNames {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            // CTFontCreateWithName falls back silently; accept the first result.
            let bold = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
            switch style.resolvedWeight {
            case "black":
                // Heaviest face of the family at normal width; a family whose
                // only heavier faces are condensed keeps its bold.
                let descriptor = CTFontDescriptorCreateWithAttributes([
                    kCTFontFamilyNameAttribute: CTFontCopyFamilyName(font),
                    kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.62, kCTFontWidthTrait: 0.0],
                ] as CFDictionary)
                let black = CTFontCreateWithFontDescriptor(descriptor, size, nil)
                let name = (CTFontCopyPostScriptName(black) as String).lowercased()
                let narrow = ["condensed", "compressed", "narrow", "extended", "expanded"].contains { name.contains($0) }
                return narrow ? bold : black
            case "bold": return bold
            default: return font
            }
        }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    // MARK: - Layout

    // Reserve the largest possible word size in every state, so the page's
    // geometry and baselines do not change when a different word lights up.
    private var wordScale: CGFloat {
        style.resolvedHighlight == "scale" || ["scale", "both"].contains(style.resolvedEmphasis) ? 1.12 : 1
    }

    /// Every face a page may draw a word in: the text font, plus the highlight
    /// and emphasis fonts while those states are on. Layout reserves the widest
    /// of them per word so a lit word never pushes into its neighbours.
    private func measureFonts(size: CGFloat) -> [CTFont] {
        var families = [style.font]
        if style.resolvedHighlight != "none" { families.append(style.resolvedHighlightFont) }
        if style.resolvedEmphasis != "none" { families.append(style.resolvedEmphasisFont) }
        var seen = Set<String>()
        return families.filter { seen.insert($0.lowercased()).inserted }
            .map { resolveFont(size: size, family: $0) }
    }

    private func reservedWidth(_ token: String, fonts: [CTFont]) -> CGFloat {
        fonts.map { lineWidth(token, font: $0) }.max() ?? 0
    }

    private func spaceWidth(_ fonts: [CTFont]) -> CGFloat {
        fonts.first.map { lineWidth(" ", font: $0) } ?? 0
    }

    /// A line's width with every word at its reserved width.
    private func reservedLineWidth(_ text: String, fonts: [CTFont]) -> CGFloat {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        return tokens.reduce(0) { $0 + reservedWidth($1, fonts: fonts) }
            + spaceWidth(fonts) * CGFloat(tokens.count - 1)
    }

    private func lineWidth(_ text: String, font: CTFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): style.resolvedLetterSpacing * Double(videoWidth) / 1080,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Greedy word-wrap to 86% of the video width (captions.py behavior).
    private func wrap(_ text: String, fonts: [CTFont]) -> [String] {
        let available = maxTextWidth
        var lines: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if reservedLineWidth(candidate, fonts: fonts) <= available || current.isEmpty {
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
                let widths = pair.map { reservedLineWidth($0, fonts: fonts) }
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
        let outerWidth = CGFloat(videoWidth) * (safeArea?.rect.width ?? 1)
        // Reserve pop's overshoot inside the available width, including the
        // fixed raster envelope and rounding at both edges.
        let contentWidth = style.resolvedAnimation == "pop" ? (outerWidth - 2) / 1.08 : outerWidth
        return min(CGFloat(videoWidth) * 0.86, contentWidth - padding)
    }

    func rowCount(for text: String) -> Int {
        wrap(style.resolvedUppercase ? text.uppercased() : text, fonts: measureFonts(size: max(36, CGFloat(videoWidth) / 22) * wordScale)).count
    }

    func pages(for segment: TranscriptSegment) -> [CaptionPage] {
        CaptionPaging.pages(text: segment.text, start: segment.start, end: segment.end,
                            words: segment.words, maxWords: style.resolvedWordsPerPage, fits: { text in
            let emoji = style.resolvedEmoji
                ? CaptionEmphasis.emoji(for: CaptionPage(text: text, start: 0, end: 1), language: "") : nil
            return rowCount(for: text + (emoji.map { " " + $0 } ?? "")) <= 2
        })
    }

    /// Conservative two-row band, in top-left canvas pixels, shared with name tags.
    func twoRowBand(positionOverride: String? = nil) -> CGRect {
        if let positionOverride, positionOverride != "auto", safeArea != nil {
            var fullFrame = self
            fullFrame.safeArea = nil
            return fullFrame.twoRowBand(positionOverride: positionOverride)
        }
        let size = max(36, CGFloat(videoWidth) / 22)
        let fonts = measureFonts(size: size * wordScale)
        let contentHeight = Int(ceil(Self.maxAscent(fonts) + Self.maxDescent(fonts))) * 2
            + max(4, Int(size) / 6) + max(10, Int(size) / 4) * 2
        let contentWidth = Int(maxTextWidth) + max(18, videoWidth / 60) * 2
        let motionX = style.resolvedAnimation == "pop" ? Int(ceil(Double(contentWidth) * 0.04)) : 0
        let motionY = style.resolvedAnimation == "pop" ? Int(ceil(Double(contentHeight) * 0.04))
            : (style.resolvedAnimation == "slide-up" ? Int(ceil(24 * Double(videoWidth) / 1080)) : 0)
        let box = RenderedCaption(pngURL: URL(fileURLWithPath: "/"),
                                  width: contentWidth + motionX * 2, height: contentHeight + motionY * 2)
        let origin = position(for: box, positionOverride: positionOverride)
        return CGRect(x: origin.x, y: origin.y, width: box.width, height: box.height)
    }

    // MARK: - Rendering

    /// Render one caption to a PNG in `directory`. Font size defaults to
    /// max(36, videoW / 22); explicit `fontSize` overrides (text overlays).
    func render(text: String, activeIndex: Int? = nil, emphasis: [Int] = [],
                textColor: String? = nil, frame: CaptionAnimation.Frame = .init(), to directory: URL,
                fontSize explicitSize: CGFloat? = nil) throws -> RenderedCaption {
        let text = style.resolvedUppercase ? text.uppercased() : text
        var fontSize = explicitSize ?? max(36, CGFloat(videoWidth) / 22)
        let initialFonts = measureFonts(size: fontSize * wordScale)
        let longest = text.split(whereSeparator: \.isWhitespace)
            .map { reservedWidth(String($0), fonts: initialFonts) }.max() ?? 0
        if longest > maxTextWidth { fontSize *= maxTextWidth / longest }
        var fonts = measureFonts(size: fontSize * wordScale)
        var lines = wrap(text, fonts: fonts)
        // Static fallback may regroup many one-word pages. Keep that page in
        // two rows too, without dropping words or exceeding the video width.
        while lines.count > 2 && fontSize > 1 {
            fontSize *= 0.9
            fonts = measureFonts(size: fontSize * wordScale)
            lines = wrap(text, fonts: fonts)
        }

        let padX = max(18, videoWidth / 60)
        let padY = max(10, Int(fontSize) / 4)
        let lineGap = max(4, Int(fontSize) / 6)
        let ascent = Self.maxAscent(fonts)
        let descent = Self.maxDescent(fonts)
        let lineHeight = Int((ascent + descent).rounded(.up))

        let maxLineWidth = lines.map { reservedLineWidth($0, fonts: fonts) }.max() ?? 0
        let textHeight = lineHeight * lines.count + lineGap * (lines.count - 1)
        let contentWidth = min(videoWidth, Int(maxLineWidth.rounded(.up)) + padX * 2)
        let contentHeight = textHeight + padY * 2
        // A fixed envelope for every frame, including the steady image.
        let motionX = style.resolvedAnimation == "pop" ? Int(ceil(Double(contentWidth) * 0.04)) : 0
        let motionY = style.resolvedAnimation == "pop" ? Int(ceil(Double(contentHeight) * 0.04))
            : (style.resolvedAnimation == "slide-up" ? Int(ceil(24 * Double(videoWidth) / 1080)) : 0)
        let boxWidth = contentWidth + motionX * 2
        let boxHeight = contentHeight + motionY * 2

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: boxWidth, height: boxHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }

        context.translateBy(x: CGFloat(boxWidth) / 2, y: CGFloat(boxHeight) / 2 - frame.offsetY * CGFloat(videoWidth) / 1080)
        context.scaleBy(x: frame.scale, y: frame.scale)
        context.translateBy(x: -CGFloat(contentWidth) / 2, y: -CGFloat(contentHeight) / 2)
        context.setAlpha(frame.alpha)

        func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
            let (r, g, b) = Self.parseHexColor(hex, fallback: (1, 1, 1))
            return CGColor(red: r, green: g, blue: b, alpha: alpha)
        }
        if style.bgOn {
            let radius = CGFloat(max(6, Int(fontSize) / 6))
            let rect = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(color(style.bgColor, alpha: 0.7))
            context.fillPath()
        }

        var tokenIndex = 0
        for (lineIndex, lineText) in lines.enumerated() {
            let width = reservedLineWidth(lineText, fonts: fonts)
            let x = Self.lineOrigin(width: width, boxWidth: CGFloat(contentWidth),
                                    padding: CGFloat(padX), alignment: style.alignment)
            let baselineY = CGFloat(contentHeight - padY - (lineIndex + 1) * lineHeight - lineIndex * lineGap) + descent
            let space = spaceWidth(fonts)
            var cursor = x
            for token in lineText.split(separator: " ").map(String.init) {
                let active = tokenIndex == activeIndex
                let emphasised = emphasis.contains(tokenIndex)
                let enlarged = (active && style.resolvedHighlight == "scale")
                    || (emphasised && ["scale", "both"].contains(style.resolvedEmphasis))
                let family = active && style.resolvedHighlight != "none" ? style.resolvedHighlightFont
                    : emphasised && style.resolvedEmphasis != "none" ? style.resolvedEmphasisFont : style.font
                let drawFont = resolveFont(size: fontSize * (enlarged ? 1.12 : 1), family: family)
                let reserved = reservedWidth(token, fonts: fonts)
                let drawWidth = lineWidth(token, font: drawFont)
                let tokenX = cursor + (reserved - drawWidth) / 2
                var fill = textColor ?? style.color
                if emphasised && ["color", "both"].contains(style.resolvedEmphasis) { fill = style.resolvedEmphasisColor }
                if active && style.resolvedHighlight == "color" { fill = style.resolvedHighlightColor }
                if active && style.resolvedHighlight == "box" {
                    let rect = CGRect(x: tokenX - 3, y: baselineY - descent - 3,
                                      width: drawWidth + 6, height: ascent + descent + 6)
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
                    context.setFillColor(color(style.resolvedHighlightColor))
                    context.fillPath()
                    // Keep a box highlight readable regardless of the base text colour.
                    let (r, g, b) = Self.parseHexColor(style.resolvedHighlightColor, fallback: (1, 0.84, 0))
                    fill = 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.55 ? "#000000" : "#ffffff"
                }
                var attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): drawFont,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(fill),
                    NSAttributedString.Key(kCTKernAttributeName as String): style.resolvedLetterSpacing * Double(videoWidth) / 1080,
                ]
                if !style.bgOn && style.resolvedStrokeWidth > 0 {
                    attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CGColor(gray: 0, alpha: 0.86)
                    attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                        -100 * style.resolvedStrokeWidth * Double(videoWidth) / 1080 / Double(CTFontGetSize(drawFont))
                }
                context.saveGState()
                if style.resolvedShadow {
                    context.setShadow(offset: CGSize(width: 0, height: -2), blur: 4,
                                      color: CGColor(gray: 0, alpha: 0.75))
                }
                context.textPosition = CGPoint(x: tokenX, y: baselineY)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: token, attributes: attributes)), context)
                context.restoreGState()
                cursor += reserved + space
                tokenIndex += 1
            }
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

    private static func maxAscent(_ fonts: [CTFont]) -> CGFloat { fonts.map(CTFontGetAscent).max() ?? 0 }
    private static func maxDescent(_ fonts: [CTFont]) -> CGFloat { fonts.map(CTFontGetDescent).max() ?? 0 }

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
