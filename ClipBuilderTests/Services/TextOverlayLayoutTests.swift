import CoreGraphics
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
}
