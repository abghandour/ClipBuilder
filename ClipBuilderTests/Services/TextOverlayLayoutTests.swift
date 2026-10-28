import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Clip_Builder

@Suite("Text overlay layout")
struct TextOverlayLayoutTests {
    private let renderer = TextOverlayRenderer(videoWidth: 1080, videoHeight: 1920, safeArea: nil)

    private func item(_ text: String, alignment: String, x: Double = 0.5, y: Double = 0.5,
                      w: Double = 0.3, h: Double = 0.05, fontsize: Int = 60) -> TextOverlayItem {
        var item = TextOverlayItem(text: text)
        item.alignment = alignment
        item.xFrac = x
        item.yFrac = y
        item.wFrac = w
        item.hFrac = h
        item.fontsize = fontsize
        item.boxOpacity = 1
        item.bgcolor = "#ff0000"
        item.fontcolor = "#ff0000"
        return item
    }

    /// Bounding box of the non-transparent pixels in a rendered overlay PNG.
    private func opaqueBounds(_ url: URL) throws -> CGRect {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // Bitmap rows run top-down, like the video frame.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func render(_ item: TextOverlayItem) throws -> CGRect {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try opaqueBounds(try renderer.render(item, to: directory))
    }

    @Test("Text that fits keeps its box; alignment decides where the glyphs sit")
    func fittingTextAlignsInsideTheBox() throws {
        // Box: x 378...702 (0.3 wide, centred), 96 px tall; a short word fits.
        let pad = 5.0
        let left = try render(item("Hi", alignment: "left", fontsize: 40))
        let right = try render(item("Hi", alignment: "right", fontsize: 40))
        let center = try render(item("Hi", alignment: "center", fontsize: 40))
        for box in [left, right, center] {
            #expect(abs(box.minX - (378 - pad)) <= 1 && abs(box.maxX - (702 + pad)) <= 1, "background box unchanged")
        }
        // The glyph colour equals the box colour, so compare alpha-free: render without a box.
        var bare = item("Hi", alignment: "left", fontsize: 40)
        bare.boxOpacity = 0
        let glyphsLeft = try render(bare)
        bare.alignment = "right"
        let glyphsRight = try render(bare)
        bare.alignment = "center"
        let glyphsCenter = try render(bare)
        #expect(glyphsLeft.minX < 378 + 12, "left-aligned glyphs start at the box's left edge")
        #expect(glyphsRight.maxX > 702 - 12, "right-aligned glyphs end at the box's right edge")
        #expect(abs(glyphsCenter.midX - 540) < 12, "centred glyphs straddle the box centre")
    }

    @Test("Overflowing text grows the box away from its alignment, then wraps")
    func overflowGrowsThenWraps() throws {
        let long = "This headline is far too long for its little box"
        let grownLeft = try render(item(long, alignment: "left", fontsize: 40))
        #expect(abs(grownLeft.minX - (378 - 5)) <= 1, "left edge stays put")
        #expect(grownLeft.maxX > 702 + 40, "box extended to the right")
        let grownRight = try render(item(long, alignment: "right", fontsize: 40))
        #expect(abs(grownRight.maxX - (702 + 5)) <= 1, "right edge stays put")
        #expect(grownRight.minX < 378 - 40, "box extended to the left")
        let grownCenter = try render(item("Rather long headline here", alignment: "center", fontsize: 40))
        #expect(grownCenter.minX < 378 - 20 && grownCenter.maxX > 702 + 20, "centred text grows both ways")
        #expect(abs(grownCenter.midX - 540) < 6)
        #expect(grownLeft.maxX <= 1080 - 21 + 5, "growth stops at the frame margin")

        // Longer still: no single row fits between the margins, so it wraps and the box gets taller.
        let paragraph = String(repeating: "wrap me around please ", count: 6)
        let wrapped = try render(item(paragraph, alignment: "left", fontsize: 40))
        #expect(wrapped.height > 96 + 40, "rows added below the original 96 px box")
        #expect(wrapped.minX >= 21 - 5 && wrapped.maxX <= 1080 - 21 + 5, "within the 2% frame margin")
        #expect(abs(wrapped.minY - (960 - 48 - 5)) <= 1, "grows downward from the original top edge")

        // Near the bottom edge the extra rows grow upward instead.
        let low = try render(item(paragraph, alignment: "left", y: 0.97, fontsize: 40))
        #expect(low.maxY <= 1920 - 21 + 5 && low.minY < 1920 * 0.97 - 48 - 40)
    }

    @Test("A hand-placed box keeps the design font size: words wrap at its width and it grows downward")
    func lockedWidthWrapsInsteadOfGrowing() throws {
        let long = "This headline is far too long for its little box"
        var locked = item(long, alignment: "left", fontsize: 40)
        locked.lockedWidth = true
        let rendered = try render(locked)
        #expect(abs(rendered.minX - 378) <= 1 && abs(rendered.maxX - 702) <= 1, "the placed box is the painted box, both edges stay put")
        #expect(rendered.height > 96 + 40, "the words wrapped onto more rows below the box")
        let box = try #require(renderer.renderedBox(locked))
        #expect(abs(box.minX - 378) <= 1 && abs(box.width - 324) <= 1, "renderedBox reports the placed box")
        #expect(abs(box.height - rendered.height) <= 2, "and its grown height")
        let grown = try #require(renderer.renderedBox(item(long, alignment: "left", fontsize: 40)))
        #expect(grown.width > 324, "without the lock the box widens as before")
        // A short word that fits keeps the design size instead of auto-fitting to fill the box.
        var short = item("Hi", alignment: "left", fontsize: 40)
        short.lockedWidth = true
        let footprint = try #require(renderer.renderedBox(short))
        #expect(abs(footprint.minX - 378) <= 1 && abs(footprint.width - 324) <= 1 && abs(footprint.height - 96) <= 1)
        var red = short
        red.boxOpacity = 0
        let glyphs = try render(red)
        #expect(glyphs.height < 45 && glyphs.height > 20, "40 pt at 1920 high stays 40 px tall, not grown to the 86 px box")
        var bigger = red
        bigger.wFrac = 0.6; bigger.hFrac = 0.2
        #expect(abs(try render(bigger).height - glyphs.height) <= 1, "a larger box does not change the font")
        // Round-trips in JSON and takes part in equality.
        let data = try JSONEncoder().encode(locked)
        let decoded = try JSONDecoder().decode(TextOverlayItem.self, from: data)
        var same = decoded
        same.uid = locked.uid
        #expect(decoded.resolvedLockedWidth && same == locked)
        let json = String(decoding: try JSONEncoder().encode(TextOverlayItem(text: "x")), as: UTF8.self)
        #expect(!json.contains("locked_width"), "only written when set")
    }

    @Test("Placing the Subject template's legacy line gives a box the words wrap in, matching its selector")
    func placedLegacyLineWrapsInsideItsSelector() throws {
        // The saved Subject design: centre and size only, no box, drawn as one shrunk line.
        var subject = TextOverlayItem(text: "Subject asdasd sadasasd asdasda sda")
        subject.fontsize = 194
        subject.fontfamily = "Bebas Neue"
        subject.xFrac = 0.4988
        subject.yFrac = 0.7879
        subject.boxOpacity = 0.5
        subject.isDynamic = true
        let composition = OverlayComposition(texts: [subject])
        let before = try #require(renderer.renderedBox(subject))
        let beforePaint = try render(subject)
        #expect(abs(before.minX - beforePaint.minX) <= 1 && abs(before.maxX - beforePaint.maxX) <= 1, "legacy footprint matches")
        #expect(before.width <= 1080 - 21 + 5 && before.height > 2 * 194 * 0.9, "wrapped to rows inside the frame margin at the design size, not shrunk")
        var oneWordBefore = subject
        oneWordBefore.text = "Subject"
        oneWordBefore.boxOpacity = 0
        oneWordBefore.fontcolor = "#ff0000"
        let legacyGlyphs = try render(oneWordBefore)

        var edits = OverlayEdits()
        edits.place(.text(0), at: CGRect(x: 0.42, y: 0.52, width: 0.48, height: 0.13))
        let placed = WizardFixedOverlay.applyingEdits(in: composition, with: edits).texts[0]
        #expect(placed.resolvedLockedWidth && abs((placed.wFrac ?? 0) - 0.48) < 0.0001)
        let after = try #require(renderer.renderedBox(placed))
        let paint = try render(placed)
        // A missing optional font can make an indivisible token wider than
        // the placed box. The raster is necessarily clipped to the canvas.
        let visibleAfter = after.intersection(CGRect(x: 0, y: 0, width: 1080, height: 1920))
        #expect(abs(visibleAfter.minX - paint.minX) <= 1 && abs(visibleAfter.maxX - paint.maxX) <= 1,
                "selector and painted box share visible edges")
        #expect(abs(after.minY - paint.minY) <= 1 && abs(after.maxY - paint.maxY) <= 1)
        #expect(after.width >= 0.48 * 1080 - 1 && after.midX > 0.42 * 1080 && after.midX < 0.9 * 1080,
                "the placed width is kept, widened only when one word at 194 pt cannot fit")
        #expect(after.height > 0.13 * 1920, "rows wrapped below the placed height at the design size")
        var narrowWords = placed
        // Keep this subcase genuinely narrow even when the optional Bebas
        // asset is unavailable and CoreText falls back to Helvetica.
        narrowWords.text = "Fits in a box"
        let kept = try #require(renderer.renderedBox(narrowWords))
        #expect(abs(kept.minX - 0.42 * 1080) <= 1 && abs(kept.width - 0.48 * 1080) <= 1, "words that fit keep the placed width exactly")
        var bare = placed
        bare.boxOpacity = 0
        bare.fontcolor = "#ff0000"
        let glyphs = try render(bare)
        #expect(glyphs.maxX <= after.maxX + 1 && glyphs.minX >= after.minX - 1, "the words stay inside the box")
        #expect(glyphs.height > 0.13 * 1920, "several rows at 194 pt")
        // The same font before and after placing: row height is unchanged.
        let rowsBefore = renderer.legacyLayout(item: subject, words: TextOverlayRenderer.parseMarkup(subject.text)).metrics
        #expect(CTFontGetSize(rowsBefore.font) == 194 && rowsBefore.lines.count >= 2, "legacy rows at the design size")
        var oneWordAfter = bare
        oneWordAfter.text = "Subject"
        let placedGlyphs = try render(oneWordAfter)
        #expect(abs(placedGlyphs.height - legacyGlyphs.height) <= 1 && abs(placedGlyphs.width - legacyGlyphs.width) <= 1,
                "the same word is the same size before and after placing: the font did not change")
    }

    @Test("renderedBox matches the painted footprint of every design")
    func renderedBoxMatchesThePaintedFootprint() throws {
        // Fitted box with a background: the box plus its 5 px padding.
        let fitted = item("Hi", alignment: "center", fontsize: 40)
        let fittedBox = try #require(renderer.renderedBox(fitted))
        let fittedPaint = try render(fitted)
        #expect(abs(fittedBox.minX - fittedPaint.minX) <= 1 && abs(fittedBox.maxX - fittedPaint.maxX) <= 1)
        #expect(abs(fittedBox.minY - fittedPaint.minY) <= 1 && abs(fittedBox.maxY - fittedPaint.maxY) <= 1)
        // Legacy single line (no fractions, like the Subject template).
        var legacy = TextOverlayItem(text: "Subject")
        legacy.fontsize = 194
        legacy.xFrac = 0.5
        legacy.yFrac = 0.79
        legacy.boxOpacity = 0.5
        legacy.bgcolor = "#000000"
        let legacyBox = try #require(renderer.renderedBox(legacy))
        let legacyPaint = try render(legacy)
        #expect(abs(legacyBox.minX - legacyPaint.minX) <= 1 && abs(legacyBox.maxX - legacyPaint.maxX) <= 1)
        #expect(abs(legacyBox.minY - legacyPaint.minY) <= 1 && abs(legacyBox.maxY - legacyPaint.maxY) <= 1)
        #expect(legacyBox.width < 1080 * 0.6 - 20 || legacyBox.width > 1080 * 0.6 + 20, "not the default design box")
        // Legacy with no background: the glyph bounds, within the line's metrics.
        legacy.boxOpacity = 0
        legacy.fontcolor = "#ff0000"
        let bare = try #require(renderer.renderedBox(legacy))
        let glyphs = try render(legacy)
        #expect(bare.contains(glyphs.insetBy(dx: 2, dy: 2)) && bare.height < glyphs.height * 1.6)
        // Hero and tag report the headline block and the bar; the paint stays inside with its shadows.
        var hero = item("Fight Night", alignment: "center", w: 0.8, h: 0.12, fontsize: 60)
        hero.design = "hero"
        hero.kicker = "Main event"
        let heroBox = try #require(renderer.renderedBox(hero))
        let heroPaint = try render(hero)
        #expect(abs(heroBox.midX - heroPaint.midX) <= 6 && heroBox.height > 0.12 * 1920 * 0.5)
        #expect(heroBox.minY < heroPaint.minY + 10 && heroBox.maxY > heroPaint.maxY - 60, "block with kicker spans the paint, shadows aside")
        var tag = item("Round 3", alignment: "center", w: 0.8, h: 0.06, fontsize: 40)
        tag.design = "tag"
        let tagBox = try #require(renderer.renderedBox(tag))
        let tagPaint = try render(tag)
        #expect(abs(tagBox.midY - tagPaint.midY) <= 12 && abs(tagBox.height - tagPaint.height) <= 40)
        #expect(abs(tagBox.midX - tagPaint.midX) <= 20 && tagPaint.width >= tagBox.width - 4 && tagPaint.width <= tagBox.width + 120,
                "bar vs bar plus its soft shadow and skew")
        var card = TextOverlayItem(text: "x")
        card.design = "nameTag"
        #expect(renderer.renderedBox(card) == nil)
    }

    @Test("An unbreakable token wider than the frame shrinks instead of spilling past the edge")
    func unbreakableTokenShrinks() throws {
        let token = "https://example.com/" + String(repeating: "verylongpathsegment", count: 6)
        let bounds = try render(item(token, alignment: "left", fontsize: 40))
        #expect(bounds.minX >= 21 - 5 && bounds.maxX <= 1080 - 21 + 5, "stays inside the 2% margin")
        #expect(bounds.width > 600, "still uses most of the width")
    }

    @Test("Exact-placement blocks expand into items the safe area leaves alone")
    func exactPlacementSurvivesExpansionAndClamp() throws {
        var text = TextOverlayItem(text: "Low")
        text.xFrac = 0.5; text.yFrac = 0.97; text.wFrac = 0.4; text.hFrac = 0.05; text.unbounded = true
        var image = ImageOverlayItem()
        image.path = "/logo.png"; image.xFrac = 0.95; image.yFrac = 0.5; image.unbounded = true
        var block = OverlayBlockItem()
        block.composition = OverlayComposition(texts: [text], images: [image])
        block.exactPlacement = true
        var document = TimelineDocument()
        document.overlayBlocks = [block]
        let expanded = document.expandingOverlayBlocks()
        #expect(expanded.textOverlays.first?.keepsPlacement == true && expanded.imageOverlays.first?.keepsPlacement == true)
        let area = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: 9.0 / 16.0))
        let keptText = try #require(expanded.textOverlays.first).keptClear(of: area)
        let keptImage = try #require(expanded.imageOverlays.first).keptClear(of: area)
        #expect(keptText.yFrac == 0.97 && keptImage.xFrac == 0.95)
        // The block itself is skipped by the document-level pass too.
        document.renderSettings.platformSafeArea = PlatformSafeAreaSettings()
        #expect(document.keepingOverlaysClearOfPlatformChrome().overlayBlocks.first?.composition.texts.first?.yFrac == 0.97)
        // Round trip keeps the flags.
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(expanded))
        #expect(decoded.textOverlays.first?.keepsPlacement == true && decoded.imageOverlays.first?.keepsPlacement == true)
        let decodedBlock = try JSONDecoder().decode(OverlayBlockItem.self, from: JSONEncoder().encode(block))
        #expect(decodedBlock.exactPlacement)
        #expect(try JSONDecoder().decode(OverlayBlockItem.self, from: Data(#"{"name":"x"}"#.utf8)).exactPlacement == false)
        // A pinned item renders at its designed spot even with a safe area on the renderer.
        var pinned = item("Low", alignment: "center", y: 0.97, fontsize: 30)
        pinned.boxOpacity = 0
        pinned.keepsPlacement = true
        let safeRenderer = TextOverlayRenderer(videoWidth: 1080, videoHeight: 1920, safeArea: area)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let glyphs = try opaqueBounds(try safeRenderer.render(pinned, to: directory))
        #expect(glyphs.midY > 1920 * 0.9, "not lifted above the footer")

        // Images too: a 100x100 red square placed at 92% down stays there.
        let square = directory.appendingPathComponent("square.png")
        let squareContext = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                                   space: CGColorSpaceCreateDeviceRGB(),
                                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        squareContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        squareContext.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let squareImage = try #require(squareContext.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(square as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, squareImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        var logo = ImageOverlayItem()
        logo.path = square.path
        // 10% wide so the square (108 px) fits above the frame's bottom edge at 92%.
        logo.xFrac = 0.5; logo.yFrac = 0.92; logo.wFrac = 0.1
        logo.keepsPlacement = true
        let imageRenderer = ImageOverlayRenderer(videoWidth: 1080, videoHeight: 1920, safeArea: area)
        let pinnedImage = try opaqueBounds(try imageRenderer.render(logo, to: directory))
        #expect(abs(pinnedImage.midY - 1920 * 0.92) < 2 && abs(pinnedImage.midX - 540) < 2)
        logo.keepsPlacement = false
        let nudged = try opaqueBounds(try imageRenderer.render(logo, to: directory))
        #expect(nudged.midY < 1920 * 0.8, "an ordinary image is still kept clear of the footer")
    }

    @Test("Alignment round-trips in JSON and defaults to centre")
    func alignmentCoding() throws {
        var item = TextOverlayItem(text: "x")
        #expect(item.alignment == "center")
        let centred = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        #expect(centred?["alignment"] == nil)
        item.alignment = "right"
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(TextOverlayItem.self, from: data).alignment == "right")
        #expect(try JSONDecoder().decode(TextOverlayItem.self, from: Data("{\"text\":\"x\"}".utf8)).alignment == "center")
    }
    @Test("Decorations follow each word's colour and word-reveal visibility")
    func decorationsRespectWordColourAndVisibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var text = item("OOOO *OOOO*", alignment: "left", fontsize: 60)
        text.boxOpacity = 0
        text.fontcolor = "#ff0000"
        text.highlightColor = "#00ff00"
        func pixels(_ item: TextOverlayItem, visible: Int? = nil) throws -> [UInt8] {
            let url = try renderer.render(item, to: directory, visibleWords: visible)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let plain = try pixels(text)
        text.underline = true
        text.strikethrough = true
        let decorated = try pixels(text)
        let revealed = try pixels(text, visible: 1)
        var redAdded = 0, greenAdded = 0, hiddenGreen = 0
        for offset in stride(from: 0, to: plain.count, by: 4) {
            if plain[offset + 3] == 0 && decorated[offset + 3] > 128 {
                if decorated[offset] > 128 { redAdded += 1 }
                if decorated[offset + 1] > 128 { greenAdded += 1 }
            }
            if revealed[offset + 1] > 128 { hiddenGreen += 1 }
        }
        #expect(redAdded > 0 && greenAdded > 0)
        #expect(hiddenGreen == 0)
    }


    @Test func wordsPerLineCapsLinesBeforeWidthDoes() {
        let words = TextOverlayRenderer.parseMarkup((1...13).map { "w\($0)" }.joined(separator: " "))
        let capped = TextOverlayRenderer.lines(words, maxWords: 6) { _ in true }
        #expect(capped.map(\.count) == [6, 6, 1])
        let widthOnly = TextOverlayRenderer.lines(words, maxWords: nil) { _ in true }
        #expect(widthOnly.map(\.count) == [13])
        // The width still wins when it is tighter than the cap.
        let narrow = TextOverlayRenderer.lines(words, maxWords: 6) { $0.count <= 2 }
        #expect(narrow.map(\.count) == Array(repeating: 2, count: 6) + [1])
        #expect(TextOverlayRenderer.lines([], maxWords: 6) { _ in true }.isEmpty)
    }

    @Test func wordsPerLineDefaultsToSixAndZeroMeansWidthOnly() throws {
        var item = TextOverlayItem(text: "a")
        #expect(item.wordsPerLine == nil && item.resolvedWordsPerLine == 6)
        item.wordsPerLine = 0
        #expect(item.resolvedWordsPerLine == nil)
        item.wordsPerLine = 40
        #expect(item.resolvedWordsPerLine == 12)
        item.wordsPerLine = 4
        let data = try JSONEncoder().encode(item)
        #expect(String(decoding: data, as: UTF8.self).contains("\"words_per_line\":4"))
        #expect(try JSONDecoder().decode(TextOverlayItem.self, from: data).wordsPerLine == 4)
        let legacy = try JSONDecoder().decode(TextOverlayItem.self, from: Data(#"{"text":"old"}"#.utf8))
        #expect(legacy.wordsPerLine == nil && legacy.resolvedWordsPerLine == 6)
    }

    @Test func cappedOverlayRendersTallerThanWidthOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A fitted box sizes its font to the box: one line spans the width,
        // two capped lines share the height and come out much narrower.
        var capped = item("one two three four five six seven eight nine ten", alignment: "center", w: 0.95, h: 0.06, fontsize: 60)
        capped.boxOpacity = 0
        capped.bgcolor = nil
        var wide = capped
        wide.wordsPerLine = 0
        capped.wordsPerLine = 5
        let cappedBounds = try opaqueBounds(try renderer.render(capped, to: directory))
        let wideBounds = try opaqueBounds(try renderer.render(wide, to: directory))
        #expect(cappedBounds.width < wideBounds.width * 0.8, "\(cappedBounds) vs \(wideBounds)")
    }

    /// The Overlays editor saves on `onChange(of: composition)`, so a field the
    /// equality ignores is never saved and the next reload reverts it.
    @Test func wordsPerLineTakesPartInEquality() {
        var item = TextOverlayItem()
        item.text = "Subject"
        var changed = item
        changed.wordsPerLine = 4
        #expect(item != changed, "a Words per line change is a change")
        var explicitDefault = item
        explicitDefault.wordsPerLine = TextOverlayItem.defaultWordsPerLine
        #expect(item == explicitDefault, "nil and the default render the same")
        var widthOnly = item
        widthOnly.wordsPerLine = 0
        #expect(item != widthOnly)
        #expect(OverlayComposition(texts: [item]) != OverlayComposition(texts: [changed]))
    }
}

extension TextOverlayLayoutTests {
    @Test func sharedDecorChangesRenderBoxAndLocalFontWins() {
        let shared = NamedTextStyle(name: "Wide", decor: TextDecor(size: 2, maxWidthFrac: 0.3), fontFamily: "Georgia")
        var item = TextOverlayItem(text: "A long headline with several words")
        item.sharedStyleID = shared.id.uuidString
        item.fontOverride = "Menlo"
        let styled = item.applyingSharedStyle([shared])
        #expect(styled.fontfamily == "Menlo")
        #expect(styled.textLayoutItem.fontsize == item.fontsize * 2)
        let renderer = TextOverlayRenderer(videoWidth: 1080, videoHeight: 1920, safeArea: nil, textStyles: [shared])
        #expect(renderer.renderedBox(item) != TextOverlayRenderer(videoWidth: 1080, videoHeight: 1920, safeArea: nil).renderedBox(item))
    }
}

extension TextOverlayLayoutTests {
    @Test func inspectorCropPadsTheBoxAndStaysOnCanvas() {
        let box = CGRect(x: 100, y: 1800, width: 400, height: 80)
        let rect = TextOverlayPreviewImage.cropRect(box: box, width: 1080, height: 1920)
        #expect(rect == CGRect(x: 72, y: 1772, width: 456, height: 136))
        #expect(TextOverlayPreviewImage.cropRect(box: nil, width: 1080, height: 1920) == nil)
        #expect(TextOverlayPreviewImage.cropRect(box: .zero, width: 1080, height: 1920) == nil)
    }
}

extension TextOverlayLayoutTests {
    @Test func typedLineBreaksAlwaysStartANewLine() {
        let words = TextOverlayRenderer.parseMarkup("Big *bold* hook\nsecond line here")
        #expect(words.map(\.text) == ["Big", "bold", "hook", "second", "line", "here"])
        #expect(words.map(\.breaksLine) == [false, false, false, true, false, false])
        #expect(words[1].highlighted && !words[3].highlighted)
        let lines = TextOverlayRenderer.lines(words, maxWords: nil) { _ in true }
        #expect(lines.map { $0.map(\.text).joined(separator: " ") } == ["Big bold hook", "second line here"])
        // Wrapping still applies inside each typed line.
        let narrow = TextOverlayRenderer.lines(words, maxWords: 2) { _ in true }
        #expect(narrow.map { $0.count } == [2, 1, 2, 1])
        #expect(TextOverlayRenderer.parseMarkup("one\n\ntwo").map(\.breaksLine) == [false, true])
    }
}

