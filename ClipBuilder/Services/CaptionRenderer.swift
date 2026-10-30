import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Renders caption text to transparent PNGs for ffmpeg overlay burn-in —
/// the Core Text port of captions.py's Pillow renderer: same wrap width,
/// padding, outline, and position math so output matches the Python app.
nonisolated struct CaptionRenderer: Sendable {

    struct RenderedCaption: Sendable {
        var pngURL: URL
        var width: Int
        var height: Int
    }

    var videoWidth: Int
    var videoHeight: Int
    var style: CaptionStyle { didSet { resolved = ResolvedStates(style) } }
    /// Auto placement clears platform UI; explicit positions use frame edges.
    var safeArea: PlatformSafeArea?
    var safeAreaOnly: Bool

    init(videoWidth: Int, videoHeight: Int, style: CaptionStyle,
         safeArea: PlatformSafeArea? = PlatformSafeArea.resolve(RenderContext.settings), safeAreaOnly: Bool = false) {
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.style = style
        self.safeArea = safeArea
        self.safeAreaOnly = safeAreaOnly
        resolved = ResolvedStates(style)
    }

    /// Every word state's decor, resolved once per renderer rather than per
    /// word. The style resolvers each hold a 60 KB frame in Debug builds;
    /// called from the word loop they overflowed the 512 KB cooperative
    /// thread stack under the Wizard preview (2026-10-29).
    private var resolved: ResolvedStates

    private struct ResolvedStates: Sendable {
        var text: [CaptionStyle.WordState: TextDecor] = [:]
        var word: [CaptionStyle.WordState: CaptionWordDecor] = [:]
        var size: [CaptionStyle.WordState: Double] = [:]
        var page: TextDecor
        // Whole-caption choices read in the word loop: plain values keep
        // the render frame small (each `style.x` copies the style in Debug).
        var highlight: String
        var highlightColor: String
        var highlightFont: String
        var emphasis: String
        var emphasisColor: String
        var emphasisFont: String
        var animation: String
        var weight: String
        var hasTextDecor: Bool

        init(_ style: CaptionStyle) {
            for state in CaptionStyle.WordState.allCases {
                text[state] = style.resolvedTextDecor(for: state)
                word[state] = style.resolvedDecor(for: state)
                size[state] = style.resolvedSize(for: state)
            }
            page = style.pageDecor
            highlight = style.resolvedHighlight
            highlightColor = style.resolvedHighlightColor
            highlightFont = style.resolvedHighlightFont
            emphasis = style.resolvedEmphasis
            emphasisColor = style.resolvedEmphasisColor
            emphasisFont = style.resolvedEmphasisFont
            animation = style.resolvedAnimation
            weight = style.resolvedWeight
            hasTextDecor = style.hasTextDecor
        }
    }

    private func textDecor(_ state: CaptionStyle.WordState) -> TextDecor { resolved.text[state] ?? TextDecor() }
    private func wordDecor(_ state: CaptionStyle.WordState) -> CaptionWordDecor { resolved.word[state] ?? CaptionWordDecor() }

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
    private func resolveFont(size: CGFloat, family: String? = nil, italic: Bool = false,
                             weight: String? = nil) -> CTFont {
        let family = family ?? style.fontOverride ?? style.font
        let weight = weight ?? resolved.weight
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
            switch weight {
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
        var kern: CGFloat = 0
        var casing: String? = nil
    }

    /// Letter spacing of a word state in canvas pixels.
    private func kern(for state: CaptionStyle.WordState) -> CGFloat {
        (textDecor(state).letterSpacing ?? 0) * CGFloat(videoWidth) / 1080
    }

    /// Preserve historical sizing when an old profile has no explicit text size.
    private var baseSize: CGFloat {
        style.text?.size == nil ? max(36, CGFloat(videoWidth) / 22)
            : (resolved.size[.text] ?? 49) * CGFloat(videoWidth) / 1080
    }

    private var usesLegacyDecorations: Bool {
        !resolved.hasTextDecor && style.text == nil && style.highlightDecor == nil && style.emphasisDecor == nil
    }

    private func stateFont(_ state: CaptionStyle.WordState, size: CGFloat) -> CTFont {
        let family: String
        switch state {
        case .text: family = style.fontOverride ?? style.font
        case .highlight: family = resolved.highlightFont
        case .emphasis: family = resolved.emphasisFont
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
            ? (resolved.size[state] ?? 49) * CGFloat(videoWidth) / 1080 * size / baseSize
            : size * (resolved.size[state] ?? 49) / (resolved.size[.text] ?? 49)
        let decor = textDecor(state)
        return resolveFont(size: pixels * (decor.size ?? 1), family: family, italic: decor.italic ?? false, weight: decor.weight)
    }

    /// Include padding and italic ink overhang in each state's reserved slot.
    private func measureFonts(size: CGFloat) -> [MeasuredFont] {
        var states: [CaptionStyle.WordState] = [.text]
        if resolved.highlight != "none" { states.append(.highlight) }
        if resolved.emphasis != "none" { states.append(.emphasis) }
        if usesLegacyDecorations {
            // Keep old pages geometrically compatible, including their wider
            // all-font Scale envelope and the Box mode's historical padding.
            let scale: CGFloat = resolved.highlight == "scale" || ["scale", "both"].contains(resolved.emphasis) ? 1.12 : 1
            return states.map { state in
                let family = state == .highlight ? resolved.highlightFont
                    : state == .emphasis ? resolved.emphasisFont : style.fontOverride ?? style.font
                return MeasuredFont(font: resolveFont(size: size * scale, family: family), padding: 0,
                                    kern: kern(for: .text), casing: textDecor(.text).casing)
            }
        }
        return states.map { state in
            let font = stateFont(state, size: size)
            let decor = textDecor(state)
            let padding = decor.bgOn == true || decor.borderOn == true ? CTFontGetSize(font) * max(decor.bgPaddingX ?? 0.125, decor.bgPaddingY ?? 0.125) : 0
            return MeasuredFont(font: font, padding: padding, kern: kern(for: state), casing: decor.casing)
        }
    }

    private func wordBounds(_ token: String, font: CTFont, kern: CGFloat) -> CGRect {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: token, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
        ]))
        let ink = usesLegacyDecorations ? CGRect.zero : CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let left = min(0, ink.minX)
        return CGRect(x: left, y: -CTFontGetDescent(font),
                      width: max(lineWidth(token, font: font, kern: kern), ink.maxX) - left,
                      height: CTFontGetAscent(font) + CTFontGetDescent(font))
    }

    private func reservedWidth(_ token: String, fonts: [MeasuredFont]) -> CGFloat {
        fonts.map { wordBounds(TextCasing.apply(token, casing: $0.casing), font: $0.font, kern: $0.kern).width + $0.padding * 2 }.max() ?? 0
    }

    private func spaceWidth(_ fonts: [MeasuredFont]) -> CGFloat {
        fonts.first.map { lineWidth(" ", font: $0.font, kern: $0.kern) } ?? 0
    }

    /// A line's width with every word at its reserved width.
    private func reservedLineWidth(_ text: String, fonts: [MeasuredFont]) -> CGFloat {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        return tokens.reduce(0) { $0 + reservedWidth($1, fonts: fonts) }
            + spaceWidth(fonts) * CGFloat(tokens.count - 1)
    }

    private func lineWidth(_ text: String, font: CTFont, kern: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
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
        let contentWidth = resolved.animation == "pop" ? (outerWidth - 2) / 1.08 : outerWidth
        return min(CGFloat(videoWidth) * (textDecor(.text).maxWidthFrac ?? 0.86), contentWidth - padding)
    }

    func rowCount(for text: String) -> Int {
        wrap(text, fonts: measureFonts(size: baseSize)).count
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
        if !safeAreaOnly, let positionOverride, positionOverride != "auto", safeArea != nil {
            var fullFrame = self
            fullFrame.safeArea = nil
            return fullFrame.twoRowBand(positionOverride: positionOverride)
        }
        let size = baseSize
        let fonts = measureFonts(size: size)
        let contentHeight = Int(ceil(Self.maxAscent(fonts) + Self.maxDescent(fonts))) * 2
            + max(4, Int(size) / 6) + max(10, Int(size) / 4) * 2
        let contentWidth = Int(maxTextWidth) + max(18, videoWidth / 60) * 2
        let motionX = resolved.animation == "pop" ? Int(ceil(Double(contentWidth) * 0.04)) : 0
        let motionY = resolved.animation == "pop" ? Int(ceil(Double(contentHeight) * 0.04))
            : (resolved.animation == "slide-up" ? Int(ceil(24 * Double(videoWidth) / 1080)) : 0)
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

        let padX = (style.text?.decor?.bgPaddingX ?? style.decor?.bgPaddingX).map { Int(ceil(fontSize * $0)) } ?? max(18, videoWidth / 60)
        let padY = (style.text?.decor?.bgPaddingY ?? style.decor?.bgPaddingY).map { Int(ceil(fontSize * $0)) } ?? max(10, Int(fontSize) / 4)
        let lineGap = max(4, Int(fontSize) / 6) + Int(fontSize * ((textDecor(.text).lineHeight ?? 1) - 1))
        let ascent = Self.maxAscent(fonts)
        let descent = Self.maxDescent(fonts)
        let lineHeight = Int((ascent + descent).rounded(.up))

        let maxLineWidth = lines.map { reservedLineWidth($0, fonts: fonts) }.max() ?? 0
        let textHeight = lineHeight * lines.count + lineGap * (lines.count - 1)
        let contentWidth = min(videoWidth, Int(maxLineWidth.rounded(.up)) + padX * 2)
        let contentHeight = textHeight + padY * 2
        // A fixed envelope for every frame, including the steady image.
        let motionX = resolved.animation == "pop" ? Int(ceil(Double(contentWidth) * 0.04)) : 0
        let motionY = resolved.animation == "pop" ? Int(ceil(Double(contentHeight) * 0.04))
            : (resolved.animation == "slide-up" ? Int(ceil(24 * Double(videoWidth) / 1080)) : 0)
        let effects = CaptionStyle.WordState.allCases.map { textDecor($0) } + [resolved.page]
        let effectFontSize = fonts.map { CTFontGetSize($0.font) }.max() ?? fontSize
        let effectInset = resolved.hasTextDecor ? Int(ceil(effects.map { d in
            let border = d.borderOn == true ? (d.borderWidth ?? 2) * CGFloat(videoWidth) / 1080 : 0
            let blur = d.shadowStyle == "soft" ? (d.shadowBlur ?? 0) * 2 : 0 // hard and extrude ignore blur
            let shadow = d.shadowOn == true ? effectFontSize * (max(abs(d.shadowX ?? 0), abs(d.shadowY ?? 0)) + blur) : 0
            return border + shadow + (d.strokeOn == true ? (d.strokeWidth ?? 1) * CGFloat(videoWidth) / 1080 : 0)
        }.max() ?? 0)) : 0
        let boxWidth = contentWidth + (motionX + effectInset) * 2
        let boxHeight = contentHeight + (motionY + effectInset) * 2

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
        if frame.alpha < 1 { context.beginTransparencyLayer(auxiliaryInfo: nil) }

        func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
            let (r, g, b) = Self.parseHexColor(hex, fallback: (1, 1, 1))
            return CGColor(red: r, green: g, blue: b, alpha: alpha)
        }
        let painter = TextDecorPainter(scale: CGFloat(videoWidth) / 1080)
        let pageDecor = resolved.page
        if pageDecor.bgPerLine != true {
            painter.background(in: context, rect: CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
                decor: pageDecor, radius: style.decor?.bgRadius == nil && style.bgRadius == nil
                    ? CGFloat(max(6, Int(fontSize) / 6)) : nil)
        }

        var tokenIndex = 0
        for (lineIndex, lineText) in lines.enumerated() {
            let width = reservedLineWidth(lineText, fonts: fonts)
            let x = Self.lineOrigin(width: width, boxWidth: CGFloat(contentWidth),
                                    padding: CGFloat(padX), alignment: textDecor(.text).alignment)
            let baselineY = CGFloat(contentHeight - padY - (lineIndex + 1) * lineHeight - lineIndex * lineGap) + descent
            if pageDecor.bgPerLine == true {
                painter.background(in: context,
                    rect: CGRect(x: x, y: baselineY - descent, width: width, height: CGFloat(lineHeight))
                        .insetBy(dx: -fontSize * (pageDecor.bgPaddingX ?? 0.125), dy: -fontSize * (pageDecor.bgPaddingY ?? 0.125)),
                    decor: pageDecor)
            }
            let space = spaceWidth(fonts)
            var cursor = x
            for token in lineText.split(separator: " ").map(String.init) {
                let active = tokenIndex == activeIndex
                let emphasised = emphasis.contains(tokenIndex)
                let state: CaptionStyle.WordState = active && resolved.highlight != "none" ? .highlight
                    : emphasised && resolved.emphasis != "none" ? .emphasis : .text
                let decor = wordDecor(state)
                var drawFont = stateFont(state, size: fontSize)
                if usesLegacyDecorations && state == .highlight && resolved.highlight != "scale"
                    && emphasised && ["scale", "both"].contains(resolved.emphasis) {
                    drawFont = resolveFont(size: fontSize * 1.12, family: resolved.highlightFont)
                }
                let wordKern = usesLegacyDecorations ? kern(for: .text) : kern(for: state)
                let reserved = reservedWidth(token, fonts: fonts)
                let token = TextCasing.apply(token, casing: textDecor(state).casing, firstWord: tokenIndex == 0)
                let bounds = wordBounds(token, font: drawFont, kern: wordKern)
                let drawWidth = lineWidth(token, font: drawFont, kern: wordKern)
                let tokenX = cursor + (reserved - bounds.width) / 2 - bounds.minX
                var fill = textColor ?? style.color
                if emphasised && ["color", "both"].contains(resolved.emphasis) { fill = resolved.emphasisColor }
                if active && resolved.highlight == "color" { fill = resolved.highlightColor }
                let box = state == .highlight && resolved.highlight == "box"
                if box { fill = resolved.highlightColor }
                var paint = textDecor(state)
                if !resolved.hasTextDecor { paint.color = fill }
                else if let textColor, state == .text { paint.color = textColor }
                var backgroundRect: CGRect?
                var radius: CGFloat?
                if !resolved.hasTextDecor {
                    paint.shadowY = -2 / CTFontGetSize(drawFont)
                    paint.shadowBlur = 4 / CTFontGetSize(drawFont)
                }
                if box && decor.bgColor == nil && (state == .highlight ? style.highlightDecor?.decor?.bgColor : nil) == nil {
                    paint.bgColor = resolved.highlightColor
                    paint.bgOpacity = 1
                    let (r, g, b) = Self.parseHexColor(resolved.highlightColor, fallback: (1, 0.84, 0))
                    paint.color = 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.55 ? "#000000" : "#ffffff"
                } else if !resolved.hasTextDecor { paint.bgColor = decor.bgColor ?? fill }
                if usesLegacyDecorations && box {
                    backgroundRect = CGRect(x: tokenX - 3, y: baselineY - descent - 3, width: drawWidth + 6, height: ascent + descent + 6)
                    radius = 5
                } else {
                    backgroundRect = bounds.offsetBy(dx: tokenX, dy: baselineY).insetBy(
                        dx: -CTFontGetSize(drawFont) * (paint.bgPaddingX ?? 0.125),
                        dy: -CTFontGetSize(drawFont) * (paint.bgPaddingY ?? 0.125))
                }
                painter.draw(token, font: drawFont, at: CGPoint(x: tokenX, y: baselineY), decor: paint,
                             in: context, backgroundRect: backgroundRect, radius: radius)
                cursor += reserved + space
                tokenIndex += 1
            }
        }

        if frame.alpha < 1 { context.endTransparencyLayer() }
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
        // A position the user dragged to in the preview: centred on the point,
        // kept inside the frame, and inside the safe area when that is on.
        if let custom = CustomPosition(positionOverride) {
            return customOrigin(custom, caption: caption, respectSafeArea: safeAreaOnly)
        }
        if safeAreaOnly {
            let position = positionOverride.flatMap { $0 == "auto" ? nil : $0 } ?? style.position
            return self.position(for: caption, clipPosition: position)
        }
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
        if let custom = CustomPosition(clipPosition) {
            return customOrigin(custom, caption: caption, respectSafeArea: true)
        }
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

    private func customOrigin(_ custom: CustomPosition, caption: RenderedCaption, respectSafeArea: Bool) -> (x: Int, y: Int) {
        let frame = CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight)
        var origin = custom.origin(size: CGSize(width: caption.width, height: caption.height), in: frame)
        if respectSafeArea, let safeArea {
            let clamped = safeArea.clampedOrigin(
                x: Double(origin.x) / Double(videoWidth), y: Double(origin.y) / Double(videoHeight),
                width: Double(caption.width) / Double(videoWidth), height: Double(caption.height) / Double(videoHeight))
            origin = CGPoint(x: clamped.x * Double(videoWidth), y: clamped.y * Double(videoHeight))
        }
        return (Int(origin.x.rounded()), Int(origin.y.rounded()))
    }
}
