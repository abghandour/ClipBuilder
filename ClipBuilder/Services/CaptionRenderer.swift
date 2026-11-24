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
        var cyclesHighlight: Bool
        var highlightFont: String
        var emphasis: String
        var emphasisColor: String
        var emphasisFont: String
        var animation: String
        var weight: String
        var hasTextDecor: Bool
        var font: String
        var color: String
        var textSize: Double?
        var highlightSize: Double?
        var emphasisSize: Double?
        // The second emphasis look, resolved from the style once.
        var hasAlternate: Bool
        var alternateEmphasis: String
        var alternateColor: String
        var alternateFont: String
        var alternateSize: Double?
        // An emphasis word that keeps its own colour while it is spoken.
        var emphasisKeepsColor: Bool
        var alternateKeepsColor: Bool
        var legacyDecorations: Bool
        var states: [CaptionStyle.WordState]
        var lineBreaks: String
        var lineSpacing: Double?
        var srgb: Bool
        var paddingX: Double?
        var paddingY: Double?
        var automaticRadius: Bool
        var highlightHasBackgroundColor: Bool

        init(_ style: CaptionStyle) {
            for state in CaptionStyle.WordState.allCases {
                text[state] = style.resolvedTextDecor(for: state)
                word[state] = style.resolvedDecor(for: state)
                size[state] = style.resolvedSize(for: state)
            }
            page = style.pageDecor
            highlight = style.resolvedHighlight
            highlightColor = CaptionRenderer.highlightColor(forPage: 0, style: style)
            cyclesHighlight = style.highlightColors?.isEmpty == false
            highlightFont = style.resolvedHighlightFont
            emphasis = style.resolvedEmphasis
            emphasisColor = style.resolvedEmphasisColor
            emphasisFont = style.resolvedEmphasisFont
            animation = style.resolvedAnimation
            weight = style.resolvedWeight
            hasTextDecor = style.hasTextDecor
            font = style.fontOverride ?? style.font
            color = style.color
            textSize = style.text?.size
            highlightSize = style.highlightDecor?.size
            emphasisSize = style.emphasisDecor?.size
            hasAlternate = style.hasAlternateEmphasis
            let alternate = style.alternateEmphasisStyle
            alternateEmphasis = alternate.resolvedEmphasis
            alternateColor = alternate.resolvedEmphasisColor
            alternateFont = alternate.resolvedEmphasisFont
            alternateSize = alternate.emphasisDecor?.size
            emphasisKeepsColor = style.emphasisDecor?.takesHighlightColor == false
            alternateKeepsColor = alternate.emphasisDecor?.takesHighlightColor == false
            legacyDecorations = !style.hasTextDecor && style.text == nil && style.highlightDecor == nil
                && style.emphasisDecor == nil && !style.hasAlternateEmphasis
            states = style.renderingStates
            lineBreaks = style.resolvedLineBreaks
            lineSpacing = style.resolvedLineSpacing.map { Double($0) }
            srgb = style.colorSpace == "srgb"
            paddingX = style.text?.decor?.bgPaddingX ?? style.decor?.bgPaddingX
            paddingY = style.text?.decor?.bgPaddingY ?? style.decor?.bgPaddingY
            automaticRadius = style.decor?.bgRadius == nil && style.bgRadius == nil
            highlightHasBackgroundColor = style.highlightDecor?.decor?.bgColor != nil
        }
    }

    private func textDecor(_ state: CaptionStyle.WordState) -> TextDecor { resolved.text[state] ?? TextDecor() }
    private func wordDecor(_ state: CaptionStyle.WordState) -> CaptionWordDecor { resolved.word[state] ?? CaptionWordDecor() }

    // MARK: - Color / font resolution

    /// A page keeps one highlight colour through all of its word and animation frames.
    static func highlightColor(forPage index: Int, style: CaptionStyle) -> String {
        guard let colors = style.highlightColors, !colors.isEmpty else { return style.resolvedHighlightColor }
        return colors[max(0, index) % colors.count]
    }

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
        let family = family ?? resolved.font
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

    struct MeasuredFont {
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
        resolved.textSize == nil ? max(36, CGFloat(videoWidth) / 22)
            : (resolved.size[.text] ?? 49) * CGFloat(videoWidth) / 1080
    }

    private var usesLegacyDecorations: Bool {
        resolved.legacyDecorations
    }

    private func stateFont(_ state: CaptionStyle.WordState, size: CGFloat) -> CTFont {
        let family: String
        switch state {
        case .text: family = resolved.font
        case .highlight: family = resolved.highlightFont
        case .emphasis: family = resolved.emphasisFont
        case .emphasis2: family = resolved.alternateFont
        }
        // Explicit state sizes are points at 1080, even when the regular font
        // retains the legacy 36-pixel minimum on smaller video canvases.
        let ownSize: Double?
        switch state {
        case .text: ownSize = resolved.textSize
        case .highlight: ownSize = resolved.highlightSize ?? resolved.textSize
        case .emphasis: ownSize = resolved.emphasisSize ?? resolved.textSize
        case .emphasis2: ownSize = resolved.alternateSize ?? resolved.textSize
        }
        let pixels = ownSize != nil
            ? (resolved.size[state] ?? 49) * CGFloat(videoWidth) / 1080 * size / baseSize
            : size * (resolved.size[state] ?? 49) / (resolved.size[.text] ?? 49)
        let decor = textDecor(state)
        return resolveFont(size: pixels * (decor.size ?? 1), family: family, italic: decor.italic ?? false, weight: decor.weight)
    }

    /// Include padding and italic ink overhang in each state's reserved slot.
    private func measureFonts(size: CGFloat, includeEmphasis: Bool = true, includeAlternate: Bool = false) -> [MeasuredFont] {
        var states: [CaptionStyle.WordState] = [.text]
        if resolved.highlight != "none" { states.append(.highlight) }
        if includeEmphasis && resolved.emphasis != "none" { states.append(.emphasis) }
        if includeAlternate && resolved.emphasis != "none" { states.append(.emphasis2) }
        if usesLegacyDecorations {
            // Keep old pages geometrically compatible, including their wider
            // all-font Scale envelope and the Box mode's historical padding.
            let scale: CGFloat = resolved.highlight == "scale" || ["scale", "both"].contains(resolved.emphasis) ? 1.12 : 1
            return states.map { state in
                let family = state == .highlight ? resolved.highlightFont
                    : state == .emphasis ? resolved.emphasisFont : resolved.font
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
        if let spacing = style.resolvedWordSpacing {
            return spacing * CGFloat(videoWidth) / 1080
        }
        return fonts.first.map { lineWidth(" ", font: $0.font, kern: $0.kern) } ?? 0
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

    /// "sentence" ends a row after a sentence; "clause" also after a comma,
    /// semicolon or colon. The word may carry closing quotes or brackets.
    static func endsRow(_ word: String, lineBreaks: String) -> Bool {
        guard lineBreaks == "sentence" || lineBreaks == "clause",
              let last = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}")).last else { return false }
        return (lineBreaks == "clause" ? ".!?…。！？,;:，、；：" : ".!?…。！？").contains(last)
    }

    /// Two rows are evened out unless punctuation already chose the break.
    static func balances(_ words: [String], lineBreaks: String) -> Bool {
        lineBreaks == "balanced"
            || (lineBreaks == "clause" && !words.dropLast().contains { endsRow($0, lineBreaks: lineBreaks) })
    }

    /// Greedy word-wrap to 86% of the video width (captions.py behavior).
    private func wrap(_ text: String, fonts: [MeasuredFont], lineBreaks: String? = nil) -> [String] {
        let available = maxTextWidth
        let lineBreaks = lineBreaks ?? resolved.lineBreaks
        var lines: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            let sentenceEnd = Self.endsRow(current, lineBreaks: lineBreaks)
            if !sentenceEnd && (reservedLineWidth(candidate, fonts: fonts) <= available || current.isEmpty) {
                current = candidate
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        // Balance two rows using the same measured widths used for drawing.
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if lines.count == 2 && Self.balances(words, lineBreaks: lineBreaks) {
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
        // Reserve the entrance overshoot inside the fixed raster envelope.
        let scale = CaptionAnimation.maximumScale(for: resolved.animation)
        let contentWidth = scale > 1 ? (outerWidth - 2) / scale : outerWidth
        return min(CGFloat(videoWidth) * (textDecor(.text).maxWidthFrac ?? 0.86), contentWidth - padding)
    }

    /// Wrap with a width per word, for a page whose marked words wear a
    /// larger face than their neighbours. Same rules as `wrap`.
    private func wrap(_ tokens: [String], widths: [CGFloat], space: CGFloat, lineBreaks: String) -> [String] {
        let available = maxTextWidth
        func width(_ range: Range<Int>) -> CGFloat {
            widths[range].reduce(0, +) + space * CGFloat(max(0, range.count - 1))
        }
        func text(_ range: Range<Int>) -> String { tokens[range].joined(separator: " ") }
        var rows: [Range<Int>] = []
        var start = 0
        for index in tokens.indices where index > start {
            let sentenceEnd = Self.endsRow(tokens[index - 1], lineBreaks: lineBreaks)
            if sentenceEnd || width(start..<index + 1) > available {
                rows.append(start..<index)
                start = index
            }
        }
        if start < tokens.count { rows.append(start..<tokens.count) }
        if rows.count == 2 && Self.balances(tokens, lineBreaks: lineBreaks) {
            var best = CGFloat.greatestFiniteMagnitude
            for index in 1..<tokens.count {
                let pair = [width(0..<index), width(index..<tokens.count)]
                if pair.allSatisfy({ $0 <= available }), abs(pair[0] - pair[1]) < best {
                    best = abs(pair[0] - pair[1])
                    rows = [0..<index, index..<tokens.count]
                }
            }
        }
        return rows.isEmpty ? [tokens.joined(separator: " ")] : rows.map(text)
    }

    struct EmphasisLineLayout {
        var scale: CGFloat
        var fonts: [[MeasuredFont]]
        var widths: [CGFloat]
        var space: CGFloat
        var width: CGFloat { widths.reduce(0, +) + space * CGFloat(max(0, widths.count - 1)) }
    }

    /// Measure actual word states, rather than reserving an emphasis-sized slot
    /// for every word. Scale typography, tracking and spaces together, keeping
    /// the chosen emphasis/text ratio and a shared baseline. Never enlarge a page.
    func emphasisLineLayout(for text: String, emphasis: [Int], alternateEmphasis: [Int] = [], fontSize: CGFloat? = nil) -> EmphasisLineLayout? {
        guard resolved.emphasis != "none",
              let minimum = (alternateEmphasis.isEmpty ? style : style.alternateEmphasisStyle).emphasisDecor?.resolvedFitLineMinimumScale else { return nil }
        let alternateEmphasis = resolved.hasAlternate ? alternateEmphasis : []
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.indices.contains(where: { emphasis.contains($0) }) else { return nil }
        let size = fontSize ?? baseSize
        let normal = measureFonts(size: size, includeEmphasis: false)
        let all = measureFonts(size: size)
        guard let emphatic = all.last else { return nil }
        let alternate = measureFonts(size: size, includeAlternate: true).last ?? emphatic
        let original = tokens.indices.map { index in
            alternateEmphasis.contains(index) ? [alternate] : emphasis.contains(index) ? [emphatic] : normal
        }
        let requestedWidth = (textDecor(.emphasis).maxWidthFrac ?? 0.86) * CGFloat(videoWidth)
        let outerWidth = CGFloat(videoWidth) * (safeArea?.rect.width ?? 1)
        let overshoot = CaptionAnimation.maximumScale(for: resolved.animation)
        let envelope = overshoot > 1 ? (outerWidth - 2) / overshoot : outerWidth
        let available = min(requestedWidth, envelope - CGFloat(max(18, videoWidth / 60) * 2))
        func layout(_ scale: CGFloat) -> EmphasisLineLayout {
            let fonts = original.map { values in values.map { value in
                MeasuredFont(font: CTFontCreateCopyWithAttributes(value.font, CTFontGetSize(value.font) * scale, nil, nil),
                             padding: value.padding * scale, kern: value.kern * scale, casing: value.casing)
            } }
            return EmphasisLineLayout(scale: scale, fonts: fonts,
                widths: tokens.indices.map { reservedWidth(tokens[$0], fonts: fonts[$0]) },
                space: spaceWidth(normal) * scale)
        }
        let full = layout(1)
        if full.width <= available { return full }
        guard layout(minimum).width <= available else { return nil }
        var low = CGFloat(minimum), high: CGFloat = 1
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if layout(middle).width <= available { low = middle } else { high = middle }
        }
        return layout(low)
    }

    private var fitsEmphasisLine: Bool { style.emphasisDecor?.resolvedFitLineMinimumScale != nil }

    func rowCount(for text: String) -> Int {
        // Pagination stays independent of automatic keyword selection, so
        // enabling emphasis cannot change the surrounding non-emphasis pages.
        wrap(text, fonts: measureFonts(size: baseSize, includeEmphasis: !fitsEmphasisLine)).count
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
        let height = Int(ceil(Self.maxAscent(fonts) + Self.maxDescent(fonts)))
        let advance = style.resolvedLineSpacing.map { Int(($0 * CGFloat(videoWidth) / 1080).rounded()) }
            ?? (height + max(4, Int(size) / 6))
        let contentHeight = height + advance + max(10, Int(size) / 4) * 2
        let contentWidth = Int(maxTextWidth) + max(18, videoWidth / 60) * 2
        let overshoot = (CaptionAnimation.maximumScale(for: resolved.animation) - 1) / 2
        let motionX = Int(ceil(Double(contentWidth) * overshoot))
        let motionY = overshoot > 0 ? Int(ceil(Double(contentHeight) * overshoot))
            : (resolved.animation == "slide-up" ? Int(ceil(24 * Double(videoWidth) / 1080)) : 0)
        let box = RenderedCaption(pngURL: URL(fileURLWithPath: "/"),
                                  width: contentWidth + motionX * 2, height: contentHeight + motionY * 2)
        let origin = position(for: box, positionOverride: positionOverride)
        return CGRect(x: origin.x, y: origin.y, width: box.width, height: box.height)
    }

    /// The second emphasis look keeps its typography during a colour highlight,
    /// just as fitted primary emphasis does. Other highlight modes still win.
    func wordState(at index: Int, activeIndex: Int?, emphasis: [Int], alternateEmphasis: [Int] = [],
                   fitted: Bool = false) -> CaptionStyle.WordState {
        let alternate = resolved.hasAlternate && alternateEmphasis.contains(index)
        let marked = emphasis.contains(index) && resolved.emphasis != "none"
            && (alternate ? resolved.alternateEmphasis : resolved.emphasis) != "none"
        let keepsColor = alternate ? resolved.alternateKeepsColor : resolved.emphasisKeepsColor
        if marked && (fitted || keepsColor || (alternate && resolved.highlight == "color")) {
            return alternate ? .emphasis2 : .emphasis
        }
        if index == activeIndex && resolved.highlight != "none" { return .highlight }
        return marked ? (alternate ? .emphasis2 : .emphasis) : .text
    }

    // MARK: - Rendering

    /// Render one caption to a PNG in `directory`. Font size defaults to
    /// max(36, videoW / 22); explicit `fontSize` overrides (text overlays).
    func render(text: String, activeIndex: Int? = nil, emphasis: [Int] = [], alternateEmphasis: [Int] = [],
                textColor: String? = nil, highlightColor: String? = nil, frame: CaptionAnimation.Frame = .init(), to directory: URL,
                fontSize explicitSize: CGFloat? = nil) throws -> RenderedCaption {
        let alternateEmphasis = resolved.hasAlternate ? alternateEmphasis : []
        let pageHighlightColor = highlightColor ?? resolved.highlightColor
        var fontSize = explicitSize ?? baseSize
        let fitted = emphasisLineLayout(for: text, emphasis: emphasis, alternateEmphasis: alternateEmphasis, fontSize: fontSize)
        let includeEmphasis = !fitsEmphasisLine || !emphasis.isEmpty
        // A marked word on a page that is not fitted to one line takes its
        // own width; the other words keep theirs, so the page wraps as it
        // would unmarked. Styles with neither a line fit nor a second look
        // keep the one shared slot width they always had.
        let ownSlots = fitted == nil && !emphasis.isEmpty && resolved.emphasis != "none"
            && (!alternateEmphasis.isEmpty || fitsEmphasisLine)
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var alternateFonts: [MeasuredFont] = []
        var emphasisFonts: [MeasuredFont] = []
        func slotWidths(_ fonts: [MeasuredFont]) -> [CGFloat] {
            tokens.indices.map {
                reservedWidth(tokens[$0], fonts: alternateEmphasis.contains($0) ? alternateFonts
                              : emphasis.contains($0) ? emphasisFonts : fonts)
            }
        }
        func rows(_ fonts: [MeasuredFont], lineBreaks: String? = nil) -> [String] {
            guard ownSlots else { return wrap(text, fonts: fonts, lineBreaks: lineBreaks) }
            return wrap(tokens, widths: slotWidths(fonts), space: spaceWidth(fonts), lineBreaks: lineBreaks ?? resolved.lineBreaks)
        }
        func measure() -> [MeasuredFont] {
            if ownSlots {
                emphasisFonts = measureFonts(size: fontSize).suffix(1)
                alternateFonts = alternateEmphasis.isEmpty ? []
                    : measureFonts(size: fontSize, includeEmphasis: false, includeAlternate: true).suffix(1)
            }
            return measureFonts(size: fontSize, includeEmphasis: ownSlots ? false : includeEmphasis)
        }
        let initialFonts = measure()
        let longest = (ownSlots ? slotWidths(initialFonts) : tokens.map { reservedWidth($0, fonts: initialFonts) }).max() ?? 0
        if fitted == nil && longest > maxTextWidth { fontSize *= maxTextWidth / longest }
        var fonts = fitted?.fonts.flatMap { $0 } ?? measure()
        var lines = fitted == nil ? rows(fonts) : [tokens.joined(separator: " ")]
        // Input-limit fallback can merge several sentences onto one page.
        // Mandatory sentence rows cannot be reduced by shrinking the font.
        let fallbackBreaks = lines.count > 2 && ["sentence", "clause"].contains(resolved.lineBreaks) ? "greedy" : nil
        if let fallbackBreaks { lines = rows(fonts, lineBreaks: fallbackBreaks) }
        // Static fallback may regroup many one-word pages. Keep that page in
        // two rows too, without dropping words or exceeding the video width.
        while lines.count > 2 && fontSize > 1 {
            fontSize *= 0.9
            fonts = measure()
            lines = rows(fonts, lineBreaks: fallbackBreaks)
        }
        let ownWidths = ownSlots ? slotWidths(fonts) : []
        func rowWidth(_ row: Int) -> CGFloat {
            guard ownSlots else { return reservedLineWidth(lines[row], fonts: fonts) }
            let first = lines[..<row].reduce(0) { $0 + $1.split(separator: " ").count }
            let count = lines[row].split(separator: " ").count
            return ownWidths[first..<first + count].reduce(0, +) + spaceWidth(fonts) * CGFloat(max(0, count - 1))
        }

        let padX = resolved.paddingX.map { Int(ceil(fontSize * $0)) } ?? max(18, videoWidth / 60)
        let padY = resolved.paddingY.map { Int(ceil(fontSize * $0)) } ?? max(10, Int(fontSize) / 4)
        var lineGap = max(4, Int(fontSize) / 6) + Int(fontSize * ((textDecor(.text).lineHeight ?? 1) - 1))
        let ascent = Self.maxAscent(fonts)
        let descent = Self.maxDescent(fonts)
        let lineHeight = Int((ascent + descent).rounded(.up))
        if let spacing = resolved.lineSpacing {
            lineGap = Int((spacing * CGFloat(videoWidth) / 1080 * fontSize / baseSize).rounded()) - lineHeight
        }

        // A larger word rises out of its row. Between two rows that would
        // put it on top of the neighbour, so the gap above a row grows by its
        // tallest word's extra ascent and by the extra descent of the row
        // before it. Rows without a larger word keep their rhythm.
        var rowDrop = [CGFloat](repeating: 0, count: lines.count)
        if ownSlots && lines.count > 1 {
            var rise = rowDrop, sink = rowDrop, index = 0
            for (row, line) in lines.enumerated() {
                for _ in line.split(separator: " ") {
                    defer { index += 1 }
                    guard emphasis.contains(index) else { continue }
                    let alternate = alternateEmphasis.contains(index)
                    guard (alternate ? resolved.alternateEmphasis : resolved.emphasis) != "none" else { continue }
                    let own = alternate ? alternateFonts : emphasisFonts
                    rise[row] = max(rise[row], Self.maxAscent(own) - ascent)
                    sink[row] = max(sink[row], Self.maxDescent(own) - descent)
                }
            }
            for row in lines.indices.dropFirst() {
                rowDrop[row] = rowDrop[row - 1] + (rise[row] + sink[row - 1]).rounded(.up)
            }
        }

        let maxLineWidth = fitted?.width ?? lines.indices.map { rowWidth($0) }.max() ?? 0
        let textHeight = lineHeight * lines.count + lineGap * (lines.count - 1) + Int(rowDrop.last ?? 0)
        let contentWidth = min(videoWidth, Int(maxLineWidth.rounded(.up)) + padX * 2)
        let contentHeight = textHeight + padY * 2
        // A fixed envelope for every frame, including the steady image.
        let overshoot = (CaptionAnimation.maximumScale(for: resolved.animation) - 1) / 2
        let motionX = Int(ceil(Double(contentWidth) * overshoot))
        let motionY = overshoot > 0 ? Int(ceil(Double(contentHeight) * overshoot))
            : (resolved.animation == "slide-up" ? Int(ceil(24 * Double(videoWidth) / 1080)) : 0)
        let effects = resolved.states.map { textDecor($0) } + [resolved.page]
        let effectFontSize = (fonts + alternateFonts + emphasisFonts).map { CTFontGetSize($0.font) }.max() ?? fontSize
        let effectInset = (resolved.hasTextDecor ? Int(ceil(effects.map { d in
            let border = d.borderOn == true ? (d.borderWidth ?? 2) * CGFloat(videoWidth) / 1080 : 0
            // Hard and extrude ignore blur; a glow spreads about three blur radii.
            let blur = d.shadowStyle == "soft" ? (d.shadowBlur ?? 0) * 2 : d.shadowStyle == "glow" ? (d.shadowBlur ?? 0.3) * 3 : 0
            let offset = d.shadowStyle == "glow" ? 0 : max(abs(d.shadowX ?? 0), abs(d.shadowY ?? 0))
            let shadow = d.shadowOn == true ? effectFontSize * (offset + blur) : 0
            return border + shadow + (d.strokeOn == true ? (d.strokeWidth ?? 1) * CGFloat(videoWidth) / 1080 : 0)
        }.max() ?? 0)) : 0)
        // The larger word keeps the rows' rhythm and rises out of its row.
            + Int(ceil(max(0, Self.maxAscent(alternateFonts + emphasisFonts) - ascent, Self.maxDescent(alternateFonts + emphasisFonts) - descent)))
        let boxWidth = contentWidth + (motionX + effectInset) * 2
        let boxHeight = contentHeight + (motionY + effectInset) * 2

        let colorSpace = resolved.srgb
            ? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            : CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: boxWidth, height: boxHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let pageFrame = frame.wordIndex == nil ? frame : CaptionAnimation.Frame()
        context.translateBy(x: CGFloat(boxWidth) / 2, y: CGFloat(boxHeight) / 2 - pageFrame.offsetY * CGFloat(videoWidth) / 1080)
        context.scaleBy(x: pageFrame.scale, y: pageFrame.scale)
        context.translateBy(x: -CGFloat(contentWidth) / 2, y: -CGFloat(contentHeight) / 2)
        context.setAlpha(pageFrame.alpha)
        if pageFrame.alpha < 1 { context.beginTransparencyLayer(auxiliaryInfo: nil) }

        func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
            let (r, g, b) = Self.parseHexColor(hex, fallback: (1, 1, 1))
            return CGColor(red: r, green: g, blue: b, alpha: alpha)
        }
        let painter = TextDecorPainter(scale: CGFloat(videoWidth) / 1080, usesSRGB: resolved.srgb)
        let pageDecor = resolved.page
        if pageDecor.bgPerLine != true {
            painter.background(in: context, rect: CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
                decor: pageDecor, radius: resolved.automaticRadius
                    ? CGFloat(max(6, Int(fontSize) / 6)) : nil)
        }

        var tokenIndex = 0
        for (lineIndex, lineText) in lines.enumerated() {
            let width = fitted?.width ?? rowWidth(lineIndex)
            let x = Self.lineOrigin(width: width, boxWidth: CGFloat(contentWidth),
                                    padding: CGFloat(padX), alignment: textDecor(.text).alignment)
            let baselineY = CGFloat(contentHeight - padY - (lineIndex + 1) * lineHeight - lineIndex * lineGap) + descent
                - rowDrop[lineIndex]
            if pageDecor.bgPerLine == true {
                painter.background(in: context,
                    rect: CGRect(x: x, y: baselineY - descent, width: width, height: CGFloat(lineHeight))
                        .insetBy(dx: -fontSize * (pageDecor.bgPaddingX ?? 0.125), dy: -fontSize * (pageDecor.bgPaddingY ?? 0.125)),
                    decor: pageDecor)
            }
            let space = fitted?.space ?? spaceWidth(fonts)
            var cursor = x
            for token in lineText.split(separator: " ").map(String.init) {
                let active = tokenIndex == activeIndex
                let alternate = alternateEmphasis.contains(tokenIndex)
                let lookEmphasis = alternate ? resolved.alternateEmphasis : resolved.emphasis
                let emphasised = emphasis.contains(tokenIndex) && resolved.emphasis != "none" && lookEmphasis != "none"
                let emphasisState: CaptionStyle.WordState = alternateEmphasis.contains(tokenIndex) ? .emphasis2 : .emphasis
                let state = wordState(at: tokenIndex, activeIndex: activeIndex, emphasis: emphasis,
                                      alternateEmphasis: alternateEmphasis, fitted: fitted != nil)
                let decor = wordDecor(state)
                var drawFont = stateFont(state, size: fontSize * (fitted?.scale ?? 1))
                if usesLegacyDecorations && state == .highlight && resolved.highlight != "scale"
                    && emphasised && ["scale", "both"].contains(resolved.emphasis) {
                    drawFont = resolveFont(size: fontSize * 1.12, family: resolved.highlightFont)
                }
                let wordKern = (usesLegacyDecorations ? kern(for: .text) : kern(for: state)) * (fitted?.scale ?? 1)
                let reserved = fitted?.widths[tokenIndex] ?? (ownSlots ? ownWidths[tokenIndex] : reservedWidth(token, fonts: fonts))
                if let visible = frame.visibleWords, tokenIndex >= visible {
                    cursor += reserved + space
                    tokenIndex += 1
                    continue
                }
                let token = TextCasing.apply(token, casing: textDecor(state).casing, firstWord: tokenIndex == 0)
                let bounds = wordBounds(token, font: drawFont, kern: wordKern)
                let drawWidth = lineWidth(token, font: drawFont, kern: wordKern)
                let tokenX = cursor + (reserved - bounds.width) / 2 - bounds.minX
                var fill = textColor ?? resolved.color
                if emphasised && ["color", "both"].contains(lookEmphasis) {
                    fill = alternate ? resolved.alternateColor : resolved.emphasisColor
                }
                let keepsColor = emphasised && (alternate ? resolved.alternateKeepsColor : resolved.emphasisKeepsColor)
                if active && resolved.highlight == "color" && !keepsColor { fill = pageHighlightColor }
                let box = state == .highlight && resolved.highlight == "box"
                if box { fill = pageHighlightColor }
                var paint = textDecor(state)
                if let fitted { paint.letterSpacing = (paint.letterSpacing ?? 0) * fitted.scale }
                if let grown = frame.glow[tokenIndex], paint.shadowOn == true, paint.shadowStyle == "glow" {
                    // The halo widens and brightens together as it grows in.
                    if grown <= 0 { paint.shadowOn = false }
                    else {
                        paint.shadowOpacity = (paint.shadowOpacity ?? 1) * grown
                        paint.shadowBlur = (paint.shadowBlur ?? 0.3) * (0.35 + 0.65 * grown)
                    }
                }
                if !resolved.hasTextDecor { paint.color = fill }
                else if let textColor, state == .text { paint.color = textColor }
                if state == .highlight && resolved.highlight == "color",
                   highlightColor != nil || resolved.cyclesHighlight {
                    paint.color = pageHighlightColor
                }
                if (fitted != nil || emphasisState == .emphasis2) && emphasised && active && resolved.highlight == "color" && !keepsColor {
                    paint.color = pageHighlightColor
                }
                var backgroundRect: CGRect?
                var radius: CGFloat?
                if !resolved.hasTextDecor {
                    paint.shadowY = -2 / CTFontGetSize(drawFont)
                    paint.shadowBlur = 4 / CTFontGetSize(drawFont)
                }
                if box && decor.bgColor == nil && !(state == .highlight && resolved.highlightHasBackgroundColor) {
                    paint.bgColor = pageHighlightColor
                    paint.bgOpacity = 1
                    let (r, g, b) = Self.parseHexColor(pageHighlightColor, fallback: (1, 0.84, 0))
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
                let entering = tokenIndex == frame.wordIndex
                if entering {
                    context.saveGState()
                    let center = CGPoint(x: tokenX + drawWidth / 2, y: baselineY + (ascent - descent) / 2)
                    context.translateBy(x: center.x, y: center.y - frame.offsetY * CGFloat(videoWidth) / 1080)
                    context.scaleBy(x: frame.scale, y: frame.scale)
                    context.translateBy(x: -center.x, y: -center.y)
                    context.setAlpha(frame.alpha)
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                }
                painter.draw(token, font: drawFont, at: CGPoint(x: tokenX, y: baselineY), decor: paint,
                             in: context, backgroundRect: backgroundRect, radius: radius)
                if entering { context.endTransparencyLayer(); context.restoreGState() }
                cursor += reserved + space
                tokenIndex += 1
            }
        }

        if pageFrame.alpha < 1 { context.endTransparencyLayer() }
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
        // A position the user dragged to in the preview: centred on the point
        // and kept inside the frame. Safe area only resizes the frame the
        // Auto and corner choices use; a hand placement is left alone.
        if let custom = CustomPosition(positionOverride) {
            return customOrigin(custom, caption: caption, respectSafeArea: false)
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
            return customOrigin(custom, caption: caption, respectSafeArea: false)
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
