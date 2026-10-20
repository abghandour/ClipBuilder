import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import Clip_Builder

struct CaptionRendererTests {
    @Test func wrappedLinesUseTheSelectedAlignment() {
        #expect(CaptionRenderer.lineOrigin(width: 100, boxWidth: 300, padding: 20, alignment: nil) == 100)
        #expect(CaptionRenderer.lineOrigin(width: 100, boxWidth: 300, padding: 20, alignment: "center") == 100)
        #expect(CaptionRenderer.lineOrigin(width: 100, boxWidth: 300, padding: 20, alignment: "leading") == 20)
        #expect(CaptionRenderer.lineOrigin(width: 100, boxWidth: 300, padding: 20, alignment: "trailing") == 180)
    }

    @Test func explicitPositionsOverrideTheStyleAndAutoPreservesIt() {
        var style = CaptionStyle()
        style.position = "top"
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        let caption = CaptionRenderer.RenderedCaption(pngURL: URL(fileURLWithPath: "/unused"), width: 500, height: 100)
        #expect(renderer.position(for: caption).y == 106)
        #expect(renderer.position(for: caption, positionOverride: "middle").y == 910)
        #expect(renderer.position(for: caption, positionOverride: "bottom").y == 1752)
    }
}

extension CaptionRendererTests {
    @Test func explicitTwoRowPositionsUseFrameEdgesWithOrWithoutPlatforms() throws {
        let safe = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: 9.0 / 16))
        for safeArea in [safe, nil] {
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: safeArea)
            let bottom = renderer.twoRowBand(positionOverride: "bottom")
            let top = renderer.twoRowBand(positionOverride: "top")
            let middle = renderer.twoRowBand(positionOverride: "middle")
            let margin = max(32, 1920 / 28)
            #expect(abs(bottom.maxY - CGFloat(1920 - margin)) <= 1)
            #expect(abs(top.minY - CGFloat(margin)) <= 1)
            #expect(abs(middle.midY - 960) <= 1)
            for band in [bottom, top, middle] { #expect(abs(band.midX - 540) <= 1) }
            let caption = CaptionRenderer.RenderedCaption(pngURL: URL(fileURLWithPath: "/unused"), width: 500, height: 100)
            let origin = renderer.position(for: caption, positionOverride: "bottom")
            #expect(origin.x == 290 && origin.y + caption.height == 1920 - margin)
        }
    }

    @Test func autoTwoRowPositionsRemainInsideThePlatformSafeArea() throws {
        let safe = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: 9.0 / 16))
        for position in ["top", "middle", "bottom"] {
            var style = CaptionStyle()
            style.position = position
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: safe)
            for override in [nil, "auto"] {
                let band = renderer.twoRowBand(positionOverride: override)
                let normalized = CGRect(x: band.minX / 1080, y: band.minY / 1920,
                                        width: band.width / 1080, height: band.height / 1920)
                // Header and footer bound every caption; the button rail only
                // constrains rows it actually overlaps, so a top caption may
                // span the full width.
                let tolerance = 1.0 / 1920
                #expect(normalized.minY >= safe.rect.minY - tolerance)
                #expect(normalized.maxY <= safe.rect.maxY + tolerance)
                let overlapsRail = safe.zones.contains {
                    $0.kind == .rail && $0.rect.minY < normalized.maxY && $0.rect.maxY > normalized.minY
                }
                if overlapsRail { #expect(normalized.maxX <= safe.rect.maxX + 1.0 / 1080) }
            }
        }
    }

    @Test func explicitMarginsScaleAndKeepTheirMinimumOnSmallCanvases() {
        for height in [480, 1080, 1920, 3840] {
            let renderer = CaptionRenderer(videoWidth: height * 9 / 16, videoHeight: height,
                                           style: CaptionStyle(), safeArea: nil)
            let band = renderer.twoRowBand(positionOverride: "bottom")
            #expect(abs(band.maxY - CGFloat(height - max(32, height / 28))) <= 1)
        }
    }
}

extension CaptionRendererTests {
    @Test func highlightNeverMovesThePage() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            for mode in ["color", "box", "scale"] {
                var style = CaptionStyle()
                style.highlight = mode
                let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                let plain = try renderer.render(text: "Every moment has a story", to: folder)
                for index in 0..<5 {
                    let lit = try renderer.render(text: "Every moment has a story", activeIndex: index, to: folder)
                    #expect(abs(lit.width - plain.width) <= 1 && lit.height == plain.height)
                }
            }
        }.value
    }

    @Test func wideHighlightFontIsReservedInEveryState() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var style = CaptionStyle()
            style.highlight = "color"
            let narrow = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "Thin wide end", to: folder)
            style.highlightFont = "mono"
            style.highlightDecor = CaptionWordDecor(italic: true, bgOn: true)
            style.emphasis = "both"
            style.emphasisDecor = CaptionWordDecor(size: 80)
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
            let plain = try renderer.render(text: "Thin wide end", to: folder)
            // The wider italic highlight and larger emphasis grow the reserved
            // slots before either state is drawn, and never shift the page.
            #expect(plain.width > narrow.width)
            for index in 0..<3 {
                let lit = try renderer.render(text: "Thin wide end", activeIndex: index, to: folder)
                #expect(abs(lit.width - plain.width) <= 1 && lit.height == plain.height)
            }
        }.value
    }
}

extension CaptionRendererTests {
    @Test func entranceFramesKeepTheirEnvelopeAndSafeWidth() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let safe = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: 9.0 / 16))
            for motion in ["pop", "slide-up", "fade"] {
                var style = CaptionStyle()
                style.animation = motion
                style.highlight = "scale"
                let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: safe)
                let steady = try renderer.render(text: "Every strong moment earns victory", to: folder)
                #expect(Double(steady.width) <= safe.rect.width * 1080 + 1)
                for frame in CaptionAnimation.frames(for: motion, duration: 0.16) {
                    let animated = try renderer.render(text: "Every strong moment earns victory", frame: frame, to: folder)
                    #expect(animated.width == steady.width && animated.height == steady.height)
                }
            }
        }.value
    }
}

extension CaptionRendererTests {
    nonisolated private static func pixels(_ rendered: CaptionRenderer.RenderedCaption) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(rendered.pngURL as CFURL, nil))
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

    @Test func decorationsAddPixelsBelowAndThroughTheWord() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var style = CaptionStyle()
            style.strokeWidth = 0
            style.text = CaptionWordDecor()
            let plain = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "OOOO", to: folder)
            let base = try Self.pixels(plain)
            let occupied = stride(from: 3, to: base.count, by: 4).filter { base[$0] > 128 }
            let minRow = try #require(occupied.map { ($0 / 4) / plain.width }.min())
            let maxRow = try #require(occupied.map { ($0 / 4) / plain.width }.max())
            for strike in [false, true] {
                style.text = CaptionWordDecor(underline: !strike, strikethrough: strike)
                let result = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                    .render(text: "OOOO", to: folder)
                #expect(result.width == plain.width && result.height == plain.height)
                let decorated = try Self.pixels(result)
                let added = stride(from: 3, to: base.count, by: 4).filter { decorated[$0] > 128 && base[$0] == 0 }
                #expect(!added.isEmpty)
                let rows = added.map { ($0 / 4) / plain.width }
                if strike { #expect(rows.contains { $0 > minRow && $0 < maxRow }) }
                else { #expect(rows.contains { $0 < minRow || $0 > maxRow }) }
            }
        }.value
    }

    @Test func squareAndRoundedWordBackgroundCorners() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var style = CaptionStyle()
            style.strokeWidth = 0
            style.text = CaptionWordDecor(bgOn: true, bgColor: "#ff0000", bgRadius: 0)
            let square = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "WORD", to: folder)
            let bytes = try Self.pixels(square)
            let filled = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 250 }
            let x = try #require(filled.map { ($0 / 4) % square.width }.min()) + 1
            let y = try #require(filled.map { ($0 / 4) / square.width }.min()) + 1
            style.text?.bgRadius = 20
            let rounded = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "WORD", to: folder)
            #expect(square.width == rounded.width && square.height == rounded.height)
            let roundedBytes = try Self.pixels(rounded)
            let corner = (y * square.width + x) * 4 + 3
            #expect(bytes[corner] == 255 && roundedBytes[corner] == 0)
        }.value
    }

    @Test func neighboursKeepTheirPixelPositionsAcrossStates() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var style = CaptionStyle()
            style.highlight = "color"
            style.highlightFont = "mono"
            style.highlightDecor = CaptionWordDecor(italic: true, size: 70, bgOn: true)
            style.emphasis = "both"
            style.emphasisDecor = CaptionWordDecor(size: 90)
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
            let plain = try renderer.render(text: "IIII IIII IIII", to: folder)
            let base = try Self.pixels(plain)
            for active in [false, true] {
                let changed = try renderer.render(text: "IIII IIII IIII", activeIndex: active ? 1 : nil,
                                                  emphasis: active ? [] : [1], to: folder)
                #expect(changed.width == plain.width && changed.height == plain.height)
                let bytes = try Self.pixels(changed)
                let neighboursMatch = (0..<plain.height).allSatisfy { y in
                    (0..<plain.width).allSatisfy { x in
                        guard x < plain.width / 3 || x >= plain.width * 2 / 3 else { return true }
                        let offset = (y * plain.width + x) * 4
                        return bytes[offset..<offset + 4] == base[offset..<offset + 4]
                    }
                }
                #expect(neighboursMatch)
            }
        }.value
    }
}
