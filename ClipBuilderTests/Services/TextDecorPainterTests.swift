import Foundation
import CoreGraphics
import CoreText
import ImageIO
import Testing
@testable import Clip_Builder

struct TextDecorPainterTests {
    nonisolated static func pixels(decor: TextDecor, white: Bool = false) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: 360, height: 180, bitsPerComponent: 8,
            bytesPerRow: 360 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 360, height: 180))
        let painter = TextDecorPainter()
        let font = TextDecorPainter.font(family: "Helvetica", size: 64 * (decor.size ?? 1), decor: decor)
        painter.draw(TextCasing.apply("Wide", casing: decor.casing), font: font, at: CGPoint(x: 65, y: 75), decor: decor, in: context)
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 360 * 180 * 4))
    }

    @Test(arguments: ["color", "stroke", "shadow", "hardShadow", "extrude", "background", "border", "italic", "underline", "strikethrough", "spacing", "weight", "casing", "size", "opacity"], [false, true])
    func decorationsChangePixels(_ kind: String, _ white: Bool) async throws {
        try await Task.detached {
            var base = TextDecor(color: "#888888")
            let original = try Self.pixels(decor: base, white: white)
            switch kind {
            case "color": base.color = "#ff0000"
            case "stroke": base.strokeOn = true; base.strokeWidth = 5; base.strokeColor = "#00ff00"
            case "shadow": base.shadowOn = true; base.shadowX = 0.2; base.shadowColor = "#ff0000"
            case "hardShadow": base.shadowOn = true; base.shadowX = 0.2; base.shadowColor = "#ff0000"; base.shadowStyle = "hard"
            case "extrude": base.shadowOn = true; base.shadowX = 0.2; base.shadowY = -0.2; base.shadowColor = "#ff0000"; base.shadowStyle = "extrude"
            case "background": base.bgOn = true; base.bgColor = "#0000ff"; base.bgPaddingX = 0.3
            case "border": base.borderOn = true; base.borderWidth = 5; base.borderColor = "#ff0000"
            case "italic": base.italic = true
            case "underline": base.underline = true
            case "strikethrough": base.strikethrough = true
            case "spacing": base.letterSpacing = 6
            case "weight": base.weight = "black"
            case "casing": base.casing = "upper"
            case "size": base.size = 1.2
            default: base.textOpacity = 0.2
            }
            let changed = try Self.pixels(decor: base, white: white)
            let different = zip(original, changed).filter { $0 != $1 }.count
            #expect(different > 30, "\(kind) changes pixels on both black and white")
        }.value
    }

    @Test(arguments: [0.0, 90.0, 180.0])
    func gradientContainsOrderedColors(_ angle: Double) async throws {
        try await Task.detached {
            let bytes = try Self.pixels(decor: TextDecor(color: "#ff0000", fillEndColor: "#0000ff", fillAngle: angle))
            var red: [Double] = [], blue: [Double] = []
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let x = Double(index / 4 % 360), y = Double(index / 4 / 360)
                let coordinate = angle == 90 ? y : x
                if Int(bytes[index]) > Int(bytes[index + 2]) + 50 { red.append(coordinate) }
                if Int(bytes[index + 2]) > Int(bytes[index]) + 50 { blue.append(coordinate) }
            }
            #expect(!red.isEmpty && !blue.isEmpty)
            let r = red.reduce(0, +) / Double(max(1, red.count)), b = blue.reduce(0, +) / Double(max(1, blue.count))
            // Bitmap storage is top to bottom, although drawing coordinates point up.
            #expect(angle == 180 ? r > b : r < b)
        }.value
    }

    @Test func textOpacityLeavesBackgroundOpaque() async throws {
        try await Task.detached {
            let a = try Self.pixels(decor: TextDecor(color: "#ffffff", textOpacity: 0, bgOn: true, bgColor: "#ff0000"))
            let b = try Self.pixels(decor: TextDecor(color: "#ffffff", textOpacity: 1, bgOn: true, bgColor: "#ff0000"))
            let offset = (80 * 360 + 60) * 4
            #expect(a[offset] > 180 && a[offset + 1] < 80)
            #expect(Array(a[offset..<offset + 4]) == Array(b[offset..<offset + 4]))
        }.value
    }

    @Test func widthCapWrapsCaptionsAndLineHeightGrowsEnvelope() async throws {
        try await Task.detached {
            var style = CaptionStyle()
            style.text = CaptionWordDecor(decor: TextDecor(maxWidthFrac: 0.3))
            let narrow = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
            let wide = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: nil)
            let text = "Every moment has a story"
            #expect(narrow.rowCount(for: text) > wide.rowCount(for: text))
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let compact = try narrow.render(text: text, to: scratch)
            style.text?.decor?.lineHeight = 1.8
            let tall = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil).render(text: text, to: scratch)
            #expect(compact.width <= 400 && tall.height > compact.height)
        }.value
    }

    @Test func tagAndOverlayUseFullDecor() async throws {
        try await Task.detached {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let renderer = TextOverlayRenderer(videoWidth: 540, videoHeight: 960, safeArea: nil)
            for design in ["plain", "hero", "tag", "nameTag"] {
                var item = TextOverlayItem(text: design == "nameTag" ? "Alex\nHost" : "Every strong moment")
                item.design = design; item.fontsize = 100
                item.xFrac = 0.5; item.yFrac = 0.5; item.wFrac = 0.8; item.hFrac = 0.3
                if design == "nameTag" { item.tagStyle = TagStyle() }
                let base = try Data(contentsOf: renderer.render(item, to: root))
                let decor = TextDecor(color: "#ff0000", fillEndColor: "#0000ff", textOpacity: 0.7,
                    strokeOn: true, strokeWidth: 3, strokeColor: "#00ff00", shadowOn: true,
                    bgOn: true, bgColor: "#111111", bgRadius: 20, bgPaddingX: 0.4, bgPerLine: true,
                    borderOn: true, borderColor: "#ffff00")
                if design == "nameTag" { item.tagStyle?.decor = decor; item.tagStyle?.name.decor = decor }
                else { item.decor = decor }
                let changed = try Data(contentsOf: renderer.render(item, to: root))
                #expect(base != changed)
                let source = try #require(CGImageSourceCreateWithData(changed as CFData, nil))
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(image.width == 540 && image.height == 960)
            }
        }.value
    }
}

extension TextDecorPainterTests {
    @Test func strikeCardsKeepTheirRowsAndAcceptDecor() async throws {
        try await Task.detached {
            var item = TextOverlayItem(text: "")
            item.design = "roundCard"
            item.stat = StrikeStatPayload()
            let lines = StrikeStatsCopy.lines(item.stat!)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let renderer = TextOverlayRenderer(videoWidth: 540, videoHeight: 960, safeArea: nil)
            let a = try Data(contentsOf: renderer.render(item, to: scratch))
            item.decor = TextDecor(color: "#ff0000", strokeOn: true, strokeColor: "#00ff00", bgOn: true,
                                  bgColor: "#0000ff", borderOn: true, borderWidth: 4)
            let b = try Data(contentsOf: renderer.render(item, to: scratch))
            #expect(a != b && StrikeStatsCopy.lines(item.stat!) == lines)
        }.value
    }
}

extension TextDecorPainterTests {
    @Test func overlayPreviewUsesExportRenderer() async throws {
        try await Task.detached {
            var item = TextOverlayItem(text: "Preview")
            item.decor = TextDecor(color: "#ff0000", strokeOn: true, bgOn: true, borderOn: true)
            #expect(item.usesTextDecor)
            let data = try TextOverlayPreviewImage.render(item: item, width: 540, height: 960).png
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 540 && image.height == 960)
        }.value
    }
}
