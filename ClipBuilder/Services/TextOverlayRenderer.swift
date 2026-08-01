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

    private static func cgColor(_ string: String?, fallback: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)) -> CGColor {
        let (r, g, b) = parseColor(string, fallback: fallback)
        return CGColor(red: r, green: g, blue: b, alpha: 1)
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
            // Without this Core Text fills with attribute black and ignores
            // the context fill/stroke colors the hero passes set.
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        return CTLineCreateWithAttributedString(attributed)
    }

    private func lineWidth(_ text: String, font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font: font), nil, nil, nil))
    }

    /// Word-wrap to a pixel width (port of _wrap_text, over markup words).
    private func wrap(_ words: [Word], font: CTFont, maxWidth: CGFloat) -> [[Word]] {
        guard !words.isEmpty else { return [] }
        var lines: [[Word]] = []
        var current = [words[0]]
        for word in words.dropFirst() {
            let candidate = Self.plainText(current + [word])
            if lineWidth(candidate, font: font) <= maxWidth {
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

        switch item.design {
        case "hero":
            drawHero(in: context, item: item, words: words, visibleWords: visibleWords)
        case "tag":
            drawTag(in: context, item: item, words: words, visibleWords: visibleWords)
        default:
            if let wFrac = item.wFrac, let hFrac = item.hFrac,
               let xFrac = item.xFrac, let yFrac = item.yFrac, wFrac > 0, hFrac > 0 {
                drawFittedBox(in: context, item: item, words: words, visibleWords: visibleWords,
                              boxWidth: Int(Double(width) * wFrac), boxHeight: Int(Double(height) * hFrac),
                              centerX: Int(Double(width) * xFrac), centerY: Int(Double(height) * yFrac))
            } else {
                drawLegacy(in: context, item: item, words: words, visibleWords: visibleWords)
            }
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
    private func drawFittedBox(in context: CGContext, item: TextOverlayItem,
                               words: [Word], visibleWords: Int?,
                               boxWidth: Int, boxHeight: Int, centerX: Int, centerY: Int) {
        guard !words.isEmpty else { return }
        func metrics(for size: CGFloat) -> (font: CTFont, lines: [[Word]], lineHeight: CGFloat,
                                            spacing: CGFloat, totalHeight: CGFloat, maxWidth: CGFloat) {
            let font = resolveFont(size: size, family: item.fontfamily,
                                   bold: item.bold, italic: item.italic)
            let lines = wrap(words, font: font, maxWidth: CGFloat(boxWidth))
            let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font)
            let spacing = (size * 0.15).rounded(.down)
            let total = lineHeight * CGFloat(lines.count) + spacing * CGFloat(max(0, lines.count - 1))
            let maxLineWidth = lines.map { lineWidth(Self.plainText($0), font: font) }.max() ?? 0
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
        for lineWords in m.lines {
            let width = lineWidth(Self.plainText(lineWords), font: m.font)
            let x = CGFloat(boxLeft) + (CGFloat(boxWidth) - width) / 2
            drawStyledLine(lineWords, font: m.font, item: item, visibleWords: visibleWords,
                           in: context, x: x, baselineFromTop: cursorTop + ascent)
            cursorTop += m.lineHeight + m.spacing
        }
    }

    /// Legacy mode: one unwrapped line at a fractional point or a named
    /// position (top 8%, center, bottom 85% — video.py fallback branch).
    private func drawLegacy(in context: CGContext, item: TextOverlayItem,
                            words: [Word], visibleWords: Int?) {
        guard !words.isEmpty else { return }
        let font = resolveFont(size: CGFloat(item.fontsize), family: item.fontfamily,
                               bold: item.bold, italic: item.italic)
        let plain = Self.plainText(words)
        let width = lineWidth(plain, font: font)
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
        drawStyledLine(words, font: font, item: item, visibleWords: visibleWords,
                       in: context, x: x, baselineFromTop: top + ascent)
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
            characterIndex += word.text.count + 1
        }
        return offsets
    }

    /// Hero lockup: small tracked-out kicker on a skewed accent bar above a
    /// huge auto-fit headline with outline, layered shadows, and a subtle
    /// vertical gradient — the fight-poster look.
    private func drawHero(in context: CGContext, item: TextOverlayItem,
                          words: [Word], visibleWords: Int?) {
        guard !words.isEmpty else { return }
        let boxWidth = Double(videoWidth) * (item.wFrac ?? 0.82)
        let boxHeight = Double(videoHeight) * (item.hFrac ?? 0.12)
        let centerX = Double(videoWidth) * (item.xFrac ?? 0.5)
        let centerY = Double(videoHeight) * (item.yFrac ?? 0.2)

        // Auto-fit the headline exactly like the fitted-box path.
        func metrics(for size: CGFloat) -> (font: CTFont, lines: [[Word]], lineHeight: CGFloat,
                                            spacing: CGFloat, totalHeight: CGFloat, maxWidth: CGFloat) {
            let font = resolveFont(size: size, family: item.fontfamily ?? "Anton",
                                   bold: item.bold, italic: item.italic)
            let lines = wrap(words, font: font, maxWidth: boxWidth)
            let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font)
            let spacing = (size * 0.08).rounded(.down)
            let total = lineHeight * CGFloat(lines.count) + spacing * CGFloat(max(0, lines.count - 1))
            let maxLineWidth = lines.map { lineWidth(Self.plainText($0), font: font) }.max() ?? 0
            return (font, lines, lineHeight, spacing, total, maxLineWidth)
        }
        var low = 6, high = Int(max(boxWidth, boxHeight)), best = 6
        while low <= high {
            let mid = (low + high) / 2
            let m = metrics(for: CGFloat(mid))
            if m.totalHeight <= boxHeight && m.maxWidth <= boxWidth { best = mid; low = mid + 1 }
            else { high = mid - 1 }
        }
        let m = metrics(for: CGFloat(best))
        let headlineSize = CGFloat(best)
        let blockTop = centerY - Double(m.totalHeight) / 2

        // Kicker on its angled accent bar, centered above the headline.
        if let kicker = item.kicker?.trimmingCharacters(in: .whitespacesAndNewlines), !kicker.isEmpty {
            let kickerFont = resolveFont(size: max(24, headlineSize * 0.2),
                                         family: "Archivo Black", bold: false, italic: false)
            let accent = Self.cgColor(item.accentColor, fallback: (1, 0.84, 0))
            let black = CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
            let attributes = kernedAttributes(font: kickerFont, color: black, trackingEm: 0.14)
            let kickerLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: kicker.uppercased(), attributes: attributes))
            let textWidth = CGFloat(CTLineGetTypographicBounds(kickerLine, nil, nil, nil))
            let ascent = CTFontGetAscent(kickerFont), descent = CTFontGetDescent(kickerFont)
            let barHeight = (ascent + descent) * 1.55
            let barWidth = textWidth + barHeight * 1.1
            let gap = headlineSize * 0.24
            let barCenterY = CGFloat(videoHeight) - CGFloat(blockTop) + gap + barHeight / 2

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
    private func drawTag(in context: CGContext, item: TextOverlayItem,
                         words: [Word], visibleWords: Int?) {
        guard !words.isEmpty else { return }
        let maxWidth = Double(videoWidth) * (item.wFrac ?? 0.8)
        let maxHeight = Double(videoHeight) * (item.hFrac ?? 0.06)
        let centerX = Double(videoWidth) * (item.xFrac ?? 0.5)
        let centerY = Double(videoHeight) * (item.yFrac ?? 0.2)
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
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let barHeight = (ascent + descent) * 1.7
        let barWidth = textWidth + barHeight * 1.2
        let center = CGPoint(x: centerX, y: CGFloat(videoHeight) - centerY)
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
        context.restoreGState()
    }
}
