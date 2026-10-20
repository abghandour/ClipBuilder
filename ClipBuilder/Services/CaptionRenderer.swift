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
    private func resolveFont(size: CGFloat, family: String? = nil, italic: Bool = false) -> CTFont {
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
            let weighted: CTFont
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
                weighted = narrow ? bold : black
            case "bold": weighted = bold
            default: weighted = font
            }
            guard italic else { return weighted }
            if let face = CTFontCreateCopyWithSymbolicTraits(weighted, size, nil, .traitItalic, .traitItalic) {
                return face
            }
            var skew = CGAffineTransform(a: 1, b: 0, c: tan(.pi / 15), d: 1, tx: 0, ty: 0)
            return CTFontCreateWithName(CTFontCopyPostScriptName(weighted), size, &skew)
        }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    // MARK: - Layout

    private struct MeasuredFont {
        var font: CTFont
        var padding: CGFloat
    }

    /// Preserve historical sizing when an old profile has no explicit text size.
    private var baseSize: CGFloat {
        style.text?.size == nil ? max(36, CGFloat(videoWidth) / 22)
            : style.resolvedSize(for: .text) * CGFloat(videoWidth) / 1080
    }

    private var usesLegacyDecorations: Bool {
        style.text == nil && style.highlightDecor == nil && style.emphasisDecor == nil
    }

    private func stateFont(_ state: CaptionStyle.WordState, size: CGFloat) -> CTFont {
        let family: String
        switch state {
        case .text: family = style.font
        case .highlight: family = style.resolvedHighlightFont
        case .emphasis: family = style.resolvedEmphasisFont
        }
        // Explicit state sizes are points at 1080, even when the regular font
        // retains the legacy 36-pixel minimum on smaller video canvases.
        let ownSize: Double?
        switch state {
        case .text: ownSize = style.text?.size
        case .highlight: ownSize = style.highlightDecor?.size ?? style.text?.size
        case .emphasis: ownSize = style.emphasisDecor?.size ?? style.text?.size
        }
        let pixels = ownSize != nil
            ? style.resolvedSize(for: state) * CGFloat(videoWidth) / 1080 * size / baseSize
            : size * style.resolvedSize(for: state) / style.resolvedSize(for: .text)
        return resolveFont(size: pixels, family: family, italic: style.resolvedDecor(for: state).resolvedItalic)
    }

    /// Include padding and italic ink overhang in each state's reserved slot.
    private func measureFonts(size: CGFloat) -> [MeasuredFont] {
        var states: [CaptionStyle.WordState] = [.text]
        if style.resolvedHighlight != "none" { states.append(.highlight) }
        if style.resolvedEmphasis != "none" { states.append(.emphasis) }
        if usesLegacyDecorations {
            // Keep old pages geometrically compatible, including their wider
            // all-font Scale envelope and the Box mode's historical padding.
            let scale: CGFloat = style.resolvedHighlight == "scale" || ["scale", "both"].contains(style.resolvedEmphasis) ? 1.12 : 1
            return states.map { state in
                let family = state == .highlight ? style.resolvedHighlightFont
                    : state == .emphasis ? style.resolvedEmphasisFont : style.font
                return MeasuredFont(font: resolveFont(size: size * scale, family: family), padding: 0)
            }
        }
        return states.map { state in
            let font = stateFont(state, size: size)
            return MeasuredFont(font: font, padding: style.resolvedDecor(for: state).resolvedBackground ? CTFontGetSize(font) / 8 : 0)
        }
    }

    private func wordBounds(_ token: String, font: CTFont) -> CGRect {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: token, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): style.resolvedLetterSpacing * Double(videoWidth) / 1080,
        ]))
        let ink = usesLegacyDecorations ? CGRect.zero : CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let left = min(0, ink.minX)
        return CGRect(x: left, y: -CTFontGetDescent(font),
                      width: max(lineWidth(token, font: font), ink.maxX) - left,
                      height: CTFontGetAscent(font) + CTFontGetDescent(font))
    }

    private func reservedWidth(_ token: String, fonts: [MeasuredFont]) -> CGFloat {
        fonts.map { wordBounds(token, font: $0.font).width + $0.padding * 2 }.max() ?? 0
    }

    private func spaceWidth(_ fonts: [MeasuredFont]) -> CGFloat {
        fonts.first.map { lineWidth(" ", font: $0.font) } ?? 0
    }

    /// A line's width with every word at its reserved width.
    private func reservedLineWidth(_ text: String, fonts: [MeasuredFont]) -> CGFloat {
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
    private func wrap(_ text: String, fonts: [MeasuredFont]) -> [String] {
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
        wrap(style.resolvedUppercase ? text.uppercased() : text, fonts: measureFonts(size: baseSize)).count
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
        let size = baseSize
        let fonts = measureFonts(size: size)
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
        var fontSize = explicitSize ?? baseSize
        let initialFonts = measureFonts(size: fontSize)
        let longest = text.split(whereSeparator: \.isWhitespace)
            .map { reservedWidth(String($0), fonts: initialFonts) }.max() ?? 0
        if longest > maxTextWidth { fontSize *= maxTextWidth / longest }
        var fonts = measureFonts(size: fontSize)
        var lines = wrap(text, fonts: fonts)
        // Static fallback may regroup many one-word pages. Keep that page in
        // two rows too, without dropping words or exceeding the video width.
        while lines.count > 2 && fontSize > 1 {
            fontSize *= 0.9
            fonts = measureFonts(size: fontSize)
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
            let radius = style.bgRadius == nil ? CGFloat(max(6, Int(fontSize) / 6))
                : style.resolvedPageRadius * CGFloat(videoWidth) / 1080
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
                let state: CaptionStyle.WordState = active && style.resolvedHighlight != "none" ? .highlight
                    : emphasised && style.resolvedEmphasis != "none" ? .emphasis : .text
                let decor = style.resolvedDecor(for: state)
                var drawFont = stateFont(state, size: fontSize)
                if usesLegacyDecorations && state == .highlight && style.resolvedHighlight != "scale"
                    && emphasised && ["scale", "both"].contains(style.resolvedEmphasis) {
                    drawFont = resolveFont(size: fontSize * 1.12, family: style.resolvedHighlightFont)
                }
                let reserved = reservedWidth(token, fonts: fonts)
                let bounds = wordBounds(token, font: drawFont)
                let drawWidth = lineWidth(token, font: drawFont)
                let tokenX = cursor + (reserved - bounds.width) / 2 - bounds.minX
                var fill = textColor ?? style.color
                if emphasised && ["color", "both"].contains(style.resolvedEmphasis) { fill = style.resolvedEmphasisColor }
                if active && style.resolvedHighlight == "color" { fill = style.resolvedHighlightColor }
                let box = state == .highlight && style.resolvedHighlight == "box"
                if box { fill = style.resolvedHighlightColor }
                if decor.resolvedBackground {
                    let padding = CTFontGetSize(drawFont) / 8
                    let rect = usesLegacyDecorations && box
                        ? CGRect(x: tokenX - 3, y: baselineY - descent - 3, width: drawWidth + 6, height: ascent + descent + 6)
                        : bounds.offsetBy(dx: tokenX, dy: baselineY).insetBy(dx: -padding, dy: -padding)
                    let radius = usesLegacyDecorations && box ? 5 : CGFloat(decor.resolvedRadius) * CGFloat(videoWidth) / 1080
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                    context.setFillColor(color(decor.bgColor ?? fill, alpha: box || decor.bgColor != nil ? 1 : 0.25))
                    context.fillPath()
                    if box && decor.bgColor == nil {
                        let (r, g, b) = Self.parseHexColor(style.resolvedHighlightColor, fallback: (1, 0.84, 0))
                        fill = 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.55 ? "#000000" : "#ffffff"
                    }
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
                let thickness = max(1, CTFontGetUnderlineThickness(drawFont))
                var decorations: [CGRect] = []
                if decor.resolvedUnderline {
                    decorations.append(CGRect(x: tokenX, y: baselineY + CTFontGetUnderlinePosition(drawFont),
                                              width: drawWidth, height: thickness))
                }
                if decor.resolvedStrikethrough {
                    decorations.append(CGRect(x: tokenX, y: baselineY + CTFontGetXHeight(drawFont) / 2,
                                              width: drawWidth, height: thickness))
                }
                // Outline first, then the fill on top, so a thin rule keeps
                // its colour inside the same outline width as the glyphs.
                if !style.bgOn && style.resolvedStrokeWidth > 0 {
                    context.setStrokeColor(CGColor(gray: 0, alpha: 0.86))
                    context.setLineWidth(2 * style.resolvedStrokeWidth * CGFloat(videoWidth) / 1080)
                    for rect in decorations { context.stroke(rect) }
                }
                context.setFillColor(color(fill))
                for rect in decorations { context.fill(rect) }
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

    private static func maxAscent(_ fonts: [MeasuredFont]) -> CGFloat { fonts.map { CTFontGetAscent($0.font) + $0.padding }.max() ?? 0 }
    private static func maxDescent(_ fonts: [MeasuredFont]) -> CGFloat { fonts.map { CTFontGetDescent($0.font) + $0.padding }.max() ?? 0 }

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
