import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Renders builder text overlays to full-frame transparent PNGs — the Core
/// Text port of video.py's Pillow _render_text_image(). The PNG is the size
/// of the video (1080x1920) and gets overlaid at 0:0, so slide/fade filter
/// expressions work on the whole frame exactly like the Python pipeline.
///
/// Style flair on top of the Pillow parity: outline stroke, drop shadow,
/// `*starred*` words in a highlight color, and partial renders (only the
/// first N words visible, layout unchanged) for the word-reveal animation.
nonisolated struct TextOverlayRenderer {
    var videoWidth = 1080
    var videoHeight = 1920
    /// Platform chrome to stay clear of; name tags retain their planned placement.
    var safeArea: PlatformSafeArea? = PlatformSafeArea.resolve(RenderContext.settings)

    /// A box centre and size IN PIXELS moved into the safe area. The safe
    /// area works in frame fractions, so everything converts on the way in
    /// and back out; feeding it pixels clamps every box to the top-left
    /// corner (the 1.101 Express overlay bug).
    func clamped(centerX: Double, centerY: Double, width: Double, height: Double) -> (x: Double, y: Double) {
        guard let safeArea, videoWidth > 0, videoHeight > 0 else { return (centerX, centerY) }
        let w = Double(videoWidth), h = Double(videoHeight)
        let center = safeArea.clampedCenter(x: centerX / w, y: centerY / h, width: width / w, height: height / h)
        return (center.x * w, center.y * h)
    }

    // MARK: - Markup

    /// One display word; `*starred*` words render in the highlight color.
    struct Word {
        var text: String
        var highlighted: Bool
        var index: Int
    }

    /// Split text into words, consuming `*...*` emphasis markup (a span may
    /// cover several words). Stars are stripped from the rendered text.
    static func parseMarkup(_ text: String) -> [Word] {
        var words: [Word] = []
        var highlighting = false
        for token in text.split(separator: " ") {
            var word = String(token)
            var highlighted = highlighting
            if word.hasPrefix("*") {
                word.removeFirst()
                highlighted = true
                highlighting = true
            }
            if word.hasSuffix("*") {
                word.removeLast()
                highlighting = false
            }
            guard !word.isEmpty else { continue }
            words.append(Word(text: word, highlighted: highlighted, index: words.count))
        }
        return words
    }

    static func plainText(_ words: [Word]) -> String {
        words.map(\.text).joined(separator: " ")
    }

    static func wordCount(_ text: String) -> Int {
        parseMarkup(text).count
    }

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

    static func cgColor(_ string: String?, fallback: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)) -> CGColor {
        let (r, g, b) = parseColor(string, fallback: fallback)
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    func resolveFont(size: CGFloat, family: String?, bold: Bool, italic: Bool) -> CTFont {
        let base = CTFontCreateWithName((family?.isEmpty == false ? family! : "Helvetica Neue") as CFString,
                                        size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    // MARK: - Measurement

    func line(_ text: String, font: CTFont) -> CTLine {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            // Without this Core Text fills with attribute black and ignores
            // the context fill/stroke colors the hero passes set.
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        return CTLineCreateWithAttributedString(attributed)
    }

    func lineWidth(_ text: String, font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font: font), nil, nil, nil))
    }

    /// Word-wrap to a pixel width (port of _wrap_text, over markup words),
    /// and to the item's words-per-line cap when it has one.
    private func wrap(_ words: [Word], font: CTFont, maxWidth: CGFloat, maxWords: Int? = nil) -> [[Word]] {
        Self.lines(words, maxWords: maxWords) { lineWidth(Self.plainText($0), font: font) <= maxWidth }
    }

    /// Greedy line breaking: a word joins the current line while the line
    /// still `fits` and stays under `maxWords` (nil = no word cap). Pure, so
    /// the cap is testable without fonts.
    static func lines(_ words: [Word], maxWords: Int?, fits: ([Word]) -> Bool) -> [[Word]] {
        guard !words.isEmpty else { return [] }
        let cap = maxWords.map { max(1, $0) }
        var lines: [[Word]] = []
        var current = [words[0]]
        for word in words.dropFirst() {
            if let cap, current.count >= cap {
                lines.append(current)
                current = [word]
            } else if fits(current + [word]) {
                current.append(word)
            } else {
                lines.append(current)
                current = [word]
            }
        }
        lines.append(current)
        return lines
    }

    // MARK: - Rendering

    /// Render one overlay item to a full-frame PNG in `directory`. With
    /// `visibleWords`, only the first N words are drawn — at the positions
    /// they hold in the full layout — so successive renders animate a
    /// word-by-word reveal without any reflow.
    func render(_ item: TextOverlayItem, to directory: URL, visibleWords: Int? = nil) throws -> URL {
        if item.keepsPlacement, safeArea != nil {
            // Placed by hand (Express overlay, watermark): never nudged clear of platform chrome.
            var exact = self
            exact.safeArea = nil
            return try exact.render(item, to: directory, visibleWords: visibleWords)
        }
        let width = videoWidth
        let height = videoHeight
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let words = Self.parseMarkup(item.text)

        // Whole-element opacity: a transparency layer applies one alpha to
        // the composed result (box + outline + shadow + glyphs) instead of
        // multiplying each part's own alpha.
        let elementAlpha = CGFloat(min(1, max(0, item.opacity)))
        if elementAlpha < 1 {
            context.setAlpha(elementAlpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        switch item.design {
        case "grapplingCard", "roundCard":
            drawStrikeStats(in: context, item: item)
        case "nameTag":
            drawNameTag(in: context, item: item)
        case "hero":
            drawHero(in: context, item: item, words: words, visibleWords: visibleWords)
        case "tag":
            drawTag(in: context, item: item, words: words, visibleWords: visibleWords)
        default:
            if let box = fittedInput(item) {
                drawFittedBox(in: context, item: item, words: words, visibleWords: visibleWords,
                              boxWidth: box.width, boxHeight: box.height, centerX: box.centerX, centerY: box.centerY)
            } else {
                drawLegacy(in: context, item: item, words: words, visibleWords: visibleWords)
            }
        }
        if elementAlpha < 1 {
            context.endTransparencyLayer()
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

    /// Shared by the planner and drawing: sizes are canvas pixels, fontsize is
    /// always in the overlay's 1920-high design space. Template sizes do not apply.
    struct NameTagLayout {
        var fontSize: Int
        var lines: [String]
        var fonts: [CTFont]
        var size: CGSize
        var padding: CGFloat
        var lineGap: CGFloat
        var geometry: TagLayout.Result? = nil
    }

    func nameTagLayout(_ item: TextOverlayItem, maxWidth: CGFloat, imageAspects: [UUID: CGFloat] = [:]) -> NameTagLayout {
        if let style = item.tagStyle {
            return styledNameTagLayout(item, style: style, maxWidth: maxWidth, aspects: imageAspects)
        }
        let scale = CGFloat(videoHeight) / 1920
        let lines = Array(item.text.components(separatedBy: "\n").prefix(2))
        var designSize = max(22, item.fontsize)
        func metrics(_ size: Int) -> (fonts: [CTFont], padding: CGFloat, width: CGFloat) {
            let pixels = CGFloat(size) * scale
            let fonts = lines.indices.map {
                resolveFont(size: pixels * ($0 == 0 ? 1 : 0.72), family: item.fontfamily,
                            bold: item.bold, italic: item.italic)
            }
            let padding = ceil(pixels * max(0.24, CGFloat(item.strokeWidthEm)))
            let width = lines.indices.map { lineWidth(lines[$0], font: fonts[$0]) }.max() ?? 0
            return (fonts, padding, ceil(width + padding * 2))
        }
        var measured = metrics(designSize)
        while designSize > 22 && measured.width > maxWidth {
            designSize -= 1
            measured = metrics(designSize)
        }
        let available = max(0, maxWidth - measured.padding * 2)
        let fitted = lines.indices.map { index -> String in
            var text = lines[index]
            guard lineWidth(text, font: measured.fonts[index]) > available else { return text }
            while !text.isEmpty && lineWidth(text + "…", font: measured.fonts[index]) > available {
                text.removeLast()
            }
            return lineWidth("…", font: measured.fonts[index]) <= available ? text + "…" : ""
        }
        let gap = CGFloat(designSize) * scale * 0.12
        let height = measured.fonts.reduce(CGFloat.zero) { $0 + CTFontGetAscent($1) + CTFontGetDescent($1) }
            + gap * CGFloat(max(0, lines.count - 1)) + measured.padding * 2
        return NameTagLayout(fontSize: designSize, lines: fitted, fonts: measured.fonts,
            size: CGSize(width: min(maxWidth, measured.width), height: ceil(height)),
            padding: measured.padding, lineGap: gap)
    }

    /// The planner owns placement, including explicit corners outside safe areas.
    private func drawNameTag(in context: CGContext, item: TextOverlayItem) {
        if let style = item.tagStyle {
            drawStyledNameTag(in: context, item: item, style: style)
            return
        }
        let box = item.normalizedBox
        let rect = CGRect(x: box.minX * Double(videoWidth), y: box.minY * Double(videoHeight),
                          width: box.width * Double(videoWidth), height: box.height * Double(videoHeight))
        guard rect.width > 0, rect.height > 0 else { return }
        // Undo insignificant normalized-coordinate roundoff before fitting again.
        let layout = nameTagLayout(item, maxWidth: rect.width + 0.00001)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(x: rect.minX, y: CGFloat(videoHeight) - rect.maxY,
                               width: rect.width, height: rect.height))
        if item.boxOpacity > 0 {
            // fillRoundedBackground adds 5px itself; include that in our bounds.
            fillRoundedBackground(in: context, item: item,
                topLeft: (Int(rect.minX) + 5, Int(rect.minY) + 5),
                size: (max(0, Int(rect.width) - 10), max(0, Int(rect.height) - 10)))
        }
        var top = rect.minY + layout.padding
        for index in layout.lines.indices {
            let font = layout.fonts[index]
            // Names are literal, not template emphasis markup.
            let words = [Word(text: layout.lines[index], highlighted: false, index: 0)]
            drawStyledLine(words, font: font, item: item, visibleWords: nil, in: context,
                           x: rect.minX + layout.padding, baselineFromTop: top + CTFontGetAscent(font))
            top += CTFontGetAscent(font) + CTFontGetDescent(font) + layout.lineGap
        }
    }

    /// WYSIWYG mode. Text that fits its box at the design size auto-fits the
    /// largest font whose wrapped lines fill the box (port of the
    /// w_frac/h_frac branch, binary search and 0.15em line spacing). Text
    /// that overflows keeps its design size and grows the box toward the
    /// side opposite its alignment (left-aligned grows right, right-aligned
    /// grows left, centred grows both ways) until the frame margin; what
    /// still does not fit wraps to further rows, growing the box downward
    /// (upward when the frame's bottom is near). Only when even the frame
    /// cannot hold the wrapped block does the text shrink.
    private func drawFittedBox(in context: CGContext, item: TextOverlayItem,
                               words: [Word], visibleWords: Int?,
                               boxWidth: Int, boxHeight: Int, centerX: Int, centerY: Int) {
        guard !words.isEmpty else { return }
        let layout = Self.fittedLayout(item: item, words: words, boxWidth: boxWidth, boxHeight: boxHeight,
                                       centerX: centerX, centerY: centerY,
                                       videoWidth: videoWidth, videoHeight: videoHeight,
                                       measure: { size, maxWidth in self.metrics(item: item, words: words, size: size, maxWidth: maxWidth) })
        if item.boxOpacity > 0 {
            fillRoundedBackground(in: context, item: item,
                                  topLeft: (layout.boxLeft, layout.boxTop), size: (layout.boxWidth, layout.boxHeight))
        }
        let m = layout.metrics
        var cursorTop = CGFloat(layout.boxTop) + (CGFloat(layout.boxHeight) - m.totalHeight) / 2
        let ascent = CTFontGetAscent(m.font)
        for lineWords in m.lines {
            let width = lineWidth(Self.plainText(lineWords), font: m.font)
            let x = Self.alignedX(boxLeft: CGFloat(layout.boxLeft), boxWidth: CGFloat(layout.boxWidth),
                                  lineWidth: width, alignment: item.alignment)
            drawStyledLine(lineWords, font: m.font, item: item, visibleWords: visibleWords,
                           in: context, x: x, baselineFromTop: cursorTop + ascent)
            cursorTop += m.lineHeight + m.spacing
        }
    }

    struct LineMetrics {
        var font: CTFont
        var lines: [[Word]]
        var lineHeight: CGFloat
        var spacing: CGFloat
        var totalHeight: CGFloat
        var maxWidth: CGFloat
    }

    private func metrics(item: TextOverlayItem, words: [Word], size: CGFloat, maxWidth: CGFloat) -> LineMetrics {
        let font = resolveFont(size: size, family: item.fontfamily, bold: item.bold, italic: item.italic)
        let lines = wrap(words, font: font, maxWidth: maxWidth, maxWords: item.resolvedWordsPerLine)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font)
        let spacing = (size * 0.15).rounded(.down)
        let total = lineHeight * CGFloat(lines.count) + spacing * CGFloat(max(0, lines.count - 1))
        let maxLineWidth = lines.map { lineWidth(Self.plainText($0), font: font) }.max() ?? 0
        return LineMetrics(font: font, lines: lines, lineHeight: lineHeight, spacing: spacing,
                           totalHeight: total, maxWidth: maxLineWidth)
    }

    /// Background box padding around a fitted or legacy line, in canvas pixels.
    static let boxPadding = 5

    /// The box the fitted path lays text out in, in canvas pixels: the
    /// item's w/h fractions centred on its x/y (moved into the safe area).
    /// A hand-placed box (`lockedWidth`) is the visible background box, so
    /// the text box is inset by the background padding. nil when the item
    /// has no box (legacy single line).
    func fittedInput(_ item: TextOverlayItem) -> (width: Int, height: Int, centerX: Int, centerY: Int)? {
        guard let wFrac = item.wFrac, let hFrac = item.hFrac,
              let xFrac = item.xFrac, let yFrac = item.yFrac, wFrac > 0, hFrac > 0 else { return nil }
        var placer = self
        if item.keepsPlacement { placer.safeArea = nil }
        let width = Double(videoWidth) * wFrac, height = Double(videoHeight) * hFrac
        let center = placer.clamped(centerX: Double(videoWidth) * xFrac, centerY: Double(videoHeight) * yFrac,
                                    width: width, height: height)
        let inset = item.resolvedLockedWidth ? Double(Self.boxPadding * 2) : 0
        return (max(1, Int(width - inset)), max(1, Int(height - inset)), Int(center.x), Int(center.y))
    }

    /// The footprint an item draws, in canvas pixels from the top left:
    /// the background box of a fitted or legacy item (the text bounds when
    /// it draws no box, except a hand-placed box, which is always the box),
    /// the headline block plus kicker of a hero, the bar of a tag. nil for
    /// designs that lay themselves out (name tags, strike stats).
    func renderedBox(_ item: TextOverlayItem) -> CGRect? {
        if item.keepsPlacement, safeArea != nil {
            // Mirrors `render`: placed by hand, never nudged clear of platform chrome.
            var exact = self
            exact.safeArea = nil
            return exact.renderedBox(item)
        }
        let words = Self.parseMarkup(item.text)
        let pad = CGFloat(Self.boxPadding)
        func padded(_ rect: CGRect) -> CGRect {
            item.boxOpacity > 0 || item.resolvedLockedWidth ? rect.insetBy(dx: -pad, dy: -pad) : rect
        }
        switch item.design {
        case "grapplingCard", "roundCard", "nameTag":
            return nil
        case "hero":
            guard !words.isEmpty else { return nil }
            let geometry = heroGeometry(item: item, words: words)
            var rect = CGRect(x: geometry.centerX - Double(geometry.metrics.maxWidth) / 2,
                              y: geometry.blockTop, width: Double(geometry.metrics.maxWidth), height: Double(geometry.metrics.totalHeight))
            if let kicker = heroKicker(item: item, headlineSize: geometry.headlineSize) {
                rect = rect.union(CGRect(x: geometry.centerX - Double(kicker.barWidth) / 2,
                                         y: geometry.blockTop - Double(kicker.gap + kicker.barHeight),
                                         width: Double(kicker.barWidth), height: Double(kicker.barHeight)))
            }
            return rect
        case "tag":
            guard !words.isEmpty else { return nil }
            let geometry = tagGeometry(item: item, words: words)
            let stripe = geometry.barHeight * 0.16
            return CGRect(x: geometry.centerX - Double(geometry.barWidth) / 2 - Double(stripe) * 1.4,
                          y: geometry.centerY - Double(geometry.barHeight) / 2,
                          width: Double(geometry.barWidth) + Double(stripe) * 1.4, height: Double(geometry.barHeight))
        default:
            if let box = fittedInput(item) {
                guard !words.isEmpty else {
                    return padded(CGRect(x: box.centerX - box.width / 2, y: box.centerY - box.height / 2,
                                         width: box.width, height: box.height))
                }
                let layout = Self.fittedLayout(item: item, words: words, boxWidth: box.width, boxHeight: box.height,
                                               centerX: box.centerX, centerY: box.centerY,
                                               videoWidth: videoWidth, videoHeight: videoHeight,
                                               measure: { size, maxWidth in self.metrics(item: item, words: words, size: size, maxWidth: maxWidth) })
                return padded(CGRect(x: layout.boxLeft, y: layout.boxTop, width: layout.boxWidth, height: layout.boxHeight))
            }
            guard !words.isEmpty else { return nil }
            let line = legacyLayout(item: item, words: words)
            return padded(CGRect(x: Int(line.x), y: Int(line.top),
                                 width: Int(line.width.rounded(.up)), height: Int(line.height.rounded(.up))))
        }
    }

    /// The box a fitted item finally occupies, in pixels, plus its lines.
    struct FittedLayout {
        var boxLeft: Int
        var boxTop: Int
        var boxWidth: Int
        var boxHeight: Int
        var metrics: LineMetrics
        var grew: Bool
    }

    /// The left x of a line inside a box for an alignment name.
    static func alignedX(boxLeft: CGFloat, boxWidth: CGFloat, lineWidth: CGFloat, alignment: String) -> CGFloat {
        switch alignment {
        case "left": boxLeft
        case "right": boxLeft + boxWidth - lineWidth
        default: boxLeft + (boxWidth - lineWidth) / 2
        }
    }

    /// Pure layout for the fitted box; `measure(size, maxWidth)` wraps and
    /// measures the item's words at a font size. A hand-placed box
    /// (`lockedWidth`) never changes the font: the words wrap at the box
    /// width at the design size and the box grows downward to hold the
    /// rows (an unbreakable token wider than the box just overflows it).
    static func fittedLayout(item: TextOverlayItem, words: [Word], boxWidth: Int, boxHeight: Int,
                             centerX: Int, centerY: Int, videoWidth: Int, videoHeight: Int,
                             measure: (CGFloat, CGFloat) -> LineMetrics) -> FittedLayout {
        var boxLeft = centerX - boxWidth / 2
        var boxTop = centerY - boxHeight / 2
        var boxWidth = boxWidth
        var boxHeight = boxHeight
        let margin = Int((Double(videoWidth) * 0.02).rounded())
        let designSize = max(6, (CGFloat(item.fontsize) * CGFloat(videoHeight) / 1920).rounded())

        if item.resolvedLockedWidth {
            let m = measure(designSize, CGFloat(boxWidth))
            var grew = false
            // A single word wider than the box: the box widens to hold it
            // (away from the aligned edge) rather than the font shrinking.
            let neededWidth = Int(m.maxWidth.rounded(.up))
            if neededWidth > boxWidth {
                grew = true
                switch item.alignment {
                case "left": break
                case "right": boxLeft -= neededWidth - boxWidth
                default: boxLeft -= (neededWidth - boxWidth) / 2
                }
                boxWidth = neededWidth
            }
            let neededHeight = Int(m.totalHeight.rounded(.up))
            if neededHeight > boxHeight {
                grew = true
                let bottomLimit = videoHeight - margin
                if boxTop + neededHeight > bottomLimit { boxTop = max(margin, bottomLimit - neededHeight) }
                boxHeight = neededHeight
            }
            return FittedLayout(boxLeft: boxLeft, boxTop: boxTop, boxWidth: boxWidth, boxHeight: boxHeight,
                                metrics: m, grew: grew)
        }

        let single = measure(designSize, .greatestFiniteMagnitude)
        var grew = false

        if single.maxWidth > CGFloat(boxWidth) || single.lineHeight > CGFloat(boxHeight) {
            grew = true
            // Widen toward the side opposite the alignment, up to the margin.
            let needed = Int(single.maxWidth.rounded(.up))
            let minLeft = margin, maxRight = videoWidth - margin
            var left = boxLeft, right = boxLeft + boxWidth
            // The aligned edge never moves; growth stops at the frame margin
            // and whatever is still too wide wraps onto further rows.
            switch item.alignment {
            case "left": right = min(maxRight, max(right, left + needed))
            case "right": left = max(minLeft, min(left, right - needed))
            default:
                let extra = max(0, needed - (right - left))
                left = max(minLeft, left - extra / 2)
                right = min(maxRight, right + extra - extra / 2)
            }
            boxLeft = left
            boxWidth = max(1, right - left)

            // Wrap at the grown width; rows grow the box downward, or upward
            // when the frame's bottom is near.
            var m = measure(designSize, CGFloat(boxWidth))
            var neededHeight = Int(m.totalHeight.rounded(.up))
            // Too tall for the frame, or a single unbreakable token (a URL, a
            // handle) still wider than the grown box: shrink.
            if neededHeight > videoHeight - margin * 2 || m.maxWidth > CGFloat(boxWidth) {
                var low = 6, high = Int(designSize), best = 6
                while low <= high {
                    let mid = (low + high) / 2
                    let probe = measure(CGFloat(mid), CGFloat(boxWidth))
                    if probe.totalHeight <= CGFloat(videoHeight - margin * 2) && probe.maxWidth <= CGFloat(boxWidth) {
                        best = mid
                        low = mid + 1
                    } else {
                        high = mid - 1
                    }
                }
                m = measure(CGFloat(best), CGFloat(boxWidth))
                neededHeight = Int(m.totalHeight.rounded(.up))
            }
            if neededHeight > boxHeight {
                let bottomLimit = videoHeight - margin
                if boxTop + neededHeight <= bottomLimit {
                    boxHeight = neededHeight
                } else {
                    boxTop = max(margin, bottomLimit - neededHeight)
                    boxHeight = min(neededHeight, bottomLimit - boxTop)
                }
            }
            return FittedLayout(boxLeft: boxLeft, boxTop: boxTop, boxWidth: boxWidth, boxHeight: boxHeight,
                                metrics: m, grew: grew)
        }

        // Fits: the largest font whose wrapped lines fill the box.
        var low = 6, high = max(boxWidth, boxHeight), best = 6
        while low <= high {
            let mid = (low + high) / 2
            let probe = measure(CGFloat(mid), CGFloat(boxWidth))
            if probe.totalHeight <= CGFloat(boxHeight) && probe.maxWidth <= CGFloat(boxWidth) {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return FittedLayout(boxLeft: boxLeft, boxTop: boxTop, boxWidth: boxWidth, boxHeight: boxHeight,
                            metrics: measure(CGFloat(best), CGFloat(boxWidth)), grew: grew)
    }

    /// Legacy mode: one unwrapped line at a fractional point or a named
    /// position (top 8%, center, bottom 85% — video.py fallback branch).
    /// The line is designed around the template's original text, but dynamic
    /// items get arbitrary AI/user text — so shrink an overflowing line to
    /// the frame width and nudge it back on screen instead of clipping.
    private func drawLegacy(in context: CGContext, item: TextOverlayItem,
                            words: [Word], visibleWords: Int?) {
        guard !words.isEmpty else { return }
        let line = legacyLayout(item: item, words: words)
        if item.boxOpacity > 0 {
            fillRoundedBackground(in: context, item: item,
                                  topLeft: (Int(line.x), Int(line.top)),
                                  size: (Int(line.width.rounded(.up)), Int(line.height.rounded(.up))))
        }
        let m = line.metrics
        var cursorTop = line.top
        let ascent = CTFontGetAscent(m.font)
        for lineWords in m.lines {
            let width = lineWidth(Self.plainText(lineWords), font: m.font)
            let x = Self.alignedX(boxLeft: line.x, boxWidth: line.width, lineWidth: width, alignment: item.alignment)
            drawStyledLine(lineWords, font: m.font, item: item, visibleWords: visibleWords,
                           in: context, x: x, baselineFromTop: cursorTop + ascent)
            cursorTop += m.lineHeight + m.spacing
        }
    }

    struct LegacyLayout {
        var metrics: LineMetrics
        var x: CGFloat
        var top: CGFloat
        var width: CGFloat
        var height: CGFloat
        var font: CTFont { metrics.font }
    }

    /// Where a legacy (box-less) text lands: the design size, wrapped at
    /// the frame width when the words are too long for one line (the font
    /// never changes for a longer text; only a single word wider than the
    /// frame shrinks so it stays on screen), in a block that hugs the rows,
    /// centred on the fractions or a named position, nudged inside the
    /// margin and the safe area.
    func legacyLayout(item: TextOverlayItem, words: [Word]) -> LegacyLayout {
        let margin = CGFloat(videoWidth) * 0.02
        let available = CGFloat(videoWidth) - margin * 2
        let designScale = CGFloat(videoHeight) / 1920
        let requestedSize = max(6, CGFloat(item.fontsize) * designScale)
        var m = metrics(item: item, words: words, size: requestedSize, maxWidth: available)
        if m.maxWidth > available {
            let scaled = max(6, requestedSize * available / m.maxWidth)
            m = metrics(item: item, words: words, size: scaled, maxWidth: available)
        }
        let width = m.maxWidth
        let textHeight = m.totalHeight

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
        x = min(max(x, margin), CGFloat(videoWidth) - margin - width)
        top = min(max(top, margin), CGFloat(videoHeight) - margin - textHeight)
        if safeArea != nil {
            let center = clamped(centerX: x + width / 2, centerY: top + textHeight / 2,
                                 width: width, height: textHeight)
            x = center.x - width / 2
            top = center.y - textHeight / 2
        }
        return LegacyLayout(metrics: m, x: x, top: top, width: width, height: textHeight)
    }

    /// Rounded background box with 5px padding; radius comes from the item
    /// (nil = 4px, the historical Pillow-parity value), clamped so oversized
    /// radii still produce a valid capsule.
    private func fillRoundedBackground(in context: CGContext, item: TextOverlayItem,
                                       topLeft: (x: Int, y: Int), size: (w: Int, h: Int)) {
        let (br, bg, bb) = Self.parseColor(item.bgcolor, fallback: (0, 0, 0))
        let pad = Self.boxPadding
        let rect = CGRect(x: CGFloat(topLeft.x - pad),
                          y: CGFloat(videoHeight - topLeft.y - size.h - pad),
                          width: CGFloat(size.w + pad * 2),
                          height: CGFloat(size.h + pad * 2))
        let radius = min(CGFloat(item.boxRadius ?? 4), rect.width / 2, rect.height / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(CGColor(red: br, green: bg, blue: bb,
                                     alpha: CGFloat(min(1, max(0, item.boxOpacity)))))
        context.fillPath()
    }

    // MARK: - Pro compositions

    private static let heroGradientBottom: (CGFloat, CGFloat, CGFloat) = (0.83, 0.83, 0.85)

    /// A parallelogram (rectangle skewed ~8°) — the angled bar behind
    /// kickers and tags.
    private func skewedBarPath(center: CGPoint, width: CGFloat, height: CGFloat) -> CGPath {
        let skew = height * 0.14
        let halfW = width / 2, halfH = height / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - halfW + skew, y: center.y + halfH))
        path.addLine(to: CGPoint(x: center.x + halfW + skew, y: center.y + halfH))
        path.addLine(to: CGPoint(x: center.x + halfW - skew, y: center.y - halfH))
        path.addLine(to: CGPoint(x: center.x - halfW - skew, y: center.y - halfH))
        path.closeSubpath()
        return path
    }

    private func kernedAttributes(font: CTFont, color: CGColor, trackingEm: CGFloat) -> [NSAttributedString.Key: Any] {
        [NSAttributedString.Key(kCTFontAttributeName as String): font,
         NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
         NSAttributedString.Key(kCTKernAttributeName as String):
            (CTFontGetSize(font) * trackingEm) as NSNumber]
    }

    /// Word start offsets within a full line, so words can be drawn (or
    /// skipped) individually without any layout drift.
    private func wordOffsets(_ words: [Word], font: CTFont) -> [CGFloat] {
        let plain = Self.plainText(words)
        let full = line(plain, font: font)
        var offsets: [CGFloat] = []
        var characterIndex = 0
        for word in words {
            offsets.append(CGFloat(CTLineGetOffsetForStringIndex(full, characterIndex, nil)))
            characterIndex += word.text.utf16.count + 1
        }
        return offsets
    }

    /// Hero lockup: small tracked-out kicker on a skewed accent bar above a
    /// huge auto-fit headline with outline, layered shadows, and a subtle
    /// vertical gradient — the fight-poster look.
    struct HeroGeometry {
        var centerX: Double
        var centerY: Double
        var headlineSize: CGFloat
        var blockTop: Double
        var metrics: LineMetrics
    }

    struct HeroKicker {
        var font: CTFont
        var line: CTLine
        var textWidth: CGFloat
        var barWidth: CGFloat
        var barHeight: CGFloat
        var gap: CGFloat
    }

    /// The hero headline auto-fitted to its box exactly like the fitted-box
    /// path (0.08em line spacing, Anton by default).
    func heroGeometry(item: TextOverlayItem, words: [Word]) -> HeroGeometry {
        let boxWidth = Double(videoWidth) * (item.wFrac ?? 0.82)
        let boxHeight = Double(videoHeight) * (item.hFrac ?? 0.12)
        let (centerX, centerY) = clamped(centerX: Double(videoWidth) * (item.xFrac ?? 0.5),
                                         centerY: Double(videoHeight) * (item.yFrac ?? 0.2),
                                         width: boxWidth, height: boxHeight)
        func metrics(for size: CGFloat) -> LineMetrics {
            let font = resolveFont(size: size, family: item.fontfamily ?? "Anton",
                                   bold: item.bold, italic: item.italic)
            let lines = wrap(words, font: font, maxWidth: boxWidth, maxWords: item.resolvedWordsPerLine)
            let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font)
            let spacing = (size * 0.08).rounded(.down)
            let total = lineHeight * CGFloat(lines.count) + spacing * CGFloat(max(0, lines.count - 1))
            let maxLineWidth = lines.map { lineWidth(Self.plainText($0), font: font) }.max() ?? 0
            return LineMetrics(font: font, lines: lines, lineHeight: lineHeight, spacing: spacing,
                               totalHeight: total, maxWidth: maxLineWidth)
        }
        var low = 6, high = Int(max(boxWidth, boxHeight)), best = 6
        while low <= high {
            let mid = (low + high) / 2
            let m = metrics(for: CGFloat(mid))
            if m.totalHeight <= boxHeight && m.maxWidth <= boxWidth { best = mid; low = mid + 1 }
            else { high = mid - 1 }
        }
        let m = metrics(for: CGFloat(best))
        return HeroGeometry(centerX: centerX, centerY: centerY, headlineSize: CGFloat(best),
                            blockTop: centerY - Double(m.totalHeight) / 2, metrics: m)
    }

    /// The kicker bar above a hero headline; nil without a kicker.
    func heroKicker(item: TextOverlayItem, headlineSize: CGFloat) -> HeroKicker? {
        guard let kicker = item.kicker?.trimmingCharacters(in: .whitespacesAndNewlines), !kicker.isEmpty else { return nil }
        let kickerFont = resolveFont(size: max(24, headlineSize * 0.2),
                                     family: "Archivo Black", bold: false, italic: false)
        let black = CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        let attributes = kernedAttributes(font: kickerFont, color: black, trackingEm: 0.14)
        let kickerLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: kicker.uppercased(), attributes: attributes))
        let textWidth = CGFloat(CTLineGetTypographicBounds(kickerLine, nil, nil, nil))
        let barHeight = (CTFontGetAscent(kickerFont) + CTFontGetDescent(kickerFont)) * 1.55
        return HeroKicker(font: kickerFont, line: kickerLine, textWidth: textWidth,
                          barWidth: textWidth + barHeight * 1.1, barHeight: barHeight, gap: headlineSize * 0.24)
    }

    private func drawHero(in context: CGContext, item: TextOverlayItem,
                          words: [Word], visibleWords: Int?) {
        guard !words.isEmpty else { return }
        let geometry = heroGeometry(item: item, words: words)
        let centerX = geometry.centerX, m = geometry.metrics
        let headlineSize = geometry.headlineSize
        let blockTop = geometry.blockTop

        // Kicker on its angled accent bar, centered above the headline.
        if let kicker = heroKicker(item: item, headlineSize: headlineSize) {
            let kickerFont = kicker.font, kickerLine = kicker.line, textWidth = kicker.textWidth
            let accent = Self.cgColor(item.accentColor, fallback: (1, 0.84, 0))
            let ascent = CTFontGetAscent(kickerFont), descent = CTFontGetDescent(kickerFont)
            let barHeight = kicker.barHeight, barWidth = kicker.barWidth
            let barCenterY = CGFloat(videoHeight) - CGFloat(blockTop) + kicker.gap + barHeight / 2

            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -4), blur: 14,
                              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            context.addPath(skewedBarPath(center: CGPoint(x: centerX, y: barCenterY),
                                          width: barWidth, height: barHeight))
            context.setFillColor(accent)
            context.fillPath()
            context.restoreGState()
            // Center optically: drop the trailing kern the last glyph carries.
            let kern = CTFontGetSize(kickerFont) * 0.14
            context.textPosition = CGPoint(x: centerX - Double(textWidth - kern) / 2,
                                           y: barCenterY - (ascent - descent) / 2)
            CTLineDraw(kickerLine, context)
        }

        // Headline lines: outline with ambient shadow, solid fill with a
        // tight contact shadow, then a vertical gradient clipped to the
        // visible glyphs.
        let strokePercent = CGFloat(max(item.strokeWidthEm, 0.05)) * 200
        let strokeColor = Self.cgColor(item.strokeColor ?? "black", fallback: (0, 0, 0))
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let highlightColor = item.highlightColor.map { Self.cgColor($0, fallback: (1, 0.84, 0)) }
        let (gr, gg, gb) = Self.heroGradientBottom
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(colorsSpace: colorSpace,
                                  colors: [white, CGColor(red: gr, green: gg, blue: gb, alpha: 1)] as CFArray,
                                  locations: [0, 1])

        var decorationItem = item
        decorationItem.fontcolor = "#ffffff"
        decorationItem.strokeColor = item.strokeColor ?? "black"
        decorationItem.strokeWidthEm = max(item.strokeWidthEm, 0.05)
        var cursorTop = blockTop
        let ascent = CTFontGetAscent(m.font), descent = CTFontGetDescent(m.font)
        for lineWords in m.lines {
            let plain = Self.plainText(lineWords)
            let width = lineWidth(plain, font: m.font)
            let lineX = centerX - Double(width) / 2
            let baselineY = CGFloat(videoHeight) - CGFloat(cursorTop) - ascent
            let offsets = wordOffsets(lineWords, font: m.font)

            for (position, word) in lineWords.enumerated() {
                if let visibleWords, word.index >= visibleWords { continue }
                let wordLine = line(word.text, font: m.font)
                let wordX = CGFloat(lineX) + offsets[position]

                // 1. Outline + ambient shadow.
                context.saveGState()
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.setShadow(offset: CGSize(width: 0, height: -headlineSize * 0.09),
                                  blur: headlineSize * 0.26,
                                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
                context.setTextDrawingMode(.stroke)
                context.setStrokeColor(strokeColor)
                context.setLineWidth(headlineSize * strokePercent / 100)
                context.textPosition = CGPoint(x: wordX, y: baselineY)
                CTLineDraw(wordLine, context)
                drawDecorations([word], font: m.font, item: decorationItem, visibleWords: nil,
                                in: context, position: CGPoint(x: wordX, y: baselineY), stroke: true)
                context.restoreGState()

                // 2. Solid fill + contact shadow. Starred words take the
                //    accent color and skip the gradient.
                let accented = word.highlighted ? highlightColor : nil
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -headlineSize * 0.03),
                                  blur: headlineSize * 0.05,
                                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
                context.setTextDrawingMode(.fill)
                context.setFillColor(accented ?? white)
                context.textPosition = CGPoint(x: wordX, y: baselineY)
                CTLineDraw(wordLine, context)
                drawDecorations([word], font: m.font, item: decorationItem, visibleWords: nil,
                                in: context, position: CGPoint(x: wordX, y: baselineY))
                context.restoreGState()

                // 3. Gradient clipped to the glyphs.
                if let gradient, accented == nil {
                    context.saveGState()
                    context.setTextDrawingMode(.clip)
                    context.textPosition = CGPoint(x: wordX, y: baselineY)
                    CTLineDraw(wordLine, context)
                    context.drawLinearGradient(gradient,
                                               start: CGPoint(x: 0, y: baselineY + ascent),
                                               end: CGPoint(x: 0, y: baselineY - descent),
                                               options: [])
                    context.restoreGState()
                }
            }
            cursorTop += Double(m.lineHeight + m.spacing)
        }
    }

    /// Tag chip: one bold line on a skewed dark bar with an accent stripe on
    /// the leading edge — lower-third name/stat plate.
    struct TagGeometry {
        var centerX: Double
        var centerY: Double
        var font: CTFont
        var line: CTLine
        var attributes: [NSAttributedString.Key: Any]
        var textWidth: CGFloat
        var barWidth: CGFloat
        var barHeight: CGFloat
    }

    /// The tag chip: the largest font whose line fits the box minus the
    /// bar's padding, and the bar around it.
    func tagGeometry(item: TextOverlayItem, words: [Word]) -> TagGeometry {
        let maxWidth = Double(videoWidth) * (item.wFrac ?? 0.8)
        let maxHeight = Double(videoHeight) * (item.hFrac ?? 0.06)
        let (centerX, centerY) = clamped(centerX: Double(videoWidth) * (item.xFrac ?? 0.5),
                                         centerY: Double(videoHeight) * (item.yFrac ?? 0.2),
                                         width: maxWidth, height: maxHeight)
        let plain = Self.plainText(words)

        var low = 6, high = Int(maxHeight), best = 6
        while low <= high {
            let mid = (low + high) / 2
            let font = resolveFont(size: CGFloat(mid), family: item.fontfamily ?? "Archivo Black",
                                   bold: item.bold, italic: item.italic)
            // Bar padding eats into the width budget.
            if lineWidth(plain, font: font) <= maxWidth - Double(CGFloat(mid)) * 2.4 { best = mid; low = mid + 1 }
            else { high = mid - 1 }
        }
        let font = resolveFont(size: CGFloat(best), family: item.fontfamily ?? "Archivo Black",
                               bold: item.bold, italic: item.italic)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let attributes = kernedAttributes(font: font, color: white, trackingEm: 0.03)
        let tagLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: plain, attributes: attributes))
        let textWidth = CGFloat(CTLineGetTypographicBounds(tagLine, nil, nil, nil))
        let barHeight = (CTFontGetAscent(font) + CTFontGetDescent(font)) * 1.7
        return TagGeometry(centerX: centerX, centerY: centerY, font: font, line: tagLine, attributes: attributes,
                           textWidth: textWidth, barWidth: textWidth + barHeight * 1.2, barHeight: barHeight)
    }

    private func drawTag(in context: CGContext, item: TextOverlayItem,
                         words: [Word], visibleWords: Int?) {
        guard !words.isEmpty else { return }
        let geometry = tagGeometry(item: item, words: words)
        let font = geometry.font, tagLine = geometry.line, attributes = geometry.attributes
        let textWidth = geometry.textWidth, barWidth = geometry.barWidth, barHeight = geometry.barHeight
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let center = CGPoint(x: geometry.centerX, y: CGFloat(videoHeight) - geometry.centerY)
        let dark = Self.cgColor(item.bgcolor, fallback: (0.07, 0.07, 0.09))
        let accent = Self.cgColor(item.accentColor, fallback: (1, 0.84, 0))

        // Bar with a soft lift shadow.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 22,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.4))
        context.addPath(skewedBarPath(center: center, width: barWidth, height: barHeight))
        context.setFillColor(dark)
        context.fillPath()
        context.restoreGState()

        // Accent stripe hugging the leading edge (same skew).
        let stripeWidth = barHeight * 0.16
        let stripeCenter = CGPoint(x: center.x - barWidth / 2 - stripeWidth * 0.9, y: center.y)
        context.addPath(skewedBarPath(center: stripeCenter, width: stripeWidth, height: barHeight))
        context.setFillColor(accent)
        context.fillPath()

        // Hidden words keep their space (word_reveal parity).
        let kern = CTFontGetSize(font) * 0.03
        let textX = center.x - (textWidth - kern) / 2
        let baselineY = center.y - (ascent - descent) / 2
        if let visibleWords, visibleWords < words.count {
            let offsets = wordOffsets(words, font: font)
            for (position, word) in words.enumerated() where word.index < visibleWords {
                let wordLine = CTLineCreateWithAttributedString(
                    NSAttributedString(string: word.text, attributes: attributes))
                context.textPosition = CGPoint(x: textX + offsets[position], y: baselineY)
                CTLineDraw(wordLine, context)
            }
        } else {
            context.textPosition = CGPoint(x: textX, y: baselineY)
            CTLineDraw(tagLine, context)
        }
        var decorationItem = item
        decorationItem.fontcolor = "#ffffff"
        decorationItem.highlightColor = nil
        drawDecorations(words, font: font, item: decorationItem, visibleWords: visibleWords,
                        in: context, position: CGPoint(x: textX, y: baselineY), trackingEm: 0.03)
    }

    // MARK: - Styled line drawing

    /// Attributed string for one wrapped line. Hidden words (beyond
    /// `visibleWords`) get fully transparent color so the layout — including
    /// spaces — is identical across the reveal sequence.
    private func attributedLine(_ words: [Word], font: CTFont, item: TextOverlayItem,
                                visibleWords: Int?, strokeWidthPercent: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseColor = Self.cgColor(item.fontcolor)
        let highlightColor = item.highlightColor.map { Self.cgColor($0, fallback: (1, 0.84, 0)) }
        let strokeColor = Self.cgColor(item.strokeColor, fallback: (0, 0, 0))
        let clear = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        let strokePass = strokeWidthPercent > 0

        for (position, word) in words.enumerated() {
            let visible = visibleWords.map { word.index < $0 } ?? true
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]
            if strokePass {
                // Positive stroke width = stroke only; the fill pass draws on top.
                attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                    strokeWidthPercent as NSNumber
                attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] =
                    visible ? strokeColor : clear
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = clear
            } else {
                let fill = word.highlighted ? (highlightColor ?? baseColor) : baseColor
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] =
                    visible ? fill : clear
            }
            result.append(NSAttributedString(string: (position > 0 ? " " : "") + word.text,
                                             attributes: attributes))
        }
        return result
    }

    /// Use the same per-word colour and visibility as the glyph passes.
    private func drawDecorations(_ words: [Word], font: CTFont, item: TextOverlayItem,
                                 visibleWords: Int?, in context: CGContext, position: CGPoint,
                                 stroke: Bool = false, trackingEm: CGFloat = 0) {
        guard item.resolvedUnderline || item.resolvedStrikethrough else { return }
        let tracked = CTLineCreateWithAttributedString(NSAttributedString(
            string: Self.plainText(words), attributes: kernedAttributes(font: font, color: Self.cgColor(item.fontcolor), trackingEm: trackingEm)))
        var characterIndex = 0
        let offsets = words.map { word in
            defer { characterIndex += word.text.utf16.count + 1 }
            return CGFloat(CTLineGetOffsetForStringIndex(tracked, characterIndex, nil))
        }
        let thickness = max(1, CTFontGetUnderlineThickness(font))
        let base = Self.cgColor(item.fontcolor)
        let highlight = item.highlightColor.map { Self.cgColor($0, fallback: (1, 0.84, 0)) }
        for (index, word) in words.enumerated() {
            if let visibleWords, word.index >= visibleWords { continue }
            let trackedWord = CTLineCreateWithAttributedString(NSAttributedString(string: word.text,
                attributes: kernedAttributes(font: font, color: base, trackingEm: trackingEm)))
            let width = max(0, CGFloat(CTLineGetTypographicBounds(trackedWord, nil, nil, nil)) - CTFontGetSize(font) * trackingEm)
            context.setFillColor(word.highlighted ? (highlight ?? base) : base)
            var ys: [CGFloat] = []
            if item.resolvedUnderline { ys.append(position.y + CTFontGetUnderlinePosition(font)) }
            if item.resolvedStrikethrough { ys.append(position.y + CTFontGetXHeight(font) / 2) }
            for y in ys {
                let rect = CGRect(x: position.x + offsets[index], y: y, width: width, height: thickness)
                if stroke {
                    context.setStrokeColor(Self.cgColor(item.strokeColor, fallback: (0, 0, 0)))
                    context.setLineWidth(CTFontGetSize(font) * item.strokeWidthEm * 2)
                    context.stroke(rect)
                } else {
                    context.fill(rect)
                }
            }
        }
    }

    /// Draw one line: optional drop shadow, optional outline stroke pass
    /// behind the color fill pass.
    private func drawStyledLine(_ words: [Word], font: CTFont, item: TextOverlayItem,
                                visibleWords: Int?, in context: CGContext,
                                x: CGFloat, baselineFromTop: CGFloat) {
        let position = CGPoint(x: x, y: CGFloat(videoHeight) - baselineFromTop)
        let fontSize = CTFontGetSize(font)
        // CT stroke width is a percentage of the font size; the stroke is
        // centered on the glyph edge, so double it to get the requested
        // outward thickness once the fill pass covers the inner half.
        let strokePercent = item.strokeColor != nil && item.strokeWidthEm > 0
            ? CGFloat(item.strokeWidthEm) * 200 : 0

        context.saveGState()
        if item.shadowOpacity > 0 {
            context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.05),
                              blur: fontSize * 0.15,
                              color: CGColor(red: 0, green: 0, blue: 0,
                                             alpha: CGFloat(min(1, item.shadowOpacity))))
        }
        if strokePercent > 0 {
            // Round joins: sharp glyph corners (W, V, A) grow miter spikes
            // at these stroke widths otherwise.
            context.setLineJoin(.round)
            context.setLineCap(.round)
            let stroke = CTLineCreateWithAttributedString(
                attributedLine(words, font: font, item: item,
                               visibleWords: visibleWords, strokeWidthPercent: strokePercent))
            context.textPosition = position
            CTLineDraw(stroke, context)
            drawDecorations(words, font: font, item: item, visibleWords: visibleWords,
                            in: context, position: position, stroke: true)
            // The fill draws on top without a shadow of its own — otherwise
            // it would shade the stroke it sits on.
            context.restoreGState()
            context.saveGState()
        }
        let fill = CTLineCreateWithAttributedString(
            attributedLine(words, font: font, item: item,
                           visibleWords: visibleWords, strokeWidthPercent: 0))
        context.textPosition = position
        CTLineDraw(fill, context)
        drawDecorations(words, font: font, item: item, visibleWords: visibleWords,
                        in: context, position: position)
        context.restoreGState()
    }
}
